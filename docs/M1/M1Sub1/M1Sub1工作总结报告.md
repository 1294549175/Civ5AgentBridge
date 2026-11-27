# M1Sub1（游戏内信息收集子模块 `CAB_InfoCollector`）工作总结报告

> [!IMPORTANT]
> 本报告为 **模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`）** 下属 **子模块 1：游戏内信息收集子模块（`CAB_InfoCollector`）** 的正式结项与验收呈报文档，供模块 1（M1）上级评审会话开展子模块验收及上位设计文档同步回写使用。
>
> **隔离红线执行声明**：在 M1Sub1 规划、编码、测试与真机冒烟全过程中，严格执行决策 `D-02` 与验收项 `A-10`，**未对 `docs/M1/` 下三份上位设计文档（`模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）及顶层《01》《02》《03》文档做任何修改**；WP5 真机冒烟期间的临时挂载改动已 100% 回滚。全部接口增补、细化与契约偏离建议均集中汇总于本报告第六章（`SYNC-01` ~ `SYNC-05`）。

---

## 一、 子模块建设总览与验收结论

### 1.1 子模块职责定位与建设范围

`CAB_InfoCollector` 运行于《文明5：美丽新世界（BNW v1.0.3.279）》客户端的 Lua 5.1 UI 沙箱内，定位为模块 1 的**纯只读游戏态势传感器（Zero-Mutation Read-Only Sensor）**。其核心职责是将引擎 C++ 导出的 `Player`、`Team`、`Unit`、`City`、`Plot` 及 `GameInfo` 实时状态安全转换为可 JSON 序列化的结构化纯 Lua 表（DTO），在严守战争迷雾与防侧信道边界的前提下，向上支撑调度控制子模块（`CAB_Dispatcher`）的全局/局部查询响应，并向任务执行子模块（`CAB_TaskExecutor`）输出可复用的原子序列化与视野扫描能力。

对照《M1Sub1工作计划.md》，本子模块分设的 **规划阶段（`Plan`）+ 5 个串行工作包（`WP1` ~ `WP5`）** 已全部按期闭环：

| 阶段 / 工作包 | 核心交付目标 | 完成状态 | 完成日期 |
| :---: | :--- | :---: | :---: |
| **Plan** | 前置依赖核查、8 项关键设计决策（`D-01` ~ `D-08`）对齐、工作计划与进度看板编制 | ✅ 已完成 | 2026-11-26 |
| **WP1** | 公共静态只读配置表 `CAB_Config.lua`（12 键）与全新 `lupa.lua51` 引擎桩测试底座搭建 | ✅ 已完成 | 2026-11-26 |
| **WP2** | `CAB_InfoCollector.lua` 骨架、7 个纯只读复用辅助函数（`H1`~`H7`）与 4 个基础域查询接口（`F1`~`F4`） | ✅ 已完成 | 2026-11-27 |
| **WP3** | 全局态势聚合接口 `BuildTurnOverview`（`F5`）与单位局部战术网格/候选动作接口 `BuildUnitContextAndCandidates`（`F6`） | ✅ 已完成 | 2026-11-27 |
| **WP4** | 城市深度面板、城防远程炮击目标与建筑/单位/地块双层购买报价单接口 `GetCityDetail`（`F7`） | ✅ 已完成 | 2026-11-27 |
| **WP5** | 全量离线自动化验收、《文明5：BNW》真机多轮冒烟实证、临时挂载 100% 回滚及本验收报告编制 | ✅ 已完成 | 2026-11-27 |

### 1.2 总体自评结论

* **功能与契约完备度**：`CAB_Config` 全部 **12 个配置键**、`CAB_Collector` 全部 **7 个主查询接口（`F1` ~ `F7`）** 与 **7 个复用辅助函数（`H1` ~ `H7`）** 共 14 项导出 100% 实现，完全向下兼容《03_接口设计说明书.md》§2.1 / §2.2 既有字段契约。
* **离线自动化验证**：`python Civ5AgentBridge/tests/run_m1sub1_tests.py` 退出码 `0`——Lua 5.1 语法编译 **8/8 通过**（含 3 项负向语法拦截自检），引擎桩测试 **`T-00` ~ `T-35` 共 36/36 通过**，只读守卫违规 **0 次**，未实现桩方法调用 **0 次**。
* **真机实证验证**：在本机《文明5：BNW v1.0.3.279》（内置 `Lua 5.1.4`）真实对局中完成建城前/建城后连续 **9 轮冒烟检验（累计 `90/90 PASS`、`0 FAIL`）**，`Logs/Lua.log` 零语法/运行时错误，所有返回对象均通过真实 `CAB_JsonEncode` 编码并落盘 `ModUserData/Civ5AgentBridge-1.db`。
* **验收建议**：**`A-01` ~ `A-10` 全部 10 项验收指标均已达成，申请 M1 上级评审予以正式验收通过。**

---

## 二、 交付物清单与文件隔离边界核验

### 2.1 永久交付与修改文件清单（严格落于白名单内）

| 文件路径（相对 `Civ5AgentBridge/`） | 操作类型 | 规模（行数） | 核心交付内容与职责 |
| :--- | :---: | :---: | :--- |
| `mod/Lua/CAB_Config.lua` | 全新重写 | 55 行 | 模块 1 全局静态只读常量表 `CAB_Config`（原设计 11 键 + 决策 `D-06` 新增 `MAX_SCAN_RADIUS = 8`），零依赖、零函数、零引擎调用 |
| `mod/Lua/CAB_InfoCollector.lua` | 新建 | 1,639 行 | 子模块 1 正式实现，仅 `include("CAB_Config")` 一次，仅导出唯一全局表 `CAB_Collector`（7 主接口 + 7 复用只读辅助函数），全函数附中文 What/Why/IO 注释 |
| `tests/run_m1sub1_tests.py` | 全新重写 | 267 行 | 基于 `Python 3.14` + `lupa.lua51` 的离线自动化验收入口（Lua 5.1 字节码编译检查 + 3 项负向自检 + 桩测试运行器 + `--filter` 单测过滤） |
| `tests/m1sub1/engine_stubs.lua` | 全新重写 | 2,324 行 | 纯净版 BNW Lua 5.1 引擎模拟桩：含只读写入守卫、原版 DLL `CanMoveOrAttackInto` 禁令陷阱、迷雾侧信道调用审计（`queriesOnForbiddenFog`）、深层实体 `_s` 世界快照与 IGE 动态变阵助手 |
| `tests/m1sub1/test_collector.lua` | 全新重写 | 2,798 行 | `T-00` ~ `T-35` 共 36 条结构化验收用例，全覆盖 14 项导出契约、迷雾 6 红线、1UPT 停靠、空军超半径扫描、UI 选区异常恢复、双层购买报价单及 IGE 实时无缓存特性 |
| `docs/M1/M1Sub1/M1Sub1工作计划.md` | 新建 | 271 行 | M1Sub1 架构约束、决策定稿（`D-01`~`D-08`）、接口契约、WP1~WP5 拆分与验收矩阵 |
| `docs/M1/M1Sub1/M1Sub1工作进度.md` | 新建并闭环 | ~165 行 | 多会话推进看板、待回写偏离台账与 `Session 0` ~ `Session 5` 完整交接日志 |
| `docs/M1/M1Sub1/M1Sub1工作总结报告.md` | 新建 | 本文档 | M1Sub1 结项验收报告与上位文档回写建议书 |

### 2.2 临时挂载回滚与红线文件零污染核验（`D-02` / `A-10`）

1. **WP5 临时冒烟文件处置**：真机冒烟采集完成后，已执行 `git checkout -- mod/Civ5AgentBridge.modinfo mod/Lua/Civ5AgentBridgeUI.lua`、删除临时脚本 `mod/Lua/CAB_M1Sub1Smoke.lua`，并通过 `scripts/deploy_mod.ps1 -ForceCopy` 镜像同步清理 `MODS/Civ5AgentBridge/` 中的临时文件。
2. **工作区最终 `git status --short` 核验**：
   * 仅存在白名单内的代码/测试文件（`mod/Lua/CAB_Config.lua`、`mod/Lua/CAB_InfoCollector.lua`、`tests/run_m1sub1_tests.py`、`tests/m1sub1/engine_stubs.lua`、`tests/m1sub1/test_collector.lua`）与 `docs/M1/M1Sub1/` 下三份子模块文档；
   * **严禁修改清单零触碰**：`docs/M1/模块设计说明.md`、`docs/M1/模块内部接口设计.md`、`docs/M1/模块设计进度.md`、`docs/01~03_*.md`、`mod/Civ5AgentBridge.modinfo`、`mod/Lua/Civ5AgentBridgeCore.lua`、`Civ5AgentBridgeJson.lua`、`Civ5AgentBridgeLoader.lua/.xml`、`Civ5AgentBridgeUI.lua/.xml`、`scripts/deploy_mod.ps1` **均为零持久化修改**。

---

## 三、 接口实现明细与关键工程机制说明

### 3.1 `CAB_Config.lua` 配置表实现（12 键）

严格按纯静态字面量表实现，包含《模块设计说明.md》§4.1 既有 11 键（`DB_NAME = "Civ5AgentBridge"`、`DB_VERSION = 1`、`CHUNK_SIZE_BYTES = 3000`、`POLL_INTERVAL_SEC = 0.20`、`HEARTBEAT_INTERVAL_SEC = 2.00`、`DEFAULT_UNIT_SETTLE_SEC = 0.35`、`PLOT_BUY_SETTLE_SEC = 0.10`、`MAX_SETTLE_TIMEOUT_SEC = 1.50`、`DEFAULT_SCAN_RADIUS = 3`、`DELTA_REVEAL_SCAN_RADIUS = 5`、`ENABLE_DEBUG_LOG = true`），以及按决策 `D-06` 新增的第 12 键 **`MAX_SCAN_RADIUS = 8`**（硬性钳制外部传入的扫描半径上限，防止超大半径遍历导致主线程卡顿）。

### 3.2 `CAB_Collector` 7 个主查询接口实现矩阵（`F1` ~ `F7`）

| 编号 | 接口签名 | 输出 DTO 与兼容性 | 关键实现口径与官方引擎脚本依据 |
| :---: | :--- | :--- | :--- |
| **F1** | `GetEmpireEconomy(activePlayerID)` | `EconomyDTO`（带 `__is_object = true`） | 实时读取金币、回合金、科研、文化、信仰（每回合与累计）、净快乐度、黄金时代态；遍历 `GameInfo.Resources()` 经 `Game.GetResourceUsageType` 严格分离战略/奢侈资源，过滤加成资源与可用量 `<= 0` 条目。 |
| **F2** | `GetVisibilitySummary(activePlayerID)` | 双返回 `(VisibilitySummaryDTO, visibleEnemyMap)` | 遍历 `0 .. MAX_PLAYERS-1` 非己方存活玩家（兼容存活/死玩家/`nil` 三态槽位）；敌军须同时满足 `IsVisible(activeTeam, false)` 与 `not IsInvisible(activeTeam, false)`；非己方城市须 `IsRevealed` 并标注 `in_fog = not IsVisible`；采用 `"<ownerID>:<id>"` 复合键杜绝跨文明碰撞。 |
| **F3** | `CaptureRevealedPlotsSet(activePlayerID, centerX, centerY, radius)` | 纯坐标集合 `{ ["x:y"] = true }`（不带 `__is_object`） | 缺省半径取 `DELTA_REVEAL_SCAN_RADIUS`（5），钳制至 `[0, MAX_SCAN_RADIUS]`；`Map.GetPlotXY` + `Map.PlotDistance <= r` 提取 `IsRevealed == true` 坐标集；非法入参或负半径安全返回 `{}`。 |
| **F4** | `GetEndTurnStatus(activePlayerID)` | `EndTurnStatusDTO` | 对齐官方 `ActionInfoPanel.lua`：覆盖全部 **24 种 `EndTurnBlockingTypes`** 枚举映射（无阻塞统一为 `"NO_BLOCKING"`）；待命/叠栈取 `GetFirstReadyUnit()`，待晋升查 `IsPromotionReady()`，缺生产排查非傀儡/非抵抗/非焚城且 `GetOrderQueueLength() == 0` 的城市；经 `GetEndTurnBlockingNotificationIndex()` 精确匹配阻塞通知摘要；联动 `UI.CanEndTurn()` 综合判定 `can_end_turn_now`。 |
| **F5** | `BuildTurnOverview(activePlayerID)` | `TurnOverviewDTO`（100% 兼容《03》§2.1 + 扩展字段） | 纯聚合调用 `GetEmpireEconomy`、`GetVisibilitySummary`、`GetEndTurnStatus`、`SerializeUnitSummary` 与 `SerializeCitySummary`，零重复扫描代码；完整包含扩展经济收益、城市分项产出、`can_range_strike` 与 `end_turn_status`。 |
| **F6** | `BuildUnitContextAndCandidates(activePlayerID, unitID, radius)` | `UnitTacticalContextDTO`（100% 对齐《03》§2.2） | `surrounding_tiles` 严格按钳制后的 `r`（`[0, 8]`）导出；内部 `scanRadius` 自动扩展覆盖空军真实射程（上限 `MAX_AIR_SCAN_RADIUS = 20`）；枚举 `MOVE_STEP`（含相邻黑雾探路与 `CanMoveThrough` + 1UPT）、`MELEE_ATTACK`（校验陆海兵种域、不可通行格与敌城真实血量）、`RANGE_ATTACK` / `AIR_STRIKE`（严禁探测普通迷雾格）、以及经临时选区探测的 `SETUP_FOR_RANGED` / `FORTIFY` / `HEAL` / `SKIP_TURN`。 |
| **F7** | `GetCityDetail(activePlayerID, cityID, includePurchasable)` | `CityDetailDTO` | 对齐官方 `CityView.lua` / `ProductionPopup.lua` / `WorldView.lua`：`combat_str = math.floor(GetStrengthValue() / 100)`；造移民/停滞/饥荒时 `turns_to_growth = -1`；过滤无效/阵亡驻军；仅导出 `GetNumRealBuilding > 0` 真实建筑；城防炮击仅在 `CanRangeStrikeNow()` 时对实时可见交战敌军/蛮族调用 `CanRangeStrikeAt(px, py, true, true)`；双层 `IsCanPurchase(false, false, ...)` / `(true, true, ...)` 生成建筑与单位金币/信仰双通道报价单（单位信仰价传参 `(id, true)`）；买地检查 `BUY_PLOTS_DISABLED == 0` 及非傀儡/非抵抗/非焚城，地块资源经 `GetResourceType(activeTeam)` 过滤科技可见性。 |

### 3.3 公开纯只读复用辅助函数清单（`H1` ~ `H7`，决策 `D-03`）

为避免后续子模块 2（`CAB_TaskExecutor`）重复编写实体序列化与移动/动作合法性校验逻辑，`CAB_Collector` 同步公开以下 7 个无副作用纯只读辅助函数：

1. `CAB_Collector.SerializeUnitSummary(pUnit)`：`Unit` $\rightarrow$ `UnitSummaryDTO`，结合 `MovesLeft() > 0` 与 `IsReadyToMove() == true` 精准判定 `can_act`，移动力除以 `MOVE_DENOMINATOR` 保留两位小数截断（含 `1e-6` 浮点误差补偿）。
2. `CAB_Collector.SerializeEnemyUnit(pEnemyUnit)`：敌方/蛮族存活 `Unit` $\rightarrow$ `EnemyUnitDTO`（含复合 `enemy_id`）。
3. `CAB_Collector.SerializeCitySummary(pCity)`：己方 `City` $\rightarrow$ `CitySummaryDTO`（含 7 项分项 `yields` 与 `can_range_strike`）。
4. `CAB_Collector.InspectPlotUnits(pPlot, activePlayerID)`：扫描可见格存活单位返回 `(friendlyId, enemyDto)`，军民叠栈优先保留主战单位（`IsCombatUnit()`），并强制过滤 `IsInvisible(activeTeam, false)` 隐形敌军。
5. `CAB_Collector.CanUnitMoveThrough(pUnit, pPlot)`：`pcall` 安全包裹 `pUnit:CanMoveThrough(pPlot)`，彻底隔离原版 DLL `CanMoveOrAttackInto` 恒假缺陷。
6. `CAB_Collector.HasSameClassFriendlyUnit(pPlot, activePlayerID, isSelfCombat)`：判定目标格是否存在同类别（同战斗或同民用）己方存活单位，支撑 1UPT 停靠判定。
7. `CAB_Collector.FindGameActionIndex(actionTypeStr)`：对齐 `UnitPanel.lua:202-206`，双重校验 `Game.CanHandleAction(iAction, 0, 1)` 与 `Game.CanHandleAction(iAction)` 返回合法动作索引。

### 3.4 关键安全红线与兼容性工程保障

* **战争迷雾与防侧信道 6 条红线（`F-01` ~ `F-06`）全闭环**：
  * `F-01` / `F-02`：全图敌军扫描与局部网格均强制校验 `IsVisible(activeTeam, false) == true` 且 `IsInvisible(activeTeam, false) ~= true`（未反隐潜艇等隐形单位绝对屏蔽）；
  * `F-03`：**杜绝远程探测侧信道**——在 `BuildUnitContextAndCandidates` 与 `GetCityDetail` 中，严禁对普通迷雾格或黑雾格调用 `CanRangeStrikeAt`（防止通过引擎返回布尔值反推迷雾下隐匿敌军坐标），仅允许对实时可见格或已探索交战敌城格调用；
  * `F-04` / `F-05`：`REVEALED_FOG` 迷雾格严格省略动态 `improvement`、`friendly_unit_id`、`enemy_unit`（迷雾敌城显式标 `in_fog = true`）；未探索黑雾格零地形/实体信息导出，仅对相邻 1 格且有移动力的非空军单位生成无预览探路 `MOVE_STEP`；
  * `F-06`：可购地块资源统一调用 `pPlot:GetResourceType(activeTeam)`，确保未解锁对应科技前不提前泄露铁/马/煤/铝/铀等战略资源。
* **UI 选区探测无痕恢复（`A-03`）**：`BuildUnitContextAndCandidates` 枚举原地动作时，仅当目标单位尚未被选中才临时调用 `UI.SelectUnit(pUnit)`，全过程置于 `pcall` 保护内，退出前无条件恢复原选区（原选中单位仍存活则复选，原无选中则调 `UI.ClearSelectionList()`），且绝不触碰 `UI.SetInterfaceMode`。
* **原生 BNW 与 IGE 实时动态兼容（`D-05`）**：模块内部**零跨调用可变缓存**（连 `MOVE_DENOMINATOR`、`CITY_ATTACK_RANGE`、`BUY_PLOTS_DISABLED` 等 `GameDefines` 均按次实时读取），对 IGE 回合中刷兵、删兵、改金币/信仰、建城/改建筑、开闭迷雾均即时生效；完全不引入 `AirRaidLegacyUnits` 外部 Mod 依赖。

---

## 四、 双层验收测试执行结果

### 4.1 第一层：离线 Lua 5.1 语法检查与引擎桩测试（`run_m1sub1_tests.py`）

执行命令：`python Civ5AgentBridge/tests/run_m1sub1_tests.py`（运行环境：`Python 3.14.6` + `lupa.lua51` 标准 Lua 5.1 运行时）

* **阶段 1：Lua 5.1 语法编译检查**
  * 目标文件编译：**8 通过 / 0 失败 / 0 待创建**（含原型 4 文件 + `CAB_Config.lua` + `CAB_InfoCollector.lua` + `engine_stubs.lua` + `test_collector.lua`）；
  * 编译器负向自检：**3/3 通过**（普通语法错误、Lua 5.2 `goto` 语句、Lua 5.3 `//` 整除运算符均被准确拒绝）。
* **阶段 2：纯净版 BNW 引擎桩测试（共 36 条用例）**
  * 执行结果：**36 通过 / 0 失败 / 0 跳过**，退出码 **`0`**；
  * 守卫统计：**写入类/红线违规 `0` 次，桩未实现方法 `0` 次**，所有用例前后深层世界快照（`S.snapshot`）100% 一致。

| 用例区间 | 覆盖模块 / 主题 | 条数 | 结果 | 核心验证点摘要 |
| :---: | :--- | :---: | :---: | :--- |
| `T-00` ~ `T-01` | 加载洁净、静态红线与 `CAB_Config` | 2 | 2/2 通过 | 全局仅新增 `CAB_Config` 与 `CAB_Collector`（精确 14 项导出）；源码零出现 `CanMoveOrAttackInto` / `AirRaidCore` / `AR_EnumerateTargets`；12 配置键精确匹配 |
| `T-02` ~ `T-09` | 引擎桩核心机制自检 | 8 | 8/8 通过 | Odd-r 六边形距离、队伍视野/隐形/科技资源隔离、只读守卫陷阱、`Players` 三态槽位、深层世界快照篡改检出 |
| `T-10` ~ `T-18` | WP2：`H1`~`H7` 与 `F1`~`F4` | 9 | 9/9 通过 | `IsReadyToMove` 避坑、军民叠栈优先主战、`F-01/F-02/F-04/F-05` 迷雾分层、24 种回合阻塞枚举全覆盖、通知匹配、IGE 实时变更 |
| `T-19` ~ `T-27` | WP3：`F5` 全局态势与 `F6` 单位上下文 | 9 | 9/9 通过 | 兼容《03》§2.1/§2.2、`CanMoveThrough`+1UPT、陆海近战域校验、`F-03` 普通迷雾零 `CanRangeStrikeAt` 调用（`queriesOnForbiddenFog == 0`）、空军 8/10 格超半径射程、选区 4 路径及异常恢复 |
| `T-28` ~ `T-35` | WP4：`F7` 城市详情与购买报价单 | 8 | 8/8 通过 | `combat_str` 除 100 取整、造移民/停滞/饥荒 `turns_to_growth = -1`、城防远程目标防侧信道、双层金币/信仰报价单、`F-06` 科技资源屏蔽、`includePurchasable=false`、越权访问敌城拦截、动态 `GameDefines` 生效 |

### 4.2 第二层：《文明5：BNW v1.0.3.279》真机实证冒烟（`WP5` / `A-09`）

* **实测环境**：Windows 本机 `Sid Meier's Civilization V (DX11)` BNW `v1.0.3.279`（引擎日志显示 `Initializing Lua 5.1.4`），启用 `Civ5 Agent Command Bridge`（临时挂载 `CAB_Config.lua`、`CAB_InfoCollector.lua` 与只读冒烟脚本 `CAB_M1Sub1Smoke.lua`）进入单人大陆地图（玩家 0：中国文明）。
* **整体表现**：在局内连续触发 **9 轮全接口冒烟检验（`Pass #1` ~ `Pass #9`，每轮包含 `S01` ~ `S10` 共 10 项断言，累计 `90/90 PASS`，`0 FAIL`）**；游戏右上角状态栏实时显示 `M1Sub1 #1: PASS (10/10)` $\rightarrow$ `M1Sub1 #9: PASS (10/10)`；`Logs/Lua.log`（共 529 行）**全程 0 条语法错误、0 条运行时错误、0 条警告**；全部 9 轮完整 JSON 报告成功写入 `ModUserData/Civ5AgentBridge-1.db`（`m1sub1_smoke_pass_1` ~ `m1sub1_smoke_pass_9`）。
* **跨局内状态演进的真机量化实证摘要**：

| 检验维度（冒烟项编号） | 建城前阶段（`Pass #1` ~ `Pass #5`） | 建城后阶段（`Pass #6` ~ `Pass #9`，“北京”建成） | 真机验证结论 |
| :--- | :--- | :--- | :--- |
| **配置与导出（`S01` / `S02`）** | `CAB_Config` 12 键完整（`MAX_SCAN_RADIUS=8`）；`CAB_Collector` 精确 14 项函数导出 | 同左（稳定一致） | VFS 加载与命名空间契约 100% 正常 |
| **帝国经济（`S03` / `F1`）** | `gold=0, gpt=0, sci=0, cul=0, faith=0, happy=9`（JSON `188B`） | 建城后即时刷新为 **`gold=0, gpt=5, sci=4, cul=1, happy=5`**（JSON `188B`） | 零缓存实时反映引擎产出变化 |
| **视野与迷雾探索集（`S04` / `S07`）** | 中心 `(34,12)` 默认 `r=5` 已探索 **18 格**；`r=99` 钳制后 18 格（`<=217`）；`r=-1` 返回 `0` | 建城扩视野后即时增至 **27 格**（`r=5` 与 `r=99` 均为 27，`r=-1` 为 `0`） | 六边形视野扫描与半径上下限钳制准确 |
| **回合阻塞诊断（`S05` / `F4`）** | 首帧初始化 `NO_BLOCKING(-1)` $\rightarrow$ 随后精准识别 **`ENDTURN_BLOCKING_UNITS(3)`**，定位待命开拓者 `unit_id=8192` | 先识别待命勇士 `ENDTURN_BLOCKING_UNITS(3, unit_id=16385)` $\rightarrow$ 勇士驻扎后即时切换为 **`ENDTURN_BLOCKING_PRODUCTION(2)`**，定位 `blocking_city_id=8192` 并提取通知 **`"北京已準備好進行新的建造計畫。"`** | 阻塞枚举映射、单位/城市定位与引擎通知索引匹配在真机 100% 吻合 |
| **全局态势汇总（`S06` / `F5`）** | `turn=0, civ="中國", ourUnits=2, ourCities=0`（JSON `931B`） | 开拓者消耗建城后即时变为 **`ourUnits=1, ourCities=1`**（JSON `1,031B`） | 聚合 DTO 完整且可无损序列化 UTF-8 中文 |
| **单位战术上下文（`S08` / `F6`）** | 抽样开拓者（18 格、7 候选动作）+ 勇士（18 格、8 候选动作），**`selection_restored=true`**，迷雾格零动态字段泄露 | 抽样勇士 `16385`（视野扩大后 **25 格**、8 候选动作：`MOVE_STEP=6, FORTIFY=1, SKIP_TURN=1`，JSON `4,592B`），**`selection_restored=true`**，`r=99` 钳制 `dist<=8` | 原版 `CanMoveThrough`、原地动作探测与 UI 选区恢复在真机稳定无抖动 |
| **城市深度详情（`S09` / `F7`）** | 无己方城市时安全跳过无异常 | 采样 **`北京`（`city_id=8192`）**：`pop=1`、**`combat_str=10`**（与游戏 UI 城防横幅 `10` 完全一致）、`turns_to_growth=5`、真实建筑 `1`（宫殿）、可购建筑 `1`、可购单位 `4`、可购地块 `12`、`includePurchasable=false` 准确返回空购买表（JSON `2,755B`） | `GetStrengthValue()/100`、双层 `IsCanPurchase` 与 `CanBuyPlotAt` 真机表现完全符合预期 |
| **非法入参防御（`S10`）** | 7 主接口传入 `-1` / `999` / `-999` / `"not_a_number"` 全部返回结构化 `error` | 同左，零未捕获异常 | 边界防御稳健 |

---

## 五、 验收标准矩阵逐项对账表（`A-01` ~ `A-10`）

| 验收项 | 验收内容 | 计划判定标准 | 实测验证证据 | 验收结论 |
| :---: | :--- | :--- | :--- | :---: |
| **A-01** | Lua 5.1 语法与加载洁净 | 通过 `lupa.lua51` 编译；仅 `include("CAB_Config")` 一次；全局仅新增 `CAB_Config` 与 `CAB_Collector` | `run_m1sub1_tests.py` 阶段 1 `8/8` + 负向自检 `3/3` 通过；桩测试 `T-00` 与真机 `S01/S02` 核实精确导出 | ✅ **通过** |
| **A-02** | 接口签名与 DTO 完整性 | 7 主接口 + 7 复用辅助函数签名与字段 100% 对齐计划 §4.2~4.3 及《03》§2.1/§2.2 | `T-00` 精确 14 键集合断言 + `T-10`~`T-35` 全字段结构断言 + 真机 `CAB_JsonEncode` 实证 | ✅ **通过** |
| **A-03** | 纯只读零写入红线 | 写入类调用 = `0`，世界快照前后完全一致；选区探测结束后无条件恢复原选区 | 36 条桩测试累计 `guardViolations = 0`、`S.snapshot` 零差异；`T-25` 及真机 `S08` `selRestored=true` | ✅ **通过** |
| **A-04** | 战争迷雾与防侧信道红线 | `F-01` ~ `F-06` 全部通过：隐形敌军屏蔽、黑雾零属性泄露、普通迷雾 `CanRangeStrikeAt` 调用 = `0`、未解锁科技资源屏蔽 | `T-12`、`T-15`、`T-20`、`T-23`（`queriesOnForbiddenFog == 0`）、`T-29`、`T-31` 及真机 `S08` 迷雾校验全部通过 | ✅ **通过** |
| **A-05** | 原版 DLL 避坑与 1UPT | 源码零出现 `CanMoveOrAttackInto`；移动经 `CanMoveThrough` + 同类 1UPT；已跳过/驻扎单位 `can_act == false` | `T-00` 源码静态扫描 + `engine_stubs` 禁令陷阱 + `T-10` / `T-13` / `T-21` 专项通过 | ✅ **通过** |
| **A-06** | 无 `AirRaidLegacyUnits` 且兼容 IGE | 源码零出现 `AirRaidCore` / `AR_EnumerateTargets`；零缓存实时响应动态修改；死/延迟死/空槽位不崩溃 | `T-00` 静态扫描 + `T-07` / `T-10` / `T-18` / `T-27` / `T-34` / `T-35` + 真机建城前后动态演进实证 | ✅ **通过** |
| **A-07** | 异常入参防御与半径钳制 | 非法玩家/单位/城市 ID 及超大/负/非数字 `radius` 安全返回结构化错误或钳制结果，不抛异常 | `T-14` ~ `T-17`、`T-19`、`T-26`、`T-33` 及真机 `S07` / `S08` / `S10` 全部通过 | ✅ **通过** |
| **A-08** | 城市购买与回合阻塞精度 | `GetCityDetail` 区分规则可买与当前可负担（金币/信仰双通道）及 `BUY_PLOTS_DISABLED`；`GetEndTurnStatus` 精准定位阻塞实体与通知 | `T-17`、`T-30`、`T-31`、`T-32`、`T-35` 及真机 `Pass #2/#6/#8/#9` 单位阻塞与生产阻塞切换实证 | ✅ **通过** |
| **A-09** | 临时实机冒烟零报错 | 本机游戏实机跑通 7 个主接口冒烟采样，`Logs/Lua.log` 零运行时报错，随后临时改动 100% 回滚 | 真机连续 9 轮（`90/90 PASS`），`Logs/Lua.log` 529 行零报错，报告落盘 SQLite，临时改动已回滚 | ✅ **通过** |
| **A-10** | 隔离纪律与总结交付 | 上位三份 M1 文档与其他非白名单文件零持久化改动；完成工作总结报告与进度闭环 | `git status --short` 复核仅含白名单文件，上位文档与原 Mod 壳层文件零修改；本报告与进度文档已闭环 | ✅ **通过** |

---

## 六、 上位设计文档回写建议清单（`SYNC-01` ~ `SYNC-05`）

以下为 M1Sub1 实施过程中依据已确认决策（`D-02` ~ `D-06`）形成的**上位文档同步建议台账**，提请上级 M1 评审会话在验收通过后统一回写至 `docs/M1/` 下对应文档：

### `SYNC-01`：补充 `CAB_Config.MAX_SCAN_RADIUS` 配置项（对应决策 `D-06`）
* **目标文档与章节**：`docs/M1/模块设计说明.md` §4.1「全局只读配置变量（`Lua/CAB_Config.lua` -> `CAB_Config` 表）」
* **变更类型**：增补配置键（由 11 键扩充为 12 键）
* **建议回写内容**：在表格中新增一行：
  * 配置项键名：`MAX_SCAN_RADIUS` | 类型：`number` | 默认值：`8` | 用途与设计原因：对外部 RPC 传入的 `radius` 扫描半径执行硬上限钳制（`[0, 8]`），防止异常超大半径引发六边形全图遍历卡死 UI 帧。

### `SYNC-02`：补充 `CAB_Collector` 公开的 7 个纯只读复用辅助函数契约（对应决策 `D-03`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §四「子模块 1：信息收集子模块接口设计（`CAB_Collector`）」末尾新增 `§4.7 供任务执行子模块复用的纯只读辅助函数`
* **变更类型**：增补模块内部接口契约
* **建议回写内容**：正式登记 `CAB_Collector` 导出的 `SerializeUnitSummary(pUnit)`、`SerializeEnemyUnit(pEnemyUnit)`、`SerializeCitySummary(pCity)`、`InspectPlotUnits(pPlot, activePlayerID)`、`CanUnitMoveThrough(pUnit, pPlot)`、`HasSameClassFriendlyUnit(pPlot, activePlayerID, isSelfCombat)`、`FindGameActionIndex(actionTypeStr)` 共 7 个函数签名与职责，供 `CAB_TaskExecutor` 在动作前置校验与战后结算中直接调用。

### `SYNC-03`：移除 `AirRaidLegacyUnits` 外部 Mod 联动描述，确立原生 BNW + IGE 兼容基线（对应决策 `D-05`）
* **目标文档与章节**：
  1. `docs/M1/模块内部接口设计.md` §4.5 `CAB_Collector.BuildUnitContextAndCandidates`（第 208 行“含联动 `AR_EnumerateTargets`”）；
  2. （建议上级评审一并审视）`docs/M1/模块设计说明.md` §3.2 / §4.2 及 `模块内部接口设计.md` §5.1 / §5.2 中 `CAB_TaskExecutor` 对 `AirRaidCore` / `AR_ExecuteStrike` 的联动设计。
* **变更类型**：**契约偏离 / 删减**
* **建议回写内容**：在 §4.5 中删除 `（含联动 AR_EnumerateTargets）`，明确模块兼容基线为**原生《文明5：BNW v1.0.3.279》及 IGE（Ingame Editor）**，不依赖第三方空袭 Mod；同时建议上级评审在启动子模块 2（`CAB_TaskExecutor`）前统一拍板是否在执行层同步裁撤 `AirRaidCore` 探测逻辑，以保持采集层（候选动作枚举）与执行层（动作下发）契约完全对称。

### `SYNC-04`：细化战争迷雾防侧信道契约、可空字段约定与结构化错误返回格式（对应决策 `D-04`、`D-06`）
* **目标文档与章节**：`docs/M1/模块内部接口设计.md` §4.1 ~ §4.6
* **变更类型**：接口契约细化
* **建议回写内容**：
  1. **迷雾防侧信道契约**：明确可见敌军必须同时满足 `IsVisible(activeTeam, false)` 与 `not IsInvisible(activeTeam, false)`；单位与城市枚举远程攻击目标时，`CanRangeStrikeAt` **仅允许对实时可见格或已探索交战敌城格调用**，严禁探测普通迷雾格；
  2. **DTO 可空字段与字典标记**：所有 JSON 对象表统一携带 `__is_object = true`；可空字段无值时直接赋 Lua `nil`（省略键），使 `CAB_InfoCollector` 对 `Civ5AgentBridgeJson` 保持零依赖；
  3. **非法入参错误返回**：当玩家 ID 无效/未存活，或 `unitID`/`cityID` 不存在/已阵亡/非己方所属时，主查询接口统一返回 `{ __is_object = true, error = "<英文错误说明>" }`（`GetVisibilitySummary` 返回带空数组的错误对象与空映射表二元组；`CaptureRevealedPlotsSet` 返回 `{}`），不抛未捕获 Lua 异常。

### `SYNC-05`：同步模块 1 开发进度看板状态（对应决策 `D-02`）
* **目标文档与章节**：`docs/M1/模块设计进度.md` §三「阶段二：模块 1 编码与验证多会话拆分计划」
* **变更类型**：进度状态同步
* **建议回写内容**：
  * 将 **`M1-S2`（游戏内信息收集子模块编写）** 状态更新为 `✅ 已完成`（含独立桩测试套件与真机冒烟验证）；
  * 在 **`M1-S1`（公共配置与外部交互子模块编写）** 备注中注明 `Lua/CAB_Config.lua` 已由 M1Sub1 先行交付并通过验收，`M1-S1` 后续仅需聚焦 `Civ5AgentBridgeJson.lua` 命名空间封装与 `CAB_ExternalIO.lua` 实现。

---

## 七、 后续子模块开发衔接建议与待 `M1-S5 / M1-S6` 闭环事项

1. **供子模块 2（`CAB_TaskExecutor`，`M1-S3 / M1-S4`）直接复用的接口对接指引**：
   * **动作前基线采样**：直接调用 `local _, baselineEnemyMap = CAB_Collector.GetVisibilitySummary(activePlayerID)` 与 `CAB_Collector.CaptureRevealedPlotsSet(activePlayerID, ux, uy, CAB_Config.DELTA_REVEAL_SCAN_RADIUS)`，可 $O(1)$ 记录战前可见敌军索引与周边已探索地块集合；
   * **移动与原地动作校验**：直接调用 `CAB_Collector.CanUnitMoveThrough`、`CAB_Collector.HasSameClassFriendlyUnit` 与 `CAB_Collector.FindGameActionIndex`，确保执行层前置校验与采集层候选动作口径 100% 同源；
   * **购买后与结束回合前状态回读**：购买建筑/单位后直接调用 `CAB_Collector.SerializeCitySummary(pCity)` 生成 `city_summary_after`；`ExecuteEndTurn` 在自动跳过待命单位前后直接调用 `CAB_Collector.GetEndTurnStatus(activePlayerID)` 获取权威阻塞诊断。
2. **供调度装配层（`M1-S5`）的 VFS 加载顺序要求**：
   * 更新 `mod/Civ5AgentBridge.modinfo` 时，须将 `Lua/CAB_Config.lua` 与 `Lua/CAB_InfoCollector.lua` 均登记为 `<File import="1">`，且使用正斜杠路径；
   * 在 `Civ5AgentBridgeUI.lua`（或 `CAB_Dispatcher.lua`）顶层 `include` 时，确保 `CAB_Config` 先于其他子模块加载（`CAB_InfoCollector.lua` 内部亦已自带 `include("CAB_Config")` 自包含保护）；
   * 修改 `.modinfo` 后，务必在**《文明5》完全退出未运行状态**下执行 `scripts/deploy_mod.ps1 -ForceCopy -ClearCache` 清理 `cache/Civ5*.db`。
3. **留待 `M1-S6`（模块 1 全功能联调验收）闭环的场景**：
   * 本次 WP5 真机冒烟聚焦单人开局建城前后的全部 7 个只读主接口、阻塞切换与城市购买报价单验证；涉及**视野内交战敌军/蛮族残血结算、空军远程轰炸、城防炮击实战开火及 IGE 大规模兵团压力场景**的端到端交互，已在离线引擎桩（`T-15`、`T-22`~`T-24`、`T-29`）完成 100% 分支覆盖，后续将在 `M1-S6` 配合 `CAB_TaskExecutor` 与外部 MCP 客户端通过 `--mode live` 完成全链路真机闭环。
