import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/sse_client.dart';
import '../../../core/connections/connection_providers.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/tool_call.dart';
import '../../../core/utils/selected_context.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/chat_models.dart';
import '../../chat/chat_providers.dart';
import '../../chat/chat_state.dart';
import 'chat_media_parser.dart';
import 'chat_media_view.dart';
import 'collapsible_process_capsule.dart';
import 'markdown_styles.dart';
import 'message_action_menu.dart';
import 'message_bubble.dart';
import 'message_highlight.dart';
import '../../settings/injected_notice_settings.dart';
import '../../settings/tool_group_settings.dart';
import 'selected_context_card.dart';
import 'steer_banner.dart';
import 'tool_call_card.dart';

/// 阅读锚点快照（离底阅读时记录视口顶部第一条可见条目及偏移，todo.md #14）。
class _ReadingAnchor {
  const _ReadingAnchor({
    required this.candidateKey,
    this.renderId,
    this.liveRenderKey,
    this.toolGroupId,
    this.messageId,
    required this.topOffset,
  });

  final String candidateKey;
  final String? renderId;
  final String? liveRenderKey;
  final String? toolGroupId;
  final String? messageId;
  final double topOffset;
}

/// 回合信息封装（用于回合级过程折叠分组，#55）。
class _TurnInfo {
  _TurnInfo({
    required this.turnKey,
    this.userEntry,
    required this.assistantEntries,
  });

  final String turnKey;
  final TranscriptMessage? userEntry;
  final List<TranscriptMessage> assistantEntries;

  List<TranscriptMessage> get allEntries => [?userEntry, ...assistantEntries];

  TranscriptMessage? get finalAssistantEntry {
    for (var i = assistantEntries.length - 1; i >= 0; i--) {
      final a = assistantEntries[i];
      if (a.message.content?.trim().isNotEmpty == true) {
        return a;
      }
    }
    return null;
  }

  int get intermediateTextCount {
    final finalEntry = finalAssistantEntry;
    if (finalEntry == null) return 0;
    var count = 0;
    for (final a in assistantEntries) {
      if (a == finalEntry) continue;
      if (a.message.content?.trim().isNotEmpty == true) {
        count++;
      }
    }
    return count;
  }

  List<ToolCallGroup> allToolGroups(
    Map<String, List<ToolCallGroup>> entryToolGroups,
  ) {
    final groups = <ToolCallGroup>[];
    if (userEntry != null) {
      final uGroups = entryToolGroups[userEntry!.renderId];
      if (uGroups != null) groups.addAll(uGroups);
    }
    for (final a in assistantEntries) {
      final aGroups = entryToolGroups[a.renderId];
      if (aGroups != null) groups.addAll(aGroups);
    }
    return groups;
  }

  bool hasFailure(Map<String, List<ToolCallGroup>> entryToolGroups) {
    for (final entry in allEntries) {
      final groups = entryToolGroups[entry.renderId];
      if (groups != null) {
        for (final g in groups) {
          if (g.hasFailedTool || g.toolCalls.any((c) => c.isError == true)) {
            return true;
          }
        }
      }
    }
    return false;
  }
}

/// 消息列表项抽象类型（#55：消息或注入折叠胶囊）。
sealed class _ChatListItem {
  const _ChatListItem();
}

class _CapsuleListItem extends _ChatListItem {
  const _CapsuleListItem({
    required this.turn,
    required this.isExpanded,
    required this.toolGroups,
    required this.intermediateTextCount,
  });

  final _TurnInfo turn;
  final bool isExpanded;
  final List<ToolCallGroup> toolGroups;
  final int intermediateTextCount;
}

class _MessageListItem extends _ChatListItem {
  const _MessageListItem({
    required this.entry,
    required this.groups,
    required this.isHidden,
    required this.isFinalAssistantInCollapsedTurn,
  });

  final TranscriptMessage entry;
  final List<ToolCallGroup> groups;
  final bool isHidden;
  final bool isFinalAssistantInCollapsedTurn;
}

bool _isTurnCollapsible({
  required _TurnInfo turn,
  required bool turnCollapseEnabled,
  required bool isTurnCompleted,
  required Map<String, List<ToolCallGroup>> entryToolGroups,
  required bool hideThinking,
}) {
  if (!turnCollapseEnabled) return false;
  if (!isTurnCompleted) return false;

  final finalEntry = turn.finalAssistantEntry;
  if (finalEntry == null) return false;

  if (turn.hasFailure(entryToolGroups)) return false;

  final allGroups = turn.allToolGroups(entryToolGroups);
  final hasThinking =
      !hideThinking &&
      allGroups.any((g) => g.toolCalls.any((c) => c.isThinking));
  final toolCount = allGroups.fold<int>(
    0,
    (sum, g) => sum + g.toolCalls.where((c) => !c.isThinking).length,
  );
  final intermediateTexts = turn.intermediateTextCount;

  return intermediateTexts > 0 || hasThinking || toolCount > 0;
}

/// 安全 Markdown 渲染组件（增量流式解析异常兜底为纯文本，防止大灰屏，todo.md #8）。
class _SafeMarkdownBody extends StatelessWidget {
  const _SafeMarkdownBody({
    required this.data,
    required this.styleSheet,
    required this.builders,
    required this.imageBuilder,
    this.selectable = true,
    // ignore: unused_element_parameter
    this.inlineSyntaxes,
    this.isStreaming = false,
    this.sessionId,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final Map<String, MarkdownElementBuilder> builders;
  final Widget Function(Uri, String?, String?) imageBuilder;
  final bool selectable;
  final List<md.InlineSyntax>? inlineSyntaxes;
  final bool isStreaming;
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    if (isStreaming) {
      return Text(
        data,
        style: TextStyle(
          fontSize: kMarkdownBodyFontSize,
          height: 1.4,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      );
    }
    try {
      return MarkdownBody(
        data: data,
        selectable: selectable,
        styleSheet: styleSheet,
        builders: builders,
        inlineSyntaxes: inlineSyntaxes,
        // #57：live 文本段 MEDIA 链接点击 → 预览/下载
        onTapLink: (text, href, title) => onChatMarkdownLinkTap(
          context,
          link: href,
          linkText: text,
          sessionId: sessionId,
        ),
        // ignore: deprecated_member_use
        imageBuilder: imageBuilder,
      );
    } catch (e, st) {
      developer.log(
        'MarkdownBody incremental parse error, fallback to Text',
        name: 'chat.markdown',
        error: e,
        stackTrace: st,
      );
      return Text(
        data,
        style: TextStyle(
          fontSize: kMarkdownBodyFontSize,
          height: 1.4,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      );
    }
  }
}

/// 消息列表（ListView.builder + 稳定 renderId key + 自动滚动跟随）。
///
/// 流式消息由独立气泡层渲染（transcriptMessagesProvider 已隐藏它），
/// 工具卡片/reasoning 折叠块按 anchorMessageID 锚定到对应气泡。
/// 底部额外插入 steer 横幅（phase==steered 时）与排队横幅（queued 非空时）。
class ChatMessageList extends ConsumerStatefulWidget {
  const ChatMessageList({
    super.key,
    required this.sessionId,
    this.highlightQuery,
    this.listKey,
  });

  final String sessionId;

  /// 搜索结果定位关键词（匹配 content 的第一条消息滚动+高亮；null 关闭）。
  final String? highlightQuery;

  /// 外部持有的 GlobalKey，用于调用 [ChatMessageListState.outlineJumpTo]
  /// 实现大纲点击跳转（chat_page.dart 中由标题栏大纲面板回调触发）。
  final GlobalKey<ChatMessageListState>? listKey;

  @override
  ConsumerState<ChatMessageList> createState() => ChatMessageListState();
}

/// 消息列表状态（公开以暴露 [outlineJumpTo] 给大纲面板调用）。
class ChatMessageListState extends ConsumerState<ChatMessageList> {
  final ScrollController _controller = ScrollController();
  final GlobalKey<State<StatefulWidget>> _highlightKey =
      GlobalKey<State<StatefulWidget>>();
  final Set<String> _expandedNoticeIds = <String>{};
  final Set<String> _expandedTurnKeys = <String>{};
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};
  _ReadingAnchor? _readingAnchor;
  double? _lastBottomInset;
  double? _lastLayoutHeight;

  /// 贴底判定阈值（收紧至 80px，既保障平滑跟随又防止向上轻扫被拽回）。
  static const double _nearBottomThreshold = 80.0;

  /// 拖动起始判定敏感阈值（8px，touchSlop 基准附近，排除轻点，#41）。
  static const double _dragSensitivityThreshold = 8.0;

  /// 锚点准入最小可见高度阈值（24px，避免贴边一条缝的条目当锚，#56）。
  static const double _minAnchorVisibleHeight = 24.0;

  /// 阅读锚点补偿死区阈值（4px，低于此漂移不触发 jumpTo，#56）。
  static const double _anchorDeadzoneThreshold = 4.0;

  /// 防抖锁冻结帧数（同锚点连续反向补偿触发冻结，#56）。
  static const int _anchorFreezeFrames = 10;

  /// 锚点出树最大容忍帧数（容忍 <= 5 帧等待其回到树中，#56）。
  static const int _maxAnchorMissingFrames = 5;

  String? _lastAnchorCompensatedKey;
  double _lastAnchorCompensationDirection = 0.0;
  int _anchorFreezeRemainingFrames = 0;
  int _anchorMissingFrames = 0;

  void _resetAnchorStabilityState() {
    _lastAnchorCompensatedKey = null;
    _lastAnchorCompensationDirection = 0.0;
    _anchorFreezeRemainingFrames = 0;
    _anchorMissingFrames = 0;
  }

  bool _nearBottom = true;
  bool _loadingOlder = false;
  bool _olderLoadQueued = false;
  bool _initialPositioned = false;
  bool _initialPositioning = false;
  bool _restoringOlderPosition = false;
  bool _userHasScrolled = false;
  bool _isUserInteracting = false;
  bool _pressFollowed = true;
  double _dragDisplacement = 0.0;
  bool _dragExceededThreshold = false;
  bool _isGestureActive = false;
  int _pinnedTranscriptCount = 0;
  String? _lastSentUserMessageId;
  int _layoutGeneration = 0;
  bool _initialPositionScheduled = false;
  String? _highlightTargetRenderId;
  bool _highlightPositioned = false;
  bool _highlightSettled = false;

  @visibleForTesting
  bool get nearBottom => _nearBottom;

  @visibleForTesting
  bool get userHasScrolled => _userHasScrolled;

  @visibleForTesting
  bool get pressFollowed => _pressFollowed;

  @visibleForTesting
  bool get isUserInteracting => _isUserInteracting;

  @visibleForTesting
  bool get initialPositioned => _initialPositioned;

  @visibleForTesting
  int get pinnedTranscriptCount => _pinnedTranscriptCount;

  @visibleForTesting
  bool get hasReadingAnchor => _readingAnchor != null;

  @visibleForTesting
  String? get readingAnchorCandidateKey => _readingAnchor?.candidateKey;

  @visibleForTesting
  Map<String, GlobalKey> get itemKeys => _itemKeys;

  @visibleForTesting
  double? get readingAnchorTopOffset => _readingAnchor?.topOffset;

  @visibleForTesting
  int get anchorFreezeRemainingFrames => _anchorFreezeRemainingFrames;

  @visibleForTesting
  int get anchorMissingFrames => _anchorMissingFrames;

  @visibleForTesting
  double get lastAnchorCompensationDirection =>
      _lastAnchorCompensationDirection;

  @visibleForTesting
  void testUpdateReadingAnchor() => _updateReadingAnchor();

  @visibleForTesting
  void testMaybeRestoreReadingAnchor() => _maybeRestoreReadingAnchor();

  @visibleForTesting
  void testSetReadingAnchor({
    required String candidateKey,
    String? renderId,
    String? liveRenderKey,
    String? toolGroupId,
    String? messageId,
    required double topOffset,
  }) {
    _readingAnchor = _ReadingAnchor(
      candidateKey: candidateKey,
      renderId: renderId,
      liveRenderKey: liveRenderKey,
      toolGroupId: toolGroupId,
      messageId: messageId,
      topOffset: topOffset,
    );
  }

  late ProviderSubscription<int> _scrollTriggerSub;
  late ProviderSubscription<ChatPhase> _phaseSub;
  ChatPhase? _lastPhase;
  bool _justSent = false;
  bool _isAnimatingToBottom = false;
  bool _isOutlineJumping = false;

  /// 非动画跳底收敛链（`_settleJumpToBottom`）复核次数上限（#23）。
  /// 发送/流式路径只需追平「新气泡未布局完」的增长窗口，几帧内即收敛，
  /// 刻意远小于初始定位 `_settleToBottom` 的 24 轮上限。
  static const int _maxJumpResettle = 3;

  /// 非动画跳底收敛链是否在途：防止同帧多次触发叠出并行跳转链。
  bool _jumpSettling = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _scrollTriggerSub = ref.listenManual<int>(
      chatControllerProvider(widget.sessionId)
          .select((s) => s.streamingScrollTrigger),
      (_, _) {
        if (!mounted) return;
        if (_nearBottom && !_userHasScrolled && !_isUserInteracting) {
          _scrollToBottom(animated: false);
        }
      },
    );
    _phaseSub = ref.listenManual<ChatPhase>(
      chatPhaseProvider(widget.sessionId),
      (previous, next) {
        if (!mounted) return;
        if (next == ChatPhase.sending) {
          // 刚发送门控：用户刚发送，置位门控，重置离底阅读标志（#13/#14）
          _justSent = true;
          _userHasScrolled = false;
          _nearBottom = true;
          _readingAnchor = null;
          _resetAnchorStabilityState();
          _pinnedTranscriptCount = 0;
        } else if (next == ChatPhase.streaming) {
          if (_justSent ||
              (_nearBottom && !_userHasScrolled) ||
              previous == ChatPhase.sending) {
            _justSent = true;
            _userHasScrolled = false;
            _nearBottom = true;
            _readingAnchor = null;
            _resetAnchorStabilityState();
            _pinnedTranscriptCount = 0;
          }
        }
      },
    );
    final initialTranscript = ref.read(
      transcriptMessagesProvider(widget.sessionId),
    );
    final initialLastUser = initialTranscript
        .where((m) => m.message.role == 'user')
        .lastOrNull;
    _lastSentUserMessageId =
        initialLastUser?.message.messageId ?? initialLastUser?.message.id;

    // 初次 highlight 解析（transcript 尚未加载时会返回 false，下次 build 重试）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeResolveHighlightAndScroll();
    });
  }

  @override
  void didUpdateWidget(ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _scrollTriggerSub.close();
      _phaseSub.close();
      _initialPositioned = false;
      _initialPositioning = false;
      _initialPositionScheduled = false;
      _restoringOlderPosition = false;
      _userHasScrolled = false;
      _isUserInteracting = false;
      _pressFollowed = true;
      _dragDisplacement = 0.0;
      _dragExceededThreshold = false;
      _isGestureActive = false;
      _pinnedTranscriptCount = 0;
      _highlightTargetRenderId = null;
      _highlightSettled = false;
      _highlightPositioned = false;
      _expandedNoticeIds.clear();
      _expandedTurnKeys.clear();
      _itemKeys.clear();
      _readingAnchor = null;
      _lastBottomInset = null;
      _lastLayoutHeight = null;
      _lastPhase = null;
      _justSent = false;
      _isAnimatingToBottom = false;
      _nearBottom = true;
      _layoutGeneration++;
      _scrollTriggerSub = ref.listenManual<int>(
        chatControllerProvider(widget.sessionId)
            .select((s) => s.streamingScrollTrigger),
        (_, _) {
          if (!mounted) return;
          if (_nearBottom && !_userHasScrolled && !_isUserInteracting) {
            _scrollToBottom(animated: false);
          }
        },
      );
      _phaseSub = ref.listenManual<ChatPhase>(
        chatPhaseProvider(widget.sessionId),
        (previous, next) {
          if (!mounted) return;
          if (next == ChatPhase.sending) {
            _justSent = true;
            _userHasScrolled = false;
            _nearBottom = true;
            _readingAnchor = null;
            _pinnedTranscriptCount = 0;
          } else if (next == ChatPhase.streaming) {
            if (_justSent ||
                (_nearBottom && !_userHasScrolled) ||
                previous == ChatPhase.sending) {
              _justSent = true;
              _userHasScrolled = false;
              _nearBottom = true;
              _readingAnchor = null;
              _resetAnchorStabilityState();
              _pinnedTranscriptCount = 0;
            }
          }
        },
      );
      final initialTranscript = ref.read(
        transcriptMessagesProvider(widget.sessionId),
      );
      final initialLastUser = initialTranscript
          .where((m) => m.message.role == 'user')
          .lastOrNull;
      _lastSentUserMessageId =
          initialLastUser?.message.messageId ?? initialLastUser?.message.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeResolveHighlightAndScroll();
      });
    } else if (oldWidget.highlightQuery != widget.highlightQuery) {
      _highlightTargetRenderId = null;
      _highlightSettled = false;
      _highlightPositioned = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeResolveHighlightAndScroll();
      });
    }
  }

  @override
  void dispose() {
    _scrollTriggerSub.close();
    _phaseSub.close();
    _controller.dispose();
    super.dispose();
  }

  void _maybeResolveHighlightAndScroll() {
    if (!mounted) return;
    if (_resolveHighlightTarget() && !_highlightPositioned) {
      _highlightPositioned = true;
      _scrollToHighlight();
    }
  }

  /// extent-only 增长的跟底补跳（图片异步解码撑高盲区）。
  ///
  /// 图片解码完成等事件**只增大 maxScrollExtent 而不移动 pixels**：SDK 仅在
  /// pixels 实际变化时 notifyListeners / 派发 ScrollNotification（见
  /// scroll_position.dart setPixels/forcePixels），因此 `_onScroll` 与
  /// [ScrollNotification] 监听族对此完全无感；唯一入口是
  /// [ScrollMetricsNotification]（applyContentDimensions 在 metrics 变化时经
  /// microtask 派发，官方文档明确其用途即「内容变化通常不触发 ScrollNotification」）。
  /// 跟随态（贴底且用户未上滚）→ 走 `_settleJumpToBottom` 轻量收敛链补跳；
  /// 离底阅读、手势在途、各类程序化定位在途时一律不动。
  bool _onMetricsChanged(ScrollMetricsNotification notification) {
    // 气泡内横向滚动器等内层 Scrollable 的 metrics 通知会冒泡到本监听：
    // 只响应纵向（本列表是唯一纵向滚动器）。
    if (notification.metrics.axis != Axis.vertical) return false;
    if (!_nearBottom ||
        _userHasScrolled ||
        !_initialPositioned ||
        _positioningActive ||
        _restoringOlderPosition ||
        _isUserInteracting ||
        _isAnimatingToBottom ||
        _isOutlineJumping) {
      return false;
    }
    // 仅当 extent 增长（离底）才补跳：收缩/不变时 Clamping 物理会自行拉回
    // 越界像素，无需干预（也避免视口变化路径与 LayoutBuilder 处理重复动作）。
    if (notification.metrics.maxScrollExtent - notification.metrics.pixels <=
        0.5) {
      return false;
    }
    _settleJumpToBottom(attempts: 0);
    return false;
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final distFromBottom = position.maxScrollExtent - position.pixels;
    final nearBottom = distFromBottom < _nearBottomThreshold;
    // 用户在初始定位收敛完成前的一切位置变化（含 jumpTo 自身触发）都不
    // 算用户滚动，避免估算偏差把「初始定位未到底」误判为「用户已上滚」。
    if (!_restoringOlderPosition &&
        _initialPositioned &&
        !_initialPositioning &&
        !_isAnimatingToBottom &&
        !_isOutlineJumping) {
      if (nearBottom) {
        if (!_isUserInteracting || distFromBottom <= 1.0) {
          final wasScrolled = _userHasScrolled;
          final wasNotNear = !_nearBottom;
          _userHasScrolled = false;
          _readingAnchor = null;
          _resetAnchorStabilityState();
          _pinnedTranscriptCount = 0;
          _nearBottom = true;
          if ((wasScrolled || wasNotNear) && mounted) {
            setState(() {});
          }
        }
      } else {
        // 非贴底位置：
        // 任何非触摸手势（新消息到达、键盘/输入栏高度挤压、窗口 resize、程序滚动等）
        // 一律不得置 _userHasScrolled = true；跟随状态的取消与判定全部交由
        // 手势状态机（及大纲跳转/高亮定位等主动导航）处理。
        if (!_isUserInteracting && !_userHasScrolled) {
          // 非用户交互且未主动离底：由图片异步加载、未知高度条目布局撑高或 extent 变化引起。
          // 保持 _nearBottom = true，触发自动跟底，绝不打断进入时的底部跟随。
          _scrollToBottom(animated: false);
        } else {
          final wasNear = _nearBottom;
          _nearBottom = false;
          if (wasNear && mounted) {
            setState(() {});
          }
        }
      }
    }
    if (position.pixels <= 80 &&
        _initialPositioned &&
        !_restoringOlderPosition) {
      unawaited(_loadOlderMessages());
    }
  }

  /// 记录视口顶部第一条可见条目 + 偏移（候选锚点优先级：renderId → liveRenderKey → toolGroupId → messageId，todo.md #14 / #56）。
  void _updateReadingAnchor() {
    if (!_controller.hasClients ||
        (_nearBottom && !_userHasScrolled) ||
        !mounted) {
      return;
    }
    final scrollableBox = context.findRenderObject() as RenderBox?;
    if (scrollableBox == null || !scrollableBox.attached) return;

    final transcript = ref.read(transcriptMessagesProvider(widget.sessionId));
    final liveTimeline = ref.read(liveTimelineProvider(widget.sessionId));
    final toolGroups = ref.read(toolGroupsProvider(widget.sessionId));

    _ReadingAnchor? candidate;
    _ReadingAnchor? fallbackCandidate;

    // 1. 优先扫描 transcript 消息
    for (final entry in transcript) {
      final key = _itemKeys[entry.renderId];
      if (key?.currentContext == null) continue;
      final box = key!.currentContext!.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || box.size.height == 0) continue;
      final localOffset = box.localToGlobal(
        Offset.zero,
        ancestor: scrollableBox,
      );
      final dy = localOffset.dy;
      final visibleHeight = dy >= 0 ? box.size.height : (dy + box.size.height);
      if (visibleHeight <= 0) continue;

      final group = toolGroups
          .where(
            (g) =>
                g.anchorMessageID == entry.message.messageId ||
                g.anchorMessageID == entry.anchorId,
          )
          .firstOrNull;
      final anchor = _ReadingAnchor(
        candidateKey: entry.renderId,
        renderId: entry.renderId,
        toolGroupId: group?.id,
        messageId: entry.message.messageId ?? entry.message.id,
        topOffset: dy,
      );

      // 方向 A 锚点准入收紧（#56）：可见高度 < 24px 且 < 条目高 1/3 的贴边条目跳过
      if (visibleHeight < _minAnchorVisibleHeight &&
          visibleHeight < box.size.height / 3.0) {
        fallbackCandidate ??= anchor;
        continue;
      }

      candidate = anchor;
      break;
    }

    // 2. 其次扫描 live 时间线段落
    if (candidate == null && liveTimeline != null) {
      for (final entry in liveTimeline) {
        final key = _itemKeys[entry.renderKey];
        if (key?.currentContext == null) continue;
        final box = key!.currentContext!.findRenderObject() as RenderBox?;
        if (box == null || !box.attached || box.size.height == 0) continue;
        final localOffset = box.localToGlobal(
          Offset.zero,
          ancestor: scrollableBox,
        );
        final dy = localOffset.dy;
        final visibleHeight = dy >= 0
            ? box.size.height
            : (dy + box.size.height);
        if (visibleHeight <= 0) continue;

        final anchor = _ReadingAnchor(
          candidateKey: entry.renderKey,
          liveRenderKey: entry.renderKey,
          toolGroupId: entry.toolGroup?.id,
          topOffset: dy,
        );

        if (visibleHeight < _minAnchorVisibleHeight &&
            visibleHeight < box.size.height / 3.0) {
          fallbackCandidate ??= anchor;
          continue;
        }

        candidate = anchor;
        break;
      }
    }

    final chosen = candidate ?? fallbackCandidate;
    if (chosen != null) {
      _readingAnchor = chosen;
      _anchorMissingFrames = 0;
    }
  }

  /// 内容变化 postFrame 无动画跳回锚点，绝不拉回底部（todo.md #14 / #56）。
  void _maybeRestoreReadingAnchor() {
    if (!mounted ||
        !_controller.hasClients ||
        _isUserInteracting ||
        _isAnimatingToBottom ||
        _justSent ||
        (!_userHasScrolled && _nearBottom) ||
        !_initialPositioned ||
        _positioningActive ||
        _restoringOlderPosition) {
      return;
    }
    if (_readingAnchor == null) {
      _updateReadingAnchor();
      return;
    }

    // 方向 B 防抖锁（#56）：反向补偿后冻结期内跳过补偿
    if (_anchorFreezeRemainingFrames > 0) {
      _anchorFreezeRemainingFrames--;
      return;
    }

    final anchor = _readingAnchor!;

    final scrollableBox = context.findRenderObject() as RenderBox?;
    if (scrollableBox == null || !scrollableBox.attached) return;

    // 按优先级解析锚点：transcript renderId → live entry.renderKey → 工具组 id → messageId
    GlobalKey? targetKey;
    if (anchor.renderId != null && _itemKeys.containsKey(anchor.renderId)) {
      targetKey = _itemKeys[anchor.renderId];
    } else if (anchor.liveRenderKey != null &&
        _itemKeys.containsKey(anchor.liveRenderKey)) {
      targetKey = _itemKeys[anchor.liveRenderKey];
    } else if (anchor.toolGroupId != null &&
        _itemKeys.containsKey(anchor.toolGroupId)) {
      targetKey = _itemKeys[anchor.toolGroupId];
    } else if (anchor.messageId != null &&
        _itemKeys.containsKey(anchor.messageId)) {
      targetKey = _itemKeys[anchor.messageId];
    }

    if (targetKey?.currentContext == null) {
      // 方向 C 锚点稳定性（#56）：出树时不立即换锚，容忍 <= 5 帧等待其回到树中
      _anchorMissingFrames++;
      if (_anchorMissingFrames > _maxAnchorMissingFrames) {
        _updateReadingAnchor();
      }
      return;
    }
    final box = targetKey!.currentContext!.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) {
      _anchorMissingFrames++;
      if (_anchorMissingFrames > _maxAnchorMissingFrames) {
        _updateReadingAnchor();
      }
      return;
    }

    _anchorMissingFrames = 0;
    final localOffset = box.localToGlobal(Offset.zero, ancestor: scrollableBox);
    final currentDy = localOffset.dy;
    final diff = currentDy - anchor.topOffset;

    // 方向 B 补偿死区（#56）：jump 阈值从 0.5 提至 4px
    if (diff.abs() >= _anchorDeadzoneThreshold) {
      final currentDirection = diff > 0 ? 1.0 : -1.0;
      final anchorKey = anchor.candidateKey;

      // 方向 B 防抖锁（#56）：同锚点连续两次补偿方向相反 → 冻结 10 帧
      if (_lastAnchorCompensatedKey == anchorKey &&
          _lastAnchorCompensationDirection != 0.0 &&
          currentDirection != _lastAnchorCompensationDirection) {
        _anchorFreezeRemainingFrames = _anchorFreezeFrames;
        _lastAnchorCompensationDirection = 0.0;
        return;
      }

      final newPixels = (_controller.position.pixels + diff).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      if ((newPixels - _controller.position.pixels).abs() >=
          _anchorDeadzoneThreshold) {
        _lastAnchorCompensatedKey = anchorKey;
        _lastAnchorCompensationDirection = currentDirection;
        _controller.jumpTo(newPixels);
      }
    }
    _updateReadingAnchor();
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || _olderLoadQueued || !mounted) return;
    final state = ref.read(chatControllerProvider(widget.sessionId));
    if (!state.hasOlderMessages || state.messagesOffset <= 0) return;
    _olderLoadQueued = true;
    _loadingOlder = true;
    final beforePixels = _controller.hasClients
        ? _controller.position.pixels
        : 0.0;
    final beforeExtent = _controller.hasClients
        ? _controller.position.maxScrollExtent
        : 0.0;
    _restoringOlderPosition = true;
    try {
      await ref
          .read(chatControllerProvider(widget.sessionId).notifier)
          .loadOlderMessages();
      if (!mounted) return;
      _restoreOlderScrollPosition(
        beforePixels: beforePixels,
        beforeExtent: beforeExtent,
        frame: 0,
      );
    } finally {
      _olderLoadQueued = false;
      _loadingOlder = false;
      // The post-frame callback owns the final reset. This fallback covers
      // request failures and unmounted controllers.
      if (!mounted) _restoringOlderPosition = false;
    }
  }

  void _restoreOlderScrollPosition({
    required double beforePixels,
    required double beforeExtent,
    required int frame,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) {
        _restoringOlderPosition = false;
        return;
      }
      if (frame < 2) {
        _restoreOlderScrollPosition(
          beforePixels: beforePixels,
          beforeExtent: beforeExtent,
          frame: frame + 1,
        );
        return;
      }
      final delta = _controller.position.maxScrollExtent - beforeExtent;
      final target = (beforePixels + delta).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      if (!mounted || !_controller.hasClients) {
        _restoringOlderPosition = false;
        return;
      }
      _controller.jumpTo(target);
      _restoringOlderPosition = false;
      _nearBottom =
          _controller.position.maxScrollExtent - _controller.position.pixels <
          _nearBottomThreshold;
    });
  }

  /// 初始定位是否在途（调度中或收敛循环执行中）。
  bool get _positioningActive =>
      _initialPositionScheduled || _initialPositioning;

  /// 初始定位滚到底部：lazy `ListView.builder` 首帧的 `maxScrollExtent` 是
  /// 估算值（未构建条目按平均高度折算），单次 jumpTo 会停在估算位置——
  /// 长会话下表现为「随机停在中间」。改为逐帧复核、收敛到真实底部。
  void _positionInitialView({required bool hasContent}) {
    if (!mounted ||
        !hasContent ||
        _userHasScrolled ||
        _initialPositionScheduled ||
        _initialPositioned) {
      return;
    }
    _initialPositionScheduled = true;
    final generation = ++_layoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPositionScheduled = false;
      if (!mounted || _userHasScrolled || generation != _layoutGeneration) {
        return;
      }
      // ListView 尚未挂载 controller：等待下一次 build 重试。
      if (!_controller.hasClients) return;
      _settleToBottom(generation: generation, attempts: 0);
    });
  }

  /// 收敛循环：跳到底部 → 下一帧复核 `maxScrollExtent` 是否仍在增长
  /// （新增条目改变了真实 extent）→ 增长则再跳；连续两帧稳定则一次精准
  /// jumpTo(最终 max) 收官（收官值 == max，不会越界 clamp）。
  ///
  /// 相对旧实现的改进：① 以「extent 连续稳定」为收敛条件（而非与跳转前
  /// 目标值比较），杜绝 overshoot 后像素被 ClampingScrollPhysics 拉回的
  /// 「撞击反弹」；② 超限时也做最后一次精准跳转收场（不再停在半途）。
  void _settleToBottom({
    required int generation,
    required int attempts,
    double? lastExtent,
  }) {
    if (!mounted || _userHasScrolled || generation != _layoutGeneration) {
      _initialPositioning = false;
      return;
    }
    if (attempts >= 24 || !_controller.hasClients) {
      // 尽力而为收场：以当前（最新估算/真实）extent 精准跳一次，避免停在半途。
      if (mounted &&
          _controller.hasClients &&
          !_userHasScrolled &&
          generation == _layoutGeneration) {
        final max = _controller.position.maxScrollExtent;
        final target = max.clamp(0.0, max);
        if (target > 0) {
          _controller.jumpTo(target);
          if (_controller.position.pixels >
              _controller.position.maxScrollExtent) {
            _controller.jumpTo(_controller.position.maxScrollExtent);
          }
        }
      }
      _initialPositioning = false;
      _initialPositioned = true;
      _nearBottom = true;
      _userHasScrolled = false;
      _readingAnchor = null;
      _pinnedTranscriptCount = 0;
      if (mounted) setState(() {});
      return;
    }
    final target = _controller.position.maxScrollExtent;
    if (target <= 0 && _controller.position.viewportDimension <= 0) {
      // 视口尚未布局：下一帧再试，避免空转。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _settleToBottom(
          generation: generation,
          attempts: attempts + 1,
          lastExtent: lastExtent,
        );
      });
      return;
    }
    // extent 已连续两帧不变 → 真实底部已确定，最终精准跳一次收场。
    if (lastExtent != null && (target - lastExtent).abs() <= 0.5) {
      _finishSettleWithTarget(generation);
      return;
    }
    _initialPositioning = true;
    if (!mounted || !_controller.hasClients) {
      _initialPositioning = false;
      return;
    }
    final clampedTarget = target.clamp(0.0, target);
    if (clampedTarget > 0) {
      _controller.jumpTo(clampedTarget);
      if (_controller.position.pixels > _controller.position.maxScrollExtent) {
        _controller.jumpTo(_controller.position.maxScrollExtent);
      }
    }
    // 下一帧复核真实 extent 是否与跳转目标仍有出入。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userHasScrolled || generation != _layoutGeneration) {
        _initialPositioning = false;
        return;
      }
      if (!_controller.hasClients) {
        _initialPositioning = false;
        return;
      }
      _settleToBottom(
        generation: generation,
        attempts: attempts + 1,
        lastExtent: _controller.position.maxScrollExtent,
      );
    });
  }

  /// 收敛收官：以当前真实 maxScrollExtent 精准跳一次并标记定位完成。
  /// （收官值恒等于 extent 本身，无越界 clamp，无回弹。）
  void _finishSettleWithTarget(int generation) {
    if (mounted &&
        _controller.hasClients &&
        !_userHasScrolled &&
        generation == _layoutGeneration) {
      final max = _controller.position.maxScrollExtent;
      final target = max.clamp(0.0, max);
      if (target > 0) {
        _controller.jumpTo(target);
        if (_controller.position.pixels >
            _controller.position.maxScrollExtent) {
          _controller.jumpTo(_controller.position.maxScrollExtent);
        }
      }
    }
    _initialPositioning = false;
    _initialPositioned = true;
    _nearBottom = true;
    _userHasScrolled = false;
    _readingAnchor = null;
    _pinnedTranscriptCount = 0;
    if (mounted) setState(() {});
  }

  void _scrollToBottom({bool animated = true}) {
    if (!mounted || !_controller.hasClients) return;
    if (_positioningActive) return;
    final target = _controller.position.maxScrollExtent;
    if (target <= 0) return;
    if (animated) {
      if (_isAnimatingToBottom) return;
      _isAnimatingToBottom = true;
      unawaited(
        _controller
            .animateTo(
              target,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            )
            .whenComplete(() {
              if (mounted) {
                _isAnimatingToBottom = false;
                _nearBottom = true;
                _userHasScrolled = false;
                _readingAnchor = null;
                _resetAnchorStabilityState();
                _pinnedTranscriptCount = 0;
                _settleJumpToBottom(attempts: 0);
              }
            }),
      );
    } else {
      if (_isAnimatingToBottom) return;
      _settleJumpToBottom(attempts: 0);
    }
  }

  /// 非动画跳底的轻量收敛链（#23 发送/流式跟随路径）。
  ///
  /// 旧实现 `jumpTo(target)` 在调用时**同步**读取 `maxScrollExtent`：若此刻
  /// 新气泡尚未布局完（extent 仍处增长/估算态，如 sending 指示器、流式气泡、
  /// live 时间线条目刚入场），目标与真实底部不一致；`jumpTo` 又**不做任何
  /// 边界修正**（`forcePixels` 直写），落点越界后其收尾的 `goBallistic(0)`
  /// 被 ClampingScrollPhysics 判为 `outOfRange`，随即启动 ScrollSpringSimulation
  /// 弹簧把像素拉回边界 → 肉眼「下拉拉超又弹回」。
  ///
  /// 本方法沿用 `_settleToBottom` 的「extent 收敛」思想但刻意轻量：
  /// ① 每次跳转都在 **post-frame 读取 extent**——拿到的是「刚布局完」的
  /// 真实底部，跳转目标恒等于当帧 `maxScrollExtent`，落点必在界内
  /// （pixels == max ⇒ outOfRange 为 false，引擎不会起弹簧）；
  /// ② 复核链最多 `_maxJumpResettle` 轮就收手（发送路径不跑 24 轮收敛），
  /// 收敛条件 = 跳后一帧 extent 不再增长（pixels 已贴住 maxScrollExtent）。
  void _settleJumpToBottom({required int attempts}) {
    if (_jumpSettling || !mounted || !_controller.hasClients) return;
    if (_userHasScrolled || !_nearBottom || _isUserInteracting) return;
    _jumpSettling = true;
    final generation = _layoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_controller.hasClients ||
          generation != _layoutGeneration ||
          _isAnimatingToBottom ||
          _userHasScrolled ||
          !_nearBottom ||
          _isUserInteracting) {
        _jumpSettling = false;
        return;
      }
      final position = _controller.position;
      final max = position.maxScrollExtent;
      // 已贴底（且未越界）：上一轮跳转已收敛，无需动作。
      if ((max - position.pixels).abs() <= 0.5) {
        _jumpSettling = false;
        return;
      }
      // 落点恒为当帧 maxScrollExtent（界内）：goBallistic(0) 不会起弹簧。
      // 若前帧 extent 收缩导致像素越界，此跳亦完成精准拉回（直跳非弹簧）。
      _controller.jumpTo(max);
      if (_controller.position.pixels > _controller.position.maxScrollExtent) {
        _controller.jumpTo(_controller.position.maxScrollExtent);
      }
      if (attempts >= _maxJumpResettle) {
        _jumpSettling = false;
        return;
      }
      // 下一帧复核：extent 若仍在增长（新气泡未布局完）则继续追底。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_controller.hasClients ||
            generation != _layoutGeneration ||
            _isAnimatingToBottom ||
            _userHasScrolled ||
            !_nearBottom ||
            _isUserInteracting) {
          _jumpSettling = false;
          return;
        }
        _jumpSettling = false;
        _settleJumpToBottom(attempts: attempts + 1);
      });
    });
  }

  /// 解析搜索定位目标（幂等）：在 transcript 里找第一条含关键词的消息，用 renderId。
  ///
  /// transcript 尚未加载完成时返回 false，由下一次重试；已加载但无匹配 → 置 settled 不再尝试。
  bool _resolveHighlightTarget() {
    if (_highlightSettled) return true;
    final query = widget.highlightQuery;
    if (query == null || query.isEmpty) {
      _highlightSettled = true;
      _highlightTargetRenderId = null;
      return true;
    }
    final transcript = ref.read(transcriptMessagesProvider(widget.sessionId));
    if (transcript.isEmpty) {
      final raw = ref.read(chatControllerProvider(widget.sessionId));
      if (raw.messages.isEmpty) return false;
      // transcript 为空但 raw 非空（被过滤为 tool-only），视为无匹配。
      _highlightSettled = true;
      return true;
    }
    final lower = query.toLowerCase();
    for (final entry in transcript) {
      final text = entry.message.content ?? '';
      if (text.toLowerCase().contains(lower)) {
        _highlightTargetRenderId = entry.renderId;
        break;
      }
    }
    _highlightSettled = true;
    return true;
  }

  /// 定位到高亮消息：优先 GlobalKey.ensureVisible；未构建（列表懒加载）
  /// 时先按索引比例粗跳，下一帧再 ensureVisible。
  void _scrollToHighlight() {
    if (_highlightTargetRenderId == null) return;
    final transcript = ref.read(transcriptMessagesProvider(widget.sessionId));
    _userHasScrolled = true;
    _nearBottom = false;
    _justSent = false;
    _readingAnchor = null;
    _resetAnchorStabilityState();
    _pinnedTranscriptCount = transcript.length;
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final ctx = _highlightKey.currentContext;
      if (ctx != null) {
        final renderObject = ctx.findRenderObject();
        if (renderObject == null || !renderObject.attached) {
          // detached → 尝试 fallback 粗跳。
        } else {
          if (ctx is Element && !ctx.mounted) return;
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 350),
            alignment: 0.25,
          );
          return;
        }
      }
      // 目标未构建或 detached：按「目标序次 / 消息总数」比例粗跳到附近。
      final transcript = ref.read(transcriptMessagesProvider(widget.sessionId));
      final index = transcript.indexWhere(
        (e) => e.renderId == _highlightTargetRenderId,
      );
      if (index < 0 || transcript.isEmpty) return;
      if (!mounted || !_controller.hasClients) return;
      final ratio = index / transcript.length;
      final target = _controller.position.maxScrollExtent * ratio;
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(target);
      // 下一帧再精确对准（此时目标多半已入视口构建）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        final retryCtx = _highlightKey.currentContext;
        if (retryCtx == null) return;
        final renderObject = retryCtx.findRenderObject();
        if (renderObject == null || !renderObject.attached) return;
        if (retryCtx is Element && !retryCtx.mounted) return;
        Scrollable.ensureVisible(
          retryCtx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.25,
        );
      });
    });
  }

  /// 大纲跳转：将指定 renderId 的用户气泡顶部贴至视口顶部（alignment 0.0）。
  ///
  /// 大纲跳转属于主动阅读行为（active.md 大纲点击跳转跑飞规格）：
  /// 1. 入口立即进入离底阅读态（`_userHasScrolled = true`, `_nearBottom = false`,
  ///    `_readingAnchor = null`），暂停跟随，流式生成中亦不拽回底部；
  /// 2. 若目标已在 DOM 中构建，直接 `Scrollable.ensureVisible` + 导航栏补偿；
  /// 3. 否则基于已构建条目的实际像素位置与锚点比例进行粗跳（避免 `maxExtent * ratio`
  ///    因虚拟化估算落底误入跟随），下一帧目标入视口后再 `ensureVisible` 精定；
  /// 4. 完成后更新阅读锚点 `_readingAnchor`，右下角展示回底按钮。
  void outlineJumpTo(String renderId, int loadedIndex, {int retryCount = 0}) {
    if (!mounted || !_controller.hasClients) return;
    const kNavBarHeight = 44.0;
    final topPadding = MediaQuery.of(context).padding.top + kNavBarHeight;

    final transcript = ref.read(transcriptMessagesProvider(widget.sessionId));
    _userHasScrolled = true;
    _nearBottom = false;
    _isUserInteracting = false;
    _justSent = false;
    _readingAnchor = null;
    _resetAnchorStabilityState();
    _pinnedTranscriptCount = transcript.length;
    _isOutlineJumping = true;
    setState(() {});

    // 1. 尝试精跳（目标已构建）
    final key = _itemKeys[renderId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      final renderObject = ctx.findRenderObject();
      if (renderObject != null &&
          renderObject.attached &&
          (ctx is! Element || ctx.mounted)) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.0,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          ).then((_) {
            _finishOutlineJump(topPadding);
          }),
        );
        return;
      }
    }

    // 2. 粗跳估算（基于已构建条目的真实位置插值，避免虚拟化 maxExtent 估算偏底）
    final coarse = _estimateCoarseJumpOffset(loadedIndex, transcript);
    _controller.jumpTo(
      coarse.clamp(
        _controller.position.minScrollExtent,
        _controller.position.maxScrollExtent,
      ),
    );

    // 下一帧再精定（目标多已入视口构建）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) {
        _isOutlineJumping = false;
        return;
      }
      final retryKey = _itemKeys[renderId];
      final retryCtx = retryKey?.currentContext;
      if (retryCtx != null) {
        final renderObject = retryCtx.findRenderObject();
        if (renderObject != null &&
            renderObject.attached &&
            (retryCtx is! Element || retryCtx.mounted)) {
          unawaited(
            Scrollable.ensureVisible(
              retryCtx,
              alignment: 0.0,
              alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            ).then((_) {
              _finishOutlineJump(topPadding);
            }),
          );
          return;
        }
      }

      // 若单次粗跳后目标仍未入视口（极长/长短极端混合），最多重试 2 轮收敛
      if (retryCount < 2) {
        outlineJumpTo(renderId, loadedIndex, retryCount: retryCount + 1);
      } else {
        _finishOutlineJump(topPadding);
      }
    });
  }

  /// 基于已构建条目的实际渲染位置估算未构建目标索引的像素偏移。
  double _estimateCoarseJumpOffset(
    int loadedIndex,
    List<TranscriptMessage> transcript,
  ) {
    if (loadedIndex <= 0 || transcript.isEmpty) return 0.0;
    final scrollableBox = context.findRenderObject() as RenderBox?;
    if (scrollableBox == null || !scrollableBox.attached) {
      return (loadedIndex * 120.0).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
    }

    int? minRenderedIndex;
    double? minRenderedOffset;
    int? maxRenderedIndex;
    double? maxRenderedOffset;

    for (var i = 0; i < transcript.length; i++) {
      final entry = transcript[i];
      final itemKey = _itemKeys[entry.renderId];
      final itemCtx = itemKey?.currentContext;
      if (itemCtx == null) continue;
      final box = itemCtx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || box.size.height == 0) continue;
      final localOffset = box.localToGlobal(
        Offset.zero,
        ancestor: scrollableBox,
      );
      final itemScrollOffset = _controller.position.pixels + localOffset.dy;
      if (minRenderedIndex == null || i < minRenderedIndex) {
        minRenderedIndex = i;
        minRenderedOffset = itemScrollOffset;
      }
      if (maxRenderedIndex == null || i > maxRenderedIndex) {
        maxRenderedIndex = i;
        maxRenderedOffset = itemScrollOffset;
      }
    }

    final maxExtent = _controller.position.maxScrollExtent;

    if (minRenderedIndex != null && minRenderedOffset != null) {
      if (loadedIndex < minRenderedIndex) {
        if (minRenderedIndex <= 0) return 0.0;
        final ratio = loadedIndex / minRenderedIndex;
        return (minRenderedOffset * ratio).clamp(0.0, maxExtent);
      } else if (maxRenderedIndex != null &&
          maxRenderedOffset != null &&
          loadedIndex > maxRenderedIndex) {
        final remaining = transcript.length - 1 - maxRenderedIndex;
        if (remaining <= 0) return maxExtent;
        final ratio = (loadedIndex - maxRenderedIndex) / remaining;
        final distToMax = math.max(0.0, maxExtent - maxRenderedOffset);
        return (maxRenderedOffset + distToMax * ratio).clamp(0.0, maxExtent);
      } else if (minRenderedIndex != maxRenderedIndex &&
          maxRenderedIndex != null &&
          maxRenderedOffset != null) {
        final ratio =
            (loadedIndex - minRenderedIndex) /
            (maxRenderedIndex - minRenderedIndex);
        return (minRenderedOffset +
                (maxRenderedOffset - minRenderedOffset) * ratio)
            .clamp(0.0, maxExtent);
      }
    }

    // 无构建条目参考时按保守平均高度估算
    return (loadedIndex * 120.0).clamp(0.0, maxExtent);
  }

  /// 完成大纲跳转的导航栏高度补偿与阅读状态锁定。
  void _finishOutlineJump(double topPadding) {
    if (!mounted || !_controller.hasClients) {
      _isOutlineJumping = false;
      return;
    }
    final current = _controller.position.pixels;
    final adjusted = math.max(0.0, current - topPadding);
    if ((adjusted - current).abs() > 1) {
      unawaited(
        _controller
            .animateTo(
              adjusted,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
            )
            .then((_) {
              if (!mounted) return;
              _isOutlineJumping = false;
              _userHasScrolled = true;
              _nearBottom = false;
              _readingAnchor = null;
              _resetAnchorStabilityState();
              _updateReadingAnchor();
              if (mounted) setState(() {});
            }),
      );
    } else {
      _isOutlineJumping = false;
      _userHasScrolled = true;
      _nearBottom = false;
      _readingAnchor = null;
      _resetAnchorStabilityState();
      _updateReadingAnchor();
      if (mounted) setState(() {});
    }
  }

  /// 长按/右键消息弹操作菜单并执行动作。
  Future<void> _showMessageActions(ChatMessage message) async {
    final action = await showMessageActionMenu(context, message: message);
    if (action == null || !mounted) return;
    final controller = ref.read(
      chatControllerProvider(widget.sessionId).notifier,
    );
    switch (action) {
      case MessageAction.copy:
      case MessageAction.copyMd:
        // 先提示，再异步写剪贴板（立即反馈，不阻塞菜单关闭）。
        unawaited(copyMessageText(message));
        if (mounted) {
          controller.setNotice(
            AppLocalizations.of(context).copiedToClipboardNotice,
          );
        }
      case MessageAction.edit:
        final text = message.content;
        if (text != null && text.isNotEmpty) {
          controller.prefillComposer(text);
        }
      case MessageAction.branch:
        final branchIndex = ref
            .read(chatControllerProvider(widget.sessionId))
            .messages
            .indexWhere((m) => m.id == message.id);
        if (branchIndex >= 0) {
          final newId = await controller.branchAt(branchIndex);
          if (newId != null && mounted) {
            context.go('/chat/$newId');
          }
        }
      case MessageAction.truncate:
        final index = ref
            .read(chatControllerProvider(widget.sessionId))
            .messages
            .indexWhere((m) => m.id == message.id);
        if (index >= 0) await controller.truncateAt(index);
    }
  }

  /// 手势松手结束：按累计位移方向与按压前跟随态定夺最终跟随状态（#41）。
  void _handleGestureEnd() {
    if (!_isGestureActive) return;
    _isGestureActive = false;
    _isUserInteracting = false;

    if (!_initialPositioned || _initialPositioning || _restoringOlderPosition) {
      _dragDisplacement = 0.0;
      _dragExceededThreshold = false;
      return;
    }

    final wasUserHasScrolled = _userHasScrolled;
    final wasNearBottom = _nearBottom;

    if (!_dragExceededThreshold ||
        _dragDisplacement.abs() < _dragSensitivityThreshold) {
      // 3. 无位移（轻点已排除）→ 状态回到按压前（不改变）
      _userHasScrolled = !_pressFollowed;
      if (!_userHasScrolled) {
        _nearBottom = true;
        _readingAnchor = null;
        _resetAnchorStabilityState();
        _pinnedTranscriptCount = 0;
      }
    } else if (_dragDisplacement < -_dragSensitivityThreshold) {
      // 2. 累计向下滑（=内容向下=朝顶部，手指从下往上滑，pixels 减小）→ 一定取消跟随
      _userHasScrolled = true;
      _nearBottom = false;
      if (!wasUserHasScrolled) {
        _pinnedTranscriptCount = ref
            .read(transcriptMessagesProvider(widget.sessionId))
            .length;
      }
    } else if (_dragDisplacement > _dragSensitivityThreshold) {
      // 1. 累计向上滑（=内容向上=朝底部，手指从上往下滑，pixels 增大）
      if (_pressFollowed) {
        // 按压前跟随中 → 恢复跟随（继续跟）
        _userHasScrolled = false;
        _nearBottom = true;
        _readingAnchor = null;
        _resetAnchorStabilityState();
        _pinnedTranscriptCount = 0;
      } else {
        // 按压前不跟随 → 若松手位置接近底部超 80px 阈值 → 进入跟随；否则保持不跟随
        final distFromBottom = _controller.hasClients
            ? _controller.position.maxScrollExtent - _controller.position.pixels
            : 0.0;
        if (distFromBottom < _nearBottomThreshold) {
          _userHasScrolled = false;
          _nearBottom = true;
          _readingAnchor = null;
          _resetAnchorStabilityState();
          _pinnedTranscriptCount = 0;
        } else {
          _userHasScrolled = true;
          _nearBottom = false;
        }
      }
    }

    _dragDisplacement = 0.0;
    _dragExceededThreshold = false;

    if ((wasUserHasScrolled != _userHasScrolled ||
            wasNearBottom != _nearBottom) &&
        mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final collapseEnabled = ref.watch(
      injectedNoticeSettingsProvider.select((s) => s.collapseInjectedNotices),
    );
    final coalesce = ref.watch(toolGroupCoalesceProvider);
    final transcript = ref.watch(transcriptMessagesProvider(sessionId));
    final streaming = ref.watch(streamingMessageProvider(sessionId));
    final liveTimeline = ref.watch(liveTimelineProvider(sessionId));
    final toolGroups = ref.watch(toolGroupsProvider(sessionId));
    final phase = ref.watch(chatPhaseProvider(sessionId));
    // #70 折叠误闪门控：live 会话刷新时「回合是否完成」存在两个误判窗口——
    // ① 缓存回放态（isViewingCachedData）：网络未回先铺缓存，phase=idle、
    //    activeStreamId=null，缓存里进行中的最后回合被当已完成 → 胶囊闪现，
    //    网络恢复带回流信息后又消失（主人实机所见「刷新闪现、过会没了」）；
    // ② 流仍活跃但相位非 streaming（recovering/steered 等）：phase/streaming
    //    两项判定漏放行。
    // 门控 = 流权威信号（activeStreamId）+ 缓存回放态双保险：流状态未确认
    // 前，最后回合一律不算完成、不折叠。
    final hasActiveStream = ref.watch(
      chatControllerProvider(sessionId)
          .select((s) => s.stream.activeStreamId != null),
    );
    final isViewingCachedData = ref.watch(
      chatControllerProvider(sessionId).select((s) => s.isViewingCachedData),
    );
    final queuedMessages = ref.watch(
      chatControllerProvider(sessionId).select((s) => s.queuedSlashMessages),
    );

    final entryToolGroups = <String, List<ToolCallGroup>>{};
    final mountedGroupIds = <String>{};
    for (final entry in transcript) {
      final msgId = entry.message.messageId;
      final anchorId = entry.anchorId;
      final matched = <ToolCallGroup>[];
      for (final g in toolGroups) {
        if (!coalesce && mountedGroupIds.contains(g.id)) {
          continue;
        }
        final isMatch =
            (msgId != null && msgId.isNotEmpty && g.anchorMessageID == msgId) ||
            (g.anchorMessageID != null && g.anchorMessageID == anchorId);
        if (isMatch) {
          matched.add(g);
          if (!coalesce) {
            mountedGroupIds.add(g.id);
          }
        }
      }
      entryToolGroups[entry.renderId] = matched;
    }

    // 初始定位与搜索定位均以 postFrame 调度，避免 build 期间同步 markNeedsBuild
    // 或在 dependents 未就绪时触发 listen 副作用。
    _positionInitialView(
      hasContent: transcript.isNotEmpty || streaming != null,
    );
    if (!_highlightSettled ||
        (_highlightTargetRenderId != null && !_highlightPositioned)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_resolveHighlightTarget() && !_highlightPositioned) {
          _highlightPositioned = true;
          _scrollToHighlight();
        }
      });
    }

    final lastUserMsg = transcript
        .where((m) => m.message.role == 'user')
        .lastOrNull;
    final lastUserMsgId =
        lastUserMsg?.message.messageId ?? lastUserMsg?.message.id;
    final hasNewUserMessage =
        lastUserMsgId != null &&
        _lastSentUserMessageId != null &&
        lastUserMsgId != _lastSentUserMessageId;
    if (_lastSentUserMessageId == null && lastUserMsgId != null) {
      _lastSentUserMessageId = lastUserMsgId;
    } else if (hasNewUserMessage) {
      _lastSentUserMessageId = lastUserMsgId;
      _justSent = true;
      _userHasScrolled = false;
      _nearBottom = true;
      _readingAnchor = null;
      _resetAnchorStabilityState();
      _pinnedTranscriptCount = 0;
    }

    final phaseChanged = _lastPhase != phase;
    _lastPhase = phase;

    // 全平台软键盘监听（viewInsets.bottom 变化驱动，todo.md #13）
    final currentBottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final bottomInsetChange =
        _lastBottomInset != null && _lastBottomInset != currentBottomInset;
    _lastBottomInset = currentBottomInset;
    if (bottomInsetChange &&
        _nearBottom &&
        !_userHasScrolled &&
        _initialPositioned &&
        !_positioningActive &&
        !_restoringOlderPosition) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        if (_nearBottom &&
            !_userHasScrolled &&
            !_positioningActive &&
            !_restoringOlderPosition) {
          _scrollToBottom(animated: false);
        }
      });
    }

    // 消息刷新与内容变化：若 _nearBottom 则无动画 jump 回底（#13）；若离底阅读则保持锚点不拉底（#14）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      if (_justSent ||
          (phaseChanged &&
              !_userHasScrolled &&
              (phase == ChatPhase.sending ||
                  (phase == ChatPhase.streaming && _nearBottom)))) {
        // 用户刚发送或阶段切换（sending/streaming 开始）保持 200ms animateTo 平滑动画（#13/#14）
        _justSent = false;
        _scrollToBottom(animated: true);
      } else if (_nearBottom &&
          !_userHasScrolled &&
          !_isUserInteracting &&
          _initialPositioned &&
          !_positioningActive &&
          !_restoringOlderPosition) {
        // 消息刷新与增量更新无动画 jump 回底（#13）
        _scrollToBottom(animated: false);
      } else if (_userHasScrolled &&
          !_nearBottom &&
          !_justSent &&
          !_isAnimatingToBottom &&
          _initialPositioned) {
        if (_readingAnchor == null) {
          if (!_isUserInteracting) {
            _updateReadingAnchor();
          }
        } else {
          _maybeRestoreReadingAnchor();
        }
      }
    });

    // live 时间线模式：streaming 且 provider 非 null（null = 重连归档等
    // 无法还原段落边界的场景，回退旧分组式流式气泡）。
    final timelineActive = streaming != null && liveTimeline != null;
    final liveReasoningText = ref
        .read(chatControllerProvider(sessionId))
        .liveReasoningText;
    final hideThinking = ref.watch(hideReasoningProvider);
    // legacy（非时间线）模式：live 思考并入工具组（think 子卡行前置）。
    final streamingTools = streaming == null || liveTimeline != null
        ? const <ToolCallGroup>[]
        : [
            for (final g in toolGroups)
              if (g.anchorMessageID == streaming.messageId)
                (hideThinking || liveReasoningText.trim().isEmpty)
                    ? g
                    : ToolCallGroup(
                        id: g.id,
                        anchorMessageID: g.anchorMessageID,
                        precedingMessageID: g.precedingMessageID,
                        isAboveContent: g.isAboveContent,
                        toolCalls: [
                          ToolCall.thinking(liveReasoningText.trim()),
                          ...g.toolCalls,
                        ],
                      ),
          ];

    final turnCollapseEnabled = ref.watch(turnCollapseProvider);

    // 回合分组（#55 过程折叠）
    final turns = <_TurnInfo>[];
    _TurnInfo? currentTurn;
    for (final entry in transcript) {
      if (TranscriptTurnClassifier.isUserTurnBoundary(entry.message)) {
        currentTurn = _TurnInfo(
          turnKey: 'turn:user:${entry.loadedIndex}',
          userEntry: entry,
          assistantEntries: [],
        );
        turns.add(currentTurn);
      } else if (entry.message.role == 'assistant') {
        if (currentTurn == null) {
          currentTurn = _TurnInfo(
            turnKey: 'turn:orphan:${entry.loadedIndex}',
            assistantEntries: [entry],
          );
          turns.add(currentTurn);
        } else {
          currentTurn.assistantEntries.add(entry);
        }
      } else {
        if (currentTurn == null) {
          currentTurn = _TurnInfo(
            turnKey: 'turn:other:${entry.loadedIndex}',
            userEntry: entry,
            assistantEntries: [],
          );
          turns.add(currentTurn);
        } else if (currentTurn.userEntry == null) {
          currentTurn = _TurnInfo(
            turnKey: 'turn:user:${entry.loadedIndex}',
            userEntry: entry,
            assistantEntries: [],
          );
          turns.add(currentTurn);
        } else {
          currentTurn.assistantEntries.add(entry);
        }
      }
    }

    final displayItems = <_ChatListItem>[];
    for (var i = 0; i < turns.length; i++) {
      final turn = turns[i];
      final isLastTurn = i == turns.length - 1;
      final isTurnCompleted =
          !isLastTurn ||
          (streaming == null &&
              !hasActiveStream &&
              !isViewingCachedData &&
              phase != ChatPhase.streaming &&
              phase != ChatPhase.sending);

      final collapsible = _isTurnCollapsible(
        turn: turn,
        turnCollapseEnabled: turnCollapseEnabled,
        isTurnCompleted: isTurnCompleted,
        entryToolGroups: entryToolGroups,
        hideThinking: hideThinking,
      );

      if (!collapsible) {
        if (turn.userEntry != null) {
          displayItems.add(
            _MessageListItem(
              entry: turn.userEntry!,
              groups: entryToolGroups[turn.userEntry!.renderId] ?? const [],
              isHidden: false,
              isFinalAssistantInCollapsedTurn: false,
            ),
          );
        }
        for (final a in turn.assistantEntries) {
          displayItems.add(
            _MessageListItem(
              entry: a,
              groups: entryToolGroups[a.renderId] ?? const [],
              isHidden: false,
              isFinalAssistantInCollapsedTurn: false,
            ),
          );
        }
      } else {
        final hasHighlightTarget =
            _highlightTargetRenderId != null &&
            turn.allEntries.any((e) => e.renderId == _highlightTargetRenderId);
        final isExpanded =
            _expandedTurnKeys.contains(turn.turnKey) ||
            (hasHighlightTarget &&
                _highlightTargetRenderId != turn.userEntry?.renderId &&
                _highlightTargetRenderId != turn.finalAssistantEntry?.renderId);

        // 1. 主人提问气泡（常显，#58：胶囊改钉气泡下方，提问先行）
        if (turn.userEntry != null) {
          displayItems.add(
            _MessageListItem(
              entry: turn.userEntry!,
              groups: entryToolGroups[turn.userEntry!.renderId] ?? const [],
              isHidden: false,
              isFinalAssistantInCollapsedTurn: false,
            ),
          );
        }

        // 2. 胶囊行置于提问气泡下方、最终答复上方（#58 改判，推翻 #55「回合最上方」）
        displayItems.add(
          _CapsuleListItem(
            turn: turn,
            isExpanded: isExpanded,
            toolGroups: turn.allToolGroups(entryToolGroups),
            intermediateTextCount: turn.intermediateTextCount,
          ),
        );

        // 3. 助手消息：中间助手及尾随助手收起时隐藏，最终答复常显（收起时仅露文本）
        final finalEntry = turn.finalAssistantEntry!;
        for (final a in turn.assistantEntries) {
          if (a == finalEntry) {
            displayItems.add(
              _MessageListItem(
                entry: a,
                groups: isExpanded
                    ? (entryToolGroups[a.renderId] ?? const [])
                    : const <ToolCallGroup>[],
                isHidden: false,
                isFinalAssistantInCollapsedTurn: !isExpanded,
              ),
            );
          } else {
            displayItems.add(
              _MessageListItem(
                entry: a,
                groups: entryToolGroups[a.renderId] ?? const [],
                isHidden: !isExpanded,
                isFinalAssistantInCollapsedTurn: false,
              ),
            );
          }
        }
      }
    }

    final showQueuedBanner = queuedMessages.isNotEmpty;
    // 落地兜底：仅在 coalesce==true 且 transcript 为空且无可挂载 anchor 时渲染聚合视图
    final needFallback =
        coalesce &&
        transcript.isEmpty &&
        streaming == null &&
        phase != ChatPhase.sending &&
        toolGroups.isNotEmpty;

    // live 段落条目数：时间线模式 = 段数（空段列表 = 思考中指示器 1 条）；
    // legacy 模式 = 单个流式气泡。
    // #52 统一状态行：sending / 等待 prefill / 生成中 / recovery / prefill error 期间
    // 在列表尾部显示一行状态指示（开关控制 + 空闲自动隐藏）。
    final prefillStatus = ref.watch(
      chatControllerProvider(sessionId).select((s) => s.prefillStatus),
    );
    final statusLineEnabled = ref.watch(chatStatusLineProvider);
    final showStatusLine =
        statusLineEnabled &&
        (phase == ChatPhase.sending ||
            streaming != null ||
            prefillStatus == ContextPrefillStatus.loading ||
            prefillStatus == ContextPrefillStatus.notConfigured ||
            prefillStatus == ContextPrefillStatus.error);
    final liveItemCount = streaming == null
        ? 0
        : liveTimeline == null
        ? 1
        : liveTimeline.length;

    var itemCount = displayItems.length + liveItemCount;
    if (showStatusLine) itemCount++;
    if (showQueuedBanner) itemCount++;
    if (needFallback) itemCount++;

    final isEnglish = AppLocalizations.of(context).isEnglish;
    final unreadCount =
        (_pinnedTranscriptCount > 0 &&
            transcript.length > _pinnedTranscriptCount)
        ? transcript.length - _pinnedTranscriptCount
        : 0;
    final buttonLabel = unreadCount > 0
        ? (isEnglish ? '$unreadCount new messages' : '$unreadCount 条新消息')
        : (isEnglish ? 'Scroll to bottom' : '回到底部');
    final distFromBottom = _controller.hasClients
        ? _controller.position.maxScrollExtent - _controller.position.pixels
        : 0.0;
    final showScrollToBottomButton =
        _initialPositioned &&
        _controller.hasClients &&
        (_userHasScrolled || !_nearBottom) &&
        distFromBottom >= 20.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final currentHeight = constraints.maxHeight;
        final heightChange =
            _lastLayoutHeight != null &&
            (_lastLayoutHeight! - currentHeight).abs() > 0.5;
        _lastLayoutHeight = currentHeight;

        if (heightChange &&
            _nearBottom &&
            !_userHasScrolled &&
            _initialPositioned &&
            !_positioningActive &&
            !_restoringOlderPosition) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_controller.hasClients) return;
            if (_nearBottom &&
                !_userHasScrolled &&
                !_positioningActive &&
                !_restoringOlderPosition) {
              _scrollToBottom(animated: false);
            }
          });
        }

        return NotificationListener<ScrollMetricsNotification>(
          onNotification: _onMetricsChanged,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) {
                if (notification.dragDetails != null) {
                  _isUserInteracting = true;
                  _isGestureActive = true;
                  _pressFollowed = !_userHasScrolled;
                  _dragDisplacement = 0.0;
                  _dragExceededThreshold = false;
                }
              } else if (notification is UserScrollNotification) {
                if (notification.direction == ScrollDirection.idle) {
                  if (_isGestureActive) {
                    _handleGestureEnd();
                  } else {
                    _isUserInteracting = false;
                  }
                } else {
                  _isUserInteracting = true;
                }
              } else if (notification is ScrollUpdateNotification) {
                if (notification.dragDetails != null || _isGestureActive) {
                  _isUserInteracting = true;
                  final stepDelta =
                      (notification.scrollDelta != null &&
                          notification.scrollDelta! != 0)
                      ? notification.scrollDelta!
                      : -(notification.dragDetails?.delta.dy ?? 0.0);
                  _dragDisplacement += stepDelta;

                  if (!_dragExceededThreshold &&
                      _dragDisplacement.abs() >= _dragSensitivityThreshold) {
                    _dragExceededThreshold = true;
                    // 拖动开始超过 8px 敏感阈值即置取消（解锁自由滚动，不滚到离底不算用户离开）
                    if (_initialPositioned &&
                        !_initialPositioning &&
                        !_restoringOlderPosition) {
                      final wasNotScrolled = !_userHasScrolled;
                      if (!_userHasScrolled) {
                        _pinnedTranscriptCount = ref
                            .read(transcriptMessagesProvider(widget.sessionId))
                            .length;
                      }
                      _userHasScrolled = true;
                      _nearBottom = false;
                      if (wasNotScrolled && mounted) {
                        setState(() {});
                      }
                    }
                  }
                }
              } else if (notification is ScrollEndNotification) {
                if (_isGestureActive) {
                  _handleGestureEnd();
                } else {
                  _isUserInteracting = false;
                }
              }
              return false;
            },
            child: Stack(
              children: [
                ListView.builder(
                  controller: _controller,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  addRepaintBoundaries: true,
                  addAutomaticKeepAlives: false,
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    // 统一尾部顺序：transcript | queued | steer | streaming | sending | fallback
                    if (index < displayItems.length) {
                      final item = displayItems[index];
                      if (item is _CapsuleListItem) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: CollapsibleProcessCapsule(
                            toolGroups: item.toolGroups,
                            intermediateTextCount: item.intermediateTextCount,
                            hideThinking: hideThinking,
                            isExpanded: item.isExpanded,
                            onToggle: () {
                              if (!mounted) return;
                              setState(() {
                                if (_expandedTurnKeys.contains(
                                  item.turn.turnKey,
                                )) {
                                  _expandedTurnKeys.remove(item.turn.turnKey);
                                } else {
                                  _expandedTurnKeys.add(item.turn.turnKey);
                                }
                              });
                            },
                          ),
                        );
                      }
                      final msgItem = item as _MessageListItem;
                      final entry = msgItem.entry;
                      final groups = msgItem.groups;
                      final noticeId = entry.message.id;
                      final expanded = _expandedNoticeIds.contains(noticeId);
                      final isHighlightTarget =
                          _highlightTargetRenderId != null &&
                          entry.renderId == _highlightTargetRenderId;
                      final entryKey = _itemKeys.putIfAbsent(
                        entry.renderId,
                        () => GlobalKey(),
                      );
                      if (entry.message.messageId != null &&
                          entry.message.messageId!.isNotEmpty) {
                        _itemKeys.putIfAbsent(
                          entry.message.messageId!,
                          () => entryKey,
                        );
                      }
                      for (final g in groups) {
                        _itemKeys.putIfAbsent(g.id, () => entryKey);
                      }

                      if (msgItem.isHidden) {
                        return KeyedSubtree(
                          key: entryKey,
                          child: const SizedBox.shrink(),
                        );
                      }

                      return KeyedSubtree(
                        key: isHighlightTarget ? _highlightKey : entryKey,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPress: () => _showMessageActions(entry.message),
                          onSecondaryTapDown: (_) =>
                              _showMessageActions(entry.message),
                          child: SearchMessageHighlight(
                            highlight: isHighlightTarget,
                            child: RepaintBoundary(
                              child: ChatMessageBubble(
                                key: ValueKey(entry.renderId),
                                message: entry.message,
                                toolGroups: groups,
                                hideThinking: hideThinking,
                                collapseInjectedEnabled: collapseEnabled,
                                injectedExpanded: expanded,
                                onToggleInjected: () {
                                  if (!mounted) return;
                                  setState(() {
                                    if (_expandedNoticeIds.contains(noticeId)) {
                                      _expandedNoticeIds.remove(noticeId);
                                    } else {
                                      _expandedNoticeIds.add(noticeId);
                                    }
                                  });
                                },
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    var tail = index - displayItems.length;
                    if (showQueuedBanner) {
                      if (tail == 0) {
                        return QueuedBanner(
                          count: queuedMessages.length,
                          preview: queuedMessages.first,
                        );
                      }
                      tail--;
                    }
                    if (streaming != null && !timelineActive) {
                      // legacy：旧分组式流式气泡（重连归档等无法还原段落边界的场景）。
                      if (tail == 0) {
                        return _StreamingBubble(
                          sessionId: sessionId,
                          message: streaming,
                          toolGroups: streamingTools,
                          hideThinking: hideThinking,
                        );
                      }
                      tail--;
                    }
                    if (streaming != null && timelineActive) {
                      if (tail < liveTimeline.length) {
                        final liveEntry = liveTimeline[tail];
                        final liveKey = _itemKeys.putIfAbsent(
                          liveEntry.renderKey,
                          () => GlobalKey(),
                        );
                        if (liveEntry.toolGroup != null) {
                          _itemKeys.putIfAbsent(
                            liveEntry.toolGroup!.id,
                            () => liveKey,
                          );
                        }
                        return KeyedSubtree(
                          key: liveKey,
                          child: _LiveTimelineItem(
                            sessionId: sessionId,
                            entry: liveEntry,
                            streamingMessage: streaming,
                            hideThinking: hideThinking,
                          ),
                        );
                      }
                      tail -= liveTimeline.length;
                    }
                    if (showStatusLine) {
                      if (tail == 0) {
                        return _ChatStatusLine(sessionId: sessionId);
                      }
                      tail--;
                    }
                    if (needFallback) {
                      if (tail == 0) {
                        return _FallbackToolReasoningCards(
                          toolGroups: toolGroups,
                          hideThinking: hideThinking,
                        );
                      }
                      tail--;
                    }
                    return const SizedBox.shrink();
                  },
                ),
                if (showScrollToBottomButton)
                  Positioned(
                    right: 16,
                    bottom: 12,
                    child: _ScrollToBottomButton(
                      label: buttonLabel,
                      onPressed: () {
                        if (!mounted) return;
                        setState(() {
                          _userHasScrolled = false;
                          _nearBottom = true;
                          _readingAnchor = null;
                          _resetAnchorStabilityState();
                          _pinnedTranscriptCount = 0;
                        });
                        _scrollToBottom(animated: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 悬浮回底按钮（Cupertino 悬浮 pill 样式，#2 规格）。
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final primaryColor = CupertinoTheme.of(context).primaryColor;
    final backgroundColor = CupertinoDynamicColor.resolve(
      CupertinoColors.secondarySystemGroupedBackground,
      context,
    );
    final borderColor = CupertinoDynamicColor.resolve(
      CupertinoColors.separator,
      context,
    ).withValues(alpha: 0.6);

    return CupertinoButton(
      key: const ValueKey('chat-scroll-to-bottom-button'),
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.black.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.arrow_down, size: 13, color: primaryColor),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: primaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 流式气泡（独立渲染层：思考中指示器 + 流式文本 + 实时工具卡片）。
class _StreamingBubble extends ConsumerWidget {
  const _StreamingBubble({
    required this.sessionId,
    required this.message,
    required this.toolGroups,
    required this.hideThinking,
  });

  final String sessionId;
  final ChatMessage message;
  final List<ToolCallGroup> toolGroups;
  final bool hideThinking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasContent = (message.content ?? '').isNotEmpty;
    final isEmpty = !hasContent && toolGroups.isEmpty;
    if (!isEmpty) {
      final phase = ref.watch(chatPhaseProvider(sessionId));
      final isRevealQueueEmpty = ref.watch(
        chatControllerProvider(sessionId).select((s) => s.isRevealQueueEmpty),
      );
      final pendingTokens = ref.watch(
        chatControllerProvider(sessionId)
            .select((s) => s.pendingAssistantTokenChunks),
      );
      final showCursor =
          phase == ChatPhase.streaming &&
          isRevealQueueEmpty &&
          pendingTokens.isEmpty &&
          hasContent;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: ChatMessageBubble(
              message: message,
              toolGroups: toolGroups,
              hideThinking: hideThinking,
              isStreaming: true,
            ),
          ),
          if (showCursor)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: _StreamingCursor(),
            ),
        ],
      );
    }
    // 空流式气泡兜底。
    return const SizedBox.shrink();
  }
}

/// #52 统一状态行：聊天列表尾部的连接/回合状态指示。
/// 取代旧 _ReconnectingIndicator / _SendingIndicator；
/// 按优先级渲染：prefill error → recovery → sending → 等待 prefill → 已重连 → 生成中；
/// 所有非空闲状态行统一靠左并附加「已工作 MM:SS」耗时；
/// 空闲自动隐藏（由外层 showStatusLine 控制占位）。
class _ChatStatusLine extends ConsumerStatefulWidget {
  const _ChatStatusLine({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_ChatStatusLine> createState() => _ChatStatusLineState();
}

class _ChatStatusLineState extends ConsumerState<_ChatStatusLine>
    with SingleTickerProviderStateMixin {
  /// 重连成功「已重连」绿点渐隐控制器（1.5s）。
  late final AnimationController _flashController;
  bool _flashReconnected = false;
  Timer? _elapsedTimer;

  @override
  void initState() {
    super.initState();
    _flashController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _flashReconnected = false);
          }
        });
    _startElapsedTimer();
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _flashController.dispose();
    super.dispose();
  }

  DateTime _now() {
    try {
      return ref.read(chatClockProvider)();
    } catch (_) {
      return DateTime.now();
    }
  }

  String _formatElapsed(int? turnStartedMillis) {
    if (turnStartedMillis == null) return '00:00';
    final nowMs = _now().millisecondsSinceEpoch;
    final elapsedMs = (nowMs - turnStartedMillis).clamp(0, 86400000);
    final duration = Duration(milliseconds: elapsedMs);
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sessionId = widget.sessionId;
    final phase = ref.watch(chatPhaseProvider(sessionId));
    final streaming = ref.watch(streamingMessageProvider(sessionId));
    final prefillStatus = ref.watch(
      chatControllerProvider(sessionId).select((s) => s.prefillStatus),
    );
    final recovery = ref.watch(
      chatControllerProvider(sessionId).select((s) => s.stream.recovery),
    );
    final liveTps = ref.watch(
      chatControllerProvider(sessionId)
          .select((s) => s.stream.liveTokensPerSecond),
    );
    final turnStartedMillis = ref.watch(
      chatControllerProvider(sessionId).select((s) => s.turnStartedMillis),
    );

    // 重连成功（recovery 非 idle → idle）→ 触发「已重连」绿点 1.5s 渐隐。
    ref.listen<ActiveStreamRecoveryState>(
      chatControllerProvider(sessionId).select((s) => s.stream.recovery),
      (previous, next) {
        if (previous != null &&
            previous != ActiveStreamRecoveryState.idle &&
            next == ActiveStreamRecoveryState.idle &&
            !_flashReconnected) {
          _flashReconnected = true;
          _flashController.forward(from: 0);
        }
      },
    );

    final elapsedStr = _formatElapsed(turnStartedMillis);
    final workSuffix = turnStartedMillis != null
        ? ' · ${l10n.chatStatusWorkingFor(elapsedStr)}'
        : '';

    if (prefillStatus == ContextPrefillStatus.error) {
      return _StatusLineRow(
        color: CupertinoColors.systemRed,
        label: l10n.chatStatusContextUnavailable + workSuffix,
      );
    }
    if (recovery == ActiveStreamRecoveryState.checking) {
      return _StatusLineRow(
        color: CupertinoColors.systemOrange,
        label: l10n.chatStatusInvestigating + workSuffix,
        showSpinner: true,
      );
    }
    if (recovery == ActiveStreamRecoveryState.reconnecting) {
      return _StatusLineRow(
        color: CupertinoColors.systemOrange,
        label: l10n.chatStatusReconnecting + workSuffix,
        showSpinner: true,
      );
    }
    if (phase == ChatPhase.sending) {
      return _StatusLineRow(
        color: CupertinoColors.secondaryLabel,
        label: l10n.chatStatusConnecting + workSuffix,
        showSpinner: true,
      );
    }
    if (prefillStatus == ContextPrefillStatus.loading ||
        prefillStatus == ContextPrefillStatus.notConfigured) {
      return _StatusLineRow(
        color: CupertinoColors.systemYellow,
        label: l10n.chatStatusWaitingResponse + workSuffix,
        showSpinner: true,
      );
    }
    if (_flashReconnected && !_flashController.isDismissed) {
      final opacity = 1 - _flashController.value;
      return Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: _StatusLineRow(
          color: CupertinoColors.systemGreen,
          label: l10n.chatStatusReconnected,
        ),
      );
    }
    if (streaming != null) {
      final tpsSuffix = (liveTps != null && liveTps.isFinite && liveTps > 0)
          ? ' ≈${liveTps.round()} tps'
          : '';
      return _StatusLineRow(
        color: CupertinoColors.systemGreen,
        label: l10n.chatStatusGenerating + tpsSuffix + workSuffix,
      );
    }
    return const SizedBox.shrink();
  }
}

/// 状态行单行：状态点/转圈 + 文案（secondaryLabel 13px，靠左对齐）。
class _StatusLineRow extends StatelessWidget {
  const _StatusLineRow({this.color, this.label = '', this.showSpinner = false});

  /// 状态点颜色；null 时显示转圈。
  final Color? color;
  final String label;

  /// 转圈优先（checking/reconnecting/sending/等待 prefill 均转圈）。
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    final resolved = color == null
        ? null
        : CupertinoDynamicColor.resolve(color!, context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          if (showSpinner || resolved == null)
            CupertinoActivityIndicator(
              radius: color == null ? 7 : 6,
              color: resolved,
            )
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: resolved,
                shape: BoxShape.circle,
              ),
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// live 时间线条目渲染（think/text/tools 按事件先后穿插的独立列表项）。
class _LiveTimelineItem extends StatelessWidget {
  const _LiveTimelineItem({
    required this.sessionId,
    required this.entry,
    required this.streamingMessage,
    required this.hideThinking,
    // ignore: unused_element_parameter
    this.isLastText = false,
  });

  final String sessionId;
  final LiveTimelineEntry entry;
  final ChatMessage streamingMessage;
  final bool hideThinking;
  final bool isLastText;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey(entry.renderKey),
      child: switch (entry.kind) {
        // 思考已并入工具卡子卡（think 行），不再产出独立思考条目；此分支
        // 为防御（旧数据/异常路径），不渲染任何内容。
        LiveSegmentKind.thinking => const SizedBox.shrink(),
        LiveSegmentKind.text => _LiveTextBlock(
          sessionId: sessionId,
          slice: entry.textSlice,
          streamingMessage: streamingMessage,
          isLastText: isLastText,
        ),
        LiveSegmentKind.tools => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: ToolCallGroupCard(
            group: entry.toolGroup!,
            hideThinking: hideThinking,
          ),
        ),
      },
    );
  }
}

/// 流式文本段（Markdown 渲染，增量解析 try/catch 兜底，镜像历史 assistant 气泡的 content 处理管线）。
class _LiveTextBlock extends ConsumerWidget {
  const _LiveTextBlock({
    required this.sessionId,
    required this.slice,
    required this.streamingMessage,
    // ignore: unused_element_parameter
    this.isLastText = false,
  });

  final String sessionId;
  final String slice;
  final ChatMessage streamingMessage;
  final bool isLastText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    SelectedContextParse selected;
    try {
      selected = SelectedContextParser.parse(slice);
    } catch (_) {
      selected = SelectedContextParse(blocks: const [], cleanText: slice);
    }
    final blocks = selected.blocks;
    final cleanText = selected.cleanText;
    final hasMediaMarker =
        cleanText.contains('MEDIA:') || cleanText.contains('file://');
    String parsedContent;
    try {
      parsedContent = hasMediaMarker
          ? ChatMediaParser.parseMediaMarkers(cleanText)
          : cleanText;
    } catch (_) {
      parsedContent = cleanText;
    }
    final sections = <Widget>[];
    if (blocks.isNotEmpty) {
      sections.add(SelectedContextCardGroup(blocks: blocks));
    }
    if (parsedContent.isNotEmpty) {
      sections.add(
        _SafeMarkdownBody(
          data: parsedContent,
          isStreaming: !hasMediaMarker,
          selectable: true,
          sessionId: sessionId,
          styleSheet: buildAssistantMarkdownStyleSheet(context),
          builders: createAssistantMarkdownBuilders(context),
          // ignore: deprecated_member_use
          imageBuilder: (uri, title, alt) {
            return ChatInlineMediaWidget(
              rawUri: uri.toString(),
              title: title,
              alt: alt,
              baseUrl: _resolveBaseUrl(context),
            );
          },
        ),
      );
    }
    if (isLastText) {
      final phase = ref.watch(chatPhaseProvider(sessionId));
      final isRevealQueueEmpty = ref.watch(
        chatControllerProvider(sessionId).select((s) => s.isRevealQueueEmpty),
      );
      final pendingTokens = ref.watch(
        chatControllerProvider(sessionId)
            .select((s) => s.pendingAssistantTokenChunks),
      );
      final hasContent = (streamingMessage.content ?? '').isNotEmpty;
      final showCursor =
          phase == ChatPhase.streaming &&
          isRevealQueueEmpty &&
          pendingTokens.isEmpty &&
          hasContent;
      if (showCursor) {
        sections.add(const _StreamingCursor());
      }
    }
    if (sections.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var i = 0; i < sections.length; i++) {
      final section = sections[i];
      if (i > 0 && section is! _StreamingCursor) {
        children.add(const SizedBox(height: kMessageSectionGap));
      }
      children.add(section);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  String? _resolveBaseUrl(BuildContext context) {
    try {
      final container = ProviderScope.containerOf(context, listen: false);
      return container.read(activeConnectionProvider)?.baseUrl;
    } catch (_) {
      return null;
    }
  }
}

/// 流式打字机闪烁光标（追上积压后闪烁提示，非流式/done 立即消失）。
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor> {
  Timer? _blinkTimer;
  bool _visible = true;
  int _blinkCount = 0;
  static const int _maxBlinks = 12; // 约 6.7 秒后定格常亮，防眩晕并允许测试 pumpAndSettle 收敛

  @override
  void initState() {
    super.initState();
    _startBlinkTimer();
  }

  void _startBlinkTimer() {
    _blinkTimer?.cancel();
    _blinkCount = 0;
    _visible = true;
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 560), (_) {
      if (!mounted) return;
      _blinkCount++;
      if (_blinkCount >= _maxBlinks) {
        _blinkTimer?.cancel();
        _blinkTimer = null;
        if (!_visible) {
          setState(() {
            _visible = true;
          });
        }
        return;
      }
      setState(() {
        _visible = !_visible;
      });
    });
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = CupertinoDynamicColor.resolve(
      CupertinoColors.label,
      context,
    ).withValues(alpha: 0.6);

    final cursor = Text(
      '▎',
      style: TextStyle(
        fontSize: 15,
        height: 1.0,
        color: color,
        shadows: [Shadow(color: color.withValues(alpha: 0.25), blurRadius: 4)],
      ),
    );

    final content = disableAnimations
        ? cursor
        : AnimatedOpacity(
            opacity: _visible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 560),
            curve: Curves.easeInOut,
            child: cursor,
          );

    return SizedBox(
      height: 0,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        maxHeight: 20,
        child: Padding(
          key: const ValueKey('streaming-cursor'),
          padding: const EdgeInsets.only(left: 2),
          child: content,
        ),
      ),
    );
  }
}

/// 落地兜底：transcript 为空但已归档的工具/思考组非空时，末尾独立渲染入口
class _FallbackToolReasoningCards extends StatelessWidget {
  const _FallbackToolReasoningCards({
    required this.toolGroups,
    required this.hideThinking,
  });

  final List<ToolCallGroup> toolGroups;
  final bool hideThinking;

  @override
  Widget build(BuildContext context) {
    // 复用与 assistant 气泡相同的 horizontal 12 外边距；区块间统一固定间距
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in toolGroups) ...[
            ToolCallGroupCard(group: group, hideThinking: hideThinking),
            if (group != toolGroups.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
