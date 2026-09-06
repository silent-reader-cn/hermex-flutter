import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/api/custom_header.dart';
import 'package:hermes_ui/core/api/sse_client.dart';
import 'package:hermes_ui/core/models/approval.dart';
import 'package:hermes_ui/core/models/clarification.dart';
import 'package:hermes_ui/core/models/context_window_snapshot.dart';
import 'package:hermes_ui/core/models/json_value.dart';
import 'package:hermes_ui/core/models/session.dart';

void main() {
  group('SseWireParser（线上协议）', () {
    test('单事件：event + data + id + 空行结束', () {
      final parser = SseWireParser();
      final events = parser.feed(
        'event: token\ndata: {"text":"hi"}\nid: 5\n\n',
      );
      expect(events, hasLength(1));
      expect(events.single.eventType, 'token');
      expect(events.single.data, '{"text":"hi"}');
      expect(events.single.id, '5');
    });

    test('CRLF 换行兼容', () {
      final parser = SseWireParser();
      final events = parser.feed('event: token\r\ndata: {"text":"x"}\r\n\r\n');
      expect(events, hasLength(1));
      expect(events.single.data, '{"text":"x"}');
    });

    test('多行 data 以 \\n 连接', () {
      final parser = SseWireParser();
      final events = parser.feed('data: line1\ndata: line2\n\n');
      expect(events.single.data, 'line1\nline2');
    });

    test('字段值前的单个空格被去掉', () {
      final parser = SseWireParser();
      final events = parser.feed('data:  hello\n\n');
      expect(events.single.data, ' hello'); // 只去一个空格
    });

    test('data 字段不带空格也能解析', () {
      final parser = SseWireParser();
      final events = parser.feed('data:{"a":1}\n\n');
      expect(events.single.data, '{"a":1}');
    });

    test('comment 行 → heartbeat 事件', () {
      final parser = SseWireParser();
      final events = parser.feed(': ping\n\n');
      expect(events, hasLength(1));
      expect(events.single.heartbeat, isTrue);
    });

    test('未知字段行忽略，不影响后续事件', () {
      final parser = SseWireParser();
      final events = parser.feed(
        'foo: bar\nevent: token\ndata: {"text":"x"}\n\n',
      );
      expect(events, hasLength(1));
      expect(events.single.eventType, 'token');
    });

    test('空 data 且无事件名的事件不派发', () {
      final parser = SseWireParser();
      final events = parser.feed('id: 1\n\n');
      expect(events, isEmpty);
    });

    test('块跨 feed 分片传输', () {
      final parser = SseWireParser();
      expect(parser.feed('event: tok'), isEmpty);
      expect(parser.feed('en\ndata: {"te'), isEmpty);
      final events = parser.feed('xt":"x"}\n\n');
      expect(events, hasLength(1));
      expect(events.single.eventType, 'token');
      expect(events.single.data, '{"text":"x"}');
    });

    test('finish 冲刷末尾无空行的最后一块', () {
      final parser = SseWireParser();
      parser.feed('event: stream_end\ndata: {}');
      final events = parser.finish();
      expect(events, hasLength(1));
      expect(events.single.eventType, 'stream_end');
    });
  });

  group('SseEventDecoder（事件名 → Dart 事件映射，PROTOCOL_NOTES §2）', () {
    test('token', () {
      final event = SseEventDecoder.decode('token', '{"text":"你好"}');
      expect(event, isA<TokenSseEvent>());
      expect((event as TokenSseEvent).text, '你好');
    });

    test('interim_assistant', () {
      final event = SseEventDecoder.decode(
        'interim_assistant',
        '{"text":"部分","already_streamed":true}',
      );
      expect(event, isA<InterimAssistantSseEvent>());
      expect((event as InterimAssistantSseEvent).text, '部分');
      expect(event.alreadyStreamed, isTrue);
    });

    test('reasoning', () {
      final event = SseEventDecoder.decode('reasoning', '{"text":"思考中"}');
      expect(event, isA<ReasoningSseEvent>());
      expect((event as ReasoningSseEvent).text, '思考中');
    });

    test('tool → ToolStarted，含容错字段与 stableId 回退顺序及 jsonArgs 类型化', () {
      final event = SseEventDecoder.decode(
        'tool',
        '{"event_type":"tool_call","name":"bash","preview":"ls",'
            '"args":{"cmd":"ls","count":5},"duration":1.5,"is_error":false,'
            '"tool_use_id":"use-1","tid":"tid-9"}',
      );
      expect(event, isA<ToolStartedSseEvent>());
      final tool = (event as ToolStartedSseEvent).event;
      expect(tool.eventType, 'tool_call');
      expect(tool.name, 'bash');
      expect(tool.preview, 'ls');
      expect(tool.args, {'cmd': 'ls', 'count': 5});
      expect(tool.jsonArgs?['cmd'], const JsonString('ls'));
      expect(tool.jsonArgs?['count'], const JsonNumber(5.0));
      expect(tool.duration, 1.5);
      expect(tool.isError, isFalse);
      // tid 优先于 tool_use_id
      expect(tool.stableId, 'tid-9');
    });

    test('tool 无 tid/id 时依次回退 tool_call_id/tool_use_id/call_id', () {
      final event = SseEventDecoder.decode(
        'tool',
        '{"call_id":"c9","tool_call_id":"tc9"}',
      );
      final tool = (event as ToolStartedSseEvent).event;
      expect(tool.stableId, 'tc9');
    });

    test('tool_complete → ToolCompleted', () {
      final event = SseEventDecoder.decode(
        'tool_complete',
        '{"id":"x1","name":"read"}',
      );
      expect(event, isA<ToolCompletedSseEvent>());
      expect((event as ToolCompletedSseEvent).event.stableId, 'x1');
    });

    test('title', () {
      final event = SseEventDecoder.decode(
        'title',
        '{"session_id":"s1","title":"新标题"}',
      );
      expect(event, isA<TitleSseEvent>());
      expect((event as TitleSseEvent).sessionId, 's1');
      expect(event.title, '新标题');
    });

    test('metering（含 displayableTps 判定）', () {
      final event = SseEventDecoder.decode(
        'metering',
        '{"tps":12.5,"tps_available":true,"estimated":false,"session_id":"s1"}',
      );
      final metering = event as MeteringSseEvent;
      expect(metering.tps, 12.5);
      expect(metering.tpsAvailable, isTrue);
      expect(metering.estimated, isFalse);
      expect(metering.sessionId, 's1');
      expect(metering.displayableTps, 12.5);

      // estimated=true 或 tps<=0 或不可用 → 不可展示
      const hidden = MeteringSseEvent(
        tps: 3,
        tpsAvailable: true,
        estimated: true,
      );
      expect(hidden.displayableTps, isNull);
      const notAvailable = MeteringSseEvent(
        tps: 3,
        tpsAvailable: false,
        estimated: false,
      );
      expect(notAvailable.displayableTps, isNull);
      const zero = MeteringSseEvent(
        tps: 0,
        tpsAvailable: true,
        estimated: false,
      );
      expect(zero.displayableTps, isNull);
    });

    test('done 正常 → DoneSseEvent（usage/session 原样携带 + 强类型解析）', () {
      final event = SseEventDecoder.decode(
        'done',
        '{"event":{"usage":{"context_length":8000,"tps":25.5,"input_tokens":100},"session":{"session_id":"s1","title":"会话标题"}}}',
      );
      expect(event, isA<DoneSseEvent>());
      final done = (event as DoneSseEvent).event;
      expect(done.usage, {
        'context_length': 8000,
        'tps': 25.5,
        'input_tokens': 100,
      });
      expect(done.session, {'session_id': 's1', 'title': '会话标题'});
      expect(done.usageSnapshot, isA<ContextWindowSnapshot>());
      expect(done.usageSnapshot?.contextLength, 8000);
      expect(done.usageSnapshot?.tokensPerSecond, 25.5);
      expect(done.usageSnapshot?.inputTokens, 100);
      expect(done.sessionDetail, isA<SessionDetail>());
      expect(done.sessionDetail?.sessionId, 's1');
      expect(done.sessionDetail?.title, '会话标题');
    });

    test('done 畸形（非 JSON / 缺 event / event 非对象）→ TransportError', () {
      expect(
        SseEventDecoder.decode('done', 'not-json'),
        isA<TransportErrorSseEvent>(),
      );
      expect(
        SseEventDecoder.decode('done', '{"foo":1}'),
        isA<TransportErrorSseEvent>(),
      );
      expect(
        SseEventDecoder.decode('done', '{"event":"oops"}'),
        isA<TransportErrorSseEvent>(),
      );
      expect(SseEventDecoder.decode('done', ''), isA<TransportErrorSseEvent>());
    });

    test('initial 含澄清标记 → ClarificationPending，否则 ApprovalPending（含强类型字段）', () {
      final clarify = SseEventDecoder.decode(
        'initial',
        '{"pending":{"question":"哪个方案？","choices_offered":["a","b"],"clarify_id":"c1"}}',
      ) as ClarificationPendingSseEvent;
      expect(clarify.clarification, isA<ClarificationPendingResponse>());
      expect(clarify.clarification.pending?.question, '哪个方案？');
      expect(clarify.clarification.pending?.choicesOffered, ['a', 'b']);
      expect(clarify.clarification.pending?.clarifyId, 'c1');
      expect(clarify.response, clarify.clarification);

      final clarifyTopLevel = SseEventDecoder.decode(
        'initial',
        '{"question":"q"}',
      ) as ClarificationPendingSseEvent;
      expect(clarifyTopLevel.clarification.pending?.question, 'q');

      final approval = SseEventDecoder.decode(
        'initial',
        '{"pending":{"id":"p1","command":"run test","description":"跑测试"}}',
      ) as ApprovalPendingSseEvent;
      expect(approval.approval, isA<ApprovalPendingResponse>());
      expect(approval.approval.pending?.approvalId, 'p1');
      expect(approval.approval.pending?.command, 'run test');
      expect(approval.approval.pending?.description, '跑测试');
      expect(approval.response, approval.approval);
    });

    test('approval / clarify 事件强类型解析', () {
      final approval = SseEventDecoder.decode(
        'approval',
        '{"id":"a1","command":"git push"}',
      ) as ApprovalPendingSseEvent;
      expect(approval.approval, isA<ApprovalPendingResponse>());
      expect(approval.approval.pending?.approvalId, 'a1');
      expect(approval.approval.pending?.command, 'git push');

      final clarify = SseEventDecoder.decode(
        'clarify',
        '{"id":"c1","question":"继续？"}',
      ) as ClarificationPendingSseEvent;
      expect(clarify.clarification, isA<ClarificationPendingResponse>());
      expect(clarify.clarification.pending?.clarifyId, 'c1');
      expect(clarify.clarification.pending?.question, '继续？');
    });

    test('context_status 事件解析（loading / loaded / error / not_configured + label + 宽容解析）', () {
      final eLoading = SseEventDecoder.decode(
        'context_status',
        '{"prefill":{"status":"loading","label":"Loading context..."}}',
      );
      expect(eLoading, isA<ContextStatusSseEvent>());
      final csLoading = eLoading as ContextStatusSseEvent;
      expect(csLoading.status, ContextPrefillStatus.loading);
      expect(csLoading.label, 'Loading context...');
      expect(csLoading.rawStatus, 'loading');

      final eLoaded = SseEventDecoder.decode(
        'context_status',
        '{"prefill":{"status":"loaded","label":"Context ready"}}',
      ) as ContextStatusSseEvent;
      expect(eLoaded.status, ContextPrefillStatus.loaded);
      expect(eLoaded.label, 'Context ready');

      final eError = SseEventDecoder.decode(
        'context_status',
        '{"prefill":{"status":"error","label":"Context failed"}}',
      ) as ContextStatusSseEvent;
      expect(eError.status, ContextPrefillStatus.error);
      expect(eError.label, 'Context failed');

      final eNotConfigured = SseEventDecoder.decode(
        'context_status',
        '{"prefill":{"status":"not_configured"}}',
      ) as ContextStatusSseEvent;
      expect(eNotConfigured.status, ContextPrefillStatus.notConfigured);
      expect(eNotConfigured.label, isNull);

      final eTolerant = SseEventDecoder.decode(
        'context_status',
        '{"unknown_field": 123, "prefill": {"status": "custom_val", "extra": true}}',
      ) as ContextStatusSseEvent;
      expect(eTolerant.status, ContextPrefillStatus.unknown);
      expect(eTolerant.rawStatus, 'custom_val');

      final eMalformed = SseEventDecoder.decode(
        'context_status',
        'not a json',
      ) as ContextStatusSseEvent;
      expect(eMalformed.status, ContextPrefillStatus.unknown);
      expect(eMalformed.label, isNull);
    });

    test('pending_steer_leftover', () {
      final event = SseEventDecoder.decode(
        'pending_steer_leftover',
        '{"text":"剩余"}',
      );
      expect(event, isA<PendingSteerLeftoverSseEvent>());
      expect((event as PendingSteerLeftoverSseEvent).text, '剩余');
    });

    test('stream_end / cancel', () {
      expect(
        SseEventDecoder.decode('stream_end', ''),
        isA<StreamEndSseEvent>(),
      );
      expect(SseEventDecoder.decode('cancel', ''), isA<CancelledSseEvent>());
    });

    test('error / apperror：{error} 或 {message} 两种形状', () {
      final e1 = SseEventDecoder.decode('error', '{"error":"出错了"}');
      expect((e1 as ErrorSseEvent).message, '出错了');

      final e2 = SseEventDecoder.decode('apperror', '{"message":"另一种形状"}');
      expect((e2 as ErrorSseEvent).message, '另一种形状');

      final e3 = SseEventDecoder.decode('error', 'garbage');
      expect((e3 as ErrorSseEvent).message, isNotEmpty);
    });

    test('未知事件 → Ignored', () {
      expect(
        SseEventDecoder.decode('weird_event', '{}'),
        isA<IgnoredSseEvent>(),
      );
    });

    test('畸形载荷不崩流（安全默认值）', () {
      expect(
        (SseEventDecoder.decode('token', 'not-json') as TokenSseEvent).text,
        '',
      );
      expect(
        (SseEventDecoder.decode('reasoning', '[]') as ReasoningSseEvent).text,
        '',
      );
      final tool =
          SseEventDecoder.decode('tool', 'garbage') as ToolStartedSseEvent;
      expect(tool.event.eventType, isNull);
      expect(tool.event.stableId, isNull);
      expect(tool.event.jsonArgs, isNull);
      final interim = SseEventDecoder.decode(
        'interim_assistant',
        'null',
      ) as InterimAssistantSseEvent;
      expect(interim.text, '');
      expect(interim.alreadyStreamed, isFalse);
      final metering = SseEventDecoder.decode(
        'metering',
        '{"tps":"oops"}',
      ) as MeteringSseEvent;
      expect(metering.tps, isNull);

      final malformedApproval = SseEventDecoder.decode(
        'approval',
        'garbage',
      ) as ApprovalPendingSseEvent;
      expect(malformedApproval.approval.pending, isNull);

      final malformedClarify = SseEventDecoder.decode(
        'clarify',
        'not-json',
      ) as ClarificationPendingSseEvent;
      expect(malformedClarify.clarification.pending, isNull);

      const malformedDoneEvent = DoneStreamEvent(
        usage: {'context_length': 'not-int', 'tps': 'not-double'},
        session: {'message_count': 'bad-int'},
      );
      expect(malformedDoneEvent.usageSnapshot?.contextLength, isNull);
      expect(malformedDoneEvent.usageSnapshot?.tokensPerSecond, isNull);
      expect(malformedDoneEvent.sessionDetail?.messageCount, isNull);
    });
  });

  group('SseClient 传输（请求头合并顺序 + 事件派发）', () {
    test('内置头恒胜于自定义头，X-Api-Key 等透传，cookie 按 host 注入', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => ResponseBody.fromString(
          'event: token\ndata: {"text":"hi"}\n\n',
          200,
          headers: {
            'content-type': ['text/event-stream'],
          },
        ),
      );
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      dio.httpClientAdapter = adapter;

      final client = SseClient(
        dio: dio,
        baseUrl: 'http://hermes.local:8787',
        customHeaderProvider: () => const [
          CustomHeader(name: 'Accept', value: 'application/json'), // 与内置冲突
          CustomHeader(name: 'X-Api-Key', value: 'secret-key'),
        ],
        cookieProvider: (uri) =>
            uri.host == 'hermes.local' ? 'sid=abc123' : null,
      );

      final events = <SseEvent>[];
      var closed = false;
      await client.start(
        Uri.parse('http://hermes.local:8787/api/chat/stream?stream_id=st1'),
        onEvent: events.add,
        onClosed: () => closed = true,
      );

      expect(closed, isTrue);
      expect(events, hasLength(1));
      expect((events.single as TokenSseEvent).text, 'hi');

      final headers = adapter.requests.single.headers;
      expect(headers['Accept'], 'text/event-stream'); // 内置头胜出
      expect(headers['X-Api-Key'], 'secret-key'); // 自定义头透传
      expect(headers['Cache-Control'], 'no-cache, no-transform');
      expect(headers['Accept-Encoding'], 'identity');
      expect(headers['Cookie'], 'sid=abc123');
    });

    test('lastEventId 随 id: 行更新', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => ResponseBody.fromString(
          'event: events\ndata: {"cursor":1}\nid: 42\n\n',
          200,
        ),
      );
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      dio.httpClientAdapter = adapter;
      final client = SseClient(dio: dio, baseUrl: 'http://x');

      final ids = <String>[];
      await client.start(
        Uri.parse('http://x/stream'),
        onEvent: (_) {},
        onEventId: ids.add,
      );
      expect(ids, ['42']);
      expect(client.lastEventId, '42');
    });

    test('非 200 → transportError', () async {
      final adapter = _RecordingAdapter(
        responder: (_) => ResponseBody.fromString('oops', 500),
      );
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      dio.httpClientAdapter = adapter;
      final client = SseClient(dio: dio, baseUrl: 'http://x');

      final errors = <String>[];
      await client.start(
        Uri.parse('http://x/stream'),
        onEvent: (_) {},
        onTransportError: errors.add,
      );
      expect(errors, hasLength(1));
      expect(errors.single, contains('500'));
    });

    test(
      '同一 SseClient 连续两次 start，第一次请求在第二次 start 后处于 cancelled（防连接泄漏）',
      () async {
        final streamController = StreamController<Uint8List>();
        final adapter = _RecordingAdapter(
          responder: (_) => ResponseBody(
            streamController.stream,
            200,
            headers: {
              'content-type': ['text/event-stream'],
            },
          ),
        );
        final dio = Dio(BaseOptions(validateStatus: (_) => true));
        dio.httpClientAdapter = adapter;
        final client = SseClient(dio: dio, baseUrl: 'http://hermes.local:8787');

        // 第一次启动
        final firstStart = client.start(
          Uri.parse('http://hermes.local:8787/stream?id=1'),
          onEvent: (_) {},
        );
        await pumpEventQueue();

        expect(adapter.requests, hasLength(1));
        final firstCancelToken = adapter.requests[0].cancelToken;
        expect(firstCancelToken, isNotNull);
        expect(firstCancelToken!.isCancelled, isFalse);

        // 第二次启动同一 client：必须 cancel 旧 token，防止旧连接残留
        final secondStart = client.start(
          Uri.parse('http://hermes.local:8787/stream?id=2'),
          onEvent: (_) {},
        );
        await pumpEventQueue();

        expect(firstCancelToken.isCancelled, isTrue);
        expect(adapter.requests, hasLength(2));
        final secondCancelToken = adapter.requests[1].cancelToken;
        expect(secondCancelToken, isNotNull);
        expect(secondCancelToken!.isCancelled, isFalse);
        expect(client.cancelTokenForTesting, same(secondCancelToken));

        client.stop();
        expect(secondCancelToken.isCancelled, isTrue);

        await firstStart;
        await secondStart;
        await streamController.close();
      },
    );
  });
}

/// 记录请求的假 HttpClientAdapter（dio 单测标准做法）。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.responder});

  final ResponseBody Function(RequestOptions options) responder;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}
