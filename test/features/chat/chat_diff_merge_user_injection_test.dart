import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/models/chat_message.dart';
import 'package:hermes_ui/features/chat/chat_diff_merge.dart';

void main() {
  group('TASK #61 用户消息双气泡与服务端注入行 diff-merge 测试', () {
    test('1. RED 复现：带服务端注入标记的 server 消息与 local 乐观消息成功匹配，消除双气泡并剥离标记', () {
      const local = [
        ChatMessage(
          messageId: 'local-x',
          role: 'user',
          content: '图中出现两个先两个跑的原因是什么',
          timestamp: 100.0,
        ),
      ];

      const server = [
        ChatMessage(
          messageId: '42',
          role: 'user',
          content: '[Workspace::v1: D:\\projects\\hermes-ui]\n图中出现两个先两个跑的原因是什么\n\n[Attached files: C:\\a\\b.jpg]\n[screenshot]',
          timestamp: 105.0,
        ),
      ];

      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: server,
      );

      // 断言 merge 结果只有一条 user 消息
      expect(merged, hasLength(1));
      final msg = merged.first;
      expect(msg.role, 'user');
      expect(msg.messageId, '42');

      // 断言 content 不含注入标记
      expect(msg.content, isNot(contains('[Workspace::v1')));
      expect(msg.content, isNot(contains('[Attached files')));
      expect(msg.content, isNot(contains('[screenshot]')));
      expect(msg.content, '图中出现两个先两个跑的原因是什么');
    });

    test('2. 不误伤：两条内容确实不同的 user 消息（归一化后仍不等）保持双条', () {
      const local = [
        ChatMessage(
          messageId: 'local-x',
          role: 'user',
          content: '这是用户第一条问题',
          timestamp: 100.0,
        ),
      ];

      const server = [
        ChatMessage(
          messageId: '42',
          role: 'user',
          content: '[Workspace::v1: D:\\projects\\hermes-ui]\n这是完全不同的第二条问题\n\n[Attached files: C:\\a\\b.jpg]\n[screenshot]',
          timestamp: 105.0,
        ),
      ];

      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: server,
      );

      expect(merged, hasLength(2));
      expect(merged[0].messageId, 'local-x');
      expect(merged[1].messageId, '42');
    });

    test('3. 时间窗外（>120s）相同内容不匹配（维持既有语义）', () {
      const local = [
        ChatMessage(
          messageId: 'local-x',
          role: 'user',
          content: '图中出现两个先两个跑的原因是什么',
          timestamp: 100.0,
        ),
      ];

      const server = [
        ChatMessage(
          messageId: '42',
          role: 'user',
          content: '[Workspace::v1: D:\\projects\\hermes-ui]\n图中出现两个先两个跑的原因是什么\n\n[Attached files: C:\\a\\b.jpg]\n[screenshot]',
          timestamp: 300.0, // 差 200s > 120s
        ),
      ];

      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: server,
      );

      // 超过 120s 不匹配，保持双条
      expect(merged, hasLength(2));
    });

    test('4. 归一化后为空串时，保留 local.content 兜底', () {
      const local = [
        ChatMessage(
          messageId: 'local-empty-text',
          role: 'user',
          content: '',
          timestamp: 100.0,
        ),
      ];

      const server = [
        ChatMessage(
          messageId: '43',
          role: 'user',
          content: '[Workspace::v1: D:\\projects\\hermes-ui]\n[Attached files: C:\\a\\b.jpg]\n[screenshot]',
          timestamp: 105.0,
        ),
      ];

      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: server,
      );

      expect(merged, hasLength(1));
      expect(merged.first.messageId, '43');
      expect(merged.first.content, '');
    });

    test('5. 行内占位符不误伤，整行精确匹配才删', () {
      const local = [
        ChatMessage(
          messageId: 'local-inline',
          role: 'user',
          content: '请参考 [screenshot] 和 [image] 的说明',
          timestamp: 100.0,
        ),
      ];

      const server = [
        ChatMessage(
          messageId: '44',
          role: 'user',
          content: '[Workspace::v1: D:\\projects\\hermes-ui]\n请参考 [screenshot] 和 [image] 的说明\n\n[Attached files: C:\\a\\b.jpg]\n[screenshot]',
          timestamp: 105.0,
        ),
      ];

      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: server,
      );

      expect(merged, hasLength(1));
      expect(merged.first.content, '请参考 [screenshot] 和 [image] 的说明');
    });

    test('6. 容忍前导换行、转义反斜杠、大小写与行内多余空格', () {
      const local = [
        ChatMessage(
          messageId: 'local-loose',
          role: 'user',
          content: '多行测试\n第二行正文',
          timestamp: 100.0,
        ),
      ];

      const server = [
        ChatMessage(
          messageId: '45',
          role: 'user',
          content: '\n\n[Workspace::v1: C:\\Users\\Admin\\project (branch-x)]  \n多行测试\n第二行正文\n\n[Attached files: C:\\path with space\\image.png]  \n  [SCREENSHOT]  \n  [image]  \n  [attachment]  ',
          timestamp: 102.0,
        ),
      ];

      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: server,
      );

      expect(merged, hasLength(1));
      expect(merged.first.content, '多行测试\n第二行正文');
    });
  });

  group('TASK #67 服务端同回合 user 双投影行去重测试', () {
    // webui 上游真实形状（会话 4dea67e97b65 idx137/138）：同一时间戳两条
    // user 行——解析版带权威 id + attachments、注入原文版无 id。
    const parsedRow = ChatMessage(
      messageId: '141',
      role: 'user',
      content: '还有这个 连续四张 tools 折叠卡 为什么没有聚合成一张 tools\n\n[Attached files: C:\\Users\\Admin\\a\\Screenshot.jpg]',
      timestamp: 1788605380.6545517,
    );
    const injectedRow = ChatMessage(
      role: 'user',
      content: '[Workspace::v1: D:\\\\projects\\\\hermes-ui]\n还有这个 连续四张 tools 折叠卡 为什么没有聚合成一张 tools\n\n[Attached files: C:\\Users\\Admin\\a\\Screenshot.jpg]\n[screenshot]',
      timestamp: 1788605380.6545517,
    );

    test('1. RED 复现：server 双投影 + local 乐观消息 → 仅一条 user（权威行）', () {
      const local = [
        ChatMessage(
          messageId: 'local-y',
          role: 'user',
          content: '还有这个 连续四张 tools 折叠卡 为什么没有聚合成一张 tools',
          timestamp: 1788605380.1,
        ),
      ];
      final merged = diffMergeMessages(
        localMessages: local,
        serverMessages: const [parsedRow, injectedRow],
      );
      final users = merged.where((m) => m.role == 'user').toList();
      expect(users, hasLength(1));
      expect(users.first.messageId, '141');
      // patch 后注入标记全部剥离
      expect(users.first.content, isNot(contains('[Workspace::v1')));
      expect(users.first.content, isNot(contains('[Attached files')));
      expect(users.first.content, isNot(contains('[screenshot]')));
    });

    test('2. local 为空时 server 双投影同样收敛为一条', () {
      final merged = diffMergeMessages(
        localMessages: const [],
        serverMessages: const [parsedRow, injectedRow],
      );
      expect(merged.where((m) => m.role == 'user'), hasLength(1));
      expect(merged.first.messageId, '141');
    });

    test('3. 不误伤：同 ts 但归一化内容不同的两条 user 保持双条', () {
      const other = ChatMessage(
        messageId: '142',
        role: 'user',
        content: '完全不相干的另一条消息',
        timestamp: 1788605380.6545517,
      );
      final merged = diffMergeMessages(
        localMessages: const [],
        serverMessages: const [parsedRow, other],
      );
      expect(merged.where((m) => m.role == 'user'), hasLength(2));
    });

    test('4. 不误伤：同内容但时间差 >0.5s 的连发重复消息保持双条', () {
      const earlier = ChatMessage(
        messageId: '140',
        role: 'user',
        content: '还有这个 连续四张 tools 折叠卡 为什么没有聚合成一张 tools',
        timestamp: 1788605370.0,
      );
      final merged = diffMergeMessages(
        localMessages: const [],
        serverMessages: const [earlier, parsedRow],
      );
      expect(merged.where((m) => m.role == 'user'), hasLength(2));
    });

    test('5. 权威行在前在后均保留带 id 的那条', () {
      final merged = diffMergeMessages(
        localMessages: const [],
        serverMessages: const [injectedRow, parsedRow],
      );
      final users = merged.where((m) => m.role == 'user').toList();
      expect(users, hasLength(1));
      expect(users.first.messageId, '141');
    });
  });
}
