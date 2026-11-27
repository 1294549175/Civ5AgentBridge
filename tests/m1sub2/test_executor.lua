-- =============================================================================
-- 文件：tests/m1sub2/test_executor.lua
-- 职责：M1Sub2（mod/Lua/CAB_TaskExecutor.lua）离线有状态引擎桩验收测试集。
-- 依赖：由 tests/run_m1sub2_tests.py 在加载 tests/m1sub2/engine_stubs.lua 后执行。
-- 对外契约：返回汇总表 { passed, failed, skipped, guardViolations, guardMissing,
--           totalWrites, cases = {...} }。
--
-- 结构划分（对齐《docs/M1/M1Sub2/M1Sub2工作计划.md》WP1 ~ WP4）：
--   第 1 节  用例注册与断言工具库；
--   第 2 节  WP1 静态红线、加载洁净与 Initialize 契约用例（T-00）；
--   第 3 节  WP1 真实跨模块联调与有状态引擎桩自检用例（T-01 ~ T-08）；
--   第 4 节  运行器与收尾总检（FW-01）。
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
    isType(CAB_Executor.Initialize, "function", "应导出 CAB_Executor.Initialize 函数")

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
-- 第 4 节：运行器与收尾总检（FW-01）
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
