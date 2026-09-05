import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/uuid.dart';
import '../diagnostics/diagnostics_models.dart';
import '../diagnostics/diagnostics_service.dart';
import '../notifications/notification_providers.dart';
import '../notifications/turn_notification_service.dart';
import 'download_models.dart';
import 'download_providers.dart';
import 'download_repository.dart';
import 'download_save_service.dart';

/// 下载列表状态快照。
class DownloadState {
  const DownloadState({this.tasks = const [], this.isInitialized = false});

  /// 全部任务列表（含排队中、下载中及历史终态任务）。
  final List<DownloadTask> tasks;

  /// 是否已完成数据库恢复与历史加载。
  final bool isInitialized;

  /// 排队中任务列表。
  List<DownloadTask> get queuedTasks =>
      tasks.where((t) => t.status == DownloadStatus.queued).toList();

  /// 当前正在下载的任务（单 worker 模式下最多 1 个）。
  DownloadTask? get currentDownloadingTask =>
      tasks.where((t) => t.status == DownloadStatus.downloading).firstOrNull;

  /// 已完成任务列表。
  List<DownloadTask> get completedTasks =>
      tasks.where((t) => t.status == DownloadStatus.completed).toList();

  /// 失败任务列表。
  List<DownloadTask> get failedTasks =>
      tasks.where((t) => t.status == DownloadStatus.failed).toList();

  /// 已取消任务列表。
  List<DownloadTask> get cancelledTasks =>
      tasks.where((t) => t.status == DownloadStatus.cancelled).toList();

  /// 根据 ID 查找指定任务。
  DownloadTask? taskById(String id) {
    for (final task in tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  DownloadState copyWith({List<DownloadTask>? tasks, bool? isInitialized}) {
    return DownloadState(
      tasks: tasks ?? this.tasks,
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadState &&
          runtimeType == other.runtimeType &&
          isInitialized == other.isInitialized &&
          listEquals(tasks, other.tasks);

  @override
  int get hashCode => Object.hash(isInitialized, Object.hashAll(tasks));
}

/// 下载控制器（FIFO 单 worker 队列、断点恢复、去重合并、取消与持久化）。
class DownloadController extends Notifier<DownloadState> {
  late final DownloadRepository _repository;
  late final DownloadSaveService _saveService;
  late final TurnNotificationService _notificationService;
  late final DownloadBytesDownloader _downloader;

  bool _isWorkerRunning = false;
  bool _isInitialized = false;
  final Set<String> _cancelledTaskIds = {};
  final Map<String, Uint8List> _pendingBytes = {};
  Completer<void>? _initCompleter;

  @override
  DownloadState build() {
    _repository = ref.watch(downloadRepositoryProvider);
    _saveService = ref.watch(downloadSaveServiceProvider);
    _notificationService = ref.watch(turnNotificationServiceProvider);
    _downloader = ref.watch(downloadDownloaderProvider);

    _isWorkerRunning = false;
    _isInitialized = false;
    _cancelledTaskIds.clear();
    _pendingBytes.clear();
    _initCompleter = null;

    unawaited(Future.microtask(_ensureInitialized));

    return const DownloadState();
  }

  /// 确保异步初始化完成：中断任务恢复与历史记录装载。
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    if (_initCompleter != null) return _initCompleter!.future;
    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      await _repository.recoverInterruptedTasks();
      final records = await _repository.getAllRecords();

      final currentTasks = {for (final t in state.tasks) t.id: t};
      for (final r in records) {
        if (!currentTasks.containsKey(r.id)) {
          currentTasks[r.id] = r;
        }
      }
      final sorted = currentTasks.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      _isInitialized = true;
      state = state.copyWith(tasks: sorted, isInitialized: true);
      completer.complete();
      unawaited(_processQueue());
    } catch (error) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.error,
        tag: 'downloads',
        message: '下载初始化失败',
        errorKind: error.toString(),
      );
      _isInitialized = true;
      state = state.copyWith(isInitialized: true);
      completer.complete();
    }
  }

  /// 将新下载任务加入队列。
  ///
  /// 支持两种来源模式：
  /// - URL 模式：传入 [sourceUrl]，由 worker 通过网络下载；
  /// - bytes 模式：传入内存字节 [bytes]（如已解码 Data URI 或内存图），worker 跳过网络直接落盘。
  ///
  /// 幂等与去重契约：
  /// 1. 若同 `sourceUrl` 已存在完成记录且本地文件仍然存在，直接返回已有任务 ID；
  /// 2. 若队列中已存在同 `sourceUrl` 的 queued/downloading 任务，合并返回已有任务 ID；
  /// 3. bytes 模式若无独立 sourceUrl，则按 `bytes:$fileName` 参与查重或直接入队；
  /// 4. 否则创建新任务加入队列，启动 FIFO worker 并返回新任务 ID。
  Future<String> enqueue({
    String? sourceUrl,
    Uint8List? bytes,
    required String fileName,
    String? mimeType,
    int? expectedBytes,
    String? sessionId,
  }) async {
    await _ensureInitialized();

    final isBytes =
        bytes != null || (sourceUrl != null && sourceUrl.startsWith('data:'));
    final effectiveUrl = sourceUrl ?? (isBytes ? 'bytes:$fileName' : '');
    if (!isBytes && effectiveUrl.isEmpty) {
      throw ArgumentError('必须提供 sourceUrl 或 bytes');
    }

    final effectiveExpectedBytes = expectedBytes ?? bytes?.length;
    final sourceType = isBytes
        ? DownloadSourceType.bytes
        : DownloadSourceType.url;

    // 1. 已完成且文件仍在检查
    final existingCompleted = state.tasks.where((t) {
      if (t.status != DownloadStatus.completed) return false;
      if (isBytes && (sourceUrl == null || sourceUrl.isEmpty)) {
        return t.sourceType == DownloadSourceType.bytes &&
            t.fileName == fileName;
      }
      return t.sourceUrl == effectiveUrl;
    }).firstOrNull;

    if (existingCompleted != null && existingCompleted.savedPath != null) {
      try {
        final file = File(existingCompleted.savedPath!);
        if (file.existsSync()) {
          DiagnosticsService.instance.log(
            level: DiagnosticsLogLevel.info,
            tag: 'downloads',
            message: '命中已完成任务且本地文件存在，跳过重复下载: ${existingCompleted.id}',
            details: {
              'id': existingCompleted.id,
              'sourceUrl': effectiveUrl,
              'savedPath': existingCompleted.savedPath,
            },
          );
          return existingCompleted.id;
        }
      } catch (_) {}
    }

    // 2. 队列中活跃同 URL 合并
    final existingActive = state.tasks.where((t) {
      if (!t.isActive) return false;
      if (isBytes && (sourceUrl == null || sourceUrl.isEmpty)) {
        return t.sourceType == DownloadSourceType.bytes &&
            t.fileName == fileName;
      }
      return t.sourceUrl == effectiveUrl;
    }).firstOrNull;

    if (existingActive != null) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'downloads',
        message: '队列中已存在同 sourceUrl 任务，合并至: ${existingActive.id}',
        details: {
          'id': existingActive.id,
          'sourceUrl': effectiveUrl,
          'status': existingActive.status.name,
        },
      );
      return existingActive.id;
    }

    // 3. 创建新任务加入队列
    final newTask = DownloadTask(
      id: uuidV4(),
      sourceUrl: effectiveUrl,
      fileName: fileName,
      mimeType: mimeType,
      expectedBytes: effectiveExpectedBytes,
      receivedBytes: 0,
      status: DownloadStatus.queued,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      sessionId: sessionId,
      sourceType: sourceType,
    );

    if (bytes != null) {
      _pendingBytes[newTask.id] = bytes;
    }

    _updateTask(newTask);
    await _repository.saveRecord(newTask);

    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'downloads',
      message: '加入下载队列: ${newTask.fileName}',
      details: {
        'id': newTask.id,
        'sourceUrl': newTask.sourceUrl,
        'fileName': newTask.fileName,
        'sourceType': newTask.sourceType.name,
      },
    );

    unawaited(_processQueue());
    return newTask.id;
  }

  /// 取消排队中或正在下载的任务。
  Future<void> cancel(String id) async {
    await _ensureInitialized();
    final task = state.taskById(id);
    if (task == null || task.isTerminal) return;

    _cancelledTaskIds.add(id);
    _pendingBytes.remove(id);

    final cancelledTask = task.copyWith(
      status: DownloadStatus.cancelled,
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _updateTask(cancelledTask);
    await _repository.saveRecord(cancelledTask);

    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'downloads',
      message: '任务已标记取消: $id',
      details: {'id': id, 'fileName': task.fileName},
    );
  }

  /// 重试失败或已取消的任务。
  Future<void> retry(String id) async {
    await _ensureInitialized();
    final task = state.taskById(id);
    if (task == null) return;
    if (task.status != DownloadStatus.failed &&
        task.status != DownloadStatus.cancelled) {
      return;
    }

    _cancelledTaskIds.remove(id);

    final retriedTask = task.copyWith(
      status: DownloadStatus.queued,
      receivedBytes: 0,
      failureMessage: null,
      completedAt: null,
      savedPath: null,
    );

    _updateTask(retriedTask);
    await _repository.saveRecord(retriedTask);

    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'downloads',
      message: '重试下载任务: $id',
      details: {'id': id, 'fileName': task.fileName},
    );

    unawaited(_processQueue());
  }

  /// 删除任务记录（若活跃则先取消）。
  Future<void> remove(String id) async {
    await _ensureInitialized();
    final task = state.taskById(id);
    if (task == null) return;

    _pendingBytes.remove(id);

    if (task.isActive) {
      await cancel(id);
    }

    state = state.copyWith(
      tasks: state.tasks.where((t) => t.id != id).toList(),
    );
    await _repository.deleteRecord(id);

    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'downloads',
      message: '移除下载记录: $id',
    );
  }

  /// 清空所有已终态的任务记录（completed / failed / cancelled）。
  Future<void> clearTerminalRecords() async {
    await _ensureInitialized();
    _pendingBytes.clear();
    final terminalTasks = state.tasks.where((t) => t.isTerminal).toList();
    for (final t in terminalTasks) {
      await _repository.deleteRecord(t.id);
    }
    state = state.copyWith(
      tasks: state.tasks.where((t) => !t.isTerminal).toList(),
    );
  }

  /// FIFO 单 worker 处理循环。
  Future<void> _processQueue() async {
    await _ensureInitialized();
    if (_isWorkerRunning) return;
    _isWorkerRunning = true;

    try {
      while (true) {
        final queuedTasks =
            state.tasks.where((t) => t.status == DownloadStatus.queued).toList()
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

        if (queuedTasks.isEmpty) break;
        final currentTask = queuedTasks.first;

        if (_cancelledTaskIds.contains(currentTask.id)) {
          _cancelledTaskIds.remove(currentTask.id);
          _pendingBytes.remove(currentTask.id);
          final cancelled = currentTask.copyWith(
            status: DownloadStatus.cancelled,
            completedAt: DateTime.now().millisecondsSinceEpoch,
          );
          _updateTask(cancelled);
          await _repository.saveRecord(cancelled);
          continue;
        }

        final downloading = currentTask.copyWith(
          status: DownloadStatus.downloading,
        );
        _updateTask(downloading);
        await _repository.saveRecord(downloading);

        try {
          DiagnosticsService.instance.log(
            level: DiagnosticsLogLevel.info,
            tag: 'downloads',
            message: '开始下载: ${currentTask.fileName}',
            details: {
              'id': currentTask.id,
              'sourceUrl': currentTask.sourceUrl,
              'fileName': currentTask.fileName,
              'expectedBytes': currentTask.expectedBytes,
              'sourceType': currentTask.sourceType.name,
            },
          );

          final Uint8List bytes;
          if (currentTask.sourceType == DownloadSourceType.bytes) {
            final memoryBytes = _pendingBytes.remove(currentTask.id);
            if (memoryBytes != null) {
              bytes = memoryBytes;
            } else if (currentTask.sourceUrl.startsWith('data:')) {
              final commaIdx = currentTask.sourceUrl.indexOf(',');
              if (commaIdx != -1) {
                bytes = base64Decode(
                  currentTask.sourceUrl.substring(commaIdx + 1),
                );
              } else {
                throw Exception('内存数据丢失且无效的 Data URI');
              }
            } else {
              throw Exception('内存数据已失效，无法重新下载');
            }
          } else {
            final uri = Uri.parse(currentTask.sourceUrl);
            // #69 真实进度回传：dio onReceiveProgress → 任务 receivedBytes，
            // 节流 ≥100ms 或 ≥1% 增量才刷 state（防高频重建）；total>0 且任务
            // 无 expectedBytes 时顺带补齐分母。
            var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
            var lastReceived = 0;
            bytes = await _downloader(
              uri,
              onProgress: (received, total) {
                if (received <= 0) return;
                final now = DateTime.now();
                final effectiveTotal = total > 0
                    ? total
                    : (currentTask.expectedBytes ?? -1);
                final timeHit =
                    now.difference(lastProgressAt).inMilliseconds >= 100;
                final sizeHit =
                    effectiveTotal <= 0 ||
                    (received - lastReceived) * 100 >= effectiveTotal;
                if (!timeHit && !sizeHit && received < effectiveTotal) return;
                lastProgressAt = now;
                lastReceived = received;
                final progressed = currentTask.copyWith(
                  status: DownloadStatus.downloading,
                  receivedBytes: received,
                  expectedBytes: effectiveTotal > 0 ? effectiveTotal : null,
                );
                _updateTask(progressed);
              },
            );
          }

          if (_cancelledTaskIds.contains(currentTask.id)) {
            _cancelledTaskIds.remove(currentTask.id);
            final cancelled = currentTask.copyWith(
              status: DownloadStatus.cancelled,
              receivedBytes: bytes.length,
              completedAt: DateTime.now().millisecondsSinceEpoch,
            );
            _updateTask(cancelled);
            await _repository.saveRecord(cancelled);
            DiagnosticsService.instance.log(
              level: DiagnosticsLogLevel.info,
              tag: 'downloads',
              message: '任务在下载中取消，丢弃结果: ${currentTask.id}',
            );
            continue;
          }

          final savedPath = await _saveService.save(
            fileName: currentTask.fileName,
            bytes: bytes,
            mimeType: currentTask.mimeType,
          );

          if (_cancelledTaskIds.contains(currentTask.id)) {
            _cancelledTaskIds.remove(currentTask.id);
            final cancelled = currentTask.copyWith(
              status: DownloadStatus.cancelled,
              receivedBytes: bytes.length,
              completedAt: DateTime.now().millisecondsSinceEpoch,
            );
            _updateTask(cancelled);
            await _repository.saveRecord(cancelled);
            continue;
          }

          final completed = currentTask.copyWith(
            status: DownloadStatus.completed,
            receivedBytes: bytes.length,
            savedPath: savedPath,
            completedAt: DateTime.now().millisecondsSinceEpoch,
            failureMessage: null,
          );
          _updateTask(completed);
          await _repository.saveRecord(completed);

          DiagnosticsService.instance.log(
            level: DiagnosticsLogLevel.info,
            tag: 'downloads',
            message: '下载完成: ${currentTask.fileName}',
            details: {
              'id': currentTask.id,
              'savedPath': savedPath,
              'byteSize': bytes.length,
            },
          );

          await _notificationService.notifyDownloadCompleted(
            completed.id,
            completed.fileName,
            bytes.length,
          );
        } catch (error) {
          if (_cancelledTaskIds.contains(currentTask.id)) {
            _cancelledTaskIds.remove(currentTask.id);
            final cancelled = currentTask.copyWith(
              status: DownloadStatus.cancelled,
              completedAt: DateTime.now().millisecondsSinceEpoch,
            );
            _updateTask(cancelled);
            await _repository.saveRecord(cancelled);
            continue;
          }

          final failed = currentTask.copyWith(
            status: DownloadStatus.failed,
            failureMessage: error.toString(),
            completedAt: DateTime.now().millisecondsSinceEpoch,
          );
          _updateTask(failed);
          await _repository.saveRecord(failed);

          DiagnosticsService.instance.log(
            level: DiagnosticsLogLevel.error,
            tag: 'downloads',
            message: '下载失败: ${currentTask.fileName}',
            details: {'id': currentTask.id, 'sourceUrl': currentTask.sourceUrl},
            errorKind: error.toString(),
          );
        }
      }
    } finally {
      _isWorkerRunning = false;
    }
  }

  void _updateTask(DownloadTask task) {
    final index = state.tasks.indexWhere((t) => t.id == task.id);
    if (index != -1) {
      final newTasks = List<DownloadTask>.from(state.tasks);
      newTasks[index] = task;
      state = state.copyWith(tasks: newTasks);
    } else {
      state = state.copyWith(tasks: [task, ...state.tasks]);
    }
  }
}
