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
| **总体阶段** | 🟢 **WP1 已完成，准备进入 WP2（军事动作与城防炮击下发）** |
| **当前待执行工作包** | **WP2**（单位战术动作下发 `StartUnitAction` 8 种 + 城防远程炮击 `StartCityRangeAttack`） |
| **最近一次测试结果** | ✅ `run_m1sub2_tests.py` 全绿（语法 9/9 + 负向自检 3/3，桩测试 9/9，红线违规 0，未实现方法 0）；`run_m1sub1_tests.py` 36/36 零回归 |

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
| **WP2** | 军事动作下发（`StartUnitAction` 8 种）与城防远程炮击（`StartCityRangeAttack`） | `mod/Lua/CAB_TaskExecutor.lua`<br>`tests/m1sub2/test_executor.lua` | `[ ] 待执行` | — | — |
| **WP3** | 两段式异步结算与精准增量观测（`IsSettlementBusy` + `FinalizeActionSettlement`） | `mod/Lua/CAB_TaskExecutor.lua`<br>`tests/m1sub2/test_executor.lua` | `[ ] 待执行` | — | — |
| **WP4** | 城市内政（买建筑/单位/地块、设生产）与安全下一回合（`ExecuteEndTurn`） | `mod/Lua/CAB_TaskExecutor.lua`<br>`tests/m1sub2/test_executor.lua` | `[ ] 待执行` | — | — |
| **WP5** | 全量离线验收 + 原生 BNW/IGE 临时真机冒烟回滚 + 工作总结报告 | 临时挂载验证并回滚<br>`docs/M1/M1Sub2/M1Sub2工作总结报告.md` | `[ ] 待执行` | — | — |

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
