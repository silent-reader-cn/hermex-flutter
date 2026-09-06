import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_ui/core/install/install_detector.dart';
import 'package:hermes_ui/core/install/webui_bootstrap.dart';
import 'package:hermes_ui/features/webui_sidecar/webui_sidecar_service.dart';

class _FakeProcess implements Process {
  _FakeProcess({this.pid = 9999});

  @override
  final int pid;

  final Completer<int> _exitCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderrController =
      StreamController<List<int>>.broadcast();

  bool killed = false;

  void emitStdout(String text) {
    _stdoutController.add(utf8.encode(text));
  }

  void emitStderr(String text) {
    _stderrController.add(utf8.encode(text));
  }

  void completeExit(int code) {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(code);
    }
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;
}

class _FakeProcessExecutor implements ProcessExecutor {
  _FakeProcessExecutor({_FakeProcess? defaultProcess})
    : processToReturn = defaultProcess ?? _FakeProcess();

  _FakeProcess processToReturn;
  final List<List<String>> runCalls = [];
  final List<Map<String, dynamic>> startCalls = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    runCalls.add([executable, ...arguments]);
    return ProcessResult(1001, 0, '', '');
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    startCalls.add({
      'executable': executable,
      'arguments': arguments,
      'workingDirectory': workingDirectory,
      'environment': environment,
    });
    return processToReturn;
  }
}

class _FakePortProber implements PortProber {
  bool isOpen = false;
  final List<Map<String, dynamic>> probeCalls = [];

  @override
  Future<bool> isPortOpen(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    probeCalls.add({'host': host, 'port': port, 'timeout': timeout});
    return isOpen;
  }
}

class _FakeHealthChecker implements HealthChecker {
  _FakeHealthChecker({this.alwaysReturn = true});

  bool alwaysReturn;
  int healthyAfterAttempts = 1;
  int checkCalls = 0;
  final List<String> checkedUrls = [];

  @override
  Future<bool> checkHealth(String url) async {
    checkCalls++;
    checkedUrls.add(url);
    if (!alwaysReturn) return false;
    return checkCalls >= healthyAfterAttempts;
  }
}

class _FakeSidecarFileSystem implements SidecarFileSystem {
  _FakeSidecarFileSystem();

  @override
  bool isWindows = true;

  bool bundleAvailable = true;
  String root = r'C:\app\webui';
  String agentDir = r'C:\Users\Admin\AppData\Local\hermes\hermes-agent';

  final List<String> logLines = [];
  int rotateCalls = 0;

  bool Function(String path)? fileExistsOverride;

  @override
  String? get envSidecarRoot => null;

  @override
  String get defaultSidecarDir => root;

  String get hermesAgentDir => agentDir;

  @override
  String get logDirectoryPath =>
      r'C:\Users\Admin\AppData\Local\hermes\webui-bundled\logs';

  @override
  String get logFilePath =>
      r'C:\Users\Admin\AppData\Local\hermes\webui-bundled\logs\webui.log';

  @override
  bool directoryExists(String path) => true;

  @override
  bool fileExists(String path) {
    if (fileExistsOverride != null) {
      return fileExistsOverride!(path);
    }
    return true;
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) async {}

  @override
  Future<void> appendLogLine(String path, String line) async {
    logLines.add(line);
  }

  @override
  Future<void> rotateLogIfNeeded(
    String path, {
    int maxSizeBytes = 5 * 1024 * 1024,
  }) async {
    rotateCalls++;
  }

  @override
  String resolveBundleDir() => root;

  @override
  bool isBundleAvailable() => isWindows && bundleAvailable;
}

void main() {
  group('WebuiSidecarService 核心行为', () {
    late _FakeProcess fakeProcess;
    late _FakeProcessExecutor fakeExecutor;
    late _FakePortProber fakeProber;
    late _FakeHealthChecker fakeHealth;
    late _FakeSidecarFileSystem fakeFs;
    late SidecarConfig currentConfig;

    setUp(() {
      fakeProcess = _FakeProcess(pid: 7788);
      fakeExecutor = _FakeProcessExecutor(defaultProcess: fakeProcess);
      fakeProber = _FakePortProber();
      fakeHealth = _FakeHealthChecker(alwaysReturn: true);
      fakeFs = _FakeSidecarFileSystem();
      currentConfig = const SidecarConfig(
        enabled: true,
        host: '127.0.0.1',
        port: 8787,
        password: 'my_secret_token_xyz',
      );
    });

    DefaultWebuiSidecarService createService({
      Duration healthTimeout = const Duration(seconds: 30),
      Duration healthInterval = const Duration(milliseconds: 10),
      Duration takeoverInterval = const Duration(milliseconds: 20),
      Duration stopGracePeriod = const Duration(milliseconds: 50),
      BackoffCalculator? backoffCalculator,
      String? customAgentDir,
    }) {
      return DefaultWebuiSidecarService(
        getConfig: () => currentConfig,
        processExecutor: fakeExecutor,
        fileSystem: fakeFs,
        healthChecker: fakeHealth,
        portProber: fakeProber,
        healthTimeout: healthTimeout,
        healthInterval: healthInterval,
        takeoverInterval: takeoverInterval,
        stopGracePeriod: stopGracePeriod,
        backoffCalculator: backoffCalculator ?? (_) => Duration.zero,
        customAgentDir: customAgentDir,
      );
    }

    test('start 成功路径：空闲端口 -> 拉起子进程 -> 轮询 health 成功 -> running(pid)', () async {
      final service = createService();
      final states = <SidecarState>[];
      final sub = service.states.listen(states.add);

      await service.start();

      expect(service.currentState.status, SidecarStatus.running);
      expect(service.currentState.pid, 7788);
      expect(service.currentState.reason, SidecarFailureReason.none);

      expect(fakeExecutor.startCalls.length, 1);
      final call = fakeExecutor.startCalls.first;
      expect(call['executable'], contains('python.exe'));
      expect((call['arguments'] as List)[0], contains('server.py'));
      expect(call['workingDirectory'], fakeFs.root);

      final env = call['environment'] as Map<String, String>;
      expect(env['HERMES_WEBUI_HOST'], '127.0.0.1');
      expect(env['HERMES_WEBUI_PORT'], '8787');
      expect(env['HERMES_WEBUI_PASSWORD'], 'my_secret_token_xyz');
      expect(env['PYTHONDONTWRITEBYTECODE'], '1');
      expect(env['HERMES_WEBUI_AGENT_DIR'], fakeFs.agentDir);
      expect(env.containsKey('HERMES_HOME'), isFalse);

      expect(fakeHealth.checkCalls, greaterThanOrEqualTo(1));
      expect(fakeHealth.checkedUrls.first, 'http://127.0.0.1:8787/health');

      await Future<void>.delayed(Duration.zero);
      expect(states.any((s) => s.status == SidecarStatus.starting), isTrue);
      expect(states.last.status, SidecarStatus.running);

      await sub.cancel();
      await service.stop();
    });

    test('start 幂等性：已 running 时直接返回且不重复启动', () async {
      final service = createService();
      await service.start();
      expect(fakeExecutor.startCalls.length, 1);

      await service.start();
      expect(fakeExecutor.startCalls.length, 1);

      await service.stop();
    });

    test('内置包缺失：置 failed(missingBundle) 且不拉起进程', () async {
      fakeFs.bundleAvailable = false;
      final service = createService();

      await service.start();

      expect(service.currentState.status, SidecarStatus.failed);
      expect(service.currentState.reason, SidecarFailureReason.missingBundle);
      expect(fakeExecutor.startCalls, isEmpty);
    });

    test('端口被陌生服务占用：Socket 能通但 /health 失败 -> failed(portOccupied)', () async {
      fakeProber.isOpen = true;
      fakeHealth.alwaysReturn = false;
      final service = createService();

      await service.start();

      expect(service.currentState.status, SidecarStatus.failed);
      expect(service.currentState.reason, SidecarFailureReason.portOccupied);
      expect(fakeExecutor.startCalls, isEmpty);
    });

    test(
      '接管模式：端口能通且 /health 为 ok -> running、无 PID、接管 watchdog 仅轮 health',
      () async {
        fakeProber.isOpen = true;
        fakeHealth.alwaysReturn = true;
        final service = createService();

        await service.start();

        expect(service.currentState.status, SidecarStatus.running);
        expect(service.currentState.pid, isNull);
        expect(service.currentState.detail, contains('Takeover'));
        expect(fakeExecutor.startCalls, isEmpty);

        await service.stop();
        expect(service.currentState.status, SidecarStatus.stopped);
      },
    );

    test('host 为 0.0.0.0 时健康检查与 socket 探测使用 127.0.0.1', () async {
      currentConfig = const SidecarConfig(
        enabled: true,
        host: '0.0.0.0',
        port: 8787,
        password: 'pass',
      );
      final service = createService();

      await service.start();

      expect(fakeHealth.checkedUrls.first, 'http://127.0.0.1:8787/health');

      await service.stop();
    });

    test('健康确认超时：30s 内未通过 -> failed(healthTimeout) 并杀进程树', () async {
      fakeHealth.alwaysReturn = false;
      final service = createService(
        healthTimeout: const Duration(milliseconds: 30),
        healthInterval: const Duration(milliseconds: 5),
      );

      await service.start();

      expect(service.currentState.status, SidecarStatus.failed);
      expect(service.currentState.reason, SidecarFailureReason.healthTimeout);
      expect(fakeProcess.killed, isTrue);
    });

    test('stop 温和杀死：3s 内未退执行 taskkill /T /F /PID 兜底清树', () async {
      final service = createService(
        stopGracePeriod: const Duration(milliseconds: 20),
      );

      await service.start();
      expect(service.currentState.status, SidecarStatus.running);

      await service.stop();

      expect(fakeProcess.killed, isTrue);
      expect(
        fakeExecutor.runCalls.any(
          (call) =>
              call[0] == 'taskkill' &&
              call.contains('/PID') &&
              call.contains('7788'),
        ),
        isTrue,
      );
      expect(service.currentState.status, SidecarStatus.stopped);
    });

    test('stop 温和杀死：若子进程正常退出则不调用 taskkill', () async {
      final service = createService(
        stopGracePeriod: const Duration(seconds: 1),
      );

      await service.start();
      fakeProcess.completeExit(0);

      await service.stop();

      expect(
        fakeExecutor.runCalls.any((call) => call[0] == 'taskkill'),
        isFalse,
      );
      expect(service.currentState.status, SidecarStatus.stopped);
    });

    test('watchdog 进程崩溃重启与退避上限：连续失败 5 次后停止自愈并标记 failed(startFailed)', () async {
      var attemptCount = 0;
      fakeHealth.alwaysReturn = true;

      final service = createService(
        healthTimeout: const Duration(milliseconds: 15),
        healthInterval: const Duration(milliseconds: 2),
        backoffCalculator: (attempt) {
          attemptCount++;
          return Duration.zero;
        },
      );

      await service.start();
      expect(service.currentState.status, SidecarStatus.running);

      fakeHealth.alwaysReturn = false;
      fakeProcess.completeExit(1);

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(attemptCount, greaterThanOrEqualTo(4));
      expect(service.currentState.status, SidecarStatus.failed);
      expect(service.currentState.reason, SidecarFailureReason.startFailed);

      await service.stop();
    });

    test('日志 tee：进程 stdout/stderr 中的密码被严格替换为 ***', () async {
      final service = createService();
      await service.start();

      fakeProcess.emitStdout(
        'Server starting with password: my_secret_token_xyz\n',
      );
      fakeProcess.emitStderr(
        'Failed auth for password my_secret_token_xyz from 1.2.3.4\n',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeFs.logLines.isNotEmpty, isTrue);
      for (final line in fakeFs.logLines) {
        expect(line, isNot(contains('my_secret_token_xyz')));
        expect(line, contains('***'));
      }

      await service.stop();
    });

    test('非 Windows 平台直接置 failed(startFailed) 且不拉起进程', () async {
      fakeFs.isWindows = false;
      final service = createService();

      await service.start();

      expect(service.currentState.status, SidecarStatus.failed);
      expect(service.currentState.reason, SidecarFailureReason.startFailed);
      expect(
        service.currentState.detail,
        contains('only supported on Windows'),
      );
      expect(fakeExecutor.startCalls, isEmpty);
    });
  });

  group('WebUI Sidecar Python 解释器选择与 Agent 环境变量注入 (TASK #71 方案 B′)', () {
    late _FakeProcess fakeProcess;
    late _FakeProcessExecutor fakeExecutor;
    late _FakePortProber fakeProber;
    late _FakeHealthChecker fakeHealth;
    late _FakeSidecarFileSystem fakeFs;
    late SidecarConfig currentConfig;

    setUp(() {
      fakeProcess = _FakeProcess(pid: 7788);
      fakeExecutor = _FakeProcessExecutor(defaultProcess: fakeProcess);
      fakeProber = _FakePortProber();
      fakeHealth = _FakeHealthChecker(alwaysReturn: true);
      fakeFs = _FakeSidecarFileSystem();
      currentConfig = const SidecarConfig(
        enabled: true,
        host: '127.0.0.1',
        port: 8787,
        password: 'my_secret_token_xyz',
      );
    });

    DefaultWebuiSidecarService createService({
      Duration healthTimeout = const Duration(seconds: 30),
      Duration healthInterval = const Duration(milliseconds: 10),
      Duration takeoverInterval = const Duration(milliseconds: 20),
      Duration stopGracePeriod = const Duration(milliseconds: 50),
      BackoffCalculator? backoffCalculator,
      String? customAgentDir,
    }) {
      return DefaultWebuiSidecarService(
        getConfig: () => currentConfig,
        processExecutor: fakeExecutor,
        fileSystem: fakeFs,
        healthChecker: fakeHealth,
        portProber: fakeProber,
        healthTimeout: healthTimeout,
        healthInterval: healthInterval,
        takeoverInterval: takeoverInterval,
        stopGracePeriod: stopGracePeriod,
        backoffCalculator: backoffCalculator ?? (_) => Duration.zero,
        customAgentDir: customAgentDir,
      );
    }

    test(
      '解释器探测分支 1：agent venv 命中 -> 优先使用 venv 解释器并注入 HERMES_WEBUI_AGENT_DIR',
      () async {
        final expectedVenvPy = '${fakeFs.agentDir}\\venv\\Scripts\\python.exe';
        fakeFs.fileExistsOverride = (path) => path == expectedVenvPy;

        final service = createService();
        await service.start();

        expect(service.currentState.status, SidecarStatus.running);
        expect(fakeExecutor.startCalls.length, 1);
        final call = fakeExecutor.startCalls.first;
        expect(call['executable'], expectedVenvPy);

        final env = call['environment'] as Map<String, String>;
        expect(env['HERMES_WEBUI_AGENT_DIR'], fakeFs.agentDir);
        expect(env['HERMES_WEBUI_HOST'], '127.0.0.1');
        expect(env['HERMES_WEBUI_PORT'], '8787');
        expect(env['HERMES_WEBUI_PASSWORD'], 'my_secret_token_xyz');
        expect(env['PYTHONDONTWRITEBYTECODE'], '1');

        await service.stop();
      },
    );

    test(
      '解释器探测分支 2：venv 缺失但 .venv 命中 -> 使用 .venv 解释器并注入 HERMES_WEBUI_AGENT_DIR',
      () async {
        final expectedDotVenvPy =
            '${fakeFs.agentDir}\\.venv\\Scripts\\python.exe';
        fakeFs.fileExistsOverride = (path) => path == expectedDotVenvPy;

        final service = createService();
        await service.start();

        expect(service.currentState.status, SidecarStatus.running);
        expect(fakeExecutor.startCalls.length, 1);
        final call = fakeExecutor.startCalls.first;
        expect(call['executable'], expectedDotVenvPy);

        final env = call['environment'] as Map<String, String>;
        expect(env['HERMES_WEBUI_AGENT_DIR'], fakeFs.agentDir);
        expect(env['HERMES_WEBUI_HOST'], '127.0.0.1');
        expect(env['HERMES_WEBUI_PORT'], '8787');
        expect(env['HERMES_WEBUI_PASSWORD'], 'my_secret_token_xyz');
        expect(env['PYTHONDONTWRITEBYTECODE'], '1');

        await service.stop();
      },
    );

    test('解释器探测分支 3：venv 与 .venv 均缺失 -> 兜底使用 embedded python 并注入 HERMES_WEBUI_AGENT_DIR', () async {
      final expectedEmbeddedPy = '${fakeFs.root}\\python\\python.exe';
      fakeFs.fileExistsOverride = (path) {
        if (path.contains('hermes-agent')) return false;
        return true;
      };

      final service = createService();
      await service.start();

      expect(service.currentState.status, SidecarStatus.running);
      expect(fakeExecutor.startCalls.length, 1);
      final call = fakeExecutor.startCalls.first;
      expect(call['executable'], expectedEmbeddedPy);

      final env = call['environment'] as Map<String, String>;
      expect(env['HERMES_WEBUI_AGENT_DIR'], fakeFs.agentDir);
      expect(env['HERMES_WEBUI_HOST'], '127.0.0.1');
      expect(env['HERMES_WEBUI_PORT'], '8787');
      expect(env['HERMES_WEBUI_PASSWORD'], 'my_secret_token_xyz');
      expect(env['PYTHONDONTWRITEBYTECODE'], '1');

      await service.stop();
    });

    test('resolvePythonPath 探测优先级：venv > .venv > embedded python 兜底', () {
      final service = createService();
      final venvPy = '${fakeFs.agentDir}\\venv\\Scripts\\python.exe';
      final dotVenvPy = '${fakeFs.agentDir}\\.venv\\Scripts\\python.exe';
      final embeddedPy = '${fakeFs.root}\\python\\python.exe';

      // 1. 两者皆有时优先 venv
      fakeFs.fileExistsOverride = (path) => path == venvPy || path == dotVenvPy;
      expect(service.resolvePythonPath(), venvPy);

      // 2. venv 不在，.venv 在
      fakeFs.fileExistsOverride = (path) => path == dotVenvPy;
      expect(service.resolvePythonPath(), dotVenvPy);

      // 3. 都不在，兜底 embedded
      fakeFs.fileExistsOverride = (path) => false;
      expect(service.resolvePythonPath(), embeddedPy);
    });

    test('watchdog 进程崩溃重启自愈保持相同解释器与 HERMES_WEBUI_AGENT_DIR', () async {
      final expectedVenvPy = '${fakeFs.agentDir}\\venv\\Scripts\\python.exe';
      fakeFs.fileExistsOverride = (path) => path == expectedVenvPy;

      final service = createService();
      await service.start();

      expect(fakeExecutor.startCalls.length, 1);
      expect(fakeExecutor.startCalls.first['executable'], expectedVenvPy);

      // 模拟进程异常退出，触发 watchdog 自愈重拉
      final restartProcess = _FakeProcess(pid: 8899);
      fakeExecutor.processToReturn = restartProcess;
      fakeProcess.completeExit(1);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeExecutor.startCalls.length, 2);
      final restartedCall = fakeExecutor.startCalls[1];
      expect(restartedCall['executable'], expectedVenvPy);
      final restartedEnv = restartedCall['environment'] as Map<String, String>;
      expect(restartedEnv['HERMES_WEBUI_AGENT_DIR'], fakeFs.agentDir);
      expect(restartedEnv['HERMES_WEBUI_HOST'], '127.0.0.1');

      await service.stop();
    });

    test(
      'DefaultSidecarFileSystem 默认 hermesAgentDir 与 customAgentDir 构造断言',
      () {
        const fsDefault = DefaultSidecarFileSystem(
          customLocalAppData: r'D:\CustomAppData',
        );
        expect(
          fsDefault.hermesAgentDir,
          r'D:\CustomAppData\hermes\hermes-agent',
        );

        const fsCustom = DefaultSidecarFileSystem(
          customAgentDir: r'E:\DedicatedAgent',
        );
        expect(fsCustom.hermesAgentDir, r'E:\DedicatedAgent');
      },
    );

    test('customAgentDir 可被 DefaultWebuiSidecarService 注入覆盖', () async {
      const customAgentPath = r'Z:\SpecialAgent';
      final expectedCustomVenvPy =
          '$customAgentPath\\venv\\Scripts\\python.exe';
      fakeFs.fileExistsOverride = (path) => path == expectedCustomVenvPy;

      final service = createService(customAgentDir: customAgentPath);
      await service.start();

      expect(fakeExecutor.startCalls.length, 1);
      final call = fakeExecutor.startCalls.first;
      expect(call['executable'], expectedCustomVenvPy);
      final env = call['environment'] as Map<String, String>;
      expect(env['HERMES_WEBUI_AGENT_DIR'], customAgentPath);

      await service.stop();
    });
  });
}
