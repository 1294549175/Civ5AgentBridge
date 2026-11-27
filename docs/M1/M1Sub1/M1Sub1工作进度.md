# M1Sub1（游戏内信息收集子模块 `CAB_InfoCollector`）工作进度与多会话交接记录

> [!NOTE]
> 本文档用于跨会话追踪 **M1Sub1：游戏内信息收集子模块（`CAB_InfoCollector`）** 的计划确认、分包编码、离线与实机验收进度及交接上下文。每次新会话开始前应首先阅读本文档，完成后就地更新对应状态与交接日志。
>
> **红线提醒**：本子模块全过程**严禁直接修改**上位三文档（`docs/M1/模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）。全部需要同步回写上位文档的变更建议，统一先登记于本文档「四、待上级评审回写的文档偏离与增补台账」，最终汇总进《M1Sub1工作总结报告.md》。

---

## 一、 当前总览看板

| 项目 | 当前状态 |
| :--- | :--- |
| **所属上级模块** | 模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`） |
| **本子模块范围** | 子模块 1：游戏内信息收集子模块（`CAB_Config.lua` + `CAB_InfoCollector.lua` + 独立验收测试） |
| **前置可启动性评估** | ✅ **可立即启动**（仅依赖静态只读表 `CAB_Config.lua`，无前序子模块运行时依赖） |
| **总体阶段** | ✅ **WP1 ~ WP5 全部完成，已产出《M1Sub1工作总结报告.md》提交 M1 验收** |
| **当前待执行工作包** | 无（本子模块编码、离线测试、真机冒烟与回滚收尾全部闭环，等待上级 M1 评审验收） |
| **最近一次测试结果** | ① 离线：`python tests/run_m1sub1_tests.py` 退出码 `0`（语法 8/8 + 3 负向自检通过；桩测试 36/36 通过；只读守卫违规 `0` 次、未实现方法 `0` 次）；② 真机：原生 BNW 连续 9 轮冒烟 `90/90 PASS`、`Logs/Lua.log` 0 报错，临时挂载已 100% 回滚 |

---

## 二、 决策确认登记表（来自 2026-11-26 设计对齐）

| 编号 | 决策要点 | 已确认方案 | 状态 |
| :---: | :--- | :--- | :---: |
| **D-01** | 工作基线 | 全新重来：以 `docs/M1/` 三份文档为唯一起点，允许重写现有 `CAB_Config.lua` 与 `tests/m1sub1/*`、`run_m1sub1_tests.py` | ✅ 已确认 |
| **D-02** | 文件隔离边界 | 严格隔离：仅持久化改动白名单内文件（`CAB_Config.lua`、`CAB_InfoCollector.lua`、测试文件与 `docs/M1/M1Sub1/` 文档），不动上位三文档与其余 Mod 文件 | ✅ 已确认 |
| **D-03** | 复用函数导出 | `CAB_Collector` 公开 7 个主查询接口 + 7 个供 `CAB_TaskExecutor` 复用的纯只读辅助函数 | ✅ 已确认 |
| **D-04** | 迷雾与防侧信道 | 过滤 `IsInvisible`；`CanRangeStrikeAt` 仅限可见格或已探索敌对城；迷雾敌城保留 `hp`/`pop` 并标 `in_fog=true`；相邻黑雾仅允许探路 `MOVE_STEP` | ✅ 已确认 |
| **D-05** | Mod 兼容范围 | 不接入 `AirRaidLegacyUnits`；仅面向原生 BNW v1.0.3.279 与 IGE 兼容（零状态缓存、存活/延迟死防护、选区安全恢复） | ✅ 已确认 |
| **D-06** | DTO 与配置约定 | 可空字段用 Lua `nil`（零 `CAB_Json` 依赖）；非法入参统一 `{ __is_object = true, error = "..." }`；`CAB_Config` 增补 `MAX_SCAN_RADIUS = 8` | ✅ 已确认 |
| **D-07** | 双层验收标准 | 离线 `lupa.lua51` 语法 + 引擎桩测试，再加 WP5 临时实机冒烟（原生 + IGE）并 100% 回滚临时挂载改动 | ✅ 已确认 |
| **D-08** | 文档命名与本会话边界 | 统一命名 `M1Sub1工作计划.md` / `M1Sub1工作进度.md` / `M1Sub1工作总结报告.md`；先产出计划与进度文档报确认后再启动 WP1 | ✅ 已确认 |

---

## 三、 工作包进度追踪表（`WP1` ~ `WP5`）

| 编号 | 工作包名称 | 计划涉及文件 | 状态 | 实测摘要（通过/失败/只读守卫） | 完成日期 |
| :---: | :--- | :--- | :---: | :--- | :---: |
| **Plan** | 编制 M1Sub1 工作计划与进度文档 | `docs/M1/M1Sub1/M1Sub1工作计划.md`<br>`docs/M1/M1Sub1/M1Sub1工作进度.md` | ✅ 已完成 | 已完成设计对齐（D-01~D-08）与计划审阅确认 | 2026-11-26 |
| **WP1** | 公共配置表与全新 Lua 5.1 测试桩底座 | `mod/Lua/CAB_Config.lua`<br>`tests/run_m1sub1_tests.py`<br>`tests/m1sub1/engine_stubs.lua`<br>`tests/m1sub1/test_collector.lua` | ✅ 已完成 | 语法 7/7 + 3 负向自检通过；桩自检 9 通过 / 0 失败 / 1 跳过（`T-00`）；只读守卫 0 违规 | 2026-11-26 |
| **WP2** | `CAB_InfoCollector` 骨架 + 7 辅助函数 + 经济/视野/回合阻塞 | `mod/Lua/CAB_InfoCollector.lua`<br>`tests/m1sub1/test_collector.lua` | ✅ 已完成 | 语法 8/8 + 3 负向自检通过；桩测试 19 通过（`T-00` ~ `T-18`）/ 0 失败 / 0 跳过；只读守卫 0 违规 | 2026-11-27 |
| **WP3** | 全局态势汇总与单位局部战术上下文 | `mod/Lua/CAB_InfoCollector.lua`<br>`tests/m1sub1/test_collector.lua` | ✅ 已完成 | 语法 8/8 + 3 负向自检通过；桩测试 28 通过（`T-00` ~ `T-27`）/ 0 失败 / 0 跳过；只读守卫 0 违规 | 2026-11-27 |
| **WP4** | 城市详情、城防目标与可购买项报价单 | `mod/Lua/CAB_InfoCollector.lua`<br>`tests/m1sub1/test_collector.lua` | ✅ 已完成 | 语法 8/8 + 3 负向自检通过；桩测试 36 通过（`T-00` ~ `T-35`）/ 0 失败 / 0 跳过；只读守卫 0 违规 | 2026-11-27 |
| **WP5** | 全量离线验收 + 临时实机冒烟回滚 + 工作总结报告 | 临时挂载验证并回滚<br>`docs/M1/M1Sub1/M1Sub1工作总结报告.md` | ✅ 已完成 | 离线 8/8 语法 + 36/36 桩测试全通过（0 违规）；真机连续 9 轮（`90/90`）全通过、`Lua.log` 0 报错；临时挂载 100% 回滚 | 2026-11-27 |

---

## 四、 待上级评审回写的文档偏离与增补台账

> 本台账记录实施期间相对 `docs/M1/` 三份上位文档的**增补项、细化项与偏离项**，严禁直接修改上位文档，待 WP5 汇总至《M1Sub1工作总结报告.md》由上级评审拍板后统一更新：

| 台账编号 | 涉及上位文档与章节 | 类型 | 内容摘要 | 对应决策 |
| :---: | :--- | :---: | :--- | :---: |
| **SYNC-01** | `模块设计说明.md` §4.1 | 增补 | `CAB_Config` 新增第 12 键 `MAX_SCAN_RADIUS = 8`，用于钳制外部传入的 `radius` 参数防止超大范围扫描卡死游戏。 | D-06 |
| **SYNC-02** | `模块内部接口设计.md` §四 | 增补 | `CAB_Collector` 除 7 个主接口外，额外公开 7 个供 `CAB_TaskExecutor` 复用的纯只读辅助函数（`SerializeUnitSummary`、`SerializeEnemyUnit`、`SerializeCitySummary`、`InspectPlotUnits`、`CanUnitMoveThrough`、`HasSameClassFriendlyUnit`、`FindGameActionIndex`）。 | D-03 |
| **SYNC-03** | `模块内部接口设计.md` §4.5（及 `模块设计说明.md` §3.1/§4.2） | **偏离/删减** | 明确不兼容/不联动 `AirRaidLegacyUnits`（移除 `AR_EnumerateTargets` 相关调用与描述），仅面向原生 BNW v1.0.3.279 与 IGE 兼容。 | D-05 |
| **SYNC-04** | `模块内部接口设计.md` §4.2、§4.5 | 细化 | 明确迷雾防侧信道契约：过滤 `IsInvisible` 隐形敌军；`CanRangeStrikeAt` 仅允许对实时可见格或已探索敌对城调用；可空字段使用 Lua `nil` 省略键；非法入参统一返回 `{ __is_object = true, error = "..." }`。 | D-04、D-06 |
| **SYNC-05** | `模块设计进度.md` §二、§三 | 状态同步 | M1Sub1 先行独立交付 `CAB_Config.lua` 与 `CAB_InfoCollector.lua`（对应原 `M1-S1` 的配置部分 + 全部 `M1-S2`），验收通过后需同步勾选进度并更新 `M1-S1` 范围说明。 | D-02 |

---

## 五、 跨会话交接日志（Session Log）

### Session 0 — 2026-11-26（规划与决策对齐会话）
* **完成工作**：
  1. 完整研读 `docs/M1/` 三份上位设计文档、`docs/03_接口设计说明书.md`、原型文件 `Civ5AgentBridgeCore.lua` / `UI.lua` / `Json.lua` / `.modinfo` 及本机 `CvLuaCity.cpp` 关键购买接口签名；
  2. 核查仓库现状：确认实际路径在 `C:\Users\Chen\Documents\My Games\Sid Meier's Civilization 5\Civ5AgentBridge`，本机全局 `Python 3.14.6` 已安装 `lupa`（内置 Lua 5.1）；
  3. 经逐项决策对齐确定 `D-01` ~ `D-08`，评估确认 M1Sub1 当前无阻塞前序工作、可直接独立推进；
  4. 编写 `docs/M1/M1Sub1/M1Sub1工作计划.md` 与 `docs/M1/M1Sub1/M1Sub1工作进度.md`（未改动任何上位文档与业务源码）。
* **当前卡点 / 交接给下一会话**：
  * **等待用户审阅并确认《M1Sub1工作计划.md》**。
  * 一旦用户确认，下一会话（或本会话继续）立即执行 **WP1**：按新计划重写 `mod/Lua/CAB_Config.lua`、`tests/run_m1sub1_tests.py`、`tests/m1sub1/engine_stubs.lua`、`tests/m1sub1/test_collector.lua`（去除所有旧 `SubM1` 遗留引用与 `AirRaid` 痕迹，对齐本机全局 `python` 与 `lupa.lua51`），跑通 WP1 语法+桩自检并更新本文档进度。

### Session 1 — 2026-11-26（WP1 公共配置表与全新 Lua 5.1 桩测试底座）
* **完成工作**：
  1. 全新重写 `mod/Lua/CAB_Config.lua`：纯静态 Lua 5.1 全局表，严格包含 12 个规定配置键（含决策 `D-06` 增补的 `MAX_SCAN_RADIUS = 8`），零 `include`、零函数、零引擎调用；
  2. 全新重写 `tests/run_m1sub1_tests.py`：对接本机全局 `Python 3.14.6` + `lupa.lua51`，实现 3 项负向语法自检（普通语法错误 + Lua 5.2 `goto` + Lua 5.3 `//` 整除拒绝）、`--filter` 用例过滤及统一退出码（`0`/`1`/`2`）；
  3. 全新重写 `tests/m1sub1/engine_stubs.lua`：彻底根除旧提交 `4e1fbaa` 中的 3 项关键缺陷（修复 `S.snapshot` 未展开实体 `_s` 导致无法检出世界状态篡改的漏洞、修复 `queriesOnInvisible` 误计入越界空地块调用的问题、修复部分 `costs` 子表空值索引异常），新增 F-03 专项筛选 `w:queriesOnForbiddenFog()`、A-05 禁令陷阱 `Unit:CanMoveOrAttackInto`、`Unit:CanFortify`、显式 `nil` 玩家槽位及 IGE 变阵助手（`w:setPlayer` / `w:setUnit` / `w:setCity`）；
  4. 全新重写 `tests/m1sub1/test_collector.lua`：修复旧版 `T-01` 全局变量 `_` 泄露与 include 计数断言，在 `T-00` 预置静态源码红线扫查（`CanMoveOrAttackInto` / `AirRaidCore` / `AR_EnumerateTargets`），完善 `T-01` ~ `T-09` 全套契约与桩自检用例。
* **实测与隔离核验**：
  * `python tests/run_m1sub1_tests.py`：退出码 `0`，语法检查 7 通过 / 0 失败 / 1 待创建（`CAB_InfoCollector.lua`）+ 3 负向自检通过；桩测试 9 通过（`T-01` ~ `T-09`）/ 0 失败 / 1 跳过（`T-00`）；只读守卫违规 `0` 次、未实现方法 `0` 次；
  * `python tests/run_m1sub1_tests.py --filter T-01`：退出码 `0`，单条过滤运行正常；
  * `git status --short` 核验仅包含白名单文件（`CAB_Config.lua`、`run_m1sub1_tests.py`、`engine_stubs.lua`、`test_collector.lua`、`M1Sub1工作进度.md`），上位三文档及其他 Mod 文件零改动。
* **交接给下一会话（WP2 接力提示）**：
  * 立即进入 **WP2**：新建 `mod/Lua/CAB_InfoCollector.lua`（仅 `include("CAB_Config")` 一次、仅导出唯一全局 `CAB_Collector`），实现 H1 ~ H7 全部 7 个纯只读复用辅助函数与 4 个基础查询主接口（`GetEmpireEconomy`、`GetVisibilitySummary`、`CaptureRevealedPlotsSet`、`GetEndTurnStatus`）；
  * 在 `tests/m1sub1/test_collector.lua` 第 3 节之后追加 WP2 契约、迷雾/隐形（F-01/F-02）、24 种阻塞类型与非法入参兜底用例，激活 `T-00` 冒烟与静态红线扫查，并跑通 `python tests/run_m1sub1_tests.py` 全量绿灯。

### Session 2 — 2026-11-27（WP2 `CAB_InfoCollector` 骨架 + 7 辅助函数 + 经济/视野/回合阻塞）
* **完成工作**：
  1. 新建 `mod/Lua/CAB_InfoCollector.lua`（前半）：严格仅 `include("CAB_Config")` 一次、仅导出唯一全局表 `CAB_Collector`、全部内部辅助均为 `local`、零跨调用状态缓存（兼容 IGE 与多世界测试动态覆盖 `GameDefines`）、源码零出现禁令标识符（`CanMoveOrAttackInto` / `AirRaidCore` / `AR_EnumerateTargets`）；
  2. 实现全部 7 个公开纯只读复用辅助函数（H1~H7）：`SerializeUnitSummary`（含 `MovesLeft > 0 and IsReadyToMove` 精准 `can_act` 与两位小数截断、`IsDead`/`IsDelayedDeath` 过滤）、`SerializeEnemyUnit`（复合 `enemy_id`）、`SerializeCitySummary`（含 7 项分项 `yields` 与 `can_range_strike`）、`InspectPlotUnits`（军民叠栈优先主战 + F-02 隐形过滤）、`CanUnitMoveThrough`（`pcall` 包裹隔离原版 DLL 缺陷）、`HasSameClassFriendlyUnit`（1UPT 战斗/民用分离）、`FindGameActionIndex`（`Game.CanHandleAction` 双重校验）；
  3. 实现 4 个基础域主查询接口：`GetEmpireEconomy`（产出全量 + 战略/奢侈资源分类与零储量过滤）、`GetVisibilitySummary`（F-01/F-02/F-04/F-05 迷雾分层 + 双返回值 + 存活/死/nil 槽位兼容）、`CaptureRevealedPlotsSet`（默认半径 5、上限钳制至 `MAX_SCAN_RADIUS = 8`、非法入参返回 `{}`）、`GetEndTurnStatus`（全量 24 种 `EndTurnBlockingTypes` 枚举映射 + `NO_BLOCKING`、`UI.CanEndTurn` 联动、单位/晋升/非受限闲置城定位与通知索引精确匹配）；
  4. 扩充 `tests/m1sub1/test_collector.lua`：激活 `T-00` 静态红线与加载洁净检查并补充 WP2 导出断言；新增 `ensureCollectorLoaded()` 支撑 `--filter` 单独执行；新增第 4 节 `T-10` ~ `T-18` 共 9 条专项用例（覆盖 H1~H7、F1~F4、迷雾/隐形、24 种阻塞枚举、非法入参兜底及 IGE 动态变更）。
* **实测与隔离核验**：
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：退出码 `0`，语法检查 8 通过 / 0 失败 / 0 待创建 + 3 项负向自检通过；桩测试 19 通过（`T-00` ~ `T-18`）/ 0 失败 / 0 跳过；只读守卫违规 `0` 次、桩未实现方法 `0` 次；
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py --filter T-14`：退出码 `0`，单条过滤运行 1/1 通过；
  * `git -C Civ5AgentBridge status --short` 核验仅包含白名单产出文件，三份上位 M1 文档与其他 Mod 文件零改动。
* **交接给下一会话（WP3 接力提示）**：
  * 立即进入 **WP3**：在 `mod/Lua/CAB_InfoCollector.lua` 中续写 `BuildTurnOverview`（聚合复用 `GetEmpireEconomy`、`GetVisibilitySummary`、`GetEndTurnStatus`、`SerializeUnitSummary`、`SerializeCitySummary`，100% 向下兼容《03》§2.1）与 `BuildUnitContextAndCandidates`（遵循 F-01~F-05，严禁对普通迷雾格/黑雾格调用 `CanRangeStrikeAt`，`queriesOnForbiddenFog == 0`，支持空军射程与临时选区安全恢复含 `pcall` 兜底，不引入 `AirRaidLegacyUnits`）；
  * 在 `tests/m1sub1/test_collector.lua` 第 4 节之后追加 WP3 专项用例并验证全量绿灯。

### Session 3 — 2026-11-27（WP3 全局态势汇总与单位局部战术上下文/候选动作）
* **完成工作**：
  1. 扩充 `mod/Lua/CAB_InfoCollector.lua`（中段）：新增内部局部辅助函数 `resolveRowType` / `isTeamAtWarWithPlayer` 及第 4 节两个主查询接口（F5、F6），严格遵循 Lua 5.1 语法、零跨调用状态缓存与源码红线（零出现 `CanMoveOrAttackInto` / `AirRaidCore` / `AR_EnumerateTargets`）；
  2. 实现 `CAB_Collector.BuildTurnOverview(activePlayerID)` [F5]：纯聚合复用 WP2 的 `GetEmpireEconomy`、`GetVisibilitySummary`、`GetEndTurnStatus`、`SerializeUnitSummary` 与 `SerializeCitySummary`，100% 向下兼容《03》§2.1 `TurnOverviewDTO` 并附带扩展经济、城市产出及回合阻塞状态；
  3. 实现 `CAB_Collector.BuildUnitContextAndCandidates(activePlayerID, unitID, radius)` [F6]：
     * `surrounding_tiles` 严格按钳制至 `[0, CAB_Config.MAX_SCAN_RADIUS]` 的 `radius` 导出（非数字报错）；内部 `scanRadius` 覆盖 `max(r, moves>0 and 1 or 0, effectiveRange)`（空军射程上限 `MAX_AIR_SCAN_RADIUS = 20` 覆盖隐形轰炸机等全部原生 BNW 空军单位）；
     * 严格遵守迷雾防侧信道红线 F-01 ~ F-05：黑雾格绝不泄露地形/单位且仅相邻非空军有移动力时生成无预览探路 `MOVE_STEP`；迷雾格省略 `improvement` / `friendly_unit_id` / `enemy_unit`；`CanRangeStrikeAt` 仅允许对实时可见格或已探索交战敌城调用；
     * 陆海近战攻击使用敌城真实血量预览（`getMaxCityHp - GetDamage`）并校验 `IsCanAttack`、域匹配与不可通行格；邻格移动统一复用 `CanUnitMoveThrough` + `HasSameClassFriendlyUnit`（1UPT）；
     * 原地动作（`SETUP_FOR_RANGED` / `FORTIFY` / `HEAL` / `SKIP_TURN`，含 `CanFortify` / `CanHeal` 回退）探测使用 `pcall` 包裹并在退出前无条件恢复原选区（原选中存活则复选，原无选中则调 `ClearSelectionList`，原已选中自身不抖动，绝不修改界面模式）；
  4. 扩充 `tests/m1sub1/test_collector.lua`：在 `T-00` 追加 WP3 导出校验，新增第 5 节 `T-19` ~ `T-27` 共 9 条专项用例（覆盖全量契约、F-01~F-05 迷雾防侧信道、`CanMoveThrough`+1UPT、陆海近战与敌城血量、空军超半径射程、选区 4 路径及异常恢复、半径钳制/非法入参及 IGE 实时动态变更）。
* **实测与隔离核验**：
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：退出码 `0`，语法检查 8 通过 / 0 失败 / 0 待创建 + 3 项负向自检通过；桩测试 28 通过（`T-00` ~ `T-27`）/ 0 失败 / 0 跳过；只读守卫违规 `0` 次、桩未实现方法 `0` 次；
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py --filter T-23`：退出码 `0`，单条过滤运行 1/1 通过；
  * `git -C Civ5AgentBridge status --short` 核验仅包含白名单产出文件，三份上位 M1 文档及其他 Mod 文件零改动。
* **交接给下一会话（WP4 接力提示）**：
  * 立即进入 **WP4**：在 `mod/Lua/CAB_InfoCollector.lua` 中补齐最后一个主查询接口 `CAB_Collector.GetCityDetail(activePlayerID, cityID, includePurchasable)` [F7]（基础态、分项产出、队列、驻军、真实建筑、城防远程炮击目标、双层 `IsCanPurchase` 建筑/单位金币与信仰报价单、可购地块科技过滤资源 F-06 与 `BUY_PLOTS_DISABLED` 开关）；
  * 在 `tests/m1sub1/test_collector.lua` 中更新 `T-00` 校验全部 7 主接口 + 7 辅助函数导出，并在第 5 节之后追加 WP4 城市详情与买地/购买专项用例（含 `includePurchasable = false`、傀儡/占领/抵抗/焚城、非法/越权 `cityID` 防御），跑通全量绿灯。

### Session 4 — 2026-11-27（WP4 城市详情、城防目标与可购买项报价单）
* **完成工作**：
  1. 补齐 `mod/Lua/CAB_InfoCollector.lua` 收尾段（第 5 节）：新增内部动态常量读取 `getCityAttackRange()` 与最后一个主查询接口 `CAB_Collector.GetCityDetail(activePlayerID, cityID, includePurchasable)` [F7]，至此模块全部 7 个主查询接口 + 7 个复用只读辅助函数（共 14 项导出）全部实现完毕；
  2. 对照本机原生 BNW 官方脚本（`ProductionPopup.lua`、`CityView.lua`、`WorldView.lua`）严密对齐实现口径：
     * `city.combat_str` 按 `CityView.lua:855` 对 `GetStrengthValue()` 除以 100 向下取整；
     * `yields.turns_to_growth` 按 `CityView.lua:1666-1673` 在造移民（`IsFoodProduction()`）、停滞（`FoodDifferenceTimes100() <= 0`）或饥荒时统一输出 `-1`；
     * `garrison_unit_id` 统一过滤 `nil` / 已死 / 延迟死亡 / 非己方单位，无有效驻军时省略键；
     * `built_buildings` 仅导出 `GetNumRealBuilding(id) > 0` 的真实建筑；
     * `ranged_attack_targets` 仅在 `CanRangeStrikeNow() == true` 时扫描 `GameDefines.CITY_ATTACK_RANGE` 内实时可见格，复用 `InspectPlotUnits` 过滤隐形敌军（F-02）并优先主战单位，仅对交战敌国或蛮族调用 `CanRangeStrikeAt(px, py, true, true)`（迷雾/黑雾格零探测，F-01/F-03）；
     * `purchasable_buildings` / `purchasable_units` 采用双层 `IsCanPurchase(false, false, ...)` / `(true, true, ...)` 区分规则可买与当前买得起，金币与信仰双通道独立报价（不支持的通道置 `0`/`false`，单位信仰价按 `ProductionPopup.lua:457` 传参 `(unitTypeId, true)`）；
     * `purchasable_plots` 检查 `BUY_PLOTS_DISABLED == 0`、非傀儡/非抵抗/非焚城（保留已过抵抗期占领城买地能力）及地块 `IsRevealed`，资源严格经 `GetResourceType(activeTeam)` 过滤以屏蔽未解锁科技资源（F-06）；`includePurchasable == false` 时三类购买数组均返回空表；
  3. 扩充 `tests/m1sub1/test_collector.lua`：在 `T-00` 升级为 `exactKeys` 校验全部 14 项精确导出；新增第 6 节 `T-28` ~ `T-35` 共 8 条专项用例（覆盖全量 DTO 契约、城防炮击与迷雾/隐形防侧信道、双层金币/信仰报价单、可购地块与 F-06 科技资源过滤、`includePurchasable=false` 与傀儡/占领/抵抗/焚城、非法入参与敌城越权拒绝、IGE 零缓存实时变更及动态 `GameDefines` 覆盖）。
* **实测与隔离核验**：
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：退出码 `0`，语法检查 8 通过 / 0 失败 / 0 待创建 + 3 项负向自检通过；桩测试 36 通过（`T-00` ~ `T-35`）/ 0 失败 / 0 跳过；只读守卫违规 `0` 次、桩未实现方法 `0` 次；
  * `python Civ5AgentBridge/tests/run_m1sub1_tests.py --filter T-29`：退出码 `0`，单条过滤运行 1/1 通过；
  * `git -C Civ5AgentBridge status --short` 核验仅包含白名单产出文件，三份上位 M1 文档与其他 Mod 文件零改动。
* **交接给下一会话（WP5 接力提示）**：
  * 立即进入 **WP5（收官验收）**：
    1. 复核全量离线测试 `python Civ5AgentBridge/tests/run_m1sub1_tests.py` 与验收标准 `A-01` ~ `A-08`；
    2. 按计划 §3.2 临时挂载 `CAB_Config.lua` 与 `CAB_InfoCollector.lua` 至本机游戏完成原生 BNW + IGE 实机冒烟，确认全部 7 个主查询接口返回有效结构且 `Logs/Lua.log` 零报错（验收项 `A-09`）；
    3. **100% 回滚**所有临时挂载改动并经 `git status` / `git diff` 核验仅留白名单产出文件（验收项 `A-10`）；
    4. 汇总本台账 `SYNC-01` ~ `SYNC-05` 及实机验证记录，编写 `docs/M1/M1Sub1/M1Sub1工作总结报告.md` 并闭环本文档进度。

### Session 5 — 2026-11-27（WP5 全量离线验收、真机冒烟回滚与工作总结报告闭环）
* **完成工作**：
  1. 复核离线全量自动化测试 `python Civ5AgentBridge/tests/run_m1sub1_tests.py`：8 项 Lua 5.1 语法编译 + 3 项负向自检全部通过，`T-00` ~ `T-35` 共 36 条桩测试用例 100% 通过，只读守卫违规 `0` 次、未实现桩方法 `0` 次；
  2. 配合用户在本机《文明5：BNW v1.0.3.279》（DX11，`Lua 5.1.4`）完成建城前/建城后连续 **9 轮真机冒烟验证（`Pass #1` ~ `Pass #9`，累计 `90/90 PASS`，`0 FAIL`）**，采集 `Logs/Lua.log`（529 行零语法/运行时错误）与 `ModUserData/Civ5AgentBridge-1.db`（`m1sub1_smoke_pass_1` ~ `m1sub1_smoke_pass_9`），实证 `CAB_Config` 12 键、`CAB_Collector` 14 项导出、7 个主接口动态无缓存刷新、阻塞枚举与本地化通知精确匹配、UI 选区无损恢复、`combat_str` 除 100 换算及双层购买报价单全部正常；
  3. **100% 回滚临时冒烟改动**：还原 `mod/Civ5AgentBridge.modinfo` 与 `mod/Lua/Civ5AgentBridgeUI.lua`，移除临时脚本 `mod/Lua/CAB_M1Sub1Smoke.lua`，同步刷新 `MODS/Civ5AgentBridge/`，回滚后再次跑通 `run_m1sub1_tests.py` 全量绿灯；
  4. 编写完成《`docs/M1/M1Sub1/M1Sub1工作总结报告.md`》，完整呈报交付清单、`A-01` ~ `A-10` 对账结果、`SYNC-01` ~ `SYNC-05` 上位文档回写建议及后续子模块衔接说明，并更新本文档闭环 M1Sub1 全部进度。
* **最终隔离核验**：
  * `git -C Civ5AgentBridge status --short` 仅含白名单文件（`CAB_Config.lua`、`CAB_InfoCollector.lua`、`run_m1sub1_tests.py`、`engine_stubs.lua`、`test_collector.lua` 及 `docs/M1/M1Sub1/` 下三份文档），`docs/M1/` 上位三文档与其他所有 Mod 文件零持久化改动。
