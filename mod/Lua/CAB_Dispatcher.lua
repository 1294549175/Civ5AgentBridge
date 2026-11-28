-- =============================================================================
-- 文件：mod/Lua/CAB_Dispatcher.lua
-- 职责：模块 1（游戏端纯 Lua 桥接 Mod）——子模块 3：调度控制子模块（CAB_Dispatcher）。
--       作为模块 1 的纯状态机与事件路由枢纽，统一管理：
--         1. 下游子模块（CAB_Config / CAB_Collector / CAB_Executor / CAB_ExternalIO）
--            的依赖自检与初始化编排；
--         2. 玩家回合开始/结束生命周期事件与手动同步护栏；
--         3. 外部 SQLite IPC 20 项 RPC 方法路由（原 14 项 + WP5 科研/政策/晋升 6 项）、
--            非活动回合白名单门控与信封保真映射（WP2 / WP5）；
--         4. ContextPtr:SetUpdate 驱动的 8 类异步动作帧结算、跨回合抢占刷写防死锁
--            与空闲态轮询/心跳节流（WP3 / WP5）。
--
-- 依赖：采用守卫式按需 include（决策 D-02），防止 Civ5 VFS 重复执行重置下游 local 状态，
--       且天然兼容测试阶段预注入 CAB_ExternalIO 契约桩与后续正式装配零改代码：
--         if CAB_Config == nil then include("CAB_Config") end
--         if CAB_Collector == nil then include("CAB_InfoCollector") end
--         if CAB_Executor == nil then include("CAB_TaskExecutor") end
--         if CAB_ExternalIO == nil then include("CAB_ExternalIO") end
--
-- 对外契约：
--   * 仅导出唯一全局变量 CAB_Dispatcher（精确 7 个公开函数 D1 ~ D7）：
--       D1: Initialize(uiStatusCallback) -> boolean
--       D2: OnActivePlayerTurnStart() -> nil
--       D3: OnActivePlayerTurnEnd() -> nil
--       D4: OnManualSyncClicked() -> nil
--       D5: OnExternalRequestReceived(reqObj) -> nil   (WP2 已实现全量 14 项 IPC 路由与门控)
--       D6: OnFrameUpdate(deltaTime) -> nil            (WP3 已实现 5 类异步帧结算与节流轮询/心跳)
--       D7: GetRuntimeState() -> table
--   * 全部内部状态变量、路由分发表与校验辅助函数一律声明为 local。
--
-- 安全红线（《docs/M1/M1Sub3/M1Sub3工作计划.md》§2.2）：
--   * S-01 零越层直调引擎写接口与 SQLite/JSON：全部采集委托 CAB_Collector，
--         全部写动作委托 CAB_Executor，全部序列化分片与数据库交互委托 CAB_ExternalIO；
--   * S-02 非活动回合严格白名单门控（D-03）；
--   * S-03 单工异步结算互斥与零丢回执（D-05）；
--   * S-04 状态机异常自愈（pcall 隔离下游与回调异常，防永久卡锁）；
--   * S-05 手动同步防脏写与序号隔离（D-06：合法导出不递增 s_TurnEventSeq）；
--   * S-06 帧时钟净化与单帧尖峰防护。
-- =============================================================================

if CAB_Config == nil then
    include("CAB_Config")
end
if CAB_Collector == nil then
    include("CAB_InfoCollector")
end
if CAB_Executor == nil then
    include("CAB_TaskExecutor")
end
if CAB_ExternalIO == nil then
    include("CAB_ExternalIO")
end

CAB_Dispatcher = {}

-- -----------------------------------------------------------------------------
-- 第 1 节：内部私有状态变量（严格对齐《模块设计说明.md》§4.2，全部 local）
-- -----------------------------------------------------------------------------

local s_Initialized = false
local s_BridgeState = "UNINITIALIZED"
local s_PollAccumSec = 0.0
local s_HeartbeatAccumSec = 0.0
local s_TurnEventSeq = 0
local s_PendingSettlement = nil
local s_UiStatusCallback = nil

-- 锁入 AI_TURN_LOCKED 时的来源追踪（防止 end_turn / TurnEnd 刚锁入、引擎尚未将
-- IsTurnActive() 置 false 的窗口期内被交叉对齐误解锁，同时支持读档/IGE 切人自校准）
local s_LockedTurnNumber = nil
local s_LockedPlayerID = nil
local s_TurnLockObservedInactive = false

-- 非活动回合（AI_TURN_LOCKED / not IsTurnActive）放行的 10 项零选区副作用只读/诊断方法（D-03 / D-08 / S-02）
local AI_TURN_READONLY_WHITELIST = {
    ping = true,
    test_large_payload = true,
    get_turn_overview = true,
    get_empire_economy = true,
    get_visibility_summary = true,
    get_city_detail = true,
    get_end_turn_status = true,
    get_research_options = true,
    get_policy_options = true,
    get_unit_promotions = true,
}

-- test_large_payload 默认与安全上限字节数（防超大载荷引发 Lua 5.1 内存暴涨）
local DEFAULT_LARGE_PAYLOAD_BYTES = 32768
local MAX_LARGE_PAYLOAD_BYTES = 524288

-- 异步结算单帧最大步进上限（S-06：防窗口切出/卡顿单帧跨过 1.50s 硬超时）与浮点累加容差
local MAX_SETTLE_STEP_SEC = 0.50
local TIME_EPSILON = 1e-9

-- -----------------------------------------------------------------------------
-- 第 2 节：下游依赖契约清单与基础安全辅助（全部 local）
-- -----------------------------------------------------------------------------

-- CAB_Config 必需配置键及其校验规则（>0 正数 / >=0 非负数 / boolean）
local REQUIRED_CONFIG_SPEC = {
    { key = "POLL_INTERVAL_SEC",       kind = "pos_number" },
    { key = "HEARTBEAT_INTERVAL_SEC",  kind = "pos_number" },
    { key = "DEFAULT_UNIT_SETTLE_SEC", kind = "nonneg_number" },
    { key = "PLOT_BUY_SETTLE_SEC",     kind = "nonneg_number" },
    { key = "MAX_SETTLE_TIMEOUT_SEC",  kind = "pos_number" },
    { key = "ENABLE_DEBUG_LOG",        kind = "boolean" },
}

-- CAB_Collector 10 个对外只读主查询接口（原 7 项 + WP5 科研/政策/晋升 3 项）
local REQUIRED_COLLECTOR_FUNCS = {
    "GetEmpireEconomy",
    "GetVisibilitySummary",
    "CaptureRevealedPlotsSet",
    "GetEndTurnStatus",
    "BuildTurnOverview",
    "BuildUnitContextAndCandidates",
    "GetCityDetail",
    "GetResearchOptions",
    "GetPolicyOptions",
    "GetUnitPromotions",
}

-- CAB_Executor 全部 12 个公开接口（原 9 项 + WP5 科研/政策/晋升 3 项）
local REQUIRED_EXECUTOR_FUNCS = {
    "Initialize",
    "StartUnitAction",
    "StartCityRangeAttack",
    "PurchaseCityItem",
    "SetCityProduction",
    "PurchaseCityPlot",
    "ExecuteEndTurn",
    "IsSettlementBusy",
    "FinalizeActionSettlement",
    "SetResearchTech",
    "AdoptPolicyOrBranch",
    "PromoteUnit",
}

-- CAB_ExternalIO 全部 7 个公开契约接口（《模块内部接口设计.md》§三）
local REQUIRED_EXTERNAL_IO_FUNCS = {
    "Initialize",
    "WritePayload",
    "ReadPayload",
    "PushTurnOverview",
    "WriteHeartbeat",
    "SendRpcResponse",
    "PollIncomingRequest",
}

-- -----------------------------------------------------------------------------
-- 函数：debugLog(msg) / errorLog(msg)
-- 做什么：输出带 [CAB_Dispatcher] 前缀的调试/错误诊断日志。
-- 为什么：调试日志遵循 CAB_Config.ENABLE_DEBUG_LOG 开关，关键错误与异常自愈始终留痕，
--         且在 CAB_Config 未就绪时零异常。
-- 输入：msg（日志文本）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function debugLog(msg)
    if type(CAB_Config) == "table" and CAB_Config.ENABLE_DEBUG_LOG == true and print ~= nil then
        print("[CAB_Dispatcher] " .. tostring(msg))
    end
end

local function errorLog(msg)
    if print ~= nil then
        print("[CAB_Dispatcher][ERROR] " .. tostring(msg))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：isFiniteNumber(v) / isFiniteInteger(v)
-- 做什么：校验数值为有限实数或有限整数（过滤 nil、非数字、NaN 与 +/-inf）。
-- 为什么：在 Lua 5.1 中 NaN 与 inf 参与比较可能引发隐蔽逻辑漏洞，须统一拦截。
-- 输入：v（任意 Lua 值）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isFiniteInteger(v)
    return isFiniteNumber(v) and v == math.floor(v)
end

-- -----------------------------------------------------------------------------
-- 函数：safeNotifyUi(statusText)
-- 做什么：通过 pcall 安全调用外部注入的 UI 状态栏刷新委托。
-- 为什么：遵循 S-04，UI 控件回调若因界面卸载或脚本报错抛出异常，绝不允许中断调度状态机。
-- 输入：statusText（展示在右上角状态栏的简短文本）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function safeNotifyUi(statusText)
    if type(s_UiStatusCallback) ~= "function" then
        return
    end
    local ok, err = pcall(s_UiStatusCallback, tostring(statusText or ""))
    if not ok then
        debugLog("UI status callback error (ignored): " .. tostring(err))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：getGameTurn() / getActivePlayerID()
-- 做什么：安全读取当前游戏回合号与激活玩家 ID。
-- 为什么：防止在引擎全局表尚未就绪或测试异常桩状态下抛出未捕获错误。
-- 输入：无。
-- 输出：number（失败时分别回退为 0 与 -1）。
-- -----------------------------------------------------------------------------
local function getGameTurn()
    if Game == nil or type(Game.GetGameTurn) ~= "function" then
        return 0
    end
    local ok, turn = pcall(Game.GetGameTurn)
    if ok and isFiniteInteger(turn) then
        return turn
    end
    return 0
end

local function getActivePlayerID()
    if Game == nil or type(Game.GetActivePlayer) ~= "function" then
        return -1
    end
    local ok, pid = pcall(Game.GetActivePlayer)
    if ok and isFiniteInteger(pid) then
        return pid
    end
    return -1
end

-- -----------------------------------------------------------------------------
-- 函数：isActivePlayerTurnNow()
-- 做什么：实时向引擎核验当前激活玩家是否存在、存活且正处于活动回合。
-- 为什么：既用于 Initialize 双态分流，也在事件入口交叉对齐读档/IGE 切人导致的状态失步。
-- 输入：无。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function isActivePlayerTurnNow()
    local activePlayerID = getActivePlayerID()
    if activePlayerID < 0 or Players == nil then
        return false
    end
    local ok, isActive = pcall(function()
        local pPlayer = Players[activePlayerID]
        if pPlayer == nil then
            return false
        end
        if pPlayer.IsAlive == nil or pPlayer:IsAlive() ~= true then
            return false
        end
        if pPlayer.IsTurnActive == nil or pPlayer:IsTurnActive() ~= true then
            return false
        end
        return true
    end)
    return ok and isActive == true
end

-- -----------------------------------------------------------------------------
-- 函数：safeSendRpcResponse(reqId, ok, dataTable, errMsg, forceChunked)
-- 做什么：在 pcall 保护下向 CAB_ExternalIO 写回 RPC 响应信封。
-- 为什么：确保响应写回阶段发生外部 IO 故障时不会向上抛出未捕获异常导致状态机卡死。
-- 输入：与 CAB_ExternalIO.SendRpcResponse 签名完全一致。
-- 输出：boolean（是否写回成功）。
-- -----------------------------------------------------------------------------
local function safeSendRpcResponse(reqId, ok, dataTable, errMsg, forceChunked)
    if type(CAB_ExternalIO) ~= "table" or type(CAB_ExternalIO.SendRpcResponse) ~= "function" then
        errorLog("Cannot send RPC response: CAB_ExternalIO.SendRpcResponse unavailable")
        return false
    end
    local okCall, sent = pcall(
        CAB_ExternalIO.SendRpcResponse,
        reqId,
        ok == true,
        dataTable,
        errMsg,
        forceChunked == true
    )
    if not okCall then
        errorLog("CAB_ExternalIO.SendRpcResponse threw error: " .. tostring(sent))
        return false
    end
    return sent ~= false
end

-- -----------------------------------------------------------------------------
-- 函数：safeWriteHeartbeat(statusStr)
-- 做什么：在 pcall 保护下写入当前 s_TurnEventSeq 对应的桥接心跳。
-- 为什么：隔离外部 IO 故障并统一传递本模块维护的 s_TurnEventSeq。
-- 输入：statusStr（心跳状态枚举字符串，如 "IDLE" / "AI_TURN_PROCESSING"）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function safeWriteHeartbeat(statusStr)
    if type(CAB_ExternalIO) ~= "table" or type(CAB_ExternalIO.WriteHeartbeat) ~= "function" then
        errorLog("Cannot write heartbeat: CAB_ExternalIO.WriteHeartbeat unavailable")
        return false
    end
    local okCall, wrote = pcall(CAB_ExternalIO.WriteHeartbeat, tostring(statusStr or "IDLE"), s_TurnEventSeq)
    if not okCall then
        errorLog("CAB_ExternalIO.WriteHeartbeat threw error: " .. tostring(wrote))
        return false
    end
    return wrote ~= false
end

-- -----------------------------------------------------------------------------
-- 函数：validateDependencies()
-- 做什么：逐项校验 CAB_Config（6 键）、CAB_Collector（7 函数）、CAB_Executor（9 函数）
--         与 CAB_ExternalIO（7 函数）是否全部就绪且类型合法。
-- 为什么：遵循 D-02，确保任一依赖缺失或破坏时 Initialize 安全返回 false 而非运行期崩溃。
-- 输入：无。
-- 输出：(ok: boolean, errMsg: string | nil)。
-- -----------------------------------------------------------------------------
local function validateDependencies()
    if type(CAB_Config) ~= "table" then
        return false, "CAB_Config table is missing"
    end
    for _, spec in ipairs(REQUIRED_CONFIG_SPEC) do
        local v = CAB_Config[spec.key]
        if spec.kind == "pos_number" then
            if not isFiniteNumber(v) or v <= 0 then
                return false, "CAB_Config." .. spec.key .. " must be a positive finite number"
            end
        elseif spec.kind == "nonneg_number" then
            if not isFiniteNumber(v) or v < 0 then
                return false, "CAB_Config." .. spec.key .. " must be a non-negative finite number"
            end
        elseif spec.kind == "boolean" then
            if type(v) ~= "boolean" then
                return false, "CAB_Config." .. spec.key .. " must be a boolean"
            end
        end
    end

    local moduleChecks = {
        { name = "CAB_Collector",  tbl = CAB_Collector,  funcs = REQUIRED_COLLECTOR_FUNCS },
        { name = "CAB_Executor",   tbl = CAB_Executor,   funcs = REQUIRED_EXECUTOR_FUNCS },
        { name = "CAB_ExternalIO", tbl = CAB_ExternalIO, funcs = REQUIRED_EXTERNAL_IO_FUNCS },
    }
    for _, check in ipairs(moduleChecks) do
        if type(check.tbl) ~= "table" then
            return false, check.name .. " table is missing"
        end
        for _, fnName in ipairs(check.funcs) do
            if type(check.tbl[fnName]) ~= "function" then
                return false, check.name .. "." .. fnName .. " function is missing"
            end
        end
    end

    return true, nil
end

-- -----------------------------------------------------------------------------
-- 函数：flushPendingSettlement(reasonStr)
-- 做什么：当处于 WAITING_SETTLEMENT 却遭遇回合切换或重初始化抢占时，先对在途挂起任务
--         执行 FinalizeActionSettlement 并写回 SendRpcResponse，再清空槽位。
-- 为什么：遵循 D-05 与红线 S-03，确保每个进入调度器的 req_id 100% 有且仅有 1 次回执，
--         彻底杜绝跨回合打断导致外部客户端 8s 超时死等。
-- 输入：reasonStr（抢占原因说明，如 "turn_end" / "turn_start" / "reinitialize"）。
-- 输出：boolean（是否存在并刷写了挂起任务）。
-- -----------------------------------------------------------------------------
local function flushPendingSettlement(reasonStr)
    if s_PendingSettlement == nil then
        return false
    end

    -- 先取出并立即清槽，防止后续回调异常或重入引发二次写回（S-03）
    local pending = s_PendingSettlement
    s_PendingSettlement = nil

    local elapsedSec = (isFiniteNumber(pending.elapsedSec) and pending.elapsedSec >= 0)
        and pending.elapsedSec or 0
    local elapsedMs = math.floor(elapsedSec * 1000 + 0.5)

    local okFin, resultDto = false, "CAB_Executor.FinalizeActionSettlement unavailable"
    if type(CAB_Executor) == "table" and type(CAB_Executor.FinalizeActionSettlement) == "function" then
        okFin, resultDto = pcall(CAB_Executor.FinalizeActionSettlement, pending.baselineInfo, elapsedMs)
    end

    if okFin and type(resultDto) == "table" then
        safeSendRpcResponse(pending.reqId, true, resultDto, nil, false)
        debugLog(
            "Preemptively flushed settlement req_id=" .. tostring(pending.reqId)
                .. " reason=" .. tostring(reasonStr)
        )
    else
        local errMsg = "Pending settlement interrupted ("
            .. tostring(reasonStr or "preempted") .. "): " .. tostring(resultDto)
        errorLog(errMsg)
        safeSendRpcResponse(pending.reqId, false, nil, errMsg, false)
    end
    return true
end

-- -----------------------------------------------------------------------------
-- 函数：sanitizeDeltaTime(deltaTime)
-- 做什么：净化 ContextPtr:SetUpdate 传入的帧时间间隔 deltaTime。
-- 为什么：遵循红线 S-06，彻底过滤 nil、非数值、NaN、<=0 及 +/-inf，防止脏时钟污染
--         轮询/心跳累加器或在 minWaitSec == 0 时触发误结算。
-- 输入：deltaTime（任意 Lua 值）。
-- 输出：number（有限正数原样返回，其余统一返回 0.0）。
-- -----------------------------------------------------------------------------
local function sanitizeDeltaTime(deltaTime)
    if isFiniteNumber(deltaTime) and deltaTime > 0 then
        return deltaTime
    end
    return 0.0
end

-- -----------------------------------------------------------------------------
-- 函数：safeIsSettlementBusy(baselineInfo)
-- 做什么：在 pcall 保护下向 CAB_Executor.IsSettlementBusy 查询在途动作是否仍忙碌。
-- 为什么：遵循红线 S-04，若忙碌态探测意外抛出运行时错误，记录诊断日志并按非忙碌处理，
--         确保满 minWaitSec 后可顺利进入 FinalizeActionSettlement 自愈收口而不卡死。
-- 输入：baselineInfo（动作启动阶段返回的基线上下文表）。
-- 输出：boolean（true 表示仍处于动画或队列忙碌态）。
-- -----------------------------------------------------------------------------
local function safeIsSettlementBusy(baselineInfo)
    if type(CAB_Executor) ~= "table" or type(CAB_Executor.IsSettlementBusy) ~= "function" then
        errorLog("CAB_Executor.IsSettlementBusy unavailable")
        return false
    end
    local okCall, busy = pcall(CAB_Executor.IsSettlementBusy, baselineInfo)
    if not okCall then
        errorLog("CAB_Executor.IsSettlementBusy threw error: " .. tostring(busy))
        return false
    end
    return busy == true
end

-- -----------------------------------------------------------------------------
-- 函数：pushCurrentTurnOverview(degradeHeartbeatOnFailure)
-- 做什么：采集当前激活玩家的全局态势快照并推送至 CAB_ExternalIO.PushTurnOverview，
--         成功时刷新 UI 状态栏；采集或推送异常时记录诊断日志并按需降级写 IDLE 心跳。
-- 为什么：集中复用 Initialize、OnActivePlayerTurnStart 与 OnManualSyncClicked 的导出逻辑，
--         并通过 pcall 隔离下游采集/推送异常（S-04）。
-- 输入：degradeHeartbeatOnFailure（boolean，回合初/初始化失败时降级写入 IDLE 心跳）。
-- 输出：boolean（是否推送成功）。
-- -----------------------------------------------------------------------------
local function pushCurrentTurnOverview(degradeHeartbeatOnFailure)
    local activePlayerID = getActivePlayerID()
    local turnNum = getGameTurn()

    local okCol, overview = pcall(CAB_Collector.BuildTurnOverview, activePlayerID)
    if not okCol or type(overview) ~= "table" or overview.error ~= nil then
        local reason
        if not okCol then
            reason = tostring(overview)
        elseif type(overview) == "table" then
            reason = tostring(overview.error)
        else
            reason = "BuildTurnOverview returned non-table"
        end
        errorLog("BuildTurnOverview failed (turn=" .. tostring(turnNum) .. "): " .. reason)
        if degradeHeartbeatOnFailure == true then
            safeWriteHeartbeat("IDLE")
        end
        safeNotifyUi("Agent: Turn " .. tostring(turnNum) .. " Sync Error")
        return false
    end

    local okPush, pushed = pcall(CAB_ExternalIO.PushTurnOverview, overview, s_TurnEventSeq)
    if not okPush or pushed == false then
        local reason = (not okPush) and tostring(pushed) or "PushTurnOverview returned false"
        errorLog("PushTurnOverview failed (turn=" .. tostring(turnNum) .. "): " .. reason)
        if degradeHeartbeatOnFailure == true then
            safeWriteHeartbeat("IDLE")
        end
        safeNotifyUi("Agent: Turn " .. tostring(turnNum) .. " Sync Error")
        return false
    end

    safeNotifyUi("Agent: Turn " .. tostring(turnNum) .. " Synced")
    debugLog("Turn overview synced: turn=" .. tostring(turnNum) .. " seq=" .. tostring(s_TurnEventSeq))
    return true
end

-- -----------------------------------------------------------------------------
-- 函数：clearAiTurnLockMeta() / enterAiTurnLockedState(...) / reconcileTurnStateOnRequest()
-- 做什么：统一管理 AI_TURN_LOCKED 态切入元信息与请求到达时的实时回合态交叉对齐。
-- 为什么：
--   1. end_turn 提交 CONTROL_ENDTURN 或 OnActivePlayerTurnEnd 触发瞬间，引擎 C++ 侧
--      pPlayer:IsTurnActive() 可能尚未在当帧翻转为 false；记录锁定来源可防止此时紧随的
--      写请求误触发回退 IDLE 穿透门控（严守 S-02）；
--   2. 当确实观测到非活动态后再恢复活动，或回合号/激活玩家发生变化（读档/IGE 切人未触发
--      ActivePlayerTurnStart）时，自动对齐回 IDLE 避免永久锁死（§6.2 风险 1）。
-- 输入 / 输出：reconcileTurnStateOnRequest() 返回 boolean（当前是否允许执行活动回合写指令）。
-- -----------------------------------------------------------------------------
local function clearAiTurnLockMeta()
    s_LockedTurnNumber = nil
    s_LockedPlayerID = nil
    s_TurnLockObservedInactive = false
end

local function enterAiTurnLockedState(writeHeartbeatAndUi, observedInactive)
    s_BridgeState = "AI_TURN_LOCKED"
    s_LockedTurnNumber = getGameTurn()
    s_LockedPlayerID = getActivePlayerID()
    s_TurnLockObservedInactive = (observedInactive == true) or (not isActivePlayerTurnNow())
    if writeHeartbeatAndUi == true then
        s_HeartbeatAccumSec = 0.0
        safeWriteHeartbeat("AI_TURN_PROCESSING")
        safeNotifyUi("Agent: AI Turn...")
    end
end

local function reconcileTurnStateOnRequest()
    local engineTurnActive = isActivePlayerTurnNow()
    if s_BridgeState == "AI_TURN_LOCKED" then
        if not engineTurnActive then
            s_TurnLockObservedInactive = true
            return false
        end
        local turnChanged = (s_LockedTurnNumber ~= nil and getGameTurn() ~= s_LockedTurnNumber)
        local playerChanged = (s_LockedPlayerID ~= nil and getActivePlayerID() ~= s_LockedPlayerID)
        if s_TurnLockObservedInactive or turnChanged or playerChanged then
            s_BridgeState = "IDLE"
            clearAiTurnLockMeta()
            return true
        end
        return false
    end

    if not engineTurnActive then
        enterAiTurnLockedState(false, true)
        return false
    end

    return true
end

-- -----------------------------------------------------------------------------
-- 函数：RPC 入参类型校验与信封映射/异步挂起装配辅助（全部 local）
-- 做什么：对 14 项 IPC 方法的 params 执行严格前置类型守卫，统一映射 CAB_Collector 错误表，
--         并在 5 类写动作成功下发后规范化组装 s_PendingSettlement 切入 WAITING_SETTLEMENT。
-- 为什么：遵循 A-04、D-04 与 D-05，保证缺参/错型零异常早退，写动作统一走帧结算并彻底
--         退役 EXP-04 遗留的 sync_frame_comparison 字段。
-- -----------------------------------------------------------------------------
local function parseRequiredInt(params, key)
    local val = params[key]
    if not isFiniteInteger(val) then
        return nil, "Invalid or missing '" .. key .. "': expected finite integer"
    end
    return val, nil
end

local function parseOptionalInt(params, key)
    local val = params[key]
    if val == nil then
        return nil, nil
    end
    if not isFiniteInteger(val) then
        return nil, "Invalid '" .. key .. "': expected finite integer"
    end
    return val, nil
end

local function parseRequiredNonEmptyString(params, key)
    local val = params[key]
    if type(val) ~= "string" or val == "" then
        return nil, "Invalid or missing '" .. key .. "': expected non-empty string"
    end
    return val, nil
end

local function parseOptionalNonEmptyString(params, key, defaultVal)
    local val = params[key]
    if val == nil then
        return defaultVal, nil
    end
    if type(val) ~= "string" or val == "" then
        return nil, "Invalid '" .. key .. "': expected non-empty string"
    end
    return val, nil
end

local function parseRequiredItemIdentifier(params, key)
    local val = params[key]
    if (type(val) == "string" and val ~= "") or isFiniteInteger(val) then
        return val, nil
    end
    return nil, "Invalid or missing '" .. key .. "': expected non-empty string or finite integer"
end

local function sendCollectorResult(reqId, resultDto)
    if type(resultDto) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, "Collector returned invalid non-table result", false)
        return
    end
    if resultDto.error ~= nil then
        safeSendRpcResponse(reqId, false, nil, tostring(resultDto.error), false)
        return
    end
    safeSendRpcResponse(reqId, true, resultDto, nil, false)
end

local function enrollPendingSettlement(reqId, method, baselineContext, defaultKind, defaultMinWaitSec, overrideMinWaitSec)
    local cfgMaxTimeout = (type(CAB_Config) == "table" and isFiniteNumber(CAB_Config.MAX_SETTLE_TIMEOUT_SEC))
        and CAB_Config.MAX_SETTLE_TIMEOUT_SEC or 1.50
    local maxTimeoutSec = isFiniteNumber(baselineContext.maxTimeoutSec)
        and baselineContext.maxTimeoutSec or cfgMaxTimeout
    if maxTimeoutSec < 0 then
        maxTimeoutSec = cfgMaxTimeout
    end

    local minWaitSec
    if overrideMinWaitSec ~= nil then
        minWaitSec = overrideMinWaitSec
    elseif isFiniteNumber(baselineContext.minWaitSec) then
        minWaitSec = baselineContext.minWaitSec
    else
        minWaitSec = defaultMinWaitSec or 0
    end
    if minWaitSec < 0 then
        minWaitSec = 0
    elseif minWaitSec > maxTimeoutSec then
        minWaitSec = maxTimeoutSec
    end

    local kind = (type(baselineContext.settlementKind) == "string" and baselineContext.settlementKind ~= "")
        and baselineContext.settlementKind or defaultKind

    s_PendingSettlement = {
        reqId = reqId,
        method = method,
        settlementKind = kind,
        baselineInfo = baselineContext,
        elapsedSec = 0.0,
        minWaitSec = minWaitSec,
        maxTimeoutSec = maxTimeoutSec,
    }
    s_BridgeState = "WAITING_SETTLEMENT"
    debugLog(
        "Enrolled pending settlement req_id=" .. tostring(reqId)
            .. " method=" .. tostring(method)
            .. " kind=" .. tostring(kind)
            .. " minWaitSec=" .. tostring(minWaitSec)
    )
end

-- -----------------------------------------------------------------------------
-- 14 项对外 SQLite IPC 方法路由分发表（严格对齐《M1Sub3工作计划.md》§4.4）
-- -----------------------------------------------------------------------------
local RPC_HANDLERS = {}

RPC_HANDLERS.ping = function(reqId, params, activePlayerID, preState)
    local echo = (params.echo ~= nil) and tostring(params.echo) or "pong"
    safeSendRpcResponse(reqId, true, {
        __is_object = true,
        pong = echo,
        turn = getGameTurn(),
        active_player = activePlayerID,
        is_turn_active = isActivePlayerTurnNow(),
        status = preState,
        turn_seq = s_TurnEventSeq,
    }, nil, false)
end

RPC_HANDLERS.test_large_payload = function(reqId, params)
    local targetBytes = DEFAULT_LARGE_PAYLOAD_BYTES
    if params.target_bytes ~= nil then
        if not isFiniteInteger(params.target_bytes) or params.target_bytes < 0 then
            safeSendRpcResponse(reqId, false, nil, "Invalid 'target_bytes': expected non-negative integer", false)
            return
        end
        targetBytes = math.min(params.target_bytes, MAX_LARGE_PAYLOAD_BYTES)
    end
    local useChunk = (params.use_chunk == true)
    local incomingPayload = (params.payload ~= nil) and tostring(params.payload) or ""
    local pad = string.rep("X", targetBytes)
    safeSendRpcResponse(reqId, true, {
        __is_object = true,
        received_len = #incomingPayload,
        generated_len = #pad,
        payload_blob = pad,
    }, nil, useChunk)
end

RPC_HANDLERS.get_turn_overview = function(reqId, _, activePlayerID)
    sendCollectorResult(reqId, CAB_Collector.BuildTurnOverview(activePlayerID))
end

RPC_HANDLERS.get_empire_economy = function(reqId, _, activePlayerID)
    sendCollectorResult(reqId, CAB_Collector.GetEmpireEconomy(activePlayerID))
end

RPC_HANDLERS.get_visibility_summary = function(reqId, _, activePlayerID)
    local visDto = CAB_Collector.GetVisibilitySummary(activePlayerID)
    sendCollectorResult(reqId, visDto)
end

RPC_HANDLERS.get_city_detail = function(reqId, params, activePlayerID)
    local cityId, errCity = parseRequiredInt(params, "city_id")
    if errCity ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCity, false)
        return
    end
    local includePurchasable = (params.include_purchasable ~= false)
    sendCollectorResult(reqId, CAB_Collector.GetCityDetail(activePlayerID, cityId, includePurchasable))
end

RPC_HANDLERS.get_end_turn_status = function(reqId, _, activePlayerID)
    sendCollectorResult(reqId, CAB_Collector.GetEndTurnStatus(activePlayerID))
end

RPC_HANDLERS.get_unit_context = function(reqId, params, activePlayerID)
    local unitId, errUnit = parseRequiredInt(params, "unit_id")
    if errUnit ~= nil then
        safeSendRpcResponse(reqId, false, nil, errUnit, false)
        return
    end
    local radius, errRadius = parseOptionalInt(params, "radius")
    if errRadius ~= nil then
        safeSendRpcResponse(reqId, false, nil, errRadius, false)
        return
    end
    sendCollectorResult(reqId, CAB_Collector.BuildUnitContextAndCandidates(activePlayerID, unitId, radius))
end

RPC_HANDLERS.execute_unit_action = function(reqId, params, activePlayerID)
    local unitId, errUnit = parseRequiredInt(params, "unit_id")
    if errUnit ~= nil then
        safeSendRpcResponse(reqId, false, nil, errUnit, false)
        return
    end
    local actionType, errAction = parseRequiredNonEmptyString(params, "action_type")
    if errAction ~= nil then
        safeSendRpcResponse(reqId, false, nil, errAction, false)
        return
    end
    local tx, errTx = parseOptionalInt(params, "target_x")
    if errTx ~= nil then
        safeSendRpcResponse(reqId, false, nil, errTx, false)
        return
    end
    local ty, errTy = parseOptionalInt(params, "target_y")
    if errTy ~= nil then
        safeSendRpcResponse(reqId, false, nil, errTy, false)
        return
    end

    local overrideDelay = nil
    if params.settle_delay_sec ~= nil then
        if not isFiniteNumber(params.settle_delay_sec) then
            safeSendRpcResponse(reqId, false, nil, "Invalid 'settle_delay_sec': expected finite number", false)
            return
        end
        local maxSec = (type(CAB_Config) == "table" and isFiniteNumber(CAB_Config.MAX_SETTLE_TIMEOUT_SEC))
            and CAB_Config.MAX_SETTLE_TIMEOUT_SEC or 1.50
        overrideDelay = math.max(0, math.min(params.settle_delay_sec, maxSec))
    end

    local allowDeclareWar = (params.allow_declare_war == true)
    local okExec, errExec, baselineContext = CAB_Executor.StartUnitAction(
        activePlayerID,
        unitId,
        actionType,
        tx,
        ty,
        allowDeclareWar
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "StartUnitAction failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "execute_unit_action",
        baselineContext,
        "UNIT_ACTION",
        CAB_Config.DEFAULT_UNIT_SETTLE_SEC,
        overrideDelay
    )
end

RPC_HANDLERS.execute_city_attack = function(reqId, params, activePlayerID)
    local cityId, errCity = parseRequiredInt(params, "city_id")
    if errCity ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCity, false)
        return
    end
    local tx, errTx = parseRequiredInt(params, "target_x")
    if errTx ~= nil then
        safeSendRpcResponse(reqId, false, nil, errTx, false)
        return
    end
    local ty, errTy = parseRequiredInt(params, "target_y")
    if errTy ~= nil then
        safeSendRpcResponse(reqId, false, nil, errTy, false)
        return
    end

    local allowDeclareWar = (params.allow_declare_war == true)
    local okExec, errExec, baselineContext = CAB_Executor.StartCityRangeAttack(
        activePlayerID,
        cityId,
        tx,
        ty,
        allowDeclareWar
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "StartCityRangeAttack failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "execute_city_attack",
        baselineContext,
        "CITY_ATTACK",
        CAB_Config.DEFAULT_UNIT_SETTLE_SEC,
        nil
    )
end

RPC_HANDLERS.purchase_city_item = function(reqId, params, activePlayerID)
    local cityId, errCity = parseRequiredInt(params, "city_id")
    if errCity ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCity, false)
        return
    end
    local item, errItem = parseRequiredItemIdentifier(params, "item")
    if errItem ~= nil then
        safeSendRpcResponse(reqId, false, nil, errItem, false)
        return
    end
    local itemCategory, errCat = parseOptionalNonEmptyString(params, "item_category", "BUILDING")
    if errCat ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCat, false)
        return
    end
    local yieldType, errYield = parseOptionalNonEmptyString(params, "yield_type", "GOLD")
    if errYield ~= nil then
        safeSendRpcResponse(reqId, false, nil, errYield, false)
        return
    end

    local okExec, errExec, baselineContext = CAB_Executor.PurchaseCityItem(
        activePlayerID,
        cityId,
        itemCategory,
        item,
        yieldType
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "PurchaseCityItem failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "purchase_city_item",
        baselineContext,
        "PURCHASE_ITEM",
        CAB_Config.PLOT_BUY_SETTLE_SEC,
        nil
    )
end

RPC_HANDLERS.set_city_production = function(reqId, params, activePlayerID)
    local cityId, errCity = parseRequiredInt(params, "city_id")
    if errCity ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCity, false)
        return
    end
    local orderCategory, errCat = parseRequiredNonEmptyString(params, "order_category")
    if errCat ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCat, false)
        return
    end
    local item, errItem = parseRequiredItemIdentifier(params, "item")
    if errItem ~= nil then
        safeSendRpcResponse(reqId, false, nil, errItem, false)
        return
    end
    local clearQueue = (params.clear_queue ~= false)

    local okExec, errExec, baselineContext = CAB_Executor.SetCityProduction(
        activePlayerID,
        cityId,
        orderCategory,
        item,
        clearQueue
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "SetCityProduction failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "set_city_production",
        baselineContext,
        "SET_PRODUCTION",
        CAB_Config.PLOT_BUY_SETTLE_SEC,
        nil
    )
end

RPC_HANDLERS.purchase_city_plot = function(reqId, params, activePlayerID)
    local cityId, errCity = parseRequiredInt(params, "city_id")
    if errCity ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCity, false)
        return
    end
    -- 主契约为 target_x / target_y，兼容读取备选别名 plot_x / plot_y
    local rawTx = (params.target_x ~= nil) and params.target_x or params.plot_x
    local rawTy = (params.target_y ~= nil) and params.target_y or params.plot_y
    if not isFiniteInteger(rawTx) then
        safeSendRpcResponse(reqId, false, nil, "Invalid or missing 'target_x': expected finite integer", false)
        return
    end
    if not isFiniteInteger(rawTy) then
        safeSendRpcResponse(reqId, false, nil, "Invalid or missing 'target_y': expected finite integer", false)
        return
    end

    local okExec, errExec, baselineContext = CAB_Executor.PurchaseCityPlot(
        activePlayerID,
        cityId,
        rawTx,
        rawTy
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "PurchaseCityPlot failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "purchase_city_plot",
        baselineContext,
        "BUY_PLOT",
        CAB_Config.PLOT_BUY_SETTLE_SEC,
        nil
    )
end

RPC_HANDLERS.end_turn = function(reqId, params, activePlayerID)
    local autoSkip = (params.auto_skip_ready_units == true)
    local _, errExec, resultDto = CAB_Executor.ExecuteEndTurn(activePlayerID, autoSkip)

    -- D-04 信封保真映射：
    --   1. 门控失败（resultDto == nil）-> ok = false；
    --   2. 待办阻塞（BLOCKED, turn_ended ~= true）-> ok = true 保真回传 blocking_info，维持 IDLE；
    --   3. 成功提交（WAITING_NEXT_TURN, turn_ended == true）-> ok = true 并立即切入 AI_TURN_LOCKED。
    if type(resultDto) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "ExecuteEndTurn failed"), false)
        return
    end

    safeSendRpcResponse(reqId, true, resultDto, nil, false)
    if resultDto.turn_ended == true then
        enterAiTurnLockedState(true, false)
    end
end

-- WP5（D-08）增补 6 项硬阻塞查询与设置路由（15 ~ 20）

RPC_HANDLERS.get_research_options = function(reqId, _, activePlayerID)
    sendCollectorResult(reqId, CAB_Collector.GetResearchOptions(activePlayerID))
end

RPC_HANDLERS.set_research_tech = function(reqId, params, activePlayerID)
    -- 主契约为 tech，兼容读取备选别名 tech_type / tech_id
    local rawTech = params.tech
    if rawTech == nil then
        rawTech = (params.tech_type ~= nil) and params.tech_type or params.tech_id
    end
    if not ((type(rawTech) == "string" and rawTech ~= "") or isFiniteInteger(rawTech)) then
        safeSendRpcResponse(reqId, false, nil, "Invalid or missing 'tech': expected non-empty string or finite integer", false)
        return
    end

    local okExec, errExec, baselineContext = CAB_Executor.SetResearchTech(activePlayerID, rawTech)
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "SetResearchTech failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "set_research_tech",
        baselineContext,
        "SET_RESEARCH",
        CAB_Config.PLOT_BUY_SETTLE_SEC,
        nil
    )
end

RPC_HANDLERS.get_policy_options = function(reqId, _, activePlayerID)
    sendCollectorResult(reqId, CAB_Collector.GetPolicyOptions(activePlayerID))
end

RPC_HANDLERS.adopt_policy = function(reqId, params, activePlayerID)
    local targetCategory, errCat = parseOptionalNonEmptyString(params, "target_category", "POLICY")
    if errCat ~= nil then
        safeSendRpcResponse(reqId, false, nil, errCat, false)
        return
    end
    -- 主契约为 target，兼容读取备选别名 policy / branch
    local rawTarget = params.target
    if rawTarget == nil then
        if targetCategory == "BRANCH" then
            rawTarget = (params.branch ~= nil) and params.branch or params.policy
        else
            rawTarget = (params.policy ~= nil) and params.policy or params.branch
        end
    end
    if not ((type(rawTarget) == "string" and rawTarget ~= "") or isFiniteInteger(rawTarget)) then
        safeSendRpcResponse(reqId, false, nil, "Invalid or missing 'target': expected non-empty string or finite integer", false)
        return
    end

    local okExec, errExec, baselineContext = CAB_Executor.AdoptPolicyOrBranch(
        activePlayerID,
        targetCategory,
        rawTarget
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "AdoptPolicyOrBranch failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "adopt_policy",
        baselineContext,
        "ADOPT_POLICY",
        CAB_Config.PLOT_BUY_SETTLE_SEC,
        nil
    )
end

RPC_HANDLERS.get_unit_promotions = function(reqId, params, activePlayerID)
    local unitId, errUnit = parseRequiredInt(params, "unit_id")
    if errUnit ~= nil then
        safeSendRpcResponse(reqId, false, nil, errUnit, false)
        return
    end
    sendCollectorResult(reqId, CAB_Collector.GetUnitPromotions(activePlayerID, unitId))
end

RPC_HANDLERS.promote_unit = function(reqId, params, activePlayerID)
    local unitId, errUnit = parseRequiredInt(params, "unit_id")
    if errUnit ~= nil then
        safeSendRpcResponse(reqId, false, nil, errUnit, false)
        return
    end
    -- 主契约为 promotion，兼容读取备选别名 promotion_type / promotion_id
    local rawPromo = params.promotion
    if rawPromo == nil then
        rawPromo = (params.promotion_type ~= nil) and params.promotion_type or params.promotion_id
    end
    if not ((type(rawPromo) == "string" and rawPromo ~= "") or isFiniteInteger(rawPromo)) then
        safeSendRpcResponse(
            reqId,
            false,
            nil,
            "Invalid or missing 'promotion': expected non-empty string or finite integer",
            false
        )
        return
    end

    local okExec, errExec, baselineContext = CAB_Executor.PromoteUnit(
        activePlayerID,
        unitId,
        rawPromo
    )
    if not okExec or type(baselineContext) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, tostring(errExec or "PromoteUnit failed"), false)
        return
    end

    enrollPendingSettlement(
        reqId,
        "promote_unit",
        baselineContext,
        "PROMOTE_UNIT",
        CAB_Config.PLOT_BUY_SETTLE_SEC,
        nil
    )
end

-- -----------------------------------------------------------------------------
-- 第 3 节：7 个公开导出接口（D1 ~ D7）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- D1：CAB_Dispatcher.Initialize(uiStatusCallback) -> boolean
-- 做什么：执行热重载抢占刷写保护、四模块依赖完整性校验、下游模块初始化及首帧双态分流
--         （玩家活动回合进入 IDLE 并推送首帧态势；非活动回合进入 AI_TURN_LOCKED 写心跳）。
-- 为什么：确保调度控制层在任何依赖不完整或非活动回合读档场景下均能安全启动，绝不脏写。
-- 输入：uiStatusCallback（可选 function(statusText: string) -> nil，非函数自动忽略）。
-- 输出：boolean（初始化成功返回 true，任一依赖或下游初始化失败返回 false）。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.Initialize(uiStatusCallback)
    -- 1. 热重载重初始化保护：若存在残留挂起结算，先刷写回执再清槽（D-05 / S-03）
    if s_PendingSettlement ~= nil then
        flushPendingSettlement("reinitialize")
    end

    -- 2. 校验四模块导出契约
    local depOk, depErr = validateDependencies()
    if not depOk then
        errorLog("Initialize dependency check failed: " .. tostring(depErr))
        s_Initialized = false
        s_BridgeState = "UNINITIALIZED"
        clearAiTurnLockMeta()
        s_PollAccumSec = 0.0
        s_HeartbeatAccumSec = 0.0
        s_UiStatusCallback = nil
        return false
    end

    -- 3. 绑定 UI 回调（仅接受函数类型，其他类型静默忽略）
    s_UiStatusCallback = (type(uiStatusCallback) == "function") and uiStatusCallback or nil

    -- 4. 依次初始化下游 CAB_Executor 与 CAB_ExternalIO
    local okExecCall, execInitOk = pcall(CAB_Executor.Initialize)
    if not okExecCall or execInitOk ~= true then
        errorLog("CAB_Executor.Initialize failed: " .. tostring(execInitOk))
        s_Initialized = false
        s_BridgeState = "UNINITIALIZED"
        clearAiTurnLockMeta()
        s_PollAccumSec = 0.0
        s_HeartbeatAccumSec = 0.0
        return false
    end

    local okExtCall, extInitOk, extInitErr = pcall(
        CAB_ExternalIO.Initialize,
        CAB_Dispatcher.OnExternalRequestReceived
    )
    if not okExtCall or extInitOk ~= true then
        local reason = (not okExtCall) and tostring(extInitOk) or tostring(extInitErr or extInitOk)
        errorLog("CAB_ExternalIO.Initialize failed: " .. reason)
        s_Initialized = false
        s_BridgeState = "UNINITIALIZED"
        clearAiTurnLockMeta()
        s_PollAccumSec = 0.0
        s_HeartbeatAccumSec = 0.0
        return false
    end

    -- 5. 重置节流累加器并置位初始化完成标志
    s_PollAccumSec = 0.0
    s_HeartbeatAccumSec = 0.0
    s_Initialized = true

    -- 6. 按当前是否处于玩家活动回合进行双态分流
    if isActivePlayerTurnNow() then
        s_BridgeState = "IDLE"
        clearAiTurnLockMeta()
        s_TurnEventSeq = s_TurnEventSeq + 1
        pushCurrentTurnOverview(true)
    else
        enterAiTurnLockedState(true, true)
    end

    return true
end

-- -----------------------------------------------------------------------------
-- D2：CAB_Dispatcher.OnActivePlayerTurnStart() -> nil
-- 做什么：响应 Events.ActivePlayerTurnStart，抢占收口任何残留挂起结算、切回 IDLE、
--         递增 s_TurnEventSeq 并采集推送新回合全局态势。
-- 为什么：为外部智能体提供可靠的新回合到达信号（turn_seq 单调递增）与最新全局快照。
-- 输入：无。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.OnActivePlayerTurnStart()
    if not s_Initialized then
        return
    end

    if s_PendingSettlement ~= nil then
        flushPendingSettlement("turn_start")
    end

    s_PollAccumSec = 0.0
    s_HeartbeatAccumSec = 0.0
    s_BridgeState = "IDLE"
    clearAiTurnLockMeta()
    s_TurnEventSeq = s_TurnEventSeq + 1

    pushCurrentTurnOverview(true)
end

-- -----------------------------------------------------------------------------
-- D3：CAB_Dispatcher.OnActivePlayerTurnEnd() -> nil
-- 做什么：响应 Events.ActivePlayerTurnEnd，抢占收口任何在途异步结算，将状态机锁入
--         AI_TURN_LOCKED，并立即写入 AI_TURN_PROCESSING 心跳与更新 UI 提示。
-- 为什么：防止玩家手动点击下一回合打断在途结算导致外部死等，同时立刻启动 AI 回合门控。
-- 输入：无。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.OnActivePlayerTurnEnd()
    if not s_Initialized then
        return
    end

    if s_PendingSettlement ~= nil then
        flushPendingSettlement("turn_end")
    end

    enterAiTurnLockedState(true, false)
end

-- -----------------------------------------------------------------------------
-- D4：CAB_Dispatcher.OnManualSyncClicked() -> nil
-- 做什么：响应右上角手动同步按钮点击，仅在已初始化、玩家活动回合且 IDLE 态下强制刷新
--         turn_overview_auto，且严格保持 s_TurnEventSeq 不变。
-- 为什么：遵循 D-06 与红线 S-05：挂起结算或 AI 回合点击不脏写快照；合法刷新不递增
--         s_TurnEventSeq 以免外部智能体误判发生了新回合切换。
-- 输入：无。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.OnManualSyncClicked()
    if not s_Initialized then
        return
    end

    if s_PendingSettlement ~= nil or s_BridgeState == "WAITING_SETTLEMENT" then
        safeNotifyUi("Agent: Busy (Settling...)")
        return
    end

    if s_BridgeState == "EXECUTING_SYNC" then
        safeNotifyUi("Agent: Busy (Syncing...)")
        return
    end

    if s_BridgeState == "AI_TURN_LOCKED" or not isActivePlayerTurnNow() then
        if s_BridgeState ~= "AI_TURN_LOCKED" then
            enterAiTurnLockedState(false, true)
        end
        safeNotifyUi("Agent: AI Turn...")
        return
    end

    -- 严格不递增 s_TurnEventSeq（S-05）
    pushCurrentTurnOverview(false)
end

-- -----------------------------------------------------------------------------
-- D5：CAB_Dispatcher.OnExternalRequestReceived(reqObj) -> nil
-- 做什么：作为 CAB_ExternalIO 的新消息到达委托回调入口，执行：
--         1. 请求信封与未初始化守卫；
--         2. WAITING_SETTLEMENT / EXECUTING_SYNC 单工互斥守卫（D-05 / S-03）；
--         3. 实时活动回合交叉对齐与 D-03 / S-02 7 项非活动回合白名单门控；
--         4. 全量 14 项 IPC 方法参数校验、pcall 隔离分发、D-04 信封保真映射与异常自愈。
-- 为什么：将外部通信与游戏执行解耦，确保每个合法 req_id 均有确定回执且状态机永不卡锁。
-- 输入：reqObj（table，含 req_id / method / params）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.OnExternalRequestReceived(reqObj)
    if type(reqObj) ~= "table" then
        return
    end
    local reqId = tonumber(reqObj.req_id)
    if not isFiniteInteger(reqId) then
        return
    end
    if not s_Initialized then
        safeSendRpcResponse(reqId, false, nil, "CAB_Dispatcher is not initialized", false)
        return
    end

    -- 1. 挂起结算与同步执行互斥守卫（D-05 / S-03）：绝不污染在途结算
    if s_PendingSettlement ~= nil or s_BridgeState == "WAITING_SETTLEMENT" then
        safeSendRpcResponse(reqId, false, nil, "Bridge is busy waiting for pending settlement", false)
        return
    end
    if s_BridgeState == "EXECUTING_SYNC" then
        safeSendRpcResponse(reqId, false, nil, "Bridge is busy executing a synchronous request", false)
        return
    end

    -- 2. 实时交叉对齐活动回合态（防读档/IGE 失步，同时防止 end_turn 刚锁入时误解锁）
    local turnAllowedForWrites = reconcileTurnStateOnRequest()

    -- 3. 校验 method 存在性与路由表命中
    local method = reqObj.method
    if type(method) ~= "string" or method == "" then
        safeSendRpcResponse(reqId, false, nil, "Missing or invalid RPC method", false)
        return
    end
    local handler = RPC_HANDLERS[method]
    if handler == nil then
        safeSendRpcResponse(reqId, false, nil, "Unknown RPC method: " .. method, false)
        return
    end

    -- 4. 非活动回合严格白名单门控（D-03 / S-02）：先于参数解析拦截 6 写指令与 get_unit_context
    if (not turnAllowedForWrites) and (not AI_TURN_READONLY_WHITELIST[method]) then
        safeSendRpcResponse(reqId, false, nil, "Player turn is not active (AI turn in progress)", false)
        return
    end

    -- 5. 校验 params（缺省为空表，非 table 直接拒返）
    local params = reqObj.params
    if params == nil then
        params = {}
    elseif type(params) ~= "table" then
        safeSendRpcResponse(reqId, false, nil, "Invalid params: expected object table", false)
        return
    end

    -- 6. 刷新 UI 状态栏并在 pcall 保护下分发执行（S-04 异常自愈）
    safeNotifyUi("Agent: " .. method .. " (#" .. tostring(reqId) .. ")")

    local preState = s_BridgeState
    local activePlayerID = getActivePlayerID()
    s_BridgeState = "EXECUTING_SYNC"

    local okRun, runErr = pcall(handler, reqId, params, activePlayerID, preState)
    if not okRun then
        errorLog("Unhandled error in RPC '" .. method .. "' (req_id=" .. tostring(reqId) .. "): " .. tostring(runErr))
        -- 若在异常前未进入有效挂起结算，强制自愈回合法态并兜底返回 ok=false（S-04）
        if s_PendingSettlement == nil then
            if preState == "AI_TURN_LOCKED" or not isActivePlayerTurnNow() then
                s_BridgeState = "AI_TURN_LOCKED"
            else
                s_BridgeState = "IDLE"
            end
            safeSendRpcResponse(
                reqId,
                false,
                nil,
                "RPC execution error (" .. method .. "): " .. tostring(runErr),
                false
            )
        end
        return
    end

    -- 若路由分支未切入 WAITING_SETTLEMENT 或 AI_TURN_LOCKED，则恢复至执行前合法态
    if s_PendingSettlement == nil and s_BridgeState == "EXECUTING_SYNC" then
        s_BridgeState = preState
    end
end

-- -----------------------------------------------------------------------------
-- 函数：completePendingSettlement(pending)
-- 做什么：在异步结算满足完成条件或触达硬超时后，恢复合法状态机态、经 pcall 调用
--         CAB_Executor.FinalizeActionSettlement 采集结算 DTO 并写回 SendRpcResponse。
-- 为什么：
--   1. 调用前调用方已清空 s_PendingSettlement，此处先行恢复 IDLE/AI_TURN_LOCKED，
--      确保即便 FinalizeActionSettlement 或 SendRpcResponse 抛错也不卡锁（S-03/S-04）；
--   2. 遵循 D-04 信封保真：只要产出合法 DTO 表（含 timed_out=true / purchased=false /
--      executed=false），统一以 ok=true 透传，避免 Python 侧丢弃诊断详情；仅当下游抛错
--      或返回非表时兜底写回 ok=false。
-- 输入：pending（已从 s_PendingSettlement 取出的挂起记录表）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function completePendingSettlement(pending)
    local elapsedSec = (isFiniteNumber(pending.elapsedSec) and pending.elapsedSec >= 0)
        and pending.elapsedSec or 0.0
    local elapsedMs = math.floor(elapsedSec * 1000 + 0.5)

    if isActivePlayerTurnNow() then
        s_BridgeState = "IDLE"
        clearAiTurnLockMeta()
    else
        enterAiTurnLockedState(false, true)
    end

    local okFin, resultDto = false, "CAB_Executor.FinalizeActionSettlement unavailable"
    if type(CAB_Executor) == "table" and type(CAB_Executor.FinalizeActionSettlement) == "function" then
        okFin, resultDto = pcall(CAB_Executor.FinalizeActionSettlement, pending.baselineInfo, elapsedMs)
    end

    if okFin and type(resultDto) == "table" then
        safeSendRpcResponse(pending.reqId, true, resultDto, nil, false)
        safeNotifyUi("Agent: Settled #" .. tostring(pending.reqId))
        debugLog(
            "Settled pending action req_id=" .. tostring(pending.reqId)
                .. " method=" .. tostring(pending.method)
                .. " kind=" .. tostring(pending.settlementKind)
                .. " elapsedMs=" .. tostring(elapsedMs)
                .. " timedOut=" .. tostring(resultDto.timed_out)
        )
    else
        local errMsg = "Settlement finalization error ("
            .. tostring(pending.method or "unknown") .. "): " .. tostring(resultDto)
        errorLog(errMsg)
        safeSendRpcResponse(pending.reqId, false, nil, errMsg, false)
        safeNotifyUi("Agent: Settle Error #" .. tostring(pending.reqId))
    end
end

-- -----------------------------------------------------------------------------
-- D6：CAB_Dispatcher.OnFrameUpdate(deltaTime) -> nil
-- 做什么：作为 ContextPtr:SetUpdate 的每帧驱动入口，统一完成：
--         1. 帧间隔净化（S-06）与同步执行期重入守卫；
--         2. 分支一（WAITING_SETTLEMENT）：按单帧上限 0.50s 推进 5 类异步动作计时，
--            联合 minWaitSec / IsSettlementBusy 与 1.50s 硬超时收口结算并暂停外部轮询（S-03）；
--         3. 分支二（IDLE / AI_TURN_LOCKED）：按 0.20s 节流调用 PollIncomingRequest，
--            按 2.00s 节流刷新 IDLE 或 AI_TURN_PROCESSING 存活心跳。
-- 为什么：避免在单帧同步回调中死等引擎动画或消息队列落地，确保 UI 不卡顿、跨帧状态
--         回读精准且任何单帧尖峰或下游故障均不会导致状态机死锁。
-- 输入：deltaTime（number，距上一帧的秒数）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.OnFrameUpdate(deltaTime)
    if not s_Initialized then
        return
    end

    -- 1. S-06 帧时钟净化（过滤 nil / 非数字 / NaN / <=0 / +/-inf）
    local dt = sanitizeDeltaTime(deltaTime)
    if dt <= 0 then
        return
    end

    -- 2. 防止同步 RPC 执行期意外重入帧更新破坏状态机
    if s_BridgeState == "EXECUTING_SYNC" then
        return
    end

    -- 3. 分支一：推进在途异步结算（S-03：挂起期严格暂停 PollIncomingRequest）
    if s_PendingSettlement ~= nil then
        local pending = s_PendingSettlement
        local stepDt = math.min(dt, MAX_SETTLE_STEP_SEC)
        pending.elapsedSec = pending.elapsedSec + stepDt

        local isBusy = safeIsSettlementBusy(pending.baselineInfo)
        local readyByMinWait = (pending.elapsedSec + TIME_EPSILON >= pending.minWaitSec) and (not isBusy)
        local hitMaxTimeout = (pending.elapsedSec + TIME_EPSILON >= pending.maxTimeoutSec)

        if readyByMinWait or hitMaxTimeout then
            -- 先清空挂起槽位再收口与写回，杜绝异常或重入导致二次回执（S-03 / S-04）
            s_PendingSettlement = nil
            completePendingSettlement(pending)
        end
        return
    end

    -- 4. 防御性自愈：若无挂起槽位却处于异常悬空 WAITING_SETTLEMENT，恢复至当前合法态
    if s_BridgeState == "WAITING_SETTLEMENT" then
        if isActivePlayerTurnNow() then
            s_BridgeState = "IDLE"
            clearAiTurnLockMeta()
        else
            enterAiTurnLockedState(false, true)
        end
    end

    -- 5. 分支二：空闲态 / AI 锁态节流轮询（0.20s）与周期心跳（2.00s）
    s_PollAccumSec = s_PollAccumSec + dt
    if s_PollAccumSec + TIME_EPSILON >= CAB_Config.POLL_INTERVAL_SEC then
        s_PollAccumSec = 0.0
        if type(CAB_ExternalIO) == "table" and type(CAB_ExternalIO.PollIncomingRequest) == "function" then
            local okPoll, pollRes = pcall(CAB_ExternalIO.PollIncomingRequest)
            if not okPoll then
                errorLog("CAB_ExternalIO.PollIncomingRequest threw error: " .. tostring(pollRes))
            end
        end
        -- 若本次轮询触发了异步写动作进入 WAITING_SETTLEMENT，立即结束本帧
        if s_PendingSettlement ~= nil or s_BridgeState == "WAITING_SETTLEMENT" then
            return
        end
    end

    s_HeartbeatAccumSec = s_HeartbeatAccumSec + dt
    if s_HeartbeatAccumSec + TIME_EPSILON >= CAB_Config.HEARTBEAT_INTERVAL_SEC then
        s_HeartbeatAccumSec = 0.0
        local hbStatus = (s_BridgeState == "AI_TURN_LOCKED" or not isActivePlayerTurnNow())
            and "AI_TURN_PROCESSING" or "IDLE"
        safeWriteHeartbeat(hbStatus)
    end
end

-- -----------------------------------------------------------------------------
-- D7：CAB_Dispatcher.GetRuntimeState() -> table
-- 做什么：返回调度器内部运行状态的纯只读浅拷贝快照（带 __is_object = true）。
-- 为什么：遵循 D-06，向测试套件与诊断面板提供可观测性，同时零暴露内部私有表引用。
-- 输入：无。
-- 输出：table（浅拷贝状态快照）。
-- -----------------------------------------------------------------------------
function CAB_Dispatcher.GetRuntimeState()
    local hasPending = (s_PendingSettlement ~= nil)
    return {
        __is_object = true,
        initialized = (s_Initialized == true),
        bridge_state = s_BridgeState,
        turn_event_seq = s_TurnEventSeq,
        has_pending_settlement = hasPending,
        pending_req_id = hasPending and s_PendingSettlement.reqId or nil,
        pending_method = hasPending and s_PendingSettlement.method or nil,
        pending_kind = hasPending and s_PendingSettlement.settlementKind or nil,
        pending_elapsed_sec = hasPending and s_PendingSettlement.elapsedSec or nil,
        pending_min_wait_sec = hasPending and s_PendingSettlement.minWaitSec or nil,
        pending_max_timeout_sec = hasPending and s_PendingSettlement.maxTimeoutSec or nil,
        poll_accum_sec = s_PollAccumSec,
        heartbeat_accum_sec = s_HeartbeatAccumSec,
    }
end
