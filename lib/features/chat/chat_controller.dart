import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/sse_client.dart';
import '../../core/cache/cache_providers.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/context_window_snapshot.dart';
import '../../core/models/json_value.dart';
import '../../core/models/message_attachment.dart';
import '../../core/models/session.dart';
import '../../core/models/tool_call.dart';
import '../../core/models/upload_response.dart';
import '../../core/utils/uuid.dart';
import '../../core/connections/connection_providers.dart';
import '../diagnostics/diagnostics_models.dart';
import '../diagnostics/diagnostics_service.dart';
import '../notifications/notification_providers.dart';
import '../session_list/session_list_providers.dart';
import '../settings/smooth_streaming_settings.dart';
import '../settings/tool_group_settings.dart';
import 'chat_diff_merge.dart';
import 'chat_models.dart';
import 'chat_providers.dart';
import 'chat_server_api.dart';
import 'chat_state.dart';

/// 回合完成 → 会话列表刷新的节流窗口。
///
/// 存量会话（非新建）回合完成也需刷新列表（#30）；窗口内多次完成
/// （同会话重复完成 / 并发多会话完成）合并为一次刷新，防高频抖动。
/// 不用 Timer 延迟触发（testWidgets/FakeAsync 下残留 Timer 会误报
/// "Timer still pending"），采用「前沿冷却 + 窗口内合并」的时间戳方案。
const Duration _sessionListRefreshThrottleWindow = Duration(milliseconds: 1500);

/// 聊天主控制器（chat_spec.md §1/§2：九态状态机 + 消息组装 + 断线恢复）。
///
/// 唯一写 `List<ChatMessage>` 的类；SSE 事件经 [_handleSseEvent] 同步串行
/// 处理；token 走「缓冲(16ms 合并) → 词级 reveal(48ms)」三段式；done 双重
/// 收尾；transportError 走「挂起 → status 检查 → 重连/replay/finalize」。
class ChatController extends FamilyNotifier<ChatState, String> {
  // -------------------------------------------------------------------------
  // 私有非状态（对齐 Swift @ObservationIgnored：Timer/游标不进 state）
  // -------------------------------------------------------------------------

  /// token 合并延迟（16ms）。
  static const mergeDelay = Duration(milliseconds: 16);

  /// 词级 reveal 间隔（标准档 64ms）。
  static const revealInterval = Duration(milliseconds: 64);

  /// 每 tick 最多 reveal 的词单元数（标准档 2）。
  static const maxWordUnitsPerTick = 2;

  /// reveal 最大滞后（标准档 3s；积压超过该时长一次性排空）。
  static const maxRevealLag = Duration(seconds: 3);

  /// reveal 队列词单元硬上限（超限直接落全文，防后台/锁屏积压爆吐卡死）。
  static const maxRevealQueueUnits = 2000;

  /// Live 流式期间上下文窗口读数轮询频率（2s）。
  static const contextWindowPollInterval = Duration(seconds: 2);

  ChatServerApi? _api;
  Timer? _mergeTimer;
  Timer? _revealTimer;
  Timer? _watchdogTimer;
  Timer? _transcriptRefreshTimer;
  Timer? _clarifyPollTimer;
  Timer? _reconnectTimer;

  /// 传输错误重连尝试次数（收到任意成功事件重置为 0）。
  int _reconnectAttempts = 0;

  /// 词级 reveal 队列（合并缓冲产出、逐 tick 消费）。
  final List<String> _revealQueue = [];

  /// live 时间线断点序列号（单调递增，用于渲染 key；新回合归零）。
  int _timelineSequence = 0;

  /// reveal 队列开始积压的时刻（最大滞后判定）。
  DateTime? _revealQueueStart;

  /// 最近一次内容新增（看门狗 5s 阈值）。
  DateTime? _lastProgress;

  /// 最近一次传输活动（看门狗 12s/18s/25s 阈值）。
  DateTime? _lastTransportActivity;

  /// 最近一次 live 上下文窗口轮询请求发起的时刻。
  DateTime? _lastContextPollTime;

  /// 标记是否有上下文轮询请求正在途中，防并发重复请求。
  bool _isContextPolling = false;

  /// status 轮询冷却截止。
  DateTime? _statusCheckCooldownUntil;

  /// 最近一次从后台/锁屏恢复的时刻（用于诊断统计 resume→首字耗时）。
  DateTime? _resumedAt;

  /// 异步操作代数守卫（防双 finalize / 覆盖新流）。
  int _generation = 0;

  bool _disposed = false;

  /// App 生命周期非 resumed（后台/锁屏/隐藏）期间暂停 reveal/merge 消费，
  /// resumed 后直接铺全文并重新校准看门狗基线。
  bool _appPaused = false;

  /// 重放期间是否需要逐帧重建时间线断点（仅断点为空的恢复场景为 true）。
  /// 正常 live 重连断点仍在：重放帧全命中时不再补点，避免已展示段在时间线
  /// 尾部重复叠加成簇（底部连续思考/文本卡簇的放大源）。
  bool _replayRebuildTimeline = false;

  /// SSE 连接当前是否存活（409 恢复路径判断是否需要重连）。
  bool _streamConnected = false;

  /// loadYoloState 一次性守卫（页面每次 build 都会触发，仅首次真正拉取）。
  bool _yoloLoaded = false;

  /// P4：新会话创建后待通过 done/stream_end 二次刷新的会话 id 集合。
  ///
  /// 仅用于「首轮完成后才落库」的异步后端：startChat 阶段已做立即+600ms
  /// 双次补拉，若服务端仍未落库，则在 done/stream_end 成功收尾时再做一次
  /// 强制刷新，避免用户需手动下拉。
  final Set<String> _pendingNewSessionIds = {};

  DateTime _now() => ref.read(chatClockProvider)();

  ChatWatchdogConfig get _watchdogConfig =>
      ref.read(chatWatchdogConfigProvider);

  bool get _coalesceTools => ref.read(toolGroupCoalesceProvider);

  bool get _smoothStreaming => ref.read(smoothStreamingProvider);

  SmoothStreamingSpeedPreset get _smoothStreamingSpeed =>
      ref.read(smoothStreamingSpeedProvider);

  List<PersistedToolCall>? _lastPersistedToolCalls;

  double _nowSeconds() => _now().millisecondsSinceEpoch / 1000;

  @override
  ChatState build(String sessionId) {
    _api = ref.read(chatApiProvider);
    _disposed = false;
    _streamConnected = false;
    _generation++;
    _lastProgress = null;
    _lastTransportActivity = null;
    _statusCheckCooldownUntil = null;
    _revealQueue.clear();
    _revealQueueStart = null;
    _appPaused = false;
    _lastContextPollTime = null;
    _isContextPolling = false;
    _startWatchdog();
    ref.onDispose(_dispose);
    // 后台/锁屏暂停 reveal 消费、resumed 铺全文并重新校准 watchdog 基线。
    ref.listen<AppLifecycleState>(appLifecycleStateProvider, (previous, next) {
      _handleAppLifecycleChange(previous, next);
    });
    ref.listen(toolGroupCoalesceProvider, (prev, next) {
      if (prev != next) {
        _recomputeToolGroups(next);
      }
    });
    ref.listen(smoothStreamingProvider, (prev, next) {
      if (prev != next && !next) {
        _flushPendingRevealToFullText();
      }
    });
    ref.listen(smoothStreamingSpeedProvider, (prev, next) {
      if (prev != next) {
        _handleSpeedPresetChanged();
      }
    });
    if (sessionId.isNotEmpty) {
      _startClarifyChannel(sessionId);
      // build 期间 state 未初始化，推迟到微任务再加载（读 state 安全）。
      scheduleMicrotask(() {
        if (_disposed) return;
        unawaited(loadMessages());
      });
    }
    return ChatState.initial(sessionId: sessionId);
  }

  void _recomputeToolGroups(bool coalesce) {
    final serverDerivedGroups = ToolCallGroup.groups(
      persistedToolCalls: _lastPersistedToolCalls ?? const [],
      messages: state.messages,
      messageOffset: state.messagesOffset,
      coalesce: coalesce,
    );
    if (serverDerivedGroups.isNotEmpty) {
      state = state.copyWith(completedToolCallGroups: serverDerivedGroups);
    } else if (state.completedToolCallGroups.isNotEmpty) {
      final nextToolGroups = ToolCallGroup.merging(
        primaryGroups: serverDerivedGroups,
        fallbackGroups: state.completedToolCallGroups,
      );
      state = state.copyWith(completedToolCallGroups: nextToolGroups);
    }
  }

  void _handleSpeedPresetChanged() {
    if (_revealTimer != null) {
      _revealTimer?.cancel();
      _revealTimer = null;
      if (_revealQueue.isNotEmpty && !_appPaused && _smoothStreaming) {
        _startRevealTimerIfNeeded();
      }
    }
  }

  void _dispose() {
    _disposed = true;
    _generation++;
    _mergeTimer?.cancel();
    _revealTimer?.cancel();
    _watchdogTimer?.cancel();
    _transcriptRefreshTimer?.cancel();
    _cancelReconnectTimer();
    _lastContextPollTime = null;
    _isContextPolling = false;
    _stopClarifyChannel();
    _api?.stopStream();
  }

  // -------------------------------------------------------------------------
  // 用户动作
  // -------------------------------------------------------------------------

  /// 发送新消息；流式期间按 [behavior] 处理（默认 steer）。
  ///
  /// [attachments] 为随消息一并提交的待发附件（已上传到服务端，
  /// 以 `{name, path, mime, size, is_image}` 传给 `/api/chat/start`）。
  Future<bool> send(
    String text, {
    StreamingSendBehavior behavior = StreamingSendBehavior.steer,
    List<PendingAttachment> attachments = const [],
  }) async {
    final current = state;
    if (current.isViewingCachedData) {
      _setSendError('Reconnect to the server to send a message.');
      return false;
    }
    _cancelReconnectTimer();
    _reconnectAttempts = 0;
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return false;
    if (current.stream.activeStreamId != null) {
      return _submitStreamingMessage(trimmed, behavior);
    }
    return _sendMessage(trimmed, attachments: attachments);
  }

  /// 停止当前响应（保留已流出文本，不删除）。
  Future<bool> stop() async {
    final streamId = state.stream.activeStreamId;
    if (streamId == null) return false;
    state = state.copyWith(stream: state.stream.copyWith(isCancelling: true));
    final gen = _generation;
    try {
      final response = await _api!.cancelChat(streamId);
      if (_disposed || gen != _generation) return false;
      if (response.ok == true || response.cancelled == true) {
        _finishStream(endPhase: ChatPhase.cancelled);
        return true;
      }
      state = state.copyWith(
        stream: state.stream.copyWith(isCancelling: false),
        sendErrorMessage: response.error ?? '服务器未能停止当前响应。',
      );
      return false;
    } on ApiException catch (error) {
      if (_disposed || gen != _generation) return false;
      state = state.copyWith(
        stream: state.stream.copyWith(isCancelling: false),
        sendErrorMessage: error.message,
      );
      return false;
    }
  }

  /// 显式选择模型（发送时带 explicit_model_pick）。
  void selectModel(String? model, {String? modelProvider}) {
    state = state.copyWith(
      model: model,
      clearModel: model == null,
      modelProvider: modelProvider,
      clearModelProvider: modelProvider == null,
      explicitModelPick: model != null,
    );
  }

  /// 清除当前展示的错误。
  void dismissError() {
    state = state.copyWith(
      clearSendErrorMessage: true,
      clearErrorMessage: true,
    );
  }

  /// 关闭离线缓存横幅。
  void dismissOfflineCache() {
    state = state.copyWith(isShowingOfflineCache: false);
  }

  /// 重命名当前会话，并立即更新聊天页标题。
  Future<bool> renameSession(String title) async {
    final trimmed = title.trim();
    if (state.sessionId.isEmpty || state.isReadOnly || trimmed.isEmpty) {
      return false;
    }
    try {
      final response = await _api!.renameSession(
        sessionId: state.sessionId,
        title: trimmed,
      );
      if (response.ok == false) {
        _setSendError(response.error ?? '重命名会话失败。');
        return false;
      }
      state = state.copyWith(displayTitle: trimmed);
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 更新当前会话的置顶状态。
  Future<bool> setPinned(bool pinned) => _mutateSession(
    () => _api!.pinSession(sessionId: state.sessionId, pinned: pinned),
    failure: '置顶状态更新失败。',
  );

  /// 更新当前会话的归档状态。
  Future<bool> setArchived(bool archived) => _mutateSession(
    () => _api!.archiveSession(sessionId: state.sessionId, archived: archived),
    failure: '归档状态更新失败。',
  );

  Future<bool> _mutateSession(
    Future<SessionMutationResponse> Function() request, {
    required String failure,
  }) async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    try {
      final response = await request();
      if (response.ok == false) {
        _setSendError(response.error ?? failure);
        return false;
      }
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 删除当前会话。
  Future<bool> deleteSession() async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    try {
      final response = await _api!.deleteSession(state.sessionId);
      if (response.ok == false) {
        _setSendError(response.error ?? '删除会话失败。');
        return false;
      }
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 从当前会话创建分支，返回新会话 ID。
  ///
  /// [keepCount] 非空时仅复制前 N 条消息（消息级分支）。
  Future<String?> branchSession({int? keepCount}) async {
    if (state.sessionId.isEmpty || state.isReadOnly) return null;
    try {
      final response = await _api!.branchSession(
        state.sessionId,
        keepCount: keepCount,
      );
      if (response.sessionId == null) {
        _setSendError(response.error ?? '创建会话分支失败。');
      }
      return response.sessionId;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return null;
    }
  }

  /// 从此处创建分支：保留 [messageIndex] 之前（含）的消息分支出新会话。
  Future<String?> branchAt(int messageIndex) async {
    final messages = state.messages;
    if (messageIndex < 0 || messageIndex >= messages.length) return null;
    return branchSession(keepCount: messageIndex + 1);
  }

  /// 压缩当前会话（可带聚焦主题）；成功后刷新消息列表并轻提示。
  Future<bool> compressSession({String? focusTopic}) async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    final trimmedTopic = focusTopic?.trim();
    try {
      final response = await _api!.compressSession(
        sessionId: state.sessionId,
        focusTopic: (trimmedTopic == null || trimmedTopic.isEmpty)
            ? null
            : trimmedTopic,
      );
      if (response.ok == false) {
        _setSendError(response.error ?? '压缩会话失败。');
        return false;
      }
      setNotice('会话已压缩');
      await loadMessages();
      // 对齐 Swift：用压缩摘要的 token 估算覆盖 snapshot 的 lastPromptTokens
      final estimate = response.summary?.compressedTokenEstimate;
      if (estimate != null && estimate > 0) {
        final prev = state.contextWindowSnapshot;
        if (prev != null) {
          state = state.copyWith(
            contextWindowSnapshot: prev.replacingTokensUsed(estimate),
          );
        } else {
          state = state.copyWith(
            contextWindowSnapshot: ContextWindowSnapshot(
              lastPromptTokens: estimate,
              contextLength: prev?.contextLength,
              thresholdTokens: prev?.thresholdTokens,
            ),
          );
        }
      }
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 从此处截断：保留 [messageIndex] 及其之前的全部消息，删除其后所有。
  ///
  /// 服务端 keep_count = index + 1（从开头保留条数）；越界或只读返回 false。
  Future<bool> truncateAt(int messageIndex) async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    final messages = state.messages;
    if (messageIndex < 0 || messageIndex >= messages.length) return false;
    final keepCount = messageIndex + 1;
    try {
      final response = await _api!.truncateSession(
        sessionId: state.sessionId,
        keepCount: keepCount,
      );
      if (response.session == null) {
        _setSendError('截断会话失败。');
        return false;
      }
      await loadMessages();
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 用 [text] 预填输入框（编辑/重试复用；不自动发送）。
  void prefillComposer(String text) {
    if (state.sessionId.isEmpty || state.isReadOnly) return;
    state = state.copyWith(composerPrefill: text);
  }

  /// 撤销上一轮（删除最后一轮用户消息及其后全部）；成功后刷新消息列表。
  Future<bool> undoLastTurn() async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    try {
      final response = await _api!.undoSession(state.sessionId);
      if (response.ok == false) {
        _setSendError(response.error ?? '撤销上一轮失败。');
        return false;
      }
      await loadMessages();
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 重试上一轮：服务端删除最后一轮并返回该轮用户消息原文。
  ///
  /// 成功时把文本写入 [ChatState.composerPrefill]（UI 回填输入框，不自动发送），
  /// 并刷新消息列表；返回该文本供调用方直接使用。
  Future<String?> retryLastTurn() async {
    if (state.sessionId.isEmpty || state.isReadOnly) return null;
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat',
      message: 'Retrying last turn for session: ${state.sessionId}',
    );
    try {
      final response = await _api!.retrySession(state.sessionId);
      final lastText = response.lastUserText;
      if (response.ok == false || lastText == null || lastText.isEmpty) {
        _setSendError(response.error ?? '重试上一轮失败。');
        return null;
      }
      state = state.copyWith(composerPrefill: lastText);
      await loadMessages();
      return lastText;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return null;
    }
  }

  /// 更新会话设置（workspace / model）；成功后乐观更新本地元数据并轻提示。
  ///
  /// 模型列表由 [chatAvailableModelsProvider] 注入、无服务端状态可刷新，
  /// 这里仅同步 state.model/modelProvider 供后续发送使用。
  Future<bool> updateSessionSettings({String? workspace, String? model}) async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    final trimmedWorkspace = workspace?.trim();
    final trimmedModel = model?.trim();
    try {
      final response = await _api!.updateSession(
        sessionId: state.sessionId,
        workspace: (trimmedWorkspace == null || trimmedWorkspace.isEmpty)
            ? null
            : trimmedWorkspace,
        model: (trimmedModel == null || trimmedModel.isEmpty)
            ? null
            : trimmedModel,
      );
      final updated = response.session;
      state = state.copyWith(
        workspace: updated?.workspace ?? trimmedWorkspace ?? state.workspace,
        model: updated?.model ?? trimmedModel ?? state.model,
        modelProvider: updated?.modelProvider ?? state.modelProvider,
      );
      setNotice('设置已保存');
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 切换 YOLO 模式；成功后乐观更新开关状态。
  Future<bool> toggleYolo(bool enabled) async {
    if (state.sessionId.isEmpty || state.isReadOnly) return false;
    try {
      final response = await _api!.setYolo(
        sessionId: state.sessionId,
        enabled: enabled,
      );
      if (response.ok == false) {
        _setSendError('YOLO 状态更新失败。');
        return false;
      }
      state = state.copyWith(yoloEnabled: response.yoloEnabled ?? enabled);
      return true;
    } on ApiException catch (error) {
      _setSendError(error.message);
      return false;
    }
  }

  /// 拉取当前会话 YOLO 状态（页面初始化调用；一次性守卫，失败静默）。
  Future<void> loadYoloState() async {
    if (_yoloLoaded || state.sessionId.isEmpty) return;
    _yoloLoaded = true;
    final gen = _generation;
    try {
      final response = await _api!.getYolo(state.sessionId);
      if (_disposed || gen != _generation) return;
      if (response.yoloEnabled != null) {
        state = state.copyWith(yoloEnabled: response.yoloEnabled);
      }
    } on ApiException {
      // YOLO 状态拉取失败静默（保持关闭默认值）。
    }
  }

  /// 加载更早的消息（分页）。
  Future<void> loadOlderMessages() async {
    final offset = state.messagesOffset;
    if (offset <= 0) return;
    await loadMessages(messageBefore: offset);
  }

  /// 跨端/跨设备聊天记录同步补齐（diff patch 类 VDOM 思路）。
  ///
  /// 从服务器拉取最新消息并与本地 [state.messages] 进行 diff 合并，
  /// 补全缺失消息、原地更新已变化消息，静默容错不弹全局错误。
  Future<void> syncMissingMessages({int limit = 50}) async {
    final sessionId = state.sessionId;
    if (sessionId.isEmpty || _disposed) return;
    final api = _api;
    if (api == null) return;
    // 若当前正在发送或流式接收中，避免与实时消息状态竞争
    if (state.stream.activeStreamId != null ||
        state.phase == ChatPhase.streaming ||
        state.phase == ChatPhase.sending) {
      return;
    }
    final gen = _generation;
    try {
      final response = await api.session(
        sessionId: sessionId,
        includeMessages: true,
        messageLimit: limit,
        expandRenderable: true,
      );
      if (_disposed || gen != _generation) return;
      final detail = response.session;
      if (detail == null) return;
      final serverMessages = detail.messages ?? const <ChatMessage>[];
      final mergedMessages = diffMergeMessages(
        localMessages: state.messages,
        serverMessages: serverMessages,
      );
      _applySessionDetail(detail: detail, mergedMessages: mergedMessages);
    } on Object {
      // 同步失败静默容错（不弹全局错误）
    }
  }

  /// 加载会话 transcript（冷启动 / 重载 / 分页）。
  Future<void> loadMessages({int? messageBefore}) async {
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return;
    final api = _api;
    if (api == null) return;
    final gen = _generation;
    try {
      final response = await api.session(
        sessionId: sessionId,
        includeMessages: true,
        messageLimit: 50,
        messageBefore: messageBefore,
        expandRenderable: messageBefore == null,
      );
      if (_disposed || gen != _generation) return;
      final detail = response.session;
      if (detail == null) return;
      final loaded = detail.messages ?? const <ChatMessage>[];
      if (messageBefore != null) {
        final existingIds = state.messages
            .map((m) => m.messageId)
            .whereType<String>()
            .toSet();
        final existingFingerprints = state.messages
            .where((m) => m.messageId == null)
            .map((m) => '${m.role}:${m.timestamp}:${m.content}')
            .toSet();
        final fresh = loaded.where((m) {
          if (m.messageId != null) {
            return !existingIds.contains(m.messageId);
          }
          return !existingFingerprints.contains(
            '${m.role}:${m.timestamp}:${m.content}',
          );
        }).toList();
        final allMessages = [...fresh, ...state.messages];
        final fallbackOffset = state.messagesOffset - loaded.length;
        final newOffset =
            detail.messagesOffset ?? (fallbackOffset < 0 ? 0 : fallbackOffset);
        final persistedToolCalls =
            detail.toolCalls ?? const <PersistedToolCall>[];
        _lastPersistedToolCalls = persistedToolCalls;
        final serverDerivedGroups = ToolCallGroup.groups(
          persistedToolCalls: persistedToolCalls,
          messages: allMessages,
          messageOffset: newOffset,
          coalesce: _coalesceTools,
        );
        final nextToolGroups = ToolCallGroup.merging(
          primaryGroups: serverDerivedGroups,
          fallbackGroups: state.completedToolCallGroups,
        );
        final serverDerivedReasoning = ReasoningGroup.groups(
          messages: allMessages,
          messageOffset: newOffset,
        );
        final nextReasoningGroups = ReasoningGroup.merging(
          primaryGroups: serverDerivedReasoning,
          fallbackGroups: state.completedReasoningGroups,
        );
        state = state.copyWith(
          messages: allMessages,
          messagesOffset: newOffset,
          hasOlderMessages:
              detail.messageCount != null &&
              detail.messageCount! > state.messages.length + fresh.length,
          completedToolCallGroups: nextToolGroups,
          completedReasoningGroups: nextReasoningGroups,
        );
      } else {
        // 全量重载：diff-merge 调和本地与服务端消息
        // 若当前展示的是离线缓存回放数据，fresh 在线消息直接替换旧缓存
        final local = state.isViewingCachedData
            ? const <ChatMessage>[]
            : state.messages;
        final mergedMessages = diffMergeMessages(
          localMessages: local,
          serverMessages: loaded,
        );
        _applySessionDetail(detail: detail, mergedMessages: mergedMessages);
      }
    } on ApiException catch (error) {
      if (_disposed || gen != _generation) return;
      if (messageBefore == null && ApiException.shouldUseCache(error)) {
        List<Map<String, Object?>> cachedMaps = const [];
        try {
          cachedMaps = await ref
              .read(cacheServiceProvider)
              .readMessages(sessionId);
        } catch (_) {
          // 缓存读取异常静默，继续维持无缓存错误态
        }
        if (cachedMaps.isNotEmpty) {
          final parsed = cachedMaps
              .map((map) => ChatMessage.fromJson(map))
              .toList(growable: true);
          final hasTimestamps = parsed.any(
            (m) => m.timestamp != null && m.timestamp! > 0,
          );
          final List<ChatMessage> cachedMessages;
          if (hasTimestamps) {
            parsed.sort((a, b) {
              final tsA = a.timestamp ?? 0;
              final tsB = b.timestamp ?? 0;
              return tsA.compareTo(tsB);
            });
            cachedMessages = parsed;
          } else {
            // readMessages 按 cachedAt 倒序返回，反转恢复时间正序
            cachedMessages = parsed.reversed.toList(growable: false);
          }
          _lastPersistedToolCalls = const [];
          final serverDerivedGroups = ToolCallGroup.groups(
            persistedToolCalls: const [],
            messages: cachedMessages,
            messageOffset: 0,
            coalesce: _coalesceTools,
          );
          final serverDerivedReasoning = ReasoningGroup.groups(
            messages: cachedMessages,
            messageOffset: 0,
          );
          state = state.copyWith(
            messages: cachedMessages,
            completedToolCallGroups: serverDerivedGroups,
            completedReasoningGroups: serverDerivedReasoning,
            isViewingCachedData: true,
            isShowingOfflineCache: true,
            clearErrorMessage: true,
            clearSendErrorMessage: true,
          );
          return;
        }
      }
      // 无缓存或非网络类错误（401/业务错误）：保持现状错误态
      state = state.copyWith(errorMessage: error.message);
    }
  }

  void _applySessionDetail({
    required SessionDetail detail,
    required List<ChatMessage> mergedMessages,
  }) {
    final persistedToolCalls = detail.toolCalls ?? const <PersistedToolCall>[];
    _lastPersistedToolCalls = persistedToolCalls;
    final newOffset = detail.messagesOffset ?? state.messagesOffset;
    final serverDerivedGroups = ToolCallGroup.groups(
      persistedToolCalls: persistedToolCalls,
      messages: mergedMessages,
      messageOffset: newOffset,
      coalesce: _coalesceTools,
    );
    final serverDerivedReasoning = ReasoningGroup.groups(
      messages: mergedMessages,
      messageOffset: newOffset,
    );
    List<ToolCallGroup> nextCompletedGroups;
    List<ToolCall> nextLiveToolCalls = state.liveToolCalls;
    final String nextLiveReasoning = state.liveReasoningText;
    final hasServerTools =
        persistedToolCalls.isNotEmpty || serverDerivedGroups.isNotEmpty;
    if (hasServerTools) {
      // 服务端 transcript 已含工具 → 以服务端为准合并已有完成组保底，live 清空。
      nextCompletedGroups = ToolCallGroup.merging(
        primaryGroups: serverDerivedGroups,
        fallbackGroups: state.completedToolCallGroups,
      );
      nextLiveToolCalls = const [];
    } else {
      if (state.liveToolCalls.isNotEmpty) {
        final anchor =
            state.stream.toolCallAnchorMessageId ??
            state.stream.streamingAssistantMessageId ??
            _lastAssistantMessageId(mergedMessages);
        final liveGroup = ToolCallGroup.live(
          anchorMessageID: anchor,
          toolCalls: List<ToolCall>.of(state.liveToolCalls),
        );
        nextCompletedGroups = ToolCallGroup.merging(
          primaryGroups: state.completedToolCallGroups,
          fallbackGroups: [liveGroup],
        );
        // live 时间线需要保留 liveToolCalls 继续切片展示（重连/恢复场景）；
        // 归档组仅作流式结束后的 transcript fallback，不双显（transcript 会跳过
        // 流式消息自身）。
      } else {
        nextCompletedGroups = state.completedToolCallGroups;
      }
    }

    final liveReasoningList = <ReasoningGroup>[];
    if (state.liveReasoningText.isNotEmpty) {
      final anchor =
          state.stream.reasoningAnchorMessageId ??
          state.stream.streamingAssistantMessageId ??
          _lastAssistantMessageId(mergedMessages);
      liveReasoningList.add(
        ReasoningGroup(anchorMessageId: anchor, text: state.liveReasoningText),
      );
      // 同工具：保留 liveReasoningText 供 live 时间线切片，档案组仅收尾 fallback。
    }
    var nextCompletedReasoning = ReasoningGroup.merging(
      primaryGroups: serverDerivedReasoning,
      fallbackGroups: [...state.completedReasoningGroups, ...liveReasoningList],
    );
    // 历史思考归档：从已加载消息的 reasoning 字段提取，补入 completedReasoningGroups
    final persistedReasoning = _reasoningGroupsFromMessages(
      mergedMessages,
      newOffset,
    );
    if (persistedReasoning.isNotEmpty) {
      final existingAnchors = nextCompletedReasoning
          .map((g) => '${g.anchorMessageId ?? ''}:${g.text}')
          .toSet();
      for (final g in persistedReasoning) {
        final key = '${g.anchorMessageId ?? ''}:${g.text}';
        if (!existingAnchors.contains(key)) {
          nextCompletedReasoning = [...nextCompletedReasoning, g];
        }
      }
    }

    state = state.copyWith(
      messages: mergedMessages,
      messagesOffset: detail.messagesOffset ?? state.messagesOffset,
      hasOlderMessages:
          detail.messageCount != null &&
          detail.messageCount! > mergedMessages.length,
      displayTitle: _resolveTitle(detail),
      workspace: detail.workspace ?? state.workspace,
      model: detail.model ?? state.model,
      modelProvider: detail.modelProvider ?? state.modelProvider,
      profile: detail.profile ?? state.profile,
      isReadOnly: detail.readOnly == true || detail.isReadOnly == true,
      hasPendingUserMessage:
          detail.pendingUserMessage?.trim().isNotEmpty == true ||
          detail.pendingAttachments?.isNotEmpty == true,
      parentSessionId: detail.parentSessionId,
      contextWindowSnapshot: ContextWindowSnapshot(
        contextLength: detail.contextLength,
        thresholdTokens: detail.thresholdTokens,
        lastPromptTokens: detail.lastPromptTokens,
        inputTokens: detail.inputTokens,
        outputTokens: detail.outputTokens,
        estimatedCost: detail.estimatedCost,
        tokensPerSecond:
            state.stream.liveTokensPerSecond ??
            state.contextWindowSnapshot?.tokensPerSecond,
      ),
      completedToolCallGroups: nextCompletedGroups,
      liveToolCalls: nextLiveToolCalls,
      completedReasoningGroups: nextCompletedReasoning,
      liveReasoningText: nextLiveReasoning,
      responseCompletionNeedsTranscriptRefresh: false,
      isViewingCachedData: false,
      isShowingOfflineCache: false,
    );
    unawaited(_writeCacheMessages(state.sessionId, mergedMessages));
    final activeStreamId = detail.activeStreamId;
    if (activeStreamId != null &&
        activeStreamId.isNotEmpty &&
        state.stream.activeStreamId == null) {
      _lastContextPollTime = _now();
      state = state.copyWith(
        phase: ChatPhase.streaming,
        stream: state.stream.copyWith(activeStreamId: activeStreamId),
      );
      _syncSessionStreaming(
        state.sessionId,
        true,
        activeStreamId: activeStreamId,
      );
      unawaited(_reconnectIfNeeded());
    }
  }

  /// done 后补拉 transcript：status → active==false → loadMessages。
  Future<void> refreshTranscriptIfCompleted(String streamId) async {
    // 已开启新流则跳过；无流（已完成）或仍是旧流则继续。
    if (state.stream.activeStreamId != null &&
        state.stream.activeStreamId != streamId) {
      return;
    }
    final gen = _generation;
    try {
      final status = await _api!.chatStreamStatus(streamId);
      if (_disposed || gen != _generation) return;
      if (status.active == true) return; // 仍在流中，稍后再试
      await loadMessages();
      if (_disposed || gen != _generation) return;
      state = state.copyWith(responseCompletionNeedsTranscriptRefresh: false);
    } on ApiException {
      // 状态检查失败：静默（下次会话加载会补上）。
    }
  }

  /// 审批卡片作答。
  Future<bool> respondToApproval(String choice) async {
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return false;
    final gen = _generation;
    try {
      await _api!.respondApproval(sessionId: sessionId, choice: choice);
      if (_disposed || gen != _generation) return false;
      _clearApprovalCard();
      return true;
    } on ApiException {
      if (_disposed || gen != _generation) return false;
      return false;
    }
  }

  /// 澄清卡片作答。
  Future<bool> respondToClarification(String response) async {
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return false;
    final gen = _generation;
    try {
      await _api!.respondClarification(
        sessionId: sessionId,
        response: response,
      );
      if (_disposed || gen != _generation) return false;
      _clearClarificationCard();
      return true;
    } on ApiException {
      if (_disposed || gen != _generation) return false;
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 发送内部实现
  // -------------------------------------------------------------------------

  Future<bool> _sendMessage(
    String text, {
    List<PendingAttachment> attachments = const [],
  }) async {
    final api = _api;
    if (api == null) return false;
    _archiveLiveReasoningIfNeeded();
    _archiveLiveToolCallsIfNeeded();
    final messageId = 'local-${uuidV4()}';
    final optimistic = ChatMessage(
      role: 'user',
      content: text,
      messageId: messageId,
      timestamp: _nowSeconds(),
      // 乐观消息直接带附件元数据：发送后立即可见附件卡片（对齐 WebUI 回显行为，
      // 服务端重放后由 attachments/文本标记再次兜底）。
      attachments: attachments.isEmpty
          ? null
          : [
              for (final a in attachments)
                MessageAttachment(
                  name: a.name,
                  path: a.path,
                  mime: a.mime,
                  size: a.size,
                  isImage: a.isImage,
                ),
            ],
    );
    state = state.copyWith(
      phase: ChatPhase.sending,
      messages: [...state.messages, optimistic],
      clearSendErrorMessage: true,
      clearErrorMessage: true,
      clearPrefillStatus: true,
      clearPrefillLabel: true,
      turnStartedMillis: _now().millisecondsSinceEpoch,
    );
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat',
      message:
          'Message sending initiated (phase: sending, session: ${state.sessionId})',
    );
    final gen = ++_generation;
    try {
      final response = await api.startChat(
        sessionId: state.sessionId,
        message: text,
        workspace: state.workspace,
        model: state.model,
        modelProvider: state.modelProvider,
        profile: state.profile,
        explicitModelPick: state.explicitModelPick,
        attachments: attachments.isEmpty
            ? null
            : [
                for (final a in attachments)
                  a.toJsonValue().toJson() as Map<String, Object?>,
              ],
      );
      if (_disposed || gen != _generation) return false;
      final streamId = response.streamId;
      final sessionId = response.sessionId;
      if (streamId == null || streamId.isEmpty) {
        _rollbackOptimisticMessage(messageId);
        state = state.copyWith(
          phase: ChatPhase.idle,
          sendErrorMessage: response.error ?? '服务器未返回流 ID，发送失败。',
          clearTurnStartedMillis: true,
        );
        return false;
      }
      if (sessionId != null &&
          sessionId.isNotEmpty &&
          state.sessionId.isEmpty) {
        final newSessionId = sessionId;
        state = state.copyWith(sessionId: newSessionId);
        _onNewSessionCreated(newSessionId, text);
        _startClarifyChannel(newSessionId);
      }
      _beginStream(streamId);
      return true;
    } on ApiException catch (error) {
      if (_disposed || gen != _generation) return false;
      if (error is HttpException && error.indicatesActiveStream) {
        // 409 已有活动流：服务端未接受本条消息 → 回滚 → 接管已有流。
        _rollbackOptimisticMessage(messageId);
        await _recoverExistingStream(error.activeStreamId!);
        return false;
      }
      _rollbackOptimisticMessage(messageId);
      state = state.copyWith(
        phase: ChatPhase.idle,
        sendErrorMessage: error.message,
        clearTurnStartedMillis: true,
      );
      return false;
    }
  }

  /// 流式期间发送：steer / interrupt / queue 三行为（chat_spec.md §4.2）。
  Future<bool> _submitStreamingMessage(
    String text,
    StreamingSendBehavior behavior,
  ) async {
    switch (behavior) {
      case StreamingSendBehavior.steer:
        return _steer(text);
      case StreamingSendBehavior.interrupt:
        state = state.copyWith(
          queuedSlashMessages: [text, ...state.queuedSlashMessages],
        );
        final stopped = await stop();
        if (!stopped && state.stream.activeStreamId != null) {
          _pinNotice(
            'Could not stop the current response — your message is queued for the next turn.',
          );
        }
        return false;
      case StreamingSendBehavior.queue:
        state = state.copyWith(
          queuedSlashMessages: [...state.queuedSlashMessages, text],
        );
        _pinNotice(
          'Queued for next turn (#${state.queuedSlashMessages.length})',
        );
        return false;
    }
  }

  Future<bool> _steer(String text) async {
    final gen = _generation;
    try {
      final response = await _api!.steerChat(
        sessionId: state.sessionId,
        text: text,
      );
      if (_disposed || gen != _generation) return false;
      if (response.accepted == true) {
        _markProgress();
        state = state.copyWith(
          phase: ChatPhase.steered,
          steerHints: [...state.steerHints, text],
        );
        return true;
      }
      _queueSteerFailure(text);
      unawaited(cancelActiveStream());
      return false;
    } on ApiException {
      if (_disposed || gen != _generation) return false;
      _queueSteerFailure(text);
      unawaited(cancelActiveStream());
      return false;
    }
  }

  void _queueSteerFailure(String text) {
    state = state.copyWith(
      queuedSlashMessages: [...state.queuedSlashMessages, text],
      pinnedLocalNotices: [
        ...state.pinnedLocalNotices,
        'Steer was unavailable — your message has been queued for the next turn.',
      ],
    );
  }

  /// 停止当前流（steer 失败路径；finishStream 会顺次发送队列）。
  Future<void> cancelActiveStream() async {
    final streamId = state.stream.activeStreamId;
    if (streamId == null) return;
    await _api?.cancelChat(streamId);
    if (_disposed) return;
    _notifySessionError('响应已取消', state.displayTitle);
    _finishStream(endPhase: ChatPhase.cancelled);
  }

  /// 流结束后顺次发送队列首条（发送失败回队首并停止连锁，防死循环）。
  Future<void> _drainQueuedSlashMessage() async {
    final queued = state.queuedSlashMessages;
    if (queued.isEmpty) return;
    if (state.stream.activeStreamId != null) return;
    final next = queued.first;
    state = state.copyWith(queuedSlashMessages: queued.sublist(1));
    final sent = await _sendMessage(next);
    if (!sent) {
      state = state.copyWith(
        queuedSlashMessages: [next, ...state.queuedSlashMessages],
      );
    }
  }

  void _beginStream(String streamId) {
    _timelineSequence = 0;
    _replayRebuildTimeline = false;
    state = state.copyWith(
      phase: ChatPhase.streaming,
      clearSendErrorMessage: true,
      clearErrorMessage: true,
      clearPrefillStatus: true,
      clearPrefillLabel: true,
      liveTimelinePoints: const [],
      turnStartedMillis:
          state.turnStartedMillis ?? _now().millisecondsSinceEpoch,
      stream: state.stream.copyWith(
        activeStreamId: streamId,
        isSuspended: false,
        recovery: ActiveStreamRecoveryState.idle,
        hasCompletedResponse: false,
        isCancelling: false,
        clearLastEventId: true,
        isReplayConnection: false,
        matchedPrefixLength: 0,
        matchedReasoningLength: 0,
        replayToolMatchIndex: 0,
        replayAfterSeq: 0,
      ),
      pendingAction: const ChatPendingActionState(),
      responseCompletionNeedsTranscriptRefresh: false,
    );
    // 空流式气泡立即锚定（思考中指示器依赖它）。
    _ensureStreamingAssistantMessage();
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat',
      message:
          'Stream started (phase: streaming, streamId: $streamId, session: ${state.sessionId})',
    );
    _syncSessionStreaming(
      state.sessionId,
      true,
      activeStreamId: streamId,
      verifyInBackground: true,
    );
    _connectStream(streamId);
    _lastContextPollTime = _now();
    _markProgress();
    _recordTransportActivity();
  }

  /// 建立 SSE 连接。replayAfterSeq → `?replay=1&after_seq=N`（保留 lastEventID）；
  /// [fullReconnect] → 不带 replay 参数但从 0 重放（靠 §6.4 去重）。
  void _connectStream(
    String streamId, {
    int? replayAfterSeq,
    bool fullReconnect = false,
  }) {
    final api = _api;
    if (api == null) return;
    if (_streamConnected || replayAfterSeq != null || fullReconnect) {
      api.stopStream();
      _streamConnected = false;
    }
    final useReplay = replayAfterSeq != null || fullReconnect;
    final effectiveReplayAfterSeq =
        replayAfterSeq ??
        (fullReconnect ? _replayAfterSeq(state.stream.lastEventId) : 0);
    state = state.copyWith(
      // 旧时间线断点保留（见 _replayRebuildTimeline 语义）：重放帧对已展示
      // 内容不再向尾部叠加重复断点，成簇卡片的放大源被切断。
      stream: state.stream.copyWith(
        isReplayConnection: useReplay,
        matchedPrefixLength: 0,
        matchedReasoningLength: 0,
        replayToolMatchIndex: 0,
        replayAfterSeq: effectiveReplayAfterSeq,
        clearLastEventId: true,
      ),
    );
    // 重放是否需要逐帧重建时间线：仅「断点为空的恢复场景」（如重启后 resume，
    // 断点丢失但内容已在服务端占位行中）需要；正常 live 重连时断点仍在，
    // 重放帧全命中时若再补点，会把已展示段重复叠加到时间线尾部（卡簇）。
    // 工具断点依赖 _appendToolCall 正常路径，此处旗标只约束 text/think 补点。
    _replayRebuildTimeline = useReplay && state.liveTimelinePoints.isEmpty;
    _streamConnected = true;
    unawaited(
      api.startStream(
        streamId,
        replayAfterSeq: replayAfterSeq,
        onEvent: _handleSseEvent,
        onEventId: (id) {
          if (_disposed) return;
          _resetReconnectBackoff();
          state = state.copyWith(
            stream: state.stream.copyWith(lastEventId: id),
          );
          _recordTransportActivity();
        },
        onTransportError: (message) {
          if (_disposed) return;
          _streamConnected = false;
          _handleTransportError(message);
        },
        onClosed: () {
          _streamConnected = false;
          _recordTransportActivity();
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // SSE 事件分发（同步串行；先记录传输活动，有新增再 markProgress）
  // -------------------------------------------------------------------------

  void _handleSseEvent(SseEvent event) {
    if (_disposed) return;
    _recordTransportActivity();
    _resetReconnectBackoff();
    final stream = state.stream;
    if (stream.isReplayConnection && stream.replayAfterSeq > 0) {
      final currentSeq = _replayAfterSeq(stream.lastEventId);
      if (currentSeq > 0 && currentSeq <= stream.replayAfterSeq) {
        // 重连回放帧：seq <= replayAfterSeq 说明断线前已处理过，
        // 幂等忽略内容帧（token / interim / reasoning / tool / steer），
        // 避免重复推流和 UI 闪动。心跳与终结事件仍正常分发。
        switch (event) {
          case TokenSseEvent() ||
              InterimAssistantSseEvent() ||
              ReasoningSseEvent() ||
              ToolStartedSseEvent() ||
              ToolCompletedSseEvent() ||
              PendingSteerLeftoverSseEvent():
            return;
          default:
            break;
        }
      }
    }
    switch (event) {
      case TokenSseEvent(:final text):
        if (_appendAssistantToken(text)) _markProgress();
      case InterimAssistantSseEvent(:final text, :final alreadyStreamed):
        _handleInterimAssistant(text, alreadyStreamed);
      case ReasoningSseEvent(:final text):
        if (_appendReasoning(text)) _markProgress();
      case ToolStartedSseEvent(:final event):
        _appendToolCall(event);
      case ToolCompletedSseEvent(:final event):
        _completeToolCall(event);
      case TitleSseEvent(:final sessionId, :final title):
        _handleTitle(sessionId, title);
      case MeteringSseEvent(
        :final tps,
        :final tpsAvailable,
        :final estimated,
        :final sessionId,
      ):
        _handleMetering(
          tps: tps,
          tpsAvailable: tpsAvailable,
          estimated: estimated,
          sessionId: sessionId,
        );
      case DoneSseEvent(:final event):
        _applyDone(event);
      case ContextStatusSseEvent(:final status, :final label):
        _handleContextStatus(status, label);
      case ApprovalPendingSseEvent(:final payload):
        _applyApprovalUpdate(payload);
      case ClarificationPendingSseEvent(:final payload):
        _applyClarificationUpdate(payload);
      case PendingSteerLeftoverSseEvent(:final text):
        _handlePendingSteerLeftover(text);
      case StreamEndSseEvent():
        _handleStreamEnd();
      case CancelledSseEvent():
        _handleCancelled();
      case ErrorSseEvent(:final message):
        _handleErrorEvent(message);
      case TransportErrorSseEvent(:final message):
        _handleTransportError(message);
      case HeartbeatSseEvent():
        _handleHeartbeat();
      case IgnoredSseEvent():
        break;
    }
  }

  // -------------------------------------------------------------------------
  // token 三段式缓冲（合并 → 词级 reveal）
  // -------------------------------------------------------------------------

  /// 去重（replay 连接）→ 入 pendingAssistantTokenChunks → 调度 16ms 合并。
  /// 返回是否有真实新增（看门狗进度信号）。
  bool _appendAssistantToken(String text) {
    if (text.isEmpty) return false;
    var remainder = text;
    final stream = state.stream;
    if (stream.isReplayConnection) {
      // 打点前记录匹配游标：重放帧即使全命中（remainder 空），也要用它
      // 重建 text 段断点（该帧在最终 content 中的起点）。
      final prevCursor = stream.matchedPrefixLength;
      final deduped = deduplicatedReplayToken(
        token: text,
        existingContent: _currentStreamingContent(),
        matchedPrefixLength: stream.matchedPrefixLength,
      );
      remainder = deduped.remainder;
      state = state.copyWith(
        stream: state.stream.copyWith(
          matchedPrefixLength: deduped.newCursor,
          isReplayConnection: deduped.stillReplay,
        ),
      );
      if (remainder.isEmpty) {
        // 重放帧（fullReconnect 从 0 重放）文本全部命中断线前已 flush 的内容：
        // 内容不再追加。断点补建仅在「断点为空的恢复场景」（
        // _replayRebuildTimeline）执行，避免时间线为空 + 归档锚定 →
        // liveTimeline=null → 旧分组式气泡沉底；正常 live 重连断点仍在，
        // 此时补点会把已展示段重复叠加到时间线尾部（成簇卡片）。
        if (_replayRebuildTimeline) {
          _ensureTimelinePoint(LiveSegmentKind.text, prevCursor);
        }
        return false;
      }
    }
    // 时间线断点：在「事件到达」时记录（而非 flush 时），保证与真实事件顺序一致；
    // start 取缓冲全量（content + 待合并 + 待揭示），使切片与最终 content 对齐。
    _ensureTimelinePoint(
      LiveSegmentKind.text,
      _currentStreamingContent().length,
    );
    state = state.copyWith(
      pendingAssistantTokenChunks: [
        ...state.pendingAssistantTokenChunks,
        remainder,
      ],
    );
    if (_resumedAt != null) {
      final elapsed = _now().difference(_resumedAt!);
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'chat_resume',
        message:
            'First token received after resume in ${elapsed.inMilliseconds}ms',
      );
      _resumedAt = null;
    }
    _scheduleMerge();
    return true;
  }

  /// 生命周期变化处理（修复①背景/锁屏暂停消费 + 修复③watchdog 基线校准）。
  ///
  /// - 非 resumed（后台/锁屏/隐藏）：暂停 16ms 合并与 48ms 逐词 reveal 消费，
  ///   避免后台空转 CPU 与解锁后积压爆吐。
  /// - resumed：先直接铺全文（积压缓冲一次性落消息），再重新校准看门狗基线，
  ///   避免锁屏冻结计时器在解锁瞬间被误判为断线超时触发重连。
  void _handleAppLifecycleChange(
    AppLifecycleState? previous,
    AppLifecycleState next,
  ) {
    final nowPaused = next != AppLifecycleState.resumed;
    if (nowPaused == _appPaused) return;
    _appPaused = nowPaused;
    if (nowPaused) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'chat',
        message:
            'App lifecycle paused/hidden: reveal & merge consumption paused',
      );
      _mergeTimer?.cancel();
      _mergeTimer = null;
      _revealTimer?.cancel();
      _revealTimer = null;
      try {
        final keepalive = ref.read(backgroundKeepaliveServiceProvider);
        final notifSettings = ref.read(notificationSettingsProvider);
        final isStreaming =
            state.stream.activeStreamId != null ||
            state.phase == ChatPhase.streaming ||
            state.phase == ChatPhase.steered ||
            state.phase == ChatPhase.sending;
        unawaited(
          keepalive.onAppLifecycleChanged(
            state: next,
            activeSessionId: state.sessionId,
            activeStreamId: state.stream.activeStreamId,
            isStreaming: isStreaming,
            foregroundServiceEnabled: notifSettings.bgForegroundServiceEnabled,
          ),
        );
      } catch (_) {}
      return;
    }
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat',
      message:
          'App lifecycle resumed: flushing pending text + watchdog rebaseline',
    );
    try {
      final keepalive = ref.read(backgroundKeepaliveServiceProvider);
      unawaited(
        keepalive.stopForegroundService()
        // 停止失败仅诊断日志（K 修复规格：仅开关路径需回滚，见
        // setBgForegroundServiceEnabled）；fire-and-forget 调用自吞。
        .catchError((Object _) {}),
      );
      if (state.sessionId.isNotEmpty) {
        unawaited(keepalive.cancelOneOffPoll(state.sessionId));
      }
    } catch (_) {}
    // #29 后台恢复主动探测：重基线前捕获「后台空窗」——后台冻结点到 resumed
    // 时刻的传输停滞时长（SSE 后台静默断线无 onTransportError/onClosed 事件，
    // 只能靠时间差识别，`_lastTransportActivity` 即断线状态快照）。
    final lastActivity = _lastTransportActivity;
    final transportGap = lastActivity == null
        ? Duration.zero
        : _now().difference(lastActivity);
    // 直接铺全文：先入队（queue）的文本在前、pending 在后，保持到达顺序。
    _flushPendingRevealToFullText();
    _startRevealTimerIfNeeded();
    // 看门狗基线重新校准：锁屏冻结期间的时间差不参与超时判定。
    _lastProgress = _now();
    _lastTransportActivity = _now();
    _statusCheckCooldownUntil = null;
    final stream = state.stream;
    final isStreamingActive =
        stream.activeStreamId != null &&
        !stream.hasCompletedResponse &&
        !state.pendingAction.hasPendingPrompt;
    if (isStreamingActive) {
      _resumedAt = _now();
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'chat_resume',
        message:
            'App lifecycle resumed (transportGap: ${transportGap.inMilliseconds}ms, streamId: ${stream.activeStreamId})',
      );
    }
    // resume 立即主动查 stream status（不等 watchdog 12s 阈值）：
    // 空窗达到阈值（生产环境 gap >= 2s，测试 override 时取其较小值）且 recovery == idle 时立即探测，
    // 弱网/后台空窗目标 resume→首个新字 ≤3s；死流/超时立即重连或补差，健康流 loadMessages
    // 顺带把后台期间新内容落地——「切回立即呈现最新状态」。
    final resumeProbeThreshold =
        _watchdogConfig.transportStaleThreshold < const Duration(seconds: 2)
        ? _watchdogConfig.transportStaleThreshold
        : const Duration(seconds: 2);
    if (isStreamingActive &&
        stream.recovery == ActiveStreamRecoveryState.idle &&
        transportGap >= resumeProbeThreshold) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'chat_resume',
        message:
            'Resume active-probe triggered (transportGap: ${transportGap.inMilliseconds}ms, streamId: ${stream.activeStreamId})',
      );
      unawaited(_checkStatusAndReconnect());
    }
  }

  /// 把 merge/reveal 积压一次性写入消息（保持时间顺序：queue 先、pending 后）。
  void _flushPendingRevealToFullText() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _revealTimer?.cancel();
    _revealTimer = null;
    final text = _revealQueue.join() + state.pendingAssistantTokenChunks.join();
    _revealQueue.clear();
    _revealQueueStart = null;
    state = state.copyWith(
      pendingAssistantTokenChunks: const [],
      isRevealQueueEmpty: true,
    );
    if (text.isNotEmpty) {
      _appendToStreamingMessage(text);
    }
  }

  void _scheduleMerge() {
    if (_appPaused) return; // 后台/锁屏不调度合并（resumed 统一铺全文）
    _mergeTimer ??= Timer(mergeDelay, () {
      _mergeTimer = null;
      _mergePendingTokens();
    });
  }

  void _mergePendingTokens() {
    final chunks = state.pendingAssistantTokenChunks;
    if (chunks.isNotEmpty) {
      final text = chunks.join();
      if (!_smoothStreaming) {
        state = state.copyWith(
          pendingAssistantTokenChunks: const [],
          isRevealQueueEmpty: true,
        );
        if (text.isNotEmpty) {
          _appendToStreamingMessage(text);
          _markProgress();
        }
      } else {
        final units = splitIntoWordUnits(
          text,
          cjkChunkSize: _smoothStreamingSpeed.cjkChunkSize,
        );
        _revealQueue.addAll(units);
        if (_revealQueue.length > maxRevealQueueUnits) {
          // 修复②队列硬上限：积压超过阈值直接落全文（一次铺完不再逐词），
          // 防止后台/锁屏期间无上限积压导致解锁后爆吐 + 卡死。
          final overflow = _revealQueue.join();
          _revealQueue.clear();
          _revealQueueStart = null;
          state = state.copyWith(
            pendingAssistantTokenChunks: const [],
            isRevealQueueEmpty: true,
          );
          if (overflow.isNotEmpty) {
            _appendToStreamingMessage(overflow);
            _markProgress();
          }
        } else {
          _revealQueueStart ??= _now();
          state = state.copyWith(
            pendingAssistantTokenChunks: const [],
            isRevealQueueEmpty: _revealQueue.isEmpty,
          );
          _startRevealTimerIfNeeded();
        }
      }
    }
    // 同一 tick 内 token 先、reasoning 后。
    _flushReasoningChunks();
  }

  void _startRevealTimerIfNeeded() {
    if (_appPaused) return; // 后台/锁屏不启动逐词消费
    if (_revealTimer != null) return;
    _revealTimer = Timer.periodic(
      _smoothStreamingSpeed.revealInterval,
      (_) => _drainReveal(),
    );
  }

  /// 根据积压量与档位配置计算每 tick reveal 词单元数。
  ///
  /// - 慢档（1-3 档）：固定每 tick 单元数，不随积压自适应加速。
  /// - 快档（4-5 档）：保留自适应加速（base=档位单元数，上限 32）。
  @visibleForTesting
  static int adaptiveWordUnitsPerTick(
    int backlog, [
    SmoothStreamingSpeedPreset speed = SmoothStreamingSpeedPreset.standard,
  ]) {
    if (backlog <= 0) return 0;
    if (!speed.isAdaptive) {
      return backlog < speed.wordUnitsPerTick
          ? backlog
          : speed.wordUnitsPerTick;
    }
    if (backlog < speed.wordUnitsPerTick) return backlog;
    if (backlog <= 8) return speed.wordUnitsPerTick;
    // backlog >= 9 时平滑递增，积压越多消耗越快，上限 32
    return (speed.wordUnitsPerTick + (backlog - 8) ~/ 12).clamp(
      speed.wordUnitsPerTick,
      32,
    );
  }

  void _drainReveal() {
    if (_appPaused) return; // 后台/锁屏暂停逐词消费（resumed 统一铺全文）
    if (!_smoothStreaming) {
      _flushPendingRevealToFullText();
      return;
    }
    if (_revealQueue.isEmpty) {
      _revealTimer?.cancel();
      _revealTimer = null;
      _revealQueueStart = null;
      if (!state.isRevealQueueEmpty) {
        state = state.copyWith(isRevealQueueEmpty: true);
      }
      return;
    }
    final speed = _smoothStreamingSpeed;
    final count = adaptiveWordUnitsPerTick(_revealQueue.length, speed);
    final effectiveCount = count < _revealQueue.length
        ? count
        : _revealQueue.length;
    final units = _revealQueue.sublist(0, effectiveCount);
    _revealQueue.removeRange(0, effectiveCount);
    _appendToStreamingMessage(
      units.join(),
      isRevealQueueEmpty: _revealQueue.isEmpty,
    );
    _markProgress();
    // 最大滞后：积压超过档位时限一次性排空。
    final start = _revealQueueStart;
    if (_revealQueue.isNotEmpty &&
        start != null &&
        _now().difference(start) >= speed.maxRevealLag) {
      final rest = _revealQueue.join();
      _revealQueue.clear();
      _revealQueueStart = null;
      _appendToStreamingMessage(rest, isRevealQueueEmpty: true);
      _markProgress();
    }
  }

  /// 完成路径全量 flush：取消待定 tick，把缓冲全部写入消息。
  void flushPendingStreamingContent() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _revealTimer?.cancel();
    _revealTimer = null;
    final text = state.pendingAssistantTokenChunks.join() + _revealQueue.join();
    _revealQueue.clear();
    _revealQueueStart = null;
    if (text.isNotEmpty) {
      state = state.copyWith(
        pendingAssistantTokenChunks: const [],
        isRevealQueueEmpty: true,
      );
      _appendToStreamingMessage(text);
    } else {
      state = state.copyWith(isRevealQueueEmpty: true);
    }
    _flushReasoningChunks();
  }

  void _flushReasoningChunks() {
    final chunks = state.pendingReasoningChunks;
    if (chunks.isEmpty) return;
    final text = chunks.join();
    state = state.copyWith(
      pendingReasoningChunks: const [],
      liveReasoningText: state.liveReasoningText + text,
    );
  }

  String _currentReasoningContent() {
    var base = state.liveReasoningText;
    if (state.pendingReasoningChunks.isNotEmpty) {
      base += state.pendingReasoningChunks.join();
    }
    return base;
  }

  /// reasoning：去重 → 入 pendingReasoningChunks → 合并 tick 整块 flush。
  bool _appendReasoning(String text) {
    if (text.isEmpty) return false;
    var remainder = text;
    final stream = state.stream;
    if (stream.isReplayConnection) {
      // 打点前记录匹配游标：重放帧全命中（remainder 空）时用它重建
      // thinking 段断点（该帧在最终 reasoning 文本中的起点）。
      final prevCursor = stream.matchedReasoningLength;
      final deduped = deduplicatedReplayText(
        text: text,
        existingContent: _currentReasoningContent(),
        matchedLength: stream.matchedReasoningLength,
      );
      remainder = deduped.remainder;
      state = state.copyWith(
        stream: state.stream.copyWith(
          matchedReasoningLength: deduped.newCursor,
          isReplayConnection: deduped.stillReplay,
        ),
      );
      if (remainder.isEmpty) {
        // same 重放帧：内容命中已有思考。断点补建仅在「断点为空的恢复场景」
        // （_replayRebuildTimeline）执行，避免时间线为空导致时间线回退；
        // 正常 live 重连断点仍在，补点会把已展示思考段叠加到时间线尾部
        // （底部连续思考卡簇的放大源）。
        if (_replayRebuildTimeline) {
          _ensureTimelinePoint(LiveSegmentKind.thinking, prevCursor);
        }
        return false;
      }
    }
    // 与工具事件一致：reasoning 先到时也立即锚定空流式气泡（思考中指示器兜底）。
    _ensureStreamingAssistantMessage();
    // 时间线断点：事件到达时记录（对齐真实顺序）；start 含待 flush 块长度。
    final start = _currentReasoningContent().length;
    _ensureTimelinePoint(LiveSegmentKind.thinking, start);
    state = state.copyWith(
      pendingReasoningChunks: [...state.pendingReasoningChunks, remainder],
    );
    _scheduleMerge();
    return true;
  }

  // -------------------------------------------------------------------------
  // 消息组装
  // -------------------------------------------------------------------------

  /// 流式 assistant 消息锚定：不存在则创建并记住 ID。
  void _ensureStreamingAssistantMessage() {
    if (state.stream.streamingAssistantMessageId != null) return;
    final message = ChatMessage(
      role: 'assistant',
      content: '',
      messageId: 'stream-${uuidV4()}',
      timestamp: _nowSeconds(),
    );
    state = state.copyWith(
      messages: [...state.messages, message],
      stream: state.stream.copyWith(
        streamingAssistantMessageId: message.messageId,
      ),
    );
  }

  /// 时间线断点：段切换时追加（同 kind 连续追加并入同段，不重复建点）。
  ///
  /// 断点按 SSE 事件到达顺序记录；[start] 为该段缓冲起始游标，渲染层据此
  /// 对 content / liveReasoningText / liveToolCalls 切片穿插展示。
  void _ensureTimelinePoint(LiveSegmentKind kind, int start) {
    final points = state.liveTimelinePoints;
    if (points.isNotEmpty && points.last.kind == kind) return;
    state = state.copyWith(
      liveTimelinePoints: [
        ...points,
        LiveTimelinePoint(
          kind: kind,
          start: start,
          sequence: ++_timelineSequence,
        ),
      ],
    );
  }

  /// 以 messageId == streamingAssistantMessageId 定位，原地替换（content 追加）。
  ///
  /// [establishPoint] = true 时（interim_assistant 新段落路径）在追加前建立
  /// text 断点（start=缓冲全量）；默认 false —— flush/reveal 只是推进既有
  /// text 段的 content，不产生新段，若在此建点会用「已 flush 进度」把同一
  /// 段文本在工具断点之后劈开（「一致性问题」的「一」「致」之间插卡）。
  void _appendToStreamingMessage(
    String text, {
    bool? isRevealQueueEmpty,
    bool establishPoint = false,
  }) {
    if (text.isEmpty) return;
    _ensureStreamingAssistantMessage();
    final id = state.stream.streamingAssistantMessageId!;
    var index = state.messages.indexWhere((m) => m.messageId == id);
    if (index == -1) {
      // 防御重锚：diff-merge 吸收匹配后流式临时消息可能被服务端权威行替换
      //（isMessageMatch 内容吸收），锚点重指最后一条 assistant，保证后续
      // 内容继续追加而不是静默丢失。
      for (var i = state.messages.length - 1; i >= 0; i--) {
        if (state.messages[i].role == 'assistant' &&
            state.messages[i].messageId != null) {
          index = i;
          state = state.copyWith(
            stream: state.stream.copyWith(
              streamingAssistantMessageId: state.messages[i].messageId,
            ),
          );
          break;
        }
      }
    }
    if (index == -1) return;
    final current = state.messages[index];
    // 兜底断点仅限「新段落」追加路径（interim_assistant）：start 取缓冲全量
    // （含待合并/待揭示），使段边界与最终 content 对齐。常规 flush/reveal
    // 路径不建点——text 段在 token 事件到达时已定义（_appendAssistantToken），
    // 这里若按已 flush 长度建点会劈段（「一」「致」之间插工具卡的根因）。
    if (establishPoint) {
      _ensureTimelinePoint(
        LiveSegmentKind.text,
        _currentStreamingContent().length,
      );
    }
    final next = List<ChatMessage>.of(state.messages);
    next[index] = current.copyWith(content: '${current.content ?? ''}$text');
    state = state.copyWith(
      messages: next,
      streamingScrollTrigger: state.streamingScrollTrigger + 1,
      isRevealQueueEmpty: isRevealQueueEmpty ?? state.isRevealQueueEmpty,
    );
  }

  String _currentStreamingContent() {
    final id = state.stream.streamingAssistantMessageId;
    String base = '';
    if (id != null) {
      for (final message in state.messages) {
        if (message.messageId == id) {
          base = message.content ?? '';
          break;
        }
      }
    } else if (state.messages.isNotEmpty) {
      for (var i = state.messages.length - 1; i >= 0; i--) {
        final message = state.messages[i];
        if (message.role == 'assistant') {
          base = message.content ?? '';
          break;
        }
      }
    }
    // 包含待合并与待揭示队列，避免重连去重时把待吐内容误作新内容
    if (state.pendingAssistantTokenChunks.isNotEmpty) {
      base += state.pendingAssistantTokenChunks.join();
    }
    if (_revealQueue.isNotEmpty) {
      base += _revealQueue.join();
    }
    return base;
  }

  /// interim_assistant：already_streamed 过滤 + 先 flush 再追加 + 分隔符规则。
  bool _handleInterimAssistant(String text, bool alreadyStreamed) {
    if (alreadyStreamed) return false;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    flushPendingStreamingContent();
    final stream = state.stream;
    if (stream.streamingAssistantMessageId == null) {
      return _appendAssistantToken(text);
    }
    final currentContent = _currentStreamingContent();
    String append;
    if (stream.isReplayConnection) {
      // 修复④：与 token 路径共用 matchedPrefixLength 游标并回写，interim
      // 整段去重不再恒 0 失效（否则整段重复文本直接入 content）。
      final deduped = deduplicatedReplayText(
        text: text,
        existingContent: currentContent,
        matchedLength: stream.matchedPrefixLength,
      );
      append = deduped.remainder;
      // 整段吸收：游标错位（中段重放/多次重连叠加）时残余段常是已展示
      // 内容的后缀碎片，overlap 启发式会把它当新内容拼出「归档-#42 归档」
      // 式重复。凡残余段已被现有内容整体包含，一律吞掉并保持 replay 态，
      // 由后续帧的 offset 对齐自然衔接。
      if (append.isNotEmpty && currentContent.contains(append)) {
        append = '';
      }
      state = state.copyWith(
        stream: state.stream.copyWith(
          matchedPrefixLength: deduped.newCursor,
          isReplayConnection: deduped.stillReplay,
        ),
      );
      if (append.isEmpty) return false;
      // replay 直连：直接拼接不加分隔符。
    } else {
      // 1. 整段包含：已展示内容已包含本快照全量 → 吞掉（语义同 replay 分支兜底）
      if (currentContent.contains(text)) return false;

      // 2. 快照前缀重叠：currentContent 后缀与 text 前缀最大重叠（overlap >= 2 时只追加残余）
      var overlap = 0;
      final maxK = currentContent.length < text.length
          ? currentContent.length
          : text.length;
      for (var k = maxK; k >= 2; k--) {
        if (currentContent.endsWith(text.substring(0, k))) {
          overlap = k;
          break;
        }
      }

      if (overlap >= 2) {
        append = text.substring(overlap);
        // 3. 短片段防误判：残余 append 去空白后为空 → 吞掉
        if (append.trim().isEmpty) return false;
      } else {
        // 4. 未命中任何去重 → 维持现状新段落
        append = currentContent.isEmpty ? text : '\n\n$text';
      }
    }
    // interim 独立新段落或快照残余拼接：需建 text 断点；start 由
    // _appendToStreamingMessage 内部按缓冲全量取，保证段边界对齐最终 content。
    _appendToStreamingMessage(append, establishPoint: true);
    _markProgress();
    return true;
  }

  // -------------------------------------------------------------------------
  // 工具调用
  // -------------------------------------------------------------------------

  void _appendToolCall(ToolStreamEvent evt) {
    final stream = state.stream;
    if (stream.isReplayConnection) {
      final stableId = evt.stableId;
      if (stableId != null) {
        if (state.liveToolCalls.any((t) => t.id == stableId) ||
            state.completedToolCallGroups.any(
              (g) => g.toolCalls.any((t) => t.id == stableId),
            )) {
          return;
        }
      } else {
        var idx = stream.replayToolMatchIndex;
        while (idx < state.liveToolCalls.length) {
          if (_sameToolSignature(state.liveToolCalls[idx], evt)) {
            state = state.copyWith(
              stream: state.stream.copyWith(replayToolMatchIndex: idx + 1),
            );
            return;
          }
          idx++;
        }
      }
    }
    _ensureStreamingAssistantMessage();
    // 时间线断点：工具段切换（真实追加前记录，liveToolCalls 下标即段起点；
    // replay 去重命中已在上文 return，不会误建点）。
    _ensureTimelinePoint(LiveSegmentKind.tools, state.liveToolCalls.length);
    final tool = ToolCall(
      id: evt.stableId,
      name: evt.name,
      preview: evt.preview,
      args: evt.jsonArgs ?? _argsToJsonValue(evt.args),
      isCompleted: false,
    );
    final anchor =
        state.stream.toolCallAnchorMessageId ??
        state.stream.streamingAssistantMessageId;
    state = state.copyWith(
      liveToolCalls: [...state.liveToolCalls, tool],
      stream: state.stream.copyWith(toolCallAnchorMessageId: anchor),
    );
    _markProgress();
  }

  void _completeToolCall(ToolStreamEvent evt) {
    final stableId = evt.stableId;
    final calls = state.liveToolCalls;
    var index = -1;
    if (stableId != null) {
      index = calls.indexWhere((t) => t.id == stableId);
    }
    if (index == -1 && evt.name != null) {
      // 匹配 name 相同的最后一个未完成项。
      for (var i = calls.length - 1; i >= 0; i--) {
        if (calls[i].name == evt.name && !calls[i].isCompleted) {
          index = i;
          break;
        }
      }
    }
    if (index != -1) {
      final existing = calls[index];
      if (state.stream.isReplayConnection && existing.isCompleted) return;
      final next = List<ToolCall>.of(calls);
      next[index] = ToolCall(
        id: existing.id,
        name: evt.name ?? existing.name,
        preview: evt.preview ?? existing.preview,
        args:
            evt.jsonArgs ??
            (evt.args != null ? _argsToJsonValue(evt.args) : existing.args),
        duration: evt.duration,
        isError: evt.isError,
        isCompleted: true,
        startedAt: existing.startedAt,
      );
      state = state.copyWith(liveToolCalls: next);
    } else {
      if (state.stream.isReplayConnection &&
          stableId != null &&
          state.completedToolCallGroups.any(
            (g) => g.toolCalls.any((t) => t.id == stableId),
          )) {
        return;
      }
      // 匹配不到 → append 已完成项（服务器只发了完成事件）。
      state = state.copyWith(
        liveToolCalls: [
          ...calls,
          ToolCall(
            id: stableId,
            name: evt.name,
            preview: evt.preview,
            args: evt.jsonArgs ?? _argsToJsonValue(evt.args),
            duration: evt.duration,
            isError: evt.isError,
            isCompleted: true,
          ),
        ],
      );
    }
    _markProgress();
  }

  Map<String, JsonValue>? _argsToJsonValue(Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return null;
    return args.map((k, v) => MapEntry(k, JsonValue.fromJson(v)));
  }

  bool _sameToolSignature(ToolCall call, ToolStreamEvent evt) {
    if (call.name != evt.name) return false;
    if (call.preview != evt.preview) return false;
    final argsA = call.args == null
        ? '{}'
        : jsonEncode(call.args!.map((k, v) => MapEntry(k, v.toJson())));
    final argsB = evt.args == null ? '{}' : jsonEncode(evt.args);
    return argsA == argsB;
  }

  // -------------------------------------------------------------------------
  // title / metering / approval / clarify / steer leftover
  // -------------------------------------------------------------------------

  void _handleTitle(String? sessionId, String? title) {
    if (sessionId == null || sessionId.isEmpty || title == null) return;
    if (state.sessionId.isNotEmpty && sessionId != state.sessionId) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(displayTitle: trimmed);
  }

  void _handleMetering({
    double? tps,
    required bool tpsAvailable,
    required bool estimated,
    String? sessionId,
  }) {
    if (sessionId != null &&
        sessionId.isNotEmpty &&
        state.sessionId.isNotEmpty &&
        sessionId != state.sessionId) {
      return;
    }
    if (tpsAvailable && !estimated && tps != null && tps.isFinite && tps > 0) {
      state = state.copyWith(
        stream: state.stream.copyWith(liveTokensPerSecond: tps),
      );
      // 同步更新 snapshot 的 tps，确保 popover 阈值色与 indicator 一致
      // 且即使仅有 metering 也能实时更新 cost/tps 相关行。
      final prev = state.contextWindowSnapshot;
      if (prev != null) {
        state = state.copyWith(
          contextWindowSnapshot: prev.replacingTokensPerSecond(tps),
        );
      } else {
        // 无历史 snapshot 时，用 tps 创建空壳（至少保留 tps 可展示）
        state = state.copyWith(
          contextWindowSnapshot: ContextWindowSnapshot(tokensPerSecond: tps),
        );
      }
    }
  }

  void _applyApprovalUpdate(Map<String, Object?> payload) {
    final pending = payload['pending'];
    if (pending is Map) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'chat',
        message:
            'Phase changed to approvalPending (session: ${state.sessionId})',
      );
      state = state.copyWith(
        phase: ChatPhase.approvalPending,
        pendingAction: state.pendingAction.copyWith(
          approvalPrompt: Map<String, Object?>.from(pending),
        ),
      );
    } else {
      _clearApprovalCard();
    }
    _markProgress();
  }

  void _applyClarificationUpdate(Map<String, Object?> payload) {
    final pending = payload['pending'];
    if (pending is Map) {
      final isNew =
          state.phase != ChatPhase.clarifyPending ||
          state.pendingAction.clarificationPrompt == null;
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'chat',
        message:
            'Phase changed to clarifyPending (session: ${state.sessionId})',
      );
      state = state.copyWith(
        phase: ChatPhase.clarifyPending,
        pendingAction: state.pendingAction.copyWith(
          clarificationPrompt: Map<String, Object?>.from(pending),
        ),
      );
      if (isNew) {
        final q = (pending['question'] as String?)?.trim();
        _notifyClarificationNeeded(
          q != null && q.isNotEmpty ? q : 'Agent 需要你澄清问题',
        );
      }
    } else {
      _clearClarificationCard();
    }
    _markProgress();
  }

  /// 澄清卡片超时收卡 + 提示。
  void handleClarificationTimeout() {
    if (_disposed) return;
    _clearClarificationCard();
    setNotice('澄清已超时');
  }

  void _clearApprovalCard() {
    state = state.copyWith(
      phase: state.stream.hasActiveStream
          ? ChatPhase.streaming
          : ChatPhase.idle,
      pendingAction: state.pendingAction.copyWith(clearApproval: true),
    );
  }

  void _clearClarificationCard() {
    state = state.copyWith(
      phase: state.stream.hasActiveStream
          ? ChatPhase.streaming
          : ChatPhase.idle,
      pendingAction: state.pendingAction.copyWith(clearClarification: true),
    );
  }

  void _handleContextStatus(ContextPrefillStatus status, String? label) {
    state = state.copyWith(prefillStatus: status, prefillLabel: label);
    _markProgress();
  }

  /// 启动独立 Clarify SSE 流 + 轮询兜底通道。
  void _startClarifyChannel(String sessionId) {
    if (sessionId.isEmpty) return;
    _stopClarifyChannel();
    _connectClarifyStream(sessionId);
    _startClarifyPolling(sessionId);
  }

  /// 停止 Clarify SSE 流与轮询。
  void _stopClarifyChannel() {
    try {
      ref.read(chatApiProvider).stopClarifyStream();
    } catch (_) {}
    _clarifyPollTimer?.cancel();
    _clarifyPollTimer = null;
  }

  /// 连接 `/api/clarify/stream?session_id=` 独立 SSE 流。
  void _connectClarifyStream(String sessionId) {
    if (_disposed || sessionId.isEmpty) return;
    try {
      final api = ref.read(chatApiProvider);
      unawaited(
        api.startClarifyStream(
          sessionId,
          onEvent: (event) {
            if (_disposed) return;
            if (event is ClarificationPendingSseEvent) {
              _applyClarificationUpdate(event.payload);
            }
          },
          onTransportError: (_) {
            // 静默容错，由轮询兜底
          },
          onClosed: () {},
        ),
      );
    } catch (_) {
      // 静默容错
    }
  }

  /// 启动静默轮询兜底（20s 周期，会话打开时拉取）。
  void _startClarifyPolling(String sessionId) {
    _clarifyPollTimer?.cancel();
    _clarifyPollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_pollClarifyPending(sessionId));
    });
    scheduleMicrotask(() => _pollClarifyPending(sessionId));
  }

  /// 静默拉取 `/api/clarify/pending`。
  Future<void> _pollClarifyPending(String sessionId) async {
    if (_disposed || state.sessionId != sessionId) return;
    final gen = _generation;
    try {
      final api = ref.read(chatApiProvider);
      final response = await api.clarifyPending(sessionId);
      if (_disposed || gen != _generation || state.sessionId != sessionId) {
        return;
      }
      if (response.pending != null) {
        final p = response.pending!;
        _applyClarificationUpdate({
          'pending': {
            'clarify_id': p.clarifyId,
            'question': p.question,
            'choices_offered': p.choicesOffered,
            'session_id': p.sessionId ?? sessionId,
            'kind': p.kind,
            'requested_at': p.requestedAt,
            'timeout_seconds': p.timeoutSeconds,
            'expires_at': p.expiresAt,
          },
          'pending_count': response.pendingCount ?? 1,
        });
      } else if (state.pendingAction.clarificationPrompt != null) {
        _clearClarificationCard();
      }
    } catch (_) {
      // 静默容错
    }
  }

  void _handlePendingSteerLeftover(String text) {
    if (text.trim().isEmpty) return;
    state = state.copyWith(
      queuedSlashMessages: [...state.queuedSlashMessages, text],
      pinnedLocalNotices: [
        ...state.pinnedLocalNotices,
        'Steering hint was not consumed — it has been queued for the next message.',
      ],
    );
    _markProgress();
  }

  // -------------------------------------------------------------------------
  // done / stream_end / cancel / error 收尾
  // -------------------------------------------------------------------------

  void _applyDone(DoneStreamEvent event) {
    flushPendingStreamingContent();
    final completedStreamId = state.stream.activeStreamId;
    final currentStreamingId = state.stream.streamingAssistantMessageId;
    final rawSession = event.session;
    final hasCompletedTranscript =
        rawSession != null &&
        rawSession['messages'] is List &&
        (rawSession['messages'] as List).isNotEmpty;
    if (hasCompletedTranscript) {
      _applyCompletedStreamSession(rawSession, currentStreamingId);
    }
    final rawUsage = event.usage;
    ContextWindowSnapshot? snapshot =
        event.usageSnapshot ??
        (rawUsage != null ? ContextWindowSnapshot.fromJson(rawUsage) : null);
    // 若 usage 缺失关键字段，尝试从 session detail 或历史 snapshot 回退补齐
    if (snapshot != null) {
      final prev = state.contextWindowSnapshot;
      final detailFallback = hasCompletedTranscript
          ? SessionDetail.fromJson(rawSession)
          : null;
      // 回退 contextLength / threshold / tokens
      final merged = ContextWindowSnapshot(
        contextLength:
            snapshot.contextLength ??
            detailFallback?.contextLength ??
            prev?.contextLength,
        thresholdTokens:
            snapshot.thresholdTokens ??
            detailFallback?.thresholdTokens ??
            prev?.thresholdTokens,
        lastPromptTokens:
            snapshot.lastPromptTokens ??
            detailFallback?.lastPromptTokens ??
            prev?.lastPromptTokens,
        inputTokens:
            snapshot.inputTokens ??
            detailFallback?.inputTokens ??
            prev?.inputTokens,
        outputTokens:
            snapshot.outputTokens ??
            detailFallback?.outputTokens ??
            prev?.outputTokens,
        estimatedCost:
            snapshot.estimatedCost ??
            detailFallback?.estimatedCost ??
            prev?.estimatedCost,
        tokensPerSecond: snapshot.tokensPerSecond ?? prev?.tokensPerSecond,
      );
      // 若回退后仍有有效百分比，则使用合并后；否则保留原始
      snapshot = merged;
    } else if (hasCompletedTranscript) {
      // usage 缺失但有完整 transcript：直接从 session detail 构建
      // ignore: unnecessary_non_null_assertion
      final detail = SessionDetail.fromJson(rawSession!);
      snapshot = ContextWindowSnapshot(
        contextLength: detail.contextLength,
        thresholdTokens: detail.thresholdTokens,
        lastPromptTokens: detail.lastPromptTokens,
        inputTokens: detail.inputTokens,
        outputTokens: detail.outputTokens,
        estimatedCost: detail.estimatedCost,
        tokensPerSecond: state.contextWindowSnapshot?.tokensPerSecond,
      );
      // 若回退的 tps 存在，同步到 snapshot
      final prevTps =
          state.stream.liveTokensPerSecond ??
          state.contextWindowSnapshot?.tokensPerSecond;
      if (prevTps != null && snapshot.tokensPerSecond == null) {
        snapshot = snapshot.replacingTokensPerSecond(prevTps);
      }
    }
    if (snapshot != null &&
        (snapshot.contextLength != null ||
            snapshot.inputTokens != null ||
            snapshot.lastPromptTokens != null ||
            snapshot.tokensPerSecond != null)) {
      state = state.copyWith(contextWindowSnapshot: snapshot);
      final tps = snapshot.tokensPerSecond;
      if (tps != null && tps.isFinite && tps > 0) {
        _applyTurnTps(currentStreamingId, tps);
      }
    }
    _completeCurrentResponse(
      needsTranscriptRefresh: !hasCompletedTranscript,
      completedStreamId: completedStreamId,
    );
    // 回合完成（done）：通知 hook（仅后台发通知，见 notifications feature）。
    _notifyTurnCompleted();
    _triggerSessionListRefreshForCompleted(state.sessionId);
    unawaited(_writeCacheMessages(state.sessionId, state.messages));
  }

  void _applyCompletedStreamSession(
    Map<String, Object?> rawSession,
    String? currentStreamingId,
  ) {
    final detail = SessionDetail.fromJson(rawSession);
    final loaded = detail.messages ?? const <ChatMessage>[];
    final merged = _mergingLoadedMessages(
      loaded,
      state.messages,
      currentStreamingId,
    );
    final persisted = detail.toolCalls ?? const <PersistedToolCall>[];
    _lastPersistedToolCalls = persisted;
    final persistedGroups = ToolCallGroup.groups(
      persistedToolCalls: persisted,
      messages: merged,
      messageOffset: state.messagesOffset,
      coalesce: _coalesceTools,
    );
    final lastAssistant = _lastAssistantMessageId(merged);
    final liveGroups = _archiveLiveToolCallsToGroups();
    final reanchoredLiveGroups = _reanchorGroupsToMessages(
      liveGroups,
      merged,
      currentStreamingId,
      lastAssistant,
    );
    final groups = ToolCallGroup.merging(
      primaryGroups: persistedGroups,
      fallbackGroups: reanchoredLiveGroups,
    );
    final serverDerivedReasoning = ReasoningGroup.groups(
      messages: merged,
      messageOffset: state.messagesOffset,
    );
    final liveReasoning = _archiveLiveReasoningToGroups();
    final reanchoredLiveReasoning = _reanchorReasoningToMessages(
      liveReasoning,
      merged,
      currentStreamingId,
      lastAssistant,
    );
    final reasoningGroups = ReasoningGroup.merging(
      primaryGroups: serverDerivedReasoning,
      fallbackGroups: reanchoredLiveReasoning,
    );
    final title = detail.title?.trim();
    // 同步上下文快照（对齐 Swift applyCompletedStreamSession）
    final snapshotFromDetail = ContextWindowSnapshot(
      contextLength: detail.contextLength,
      thresholdTokens: detail.thresholdTokens,
      lastPromptTokens: detail.lastPromptTokens,
      inputTokens: detail.inputTokens,
      outputTokens: detail.outputTokens,
      estimatedCost: detail.estimatedCost,
      tokensPerSecond:
          state.stream.liveTokensPerSecond ??
          state.contextWindowSnapshot?.tokensPerSecond,
    );
    final hasSnapshotValues =
        snapshotFromDetail.contextLength != null ||
        snapshotFromDetail.thresholdTokens != null ||
        snapshotFromDetail.lastPromptTokens != null ||
        snapshotFromDetail.inputTokens != null;
    state = state.copyWith(
      messages: merged,
      messagesOffset: detail.messagesOffset ?? state.messagesOffset,
      hasOlderMessages:
          detail.messageCount != null && detail.messageCount! > merged.length,
      displayTitle: (title == null || title.isEmpty)
          ? state.displayTitle
          : title,
      workspace: detail.workspace ?? state.workspace,
      model: detail.model ?? state.model,
      modelProvider: detail.modelProvider ?? state.modelProvider,
      profile: detail.profile ?? state.profile,
      completedToolCallGroups: groups,
      completedReasoningGroups: reasoningGroups,
      liveToolCalls: const [],
      liveReasoningText: '',
      stream: state.stream.copyWith(
        clearStreamingAssistantMessageId: true,
        clearToolCallAnchorMessageId: true,
        clearReasoningAnchorMessageId: true,
      ),
    );
    if (hasSnapshotValues) {
      state = state.copyWith(contextWindowSnapshot: snapshotFromDetail);
    }
  }

  /// 服务端 transcript 与本地合并：local- 乐观消息保留插回；本地流式内容
  /// 与服务端取「更长/更新的」，前缀包含去重（chat_spec.md §5.5 最低档）。
  List<ChatMessage> _mergingLoadedMessages(
    List<ChatMessage> loaded,
    List<ChatMessage> current,
    String? streamingMessageId,
  ) {
    if (loaded.isEmpty) return List<ChatMessage>.from(current);
    if (current.isEmpty) return loaded;
    final result = List<ChatMessage>.from(loaded);
    if (streamingMessageId != null) {
      ChatMessage? localStreaming;
      for (final message in current) {
        if (message.messageId == streamingMessageId) {
          localStreaming = message;
          break;
        }
      }
      if (localStreaming != null) {
        final localContent = localStreaming.content ?? '';
        var lastAssistantIndex = -1;
        for (var i = result.length - 1; i >= 0; i--) {
          if (result[i].role == 'assistant') {
            lastAssistantIndex = i;
            break;
          }
        }
        if (lastAssistantIndex != -1) {
          final serverContent = result[lastAssistantIndex].content ?? '';
          if (localContent.isNotEmpty &&
              serverContent.startsWith(localContent)) {
            // 服务端已含本地全部内容 → 丢弃本地流式消息。
          } else if (localContent.isNotEmpty &&
              (serverContent.isEmpty ||
                  localContent.startsWith(serverContent))) {
            result[lastAssistantIndex] = result[lastAssistantIndex].copyWith(
              content: localContent,
            );
          }
        } else if (localContent.isNotEmpty) {
          result.add(localStreaming);
        }
      }
    }
    final loadedIds = result
        .map((m) => m.messageId)
        .whereType<String>()
        .toSet();
    final localToInsert = current
        .where(
          (m) =>
              (m.messageId ?? '').startsWith('local-') &&
              !loadedIds.contains(m.messageId) &&
              !_duplicatesLoadedUserMessage(m, result),
        )
        .toList();
    if (localToInsert.isNotEmpty) {
      var insertAt = result.length;
      for (var i = result.length - 1; i >= 0; i--) {
        if (result[i].role == 'user' &&
            TranscriptTurnClassifier.isUserTurnBoundary(result[i])) {
          insertAt = i + 1;
          break;
        }
      }
      result.insertAll(insertAt, localToInsert);
    }
    return result;
  }

  /// local- 乐观 user 消息与加载 transcript 的最后一条 user 消息内容相同
  /// （服务端已确认该消息）→ 视为重复，不再保留。
  bool _duplicatesLoadedUserMessage(
    ChatMessage local,
    List<ChatMessage> loaded,
  ) {
    if (local.role != 'user') return false;
    final localContent = local.content?.trim();
    if (localContent == null || localContent.isEmpty) return false;
    for (var i = loaded.length - 1; i >= 0; i--) {
      final message = loaded[i];
      if (message.role == 'user' &&
          (message.content ?? '').trim() == localContent) {
        return true;
      }
    }
    return false;
  }

  void _applyTurnTps(String? currentStreamingId, double tps) {
    var index = -1;
    if (currentStreamingId != null) {
      index = state.messages.indexWhere(
        (m) => m.messageId == currentStreamingId,
      );
    }
    if (index == -1) {
      for (var i = state.messages.length - 1; i >= 0; i--) {
        if (state.messages[i].role == 'assistant') {
          index = i;
          break;
        }
      }
    }
    if (index == -1) return;
    final next = List<ChatMessage>.of(state.messages);
    next[index] = next[index].copyWith(turnTps: tps);
    state = state.copyWith(messages: next);
  }

  /// completeCurrentResponse：结束流（activeStreamId=null、hasCompletedResponse=true）。
  void _completeCurrentResponse({
    required bool needsTranscriptRefresh,
    String? completedStreamId,
  }) {
    _api?.stopStream();
    _syncSessionStreaming(state.sessionId, false);
    final nextToolGroups = _archiveLiveToolCallsToGroups();
    final nextReasoningGroups = _archiveLiveReasoningToGroups();
    state = state.copyWith(
      phase: ChatPhase.idle,
      completedToolCallGroups: nextToolGroups,
      completedReasoningGroups: nextReasoningGroups,
      liveToolCalls: const [],
      liveReasoningText: '',
      liveTimelinePoints: const [],
      clearSteerHints: true,
      clearPrefillStatus: true,
      clearPrefillLabel: true,
      stream: state.stream.copyWith(
        clearActiveStreamId: true,
        clearLastEventId: true,
        clearStreamingAssistantMessageId: true,
        clearToolCallAnchorMessageId: true,
        clearReasoningAnchorMessageId: true,
        clearLiveTokensPerSecond: true,
        hasCompletedResponse: true,
        isSuspended: false,
        recovery: ActiveStreamRecoveryState.idle,
        isReplayConnection: false,
        matchedPrefixLength: 0,
        matchedReasoningLength: 0,
        replayToolMatchIndex: 0,
        replayAfterSeq: 0,
      ),
      pendingAction: const ChatPendingActionState(),
      responseCompletionNeedsTranscriptRefresh: needsTranscriptRefresh,
    );
    if (needsTranscriptRefresh && completedStreamId != null) {
      _scheduleTranscriptRefresh(completedStreamId);
    }
    _markProgress();
  }

  void _scheduleTranscriptRefresh(String streamId) {
    _transcriptRefreshTimer?.cancel();
    _transcriptRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      _transcriptRefreshTimer = null;
      unawaited(refreshTranscriptIfCompleted(streamId));
    });
  }

  /// 回合完成 → 通知 hook（仅 done / stream_end 成功收尾触发；
  /// cancel / error / transportError 路径不调用）。
  ///
  /// sessionId 为空（新会话尚未确定）时跳过：通知点击需要可跳转的会话。
  void _notifyTurnCompleted() {
    if (_disposed) return;
    final current = state;
    final sessionId = current.sessionId;
    if (sessionId.isEmpty) return;
    final title = current.displayTitle;
    final preview = _lastAssistantContent(current);
    ref.read(chatTurnCompletedCallbackProvider)(sessionId, title, preview);
  }

  /// 澄清请求通知。
  void _notifyClarificationNeeded(String question) {
    if (_disposed) return;
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return;
    ref.read(chatClarificationNeededCallbackProvider)(sessionId, question);
  }

  /// 异常中断通知。
  void _notifySessionError(String title, String preview) {
    if (_disposed) return;
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return;
    ref.read(chatSessionErrorCallbackProvider)(sessionId, title, preview);
  }

  /// 最近一条非空 assistant 消息内容（通知预览用）；无则空串。
  String _lastAssistantContent(ChatState state) {
    for (final message in state.messages.reversed) {
      final content = message.content ?? '';
      if (message.role == 'assistant' && content.trim().isNotEmpty) {
        return content;
      }
    }
    return '';
  }

  void _handleStreamEnd() {
    final wasCompleted = state.stream.hasCompletedResponse;
    if (!wasCompleted) {
      _completeCurrentResponse(
        needsTranscriptRefresh: false,
        completedStreamId: state.stream.activeStreamId,
      );
      // 回合完成（stream_end，done 未先到）：通知 hook。
      // done 已收尾时 wasCompleted 为 true，不会重复通知。
      _notifyTurnCompleted();
      _triggerSessionListRefreshForCompleted(state.sessionId);
    }
    _finishStream();
    unawaited(_writeCacheMessages(state.sessionId, state.messages));
  }

  void _handleCancelled() {
    _syncSessionStreaming(state.sessionId, false);
    if (!state.stream.hasCompletedResponse) {
      _completeCurrentResponse(
        needsTranscriptRefresh: false,
        completedStreamId: state.stream.activeStreamId,
      );
      _notifySessionError('响应已取消', state.displayTitle);
    }
    _finishStream(endPhase: ChatPhase.cancelled);
  }

  void _handleErrorEvent(String message) {
    _syncSessionStreaming(state.sessionId, false);
    if (!state.stream.hasCompletedResponse) {
      state = state.copyWith(sendErrorMessage: message);
      _completeCurrentResponse(
        needsTranscriptRefresh: false,
        completedStreamId: state.stream.activeStreamId,
      );
      _notifySessionError('响应出错', message);
      _finishStream(endPhase: ChatPhase.error);
    } else {
      // done 已收尾：不显示错误，仅清理残留。
      _finishStream();
    }
  }

  /// finishStream：清残留（flush、卡片、pinned notices、队列顺次发送），
  /// 相位经瞬态 endPhase 后立即回 idle。
  void _finishStream({ChatPhase endPhase = ChatPhase.idle}) {
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat',
      message:
          'Stream finished (endPhase: ${endPhase.name}, session: ${state.sessionId})',
    );
    _syncSessionStreaming(state.sessionId, false);
    flushPendingStreamingContent();
    _resetReconnectBackoff();
    var messages = state.messages;
    if (state.pinnedLocalNotices.isNotEmpty) {
      final notices = state.pinnedLocalNotices
          .map(
            (text) => ChatMessage(
              role: 'local_notice',
              content: text,
              messageId: 'local-notice-${uuidV4()}',
              timestamp: _nowSeconds(),
            ),
          )
          .toList();
      messages = [...messages, ...notices];
    }
    state = state.copyWith(
      phase: endPhase,
      messages: messages,
      pinnedLocalNotices: const [],
      clearSteerHints: true,
      clearPrefillStatus: true,
      clearPrefillLabel: true,
      clearTurnStartedMillis: true,
      liveTimelinePoints: const [],
      pendingAction: const ChatPendingActionState(),
      stream: state.stream.copyWith(
        clearActiveStreamId: true,
        clearLastEventId: true,
        clearStreamingAssistantMessageId: true,
        clearToolCallAnchorMessageId: true,
        clearReasoningAnchorMessageId: true,
        isSuspended: false,
        recovery: ActiveStreamRecoveryState.idle,
        isCancelling: false,
        isReplayConnection: false,
        matchedPrefixLength: 0,
        matchedReasoningLength: 0,
        replayToolMatchIndex: 0,
        replayAfterSeq: 0,
      ),
    );
    _api?.stopStream();
    _cancelStreamTimers();
    _markProgress();
    try {
      final keepalive = ref.read(backgroundKeepaliveServiceProvider);
      unawaited(
        keepalive.stopForegroundService()
        // 停止失败仅诊断日志（K 修复规格：仅开关路径需回滚，见
        // setBgForegroundServiceEnabled）；fire-and-forget 调用自吞。
        .catchError((Object _) {}),
      );
      if (state.sessionId.isNotEmpty) {
        unawaited(keepalive.cancelOneOffPoll(state.sessionId));
      }
    } catch (_) {}
    // 瞬态相位：收尾完成后立即回 idle。
    if (endPhase != ChatPhase.idle) {
      state = state.copyWith(phase: ChatPhase.idle);
    }
    // done 后未收到 title → 补拉一次标题。
    if (state.stream.hasCompletedResponse &&
        state.displayTitle == 'Untitled Session') {
      unawaited(_refreshCompletedResponseTitleIfNeeded());
    }
    // 队列顺次发送。
    if (state.queuedSlashMessages.isNotEmpty) {
      unawaited(_drainQueuedSlashMessage());
    }
  }

  void _cancelStreamTimers() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _revealTimer?.cancel();
    _revealTimer = null;
    _revealQueue.clear();
    _revealQueueStart = null;
    _lastContextPollTime = null;
    _isContextPolling = false;
  }

  Future<void> _refreshCompletedResponseTitleIfNeeded() async {
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return;
    final gen = _generation;
    try {
      final response = await _api!.session(
        sessionId: sessionId,
        includeMessages: false,
      );
      if (_disposed || gen != _generation) return;
      final title = response.session?.title?.trim();
      if (title != null && title.isNotEmpty) {
        state = state.copyWith(displayTitle: title);
      }
    } on ApiException {
      // 标题补拉失败静默。
    }
  }

  void _onNewSessionCreated(String newSessionId, String hint) {
    _pendingNewSessionIds.add(newSessionId);
    // Guard: no active connection in tests/offline -> skip list refresh (avoid "尚未配置服务器连接" throw).
    try {
      final active = ref.read(activeConnectionProvider);
      if (active == null) return;
    } catch (_) {
      return;
    }
    try {
      final notifier = ref.read(sessionListControllerProvider.notifier);
      unawaited(
        notifier
            .handleNewChatSession(newSessionId, titleHint: hint)
            .catchError((_) {}),
      );
    } catch (_) {
      // Provider 未就绪（如无激活连接）时静默，列表会在下次进入时拉取。
    }
  }

  void _triggerSessionListRefreshForCompleted(String sessionId) {
    if (sessionId.isEmpty) return;
    final throttle = ref.read(sessionListRefreshThrottleProvider);
    // 新建会话（pending）双次补拉语义：收尾时必须强制刷新一次，不参与
    // 存量会话节流；其刷新时间戳同时作为容器级冷却，窗口内其他完成合并
    // 跳过，避免重复拉取。
    if (_pendingNewSessionIds.remove(sessionId)) {
      throttle.lastRefreshAt = _now();
      _fireSessionListRefresh();
      return;
    }
    // 存量会话：回合完成同样刷新列表（#30）。节流窗口内（同会话重复 /
    // 并发多会话）合并进先到的刷新，窗口外直接触发。
    final now = _now();
    final last = throttle.lastRefreshAt;
    if (last != null &&
        now.difference(last) < _sessionListRefreshThrottleWindow) {
      return;
    }
    throttle.lastRefreshAt = now;
    _fireSessionListRefresh();
  }

  /// 实际执行会话列表强制刷新（弱网/离线静默，不抛错）。
  void _fireSessionListRefresh() {
    if (_disposed) return;
    try {
      final active = ref.read(activeConnectionProvider);
      if (active == null) return;
    } catch (_) {
      return;
    }
    try {
      final notifier = ref.read(sessionListControllerProvider.notifier);
      unawaited(notifier.refreshIfStale(force: true).catchError((_) {}));
    } catch (_) {}
  }

  /// 实时同步单个会话流式状态到会话列表（乐观置位 / 清除 + 后台纠偏）。
  void _syncSessionStreaming(
    String sessionId,
    bool isStreaming, {
    String? activeStreamId,
    bool verifyInBackground = false,
  }) {
    if (sessionId.isEmpty || _disposed) return;
    try {
      final active = ref.read(activeConnectionProvider);
      if (active == null) return;
    } catch (_) {
      return;
    }
    try {
      final notifier = ref.read(sessionListControllerProvider.notifier);
      notifier.markStreaming(
        sessionId,
        isStreaming,
        activeStreamId: activeStreamId,
        verifyInBackground: verifyInBackground,
      );
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // transportError 断线恢复（chat_spec.md §5.3）
  // -------------------------------------------------------------------------

  /// 取消挂起的重连退避定时器。
  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// 任何成功事件重置退避（SSE 连接成功 / 收到任意 event / 收到 status 正常响应）。
  void _resetReconnectBackoff() {
    _reconnectAttempts = 0;
    _cancelReconnectTimer();
  }

  void _handleTransportError(String message) {
    final stream = state.stream;
    if (stream.activeStreamId == null || stream.hasCompletedResponse) {
      // 无连接可恢复：显示错误 + finishStream。
      _syncSessionStreaming(state.sessionId, false);
      state = state.copyWith(sendErrorMessage: message);
      _finishStream(endPhase: ChatPhase.error);
      return;
    }
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.warn,
      tag: 'chat',
      message: 'Transport error handled, phase -> recovering: $message',
    );
    // 挂起：lastEventID 已由 onEventId 记录；快照即当前 state。
    state = state.copyWith(
      phase: ChatPhase.recovering,
      stream: stream.copyWith(
        isSuspended: true,
        recovery: ActiveStreamRecoveryState.checking,
      ),
    );
    _api?.stopStream();

    final maxAttempts = _watchdogConfig.effectiveMaxReconnectAttempts;
    if (_reconnectAttempts >= maxAttempts) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'chat_reconnect',
        message:
            'Transport error: max reconnect attempts ($_reconnectAttempts) reached, stopping auto-reconnect',
      );
      return;
    }

    final delay = _watchdogConfig.backoffDelayForAttempt(_reconnectAttempts);
    _reconnectAttempts++;
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat_reconnect',
      message:
          'Scheduling reconnect attempt $_reconnectAttempts with delay ${delay.inMilliseconds}ms (streamId: ${stream.activeStreamId})',
    );
    _cancelReconnectTimer();
    final gen = _generation;
    _reconnectTimer = Timer(delay, () {
      if (_disposed || gen != _generation) return;
      _reconnectTimer = null;
      unawaited(_reconnectIfNeeded());
    });
  }

  Future<void> _reconnectIfNeeded() async {
    final streamId = state.stream.activeStreamId;
    if (streamId == null) return;
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat_reconnect',
      message: 'Stream reconnection checking status (streamId: $streamId)',
    );
    final gen = _generation;
    try {
      final status = await _api!.chatStreamStatus(streamId);
      if (_disposed || gen != _generation) return;
      _resetReconnectBackoff();
      if (status.active == true) {
        // 全量重连：loadMessages 后恢复（带 replay 若快照有 lastEventID）。
        await _loadMessagesAndResume(streamId);
        return;
      }
      if (status.replayAvailable == true) {
        final afterSeq = _replayAfterSeq(state.stream.lastEventId);
        state = state.copyWith(
          stream: state.stream.copyWith(
            isSuspended: false,
            recovery: ActiveStreamRecoveryState.reconnecting,
          ),
        );
        if (afterSeq > 0) {
          _connectStream(streamId, replayAfterSeq: afterSeq);
        } else {
          _connectStream(streamId, fullReconnect: true);
        }
        state = state.copyWith(
          stream: state.stream.copyWith(
            isSuspended: false,
            recovery: ActiveStreamRecoveryState.idle,
          ),
          phase: ChatPhase.streaming,
        );
        _markProgress();
        return;
      }
      // 非 active 且无 replay：loadMessages → 有 assistant 响应按 transcript
      // complete，否则 finalize 为失败。
      await _finalizeAfterRecovery(streamId);
    } on ApiException {
      if (_disposed || gen != _generation) return;
      // status 失败 → 强制尝试 replay。
      _forceReconnect(streamId);
    }
  }

  Future<void> _loadMessagesAndResume(String streamId) async {
    await loadMessages();
    if (_disposed) return;
    if (state.stream.activeStreamId != streamId) return;
    // 重锚定：加载的 transcript 里当前回合最后一条 assistant 消息。
    final currentAnchor = state.stream.streamingAssistantMessageId;
    if (currentAnchor == null ||
        !state.messages.any((m) => m.messageId == currentAnchor)) {
      String? anchorId;
      for (var i = state.messages.length - 1; i >= 0; i--) {
        final message = state.messages[i];
        if (message.role == 'assistant' && message.messageId != null) {
          anchorId = message.messageId;
          break;
        }
      }
      if (anchorId != null) {
        state = state.copyWith(
          stream: state.stream.copyWith(streamingAssistantMessageId: anchorId),
        );
      }
    }
    final afterSeq = _replayAfterSeq(state.stream.lastEventId);
    if (afterSeq > 0) {
      _connectStream(streamId, replayAfterSeq: afterSeq);
    } else {
      _connectStream(streamId, fullReconnect: true);
    }
    state = state.copyWith(
      stream: state.stream.copyWith(
        isSuspended: false,
        recovery: ActiveStreamRecoveryState.idle,
      ),
      phase: ChatPhase.streaming,
    );
    _markProgress();
  }

  Future<void> _finalizeAfterRecovery(String streamId) async {
    await loadMessages();
    if (_disposed) return;
    if (state.stream.activeStreamId != streamId) return;
    final hasAssistantResponse = state.messages.any(
      (m) => m.role == 'assistant',
    );
    if (hasAssistantResponse) {
      _completeCurrentResponse(
        needsTranscriptRefresh: false,
        completedStreamId: streamId,
      );
      _finishStream();
    } else {
      state = state.copyWith(sendErrorMessage: '连接已断开，未能恢复流。');
      _notifySessionError('连接已断开', '未能恢复流，会话已终止。');
      _finishStream(endPhase: ChatPhase.error);
    }
  }

  /// 强制重连（status 失败 / 看门狗超时；带 replay 若可用）。
  void _forceReconnect(String streamId) {
    if (_disposed) return;
    if (_reconnectAttempts >= _watchdogConfig.effectiveMaxReconnectAttempts) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'chat_reconnect',
        message:
            'Force reconnect suppressed: max reconnect attempts ($_reconnectAttempts) reached',
      );
      return;
    }
    if (_reconnectTimer != null && _reconnectTimer!.isActive) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'chat_reconnect',
        message:
            'Force reconnect suppressed: backoff timer is currently pending',
      );
      return;
    }
    final afterSeq = _replayAfterSeq(state.stream.lastEventId);
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.warn,
      tag: 'chat_reconnect',
      message:
          'Force reconnecting stream (streamId: $streamId, afterSeq: $afterSeq)',
    );
    _recordTransportActivity();
    state = state.copyWith(
      stream: state.stream.copyWith(
        isSuspended: true,
        recovery: ActiveStreamRecoveryState.reconnecting,
      ),
    );
    _api?.stopStream();
    if (afterSeq > 0) {
      _connectStream(streamId, replayAfterSeq: afterSeq);
    } else {
      _connectStream(streamId, fullReconnect: true);
    }
    state = state.copyWith(
      stream: state.stream.copyWith(
        isSuspended: false,
        recovery: ActiveStreamRecoveryState.idle,
      ),
      phase: ChatPhase.streaming,
    );
    _markProgress();
  }

  /// lastEventID 冒号后序号解析（§5.4）；解析失败 → 0。
  int _replayAfterSeq(String? lastEventId) {
    if (lastEventId == null) return 0;
    final idx = lastEventId.lastIndexOf(':');
    final part = idx == -1 ? lastEventId : lastEventId.substring(idx + 1);
    return int.tryParse(part.trim()) ?? 0;
  }

  // -------------------------------------------------------------------------
  // 看门狗（前台 1s 心跳；5s/12s/18s/25s 阈值；冷却 ≥4s）
  // -------------------------------------------------------------------------

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogConfig.watchdogInterval, (_) {
      _recoverStaleStreamIfNeeded();
      _pollContextWindowIfNeeded();
    });
  }

  void _recoverStaleStreamIfNeeded() {
    if (_disposed) return;
    if (_appPaused) return; // 修复③后台/锁屏豁免看门狗（冻结计时器不判超时）
    if (state.stream.activeStreamId == null) return;
    if (state.stream.hasCompletedResponse) return;
    if (state.pendingAction.hasPendingPrompt) return; // 卡片期间暂停
    final config = _watchdogConfig;
    if (_reconnectTimer != null && _reconnectTimer!.isActive) return;
    if (_reconnectAttempts >= config.effectiveMaxReconnectAttempts) return;
    final now = _now();
    final lastProgress = _lastProgress;
    final lastTransport = _lastTransportActivity;
    final hasRunningTools = _hasRunningTools;

    final isTransportFresh =
        lastTransport != null &&
        now.difference(lastTransport) < config.transportFreshThreshold;

    final isNormalStale =
        lastProgress != null &&
        now.difference(lastProgress) >= config.progressStaleThreshold &&
        lastTransport != null &&
        now.difference(lastTransport) >= config.transportStaleThreshold;
    final isToolProgressStale =
        !isTransportFresh &&
        hasRunningTools &&
        lastProgress != null &&
        now.difference(lastProgress) >= config.forceReconnectThreshold;

    if (isNormalStale || isToolProgressStale) {
      final cooldown = _statusCheckCooldownUntil;
      if (cooldown == null || now.isAfter(cooldown)) {
        _statusCheckCooldownUntil = now.add(config.statusPollCooldown);
        DiagnosticsService.instance.log(
          level: DiagnosticsLogLevel.warn,
          tag: 'chat_watchdog',
          message:
              'Watchdog detected stale stream activity${hasRunningTools ? ' during tool execution' : ''}, polling status (session: ${state.sessionId})',
        );
        state = state.copyWith(
          stream: state.stream.copyWith(
            recovery: ActiveStreamRecoveryState.checking,
          ),
        );
        unawaited(_checkStatusAndReconnect());
      }
    }
    final forceThreshold = hasRunningTools
        ? config.forceReconnectWithRunningToolsThreshold
        : config.forceReconnectThreshold;
    final isTransportForce =
        lastTransport != null &&
        now.difference(lastTransport) >= forceThreshold;
    final isToolProgressForce =
        !isTransportFresh &&
        hasRunningTools &&
        lastProgress != null &&
        now.difference(lastProgress) >=
            config.forceReconnectWithRunningToolsThreshold;

    if (isTransportForce || isToolProgressForce) {
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.error,
        tag: 'chat_watchdog',
        message:
            'Watchdog force reconnecting due to ${isToolProgressForce ? 'tool progress hang' : 'transport silence'} (session: ${state.sessionId})',
      );
      _forceReconnect(state.stream.activeStreamId!);
    }
  }

  bool get _hasRunningTools => state.liveToolCalls.any((t) => !t.isCompleted);

  Future<void> _checkStatusAndReconnect() async {
    final streamId = state.stream.activeStreamId;
    if (streamId == null) return;
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.info,
      tag: 'chat_resume',
      message:
          'Checking stream status (streamId: $streamId, session: ${state.sessionId})',
    );
    final gen = _generation;
    try {
      final status = await _api!.chatStreamStatus(streamId);
      if (_disposed || gen != _generation) return;
      _resetReconnectBackoff();
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.info,
        tag: 'chat_resume',
        message:
            'Stream status checked: active=${status.active}, replayAvailable=${status.replayAvailable}',
      );
      if (status.active == true) {
        await _loadMessagesAndResume(streamId);
      } else if (status.replayAvailable == true) {
        final afterSeq = _replayAfterSeq(state.stream.lastEventId);
        state = state.copyWith(
          stream: state.stream.copyWith(
            recovery: ActiveStreamRecoveryState.reconnecting,
          ),
        );
        _connectStream(
          streamId,
          replayAfterSeq: afterSeq == 0 ? null : afterSeq,
        );
        state = state.copyWith(
          stream: state.stream.copyWith(
            recovery: ActiveStreamRecoveryState.idle,
          ),
          phase: ChatPhase.streaming,
        );
        _markProgress();
      } else {
        await _finalizeAfterRecovery(streamId);
      }
    } on ApiException catch (e) {
      if (_disposed || gen != _generation) return;
      DiagnosticsService.instance.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'chat_resume',
        message: 'Status check failed: $e, falling back to force reconnect',
      );
      _forceReconnect(streamId);
    }
  }

  void _handleHeartbeat() {
    // 心跳证明传输存活：checking → idle；绝不 demote reconnecting。
    if (state.stream.recovery == ActiveStreamRecoveryState.checking) {
      state = state.copyWith(
        stream: state.stream.copyWith(recovery: ActiveStreamRecoveryState.idle),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Live 流式上下文窗口轮询（N = 2s；活跃流期间轮询；空闲零请求）
  // -------------------------------------------------------------------------

  /// Live 流式期间每 2s 轮询一次会话详情以实时刷新上下文窗口指示器读数。
  void _pollContextWindowIfNeeded() {
    if (_disposed) return;
    if (_appPaused) return;
    final streamId = state.stream.activeStreamId;
    if (streamId == null) return;
    if (state.stream.hasCompletedResponse) return;
    if (state.sessionId.isEmpty) return;
    if (_isContextPolling) return;

    final now = _now();
    final lastPoll = _lastContextPollTime;
    if (lastPoll != null &&
        now.difference(lastPoll) < contextWindowPollInterval) {
      return;
    }

    _lastContextPollTime = now;
    unawaited(_pollContextWindow(streamId));
  }

  Future<void> _pollContextWindow(String streamId) async {
    final api = _api;
    if (api == null) return;
    final sessionId = state.sessionId;
    if (sessionId.isEmpty) return;
    final gen = _generation;
    _isContextPolling = true;
    try {
      final response = await api.session(
        sessionId: sessionId,
        includeMessages: false,
      );
      if (_disposed || gen != _generation) return;
      if (state.stream.activeStreamId != streamId ||
          state.stream.hasCompletedResponse) {
        return;
      }
      final detail = response.session;
      if (detail == null) return;

      final prev = state.contextWindowSnapshot;
      final snapshot = ContextWindowSnapshot(
        contextLength: detail.contextLength ?? prev?.contextLength,
        thresholdTokens: detail.thresholdTokens ?? prev?.thresholdTokens,
        lastPromptTokens: detail.lastPromptTokens ?? prev?.lastPromptTokens,
        inputTokens: detail.inputTokens ?? prev?.inputTokens,
        outputTokens: detail.outputTokens ?? prev?.outputTokens,
        estimatedCost: detail.estimatedCost ?? prev?.estimatedCost,
        tokensPerSecond:
            state.stream.liveTokensPerSecond ?? prev?.tokensPerSecond,
      );
      final hasSnapshotValues =
          snapshot.contextLength != null ||
          snapshot.thresholdTokens != null ||
          snapshot.lastPromptTokens != null ||
          snapshot.inputTokens != null ||
          snapshot.outputTokens != null ||
          snapshot.estimatedCost != null;
      if (hasSnapshotValues) {
        state = state.copyWith(contextWindowSnapshot: snapshot);
      }
    } on Object {
      // 轮询静默容错：网络波动或临时异常不打断流式渲染，不报全局错误
    } finally {
      _isContextPolling = false;
    }
  }

  // -------------------------------------------------------------------------
  // 归档 / 辅助
  // -------------------------------------------------------------------------

  /// 从消息列表的 reasoning 字段提取历史推理组（按 assistant 消息锚定）。
  List<ReasoningGroup> _reasoningGroupsFromMessages(
    List<ChatMessage> messages,
    int messageOffset,
  ) {
    final groups = <ReasoningGroup>[];
    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final reasoning = msg.reasoning?.trim();
      if (reasoning == null || reasoning.isEmpty) continue;
      if (msg.role != 'assistant') continue;
      final anchor = TranscriptTurnClassifier.anchorID(
        msg,
        at: i,
        messageOffset: messageOffset,
      );
      groups.add(ReasoningGroup(anchorMessageId: anchor, text: reasoning));
    }
    return groups;
  }

  void _archiveLiveReasoningIfNeeded() {
    if (state.liveReasoningText.isEmpty) return;
    final groups = _archiveLiveReasoningToGroups();
    state = state.copyWith(
      liveReasoningText: '',
      liveTimelinePoints: const [],
      completedReasoningGroups: groups,
    );
  }

  List<ReasoningGroup> _archiveLiveReasoningToGroups([String? overrideAnchor]) {
    if (state.liveReasoningText.isEmpty) return state.completedReasoningGroups;
    final anchor =
        overrideAnchor ??
        state.stream.reasoningAnchorMessageId ??
        state.stream.streamingAssistantMessageId ??
        _lastAssistantMessageId(state.messages);
    final group = ReasoningGroup(
      anchorMessageId: anchor,
      text: state.liveReasoningText,
    );
    return ReasoningGroup.merging(
      primaryGroups: state.completedReasoningGroups,
      fallbackGroups: [group],
    );
  }

  void _archiveLiveToolCallsIfNeeded() {
    if (state.liveToolCalls.isEmpty) return;
    final groups = _archiveLiveToolCallsToGroups();
    state = state.copyWith(
      liveToolCalls: const [],
      liveTimelinePoints: const [],
      completedToolCallGroups: groups,
    );
  }

  List<ToolCallGroup> _archiveLiveToolCallsToGroups([String? overrideAnchor]) {
    if (state.liveToolCalls.isEmpty) return state.completedToolCallGroups;
    final anchor =
        overrideAnchor ??
        state.stream.toolCallAnchorMessageId ??
        state.stream.streamingAssistantMessageId ??
        _lastAssistantMessageId(state.messages);
    final group = ToolCallGroup.live(
      anchorMessageID: anchor,
      toolCalls: List<ToolCall>.of(state.liveToolCalls),
    );
    return ToolCallGroup.merging(
      primaryGroups: state.completedToolCallGroups,
      fallbackGroups: [group],
    );
  }

  List<ToolCallGroup> _reanchorGroupsToMessages(
    List<ToolCallGroup> groups,
    List<ChatMessage> messages,
    String? oldStreamingId,
    String? newAnchorId,
  ) {
    if (groups.isEmpty || newAnchorId == null || newAnchorId.isEmpty) {
      return groups;
    }
    final messageIds = messages
        .map((m) => m.messageId)
        .whereType<String>()
        .toSet();
    return groups.map((g) {
      final anchor = g.anchorMessageID;
      final needsReanchor =
          anchor == null ||
          anchor == oldStreamingId ||
          ((anchor.startsWith('local-') || anchor == 'unanchored') &&
              !messageIds.contains(anchor));
      if (needsReanchor) {
        return ToolCallGroup(
          id: g.id,
          anchorMessageID: newAnchorId,
          toolCalls: g.toolCalls,
        );
      }
      return g;
    }).toList();
  }

  List<ReasoningGroup> _reanchorReasoningToMessages(
    List<ReasoningGroup> groups,
    List<ChatMessage> messages,
    String? oldStreamingId,
    String? newAnchorId,
  ) {
    if (groups.isEmpty || newAnchorId == null || newAnchorId.isEmpty) {
      return groups;
    }
    final messageIds = messages
        .map((m) => m.messageId)
        .whereType<String>()
        .toSet();
    return groups.map((g) {
      final anchor = g.anchorMessageId;
      final needsReanchor =
          anchor == null ||
          anchor == oldStreamingId ||
          ((anchor.startsWith('local-') || anchor == 'unanchored') &&
              !messageIds.contains(anchor));
      if (needsReanchor) {
        return ReasoningGroup(anchorMessageId: newAnchorId, text: g.text);
      }
      return g;
    }).toList();
  }

  void _rollbackOptimisticMessage(String messageId) {
    state = state.copyWith(
      messages: state.messages.where((m) => m.messageId != messageId).toList(),
    );
  }

  void _pinNotice(String text) {
    state = state.copyWith(
      pinnedLocalNotices: [...state.pinnedLocalNotices, text],
    );
  }

  void _setSendError(String message) {
    state = state.copyWith(sendErrorMessage: message);
  }

  /// 轻提示（成功类会话操作结果）。
  void setNotice(String message) {
    state = state.copyWith(noticeMessage: message);
  }

  /// 清除轻提示。
  void dismissNotice() {
    state = state.copyWith(clearNoticeMessage: true);
  }

  ///
  /// 若指定 [index]，仅移除该位置的单条 steer 提示；若未指定（或越界），清空全部 steer 提示。
  void clearSteerHint({int? index}) {
    if (index == null) {
      state = state.copyWith(clearSteerHints: true);
      return;
    }
    if (index < 0 || index >= state.steerHints.length) return;
    final updated = List<String>.from(state.steerHints)..removeAt(index);
    state = state.copyWith(steerHints: updated);
  }

  /// 清除重试回填预填值（输入栏已消费后调用）。
  void clearComposerPrefill() {
    state = state.copyWith(clearComposerPrefill: true);
  }

  void _markProgress() {
    _lastProgress = _now();
    // steered 是子相位：收到任意 progress 事件回到 streaming。
    if (state.phase == ChatPhase.steered) {
      state = state.copyWith(phase: ChatPhase.streaming);
    }
    if (state.stream.recovery == ActiveStreamRecoveryState.checking) {
      state = state.copyWith(
        stream: state.stream.copyWith(recovery: ActiveStreamRecoveryState.idle),
      );
    }
  }

  void _recordTransportActivity() {
    _lastTransportActivity = _now();
  }

  Future<void> _recoverExistingStream(String activeStreamId) async {
    _resetReconnectBackoff();
    await loadMessages();
    if (_disposed) return;
    if (state.stream.activeStreamId == null) {
      state = state.copyWith(
        stream: state.stream.copyWith(activeStreamId: activeStreamId),
      );
    }
    if (state.stream.activeStreamId == activeStreamId && !_streamConnected) {
      _connectStream(activeStreamId, fullReconnect: true);
    }
    state = state.copyWith(
      phase: ChatPhase.streaming,
      stream: state.stream.copyWith(
        hasCompletedResponse: false,
        isSuspended: false,
      ),
    );
    _syncSessionStreaming(
      state.sessionId,
      true,
      activeStreamId: activeStreamId,
      verifyInBackground: true,
    );
    _markProgress();
  }

  String? _lastAssistantMessageId(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'assistant' && m.messageId != null) return m.messageId;
    }
    return null;
  }

  String _resolveTitle(SessionDetail detail) {
    final title = detail.title?.trim();
    if (title == null || title.isEmpty) return 'Untitled Session';
    return title;
  }

  // -------------------------------------------------------------------------
  // replay 去重（chat_spec.md §5.6；token 粒度 + reasoning 同构）
  // -------------------------------------------------------------------------

  /// token 粒度去重。返回剩余文本 + 新游标 + 是否仍处于 replay 匹配。
  @visibleForTesting
  static ({String remainder, int newCursor, bool stillReplay})
  deduplicatedReplayToken({
    required String token,
    required String existingContent,
    required int matchedPrefixLength,
  }) {
    if (existingContent.isEmpty) {
      return (remainder: token, newCursor: 0, stillReplay: false);
    }
    var cursor = matchedPrefixLength;
    if (cursor < 0) cursor = 0;
    if (cursor > existingContent.length) cursor = existingContent.length;
    final expectedRemainder = existingContent.substring(cursor);

    if (expectedRemainder.isNotEmpty && expectedRemainder.startsWith(token)) {
      // 纯重复：游标前进。（保持 replay 态直到不匹配帧自然退出：重放流
      // 中途「追平」不代表重放结束，提前关闸会让后续旧事件帧裸追加。）
      final newCursor = cursor + token.length;
      return (
        remainder: '',
        newCursor: newCursor >= existingContent.length ? 0 : newCursor,
        stillReplay: true,
      );
    }
    if (expectedRemainder.isNotEmpty && token.startsWith(expectedRemainder)) {
      // 残余拼接。
      return (
        remainder: token.substring(expectedRemainder.length),
        newCursor: 0,
        stillReplay: true,
      );
    }
    if (existingContent.endsWith(token) || existingContent.startsWith(token)) {
      // 完全重复。
      return (remainder: '', newCursor: 0, stillReplay: true);
    }
    if (token.startsWith(existingContent)) {
      return (
        remainder: token.substring(existingContent.length),
        newCursor: 0,
        stillReplay: true,
      );
    }
    // 最大重叠扫描（existingContent 后缀 ∩ token 前缀，从大到小）。
    // 修复：单字重叠（CJK 根/因等）会导致死循环重复，需 >=2 才算有效重叠
    final maxLen = existingContent.length < token.length
        ? existingContent.length
        : token.length;
    var overlap = 0;
    for (var len = maxLen; len > 0; len--) {
      if (len == 1) continue; // 单字重叠不算，避免 CJK 单字误判
      if (existingContent.endsWith(token.substring(0, len))) {
        overlap = len;
        break;
      }
    }
    if (overlap > 0) {
      return (
        remainder: token.substring(overlap),
        newCursor: 0,
        stillReplay: true,
      );
    }
    // 皆不匹配 → 原样返回，关闭 replay。
    return (remainder: token, newCursor: 0, stillReplay: false);
  }

  /// reasoning 粒度去重（同构，游标基于已 flush 的 liveReasoningText）。
  @visibleForTesting
  static ({String remainder, int newCursor, bool stillReplay})
  deduplicatedReplayText({
    required String text,
    required String existingContent,
    required int matchedLength,
  }) {
    return deduplicatedReplayToken(
      token: text,
      existingContent: existingContent,
      matchedPrefixLength: matchedLength,
    );
  }

  /// 词单元切分：空白携带在单元尾部；无空白的 CJK 长串按 [cjkChunkSize] 切分。
  /// 拼接（join）与原始文本完全一致。
  @visibleForTesting
  static List<String> splitIntoWordUnits(String text, {int cjkChunkSize = 8}) {
    if (text.isEmpty) return const [];
    final units = <String>[];
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(ch);
      final isWhitespace = RegExp(r'\s').hasMatch(ch);
      if (isWhitespace || (isCjkRune(rune) && buffer.length >= cjkChunkSize)) {
        units.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) units.add(buffer.toString());
    return units;
  }

  /// CJK 统一表意文字 / 假名 / 谚文范围判定。
  static bool isCjkRune(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF);
  }

  /// 缓存写入：写入最近至多 50 条消息（错误时不影响聊天主流程）。
  Future<void> _writeCacheMessages(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    if (sessionId.isEmpty || messages.isEmpty) return;
    try {
      final cacheService = ref.read(cacheServiceProvider);
      final authoritative = messages.where((m) {
        final id = m.messageId ?? m.id;
        if (id.startsWith('local-') || id.startsWith('stream-')) {
          return false;
        }
        return true;
      }).toList();
      if (authoritative.isEmpty) return;
      final takeCount = authoritative.length > 50 ? 50 : authoritative.length;
      final recentMessages = authoritative.sublist(
        authoritative.length - takeCount,
      );
      final maps = recentMessages.map(_messageToCacheJson).toList();
      await cacheService.writeMessages(sessionId: sessionId, messages: maps);
    } catch (_) {
      // 写缓存失败不得影响聊天主流程（缓存旁路设计，不吞异常原则下此处属旁路容错）。
    }
  }

  static Map<String, Object?> _messageToCacheJson(ChatMessage message) {
    final json = message.toJson();
    final id = message.messageId ?? message.id;
    json['id'] = id;
    json['message_id'] ??= id;
    return json;
  }
}
