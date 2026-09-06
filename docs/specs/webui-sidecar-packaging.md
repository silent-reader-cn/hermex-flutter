# WebUI Sidecar 打包设计说明书 (Windows Desktop Packaging Spec)

> 状态：定案 · 已实施  
> 适用平台：Windows (x64)  
> 任务归属：TASK S4（内置 WebUI 包构建脚本 + Inno Setup + CI windows-installer job）  
> 规范依据：`.todo/active.md`「内置 WebUI Sidecar」方向规格、决策 5（版本通道随 app 走）、风险①（发布前删 .git）、风险④（卸载数据留存语义）

---

## 1. 架构定位与设计目标

### 1.1 架构模型：Sidecar 随 App 捆绑
在之前版本中，hermes-ui 对 Hermes WebUI 后端的支持停留在引导页手动部署（依赖宿主 Git 与 Python 环境进行 `git clone` 与 `pip install`）。  
本设计借鉴 **Clash Verge 捆绑 mihomo 核心** 的产品形态，将 Hermes WebUI 后端与 Python 运行环境深度封装为随应用直接分发的内置 Sidecar 组件：
- **开箱即用**：用户机器无需预装 Python、Git 或任何 C++ 运行库编译环境；
- **运行时零 pip**：所有依赖包在 CI 构建期预先离线安装并固化，消除运行期网络拉取依赖的不确定性；
- **生命周期托管**：App 启动时按用户配置拉起 WebUI 子进程，退出时统一终止进程树，托盘与设置页双向同步状态。

```
+-------------------------------------------------------------------------+
|                        Hermes UI (Flutter App)                          |
|  - WebuiSidecarService (Process.start / Watchdog / Env / Log Tee)       |
|  - Settings / Tray Manager ("在浏览器中打开 WebUI")                       |
+-------------------------------------------------------------------------+
                                   |
                Spawns & Monitors  | (PORT, HOST, PASSWORD,
                                   |  PYTHONDONTWRITEBYTECODE=1)
                                   v
+-------------------------------------------------------------------------+
|                <安装目录>\webui\ (Sidecar 根目录)                         |
|  +-----------------------------------+  +----------------------------+  |
|  | python\python.exe (3.11.x Embed)  |  | server\server.py (WebUI)   |  |
|  | Lib\site-packages (预装离线依赖)    |  | api\ + static\             |  |
|  +-----------------------------------+  +----------------------------+  |
|  +-------------------------------------------------------------------+  |
|  | webui_version.txt (上游 commit sha, 单行固化)                       |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

---

## 2. 内置包目录布局规范（与 S1 硬约定）

根据与 S1（`WebuiSidecarService`）的硬性接口约定，打包产物在安装目标目录中的结构精确如下：

```
<安装目录>\
├── hermes_ui.exe                    # Flutter Runner 桌面主可执行程序
├── data\                            # Flutter 资源与 flutter_assets
│   ├── icudtl.dat
│   └── flutter_assets\
├── flutter_windows.dll              # Flutter 引擎动态链接库
├── (其他插件 dll)
└── webui\                           # 内置 WebUI Sidecar 根目录
    ├── python\                      # Python 3.11.x 64 位 Embeddable 环境
    │   ├── python.exe               # 解释器入口
    │   ├── pythonw.exe
    │   ├── python311.dll
    │   ├── python3.dll
    │   ├── python311.zip            # 标准库 zip
    │   ├── python311._pth           # sys.path 引导文件（已启用 import site）
    │   └── Lib\site-packages\       # 预装运行时依赖
    │       ├── yaml\ (pyyaml)
    │       ├── cryptography\
    │       └── ...
    ├── server\                      # hermes-webui 源码（已裁撤开发资源）
    │   ├── server.py                # 服务端主入口（标准库 http.server）
    │   ├── api\                     # API 路由与业务逻辑
    │   └── static\                  # Web 前端静态资源
    └── webui_version.txt            # 单行文本 = 上游 WebUI Git Commit SHA
```

### 关键路径语义
1. **主服务入口**：`<安装目录>\webui\server\server.py`
2. **解释器绝对路径**：`<安装目录>\webui\python\python.exe`
3. **版本比对文件**：`<安装目录>\webui\webui_version.txt`
4. **运行时数据隔离**：
   - 运行日志：`%LOCALAPPDATA%\hermes\webui-bundled\logs\`（由 App 负责从 stdout/stderr tee 写入，不落安装目录）
   - 业务状态/配置：`%LOCALAPPDATA%\hermes\`（`HERMES_HOME` 默认路径），与独立 agent / webui 实例共用数据目录

### 2.1 Python 解释器选择与 Agent 依赖对齐（方案 B′，TASK #71）

在 2026-09-06 安装包首测实证中定位：WebUI 服务端在聊天回合时于**进程内**直接 import Agent 核心（`api/streaming.py` 中的 `from run_agent import AIAgent`），而 Agent 需 `dotenv` 等全套第三方依赖（venv site-packages 实测 ~1.75GB）。内置 embedded Python 按 S4 零 pip 规格只预装了 WebUI 自身的两个轻依赖（`pyyaml` 与 `cryptography`），`server.py` 的 `auto_install_agent_deps()` 兜底在零 pip 环境注定失败，导致全新安装用户首发消息报错 `AIAgent not available`。

为兼顾安装包小巧（~50MB）与全新安装开箱即可发收消息，采纳 **方案 B′（解释器优先复用 Agent venv，Embedded 兜底；否决方案 A 构建期全量预装 1.75GB 依赖）**：
1. **解释器探测优先级**（纯 IO 探测，`webui_sidecar_service.dart`）：
   - **首选 Agent 默认 venv**：`%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\python.exe` 存在 → 选用之（与 Gateway 共享成熟环境，天然具备 `dotenv` 等全套依赖且版本对齐）；
   - **次选 Agent .venv**：`%LOCALAPPDATA%\hermes\hermes-agent\.venv\Scripts\python.exe` 存在 → 选用之；
   - **兜底 Embedded Python**：若本机未安装 Agent 或 venv 目录不存在，兜底使用随包分发的 `<安装目录>\webui\python\python.exe`（此时 WebUI 历史/会话只读可用，聊天提示 AIAgent not available 属预期）。
2. **显式注入环境变量**：
   - 启动 Sidecar 进程时追加 `HERMES_WEBUI_AGENT_DIR=%LOCALAPPDATA%\hermes\hermes-agent`，显式指定 Agent 源码根目录，消除 WebUI 上游多策略猜测带来的漂移风险；
   - 现有 4 个环境变量（`HERMES_WEBUI_HOST`、`HERMES_WEBUI_PORT`、`HERMES_WEBUI_PASSWORD`、`PYTHONDONTWRITEBYTECODE=1`）严格保持不变。
3. **分发包产物与脚本零改动**：
   - 打包脚本（`build_webui_bundle.ps1`）与 Inno Setup 脚本（`installer/hermes-ui.iss`）零改动；
   - 内置 embedded Python 仍随包分发作为坚实离线兜底，安装包体积（~50MB）与零 pip 断言不受影响。

---

## 3. Embedded Python 环境构建标准

### 3.1 基础选型
- **版本**：Python 3.11.9 (amd64 embeddable zip)
- **下载源与容灾策略**：
  - 首选：`https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip`
  - 兜底：npmmirror 官方 embeddable 镜像 `https://registry.npmmirror.com/-/binary/python/3.11.9/python-3.11.9-embed-amd64.zip`（与 python.org 同一 zip；国内网络实测可达）
  - pip 引导/依赖安装：pypi.org 失败自动重试清华 TUNA 镜像（`-i https://pypi.tuna.tsinghua.edu.cn/simple`）
  - ~~NuGet `python` 包兜底~~ 已移除：其 `tools\` 载荷为完整版安装（**无 `pythonXX._pth`**），Step 2 必失败，回退路线从不可走通（2026-09-04 审查发现，同日全链实测 npmmirror+TUNA 双回退通过）
  - 构建脚本内置多源下载与自动 fallback 机制

### 3.2 `python311._pth` 配置与 `site-packages` 启用
Embeddable Python 发行版默认隔离系统环境，且 `#import site` 处于注释状态。  
构建流水线中通过脚本自动修改 `python311._pth`：
1. 插入 `Lib\site-packages` 路径条目；
2. 取消 `#import site` 注释，改写为 `import site`；
3. 追加 `..\server` 路径条目。  
这使得 `python.exe` 启动时能够自动发现并加载 `Lib\site-packages` 下的第三方轮子包。

> **为何必须追加 `..\server`（2026-09-04 冒烟实证）**：带 `._pth` 文件的 embeddable python 运行在**隔离模式**——`sys.path` 完全由 `._pth` 决定，`PYTHONPATH` 与环境变量注入均被忽略，且脚本所在目录也不自动入 path。若不写入 `..\server`（相对 python 目录，即内置包的 `webui\server`），`server.py` 首行 `from api.auth import ...` 直接 `ModuleNotFoundError: No module named 'api'`，sidecar 无法启动。脚本对 `._pth` 的改写具备幂等性（重复执行不产生重复条目）。

### 3.3 构建期预装与「运行时零 pip」硬约束
Hermes WebUI 本体依赖极度轻量（仅 `pyyaml>=6.0` 与 `cryptography>=42.0`）。为了确保生产分发包的极度精简、纯净与安全，执行严格的**构建期安装 + 剥离流水线**：
1. **临时引入 Pip**：通过官方 `get-pip.py` 为 embedded python 注入临时 pip 与 setuptools；
2. **定向安装**：执行 `python.exe -m pip install --target Lib\site-packages pyyaml cryptography`；
3. **验证依赖**：执行 `import yaml; import cryptography` 验证 C-extensions（cffi、_yaml、cryptography）正确链接；
4. **彻底清洗**：
   - 物理删除 `pip`、`setuptools`、`wheel`、`packaging`、`pkg_resources` 等目录及其 `.dist-info`；
   - 物理删除 `Scripts\` 目录（含 `pip.exe`、`wheel.exe`）；
   - 递归清除所有 `__pycache__` 目录与 `*.pyc` 字节码文件；
   - 脚本执行 `python.exe -m pip --version` 必须返回 `No module named pip`，断言零 pip 成立。

### 3.4 Program Files 只读与防字节码写入
Windows 下应用通常安装在 `C:\Program Files\HermesUI`，普通用户无写入权限。  
App 在拉起 Sidecar 进程时注入环境变量：
```
PYTHONDONTWRITEBYTECODE=1
```
防止 Python 在安装目录下尝试生成 `__pycache__` 导致无权限异常。

---

## 4. 版本通道与上游更新语义

### 4.1 版本耦合策略（决策 5）
- **版本通道随 App 走**：与 Clash Verge 绑内核模式一致，Hermes WebUI 作为客户端桌面包的基础构件，随 hermes-ui 的正式发布而整体迭代。
- **不设独立自更新通道**：用户无需也不应在 UI 内单独更新 WebUI 代码。

### 4.2 剥离 `.git` 消除上游自更新隐患（风险①闭环）
- Hermes WebUI 上游内置有自更新模块（`updates.py`），其更新逻辑以 `.git` 目录存在为前提条件。若检测不到 `.git`，自更新检查会自动跳过。
- 构建流水线在通过 `git rev-parse HEAD` 获取当前检出 commit sha 并写入 `webui_version.txt` 后，**强制递归删除 `.git`、`tests`、`docs` 目录**。
- 这既为分发包节省了数十兆空间，又天然在物理层阻断了上游自更新触发文件修改的风险。

---

## 5. Inno Setup 安装包规格

### 5.1 核心配置属性
- **脚本路径**：`installer/hermes-ui.iss`
- **输出包命名规则**：`HermesUI-<version>-x64-setup.exe`（如 `HermesUI-0.1.17-x64-setup.exe`）
- **默认安装路径**：`{autopf}\HermesUI`（64 位 Program Files）
- **固定 GUID (`AppId`)**：`{{8B41253C-9A5C-4B74-8C37-A3C8B7E20E21}}`（锁死，保证版本平滑升级覆盖，不产生重复安装项）
- **架构支持**：纯 64 位（`ArchitecturesAllowed=x64`, `ArchitecturesInstallIn64BitMode=x64`）
- **图标与许可**：引用 `installer/app_icon.ico` 与 `installer/LICENSE.txt`

### 5.2 注册表与关联约束
- **严禁抢占 `.py` 文件关联**：安装包仅注册自身快捷方式与卸载项，绝不篡改系统 Python 关联。
- **不写入注册表开机启动**：开机自启能力由 App 内 `startup_registrar.dart` 统一按用户设置项管理，安装器不代越。

---

## 6. 升级与卸载语义设计

### 6.1 覆盖升级语义
当用户运行新版本安装包时：
- Inno Setup 基于固定的 `AppId` 自动识别旧版本安装目录；
- 原地覆盖更新 `hermes_ui.exe`、Flutter 动态库以及 `<安装目录>\webui\` 内的 python 与 server 代码；
- 用户的本地配置（存储于注册表/Flutter shared_preferences）与 WebUI 历史会话数据（存储于 `%LOCALAPPDATA%\hermes\`）毫发无损。

### 6.2 卸载清理与用户数据保留语义（风险④闭环）
根据规格要求，卸载过程必须保护用户的数据资产：
- **安装目录**：彻底清理 `{app}` 及其全部内容（包含 `webui\`）。
- **用户数据与日志默认保留**：
  - 日志目录：`%LOCALAPPDATA%\hermes\webui-bundled\`（默认保留）
  - 状态数据：`%LOCALAPPDATA%\hermes\webui\`（默认保留）
- **卸载确认页交互**：
  - Inno Setup 卸载程序配置 `ConfirmUninstall=no`，接管默认弹窗；
  - 在 `InitializeUninstall()` 中弹出定制化对话框，包含询问文案与勾选项：
    ```
    [ ] Also remove logs and WebUI state data (同时删除日志与 WebUI 状态数据)
    ```
  - 该复选框**默认未选中（Checked = False）**；
  - 仅当用户主动勾选该项确认后，`CurUninstallStepChanged(usPostUninstall)` 阶段才会级联删除 `%LOCALAPPDATA%\hermes\webui-bundled` 与 `%LOCALAPPDATA%\hermes\webui`。

---

## 7. 构建与 CI 流水线集成

### 7.1 本地构建命令
1. **组装 Sidecar 内置包**：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/packaging/build_webui_bundle.ps1 -OutDir build\webui-bundle
   ```
2. **编译 Inno Setup 安装包**：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts/packaging/build_installer.ps1
   ```

### 7.2 CI `windows-installer` 流水线
位于 `.github/workflows/ci.yml`，在 `analyze-test` 绿灯后触发：
1. **触发时机**：
   - 推送 `main` 分支；
   - 打 Release Tag（`v*`）；
   - 手动调度（`workflow_dispatch`，可传参 `webui_ref` 指定上游分支/Commit）。
2. **并发控制**：`concurrency` 取消同分支未完成的旧构建；
3. **构建步骤**：
   - 检出源码；
   - 配置构建工具链（Python 3.12、Flutter 3.47.0 stable、Inno Setup 6）；
   - 执行 `flutter build windows --release`；
   - 执行 `build_webui_bundle.ps1` 组装 Sidecar；
   - 执行 `build_installer.ps1` 输出安装包；
   - 上传 `HermesUI-*-x64-setup.exe` 至 GitHub Artifacts。
