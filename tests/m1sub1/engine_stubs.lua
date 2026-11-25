-- =============================================================================
-- 文件：tests/m1sub1/engine_stubs.lua
-- 做什么：给《mod/Lua/CAB_InfoCollector.lua》的桩测试提供一套“假的游戏引擎环境”。
--         被测文件只读引擎、不写引擎，所以这里只需要把“读取类接口”按真实签名做出来，
--         再把“写入类接口”做成一碰就报错的陷阱。
-- 为什么：本子模块按用户决策 U-03 用引擎桩测试验证，本阶段不部署实机。
--
-- 提供内容（对应《SubM1工作计划.md》§10.1）：
--   1. include 垫片：从 mod/Lua/<模块名>.lua 加载源码，并记录已加载名单；
--   2. GameInfo / GameInfoActions 桩：按数据库表视图的语义取行；
--   3. 枚举表与 GameDefines：取值以本机游戏数据为准；
--   4. 只读守卫：写入类接口被调用时立即报错并记录；
--   5. 合成世界构建器：生成玩家、队伍、单位、城市和一张带行偏移的六边形网格地图；
--   6. 调用日志：记录判定类调用及其目标格当时的可见性；
--   7. 世界快照：用例结束后核对世界状态有没有被改动。
--
-- 怎么用（详见 test_collector.lua）：
--     local S = CAB_TEST_STUBS
--     local w = S.newWorld({ revealAll = 0 })
--     local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 5 })
--
-- 引擎语义依据（均为本机 v1.0.3.279 的官方脚本与游戏数据）：
--   * Map.GetPlotXY(x, y, dx, dy)：越界返回 nil（Expansion2/UI/InGame/InGame.lua:600-601）；
--   * 地图距离：Map.PlotDistance(x1, y1, x2, y2)（InGame.lua:604）；
--   * 视野：pPlot:IsVisible(team, bIsDebug) / IsRevealed(team, bIsDebug)
--       （Expansion2/UI/InGame/PlotHelpManager.lua:125、:130）；
--   * 隐形：pUnit:IsInvisible(team, bIsDebug)（Expansion2/UI/InGame/PlotMouseoverInclude.lua:302）；
--   * 格上单位：pPlot:GetNumUnits() / GetUnit(i)，下标从 0 起（PlotMouseoverInclude.lua:298-301）；
--   * 玩家槽位：范围内的 Players[i] 恒返回对象，未参战的槽位是 IsAlive() 为假的“死玩家”
--       （官方循环里不判 nil 就调用：Popups/CultureOverview.lua:1798-1800、PlotMouseoverInclude.lua:50-54）；
--   * #GameInfo.<表> 是行数（FrontEnd/GameSetup/AdvancedSetup.lua:1089、Popups/Demographics.lua:400）。
--     所以官方惯用的 for i = 0, #GameInfoActions 会多访问一个越界项，而且不报错
--     （WorldView/UnitPanel.lua:202-206 直接读 action.Visible）——可见越界项不是 nil；
--   * GameDefines：MOVE_DENOMINATOR=60、MAX_HIT_POINTS=100、CITY_ATTACK_RANGE=2、BUY_PLOTS_DISABLED=0
--       （Expansion2/Gameplay/XML/GlobalDefines.xml:66、:974、:1078、:1501）。
--
-- 桩的已知近似（不能当成引擎事实，属于计划 §9.6 的待实机确认项）：
--   * 六边形网格按“奇数行右偏半格”摆放，不模拟地图卷绕（R-4）；
--   * GameInfo 越界时返回一个空表：由“越界项不是 nil”推出，具体返回什么没有实机证据；
--   * pPlot:IsVisibleEnemyUnit / IsEnemyCity 的精确语义未知。前者做成“不是自己的、且看得见”，
--     后者只做“不是自己的”，不看可见性。用例可以用 isVisibleEnemyUnit / isEnemyCity 字段直接指定返回值；
--   * 枚举的具体数值与 GameDefines.MAX_PLAYERS 是编译期常量，未能静态核实，这里是自洽的假设值。
--     用例与被测代码共用同一张表，所以数值偏差不影响测试结论。
-- =============================================================================

local S = {}
CAB_TEST_STUBS = S

-- -----------------------------------------------------------------------------
-- 第 1 节：常量
-- -----------------------------------------------------------------------------

-- 回合阻塞枚举的 24 个成员，顺序照计划 §9.1
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

-- 枚举表。成员名以官方脚本为准，数值是假设值（见文件头）。
local ENUMS = {
    DomainTypes = {
        DOMAIN_LAND = 0, DOMAIN_SEA = 1, DOMAIN_AIR = 2, DOMAIN_HOVER = 3,
        DOMAIN_IMMOBILE = 4, NO_DOMAIN = -1,
    },
    YieldTypes = {
        YIELD_FOOD = 0, YIELD_PRODUCTION = 1, YIELD_GOLD = 2, YIELD_SCIENCE = 3,
        YIELD_CULTURE = 4, YIELD_FAITH = 5, NO_YIELD = -1,
    },
    ResourceUsageTypes = {
        RESOURCEUSAGE_LUXURY = 0, RESOURCEUSAGE_STRATEGIC = 1, RESOURCEUSAGE_BONUS = 2,
    },
    InterfaceModeTypes = {
        INTERFACEMODE_SELECTION = 0,
        -- 以下数值不是引擎的真实值，只保证与 INTERFACEMODE_SELECTION 不同
        INTERFACEMODE_MOVE_TO = 1,
        INTERFACEMODE_RANGE_ATTACK = 2,
        INTERFACEMODE_AIRSTRIKE = 3,
        INTERFACEMODE_CITY_RANGE_ATTACK = 4,
        INTERFACEMODE_PURCHASE_PLOT = 5,
    },
    EndTurnBlockingTypes = { NO_ENDTURN_BLOCKING_TYPE = -1 },
}

-- GameDefines 的默认值：前五个取自游戏数据（见文件头），后三个是假设值
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

-- GameInfo 的默认行。每个世界各拷贝一份，用例之间互不共享。
-- 行里的 ID 由构建器按顺序自动分配（从 0 起）。
-- 小写开头的列（water、usage、Movement）是桩用的辅助列，其余列名与游戏数据表一致。
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
        { Type = "RESOURCE_HORSE", Description = "TXT_KEY_RESOURCE_HORSE",
          usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC },
        { Type = "RESOURCE_IRON",  Description = "TXT_KEY_RESOURCE_IRON",
          usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC },
        { Type = "RESOURCE_FUR",   Description = "TXT_KEY_RESOURCE_FUR",
          usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_LUXURY },
        { Type = "RESOURCE_WHEAT", Description = "TXT_KEY_RESOURCE_WHEAT",
          usage = ENUMS.ResourceUsageTypes.RESOURCEUSAGE_BONUS },
    },
    -- Moves 是“每回合能走的格数”；原始移动力点数 = Moves × MOVE_DENOMINATOR
    Units = {
        { Type = "UNIT_WARRIOR",  Description = "TXT_KEY_UNIT_WARRIOR", Domain = "DOMAIN_LAND",
          Combat = 8,  RangedCombat = 0,  Range = 0, Moves = 2 },
        { Type = "UNIT_ARCHER",   Description = "TXT_KEY_UNIT_ARCHER",  Domain = "DOMAIN_LAND",
          Combat = 5,  RangedCombat = 9,  Range = 2, Moves = 2 },
        { Type = "UNIT_SETTLER",  Description = "TXT_KEY_UNIT_SETTLER", Domain = "DOMAIN_LAND",
          Combat = 0,  RangedCombat = 0,  Range = 0, Moves = 2 },
        { Type = "UNIT_WORKER",   Description = "TXT_KEY_UNIT_WORKER",  Domain = "DOMAIN_LAND",
          Combat = 0,  RangedCombat = 0,  Range = 0, Moves = 2 },
        { Type = "UNIT_CATAPULT", Description = "TXT_KEY_UNIT_CATAPULT", Domain = "DOMAIN_LAND",
          Combat = 7,  RangedCombat = 11, Range = 2, Moves = 2 },
        { Type = "UNIT_TRIREME",  Description = "TXT_KEY_UNIT_TRIREME", Domain = "DOMAIN_SEA",
          Combat = 10, RangedCombat = 0,  Range = 0, Moves = 4 },
        { Type = "UNIT_GALLEASS", Description = "TXT_KEY_UNIT_GALLEASS", Domain = "DOMAIN_SEA",
          Combat = 12, RangedCombat = 13, Range = 2, Moves = 4 },
        { Type = "UNIT_FIGHTER",  Description = "TXT_KEY_UNIT_FIGHTER", Domain = "DOMAIN_AIR",
          Combat = 0,  RangedCombat = 0,  Range = 8, Moves = 2 },
    },
    Buildings = {
        { Type = "BUILDING_MONUMENT", Description = "TXT_KEY_BUILDING_MONUMENT" },
        { Type = "BUILDING_GRANARY",  Description = "TXT_KEY_BUILDING_GRANARY" },
        { Type = "BUILDING_WALLS",    Description = "TXT_KEY_BUILDING_WALLS" },
        { Type = "BUILDING_PALACE",   Description = "TXT_KEY_BUILDING_PALACE" },
    },
}

-- GameInfoActions 的默认行。Type 就是任务类型名（WorldView/UnitPanel.lua:202 的用法）。
local DEFAULT_ACTION_ROWS = {
    { Type = "MISSION_FORTIFY",                  SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_ALERT",                    SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_HEAL",                     SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SKIP",                     SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
    { Type = "MISSION_SET_UP_FOR_RANGED_ATTACK", SubType = "ACTIONSUBTYPE_MISSION", Visible = true },
}

-- -----------------------------------------------------------------------------
-- 第 2 节：小工具
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：keyOf(x, y)
-- 做什么：把坐标拼成 "x:y"，用作“按目标格配置的判定表”的键。
-- -----------------------------------------------------------------------------
local function keyOf(x, y)
    return tostring(x) .. ":" .. tostring(y)
end
S.keyOf = keyOf

-- -----------------------------------------------------------------------------
-- 函数：deepCopy(v)
-- 做什么：递归深拷贝普通表；函数与非表类型原样返回；带 _kind 的桩对象原样返回（保持身份）。
-- 为什么桩对象不拷贝：布置规格里若引用了一个单位对象（例如驻军），拷贝会得到另一个对象，
--     被测代码比较身份时就会出错。
-- -----------------------------------------------------------------------------
local function deepCopy(v)
    if type(v) ~= "table" or v._kind ~= nil then return v end
    local out = {}
    for k, item in pairs(v) do out[k] = deepCopy(item) end
    return out
end

-- -----------------------------------------------------------------------------
-- 函数：normalizeNameList(names)
-- 做什么：把“一个方法名或一组方法名”统一成数组。
-- 输入：names，字符串或字符串数组。
-- 输出：字符串数组。
-- -----------------------------------------------------------------------------
local function normalizeNameList(names)
    if type(names) == "string" then return { names } end
    return names
end

-- -----------------------------------------------------------------------------
-- 函数：decide(value, self, key, ...)
-- 做什么：解析一个“可配置的判定结果”。判定字段允许三种写法：
--     布尔     直接返回；
--     函数     以 (self, ...) 调用，返回 true 才算真；
--     表       按目标键（"x:y"）查；表里的值还可以是函数。
-- 输入：value，规格里的判定字段；self，调用它的桩对象；key，目标键（没有目标时为 nil）。
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
-- 第 3 节：枚举表与 GameDefines
-- -----------------------------------------------------------------------------

for i, name in ipairs(ENDTURN_BLOCKING_NAMES) do
    ENUMS.EndTurnBlockingTypes[name] = i - 1
end

-- 枚举表作为全局常量只安装一次；GameDefines 每个世界重置一次
DomainTypes = ENUMS.DomainTypes
YieldTypes = ENUMS.YieldTypes
ResourceUsageTypes = ENUMS.ResourceUsageTypes
InterfaceModeTypes = ENUMS.InterfaceModeTypes
EndTurnBlockingTypes = ENUMS.EndTurnBlockingTypes

-- -----------------------------------------------------------------------------
-- 函数：S.resetGameDefines(overrides)
-- 做什么：把全局 GameDefines 重置为默认值，再套用用例给的覆盖项。
-- 为什么复用同一张表：被测文件可能在文件顶层写 local X = GameDefines["X"]，把整张表捕获走了。
--     如果每个世界换一张新表，这种写法读到的是上一条用例的值。
-- 输入：overrides，可选的键值覆盖表。
-- -----------------------------------------------------------------------------
function S.resetGameDefines(overrides)
    GameDefines = GameDefines or {}
    for k in pairs(GameDefines) do GameDefines[k] = nil end
    for k, v in pairs(GAME_DEFINES_DEFAULT) do GameDefines[k] = v end
    for k, v in pairs(overrides or {}) do GameDefines[k] = v end
end

-- -----------------------------------------------------------------------------
-- 第 4 节：只读守卫
-- -----------------------------------------------------------------------------

-- 守卫记录（跨用例累计，由 test_collector.lua 在每条用例结束时核对）
S.guard = { violations = {}, missing = {} }

-- 写入类接口名单。前一组取自计划 WP2 第 4 点的名单，其余是同一类风险的补充。
local WRITE_NAMES = {
    -- 计划点名的
    SetScriptData = true, SetRevealed = true,
    CityPurchaseBuilding = true, CityPurchaseUnit = true, CityPushOrder = true,
    SendCityBuyPlot = true,
    HandleAction = true, DoControl = true,
    SelectionListMove = true, SelectionListGameNetMessage = true,
    ActivateNotification = true, RemoveNotification = true,
    -- 同类补充
    CityPurchaseProject = true, SelectedCitiesGameNetMessage = true,
    PushMission = true,
}
local WRITE_PATTERNS = {
    "^Set[A-Z]", "^Send[A-Z]", "^Push[A-Z]", "^Buy[A-Z]", "^Purchase[A-Z]",
    "^Delete[A-Z]", "^Destroy[A-Z]", "^Kill[A-Z]", "^Disband[A-Z]", "^Found[A-Z]",
}

-- -----------------------------------------------------------------------------
-- 函数：S.isWriteMethod(name)
-- 做什么：判断一个方法名是不是写入类接口（命中名单，或匹配 Set* 等前缀）。
-- 输入：name，方法名。
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
-- 函数：makeTrap(ownerLabel, methodName)
-- 做什么：造一个“陷阱函数”：被调用时先把这次违规记进 S.guard.violations，再抛错。
-- 为什么先记录再抛错：被测代码可能用 pcall 把错误吞掉，记录不受 pcall 影响。
-- 输入：ownerLabel，接口所属对象的名字（如 "Game"、"Unit"）；methodName，方法名。
-- 输出：陷阱函数。
-- -----------------------------------------------------------------------------
local function makeTrap(ownerLabel, methodName)
    return function(...)
        table.insert(S.guard.violations, { owner = ownerLabel, method = methodName, args = { ... } })
        error("[只读守卫] 被测代码调用了写入类接口 " .. ownerLabel .. "." .. methodName .. "()", 2)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：makeMissing(ownerLabel, methodName)
-- 做什么：造一个“未实现”函数：桩没有实现这个方法，被调用时记录并抛错。
-- 为什么：桩没实现的方法，在真实引擎上要么不存在、要么行为未知。让它静静地返回 nil，
--     会把错误的调用方式带进正式代码；直接报错才能提醒把桩补齐。
-- 输入：ownerLabel，接口所属对象的名字；methodName，方法名。
-- 输出：未实现函数。
-- -----------------------------------------------------------------------------
local function makeMissing(ownerLabel, methodName)
    return function(...)
        table.insert(S.guard.missing, { owner = ownerLabel, method = methodName })
        error("[引擎桩] 调用了桩未实现的方法 " .. ownerLabel .. "." .. methodName .. "()", 2)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：unknownMember(ownerLabel, key)
-- 做什么：统一处理“访问桩没有定义的成员”：写入类给陷阱，其他给未实现函数。
-- 输入：ownerLabel，对象名；key，成员名。
-- 输出：陷阱函数或未实现函数。
-- -----------------------------------------------------------------------------
local function unknownMember(ownerLabel, key)
    if S.isWriteMethod(key) then return makeTrap(ownerLabel, key) end
    return makeMissing(ownerLabel, key)
end

-- -----------------------------------------------------------------------------
-- 第 5 节：include 垫片与调试输出
-- -----------------------------------------------------------------------------

-- include 记录：includeOrder 是首次加载的先后顺序，includeCount 是每个模块的加载次数
S.includeOrder = {}
S.includeCount = {}

-- -----------------------------------------------------------------------------
-- 函数：S.hasModule(name)
-- 做什么：判断 mod/Lua/<name>.lua 是否存在，不加载。
-- 输入：name，模块名（不含扩展名）。
-- 输出：存在返回 true。
-- -----------------------------------------------------------------------------
function S.hasModule(name)
    local src = __py_read_file("mod/Lua/" .. tostring(name) .. ".lua")
    return src ~= nil
end

-- -----------------------------------------------------------------------------
-- 函数：include(name)
-- 做什么：垫片版的游戏 include：读取 mod/Lua/<name>.lua，编译后当作独立代码块执行，
--     并把模块名记进已加载名单。
-- 为什么由 Python 读文件：项目的绝对路径含空格和撇号，C 运行库打开它的行为不可控。
-- 输入：name，模块名。
-- 失败行为：文件不存在或编译失败时抛错（带模块名与错误信息），不静默忽略。
-- -----------------------------------------------------------------------------
function include(name)
    local key = tostring(name)
    local relpath = "mod/Lua/" .. key .. ".lua"
    local src, err = __py_read_file(relpath)
    if not src then
        error("include 垫片：读不到 " .. relpath .. "（" .. tostring(err) .. "）", 2)
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

-- 被测代码的 print 输出收集到这里，用例失败时随错误信息一起显示
S.prints = {}

-- -----------------------------------------------------------------------------
-- 函数：print(...)
-- 做什么：替换标准输出，把被测代码的日志收集到 S.prints，而不是刷到测试报告里。
-- -----------------------------------------------------------------------------
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    table.insert(S.prints, table.concat(parts, "\t"))
end

-- -----------------------------------------------------------------------------
-- 第 6 节：GameInfo 表视图
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：copyRows(rows)
-- 做什么：把默认行模板复制成世界自己的行表。
-- 输入：rows，按 1 起下标排列的行模板数组。
-- 输出：{ [0]=行, [1]=行, …, n=行数 }，其中每行带 ID 列。
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
-- 做什么：造一个“数据库表视图”，模拟 GameInfo.<表> 与 GameInfoActions 的行为：
--     view[i]       按行号取行，行号从 0 起；越界返回空表（见文件头的依据与近似说明）；
--     view["Xxx"]   按行的 Type 列取行；找不到返回空表；
--     #view         返回行数；
--     view()        返回迭代器，供 for row in GameInfo.<表>() do 使用
--                   （先例：InGame/TopPanel.lua:190）。
-- 为什么用 userdata：标准 Lua 5.1 里，表的长度运算符不认 __len 元方法，userdata 才认。
-- 输入：getRows，返回当前行表的函数。行表可以随时增行，所以不直接捕获行表。
-- 输出：userdata 视图。
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
    meta.__len = function() return getRows().n end
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
-- 第 7 节：六边形网格
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：S.hexDistance(x1, y1, x2, y2)
-- 做什么：计算两个网格坐标之间的六边形距离，网格按“奇数行右偏半格”摆放。
-- 怎么算：先把网格坐标换算成“立方坐标”（三个分量之和恒为 0），距离是三个分量差的
--     绝对值之和的一半。
-- 输入：两个格子的坐标（非负整数）。
-- 输出：非负整数距离；同一格为 0，相邻为 1。
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
-- 第 8 节：调用日志
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：S.describe(value)
-- 做什么：把日志里的参数值转成便于阅读的字符串。桩对象显示成“种类(归属:编号)”或“种类(坐标)”。
-- 输入：value，任意值。
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
-- 做什么：往世界的调用日志追加一条记录，并补上“目标格当时对参照队伍的可见性”。
-- 为什么记可见性：泄露回归（T-68）要断言“引擎判定从未以不可见格为目标被调用过”，
--     而用例事后无法重现调用那一刻的视野状态，所以必须在调用发生的那一刻记下来。
-- 参照队伍：主玩家（w.activePlayer）所在的队伍。
-- 输入：w，世界；entry，日志条目，含 name、args、self、plot（可为 nil）。
-- 输出：补全后的 entry。字段：x、y、revealed、visible（没有目标格时这四项为 nil）、
--     headUnit（调用那一刻的选中单位）。
-- -----------------------------------------------------------------------------
function S.record(w, entry)
    local plot = entry.plot
    if plot ~= nil then
        local team = S.visionTeamOf(w)
        entry.x, entry.y = plot._s.x, plot._s.y
        entry.revealed = plot._s.revealed[team] == true
        entry.visible = plot._s.visible[team] == true
    end
    entry.headUnit = S.describe(w.ui.headUnit)
    entry.seq = #w.log + 1
    table.insert(w.log, entry)
    return entry
end

-- -----------------------------------------------------------------------------
-- 第 9 节：世界快照
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：sortedKeys(t)
-- 做什么：把表的键排成稳定顺序：数字键在前（从小到大），字符串键在后（字典序）。
-- 为什么：pairs 的遍历顺序不确定，快照要逐字节可比，必须先定序。
-- 输出：键的数组。
-- -----------------------------------------------------------------------------
local function sortedKeys(t)
    local numbers, strings = {}, {}
    for k in pairs(t) do
        if type(k) == "number" then table.insert(numbers, k) else table.insert(strings, k) end
    end
    table.sort(numbers)
    table.sort(strings)
    for _, s in ipairs(strings) do table.insert(numbers, s) end
    return numbers
end

-- -----------------------------------------------------------------------------
-- 函数：objTag(v)
-- 做什么：给桩对象生成“种类:身份”标签，快照用它代表对象引用，不深入对象内部。
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
-- 做什么：把一个值序列化成逐字节可比的规范字符串。
--     桩对象只记“种类与身份”，不深入内部；函数只记“是函数”。
-- 输入：v，任意值；seen，用于识别循环引用的表。
-- 输出：字符串。
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
-- 函数：S.snapshot(w)
-- 做什么：把世界的全部状态拍成一张规范字符串快照。
--     范围：回合号、GameDefines、GameInfo 行、队伍与交战关系、玩家、单位、城市、全部地块。
--     不含界面状态（当前选中）——原地动作探测允许短暂切换选中（计划 §3.3 的 P-3）。
-- 输入：w，世界。
-- 输出：字符串。
-- -----------------------------------------------------------------------------
function S.snapshot(w)
    local seen = {}
    local parts = {}
    local function add(label, value)
        parts[#parts + 1] = label .. "=" .. ser(value, seen)
    end
    add("turn", w.turn)
    add("busy", w.processingMessages)
    add("active", w.activePlayer)
    add("defines", GameDefines)
    add("info", w.info)
    add("actions", w.actionRows)
    add("teams", w.teams)
    add("players", w.players)
    add("units", w.unitsByPlayer)
    add("cities", w.citiesByPlayer)
    add("plots", w.plots)
    return table.concat(parts, "|")
end

-- -----------------------------------------------------------------------------
-- 函数：S.touch(w)
-- 做什么：登记“这个世界被读过了”。若还没有基线快照，就在此刻拍一张。
--     基线 = 最后一次布置之后、第一次被读之前的状态。采集模块是先读后写的才可能有危害，
--     而任何写入要么走守卫（当场被拦），要么发生在第一次读之后（快照会变），所以这个基线够用。
-- 输入：w，世界；可为 nil。
-- -----------------------------------------------------------------------------
function S.touch(w)
    if w ~= nil and w._snapshot == nil then
        w._snapshot = S.snapshot(w)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：dirty(w)
-- 做什么：作废基线快照。每次布置操作前后各调用一次，保证下一次读之前会重拍。
-- 输入：w，世界；可为 nil。
-- -----------------------------------------------------------------------------
local function dirty(w)
    if w ~= nil then w._snapshot = nil end
end

-- -----------------------------------------------------------------------------
-- 函数：S.firstDiff(a, b)
-- 做什么：找出两个字符串第一处不同的位置，返回该处附近的片段，便于定位是哪一项变了。
-- 输入：a，基线；b，现状。
-- 输出：形如 “…基线片段… => …现状片段…” 的字符串。
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
-- 第 10 节：布置规格的填写工具
-- -----------------------------------------------------------------------------

-- “没有缺省值”的标记：字段可以设置，不设置就是 nil
local NONE = {}

-- -----------------------------------------------------------------------------
-- 函数：fieldSet(names, defaults)
-- 做什么：由字段名清单造出“字段 → 缺省值”的规格表。
-- 为什么字段名用清单而不是表：缺省值为 nil 的字段写不进表字面量，清单不会有这个遗漏。
-- 输入：names，允许设置的字段名数组；defaults，带缺省值的字段的表。
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
-- 做什么：按规格表铺缺省值，再用布置规格里的同名字段覆盖。
--     表类型的值一律复制一份（桩对象除外），避免不同对象共用同一个表。
-- 失败行为：规格里出现规格表之外的字段时抛错。
--     为什么：拼错的字段名如果被静默忽略，用例会以为设置生效了，测试就成了假通过。
-- 输入：spec，布置规格（可为 nil）；fields，fieldSet 造出的规格表；label，用在报错信息里。
-- 输出：状态表。
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
            error("布置规格里有未知字段 " .. label .. "." .. tostring(name), 3)
        end
        if type(value) == "table" and value._kind == nil then value = deepCopy(value) end
        s[name] = value
    end
    return s
end

-- -----------------------------------------------------------------------------
-- 第 11 节：各类对象的字段清单
-- 这里列出的字段，就是用例可以设置的全部字段（计划 §10.2 的最小能力）。
-- -----------------------------------------------------------------------------

local TEAM_FIELDS = fieldSet({ "id", "atWar" }, { atWar = {} })

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

-- 判定类字段（canRangeStrike 等）的写法见 decide：布尔、函数或按目标键查的表。
-- moves / maxMoves 的单位是“原始移动力点数”，与 MovesLeft() / MaxMoves() 的返回值一致。
local UNIT_FIELDS = fieldSet({
    "id", "owner", "unitType", "x", "y", "nameKey",
    "domain", "damage", "maxHp", "moves", "maxMoves",
    "combat", "rangedCombat", "range",
    "fortifyTurns", "readyToMove", "promotionReady", "automated", "delayedDeath", "dead",
    "isCombat", "embarked", "invisibleTo",
    "canRangeStrike", "canRangeStrikeAt", "canMoveThrough", "canAttack", "canHeal",
    "mustSetUp", "everFortifyable", "canHandleActions",
}, {
    damage = 0, fortifyTurns = 0, promotionReady = false, automated = false, delayedDeath = false,
    dead = false, embarked = false, invisibleTo = {},
    canRangeStrike = false, canRangeStrikeAt = false, canMoveThrough = false,
    canHeal = false, mustSetUp = false, canHandleActions = {},
})

-- costs 的四个子表：unitGold / unitFaith / bldGold / bldFaith，键是单位或建筑的行号。
-- purchasable 与 affordable 的写法：{ units = { [行号] = { gold = true, faith = true } }, buildings = { … } }。
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
-- 第 12 节：地块与单位的方法表（签名逐一对照计划 §9.1）
-- 每个方法的写法上方标了官方先例；路径前缀同计划 §9.1（E2/ = Expansion2/UI/InGame/）。
-- -----------------------------------------------------------------------------

local PlotMethods = {}

-- 坐标与视野（E2/CityView/CityView.lua:2001-2002；E2/PlotHelpManager.lua:125、:130）
PlotMethods.GetX = function(p) return p._s.x end
PlotMethods.GetY = function(p) return p._s.y end
PlotMethods.IsRevealed = function(p, team) return p._s.revealed[team] == true end
PlotMethods.IsVisible = function(p, team) return p._s.visible[team] == true end

-- 格上单位，下标从 0 起（E2/PlotMouseoverInclude.lua:298-301）
PlotMethods.GetNumUnits = function(p) return #p._s.units end
PlotMethods.GetUnit = function(p, index)
    if type(index) ~= "number" then return nil end
    return p._s.units[index + 1]
end

-- 归属与城市（E2/CityView/CityView.lua:2031；E2/PlotMouseoverInclude.lua:380-382）
PlotMethods.GetOwner = function(p) return p._s.owner end
PlotMethods.GetPlotCity = function(p) return p._s.city end
PlotMethods.IsCity = function(p) return p._s.city ~= nil end

-- 地形、地貌、丘陵、河流、山地
-- （E2/PlotMouseoverInclude.lua:153、:87、:161、:172、:125）
PlotMethods.GetTerrainType = function(p) return p._s.terrain end
PlotMethods.GetFeatureType = function(p) return p._s.feature end
PlotMethods.IsHills = function(p) return p._s.hills == true end
PlotMethods.IsRiver = function(p) return p._s.river == true end
PlotMethods.IsMountain = function(p) return p._s.mountain == true end

-- 水域与通行（E2/CityView/CityView.lua:2086；Gameplay/Lua/MapGenerator.lua:618）
PlotMethods.IsWater = function(p)
    local row = p._w.info.Terrains[p._s.terrain]
    return row ~= nil and row.water == true
end
PlotMethods.IsImpassable = function(p) return p._s.impassable == true end

-- 战斗动画中（E2/WorldView/WorldView.lua:418）
PlotMethods.IsFighting = function(p) return p._s.fighting == true end

-- 改良与资源（E2/WorldView/UnitPanel.lua:1452；E2/PlotMouseoverInclude.lua:215-216）
-- GetResourceType 的参数是队伍 ID，对该队伍尚未探明时返回负值。
PlotMethods.GetImprovementType = function(p) return p._s.improvement end
PlotMethods.GetResourceType = function(p, team)
    local known = p._s.resourceKnownBy
    if known == false then return -1 end
    if known == nil or known[team] == true then return p._s.resource end
    return -1
end

-- 官方右键闸门（E2/WorldView/WorldView.lua:692）。两者的精确语义未知，见文件头的近似说明。
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

-- 标识与归属（E2/UnitList.lua:116；E2/UnitFlagManager.lua:318、:86；E2/WorldView/UnitPanel.lua:425；
-- E2/PlotMouseoverInclude.lua:313；E2/UnitFlagManager.lua:206；E2/InGame.lua:466）
UnitMethods.GetID = function(u) return u._s.id end
UnitMethods.GetUnitType = function(u) return u._s.unitType end
-- GetName 返回的是文本键，要经 Locale.ConvertTextKey 转换
UnitMethods.GetName = function(u) return u._s.nameKey end
UnitMethods.GetDomainType = function(u) return u._s.domain end
UnitMethods.GetOwner = function(u) return u._s.owner end
UnitMethods.GetPlot = function(u) return u._w:getPlot(u._s.x, u._s.y) end
UnitMethods.GetX = function(u) return u._s.x end
UnitMethods.GetY = function(u) return u._s.y end

-- 血量与移动力（E2/PlotMouseoverInclude.lua:349；E2/UnitFlagManager.lua:387；
-- E2/WorldView/UnitPanel.lua:152、:639、:641）。MovesLeft / MaxMoves 返回原始移动力点数。
UnitMethods.GetDamage = function(u) return u._s.damage end
UnitMethods.GetCurrHitPoints = function(u) return u._s.maxHp - u._s.damage end
UnitMethods.GetMaxHitPoints = function(u) return u._s.maxHp end
UnitMethods.MovesLeft = function(u) return u._s.moves end
UnitMethods.MaxMoves = function(u) return u._s.maxMoves end

-- 战力与射程（E2/Popups/MilitaryOverview.lua:258、:265；E2/WorldView/UnitPanel.lua:626）
UnitMethods.GetBaseCombatStrength = function(u) return u._s.combat end
UnitMethods.GetBaseRangedCombatStrength = function(u) return u._s.rangedCombat end
UnitMethods.Range = function(u) return u._s.range end

-- 状态（E2/UnitList.lua:178；E2/WorldView/ActionInfoPanel.lua:539、:142；E2/UnitFlagManager.lua:649）
UnitMethods.GetFortifyTurns = function(u) return u._s.fortifyTurns end
-- 不设置 readyToMove 时按“还有移动力”推导
UnitMethods.IsReadyToMove = function(u)
    if u._s.readyToMove ~= nil then return u._s.readyToMove == true end
    return u._s.moves > 0
end
UnitMethods.IsPromotionReady = function(u) return u._s.promotionReady == true end
UnitMethods.IsAutomated = function(u) return u._s.automated == true end
UnitMethods.IsDelayedDeath = function(u) return u._s.delayedDeath == true end
UnitMethods.IsDead = function(u) return u._s.dead == true end

-- 类别与隐形（E2/UnitFlagManager.lua:83；E2/PlotMouseoverInclude.lua:302）
UnitMethods.IsCombatUnit = function(u) return u._s.isCombat == true end
UnitMethods.IsEmbarked = function(u) return u._s.embarked == true end
UnitMethods.IsInvisible = function(u, team) return u._s.invisibleTo[team] == true end

-- 射程攻击（UI/InGame/Bombardment.lua:33；E2/WorldView/WorldView.lua:423、:471）
UnitMethods.CanRangeStrike = function(u) return decide(u._s.canRangeStrike, u, nil) end
UnitMethods.CanRangeStrikeAt = function(u, x, y, ...)
    local w = u._w
    local pPlot = w:getPlot(x, y)
    S.record(w, { name = "CanRangeStrikeAt", self = u, args = { x, y, ... }, plot = pPlot })
    if pPlot == nil then return false end
    return decide(u._s.canRangeStrikeAt, u, keyOf(x, y), x, y, ...)
end

-- 攻击与架设（DLC/Expansion/Tutorial/lua/TutorialChecks.lua:1233、:2358）
UnitMethods.IsCanAttack = function(u)
    if u._s.canAttack ~= nil then return u._s.canAttack == true end
    return u._s.isCombat == true and u._s.moves > 0
end
UnitMethods.IsMustSetUpToRangedAttack = function(u) return u._s.mustSetUp == true end

-- 驻扎、休整与移动（E2/WorldView/UnitPanel.lua:1122；TutorialChecks.lua:552；CanMoveThrough 见计划 §9.4）
UnitMethods.IsEverFortifyable = function(u)
    if u._s.everFortifyable ~= nil then return u._s.everFortifyable == true end
    return u._s.isCombat == true
end
UnitMethods.IsHurt = function(u) return u._s.damage > 0 end
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

local CityMethods = {}

-- 标识与属性（E2/Popups/EconomicGeneralInfo.lua:670、:79、:112、:95、:73；E2/Popups/ProductionPopup.lua:304）
-- GetStrengthValue 返回的是 100 倍的城防值
CityMethods.GetID = function(c) return c._s.id end
CityMethods.GetName = function(c) return c._s.name end
CityMethods.GetPopulation = function(c) return c._s.pop end
CityMethods.GetX = function(c) return c._s.x end
CityMethods.GetY = function(c) return c._s.y end
CityMethods.GetMaxHitPoints = function(c) return c._s.maxHp end
CityMethods.GetDamage = function(c) return c._s.damage end
CityMethods.GetStrengthValue = function(c) return c._s.strength end

-- 状态（E2/Popups/EconomicGeneralInfo.lua:82、:85、:88；E2/CityBannerManager.lua:278、:270）
CityMethods.IsCapital = function(c) return c._s.isCapital == true end
CityMethods.IsPuppet = function(c) return c._s.isPuppet == true end
CityMethods.IsOccupied = function(c) return c._s.isOccupied == true end
CityMethods.IsResistance = function(c) return c._s.isResistance == true end
CityMethods.IsRazing = function(c) return c._s.isRazing == true end

-- 归属与地块（E2/Popups/EconomicGeneralInfo.lua:634；E2/WorldView/EnemyUnitPanel.lua:2163；
-- UI/InGame/Bombardment.lua:27；E2/CityView/CityView.lua:2025-2026；E2/CityBannerManager.lua:331）
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

-- 生产（E2/Popups/ProductionPopup.lua:222；E2/CityBannerManager.lua:371、:373、:422）
CityMethods.GetOrderQueueLength = function(c) return c._s.orderQueueLength end
CityMethods.IsProduction = function(c) return c._s.isProduction == true end
CityMethods.IsProductionProcess = function(c) return c._s.isProductionProcess == true end
CityMethods.GetProductionTurnsLeft = function(c) return c._s.productionTurnsLeft end
-- GetProductionNameKey 返回的是文本键
CityMethods.GetProductionNameKey = function(c) return c._s.productionNameKey end

-- 产出（E2/Popups/ProductionPopup.lua:289-293、:302-303；E2/Popups/EconomicGeneralInfo.lua:587、:120、:137-140；
-- E2/CityView/CityView.lua:862-873）
CityMethods.GetYieldRate = function(c, yieldType) return c._s.yields[yieldType] or 0 end
CityMethods.GetProductionModifier = function(c) return c._s.productionModifier end
CityMethods.FoodDifference = function(c) return c._s.foodNet end
CityMethods.GetJONSCulturePerTurn = function(c) return c._s.culturePerTurn end
CityMethods.GetFaithPerTurn = function(c) return c._s.faithPerTurn end
CityMethods.GetFood = function(c) return c._s.foodStore end
CityMethods.GrowthThreshold = function(c) return c._s.growthThreshold end
CityMethods.GetFoodTurnsLeft = function(c) return c._s.foodTurnsLeft end
-- IsFoodProduction 为真表示城市正在生产“避免增长”
CityMethods.IsFoodProduction = function(c) return c._s.foodGrowthBlocked == true end
CityMethods.FoodDifferenceTimes100 = function(c)
    if c._s.foodDiffTimes100 ~= nil then return c._s.foodDiffTimes100 end
    return c._s.foodNet * 100
end

-- 城防炮击（E2/CityBannerManager.lua:37；UI/InGame/Bombardment.lua:24、:287；E2/WorldView/WorldView.lua:518）
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

-- 购买（E2/Popups/ProductionPopup.lua:428、:432、:436、:449、:453、:457、:563、:571、:575、:593、:601、:605）
-- 官方只用两种参数组合：(false, false, …) 查“规则上能不能买”，(true, true, …) 查“现在买不买得起”。
-- 返回 nil 表示这组参数不在桩的模型里（例如查项目），调用处按假处理。
local function purchasePoolEntry(city, bTestVisible, bTestCost, unitID, buildingID, eYield)
    local pool
    if bTestVisible == false and bTestCost == false then
        pool = city._s.purchasable
    elseif bTestVisible == true and bTestCost == true then
        pool = city._s.affordable or city._s.purchasable
    else
        return nil
    end
    local currency = nil
    if eYield == YieldTypes.YIELD_GOLD then currency = "gold"
    elseif eYield == YieldTypes.YIELD_FAITH then currency = "faith" end
    if currency == nil then return nil end
    local entry = nil
    if unitID ~= nil and unitID >= 0 then
        entry = pool.units[unitID]
    elseif buildingID ~= nil and buildingID >= 0 then
        entry = pool.buildings[buildingID]
    end
    if entry == nil then return false end
    return entry[currency] == true
end

CityMethods.IsCanPurchase = function(c, bTestVisible, bTestCost, unitID, buildingID, projectID, eYield)
    local result = purchasePoolEntry(c, bTestVisible, bTestCost, unitID, buildingID, eYield)
    if result == nil then return false end
    return result
end
CityMethods.GetUnitPurchaseCost = function(c, unitID) return c._s.costs.unitGold[unitID] end
CityMethods.GetUnitFaithPurchaseCost = function(c, unitID) return c._s.costs.unitFaith[unitID] end
CityMethods.GetBuildingPurchaseCost = function(c, buildingID) return c._s.costs.bldGold[buildingID] end
CityMethods.GetBuildingFaithPurchaseCost = function(c, buildingID) return c._s.costs.bldFaith[buildingID] end

-- 买地（E2/CityView/CityView.lua:2143、:2146）。CanBuyPlotAt 的第三个参数为真表示忽略金币只看规则。
CityMethods.CanBuyPlotAt = function(c, x, y, ignoreCost)
    local key = keyOf(x, y)
    if ignoreCost == true then return c._s.canBuyPlotAt[key] == true end
    if c._s.canBuyPlotNow == nil then return c._s.canBuyPlotAt[key] == true end
    return c._s.canBuyPlotNow[key] == true
end
CityMethods.GetBuyPlotCost = function(c, x, y) return c._s.buyPlotCost[keyOf(x, y)] or 0 end

-- 真实建造的建筑数量（计划 §9.4：IGE/Panels/IGE_CitiesPanel.lua:151）
CityMethods.GetNumRealBuilding = function(c, buildingID) return c._s.realBuildings[buildingID] or 0 end

local PlayerMethods = {}

-- 归属与存活（E2/TopPanel.lua:11；E2/WorldView/ActionInfoPanel.lua:100；E2/PlotMouseoverInclude.lua:54；
-- UI/InGame/TurnProcessing.lua:60；E2/DiploList.lua:313；E2/Popups/CultureOverview.lua:1290）
PlayerMethods.GetTeam = function(p) return p._s.team end
PlayerMethods.IsTurnActive = function(p) return p._s.turnActive == true end
PlayerMethods.IsAlive = function(p) return p._s.alive == true end
PlayerMethods.IsMinorCiv = function(p) return p._s.minor == true end
PlayerMethods.IsBarbarian = function(p) return p._s.barbarian == true end
PlayerMethods.GetName = function(p) return p._s.name end
PlayerMethods.GetCivilizationShortDescription = function(p) return p._s.civ end

-- 经济（E2/TopPanel.lua:62-63、:34、:151、:173、:96；E2/WorldView/EnemyUnitPanel.lua:470）
PlayerMethods.GetGold = function(p) return p._s.gold end
PlayerMethods.CalculateGoldRate = function(p) return p._s.goldRate end
PlayerMethods.GetScience = function(p) return p._s.science end
PlayerMethods.GetTotalJONSCulturePerTurn = function(p) return p._s.culturePerTurn end
PlayerMethods.GetFaith = function(p) return p._s.faith end
PlayerMethods.GetTotalFaithPerTurn = function(p) return p._s.faithPerTurn end
PlayerMethods.GetExcessHappiness = function(p) return p._s.happiness end
PlayerMethods.IsGoldenAge = function(p) return p._s.goldenAge == true end

-- 资源（E2/TopPanel.lua:203；E2/Popups/HappinessInfo.lua:637）
PlayerMethods.GetNumResourceAvailable = function(p, resourceID) return p._s.resourcesAvailable[resourceID] or 0 end
PlayerMethods.GetNumResourceTotal = function(p, resourceID) return p._s.resourcesTotal[resourceID] or 0 end

-- 按创建顺序遍历单位与城市（E2/UnitList.lua:113；E2/Popups/EconomicGeneralInfo.lua:66）
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

-- 按编号取单位与城市（E2/UnitFlagManager.lua:81；E2/Popups/ProductionPopup.lua:73）
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

-- 回合阻塞与通知（E2/WorldView/ActionInfoPanel.lua:117-118、:399-403、:154）
PlayerMethods.GetEndTurnBlockingType = function(p) return p._s.blockingType end
PlayerMethods.GetEndTurnBlockingNotificationIndex = function(p) return p._s.blockingNotificationIndex end
PlayerMethods.GetNumNotifications = function(p) return #p._s.notifications end
-- GetNotificationIndex(i) 的参数是通知在列表里的下标（从 0 起），返回的是通知的编号
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
-- 可能返回已自动化的单位（ActionInfoPanel.lua:536 的官方注释）
PlayerMethods.GetFirstReadyUnit = function(p)
    for u in p:Units() do
        if (not u._s.dead) and u:IsReadyToMove() then return u end
    end
    return nil
end

local TeamMethods = {}

-- 交战关系（E2/CityBannerManager.lua:213）
TeamMethods.IsAtWar = function(t, otherTeam) return t._s.atWar[otherTeam] == true end

-- -----------------------------------------------------------------------------
-- 第 13 节：方法表的包装
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：makeObjectMeta(methodTable, ownerLabel)
-- 做什么：把一张原始方法表变成桩对象的元表。每个读方法被包一层：调用时先登记“被读过”
--     （见 S.touch），再转给原方法。方法表里没有的名字走 unknownMember。
-- 输入：methodTable，原始方法表；ownerLabel，对象名，用在守卫的报错信息里。
-- 输出：元表（只含 __index）。
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
-- 第 14 节：全局引擎对象的安装
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：S.playerTeamOf(w, playerID)
-- 做什么：取玩家所在的队伍。
-- 输入：w，世界；playerID，玩家编号。
-- 输出：队伍编号；玩家不存在时返回 -1。
-- -----------------------------------------------------------------------------
function S.playerTeamOf(w, playerID)
    local p = w.players[playerID]
    if p == nil then return -1 end
    return p._s.team
end

-- -----------------------------------------------------------------------------
-- 函数：S.visionTeamOf(w)
-- 做什么：取调用日志的参照队伍——主玩家（w.activePlayer）所在的队伍。
-- 输入：w，世界。
-- 输出：队伍编号。
-- -----------------------------------------------------------------------------
function S.visionTeamOf(w)
    return S.playerTeamOf(w, w.activePlayer)
end

-- -----------------------------------------------------------------------------
-- 函数：S.toLocale(key, ...)
-- 做什么：模拟 Locale 的文本转换。
--     用例用 w:addText 登记过的键返回登记的文本；
--     没登记的 TXT_KEY_ 键返回带尖括号的键名（带参数时一并拼上），便于断言“经过了转换”；
--     不是 TXT_KEY 开头的字符串原样返回。
-- 输入：key，文本键；…，格式参数。
-- 输出：字符串。
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
-- 做什么：由当前世界的全部行重建全局表 GameInfoTypes（Type 名 → 行号）。
-- 复用同一张表：理由同 S.resetGameDefines。
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
-- 做什么：造全局表 Players。范围内（0 .. MAX_PLAYERS-1）的槽位恒返回对象：
--     参战的槽位返回用例创建过的玩家；没参战的槽位当场造一个“死玩家”，缓存在世界里。
--     越界返回 nil。
-- 为什么先查参战玩家：被测代码可能先遍历过玩家表（把死玩家造了出来），
--     之后用例再 addPlayer 时，必须让活玩家生效。
-- -----------------------------------------------------------------------------
local function makePlayers(w)
    return setmetatable({}, {
        __index = function(_, index)
            local valid = (type(index) == "number" and index >= 0 and index == math.floor(index)
                and index < GameDefines.MAX_PLAYERS)
            if not valid then return nil end
            local player = w.players[index]
            if player ~= nil then return player end
            local dead = w.deadPlayers[index]
            if dead == nil then
                local spec = { id = index, alive = false, team = -1, name = "" }
                dead = setmetatable({ _kind = "player", _w = w, _s = fillDefaults(spec, PLAYER_FIELDS, "player") }, PlayerMT)
                w.deadPlayers[index] = dead
            end
            return dead
        end,
    })
end

-- -----------------------------------------------------------------------------
-- 函数：makeTeams(w)
-- 做什么：造全局表 Teams。队伍不存在时返回 nil（官方与原型都先判 nil）。
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
-- 做什么：造全局表 Map。
--     GetPlotXY(x, y, dx, dy) 等价于 GetPlot(x+dx, y+dy)，越界返回 nil；
--     PlotDistance 用桩的六边形距离；不模拟地图卷绕。
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
-- 做什么：造全局表 UI。
--     SelectUnit 与 ClearSelectionList 是计划 §3.3 允许的唯一例外：只改变桩的选中状态，
--     并把每次调用记进日志，供用例断言选中保护（P-1 至 P-4）的调用次数。
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
-- 做什么：造全局表 Game。
--     CanHandleAction 隐式作用于“当前选中的单位”：按该单位的 canHandleActions 判定，
--     没有选中单位、单位已死、动作不存在时都返回假。
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
-- 做什么：造全局表 GameInfo。每个表名对应一个表视图（见 newInfoView），首次访问时创建。
--     世界里没有的表名走 unknownMember：拼错表名不会悄悄得到一张空表。
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
-- 做什么：造一个“没有任何读接口”的全局对象（Network、Events、Modding）。
--     采集模块不该碰它们；一旦访问任何成员，就会得到陷阱或未实现函数。
-- -----------------------------------------------------------------------------
local function makeWriteOnlyObject(label)
    return setmetatable({}, { __index = function(_, key) return unknownMember(label, key) end })
end

-- -----------------------------------------------------------------------------
-- 函数：installGlobals(w)
-- 做什么：把世界对应的全部引擎全局对象装进全局环境。每建一个新世界就整体换一套。
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
-- 第 15 节：世界构建器
-- 每个布置方法在开头和结尾各作废一次基线快照（dirty）：开头一次是为了让方法内部
-- 若调用了读方法，不会把半成品状态拍成基线；结尾一次是保证下一次读之前按最终状态重拍。
-- -----------------------------------------------------------------------------

local WorldMethods = {}
local WorldMT = { __index = WorldMethods }

-- -----------------------------------------------------------------------------
-- 函数：newPlot(w, x, y)
-- 做什么：造一个地块，默认是草地、无地貌、未探索。全图只有草地一种地形，
--     其余地形由用例通过 setPlot 设置。
-- 输入：w，世界；x、y，坐标。
-- 输出：地块对象。
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
-- 做什么：把布置规格里的类型写法统一成行号：数字原样返回，字符串按 Type 列查行。
-- 失败行为：Type 名不存在时抛错，提示是哪张表。
-- 输入：w，世界；tableName，GameInfo 的表名；value，Type 名或行号。
-- 输出：行号。
-- -----------------------------------------------------------------------------
local function resolveType(w, tableName, value)
    if type(value) == "number" then return value end
    local rows = w.info[tableName]
    if rows ~= nil then
        for i = 0, rows.n - 1 do
            if rows[i].Type == value then return i end
        end
    end
    error("GameInfo." .. tableName .. " 里没有 Type=" .. tostring(value), 3)
end

-- -----------------------------------------------------------------------------
-- 函数：override(target, key, value)
-- 做什么：value 不为 nil 时才覆盖 target[key]，用于 setPlot 的“只改给出来的字段”。
-- -----------------------------------------------------------------------------
local function override(target, key, value)
    if value ~= nil then target[key] = value end
end

-- -----------------------------------------------------------------------------
-- 函数：w:getPlot(x, y)
-- 做什么：取地块。
-- 输入：x、y，坐标。
-- 输出：地块对象；坐标不是数字或越界时返回 nil。
-- -----------------------------------------------------------------------------
function WorldMethods:getPlot(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local row = self.plots[y]
    if row == nil then return nil end
    return row[x]
end

-- -----------------------------------------------------------------------------
-- 函数：w:addTeam(spec)
-- 做什么：创建一个队伍。
-- 输入：spec，{ id = 队伍编号, atWar = { [对方队伍] = true } }。
-- 输出：队伍对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addTeam(spec)
    dirty(self)
    local s = fillDefaults(spec, TEAM_FIELDS, "team")
    if s.id == nil then error("addTeam 必须给出 id", 2) end
    local team = setmetatable({ _kind = "team", _w = self, _s = s }, TeamMT)
    self.teams[s.id] = team
    dirty(self)
    return team
end

-- -----------------------------------------------------------------------------
-- 函数：w:ensureTeam(teamID)
-- 做什么：取队伍，不存在就创建（真实游戏里每个玩家都有自己的队伍）。
-- 输出：队伍对象。
-- -----------------------------------------------------------------------------
function WorldMethods:ensureTeam(teamID)
    local team = self.teams[teamID]
    if team == nil then
        team = self:addTeam({ id = teamID })
    end
    return team
end

-- -----------------------------------------------------------------------------
-- 函数：w:atWar(teamA, teamB, flag)
-- 做什么：设置两个队伍是否交战，双方对称记录。
-- 输入：teamA、teamB，队伍编号；flag，可省略，默认为真。
-- -----------------------------------------------------------------------------
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
-- 函数：w:addPlayer(spec)
-- 做什么：创建一个玩家，并保证它的队伍存在。可设置的字段见 PLAYER_FIELDS。
-- 输入：spec，玩家规格。省略 id 时从 0 起自动分配。
-- 输出：玩家对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addPlayer(spec)
    dirty(self)
    local s = fillDefaults(spec, PLAYER_FIELDS, "player")
    if s.id == nil then
        s.id = self.nextPlayerID
        self.nextPlayerID = self.nextPlayerID + 1
    end
    local player = setmetatable({ _kind = "player", _w = self, _s = s }, PlayerMT)
    self.players[s.id] = player
    if s.alive then self:ensureTeam(s.team) end
    dirty(self)
    return player
end

-- -----------------------------------------------------------------------------
-- 函数：assertOwnerAlive(w, owner, label)
-- 做什么：确认一个单位或城市的拥有者是参战玩家。
-- 为什么：拥有者不是存活玩家时，扫描类接口遍历“其他存活玩家”时根本看不到这个单位或城市，
--     用例会以为布置成功而实际没有。直接报错比静默无效好。
-- 输入：w，世界；owner，玩家编号；label，用在报错信息里。
-- -----------------------------------------------------------------------------
local function assertOwnerAlive(w, owner, label)
    local player = w.players[owner]
    if player == nil or not player._s.alive then
        error(label .. "：玩家 " .. tostring(owner) .. " 不存在或已死亡，请先 addPlayer", 3)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：w:addUnit(spec)
-- 做什么：创建一个单位并放到地图上，同时登记到拥有者的单位表与所在格的单位表。
--     可设置的字段见 UNIT_FIELDS。没给的字段按单位类型所在行推导：名称键、域、战力、射程、
--     最大移动力；isCombat 按“有战力”推导。
-- 输入：spec，单位规格，必须给出 owner、unitType、x、y。省略 id 时按拥有者从 0 起分配。
-- 输出：单位对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addUnit(spec)
    dirty(self)
    local s = fillDefaults(spec, UNIT_FIELDS, "unit")
    if s.owner == nil then error("addUnit 必须给出 owner", 2) end
    assertOwnerAlive(self, s.owner, "addUnit")
    if s.x == nil or s.y == nil then error("addUnit 必须给出 x、y", 2) end
    local plot = self:getPlot(s.x, s.y)
    if plot == nil then
        error("addUnit：坐标越界 (" .. tostring(s.x) .. "," .. tostring(s.y) .. ")", 2)
    end
    if s.unitType == nil then error("addUnit 必须给出 unitType", 2) end
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
            error("addUnit：玩家 " .. tostring(s.owner) .. " 已经有编号为 " .. tostring(s.id) .. " 的单位", 2)
        end
    end
    self.nextUnitID[s.owner] = math.max(self.nextUnitID[s.owner] or 0, s.id + 1)

    local unit = setmetatable({ _kind = "unit", _w = self, _s = s }, UnitMT)
    table.insert(owned, unit)
    table.insert(plot._s.units, unit)
    dirty(self)
    return unit
end

-- -----------------------------------------------------------------------------
-- 函数：w:addCity(spec)
-- 做什么：创建一座城市并放到地图上，同时登记到拥有者的城市表与所在格。
--     可设置的字段见 CITY_FIELDS。省略 name 时用 "城市编号"；省略 cityPlots 时只有中心格。
--     城市中心格若还没有归属，就归城市拥有者（真实游戏如此）。
-- 输入：spec，城市规格，必须给出 owner、x、y。省略 id 时按拥有者从 0 起分配。
-- 输出：城市对象。
-- -----------------------------------------------------------------------------
function WorldMethods:addCity(spec)
    dirty(self)
    local s = fillDefaults(spec, CITY_FIELDS, "city")
    if s.owner == nil then error("addCity 必须给出 owner", 2) end
    assertOwnerAlive(self, s.owner, "addCity")
    if s.x == nil or s.y == nil then error("addCity 必须给出 x、y", 2) end
    local plot = self:getPlot(s.x, s.y)
    if plot == nil then
        error("addCity：坐标越界 (" .. tostring(s.x) .. "," .. tostring(s.y) .. ")", 2)
    end
    if plot._s.city ~= nil then
        error("addCity：格 (" .. tostring(s.x) .. "," .. tostring(s.y) .. ") 上已经有一座城市", 2)
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
            error("addCity：玩家 " .. tostring(s.owner) .. " 已经有编号为 " .. tostring(s.id) .. " 的城市", 2)
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

-- -----------------------------------------------------------------------------
-- 函数：w:setPlot(x, y, spec)
-- 做什么：修改一个地块的属性，只改规格里给出来的字段。可设置的字段见 PLOT_FIELDS。
--     地形、地貌、改良、资源可以写 Type 名或行号；地貌、改良、资源写 false 表示“没有”。
--     revealed 与 visible 是 { [队伍] = 真/假 }，按队伍设置视野。
-- 输入：x、y，坐标；spec，地块规格。
-- 输出：地块对象。
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
-- 函数：w:show(team, x, y, flag)
-- 做什么：设置地块对某队伍“当前可见”。可见必然已探索，所以同时置为已探索。
-- 输入：team，队伍编号；x、y，坐标；flag，可省略，默认为真；为假时只取消可见。
-- 坐标越界时静默忽略，便于成片设置。
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

-- -----------------------------------------------------------------------------
-- 函数：w:reveal(team, x, y, flag)
-- 做什么：设置地块对某队伍“已探索”。flag 为假表示改成未探索，此时必然不可见。
-- 输入：同 w:show。只调用它（不调用 w:show）得到的正是“已探索但被迷雾覆盖”的格子。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：w:unreveal(team, x, y)
-- 做什么：把地块对某队伍改成未探索（黑雾）。
-- -----------------------------------------------------------------------------
function WorldMethods:unreveal(team, x, y)
    self:reveal(team, x, y, false)
end

-- -----------------------------------------------------------------------------
-- 函数：w:revealAll(team) / w:showAll(team) / w:unrevealAll(team)
-- 做什么：对全图一次性设置视野：全部已探索（迷雾）、全部可见、全部未探索。
-- -----------------------------------------------------------------------------
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
-- 函数：w:select(unit) / w:clearSelection() / w:setInterfaceMode(mode)
-- 做什么：直接布置界面状态（当前选中的单位、界面模式），不写调用日志。
--     这是用例在“摆场景”，不是被测代码的调用。界面状态不进世界快照。
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
-- 函数：w:addInfoRow(tableName, row)
-- 做什么：给世界的一张 GameInfo 表追加一行（表不存在就新建），并刷新 GameInfoTypes。
-- 输入：tableName，表名（如 "Units"、"Projects"）；row，行，必须带 Type 列。
-- 输出：新行的行号。
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

-- -----------------------------------------------------------------------------
-- 函数：w:addAction(row)
-- 做什么：给 GameInfoActions 追加一行（动作）。默认已有驻扎、警戒、休整、跳过、架设五个动作。
-- 输入：row，动作行，必须带 Type 列，如 { Type = "MISSION_SLEEP", Visible = true }。
-- 输出：新动作的行号。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：w:addText(key, text)
-- 做什么：登记一条界面文本，模拟本地化表。Locale 转换这个键时会返回登记的文本。
-- -----------------------------------------------------------------------------
function WorldMethods:addText(key, text)
    self.texts[key] = text
end

-- -----------------------------------------------------------------------------
-- 函数：w:unit(owner, id) / w:city(owner, id)
-- 做什么：按拥有者与编号取单位或城市对象，供布置规格之间互相引用（例如驻军）。
-- 输出：对象；找不到时返回 nil。
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
-- 函数：w:logOf(names)
-- 做什么：取出指定方法名的全部调用日志，按调用先后排列。
-- 输入：names，一个方法名或一组方法名，如 "CanMoveThrough" 或 { "CanMoveThrough", "CanRangeStrikeAt" }。
-- 输出：日志条目的数组。每条的字段见 S.record，另有 name、self、args。
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

-- -----------------------------------------------------------------------------
-- 函数：w:logCount(names)
-- 做什么：统计指定方法被调用了多少次。输入同 w:logOf。
-- 输出：次数。
-- -----------------------------------------------------------------------------
function WorldMethods:logCount(names)
    return #self:logOf(names)
end

-- -----------------------------------------------------------------------------
-- 函数：w:queriesOnInvisible(names)
-- 做什么：筛出“目标格当时不可见”的调用：迷雾格（已探索但不可见）或未探索格。
--     泄露回归（T-68）用它断言引擎判定没有以看不见的格子为目标被调用过。
-- 输入：names，同 w:logOf。
-- 输出：日志条目的数组；空数组表示没有这类调用。
-- -----------------------------------------------------------------------------
function WorldMethods:queriesOnInvisible(names)
    local out = {}
    for _, entry in ipairs(self:logOf(names)) do
        if entry.visible ~= true then
            table.insert(out, entry)
        end
    end
    return out
end

-- -----------------------------------------------------------------------------
-- 函数：w:clearLog()
-- 做什么：清空世界的调用日志。
-- -----------------------------------------------------------------------------
function WorldMethods:clearLog()
    self.log = {}
end

-- -----------------------------------------------------------------------------
-- 函数：S.describeEntry(entry)
-- 做什么：把一条调用日志转成一行文字，用在断言失败的提示里。
-- 输出：形如 “unit(1:0):CanRangeStrikeAt -> (6,5) visible=false revealed=true”，
--     或者 “CanHandleAction[MISSION_FORTIFY]”。
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
            .. " visible=" .. tostring(entry.visible) .. " revealed=" .. tostring(entry.revealed)
    end
    return caller .. name .. target
end

-- -----------------------------------------------------------------------------
-- 函数：S.describeLog(entries)
-- 做什么：把一组调用日志转成带编号的多行文字。
-- 输出：字符串；空数组返回 "(空)"。
-- -----------------------------------------------------------------------------
function S.describeLog(entries)
    if #entries == 0 then return "(空)" end
    local lines = {}
    for i, entry in ipairs(entries) do
        lines[i] = tostring(i) .. ") " .. S.describeEntry(entry)
    end
    return table.concat(lines, "\n")
end

-- -----------------------------------------------------------------------------
-- 第 16 节：建世界与用例边界
-- -----------------------------------------------------------------------------

-- S.newWorld 可用的选项字段
local WORLD_OPTION_FIELDS = fieldSet({
    "width", "height", "activePlayer", "turn", "processingMessages", "canEndTurn", "gameDefines",
    "teams", "players", "wars", "revealAll", "visibleAll", "units", "cities", "select",
}, {
    width = 24, height = 20, activePlayer = 0, turn = 1, processingMessages = false, canEndTurn = true,
})

-- 用例期间允许新增的全局名：只有被测模块自己的两个全局表（验收项 A-8）
local ALLOWED_CASE_GLOBALS = { CAB_Config = true, CAB_Collector = true }

-- 当前用例创建的世界列表，以及“当前世界”（Locale 转换查它的文本表）。
-- test_collector.lua 在每条用例开始时调用 S.beginCase 重建。
S.worlds = {}
S.currentWorld = nil

-- -----------------------------------------------------------------------------
-- 函数：globalNames()
-- 做什么：取当前全局环境里的全部名字。
-- 输出：{ [名字] = true }。
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
-- 做什么：创建一个合成世界，并把与它对应的引擎全局对象装进全局环境。
--     每条用例的世界互相独立：GameInfo 行、地块、玩家都是各自的一份。
-- 输入：opts，可省略。可用字段：
--     width / height        网格尺寸，默认 24×20（计划 §10.2 要求不小于 20×20）
--     activePlayer          主玩家编号，默认 0；决定调用日志的参照队伍
--     turn                  回合号，默认 1
--     processingMessages    引擎是否在处理消息，默认假
--     canEndTurn            UI.CanEndTurn() 的返回值，默认真
--     gameDefines           要覆盖的 GameDefines 键值
--     teams / players       批量创建队伍与玩家，规格同 addTeam / addPlayer
--     wars                  交战的队伍对，如 { { 0, 1 }, { 0, 3 } }
--     revealAll / visibleAll  让某个队伍全图已探索 / 全图可见，值是队伍编号
--     units / cities        批量创建单位与城市，规格同 addUnit / addCity
--     select                开局就选中的单位对象
-- 输出：世界对象 w。布置方法用冒号调用，如 w:addUnit{…}。
-- -----------------------------------------------------------------------------
function S.newWorld(opts)
    local o = fillDefaults(opts, WORLD_OPTION_FIELDS, "newWorld")
    local w = {
        width = o.width,
        height = o.height,
        plots = {},
        players = {},
        deadPlayers = {},
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
-- 做什么：一条用例开始前的准备：清空本条用例的世界与日志输出，建一个空白世界装进全局环境
--     （避免沿用上一条用例的世界），最后记下守卫记录与全局名的起始水位。
--     顺序不能反：建世界会安装 Players、Game 等引擎全局，水位必须在这之后才记。
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
-- 做什么：一条用例结束后的三项核对，任何一项不满足都算这条用例失败：
--     1. 世界快照：本条用例的每个世界，凡被读过（有基线快照的），现在的状态必须与基线一致；
--     2. 守卫记录：本条用例期间没有新的写入类调用，也没有调用桩未实现的方法；
--     3. 全局名：本条用例期间没有新建白名单之外的全局变量。
-- 输出：是否通过（布尔值），问题描述（字符串，通过时为空串）。
-- -----------------------------------------------------------------------------
function S.endCase()
    local problems = {}
    for _, w in ipairs(S.worlds) do
        if w._snapshot ~= nil then
            local now = S.snapshot(w)
            if now ~= w._snapshot then
                table.insert(problems, "世界状态在用例期间发生了变化（疑似写入）："
                    .. S.firstDiff(w._snapshot, now))
            end
        end
    end
    for i = S.marks.violations + 1, #S.guard.violations do
        local record = S.guard.violations[i]
        table.insert(problems, "触发只读守卫：" .. record.owner .. "." .. record.method .. "()")
    end
    for i = S.marks.missing + 1, #S.guard.missing do
        local record = S.guard.missing[i]
        table.insert(problems, "调用了桩未实现的方法：" .. record.owner .. "." .. record.method
            .. "()（请补桩，或检查调用写法）")
    end
    local newGlobals = {}
    for name in pairs(globalNames()) do
        if not S.marks.globals[name] and not ALLOWED_CASE_GLOBALS[name] then
            table.insert(newGlobals, name)
        end
    end
    if #newGlobals > 0 then
        table.sort(newGlobals)
        table.insert(problems, "用例期间新增了全局变量：" .. table.concat(newGlobals, ", "))
    end
    return #problems == 0, table.concat(problems, "\n")
end
