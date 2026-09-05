import 'package:flutter/cupertino.dart';

import '../../l10n/app_localizations.dart';
import 'download_models.dart';
import 'download_page.dart';

/// 弹出 Cupertino 下载确认对话框。
///
/// 展示：文件名、文件分类、文件大小（或未知大小）、来源会话/路径（若有）。
/// 返回 true 表示用户确认开始下载，返回 false 或 null 表示取消。
Future<bool?> showDownloadConfirmationDialog(
  BuildContext context, {
  required String fileName,
  String? mimeType,
  int? expectedBytes,
  String? sessionId,
  String? sourceDescription,
}) {
  final l10n = AppLocalizations.of(context);
  final fileType = getDownloadFileType(fileName: fileName, mimeType: mimeType);
  final typeName = localizeDownloadFileType(fileType, l10n);
  final sizeText = expectedBytes != null && expectedBytes > 0
      ? formatDownloadByteSize(expectedBytes)
      : l10n.downloadUnknownSize;
  final sessionText =
      (sourceDescription != null && sourceDescription.isNotEmpty)
      ? sourceDescription
      : ((sessionId != null && sessionId.isNotEmpty)
            ? (sessionId.length > 12
                  ? '${sessionId.substring(0, 12)}…'
                  : sessionId)
            : null);

  return showCupertinoDialog<bool>(
    context: context,
    builder: (dialogCtx) => CupertinoAlertDialog(
      title: Text(l10n.downloadConfirmTitle),
      content: Padding(
        padding: const EdgeInsets.only(top: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${l10n.name}：$fileName'),
            const SizedBox(height: 4),
            Text('${l10n.info}：$typeName'),
            const SizedBox(height: 4),
            Text('${l10n.value}：$sizeText'),
            if (sessionText != null) ...[
              const SizedBox(height: 4),
              Text('${l10n.downloadFromSession}：$sessionText'),
            ],
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: Text(l10n.downloadConfirmCancel),
          onPressed: () => Navigator.of(dialogCtx).pop(false),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          child: Text(l10n.downloadConfirmStart),
          onPressed: () => Navigator.of(dialogCtx).pop(true),
        ),
      ],
    ),
  );
}
