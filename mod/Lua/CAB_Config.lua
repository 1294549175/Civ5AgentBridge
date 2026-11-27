-- =============================================================================
-- 文件：mod/Lua/CAB_Config.lua
-- 职责：模块 1（游戏端纯 Lua 桥接 Mod）的全局静态只读配置表 CAB_Config。
--       集中收敛全部可调阈值：SQLite IPC 标识、分片字节上限、轮询/心跳间隔、
--       异步动画结算时长、视野扫描半径及调试日志开关。
-- 依赖：零依赖（禁止任何 include、函数定义或引擎 API 调用）。
-- 对外契约：仅导出唯一全局变量 CAB_Config（共 12 个静态字面量键，只读）。
-- 接口依据：
--   * 前 11 键的键名、类型与默认值严格对齐《docs/M1/模块设计说明.md》§4.1；
--   * MAX_SCAN_RADIUS = 8 按《docs/M1/M1Sub1/M1Sub1工作计划.md》§4.1 及决策 D-06 增补。
--
-- 子模块使用归属：
--   * CAB_InfoCollector（信息收集）：DEFAULT_SCAN_RADIUS、DELTA_REVEAL_SCAN_RADIUS、
--                                    MAX_SCAN_RADIUS、ENABLE_DEBUG_LOG
--   * CAB_TaskExecutor （任务执行）：DEFAULT_UNIT_SETTLE_SEC、PLOT_BUY_SETTLE_SEC、
--                                    MAX_SETTLE_TIMEOUT_SEC
--   * CAB_Dispatcher   （调度控制）：POLL_INTERVAL_SEC、HEARTBEAT_INTERVAL_SEC、ENABLE_DEBUG_LOG
--   * CAB_ExternalIO   （外部交互）：DB_NAME、DB_VERSION、CHUNK_SIZE_BYTES
-- =============================================================================

CAB_Config = {
    -- SQLite ModUserData 数据库名与版本（对应 ModUserData/Civ5AgentBridge-1.db）
    DB_NAME = "Civ5AgentBridge",
    DB_VERSION = 1,

    -- 单字段自动分片字节阈值（规避引擎底层定长缓冲区截断风险）
    CHUNK_SIZE_BYTES = 3000,

    -- 空闲态轮询 SQLite 新请求的节流周期（秒）
    POLL_INTERVAL_SEC = 0.20,

    -- 空闲态刷新 bridge_heartbeat 的周期（秒）
    HEARTBEAT_INTERVAL_SEC = 2.00,

    -- 单位移动/攻击动作下发后的最小结算等待（秒）
    DEFAULT_UNIT_SETTLE_SEC = 0.35,

    -- 购买地块（Network.SendCityBuyPlot）后的短结算等待（秒）
    PLOT_BUY_SETTLE_SEC = 0.10,

    -- 单位/战斗动画结算等待的硬超时上限（秒）
    MAX_SETTLE_TIMEOUT_SEC = 1.50,

    -- 查询单位局部战术网格时的默认六边形半径（格）
    DEFAULT_SCAN_RADIUS = 3,

    -- 统计单步动作新揭盲地块数时的默认采样半径（格）
    DELTA_REVEAL_SCAN_RADIUS = 5,

    -- 外部传入扫描半径的硬上限钳制值（格，防止超大半径卡死游戏，决策 D-06）
    MAX_SCAN_RADIUS = 8,

    -- 是否向 Logs/Lua.log 输出调试与异常诊断日志
    ENABLE_DEBUG_LOG = true,
}
