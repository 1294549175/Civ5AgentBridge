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
| **总体阶段** | ⏳ **计划已编制，等待用户审阅确认后启动 WP1 编码** |
| **当前待执行工作包** | `WP1`（公共配置表与全新 Lua 5.1 桩测试底座）——待用户确认本计划后启动 |
| **最近一次测试结果** | 尚未开始全新 WP1 编码（仓库内尚存旧提交 `4e1fbaa` 的历史文件，将在 WP1 按新计划重写替换） |

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
| **Plan** | 编制 M1Sub1 工作计划与进度文档 | `docs/M1/M1Sub1/M1Sub1工作计划.md`<br>`docs/M1/M1Sub1/M1Sub1工作进度.md` | ⏳ 待用户确认 | 已完成设计对齐（D-01~D-08）与文档编写 | 2026-11-26 |
| **WP1** | 公共配置表与全新 Lua 5.1 测试桩底座 | `mod/Lua/CAB_Config.lua`<br>`tests/run_m1sub1_tests.py`<br>`tests/m1sub1/engine_stubs.lua`<br>`tests/m1sub1/test_collector.lua` | `[ ] 待执行` | — | — |
| **WP2** | `CAB_InfoCollector` 骨架 + 7 辅助函数 + 经济/视野/回合阻塞 | `mod/Lua/CAB_InfoCollector.lua`<br>`tests/m1sub1/test_collector.lua` | `[ ] 待执行` | — | — |
| **WP3** | 全局态势汇总与单位局部战术上下文 | `mod/Lua/CAB_InfoCollector.lua`<br>`tests/m1sub1/test_collector.lua` | `[ ] 待执行` | — | — |
| **WP4** | 城市详情、城防目标与可购买项报价单 | `mod/Lua/CAB_InfoCollector.lua`<br>`tests/m1sub1/test_collector.lua` | `[ ] 待执行` | — | — |
| **WP5** | 全量离线验收 + 临时实机冒烟回滚 + 工作总结报告 | 临时挂载验证并回滚<br>`docs/M1/M1Sub1/M1Sub1工作总结报告.md` | `[ ] 待执行` | — | — |

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
