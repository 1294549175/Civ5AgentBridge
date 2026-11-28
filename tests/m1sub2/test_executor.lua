-- =============================================================================
-- 文件：tests/m1sub2/test_executor.lua
-- 职责：M1Sub2（mod/Lua/CAB_TaskExecutor.lua）离线有状态引擎桩验收测试集。
-- 依赖：由 tests/run_m1sub2_tests.py 在加载 tests/m1sub2/engine_stubs.lua 后执行。
-- 对外契约：返回汇总表 { passed, failed, skipped, guardViolations, guardMissing,
--           totalWrites, cases = {...} }。
--
-- 结构划分（对齐《docs/M1/M1Sub2/M1Sub2工作计划.md》WP1 ~ WP4）：
--   第 1 节  用例注册与断言工具库；
--   第 2 节  WP1~WP4 静态红线、加载洁净与全部 9 项导出/Initialize 契约用例（T-00）；
--   第 3 节  WP1 真实跨模块联调与有状态引擎桩自检用例（T-01 ~ T-08）；
--   第 4 节  WP2 单位战术动作与城防炮击用例（T-09 ~ T-17）；
--   第 5 节  WP3 两段式异步结算与精准增量观测用例（T-18 ~ T-24）；
--   第 6 节  WP4 城市内政、安全下一回合、IGE 动态变阵与非法入参防御用例（T-25 ~ T-32）；
--   第 7 节  运行器与收尾总检（FW-01）。
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

local function ensureModulesLoaded()
    if CAB_Executor == nil then
        include("CAB_TaskExecutor")
    end
end

local TWO_PLAYERS = {
    { id = 0, team = 0, civ = "Rome", gold = 500, faith = 300 },
    { id = 1, team = 1, civ = "Carthage", gold = 200, faith = 100 },
}

-- -----------------------------------------------------------------------------
-- 第 2 节：WP1 静态红线、加载洁净与 Initialize 契约用例（T-00）
-- -----------------------------------------------------------------------------

test("T-00", "WP1 冒烟与静态红线：CAB_TaskExecutor.lua 加载洁净、依赖合法且 Initialize 准确", function()
    if not S.hasModule("CAB_TaskExecutor") then
        skip("mod/Lua/CAB_TaskExecutor.lua 尚未创建")
    end

    -- 1. 静态源码红线扫查（A-01 / A-04 / A-08）
    local src, readErr = __py_read_file("mod/Lua/CAB_TaskExecutor.lua")
    notNil(src, "应能读取 CAB_TaskExecutor.lua 源码：" .. tostring(readErr))

    -- 仅检查非注释代码行，避免注释中提及红线名称引起误报
    local codeLines = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do
        if not line:match("^%s*%-%-") then
            codeLines[#codeLines + 1] = line
        end
    end
    local codeOnly = table.concat(codeLines, "\n")

    local forbiddenTokens = {
        "CanMoveOrAttackInto",
        "AirRaidCore",
        "AR_ExecuteStrike",
        "AR_EnumerateTargets",
        "SetScriptData",
        "SetInterfaceMode",
        "Civ5AgentBridgeJson",
        "CAB_ExternalIO",
        "CAB_Dispatcher",
    }
    for _, token in ipairs(forbiddenTokens) do
        isNil(codeOnly:find(token, 1, true), "静态红线：非注释代码严禁出现 " .. token)
    end

    eq(countPattern(codeOnly, 'include%s*%(%s*"CAB_Config"%s*%)'), 1, "应恰好 include('CAB_Config') 一次")
    eq(countPattern(codeOnly, 'include%s*%(%s*"CAB_InfoCollector"%s*%)'), 1, "应恰好 include('CAB_InfoCollector') 一次")
    eq(countPattern(codeOnly, "include%s*%("), 2, "源码总 include 调用数应恰好为 2")

    -- 2. 动态加载洁净验证（A-01）
    local globalsBefore = globalSnapshot()
    local includesBefore = snapshotIncludes()

    local ok, err = pcall(include, "CAB_TaskExecutor")
    truthy(ok, "include('CAB_TaskExecutor') 应成功，实际报错：" .. tostring(err))

    isType(CAB_Executor, "table", "应导出全局表 CAB_Executor")
    local expectedExports = {
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
    local expectedSet = {}
    for _, fnName in ipairs(expectedExports) do
        expectedSet[fnName] = true
        isType(CAB_Executor[fnName], "function", "A-01：应导出公开函数 CAB_Executor." .. fnName)
    end
    local actualExportCount = 0
    for k, v in pairs(CAB_Executor) do
        actualExportCount = actualExportCount + 1
        truthy(expectedSet[k] == true, "A-01：CAB_Executor 不得包含未规划导出键 " .. tostring(k))
        isType(v, "function", "A-01：CAB_Executor." .. tostring(k) .. " 必须为函数")
    end
    eq(actualExportCount, 12, "A-01：CAB_Executor 导出函数总数必须精确为 12")

    -- CAB_TaskExecutor 直接 include CAB_Config + CAB_InfoCollector，后者内部再 include CAB_Config 一次
    same(
        includeDiff(includesBefore),
        { CAB_TaskExecutor = 1, CAB_InfoCollector = 1, CAB_Config = 2 },
        "加载依赖计数应精确匹配单向依赖拓扑"
    )

    local allowed = { CAB_Config = true, CAB_Collector = true, CAB_Executor = true }
    for _, name in ipairs(newGlobals(globalsBefore)) do
        truthy(allowed[name] ~= nil, "CAB_TaskExecutor 不得新增非法全局变量 " .. name)
    end

    -- 3. CAB_Executor.Initialize() 正常与缺依赖降级验证
    truthy(CAB_Executor.Initialize(), "依赖完整时 Initialize() 应返回 true")

    local savedFn = CAB_Collector.GetEndTurnStatus
    CAB_Collector.GetEndTurnStatus = nil
    falsy(CAB_Executor.Initialize(), "缺少必需 CAB_Collector 导出函数时 Initialize() 应返回 false")
    CAB_Collector.GetEndTurnStatus = savedFn

    local savedKey = CAB_Config.DEFAULT_UNIT_SETTLE_SEC
    CAB_Config.DEFAULT_UNIT_SETTLE_SEC = nil
    falsy(CAB_Executor.Initialize(), "缺少必需 CAB_Config 键时 Initialize() 应返回 false")
    CAB_Config.DEFAULT_UNIT_SETTLE_SEC = savedKey

    truthy(CAB_Executor.Initialize(), "恢复依赖后 Initialize() 应再次返回 true")
end)

-- -----------------------------------------------------------------------------
-- 第 3 节：WP1 真实跨模块联调与有状态引擎桩自检用例（T-01 ~ T-08）
-- -----------------------------------------------------------------------------

test("T-01", "跨模块联调：在有状态引擎桩上真实运行 CAB_InfoCollector 核心查询接口", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        players = TWO_PLAYERS,
        wars = { { 0, 1 } },
        visibleAll = 0,
    })
    local warrior = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local enemy = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 7, y = 5 })
    local city = w:addCity({ owner = 0, name = "Rome", x = 4, y = 5, isCapital = true })

    local overview = CAB_Collector.BuildTurnOverview(0)
    eq(overview.active_player_id, 0, "BuildTurnOverview 应识别活跃玩家 0")
    eq(#overview.our_units, 1, "应返回 1 个己方单位")
    eq(overview.our_units[1].unit_id, warrior:GetID(), "己方单位 ID 匹配")
    eq(#overview.visible_enemies, 1, "应返回 1 个可见敌军")
    eq(overview.visible_enemies[1].enemy_id, "1:" .. tostring(enemy:GetID()), "敌军复合 ID 匹配")
    eq(#overview.our_cities, 1, "应返回 1 座己方城市")

    local vis = CAB_Collector.GetVisibilitySummary(0)
    eq(#vis.visible_enemies, 1, "GetVisibilitySummary 可见敌军数")

    local revSet = CAB_Collector.CaptureRevealedPlotsSet(0, 5, 5, 1)
    truthy(revSet["5:5"], "CaptureRevealedPlotsSet 应包含中心格")

    local etStatus = CAB_Collector.GetEndTurnStatus(0)
    truthy(etStatus.can_end_turn_now, "无阻塞时 GetEndTurnStatus.can_end_turn_now 应为 true")

    local detail = CAB_Collector.GetCityDetail(0, city:GetID(), true)
    eq(detail.city.city_id, city:GetID(), "GetCityDetail 城市 ID 匹配")
end)

test("T-02", "有状态桩自检：SelectionListMove 单位移动、扣移动力、自动揭盲与写日志", function()
    local w = S.newWorld({ players = TWO_PLAYERS })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5, visionRange = 1 })
    falsy(w:getPlot(7, 5):IsRevealed(0), "移动前 (7,5) 应处于黑雾")

    UI.SelectUnit(u)
    Game.SelectionListMove(w:getPlot(6, 5), false, false, false)

    eq(u:GetX(), 6, "移动后 x 应为 6")
    eq(u:GetY(), 5, "移动后 y 应为 5")
    eq(u:MovesLeft(), 60, "移动 1 格应消耗 60 点移动力")
    truthy(w:getPlot(7, 5):IsRevealed(0), "移动后新视野前沿 (7,5) 应被揭盲")
    eq(w:writeCount("SelectionListMove"), 1, "写日志应记录 1 次 SelectionListMove")
end)

test("T-03", "有状态桩自检：近战/远程/空袭/城防战斗演进与动画帧推进 tickSettlement", function()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } }, visibleAll = 0 })
    local attacker = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        combatOutcome = { damageToTarget = 100, counterDamage = 25, targetDies = true, busyTicks = 2, fightingTicks = 2 },
    })
    local enemy = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 6, y = 5 })

    UI.SelectUnit(attacker)
    Game.SelectionListMove(w:getPlot(6, 5), false, false, false)

    truthy(enemy:IsDead(), "目标敌军应被击杀")
    eq(attacker:GetX(), 6, "近战击杀后攻击方应进占目标格")
    eq(attacker:GetDamage(), 25, "攻击方应承受反击损血")
    truthy(attacker:IsBusy(), "战斗刚下发时 IsBusy() 应为 true")
    truthy(w:getPlot(6, 5):IsFighting(), "目标格 IsFighting() 应为 true")

    w:tickSettlement(1)
    truthy(attacker:IsBusy(), "推进 1 帧后仍应处于忙碌")
    w:tickSettlement(1)
    falsy(attacker:IsBusy(), "推进 2 帧后 IsBusy() 应恢复 false")
    falsy(w:getPlot(6, 5):IsFighting(), "推进 2 帧后目标格 IsFighting() 应恢复 false")

    -- 城防远程炮击验证
    local city = w:addCity({
        owner = 0, name = "Rome", x = 3, y = 5,
        canRangeStrikeNow = true,
        rangedOutcome = { damageToTarget = 40, fightingTicks = 1 },
    })
    local enemy2 = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 4, y = 5 })
    UI.SelectCity(city)
    Game.SelectedCitiesGameNetMessage(GameMessageTypes.GAMEMESSAGE_DO_TASK, TaskTypes.TASK_RANGED_ATTACK, 4, 5)
    UI.ClearSelectedCities()

    falsy(city:CanRangeStrikeNow(), "城防炮击后 CanRangeStrikeNow 应变为 false")
    eq(enemy2:GetDamage(), 40, "敌军应受到 40 点城防伤害")
    truthy(w:getPlot(4, 5):IsFighting(), "炮击目标格应处于战斗动画中")
    w:tickSettlement(1)
    falsy(w:getPlot(4, 5):IsFighting(), "推进 1 帧后炮击战斗动画结束")
end)

test("T-04", "有状态桩自检：外交宣战与和约拦截（CanDeclareWar / DeclareWar）", function()
    local w = S.newWorld({ players = TWO_PLAYERS })
    falsy(Teams[0]:IsAtWar(1), "初始两队应为和平中立")
    truthy(Teams[0]:CanDeclareWar(1), "无和约时应允许宣战")

    w:setPeaceTreaty(0, 1, true)
    falsy(Teams[0]:CanDeclareWar(1), "和约期内 CanDeclareWar 必须返回 false")

    w:setPeaceTreaty(0, 1, false)
    truthy(Teams[0]:CanDeclareWar(1), "解除和约后应恢复可宣战")
    Teams[0]:DeclareWar(1)
    truthy(Teams[0]:IsAtWar(1), "DeclareWar 后队伍 0 对 1 应交战")
    truthy(Teams[1]:IsAtWar(0), "DeclareWar 应对称生效于队伍 1 对 0")
    eq(w:writeCount("DeclareWar"), 1, "写日志应记录 1 次 DeclareWar")
end)

test("T-05", "有状态桩自检：城市买建筑、买单位生新 ID、设生产队列与 SpecificCityInfoDirty", function()
    local w = S.newWorld({ players = TWO_PLAYERS })
    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        costs = {
            bldGold = { [GameInfoTypes.BUILDING_GRANARY] = 200 },
            unitGold = { [GameInfoTypes.UNIT_ARCHER] = 150 },
        },
    })

    -- 买建筑
    Game.CityPurchaseBuilding(city, GameInfoTypes.BUILDING_GRANARY, YieldTypes.YIELD_GOLD)
    Events.SpecificCityInfoDirty(0, city:GetID(), CityUpdateTypes.CITY_UPDATE_TYPE_PURCHASE)
    eq(Players[0]:GetGold(), 300, "买粮仓后金币应从 500 扣至 300")
    eq(city:GetNumRealBuilding(GameInfoTypes.BUILDING_GRANARY), 1, "城市应新增 1 座粮仓")

    -- 买单位
    Game.CityPurchaseUnit(city, GameInfoTypes.UNIT_ARCHER, YieldTypes.YIELD_GOLD)
    eq(Players[0]:GetGold(), 150, "买弓箭手后金币应扣至 150")
    local spawnedCount = 0
    for u in Players[0]:Units() do
        spawnedCount = spawnedCount + 1
        eq(u:GetX(), 5, "新购单位应生成在城市格 x=5")
        eq(u:GetY(), 5, "新购单位应生成在城市格 y=5")
    end
    eq(spawnedCount, 1, "应恰好生成 1 个新单位")

    -- 设生产队列
    Game.CityPushOrder(city, OrderTypes.ORDER_CONSTRUCT, GameInfoTypes.BUILDING_WALLS, false, true, true)
    eq(city:GetOrderQueueLength(), 1, "清空队列并推入城墙后队列长度应为 1")
    eq(city:GetProductionNameKey(), "TXT_KEY_BUILDING_WALLS", "当前生产品项应为城墙")
    eq(w:logCount("Events.SpecificCityInfoDirty"), 1, "应记录 SpecificCityInfoDirty 事件")
end)

test("T-06", "有状态桩自检：Network.SendCityBuyPlot 异步延迟翻转归属与扣费", function()
    local w = S.newWorld({ players = TWO_PLAYERS, plotBuyDelayTicks = 2 })
    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        buyPlotCost = { ["6:5"] = 80 },
    })

    Network.SendCityBuyPlot(city:GetID(), 6, 5)
    eq(w:getPlot(6, 5):GetOwner(), -1, "刚发送买地包时地块归属尚未翻转")
    eq(Players[0]:GetGold(), 500, "异步延迟期间金币尚未扣除")

    w:tickSettlement(1)
    eq(w:getPlot(6, 5):GetOwner(), -1, "推进 1 帧后仍未到 2 帧延迟")

    w:tickSettlement(1)
    eq(w:getPlot(6, 5):GetOwner(), 0, "推进 2 帧后地块归属应翻转为玩家 0")
    eq(Players[0]:GetGold(), 420, "归属翻转时应扣除 80 金币")
    eq(w:writeCount("SendCityBuyPlot"), 1, "写日志应记录 1 次 SendCityBuyPlot")
end)

test("T-07", "有状态桩自检：单位跳过待命（MISSION_SKIP）与结束回合（CONTROL_ENDTURN）", function()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome", blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS },
        },
    })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    truthy(u:IsReadyToMove(), "初始单位应处于待命状态")

    UI.SelectUnit(u)
    Game.HandleAction(GameInfoTypes.MISSION_SKIP)
    falsy(u:IsReadyToMove(), "执行 MISSION_SKIP 后单位不再待命")
    eq(Players[0]:GetEndTurnBlockingType(), EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE, "全部待命单位跳过后阻塞应清除")

    Game.DoControl(GameInfoTypes.CONTROL_ENDTURN)
    truthy(w.endTurnRequested, "CONTROL_ENDTURN 应标记 endTurnRequested = true")
    eq(w:writeCount("DoControl"), 1, "写日志应记录 1 次 DoControl")
end)

test("T-08", "有状态桩自检：红线陷阱（CanMoveOrAttackInto/SetInterfaceMode/SetScriptData）与迷雾侧信道审计", function()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } }, revealAll = 0 })
    w:show(0, 11, 5)
    w:addCity({ owner = 1, name = "Carthage", x = 14, y = 5 })
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 10, y = 5,
        canRangeStrikeAt = { ["11:5"] = true, ["12:5"] = true, ["14:5"] = true },
    })

    -- 1. 红线陷阱核验
    local caught1 = S.expectViolation(function() u:CanMoveOrAttackInto(w:getPlot(11, 5), false) end)
    truthy(caught1, "Unit:CanMoveOrAttackInto 必须触发红线陷阱")

    local caught2 = S.expectViolation(function() UI.SetInterfaceMode(InterfaceModeTypes.INTERFACEMODE_RANGE_ATTACK) end)
    truthy(caught2, "UI.SetInterfaceMode 必须触发 E-06 红线陷阱")

    local caught3 = S.expectViolation(function() u:SetScriptData("dirty") end)
    truthy(caught3, "SetScriptData 必须触发红线陷阱")

    -- 2. 迷雾防侧信道审计（E-03）
    u:CanRangeStrikeAt(11, 5, true, false) -- 实时可见格：允许
    u:CanRangeStrikeAt(12, 5, true, false) -- 普通迷雾格：违禁
    u:CanRangeStrikeAt(14, 5, true, false) -- 已探索交战敌城格：允许
    local forbidden = w:queriesOnForbiddenFog("CanRangeStrikeAt")
    eq(#forbidden, 1, "仅普通迷雾格 (12,5) 应被判为违禁迷雾探测")
    eq(forbidden[1].x, 12, "违禁探测坐标 x=12")
end)

-- -----------------------------------------------------------------------------
-- 第 4 节：WP2 单位战术动作（StartUnitAction）与城防炮击（StartCityRangeAttack）用例（T-09 ~ T-17）
-- -----------------------------------------------------------------------------

test("T-09", "WP2 E-01 门控与非法入参：非活动回合、消息队列忙与越界参数零写入零选区改动", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome", turnActive = false },
            { id = 1, team = 1, civ = "Carthage", turnActive = true },
        },
        wars = { { 0, 1 } },
        visibleAll = 0,
    })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5, canMoveThrough = true })
    local c = w:addCity({ owner = 0, name = "Rome", x = 3, y = 5, canRangeStrikeNow = true, canRangeStrikeAt = true })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 4, y = 5 })
    w:select(u)

    -- 1. 非活动回合：单位与城防炮击均拦截，零写入
    local ok1, err1, ctx1 = CAB_Executor.StartUnitAction(0, u:GetID(), "MOVE_STEP", 6, 5)
    falsy(ok1, "非活动回合 StartUnitAction 必须拒绝")
    notNil(err1, "应返回错误信息")
    isNil(ctx1, "失败时 baselineContext 应为 nil")

    local ok2, err2, ctx2 = CAB_Executor.StartCityRangeAttack(0, c:GetID(), 4, 5)
    falsy(ok2, "非活动回合 StartCityRangeAttack 必须拒绝")
    notNil(err2, "应返回错误信息")
    isNil(ctx2, "失败时 baselineContext 应为 nil")

    -- 2. 消息队列忙：同样拦截
    w:setPlayer(0, { turnActive = true })
    w.processingMessages = true
    local ok3, err3 = CAB_Executor.StartUnitAction(0, u:GetID(), "MOVE_STEP", 6, 5)
    falsy(ok3, "消息队列忙时 StartUnitAction 必须拒绝")
    notNil(err3, "应返回错误信息")
    local ok4 = CAB_Executor.StartCityRangeAttack(0, c:GetID(), 4, 5)
    falsy(ok4, "消息队列忙时 StartCityRangeAttack 必须拒绝")
    w.processingMessages = false

    -- 3. 非法入参（坏玩家/死单位/坏枚举/越界坐标/敌方单位与城市越权）
    falsy(CAB_Executor.StartUnitAction(-1, u:GetID(), "MOVE_STEP", 6, 5), "负玩家 ID 拒绝")
    falsy(CAB_Executor.StartUnitAction("bad", u:GetID(), "MOVE_STEP", 6, 5), "非整数玩家 ID 拒绝")
    falsy(CAB_Executor.StartUnitAction(0, 9999, "MOVE_STEP", 6, 5), "不存在单位拒绝")
    falsy(CAB_Executor.StartUnitAction(0, u:GetID(), "TELEPORT", 6, 5), "非法动作枚举拒绝")
    falsy(CAB_Executor.StartUnitAction(0, u:GetID(), "MOVE_STEP", 999, 5), "越界坐标拒绝")
    falsy(CAB_Executor.StartUnitAction(0, u:GetID(), "MOVE_STEP", 6.5, 5), "小数坐标拒绝")
    falsy(CAB_Executor.StartCityRangeAttack(0, 9999, 4, 5), "不存在城市拒绝")

    -- 零写副作用且原 UI 选区纹丝不动
    eq(w:writeCount(), 0, "E-01/E-02：所有前置拦截均必须保持写调用 = 0")
    eq(UI.GetHeadSelectedUnit(), u, "E-02：前置校验失败不得改变原 UI 选区")
end)

test("T-10", "WP2 MOVE_STEP：CanMoveThrough + 1UPT、军民叠栈放行、空军禁移与 E-05 相邻黑雾探路", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS })
    w:show(0, 5, 5)
    w:show(0, 6, 5)
    w:show(0, 4, 5)
    w:show(0, 5, 6)
    -- (5,4) 保持未探索黑雾，且在黑雾内故意放不可通行山脉以验证 E-05 不窥探黑雾地形
    w:setPlot(5, 4, { terrain = "TERRAIN_MOUNTAIN", mountain = true, impassable = true })

    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5, visionRange = 1,
        canMoveThrough = { ["6:5"] = true, ["4:5"] = false, ["5:6"] = true },
    })
    -- (5,6) 放己方同战斗单位（1UPT 拦截），(6,5) 放己方民用工人（军民叠栈允许）
    w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 6 })
    w:addUnit({ owner = 0, unitType = "UNIT_WORKER", x = 6, y = 5 })
    local fighter = w:addUnit({ owner = 0, unitType = "UNIT_FIGHTER", x = 5, y = 5 })

    -- 1. 空军禁止 MOVE_STEP
    falsy(CAB_Executor.StartUnitAction(0, fighter:GetID(), "MOVE_STEP", 6, 5), "空军严禁 MOVE_STEP")
    -- 2. 超距禁止 MOVE_STEP
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "MOVE_STEP", 7, 5), "dist > 1 严禁 MOVE_STEP")
    -- 3. CanMoveThrough == false 拦截（零触发 CanMoveOrAttackInto）
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "MOVE_STEP", 4, 5), "CanMoveThrough=false 应拦截")
    -- 4. 1UPT 同类战斗单位叠栈拦截
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "MOVE_STEP", 5, 6), "同战斗单位 1UPT 应拦截")
    eq(w:writeCount(), 0, "上述 4 次拦截必须零写入")

    -- 5. E-05：相邻未探索黑雾格 (5,4) 应允许探路移动（且不调用 CanMoveThrough 窥探黑雾）
    w:clearLog()
    local okFog, errFog, ctxFog = CAB_Executor.StartUnitAction(0, warrior:GetID(), "MOVE_STEP", 5, 4)
    truthy(okFog, "E-05：相邻黑雾探路应成功，实际报错：" .. tostring(errFog))
    eq(ctxFog.settlementKind, "UNIT_ACTION", "settlementKind 应为 UNIT_ACTION")
    eq(ctxFog.actionType, "MOVE_STEP", "actionType 应为 MOVE_STEP")
    eq(w:logCount("CanMoveThrough"), 0, "E-05：黑雾探路不得调用 CanMoveThrough 窥探地形")
    eq(warrior:GetX(), 5, "黑雾探路移动后 x=5")
    eq(warrior:GetY(), 4, "黑雾探路移动后 y=4")

    -- 6. 军民叠栈放行（把 warrior 移回 (5,5) 后踏入有己方工人的 (6,5)）
    w:setUnit(warrior, { x = 5, y = 5, moves = 120, readyToMove = true })
    local okStack, errStack, ctxStack = CAB_Executor.StartUnitAction(0, warrior:GetID(), "MOVE_STEP", 6, 5)
    truthy(okStack, "军民叠栈移动应放行，实际报错：" .. tostring(errStack))
    eq(ctxStack.beforeX, 5, "记录移动前 x")
    eq(ctxStack.targetX, 6, "记录目标 x")
    eq(warrior:GetX(), 6, "移动后应到达 (6,5)")
end)

test("T-11", "WP2 MELEE_ATTACK：近战击杀、陆海兵种域限制、非近战拦截与攻城 targetCityBefore 基线", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } }, visibleAll = 0 })
    w:setPlot(6, 5, { terrain = "TERRAIN_COAST" })
    w:setPlot(6, 6, { terrain = "TERRAIN_COAST" })

    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        combatOutcome = { damageToTarget = 100, counterDamage = 10, targetDies = true },
    })
    local archer = w:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 5, y = 5 })
    local worker = w:addUnit({ owner = 0, unitType = "UNIT_WORKER", x = 5, y = 5 })
    local trireme = w:addUnit({ owner = 0, unitType = "UNIT_TRIREME", x = 6, y = 6 })

    local seaEnemy = w:addUnit({ owner = 1, unitType = "UNIT_TRIREME", x = 6, y = 5 })
    local landEnemy = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 4, y = 5 })
    local enemyCity = w:addCity({ owner = 1, name = "Carthage", x = 5, y = 6, damage = 50 })

    -- 1. 陆军禁攻水域敌军；远程/民用禁近战；海军禁攻纯陆地非城格
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "MELEE_ATTACK", 6, 5), "陆军严禁近战攻击水域敌舰")
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "MELEE_ATTACK", 4, 5), "远程单位严禁 MELEE_ATTACK")
    falsy(CAB_Executor.StartUnitAction(0, worker:GetID(), "MELEE_ATTACK", 4, 5), "民用单位严禁 MELEE_ATTACK")
    eq(w:writeCount(), 0, "非法近战拦截应零写入")

    -- 2. 正常陆军近战击杀
    local okM, errM, ctxM = CAB_Executor.StartUnitAction(0, warrior:GetID(), "MELEE_ATTACK", 4, 5)
    truthy(okM, "陆军近战攻击相邻交战敌军应成功：" .. tostring(errM))
    notNil(ctxM.targetEnemyBefore, "应采集受击敌军战前快照")
    eq(ctxM.targetEnemyBefore.enemy_id, "1:" .. tostring(landEnemy:GetID()), "受击敌军复合 ID 匹配")
    truthy(landEnemy:IsDead(), "目标敌军应已被击杀")

    -- 3. 海军近战攻打沿海敌城，应放行并记录 targetCityBefore
    local okC, errC, ctxC = CAB_Executor.StartUnitAction(0, trireme:GetID(), "MELEE_ATTACK", 5, 6)
    truthy(okC, "海军近战攻打沿海交战敌城应成功：" .. tostring(errC))
    notNil(ctxC.targetCityBefore, "攻城应记录 targetCityBefore 快照")
    eq(ctxC.targetCityBefore.city_id, "1:" .. tostring(enemyCity:GetID()), "目标城市复合 ID 匹配")
    eq(ctxC.targetCityBefore.hp, 150, "目标城市战前血量 200-50=150")
    falsy(seaEnemy:IsDead(), "未攻击的海军敌舰应存活")
end)

test("T-12", "WP2 RANGE_ATTACK 与 E-03 迷雾防侧信道：普通迷雾、黑雾与隐形敌军零 CanRangeStrikeAt 调用", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } } })
    -- (5,5) 弓箭手；(7,5) 实时可见交战敌军；(6,5) 普通迷雾有隐匿敌军；(5,7) 未探索黑雾有敌军；
    -- (3,5) 实时可见但敌军隐形；(5,3) 已探索迷雾中的交战敌城（E-03 允许轰炸）
    w:show(0, 5, 5)
    w:show(0, 7, 5)
    w:show(0, 3, 5)
    w:reveal(0, 6, 5)
    w:reveal(0, 5, 3)

    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 5, y = 5,
        canRangeStrikeAt = { ["7:5"] = true, ["6:5"] = true, ["5:7"] = true, ["3:5"] = true, ["5:3"] = true },
    })
    local visEnemy = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 7, y = 5 })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 6, y = 5 }) -- 普通迷雾内
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 5, y = 7 }) -- 黑雾内
    w:addUnit({ owner = 1, unitType = "UNIT_TRIREME", x = 3, y = 5, invisibleTo = { [0] = true } }) -- 隐形
    local fogCity = w:addCity({ owner = 1, name = "Carthage", x = 5, y = 3 })

    -- 1. 普通迷雾 / 黑雾 / 隐形敌军必须全部拦截，且零 CanRangeStrikeAt 调用、零写入
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 6, 5), "普通迷雾格必须拦截")
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 5, 7), "黑雾格必须拦截")
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 3, 5), "仅含隐形敌军格必须拦截")
    eq(w:logCount("CanRangeStrikeAt"), 0, "E-03：迷雾/黑雾/隐形拦截不得调用 CanRangeStrikeAt")
    eq(w:writeCount(), 0, "拦截期间零写入")

    -- 2. 实时可见交战敌军正常射击
    local ok1, err1, ctx1 = CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 7, 5)
    truthy(ok1, "射程内可见交战敌军应射击成功：" .. tostring(err1))
    eq(ctx1.targetEnemyBefore.enemy_id, "1:" .. tostring(visEnemy:GetID()), "记录受击敌军")
    eq(visEnemy:GetDamage(), 30, "敌军应受到远程伤害")

    -- 3. 已探索迷雾中的交战敌城允许远程轰炸，且 queriesOnForbiddenFog == 0
    w:setUnit(archer, { moves = 120, readyToMove = true })
    local ok2, err2, ctx2 = CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 5, 3)
    truthy(ok2, "已探索交战敌城应允许远程轰炸：" .. tostring(err2))
    eq(ctx2.targetCityBefore.city_id, "1:" .. tostring(fogCity:GetID()), "记录受击敌城")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "E-03：queriesOnForbiddenFog 必须为 0")
end)

test("T-13", "WP2 AIR_STRIKE：纯原生 BNW MISSION_MOVE_TO 空袭与 E-03 迷雾红线（零 AirRaidCore）", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } } })
    w:show(0, 2, 5)
    w:show(0, 9, 5) -- 距离 7，在战机射程 8 内
    w:reveal(0, 8, 5) -- 普通迷雾

    local fighter = w:addUnit({
        owner = 0, unitType = "UNIT_FIGHTER", x = 2, y = 5,
        canRangeStrikeAt = { ["9:5"] = true, ["8:5"] = true },
    })
    local archer = w:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 2, y = 5 })
    local enemy = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 9, y = 5 })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 8, y = 5 }) -- 普通迷雾

    -- 陆军禁空袭；空军禁 RANGE_ATTACK；普通迷雾禁空袭
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "AIR_STRIKE", 9, 5), "陆军严禁 AIR_STRIKE")
    falsy(CAB_Executor.StartUnitAction(0, fighter:GetID(), "RANGE_ATTACK", 9, 5), "空军严禁 RANGE_ATTACK")
    falsy(CAB_Executor.StartUnitAction(0, fighter:GetID(), "AIR_STRIKE", 8, 5), "空军严禁探测普通迷雾格")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "E-03：空袭 queriesOnForbiddenFog 必须为 0")
    eq(w:writeCount(), 0, "拦截期间零写入")

    -- 正常原生空袭：通过 MISSION_MOVE_TO 下发
    local ok, err, ctx = CAB_Executor.StartUnitAction(0, fighter:GetID(), "AIR_STRIKE", 9, 5)
    truthy(ok, "纯原生空军空袭应成功：" .. tostring(err))
    eq(ctx.actionType, "AIR_STRIKE", "actionType 应为 AIR_STRIKE")
    eq(w.writeLog[1].kind, "SelectionListGameNetMessage", "应通过 SelectionListGameNetMessage 下发")
    eq(w.writeLog[1].mission, MissionTypes.MISSION_MOVE_TO, "原版空袭必须使用 MissionTypes.MISSION_MOVE_TO")
    eq(enemy:GetDamage(), 30, "空袭目标应受到伤害")
end)

test("T-14", "WP2 E-04/D-03 防误宣战与可控显式宣战：默认拦截、和约拦截、校验失败零宣战与显式 DeclareWar", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, visibleAll = 0 }) -- 默认和平中立
    local warrior = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 5, y = 5,
        canRangeStrikeAt = function(_, x, y) return x == 7 and y == 5 end,
    })
    local neutralMelee = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 6, y = 5 })
    local neutralRange = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 7, y = 5 })
    local blockedNeutral = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 7, y = 6 })

    -- 1. 默认 allowDeclareWar=false 必须拦截中立目标（近战与远程）
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "MELEE_ATTACK", 6, 5), "默认禁止攻击中立近战目标")
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 7, 5, false), "显式 false 禁止攻击中立远程目标")
    falsy(Teams[0]:IsAtWar(1), "拦截后不得宣战")
    eq(w:writeCount(), 0, "拦截期间零写入")

    -- 2. 和约期内即使 allowDeclareWar=true 也必须拦截
    w:setPeaceTreaty(0, 1, true)
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "MELEE_ATTACK", 6, 5, true), "和约期内 allowDeclareWar=true 必须拦截")
    falsy(Teams[0]:IsAtWar(1), "和约拦截不得触发 DeclareWar")
    eq(w:writeCount(), 0, "和约拦截零写入")
    w:setPeaceTreaty(0, 1, false)

    -- 3. E-02 关键验证：allowDeclareWar=true 但 CanRangeStrikeAt=false（如被山阻挡），严禁先宣战后失败
    falsy(CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 7, 6, true), "视线受阻应拦截")
    falsy(Teams[0]:IsAtWar(1), "E-02：前置失败绝不可残留已宣战状态")
    eq(w:writeCount(), 0, "E-02：前置失败写计数必须为 0")

    -- 4. 全部校验通过 + allowDeclareWar=true -> 先显式 DeclareWar 再下发攻击
    local ok, err, ctx = CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 7, 5, true)
    truthy(ok, "allowDeclareWar=true 显式宣战并远程打击应成功：" .. tostring(err))
    truthy(Teams[0]:IsAtWar(1), "应已对称宣战")
    truthy(ctx.warDeclared, "baselineContext.warDeclared 应为 true")
    eq(ctx.warDeclaredInfo.target_owner_id, 1, "应记录宣战目标玩家 ID")
    eq(ctx.warDeclaredInfo.target_team_id, 1, "应记录宣战目标团队 ID")
    eq(w.writeLog[1].kind, "DeclareWar", "第 1 条写调用必须先显式 DeclareWar")
    eq(w.writeLog[2].kind, "SelectionListGameNetMessage", "第 2 条写调用再下发攻击指令")
    eq(neutralRange:GetDamage(), 30, "目标应受到伤害")
    falsy(neutralMelee:IsDead(), "未攻击目标保持完好")
    falsy(blockedNeutral:IsDead(), "受阻目标保持完好")
end)

test("T-15", "WP2 原地动作（SETUP/FORTIFY/HEAL/SKIP）与 E-02 校验失败无痕恢复原选区", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, visibleAll = 0 })
    local prevSelected = w:addUnit({ owner = 0, unitType = "UNIT_WORKER", x = 2, y = 2 })
    local catapult = w:addUnit({
        owner = 0, unitType = "UNIT_CATAPULT", x = 5, y = 5,
        mustSetUp = true,
        canHandleActions = {
            MISSION_SET_UP_FOR_RANGED_ATTACK = true,
            MISSION_SKIP = true,
        },
    })
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 6, y = 5,
        damage = 20,
        canFortify = true,
        canHeal = true,
        canHandleActions = {}, -- 故意清空，验证 CanFortify / CanHeal / SKIP_TURN 回退路径
    })
    local settler = w:addUnit({ owner = 0, unitType = "UNIT_SETTLER", x = 7, y = 5 })

    -- 1. 校验失败必须零写入且恢复原选区（含原选中单位与原无选中两种情况）
    w:select(prevSelected)
    falsy(CAB_Executor.StartUnitAction(0, settler:GetID(), "SETUP_FOR_RANGED"), "开拓者禁架设")
    eq(UI.GetHeadSelectedUnit(), prevSelected, "E-02：失败后必须恢复原选中单位")
    falsy(CAB_Executor.StartUnitAction(0, settler:GetID(), "FORTIFY"), "开拓者禁驻扎")
    eq(UI.GetHeadSelectedUnit(), prevSelected, "E-02：FORTIFY 失败后恢复原选中单位")
    falsy(CAB_Executor.StartUnitAction(0, settler:GetID(), "HEAL"), "满血不可回血单位禁 HEAL")
    eq(UI.GetHeadSelectedUnit(), prevSelected, "E-02：HEAL 失败后恢复原选中单位")

    w:clearSelection()
    falsy(CAB_Executor.StartUnitAction(0, settler:GetID(), "SETUP_FOR_RANGED"), "原无选中时失败")
    isNil(UI.GetHeadSelectedUnit(), "E-02：原无选中时失败后必须清空选区")
    eq(w:writeCount(), 0, "全部失败均保持零写入")

    -- 2. SETUP_FOR_RANGED 走 HandleAction 主路径
    local okS, errS = CAB_Executor.StartUnitAction(0, catapult:GetID(), "SETUP_FOR_RANGED")
    truthy(okS, "投石车架设应成功：" .. tostring(errS))
    falsy(catapult:IsMustSetUpToRangedAttack(), "架设后 mustSetUp 变为 false")

    -- 3. FORTIFY 与 HEAL 走 CanFortify / CanHeal 回退路径
    local okF, errF = CAB_Executor.StartUnitAction(0, warrior:GetID(), "FORTIFY")
    truthy(okF, "FORTIFY 回退路径应成功：" .. tostring(errF))
    eq(warrior:GetFortifyTurns(), 1, "驻扎后 fortifyTurns 应递增")

    w:setUnit(warrior, { readyToMove = true })
    local okH, errH = CAB_Executor.StartUnitAction(0, warrior:GetID(), "HEAL")
    truthy(okH, "HEAL 回退路径应成功：" .. tostring(errH))
    falsy(warrior:IsReadyToMove(), "HEAL 后不再待命")

    -- 4. SKIP_TURN：已跳过单位重复 SKIP_TURN 必须拒绝；待命单位可成功跳过
    falsy(CAB_Executor.StartUnitAction(0, warrior:GetID(), "SKIP_TURN"), "已非待命单位重复 SKIP_TURN 应拦截")
    local okSkip, errSkip = CAB_Executor.StartUnitAction(0, catapult:GetID(), "SKIP_TURN")
    truthy(okSkip, "待命单位 SKIP_TURN 应成功：" .. tostring(errSkip))
    falsy(catapult:IsReadyToMove(), "SKIP_TURN 后不再待命")
end)

test("T-16", "WP2 StartCityRangeAttack：WorldView 序列、动态射程、E-03 防侧信道与 E-04 宣战护栏", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS }) -- 默认中立
    w:show(0, 5, 5)
    w:show(0, 7, 5) -- 距离 2（默认射程内）
    w:show(0, 8, 5) -- 距离 3（默认超距，动态改 CITY_ATTACK_RANGE=3 后合法）
    w:show(0, 6, 5) -- 放隐形敌军
    w:reveal(0, 5, 6) -- 普通迷雾

    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        canRangeStrikeNow = true,
        canRangeStrikeAt = { ["7:5"] = true, ["8:5"] = true, ["6:5"] = true, ["5:6"] = true },
        rangedOutcome = { damageToTarget = 45, fightingTicks = 1 },
    })
    local neutralAt2 = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 7, y = 5 })
    local neutralAt3 = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 8, y = 5 })
    w:addUnit({ owner = 1, unitType = "UNIT_TRIREME", x = 6, y = 5, invisibleTo = { [0] = true } })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 5, y = 6 }) -- 迷雾格

    -- 1. 迷雾格、黑雾格、隐形格、超距格、默认中立格全部拦截，且零 CanRangeStrikeAt 调用
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 5, 6), "普通迷雾格拒绝")
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 5, 4), "黑雾格拒绝")
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 6, 5), "隐形敌军格拒绝")
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 8, 5), "默认射程 2 下距离 3 应拒绝")
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 7, 5), "默认 allowDeclareWar=false 拒绝中立目标")
    eq(w:logCount("CanRangeStrikeAt"), 0, "E-03/E-04：拦截前不得调用 CanRangeStrikeAt")
    eq(w:writeCount(), 0, "拦截期间零写入")

    -- 2. 和约期 allowDeclareWar=true 拦截
    w:setPeaceTreaty(0, 1, true)
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 7, 5, true), "和约期拒绝城防宣战")
    eq(w:writeCount(), 0, "和约期零写入")
    w:setPeaceTreaty(0, 1, false)

    -- 3. 显式 allowDeclareWar=true 正常炮击，验证 WorldView.lua 调用序列与 CITY_ATTACK 基线
    local ok, err, ctx = CAB_Executor.StartCityRangeAttack(0, city:GetID(), 7, 5, true)
    truthy(ok, "城防显式宣战炮击应成功：" .. tostring(err))
    eq(ctx.settlementKind, "CITY_ATTACK", "settlementKind 应为 CITY_ATTACK")
    eq(ctx.cityID, city:GetID(), "cityID 匹配")
    truthy(ctx.warDeclared, "warDeclared 应为 true")
    truthy(Teams[0]:IsAtWar(1), "应已显式宣战")
    eq(neutralAt2:GetDamage(), 45, "目标应承受 45 点城防伤害")
    falsy(city:CanRangeStrikeNow(), "炮击后 CanRangeStrikeNow 应消耗")
    isNil(UI.GetHeadSelectedCity(), "炮击完成后必须 ClearSelectedCities")
    eq(w:logCount("Events.SpecificCityInfoDirty"), 1, "应触发 SpecificCityInfoDirty 刷新")

    -- 4. 冷却耗尽后再次炮击拒绝；动态扩充 GameDefines.CITY_ATTACK_RANGE=3 后立即生效（E-06 零缓存）
    falsy(CAB_Executor.StartCityRangeAttack(0, city:GetID(), 8, 5), "CanRangeStrikeNow=false 应拒绝")
    S.resetGameDefines({ CITY_ATTACK_RANGE = 3 })
    w:setCity(city, { canRangeStrikeNow = true })
    local ok3, err3 = CAB_Executor.StartCityRangeAttack(0, city:GetID(), 8, 5)
    truthy(ok3, "E-06：动态 CITY_ATTACK_RANGE=3 应实时生效：" .. tostring(err3))
    eq(neutralAt3:GetDamage(), 45, "3 格敌军应受击")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "E-03：全程 queriesOnForbiddenFog == 0")
end)

test("T-17", "WP2 D-04 双圆心联合 revealedBefore 采样：消除移动 1 格前沿已探索格假阳性", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS })
    -- 单位在 (10,10)，准备向东移动 1 格至 (11,10)；默认 DELTA_REVEAL_SCAN_RADIUS = 5
    -- (16,10) 距离 (10,10) 为 6（超出单圆心 r=5），但距离目标 (11,10) 为 5（落在移动后 r=5 扫描盘内）
    w:show(0, 10, 10)
    w:show(0, 11, 10)
    w:reveal(0, 16, 10) -- 移动前早已探索过的圆周前沿格

    local u = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 10, visionRange = 1,
        canMoveThrough = true,
    })

    local ok, err, ctx = CAB_Executor.StartUnitAction(0, u:GetID(), "MOVE_STEP", 11, 10)
    truthy(ok, "移动 1 格应成功：" .. tostring(err))
    eq(ctx.revealScanRadius, 5, "记录扫描半径 r=5")
    truthy(ctx.revealedBefore["16:10"], "D-04：双圆心联合采样必须预先收录距原位 6 格、距目标 5 格的已探索格 (16,10)")
end)

-- -----------------------------------------------------------------------------
-- 第 5 节：WP3 两段式异步结算与精准增量观测用例（T-18 ~ T-24）
-- -----------------------------------------------------------------------------

test("T-18", "WP3 IsSettlementBusy：三类 settlementKind 帧推进状态检测与非法入参零异常", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } }, visibleAll = 0, plotBuyDelayTicks = 2 })

    -- 1. UNIT_ACTION：存活单位 busyTicks/fightingTicks 推进至结束
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        combatOutcome = { damageToTarget = 100, counterDamage = 15, targetDies = true, busyTicks = 2, fightingTicks = 2 },
    })
    w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 6, y = 5 })
    local okU, errU, ctxU = CAB_Executor.StartUnitAction(0, warrior:GetID(), "MELEE_ATTACK", 6, 5)
    truthy(okU, "近战发起应成功：" .. tostring(errU))
    truthy(CAB_Executor.IsSettlementBusy(ctxU), "刚下发战斗动画时 IsSettlementBusy 应为 true")
    w:tickSettlement(1)
    truthy(CAB_Executor.IsSettlementBusy(ctxU), "推进 1 帧后仍忙碌应为 true")
    w:tickSettlement(1)
    falsy(CAB_Executor.IsSettlementBusy(ctxU), "推进 2 帧后动画结束应为 false")

    -- 2. UNIT_ACTION 边缘：己方单位阵亡但目标格战斗动画尚未结束，仍应返回 true 直至格动画完毕
    local suicide = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 8, y = 5,
        combatOutcome = { damageToTarget = 20, attackerDies = true, fightingTicks = 1 },
    })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 9, y = 5 })
    local okD, errD, ctxD = CAB_Executor.StartUnitAction(0, suicide:GetID(), "MELEE_ATTACK", 9, 5)
    truthy(okD, "反击阵亡场景发起应成功：" .. tostring(errD))
    truthy(suicide:IsDead(), "己方单位应已阵亡")
    truthy(CAB_Executor.IsSettlementBusy(ctxD), "己方阵亡但目标格仍在 IsFighting 时应为 true")
    w:tickSettlement(1)
    falsy(CAB_Executor.IsSettlementBusy(ctxD), "目标格战斗动画结束后应返回 false")

    -- 3. CITY_ATTACK：依据目标格 IsFighting 判定
    local city = w:addCity({
        owner = 0, name = "Rome", x = 3, y = 5,
        canRangeStrikeNow = true,
        canRangeStrikeAt = { ["4:5"] = true },
        rangedOutcome = { damageToTarget = 35, fightingTicks = 2 },
        buyPlotCost = { ["3:6"] = 80 },
    })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 4, y = 5 })
    local okC, errC, ctxC = CAB_Executor.StartCityRangeAttack(0, city:GetID(), 4, 5)
    truthy(okC, "城防炮击发起应成功：" .. tostring(errC))
    truthy(CAB_Executor.IsSettlementBusy(ctxC), "城防炮击刚下发应忙碌")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctxC), "推进 2 帧后城防炮击结算完成")

    -- 4. BUY_PLOT：依据目标格 GetOwner() ~= activePlayerID 判定
    Network.SendCityBuyPlot(city:GetID(), 3, 6)
    local ctxPlot = {
        settlementKind = "BUY_PLOT",
        activePlayerID = 0,
        cityID = city:GetID(),
        targetX = 3,
        targetY = 6,
        goldBefore = 500,
        expectedCost = 80,
    }
    truthy(CAB_Executor.IsSettlementBusy(ctxPlot), "买地归属尚未翻转时 IsSettlementBusy 应为 true")
    w:tickSettlement(1)
    truthy(CAB_Executor.IsSettlementBusy(ctxPlot), "推进 1 帧归属仍未翻转应为 true")
    w:tickSettlement(1)
    falsy(CAB_Executor.IsSettlementBusy(ctxPlot), "推进 2 帧归属翻转为玩家 0 后应为 false")

    -- 5. 非法入参零异常安全返回 false
    falsy(CAB_Executor.IsSettlementBusy(nil), "nil 基线返回 false")
    falsy(CAB_Executor.IsSettlementBusy("bad"), "非表基线返回 false")
    falsy(CAB_Executor.IsSettlementBusy({}), "空表基线返回 false")
    falsy(CAB_Executor.IsSettlementBusy({ settlementKind = "UNKNOWN", activePlayerID = 0 }), "未知类型返回 false")
    falsy(CAB_Executor.IsSettlementBusy({ settlementKind = "UNIT_ACTION", activePlayerID = -1 }), "非法玩家返回 false")
    falsy(CAB_Executor.IsSettlementBusy({ settlementKind = "BUY_PLOT", activePlayerID = 0, targetX = 999, targetY = 999 }), "越界买地格返回 false")
end)

test("T-19", "WP3 UNIT_ACTION 移动结算：D-04 双圆心消假阳性精准揭盲与新现身敌军（过滤隐形）", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } } })
    -- 初始仅点亮 (10,10) 半径 1 内的 7 个六边形格，再额外预探索圆周前沿 (16,10)（距原位 6、距目标 5）
    local initVisible = {
        { 10, 10 }, { 9, 10 }, { 11, 10 }, { 9, 9 }, { 10, 9 }, { 9, 11 }, { 10, 11 },
    }
    for _, pt in ipairs(initVisible) do
        w:show(0, pt[1], pt[2])
    end
    w:reveal(0, 16, 10)

    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 10, visionRange = 1,
        canMoveThrough = true,
    })
    -- 移动前已可见的敌军（不应重复报入 newly_spotted_enemies）
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 9, y = 10 })
    -- 藏在移动前沿黑雾 (12,10) 的普通敌军（移动后新揭开并可见，必须报入 newly_spotted_enemies）
    local ambushEnemy = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 12, y = 10 })
    -- 藏在移动前沿黑雾 (11,9) 的隐形敌军（地块揭开后仍不可探测，绝不可报入 newly_spotted_enemies）
    w:addUnit({ owner = 1, unitType = "UNIT_TRIREME", x = 11, y = 9, invisibleTo = { [0] = true } })

    local ok, err, ctx = CAB_Executor.StartUnitAction(0, warrior:GetID(), "MOVE_STEP", 11, 10)
    truthy(ok, "移动 1 格应成功：" .. tostring(err))
    local res = CAB_Executor.FinalizeActionSettlement(ctx, 350)

    truthy(res.__is_object, "结果 DTO 应带 __is_object = true")
    truthy(res.executed, "executed 应为 true")
    eq(res.action_type, "MOVE_STEP", "action_type 匹配")
    eq(res.target_x, 11, "target_x 匹配")
    eq(res.target_y, 10, "target_y 匹配")
    eq(res.settle_wait_ms, 350, "settle_wait_ms 匹配")
    falsy(res.timed_out, "移动无残留忙碌，timed_out 应为 false")
    isNil(res.war_declared, "未宣战时应省略 war_declared")
    falsy(res.unit_died, "单位存活")
    notNil(res.unit_after, "应返回最新 unit_after")
    eq(res.unit_after.x, 11, "unit_after.x 应更新至 11")
    eq(res.unit_after.y, 10, "unit_after.y 应更新至 10")

    local delta = res.delta_observation
    truthy(delta.__is_object, "delta_observation 应带 __is_object = true")
    -- (11,10) 半径 1 新揭开的仅 (12,10)、(11,9)、(11,11) 共 3 格；(16,10) 已被双圆心预先收录，绝无假阳性
    eq(delta.newly_revealed_tiles_count, 3, "D-04：双圆心精准揭盲计数必须严格为 3（排除 (16,10) 假阳性）")
    eq(delta.newly_spotted_count, 1, "应仅新发现 1 个非隐形敌军")
    eq(#delta.newly_spotted_enemies, 1, "newly_spotted_enemies 数组长度为 1")
    eq(delta.newly_spotted_enemies[1].enemy_id, "1:" .. tostring(ambushEnemy:GetID()), "新发现敌军 ID 匹配")
    isNil(delta.target_enemy_after, "MOVE_STEP 应省略 target_enemy_after")
    isNil(delta.target_city_after, "无目标敌城时应省略 target_city_after")
end)

test("T-20", "WP3 UNIT_ACTION 战斗结算：残血、显式宣战击杀、己方反击阵亡与 timed_out 标志", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, visibleAll = 0 }) -- 初始中立，验证宣战标记传递

    -- 场景 A：显式宣战近战击杀 + 提前结算 timed_out=true vs 帧毕 timed_out=false
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        combatOutcome = { damageToTarget = 100, counterDamage = 20, targetDies = true, busyTicks = 2, fightingTicks = 2 },
    })
    local neutralTarget = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 6, y = 5 })

    local okA, errA, ctxA = CAB_Executor.StartUnitAction(0, warrior:GetID(), "MELEE_ATTACK", 6, 5, true)
    truthy(okA, "显式宣战近战应成功：" .. tostring(errA))

    local resTimeout = CAB_Executor.FinalizeActionSettlement(ctxA, 1500)
    truthy(resTimeout.timed_out, "忙碌未清零时结算 timed_out 必须为 true")

    w:tickSettlement(2)
    local resA = CAB_Executor.FinalizeActionSettlement(ctxA, 420)
    falsy(resA.timed_out, "动画结束后 timed_out 应为 false")
    truthy(resA.war_declared, "D-03：显式宣战动作结算必须标记 war_declared = true")
    eq(resA.war_declared_target_player_id, 1, "D-03：记录宣战目标玩家 ID")
    eq(resA.war_declared_target_team_id, 1, "D-03：记录宣战目标团队 ID")
    falsy(resA.unit_died, "击杀敌军后己方存活")
    eq(resA.unit_after.hp, 80, "己方承受 20 反击伤剩余 80 HP")
    eq(resA.unit_after.x, 6, "近战击杀后进占 (6,5)")
    notNil(resA.delta_observation.target_enemy_after, "应返回 target_enemy_after")
    truthy(resA.delta_observation.target_enemy_after.__is_object, "target_enemy_after 应带 __is_object")
    eq(resA.delta_observation.target_enemy_after.enemy_id, "1:" .. tostring(neutralTarget:GetID()), "受击敌军 ID 匹配")
    eq(resA.delta_observation.target_enemy_after.hp, 0, "被击杀敌军血量归 0")
    truthy(resA.delta_observation.target_enemy_after.enemy_killed, "被击杀敌军 enemy_killed = true")

    -- 场景 B：远程击伤残血（enemy_killed = false）
    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 3, y = 5,
        canRangeStrikeAt = { ["5:6"] = true },
        combatOutcome = { damageToTarget = 35 },
    })
    local survivor = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 5, y = 6 })
    local okB, errB, ctxB = CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 5, 6)
    truthy(okB, "远程射击应成功：" .. tostring(errB))
    local resB = CAB_Executor.FinalizeActionSettlement(ctxB, 350)
    isNil(resB.war_declared, "已处于交战状态，不应设置 war_declared")
    eq(resB.delta_observation.target_enemy_after.hp, 65, "残血敌军应剩 65 HP")
    falsy(resB.delta_observation.target_enemy_after.enemy_killed, "存活敌军 enemy_killed = false")

    -- 场景 C：己方近战反击阵亡（unit_died = true, unit_after = nil）
    local doomed = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 8, y = 5,
        combatOutcome = { damageToTarget = 40, attackerDies = true },
    })
    local counterKiller = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 9, y = 5 })
    local okC, errC, ctxC = CAB_Executor.StartUnitAction(0, doomed:GetID(), "MELEE_ATTACK", 9, 5)
    truthy(okC, "反击阵亡测试发起应成功：" .. tostring(errC))
    local resC = CAB_Executor.FinalizeActionSettlement(ctxC, 380)
    truthy(resC.unit_died, "己方阵亡时 unit_died 必须为 true")
    isNil(resC.unit_after, "己方阵亡时 unit_after 必须为 nil（省略键）")
    eq(resC.delta_observation.target_enemy_after.enemy_id, "1:" .. tostring(counterKiller:GetID()), "敌军 ID 匹配")
    eq(resC.delta_observation.target_enemy_after.hp, 60, "敌军存活残血 60 HP")
    falsy(resC.delta_observation.target_enemy_after.enemy_killed, "敌军存活 enemy_killed = false")
end)

test("T-21", "WP3 UNIT_ACTION 攻城三态结算：target_city_after 残血、占领与毁城", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } } })
    w:show(0, 5, 5)
    w:reveal(0, 7, 5) -- 仅已探索迷雾中的敌城（测试远程轰炸迷雾敌城）
    w:show(0, 6, 5)
    w:show(0, 10, 5)
    w:show(0, 11, 5)

    -- 1. 远程轰炸已探索迷雾敌城：残血（captured=false, destroyed=false）
    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 5, y = 5,
        canRangeStrikeAt = { ["7:5"] = true },
        combatOutcome = { cityDamage = 40 },
    })
    local fogCity = w:addCity({ owner = 1, name = "Carthage", x = 7, y = 5 })
    local ok1, err1, ctx1 = CAB_Executor.StartUnitAction(0, archer:GetID(), "RANGE_ATTACK", 7, 5)
    truthy(ok1, "远程轰炸迷雾敌城应成功：" .. tostring(err1))
    local res1 = CAB_Executor.FinalizeActionSettlement(ctx1, 350)
    local tc1 = res1.delta_observation.target_city_after
    notNil(tc1, "攻城结算必须返回 target_city_after")
    truthy(tc1.__is_object, "target_city_after 应带 __is_object = true")
    eq(tc1.city_id, "1:" .. tostring(fogCity:GetID()), "残血敌城复合 ID 匹配")
    eq(tc1.owner_id, 1, "仍归属敌方 1")
    eq(tc1.hp, 160, "200 - 40 = 160 HP")
    falsy(tc1.captured, "未占领")
    falsy(tc1.destroyed, "未毁城")

    -- 2. 近战占领敌城：captured = true, destroyed = false, owner_id = 0
    local capturer = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        combatOutcome = { cityCaptured = true, counterDamage = 25 },
    })
    w:addCity({ owner = 1, name = "Utica", x = 6, y = 5, damage = 180 })
    local ok2, err2, ctx2 = CAB_Executor.StartUnitAction(0, capturer:GetID(), "MELEE_ATTACK", 6, 5)
    truthy(ok2, "近战占领敌城应成功：" .. tostring(err2))
    local res2 = CAB_Executor.FinalizeActionSettlement(ctx2, 450)
    local tc2 = res2.delta_observation.target_city_after
    notNil(tc2, "占领后应返回 target_city_after")
    truthy(tc2.captured, "captured 必须为 true")
    falsy(tc2.destroyed, "destroyed 必须为 false")
    eq(tc2.owner_id, 0, "占领后归属翻转为己方 0")
    eq(tc2.hp, 100, "占领后按半血重置为 100 HP")
    eq(res2.unit_after.x, 6, "占城后我方单位进驻城格")

    -- 3. 近战毁城：destroyed = true, captured = false, hp = 0
    local razer = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 5,
        combatOutcome = { cityDestroyed = true, counterDamage = 10 },
    })
    local doomedCity = w:addCity({ owner = 1, name = "Hippo", x = 11, y = 5 })
    local ok3, err3, ctx3 = CAB_Executor.StartUnitAction(0, razer:GetID(), "MELEE_ATTACK", 11, 5)
    truthy(ok3, "近战毁城应成功：" .. tostring(err3))
    local res3 = CAB_Executor.FinalizeActionSettlement(ctx3, 450)
    local tc3 = res3.delta_observation.target_city_after
    notNil(tc3, "毁城后应返回 target_city_after")
    falsy(tc3.captured, "毁城时 captured 应为 false")
    truthy(tc3.destroyed, "毁城时 destroyed 必须为 true")
    eq(tc3.city_id, "1:" .. tostring(doomedCity:GetID()), "毁城保留战前复合 city_id")
    eq(tc3.hp, 0, "毁城后 hp 应为 0")
    eq(res3.unit_after.x, 11, "毁城后单位进占原城格")
end)

test("T-22", "WP3 CITY_ATTACK 城防炮击结算：city_id、city_after、残血与击杀、war_declared 及 timed_out", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, visibleAll = 0 }) -- 默认中立

    local city1 = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        canRangeStrikeNow = true,
        canRangeStrikeAt = { ["7:5"] = true },
        rangedOutcome = { damageToTarget = 45, fightingTicks = 2 },
    })
    local city2 = w:addCity({
        owner = 0, name = "Antium", x = 12, y = 5,
        canRangeStrikeNow = true,
        canRangeStrikeAt = { ["13:5"] = true },
        rangedOutcome = { damageToTarget = 100, targetDies = true, fightingTicks = 1 },
    })
    local enemy1 = w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 7, y = 5 })
    local enemy2 = w:addUnit({ owner = 1, unitType = "UNIT_ARCHER", x = 13, y = 5 })

    -- 1. 显式宣战城防炮击击伤敌军 + 超时态 vs 完成态
    local ok1, err1, ctx1 = CAB_Executor.StartCityRangeAttack(0, city1:GetID(), 7, 5, true)
    truthy(ok1, "城防显式宣战炮击应成功：" .. tostring(err1))
    local resEarly = CAB_Executor.FinalizeActionSettlement(ctx1, 1500)
    truthy(resEarly.timed_out, "炮击动画未完成时 timed_out 应为 true")

    w:tickSettlement(2)
    local res1 = CAB_Executor.FinalizeActionSettlement(ctx1, 360)
    truthy(res1.__is_object, "结果 DTO 带 __is_object = true")
    truthy(res1.executed, "executed = true")
    eq(res1.action_type, "CITY_RANGE_ATTACK", "action_type 为 CITY_RANGE_ATTACK")
    eq(res1.city_id, city1:GetID(), "city_id 匹配")
    notNil(res1.city_after, "D-04：必须返回 city_after（SerializeCitySummary）")
    truthy(res1.city_after.__is_object, "city_after 带 __is_object = true")
    eq(res1.city_after.city_id, city1:GetID(), "city_after.city_id 匹配")
    falsy(res1.city_after.can_range_strike, "炮击后 city_after.can_range_strike 应为 false")
    falsy(res1.timed_out, "帧毕后 timed_out = false")
    truthy(res1.war_declared, "显式宣战标记 war_declared = true")
    eq(res1.war_declared_target_player_id, 1, "宣战目标玩家 ID 匹配")
    eq(res1.delta_observation.target_enemy_after.enemy_id, "1:" .. tostring(enemy1:GetID()), "受击敌军 ID 匹配")
    eq(res1.delta_observation.target_enemy_after.hp, 55, "受击敌军剩 55 HP")
    falsy(res1.delta_observation.target_enemy_after.enemy_killed, "未击杀")

    -- 2. 城防炮击击杀敌军
    local ok2, err2, ctx2 = CAB_Executor.StartCityRangeAttack(0, city2:GetID(), 13, 5)
    truthy(ok2, "第二座城炮击击杀应成功：" .. tostring(err2))
    w:tickSettlement(1)
    local res2 = CAB_Executor.FinalizeActionSettlement(ctx2, 350)
    isNil(res2.war_declared, "已交战后不再置 war_declared")
    eq(res2.delta_observation.target_enemy_after.enemy_id, "1:" .. tostring(enemy2:GetID()), "被击杀敌军 ID 匹配")
    eq(res2.delta_observation.target_enemy_after.hp, 0, "被击杀敌军 HP=0")
    truthy(res2.delta_observation.target_enemy_after.enemy_killed, "被击杀 enemy_killed=true")
end)

test("T-23", "WP3 BUY_PLOT 买地异步结算：归属翻转成功与兜底超时未翻转判定", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, plotBuyDelayTicks = 2 })
    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        buyPlotCost = { ["6:5"] = 80 },
    })

    -- 发起异步买地包（模拟 WP4 PurchaseCityPlot 构造的 baselineContext）
    local goldBefore = Players[0]:GetGold()
    Network.SendCityBuyPlot(city:GetID(), 6, 5)
    local ctx = {
        settlementKind = "BUY_PLOT",
        activePlayerID = 0,
        cityID = city:GetID(),
        targetX = 6,
        targetY = 5,
        goldBefore = goldBefore,
        expectedCost = 80,
    }

    -- 1. 兜底超时场景：归属尚未翻转时强行结算 -> purchased=false, timed_out=true
    truthy(CAB_Executor.IsSettlementBusy(ctx), "买地包未落地前仍处于忙碌")
    local resTimeout = CAB_Executor.FinalizeActionSettlement(ctx, 1500)
    truthy(resTimeout.__is_object, "BUY_PLOT DTO 带 __is_object = true")
    falsy(resTimeout.purchased, "D-04：归属未翻转时 purchased 必须为 false")
    truthy(resTimeout.timed_out, "超时兜底 timed_out 必须为 true")
    notNil(resTimeout.error_reason, "未翻转时必须提供 error_reason")
    eq(resTimeout.city_id, city:GetID(), "city_id 匹配")
    eq(resTimeout.x, 6, "x 匹配")
    eq(resTimeout.y, 5, "y 匹配")
    eq(resTimeout.cost_paid, 0, "未扣费时 cost_paid 为 0")
    eq(resTimeout.expected_cost, 80, "expected_cost 为 80")
    eq(resTimeout.gold_before, 500, "gold_before 为 500")
    eq(resTimeout.gold_after, 500, "gold_after 仍为 500")
    eq(resTimeout.new_owner_id, -1, "归属仍为无主 -1")
    eq(resTimeout.settle_wait_ms, 1500, "settle_wait_ms 匹配")

    -- 2. 正常落地场景：推进 2 帧后归属翻转与扣费完成 -> purchased=true, timed_out=false
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctx), "归属翻转后 IsSettlementBusy 应为 false")
    local resOk = CAB_Executor.FinalizeActionSettlement(ctx, 120)
    truthy(resOk.purchased, "D-04：归属翻转为玩家 0 后 purchased 必须为 true")
    falsy(resOk.timed_out, "正常完成 timed_out 必须为 false")
    isNil(resOk.error_reason, "购买成功时应省略 error_reason")
    eq(resOk.cost_paid, 80, "实际扣费 cost_paid 为 80")
    eq(resOk.expected_cost, 80, "expected_cost 为 80")
    eq(resOk.gold_before, 500, "gold_before 为 500")
    eq(resOk.gold_after, 420, "gold_after 扣至 420")
    eq(resOk.new_owner_id, 0, "new_owner_id 翻转为 0")
    eq(resOk.settle_wait_ms, 120, "settle_wait_ms 匹配")
end)

test("T-24", "WP3 防御性与只读审计：非法 baselineContext 零异常且结算接口全程零写调用", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } }, visibleAll = 0 })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5, canMoveThrough = true })
    w:select(u)

    -- 1. 非法入参调用 FinalizeActionSettlement 绝不抛异常
    local r1 = CAB_Executor.FinalizeActionSettlement(nil, 100)
    truthy(r1.__is_object, "nil 入参返回带 __is_object 的结构化错返")
    falsy(r1.executed, "executed = false")
    notNil(r1.error_reason, "包含 error_reason")
    eq(r1.settle_wait_ms, 100, "保留合法 settle_wait_ms")
    falsy(r1.timed_out, "timed_out = false")

    local r2 = CAB_Executor.FinalizeActionSettlement({ settlementKind = "NO_SUCH_KIND" }, "not_a_number")
    truthy(r2.__is_object, "未知 settlementKind 返回结构化错返")
    falsy(r2.executed, "executed = false")
    notNil(r2.error_reason, "包含 error_reason")
    eq(r2.settle_wait_ms, 0, "非法 settleWaitMs 安全回退 0")

    -- 2. 验证 IsSettlementBusy 与 FinalizeActionSettlement 严格只读（零引擎写调用、零选区变更）
    local ok, err, ctx = CAB_Executor.StartUnitAction(0, u:GetID(), "MOVE_STEP", 6, 5)
    truthy(ok, "准备动作应成功：" .. tostring(err))
    local writesBefore = w:writeCount()
    local selectedBefore = UI.GetHeadSelectedUnit()

    falsy(CAB_Executor.IsSettlementBusy(ctx), "移动无忙碌动画")
    local res = CAB_Executor.FinalizeActionSettlement(ctx, 350)
    truthy(res.executed, "结算应成功")

    eq(w:writeCount(), writesBefore, "IsSettlementBusy 与 FinalizeActionSettlement 必须保持零写调用")
    eq(UI.GetHeadSelectedUnit(), selectedBefore, "结算接口不得改动 UI 选区")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "E-03：结算期间 queriesOnForbiddenFog == 0")
end)

-- -----------------------------------------------------------------------------
-- 第 6 节：WP4 城市内政、安全下一回合、IGE 动态变阵与非法入参防御用例（T-25 ~ T-32）
-- -----------------------------------------------------------------------------

test("T-25", "WP4 PurchaseCityItem 建筑购买：双层校验、金币/信仰双通道与 PURCHASE_ITEM 短异步结算及超时兜底", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, cityActionDelayTicks = 2 })
    local bGranary = GameInfoTypes.BUILDING_GRANARY
    local bWalls = GameInfoTypes.BUILDING_WALLS
    local bMonument = GameInfoTypes.BUILDING_MONUMENT
    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        purchasable = {
            buildings = {
                [bGranary] = { gold = true },
                [bWalls] = { faith = true },
                [bMonument] = { gold = true }, -- 规则可买但当前余额不足
            },
            units = {},
        },
        affordable = {
            buildings = {
                [bGranary] = { gold = true },
                [bWalls] = { faith = true },
                [bMonument] = { gold = false },
            },
            units = {},
        },
        costs = {
            bldGold = { [bGranary] = 200, [bMonument] = 600 },
            bldFaith = { [bWalls] = 180 },
        },
    })

    -- 1. 双层 IsCanPurchase 错误细分：前置未满足/不可买 vs 余额不足（均零写入）
    local okUnmet, errUnmet, dtoUnmet = CAB_Executor.PurchaseCityItem(0, city:GetID(), "BUILDING", "BUILDING_PALACE", "GOLD")
    falsy(okUnmet, "不可购建筑应拒绝")
    notNil(errUnmet, "应返回前置/不可买错误说明")
    truthy(errUnmet:find("prerequisites", 1, true) ~= nil, "错误信息应明确区分规则/前置未满足：" .. tostring(errUnmet))
    isNil(dtoUnmet, "失败时基线应为 nil")

    local okPoor, errPoor, dtoPoor = CAB_Executor.PurchaseCityItem(0, city:GetID(), "BUILDING", "BUILDING_MONUMENT", "GOLD")
    falsy(okPoor, "金币不足应拒绝")
    notNil(errPoor, "应返回金币不足错误说明")
    truthy(errPoor:find("Insufficient GOLD", 1, true) ~= nil, "错误信息应区分余额不足：" .. tostring(errPoor))
    truthy(errPoor:find("600", 1, true) ~= nil, "错误信息应附带所需金币报价")
    isNil(dtoPoor, "失败时基线应为 nil")
    eq(w:writeCount(), 0, "E-02：购买校验失败必须零写入")

    -- 2. 默认 itemCategory=nil ("BUILDING")、yieldTypeStr=nil ("GOLD")，Type 串购买粮仓 + 跨帧异步结算
    local okGold, errGold, ctxGold = CAB_Executor.PurchaseCityItem(0, city:GetID(), nil, "BUILDING_GRANARY", nil)
    truthy(okGold, "金币默认购买建筑下发应成功：" .. tostring(errGold))
    eq(ctxGold.settlementKind, "PURCHASE_ITEM", "settlementKind 应为 PURCHASE_ITEM")
    eq(ctxGold.minWaitSec, CAB_Config.PLOT_BUY_SETTLE_SEC, "minWaitSec 对齐 PLOT_BUY_SETTLE_SEC")
    truthy(CAB_Executor.IsSettlementBusy(ctxGold), "消息队列未落地前 IsSettlementBusy 应为 true")
    w:tickSettlement(1)
    truthy(CAB_Executor.IsSettlementBusy(ctxGold), "仅推进 1 帧时仍应忙碌")
    w:tickSettlement(1)
    falsy(CAB_Executor.IsSettlementBusy(ctxGold), "推进 2 帧建筑落地后 IsSettlementBusy 应为 false")

    local resGold = CAB_Executor.FinalizeActionSettlement(ctxGold, 110)
    truthy(resGold.__is_object, "结果 DTO 应带 __is_object = true")
    truthy(resGold.purchased, "purchased 应为 true")
    falsy(resGold.timed_out, "timed_out 应为 false")
    isNil(resGold.error_reason, "成功时省略 error_reason")
    eq(resGold.city_id, city:GetID(), "city_id 匹配")
    eq(resGold.item_category, "BUILDING", "默认 item_category 应为 BUILDING")
    eq(resGold.item_type, "BUILDING_GRANARY", "item_type 匹配")
    eq(resGold.yield_type, "GOLD", "默认 yield_type 应为 GOLD")
    eq(resGold.cost_paid, 200, "实际扣费 200 金币")
    eq(resGold.expected_cost, 200, "expected_cost 为 200")
    eq(resGold.gold_before, 500, "gold_before 应为 500")
    eq(resGold.gold_after, 300, "gold_after 应为 300")
    eq(resGold.settle_wait_ms, 110, "settle_wait_ms 匹配")
    isNil(resGold.faith_before, "金币通道应省略 faith_before")
    isNil(resGold.faith_after, "金币通道应省略 faith_after")
    isNil(resGold.spawned_unit_id, "买建筑应省略 spawned_unit_id")
    notNil(resGold.city_summary_after, "应回读 city_summary_after")
    truthy(resGold.city_summary_after.__is_object, "city_summary_after 带 __is_object = true")
    eq(city:GetNumRealBuilding(bGranary), 1, "城内应已拥有 1 座粮仓")
    eq(w:logCount("Events.SpecificCityInfoDirty"), 1, "应触发 SpecificCityInfoDirty")

    -- 3. 信仰通道 + 整数 ID 购买城墙：先验证未落地时超时兜底，再验证落地后成功
    local okFaith, errFaith, ctxFaith = CAB_Executor.PurchaseCityItem(0, city:GetID(), "BUILDING", bWalls, "FAITH")
    truthy(okFaith, "信仰按整数 ID 购买建筑下发应成功：" .. tostring(errFaith))
    local resTimeout = CAB_Executor.FinalizeActionSettlement(ctxFaith, 1500)
    falsy(resTimeout.purchased, "未落地超时兜底时 purchased 应为 false")
    truthy(resTimeout.timed_out, "未落地超时兜底时 timed_out 应为 true")
    notNil(resTimeout.error_reason, "超时兜底应返回明确 error_reason")

    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctxFaith), "2 帧后城墙应落地")
    local resFaith = CAB_Executor.FinalizeActionSettlement(ctxFaith, 120)
    truthy(resFaith.purchased, "落地后 purchased 应为 true")
    falsy(resFaith.timed_out, "落地后 timed_out 应为 false")
    eq(resFaith.item_type, "BUILDING_WALLS", "整数 ID 应解析为 BUILDING_WALLS")
    eq(resFaith.yield_type, "FAITH", "yield_type 应为 FAITH")
    eq(resFaith.cost_paid, 180, "实际扣费 180 信仰")
    eq(resFaith.faith_before, 300, "faith_before 应为 300")
    eq(resFaith.faith_after, 120, "faith_after 应为 120")
    isNil(resFaith.gold_before, "信仰通道应省略 gold_before")
    isNil(resFaith.gold_after, "信仰通道应省略 gold_after")
    eq(city:GetNumRealBuilding(bWalls), 1, "城内应已拥有 1 座城墙")
    eq(w:logCount("Events.SpecificCityInfoDirty"), 2, "第二次购买应再次触发 SpecificCityInfoDirty")

    -- 4. 已拥有建筑重复购买应被规则层拦截（零写入）
    local writesNow = w:writeCount()
    falsy(CAB_Executor.PurchaseCityItem(0, city:GetID(), "BUILDING", "BUILDING_GRANARY", "GOLD"), "重复购买已拥有建筑应拒绝")
    eq(w:writeCount(), writesNow, "重复购买拦截应零写入")
end)

test("T-26", "WP4 PurchaseCityItem 单位购买：金币/信仰双通道、跨帧新生 spawned_unit_id 精准识别与叠栈拦截", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, cityActionDelayTicks = 2 })
    local uArcher = GameInfoTypes.UNIT_ARCHER
    local uWarrior = GameInfoTypes.UNIT_WARRIOR
    local uCatapult = GameInfoTypes.UNIT_CATAPULT

    -- 预先在城格放置 1 个工人，城外放置 1 个弓箭手，验证差分不会误匹配旧单位
    local preWorker = w:addUnit({ owner = 0, unitType = "UNIT_WORKER", x = 5, y = 5 })
    local preArcher = w:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 7, y = 5 })

    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        purchasable = {
            buildings = {},
            units = {
                [uArcher] = { gold = true },
                [uWarrior] = { faith = true },
                [uCatapult] = { gold = true },
            },
        },
        affordable = {
            buildings = {},
            units = {
                [uArcher] = { gold = true },
                [uWarrior] = { faith = true },
                [uCatapult] = { gold = false }, -- 金币够但城内叠栈不可买
            },
        },
        costs = {
            unitGold = { [uArcher] = 150, [uCatapult] = 200 },
            unitFaith = { [uWarrior] = 120 },
        },
    })

    -- 1. 余额足够但城内同类单位叠栈导致 IsCanPurchase(true,true)=false -> 精准提示叠栈/条件不满足且零写入
    local okStack, errStack = CAB_Executor.PurchaseCityItem(0, city:GetID(), "UNIT", "UNIT_CATAPULT", "GOLD")
    falsy(okStack, "叠栈冲突购买单位应拒绝")
    truthy(errStack:find("stacking", 1, true) ~= nil, "错误信息应提示叠栈冲突：" .. tostring(errStack))
    eq(w:writeCount(), 0, "叠栈拦截必须零写入")

    -- 2. 金币购买弓箭手：跨帧后精准识别新生 spawned_unit_id（不同于 preWorker 与 preArcher）
    local okGold, errGold, ctxGold = CAB_Executor.PurchaseCityItem(0, city:GetID(), "UNIT", "UNIT_ARCHER", "GOLD")
    truthy(okGold, "金币购买弓箭手下发应成功：" .. tostring(errGold))
    eq(ctxGold.settlementKind, "PURCHASE_ITEM", "settlementKind 应为 PURCHASE_ITEM")
    truthy(CAB_Executor.IsSettlementBusy(ctxGold), "新单位诞生前 IsSettlementBusy 应为 true")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctxGold), "新单位诞生后 IsSettlementBusy 应为 false")

    local resGold = CAB_Executor.FinalizeActionSettlement(ctxGold, 115)
    truthy(resGold.purchased, "purchased 应为 true")
    falsy(resGold.timed_out, "timed_out 应为 false")
    eq(resGold.item_category, "UNIT", "item_category 应为 UNIT")
    eq(resGold.item_type, "UNIT_ARCHER", "item_type 匹配")
    eq(resGold.cost_paid, 150, "实际扣费 150 金币")
    eq(resGold.gold_before, 500, "gold_before 为 500")
    eq(resGold.gold_after, 350, "gold_after 为 350")
    notNil(resGold.spawned_unit_id, "必须返回新生 spawned_unit_id")
    truthy(resGold.spawned_unit_id ~= preWorker:GetID(), "不得误匹配旧工人 ID")
    truthy(resGold.spawned_unit_id ~= preArcher:GetID(), "不得误匹配城外旧弓箭手 ID")
    local spawned1 = Players[0]:GetUnitByID(resGold.spawned_unit_id)
    notNil(spawned1, "新单位应存在于玩家单位列表中")
    eq(spawned1:GetUnitType(), uArcher, "新单位类型应为 UNIT_ARCHER")
    eq(spawned1:GetX(), 5, "新单位生成于城市 x=5")
    eq(spawned1:GetY(), 5, "新单位生成于城市 y=5")

    -- 3. 信仰 + 整数 ID 购买勇士：返回另一新 spawned_unit_id
    local okFaith, errFaith, ctxFaith = CAB_Executor.PurchaseCityItem(0, city:GetID(), "UNIT", uWarrior, "FAITH")
    truthy(okFaith, "信仰按 ID 购买勇士下发应成功：" .. tostring(errFaith))
    w:tickSettlement(2)
    local resFaith = CAB_Executor.FinalizeActionSettlement(ctxFaith, 105)
    truthy(resFaith.purchased, "信仰买单位结算成功")
    eq(resFaith.yield_type, "FAITH", "yield_type 应为 FAITH")
    eq(resFaith.cost_paid, 120, "实际扣费 120 信仰")
    eq(resFaith.faith_before, 300, "faith_before 为 300")
    eq(resFaith.faith_after, 180, "faith_after 为 180")
    notNil(resFaith.spawned_unit_id, "应返回新生勇士 ID")
    truthy(resFaith.spawned_unit_id ~= resGold.spawned_unit_id, "两次购买应返回不同新生 ID")
end)

test("T-27", "WP4 SetCityProduction：四类订单、clearQueue 清空/追加、SET_PRODUCTION 短异步结算与受限拦截", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, cityActionDelayTicks = 2 })
    local bWalls = GameInfoTypes.BUILDING_WALLS
    local uArcher = GameInfoTypes.UNIT_ARCHER
    local pApollo = GameInfoTypes.PROJECT_APOLLO_PROGRAM
    local prWealth = GameInfoTypes.PROCESS_WEALTH

    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        canConstruct = { [bWalls] = true },
        canTrain = { [uArcher] = true },
        canCreate = { [pApollo] = true },
        canMaintain = { [prWealth] = true },
    })
    local puppetCity = w:addCity({ owner = 0, name = "Puppet", x = 8, y = 5, isPuppet = true })
    local resistCity = w:addCity({ owner = 0, name = "Resist", x = 10, y = 5, isResistance = true })
    local razingCity = w:addCity({ owner = 0, name = "Razing", x = 12, y = 5, isRazing = true })

    -- 1. 受限城市与前置不满足项目必须拦截且零写入
    falsy(CAB_Executor.SetCityProduction(0, puppetCity:GetID(), "BUILDING", "BUILDING_WALLS"), "傀儡城禁止设生产")
    falsy(CAB_Executor.SetCityProduction(0, resistCity:GetID(), "BUILDING", "BUILDING_WALLS"), "抵抗城禁止设生产")
    falsy(CAB_Executor.SetCityProduction(0, razingCity:GetID(), "BUILDING", "BUILDING_WALLS"), "焚城禁止设生产")
    falsy(CAB_Executor.SetCityProduction(0, city:GetID(), "BUILDING", "BUILDING_GRANARY"), "CanConstruct=false 应拒绝")
    falsy(CAB_Executor.SetCityProduction(0, city:GetID(), "UNIT", "UNIT_WARRIOR"), "CanTrain=false 应拒绝")
    falsy(CAB_Executor.SetCityProduction(0, city:GetID(), "PROJECT", "PROJECT_MANHATTAN_PROJECT"), "CanCreate=false 应拒绝")
    falsy(CAB_Executor.SetCityProduction(0, city:GetID(), "PROCESS", "PROCESS_RESEARCH"), "CanMaintain=false 应拒绝")
    eq(w:writeCount(), 0, "E-02：受限与前置失败必须零写入")

    -- 2. BUILDING（默认 clearQueue = true）+ 异步结算及超时兜底
    local ok1, err1, ctx1 = CAB_Executor.SetCityProduction(0, city:GetID(), "BUILDING", "BUILDING_WALLS")
    truthy(ok1, "设置建筑生产下发应成功：" .. tostring(err1))
    eq(ctx1.settlementKind, "SET_PRODUCTION", "settlementKind 应为 SET_PRODUCTION")
    truthy(CAB_Executor.IsSettlementBusy(ctx1), "队列切换落地前 IsSettlementBusy 应为 true")
    local r1Timeout = CAB_Executor.FinalizeActionSettlement(ctx1, 1500)
    falsy(r1Timeout.executed, "未落地超时兜底时 executed 应为 false")
    truthy(r1Timeout.timed_out, "未落地超时兜底时 timed_out 应为 true")
    notNil(r1Timeout.error_reason, "超时兜底应提供 error_reason")

    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctx1), "2 帧后城墙队列落地应不再忙碌")
    local r1 = CAB_Executor.FinalizeActionSettlement(ctx1, 105)
    truthy(r1.__is_object, "DTO 应带 __is_object = true")
    truthy(r1.executed, "executed 应为 true")
    falsy(r1.timed_out, "timed_out 应为 false")
    eq(r1.city_id, city:GetID(), "city_id 匹配")
    eq(r1.order_category, "BUILDING", "order_category 匹配")
    eq(r1.item_type, "BUILDING_WALLS", "item_type 匹配")
    eq(r1.order_queue_length, 1, "清空队列后长度为 1")
    eq(r1.turns_left, 5, "剩余回合数应为 5")
    truthy(w.writeLog[1].clearQueue, "默认 clearQueue 应为 true")

    -- 3. UNIT（整数 ID + clearQueue = false 追加队列）
    local ok2, err2, ctx2 = CAB_Executor.SetCityProduction(0, city:GetID(), "UNIT", uArcher, false)
    truthy(ok2, "追加单位训练下发应成功：" .. tostring(err2))
    truthy(CAB_Executor.IsSettlementBusy(ctx2), "队列长度未递增前 IsSettlementBusy 应为 true")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctx2), "追加落地后队列递增为 2 应不再忙碌")
    local r2 = CAB_Executor.FinalizeActionSettlement(ctx2, 100)
    truthy(r2.executed, "追加结算 executed 应为 true")
    eq(r2.order_category, "UNIT", "order_category 匹配")
    eq(r2.item_type, "UNIT_ARCHER", "整数 ID 应解析为 UNIT_ARCHER")
    eq(r2.order_queue_length, 2, "clearQueue=false 追加后队列长度应为 2")
    falsy(w.writeLog[2].clearQueue, "应向引擎透传 clearQueue=false")

    -- 4. PROJECT（clearQueue = true 清空重置）
    local ok3, err3, ctx3 = CAB_Executor.SetCityProduction(0, city:GetID(), "PROJECT", "PROJECT_APOLLO_PROGRAM", true)
    truthy(ok3, "设置项目生产下发应成功：" .. tostring(err3))
    w:tickSettlement(2)
    local r3 = CAB_Executor.FinalizeActionSettlement(ctx3, 100)
    truthy(r3.executed, "项目结算 executed 应为 true")
    eq(r3.order_category, "PROJECT", "order_category 匹配")
    eq(r3.item_type, "PROJECT_APOLLO_PROGRAM", "item_type 匹配")
    eq(r3.order_queue_length, 1, "清空队列后长度重归 1")

    -- 5. PROCESS（维持转化，turns_left = 0）
    local ok4, err4, ctx4 = CAB_Executor.SetCityProduction(0, city:GetID(), "PROCESS", "PROCESS_WEALTH")
    truthy(ok4, "设置财富转化下发应成功：" .. tostring(err4))
    w:tickSettlement(2)
    local r4 = CAB_Executor.FinalizeActionSettlement(ctx4, 100)
    truthy(r4.executed, "转化结算 executed 应为 true")
    eq(r4.order_category, "PROCESS", "order_category 匹配")
    eq(r4.item_type, "PROCESS_WEALTH", "item_type 匹配")
    eq(r4.turns_left, 0, "转化项目 turns_left 应为 0")
    eq(w:logCount("Events.SpecificCityInfoDirty"), 4, "4 次设生产均应触发 SpecificCityInfoDirty")
end)

test("T-28", "WP4 PurchaseCityPlot：实时 BUY_PLOTS_DISABLED、错误细分、UI 刷新与 WP3 短结算闭环", function()
    ensureModulesLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, plotBuyDelayTicks = 2, cityScreenUp = true })
    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        canBuyPlotAt = { ["6:5"] = true, ["6:6"] = true },
        canBuyPlotNow = { ["6:5"] = true, ["6:6"] = false },
        buyPlotCost = { ["6:5"] = 80, ["6:6"] = 900 },
    })
    local puppet = w:addCity({
        owner = 0, name = "Puppet", x = 10, y = 5, isPuppet = true,
        canBuyPlotAt = { ["11:5"] = true }, canBuyPlotNow = { ["11:5"] = true },
    })

    -- 1. E-06：BUY_PLOTS_DISABLED == 1 实时阻断，恢复为 0 后立刻生效
    S.resetGameDefines({ BUY_PLOTS_DISABLED = 1 })
    local okDis, errDis = CAB_Executor.PurchaseCityPlot(0, city:GetID(), 6, 5)
    falsy(okDis, "BUY_PLOTS_DISABLED=1 时必须拒绝买地")
    truthy(errDis:find("BUY_PLOTS_DISABLED", 1, true) ~= nil, "错误信息应指明 BUY_PLOTS_DISABLED")
    S.resetGameDefines({ BUY_PLOTS_DISABLED = 0 })

    -- 2. 受限城与双层 CanBuyPlotAt 错误细分（余额不足 vs 非合法范围），全程零写入
    falsy(CAB_Executor.PurchaseCityPlot(0, puppet:GetID(), 11, 5), "傀儡城禁止买地")

    local okPoor, errPoor = CAB_Executor.PurchaseCityPlot(0, city:GetID(), 6, 6)
    falsy(okPoor, "金币不足买地应拒绝")
    truthy(errPoor:find("Insufficient gold", 1, true) ~= nil, "应区分为金币不足：" .. tostring(errPoor))
    truthy(errPoor:find("900", 1, true) ~= nil, "应附带 GetBuyPlotCost 报价")

    local okOut, errOut = CAB_Executor.PurchaseCityPlot(0, city:GetID(), 15, 15)
    falsy(okOut, "超范围地块应拒绝")
    truthy(errOut:find("valid purchasable range", 1, true) ~= nil, "应区分为非本城合法可购范围：" .. tostring(errOut))
    eq(w:writeCount(), 0, "E-02：买地校验失败必须零写入")

    -- 3. 成功发包 + cityScreenUp=true 触发 UpdateCityScreen + WP3 BUY_PLOT 短结算全闭环
    local okBuy, errBuy, ctx = CAB_Executor.PurchaseCityPlot(0, city:GetID(), 6, 5)
    truthy(okBuy, "合法买地应成功：" .. tostring(errBuy))
    eq(ctx.settlementKind, "BUY_PLOT", "settlementKind 应为 BUY_PLOT")
    eq(ctx.cityID, city:GetID(), "cityID 匹配")
    eq(ctx.targetX, 6, "targetX 匹配")
    eq(ctx.targetY, 5, "targetY 匹配")
    eq(ctx.goldBefore, 500, "goldBefore 为 500")
    eq(ctx.expectedCost, 80, "expectedCost 为 80")
    eq(ctx.minWaitSec, CAB_Config.PLOT_BUY_SETTLE_SEC, "minWaitSec 对齐 CAB_Config.PLOT_BUY_SETTLE_SEC")
    eq(ctx.maxTimeoutSec, CAB_Config.MAX_SETTLE_TIMEOUT_SEC, "maxTimeoutSec 对齐 CAB_Config.MAX_SETTLE_TIMEOUT_SEC")
    eq(w:logCount("UpdateCityScreen"), 1, "城市界面开启时应调用 UI.UpdateCityScreen()")

    -- 联动 WP3 IsSettlementBusy -> tickSettlement -> FinalizeActionSettlement
    truthy(CAB_Executor.IsSettlementBusy(ctx), "归属翻转前 IsSettlementBusy 应为 true")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(ctx), "2 帧归属翻转后 IsSettlementBusy 应为 false")

    local settled = CAB_Executor.FinalizeActionSettlement(ctx, 110)
    truthy(settled.purchased, "D-04：归属翻转为己方后 purchased 应为 true")
    falsy(settled.timed_out, "timed_out 应为 false")
    isNil(settled.error_reason, "成功时省略 error_reason")
    eq(settled.cost_paid, 80, "实际扣费 80")
    eq(settled.gold_after, 420, "扣费后余 420 金币")
    eq(settled.new_owner_id, 0, "新归属为玩家 0")

    -- 4. cityScreenUp=false 时不应调用 UpdateCityScreen
    w.ui.cityScreenUp = false
    w:setCity(city, {
        canBuyPlotAt = { ["6:6"] = true },
        canBuyPlotNow = { ["6:6"] = true },
        buyPlotCost = { ["6:6"] = 100 },
    })
    local okBuy2, errBuy2 = CAB_Executor.PurchaseCityPlot(0, city:GetID(), 6, 6)
    truthy(okBuy2, "关闭城市界面时买地应成功：" .. tostring(errBuy2))
    eq(w:logCount("UpdateCityScreen"), 1, "城市界面关闭时不得多调 UI.UpdateCityScreen()")
end)

test("T-29", "WP4 ExecuteEndTurn：默认安全诊断拒绝与无阻塞提交 CONTROL_ENDTURN", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        turn = 42,
        players = {
            { id = 0, team = 0, civ = "Rome", blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION },
        },
    })
    local idleCity = w:addCity({ owner = 0, name = "Rome", x = 5, y = 5, orderQueueLength = 0 })

    -- 1. 默认 autoSkipReadyUnits=false 遇生产阻塞：安全拒绝，零写入，返回完整 blocking_info
    local okBlk, errBlk, dtoBlk = CAB_Executor.ExecuteEndTurn(0)
    falsy(okBlk, "存在生产阻塞时 ExecuteEndTurn 必须返回 false")
    truthy(errBlk:find("ENDTURN_BLOCKING_PRODUCTION", 1, true) ~= nil, "错误信息应包含阻塞类型名")
    truthy(dtoBlk.__is_object, "结果 DTO 应带 __is_object = true")
    falsy(dtoBlk.turn_ended, "turn_ended 应为 false")
    eq(dtoBlk.ended_turn_number, 42, "ended_turn_number 匹配当前回合 42")
    eq(dtoBlk.status, "BLOCKED", "status 应为 BLOCKED")
    eq(#dtoBlk.auto_skipped_unit_ids, 0, "未跳过任何单位")
    notNil(dtoBlk.blocking_info, "必须附带 blocking_info")
    eq(dtoBlk.blocking_info.blocking_type_name, "ENDTURN_BLOCKING_PRODUCTION", "阻塞名匹配")
    eq(dtoBlk.blocking_info.blocking_city_id, idleCity:GetID(), "应精确定位闲置城市 ID")
    falsy(w.endTurnRequested, "阻塞时严禁触发 CONTROL_ENDTURN")
    eq(w:writeCount(), 0, "阻塞拒绝零写入")

    -- 2. 无阻塞但 UI.CanEndTurn() == false 时同样安全拒绝
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE })
    w.ui.canEndTurn = false
    local okUiBlk, _, dtoUiBlk = CAB_Executor.ExecuteEndTurn(0, false)
    falsy(okUiBlk, "UI.CanEndTurn()=false 时应安全拒绝")
    eq(dtoUiBlk.status, "BLOCKED", "status 应为 BLOCKED")
    falsy(w.endTurnRequested, "严禁触发 CONTROL_ENDTURN")

    -- 3. 完全无阻塞时调用 CONTROL_ENDTURN 并立返 WAITING_NEXT_TURN
    w.ui.canEndTurn = true
    local okEnd, errEnd, dtoEnd = CAB_Executor.ExecuteEndTurn(0, false)
    truthy(okEnd, "无阻塞时 ExecuteEndTurn 应成功：" .. tostring(errEnd))
    isNil(errEnd, "成功时 errMsg 应为 nil")
    truthy(dtoEnd.__is_object, "结果 DTO 应带 __is_object = true")
    truthy(dtoEnd.turn_ended, "turn_ended 应为 true")
    eq(dtoEnd.ended_turn_number, 42, "ended_turn_number 匹配")
    eq(dtoEnd.status, "WAITING_NEXT_TURN", "status 应为 WAITING_NEXT_TURN")
    isNil(dtoEnd.blocking_info, "成功提交时应省略 blocking_info")
    truthy(w.endTurnRequested, "必须已调用 Game.DoControl(CONTROL_ENDTURN)")
    eq(w:writeCount("DoControl"), 1, "写日志应记录 1 次 DoControl")
end)

test("T-30", "WP4 ExecuteEndTurn D-05 守卫式自动跳过：硬阻塞零浪费、待命跳过并复查、保护晋升与叠栈及选区恢复", function()
    ensureModulesLoaded()

    -- 场景 A：硬阻塞（生产/科研）下即使 autoSkipReadyUnits=true，严禁浪费待命单位行动力
    local wA = S.newWorld({
        turn = 10,
        players = {
            { id = 0, team = 0, civ = "Rome", blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_RESEARCH },
        },
    })
    local readyWarrior = wA:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local okA, errA, dtoA = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okA, "科研硬阻塞下必须拒绝结束回合")
    truthy(errA:find("ENDTURN_BLOCKING_RESEARCH", 1, true) ~= nil, "应报告科研硬阻塞")
    eq(dtoA.status, "BLOCKED", "status 应为 BLOCKED")
    eq(#dtoA.auto_skipped_unit_ids, 0, "D-05：硬阻塞下绝不可跳过待命单位")
    truthy(readyWarrior:IsReadyToMove(), "D-05：待命单位必须保留行动机会")
    eq(wA:writeCount(), 0, "D-05：硬阻塞拦截必须零写入")

    -- 场景 B：待命单位类阻塞（含合法军民叠栈 + 城内空军叠栈）-> 全量跳过、恢复原选区并成功提交下一回合
    local wB = S.newWorld({
        turn = 11,
        players = {
            { id = 0, team = 0, civ = "Rome", blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS },
        },
    })
    local uCombat = wB:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        canHandleActions = { MISSION_SKIP = true },
    })
    local uCivilian = wB:addUnit({
        owner = 0, unitType = "UNIT_WORKER", x = 5, y = 5, -- 与 uCombat 军民合法叠栈
        canHandleActions = {}, -- 同步覆盖回退 PUSH_MISSION 路径
    })
    local uAir1 = wB:addUnit({ owner = 0, unitType = "UNIT_FIGHTER", x = 3, y = 5 })
    local uAir2 = wB:addUnit({ owner = 0, unitType = "UNIT_FIGHTER", x = 3, y = 5 }) -- 空军城内合法叠栈
    wB:select(uCombat)

    local okB, errB, dtoB = CAB_Executor.ExecuteEndTurn(0, true)
    truthy(okB, "全部待命单位可跳过时应自动跳过并结束回合：" .. tostring(errB))
    truthy(dtoB.turn_ended, "turn_ended 应为 true")
    eq(dtoB.status, "WAITING_NEXT_TURN", "status 应为 WAITING_NEXT_TURN")
    eq(#dtoB.auto_skipped_unit_ids, 4, "军民叠栈与空军叠栈共 4 个待命单位均应被跳过")
    falsy(uCombat:IsReadyToMove(), "勇士已跳过")
    falsy(uCivilian:IsReadyToMove(), "工人已跳过")
    falsy(uAir1:IsReadyToMove(), "空军 1 已跳过")
    falsy(uAir2:IsReadyToMove(), "空军 2 已跳过")
    eq(UI.GetHeadSelectedUnit(), uCombat, "E-02：自动跳过后必须无痕恢复原选中单位")
    truthy(wB.endTurnRequested, "复查无阻塞后应提交 CONTROL_ENDTURN")

    -- 场景 C：混合待命阻塞（普通待命 + 待晋升 + 同类非法叠栈）-> 仅跳过普通单位，保护晋升与叠栈，不结束回合
    local wC = S.newWorld({
        turn = 12,
        players = {
            { id = 0, team = 0, civ = "Rome", blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS },
        },
    })
    local normalUnit = wC:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 2, y = 2 })
    local promoUnit = wC:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 4, y = 2, promotionReady = true })
    local stack1 = wC:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 6, y = 2 })
    local stack2 = wC:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 6, y = 2 }) -- 与 stack1 同类非法叠栈
    wC:clearSelection()

    local okC, errC, dtoC = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okC, "剩余待晋升与非法叠栈单位时必须阻止结束回合")
    notNil(errC, "应返回阻塞错误信息")
    falsy(dtoC.turn_ended, "turn_ended 应为 false")
    eq(dtoC.status, "BLOCKED", "status 应为 BLOCKED")
    same(dtoC.auto_skipped_unit_ids, { normalUnit:GetID() }, "应仅跳过普通待命单位")
    falsy(normalUnit:IsReadyToMove(), "普通单位已跳过")
    truthy(promoUnit:IsReadyToMove(), "D-05：待晋升单位绝不可被自动跳过")
    truthy(stack1:IsReadyToMove(), "D-05：同类非法叠栈单位 1 绝不可被自动跳过")
    truthy(stack2:IsReadyToMove(), "D-05：同类非法叠栈单位 2 绝不可被自动跳过")
    isNil(UI.GetHeadSelectedUnit(), "E-02：原无选区时必须清空恢复为空选区")
    falsy(wC.endTurnRequested, "仍有阻塞严禁调用 CONTROL_ENDTURN")
end)

test("T-31", "WP4 E-01/E-02 写门控与全量非法入参防御：4 接口非活动回合/消息忙/越权/坏参数零写入零异常", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome", turnActive = false, gold = 500, faith = 300 },
            { id = 1, team = 1, civ = "Carthage", turnActive = true, gold = 500 },
        },
    })
    local myCity = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5,
        purchasable = { buildings = { [GameInfoTypes.BUILDING_GRANARY] = { gold = true } }, units = {} },
        affordable = { buildings = { [GameInfoTypes.BUILDING_GRANARY] = { gold = true } }, units = {} },
        canBuyPlotAt = { ["6:5"] = true }, canBuyPlotNow = { ["6:5"] = true },
    })
    local enemyCity = w:addCity({ id = 99, owner = 1, name = "Carthage", x = 10, y = 5 })
    local guardUnit = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    w:select(guardUnit)

    -- 1. 非活动回合：4 接口全部拦截且 ExecuteEndTurn 第 3 返回值为 nil
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", "BUILDING_GRANARY", "GOLD"), "非活动回合禁买项")
    falsy(CAB_Executor.SetCityProduction(0, myCity:GetID(), "BUILDING", "BUILDING_GRANARY"), "非活动回合禁设产")
    falsy(CAB_Executor.PurchaseCityPlot(0, myCity:GetID(), 6, 5), "非活动回合禁买地")
    local okEt1, errEt1, dtoEt1 = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okEt1, "非活动回合禁结束回合")
    notNil(errEt1, "应返回非活动回合错误")
    isNil(dtoEt1, "门控失败 ExecuteEndTurn 第 3 返回值应为 nil")

    -- 2. 消息队列忙：4 接口全部拦截
    w:setPlayer(0, { turnActive = true })
    w.processingMessages = true
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", "BUILDING_GRANARY", "GOLD"), "消息忙禁买项")
    falsy(CAB_Executor.SetCityProduction(0, myCity:GetID(), "BUILDING", "BUILDING_GRANARY"), "消息忙禁设产")
    falsy(CAB_Executor.PurchaseCityPlot(0, myCity:GetID(), 6, 5), "消息忙禁买地")
    local okEt2, _, dtoEt2 = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okEt2, "消息忙禁结束回合")
    isNil(dtoEt2, "消息忙门控失败第 3 返回值应为 nil")
    w.processingMessages = false

    -- 3. 全量非法入参 / 越权访问（零未捕获 Lua 异常）
    falsy(CAB_Executor.PurchaseCityItem("bad", myCity:GetID(), "BUILDING", "BUILDING_GRANARY"), "坏玩家 ID")
    falsy(CAB_Executor.PurchaseCityItem(0, 1.5, "BUILDING", "BUILDING_GRANARY"), "小数城市 ID")
    falsy(CAB_Executor.PurchaseCityItem(0, enemyCity:GetID(), "BUILDING", "BUILDING_GRANARY"), "越权敌城")
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "WONDER", "BUILDING_GRANARY"), "非法 itemCategory")
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", "BUILDING_GRANARY", "CULTURE"), "非法货币类型")
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", nil), "nil itemKeyOrId")
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", -1), "负整数 itemKeyOrId")
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", 9999), "越界整数 itemKeyOrId")
    falsy(CAB_Executor.PurchaseCityItem(0, myCity:GetID(), "BUILDING", "BUILDING_NO_SUCH"), "未知建筑 Type")

    falsy(CAB_Executor.SetCityProduction(0, nil, "BUILDING", "BUILDING_GRANARY"), "nil 城市 ID")
    falsy(CAB_Executor.SetCityProduction(0, enemyCity:GetID(), "BUILDING", "BUILDING_GRANARY"), "越权敌城设产")
    falsy(CAB_Executor.SetCityProduction(0, myCity:GetID(), "INVALID_CAT", "BUILDING_GRANARY"), "非法 orderCategory")
    falsy(CAB_Executor.SetCityProduction(0, myCity:GetID(), "BUILDING", ""), "空串 itemKeyOrId")

    falsy(CAB_Executor.PurchaseCityPlot(0, enemyCity:GetID(), 6, 5), "越权敌城买地")
    falsy(CAB_Executor.PurchaseCityPlot(0, myCity:GetID(), 6.5, 5), "小数坐标买地")
    falsy(CAB_Executor.PurchaseCityPlot(0, myCity:GetID(), 999, 5), "越界坐标买地")

    local okBadP, _, dtoBadP = CAB_Executor.ExecuteEndTurn(-1, true)
    falsy(okBadP, "负玩家 ID 结束回合拒绝")
    isNil(dtoBadP, "非法玩家第 3 返回值应为 nil")

    eq(w:writeCount(), 0, "E-01/E-02：全部门控与非法入参拦截必须保持写调用 = 0")
    eq(UI.GetHeadSelectedUnit(), guardUnit, "E-02：拦截期间不得改变原 UI 选区")
end)

test("T-32", "WP4 E-06 IGE 动态变阵与零缓存联调：即时注金、清生产阻塞与延迟死亡幽灵单位过滤", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        turn = 25,
        plotBuyDelayTicks = 1,
        cityActionDelayTicks = 1,
        players = {
            { id = 0, team = 0, civ = "Rome", gold = 50, blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION },
        },
    })
    local bGranary = GameInfoTypes.BUILDING_GRANARY
    local city = w:addCity({
        owner = 0, name = "Rome", x = 5, y = 5, orderQueueLength = 0,
        purchasable = { buildings = { [bGranary] = { gold = true } }, units = {} },
        affordable = { buildings = { [bGranary] = { gold = false } }, units = {} },
        costs = { bldGold = { [bGranary] = 200 } },
        canBuyPlotAt = { ["6:5"] = true },
        canBuyPlotNow = { ["6:5"] = false },
        buyPlotCost = { ["6:5"] = 90 },
    })

    -- 1. 初始金币不足：买建筑与买地均被拦截
    falsy(CAB_Executor.PurchaseCityItem(0, city:GetID(), "BUILDING", "BUILDING_GRANARY", "GOLD"), "初始金币不足应拒绝买建筑")
    falsy(CAB_Executor.PurchaseCityPlot(0, city:GetID(), 6, 5), "初始金币不足应拒绝买地")

    -- 2. 模拟 IGE 中途直接修改国库金币并更新可购态 -> 无需重启立即成交（E-06 零缓存）
    w:setPlayer(0, { gold = 1000 })
    w:setCity(city, {
        affordable = { buildings = { [bGranary] = { gold = true } }, units = {} },
        canBuyPlotNow = { ["6:5"] = true },
    })
    local okBld, errBld, ctxBld = CAB_Executor.PurchaseCityItem(0, city:GetID(), "BUILDING", "BUILDING_GRANARY", "GOLD")
    truthy(okBld, "IGE 注金后买建筑下发应立即成功：" .. tostring(errBld))
    w:tickSettlement(1)
    local resBld = CAB_Executor.FinalizeActionSettlement(ctxBld, 100)
    truthy(resBld.purchased, "买建筑结算成功")
    eq(resBld.gold_after, 800, "买建筑后余 800 金币")

    local okPlot, errPlot, ctxPlot = CAB_Executor.PurchaseCityPlot(0, city:GetID(), 6, 5)
    truthy(okPlot, "IGE 注金后买地应立即成功：" .. tostring(errPlot))
    w:tickSettlement(1)
    local resPlot = CAB_Executor.FinalizeActionSettlement(ctxPlot, 100)
    truthy(resPlot.purchased, "买地结算成功")
    eq(resPlot.gold_after, 710, "买地后余 710 金币")

    -- 3. 设生产 + IGE 清除阻塞，同时放 1 个延迟死亡（delayedDeath=true）幽灵单位，验证 ExecuteEndTurn 安全过滤
    local okProd, errProd, ctxProd = CAB_Executor.SetCityProduction(0, city:GetID(), "BUILDING", "BUILDING_WALLS")
    truthy(okProd, "设生产下发应成功：" .. tostring(errProd))
    w:tickSettlement(1)
    local resProd = CAB_Executor.FinalizeActionSettlement(ctxProd, 100)
    truthy(resProd.executed, "设生产结算成功")
    local ghostUnit = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 4, y = 5, delayedDeath = true, readyToMove = true })
    local liveUnit = w:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 5, y = 5, readyToMove = true })
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS })

    -- ExecuteEndTurn(0, true) 必须跳过存活 liveUnit，绝不触碰 delayedDeath 幽灵单位
    local _, _, dtoEt = CAB_Executor.ExecuteEndTurn(0, true)
    same(dtoEt.auto_skipped_unit_ids, { liveUnit:GetID() }, "E-06：必须跳过存活单位且绝不把 delayedDeath 幽灵单位纳入跳过列表")
    truthy(ghostUnit:IsDelayedDeath(), "幽灵单位未被误操作")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "E-03：全程零迷雾违禁探测")
end)

-- -----------------------------------------------------------------------------
-- 第 6.5 节：WP5 三大回合硬阻塞安全写动作与跨帧异步结算用例（T-33 ~ T-37）
-- -----------------------------------------------------------------------------

test("T-33", "WP5 SetResearchTech：常规/免费科技、跨帧结算、超时兜底与前置拦截", function()
    ensureModulesLoaded()
    -- 1. 常规科研跨帧异步结算（cityActionDelayTicks = 2）
    local w = S.newWorld({
        cityActionDelayTicks = 2,
        teams = { { id = 0, techs = { [0] = true } } },
        players = {
            {
                id = 0, team = 0, science = 10,
                canResearch = { [1] = true, [2] = true },
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_RESEARCH,
            },
        },
    })

    -- 前置失败：未知科技、已研究科技、前置未满
    local okBad, _, baseBad = CAB_Executor.SetResearchTech(0, "TECH_NONEXISTENT")
    falsy(okBad, "未知科技应失败")
    isNil(baseBad, "失败无基线")
    local okOwned = CAB_Executor.SetResearchTech(0, "TECH_AGRICULTURE")
    falsy(okOwned, "已研究非 Repeat 科技应失败")
    local okPrereq = CAB_Executor.SetResearchTech(0, "TECH_WRITING")
    falsy(okPrereq, "前置未满科技应失败")
    eq(w:writeCount(), 0, "E-02：前置失败零写入")

    -- 正常选择 TECH_POTTERY
    local okSet, errSet, base = CAB_Executor.SetResearchTech(0, "TECH_POTTERY")
    truthy(okSet, "选择 TECH_POTTERY 应成功：" .. tostring(errSet))
    eq(base.settlementKind, "SET_RESEARCH", "settlementKind 应为 SET_RESEARCH")
    eq(base.minWaitSec, CAB_Config.PLOT_BUY_SETTLE_SEC, "应采用 0.10s 短结算等待")
    eq(w:writeCount("SendResearch"), 1, "应调用 1 次 Network.SendResearch")
    truthy(CAB_Executor.IsSettlementBusy(base), "消息队列未落地前应保持忙碌")

    -- 超时兜底测试（未 tick 直接 Finalize）
    local dtoTimeout = CAB_Executor.FinalizeActionSettlement(base, 1500)
    falsy(dtoTimeout.executed, "未落地超时应返回 executed=false")
    truthy(dtoTimeout.timed_out, "应标记 timed_out=true")
    notNil(dtoTimeout.error_reason, "应附带超时错误说明")

    -- 推进 2 帧后落地
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(base), "2 帧落地后应不再忙碌")
    local dtoDone = CAB_Executor.FinalizeActionSettlement(base, 110)
    truthy(dtoDone.executed, "落地后应返回 executed=true")
    falsy(dtoDone.timed_out, "落地后 timed_out=false")
    eq(dtoDone.current_research_type, "TECH_POTTERY", "应回读到 TECH_POTTERY")
    eq(Players[0]:GetEndTurnBlockingType(), EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE, "科研阻塞应已解除")

    -- 2. 免费科技模式（ENDTURN_BLOCKING_FREE_TECH）
    local wFree = S.newWorld({
        cityActionDelayTicks = 1,
        teams = { { id = 0, techs = { [0] = true } } },
        players = {
            {
                id = 0, team = 0, science = 10, freeTechs = 1,
                canResearch = { [1] = true, [2] = true },
                canResearchForFree = { [1] = true },
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_FREE_TECH,
            },
        },
    })
    falsy(CAB_Executor.SetResearchTech(0, "TECH_ANIMAL_HUSBANDRY"), "未通过 CanResearchForFree 的科技应被拦截")
    local okFree, errFree, baseFree = CAB_Executor.SetResearchTech(0, 1) -- 支持整数 ID
    truthy(okFree, "免费科技应支持整数 ID 并成功：" .. tostring(errFree))
    truthy(baseFree.isFreeTech, "应标记 isFreeTech=true")
    truthy(CAB_Executor.IsSettlementBusy(baseFree), "落地前忙碌")
    wFree:tickSettlement(1)
    falsy(CAB_Executor.IsSettlementBusy(baseFree), "免费科技落地后解除忙碌")
    local dtoFree = CAB_Executor.FinalizeActionSettlement(baseFree, 100)
    truthy(dtoFree.executed, "免费科技应 executed=true")
    eq(dtoFree.free_techs_before, 1, "free_techs_before=1")
    eq(dtoFree.free_techs_after, 0, "free_techs_after=0")
    truthy(Teams[0]:GetTeamTechs():HasTech(1), "队伍应已掌握该免费科技")
end)

test("T-34", "WP5 AdoptPolicyOrBranch：分支开启、政策/信条采纳、错误细分与跨帧结算", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        cityActionDelayTicks = 2,
        teams = { { id = 0, currentEra = 0 } },
        players = {
            {
                id = 0, team = 0, culture = 30, nextPolicyCost = 25,
                canAdoptPolicy = { [1] = true }, -- POLICY_ARISTOCRACY
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_POLICY,
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
    })

    -- 拦截非法操作（意识形态分支、时代未达分支、自动开门政策、前置未满政策）
    local okIdeo, errIdeo = CAB_Executor.AdoptPolicyOrBranch(0, "BRANCH", "POLICY_BRANCH_FREEDOM")
    falsy(okIdeo, "应拦截 PurchaseByLevel 意识形态分支")
    truthy(errIdeo:find("SendIdeologyChoice", 1, true) ~= nil, "应提示需走 SendIdeologyChoice")

    local okEra, errEra = CAB_Executor.AdoptPolicyOrBranch(0, "BRANCH", "POLICY_BRANCH_RATIONALISM")
    falsy(okEra, "应拦截时代未达的理性主义分支")
    truthy(errEra:find("ERA_RENAISSANCE", 1, true) ~= nil, "应细分提示缺少时代前置")

    falsy(CAB_Executor.AdoptPolicyOrBranch(0, "POLICY", "POLICY_TRADITION"), "应拦截 PolicyBranchType==nil 自动开门政策")
    falsy(CAB_Executor.AdoptPolicyOrBranch(0, "POLICY", "POLICY_REPUBLIC"), "应拦截前置未满政策")
    eq(w:writeCount(), 0, "E-02：前置失败零写入")

    -- 1. 开启常规分支 POLICY_BRANCH_TRADITION（跨帧结算）
    local okBr, errBr, baseBr = CAB_Executor.AdoptPolicyOrBranch(0, "BRANCH", "POLICY_BRANCH_TRADITION")
    truthy(okBr, "开启传统分支应成功：" .. tostring(errBr))
    eq(baseBr.settlementKind, "ADOPT_POLICY", "settlementKind=ADOPT_POLICY")
    eq(w:writeCount("SendUpdatePolicies"), 1, "应调用 1 次 Network.SendUpdatePolicies")
    truthy(CAB_Executor.IsSettlementBusy(baseBr), "落地前忙碌")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(baseBr), "落地后解除忙碌")
    local dtoBr = CAB_Executor.FinalizeActionSettlement(baseBr, 105)
    truthy(dtoBr.adopted, "分支应 adopted=true")
    eq(dtoBr.culture_before, 30, "文化扣前 30")
    eq(dtoBr.culture_after, 5, "文化扣后 5")
    eq(dtoBr.next_policy_cost_after, 45, "下次政策花费应上涨至 45")

    -- 2. 文化不足细分报错（需 45，仅剩 5）
    local okPoor, errPoor = CAB_Executor.AdoptPolicyOrBranch(0, "POLICY", "POLICY_ARISTOCRACY")
    falsy(okPoor, "文化不足应拦截")
    truthy(errPoor:find("Insufficient culture", 1, true) ~= nil, "应细分提示文化不足")

    -- 3. 补足免费政策后采纳 POLICY_ARISTOCRACY
    w:setPlayer(0, { freePolicies = 1, blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_FREE_POLICY })
    local okPol, errPol, basePol = CAB_Executor.AdoptPolicyOrBranch(0, "POLICY", "POLICY_ARISTOCRACY")
    truthy(okPol, "免费政策采纳贵族应成功：" .. tostring(errPol))
    w:tickSettlement(2)
    local dtoPol = CAB_Executor.FinalizeActionSettlement(basePol, 100)
    truthy(dtoPol.adopted, "政策采纳应 adopted=true")
    eq(dtoPol.free_policies_before, 1, "free_policies_before=1")
    eq(dtoPol.free_policies_after, 0, "free_policies_after=0")
    truthy(Players[0]:HasPolicy(1), "玩家应已拥有 POLICY_ARISTOCRACY")

    -- 4. 意识形态信条采纳
    w:setPlayer(0, {
        ideologyBranch = 5,
        freeTenets = 1,
        availableTenets = { [1] = { 5 } },
    })
    local okTen, errTen, baseTen = CAB_Executor.AdoptPolicyOrBranch(0, "POLICY", "POLICY_AVANT_GARDE")
    truthy(okTen, "采纳 1 级自由信条应成功：" .. tostring(errTen))
    w:tickSettlement(2)
    local dtoTen = CAB_Executor.FinalizeActionSettlement(baseTen, 100)
    truthy(dtoTen.adopted, "意识形态信条应 adopted=true")
end)

test("T-35", "WP5 PromoteUnit：常规晋升、InstaHeal、选区无痕恢复与跨帧结算", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        cityActionDelayTicks = 2,
        players = TWO_PLAYERS,
    })
    local prevSelected = w:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 4, y = 5 })
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        damage = 40, level = 1, promotionReady = true,
        availablePromotions = { [0] = true, [3] = true }, -- SHOCK_1 + INSTA_HEAL
    })
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_PROMOTION })
    w:select(prevSelected)

    -- 非法晋升前置拦截（零写入、选区不变）
    falsy(CAB_Executor.PromoteUnit(0, warrior:GetID(), "PROMOTION_EMBARKATION"), "CannotBeChosen 应拦截")
    falsy(CAB_Executor.PromoteUnit(0, warrior:GetID(), "PROMOTION_DRILL_1"), "不可获取晋升应拦截")
    eq(w:writeCount(), 0, "E-02：失败零写入")
    eq(UI.GetHeadSelectedUnit(), prevSelected, "E-02：失败后原 UI 选区不得改变")

    -- 1. 常规永久晋升 PROMOTION_SHOCK_1
    local okP1, errP1, baseP1 = CAB_Executor.PromoteUnit(0, warrior:GetID(), "PROMOTION_SHOCK_1")
    truthy(okP1, "晋升 PROMOTION_SHOCK_1 应成功：" .. tostring(errP1))
    eq(baseP1.settlementKind, "PROMOTE_UNIT", "settlementKind=PROMOTE_UNIT")
    eq(UI.GetHeadSelectedUnit(), prevSelected, "E-02：PromoteUnit 下发后必须无条件恢复原 UI 选区")
    truthy(CAB_Executor.IsSettlementBusy(baseP1), "落地前保持忙碌")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(baseP1), "2 帧后晋升落地")
    local dtoP1 = CAB_Executor.FinalizeActionSettlement(baseP1, 105)
    truthy(dtoP1.promoted, "应返回 promoted=true")
    eq(dtoP1.level_before, 1, "level_before=1")
    eq(dtoP1.level_after, 2, "level_after=2")
    falsy(dtoP1.is_promotion_ready_after, "晋升后 is_promotion_ready_after=false")
    truthy(warrior:IsHasPromotion(0), "单位应已持有 PROMOTION_SHOCK_1")
    eq(Players[0]:GetEndTurnBlockingType(), EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE, "晋升阻塞应已解除")

    -- 2. InstaHeal 立即回血晋升（不驻留 IsHasPromotion，靠等级/HP 恢复判定）
    w:setUnit(warrior, { promotionReady = true, damage = 45, availablePromotions = { [3] = true } })
    local okHeal, errHeal, baseHeal = CAB_Executor.PromoteUnit(0, warrior:GetID(), "PROMOTION_INSTA_HEAL")
    truthy(okHeal, "伤血单位 InstaHeal 应成功：" .. tostring(errHeal))
    truthy(baseHeal.isInstaHeal, "应标记 isInstaHeal=true")
    eq(UI.GetHeadSelectedUnit(), prevSelected, "InstaHeal 后原选区同样保持不变")
    w:tickSettlement(2)
    falsy(CAB_Executor.IsSettlementBusy(baseHeal), "InstaHeal 落地后应解除忙碌")
    local dtoHeal = CAB_Executor.FinalizeActionSettlement(baseHeal, 100)
    truthy(dtoHeal.promoted, "InstaHeal 应返回 promoted=true")
    eq(dtoHeal.level_after, 3, "等级升至 3")
    eq(dtoHeal.unit_after.hp, 100, "InstaHeal 应回复至满血 100 HP")
end)

test("T-36", "WP5 E-01/E-02 写门控与异常入参防御：三新接口非活动回合/消息忙零写入", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, turnActive = false, culture = 50, canResearch = { [1] = true } },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5 } },
    })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5, promotionReady = true, availablePromotions = { [0] = true } })

    -- AI 非活动回合全部拦截
    falsy(CAB_Executor.SetResearchTech(0, "TECH_POTTERY"), "非活动回合 SetResearchTech 拦截")
    falsy(CAB_Executor.AdoptPolicyOrBranch(0, "BRANCH", "POLICY_BRANCH_TRADITION"), "非活动回合 AdoptPolicyOrBranch 拦截")
    falsy(CAB_Executor.PromoteUnit(0, u:GetID(), "PROMOTION_SHOCK_1"), "非活动回合 PromoteUnit 拦截")

    -- 消息队列忙全部拦截
    w:setPlayer(0, { turnActive = true })
    w.processingMessages = true
    falsy(CAB_Executor.SetResearchTech(0, "TECH_POTTERY"), "消息忙 SetResearchTech 拦截")
    falsy(CAB_Executor.AdoptPolicyOrBranch(0, "BRANCH", "POLICY_BRANCH_TRADITION"), "消息忙 AdoptPolicyOrBranch 拦截")
    falsy(CAB_Executor.PromoteUnit(0, u:GetID(), "PROMOTION_SHOCK_1"), "消息忙 PromoteUnit 拦截")
    eq(w:writeCount(), 0, "E-01：门控拦截期间引擎写计数必须为 0")
end)

test("T-37", "WP5 端到端闭环：纯接口依次解除科研/政策/晋升三大硬阻塞后 ExecuteEndTurn 成功", function()
    ensureModulesLoaded()
    local w = S.newWorld({
        players = {
            {
                id = 0, team = 0, science = 8, culture = 30, nextPolicyCost = 25,
                canResearch = { [1] = true },
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_RESEARCH,
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true, orderQueueLength = 1 } },
    })
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        moves = 0, readyToMove = false, promotionReady = true,
        availablePromotions = { [0] = true },
    })

    -- 1. 科研阻塞期间 ExecuteEndTurn 应拒返 BLOCKED
    local okEt1, _, dtoEt1 = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okEt1, "科研阻塞期间不得结束回合")
    eq(dtoEt1.blocking_info.blocking_type_name, "ENDTURN_BLOCKING_RESEARCH", "诊断为科研阻塞")
    local okR, _, bR = CAB_Executor.SetResearchTech(0, "TECH_POTTERY")
    truthy(okR and CAB_Executor.FinalizeActionSettlement(bR, 100).executed, "科研设置成功")

    -- 2. 切至政策阻塞并解除
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_POLICY })
    local okEt2, _, dtoEt2 = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okEt2, "政策阻塞期间不得结束回合")
    eq(dtoEt2.blocking_info.blocking_type_name, "ENDTURN_BLOCKING_POLICY", "诊断为政策阻塞")
    local okP, _, bP = CAB_Executor.AdoptPolicyOrBranch(0, "BRANCH", "POLICY_BRANCH_TRADITION")
    truthy(okP and CAB_Executor.FinalizeActionSettlement(bP, 100).adopted, "政策分支开启成功")

    -- 3. 切至单位晋升阻塞并解除
    w:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_PROMOTION })
    local okEt3, _, dtoEt3 = CAB_Executor.ExecuteEndTurn(0, true)
    falsy(okEt3, "晋升阻塞期间不得结束回合")
    eq(dtoEt3.blocking_info.blocking_type_name, "ENDTURN_BLOCKING_UNIT_PROMOTION", "诊断为晋升阻塞")
    local okU, _, bU = CAB_Executor.PromoteUnit(0, u:GetID(), "PROMOTION_SHOCK_1")
    truthy(okU and CAB_Executor.FinalizeActionSettlement(bU, 100).promoted, "单位晋升成功")

    -- 4. 三大硬阻塞均已解除，ExecuteEndTurn 成功提交 CONTROL_ENDTURN
    local okEt4, _, dtoEt4 = CAB_Executor.ExecuteEndTurn(0, false)
    truthy(okEt4, "全部硬阻塞解除后 ExecuteEndTurn 应成功")
    truthy(dtoEt4.turn_ended, "turn_ended=true")
    truthy(w.endTurnRequested, "应提交 CONTROL_ENDTURN")
end)

-- -----------------------------------------------------------------------------
-- 第 7 节：运行器与收尾总检（FW-01）
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
