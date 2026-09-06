import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/api/api_client.dart';
import 'package:hermes_ui/core/api/api_exception.dart';
import 'package:hermes_ui/core/cache/cache_providers.dart';
import 'package:hermes_ui/core/connections/connection_providers.dart';
import 'package:hermes_ui/core/connections/server_connection.dart';
import 'package:hermes_ui/core/install/webui_bootstrap.dart';
import 'package:hermes_ui/core/models/session.dart';
import 'package:hermes_ui/features/desktop/desktop_lifecycle_observer.dart';
import 'package:hermes_ui/features/projects/project_providers.dart';
import 'package:hermes_ui/features/session_list/session_list_providers.dart';
import 'package:hermes_ui/features/webui_sidecar/webui_sidecar_providers.dart';

import '../../helpers/fake_session_list_api.dart';

class _FakeHealthChecker implements HealthChecker {
  _FakeHealthChecker({this.isHealthy = false, this.healthyAfterAttempts = 0});

  bool isHealthy;
  int healthyAfterAttempts;
  int callCount = 0;
  final List<String> checkedUrls = [];

  @override
  Future<bool> checkHealth(String url) async {
    callCount++;
    checkedUrls.add(url);
    if (healthyAfterAttempts > 0 && callCount >= healthyAfterAttempts) {
      return true;
    }
    return isHealthy;
  }
}

class _FakeSidecarConfigStorage extends Fake
    implements WebuiSidecarConfigStorage {
  _FakeSidecarConfigStorage({
    SidecarConfig initialConfig = const SidecarConfig(),
  }) : config = initialConfig;

  SidecarConfig config;

  @override
  Future<SidecarConfig> load() async => config;

  @override
  Future<void> save(SidecarConfig newConfig) async {
    config = newConfig;
  }
}

class _FakeSidecarService implements WebuiSidecarService {
  _FakeSidecarService({SidecarState initialState = SidecarState.initial})
    : _state = initialState;

  SidecarState _state;
  final StreamController<SidecarState> _controller =
      StreamController<SidecarState>.broadcast();

  int startCallCount = 0;
  int stopCallCount = 0;

  @override
  SidecarState get currentState => _state;

  @override
  Stream<SidecarState> get states => _controller.stream;

  @override
  Future<void> start() async {
    startCallCount++;
    emitState(_state.copyWith(status: SidecarStatus.running));
  }

  @override
  Future<void> stop() async {
    stopCallCount++;
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  void emitState(SidecarState newState) {
    _state = newState;
    _controller.add(newState);
  }

  void dispose() {
    unawaited(_controller.close());
  }
}

class _StubProjectApi implements ProjectApi {
  @override
  Future<ProjectsResponse> fetchProjects() async =>
      const ProjectsResponse(projects: []);

  @override
  Future<ProjectMutationResponse> createProject({
    required String name,
    String? color,
  }) async => const ProjectMutationResponse(ok: true);

  @override
  Future<ProjectMutationResponse> renameProject({
    required String projectId,
    required String name,
    String? color,
  }) async => const ProjectMutationResponse(ok: true);

  @override
  Future<ProjectMutationResponse> deleteProject(String projectId) async =>
      const ProjectMutationResponse(ok: true);
}

class _StubActiveConnection extends ActiveConnectionController {
  _StubActiveConnection(this._connection);

  final ServerConnection? _connection;

  @override
  ServerConnection? build() => _connection;
}

SessionSummary _buildSession(String id, String title) {
  return SessionSummary(
    sessionId: id,
    title: title,
    lastMessageAt: DateTime.now().millisecondsSinceEpoch / 1000,
  );
}

ServerConnection _builtinConn() {
  return ServerConnection(
    id: ServerConnection.builtinId,
    name: 'Built-in WebUI',
    baseUrl: 'http://127.0.0.1:8787',
    kind: ConnectionKind.builtin,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

ServerConnection _remoteConn() {
  return ServerConnection(
    id: 'remote-1',
    name: 'Remote Server',
    baseUrl: 'https://hermes.remote:30002',
    kind: ConnectionKind.remote,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

ProviderContainer _makeContainer({
  required FakeSessionListApi api,
  ServerConnection? active,
  HealthChecker? healthChecker,
  WebuiSidecarService? sidecarService,
  Duration? graceTimeout,
  Duration? graceInterval,
}) {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(baseUrl: active?.baseUrl ?? 'http://127.0.0.1:8787'),
      ),
      sessionListApiFactoryProvider.overrideWithValue((_) => api),
      projectApiFactoryProvider.overrideWithValue((_) => _StubProjectApi()),
      activeConnectionProvider.overrideWith(
        () => _StubActiveConnection(active),
      ),
      if (healthChecker != null)
        sidecarHealthCheckerProvider.overrideWithValue(healthChecker),
      if (sidecarService != null)
        webuiSidecarServiceProvider.overrideWithValue(sidecarService),
      webuiSidecarConfigStorageProvider.overrideWithValue(
        _FakeSidecarConfigStorage(),
      ),
      if (graceTimeout != null)
        coldStartGraceTimeoutProvider.overrideWithValue(graceTimeout),
      if (graceInterval != null)
        coldStartGraceIntervalProvider.overrideWithValue(graceInterval),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionListController 冷启动静默宽限 (TASK #72)', () {
    test(
      '内置连接 + 冷启动 + 网络失败 + 存在缓存 → 进入 active 宽限，actionError 为 null',
      () async {
        final cachedSession = _buildSession('c1', '缓存会话 1');
        final api = FakeSessionListApi(
          sessions: [_buildSession('s1', '在线会话 1')],
        );
        api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);

        final container = _makeContainer(
          api: api,
          active: _builtinConn(),
          healthChecker: _FakeHealthChecker(isHealthy: false),
        );

        // 先预置离线缓存
        await container.read(cacheServiceProvider).writeSessions([
          cachedSession,
        ]);

        // 触发冷启动加载
        await container.read(sessionListControllerProvider.future);
        final state = container
            .read(sessionListControllerProvider)
            .valueOrNull!;

        // 验证：显示离线缓存且无 actionError 弹窗
        expect(state.sessions, hasLength(1));
        expect(state.sessions.first.sessionId, 'c1');
        expect(state.actionError, isNull);

        // 验证宽限状态机处于 active 态
        final graceState = container.read(coldStartGraceControllerProvider);
        expect(graceState.phase, ColdStartGracePhase.active);
        expect(graceState.pendingActionError, '离线缓存：当前显示最近缓存的会话');
      },
    );

    test(
      '宽限期内轮询 health 成功 → 状态变为 resolved，自动触发刷新，显示在线会话且 actionError 仍为 null',
      () async {
        final cachedSession = _buildSession('c1', '缓存会话 1');
        final liveSession = _buildSession('s1', '在线会话 1');
        final api = FakeSessionListApi(sessions: [liveSession]);
        // 首次 fetchSessions 失败（模拟冷启动阶段 sidecar 未就绪），第二次成功
        api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);
        api.fetchErrorCap = 1;

        // 模拟第 2 次探测时健康检查返回成功
        final healthChecker = _FakeHealthChecker(healthyAfterAttempts: 2);

        final container = _makeContainer(
          api: api,
          active: _builtinConn(),
          healthChecker: healthChecker,
          graceInterval: const Duration(milliseconds: 50),
        );

        await container.read(cacheServiceProvider).writeSessions([
          cachedSession,
        ]);
        await container.read(sessionListControllerProvider.future);

        expect(
          container.read(coldStartGraceControllerProvider).phase,
          ColdStartGracePhase.active,
        );

        // 等待轮询探测成功触发刷新
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final state = container
            .read(sessionListControllerProvider)
            .valueOrNull!;
        expect(
          container.read(coldStartGraceControllerProvider).phase,
          ColdStartGracePhase.resolved,
        );
        expect(api.fetchCount, 2);
        expect(state.sessions, hasLength(1));
        expect(state.sessions.first.sessionId, 's1');
        expect(state.actionError, isNull);
      },
    );

    test('宽限期内 Sidecar 转为 running 态 → 状态变为 resolved，自动触发刷新', () async {
      final cachedSession = _buildSession('c1', '缓存会话 1');
      final liveSession = _buildSession('s1', '在线会话 1');
      final api = FakeSessionListApi(sessions: [liveSession]);
      api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);
      api.fetchErrorCap = 1;

      final sidecarService = _FakeSidecarService(
        initialState: const SidecarState(status: SidecarStatus.starting),
      );

      final container = _makeContainer(
        api: api,
        active: _builtinConn(),
        healthChecker: _FakeHealthChecker(isHealthy: false),
        sidecarService: sidecarService,
      );

      await container.read(cacheServiceProvider).writeSessions([cachedSession]);
      await container.read(sessionListControllerProvider.future);

      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.active,
      );

      // Sidecar 进程完成启动，发出 running 状态
      sidecarService.emitState(
        const SidecarState(status: SidecarStatus.running),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.resolved,
      );
      expect(api.fetchCount, 2);

      final state = container.read(sessionListControllerProvider).valueOrNull!;
      expect(state.sessions.first.sessionId, 's1');
      expect(state.actionError, isNull);
    });

    test('宽限超时仍失败 → 状态变为 expired，补落 actionError「离线缓存：当前显示最近缓存的会话」（不吞真错误）', () {
      fakeAsync((async) {
        final cachedSession = _buildSession('c1', '缓存会话 1');
        final api = FakeSessionListApi(sessions: [_buildSession('s1', '在线')]);
        api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);

        final container = _makeContainer(
          api: api,
          active: _builtinConn(),
          healthChecker: _FakeHealthChecker(isHealthy: false),
          graceTimeout: const Duration(seconds: 4),
          graceInterval: const Duration(milliseconds: 500),
        );

        unawaited(
          container.read(cacheServiceProvider).writeSessions([cachedSession]),
        );
        async.flushMicrotasks();

        unawaited(container.read(sessionListControllerProvider.future));
        async.flushMicrotasks();

        // 此时处于宽限活跃中，尚未补落 actionError
        var state = container.read(sessionListControllerProvider).valueOrNull!;
        expect(state.actionError, isNull);
        expect(
          container.read(coldStartGraceControllerProvider).phase,
          ColdStartGracePhase.active,
        );

        // 前进 3.5 秒（尚未超时）
        async.elapse(const Duration(milliseconds: 3500));
        state = container.read(sessionListControllerProvider).valueOrNull!;
        expect(state.actionError, isNull);
        expect(
          container.read(coldStartGraceControllerProvider).phase,
          ColdStartGracePhase.active,
        );

        // 前进至 4 秒超时
        async.elapse(const Duration(milliseconds: 600));

        expect(
          container.read(coldStartGraceControllerProvider).phase,
          ColdStartGracePhase.expired,
        );
        state = container.read(sessionListControllerProvider).valueOrNull!;
        expect(state.actionError, '离线缓存：当前显示最近缓存的会话');
        expect(state.consecutiveFailures, 1);
      });
    });

    test('宽限期内 Sidecar 转为 failed 态 → 立即转为 expired 并补落 actionError', () async {
      final cachedSession = _buildSession('c1', '缓存会话 1');
      final api = FakeSessionListApi(sessions: [_buildSession('s1', '在线')]);
      api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);

      final sidecarService = _FakeSidecarService(
        initialState: const SidecarState(status: SidecarStatus.starting),
      );

      final container = _makeContainer(
        api: api,
        active: _builtinConn(),
        healthChecker: _FakeHealthChecker(isHealthy: false),
        sidecarService: sidecarService,
      );

      await container.read(cacheServiceProvider).writeSessions([cachedSession]);
      await container.read(sessionListControllerProvider.future);

      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.active,
      );

      // Sidecar 报错退出
      sidecarService.emitState(
        const SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.missingBundle,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.expired,
      );
      final state = container.read(sessionListControllerProvider).valueOrNull!;
      expect(state.actionError, '离线缓存：当前显示最近缓存的会话');
    });

    test('非内置连接（远程连接）冷启动网络失败 → 不享受宽限，直接产生 actionError', () async {
      final cachedSession = _buildSession('c1', '缓存会话 1');
      final api = FakeSessionListApi(sessions: [_buildSession('s1', '在线')]);
      api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);

      final container = _makeContainer(
        api: api,
        active: _remoteConn(), // 远程连接
        healthChecker: _FakeHealthChecker(isHealthy: false),
      );

      await container.read(cacheServiceProvider).writeSessions([cachedSession]);
      await container.read(sessionListControllerProvider.future);

      final state = container.read(sessionListControllerProvider).valueOrNull!;
      // 非内置连接直接落 actionError
      expect(state.actionError, '离线缓存：当前显示最近缓存的会话');
      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.idle,
      );
    });

    test('手动刷新（refresh）不享受宽限 → 网络失败即使是内置连接也直接落 actionError', () async {
      final cachedSession = _buildSession('c1', '缓存会话 1');
      final api = FakeSessionListApi(sessions: [_buildSession('s1', '在线')]);

      final container = _makeContainer(
        api: api,
        active: _builtinConn(),
        healthChecker: _FakeHealthChecker(isHealthy: false),
      );

      await container.read(cacheServiceProvider).writeSessions([cachedSession]);
      // 初始加载成功
      await container.read(sessionListControllerProvider.future);
      var state = container.read(sessionListControllerProvider).valueOrNull!;
      expect(state.actionError, isNull);

      // 后续手动刷新时网络断开
      api.fetchError = NetworkException(NetworkExceptionKind.cannotConnect);
      await container.read(sessionListControllerProvider.notifier).refresh();

      state = container.read(sessionListControllerProvider).valueOrNull!;
      // 手动刷新直接产生 actionError，不进入宽限
      expect(state.actionError, '离线缓存：当前显示最近缓存的会话');
      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.idle,
      );
    });

    test('非网络类错误（如 500 服务器错误）不享受宽限 → 直接抛出错误转为 AsyncError', () async {
      final cachedSession = _buildSession('c1', '缓存会话 1');
      final api = FakeSessionListApi(sessions: [_buildSession('s1', '在线')]);
      api.fetchError = HttpException(500, 'Internal Server Error');

      final container = _makeContainer(
        api: api,
        active: _builtinConn(),
        healthChecker: _FakeHealthChecker(isHealthy: false),
      );

      await container.read(cacheServiceProvider).writeSessions([cachedSession]);

      await expectLater(
        container.read(sessionListControllerProvider.future),
        throwsA(isA<ApiException>()),
      );

      expect(container.read(sessionListControllerProvider).hasError, isTrue);
      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.idle,
      );
    });
  });
}
