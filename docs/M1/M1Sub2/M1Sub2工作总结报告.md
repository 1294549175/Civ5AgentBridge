# M1Sub2（游戏内任务执行子模块 `CAB_TaskExecutor`）工作总结报告

> [!IMPORTANT]
> 本报告为 **模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`）** 下属 **子模块 2：游戏内任务执行子模块（`CAB_TaskExecutor`）** 的正式结项与验收呈报文档，供模块 1（M1）上级评审会话开展子模块验收及上位设计文档同步回写使用（覆盖原《模块设计进度.md》中的 `M1-S3` + `M1-S4`）。
>
> **隔离红线执行声明**：在 M1Sub2 规划、编码、测试与多轮真机冒烟全过程中，严格执行决策 `D-01` 与验收项 `A-10`，**未对 `docs/M1/` 下三份上位设计文档（`模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）、顶层《01》《02》《03》文档、已验收的 M1Sub1 全部交付物及其他 Mod 壳层文件做任何持久化修改**；WP5 真机冒烟期间的临时挂载改动已 100% 回滚。全部决策闭环、接口细化与真机实证驱动的架构演进建议均集中汇总于本报告第六章（`SYNC-M2-01` ~ `SYNC-M2-06`）。

---

## 一、 子模块建设总览与验收结论

### 1.1 子模块职责定位与建设范围

`CAB_TaskExecutor` 运行于《文明5：美丽新世界（BNW v1.0.3.279）》客户端的 Lua 5.1 UI 沙箱内，定位为模块 1 的**高安全游戏内动作执行器（Guarded Action Executor & Two-Phase Settlement Engine）**。其核心职责是在严守活动回合门控、前置校验零写副作用、战争迷雾防侧信道与防误宣战护栏的前提下，复用已验收的 `CAB_Config` 与 `CAB_Collector` 同源口径，将智能体下达的单位战术动作、城防远程炮击、城市内政（买建筑/买单位/设生产队列/买地块）及安全下一回合指令精准驱动至原生 BNW 引擎接口，并配合调度层完成两段式异步结算与战后增量观测汇总。

对照《M1Sub2工作计划.md》，本子模块分设的 **规划阶段（`Plan`）+ 5 个串行工作包（`WP1` ~ `WP5`）** 已全部按期闭环：

| 阶段 / 工作包 | 核心交付目标 | 完成状态 | 完成日期 |
| :---: | :--- | :---: | :---: |
| **Plan** | 前置依赖核查、7 项关键设计决策（`D-01` ~ `D-07`）对齐、工作计划与进度看板编制 | ✅ 已完成 | 2026-11-27 |
| **WP1** | 独立有状态 `lupa.lua51` BNW 引擎桩底座 + `CAB_TaskExecutor.lua` 骨架、`Initialize`（E1）与基础安全守卫 | ✅ 已完成 | 2026-11-27 |
| **WP2** | 单位战术动作（8 种，`StartUnitAction` E2）与城防远程炮击（`StartCityRangeAttack` E3）及双圆心揭盲基线 | ✅ 已完成 | 2026-11-27 |
| **WP3** | 两段式异步结算与精准增量观测（`IsSettlementBusy` E8 + `FinalizeActionSettlement` E9） | ✅ 已完成 | 2026-11-27 |
| **WP4** | 城市内政（`PurchaseCityItem` E4、`SetCityProduction` E5、`PurchaseCityPlot` E6）与安全下一回合（`ExecuteEndTurn` E7） | ✅ 已完成 | 2026-11-27 |
| **WP5** | 全量双套件离线验收、《文明5：BNW》+ IGE 多轮真机实证、真机跨帧消息队列缺陷定位与方案 A 异步结算升级、临时挂载 100% 回滚及本验收报告编制 | ✅ 已完成 | 2026-11-27 |

### 1.2 总体自评结论

* **功能与契约完备度**：`CAB_Executor` 全部 **9 个导出函数（`E1` ~ `E9`）** 100% 实现；全面覆盖 8 种单位战术动作、城防远程炮击、建筑/单位双通道购买、4 类城市生产队列、买地块与守卫式安全下一回合，并经真机实证将 5 类发送引擎 NetMessage 的写动作（`UNIT_ACTION`、`CITY_ATTACK`、`BUY_PLOT`、`PURCHASE_ITEM`、`SET_PRODUCTION`）统一纳入两段式异步结算管线，彻底根除同帧回读滞后问题。
* **离线自动化验证**：
  * `python Civ5AgentBridge/tests/run_m1sub2_tests.py` 退出码 `0`——Lua 5.1 语法编译 **9/9 通过**（含 3 项负向语法拦截自检），有状态引擎桩跨模块联调测试 **`T-00` ~ `T-32` 共 33/33 通过**，红线违规 **0 次**，桩未实现方法调用 **0 次**；
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py` 退出码 `0`——语法 **8/8** + 桩测试 **36/36 通过**，已验收 M1Sub1 零回归。
* **真机实证验证**：在本机《文明5：BNW v1.0.3.279》（DX11，`Lua 5.1.4`）+ `Ingame Editor (v 39)` 真实对局中，通过三轮实机冒烟完整实证全部 **9 个导出接口** 与 **5 类 `settlementKind`**（含两轮硬阻塞守卫与真实推进 `Turn 0 → Turn 1`），`Logs/Lua.log` 累计 **1,948 行全程 0 条语法错误、0 条运行时错误、0 条堆栈报错**，完整结构化 JSON 实证均落盘 `ModUserData/Civ5AgentBridge-1.db`。
* **验收建议**：**`A-01` ~ `A-10` 全部 10 项验收指标均已达成，申请 M1 上级评审予以正式验收通过。**

---

## 二、 交付物清单与文件隔离边界核验

### 2.1 永久交付与修改文件清单（严格落于白名单内）

| 文件路径（相对 `Civ5AgentBridge/`） | 操作类型 | 规模（行数） | 核心交付内容与职责 |
| :--- | :---: | :---: | :--- |
| `mod/Lua/CAB_TaskExecutor.lua` | 新建 | 2,281 行 | 子模块 2 正式实现：仅 `include("CAB_Config")` 与 `include("CAB_InfoCollector")` 各一次，仅导出唯一全局表 `CAB_Executor`（精确 9 个公开接口），模块私有状态仅保留 `s_Initialized`（零实体缓存），全函数附中文 What/Why/IO 注释 |
| `tests/run_m1sub2_tests.py` | 新建 | 252 行 | 基于本机 `Python` + `lupa.lua51` 的三阶段离线自动化验收入口（9 文件 Lua 5.1 字节码编译 + 3 项负向语法自检 + 有状态桩测试运行器 + `--filter` 单测过滤 + 退出码 `0/1/2`） |
| `tests/m1sub2/engine_stubs.lua` | 新建 | 2,045 行 | 独立于 M1Sub1 的有状态 BNW v1.0.3.279 引擎桩：真实加载 `CAB_Config` + `CAB_InfoCollector` + `CAB_TaskExecutor`，支持移动/战斗/阵亡/攻城三态/揭盲/宣战与和约/买建筑与单位/生产队列/买地块跨帧异步消息队列（`plotBuyDelayTicks` & `cityActionDelayTicks`）与红线陷阱/迷雾侧信道/写操作全审计 |
| `tests/m1sub2/test_executor.lua` | 新建 | 1,945 行 | `T-00` ~ `T-32` 共 33 条结构化跨模块联调验收用例（+ `FW-01` 框架收尾审计），全覆盖 9 接口契约、6 条执行红线 `E-01`~`E-06`、5 类异步结算与超时兜底、D-05 守卫式自动跳过及 IGE 动态变阵 |
| `docs/M1/M1Sub2/M1Sub2工作计划.md` | 新建 | 232 行 | M1Sub2 前置评估、决策定稿（`D-01`~`D-07`）、6 条红线、9 接口详设、WP1~WP5 拆分与验收矩阵 |
| `docs/M1/M1Sub2/M1Sub2工作进度.md` | 新建并闭环 | ~165 行 | 多会话推进看板、待回写偏离台账（`SYNC-M2-01`~`SYNC-M2-06`）与 `Session 0`~`Session 5` 完整交接日志 |
| `docs/M1/M1Sub2/M1Sub2工作总结报告.md` | 新建 | 本文档 | M1Sub2 结项验收报告与上位文档回写建议书 |

### 2.2 临时挂载回滚与红线文件零污染核验（`D-01` / `A-10`）

1. **WP5 临时冒烟文件 100% 回滚**：在用户确认退出《文明5》进程后，已执行：
   * `git -C Civ5AgentBridge checkout -- mod/Civ5AgentBridge.modinfo mod/Lua/Civ5AgentBridgeUI.lua`；
   * 彻底删除临时脚本 `Civ5AgentBridge/mod/Lua/CAB_M1Sub2Smoke.lua`；
   * 执行 `scripts/deploy_mod.ps1 -ForceCopy -ClearCache`，将 `MODS/Civ5AgentBridge/` 镜像同步还原并清理全部 5 个 `cache/Civ5*.db` 缓存库。
2. **工作区最终 `git status --short` 隔离核验**：
   * 仅存在 M1Sub2 白名单内的交付文件（`mod/Lua/CAB_TaskExecutor.lua`、`tests/run_m1sub2_tests.py`、`tests/m1sub2/engine_stubs.lua`、`tests/m1sub2/test_executor.lua`、`docs/M1/M1Sub2/` 三份文档）；
   * **严禁修改清单零触碰**：`docs/M1/` 三份上位文档、顶层《01~03》文档、`docs/M1/M1Sub1/*`、`mod/Lua/CAB_Config.lua`、`mod/Lua/CAB_InfoCollector.lua`、`tests/run_m1sub1_tests.py`、`tests/m1sub1/*`、`mod/Civ5AgentBridge.modinfo`、`mod/Lua/Civ5AgentBridgeCore.lua`、`Civ5AgentBridgeJson.lua`、`Civ5AgentBridgeLoader.lua/.xml`、`Civ5AgentBridgeUI.lua/.xml`、`scripts/deploy_mod.ps1` **均为零持久化修改**。

---

## 三、 接口实现明细与关键工程机制说明

### 3.1 `CAB_Executor` 9 个导出接口实现矩阵（`E1` ~ `E9`）

| 编号 | 函数签名 | 结算模式 | 返回值 / 核心 DTO | 关键实现要点与官方引擎脚本依据 |
| :---: | :--- | :---: | :--- | :--- |
| **E1** | `CAB_Executor.Initialize()` | 同步 | `boolean` | 校验 `CAB_Config`（6 项核心结算/半径/日志键）与 `CAB_Collector`（全部 14 项公开函数）就绪后置 `s_Initialized = true`；零 `AirRaidCore` 探测。 |
| **E2** | `CAB_Executor.StartUnitAction(activePlayerID, unitID, actionType, targetX, targetY, allowDeclareWar)` | **两段式异步**（`UNIT_ACTION`） | `(ok, errMsg, baselineContext)` | 覆盖 8 种动作：`MOVE_STEP`（`CanUnitMoveThrough`+1UPT+相邻黑雾探路）、`MELEE_ATTACK`（陆海兵种域+禁攻+敌城快照）、`RANGE_ATTACK`（防迷雾侧信道）、`AIR_STRIKE`（纯原生 `MISSION_MOVE_TO`）、`SETUP_FOR_RANGED`/`FORTIFY`/`HEAL`/`SKIP_TURN`（`pcall` 临时选区探测与恢复）；采集双圆心联合 `revealedBefore`、战前可见敌军与敌城快照；默认拦截中立攻击，`allowDeclareWar=true` 经 `CanDeclareWar` 守卫后显式 `DeclareWar`。 |
| **E3** | `CAB_Executor.StartCityRangeAttack(activePlayerID, cityID, targetX, targetY, allowDeclareWar)` | **两段式异步**（`CITY_ATTACK`） | `(ok, errMsg, baselineContext)` | 校验 `CanRangeStrikeNow()`、目标格实时可见（`IsVisible`）且非隐形敌军（`InspectPlotUnits`），严禁探测迷雾/黑雾；交战或 `allowDeclareWar` 通过后参照 `WorldView.lua:519` 执行 `ClearSelectionList → SelectCity → SelectedCitiesGameNetMessage(GAMEMESSAGE_DO_TASK, TASK_RANGED_ATTACK) → SpecificCityInfoDirty → ClearSelectedCities`。 |
| **E4** | `CAB_Executor.PurchaseCityItem(activePlayerID, cityID, itemCategory, itemKeyOrId, yieldTypeStr)` | **短延迟异步**（`PURCHASE_ITEM`，0.10s） | `(ok, errMsg, baselineContext)` | 支持建筑/单位 × 金币/信仰双通道与 Type/ID 双入参；参照 `ProductionPopup.lua:136-161` 双层 `IsCanPurchase` 细分前置/已拥有 vs 余额不足（附报价）/叠栈冲突；记录购买前余额、建筑数与存活单位集快照，调用 `Game.CityPurchaseBuilding/Unit` + `SpecificCityInfoDirty`，经 WP5 方案 A 纳入短延迟异步结算精准回读扣费与新生 `spawned_unit_id`。 |
| **E5** | `CAB_Executor.SetCityProduction(activePlayerID, cityID, orderCategory, itemKeyOrId, clearQueue)` | **短延迟异步**（`SET_PRODUCTION`，0.10s） | `(ok, errMsg, baselineContext)` | 拦截傀儡/抵抗/焚城；支持 `BUILDING`/`UNIT`/`PROJECT`/`PROCESS` 4 类订单与 `CanConstruct`/`CanTrain`/`CanCreate`/`CanMaintain` 校验；参照 `ProductionPopup.lua:133` 调用 `Game.CityPushOrder(pCity, eOrder, itemId, false, clearQueue ~= false, true)` + `SpecificCityInfoDirty`，经 WP5 方案 A 纳入短延迟异步结算精准回读队列长度与当前生产项。 |
| **E6** | `CAB_Executor.PurchaseCityPlot(activePlayerID, cityID, plotX, plotY)` | **短延迟异步**（`BUY_PLOT`，0.10s） | `(ok, errMsg, baselineContext)` | 实时读取 `GameDefines.BUY_PLOTS_DISABLED == 0`（零缓存），拦截受限城；参照 `CityView.lua:2003, 2143` 双层 `CanBuyPlotAt` 细分余额不足 vs 非合法范围；调用 `Network.SendCityBuyPlot`（城市界面打开时安全调 `UI.UpdateCityScreen()`）返回 `BUY_PLOT` 基线。 |
| **E7** | `CAB_Executor.ExecuteEndTurn(activePlayerID, autoSkipReadyUnits)` | **同步提交 + 跨回合** | `(ok, errMsg, EndTurnResultDTO \| nil)` | 落实 `D-05` 诊断优先与守卫式自动跳过：先查 `CAB_Collector.GetEndTurnStatus`；仅 `autoSkipReadyUnits == true` 且为待命单位类阻塞时才跳过非自动化、非 `IsPromotionReady()`、非同类非法叠栈的存活待命单位（保留军民/空军合法叠栈，经 `pcall` 无条件恢复原选区）并复查；硬阻塞零浪费直接返 `BLOCKED`；无阻塞调 `Game.DoControl(CONTROL_ENDTURN)` 立返 `WAITING_NEXT_TURN`。 |
| **E8** | `CAB_Executor.IsSettlementBusy(baselineContext)` | 帧轮询只读 | `boolean` | 统一支持全部 **5 类 `settlementKind`**：`UNIT_ACTION`（单位/地块 `IsBusy`/`IsFighting`）、`CITY_ATTACK`（目标格 `IsFighting`）、`BUY_PLOT`（`GetOwner() ~= activePlayerID`）、`PURCHASE_ITEM`（建筑数递增或新生 `spawned_unit_id` 现身）、`SET_PRODUCTION`（追加队列递增或原生 `GetProductionBuilding/Unit/Project/Process == itemId`）。 |
| **E9** | `CAB_Executor.FinalizeActionSettlement(baselineContext, settleWaitMs)` | 结算采样只读 | 对应结构化结算 DTO | 全程只读零写入、零迷雾侧信道；统一附带 `settle_wait_ms` 与 `timed_out`；双圆心联合采样消除 1 格移动揭盲假阳性；精准汇总 `newly_spotted_enemies`（过滤隐形）、`target_enemy_after`、`unit_died`、`target_city_after`、`city_after`、`war_declared`、买地真实归属、买建筑/单位真实扣费与 `spawned_unit_id`、设产最新队列长度；异常/超时兜底零未捕获异常。 |

### 3.2 6 条执行层安全红线（`E-01` ~ `E-06`）工程落实

1. **`E-01` 非活动回合零写入**：全部 6 个写接口入口强制通过 `validateActivePlayerWriteGate`（合法存活玩家 + `IsTurnActive() == true` + `not Game.IsProcessingMessages()`），否则立即拒返且零写入。
2. **`E-02` 前置校验失败零副作用与选区无痕恢复**：两段式宣战预检（先用 `bNeedWar = false` 校验射程/视野再决定是否宣战）、原地动作探测与 `ExecuteEndTurn` 自动跳过均由 `pcall` 包裹并在退出前无条件恢复原选中单位或清空选区。
3. **`E-03` 远程攻击防迷雾侧信道**：`RANGE_ATTACK`、`AIR_STRIKE`、`StartCityRangeAttack` 仅允许对实时可见格或已探索非己方城市格校验，对普通迷雾与黑雾格及隐形单位直接拦截，确保 `CanRangeStrikeAt` 违禁探测 `== 0`。
4. **`E-04` 防误宣战与无弹窗显式宣战**：默认 `allowDeclareWar = false` 阻断对中立势力的任何攻击；为 `true` 时强制先查 `CanDeclareWar(targetTeam)`（和约期拦截），通过后显式调用 `DeclareWar(targetTeam)` 避免模态弹窗卡死自动化，并在结算结果中透出 `war_declared = true`。
5. **`E-05` 黑雾探路零信息泄露**：`MOVE_STEP` 允许非空军存活有移动力单位向相邻 1 格黑雾探路，前置校验不读取黑雾地形/单位属性，战后由双圆心基线精准统计新揭开格数。
6. **`E-06` 原生 BNW + IGE 零缓存兼容**：源码零出现 `CanMoveOrAttackInto` / `AirRaidCore` / `AR_ExecuteStrike` / `AR_EnumerateTargets` / `SetScriptData` / `UI.SetInterfaceMode`；`GameDefines` 按次实时读取，统一过滤 `nil` / `IsDead()` / `IsDelayedDeath()` 实体。

---

## 四、 双层验收测试执行结果

### 4.1 第一层：离线 Lua 5.1 语法检查与有状态引擎桩跨模块联调

执行命令：`python Civ5AgentBridge/tests/run_m1sub2_tests.py` 与 `python Civ5AgentBridge/tests/run_m1sub1_tests.py`（`Python` + `lupa.lua51` 标准 Lua 5.1 运行时）

* **M1Sub2 套件（`run_m1sub2_tests.py`）**：
  * 阶段 1 Lua 5.1 语法编译：**9 通过 / 0 失败 / 0 待创建** + **3/3 负向语法自检通过**（拒绝语法错误、`goto`、`//`）；
  * 阶段 2 有状态引擎桩跨模块联调（真实加载 `CAB_Config` + `CAB_InfoCollector` + `CAB_TaskExecutor`）：**`T-00` ~ `T-32` 共 33/33 通过，0 失败，0 跳过**，退出码 **`0`**；
  * 守卫审计累计：**红线违规 `0` 次，桩未实现方法 `0` 次**，有效写操作记录 65 次。
* **M1Sub1 套件复跑回归（`run_m1sub1_tests.py`）**：
  * 语法 **8/8** + 负向自检 **3/3** + 桩测试 **36/36 通过**，只读守卫违规 `0` 次，退出码 **`0`**（M1Sub1 零回归）。

| 用例区间 | 覆盖主题 | 条数 | 结果 | 核心验证点摘要 |
| :---: | :--- | :---: | :---: | :--- |
| `T-00` ~ `T-01` | 加载洁净、静态红线与跨模块联调 | 2 | 2/2 通过 | 仅新增唯一全局 `CAB_Executor`（精确 9 项导出）；源码零禁令符号；`Initialize()` 与真实 `CAB_InfoCollector` 联调正常 |
| `T-02` ~ `T-08` | 有状态引擎桩核心演进与红线陷阱自检 | 7 | 7/7 通过 | 移动揭盲、战斗帧推进、和约宣战、城市内政、异步买地、结束回合及红线陷阱（`CanMoveOrAttackInto` / `SetInterfaceMode` / `SetScriptData`） |
| `T-09` ~ `T-17` | WP2：8 种单位动作、城防炮击与双圆心基线 | 9 | 9/9 通过 | E-01 写门控、E-02 选区恢复、E-03 迷雾/隐形 `queriesOnForbiddenFog == 0`、E-04 中立拦截/和约/显式宣战、E-05 黑雾探路、原生空袭、双圆心基线 |
| `T-18` ~ `T-24` | WP3：两段式异步结算与增量观测精度 | 7 | 7/7 通过 | `IsSettlementBusy` 帧推进、双圆心消假阳性揭盲、新敌军过滤隐形、反击阵亡、攻城残血/占领/毁城三态、城防炮击 `city_after`、买地成功与超时兜底、结算全程零写 |
| `T-25` ~ `T-32` | WP4 & WP5 升级：城市内政短异步结算、安全下一回合与 IGE 联调 | 8 | 8/8 通过 | `PurchaseCityItem`（建筑/单位 × 金币/信仰、`PURCHASE_ITEM` 短异步结算与超时兜底）、`SetCityProduction`（4 类订单、`clearQueue`、`SET_PRODUCTION` 短异步结算与超时兜底）、`PurchaseCityPlot`（`BUY_PLOTS_DISABLED` + 短结算）、`ExecuteEndTurn`（硬阻塞零浪费、待命跳过、保护晋升/叠栈）、全量门控防御与 IGE 零缓存 |

### 4.2 第二层：《文明5：BNW v1.0.3.279》+ IGE 真机实证冒烟（`WP5` / `A-09`）

* **实测环境**：Windows 本机 `Sid Meier's Civilization V (DX11)` BNW `v1.0.3.279`（内置 `Lua 5.1.4`），同时加载 `Civ5 Agent Command Bridge`（临时挂载 `CAB_Config.lua`、`CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua`、`CAB_M1Sub2Smoke.lua`）与 `Ingame Editor (v 39)`，进入单人游戏（玩家 0：中国文明，建立首都北京，IGE 注金 `+2000` 并在首都 2 格内刷蛮族勇士）。
* **真机暴露并彻底根治的关键底层发现（方案 A 升级实证）**：
  * 首轮与次轮真机探针实证：`Game.CityPushOrder`、`Game.CityPurchaseBuilding`、`Game.CityPurchaseUnit` 在真实 BNW DLL 中均与 `Network.SendCityBuyPlot` 一样，**通过 C++ NetMessage 消息队列在下一帧（~16–100ms）落地生效**。原设计假设其“同帧同步”，导致同帧回读拿到 `cost_paid = 0`、`spawned_unit_id = nil`、`order_queue_length = 0` 的旧快照；
  * 经用户拍板采用 **方案 A**，在 WP5 内将 `PurchaseCityItem`（`PURCHASE_ITEM`）与 `SetCityProduction`（`SET_PRODUCTION`）升级为与 `PurchaseCityPlot`（`BUY_PLOT`）完全对称的 `0.10s` 短延迟两段式异步结算，并补齐离线跨帧桩测试（`cityActionDelayTicks = 2`）与超时兜底验证后进行第三轮真机复测；
  * **最终真机复测结果**：全部 10 项可执行断言 **100% PASS（`10P / 2S / 0F`）**，合并首轮移动/驻扎/真实换回合实证后，**9 个导出接口 + 5 类 `settlementKind` + 阻塞/切回合全分支实现真机 100% 闭环**；`Logs/Lua.log` 累计 **1,948 行，0 条语法错误、0 条运行时错误、0 条堆栈追踪**。
* **真机量化实证汇总表**：

| 冒烟项 | 覆盖接口 / `settlementKind` | 实机执行现象与量化回读数据（来自 `Civ5AgentBridge-1.db` & `Lua.log`） | 实机结论 |
| :---: | :--- | :--- | :---: |
| **S01 / S02** | `Initialize`（E1）+ E-02 负向守卫 | `init_ok = true`、精确 9 项导出；6 类非法入参全部拒返且 `selection_restored = true` | ✅ PASS |
| **S03** | `ExecuteEndTurn(pid, false)`（E7） | 建城未设产时精准返回 `ok = false, status = "BLOCKED", blocking_type = "ENDTURN_BLOCKING_PRODUCTION", blocking_city_id = 8192` | ✅ PASS |
| **S04** | `SetCityProduction`（E5 / `SET_PRODUCTION`） | 清空设建纪念碑：`109ms`（7 帧）`queue_len_1 = 1, timed_out = false`；追加训练工人：`125ms`（7 帧）`queue_len_2 = 2, current_production = "紀念碑", turns_left = 5, timed_out = false` | ✅ PASS |
| **S05** | `PurchaseCityItem` 建筑（E4 / `PURCHASE_ITEM`） | 负向非法建筑被拒；金币购 `BUILDING_MONUMENT`：`110ms`（7 帧）精准回读 `purchased = true, expected_cost = 200, cost_paid = 200, gold = 2000 → 1800, timed_out = false`（文化同步 `+1 → +3`） | ✅ PASS |
| **S06** | `PurchaseCityItem` 单位（E4 / `PURCHASE_ITEM`） | 金币购 `UNIT_WORKER`：`109ms`（7 帧）精准回读 `purchased = true, expected_cost = 220, cost_paid = 220, gold = 1800 → 1580, spawned_unit_id = 24576, timed_out = false` | ✅ PASS |
| **S07** | `PurchaseCityPlot`（E6 / `BUY_PLOT`） | 越界 `(9999,9999)` 被拒；购地 `(27,15)`：`109ms`（6 帧）`purchased = true, expected_cost = 30, cost_paid = 30, gold = 1580 → 1550, new_owner_id = 0, timed_out = false`（地图边境实时扩张） | ✅ PASS |
| **S08** | `StartCityRangeAttack`（E3 / `CITY_ATTACK`） | 黑雾格被拦截（`fog_blocked = true`）；炮击 `(27,12)` 蛮族勇士：`360ms`（22 帧）`timed_out = false`，目标血量 `100 → 73 HP`（首轮同样命中 `100 → 81 HP`） | ✅ PASS |
| **S09** | `StartUnitAction(MELEE_ATTACK)`（E2 / `UNIT_ACTION`） | 勇士 `16385` 近战攻击 `(27,12)` 蛮族勇士：`359ms`（21 帧）`timed_out = false`，我方 `100 → 79 HP`、蛮族 `73 → 38 HP` | ✅ PASS |
| **S10 / S11** | `StartUnitAction(MOVE_STEP / FORTIFY)`（E2 / `UNIT_ACTION`） | 首轮实证：`MOVE_STEP` `(4,14)→(4,15)` `359ms`（20 帧）`moves_left_after = 1, newly_revealed = 0`；`FORTIFY` `360ms`（21 帧）`can_act_after = false` | ✅ PASS |
| **S12** | `ExecuteEndTurn(pid, true)`（E7） | 1. 未选科研时精准触发 D-05 硬阻塞守卫（`mode = "HARD_BLOCK_GUARDED", auto_skipped_count = 0, blocking = "ENDTURN_BLOCKING_RESEARCH"`）；<br>2. 选定科研后真实调用 `CONTROL_ENDTURN`（`mode = "TURN_ENDED", status = "WAITING_NEXT_TURN"`），游戏顺利由 **Turn 0 推进至 Turn 1** | ✅ PASS |

---

## 五、 验收标准矩阵逐项对账表（`A-01` ~ `A-10`）

| 验收项 | 验收内容 | 判定标准 | 实测验证证据 | 验收结论 |
| :---: | :--- | :--- | :--- | :---: |
| **A-01** | Lua 5.1 语法与加载洁净 | 通过 `lupa.lua51` 编译（含 3 项负向自检）；仅 `include("CAB_Config")` 与 `include("CAB_InfoCollector")` 各一次；仅导出 `CAB_Executor`（精确 9 函数） | `run_m1sub2_tests.py` 阶段 1 `9/9` + 负向 `3/3` 通过；`T-00` 源码静态检查与真机 `S01` 精确 9 项导出核验 | ✅ **通过** |
| **A-02** | 9 接口签名与 DTO 契约 | 全部 9 接口签名、三元组返回值与 DTO 字段完整对齐（对象表带 `__is_object = true`，可空字段省略，零 `CAB_Json` 依赖） | `T-00`、`T-09`~`T-32` 契约断言 + 真机 `CAB_JsonEncode` 全字段无损落盘 SQLite | ✅ **通过** |
| **A-03** | 活动回合门控与失败零副作用 | 满足 E-01 / E-02：非活动回合或消息队列忙时写调用 = 0；前置校验失败写调用 = 0 且恢复原选区 | `T-09`、`T-15`、`T-25`~`T-28`、`T-31` 写审计 = 0 + 真机 `S02` `selection_restored = true` | ✅ **通过** |
| **A-04** | 同源校验、迷雾防侧信道与宣战护栏 | 满足 E-03 / E-04 / E-05：零 `CanMoveOrAttackInto`；普通迷雾/黑雾 `queriesOnForbiddenFog == 0`；默认防误宣战 + 可控显式宣战 + 和约拦截；黑雾探路不泄露 | `T-00` 静态扫描 + `T-10`~`T-16` 专项用例 + 真机 `S08` `fog_blocked = true` | ✅ **通过** |
| **A-05** | 两段式异步结算与增量精度 | 双圆心联合采样消揭盲假阳性；精准汇总 5 类 `settlementKind`、`newly_spotted_enemies`（滤隐形）、`target_enemy_after`、`unit_died`、`target_city_after`、`city_after`、`timed_out` | `T-17`~`T-28` 全覆盖 + 真机 `S04`~`S11` 全部 5 类 `settlementKind` 跨帧结算实证（`timed_out = false`） | ✅ **通过** |
| **A-06** | 城市内政全能力精度 | `PurchaseCityItem`（建筑/单位 × 金币/信仰、误差细分、新生 `spawned_unit_id`）、`SetCityProduction`（4 类订单 + `clearQueue`）、`PurchaseCityPlot`（`BUY_PLOTS_DISABLED` + 余额/越界细分） | `T-25`~`T-28`、`T-32`（含跨帧异步与超时兜底）+ 真机 `S04`/`S05`/`S06`/`S07` 实证精准扣费与新生 ID | ✅ **通过** |
| **A-07** | `ExecuteEndTurn` 安全闭环 | 默认 `false` 遇阻立返 `blocking_info`；为 `true` 时遵循 D-05 守卫式跳过（硬阻塞不浪费行动力，保护晋升/叠栈）；无阻塞立返 `WAITING_NEXT_TURN` | `T-29`、`T-30`、`T-32` + 真机 `S03` / `S12`（硬阻塞拦截与 `Turn 0 → Turn 1` 真实切换） | ✅ **通过** |
| **A-08** | 原生 BNW + IGE 兼容与零外部 Mod | 零 `AirRaidCore`/`AR_*`/`SetScriptData`/`SetInterfaceMode`；零实体缓存；真实联调 `CAB_InfoCollector` 且 M1Sub1 零回归 | `T-00` 静态扫描 + `T-01` / `T-32` + `run_m1sub1_tests.py` `36/36` + 真机 IGE 实证 | ✅ **通过** |
| **A-09** | 临时真机冒烟零报错与 100% 回滚 | 本机原生 BNW + IGE 跑通全核心执行接口，`Logs/Lua.log` 零报错，临时改动 100% 回滚 | 累计三轮真机实证覆盖全部 9 接口，`Logs/Lua.log` 1,948 行零报错，临时挂载已回滚并清理缓存 | ✅ **通过** |
| **A-10** | 文件隔离纪律与结项文档交付 | 禁止清单文件零持久化修改；《M1Sub2工作进度.md》与《M1Sub2工作总结报告.md》（含 `SYNC-M2-*`）交付闭环 | 回滚后 `git status --short` 仅留白名单文件；本报告与进度文档全部闭环 | ✅ **通过** |

---

## 六、 上位设计文档回写建议清单（`SYNC-M2-01` ~ `SYNC-M2-06`）

以下为 M1Sub2 实施与真机验证过程中形成的**上位文档同步建议台账**，提请上级 M1 评审会话在验收通过后统一回写至 `docs/M1/` 下对应文档：

### `SYNC-M2-01`：决策项 2 & 3 正式拍板闭环（对应决策 `D-01`、`D-05`）
* **目标文档与章节**：`docs/M1/模块设计进度.md` §二 决策项 2 & 3
* **变更类型**：决策闭环
* **建议回写内容**：正式确认城市内政全 5 项范围（买建筑 + 买地块 + 买单位 + 设生产队列 + 城防炮击）以及 `ExecuteEndTurn` 安全诊断优先 + 守卫式自动跳过 + 立即回执策略。

### `SYNC-M2-02`：增补可控显式宣战参数 `allowDeclareWar` 与 `war_declared` 标记（对应决策 `D-02`、`D-03`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §5.2、§5.3、§七 IPC 映射表
* **变更类型**：接口增补（向后兼容）
* **建议回写内容**：为 `StartUnitAction`（第 6 参）与 `StartCityRangeAttack`（第 5 参）增补可选参数 `allowDeclareWar`（默认 `false`）；细化先检 `pTeam:CanDeclareWar(targetTeam)`（和约期拦截）再显式调 `pTeam:DeclareWar(targetTeam)` 的无弹窗宣战护栏及结算结果 `war_declared` / `war_declared_target_player_id` / `war_declared_target_team_id` 字段，并在 IPC 表 `execute_unit_action` / `execute_city_attack` 中登记 `allow_declare_war`。

### `SYNC-M2-03`：细化 `FinalizeActionSettlement` 双圆心揭盲与扩展结算契约（对应决策 `D-04`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §5.8
* **变更类型**：细化 / 增补
* **建议回写内容**：明确动作前 `revealedBefore` 采用双圆心联合采样 `(before, min(r+1, MAX_SCAN_RADIUS)) ∪ (target, r)` 以消除 1 格移动揭盲假阳性；统一所有结算 DTO 附带 `timed_out`；明确 `BUY_PLOT` 按实时归属 `GetOwner() == activePlayerID` 判真；为 `CITY_ATTACK` 补充 `city_id` / `city_after`，为攻城动作补充 `target_city_after`（含 `city_id` / `hp` / `captured` / `destroyed`）。

### `SYNC-M2-04`：细化 `ExecuteEndTurn` 守卫式自动跳过规则（对应决策 `D-05`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §5.7
* **变更类型**：接口细化
* **建议回写内容**：明确当 `autoSkipReadyUnits == true` 时先查 `CAB_Collector.GetEndTurnStatus`，仅当前阻塞为 `ENDTURN_BLOCKING_UNITS` / `ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS` 才跳过非自动化、非 `IsPromotionReady()`、非同类非法叠栈的存活待命单位并经 `pcall` 恢复原选区后再复查；存在硬阻塞时零写入直返 `BLOCKED`，绝不浪费单位行动力。

### `SYNC-M2-05`：同步模块 1 开发进度看板状态（对应决策 `D-01`、`D-07`）
* **目标文档与章节**：`docs/M1/模块设计进度.md` §三「阶段二：模块 1 编码与验证多会话拆分计划」
* **变更类型**：进度状态同步
* **建议回写内容**：将 **`M1-S3`（任务执行子模块——军事与异步结算）** 与 **`M1-S4`（任务执行子模块——城市内政与安全下一回合）** 状态统一更新为 `✅ 已完成`（含离线有状态桩测试与真机实证）。

### `SYNC-M2-06`（WP5 真机实证新增）：将 `PurchaseCityItem` 与 `SetCityProduction` 统一升级为短延迟两段式异步结算
* **目标文档与章节**：`docs/M1/模块设计说明.md` §3.2、`docs/M1/模块内部接口设计.md` §5.4、§5.5、§5.8
* **变更类型**：**架构与契约修正（由 WP5 真机实证驱动，经用户确认方案 A）**
* **背景与真机实证依据**：WP5 在本机《文明5：BNW v1.0.3.279》实测证实，`Game.CityPurchaseBuilding`、`Game.CityPurchaseUnit` 与 `Game.CityPushOrder` 底层均经引擎 C++ NetMessage 队列跨帧生效（约 16–100ms），调用后同帧立即回读会返回 `cost_paid = 0`、`spawned_unit_id = nil`、`order_queue_length = 0` 的陈旧值。
* **建议回写内容**：
  1. 将 `CAB_Executor.PurchaseCityItem`（`settlementKind = "PURCHASE_ITEM"`）与 `CAB_Executor.SetCityProduction`（`settlementKind = "SET_PRODUCTION"`）的返回契约统一对齐为与 `PurchaseCityPlot`（`BUY_PLOT`）完全对称的 `(ok, errMsg, baselineContext)`（`minWaitSec = CAB_Config.PLOT_BUY_SETTLE_SEC = 0.10`，`maxTimeoutSec = CAB_Config.MAX_SETTLE_TIMEOUT_SEC = 1.50`）；
  2. 在 `IsSettlementBusy` 与 `FinalizeActionSettlement` 契约中正式扩充 `PURCHASE_ITEM` 与 `SET_PRODUCTION` 两类 `settlementKind`（共 5 类），统一输出精准扣费、新生 `spawned_unit_id`、最新 `city_summary_after`、队列长度、`settle_wait_ms`、`timed_out` 及超时兜底 `error_reason`。

---

## 七、 后续子模块衔接指引与待 `M1-S5 / M1-S6` 闭环事项

1. **供调度装配层（`M1-S5 CAB_Dispatcher`）的统一异步结算接入指引**：
   * 经 `SYNC-M2-06` 统一后，除 `ExecuteEndTurn` 为同步提交/立返外，其余 **全部 5 个引擎写动作接口**（`StartUnitAction`、`StartCityRangeAttack`、`PurchaseCityItem`、`SetCityProduction`、`PurchaseCityPlot`）均统一返回 `(ok, errMsg, baselineContext)`，调度层只需维护单一 `g_PendingSettlement` 帧轮询状态机，按 `baselineContext.minWaitSec`（军事 `0.35s` / 内政 `0.10s`）与 `baselineContext.maxTimeoutSec`（`1.50s`）轮询 `CAB_Executor.IsSettlementBusy(baselineContext)`，就绪或超时后调用 `CAB_Executor.FinalizeActionSettlement(baselineContext, elapsedMs)` 并通过 `CAB_ExternalIO` 回写 JSON 响应即可；
   * VFS 加载顺序：在 `.modinfo` 中将 `Lua/CAB_Config.lua`、`Lua/CAB_InfoCollector.lua`、`Lua/CAB_TaskExecutor.lua` 均声明为 `<File import="1">`，且更新 `.modinfo` 后务必在游戏完全退出状态下执行 `scripts/deploy_mod.ps1 -ForceCopy -ClearCache`。
2. **留待 `M1-S6`（模块 1 全功能联调验收）闭环的场景**：
   * 空军基地远程轰炸（`AIR_STRIKE` 原生 `MISSION_MOVE_TO`）、中立文明/城邦显式 `allowDeclareWar = true` 无弹窗宣战及攻城占领/毁城三态的端到端外部 MCP `--mode live` 实测（以上分支均已在 `T-11`、`T-13`、`T-14`、`T-20`、`T-21` 离线有状态桩中完成 100% 逻辑与红线覆盖）。
