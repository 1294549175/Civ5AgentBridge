# M1Sub2（游戏内任务执行子模块 `CAB_TaskExecutor`）工作进度与多会话交接记录

> [!NOTE]
> 本文档用于跨会话追踪 **M1Sub2：游戏内任务执行子模块（`CAB_TaskExecutor`）** 的计划确认、分包编码、离线与实机验收进度及交接上下文。每次新会话开始前应首先阅读本文档，完成后就地更新对应状态与交接日志。
>
> **红线提醒**：本子模块全过程**严禁持久化修改**上位三文档（`docs/M1/模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）、已验收的 M1Sub1 文件（`CAB_Config.lua`、`CAB_InfoCollector.lua`、`tests/m1sub1/*`、`tests/run_m1sub1_tests.py`）以及其他 Mod 壳层文件。全部需要同步回写上位文档的变更建议，统一先登记于本文档「四、待上级评审回写的文档偏离与增补台账」，最终汇总进《M1Sub2工作总结报告.md》。

---

## 一、 当前总览看板

| 项目 | 当前状态 |
| :--- | :--- |
| **所属上级模块** | 模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`） |
| **本子模块范围** | 子模块 2：游戏内任务执行子模块（`CAB_TaskExecutor.lua` + 独立有状态测试套件，覆盖原 `M1-S3` + `M1-S4`） |
| **前置可启动性评估** | ✅ **可立即启动**（全部依赖 `CAB_Config.lua` 与 `CAB_InfoCollector.lua` 已于 2026-11-27 通过 M1Sub1 验收） |
| **总体阶段** | ✅ **M1Sub2 全部工作包（WP1~WP5）已完成并提交《M1Sub2工作总结报告.md》，待上级 M1 评审验收** |
| **当前待执行工作包** | **无（已结项闭环）** |
| **最近一次测试结果** | ✅ `run_m1sub2_tests.py` 全绿（语法 9/9 + 负向自检 3/3，桩测试 33/33，红线违规 0，未实现方法 0）；`run_m1sub1_tests.py` 36/36 零回归；真机 BNW+IGE 全部 9 接口 + 5 类异步结算冒烟闭环，`Logs/Lua.log` 1,948 行零报错 |

---

## 二、 决策确认登记表（来自 2026-11-27 `/grill-me` 设计对齐）

| 编号 | 决策要点 | 已确认方案 | 状态 |
| :---: | :--- | :--- | :---: |
| **D-01** | 文件隔离边界与接口范围 | 沿用 M1Sub1 严格隔离纪律，不动上位三文档、M1Sub1 已验收文件与其余 Mod 文件；完整实现 `CAB_Executor` 全部 9 个导出接口（含买单位、设生产、城市远程炮击） | ✅ 已确认 |
| **D-02** | 前置校验、迷雾与防误宣战 | 活动回合/消息队列门控 + 复用 `CAB_Collector` `H4`~`H7` 同源校验 + 严禁对普通迷雾/黑雾调 `CanRangeStrikeAt` + 校验失败零副作用恢复原选区；默认拦截攻中立，支持向后兼容可选参数 `allowDeclareWar`（默认 `false`） | ✅ 已确认 |
| **D-03** | 显式无弹窗宣战机制 | 当 `allowDeclareWar == true` 且目标为非交战中立势力时，先检 `CanDeclareWar(targetTeam)`（和约期拦截），通过则显式调 `DeclareWar(targetTeam)` 再下发攻击，并在结果中记录 `war_declared = true` | ✅ 已确认 |
| **D-04** | 异步结算与增量观测精度 | `revealedBefore` 采用双圆心联合采样 `(before, r+1) ∪ (target, r)` 消除移动边缘揭盲假阳性；结算附带 `timed_out`；`BUY_PLOT` 按真实归属判定 `purchased`；攻城/城防炮击补充 `target_city_after` 与 `city_after` | ✅ 已确认 |
| **D-05** | `ExecuteEndTurn` 安全策略 | 同步拍板《模块设计进度.md》§二 决策项 3：默认 `autoSkipReadyUnits = false` 返回完整阻塞诊断；为 `true` 时先查 `GetEndTurnStatus`，仅待命单位类阻塞才守卫式跳过（硬阻塞绝不浪费行动力）；无阻塞调 `CONTROL_ENDTURN` 立即回执 `WAITING_NEXT_TURN` | ✅ 已确认 |
| **D-06** | 双层验收与测试桩架构 | 新建独立 `tests/run_m1sub2_tests.py` + `tests/m1sub2/*`（零改动 `tests/m1sub1/*`），在 `lupa.lua51` 有状态引擎桩上真实联调 `CAB_Config` + `CAB_InfoCollector` + `CAB_TaskExecutor`；WP5 配合原生 BNW + IGE 临时真机冒烟并 100% 回滚 | ✅ 已确认 |
| **D-07** | WP 拆分、命名与本会话边界 | 统一命名 `M1Sub2工作计划.md` / `M1Sub2工作进度.md` / `M1Sub2工作总结报告.md`；拆分 `WP1` ~ `WP5` 串行推进；本会话仅产出计划与进度两份文档，待确认后启动 WP1 | ✅ 已确认 |

---

## 三、 工作包进度追踪表（`WP1` ~ `WP5`）

| 编号 | 工作包名称 | 计划涉及文件 | 状态 | 实测摘要（通过/失败/红线审计） | 完成日期 |
| :---: | :--- | :--- | :---: | :--- | :---: |
| **Plan** | 编制 M1Sub2 工作计划与进度文档 | `docs/M1/M1Sub2/M1Sub2工作计划.md`<br>`docs/M1/M1Sub2/M1Sub2工作进度.md` | ✅ 已完成 | 已完成 `D-01` ~ `D-07` 全部分支设计对齐，两份文档已落盘待用户审阅确认 | 2026-11-27 |
| **WP1** | 有状态引擎桩底座 + `CAB_TaskExecutor` 骨架与 `Initialize` | `tests/run_m1sub2_tests.py`<br>`tests/m1sub2/engine_stubs.lua`<br>`tests/m1sub2/test_executor.lua`<br>`mod/Lua/CAB_TaskExecutor.lua` | ✅ 已完成 | 语法 9/9（含 3 项负向自检）；桩测试 9/9（`T-00`~`T-08`）；红线违规 0，未实现方法 0；`run_m1sub1_tests.py` 36/36 零回归 | 2026-11-27 |
| **WP2** | 军事动作下发（`StartUnitAction` 8 种）与城防远程炮击（`StartCityRangeAttack`） | `mod/Lua/CAB_TaskExecutor.lua`<br>`tests/m1sub2/test_executor.lua` | ✅ 已完成 | 语法 9/9（含 3 项负向自检）；桩测试 18/18（`T-00`~`T-17`）；红线违规 0，未实现方法 0；`run_m1sub1_tests.py` 36/36 零回归 | 2026-11-27 |
| **WP3** | 两段式异步结算与精准增量观测（`IsSettlementBusy` + `FinalizeActionSettlement`） | `mod/Lua/CAB_TaskExecutor.lua`<br>`tests/m1sub2/test_executor.lua` | ✅ 已完成 | 语法 9/9（含 3 项负向自检）；桩测试 25/25（`T-00`~`T-24`，`--filter WP3` 7/7）；红线违规 0，未实现方法 0；`run_m1sub1_tests.py` 36/36 零回归 | 2026-11-27 |
| **WP4** | 城市内政（买建筑/单位/地块、设生产）与安全下一回合（`ExecuteEndTurn`） | `mod/Lua/CAB_TaskExecutor.lua`<br>`tests/m1sub2/test_executor.lua` | ✅ 已完成 | 语法 9/9（含 3 项负向自检）；桩测试 33/33（`T-00`~`T-32`，`--filter WP4` 8/8）；红线违规 0，未实现方法 0；`run_m1sub1_tests.py` 36/36 零回归 | 2026-11-27 |
| **WP5** | 全量离线验收 + 原生 BNW/IGE 临时真机冒烟回滚 + 工作总结报告 | 临时挂载验证并 100% 回滚<br>方案 A 升级 `PurchaseCityItem`/`SetCityProduction` 短异步结算<br>`docs/M1/M1Sub2/M1Sub2工作总结报告.md` | ✅ 已完成 | 离线双套件回滚后全绿（M1Sub2 33/33 + M1Sub1 36/36，红线违规 0）；真机 BNW+IGE 实证全部 9 接口 + 5 类异步结算，`Logs/Lua.log` 1,948 行零报错；临时挂载已 100% 回滚并清缓存；总结报告已交付 | 2026-11-27 |

---

## 四、 待上级评审回写的文档偏离与增补台账

> 本台账记录相对 `docs/M1/` 三份上位文档的**决策闭环项、接口细化项与增补项**，严禁在 M1Sub2 期间直接修改上位文档，待 WP5 汇总至《M1Sub2工作总结报告.md》由上级评审验收后统一回写：

| 台账编号 | 涉及上位文档与章节 | 类型 | 内容摘要 | 对应决策 |
| :---: | :--- | :---: | :--- | :---: |
| **SYNC-M2-01** | `模块设计进度.md` §二 决策项 2 & 3 | 决策闭环 | 正式确认城市内政全 5 项范围（买建筑 + 买地块 + 买单位 + 设生产 + 城市炮击）与 `ExecuteEndTurn` 安全诊断优先 + 守卫式自动跳过 + 立即回执策略，推进 `D-06` 审查闭环。 | D-01、D-05 |
| **SYNC-M2-02** | `模块内部接口设计.md` §5.2、§5.3、§七 | 增补 | 为 `StartUnitAction`（第 6 参）与 `StartCityRangeAttack`（第 5 参）增补向后兼容的可选参数 `allowDeclareWar`（默认 `false`），细化显式 `CanDeclareWar` + `DeclareWar` 无弹窗宣战机制与 `war_declared` 结算标记，并在 IPC 表 `execute_unit_action` / `execute_city_attack` 中登记 `allow_declare_war`。 | D-02、D-03 |
| **SYNC-M2-03** | `模块内部接口设计.md` §5.8 | 细化 / 增补 | 细化 `FinalizeActionSettlement` 精准契约：双圆心联合揭盲基线 `(before, r+1) ∪ (target, r)`、`timed_out` 标志、`BUY_PLOT` 按真实归属判定 `purchased`、以及 `CITY_ATTACK` 的 `city_after` 与攻城的 `target_city_after` 扩展字段。 | D-04 |
| **SYNC-M2-04** | `模块内部接口设计.md` §5.7 | 细化 | 细化 `ExecuteEndTurn` 的守卫式自动跳过规则：当 `autoSkipReadyUnits == true` 时先查 `GetEndTurnStatus`，仅当前阻塞为 `ENDTURN_BLOCKING_UNITS` / `ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS` 才跳过非晋升非叠栈待命单位并复查，避免已有硬阻塞时浪费行动力。 | D-05 |
| **SYNC-M2-05** | `模块设计进度.md` §三 | 状态同步 | M1Sub2 独立交付 `CAB_TaskExecutor.lua` 及完整有状态测试/真机冒烟验证，覆盖原 `M1-S3` 与 `M1-S4` 两个会话任务包；验收通过后同步标记 `M1-S3` 与 `M1-S4` 为 `✅ 已完成`。 | D-01、D-07 |
| **SYNC-M2-06** | `模块设计说明.md` §3.2、`模块内部接口设计.md` §5.4/§5.5/§5.8 | 架构修正（真机实证） | WP5 真机实证 `Game.CityPurchaseBuilding/Unit` 与 `Game.CityPushOrder` 经 BNW NetMessage 队列跨帧生效（同帧回读滞后）。经用户确认方案 A，将 `PurchaseCityItem`（`PURCHASE_ITEM`）与 `SetCityProduction`（`SET_PRODUCTION`）统一升级为与 `PurchaseCityPlot` 对称的 `0.10s` 短延迟两段式异步结算，由 `IsSettlementBusy` + `FinalizeActionSettlement`（5 类 `settlementKind`）精准回读扣费、新生 `spawned_unit_id` 与生产队列。 | WP5 方案 A 确认 |

---

## 五、 跨会话交接日志（Session Log）

### Session 0 — 2026-11-27（M1Sub2 规划与 `/grill-me` 决策对齐会话）
* **完成工作**：
  1. 完整研读 `docs/M1/` 三份上位设计文档（含已同步的 `SYNC-01` ~ `SYNC-05`）、`docs/03_接口设计说明书.md`、已验收的 M1Sub1 全部交付文档与源码（`CAB_Config.lua`、`CAB_InfoCollector.lua`、`run_m1sub1_tests.py`）以及原型 `Civ5AgentBridgeCore.lua` 动作执行/结算参考逻辑；
  2. 核实仓库工作树洁净（`git status` 无未提交脏文件）且 M1Sub1 全部依赖已验收通过，确认 M1Sub2 当前无阻塞前序任务；
  3. 经 `/grill-me` 逐分支访谈，与用户最终拍板 7 项核心设计决策（`D-01` ~ `D-07`），并预登记 `SYNC-M2-01` ~ `SYNC-M2-05` 待回写台账；
  4. 创建 `docs/M1/M1Sub2/` 目录并编写完成 `M1Sub2工作计划.md` 与 `M1Sub2工作进度.md`（严守隔离红线，零触碰上位文档与业务源码）。
* **当前卡点 / 交接给下一会话**：
  * **等待用户审阅并确认《M1Sub2工作计划.md》**。
  * 一旦用户确认，下一会话立即启动 **WP1**：
    1. 新建 `tests/run_m1sub2_tests.py`（对接本机 Python + `lupa.lua51`，覆盖原型 + M1Sub1 + M1Sub2 Lua 文件语法检查 + 3 项负向语法自检 + `--filter` 过滤 + 统一退出码 `0/1/2`）；
    2. 新建 `tests/m1sub2/engine_stubs.lua`（独立有状态 BNW Lua 5.1 引擎桩，支持真实加载 `CAB_Config.lua` 与 `CAB_InfoCollector.lua`，提供单位移动/战斗/阵亡/揭盲/宣战/和约/购买建筑与单位/生产队列/买地块/动画忙碌帧推进/`CONTROL_ENDTURN` 模拟与全量写调用/禁令/迷雾侧信道审计）；
    3. 新建 `mod/Lua/CAB_TaskExecutor.lua` 骨架（仅 `include("CAB_Config")` 与 `include("CAB_InfoCollector")` 各一次、仅导出唯一全局 `CAB_Executor`、实现 `Initialize()` 与基础活动回合/消息队列/选区恢复内部守卫）；
    4. 新建 `tests/m1sub2/test_executor.lua` 完成 WP1 加载洁净、静态红线扫查、有状态桩自检与 `Initialize()` 用例并跑通 `python Civ5AgentBridge/tests/run_m1sub2_tests.py` 全量绿灯。

### Session 1 — 2026-11-27（WP1：有状态引擎桩底座 + `CAB_TaskExecutor` 骨架与 `Initialize`）
* **完成工作**：
  1. 新建 `tests/run_m1sub2_tests.py`：对接本机 Python + `lupa.lua51`，实现三阶段验收入口（Lua 5.1 语法编译 9 文件 + 3 项负向语法自检 + 有状态引擎桩测试 + `--filter` 过滤 + 退出码 `0/1/2`）；
  2. 新建 `tests/m1sub2/engine_stubs.lua`：完全独立于 `tests/m1sub1/*` 的有状态 BNW v1.0.3.279 Lua 5.1 引擎桩，100% 兼容真实加载 `CAB_Config.lua` + `CAB_InfoCollector.lua` + `CAB_TaskExecutor.lua`，完整支持单位移动/揭盲/近战/远程/空袭/城防炮击、外交和约与显式宣战、城市买建筑/买单位/设生产队列、买地块异步延迟翻转、`MISSION_SKIP`/`CONTROL_ENDTURN`、`tickSettlement()` 动画帧推进及红线陷阱（`CanMoveOrAttackInto` / `UI.SetInterfaceMode` / `SetScriptData`）与迷雾/写操作审计；
  3. 新建 `mod/Lua/CAB_TaskExecutor.lua` 骨架：单向依赖 `CAB_Config` 与 `CAB_InfoCollector` 各一次、导出唯一全局 `CAB_Executor`、实现 `CAB_Executor.Initialize()` 与 7 个基础 `local` 安全守卫（活动回合/消息队列门控 `validateActivePlayerWriteGate`、临时选区无痕恢复 `withTempUnitSelection`、两段式宣战护栏 `checkHostileOrWarPrecondition` / `commitDeclareWarIfNeeded` 等）；
  4. 新建 `tests/m1sub2/test_executor.lua`（`T-00` ~ `T-08` + `FW-01`），实测结果：
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py`：语法 9/9（含 3 项负向自检）、桩测试 9/9 全部通过，红线违规 0、未实现方法 0、有效写操作记录 10 次，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py --filter T-00`：1/1 通过，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：语法 8/8、桩测试 36/36 全绿，M1Sub1 零回归；
     * `git -C Civ5AgentBridge status --short`：仅含白名单文件（`docs/M1/M1Sub2/`、`mod/Lua/CAB_TaskExecutor.lua`、`tests/run_m1sub2_tests.py`、`tests/m1sub2/`），零触碰禁止清单文件。
* **当前卡点 / 交接给下一会话**：
  * WP1 全部完成标准已达成，无遗留阻塞。
  * 下一会话直接启动 **WP2**：
    1. 在 `mod/Lua/CAB_TaskExecutor.lua` 中复用 WP1 内部守卫实现 `CAB_Executor.StartUnitAction`（8 种动作：`MOVE_STEP` / `MELEE_ATTACK` / `RANGE_ATTACK` / `AIR_STRIKE` / `SETUP_FOR_RANGED` / `FORTIFY` / `HEAL` / `SKIP_TURN`，含双圆心联合 `revealedBefore` 基线与 `allowDeclareWar` 两段式显式宣战）与 `CAB_Executor.StartCityRangeAttack`；
    2. 在 `tests/m1sub2/test_executor.lua` 中扩充 WP2 全量用例，覆盖红线 `E-01` ~ `E-06`（活动回合门控、校验失败零写副作用与选区恢复、远程/空袭/城防对普通迷雾与黑雾 `queriesOnForbiddenFog == 0`、默认防误宣战 + 显式宣战 + 和约拦截、相邻黑雾探路、`CanMoveThrough`+1UPT、纯原生空军打击）。

### Session 2 — 2026-11-27（WP2：单位战术动作下发 `StartUnitAction` 与城防远程炮击 `StartCityRangeAttack`）
* **完成工作**：
  1. 在 `mod/Lua/CAB_TaskExecutor.lua` 中实现 `CAB_Executor.StartUnitAction`（完整覆盖 8 种动作：`MOVE_STEP` / `MELEE_ATTACK` / `RANGE_ATTACK` / `AIR_STRIKE` / `SETUP_FOR_RANGED` / `FORTIFY` / `HEAL` / `SKIP_TURN`）与 `CAB_Executor.StartCityRangeAttack`（参照官方 `WorldView.lua:519` 调用序列）；
  2. 配套实现内部无缓存辅助函数 `getCityAttackRange`、`getMaxCityHp`、`captureDualCenterRevealedSet`（`D-04` 双圆心联合揭盲基线）与 `captureTargetCitySnapshot`（`D-04` 攻城战前城市快照）；
  3. 全面落实红线 `E-01`~`E-06` 与决策 `D-02`/`D-03`：对可见中立目标在 `allowDeclareWar == true` 时先用 `bNeedWar = false` 预检 `CanRangeStrikeAt` 确保校验失败零宣战零写入（`E-02`），对普通迷雾/黑雾/隐形目标直接拒绝保证 `queriesOnForbiddenFog == 0`（`E-03`），纯原生 `MISSION_MOVE_TO` 空袭零 `AirRaidCore`（`E-06`）；
  4. 在 `tests/m1sub2/test_executor.lua` 中扩充 9 条 WP2 专项验收用例（`T-09` ~ `T-17`），并更新 `T-00` 导出检查；实测结果：
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py`：语法 9/9（含 3 项负向自检）、桩测试 18/18 全部通过，红线违规 0、未实现方法 0、有效写操作记录 27 次，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：语法 8/8、桩测试 36/36 全绿，M1Sub1 零回归；
     * `git -C Civ5AgentBridge status --short`：仅含白名单文件，零触碰禁止清单文件。
* **当前卡点 / 交接给下一会话**：
  * WP2 全部完成标准已达成，无遗留阻塞。
  * 下一会话直接启动 **WP3（两段式异步结算与精准增量观测）**：
    1. 在 `mod/Lua/CAB_TaskExecutor.lua` 中实现 `CAB_Executor.IsSettlementBusy(baselineContext)` 与 `CAB_Executor.FinalizeActionSettlement(baselineContext, settleWaitMs)`，完整覆盖 `UNIT_ACTION`、`CITY_ATTACK` 与 `BUY_PLOT` 三类 `settlementKind`；
    2. 严格按 `D-04` 实现：基于双圆心 `revealedBefore` 与 `revealScanRadius` 精准统计 `newly_revealed_tiles_count`（消除 1 格移动假阳性）、统一附带 `timed_out`、准确生成 `newly_spotted_enemies`（过滤隐形）、`target_enemy_after`（残血/击杀）、`unit_died`/`unit_after`、`target_city_after`（残血/占领/毁城）、`CITY_ATTACK` 的 `city_id`/`city_after`（复用 `SerializeCitySummary`）以及 `BUY_PLOT` 的实时归属判定 `purchased = (newOwner == activePlayerID)`；
    3. 在 `tests/m1sub2/test_executor.lua` 中扩充 WP3 全量结算、阵亡、攻城、超时与买地结算用例。

### Session 3 — 2026-11-27（WP3：两段式异步结算与精准增量观测 `IsSettlementBusy` / `FinalizeActionSettlement`）
* **完成工作**：
  1. 在 `mod/Lua/CAB_TaskExecutor.lua` 中新增第 4 节，实现公开接口 `CAB_Executor.IsSettlementBusy(baselineContext)`（E8）与 `CAB_Executor.FinalizeActionSettlement(baselineContext, settleWaitMs)`（E9），完整覆盖 `UNIT_ACTION`、`CITY_ATTACK`、`BUY_PLOT` 三类 `settlementKind`；
  2. 配套实现 9 个只读 `local` 辅助函数（`safeCallBool`、`normalizeWaitMs`、`resolvePlotFromCoords`、`resolveBuyPlotCoords`、`countNewlyRevealedTiles`、`buildTargetEnemyAfter`、`buildTargetCityAfter`、`collectDeltaObservation`、`attachWarDeclaredFields`），全程零写入、零选区改动、零迷雾侧信道：
     * 复用 WP2 双圆心联合 `revealedBefore` 与 `CAB_Collector.CaptureRevealedPlotsSet`，彻底消除移动 1 格圆周前沿已探索格的揭盲假阳性；
     * 复用 `CAB_Collector.GetVisibilitySummary` / `SerializeUnitSummary` / `SerializeCitySummary` 保持与采集层 100% 同源，过滤 `IsInvisible` 隐形敌军；
     * 严格落实 `D-03`（仅在触发显式宣战时附带 `war_declared = true`、`war_declared_target_player_id`、`war_declared_target_team_id`）与 `D-04`（统一附带 `timed_out`、攻城三态 `target_city_after`、城防炮击 `city_id`/`city_after`、`BUY_PLOT` 按实时归属 `newOwner == activePlayerID` 判定 `purchased`）；
     * 非法/空 `baselineContext` 与未知 `settlementKind` 均零异常安全降级返回结构化错返 DTO；
  3. 在 `tests/m1sub2/test_executor.lua` 中更新 `T-00` 导出检查，并新增 7 条 WP3 专项验收用例（`T-18` ~ `T-24`），实测结果：
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py`：语法 9/9（含 3 项负向自检）、桩测试 25/25 全部通过，红线违规 0、未实现方法 0、有效写操作记录 44 次，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py --filter WP3`：7/7 全部通过，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：语法 8/8、桩测试 36/36 全绿，M1Sub1 零回归；
     * `git -C Civ5AgentBridge status --short`：仅含白名单文件（`docs/M1/M1Sub2/M1Sub2工作进度.md`、`mod/Lua/CAB_TaskExecutor.lua`、`tests/m1sub2/test_executor.lua`），零触碰禁止清单文件。
* **当前卡点 / 交接给下一会话**：
  * WP3 全部完成标准已达成，无遗留阻塞。
  * 下一会话直接启动 **WP4（城市内政执行与安全下一回合）**：
    1. 在 `mod/Lua/CAB_TaskExecutor.lua` 中实现 `CAB_Executor.PurchaseCityItem`（建筑/单位 × 金币/信仰双通道、Type/ID 双入参、双层 `IsCanPurchase` 错误细分、新生 `spawned_unit_id` 识别与 `city_summary_after`）、`CAB_Executor.SetCityProduction`（4 类订单与 `clearQueue`）、`CAB_Executor.PurchaseCityPlot`（实时读取 `BUY_PLOTS_DISABLED`、`CanBuyPlotAt` 余额不足 vs 越界细分、联动 WP3 `BUY_PLOT` 短结算，复用 `targetX/targetY/goldBefore/expectedCost` 基线契约）及 `CAB_Executor.ExecuteEndTurn`（`D-05` 守卫式自动跳过非晋升非叠栈待命单位、硬阻塞零浪费拦截、无阻塞调 `CONTROL_ENDTURN` 立返）；
    2. 将 `T-00` 升级为精确校验 `CAB_Executor` 全部 9 项导出，扩充 WP4 内政、安全下一回合、IGE 动态变阵与非法入参防御用例，并复跑 M1Sub2 + M1Sub1 双套件确认全绿。

### Session 4 — 2026-11-27（WP4：城市内政执行与安全下一回合 `PurchaseCityItem` / `SetCityProduction` / `PurchaseCityPlot` / `ExecuteEndTurn`）
* **完成工作**：
  1. 在 `mod/Lua/CAB_TaskExecutor.lua` 中新增第 5 节，完整实现最后 4 个公开接口，至此 `CAB_Executor` 全部 **9 个导出函数**开发完毕：
     * **E4 `PurchaseCityItem`**：支持建筑/单位 × 金币/信仰双通道、Type 字符串/整数 ID 双入参、参照 `ProductionPopup.lua:136-161` 双层 `IsCanPurchase` 精准区分前置/已拥有 vs 余额不足（附报价与余额）/叠栈冲突、执行 `Game.CityPurchaseBuilding` / `CityPurchaseUnit` + `Events.SpecificCityInfoDirty`、通过 `pPlayer:Units()` 前后差分精准识别新生 `spawned_unit_id` 并回读 `CAB_Collector.SerializeCitySummary(pCity)`；
     * **E5 `SetCityProduction`**：拦截傀儡/抵抗/焚城城市，覆盖 `BUILDING` / `UNIT` / `PROJECT` / `PROCESS` 4 类订单与 `CanConstruct` / `CanTrain` / `CanCreate` / `CanMaintain` 校验，按 `ProductionPopup.lua:133` 调用 `Game.CityPushOrder(pCity, eOrder, itemId, false, clearQueue ~= false, true)` + `SpecificCityInfoDirty` 并回读队列与回合状态；
     * **E6 `PurchaseCityPlot`**：实时读取 `GameDefines.BUY_PLOTS_DISABLED == 0`（E-06 零缓存），拦截傀儡/抵抗/焚城城市，按 `CityView.lua:2003, 2143` 双层 `CanBuyPlotAt` 区分余额不足（附 `GetBuyPlotCost`）与非合法买地范围，调用 `Network.SendCityBuyPlot`（城市界面打开时安全调 `UI.UpdateCityScreen()`）并无缝返回 `settlementKind = "BUY_PLOT"` 基线联动 WP3 短结算；
     * **E7 `ExecuteEndTurn`**：严格落实 `D-05` 诊断优先与守卫式自动跳过——先调 `CAB_Collector.GetEndTurnStatus`，仅当 `autoSkipReadyUnits == true` 且当前为待命单位类阻塞（`ENDTURN_BLOCKING_UNITS` / `ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS`）才跳过存活非自动化、非 `IsPromotionReady()`、非同格非空军同类非法叠栈（`isUnitIllegallyStacked`）的待命单位并经 `pcall` 无条件恢复原 UI 选区后再复查；硬阻塞零浪费拦截；无阻塞调 `Game.DoControl(CONTROL_ENDTURN)` 立即返回 `WAITING_NEXT_TURN`；
  2. 在 `tests/m1sub2/test_executor.lua` 中将 `T-00` 升级为精确校验 `CAB_Executor` 全部 9 项导出（数量与名称一一对应、无多余键），并新增 8 条 WP4 专项验收用例（`T-25` ~ `T-32`），覆盖建筑/单位双通道购买、新生 ID 差分、4 类生产与 `clearQueue`、买地与 WP3 短结算闭环、守卫式自动跳过（含硬阻塞保护、待晋升/非法叠栈保护、军民/空军合法叠栈放行、选区恢复）、全量写门控/非法入参防御及 IGE 动态注金/幽灵单位联调；
  3. 全量实测结果：
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py --filter WP4`：语法 9/9 + 负向自检 3/3，桩测试 8/8（`T-25` ~ `T-32`），红线违规 0、未实现方法 0、有效写操作记录 21 次，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub2_tests.py`：语法 9/9 + 负向自检 3/3，桩测试 33/33（`T-00` ~ `T-32`），红线违规 0、未实现方法 0、有效写操作记录 65 次，退出码 `0`；
     * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：语法 8/8 + 负向自检 3/3，桩测试 36/36，M1Sub1 零回归，退出码 `0`；
     * `git -C Civ5AgentBridge status --short`：仅含白名单文件（`docs/M1/M1Sub2/M1Sub2工作进度.md`、`mod/Lua/CAB_TaskExecutor.lua`、`tests/m1sub2/test_executor.lua`），零触碰任何禁止清单文件。
* **当前卡点 / 交接给下一会话**：
  * WP4 全部完成标准已达成，`CAB_TaskExecutor.lua` 全部 9 项导出接口离线自动化验收 100% 绿灯，无遗留阻塞。
  * 下一会话直接启动 **WP5（双层总验收、原生 BNW/IGE 临时实机冒烟回滚与工作总结报告）**：
    1. 确认 M1Sub2（33/33）与 M1Sub1（36/36）双套件全绿；
    2. 配合用户在本机《文明5：BNW v1.0.3.279》（原生 + IGE）临时挂载并完成 `CAB_TaskExecutor` 实机冒烟，核验 `Logs/Lua.log` 零语法/运行时错误；
    3. **100% 回滚**临时挂载改动并同步还原 `MODS/Civ5AgentBridge/`，经 `git status` / `git diff` 确认仅留白名单文件；
    4. 编写交付《`docs/M1/M1Sub2/M1Sub2工作总结报告.md`》（汇总实测实证与 `SYNC-M2-01` ~ `SYNC-M2-05` 上位文档回写建议）并更新本进度文档完成 M1Sub2 结项。

### Session 5 — 2026-11-27（WP5：双层总验收、BNW+IGE 真机实证与方案 A 异步升级、100% 回滚及结项报告）
* **完成工作**：
  1. 复核离线双套件基线全绿（`run_m1sub2_tests.py` 33/33、`run_m1sub1_tests.py` 36/36），编写并临时挂载 Lua 5.1 步进式异步冒烟驱动脚本 `mod/Lua/CAB_M1Sub2Smoke.lua`，通过 `deploy_mod.ps1 -ForceCopy -ClearCache` 部署进本机《文明5：BNW v1.0.3.279》+ `Ingame Editor (v 39)`；
  2. 配合用户完成首轮与次轮真机冒烟：
     * 首轮实证 `Initialize`、E-02 负向守卫、`ExecuteEndTurn` 阻塞诊断/硬阻塞守卫与真实推进 `Turn 0 → Turn 1`、`StartCityRangeAttack`（`359ms`，蛮族 `100→81 HP`）、`StartUnitAction`（`MOVE_STEP` `359ms` + `FORTIFY` `360ms`）；
     * 次轮跨帧探针实证全部操作均在当前 Turn 0 内 1.38s 完成，同时暴露出 **BNW 真机 C++ NetMessage 跨帧时序差异**：`Game.CityPushOrder`、`Game.CityPurchaseBuilding`、`Game.CityPurchaseUnit` 均在下一帧（~16–100ms）落地，导致原“同帧同步回读”设计返回 `cost_paid = 0` / `spawned_unit_id = nil` / `order_queue_length = 0` 旧值；
  3. 经用户确认 **方案 A**，立即完成架构级根治：
     * 在 `mod/Lua/CAB_TaskExecutor.lua` 中将 `PurchaseCityItem`（`settlementKind = "PURCHASE_ITEM"`）与 `SetCityProduction`（`settlementKind = "SET_PRODUCTION"`）升级为与 `PurchaseCityPlot` 完全对称的 `0.10s` 短延迟两段式异步结算，扩展 `IsSettlementBusy` / `FinalizeActionSettlement` 覆盖全部 5 类 `settlementKind`；
     * 在 `tests/m1sub2/engine_stubs.lua` 中新增 `cityActionDelayTicks` 与 `GetProductionBuilding/Unit/Project/Process` 跨帧模拟，在 `tests/m1sub2/test_executor.lua` 中升级 `T-25`/`T-26`/`T-27`/`T-32` 覆盖异步结算与超时兜底，离线全绿；
     * 第三轮真机复测 **10P/2S/0F** 精准回读：`SetCityProduction`（`109ms` `queue_len=1` + `125ms` `queue_len=2`）、`PurchaseCityItem` 建筑（`110ms` `cost_paid=200`）与单位（`109ms` `cost_paid=220, spawned_unit_id=24576`）、`PurchaseCityPlot`（`109ms` `cost_paid=30, new_owner_id=0`）、`StartCityRangeAttack`（`360ms` 蛮族 `100→73 HP`）、`StartUnitAction(MELEE_ATTACK)`（`359ms` 我方 `100→79 HP`、蛮族 `73→38 HP`），`Logs/Lua.log` 累计 1,948 行零报错；
  4. 用户退出游戏后执行 **100% 临时挂载回滚**：还原 `mod/Civ5AgentBridge.modinfo` 与 `mod/Lua/Civ5AgentBridgeUI.lua`，删除 `mod/Lua/CAB_M1Sub2Smoke.lua`，执行 `deploy_mod.ps1 -ForceCopy -ClearCache` 同步清理 `MODS/Civ5AgentBridge/` 与 5 个缓存库；回滚后复跑 `run_m1sub2_tests.py`（33/33）与 `run_m1sub1_tests.py`（36/36）全部通过；
  5. 编写交付《`docs/M1/M1Sub2/M1Sub2工作总结报告.md`》（含 `A-01`~`A-10` 逐项对账与 `SYNC-M2-01`~`SYNC-M2-06` 上位文档回写建议），并更新本文档闭环 M1Sub2 全部进度。
* **最终隔离核验**：
  * `git -C Civ5AgentBridge status --short` 仅含白名单文件（`mod/Lua/CAB_TaskExecutor.lua`、`tests/m1sub2/engine_stubs.lua`、`tests/m1sub2/test_executor.lua` 及 `docs/M1/M1Sub2/` 三份文档），`docs/M1/` 上位三文档、M1Sub1 已验收交付物与其他所有 Mod 壳层文件零持久化改动。
