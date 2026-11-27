-- =============================================================================
-- 文件：tests/m1sub2/engine_stubs.lua
-- 职责：为 M1Sub2（mod/Lua/CAB_TaskExecutor.lua）离线验收提供独立的有状态《文明5：BNW
--       v1.0.3.279》Lua 5.1 引擎桩、真实跨模块联调底座（同时支持真实 CAB_Config.lua +
--       CAB_InfoCollector.lua + CAB_TaskExecutor.lua）、写操作状态演进与红线审计守卫。
-- 依赖：由 tests/run_m1sub2_tests.py 在 lupa.lua51 中加载，依赖 Python 注入的 __py_read_file。
-- 对外契约：
--   * 导出唯一测试框架全局表 CAB_TEST_STUBS（以及模拟 Civ5 引擎的全局符号）；
--   * 零修改 tests/m1sub1/*，完全独立维护；
--   * 不包含任何 AirRaidCore / AR_ExecuteStrike / AR_EnumerateTargets 模拟逻辑。
--
-- 核心能力（对齐《docs/M1/M1Sub2/M1Sub2工作计划.md》决策 D-06 与红线 E-01~E-06）：
--   1. 100% 兼容已验收的 CAB_InfoCollector.lua 全部只读引擎调用；
--   2. 有状态写操作模拟：
--        * 单位移动/揭盲/近战（Game.SelectionListMove）
--        * 单位远程/空袭/跳过/驻扎/治疗任务（Game.SelectionListGameNetMessage / Game.HandleAction）
--        * 城防远程炮击（UI.SelectCity + Game.SelectedCitiesGameNetMessage）
--        * 显式宣战与和约限制（Team:CanDeclareWar / Team:DeclareWar）
--        * 城市购买建筑/单位与设生产队列（Game.CityPurchaseBuilding / CityPurchaseUnit / CityPushOrder）
--        * 购买地块短延迟异步翻转（Network.SendCityBuyPlot + w:tickSettlement）
--        * 安全结束回合（Game.DoControl(CONTROL_ENDTURN)）
--   3. 红线陷阱与调用审计：
--        * 陷阱：Unit:CanMoveOrAttackInto、UI.SetInterfaceMode、SetScriptData；
--        * 审计：w.writeLog / w:writeCount() / w:queriesOnForbiddenFog(names)。
-- =============================================================================

local S = {}
CAB_TEST_STUBS = S

-- -----------------------------------------------------------------------------
-- 第 1 节：BNW 枚举常量、GameDefines 与默认 GameInfo 行模板
-- -----------------------------------------------------------------------------

local ENDTURN_BLOCKING_NAMES = {
    "ENDTURN_BLOCKING_UNITS",
    "ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS",
    "ENDTURN_BLOCKING_UNIT_PROMOTION",
    "ENDTURN_BLOCKING_STACKED_UNITS",
    "ENDTURN_BLOCKING_RESEARCH",
    "ENDTURN_BLOCKING_FREE_TECH",
    "ENDTURN_BLOCKING_PRODUCTION",
    "ENDTURN_BLOCKING_POLICY",
    "ENDTURN_BLOCKING_FREE_POLICY",
    "ENDTURN_BLOCKING_DIPLO_VOTE",
    "ENDTURN_BLOCKING_MINOR_QUEST",
    "ENDTURN_BLOCKING_CITY_RANGE_ATTACK",
    "ENDTURN_BLOCKING_FOUND_PANTHEON",
    "ENDTURN_BLOCKING_FOUND_RELIGION",
    "ENDTURN_BLOCKING_ENHANCE_RELIGION",
    "ENDTURN_BLOCKING_ADD_REFORMATION_BELIEF",
    "ENDTURN_BLOCKING_FAITH_GREAT_PERSON",
    "ENDTURN_BLOCKING_STEAL_TECH",
    "ENDTURN_BLOCKING_MAYA_LONG_COUNT",
    "ENDTURN_BLOCKING_FREE_ITEMS",
    "ENDTURN_BLOCKING_LEAGUE_CALL_FOR_PROPOSALS",
    "ENDTURN_BLOCKING_LEAGUE_CALL_FOR_VOTES",
    "ENDTURN_BLOCKING_CHOOSE_ARCHAEOLOGY",
    "ENDTURN_BLOCKING_CHOOSE_IDEOLOGY",
}

local ENUMS = {
    DomainTypes = {
        DOMAIN_LAND = 0,
        DOMAIN_SEA = 1,
        DOMAIN_AIR = 2,
        DOMAIN_HOVER = 3,
        DOMAIN_IMMOBILE = 4,
        NO_DOMAIN = -1,
    },
    YieldTypes = {
        YIELD_FOOD = 0,
        YIELD_PRODUCTION = 1,
        YIELD_GOLD = 2,
        YIELD_SCIENCE = 3,
        YIELD_CULTURE = 4,
        YIELD_FAITH = 5,
        NO_YIELD = -1,
    },
    ResourceUsageTypes = {
        RESOURCEUSAGE_LUXURY = 0,
        RESOURCEUSAGE_STRATEGIC = 1,
        RESOURCEUSAGE_BONUS = 2,
    },
    InterfaceModeTypes = {
        INTERFACEMODE_SELECTION = 0,
        INTERFACEMODE_MOVE_TO = 1,
        INTERFACEMODE_RANGE_ATTACK = 2,
        INTERFACEMODE_AIRSTRIKE = 3,
        INTERFACEMODE_CITY_RANGE_ATTACK = 4,
        INTERFACEMODE_PURCHASE_PLOT = 5,
    },
    EndTurnBlockingTypes = {
        NO_ENDTURN_BLOCKING_TYPE = -1,
    },
    GameMessageTypes = {
        GAMEMESSAGE_PUSH_MISSION = 0,
        GAMEMESSAGE_DO_TASK = 1,
    },
    MissionTypes = {
        MISSION_MOVE_TO = 0,
        MISSION_RANGE_ATTACK = 1,
        MISSION_FORTIFY = 2,
        MISSION_ALERT = 3,
        MISSION_SLEEP = 4,
        MISSION_HEAL = 5,
        MISSION_SKIP = 6,
        MISSION_SET_UP_FOR_RANGED_ATTACK = 7,
    },
    TaskTypes = {
        TASK_RANGED_ATTACK = 0,
    },
    OrderTypes = {
        ORDER_TRAIN = 0,
        ORDER_CONSTRUCT = 1,
        ORDER_CREATE = 2,
        ORDER_MAINTAIN = 3,
    },
    CityUpdateTypes = {
        CITY_UPDATE_TYPE_PRODUCTION = 0,
        CITY_UPDATE_TYPE_BANNER = 1,
        CITY_UPDATE_TYPE_PURCHASE = 2,
    },
    ControlTypes = {
        CONTROL_ENDTURN = 0,
    },
}

for i, name in ipairs(ENDTURN_BLOCKING_NAMES) do
    ENUMS.EndTurnBlockingTypes[name] = i - 1
end

local GAME_DEFINES_DEFAULT = {
    MOVE_DENOMINATOR = 60,
    MAX_HIT_POINTS = 100,
    MAX_CITY_HIT_POINTS = 200,
    CITY_ATTACK_RANGE = 2,
    BUY_PLOTS_DISABLED = 0,
    MAX_MAJOR_CIVS = 22,
    MAX_CIV_PLAYERS = 63,
    MAX_PLAYERS = 64,
}

local DEFAULT_INFO_ROWS = {
    Terrains = {
        { Type = "TERRAIN_GRASS",    Description = "TXT_KEY_TERRAIN_GRASS" },
        { Type = "TERRAIN_PLAINS",   Description = "TXT_KEY_TERRAIN_PLAINS" },
        { Type = "TERRAIN_DESERT",   Description = "TXT_KEY_TERRAIN_DESERT" },
        { Type = "TERRAIN_TUNDRA",   Description = "TXT_KEY_TERRAIN_TUNDRA" },
        { Type = "TERRAIN_SNOW",     Description = "TXT_KEY_TERRAIN_SNOW" },
        { Type = "TERRAIN_COAST",    Description = "TXT_KEY_TERRAIN_COAST",    water = true },
        { Type = "TERRAIN_OCEAN",    Description = "TXT_KEY_TERRAIN_OCEAN",    water = true },
        { Type = "TERRAIN_MOUNTAIN", Description = "TXT_KEY_TERRAIN_MOUNTAIN" },
    },
    Features = {
        { Type = "FEATURE_FOREST", Description = "TXT_KEY_FEATURE_FOREST", Movement = 2 },
        { Type = "FEATURE_JUNGLE", Description = "TXT_KEY_FEATURE_JUNGLE", Movement = 2 },
        { Type = "FEATURE_MARSH",  Description = "TXT_KEY_FEATURE_MARSH",  Movement = 2 },
    },
    Improvements = {
        { Type = "IMPROVEMENT_FARM",    Description = "TXT_KEY_IMPROVEMENT_FARM" },
        { Type = "IMPROVEMENT_MINE",    Description = "TXT_KEY_IMPROVEMENT_MINE" },
        { Type = "IMPROVEMENT_PASTURE", Description = "TXT_KEY_IMPROVEMENT_PASTURE" },
    },
    Resources = {
        { Type = "RESOURCE_HORSE", Description = "TXT_KEY_RESOURCE_HORSE", usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC },
        { Type = "RESOURCE_IRON",  Description = "TXT_KEY_RESOURCE_IRON",  usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC },
        { Type = "RESOURCE_FUR",   Description = "TXT_KEY_RESOURCE_FUR",   usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_LUXURY },
        { Type = "RESOURCE_WHEAT", Description = "TXT_KEY_RESOURCE_WHEAT", usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_BONUS },
    },
    Units = {
        { Type = "UNIT_WARRIOR",  Description = "TXT_KEY_UNIT_WARRIOR",  Domain = "DOMAIN_LAND", Combat = 8,  RangedCombat = 0,  Range = 0, Moves = 2 },
        { Type = "UNIT_ARCHER",   Description = "TXT_KEY_UNIT_ARCHER",   Domain = "DOMAIN_LAND", Combat = 5,  RangedCombat = 9,  Range = 2, Moves = 2 },
        { Type = "UNIT_SETTLER",  Description = "TXT_KEY_UNIT_SETTLER",  Domain = "DOMAIN_LAND", Combat = 0,  RangedCombat = 0,  Range = 0, Moves = 2 },
        { Type = "UNIT_WORKER",   Description = "TXT_KEY_UNIT_WORKER",   Domain = "DOMAIN_LAND", Combat = 0,  RangedCombat = 0,  Range = 0, Moves = 2 },
        { Type = "UNIT_CATAPULT", Description = "TXT_KEY_UNIT_CATAPULT", Domain = "DOMAIN_LAND", Combat = 7,  RangedCombat = 11, Range = 2, Moves = 2 },
        { Type = "UNIT_TRIREME",  Description = "TXT_KEY_UNIT_TRIREME",  Domain = "DOMAIN_SEA",  Combat = 10, RangedCombat = 0,  Range = 0, Moves = 4 },
        { Type = "UNIT_GALLEASS", Description = "TXT_KEY_UNIT_GALLEASS", Domain = "DOMAIN_SEA",  Combat = 12, RangedCombat = 13, Range = 2, Moves = 4 },
        { Type = "UNIT_FIGHTER",  Description = "TXT_KEY_UNIT_FIGHTER",  Domain = "DOMAIN_AIR",  Combat = 0,  RangedCombat = 0,  Range = 8, Moves = 2 },
    },
    Buildings = {
        { Type = "BUILDING_MONUMENT", Description = "TXT_KEY_BUILDING_MONUMENT" },
        { Type = "BUILDING_GRANARY",  Description = "TXT_KEY_BUILDING_GRANARY" },
        { Type = "BUILDING_WALLS",    Description = "TXT_KEY_BUILDING_WALLS" },
        { Type = "BUILDING_PALACE",   Description = "TXT_KEY_BUILDING_PALACE" },
    },
    Projects = {
        { Type = "PROJECT_APOLLO_PROGRAM",    Description = "TXT_KEY_PROJECT_APOLLO_PROGRAM" },
        { Type = "PROJECT_MANHATTAN_PROJECT", Description = "TXT_KEY_PROJECT_MANHATTAN_PROJECT" },
    },
    Processes = {
        { Type = "PROCESS_WEALTH",   Description = "TXT_KEY_PROCESS_WEALTH" },
        { Type = "PROCESS_RESEARCH", Description = "TXT_KEY_PROCESS_RESEARCH" },
    },
}

local DEFAULT_ACTION_ROWS = {
    { Type = "MISSION_FORTIFY",                  SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_ALERT",                    SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SLEEP",                    SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_HEAL",                     SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SKIP",                     SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SET_UP_FOR_RANGED_ATTACK", SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
}

-- -----------------------------------------------------------------------------
-- 第 2 节：基础工具函数
-- -----------------------------------------------------------------------------

local function keyOf(x, y)
    return tostring(x) .. ":" .. tostring(y)
end
S.keyOf = keyOf

local function deepCopy(v)
    if type(v) ~= "table" or v._kind ~= nil then return v end
    local out = {}
    for k, item in pairs(v) do
        out[k] = deepCopy(item)
    end
    return out
end

local function normalizeNameList(names)
    if type(names) == "string" then return { names } end
    return names or {}
end

local function decide(value, self, key, ...)
    local kind = type(value)
    if kind == "function" then return value(self, ...) == true end
    if kind == "table" then
        local item = value[key]
        if type(item) == "function" then return item(self, ...) == true end
        return item == true
    end
    return value == true
end

local function evalOutcome(value, ...)
    if type(value) == "function" then
        return value(...)
    end
    if type(value) == "table" then
        return value
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- 第 3 节：全局枚举表与 GameDefines 管理
-- -----------------------------------------------------------------------------

DomainTypes = ENUMS.DomainTypes
YieldTypes = ENUMS.YieldTypes
ResourceUsageTypes = ENUMS.ResourceUsageTypes
InterfaceModeTypes = ENUMS.InterfaceModeTypes
EndTurnBlockingTypes = ENUMS.EndTurnBlockingTypes
GameMessageTypes = ENUMS.GameMessageTypes
MissionTypes = ENUMS.MissionTypes
TaskTypes = ENUMS.TaskTypes
OrderTypes = ENUMS.OrderTypes
CityUpdateTypes = ENUMS.CityUpdateTypes
ControlTypes = ENUMS.ControlTypes

function S.resetGameDefines(overrides)
    GameDefines = GameDefines or {}
    for k in pairs(GameDefines) do GameDefines[k] = nil end
    for k, v in pairs(GAME_DEFINES_DEFAULT) do GameDefines[k] = v end
    for k, v in pairs(overrides or {}) do GameDefines[k] = v end
end

-- -----------------------------------------------------------------------------
-- 第 4 节：红线陷阱守卫与未实现方法检测
-- -----------------------------------------------------------------------------

S.guard = { violations = {}, missing = {}, totalWrites = 0 }

-- 永久禁令方法：触发即记入 violations 并抛错（E-06 / 原版 DLL 避坑 / AffectsSavedGames = 0）
local FORBIDDEN_METHODS = {
    CanMoveOrAttackInto = "[引擎避坑红线] 严禁调用原版 DLL 缺陷方法 ",
    SetInterfaceMode = "[红线 E-06] 严禁调用 UI.SetInterfaceMode ",
    SetScriptData = "[红线 A-08] 严禁写入存档持久化数据 ",
}

local function makeTrap(ownerLabel, methodName, reasonPrefix)
    local prefix = reasonPrefix or "[红线守卫] 禁止调用方法 "
    return function(...)
        table.insert(S.guard.violations, {
            owner = ownerLabel,
            method = methodName,
            args = { ... },
        })
        error(prefix .. ownerLabel .. "." .. methodName .. "()", 2)
    end
end

local function makeMissing(ownerLabel, methodName)
    return function(...)
        table.insert(S.guard.missing, { owner = ownerLabel, method = methodName })
        error("[引擎桩] 调用了桩未实现的方法 " .. ownerLabel .. "." .. methodName .. "()", 2)
    end
end

local function unknownMember(ownerLabel, key)
    if type(key) == "string" and FORBIDDEN_METHODS[key] ~= nil then
        return makeTrap(ownerLabel, key, FORBIDDEN_METHODS[key])
    end
    return makeMissing(ownerLabel, key)
end

-- -----------------------------------------------------------------------------
-- 函数：S.expectViolation(fn)
-- 做什么：供桩自检用例验证红线陷阱是否按预期触发，并安全剥离本次预期的违规记录，
--         防止用例结束后误触 FW-01 全局归零检查。
-- 输入：fn（预期触发陷阱的闭包）。
-- 输出：(caught: boolean, errMsg: string, capturedCount: number)。
-- -----------------------------------------------------------------------------
function S.expectViolation(fn)
    local before = #S.guard.violations
    local ok, err = pcall(fn)
    local after = #S.guard.violations
    local captured = after - before
    for i = after, before + 1, -1 do
        table.remove(S.guard.violations, i)
    end
    return (not ok) and (captured > 0), tostring(err), captured
end

-- -----------------------------------------------------------------------------
-- 第 5 节：include 垫片与 print 输出捕获
-- -----------------------------------------------------------------------------

S.includeOrder = {}
S.includeCount = {}
S.prints = {}

function S.hasModule(name)
    local src = __py_read_file("mod/Lua/" .. tostring(name) .. ".lua")
    return src ~= nil
end

function include(name)
    local key = tostring(name)
    if key:sub(-4) == ".lua" then
        key = key:sub(1, -5)
    end
    local relpath = "mod/Lua/" .. key .. ".lua"
    local src, err = __py_read_file(relpath)
    if not src then
        error("include 垫片：无法读取 " .. relpath .. "（" .. tostring(err) .. "）", 2)
    end
    local chunk, compileErr = loadstring(src, "@" .. relpath)
    if not chunk then
        error("include 垫片：" .. relpath .. " 编译失败：" .. tostring(compileErr), 2)
    end
    chunk()
    if not S.includeCount[key] then
        S.includeCount[key] = 0
        table.insert(S.includeOrder, key)
    end
    S.includeCount[key] = S.includeCount[key] + 1
end

print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    table.insert(S.prints, table.concat(parts, "\t"))
end

-- -----------------------------------------------------------------------------
-- 第 6 节：GameInfo 数据库表视图（0-based + #view + 迭代器 + 越界空表）
-- -----------------------------------------------------------------------------

local function copyRows(rows)
    local out = { n = 0 }
    for i, row in ipairs(rows) do
        local copy = deepCopy(row)
        copy.ID = i - 1
        out[i - 1] = copy
        out.n = i
    end
    return out
end

local function newInfoView(getRows)
    local view = newproxy(true)
    local meta = getmetatable(view)
    meta.__index = function(_, key)
        if type(key) == "number" then
            local rows = getRows()
            local row = rows[key]
            if row ~= nil then return row end
            return {}
        end
        if type(key) == "string" then
            local rows = getRows()
            for i = 0, rows.n - 1 do
                if rows[i].Type == key then return rows[i] end
            end
            return {}
        end
        return nil
    end
    meta.__len = function()
        return getRows().n
    end
    meta.__call = function()
        local i = -1
        return function()
            i = i + 1
            local rows = getRows()
            if i < rows.n then return rows[i] end
            return nil
        end
    end
    return view
end

-- -----------------------------------------------------------------------------
-- 第 7 节：Odd-r 六边形距离与调用日志/写审计
-- -----------------------------------------------------------------------------

function S.hexDistance(x1, y1, x2, y2)
    local ax = x1 - (y1 - (y1 % 2)) / 2
    local az = y1
    local bx = x2 - (y2 - (y2 % 2)) / 2
    local bz = y2
    local ay = -ax - az
    local by = -bx - bz
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.floor((math.abs(dx) + math.abs(dy) + math.abs(dz)) / 2 + 0.5)
end

function S.describe(value)
    if type(value) == "table" and value._kind ~= nil then
        if value._kind == "plot" then
            return "plot(" .. tostring(value._s.x) .. "," .. tostring(value._s.y) .. ")"
        end
        if value._kind == "player" or value._kind == "team" then
            return value._kind .. "(" .. tostring(value._s.id) .. ")"
        end
        return value._kind .. "(" .. tostring(value._s.owner) .. ":" .. tostring(value._s.id) .. ")"
    end
    return tostring(value)
end

function S.playerTeamOf(w, playerID)
    local p = w.players[playerID]
    if p == nil then return -1 end
    return p._s.team
end

function S.visionTeamOf(w)
    return S.playerTeamOf(w, w.activePlayer)
end

function S.record(w, entry)
    local plot = entry.plot
    if plot ~= nil then
        local team = S.visionTeamOf(w)
        entry.x, entry.y = plot._s.x, plot._s.y
        entry.revealed = plot._s.revealed[team] == true
        entry.visible = plot._s.visible[team] == true
        local city = plot._s.city
        entry.hasCity = (city ~= nil)
        local isHostileCity = false
        if city ~= nil and city._s.owner ~= w.activePlayer then
            local cityTeam = S.playerTeamOf(w, city._s.owner)
            local myTeamObj = w.teams[team]
            if myTeamObj ~= nil and myTeamObj._s.atWar[cityTeam] == true then
                isHostileCity = true
            end
        end
        entry.isHostileCity = isHostileCity
    end
    entry.headUnit = S.describe(w.ui.headUnit)
    entry.seq = #w.log + 1
    table.insert(w.log, entry)
    return entry
end

function S.recordWrite(w, kind, detail)
    local entry = detail or {}
    entry.kind = kind
    entry.seq = #w.writeLog + 1
    table.insert(w.writeLog, entry)
    S.guard.totalWrites = S.guard.totalWrites + 1
    return entry
end

-- -----------------------------------------------------------------------------
-- 第 8 节：对象规格校验与字段清单
-- -----------------------------------------------------------------------------

local NONE = {}

local function fieldSet(names, defaults)
    local set = {}
    for _, name in ipairs(names) do
        if defaults ~= nil and defaults[name] ~= nil then
            set[name] = defaults[name]
        else
            set[name] = NONE
        end
    end
    return set
end

local function fillDefaults(spec, fields, label)
    local s = {}
    for name, default in pairs(fields) do
        local value = default
        if value == NONE then value = nil end
        if type(value) == "table" then value = deepCopy(value) end
        s[name] = value
    end
    for name, value in pairs(spec or {}) do
        if fields[name] == nil then
            error("布置规格包含未知字段 " .. label .. "." .. tostring(name), 3)
        end
        if type(value) == "table" and value._kind == nil then
            value = deepCopy(value)
        end
        s[name] = value
    end
    return s
end

local function applyPatch(targetState, patch, fields, label)
    for name, value in pairs(patch or {}) do
        if fields[name] == nil then
            error("状态补丁包含未知字段 " .. label .. "." .. tostring(name), 3)
        end
        if type(value) == "table" and value._kind == nil then
            value = deepCopy(value)
        end
        targetState[name] = value
    end
end

local TEAM_FIELDS = fieldSet({ "id", "atWar", "peaceTreaty", "canDeclareWar" }, {
    atWar = {},
    peaceTreaty = {},
})

local PLAYER_FIELDS = fieldSet({
    "id", "alive", "team", "minor", "barbarian", "human", "name", "civ",
    "turnActive", "goldenAge",
    "gold", "goldRate", "science", "culturePerTurn", "faith", "faithPerTurn", "happiness",
    "resourcesAvailable", "resourcesTotal",
    "blockingType", "blockingNotificationIndex", "notifications",
}, {
    alive = true, team = 0, minor = false, barbarian = false, human = true,
    turnActive = true, goldenAge = false,
    gold = 0, goldRate = 0, science = 0, culturePerTurn = 0, faith = 0, faithPerTurn = 0, happiness = 0,
    resourcesAvailable = {}, resourcesTotal = {},
    blockingType = -1, blockingNotificationIndex = -1, notifications = {},
})

local UNIT_FIELDS = fieldSet({
    "id", "owner", "unitType", "x", "y", "nameKey",
    "domain", "damage", "maxHp", "moves", "maxMoves",
    "combat", "rangedCombat", "range",
    "fortifyTurns", "readyToMove", "promotionReady", "automated", "delayedDeath", "dead",
    "isCombat", "embarked", "invisibleTo",
    "canRangeStrike", "canRangeStrikeAt", "canMoveThrough", "canAttack", "canFortify", "canHeal",
    "mustSetUp", "everFortifyable", "canHandleActions",
    "busyTicks", "fightingTicks", "visionRange", "onMove", "combatOutcome",
}, {
    damage = 0, fortifyTurns = 0, promotionReady = false, automated = false, delayedDeath = false,
    dead = false, embarked = false, invisibleTo = {},
    canRangeStrike = false, canRangeStrikeAt = false, canMoveThrough = false,
    canFortify = false, canHeal = false, mustSetUp = false, canHandleActions = {},
    busyTicks = 0, fightingTicks = 0, visionRange = 2,
})

local CITY_FIELDS = fieldSet({
    "id", "owner", "name", "x", "y", "pop", "damage", "maxHp", "strength",
    "isCapital", "isPuppet", "isOccupied", "isResistance", "isRazing",
    "yields", "productionModifier", "foodNet", "foodStore", "growthThreshold",
    "foodTurnsLeft", "foodGrowthBlocked", "foodDiffTimes100",
    "culturePerTurn", "faithPerTurn",
    "orderQueueLength", "isProduction", "isProductionProcess", "productionTurnsLeft", "productionNameKey",
    "garrison", "realBuildings", "cityPlots",
    "canRangeStrike", "canRangeStrikeNow", "canRangeStrikeAt",
    "purchasable", "affordable", "costs",
    "canBuyPlotAt", "canBuyPlotNow", "buyPlotCost",
    "canConstruct", "canTrain", "canCreate", "canMaintain", "rangedOutcome",
}, {
    pop = 1, damage = 0, maxHp = GAME_DEFINES_DEFAULT.MAX_CITY_HIT_POINTS, strength = 800,
    isCapital = false, isPuppet = false, isOccupied = false, isResistance = false, isRazing = false,
    yields = {}, productionModifier = 0, foodNet = 0, foodStore = 0, growthThreshold = 20,
    foodTurnsLeft = -1, foodGrowthBlocked = false,
    culturePerTurn = 0, faithPerTurn = 0,
    orderQueueLength = 0, isProduction = false, isProductionProcess = false, productionTurnsLeft = 0,
    realBuildings = {}, cityPlots = {},
    canRangeStrike = false, canRangeStrikeNow = false, canRangeStrikeAt = false,
    purchasable = { units = {}, buildings = {} },
    costs = { unitGold = {}, unitFaith = {}, bldGold = {}, bldFaith = {} },
    canBuyPlotAt = {}, buyPlotCost = {},
    canConstruct = true, canTrain = true, canCreate = true, canMaintain = true,
})

local PLOT_FIELDS = fieldSet({
    "terrain", "feature", "hills", "river", "mountain", "impassable", "fighting", "fightingTicks",
    "improvement", "resource", "resourceKnownBy", "owner",
    "revealed", "visible",
    "isVisibleEnemyUnit", "isEnemyCity",
}, {
    feature = -1, hills = false, river = false, mountain = false, impassable = false,
    fighting = false, fightingTicks = 0,
    improvement = -1, resource = -1, owner = -1,
})

-- -----------------------------------------------------------------------------
-- 第 9 节：状态演进内部辅助（移动、揭盲、战斗、阵亡、城市攻占/购买）
-- -----------------------------------------------------------------------------

local function removeUnitFromPlot(w, unit)
    local oldPlot = w:getPlot(unit._s.x, unit._s.y)
    if oldPlot == nil then return end
    for i = #oldPlot._s.units, 1, -1 do
        if oldPlot._s.units[i] == unit then
            table.remove(oldPlot._s.units, i)
        end
    end
end

local function killUnit(w, unit)
    unit._s.damage = unit._s.maxHp
    unit._s.dead = true
    unit._s.moves = 0
    unit._s.readyToMove = false
    unit._s.busyTicks = 0
    unit._s.fightingTicks = 0
    removeUnitFromPlot(w, unit)
end

local function moveUnitToPlot(w, unit, targetPlot)
    removeUnitFromPlot(w, unit)
    unit._s.x = targetPlot._s.x
    unit._s.y = targetPlot._s.y
    table.insert(targetPlot._s.units, unit)

    -- 自动按单位视野半径揭盲并设为可见
    local team = S.playerTeamOf(w, unit._s.owner)
    local radius = unit._s.visionRange or 2
    if team >= 0 and radius >= 0 then
        local cx, cy = targetPlot._s.x, targetPlot._s.y
        for dx = -radius, radius do
            for dy = -radius, radius do
                local p = w:getPlot(cx + dx, cy + dy)
                if p ~= nil and S.hexDistance(cx, cy, p._s.x, p._s.y) <= radius then
                    p._s.revealed[team] = true
                    p._s.visible[team] = true
                end
            end
        end
    end
end

local function findPrimaryHostileUnitOnPlot(w, plot, attackerOwner)
    local best = nil
    for _, u in ipairs(plot._s.units) do
        if (not u._s.dead) and (not u._s.delayedDeath) and u._s.owner ~= attackerOwner then
            if best == nil or (u._s.isCombat and not best._s.isCombat) then
                best = u
            end
        end
    end
    return best
end

local function transferCityOwner(w, city, newOwner)
    local oldOwner = city._s.owner
    local oldList = w.citiesByPlayer[oldOwner]
    if oldList ~= nil then
        for i = #oldList, 1, -1 do
            if oldList[i] == city then
                table.remove(oldList, i)
            end
        end
    end
    city._s.owner = newOwner
    city._s.damage = math.floor(city._s.maxHp / 2)
    city._s.isOccupied = true
    local newList = w.citiesByPlayer[newOwner]
    if newList == nil then
        newList = {}
        w.citiesByPlayer[newOwner] = newList
    end
    table.insert(newList, city)
    local plot = w:getPlot(city._s.x, city._s.y)
    if plot ~= nil then
        plot._s.owner = newOwner
    end
end

local function destroyCity(w, city)
    local oldList = w.citiesByPlayer[city._s.owner]
    if oldList ~= nil then
        for i = #oldList, 1, -1 do
            if oldList[i] == city then
                table.remove(oldList, i)
            end
        end
    end
    local plot = w:getPlot(city._s.x, city._s.y)
    if plot ~= nil then
        plot._s.city = nil
    end
end

local function refreshReadyUnitBlocking(w, playerID)
    local p = w.players[playerID]
    if p == nil then return end
    local bt = p._s.blockingType
    if bt == EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS
        or bt == EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS
    then
        local anyReady = false
        for _, u in ipairs(w.unitsByPlayer[playerID] or {}) do
            if (not u._s.dead) and u:IsReadyToMove() then
                anyReady = true
                break
            end
        end
        if not anyReady then
            p._s.blockingType = EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE
        end
    end
end

-- -----------------------------------------------------------------------------
-- 第 10 节：Plot / Unit / City / Player / Team 方法表
-- -----------------------------------------------------------------------------

local PlotMethods = {}

PlotMethods.GetX = function(p) return p._s.x end
PlotMethods.GetY = function(p) return p._s.y end
PlotMethods.IsRevealed = function(p, team) return p._s.revealed[team] == true end
PlotMethods.IsVisible = function(p, team) return p._s.visible[team] == true end
PlotMethods.GetNumUnits = function(p) return #p._s.units end
PlotMethods.GetUnit = function(p, index)
    if type(index) ~= "number" then return nil end
    return p._s.units[index + 1]
end
PlotMethods.GetOwner = function(p) return p._s.owner end
PlotMethods.GetPlotCity = function(p) return p._s.city end
PlotMethods.IsCity = function(p) return p._s.city ~= nil end
PlotMethods.GetTerrainType = function(p) return p._s.terrain end
PlotMethods.GetFeatureType = function(p) return p._s.feature end
PlotMethods.IsHills = function(p) return p._s.hills == true end
PlotMethods.IsRiver = function(p) return p._s.river == true end
PlotMethods.IsMountain = function(p) return p._s.mountain == true end
PlotMethods.IsWater = function(p)
    local row = p._w.info.Terrains[p._s.terrain]
    return row ~= nil and row.water == true
end
PlotMethods.IsImpassable = function(p) return p._s.impassable == true end
PlotMethods.IsFighting = function(p) return p._s.fighting == true or (p._s.fightingTicks or 0) > 0 end
PlotMethods.GetImprovementType = function(p) return p._s.improvement end
PlotMethods.GetResourceType = function(p, team)
    local known = p._s.resourceKnownBy
    if known == false then return -1 end
    if known == nil then return p._s.resource end
    if type(known) == "table" and known[team] == true then return p._s.resource end
    return -1
end
PlotMethods.IsVisibleEnemyUnit = function(p, ePlayer)
    S.record(p._w, { name = "IsVisibleEnemyUnit", args = { ePlayer }, plot = p })
    if p._s.isVisibleEnemyUnit ~= nil then
        return decide(p._s.isVisibleEnemyUnit, p, keyOf(p._s.x, p._s.y), ePlayer)
    end
    local team = S.playerTeamOf(p._w, ePlayer)
    if p._s.visible[team] ~= true then return false end
    for _, u in ipairs(p._s.units) do
        if (not u._s.dead) and u._s.owner ~= ePlayer and u._s.invisibleTo[team] ~= true then
            return true
        end
    end
    return false
end
PlotMethods.IsEnemyCity = function(p, pUnit)
    S.record(p._w, { name = "IsEnemyCity", args = { pUnit }, plot = p })
    if p._s.isEnemyCity ~= nil then
        return decide(p._s.isEnemyCity, p, keyOf(p._s.x, p._s.y), pUnit)
    end
    local city = p._s.city
    if city == nil then return false end
    local viewer = -1
    if pUnit ~= nil and pUnit._kind == "unit" then viewer = pUnit._s.owner end
    return city._s.owner ~= viewer
end

local UnitMethods = {}

UnitMethods.GetID = function(u) return u._s.id end
UnitMethods.GetUnitType = function(u) return u._s.unitType end
UnitMethods.GetName = function(u) return u._s.nameKey end
UnitMethods.GetDomainType = function(u) return u._s.domain end
UnitMethods.GetOwner = function(u) return u._s.owner end
UnitMethods.GetPlot = function(u) return u._w:getPlot(u._s.x, u._s.y) end
UnitMethods.GetX = function(u) return u._s.x end
UnitMethods.GetY = function(u) return u._s.y end
UnitMethods.GetDamage = function(u) return u._s.damage end
UnitMethods.GetCurrHitPoints = function(u) return math.max(0, u._s.maxHp - u._s.damage) end
UnitMethods.GetMaxHitPoints = function(u) return u._s.maxHp end
UnitMethods.MovesLeft = function(u) return u._s.moves end
UnitMethods.MaxMoves = function(u) return u._s.maxMoves end
UnitMethods.GetBaseCombatStrength = function(u) return u._s.combat end
UnitMethods.GetBaseRangedCombatStrength = function(u) return u._s.rangedCombat end
UnitMethods.Range = function(u) return u._s.range end
UnitMethods.GetFortifyTurns = function(u) return u._s.fortifyTurns end
UnitMethods.IsReadyToMove = function(u)
    if u._s.readyToMove ~= nil then return u._s.readyToMove == true end
    return u._s.moves > 0
end
UnitMethods.IsPromotionReady = function(u) return u._s.promotionReady == true end
UnitMethods.IsAutomated = function(u) return u._s.automated == true end
UnitMethods.IsDelayedDeath = function(u) return u._s.delayedDeath == true end
UnitMethods.IsDead = function(u) return u._s.dead == true end
UnitMethods.IsBusy = function(u) return (u._s.busyTicks or 0) > 0 end
UnitMethods.IsFighting = function(u) return (u._s.fightingTicks or 0) > 0 end
UnitMethods.IsCombatUnit = function(u) return u._s.isCombat == true end
UnitMethods.IsEmbarked = function(u) return u._s.embarked == true end
UnitMethods.IsInvisible = function(u, team) return u._s.invisibleTo[team] == true end
UnitMethods.CanRangeStrike = function(u) return decide(u._s.canRangeStrike, u, nil) end
UnitMethods.CanRangeStrikeAt = function(u, x, y, ...)
    local w = u._w
    local pPlot = w:getPlot(x, y)
    S.record(w, { name = "CanRangeStrikeAt", self = u, args = { x, y, ... }, plot = pPlot })
    if pPlot == nil then return false end
    return decide(u._s.canRangeStrikeAt, u, keyOf(x, y), x, y, ...)
end
UnitMethods.IsCanAttack = function(u)
    if u._s.canAttack ~= nil then return u._s.canAttack == true end
    return u._s.isCombat == true and u._s.moves > 0
end
UnitMethods.IsMustSetUpToRangedAttack = function(u) return u._s.mustSetUp == true end
UnitMethods.IsEverFortifyable = function(u)
    if u._s.everFortifyable ~= nil then return u._s.everFortifyable == true end
    return u._s.isCombat == true
end
UnitMethods.IsHurt = function(u) return u._s.damage > 0 end
UnitMethods.CanFortify = function(u, pPlot)
    local key = nil
    if pPlot ~= nil and pPlot._kind == "plot" then key = keyOf(pPlot._s.x, pPlot._s.y) end
    return decide(u._s.canFortify, u, key, pPlot)
end
UnitMethods.CanHeal = function(u, pPlot)
    local key = nil
    if pPlot ~= nil and pPlot._kind == "plot" then key = keyOf(pPlot._s.x, pPlot._s.y) end
    return decide(u._s.canHeal, u, key, pPlot)
end
UnitMethods.CanMoveThrough = function(u, pPlot)
    local isPlot = (pPlot ~= nil and pPlot._kind == "plot")
    S.record(u._w, { name = "CanMoveThrough", self = u, args = { pPlot }, plot = isPlot and pPlot or nil })
    if not isPlot then return false end
    return decide(u._s.canMoveThrough, u, keyOf(pPlot._s.x, pPlot._s.y), pPlot)
end
UnitMethods.CanMoveOrAttackInto = makeTrap("Unit", "CanMoveOrAttackInto", FORBIDDEN_METHODS.CanMoveOrAttackInto)

local CityMethods = {}

CityMethods.GetID = function(c) return c._s.id end
CityMethods.GetName = function(c) return c._s.name end
CityMethods.GetPopulation = function(c) return c._s.pop end
CityMethods.GetX = function(c) return c._s.x end
CityMethods.GetY = function(c) return c._s.y end
CityMethods.GetMaxHitPoints = function(c) return c._s.maxHp end
CityMethods.GetDamage = function(c) return c._s.damage end
CityMethods.GetStrengthValue = function(c) return c._s.strength end
CityMethods.IsCapital = function(c) return c._s.isCapital == true end
CityMethods.IsPuppet = function(c) return c._s.isPuppet == true end
CityMethods.IsOccupied = function(c) return c._s.isOccupied == true end
CityMethods.IsResistance = function(c) return c._s.isResistance == true end
CityMethods.IsRazing = function(c) return c._s.isRazing == true end
CityMethods.GetOwner = function(c) return c._s.owner end
CityMethods.GetTeam = function(c) return S.playerTeamOf(c._w, c._s.owner) end
CityMethods.Plot = function(c) return c._w:getPlot(c._s.x, c._s.y) end
CityMethods.GetNumCityPlots = function(c) return #c._s.cityPlots end
CityMethods.GetCityIndexPlot = function(c, index)
    if type(index) ~= "number" then return nil end
    local entry = c._s.cityPlots[index + 1]
    if entry == nil then return nil end
    return c._w:getPlot(entry.x, entry.y)
end
CityMethods.GetGarrisonedUnit = function(c) return c._s.garrison end
CityMethods.GetOrderQueueLength = function(c) return c._s.orderQueueLength end
CityMethods.IsProduction = function(c) return c._s.isProduction == true end
CityMethods.IsProductionProcess = function(c) return c._s.isProductionProcess == true end
CityMethods.GetProductionTurnsLeft = function(c) return c._s.productionTurnsLeft end
CityMethods.GetProductionNameKey = function(c) return c._s.productionNameKey end
CityMethods.GetYieldRate = function(c, yieldType) return c._s.yields[yieldType] or 0 end
CityMethods.GetProductionModifier = function(c) return c._s.productionModifier end
CityMethods.FoodDifference = function(c) return c._s.foodNet end
CityMethods.GetJONSCulturePerTurn = function(c) return c._s.culturePerTurn end
CityMethods.GetFaithPerTurn = function(c) return c._s.faithPerTurn end
CityMethods.GetFood = function(c) return c._s.foodStore end
CityMethods.GrowthThreshold = function(c) return c._s.growthThreshold end
CityMethods.GetFoodTurnsLeft = function(c) return c._s.foodTurnsLeft end
CityMethods.IsFoodProduction = function(c) return c._s.foodGrowthBlocked == true end
CityMethods.FoodDifferenceTimes100 = function(c)
    if c._s.foodDiffTimes100 ~= nil then return c._s.foodDiffTimes100 end
    return c._s.foodNet * 100
end
CityMethods.CanRangeStrike = function(c) return decide(c._s.canRangeStrike, c, nil) end
CityMethods.CanRangeStrikeNow = function(c)
    local w = c._w
    S.record(w, { name = "CanRangeStrikeNow", self = c, args = {}, plot = w:getPlot(c._s.x, c._s.y) })
    return decide(c._s.canRangeStrikeNow, c, nil)
end
CityMethods.CanRangeStrikeAt = function(c, x, y, ...)
    local w = c._w
    local pPlot = w:getPlot(x, y)
    S.record(w, { name = "CanRangeStrikeAt", self = c, args = { x, y, ... }, plot = pPlot })
    if pPlot == nil then return false end
    return decide(c._s.canRangeStrikeAt, c, keyOf(x, y), x, y, ...)
end
CityMethods.CanConstruct = function(c, bldId) return decide(c._s.canConstruct, c, bldId, bldId) end
CityMethods.CanTrain = function(c, unitId) return decide(c._s.canTrain, c, unitId, unitId) end
CityMethods.CanCreate = function(c, projId) return decide(c._s.canCreate, c, projId, projId) end
CityMethods.CanMaintain = function(c, procId) return decide(c._s.canMaintain, c, procId, procId) end

local function purchasePoolEntry(city, bTestVisible, bTestCost, unitID, buildingID, eYield)
    local pool
    if bTestVisible == false and bTestCost == false then
        pool = city._s.purchasable
    elseif bTestVisible == true and bTestCost == true then
        pool = city._s.affordable or city._s.purchasable
    else
        return nil
    end
    if pool == nil then return false end
    local currency = nil
    if eYield == YieldTypes.YIELD_GOLD then
        currency = "gold"
    elseif eYield == YieldTypes.YIELD_FAITH then
        currency = "faith"
    end
    if currency == nil then return nil end

    local entry = nil
    if unitID ~= nil and unitID >= 0 then
        entry = pool.units and pool.units[unitID]
    elseif buildingID ~= nil and buildingID >= 0 then
        entry = pool.buildings and pool.buildings[buildingID]
    end
    if entry == nil then return false end
    return entry[currency] == true
end

CityMethods.IsCanPurchase = function(c, bTestVisible, bTestCost, unitID, buildingID, projectID, eYield)
    local result = purchasePoolEntry(c, bTestVisible, bTestCost, unitID, buildingID, eYield)
    if result == nil then return false end
    return result
end
CityMethods.GetUnitPurchaseCost = function(c, unitID)
    return (c._s.costs and c._s.costs.unitGold and c._s.costs.unitGold[unitID]) or 0
end
CityMethods.GetUnitFaithPurchaseCost = function(c, unitID)
    return (c._s.costs and c._s.costs.unitFaith and c._s.costs.unitFaith[unitID]) or 0
end
CityMethods.GetBuildingPurchaseCost = function(c, buildingID)
    return (c._s.costs and c._s.costs.bldGold and c._s.costs.bldGold[buildingID]) or 0
end
CityMethods.GetBuildingFaithPurchaseCost = function(c, buildingID)
    return (c._s.costs and c._s.costs.bldFaith and c._s.costs.bldFaith[buildingID]) or 0
end
CityMethods.CanBuyPlotAt = function(c, x, y, ignoreCost)
    local key = keyOf(x, y)
    if ignoreCost == true then return c._s.canBuyPlotAt[key] == true end
    if c._s.canBuyPlotNow == nil then return c._s.canBuyPlotAt[key] == true end
    return c._s.canBuyPlotNow[key] == true
end
CityMethods.GetBuyPlotCost = function(c, x, y) return c._s.buyPlotCost[keyOf(x, y)] or 0 end
CityMethods.GetNumRealBuilding = function(c, buildingID) return c._s.realBuildings[buildingID] or 0 end

local PlayerMethods = {}

PlayerMethods.GetTeam = function(p) return p._s.team end
PlayerMethods.IsTurnActive = function(p) return p._s.turnActive == true end
PlayerMethods.IsAlive = function(p) return p._s.alive == true end
PlayerMethods.IsMinorCiv = function(p) return p._s.minor == true end
PlayerMethods.IsBarbarian = function(p) return p._s.barbarian == true end
PlayerMethods.GetName = function(p) return p._s.name end
PlayerMethods.GetCivilizationShortDescription = function(p) return p._s.civ end
PlayerMethods.GetGold = function(p) return p._s.gold end
PlayerMethods.CalculateGoldRate = function(p) return p._s.goldRate end
PlayerMethods.GetScience = function(p) return p._s.science end
PlayerMethods.GetTotalJONSCulturePerTurn = function(p) return p._s.culturePerTurn end
PlayerMethods.GetFaith = function(p) return p._s.faith end
PlayerMethods.GetTotalFaithPerTurn = function(p) return p._s.faithPerTurn end
PlayerMethods.GetExcessHappiness = function(p) return p._s.happiness end
PlayerMethods.IsGoldenAge = function(p) return p._s.goldenAge == true end
PlayerMethods.GetNumResourceAvailable = function(p, resourceID) return p._s.resourcesAvailable[resourceID] or 0 end
PlayerMethods.GetNumResourceTotal = function(p, resourceID) return p._s.resourcesTotal[resourceID] or 0 end
PlayerMethods.Units = function(p)
    local list = p._w.unitsByPlayer[p._s.id]
    local i = 0
    return function()
        i = i + 1
        if list == nil then return nil end
        return list[i]
    end
end
PlayerMethods.Cities = function(p)
    local list = p._w.citiesByPlayer[p._s.id]
    local i = 0
    return function()
        i = i + 1
        if list == nil then return nil end
        return list[i]
    end
end
PlayerMethods.GetUnitByID = function(p, unitID)
    for u in p:Units() do
        if u._s.id == unitID then return u end
    end
    return nil
end
PlayerMethods.GetCityByID = function(p, cityID)
    for c in p:Cities() do
        if c._s.id == cityID then return c end
    end
    return nil
end
PlayerMethods.GetEndTurnBlockingType = function(p) return p._s.blockingType end
PlayerMethods.GetEndTurnBlockingNotificationIndex = function(p) return p._s.blockingNotificationIndex end
PlayerMethods.GetNumNotifications = function(p) return #p._s.notifications end
PlayerMethods.GetNotificationIndex = function(p, index)
    local item = p._s.notifications[index + 1]
    if item == nil then return -1 end
    return item.index
end
PlayerMethods.GetNotificationSummaryStr = function(p, index)
    local item = p._s.notifications[index + 1]
    if item == nil then return "" end
    return item.summary
end
PlayerMethods.GetNotificationStr = function(p, index)
    local item = p._s.notifications[index + 1]
    if item == nil then return "" end
    return item.str
end
PlayerMethods.GetFirstReadyUnit = function(p)
    for u in p:Units() do
        if (not u._s.dead) and u:IsReadyToMove() then return u end
    end
    return nil
end

local TeamMethods = {}

TeamMethods.IsAtWar = function(t, otherTeam) return t._s.atWar[otherTeam] == true end
TeamMethods.CanDeclareWar = function(t, otherTeam)
    if t._s.canDeclareWar ~= nil then
        return decide(t._s.canDeclareWar, t, otherTeam, otherTeam)
    end
    if type(otherTeam) ~= "number" or otherTeam < 0 or otherTeam == t._s.id then
        return false
    end
    if t._s.atWar[otherTeam] == true then return false end
    if t._s.peaceTreaty[otherTeam] == true then return false end
    return true
end
TeamMethods.DeclareWar = function(t, otherTeam)
    local w = t._w
    S.recordWrite(w, "DeclareWar", { team = t._s.id, targetTeam = otherTeam })
    w:atWar(t._s.id, otherTeam, true)
end

-- -----------------------------------------------------------------------------
-- 第 11 节：对象元表包装
-- -----------------------------------------------------------------------------

local function makeObjectMeta(methodTable, ownerLabel)
    return {
        __index = function(_, key)
            local fn = methodTable[key]
            if fn ~= nil then return fn end
            return unknownMember(ownerLabel, key)
        end,
    }
end

local PlotMT = makeObjectMeta(PlotMethods, "Plot")
local UnitMT = makeObjectMeta(UnitMethods, "Unit")
local CityMT = makeObjectMeta(CityMethods, "City")
local PlayerMT = makeObjectMeta(PlayerMethods, "Player")
local TeamMT = makeObjectMeta(TeamMethods, "Team")

-- -----------------------------------------------------------------------------
-- 第 12 节：全局引擎对象构造与有状态动作模拟
-- -----------------------------------------------------------------------------

function S.toLocale(key, ...)
    if type(key) ~= "string" then return key end
    local text = S.currentWorld.texts[key]
    if text ~= nil then return text end
    if key:sub(1, 8) ~= "TXT_KEY_" then return key end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    if #parts == 0 then return "<" .. key .. ">" end
    return "<" .. key .. "|" .. table.concat(parts, "|") .. ">"
end

local function rebuildGameInfoTypes(w)
    GameInfoTypes = GameInfoTypes or {}
    for k in pairs(GameInfoTypes) do GameInfoTypes[k] = nil end
    for _, rows in pairs(w.info) do
        for i = 0, rows.n - 1 do
            GameInfoTypes[rows[i].Type] = i
        end
    end
    for i = 0, w.actionRows.n - 1 do
        GameInfoTypes[w.actionRows[i].Type] = i
    end
    GameInfoTypes.CONTROL_ENDTURN = ControlTypes.CONTROL_ENDTURN
end

local function makePlayers(w)
    return setmetatable({}, {
        __index = function(_, index)
            local valid = (
                type(index) == "number"
                and index >= 0
                and index == math.floor(index)
                and index < GameDefines.MAX_PLAYERS
            )
            if not valid then return nil end
            if w.nilPlayerSlots[index] then return nil end
            local player = w.players[index]
            if player ~= nil then return player end
            local dead = w.deadPlayers[index]
            if dead == nil then
                local spec = { id = index, alive = false, team = -1, name = "" }
                dead = setmetatable(
                    { _kind = "player", _w = w, _s = fillDefaults(spec, PLAYER_FIELDS, "player") },
                    PlayerMT
                )
                w.deadPlayers[index] = dead
            end
            return dead
        end,
    })
end

local function makeTeams(w)
    return setmetatable({}, {
        __index = function(_, teamID)
            if type(teamID) == "number" then return w.teams[teamID] end
            return unknownMember("Teams", teamID)
        end,
    })
end

local function makeMap(w)
    local map = {
        GetPlot = function(x, y) return w:getPlot(x, y) end,
        GetPlotXY = function(x, y, dx, dy) return w:getPlot(x + dx, y + dy) end,
        PlotDistance = function(x1, y1, x2, y2) return S.hexDistance(x1, y1, x2, y2) end,
        GetNumPlots = function() return w.width * w.height end,
        GetPlotByIndex = function(index)
            if type(index) ~= "number" or index < 0 or index ~= math.floor(index) then return nil end
            local y = math.floor(index / w.width)
            local x = index - y * w.width
            return w:getPlot(x, y)
        end,
        GetGridSize = function() return w.width, w.height end,
    }
    return setmetatable(map, { __index = function(_, key) return unknownMember("Map", key) end })
end

local function makeUI(w)
    local ui = {
        GetHeadSelectedUnit = function() return w.ui.headUnit end,
        SelectUnit = function(pUnit)
            local plot = nil
            if pUnit ~= nil and pUnit._kind == "unit" then
                plot = pUnit._w:getPlot(pUnit._s.x, pUnit._s.y)
            end
            S.record(w, { name = "SelectUnit", self = pUnit, args = { pUnit }, plot = plot })
            w.ui.headUnit = pUnit
        end,
        ClearSelectionList = function()
            S.record(w, { name = "ClearSelectionList", args = {} })
            w.ui.headUnit = nil
        end,
        SelectCity = function(pCity)
            S.record(w, { name = "SelectCity", self = pCity, args = { pCity } })
            w.ui.headCity = pCity
        end,
        ClearSelectedCities = function()
            S.record(w, { name = "ClearSelectedCities", args = {} })
            w.ui.headCity = nil
        end,
        GetHeadSelectedCity = function() return w.ui.headCity end,
        GetInterfaceMode = function() return w.ui.interfaceMode end,
        CanEndTurn = function() return w.ui.canEndTurn end,
        IsCityScreenUp = function() return w.ui.cityScreenUp == true end,
        UpdateCityScreen = function()
            S.record(w, { name = "UpdateCityScreen", args = {} })
        end,
    }
    return setmetatable(ui, { __index = function(_, key) return unknownMember("UI", key) end })
end

local function applyCombatResult(w, attacker, targetPlot, isMelee)
    local enemy = findPrimaryHostileUnitOnPlot(w, targetPlot, attacker._s.owner)
    local enemyCity = (targetPlot._s.city ~= nil and targetPlot._s.city._s.owner ~= attacker._s.owner)
        and targetPlot._s.city or nil
    local outcome = evalOutcome(attacker._s.combatOutcome, attacker, targetPlot, enemy, enemyCity, isMelee) or {}

    local dmgTarget = outcome.damageToTarget or 30
    local counterDmg = isMelee and (outcome.counterDamage or 15) or 0
    local busyTicks = outcome.busyTicks or 0
    local fightingTicks = outcome.fightingTicks or 0

    attacker._s.moves = 0
    attacker._s.readyToMove = false
    if busyTicks > 0 then attacker._s.busyTicks = busyTicks end
    if fightingTicks > 0 then
        attacker._s.fightingTicks = fightingTicks
        targetPlot._s.fighting = true
        targetPlot._s.fightingTicks = fightingTicks
    end

    if enemy ~= nil then
        if outcome.targetDies == true or (enemy._s.damage + dmgTarget) >= enemy._s.maxHp then
            killUnit(w, enemy)
            if isMelee and enemyCity == nil and outcome.attackerDies ~= true then
                moveUnitToPlot(w, attacker, targetPlot)
            end
        else
            enemy._s.damage = enemy._s.damage + dmgTarget
        end
    elseif enemyCity ~= nil then
        local cityDmg = outcome.cityDamage or dmgTarget
        if outcome.cityDestroyed == true then
            destroyCity(w, enemyCity)
            if isMelee and outcome.attackerDies ~= true then
                moveUnitToPlot(w, attacker, targetPlot)
            end
        elseif outcome.cityCaptured == true or (isMelee and (enemyCity._s.damage + cityDmg) >= enemyCity._s.maxHp) then
            transferCityOwner(w, enemyCity, attacker._s.owner)
            if isMelee and outcome.attackerDies ~= true then
                moveUnitToPlot(w, attacker, targetPlot)
            end
        else
            enemyCity._s.damage = math.min(enemyCity._s.maxHp - 1, enemyCity._s.damage + cityDmg)
        end
    end

    if outcome.attackerDies == true or (attacker._s.damage + counterDmg) >= attacker._s.maxHp then
        killUnit(w, attacker)
    elseif counterDmg > 0 then
        attacker._s.damage = attacker._s.damage + counterDmg
    end
end

local function makeGame(w)
    local game = {
        GetGameTurn = function() return w.turn end,
        IsProcessingMessages = function() return w.processingMessages end,
        GetActivePlayer = function() return w.activePlayer end,
        GetActiveTeam = function() return S.visionTeamOf(w) end,
        IsDebugMode = function() return false end,
        GetResourceUsageType = function(resourceID)
            local row = w.info.Resources[resourceID]
            if row == nil then return -1 end
            return row.usage
        end,
        CanHandleAction = function(iAction, ...)
            local action = w.actionRows[iAction]
            local actionType = action and action.Type or nil
            local head = w.ui.headUnit
            S.record(w, { name = "CanHandleAction", args = { iAction, ... }, actionType = actionType })
            if head == nil or head._s.dead or actionType == nil then return false end
            return head._s.canHandleActions[actionType] == true
        end,
        SelectionListMove = function(pTargetPlot, bShift, bCtrl, bAlt)
            local head = w.ui.headUnit
            S.recordWrite(w, "SelectionListMove", {
                unitID = head and head._s.id or nil,
                x = pTargetPlot and pTargetPlot._s.x or nil,
                y = pTargetPlot and pTargetPlot._s.y or nil,
            })
            if head == nil or head._s.dead or pTargetPlot == nil then return end
            local enemy = findPrimaryHostileUnitOnPlot(w, pTargetPlot, head._s.owner)
            local enemyCity = (pTargetPlot._s.city ~= nil and pTargetPlot._s.city._s.owner ~= head._s.owner)
                and pTargetPlot._s.city or nil
            if enemy ~= nil or enemyCity ~= nil then
                applyCombatResult(w, head, pTargetPlot, true)
            else
                local denom = (GameDefines and GameDefines.MOVE_DENOMINATOR) or 60
                head._s.moves = math.max(0, head._s.moves - denom)
                if head._s.moves == 0 then head._s.readyToMove = false end
                moveUnitToPlot(w, head, pTargetPlot)
                if type(head._s.onMove) == "function" then
                    head._s.onMove(head, pTargetPlot)
                end
            end
            refreshReadyUnitBlocking(w, head._s.owner)
        end,
        SelectionListGameNetMessage = function(eMessage, iData1, iData2, iData3, iFlags, bAlt, bShift)
            local head = w.ui.headUnit
            S.recordWrite(w, "SelectionListGameNetMessage", {
                unitID = head and head._s.id or nil,
                message = eMessage,
                mission = iData1,
                data2 = iData2,
                data3 = iData3,
            })
            if head == nil or head._s.dead then return end
            if iData1 == MissionTypes.MISSION_RANGE_ATTACK or iData1 == MissionTypes.MISSION_MOVE_TO then
                local pTargetPlot = w:getPlot(iData2, iData3)
                if pTargetPlot ~= nil then
                    applyCombatResult(w, head, pTargetPlot, false)
                end
            elseif iData1 == MissionTypes.MISSION_FORTIFY then
                head._s.fortifyTurns = (head._s.fortifyTurns or 0) + 1
                head._s.readyToMove = false
            elseif iData1 == MissionTypes.MISSION_HEAL or iData1 == MissionTypes.MISSION_SKIP then
                head._s.readyToMove = false
            end
            refreshReadyUnitBlocking(w, head._s.owner)
        end,
        HandleAction = function(iAction)
            local head = w.ui.headUnit
            local action = w.actionRows[iAction]
            local actionType = action and action.Type or nil
            S.recordWrite(w, "HandleAction", {
                unitID = head and head._s.id or nil,
                actionIndex = iAction,
                actionType = actionType,
            })
            if head == nil or head._s.dead then return end
            if actionType == "MISSION_FORTIFY" then
                head._s.fortifyTurns = (head._s.fortifyTurns or 0) + 1
                head._s.readyToMove = false
            elseif actionType == "MISSION_SET_UP_FOR_RANGED_ATTACK" then
                local denom = (GameDefines and GameDefines.MOVE_DENOMINATOR) or 60
                head._s.moves = math.max(0, head._s.moves - denom)
                head._s.mustSetUp = false
            else
                head._s.readyToMove = false
            end
            refreshReadyUnitBlocking(w, head._s.owner)
        end,
        SelectedCitiesGameNetMessage = function(eMessage, eTask, tx, ty)
            local city = w.ui.headCity
            local pTargetPlot = w:getPlot(tx, ty)
            S.recordWrite(w, "SelectedCitiesGameNetMessage", {
                cityID = city and city._s.id or nil,
                message = eMessage,
                task = eTask,
                x = tx,
                y = ty,
            })
            if city == nil or pTargetPlot == nil then return end
            city._s.canRangeStrikeNow = false
            local enemy = findPrimaryHostileUnitOnPlot(w, pTargetPlot, city._s.owner)
            local outcome = evalOutcome(city._s.rangedOutcome, city, pTargetPlot, enemy) or {}
            local dmg = outcome.damageToTarget or 35
            local fTicks = outcome.fightingTicks or 0
            if fTicks > 0 then
                pTargetPlot._s.fighting = true
                pTargetPlot._s.fightingTicks = fTicks
            end
            if enemy ~= nil then
                if outcome.targetDies == true or (enemy._s.damage + dmg) >= enemy._s.maxHp then
                    killUnit(w, enemy)
                else
                    enemy._s.damage = enemy._s.damage + dmg
                end
            end
        end,
        CityPurchaseBuilding = function(pCity, bldID, eYield)
            S.recordWrite(w, "CityPurchaseBuilding", {
                cityID = pCity and pCity._s.id or nil,
                buildingID = bldID,
                yieldType = eYield,
            })
            if pCity == nil then return end
            local pPlayer = w.players[pCity._s.owner]
            if eYield == YieldTypes.YIELD_FAITH then
                local cost = pCity:GetBuildingFaithPurchaseCost(bldID)
                if pPlayer ~= nil then pPlayer._s.faith = math.max(0, pPlayer._s.faith - cost) end
            else
                local cost = pCity:GetBuildingPurchaseCost(bldID)
                if pPlayer ~= nil then pPlayer._s.gold = math.max(0, pPlayer._s.gold - cost) end
            end
            pCity._s.realBuildings[bldID] = (pCity._s.realBuildings[bldID] or 0) + 1
            if pCity._s.purchasable and pCity._s.purchasable.buildings then
                pCity._s.purchasable.buildings[bldID] = nil
            end
            if pCity._s.affordable and pCity._s.affordable.buildings then
                pCity._s.affordable.buildings[bldID] = nil
            end
        end,
        CityPurchaseUnit = function(pCity, unitTypeID, eYield)
            S.recordWrite(w, "CityPurchaseUnit", {
                cityID = pCity and pCity._s.id or nil,
                unitTypeID = unitTypeID,
                yieldType = eYield,
            })
            if pCity == nil then return end
            local pPlayer = w.players[pCity._s.owner]
            if eYield == YieldTypes.YIELD_FAITH then
                local cost = pCity:GetUnitFaithPurchaseCost(unitTypeID)
                if pPlayer ~= nil then pPlayer._s.faith = math.max(0, pPlayer._s.faith - cost) end
            else
                local cost = pCity:GetUnitPurchaseCost(unitTypeID)
                if pPlayer ~= nil then pPlayer._s.gold = math.max(0, pPlayer._s.gold - cost) end
            end
            w:addUnit({
                owner = pCity._s.owner,
                unitType = unitTypeID,
                x = pCity._s.x,
                y = pCity._s.y,
                moves = 0,
                readyToMove = false,
            })
        end,
        CityPushOrder = function(pCity, eOrder, iData, bAlt, bShift, bCtrl)
            S.recordWrite(w, "CityPushOrder", {
                cityID = pCity and pCity._s.id or nil,
                orderType = eOrder,
                data = iData,
                clearQueue = bShift,
            })
            if pCity == nil then return end
            local row = nil
            local isProc = false
            if eOrder == OrderTypes.ORDER_CONSTRUCT then
                row = w.info.Buildings[iData]
            elseif eOrder == OrderTypes.ORDER_TRAIN then
                row = w.info.Units[iData]
            elseif eOrder == OrderTypes.ORDER_CREATE then
                row = w.info.Projects[iData]
            elseif eOrder == OrderTypes.ORDER_MAINTAIN then
                row = w.info.Processes[iData]
                isProc = true
            end
            if bShift == true then
                pCity._s.orderQueueLength = 1
            else
                pCity._s.orderQueueLength = (pCity._s.orderQueueLength or 0) + 1
            end
            pCity._s.isProduction = true
            pCity._s.isProductionProcess = isProc
            pCity._s.productionTurnsLeft = isProc and 0 or 5
            pCity._s.productionNameKey = (row and (row.Description or row.Type)) or tostring(iData)
        end,
        DoControl = function(eControl)
            S.recordWrite(w, "DoControl", { control = eControl })
            if eControl == GameInfoTypes.CONTROL_ENDTURN then
                w.endTurnRequested = true
            end
        end,
    }
    return setmetatable(game, { __index = function(_, key) return unknownMember("Game", key) end })
end

local function makeNetwork(w)
    local net = {
        SendCityBuyPlot = function(cityID, x, y)
            S.recordWrite(w, "SendCityBuyPlot", { cityID = cityID, x = x, y = y })
            local pPlayer = w.players[w.activePlayer]
            local pCity = pPlayer and pPlayer:GetCityByID(cityID) or nil
            local pPlot = w:getPlot(x, y)
            if pCity == nil or pPlot == nil then return end
            local cost = pCity:GetBuyPlotCost(x, y)
            if (w.plotBuyDelayTicks or 0) <= 0 then
                pPlayer._s.gold = math.max(0, pPlayer._s.gold - cost)
                pPlot._s.owner = w.activePlayer
            else
                table.insert(w.pendingPlotBuys, {
                    playerID = w.activePlayer,
                    cityID = cityID,
                    x = x,
                    y = y,
                    cost = cost,
                    ticksLeft = w.plotBuyDelayTicks,
                })
            end
        end,
    }
    return setmetatable(net, { __index = function(_, key) return unknownMember("Network", key) end })
end

local function makeEvents(w)
    local function makeEventSink(eventName)
        local fn = function(...)
            S.record(w, { name = "Events." .. eventName, args = { ... } })
        end
        return setmetatable({ Call = fn }, {
            __call = function(_, ...) return fn(...) end,
        })
    end
    local ev = {
        SpecificCityInfoDirty = makeEventSink("SpecificCityInfoDirty"),
    }
    return setmetatable(ev, { __index = function(_, key) return unknownMember("Events", key) end })
end

local function makeGameInfo(w)
    local views = {}
    return setmetatable({}, {
        __index = function(_, name)
            local rows = w.info[name]
            if rows == nil then return unknownMember("GameInfo", name) end
            if views[name] == nil then
                local tableName = name
                views[name] = newInfoView(function() return w.info[tableName] end)
            end
            return views[name]
        end,
    })
end

local function installGlobals(w)
    Players = makePlayers(w)
    Teams = makeTeams(w)
    Game = makeGame(w)
    Map = makeMap(w)
    UI = makeUI(w)
    Network = makeNetwork(w)
    Events = makeEvents(w)
    Modding = setmetatable({}, { __index = function(_, key) return unknownMember("Modding", key) end })
    GameInfo = makeGameInfo(w)
    GameInfoActions = newInfoView(function() return w.actionRows end)
    GameInfoTypes = GameInfoTypes or {}
    Locale = {
        ConvertTextKey = function(key, ...) return S.toLocale(key, ...) end,
        Lookup = function(key, ...) return S.toLocale(key, ...) end,
    }
    rebuildGameInfoTypes(w)
end

-- -----------------------------------------------------------------------------
-- 第 13 节：合成世界构建器、动画帧推进与日志/红线审计方法
-- -----------------------------------------------------------------------------

local WorldMethods = {}
local WorldMT = { __index = WorldMethods }

local function newPlot(w, x, y)
    local s = {
        x = x, y = y,
        terrain = 0, feature = -1, hills = false, river = false, mountain = false,
        impassable = false, fighting = false, fightingTicks = 0,
        improvement = -1, resource = -1, resourceKnownBy = nil, owner = -1,
        revealed = {}, visible = {}, units = {}, city = nil,
        isVisibleEnemyUnit = nil, isEnemyCity = nil,
    }
    return setmetatable({ _kind = "plot", _w = w, _s = s }, PlotMT)
end

local function resolveType(w, tableName, value)
    if type(value) == "number" then return value end
    local rows = w.info[tableName]
    if rows ~= nil then
        for i = 0, rows.n - 1 do
            if rows[i].Type == value then return i end
        end
    end
    error("GameInfo." .. tableName .. " 中不存在 Type=" .. tostring(value), 3)
end

local function override(target, key, value)
    if value ~= nil then target[key] = value end
end

local function assertOwnerAlive(w, owner, label)
    local player = w.players[owner]
    if player == nil or not player._s.alive then
        error(label .. "：玩家 " .. tostring(owner) .. " 不存在或已死亡", 3)
    end
end

function WorldMethods:getPlot(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local row = self.plots[y]
    if row == nil then return nil end
    return row[x]
end

function WorldMethods:addTeam(spec)
    local s = fillDefaults(spec, TEAM_FIELDS, "team")
    if s.id == nil then error("addTeam 必须提供 id", 2) end
    local team = setmetatable({ _kind = "team", _w = self, _s = s }, TeamMT)
    self.teams[s.id] = team
    return team
end

function WorldMethods:ensureTeam(teamID)
    local team = self.teams[teamID]
    if team == nil then team = self:addTeam({ id = teamID }) end
    return team
end

function WorldMethods:atWar(teamA, teamB, flag)
    if flag == nil then flag = true end
    local a = self:ensureTeam(teamA)
    local b = self:ensureTeam(teamB)
    a._s.atWar[teamB] = flag or nil
    b._s.atWar[teamA] = flag or nil
end

function WorldMethods:setPeaceTreaty(teamA, teamB, flag)
    if flag == nil then flag = true end
    local a = self:ensureTeam(teamA)
    local b = self:ensureTeam(teamB)
    a._s.peaceTreaty[teamB] = flag or nil
    b._s.peaceTreaty[teamA] = flag or nil
end

function WorldMethods:addPlayer(spec)
    local s = fillDefaults(spec, PLAYER_FIELDS, "player")
    if s.id == nil then
        s.id = self.nextPlayerID
        self.nextPlayerID = self.nextPlayerID + 1
    end
    self.nilPlayerSlots[s.id] = nil
    local player = setmetatable({ _kind = "player", _w = self, _s = s }, PlayerMT)
    self.players[s.id] = player
    if s.alive then self:ensureTeam(s.team) end
    return player
end

function WorldMethods:setPlayer(playerID, patch)
    local player = self.players[playerID]
    if player == nil then error("setPlayer：玩家 " .. tostring(playerID) .. " 不存在", 2) end
    applyPatch(player._s, patch, PLAYER_FIELDS, "player")
    if player._s.alive then self:ensureTeam(player._s.team) end
    return player
end

function WorldMethods:setNilPlayerSlot(playerID, flag)
    if flag == nil then flag = true end
    self.nilPlayerSlots[playerID] = flag or nil
end

function WorldMethods:addUnit(spec)
    local s = fillDefaults(spec, UNIT_FIELDS, "unit")
    if s.owner == nil then error("addUnit 必须提供 owner", 2) end
    assertOwnerAlive(self, s.owner, "addUnit")
    if s.x == nil or s.y == nil then error("addUnit 必须提供 x、y", 2) end
    local plot = self:getPlot(s.x, s.y)
    if plot == nil then error("addUnit：坐标越界", 2) end
    if s.unitType == nil then error("addUnit 必须提供 unitType", 2) end
    s.unitType = resolveType(self, "Units", s.unitType)
    local row = self.info.Units[s.unitType]

    if s.nameKey == nil then s.nameKey = row.Description end
    if s.domain == nil then s.domain = ENUMS.DomainTypes[row.Domain] or ENUMS.DomainTypes.DOMAIN_LAND end
    if s.combat == nil then s.combat = row.Combat or 0 end
    if s.rangedCombat == nil then s.rangedCombat = row.RangedCombat or 0 end
    if s.range == nil then s.range = row.Range or 0 end
    if s.maxMoves == nil then s.maxMoves = (row.Moves or 0) * GameDefines.MOVE_DENOMINATOR end
    if s.moves == nil then s.moves = s.maxMoves end
    if s.maxHp == nil then s.maxHp = GameDefines.MAX_HIT_POINTS end
    if s.isCombat == nil then s.isCombat = (s.combat > 0 or s.rangedCombat > 0) end

    local owned = self.unitsByPlayer[s.owner]
    if owned == nil then
        owned = {}
        self.unitsByPlayer[s.owner] = owned
    end
    if s.id == nil then s.id = self.nextUnitID[s.owner] or 0 end
    for _, existing in ipairs(owned) do
        if existing._s.id == s.id then
            error("addUnit：单位 ID 重复 " .. tostring(s.id), 2)
        end
    end
    self.nextUnitID[s.owner] = math.max(self.nextUnitID[s.owner] or 0, s.id + 1)

    local unit = setmetatable({ _kind = "unit", _w = self, _s = s }, UnitMT)
    table.insert(owned, unit)
    table.insert(plot._s.units, unit)
    return unit
end

function WorldMethods:setUnit(unit, patch)
    if unit == nil or unit._kind ~= "unit" then error("setUnit：首个参数必须是单位", 2) end
    local oldX, oldY = unit._s.x, unit._s.y
    applyPatch(unit._s, patch, UNIT_FIELDS, "unit")
    if unit._s.x ~= oldX or unit._s.y ~= oldY then
        local newPlot = self:getPlot(unit._s.x, unit._s.y)
        if newPlot == nil then error("setUnit：新坐标越界", 2) end
        local oldPlot = self:getPlot(oldX, oldY)
        if oldPlot ~= nil then
            for i = #oldPlot._s.units, 1, -1 do
                if oldPlot._s.units[i] == unit then table.remove(oldPlot._s.units, i) end
            end
        end
        table.insert(newPlot._s.units, unit)
    end
    return unit
end

function WorldMethods:addCity(spec)
    local s = fillDefaults(spec, CITY_FIELDS, "city")
    if s.owner == nil then error("addCity 必须提供 owner", 2) end
    assertOwnerAlive(self, s.owner, "addCity")
    if s.x == nil or s.y == nil then error("addCity 必须提供 x、y", 2) end
    local plot = self:getPlot(s.x, s.y)
    if plot == nil or plot._s.city ~= nil then error("addCity：坐标非法或已有城市", 2) end

    local owned = self.citiesByPlayer[s.owner]
    if owned == nil then
        owned = {}
        self.citiesByPlayer[s.owner] = owned
    end
    if s.id == nil then s.id = self.nextCityID[s.owner] or 0 end
    self.nextCityID[s.owner] = math.max(self.nextCityID[s.owner] or 0, s.id + 1)
    if s.name == nil then s.name = "City" .. s.id end
    if #s.cityPlots == 0 then s.cityPlots = { { x = s.x, y = s.y } } end

    local city = setmetatable({ _kind = "city", _w = self, _s = s }, CityMT)
    table.insert(owned, city)
    plot._s.city = city
    if plot._s.owner == -1 then plot._s.owner = s.owner end
    return city
end

function WorldMethods:setCity(city, patch)
    if city == nil or city._kind ~= "city" then error("setCity：首个参数必须是城市", 2) end
    applyPatch(city._s, patch, CITY_FIELDS, "city")
    return city
end

function WorldMethods:setPlot(x, y, spec)
    local plot = self:getPlot(x, y)
    if plot == nil then error("setPlot：坐标越界", 2) end
    local s = fillDefaults(spec, PLOT_FIELDS, "plot")
    local p = plot._s
    if s.terrain ~= nil then p.terrain = resolveType(self, "Terrains", s.terrain) end
    if s.feature ~= nil then p.feature = (s.feature == false) and -1 or resolveType(self, "Features", s.feature) end
    if s.improvement ~= nil then p.improvement = (s.improvement == false) and -1 or resolveType(self, "Improvements", s.improvement) end
    if s.resource ~= nil then p.resource = (s.resource == false) and -1 or resolveType(self, "Resources", s.resource) end
    override(p, "resourceKnownBy", s.resourceKnownBy)
    override(p, "hills", s.hills)
    override(p, "river", s.river)
    override(p, "mountain", s.mountain)
    override(p, "impassable", s.impassable)
    override(p, "fighting", s.fighting)
    override(p, "fightingTicks", s.fightingTicks)
    override(p, "owner", s.owner)
    override(p, "isVisibleEnemyUnit", s.isVisibleEnemyUnit)
    override(p, "isEnemyCity", s.isEnemyCity)
    if s.revealed ~= nil then
        for team, flag in pairs(s.revealed) do self:reveal(team, x, y, flag) end
    end
    if s.visible ~= nil then
        for team, flag in pairs(s.visible) do self:show(team, x, y, flag) end
    end
    return plot
end

function WorldMethods:show(team, x, y, flag)
    if flag == nil then flag = true end
    local plot = self:getPlot(x, y)
    if plot ~= nil then
        plot._s.visible[team] = flag or nil
        if flag then plot._s.revealed[team] = true end
    end
end

function WorldMethods:reveal(team, x, y, flag)
    if flag == nil then flag = true end
    local plot = self:getPlot(x, y)
    if plot ~= nil then
        plot._s.revealed[team] = flag or nil
        if not flag then plot._s.visible[team] = nil end
    end
end

function WorldMethods:revealAll(team)
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do self:reveal(team, x, y) end
    end
end

function WorldMethods:showAll(team)
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do self:show(team, x, y) end
    end
end

function WorldMethods:select(unit) self.ui.headUnit = unit end
function WorldMethods:clearSelection() self.ui.headUnit = nil end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:tickSettlement(steps)
-- 做什么：推进指定数量的动画与网络结算帧，递减单位/地块忙碌倒计时并落地待生效买地请求。
-- 为什么：用于模拟两段式异步结算循环（IsSettlementBusy -> 等待 -> FinalizeActionSettlement）。
-- 输入：steps（可选正整数，默认 1）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function WorldMethods:tickSettlement(steps)
    local n = steps or 1
    for _ = 1, n do
        for _, list in pairs(self.unitsByPlayer) do
            for _, u in ipairs(list) do
                if (u._s.busyTicks or 0) > 0 then u._s.busyTicks = u._s.busyTicks - 1 end
                if (u._s.fightingTicks or 0) > 0 then u._s.fightingTicks = u._s.fightingTicks - 1 end
            end
        end
        for y = 0, self.height - 1 do
            for x = 0, self.width - 1 do
                local p = self.plots[y][x]._s
                if (p.fightingTicks or 0) > 0 then
                    p.fightingTicks = p.fightingTicks - 1
                    if p.fightingTicks == 0 then p.fighting = false end
                end
            end
        end
        for i = #self.pendingPlotBuys, 1, -1 do
            local req = self.pendingPlotBuys[i]
            req.ticksLeft = req.ticksLeft - 1
            if req.ticksLeft <= 0 then
                local pPlayer = self.players[req.playerID]
                local pPlot = self:getPlot(req.x, req.y)
                if pPlayer ~= nil then
                    pPlayer._s.gold = math.max(0, pPlayer._s.gold - req.cost)
                end
                if pPlot ~= nil then
                    pPlot._s.owner = req.playerID
                end
                table.remove(self.pendingPlotBuys, i)
            end
        end
    end
end

function WorldMethods:logOf(names)
    local wanted = {}
    for _, name in ipairs(normalizeNameList(names)) do wanted[name] = true end
    local out = {}
    for _, entry in ipairs(self.log) do
        if wanted[entry.name] then table.insert(out, entry) end
    end
    return out
end

function WorldMethods:logCount(names) return #self:logOf(names) end

function WorldMethods:queriesOnForbiddenFog(names)
    local out = {}
    for _, entry in ipairs(self:logOf(names)) do
        if entry.x ~= nil and entry.visible ~= true then
            local allowedFogHostileCity = (entry.revealed == true and entry.isHostileCity == true)
            if not allowedFogHostileCity then table.insert(out, entry) end
        end
    end
    return out
end

function WorldMethods:writeCount(kind)
    if kind == nil then return #self.writeLog end
    local n = 0
    for _, entry in ipairs(self.writeLog) do
        if entry.kind == kind then n = n + 1 end
    end
    return n
end

function WorldMethods:clearWriteLog() self.writeLog = {} end
function WorldMethods:clearLog() self.log = {} end

-- -----------------------------------------------------------------------------
-- 第 14 节：世界创建与用例边界管理（beginCase / endCase）
-- -----------------------------------------------------------------------------

local WORLD_OPTION_FIELDS = fieldSet({
    "width", "height", "activePlayer", "turn", "processingMessages", "canEndTurn",
    "plotBuyDelayTicks", "cityScreenUp", "gameDefines",
    "teams", "players", "wars", "revealAll", "visibleAll", "units", "cities", "select",
}, {
    width = 24, height = 20, activePlayer = 0, turn = 1, processingMessages = false,
    canEndTurn = true, plotBuyDelayTicks = 1, cityScreenUp = false,
})

local ALLOWED_CASE_GLOBALS = {
    CAB_Config = true,
    CAB_Collector = true,
    CAB_Executor = true,
}

S.worlds = {}
S.currentWorld = nil

local function globalNames()
    local names = {}
    for name in pairs(_G) do names[name] = true end
    return names
end

function S.newWorld(opts)
    local o = fillDefaults(opts, WORLD_OPTION_FIELDS, "newWorld")
    local w = {
        width = o.width,
        height = o.height,
        plots = {},
        players = {},
        deadPlayers = {},
        nilPlayerSlots = {},
        teams = {},
        unitsByPlayer = {},
        citiesByPlayer = {},
        nextUnitID = {},
        nextCityID = {},
        nextPlayerID = 0,
        info = {},
        actionRows = copyRows(DEFAULT_ACTION_ROWS),
        activePlayer = o.activePlayer,
        turn = o.turn,
        processingMessages = o.processingMessages,
        plotBuyDelayTicks = o.plotBuyDelayTicks,
        pendingPlotBuys = {},
        endTurnRequested = false,
        ui = {
            headUnit = nil,
            headCity = nil,
            interfaceMode = InterfaceModeTypes.INTERFACEMODE_SELECTION,
            canEndTurn = o.canEndTurn,
            cityScreenUp = o.cityScreenUp,
        },
        log = {},
        writeLog = {},
        texts = {},
    }
    setmetatable(w, WorldMT)

    for name, rows in pairs(DEFAULT_INFO_ROWS) do
        w.info[name] = copyRows(rows)
    end
    for y = 0, w.height - 1 do
        w.plots[y] = {}
        for x = 0, w.width - 1 do
            w.plots[y][x] = newPlot(w, x, y)
        end
    end

    S.resetGameDefines(o.gameDefines)
    installGlobals(w)
    S.currentWorld = w

    for _, teamSpec in ipairs(o.teams or {}) do w:addTeam(teamSpec) end
    for _, playerSpec in ipairs(o.players or {}) do w:addPlayer(playerSpec) end
    for _, warPair in ipairs(o.wars or {}) do w:atWar(warPair[1], warPair[2], true) end
    if o.revealAll ~= nil then w:revealAll(o.revealAll) end
    if o.visibleAll ~= nil then w:showAll(o.visibleAll) end
    for _, unitSpec in ipairs(o.units or {}) do w:addUnit(unitSpec) end
    for _, citySpec in ipairs(o.cities or {}) do w:addCity(citySpec) end
    w:select(o.select)

    table.insert(S.worlds, w)
    return w
end

function S.beginCase()
    S.worlds = {}
    S.prints = {}
    S.newWorld()
    S.marks = {
        violations = #S.guard.violations,
        missing = #S.guard.missing,
        globals = globalNames(),
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
    for name in pairs(globalNames()) do
        if not S.marks.globals[name] and not ALLOWED_CASE_GLOBALS[name] then
            table.insert(addedGlobals, name)
        end
    end
    if #addedGlobals > 0 then
        table.sort(addedGlobals)
        table.insert(problems, "用例期间新增了非法全局变量：" .. table.concat(addedGlobals, ", "))
    end
    return #problems == 0, table.concat(problems, "\n")
end
