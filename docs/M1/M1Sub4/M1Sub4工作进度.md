# M1Sub4（外部交互子模块 `CAB_ExternalIO` + `CAB_Json` 与最终壳层合龙）工作进度与多会话交接记录

> [!NOTE]
> 本文档用于跨会话追踪 **M1Sub4：外部交互子模块（`CAB_ExternalIO` + `CAB_Json`）与模块 1 最终壳层合龙** 的计划确认、分工作包编码、跨语言 SQLite 离线测试、最终壳层装配部署与正式部署态真机验收进度。后续每个协作会话开始前应首先阅读本文档定位当前工作包与交接上下文，完成后就地更新对应状态与会话日志。
>
> **红线提醒（D-01）**：本子模块全过程**严禁修改**上位三文档（`docs/M1/模块设计说明.md`、`模块内部接口设计.md`、`模块设计进度.md`）、顶层《01~03》文档、已结项的 `docs/M1/M1Sub1~3/*`、已验收的核心业务源码（`CAB_Config.lua`、`CAB_InfoCollector.lua`、`CAB_TaskExecutor.lua`、`CAB_Dispatcher.lua`）、前序三套测试（`tests/run_m1sub1~3_tests.py`、`tests/m1sub1~3/*`）、已实证 UI/Loader XML 与部署脚本（`Civ5AgentBridgeUI.xml`、`Civ5AgentBridgeLoader.lua/.xml`、`scripts/deploy_mod.ps1`）以及历史实验目录（`tests/exp05~07/*`）。全部需同步回写上位文档的事项统一先登记于本文档「四、待上级评审回写的文档偏离与增补台账」，最终于 WP4 汇总至《M1Sub4工作总结报告.md》。

---

## 一、 当前总览看板

| 项目 | 当前状态 |
| :--- | :--- |
| **所属上级模块** | 模块 1：游戏端纯 Lua 桥接 Mod（`Civ5AgentBridge`） |
| **本子模块范围** | 子模块 4（`mod/Lua/Civ5AgentBridgeJson.lua` + `mod/Lua/CAB_ExternalIO.lua`）+ 模块 1 最终壳层合龙（`Civ5AgentBridgeUI.lua` + `Civ5AgentBridge.modinfo` + `Civ5AgentBridgeCore.lua` 退役存根 + 正式部署）+ 独立测试套件（`tests/run_m1sub4_tests.py` & `tests/m1sub4/*`） |
| **前置可启动性评估** | ✅ **可立即启动**（`CAB_Config`、`CAB_InfoCollector`、`CAB_TaskExecutor`、`CAB_Dispatcher` 均已于 2026-11-27 验收通过，`CAB_Dispatcher` 已预埋守卫式 `CAB_ExternalIO` 加载与全量 7 项依赖自检，零改代码即可无缝合龙） |
| **总体阶段** | 🟡 **开发中（`WP1`~`WP3` 已验收，正式部署就绪，待启动 `WP4` 真机验收）**（最终壳层合龙、五模块全栈离线联调、四套件总回归与正式镜像部署均已交付） |
| **当前待执行工作包** | **`WP4`：正式部署态原生 BNW/IGE 真机全链路实证验收（不回滚）+ 产出《M1Sub4工作总结报告.md》** |
| **最近一次测试结果** | ✅ **2026-11-28 WP3 全部通过**：`run_m1sub4_tests.py` 语法 `13/13` + 3 负向自检 + `.modinfo` 校验 `10/10` + 用例 `23/23`（单测 `16/16`、全栈 `7/7`，`--filter T-19` `1/1`）、红线违规 `0`；前序三套件零回归（M1Sub1 `40/40`、M1Sub2 `38/38`、M1Sub3 `29/29`，四套件合计 `130/130` 全绿）；`MODS/Civ5AgentBridge/` 12/12 SHA256 镜像一致且缓存库清零 |

---

## 二、 决策确认登记表（来自 2026-11-27 `/grill-me` 设计对齐）

| 编号 | 决策要点 | 已确认方案 | 状态 |
| :---: | :--- | :--- | :---: |
| **D-01** | 范围边界与严格隔离红线 | 明确覆盖 M1Sub4（`CAB_ExternalIO` + `CAB_Json`）与模块 1 最终壳层合龙（`Civ5AgentBridgeUI.lua` + `.modinfo` + 正式部署）；严禁修改上位三文档、顶层《01~03》、已验收 4 个业务 Lua 模块及前序测试/历史实验脚本；上位同步项登记 `SYNC-M4-*` 待评审统一回写，`M1-S6` 顶层文档回写另行收口 | ✅ 已确认 |
| **D-02** | `Civ5AgentBridgeCore.lua` 退役策略 | 从 `.modinfo` `<Files>` 中彻底移除 `Lua/Civ5AgentBridgeCore.lua`（游戏零加载），并将源码文件替换为极简合法 Lua 5.1 退役说明存根，确保前序 `run_m1sub1~3_tests.py` 无需改动即可 100% 回归全绿 | ✅ 已确认 |
| **D-03** | `CAB_Json` 升级与加固粒度 | 100% 保留旧全局函数（`CAB_JsonEncode` / `CAB_JsonDecode` / `CAB_JSON_NULL`），新增 `CAB_Json = { Encode, Decode, NULL }` 命名空间；同步加固 4 项生产边界：尾随垃圾拦截、严格 `\uXXXX` 四位十六进制 + UTF-16 代理对转 4 字节 UTF-8、`Encode` 循环引用与深度上限（`64`）防爆栈、非法字面量与未转义控制字符拦截 | ✅ 已确认 |
| **D-04** | `CAB_ExternalIO` 通信契约与加固 | 严格落实 §三 全部 7 项核心接口 + UTF-8 首字节边界对齐 3KB 分片，并增补 3 项加固：① `PushTurnOverview` 落盘后追加写入 `turn_overview_auto_seq` 原子序号屏障；② 仅当 `rpc_session_id` 变更为新非空值时重置 `s_LastProcessedReqId=0`，且 JSON 解码为非对象时直接由 ExternalIO 拦截回错；③ 增补第 8 个纯只读诊断函数 `CAB_ExternalIO.GetRuntimeState()`（零句柄/闭包泄露） | ✅ 已确认 |
| **D-05** | 最终壳层合龙、Python 驱动归属与部署 | `Civ5AgentBridgeUI.lua` 精简为纯事件转发壳层（自底向上守卫式加载 6 模块，仅 `Initialize` 返回 `true` 时挂 4 项回调，失败显示错误文案）；`.modinfo` 登记全部 10 个正式文件（全 `import="1"`、正斜杠、移除 `Core`）；不改历史 `tests/exp06/sqlite_bridge.py`，在 `tests/m1sub4/live_smoke_client.py` 落地 `text_factory=bytes` 拼片解码与 `rpc_session_id` 握手；统一用 `deploy_mod.ps1 -ForceCopy -ClearCache` 部署 | ✅ 已确认 |
| **D-06** | 工作包拆分与 WP4 不回滚真机验收 | 拆为 `WP1`~`WP4` 共 4 包（每包约 1 会话）；离线测试在 `lupa.lua51` 背后接入真实 Python `sqlite3` `SimpleValues` 库实证跨语言 UTF-8 分片；WP4 直接运行正式部署态 Mod 开展真机全链路验收（零临时垫片，通过后保留正式部署态不回滚）；本会话仅产出计划与进度文档 | ✅ 已确认 |

---

## 三、 工作包进度追踪表（`WP1` ~ `WP4`）

| 编号 | 工作包名称 | 计划涉及文件 | 状态 | 实测摘要（通过/失败/红线审计） | 完成日期 |
| :---: | :--- | :--- | :---: | :--- | :---: |
| **Plan** | 编制 M1Sub4 工作计划与进度文档 | `docs/M1/M1Sub4/M1Sub4工作计划.md`<br>`docs/M1/M1Sub4/M1Sub4工作进度.md` | ✅ 已完成 | 已完成 `D-01` ~ `D-06` 全分支访谈对齐，计划与进度两份文档已落盘待用户审阅确认 | 2026-11-27 |
| **WP1** | 离线真实 SQLite3 测试底座 + `Civ5AgentBridgeJson.lua`（`CAB_Json`）升级加固与专项单测 | `tests/run_m1sub4_tests.py`<br>`tests/m1sub4/db_stubs.lua`<br>`tests/m1sub4/test_external_io.lua`<br>`mod/Lua/Civ5AgentBridgeJson.lua` | ✅ 已完成 | 语法 `10/10`（`CAB_ExternalIO.lua` 待创建）+ 3 负向自检；用例 `7/7`（`T-00`~`T-06`）全绿、`--filter T-03` `1/1`；红线违规 `0`；复跑 M1Sub1~3（`40/40`、`38/38`、`29/29`）零回归 | 2026-11-28 |
| **WP2** | `mod/Lua/CAB_ExternalIO.lua` 全量实现（`X1`~`X8`）+ 跨语言 UTF-8 分片/会话/屏障/异常测试 | `mod/Lua/CAB_ExternalIO.lua`<br>`tests/m1sub4/db_stubs.lua`<br>`tests/m1sub4/test_external_io.lua` | ✅ 已完成 | 语法 `11/11`（0 待创建）+ 3 负向自检；用例 `16/16`（`T-00`~`T-15`）全绿、`--filter T-09` `1/1`；红线违规 `0`；真实 DB 审计打开 15 / 写 183 / 读 196；复跑 M1Sub1~3（`40/40`、`38/38`、`29/29`）零回归 | 2026-11-28 |
| **WP3** | 最终壳层合龙（`UI.lua` + `.modinfo` + `Core` 退役存根）+ 五模块全栈离线联调 + 四套件回归 + 正式部署 | `mod/Lua/Civ5AgentBridgeUI.lua`<br>`mod/Civ5AgentBridge.modinfo`<br>`mod/Lua/Civ5AgentBridgeCore.lua`<br>`tests/run_m1sub4_tests.py`<br>`tests/m1sub4/fullstack_stubs.lua`<br>`tests/m1sub4/test_fullstack.lua` | ✅ 已完成 | 语法 `13/13` + 3 负向自检；`.modinfo` 校验 `10/10`；用例 `23/23`（单测 `16/16` + 全栈 `7/7`，`--filter T-19` `1/1`）；红线违规 `0`；复跑 M1Sub1~3（`40/40`、`38/38`、`29/29`，合计 `130/130` 全绿）；正式部署 12/12 SHA256 一致且缓存库已清零 | 2026-11-28 |
| **WP4** | 正式部署态原生 BNW/IGE 真机全链路验收（不回滚）+ 产出《M1Sub4工作总结报告.md》 | `tests/m1sub4/live_smoke_client.py`<br>`docs/M1/M1Sub4/M1Sub4工作总结报告.md`<br>`docs/M1/M1Sub4/M1Sub4工作进度.md` | `[ ] 待执行` | — | — |

---

## 四、 待上级评审回写的文档偏离与增补台账

> 本台账记录相对 `docs/M1/` 三份上位文档的**加固细化项、新增诊断接口与正式合龙进度同步项**，严禁在 M1Sub4 期间直接修改上位文档，待 WP4 汇总至《M1Sub4工作总结报告.md》由上级 M1 评审验收后统一回写：

| 台账编号 | 涉及上位文档与章节 | 类型 | 内容摘要 | 对应决策 |
| :---: | :--- | :---: | :--- | :---: |
| **SYNC-M4-01** | `模块内部接口设计.md` §3.1 `CAB_Json` | 加固 / 增补 | 补充 `CAB_Json.NULL` 导出及保留旧全局函数兼容声明；登记 4 项生产边界加固（`Decode` 拦截尾随垃圾、严格 `\uXXXX` 四位十六进制与 UTF-16 代理对转 4 字节 UTF-8、`Encode` 循环引用与深度 `64` 防护、非法字面量与未转义控制字符拦截）。 | D-03 |
| **SYNC-M4-02** | `模块内部接口设计.md` §3.2~§3.6 & `模块设计说明.md` §3.4 / §4.2 | 加固 / 增补 | 1. 登记第 8 个纯只读诊断接口 `CAB_ExternalIO.GetRuntimeState() -> table`（零句柄与闭包泄露）；<br>2. 在 `PushTurnOverview` 中明确写入 `turn_overview_auto_seq` 原子发布序号屏障（位于分片落盘之后、`TURN_SYNCED` 心跳之前）；<br>3. 明确严格 `rpc_session_id` 水位线重置策略（仅非空新值重置，不盲猜旧客户端变小 `req_id`）及非对象 JSON 请求在 `CAB_ExternalIO` 层直接拦截回错；<br>4. 补充 UTF-8 分片边界回退的向前推进兜底守卫说明。 | D-04 |
| **SYNC-M4-03** | `模块设计说明.md` §2.1 & `模块设计进度.md` §二 决策项 1 / §三 `M1-S1` & `M1-S5` | 进度与装配同步 | 1. 闭环 §二 决策项 1：确认正式合龙 10 文件 `.modinfo` 清单（全 `import="1"`、正斜杠、移除 `Civ5AgentBridgeCore.lua`），源码保留 `Civ5AgentBridgeCore.lua` 极简合法 Lua 5.1 退役存根以保障前序回归脚本零改动全绿；<br>2. 登记 `Civ5AgentBridgeUI.lua` 纯转发壳层（自底向上守卫加载 6 模块、初始化成功才挂 4 项回调）；<br>3. 同步标记 `M1-S1` 与 `M1-S5` 全部验收通过，全模块 1 正式进入 `M1-S6` 收尾。 | D-01、D-02、D-05 |

---

## 五、 跨会话交接日志（Session Log）

### Session 0 — 2026-11-27（M1Sub4 与最终壳层合龙任务分解细化及 `/grill-me` 决策对齐会话）
* **完成工作**：
  1. 完整研读 `docs/M1/` 三份上位设计文档（含已同步的 `SYNC-01`~`SYNC-05`、`SYNC-M2-01`~`SYNC-M2-06` 与 `SYNC-M3-01`~`SYNC-M3-05`）、`M1Sub3` 工作计划/进度/总结报告、`CAB_Config.lua`、`CAB_Dispatcher.lua` 中全部 `CAB_ExternalIO` 调用点与依赖自检列表，以及现有壳层文件（`Civ5AgentBridgeJson.lua`、`Civ5AgentBridgeUI.lua/.xml`、`Civ5AgentBridgeLoader.lua/.xml`、`Civ5AgentBridgeCore.lua`、`Civ5AgentBridge.modinfo`、`scripts/deploy_mod.ps1`）与 `tests/exp06/sqlite_bridge.py`；
  2. 定位并核清 4 项关键工程依赖与风险点：① `run_m1sub1~3_tests.py` 均将 `mod/Lua/Civ5AgentBridgeCore.lua` 列为必填正样本（`True`），直接物理删除将破坏前序三套件回归；② 现有 `Civ5AgentBridgeJson.lua` 缺少 `CAB_Json` 命名空间，且存在尾随垃圾未拦截、`\uXXXX` 无十六进制/代理对校验、`Encode` 无循环引用保护 3 处缺口；③ `CAB_ExternalIO` 需严格落实 M1Sub3 WP5 真机实证暴露的 UTF-8 首字节对齐分片，且写入 `turn_overview_auto_seq` 与 `rpc_response_req_id` 原子发布屏障；④ 最终壳层合龙后 WP4 可直接在正式部署态开展真机验收，无需临时垫片与回滚；
  3. 经 `/grill-me` 逐分支访谈，与用户最终确认全部 6 项核心设计决策（`D-01` ~ `D-06`），并预登记 `SYNC-M4-01` ~ `SYNC-M4-03` 待回写台账；
  4. 创建 `docs/M1/M1Sub4/` 目录并编写完成《M1Sub4工作计划.md》与《M1Sub4工作进度.md》（严守 D-01 隔离红线，零触碰上位文档与任何代码/测试文件）。
* **当前卡点 / 交接给下一会话**：
  * **等待用户审阅确认《M1Sub4工作计划.md》**（若无修改意见，下一会话可直接启动 `WP1`）。
  * 下一会话启动 **`WP1`** 时的具体执行清单：
    1. 新建 `tests/run_m1sub4_tests.py`：对接本机 Python + `lupa.lua51` + Python 标准库 `sqlite3`，构建三阶段离线验收入口（阶段 1 覆盖全量 Mod 与 M1Sub4 测试 Lua 文件的 Lua 5.1 语法编译 + 3 项负向语法自检；阶段 2 注入真实 `sqlite3` 临时库桥接函数至 Lua 沙箱并运行桩测试，支持 `--filter`；阶段 3 输出红线与 DB 写序审计统计，返回标准退出码 `0/1/2`）；
    2. 新建 `tests/m1sub4/db_stubs.lua`：封装对接 Python 真实 `sqlite3` `SimpleValues(Name TEXT Primary Key, Value VARIANT)` 的 `Modding.OpenUserData` 桩，提供写操作顺序事件记录（供 WP2 验证红线 `I-03` 原子屏障顺序）、异常故障注入开关（模拟 `OpenUserData` 失败或 `SetValue`/`GetValue` 报错）及红线 `I-01` 禁令符号静态扫查辅助；
    3. 升级 `mod/Lua/Civ5AgentBridgeJson.lua`：100% 保留 `CAB_JsonEncode`、`CAB_JsonDecode`、`CAB_JSON_NULL` 全局兼容，新增 `CAB_Json = { Encode, Decode, NULL }`，并按 `D-03` 落地 4 项边界加固（尾随垃圾拦截、严格 `\uXXXX` 四位十六进制 + UTF-16 代理对转 4 字节 UTF-8、`Encode` 循环引用与深度上限 `64` 防护、非法字面量与未转义控制字符拦截）；
    4. 新建 `tests/m1sub4/test_external_io.lua` 编写 WP1 验收用例（`T-00` 静态洁净与全局符号校验 + `CAB_Json` 正向/负向/中文/代理对/循环引用/深度/旧全局兼容专项单测 + 真实 `sqlite3` 桩自检），跑通 `python Civ5AgentBridge/tests/run_m1sub4_tests.py` 并复跑 `run_m1sub1~3_tests.py` 全绿后，更新本进度表交接至 `WP2`。

### Session 1 — 2026-11-28（WP1：离线真实 SQLite3 测试底座 + `CAB_Json` 升级加固与专项单测）
* **完成工作**：
  1. **升级加固 `mod/Lua/Civ5AgentBridgeJson.lua`（`D-03`）**：
     * 100% 保留既有全局符号 `CAB_JSON_NULL`、`CAB_JsonEncode`、`CAB_JsonDecode`，新增标准命名空间 `CAB_Json = { Encode = CAB_JsonEncode, Decode = CAB_JsonDecode, NULL = CAB_JSON_NULL }`，无多余全局泄露；
     * 落地全部 4 项生产边界加固：① `Decode` 拦截根值后非法尾随字符并增加最大递归深度限制（`MAX_DECODE_DEPTH = 64`）；② 严格校验 `\uXXXX` 四位十六进制与 UTF-16 代理对转 4 字节 UTF-8（含 `U+10000`~`U+10FFFF` 边界），拦截孤立高/低代理、非法转义符及未转义控制字符（`< 0x20`）；③ `Encode` 增加循环引用检测与最大递归深度限制（`MAX_ENCODE_DEPTH = 64`），退出表节点清理 `visiting` 以放行合法非环 DAG 共享子表，且 `CAB_EscapeString` 采用 locale 无关字节类 `[%z\001-\031\\"]` 支持 `\0` 转 `\u0000`；④ 严格 RFC 8259 数字与 `true`/`false`/`null` 边界分隔符校验，维持 `NaN`/`±inf` → `"null"` 与 `__is_object` 契约。
  2. **新建跨语言真实 SQLite3 测试底座（`tests/run_m1sub4_tests.py` + `tests/m1sub4/db_stubs.lua`）**：
     * `SqliteTestBackend` 在 `tempfile.TemporaryDirectory` 中建真实 `SimpleValues(Name TEXT Primary Key, Value VARIANT)` 库，通过 Lua 256 项查表 Hex 原始字节桥 + SQLite `CAST(? AS TEXT)` 完整复现 Civ5 原生 C++ 字节存储，实证写入残缺 UTF-8 字节后 Python 默认 `text_factory=str` 真实抛出 `sqlite3.OperationalError` 而 `text_factory=bytes` 无损读回；
     * 提供 `S.db.writeLog` 写序审计（`writeKeys`/`firstWriteIndex`/`lastWriteIndex`）、`S.faults` 故障注入开关（`openFail`/`openThrow`/`setThrowOnKey`/`setThrowOnCallIndex`/`getThrowOnKey`/`getThrowAll`）、`S.pyDb` 跨语言验真封装、`__py_json_loads_check` 交叉校验以及红线 `I-01` 静态扫查与动态写接口陷阱守卫。
  3. **新建 `tests/m1sub4/test_external_io.lua` 并完成四套件回归**：
     * 编写 `T-00` ~ `T-06` 共 7 组 WP1 专项用例 + `FW-01` 收尾总检；
     * 实测 `python Civ5AgentBridge/tests/run_m1sub4_tests.py` 语法检查 `10/10`（`CAB_ExternalIO.lua` 待创建）+ 3 负向自检全过，桩测试 `7/7` 全绿（`--filter T-03` `1/1`），红线违规 `0`；
     * 复跑 `run_m1sub1_tests.py`（`40/40`）、`run_m1sub2_tests.py`（`38/38`）、`run_m1sub3_tests.py`（`29/29`）全部退出码 `0`，零回归且严守 `D-01` 白名单隔离红线。
* **当前卡点 / 交接给下一会话**：
  * 无卡点，可直接启动 **`WP2`**：
    1. 新建 `mod/Lua/CAB_ExternalIO.lua`：采用守卫式加载 `CAB_Config` 与 `Civ5AgentBridgeJson`，严格导出唯一全局表 `CAB_ExternalIO` 与精确 8 项公开接口（`X1` `Initialize`、`X2` `WritePayload`、`X3` `ReadPayload`、`X4` `PushTurnOverview`、`X5` `WriteHeartbeat`、`X6` `SendRpcResponse`、`X7` `PollIncomingRequest`、`X8` `GetRuntimeState`），落实 UTF-8 首字节边界对齐 3KB 分片（含向前推进兜底守卫）、原子发布屏障顺序（`I-03`）、水位线对齐与严格非空新 `rpc_session_id` 重置（`I-04`）及全异常隔离（`I-05`）；
    2. 扩充 `tests/m1sub4/db_stubs.lua`（按需）与 `tests/m1sub4/test_external_io.lua`：覆盖 `CAB_ExternalIO` 静态红线扫描与精确 8 接口校验、0B/2999B/3000B/3001B/32KB+ 简繁中文与 4 字节表情跨语言真实 SQLite3 分片互操作（Python `readTextStrict` 零 `OperationalError` + `readChunkedBytes` 无损还原 + 反向 `ReadPayload`）、原子屏障写序审计、重载防重放与会话重置、坏 JSON/非对象/回调异常/DB 异常隔离及 `GetRuntimeState()` 零引用泄露；
    3. 跑通 `run_m1sub1~4_tests.py` 全部退出码 `0` 后更新本进度表交接至 `WP3`。

### Session 2 — 2026-11-28（WP2：`mod/Lua/CAB_ExternalIO.lua` 全量实现与跨语言 SQLite3 协议测试）
* **完成工作**：
  1. **新建外部交互防腐层 `mod/Lua/CAB_ExternalIO.lua`（`X1`~`X8`）**：
     * 顶部采用守卫式按需加载 `CAB_Config` 与 `Civ5AgentBridgeJson`，严格仅导出唯一全局表 `CAB_ExternalIO` 与精确 8 项公开函数（`Initialize`、`WritePayload`、`ReadPayload`、`PushTurnOverview`、`WriteHeartbeat`、`SendRpcResponse`、`PollIncomingRequest`、`GetRuntimeState`），静态红线 `I-01` 违规为 `0`；
     * 落地 `WritePayload` UTF-8 首字节边界对齐分片（`CHUNK_SIZE_BYTES` 默认 `3000`、最小兜底 `4`，续字节 `0x80..0xBF` 最多回退 3 字节并内置 `endIdx < startIdx` 向前推进防死循环守卫 `R-02`）；兼容原生 Civ5 C++ `SetValue` 成功时返回 `nil` 的特性；`ReadPayload` 遇分片缺失安全返回 `nil` 不静默拼残片；
     * 严格落实 `I-03` 原子发布屏障写序（`rpc_response` 分片先于 `rpc_response_req_id`、`turn_overview_auto` 先于 `turn_overview_auto_seq` 先于 `bridge_heartbeat("TURN_SYNCED")`），前置失败绝不推进屏障；`SendRpcResponse` 遇循环引用表自动降级编码回写 `ok=false` 错返；
     * 严格落实 `I-04`/`I-05`/`I-06`：`Initialize` 校准库内既有 `rpc_request_req_id` 与 `rpc_session_id` 防重载重放；`PollIncomingRequest` 空轮询严格仅 2 次轻量 `GetValue`，通过 `normalizeSessionId` 兼容 SQLite `Value VARIANT` 数值亲和性（纯数字会话号亦正确切换重置），绝不对旧客户端或空 session 盲猜重置；精确拦截 `null`/标量/非空数组/空数组 `[]` 等非对象 JSON 请求，对坏 JSON 与回调抛错均经 `pcall` 隔离回错且不重试；`GetRuntimeState()` 仅返回 6 项基础标量浅拷贝表，零句柄/闭包泄露。
  2. **扩充跨语言 SQLite3 测试底座与 WP2 验收用例（`T-07`~`T-15`）**：
     * 扩充 `tests/m1sub4/db_stubs.lua`：新增 `S.faults.setReturnNil`（模拟原生 Civ5 `SetValue` 无返回值）、`S.faults.setReturnFalseOnKey`、`S.pyDb.sendRpcRequest` 外部客户端协议写入助手及 `S.reloadExternalIO()` 用例级状态隔离；
     * 在 `tests/m1sub4/test_external_io.lua` 新增 `T-07`~`T-15` 共 9 组专项用例，实证 0B/2999B/3000B/3001B/36KB+、3 字节简繁中文与 4 字节表情逐偏移压 3000B 边界下 Python 默认 `text_factory=str` **0 次 `OperationalError`** 且 `text_factory=bytes` 与反向 `ReadPayload` 100% 字节无损。
  3. **四套件全量回归与白名单审计**：
     * `python Civ5AgentBridge/tests/run_m1sub4_tests.py`：语法检查 `11/11`（待创建 `0`）+ 3 负向自检，桩测试 `16/16` 全绿（`--filter T-09` `1/1`），红线违规 `0`，真实 DB 打开 15 / 写 183 / 读 196；
     * 复跑 `run_m1sub1_tests.py`（`40/40`）、`run_m1sub2_tests.py`（`38/38`）、`run_m1sub3_tests.py`（`29/29`）全部退出码 `0`，合计 `123/123` 零回归；严守 `D-01` 白名单隔离红线。
* **当前卡点 / 交接给下一会话**：
  * 无卡点，可直接启动 **`WP3`**（最终壳层合龙 + 五模块全栈离线联调 + 四套件回归 + 正式部署）：
    1. 精简重构 `mod/Lua/Civ5AgentBridgeUI.lua` 为纯事件挂载壳层（自底向上守卫式按需加载 6 个 Lua 模块：`CAB_Config` → `Civ5AgentBridgeJson` → `CAB_ExternalIO` → `CAB_InfoCollector` → `CAB_TaskExecutor` → `CAB_Dispatcher`；仅 `CAB_Dispatcher.Initialize(CAB_UpdateStatusLabel)` 返回 `true` 时注册 4 项回调且带 `s_HooksRegistered` 防重入，失败则显示 `"Agent Bridge: Init Failed"`）；
    2. 正式更新 `mod/Civ5AgentBridge.modinfo`：登记全部 10 个正式 VFS 文件（全 `import="1"`、正斜杠 `/`、移除 `Lua/Civ5AgentBridgeCore.lua`），保持 `AffectsSavedGames=0` 与空壳 `Lua/Civ5AgentBridgeLoader.lua` 入口；
    3. 按 `D-02` 将 `mod/Lua/Civ5AgentBridgeCore.lua` 替换为极简合法 Lua 5.1 退役说明存根（清除全部旧单体代码与 `AirRaidCore`/`CanMoveOrAttackInto` 引用）；
    4. 在 `tests/run_m1sub4_tests.py` 与 `tests/m1sub4/*` 中新增 `.modinfo` XML 结构自动校验与五模块 + UI 壳层真实 SQLite3 全栈端到端联调用例，复跑四套件全部退出码 `0` 后执行 `scripts/deploy_mod.ps1 -ForceCopy -ClearCache` 完成正式镜像部署与缓存清理。

### Session 3 — 2026-11-28（WP3：最终壳层合龙 + 五模块全栈离线联调 + 四套件回归 + 正式部署）
* **完成工作**：
  1. **最终壳层合龙与旧单体退役（`D-02` / `D-05` / `I-01` / `R-04`）**：
     * 精简重构 `mod/Lua/Civ5AgentBridgeUI.lua` 为纯事件转发壳层（零全局变量导出、红线 `I-01` 违规为 `0`）：顶部自底向上守卫式按需加载 6 个正式模块（`CAB_Config` → `Civ5AgentBridgeJson` → `CAB_ExternalIO` → `CAB_InfoCollector` → `CAB_TaskExecutor` → `CAB_Dispatcher`）；经 `pcall(CAB_Dispatcher.Initialize, CAB_UpdateStatusLabel)` 引导启动，仅当返回 `true` 时挂载 4 项宿主回调（按钮点击、回合开始、回合结束、`ContextPtr:SetUpdate`）并以 `local s_HooksRegistered` 防重入；初始化失败时刷新状态栏为 `"Agent Bridge: Init Failed"` 且绝不挂载帧循环；
     * 正式更新 `mod/Civ5AgentBridge.modinfo`：登记全部 10 个正式 VFS 文件（全 `import="1"`、正斜杠 `/`、移除 `Lua/Civ5AgentBridgeCore.lua`），保持 UUID、BNW `1.0.3.279` 依赖、`AffectsSavedGames=0` 与唯一空壳 `Lua/Civ5AgentBridgeLoader.lua` 入口；
     * 按 `D-02` 将 `mod/Lua/Civ5AgentBridgeCore.lua` 替换为极简纯注释合法 Lua 5.1 退役存根，清除旧单体代码与遗留禁令符号，保障前序回归脚本零改动全绿。
  2. **升级 `tests/run_m1sub4_tests.py` 并新建五模块全栈离线联调测试套件**：
     * 将 `tests/run_m1sub4_tests.py` 升级为四阶段自动化验收入口：阶段 1 覆盖全量 13 个 Lua 文件编译 + 3 负向自检；阶段 2 新增 `.modinfo` XML 结构与退役存根 10 项自动校验（`A-06`）；阶段 3 保留 WP1~WP2 隔离单测（`T-00`~`T-15`）；阶段 4 启动独立 `lupa.lua51` 沙箱与真实 `sqlite3` 后端执行五模块全栈联调（`T-16`~`T-22`）；
     * 新建 `tests/m1sub4/fullstack_stubs.lua`（只读复用 `tests/m1sub3/engine_stubs.lua` 零修改前序测试，叠加真实 SQLite3 `Modding.OpenUserData` 与 Civ5 UI 宿主桩 `Controls`/`Mouse`/`Events`/`ContextPtr`）与 `tests/m1sub4/test_fullstack.lua`（覆盖静态红线审计、冷启动 6 模块顺序与 4 回调挂载、初始化失败降级、繁/简体中文 `get_policy_options` 与 36KB+ `test_large_payload` 跨语言分片无损闭环、`execute_unit_action` + `purchase_city_plot` 两段式跨帧异步结算、坏 JSON/非对象隔离与会话重启重置、手动同步序号隔离 `S-05`、`end_turn` → AI 门控 → `ActivePlayerTurnStart` 跨回合自动推送）。
  3. **四套件全量回归、正式镜像部署与 D-01 白名单审计**：
     * `python Civ5AgentBridge/tests/run_m1sub4_tests.py`：语法 `13/13` + 3 负向自检、`.modinfo` 校验 `10/10`、桩测试 `23/23`（单测 `16/16` + 全栈 `7/7`，`--filter T-19` `1/1`），两套沙箱红线违规与未实现方法均为 `0`（单测 DB 打开 15 / 写 183 / 读 196；全栈 DB 打开 8 / 写 86 / 读 57）；
     * 复跑前序三套件零回归：`run_m1sub1_tests.py`（`40/40`）、`run_m1sub2_tests.py`（`38/38`）、`run_m1sub3_tests.py`（`29/29`），四套件合计 `130/130` 退出码均为 `0`；
     * 核验游戏未运行后执行 `scripts/deploy_mod.ps1 -ForceCopy -ClearCache`，逐文件 SHA256 核验 `Civ5AgentBridge/mod/` 与 `MODS/Civ5AgentBridge/` 全部 12/12 文件一致（`mismatch=0`），`cache/Civ5*.db` 残留为 `0`；`git status --short` 确认 100% 落在 M1Sub4 白名单内。
* **当前卡点 / 交接给下一会话**：
  * 无卡点，正式部署态 `MODS/Civ5AgentBridge/` 已就绪，下一会话可直接启动 **`WP4`**（正式部署态原生 BNW/IGE 真机全链路实证验收 + 结项交付）：
    1. 新建 `tests/m1sub4/live_smoke_client.py`：落地 `sqlite3` `text_factory = bytes` 拼片解码与 `rpc_session_id` 握手协议，直接对接正式部署的 `MODS/Civ5AgentBridge/`（零临时垫片、零修改 `mod/`）；
    2. 配合用户启动原生《文明5：BNW v1.0.3.279》+ IGE 进入单人局，依次实证实机验收清单（空壳加载与右上角状态栏、首帧自动推送 `turn_overview_auto` + `turn_overview_auto_seq` + 心跳、繁/简体中文大包与 `test_large_payload` 32KB+ 分片零 UTF-8 错、`rpc_session_id` 会话重置、只读查询/写动作跨帧结算/坏 JSON 错返隔离/手动同步不递增 `turn_seq`/AI 门控与 `end_turn` 推进 `Turn N → Turn N+1` 自动推送）并核查 `Logs/Lua.log` 全程零错误；
    3. 保留正式部署态不回滚，复跑四套件总回归与 `git status` 白名单审计；产出《`M1Sub4工作总结报告.md`》（含 `A-01`~`A-10` 逐项对账与 `SYNC-M4-01`~`SYNC-M4-03` 上位文档回写建议书）并闭环更新本进度表。
