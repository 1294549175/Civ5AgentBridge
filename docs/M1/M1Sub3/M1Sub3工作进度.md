# M1Sub3（调度控制子模块 `CAB_Dispatcher`）工作进度与多会话交接记录

> [!NOTE]
> 本文档用于跨会话追踪 **M1Sub3：调度控制子模块（`CAB_Dispatcher`）** 的计划确认、分工作包编码、四模块离线联调与真机冒烟验收进度。后续每个协作会话开始前应首先阅读本文档定位当前工作包与交接上下文，完成后就地更新对应状态与会话日志。
>
> **红线提醒**：本子模块全过程**严禁持久化修改**上位三文档（`docs/M1/模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）、顶层《01~03》文档、已验收的 M1Sub1 / M1Sub2 交付物（`CAB_Config.lua`、`CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua` 及 `tests/m1sub1/*`、`tests/m1sub2/*`）以及现有 Mod 壳层文件（`Civ5AgentBridgeUI.lua/.xml`、`.modinfo`、`deploy_mod.ps1` 等）。全部需同步回写上位文档的事项，统一先登记于本文档「四、待上级评审回写的文档偏离与增补台账」，最终于 WP4 汇总至《M1Sub3工作总结报告.md》。

---

## 一、 当前总览看板

| 项目 | 当前状态 |
| :--- | :--- |
| **所属上级模块** | 模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`） |
| **本子模块范围** | 子模块 3：调度控制子模块核心（`mod/Lua/CAB_Dispatcher.lua` + 独立四模块联调测试套件 `tests/run_m1sub3_tests.py` & `tests/m1sub3/*`） |
| **前置可启动性评估** | ✅ **可立即启动**（`CAB_Config`、`CAB_InfoCollector`、`CAB_TaskExecutor` 均已于 2026-11-27 验收通过；未交付的 `CAB_ExternalIO` 经守卫式按需 `include` 与标准契约桩解耦） |
| **总体阶段** | ✅ **全部开发与双层验收已完成（`WP1` ~ `WP5` 全闭环，已产出结项总结报告，待上级 M1 评审验收）**（20 项 IPC 路由、8 类异步结算与三大硬阻塞全栈能力均通过三套件 107/107 离线总回归及两轮原生 BNW+IGE 真机全链路实证，全部临时挂载改动已 100% 回滚） |
| **当前待执行工作包** | **无（M1Sub3 全量闭环，待上级 M1 评审验收并回写 `SYNC-M3-01` ~ `SYNC-M3-05`，下一子模块启动 M1Sub4 `CAB_ExternalIO`）** |
| **最近一次测试结果** | ✅ **全绿（回滚后离线三套件 107/107 + 两轮真机双闭环）**（2026-11-27：最终回滚后离线 M1Sub1 `40/40`、M1Sub2 `38/38`、M1Sub3 `29/29` 全部退出码 `0`、红线违规 `0`；WP4 真机 `17/17 PASS` `Lua.log` 629 行 0 报错；WP5 真机零手工点击纯 RPC 解除科研/政策/晋升三大硬阻塞并完成 `Turn 0 → Turn 1`，`Lua.log` 655 行 0 报错） |

---

## 二、 决策确认登记表（来自 2026-11-27 `/grill-me` 设计对齐）

| 编号 | 决策要点 | 已确认方案 | 状态 |
| :---: | :--- | :--- | :---: |
| **D-01** | 交付边界与文件隔离 | 纯调度核隔离交付（仅持久化产出 `mod/Lua/CAB_Dispatcher.lua`、`tests/run_m1sub3_tests.py`、`tests/m1sub3/*` 及 `docs/M1/M1Sub3/*`）；不动上位文档、前序已验收文件及 UI/`.modinfo` 壳层；WP4 临时真机冒烟后 100% 回滚，UI 重构与 `.modinfo` 正式装配留待子模块 4（`CAB_ExternalIO`）完成后统一收口 | ✅ 已确认 |
| **D-02** | 跨子模块依赖加载 | 顶部采用 `if CAB_X == nil then include("...") end` 守卫式按需加载四模块（防 Civ5 VFS 重复执行重置 `local` 状态，支持测试桩预注入 `CAB_ExternalIO` 后续零改代码）；`CAB_Dispatcher.Initialize` 严格自检全部依赖导出表与下游 `Initialize` 返回值 | ✅ 已确认 |
| **D-03** | 非活动回合门控白名单 | 对齐《模块设计说明.md》§3.3 并排除选区副作用：`AI_TURN_LOCKED` 或 `not IsTurnActive()` 时放行 `ping`、`test_large_payload`、`get_end_turn_status`、`get_empire_economy`、`get_visibility_summary`、`get_turn_overview`、`get_city_detail` 共 7 项；拦截全部 6 个写指令与需临时切换 UI 选区的 `get_unit_context` | ✅ 已确认 |
| **D-04** | RPC 响应信封保真映射 | 协议/门控/入参错误、`CAB_Collector` 含 `error` 字段结果、以及写动作前置校验失败（`baselineContext == nil`）统一返 `ok = false`；`end_turn(BLOCKED)`（携带 `blocking_info` 与 `auto_skipped_unit_ids`）及 `FinalizeActionSettlement` 结算结果统一返 `ok = true, data = resultDto`，避免 Python `sqlite_bridge.py` 抛异常丢失诊断详情；仅当 `turn_ended == true` 时切入 `AI_TURN_LOCKED` | ✅ 已确认 |
| **D-05** | 异步结算防死锁与原型清理 | `WAITING_SETTLEMENT` 期间若遇 `TurnEnd` / `TurnStart` / 重初始化，先 `pcall(FinalizeActionSettlement)` 刷写 `SendRpcResponse`（异常降级写中断错返）再清空槽位，杜绝客户端 8s 死等；挂起期重入新请求立返 Busy 错误不破坏在途结算；`execute_unit_action` 支持 `settle_delay_sec` 钳制于 `[0, MAX_SETTLE_TIMEOUT_SEC]` 统一走帧结算，退役原型 `sync_frame_comparison` | ✅ 已确认 |
| **D-06** | 导出可观测性与手动同步 | 导出《模块内部接口设计.md》§六 全部 6 个入口函数 + 第 7 个纯只读诊断快照 `CAB_Dispatcher.GetRuntimeState()`；`OnManualSyncClicked` 仅在活动回合且 `IDLE` 态导出快照且**不递增 `s_TurnEventSeq`**，挂起或 AI 回合点击仅更新 UI 提示不脏写快照 | ✅ 已确认 |
| **D-07** | 文档命名、WP 拆分与会话边界 | 对齐前序目录命名为 `M1Sub3工作计划.md` / `M1Sub3工作进度.md` / `M1Sub3工作总结报告.md`；`WP1`~`WP4` 完成 14 项既有 IPC 离线+真机闭环，按 `D-08` 追加 `WP5` 后统一产出最终总结报告 | ✅ 已确认 |
| **D-08** | `WP5` 增补三大硬阻塞设置功能（2026-11-27） | 经用户在 `WP4` 真机验收后拍板新增 `WP5`（交由新会话执行）：完整实现**科研选择（`ENDTURN_BLOCKING_RESEARCH`）**、**社会政策（`ENDTURN_BLOCKING_POLICY`）**与**单位晋升（`ENDTURN_BLOCKING_UNIT_PROMOTION`）**的只读查询 + 安全写动作 + IPC 路由 + 同步离线/真机测试；特批 `WP5` 按需向后兼容增量扩充 `CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua`、`CAB_Dispatcher.lua` 及三套测试，仍严禁修改 `docs/M1/` 上位三文档与 Mod 壳层，新契约登记于 `SYNC-M3-05` | ✅ 已确认 |

---

## 三、 工作包进度追踪表（`WP1` ~ `WP5`）

| 编号 | 工作包名称 | 计划涉及文件 | 状态 | 实测摘要（通过/失败/红线审计） | 完成日期 |
| :---: | :--- | :--- | :---: | :--- | :---: |
| **Plan** | 编制 M1Sub3 工作计划与进度文档 | `docs/M1/M1Sub3/M1Sub3工作计划.md`<br>`docs/M1/M1Sub3/M1Sub3工作进度.md` | ✅ 已完成 | 已完成 `D-01` ~ `D-07` 全分支访谈对齐，计划与进度两份文档已落盘待用户审阅确认 | 2026-11-27 |
| **WP1** | 四模块联调测试底座（含 `CAB_ExternalIO` 契约桩）+ `CAB_Dispatcher` 骨架、初始化与生命周期事件 | `tests/run_m1sub3_tests.py`<br>`tests/m1sub3/engine_stubs.lua`<br>`tests/m1sub3/test_dispatcher.lua`<br>`mod/Lua/CAB_Dispatcher.lua` | ✅ 已完成 | 语法 `10/10` + 3 项负向自检通过；桩测试 `12/12`（`T-00`~`T-11`）通过，红线违规 `0`、桩未实现 `0`；外部 IO 审计（态势 `15` / 心跳 `24` / RPC `3` / 轮询 `3`）；M1Sub2 `33/33` & M1Sub1 `36/36` 零回归 | 2026-11-27 |
| **WP2** | `OnExternalRequestReceived` 全量 14 项 IPC 路由、AI 门控白名单与信封保真映射 | `mod/Lua/CAB_Dispatcher.lua`<br>`tests/m1sub3/test_dispatcher.lua` | ✅ 已完成 | 语法 `10/10` + 3 项负向自检通过；桩测试 `18/18`（`T-00`~`T-17`）通过，红线违规 `0`、桩未实现 `0`、有效写操作 `14`；外部 IO 审计（态势 `31` / 心跳 `43` / RPC `69` / 轮询 `3`）；M1Sub2 `33/33` & M1Sub1 `36/36` 零回归 | 2026-11-27 |
| **WP3** | `OnFrameUpdate` 5 类异步结算推进、跨回合抢占防死锁、异常自愈与轮询/心跳节流 | `mod/Lua/CAB_Dispatcher.lua`<br>`tests/m1sub3/test_dispatcher.lua` | ✅ 已完成 | 语法 `10/10` + 3 项负向自检通过；桩测试 `25/25`（`T-00`~`T-24`）通过，红线违规 `0`、桩未实现 `0`、有效写操作 `41`；外部 IO 审计（态势 `60` / 心跳 `81` / RPC `100` / 轮询 `38`）；M1Sub2 `33/33` & M1Sub1 `36/36` 零回归 | 2026-11-27 |
| **WP4** | 14 项基础 IPC 三套件离线总验收 + 原生 BNW/IGE 临时真机冒烟回滚 + WP5 方案修订 | 临时挂载验证并 100% 回滚<br>更新 `docs/M1/M1Sub3/M1Sub3工作计划.md`<br>更新 `docs/M1/M1Sub3/M1Sub3工作进度.md` | ✅ 已完成 | 离线三套件回滚前后均 100% 全绿（M1Sub3 `25/25`、M1Sub2 `33/33`、M1Sub1 `36/36`）；原生 BNW v1.0.3.279 + IGE 真机全链路冒烟 `17/17 PASS / 0 FAIL`（覆盖首帧推送、14 项 IPC、32KB 11 分片、5 类异步结算零超时、手动同步护栏、AI 回合门控拦截与 `Turn 0 → Turn 1` 自动推送），`Logs/Lua.log` 629 行 0 报错；临时文件 100% 回滚并清理全部 5 个缓存库 | 2026-11-27 |
| **WP5** | （`D-08` 增补）科研选择、社会政策、单位晋升三大硬阻塞查询/设置能力 + 同步离线/真机测试 + 最终结项总结报告 | 增量扩充 `CAB_InfoCollector.lua` / `CAB_TaskExecutor.lua` / `CAB_Dispatcher.lua` 及三套测试<br>临时真机冒烟并 100% 回滚<br>新建 `docs/M1/M1Sub3/M1Sub3工作总结报告.md` | ✅ 已完成 | 离线三套件回滚前后 100% 全绿（M1Sub1 `40/40`、M1Sub2 `38/38`、M1Sub3 `29/29`，合计 `107/107`，红线违规 `0`）；原生 BNW v1.0.3.279 + IGE 真机实证零手工点击纯 RPC 解除科研/政策/晋升三大硬阻塞并推进 `Turn 0 → Turn 1` + AI 门控验证，`Logs/Lua.log` 655 行 0 报错；临时挂载 100% 回滚并清理全部 5 个缓存库；已产出最终《M1Sub3工作总结报告.md》 | 2026-11-27 |

---

## 四、 待上级评审回写的文档偏离与增补台账

> 本台账记录相对 `docs/M1/` 三份上位文档的**口径消歧项、防死锁加固项与诊断接口增补项**，严禁在 M1Sub3 期间直接修改上位文档，待 WP4 汇总至《M1Sub3工作总结报告.md》由上级 M1 评审验收后统一回写：

| 台账编号 | 涉及上位文档与章节 | 类型 | 内容摘要 | 对应决策 |
| :---: | :--- | :---: | :--- | :---: |
| **SYNC-M3-01** | `模块内部接口设计.md` §六 `OnExternalRequestReceived` | 口径消歧 | 对齐《模块设计说明.md》§3.3 与实机选区安全边界：将非活动回合（`AI_TURN_LOCKED` / `not IsTurnActive`）放行白名单由原“仅 `ping` / `get_end_turn_status`”统一修订为放行 7 项无选区副作用只读/诊断方法（`ping`、`test_large_payload`、`get_end_turn_status`、`get_empire_economy`、`get_visibility_summary`、`get_turn_overview`、`get_city_detail`），拦截 6 个写指令及需临时切换 UI 选区的 `get_unit_context`。 | D-03 |
| **SYNC-M3-02** | `模块内部接口设计.md` §六 & `模块设计说明.md` §3.3 | 加固 / 增补 | 1. 增补第 7 个纯只读诊断快照函数 `CAB_Dispatcher.GetRuntimeState() -> table`（含挂起态只读标量 `pending_elapsed_sec` / `pending_min_wait_sec` / `pending_max_timeout_sec`）；<br>2. 将跨回合清理 `s_PendingSettlement` 细化为“先 `pcall(FinalizeActionSettlement)` 刷写 `SendRpcResponse` 再清槽位”的抢占防死锁机制；<br>3. 明确 `OnManualSyncClicked` 在挂起/AI 回合态不覆写快照且合法导出时不递增 `s_TurnEventSeq`；<br>4. 补充 `AI_TURN_LOCKED` 锁定来源元信息防 `end_turn` 后窗口期误解锁与读档/IGE 切人自校准规则；<br>5. 明确 `OnFrameUpdate` 单帧结算步进钳制 `0.50s`（`S-06`）与 `1e-9` 浮点累加容差防 IEEE-754 漂移。 | D-05、D-06 |
| **SYNC-M3-03** | `模块内部接口设计.md` §1.1、§六、§七 | 细化 | 1. 在 §1.1 补充 Civ5 VFS 守卫式按需 `include` 规范（防止重复 `include` 重置子模块 `local` 状态）；<br>2. 明确 `end_turn` 返回 `status = "BLOCKED"` 时以 `ok = true, data = EndTurnResultDTO` 保真回传（不触发 `AI_TURN_LOCKED`），以及 `execute_unit_action` 正式退役 EXP-04 遗留字段 `sync_frame_comparison`。 | D-02、D-04、D-05 |
| **SYNC-M3-04** | `模块设计进度.md` §三 `M1-S5` | 进度拆分同步 | 记录 `M1-S5` 中核心调度器 `CAB_Dispatcher.lua` 及四模块联调测试由 M1Sub3 独立交付验收；剩余 `Civ5AgentBridgeUI.lua` 壳层精简与 `.modinfo` 部署收口待子模块 4（`CAB_ExternalIO`）验收后一键合龙。 | D-01 |
| **SYNC-M3-05** | `模块内部接口设计.md` §四、§五、§六、§七 & `模块设计说明.md` §3.1~§3.3 | 能力增补（WP5 已定稿） | 1. 采集层（`14 → 17`）：新增 `GetResearchOptions`（`F8`）、`GetPolicyOptions`（`F9`，使用原生 `CanUnlockPolicyBranch` 并过滤自动开/关门与未选意识形态分支）、`GetUnitPromotions`（`F10`，纯只读零选区副作用）；<br>2. 执行层（`9 → 12`，`settlementKind` `5 → 8`）：新增 `SetResearchTech`（`E10`/`SET_RESEARCH`）、`AdoptPolicyOrBranch`（`E11`/`ADOPT_POLICY`）、`PromoteUnit`（`E12`/`PROMOTE_UNIT`，`withTempUnitSelection` + `GameInfoActions/HandleAction`），统一纳入 `0.10s` 短延迟异步结算；<br>3. 调度层（`14 → 20` 项 IPC）：新增 3 项只读查询（全部入 AI 白名单，白名单 `7 → 10`）与 3 项写路由（`set_research_tech`/`adopt_policy`/`promote_unit`，AI 回合严格拦截）；<br>4. 实机发现建议：M1Sub4 `CAB_ExternalIO` 分片需对齐 UTF-8 首字节防截断中文字符，且 Python 侧应按 `bytes` 拼片后解码；`ExecuteEndTurn(autoSkip=true)` 的 `MISSION_SKIP` 跨帧落地。 | D-08 |

---

## 五、 跨会话交接日志（Session Log）

### Session 0 — 2026-11-27（M1Sub3 任务分解细化与 `/grill-me` 设计决策对齐会话）
* **完成工作**：
  1. 完整研读 `docs/M1/` 三份上位设计文档（含已同步的 `SYNC-01`~`SYNC-05` 与 `SYNC-M2-01`~`SYNC-M2-06`）、`docs/03_接口设计说明书.md`、前序 M1Sub1 / M1Sub2 工作计划与源码（`CAB_Config.lua`、`CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua`）、原型壳层（`Civ5AgentBridgeUI.lua/.xml`、`Civ5AgentBridgeLoader.lua/.xml`、`Civ5AgentBridgeJson.lua`、`.modinfo`）及 Python 侧 `sqlite_bridge.py` / `bridge_service.py` / `mock_sandbox.py`；
  2. 定位并核清 3 项关键工程依赖与跨文档细节：① 子模块 4（`CAB_ExternalIO.lua`）尚未创建，需以守卫式按需 `include` + 契约桩隔离交付 `CAB_Dispatcher.lua`；② 上位两份文档关于 `AI_TURN_LOCKED` 只读查询放行范围存在口径差异且 `get_unit_context` 含临时选区副作用；③ Python `sqlite_bridge.py` 在 `ok=false` 时会直接抛异常丢弃 `data`，`end_turn(BLOCKED)` 需采用 `ok=true + EndTurnResultDTO` 保真透传 `blocking_info`；
  3. 经 `/grill-me` 逐分支访谈，与用户最终确认全部 7 项核心设计决策（`D-01` ~ `D-07`），并预登记 `SYNC-M3-01` ~ `SYNC-M3-04` 待回写台账；
  4. 创建 `docs/M1/M1Sub3/` 目录并编写完成《M1Sub3工作计划.md》与《M1Sub3工作进度.md》（严守隔离红线，零触碰上位文档与任何代码/测试文件）。
* **当前卡点 / 交接给下一会话**：
  * **等待用户审阅确认《M1Sub3工作计划.md》**（若无修改意见，下一会话可直接开干）。
  * 下一会话启动 **`WP1`** 时的具体执行清单：
    1. 新建 `tests/run_m1sub3_tests.py`：对接本机 Python + `lupa.lua51`，实现三阶段验收入口（阶段 1 编译检查原型 + M1Sub1 + M1Sub2 + M1Sub3 全部 Lua 文件 + 3 项负向语法自检；阶段 2 运行四模块联调桩测试并支持 `--filter`；阶段 3 输出守卫审计统计并返回退出码 `0/1/2`）；
    2. 新建 `tests/m1sub3/engine_stubs.lua`（零修改 `tests/m1sub1/*` 与 `tests/m1sub2/*`）：构建独立有状态 BNW 引擎桩 + 100% 符合《模块内部接口设计.md》§三 的 `CAB_ExternalIO` 标准契约模拟桩（维护模拟入站队列、记录 `PushTurnOverview` / `WriteHeartbeat` / `SendRpcResponse` 调用历史、支持注入初始化失败或回调异常，并审计红线 S-01 违规调用），真实加载 `CAB_Config.lua` + `CAB_InfoCollector.lua` + `CAB_TaskExecutor.lua` + `CAB_Dispatcher.lua`；
    3. 新建 `mod/Lua/CAB_Dispatcher.lua` 骨架：实现守卫式按需 `include`、唯一全局导出表 `CAB_Dispatcher`、内部抢占刷写辅助骨架、`D1: Initialize(uiStatusCallback)`、`D7: GetRuntimeState()`、`D2: OnActivePlayerTurnStart()`、`D3: OnActivePlayerTurnEnd()`、`D4: OnManualSyncClicked()`（为 `D5`/`D6` 预留清晰入口桩以便 `D1` 绑定回调并通过契约校验）；
    4. 新建 `tests/m1sub3/test_dispatcher.lua` 编写 WP1 验收用例（加载洁净与静态红线扫查、守卫式 `include` 防重复重置验证、依赖缺失拦截、活动/非活动回合双态初始化、`TurnStart`/`TurnEnd` 流转与 `s_TurnEventSeq` 递增、`OnManualSyncClicked` 护栏），跑通 `python Civ5AgentBridge/tests/run_m1sub3_tests.py` 全绿后更新本进度表交接至 `WP2`。

### Session 1 — 2026-11-27（WP1：四模块联调测试底座 + `CAB_Dispatcher` 骨架、初始化与回合生命周期事件）
* **完成工作**：
  1. 新建 `tests/run_m1sub3_tests.py`：对接本机 Python + `lupa.lua51`，完成全量 10 个 Lua 文件（原型 4 + M1Sub1 2 + M1Sub2 1 + M1Sub3 3）的 Lua 5.1 语法编译检查、3 项负向语法自检（普通语法错误、`goto`、`//`）、`--filter` 用例过滤，以及红线守卫与外部 IO 调用审计汇总；
  2. 新建 `tests/m1sub3/engine_stubs.lua`：独立构建完整有状态 BNW Lua 5.1 引擎桩、新增 `Modding.OpenUserData`（红线 `S-01`）陷阱守卫，内置 100% 对齐《模块内部接口设计.md》§三 的 `CAB_ExternalIO` 标准契约模拟桩（7 项接口、深拷贝历史记录、入站队列、按 `req_id` 响应归档与故障注入开关），实现真实加载 `CAB_Config` + `CAB_InfoCollector` + `CAB_TaskExecutor` + `CAB_Dispatcher` 四模块闭环；
  3. 新建 `mod/Lua/CAB_Dispatcher.lua`：完成守卫式按需 `include`（`D-02`）、7 个私有 `local` 状态变量、精确 7 项公开导出（`D1`~`D7`）、`flushPendingSettlement` 跨回合抢占刷写防死锁骨架、`D1: Initialize`（含四模块全量契约自检与活动/非活动回合双态分流）、`D2: OnActivePlayerTurnStart`、`D3: OnActivePlayerTurnEnd`、`D4: OnManualSyncClicked`（含 `S-05` 状态护栏与 `s_TurnEventSeq` 隔离）、`D7: GetRuntimeState`（浅拷贝只读快照），以及 `D5` / `D6` 安全占位入口；
  4. 新建 `tests/m1sub3/test_dispatcher.lua`：编写 `T-00` ~ `T-11` 共 12 条 WP1 验收用例与 `FW-01` 框架收尾总检，覆盖静态红线 `S-01`、守卫式按需加载、契约桩自检、依赖完整性矩阵、双态初始化、`GetRuntimeState` 只读隔离、UI 回调容错、多回合流转、未初始化空转、手动同步护栏、采集/推送异常降级自愈与 `D5` 占位防御。
* **验收实测摘要**：
  * `python Civ5AgentBridge/tests/run_m1sub3_tests.py`：语法 `10/10` + 3 项负向自检通过；桩测试 `12/12` 通过；红线违规 `0` 次、桩未实现方法 `0` 次、有效写操作 `0` 次；外部 IO 审计：态势推送 `15` 次、心跳写入 `24` 次、RPC 响应 `3` 次、入站轮询 `3` 次；退出码 `0`。
  * `python Civ5AgentBridge/tests/run_m1sub3_tests.py --filter T-00`：`1/1` 通过，退出码 `0`。
  * 前序回归：`run_m1sub2_tests.py`（`33/33`，退出码 `0`）、`run_m1sub1_tests.py`（`36/36`，退出码 `0`）。
  * `git -C Civ5AgentBridge status --short` 核验：仅新增 `mod/Lua/CAB_Dispatcher.lua`、`tests/run_m1sub3_tests.py`、`tests/m1sub3/*` 及更新 `docs/M1/M1Sub3/M1Sub3工作进度.md`，严守 `D-01` 隔离红线。
* **当前卡点 / 交接给下一会话（启动 `WP2`）**：
  * 无卡点，可直接启动 **`WP2`**：
    1. 在 `mod/Lua/CAB_Dispatcher.lua` 中完整实现 `D5: OnExternalRequestReceived(reqObj)`：包括挂起互斥守卫（`D-05`/`S-03`）、`isActivePlayerTurnNow()` 实时对齐、`D-03`/`S-02` 非活动回合 7 项白名单门控、§4.4 全部 14 个 IPC 方法的入参类型校验与路由分发表、`D-04` 信封保真映射（`end_turn(BLOCKED)` 返 `ok=true` 保持 `IDLE`、`end_turn(WAITING_NEXT_TURN)` 返 `ok=true` 并切入 `AI_TURN_LOCKED` 刷新心跳）、以及 5 类写动作成功下发后装配 `s_PendingSettlement`（含 `execute_unit_action` 的 `settle_delay_sec` 钳制与退役 `sync_frame_comparison`）切入 `WAITING_SETTLEMENT`；
    2. 在 `tests/m1sub3/test_dispatcher.lua` 中扩充 WP2 用例（替换/升级 `T-11` 占位校验为全量 14 方法正向与畸形入参矩阵、AI 回合 14 方法白名单拦截与零下游调用断言、信封保真与 `end_turn` 双分支、5 类写动作挂起槽位装配验证），运行 `run_m1sub3_tests.py` 全绿后更新本进度表交接至 `WP3`。

### Session 2 — 2026-11-27（WP2：`OnExternalRequestReceived` 全量 14 项 IPC 路由、AI 门控白名单与信封保真映射）
* **完成工作**：
  1. 更新 `mod/Lua/CAB_Dispatcher.lua`：
     * 新增锁定来源追踪私有状态（`s_LockedTurnNumber`、`s_LockedPlayerID`、`s_TurnLockObservedInactive`）与 `enterAiTurnLockedState` / `reconcileTurnStateOnRequest`，既支持读档/IGE 切人失步自校准，又防止 `end_turn` / `OnActivePlayerTurnEnd` 刚锁入、引擎尚未翻转 `IsTurnActive()` 窗口期内被误解锁；
     * 完整实现 `D5: CAB_Dispatcher.OnExternalRequestReceived(reqObj)` 及 14 项 `RPC_HANDLERS` 路由分发表，涵盖严格入参类型守卫、`AI_TURN_READONLY_WHITELIST` 7 项非活动回合白名单门控（`D-03`/`S-02`）、`test_large_payload` 512KB 上限钳制与 `forceChunked` 透传、`D-04` 信封保真映射（`CAB_Collector` 含 `error` 转 `ok=false`、`end_turn(BLOCKED)` 返 `ok=true` 保留 `blocking_info` 并维持 `IDLE`、`end_turn(WAITING_NEXT_TURN)` 返 `ok=true` 并即刻切入 `AI_TURN_LOCKED` 刷新心跳）、5 类写动作成功下发后装配 `s_PendingSettlement`（含 `execute_unit_action` 的 `settle_delay_sec` `[0, MAX_SETTLE_TIMEOUT_SEC]` 钳制、`purchase_city_plot` 兼容 `plot_x`/`plot_y` 别名及退役 `sync_frame_comparison`），以及全路由 `pcall` 异常自愈（`S-04`）；
     * 在 `D7: CAB_Dispatcher.GetRuntimeState()` 中增补 `pending_min_wait_sec` 与 `pending_max_timeout_sec` 只读标量诊断字段（空闲态为 `nil`，零私有引用暴露）。
  2. 扩充 `tests/m1sub3/test_dispatcher.lua`：将 `T-11` 升级为协议守卫与异常自愈用例，并新增 `T-12` ~ `T-17` 共 7 条 WP2 验收用例（总计 18 条用例 + `FW-01` 收尾总检），覆盖全部 14 项方法正向与畸形入参、AI 回合 14 方法门控矩阵及零下游调用断言、`end_turn` 三分支与窗口防护、5 类写动作挂起槽位装配与 `settle_delay_sec` 钳制、以及挂起期重入 Busy 拒绝、手动同步护栏与抢占刷写校验。
* **验收实测摘要**：
  * `python Civ5AgentBridge/tests/run_m1sub3_tests.py`：语法 `10/10` + 3 项负向自检通过；桩测试 `18/18`（`T-00`~`T-17`）通过；红线违规 `0` 次、桩未实现方法 `0` 次、有效写操作 `14` 次；外部 IO 审计：态势推送 `31` 次、心跳写入 `43` 次、RPC 响应 `69` 次、入站轮询 `3` 次；退出码 `0`。
  * 前序回归：`run_m1sub2_tests.py`（语法 `9/9`、桩测试 `33/33`，退出码 `0`）、`run_m1sub1_tests.py`（语法 `8/8`、桩测试 `36/36`，退出码 `0`）。
  * `git -C Civ5AgentBridge status --short` 核验：本次仅修改白名单内 `mod/Lua/CAB_Dispatcher.lua`、`tests/m1sub3/test_dispatcher.lua` 及 `docs/M1/M1Sub3/M1Sub3工作进度.md`，零触碰禁止清单文件。
* **当前卡点 / 交接给下一会话（启动 `WP3`）**：
  * 无卡点，可直接启动 **`WP3`**：
    1. 在 `mod/Lua/CAB_Dispatcher.lua` 中完整实现 `D6: CAB_Dispatcher.OnFrameUpdate(deltaTime)`：包含帧间隔净化与单帧步进 `<= 0.50s` 尖峰钳制（`S-06`）、全部 5 类 `settlementKind`（`UNIT_ACTION`、`CITY_ATTACK`、`PURCHASE_ITEM`、`SET_PRODUCTION`、`BUY_PLOT`）异步推进与 `1.50s` 超时兜底（`IsSettlementBusy` + `FinalizeActionSettlement` + `SendRpcResponse` + `pcall` 异常自愈）、挂起期严格暂停 `PollIncomingRequest`（`S-03`）、以及空闲态 `0.20s` 轮询节流与 `2.00s` 心跳节流；
    2. 在 `tests/m1sub3/test_dispatcher.lua` 中扩充 WP3 用例（覆盖 5 类异步帧结算、超时兜底、跨回合 `TurnEnd`/`TurnStart`/重初始化抢占刷写与请求-响应 `1:1` 计数、下游抛异常自愈、畸形/尖峰 `deltaTime` 防护及 `0.20s`/`2.00s` 节流精度），复跑 M1Sub3 + M1Sub2 + M1Sub1 三套件全绿后交接至 `WP4`。

### Session 3 — 2026-11-27（WP3：`OnFrameUpdate` 5 类异步结算推进、跨回合抢占防死锁、异常自愈与轮询/心跳节流）
* **完成工作**：
  1. 更新 `mod/Lua/CAB_Dispatcher.lua`（功能全部收尾）：
     * 新增 `MAX_SETTLE_STEP_SEC = 0.50`（`S-06` 单帧步进上限）与 `TIME_EPSILON = 1e-9`（消除 Lua 5.1 IEEE-754 浮点累加微差）；
     * 新增内部 `local` 辅助函数 `sanitizeDeltaTime`、`safeIsSettlementBusy` 与 `completePendingSettlement`（先清槽、按实时活动回合态恢复 `IDLE` 或 `AI_TURN_LOCKED`、再 `pcall(CAB_Executor.FinalizeActionSettlement)`，遵循 `D-04` 信封保真透传结构化结算 DTO，仅在下层抛错或返回非表时兜底 `ok=false`）；
     * 完整实现 `D6: CAB_Dispatcher.OnFrameUpdate(deltaTime)`：覆盖帧时钟净化、同步期重入防护、5 类 `settlementKind` 两段式/短延迟帧结算与 `1.50s` 硬超时兜底、挂起期严禁 `PollIncomingRequest`（`S-03`）、异常悬空态防御自愈、以及空闲/AI 锁态 `0.20s` 节流轮询与 `2.00s` 周期心跳；
     * 在 `D7: CAB_Dispatcher.GetRuntimeState()` 增补只读标量 `pending_elapsed_sec`（空闲态为 `nil`，零私有引用泄露），同步登记至 `SYNC-M3-02`。
  2. 扩充 `tests/m1sub3/test_dispatcher.lua`：新增第 4 节 `T-18` ~ `T-24` 共 7 组 WP3 验收用例（总计 25 条用例 + `FW-01` 收尾总检），覆盖 `UNIT_ACTION` / `CITY_ATTACK` 忙碌等待与 `settle_delay_sec`、`PURCHASE_ITEM` / `SET_PRODUCTION` / `BUY_PLOT` 延迟队列帧结算、`1.50s` 硬超时与 `D-04` 信封保真、`TurnEnd` / `TurnStart` / `Initialize` 三路径抢占刷写与 `1:1` 幂等回执、畸形/尖峰 `deltaTime` 防护（`S-06`）、全链路故障注入自愈（`S-04`）、IEEE-754 边界节流精度及纯 `OnFrameUpdate` 驱动的端到端 4 指令自动队列闭环。
* **验收实测摘要**：
  * `python Civ5AgentBridge/tests/run_m1sub3_tests.py`：语法 `10/10` + 3 项负向自检通过；桩测试 `25/25`（`T-00`~`T-24`）通过；红线违规 `0` 次、桩未实现方法 `0` 次、有效写操作 `41` 次；外部 IO 审计：态势推送 `60` 次、心跳写入 `81` 次、RPC 响应 `100` 次、入站轮询 `38` 次；退出码 `0`。
  * `python Civ5AgentBridge/tests/run_m1sub3_tests.py --filter T-24`：`1/1` 通过，退出码 `0`。
  * 前序回归：`run_m1sub2_tests.py`（语法 `9/9`、桩测试 `33/33`，退出码 `0`）、`run_m1sub1_tests.py`（语法 `8/8`、桩测试 `36/36`，退出码 `0`）。
  * `git -C Civ5AgentBridge status --short` 核验：仅触碰白名单内 `mod/Lua/CAB_Dispatcher.lua`、`tests/m1sub3/test_dispatcher.lua` 及 `docs/M1/M1Sub3/M1Sub3工作进度.md`，零触碰禁止清单文件与 `engine_stubs.lua` / `run_m1sub3_tests.py`。
* **当前卡点 / 交接给下一会话（启动 `WP4`）**：
  * 无卡点，可直接启动 **`WP4`**：
    1. 独立复跑 `run_m1sub3_tests.py`（`25/25`）、`run_m1sub2_tests.py`（`33/33`）、`run_m1sub1_tests.py`（`36/36`）离线总验收；
    2. 编写极薄 SQLite `CAB_ExternalIO` 临时真机冒烟垫片，配合用户在本机原生《文明5：BNW v1.0.3.279》+ IGE 环境完成真实 `CAB_Dispatcher` 全链路冒烟验证（首帧自动推送、只读查询、5 类写动作跨帧结算、AI 门控拦截、`end_turn` 跨回合自动推送），留存 `Logs/Lua.log` 零报错与 `ModUserData/Civ5AgentBridge-1.db` 量化证据；
    3. 用户退出游戏后 **100% 回滚**全部临时挂载改动并执行 `deploy_mod.ps1 -ForceCopy -ClearCache` 还原部署与缓存，经 `git status` / `git diff` 核验仅留白名单文件；
    4. 产出《M1Sub3工作总结报告.md》（含 `A-01`~`A-10` 逐项对账与 `SYNC-M3-01`~`SYNC-M3-04` 上位文档回写建议书）并更新本进度文档至结项状态。

### Session 4 — 2026-11-27（WP4：离线三套件总验收、原生 BNW+IGE 17/17 真机全链路冒烟与 100% 回滚，及按用户拍板修订方案新增 WP5）
* **完成工作**：
  1. **第一层离线总回归**：独立复跑 `run_m1sub3_tests.py`（语法 `10/10` + 3 负向自检，桩测试 `25/25`，红线违规 `0`，退出码 `0`）、`run_m1sub2_tests.py`（`33/33`，退出码 `0`）、`run_m1sub1_tests.py`（`36/36`，退出码 `0`）；
  2. **第二层原生 BNW v1.0.3.279 + IGE 全链路真机冒烟**：
     * 编写极薄临时 SQLite `CAB_ExternalIO` 垫片 `mod/Lua/CAB_M1Sub3Smoke.lua`（精确实现《模块内部接口设计.md》§三 全部 7 项接口），零修改 `CAB_Dispatcher.lua` 源码，经临时 `Civ5AgentBridgeUI.lua` 先加载 `CAB_M1Sub3Smoke` 再加载 `CAB_Dispatcher`（同时真机实证 `D-02` 守卫式按需 `include`），部署并清理缓存；
     * 通过外部 Python SQLite IPC 驱动脚本直连 `ModUserData/Civ5AgentBridge-1.db`，在本机单人局（中国文明首都北京 + IGE `+2000` 金币 + 首都 2 格内蛮族勇士）完整实证 **17/17 PASS / 0 FAIL**：
       * `L01` 首帧自动推送：`turn=0, turn_seq=1, status="IDLE"/"TURN_SYNCED"`；
       * `L02` 诊断与分片：`ping`（`90.5ms`）、`test_large_payload` 32KB 强制 11 分片（`317.2ms`, `32768/32768` 完整回读）、未知方法与缺参拦截均返 `ok=false`；
       * `L03` 全部 6 项只读查询：`get_turn_overview` / `get_empire_economy` / `get_visibility_summary` / `get_end_turn_status` / `get_city_detail` / `get_unit_context` 全绿（`187~251ms`）；
       * `L04` `end_turn(BLOCKED)` 信封保真（`D-04`）：未设产时返回 `ok=true, status="BLOCKED", turn_ended=false, blocking_type="ENDTURN_BLOCKING_PRODUCTION"`，状态机维持 `"IDLE"`；
       * `L05` 全部 5 类异步动作跨帧结算（零超时，无遗留 `sync_frame_comparison`）：`SET_PRODUCTION`（纪念碑 `109ms queue=1` + 追加工人 `109ms queue=2`）、`PURCHASE_ITEM`（纪念碑 `110ms cost=200` + 工人 `125ms cost=220 spawned_unit_id=24576`）、`BUY_PLOT`（`(32,10)` `109ms cost=65 gold 1580→1515 owner=0`）、`CITY_ATTACK`（炮击 `(32,9)` `360ms` 蛮族 `100→63 HP`）、`UNIT_ACTION`（近战 `(32,9)` `359ms` 我方 `100→81 HP`、蛮族 `63→21 HP`）；
       * `L06` 手动同步护栏（`S-05`）：点击右上角按钮刷新 `Agent: Turn 0 Synced` 且 `turn_seq` 严格保持 `1` 不变；
       * `L07` 跨回合提交、AI 回合门控与 Turn 1 自动推送：`end_turn(auto_skip_ready_units=true)` `246.9ms` 提交成功（同时实证提交当帧 `IsTurnActive()` 尚未翻转的窗口期，被锁定来源追踪精准守住）；紧随其后 AI 锁态下 `get_unit_context` 在 `185.4ms` 被拦截返回 `"Player turn is not active (AI turn in progress)"`，而白名单 `ping` 在 `233.9ms` 正常放行返回 `status="AI_TURN_LOCKED", is_turn_active=false`；`1.8s` 后自动切入 **Turn 1**，`turn_seq` 单调递增至 `2`，`turn_overview_auto` 刷新为 `turn_number=1`，状态机恢复 `"IDLE"`；
     * `Logs/Lua.log` 核验：累计 **629 行，0 条语法错误、0 条运行时错误、0 条堆栈报错**，29 条 `[CAB_*]` 全链路调试日志完整留证；
  3. **100% 临时挂载回滚与缓存还原**：用户退出《文明5》后，执行 `git checkout -- mod/Civ5AgentBridge.modinfo mod/Lua/Civ5AgentBridgeUI.lua`、删除 `mod/Lua/CAB_M1Sub3Smoke.lua`、执行 `deploy_mod.ps1 -ForceCopy -ClearCache` 还原 `MODS/Civ5AgentBridge/` 并清理全部 5 个缓存库，回滚后复跑三套件全部退出码 `0`；
  4. **方案增补修订（`D-08` / 新增 `WP5`）**：用户确认在回滚后扩展方案，将**科研选择（`ENDTURN_BLOCKING_RESEARCH`）**、**社会政策（`ENDTURN_BLOCKING_POLICY`）**与**单位晋升（`ENDTURN_BLOCKING_UNIT_PROMOTION`）**设置功能及同步测试纳入新增的 **`WP5`** 交由新会话完成，已同步修订《M1Sub3工作计划.md》与本文档并预登记 `SYNC-M3-05`。
* **当前卡点 / 交接给下一会话（启动 `WP5`）**：
  * 无卡点，既有 `WP1`~`WP4`（14 项 IPC + 5 类异步结算）已离线+真机双闭环且环境 100% 洁净；
  * 下一会话启动 **`WP5`** 时的具体执行清单：
    1. **第一步（核实原生 BNW API）**：先查阅本机《文明5：BNW》安装目录下的官方 `TechTree.lua` / `TechPopup.lua`、`SocialPolicyPopup.lua`、`UnitPanel.lua`（或已有研究笔记），精确核实以下原生接口签名及是否经 C++ NetMessage 跨帧生效：
       * 科研：`pPlayer:CanResearch(eTech)`、`pPlayer:GetCurrentResearch()`、`pPlayer:GetNumFreeTechs()`、`Network.SendResearch(eTech, iDiscover, iPlayer, bShift)`；
       * 社会政策：`pPlayer:CanAdoptPolicyBranch(eBranch)`、`pPlayer:CanAdoptPolicy(ePolicy)`、`pPlayer:GetNumFreePolicies()`、`pPlayer:GetJONSCulture()`、`pPlayer:GetNextPolicyCost()`、`Network.SendUpdatePolicies(eId, bIsPolicy, bAdopt)`（同步注意意识形态/自由政策分支）；
       * 单位晋升：`pUnit:IsPromotionReady()`、`pUnit:CanAcquirePromotion(ePromotion)`、选区后通过 `GameInfoActions`（`PromotionType`）调用 `Game.HandleAction(iAction)` 或 `Game.SelectionListGameNetMessage`（务必在 `pcall` 下保护并无条件恢复原 UI 选区，严禁触碰 `UI.SetInterfaceMode`）；
    2. **第二步（三模块增量实现，按 `D-08` 严保既有接口零退化）**：
       * `mod/Lua/CAB_InfoCollector.lua`：新增 `GetResearchOptions`、`GetPolicyOptions`、`GetUnitPromotions` 3 个纯只读查询接口（遵循无缓存、DTO 带 `__is_object = true`、结构化错返红线），同步更新 `CAB_Dispatcher.lua` 的 `REQUIRED_COLLECTOR_FUNCS` 依赖自检（或保持向后兼容）；
       * `mod/Lua/CAB_TaskExecutor.lua`：新增 `SetResearchTech`、`AdoptPolicyOrBranch`、`PromoteUnit` 3 个安全写动作接口（严格落实 `E-01` 活动回合门控、`E-02` 前置校验零副作用与选区恢复；若实证需跨帧 NetMessage 落地，统一纳入 `IsSettlementBusy` + `FinalizeActionSettlement` `0.10s` 短延迟异步结算）；
       * `mod/Lua/CAB_Dispatcher.lua`：在 `RPC_HANDLERS` 扩充 6 项方法（`get_research_options`、`set_research_tech`、`get_policy_options`、`adopt_policy`、`get_unit_promotions`、`promote_unit`），更新非活动回合白名单与依赖校验；
    3. **第三步（三套件同步测试 + 原生 BNW/IGE 真机冒烟回滚）**：
       * 同步扩充 `tests/m1sub1/*`、`tests/m1sub2/*`、`tests/m1sub3/*` 引擎桩与专项用例，跑通三套件 100% 全绿；
       * 复用临时 SQLite `CAB_ExternalIO` 垫片模式，配合用户在原生 BNW + IGE 环境下（可用 IGE 加文化/加经验触发三大阻塞）真机实证“零手工点击、纯 RPC 解除科研/政策/晋升三大硬阻塞并完成 `end_turn`”，核验 `Logs/Lua.log` 零报错后 **100% 回滚**临时挂载并清理缓存；
    4. **第四步（最终结项交付）**：编制《`docs/M1/M1Sub3/M1Sub3工作总结报告.md`》（汇总 WP1~WP5 全量离线与真机实证、`A-01`~`A-11` 对账与 `SYNC-M3-01`~`SYNC-M3-05` 回写建议书）并闭环更新本文档。

### Session 5 — 2026-11-27（WP5：三大回合硬阻塞查询与设置全栈实现、三套件离线扩充、原生 BNW+IGE 真机实证回滚与最终结项）
* **完成工作**：
  1. **原生 BNW v1.0.3.279 官方脚本与 DLL 核实**：核查本机安装目录 `TechPopup.lua`、`TechTree.lua`、`SocialPolicyPopup.lua`、`UnitPanel.lua` 与 `CvGameCore_Expansion2.dll` 导出符号，确认分支开启原生 API 为 `CanUnlockPolicyBranch`（非 `CanAdoptPolicyBranch`）、单位晋升查询全部原生只读零选区副作用、以及三类写动作均经跨帧 NetMessage/HandleAction 队列落地，统一采用 `0.10s` 短延迟异步结算；
  2. **三模块向后兼容增量实现（严格遵循 `D-08`）**：
     * `mod/Lua/CAB_InfoCollector.lua`（`14 → 17`）：新增第 6 节 `GetResearchOptions`（`F8`）、`GetPolicyOptions`（`F9`，含已选意识形态信条支持）、`GetUnitPromotions`（`F10`）；
     * `mod/Lua/CAB_TaskExecutor.lua`（`9 → 12`，`settlementKind` `5 → 8`）：新增第 6 节 `SetResearchTech`（`E10`）、`AdoptPolicyOrBranch`（`E11`）、`PromoteUnit`（`E12`，`withTempUnitSelection` + `GameInfoActions/HandleAction`），扩充 `IsSettlementBusy` 与 `FinalizeActionSettlement` 支持 `SET_RESEARCH`/`ADOPT_POLICY`/`PROMOTE_UNIT`（兼容 `PROMOTION_INSTA_HEAL`）；
     * `mod/Lua/CAB_Dispatcher.lua`（精确 7 导出不变，IPC 路由 `14 → 20`）：更新依赖自检与 10 项 `AI_TURN_READONLY_WHITELIST`，新增 `get_research_options`、`set_research_tech`、`get_policy_options`、`adopt_policy`、`get_unit_promotions`、`promote_unit` 路由与参数别名兼容；
  3. **三套件离线自动化扩充与回归**：同步扩充 `tests/m1sub1/*`（`T-36`~`T-39`）、`tests/m1sub2/*`（`T-33`~`T-37`）、`tests/m1sub3/*`（加强 `T-00` 静态红线、升级 `T-14` 至 20 方法门控矩阵、新增 `T-25`~`T-28`）；
  4. **原生 BNW v1.0.3.279 + IGE 全链路真机冒烟与 100% 回滚**：
     * 临时挂载 `CAB_M1Sub3Smoke.lua` 后，在 Player 0（中国，首都北京 + IGE `+300` 文化 + 勇士 16385 `+61` 经验）下**零手工点击任何科研/政策/晋升按钮**，纯 RPC 跑通科研选择与热切换（`TECH_POTTERY` → `TECH_ANIMAL_HUSBANDRY`，`109~110ms`）、社会政策开启传统分支 + 连采 4 项政策（文化 `300→40`，`109~110ms`）、勇士三连晋升（`SHOCK_1→SHOCK_2→SHOCK_3`，等级 `1→4`，`109~110ms`）、设产勇士、跳过待命、`end_turn` 提交、AI 锁态拦截新写方法并放行新只读方法，以及自动推进 `Turn 0 → Turn 1`（`turn_seq=2`）；`Logs/Lua.log` 655 行 0 报错；
     * 真机实证记录两项有价值工程经验并写入 `SYNC-M3-05`：① M1Sub4 `CAB_ExternalIO` 切片需对齐 UTF-8 首字节防截断繁体中文字符（Python 客户端以 `bytes` 拼片后解码）；② `ExecuteEndTurn(autoSkip=true)` 的 `MISSION_SKIP` 跨帧生效；
     * 用户退出《文明5》后执行 `git checkout -- mod/Civ5AgentBridge.modinfo mod/Lua/Civ5AgentBridgeUI.lua`、删除 `mod/Lua/CAB_M1Sub3Smoke.lua`、运行 `deploy_mod.ps1 -ForceCopy -ClearCache` 完成 100% 回滚与缓存还原；
  5. **结项文档交付**：完成《`docs/M1/M1Sub3/M1Sub3工作总结报告.md`》编制（含 `A-01`~`A-11` 对账与 `SYNC-M3-01`~`SYNC-M3-05` 完整建议）并闭环更新本文档。
* **最终回滚后验收实测摘要**：
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：语法 `8/8` + 负向 `3/3`，桩测试 **`40/40`**，只读违规 `0`，退出码 `0`；
  * `python Civ5AgentBridge/tests/run_m1sub2_tests.py`：语法 `9/9` + 负向 `3/3`，桩测试 **`38/38`**，红线违规 `0`，有效写 `76`，退出码 `0`；
  * `python Civ5AgentBridge/tests/run_m1sub3_tests.py`：语法 `10/10` + 负向 `3/3`，桩测试 **`29/29`**，红线违规 `0`，有效写 `51`，态势 `67` / 心跳 `89` / RPC `126` / 轮询 `42`，退出码 `0`；
  * `git -C Civ5AgentBridge status --short` 白名单审计通过：零持久化触碰上位三文档（保持前序原样）、顶层《01~03》、`CAB_Config.lua` 及任何 Mod 壳层文件。
* **结项交接结论**：
  * **M1Sub3（含 WP1 ~ WP5 全部工作包）已 100% 闭环，可直接呈报 M1 上级评审验收**；
  * 上级评审验收并回写 `SYNC-M3-01` ~ `SYNC-M3-05` 后，即可启动下一子模块 **M1Sub4（`CAB_ExternalIO` 外部通信与大包分片子模块）** 及最终壳层合龙。
