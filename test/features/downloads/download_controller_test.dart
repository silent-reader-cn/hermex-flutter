import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/cache/app_database.dart';
import 'package:hermes_ui/core/cache/cache_providers.dart';
import 'package:hermes_ui/features/diagnostics/diagnostics_service.dart';
import 'package:hermes_ui/features/downloads/download_models.dart';
import 'package:hermes_ui/features/downloads/download_providers.dart';
import 'package:hermes_ui/features/downloads/download_save_service.dart';
import 'package:hermes_ui/features/notifications/notification_providers.dart';
import 'package:hermes_ui/features/notifications/turn_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotificationService implements TurnNotificationService {
  final List<(String id, String fileName, int size)> downloadCompletedCalls =
      [];
  final List<(String, String, String)> notifyCalls = [];
  final List<(String, String)> clarifyCalls = [];
  final List<(String, String, String)> errorCalls = [];
  int clearAllCalls = 0;

  @override
  Future<void> notifyDownloadCompleted(
    String downloadId,
    String fileName,
    int byteSize,
  ) async {
    downloadCompletedCalls.add((downloadId, fileName, byteSize));
  }

  @override
  Future<void> notifyTurnCompleted(
    String sessionId,
    String title,
    String preview,
  ) async {
    notifyCalls.add((sessionId, title, preview));
  }

  @override
  Future<void> notifyClarificationNeeded(
    String sessionId,
    String question,
  ) async {
    clarifyCalls.add((sessionId, question));
  }

  @override
  Future<void> notifySessionError(
    String sessionId,
    String title,
    String preview,
  ) async {
    errorCalls.add((sessionId, title, preview));
  }

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> areNotificationsEnabled() async => true;
  @override
  Future<String?> getLaunchSessionId() async => null;
}

class _FailingSaveService extends DownloadSaveService {
  _FailingSaveService({required this.error});
  final Object error;

  @override
  Future<String> save({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    throw error;
  }
}

void main() {
  late AppDatabase db;
  late Directory tempSaveDir;
  late DownloadSaveService saveService;
  late _FakeNotificationService notificationService;
  late Map<String, Uint8List Function()> mockDownloadResponses;

  setUp(() async {
    SharedPreferences.setMockInitialValues({kDiagnosticsEnabledKey: true});
    await DiagnosticsService.instance.init();
    await DiagnosticsService.instance.clear();

    db = AppDatabase.memory();
    tempSaveDir = Directory.systemTemp.createTempSync(
      'hermes_controller_test_',
    );
    saveService = DownloadSaveService(destinationDirOverride: tempSaveDir);
    notificationService = _FakeNotificationService();
    mockDownloadResponses = {};
  });

  tearDown(() async {
    await db.close();
    try {
      await tempSaveDir.delete(recursive: true);
    } catch (_) {}
  });

  ProviderContainer createContainer({
    DownloadBytesDownloader? customDownloader,
    DownloadSaveService? customSaveService,
  }) {
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        downloadSaveServiceProvider.overrideWithValue(
          customSaveService ?? saveService,
        ),
        turnNotificationServiceProvider.overrideWithValue(notificationService),
        downloadDownloaderProvider.overrideWithValue(
          customDownloader ??
              (url, {onProgress}) async {
                final key = url.toString();
                if (mockDownloadResponses.containsKey(key)) {
                  return mockDownloadResponses[key]!();
                }
                return Uint8List.fromList([1, 2, 3, 4]);
              },
        ),
      ],
    );
  }

  group('DownloadController 核心队列与状态机', () {
    test('单任务下载成功：更新 completed、保存文件、触发通知、记录诊断日志', () async {
      mockDownloadResponses['https://example.com/sample.pdf'] = () =>
          Uint8List.fromList([10, 20, 30]);

      final container = createContainer();
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/sample.pdf',
        fileName: 'sample.pdf',
        mimeType: 'application/pdf',
        expectedBytes: 3,
      );

      // 等待 FIFO worker 处理完成
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      final task = state.taskById(id);

      expect(task, isNotNull);
      expect(task!.status, DownloadStatus.completed);
      expect(task.receivedBytes, 3);
      expect(task.savedPath, isNotNull);
      expect(File(task.savedPath!).existsSync(), isTrue);

      // 验证通知触发
      expect(notificationService.downloadCompletedCalls, hasLength(1));
      expect(notificationService.downloadCompletedCalls.single, (
        id,
        'sample.pdf',
        3,
      ));

      // 验证数据库持久化
      final repo = container.read(downloadRepositoryProvider);
      final persisted = await repo.getRecordById(id);
      expect(persisted?.status, DownloadStatus.completed);
      expect(persisted?.savedPath, task.savedPath);

      // 验证诊断日志
      final logs = DiagnosticsService.instance.logs
          .where((l) => l.tag == 'downloads')
          .toList();
      expect(logs.any((l) => l.message.contains('下载完成')), isTrue);
    });

    test('任务下载失败：更新 failed、填充 failureMessage、记录 error 日志', () async {
      final container = createContainer(
        customDownloader: (url, {onProgress}) async =>
            throw Exception('网络连接超时 504'),
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/fail.zip',
        fileName: 'fail.zip',
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      final task = state.taskById(id);

      expect(task, isNotNull);
      expect(task!.status, DownloadStatus.failed);
      expect(task.failureMessage, contains('网络连接超时 504'));
      expect(task.completedAt, isNotNull);

      // 验证数据库
      final repo = container.read(downloadRepositoryProvider);
      final persisted = await repo.getRecordById(id);
      expect(persisted?.status, DownloadStatus.failed);
      expect(persisted?.failureMessage, contains('网络连接超时 504'));
    });

    test('#69 下载过程进度回传：onProgress 中途刷新 receivedBytes/expectedBytes', () async {
      final progressEmitted = Completer<void>();
      final releaseDownload = Completer<void>();

      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          // 模拟 dio 分块回调：先报一半（total 已知），等测试读取中间态后放行。
          onProgress?.call(500, 1000);
          progressEmitted.complete();
          await releaseDownload.future;
          return Uint8List(1000);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/progress.bin',
        fileName: 'progress.bin',
      );

      await progressEmitted.future;
      // 回调里 DateTime.now() 距 epoch 恒 >100ms → 首帧必刷。等一帧 state 更新。
      await Future<void>.delayed(const Duration(milliseconds: 20));

      var task = container.read(downloadControllerProvider).taskById(id);
      expect(task, isNotNull);
      expect(task!.status, DownloadStatus.downloading);
      expect(task.receivedBytes, 500);
      expect(task.expectedBytes, 1000);
      expect(task.progress, closeTo(0.5, 0.01));

      releaseDownload.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      task = container.read(downloadControllerProvider).taskById(id);
      expect(task!.status, DownloadStatus.completed);
    });

    test('#69 total 未知(-1)时进度仍回传 receivedBytes', () async {
      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          onProgress?.call(700, -1);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return Uint8List(700);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/unknown_total.bin',
        fileName: 'unknown_total.bin',
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final task = container.read(downloadControllerProvider).taskById(id);
      // 首帧回调即刷 receivedBytes（timeHit）；完成后为 completed+700。
      expect(task!.receivedBytes, 700);
    });

    test('取消排队中任务：状态转为 cancelled 并跳过下载', () async {
      final downloadStarted = Completer<void>();
      final blockFirstDownload = Completer<void>();

      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          if (url.toString().contains('first')) {
            downloadStarted.complete();
            await blockFirstDownload.future;
            return Uint8List(10);
          }
          return Uint8List(20);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);

      // 1. 加入第一个任务（阻塞在下载中）
      final id1 = await controller.enqueue(
        sourceUrl: 'https://example.com/first.bin',
        fileName: 'first.bin',
      );

      await downloadStarted.future;

      // 2. 加入第二个任务（排队中）
      final id2 = await controller.enqueue(
        sourceUrl: 'https://example.com/second.bin',
        fileName: 'second.bin',
      );

      // 取消第二个任务
      await controller.cancel(id2);

      expect(
        container.read(downloadControllerProvider).taskById(id2)?.status,
        DownloadStatus.cancelled,
      );

      // 释放第一个任务
      blockFirstDownload.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      expect(state.taskById(id1)?.status, DownloadStatus.completed);
      expect(state.taskById(id2)?.status, DownloadStatus.cancelled);
    });

    test('取消正在下载的任务：下载返回后丢弃结果，不保存文件且不发通知', () async {
      final downloadStarted = Completer<void>();
      final finishDownload = Completer<void>();

      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          downloadStarted.complete();
          await finishDownload.future;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/canceling.bin',
        fileName: 'canceling.bin',
      );

      await downloadStarted.future;
      expect(
        container.read(downloadControllerProvider).taskById(id)?.status,
        DownloadStatus.downloading,
      );

      // 标记取消
      await controller.cancel(id);
      expect(
        container.read(downloadControllerProvider).taskById(id)?.status,
        DownloadStatus.cancelled,
      );

      // 下载返回
      finishDownload.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      expect(state.taskById(id)?.status, DownloadStatus.cancelled);
      expect(state.taskById(id)?.savedPath, isNull);
      expect(notificationService.downloadCompletedCalls, isEmpty);
    });

    test('重试失败/已取消任务：重新加入队列并成功完成', () async {
      var failOnce = true;
      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          if (failOnce) {
            failOnce = false;
            throw Exception('第一次失败');
          }
          return Uint8List.fromList([42]);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/retry.bin',
        fileName: 'retry.bin',
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        container.read(downloadControllerProvider).taskById(id)?.status,
        DownloadStatus.failed,
      );

      // 重试
      await controller.retry(id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      expect(state.taskById(id)?.status, DownloadStatus.completed);
      expect(state.taskById(id)?.failureMessage, isNull);
      expect(state.taskById(id)?.receivedBytes, 1);
    });

    test('已完成任务去重：本地文件仍存在直接返回已存在任务 ID，不重复下载', () async {
      var downloadCalls = 0;
      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          downloadCalls++;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);

      // 第一次下载
      final id1 = await controller.enqueue(
        sourceUrl: 'https://example.com/dedup.png',
        fileName: 'dedup.png',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(downloadCalls, 1);

      // 第二次相同 sourceUrl：本地文件存在 → 直接返回 id1
      final id2 = await controller.enqueue(
        sourceUrl: 'https://example.com/dedup.png',
        fileName: 'dedup.png',
      );
      expect(id2, equals(id1));
      expect(downloadCalls, 1);

      // 删除本地文件后再加入：重新触发下载
      final task1 = container.read(downloadControllerProvider).taskById(id1)!;
      File(task1.savedPath!).deleteSync();

      // 先把原已完成状态移除或者尝试重新 enqueue
      // 当文件被删后，再 enqueue 应当重新下载
      final id3 = await controller.enqueue(
        sourceUrl: 'https://example.com/dedup.png',
        fileName: 'dedup.png',
      );
      expect(id3, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(downloadCalls, 2);
    });

    test('队列中活跃同 URL 合并：不重复入队', () async {
      final blockDownload = Completer<void>();
      final downloadStarted = Completer<void>();
      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          downloadStarted.complete();
          await blockDownload.future;
          return Uint8List(10);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);

      final id1 = await controller.enqueue(
        sourceUrl: 'https://example.com/merge.bin',
        fileName: 'merge.bin',
      );
      await downloadStarted.future;

      final id2 = await controller.enqueue(
        sourceUrl: 'https://example.com/merge.bin',
        fileName: 'merge.bin',
      );

      expect(id2, equals(id1));
      expect(container.read(downloadControllerProvider).tasks, hasLength(1));

      blockDownload.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('remove 与 clearTerminalRecords', () async {
      final container = createContainer();
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);

      final id1 = await controller.enqueue(
        sourceUrl: 'https://example.com/file1',
        fileName: 'file1',
      );
      final id2 = await controller.enqueue(
        sourceUrl: 'https://example.com/file2',
        fileName: 'file2',
      );
      expect(id2, isNotEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(container.read(downloadControllerProvider).tasks, hasLength(2));

      await controller.remove(id1);
      expect(container.read(downloadControllerProvider).tasks, hasLength(1));
      expect(container.read(downloadControllerProvider).taskById(id1), isNull);

      await controller.clearTerminalRecords();
      expect(container.read(downloadControllerProvider).tasks, isEmpty);
    });

    test('内存字节模式：直接保存文件，不经过网络下载器，sourceType 为 bytes', () async {
      var networkCalled = false;
      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          networkCalled = true;
          return Uint8List(0);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final rawBytes = Uint8List.fromList([10, 20, 30, 40, 50]);
      final id = await controller.enqueue(
        bytes: rawBytes,
        fileName: 'memory_image.png',
        mimeType: 'image/png',
        expectedBytes: 5,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      final task = state.taskById(id);

      expect(task, isNotNull);
      expect(task!.sourceType, DownloadSourceType.bytes);
      expect(task.status, DownloadStatus.completed);
      expect(task.receivedBytes, 5);
      expect(task.savedPath, isNotNull);
      expect(File(task.savedPath!).existsSync(), isTrue);
      expect(File(task.savedPath!).readAsBytesSync(), rawBytes);
      expect(networkCalled, isFalse);

      expect(notificationService.downloadCompletedCalls, hasLength(1));
      expect(notificationService.downloadCompletedCalls.single, (
        id,
        'memory_image.png',
        5,
      ));
    });

    test('Data URI 模式：解码 base64 直接落盘，sourceType 为 bytes 且不调下载器', () async {
      var networkCalled = false;
      final container = createContainer(
        customDownloader: (url, {onProgress}) async {
          networkCalled = true;
          return Uint8List(0);
        },
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      // "hello" in base64: aGVsbG8=
      final id = await controller.enqueue(
        sourceUrl: 'data:text/plain;base64,aGVsbG8=',
        fileName: 'hello.txt',
        mimeType: 'text/plain',
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      final task = state.taskById(id);

      expect(task, isNotNull);
      expect(task!.sourceType, DownloadSourceType.bytes);
      expect(task.status, DownloadStatus.completed);
      expect(task.savedPath, isNotNull);
      expect(File(task.savedPath!).existsSync(), isTrue);
      expect(File(task.savedPath!).readAsStringSync(), 'hello');
      expect(networkCalled, isFalse);
    });

    test('内存字节去重：本地文件仍存在直接返回已存在任务 ID；删除后重新落盘', () async {
      final container = createContainer();
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final rawBytes = Uint8List.fromList([1, 2, 3]);

      final id1 = await controller.enqueue(
        bytes: rawBytes,
        fileName: 'dup_test.bin',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 再次 enqueue 相同 fileName 与 bytes：文件存在 → 返回 id1
      final id2 = await controller.enqueue(
        bytes: rawBytes,
        fileName: 'dup_test.bin',
      );
      expect(id2, equals(id1));

      // 删除本地文件
      final task1 = container.read(downloadControllerProvider).taskById(id1)!;
      File(task1.savedPath!).deleteSync();

      // 文件被删后再次 enqueue：重新创建并落盘
      final id3 = await controller.enqueue(
        bytes: rawBytes,
        fileName: 'dup_test.bin',
      );
      expect(id3, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final task3 = container.read(downloadControllerProvider).taskById(id3)!;
      expect(task3.status, DownloadStatus.completed);
      expect(File(task3.savedPath!).existsSync(), isTrue);
    });

    test('平台保存异常透传（Area D）：DownloadSaveService 抛错捕获置 failed 并记录诊断日志', () async {
      final container = createContainer(
        customSaveService: _FailingSaveService(
          error: const FileSystemException(
            'Permission denied (Scoped Storage)',
          ),
        ),
      );
      addTearDown(container.dispose);

      final controller = container.read(downloadControllerProvider.notifier);
      final id = await controller.enqueue(
        sourceUrl: 'https://example.com/scoped_storage_test.apk',
        fileName: 'scoped_storage_test.apk',
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final state = container.read(downloadControllerProvider);
      final task = state.taskById(id);

      expect(task, isNotNull);
      expect(task!.status, DownloadStatus.failed);
      expect(task.failureMessage, contains('Permission denied'));

      // 验证诊断日志包含错误
      final logs = DiagnosticsService.instance.logs
          .where((l) => l.tag == 'downloads')
          .toList();
      expect(
        logs.any(
          (l) => l.message.contains('保存失败') || l.message.contains('下载失败'),
        ),
        isTrue,
      );
    });
  });
}
