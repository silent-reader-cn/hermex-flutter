import 'package:flutter/cupertino.dart';

import '../../../app/theme/status_colors.dart';
import '../../../core/models/tool_call.dart';
import '../../../l10n/app_localizations.dart';

/// 回合完成后过程折叠胶囊组件（active.md #55，样式改版 #59 → #64 方案 E）。
///
/// 将已完成回合中的思考块、工具调用卡、中间文本等过程项收敛为单行摘要胶囊，
/// 默认收起（首次折叠，会话内记忆），点击可展开/收起详情。
///
/// #64 方案 E「时间轴轨」：左侧一根发丝轨线串起整个回合过程（header +
/// 展开后的子卡都挂在轨上），胶囊是轨上的空心蓝节点——语义即「本回合的
/// 过程流起点」。与 [ToolCallGroupCard]（实底灰盒 + 边框 + 绿勾）天然
/// 不同视觉语言，层级区分由形态本身完成，不再依赖孤立的装饰竖条。
class CollapsibleProcessCapsule extends StatefulWidget {
  const CollapsibleProcessCapsule({
    super.key,
    required this.toolGroups,
    this.intermediateTextCount = 0,
    this.children = const <Widget>[],
    this.hideThinking = false,
    this.noticeCount = 0,
    this.initiallyExpanded = false,
    this.isExpanded,
    this.onToggle,
  });

  /// 归档/展示的工具调用组。
  final List<ToolCallGroup> toolGroups;

  /// 回合内中间助手文本数。
  final int intermediateTextCount;

  /// 展开时渲染的过程子卡片列表（当作为独立容器时使用）。
  final List<Widget> children;

  /// 是否隐藏思考。
  final bool hideThinking;

  /// 伴随的通知数。
  final int noticeCount;

  /// 初始展开态（默认 false）。
  final bool initiallyExpanded;

  /// 外部受控展开态（若提供则优先于内部状态）。
  final bool? isExpanded;

  /// 切换展开回调。
  final VoidCallback? onToggle;

  @override
  State<CollapsibleProcessCapsule> createState() =>
      _CollapsibleProcessCapsuleState();
}

class _CollapsibleProcessCapsuleState extends State<CollapsibleProcessCapsule> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isExpanded ?? widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(CollapsibleProcessCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != null) {
      _expanded = widget.isExpanded!;
    }
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
    });
    widget.onToggle?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final effectiveExpanded = widget.isExpanded ?? _expanded;

    final titleStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: secondaryText.resolveFrom(context),
    );
    // 轨线与节点色（#64 方案 E）：装饰元素不受 AA 文字对比约束，
    // 但深浅两态仍显式解析，防暗黑退化。
    final railColor = const CupertinoDynamicColor.withBrightness(
      color: Color(0x1F000000), // 浅底 12% 黑
      darkColor: Color(0x26FFFFFF), // 深底 15% 白
    );

    return SizedBox(
      key: const ValueKey('collapsible-process-capsule'),
      width: double.infinity,
      child: Padding(
        // 左缘让出 11px 给轨线（rail 5px 居中于 0-10 区），内容整体缩进。
        // #67 对齐修正：17→11，使空心蓝节点左缘（12+11+1.5≈24.5）与展开后
        // 工具卡组卡绿勾左缘（12+10+2.5≈24.5）垂直对齐——真机反馈两者图标
        // 错位（节点比卡图标缩进多 6px）。
        padding: const EdgeInsets.only(left: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 轨线 + 空心蓝节点（节点对齐 header 行垂直中心）。
            Row(
              children: [
                _TimelineNode(color: statusBlueText.resolveFrom(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // 可用标题宽度：容器宽 - 左右内边距 - 箭头 - 间距（- 耗时）
                      var availableWidth = constraints.maxWidth - 20 - 12 - 6;
                      final trailingDuration = _trailingDuration();
                      if (trailingDuration != null) {
                        availableWidth -= 44;
                      }
                      if (availableWidth < 0) availableWidth = 0;

                      final title = formatProcessCapsuleSummary(
                        toolGroups: widget.toolGroups,
                        intermediateTextCount: widget.intermediateTextCount,
                        hideThinking: widget.hideThinking,
                        l10n: l10n,
                        maxWidth: constraints.maxWidth.isFinite
                            ? availableWidth
                            : null,
                        style: titleStyle,
                        textScaler: MediaQuery.textScalerOf(context),
                        textDirection: Directionality.of(context),
                        processPrefix: true,
                      );

                      return Semantics(
                        button: true,
                        label: effectiveExpanded
                            ? l10n.turn55CollapseProcess
                            : l10n.turn55ExpandProcess,
                        child: GestureDetector(
                          key: const ValueKey('process-capsule-header'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggle,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                ),
                                if (trailingDuration != null) ...[
                                  Text(
                                    trailingDuration,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: secondaryText.resolveFrom(context),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Icon(
                                  effectiveExpanded
                                      ? CupertinoIcons.chevron_up
                                      : CupertinoIcons.chevron_down,
                                  size: 12,
                                  color: CupertinoColors.tertiaryLabel
                                      .resolveFrom(context),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            if (effectiveExpanded && widget.children.isNotEmpty)
              // 展开内容同样挂轨：左侧 1px 发丝轨线 + 节点延续，子卡缩进
              // 与 header 文本对齐。
              _RailBody(
                railColor: railColor.resolveFrom(context),
                nodeColor: statusBlueText.resolveFrom(context),
                children: widget.children,
              ),
          ],
        ),
      ),
    );
  }

  /// 耗时尾缀（无思考且总耗时 > 0 时展示）。
  String? _trailingDuration() {
    final allCalls = [for (final g in widget.toolGroups) ...g.toolCalls];
    final hasThinking =
        !widget.hideThinking && allCalls.any((c) => c.isThinking);
    final durationSeconds = allCalls
        .map((c) => c.duration)
        .whereType<double>()
        .fold<double>(0.0, (a, b) => a + b);
    return (durationSeconds > 0 && !hasThinking)
        ? '${durationSeconds.toStringAsFixed(1)}s'
        : null;
  }
}

/// #64 方案 E：轨线上的空心蓝节点（7px 圆环，header 行首）。
class _TimelineNode extends StatelessWidget {
  const _TimelineNode({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 10,
      height: 32,
      child: Center(
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// #64 方案 E：展开体的左缘轨线（1px 发丝线 + 顶部实心小节点延续）。
///
/// 用 Stack + Positioned 画线：Stack 由内容定高，positioned 轨线自动
/// 拉伸到内容全高（Row+Expanded 方案在无界高度约束下会 RenderFlex 炸）。
class _RailBody extends StatelessWidget {
  const _RailBody({
    required this.railColor,
    required this.nodeColor,
    required this.children,
  });

  final Color railColor;
  final Color nodeColor;
  final List<Widget> children;

  // 轨线 x = 节点圆心（header 节点区宽 10 的中心 5）对齐，线宽 1 → left 4.5。
  static const double _railLeft = 4.5;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: _railLeft,
          top: 0,
          bottom: 0,
          child: SizedBox(width: 1, child: ColoredBox(color: railColor)),
        ),
        Positioned(
          left: _railLeft - 1,
          top: 14,
          child: Container(
            width: 3,
            height: 3,
            decoration: BoxDecoration(shape: BoxShape.circle, color: nodeColor),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 2),
              ...children,
              const SizedBox(height: 6),
            ],
          ),
        ),
      ],
    );
  }
}

/// 根据可用宽度自适应计算过程胶囊标题（对齐 [_adaptiveActivityTitle] 风格）。
///
/// [processPrefix]（#64 方案 E）：标题带「过程 ·」前缀，与轨线节点共同
/// 读出「本回合的过程流」语义；宽度不足时前缀优先保留、明细退省略号。
String formatProcessCapsuleSummary({
  required List<ToolCallGroup> toolGroups,
  required int intermediateTextCount,
  required bool hideThinking,
  required AppLocalizations l10n,
  double? maxWidth,
  TextStyle? style,
  TextScaler? textScaler,
  TextDirection? textDirection,
  bool processPrefix = false,
}) {
  final allCalls = [for (final g in toolGroups) ...g.toolCalls];

  final counts = <String, int>{};
  final initialIndex = <String, int>{};

  for (var i = 0; i < allCalls.length; i++) {
    final call = allCalls[i];
    if (call.isThinking && hideThinking) continue;
    final name = call.isThinking
        ? l10n.thinkingLabel
        : l10n.localizeToolName(call.displayName);
    initialIndex.putIfAbsent(name, () => initialIndex.length);
    counts[name] = (counts[name] ?? 0) + 1;
  }

  if (intermediateTextCount > 0) {
    final name = l10n.turn55IntermediateText;
    initialIndex.putIfAbsent(name, () => initialIndex.length);
    counts[name] = (counts[name] ?? 0) + intermediateTextCount;
  }

  if (counts.isEmpty) {
    return l10n.turn55ProcessLabel;
  }

  // #64 方案 E 前缀：「过程 · 执行代码×8 …」；宽度不足时前缀优先保留、
  // 明细退省略号（前缀 + 首项仍放不下时由渲染层 ellipsis 兜底）。
  final prefix = processPrefix ? '${l10n.turn55ProcessLabel} \u00B7 ' : '';

  final entries = counts.entries.toList()
    ..sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) return cmp;
      return (initialIndex[a.key] ?? 0).compareTo(initialIndex[b.key] ?? 0);
    });

  if (maxWidth == null ||
      style == null ||
      textScaler == null ||
      textDirection == null) {
    final detail = entries.map((e) => '${e.key} \u00D7${e.value}').join(', ');
    return '$prefix$detail';
  }

  bool fits(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    return painter.width <= maxWidth;
  }

  final visible = <String>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final itemText = '${entry.key} \u00D7${entry.value}';
    final candidateVisible = [...visible, itemText];
    final remaining = entries.length - candidateVisible.length;
    final candidateString = remaining > 0
        ? '$prefix${candidateVisible.join(', ')} \u2026'
        : '$prefix${candidateVisible.join(', ')}';

    if (fits(candidateString)) {
      visible.add(itemText);
    } else {
      break;
    }
  }

  if (visible.isNotEmpty) {
    final remaining = entries.length - visible.length;
    if (remaining > 0) {
      return '$prefix${visible.join(', ')} \u2026';
    }
    return '$prefix${visible.join(', ')}';
  }

  return '$prefix${entries.first.key} \u2026';
}
