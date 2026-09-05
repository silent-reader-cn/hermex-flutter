import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/cache/app_database.dart';
import 'package:hermes_ui/core/cache/cache_providers.dart';
import 'package:hermes_ui/core/connections/connection_providers.dart';
import 'package:hermes_ui/core/connections/server_connection.dart';
import 'package:hermes_ui/core/models/chat_message.dart';
import 'package:hermes_ui/core/models/message_attachment.dart';
import 'package:hermes_ui/core/models/upload_response.dart';
import 'package:hermes_ui/features/chat/pending_attachments_provider.dart';
import 'package:hermes_ui/features/chat/widgets/attachment_pending_bar.dart';
import 'package:hermes_ui/features/chat/widgets/chat_media_view.dart';
import 'package:hermes_ui/features/chat/widgets/message_bubble.dart';
import 'package:hermes_ui/features/downloads/download_providers.dart';
import 'package:hermes_ui/features/downloads/download_repository.dart';
import 'package:hermes_ui/features/downloads/download_save_service.dart';
import 'package:hermes_ui/features/notifications/notification_providers.dart';
import 'package:hermes_ui/features/notifications/turn_notification_service.dart';

import '../../helpers/fake_media_cache.dart';

/// 下载链路测试双：AttachmentLightbox 的下载按钮 watch downloadControllerProvider
///（→ apiClientProvider 需真实连接），widget 测试必须注入假执行器、假通知与
/// 内存 DB，避免「尚未配置服务器连接」/ 真实插件挂起。
class _FakeDownloadNotificationService implements TurnNotificationService {
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

/// 构造下载链路测试 override（内存 DB + fake 下载器 + fake 通知 + 临时保存目录）。
List<Override> buildDownloadOverrides({
  Directory? tempDir,
  DownloadBytesDownloader? downloader,
}) {
  final db = AppDatabase.memory();
  return [
    appDatabaseProvider.overrideWithValue(db),
    downloadRepositoryProvider.overrideWithValue(DownloadRepository(db)),
    downloadSaveServiceProvider.overrideWithValue(
      DownloadSaveService(
        destinationDirOverride:
            tempDir ?? Directory.systemTemp.createTempSync('media_bubble_dl_'),
      ),
    ),
    turnNotificationServiceProvider.overrideWithValue(
      _FakeDownloadNotificationService(),
    ),
    downloadDownloaderProvider.overrideWithValue(
      downloader ??
          ((uri, {onProgress}) async => Uint8List.fromList([1, 2, 3, 4])),
    ),
  ];
}

// 1x1 像素有效透明 PNG base64 数据
const _k1x1Png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

class _FakeActiveConnectionController extends ActiveConnectionController {
  _FakeActiveConnectionController(this._initial);
  final ServerConnection? _initial;
  @override
  ServerConnection? build() => _initial;
}

/// 包一层 ProviderScope：ChatInlineMediaWidget 已是 ConsumerWidget，且网络图
/// 经 MediaCacheService（provider）取数。构造默认的假媒体缓存（下载抛错
/// → 渲染占位），需要成功场景时传 `rig`。
Widget _testApp(Widget home, {FakeMediaCacheRig? rig}) {
  final service = (rig ?? buildFakeMediaCache()).service;
  return ProviderScope(
    overrides: [
      activeConnectionProvider.overrideWith(
        () => _FakeActiveConnectionController(null),
      ),
      mediaCacheOverride(service),
      ...buildDownloadOverrides(),
    ],
    child: CupertinoApp(home: CupertinoPageScaffold(child: home)),
  );
}

/// 让真实异步（drift / 文件 IO / 下载回调）在 widget 测试中完成：
/// FakeAsync 下 `pumpAndSettle` 会被无限转圈的加载指示器卡住，且真实 IO
/// 不会推进；用 `tester.runAsync` 放行真实事件循环后 pump 一帧即可。
Future<void> _settleMediaAsync(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
}

void main() {
  group('ChatMessageBubble 媒体标记与附件内联渲染 Widget 测试', () {
    testWidgets('助手消息 MEDIA: data:image 渲染为内联 Image.memory', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      const message = ChatMessage(
        role: 'assistant',
        content: '这是渲染好的图片：MEDIA:$_k1x1Png 很好。',
      );

      await tester.pumpWidget(
        _testApp(const ChatMessageBubble(message: message)),
      );
      await tester.pump();

      expect(find.byType(ChatInlineMediaWidget), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<MemoryImage>(),
      );
      expect(find.textContaining('很好。'), findsOneWidget);
    });

    testWidgets('助手消息 MEDIA: 网络图片 URL 渲染 ChatInlineMediaWidget', (
      tester,
    ) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      const message = ChatMessage(
        role: 'assistant',
        content: '请查看：MEDIA:https://example.com/assets/banner.png',
      );

      await tester.pumpWidget(
        _testApp(
          const ChatMessageBubble(
            message: message,
            baseUrl: 'http://localhost:30002',
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ChatInlineMediaWidget), findsOneWidget);
    });

    testWidgets('ChatInlineMediaWidget 图片加载失败时显示占位符，不白屏且展示 Cupertino 错误提示', (
      tester,
    ) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      await tester.pumpWidget(
        _testApp(
          const ChatInlineMediaWidget(
            rawUri: 'data:image/png;base64,INVALID_BASE64_CORRUPTED_DATA',
            alt: 'corrupted.png',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('图片加载失败'), findsOneWidget);
      expect(find.text('corrupted.png'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.photo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('助手消息音频/视频/文档 MEDIA: 标记转换为对应链接芯片', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      const message = ChatMessage(
        role: 'assistant',
        content: '音频：MEDIA:/tmp/audio.mp3\n\n文档：MEDIA:/tmp/spec.pdf',
      );

      await tester.pumpWidget(
        _testApp(const ChatMessageBubble(message: message)),
      );
      await tester.pump();

      expect(find.textContaining('🎵 audio.mp3'), findsOneWidget);
      expect(find.textContaining('📎 spec.pdf'), findsOneWidget);
    });

    testWidgets('用户消息附件展示 ChatAttachmentChipView 与图标', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      const message = ChatMessage(
        role: 'user',
        content: '你好',
        attachments: [
          MessageAttachment(name: 'photo.jpg', isImage: true),
          MessageAttachment(name: 'report.pdf', isImage: false),
        ],
      );

      await tester.pumpWidget(
        _testApp(const ChatMessageBubble(message: message)),
      );
      await tester.pump();

      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.photo), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.doc_text), findsOneWidget);
    });

    testWidgets('用户消息尾部 [Attached files: ...] 标记被剥离，附件正常渲染', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      final message = ChatMessage.fromJson(const {
        'role': 'user',
        'content': '发送此文件\n\n[Attached files: /tmp/invoice.pdf]',
      });

      await tester.pumpWidget(_testApp(ChatMessageBubble(message: message)));
      await tester.pump();

      expect(find.text('发送此文件'), findsOneWidget);
      expect(find.textContaining('[Attached files:'), findsNothing);
      expect(find.text('invoice.pdf'), findsOneWidget);
    });

    testWidgets('点击内联图片可弹出全屏查看器（Lightbox）且可点击关闭', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      await tester.pumpWidget(
        _testApp(
          const ChatInlineMediaWidget(rawUri: _k1x1Png, title: 'preview.png'),
        ),
      );
      await tester.pump();

      final imgFinder = find.byType(ChatInlineMediaWidget);
      expect(imgFinder, findsOneWidget);

      await tester.tap(imgFinder);
      await tester.pumpAndSettle();

      // 验证弹出全屏 Lightbox
      expect(find.byType(InteractiveViewer), findsOneWidget);
      // 回归（真机反馈 bug）：1x1 小图时 InteractiveViewer 曾被 Center 收缩
      // 为图片自然尺寸，放大内容被内部 ClipRect 裁回小框。视口必须铺满宽度。
      final viewerSize = tester.getSize(find.byType(InteractiveViewer));
      expect(viewerSize.width, 800);
      expect(viewerSize.height, greaterThan(400));
      expect(find.byIcon(CupertinoIcons.clear_thick), findsOneWidget);

      // 点击关闭
      await tester.tap(find.byIcon(CupertinoIcons.clear_thick));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('ProviderScope 激活连接 baseUrl 正确注入到媒体组件', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      final conn = ServerConnection(
        id: 'conn_1',
        name: 'Dev Server',
        baseUrl: 'http://hermes.example.com:30002',
        createdAt: DateTime(2026),
      );

      const message = ChatMessage(
        role: 'assistant',
        content: 'MEDIA:/var/data/output.png',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWith(
              () => _FakeActiveConnectionController(conn),
            ),
            mediaCacheOverride(rig.service),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatMessageBubble(message: message),
            ),
          ),
        ),
      );
      await tester.pump();

      final widgetFinder = find.byType(ChatInlineMediaWidget);
      expect(widgetFinder, findsOneWidget);
      final inlineWidget = tester.widget<ChatInlineMediaWidget>(widgetFinder);
      expect(inlineWidget.baseUrl, 'http://hermes.example.com:30002');
    });

    // ── P2 媒体缓存渲染切换：网络图经 MediaCacheService 落盘 → Image.file ──
    // 说明：MediaCacheService 的命中/下载/淘汰逻辑已在单测全覆盖；此处直接
    // override mediaFileProvider 验证渲染切换（成功→Image.file / 失败→占位），
    // 避免 FakeAsync 下真实 drift+文件 IO 的不确定性。
    testWidgets('网络图片成功下载后渲染为 Image.file', (tester) async {
      // 真实 PNG 临时文件，供 Image.file 解码。
      final pngFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}hermex_net_success.png',
      );
      await tester.runAsync(
        () => pngFile.writeAsBytes(base64Decode(_k1x1Png.split(',').last)),
      );
      addTearDown(() async {
        try {
          await pngFile.delete();
        } on FileSystemException {
          // ignore
        }
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaFileProvider.overrideWith((ref, url) async => pngFile),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatInlineMediaWidget(
                rawUri: 'https://example.com/assets/banner.png',
                alt: 'banner.png',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<FileImage>());
      expect((image.image as FileImage).file.path, pngFile.path);
      expect(find.text('图片加载失败'), findsNothing);
    });

    testWidgets('网络图片下载失败（非 2xx/网络错）渲染为失败占位符', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaFileProvider.overrideWith(
              (ref, url) async => throw StateError('401 for test'),
            ),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatInlineMediaWidget(
                rawUri: 'https://example.com/assets/secret.png',
                alt: 'secret.png',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('图片加载失败'), findsOneWidget);
      expect(find.text('secret.png'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.photo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('本地 file:// 路径分支仍走 Image.file（不经媒体缓存）', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);
      // 构造一个真实存在的临时 PNG 文件，作为本地 file:// 引用。
      // 真实文件 IO 在 FakeAsync 下不会推进，须经 runAsync 完成。
      final tmpFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}hermex_local_test.png',
      );
      await tester.runAsync(
        () => tmpFile.writeAsBytes(base64Decode(_k1x1Png.split(',').last)),
      );
      addTearDown(() async {
        try {
          await tmpFile.delete();
        } on FileSystemException {
          // ignore
        }
      });

      await tester.pumpWidget(
        _testApp(ChatInlineMediaWidget(rawUri: tmpFile.path)),
      );
      await _settleMediaAsync(tester);

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<FileImage>());
    });

    testWidgets('ChatInlineMediaWidget 不再使用 AnimatedSize（extent 一步到位）', (
      tester,
    ) async {
      // 尺寸动画（AnimatedSize）会把占位→真图的差异逐帧撑高 maxScrollExtent，
      // 底部跟随只能逐帧补跳；现改为真实尺寸一步到位 + 出帧淡入。
      await tester.pumpWidget(
        _testApp(
          const ChatInlineMediaWidget(rawUri: _k1x1Png, alt: 'preview.png'),
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(ChatInlineMediaWidget),
          matching: find.byType(AnimatedSize),
        ),
        findsNothing,
      );
    });

    testWidgets('网络图片 loading 期间渲染指定尺寸 loadingBox 与加载指示器', (tester) async {
      final completer = Completer<File>();
      // 构造一个处于 loading 状态的 FutureProvider
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaFileProvider.overrideWith((ref, url) => completer.future),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatInlineMediaWidget(
                rawUri: 'https://example.com/assets/loading_photo.png',
                alt: 'loading_photo.png',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

      final containerFinder = find.descendant(
        of: find.byType(ChatInlineMediaWidget),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints?.maxWidth == 160 &&
              w.constraints?.maxHeight == 120,
        ),
      );
      expect(containerFinder, findsOneWidget);
    });

    testWidgets('网络图片 URL 包含宽高参数时，自适应预设占位尺寸', (tester) async {
      final completer = Completer<File>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaFileProvider.overrideWith((ref, url) => completer.future),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatInlineMediaWidget(
                rawUri: 'https://example.com/assets/banner.png?w=600&h=300',
                alt: 'banner.png',
                maxWidth: 360,
                maxHeight: 320,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

      // 600x300 在 maxWidth 360, maxHeight 320 contain 缩放后应为 360x180
      final containerFinder = find.descendant(
        of: find.byType(ChatInlineMediaWidget),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints?.maxWidth == 360 &&
              w.constraints?.maxHeight == 180,
        ),
      );
      expect(containerFinder, findsOneWidget);
    });

    testWidgets('待发图片附件：点缩略图/文件名区域弹出 Lightbox 全屏预览，可缩放并点击 clear_thick 关闭', (
      tester,
    ) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);

      final container = ProviderContainer(
        overrides: [
          mediaCacheOverride(rig.service),
          ...buildDownloadOverrides(),
        ],
      );
      addTearDown(container.dispose);

      final attachment = PendingAttachment(
        id: 'att-img-1',
        name: 'sample_photo.png',
        path: '/tmp/sample_photo.png',
        mime: 'image/png',
        isImage: true,
        thumbnailData: base64Decode(_k1x1Png.split(',').last),
      );

      container
          .read(pendingAttachmentsProvider('session-1').notifier)
          .add(attachment);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: AttachmentPendingBar(sessionId: 'session-1'),
            ),
          ),
        ),
      );
      await tester.pump();

      // 验证待发条出现且有预览 key 与删除 key
      expect(
        find.byKey(const ValueKey('attachment-preview-att-img-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('attachment-remove-att-img-1')),
        findsOneWidget,
      );
      expect(find.text('sample_photo.png'), findsOneWidget);

      // 点击缩略图/文件名区域进入 Lightbox
      await tester.tap(
        find.byKey(const ValueKey('attachment-preview-att-img-1')),
      );
      await tester.pumpAndSettle();

      // 验证全屏 Lightbox
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.minScale, 0.5);
      expect(viewer.maxScale, 4.0);
      expect(find.byIcon(CupertinoIcons.clear_thick), findsOneWidget);
      expect(find.text('sample_photo.png'), findsOneWidget);

      // 点击 clear_thick 关闭
      await tester.tap(find.byIcon(CupertinoIcons.clear_thick));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsNothing);
      expect(
        find.byKey(const ValueKey('attachment-preview-att-img-1')),
        findsOneWidget,
      );
    });

    testWidgets('待发卡点击删除按钮 xmark 仅删除附件，不误触发预览', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);

      final container = ProviderContainer(
        overrides: [mediaCacheOverride(rig.service)],
      );
      addTearDown(container.dispose);

      final attachment = PendingAttachment(
        id: 'att-img-2',
        name: 'photo_to_remove.png',
        path: '/tmp/photo_to_remove.png',
        mime: 'image/png',
        isImage: true,
        thumbnailData: base64Decode(_k1x1Png.split(',').last),
      );

      container
          .read(pendingAttachmentsProvider('session-2').notifier)
          .add(attachment);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: AttachmentPendingBar(sessionId: 'session-2'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('attachment-remove-att-img-2')),
        findsOneWidget,
      );

      // 点击 xmark 删除
      await tester.tap(
        find.byKey(const ValueKey('attachment-remove-att-img-2')),
      );
      await tester.pumpAndSettle();

      // 验证未弹出 Lightbox 且附件已被清空
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(container.read(pendingAttachmentsProvider('session-2')), isEmpty);
    });

    testWidgets('待发非图片附件：点击弹出「不支持预览」与下载操作', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);

      final container = ProviderContainer(
        overrides: [
          mediaCacheOverride(rig.service),
          ...buildDownloadOverrides(),
        ],
      );
      addTearDown(container.dispose);

      final attachment = PendingAttachment(
        id: 'att-doc-1',
        name: 'architecture.pdf',
        path: '/tmp/architecture.pdf',
        mime: 'application/pdf',
        isImage: false,
      );

      container
          .read(pendingAttachmentsProvider('session-3').notifier)
          .add(attachment);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: AttachmentPendingBar(sessionId: 'session-3'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('attachment-preview-att-doc-1')),
      );
      await tester.pumpAndSettle();

      // 验证显示不支持预览文案与下载按钮
      expect(find.text('不支持预览'), findsOneWidget);
      expect(find.text('architecture.pdf'), findsWidgets);
      expect(
        find.byKey(const ValueKey('attachment-download-button')),
        findsOneWidget,
      );

      // 点击关闭
      await tester.tap(find.byIcon(CupertinoIcons.clear_thick));
      await tester.pumpAndSettle();
      expect(find.text('不支持预览'), findsNothing);
    });

    testWidgets('用户气泡图片附件：点下方芯片进入同一 Lightbox 大图并复用缓存', (tester) async {
      final rig = buildFakeMediaCache();
      addTearDown(rig.dispose);

      const message = ChatMessage(
        role: 'user',
        content: '这是图片附件',
        attachments: [
          MessageAttachment(name: 'diagram.png', path: _k1x1Png, isImage: true),
        ],
      );

      await tester.pumpWidget(
        _testApp(const ChatMessageBubble(message: message), rig: rig),
      );
      await tester.pump();

      // 验证芯片与内联图均渲染
      expect(
        find.byKey(const ValueKey('attachment-chip-preview-diagram.png')),
        findsOneWidget,
      );

      // 点击芯片进入 Lightbox
      await tester.tap(
        find.byKey(const ValueKey('attachment-chip-preview-diagram.png')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('diagram.png'), findsOneWidget);

      // 关闭 Lightbox
      await tester.tap(find.byIcon(CupertinoIcons.clear_thick));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('用户气泡非图片附件：点击芯片弹出「不支持预览」与下载按钮，点击触发下载并成功标记', (tester) async {
      final tmpFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}test_spec.pdf',
      );
      await tester.runAsync(() => tmpFile.writeAsBytes([1, 2, 3]));
      addTearDown(() async {
        try {
          await tmpFile.delete();
        } on FileSystemException {
          // ignore
        }
      });

      const message = ChatMessage(
        role: 'user',
        content: '这是规范文档',
        attachments: [
          MessageAttachment(
            name: 'spec.pdf',
            path: 'https://example.com/media/spec.pdf',
            isImage: false,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWith(
              () => _FakeActiveConnectionController(null),
            ),
            mediaFileProvider.overrideWith((ref, url) async => tmpFile),
            ...buildDownloadOverrides(),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatMessageBubble(message: message),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('attachment-chip-preview-spec.pdf')),
        findsOneWidget,
      );

      // 点击芯片
      await tester.tap(
        find.byKey(const ValueKey('attachment-chip-preview-spec.pdf')),
      );
      await tester.pumpAndSettle();

      expect(find.text('不支持预览'), findsOneWidget);
      expect(find.text('spec.pdf'), findsWidgets);
      final downloadBtn = find.byKey(
        const ValueKey('attachment-download-button'),
      );
      expect(downloadBtn, findsOneWidget);
      expect(find.text('下载'), findsOneWidget);

      // 点击下载按钮：先弹确认框，确认后走下载队列。
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();
      expect(find.text('开始下载'), findsOneWidget);
      await tester.tap(find.text('开始下载'));
      // 队列链跨 FakeAsync（microtask 续体）+ 真实 IO（drift/文件写入）：
      // 交替 runAsync（推进真实事件）与 pump（消化 FakeAsync microtask）轮询。
      var taskSettled = false;
      for (var i = 0; i < 50 && !taskSettled; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        taskSettled =
            find.text('已下载').evaluate().isNotEmpty ||
            find.text('重试').evaluate().isNotEmpty;
      }

      // 验证下载成功标记（任务已完成 → 按钮显示「已下载」）
      expect(find.text('已下载'), findsOneWidget);

      // 关闭
      await tester.tap(find.byIcon(CupertinoIcons.clear_thick));
      await tester.pumpAndSettle();
      expect(find.text('不支持预览'), findsNothing);
    });

    testWidgets('下载失败时不崩溃且优雅降级', (tester) async {
      const message = ChatMessage(
        role: 'user',
        content: '错误文件',
        attachments: [
          MessageAttachment(
            name: 'corrupted.zip',
            path: 'https://example.com/media/corrupted.zip',
            isImage: false,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWith(
              () => _FakeActiveConnectionController(null),
            ),
            mediaFileProvider.overrideWith(
              (ref, url) async => throw Exception('Network timeout'),
            ),
            // 下载执行器也抛错 → 队列任务 failed → 按钮回到可重试状态。
            ...buildDownloadOverrides(
              downloader: (uri, {onProgress}) async =>
                  throw Exception('Network timeout'),
            ),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatMessageBubble(message: message),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('attachment-chip-preview-corrupted.zip')),
      );
      await tester.pumpAndSettle();

      expect(find.text('不支持预览'), findsOneWidget);
      final downloadBtn = find.byKey(
        const ValueKey('attachment-download-button'),
      );
      expect(downloadBtn, findsOneWidget);

      // 点击下载（先确认框再确认，队列真实异步失败落定）
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();
      expect(find.text('开始下载'), findsOneWidget);
      await tester.tap(find.text('开始下载'));
      var taskSettled = false;
      for (var i = 0; i < 50 && !taskSettled; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        taskSettled =
            find.text('重试').evaluate().isNotEmpty ||
            find.text('已下载').evaluate().isNotEmpty;
      }

      // 验证没有未捕获异常崩溃，按钮回到可重试状态
      expect(tester.takeException(), isNull);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('图片 Lightbox 底部包含下载按钮且点击可触发下载落盘', (tester) async {
      final tmpDir = Directory.systemTemp.createTempSync('lightbox_dl_');
      addTearDown(() {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      const message = ChatMessage(
        role: 'user',
        content: '看这张图片',
        attachments: [
          MessageAttachment(name: 'photo.png', path: _k1x1Png, isImage: true),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWith(
              () => _FakeActiveConnectionController(null),
            ),
            ...buildDownloadOverrides(tempDir: tmpDir),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatMessageBubble(message: message),
            ),
          ),
        ),
      );
      await tester.pump();

      // 点击附件芯片打开 Lightbox
      await tester.tap(
        find.byKey(const ValueKey('attachment-chip-preview-photo.png')),
      );
      await tester.pumpAndSettle();

      // 验证大图与底部的下载按钮均展示
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final downloadBtn = find.byKey(
        const ValueKey('attachment-download-button'),
      );
      expect(downloadBtn, findsOneWidget);
      expect(find.text('下载'), findsOneWidget);

      // 点击下载，弹出确认对话框
      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();
      expect(find.text('开始下载'), findsOneWidget);

      // 点击开始下载
      await tester.tap(find.text('开始下载'));
      // 推进真实异步
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('已下载').evaluate().isNotEmpty) break;
      }

      expect(find.text('已下载'), findsOneWidget);
    });

    testWidgets('内存字节（未保存为本地文件）不应误判为「已下载/已保存」', (tester) async {
      final attachment = PendingAttachment(
        id: 'att-mem-1',
        name: 'memory_doc.pdf',
        path: 'memory_doc.pdf',
        mime: 'application/pdf',
        isImage: false,
        thumbnailData: Uint8List.fromList([1, 2, 3]),
      );

      final container = ProviderContainer(
        overrides: [...buildDownloadOverrides()],
      );
      addTearDown(container.dispose);

      container
          .read(pendingAttachmentsProvider('session-mem').notifier)
          .add(attachment);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: AttachmentPendingBar(sessionId: 'session-mem'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('attachment-preview-att-mem-1')),
      );
      await tester.pumpAndSettle();

      // 初始状态下虽有内存 bytes，但不是本地已有文件，应显示「下载」而非「已保存」或「已下载」
      final downloadBtn = find.byKey(
        const ValueKey('attachment-download-button'),
      );
      expect(downloadBtn, findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('已保存'), findsNothing);
      expect(find.text('已下载'), findsNothing);
    });

    testWidgets('不可解析来源的附件显示禁用态并呈现「无法从此来源下载」', (tester) async {
      const message = ChatMessage(
        role: 'user',
        content: '无效附件',
        attachments: [
          MessageAttachment(
            name: 'bad_file.bin',
            path: 'invalid_scheme://not_real',
            isImage: false,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWith(
              () => _FakeActiveConnectionController(null),
            ),
            ...buildDownloadOverrides(),
          ],
          child: const CupertinoApp(
            home: CupertinoPageScaffold(
              child: ChatMessageBubble(message: message),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('attachment-chip-preview-bad_file.bin')),
      );
      await tester.pumpAndSettle();

      // 验证禁用态文案与不可点击
      expect(find.text('无法从此来源下载'), findsOneWidget);
      final downloadBtn = tester.widget<CupertinoButton>(
        find.byKey(const ValueKey('attachment-download-button')),
      );
      expect(downloadBtn.onPressed, isNull);
    });
  });
}
