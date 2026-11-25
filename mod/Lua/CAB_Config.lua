-- =============================================================================
-- 文件：Lua/CAB_Config.lua
-- 做什么：模块 1（游戏端纯 Lua 桥接 Mod）的全局配置表 CAB_Config。
--         集中存放全部可调阈值：IPC 数据库标识、分片大小、轮询与心跳间隔、动作结算等待、扫描半径、
--         调试日志开关。全部键都是静态字面量。
-- 为什么：设计红线要求“全部可调阈值集中收敛于 CAB_Config，禁止在业务子模块散落硬编码”
--         （《模块设计说明.md》§1.2 第 4 条）。改一个阈值只改这一处，各子模块自动生效。
--
-- 使用约定：
--   * 只读：各子模块只读取，任何代码都不得在运行时写入本表。
--   * 加载：纯静态表，没有 include、没有函数、没有引擎调用，先于其他子模块被加载
--           （登记与加载顺序属 M1-S5：import="1"，先 CAB_Config 再 CAB_InfoCollector）。
--   * 被谁引用：
--       - CAB_InfoCollector（信息收集）：DEFAULT_SCAN_RADIUS、MAX_SCAN_RADIUS
--       - CAB_TaskExecutor（任务执行）：*_SETTLE_SEC、MAX_SETTLE_TIMEOUT_SEC、DELTA_REVEAL_SCAN_RADIUS
--       - CAB_Dispatcher（调度）：POLL_INTERVAL_SEC、HEARTBEAT_INTERVAL_SEC、ENABLE_DEBUG_LOG
--       - CAB_ExternalIO（外部交互）：DB_NAME、DB_VERSION、CHUNK_SIZE_BYTES
--     其中后三者属后续工作包，这里只是列出归属。
--
-- 键值出处：
--   前 11 个键的键名、类型、默认值、用途，逐项照《模块设计说明.md》§4.1；
--   MAX_SCAN_RADIUS 是子模块 1 工作计划的默认取舍 D-06（《SubM1工作计划.md》§二）。
-- =============================================================================

CAB_Config = {
    -- IPC 数据库名与版本：对应 ModUserData/Civ5AgentBridge-1.db 的文件名
    DB_NAME = "Civ5AgentBridge",
    DB_VERSION = 1,

    -- 单字段自动分片的字节阈值：超过它就分片写入，规避定长缓冲区截断风险
    CHUNK_SIZE_BYTES = 3000,

    -- 空闲态轮询外部新请求的间隔（秒）：约 200ms，兼顾低延迟与帧率
    POLL_INTERVAL_SEC = 0.20,

    -- 空闲态刷新 bridge_heartbeat 的间隔（秒）：供外部监控游戏端是否存活
    HEARTBEAT_INTERVAL_SEC = 2.00,

    -- 单位移动/攻击动作下发后的最小结算等待（秒）：给异步动画与揭盲留出时间
    DEFAULT_UNIT_SETTLE_SEC = 0.35,

    -- 买地动作（Network.SendCityBuyPlot）后的短结算等待（秒）
    PLOT_BUY_SETTLE_SEC = 0.10,

    -- 战斗/移动动画等待的硬超时上限（秒）：防止异常卡动画让 IPC 永久挂起
    MAX_SETTLE_TIMEOUT_SEC = 1.50,

    -- 查询单位局部战术网格时的默认六边形半径（格）
    DEFAULT_SCAN_RADIUS = 3,

    -- 统计单步动作新揭开迷雾地块数时的周边采样半径（格）：覆盖侦察兵登高望远的视野
    DELTA_REVEAL_SCAN_RADIUS = 5,

    -- 扫描半径的上限（格）：外部传入超大半径时把扫描范围钳制到这里，
    -- 防止一次查询遍历上百万格卡死游戏（D-06）
    MAX_SCAN_RADIUS = 8,

    -- 是否向 Logs/Lua.log 输出关键状态流转与异常诊断日志
    ENABLE_DEBUG_LOG = true,
}
