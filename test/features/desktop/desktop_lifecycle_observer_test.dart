import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hermes_ui/app/router.dart';
import 'package:hermes_ui/core/install/webui_bootstrap.dart';
import 'package:hermes_ui/features/desktop/desktop_lifecycle_observer.dart';
import 'package:hermes_ui/features/desktop/desktop_shortcuts.dart';
import 'package:hermes_ui/features/desktop/tray_manager_service.dart';
import 'package:hermes_ui/features/desktop/window_memory.dart';
import 'package:hermes_ui/features/desktop/window_title_service.dart';
import 'package:hermes_ui/features/session_list/session_list_providers.dart';
import 'package:hermes_ui/features/webui_sidecar/webui_sidecar_providers.dart';

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

  @override
  Future<void> setEnabled(bool value) async {
    config = config.copyWith(enabled: value);
  }

  @override
  Future<void> setHost(String value) async {
    config = config.copyWith(host: value);
  }

  @override
  Future<void> setPort(int value) async {
    config = config.copyWith(port: value);
  }

  @override
  Future<void> setPassword(String value) async {
    config = config.copyWith(password: value);
  }
}

class _FakeSidecarFileSystem extends Fake implements SidecarFileSystem {
  _FakeSidecarFileSystem({this.isWindowsPlatform = true});

  final bool isWindowsPlatform;

  @override
  bool get isWindows => isWindowsPlatform;

  @override
  bool isBundleAvailable() => true;
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

class _FakeHealthChecker implements HealthChecker {
  _FakeHealthChecker({this.isHealthy = false});

  bool isHealthy;
  int callCount = 0;

  @override
  Future<bool> checkHealth(String url) async {
    callCount++;
    return isHealthy;
  }
}

class _FakeSessionListController extends SessionListController {
  int refreshCallCount = 0;
  String? appliedTimeoutError;

  @override
  Future<SessionListState> build() async => const SessionListState();

  @override
  Future<void> refresh() async {
    refreshCallCount++;
  }

  @override
  void applyGraceTimeout(String message) {
    appliedTimeoutError = message;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoRouter testRouter;

  setUp(() {
    testRouter = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const SizedBox()),
      ],
    );
  });

  tearDown(() {
    testRouter.dispose();
  });

  group('DesktopLifecycleObserver Sidecar 启动链测试', () {
    testWidgets('enabled=true: _initDesktopServices 启动 sidecar', (
      tester,
    ) async {
      final fakeStorage = _FakeSidecarConfigStorage(
        initialConfig: const SidecarConfig(enabled: true),
      );
      final fakeSidecar = _FakeSidecarService();
      final fakeFs = _FakeSidecarFileSystem(isWindowsPlatform: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            routerProvider.overrideWithValue(testRouter),
            windowTitleServiceProvider.overrideWithValue(
              WindowTitleService(isDesktop: false),
            ),
            trayManagerServiceProvider.overrideWithValue(
              TrayManagerService(isDesktop: false),
            ),
            windowMemoryServiceProvider.overrideWithValue(
              WindowMemoryService(isDesktop: false),
            ),
            desktopShortcutsServiceProvider.overrideWithValue(
              DesktopShortcutsService(isDesktop: false),
            ),
            webuiSidecarConfigStorageProvider.overrideWithValue(fakeStorage),
            webuiSidecarServiceProvider.overrideWithValue(fakeSidecar),
            sidecarFileSystemProvider.overrideWithValue(fakeFs),
          ],
          child: const DesktopLifecycleObserver(
            isDesktop: true,
            child: SizedBox(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeSidecar.startCallCount, 1);
    });

    testWidgets('enabled=false: _initDesktopServices 不拉起 sidecar', (
      tester,
    ) async {
      final fakeStorage = _FakeSidecarConfigStorage(
        initialConfig: const SidecarConfig(enabled: false),
      );
      final fakeSidecar = _FakeSidecarService();
      final fakeFs = _FakeSidecarFileSystem(isWindowsPlatform: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            routerProvider.overrideWithValue(testRouter),
            windowTitleServiceProvider.overrideWithValue(
              WindowTitleService(isDesktop: false),
            ),
            trayManagerServiceProvider.overrideWithValue(
              TrayManagerService(isDesktop: false),
            ),
            windowMemoryServiceProvider.overrideWithValue(
              WindowMemoryService(isDesktop: false),
            ),
            desktopShortcutsServiceProvider.overrideWithValue(
              DesktopShortcutsService(isDesktop: false),
            ),
            webuiSidecarConfigStorageProvider.overrideWithValue(fakeStorage),
            webuiSidecarServiceProvider.overrideWithValue(fakeSidecar),
            sidecarFileSystemProvider.overrideWithValue(fakeFs),
          ],
          child: const DesktopLifecycleObserver(
            isDesktop: true,
            child: SizedBox(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeSidecar.startCallCount, 0);
    });

    testWidgets('非桌面平台: 安全 no-op，不拉起 sidecar', (tester) async {
      final fakeStorage = _FakeSidecarConfigStorage(
        initialConfig: const SidecarConfig(enabled: true),
      );
      final fakeSidecar = _FakeSidecarService();
      final fakeFs = _FakeSidecarFileSystem(isWindowsPlatform: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            routerProvider.overrideWithValue(testRouter),
            windowTitleServiceProvider.overrideWithValue(
              WindowTitleService(isDesktop: false),
            ),
            trayManagerServiceProvider.overrideWithValue(
              TrayManagerService(isDesktop: false),
            ),
            windowMemoryServiceProvider.overrideWithValue(
              WindowMemoryService(isDesktop: false),
            ),
            desktopShortcutsServiceProvider.overrideWithValue(
              DesktopShortcutsService(isDesktop: false),
            ),
            webuiSidecarConfigStorageProvider.overrideWithValue(fakeStorage),
            webuiSidecarServiceProvider.overrideWithValue(fakeSidecar),
            sidecarFileSystemProvider.overrideWithValue(fakeFs),
          ],
          child: const DesktopLifecycleObserver(
            isDesktop: false,
            child: SizedBox(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeSidecar.startCallCount, 0);
    });

    testWidgets('运行期 Sidecar 配置 false->true 跳变时自动触发 start', (tester) async {
      final fakeStorage = _FakeSidecarConfigStorage(
        initialConfig: const SidecarConfig(enabled: false),
      );
      final fakeSidecar = _FakeSidecarService();
      final fakeFs = _FakeSidecarFileSystem(isWindowsPlatform: true);

      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            routerProvider.overrideWithValue(testRouter),
            windowTitleServiceProvider.overrideWithValue(
              WindowTitleService(isDesktop: false),
            ),
            trayManagerServiceProvider.overrideWithValue(
              TrayManagerService(isDesktop: false),
            ),
            windowMemoryServiceProvider.overrideWithValue(
              WindowMemoryService(isDesktop: false),
            ),
            desktopShortcutsServiceProvider.overrideWithValue(
              DesktopShortcutsService(isDesktop: false),
            ),
            webuiSidecarConfigStorageProvider.overrideWithValue(fakeStorage),
            webuiSidecarServiceProvider.overrideWithValue(fakeSidecar),
            sidecarFileSystemProvider.overrideWithValue(fakeFs),
          ],
          child: DesktopLifecycleObserver(
            isDesktop: true,
            child: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(fakeSidecar.startCallCount, 0);

      // 用户在设置页启用了 sidecar
      await capturedRef
          .read(webuiSidecarConfigProvider.notifier)
          .setEnabled(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeSidecar.startCallCount, 1);
    });
  });

  group('DesktopLifecycleObserver 冷启动静默宽限状态机 (TASK #72)', () {
    test('startGrace 进入 active 宽限态并暂存错误信息', () {
      final fakeSessionList = _FakeSessionListController();
      final container = ProviderContainer(
        overrides: [
          sessionListControllerProvider.overrideWith(() => fakeSessionList),
          sidecarHealthCheckerProvider.overrideWithValue(
            _FakeHealthChecker(isHealthy: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        coldStartGraceControllerProvider.notifier,
      );
      controller.startGrace(pendingActionError: '离线缓存：当前显示最近缓存的会话');

      final state = container.read(coldStartGraceControllerProvider);
      expect(state.phase, ColdStartGracePhase.active);
      expect(state.pendingActionError, '离线缓存：当前显示最近缓存的会话');
      expect(state.isActive, isTrue);
    });

    test('cancelGrace 取消宽限并恢复 idle 态', () {
      final fakeSessionList = _FakeSessionListController();
      final container = ProviderContainer(
        overrides: [
          sessionListControllerProvider.overrideWith(() => fakeSessionList),
          sidecarHealthCheckerProvider.overrideWithValue(
            _FakeHealthChecker(isHealthy: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        coldStartGraceControllerProvider.notifier,
      );
      controller.startGrace(pendingActionError: '离线缓存：当前显示最近缓存的会话');
      expect(container.read(coldStartGraceControllerProvider).isActive, isTrue);

      controller.cancelGrace();
      final state = container.read(coldStartGraceControllerProvider);
      expect(state.phase, ColdStartGracePhase.idle);
      expect(state.pendingActionError, isNull);
    });

    test('Sidecar 转为 running 态时联动将宽限转为 resolved 态并触发 refresh', () async {
      final fakeSidecar = _FakeSidecarService(
        initialState: const SidecarState(status: SidecarStatus.starting),
      );
      final fakeSessionList = _FakeSessionListController();
      final container = ProviderContainer(
        overrides: [
          sessionListControllerProvider.overrideWith(() => fakeSessionList),
          webuiSidecarServiceProvider.overrideWithValue(fakeSidecar),
          sidecarHealthCheckerProvider.overrideWithValue(
            _FakeHealthChecker(isHealthy: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        coldStartGraceControllerProvider.notifier,
      );
      controller.startGrace(pendingActionError: '离线缓存：当前显示最近缓存的会话');
      expect(container.read(coldStartGraceControllerProvider).isActive, isTrue);

      fakeSidecar.emitState(const SidecarState(status: SidecarStatus.running));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.resolved,
      );
      expect(fakeSessionList.refreshCallCount, 1);
    });

    test('Sidecar 转为 failed 态时联动将宽限转为 expired 态并补发错误', () async {
      final fakeSidecar = _FakeSidecarService(
        initialState: const SidecarState(status: SidecarStatus.starting),
      );
      final fakeSessionList = _FakeSessionListController();
      final container = ProviderContainer(
        overrides: [
          sessionListControllerProvider.overrideWith(() => fakeSessionList),
          webuiSidecarServiceProvider.overrideWithValue(fakeSidecar),
          sidecarHealthCheckerProvider.overrideWithValue(
            _FakeHealthChecker(isHealthy: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(
        coldStartGraceControllerProvider.notifier,
      );
      controller.startGrace(pendingActionError: '离线缓存：当前显示最近缓存的会话');
      expect(container.read(coldStartGraceControllerProvider).isActive, isTrue);

      fakeSidecar.emitState(
        const SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.startFailed,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        container.read(coldStartGraceControllerProvider).phase,
        ColdStartGracePhase.expired,
      );
      expect(fakeSessionList.appliedTimeoutError, '离线缓存：当前显示最近缓存的会话');
    });

    test('宽限超时未就绪转为 expired 态并补发错误', () {
      fakeAsync((async) {
        final fakeSessionList = _FakeSessionListController();
        final container = ProviderContainer(
          overrides: [
            sessionListControllerProvider.overrideWith(() => fakeSessionList),
            sidecarHealthCheckerProvider.overrideWithValue(
              _FakeHealthChecker(isHealthy: false),
            ),
            coldStartGraceTimeoutProvider.overrideWithValue(
              const Duration(seconds: 4),
            ),
            coldStartGraceIntervalProvider.overrideWithValue(
              const Duration(milliseconds: 500),
            ),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(
          coldStartGraceControllerProvider.notifier,
        );
        controller.startGrace(pendingActionError: '离线缓存：当前显示最近缓存的会话');
        expect(
          container.read(coldStartGraceControllerProvider).isActive,
          isTrue,
        );

        // 前进 3.5 秒尚未超时
        async.elapse(const Duration(milliseconds: 3500));
        expect(
          container.read(coldStartGraceControllerProvider).isActive,
          isTrue,
        );

        // 前进至 4 秒超时
        async.elapse(const Duration(milliseconds: 600));
        expect(
          container.read(coldStartGraceControllerProvider).phase,
          ColdStartGracePhase.expired,
        );
        expect(fakeSessionList.appliedTimeoutError, '离线缓存：当前显示最近缓存的会话');
      });
    });
  });
}
