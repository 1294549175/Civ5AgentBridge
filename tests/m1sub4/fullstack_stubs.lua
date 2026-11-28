-- =============================================================================
-- 文件：tests/m1sub4/fullstack_stubs.lua
-- 职责：为 M1Sub4 WP3（五模块 + Civ5AgentBridgeUI.lua 最终壳层合龙）离线全栈联调
--       提供独立沙箱底座：
--         1. 只读复用已验收的 tests/m1sub3/engine_stubs.lua 完整 BNW v1.0.3.279
--            有状态引擎世界桩（零修改 tests/m1sub3/*，严守 D-01）；
--         2. 在引擎世界之上叠加对接 Python 真实 sqlite3 SimpleValues 临时库的
--            Modding.OpenUserData 句柄桩（无损 Hex 原始字节桥 + 故障注入 + 写序日志）；
--         3. 提供 Civ5 UI 上下文宿主桩（Controls / Mouse / Events.ActivePlayerTurnStart /
--            Events.ActivePlayerTurnEnd / ContextPtr）与帧推进/点击/事件触发助手；
--         4. 卸载 engine_stubs.lua 预装的模拟 CAB_ExternalIO，确保由 Civ5AgentBridgeUI.lua
--            冷加载并驱动全部 6 个正式 Lua 业务模块。
-- 依赖：由 tests/run_m1sub4_tests.py 阶段 4 在独立 lupa.lua51 沙箱中加载。
-- 对外契约：复用并扩充全局表 CAB_TEST_STUBS（S.db / S.faults / S.pyDb / S.ui /
--           S.resetFullStack / S.bootUI / S.scanForbiddenTokens）。
-- =============================================================================

-- 1. 只读加载已验收的 BNW 有状态引擎世界桩
do
    local engineStubSrc, readErr = __py_read_file("tests/m1sub3/engine_stubs.lua")
    if engineStubSrc == nil then
        error("无法只读加载 tests/m1sub3/engine_stubs.lua：" .. tostring(readErr))
    end
    local chunk, compileErr = loadstring(engineStubSrc, "@tests/m1sub3/engine_stubs.lua")
    if chunk == nil then
        error("tests/m1sub3/engine_stubs.lua 编译失败：" .. tostring(compileErr))
    end
    chunk()
end

local S = CAB_TEST_STUBS

-- 彻底清除 engine_stubs.lua 预装的模拟 CAB_ExternalIO，避免遮蔽正式实现
CAB_ExternalIO = nil

-- -----------------------------------------------------------------------------
-- 第 1 节：256 项 Hex 字节桥（Lua <-> Python 真实 SQLite3 无损字节传输）
-- -----------------------------------------------------------------------------

local HEX_OF_CHAR = {}
local CHAR_OF_HEX = {}
for b = 0, 255 do
    local ch = string.char(b)
    local h = string.format("%02x", b)
    HEX_OF_CHAR[ch] = h
    CHAR_OF_HEX[h] = ch
    CHAR_OF_HEX[h:upper()] = ch
end

function S.toHex(str)
    if str == nil or str == "" then
        return ""
    end
    return (str:gsub(".", HEX_OF_CHAR))
end

function S.fromHex(hex)
    if hex == nil or hex == "" then
        return ""
    end
    return (hex:gsub("..", CHAR_OF_HEX))
end

-- -----------------------------------------------------------------------------
-- 第 2 节：真实 SQLite3 DB 审计、故障开关与 Modding.OpenUserData 实现
-- -----------------------------------------------------------------------------

S.guard.totalOpens = 0
S.guard.totalDbWrites = 0
S.guard.totalDbReads = 0

S.db = {
    writeLog = {},
    lastHandleId = nil,
    handlesByKey = {},
}

S.faults = {
    openFail = false,
    openThrow = nil,
    setThrowOnKey = nil,
    getThrowAll = nil,
}

local s_CaseWriteSeq = 0

local function resetFaults()
    S.faults.openFail = false
    S.faults.openThrow = nil
    S.faults.setThrowOnKey = nil
    S.faults.getThrowAll = nil
end

local function matchesKeyFilter(filter, key)
    if filter == nil then
        return false
    end
    if type(filter) == "string" then
        return filter == key
    end
    if type(filter) == "table" then
        return filter[key] == true
    end
    return false
end

function S.db.clearWriteLog()
    S.db.writeLog = {}
    s_CaseWriteSeq = 0
end

function S.db.firstWriteIndex(targetKey)
    for i = 1, #S.db.writeLog do
        if S.db.writeLog[i].key == targetKey then
            return i
        end
    end
    return nil
end

function S.db.lastWriteIndex(targetKey)
    for i = #S.db.writeLog, 1, -1 do
        if S.db.writeLog[i].key == targetKey then
            return i
        end
    end
    return nil
end

local function makeRealModding()
    local mod = {}

    function mod.OpenUserData(dbName, dbVersion)
        S.guard.totalOpens = S.guard.totalOpens + 1
        if S.faults.openThrow ~= nil then
            error(tostring(S.faults.openThrow))
        end
        if S.faults.openFail == true then
            return nil
        end
        if type(dbName) ~= "string" or dbName == "" then
            error("Modding.OpenUserData: dbName 必须为非空字符串")
        end
        if type(dbVersion) ~= "number" then
            error("Modding.OpenUserData: dbVersion 必须为数字")
        end

        local handleId, dbPath = __py_db_open(dbName, dbVersion)
        S.db.lastHandleId = handleId
        S.db.handlesByKey[tostring(dbName) .. ":" .. tostring(dbVersion)] = handleId

        local handle = {}

        function handle.SetValue(key, value)
            if type(key) ~= "string" or key == "" then
                error("DB.SetValue: key 必须为非空字符串")
            end
            s_CaseWriteSeq = s_CaseWriteSeq + 1
            S.guard.totalDbWrites = S.guard.totalDbWrites + 1

            local entry = {
                seq = s_CaseWriteSeq,
                key = key,
                ok = false,
            }
            S.db.writeLog[#S.db.writeLog + 1] = entry

            if matchesKeyFilter(S.faults.setThrowOnKey, key) then
                error("Injected SetValue fault on key: " .. key)
            end

            local vtype = type(value)
            if value == nil then
                __py_db_set_value(handleId, key, "nil", nil)
            elseif vtype == "string" then
                __py_db_set_value(handleId, key, "string_hex", S.toHex(value))
            elseif vtype == "number" then
                __py_db_set_value(handleId, key, "number", value)
            elseif vtype == "boolean" then
                __py_db_set_value(handleId, key, "boolean", value)
            else
                __py_db_set_value(handleId, key, "string_hex", S.toHex(tostring(value)))
            end
            entry.ok = true
            return true
        end

        function handle.GetValue(key)
            if type(key) ~= "string" or key == "" then
                error("DB.GetValue: key 必须为非空字符串")
            end
            S.guard.totalDbReads = S.guard.totalDbReads + 1
            if S.faults.getThrowAll ~= nil then
                error(tostring(S.faults.getThrowAll))
            end

            local vtype, payload = __py_db_get_value(handleId, key)
            if vtype == "nil" then
                return nil
            elseif vtype == "string_hex" then
                return S.fromHex(payload)
            elseif vtype == "number" then
                return payload
            end
            return payload
        end

        handle._testHandleId = handleId
        handle._testDbPath = dbPath
        return handle
    end

    return mod
end

-- Python 侧跨语言读写封装（模拟真实外部 Python 客户端操作 SimpleValues）
S.pyDb = {}

function S.pyDb.readTextStrict(handleId, key)
    return __py_db_read_text_strict(handleId or S.db.lastHandleId, key)
end

function S.pyDb.readChunkedBytes(handleId, key)
    return __py_db_read_chunked_bytes(handleId or S.db.lastHandleId, key)
end

function S.pyDb.sendRpcRequest(handleId, reqId, rawJsonStr, sessionId, chunkSize, forceChunked)
    local hid = handleId or S.db.lastHandleId
    if sessionId ~= nil then
        __py_db_set_value(hid, "rpc_session_id", "string_hex", S.toHex(tostring(sessionId)))
    end
    if rawJsonStr ~= nil then
        __py_db_write_payload_py(
            hid,
            "rpc_request",
            S.toHex(tostring(rawJsonStr)),
            chunkSize or 3000,
            forceChunked == true
        )
    else
        __py_db_delete_key(hid, "rpc_request")
        __py_db_delete_key(hid, "rpc_request#chunk_count")
    end
    __py_db_set_value(hid, "rpc_request_req_id", "string_hex", S.toHex(tostring(reqId)))
end

function S.pyDb.sendRpcMethod(handleId, reqId, method, params, sessionId)
    local reqTable = {
        __is_object = true,
        method = method,
        params = params or { __is_object = true },
    }
    local raw = CAB_Json.Encode(reqTable)
    S.pyDb.sendRpcRequest(handleId, reqId, raw, sessionId)
end

function S.pyDb.readRpcBarrier(handleId)
    local ok, val = S.pyDb.readTextStrict(handleId, "rpc_response_req_id")
    if not ok or val == nil then
        return nil
    end
    return tonumber(val)
end

function S.pyDb.readRpcResponse(handleId)
    local hid = handleId or S.db.lastHandleId
    local barrier = S.pyDb.readRpcBarrier(hid)
    local okRead, rawJson, rawLen, chunkCount = S.pyDb.readChunkedBytes(hid, "rpc_response")
    if not okRead or rawJson == nil then
        return barrier, nil, rawJson, chunkCount, rawLen
    end
    local pyOk, pyErr = __py_json_loads_check(rawJson)
    if not pyOk then
        error("Python json.loads 校验 rpc_response 失败：" .. tostring(pyErr))
    end
    local obj, decErr = CAB_Json.Decode(rawJson)
    if decErr ~= nil then
        error("CAB_Json.Decode 解析 rpc_response 失败：" .. tostring(decErr))
    end
    return barrier, obj, rawJson, chunkCount, rawLen
end

function S.pyDb.readTurnOverview(handleId)
    local hid = handleId or S.db.lastHandleId
    local okSeq, seqVal = S.pyDb.readTextStrict(hid, "turn_overview_auto_seq")
    local seqNum = (okSeq and seqVal ~= nil) and tonumber(seqVal) or nil
    local okRead, rawJson, rawLen, chunkCount = S.pyDb.readChunkedBytes(hid, "turn_overview_auto")
    if not okRead or rawJson == nil then
        return seqNum, nil, rawJson, chunkCount, rawLen
    end
    local pyOk, pyErr = __py_json_loads_check(rawJson)
    if not pyOk then
        error("Python json.loads 校验 turn_overview_auto 失败：" .. tostring(pyErr))
    end
    local obj, decErr = CAB_Json.Decode(rawJson)
    if decErr ~= nil then
        error("CAB_Json.Decode 解析 turn_overview_auto 失败：" .. tostring(decErr))
    end
    return seqNum, obj, rawJson, chunkCount, rawLen
end

function S.pyDb.readHeartbeat(handleId)
    local hid = handleId or S.db.lastHandleId
    local okRead, rawJson = S.pyDb.readTextStrict(hid, "bridge_heartbeat")
    if not okRead or rawJson == nil then
        return nil, rawJson
    end
    local pyOk, pyErr = __py_json_loads_check(rawJson)
    if not pyOk then
        error("Python json.loads 校验 bridge_heartbeat 失败：" .. tostring(pyErr))
    end
    local obj, decErr = CAB_Json.Decode(rawJson)
    if decErr ~= nil then
        error("CAB_Json.Decode 解析 bridge_heartbeat 失败：" .. tostring(decErr))
    end
    return obj, rawJson
end

-- -----------------------------------------------------------------------------
-- 第 3 节：Civ5 UI 上下文宿主桩（Controls / Mouse / Events / ContextPtr）
-- -----------------------------------------------------------------------------

S.ui = {
    currentLabel = "Agent Bridge: Ready",
    labelHistory = {},
    syncButtonCallbacks = {},
    turnStartListeners = {},
    turnEndListeners = {},
    updateCallbacks = {},
    activeUpdateFn = nil,
}

local function installUiHostGlobals()
    Mouse = {
        eLClick = 1,
    }

    Controls = {
        BridgeStatusLabel = {
            SetText = function(_, text)
                local s = tostring(text or "")
                S.ui.currentLabel = s
                S.ui.labelHistory[#S.ui.labelHistory + 1] = s
            end,
        },
        BridgeSyncButton = {
            RegisterCallback = function(_, mouseEvent, fn)
                if mouseEvent ~= Mouse.eLClick then
                    error("BridgeSyncButton:RegisterCallback 期望 Mouse.eLClick")
                end
                S.ui.syncButtonCallbacks[#S.ui.syncButtonCallbacks + 1] = fn
            end,
        },
    }

    ContextPtr = {
        SetUpdate = function(_, fn)
            S.ui.updateCallbacks[#S.ui.updateCallbacks + 1] = fn
            S.ui.activeUpdateFn = fn
        end,
        ClearUpdate = function(_)
            S.ui.activeUpdateFn = nil
        end,
    }

    if Events ~= nil then
        Events.ActivePlayerTurnStart = {
            Add = function(fn)
                S.ui.turnStartListeners[#S.ui.turnStartListeners + 1] = fn
            end,
        }
        Events.ActivePlayerTurnEnd = {
            Add = function(fn)
                S.ui.turnEndListeners[#S.ui.turnEndListeners + 1] = fn
            end,
        }
    end
end

function S.ui.reset()
    S.ui.currentLabel = "Agent Bridge: Ready"
    S.ui.labelHistory = {}
    S.ui.syncButtonCallbacks = {}
    S.ui.turnStartListeners = {}
    S.ui.turnEndListeners = {}
    S.ui.updateCallbacks = {}
    S.ui.activeUpdateFn = nil
    installUiHostGlobals()
end

function S.ui.clickSyncButton()
    for _, fn in ipairs(S.ui.syncButtonCallbacks) do
        fn()
    end
end

function S.ui.fireTurnStart()
    for _, fn in ipairs(S.ui.turnStartListeners) do
        fn()
    end
end

function S.ui.fireTurnEnd()
    for _, fn in ipairs(S.ui.turnEndListeners) do
        fn()
    end
end

function S.ui.stepFrames(count, dt)
    local n = count or 1
    local step = dt or 0.20
    if type(S.ui.activeUpdateFn) ~= "function" then
        error("ContextPtr:SetUpdate 尚未注册帧更新回调，无法推进帧循环")
    end
    for _ = 1, n do
        S.ui.activeUpdateFn(step)
    end
end

-- -----------------------------------------------------------------------------
-- 第 4 节：包装 S.newWorld、全栈冷启动助手、静态扫描与用例边界管理
-- -----------------------------------------------------------------------------

local s_OrigNewWorld = S.newWorld
function S.newWorld(opts)
    local w = s_OrigNewWorld(opts)
    Modding = makeRealModding()
    installUiHostGlobals()
    return w
end

function S.clearAllBridgeModules()
    CAB_Config = nil
    CAB_Json = nil
    CAB_JsonEncode = nil
    CAB_JsonDecode = nil
    CAB_JSON_NULL = nil
    CAB_ExternalIO = nil
    CAB_Collector = nil
    CAB_Executor = nil
    CAB_Dispatcher = nil
    S.includeOrder = {}
    S.includeCount = {}
end

function S.resetFullStack(worldOpts)
    __py_db_reset()
    S.db.writeLog = {}
    S.db.lastHandleId = nil
    S.db.handlesByKey = {}
    s_CaseWriteSeq = 0
    resetFaults()
    S.clearAllBridgeModules()
    S.ui.reset()
    return S.newWorld(worldOpts)
end

function S.bootUI()
    include("Civ5AgentBridgeUI")
    return S.db.lastHandleId
end

function S.scanForbiddenTokens(relpath, forbiddenTokens)
    local src, readErr = __py_read_file(relpath)
    if src == nil then
        error("无法读取待扫查源码 " .. tostring(relpath) .. "：" .. tostring(readErr))
    end
    local codeLines = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do
        if not line:match("^%s*%-%-") then
            codeLines[#codeLines + 1] = line
        end
    end
    local codeOnly = table.concat(codeLines, "\n")
    local hits = {}
    for _, token in ipairs(forbiddenTokens) do
        if codeOnly:find(token, 1, true) ~= nil then
            hits[#hits + 1] = token
        end
    end
    return hits
end

local ALLOWED_FULLSTACK_GLOBALS = {
    CAB_Config = true,
    CAB_Json = true,
    CAB_JsonEncode = true,
    CAB_JsonDecode = true,
    CAB_JSON_NULL = true,
    CAB_ExternalIO = true,
    CAB_Collector = true,
    CAB_Executor = true,
    CAB_Dispatcher = true,
}

local function snapshotGlobalNames()
    local names = {}
    for name in pairs(_G) do
        names[name] = true
    end
    return names
end

-- 预装一次 UI 宿主与真实 Modding，确保 beginCase 捕获全局基线已包含宿主表
S.resetFullStack()

function S.beginCase()
    S.worlds = {}
    S.prints = {}
    S.resetFullStack()
    S.marks = {
        violations = #S.guard.violations,
        missing = #S.guard.missing,
        globals = snapshotGlobalNames(),
    }
end

function S.endCase()
    local problems = {}
    for i = S.marks.violations + 1, #S.guard.violations do
        local record = S.guard.violations[i]
        table.insert(problems, "触发红线守卫违规：" .. record.owner .. "." .. record.method .. "()")
    end
    for i = S.marks.missing + 1, #S.guard.missing do
        local record = S.guard.missing[i]
        table.insert(problems, "调用了桩未实现的方法：" .. record.owner .. "." .. record.method .. "()")
    end
    local addedGlobals = {}
    for name in pairs(snapshotGlobalNames()) do
        if not S.marks.globals[name] and not ALLOWED_FULLSTACK_GLOBALS[name] then
            table.insert(addedGlobals, name)
        end
    end
    if #addedGlobals > 0 then
        table.sort(addedGlobals)
        table.insert(problems, "用例期间新增了非法全局变量：" .. table.concat(addedGlobals, ", "))
    end
    return #problems == 0, table.concat(problems, "\n")
end
