import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../models/approval.dart';
import '../models/clarification.dart';
import '../models/context_window_snapshot.dart';
import '../models/json_value.dart';
import '../models/session.dart';
import '../../features/diagnostics/diagnostics_models.dart';
import '../../features/diagnostics/diagnostics_service.dart';
import 'custom_header.dart';

// ---------------------------------------------------------------------------
// SSE 线上协议解析（SseWireParser）
// ---------------------------------------------------------------------------

/// SSE 线上解析出的单条原始事件（未解码，字段为线上原始值）。
class SseWireEvent {
  const SseWireEvent({
    this.eventType = 'message',
    this.data = '',
    this.id,
    this.heartbeat = false,
  });

  final String eventType;
  final String data;
  final String? id;

  /// true 表示该「事件」实际是一行 `:comment`（心跳），无 data。
  final bool heartbeat;
}

/// SSE 线上协议解析器（逐行，LF / CRLF 兼容，对齐 LDSwiftEventSource）。
///
/// - `event:` / `data:` / `id:` / `retry:` 字段；`data:` 多行以 `\n` 连接。
/// - `:comment` 行 → 心跳事件（[SseWireEvent.heartbeat]）。
/// - 未知字段名行忽略；空 data 且无事件名的普通 message 不派发。
/// - 流末尾无空行时调用 [finish] 冲刷最后一块。
class SseWireParser {
  final StringBuffer _buffer = StringBuffer();
  String _eventType = '';
  final List<String> _dataLines = [];
  String? _id;
  bool _sawComment = false;

  /// 喂入一段文本，返回本段内完整的事件（可能为空）。
  List<SseWireEvent> feed(String chunk) {
    _buffer.write(chunk);
    final events = <SseWireEvent>[];
    final text = _buffer.toString();
    var i = 0;
    while (i < text.length) {
      final nl = text.indexOf('\n', i);
      if (nl == -1) break; // 行不完整，留到下一块
      final rawLine = text.substring(i, nl);
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      i = nl + 1;
      if (line.isEmpty) {
        final event = _dispatch();
        if (event != null) events.add(event);
      } else {
        _processLine(line);
      }
    }
    _buffer.clear();
    if (i < text.length) _buffer.write(text.substring(i));
    return events;
  }

  /// 冲刷剩余缓冲（服务端可能不发送末尾空行）。
  List<SseWireEvent> finish() {
    final events = <SseWireEvent>[];
    final text = _buffer.toString();
    _buffer.clear();
    if (text.isNotEmpty) {
      for (final rawLine in text.split('\n')) {
        final line = rawLine.endsWith('\r')
            ? rawLine.substring(0, rawLine.length - 1)
            : rawLine;
        if (line.isEmpty) {
          final event = _dispatch();
          if (event != null) events.add(event);
        } else {
          _processLine(line);
        }
      }
      final event = _dispatch();
      if (event != null) events.add(event);
    }
    return events;
  }

  void _processLine(String line) {
    if (line.startsWith(':')) {
      _sawComment = true;
      return;
    }
    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    final rawValue = colon == -1 ? '' : line.substring(colon + 1);
    // 按规范：字段值前的一个空格要去掉。
    final value = rawValue.startsWith(' ') ? rawValue.substring(1) : rawValue;
    switch (field) {
      case 'event':
        _eventType = value;
      case 'data':
        _dataLines.add(value);
      case 'id':
        _id = value;
      case 'retry':
        break; // 忽略重连间隔
      default:
        break; // 未知字段忽略
    }
  }

  SseWireEvent? _dispatch() {
    final data = _dataLines.join('\n');
    final eventType = _eventType.isEmpty ? 'message' : _eventType;
    final id = _id;
    final commentOnly =
        _sawComment && data.isEmpty && _eventType.isEmpty && id == null;
    _reset();
    if (commentOnly) return const SseWireEvent(heartbeat: true);
    // 按 SSE 规范：data 为空且无事件名（仅 id/retry 等）的事件不派发。
    if (data.isEmpty && eventType == 'message') return null;
    return SseWireEvent(eventType: eventType, data: data, id: id);
  }

  void _reset() {
    _eventType = '';
    _dataLines.clear();
    _id = null;
    _sawComment = false;
  }
}

// ---------------------------------------------------------------------------
// 事件类型（PROTOCOL_NOTES.md §2 映射表）
// ---------------------------------------------------------------------------

/// SSE 解码后的事件（sealed，feature 层按类型分发）。
sealed class SseEvent {
  const SseEvent();
}

/// `token` → `{text}`。
class TokenSseEvent extends SseEvent {
  const TokenSseEvent(this.text);

  final String text;
}

/// `interim_assistant` → `{text, already_streamed}`。
class InterimAssistantSseEvent extends SseEvent {
  const InterimAssistantSseEvent({
    required this.text,
    required this.alreadyStreamed,
  });

  final String text;
  final bool alreadyStreamed;
}

/// `reasoning` → `{text}`。
class ReasoningSseEvent extends SseEvent {
  const ReasoningSseEvent(this.text);

  final String text;
}

/// `tool` → ToolStreamEvent。
class ToolStartedSseEvent extends SseEvent {
  const ToolStartedSseEvent(this.event);

  final ToolStreamEvent event;
}

/// `tool_complete` → ToolStreamEvent。
class ToolCompletedSseEvent extends SseEvent {
  const ToolCompletedSseEvent(this.event);

  final ToolStreamEvent event;
}

/// `title` → `{session_id, title}`。
class TitleSseEvent extends SseEvent {
  const TitleSseEvent({this.sessionId, this.title});

  final String? sessionId;
  final String? title;
}

/// `metering` → `{tps, tps_available, estimated, session_id}`。
class MeteringSseEvent extends SseEvent {
  const MeteringSseEvent({
    this.tps,
    required this.tpsAvailable,
    required this.estimated,
    this.sessionId,
  });

  final double? tps;
  final bool tpsAvailable;
  final bool estimated;
  final String? sessionId;

  /// 可展示 tps：`tps_available==true && estimated!=true && tps>0 且有限`。
  double? get displayableTps {
    if (tpsAvailable != true || estimated == true) return null;
    final value = tps;
    if (value == null || !value.isFinite || value <= 0) return null;
    return value;
  }
}

/// `done` → DonePayload.event（缺失/畸形 → TransportErrorSseEvent）。
class DoneSseEvent extends SseEvent {
  const DoneSseEvent(this.event);

  final DoneStreamEvent event;
}

/// `approval` / `initial`（无澄清标记时）。
class ApprovalPendingSseEvent extends SseEvent {
  const ApprovalPendingSseEvent(
    this.payload, {
    ApprovalPendingResponse? explicitApproval,
  }) : _approval = explicitApproval;

  /// 兼容原始 Map 载荷。
  final Map<String, Object?> payload;
  final ApprovalPendingResponse? _approval;

  /// 强类型审批响应（对齐 Swift `streamPayload` 容错解码）。
  ApprovalPendingResponse get approval =>
      _approval ?? ApprovalPendingResponse.streamPayload(payload);

  /// 别名：保持与 response 命名兼容。
  ApprovalPendingResponse get response => approval;
}

/// `clarify` / `initial`（含澄清标记时）。
class ClarificationPendingSseEvent extends SseEvent {
  const ClarificationPendingSseEvent(
    this.payload, {
    ClarificationPendingResponse? explicitClarification,
  }) : _clarification = explicitClarification;

  /// 兼容原始 Map 载荷。
  final Map<String, Object?> payload;
  final ClarificationPendingResponse? _clarification;

  /// 强类型澄清响应（对齐 Swift `streamPayload` 容错解码）。
  ClarificationPendingResponse get clarification =>
      _clarification ?? ClarificationPendingResponse.streamPayload(payload);

  /// 别名：保持与 response 命名兼容。
  ClarificationPendingResponse get response => clarification;
}

/// `pending_steer_leftover` → `{text}`。
class PendingSteerLeftoverSseEvent extends SseEvent {
  const PendingSteerLeftoverSseEvent(this.text);

  final String text;
}

/// `stream_end`。
class StreamEndSseEvent extends SseEvent {
  const StreamEndSseEvent();
}

/// `cancel`。
class CancelledSseEvent extends SseEvent {
  const CancelledSseEvent();
}

/// `error` / `apperror` → `{error}` 或 `{message}`。
class ErrorSseEvent extends SseEvent {
  const ErrorSseEvent(this.message);

  final String message;
}

/// 传输层错误（连接失败 / done 畸形 / 流中断）。
class TransportErrorSseEvent extends SseEvent {
  const TransportErrorSseEvent(this.message);

  final String message;
}

/// `:comment` 心跳。
class HeartbeatSseEvent extends SseEvent {
  const HeartbeatSseEvent();
}

/// 上下文 prefill 状态枚举。
enum ContextPrefillStatus {
  notConfigured,
  loading,
  loaded,
  error,
  unknown;

  static ContextPrefillStatus fromString(String? raw) {
    return switch (raw?.toLowerCase().trim()) {
      'not_configured' => ContextPrefillStatus.notConfigured,
      'loading' => ContextPrefillStatus.loading,
      'loaded' => ContextPrefillStatus.loaded,
      'error' => ContextPrefillStatus.error,
      _ => ContextPrefillStatus.unknown,
    };
  }
}

/// `context_status` 事件（prefill.status: not_configured/loading/loaded/error + label）。
class ContextStatusSseEvent extends SseEvent {
  const ContextStatusSseEvent({
    this.status = ContextPrefillStatus.unknown,
    this.label,
    this.rawStatus,
    this.payload = const {},
  });

  final ContextPrefillStatus status;
  final String? label;
  final String? rawStatus;
  final Map<String, Object?> payload;

  factory ContextStatusSseEvent.fromJson(Map<String, Object?> map) {
    final prefill = _asMap(map['prefill']);
    final rawStatus = _string(prefill['status']) ?? _string(map['status']);
    final label = _string(prefill['label']) ?? _string(map['label']);
    return ContextStatusSseEvent(
      status: ContextPrefillStatus.fromString(rawStatus),
      label: label,
      rawStatus: rawStatus,
      payload: map,
    );
  }
}

/// 未知事件类型（静默丢弃）。
class IgnoredSseEvent extends SseEvent {
  const IgnoredSseEvent();
}

// ---------------------------------------------------------------------------
// 载荷结构（PROTOCOL_NOTES.md §3/§4）
// ---------------------------------------------------------------------------

/// `tool` / `tool_complete` 共用载荷；全部字段可空，逐个容错。
class ToolStreamEvent {
  const ToolStreamEvent({
    this.eventType,
    this.name,
    this.preview,
    this.args,
    Map<String, JsonValue>? explicitJsonArgs,
    this.duration,
    this.isError,
    this.stableId,
  }) : _jsonArgs = explicitJsonArgs;

  final String? eventType;
  final String? name;
  final String? preview;
  final Map<String, Object?>? args;
  final Map<String, JsonValue>? _jsonArgs;
  final double? duration;
  final bool? isError;

  /// stable_id ← 依次取 `tid` / `id` / `tool_call_id` / `tool_use_id` / `call_id`
  /// 的第一个非空（trim 后）。
  final String? stableId;

  /// 类型化参数（`Map<String, JsonValue>`，对齐 ToolCall.args）。
  Map<String, JsonValue>? get jsonArgs =>
      _jsonArgs ??
      (args != null && args!.isNotEmpty
          ? args!.map((k, v) => MapEntry(k, JsonValue.fromJson(v)))
          : null);

  factory ToolStreamEvent.fromJson(Object? json) {
    final map = _asMap(json);
    String? stable;
    for (final key in const [
      'tid',
      'id',
      'tool_call_id',
      'tool_use_id',
      'call_id',
    ]) {
      final value = map[key];
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.isNotEmpty) {
          stable = trimmed;
          break;
        }
      }
    }
    final rawArgs = map['args'];
    final parsedArgs = rawArgs is Map<String, Object?>
        ? Map<String, Object?>.from(rawArgs)
        : (rawArgs is Map ? Map<String, Object?>.from(rawArgs) : null);
    final jsonArgs = parsedArgs != null && parsedArgs.isNotEmpty
        ? parsedArgs.map((k, v) => MapEntry(k, JsonValue.fromJson(v)))
        : null;
    return ToolStreamEvent(
      eventType: _string(map['event_type']),
      name: _string(map['name']),
      preview: _string(map['preview']),
      args: parsedArgs,
      explicitJsonArgs: jsonArgs,
      duration: _double(map['duration']),
      isError: _bool(map['is_error']),
      stableId: stable,
    );
  }
}

/// `interim_assistant` 载荷。
class InterimAssistantStreamEvent {
  const InterimAssistantStreamEvent({this.text, this.alreadyStreamed});

  final String? text;
  final bool? alreadyStreamed;
}

/// `title` 载荷。
class TitleStreamEvent {
  const TitleStreamEvent({this.sessionId, this.title});

  final String? sessionId;
  final String? title;
}

/// `metering` 载荷。
class MeteringStreamEvent {
  const MeteringStreamEvent({
    this.tokensPerSecond,
    this.isTokensPerSecondAvailable,
    this.isEstimated,
    this.sessionId,
  });

  factory MeteringStreamEvent.fromJson(Map<String, Object?> json) {
    return MeteringStreamEvent(
      tokensPerSecond: _double(json['tps']),
      isTokensPerSecondAvailable: _bool(json['tps_available']),
      isEstimated: _bool(json['estimated']),
      sessionId: _string(json['session_id']),
    );
  }

  final double? tokensPerSecond;
  final bool? isTokensPerSecondAvailable;
  final bool? isEstimated;
  final String? sessionId;
}

/// `done` 事件载荷（DonePayload.event）。
class DoneStreamEvent {
  const DoneStreamEvent({
    this.usage,
    this.session,
    ContextWindowSnapshot? explicitUsageSnapshot,
    SessionDetail? explicitSessionDetail,
  }) : _usageSnapshot = explicitUsageSnapshot,
       _sessionDetail = explicitSessionDetail;

  /// 兼容原始 Map 字段。
  final Map<String, Object?>? usage;

  /// 兼容原始 Map 字段。
  final Map<String, Object?>? session;

  final ContextWindowSnapshot? _usageSnapshot;
  final SessionDetail? _sessionDetail;

  /// 强类型用量快照（ContextWindowSnapshot）。
  ContextWindowSnapshot? get usageSnapshot =>
      _usageSnapshot ??
      (usage != null ? ContextWindowSnapshot.fromJson(usage!) : null);

  /// 强类型会话详情（SessionDetail）。
  SessionDetail? get sessionDetail =>
      _sessionDetail ??
      (session != null ? SessionDetail.fromJson(session!) : null);
}

// ---------------------------------------------------------------------------
// 事件解码器（PROTOCOL_NOTES.md §2/§5：畸形载荷不崩流，done 畸形 → transportError）
// ---------------------------------------------------------------------------

/// 事件名 + data JSON → [SseEvent]。
class SseEventDecoder {
  const SseEventDecoder._();

  static SseEvent decode(String eventType, String data) {
    switch (eventType) {
      case 'token':
        return TokenSseEvent(_textOf(data));
      case 'interim_assistant':
        final map = _jsonMap(data);
        return InterimAssistantSseEvent(
          text: _string(map['text']) ?? '',
          alreadyStreamed: _bool(map['already_streamed']) ?? false,
        );
      case 'reasoning':
        return ReasoningSseEvent(_textOf(data));
      case 'tool':
        return ToolStartedSseEvent(ToolStreamEvent.fromJson(_jsonOrNull(data)));
      case 'tool_complete':
        return ToolCompletedSseEvent(
          ToolStreamEvent.fromJson(_jsonOrNull(data)),
        );
      case 'title':
        final map = _jsonMap(data);
        return TitleSseEvent(
          sessionId: _string(map['session_id']),
          title: _string(map['title']),
        );
      case 'metering':
        final map = _jsonMap(data);
        return MeteringSseEvent(
          tps: _double(map['tps']),
          tpsAvailable: _bool(map['tps_available']) ?? false,
          estimated: _bool(map['estimated']) ?? false,
          sessionId: _string(map['session_id']),
        );
      case 'done':
        return _decodeDone(data);
      case 'initial':
        final map = _jsonMap(data);
        if (_containsClarificationMarkers(map)) {
          return ClarificationPendingSseEvent(map);
        }
        return ApprovalPendingSseEvent(map);
      case 'approval':
        return ApprovalPendingSseEvent(_jsonMap(data));
      case 'clarify':
        return ClarificationPendingSseEvent(_jsonMap(data));
      case 'pending_steer_leftover':
        return PendingSteerLeftoverSseEvent(_textOf(data));
      case 'stream_end':
        return const StreamEndSseEvent();
      case 'cancel':
        return const CancelledSseEvent();
      case 'context_status':
        return ContextStatusSseEvent.fromJson(_jsonMap(data));
      case 'error':
      case 'apperror':
        final map = _jsonMap(data);
        final message = _string(map['error']) ?? _string(map['message']);
        return ErrorSseEvent(message ?? '流返回了一个错误。');
      default:
        return const IgnoredSseEvent();
    }
  }

  static SseEvent _decodeDone(String data) {
    final json = _jsonOrNull(data);
    final map = _asMap(json);
    if (map.isEmpty) {
      return const TransportErrorSseEvent('连接异常：完成事件格式异常');
    }
    // 兼容两种形态：
    // 1) 旧契约/测试：{"event": {"session":..., "usage":...}}
    // 2) 真实服务端（gateway_chat.py / streaming.py）：{"session":..., "usage":...} 平铺
    // Swift DonePayload 同样从平铺的 usage/session 构造 event。
    Map<String, Object?>? event;
    final rawEvent = map['event'];
    if (rawEvent is Map<String, Object?>) {
      event = Map<String, Object?>.from(rawEvent);
    } else if (rawEvent is Map) {
      event = Map<String, Object?>.from(rawEvent);
    } else if (map.containsKey('session') || map.containsKey('usage')) {
      event = map;
    } else {
      return const TransportErrorSseEvent('连接异常：完成事件格式异常');
    }
    final rawUsage = event['usage'];
    final rawSession = event['session'];
    final usageMap = rawUsage is Map<String, Object?>
        ? Map<String, Object?>.from(rawUsage)
        : (rawUsage is Map ? Map<String, Object?>.from(rawUsage) : null);
    final sessionMap = rawSession is Map<String, Object?>
        ? Map<String, Object?>.from(rawSession)
        : (rawSession is Map ? Map<String, Object?>.from(rawSession) : null);
    final usageSnapshot = usageMap != null
        ? ContextWindowSnapshot.fromJson(usageMap)
        : null;
    final sessionDetail = sessionMap != null
        ? SessionDetail.fromJson(sessionMap)
        : null;
    return DoneSseEvent(
      DoneStreamEvent(
        usage: usageMap,
        session: sessionMap,
        explicitUsageSnapshot: usageSnapshot,
        explicitSessionDetail: sessionDetail,
      ),
    );
  }

  /// 澄清标记：`pending`（或顶层）含 `question` / `choices_offered` /
  /// `choicesOffered` 之一（Clarification.swift containsClarificationMarkers）。
  static bool _containsClarificationMarkers(Map<String, Object?> map) {
    final rawPending = map['pending'];
    final candidate = rawPending is Map<String, Object?>
        ? Map<String, Object?>.from(rawPending)
        : map;
    return candidate.containsKey('question') ||
        candidate.containsKey('choices_offered') ||
        candidate.containsKey('choicesOffered');
  }
}

// ---------------------------------------------------------------------------
// 传输层（dio ResponseType.stream + 共享 header/cookie 合并顺序）
// ---------------------------------------------------------------------------

/// 底层 SSE 传输（供 [SseClient] / KanbanEventStreamClient 共用）。
///
/// 请求头合并顺序（PROTOCOL_NOTES.md §1）：内置三头
/// `Accept: text/event-stream`、`Cache-Control: no-cache, no-transform`、
/// `Accept-Encoding: identity` 先占位，自定义头合并在其**之下**（碰撞时内置头
/// 胜出）。Cookie 由 [cookieProvider] 按目标 host 提供。
Future<void> connectSse({
  required Dio dio,
  required Uri url,
  required List<CustomHeader> Function() customHeaderProvider,
  String? Function(Uri uri)? cookieProvider,
  required void Function(SseWireEvent event) onEvent,
  required void Function(String message) onTransportError,
  required void Function() onClosed,
  CancelToken? cancelToken,
  Duration connectTimeout = const Duration(seconds: 60),
}) async {
  final headers = <String, dynamic>{
    'Accept': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    'Accept-Encoding': 'identity',
  };
  for (final header in customHeaderProvider()) {
    if (!header.isApplicable) continue;
    final name = header.sanitizedName;
    final lower = name.toLowerCase();
    if (!headers.keys.any((k) => k.toLowerCase() == lower)) {
      headers[name] = header.sanitizedValue;
    }
  }
  final cookie = cookieProvider?.call(url);
  if (cookie != null &&
      cookie.isNotEmpty &&
      !headers.keys.any((k) => k.toLowerCase() == 'cookie')) {
    headers['Cookie'] = cookie;
  }

  final options = RequestOptions(
    method: 'GET',
    path: url.toString(),
    headers: headers,
    responseType: ResponseType.stream,
    validateStatus: (_) => true,
    followRedirects: true,
    receiveTimeout: const Duration(days: 1),
    sendTimeout: connectTimeout,
    connectTimeout: connectTimeout,
    cancelToken: cancelToken,
  );

  final Response<ResponseBody> response;
  try {
    response = await dio.fetch<ResponseBody>(options);
  } on DioException catch (error) {
    if (error.type == DioExceptionType.cancel) return; // 主动取消：静默返回
    onTransportError(_transportErrorMessage(error));
    return;
  }
  if (response.statusCode != 200) {
    onTransportError('SSE 连接失败：HTTP ${response.statusCode}');
    return;
  }
  final body = response.data;
  if (body == null) {
    onTransportError('SSE 响应体为空。');
    return;
  }

  final parser = SseWireParser();
  try {
    await for (final chunk in body.stream) {
      final text = utf8.decode(chunk, allowMalformed: true);
      for (final wire in parser.feed(text)) {
        onEvent(wire);
      }
    }
  } on DioException catch (error) {
    if (error.type == DioExceptionType.cancel) return;
    onTransportError(_transportErrorMessage(error));
    return;
  } catch (error) {
    onTransportError('SSE 流读取失败：$error');
    return;
  }
  for (final wire in parser.finish()) {
    onEvent(wire);
  }
  onClosed();
}

String _transportErrorMessage(DioException error) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'SSE 连接超时。';
    case DioExceptionType.badCertificate:
      return 'SSE HTTPS 证书校验失败。';
    default:
      return 'SSE 连接失败：${error.message}';
  }
}

/// SSE 客户端：连接 + 事件名→事件映射 + lastEventId 跟踪。
///
/// 连接错误直接结束（不做重连，由上层决定，对齐 SSEClient.swift）。
class SseClient {
  SseClient({
    required this.dio,
    required this.baseUrl,
    List<CustomHeader> Function()? customHeaderProvider,
    this.cookieProvider,
  }) : _customHeaderProvider = customHeaderProvider ?? (() => const []);

  /// 传输用 dio；传入 [ApiClient.dio] 时自动继承其自定义头/cookie 拦截器。
  final Dio dio;

  /// 服务器 base URL（构造流 URL 用）。
  final String baseUrl;

  final List<CustomHeader> Function() _customHeaderProvider;

  /// 按目标 URL 提供 Cookie 头（null 表示无 cookie）；传 [ApiClient.dio] 时
  /// 可省略（拦截器已处理）。
  final String? Function(Uri uri)? cookieProvider;
  CancelToken? _cancelToken;

  /// 最近一次收到的 `id:` 事件 ID（重连续传用）。
  String? _lastEventId;
  String? get lastEventId => _lastEventId;

  /// 连接 [url] 并持续派发解码后的事件；流自然结束或出错后返回。
  Future<void> start(
    Uri url, {
    required void Function(SseEvent event) onEvent,
    void Function(String eventId)? onEventId,
    void Function(String message)? onTransportError,
    void Function()? onClosed,
  }) async {
    _cancelToken?.cancel();
    _cancelToken = CancelToken();
    await connectSse(
      dio: dio,
      url: url,
      customHeaderProvider: _customHeaderProvider,
      cookieProvider: cookieProvider,
      cancelToken: _cancelToken,
      onEvent: (wire) {
        if (wire.heartbeat) {
          const hb = HeartbeatSseEvent();
          _logSseEvent(hb);
          onEvent(hb);
          return;
        }
        if (wire.id != null && wire.id!.isNotEmpty) {
          _lastEventId = wire.id;
          onEventId?.call(wire.id!);
        }
        final event = SseEventDecoder.decode(wire.eventType, wire.data);
        _logSseEvent(event);
        onEvent(event);
      },
      onTransportError: (message) {
        DiagnosticsService.instance.log(
          level: DiagnosticsLogLevel.error,
          tag: 'sse',
          message: 'SSE transport error: $message',
          errorKind: 'TransportError',
        );
        onTransportError?.call(message);
      },
      onClosed: onClosed ?? () {},
    );
  }

  void stop() => _cancelToken?.cancel();

  /// 供单测断言当前使用的 [CancelToken]（覆盖前 cancel 证据）。
  @visibleForTesting
  CancelToken? get cancelTokenForTesting => _cancelToken;
}

void _logSseEvent(SseEvent event) {
  final service = DiagnosticsService.instance;
  if (!service.enabled) return;
  switch (event) {
    case TokenSseEvent(:final text):
      service.log(
        level: DiagnosticsLogLevel.verbose,
        tag: 'sse',
        message: 'token: "${truncateText(text, 100)}"',
      );
    case ReasoningSseEvent(:final text):
      service.log(
        level: DiagnosticsLogLevel.debug,
        tag: 'sse',
        message: 'reasoning: "${truncateText(text, 100)}"',
      );
    case ToolStartedSseEvent(:final event):
      service.log(
        level: DiagnosticsLogLevel.info,
        tag: 'sse',
        message:
            'tool start: ${event.name ?? 'unknown'} (${event.stableId ?? ''})',
        details: {
          'name': event.name,
          'stableId': event.stableId,
          if (event.preview != null) 'preview': event.preview,
        },
      );
    case ToolCompletedSseEvent(:final event):
      service.log(
        level: DiagnosticsLogLevel.info,
        tag: 'sse',
        message:
            'tool complete: ${event.name ?? 'unknown'} (${event.stableId ?? ''}) duration=${event.duration ?? 0}s',
        details: {
          'name': event.name,
          'stableId': event.stableId,
          if (event.duration != null) 'duration': event.duration,
          if (event.isError != null) 'isError': event.isError,
        },
      );
    case HeartbeatSseEvent():
      service.log(
        level: DiagnosticsLogLevel.verbose,
        tag: 'sse',
        message: 'heartbeat (:comment)',
      );
    case DoneSseEvent():
      service.log(level: DiagnosticsLogLevel.info, tag: 'sse', message: 'done');
    case TitleSseEvent(:final title, :final sessionId):
      service.log(
        level: DiagnosticsLogLevel.info,
        tag: 'sse',
        message: 'title: "$title" (session: $sessionId)',
      );
    case MeteringSseEvent(:final tps, :final sessionId):
      service.log(
        level: DiagnosticsLogLevel.debug,
        tag: 'sse',
        message: 'metering: tps=$tps (session: $sessionId)',
      );
    case ContextStatusSseEvent(:final status, :final rawStatus, :final label):
      service.log(
        level: status == ContextPrefillStatus.error
            ? DiagnosticsLogLevel.error
            : DiagnosticsLogLevel.debug,
        tag: 'sse',
        message:
            'context_status: ${rawStatus ?? status.name}'
            '${label != null ? ' (label: $label)' : ''}',
      );
    case ApprovalPendingSseEvent():
      service.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'sse',
        message: 'approval pending',
      );
    case ClarificationPendingSseEvent():
      service.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'sse',
        message: 'clarification pending',
      );
    case PendingSteerLeftoverSseEvent(:final text):
      service.log(
        level: DiagnosticsLogLevel.info,
        tag: 'sse',
        message: 'pending_steer_leftover: "${truncateText(text, 100)}"',
      );
    case StreamEndSseEvent():
      service.log(
        level: DiagnosticsLogLevel.info,
        tag: 'sse',
        message: 'stream_end',
      );
    case CancelledSseEvent():
      service.log(
        level: DiagnosticsLogLevel.warn,
        tag: 'sse',
        message: 'cancel',
      );
    case ErrorSseEvent(:final message):
      service.log(
        level: DiagnosticsLogLevel.error,
        tag: 'sse',
        message: 'error: $message',
        errorKind: 'ErrorSseEvent',
      );
    case TransportErrorSseEvent(:final message):
      service.log(
        level: DiagnosticsLogLevel.error,
        tag: 'sse',
        message: 'transportError: $message',
        errorKind: 'TransportError',
      );
    case InterimAssistantSseEvent(:final text, :final alreadyStreamed):
      service.log(
        level: DiagnosticsLogLevel.debug,
        tag: 'sse',
        message:
            'interim_assistant: alreadyStreamed=$alreadyStreamed "${truncateText(text, 100)}"',
      );
    case IgnoredSseEvent():
      service.log(
        level: DiagnosticsLogLevel.verbose,
        tag: 'sse',
        message: 'ignored event',
      );
  }
}

// ---------------------------------------------------------------------------
// 容错 JSON 读取辅助（字段缺失/类型不符 → 安全默认值，绝不 crash）
// ---------------------------------------------------------------------------

Map<String, Object?> _jsonMap(String data) {
  final json = _jsonOrNull(data);
  return _asMap(json);
}

Object? _jsonOrNull(String data) {
  if (data.isEmpty) return null;
  try {
    return jsonDecode(data);
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _asMap(Object? json) {
  if (json is Map<String, Object?>) return json;
  if (json is Map) return Map<String, Object?>.from(json);
  return const {};
}

String _textOf(String data) {
  final map = _jsonMap(data);
  return _string(map['text']) ?? '';
}

String? _string(Object? value) => value is String ? value : null;

double? _double(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  return null;
}

bool? _bool(Object? value) => value is bool ? value : null;
