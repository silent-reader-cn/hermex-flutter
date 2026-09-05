import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/cache/app_database.dart';
import 'package:hermes_ui/core/cache/cache_providers.dart';
import 'package:hermes_ui/features/diagnostics/diagnostics_service.dart';
import 'package:hermes_ui/features/downloads/download_models.dart';
import 'package:hermes_ui/features/downloads/download_page.dart';
import 'package:hermes_ui/features/downloads/download_providers.dart';
import 'package:hermes_ui/features/downloads/download_repository.dart';
import 'package:hermes_ui/features/downloads/download_save_service.dart';
import 'package:hermes_ui/features/notifications/notification_providers.dart';
import 'package:hermes_ui/features/notifications/turn_notification_service.dart';
import 'package:hermes_ui/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通知服务测试双（与 download_controller_test 同款，避免真实插件调用卡 pumpAndSettle）。
class _FakeNotificationService implements TurnNotificationService {
  @override
  Future<void> notifyDownloadCompleted(
    String downloadId,
    String fileName,
    int byteSize,
  ) async {}

  @override
  Future<void> notifyTurnCompleted(
    String sessionId,
    String title,
    String preview,
  ) async {}

  @override
  Future<void> notifyClarificationNeeded(
    String sessionId,
    String question,
  ) async {}

  @override
  Future<void> notifySessionError(
    String sessionId,
    String title,
    String preview,
  ) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> areNotificationsEnabled() async => true;
  @override
  Future<String?> getLaunchSessionId() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const List<LocalizationsDelegate<dynamic>> testDelegates = [
    AppLocalizationsDelegate(),
    DefaultCupertinoLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  late AppDatabase db;
  late DownloadRepository repo;
  late Directory tempDir;
  late _FakeNotificationService notificationService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({kDiagnosticsEnabledKey: true});
    await DiagnosticsService.instance.init();
    await DiagnosticsService.instance.clear();
    db = AppDatabase.memory();
    repo = DownloadRepository(db);
    tempDir = await Directory.systemTemp.createTemp('download_page_test_');
    notificationService = _FakeNotificationService();
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget buildTestApp({
    Future<void> Function(String path)? onOpenFile,
    List<DownloadTask>? tasksOverride,
  }) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        downloadRepositoryProvider.overrideWithValue(repo),
        downloadSaveServiceProvider.overrideWithValue(
          DownloadSaveService(destinationDirOverride: tempDir),
        ),
        turnNotificationServiceProvider.overrideWithValue(notificationService),
        // DownloadController 内部 watch 的远程下载执行器走 apiClientProvider，
        // 无服务器连接会抛「尚未配置服务器连接」——测试注入假执行器。
        downloadDownloaderProvider.overrideWithValue(
          (uri, {onProgress}) async => Uint8List.fromList([]),
        ),
        if (tasksOverride != null)
          downloadTasksProvider.overrideWithValue(tasksOverride),
      ],
      child: CupertinoApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: testDelegates,
        home: DownloadPage(onOpenFile: onOpenFile),
      ),
    );
  }

  group('DownloadPage 渲染与交互测试', () {
    testWidgets('空状态展示图标与「暂无下载记录」文案，且顶部不展示清除按钮', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('下载'), findsOneWidget);
      expect(find.text('暂无下载记录'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.arrow_down_circle), findsOneWidget);
      expect(
        find.byKey(const ValueKey('downloads-clear-terminal-button')),
        findsNothing,
      );
    });

    testWidgets('渲染不同状态的下载任务（排队中/下载中/已完成/失败/已取消）', (tester) async {
      // 真实文件 IO 在 FakeAsync 环境挂起，必须包 runAsync。
      final existingFilePath = await tester.runAsync(() async {
        final existingFile = File('${tempDir.path}/report.pdf');
        await existingFile.writeAsString('pdf content');
        return existingFile.path;
      });

      final now = DateTime.now().millisecondsSinceEpoch;

      // 注意：预填 DB 会被 controller 启动 recover 转 failed——渲染用例
      // 直接 override downloadTasksProvider 注入固定状态列表。
      final tasks = [
        DownloadTask(
          id: 'task-1',
          sourceUrl: 'https://example.com/file1.zip',
          fileName: 'archive.zip',
          mimeType: 'application/zip',
          status: DownloadStatus.queued,
          createdAt: now - 50000,
        ),
        DownloadTask(
          id: 'task-2',
          sourceUrl: 'https://example.com/video.mp4',
          fileName: 'video.mp4',
          mimeType: 'video/mp4',
          status: DownloadStatus.downloading,
          receivedBytes: 5242880, // 5MB
          expectedBytes: 10485760, // 10MB
          createdAt: now - 40000,
        ),
        DownloadTask(
          id: 'task-3',
          sourceUrl: 'https://example.com/report.pdf',
          fileName: 'report.pdf',
          mimeType: 'application/pdf',
          status: DownloadStatus.completed,
          receivedBytes: 2048,
          expectedBytes: 2048,
          savedPath: existingFilePath,
          createdAt: now - 30000,
        ),
        DownloadTask(
          id: 'task-4',
          sourceUrl: 'https://example.com/code.dart',
          fileName: 'code.dart',
          mimeType: 'text/plain',
          status: DownloadStatus.failed,
          failureMessage: 'HTTP 404',
          createdAt: now - 20000,
        ),
        DownloadTask(
          id: 'task-5',
          sourceUrl: 'https://example.com/photo.png',
          fileName: 'photo.png',
          mimeType: 'image/png',
          status: DownloadStatus.cancelled,
          createdAt: now - 10000,
        ),
      ];

      await tester.pumpWidget(buildTestApp(tasksOverride: tasks));
      await tester.pumpAndSettle();

      // 验证任务卡片展示
      expect(find.text('archive.zip'), findsOneWidget);
      expect(find.text('等待中'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('download-cancel-task-1')),
        findsOneWidget,
      );

      expect(find.text('video.mp4'), findsOneWidget);
      expect(find.text('50% (5.0 MB / 10.0 MB)'), findsOneWidget);
      expect(find.byType(CupertinoProgressBar), findsOneWidget);

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('已完成 · 2.0 KB'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('download-open-task-3')),
        findsOneWidget,
      );

      expect(find.text('code.dart'), findsOneWidget);
      expect(find.text('失败：HTTP 404'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('download-retry-task-4')),
        findsOneWidget,
      );

      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('已取消'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('download-retry-task-5')),
        findsOneWidget,
      );

      // 验证存在终端状态任务时顶部展示「清除已完成」按钮
      expect(
        find.byKey(const ValueKey('downloads-clear-terminal-button')),
        findsOneWidget,
      );
    });

    testWidgets('已完成任务在本地文件被删除后展示「文件已被移动或删除」与「重新下载」按钮', (tester) async {
      await tester.runAsync(() async {
        final taskMissingFile = DownloadTask(
          id: 'task-missing',
          sourceUrl: 'https://example.com/missing.pdf',
          fileName: 'missing.pdf',
          mimeType: 'application/pdf',
          status: DownloadStatus.completed,
          savedPath: '${tempDir.path}/non_existent_file.pdf',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );

        await repo.saveRecord(taskMissingFile);
      });

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('文件已被移动或删除'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('download-retry-task-missing')),
        findsOneWidget,
      );
      expect(find.text('重新下载'), findsOneWidget);
    });

    testWidgets('点击打开文件触发 onOpenFile 回调', (tester) async {
      await tester.runAsync(() async {
        final existingFile = File('${tempDir.path}/test_doc.pdf');
        await existingFile.writeAsString('pdf content');

        final task = DownloadTask(
          id: 'task-open',
          sourceUrl: 'https://example.com/test_doc.pdf',
          fileName: 'test_doc.pdf',
          status: DownloadStatus.completed,
          savedPath: existingFile.path,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );

        await repo.saveRecord(task);
      });

      late String openedPath;
      await tester.pumpWidget(
        buildTestApp(
          onOpenFile: (path) async {
            openedPath = path;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('download-open-task-open')));
      await tester.pumpAndSettle();

      expect(openedPath, equals('${tempDir.path}/test_doc.pdf'));
    });

    testWidgets('点击删除按钮移除单条记录', (tester) async {
      await tester.runAsync(() async {
        final task = DownloadTask(
          id: 'task-del',
          sourceUrl: 'https://example.com/del.zip',
          fileName: 'del.zip',
          status: DownloadStatus.failed,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );

        await repo.saveRecord(task);
      });

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('del.zip'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('download-delete-task-del')));
      // remove 内部含异步 DB 删除：先 pumpAndSettle 驱动 rebuild，再
      // FakeAsync 快进消化可能的一次性 Timer，最后 runAsync 让真实 drift
      // 异步落定，避免测试结束时报 “A Timer is still pending”。
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      expect(find.text('del.zip'), findsNothing);
      expect(find.text('暂无下载记录'), findsOneWidget);
    });

    testWidgets('点击顶部清除已完成按钮清空所有终端状态记录', (tester) async {
      await tester.runAsync(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final task1 = DownloadTask(
          id: 'task-1',
          sourceUrl: 'https://example.com/1.zip',
          fileName: '1.zip',
          status: DownloadStatus.completed,
          createdAt: now - 2000,
        );
        final task2 = DownloadTask(
          id: 'task-2',
          sourceUrl: 'https://example.com/2.zip',
          fileName: '2.zip',
          status: DownloadStatus.failed,
          createdAt: now - 1000,
        );

        await repo.saveRecords([task1, task2]);
      });

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('1.zip'), findsOneWidget);
      expect(find.text('2.zip'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('downloads-clear-terminal-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('暂无下载记录'), findsOneWidget);
    });
  });
}
