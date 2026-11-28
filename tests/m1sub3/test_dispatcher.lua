-- =============================================================================
-- 文件：tests/m1sub3/test_dispatcher.lua
-- 职责：M1Sub3（mod/Lua/CAB_Dispatcher.lua）离线四模块联调验收测试集。
-- 依赖：由 tests/run_m1sub3_tests.py 在加载 tests/m1sub3/engine_stubs.lua 后执行。
-- 对外契约：返回汇总表 { passed, failed, skipped, guardViolations, guardMissing,
--           totalWrites, extOverviewCount, extHeartbeatCount, extRpcResponseCount,
--           extPollCount, cases = {...} }。
--
-- 结构划分（对齐《docs/M1/M1Sub3/M1Sub3工作计划.md》WP1 ~ WP3）：
--   第 1 节  用例注册与断言工具库；
--   第 2 节  WP1 静态红线、守卫式加载、契约桩自检、双态初始化与生命周期用例（T-00 ~ T-10）；
--   第 3 节  WP2 14 项 IPC 路由、非活动回合门控白名单、信封保真与挂起槽位用例（T-11 ~ T-17）；
--   第 4 节  WP3 5 类异步帧结算、超时兜底、抢占刷写、时钟防护、异常自愈与节流用例（T-18 ~ T-24）；
--   第 5 节  运行器与收尾总检（FW-01）。
-- =============================================================================

local S = CAB_TEST_STUBS
local cases = {}

-- -----------------------------------------------------------------------------
-- 第 1 节：用例注册与断言工具库
-- -----------------------------------------------------------------------------

local function test(id, title, fn)
    table.insert(cases, { id = id, title = title, fn = fn })
end

local function skip(reason)
    error({ __skip = true, reason = reason })
end

local function fail(msg)
    error(msg .. "\n" .. debug.traceback(), 2)
end

local function show(v)
    local kind = type(v)
    if kind == "string" then
        return '"' .. v .. '"'
    elseif kind == "table" then
        if v._kind ~= nil then return S.describe(v) end
        local parts = {}
        if v[1] ~= nil then
            for i = 1, #v do parts[i] = show(v[i]) end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        for k, item in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. show(item)
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function isSame(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if a._kind ~= nil or b._kind ~= nil then return false end
    for k, item in pairs(a) do
        if not isSame(item, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

local function same(actual, expected, msg)
    if not isSame(actual, expected) then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

local function truthy(actual, msg)
    if actual ~= true then
        fail(msg .. "：应为 true，实际 " .. show(actual))
    end
end

local function falsy(actual, msg)
    if actual ~= false then
        fail(msg .. "：应为 false，实际 " .. show(actual))
    end
end

local function isNil(actual, msg)
    if actual ~= nil then
        fail(msg .. "：应为 nil，实际 " .. show(actual))
    end
end

local function notNil(actual, msg)
    if actual == nil then
        fail(msg .. "：不应为 nil")
    end
end

local function isType(actual, typeName, msg)
    if type(actual) ~= typeName then
        fail(msg .. "：类型应为 " .. typeName .. "，实际 " .. type(actual))
    end
end

local function contains(str, needle, msg)
    if type(str) ~= "string" or str:find(needle, 1, true) == nil then
        fail(msg .. "：期望包含 " .. show(needle) .. "，实际 " .. show(str))
    end
end

local function snapshotIncludes()
    local snapshot = {}
    for name, n in pairs(S.includeCount) do snapshot[name] = n end
    return snapshot
end

local function includeDiff(before)
    local diff = {}
    for name, n in pairs(S.includeCount) do
        local added = n - (before[name] or 0)
        if added > 0 then diff[name] = added end
    end
    return diff
end

local function globalSnapshot()
    local names = {}
    for name in pairs(_G) do names[name] = true end
    return names
end

local function newGlobals(snapshot)
    local added = {}
    for name in pairs(_G) do
        if not snapshot[name] then added[#added + 1] = name end
    end
    table.sort(added)
    return added
end

local function countPattern(src, pattern)
    local count = 0
    for _ in src:gmatch(pattern) do
        count = count + 1
    end
    return count
end

local function makeUiRecorder()
    local log = {}
    local fn = function(text)
        table.insert(log, text)
    end
    return fn, log
end

local TWO_PLAYERS = {
    { id = 0, team = 0, civ = "Rome", gold = 500, faith = 300, turnActive = true },
    { id = 1, team = 1, civ = "Carthage", gold = 200, faith = 100, turnActive = false },
}

-- -----------------------------------------------------------------------------
-- 第 2 节：WP1 静态红线、守卫式加载、契约桩自检、初始化与生命周期用例（T-00 ~ T-11）
-- -----------------------------------------------------------------------------

test("T-00", "WP1 静态红线（S-01）、守卫式按需 include（D-02）与精确 7 项导出（A-01）", function()
    if not S.hasModule("CAB_Dispatcher") then
        skip("mod/Lua/CAB_Dispatcher.lua 尚未创建")
    end

    -- 1. 静态源码红线扫查（仅检查非注释代码行）
    local src, readErr = __py_read_file("mod/Lua/CAB_Dispatcher.lua")
    notNil(src, "应能读取 CAB_Dispatcher.lua 源码：" .. tostring(readErr))

    local codeLines = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do
        if not line:match("^%s*%-%-") then
            codeLines[#codeLines + 1] = line
        end
    end
    local codeOnly = table.concat(codeLines, "\n")

    local forbiddenTokens = {
        "OpenUserData",
        "SimpleValues",
        "CAB_Json",
        "Civ5AgentBridgeJson",
        "SelectionListMove",
        "SelectionListGameNetMessage",
        "SelectedCitiesGameNetMessage",
        "CityPurchase",
        "CityPushOrder",
        "SendCityBuyPlot",
        "SendResearch",
        "SendUpdatePolicies",
        "HandleAction",
        "DoControl",
        "SelectUnit",
        "SetInterfaceMode",
        "SetScriptData",
        "CanMoveOrAttackInto",
        "AirRaidCore",
    }
    for _, token in ipairs(forbiddenTokens) do
        isNil(codeOnly:find(token, 1, true), "红线 S-01：非注释代码严禁出现 " .. token)
    end

    -- 校验恰好 4 处守卫式 include
    eq(countPattern(codeOnly, 'include%s*%(%s*"CAB_Config"%s*%)'), 1, "应恰好 include('CAB_Config') 一次")
    eq(countPattern(codeOnly, 'include%s*%(%s*"CAB_InfoCollector"%s*%)'), 1, "应恰好 include('CAB_InfoCollector') 一次")
    eq(countPattern(codeOnly, 'include%s*%(%s*"CAB_TaskExecutor"%s*%)'), 1, "应恰好 include('CAB_TaskExecutor') 一次")
    eq(countPattern(codeOnly, 'include%s*%(%s*"CAB_ExternalIO"%s*%)'), 1, "应恰好 include('CAB_ExternalIO') 一次")
    eq(countPattern(codeOnly, "include%s*%("), 4, "源码总 include 调用数应恰好为 4")

    -- 2. 冷加载四模块验证：清除前序全局（保留预注入 CAB_ExternalIO），由 CAB_Dispatcher 按需拉起
    CAB_Config = nil
    CAB_Collector = nil
    CAB_Executor = nil
    CAB_Dispatcher = nil

    local globalsBefore = globalSnapshot()
    local includesBefore = snapshotIncludes()

    local okLoad, loadErr = pcall(include, "CAB_Dispatcher")
    truthy(okLoad, "include('CAB_Dispatcher') 应成功，实际报错：" .. tostring(loadErr))

    local diff = includeDiff(includesBefore)
    eq(diff.CAB_Dispatcher, 1, "CAB_Dispatcher 应加载 1 次")
    truthy((diff.CAB_Config or 0) >= 1, "应按需加载 CAB_Config")
    truthy((diff.CAB_InfoCollector or 0) >= 1, "应按需加载 CAB_InfoCollector")
    eq(diff.CAB_TaskExecutor, 1, "应按需加载 CAB_TaskExecutor 1 次")
    isNil(diff.CAB_ExternalIO, "预注入 CAB_ExternalIO 存在时不得重复 include('CAB_ExternalIO')")

    local allowed = {
        CAB_Config = true,
        CAB_Collector = true,
        CAB_Executor = true,
        CAB_ExternalIO = true,
        CAB_Dispatcher = true,
    }
    for _, name in ipairs(newGlobals(globalsBefore)) do
        truthy(allowed[name] == true, "CAB_Dispatcher 不得新增非法全局变量 " .. name)
    end

    -- 3. 精确 7 项公开导出锁定（A-01）
    isType(CAB_Dispatcher, "table", "应导出全局表 CAB_Dispatcher")
    local expectedExports = {
        "Initialize",
        "OnActivePlayerTurnStart",
        "OnActivePlayerTurnEnd",
        "OnManualSyncClicked",
        "OnExternalRequestReceived",
        "OnFrameUpdate",
        "GetRuntimeState",
    }
    local expectedSet = {}
    for _, fnName in ipairs(expectedExports) do
        expectedSet[fnName] = true
        isType(CAB_Dispatcher[fnName], "function", "A-01：应导出公开函数 CAB_Dispatcher." .. fnName)
    end
    local actualCount = 0
    for k, v in pairs(CAB_Dispatcher) do
        actualCount = actualCount + 1
        truthy(expectedSet[k] == true, "A-01：CAB_Dispatcher 不得包含未规划导出键 " .. tostring(k))
        isType(v, "function", "A-01：CAB_Dispatcher." .. tostring(k) .. " 必须为函数")
    end
    eq(actualCount, 7, "A-01：CAB_Dispatcher 导出函数总数必须精确为 7")
end)

test("T-01", "守卫式按需 include 防重复重置验证：四模块已就绪时重载零额外 include（D-02）", function()
    S.reloadDispatcher()
    truthy(CAB_Executor.Initialize(), "前置 CAB_Executor.Initialize() 应成功")

    local includesBefore = snapshotIncludes()
    S.reloadDispatcher()
    local diff = includeDiff(includesBefore)

    same(
        diff,
        { CAB_Dispatcher = 1 },
        "四模块已存在时重载 CAB_Dispatcher，下游 4 模块 include 增量必须全为 0"
    )
end)

test("T-02", "独立引擎桩与 CAB_ExternalIO 契约桩自检：红线陷阱 + 7 项外部 IO 契约 + 四模块联调", function()
    local w = S.newWorld({
        players = TWO_PLAYERS,
        wars = { { 0, 1 } },
        visibleAll = 0,
    })
    local warrior = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 7, y = 5 })
    w:addCity({ owner = 0, name = "Rome", x = 4, y = 5, isCapital = true })

    -- 1. S-01 / E-06 红线陷阱自检
    local caughtDb, errDb = S.expectViolation(function()
        Modding.OpenUserData("Civ5AgentBridge", 1)
    end)
    truthy(caughtDb, "Modding.OpenUserData 必须触发 S-01 红线陷阱")
    contains(errDb, "S-01", "错误消息应标注红线 S-01")

    local caughtDll = S.expectViolation(function()
        warrior:CanMoveOrAttackInto(w:getPlot(6, 5), false)
    end)
    truthy(caughtDll, "Unit:CanMoveOrAttackInto 必须触发引擎避坑红线陷阱")

    local caughtUi = S.expectViolation(function()
        UI.SetInterfaceMode(InterfaceModeTypes.INTERFACEMODE_MOVE_TO)
    end)
    truthy(caughtUi, "UI.SetInterfaceMode 必须触发红线陷阱")

    local caughtScript = S.expectViolation(function()
        w:getPlot(5, 5):SetScriptData("x")
    end)
    truthy(caughtScript, "Plot:SetScriptData 必须触发红线陷阱")

    -- 2. CAB_ExternalIO 契约桩 7 项接口验证
    local received = {}
    local okInit, errInit = CAB_ExternalIO.Initialize(function(req)
        table.insert(received, req)
    end)
    truthy(okInit, "CAB_ExternalIO.Initialize 应返回 true")
    isNil(errInit, "CAB_ExternalIO.Initialize 无错误")

    truthy(CAB_ExternalIO.WritePayload("k1", "hello", true), "WritePayload 应返回 true")
    eq(CAB_ExternalIO.ReadPayload("k1"), "hello", "ReadPayload 应准确读回")

    local overview = CAB_Collector.BuildTurnOverview(0)
    truthy(CAB_ExternalIO.PushTurnOverview(overview, 1), "PushTurnOverview 应返回 true")
    eq(#S.extIO.turnOverviews, 1, "应记录 1 次态势快照")
    eq(#S.extIO.heartbeats, 1, "PushTurnOverview 后应自动写入 1 次 TURN_SYNCED 心跳")
    eq(S.extIO.lastHeartbeat().status, "TURN_SYNCED", "自动心跳状态应为 TURN_SYNCED")

    local reqId = S.extIO.enqueueRequest("ping", { echo = "hi" })
    truthy(CAB_ExternalIO.PollIncomingRequest(), "队列非空时 PollIncomingRequest 应返回 true")
    falsy(CAB_ExternalIO.PollIncomingRequest(), "队列为空时 PollIncomingRequest 应返回 false")
    eq(#received, 1, "回调应收到 1 条入站请求")
    eq(received[1].req_id, reqId, "入站请求 req_id 匹配")

    -- 回调抛错时由 CAB_ExternalIO 兜底写回 ok=false 响应（对齐 §3.6）
    CAB_ExternalIO.Initialize(function()
        error("boom from callback")
    end)
    local errReqId = S.extIO.enqueueRequest("ping", {})
    truthy(CAB_ExternalIO.PollIncomingRequest(), "故障回调场景 PollIncomingRequest 应安全返回 true")
    eq(#S.extIO.responsesFor(errReqId), 1, "回调抛错时应兜底写回 1 次 RPC 响应")
    falsy(S.extIO.responsesFor(errReqId)[1].ok, "兜底响应 ok 应为 false")
    contains(S.extIO.responsesFor(errReqId)[1].error, "boom from callback", "兜底响应应包含异常信息")
end)

test("T-03", "Initialize 依赖完整性逐项自检与下游初始化失败拦截（A-02 / D-02）", function()
    S.newWorld({ players = TWO_PLAYERS })
    S.reloadDispatcher()

    -- 1. 逐项破坏 CAB_Config 6 个必需键
    local cfgKeys = {
        "POLL_INTERVAL_SEC",
        "HEARTBEAT_INTERVAL_SEC",
        "DEFAULT_UNIT_SETTLE_SEC",
        "PLOT_BUY_SETTLE_SEC",
        "MAX_SETTLE_TIMEOUT_SEC",
        "ENABLE_DEBUG_LOG",
    }
    for _, k in ipairs(cfgKeys) do
        local saved = CAB_Config[k]
        CAB_Config[k] = nil
        falsy(CAB_Dispatcher.Initialize(), "缺少 CAB_Config." .. k .. " 时 Initialize 应返回 false")
        local st = CAB_Dispatcher.GetRuntimeState()
        falsy(st.initialized, "失败后 initialized 应为 false")
        eq(st.bridge_state, "UNINITIALIZED", "失败后 bridge_state 应为 UNINITIALIZED")
        CAB_Config[k] = saved
    end

    -- 非正数轮询间隔校验
    local savedPoll = CAB_Config.POLL_INTERVAL_SEC
    CAB_Config.POLL_INTERVAL_SEC = 0
    falsy(CAB_Dispatcher.Initialize(), "POLL_INTERVAL_SEC <= 0 时 Initialize 应返回 false")
    CAB_Config.POLL_INTERVAL_SEC = savedPoll

    -- 2. 逐项破坏 CAB_Collector 7 个主查询函数
    local collFuncs = {
        "GetEmpireEconomy",
        "GetVisibilitySummary",
        "CaptureRevealedPlotsSet",
        "GetEndTurnStatus",
        "BuildTurnOverview",
        "BuildUnitContextAndCandidates",
        "GetCityDetail",
    }
    for _, fnName in ipairs(collFuncs) do
        local saved = CAB_Collector[fnName]
        CAB_Collector[fnName] = nil
        falsy(CAB_Dispatcher.Initialize(), "缺少 CAB_Collector." .. fnName .. " 时 Initialize 应返回 false")
        CAB_Collector[fnName] = saved
    end

    -- 3. 逐项破坏 CAB_Executor 9 个公开函数
    local execFuncs = {
        "Initialize",
        "StartUnitAction",
        "StartCityRangeAttack",
        "PurchaseCityItem",
        "SetCityProduction",
        "PurchaseCityPlot",
        "ExecuteEndTurn",
        "IsSettlementBusy",
        "FinalizeActionSettlement",
    }
    for _, fnName in ipairs(execFuncs) do
        local saved = CAB_Executor[fnName]
        CAB_Executor[fnName] = nil
        falsy(CAB_Dispatcher.Initialize(), "缺少 CAB_Executor." .. fnName .. " 时 Initialize 应返回 false")
        CAB_Executor[fnName] = saved
    end

    -- 4. 逐项破坏 CAB_ExternalIO 7 个契约函数
    local extFuncs = {
        "Initialize",
        "WritePayload",
        "ReadPayload",
        "PushTurnOverview",
        "WriteHeartbeat",
        "SendRpcResponse",
        "PollIncomingRequest",
    }
    for _, fnName in ipairs(extFuncs) do
        local saved = CAB_ExternalIO[fnName]
        CAB_ExternalIO[fnName] = nil
        falsy(CAB_Dispatcher.Initialize(), "缺少 CAB_ExternalIO." .. fnName .. " 时 Initialize 应返回 false")
        CAB_ExternalIO[fnName] = saved
    end

    -- 5. 下游 CAB_Executor.Initialize 返回 false 或抛错
    local savedExecInit = CAB_Executor.Initialize
    CAB_Executor.Initialize = function() return false end
    falsy(CAB_Dispatcher.Initialize(), "CAB_Executor.Initialize 返回 false 时应拦截")
    CAB_Executor.Initialize = function() error("exec init boom") end
    falsy(CAB_Dispatcher.Initialize(), "CAB_Executor.Initialize 抛错时应拦截")
    CAB_Executor.Initialize = savedExecInit

    -- 6. 下游 CAB_ExternalIO.Initialize 返回 false 或抛错
    S.extIO.faults.initFail = "OpenUserData failed"
    falsy(CAB_Dispatcher.Initialize(), "CAB_ExternalIO.Initialize 返回 false 时应拦截")
    S.extIO.faults.initFail = nil

    S.extIO.faults.initThrow = "db lock boom"
    falsy(CAB_Dispatcher.Initialize(), "CAB_ExternalIO.Initialize 抛错时应拦截")
    S.extIO.faults.initThrow = nil

    -- 7. 恢复全部依赖后成功初始化
    truthy(CAB_Dispatcher.Initialize(), "恢复全部依赖后 Initialize 应返回 true")
    truthy(CAB_Dispatcher.GetRuntimeState().initialized, "成功后 initialized 应为 true")
end)

test("T-04", "活动回合初始化闭环：IDLE + turn_seq=1 + 首帧态势推送 + 委托注册（A-02）", function()
    local w = S.newWorld({
        turn = 12,
        players = TWO_PLAYERS,
        wars = { { 0, 1 } },
        visibleAll = 0,
    })
    local warrior = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local enemy = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 7, y = 5 })
    local city = w:addCity({ owner = 0, name = "Rome", x = 4, y = 5, isCapital = true })

    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()

    truthy(CAB_Dispatcher.Initialize(uiCb), "活动回合 Initialize 应返回 true")

    local st = CAB_Dispatcher.GetRuntimeState()
    truthy(st.initialized, "initialized 应为 true")
    eq(st.bridge_state, "IDLE", "活动回合初始化后 bridge_state 应为 IDLE")
    eq(st.turn_event_seq, 1, "首次活动回合初始化后 turn_event_seq 应为 1")
    falsy(st.has_pending_settlement, "初始无挂起结算")
    isNil(st.pending_req_id, "初始 pending_req_id 为 nil")
    eq(st.poll_accum_sec, 0, "poll_accum_sec 应归零")
    eq(st.heartbeat_accum_sec, 0, "heartbeat_accum_sec 应归零")

    -- 验证 CAB_ExternalIO.Initialize 收到精确的委托函数
    eq(#S.extIO.initCalls, 1, "应调用 CAB_ExternalIO.Initialize 1 次")
    eq(
        S.extIO.initCalls[1].callback,
        CAB_Dispatcher.OnExternalRequestReceived,
        "必须注册 CAB_Dispatcher.OnExternalRequestReceived 作为消息到达委托"
    )

    -- 验证自动首帧态势推送（真实 CAB_Collector 数据）
    eq(#S.extIO.turnOverviews, 1, "活动回合初始化应推送 1 次首帧态势")
    local pushed = S.extIO.lastOverview()
    eq(pushed.turnSeq, 1, "推送携带 turnSeq 应为 1")
    eq(pushed.overview.turn_number, 12, "快照 turn_number 应为 12")
    eq(#pushed.overview.our_units, 1, "快照应包含 1 个己方单位")
    eq(pushed.overview.our_units[1].unit_id, warrior:GetID(), "快照己方单位 ID 匹配")
    eq(#pushed.overview.our_cities, 1, "快照应包含 1 座己方城市")
    eq(pushed.overview.our_cities[1].city_id, city:GetID(), "快照己方城市 ID 匹配")
    eq(#pushed.overview.visible_enemies, 1, "快照应包含 1 个可见敌军")
    eq(pushed.overview.visible_enemies[1].enemy_id, "1:" .. tostring(enemy:GetID()), "快照可见敌军 ID 匹配")

    -- 验证 TURN_SYNCED 心跳与 UI 文案
    eq(#S.extIO.heartbeats, 1, "应写入 1 次 TURN_SYNCED 心跳")
    eq(S.extIO.lastHeartbeat().status, "TURN_SYNCED", "心跳状态应为 TURN_SYNCED")
    eq(S.extIO.lastHeartbeat().turnSeq, 1, "心跳 turnSeq 应为 1")
    eq(uiLog[#uiLog], "Agent: Turn 12 Synced", "UI 状态栏应显示 Agent: Turn 12 Synced")
end)

test("T-05", "非活动回合初始化闭环：AI_TURN_LOCKED + 零态势推送 + AI 心跳（A-02）", function()
    S.newWorld({
        turn = 5,
        players = {
            { id = 0, team = 0, civ = "Rome", turnActive = false },
            { id = 1, team = 1, civ = "Carthage", turnActive = true },
        },
    })

    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()

    truthy(CAB_Dispatcher.Initialize(uiCb), "非活动回合 Initialize 应返回 true")

    local st = CAB_Dispatcher.GetRuntimeState()
    truthy(st.initialized, "initialized 应为 true")
    eq(st.bridge_state, "AI_TURN_LOCKED", "非活动回合初始化应进入 AI_TURN_LOCKED")
    eq(st.turn_event_seq, 0, "非活动回合初始化不得递增 turn_event_seq")

    eq(#S.extIO.turnOverviews, 0, "非活动回合初始化严禁推送 turn_overview_auto")
    eq(#S.extIO.heartbeats, 1, "应写入 1 次初始 AI 心跳")
    eq(S.extIO.lastHeartbeat().status, "AI_TURN_PROCESSING", "初始心跳状态应为 AI_TURN_PROCESSING")
    eq(S.extIO.lastHeartbeat().turnSeq, 0, "初始心跳 turnSeq 应为 0")
    eq(uiLog[#uiLog], "Agent: AI Turn...", "UI 状态栏应显示 Agent: AI Turn...")

    -- 激活玩家槽位为空时亦应安全进入 AI_TURN_LOCKED
    local w2 = S.newWorld({ turn = 6, activePlayer = 0 })
    w2:setNilPlayerSlot(0, true)
    S.resetExternalIO()
    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(uiCb), "激活玩家缺失时 Initialize 仍应安全返回 true")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "无有效玩家时应进入 AI_TURN_LOCKED")
    eq(#S.extIO.turnOverviews, 0, "无有效玩家时不得推送快照")
end)

test("T-06", "GetRuntimeState 只读浅拷贝隔离性与 UI 回调容错保护（D-06 / S-04）", function()
    S.newWorld({ turn = 3, players = TWO_PLAYERS })
    S.reloadDispatcher()

    -- 1. 非函数 uiStatusCallback 静默忽略
    truthy(CAB_Dispatcher.Initialize("not_a_function"), "传入非函数 UI 回调不得报错")

    -- 2. 篡改 GetRuntimeState 返回表不得污染内部状态
    local snap1 = CAB_Dispatcher.GetRuntimeState()
    truthy(snap1.__is_object, "GetRuntimeState 返回表应携带 __is_object = true")
    snap1.bridge_state = "HACKED"
    snap1.turn_event_seq = 999
    snap1.initialized = false

    local snap2 = CAB_Dispatcher.GetRuntimeState()
    eq(snap2.bridge_state, "IDLE", "篡改快照不得影响内部 bridge_state")
    eq(snap2.turn_event_seq, 1, "篡改快照不得影响内部 turn_event_seq")
    truthy(snap2.initialized, "篡改快照不得影响内部 initialized")

    -- 3. 抛异常的 UI 回调必须被 pcall 隔离
    local badUiCb = function()
        error("UI panel destroyed")
    end
    truthy(CAB_Dispatcher.Initialize(badUiCb), "UI 回调抛异常不得导致 Initialize 失败")
    CAB_Dispatcher.OnManualSyncClicked()
    CAB_Dispatcher.OnActivePlayerTurnEnd()
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "UI 回调抛错后 TurnEnd 仍应正常切态")
    CAB_Dispatcher.OnActivePlayerTurnStart()
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "UI 回调抛错后 TurnStart 仍应正常切态")
end)

test("T-07", "回合生命周期流转：TurnEnd -> TurnStart 跨多回合切态与 s_TurnEventSeq 递增（A-03）", function()
    local w = S.newWorld({
        turn = 1,
        players = TWO_PLAYERS,
        visibleAll = 0,
    })
    w:addCity({ owner = 0, name = "Rome", x = 4, y = 5, isCapital = true })

    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()

    truthy(CAB_Dispatcher.Initialize(uiCb), "Turn 1 初始化成功")
    eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 1, "Turn 1 seq=1")
    eq(#S.extIO.turnOverviews, 1, "Turn 1 已推送 1 次")

    -- Turn 1 结束 -> AI 回合
    w:setPlayer(0, { turnActive = false })
    CAB_Dispatcher.OnActivePlayerTurnEnd()

    local stEnd = CAB_Dispatcher.GetRuntimeState()
    eq(stEnd.bridge_state, "AI_TURN_LOCKED", "TurnEnd 后进入 AI_TURN_LOCKED")
    eq(stEnd.turn_event_seq, 1, "TurnEnd 不得递增 turn_event_seq")
    eq(S.extIO.lastHeartbeat().status, "AI_TURN_PROCESSING", "TurnEnd 应写 AI_TURN_PROCESSING 心跳")
    eq(S.extIO.lastHeartbeat().turnSeq, 1, "AI 心跳携带当前 seq=1")
    eq(uiLog[#uiLog], "Agent: AI Turn...", "TurnEnd 更新 UI 为 Agent: AI Turn...")

    -- Turn 2 开始 -> 玩家回合
    w.turn = 2
    w:setPlayer(0, { turnActive = true })
    CAB_Dispatcher.OnActivePlayerTurnStart()

    local stStart2 = CAB_Dispatcher.GetRuntimeState()
    eq(stStart2.bridge_state, "IDLE", "Turn 2 Start 应恢复 IDLE")
    eq(stStart2.turn_event_seq, 2, "Turn 2 Start 应递增 turn_event_seq 至 2")
    eq(#S.extIO.turnOverviews, 2, "Turn 2 应触发第 2 次态势推送")
    eq(S.extIO.lastOverview().overview.turn_number, 2, "第 2 次快照 turn_number 应为 2")
    eq(S.extIO.lastOverview().turnSeq, 2, "第 2 次快照 turnSeq 应为 2")
    eq(S.extIO.lastHeartbeat().status, "TURN_SYNCED", "Turn 2 推送后应写 TURN_SYNCED 心跳")
    eq(S.extIO.lastHeartbeat().turnSeq, 2, "Turn 2 心跳 turnSeq 应为 2")
    eq(uiLog[#uiLog], "Agent: Turn 2 Synced", "Turn 2 更新 UI 为 Agent: Turn 2 Synced")

    -- Turn 3 再循环一轮
    CAB_Dispatcher.OnActivePlayerTurnEnd()
    w.turn = 3
    CAB_Dispatcher.OnActivePlayerTurnStart()
    eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 3, "Turn 3 Start 应递增 turn_event_seq 至 3")
    eq(S.extIO.lastOverview().overview.turn_number, 3, "第 3 次快照 turn_number 应为 3")
end)

test("T-08", "未初始化态安全空转：生命周期与帧回调零异常、零外部 IO 写入", function()
    S.newWorld({ players = TWO_PLAYERS })
    S.reloadDispatcher()

    local st0 = CAB_Dispatcher.GetRuntimeState()
    falsy(st0.initialized, "未调用 Initialize 前 initialized 应为 false")
    eq(st0.bridge_state, "UNINITIALIZED", "初始状态应为 UNINITIALIZED")
    eq(st0.turn_event_seq, 0, "初始 turn_event_seq 应为 0")

    CAB_Dispatcher.OnActivePlayerTurnStart()
    CAB_Dispatcher.OnActivePlayerTurnEnd()
    CAB_Dispatcher.OnManualSyncClicked()
    CAB_Dispatcher.OnFrameUpdate(0.25)

    eq(#S.extIO.turnOverviews, 0, "未初始化态不得推送态势")
    eq(#S.extIO.heartbeats, 0, "未初始化态不得写入心跳")
    eq(#S.extIO.rpcResponses, 0, "未初始化态不得写回 RPC 响应")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "UNINITIALIZED", "状态保持 UNINITIALIZED")
    eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 0, "序号保持 0")
end)

test("T-09", "OnManualSyncClicked 多状态护栏与 s_TurnEventSeq 严格隔离（A-03 / D-06 / S-05）", function()
    local w = S.newWorld({
        turn = 7,
        players = TWO_PLAYERS,
        visibleAll = 0,
    })
    w:addCity({ owner = 0, name = "Rome", x = 4, y = 5, isCapital = true })

    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()
    truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
    eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 1, "初始 turn_event_seq=1")
    S.extIO.clearHistory()

    -- 1. 玩家活动回合 IDLE 连续点击 2 次手动同步：均导出快照，且 turn_event_seq 严格保持 1
    CAB_Dispatcher.OnManualSyncClicked()
    CAB_Dispatcher.OnManualSyncClicked()
    eq(#S.extIO.turnOverviews, 2, "IDLE 态点击 2 次应导出 2 次快照")
    eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 1, "S-05：手动同步绝不得递增 s_TurnEventSeq")
    eq(S.extIO.turnOverviews[1].turnSeq, 1, "第 1 次手动同步携带 turnSeq=1")
    eq(S.extIO.turnOverviews[2].turnSeq, 1, "第 2 次手动同步携带 turnSeq=1")
    eq(uiLog[#uiLog], "Agent: Turn 7 Synced", "手动同步后刷新 UI 为 Turn 7 Synced")

    -- 2. AI_TURN_LOCKED 态点击：零快照导出，仅提示 AI Turn
    CAB_Dispatcher.OnActivePlayerTurnEnd()
    S.extIO.clearHistory()
    CAB_Dispatcher.OnManualSyncClicked()
    eq(#S.extIO.turnOverviews, 0, "S-05：AI_TURN_LOCKED 态手动同步严禁覆写快照")
    eq(uiLog[#uiLog], "Agent: AI Turn...", "AI_TURN_LOCKED 点击仅提示 Agent: AI Turn...")

    -- 3. 状态失步自校准（bridge_state 仍为 IDLE，但引擎侧 IsTurnActive 已变 false）：
    --    应拦截导出并将 bridge_state 对齐至 AI_TURN_LOCKED
    CAB_Dispatcher.OnActivePlayerTurnStart()
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "TurnStart 后恢复 IDLE")
    S.extIO.clearHistory()
    w:setPlayer(0, { turnActive = false })

    CAB_Dispatcher.OnManualSyncClicked()
    eq(#S.extIO.turnOverviews, 0, "S-05：实时检测到非活动回合时严禁覆写快照")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "检测到失步后应自动对齐为 AI_TURN_LOCKED")
    eq(uiLog[#uiLog], "Agent: AI Turn...", "失步拦截时提示 Agent: AI Turn...")
end)

test("T-10", "采集或推送异常降级自愈：不推送脏快照、不卡死状态机（S-04）", function()
    S.newWorld({ turn = 9, players = TWO_PLAYERS })
    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()

    local savedBuild = CAB_Collector.BuildTurnOverview

    -- 1. BuildTurnOverview 返回带 error 字段表
    CAB_Collector.BuildTurnOverview = function()
        return { __is_object = true, error = "Simulated collector failure" }
    end
    local ok1, err1 = pcall(function()
        truthy(CAB_Dispatcher.Initialize(uiCb), "采集返回 error 表时 Initialize 仍应降级成功")
    end)
    CAB_Collector.BuildTurnOverview = savedBuild
    truthy(ok1, "场景 1 断言失败：" .. tostring(err1))

    eq(#S.extIO.turnOverviews, 0, "采集返回 error 时不得向 PushTurnOverview 写入脏快照")
    eq(S.extIO.lastHeartbeat().status, "IDLE", "采集失败应降级写入 IDLE 心跳")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "状态机应维持 IDLE 不卡死")
    contains(uiLog[#uiLog], "Sync Error", "UI 应给出同步异常提示")

    -- 2. OnActivePlayerTurnStart 时 BuildTurnOverview 抛出 Lua 运行时异常
    S.extIO.clearHistory()
    CAB_Collector.BuildTurnOverview = function()
        error("unexpected collector crash")
    end
    local ok2, err2 = pcall(CAB_Dispatcher.OnActivePlayerTurnStart)
    CAB_Collector.BuildTurnOverview = savedBuild
    truthy(ok2, "BuildTurnOverview 抛错时 OnActivePlayerTurnStart 不得向外抛异常：" .. tostring(err2))

    eq(#S.extIO.turnOverviews, 0, "采集抛错时不得写入脏快照")
    eq(S.extIO.lastHeartbeat().status, "IDLE", "采集抛错应降级写入 IDLE 心跳")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "状态机自愈维持 IDLE")

    -- 3. PushTurnOverview 抛出异常时同样安全自愈
    S.extIO.clearHistory()
    S.extIO.faults.pushThrow = "disk full"
    CAB_Dispatcher.OnActivePlayerTurnStart()
    S.extIO.faults.pushThrow = nil
    eq(S.extIO.lastHeartbeat().status, "IDLE", "PushTurnOverview 抛错应降级写入 IDLE 心跳")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "状态机自愈维持 IDLE")
end)

-- -----------------------------------------------------------------------------
-- 第 3 节：WP2 14 项 IPC 路由、非活动回合门控、信封保真与挂起槽位用例（T-11 ~ T-17）
-- -----------------------------------------------------------------------------

local function buildWp2World()
    local w = S.newWorld({
        turn = 15,
        players = {
            {
                id = 0, team = 0, civ = "Rome", name = "Augustus",
                gold = 800, goldRate = 25, science = 18, culturePerTurn = 12,
                faith = 400, faithPerTurn = 6, happiness = 7, turnActive = true,
            },
            {
                id = 1, team = 1, civ = "Carthage", name = "Dido",
                gold = 200, faith = 100, turnActive = false,
            },
        },
        wars = { { 0, 1 } },
        visibleAll = 0,
    })

    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        canMoveThrough = true,
        canHandleActions = {
            MISSION_FORTIFY = true,
            MISSION_SKIP = true,
        },
    })
    local enemy = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 6, y = 5 })
    local enemyCity = w:addCity({ owner = 1, name = "Carthage", x = 10, y = 5, isCapital = true })

    local granaryId = GameInfoTypes.BUILDING_GRANARY
    local archerId = GameInfoTypes.UNIT_ARCHER
    local city = w:addCity({
        owner = 0, name = "Rome", x = 4, y = 5, isCapital = true,
        canRangeStrike = true,
        canRangeStrikeNow = true,
        canRangeStrikeAt = { [S.keyOf(6, 5)] = true },
        purchasable = {
            buildings = { [granaryId] = { gold = true } },
            units = { [archerId] = { gold = true, faith = true } },
        },
        affordable = {
            buildings = { [granaryId] = { gold = true } },
            units = { [archerId] = { gold = true, faith = true } },
        },
        costs = {
            bldGold = { [granaryId] = 200 },
            unitGold = { [archerId] = 160 },
            unitFaith = { [archerId] = 120 },
        },
        cityPlots = {
            { x = 4, y = 5 },
            { x = 3, y = 5 },
            { x = 3, y = 4 },
        },
        canBuyPlotAt = {
            [S.keyOf(3, 5)] = true,
            [S.keyOf(3, 4)] = true,
        },
        canBuyPlotNow = {
            [S.keyOf(3, 5)] = true,
            [S.keyOf(3, 4)] = true,
        },
        buyPlotCost = {
            [S.keyOf(3, 5)] = 50,
            [S.keyOf(3, 4)] = 65,
        },
    })

    return w, warrior, enemy, city, enemyCity
end

local function sendRpc(reqId, method, params)
    CAB_Dispatcher.OnExternalRequestReceived({
        req_id = reqId,
        method = method,
        params = params,
    })
    local resps = S.extIO.responsesFor(reqId)
    return resps[#resps], #resps
end

test("T-11", "OnExternalRequestReceived 协议守卫：畸形入参、未初始化、未知方法与异常自愈（A-04 / S-04）", function()
    S.newWorld({ players = TWO_PLAYERS })
    S.reloadDispatcher()

    -- 1. 畸形入参安全忽略（零响应）
    CAB_Dispatcher.OnExternalRequestReceived(nil)
    CAB_Dispatcher.OnExternalRequestReceived("bad")
    CAB_Dispatcher.OnExternalRequestReceived({})
    CAB_Dispatcher.OnExternalRequestReceived({ req_id = "NaN", method = "ping" })
    CAB_Dispatcher.OnExternalRequestReceived({ req_id = 1.5, method = "ping" })
    CAB_Dispatcher.OnExternalRequestReceived({ req_id = math.huge, method = "ping" })
    eq(#S.extIO.rpcResponses, 0, "无合法整数 req_id 的脏对象不得写回无效响应")

    -- 2. 未初始化态收到合法 req_id 应立返 ok=false
    local rUninit, nUninit = sendRpc(101, "ping", {})
    eq(nUninit, 1, "未初始化态应返回 1 条错误响应")
    falsy(rUninit.ok, "未初始化态响应 ok 应为 false")
    contains(rUninit.error, "not initialized", "错误信息应明确指出未初始化")

    -- 3. 初始化后：缺失/非法 method、非表 params、未知方法
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")
    S.extIO.clearHistory()

    local rNoMethod, nNoMethod = sendRpc(102, nil, {})
    eq(nNoMethod, 1, "缺失 method 应返回 1 条响应")
    falsy(rNoMethod.ok, "缺失 method 应返 ok=false")
    contains(rNoMethod.error, "method", "报错应指出 method 缺失")

    local rEmptyMethod = sendRpc(103, "", {})
    falsy(rEmptyMethod.ok, "空字符串 method 应返 ok=false")

    local rBadParams = sendRpc(104, "ping", "not_a_table")
    falsy(rBadParams.ok, "非表 params 应返 ok=false")
    contains(rBadParams.error, "params", "报错应指出 params 非法")

    local rUnknown = sendRpc(105, "no_such_rpc_method", {})
    falsy(rUnknown.ok, "未知 method 应返 ok=false")
    contains(rUnknown.error, "Unknown RPC method", "报错应明确指出未知方法")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "错返后状态保持 IDLE")

    -- 4. 下游抛出 Lua 运行时异常时 pcall 兜底返 ok=false 并自愈回 IDLE（S-04）
    local savedEcon = CAB_Collector.GetEmpireEconomy
    CAB_Collector.GetEmpireEconomy = function()
        error("simulated collector panic")
    end
    local rPanic, nPanic
    local okOuter, outerErr = pcall(function()
        rPanic, nPanic = sendRpc(106, "get_empire_economy", {})
    end)
    CAB_Collector.GetEmpireEconomy = savedEcon

    truthy(okOuter, "下游抛错时 OnExternalRequestReceived 不得向外冒泡：" .. tostring(outerErr))
    eq(nPanic, 1, "下游抛错应兜底写回 1 条错误响应")
    falsy(rPanic.ok, "异常兜底响应 ok 应为 false")
    contains(rPanic.error, "simulated collector panic", "错误信息应包含下游异常描述")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "S-04：异常后状态机必须自愈回 IDLE")
end)

test("T-12", "内建与诊断方法路由：ping 与 test_large_payload（含 512KB 钳制与分片透传）（A-04）", function()
    buildWp2World()
    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()
    truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
    S.extIO.clearHistory()

    -- 1. ping 缺省参数（params=nil）与自定义 echo
    local rPingDef, n1 = sendRpc(201, "ping", nil)
    eq(n1, 1, "ping 应返回 1 条响应")
    truthy(rPingDef.ok, "ping 应返回 ok=true")
    eq(rPingDef.data.pong, "pong", "缺省 echo 应回传 pong")
    eq(rPingDef.data.turn, 15, "turn 字段应匹配当前回合")
    eq(rPingDef.data.active_player, 0, "active_player 应为 0")
    truthy(rPingDef.data.is_turn_active, "活动回合 is_turn_active 应为 true")
    eq(rPingDef.data.status, "IDLE", "ping.status 应报告执行前逻辑态 IDLE")
    eq(rPingDef.data.turn_seq, 1, "turn_seq 应匹配 s_TurnEventSeq")
    eq(uiLog[#uiLog], "Agent: ping (#201)", "UI 应刷新为 Agent: ping (#201)")

    local rPingCustom = sendRpc(202, "ping", { echo = "hello_civ5" })
    truthy(rPingCustom.ok, "自定义 echo ping 成功")
    eq(rPingCustom.data.pong, "hello_civ5", "echo 应原样回传")

    -- 2. test_large_payload 缺省 32768 字节、自定义分片透传、0 字节、超大钳制与非法入参
    local rLargeDef = sendRpc(203, "test_large_payload", {})
    truthy(rLargeDef.ok, "缺省 test_large_payload 应成功")
    falsy(rLargeDef.force_chunked, "未指定 use_chunk 时 force_chunked 应为 false")
    eq(rLargeDef.data.received_len, 0, "空 payload received_len 为 0")
    eq(rLargeDef.data.generated_len, 32768, "缺省生成长度应为 32768")
    eq(#rLargeDef.data.payload_blob, 32768, "payload_blob 字节数匹配")

    local rLargeChunk = sendRpc(204, "test_large_payload", {
        target_bytes = 128,
        use_chunk = true,
        payload = "abcdef",
    })
    truthy(rLargeChunk.ok, "分片 test_large_payload 应成功")
    truthy(rLargeChunk.force_chunked, "use_chunk=true 必须透传至 SendRpcResponse.forceChunked")
    eq(rLargeChunk.data.received_len, 6, "received_len 应为 6")
    eq(rLargeChunk.data.generated_len, 128, "generated_len 应为 128")

    local rLargeZero = sendRpc(205, "test_large_payload", { target_bytes = 0 })
    truthy(rLargeZero.ok, "target_bytes=0 应成功")
    eq(rLargeZero.data.generated_len, 0, "0 字节载荷长度为 0")

    local rLargeCap = sendRpc(206, "test_large_payload", { target_bytes = 9999999 })
    truthy(rLargeCap.ok, "超大 target_bytes 应安全钳制成功")
    eq(rLargeCap.data.generated_len, 524288, "target_bytes 必须钳制上限为 524288 (512KB)")

    falsy(sendRpc(207, "test_large_payload", { target_bytes = -1 }).ok, "负数 target_bytes 应拦截")
    falsy(sendRpc(208, "test_large_payload", { target_bytes = 12.5 }).ok, "小数 target_bytes 应拦截")
    falsy(sendRpc(209, "test_large_payload", { target_bytes = "100" }).ok, "字符串 target_bytes 应拦截")
end)

test("T-13", "6 项 CAB_Collector 只读查询路由、参数守卫与错误信封映射（A-04 / D-04）", function()
    local _, warrior, _, city = buildWp2World()
    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")
    S.extIO.clearHistory()

    -- 1. get_turn_overview
    local rOverview = sendRpc(301, "get_turn_overview", {})
    truthy(rOverview.ok, "get_turn_overview 应返回 ok=true")
    eq(rOverview.data.turn_number, 15, "turn_number=15")
    eq(#rOverview.data.our_units, 1, "己方单位数=1")
    eq(#rOverview.data.our_cities, 1, "己方城市数=1")
    eq(#rOverview.data.visible_enemies, 1, "可见敌军数=1")
    notNil(rOverview.data.end_turn_status, "应携带 end_turn_status")

    -- 2. get_empire_economy
    local rEcon = sendRpc(302, "get_empire_economy", {})
    truthy(rEcon.ok, "get_empire_economy 应返回 ok=true")
    eq(rEcon.data.gold, 800, "国库金币=800")
    eq(rEcon.data.faith_total, 400, "累计信仰=400")

    -- 3. get_visibility_summary（仅透传第 1 返回值 VisibilitySummaryDTO）
    local rVis = sendRpc(303, "get_visibility_summary", {})
    truthy(rVis.ok, "get_visibility_summary 应返回 ok=true")
    eq(#rVis.data.visible_enemies, 1, "可见敌军数=1")
    eq(#rVis.data.visible_enemy_cities, 1, "已探索敌城数=1")

    -- 4. get_city_detail（默认 include_purchasable=true / 显式 false / 缺失错型 / 不存在城市转 ok=false）
    local rCityFull = sendRpc(304, "get_city_detail", { city_id = city:GetID() })
    truthy(rCityFull.ok, "get_city_detail 默认参数应成功")
    eq(rCityFull.data.city.name, "Rome", "城市名匹配")
    truthy(#rCityFull.data.purchasable_buildings >= 1, "默认应包含可购建筑")
    truthy(#rCityFull.data.purchasable_plots >= 1, "默认应包含可购地块")

    local rCityNoBuy = sendRpc(305, "get_city_detail", {
        city_id = city:GetID(),
        include_purchasable = false,
    })
    truthy(rCityNoBuy.ok, "include_purchasable=false 应成功")
    eq(#rCityNoBuy.data.purchasable_buildings, 0, "跳过购买项时可购建筑为空")
    eq(#rCityNoBuy.data.purchasable_units, 0, "跳过购买项时可购单位为空")
    eq(#rCityNoBuy.data.purchasable_plots, 0, "跳过购买项时可购地块为空")

    falsy(sendRpc(306, "get_city_detail", {}).ok, "缺少 city_id 应返 ok=false")
    falsy(sendRpc(307, "get_city_detail", { city_id = "0" }).ok, "非整数 city_id 应返 ok=false")
    local rMissingCity = sendRpc(308, "get_city_detail", { city_id = 999 })
    falsy(rMissingCity.ok, "D-04：CAB_Collector 返回 error 表必须映射为 ok=false")
    isNil(rMissingCity.data, "ok=false 时 data 应为 nil")
    contains(rMissingCity.error, "City not found", "应透传采集层错误信息")

    -- 5. get_end_turn_status
    local rEndSt = sendRpc(309, "get_end_turn_status", {})
    truthy(rEndSt.ok, "get_end_turn_status 应返回 ok=true")
    truthy(rEndSt.data.can_end_turn_now, "无阻塞时 can_end_turn_now 应为 true")
    eq(rEndSt.data.blocking_type_name, "NO_BLOCKING", "无阻塞枚举名匹配")

    -- 6. get_unit_context（缺省 radius / 显式 radius / 非法入参 / 不存在单位）
    local rUnitDef = sendRpc(310, "get_unit_context", { unit_id = warrior:GetID() })
    truthy(rUnitDef.ok, "get_unit_context 默认 radius 应成功")
    eq(rUnitDef.data.unit.unit_id, warrior:GetID(), "返回单位 ID 匹配")
    truthy(#rUnitDef.data.candidate_actions >= 1, "应枚举出合法候选动作")

    local rUnitRad = sendRpc(311, "get_unit_context", { unit_id = warrior:GetID(), radius = 1 })
    truthy(rUnitRad.ok, "get_unit_context 显式 radius=1 应成功")
    for _, tile in ipairs(rUnitRad.data.surrounding_tiles) do
        truthy(tile.distance <= 1, "radius=1 时地块距离不得超过 1")
    end

    falsy(sendRpc(312, "get_unit_context", {}).ok, "缺少 unit_id 应返 ok=false")
    falsy(sendRpc(313, "get_unit_context", { unit_id = warrior:GetID(), radius = "bad" }).ok, "非数字 radius 应返 ok=false")
    falsy(sendRpc(314, "get_unit_context", { unit_id = warrior:GetID(), radius = 1.5 }).ok, "小数 radius 应返 ok=false")
    local rMissingUnit = sendRpc(315, "get_unit_context", { unit_id = 999 })
    falsy(rMissingUnit.ok, "D-04：不存在单位应映射为 ok=false")
    isNil(rMissingUnit.data, "ok=false 时 data 为 nil")
    contains(rMissingUnit.error, "Unit not found", "应透传单位缺失错误")
end)

test("T-14", "非活动回合全量 20 方法门控矩阵与状态失步自校准（D-03 / D-08 / S-02 / A-05）", function()
    local w, warrior, _, city = buildWp2World()
    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")

    -- 切入 AI 回合（同时将引擎 turnActive 置 false）
    w:setPlayer(0, { turnActive = false })
    CAB_Dispatcher.OnActivePlayerTurnEnd()
    S.extIO.clearHistory()
    w:clearWriteLog()

    -- 1. 10 项零选区副作用只读/诊断白名单方法在 AI_TURN_LOCKED 下全部放行且保持 AI_TURN_LOCKED
    local allowedCases = {
        { method = "ping",                   params = { echo = "ai_ok" } },
        { method = "test_large_payload",     params = { target_bytes = 32 } },
        { method = "get_turn_overview",      params = {} },
        { method = "get_empire_economy",     params = {} },
        { method = "get_visibility_summary", params = {} },
        { method = "get_city_detail",        params = { city_id = city:GetID() } },
        { method = "get_end_turn_status",    params = {} },
        { method = "get_research_options",   params = {} },
        { method = "get_policy_options",     params = {} },
        { method = "get_unit_promotions",    params = { unit_id = warrior:GetID() } },
    }
    local nextId = 400
    for _, item in ipairs(allowedCases) do
        nextId = nextId + 1
        local resp = sendRpc(nextId, item.method, item.params)
        truthy(resp.ok, "D-03/D-08 白名单方法在 AI 回合应放行：" .. item.method)
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", item.method .. " 返回后应维持 AI_TURN_LOCKED")
        if item.method == "ping" then
            eq(resp.data.status, "AI_TURN_LOCKED", "AI 回合 ping.status 应为 AI_TURN_LOCKED")
            falsy(resp.data.is_turn_active, "AI 回合 ping.is_turn_active 应为 false")
        end
    end

    -- 2. 监控下游 10 个被禁入口（BuildUnitContextAndCandidates + 9 个 CAB_Executor 写/结束回合函数）
    local blockedDownstreamCalls = 0
    local savedUnitCtx = CAB_Collector.BuildUnitContextAndCandidates
    local savedExec = {
        StartUnitAction = CAB_Executor.StartUnitAction,
        StartCityRangeAttack = CAB_Executor.StartCityRangeAttack,
        PurchaseCityItem = CAB_Executor.PurchaseCityItem,
        SetCityProduction = CAB_Executor.SetCityProduction,
        PurchaseCityPlot = CAB_Executor.PurchaseCityPlot,
        ExecuteEndTurn = CAB_Executor.ExecuteEndTurn,
        SetResearchTech = CAB_Executor.SetResearchTech,
        AdoptPolicyOrBranch = CAB_Executor.AdoptPolicyOrBranch,
        PromoteUnit = CAB_Executor.PromoteUnit,
    }
    CAB_Collector.BuildUnitContextAndCandidates = function(...)
        blockedDownstreamCalls = blockedDownstreamCalls + 1
        return savedUnitCtx(...)
    end
    for fnName, origFn in pairs(savedExec) do
        CAB_Executor[fnName] = function(...)
            blockedDownstreamCalls = blockedDownstreamCalls + 1
            return origFn(...)
        end
    end

    local blockedCases = {
        { method = "get_unit_context",    params = { unit_id = warrior:GetID() } },
        { method = "execute_unit_action", params = { unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4 } },
        { method = "execute_city_attack", params = { city_id = city:GetID(), target_x = 6, target_y = 5 } },
        { method = "purchase_city_item",  params = { city_id = city:GetID(), item = "BUILDING_GRANARY" } },
        { method = "set_city_production", params = { city_id = city:GetID(), order_category = "BUILDING", item = "BUILDING_MONUMENT" } },
        { method = "purchase_city_plot",  params = { city_id = city:GetID(), target_x = 3, target_y = 5 } },
        { method = "set_research_tech",   params = { tech = "TECH_POTTERY" } },
        { method = "adopt_policy",        params = { target_category = "BRANCH", target = "POLICY_BRANCH_TRADITION" } },
        { method = "promote_unit",        params = { unit_id = warrior:GetID(), promotion = "PROMOTION_SHOCK_1" } },
        { method = "end_turn",            params = {} },
    }

    local okMatrix, matrixErr = pcall(function()
        for _, item in ipairs(blockedCases) do
            nextId = nextId + 1
            local resp, count = sendRpc(nextId, item.method, item.params)
            eq(count, 1, "拦截方法应写回 1 次错返：" .. item.method)
            falsy(resp.ok, "S-02/D-03：AI 回合必须拦截 " .. item.method)
            eq(resp.error, "Player turn is not active (AI turn in progress)", "拦截错误文案应精确对齐 D-03：" .. item.method)
        end
    end)

    -- 无条件还原下游函数引用
    CAB_Collector.BuildUnitContextAndCandidates = savedUnitCtx
    for fnName, origFn in pairs(savedExec) do
        CAB_Executor[fnName] = origFn
    end
    truthy(okMatrix, "AI 拦截矩阵断言失败：" .. tostring(matrixErr))
    eq(blockedDownstreamCalls, 0, "A-05：被拦截的 7 个方法下游调用次数必须严格为 0")
    eq(w:writeCount(), 0, "A-05：AI 回合拦截期间引擎写计数必须严格为 0")

    -- 3. 读档/IGE 恢复自校准（曾观测到非活动态，现引擎恢复活动但未触发 ActivePlayerTurnStart）
    w:setPlayer(0, { turnActive = true })
    local rRecovered = sendRpc(450, "get_unit_context", { unit_id = warrior:GetID() })
    truthy(rRecovered.ok, "读档/IGE 恢复活动回合后应自动校准回 IDLE 并放行 get_unit_context")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "自校准后状态应为 IDLE")

    -- 4. IDLE 态实时失步自锁（未触发 TurnEnd 但引擎 IsTurnActive 已变 false）
    w:setPlayer(0, { turnActive = false })
    local rDesyncBlock = sendRpc(451, "execute_unit_action", {
        unit_id = warrior:GetID(),
        action_type = "MOVE_STEP",
        target_x = 5,
        target_y = 4,
    })
    falsy(rDesyncBlock.ok, "实时检测到非活动回合应立即拦截写指令")
    eq(rDesyncBlock.error, "Player turn is not active (AI turn in progress)", "失步拦截错误文案匹配")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "失步拦截后应自动对齐为 AI_TURN_LOCKED")
    eq(w:writeCount(), 0, "失步拦截期间引擎写计数为 0")
end)

test("T-15", "end_turn 三分支信封保真映射、守卫式自动跳过与切入 AI_TURN_LOCKED（A-06 / D-04）", function()
    local w, warrior = buildWp2World()
    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()
    truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
    S.extIO.clearHistory()
    w:clearWriteLog()

    -- 分支 1：引擎消息队列忙导致门控失败（ExecuteEndTurn 返回 resultDto == nil -> ok = false）
    w.processingMessages = true
    local rGateFail = sendRpc(501, "end_turn", {})
    falsy(rGateFail.ok, "门控失败时 end_turn 应返 ok=false")
    isNil(rGateFail.data, "门控失败时 data 应为 nil")
    contains(rGateFail.error, "processing messages", "应透传消息队列忙原因")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "门控失败后维持 IDLE")
    falsy(w.endTurnRequested, "门控失败不得提交 CONTROL_ENDTURN")
    w.processingMessages = false

    -- 分支 2：存在待办阻塞（BLOCKED -> D-04 要求 ok=true 保真透传 blocking_info 且维持 IDLE）
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION })
    local rBlockedProd = sendRpc(502, "end_turn", { auto_skip_ready_units = true })
    truthy(rBlockedProd.ok, "D-04：end_turn(BLOCKED) 必须返 ok=true 以防 Python 抛异常丢弃诊断详情")
    eq(rBlockedProd.data.status, "BLOCKED", "status 应为 BLOCKED")
    falsy(rBlockedProd.data.turn_ended, "turn_ended 应为 false")
    eq(rBlockedProd.data.blocking_info.blocking_type_name, "ENDTURN_BLOCKING_PRODUCTION", "应完整携带 blocking_info")
    eq(#rBlockedProd.data.auto_skipped_unit_ids, 0, "硬阻塞下绝不浪费待命单位行动力")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "BLOCKED 时必须维持 IDLE")
    eq(#S.extIO.heartbeats, 0, "BLOCKED 时不得写入 AI_TURN_PROCESSING 心跳")
    falsy(w.endTurnRequested, "BLOCKED 时不得提交 CONTROL_ENDTURN")

    -- 分支 2b：待命单位阻塞但未开启 auto_skip_ready_units -> 仍返回 BLOCKED 维持 IDLE
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS })
    local rBlockedUnits = sendRpc(503, "end_turn", { auto_skip_ready_units = false })
    truthy(rBlockedUnits.ok, "待命单位阻塞亦应返 ok=true 保真回传")
    eq(rBlockedUnits.data.status, "BLOCKED", "未开启自动跳过时应返回 BLOCKED")
    eq(rBlockedUnits.data.blocking_info.blocking_unit_id, warrior:GetID(), "应携带待命单位 ID")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "仍维持 IDLE")

    -- 分支 3：开启 auto_skip_ready_units=true 跳过待命单位后成功提交下一回合 -> 立即切入 AI_TURN_LOCKED
    local rSuccess = sendRpc(504, "end_turn", { auto_skip_ready_units = true })
    truthy(rSuccess.ok, "成功提交下一回合应返 ok=true")
    eq(rSuccess.data.status, "WAITING_NEXT_TURN", "status 应为 WAITING_NEXT_TURN")
    truthy(rSuccess.data.turn_ended, "turn_ended 应为 true")
    eq(rSuccess.data.ended_turn_number, 15, "ended_turn_number 应为 15")
    same(rSuccess.data.auto_skipped_unit_ids, { warrior:GetID() }, "应记录自动跳过的单位 ID")
    truthy(w.endTurnRequested, "应实际提交 CONTROL_ENDTURN")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "turn_ended=true 后必须立即切入 AI_TURN_LOCKED")
    eq(S.extIO.lastHeartbeat().status, "AI_TURN_PROCESSING", "提交后应立即写入 AI_TURN_PROCESSING 心跳")
    eq(S.extIO.lastHeartbeat().turnSeq, 1, "心跳应携带当前 s_TurnEventSeq")
    eq(uiLog[#uiLog], "Agent: AI Turn...", "UI 应刷新为 Agent: AI Turn...")

    -- 关键窗口防护：即使引擎尚未在当帧将 IsTurnActive() 翻转为 false，后续写指令仍必须被 AI_TURN_LOCKED 拦截
    w:clearWriteLog()
    local rPostEndWrite = sendRpc(505, "purchase_city_plot", { city_id = 0, target_x = 3, target_y = 5 })
    falsy(rPostEndWrite.ok, "end_turn 刚提交后紧跟的写指令必须被 AI_TURN_LOCKED 拦截")
    eq(rPostEndWrite.error, "Player turn is not active (AI turn in progress)", "应返回非活动回合错误")
    eq(w:writeCount(), 0, "拦截期间零引擎写入")
end)

test("T-16", "5 类写动作入参校验、前置失败信封与成功挂起 s_PendingSettlement 装配（A-04 / D-05）", function()
    -- 1. execute_unit_action：入参守卫、前置失败、默认等待与 settle_delay_sec 钳制（[0, 1.50]）
    do
        local w, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        w:clearWriteLog()

        falsy(sendRpc(601, "execute_unit_action", { action_type = "MOVE_STEP" }).ok, "缺 unit_id 拦截")
        falsy(sendRpc(602, "execute_unit_action", { unit_id = warrior:GetID(), action_type = "" }).ok, "空 action_type 拦截")
        falsy(sendRpc(603, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = "5", target_y = 4,
        }).ok, "非整数 target_x 拦截")
        falsy(sendRpc(604, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4, settle_delay_sec = "fast",
        }).ok, "非数值 settle_delay_sec 拦截")
        -- 前置校验失败（距离 > 1）
        local rBadMove = sendRpc(605, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 12, target_y = 12,
        })
        falsy(rBadMove.ok, "越界/非相邻 MOVE_STEP 前置失败应返 ok=false")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "失败维持 IDLE")
        eq(w:writeCount(), 0, "前置失败零写入")

        -- 合法 MOVE_STEP（缺省 settle_delay_sec -> 0.35s）
        local resp, cnt = sendRpc(606, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        eq(cnt, 0, "异步动作挂起期间不得提前发送 RPC 响应")
        isNil(resp, "响应尚未产出")
        local st = CAB_Dispatcher.GetRuntimeState()
        eq(st.bridge_state, "WAITING_SETTLEMENT", "成功后必须切入 WAITING_SETTLEMENT")
        truthy(st.has_pending_settlement, "has_pending_settlement 应为 true")
        eq(st.pending_req_id, 606, "pending_req_id 匹配")
        eq(st.pending_method, "execute_unit_action", "pending_method 匹配")
        eq(st.pending_kind, "UNIT_ACTION", "pending_kind 应为 UNIT_ACTION")
        eq(st.pending_min_wait_sec, CAB_Config.DEFAULT_UNIT_SETTLE_SEC, "缺省 minWaitSec 应为 0.35s")
        eq(st.pending_max_timeout_sec, CAB_Config.MAX_SETTLE_TIMEOUT_SEC, "maxTimeoutSec 应为 1.50s")
    end

    -- 1b. execute_unit_action 的 settle_delay_sec 钳制矩阵（负数 -> 0 / 0.6 -> 0.6 / 超上限 -> 1.50）
    local delayCases = {
        { input = -0.5, expected = 0 },
        { input = 0,    expected = 0 },
        { input = 0.6,  expected = 0.6 },
        { input = 9.9,  expected = CAB_Config.MAX_SETTLE_TIMEOUT_SEC },
    }
    for i, dc in ipairs(delayCases) do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        local _, cnt = sendRpc(610 + i, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "FORTIFY",
            settle_delay_sec = dc.input,
        })
        eq(cnt, 0, "settle_delay_sec=" .. tostring(dc.input) .. " 统一走异步帧结算（零同步直返）")
        local st = CAB_Dispatcher.GetRuntimeState()
        eq(st.bridge_state, "WAITING_SETTLEMENT", "切入 WAITING_SETTLEMENT")
        eq(st.pending_min_wait_sec, dc.expected, "settle_delay_sec=" .. tostring(dc.input) .. " 钳制值应为 " .. tostring(dc.expected))
    end

    -- 2. execute_city_attack（CITY_ATTACK）
    do
        local w, _, _, city = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        w:clearWriteLog()

        falsy(sendRpc(621, "execute_city_attack", { city_id = city:GetID(), target_x = 6 }).ok, "缺 target_y 拦截")
        falsy(sendRpc(622, "execute_city_attack", { city_id = city:GetID(), target_x = 15, target_y = 15 }).ok, "超出射程前置失败返 ok=false")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "失败维持 IDLE")
        eq(w:writeCount(), 0, "前置失败零写入")

        local _, cnt = sendRpc(623, "execute_city_attack", {
            city_id = city:GetID(), target_x = 6, target_y = 5,
        })
        eq(cnt, 0, "城防炮击挂起期间不提前写回")
        local st = CAB_Dispatcher.GetRuntimeState()
        eq(st.bridge_state, "WAITING_SETTLEMENT", "切入 WAITING_SETTLEMENT")
        eq(st.pending_req_id, 623, "pending_req_id 匹配")
        eq(st.pending_method, "execute_city_attack", "pending_method 匹配")
        eq(st.pending_kind, "CITY_ATTACK", "pending_kind 应为 CITY_ATTACK")
        eq(st.pending_min_wait_sec, CAB_Config.DEFAULT_UNIT_SETTLE_SEC, "CITY_ATTACK minWaitSec 应为 0.35s")
    end

    -- 3. purchase_city_item（PURCHASE_ITEM：缺省 BUILDING/GOLD 与显式 UNIT/FAITH）
    do
        local w, _, _, city = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        w:clearWriteLog()

        falsy(sendRpc(631, "purchase_city_item", { city_id = city:GetID() }).ok, "缺 item 拦截")
        falsy(sendRpc(632, "purchase_city_item", { city_id = city:GetID(), item = "BUILDING_UNKNOWN" }).ok, "未知建筑前置失败返 ok=false")
        falsy(sendRpc(633, "purchase_city_item", { city_id = city:GetID(), item = "BUILDING_GRANARY", item_category = 123 }).ok, "非字符串 item_category 拦截")
        eq(w:writeCount(), 0, "前置失败零写入")

        local _, cnt = sendRpc(634, "purchase_city_item", {
            city_id = city:GetID(),
            item = "BUILDING_GRANARY",
        })
        eq(cnt, 0, "买建筑挂起期间不提前写回")
        local st = CAB_Dispatcher.GetRuntimeState()
        eq(st.bridge_state, "WAITING_SETTLEMENT", "切入 WAITING_SETTLEMENT")
        eq(st.pending_kind, "PURCHASE_ITEM", "pending_kind 应为 PURCHASE_ITEM")
        eq(st.pending_min_wait_sec, CAB_Config.PLOT_BUY_SETTLE_SEC, "PURCHASE_ITEM minWaitSec 应为 0.10s")
    end

    do
        local _, _, _, city = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        local _, cnt = sendRpc(635, "purchase_city_item", {
            city_id = city:GetID(),
            item_category = "UNIT",
            item = GameInfoTypes.UNIT_ARCHER,
            yield_type = "FAITH",
        })
        eq(cnt, 0, "信仰整数 ID 买单位成功挂起")
        eq(CAB_Dispatcher.GetRuntimeState().pending_kind, "PURCHASE_ITEM", "pending_kind 应为 PURCHASE_ITEM")
    end

    -- 4. set_city_production（SET_PRODUCTION）
    do
        local w, _, _, city = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        w:clearWriteLog()

        falsy(sendRpc(641, "set_city_production", { city_id = city:GetID(), item = "BUILDING_MONUMENT" }).ok, "缺 order_category 拦截")
        falsy(sendRpc(642, "set_city_production", {
            city_id = city:GetID(), order_category = "BAD_CAT", item = "BUILDING_MONUMENT",
        }).ok, "非法 order_category 前置失败返 ok=false")
        eq(w:writeCount(), 0, "前置失败零写入")

        local _, cnt = sendRpc(643, "set_city_production", {
            city_id = city:GetID(),
            order_category = "BUILDING",
            item = "BUILDING_MONUMENT",
            clear_queue = false,
        })
        eq(cnt, 0, "设生产挂起期间不提前写回")
        local st = CAB_Dispatcher.GetRuntimeState()
        eq(st.bridge_state, "WAITING_SETTLEMENT", "切入 WAITING_SETTLEMENT")
        eq(st.pending_kind, "SET_PRODUCTION", "pending_kind 应为 SET_PRODUCTION")
        eq(st.pending_min_wait_sec, CAB_Config.PLOT_BUY_SETTLE_SEC, "SET_PRODUCTION minWaitSec 应为 0.10s")
    end

    -- 5. purchase_city_plot（BUY_PLOT：主字段 target_x/target_y 与备选别名 plot_x/plot_y）
    do
        local w, _, _, city = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        w:clearWriteLog()

        falsy(sendRpc(651, "purchase_city_plot", { city_id = city:GetID(), target_x = 3 }).ok, "缺 target_y 拦截")
        falsy(sendRpc(652, "purchase_city_plot", { city_id = city:GetID(), target_x = 0, target_y = 0 }).ok, "不可购格前置失败返 ok=false")
        eq(w:writeCount(), 0, "前置失败零写入")

        local _, cnt1 = sendRpc(653, "purchase_city_plot", {
            city_id = city:GetID(), target_x = 3, target_y = 5,
        })
        eq(cnt1, 0, "主字段 target_x/target_y 买地挂起")
        local st1 = CAB_Dispatcher.GetRuntimeState()
        eq(st1.bridge_state, "WAITING_SETTLEMENT", "切入 WAITING_SETTLEMENT")
        eq(st1.pending_kind, "BUY_PLOT", "pending_kind 应为 BUY_PLOT")
        eq(st1.pending_min_wait_sec, CAB_Config.PLOT_BUY_SETTLE_SEC, "BUY_PLOT minWaitSec 应为 0.10s")
    end

    do
        local _, _, _, city = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        local _, cnt2 = sendRpc(654, "purchase_city_plot", {
            city_id = city:GetID(), plot_x = 3, plot_y = 4,
        })
        eq(cnt2, 0, "备选别名 plot_x/plot_y 买地挂起")
        eq(CAB_Dispatcher.GetRuntimeState().pending_kind, "BUY_PLOT", "别名参数同样正确装配 BUY_PLOT")
    end
end)

test("T-17", "WAITING_SETTLEMENT 挂起期互斥守卫：重入拒返 Busy、手动同步护栏与抢占刷写（D-05 / S-03 / S-05）", function()
    local _, warrior = buildWp2World()
    S.reloadDispatcher()
    local uiCb, uiLog = makeUiRecorder()
    truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
    S.extIO.clearHistory()

    -- 1. 触发单位移动进入 WAITING_SETTLEMENT
    local _, cnt500 = sendRpc(700, "execute_unit_action", {
        unit_id = warrior:GetID(),
        action_type = "MOVE_STEP",
        target_x = 5,
        target_y = 4,
    })
    eq(cnt500, 0, "在途异步动作尚未回执")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "进入 WAITING_SETTLEMENT")

    -- 2. 挂起期异常重入任何请求均立返 Busy 且绝不污染在途槽位（S-03）
    local rBusy1, nBusy1 = sendRpc(701, "ping", {})
    eq(nBusy1, 1, "重入 ping 应立即得到 1 条错返")
    falsy(rBusy1.ok, "重入请求 ok 应为 false")
    eq(rBusy1.error, "Bridge is busy waiting for pending settlement", "Busy 错误文案精确匹配")

    local rBusy2, nBusy2 = sendRpc(702, "get_turn_overview", {})
    eq(nBusy2, 1, "重入只读查询亦应立返 Busy")
    falsy(rBusy2.ok, "重入只读查询 ok 应为 false")

    local stBusy = CAB_Dispatcher.GetRuntimeState()
    eq(stBusy.bridge_state, "WAITING_SETTLEMENT", "重入拒绝不得改变 WAITING_SETTLEMENT 状态")
    eq(stBusy.pending_req_id, 700, "在途 pending_req_id 仍完整保留为 700")
    eq(#S.extIO.responsesFor(700), 0, "在途 req_id=700 尚未提前回执")

    -- 3. 挂起期点击手动同步按钮不得覆写快照（S-05）
    CAB_Dispatcher.OnManualSyncClicked()
    eq(#S.extIO.turnOverviews, 0, "S-05：挂起期手动同步严禁推送快照")
    eq(uiLog[#uiLog], "Agent: Busy (Settling...)", "挂起期手动同步仅更新 UI 提示")

    -- 4. 触发 OnActivePlayerTurnEnd 抢占刷写：保证 req_id=700 有且仅有 1 次结算回执且退役 sync_frame_comparison
    CAB_Dispatcher.OnActivePlayerTurnEnd()
    local resps700 = S.extIO.responsesFor(700)
    eq(#resps700, 1, "S-03：抢占刷写必须为在途 req_id=700 补发恰好 1 次回执")
    truthy(resps700[1].ok, "抢占刷写结算结果应以 ok=true 返回")
    truthy(resps700[1].data.executed, "单位移动应已落地 executed=true")
    isNil(resps700[1].data.sync_frame_comparison, "D-05：必须已退役 EXP-04 字段 sync_frame_comparison")
    local stAfter = CAB_Dispatcher.GetRuntimeState()
    falsy(stAfter.has_pending_settlement, "抢占刷写后必须清空挂起槽位")
    eq(stAfter.bridge_state, "AI_TURN_LOCKED", "抢占后切入 AI_TURN_LOCKED")
end)

-- -----------------------------------------------------------------------------
-- 第 4 节：WP3 5 类异步帧结算、超时兜底、抢占防死锁、时钟防护、异常自愈与节流用例（T-18 ~ T-24）
-- -----------------------------------------------------------------------------

test("T-18", "UNIT_ACTION 与 CITY_ATTACK 两段式帧结算闭环（含忙碌等待与 settle_delay_sec）（A-07 / D-05 / S-03）", function()
    -- 1. UNIT_ACTION (ATTACK_MELEE) 带 busyTicks / fightingTicks 跨帧结算
    do
        local w, warrior = buildWp2World()
        w:setUnit(warrior, {
            combatOutcome = {
                damageToTarget = 40,
                counterDamage = 10,
                busyTicks = 2,
                fightingTicks = 2,
            },
        })
        S.reloadDispatcher()
        local uiCb, uiLog = makeUiRecorder()
        truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
        S.extIO.clearHistory()

        local _, cnt0 = sendRpc(801, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "MELEE_ATTACK",
            target_x = 6,
            target_y = 5,
        })
        eq(cnt0, 0, "异步近战下发后不得提前写回")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "进入 WAITING_SETTLEMENT")

        -- 推进 0.20s（未满 minWaitSec=0.35s）
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(801), 0, "未满 0.35s 不得提前结算")
        eq(S.extIO.pollCallCount, 0, "S-03：挂起期严禁轮询")
        eq(CAB_Dispatcher.GetRuntimeState().pending_elapsed_sec, 0.20, "pending_elapsed_sec 应推进至 0.20s")

        -- 再推进 0.20s（达 0.40s >= 0.35s，但 busyTicks/fightingTicks 仍为 2 -> 继续挂起）
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(801), 0, "动画仍忙碌时满 0.35s 后仍须继续等待")
        eq(S.extIO.pollCallCount, 0, "S-03：持续挂起期严禁轮询")

        -- 推进 1 个引擎动画 tick（仍余 1 tick）
        w:tickSettlement(1)
        CAB_Dispatcher.OnFrameUpdate(0.10)
        eq(#S.extIO.responsesFor(801), 0, "仍余 1 tick 战斗动画时不得提前结算")

        -- 推进最后 1 个 tick，动画结束 -> 下一帧立即收口结算
        w:tickSettlement(1)
        CAB_Dispatcher.OnFrameUpdate(0.05)

        local resps = S.extIO.responsesFor(801)
        eq(#resps, 1, "动画结束后应恰好写回 1 次结算响应")
        truthy(resps[1].ok, "结算响应 ok 应为 true")
        truthy(resps[1].data.executed, "executed 应为 true")
        falsy(resps[1].data.timed_out, "正常动画结束 timed_out 应为 false")
        eq(resps[1].data.settle_wait_ms, 550, "settle_wait_ms 应精确记录累计 550ms")
        eq(resps[1].data.unit_after.hp, 90, "应回读反击扣血后的己方剩余 HP=90")
        eq(resps[1].data.delta_observation.target_enemy_after.hp, 60, "应回读目标敌军剩余 HP=60")
        isNil(resps[1].data.sync_frame_comparison, "D-05：必须已退役 sync_frame_comparison")
        eq(uiLog[#uiLog], "Agent: Settled #801", "UI 应刷新为 Agent: Settled #801")
        eq(S.extIO.pollCallCount, 0, "结算收口当帧不得顺带轮询新请求")

        local stAfter = CAB_Dispatcher.GetRuntimeState()
        eq(stAfter.bridge_state, "IDLE", "结算完成后恢复 IDLE")
        falsy(stAfter.has_pending_settlement, "挂起槽位已清空")
        isNil(stAfter.pending_elapsed_sec, "空闲态 pending_elapsed_sec 应为 nil")
    end

    -- 2. execute_unit_action 传 settle_delay_sec=0.05 与 0 缩短最小等待时长
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(802, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "FORTIFY",
            settle_delay_sec = 0.05,
        })
        CAB_Dispatcher.OnFrameUpdate(0.04)
        eq(#S.extIO.responsesFor(802), 0, "0.04s < 0.05s 时尚未结算")
        CAB_Dispatcher.OnFrameUpdate(0.01)
        local r802 = S.extIO.responsesFor(802)
        eq(#r802, 1, "满 0.05s 立即结算")
        truthy(r802[1].ok, "FORTIFY 结算 ok=true")
        falsy(r802[1].data.timed_out, "timed_out=false")
        eq(r802[1].data.settle_wait_ms, 50, "settle_wait_ms=50")
    end

    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(803, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "SKIP_TURN",
            settle_delay_sec = 0,
        })
        eq(#S.extIO.responsesFor(803), 0, "settle_delay_sec=0 亦统一走异步帧结算")
        CAB_Dispatcher.OnFrameUpdate(0.01)
        local r803 = S.extIO.responsesFor(803)
        eq(#r803, 1, "首个有效正帧即可结算")
        truthy(r803[1].ok, "SKIP_TURN 结算 ok=true")
        eq(r803[1].data.settle_wait_ms, 10, "settle_wait_ms=10")
    end

    -- 3. CITY_ATTACK 带 fightingTicks 跨帧结算闭环
    do
        local w, _, _, city = buildWp2World()
        w:setCity(city, {
            rangedOutcome = { damageToTarget = 35, fightingTicks = 2 },
        })
        S.reloadDispatcher()
        local uiCb, uiLog = makeUiRecorder()
        truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(804, "execute_city_attack", {
            city_id = city:GetID(),
            target_x = 6,
            target_y = 5,
        })
        CAB_Dispatcher.OnFrameUpdate(0.35)
        eq(#S.extIO.responsesFor(804), 0, "城防炮击目标格仍在战斗时保持挂起")

        w:tickSettlement(2)
        CAB_Dispatcher.OnFrameUpdate(0.05)

        local r804 = S.extIO.responsesFor(804)
        eq(#r804, 1, "炮击动画结束后写回 1 次结算响应")
        truthy(r804[1].ok, "CITY_ATTACK ok=true")
        truthy(r804[1].data.executed, "CITY_ATTACK executed=true")
        eq(r804[1].data.action_type, "CITY_RANGE_ATTACK", "action_type 对齐 CITY_RANGE_ATTACK")
        falsy(r804[1].data.timed_out, "timed_out=false")
        eq(r804[1].data.settle_wait_ms, 400, "settle_wait_ms=400")
        eq(r804[1].data.city_after.city_id, city:GetID(), "city_after 匹配")
        eq(r804[1].data.delta_observation.target_enemy_after.hp, 65, "敌军扣血至 65 HP")
        eq(uiLog[#uiLog], "Agent: Settled #804", "UI 提示 Settled #804")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "恢复 IDLE")
    end
end)

test("T-19", "城市内政 3 类短延迟异步帧结算闭环：PURCHASE_ITEM / SET_PRODUCTION / BUY_PLOT（A-07 / D-04）", function()
    local w, _, _, city = buildWp2World()
    w.cityActionDelayTicks = 2
    w.plotBuyDelayTicks = 2

    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")
    S.extIO.clearHistory()

    -- 1a. PURCHASE_ITEM（金币购买建筑 BUILDING_GRANARY，延迟 2 ticks 落地）
    sendRpc(811, "purchase_city_item", {
        city_id = city:GetID(),
        item = "BUILDING_GRANARY",
    })
    CAB_Dispatcher.OnFrameUpdate(0.05)
    eq(#S.extIO.responsesFor(811), 0, "未满 0.10s 保持挂起")
    CAB_Dispatcher.OnFrameUpdate(0.05)
    eq(#S.extIO.responsesFor(811), 0, "满 0.10s 但建筑消息队列尚未落地时保持挂起")
    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.05)
    eq(#S.extIO.responsesFor(811), 0, "仍余 1 tick 时保持挂起")

    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.05)
    local r811 = S.extIO.responsesFor(811)
    eq(#r811, 1, "建筑落地后下一帧完成结算")
    truthy(r811[1].ok, "买建筑 ok=true")
    truthy(r811[1].data.purchased, "purchased 应为 true")
    falsy(r811[1].data.timed_out, "timed_out=false")
    eq(r811[1].data.cost_paid, 200, "应回读金币扣费 200")
    eq(r811[1].data.gold_before, 800, "gold_before=800")
    eq(r811[1].data.gold_after, 600, "gold_after=600")
    eq(r811[1].data.settle_wait_ms, 200, "settle_wait_ms=200")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "恢复 IDLE")

    -- 1b. PURCHASE_ITEM（信仰购买单位 UNIT_ARCHER，精准回读 spawned_unit_id）
    sendRpc(812, "purchase_city_item", {
        city_id = city:GetID(),
        item_category = "UNIT",
        item = "UNIT_ARCHER",
        yield_type = "FAITH",
    })
    w:tickSettlement(2)
    CAB_Dispatcher.OnFrameUpdate(0.10)
    local r812 = S.extIO.responsesFor(812)
    eq(#r812, 1, "信仰买单位应完成结算")
    truthy(r812[1].ok, "信仰买单位 ok=true")
    truthy(r812[1].data.purchased, "purchased=true")
    falsy(r812[1].data.timed_out, "timed_out=false")
    eq(r812[1].data.yield_type, "FAITH", "yield_type=FAITH")
    eq(r812[1].data.cost_paid, 120, "信仰扣费 120")
    eq(r812[1].data.faith_before, 400, "faith_before=400")
    eq(r812[1].data.faith_after, 280, "faith_after=280")
    notNil(r812[1].data.spawned_unit_id, "应精准识别新生单位 spawned_unit_id")

    -- 2. SET_PRODUCTION（先清空设产 BUILDING_MONUMENT，再追加队列 UNIT_WARRIOR）
    sendRpc(813, "set_city_production", {
        city_id = city:GetID(),
        order_category = "BUILDING",
        item = "BUILDING_MONUMENT",
        clear_queue = true,
    })
    CAB_Dispatcher.OnFrameUpdate(0.10)
    eq(#S.extIO.responsesFor(813), 0, "设产队列尚未生效前保持挂起")
    w:tickSettlement(2)
    CAB_Dispatcher.OnFrameUpdate(0.05)
    local r813 = S.extIO.responsesFor(813)
    eq(#r813, 1, "设产生效后完成结算")
    truthy(r813[1].ok, "SET_PRODUCTION ok=true")
    truthy(r813[1].data.executed, "executed=true")
    falsy(r813[1].data.timed_out, "timed_out=false")
    eq(r813[1].data.order_queue_length, 1, "队列长度应为 1")

    sendRpc(814, "set_city_production", {
        city_id = city:GetID(),
        order_category = "UNIT",
        item = "UNIT_WARRIOR",
        clear_queue = false,
    })
    w:tickSettlement(2)
    CAB_Dispatcher.OnFrameUpdate(0.10)
    local r814 = S.extIO.responsesFor(814)
    eq(#r814, 1, "追加队列生效后完成结算")
    truthy(r814[1].ok, "追加队列 ok=true")
    truthy(r814[1].data.executed, "追加队列 executed=true")
    falsy(r814[1].data.timed_out, "timed_out=false")
    eq(r814[1].data.order_queue_length, 2, "追加后队列长度应为 2")

    -- 3. BUY_PLOT（买地延迟 2 ticks，领土归属翻转后结算）
    sendRpc(815, "purchase_city_plot", {
        city_id = city:GetID(),
        target_x = 3,
        target_y = 5,
    })
    CAB_Dispatcher.OnFrameUpdate(0.10)
    eq(#S.extIO.responsesFor(815), 0, "地块归属尚未翻转前保持挂起")
    w:tickSettlement(2)
    CAB_Dispatcher.OnFrameUpdate(0.05)
    local r815 = S.extIO.responsesFor(815)
    eq(#r815, 1, "地块归属翻转后完成结算")
    truthy(r815[1].ok, "BUY_PLOT ok=true")
    truthy(r815[1].data.purchased, "purchased=true")
    falsy(r815[1].data.timed_out, "timed_out=false")
    eq(r815[1].data.new_owner_id, 0, "new_owner_id 应翻转为 0")
    eq(r815[1].data.cost_paid, 50, "买地扣费 50")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "全部内政结算后恢复 IDLE")
end)

test("T-20", "1.50s 硬超时兜底与 D-04 信封保真（战斗忙碌超时 + 3 类城市队列超时）（A-07 / D-04）", function()
    -- 1. UNIT_ACTION 持续忙碌直至 1.50s 硬超时
    do
        local w, warrior = buildWp2World()
        w:setUnit(warrior, {
            combatOutcome = { damageToTarget = 20, counterDamage = 5, busyTicks = 99, fightingTicks = 99 },
        })
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(821, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "MELEE_ATTACK",
            target_x = 6,
            target_y = 5,
        })
        for _ = 1, 14 do
            CAB_Dispatcher.OnFrameUpdate(0.10)
        end
        eq(#S.extIO.responsesFor(821), 0, "1.40s < 1.50s 时持续忙碌仍须挂起")

        CAB_Dispatcher.OnFrameUpdate(0.10)
        local r821 = S.extIO.responsesFor(821)
        eq(#r821, 1, "满 1.50s 必须触发硬超时兜底收口")
        truthy(r821[1].ok, "D-04：超时结算 DTO 必须以 ok=true 保真透传")
        truthy(r821[1].data.timed_out, "timed_out 应为 true")
        eq(r821[1].data.settle_wait_ms, 1500, "settle_wait_ms 应为 1500")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "超时收口后恢复 IDLE")
    end

    -- 2. BUY_PLOT 消息永不落地 -> 1.50s 超时返回 ok=true, purchased=false, timed_out=true
    do
        local w, _, _, city = buildWp2World()
        w.plotBuyDelayTicks = 99
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(822, "purchase_city_plot", { city_id = city:GetID(), target_x = 3, target_y = 5 })
        CAB_Dispatcher.OnFrameUpdate(0.50)
        CAB_Dispatcher.OnFrameUpdate(0.50)
        eq(#S.extIO.responsesFor(822), 0, "1.00s 尚未触达 1.50s 硬超时")
        CAB_Dispatcher.OnFrameUpdate(0.50)

        local r822 = S.extIO.responsesFor(822)
        eq(#r822, 1, "BUY_PLOT 满 1.50s 强制收口")
        truthy(r822[1].ok, "D-04：BUY_PLOT 超时仍须以 ok=true 保真透传")
        falsy(r822[1].data.purchased, "purchased 应为 false")
        truthy(r822[1].data.timed_out, "timed_out 应为 true")
        contains(r822[1].data.error_reason, "timeout", "应附带超时错误原因")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "恢复 IDLE")
    end

    -- 3. PURCHASE_ITEM 消息永不落地 -> 1.50s 超时返回 ok=true, purchased=false, timed_out=true
    do
        local w, _, _, city = buildWp2World()
        w.cityActionDelayTicks = 99
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(823, "purchase_city_item", { city_id = city:GetID(), item = "BUILDING_GRANARY" })
        for _ = 1, 3 do CAB_Dispatcher.OnFrameUpdate(0.50) end

        local r823 = S.extIO.responsesFor(823)
        eq(#r823, 1, "PURCHASE_ITEM 满 1.50s 强制收口")
        truthy(r823[1].ok, "D-04：PURCHASE_ITEM 超时以 ok=true 保真透传")
        falsy(r823[1].data.purchased, "purchased 应为 false")
        truthy(r823[1].data.timed_out, "timed_out 应为 true")
        contains(r823[1].data.error_reason, "timeout", "应附带超时错误原因")
    end

    -- 4. SET_PRODUCTION 消息永不落地 -> 1.50s 超时返回 ok=true, executed=false, timed_out=true
    do
        local w, _, _, city = buildWp2World()
        w.cityActionDelayTicks = 99
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(824, "set_city_production", {
            city_id = city:GetID(),
            order_category = "BUILDING",
            item = "BUILDING_MONUMENT",
        })
        for _ = 1, 3 do CAB_Dispatcher.OnFrameUpdate(0.50) end

        local r824 = S.extIO.responsesFor(824)
        eq(#r824, 1, "SET_PRODUCTION 满 1.50s 强制收口")
        truthy(r824[1].ok, "D-04：SET_PRODUCTION 超时以 ok=true 保真透传")
        falsy(r824[1].data.executed, "executed 应为 false")
        truthy(r824[1].data.timed_out, "timed_out 应为 true")
        contains(r824[1].data.error_reason, "timeout", "应附带超时错误原因")
    end
end)

test("T-21", "跨回合与重初始化抢占刷写防死锁（TurnEnd / TurnStart / Initialize）与 1:1 幂等回执（A-08 / D-05 / S-03）", function()
    -- 1. TurnEnd 抢占刷写：携带已累积耗时 200ms，后续 OnFrameUpdate 绝不重复写回
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(831, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(831), 0, "抢占前尚未回执")

        CAB_Dispatcher.OnActivePlayerTurnEnd()
        local r831 = S.extIO.responsesFor(831)
        eq(#r831, 1, "TurnEnd 抢占必须补发恰好 1 次回执")
        truthy(r831[1].ok, "抢占结算应返回 ok=true")
        eq(r831[1].data.settle_wait_ms, 200, "应传入抢占前已累计耗时 200ms")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "抢占后切入 AI_TURN_LOCKED")
        falsy(CAB_Dispatcher.GetRuntimeState().has_pending_settlement, "挂起槽位已清空")

        for _ = 1, 4 do CAB_Dispatcher.OnFrameUpdate(0.50) end
        eq(#S.extIO.responsesFor(831), 1, "S-03：抢占清槽后继续驱动帧循环绝不得二次写回")
    end

    -- 2. TurnStart 抢占刷写：先收口旧响应再递增 turn_seq 推送新回合态势
    do
        local w, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(832, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        CAB_Dispatcher.OnFrameUpdate(0.20)

        w.turn = 16
        CAB_Dispatcher.OnActivePlayerTurnStart()
        local r832 = S.extIO.responsesFor(832)
        eq(#r832, 1, "TurnStart 抢占必须补发恰好 1 次回执")
        truthy(r832[1].ok, "TurnStart 抢占结算 ok=true")
        eq(r832[1].data.settle_wait_ms, 200, "累计耗时 200ms")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "TurnStart 后恢复 IDLE")
        eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 2, "turn_event_seq 递增至 2")
        eq(#S.extIO.turnOverviews, 1, "TurnStart 应推送新回合态势")

        for _ = 1, 4 do CAB_Dispatcher.OnFrameUpdate(0.50) end
        eq(#S.extIO.responsesFor(832), 1, "S-03：TurnStart 抢占后不得二次写回")
    end

    -- 3. Initialize 热重载重初始化抢占刷写
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "首次初始化成功")
        S.extIO.clearHistory()

        sendRpc(833, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        CAB_Dispatcher.OnFrameUpdate(0.20)

        truthy(CAB_Dispatcher.Initialize(), "热重载重初始化应成功")
        local r833 = S.extIO.responsesFor(833)
        eq(#r833, 1, "重初始化抢占必须补发恰好 1 次回执")
        truthy(r833[1].ok, "重初始化抢占结算 ok=true")
        eq(r833[1].data.settle_wait_ms, 200, "累计耗时 200ms")
        falsy(CAB_Dispatcher.GetRuntimeState().has_pending_settlement, "重初始化后挂起槽位已清空")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "重初始化后状态为 IDLE")
    end

    -- 4. 抢占期间 FinalizeActionSettlement 抛异常时降级写回 ok=false 中断错返且清槽（D-05 / S-04）
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(834, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        CAB_Dispatcher.OnFrameUpdate(0.15)

        local savedFin = CAB_Executor.FinalizeActionSettlement
        CAB_Executor.FinalizeActionSettlement = function()
            error("simulated preempt finalize crash")
        end
        local okTurnEnd, turnEndErr = pcall(CAB_Dispatcher.OnActivePlayerTurnEnd)
        CAB_Executor.FinalizeActionSettlement = savedFin

        truthy(okTurnEnd, "抢占刷写遇下游异常不得向外冒泡：" .. tostring(turnEndErr))
        local r834 = S.extIO.responsesFor(834)
        eq(#r834, 1, "异常降级仍须保证请求-响应 1:1")
        falsy(r834[1].ok, "异常降级响应 ok 应为 false")
        contains(r834[1].error, "simulated preempt finalize crash", "错误文案应包含异常原因")
        falsy(CAB_Dispatcher.GetRuntimeState().has_pending_settlement, "异常后仍须清空挂起槽位")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "切入 AI_TURN_LOCKED")
    end
end)

test("T-22", "帧时钟净化与单帧 0.50s 尖峰钳制（S-06 / A-08）", function()
    local badDts = { nil, "0.5", false, {}, 0, -0.2, 0 / 0, math.huge, -math.huge }

    -- 1. 空闲态喂入全量畸形 deltaTime：零轮询、零心跳、累加器严守 0
    do
        buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        for i = 1, 9 do
            CAB_Dispatcher.OnFrameUpdate(badDts[i])
        end
        local st = CAB_Dispatcher.GetRuntimeState()
        eq(st.poll_accum_sec, 0, "畸形 deltaTime 不得污染 poll_accum_sec")
        eq(st.heartbeat_accum_sec, 0, "畸形 deltaTime 不得污染 heartbeat_accum_sec")
        eq(S.extIO.pollCallCount, 0, "畸形 deltaTime 不得触发轮询")
        eq(#S.extIO.heartbeats, 0, "畸形 deltaTime 不得触发心跳")
    end

    -- 2. 挂起态（即使 settle_delay_sec=0）喂入全量畸形 deltaTime：零推进、零误结算
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(841, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "FORTIFY",
            settle_delay_sec = 0,
        })
        for i = 1, 9 do
            CAB_Dispatcher.OnFrameUpdate(badDts[i])
        end
        eq(#S.extIO.responsesFor(841), 0, "S-06：minWaitSec=0 时畸形 deltaTime 绝不得触发误结算")
        eq(CAB_Dispatcher.GetRuntimeState().pending_elapsed_sec, 0, "pending_elapsed_sec 严守 0")

        CAB_Dispatcher.OnFrameUpdate(0.01)
        eq(#S.extIO.responsesFor(841), 1, "随后首个有效正帧正常结算")
    end

    -- 3. 单帧卡顿尖峰（dt=5.0s）钳制上限 0.50s：绝不单帧跨过 1.50s 硬超时
    do
        local w, warrior = buildWp2World()
        w:setUnit(warrior, {
            combatOutcome = { damageToTarget = 30, counterDamage = 5, busyTicks = 2, fightingTicks = 2 },
        })
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(842, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "MELEE_ATTACK",
            target_x = 6,
            target_y = 5,
        })

        -- 单帧 5.0s 卡顿尖峰 -> 钳制为 0.50s（仍在忙碌，不触发 1.50s 超时）
        CAB_Dispatcher.OnFrameUpdate(5.0)
        eq(#S.extIO.responsesFor(842), 0, "S-06：单帧 5.0s 尖峰不得直接跨过 1.50s 硬超时")
        eq(CAB_Dispatcher.GetRuntimeState().pending_elapsed_sec, 0.50, "单帧步进必须被精确钳制为 0.50s")

        -- 引擎动画随后完成 -> 第 2 帧再遇 5.0s 尖峰（累计 1.00s），正常无超时结算
        w:tickSettlement(2)
        CAB_Dispatcher.OnFrameUpdate(5.0)
        local r842 = S.extIO.responsesFor(842)
        eq(#r842, 1, "动画结束后第 2 帧正常结算")
        truthy(r842[1].ok, "ok=true")
        falsy(r842[1].data.timed_out, "经尖峰钳制留出检查窗口，应正常无超时结算")
        eq(r842[1].data.settle_wait_ms, 1000, "累计等待耗时应为 1000ms")
    end

    -- 4. 持续忙碌下连续 5.0s 尖峰需满 3 帧（0.50 -> 1.00 -> 1.50）方触发硬超时
    do
        local w, warrior = buildWp2World()
        w:setUnit(warrior, {
            combatOutcome = { damageToTarget = 30, counterDamage = 5, busyTicks = 99, fightingTicks = 99 },
        })
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(843, "execute_unit_action", {
            unit_id = warrior:GetID(),
            action_type = "MELEE_ATTACK",
            target_x = 6,
            target_y = 5,
        })
        CAB_Dispatcher.OnFrameUpdate(5.0)
        eq(CAB_Dispatcher.GetRuntimeState().pending_elapsed_sec, 0.50, "第 1 帧钳制至 0.50s")
        CAB_Dispatcher.OnFrameUpdate(5.0)
        eq(CAB_Dispatcher.GetRuntimeState().pending_elapsed_sec, 1.00, "第 2 帧钳制至 1.00s")
        eq(#S.extIO.responsesFor(843), 0, "前 2 帧均不超时")

        CAB_Dispatcher.OnFrameUpdate(5.0)
        local r843 = S.extIO.responsesFor(843)
        eq(#r843, 1, "第 3 帧达 1.50s 触发硬超时兜底")
        truthy(r843[1].data.timed_out, "timed_out=true")
        eq(r843[1].data.settle_wait_ms, 1500, "settle_wait_ms=1500")
    end
end)

test("T-23", "帧循环全链路故障注入异常自愈与结算瞬间切非活动回合对齐（S-04 / A-08）", function()
    -- 1. IsSettlementBusy 瞬态抛错：首帧探测抛错不冒泡，恢复后满 minWaitSec 正常收口 ok=true 并回 IDLE
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(851, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })

        local savedBusy = CAB_Executor.IsSettlementBusy
        local throwOnce = true
        CAB_Executor.IsSettlementBusy = function(ctx)
            if throwOnce then
                throwOnce = false
                error("simulated transient IsSettlementBusy panic")
            end
            return savedBusy(ctx)
        end
        local okRun, runErr = pcall(function()
            CAB_Dispatcher.OnFrameUpdate(0.20)
            eq(#S.extIO.responsesFor(851), 0, "首帧探测抛错且未满 0.35s 时保持等待不崩溃")
            CAB_Dispatcher.OnFrameUpdate(0.20)
        end)
        CAB_Executor.IsSettlementBusy = savedBusy

        truthy(okRun, "IsSettlementBusy 抛错不得向外冒泡：" .. tostring(runErr))
        local r851 = S.extIO.responsesFor(851)
        eq(#r851, 1, "满 minWaitSec 后应正常结算收口")
        truthy(r851[1].ok, "瞬态恢复后 FinalizeActionSettlement 正常返回 ok=true")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "自愈回 IDLE")
    end

    -- 2. FinalizeActionSettlement 抛错：清槽、写回 ok=false、刷新 UI 错误提示、自愈回 IDLE
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        local uiCb, uiLog = makeUiRecorder()
        truthy(CAB_Dispatcher.Initialize(uiCb), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(852, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })

        local savedFin = CAB_Executor.FinalizeActionSettlement
        CAB_Executor.FinalizeActionSettlement = function()
            error("simulated FinalizeActionSettlement panic")
        end
        local okRun, runErr = pcall(CAB_Dispatcher.OnFrameUpdate, 0.35)
        CAB_Executor.FinalizeActionSettlement = savedFin

        truthy(okRun, "FinalizeActionSettlement 抛错不得向外冒泡：" .. tostring(runErr))
        local r852 = S.extIO.responsesFor(852)
        eq(#r852, 1, "必须兜底写回 1 条错误响应")
        falsy(r852[1].ok, "异常兜底响应 ok=false")
        contains(r852[1].error, "simulated FinalizeActionSettlement panic", "错误信息应透传异常内容")
        contains(uiLog[#uiLog], "Settle Error #852", "UI 应刷新 Settle Error 提示")
        falsy(CAB_Dispatcher.GetRuntimeState().has_pending_settlement, "挂起槽位已清空")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "S-04：状态机必须自愈回 IDLE")
    end

    -- 3. FinalizeActionSettlement 返回非 table：同样兜底 ok=false 并自愈
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(853, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        local savedFin = CAB_Executor.FinalizeActionSettlement
        CAB_Executor.FinalizeActionSettlement = function()
            return "invalid_non_table"
        end
        CAB_Dispatcher.OnFrameUpdate(0.35)
        CAB_Executor.FinalizeActionSettlement = savedFin

        local r853 = S.extIO.responsesFor(853)
        eq(#r853, 1, "非表返回必须兜底写回 1 条错返")
        falsy(r853[1].ok, "ok=false")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "恢复 IDLE")
    end

    -- 4. 结算完成瞬间引擎已切换为非活动回合：状态机自动恢复至 AI_TURN_LOCKED
    do
        local w, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(854, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })
        w:setPlayer(0, { turnActive = false })
        CAB_Dispatcher.OnFrameUpdate(0.35)

        eq(#S.extIO.responsesFor(854), 1, "结算完成正常写回")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "非活动回合下结算完成应恢复 AI_TURN_LOCKED")
    end

    -- 5. PollIncomingRequest 与 WriteHeartbeat 抛错：不中断帧循环，清除故障后自动恢复
    do
        buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        S.extIO.faults.pollThrow = "sqlite database locked"
        S.extIO.faults.heartbeatThrow = "sqlite readonly"
        local okTick, tickErr = pcall(CAB_Dispatcher.OnFrameUpdate, 2.00)
        S.extIO.faults.pollThrow = nil
        S.extIO.faults.heartbeatThrow = nil

        truthy(okTick, "外部 IO 轮询/心跳抛错不得中断 OnFrameUpdate：" .. tostring(tickErr))
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "故障后状态维持 IDLE")

        -- 故障解除后下一周期恢复正常轮询与心跳
        S.extIO.clearHistory()
        local reqId = S.extIO.enqueueRequest("ping", { echo = "recovered" })
        CAB_Dispatcher.OnFrameUpdate(2.00)
        eq(S.extIO.pollCallCount, 1, "故障解除后恢复正常轮询")
        eq(#S.extIO.responsesFor(reqId), 1, "恢复后正常处理入站请求")
        truthy(S.extIO.responsesFor(reqId)[1].ok, "恢复后 ping ok=true")
        eq(#S.extIO.heartbeats, 1, "故障解除后恢复正常心跳写入")
        eq(S.extIO.lastHeartbeat().status, "IDLE", "心跳状态为 IDLE")
    end
end)

test("T-24", "节流精度（0.20s 轮询 / 2.00s 心跳）、AI 态节流与端到端全自动队列驱动闭环（A-07 / A-08 / S-03）", function()
    -- 1. 挂起期累计 1.0s 严格零 PollIncomingRequest（S-03）
    do
        local w, warrior = buildWp2World()
        w:setUnit(warrior, {
            combatOutcome = { damageToTarget = 20, counterDamage = 5, busyTicks = 99, fightingTicks = 99 },
        })
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        sendRpc(860, "execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MELEE_ATTACK", target_x = 6, target_y = 5,
        })
        for _ = 1, 5 do
            CAB_Dispatcher.OnFrameUpdate(0.20)
        end
        eq(S.extIO.pollCallCount, 0, "S-03：挂起期累计 1.0s 必须严格零轮询")
        eq(#S.extIO.heartbeats, 0, "挂起期不走空闲心跳分支")
    end

    -- 2. IDLE 态 IEEE-754 浮点漂移边界精度：0.02s x 10 = 0.20s 轮询，0.10s x 20 = 2.00s 心跳
    do
        buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        for _ = 1, 9 do
            CAB_Dispatcher.OnFrameUpdate(0.02)
        end
        eq(S.extIO.pollCallCount, 0, "0.18s < 0.20s 不得早触发轮询")
        CAB_Dispatcher.OnFrameUpdate(0.02)
        eq(S.extIO.pollCallCount, 1, "0.02s x 10 达 0.20s 应精准触发 1 次轮询（零 IEEE-754 漂移漏触发）")
        eq(CAB_Dispatcher.GetRuntimeState().poll_accum_sec, 0, "触发后 poll_accum_sec 归零")

        -- 重置历史再测 2.00s 心跳（0.10s x 20）
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()
        for _ = 1, 19 do
            CAB_Dispatcher.OnFrameUpdate(0.10)
        end
        eq(#S.extIO.heartbeats, 0, "1.90s < 2.00s 不得早触发心跳")
        CAB_Dispatcher.OnFrameUpdate(0.10)
        eq(#S.extIO.heartbeats, 1, "0.10s x 20 达 2.00s 应精准触发 1 次 IDLE 心跳")
        eq(S.extIO.lastHeartbeat().status, "IDLE", "IDLE 态心跳状态应为 IDLE")
        eq(S.extIO.lastHeartbeat().turnSeq, 1, "心跳携带当前 turnSeq=1")
        eq(S.extIO.pollCallCount, 10, "2.00s 内每 0.20s 轮询一次，共 10 次")
    end

    -- 3. AI_TURN_LOCKED 态节流：0.20s 正常轮询放行白名单/拦截写指令，2.00s 写入 AI_TURN_PROCESSING 心跳
    do
        local w, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        w:setPlayer(0, { turnActive = false })
        CAB_Dispatcher.OnActivePlayerTurnEnd()
        S.extIO.clearHistory()

        local idPing = S.extIO.enqueueRequest("ping", { echo = "ai_poll" })
        local idBlocked = S.extIO.enqueueRequest("execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        })

        CAB_Dispatcher.OnFrameUpdate(0.20)
        local rPing = S.extIO.responsesFor(idPing)
        eq(#rPing, 1, "AI 回合 0.20s 轮询应取出并响应白名单 ping")
        truthy(rPing[1].ok, "AI 回合 ping ok=true")
        eq(rPing[1].data.status, "AI_TURN_LOCKED", "ping.status=AI_TURN_LOCKED")

        CAB_Dispatcher.OnFrameUpdate(0.20)
        local rBlk = S.extIO.responsesFor(idBlocked)
        eq(#rBlk, 1, "AI 回合下一 0.20s 轮询应取出并拦截写动作")
        falsy(rBlk[1].ok, "写动作被门控拦截 ok=false")
        eq(rBlk[1].error, "Player turn is not active (AI turn in progress)", "门控报错匹配")

        -- 累计余下 1.60s 达 2.00s 心跳周期
        for _ = 1, 8 do
            CAB_Dispatcher.OnFrameUpdate(0.20)
        end
        eq(#S.extIO.heartbeats, 1, "AI 回合满 2.00s 应写入 1 次周期心跳")
        eq(S.extIO.lastHeartbeat().status, "AI_TURN_PROCESSING", "AI 回合周期心跳状态应为 AI_TURN_PROCESSING")
    end

    -- 4. 端到端全自动队列驱动闭环：纯靠 OnFrameUpdate(0.20) 串行跑完 4 条跨同步/异步/结束回合指令
    do
        local _, warrior = buildWp2World()
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        local q1 = S.extIO.enqueueRequest("ping", { echo = "step1" }, 901)
        local q2 = S.extIO.enqueueRequest("execute_unit_action", {
            unit_id = warrior:GetID(), action_type = "MOVE_STEP", target_x = 5, target_y = 4,
        }, 902)
        local q3 = S.extIO.enqueueRequest("get_turn_overview", {}, 903)
        local q4 = S.extIO.enqueueRequest("end_turn", { auto_skip_ready_units = true }, 904)

        -- 帧 1 (0.20s)：轮询取出 q1(ping) 并即时响应
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(q1), 1, "帧 1 完成 q1(ping)")
        truthy(S.extIO.responsesFor(q1)[1].ok, "q1 ok=true")
        eq(#S.extIO.incomingQueue, 3, "队列剩余 3 条")

        -- 帧 2 (0.20s)：轮询取出 q2(execute_unit_action) 进入 WAITING_SETTLEMENT
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "帧 2 切入 WAITING_SETTLEMENT")
        eq(#S.extIO.responsesFor(q2), 0, "q2 尚未结算")
        eq(#S.extIO.incomingQueue, 2, "队列剩余 2 条")

        -- 帧 3 (0.20s)：挂起推进 0.20s < 0.35s，暂停轮询不取 q3
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "帧 3 继续挂起")
        eq(#S.extIO.incomingQueue, 2, "S-03：挂起期不得提前取出 q3")

        -- 帧 4 (0.20s)：挂起累计 0.40s >= 0.35s 且不忙 -> 结算 q2，本帧仍不取 q3
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(q2), 1, "帧 4 完成 q2 结算")
        truthy(S.extIO.responsesFor(q2)[1].ok, "q2 ok=true")
        truthy(S.extIO.responsesFor(q2)[1].data.executed, "q2 移动已落地")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "帧 4 恢复 IDLE")
        eq(#S.extIO.incomingQueue, 2, "结算当帧不顺带取 q3")

        -- 帧 5 (0.20s)：空闲轮询取出 q3(get_turn_overview)，可观测到移动后的最新坐标 (5, 4)
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(q3), 1, "帧 5 完成 q3(get_turn_overview)")
        truthy(S.extIO.responsesFor(q3)[1].ok, "q3 ok=true")
        eq(S.extIO.responsesFor(q3)[1].data.our_units[1].x, 5, "q3 快照应反映移动后 x=5")
        eq(S.extIO.responsesFor(q3)[1].data.our_units[1].y, 4, "q3 快照应反映移动后 y=4")
        eq(#S.extIO.incomingQueue, 1, "队列剩余 1 条")

        -- 帧 6 (0.20s)：空闲轮询取出 q4(end_turn)，成功提交并切入 AI_TURN_LOCKED
        CAB_Dispatcher.OnFrameUpdate(0.20)
        eq(#S.extIO.responsesFor(q4), 1, "帧 6 完成 q4(end_turn)")
        truthy(S.extIO.responsesFor(q4)[1].ok, "q4 ok=true")
        truthy(S.extIO.responsesFor(q4)[1].data.turn_ended, "q4 turn_ended=true")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "帧 6 切入 AI_TURN_LOCKED")
        eq(#S.extIO.incomingQueue, 0, "入站队列全部消费完毕")

        -- 全局 1:1 响应数核验
        eq(#S.extIO.rpcResponses, 4, "4 条入站请求必须精确产生 4 条 RPC 响应（1:1 零丢失零重复）")
    end
end)

-- -----------------------------------------------------------------------------
-- 第 4.5 节：WP5（D-08）三大回合硬阻塞查询与设置 IPC 路由、异步帧结算与全自动闭环用例（T-25 ~ T-28）
-- -----------------------------------------------------------------------------

test("T-25", "WP5 只读查询路由：get_research_options / get_policy_options / get_unit_promotions 与入参守卫（A-11）", function()
    local w = S.newWorld({
        teams = { { id = 0, techs = { [0] = true } } },
        players = {
            {
                id = 0, team = 0, civ = "China", science = 10,
                culture = 40, nextPolicyCost = 25,
                canResearch = { [1] = true, [2] = true },
                unlockedBranches = { [0] = true },
                canAdoptPolicy = { [1] = true },
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
    })
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        promotionReady = true, availablePromotions = { [0] = true, [1] = true },
    })

    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")
    S.extIO.clearHistory()

    local rRes = sendRpc(2501, "get_research_options", {})
    truthy(rRes.ok, "get_research_options 应返回 ok=true")
    eq(#rRes.data.available_techs, 2, "应枚举 2 项可选科技")

    local rPol = sendRpc(2502, "get_policy_options", {})
    truthy(rPol.ok, "get_policy_options 应返回 ok=true")
    truthy(rPol.data.can_adopt_now, "应返回 can_adopt_now=true")
    eq(#rPol.data.adoptable_policies, 1, "应枚举 1 项可采纳政策")

    local rPro = sendRpc(2503, "get_unit_promotions", { unit_id = u:GetID() })
    truthy(rPro.ok, "get_unit_promotions 应返回 ok=true")
    truthy(rPro.data.is_promotion_ready, "应标记待晋升")
    eq(#rPro.data.available_promotions, 2, "应枚举 2 项可用晋升")

    -- 参数守卫与不存在单位错误映射
    falsy(sendRpc(2504, "get_unit_promotions", {}).ok, "缺 unit_id 应返 ok=false")
    falsy(sendRpc(2505, "get_unit_promotions", { unit_id = "bad" }).ok, "非整数 unit_id 应返 ok=false")
    local rMiss = sendRpc(2506, "get_unit_promotions", { unit_id = 999 })
    falsy(rMiss.ok, "不存在单位应映射 ok=false")
    contains(rMiss.error, "Unit not found", "应透传采集层错误")
end)

test("T-26", "WP5 三类新写动作入参校验、别名兼容与短延迟异步帧结算（SET_RESEARCH / ADOPT_POLICY / PROMOTE_UNIT）", function()
    local w = S.newWorld({
        cityActionDelayTicks = 2,
        teams = { { id = 0, techs = { [0] = true } } },
        players = {
            {
                id = 0, team = 0, civ = "China", science = 10,
                culture = 60, nextPolicyCost = 25,
                canResearch = { [1] = true, [2] = true },
                canAdoptPolicy = { [1] = true },
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
    })
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        promotionReady = true, availablePromotions = { [0] = true },
    })

    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")
    S.extIO.clearHistory()
    w:clearWriteLog()

    -- 参数守卫
    falsy(sendRpc(2601, "set_research_tech", {}).ok, "缺 tech 拦截")
    falsy(sendRpc(2602, "adopt_policy", { target_category = 123, target = "POLICY_ARISTOCRACY" }).ok, "非字符串 target_category 拦截")
    falsy(sendRpc(2603, "adopt_policy", { target_category = "BRANCH" }).ok, "缺 target 拦截")
    falsy(sendRpc(2604, "promote_unit", { unit_id = u:GetID() }).ok, "缺 promotion 拦截")
    eq(w:writeCount(), 0, "入参拦截零写入")

    -- 1. set_research_tech（含 tech_type 别名与 0.10s 短异步帧结算）
    local _, c1 = sendRpc(2610, "set_research_tech", { tech_type = "TECH_POTTERY" })
    eq(c1, 0, "挂起期不提前响应")
    eq(CAB_Dispatcher.GetRuntimeState().pending_kind, "SET_RESEARCH", "pending_kind=SET_RESEARCH")
    CAB_Dispatcher.OnFrameUpdate(0.06)
    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.06) -- 满 0.12s 但仍需 1 tick 才落地
    eq(#S.extIO.responsesFor(2610), 0, "引擎未落地前保持等待")
    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.05)
    local rTech = S.extIO.responsesFor(2610)[1]
    notNil(rTech, "落地后立即写回响应")
    truthy(rTech.ok and rTech.data.executed, "set_research_tech 应结算成功")
    eq(rTech.data.current_research_type, "TECH_POTTERY", "回读当前科研匹配")

    -- 2. adopt_policy（BRANCH + branch 别名）
    local _, c2 = sendRpc(2611, "adopt_policy", { target_category = "BRANCH", branch = "POLICY_BRANCH_TRADITION" })
    eq(c2, 0, "挂起期不提前响应")
    eq(CAB_Dispatcher.GetRuntimeState().pending_kind, "ADOPT_POLICY", "pending_kind=ADOPT_POLICY")
    w:tickSettlement(2)
    CAB_Dispatcher.OnFrameUpdate(0.11)
    local rBranch = S.extIO.responsesFor(2611)[1]
    notNil(rBranch, "分支开启应结算完成")
    truthy(rBranch.ok and rBranch.data.adopted, "BRANCH 开启应 adopted=true")

    -- 3. promote_unit（promotion_type 别名）
    local _, c3 = sendRpc(2612, "promote_unit", { unit_id = u:GetID(), promotion_type = "PROMOTION_SHOCK_1" })
    eq(c3, 0, "挂起期不提前响应")
    eq(CAB_Dispatcher.GetRuntimeState().pending_kind, "PROMOTE_UNIT", "pending_kind=PROMOTE_UNIT")
    w:tickSettlement(2)
    CAB_Dispatcher.OnFrameUpdate(0.11)
    local rPromo = S.extIO.responsesFor(2612)[1]
    notNil(rPromo, "晋升应结算完成")
    truthy(rPromo.ok and rPromo.data.promoted, "promote_unit 应 promoted=true")
    eq(rPromo.data.level_after, 2, "等级递增至 2")
end)

test("T-27", "WP5 三类新结算 1.50s 硬超时兜底与 D-04 信封保真", function()
    local casesSpec = {
        {
            method = "set_research_tech",
            params = { tech = "TECH_POTTERY" },
            flagKey = "executed",
        },
        {
            method = "adopt_policy",
            params = { target_category = "BRANCH", target = "POLICY_BRANCH_TRADITION" },
            flagKey = "adopted",
        },
        {
            method = "promote_unit",
            params = { unit_id = 0, promotion = "PROMOTION_SHOCK_1" },
            flagKey = "promoted",
        },
    }
    for idx, spec in ipairs(casesSpec) do
        local w = S.newWorld({
            cityActionDelayTicks = 99, -- 故意永不落地触发 1.50s 超时
            teams = { { id = 0, techs = { [0] = true } } },
            players = {
                { id = 0, team = 0, science = 10, culture = 50, nextPolicyCost = 25, canResearch = { [1] = true } },
            },
            cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
        })
        w:addUnit({
            id = 0, owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
            promotionReady = true, availablePromotions = { [0] = true },
        })
        S.reloadDispatcher()
        truthy(CAB_Dispatcher.Initialize(), "初始化成功")
        S.extIO.clearHistory()

        local reqId = 2700 + idx
        sendRpc(reqId, spec.method, spec.params)
        for _ = 1, 4 do
            CAB_Dispatcher.OnFrameUpdate(0.40) -- 累计 1.60s > 1.50s 硬超时
        end
        local resp = S.extIO.responsesFor(reqId)[1]
        notNil(resp, spec.method .. " 满 1.50s 应超时收口")
        truthy(resp.ok, "D-04：超时仍以 ok=true 保真透传结构化结算 DTO")
        falsy(resp.data[spec.flagKey], spec.method .. " 超时未落地标记应为 false")
        truthy(resp.data.timed_out, spec.method .. " 应标记 timed_out=true")
        notNil(resp.data.error_reason, spec.method .. " 应带 error_reason")
        eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "超时后应恢复 IDLE")
    end
end)

test("T-28", "WP5 端到端自动帧队列闭环：纯 RPC 解除三大硬阻塞并 end_turn 推进至下一回合（A-11）", function()
    local w = S.newWorld({
        turn = 0,
        cityActionDelayTicks = 1,
        teams = { { id = 0, techs = { [0] = true } } },
        players = {
            {
                id = 0, team = 0, civ = "China", science = 8,
                culture = 30, nextPolicyCost = 25,
                canResearch = { [1] = true },
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_RESEARCH,
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true, orderQueueLength = 1 } },
    })
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        moves = 0, readyToMove = false, promotionReady = true,
        availablePromotions = { [0] = true },
    })

    S.reloadDispatcher()
    truthy(CAB_Dispatcher.Initialize(), "初始化成功")
    S.extIO.clearHistory()

    -- 1. 解除科研阻塞
    local id1 = S.extIO.enqueueRequest("set_research_tech", { tech = "TECH_POTTERY" })
    CAB_Dispatcher.OnFrameUpdate(0.20) -- 轮询并挂起
    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.11) -- 完成结算
    truthy(S.extIO.responsesFor(id1)[1].data.executed, "步骤 1：科研阻塞已解除")

    -- 2. 切入政策阻塞并纯 RPC 解除
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_POLICY })
    local id2 = S.extIO.enqueueRequest("adopt_policy", { target_category = "BRANCH", target = "POLICY_BRANCH_TRADITION" })
    CAB_Dispatcher.OnFrameUpdate(0.20)
    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.11)
    truthy(S.extIO.responsesFor(id2)[1].data.adopted, "步骤 2：社会政策阻塞已解除")

    -- 3. 切入单位晋升阻塞并纯 RPC 解除
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_PROMOTION })
    local id3 = S.extIO.enqueueRequest("promote_unit", { unit_id = warrior:GetID(), promotion = "PROMOTION_SHOCK_1" })
    CAB_Dispatcher.OnFrameUpdate(0.20)
    w:tickSettlement(1)
    CAB_Dispatcher.OnFrameUpdate(0.11)
    truthy(S.extIO.responsesFor(id3)[1].data.promoted, "步骤 3：单位晋升阻塞已解除")

    -- 4. 全部硬阻塞已清空，提交 end_turn 并验证切入 AI_TURN_LOCKED 与 Turn 1 自动推送
    local id4 = S.extIO.enqueueRequest("end_turn", { auto_skip_ready_units = true })
    CAB_Dispatcher.OnFrameUpdate(0.20)
    local rEnd = S.extIO.responsesFor(id4)[1]
    truthy(rEnd.ok and rEnd.data.turn_ended, "步骤 4：end_turn 应成功提交")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "提交后切入 AI_TURN_LOCKED")

    w.turn = 1
    w:setPlayer(0, { turnActive = true })
    CAB_Dispatcher.OnActivePlayerTurnStart()
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "新回合恢复 IDLE")
    eq(CAB_Dispatcher.GetRuntimeState().turn_event_seq, 2, "turn_seq 递增至 2")
    eq(S.extIO.lastOverview().overview.turn_number, 1, "已自动推送 Turn 1 全局态势")
end)

-- -----------------------------------------------------------------------------
-- 第 5 节：运行器与收尾总检（FW-01）
-- -----------------------------------------------------------------------------

local PRINT_LINES_LIMIT = 30

local function matchesFilter(case, filterStr)
    if filterStr == nil or filterStr == "" then return true end
    local needle = tostring(filterStr):lower()
    if tostring(case.id):lower():find(needle, 1, true) ~= nil then return true end
    if tostring(case.title):lower():find(needle, 1, true) ~= nil then return true end
    return false
end

local function runOne(case)
    local handler = function(err)
        if type(err) == "table" and err.__skip then return err end
        return tostring(err) .. "\n" .. debug.traceback()
    end

    S.beginCase()
    local ok, result = xpcall(case.fn, handler)

    local status, message
    if ok then
        status, message = "pass", ""
    elseif type(result) == "table" and result.__skip then
        status, message = "skip", tostring(result.reason)
    else
        status, message = "fail", tostring(result)
    end

    local boundaryOk, boundaryMessage = S.endCase()
    if not boundaryOk then
        status = "fail"
        message = (message == "") and boundaryMessage or (message .. "\n" .. boundaryMessage)
    end

    if status == "fail" and #S.prints > 0 then
        local lines = {}
        for i = 1, math.min(#S.prints, PRINT_LINES_LIMIT) do lines[i] = S.prints[i] end
        message = message .. "\n—— 被测模块 print 输出 ——\n" .. table.concat(lines, "\n")
    end
    return status, message
end

local function runAll()
    local filterStr = __py_case_filter
    local summary = { passed = 0, failed = 0, skipped = 0, cases = {} }
    local counter = { pass = "passed", fail = "failed", skip = "skipped" }

    for _, case in ipairs(cases) do
        if matchesFilter(case, filterStr) then
            local status, message = runOne(case)
            summary[counter[status]] = summary[counter[status]] + 1
            summary.cases[#summary.cases + 1] = {
                id = case.id,
                status = status,
                title = case.title,
                message = message,
            }
        end
    end

    summary.guardViolations = #S.guard.violations
    summary.guardMissing = #S.guard.missing
    summary.totalWrites = S.guard.totalWrites
    summary.extOverviewCount = S.guard.extOverviewCount
    summary.extHeartbeatCount = S.guard.extHeartbeatCount
    summary.extRpcResponseCount = S.guard.extRpcResponseCount
    summary.extPollCount = S.guard.extPollCount

    if summary.guardViolations > 0 or summary.guardMissing > 0 then
        local parts = {}
        for _, record in ipairs(S.guard.violations) do
            parts[#parts + 1] = "红线违规：" .. record.owner .. "." .. record.method .. "()"
        end
        for _, record in ipairs(S.guard.missing) do
            parts[#parts + 1] = "桩未实现方法：" .. record.owner .. "." .. record.method .. "()"
        end
        summary.failed = summary.failed + 1
        summary.cases[#summary.cases + 1] = {
            id = "FW-01",
            status = "fail",
            title = "红线守卫或未实现方法累计不为零（框架收尾总检）",
            message = table.concat(parts, "\n"),
        }
    end
    return summary
end

return runAll()
