import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/api/api_exception.dart';
import 'package:hermes_ui/core/cache/app_database.dart';
import 'package:hermes_ui/core/cache/cache_providers.dart';
import 'package:hermes_ui/core/cache/cache_service.dart';
import 'package:hermes_ui/core/models/server_catalog.dart';
import 'package:hermes_ui/features/chat/chat_page.dart';
import 'package:hermes_ui/features/chat/chat_providers.dart';
import 'package:hermes_ui/features/chat/widgets/collapsible_process_capsule.dart';
import 'package:hermes_ui/features/chat/widgets/tool_call_card.dart';
import 'package:hermes_ui/features/settings/tool_group_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_chat_api.dart';

void main() {
  Future<FakeChatApi> pumpTurnSession(
    WidgetTester tester, {
    required Map<String, dynamic> sessionData,
    bool turnCollapse = true,
    bool coalesceTools = false,
    bool hideThinking = false,
    FakeChatApi? customApi,
    List<Override>? extraOverrides,
    bool skipSessionResult = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      kTurnCollapseKey: turnCollapse,
      kToolGroupCoalesceKey: coalesceTools,
      kThinkGroupCoalesceKey: true,
      kHideReasoningKey: hideThinking,
    });

    final api = customApi ?? FakeChatApi();
    if (!skipSessionResult) {
      api.sessionResult = {'session': sessionData};
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatApiProvider.overrideWithValue(api), ...?extraOverrides],
        child: CupertinoApp(
          home: ChatPage(sessionId: sessionData['session_id'] as String),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  Map<String, dynamic> createMultiMessageTurnSession({
    String sessionId = 's-turn-1',
  }) {
    return {
      'session_id': sessionId,
      'title': '多消息回合',
      'active_stream_id': null,
      'messages': [
        {'role': 'user', 'content': '帮我审查代码', 'message_id': 'u1'},
        {
          'role': 'assistant',
          'message_id': 'a1',
          'reasoning': '第一步分析整体结构。',
          'content': '收到，首先检查整体架构。',
          'tool_calls': [
            {
              'id': 'call_1',
              'call_id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'read_file',
                'arguments': '{"path": "lib/main.dart"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'content': '{"status": "ok"}',
        },
        {
          'role': 'assistant',
          'message_id': 'a2',
          'reasoning': '第二步分析具体模块。',
          'content': '这是最终的审查报告，一切正常。',
          'tool_calls': [
            {
              'id': 'call_2',
              'call_id': 'call_2',
              'type': 'function',
              'function': {
                'name': 'analyze_code',
                'arguments': '{"target": "all"}',
              },
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_2',
          'content': '{"clean": true}',
        },
      ],
      'message_count': 5,
    };
  }

  group('TASK #55 回合顶部过程折叠胶囊测试', () {
    testWidgets('1. 多消息回合默认折叠：胶囊行存在，中间文本与卡片不可见，提问与最终文本常显', (tester) async {
      await pumpTurnSession(
        tester,
        sessionData: createMultiMessageTurnSession(),
      );

      // 胶囊行存在
      expect(find.byType(CollapsibleProcessCapsule), findsOneWidget);
      expect(
        find.byKey(const ValueKey('process-capsule-header')),
        findsOneWidget,
      );

      // 主人提问气泡常显
      expect(find.text('帮我审查代码'), findsOneWidget);

      // 最终答复文本常显
      expect(find.text('这是最终的审查报告，一切正常。'), findsOneWidget);

      // 中间助手文本在折叠态被收纳（SizedBox.shrink，不可见）
      expect(find.text('收到，首先检查整体架构。'), findsNothing);

      // 工具卡与思考卡被收敛进胶囊，外部树中不可见
      expect(find.byType(ToolCallGroupCard), findsNothing);
      expect(find.text('第一步分析整体结构。'), findsNothing);
    });

    testWidgets('1b. #58 胶囊位置：在用户提问气泡下方、最终答复上方', (tester) async {
      await pumpTurnSession(
        tester,
        sessionData: createMultiMessageTurnSession(),
      );

      final capsuleDy = tester
          .getTopLeft(find.byKey(const ValueKey('collapsible-process-capsule')))
          .dy;
      final userDy = tester.getTopLeft(find.text('帮我审查代码')).dy;
      final finalDy = tester.getTopLeft(find.text('这是最终的审查报告，一切正常。')).dy;

      // #58 改判（推翻 #55「胶囊钉回合最上方」）：提问 → 胶囊 → 最终答复
      expect(capsuleDy, greaterThan(userDy), reason: '#58 胶囊应在用户气泡下方');
      expect(capsuleDy, lessThan(finalDy), reason: '#58 胶囊应在最终答复上方');
    });

    testWidgets('2. 点胶囊展开与再次收起：展开后符合 #54 时间线语义，再次点击回到折叠态', (tester) async {
      await pumpTurnSession(
        tester,
        sessionData: createMultiMessageTurnSession(),
      );

      final capsuleHeader = find.byKey(
        const ValueKey('process-capsule-header'),
      );
      expect(capsuleHeader, findsOneWidget);

      // 点击展开
      await tester.tap(capsuleHeader);
      await tester.pumpAndSettle();

      // 中间正文与最终正文均已展开可见
      final text1Finder = find.textContaining('收到，首先检查整体架构');
      final text2Finder = find.textContaining('这是最终的审查报告');
      expect(text1Finder, findsOneWidget);
      expect(text2Finder, findsOneWidget);

      // 工具与思考卡片展开，符合 #54 时间线顺序（聚合关：3 张卡片）
      final toolCards = find.byType(ToolCallGroupCard);
      expect(toolCards, findsNWidgets(3));

      final card0Top = tester.getTopLeft(toolCards.at(0)).dy;
      final text1Top = tester.getTopLeft(text1Finder).dy;
      final card1Top = tester.getTopLeft(toolCards.at(1)).dy;
      final text2Top = tester.getTopLeft(text2Finder).dy;
      final card2Top = tester.getTopLeft(toolCards.at(2)).dy;

      // 首组思考卡在第一条正文上方
      expect(card0Top, lessThan(text1Top), reason: '首思考卡应在首条中间正文上方');

      // 中间卡在第一条正文下方、第二条正文上方（两正文之间）
      expect(card1Top, greaterThan(text1Top), reason: '中间卡应在第一条正文下方');
      expect(card1Top, lessThan(text2Top), reason: '中间卡应在第二条正文上方');

      // 末组工具卡在第二条正文下方
      expect(card2Top, greaterThan(text2Top), reason: '末组工具卡应在最后正文下方');

      // 再次点击胶囊头部折叠收起
      await tester.tap(capsuleHeader);
      await tester.pumpAndSettle();

      // 恢复为折叠态：中间文本与工具卡不可见，提问与最终文本仍常显
      expect(find.text('收到，首先检查整体架构。'), findsNothing);
      expect(find.byType(ToolCallGroupCard), findsNothing);
      expect(find.text('帮我审查代码'), findsOneWidget);
      expect(find.text('这是最终的审查报告，一切正常。'), findsOneWidget);
    });

    testWidgets('3. 纯工具无文本回合：不出现胶囊行，维持现状平铺', (tester) async {
      final sessionData = {
        'session_id': 's-pure-tools',
        'title': '纯工具会话',
        'active_stream_id': null,
        'messages': [
          {'role': 'user', 'content': '执行无返回文本工具', 'message_id': 'u1'},
          {
            'role': 'assistant',
            'message_id': 'a1',
            'content': '',
            'tool_calls': [
              {
                'id': 'call_1',
                'call_id': 'call_1',
                'type': 'function',
                'function': {'name': 'terminal_run', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': '{"ok":1}'},
        ],
        'message_count': 3,
      };

      await pumpTurnSession(tester, sessionData: sessionData);

      // 无胶囊行
      expect(find.byType(CollapsibleProcessCapsule), findsNothing);

      // 保持平铺渲染
      expect(find.text('执行无返回文本工具'), findsOneWidget);
      expect(find.byType(ToolCallGroupCard), findsOneWidget);
    });

    testWidgets('4. 含失败工具回合：不出现胶囊行，全平铺展示', (tester) async {
      final sessionData = {
        'session_id': 's-tool-fail',
        'title': '工具失败会话',
        'active_stream_id': null,
        'messages': [
          {'role': 'user', 'content': '请执行有可能会失败的命令', 'message_id': 'u1'},
          {
            'role': 'assistant',
            'message_id': 'a1',
            'content': '开始执行任务。',
            'tool_calls': [
              {
                'id': 'call_err',
                'call_id': 'call_err',
                'type': 'function',
                'function': {'name': 'bash', 'arguments': '{"cmd": "exit 1"}'},
                'is_error': true,
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'call_err',
            'content': '{"error": "failed"}',
          },
          {'role': 'assistant', 'message_id': 'a2', 'content': '执行遇到错误，请处理。'},
        ],
        'tool_calls': [
          {
            'name': 'bash',
            'snippet': 'command failed',
            'tid': 'call_err',
            'assistant_msg_idx': 1,
            'is_error': true,
          },
        ],
        'message_count': 4,
      };

      await pumpTurnSession(tester, sessionData: sessionData);

      // 含失败工具时不出现胶囊行
      expect(find.byType(CollapsibleProcessCapsule), findsNothing);

      // 全部内容平铺展示
      expect(find.text('请执行有可能会失败的命令'), findsOneWidget);
      expect(find.text('开始执行任务。'), findsOneWidget);
      expect(find.text('执行遇到错误，请处理。'), findsOneWidget);
      expect(find.byType(ToolCallGroupCard), findsOneWidget);
    });

    testWidgets('5. 开关关闭：完全维持现状逐条平铺，无胶囊行', (tester) async {
      await pumpTurnSession(
        tester,
        sessionData: createMultiMessageTurnSession(),
        turnCollapse: false,
      );

      // 无胶囊行
      expect(find.byType(CollapsibleProcessCapsule), findsNothing);

      // 所有过程消息和工具卡平铺可见
      expect(find.text('帮我审查代码'), findsOneWidget);
      expect(find.text('收到，首先检查整体架构。'), findsOneWidget);
      expect(find.text('这是最终的审查报告，一切正常。'), findsOneWidget);
      expect(find.byType(ToolCallGroupCard), findsNWidgets(3));
    });

    testWidgets('6. 流式回合（streaming 活跃消息）：不出现胶囊行', (tester) async {
      final customApi = FakeChatApi()
        ..statusResponse = const ChatStreamStatusResponse(active: true);

      final sessionData = {
        'session_id': 's-streaming-turn',
        'title': '流式生成中会话',
        'active_stream_id': 'stream-turn-active',
        'messages': [
          {'role': 'user', 'content': '进行流式长文本生成', 'message_id': 'u1'},
          {
            'role': 'assistant',
            'message_id': 'a1',
            'content': '第一批阶段性成果。',
            'tool_calls': [
              {
                'id': 'call_1',
                'call_id': 'call_1',
                'type': 'function',
                'function': {'name': 'fetch_data', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': '{"ok":1}'},
        ],
        'message_count': 3,
      };

      await pumpTurnSession(
        tester,
        sessionData: sessionData,
        customApi: customApi,
      );

      // 流式未完成状态下，不出现胶囊行
      expect(find.byType(CollapsibleProcessCapsule), findsNothing);
    });

    testWidgets('7. 展开记忆：展开回合后，会话内滚动/重建不自动收起', (tester) async {
      await pumpTurnSession(
        tester,
        sessionData: createMultiMessageTurnSession(sessionId: 's-memory-1'),
      );

      final capsuleHeader = find.byKey(
        const ValueKey('process-capsule-header'),
      );
      expect(capsuleHeader, findsOneWidget);

      // 默认折叠：中间正文不可见
      expect(find.text('收到，首先检查整体架构。'), findsNothing);

      // 点击展开
      await tester.tap(capsuleHeader);
      await tester.pumpAndSettle();

      // 断言中间正文展开可见
      expect(find.text('收到，首先检查整体架构。'), findsOneWidget);

      // 模拟列表滚动交互与触发重新渲染
      await tester.drag(find.byType(ListView), const Offset(0, -50));
      await tester.pumpAndSettle();

      // 滚动后状态依然保持展开记忆
      expect(find.text('收到，首先检查整体架构。'), findsOneWidget);
    });

    testWidgets('8. #70 缓存回放态（网络未回先铺缓存）：最后回合不闪折叠胶囊', (tester) async {
      // 预置离线缓存：一个带工具的完整回合（与用例 1 同形状）。
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final cacheService = CacheService(db);
      unawaited(
        cacheService.writeMessages(
          sessionId: 's-cache-flash',
          messages: [
            {'id': 'u1', 'role': 'user', 'content': '帮我审查代码', '_ts': 1000.0},
            {
              'id': 'a1',
              'role': 'assistant',
              'content': '收到，首先检查整体架构。',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'call_id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'read_file',
                    'arguments': '{"path": "lib/main.dart"}',
                  },
                },
              ],
              '_ts': 1001.0,
            },
            {
              'id': 'a2',
              'role': 'assistant',
              'content': '这是最终的审查报告，一切正常。',
              '_ts': 1002.0,
            },
          ],
        ),
      );
      await pumpTurnSession(
        tester,
        sessionData: const {'session_id': 's-cache-flash'},
        skipSessionResult: true,
        extraOverrides: [
          cacheServiceProvider.overrideWithValue(cacheService),
          appDatabaseProvider.overrideWithValue(db),
        ],
        customApi: FakeChatApi()
          ..sessionError = NetworkException(NetworkExceptionKind.cannotConnect),
      );
      await tester.pumpAndSettle();

      // 缓存消息已渲染（回放态），但流状态未知 → 最后回合不折叠、无胶囊。
      expect(find.text('帮我审查代码'), findsOneWidget);
      expect(find.text('这是最终的审查报告，一切正常。'), findsOneWidget);
      expect(find.byType(CollapsibleProcessCapsule), findsNothing);
    });
  });
}
