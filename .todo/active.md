# Hermes UI TODO — Active（进行中队列 · 完整规格）

> **规则**：
> 1. 新增任务直接在【本文件】写完整规格（位置/范围/复现/现状vs预期/验收），不写日期文件。
> 2. 条目完成收口 → 将完整条目【誊写】到完成当天日期文件 `.todo/YYYYMMDD.md`（不存在则新建)，标题标 `[已收口]` 作归档备份；随后从本文件移除该条。
> 3. 本文件只保留未收口任务，收口即清出。

---

（#56-#63 已全部收口誊写至 `.todo/20260905.md`；#64 胶囊方案 E 已收口至 `.todo/20260905.md`；#65-#70 六条已收口誊写至 `.todo/20260906.md`）

---

### #71 [P0 方案已定 B′ · 未开工] 内置 WebUI sidecar 缺 agent 运行依赖，全新安装第一条消息必失败
- 位置：`lib/features/webui_sidecar/webui_sidecar_service.dart`（解释器选择，现固定 `webui\python\python.exe`）；根因侧 `scripts/packaging/build_webui_bundle.ps1`（Step 3 只预装 pyyaml/cryptography）；消费方 `D:/hermes-webui api/streaming.py:616 AIAgent = get_ai_agent_class()`（进程内 import hermes-agent run_agent）
- 复现（2026-09-06 E2E 实证，报告 `build/reports/win-installer-e2e-20260905/REPORT.md`）：全新装 0.1.23 → 引导页一键「启动并连接」全通（起服/登录/会话列表）→ 发第一条消息 → 红条「AIAgent not available — check that hermes-agent is on sys.path」；截图 27/28
- 根因：聊天回合由 webui **进程内** import agent 的 run_agent，agent 需 dotenv 等全套第三方依赖；内置 embedded python 按 S4 零 pip 规格只装了 webui 自身两依赖，server.py 的 auto_install_agent_deps() 兜底在零 pip 环境注定失败（日志实证 `ModuleNotFoundError: No module named 'dotenv'`）
- 现状 vs 预期：现状=内置模式只能读历史不能对话（对所有全新用户不可用）；预期=开箱即可发收消息
- **修复方案（2026-09-06 主人过目定稿：B′——sidecar 优先用 agent venv 的解释器跑内置 server，embedded python 降级为兜底；A 方案否决）**：
  - 否决 A 的实证：agent venv site-packages 实测 **1.75GB**，构建期全量预装 = 安装包 50MB→~1.8GB 且引入版本漂移；无 agent 的用户本来就聊不了天（引导页 agent 缺失卡已有引导），「纯离线自足」在当前产品语义下是伪需求
  - B′ 决定性实证（2026-09-06）：① agent venv python 直接跑 `C:\Program Files\HermesUI\webui\server\server.py` → 起服成功、启动横幅 `agent dir : %LOCALAPPDATA%\hermes\hermes-agent [ok]`、`/api/system/health` 401（auth 开启即活）；② `from api.streaming import AIAgent` → `<class 'run_agent.AIAgent'>` 导入成功；③ venv 依赖 dotenv/aiohttp/yaml/cryptography 全齐（Python 3.11.15，与 server 只用标准库+2 轻依赖耦合无感）。优于原 B（embedded python + `_pth` 混插 venv site-packages 有 ABI/版本错配隐患）：换解释器=零混插，venv 本就是 agent 官方运行环境（gateway 同环境实证）
  - 实现要点（`webui_sidecar_service.dart` 单点改动）：
    1. 启动前探测解释器（纯 IO，走现有 fileSystem 注入缝可测）：`%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\python.exe` 存在 → 用之；再探 `…\.venv\Scripts\python.exe`；都没有 → 兜底 `webui\python\python.exe`
    2. env 追加 `HERMES_WEBUI_AGENT_DIR=<agent 目录>`（显式指定，不靠 webui 多策略猜）；现有 4 个 env（HOST/PORT/PASSWORD/PYTHONDONTWRITEBYTECODE）不变
    3. bundle 判定不变（仍用 `webui\server\server.py` 存在性判打包态）；server.py 路径、工作目录、日志 tee、watchdog、端口接管逻辑全部不动
    4. 单测：三条探测分支（venv 命中 / .venv 命中 / 兜底 embedded）+ `HERMES_WEBUI_AGENT_DIR` 注入断言（现有 28 个 sidecar 单测框架直扩）
    5. 文档：`docs/specs/webui-sidecar-packaging.md` §2 补「解释器选择」小节；打包脚本与 .iss 零改动（embedded python 仍随包分发作兜底）
  - 边界：venv python 与 app 无版本耦合风险（server 轻依赖）；真要做「App 自带完整 agent+依赖」是另一量级决策，不塞进本修复
- 验收：全新安装（清 prefs + 删 Program Files\HermesUI + **无绕行补丁**，即 `python311._pth` 保持出厂三行）→ 一键启动并连接 → 发中文消息 → 收到 agent 回复（进程列表可见 sidecar python.exe 路径在 agent venv 内）；模拟 venv 缺失（改名 venv 目录）→ 兜底 embedded 起服、历史可读、聊天报 AIAgent not available 属预期；零 pip 断言不回归；watchdog kill 重拉仍用同一探测结果
- ⚠️ 取证遗留：当前安装目录 `C:\Program Files\HermesUI\webui\python\python311._pth` 尾部有本喵 E2E 加的 venv site-packages 绕行行，修复验收前须还原

---

---

---

### #72 [P2 未修复] App 冷启动 sidecar 未就绪窗口期弹模态「操作失败·离线缓存」
- 位置：启动链 sidecar 拉起（`webui_sidecar_service` start 异步）与会话列表首刷（`desktop_lifecycle_observer` / connections 激活）时序竞争
- 复现（E2E 实证）：已配置内置连接后重启 hermes_ui.exe → 首帧会话列表请求打到尚未 LISTENING 的 :8787 → 中央模态「操作失败 离线缓存：当前显示最近缓存的会话」需手点「好」；数秒后 sidecar 就绪列表自动恢复（截图 20/24）
- 现状 vs 预期：现状=新用户每次冷启动见红色报错弹窗；预期=内置连接冷启动静默宽限（3~5s 轮询 health）或降级为轻量 toast，就绪后自动刷新
- 验收：杀 app 重启 ×3 无模态报错弹窗；手动断网场景离线提示仍可见（不吞真错误）；回归单测覆盖宽限逻辑

---

---

### #73 [P0 未修复·未开工] live 文本反复重复：SSE 订阅连接泄漏叠加（N 条连接各送一份事件流）
- 位置：`lib/features/chat/chat_controller.dart` `_connectStream`（:1221-1274）与 `_loadMessagesAndResume`（:3042-3069）；`lib/core/api/sse_client.dart` `SseClient.start`（:762-802 `_cancelToken = CancelToken()` 直接覆盖）；`lib/features/chat/chat_providers.dart` 看门狗阈值（:75-81）
- 复现（2026-09-06 主人日志实证，v0.1.24 真机）：live 生成中出现整段/逐词重复文本（「本喵喵」式）；诊断日志同一 token/reasoning/tool 事件成倍出现（9a8c 会话 ×6-7 份、c661f6 会话 ×2 份），heartbeat 每 ~5s 成串 6-8 条同刻到达；`/api/system/health` 的 `streams.subscribers` 12s 内 8→9→10 单调上涨
- 根因（源码行号实证）：恢复路径从不关旧 SSE 连接——①`_checkStatusAndReconnect` → status active → `_loadMessagesAndResume` → `_connectStream` → `api.startStream` 全链无 stopStream()（全项目仅 `_forceReconnect` :3135 先 stopStream）；②`SseClient.start` 覆盖 `_cancelToken` 不 cancel 旧请求 → 旧连接永久存活继续吐事件；③触发源 = 工具执行期 `isToolProgressStale`（:3190-3193，progress>18s 无视传输健康）与 resume 主动探针（:1511-1525，gap≥2s）——heartbeat 每 5s 准时到达（传输活着）照样触发 status 轮询 → active → 再叠一条；长工具回合每轮 +1 累积到 6-7 条；④live token 去重只覆盖 replay 窗口（`deduplicatedReplayToken` :1364-1378，游标追平 stillReplay=false 后裸追加）→ N 条连接同一 token 各 append 一次 = 文本重复 N 倍
- 与既有修复的边界：G（interim 快照 #60）/D（replay 重放 #42/e57ce9b）/I（隐形 text 断点 #62）均不覆盖本形态——这是「多连接并发灌入」新类别，非重放去重问题
- 修复方案（2026-09-06 分析定稿，待主人拍板后开工）：
  - A 根治：`_connectStream` 入口先 `stopStream()` 再建新连接；更稳 = `SseClient.start()` 内部先 cancel 旧 token（防御所有调用方；clarify 流已是此写法 chat_server_api.dart:361）
  - B 消触发源：`isToolProgressStale`/`isToolProgressForce` 加 transport-fresh 门控——heartbeat 持续到达（`_lastTransportActivity` 距今 < 心跳间隔×2）则不触发 status 轮询/强重连（工具跑得慢 ≠ 连接死了）
  - 可选 C 兜底：live token 追加前按「整段包含+尾首重叠」二次去重（同 #60 手法），防其他路径再灌重复
- 验收：①修复后 live 长工具回合（如 6 分钟后台命令）期间 `/api/system/health` 的 `subscribers` 稳定 = 活跃会话数、不单调上涨；②诊断日志 heartbeat 单条 ~5s 间隔不再成串；③live 正文无重复追加；④回归测试：SseClient.start 覆盖前 cancel 旧 token + watchdog transport-fresh 门控两案
- 备注：主人指示先落盘不修复，待拍板开工
