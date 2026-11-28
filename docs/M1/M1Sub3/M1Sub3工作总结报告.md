# M1Sub3（调度控制子模块 `CAB_Dispatcher`）工作总结报告

> [!IMPORTANT]
> 本报告为 **模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`）** 下属 **子模块 3：调度控制子模块（`CAB_Dispatcher`）**（含 `D-08` 增补的 `WP5` 三大回合硬阻塞设置能力）的正式结项与验收呈报文档，供模块 1（M1）上级评审会话开展子模块验收及上位设计文档同步回写使用。
>
> **隔离红线执行声明**：在 M1Sub3 规划、编码、多套件离线回归与两轮原生真机冒烟全过程中，严格执行决策 `D-01`、`D-08` 与验收项 `A-10`：
> 1. **未对 `docs/M1/` 下三份上位设计文档（`模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）、顶层《01》《02》《03》文档、`docs/M1/M1Sub1/*`、`docs/M1/M1Sub2/*`、`mod/Lua/CAB_Config.lua` 及全部 Mod 壳层文件（`Civ5AgentBridge.modinfo`、`Civ5AgentBridgeUI.lua/.xml`、`Civ5AgentBridgeLoader.lua/.xml`、`Civ5AgentBridgeCore.lua`、`Civ5AgentBridgeJson.lua`、`scripts/deploy_mod.ps1`）做任何持久化修改**；
> 2. 仅在 `WP5` 依用户拍板特批的 `D-08`，以 100% 向后兼容的方式增量扩充 `CAB_InfoCollector.lua`（`14 → 17`）、`CAB_TaskExecutor.lua`（`9 → 12`）、`CAB_Dispatcher.lua`（`14 → 20` 路由）及三套离线测试套件；
> 3. `WP4` 与 `WP5` 临时真机冒烟期间的挂载改动（`.modinfo`、`Civ5AgentBridgeUI.lua`、临时 `CAB_M1Sub3Smoke.lua`）均已 **100% 回滚**，且执行 `deploy_mod.ps1 -ForceCopy -ClearCache` 彻底还原部署与缓存。全部架构消歧、防死锁加固、WP5 新增契约与实机发现统一汇总于本报告第六章（`SYNC-M3-01` ~ `SYNC-M3-05`）。

---

## 一、 子模块建设总览与验收结论

### 1.1 子模块职责定位与建设范围

`CAB_Dispatcher` 运行于《文明5：美丽新世界（BNW v1.0.3.279）》客户端的 Lua 5.1 UI 沙箱内，定位为模块 1 的**纯状态机与事件调度控制枢纽（State Machine & IPC Event Dispatcher）**。其核心职责包括：
1. 以守卫式按需 `include`（`D-02`）与启动全量契约自检串联 `CAB_Config`、`CAB_Collector`、`CAB_Executor`、`CAB_ExternalIO` 四大子模块；
2. 维护 5 态严格状态机（`UNINITIALIZED` / `IDLE` / `EXECUTING_SYNC` / `WAITING_SETTLEMENT` / `AI_TURN_LOCKED`）与单调递增回合序号 `s_TurnEventSeq`；
3. 统一路由对外 **20 项 SQLite IPC 方法**（原 14 项基础方法 + `WP5` 增补 6 项三大硬阻塞查询与设置方法），严格实施非活动回合 10 项白名单门控（`D-03` / `D-08`）与 RPC 信封保真映射（`D-04`）；
4. 经 `OnFrameUpdate(deltaTime)` 驱动 **8 类 `settlementKind`** 的两段式/短延迟异步帧结算、`1.50s` 硬超时兜底、跨回合抢占刷写防死锁（`D-05`）、帧时钟尖峰钳制（`S-06`）以及空闲态 `0.20s` 轮询 / `2.00s` 心跳节流。

对照《M1Sub3工作计划.md》，本子模块分设的 **规划阶段（`Plan`）+ 5 个串行工作包（`WP1` ~ `WP5`）** 已全部按期闭环：

| 阶段 / 工作包 | 核心交付目标 | 完成状态 | 完成日期 |
| :---: | :--- | :---: | :---: |
| **Plan** | 前置依赖核查、7 项关键设计决策（`D-01` ~ `D-07`）对齐、工作计划与进度看板编制 | ✅ 已完成 | 2026-11-27 |
| **WP1** | 四模块联调测试底座（含 `CAB_ExternalIO` 契约桩）+ `CAB_Dispatcher` 骨架、依赖自检、双态初始化与回合生命周期事件 | ✅ 已完成 | 2026-11-27 |
| **WP2** | `OnExternalRequestReceived` 基础 14 项 IPC 路由、AI 回合白名单门控（`D-03`）与信封保真映射（`D-04`） | ✅ 已完成 | 2026-11-27 |
| **WP3** | `OnFrameUpdate` 5 类异步帧结算推进、跨回合抢占刷写防死锁（`D-05`）、故障自愈（`S-04`）与 `0.20s`/`2.00s` 节流 | ✅ 已完成 | 2026-11-27 |
| **WP4** | 基础 14 项 IPC 三套件离线总验收、原生 BNW+IGE `17/17` 真机全链路冒烟及 100% 回滚、按 `D-08` 修订增补 `WP5` | ✅ 已完成 | 2026-11-27 |
| **WP5** | 科研选择（`ENDTURN_BLOCKING_RESEARCH`）、社会政策（`ENDTURN_BLOCKING_POLICY`）、单位晋升（`ENDTURN_BLOCKING_UNIT_PROMOTION`）全栈查询/写入/路由实现、三套件离线扩充、原生 BNW+IGE 零手工点击纯 RPC 解除三大硬阻塞真机实证、100% 回滚与结项总结 | ✅ 已完成 | 2026-11-27 |

### 1.2 总体自评结论

* **功能与契约完备度**：
  * `CAB_Dispatcher` 精确导出 **7 个公开函数（`D1` ~ `D7`）**，覆盖全部 **20 项 SQLite IPC 协议方法**（非活动回合 10 项只读/诊断白名单放行、10 项写动作及含选区副作用接口拦截），统一管理 **8 类 `settlementKind`** 异步帧结算；
  * 经 `D-08` 增量扩展后，`CAB_Collector` 导出增至 **17 项**（新增 `F8` ~ `F10`），`CAB_Executor` 导出增至 **12 项**（新增 `E10` ~ `E12`），既有全部基础接口保持 100% 向下兼容零退化。
* **离线自动化验证（回滚后最终实跑）**：三套 `Python + lupa.lua51` 离线测试套件总计 **107 条引擎桩联调用例（`40 + 38 + 29`）与全部 Lua 5.1 语法编译及负向自检 100% 通过，红线违规累计 `0` 次，桩未实现方法 `0` 次，退出码均为 `0`**：
  * `run_m1sub1_tests.py`：语法 **8/8** + 负向 **3/3**，桩测试 **`40/40`**（含 WP5 新增 `T-36` ~ `T-39`），退出码 `0`；
  * `run_m1sub2_tests.py`：语法 **9/9** + 负向 **3/3**，桩测试 **`38/38`**（含 WP5 新增 `T-33` ~ `T-37`，有效写审计 76 次），退出码 `0`；
  * `run_m1sub3_tests.py`：语法 **10/10** + 负向 **3/3**，桩测试 **`29/29`**（含 WP5 新增 `T-25` ~ `T-28`，有效写审计 51 次，态势推送 67 / 心跳 89 / RPC 响应 126 / 入站轮询 42），退出码 `0`。
* **真机实证验证**：在 Windows 本机原生《文明5：BNW v1.0.3.279》（DX11，`Lua 5.1.4`）+ `Ingame Editor (v 39)` 环境中完成两轮端到端实机冒烟：
  * **WP4 真机实证**：基础 14 项 IPC 与 5 类异步结算 **`17/17 PASS / 0 FAIL`**，`Logs/Lua.log` **629 行 0 报错**；
  * **WP5 真机实证**：全程**零手工点击**任何科研、政策或晋升 UI 按钮，纯通过 SQLite RPC 连续解除科研（`TECH_POTTERY` → 热切换 `TECH_ANIMAL_HUSBANDRY`）、社会政策（开启传统分支 + 连续采纳 4 项政策消耗文化 `300 → 40`）、单位晋升（勇士 16385 连续三连升 `SHOCK_1 → SHOCK_2 → SHOCK_3`，等级 `1 → 4`）及生产队列，完成 `end_turn` 切入 `AI_TURN_LOCKED`、真机实证 AI 门控拦截新写方法并放行新只读方法，最终顺利推进 **`Turn 0 → Turn 1`** 并自动推送 `turn_seq=2`；`Logs/Lua.log` **655 行 0 报错**。
* **验收建议**：**`A-01` ~ `A-11` 全部 11 项验收指标均已达成，申请 M1 上级评审予以正式验收通过。**

---

## 二、 交付物清单与文件隔离边界核验

### 2.1 永久交付与修改文件清单（严格落于 `D-01` / `D-08` 白名单内）

| 文件路径（相对 `Civ5AgentBridge/`） | 操作类型 | 规模（行数） | 核心交付内容与职责 |
| :--- | :---: | :---: | :--- |
| `mod/Lua/CAB_Dispatcher.lua` | 新建 | 1,503 行 | 子模块 3 正式实现：守卫式按需加载 4 模块，唯一全局 `CAB_Dispatcher`（精确 7 接口 `D1`~`D7`），5 态状态机、20 项 `RPC_HANDLERS`、10 项 AI 白名单、8 类异步结算推进、抢占刷写防死锁与异常自愈 |
| `mod/Lua/CAB_InfoCollector.lua` | WP5 增量扩充 | 2,147 行（`+508`） | 按 `D-08` 向下兼容新增第 6 节 `F8: GetResearchOptions`、`F9: GetPolicyOptions`、`F10: GetUnitPromotions`（导出 `14 → 17`），纯只读、零 UI 选区副作用、零跨调用缓存 |
| `mod/Lua/CAB_TaskExecutor.lua` | WP5 增量扩充 | 2,970 行（`+693`） | 按 `D-08` 向下兼容新增第 6 节 `E10: SetResearchTech`、`E11: AdoptPolicyOrBranch`、`E12: PromoteUnit`（导出 `9 → 12`），扩展 `IsSettlementBusy` 与 `FinalizeActionSettlement` 至 8 类 `settlementKind` |
| `tests/run_m1sub3_tests.py` | 新建 | 260 行 | 基于 `Python + lupa.lua51` 的三阶段离线验收入口（10 文件 Lua 5.1 编译 + 3 负向自检 + 四模块联调测试 + `--filter` + 红线与外部 IO 审计） |
| `tests/m1sub3/engine_stubs.lua` | 新建 & 扩充 | 2,637 行 | 独立有状态 BNW 引擎桩（含科研/政策/信条/晋升状态与延迟队列）+ 100% 对齐《模块内部接口设计.md》§三的 `CAB_ExternalIO` 标准契约模拟桩 |
| `tests/m1sub3/test_dispatcher.lua` | 新建 & 扩充 | 2,576 行 | `T-00` ~ `T-28` 共 29 条四模块联调验收用例（+ `FW-01` 框架收尾审计），覆盖全部 7 接口、20 项 IPC、AI 门控矩阵、8 类异步结算、超时、抢占刷写、时钟防护与 WP5 端到端闭环 |
| `tests/m1sub1/engine_stubs.lua`<br>`tests/m1sub1/test_collector.lua` | WP5 同步扩充 | 2,528 行（`+208`）<br>3,003 行（`+209`） | 补齐科研/政策/意识形态/晋升只读引擎桩与 `T-36` ~ `T-39` 专项单测，升级 `T-00` 导出校验至 17 项 |
| `tests/m1sub2/engine_stubs.lua`<br>`tests/m1sub2/test_executor.lua` | WP5 同步扩充 | 2,374 行（`+333`）<br>2,221 行（`+278`） | 补齐 `SendResearch`、`SendUpdatePolicies`、晋升 `GameInfoActions/HandleAction` 延迟结算桩与 `T-33` ~ `T-37` 专项单测，升级 `T-00` 导出校验至 12 项 |
| `docs/M1/M1Sub3/M1Sub3工作计划.md` | 新建 & 修订 | 232 行 | M1Sub3 前置评估、决策 `D-01`~`D-08`、6 条红线、状态机与接口详设、`WP1`~`WP5` 与 `A-01`~`A-11` 验收矩阵 |
| `docs/M1/M1Sub3/M1Sub3工作进度.md` | 新建 & 闭环 | ~200 行 | 多会话推进看板、决策表、`SYNC-M3-01`~`SYNC-M3-05` 台账与 `Session 0`~`Session 5` 完整交接日志 |
| `docs/M1/M1Sub3/M1Sub3工作总结报告.md` | 新建 | 本文档 | M1Sub3 最终结项验收报告与上位文档回写建议书 |

### 2.2 临时挂载回滚与红线文件零污染核验（`D-01` / `D-08` / `A-10`）

1. **WP4 与 WP5 临时冒烟文件 100% 回滚**：在用户确认退出《文明5》进程后，均已执行：
   * `git -C Civ5AgentBridge checkout -- mod/Civ5AgentBridge.modinfo mod/Lua/Civ5AgentBridgeUI.lua`；
   * 彻底删除临时真机垫片 `Civ5AgentBridge/mod/Lua/CAB_M1Sub3Smoke.lua`；
   * 执行 `scripts/deploy_mod.ps1 -ForceCopy -ClearCache`，镜像同步还原 `MODS/Civ5AgentBridge/` 并清理全部 5 个缓存库（`Civ5CoreDatabase.db`、`Civ5DebugDatabase.db`、`Civ5ModsDatabase.db`、`Civ5SavedGameDatabase.db`、`Civ5UserHistoryDatabase.db`）。
2. **最终 `git -C Civ5AgentBridge status --short` 隔离审计**：
   * 本子模块全部新增/修改文件严格限定于上述白名单内（`mod/Lua/CAB_Dispatcher.lua`、`CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua`、`tests/run_m1sub3_tests.py`、`tests/m1sub3/*`、`tests/m1sub1/*`、`tests/m1sub2/*`、`docs/M1/M1Sub3/*`）；
   * `docs/M1/` 下三份上位文档在 M1Sub3 启动前即已存在的前序未提交修改（M1Sub2 评审回写态）在本子模块全过程中保持原样零触碰；
   * 顶层《01~03》文档、`docs/M1/M1Sub1/*`、`docs/M1/M1Sub2/*`、`mod/Lua/CAB_Config.lua`、`.modinfo`、`Civ5AgentBridgeUI.lua/.xml`、`Civ5AgentBridgeLoader.lua/.xml`、`Civ5AgentBridgeCore.lua`、`Civ5AgentBridgeJson.lua`、`scripts/deploy_mod.ps1` **均为零持久化修改**。

---

## 三、 接口实现明细与关键工程机制说明

### 3.1 `CAB_Dispatcher` 7 个公开导出接口实现矩阵（`D1` ~ `D7`）

| 编号 | 函数签名 | 返回值 | 关键实现机制与红线落实 |
| :---: | :--- | :---: | :--- |
| **D1** | `CAB_Dispatcher.Initialize(uiStatusCallback)` | `boolean` | 热重载重初始化先抢占刷写旧挂起任务（`D-05`）；逐项自检 `CAB_Config`（6 键）、`CAB_Collector`（10 项调度依赖函数）、`CAB_Executor`（全部 12 项公开函数）与 `CAB_ExternalIO`（7 项契约函数）；依次调 `CAB_Executor.Initialize()` 与 `CAB_ExternalIO.Initialize(OnExternalRequestReceived)`；按实时活动回合态双态分流（`IDLE` + `turn_seq+1` 首帧态势推送，或 `AI_TURN_LOCKED` + `AI_TURN_PROCESSING` 心跳）。 |
| **D2** | `CAB_Dispatcher.OnActivePlayerTurnStart()` | `nil` | 先抢占收口残留挂起结算（`S-03`），重置轮询/心跳累加器与锁源元信息，置 `IDLE`、`s_TurnEventSeq + 1`，经 `pcall` 采集并推送新回合态势；采集/推送异常时降级写心跳自愈（`S-04`）。 |
| **D3** | `CAB_Dispatcher.OnActivePlayerTurnEnd()` | `nil` | 先抢占收口在途异步结算（`S-03`），置 `AI_TURN_LOCKED` 并记录当前回合/玩家锁定来源，立即写入 `AI_TURN_PROCESSING` 心跳与刷新 UI。 |
| **D4** | `CAB_Dispatcher.OnManualSyncClicked()` | `nil` | 严格落实 `S-05`：未初始化、`WAITING_SETTLEMENT`、`AI_TURN_LOCKED` 或非活动回合严禁覆写快照；合法 `IDLE` 活动回合强制导出 `turn_overview_auto` 且**绝不递增 `s_TurnEventSeq`**。 |
| **D5** | `CAB_Dispatcher.OnExternalRequestReceived(reqObj)` | `nil` | 畸形/未初始化防御；挂起态重入立返 Busy 错返不破坏在途结算（`S-03`）；结合锁定来源元信息与 `IsTurnActive()` 自校准回合态（既支持读档/IGE 切人自校准，又防止 `end_turn` 当帧窗口误解锁）；按 10 项白名单执行 AI 回合门控（`S-02`）；在 `pcall` 保护下分发 20 项 `RPC_HANDLERS`（`S-04`）。 |
| **D6** | `CAB_Dispatcher.OnFrameUpdate(deltaTime)` | `nil` | `sanitizeDeltaTime` 净化 `nil`/非数/`NaN`/`<=0`/`inf`；在途结算单帧步进钳制 `<= 0.50s`（`S-06`）并结合 `TIME_EPSILON = 1e-9` 防止 IEEE-754 边界漂移；支持全部 **8 类 `settlementKind`** 忙碌探测与 `1.50s` 硬超时兜底（挂起期间严格暂停 `PollIncomingRequest`）；空闲/AI 锁态精准执行 `0.20s` 轮询节流与 `2.00s` 心跳节流。 |
| **D7** | `CAB_Dispatcher.GetRuntimeState()` | `table` | 返回纯只读浅拷贝诊断快照（含 `initialized`、`bridge_state`、`turn_event_seq`、`has_pending_settlement`、`pending_req_id`、`pending_method`、`pending_kind`、`pending_elapsed_sec`、`pending_min_wait_sec`、`pending_max_timeout_sec`、`poll_accum_sec`、`heartbeat_accum_sec`），零私有引用泄露。 |

### 3.2 对外 20 项 SQLite IPC 协议路由总表（基础 14 项 + WP5 增补 6 项）

| # | `method` 名称 | AI 回合放行 | 结算模式 / `settlementKind` | 入参契约（含别名兼容）与信封映射要点 |
| :-: | :--- | :---: | :---: | :--- |
| 1 | `ping` | ✅ 放行 | 同步即时 | 可选 `echo`；返回 `{ pong, turn, active_player, is_turn_active, status, turn_seq }` |
| 2 | `test_large_payload` | ✅ 放行 | 同步即时 | `target_bytes`（缺省 `32768`，上限钳制 `524288`）、`use_chunk`、`payload`；支持分片透传 |
| 3 | `get_turn_overview` | ✅ 放行 | 同步即时 | 无参 → `CAB_Collector.BuildTurnOverview` |
| 4 | `get_empire_economy` | ✅ 放行 | 同步即时 | 无参 → `CAB_Collector.GetEmpireEconomy` |
| 5 | `get_visibility_summary` | ✅ 放行 | 同步即时 | 无参 → `CAB_Collector.GetVisibilitySummary`（取第 1 返回值） |
| 6 | `get_city_detail` | ✅ 放行 | 同步即时 | 必填整数 `city_id`、可选布尔 `include_purchasable`（默认 `true`）→ `CAB_Collector.GetCityDetail` |
| 7 | `get_end_turn_status` | ✅ 放行 | 同步即时 | 无参 → `CAB_Collector.GetEndTurnStatus` |
| 8 | `get_research_options` *(WP5)* | ✅ **放行** | 同步即时 | 无参 → `CAB_Collector.GetResearchOptions`（纯只读零选区副作用） |
| 9 | `get_policy_options` *(WP5)* | ✅ **放行** | 同步即时 | 无参 → `CAB_Collector.GetPolicyOptions`（纯只读零选区副作用） |
| 10 | `get_unit_promotions` *(WP5)* | ✅ **放行** | 同步即时 | 必填整数 `unit_id` → `CAB_Collector.GetUnitPromotions`（基于原生 Unit C++ 只读方法，零 `UI.SelectUnit` 副作用） |
| 11 | `get_unit_context` | ❌ 拦截 | 同步即时 | 必填整数 `unit_id`、可选整数 `radius` → `CAB_Collector.BuildUnitContextAndCandidates`（含临时选区探测故 AI 回合拦截） |
| 12 | `execute_unit_action` | ❌ 拦截 | 两段异步 `UNIT_ACTION` (`0.35s`) | `unit_id`、`action_type`、可选 `target_x`/`target_y`/`allow_declare_war`/`settle_delay_sec`（钳制 `[0, 1.50]`；退役 `sync_frame_comparison`） |
| 13 | `execute_city_attack` | ❌ 拦截 | 两段异步 `CITY_ATTACK` (`0.35s`) | `city_id`、`target_x`、`target_y`、可选 `allow_declare_war` |
| 14 | `purchase_city_item` | ❌ 拦截 | 短延迟异步 `PURCHASE_ITEM` (`0.10s`) | `city_id`、`item`、可选 `item_category`（默认 `"BUILDING"`）、`yield_type`（默认 `"GOLD"`） |
| 15 | `set_city_production` | ❌ 拦截 | 短延迟异步 `SET_PRODUCTION` (`0.10s`) | `city_id`、`order_category`、`item`、可选 `clear_queue`（默认 `true`） |
| 16 | `purchase_city_plot` | ❌ 拦截 | 短延迟异步 `BUY_PLOT` (`0.10s`) | `city_id`、`target_x`/`target_y`（兼容别名 `plot_x`/`plot_y`） |
| 17 | `end_turn` | ❌ 拦截 | 同步提交 + 跨回合 | 可选 `auto_skip_ready_units`；`BLOCKED` 返 `ok=true` 保真透传 `blocking_info` 维持 `IDLE`；`turn_ended==true` 返 `ok=true` 并即刻切入 `AI_TURN_LOCKED` |
| 18 | `set_research_tech` *(WP5)* | ❌ 拦截 | 短延迟异步 `SET_RESEARCH` (`0.10s`) | 主契约 `tech`（兼容别名 `tech_type` / `tech_id`，支持 Type 字符串或整数 ID）→ `CAB_Executor.SetResearchTech` |
| 19 | `adopt_policy` *(WP5)* | ❌ 拦截 | 短延迟异步 `ADOPT_POLICY` (`0.10s`) | 可选 `target_category`（`"BRANCH"` / `"POLICY"`，默认 `"POLICY"`）、主契约 `target`（兼容别名 `policy` / `branch`）→ `CAB_Executor.AdoptPolicyOrBranch` |
| 20 | `promote_unit` *(WP5)* | ❌ 拦截 | 短延迟异步 `PROMOTE_UNIT` (`0.10s`) | 必填整数 `unit_id`、主契约 `promotion`（兼容别名 `promotion_type` / `promotion_id`）→ `CAB_Executor.PromoteUnit` |

### 3.3 WP5 增补三组采集与执行接口明细（`F8`~`F10` & `E10`~`E12`）

经核查本机原生《文明5：BNW v1.0.3.279》官方脚本（`TechPopup.lua`、`TechTree.lua`、`SocialPolicyPopup.lua`、`UnitPanel.lua`）与 `CvGameCore_Expansion2.dll` 导出符号，确认三组硬阻塞均需遵循原生 BNW 校验与跨帧异步消息队列特性：

1. **科研选择（`F8` + `E10` + `SET_RESEARCH`）**：
   * `CAB_Collector.GetResearchOptions(activePlayerID)`：校验 `GAMEOPTION_NO_SCIENCE`、`pPlayer:CanResearch(techID)` 并在 `GetNumFreeTechs() > 0` 时追加 `pPlayer:CanResearchForFree(techID)`；返回 `ResearchOptionsDTO`（`science_disabled`、`science_per_turn`、`overflow_research`、`free_techs_available`、`is_free_tech_pending`、`current_research`、`available_techs`、`researched_techs`）。
   * `CAB_Executor.SetResearchTech(activePlayerID, techKeyOrId)`：校验 E-01 写门控、禁用科研、已研究非 Repeat 科技及 `CanResearch`/`CanResearchForFree`，调用 `Network.SendResearch(techId, freeTechsBefore, -1, false)` 并返回 `SET_RESEARCH` 短延迟结算基线；结算返回 `{ executed, error_reason, tech_id, tech_type, is_free_tech, current_research_id, current_research_type, free_techs_before, free_techs_after, turns_left, settle_wait_ms, timed_out }`。
2. **社会政策（`F9` + `E11` + `ADOPT_POLICY`）**：
   * **关键 BNW 官方核实修正**：官方 `SocialPolicyPopup.lua:155, 349, 1206, 1232` 验证分支开启使用 **`pPlayer:CanUnlockPolicyBranch(branchID)`**（并非 `CanAdoptPolicyBranch`），且需排除 `PolicyBranchType == nil` 的自动开/关门政策、排除需走 `SendIdeologyChoice` 的 `PurchaseByLevel == true` 意识形态分支，并守卫 `GetNumCities() > 0`；已选定意识形态后通过 `GetAvailableTenets(lvl)` 与 `GetTenet` 槽位规则枚举可采纳信条。
   * `CAB_Collector.GetPolicyOptions(activePlayerID)`：返回 `PolicyOptionsDTO`（`policies_disabled`、`culture`、`culture_per_turn`、`next_policy_cost`、`free_policies`、`free_tenets`、`num_cities`、`can_adopt_now`、`ideology_branch_id`、`ideology_branch_type`、`policy_branches`、`unlockable_branches`、`adoptable_policies`、`adopted_policies`）。
   * `CAB_Executor.AdoptPolicyOrBranch(activePlayerID, targetCategory, keyOrId)`：支持 `"BRANCH"` 与 `"POLICY"`（含已选意识形态信条），细分前置时代不足、文化不足、已解锁/已采纳、自动政策与意识形态分支误用；调用 `Network.SendUpdatePolicies(targetId, isPolicyFlag, true)` 并返回 `ADOPT_POLICY` 基线；结算返回 `{ adopted, error_reason, target_category, target_id, target_type, culture_before, culture_after, free_policies_before, free_policies_after, next_policy_cost_after, settle_wait_ms, timed_out }`。
3. **单位晋升（`F10` + `E12` + `PROMOTE_UNIT`）**：
   * **关键 BNW 官方核实**：`CvGameCore_Expansion2.dll` 原生导出 `IsPromotionReady`、`CanPromote`、`CanAcquirePromotion`、`IsHasPromotion`、`GetExperience`、`ExperienceNeeded`、`GetLevel`，全部只读且零 UI 选区副作用，因此 `get_unit_promotions` 安全入列 AI 回合只读白名单。
   * `CAB_Collector.GetUnitPromotions(activePlayerID, unitID)`：过滤 `CannotBeChosen` 与满血时的 `InstaHeal`；返回 `UnitPromotionsDTO`（`unit_id`、`unit_type`、`name`、`hp`、`max_hp`、`level`、`experience`、`experience_needed`、`is_promotion_ready`、`can_promote`、`earned_promotions`、`available_promotions`）。
   * `CAB_Executor.PromoteUnit(activePlayerID, unitID, promotionKeyOrId)`：校验待晋升态、`CannotBeChosen`、重复晋升、满血 `InstaHeal` 与 `CanAcquirePromotion`，在 `withTempUnitSelection`（`pcall` + 无条件恢复原 UI 选区）保护下按 `UnitPanel.lua:90-91, 206, 285, 892` 定位 `ACTIONSUBTYPE_PROMOTION` 动作并执行 `Game.HandleAction(iAction)`，返回 `PROMOTE_UNIT` 基线；结算兼容 `PROMOTION_INSTA_HEAL` 不驻留 `IsHasPromotion` 的特性（通过 `GetLevel() > levelBefore`、降伤或 `not IsPromotionReady()` 综合判定），返回 `{ promoted, error_reason, unit_id, promotion_id, promotion_type, is_insta_heal, level_before, level_after, is_promotion_ready_after, unit_after, settle_wait_ms, timed_out }`。

---

## 四、 双层验收测试执行结果

### 4.1 第一层：回滚后最终三套件离线自动化总回归（`Python + lupa.lua51`）

| 测试套件 | Lua 5.1 语法编译 | 负向语法自检 | 引擎桩用例结果 | 红线违规 / 桩未实现 | 关键审计计数 | 退出码 |
| :--- | :---: | :---: | :---: | :---: | :--- | :---: |
| `tests/run_m1sub1_tests.py` | **8/8 通过** | **3/3 通过** | **`40/40` 通过**（`T-00`~`T-39`） | **0 / 0** | 只读违规 `0` 次 | **`0`** |
| `tests/run_m1sub2_tests.py` | **9/9 通过** | **3/3 通过** | **`38/38` 通过**（`T-00`~`T-37`） | **0 / 0** | 有效写操作 `76` 次 | **`0`** |
| `tests/run_m1sub3_tests.py` | **10/10 通过** | **3/3 通过** | **`29/29` 通过**（`T-00`~`T-28`） | **0 / 0** | 有效写操作 `51` 次；态势推送 `67` / 心跳 `89` / RPC 响应 `126` / 入站轮询 `42` | **`0`** |
| **三套件合计** | **全绿** | **9/9 通过** | **`107/107` 全部通过** | **0 / 0** | **零回归、零红线违规** | **`0`** |

**M1Sub3 核心用例区间覆盖明细（`tests/m1sub3/test_dispatcher.lua`）**：

| 用例区间 | 覆盖主题 | 条数 | 结果 | 核心验证点摘要 |
| :---: | :--- | :---: | :---: | :--- |
| `T-00` ~ `T-02` | 加载洁净、静态红线、守卫加载与桩自检 | 3 | 3/3 | 唯一全局 `CAB_Dispatcher`（精确 7 导出）；静态扫描零 `S-01` 禁令符号（含新增 `SendResearch`/`SendUpdatePolicies`/`HandleAction`）；重载零重复 `include`；`CAB_ExternalIO` 7 项契约桩自检 |
| `T-03` ~ `T-10` | WP1：依赖自检、双态初始化与回合生命周期 | 8 | 8/8 | 缺键/缺函数/下游初始化失败全拦截；活动/非活动双态初始化；`GetRuntimeState` 只读隔离；UI 回调容错；跨回合 `turn_seq` 递增；未初始化空转；手动同步 `S-05` 护栏；采集/推送故障自愈 |
| `T-11` ~ `T-17` | WP2：14 项基础 IPC 路由、AI 门控与信封保真 | 7 | 7/7 | 畸形/未知方法自愈；`ping` & `test_large_payload`（512KB 钳制+分片）；6 项只读路由；**全量 20 方法非活动回合门控矩阵**（10 放行 / 10 拦截且下游零调用）；`end_turn` 三分支与窗口锁源保护；5 类写动作挂起与 `settle_delay_sec` 钳制；挂起期 Busy 重入拒返 |
| `T-18` ~ `T-24` | WP3：异步帧结算、抢占防死锁与节流精度 | 7 | 7/7 | `UNIT_ACTION` / `CITY_ATTACK` 忙碌等待；3 类城市短异步结算；`1.50s` 硬超时兜底与 `D-04` 保真；`TurnEnd`/`TurnStart`/`Initialize` 三路径抢占刷写与 `1:1` 幂等回执；畸形/尖峰 `deltaTime` 钳制（`S-06`）；帧循环故障自愈；`0.20s`/`2.00s` 节流与全自动队列驱动闭环 |
| `T-25` ~ `T-28` | WP5：三大硬阻塞查询/写入、超时与全链路闭环 | 4 | 4/4 | `get_research_options` / `get_policy_options` / `get_unit_promotions` 路由与参数守卫；`set_research_tech` / `adopt_policy` / `promote_unit` 别名兼容与 `SET_RESEARCH`/`ADOPT_POLICY`/`PROMOTE_UNIT` 帧结算；3 类新结算 `1.50s` 硬超时兜底；纯 RPC 自动帧队列依次解除科研/政策/晋升硬阻塞并成功 `end_turn` 推进至下一回合 |

### 4.2 第二层：《文明5：BNW v1.0.3.279》+ IGE 两轮全链路真机实证（`WP4` & `WP5`）

* **实测环境**：Windows 本机原生 `Sid Meier's Civilization V (DX11)` BNW `v1.0.3.279`（内置 `Lua 5.1.4`），同时加载 `Civ5 Agent Command Bridge`（临时挂载 `CAB_Config` + `CAB_InfoCollector` + `CAB_TaskExecutor` + `CAB_Dispatcher` + 极薄临时 SQLite 垫片 `CAB_M1Sub3Smoke.lua`）与 `Ingame Editor (v 39)`，外部由独立 Python SQLite 客户端直连 `ModUserData/Civ5AgentBridge-1.db` 收发真实 RPC 指令。

#### （一）WP4 真机实证摘要（基础 14 项 IPC + 5 类异步结算）
* **结果**：**`17/17 PASS / 0 FAIL`**，`Logs/Lua.log` **629 行 0 报错**（29 条 `[CAB_*]` 调试日志）。
* 覆盖：首帧自动推送（`turn=0, turn_seq=1`）、`ping`（`90.5ms`）、`test_large_payload` 32KB 11 分片（`317.2ms`）、全部 6 项只读查询（`187~251ms`）、`end_turn(BLOCKED)` 保真回传、5 类异步结算零超时（`SET_PRODUCTION` `109ms`、`PURCHASE_ITEM` 建筑 `110ms` / 工人 `125ms`、`BUY_PLOT` `109ms`、`CITY_ATTACK` `360ms`、`UNIT_ACTION` 近战 `359ms`）、手动同步不递增 `turn_seq`、AI 回合门控拦截 `get_unit_context`（`185.4ms`）放行 `ping`（`233.9ms`）、自动推进 `Turn 0 → Turn 1`（`turn_seq=2`）。

#### （二）WP5 真机实证量化总表（零手工点击、纯 RPC 解除三大硬阻塞 + 推进回合）
* **测试布置**：单人局 Player 0（中国，首都北京 `city_id=8192`），通过 IGE 注入 `+300` 文化与为开局勇士（`unit_id=16385`）注入 `+61` 经验，同时触发生产、科研、社会政策、单位晋升四重阻塞；**全程零手工点击游戏内任何科研、政策或晋升按钮**。
* **日志核验**：`Logs/Lua.log` 累计 **655 行，0 条语法错误、0 条运行时错误、0 条堆栈报错**（39 条 `[CAB_*]` 全链路调试日志）。

| 阶段 / 实证项 | 真实 RPC 调用 | 端到端 RTT | 实机量化回读结果（`ModUserData/Civ5AgentBridge-1.db`） | 实机结论 |
| :--- | :--- | :---: | :--- | :---: |
| **P1 心跳与建链** | `ping` | `81.0ms` | `turn=0, turn_seq=1, status="IDLE", is_turn_active=true` | ✅ PASS |
| **P2 科研查询与热切换** | `get_research_options` → `set_research_tech(TECH_POTTERY)` → `set_research_tech(TECH_ANIMAL_HUSBANDRY)` | `195.8ms` / `309.5ms` / `311.7ms` | 查出 4 项可选古代科技；设陶艺 `settle_wait_ms=109ms, timed_out=false, turns_left=7`；热切换畜牧 `settle_wait_ms=110ms, timed_out=false`，复查 `current_research="TECH_ANIMAL_HUSBANDRY"` | ✅ PASS |
| **P3 社会政策分支开启与连点清空** | `get_policy_options` → `adopt_policy(BRANCH, POLICY_BRANCH_TRADITION)` → 连采 `POLICY_ARISTOCRACY` / `OLIGARCHY` / `LEGALISM` / `LANDED_ELITE` | `221.9ms` / `287.7~301.1ms` | 初始 `culture=300/15`（3 个可开分支）；开传统 `settle_wait_ms=109ms`（`300→285, next_cost→20`）；4 项政策全部 `adopted=true, settle_wait_ms=109~110ms, timed_out=false`，文化 `285→265→225→155→40`（`next_cost=170`），政策阻塞彻底解除且律法主义自动赠予北京纪念碑 | ✅ PASS |
| **P4 单位晋升三连升** | `get_unit_promotions(16385)` → 连晋 `PROMOTION_SHOCK_1` / `SHOCK_2` / `SHOCK_3` | `206.8ms` / `308.3~311.0ms` | 初始 `ready=true, level=1, xp=61/10, avail=[SHOCK_1, DRILL_1]`；三连晋升全部 `promoted=true, settle_wait_ms=109~110ms, timed_out=false`，等级 `1→2→3→4`，最终 `is_promotion_ready_after=false, earned=[SHOCK_1, SHOCK_2, SHOCK_3]` | ✅ PASS |
| **P5 补齐生产与提交回合** | `set_city_production(8192, UNIT, UNIT_WARRIOR)` → 跳过待命勇士 → `get_end_turn_status` → `end_turn` | `308.8ms` / `204.4ms` / `218.3ms` | 设产勇士 `settle_wait_ms=110ms, queue=1`；复查 `NO_BLOCKING, can_end_turn_now=true`；`end_turn` 返回 `turn_ended=true, status="WAITING_NEXT_TURN"` 并切入 `AI_TURN_LOCKED` | ✅ PASS |
| **P6 AI 回合门控与 Turn 1 自动推送** | AI 锁态下发 `set_research_tech` / `promote_unit`（应拦截）与 `get_research_options` / `get_unit_promotions`（应放行）→ 等待回合推进 | `189.0ms` / `227.4ms` / `171.1ms` / `201.8ms` | 2 项 WP5 写方法均被拦截返 `"Player turn is not active (AI turn in progress)"`；2 项 WP5 只读方法放行返回准确只读态（`TECH_ANIMAL_HUSBANDRY`, `level=4`）；随后自动推进至 **Turn 1**，`turn_seq=2, status="TURN_SYNCED"` | ✅ PASS |

---

## 五、 验收标准矩阵逐项对账表（`A-01` ~ `A-11`）

| 验收项 | 验收内容 | 实测验证证据 | 验收结论 |
| :---: | :--- | :--- | :---: |
| **A-01** | Lua 5.1 语法与命名空间洁净 | `run_m1sub3_tests.py` 阶段 1 `10/10` + 负向 `3/3` 通过；`T-00`/`T-01` 确认守卫式按需加载、唯一全局 `CAB_Dispatcher` 精确 7 项导出及红线 `S-01` 违规 `0` 次 | ✅ **通过** |
| **A-02** | 依赖自检与双态初始化闭环 | `T-03`~`T-06` 全量依赖缺失与下游失败拦截；活动回合 `IDLE`/`turn_seq=1`/首帧推送与非活动回合 `AI_TURN_LOCKED`/心跳实测全绿 | ✅ **通过** |
| **A-03** | 回合生命周期与手动同步护栏 | `T-07`~`T-10` + WP4 真机 `L06`/`L07` 实证 `TurnStart` 递增 `turn_seq`、`TurnEnd` 锁态、`OnManualSyncClicked` 遵守 `S-05` 不递增 `turn_seq` | ✅ **通过** |
| **A-04** | 全量基础 14 项 IPC 路由与入参守卫 | `T-11`~`T-16` 正向与畸形入参全覆盖 + WP4 真机 `17/17` 全绿，零未捕获异常 | ✅ **通过** |
| **A-05** | 非活动回合白名单门控（`D-03` / `D-08`） | `T-14` 全量 20 方法门控矩阵（10 放行 / 10 拦截且下游调用次数 `== 0`）+ WP4 & WP5 两轮真机 AI 锁态实证 | ✅ **通过** |
| **A-06** | RPC 信封保真与 `end_turn` 切态（`D-04`） | `T-13`/`T-15`/`T-16` + WP4 真机 `L04`/`L07` 实证 `end_turn(BLOCKED)` 返 `ok=true` 保真透传 `blocking_info` 并维持 `IDLE`、`turn_ended=true` 切 `AI_TURN_LOCKED` | ✅ **通过** |
| **A-07** | 异步动作两段式帧结算（`D-05`） | `T-18`~`T-20` + `T-26`~`T-27` 覆盖全部 8 类 `settlementKind` 与 `1.50s` 硬超时兜底（已退役 `sync_frame_comparison`）；两轮真机实证全部零超时精准回读 | ✅ **通过** |
| **A-08** | 跨回合抢占防死锁、重入保护与异常自愈 | `T-17`/`T-21`~`T-24` 实证挂起期暂停轮询、Busy 重入拒返、三路径抢占刷写保证请求-响应 `1:1` 幂等、故障注入自愈与 `0.50s` 单帧钳制（`S-06`） | ✅ **通过** |
| **A-09** | 前序子模块零回归与真机冒烟 100% 回滚 | 回滚后三套件总回归：`run_m1sub1_tests.py` `40/40`、`run_m1sub2_tests.py` `38/38`、`run_m1sub3_tests.py` `29/29` 均退出码 `0`；两轮真机 `Lua.log` 零报错且临时挂载 100% 回滚并清理全部 5 个缓存库 | ✅ **通过** |
| **A-10** | 文件隔离纪律与结项文档闭环 | `git status --short` 确认禁止清单文件零持久化修改；《M1Sub3工作进度.md》与本报告（含完整 `SYNC-M3-01`~`SYNC-M3-05`）闭环齐备 | ✅ **通过** |
| **A-11** | 三大硬阻塞查询与设置能力闭环（`D-08` / WP5） | 科研/政策/晋升 6 项新接口与 6 项新 IPC 路由全覆盖，三套件新增 13 条专项用例（`T-36~39` + `T-33~37` + `T-25~28`）全绿，原生 BNW+IGE 零手工点击纯 RPC 解除三大硬阻塞并完成 `Turn 0 → Turn 1` 实证且 100% 回滚 | ✅ **通过** |

---

## 六、 上位设计文档回写建议清单（`SYNC-M3-01` ~ `SYNC-M3-05`）

以下为 M1Sub3 全过程（WP1 ~ WP5）形成的**上位文档同步建议台账**，提请上级 M1 评审会话在验收通过后统一回写至 `docs/M1/` 下对应文档：

### `SYNC-M3-01`：非活动回合（`AI_TURN_LOCKED`）门控白名单口径消歧与 WP5 扩展（对应 `D-03`、`D-08`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §六 `OnExternalRequestReceived`、`docs/M1/模块设计说明.md` §3.3
* **变更类型**：口径消歧 + 增补
* **建议回写内容**：明确当处于 `AI_TURN_LOCKED` 或 `not pPlayer:IsTurnActive()` 时，放行 **10 项零 UI 选区副作用的只读/诊断接口**（`ping`、`test_large_payload`、`get_end_turn_status`、`get_empire_economy`、`get_visibility_summary`、`get_turn_overview`、`get_city_detail`、`get_research_options`、`get_policy_options`、`get_unit_promotions`），拦截全部 **9 项写指令及需临时切换 UI 选区的 `get_unit_context`**（共 10 项拦截），零下游调用立返 `"Player turn is not active (AI turn in progress)"`。

### `SYNC-M3-02`：调度状态机防死锁加固、诊断接口与帧时钟防护（对应 `D-05`、`D-06`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §六、`docs/M1/模块设计说明.md` §3.3 & §4.2
* **变更类型**：加固 / 增补
* **建议回写内容**：
  1. 登记第 7 个公开只读诊断快照函数 `CAB_Dispatcher.GetRuntimeState() -> table`（含 `pending_elapsed_sec` / `pending_min_wait_sec` / `pending_max_timeout_sec` 只读标量）；
  2. 细化 `WAITING_SETTLEMENT` 跨回合/重初始化抢占刷写防死锁机制（先 `pcall(FinalizeActionSettlement)` 刷写 `SendRpcResponse`，异常降级写中断错返，再清槽位，确保请求-响应 `1:1` 幂等）；
  3. 明确 `OnManualSyncClicked` 在挂起/AI 态不覆写快照且合法导出不递增 `s_TurnEventSeq`；
  4. 补充锁定来源追踪元信息（`s_LockedTurnNumber`/`s_LockedPlayerID`/`s_TurnLockObservedInactive`），防止 `end_turn` 提交当帧窗口误解锁，同时支持读档/IGE 切人失步自校准；
  5. 明确 `OnFrameUpdate` 帧间隔净化、单帧结算步进上限 `0.50s`（`S-06`）与 `1e-9` 浮点累加容差。

### `SYNC-M3-03`：守卫式加载规范、RPC 信封保真映射与原型字段退役（对应 `D-02`、`D-04`、`D-05`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §1.1、§六、§七
* **变更类型**：细化
* **建议回写内容**：
  1. 在 §1.1 补充 Civ5 VFS 守卫式按需加载规范（`if CAB_X == nil then include("CAB_X") end`），防止重复 `include` 重置 `local` 状态并支持测试桩/真机垫片无侵入注入；
  2. 在 §六/§七 明确 `end_turn` 返回 `status = "BLOCKED"` 时以 `ok = true, data = EndTurnResultDTO` 保真回传（不切入 `AI_TURN_LOCKED`），以及全部异步结算 DTO（含超时未达成）均以 `ok = true, data = SettlementDTO` 保真回传；
  3. 明确 `execute_unit_action` 正式退役 EXP-04 遗留字段 `sync_frame_comparison`，支持可选 `settle_delay_sec` 钳制于 `[0, MAX_SETTLE_TIMEOUT_SEC]`。

### `SYNC-M3-04`：同步模块 1 开发进度看板状态（对应 `D-01`）
* **目标文档与章节**：`docs/M1/模块设计进度.md` §三 `M1-S5`
* **变更类型**：进度拆分同步
* **建议回写内容**：记录 `M1-S5` 中的核心调度器 `CAB_Dispatcher.lua`、四模块联调测试套件及 WP5 三大硬阻塞全栈能力已由 M1Sub3 正式交付验收；剩余 `Civ5AgentBridgeUI.lua` 壳层精简与 `.modinfo` 正式装配待子模块 4（`CAB_ExternalIO`）验收后一键合龙。

### `SYNC-M3-05`：增补科研选择、社会政策、单位晋升三大回合硬阻塞全栈接口契约与实机要点（对应 `D-08` / WP5）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §四、§五、§六、§七、`docs/M1/模块设计说明.md` §3.1 ~ §3.3
* **变更类型**：能力增补（向后兼容）
* **建议回写内容**：
  1. **采集层（`CAB_Collector` 导出 `14 → 17`）**：新增 `GetResearchOptions(activePlayerID) -> ResearchOptionsDTO`（`F8`）、`GetPolicyOptions(activePlayerID) -> PolicyOptionsDTO`（`F9`）、`GetUnitPromotions(activePlayerID, unitID) -> UnitPromotionsDTO`（`F10`），均为纯只读、零 UI 选区副作用、零跨调用缓存；特别注明官方 BNW 分支开启校验 API 为 `pPlayer:CanUnlockPolicyBranch(branchID)`（排除 `PolicyBranchType == nil` 自动开/关门政策与 `PurchaseByLevel == true` 意识形态分支，已选意识形态后通过 `GetAvailableTenets` + `GetTenet` 枚举信条）。
  2. **执行层（`CAB_Executor` 导出 `9 → 12`，`settlementKind` `5 → 8`）**：新增 `SetResearchTech(activePlayerID, techKeyOrId)`（`E10`，`SET_RESEARCH`，`Network.SendResearch`）、`AdoptPolicyOrBranch(activePlayerID, targetCategory, keyOrId)`（`E11`，`ADOPT_POLICY`，`Network.SendUpdatePolicies`）、`PromoteUnit(activePlayerID, unitID, promotionKeyOrId)`（`E12`，`PROMOTE_UNIT`，`withTempUnitSelection` + `GameInfoActions/HandleAction`）；三者经原生 BNW 实证均走跨帧消息队列，统一纳入 `0.10s` 短延迟异步结算（`1.50s` 超时兜底），其中 `PROMOTE_UNIT` 结算兼容 `PROMOTION_INSTA_HEAL` 不驻留 `IsHasPromotion` 的特性。
  3. **调度层与外部 IPC（`14 → 20` 项）**：新增 `get_research_options`、`get_policy_options`、`get_unit_promotions`（均入 AI 回合白名单）与 `set_research_tech`（`tech`/`tech_type`/`tech_id`）、`adopt_policy`（`target_category` + `target`/`policy`/`branch`）、`promote_unit`（`unit_id` + `promotion`/`promotion_type`/`promotion_id`）。
  4. **原生实机工程经验补充**：
     * **M1Sub4 `CAB_ExternalIO` UTF-8 分片切分防护**：WP5 真机实测繁体中文环境发现，当 `get_policy_options` 返回的 `Help` 描述含多字节中文字符时，按固定 `3000` 字节切片会截断 3 字节 UTF-8 字符边界，导致 Python `sqlite3` 默认 `TEXT` 按片解码时触发 `OperationalError: Could not decode to UTF-8`。建议在 M1Sub4 `CAB_ExternalIO.WritePayload` 切片边界自动回退对齐至 UTF-8 首字节，同时 Python 客户端（`sqlite_bridge.py`）读取分片时采用 `text_factory = bytes` 拼接完整字节流后再统一 UTF-8 解码；
     * **`ExecuteEndTurn(autoSkipReadyUnits=true)` 跨帧跳过说明**：原生 BNW 下 `MISSION_SKIP` 经消息队列异步落地（约 1 帧），若存在 `ENDTURN_BLOCKING_UNITS`，首次 `end_turn(auto_skip_ready_units=true)` 下发跳过并回传 `auto_skipped_unit_ids` 与 `BLOCKED`，外部智能体或工作流间隔约 1 帧再次调用 `end_turn` 即可看到 `NO_BLOCKING` 并顺利提交 `CONTROL_ENDTURN`。

---

## 七、 后续子模块衔接指引（M1Sub4 `CAB_ExternalIO` 与最终壳层合龙）

1. **M1Sub4（`CAB_ExternalIO.lua`）直接对接指引**：
   * `CAB_Dispatcher.lua` 已通过 `D-02` 守卫式按需加载预埋 `if CAB_ExternalIO == nil then include("CAB_ExternalIO") end`，且完整校验《模块内部接口设计.md》§三 的全部 7 项导出（`Initialize`、`WritePayload`、`ReadPayload`、`PushTurnOverview`、`WriteHeartbeat`、`SendRpcResponse`、`PollIncomingRequest`）；M1Sub4 按契约交付后，**`CAB_Dispatcher.lua` 零改代码即可直接合龙**；
   * 请在 M1Sub4 实现 `WritePayload` 分片切片时务必落实上文 `SYNC-M3-05` 记录的 **UTF-8 多字节边界对齐**，并在后续联调同步加固 Python `sqlite_bridge.py` 的字节拼接解码逻辑。
2. **最终壳层收口（`M1-S5` 尾部 + `M1-S6`）**：
   * 待 M1Sub4 验收后，在 `mod/Civ5AgentBridge.modinfo` 中正式注册 `CAB_Config.lua`、`CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua`、`CAB_ExternalIO.lua`、`CAB_Dispatcher.lua`（均为 `<File import="1">`），将 `Civ5AgentBridgeUI.lua` 精简为纯事件转发壳层（仅挂载 `Initialize`、`OnActivePlayerTurnStart`、`OnActivePlayerTurnEnd`、`OnManualSyncClicked`、`OnFrameUpdate` 5 项入口），并同步升级 Python 侧 `bridge_service.py` / `mcp_server.py` 暴露 WP5 新增的 6 项工具完成端到端联调验收。
