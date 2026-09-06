# Hermes UI TODO — Active（进行中队列 · 完整规格）

> **规则**：
> 1. 新增任务直接在【本文件】写完整规格（位置/范围/复现/现状vs预期/验收），不写日期文件。
> 2. 条目完成收口 → 将完整条目【誊写】到完成当天日期文件 `.todo/YYYYMMDD.md`（不存在则新建)，标题标 `[已收口]` 作归档备份；随后从本文件移除该条。
> 3. 本文件只保留未收口任务，收口即清出。

---

（#56-#63 已全部收口誊写至 `.todo/20260905.md`；#64 胶囊方案 E 已收口至 `.todo/20260905.md`）

---

### #65 [P1→已修复待真机复验] 下载中心「打开」Android 必炸：裸 file:// URI 被 StrictMode 拦截
- 位置：`lib/features/downloads/download_page.dart` `openDownloadedFile` Android 分支（原 :79 `data: file://$path`）
- 复现：下载任一文件（png/apk）→ 下载页点「打开」→ 弹「无法打开文件 PlatformException(error, file:///storage/emulated/0/Download/... exposed beyond app through Intent.getData())」
- 现状 vs 预期：Android 7+ 禁止 file:// URI 跨应用共享（FileUriExposedException 包装成 PlatformException）；预期走 FileProvider content:// URI 正常打开
- 修复：MainActivity.kt 注册 MethodChannel `com.silentreader.hermes_ui/file_share`（getShareUri → FileProvider.getUriForFile，authority `<appId>.provider` 复用既有 provider_paths.xml external-path）；Dart 侧 `_androidContentUriFor` 换取 content:// 后再发 ACTION_VIEW，通道失败兜底回 file://；build.gradle.kts 补 `androidx.core:core-ktx:1.13.1`
- 验收：真机下载 png/apk 点「打开」→ 系统应用正常接管；Windows 行为不变（explorer /select）

---

### #66 [P1→已修复待真机复验] 图片预览双指缩放被困小图区域，无法铺满全屏
- 位置：`lib/features/chat/widgets/chat_media_view.dart` AttachmentLightbox 图片分支（原 `Center > InteractiveViewer > Image(contain)`）+ `lib/features/workspace_manager/file_preview_page.dart` 图片 sliver 同款结构
- 复现：打开一张小于屏幕的图片（如 100×100 于 1000×1000 屏）→ 双指放大 → 内容放大了但仍被限制在初始小框内，四周黑边不利用全屏
- 根因（探针实锤）：InteractiveViewer 的 ClipRect 采用自身盒子尺寸；Center 给松约束时其盒子收缩为子图自然尺寸（探针测得 viewerSize=0×476 于 1x1 图），放大内容被裁回小框
- 修复：两处改 `SizedBox.expand` 紧约束钉满视口（Lightbox=Expanded+SizedBox.expand；工作区=SliverFillRemaining(hasScrollBody:false)+SizedBox.expand），子 Image 均 BoxFit.contain 初始仍 contain 铺满
- 验收：小图打开后双指放大可铺满全屏并可平移；大图行为不变；回归断言 viewerSize.width==800 已入 chat_media_bubble_test + file_preview_page_test（stash RED 校验通过）

---

### #67 [P1→已修复待真机复验] 用户消息双气泡复发：服务端同回合落两条 user 投影行
- 位置：`lib/features/chat/chat_diff_merge.dart`（新增 `_dedupeServerUserMessages` 预处理）
- 复现：WebUI 发带附件消息 → Flutter 客户端该回合用户消息出现两条气泡，第一条正常、第二条为未解析注入原文
- 根因（实证 会话 4dea67e97b65）：**非发送侧问题**——state.db 权威库只有一条（id 165170）；webui session JSON 同 timestamp（1788605380.6545517 完全相等）写两条 user 行：idx137 解析版（带 id=141+attachments+`_db_persisted`，注入标记已剥）+ idx138 注入原文版（无 id）。客户端乐观消息只能匹配一条，另一条被当缺失项补入 → 双气泡。#61 归一化匹配本身命中 idx137，漏的是**服务端自身双投影**这一新形态
- 修复：diff-merge 入口对 serverMessages 预处理——相邻 user 行 ts 相同（±0.5s）且归一化内容相等 → 仅保留带权威 id 的一条（权威行在前在后都保留它）
- 验收：回归测试 chat_diff_merge_user_injection_test 新增 5 例（RED 复现/local 空/不误伤异内容/不误伤 >0.5s 连发/权威行顺序无关）全绿；真机复验双气泡消失

---

### #68 [P2→已修复待真机复验] 回合折叠胶囊左缩进比工具卡大，图标不对齐
- 位置：`lib/features/chat/widgets/collapsible_process_capsule.dart` header `EdgeInsets.only(left:)`
- 复现：展开回合胶囊 → 胶囊「过程 ·」行的空心蓝节点 与 内部工具卡组卡绿勾 左缘不齐，节点明显更靠右（截图目测差 ~6 逻辑px）
- 根因（像素实测 DPR=3）：绿勾左缘 = 列表 pad 12 + 卡内 pad 10 + Icon 内缩 ≈ 24.5；节点左缘 = 12 + header pad 17 + (10-7)/2 = 28.5 → 差 6px
- 修复：header left padding 17→11，节点左缘 12+11+1.5=24.5 与绿勾对齐（轨线 rail 仍在 0-10 区不冲突）
- 验收：真机看展开态节点与卡图标垂直对齐；金照若受影响 `--update-goldens`

---

### #69 [P1→已修复待真机复验] 下载列表进度恒 0%→直接 100%，无中间过程
- 位置：`lib/core/api/api_client.dart` `downloadData`/`_fetchWithRedirects`/`_buildOptions` + `lib/features/downloads/download_providers.dart` `downloadDownloaderProvider` + `lib/features/downloads/download_controller.dart` worker 下载分支
- 复现：下载较大文件（如 apk）→ 下载页任务进度条一直 0%，最后瞬间跳 100%（或直接失败）
- 根因：dio `ResponseType.bytes` 全量缓冲到内存才返回，执行器 `downloadData` 从未传 `onReceiveProgress`，控制器等 `await` 完成才一次性置 completed → `receivedBytes` 全程 0
- 修复：`downloadData` 增 `onReceiveProgress` 参数透传至 `RequestOptions`；`downloadDownloaderProvider` 签名改 typedef `DownloadBytesDownloader`（带可选 `onProgress`）；controller 下载分支回调里节流（≥100ms 或 ≥1% 增量）刷 `receivedBytes`/`expectedBytes`（total>0 顺带补分母）；4 个测试注入点 lambda 同步
- 验收：回归测试 download_controller_test 新增 2 例（中途回调刷 50%+downloading/total 未知仍刷 receivedBytes）；真机下载大文件看进度条平滑推进

---

### #70 [P1→已修复待真机复验] live 会话刷新闪现回合折叠胶囊，过一会自动消失
- 位置：`lib/features/chat/widgets/chat_message_list.dart` `isTurnCompleted` 判定（原 :1780-1784）
- 复现：会话正在生成（live）→ 下拉刷新/重进 → 最后回合突然变成折叠胶囊 → 数秒后又自动展开消失
- 根因：`isTurnCompleted` 只看 `streaming==null && phase∉{streaming,sending}`，存在两个误判窗口：① 缓存回放态（网络未回先铺缓存 `isViewingCachedData=true`，phase=idle、activeStreamId=null，缓存里进行中回合被当已完成）；② 流仍活跃但相位非 streaming（recovering/steered 等）
- 修复：`isTurnCompleted` 追加 `!hasActiveStream && !isViewingCachedData` 双门控（activeStreamId 是流的权威信号；done 收尾会清 activeStreamId → 正常完成后胶囊照常出现，无误伤）
- 验收：回归测试 turn_collapse_test 新增用例 8（缓存回放态不闪胶囊；stash RED 校验通过）；用例 6（streaming 不折叠）与用例 1（历史完成回合正常折叠）不回归；真机复验 live 刷新不闪

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

### #72 [P2 未修复] App 冷启动 sidecar 未就绪窗口期弹模态「操作失败·离线缓存」
- 位置：启动链 sidecar 拉起（`webui_sidecar_service` start 异步）与会话列表首刷（`desktop_lifecycle_observer` / connections 激活）时序竞争
- 复现（E2E 实证）：已配置内置连接后重启 hermes_ui.exe → 首帧会话列表请求打到尚未 LISTENING 的 :8787 → 中央模态「操作失败 离线缓存：当前显示最近缓存的会话」需手点「好」；数秒后 sidecar 就绪列表自动恢复（截图 20/24）
- 现状 vs 预期：现状=新用户每次冷启动见红色报错弹窗；预期=内置连接冷启动静默宽限（3~5s 轮询 health）或降级为轻量 toast，就绪后自动刷新
- 验收：杀 app 重启 ×3 无模态报错弹窗；手动断网场景离线提示仍可见（不吞真错误）；回归单测覆盖宽限逻辑

---
