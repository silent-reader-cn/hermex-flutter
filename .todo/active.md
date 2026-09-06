# Hermes UI TODO — Active（进行中队列 · 完整规格）

> **规则**：
> 1. 新增任务直接在【本文件】写完整规格（位置/范围/复现/现状vs预期/验收），不写日期文件。
> 2. 条目完成收口 → 将完整条目【誊写】到完成当天日期文件 `.todo/YYYYMMDD.md`（不存在则新建)，标题标 `[已收口]` 作归档备份；随后从本文件移除该条。
> 3. 本文件只保留未收口任务，收口即清出。

---

（#56-#63 已全部收口誊写至 `.todo/20260905.md`；#64 胶囊方案 E 已收口至 `.todo/20260905.md`；#65-#70 六条已收口誊写至 `.todo/20260906.md`）

---

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

---

---

---

### #74 [P2 未修复·未开工] PC 桌面滚轮向上滚动立即被拉回底部：手势状态机无鼠标滚轮分支（只适配了触摸屏）
- 位置：`lib/features/chat/widgets/chat_message_list.dart` 手势状态机 `NotificationListener<ScrollNotification>`（:1972-2031）+ 跟随执行器三处（streamingScrollTrigger 监听 :424-432、`_onMetricsChanged` :590-612、`_onScroll` 自动跟底分支 :644-647）+ `_nearBottomThreshold = 80`（:152）+ `_dragSensitivityThreshold = 8`（:294）
- 复现（2026-09-06 主人真机反馈，Windows 桌面宽屏）：底部跟随开启（live 流式中或刚发送）→ 鼠标滚轮向上滚（小幅/慢滚必现）→ 视口立即被拉回底部，无法离底阅读；触摸屏拖动正常（已有 8px 阈值适配）
- 现状 vs 预期：现状 = 滚轮被判定为「非用户交互」，跟随状态永不取消，每条 token 都把视口拽回底；预期 = 滚轮与触摸一视同仁——上滚累计超敏感阈值即 `_userHasScrolled=true` 取消跟随、显示回底按钮，滚回底部或点按钮才恢复跟随
- 根因（源码行号实证）：鼠标滚轮走 `PointerScrollEvent → ScrollPosition.pointerScroll()` 协议，其 `ScrollUpdateNotification` 带 `scrollDelta` 但 **`dragDetails` 恒 null**、`_isGestureActive` 恒 false（`ScrollStartNotification.dragDetails` 也 null，:1974-1981 不置位）→ 状态机唯一入口 `dragDetails != null || _isGestureActive`（:1993）对滚轮恒 false → `_dragDisplacement` 永不累计 → `_userHasScrolled`/`_nearBottom=false` 永不生效；`UserScrollNotification` 设的 `_isUserInteracting`（:1989-1991）只在滚轮事件 burst 同帧内瞬时为 true，`ScrollEnd`（:2023-2028，`_isGestureActive` false）立即清除 → burst 间隙 token 一到，`streamingScrollTrigger`（:429 守卫全过）与 `_onMetricsChanged`（:594-603 守卫全过 → `_settleJumpToBottom`）即拉回底部；80px 贴底阈值内的小幅上滚 `_nearBottom` 保持 true，任何跟随路径都无需额外条件即拽回
- 修复方案（待拍板后开工）：
  - 主案（指纹扩展，零新组件）：`ScrollUpdateNotification` 分支（:1992）增加滚轮指纹——`scrollDelta != null && dragDetails == null && !_isGestureActive` 且**方向向上（scrollDelta < 0）** → 计入 `_dragDisplacement`，超 8px 置 `_userHasScrolled=true + _nearBottom=false`（复用既有取消链 ：2002-2021，含 `_pinnedTranscriptCount` 快照）。向上为负的门控天然排除程序化向下跳底（jumpTo/animateTo 时 scrollDelta 向下为正）
  - 防误判门控：程序化滚动在途旗标（`_isAnimatingToBottom`/`_isOutlineJumping`/`_jumpSettling`/`_restoringOlderPosition`/`_initialPositioning`）期间不计入位移（与 :2006-2008 既有守卫对齐）
  - 恢复路径零改动：滚回底部走 `_onScroll` nearBottom 分支（:626-638，`distFromBottom <= 1.0` 恒可复位）+ 回底按钮（`showScrollToBottomButton`），与触摸语义一致
- 验收：①widget 测试 `tester.sendEventToBinding(PointerScrollEvent(...))` 滚轮上滚累计 ≥8px → `_userHasScrolled=true`、下一条 token 事件不跳底（streamingScrollTrigger 不触发 jump）、回底按钮出现；②滚轮滚回底部 → 跟随恢复、下一条 token 正常跟底；③触摸拖动取消跟随的现有测试不回归（#41 语义不变）；④内容撑高型 ScrollUpdate（scrollDelta 为 null）不误判（现有 :1996-1999 分支天然排除）；⑤真机 Windows 复验：live 中滚轮上滚可离底阅读、右下角回底按钮可用
- 备注：主人指示与 #73 同批先落盘不修复；#56 离底阅读锚点抖动防护（a64d488）与本条正交，取消跟随瞬间 `_readingAnchor` 由 `_resetAnchorStabilityState()` 既有链路清理

---
