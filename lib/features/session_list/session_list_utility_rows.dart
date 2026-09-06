import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/accessibility.dart';
import '../../l10n/app_localizations.dart';
import '../shared/app_navigation.dart';
import 'session_entry_visibility.dart';

/// 会话列表顶部工具行入口组件（对齐 Hermex SessionSidebarUtilityRows）。
///
/// 提供 6 个核心功能模块的快捷跳转（任务、看板、工作区、技能、统计、记忆）：
/// 1. 任务 (Tasks) → /tasks (CupertinoIcons.clock, 对齐 LucideCalendarClock)
/// 2. 看板 (Kanban) → /kanban (CupertinoIcons.square_list, 对齐 LucideColumns3)
/// 3. 工作区 (Workspaces) → /workspaces (CupertinoIcons.folder, 对齐 LucideFolder)
/// 4. 技能 (Skills) → /skills (CupertinoIcons.hammer, 对齐 LucideHammer)
/// 5. 统计 (Insights) → /insights (CupertinoIcons.chart_bar_square, 对齐 LucideChartColumnIncreasing)
/// 6. 记忆 (Memory) → /memory (CupertinoIcons.book，#75 与收藏提示词 bookmark 区分)
/// 7. 下载 (Downloads) → /downloads (CupertinoIcons.arrow_down_circle)
///
/// 视觉采用纯 Cupertino 风格，支持深浅色自适应及 VoiceOver 语义与触觉反馈。
class SessionListUtilityRows extends ConsumerWidget {
  const SessionListUtilityRows({
    super.key,
    this.onTapTasks,
    this.onTapKanban,
    this.onTapWorkspaces,
    this.onTapSkills,
    this.onTapInsights,
    this.onTapMemory,
    this.onTapDownloads,
  });

  /// 任务入口自定义点击回调（为空时默认 context.go('/tasks')）。
  final VoidCallback? onTapTasks;

  /// 看板入口自定义点击回调（为空时默认 context.go('/kanban')）。
  final VoidCallback? onTapKanban;

  /// 工作区入口自定义点击回调（为空时默认 context.go('/workspaces')）。
  final VoidCallback? onTapWorkspaces;

  /// 技能入口自定义点击回调（为空时默认 context.go('/skills')）。
  final VoidCallback? onTapSkills;

  /// 统计入口自定义点击回调（为空时默认 context.go('/insights')）。
  final VoidCallback? onTapInsights;

  /// 记忆入口自定义点击回调（为空时默认 context.go('/memory')）。
  final VoidCallback? onTapMemory;

  /// 下载入口自定义点击回调（为空时默认 context.go('/downloads')）。
  final VoidCallback? onTapDownloads;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(sessionEntryVisibilityProvider);
    if (!visibility.showsAny) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final items = <Widget>[
      if (visibility.tasks)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-tasks'),
          icon: CupertinoIcons.clock,
          label: l10n.tasks,
          route: '/tasks',
          customCallback: onTapTasks,
        ),
      if (visibility.kanban)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-kanban'),
          icon: CupertinoIcons.square_list,
          label: l10n.kanban,
          route: '/kanban',
          customCallback: onTapKanban,
        ),
      if (visibility.workspaces)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-workspaces'),
          icon: CupertinoIcons.folder,
          label: l10n.workspacesTitle,
          route: '/workspaces',
          customCallback: onTapWorkspaces,
        ),
      if (visibility.skills)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-skills'),
          icon: CupertinoIcons.hammer,
          label: l10n.skills,
          route: '/skills',
          customCallback: onTapSkills,
        ),
      if (visibility.insights)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-insights'),
          icon: CupertinoIcons.chart_bar_square,
          label: l10n.insights,
          route: '/insights',
          customCallback: onTapInsights,
        ),
      if (visibility.memory)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-memory'),
          // #75：与宽屏侧栏同步，bookmark 撞脸收藏提示词，改 book。
          icon: CupertinoIcons.book,
          label: l10n.memory,
          route: '/memory',
          customCallback: onTapMemory,
        ),
      if (visibility.downloads)
        _buildUtilityItem(
          context,
          key: const ValueKey('session-list-utility-downloads'),
          icon: CupertinoIcons.arrow_down_circle,
          label: l10n.downloadsTitle,
          route: '/downloads',
          customCallback: onTapDownloads,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        key: const ValueKey('session-list-utility-rows'),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
            context,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: items,
        ),
      ),
    );
  }

  Widget _buildUtilityItem(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required String route,
    required VoidCallback? customCallback,
  }) {
    return Expanded(
      child: AccessibleButton(
        key: key,
        label: label,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        onPressed: () {
          if (customCallback != null) {
            customCallback();
          } else {
            openAdaptiveRoute(context, route);
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: CupertinoColors.activeBlue.resolveFrom(context),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: CupertinoColors.label.resolveFrom(context),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
