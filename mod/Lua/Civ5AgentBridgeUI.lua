-- =============================================================================
-- 文件：Lua/Civ5AgentBridgeUI.lua
-- 做什么：《文明5》智能体指挥系统 UI 控制器与 SQLite IPC 异步帧轮询器：
--   1. 初始化 Modding.OpenUserData("Civ5AgentBridge", 1) 连接并写入启动心跳；
--   2. 监听 Events.ActivePlayerTurnStart，在玩家回合初自动导出 turn_overview_auto；
--   3. 通过 ContextPtr:SetUpdate 每 0.25s 轮询 SQLite 的 rpc_request 槽位；
--   4. 对 execute_unit_action 采用“下发指令 -> 等待动画/移动力结算（或超时 0.4s）-> 采样增量视野”两段式异步响应，
--      彻底解决瓶颈 B-3（动作结算与迷雾视野刷新时机问题）。
-- =============================================================================

include("Civ5AgentBridgeCore")

local g_BridgeDB = Modding.OpenUserData("Civ5AgentBridge", 1)
local g_PollAccumTime = 0.0
local g_PollIntervalSec = 0.20
local g_LastProcessedReqId = -1
local g_PendingAction = nil

-- -----------------------------------------------------------------------------
-- 函数：CAB_UpdateStatusLabel(text)
-- 做什么：刷新游戏右上角状态栏按钮文字，便于玩家直观看到桥接状态。
-- -----------------------------------------------------------------------------
local function CAB_UpdateStatusLabel(text)
    if Controls and Controls.BridgeStatusLabel then
        Controls.BridgeStatusLabel:SetText(text)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_WriteHeartbeat(statusStr)
-- 做什么：向 SQLite 写入桥接心跳与能力自检信息（供 EXP-03 验收脚本自动探测）。
-- -----------------------------------------------------------------------------
local function CAB_WriteHeartbeat(statusStr)
    if not g_BridgeDB then return end
    local hb = {
        __is_object = true,
        turn = (Game and Game.GetGameTurn()) or 0,
        active_player = (Game and Game.GetActivePlayer()) or 0,
        status = statusStr or "IDLE",
        last_req_id = g_LastProcessedReqId,
        clock_ms = math.floor((os and os.clock and os.clock() or 0) * 1000)
    }
    g_BridgeDB.SetValue("bridge_heartbeat", CAB_JsonEncode(hb))
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_WriteRpcResponse(reqId, ok, dataTable, errMsg, forceChunked)
-- 做什么：将 RPC 处理结果序列化为 JSON 并写回 SQLite 的 rpc_response 槽位。
-- -----------------------------------------------------------------------------
local function CAB_WriteRpcResponse(reqId, ok, dataTable, errMsg, forceChunked)
    local resp = {
        __is_object = true,
        req_id = reqId,
        ok = ok and true or false,
        data = dataTable,
        error = errMsg
    }
    local encoded = CAB_JsonEncode(resp)
    CAB_DbWritePayload(g_BridgeDB, "rpc_response", encoded, forceChunked)
    g_BridgeDB.SetValue("rpc_response_req_id", tostring(reqId))
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ProcessRpcRequest(reqObj)
-- 做什么：路由并执行来自外部 Python MCP Server 的 RPC 请求。
-- -----------------------------------------------------------------------------
local function CAB_ProcessRpcRequest(reqObj)
    local reqId = tonumber(reqObj.req_id) or 0
    local method = tostring(reqObj.method or "")
    local params = reqObj.params or {}
    local activePlayerID = Game.GetActivePlayer()

    CAB_UpdateStatusLabel("Agent: " .. method .. " (#" .. tostring(reqId) .. ")")

    if method == "ping" then
        CAB_WriteRpcResponse(reqId, true, {
            __is_object = true,
            pong = tostring(params.echo or "pong"),
            turn = Game.GetGameTurn(),
            active_player = activePlayerID
        }, nil, false)

    elseif method == "test_large_payload" then
        -- EXP-03 瓶颈 A-3 专项测试：接收或生成指定字节长度的大 JSON 载荷并校验完整性
        local targetBytes = tonumber(params.target_bytes) or 32768
        local useChunk = (params.use_chunk == true)
        local incomingPayload = tostring(params.payload or "")
        local pad = string.rep("X", math.max(0, targetBytes))
        CAB_WriteRpcResponse(reqId, true, {
            __is_object = true,
            received_len = #incomingPayload,
            generated_len = #pad,
            payload_blob = pad
        }, nil, useChunk)

    elseif method == "get_turn_overview" then
        local overview = CAB_BuildTurnOverview(activePlayerID)
        CAB_WriteRpcResponse(reqId, true, overview, nil, false)

    elseif method == "get_unit_context" then
        local unitID = tonumber(params.unit_id)
        local radius = tonumber(params.radius) or 2
        local ctx = CAB_BuildUnitContextAndCandidates(activePlayerID, unitID, radius)
        if ctx.error then
            CAB_WriteRpcResponse(reqId, false, nil, ctx.error, false)
        else
            CAB_WriteRpcResponse(reqId, true, ctx, nil, false)
        end

    elseif method == "execute_unit_action" then
        local unitID = tonumber(params.unit_id)
        local actionType = tostring(params.action_type or "MOVE_STEP")
        local tx = tonumber(params.target_x)
        local ty = tonumber(params.target_y)
        local waitSec = tonumber(params.settle_delay_sec) or 0.35

        local ok, err, baselineInfo = CAB_ExecuteActionImmediate(activePlayerID, unitID, actionType, tx, ty)
        if not ok then
            CAB_WriteRpcResponse(reqId, false, nil, err, false)
        else
            -- 同步立即快照（供 EXP-04 对比同帧 vs 延迟结算后的视野与移动力差异）
            local syncSnap = CAB_CollectSettlementResult(baselineInfo, 0)
            if waitSec <= 0 then
                CAB_WriteRpcResponse(reqId, true, syncSnap, nil, false)
            else
                g_PendingAction = {
                    reqId = reqId,
                    baselineInfo = baselineInfo,
                    syncSnapshot = syncSnap,
                    remainingWaitSec = waitSec,
                    totalWaitSec = waitSec
                }
            end
        end
    else
        CAB_WriteRpcResponse(reqId, false, nil, "Unknown RPC method: " .. method, false)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_OnFrameUpdate(deltaTime)
-- 做什么：绑定 ContextPtr:SetUpdate 的异步帧轮询回调。
--   1. 若有正在等待移动/战斗结算的 g_PendingAction，倒计时并在结算后采样增量视野写回响应；
--   2. 每 0.20s 检查 SQLite 中是否有新的 rpc_request_req_id > g_LastProcessedReqId。
-- -----------------------------------------------------------------------------
local function CAB_OnFrameUpdate(deltaTime)
    if not g_BridgeDB then return end

    -- 1. 处理挂起中的单位动作结算与增量视野采样
    if g_PendingAction ~= nil then
        g_PendingAction.remainingWaitSec = g_PendingAction.remainingWaitSec - deltaTime
        local pPlayer = Players[g_PendingAction.baselineInfo.activePlayerID]
        local pUnit = pPlayer and pPlayer:GetUnitByID(g_PendingAction.baselineInfo.unitID)
        local isBusy = false
        if pUnit and not pUnit:IsDead() then
            local okBusy, bVal = pcall(function()
                local uPlot = pUnit:GetPlot()
                return pUnit:IsBusy() or pUnit:IsFighting() or (uPlot ~= nil and uPlot:IsFighting())
            end)
            if okBusy and bVal then isBusy = true end
        end

        -- 当等待时间结束且单位不再处于忙碌态（或最多等待 1.5 秒兜底）时完成采样
        if (g_PendingAction.remainingWaitSec <= 0 and not isBusy) or (g_PendingAction.remainingWaitSec < -1.1) then
            local elapsedMs = math.floor((g_PendingAction.totalWaitSec - g_PendingAction.remainingWaitSec) * 1000)
            local settledResult = CAB_CollectSettlementResult(g_PendingAction.baselineInfo, elapsedMs)
            settledResult.sync_frame_comparison = {
                __is_object = true,
                sync_moves_left = (g_PendingAction.syncSnapshot.unit_after and g_PendingAction.syncSnapshot.unit_after.moves_left) or -1,
                sync_spotted_count = g_PendingAction.syncSnapshot.delta_observation.newly_spotted_count
            }
            CAB_WriteRpcResponse(g_PendingAction.reqId, true, settledResult, nil, false)
            CAB_UpdateStatusLabel("Agent: Settled #" .. tostring(g_PendingAction.reqId))
            g_PendingAction = nil
        end
        return
    end

    -- 2. 节流轮询 SQLite 新请求
    g_PollAccumTime = g_PollAccumTime + deltaTime
    if g_PollAccumTime < g_PollIntervalSec then
        return
    end
    g_PollAccumTime = 0.0

    local reqIdStr = g_BridgeDB.GetValue("rpc_request_req_id")
    local reqId = tonumber(reqIdStr)
    if reqId and reqId > g_LastProcessedReqId then
        g_LastProcessedReqId = reqId
        local rawJson = CAB_DbReadPayload(g_BridgeDB, "rpc_request")
        local reqObj, decodeErr = CAB_JsonDecode(rawJson)
        if not reqObj then
            CAB_WriteRpcResponse(reqId, false, nil, "JSON decode error: " .. tostring(decodeErr), false)
        else
            reqObj.req_id = reqId
            local okExec, runErr = pcall(CAB_ProcessRpcRequest, reqObj)
            if not okExec then
                CAB_WriteRpcResponse(reqId, false, nil, "Lua runtime error: " .. tostring(runErr), false)
            end
        end
        CAB_WriteHeartbeat("IDLE")
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_OnExportSnapshotNow()
-- 做什么：回合开始或玩家点击右上角按钮时，主动导出当前回合全局态势到 turn_overview_auto。
-- -----------------------------------------------------------------------------
local function CAB_OnExportSnapshotNow()
    if not g_BridgeDB then return end
    local activePlayerID = Game.GetActivePlayer()
    local overview = CAB_BuildTurnOverview(activePlayerID)
    CAB_DbWritePayload(g_BridgeDB, "turn_overview_auto", CAB_JsonEncode(overview), false)
    CAB_WriteHeartbeat("TURN_SYNCED")
    CAB_UpdateStatusLabel("Agent: Turn " .. tostring(Game.GetGameTurn()) .. " Synced")
    print("[Civ5AgentBridge] Turn overview exported for Turn " .. tostring(Game.GetGameTurn()))
end

-- -----------------------------------------------------------------------------
-- 初始化挂载：按钮回调、回合开始事件、帧轮询注册与初始心跳
-- -----------------------------------------------------------------------------
local function CAB_Initialize()
    -- 重置请求游标，允许外部随时从 req_id >= 1 发起新会话
    local existingReqId = tonumber(g_BridgeDB and g_BridgeDB.GetValue("rpc_request_req_id")) or 0
    g_LastProcessedReqId = existingReqId

    if Controls and Controls.BridgeSyncButton then
        Controls.BridgeSyncButton:RegisterCallback(Mouse.eLClick, CAB_OnExportSnapshotNow)
    end
    Events.ActivePlayerTurnStart.Add(CAB_OnExportSnapshotNow)
    ContextPtr:SetUpdate(CAB_OnFrameUpdate)

    CAB_OnExportSnapshotNow()
    print("[Civ5AgentBridge] Civ5AgentBridgeUI initialized and polling ModUserData/Civ5AgentBridge-1.db")
end

CAB_Initialize()
