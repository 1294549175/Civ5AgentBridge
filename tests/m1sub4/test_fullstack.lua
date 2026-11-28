-- =============================================================================
-- 文件：tests/m1sub4/test_fullstack.lua
-- 职责：M1Sub4 WP3 五模块 + Civ5AgentBridgeUI.lua 最终壳层合龙离线全栈联调测试集。
-- 依赖：由 tests/run_m1sub4_tests.py 阶段 4 在加载 tests/m1sub4/fullstack_stubs.lua
--       后的独立 Lua 5.1 沙箱中执行，对接真实 Python sqlite3 SimpleValues 数据库。
-- 对外契约：返回汇总表 { passed, failed, skipped, guardViolations, guardMissing,
--           totalOpens, totalDbWrites, totalDbReads, cases = {...} }。
--
-- 用例索引（对齐《docs/M1/M1Sub4/M1Sub4工作计划.md》WP3 / A-06 / A-07）：
--   T-16  Civ5AgentBridgeUI.lua 与 Civ5AgentBridgeCore.lua 静态红线与零全局泄露审计
--   T-17  冷启动自底向上加载 6 模块、首帧自动推送、4 项宿主回调注册与热重载零重复加载
--   T-18  初始化失败降级保护：状态栏提示 Init Failed 且严禁挂载帧循环/事件监听
--   T-19  端到端只读查询与繁/简体中文 36KB+ 大载荷跨语言分片无损闭环
--   T-20  端到端两段式异步写动作跨帧结算闭环（execute_unit_action + purchase_city_plot）
--   T-21  端到端异常隔离、会话重启重置与手动同步按钮序号隔离（S-05）
--   T-22  端到端 end_turn -> AI 回合门控 -> ActivePlayerTurnStart 跨回合自动推送
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
        local parts = {}
        if v[1] ~= nil then
            for i = 1, #v do
                parts[i] = show(v[i])
            end
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

local function contains(str, needle, msg)
    if type(str) ~= "string" or str:find(needle, 1, true) == nil then
        fail(msg .. "：期望包含 " .. show(needle) .. "，实际 " .. show(str))
    end
end

-- 构建贴近实机的富状态测试世界（含简/繁中文名称与政策/单位/城市/可买地块）
local function buildRichWorld(opts)
    opts = opts or {}
    local w = S.resetFullStack({
        turn = opts.turn or 12,
        activePlayer = 0,
        teams = {
            { id = 0, techs = { [0] = true } },
            { id = 1, techs = { [0] = true } },
        },
        players = {
            {
                id = 0,
                team = 0,
                civ = "羅馬帝國",
                gold = 800,
                faith = 250,
                culture = 60,
                nextPolicyCost = 25,
                turnActive = (opts.turnActive ~= false),
                canResearch = { [1] = true, [2] = true },
                unlockedBranches = { [0] = true },
                canAdoptPolicy = { [1] = true, [2] = true, [3] = true },
            },
            {
                id = 1,
                team = 1,
                civ = "迦太基城邦",
                gold = 300,
                turnActive = false,
            },
        },
        wars = { { 0, 1 } },
        visibleAll = 0,
        plotBuyDelayTicks = opts.plotBuyDelayTicks or 1,
    })

    local capital = w:addCity({
        owner = 0,
        name = "長安與羅馬首都",
        x = 5,
        y = 5,
        isCapital = true,
        cityPlots = {
            { x = 5, y = 5 },
            { x = 5, y = 4 },
            { x = 6, y = 5 },
            { x = 6, y = 4 },
        },
        canBuyPlotAt = { [S.keyOf(6, 4)] = true },
        canBuyPlotNow = { [S.keyOf(6, 4)] = true },
        buyPlotCost = { [S.keyOf(6, 4)] = 50 },
    })
    -- 开放 (6, 4) 作为城市可购买地块
    w:setPlot(6, 4, { owner = -1, terrain = "TERRAIN_GRASS" })

    local warrior = w:addUnit({
        owner = 0,
        unitType = "UNIT_WARRIOR",
        nameKey = "第一軍團近衛戰士",
        x = 5,
        y = 5,
        canMoveThrough = true,
        canHandleActions = {
            MISSION_FORTIFY = true,
            MISSION_SKIP = true,
        },
        busyTicks = opts.unitBusyTicks or 0,
    })
    w:addUnit({
        owner = 1,
        unitType = "UNIT_ARCHER",
        nameKey = "敵軍遠程弓手",
        x = 8,
        y = 5,
    })

    return w, capital, warrior
end

-- -----------------------------------------------------------------------------
-- 第 2 节：WP3 五模块 + UI 壳层全栈联调用例（T-16 ~ T-22）
-- -----------------------------------------------------------------------------

test("T-16", "UI 壳层与退役 Core 静态红线审计（I-01 / D-02 / A-06）", function()
    local uiForbidden = {
        "OpenUserData",
        "SimpleValues",
        "CAB_JsonEncode",
        "CAB_JsonDecode",
        "CAB_Json.",
        "CAB_ExternalIO.",
        "CAB_Collector.",
        "CAB_Executor.",
        "CAB_DbWritePayload",
        "CAB_DbReadPayload",
        "CAB_BuildTurnOverview",
        "Civ5AgentBridgeCore",
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
        "UI.SelectUnit",
        "UI.SetInterfaceMode",
        "SetScriptData",
        "CanMoveOrAttackInto",
        "AirRaidCore",
    }
    local uiHits = S.scanForbiddenTokens("mod/Lua/Civ5AgentBridgeUI.lua", uiForbidden)
    eq(#uiHits, 0, "Civ5AgentBridgeUI.lua 不得命中红线 I-01 禁令符号，命中=" .. show(uiHits))

    -- 校验退役存根 Civ5AgentBridgeCore.lua 无任何可执行语句与遗留符号
    local coreSrc, readErr = __py_read_file("mod/Lua/Civ5AgentBridgeCore.lua")
    notNil(coreSrc, "应能读取 Civ5AgentBridgeCore.lua：" .. tostring(readErr))
    local codeLines = {}
    for line in (coreSrc .. "\n"):gmatch("(.-)\n") do
        if line:match("%S") ~= nil and not line:match("^%s*%-%-") then
            codeLines[#codeLines + 1] = line
        end
    end
    eq(#codeLines, 0, "Civ5AgentBridgeCore.lua 退役存根不得含非注释代码行")

    -- 校验加载 Civ5AgentBridgeCore.lua 零全局变量污染
    local beforeCount = 0
    for _ in pairs(_G) do beforeCount = beforeCount + 1 end
    include("Civ5AgentBridgeCore")
    local afterCount = 0
    for _ in pairs(_G) do afterCount = afterCount + 1 end
    eq(afterCount, beforeCount, "加载退役存根 Civ5AgentBridgeCore.lua 不得新增任何全局变量")
end)

test("T-17", "冷启动自底向上加载 6 模块、首帧自动推送与 4 项宿主回调注册（D-05 / A-06）", function()
    buildRichWorld({ turn = 15, turnActive = true })

    local hid = S.bootUI()
    notNil(hid, "冷启动应成功打开真实 SQLite3 数据库")

    -- 1. 核验精确自底向上加载顺序与有状态模块仅加载 1 次
    same(
        S.includeOrder,
        {
            "CAB_Config",
            "Civ5AgentBridgeJson",
            "CAB_ExternalIO",
            "CAB_InfoCollector",
            "CAB_TaskExecutor",
            "CAB_Dispatcher",
            "Civ5AgentBridgeUI",
        },
        "Civ5AgentBridgeUI.lua 必须严格按自底向上顺序冷加载全部 6 个正式模块"
    )
    eq(S.includeCount["Civ5AgentBridgeJson"], 1, "Civ5AgentBridgeJson 应精确加载 1 次")
    eq(S.includeCount["CAB_ExternalIO"], 1, "CAB_ExternalIO 有状态模块应精确加载 1 次")
    eq(S.includeCount["CAB_TaskExecutor"], 1, "CAB_TaskExecutor 有状态模块应精确加载 1 次")
    eq(S.includeCount["CAB_Dispatcher"], 1, "CAB_Dispatcher 有状态模块应精确加载 1 次")

    -- 2. 核验全部 4 项宿主回调准确注册为 CAB_Dispatcher 公开接口
    eq(#S.ui.syncButtonCallbacks, 1, "手动同步按钮回调应注册 1 次")
    eq(S.ui.syncButtonCallbacks[1], CAB_Dispatcher.OnManualSyncClicked, "按钮回调应指向 OnManualSyncClicked")
    eq(#S.ui.turnStartListeners, 1, "ActivePlayerTurnStart 回调应注册 1 次")
    eq(S.ui.turnStartListeners[1], CAB_Dispatcher.OnActivePlayerTurnStart, "TurnStart 回调应指向 OnActivePlayerTurnStart")
    eq(#S.ui.turnEndListeners, 1, "ActivePlayerTurnEnd 回调应注册 1 次")
    eq(S.ui.turnEndListeners[1], CAB_Dispatcher.OnActivePlayerTurnEnd, "TurnEnd 回调应指向 OnActivePlayerTurnEnd")
    eq(#S.ui.updateCallbacks, 1, "ContextPtr:SetUpdate 应注册 1 次")
    eq(S.ui.activeUpdateFn, CAB_Dispatcher.OnFrameUpdate, "帧循环回调应指向 OnFrameUpdate")

    -- 3. 核验首帧自动推送落盘至真实 SQLite（turn_overview_auto + seq=1 + TURN_SYNCED 心跳 + UI 标签）
    local seqNum, overview = S.pyDb.readTurnOverview(hid)
    eq(seqNum, 1, "初始化首帧 turn_overview_auto_seq 应为 1")
    notNil(overview, "初始化首帧应写入 turn_overview_auto")
    eq(overview.turn_number, 15, "态势快照回合号应为 15")
    eq(overview.our_cities[1].name, "長安與羅馬首都", "中文城市名应无损落盘")

    local hb = S.pyDb.readHeartbeat(hid)
    notNil(hb, "初始化首帧应写入 bridge_heartbeat")
    eq(hb.status, "TURN_SYNCED", "首帧心跳状态应为 TURN_SYNCED")
    eq(hb.turn_seq, 1, "首帧心跳 turn_seq 应为 1")
    truthy(hb.is_turn_active, "首帧心跳 is_turn_active 应为 true")
    eq(S.ui.currentLabel, "Agent: Turn 15 Synced", "右上角状态栏应更新为 Turn 15 Synced")

    -- 4. 六模块均已存在时再次执行 UI 脚本，守卫式加载对下游 6 模块增量为 0
    local snapExt = S.includeCount["CAB_ExternalIO"]
    local snapDisp = S.includeCount["CAB_Dispatcher"]
    local snapJson = S.includeCount["Civ5AgentBridgeJson"]
    local snapCfg = S.includeCount["CAB_Config"]
    S.bootUI()
    eq(S.includeCount["CAB_Config"], snapCfg, "守卫式加载不应重复 include CAB_Config")
    eq(S.includeCount["Civ5AgentBridgeJson"], snapJson, "守卫式加载不应重复 include Civ5AgentBridgeJson")
    eq(S.includeCount["CAB_ExternalIO"], snapExt, "守卫式加载不应重复 include CAB_ExternalIO")
    eq(S.includeCount["CAB_Dispatcher"], snapDisp, "守卫式加载不应重复 include CAB_Dispatcher")
end)

test("T-18", "初始化失败安全降级：提示 Init Failed 且严禁挂载帧循环与事件回调（D-05 / A-06）", function()
    -- 1. Modding.OpenUserData 返回 nil 导致初始化失败
    buildRichWorld({ turn = 5 })
    S.faults.openFail = true
    S.bootUI()
    S.faults.openFail = false

    eq(S.ui.currentLabel, "Agent Bridge: Init Failed", "DB 打开返回 nil 时状态栏应提示 Init Failed")
    eq(#S.ui.syncButtonCallbacks, 0, "初始化失败时严禁注册手动同步按钮回调")
    eq(#S.ui.turnStartListeners, 0, "初始化失败时严禁注册 TurnStart 事件")
    eq(#S.ui.turnEndListeners, 0, "初始化失败时严禁注册 TurnEnd 事件")
    eq(#S.ui.updateCallbacks, 0, "初始化失败时严禁调用 ContextPtr:SetUpdate")
    isNil(S.ui.activeUpdateFn, "初始化失败时不得挂载帧循环")

    -- 2. Modding.OpenUserData 抛出异常导致初始化失败
    buildRichWorld({ turn = 6 })
    S.faults.openThrow = "simulated sqlite open error"
    S.bootUI()
    S.faults.openThrow = nil

    eq(S.ui.currentLabel, "Agent Bridge: Init Failed", "DB 打开抛错时状态栏应提示 Init Failed")
    eq(#S.ui.updateCallbacks, 0, "DB 打开抛错时严禁挂载帧循环")
    isNil(S.ui.activeUpdateFn, "DB 打开抛错时 activeUpdateFn 必须为 nil")
end)

test("T-19", "端到端全栈只读查询与繁/简体中文 36KB+ 大载荷跨语言分片无损闭环（A-07 / I-02）", function()
    local w = buildRichWorld({ turn = 22 })
    -- 构造大量繁体/简体中文与 4 字节表情文本，使 get_policy_options 自然超出 3000B 触发真实分片
    local longCnNote = string.rep("羅馬帝國社會政策與文化遺產說明：傳統、自主、榮譽與美學😀⚔️|", 50)
    w.texts["TXT_KEY_POLICY_ARISTOCRACY_HELP"] = longCnNote
    w.texts["TXT_KEY_POLICY_OLIGARCHY_HELP"] = longCnNote
    w.texts["TXT_KEY_POLICY_LEGALISM_HELP"] = longCnNote

    local hid = S.bootUI()

    -- 1. ping
    S.pyDb.sendRpcMethod(hid, 1, "ping", { __is_object = true, echo = "你好世界😀" }, "sess-fs-1")
    S.ui.stepFrames(1, 0.20)
    local b1, r1 = S.pyDb.readRpcResponse(hid)
    eq(b1, 1, "ping 屏障推进至 1")
    truthy(r1.ok, "ping ok=true")
    eq(r1.data.pong, "你好世界😀", "ping 中文与表情回显无损")
    eq(r1.data.turn, 22, "ping 回合号正确")

    -- 2. get_policy_options（含大段繁简中文，走真实 CAB_Collector -> CAB_Dispatcher -> CAB_ExternalIO 分片）
    S.pyDb.sendRpcMethod(hid, 2, "get_policy_options", { __is_object = true }, "sess-fs-1")
    S.ui.stepFrames(1, 0.20)
    local b2, r2, _, chunks2 = S.pyDb.readRpcResponse(hid)
    eq(b2, 2, "get_policy_options 屏障推进至 2")
    truthy(r2.ok, "get_policy_options ok=true")
    truthy(r2.data.can_adopt_now, "应返回 can_adopt_now=true")
    truthy(chunks2 >= 2, "繁简中文 get_policy_options 载荷应真实触发多分片（实际 " .. tostring(chunks2) .. "）")
    for i = 1, chunks2 do
        local okStrict, strictVal = S.pyDb.readTextStrict(hid, "rpc_response#chunk_" .. tostring(i))
        truthy(okStrict, "get_policy_options 分片 #" .. tostring(i) .. " Python 严格 UTF-8 读库零错误：" .. tostring(strictVal))
    end

    -- 3. test_large_payload（36KB+ 强制分片 + 附带繁简中文输入）
    local bigInput = string.rep("繁體中文與簡體中文大載荷測試😀", 120)
    S.pyDb.sendRpcMethod(hid, 3, "test_large_payload", {
        __is_object = true,
        target_bytes = 36864,
        use_chunk = true,
        payload = bigInput,
    }, "sess-fs-1")
    S.ui.stepFrames(1, 0.20)
    local b3, r3, _, chunks3, rawLen3 = S.pyDb.readRpcResponse(hid)
    eq(b3, 3, "test_large_payload 屏障推进至 3")
    truthy(r3.ok, "test_large_payload ok=true")
    truthy(rawLen3 > 36864, "返回大载荷原始字节数应大于 36KB")
    truthy(chunks3 >= 12, "36KB+ 载荷应自动切分为 12+ 片（实际 " .. tostring(chunks3) .. "）")
    eq(r3.data.received_len, #bigInput, "Lua 侧完整接收并重组 Python 大载荷")
    eq(r3.data.generated_len, 36864, "Lua 侧生成长度精确匹配")
    for i = 1, chunks3 do
        local okStrict, strictVal = S.pyDb.readTextStrict(hid, "rpc_response#chunk_" .. tostring(i))
        truthy(okStrict, "36KB 大包分片 #" .. tostring(i) .. " 必须通过 Python 默认 UTF-8 文本读取：" .. tostring(strictVal))
    end
end)

test("T-20", "端到端两段式异步动作跨帧结算闭环：execute_unit_action + purchase_city_plot（A-07）", function()
    local w, capital, warrior = buildRichWorld({
        turn = 30,
        unitBusyTicks = 0,
        plotBuyDelayTicks = 1,
    })
    local hid = S.bootUI()

    -- 1. 单位移动异步结算：第 1 帧(0.20s) 下发进入 WAITING_SETTLEMENT；
    --    随后模拟引擎进入移动动画忙碌态（busyTicks=2），验证满 minWaitSec(0.35s) 仍等待动画结束
    S.pyDb.sendRpcMethod(hid, 10, "execute_unit_action", {
        __is_object = true,
        unit_id = warrior:GetID(),
        action_type = "MOVE_STEP",
        target_x = 5,
        target_y = 4,
    }, "sess-async")

    S.ui.stepFrames(1, 0.20)
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "下发移动后应进入 WAITING_SETTLEMENT")
    isNil(S.pyDb.readRpcBarrier(hid), "结算未完成前严禁提前写入 rpc_response_req_id")
    w:setUnit(warrior, { busyTicks = 2 })

    -- 推进 0.20s（未满 0.35s 且单位仍忙碌）
    S.ui.stepFrames(1, 0.20)
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "未满 minWaitSec 时保持挂起")
    isNil(S.pyDb.readRpcBarrier(hid), "挂起中屏障仍为空")

    -- 推进 0.20s（累计 0.40s >= 0.35s，但单位仍 busyTicks=2 保持等待）
    S.ui.stepFrames(1, 0.20)
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "单位仍忙碌时不得提前结算")

    -- 模拟引擎完成动画（busyTicks 归零）后再进 1 帧完成收口
    w:tickSettlement(2)
    S.ui.stepFrames(1, 0.20)
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "动画结束后应自动收口并恢复 IDLE")
    local b10, r10 = S.pyDb.readRpcResponse(hid)
    eq(b10, 10, "移动结算响应屏障应推进至 10")
    truthy(r10.ok, "移动结算响应 ok=true")
    truthy(r10.data.executed, "移动动作 executed=true")
    eq(r10.data.unit_after.x, 5, "结算后单位 x=5")
    eq(r10.data.unit_after.y, 4, "结算后单位 y=4")
    eq(S.ui.currentLabel, "Agent: Settled #10", "UI 状态栏应更新为 Settled #10")

    -- 2. 城市买地块异步结算（PLOT_BUY_SETTLE_SEC = 0.10s + plotBuyDelayTicks = 1）
    S.pyDb.sendRpcMethod(hid, 11, "purchase_city_plot", {
        __is_object = true,
        city_id = capital:GetID(),
        plot_x = 6,
        plot_y = 4,
    }, "sess-async")

    S.ui.stepFrames(1, 0.20)
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "WAITING_SETTLEMENT", "买地块下发后应进入 WAITING_SETTLEMENT")
    eq(S.pyDb.readRpcBarrier(hid), 10, "买地块未结算前屏障仍停留于 10")

    w:tickSettlement(1)
    S.ui.stepFrames(1, 0.15)
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "买地块满 0.10s 后收口恢复 IDLE")
    local b11, r11 = S.pyDb.readRpcResponse(hid)
    eq(b11, 11, "买地块响应屏障推进至 11")
    truthy(r11.ok, "买地块响应 ok=true")
    truthy(r11.data.purchased, "买地块 purchased=true")
    eq(r11.data.gold_after, 750, "买地块后金币准确扣除 50")
end)

test("T-21", "端到端异常隔离、会话重启重置与手动同步序号隔离（I-04 / I-05 / S-05）", function()
    buildRichWorld({ turn = 18 })
    local hid = S.bootUI()

    -- 1. 损坏 JSON 与非对象数组在全栈链路中被 CAB_ExternalIO 直接回错且不崩帧循环
    S.pyDb.sendRpcRequest(hid, 1, '{"method":"ping"', "sess-v1")
    S.ui.stepFrames(1, 0.20)
    local b1, r1 = S.pyDb.readRpcResponse(hid)
    eq(b1, 1, "损坏 JSON 屏障推进至 1")
    falsy(r1.ok, "损坏 JSON ok=false")
    contains(r1.error, "JSON decode error:", "损坏 JSON 返回协议错误")

    S.pyDb.sendRpcRequest(hid, 2, '[1, 2, 3]', "sess-v1")
    S.ui.stepFrames(1, 0.20)
    local b2, r2 = S.pyDb.readRpcResponse(hid)
    eq(b2, 2, "非对象 JSON 屏障推进至 2")
    falsy(r2.ok, "非对象 JSON ok=false")
    contains(r2.error, "Invalid RPC request: expected JSON object", "非对象 JSON 在 ExternalIO 层直接拦截")

    -- 2. 客户端重启切换新非空 rpc_session_id 后 req_id 从 1 重新握手成功
    S.pyDb.sendRpcMethod(hid, 1, "ping", { __is_object = true, echo = "after_restart" }, "sess-v2")
    S.ui.stepFrames(1, 0.20)
    local bRe, rRe = S.pyDb.readRpcResponse(hid)
    eq(bRe, 1, "切换新 session 后屏障应准确回落至新请求 req_id=1")
    truthy(rRe.ok, "重启后新会话 req_id=1 ok=true")
    eq(rRe.data.pong, "after_restart", "重启后响应内容准确")
    eq(CAB_ExternalIO.GetRuntimeState().active_session_id, "sess-v2", "ExternalIO 会话态同步更新")

    -- 3. 手动点击右上角同步按钮刷新 turn_overview_auto，但严格不递增 turn_overview_auto_seq（S-05）
    local seqBefore = S.pyDb.readTurnOverview(hid)
    eq(seqBefore, 1, "点击前 turn_overview_auto_seq 为 1")
    S.db.clearWriteLog()
    S.ui.clickSyncButton()
    notNil(S.db.firstWriteIndex("turn_overview_auto"), "手动同步按钮必须触发重新落盘 turn_overview_auto")
    local seqAfter, ovAfter = S.pyDb.readTurnOverview(hid)
    eq(seqAfter, 1, "红线 S-05：手动同步严禁递增 turn_overview_auto_seq")
    eq(ovAfter.turn_number, 18, "手动同步产出最新态势快照")
end)

test("T-22", "端到端 end_turn -> AI 回合门控 -> ActivePlayerTurnStart 跨回合自动推送（A-07）", function()
    local w, _, warrior = buildRichWorld({ turn = 40 })
    local hid = S.bootUI()

    -- 1. 通过真实 SQLite 下发 end_turn（自动跳过待命单位）
    S.pyDb.sendRpcMethod(hid, 1, "end_turn", {
        __is_object = true,
        auto_skip_ready_units = true,
    }, "sess-turn")
    S.ui.stepFrames(1, 0.20)

    local b1, r1 = S.pyDb.readRpcResponse(hid)
    eq(b1, 1, "end_turn 响应屏障推进至 1")
    truthy(r1.ok, "end_turn ok=true")
    truthy(r1.data.turn_ended, "end_turn turn_ended=true")
    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "AI_TURN_LOCKED", "end_turn 后状态机切入 AI_TURN_LOCKED")
    eq(S.ui.currentLabel, "Agent: AI Turn...", "UI 状态栏切为 AI Turn...")

    -- 模拟引擎切入 AI 回合
    w:setPlayer(0, { turnActive = false })
    S.ui.fireTurnEnd()
    local hbAi = S.pyDb.readHeartbeat(hid)
    eq(hbAi.status, "AI_TURN_PROCESSING", "TurnEnd 后心跳应为 AI_TURN_PROCESSING")
    falsy(hbAi.is_turn_active, "AI 回合心跳 is_turn_active 应为 false")

    -- 2. AI 回合门控验证：写动作被拒，白名单只读查询放行
    S.pyDb.sendRpcMethod(hid, 2, "execute_unit_action", {
        __is_object = true,
        unit_id = warrior:GetID(),
        action_type = "MOVE_STEP",
        target_x = 5,
        target_y = 4,
    }, "sess-turn")
    S.ui.stepFrames(1, 0.20)
    local b2, r2 = S.pyDb.readRpcResponse(hid)
    eq(b2, 2, "AI 回合写动作屏障推进至 2")
    falsy(r2.ok, "AI 回合写动作必须被门控拒绝")
    eq(r2.error, "Player turn is not active (AI turn in progress)", "门控错误文案匹配")

    S.pyDb.sendRpcMethod(hid, 3, "get_turn_overview", { __is_object = true }, "sess-turn")
    S.ui.stepFrames(1, 0.20)
    local b3, r3 = S.pyDb.readRpcResponse(hid)
    eq(b3, 3, "AI 回合白名单只读查询屏障推进至 3")
    truthy(r3.ok, "AI 回合 get_turn_overview 白名单应放行")
    eq(r3.data.turn_number, 40, "返回当前回合号 40")

    -- 3. 模拟引擎推进至 Turn 41 并触发 Events.ActivePlayerTurnStart
    w.turn = 41
    w:setPlayer(0, { turnActive = true })
    S.ui.fireTurnStart()

    eq(CAB_Dispatcher.GetRuntimeState().bridge_state, "IDLE", "新回合开始后状态机恢复 IDLE")
    local seqNext, ovNext = S.pyDb.readTurnOverview(hid)
    eq(seqNext, 2, "跨回合自动推送应将 turn_overview_auto_seq 递增至 2")
    eq(ovNext.turn_number, 41, "新回合自动推送快照应为 Turn 41")
    local hbNext = S.pyDb.readHeartbeat(hid)
    eq(hbNext.status, "TURN_SYNCED", "新回合心跳状态应为 TURN_SYNCED")
    eq(hbNext.turn_seq, 2, "新回合心跳 turn_seq 应为 2")
    truthy(hbNext.is_turn_active, "新回合心跳 is_turn_active 应为 true")
    eq(S.ui.currentLabel, "Agent: Turn 41 Synced", "UI 状态栏自动更新为 Turn 41 Synced")
end)

-- -----------------------------------------------------------------------------
-- 第 3 节：运行器与收尾总检（FW-02）
-- -----------------------------------------------------------------------------

local PRINT_LINES_LIMIT = 30

local function matchesFilter(case, filterStr)
    if filterStr == nil or filterStr == "" then
        return true
    end
    local needle = tostring(filterStr):lower()
    if tostring(case.id):lower():find(needle, 1, true) ~= nil then
        return true
    end
    if tostring(case.title):lower():find(needle, 1, true) ~= nil then
        return true
    end
    return false
end

local function runOne(case)
    local handler = function(err)
        if type(err) == "table" and err.__skip then
            return err
        end
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
        for i = 1, math.min(#S.prints, PRINT_LINES_LIMIT) do
            lines[i] = S.prints[i]
        end
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
    summary.totalOpens = S.guard.totalOpens
    summary.totalDbWrites = S.guard.totalDbWrites
    summary.totalDbReads = S.guard.totalDbReads

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
            id = "FW-02",
            status = "fail",
            title = "全栈红线守卫或未实现方法累计不为零（框架收尾总检）",
            message = table.concat(parts, "\n"),
        }
    end
    return summary
end

return runAll()
