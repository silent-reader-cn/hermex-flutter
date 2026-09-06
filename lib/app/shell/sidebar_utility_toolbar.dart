import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/session_list/session_entry_visibility.dart';
import '../../l10n/app_localizations.dart';

/// 侧栏顶部工具条项配置。
class _UtilityItem {
  const _UtilityItem({
    required this.id,
    required this.path,
    required this.icon,
    required this.getTitle,
  });

  final String id;
  final String path;
  final IconData icon;
  final String Function(AppLocalizations l10n) getTitle;
}

/// 侧栏常驻工具入口行（TASK W2/W3 / 蓝本 SessionListComponents.swift §SessionSidebarUtilityRows）。
///
/// 宽屏下展示在会话列表顶部，提供任务、看板、工作区、技能、统计、记忆、设置的快捷跳转与激活高亮。
/// 受 [sessionEntryVisibilityProvider] 控制功能入口显隐；所有功能入口全关时整条工具条仅保留设置图标。
class SidebarUtilityToolbar extends ConsumerWidget {
  const SidebarUtilityToolbar({super.key, required this.currentLocation});

  /// 当前激活的路由路径。
  final String currentLocation;

  static final List<_UtilityItem> _items = [
    _UtilityItem(
      id: 'tasks',
      path: '/tasks',
      icon: CupertinoIcons.clock,
      getTitle: (l10n) => l10n.tasksTitle,
    ),
    _UtilityItem(
      id: 'kanban',
      path: '/kanban',
      icon: CupertinoIcons.square_split_2x2,
      getTitle: (l10n) => l10n.kanbanTitle,
    ),
    _UtilityItem(
      id: 'workspaces',
      path: '/workspaces',
      icon: CupertinoIcons.folder,
      getTitle: (l10n) => l10n.workspacesTitle,
    ),
    _UtilityItem(
      id: 'skills',
      path: '/skills',
      icon: CupertinoIcons.hammer,
      getTitle: (l10n) => l10n.skillsTitle,
    ),
    _UtilityItem(
      id: 'insights',
      path: '/insights',
      icon: CupertinoIcons.chart_bar,
      getTitle: (l10n) => l10n.insightsTitle,
    ),
    _UtilityItem(
      id: 'memory',
      path: '/memory',
      // #75：bookmark 与收藏提示词按钮撞脸，记忆入口改用 book（记忆库语义）。
      icon: CupertinoIcons.book,
      getTitle: (l10n) => l10n.memoryTitle,
    ),
    _UtilityItem(
      id: 'downloads',
      path: '/downloads',
      icon: CupertinoIcons.arrow_down_circle,
      getTitle: (l10n) => l10n.downloadsTitle,
    ),
    _UtilityItem(
      id: 'settings',
      path: '/settings',
      icon: CupertinoIcons.gear_alt,
      getTitle: (l10n) => l10n.settingsTitle,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibility = ref.watch(sessionEntryVisibilityProvider);

    final l10n = AppLocalizations.of(context);
    final theme = CupertinoTheme.of(context);
    final primaryColor = theme.primaryColor;
    final inactiveColor = CupertinoColors.secondaryLabel.resolveFrom(context);

    final visibleItems = _items
        .where((item) {
          if (item.id == 'settings') return true;
          return visibility.isVisible(item.id);
        })
        .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: visibleItems
                .map((item) {
                  final isSelected =
                      currentLocation == item.path ||
                      currentLocation.startsWith('${item.path}/');
                  final title = item.getTitle(l10n);

                  return Expanded(
                    child: Semantics(
                      label: title,
                      selected: isSelected,
                      button: true,
                      child: CupertinoButton(
                        key: ValueKey('sidebar-utility-${item.id}'),
                        // 视觉压到 32pt（icon 20 + 上下 6pt），点击区保持
                        // 44pt HIG 下限；配合外层 6pt×2 边距总高 44px，
                        // 与内容区标准导航栏 / 紧凑导航条顶端对齐。
                        minimumSize: const Size(40, 32),
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        borderRadius: BorderRadius.circular(8.0),
                        color: isSelected
                            ? primaryColor.withValues(alpha: 0.12)
                            : CupertinoColors.transparent,
                        onPressed: () {
                          context.go(item.path);
                        },
                        child: Icon(
                          item.icon,
                          size: 20.0,
                          color: isSelected ? primaryColor : inactiveColor,
                        ),
                      ),
                    ),
                  );
                })
                .toList(growable: false),
          ),
        ),
        Container(
          height: 0.5,
          color: CupertinoColors.separator.resolveFrom(context),
        ),
      ],
    );
  }
}
