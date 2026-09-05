import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'cookie_store.dart';
import 'custom_header.dart';
import 'endpoints.dart';
import '../models/server_info.dart';
import '../../features/diagnostics/diagnostics_interceptor.dart';

/// 401 时的自动重登回调：返回 true 表示已用保存的凭证重登成功。
typedef AutoReauthHandler = Future<bool> Function();

/// sendDataReturningResponse 的返回类型：原始字节 + 响应头 + 状态码。
typedef ApiByteResponse = ({Uint8List data, Headers headers, int statusCode});

/// dio 封装：认证 cookie 会话 + 自定义 header 注入 + 错误归一化 + 同域判定。
///
/// 对应 Swift 的 actor APIClient（`APIClient.swift`）；请求原语为
/// [sendJson] / [sendData] / [sendDataReturningResponse]（镜像 `send` /
/// `sendData` / `sendDataReturningResponse`）。各域方法按端点表拆分在
/// `api_client_*.dart` 扩展文件中。
class ApiClient {
  ApiClient({
    required String baseUrl,
    Dio? dio,
    Dio? publicMediaDio,
    List<CustomHeader> initialHeaders = const [],
    CookieStore? cookieStore,
    this.defaultTimeout = const Duration(seconds: 60),
    this.maxRedirects = 5,
    this.autoReauth,
    this.allowAutoReauth = true,
  }) : _baseUrl = _normalizeBaseUrl(baseUrl) {
    _baseUri = Uri.parse(_baseUrl);
    final scheme = _baseUri.scheme.toLowerCase();
    if (!_baseUri.hasAuthority || (scheme != 'http' && scheme != 'https')) {
      throw InvalidServerUrlException('服务器地址无效：$baseUrl');
    }
    _headerStore = CustomHeaderStore(initialHeaders);
    // 默认共享进程级 cookie 存储：登录态跨 client 实例保留；
    // 测试可注入独立 CookieStore 隔离。
    _cookieStore = cookieStore ?? CookieStore.shared;
    _dio = dio ?? _createDio();
    _publicMediaDio = publicMediaDio ?? _createDio();
    _installInterceptors();
  }

  final String _baseUrl;
  late final Uri _baseUri;

  /// 401 自动重登处理器；null 表示不启用自动重登。
  final AutoReauthHandler? autoReauth;

  /// 当前客户端实例是否启用自动重登（默认 true）。
  final bool allowAutoReauth;

  /// 防止并发重登的互斥标记。
  bool _reauthInFlight = false;

  /// 默认请求超时（git commit-message 两个端点单独传 120s）。
  final Duration defaultTimeout;

  /// 主客户端：cookie 会话 + 自定义头（内置头恒胜）。
  late final Dio _dio;

  /// 无 cookie、无自定义头的裸客户端（仅跨域媒体下载 / 跨域重定向跳）。
  late final Dio _publicMediaDio;

  /// 自定义头内存快照（请求构建时读取，改后即时生效）。
  late final CustomHeaderStore _headerStore;

  /// Cookie 会话存储（登录成功后自动携带）。
  late final CookieStore _cookieStore;

  /// 手动重定向跟随的最大跳数（超出抛 HttpException）。
  final int maxRedirects;

  String get baseUrl => _baseUrl;

  /// 主 dio（供 SseClient / KanbanEventStreamClient 复用，继承 header/cookie 注入）。
  Dio get dio => _dio;

  CookieStore get cookieStore => _cookieStore;

  CustomHeaderStore get headerStore => _headerStore;

  /// 是否启用了自动重登。
  bool get autoReauthEnabled => allowAutoReauth;

  /// 是否有自动重登正在进行中（测试与监控用）。
  bool get isReauthInFlight => _reauthInFlight;

  static String _normalizeBaseUrl(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: defaultTimeout,
        sendTimeout: defaultTimeout,
        receiveTimeout: defaultTimeout,
        validateStatus: (_) => true,
        followRedirects: false,
        responseType: ResponseType.bytes,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 请求原语
  // -------------------------------------------------------------------------

  /// 执行请求；收到 401 且启用自动重登时，触发一次重登并重放原请求。
  /// 重登或重试仍 401 → 抛 UnauthorizedException（不递归，防死循环）。
  Future<Response<Uint8List>> _fetchWithAutoReauth(
    Future<Response<Uint8List>> Function() perform, {
    bool allowAutoReauth = true,
  }) async {
    var response = await perform();
    final reauth = autoReauth;
    if (response.statusCode == 401 &&
        this.allowAutoReauth &&
        allowAutoReauth &&
        reauth != null &&
        !_reauthInFlight) {
      _reauthInFlight = true;
      try {
        if (await reauth()) {
          response = await perform();
        }
      } finally {
        _reauthInFlight = false;
      }
    }
    return response;
  }

  /// 发送请求并返回解码后的 JSON（Map / List / 原始值；空响应体返回 null）。
  ///
  /// 非 2xx 抛 [ApiException]（401 → [UnauthorizedException]，其余 →
  /// [HttpException] 带 body 语义字段）；JSON 解析失败 → [DecodingException]。
  Future<Object?> sendJson(
    Endpoint endpoint, {
    String method = 'GET',
    Map<String, Object?>? body,
    Duration? timeout,
    String accept = 'application/json',
    bool allowAutoReauth = true,
  }) async {
    final response = await _fetchWithAutoReauth(
      () => _fetchWithRedirects(
        endpoint.url(_baseUrl),
        method: method,
        data: body == null ? null : jsonEncode(body),
        contentType: body == null ? null : 'application/json',
        timeout: timeout,
        accept: accept,
      ),
      allowAutoReauth: allowAutoReauth,
    );
    _throwUnless2xx(response);
    final text = _bodyText(response.data);
    if (text == null || text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException catch (error) {
      throw DecodingException('响应 JSON 解析失败：${error.message}');
    }
  }

  /// 发送请求并返回原始字节（rawFile / media / tts / exportSession）。
  Future<Uint8List> sendData(
    Endpoint endpoint, {
    String method = 'GET',
    Map<String, Object?>? body,
    Duration? timeout,
    String accept = 'application/json',
    bool allowAutoReauth = true,
  }) async {
    final response = await _fetchWithAutoReauth(
      () => _fetchWithRedirects(
        endpoint.url(_baseUrl),
        method: method,
        data: body == null ? null : jsonEncode(body),
        contentType: body == null ? null : 'application/json',
        timeout: timeout,
        accept: accept,
      ),
      allowAutoReauth: allowAutoReauth,
    );
    _throwUnless2xx(response);
    return response.data ?? Uint8List(0);
  }

  /// 发送请求并返回原始字节 + 响应头 + 状态码（exportSession 读
  /// `Content-Disposition` 用）。
  Future<ApiByteResponse> sendDataReturningResponse(
    Endpoint endpoint, {
    String method = 'GET',
    Map<String, Object?>? body,
    Duration? timeout,
    String accept = 'application/json',
    bool allowAutoReauth = true,
  }) async {
    final response = await _fetchWithAutoReauth(
      () => _fetchWithRedirects(
        endpoint.url(_baseUrl),
        method: method,
        data: body == null ? null : jsonEncode(body),
        contentType: body == null ? null : 'application/json',
        timeout: timeout,
        accept: accept,
      ),
      allowAutoReauth: allowAutoReauth,
    );
    _throwUnless2xx(response);
    return (
      data: response.data ?? Uint8List(0),
      headers: response.headers,
      statusCode: response.statusCode ?? -1,
    );
  }

  /// 发送请求但不做 2xx 校验（transcribe 需要非 2xx 也解 body）。
  Future<ApiByteResponse> sendUnchecked(
    Endpoint endpoint, {
    required String method,
    Object? data,
    String? contentType,
    Duration? timeout,
    String accept = 'application/json',
    bool allowAutoReauth = true,
  }) async {
    final response = await _fetchWithAutoReauth(
      () => _fetchWithRedirects(
        endpoint.url(_baseUrl),
        method: method,
        data: data,
        contentType: contentType,
        timeout: timeout,
        accept: accept,
      ),
      allowAutoReauth: allowAutoReauth,
    );
    return (
      data: response.data ?? Uint8List(0),
      headers: response.headers,
      statusCode: response.statusCode ?? -1,
    );
  }

  /// 下载任意 URL 的原始字节（外部媒体等）。
  ///
  /// 同域 → 主客户端（带自定义头 + cookie）；跨域 → 裸客户端（不带自定义头，
  /// 防泄密，对齐 `downloadData` + `remoteTranscriptMediaData`）。
  Future<Uint8List> downloadData(
    Uri url, {
    bool mapsUnauthorized = false,
    bool allowAutoReauth = true,
    void Function(int receivedBytes, int totalBytes)? onReceiveProgress,
  }) async {
    final sameOrigin = isSameOriginUri(url, _baseUri);
    final response = await _fetchWithAutoReauth(
      () => _fetchWithRedirects(
        url,
        method: 'GET',
        data: null,
        contentType: null,
        timeout: null,
        accept: '*/*',
        onReceiveProgress: onReceiveProgress,
      ),
      allowAutoReauth: allowAutoReauth && sameOrigin,
    );
    final status = response.statusCode ?? -1;
    if (mapsUnauthorized && status == 401) {
      throw const UnauthorizedException();
    }
    if (status >= 200 && status < 300) return response.data ?? Uint8List(0);
    throw HttpException.fromBody(status, _bodyText(response.data));
  }

  /// 手动重定向跟随：同域跳保留自定义头/cookie（走主 dio），跨域跳剥离
  /// 自定义头（走裸 dio），最多 [maxRedirects] 跳。
  Future<Response<Uint8List>> _fetchWithRedirects(
    Uri uri, {
    required String method,
    Object? data,
    String? contentType,
    Duration? timeout,
    required String accept,
    void Function(int receivedBytes, int totalBytes)? onReceiveProgress,
  }) async {
    var current = uri;
    var options = _buildOptions(
      current,
      method: method,
      data: data,
      contentType: contentType,
      timeout: timeout,
      accept: accept,
      onReceiveProgress: onReceiveProgress,
    );
    for (var hop = 0; ; hop++) {
      final sameOrigin = isSameOriginUri(current, _baseUri);
      final dio = sameOrigin ? _dio : _publicMediaDio;
      final Response<Uint8List> response;
      try {
        response = await dio.fetch<Uint8List>(options);
      } on DioException catch (error) {
        throw _normalizeDioException(error);
      }
      final status = response.statusCode ?? -1;
      if (!_isRedirect(status)) return response;
      if (hop >= maxRedirects) {
        throw HttpException.fromBody(status, _bodyText(response.data));
      }
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) return response;
      current = current.resolve(location);
      options = _buildOptions(
        current,
        method: method,
        data: data,
        contentType: contentType,
        timeout: timeout,
        accept: accept,
      );
    }
  }

  RequestOptions _buildOptions(
    Uri uri, {
    required String method,
    Object? data,
    String? contentType,
    Duration? timeout,
    required String accept,
    void Function(int receivedBytes, int totalBytes)? onReceiveProgress,
  }) {
    final headers = <String, dynamic>{
      'Accept': accept,
      'Cache-Control': 'no-cache',
    };
    if (contentType != null) headers['Content-Type'] = contentType;
    final resolvedTimeout = timeout ?? defaultTimeout;
    return RequestOptions(
      method: method,
      path: uri.toString(),
      headers: headers,
      data: data,
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
      followRedirects: false,
      connectTimeout: resolvedTimeout,
      sendTimeout: resolvedTimeout,
      receiveTimeout: resolvedTimeout,
      onReceiveProgress: onReceiveProgress,
    );
  }

  // -------------------------------------------------------------------------
  // 拦截器：自定义头（内置头恒胜）+ cookie 注入/落库
  // -------------------------------------------------------------------------

  void _installInterceptors() {
    _dio.interceptors.add(DiagnosticsInterceptor());
    _publicMediaDio.interceptors.add(DiagnosticsInterceptor());
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // 自定义头合并在内置头之下：已存在的键（内置头）不被覆盖。
          for (final header in _headerStore.snapshot()) {
            if (!header.isApplicable) continue;
            final name = header.sanitizedName;
            if (!_containsHeader(options.headers, name)) {
              options.headers[name] = header.sanitizedValue;
            }
          }
          final cookie = _cookieStore.cookieHeaderFor(options.uri);
          if (cookie != null && !_containsHeader(options.headers, 'Cookie')) {
            options.headers['Cookie'] = cookie;
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          final setCookies = response.headers['set-cookie'];
          if (setCookies != null && setCookies.isNotEmpty) {
            _cookieStore.setCookies(response.requestOptions.uri, setCookies);
          }
          handler.next(response);
        },
      ),
    );
  }

  bool _containsHeader(Map<String, dynamic> headers, String name) {
    final lower = name.toLowerCase();
    return headers.keys.any((key) => key.toLowerCase() == lower);
  }

  // -------------------------------------------------------------------------
  // 错误归一化（APIError.swift → ApiException）
  // -------------------------------------------------------------------------

  void _throwUnless2xx(Response<Uint8List> response) {
    final status = response.statusCode ?? -1;
    if (status == 401) {
      throw const UnauthorizedException();
    }
    if (status >= 200 && status < 300) return;
    throw HttpException.fromBody(status, _bodyText(response.data));
  }

  ApiException _normalizeDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.cancel:
        return NetworkException(NetworkExceptionKind.cancelled);
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return NetworkException(NetworkExceptionKind.timedOut);
      case DioExceptionType.badCertificate:
        return NetworkException(NetworkExceptionKind.tls);
      case DioExceptionType.connectionError:
        return NetworkException(_kindForConnectionError(error.error));
      case DioExceptionType.badResponse:
        // validateStatus 恒 true，正常不会走到；兜底按 other。
        return NetworkException(NetworkExceptionKind.other);
      case DioExceptionType.unknown:
        return NetworkException(NetworkExceptionKind.other);
    }
  }

  NetworkExceptionKind _kindForConnectionError(Object? error) {
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      final message = error.message.toLowerCase();
      if (message.contains('failed host lookup') ||
          message.contains('dns') ||
          code == 11001 ||
          code == 8) {
        return NetworkExceptionKind.cannotFindHost;
      }
      if (message.contains('network is unreachable') ||
          message.contains('no route') ||
          code == 10051 ||
          code == 101) {
        return NetworkExceptionKind.offline;
      }
      return NetworkExceptionKind.cannotConnect;
    }
    return NetworkExceptionKind.cannotConnect;
  }

  // -------------------------------------------------------------------------
  // 同域判定（scheme + host + 归一化端口全等；无端口时 http=80 / https=443）
  // -------------------------------------------------------------------------

  static bool isSameOriginUri(Uri url, Uri baseUrl) {
    if (url.scheme.toLowerCase() != baseUrl.scheme.toLowerCase()) return false;
    if (url.host.toLowerCase() != baseUrl.host.toLowerCase()) return false;
    return normalizedPort(url) == normalizedPort(baseUrl);
  }

  static int? normalizedPort(Uri uri) {
    if (uri.hasPort) return uri.port;
    switch (uri.scheme.toLowerCase()) {
      case 'http':
        return 80;
      case 'https':
        return 443;
      default:
        return null;
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static String? _bodyText(Uint8List? data) {
    if (data == null || data.isEmpty) return null;
    return utf8.decode(data, allowMalformed: true);
  }
}

// ---------------------------------------------------------------------------
// 1.1 server 域（4 个端点）
// ---------------------------------------------------------------------------

/// server 域方法（health / authStatus / login / logout）。
extension ApiClientServer on ApiClient {
  /// GET /health → HealthResponse {status, sessions, active_streams, uptime_seconds}。
  Future<HealthResponse> health() async {
    final json = await sendJson(Endpoint.health);
    return HealthResponse.fromJson(_asMap(json));
  }

  /// GET /api/auth/status → AuthStatusResponse {auth_enabled, password_auth_enabled, …}。
  Future<AuthStatusResponse> authStatus() async {
    final json = await sendJson(Endpoint.authStatus);
    return AuthStatusResponse.fromJson(_asMap(json));
  }

  /// POST /api/auth/login {password} → LoginResponse；成功即种会话 cookie。
  Future<LoginResponse> login(String password) async {
    final json = await sendJson(
      Endpoint.login,
      method: 'POST',
      body: {'password': password},
      allowAutoReauth: false,
    );
    return LoginResponse.fromJson(_asMap(json));
  }

  /// POST /api/auth/logout {} → LoginResponse。
  Future<LoginResponse> logout() async {
    final json = await sendJson(
      Endpoint.logout,
      method: 'POST',
      body: <String, Object?>{},
    );
    return LoginResponse.fromJson(_asMap(json));
  }
}

Map<String, Object?> _asMap(Object? json) => json is Map<String, Object?>
    ? json
    : (json is Map
          ? Map<String, Object?>.from(json)
          : const <String, Object?>{});
