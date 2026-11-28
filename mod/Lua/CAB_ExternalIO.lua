-- =============================================================================
-- 文件：mod/Lua/CAB_ExternalIO.lua
-- 职责：模块 1（游戏端纯 Lua 桥接 Mod）——子模块 4：外部交互子模块（CAB_ExternalIO）。
--       作为模块 1 唯一持有 SQLite 数据库句柄（Modding.OpenUserData）的通信防腐层，
--       屏蔽 SimpleValues 大载荷 UTF-8 安全分片读写、原子发布屏障写序、单调请求水位线
--       防重放、严格非空 rpc_session_id 会话重置以及 JSON/回调/DB 异常全隔离细节。
--
-- 依赖：严格遵守单向分层与守卫式按需加载规范（D-02），仅向下依赖基础静态配置与 JSON 底座：
--         if CAB_Config == nil then include("CAB_Config") end
--         if CAB_Json == nil then include("Civ5AgentBridgeJson") end
--
-- 对外契约（《模块内部接口设计.md》§三 & 《M1Sub4工作计划.md》D-04）：
--   * 唯一全局导出表：CAB_ExternalIO（精确 8 个公开接口 X1 ~ X8）：
--       X1: Initialize(onMessageCallback) -> (boolean, string | nil)
--       X2: WritePayload(key, strValue, forceChunked) -> boolean
--       X3: ReadPayload(key) -> string | nil
--       X4: PushTurnOverview(overviewTable, turnSeq) -> boolean
--       X5: WriteHeartbeat(statusStr, turnSeq) -> boolean
--       X6: SendRpcResponse(reqId, ok, dataTable, errMsg, forceChunked) -> boolean
--       X7: PollIncomingRequest() -> boolean
--       X8: GetRuntimeState() -> table
--   * 全部内部私有状态与辅助函数严格声明为 local，零多余全局符号泄露。
--
-- 安全红线（《M1Sub4工作计划.md》§2.2 I-01 ~ I-06）：
--   * I-01 单向分层与零游戏写副作用：严禁反向引用上层业务模块或调用任何游戏写接口；
--   * I-02 UTF-8 多字节分片边界绝对安全：切片右边界自动对齐至 UTF-8 首字节之前并带防死循环守卫；
--   * I-03 原子发布屏障写入顺序不可颠倒：先完整写完载荷分片，最后一步才推进屏障键；
--   * I-04 水位线单调防重放与严格非空会话重置：消费前推进水位线，仅新非空 session 重置为 0；
--   * I-05 通信防腐层异常全隔离：全链路 pcall 保护，坏 JSON/非对象请求/回调异常兜底回错不崩帧循环；
--   * I-06 纯只读诊断快照：GetRuntimeState 仅返回浅拷贝基础标量，零句柄/闭包泄露。
-- =============================================================================

if CAB_Config == nil then
    include("CAB_Config")
end
if CAB_Json == nil then
    include("Civ5AgentBridgeJson")
end

CAB_ExternalIO = {}

-- -----------------------------------------------------------------------------
-- 第 1 节：内部私有状态变量与常量（全部 local）
-- -----------------------------------------------------------------------------

local DEFAULT_CHUNK_SIZE_BYTES = 3000
local MIN_CHUNK_SIZE_BYTES = 4

local s_Initialized = false
local s_BridgeDB = nil
local s_LastProcessedReqId = 0
local s_ActiveSessionId = ""
local s_OnMessageCallback = nil

-- -----------------------------------------------------------------------------
-- 第 2 节：内部安全日志、数值校验与 SQLite 受保护读写辅助（全部 local）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：debugLog(msg) / errorLog(msg)
-- 做什么：向 Logs/Lua.log 输出带 [CAB_ExternalIO] 前缀的调试/错误诊断日志。
-- 为什么：调试日志遵循 CAB_Config.ENABLE_DEBUG_LOG 开关，关键错误始终留痕；
--         在 CAB_Config 或 print 缺失时亦零异常。
-- 输入：msg（日志内容）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function debugLog(msg)
    if type(CAB_Config) == "table" and CAB_Config.ENABLE_DEBUG_LOG == true and print ~= nil then
        print("[CAB_ExternalIO] " .. tostring(msg))
    end
end

local function errorLog(msg)
    if print ~= nil then
        print("[CAB_ExternalIO][ERROR] " .. tostring(msg))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：isFiniteNumber(v) / isFiniteInteger(v)
-- 做什么：校验值为有限实数或有限整数，过滤 nil、非数值、NaN 及 +/-inf。
-- 为什么：Lua 5.1 中 NaN 与无穷大参与大小比较或取整可能产生隐蔽越界或死循环。
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
-- 函数：parseNonNegInt(raw) / parsePositiveInt(raw) / normalizeNonNegInt(raw)
-- 做什么：将 SQLite 读取的字符串或数字严格解析为非负整数（>=0）或正整数（>=1）。
-- 为什么：SimpleValues 既可能返回文本 "12" 也可能返回数字 12，需统一拦截小数、负数、
--         NaN、无穷大与非法字符串，防止污染 req_id 水位线或分片计数循环。
-- 输入：raw（任意 Lua 值）。
-- 输出：parse* 返回整数或 nil；normalizeNonNegInt 返回非负整数（异常回退 0）。
-- -----------------------------------------------------------------------------
local function parseNonNegInt(raw)
    if raw == nil then
        return nil
    end
    local n = tonumber(raw)
    if isFiniteInteger(n) and n >= 0 then
        return n
    end
    return nil
end

local function parsePositiveInt(raw)
    local n = parseNonNegInt(raw)
    if n ~= nil and n >= 1 then
        return n
    end
    return nil
end

local function normalizeNonNegInt(raw)
    if raw == nil then
        return 0
    end
    local n = tonumber(raw)
    if isFiniteNumber(n) and n >= 0 then
        return math.floor(n)
    end
    return 0
end

-- -----------------------------------------------------------------------------
-- 函数：normalizeSessionId(raw)
-- 做什么：将 SQLite 读取的 rpc_session_id 规范化为字符串（空/非法返回 ""）。
-- 为什么：SQLite SimpleValues(Value VARIANT) 具有 NUMERIC 亲和性，若外部客户端传入
--         纯数字会话号（如时间戳 "1732770000"），GetValue 可能返回 number；此处统一
--         兼容字符串与有限数字，同时拦截 nil/空串/布尔/表。
-- 输入：raw（SQLite GetValue 返回值）。
-- 输出：string（非空会话标识或 ""）。
-- -----------------------------------------------------------------------------
local function normalizeSessionId(raw)
    if type(raw) == "string" then
        return raw
    end
    if isFiniteNumber(raw) then
        return tostring(raw)
    end
    return ""
end

-- -----------------------------------------------------------------------------
-- 函数：getChunkSize()
-- 做什么：读取并返回生效的单分片字节上限（默认 3000，容错兜底最小为 4）。
-- 为什么：单个合法 UTF-8 字符最多占 4 字节（如补充平面表情符号），将下限钳制为 4
--         可确保任何合法 UTF-8 字符都能完整落入单个分片而不被截断。
-- 输入：无。
-- 输出：number（>= 4 的正整数）。
-- -----------------------------------------------------------------------------
local function getChunkSize()
    if type(CAB_Config) == "table" and isFiniteNumber(CAB_Config.CHUNK_SIZE_BYTES) and CAB_Config.CHUNK_SIZE_BYTES > 0 then
        local floored = math.floor(CAB_Config.CHUNK_SIZE_BYTES)
        if floored >= MIN_CHUNK_SIZE_BYTES then
            return floored
        end
        return MIN_CHUNK_SIZE_BYTES
    end
    return DEFAULT_CHUNK_SIZE_BYTES
end

-- -----------------------------------------------------------------------------
-- 函数：resetInternalState()
-- 做什么：将全部模块私有状态复位至未初始化态。
-- 为什么：当热重载二次调用 Initialize 失败时，必须清空历史句柄与回调引用，防止后续
--         帧循环继续使用失效数据库句柄或错误水位线。
-- 输入：无。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function resetInternalState()
    s_Initialized = false
    s_BridgeDB = nil
    s_LastProcessedReqId = 0
    s_ActiveSessionId = ""
    s_OnMessageCallback = nil
end

-- -----------------------------------------------------------------------------
-- 函数：safeSetValue(key, value) / safeGetValue(key)
-- 做什么：通过 pcall 安全调用 s_BridgeDB.SetValue / s_BridgeDB.GetValue（严格点号调用）。
-- 为什么：
--   1. 原生《文明5》C++ Modding.OpenUserData 句柄在并发写锁冲突时可能抛出异常，
--      pcall 隔离确保通信故障绝不崩溃游戏帧循环（红线 I-05 / 风险 R-01）；
--   2. 原生 Civ5 C++ SetValue 成功时无返回值（即 nil），因此仅在 pcall 报错或显式
--      返回 false 时判失败，避免真机将正常写入误判为失败。
-- 输入：key（非空字符串）、value（待写入值）。
-- 输出：safeSetValue 返回 boolean；safeGetValue 返回 (value, ok: boolean)。
-- -----------------------------------------------------------------------------
local function safeSetValue(key, value)
    if s_BridgeDB == nil or type(key) ~= "string" or key == "" then
        return false
    end
    local okLookup, fn = pcall(function()
        return s_BridgeDB.SetValue
    end)
    if not okLookup or type(fn) ~= "function" then
        errorLog("DB.SetValue method unavailable for key '" .. key .. "'")
        return false
    end
    local okCall, res = pcall(fn, key, value)
    if not okCall then
        errorLog("DB.SetValue('" .. key .. "') failed: " .. tostring(res))
        return false
    end
    if res == false then
        errorLog("DB.SetValue('" .. key .. "') returned false")
        return false
    end
    return true
end

local function safeGetValue(key)
    if s_BridgeDB == nil or type(key) ~= "string" or key == "" then
        return nil, false
    end
    local okLookup, fn = pcall(function()
        return s_BridgeDB.GetValue
    end)
    if not okLookup or type(fn) ~= "function" then
        errorLog("DB.GetValue method unavailable for key '" .. key .. "'")
        return nil, false
    end
    local okCall, val = pcall(fn, key)
    if not okCall then
        errorLog("DB.GetValue('" .. key .. "') failed: " .. tostring(val))
        return nil, false
    end
    return val, true
end

-- -----------------------------------------------------------------------------
-- 函数：readEngineHeartbeatScalars()
-- 做什么：通过只读引擎接口安全采集当前回合号、激活玩家 ID、是否活动回合及毫秒时钟。
-- 为什么：WriteHeartbeat 可能在引擎对象不完整或异常桩下被调用，逐项 pcall 保护保证
--         心跳写入零异常且零任何游戏写副作用（红线 I-01 / I-05）。
-- 输入：无。
-- 输出：(turn: number, activePlayer: number, isTurnActive: boolean, clockMs: number)。
-- -----------------------------------------------------------------------------
local function readEngineHeartbeatScalars()
    local turn = 0
    if Game ~= nil and type(Game.GetGameTurn) == "function" then
        local okTurn, vTurn = pcall(Game.GetGameTurn)
        if okTurn and isFiniteInteger(vTurn) then
            turn = vTurn
        end
    end

    local activePlayer = -1
    if Game ~= nil and type(Game.GetActivePlayer) == "function" then
        local okPid, vPid = pcall(Game.GetActivePlayer)
        if okPid and isFiniteInteger(vPid) then
            activePlayer = vPid
        end
    end

    local isTurnActive = false
    if activePlayer >= 0 and Players ~= nil then
        local okAct, vAct = pcall(function()
            local pPlayer = Players[activePlayer]
            if pPlayer == nil or pPlayer.IsTurnActive == nil then
                return false
            end
            return pPlayer:IsTurnActive() == true
        end)
        if okAct and vAct == true then
            isTurnActive = true
        end
    end

    local clockMs = 0
    if os ~= nil and type(os.clock) == "function" then
        local okClk, vClk = pcall(os.clock)
        if okClk and isFiniteNumber(vClk) and vClk >= 0 then
            clockMs = math.floor(vClk * 1000)
        end
    end

    return turn, activePlayer, isTurnActive, clockMs
end

-- -----------------------------------------------------------------------------
-- 第 3 节：8 个公开导出接口（X1 ~ X8）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- X1：CAB_ExternalIO.Initialize(onMessageCallback) -> (boolean, string | nil)
-- 做什么：校验底层配置/JSON/Modding 依赖与回调入参，打开 ModUserData SQLite 数据库，
--         读取库内已有 rpc_request_req_id 与 rpc_session_id 校准水位线后完成初始化。
-- 为什么：
--   1. 启动前对齐库内既有请求水位线与会话号，防止读档或热重载重复消费历史残留指令（I-04）；
--   2. 任一依赖缺失或 OpenUserData 失败时复位状态并返回结构化错误信息，不抛未捕获异常（I-05）。
-- 输入：onMessageCallback（function(reqObj: table) -> nil，由调度控制层注入）。
-- 输出：(ok: boolean, errMsg: string | nil)。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.Initialize(onMessageCallback)
    resetInternalState()

    if type(CAB_Config) ~= "table" then
        return false, "CAB_Config table is missing"
    end
    if type(CAB_Config.DB_NAME) ~= "string" or CAB_Config.DB_NAME == "" then
        return false, "CAB_Config.DB_NAME must be a non-empty string"
    end
    if not isFiniteInteger(CAB_Config.DB_VERSION) then
        return false, "CAB_Config.DB_VERSION must be a finite integer"
    end
    if not isFiniteNumber(CAB_Config.CHUNK_SIZE_BYTES) or CAB_Config.CHUNK_SIZE_BYTES <= 0 then
        return false, "CAB_Config.CHUNK_SIZE_BYTES must be a positive finite number"
    end

    if type(CAB_Json) ~= "table" or type(CAB_Json.Encode) ~= "function" or type(CAB_Json.Decode) ~= "function" then
        return false, "CAB_Json.Encode/Decode unavailable"
    end
    if type(Modding) ~= "table" or type(Modding.OpenUserData) ~= "function" then
        return false, "Modding.OpenUserData unavailable"
    end
    if type(onMessageCallback) ~= "function" then
        return false, "onMessageCallback must be a function"
    end

    local okOpen, dbOrErr = pcall(Modding.OpenUserData, CAB_Config.DB_NAME, CAB_Config.DB_VERSION)
    if not okOpen then
        local errMsg = "OpenUserData failed: " .. tostring(dbOrErr)
        errorLog(errMsg)
        return false, errMsg
    end
    if dbOrErr == nil then
        local errMsg = "OpenUserData failed: returned nil"
        errorLog(errMsg)
        return false, errMsg
    end

    local dbType = type(dbOrErr)
    if dbType ~= "table" and dbType ~= "userdata" then
        local errMsg = "OpenUserData failed: invalid handle type " .. dbType
        errorLog(errMsg)
        return false, errMsg
    end
    local okMethods, hasMethods = pcall(function()
        return type(dbOrErr.GetValue) == "function" and type(dbOrErr.SetValue) == "function"
    end)
    if not okMethods or hasMethods ~= true then
        local errMsg = "OpenUserData failed: handle missing GetValue/SetValue"
        errorLog(errMsg)
        return false, errMsg
    end

    s_BridgeDB = dbOrErr

    -- 校准既有水位线与会话标识，杜绝读档/重载重放历史 RPC 请求（红线 I-04）
    local rawReqId, okReq = safeGetValue("rpc_request_req_id")
    if okReq then
        s_LastProcessedReqId = parseNonNegInt(rawReqId) or 0
    else
        s_LastProcessedReqId = 0
    end

    local rawSession, okSess = safeGetValue("rpc_session_id")
    if okSess then
        s_ActiveSessionId = normalizeSessionId(rawSession)
    else
        s_ActiveSessionId = ""
    end

    s_OnMessageCallback = onMessageCallback
    s_Initialized = true

    debugLog(
        "Initialized DB=" .. CAB_Config.DB_NAME .. "-" .. tostring(CAB_Config.DB_VERSION)
            .. " lastReqId=" .. tostring(s_LastProcessedReqId)
            .. " session='" .. s_ActiveSessionId .. "'"
    )
    return true, nil
end

-- -----------------------------------------------------------------------------
-- X2：CAB_ExternalIO.WritePayload(key, strValue, forceChunked) -> boolean
-- 做什么：将任意字符串安全写入 SimpleValues；当字节长度超过 CHUNK_SIZE_BYTES 或显式
--         forceChunked == true 时，按 UTF-8 首字节边界对齐切分为 <key>#chunk_1..N，
--         再写 <key>#chunk_count 与主槽位 "__CHUNKED__:<byteLen>"；否则直写主槽位并置
--         <key>#chunk_count = "0"。
-- 为什么：
--   1. 规避 Civ5 底层可能存在的单字段定长截断；
--   2. 若切片右边界落在多字节 UTF-8 字符中间（下一字节处于 0x80..0xBF 续字节区间），
--      自动向前回退最多 3 字节对齐至完整字符边界，彻底根除外部 Python sqlite3 按默认
--      UTF-8 文本模式读片触发 OperationalError 的问题（红线 I-02）；
--   3. 若极端非法二进制流导致回退至 startIdx 之前，强制按 defaultEnd 切分确保推进（R-02）。
-- 输入：key（非空键名）、strValue（待写入字符串）、forceChunked（可选 boolean）。
-- 输出：boolean（全部槽位写入成功返回 true，任一失败立即中止返回 false）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.WritePayload(key, strValue, forceChunked)
    if s_BridgeDB == nil or type(key) ~= "string" or key == "" then
        return false
    end

    local s = (strValue == nil) and "" or tostring(strValue)
    local totalLen = #s
    local chunkSize = getChunkSize()

    if forceChunked == true or totalLen > chunkSize then
        if totalLen == 0 then
            if not safeSetValue(key .. "#chunk_1", "") then
                return false
            end
            if not safeSetValue(key .. "#chunk_count", "1") then
                return false
            end
            if not safeSetValue(key, "__CHUNKED__:0") then
                return false
            end
            return true
        end

        local startIdx = 1
        local chunkIdx = 0
        while startIdx <= totalLen do
            local defaultEnd = math.min(startIdx + chunkSize - 1, totalLen)
            local endIdx = defaultEnd

            if endIdx < totalLen then
                -- 检查下一字节是否为 UTF-8 续字节（10xxxxxx，即 128..191）；
                -- 若是则向前回退（最多 3 步）直至紧贴多字节字符首字节之前
                local backSteps = 0
                local nextByte = s:byte(endIdx + 1)
                while endIdx >= startIdx
                    and backSteps < 3
                    and nextByte ~= nil
                    and nextByte >= 128
                    and nextByte <= 191
                do
                    endIdx = endIdx - 1
                    backSteps = backSteps + 1
                    nextByte = s:byte(endIdx + 1)
                end

                -- 向前推进兜底守卫（R-02）：防止损坏二进制流导致零推进死循环
                if endIdx < startIdx then
                    endIdx = defaultEnd
                end
            end

            chunkIdx = chunkIdx + 1
            if not safeSetValue(key .. "#chunk_" .. tostring(chunkIdx), s:sub(startIdx, endIdx)) then
                return false
            end
            startIdx = endIdx + 1
        end

        if not safeSetValue(key .. "#chunk_count", tostring(chunkIdx)) then
            return false
        end
        if not safeSetValue(key, "__CHUNKED__:" .. tostring(totalLen)) then
            return false
        end
        return true
    end

    -- 单槽位写入顺序：先写新主值，再将 #chunk_count 置 "0" 覆盖可能存在的历史分片标记
    if not safeSetValue(key, s) then
        return false
    end
    if not safeSetValue(key .. "#chunk_count", "0") then
        return false
    end
    return true
end

-- -----------------------------------------------------------------------------
-- X3：CAB_ExternalIO.ReadPayload(key) -> string | nil
-- 做什么：从 SimpleValues 读取载荷；若 <key>#chunk_count 为正整数 N，则按序读取
--         <key>#chunk_1 .. N 并 table.concat 重组；否则直接读取并返回 <key>。
-- 为什么：屏蔽外部客户端写入大分片请求（如大载荷测试或长指令）的拼片细节；
--         若任一预期分片缺失或读取异常，返回 nil 而非静默拼接残缺串，确保上层准确判错。
-- 输入：key（非空键名）。
-- 输出：string | nil（读取成功返回完整字符串，不存在/缺片/异常返回 nil）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.ReadPayload(key)
    if s_BridgeDB == nil or type(key) ~= "string" or key == "" then
        return nil
    end

    local chunkCountRaw, okCnt = safeGetValue(key .. "#chunk_count")
    if not okCnt then
        return nil
    end

    local chunkCount = parsePositiveInt(chunkCountRaw)
    if chunkCount ~= nil then
        local parts = {}
        for i = 1, chunkCount do
            local chunkKey = key .. "#chunk_" .. tostring(i)
            local partVal, okPart = safeGetValue(chunkKey)
            if not okPart or partVal == nil then
                errorLog("ReadPayload('" .. key .. "') missing or unreadable chunk #" .. tostring(i) .. "/" .. tostring(chunkCount))
                return nil
            end
            parts[i] = (type(partVal) == "string") and partVal or tostring(partVal)
        end
        return table.concat(parts)
    end

    local rawVal, okVal = safeGetValue(key)
    if not okVal or rawVal == nil then
        return nil
    end
    return (type(rawVal) == "string") and rawVal or tostring(rawVal)
end

-- -----------------------------------------------------------------------------
-- X4：CAB_ExternalIO.PushTurnOverview(overviewTable, turnSeq) -> boolean
-- 做什么：将回合全局态势表序列化并分片落盘至 turn_overview_auto，随后写入原子发布序号
--         屏障 turn_overview_auto_seq，最后写入 TURN_SYNCED 心跳。
-- 为什么：严守红线 I-03 写入顺序（载荷全分片 -> 序号屏障 -> 心跳），任一前置步骤失败
--         即刻中止返回 false，绝不向外部暴露半截快照或虚假同步信号。
-- 输入：overviewTable（table，全局态势 DTO）、turnSeq（number，单调回合事件序号）。
-- 输出：boolean（全链路写入成功返回 true）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.PushTurnOverview(overviewTable, turnSeq)
    if s_BridgeDB == nil or type(overviewTable) ~= "table" then
        return false
    end
    if type(CAB_Json) ~= "table" or type(CAB_Json.Encode) ~= "function" then
        errorLog("PushTurnOverview failed: CAB_Json.Encode unavailable")
        return false
    end

    local okEnc, jsonStr = pcall(CAB_Json.Encode, overviewTable)
    if not okEnc or type(jsonStr) ~= "string" then
        errorLog("PushTurnOverview JSON encode failed: " .. tostring(jsonStr))
        return false
    end

    -- 步骤 1：先完成全部载荷与分片落盘
    if not CAB_ExternalIO.WritePayload("turn_overview_auto", jsonStr, false) then
        errorLog("PushTurnOverview failed while writing turn_overview_auto payload")
        return false
    end

    -- 步骤 2：写入原子发布序号屏障（严禁先于分片落盘，红线 I-03）
    local seqInt = normalizeNonNegInt(turnSeq)
    if not safeSetValue("turn_overview_auto_seq", tostring(seqInt)) then
        errorLog("PushTurnOverview failed while writing turn_overview_auto_seq")
        return false
    end

    -- 步骤 3：最后写入 TURN_SYNCED 心跳通知外部
    return CAB_ExternalIO.WriteHeartbeat("TURN_SYNCED", seqInt) == true
end

-- -----------------------------------------------------------------------------
-- X5：CAB_ExternalIO.WriteHeartbeat(statusStr, turnSeq) -> boolean
-- 做什么：采集 7 项只读桥接运行标量并编码为 JSON 对象写入 bridge_heartbeat 键。
-- 为什么：供外部 Python MCP Server 探测游戏是否存活、当前回合号、是否处于 AI 回合及
--         最新回合同步序号与已消费请求水位线。
-- 输入：statusStr（可选状态枚举串，缺省 "IDLE"）、turnSeq（可选非负整数序号）。
-- 输出：boolean（写入成功返回 true）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.WriteHeartbeat(statusStr, turnSeq)
    if s_BridgeDB == nil then
        return false
    end
    if type(CAB_Json) ~= "table" or type(CAB_Json.Encode) ~= "function" then
        errorLog("WriteHeartbeat failed: CAB_Json.Encode unavailable")
        return false
    end

    local turn, activePlayer, isTurnActive, clockMs = readEngineHeartbeatScalars()
    local status = "IDLE"
    if statusStr ~= nil then
        local s = tostring(statusStr)
        if s ~= "" then
            status = s
        end
    end
    local seqInt = normalizeNonNegInt(turnSeq)

    local hb = {
        __is_object = true,
        turn = turn,
        active_player = activePlayer,
        is_turn_active = isTurnActive,
        status = status,
        turn_seq = seqInt,
        last_req_id = s_LastProcessedReqId,
        clock_ms = clockMs,
    }

    local okEnc, encoded = pcall(CAB_Json.Encode, hb)
    if not okEnc or type(encoded) ~= "string" then
        errorLog("WriteHeartbeat JSON encode failed: " .. tostring(encoded))
        return false
    end

    return safeSetValue("bridge_heartbeat", encoded)
end

-- -----------------------------------------------------------------------------
-- X6：CAB_ExternalIO.SendRpcResponse(reqId, ok, dataTable, errMsg, forceChunked) -> boolean
-- 做什么：封装标准 RPC 响应信封，序列化并分片写入 rpc_response，全部落盘后最后一步写入
--         原子发布屏障 rpc_response_req_id。
-- 为什么：
--   1. 严守红线 I-03：仅当 rpc_response 全部槽位落盘成功后才更新 rpc_response_req_id，
--      确保外部客户端一见到匹配 req_id 即可读到 100% 完整的响应包；
--   2. 严守红线 I-05：若上层传入的 dataTable 含非法循环引用或超深嵌套导致 JSON 编码失败，
--      自动降级构造 ok=false 错误信封写回，防止外部无限超时死等。
-- 输入：reqId（请求序号）、ok（boolean）、dataTable（table | nil）、
--       errMsg（string | nil）、forceChunked（boolean | nil）。
-- 输出：boolean（响应与屏障均落盘成功返回 true）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.SendRpcResponse(reqId, ok, dataTable, errMsg, forceChunked)
    if s_BridgeDB == nil or reqId == nil then
        return false
    end
    if type(CAB_Json) ~= "table" or type(CAB_Json.Encode) ~= "function" then
        errorLog("SendRpcResponse failed: CAB_Json.Encode unavailable")
        return false
    end

    local resp = {
        __is_object = true,
        req_id = reqId,
        ok = (ok == true),
        data = dataTable,
        error = (errMsg ~= nil) and tostring(errMsg) or nil,
    }

    local okEnc, encoded = pcall(CAB_Json.Encode, resp)
    if not okEnc or type(encoded) ~= "string" then
        errorLog("SendRpcResponse JSON encode failed for req_id=" .. tostring(reqId) .. ": " .. tostring(encoded))
        local fallbackResp = {
            __is_object = true,
            req_id = reqId,
            ok = false,
            error = "JSON encode error: " .. tostring(encoded),
        }
        local okFb, fbEncoded = pcall(CAB_Json.Encode, fallbackResp)
        if not okFb or type(fbEncoded) ~= "string" then
            errorLog("SendRpcResponse fallback encode failed: " .. tostring(fbEncoded))
            return false
        end
        encoded = fbEncoded
    end

    -- 步骤 1：先完整写入 rpc_response（含分片与 #chunk_count）
    if not CAB_ExternalIO.WritePayload("rpc_response", encoded, forceChunked == true) then
        errorLog("SendRpcResponse failed while writing rpc_response payload for req_id=" .. tostring(reqId))
        return false
    end

    -- 步骤 2：最后一步写入原子发布屏障 rpc_response_req_id（红线 I-03）
    return safeSetValue("rpc_response_req_id", tostring(reqId))
end

-- -----------------------------------------------------------------------------
-- X7：CAB_ExternalIO.PollIncomingRequest() -> boolean
-- 做什么：由上层调度器在空闲帧节流调用，轻量探测会话切换与新请求到达；若发现新请求，
--         立即推进水位线、读取重组载荷、解码校验 JSON 对象并通过 pcall 触发注入回调。
-- 为什么：
--   1. 无新请求时仅执行 2 次轻量 GetValue（rpc_session_id + rpc_request_req_id），零开销；
--   2. 仅当 rpc_session_id 变更为新的非空字符串时重置 s_LastProcessedReqId = 0，绝不对旧客户端
--      凭 req_id 变小盲猜重置（D-04 / I-04）；
--   3. 处理前立即推进 s_LastProcessedReqId = reqId，并对空载荷/损坏 JSON/非对象 JSON/回调异常
--      就地兜底写回 ok=false 响应，彻底杜绝坏请求重复重试或崩溃帧循环（I-04 / I-05）。
-- 输入：无。
-- 输出：boolean（本次检测到并消费了一条新请求返回 true，无新请求或 DB 临时读失败返回 false）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.PollIncomingRequest()
    if not s_Initialized or s_BridgeDB == nil then
        return false
    end

    -- 1. 轻量检查外部会话切换（仅非空新会话标识触发水位线重置，红线 I-04）
    local rawIncomingSession, okSess = safeGetValue("rpc_session_id")
    if not okSess then
        return false
    end
    local incomingSession = normalizeSessionId(rawIncomingSession)
    if incomingSession ~= "" and incomingSession ~= s_ActiveSessionId then
        debugLog(
            "Session switched: '" .. s_ActiveSessionId .. "' -> '" .. incomingSession
                .. "', resetting last_processed_req_id to 0"
        )
        s_ActiveSessionId = incomingSession
        s_LastProcessedReqId = 0
    end

    -- 2. 轻量检查请求发布屏障
    local rawReqId, okReq = safeGetValue("rpc_request_req_id")
    if not okReq then
        return false
    end
    local reqId = parsePositiveInt(rawReqId)
    if reqId == nil or reqId <= s_LastProcessedReqId then
        return false
    end

    -- 3. 发现新请求：立即推进水位线，确保无论后续解码或回调是否报错均永不重复触发（I-04）
    s_LastProcessedReqId = reqId

    local rawJson = CAB_ExternalIO.ReadPayload("rpc_request")
    if rawJson == nil or rawJson == "" then
        CAB_ExternalIO.SendRpcResponse(reqId, false, nil, "Empty RPC request payload", false)
        return true
    end

    -- 4. JSON 解码与严格对象根类型校验（精准区分 {} 与 [] / null / 标量，D-04 / I-05）
    if type(CAB_Json) ~= "table" or type(CAB_Json.Decode) ~= "function" then
        CAB_ExternalIO.SendRpcResponse(reqId, false, nil, "JSON decode error: CAB_Json.Decode unavailable", false)
        return true
    end

    local okDecCall, reqObj, decodeErr = pcall(CAB_Json.Decode, rawJson)
    if not okDecCall then
        CAB_ExternalIO.SendRpcResponse(reqId, false, nil, "JSON decode error: " .. tostring(reqObj), false)
        return true
    end
    if decodeErr ~= nil then
        CAB_ExternalIO.SendRpcResponse(reqId, false, nil, "JSON decode error: " .. tostring(decodeErr), false)
        return true
    end
    if type(reqObj) ~= "table" or rawJson:match("^[ \t\r\n]*{") == nil then
        CAB_ExternalIO.SendRpcResponse(reqId, false, nil, "Invalid RPC request: expected JSON object", false)
        return true
    end

    -- 5. 规范化请求对象字段（保证 req_id 与 params 表始终完备）
    reqObj.req_id = reqId
    reqObj.params = (type(reqObj.params) == "table") and reqObj.params or {}
    if reqObj.session_id == nil and s_ActiveSessionId ~= "" then
        reqObj.session_id = s_ActiveSessionId
    end

    -- 6. 经 pcall 单向通知调度层，捕获未处理异常并兜底写回错返（I-05）
    if type(s_OnMessageCallback) == "function" then
        local okCb, cbErr = pcall(s_OnMessageCallback, reqObj)
        if not okCb then
            errorLog("Dispatcher callback error for req_id=" .. tostring(reqId) .. ": " .. tostring(cbErr))
            CAB_ExternalIO.SendRpcResponse(
                reqId,
                false,
                nil,
                "Dispatcher callback error: " .. tostring(cbErr),
                false
            )
        end
    else
        CAB_ExternalIO.SendRpcResponse(reqId, false, nil, "ExternalIO message callback is not registered", false)
    end

    return true
end

-- -----------------------------------------------------------------------------
-- X8：CAB_ExternalIO.GetRuntimeState() -> table
-- 做什么：返回外部交互层的纯只读浅拷贝诊断快照（带 __is_object = true）。
-- 为什么：遵循 D-04 与红线 I-06，提供完整运行期可观测性，同时严禁暴露 s_BridgeDB 句柄
--         或 s_OnMessageCallback 函数引用，避免外部误改内部私有状态。
-- 输入：无。
-- 输出：table（6 项基础标量字段 + __is_object = true）。
-- -----------------------------------------------------------------------------
function CAB_ExternalIO.GetRuntimeState()
    return {
        __is_object = true,
        initialized = (s_Initialized == true),
        db_connected = (s_BridgeDB ~= nil),
        last_processed_req_id = s_LastProcessedReqId,
        active_session_id = s_ActiveSessionId,
        has_callback = (type(s_OnMessageCallback) == "function"),
        chunk_size_bytes = getChunkSize(),
    }
end
