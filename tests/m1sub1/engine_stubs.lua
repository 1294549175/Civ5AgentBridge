-- =============================================================================
-- 文件：tests/m1sub1/engine_stubs.lua
-- 职责：为 M1Sub1（mod/Lua/CAB_InfoCollector.lua）离线验收提供纯净版《文明5：BNW v1.0.3.279》
--       Lua 5.1 引擎桩、只读守卫与 DLL 避坑红线陷阱、调用日志、战争迷雾侧信道核查及深层世界快照。
-- 依赖：由 tests/run_m1sub1_tests.py 在 lupa.lua51 中加载，依赖 Python 注入的 __py_read_file 回调。
-- 对外契约：
--   * 导出唯一测试框架全局表 CAB_TEST_STUBS（以及模拟 Civ5 引擎的全局符号 Players/Teams/Game/
--     Map/UI/GameInfo/GameInfoActions/GameInfoTypes/GameDefines/Locale/Network/Events/Modding/
--     DomainTypes/YieldTypes/ResourceUsageTypes/InterfaceModeTypes/EndTurnBlockingTypes/include/print）；
--   * 不包含任何 AirRaidLegacyUnits / AirRaidCore 模拟逻辑（决策 D-05）。
--
-- 设计与引擎语义依据（《docs/M1/M1Sub1/M1Sub1工作计划.md》§2、§4、§6 及 BNW 官方 UI 脚本）：
--   1. 只读守卫（A-03）：全部写入类方法（Set*/Send*/Push*/Buy*/Purchase*/Delete*/Destroy*/Kill*/
--      Disband*/Found* 及 DoControl/HandleAction/CityPurchase*/CityPushOrder/SelectionList*/
--      ActivateNotification/RemoveNotification 等）及 Network/Events/Modding 一碰即记录并报错；
--      仅放行临时 UI 选区探测例外 UI.SelectUnit 与 UI.ClearSelectionList（仍记日志）。
--   2. 原版 DLL 避坑红线（A-05）：显式拦截 Unit:CanMoveOrAttackInto，一经调用立即触发违规报错。
--   3. 战争迷雾与防侧信道（F-01 ~ F-06）：
--      * 视野（IsVisible / IsRevealed）、隐形（IsInvisible）与科技资源（GetResourceType(team)）
--        均按队伍严格隔离；
--      * 调用日志同步记录目标格可见性、已探索态及是否为已探索敌对城市格，支持
--        w:queriesOnInvisible() 与 w:queriesOnForbiddenFog()（F-03 专项断言）。
--   4. 深层世界快照（A-03）：S.snapshot(w) 展开全部实体（teams/players/units/cities/plots）的
--      内部状态表 _s（嵌套引用通过 objTag 折叠防循环），检出任何绕过接口的隐蔽写入，不含 UI 选中态。
--   5. 兼容原生 BNW 与 IGE（D-05）：提供 w:setPlayer / w:setUnit / w:setCity 等实时变阵助手
--      （自动作废基线快照），并支持存活/死玩家/nil 三种 Players[i] 槽位形态。
-- =============================================================================

local S = {}
CAB_TEST_STUBS = S

-- -----------------------------------------------------------------------------
-- 第 1 节：枚举常量、GameDefines 与默认 GameInfo 行模板
-- -----------------------------------------------------------------------------

-- 官方 ActionInfoPanel.lua 中的 24 种回合结束阻塞枚举成员名
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
    GameOptionTypes = {
        GAMEOPTION_NO_SCIENCE = 0,
        GAMEOPTION_NO_POLICIES = 1,
        GAMEOPTION_NO_RELIGION = 2,
    },
}

for i, name in ipairs(ENDTURN_BLOCKING_NAMES) do
    ENUMS.EndTurnBlockingTypes[name] = i - 1
end

-- GameDefines 默认常量（对齐 Expansion2/Gameplay/XML/GlobalDefines.xml）
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

-- GameInfo 默认行模板（每个世界独立深拷贝，互不污染）
-- 小写列（water / usage / Movement）为桩内部推导字段，大写列与游戏 SQLite 表结构一致。
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
        {
            Type = "RESOURCE_HORSE",
            Description = "TXT_KEY_RESOURCE_HORSE",
            usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC,
        },
        {
            Type = "RESOURCE_IRON",
            Description = "TXT_KEY_RESOURCE_IRON",
            usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC,
        },
        {
            Type = "RESOURCE_FUR",
            Description = "TXT_KEY_RESOURCE_FUR",
            usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_LUXURY,
        },
        {
            Type = "RESOURCE_WHEAT",
            Description = "TXT_KEY_RESOURCE_WHEAT",
            usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_BONUS,
        },
    },
    Units = {
        {
            Type = "UNIT_WARRIOR", Description = "TXT_KEY_UNIT_WARRIOR", Domain = "DOMAIN_LAND",
            Combat = 8, RangedCombat = 0, Range = 0, Moves = 2,
        },
        {
            Type = "UNIT_ARCHER", Description = "TXT_KEY_UNIT_ARCHER", Domain = "DOMAIN_LAND",
            Combat = 5, RangedCombat = 9, Range = 2, Moves = 2,
        },
        {
            Type = "UNIT_SETTLER", Description = "TXT_KEY_UNIT_SETTLER", Domain = "DOMAIN_LAND",
            Combat = 0, RangedCombat = 0, Range = 0, Moves = 2,
        },
        {
            Type = "UNIT_WORKER", Description = "TXT_KEY_UNIT_WORKER", Domain = "DOMAIN_LAND",
            Combat = 0, RangedCombat = 0, Range = 0, Moves = 2,
        },
        {
            Type = "UNIT_CATAPULT", Description = "TXT_KEY_UNIT_CATAPULT", Domain = "DOMAIN_LAND",
            Combat = 7, RangedCombat = 11, Range = 2, Moves = 2,
        },
        {
            Type = "UNIT_TRIREME", Description = "TXT_KEY_UNIT_TRIREME", Domain = "DOMAIN_SEA",
            Combat = 10, RangedCombat = 0, Range = 0, Moves = 4,
        },
        {
            Type = "UNIT_GALLEASS", Description = "TXT_KEY_UNIT_GALLEASS", Domain = "DOMAIN_SEA",
            Combat = 12, RangedCombat = 13, Range = 2, Moves = 4,
        },
        {
            Type = "UNIT_FIGHTER", Description = "TXT_KEY_UNIT_FIGHTER", Domain = "DOMAIN_AIR",
            Combat = 0, RangedCombat = 0, Range = 8, Moves = 2,
        },
    },
    Buildings = {
        { Type = "BUILDING_MONUMENT", Description = "TXT_KEY_BUILDING_MONUMENT" },
        { Type = "BUILDING_GRANARY",  Description = "TXT_KEY_BUILDING_GRANARY" },
        { Type = "BUILDING_WALLS",    Description = "TXT_KEY_BUILDING_WALLS" },
        { Type = "BUILDING_PALACE",   Description = "TXT_KEY_BUILDING_PALACE" },
    },
    Eras = {
        { Type = "ERA_ANCIENT",     Description = "TXT_KEY_ERA_ANCIENT" },
        { Type = "ERA_CLASSICAL",   Description = "TXT_KEY_ERA_CLASSICAL" },
        { Type = "ERA_MEDIEVAL",    Description = "TXT_KEY_ERA_MEDIEVAL" },
        { Type = "ERA_RENAISSANCE", Description = "TXT_KEY_ERA_RENAISSANCE" },
        { Type = "ERA_INDUSTRIAL",  Description = "TXT_KEY_ERA_INDUSTRIAL" },
        { Type = "ERA_MODERN",      Description = "TXT_KEY_ERA_MODERN" },
    },
    Technologies = {
        { Type = "TECH_AGRICULTURE",      Description = "TXT_KEY_TECH_AGRICULTURE",      Era = "ERA_ANCIENT", Cost = 20,   GridX = 0, GridY = 5 },
        { Type = "TECH_POTTERY",          Description = "TXT_KEY_TECH_POTTERY",          Era = "ERA_ANCIENT", Cost = 35,   GridX = 1, GridY = 1 },
        { Type = "TECH_ANIMAL_HUSBANDRY", Description = "TXT_KEY_TECH_ANIMAL_HUSBANDRY", Era = "ERA_ANCIENT", Cost = 35,   GridX = 1, GridY = 4 },
        { Type = "TECH_ARCHERY",          Description = "TXT_KEY_TECH_ARCHERY",          Era = "ERA_ANCIENT", Cost = 35,   GridX = 1, GridY = 6 },
        { Type = "TECH_MINING",           Description = "TXT_KEY_TECH_MINING",           Era = "ERA_ANCIENT", Cost = 35,   GridX = 1, GridY = 8 },
        { Type = "TECH_WRITING",          Description = "TXT_KEY_TECH_WRITING",          Era = "ERA_ANCIENT", Cost = 55,   GridX = 2, GridY = 2 },
        { Type = "TECH_FUTURE_TECH",      Description = "TXT_KEY_TECH_FUTURE_TECH",      Era = "ERA_MODERN",  Cost = 9500, GridX = 17, GridY = 5, Repeat = true },
    },
    PolicyBranchTypes = {
        { Type = "POLICY_BRANCH_TRADITION",   Description = "TXT_KEY_POLICY_BRANCH_TRADITION",   Help = "TXT_KEY_POLICY_BRANCH_TRADITION_HELP" },
        { Type = "POLICY_BRANCH_LIBERTY",     Description = "TXT_KEY_POLICY_BRANCH_LIBERTY",     Help = "TXT_KEY_POLICY_BRANCH_LIBERTY_HELP" },
        { Type = "POLICY_BRANCH_HONOR",       Description = "TXT_KEY_POLICY_BRANCH_HONOR",       Help = "TXT_KEY_POLICY_BRANCH_HONOR_HELP" },
        { Type = "POLICY_BRANCH_PIETY",       Description = "TXT_KEY_POLICY_BRANCH_PIETY",       Help = "TXT_KEY_POLICY_BRANCH_PIETY_HELP", LockedWithoutReligion = true },
        { Type = "POLICY_BRANCH_RATIONALISM", Description = "TXT_KEY_POLICY_BRANCH_RATIONALISM", Help = "TXT_KEY_POLICY_BRANCH_RATIONALISM_HELP", EraPrereq = "ERA_RENAISSANCE" },
        { Type = "POLICY_BRANCH_FREEDOM",     Description = "TXT_KEY_POLICY_BRANCH_FREEDOM",     Help = "TXT_KEY_POLICY_BRANCH_FREEDOM_HELP", PurchaseByLevel = true },
    },
    Policies = {
        { Type = "POLICY_TRADITION",         Description = "TXT_KEY_POLICY_TRADITION",         Help = "TXT_KEY_POLICY_TRADITION_HELP" },
        { Type = "POLICY_ARISTOCRACY",       Description = "TXT_KEY_POLICY_ARISTOCRACY",       Help = "TXT_KEY_POLICY_ARISTOCRACY_HELP",       PolicyBranchType = "POLICY_BRANCH_TRADITION" },
        { Type = "POLICY_OLIGARCHY",         Description = "TXT_KEY_POLICY_OLIGARCHY",         Help = "TXT_KEY_POLICY_OLIGARCHY_HELP",         PolicyBranchType = "POLICY_BRANCH_TRADITION" },
        { Type = "POLICY_LEGALISM",          Description = "TXT_KEY_POLICY_LEGALISM",          Help = "TXT_KEY_POLICY_LEGALISM_HELP",          PolicyBranchType = "POLICY_BRANCH_TRADITION" },
        { Type = "POLICY_REPUBLIC",          Description = "TXT_KEY_POLICY_REPUBLIC",          Help = "TXT_KEY_POLICY_REPUBLIC_HELP",          PolicyBranchType = "POLICY_BRANCH_LIBERTY" },
        { Type = "POLICY_AVANT_GARDE",       Description = "TXT_KEY_POLICY_AVANT_GARDE",       Help = "TXT_KEY_POLICY_AVANT_GARDE_HELP",       PolicyBranchType = "POLICY_BRANCH_FREEDOM", Level = 1 },
        { Type = "POLICY_UNIVERSAL_SUFFRAGE",Description = "TXT_KEY_POLICY_UNIVERSAL_SUFFRAGE",Help = "TXT_KEY_POLICY_UNIVERSAL_SUFFRAGE_HELP",PolicyBranchType = "POLICY_BRANCH_FREEDOM", Level = 2 },
    },
    UnitPromotions = {
        { Type = "PROMOTION_SHOCK_1",     Description = "TXT_KEY_PROMOTION_SHOCK_1",     Help = "TXT_KEY_PROMOTION_SHOCK_1_HELP" },
        { Type = "PROMOTION_DRILL_1",     Description = "TXT_KEY_PROMOTION_DRILL_1",     Help = "TXT_KEY_PROMOTION_DRILL_1_HELP" },
        { Type = "PROMOTION_SHOCK_2",     Description = "TXT_KEY_PROMOTION_SHOCK_2",     Help = "TXT_KEY_PROMOTION_SHOCK_2_HELP" },
        { Type = "PROMOTION_INSTA_HEAL",  Description = "TXT_KEY_PROMOTION_INSTA_HEAL",  Help = "TXT_KEY_PROMOTION_INSTA_HEAL_HELP", InstaHeal = true },
        { Type = "PROMOTION_EMBARKATION", Description = "TXT_KEY_PROMOTION_EMBARKATION", Help = "TXT_KEY_PROMOTION_EMBARKATION_HELP", CannotBeChosen = true },
    },
}

local DEFAULT_ACTION_ROWS = {
    { Type = "MISSION_FORTIFY",                  SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_ALERT",                    SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_HEAL",                     SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SKIP",                     SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SET_UP_FOR_RANGED_ATTACK", SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
}

-- -----------------------------------------------------------------------------
-- 第 2 节：基础工具函数
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：keyOf(x, y)
-- 做什么：将坐标 (x, y) 拼装为 "x:y" 字符串键。
-- 为什么：用于按目标坐标查表的判定配置与已探索地块集合键对齐。
-- 输入：x, y（坐标数值）。
-- 输出：字符串 "x:y"。
-- -----------------------------------------------------------------------------
local function keyOf(x, y)
    return tostring(x) .. ":" .. tostring(y)
end
S.keyOf = keyOf

-- -----------------------------------------------------------------------------
-- 函数：deepCopy(v)
-- 做什么：递归深拷贝普通 Lua 表；对带 _kind 的桩对象及函数/基础类型保持原引用返回。
-- 为什么：确保各世界与对象间不共享普通配置表，同时保留对象身份引用（如城市驻军单位）。
-- 输入：v（任意 Lua 值）。
-- 输出：拷贝结果。
-- -----------------------------------------------------------------------------
local function deepCopy(v)
    if type(v) ~= "table" or v._kind ~= nil then return v end
    local out = {}
    for k, item in pairs(v) do
        out[k] = deepCopy(item)
    end
    return out
end

-- -----------------------------------------------------------------------------
-- 函数：normalizeNameList(names)
-- 做什么：将单个方法名字符串或方法名数组统一规范为数组形式。
-- 为什么：让 w:logOf / w:logCount / w:queriesOnInvisible 同时支持单字符串与数组传参。
-- 输入：names（string 或 string[]）。
-- 输出：string[]。
-- -----------------------------------------------------------------------------
local function normalizeNameList(names)
    if type(names) == "string" then return { names } end
    return names or {}
end

-- -----------------------------------------------------------------------------
-- 函数：decide(value, self, key, ...)
-- 做什么：求值可配置的桩判定字段（支持布尔值、函数回调、或按 "x:y" 索引的字典表）。
-- 为什么：让测试用例能以最简洁的声明式写法模拟 CanRangeStrikeAt / CanMoveThrough 等判定。
-- 输入：value（配置值）、self（调用者桩对象）、key（目标坐标键或 nil）、...（透传实参）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 第 3 节：全局枚举表与 GameDefines 管理
-- -----------------------------------------------------------------------------

DomainTypes = ENUMS.DomainTypes
YieldTypes = ENUMS.YieldTypes
ResourceUsageTypes = ENUMS.ResourceUsageTypes
InterfaceModeTypes = ENUMS.InterfaceModeTypes
EndTurnBlockingTypes = ENUMS.EndTurnBlockingTypes
GameOptionTypes = ENUMS.GameOptionTypes

-- -----------------------------------------------------------------------------
-- 函数：S.resetGameDefines(overrides)
-- 做什么：原地重置全局表 GameDefines 为默认值，并叠加当前世界的覆盖项。
-- 为什么：原地复用同一表引用，避免被测模块顶层缓存 GameDefines 表引用后读到旧用例数据。
-- 输入：overrides（可选键值覆盖表）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function S.resetGameDefines(overrides)
    GameDefines = GameDefines or {}
    for k in pairs(GameDefines) do GameDefines[k] = nil end
    for k, v in pairs(GAME_DEFINES_DEFAULT) do GameDefines[k] = v end
    for k, v in pairs(overrides or {}) do GameDefines[k] = v end
end

-- -----------------------------------------------------------------------------
-- 第 4 节：只读守卫与 DLL 避坑红线陷阱（A-03、A-05）
-- -----------------------------------------------------------------------------

S.guard = { violations = {}, missing = {} }

-- 显式写入类接口名单（对应 M1Sub1工作计划.md §2.1 纯只读红线）
local WRITE_NAMES = {
    SetScriptData = true,
    SetRevealed = true,
    CityPurchaseBuilding = true,
    CityPurchaseUnit = true,
    CityPurchaseProject = true,
    CityPushOrder = true,
    SendCityBuyPlot = true,
    HandleAction = true,
    DoControl = true,
    SelectionListMove = true,
    SelectionListGameNetMessage = true,
    SelectedCitiesGameNetMessage = true,
    ActivateNotification = true,
    RemoveNotification = true,
    PushMission = true,
}

-- 写入类方法名前缀模式
local WRITE_PATTERNS = {
    "^Set[A-Z]",
    "^Send[A-Z]",
    "^Push[A-Z]",
    "^Buy[A-Z]",
    "^Purchase[A-Z]",
    "^Delete[A-Z]",
    "^Destroy[A-Z]",
    "^Kill[A-Z]",
    "^Disband[A-Z]",
    "^Found[A-Z]",
}

-- -----------------------------------------------------------------------------
-- 函数：S.isWriteMethod(name)
-- 做什么：判定方法名是否属于禁止调用的写入类接口。
-- 为什么：保障任何未显式实现的 Set*/Send* 等写入方法均自动落入只读守卫陷阱。
-- 输入：name（方法名字符串）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
function S.isWriteMethod(name)
    if type(name) ~= "string" then return false end
    if WRITE_NAMES[name] then return true end
    for _, pattern in ipairs(WRITE_PATTERNS) do
        if name:match(pattern) then return true end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：makeTrap(ownerLabel, methodName, reasonPrefix)
-- 做什么：构造守卫陷阱函数；被调用时先记入 S.guard.violations 再抛出错误。
-- 为什么：先落账再抛错，即使被测代码用 pcall 吞掉异常，运行器依然能精准捕获违规。
-- 输入：ownerLabel（对象名）、methodName（方法名）、reasonPrefix（可选报错前缀）。
-- 输出：陷阱闭包函数。
-- -----------------------------------------------------------------------------
local function makeTrap(ownerLabel, methodName, reasonPrefix)
    local prefix = reasonPrefix or "[只读守卫] 被测代码禁止调用写入类接口 "
    return function(...)
        table.insert(S.guard.violations, {
            owner = ownerLabel,
            method = methodName,
            args = { ... },
        })
        error(prefix .. ownerLabel .. "." .. methodName .. "()", 2)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：makeMissing(ownerLabel, methodName)
-- 做什么：构造“桩未实现方法”占位函数；被调用时记入 S.guard.missing 并抛错。
-- 为什么：禁止未实现的方法静默返回 nil 掩盖拼写错误或未核实的引擎调用。
-- 输入：ownerLabel（对象名）、methodName（方法名）。
-- 输出：错误闭包函数。
-- -----------------------------------------------------------------------------
local function makeMissing(ownerLabel, methodName)
    return function(...)
        table.insert(S.guard.missing, { owner = ownerLabel, method = methodName })
        error("[引擎桩] 调用了桩未实现的方法 " .. ownerLabel .. "." .. methodName .. "()", 2)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：unknownMember(ownerLabel, key)
-- 做什么：统一分派未定义成员访问：命中写入规则返回陷阱，其余返回未实现报错函数。
-- 输入：ownerLabel（对象名）、key（成员名）。
-- 输出：闭包函数。
-- -----------------------------------------------------------------------------
local function unknownMember(ownerLabel, key)
    if S.isWriteMethod(key) then
        return makeTrap(ownerLabel, key)
    end
    return makeMissing(ownerLabel, key)
end

-- -----------------------------------------------------------------------------
-- 第 5 节：include 垫片与 print 输出捕获
-- -----------------------------------------------------------------------------

S.includeOrder = {}
S.includeCount = {}
S.prints = {}

-- -----------------------------------------------------------------------------
-- 函数：S.hasModule(name)
-- 做什么：探测 mod/Lua/<name>.lua 文件是否存在，不编译也不执行。
-- 为什么：供用例在早期工作包（如 WP1 尚未创建 CAB_InfoCollector.lua）时优雅 skip。
-- 输入：name（模块名，不含 .lua 后缀）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
function S.hasModule(name)
    local src = __py_read_file("mod/Lua/" .. tostring(name) .. ".lua")
    return src ~= nil
end

-- -----------------------------------------------------------------------------
-- 函数：include(name)
-- 做什么：模拟 Civ5 VFS 的 include("<name>")，通过 Python 回调读取 mod/Lua/<name>.lua，
--         以 Lua 5.1 loadstring 编译执行并记录加载次数与顺序。
-- 为什么：项目路径包含空格与撇号，经 Python 读取可避免 C 运行库路径编码问题。
-- 输入：name（模块名，可不带 .lua 扩展名）。
-- 输出：nil（文件不存在或编译失败时直接抛错）。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：print(...)
-- 做什么：接管全局 print，将被测模块日志收拢至 S.prints，仅在用例失败时附带展示。
-- 为什么：保持测试报告输出洁净，同时不丢失失败现场诊断日志。
-- 输入：...（任意打印参数）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    table.insert(S.prints, table.concat(parts, "\t"))
end

-- -----------------------------------------------------------------------------
-- 第 6 节：GameInfo 数据库表视图（0-based 索引 + #view + 迭代器 + 越界空表）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：copyRows(rows)
-- 做什么：深拷贝默认行模板并按 0-based 顺序写入 ID 字段。
-- 输入：rows（1-based 模板数组）。
-- 输出：{ [0] = row0, ..., n = count }。
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

-- -----------------------------------------------------------------------------
-- 函数：newInfoView(getRows)
-- 做什么：构造模拟 Civ5 GameInfo.<Table> / GameInfoActions 的 userdata 视图。
-- 为什么用 newproxy(true)：标准 Lua 5.1 中只有 userdata 支持 __len 元方法，
--         能精确还原官方惯用循环 `for i = 0, #GameInfoActions do` 的行为（含越界返回空表）。
-- 输入：getRows（返回当前行表的闭包函数）。
-- 输出：userdata 视图对象。
-- -----------------------------------------------------------------------------
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
-- 第 7 节：六边形网格几何计算（Odd-r 奇数行右偏半格）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：S.hexDistance(x1, y1, x2, y2)
-- 做什么：计算 Civ5 奇数行右偏（odd-r）偏移坐标下两地块之间的六边形距离。
-- 为什么：与 Map.PlotDistance 语义对齐，支撑半径盘扫描与近战/远程射程判定。
-- 输入：x1, y1, x2, y2（整数坐标）。
-- 输出：非负整数距离（同格 0，相邻 1）。
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

-- -----------------------------------------------------------------------------
-- 第 8 节：调用日志与迷雾侧信道核查支持（F-03）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：S.describe(value)
-- 做什么：将任意值或桩对象格式化为可读标签（如 unit(0:1)、plot(10,5)）。
-- 输入：value（任意值）。
-- 输出：描述字符串。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：S.record(w, entry)
-- 做什么：向世界调用日志追加一条记录，并快照调用发生瞬间目标格对参照队伍的视野与敌城属性。
-- 为什么：迷雾防侧信道红线 F-03 需要核查 CanRangeStrikeAt 是否仅作用于实时可见格或
--         已探索敌对城市格，必须在调用瞬间记录 visible / revealed / isHostileCity。
-- 输入：w（世界对象）、entry（日志表，含 name / args / self / plot 等）。
-- 输出：补齐字段后的 entry。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 第 9 节：深层世界快照与差异定位（A-03）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：sortedKeys(t)
-- 做什么：提取表的全部键并确定性排序（数字键升序在前，字符串键字典序在后）。
-- 为什么：Lua pairs 顺序不确定，快照必须先定序才能逐字节精确比对。
-- 输入：t（表）。
-- 输出：有序键数组。
-- -----------------------------------------------------------------------------
local function sortedKeys(t)
    local numbers, strings = {}, {}
    for k in pairs(t) do
        if type(k) == "number" then
            table.insert(numbers, k)
        else
            table.insert(strings, k)
        end
    end
    table.sort(numbers)
    table.sort(strings)
    for _, s in ipairs(strings) do
        table.insert(numbers, s)
    end
    return numbers
end

-- -----------------------------------------------------------------------------
-- 函数：objTag(v)
-- 做什么：为桩对象生成唯一身份标签，用于在嵌套引用处打断循环引用。
-- 输入：v（桩对象）。
-- 输出：身份标签字符串。
-- -----------------------------------------------------------------------------
local function objTag(v)
    if v._kind == "plot" then
        return "@plot:" .. tostring(v._s.x) .. "," .. tostring(v._s.y)
    end
    if v._kind == "player" or v._kind == "team" then
        return "@" .. v._kind .. ":" .. tostring(v._s.id)
    end
    return "@" .. v._kind .. ":" .. tostring(v._s.owner) .. ":" .. tostring(v._s.id)
end

-- -----------------------------------------------------------------------------
-- 函数：ser(v, seen)
-- 做什么：将基础值或普通表序列化为确定性字符串；遇到嵌套桩对象时折叠为 objTag。
-- 输入：v（任意值）、seen（防循环引用集合）。
-- 输出：规范字符串。
-- -----------------------------------------------------------------------------
local function ser(v, seen)
    local kind = type(v)
    if kind == "number" then
        return string.format("%.17g", v)
    elseif kind == "string" then
        return string.format("%q", v)
    elseif kind == "boolean" then
        return v and "T" or "F"
    elseif kind == "function" then
        return "fn"
    elseif kind == "table" then
        if v._kind ~= nil then return objTag(v) end
        if seen[v] then return "<cycle>" end
        seen[v] = true
        local parts = {}
        for _, k in ipairs(sortedKeys(v)) do
            parts[#parts + 1] = ser(k, seen) .. "=" .. ser(v[k], seen)
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "<" .. kind .. ">"
end

-- -----------------------------------------------------------------------------
-- 函数：serEntity(entity, seen)
-- 做什么：展开单个桩对象的内部状态表 _s 并序列化。
-- 为什么：若直接把桩对象交给 ser() 会只输出 @tag 而漏检实体字段修改；
--         顶层显式展开 _s、内部嵌套引用再用 objTag，兼顾完整检测与无循环引用。
-- 输入：entity（带 _kind 与 _s 的桩对象）、seen（循环保护集合）。
-- 输出：规范字符串。
-- -----------------------------------------------------------------------------
local function serEntity(entity, seen)
    return objTag(entity) .. ":" .. ser(entity._s, seen)
end

-- -----------------------------------------------------------------------------
-- 函数：serEntityMap(tbl, seen) / serEntityListMap(tbl, seen) / serPlots(plots, h, w, seen)
-- 做什么：按确定顺序展开世界内队伍、玩家、单位、城市及全部地块的 _s 状态。
-- 输入：容器表与 seen 集合。
-- 输出：规范字符串。
-- -----------------------------------------------------------------------------
local function serEntityMap(tbl, seen)
    local parts = {}
    for _, k in ipairs(sortedKeys(tbl)) do
        parts[#parts + 1] = ser(k, seen) .. "=" .. serEntity(tbl[k], seen)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function serEntityListMap(tbl, seen)
    local parts = {}
    for _, ownerID in ipairs(sortedKeys(tbl)) do
        local list = tbl[ownerID]
        local items = {}
        for i = 1, #list do
            items[i] = serEntity(list[i], seen)
        end
        parts[#parts + 1] = ser(ownerID, seen) .. "=[" .. table.concat(items, ",") .. "]"
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function serPlots(plots, height, width, seen)
    local parts = {}
    for y = 0, height - 1 do
        local row = plots[y]
        for x = 0, width - 1 do
            parts[#parts + 1] = serEntity(row[x], seen)
        end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- -----------------------------------------------------------------------------
-- 函数：S.snapshot(w)
-- 做什么：对世界全部持久游戏状态（不含 UI 选中态与惰性 deadPlayers 缓存）拍规范快照。
-- 为什么：验证被测只读模块执行前后未篡改任何引擎或世界状态（A-03）。
-- 输入：w（世界对象）。
-- 输出：可逐字节比对的快照字符串。
-- -----------------------------------------------------------------------------
function S.snapshot(w)
    local seen = {}
    local parts = {
        "turn=" .. ser(w.turn, seen),
        "busy=" .. ser(w.processingMessages, seen),
        "active=" .. ser(w.activePlayer, seen),
        "defines=" .. ser(GameDefines, seen),
        "info=" .. ser(w.info, seen),
        "actions=" .. ser(w.actionRows, seen),
        "nilSlots=" .. ser(w.nilPlayerSlots, seen),
        "teams=" .. serEntityMap(w.teams, seen),
        "players=" .. serEntityMap(w.players, seen),
        "units=" .. serEntityListMap(w.unitsByPlayer, seen),
        "cities=" .. serEntityListMap(w.citiesByPlayer, seen),
        "plots=" .. serPlots(w.plots, w.height, w.width, seen),
    }
    return table.concat(parts, "|")
end

-- -----------------------------------------------------------------------------
-- 函数：S.touch(w) / dirty(w)
-- 做什么：S.touch 在世界首次被读取前自动拍下基线快照；dirty 在布置变更时作废基线。
-- 为什么：确保基线永远对应“场景布置完成、被测代码首次读取前”的干净状态。
-- 输入：w（世界对象，可为 nil）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function S.touch(w)
    if w ~= nil and w._snapshot == nil then
        w._snapshot = S.snapshot(w)
    end
end

local function dirty(w)
    if w ~= nil then w._snapshot = nil end
end

-- -----------------------------------------------------------------------------
-- 函数：S.firstDiff(a, b)
-- 做什么：定位两张快照首个不同字符并返回前后上下文片段，便于快速排障。
-- 输入：a（基线快照）、b（当前快照）。
-- 输出：形如 "…基线片段…  =>  …现状片段…" 的对比字符串。
-- -----------------------------------------------------------------------------
function S.firstDiff(a, b)
    local limit = math.min(#a, #b)
    local pos = limit + 1
    for i = 1, limit do
        if string.sub(a, i, i) ~= string.sub(b, i, i) then
            pos = i
            break
        end
    end
    local from = math.max(1, pos - 60)
    local function cut(s) return string.sub(s, from, pos + 60) end
    return "…" .. cut(a) .. "  =>  " .. cut(b)
end

-- -----------------------------------------------------------------------------
-- 第 10 节：对象规格校验与字段清单
-- -----------------------------------------------------------------------------

local NONE = {}

-- -----------------------------------------------------------------------------
-- 函数：fieldSet(names, defaults)
-- 做什么：构建“允许字段名 -> 默认值（或 NONE 哨兵）”规格表。
-- 为什么：允许显式声明缺省为 nil 的字段，同时在 fillDefaults 时拒绝拼写错误的未知键。
-- 输入：names（字段名数组）、defaults（默认值映射）。
-- 输出：规格表。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：fillDefaults(spec, fields, label)
-- 做什么：按规格表填充默认值并应用用户覆盖；若 spec 含未知字段立即抛错。
-- 输入：spec（用户输入表或 nil）、fields（规格表）、label（报错提示前缀）。
-- 输出：填充完成的状态表。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：applyPatch(targetState, patch, fields, label)
-- 做什么：校验并将部分字段更新应用到已有实体状态表（供 IGE 场景变更助手使用）。
-- 输入：targetState（实体 _s 表）、patch（待更新键值）、fields（规格表）、label（报错前缀）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
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

local TEAM_FIELDS = fieldSet({ "id", "atWar", "currentEra", "techs", "techProgress", "techCosts" }, {
    atWar = {},
    currentEra = 0,
    techs = {},
    techProgress = {},
    techCosts = {},
})

local PLAYER_FIELDS = fieldSet({
    "id", "alive", "team", "minor", "barbarian", "human", "name", "civ",
    "turnActive", "goldenAge",
    "gold", "goldRate", "science", "culturePerTurn", "faith", "faithPerTurn", "happiness",
    "resourcesAvailable", "resourcesTotal",
    "blockingType", "blockingNotificationIndex", "notifications",
    "currentResearch", "freeTechs", "overflowResearch", "canResearch", "canResearchForFree",
    "researchProgress", "researchCosts", "researchTurnsLeft",
    "culture", "nextPolicyCost", "freePolicies", "freeTenets", "ideologyBranch",
    "unlockedBranches", "finishedBranches", "blockedBranches", "canUnlockBranch",
    "policies", "blockedPolicies", "canAdoptPolicy", "canAdoptPolicyIgnoreCost",
    "tenets", "availableTenets",
}, {
    alive = true, team = 0, minor = false, barbarian = false, human = true,
    turnActive = true, goldenAge = false,
    gold = 0, goldRate = 0, science = 0, culturePerTurn = 0, faith = 0, faithPerTurn = 0, happiness = 0,
    resourcesAvailable = {}, resourcesTotal = {},
    blockingType = -1, blockingNotificationIndex = -1, notifications = {},
    currentResearch = -1, freeTechs = 0, overflowResearch = 0, canResearch = {},
    researchProgress = {}, researchCosts = {}, researchTurnsLeft = {},
    culture = 0, nextPolicyCost = 25, freePolicies = 0, freeTenets = 0, ideologyBranch = -1,
    unlockedBranches = {}, finishedBranches = {}, blockedBranches = {}, canUnlockBranch = {},
    policies = {}, blockedPolicies = {}, canAdoptPolicy = {}, canAdoptPolicyIgnoreCost = {},
    tenets = {}, availableTenets = {},
})

local UNIT_FIELDS = fieldSet({
    "id", "owner", "unitType", "x", "y", "nameKey",
    "domain", "damage", "maxHp", "moves", "maxMoves",
    "combat", "rangedCombat", "range",
    "fortifyTurns", "readyToMove", "promotionReady", "automated", "delayedDeath", "dead",
    "isCombat", "embarked", "invisibleTo",
    "canRangeStrike", "canRangeStrikeAt", "canMoveThrough", "canAttack", "canFortify", "canHeal",
    "mustSetUp", "everFortifyable", "canHandleActions",
    "level", "experience", "experienceNeeded", "canPromote", "promotions", "availablePromotions",
}, {
    damage = 0, fortifyTurns = 0, promotionReady = false, automated = false, delayedDeath = false,
    dead = false, embarked = false, invisibleTo = {},
    canRangeStrike = false, canRangeStrikeAt = false, canMoveThrough = false,
    canFortify = false, canHeal = false, mustSetUp = false, canHandleActions = {},
    level = 1, experience = 0, experienceNeeded = 10, promotions = {}, availablePromotions = {},
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
})

local PLOT_FIELDS = fieldSet({
    "terrain", "feature", "hills", "river", "mountain", "impassable", "fighting",
    "improvement", "resource", "resourceKnownBy", "owner",
    "revealed", "visible",
    "isVisibleEnemyUnit", "isEnemyCity",
}, {
    feature = -1, hills = false, river = false, mountain = false, impassable = false, fighting = false,
    improvement = -1, resource = -1, owner = -1,
})

-- -----------------------------------------------------------------------------
-- 第 11 节：Plot / Unit / City / Player / Team 方法表
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
PlotMethods.IsFighting = function(p) return p._s.fighting == true end

PlotMethods.GetImprovementType = function(p) return p._s.improvement end
-- F-06：传入 activeTeam 时仅返回该队伍已解锁科技的资源；若未解锁返回 -1
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
UnitMethods.GetCurrHitPoints = function(u) return u._s.maxHp - u._s.damage end
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
UnitMethods.CanPromote = function(u)
    if u._s.canPromote ~= nil then return u._s.canPromote == true end
    return u._s.promotionReady == true
end
UnitMethods.GetLevel = function(u) return u._s.level or 1 end
UnitMethods.GetExperience = function(u) return u._s.experience or 0 end
UnitMethods.ExperienceNeeded = function(u) return u._s.experienceNeeded or 10 end
UnitMethods.IsHasPromotion = function(u, promoId) return u._s.promotions[promoId] == true end
UnitMethods.CanAcquirePromotion = function(u, promoId)
    local row = u._w.info.UnitPromotions and u._w.info.UnitPromotions[promoId] or nil
    if row == nil or row.CannotBeChosen == true then return false end
    if row.InstaHeal ~= true and u._s.promotions[promoId] == true then return false end
    if row.InstaHeal == true and (u._s.damage or 0) <= 0 then return false end
    return decide(u._s.availablePromotions, u, promoId, promoId)
end
UnitMethods.IsAutomated = function(u) return u._s.automated == true end
UnitMethods.IsDelayedDeath = function(u) return u._s.delayedDeath == true end
UnitMethods.IsDead = function(u) return u._s.dead == true end

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

-- A-05 红线：原版 BNW DLL 硬编码返回 false，严禁被测代码调用
UnitMethods.CanMoveOrAttackInto = makeTrap(
    "Unit",
    "CanMoveOrAttackInto",
    "[引擎避坑红线] 严禁调用原版 DLL 缺陷方法 "
)

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

-- -----------------------------------------------------------------------------
-- 函数：purchasePoolEntry(city, bTestVisible, bTestCost, unitID, buildingID, eYield)
-- 做什么：模拟官方 ProductionPopup.lua 双层 IsCanPurchase 判定：
--         (false, false, ...) 查规则候选池；(true, true, ...) 查当前是否买得起/不冲突。
-- 输入：同 City:IsCanPurchase 参数（不含 projectID）。
-- 输出：布尔值或 nil（未知参数组合）。
-- -----------------------------------------------------------------------------
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
PlayerMethods.GetNumCities = function(p)
    local list = p._w.citiesByPlayer[p._s.id]
    return (list ~= nil) and #list or 0
end
PlayerMethods.GetCurrentResearch = function(p) return p._s.currentResearch end
PlayerMethods.GetNumFreeTechs = function(p) return p._s.freeTechs or 0 end
PlayerMethods.GetOverflowResearch = function(p) return p._s.overflowResearch or 0 end
PlayerMethods.CanResearch = function(p, techId)
    local team = p._w.teams[p._s.team]
    local row = p._w.info.Technologies and p._w.info.Technologies[techId] or nil
    if row == nil then return false end
    if team ~= nil and team._s.techs[techId] == true and row.Repeat ~= true then return false end
    return decide(p._s.canResearch, p, techId, techId)
end
PlayerMethods.CanResearchForFree = function(p, techId)
    if p._s.canResearchForFree ~= nil then
        return decide(p._s.canResearchForFree, p, techId, techId)
    end
    return p:CanResearch(techId)
end
PlayerMethods.GetResearchCost = function(p, techId)
    if p._s.researchCosts[techId] ~= nil then return p._s.researchCosts[techId] end
    local team = p._w.teams[p._s.team]
    if team ~= nil and team._s.techCosts[techId] ~= nil then return team._s.techCosts[techId] end
    local row = p._w.info.Technologies and p._w.info.Technologies[techId] or nil
    return (row ~= nil and row.Cost) or 0
end
PlayerMethods.GetResearchProgress = function(p, techId)
    if p._s.researchProgress[techId] ~= nil then return p._s.researchProgress[techId] end
    local team = p._w.teams[p._s.team]
    if team ~= nil and team._s.techProgress[techId] ~= nil then return team._s.techProgress[techId] end
    return 0
end
PlayerMethods.GetResearchTurnsLeft = function(p, techId)
    if p._s.researchTurnsLeft[techId] ~= nil then return p._s.researchTurnsLeft[techId] end
    local sci = p._s.science or 0
    if sci <= 0 then return 0 end
    local rem = math.max(0, p:GetResearchCost(techId) - p:GetResearchProgress(techId))
    return math.max(1, math.ceil(rem / sci))
end
PlayerMethods.GetJONSCulture = function(p) return p._s.culture or 0 end
PlayerMethods.GetNextPolicyCost = function(p) return p._s.nextPolicyCost or 25 end
PlayerMethods.GetNumFreePolicies = function(p) return p._s.freePolicies or 0 end
PlayerMethods.GetNumFreeTenets = function(p) return p._s.freeTenets or 0 end
PlayerMethods.GetLateGamePolicyTree = function(p) return p._s.ideologyBranch or -1 end
PlayerMethods.IsPolicyBranchUnlocked = function(p, branchId) return p._s.unlockedBranches[branchId] == true end
PlayerMethods.IsPolicyBranchFinished = function(p, branchId) return p._s.finishedBranches[branchId] == true end
PlayerMethods.IsPolicyBranchBlocked = function(p, branchId) return p._s.blockedBranches[branchId] == true end
PlayerMethods.CanUnlockPolicyBranch = function(p, branchId)
    if p:GetNumCities() <= 0 then return false end
    if p._s.unlockedBranches[branchId] == true or p._s.blockedBranches[branchId] == true then return false end
    if p._s.canUnlockBranch ~= nil and type(p._s.canUnlockBranch) == "table" and next(p._s.canUnlockBranch) ~= nil then
        return decide(p._s.canUnlockBranch, p, branchId, branchId)
    end
    local branchRow = p._w.info.PolicyBranchTypes and p._w.info.PolicyBranchTypes[branchId] or nil
    if branchRow == nil or branchRow.PurchaseByLevel == true then return false end
    if branchRow.EraPrereq ~= nil and GameInfoTypes[branchRow.EraPrereq] ~= nil then
        local team = p._w.teams[p._s.team]
        if (team and team._s.currentEra or 0) < GameInfoTypes[branchRow.EraPrereq] then return false end
    end
    return (p._s.freePolicies or 0) > 0 or (p._s.culture or 0) >= (p._s.nextPolicyCost or 25)
end
PlayerMethods.HasPolicy = function(p, policyId) return p._s.policies[policyId] == true end
PlayerMethods.IsPolicyBlocked = function(p, policyId) return p._s.blockedPolicies[policyId] == true end
PlayerMethods.CanAdoptPolicy = function(p, policyId, ignoreCost)
    if p:GetNumCities() <= 0 then return false end
    if p._s.policies[policyId] == true or p._s.blockedPolicies[policyId] == true then return false end
    if ignoreCost == true and type(p._s.canAdoptPolicyIgnoreCost) == "table" and next(p._s.canAdoptPolicyIgnoreCost) ~= nil then
        return decide(p._s.canAdoptPolicyIgnoreCost, p, policyId, policyId)
    end
    if type(p._s.canAdoptPolicy) == "table" and next(p._s.canAdoptPolicy) ~= nil then
        if ignoreCost == true then
            return decide(p._s.canAdoptPolicy, p, policyId, policyId)
        end
        return decide(p._s.canAdoptPolicy, p, policyId, policyId)
            and ((p._s.freePolicies or 0) > 0 or (p._s.culture or 0) >= (p._s.nextPolicyCost or 25))
    end
    return false
end
PlayerMethods.GetTenet = function(p, ideologyId, level, index)
    if ideologyId ~= p._s.ideologyBranch then return -1 end
    local lvlTbl = p._s.tenets and p._s.tenets[level] or nil
    if lvlTbl == nil or lvlTbl[index] == nil then return -1 end
    return lvlTbl[index]
end
PlayerMethods.GetAvailableTenets = function(p, level)
    local out = {}
    local list = p._s.availableTenets and p._s.availableTenets[level] or nil
    if type(list) == "table" then
        for _, tid in ipairs(list) do
            if p._s.policies[tid] ~= true then
                table.insert(out, tid)
            end
        end
    end
    return out
end

local TeamMethods = {}

TeamMethods.IsAtWar = function(t, otherTeam) return t._s.atWar[otherTeam] == true end
TeamMethods.GetCurrentEra = function(t) return t._s.currentEra or 0 end
TeamMethods.GetTeamTechs = function(t)
    return setmetatable({
        HasTech = function(_, techId)
            S.touch(t._w)
            return t._s.techs[techId] == true
        end,
        GetResearchCost = function(_, techId)
            S.touch(t._w)
            if t._s.techCosts[techId] ~= nil then return t._s.techCosts[techId] end
            local row = t._w.info.Technologies and t._w.info.Technologies[techId] or nil
            return (row ~= nil and row.Cost) or 0
        end,
        GetResearchProgress = function(_, techId)
            S.touch(t._w)
            return t._s.techProgress[techId] or 0
        end,
    }, { __index = function(_, key) return unknownMember("TeamTechs", key) end })
end

-- -----------------------------------------------------------------------------
-- 第 12 节：对象元表包装（自动触发 S.touch 与只读守卫）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：makeObjectMeta(methodTable, ownerLabel)
-- 做什么：将方法表包装为桩对象元表：每次读方法调用前先触发 S.touch，未知成员走守卫。
-- 输入：methodTable（方法表）、ownerLabel（对象名称）。
-- 输出：元表。
-- -----------------------------------------------------------------------------
local function makeObjectMeta(methodTable, ownerLabel)
    local wrapped = {}
    for name, fn in pairs(methodTable) do
        wrapped[name] = function(self, ...)
            S.touch(self._w)
            return fn(self, ...)
        end
    end
    return {
        __index = function(_, key)
            local fn = wrapped[key]
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
-- 第 13 节：全局引擎对象构造与安装
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：S.playerTeamOf(w, playerID)
-- 做什么：查询指定玩家所属队伍 ID，不存在返回 -1。
-- 输入：w（世界对象）、playerID（玩家编号）。
-- 输出：队伍 ID（整数）。
-- -----------------------------------------------------------------------------
function S.playerTeamOf(w, playerID)
    local p = w.players[playerID]
    if p == nil then return -1 end
    return p._s.team
end

-- -----------------------------------------------------------------------------
-- 函数：S.visionTeamOf(w)
-- 做什么：返回当前世界激活玩家（w.activePlayer）的队伍 ID，作为调用日志参照视野队伍。
-- 输入：w（世界对象）。
-- 输出：队伍 ID（整数）。
-- -----------------------------------------------------------------------------
function S.visionTeamOf(w)
    return S.playerTeamOf(w, w.activePlayer)
end

-- -----------------------------------------------------------------------------
-- 函数：S.toLocale(key, ...)
-- 做什么：模拟 Locale.ConvertTextKey / Lookup；已登记键返回文本，未登记 TXT_KEY_ 键包尖括号。
-- 输入：key（字符串键）、...（可选格式化参数）。
-- 输出：转换后字符串。
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

-- -----------------------------------------------------------------------------
-- 函数：rebuildGameInfoTypes(w)
-- 做什么：按当前世界的全部 GameInfo 与 GameInfoActions 行原地刷新全局 GameInfoTypes。
-- 输入：w（世界对象）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
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
end

-- -----------------------------------------------------------------------------
-- 函数：makePlayers(w)
-- 做什么：构造全局 Players 表，支持存活玩家、未参战死玩家、越界 nil 与显式 nil 槽位。
-- 为什么：覆盖 M1Sub1工作计划.md §2.3 要求的三种槽位形态兼容性验证。
-- 输入：w（世界对象）。
-- 输出：Players 代理表。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：makeTeams(w)
-- 做什么：构造全局 Teams 表，不存在的队伍编号返回 nil。
-- 输入：w（世界对象）。
-- 输出：Teams 代理表。
-- -----------------------------------------------------------------------------
local function makeTeams(w)
    return setmetatable({}, {
        __index = function(_, teamID)
            if type(teamID) == "number" then
                return w.teams[teamID]
            end
            return unknownMember("Teams", teamID)
        end,
    })
end

-- -----------------------------------------------------------------------------
-- 函数：makeMap(w)
-- 做什么：构造全局 Map 对象（GetPlot / GetPlotXY / PlotDistance / GetNumPlots / GetPlotByIndex / GetGridSize）。
-- 输入：w（世界对象）。
-- 输出：Map 代理表。
-- -----------------------------------------------------------------------------
local function makeMap(w)
    local map = {
        GetPlot = function(x, y)
            S.touch(w)
            return w:getPlot(x, y)
        end,
        GetPlotXY = function(x, y, dx, dy)
            S.touch(w)
            return w:getPlot(x + dx, y + dy)
        end,
        PlotDistance = function(x1, y1, x2, y2)
            S.touch(w)
            return S.hexDistance(x1, y1, x2, y2)
        end,
        GetNumPlots = function()
            S.touch(w)
            return w.width * w.height
        end,
        GetPlotByIndex = function(index)
            S.touch(w)
            if type(index) ~= "number" or index < 0 or index ~= math.floor(index) then return nil end
            local y = math.floor(index / w.width)
            local x = index - y * w.width
            return w:getPlot(x, y)
        end,
        GetGridSize = function()
            S.touch(w)
            return w.width, w.height
        end,
    }
    return setmetatable(map, { __index = function(_, key) return unknownMember("Map", key) end })
end

-- -----------------------------------------------------------------------------
-- 函数：makeUI(w)
-- 做什么：构造全局 UI 对象；放行临时选区探测例外 SelectUnit / ClearSelectionList 并记日志；
--         禁止 UI.SetInterfaceMode 等写入方法（走 unknownMember 触发只读守卫）。
-- 输入：w（世界对象）。
-- 输出：UI 代理表。
-- -----------------------------------------------------------------------------
local function makeUI(w)
    local ui = {
        GetHeadSelectedUnit = function()
            S.touch(w)
            return w.ui.headUnit
        end,
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
        GetInterfaceMode = function()
            S.touch(w)
            return w.ui.interfaceMode
        end,
        CanEndTurn = function()
            S.touch(w)
            return w.ui.canEndTurn
        end,
    }
    return setmetatable(ui, { __index = function(_, key) return unknownMember("UI", key) end })
end

-- -----------------------------------------------------------------------------
-- 函数：makeGame(w)
-- 做什么：构造全局 Game 对象；CanHandleAction 基于当前 UI.GetHeadSelectedUnit 判定并记日志。
-- 输入：w（世界对象）。
-- 输出：Game 代理表。
-- -----------------------------------------------------------------------------
local function makeGame(w)
    local game = {
        GetGameTurn = function()
            S.touch(w)
            return w.turn
        end,
        IsProcessingMessages = function()
            S.touch(w)
            return w.processingMessages
        end,
        GetActivePlayer = function()
            S.touch(w)
            return w.activePlayer
        end,
        GetActiveTeam = function()
            S.touch(w)
            return S.visionTeamOf(w)
        end,
        IsDebugMode = function() return false end,
        IsOption = function(optId)
            S.touch(w)
            return w.gameOptions[optId] == true
        end,
        GetResourceUsageType = function(resourceID)
            S.touch(w)
            local row = w.info.Resources[resourceID]
            if row == nil then return -1 end
            return row.usage
        end,
        CanHandleAction = function(iAction, ...)
            S.touch(w)
            local action = w.actionRows[iAction]
            local actionType = nil
            if action ~= nil then actionType = action.Type end
            local head = w.ui.headUnit
            S.record(w, { name = "CanHandleAction", args = { iAction, ... }, actionType = actionType })
            if head == nil or head._s.dead or actionType == nil then return false end
            return head._s.canHandleActions[actionType] == true
        end,
    }
    return setmetatable(game, { __index = function(_, key) return unknownMember("Game", key) end })
end

-- -----------------------------------------------------------------------------
-- 函数：makeGameInfo(w)
-- 做什么：构造全局 GameInfo 代理表，按需为每张已知表创建 userdata 视图；未知表名走守卫。
-- 输入：w（世界对象）。
-- 输出：GameInfo 代理表。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：makeWriteOnlyObject(label)
-- 做什么：构造纯禁入全局对象（Network / Events / Modding），任何成员访问均走守卫。
-- 输入：label（对象名）。
-- 输出：代理表。
-- -----------------------------------------------------------------------------
local function makeWriteOnlyObject(label)
    return setmetatable({}, { __index = function(_, key) return unknownMember(label, key) end })
end

-- -----------------------------------------------------------------------------
-- 函数：installGlobals(w)
-- 做什么：将指定世界对应的全部引擎全局对象安装到 _G。
-- 输入：w（世界对象）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function installGlobals(w)
    Players = makePlayers(w)
    Teams = makeTeams(w)
    Game = makeGame(w)
    Map = makeMap(w)
    UI = makeUI(w)
    GameInfo = makeGameInfo(w)
    GameInfoActions = newInfoView(function() return w.actionRows end)
    GameInfoTypes = GameInfoTypes or {}
    Network = makeWriteOnlyObject("Network")
    Events = makeWriteOnlyObject("Events")
    Modding = makeWriteOnlyObject("Modding")
    Locale = {
        ConvertTextKey = function(key, ...)
            S.touch(w)
            return S.toLocale(key, ...)
        end,
        Lookup = function(key, ...)
            S.touch(w)
            return S.toLocale(key, ...)
        end,
    }
    rebuildGameInfoTypes(w)
end

-- -----------------------------------------------------------------------------
-- 第 14 节：合成世界构建器与 IGE 实时变阵助手
-- -----------------------------------------------------------------------------

local WorldMethods = {}
local WorldMT = { __index = WorldMethods }

-- -----------------------------------------------------------------------------
-- 函数：newPlot(w, x, y)
-- 做什么：初始化单个默认草地、未探索地块对象。
-- 输入：w（世界对象）、x, y（整数坐标）。
-- 输出：Plot 桩对象。
-- -----------------------------------------------------------------------------
local function newPlot(w, x, y)
    local s = {
        x = x, y = y,
        terrain = 0, feature = -1, hills = false, river = false, mountain = false,
        impassable = false, fighting = false,
        improvement = -1, resource = -1, resourceKnownBy = nil, owner = -1,
        revealed = {}, visible = {}, units = {}, city = nil,
        isVisibleEnemyUnit = nil, isEnemyCity = nil,
    }
    return setmetatable({ _kind = "plot", _w = w, _s = s }, PlotMT)
end

-- -----------------------------------------------------------------------------
-- 函数：resolveType(w, tableName, value)
-- 做什么：将 Type 字符串或整数 ID 统一解析为 0-based 行号；找不到立即抛错。
-- 输入：w（世界对象）、tableName（GameInfo 表名）、value（Type 或 ID）。
-- 输出：整数行号。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：override(target, key, value)
-- 做什么：仅当 value ~= nil 时覆盖 target[key]。
-- 输入：target（目标表）、key（键名）、value（新值或 nil）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function override(target, key, value)
    if value ~= nil then target[key] = value end
end

-- -----------------------------------------------------------------------------
-- 函数：assertOwnerAlive(w, owner, label)
-- 做什么：校验单位/城市所属玩家存在且存活，防止用例布置出隐形失效实体。
-- 输入：w（世界对象）、owner（玩家 ID）、label（报错前缀）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function assertOwnerAlive(w, owner, label)
    local player = w.players[owner]
    if player == nil or not player._s.alive then
        error(label .. "：玩家 " .. tostring(owner) .. " 不存在或已死亡，请先调用 addPlayer", 3)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:getPlot(x, y)
-- 做什么：按坐标获取地块对象，非法或越界返回 nil。
-- 输入：x, y（坐标）。
-- 输出：Plot 对象或 nil。
-- -----------------------------------------------------------------------------
function WorldMethods:getPlot(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local row = self.plots[y]
    if row == nil then return nil end
    return row[x]
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:addTeam(spec) / ensureTeam(teamID) / atWar(teamA, teamB, flag)
-- 做什么：创建队伍并配置对称的交战关系。
-- 输入：spec（队伍规格）或队伍 ID 与布尔标记。
-- 输出：addTeam / ensureTeam 返回 Team 桩对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addTeam(spec)
    dirty(self)
    local s = fillDefaults(spec, TEAM_FIELDS, "team")
    if s.id == nil then error("addTeam 必须提供 id", 2) end
    local team = setmetatable({ _kind = "team", _w = self, _s = s }, TeamMT)
    self.teams[s.id] = team
    dirty(self)
    return team
end

function WorldMethods:ensureTeam(teamID)
    local team = self.teams[teamID]
    if team == nil then
        team = self:addTeam({ id = teamID })
    end
    return team
end

function WorldMethods:atWar(teamA, teamB, flag)
    dirty(self)
    if flag == nil then flag = true end
    local a = self:ensureTeam(teamA)
    local b = self:ensureTeam(teamB)
    a._s.atWar[teamB] = flag or nil
    b._s.atWar[teamA] = flag or nil
    dirty(self)
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:addPlayer(spec) / setPlayer(playerID, patch) / setNilPlayerSlot(playerID, flag)
-- 做什么：添加玩家、实时修改玩家属性（IGE 场景）、或将指定槽位标记为显式 nil。
-- 输入：spec / playerID / patch / flag。
-- 输出：addPlayer / setPlayer 返回 Player 桩对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addPlayer(spec)
    dirty(self)
    local s = fillDefaults(spec, PLAYER_FIELDS, "player")
    if s.id == nil then
        s.id = self.nextPlayerID
        self.nextPlayerID = self.nextPlayerID + 1
    end
    self.nilPlayerSlots[s.id] = nil
    local player = setmetatable({ _kind = "player", _w = self, _s = s }, PlayerMT)
    self.players[s.id] = player
    if s.alive then self:ensureTeam(s.team) end
    dirty(self)
    return player
end

function WorldMethods:setPlayer(playerID, patch)
    dirty(self)
    local player = self.players[playerID]
    if player == nil then
        error("setPlayer：玩家 " .. tostring(playerID) .. " 不存在", 2)
    end
    applyPatch(player._s, patch, PLAYER_FIELDS, "player")
    if player._s.alive then self:ensureTeam(player._s.team) end
    dirty(self)
    return player
end

function WorldMethods:setNilPlayerSlot(playerID, flag)
    dirty(self)
    if flag == nil then flag = true end
    self.nilPlayerSlots[playerID] = flag or nil
    dirty(self)
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:addUnit(spec) / setUnit(unit, patch)
-- 做什么：创建单位放到地图与玩家列表，或在 IGE 场景中动态修改单位属性（含坐标迁移）。
-- 输入：spec（单位规格）或 unit + patch。
-- 输出：Unit 桩对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addUnit(spec)
    dirty(self)
    local s = fillDefaults(spec, UNIT_FIELDS, "unit")
    if s.owner == nil then error("addUnit 必须提供 owner", 2) end
    assertOwnerAlive(self, s.owner, "addUnit")
    if s.x == nil or s.y == nil then error("addUnit 必须提供 x、y", 2) end
    local plot = self:getPlot(s.x, s.y)
    if plot == nil then
        error("addUnit：坐标越界 (" .. tostring(s.x) .. "," .. tostring(s.y) .. ")", 2)
    end
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
    if s.id == nil then
        s.id = self.nextUnitID[s.owner] or 0
    end
    for _, existing in ipairs(owned) do
        if existing._s.id == s.id then
            error("addUnit：玩家 " .. tostring(s.owner) .. " 已存在编号 " .. tostring(s.id) .. " 的单位", 2)
        end
    end
    self.nextUnitID[s.owner] = math.max(self.nextUnitID[s.owner] or 0, s.id + 1)

    local unit = setmetatable({ _kind = "unit", _w = self, _s = s }, UnitMT)
    table.insert(owned, unit)
    table.insert(plot._s.units, unit)
    dirty(self)
    return unit
end

function WorldMethods:setUnit(unit, patch)
    dirty(self)
    if unit == nil or unit._kind ~= "unit" then
        error("setUnit：首个参数必须是单位桩对象", 2)
    end
    local oldX, oldY = unit._s.x, unit._s.y
    applyPatch(unit._s, patch, UNIT_FIELDS, "unit")
    if unit._s.x ~= oldX or unit._s.y ~= oldY then
        local newPlot = self:getPlot(unit._s.x, unit._s.y)
        if newPlot == nil then
            error("setUnit：新坐标越界 (" .. tostring(unit._s.x) .. "," .. tostring(unit._s.y) .. ")", 2)
        end
        local oldPlot = self:getPlot(oldX, oldY)
        if oldPlot ~= nil then
            for i = #oldPlot._s.units, 1, -1 do
                if oldPlot._s.units[i] == unit then
                    table.remove(oldPlot._s.units, i)
                end
            end
        end
        table.insert(newPlot._s.units, unit)
    end
    dirty(self)
    return unit
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:addCity(spec) / setCity(city, patch)
-- 做什么：创建城市放到地图与玩家列表，或在 IGE 场景中实时修改城市属性。
-- 输入：spec（城市规格）或 city + patch。
-- 输出：City 桩对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addCity(spec)
    dirty(self)
    local s = fillDefaults(spec, CITY_FIELDS, "city")
    if s.owner == nil then error("addCity 必须提供 owner", 2) end
    assertOwnerAlive(self, s.owner, "addCity")
    if s.x == nil or s.y == nil then error("addCity 必须提供 x、y", 2) end
    local plot = self:getPlot(s.x, s.y)
    if plot == nil then
        error("addCity：坐标越界 (" .. tostring(s.x) .. "," .. tostring(s.y) .. ")", 2)
    end
    if plot._s.city ~= nil then
        error("addCity：坐标 (" .. tostring(s.x) .. "," .. tostring(s.y) .. ") 已有城市", 2)
    end

    local owned = self.citiesByPlayer[s.owner]
    if owned == nil then
        owned = {}
        self.citiesByPlayer[s.owner] = owned
    end
    if s.id == nil then
        s.id = self.nextCityID[s.owner] or 0
    end
    for _, existing in ipairs(owned) do
        if existing._s.id == s.id then
            error("addCity：玩家 " .. tostring(s.owner) .. " 已存在编号 " .. tostring(s.id) .. " 的城市", 2)
        end
    end
    self.nextCityID[s.owner] = math.max(self.nextCityID[s.owner] or 0, s.id + 1)
    if s.name == nil then s.name = "City" .. s.id end
    if #s.cityPlots == 0 then
        s.cityPlots = { { x = s.x, y = s.y } }
    end

    local city = setmetatable({ _kind = "city", _w = self, _s = s }, CityMT)
    table.insert(owned, city)
    plot._s.city = city
    if plot._s.owner == -1 then plot._s.owner = s.owner end
    dirty(self)
    return city
end

function WorldMethods:setCity(city, patch)
    dirty(self)
    if city == nil or city._kind ~= "city" then
        error("setCity：首个参数必须是城市桩对象", 2)
    end
    applyPatch(city._s, patch, CITY_FIELDS, "city")
    dirty(self)
    return city
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:setPlot(x, y, spec)
-- 做什么：修改指定地块的属性（仅覆盖 spec 中给出的字段）。
-- 输入：x, y（坐标）、spec（地块规格表）。
-- 输出：Plot 桩对象。
-- -----------------------------------------------------------------------------
function WorldMethods:setPlot(x, y, spec)
    dirty(self)
    local plot = self:getPlot(x, y)
    if plot == nil then
        error("setPlot：坐标越界 (" .. tostring(x) .. "," .. tostring(y) .. ")", 2)
    end
    local s = fillDefaults(spec, PLOT_FIELDS, "plot")
    local p = plot._s
    if s.terrain ~= nil then p.terrain = resolveType(self, "Terrains", s.terrain) end
    if s.feature ~= nil then
        p.feature = (s.feature == false) and -1 or resolveType(self, "Features", s.feature)
    end
    if s.improvement ~= nil then
        p.improvement = (s.improvement == false) and -1 or resolveType(self, "Improvements", s.improvement)
    end
    if s.resource ~= nil then
        p.resource = (s.resource == false) and -1 or resolveType(self, "Resources", s.resource)
    end
    override(p, "resourceKnownBy", s.resourceKnownBy)
    override(p, "hills", s.hills)
    override(p, "river", s.river)
    override(p, "mountain", s.mountain)
    override(p, "impassable", s.impassable)
    override(p, "fighting", s.fighting)
    override(p, "owner", s.owner)
    override(p, "isVisibleEnemyUnit", s.isVisibleEnemyUnit)
    override(p, "isEnemyCity", s.isEnemyCity)
    if s.revealed ~= nil then
        for team, flag in pairs(s.revealed) do self:reveal(team, x, y, flag) end
    end
    if s.visible ~= nil then
        for team, flag in pairs(s.visible) do self:show(team, x, y, flag) end
    end
    dirty(self)
    return plot
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:show / reveal / unreveal / revealAll / showAll / unrevealAll
-- 做什么：按队伍设置单格或全图的实时可见与已探索状态（保证可见蕴含已探索、未探索必不可见）。
-- 输入：team（队伍 ID）、x, y（坐标）、flag（可选布尔值，默认 true）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
function WorldMethods:show(team, x, y, flag)
    dirty(self)
    if flag == nil then flag = true end
    local plot = self:getPlot(x, y)
    if plot ~= nil then
        plot._s.visible[team] = flag or nil
        if flag then plot._s.revealed[team] = true end
    end
    dirty(self)
end

function WorldMethods:reveal(team, x, y, flag)
    dirty(self)
    if flag == nil then flag = true end
    local plot = self:getPlot(x, y)
    if plot ~= nil then
        plot._s.revealed[team] = flag or nil
        if not flag then plot._s.visible[team] = nil end
    end
    dirty(self)
end

function WorldMethods:unreveal(team, x, y)
    self:reveal(team, x, y, false)
end

function WorldMethods:revealAll(team)
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do
            self:reveal(team, x, y)
        end
    end
end

function WorldMethods:showAll(team)
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do
            self:show(team, x, y)
        end
    end
end

function WorldMethods:unrevealAll(team)
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do
            self:unreveal(team, x, y)
        end
    end
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:select / clearSelection / setInterfaceMode
-- 做什么：布置初始 UI 状态，不写入调用日志，也不进入世界持久快照。
-- -----------------------------------------------------------------------------
function WorldMethods:select(unit)
    self.ui.headUnit = unit
end

function WorldMethods:clearSelection()
    self.ui.headUnit = nil
end

function WorldMethods:setInterfaceMode(mode)
    self.ui.interfaceMode = mode
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:addInfoRow / addAction / addText
-- 做什么：向当前世界的 GameInfo 表、GameInfoActions 或本地化表追加条目并刷新 GameInfoTypes。
-- -----------------------------------------------------------------------------
function WorldMethods:addInfoRow(tableName, row)
    dirty(self)
    local rows = self.info[tableName]
    if rows == nil then
        rows = { n = 0 }
        self.info[tableName] = rows
    end
    local copy = deepCopy(row)
    copy.ID = rows.n
    rows[rows.n] = copy
    rows.n = rows.n + 1
    rebuildGameInfoTypes(self)
    dirty(self)
    return copy.ID
end

function WorldMethods:addAction(row)
    dirty(self)
    local copy = deepCopy(row)
    copy.ID = self.actionRows.n
    self.actionRows[self.actionRows.n] = copy
    self.actionRows.n = self.actionRows.n + 1
    rebuildGameInfoTypes(self)
    dirty(self)
    return copy.ID
end

function WorldMethods:addText(key, text)
    self.texts[key] = text
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:unit(owner, id) / city(owner, id)
-- 做什么：按归属玩家与编号查找已创建的单位或城市桩对象。
-- -----------------------------------------------------------------------------
function WorldMethods:unit(owner, id)
    local list = self.unitsByPlayer[owner]
    if list == nil then return nil end
    for _, u in ipairs(list) do
        if u._s.id == id then return u end
    end
    return nil
end

function WorldMethods:city(owner, id)
    local list = self.citiesByPlayer[owner]
    if list == nil then return nil end
    for _, c in ipairs(list) do
        if c._s.id == id then return c end
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- 函数：WorldMethods:logOf / logCount / queriesOnInvisible / queriesOutOfBounds /
--       queriesOnForbiddenFog / clearLog
-- 做什么：查询与筛选世界调用日志。
-- 为什么区分三种筛选器：
--   * queriesOnInvisible：所有落于地图内非实时可见格（迷雾或黑雾）的调用；
--   * queriesOutOfBounds：落于地图越界空地块的调用；
--   * queriesOnForbiddenFog：精准对应红线 F-03，筛出落于普通迷雾格或黑雾格
--     （即非实时可见、且非已探索敌对城市格）的违禁探测调用。
-- 输入：names（方法名字符串或数组）。
-- 输出：日志条目数组或次数。
-- -----------------------------------------------------------------------------
function WorldMethods:logOf(names)
    local wanted = {}
    for _, name in ipairs(normalizeNameList(names)) do
        wanted[name] = true
    end
    local out = {}
    for _, entry in ipairs(self.log) do
        if wanted[entry.name] then
            table.insert(out, entry)
        end
    end
    return out
end

function WorldMethods:logCount(names)
    return #self:logOf(names)
end

function WorldMethods:queriesOnInvisible(names)
    local out = {}
    for _, entry in ipairs(self:logOf(names)) do
        if entry.x ~= nil and entry.visible ~= true then
            table.insert(out, entry)
        end
    end
    return out
end

function WorldMethods:queriesOutOfBounds(names)
    local out = {}
    for _, entry in ipairs(self:logOf(names)) do
        if entry.x == nil then
            table.insert(out, entry)
        end
    end
    return out
end

function WorldMethods:queriesOnForbiddenFog(names)
    local out = {}
    for _, entry in ipairs(self:logOf(names)) do
        if entry.x ~= nil and entry.visible ~= true then
            local allowedFogHostileCity = (entry.revealed == true and entry.isHostileCity == true)
            if not allowedFogHostileCity then
                table.insert(out, entry)
            end
        end
    end
    return out
end

function WorldMethods:clearLog()
    self.log = {}
end

-- -----------------------------------------------------------------------------
-- 函数：S.describeEntry(entry) / S.describeLog(entries)
-- 做什么：将调用日志条目格式化为诊断文本，供失败断言输出。
-- -----------------------------------------------------------------------------
function S.describeEntry(entry)
    local caller = ""
    if entry.self ~= nil then caller = S.describe(entry.self) .. ":" end
    local name = entry.name
    if entry.actionType ~= nil then
        name = name .. "[" .. tostring(entry.actionType) .. "]"
    end
    local target = ""
    if entry.x ~= nil then
        target = " -> (" .. tostring(entry.x) .. "," .. tostring(entry.y) .. ")"
            .. " visible=" .. tostring(entry.visible)
            .. " revealed=" .. tostring(entry.revealed)
            .. " hostileCity=" .. tostring(entry.isHostileCity)
    end
    return caller .. name .. target
end

function S.describeLog(entries)
    if #entries == 0 then return "(空)" end
    local lines = {}
    for i, entry in ipairs(entries) do
        lines[i] = tostring(i) .. ") " .. S.describeEntry(entry)
    end
    return table.concat(lines, "\n")
end

-- -----------------------------------------------------------------------------
-- 第 15 节：世界创建与用例边界管理（beginCase / endCase）
-- -----------------------------------------------------------------------------

local WORLD_OPTION_FIELDS = fieldSet({
    "width", "height", "activePlayer", "turn", "processingMessages", "canEndTurn", "gameDefines", "gameOptions",
    "teams", "players", "wars", "revealAll", "visibleAll", "units", "cities", "select",
}, {
    width = 24, height = 20, activePlayer = 0, turn = 1, processingMessages = false, canEndTurn = true,
    gameOptions = {},
})

-- A-01 洁净白名单：测试过程中允许新出现的业务全局仅限 CAB_Config 与 CAB_Collector
local ALLOWED_CASE_GLOBALS = { CAB_Config = true, CAB_Collector = true }

S.worlds = {}
S.currentWorld = nil

-- -----------------------------------------------------------------------------
-- 函数：globalNames()
-- 做什么：快照当前 _G 全部全局键名。
-- 输出：{ [name] = true }。
-- -----------------------------------------------------------------------------
local function globalNames()
    local names = {}
    for name in pairs(_G) do
        names[name] = true
    end
    return names
end

-- -----------------------------------------------------------------------------
-- 函数：S.newWorld(opts)
-- 做什么：创建一个彼此完全隔离的合成游戏世界，并将对应引擎全局表安装到 _G。
-- 输入：opts（可选配置表，字段见 WORLD_OPTION_FIELDS）。
-- 输出：世界对象 w。
-- -----------------------------------------------------------------------------
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
        gameOptions = deepCopy(o.gameOptions or {}),
        ui = {
            headUnit = nil,
            interfaceMode = InterfaceModeTypes.INTERFACEMODE_SELECTION,
            canEndTurn = o.canEndTurn,
        },
        log = {},
        texts = {},
        _snapshot = nil,
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
    dirty(w)
    return w
end

-- -----------------------------------------------------------------------------
-- 函数：S.beginCase()
-- 做什么：单条用例启动前重置世界列表、print 缓冲与默认世界，并记录守卫与全局名水位线。
-- 输出：nil。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：S.endCase()
-- 做什么：单条用例结束后执行三重红线核验：
--         1. 世界深层快照与首次读取前基线完全一致（A-03）；
--         2. 无新增写入类/DLL 避坑违规，无未实现方法调用（A-03、A-05）；
--         3. 无白名单（CAB_Config / CAB_Collector）之外的新增全局变量（A-01）。
-- 输出：(ok: boolean, detailMsg: string)。
-- -----------------------------------------------------------------------------
function S.endCase()
    local problems = {}
    for _, w in ipairs(S.worlds) do
        if w._snapshot ~= nil then
            local now = S.snapshot(w)
            if now ~= w._snapshot then
                table.insert(
                    problems,
                    "世界状态在用例期间被修改（违反纯只读红线）：" .. S.firstDiff(w._snapshot, now)
                )
            end
        end
    end
    for i = S.marks.violations + 1, #S.guard.violations do
        local record = S.guard.violations[i]
        table.insert(problems, "触发守卫违规：" .. record.owner .. "." .. record.method .. "()")
    end
    for i = S.marks.missing + 1, #S.guard.missing do
        local record = S.guard.missing[i]
        table.insert(
            problems,
            "调用了桩未实现的方法：" .. record.owner .. "." .. record.method .. "()"
        )
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
