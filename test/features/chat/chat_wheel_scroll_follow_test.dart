import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/api/sse_client.dart';
import 'package:hermes_ui/core/models/server_catalog.dart';
import 'package:hermes_ui/features/chat/chat_page.dart';
import 'package:hermes_ui/features/chat/chat_providers.dart';
import 'package:hermes_ui/features/chat/widgets/chat_message_list.dart';

import '../../helpers/fake_chat_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PC 桌面滚轮滚动跟随与状态机测试（#74 规格）', () {
    ScrollPosition positionOf(WidgetTester tester) {
      final scrollableFinder = find
          .descendant(
            of: find.byType(ChatMessageList),
            matching: find.byType(Scrollable),
          )
          .first;
      return tester.state<ScrollableState>(scrollableFinder).position;
    }

    ChatMessageListState listStateOf(WidgetTester tester) {
      return tester.state<ChatMessageListState>(find.byType(ChatMessageList));
    }

    Future<void> sendWheelScroll(
      WidgetTester tester, {
      required Offset scrollDelta,
    }) async {
      final scrollableFinder = find
          .descendant(
            of: find.byType(ChatMessageList),
            matching: find.byType(Scrollable),
          )
          .first;
      final center = tester.getCenter(scrollableFinder);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          kind: PointerDeviceKind.mouse,
          scrollDelta: scrollDelta,
        ),
      );
      await tester.pump();
    }

    testWidgets(
      '1. 滚轮上滚累计 >=8px 取消跟随：_userHasScrolled=true，后续 token 不跳底，回底按钮出现',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final api = FakeChatApi()
          ..statusResponse = const ChatStreamStatusResponse(active: true);
        final messages = List.generate(
          40,
          (i) => {
            'role': i.isEven ? 'user' : 'assistant',
            'content': '历史消息 $i：这是一段测试长消息内容，用于占满视口产生足够滚动高度。这是一段测试长消息内容。',
            'message_id': 'm_$i',
          },
        );

        api.sessionResult = {
          'session': {
            'session_id': 's-wheel-test-1',
            'active_stream_id': 'stream-wheel-1',
            'messages': messages,
            'message_count': 40,
          },
        };

        await tester.pumpWidget(
          ProviderScope(
            overrides: [chatApiProvider.overrideWithValue(api)],
            child: const CupertinoApp(
              home: ChatPage(sessionId: 's-wheel-test-1'),
            ),
          ),
        );

        await tester.pumpAndSettle();
        final listState = listStateOf(tester);
        expect(listState.initialPositioned, isTrue);
        expect(listState.nearBottom, isTrue);
        expect(listState.userHasScrolled, isFalse);

        final pos = positionOf(tester);
        expect(pos.maxScrollExtent - pos.pixels, lessThan(5.0));

        // 滚轮向上滚动 100px（scrollDelta.dy = -100 < 0，累计超 8px 敏感阈值且离底 > 80px）
        await sendWheelScroll(tester, scrollDelta: const Offset(0, -100));
        await tester.pumpAndSettle();

        expect(listState.userHasScrolled, isTrue);
        expect(listState.nearBottom, isFalse);

        // 回底按钮应出现
        final buttonFinder = find.byKey(
          const ValueKey('chat-scroll-to-bottom-button'),
        );
        expect(buttonFinder, findsOneWidget);
        expect(find.text('回到底部'), findsOneWidget);

        final readingPixels = pos.pixels;

        // 流式推送若干 token，视口不得被拽回底部
        for (var i = 0; i < 6; i++) {
          api.emit(TokenSseEvent('新增流式内容 $i\n'));
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 48));
          await tester.pump();
        }

        await tester.pumpAndSettle();
        final posAfterTokens = positionOf(tester);
        expect(
          (posAfterTokens.pixels - readingPixels).abs(),
          lessThan(5.0),
          reason: '鼠标滚轮上滚离底后，流式 token 不得拉扯视口',
        );
        expect(buttonFinder, findsOneWidget);
      },
    );

    testWidgets('2. 滚轮慢滚微幅多次连续累计：单次 <8px 不取消，累计 >=8px 触发取消跟随', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeChatApi()
        ..statusResponse = const ChatStreamStatusResponse(active: true);
      final messages = List.generate(
        40,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '历史消息 $i：这是一段测试长消息内容，用于占满视口产生足够滚动高度。这是一段测试长消息内容。',
          'message_id': 'm_$i',
        },
      );

      api.sessionResult = {
        'session': {
          'session_id': 's-wheel-test-2',
          'active_stream_id': 'stream-wheel-2',
          'messages': messages,
          'message_count': 40,
        },
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatApiProvider.overrideWithValue(api)],
          child: const CupertinoApp(
            home: ChatPage(sessionId: 's-wheel-test-2'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final listState = listStateOf(tester);

      // 第 1 次微滚：-4px（小于 8px 敏感阈值，排除轻微触碰误判）
      await sendWheelScroll(tester, scrollDelta: const Offset(0, -4));
      await tester.pump();
      expect(listState.userHasScrolled, isFalse, reason: '单次 4px 不应取消跟随');
      expect(listState.dragDisplacement, equals(-4.0));
      expect(listState.nearBottom, isTrue);

      // 第 2 次微滚：再 -5px（累计 -9px，已达到并超过 8px 敏感阈值）
      await sendWheelScroll(tester, scrollDelta: const Offset(0, -5));
      await tester.pump();
      expect(listState.userHasScrolled, isTrue, reason: '连续累计 9px 应取消跟随');
      expect(listState.nearBottom, isFalse);
    });

    testWidgets('3. 滚轮下滚回到底部：跟随恢复，回底按钮消失，新 token 正常跟底', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeChatApi()
        ..statusResponse = const ChatStreamStatusResponse(active: true);
      final messages = List.generate(
        40,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '历史消息 $i：这是一段测试长消息内容，用于占满视口产生足够滚动高度。这是一段测试长消息内容。',
          'message_id': 'm_$i',
        },
      );

      api.sessionResult = {
        'session': {
          'session_id': 's-wheel-test-3',
          'active_stream_id': 'stream-wheel-3',
          'messages': messages,
          'message_count': 40,
        },
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatApiProvider.overrideWithValue(api)],
          child: const CupertinoApp(
            home: ChatPage(sessionId: 's-wheel-test-3'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final listState = listStateOf(tester);

      // 滚轮上滚 100px 离开底部
      await sendWheelScroll(tester, scrollDelta: const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(listState.userHasScrolled, isTrue);
      expect(listState.nearBottom, isFalse);

      final buttonFinder = find.byKey(
        const ValueKey('chat-scroll-to-bottom-button'),
      );
      expect(buttonFinder, findsOneWidget);

      // 滚轮下滚 120px 回到底部（超出原有上滚量，贴底复位）
      await sendWheelScroll(tester, scrollDelta: const Offset(0, 120));
      await tester.pumpAndSettle();

      final pos = positionOf(tester);
      expect(pos.maxScrollExtent - pos.pixels, lessThanOrEqualTo(1.0));
      expect(listState.userHasScrolled, isFalse, reason: '滚回底部应恢复跟随');
      expect(listState.nearBottom, isTrue);
      expect(buttonFinder, findsNothing, reason: '恢复跟随按钮应隐藏');

      final beforeTokenPixels = pos.pixels;

      // 流式 token 应该继续跟底
      for (var i = 0; i < 4; i++) {
        api.emit(TokenSseEvent('恢复跟随后的 token $i\n'));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 48));
        await tester.pump();
      }

      await tester.pumpAndSettle();
      final afterTokenPixels = pos.pixels;
      expect(afterTokenPixels, greaterThan(beforeTokenPixels));
      expect(pos.maxScrollExtent - pos.pixels, lessThan(5.0));
    });

    testWidgets('4. 悬浮回底按钮点击恢复跟随', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeChatApi()
        ..statusResponse = const ChatStreamStatusResponse(active: true);
      final messages = List.generate(
        40,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '历史消息 $i：这是一段测试长消息内容，用于占满视口产生足够滚动高度。这是一段测试长消息内容。',
          'message_id': 'm_$i',
        },
      );

      api.sessionResult = {
        'session': {
          'session_id': 's-wheel-test-4',
          'active_stream_id': 'stream-wheel-4',
          'messages': messages,
          'message_count': 40,
        },
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatApiProvider.overrideWithValue(api)],
          child: const CupertinoApp(
            home: ChatPage(sessionId: 's-wheel-test-4'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final listState = listStateOf(tester);

      // 滚轮上滚 100px
      await sendWheelScroll(tester, scrollDelta: const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(listState.userHasScrolled, isTrue);

      final buttonFinder = find.byKey(
        const ValueKey('chat-scroll-to-bottom-button'),
      );
      expect(buttonFinder, findsOneWidget);

      // 点击悬浮回底按钮
      await tester.tap(buttonFinder);
      await tester.pumpAndSettle();

      expect(listState.userHasScrolled, isFalse);
      expect(listState.nearBottom, isTrue);
      expect(buttonFinder, findsNothing);
    });

    testWidgets('5. 触摸拖动原有取消跟随测试不回归（#41 语义不变）', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeChatApi()
        ..statusResponse = const ChatStreamStatusResponse(active: true);
      final messages = List.generate(
        40,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '历史消息 $i：这是一段测试长消息内容，用于占满视口产生足够滚动高度。这是一段测试长消息内容。',
          'message_id': 'm_$i',
        },
      );

      api.sessionResult = {
        'session': {
          'session_id': 's-wheel-test-5',
          'active_stream_id': 'stream-wheel-5',
          'messages': messages,
          'message_count': 40,
        },
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatApiProvider.overrideWithValue(api)],
          child: const CupertinoApp(
            home: ChatPage(sessionId: 's-wheel-test-5'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;

      // 触摸拖动 300px（手指下滑，内容向上看历史）
      await tester.drag(scrollable, const Offset(0, 300));
      await tester.pumpAndSettle();

      final pos = positionOf(tester);
      expect(pos.maxScrollExtent - pos.pixels, greaterThan(80));

      final buttonFinder = find.byKey(
        const ValueKey('chat-scroll-to-bottom-button'),
      );
      expect(buttonFinder, findsOneWidget);
    });

    testWidgets('6. 程序化滚动在途门控：门控在途时 scrollDelta 不计入滚轮位移', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = FakeChatApi()
        ..statusResponse = const ChatStreamStatusResponse(active: true);
      final messages = List.generate(
        40,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '历史消息 $i：这是一段测试长消息内容，用于占满视口产生足够滚动高度。这是一段测试长消息内容。',
          'message_id': 'm_$i',
        },
      );

      api.sessionResult = {
        'session': {
          'session_id': 's-wheel-test-6',
          'active_stream_id': 'stream-wheel-6',
          'messages': messages,
          'message_count': 40,
        },
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatApiProvider.overrideWithValue(api)],
          child: const CupertinoApp(
            home: ChatPage(sessionId: 's-wheel-test-6'),
          ),
        ),
      );

      await tester.pumpAndSettle();
      final listState = listStateOf(tester);

      // 初始收敛完成后门控空闲，且未发生用户滚动
      expect(listState.isProgrammaticScrolling, isFalse);
      expect(listState.userHasScrolled, isFalse);
      expect(listState.nearBottom, isTrue);
    });
  });
}
