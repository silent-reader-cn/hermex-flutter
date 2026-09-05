import 'dart:async';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/status_colors.dart';
import '../../l10n/app_localizations.dart';
import '../diagnostics/diagnostics_models.dart';
import '../diagnostics/diagnostics_service.dart';
import '../shared/app_back_button.dart';
import 'download_models.dart';
import 'download_providers.dart';

/// 原生 FileProvider 通道：把绝对路径换成 content:// URI。
const MethodChannel _fileShareChannel = MethodChannel(
  'com.silentreader.hermes_ui/file_share',
);

/// 经 MainActivity 的 FileProvider MethodChannel 生成 content:// URI。
/// 失败（通道缺失/异常）返回 null，由调用方兜底。
Future<String?> _androidContentUriFor(String path) async {
  try {
    final uri = await _fileShareChannel.invokeMethod<String>('getShareUri', {
      'path': path,
    });
    return uri;
  } catch (error) {
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.warn,
      tag: 'downloads',
      message: 'FileProvider 生成 content URI 失败: $error',
      details: {'path': path},
    );
    return null;
  }
}

/// 跨平台打开已下载文件的核心方法。
///
/// 行为契约：
/// 1. 若提供了 [customOpener]（主要用于测试与平台注入），优先调用并返回；
/// 2. 校验文件是否存在：若不存在，记录警告并弹出 Cupertino 提示框；
/// 3. Windows 平台：调用 `explorer /select, <path>` 在文件资源管理器中定位高亮文件；
/// 4. Android 平台：使用 `android_intent_plus` 发起 `ACTION_VIEW` 打开文件 content/file uri；
/// 5. macOS / Linux 平台：分别调用 `open -R` / `xdg-open` 打开对应文件；
/// 6. 异常捕获：记录诊断日志，并在 UI 提供可读错误提示，绝不静默失败。
Future<void> openDownloadedFile(
  BuildContext context,
  String path, {
  String? mimeType,
  Future<void> Function(String path)? customOpener,
}) async {
  if (customOpener != null) {
    await customOpener(path);
    return;
  }

  final file = File(path);
  if (!file.existsSync()) {
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.warn,
      tag: 'downloads',
      message: '打开文件失败，文件不存在: $path',
    );
    if (context.mounted) {
      final l10n = AppLocalizations.of(context);
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(l10n.notice),
          content: Text(l10n.downloadFileMissing),
          actions: [
            CupertinoDialogAction(
              child: Text(l10n.ok),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    }
    return;
  }

  try {
    if (!kIsWeb && Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
      return;
    }
    if (!kIsWeb && Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
      return;
    }
    if (!kIsWeb && Platform.isLinux) {
      await Process.run('xdg-open', [path]);
      return;
    }
    if (!kIsWeb && Platform.isAndroid) {
      // Android 7+ StrictMode 禁止裸 file:// URI 跨应用共享（FileUriExposedException），
      // 必须先经原生 FileProvider 换成 content:// URI 再发 ACTION_VIEW。
      final contentUri = await _androidContentUriFor(path);
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: contentUri ?? Uri.encodeFull('file://$path'),
        type: mimeType,
        flags: const [
          0x10000000, // FLAG_ACTIVITY_NEW_TASK
          0x00000001, // FLAG_GRANT_READ_URI_PERMISSION
        ],
      );
      await intent.launch();
      return;
    }
  } catch (error) {
    DiagnosticsService.instance.log(
      level: DiagnosticsLogLevel.error,
      tag: 'downloads',
      message: '打开文件异常: $error',
      details: {'path': path, 'mimeType': mimeType},
      errorKind: error.toString(),
    );
    if (context.mounted) {
      final l10n = AppLocalizations.of(context);
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(l10n.downloadOpenFileFailed),
          content: Text(error.toString()),
          actions: [
            CupertinoDialogAction(
              child: Text(l10n.ok),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    }
  }
}

/// 根据文件分类获取对应 Cupertino 图标。
IconData getDownloadFileTypeIcon(DownloadFileType type) {
  switch (type) {
    case DownloadFileType.image:
      return CupertinoIcons.photo;
    case DownloadFileType.audio:
      return CupertinoIcons.music_note;
    case DownloadFileType.video:
      return CupertinoIcons.film;
    case DownloadFileType.document:
      return CupertinoIcons.doc_text;
    case DownloadFileType.archive:
      return CupertinoIcons.archivebox;
    case DownloadFileType.code:
      return CupertinoIcons.chevron_left_slash_chevron_right;
    case DownloadFileType.other:
      return CupertinoIcons.doc;
  }
}

/// 本地化文件类型分类名称。
String localizeDownloadFileType(DownloadFileType type, AppLocalizations l10n) {
  switch (type) {
    case DownloadFileType.image:
      return l10n.mediaImage;
    case DownloadFileType.audio:
      return l10n.mediaAudio;
    case DownloadFileType.video:
      return l10n.mediaVideo;
    case DownloadFileType.document:
      return l10n.mediaDocument;
    case DownloadFileType.archive:
      return l10n.downloadFileTypeArchive;
    case DownloadFileType.code:
      return l10n.downloadFileTypeCode;
    case DownloadFileType.other:
      return l10n.downloadFileTypeOther;
  }
}

/// 纯 Cupertino 进度条组件。
class CupertinoProgressBar extends StatelessWidget {
  const CupertinoProgressBar({
    super.key,
    this.value,
    this.height = 4.0,
    this.trackColor,
    this.progressColor,
  });

  /// 进度值（0.0 .. 1.0；为 null 时显示 0% 兜底）。
  final double? value;

  /// 高度。
  final double height;

  /// 轨道背景色。
  final Color? trackColor;

  /// 进度颜色。
  final Color? progressColor;

  @override
  Widget build(BuildContext context) {
    final effectiveTrackColor =
        trackColor ?? CupertinoColors.systemGrey5.resolveFrom(context);
    final effectiveProgressColor =
        progressColor ?? CupertinoTheme.of(context).primaryColor;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: effectiveTrackColor,
        borderRadius: BorderRadius.circular(height / 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final widthFactor = (value ?? 0.0).clamp(0.0, 1.0);
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: constraints.maxWidth * widthFactor,
              height: height,
              decoration: BoxDecoration(
                color: effectiveProgressColor,
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 下载管理页面（`/downloads`）。
///
/// 采用纯 Cupertino 风格实现：
/// - 顶部导航条：AppBackButton + 标题「下载」+「清除已完成/失败记录」按钮；
/// - 空态展示：无记录时显示图标与「暂无下载记录」文案；
/// - 任务列表：按创建时间倒序展示，包含分类图标、文件名、进度条、大小与状态；
/// - 交互动作：排队/下载中可取消；失败/取消可重试；完成可打开文件（丢失可重新下载）；支持删除单个记录。
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key, this.onOpenFile});

  /// 自定义打开文件回调（用于测试与依赖注入）。
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tasks = ref.watch(downloadTasksProvider);
    final controller = ref.read(downloadControllerProvider.notifier);

    final hasTerminalTasks = tasks.any((t) => t.isTerminal);

    final sortedTasks = [...tasks]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      navigationBar: CupertinoNavigationBar(
        leading: const AppBackButton(),
        middle: Text(l10n.downloadsTitle),
        trailing: hasTerminalTasks
            ? CupertinoButton(
                key: const ValueKey('downloads-clear-terminal-button'),
                padding: EdgeInsets.zero,
                onPressed: () {
                  unawaited(controller.clearTerminalRecords());
                },
                child: Text(
                  l10n.downloadClear,
                  style: TextStyle(
                    fontSize: 14,
                    color: CupertinoTheme.of(context).primaryColor,
                  ),
                ),
              )
            : null,
      ),
      child: SafeArea(
        child: sortedTasks.isEmpty
            ? _buildEmptyState(context, l10n)
            : ListView.builder(
                key: const ValueKey('downloads-list-view'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: sortedTasks.length,
                itemBuilder: (context, index) {
                  final task = sortedTasks[index];
                  return _DownloadTaskCard(
                    key: ValueKey('download-task-${task.id}'),
                    task: task,
                    onOpenFile: onOpenFile,
                  );
                },
              ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.arrow_down_circle,
            size: 64,
            color: CupertinoColors.tertiaryLabel.resolveFrom(context),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.downloadsEmpty,
            style: TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个下载任务卡片组件。
class _DownloadTaskCard extends ConsumerWidget {
  const _DownloadTaskCard({super.key, required this.task, this.onOpenFile});

  final DownloadTask task;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(downloadControllerProvider.notifier);

    final fileType = getDownloadFileType(
      fileName: task.fileName,
      mimeType: task.mimeType,
    );
    final typeIcon = getDownloadFileTypeIcon(fileType);

    final bool fileExistsOnDisk =
        task.savedPath != null && File(task.savedPath!).existsSync();

    final String statusText;
    final Color statusColor;

    switch (task.status) {
      case DownloadStatus.queued:
        statusText = l10n.downloadStatusQueued;
        statusColor = statusGreyText.resolveFrom(context);
        break;
      case DownloadStatus.downloading:
        if (task.expectedBytes != null && task.expectedBytes! > 0) {
          final progressPercent = ((task.progress ?? 0.0) * 100)
              .toStringAsFixed(0);
          statusText =
              '$progressPercent% (${formatDownloadByteSize(task.receivedBytes)} / ${formatDownloadByteSize(task.expectedBytes!)})';
        } else {
          statusText =
              '${l10n.downloadStatusDownloading} (${formatDownloadByteSize(task.receivedBytes)})';
        }
        statusColor = statusBlueText.resolveFrom(context);
        break;
      case DownloadStatus.completed:
        if (fileExistsOnDisk) {
          statusText =
              '${l10n.downloadStatusCompleted} · ${formatDownloadByteSize(task.receivedBytes)}';
          statusColor = statusGreenText.resolveFrom(context);
        } else {
          statusText = l10n.downloadFileMissing;
          statusColor = statusRedText.resolveFrom(context);
        }
        break;
      case DownloadStatus.failed:
        statusText =
            task.failureMessage != null && task.failureMessage!.isNotEmpty
            ? '${l10n.downloadStatusFailed}：${task.failureMessage}'
            : l10n.downloadStatusFailed;
        statusColor = statusRedText.resolveFrom(context);
        break;
      case DownloadStatus.cancelled:
        statusText = l10n.downloadStatusCancelled;
        statusColor = statusGreyText.resolveFrom(context);
        break;
    }

    final List<Widget> actionButtons = [];

    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        actionButtons.add(
          CupertinoButton(
            key: ValueKey('download-cancel-${task.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: CupertinoColors.systemGrey4.resolveFrom(context),
            borderRadius: BorderRadius.circular(6),
            minimumSize: const Size(44, 28),
            onPressed: () {
              unawaited(controller.cancel(task.id));
            },
            child: Text(
              l10n.cancel,
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
        );
        break;
      case DownloadStatus.completed:
        if (fileExistsOnDisk) {
          actionButtons.add(
            CupertinoButton(
              key: ValueKey('download-open-${task.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: CupertinoTheme.of(context).primaryColor,
              borderRadius: BorderRadius.circular(6),
              minimumSize: const Size(44, 28),
              onPressed: () {
                unawaited(
                  openDownloadedFile(
                    context,
                    task.savedPath!,
                    mimeType: task.mimeType,
                    customOpener: onOpenFile,
                  ),
                );
              },
              child: Text(
                l10n.downloadOpen,
                style: const TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          );
        } else {
          actionButtons.add(
            CupertinoButton(
              key: ValueKey('download-retry-${task.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: CupertinoTheme.of(context).primaryColor,
              borderRadius: BorderRadius.circular(6),
              minimumSize: const Size(44, 28),
              onPressed: () async {
                await controller.remove(task.id);
                await controller.enqueue(
                  sourceUrl: task.sourceUrl,
                  fileName: task.fileName,
                  mimeType: task.mimeType,
                  expectedBytes: task.expectedBytes,
                  sessionId: task.sessionId,
                );
              },
              child: Text(
                l10n.downloadRedownload,
                style: const TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          );
        }
        actionButtons.add(
          CupertinoButton(
            key: ValueKey('download-delete-${task.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            minimumSize: const Size(32, 28),
            onPressed: () {
              unawaited(controller.remove(task.id));
            },
            child: Icon(
              CupertinoIcons.trash,
              size: 18,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        );
        break;
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        actionButtons.add(
          CupertinoButton(
            key: ValueKey('download-retry-${task.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: CupertinoTheme.of(context).primaryColor,
            borderRadius: BorderRadius.circular(6),
            minimumSize: const Size(44, 28),
            onPressed: () {
              unawaited(controller.retry(task.id));
            },
            child: Text(
              l10n.downloadRetry,
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.white,
              ),
            ),
          ),
        );
        actionButtons.add(
          CupertinoButton(
            key: ValueKey('download-delete-${task.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            minimumSize: const Size(32, 28),
            onPressed: () {
              unawaited(controller.remove(task.id));
            },
            child: Icon(
              CupertinoIcons.trash,
              size: 18,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        );
        break;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6.resolveFrom(context),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  typeIcon,
                  size: 22,
                  color: CupertinoColors.activeBlue.resolveFrom(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      statusText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: statusColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(mainAxisSize: MainAxisSize.min, children: actionButtons),
            ],
          ),
          if (task.status == DownloadStatus.downloading) ...[
            const SizedBox(height: 8),
            CupertinoProgressBar(value: task.progress),
          ],
        ],
      ),
    );
  }
}
