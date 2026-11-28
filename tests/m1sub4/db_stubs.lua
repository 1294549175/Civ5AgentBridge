-- =============================================================================
-- 文件：tests/m1sub4/db_stubs.lua
-- 职责：为 M1Sub4（CAB_Json + CAB_ExternalIO + 最终壳层合龙）离线测试提供：
--         1. 对接 Python 真实 sqlite3 SimpleValues(Name, Value) 临时库的
--            Modding.OpenUserData 句柄桩（无损 Hex 原始字节传输）；
--         2. 写操作顺序事件记录（S.db.writeLog，支撑 WP2 原子屏障红线 I-03 审计）；
--         3. 异常故障注入开关（S.faults，支撑红线 I-03 / I-05 故障注入测试）；
--         4. Python 跨语言验证快捷封装（S.pyDb，验证默认 text_factory=str 严格 UTF-8
--            与 text_factory=bytes 拼片还原）；
--         5. 最小只读引擎全局桩（Game / Players）与红线 I-01 禁止写接口动态陷阱守卫，
--            以及按需 include 加载器与静态源码禁令扫描助手。
-- 依赖：由 tests/run_m1sub4_tests.py 在 lupa.lua51 中加载，依赖 Python 注入的
--       __py_read_file 与 __py_db_* 桥接函数。
-- 对外契约：导出全局表 CAB_TEST_STUBS，零修改 tests/m1sub1~3/*。
-- =============================================================================

local S = {}
CAB_TEST_STUBS = S

-- -----------------------------------------------------------------------------
-- 第 1 节：256 项预构建 Hex 字节编解码表（Lua <-> Python 无损原始字节桥）
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

-- -----------------------------------------------------------------------------
-- 函数：S.toHex(str) / S.fromHex(hex)
-- 做什么：在 Lua 原始字节串与纯 ASCII 十六进制串之间执行无损双向转换。
-- 为什么：lupa 默认按 UTF-8 转换 Lua 字符串到 Python；经 Hex 桥接可无损传输含 \0
--         或故意构造的残缺 UTF-8 字节流，使真实 sqlite3 精确复现 Civ5 原生字节存储。
-- 输入：str（Lua 字符串）或 hex（偶数长度十六进制串）。
-- 输出：编码/解码后的字符串。
-- -----------------------------------------------------------------------------
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
-- 第 2 节：审计状态、故障开关、写序日志与日志捕获
-- -----------------------------------------------------------------------------

S.guard = {
    violations = {},
    missing = {},
    totalOpens = 0,
    totalDbWrites = 0,
    totalDbReads = 0,
}

S.prints = {}
S.includeCount = {}

-- 当前用例内写操作事件日志与最后打开的数据库句柄 ID
S.db = {
    writeLog = {},
    lastHandleId = nil,
    handlesByKey = {},
}

-- 当前用例内的故障注入开关（每次 beginCase 自动重置）
S.faults = {
    openFail = false,            -- true 时 OpenUserData 返回 nil
    openThrow = nil,             -- 非 nil 字符串时 OpenUserData 抛出 Lua error
    setThrowOnKey = nil,         -- 字符串或 {[key]=true} 表：写命中键时抛出错误
    setThrowOnCallIndex = nil,   -- 正整数：本用例第 N 次 SetValue 抛出错误
    setReturnNil = false,        -- true 时 SetValue 写库成功但返回 nil（模拟原生 Civ5 C++ 句柄）
    setReturnFalseOnKey = nil,   -- 字符串或 {[key]=true} 表：写命中键时显式返回 false
    getThrowOnKey = nil,         -- 字符串或 {[key]=true} 表：读命中键时抛出错误
    getThrowAll = nil,           -- 非 nil 字符串：所有 GetValue 均抛出错误
}

local s_CaseWriteSeq = 0
local s_CaseViolationsBefore = 0
local s_CaseMissingBefore = 0

local function resetFaults()
    S.faults.openFail = false
    S.faults.openThrow = nil
    S.faults.setThrowOnKey = nil
    S.faults.setThrowOnCallIndex = nil
    S.faults.setReturnNil = false
    S.faults.setReturnFalseOnKey = nil
    S.faults.getThrowOnKey = nil
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

-- -----------------------------------------------------------------------------
-- 函数：S.db.clearWriteLog / writeKeys / firstWriteIndex / lastWriteIndex
-- 做什么：清空或检索当前用例内向 SQLite SimpleValues 执行 SetValue 的先后顺序。
-- 为什么：WP2 需严格验证红线 I-03（分片全部落盘后才写 rpc_response_req_id、
--         turn_overview_auto 先于 turn_overview_auto_seq 与 bridge_heartbeat）。
-- -----------------------------------------------------------------------------
function S.db.clearWriteLog()
    S.db.writeLog = {}
    s_CaseWriteSeq = 0
end

function S.db.writeKeys()
    local keys = {}
    for i = 1, #S.db.writeLog do
        keys[i] = S.db.writeLog[i].key
    end
    return keys
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

-- 捕获被测模块 print 输出（失败时由用例框架附带打印，避免刷屏污染正常输出）
local s_OrigPrint = print
print = function(...)
    local parts = {}
    local n = select("#", ...)
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    S.prints[#S.prints + 1] = table.concat(parts, "\t")
end
S.rawPrint = s_OrigPrint

-- -----------------------------------------------------------------------------
-- 第 3 节：真实 SQLite3 Modding.OpenUserData 句柄桩与 Python 跨语言验证封装
-- -----------------------------------------------------------------------------

Modding = {}

-- -----------------------------------------------------------------------------
-- 函数：Modding.OpenUserData(dbName, dbVersion)
-- 做什么：模拟原生《文明5》Modding.OpenUserData，打开真实 Python sqlite3 临时库，
--         返回使用点号调用规范的句柄对象 { GetValue = fn, SetValue = fn }。
-- 为什么：原生引擎采用 db.GetValue(key) / db.SetValue(key, val) 点号调用；
--         若被测代码误用冒号传 self 表作 key，本桩将立即报错以尽早暴露调用缺陷。
-- 输入：dbName（数据库名字符串）、dbVersion（整数版本号）。
-- 输出：DB 句柄表或 nil（当 S.faults.openFail == true）。
-- -----------------------------------------------------------------------------
function Modding.OpenUserData(dbName, dbVersion)
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
            error("DB.SetValue: key 必须为非空字符串（请确认使用点号而非冒号调用）")
        end
        s_CaseWriteSeq = s_CaseWriteSeq + 1
        S.guard.totalDbWrites = S.guard.totalDbWrites + 1

        local entry = {
            seq = s_CaseWriteSeq,
            dbName = dbName,
            dbVersion = dbVersion,
            handleId = handleId,
            key = key,
            valueType = type(value),
            byteLen = (type(value) == "string") and #value or nil,
            ok = false,
            err = nil,
        }
        S.db.writeLog[#S.db.writeLog + 1] = entry

        if S.faults.setThrowOnCallIndex ~= nil and s_CaseWriteSeq == S.faults.setThrowOnCallIndex then
            entry.err = "Injected SetValue fault on call #" .. tostring(s_CaseWriteSeq)
            error(entry.err)
        end
        if matchesKeyFilter(S.faults.setThrowOnKey, key) then
            entry.err = "Injected SetValue fault on key: " .. key
            error(entry.err)
        end
        if matchesKeyFilter(S.faults.setReturnFalseOnKey, key) then
            entry.err = "Injected SetValue false return on key: " .. key
            return false
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
        if S.faults.setReturnNil == true then
            return nil
        end
        return true
    end

    function handle.GetValue(key)
        if type(key) ~= "string" or key == "" then
            error("DB.GetValue: key 必须为非空字符串（请确认使用点号而非冒号调用）")
        end
        S.guard.totalDbReads = S.guard.totalDbReads + 1

        if S.faults.getThrowAll ~= nil then
            error(tostring(S.faults.getThrowAll))
        end
        if matchesKeyFilter(S.faults.getThrowOnKey, key) then
            error("Injected GetValue fault on key: " .. key)
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

    -- 暴露底层句柄 ID 供测试代码直接调 S.pyDb 跨语言核验（业务代码严禁依赖此测试字段）
    handle._testHandleId = handleId
    handle._testDbPath = dbPath
    return handle
end

-- Python 侧真实 SQLite 跨语言核验快捷封装
S.pyDb = {}

function S.pyDb.readTextStrict(handleId, key)
    return __py_db_read_text_strict(handleId or S.db.lastHandleId, key)
end

function S.pyDb.readChunkedBytes(handleId, key)
    return __py_db_read_chunked_bytes(handleId or S.db.lastHandleId, key)
end

function S.pyDb.writeRaw(handleId, key, rawStr)
    return __py_db_set_value(handleId or S.db.lastHandleId, key, "string_hex", S.toHex(rawStr))
end

function S.pyDb.writePayload(handleId, key, rawStr, chunkSize, forceChunked)
    return __py_db_write_payload_py(
        handleId or S.db.lastHandleId,
        key,
        S.toHex(rawStr),
        chunkSize or 3000,
        forceChunked == true
    )
end

function S.pyDb.deleteKey(handleId, key)
    return __py_db_delete_key(handleId or S.db.lastHandleId, key)
end

function S.pyDb.listKeys(handleId)
    return __py_db_list_keys(handleId or S.db.lastHandleId)
end

-- 按正式外部 Python 客户端写入协议向真实 SQLite 写入一条完整 RPC 请求：
-- 先写可选 rpc_session_id，再分片写入 rpc_request，最后更新发布屏障 rpc_request_req_id
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

-- -----------------------------------------------------------------------------
-- 第 4 节：最小只读引擎全局桩与红线 I-01 禁止写接口动态陷阱守卫
-- -----------------------------------------------------------------------------

local s_GameState = {
    turn = 0,
    activePlayer = 0,
    turnActive = true,
}

local function recordViolation(owner, method)
    S.guard.violations[#S.guard.violations + 1] = {
        owner = owner,
        method = method,
    }
    error("红线 I-01 违规：外部交互/JSON 层禁止调用游戏写接口 " .. owner .. "." .. method .. "()")
end

local function makeWriteTrap(owner, method)
    return function()
        recordViolation(owner, method)
    end
end

Game = {
    GetGameTurn = function()
        return s_GameState.turn
    end,
    GetActivePlayer = function()
        return s_GameState.activePlayer
    end,
    -- 红线 I-01 禁止写接口陷阱
    SelectionListMove = makeWriteTrap("Game", "SelectionListMove"),
    SelectionListGameNetMessage = makeWriteTrap("Game", "SelectionListGameNetMessage"),
    SelectedCitiesGameNetMessage = makeWriteTrap("Game", "SelectedCitiesGameNetMessage"),
    CityPurchaseBuilding = makeWriteTrap("Game", "CityPurchaseBuilding"),
    CityPurchaseUnit = makeWriteTrap("Game", "CityPurchaseUnit"),
    CityPushOrder = makeWriteTrap("Game", "CityPushOrder"),
    HandleAction = makeWriteTrap("Game", "HandleAction"),
    DoControl = makeWriteTrap("Game", "DoControl"),
}

Network = {
    SendCityBuyPlot = makeWriteTrap("Network", "SendCityBuyPlot"),
    SendResearch = makeWriteTrap("Network", "SendResearch"),
    SendUpdatePolicies = makeWriteTrap("Network", "SendUpdatePolicies"),
}

UI = {
    SelectUnit = makeWriteTrap("UI", "SelectUnit"),
    SetInterfaceMode = makeWriteTrap("UI", "SetInterfaceMode"),
}

Players = {}
local function rebuildPlayers()
    Players = {}
    local activeId = s_GameState.activePlayer
    if activeId ~= nil then
        Players[activeId] = {
            IsTurnActive = function()
                return s_GameState.turnActive == true
            end,
            SetScriptData = makeWriteTrap("Player", "SetScriptData"),
        }
    end
end
rebuildPlayers()

function S.setGameState(opts)
    opts = opts or {}
    if opts.turn ~= nil then
        s_GameState.turn = opts.turn
    end
    if opts.activePlayer ~= nil then
        s_GameState.activePlayer = opts.activePlayer
    end
    if opts.turnActive ~= nil then
        s_GameState.turnActive = opts.turnActive
    end
    rebuildPlayers()
end

-- -----------------------------------------------------------------------------
-- 第 5 节：按需模块加载器（include）、静态源码红线扫描与用例生命周期钩子
-- -----------------------------------------------------------------------------

local function resolveModuleRelpath(name)
    local clean = tostring(name or ""):gsub("\\", "/")
    if clean:sub(-4) ~= ".lua" then
        clean = clean .. ".lua"
    end
    if clean:sub(1, 8) == "mod/Lua/" then
        return clean
    end
    if clean:sub(1, 4) == "Lua/" then
        return "mod/" .. clean
    end
    return "mod/Lua/" .. clean
end

function S.hasModule(name)
    local relpath = resolveModuleRelpath(name)
    local src = __py_read_file(relpath)
    return src ~= nil
end

function S.loadModule(name)
    local relpath = resolveModuleRelpath(name)
    local src, readErr = __py_read_file(relpath)
    if src == nil then
        error("include 找不到模块 " .. tostring(name) .. "（" .. tostring(readErr) .. "）")
    end
    S.includeCount[name] = (S.includeCount[name] or 0) + 1
    local chunk, compileErr = loadstring(src, "@" .. relpath)
    if chunk == nil then
        error("模块编译失败 " .. relpath .. "：" .. tostring(compileErr))
    end
    return chunk()
end

include = function(name)
    return S.loadModule(name)
end

-- -----------------------------------------------------------------------------
-- 函数：S.scanForbiddenTokens(relpath, forbiddenTokens)
-- 做什么：剔除 -- 整行注释后，检查源码代码行中是否包含禁令符号列表中的任一项。
-- 为什么：支撑红线 I-01 的离线静态源码审计，确保底层通信与 JSON 库零越层引用。
-- 输入：relpath（相对项目根路径）、forbiddenTokens（字符串数组）。
-- 输出：命中列表 hits（空表表示通过）。
-- -----------------------------------------------------------------------------
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

function S.reloadExternalIO()
    CAB_ExternalIO = nil
    if S.hasModule("CAB_ExternalIO") then
        S.loadModule("CAB_ExternalIO")
    end
end

function S.beginCase()
    __py_db_reset()
    S.db.writeLog = {}
    S.db.lastHandleId = nil
    S.db.handlesByKey = {}
    s_CaseWriteSeq = 0
    resetFaults()
    S.prints = {}
    s_GameState.turn = 0
    s_GameState.activePlayer = 0
    s_GameState.turnActive = true
    rebuildPlayers()
    -- 复位基础配置与外部交互模块私有状态，防止单测改动泄漏至后续用例
    S.loadModule("CAB_Config")
    if CAB_Json == nil then
        S.loadModule("Civ5AgentBridgeJson")
    end
    if S.hasModule("CAB_ExternalIO") then
        S.reloadExternalIO()
    end
    s_CaseViolationsBefore = #S.guard.violations
    s_CaseMissingBefore = #S.guard.missing
end

function S.endCase()
    local newViolations = #S.guard.violations - s_CaseViolationsBefore
    local newMissing = #S.guard.missing - s_CaseMissingBefore
    if newViolations > 0 or newMissing > 0 then
        return false, string.format("本用例触发红线违规 %d 次，桩未实现方法 %d 次", newViolations, newMissing)
    end
    return true, ""
end

-- 预加载稳定基础模块 CAB_Config 与 Civ5AgentBridgeJson，供后续用例默认使用
S.loadModule("CAB_Config")
S.loadModule("Civ5AgentBridgeJson")
