import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/install/install_detector.dart';
import '../../core/install/webui_bootstrap.dart';
import 'webui_sidecar_config.dart';
import 'webui_sidecar_models.dart';

export 'webui_sidecar_config.dart';
export 'webui_sidecar_models.dart';

/// 端口探测接口抽象（用于单元测试 fake 注入）。
abstract interface class PortProber {
  /// 探测指定 host 与 port 是否已有服务监听并可建立连接。
  Future<bool> isPortOpen(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 1),
  });
}

/// 基于 [Socket.connect] 的生产环境端口探测器。
class SystemPortProber implements PortProber {
  /// 构造生产端口探测器。
  const SystemPortProber();

  @override
  Future<bool> isPortOpen(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final connectHost = host == '0.0.0.0' ? '127.0.0.1' : host;
    try {
      final socket = await Socket.connect(connectHost, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// WebUI Sidecar 文件系统与环境适配器抽象。
abstract interface class SidecarFileSystem {
  /// 当前操作系统是否为 Windows。
  bool get isWindows;

  /// 开发模式环境变量覆盖根目录（`HERMES_UI_SIDECAR_ROOT`）。
  String? get envSidecarRoot;

  /// 默认内置包目录（`<exe所在目录>\webui`）。
  String get defaultSidecarDir;

  /// 日志存储目录（`%LOCALAPPDATA%\hermes\webui-bundled\logs`）。
  String get logDirectoryPath;

  /// 日志文件路径（`webui.log`）。
  String get logFilePath;

  /// 检查文件是否存在。
  bool fileExists(String path);

  /// 检查目录是否存在。
  bool directoryExists(String path);

  /// 创建目录。
  Future<void> createDirectory(String path, {bool recursive = true});

  /// 异步追加单行日志到指定文件。
  Future<void> appendLogLine(String path, String line);

  /// 检查日志文件大小，超过指定字节数（默认 5MB）则轮转为 `.1`。
  Future<void> rotateLogIfNeeded(
    String path, {
    int maxSizeBytes = 5 * 1024 * 1024,
  });

  /// 探测并解析当前有效的 WebUI 根目录。
  String resolveBundleDir();

  /// 校验内置包关键依赖是否存在（`python\python.exe` 与 `server\server.py`）。
  bool isBundleAvailable();
}

/// 默认生产环境文件系统适配器。
class DefaultSidecarFileSystem implements SidecarFileSystem {
  /// 构造生产环境文件系统适配器。
  const DefaultSidecarFileSystem({
    this.customExePath,
    this.customEnvRoot,
    this.customLocalAppData,
    this.customAgentDir,
  });

  /// 自定义 exe 路径（测试注入用）。
  final String? customExePath;

  /// 自定义环境变量覆盖（测试注入用）。
  final String? customEnvRoot;

  /// 自定义 LOCALAPPDATA（测试注入用）。
  final String? customLocalAppData;

  /// 自定义 Hermes Agent 根目录（测试注入用）。
  final String? customAgentDir;

  @override
  bool get isWindows => Platform.isWindows;

  @override
  String? get envSidecarRoot =>
      customEnvRoot ?? Platform.environment['HERMES_UI_SIDECAR_ROOT'];

  @override
  String get defaultSidecarDir {
    final exe = customExePath ?? Platform.resolvedExecutable;
    return '${File(exe).parent.path}${Platform.pathSeparator}webui';
  }

  String get _localAppData =>
      customLocalAppData ??
      Platform.environment['LOCALAPPDATA'] ??
      (Platform.isWindows
          ? 'C:\\Users\\${Platform.environment['USERNAME'] ?? 'User'}\\AppData\\Local'
          : '');

  /// Hermes Agent 安装根目录（`%LOCALAPPDATA%\hermes\hermes-agent`）。
  String get hermesAgentDir =>
      customAgentDir ??
      '$_localAppData${Platform.pathSeparator}hermes${Platform.pathSeparator}hermes-agent';

  @override
  String get logDirectoryPath =>
      '$_localAppData${Platform.pathSeparator}hermes${Platform.pathSeparator}webui-bundled${Platform.pathSeparator}logs';

  @override
  String get logFilePath =>
      '$logDirectoryPath${Platform.pathSeparator}webui.log';

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) =>
      Directory(path).create(recursive: recursive);

  @override
  Future<void> appendLogLine(String path, String line) async {
    final file = File(path);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  @override
  Future<void> rotateLogIfNeeded(
    String path, {
    int maxSizeBytes = 5 * 1024 * 1024,
  }) async {
    final file = File(path);
    if (file.existsSync()) {
      final len = await file.length();
      if (len >= maxSizeBytes) {
        final rotated = File('$path.1');
        if (rotated.existsSync()) {
          await rotated.delete();
        }
        await file.rename('$path.1');
      }
    }
  }

  @override
  String resolveBundleDir() {
    final env = envSidecarRoot;
    if (env != null && env.isNotEmpty) {
      final directPy =
          '$env${Platform.pathSeparator}python${Platform.pathSeparator}python.exe';
      final directServer =
          '$env${Platform.pathSeparator}server${Platform.pathSeparator}server.py';
      if (fileExists(directPy) && fileExists(directServer)) {
        return env;
      }
      final nestedPy =
          '$env${Platform.pathSeparator}webui${Platform.pathSeparator}python${Platform.pathSeparator}python.exe';
      final nestedServer =
          '$env${Platform.pathSeparator}webui${Platform.pathSeparator}server${Platform.pathSeparator}server.py';
      if (fileExists(nestedPy) && fileExists(nestedServer)) {
        return '$env${Platform.pathSeparator}webui';
      }
      return env;
    }
    return defaultSidecarDir;
  }

  @override
  bool isBundleAvailable() {
    if (!isWindows) return false;
    final bundleDir = resolveBundleDir();
    final py =
        '$bundleDir${Platform.pathSeparator}python${Platform.pathSeparator}python.exe';
    final server =
        '$bundleDir${Platform.pathSeparator}server${Platform.pathSeparator}server.py';
    return fileExists(py) && fileExists(server);
  }
}

/// [SidecarFileSystem] 的 Agent 目录扩展能力。
extension SidecarFileSystemAgentExtension on SidecarFileSystem {
  /// 获取 Hermes Agent 安装根目录（`%LOCALAPPDATA%\hermes\hermes-agent`）。
  String get hermesAgentDir {
    final fs = this;
    if (fs is DefaultSidecarFileSystem) {
      return fs.hermesAgentDir;
    }
    try {
      final dynamic dynamicFs = fs;
      final dynamic custom = dynamicFs.hermesAgentDir;
      if (custom is String && custom.isNotEmpty) {
        return custom;
      }
    } catch (_) {}
    final logDir = fs.logDirectoryPath;
    final sep = Platform.pathSeparator;
    final hermesIdx = logDir.lastIndexOf('${sep}hermes$sep');
    if (hermesIdx != -1) {
      final base = logDir.substring(0, hermesIdx);
      return '$base${sep}hermes${sep}hermes-agent';
    }
    final base =
        Platform.environment['LOCALAPPDATA'] ??
        (Platform.isWindows
            ? 'C:\\Users\\${Platform.environment['USERNAME'] ?? 'User'}\\AppData\\Local'
            : '');
    return '$base${sep}hermes${sep}hermes-agent';
  }
}

/// WebUI Sidecar 服务接口（生命周期与状态核心）。
abstract interface class WebuiSidecarService {
  /// 启动内置 WebUI 服务（幂等：已 running 直接返回；读取最新配置）。
  Future<void> start();

  /// 停止服务（先摘 watchdog；温和 terminate 3s 未退则 taskkill 清进程树）。
  Future<void> stop();

  /// 重启服务。
  Future<void> restart();

  /// 状态广播流。
  Stream<SidecarState> get states;

  /// 当前即时状态快照。
  SidecarState get currentState;
}

/// 退避时长计算器函数类型。
typedef BackoffCalculator = Duration Function(int attempt);

/// [WebuiSidecarService] 默认实现。
class DefaultWebuiSidecarService implements WebuiSidecarService {
  /// 构造 WebUI Sidecar 默认服务。
  DefaultWebuiSidecarService({
    required this._getConfig,
    this.processExecutor = const SystemProcessExecutor(),
    this.fileSystem = const DefaultSidecarFileSystem(),
    this.healthChecker = const SystemHealthChecker(),
    this.portProber = const SystemPortProber(),
    this.healthTimeout = const Duration(seconds: 30),
    this.healthInterval = const Duration(milliseconds: 500),
    this.takeoverInterval = const Duration(seconds: 5),
    this.stopGracePeriod = const Duration(seconds: 3),
    BackoffCalculator? backoffCalculator,
    this.customAgentDir,
  }) : _backoffCalculator = backoffCalculator ?? _defaultBackoffCalculator;

  final SidecarConfig Function() _getConfig;

  /// 进程执行器。
  final ProcessExecutor processExecutor;

  /// 文件系统与路径适配器。
  final SidecarFileSystem fileSystem;

  /// 自定义 Agent 根目录（测试注入用）。
  final String? customAgentDir;

  /// 获取当前生效的 Agent 根目录。
  String get agentDir => customAgentDir ?? fileSystem.hermesAgentDir;

  /// 探测并解析用于启动 WebUI 的 Python 解释器路径。
  ///
  /// 优先级（方案 B′）：
  /// 1. `%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\python.exe` 存在 → 优先使用（自带完整 agent 运行环境）；
  /// 2. `%LOCALAPPDATA%\hermes\hermes-agent\.venv\Scripts\python.exe` 存在 → 次选使用；
  /// 3. 都不存在 → 兜底使用内置包 embedded python（`<bundleDir>\python\python.exe`）。
  String resolvePythonPath([String? bundleDir]) {
    final root = bundleDir ?? fileSystem.resolveBundleDir();
    final targetAgentDir = agentDir;
    final sep = Platform.pathSeparator;
    final venvPy = '$targetAgentDir${sep}venv${sep}Scripts${sep}python.exe';
    if (fileSystem.fileExists(venvPy)) {
      return venvPy;
    }
    final dotVenvPy = '$targetAgentDir$sep.venv${sep}Scripts${sep}python.exe';
    if (fileSystem.fileExists(dotVenvPy)) {
      return dotVenvPy;
    }
    return '$root${sep}python${sep}python.exe';
  }

  /// 健康检查探测器。
  final HealthChecker healthChecker;

  /// 端口开放探测器。
  final PortProber portProber;

  /// 启动后轮询 /health 的超时时长。
  final Duration healthTimeout;

  /// 轮询 /health 的采样间隔。
  final Duration healthInterval;

  /// 接管模式下巡检 /health 的采样间隔。
  final Duration takeoverInterval;

  /// 停止服务时等待进程自然退出的宽限期。
  final Duration stopGracePeriod;

  final BackoffCalculator _backoffCalculator;

  final StreamController<SidecarState> _stateController =
      StreamController<SidecarState>.broadcast();

  SidecarState _state = SidecarState.initial;
  Process? _currentProcess;
  bool _isTakeover = false;
  bool _isStopping = false;
  int _consecutiveFailures = 0;
  Timer? _watchdogTimer;
  StreamSubscription<int>? _exitSubscription;
  Completer<void>? _startCompleter;

  static const int maxConsecutiveFailures = 5;

  static Duration _defaultBackoffCalculator(int attempt) {
    final seconds = min(30, pow(2, attempt - 1).toInt());
    return Duration(seconds: seconds);
  }

  @override
  SidecarState get currentState => _state;

  @override
  Stream<SidecarState> get states => _stateController.stream;

  void _updateState(SidecarState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  @override
  Future<void> start() async {
    // 幂等：若已处于 running 状态，直接返回。
    // 注意语义：自愈退避期间状态保持 running（detail=restarting N），
    // 此时用户点「启动」会命中本短路——预期行为：watchdog 已在自愈，
    // 无需重复拉起；UI 侧胶囊显示「重启中」即反馈。
    if (_state.status == SidecarStatus.running) {
      return;
    }

    if (_startCompleter != null) {
      return _startCompleter!.future;
    }

    final completer = Completer<void>();
    _startCompleter = completer;

    try {
      _consecutiveFailures = 0;
      await _performStart();
    } finally {
      _startCompleter = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _performStart({bool isSelfHealing = false}) async {
    // 跨平台检查：仅 Windows 平台拉起进程
    if (!fileSystem.isWindows) {
      _updateState(
        const SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.startFailed,
          detail: 'Built-in WebUI sidecar is only supported on Windows',
        ),
      );
      return;
    }

    final config = _getConfig();

    // 内置包目录探测
    if (!fileSystem.isBundleAvailable()) {
      _updateState(
        const SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.missingBundle,
          detail: 'WebUI bundle dependencies not found',
        ),
      );
      return;
    }

    final host = config.host;
    final port = config.port;
    final connectHost = host == '0.0.0.0' ? '127.0.0.1' : host;

    // 端口探测
    final isOccupied = await portProber.isPortOpen(
      host,
      port,
      timeout: const Duration(seconds: 1),
    );

    if (isOccupied) {
      // 端口已开启，尝试探测 /health
      final healthUrl = 'http://$connectHost:$port/health';
      final isHealthy = await healthChecker.checkHealth(healthUrl);
      if (isHealthy) {
        // 接管模式
        _isTakeover = true;
        _currentProcess = null;
        _consecutiveFailures = 0;
        _updateState(
          const SidecarState(
            status: SidecarStatus.running,
            reason: SidecarFailureReason.none,
            pid: null,
            detail: 'Takeover mode',
          ),
        );
        _startWatchdog();
        return;
      } else {
        // 端口被占且非健康 WebUI 服务，报错且不自动换端口
        _updateState(
          SidecarState(
            status: SidecarStatus.failed,
            reason: SidecarFailureReason.portOccupied,
            detail: 'Port $port is already occupied by an unrecognized service',
          ),
        );
        if (isSelfHealing) {
          await _triggerSelfHealing('Port $port occupied during restart');
        }
        return;
      }
    }

    // 端口空闲，进入启动子进程阶段
    _isTakeover = false;
    _isStopping = false;
    _updateState(
      const SidecarState(
        status: SidecarStatus.starting,
        reason: SidecarFailureReason.none,
      ),
    );

    final bundleDir = fileSystem.resolveBundleDir();
    final targetAgentDir = agentDir;
    final pyPath = resolvePythonPath(bundleDir);
    final serverPath =
        '$bundleDir${Platform.pathSeparator}server${Platform.pathSeparator}server.py';

    final env = <String, String>{
      'HERMES_WEBUI_HOST': config.host,
      'HERMES_WEBUI_PORT': config.port.toString(),
      'HERMES_WEBUI_PASSWORD': config.password,
      'PYTHONDONTWRITEBYTECODE': '1',
      'HERMES_WEBUI_AGENT_DIR': targetAgentDir,
    };

    Process process;
    try {
      process = await processExecutor.start(
        pyPath,
        [serverPath],
        workingDirectory: bundleDir,
        environment: env,
      );
    } catch (e) {
      _updateState(
        SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.startFailed,
          detail: 'Failed to start WebUI child process: $e',
        ),
      );
      if (isSelfHealing) {
        await _triggerSelfHealing('Process start exception: $e');
      }
      return;
    }

    _currentProcess = process;
    _updateState(
      SidecarState(
        status: SidecarStatus.starting,
        reason: SidecarFailureReason.none,
        pid: process.pid,
      ),
    );

    // 启动日志 tee
    _pipeLogs(process, config.password);

    // 轮询 /health 接口确认健康状态
    final healthUrl = 'http://$connectHost:$port/health';
    final stopwatch = Stopwatch()..start();
    var healthOk = false;

    while (stopwatch.elapsed < healthTimeout) {
      if (_isStopping) return;

      healthOk = await healthChecker.checkHealth(healthUrl);
      if (healthOk) break;

      await Future<void>.delayed(healthInterval);
    }

    if (!healthOk) {
      final pid = process.pid;
      _updateState(
        const SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.healthTimeout,
          detail: 'Health check timed out after 30 seconds',
        ),
      );
      await _killProcessTree(pid, process);
      _currentProcess = null;

      if (isSelfHealing) {
        await _triggerSelfHealing('Health check timeout');
      }
      return;
    }

    // 健康确认成功，进入 running 态并激活 watchdog
    _consecutiveFailures = 0;
    _updateState(
      SidecarState(
        status: SidecarStatus.running,
        reason: SidecarFailureReason.none,
        pid: process.pid,
      ),
    );
    _startWatchdog();
  }

  void _pipeLogs(Process process, String password) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          unawaited(_writeLogLine(line, password));
        });

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          unawaited(_writeLogLine(line, password));
        });
  }

  Future<void> _writeLogLine(String line, String password) async {
    var sanitized = line;
    if (password.isNotEmpty) {
      sanitized = sanitized.replaceAll(password, '***');
    }
    try {
      final logPath = fileSystem.logFilePath;
      await fileSystem.rotateLogIfNeeded(logPath);
      await fileSystem.appendLogLine(logPath, sanitized);
    } catch (_) {
      // 容错忽略日志追加异常
    }
  }

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    final oldSub = _exitSubscription;
    if (oldSub != null) {
      unawaited(oldSub.cancel());
    }

    if (_isTakeover) {
      var takeoverFails = 0;
      _watchdogTimer = Timer.periodic(takeoverInterval, (timer) async {
        if (_isStopping || _state.status != SidecarStatus.running) {
          timer.cancel();
          return;
        }

        final config = _getConfig();
        final connectHost = config.host == '0.0.0.0'
            ? '127.0.0.1'
            : config.host;
        final healthUrl = 'http://$connectHost:${config.port}/health';
        final isHealthy = await healthChecker.checkHealth(healthUrl);

        if (isHealthy) {
          takeoverFails = 0;
        } else {
          takeoverFails++;
          if (takeoverFails >= 3) {
            timer.cancel();
            await _triggerSelfHealing(
              'Takeover health check failed 3 consecutive times',
            );
          }
        }
      });
    } else if (_currentProcess != null) {
      final proc = _currentProcess!;
      unawaited(
        proc.exitCode.then((code) {
          if (_isStopping || _currentProcess != proc) return;
          unawaited(
            _triggerSelfHealing('Process exited unexpectedly with code $code'),
          );
        }),
      );
    }
  }

  Future<void> _triggerSelfHealing(String reason) async {
    if (_isStopping) return;

    _consecutiveFailures++;
    if (_consecutiveFailures >= maxConsecutiveFailures) {
      _updateState(
        SidecarState(
          status: SidecarStatus.failed,
          reason: SidecarFailureReason.startFailed,
          detail:
              'Auto-healing stopped: consecutive failures reached limit ($maxConsecutiveFailures). Last error: $reason',
        ),
      );
      _currentProcess = null;
      return;
    }

    final delay = _backoffCalculator(_consecutiveFailures);

    _updateState(
      SidecarState(
        status: SidecarStatus.running,
        reason: SidecarFailureReason.none,
        detail: 'restarting (attempt $_consecutiveFailures)',
      ),
    );

    await Future<void>.delayed(delay);
    if (_isStopping) return;

    await _performStart(isSelfHealing: true);
  }

  @override
  Future<void> stop() async {
    if (_state.status == SidecarStatus.stopped &&
        _currentProcess == null &&
        !_isTakeover) {
      return;
    }

    _isStopping = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    final sub = _exitSubscription;
    if (sub != null) {
      await sub.cancel();
      _exitSubscription = null;
    }
    _consecutiveFailures = 0;

    final proc = _currentProcess;
    _currentProcess = null;
    _isTakeover = false;

    if (proc != null) {
      await _killProcessTree(proc.pid, proc);
    }

    _updateState(
      const SidecarState(
        status: SidecarStatus.stopped,
        reason: SidecarFailureReason.none,
      ),
    );
    _isStopping = false;
  }

  Future<void> _killProcessTree(int pid, [Process? proc]) async {
    var exitedCleanly = false;
    if (proc != null) {
      try {
        proc.kill();
        final exit = await proc.exitCode.timeout(
          stopGracePeriod,
          onTimeout: () => -1,
        );
        if (exit != -1) {
          exitedCleanly = true;
        }
      } catch (_) {
        // 忽略温和退出异常
      }
    }

    if (!exitedCleanly) {
      try {
        await processExecutor.run('taskkill', [
          '/T',
          '/F',
          '/PID',
          pid.toString(),
        ]);
      } catch (_) {
        // 忽略 taskkill 失败异常
      }
    }
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }
}
