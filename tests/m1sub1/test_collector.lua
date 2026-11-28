-- =============================================================================
-- 文件：tests/m1sub1/test_collector.lua
-- 职责：M1Sub1（mod/Lua/CAB_Config.lua 与 mod/Lua/CAB_InfoCollector.lua）离线桩测试集。
-- 依赖：由 tests/run_m1sub1_tests.py 在加载 tests/m1sub1/engine_stubs.lua 后执行。
-- 对外契约：返回汇总表 { passed, failed, skipped, guardViolations, guardMissing, cases = {...} }。
--
-- 结构划分（对齐《docs/M1/M1Sub1/M1Sub1工作计划.md》WP1 ~ WP4）：
--   第 1 节  用例注册与断言工具库；
--   第 2 节  冒烟、静态红线与 CAB_Config 契约用例（T-00、T-01）；
--   第 3 节  引擎桩核心能力自检用例（T-02 ~ T-09）；
--   第 4 节  WP2 辅助函数与基础域查询接口用例（T-10 ~ T-18）；
--   第 5 节  WP3 全局态势汇总与单位局部战术上下文用例（T-19 ~ T-27）；
--   第 6 节  WP4 城市详情、城防目标与可购买项报价单用例（T-28 ~ T-35）；
--   第 7 节  运行器与收尾守卫（FW-01）。
-- =============================================================================

local S = CAB_TEST_STUBS
local cases = {}

-- -----------------------------------------------------------------------------
-- 第 1 节：用例注册与断言工具库
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：test(id, title, fn)
-- 做什么：按顺序注册一条测试用例。
-- 输入：id（编号字符串）、title（中文标题）、fn（无参执行闭包）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function test(id, title, fn)
    table.insert(cases, { id = id, title = title, fn = fn })
end

-- -----------------------------------------------------------------------------
-- 函数：skip(reason)
-- 做什么：主动跳过当前用例（例如被测模块尚未在当前 WP 创建）。
-- 输入：reason（跳过原因说明）。
-- -----------------------------------------------------------------------------
local function skip(reason)
    error({ __skip = true, reason = reason })
end

-- -----------------------------------------------------------------------------
-- 函数：fail(msg)
-- 做什么：立即以带调用栈的错误信息终止当前用例。
-- 输入：msg（失败原因）。
-- -----------------------------------------------------------------------------
local function fail(msg)
    error(msg .. "\n" .. debug.traceback(), 2)
end

-- -----------------------------------------------------------------------------
-- 函数：show(v)
-- 做什么：将值格式化为紧凑可读字符串，供断言失败日志展示。
-- 输入：v（任意值）。
-- 输出：可读字符串。
-- -----------------------------------------------------------------------------
local function show(v)
    local kind = type(v)
    if kind == "string" then
        return '"' .. v .. '"'
    elseif kind == "table" then
        if v._kind ~= nil then return S.describe(v) end
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

-- -----------------------------------------------------------------------------
-- 函数：isSame(a, b)
-- 做什么：深度结构相等比较（普通表按键递归比对，桩对象按引用身份比对）。
-- 输入：a, b（任意值）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 函数：sortedKeys(t)
-- 做什么：返回表全部键的确定性排序数组（数字在前，字符串在后）。
-- 输入：t（表）。
-- 输出：键数组。
-- -----------------------------------------------------------------------------
local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(x, y)
        if type(x) == type(y) then return x < y end
        return type(x) == "number"
    end)
    return keys
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

local function ne(actual, unexpected, msg)
    if actual == unexpected then
        fail(msg .. "：不应等于 " .. show(unexpected))
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
        fail(msg .. "：类型应为 " .. typeName .. "，实际 " .. type(actual) .. "（" .. show(actual) .. "）")
    end
end

-- -----------------------------------------------------------------------------
-- 函数：exactKeys(t, expectedKeys, msg)
-- 做什么：断言表的键集合与预期完全一致（不多不少），用于校验 DTO 契约与可空键省略。
-- 输入：t（目标表）、expectedKeys（预期键数组）、msg（断言说明）。
-- -----------------------------------------------------------------------------
local function exactKeys(t, expectedKeys, msg)
    isType(t, "table", msg)
    local actualKeys = sortedKeys(t)
    local want = {}
    for _, k in ipairs(expectedKeys) do
        want[#want + 1] = k
    end
    table.sort(want, function(x, y)
        if type(x) == type(y) then return x < y end
        return type(x) == "number"
    end)
    if not isSame(actualKeys, want) then
        fail(msg .. "：键集合应为 " .. show(want) .. "，实际 " .. show(actualKeys))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：throws(fn, msg) / notThrows(fn, msg)
-- 做什么：断言闭包必然抛错（返回错误字符串）或必然不抛错（透传返回值）。
-- -----------------------------------------------------------------------------
local function throws(fn, msg)
    local ok, err = pcall(fn)
    if ok then
        fail(msg .. "：应当抛错，实际正常返回")
    end
    return tostring(err)
end

local function notThrows(fn, msg)
    local results = { pcall(fn) }
    if not results[1] then
        fail(msg .. "：不应抛错，实际报错：" .. tostring(results[2]))
    end
    return unpack(results, 2, #results)
end

-- -----------------------------------------------------------------------------
-- 函数：countPlotsInRadius(cx, cy, radius)
-- 做什么：按官方 Map.GetPlotXY + Map.PlotDistance 包络扫描统计六边形盘内格数。
-- 输入：cx, cy（中心坐标）、radius（六边形半径）。
-- 输出：格数。
-- -----------------------------------------------------------------------------
local function countPlotsInRadius(cx, cy, radius)
    local count = 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            local pPlot = Map.GetPlotXY(cx, cy, dx, dy)
            if pPlot ~= nil then
                if Map.PlotDistance(cx, cy, pPlot:GetX(), pPlot:GetY()) <= radius then
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- -----------------------------------------------------------------------------
-- 函数：snapshotIncludes() / includeDiff(before)
-- 做什么：快照 S.includeCount 并计算期间新增的模块加载计数。
-- -----------------------------------------------------------------------------
local function snapshotIncludes()
    local snapshot = {}
    for name, n in pairs(S.includeCount) do
        snapshot[name] = n
    end
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

-- -----------------------------------------------------------------------------
-- 函数：globalSnapshot() / newGlobals(snapshot)
-- 做什么：记录并比对 _G 中新增的全局符号名（用于验收项 A-01）。
-- -----------------------------------------------------------------------------
local function globalSnapshot()
    local names = {}
    for name in pairs(_G) do
        names[name] = true
    end
    return names
end

local function newGlobals(snapshot)
    local added = {}
    for name in pairs(_G) do
        if not snapshot[name] then
            added[#added + 1] = name
        end
    end
    table.sort(added)
    return added
end

-- -----------------------------------------------------------------------------
-- 函数：ensureCollectorLoaded()
-- 做什么：确保 CAB_InfoCollector 已加载（兼容 --filter 单独执行 WP2+ 用例时跳过 T-00 的情况）。
-- -----------------------------------------------------------------------------
local function ensureCollectorLoaded()
    if CAB_Collector == nil then
        include("CAB_InfoCollector")
    end
end

local TWO_PLAYERS = {
    { id = 0, team = 0, civ = "Rome" },
    { id = 1, team = 1, civ = "Carthage" },
}

-- -----------------------------------------------------------------------------
-- 第 2 节：冒烟、静态红线与 CAB_Config 契约用例（T-00、T-01）
-- -----------------------------------------------------------------------------

test("T-00", "冒烟与静态红线：CAB_InfoCollector.lua 加载洁净、导出契约完整且不含禁令符号", function()
    if not S.hasModule("CAB_InfoCollector") then
        skip("mod/Lua/CAB_InfoCollector.lua 尚未创建（WP2 起实现）")
    end

    -- 静态源码红线扫查（A-05、A-06）
    local src, readErr = __py_read_file("mod/Lua/CAB_InfoCollector.lua")
    notNil(src, "应能读取 CAB_InfoCollector.lua 源码：" .. tostring(readErr))
    isNil(src:find("CanMoveOrAttackInto", 1, true), "A-05 红线：源码严禁出现 CanMoveOrAttackInto")
    isNil(src:find("AirRaidCore", 1, true), "A-06 红线：源码严禁出现 AirRaidCore")
    isNil(src:find("AR_EnumerateTargets", 1, true), "A-06 红线：源码严禁出现 AR_EnumerateTargets")

    local globalsBefore = globalSnapshot()
    local includesBefore = snapshotIncludes()

    local ok, err = pcall(include, "CAB_InfoCollector")
    truthy(ok, "include('CAB_InfoCollector') 应成功，实际报错：" .. tostring(err))

    isType(CAB_Collector, "table", "应导出全局表 CAB_Collector")
    -- A-01：仅允许加载自身与唯一依赖 CAB_Config 一次
    same(
        includeDiff(includesBefore),
        { CAB_InfoCollector = 1, CAB_Config = 1 },
        "CAB_InfoCollector 应仅 include CAB_Config 一次"
    )
    local allowed = { CAB_Collector = true, CAB_Config = true }
    for _, name in ipairs(newGlobals(globalsBefore)) do
        truthy(allowed[name] ~= nil, "CAB_InfoCollector 不得新增全局变量 " .. name)
    end

    -- 校验 M1Sub1 7 个复用辅助函数 + 10 个主查询接口（原 7 项 + WP5 3 项，共 17 项）已精确导出
    local expectedExports = {
        "SerializeUnitSummary",
        "SerializeEnemyUnit",
        "SerializeCitySummary",
        "InspectPlotUnits",
        "CanUnitMoveThrough",
        "HasSameClassFriendlyUnit",
        "FindGameActionIndex",
        "GetEmpireEconomy",
        "GetVisibilitySummary",
        "CaptureRevealedPlotsSet",
        "GetEndTurnStatus",
        "BuildTurnOverview",
        "BuildUnitContextAndCandidates",
        "GetCityDetail",
        "GetResearchOptions",
        "GetPolicyOptions",
        "GetUnitPromotions",
    }
    exactKeys(CAB_Collector, expectedExports, "CAB_Collector 应恰好导出 7 个辅助函数 + 10 个主查询接口")
    for _, fnName in ipairs(expectedExports) do
        isType(CAB_Collector[fnName], "function", "CAB_Collector." .. fnName .. " 应导出为 function")
    end
end)

test("T-01", "CAB_Config 契约：12 个键的类型、默认值、零嵌套依赖与零引擎调用", function()
    if not S.hasModule("CAB_Config") then
        skip("mod/Lua/CAB_Config.lua 尚未创建")
    end

    local EXPECTED = {
        DB_NAME = "Civ5AgentBridge",
        DB_VERSION = 1,
        CHUNK_SIZE_BYTES = 3000,
        POLL_INTERVAL_SEC = 0.20,
        HEARTBEAT_INTERVAL_SEC = 2.00,
        DEFAULT_UNIT_SETTLE_SEC = 0.35,
        PLOT_BUY_SETTLE_SEC = 0.10,
        MAX_SETTLE_TIMEOUT_SEC = 1.50,
        DEFAULT_SCAN_RADIUS = 3,
        DELTA_REVEAL_SCAN_RADIUS = 5,
        MAX_SCAN_RADIUS = 8,
        ENABLE_DEBUG_LOG = true,
    }

    local globalsBefore = globalSnapshot()
    local includesBefore = snapshotIncludes()
    local defaultWorld = S.worlds[1]
    defaultWorld:reveal(0, 0, 0)
    -- 触发一次只读访问以拍下世界基线（必须使用 local，避免污染全局 _G）
    local _vis = defaultWorld:getPlot(0, 0):IsVisible(0)
    falsy(_vis, "仅 reveal 后应不可见")

    local ok, err = pcall(include, "CAB_Config")
    truthy(ok, "include('CAB_Config') 应成功，实际报错：" .. tostring(err))

    isType(CAB_Config, "table", "应定义全局表 CAB_Config")
    exactKeys(CAB_Config, {
        "DB_NAME", "DB_VERSION", "CHUNK_SIZE_BYTES",
        "POLL_INTERVAL_SEC", "HEARTBEAT_INTERVAL_SEC",
        "DEFAULT_UNIT_SETTLE_SEC", "PLOT_BUY_SETTLE_SEC", "MAX_SETTLE_TIMEOUT_SEC",
        "DEFAULT_SCAN_RADIUS", "DELTA_REVEAL_SCAN_RADIUS", "MAX_SCAN_RADIUS",
        "ENABLE_DEBUG_LOG",
    }, "CAB_Config 应恰好包含 12 个规定键")
    same(CAB_Config, EXPECTED, "CAB_Config 全部键值应严格对齐设计文档 §4.1 与决策 D-06")

    isType(CAB_Config.DB_NAME, "string", "DB_NAME 应为 string")
    isType(CAB_Config.ENABLE_DEBUG_LOG, "boolean", "ENABLE_DEBUG_LOG 应为 boolean")
    for name, value in pairs(CAB_Config) do
        if name ~= "DB_NAME" and name ~= "ENABLE_DEBUG_LOG" then
            isType(value, "number", "CAB_Config." .. name .. " 应为 number")
        end
    end

    -- 零依赖：仅记录本次自身 include，不得触发任何嵌套 include 或引擎调用
    same(includeDiff(includesBefore), { CAB_Config = 1 }, "CAB_Config 不得触发其他 include")
    eq(#defaultWorld.log, 0, "加载 CAB_Config 不应触发任何引擎判定日志")
    for _, name in ipairs(newGlobals(globalsBefore)) do
        eq(name, "CAB_Config", "加载 CAB_Config 仅允许新增唯一全局 CAB_Config")
    end
end)

-- -----------------------------------------------------------------------------
-- 第 3 节：引擎桩核心能力自检用例（T-02 ~ T-09）
-- -----------------------------------------------------------------------------

test("T-02", "桩自检：Map.GetPlotXY 越界判空与 Odd-r 六边形距离/半径盘格数", function()
    local w = S.newWorld({ width = 24, height = 20 })
    eq(Map.GetPlot(10, 5), w:getPlot(10, 5), "Map.GetPlot 应返回同一地块对象")
    eq(Map.GetPlotXY(10, 5, 2, -1), w:getPlot(12, 4), "GetPlotXY 应等价于 GetPlot(x+dx, y+dy)")

    isNil(Map.GetPlotXY(10, 5, 14, 0), "x 正向越界应返回 nil")
    isNil(Map.GetPlotXY(10, 5, 0, 15), "y 正向越界应返回 nil")
    isNil(Map.GetPlotXY(10, 5, -11, 0), "x 负向越界应返回 nil")
    notNil(Map.GetPlot(23, 19), "右下角边界格应存在")
    eq(Map.GetNumPlots(), 480, "地图总格数")
    eq(Map.GetPlotByIndex(479), w:getPlot(23, 19), "GetPlotByIndex 按行优先编号")
    local gw, gh = Map.GetGridSize()
    eq(gw, 24, "GetGridSize 宽度")
    eq(gh, 20, "GetGridSize 高度")

    eq(countPlotsInRadius(10, 10, 0), 1, "半径 0 格数")
    eq(countPlotsInRadius(10, 10, 1), 7, "半径 1 格数")
    eq(countPlotsInRadius(10, 10, 2), 19, "半径 2 格数")
    eq(Map.PlotDistance(3, 4, 15, 9), Map.PlotDistance(15, 9, 3, 4), "六边形距离应对称")

    -- 验证偶数行 (10,6) 的 6 个精确邻接格（Odd-r 规则）
    local neighbors = {}
    for dx = -1, 1 do
        for dy = -1, 1 do
            local pPlot = Map.GetPlotXY(10, 6, dx, dy)
            if pPlot ~= nil then
                local x, y = pPlot:GetX(), pPlot:GetY()
                if Map.PlotDistance(10, 6, x, y) == 1 then
                    neighbors[#neighbors + 1] = x .. ":" .. y
                end
            end
        end
    end
    table.sort(neighbors)
    same(neighbors, { "10:5", "10:7", "11:6", "9:5", "9:6", "9:7" }, "偶数行 (10,6) 邻接格")
end)

test("T-03", "桩自检：视野、隐形与科技资源均按队伍严格隔离（F-01/F-02/F-06）", function()
    local w = S.newWorld()
    local pPlot = w:getPlot(5, 5)
    falsy(pPlot:IsRevealed(0), "初始应为黑雾未探索")
    falsy(pPlot:IsVisible(0), "初始应不可见")

    w:reveal(0, 5, 5)
    truthy(pPlot:IsRevealed(0), "reveal 后应已探索")
    falsy(pPlot:IsVisible(0), "仅 reveal 后仍处迷雾不可见")
    falsy(pPlot:IsRevealed(1), "队伍 0 探索不影响队伍 1")

    w:show(0, 5, 5)
    truthy(pPlot:IsRevealed(0), "可见必然蕴含已探索")
    truthy(pPlot:IsVisible(0), "show 后应实时可见")

    w:reveal(0, 5, 5, false)
    falsy(pPlot:IsRevealed(0), "取消探索后回到黑雾")
    falsy(pPlot:IsVisible(0), "黑雾必然不可见")

    w:show(0, 5, 5)
    w:show(0, 5, 5, false)
    truthy(pPlot:IsRevealed(0), "取消可见不撤销已探索")
    falsy(pPlot:IsVisible(0), "取消可见后退回迷雾")

    w:setPlot(6, 5, {
        visible = { [1] = true },
        revealed = { [2] = true },
        resource = "RESOURCE_IRON",
        resourceKnownBy = { [0] = true },
    })
    local q = w:getPlot(6, 5)
    truthy(q:IsVisible(1), "队伍 1 可见")
    truthy(q:IsRevealed(1), "队伍 1 已探索")
    falsy(q:IsRevealed(0), "队伍 0 未探索")
    truthy(q:IsRevealed(2), "队伍 2 已探索")
    falsy(q:IsVisible(2), "队伍 2 不可见")

    -- F-06：未解锁科技时资源必须返回 -1
    eq(q:GetResourceType(0), GameInfoTypes.RESOURCE_IRON, "已解锁科技队伍可见铁资源")
    eq(q:GetResourceType(1), -1, "未解锁科技队伍不可见铁资源")

    -- 批量视野
    w:revealAll(3)
    truthy(w:getPlot(0, 0):IsRevealed(3), "revealAll 生效")
    falsy(w:getPlot(0, 0):IsVisible(3), "revealAll 不应设为可见")
    w:showAll(3)
    truthy(w:getPlot(0, 0):IsVisible(3), "showAll 生效")
    w:unrevealAll(3)
    falsy(w:getPlot(0, 0):IsRevealed(3), "unrevealAll 生效")

    -- F-02：隐形单位按队伍独立
    w:addPlayer({ id = 0, team = 0 })
    local sub = w:addUnit({ owner = 0, unitType = "UNIT_TRIREME", x = 8, y = 8, invisibleTo = { [1] = true } })
    falsy(sub:IsInvisible(0), "对己方队伍不隐形")
    truthy(sub:IsInvisible(1), "对敌方队伍 1 隐形")
    falsy(sub:IsInvisible(2), "对未配置队伍 2 不隐形")
end)

test("T-04", "桩自检：GameInfo / GameInfoActions 0-based 视图、越界安全空表与世界隔离", function()
    local w = S.newWorld()
    eq(#GameInfo.Units, 8, "GameInfo.Units 行数")
    eq(GameInfo.Units[0].Type, "UNIT_WARRIOR", "0-based 首行")
    eq(GameInfo.Units[0].ID, 0, "行内 ID 字段")
    eq(GameInfo.Units["UNIT_ARCHER"].ID, 1, "按 Type 索引")
    eq(GameInfo.Units.UNIT_ARCHER.ID, 1, "点号按 Type 访问")

    local visited, lastIsEmpty = 0, false
    for i = 0, #GameInfo.Units do
        local row = GameInfo.Units[i]
        notNil(row, "GameInfo.Units[" .. i .. "] 不应为 nil")
        if i == #GameInfo.Units then
            lastIsEmpty = (next(row) == nil)
        elseif row.Type ~= nil then
            visited = visited + 1
        end
    end
    eq(visited, 8, "官方 0..#Table 循环应完整遍历全部有效行")
    truthy(lastIsEmpty, "越界项应返回空表")
    isNil(GameInfo.Units[-1].Type, "负索引返回空表")

    local n = 0
    for row in GameInfo.Resources() do
        n = n + 1
        isType(row.Type, "string", "迭代器应返回有效行")
    end
    eq(n, 4, "Resources 迭代器行数")
    eq(
        Game.GetResourceUsageType(GameInfo.Resources["RESOURCE_HORSE"].ID),
        ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC,
        "战略资源用途"
    )

    eq(#GameInfoActions, 5, "默认动作行数")
    eq(GameInfoActions[0].Type, "MISSION_FORTIFY", "动作首行 Type")
    eq(GameInfoTypes.MISSION_HEAL, 2, "GameInfoTypes 动作索引")
    eq(GameInfoTypes.UNIT_ARCHER, 1, "GameInfoTypes 单位索引")

    -- 增行仅作用于当前世界
    local newID = w:addInfoRow("Units", { Type = "UNIT_TEST", Description = "TXT_KEY_UNIT_TEST" })
    eq(newID, 8, "新增行号")
    eq(#GameInfo.Units, 9, "当前世界行数递增")
    eq(GameInfoTypes.UNIT_TEST, 8, "GameInfoTypes 同步刷新")
    local _other = S.newWorld()
    notNil(_other, "新世界应创建成功")
    eq(#GameInfo.Units, 8, "新世界不应受上一世界增行影响")
end)

test("T-05", "桩自检：调用日志与迷雾侧信道筛选（区分可见、普通迷雾、已探索敌城与越界）", function()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } }, revealAll = 0 })
    w:show(0, 11, 5)
    w:show(0, 13, 5)
    w:show(0, 9, 5)
    w:show(0, 8, 5)
    -- (12,5) 处于普通迷雾；(14,5) 处于迷雾且为交战敌国城市（F-03 允许探测）
    w:addCity({ owner = 1, name = "Carthage", x = 14, y = 5 })

    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 10, y = 5,
        canRangeStrike = true,
        canRangeStrikeAt = { ["11:5"] = true, ["12:5"] = true, ["14:5"] = true },
        canMoveThrough = { ["9:5"] = true },
    })

    truthy(archer:CanRangeStrike(), "canRangeStrike 配置生效")
    truthy(archer:CanRangeStrikeAt(11, 5, true, true), "可见格探测")
    truthy(archer:CanRangeStrikeAt(12, 5, true, true), "普通迷雾格探测")
    truthy(archer:CanRangeStrikeAt(14, 5, true, true), "已探索敌对城市迷雾格探测")
    falsy(archer:CanRangeStrikeAt(13, 5, true, true), "未配置格返回 false")
    falsy(archer:CanRangeStrikeAt(999, 999, true, true), "越界坐标返回 false 且不报错")
    truthy(archer:CanMoveThrough(w:getPlot(9, 5)), "canMoveThrough 配置生效")
    falsy(archer:CanMoveThrough(w:getPlot(8, 5)), "未配置格返回 false")

    eq(w:logCount("CanRangeStrikeAt"), 5, "CanRangeStrikeAt 总调用次数")
    eq(w:logCount("CanMoveThrough"), 2, "CanMoveThrough 总调用次数")

    local log = w:logOf("CanRangeStrikeAt")
    eq(log[1].x, 11, "第 1 条目标 x")
    truthy(log[1].visible, "第 1 条实时可见")
    falsy(log[2].visible, "第 2 条普通迷雾不可见")
    truthy(log[2].revealed, "第 2 条普通迷雾已探索")
    falsy(log[2].isHostileCity, "第 2 条非敌城")
    falsy(log[3].visible, "第 3 条敌城处迷雾不可见")
    truthy(log[3].revealed, "第 3 条敌城已探索")
    truthy(log[3].isHostileCity, "第 3 条识别为已探索敌对城市")
    isNil(log[5].x, "第 5 条越界目标无坐标")

    -- queriesOnInvisible 仅计入地图内非可见格（(12,5) 与 (14,5)），不混淆越界调用
    local invisible = w:queriesOnInvisible({ "CanRangeStrikeAt", "CanMoveThrough" })
    eq(#invisible, 2, "地图内不可见格调用应为 2 次")
    eq(#w:queriesOutOfBounds("CanRangeStrikeAt"), 1, "越界调用单独计为 1 次")
    same(w:queriesOnInvisible("CanMoveThrough"), {}, "CanMoveThrough 未对不可见格调用")

    -- F-03 专项筛选：仅把普通迷雾格 (12,5) 判为违禁探测，放行已探索敌对城市 (14,5)
    local forbidden = w:queriesOnForbiddenFog("CanRangeStrikeAt")
    eq(#forbidden, 1, "F-03 违禁迷雾探测仅应命中普通迷雾格 (12,5)")
    eq(forbidden[1].x, 12, "违禁探测目标 x")
    eq(forbidden[1].y, 5, "违禁探测目标 y")

    -- 函数式判定支持
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 6,
        canMoveThrough = function(_, pPlot) return pPlot:IsRiver() end,
    })
    w:setPlot(10, 7, { river = true })
    truthy(warrior:CanMoveThrough(w:getPlot(10, 7)), "函数式判定：有河返回 true")
    falsy(warrior:CanMoveThrough(w:getPlot(9, 7)), "函数式判定：无河返回 false")

    w:clearLog()
    eq(w:logCount({ "CanRangeStrikeAt", "CanMoveThrough" }), 0, "clearLog 后计数归零")
end)

test("T-06", "桩自检：只读守卫、DLL 避坑陷阱与允许的选区探测例外（A-03/A-05）", function()
    local w = S.newWorld({ players = { { id = 0, team = 0 } } })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local c = w:addCity({ owner = 0, name = "Rome", x = 6, y = 5 })
    local pPlot = w:getPlot(5, 5)
    local base = #S.guard.violations

    local traps = {
        { "SetScriptData", function() u:SetScriptData("x") end },
        { "SetRevealed", function() pPlot:SetRevealed(0, true) end },
        { "CityPurchaseBuilding", function() Game.CityPurchaseBuilding(c, 0, 0) end },
        { "CityPurchaseUnit", function() Game.CityPurchaseUnit(c, 0, 0) end },
        { "CityPushOrder", function() Game.CityPushOrder(c, 0, 0) end },
        { "SendCityBuyPlot", function() Network.SendCityBuyPlot(0, 1, 1) end },
        { "HandleAction", function() Game.HandleAction(0) end },
        { "DoControl", function() Game.DoControl(7) end },
        { "SelectionListMove", function() Game.SelectionListMove(pPlot, false, false, false) end },
        { "SelectionListGameNetMessage", function() Game.SelectionListGameNetMessage(1, 1, 1, 1, 0, false, false) end },
        { "ActivateNotification", function() Players[0]:ActivateNotification(0) end },
        { "RemoveNotification", function() Players[0]:RemoveNotification(0) end },
    }
    for _, trap in ipairs(traps) do
        local err = throws(trap[2], trap[1] .. " 必须抛错")
        truthy(err:find("只读守卫", 1, true) ~= nil, trap[1] .. " 报错应来自只读守卫，实际：" .. err)
    end
    eq(#S.guard.violations, base + #traps, "全部显式写入接口均应落账")

    -- Set* 前缀自动拦截
    throws(function() Players[0]:SetGold(999) end, "SetGold 必须拦截")
    throws(function() UI.SetInterfaceMode(1) end, "UI.SetInterfaceMode 必须拦截")

    -- A-05：原版 DLL 缺陷方法 CanMoveOrAttackInto 必须被拦截
    local dllErr = throws(function() u:CanMoveOrAttackInto(pPlot) end, "CanMoveOrAttackInto 必须拦截")
    truthy(dllErr:find("引擎避坑红线", 1, true) ~= nil, "CanMoveOrAttackInto 应报引擎避坑红线")

    eq(#S.guard.violations, base + #traps + 3, "Set* 前缀与 DLL 避坑红线均应落账")

    -- 唯一允许的 UI 选区探测例外：不触发守卫违规，但记录日志
    UI.SelectUnit(u)
    UI.ClearSelectionList()
    eq(#S.guard.violations, base + #traps + 3, "UI.SelectUnit 与 ClearSelectionList 不触发违规")
    eq(w:logCount("SelectUnit"), 1, "SelectUnit 应记日志")
    eq(w:logOf("SelectUnit")[1].self, u, "SelectUnit 日志含单位引用")
    eq(w:logCount("ClearSelectionList"), 1, "ClearSelectionList 应记日志")

    -- 清理本用例人为触发的守卫记录，使边界核对通过
    for i = #S.guard.violations, base + 1, -1 do
        S.guard.violations[i] = nil
    end
    eq(#S.guard.violations, base, "测试用人为违规记录已清理")
end)

test("T-07", "桩自检：Players 三种槽位形态（存活/死玩家/nil）与交战对称性", function()
    local w = S.newWorld({ players = { { id = 0, team = 0 }, { id = 1, team = 1 } } })
    truthy(Players[0]:IsAlive(), "参战玩家存活")
    falsy(Players[5]:IsAlive(), "未参战有效槽位默认为死玩家对象")
    notNil(Players[5], "未参战有效槽位非 nil")
    isNil(Players[99999], "越界编号为 nil")

    -- 显式 nil 槽位（用于测试 IGE / 边界空槽防护）
    w:setNilPlayerSlot(6, true)
    isNil(Players[6], "显式标记的 nil 槽位应返回 nil")

    local alive = 0
    for i = 0, GameDefines.MAX_CIV_PLAYERS - 1 do
        local p = Players[i]
        if p and p:IsAlive() then
            alive = alive + 1
        end
    end
    eq(alive, 2, "存活玩家计数")

    local late = w:addPlayer({ id = 7, team = 7 })
    truthy(Players[7]:IsAlive(), "后加入玩家应立即生效")
    eq(Players[7], late, "Players[7] 返回新创建玩家对象")
    eq(S.playerTeamOf(w, 5), -1, "未参战玩家队伍为 -1")
    eq(S.playerTeamOf(w, 7), 7, "新玩家队伍为 7")
    falsy(Teams[7]:IsAtWar(0), "新建队伍默认和平")
    isNil(Teams[9], "不存在队伍为 nil")

    w:atWar(0, 1)
    truthy(Teams[0]:IsAtWar(1), "交战关系正向为真")
    truthy(Teams[1]:IsAtWar(0), "交战关系反向对称")
end)

test("T-08", "桩自检：深层世界快照精准检出全部实体状态修改，且忽略 UI 选中态", function()
    local w = S.newWorld({ players = { { id = 0, team = 0 }, { id = 1, team = 1 } } })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local c = w:addCity({ owner = 0, name = "Rome", x = 6, y = 5, pop = 4 })
    local pPlot = w:getPlot(5, 5)
    isNil(w._snapshot, "首次读取前不应生成基线快照")

    local _ux = u:GetX()
    eq(_ux, 5, "读取单位坐标以触发首次基线快照")
    local baseline = w._snapshot
    notNil(baseline, "首次读取后必须生成基线快照")
    eq(S.snapshot(w), baseline, "无变更时快照完全一致")

    local function assertDetectsMutation(label, change, restore)
        change()
        ne(S.snapshot(w), baseline, label .. " 之后快照必须变化")
        restore()
        eq(S.snapshot(w), baseline, label .. " 还原后快照必须恢复一致")
    end

    assertDetectsMutation("改单位血量", function() u._s.damage = 10 end, function() u._s.damage = 0 end)
    assertDetectsMutation("改城市人口", function() c._s.pop = 9 end, function() c._s.pop = 4 end)
    assertDetectsMutation("改玩家金币", function() Players[0]._s.gold = 999 end, function() Players[0]._s.gold = 0 end)
    assertDetectsMutation("改地块丘陵", function() pPlot._s.hills = true end, function() pPlot._s.hills = false end)
    assertDetectsMutation("改地块视野", function() pPlot._s.revealed[0] = true end, function() pPlot._s.revealed[0] = nil end)
    assertDetectsMutation("改 GameInfo 行", function() w.info.Units[0].Combat = 99 end, function() w.info.Units[0].Combat = 8 end)
    assertDetectsMutation("改交战状态", function() w.teams[1]._s.atWar[0] = true end, function() w.teams[1]._s.atWar[0] = nil end)
    assertDetectsMutation("改 GameDefines", function() GameDefines.MAX_HIT_POINTS = 1 end, function() GameDefines.MAX_HIT_POINTS = 100 end)

    -- 界面选中态允许临时变动，不进入快照
    UI.SelectUnit(u)
    eq(S.snapshot(w), baseline, "切换 UI 选中态不应改变世界快照")

    u._s.damage = 10
    local diff = S.firstDiff(baseline, S.snapshot(w))
    truthy(diff:find("=>", 1, true) ~= nil, "firstDiff 应输出前后对照片段")
    u._s.damage = 0
end)

test("T-09", "桩自检：单位、城市、玩家全量只读方法映射与 IGE 变阵助手", function()
    local w = S.newWorld({
        players = {
            {
                id = 0, team = 0, civ = "Rome", name = "Augustus", goldenAge = true,
                gold = 150, goldRate = 7, science = 12, culturePerTurn = 5, faith = 40, faithPerTurn = 3,
                happiness = 9, resourcesAvailable = { [0] = 4, [1] = 0 }, resourcesTotal = { [0] = 6 },
            },
            {
                id = 1, team = 1, turnActive = false,
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION,
                blockingNotificationIndex = 7,
                notifications = {
                    { index = 3, summary = "A", str = "a" },
                    { index = 7, summary = "Need production", str = "Pick something" },
                },
            },
        },
        gameDefines = { BUY_PLOTS_DISABLED = 1 },
    })
    local p = Players[0]

    -- 单位全量只读属性
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 10, y = 5, nameKey = "TXT_KEY_MY_ARCHER",
        damage = 30, maxHp = 100, moves = 60, maxMoves = 120, range = 3, fortifyTurns = 2,
        readyToMove = false, promotionReady = true, automated = true, delayedDeath = true,
        isCombat = true, embarked = true, invisibleTo = { [1] = true },
        canRangeStrike = true, canAttack = false, canFortify = true, mustSetUp = true,
        everFortifyable = false,
    })
    eq(u:GetID(), 0, "GetID")
    eq(u:GetUnitType(), 1, "GetUnitType")
    eq(u:GetName(), "TXT_KEY_MY_ARCHER", "GetName")
    eq(u:GetOwner(), 0, "GetOwner")
    eq(u:GetDomainType(), DomainTypes.DOMAIN_LAND, "GetDomainType")
    eq(u:GetX(), 10, "GetX")
    eq(u:GetY(), 5, "GetY")
    eq(u:GetPlot(), w:getPlot(10, 5), "GetPlot")
    eq(u:GetDamage(), 30, "GetDamage")
    eq(u:GetCurrHitPoints(), 70, "GetCurrHitPoints")
    eq(u:GetMaxHitPoints(), 100, "GetMaxHitPoints")
    eq(u:MovesLeft(), 60, "MovesLeft")
    eq(u:MaxMoves(), 120, "MaxMoves")
    eq(u:GetBaseCombatStrength(), 5, "GetBaseCombatStrength")
    eq(u:GetBaseRangedCombatStrength(), 9, "GetBaseRangedCombatStrength")
    eq(u:Range(), 3, "Range")
    eq(u:GetFortifyTurns(), 2, "GetFortifyTurns")
    falsy(u:IsReadyToMove(), "IsReadyToMove")
    truthy(u:IsPromotionReady(), "IsPromotionReady")
    truthy(u:IsAutomated(), "IsAutomated")
    truthy(u:IsDelayedDeath(), "IsDelayedDeath")
    falsy(u:IsDead(), "IsDead")
    truthy(u:IsCombatUnit(), "IsCombatUnit")
    truthy(u:IsEmbarked(), "IsEmbarked")
    truthy(u:IsInvisible(1), "IsInvisible(1)")
    falsy(u:IsInvisible(0), "IsInvisible(0)")
    truthy(u:CanRangeStrike(), "CanRangeStrike")
    falsy(u:IsCanAttack(), "IsCanAttack")
    truthy(u:CanFortify(u:GetPlot()), "CanFortify")
    truthy(u:IsMustSetUpToRangedAttack(), "IsMustSetUpToRangedAttack")
    falsy(u:IsEverFortifyable(), "IsEverFortifyable")
    truthy(u:IsHurt(), "IsHurt")
    falsy(u:CanHeal(u:GetPlot()), "CanHeal")

    -- 默认属性推导（战斗单位 vs 民用单位）
    local warrior = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 6 })
    eq(warrior:GetID(), 1, "单位编号递增")
    eq(warrior:GetName(), "TXT_KEY_UNIT_WARRIOR", "默认名称键")
    eq(warrior:MaxMoves(), 120, "默认最大移动力")
    eq(warrior:MovesLeft(), 120, "默认剩余移动力")
    truthy(warrior:IsCombatUnit(), "战斗单位默认推导")
    truthy(warrior:IsReadyToMove(), "默认可行动")
    truthy(warrior:IsEverFortifyable(), "战斗单位默认可驻扎")
    truthy(warrior:IsCanAttack(), "战斗单位默认可攻击")
    falsy(warrior:IsHurt(), "满血未受伤")

    local settler = w:addUnit({ owner = 0, unitType = "UNIT_SETTLER", x = 10, y = 7 })
    falsy(settler:IsCombatUnit(), "民用单位默认推导")
    falsy(settler:IsEverFortifyable(), "民用单位不可驻扎")
    falsy(settler:IsCanAttack(), "民用单位不可攻击")

    -- 城市全量只读属性与双层购买判定
    local c = w:addCity({
        owner = 0, name = "Rome", x = 10, y = 5, pop = 7, damage = 30, maxHp = 250, strength = 1234,
        isCapital = true, isPuppet = true, isOccupied = true, isResistance = true, isRazing = true,
        yields = {
            [YieldTypes.YIELD_FOOD] = 8,
            [YieldTypes.YIELD_PRODUCTION] = 6,
            [YieldTypes.YIELD_GOLD] = 5,
            [YieldTypes.YIELD_SCIENCE] = 4,
            [YieldTypes.YIELD_CULTURE] = 1,
            [YieldTypes.YIELD_FAITH] = 2,
        },
        productionModifier = 25, foodNet = 3, foodStore = 12, growthThreshold = 30, foodTurnsLeft = 6,
        culturePerTurn = 2, faithPerTurn = 1,
        orderQueueLength = 2, isProduction = true, isProductionProcess = false, productionTurnsLeft = 4,
        productionNameKey = "TXT_KEY_BUILDING_GRANARY",
        garrison = u, realBuildings = { [3] = 1, [0] = 2 },
        cityPlots = { { x = 10, y = 5 }, { x = 11, y = 5 }, { x = 10, y = 6 } },
        canRangeStrike = true, canRangeStrikeNow = true, canRangeStrikeAt = { ["11:6"] = true },
        purchasable = { units = { [1] = { gold = true, faith = true } }, buildings = { [2] = { gold = true } } },
        affordable = { units = { [1] = { gold = false, faith = true } }, buildings = {} },
        costs = { unitGold = { [1] = 500 }, unitFaith = { [1] = 300 }, bldGold = { [2] = 200 } },
        canBuyPlotAt = { ["11:5"] = true, ["10:6"] = true }, canBuyPlotNow = { ["11:5"] = true },
        buyPlotCost = { ["11:5"] = 60, ["10:6"] = 45 },
    })
    eq(c:GetID(), 0, "City:GetID")
    eq(c:GetName(), "Rome", "City:GetName")
    eq(c:GetPopulation(), 7, "City:GetPopulation")
    eq(c:GetMaxHitPoints(), 250, "City:GetMaxHitPoints")
    eq(c:GetDamage(), 30, "City:GetDamage")
    eq(c:GetStrengthValue(), 1234, "City:GetStrengthValue")
    truthy(c:IsCapital(), "IsCapital")
    truthy(c:IsPuppet(), "IsPuppet")
    truthy(c:IsOccupied(), "IsOccupied")
    truthy(c:IsResistance(), "IsResistance")
    truthy(c:IsRazing(), "IsRazing")
    eq(c:GetNumCityPlots(), 3, "GetNumCityPlots")
    eq(c:GetCityIndexPlot(2), w:getPlot(10, 6), "GetCityIndexPlot")
    isNil(c:GetCityIndexPlot(3), "GetCityIndexPlot 越界")
    eq(c:GetGarrisonedUnit(), u, "GetGarrisonedUnit")
    eq(c:GetYieldRate(YieldTypes.YIELD_FOOD), 8, "YIELD_FOOD")
    eq(c:GetYieldRate(YieldTypes.YIELD_PRODUCTION), 6, "YIELD_PRODUCTION")
    eq(c:FoodDifferenceTimes100(), 300, "FoodDifferenceTimes100")
    eq(c:GetNumRealBuilding(3), 1, "GetNumRealBuilding(3)")
    eq(c:GetNumRealBuilding(1), 0, "未建建筑为 0")

    truthy(c:IsCanPurchase(false, false, 1, -1, -1, YieldTypes.YIELD_GOLD), "规则允许金币购买单位")
    falsy(c:IsCanPurchase(true, true, 1, -1, -1, YieldTypes.YIELD_GOLD), "余额不足买不起金币单位")
    truthy(c:IsCanPurchase(true, true, 1, -1, -1, YieldTypes.YIELD_FAITH), "当前可用信仰购买单位")
    truthy(c:IsCanPurchase(false, false, -1, 2, -1, YieldTypes.YIELD_GOLD), "规则允许金币购买建筑")
    eq(c:GetUnitPurchaseCost(1), 500, "GetUnitPurchaseCost")
    eq(c:GetUnitFaithPurchaseCost(1, true), 300, "GetUnitFaithPurchaseCost")
    eq(c:GetBuildingPurchaseCost(2), 200, "GetBuildingPurchaseCost")
    eq(c:GetBuildingFaithPurchaseCost(2), 0, "未配置信仰价格默认返回 0")

    truthy(c:CanBuyPlotAt(11, 5, true), "买地规则允许")
    truthy(c:CanBuyPlotAt(11, 5, false), "买地当前买得起")
    truthy(c:CanBuyPlotAt(10, 6, true), "买地规则允许(10,6)")
    falsy(c:CanBuyPlotAt(10, 6, false), "买地当前买不起(10,6)")
    eq(c:GetBuyPlotCost(11, 5), 60, "GetBuyPlotCost")
    truthy(c:CanRangeStrikeNow(), "City:CanRangeStrikeNow")
    truthy(c:CanRangeStrikeAt(11, 6, true, true), "City:CanRangeStrikeAt")
    eq(GameDefines.BUY_PLOTS_DISABLED, 1, "GameDefines 覆盖项")

    -- 玩家与通知映射
    eq(p:GetGold(), 150, "GetGold")
    eq(p:CalculateGoldRate(), 7, "CalculateGoldRate")
    eq(p:GetScience(), 12, "GetScience")
    eq(p:GetTotalJONSCulturePerTurn(), 5, "GetTotalJONSCulturePerTurn")
    eq(p:GetFaith(), 40, "GetFaith")
    eq(p:GetTotalFaithPerTurn(), 3, "GetTotalFaithPerTurn")
    eq(p:GetExcessHappiness(), 9, "GetExcessHappiness")
    truthy(p:IsGoldenAge(), "IsGoldenAge")
    eq(p:GetNumResourceAvailable(0, true), 4, "GetNumResourceAvailable")
    eq(p:GetFirstReadyUnit(), warrior, "GetFirstReadyUnit 跳过未 ready 单位返回首个可动单位")

    local q = Players[1]
    falsy(q:IsTurnActive(), "非活动回合")
    eq(q:GetEndTurnBlockingType(), EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION, "阻塞类型")
    eq(q:GetEndTurnBlockingNotificationIndex(), 7, "阻塞通知编号")
    eq(q:GetNumNotifications(), 2, "通知总数")
    eq(q:GetNotificationIndex(1), 7, "通知下标映射")
    eq(q:GetNotificationSummaryStr(1), "Need production", "通知摘要")

    -- IGE 变阵助手验证（自动作废基线不触发误报）
    w:setPlayer(0, { gold = 777 })
    w:setUnit(warrior, { x = 11, y = 6, damage = 25 })
    w:setCity(c, { pop = 9 })
    eq(p:GetGold(), 777, "setPlayer 实时生效")
    eq(warrior:GetX(), 11, "setUnit 坐标迁移生效")
    eq(w:getPlot(11, 6):GetNumUnits(), 1, "迁移后新地块含该单位")
    eq(w:getPlot(10, 6):GetNumUnits(), 0, "迁移后旧地块已移除该单位")
    eq(c:GetPopulation(), 9, "setCity 实时生效")
end)

-- -----------------------------------------------------------------------------
-- 第 4 节：WP2 辅助函数与基础域查询接口用例（T-10 ~ T-18）
-- -----------------------------------------------------------------------------

test("T-10", "H1/H2：SerializeUnitSummary & SerializeEnemyUnit 契约、can_act 避坑与存活性过滤", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, name = "Augustus", civ = "Rome" },
            { id = 1, team = 1, name = "Hannibal", civ = "Carthage" },
            { id = 63, team = 63, name = "Barbarians", barbarian = true },
        },
    })
    w:addText("TXT_KEY_UNIT_ARCHER", "Archer")
    w:addText("TXT_KEY_UNIT_TRIREME", "Trireme")
    w:addText("TXT_KEY_UNIT_FIGHTER", "Fighter")

    -- 1. 正常可行动远程陆军（测试浮点截断与全字段键集合）
    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 5, y = 6,
        damage = 25, maxHp = 100, moves = 40, maxMoves = 120,
        fortifyTurns = 0, readyToMove = true,
    })
    local dto = CAB_Collector.SerializeUnitSummary(archer)
    notNil(dto, "存活单位应成功序列化")
    exactKeys(dto, {
        "__is_object", "unit_id", "name", "unit_type", "domain", "x", "y",
        "hp", "max_hp", "moves_left", "max_moves", "combat_str", "ranged_str",
        "range", "is_fortified", "can_act",
    }, "UnitSummaryDTO 键集合")
    truthy(dto.__is_object, "__is_object 标记")
    eq(dto.unit_id, 0, "unit_id")
    eq(dto.name, "Archer", "本地化名称")
    eq(dto.unit_type, "UNIT_ARCHER", "unit_type")
    eq(dto.domain, "LAND", "陆军域")
    eq(dto.x, 5, "x")
    eq(dto.y, 6, "y")
    eq(dto.hp, 75, "hp = maxHp - damage")
    eq(dto.max_hp, 100, "max_hp")
    eq(dto.moves_left, 0.66, "40/60 向下截断保留两位小数")
    eq(dto.max_moves, 2, "120/60 = 2.0")
    eq(dto.combat_str, 5, "combat_str")
    eq(dto.ranged_str, 9, "ranged_str")
    eq(dto.range, 2, "range")
    falsy(dto.is_fortified, "未驻扎")
    truthy(dto.can_act, "有移动力且 IsReadyToMove 为真时 can_act 应为 true")

    -- 2. A-05 避坑：已驻扎/已跳过单位即使 MovesLeft > 0，因 IsReadyToMove == false 必须 can_act == false
    local fortified = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 6, y = 6,
        moves = 120, maxMoves = 120, fortifyTurns = 2, readyToMove = false,
    })
    local fortDto = CAB_Collector.SerializeUnitSummary(fortified)
    truthy(fortDto.is_fortified, "fortifyTurns > 0 应标记 is_fortified = true")
    falsy(fortDto.can_act, "已驻扎/跳过单位尽管有剩余移动力，can_act 必须为 false")

    -- 3. 多域映射（SEA / AIR）与超额伤害 hp 下限归零
    local trireme = w:addUnit({ owner = 0, unitType = "UNIT_TRIREME", x = 7, y = 6, damage = 150, maxHp = 100 })
    local fighter = w:addUnit({ owner = 0, unitType = "UNIT_FIGHTER", x = 8, y = 6, moves = 0 })
    local seaDto = CAB_Collector.SerializeUnitSummary(trireme)
    local airDto = CAB_Collector.SerializeUnitSummary(fighter)
    eq(seaDto.domain, "SEA", "海军域")
    eq(seaDto.hp, 0, "hp 恒非负")
    eq(airDto.domain, "AIR", "空军域")
    falsy(airDto.can_act, "moves == 0 时 can_act 为 false")

    -- 4. nil / IsDead / IsDelayedDeath 统一过滤返回 nil
    local deadU = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 9, y = 6, dead = true })
    local delayedU = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 6, delayedDeath = true })
    isNil(CAB_Collector.SerializeUnitSummary(nil), "nil 单位返回 nil")
    isNil(CAB_Collector.SerializeUnitSummary(deadU), "已死亡单位返回 nil")
    isNil(CAB_Collector.SerializeUnitSummary(delayedU), "延迟死亡单位返回 nil")

    -- 5. SerializeEnemyUnit（常规敌国 + 蛮族 + 存活性过滤）
    local enemyArcher = w:addUnit({ owner = 1, id = 42, unitType = "UNIT_ARCHER", x = 12, y = 5, damage = 10 })
    local barbWarrior = w:addUnit({ owner = 63, id = 42, unitType = "UNIT_WARRIOR", x = 13, y = 5, damage = 35 })
    local eDto = CAB_Collector.SerializeEnemyUnit(enemyArcher)
    local bDto = CAB_Collector.SerializeEnemyUnit(barbWarrior)
    exactKeys(eDto, {
        "__is_object", "enemy_id", "owner_id", "owner_name", "is_barbarian",
        "unit_type", "x", "y", "hp", "combat_str", "ranged_str",
    }, "EnemyUnitDTO 键集合")
    eq(eDto.enemy_id, "1:42", "复合 enemy_id 防止跨玩家碰撞")
    eq(eDto.owner_id, 1, "owner_id")
    eq(eDto.owner_name, "Hannibal", "owner_name")
    falsy(eDto.is_barbarian, "常规文明非蛮族")
    eq(eDto.hp, 90, "敌军 hp")
    eq(bDto.enemy_id, "63:42", "蛮族相同 unitID 生成独立复合 ID")
    truthy(bDto.is_barbarian, "蛮族标记为 true")
    eq(bDto.hp, 65, "蛮族 hp")
    isNil(CAB_Collector.SerializeEnemyUnit(nil), "nil 敌军返回 nil")
    isNil(CAB_Collector.SerializeEnemyUnit(deadU), "死亡敌军返回 nil")
    isNil(CAB_Collector.SerializeEnemyUnit(delayedU), "延迟死亡敌军返回 nil")
end)

test("T-11", "H3：SerializeCitySummary 契约、产出字典、空生产回退与城防反击态", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ players = { { id = 0, team = 0, civ = "Rome" } } })
    w:addText("TXT_KEY_BUILDING_GRANARY", "Granary")

    local rome = w:addCity({
        owner = 0, id = 10, name = "Rome", x = 4, y = 5, pop = 6, damage = 45, maxHp = 250,
        productionNameKey = "TXT_KEY_BUILDING_GRANARY", productionTurnsLeft = 5,
        yields = {
            [YieldTypes.YIELD_FOOD] = 14,
            [YieldTypes.YIELD_PRODUCTION] = 9,
            [YieldTypes.YIELD_GOLD] = 7,
            [YieldTypes.YIELD_SCIENCE] = 8,
        },
        foodNet = 2, culturePerTurn = 4, faithPerTurn = 3,
        canRangeStrikeNow = true,
    })
    local idleCity = w:addCity({
        owner = 0, id = 11, name = "Antium", x = 8, y = 5, pop = 2, damage = 300, maxHp = 200,
        productionNameKey = "", productionTurnsLeft = 0, canRangeStrikeNow = false,
    })

    local dto = CAB_Collector.SerializeCitySummary(rome)
    exactKeys(dto, {
        "__is_object", "city_id", "name", "x", "y", "pop", "hp", "max_hp",
        "current_production", "turns_left", "yields", "can_range_strike",
    }, "CitySummaryDTO 键集合")
    exactKeys(dto.yields, {
        "__is_object", "food", "food_net", "production", "gold", "science", "culture", "faith",
    }, "CitySummaryDTO.yields 键集合")
    eq(dto.city_id, 10, "city_id")
    eq(dto.name, "Rome", "name")
    eq(dto.pop, 6, "pop")
    eq(dto.hp, 205, "hp = maxHp - damage")
    eq(dto.max_hp, 250, "max_hp")
    eq(dto.current_production, "Granary", "本地化生产项名")
    eq(dto.turns_left, 5, "turns_left")
    truthy(dto.can_range_strike, "can_range_strike")
    eq(dto.yields.food, 14, "food")
    eq(dto.yields.food_net, 2, "food_net")
    eq(dto.yields.production, 9, "production")
    eq(dto.yields.gold, 7, "gold")
    eq(dto.yields.science, 8, "science")
    eq(dto.yields.culture, 4, "culture")
    eq(dto.yields.faith, 3, "faith")

    local idleDto = CAB_Collector.SerializeCitySummary(idleCity)
    eq(idleDto.current_production, "NONE", "空生产键应回退为 NONE")
    eq(idleDto.hp, 0, "超额伤害城市 hp 恒非负")
    falsy(idleDto.can_range_strike, "不可炮击城市为 false")
    isNil(CAB_Collector.SerializeCitySummary(nil), "nil 城市返回 nil")
end)

test("T-12", "H4：InspectPlotUnits 军民叠栈优先主战单位与 F-02 隐形敌军屏蔽", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, visibleAll = 0 })

    -- 1. 己方工人先入格、战斗单位后入格：必须优先返回战斗单位 ID
    local worker = w:addUnit({ owner = 0, id = 1, unitType = "UNIT_WORKER", x = 5, y = 5 })
    local warrior = w:addUnit({ owner = 0, id = 2, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local settler = w:addUnit({ owner = 0, id = 3, unitType = "UNIT_SETTLER", x = 5, y = 5 })
    notNil(worker, "worker")
    notNil(warrior, "warrior")
    notNil(settler, "settler")
    local fid, edto = CAB_Collector.InspectPlotUnits(w:getPlot(5, 5), 0)
    eq(fid, 2, "军民叠栈应优先返回战斗单位 ID（不被后续民用单位覆盖）")
    isNil(edto, "无敌军时 enemyDto 应为 nil")

    -- 2. 敌方平民 + 主战叠栈 + 己方不可见的隐形敌军
    w:addUnit({ owner = 1, id = 10, unitType = "UNIT_WORKER", x = 6, y = 5 })
    w:addUnit({ owner = 1, id = 11, unitType = "UNIT_ARCHER", x = 6, y = 5 })
    local fid2, edto2 = CAB_Collector.InspectPlotUnits(w:getPlot(6, 5), 0)
    isNil(fid2, "无己方单位")
    notNil(edto2, "应检测到可见敌军")
    eq(edto2.enemy_id, "1:11", "敌方叠栈同样优先主战单位")

    -- 3. F-02：地块上仅有对己方队伍隐形的敌方单位（如潜艇）时必须完全屏蔽
    w:addUnit({ owner = 1, id = 20, unitType = "UNIT_TRIREME", x = 7, y = 5, invisibleTo = { [0] = true } })
    local fid3, edto3 = CAB_Collector.InspectPlotUnits(w:getPlot(7, 5), 0)
    isNil(fid3, "无己方单位")
    isNil(edto3, "F-02 红线：对己方隐形的敌军严禁导出")

    -- 4. 隐形主战与可见平民同格：跳过隐形主战，仅返回可见平民
    w:addUnit({ owner = 1, id = 21, unitType = "UNIT_TRIREME", x = 8, y = 5, invisibleTo = { [0] = true } })
    w:addUnit({ owner = 1, id = 22, unitType = "UNIT_WORKER", x = 8, y = 5 })
    local _, edto4 = CAB_Collector.InspectPlotUnits(w:getPlot(8, 5), 0)
    notNil(edto4, "同格可见敌方平民仍应可见")
    eq(edto4.enemy_id, "1:22", "跳过隐形主战后仅返回可见单位")

    -- 5. 死亡/延迟死亡单位不计入；nil 地块安全返回 nil, nil
    w:addUnit({ owner = 0, id = 30, unitType = "UNIT_WARRIOR", x = 9, y = 5, dead = true })
    w:addUnit({ owner = 1, id = 31, unitType = "UNIT_WARRIOR", x = 9, y = 5, delayedDeath = true })
    local fid5, edto5 = CAB_Collector.InspectPlotUnits(w:getPlot(9, 5), 0)
    isNil(fid5, "已死亡己方单位应忽略")
    isNil(edto5, "延迟死亡敌方单位应忽略")
    local nilF, nilE = CAB_Collector.InspectPlotUnits(nil, 0)
    isNil(nilF, "nil 地块返回 nil")
    isNil(nilE, "nil 地块返回 nil")
end)

test("T-13", "H5/H6/H7：CanUnitMoveThrough、1UPT 同类检查与 FindGameActionIndex", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS })

    -- H5: CanUnitMoveThrough
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        canMoveThrough = { ["6:5"] = true, ["4:5"] = false },
    })
    local deadU = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 6, dead = true, canMoveThrough = true })
    truthy(CAB_Collector.CanUnitMoveThrough(u, w:getPlot(6, 5)), "可通行格返回 true")
    falsy(CAB_Collector.CanUnitMoveThrough(u, w:getPlot(4, 5)), "不可通行格返回 false")
    falsy(CAB_Collector.CanUnitMoveThrough(deadU, w:getPlot(6, 5)), "死单位安全返回 false")
    falsy(CAB_Collector.CanUnitMoveThrough(nil, w:getPlot(6, 5)), "nil 单位返回 false")
    falsy(CAB_Collector.CanUnitMoveThrough(u, nil), "nil 地块返回 false")
    eq(w:logCount("CanMoveThrough"), 2, "仅对有效存活单位和有效地块调用引擎 CanMoveThrough")

    -- H6: HasSameClassFriendlyUnit（1UPT 战斗与民用分离，忽略敌军与死单位）
    w:addUnit({ owner = 0, unitType = "UNIT_WORKER", x = 10, y = 5 })
    w:addUnit({ owner = 1, unitType = "UNIT_WARRIOR", x = 10, y = 5 })
    w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 5, dead = true })
    w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 5, delayedDeath = true })
    falsy(CAB_Collector.HasSameClassFriendlyUnit(w:getPlot(10, 5), 0, true), "仅己方民用/敌军/死战时，战斗单位可停靠")
    truthy(CAB_Collector.HasSameClassFriendlyUnit(w:getPlot(10, 5), 0, false), "已有己方存活民用单位，民用单位不可停靠")
    w:addUnit({ owner = 0, unitType = "UNIT_ARCHER", x = 10, y = 5 })
    truthy(CAB_Collector.HasSameClassFriendlyUnit(w:getPlot(10, 5), 0, true), "加入己方存活战斗单位后，战斗单位不可停靠")
    falsy(CAB_Collector.HasSameClassFriendlyUnit(nil, 0, true), "nil 地块安全返回 false")

    -- H7: FindGameActionIndex（基于当前选中单位与 Game.CanHandleAction）
    local siege = w:addUnit({
        owner = 0, unitType = "UNIT_CATAPULT", x = 11, y = 5,
        canHandleActions = {
            MISSION_FORTIFY = true,
            MISSION_SET_UP_FOR_RANGED_ATTACK = true,
            MISSION_HEAL = false,
        },
    })
    w:clearSelection()
    isNil(CAB_Collector.FindGameActionIndex("MISSION_FORTIFY"), "未选中单位时动作不可执行")
    w:select(siege)
    eq(CAB_Collector.FindGameActionIndex("MISSION_FORTIFY"), GameInfoTypes.MISSION_FORTIFY, "命中驻扎动作索引")
    eq(
        CAB_Collector.FindGameActionIndex("MISSION_SET_UP_FOR_RANGED_ATTACK"),
        GameInfoTypes.MISSION_SET_UP_FOR_RANGED_ATTACK,
        "命中攻城架设动作索引"
    )
    isNil(CAB_Collector.FindGameActionIndex("MISSION_HEAL"), "当前不可执行动作返回 nil")
    isNil(CAB_Collector.FindGameActionIndex("MISSION_NOT_EXISTS"), "未知动作名返回 nil")
    isNil(CAB_Collector.FindGameActionIndex(nil), "nil 动作名返回 nil")
end)

test("T-14", "F1：GetEmpireEconomy 全量经济、战略/奢侈/加成资源分类与非法玩家兜底", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            {
                id = 0, team = 0, civ = "Rome", goldenAge = true,
                gold = 420, goldRate = 18, science = 35, culturePerTurn = 11,
                faith = 160, faithPerTurn = 6, happiness = -2,
                resourcesAvailable = {
                    [0] = 4, -- RESOURCE_HORSE (strategic, > 0 -> 收录)
                    [1] = 0, -- RESOURCE_IRON  (strategic, == 0 -> 过滤)
                    [2] = 2, -- RESOURCE_FUR   (luxury, > 0 -> 收录)
                    [3] = 5, -- RESOURCE_WHEAT (bonus -> 忽略)
                },
            },
            { id = 2, team = 2, alive = false, gold = 999 },
        },
    })
    w:setNilPlayerSlot(3, true)

    local econ = CAB_Collector.GetEmpireEconomy(0)
    exactKeys(econ, {
        "__is_object", "gold", "gold_per_turn", "science_per_turn", "culture_per_turn",
        "faith_per_turn", "faith_total", "happiness", "is_golden_age",
        "strategic_resources", "luxury_resources",
    }, "EconomyDTO 键集合")
    eq(econ.gold, 420, "gold")
    eq(econ.gold_per_turn, 18, "gold_per_turn")
    eq(econ.science_per_turn, 35, "science_per_turn")
    eq(econ.culture_per_turn, 11, "culture_per_turn")
    eq(econ.faith_per_turn, 6, "faith_per_turn")
    eq(econ.faith_total, 160, "faith_total")
    eq(econ.happiness, -2, "负快乐度应原样保留")
    truthy(econ.is_golden_age, "is_golden_age")
    same(econ.strategic_resources, { __is_object = true, RESOURCE_HORSE = 4 }, "战略资源仅含 >0 条目且带 __is_object")
    same(econ.luxury_resources, { __is_object = true, RESOURCE_FUR = 2 }, "奢侈资源仅含 >0 条目且不含加成小麦")

    -- 非法/死亡/nil/越界/非整数玩家均返回结构化 error DTO
    for _, badId in ipairs({ 2, 3, 5, -1, 999, 1.5, "0", nil }) do
        local errDto = CAB_Collector.GetEmpireEconomy(badId)
        truthy(errDto.__is_object, "错误返回应带 __is_object（id=" .. tostring(badId) .. "）")
        isType(errDto.error, "string", "非法玩家应返回 error 字符串（id=" .. tostring(badId) .. "）")
    end
end)

test("T-15", "F2：GetVisibilitySummary 全图迷雾分层、隐形屏蔽、敌城与城邦、双返回兜底（F-01/F-02/F-04/F-05）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, name = "Augustus", civ = "Rome" },
            { id = 1, team = 1, name = "Hannibal", civ = "Carthage" },
            { id = 2, team = 2, name = "Geneva", civ = "Geneva", minor = true },
            { id = 4, team = 4, name = "FallenCiv", alive = false },
            { id = 63, team = 63, name = "Barbarians", barbarian = true },
        },
        wars = { { 0, 1 }, { 0, 63 } },
    })
    w:setNilPlayerSlot(5, true)

    -- 视野布置：
    -- (5,5) 实时可见；(6,5) 实时可见（隐形敌军）；(7,5) 仅已探索迷雾；(8,5) 未探索黑雾
    -- (10,5) 实时可见敌城；(11,5) 迷雾已探索城邦；(12,5) 未探索黑雾敌城
    w:show(0, 5, 5)
    w:show(0, 6, 5)
    w:reveal(0, 7, 5)
    w:show(0, 10, 5)
    w:reveal(0, 11, 5)

    -- 己方单位不得出现在敌军列表
    w:addUnit({ owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    -- F-01：可见敌军 + 可见蛮族（相同 unitID 测跨玩家复合键）
    w:addUnit({ owner = 1, id = 1, unitType = "UNIT_ARCHER", x = 5, y = 5, damage = 20 })
    w:addUnit({ owner = 63, id = 1, unitType = "UNIT_WARRIOR", x = 5, y = 5, damage = 10 })
    -- F-02：可见格上的隐形敌军必须屏蔽
    w:addUnit({ owner = 1, id = 2, unitType = "UNIT_TRIREME", x = 6, y = 5, invisibleTo = { [0] = true } })
    -- F-01：迷雾格与黑雾格上的敌军必须屏蔽
    w:addUnit({ owner = 1, id = 3, unitType = "UNIT_WARRIOR", x = 7, y = 5 })
    w:addUnit({ owner = 1, id = 4, unitType = "UNIT_WARRIOR", x = 8, y = 5 })
    -- 死单位/延迟死单位必须屏蔽
    w:addUnit({ owner = 1, id = 5, unitType = "UNIT_WARRIOR", x = 5, y = 5, dead = true })
    w:addUnit({ owner = 1, id = 6, unitType = "UNIT_WARRIOR", x = 5, y = 5, delayedDeath = true })

    -- 城市：己方城不导出；可见交战敌城；迷雾和平城邦；黑雾敌城完全隐藏
    w:addCity({ owner = 0, id = 0, name = "Rome", x = 2, y = 2 })
    w:show(0, 2, 2)
    w:addCity({ owner = 1, id = 0, name = "Carthage", x = 10, y = 5, pop = 8, damage = 40, maxHp = 220 })
    w:addCity({ owner = 2, id = 0, name = "Geneva", x = 11, y = 5, pop = 5, damage = 0, maxHp = 200 })
    w:addCity({ owner = 1, id = 1, name = "Utica", x = 12, y = 5, pop = 4 })

    local summary, enemyMap = CAB_Collector.GetVisibilitySummary(0)
    exactKeys(summary, { "__is_object", "visible_enemies", "visible_enemy_cities" }, "VisibilitySummaryDTO 键集合")
    eq(#summary.visible_enemies, 2, "仅导出实时可见且非隐形的 2 个存活敌军")
    notNil(enemyMap["1:1"], "enemyMap 应包含敌国弓手 1:1")
    notNil(enemyMap["63:1"], "enemyMap 应包含蛮族勇士 63:1")
    isNil(enemyMap["1:2"], "F-02：隐形敌军严禁进入 enemyMap")
    isNil(enemyMap["1:3"], "F-01：迷雾敌军严禁进入 enemyMap")
    isNil(enemyMap["1:4"], "F-01/F-05：黑雾敌军严禁进入 enemyMap")
    eq(enemyMap["1:1"].hp, 80, "敌军血量")
    truthy(enemyMap["63:1"].is_barbarian, "蛮族标记")

    eq(#summary.visible_enemy_cities, 2, "仅导出 2 座已探索非己方城市（黑雾 Utica 隐藏）")
    local carthage = summary.visible_enemy_cities[1]
    local geneva = summary.visible_enemy_cities[2]
    exactKeys(carthage, {
        "__is_object", "city_id", "owner_id", "owner_name", "name",
        "is_minor_civ", "is_at_war", "x", "y", "hp", "pop", "in_fog",
    }, "EnemyCityDTO 键集合")
    eq(carthage.city_id, "1:0", "复合 city_id")
    eq(carthage.owner_id, 1, "owner_id")
    eq(carthage.owner_name, "Hannibal", "owner_name")
    eq(carthage.name, "Carthage", "城市名")
    falsy(carthage.is_minor_civ, "主流文明非城邦")
    truthy(carthage.is_at_war, "交战中")
    eq(carthage.hp, 180, "可见敌城 hp")
    eq(carthage.pop, 8, "可见敌城 pop")
    falsy(carthage.in_fog, "实时可见敌城 in_fog = false")

    -- F-04：已探索迷雾城邦保留 hp/pop 并标 in_fog = true
    eq(geneva.city_id, "2:0", "城邦复合 city_id")
    truthy(geneva.is_minor_civ, "城邦标记为 true")
    falsy(geneva.is_at_war, "和平城邦 is_at_war = false")
    eq(geneva.hp, 200, "迷雾敌城保留 hp")
    eq(geneva.pop, 5, "迷雾敌城保留 pop")
    truthy(geneva.in_fog, "F-04：迷雾敌城必须标 in_fog = true")

    -- 非法/死亡玩家双返回值兜底
    local badSummary, badMap = CAB_Collector.GetVisibilitySummary(4)
    truthy(badSummary.__is_object, "非法玩家 summary 带 __is_object")
    same(badSummary.visible_enemies, {}, "非法玩家 visible_enemies 为空数组")
    same(badSummary.visible_enemy_cities, {}, "非法玩家 visible_enemy_cities 为空数组")
    isType(badSummary.error, "string", "非法玩家返回 error 字符串")
    same(badMap, {}, "非法玩家第二返回值 enemyMap 为空表")
end)

test("T-16", "F3：CaptureRevealedPlotsSet 半径默认/钳制/边界与队伍视野隔离", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ width = 24, height = 24, players = TWO_PLAYERS })
    w:revealAll(0)
    w:reveal(1, 12, 12) -- 队伍 1 仅探索中心 1 格

    local function countKeys(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    -- 1. 缺省半径使用 CAB_Config.DELTA_REVEAL_SCAN_RADIUS (5)，不带 __is_object
    local setDefault = CAB_Collector.CaptureRevealedPlotsSet(0, 12, 12)
    isNil(setDefault.__is_object, "CaptureRevealedPlotsSet 返回纯集合表，不带 __is_object")
    eq(countKeys(setDefault), countPlotsInRadius(12, 12, CAB_Config.DELTA_REVEAL_SCAN_RADIUS), "默认半径 5 格数")
    truthy(setDefault["12:12"], "中心格键格式为 x:y")

    -- 2. 自定义半径 0 与 2
    same(CAB_Collector.CaptureRevealedPlotsSet(0, 12, 12, 0), { ["12:12"] = true }, "半径 0 仅含中心格")
    local set2 = CAB_Collector.CaptureRevealedPlotsSet(0, 12, 12, 2)
    eq(countKeys(set2), 19, "半径 2 格数 = 19")

    -- 3. 超大半径钳制至 CAB_Config.MAX_SCAN_RADIUS (8)
    local setClamped = CAB_Collector.CaptureRevealedPlotsSet(0, 12, 12, 999)
    eq(countKeys(setClamped), countPlotsInRadius(12, 12, CAB_Config.MAX_SCAN_RADIUS), "超大半径应钳制至 MAX_SCAN_RADIUS = 8")

    -- 4. 按队伍严格隔离视野
    same(CAB_Collector.CaptureRevealedPlotsSet(1, 12, 12, 3), { ["12:12"] = true }, "队伍 1 仅看到自己已探索格")

    -- 5. 非法入参（负半径、非数字半径、越界坐标、非法玩家）安全返回 {}
    same(CAB_Collector.CaptureRevealedPlotsSet(0, 12, 12, -1), {}, "负半径返回空表")
    same(CAB_Collector.CaptureRevealedPlotsSet(0, 12, 12, "bad"), {}, "非数字半径返回空表")
    same(CAB_Collector.CaptureRevealedPlotsSet(0, 99, 99, 2), {}, "越界坐标返回空表")
    same(CAB_Collector.CaptureRevealedPlotsSet(0, 1.5, 5, 2), {}, "非整数坐标返回空表")
    same(CAB_Collector.CaptureRevealedPlotsSet(99, 12, 12, 2), {}, "非法玩家返回空表")
end)

test("T-17", "F4：GetEndTurnStatus 全量 24 种阻塞枚举、关联单位/城市定位、通知匹配与可空键省略", function()
    ensureCollectorLoaded()
    local ALL_24_BLOCKING_NAMES = {
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

    -- 1. 无阻塞可立即结束回合（验证可空键完全省略）
    local w1 = S.newWorld({
        canEndTurn = true,
        players = { { id = 0, team = 0, turnActive = true, blockingType = EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE } },
    })
    notNil(w1, "w1")
    local okStatus = CAB_Collector.GetEndTurnStatus(0)
    exactKeys(okStatus, {
        "__is_object", "is_turn_active", "can_end_turn_now", "blocking_type_id", "blocking_type_name",
    }, "无阻塞时可空字段（blocking_unit_id / blocking_city_id / notification_summary）应省略")
    truthy(okStatus.is_turn_active, "活动回合")
    truthy(okStatus.can_end_turn_now, "无阻塞且 UI.CanEndTurn 为真时可立即结束回合")
    eq(okStatus.blocking_type_id, -1, "NO_ENDTURN_BLOCKING_TYPE = -1")
    eq(okStatus.blocking_type_name, "NO_BLOCKING", "无阻塞映射为 NO_BLOCKING")

    -- 2. UI.CanEndTurn() == false 或非活动回合时 can_end_turn_now 必须为 false
    local w2 = S.newWorld({
        canEndTurn = false,
        players = {
            { id = 0, team = 0, turnActive = true, blockingType = -1 },
            { id = 1, team = 1, turnActive = false, blockingType = -1 },
        },
    })
    notNil(w2, "w2")
    falsy(CAB_Collector.GetEndTurnStatus(0).can_end_turn_now, "UI.CanEndTurn 为 false 时不可结束回合")
    falsy(CAB_Collector.GetEndTurnStatus(1).is_turn_active, "非活动回合标记")
    falsy(CAB_Collector.GetEndTurnStatus(1).can_end_turn_now, "非活动回合不可结束回合")

    -- 3. 逐一验证全部 24 种 EndTurnBlockingTypes 枚举映射
    local wAll = S.newWorld({ players = { { id = 0, team = 0, turnActive = true } } })
    for _, enumName in ipairs(ALL_24_BLOCKING_NAMES) do
        local enumId = EndTurnBlockingTypes[enumName]
        notNil(enumId, "枚举存在：" .. enumName)
        wAll:setPlayer(0, { blockingType = enumId })
        local st = CAB_Collector.GetEndTurnStatus(0)
        eq(st.blocking_type_id, enumId, enumName .. " 枚举 ID")
        eq(st.blocking_type_name, enumName, enumName .. " 枚举名精确映射")
        falsy(st.can_end_turn_now, enumName .. " 阻塞时 can_end_turn_now 必须为 false")
    end

    -- 4. 关联实体定位：待命单位 / 待晋升单位 / 缺生产城市（跳过傀儡、抵抗、焚城与非空队列）+ 通知摘要匹配
    local wDetail = S.newWorld({
        players = {
            {
                id = 0, team = 0, turnActive = true,
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS,
                blockingNotificationIndex = 12,
                notifications = {
                    { index = 5, summary = "Other notice", str = "x" },
                    { index = 12, summary = "Unit needs orders", str = "Move your archer" },
                },
            },
        },
    })
    wDetail:addUnit({ owner = 0, id = 10, unitType = "UNIT_WARRIOR", x = 3, y = 3, readyToMove = false, promotionReady = false })
    wDetail:addUnit({ owner = 0, id = 20, unitType = "UNIT_ARCHER", x = 4, y = 3, readyToMove = true, promotionReady = false })
    wDetail:addUnit({ owner = 0, id = 30, unitType = "UNIT_WARRIOR", x = 5, y = 3, readyToMove = false, promotionReady = true })

    local stUnits = CAB_Collector.GetEndTurnStatus(0)
    eq(stUnits.blocking_unit_id, 20, "ENDTURN_BLOCKING_UNITS 应取首个 ready 单位 ID")
    isNil(stUnits.blocking_city_id, "单位阻塞不应填 blocking_city_id")
    eq(stUnits.notification_summary, "Unit needs orders", "匹配通知索引 12 的摘要")

    wDetail:setPlayer(0, { blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNIT_PROMOTION, blockingNotificationIndex = -1 })
    local stPromo = CAB_Collector.GetEndTurnStatus(0)
    eq(stPromo.blocking_unit_id, 30, "ENDTURN_BLOCKING_UNIT_PROMOTION 应定位待晋升单位 ID")
    isNil(stPromo.notification_summary, "无关联通知索引时应省略 notification_summary")

    -- 生产阻塞：跳过傀儡/抵抗/焚城及非空队列城市，定位真正可排产的闲置城市
    wDetail:addCity({ owner = 0, id = 1, name = "PuppetCity", x = 2, y = 8, isPuppet = true, orderQueueLength = 0 })
    wDetail:addCity({ owner = 0, id = 2, name = "ResistCity", x = 4, y = 8, isResistance = true, orderQueueLength = 0 })
    wDetail:addCity({ owner = 0, id = 3, name = "RazeCity", x = 6, y = 8, isRazing = true, orderQueueLength = 0 })
    wDetail:addCity({ owner = 0, id = 4, name = "BusyCity", x = 8, y = 8, orderQueueLength = 1 })
    wDetail:addCity({ owner = 0, id = 5, name = "IdleCity", x = 10, y = 8, orderQueueLength = 0 })
    wDetail:setPlayer(0, {
        blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION,
        blockingNotificationIndex = 99,
        notifications = { { index = 99, summary = "Choose production in IdleCity", str = "detail" } },
    })
    local stProd = CAB_Collector.GetEndTurnStatus(0)
    eq(stProd.blocking_city_id, 5, "ENDTURN_BLOCKING_PRODUCTION 应跳过受限城与非空队列城，定位 IdleCity(5)")
    isNil(stProd.blocking_unit_id, "生产阻塞不应填 blocking_unit_id")
    eq(stProd.notification_summary, "Choose production in IdleCity", "匹配生产阻塞通知摘要")

    -- 非法玩家返回错误 DTO
    local badSt = CAB_Collector.GetEndTurnStatus(99)
    truthy(badSt.__is_object, "非法玩家带 __is_object")
    isType(badSt.error, "string", "非法玩家返回 error 字符串")
end)

test("T-18", "IGE 兼容（D-05）：零跨调用状态缓存，实时反映经济、敌军与回合阻塞动态修改", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome", gold = 100, blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS },
            { id = 1, team = 1, name = "Hannibal", civ = "Carthage" },
        },
        visibleAll = 0,
    })
    local u0 = w:addUnit({ owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 4, y = 4 })
    local e1 = w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 8, y = 4, damage = 0 })
    notNil(u0, "u0")

    -- 首次采样
    eq(CAB_Collector.GetEmpireEconomy(0).gold, 100, "修改前金币 100")
    local vis1 = CAB_Collector.GetVisibilitySummary(0)
    eq(#vis1.visible_enemies, 1, "修改前 1 个敌军")
    eq(vis1.visible_enemies[1].hp, 100, "修改前敌军满血")
    falsy(CAB_Collector.GetEndTurnStatus(0).can_end_turn_now, "修改前被单位阻塞")

    -- 模拟 IGE 回合中即时修改金币、刷血/删兵、解除阻塞
    w:setPlayer(0, { gold = 9999, blockingType = EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE })
    w:setUnit(e1, { damage = 60, x = 9, y = 4 })
    w:addUnit({ owner = 1, id = 2, unitType = "UNIT_ARCHER", x = 10, y = 4 })

    -- 立即再次采样必须 100% 反映最新状态（零陈旧缓存）
    eq(CAB_Collector.GetEmpireEconomy(0).gold, 9999, "IGE 改金币后立即生效")
    local vis2, map2 = CAB_Collector.GetVisibilitySummary(0)
    eq(#vis2.visible_enemies, 2, "IGE 刷出新敌军后立即反映")
    eq(map2["1:1"].hp, 40, "IGE 改敌军伤害后立即反映")
    eq(map2["1:1"].x, 9, "IGE 移动敌军坐标后立即反映")
    truthy(CAB_Collector.GetEndTurnStatus(0).can_end_turn_now, "IGE 解除阻塞后立即反映")
end)

-- -----------------------------------------------------------------------------
-- 第 5 节：WP3 全局态势汇总与单位局部战术上下文用例（T-19 ~ T-27）
-- -----------------------------------------------------------------------------

-- 按坐标索引 surrounding_tiles，便于精确断言单格字段与脱敏键集
local function indexTiles(tiles)
    local byKey = {}
    for _, tile in ipairs(tiles or {}) do
        byKey[tostring(tile.x) .. ":" .. tostring(tile.y)] = tile
    end
    return byKey
end

-- 按动作类型与目标坐标筛选候选动作列表
local function findCandidates(actions, actionType, tx, ty)
    local out = {}
    for _, act in ipairs(actions or {}) do
        if (actionType == nil or act.action_type == actionType)
            and (tx == nil or act.target_x == tx)
            and (ty == nil or act.target_y == ty) then
            table.insert(out, act)
        end
    end
    return out
end

test("T-19", "F5：BuildTurnOverview 全量契约、兼容《03》§2.1、过滤死单位与隐形敌军及非法玩家兜底", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        turn = 45,
        players = {
            {
                id = 0, team = 0, name = "Augustus", civ = "Rome", goldenAge = true,
                gold = 350, goldRate = 24, science = 42, culturePerTurn = 15,
                faith = 90, faithPerTurn = 7, happiness = 8,
                resourcesAvailable = { [0] = 3, [2] = 1 },
                blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_UNITS,
            },
            { id = 1, team = 1, name = "Hannibal", civ = "Carthage" },
            { id = 2, team = 2, name = "DeadCiv", alive = false },
        },
        wars = { { 0, 1 } },
    })
    w:setNilPlayerSlot(3, true)
    w:addText("TXT_KEY_UNIT_WARRIOR", "Warrior")
    w:addText("TXT_KEY_UNIT_ARCHER", "Archer")
    w:addText("TXT_KEY_BUILDING_WALLS", "Walls")

    w:show(0, 4, 4)
    w:show(0, 8, 4)
    w:show(0, 9, 4)
    w:reveal(0, 12, 4) -- 迷雾敌城
    -- (14, 4) 保持黑雾，敌城不应导出

    -- 己方单位：1 存活可行动、1 已驻扎不可行动、1 死亡、1 延迟死亡
    w:addUnit({ owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 4, y = 4, moves = 120, readyToMove = true })
    w:addUnit({ owner = 0, id = 2, unitType = "UNIT_ARCHER", x = 5, y = 4, moves = 120, fortifyTurns = 1, readyToMove = false })
    w:addUnit({ owner = 0, id = 3, unitType = "UNIT_WARRIOR", x = 6, y = 4, dead = true })
    w:addUnit({ owner = 0, id = 4, unitType = "UNIT_WARRIOR", x = 7, y = 4, delayedDeath = true })

    -- 己方城市
    w:addCity({
        owner = 0, id = 10, name = "Rome", x = 4, y = 4, pop = 7, damage = 20, maxHp = 220,
        productionNameKey = "TXT_KEY_BUILDING_WALLS", productionTurnsLeft = 3,
        yields = {
            [YieldTypes.YIELD_FOOD] = 12,
            [YieldTypes.YIELD_PRODUCTION] = 10,
            [YieldTypes.YIELD_GOLD] = 8,
            [YieldTypes.YIELD_SCIENCE] = 9,
        },
        foodNet = 3, culturePerTurn = 5, faithPerTurn = 2,
        canRangeStrikeNow = true,
    })

    -- 敌方单位：1 可见、1 隐形（F-02 屏蔽）、1 迷雾（F-01 屏蔽）
    w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 8, y = 4, damage = 30 })
    w:addUnit({ owner = 1, id = 2, unitType = "UNIT_TRIREME", x = 9, y = 4, invisibleTo = { [0] = true } })
    w:addUnit({ owner = 1, id = 3, unitType = "UNIT_ARCHER", x = 12, y = 4 })

    -- 敌方城市：1 迷雾已探索（in_fog = true）、1 黑雾（隐藏）
    w:addCity({ owner = 1, id = 20, name = "Carthage", x = 12, y = 4, pop = 6, damage = 15, maxHp = 200 })
    w:addCity({ owner = 1, id = 21, name = "HiddenCity", x = 14, y = 4, pop = 3 })

    local ov = CAB_Collector.BuildTurnOverview(0)
    exactKeys(ov, {
        "__is_object", "turn_number", "active_player_id", "player_civ", "yields",
        "our_units", "visible_enemies", "our_cities", "visible_enemy_cities", "end_turn_status",
    }, "TurnOverviewDTO 键集合")
    truthy(ov.__is_object, "__is_object")
    eq(ov.turn_number, 45, "turn_number")
    eq(ov.active_player_id, 0, "active_player_id")
    eq(ov.player_civ, "Rome", "player_civ")

    -- yields 100% 聚合 GetEmpireEconomy（向下兼容《03》§2.1 + 扩展字段）
    same(ov.yields, CAB_Collector.GetEmpireEconomy(0), "yields 应与 GetEmpireEconomy 完全一致")
    eq(ov.yields.gold, 350, "gold")
    eq(ov.yields.strategic_resources.RESOURCE_HORSE, 3, "strategic_resources")
    eq(ov.yields.luxury_resources.RESOURCE_FUR, 1, "luxury_resources")

    -- our_units 仅含 2 个存活单位
    eq(#ov.our_units, 2, "应过滤死亡与延迟死亡单位")
    eq(ov.our_units[1].unit_id, 1, "第 1 个存活单位 ID")
    truthy(ov.our_units[1].can_act, "可行动单位 can_act = true")
    eq(ov.our_units[2].unit_id, 2, "第 2 个存活单位 ID")
    falsy(ov.our_units[2].can_act, "已驻扎单位 can_act = false")

    -- our_cities 复用 SerializeCitySummary
    eq(#ov.our_cities, 1, "己方城市数")
    eq(ov.our_cities[1].name, "Rome", "城市名")
    eq(ov.our_cities[1].current_production, "Walls", "当前生产项")
    truthy(ov.our_cities[1].can_range_strike, "城市可远程炮击标记")

    -- 视野敌军与敌城复用 GetVisibilitySummary
    eq(#ov.visible_enemies, 1, "仅 1 个实时可见非隐形敌军")
    eq(ov.visible_enemies[1].enemy_id, "1:1", "可见敌军复合 ID")
    eq(#ov.visible_enemy_cities, 1, "仅 1 座已探索敌城（黑雾隐藏）")
    eq(ov.visible_enemy_cities[1].name, "Carthage", "已探索敌城名")
    truthy(ov.visible_enemy_cities[1].in_fog, "迷雾敌城标 in_fog = true")

    -- 回合阻塞状态复用 GetEndTurnStatus
    eq(ov.end_turn_status.blocking_type_name, "ENDTURN_BLOCKING_UNITS", "阻塞类型")
    eq(ov.end_turn_status.blocking_unit_id, 1, "阻塞单位定位为可行动单位 1")

    -- 非法 / 死亡 / nil 玩家均返回结构化错误表
    for _, badId in ipairs({ 2, 3, -1, 999, "0", nil }) do
        local errDto = CAB_Collector.BuildTurnOverview(badId)
        truthy(errDto.__is_object, "非法玩家带 __is_object")
        isType(errDto.error, "string", "非法玩家返回 error 字符串（id=" .. tostring(badId) .. "）")
    end
end)

test("T-20", "F6：surrounding_tiles 三层迷雾脱敏、军民叠栈优先主战、隐形屏蔽与相邻黑雾探路（F-01/F-02/F-04/F-05）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } } })
    local u0 = w:addUnit({
        owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 10, y = 6,
        canMoveThrough = true,
    })

    -- (10,6) 己方单位所在格：可见 + 己方民用叠栈 + 改良设施
    w:setPlot(10, 6, { terrain = "TERRAIN_PLAINS", feature = "FEATURE_FOREST", hills = true, river = true, improvement = "IMPROVEMENT_FARM" })
    w:show(0, 10, 6)
    w:addUnit({ owner = 0, id = 2, unitType = "UNIT_WORKER", x = 10, y = 6 })

    -- (11,6) 实时可见邻格：敌方民用 + 主战叠栈 + 隐形潜艇
    w:setPlot(11, 6, { terrain = "TERRAIN_GRASS", improvement = "IMPROVEMENT_MINE" })
    w:show(0, 11, 6)
    w:addUnit({ owner = 1, id = 10, unitType = "UNIT_WORKER", x = 11, y = 6 })
    w:addUnit({ owner = 1, id = 11, unitType = "UNIT_ARCHER", x = 11, y = 6, damage = 20 })

    -- (9,6) 实时可见邻格：仅有对己方隐形的敌军（F-02 必须完全屏蔽）
    w:show(0, 9, 6)
    w:addUnit({ owner = 1, id = 12, unitType = "UNIT_TRIREME", x = 9, y = 6, invisibleTo = { [0] = true } })

    -- (10,5) 已探索迷雾格（F-04）：含改良、己方单位、敌军单位与交战敌城 -> 必须省略 improvement/单位，保留静态地形与 city
    w:setPlot(10, 5, { terrain = "TERRAIN_DESERT", hills = true, river = true, improvement = "IMPROVEMENT_PASTURE" })
    w:reveal(0, 10, 5)
    w:addUnit({ owner = 0, id = 3, unitType = "UNIT_WORKER", x = 10, y = 5 })
    w:addUnit({ owner = 1, id = 13, unitType = "UNIT_WARRIOR", x = 10, y = 5 })
    w:addCity({ owner = 1, id = 50, name = "Carthage", x = 10, y = 5, pop = 5, damage = 30, maxHp = 200 })

    -- (9,5) 相邻未探索黑雾格（F-05）：布置山地+敌军，绝不能进入 surrounding_tiles，但应生成无预览探路 MOVE_STEP
    w:setPlot(9, 5, { terrain = "TERRAIN_MOUNTAIN", hills = true, improvement = "IMPROVEMENT_MINE" })
    w:addUnit({ owner = 1, id = 14, unitType = "UNIT_WARRIOR", x = 9, y = 5 })
    -- 其余邻格 (10,7) / (9,7) 也为黑雾

    local ctx = CAB_Collector.BuildUnitContextAndCandidates(0, u0:GetID(), 2)
    exactKeys(ctx, { "__is_object", "unit", "surrounding_tiles", "candidate_actions" }, "UnitTacticalContextDTO 键集合")
    eq(ctx.unit.unit_id, 1, "unit 摘要匹配")

    local byKey = indexTiles(ctx.surrounding_tiles)
    eq(#ctx.surrounding_tiles, 4, "仅导出 4 个已探索格（黑雾格绝不入表）")
    isNil(byKey["9:5"], "F-05：黑雾格 (9,5) 严禁出现在 surrounding_tiles")

    -- 校验实时可见中心格 (10,6)
    local tCenter = byKey["10:6"]
    eq(tCenter.visibility, "VISIBLE", "中心格可见")
    eq(tCenter.terrain, "TERRAIN_PLAINS", "地形")
    eq(tCenter.feature, "FEATURE_FOREST", "地貌")
    truthy(tCenter.is_hills, "丘陵")
    truthy(tCenter.has_river, "河流")
    eq(tCenter.improvement, "IMPROVEMENT_FARM", "可见格导出改良")
    eq(tCenter.friendly_unit_id, 1, "军民叠栈优先导出战斗单位 ID=1")
    isNil(tCenter.enemy_unit, "无敌军")
    isNil(tCenter.city, "无城市")

    -- 校验可见敌军叠栈格 (11,6)
    local tEnemy = byKey["11:6"]
    eq(tEnemy.enemy_unit.enemy_id, "1:11", "敌方叠栈优先导出主战单位 1:11")
    eq(tEnemy.improvement, "IMPROVEMENT_MINE", "可见格导出矿场")

    -- F-02：可见格上仅隐形敌军必须省略 enemy_unit
    local tInv = byKey["9:6"]
    eq(tInv.visibility, "VISIBLE", "(9,6) 实时可见")
    isNil(tInv.enemy_unit, "F-02：隐形敌军严禁导出至 surrounding_tiles")

    -- F-04：迷雾格严格脱敏键集合断言
    local tFog = byKey["10:5"]
    exactKeys(tFog, {
        "__is_object", "x", "y", "distance", "visibility",
        "terrain", "is_hills", "has_river", "city",
    }, "F-04：迷雾格严禁包含 improvement / friendly_unit_id / enemy_unit")
    eq(tFog.visibility, "REVEALED_FOG", "迷雾状态标记")
    eq(tFog.terrain, "TERRAIN_DESERT", "保留静态地形")
    truthy(tFog.is_hills, "保留丘陵")
    truthy(tFog.has_river, "保留河流")
    notNil(tFog.city, "保留已探索城市基础信息")
    eq(tFog.city.name, "Carthage", "迷雾城市名")
    truthy(tFog.city.is_hostile, "交战敌城标 is_hostile = true")

    -- F-05：相邻黑雾格 (9,5) 仅生成探路 MOVE_STEP 且无 combat_preview
    local exploreActs = findCandidates(ctx.candidate_actions, "MOVE_STEP", 9, 5)
    eq(#exploreActs, 1, "F-05：相邻黑雾格应生成 1 条探路 MOVE_STEP")
    isNil(exploreActs[1].combat_preview, "F-05：黑雾探路不附带 combat_preview")
    eq(exploreActs[1].note, "Explore adjacent unrevealed hex", "探路说明")
end)

test("T-21", "F6：MOVE_STEP 经 CanMoveThrough 避坑（A-05）、1UPT 战斗/民用分离与中立阻挡", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome" },
            { id = 1, team = 1, civ = "Carthage" }, -- 和平中立文明（未加 wars）
        },
        visibleAll = 0,
    })

    -- (10,6) 周围 6 邻格：11:6, 9:6, 10:5, 9:5, 10:7, 9:7
    local warrior = w:addUnit({
        owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 10, y = 6,
        canMoveThrough = {
            ["11:6"] = true, -- 空地 -> 允许
            ["9:6"] = true,  -- 仅有己方工人 -> 战斗单位可叠栈，允许
            ["10:5"] = true, -- 有己方存活弓手 -> 战斗 1UPT 阻挡，禁止
            ["9:5"] = true,  -- 仅有己方死亡/延迟死勇士 -> 不阻挡，允许
            ["10:7"] = false,-- 不可通行地形 -> CanMoveThrough=false，禁止
            ["9:7"] = true,  -- 有中立文明单位 -> 禁止直接步入
        },
    })
    w:addUnit({ owner = 0, id = 2, unitType = "UNIT_WORKER", x = 9, y = 6 })
    w:addUnit({ owner = 0, id = 3, unitType = "UNIT_ARCHER", x = 10, y = 5 })
    w:addUnit({ owner = 0, id = 4, unitType = "UNIT_WARRIOR", x = 9, y = 5, dead = true })
    w:addUnit({ owner = 0, id = 5, unitType = "UNIT_WARRIOR", x = 9, y = 5, delayedDeath = true })
    w:addUnit({ owner = 1, id = 10, unitType = "UNIT_WARRIOR", x = 9, y = 7 })

    local ctx = CAB_Collector.BuildUnitContextAndCandidates(0, warrior:GetID(), 1)
    local moveCoords = {}
    for _, act in ipairs(findCandidates(ctx.candidate_actions, "MOVE_STEP")) do
        table.insert(moveCoords, tostring(act.target_x) .. ":" .. tostring(act.target_y))
    end
    table.sort(moveCoords)
    same(moveCoords, { "11:6", "9:5", "9:6" }, "战斗单位 MOVE_STEP 应精确遵循 CanMoveThrough + 1UPT + 中立阻挡")
    eq(#findCandidates(ctx.candidate_actions, "MELEE_ATTACK"), 0, "和平中立单位不生成近战攻击")
    truthy(w:logCount("CanMoveThrough") >= 4, "应实际经由 CanMoveThrough 判定移动合法性")

    -- 验证民用单位 1UPT 方向相反：可与战斗单位叠栈，不可与另一民用单位叠栈，且不可进入中立城市
    local worker = w:addUnit({
        owner = 0, id = 6, unitType = "UNIT_WORKER", x = 4, y = 6,
        canMoveThrough = true,
    })
    w:addUnit({ owner = 0, id = 7, unitType = "UNIT_WARRIOR", x = 5, y = 6 }) -- 可叠栈
    w:addUnit({ owner = 0, id = 8, unitType = "UNIT_SETTLER", x = 3, y = 6 }) -- 同类民用阻挡
    w:addCity({ owner = 1, id = 99, name = "NeutralCity", x = 4, y = 5 })     -- 中立城市阻挡

    local wCtx = CAB_Collector.BuildUnitContextAndCandidates(0, worker:GetID(), 1)
    eq(#findCandidates(wCtx.candidate_actions, "MOVE_STEP", 5, 6), 1, "民用单位可步入有己方战斗单位的格")
    eq(#findCandidates(wCtx.candidate_actions, "MOVE_STEP", 3, 6), 0, "民用单位不可与同格己方民用叠栈")
    eq(#findCandidates(wCtx.candidate_actions, "MOVE_STEP", 4, 5), 0, "民用单位不可步入中立城市")
end)

test("T-22", "F6：MELEE_ATTACK 陆海兵种域规则、远程/民用排除、IsCanAttack 与敌城血量预览", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome" },
            { id = 1, team = 1, civ = "Carthage" },
            { id = 63, team = 63, name = "Barbarians", barbarian = true }, -- 故意不加 wars，测蛮族默认敌对
        },
        wars = { { 0, 1 } },
        visibleAll = 0,
    })

    -- 1. 陆军近战勇士在 (10,6)
    local warrior = w:addUnit({ owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 10, y = 6 })
    w:setPlot(11, 6, { terrain = "TERRAIN_PLAINS", hills = true })
    w:addUnit({ owner = 1, id = 10, unitType = "UNIT_ARCHER", x = 11, y = 6, damage = 35 }) -- 陆地敌军 -> 可攻
    w:setPlot(9, 6, { terrain = "TERRAIN_COAST" })
    w:addUnit({ owner = 1, id = 11, unitType = "UNIT_TRIREME", x = 9, y = 6 })             -- 水上敌舰 -> 陆军不可近战
    w:setPlot(10, 5, { terrain = "TERRAIN_GRASS" })
    w:addCity({ owner = 1, id = 20, name = "Carthage", x = 10, y = 5, damage = 60, maxHp = 240 }) -- 敌城 -> 可攻，真实 hp=180
    w:setPlot(9, 5, { terrain = "TERRAIN_MOUNTAIN", impassable = true })
    w:addUnit({ owner = 1, id = 12, unitType = "UNIT_WARRIOR", x = 9, y = 5 })             -- 不可通行格 -> 不可攻
    w:addUnit({ owner = 63, id = 13, unitType = "UNIT_WARRIOR", x = 10, y = 7, damage = 15 }) -- 蛮族 -> 可攻

    local ctxW = CAB_Collector.BuildUnitContextAndCandidates(0, warrior:GetID(), 1)
    local meleeW = findCandidates(ctxW.candidate_actions, "MELEE_ATTACK")
    eq(#meleeW, 3, "陆军勇士应仅有 3 个合法近战目标（敌弓/敌城/蛮族）")

    local atkArcher = findCandidates(meleeW, "MELEE_ATTACK", 11, 6)[1]
    notNil(atkArcher, "可攻丘陵敌弓")
    eq(atkArcher.combat_preview.target_enemy_type, "UNIT_ARCHER", "敌军类型")
    eq(atkArcher.combat_preview.target_hp_before, 65, "敌军战前血量")
    eq(atkArcher.combat_preview.terrain_modifier_note, "HILLS", "丘陵地形修正说明")

    local atkCity = findCandidates(meleeW, "MELEE_ATTACK", 10, 5)[1]
    notNil(atkCity, "可攻邻接敌城")
    eq(atkCity.combat_preview.target_enemy_type, "ENEMY_CITY", "敌城类型标识")
    eq(atkCity.combat_preview.target_hp_before, 180, "敌城真实血量 240-60=180")
    eq(atkCity.combat_preview.terrain_modifier_note, "FLAT", "平地说明")

    eq(#findCandidates(meleeW, "MELEE_ATTACK", 10, 7), 1, "蛮族默认视为敌对目标")
    eq(#findCandidates(meleeW, "MELEE_ATTACK", 9, 6), 0, "陆军不可近战攻击水上敌舰")
    eq(#findCandidates(meleeW, "MELEE_ATTACK", 9, 5), 0, "不可通行格禁止近战")

    -- 2. 海军近战三列桨战船在 (4,6)：可攻水格敌舰与沿海敌城，不可攻内陆敌军
    w:setPlot(4, 6, { terrain = "TERRAIN_COAST" })
    local ship = w:addUnit({ owner = 0, id = 2, unitType = "UNIT_TRIREME", x = 4, y = 6 })
    w:setPlot(5, 6, { terrain = "TERRAIN_COAST" })
    w:addUnit({ owner = 1, id = 21, unitType = "UNIT_TRIREME", x = 5, y = 6 })
    w:setPlot(3, 6, { terrain = "TERRAIN_GRASS" })
    w:addCity({ owner = 1, id = 22, name = "PortCity", x = 3, y = 6 }) -- 沿海敌城
    w:setPlot(4, 5, { terrain = "TERRAIN_GRASS" })
    w:addUnit({ owner = 1, id = 23, unitType = "UNIT_WARRIOR", x = 4, y = 5 }) -- 内陆敌兵

    local ctxS = CAB_Collector.BuildUnitContextAndCandidates(0, ship:GetID(), 1)
    eq(#findCandidates(ctxS.candidate_actions, "MELEE_ATTACK", 5, 6), 1, "海军可近战水上敌舰")
    eq(#findCandidates(ctxS.candidate_actions, "MELEE_ATTACK", 3, 6), 1, "海军可近战沿海敌城")
    eq(#findCandidates(ctxS.candidate_actions, "MELEE_ATTACK", 4, 5), 0, "海军不可近战内陆非城敌军")

    -- 3. 远程弓手（range > 0）、民用工人（isCombat = false）及已攻击单位（canAttack = false）均不生成 MELEE_ATTACK
    local archer = w:addUnit({ owner = 0, id = 3, unitType = "UNIT_ARCHER", x = 10, y = 6 })
    local worker = w:addUnit({ owner = 0, id = 4, unitType = "UNIT_WORKER", x = 10, y = 6 })
    local spent = w:addUnit({ owner = 0, id = 5, unitType = "UNIT_WARRIOR", x = 10, y = 6, canAttack = false })
    eq(#findCandidates(CAB_Collector.BuildUnitContextAndCandidates(0, archer:GetID(), 1).candidate_actions, "MELEE_ATTACK"), 0, "远程单位不生成近战")
    eq(#findCandidates(CAB_Collector.BuildUnitContextAndCandidates(0, worker:GetID(), 1).candidate_actions, "MELEE_ATTACK"), 0, "民用单位不生成近战")
    eq(#findCandidates(CAB_Collector.BuildUnitContextAndCandidates(0, spent:GetID(), 1).candidate_actions, "MELEE_ATTACK"), 0, "IsCanAttack=false 不生成近战")
end)

test("T-23", "F6：RANGE_ATTACK 与 F-03 迷雾防侧信道（严禁对普通迷雾与黑雾调用 CanRangeStrikeAt）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ players = TWO_PLAYERS, wars = { { 0, 1 } } })

    -- 弓手位于 (10,6)，射程 2；四周 4 个距离 2 目标全在桩里配为可攻击 true，专门钓鱼检验防侧信道红线
    local archer = w:addUnit({
        owner = 0, id = 1, unitType = "UNIT_ARCHER", x = 10, y = 6,
        canRangeStrike = true,
        canRangeStrikeAt = {
            ["12:6"] = true, -- 实时可见敌军（允许）
            ["8:6"]  = true, -- 普通已探索迷雾 + 隐匿敌军（F-03 严禁探测）
            ["10:4"] = true, -- 未探索黑雾 + 隐匿敌军（F-03 严禁探测）
            ["10:8"] = true, -- 已探索迷雾中的交战敌城（F-03 明确允许）
        },
    })
    w:show(0, 10, 6)
    w:show(0, 12, 6)
    w:reveal(0, 8, 6)  -- 仅迷雾
    -- (10,4) 保持黑雾
    w:reveal(0, 10, 8) -- 迷雾敌城

    w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 12, y = 6, damage = 25 })
    w:addUnit({ owner = 1, id = 2, unitType = "UNIT_WARRIOR", x = 8, y = 6 })
    w:addUnit({ owner = 1, id = 3, unitType = "UNIT_WARRIOR", x = 10, y = 4 })
    w:addCity({ owner = 1, id = 9, name = "FogCarthage", x = 10, y = 8, damage = 50, maxHp = 200 })

    local ctx = CAB_Collector.BuildUnitContextAndCandidates(0, archer:GetID(), 2)
    local rangeActs = findCandidates(ctx.candidate_actions, "RANGE_ATTACK")
    eq(#rangeActs, 2, "仅允许对可见敌军 (12,6) 与已探索交战敌城 (10,8) 生成 RANGE_ATTACK")

    local visTarget = findCandidates(rangeActs, "RANGE_ATTACK", 12, 6)[1]
    notNil(visTarget, "应包含可见敌军目标")
    eq(visTarget.combat_preview.target_enemy_type, "UNIT_WARRIOR", "可见敌军预览类型")
    eq(visTarget.combat_preview.target_hp_before, 75, "可见敌军预览血量")

    local fogCityTarget = findCandidates(rangeActs, "RANGE_ATTACK", 10, 8)[1]
    notNil(fogCityTarget, "应包含已探索交战敌城目标")
    eq(fogCityTarget.combat_preview.target_enemy_type, "ENEMY_CITY", "迷雾敌城预览类型")
    eq(fogCityTarget.combat_preview.target_hp_before, 150, "迷雾敌城真实血量 200-50=150")

    eq(#findCandidates(rangeActs, "RANGE_ATTACK", 8, 6), 0, "F-03：普通迷雾格敌军严禁暴露")
    eq(#findCandidates(rangeActs, "RANGE_ATTACK", 10, 4), 0, "F-03：黑雾格敌军严禁暴露")

    -- 核心红线断言：调用日志中绝不能出现任何落于普通迷雾或黑雾的 CanRangeStrikeAt 调用
    local forbidden = w:queriesOnForbiddenFog("CanRangeStrikeAt")
    eq(#forbidden, 0, "F-03 违禁迷雾探测次数必须为 0，实际：\n" .. S.describeLog(forbidden))
end)

test("T-24", "F6：AIR_STRIKE 空军超半径射程覆盖（8/10 格）、网格保持 dist<=r 且不产生黑雾探路移动", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ width = 24, height = 24, players = TWO_PLAYERS, wars = { { 0, 1 } } })
    w:addInfoRow("Units", {
        Type = "UNIT_BOMBER",
        Description = "TXT_KEY_UNIT_BOMBER",
        Domain = "DOMAIN_AIR",
        Combat = 0,
        RangedCombat = 65,
        Range = 10,
        Moves = 2,
    })

    local bomber = w:addUnit({
        owner = 0, id = 1, unitType = "UNIT_BOMBER", x = 12, y = 12,
        canRangeStrike = true,
        canRangeStrikeAt = {
            ["20:12"] = true, -- 距 8 格，实时可见敌军
            ["22:12"] = true, -- 距 10 格（超过 MAX_SCAN_RADIUS=8），已探索敌城
            ["2:12"]  = true, -- 距 10 格，普通迷雾敌军（F-03 禁止探测）
        },
    })
    -- 仅暴露中心格、8 格敌军、10 格迷雾敌城与 10 格普通迷雾；邻格全部为黑雾
    w:show(0, 12, 12)
    w:show(0, 20, 12)
    w:reveal(0, 22, 12)
    w:reveal(0, 2, 12)
    w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 20, y = 12, damage = 10 })
    w:addCity({ owner = 1, id = 2, name = "FarCity", x = 22, y = 12, damage = 0, maxHp = 200 })
    w:addUnit({ owner = 1, id = 3, unitType = "UNIT_WARRIOR", x = 2, y = 12 })

    -- 缺省 radius = 3：surrounding_tiles 仅含 dist <= 3，但 AIR_STRIKE 仍须覆盖 8/10 格目标
    local ctx = CAB_Collector.BuildUnitContextAndCandidates(0, bomber:GetID())
    eq(#ctx.surrounding_tiles, 1, "surrounding_tiles 严格仅含 dist <= 3 的已探索格（仅 12,12）")
    eq(#findCandidates(ctx.candidate_actions, "MOVE_STEP"), 0, "空军不生成黑雾探路或陆海移动")
    eq(#findCandidates(ctx.candidate_actions, "MELEE_ATTACK"), 0, "空军不生成近战攻击")

    local airActs = findCandidates(ctx.candidate_actions, "AIR_STRIKE")
    eq(#airActs, 2, "空军应命中 8 格可见敌军与 10 格已探索敌城")
    eq(#findCandidates(airActs, "AIR_STRIKE", 20, 12), 1, "命中距 8 格目标")
    eq(#findCandidates(airActs, "AIR_STRIKE", 22, 12), 1, "命中距 10 格目标（超 MAX_SCAN_RADIUS）")
    eq(#findCandidates(airActs, "AIR_STRIKE", 2, 12), 0, "F-03：禁止对普通迷雾格生成空袭")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "F-03：空军违禁迷雾探测必须为 0")
end)

test("T-25", "F6：原地动作、CanFortify/CanHeal 回退与选区安全恢复（含原无选中、异常路径与 IGE 界面模式）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({ players = { { id = 0, team = 0, civ = "Rome" } }, visibleAll = 0 })

    local catapult = w:addUnit({
        owner = 0, id = 1, unitType = "UNIT_CATAPULT", x = 6, y = 6,
        canHandleActions = {
            MISSION_SET_UP_FOR_RANGED_ATTACK = true,
            MISSION_FORTIFY = true,
            MISSION_HEAL = false,
        },
        canHeal = true, -- 通过 CanHeal 回退验证
    })
    local otherUnit = w:addUnit({
        owner = 0, id = 2, unitType = "UNIT_WARRIOR", x = 8, y = 6,
        canHandleActions = {},
        canFortify = true, -- 通过 CanFortify 回退验证
        canHeal = false,
    })
    local zeroMovesUnit = w:addUnit({
        owner = 0, id = 3, unitType = "UNIT_WARRIOR", x = 9, y = 6,
        moves = 0,
    })

    -- 路径 A：原本选中 otherUnit 且处于非 SELECTION 模式（模拟 IGE/瞄准模式） -> 探测后恢复选中 otherUnit 且界面模式不变
    w:select(otherUnit)
    w:setInterfaceMode(InterfaceModeTypes.INTERFACEMODE_RANGE_ATTACK)
    local ctxA = CAB_Collector.BuildUnitContextAndCandidates(0, catapult:GetID(), 1)
    eq(UI.GetHeadSelectedUnit(), otherUnit, "路径 A：探测结束后必须恢复原选中单位 otherUnit")
    eq(UI.GetInterfaceMode(), InterfaceModeTypes.INTERFACEMODE_RANGE_ATTACK, "绝不篡改 UI 界面模式")
    eq(#findCandidates(ctxA.candidate_actions, "SETUP_FOR_RANGED", 6, 6), 1, "攻城器械应检出 SETUP_FOR_RANGED")
    eq(#findCandidates(ctxA.candidate_actions, "FORTIFY", 6, 6), 1, "应检出 FORTIFY")
    eq(#findCandidates(ctxA.candidate_actions, "HEAL", 6, 6), 1, "经 CanHeal 回退应检出 HEAL")
    eq(#findCandidates(ctxA.candidate_actions, "SKIP_TURN", 6, 6), 1, "应包含 SKIP_TURN")

    -- 路径 B：原本无选中单位 -> 探测结束后必须调用 ClearSelectionList 恢复为空选区
    w:clearSelection()
    w:clearLog()
    local ctxB = CAB_Collector.BuildUnitContextAndCandidates(0, otherUnit:GetID(), 1)
    isNil(UI.GetHeadSelectedUnit(), "路径 B：原无选中时探测结束必须清空选区")
    eq(w:logCount("ClearSelectionList"), 1, "路径 B 应显式调用 ClearSelectionList")
    eq(#findCandidates(ctxB.candidate_actions, "FORTIFY", 8, 6), 1, "经 CanFortify 回退应检出 FORTIFY")
    eq(#findCandidates(ctxB.candidate_actions, "HEAL", 8, 6), 0, "不可回血时不生成 HEAL")

    -- 路径 C：原本已选中目标单位自身 -> 不触发无谓的 SelectUnit / ClearSelectionList 抖动
    w:select(catapult)
    w:clearLog()
    CAB_Collector.BuildUnitContextAndCandidates(0, catapult:GetID(), 1)
    eq(UI.GetHeadSelectedUnit(), catapult, "路径 C：仍保持选中 catapult")
    eq(w:logCount("SelectUnit"), 0, "已选中自身时不应重复调用 SelectUnit")
    eq(w:logCount("ClearSelectionList"), 0, "已选中自身时不应调用 ClearSelectionList")

    -- 路径 D：异常路径（Game.CanHandleAction 抛错）-> pcall 兜底且选区仍无条件恢复
    local origCanHandle = Game.CanHandleAction
    Game.CanHandleAction = function() error("simulated engine error") end

    w:select(otherUnit)
    local ctxErr1 = notThrows(function()
        return CAB_Collector.BuildUnitContextAndCandidates(0, catapult:GetID(), 1)
    end, "异常路径下不应向外抛出 Lua 异常")
    notNil(ctxErr1.unit, "异常路径仍安全返回上下文对象")
    eq(UI.GetHeadSelectedUnit(), otherUnit, "路径 D1：异常后仍恢复原选中单位 otherUnit")

    w:clearSelection()
    notThrows(function()
        return CAB_Collector.BuildUnitContextAndCandidates(0, catapult:GetID(), 1)
    end, "无选中异常路径也不应抛错")
    isNil(UI.GetHeadSelectedUnit(), "路径 D2：无选中异常后仍清空选区")

    Game.CanHandleAction = origCanHandle

    -- 路径 E：0 移动力单位 -> 不产生任何候选动作，也不触碰 UI.SelectUnit
    w:select(otherUnit)
    w:clearLog()
    local ctxZero = CAB_Collector.BuildUnitContextAndCandidates(0, zeroMovesUnit:GetID(), 1)
    eq(#ctxZero.candidate_actions, 0, "0 移动力单位候选动作必须为空")
    eq(w:logCount("SelectUnit"), 0, "0 移动力单位不应调用 UI.SelectUnit")
    eq(UI.GetHeadSelectedUnit(), otherUnit, "0 移动力单位保持原选区不动")
end)

test("T-26", "F6：半径默认/上下限钳制与非法入参结构化错误防御（D-06/A-07）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        width = 24,
        height = 24,
        players = {
            { id = 0, team = 0, civ = "Rome" },
            { id = 1, team = 1, civ = "Carthage" },
            { id = 2, team = 2, alive = false },
        },
        visibleAll = 0,
    })
    w:setNilPlayerSlot(3, true)

    local u0 = w:addUnit({ owner = 0, id = 10, unitType = "UNIT_WARRIOR", x = 12, y = 12 })
    local deadU = w:addUnit({ owner = 0, id = 11, unitType = "UNIT_WARRIOR", x = 13, y = 12, dead = true })
    local delayedU = w:addUnit({ owner = 0, id = 12, unitType = "UNIT_WARRIOR", x = 14, y = 12, delayedDeath = true })
    local enemyU = w:addUnit({ owner = 1, id = 99, unitType = "UNIT_WARRIOR", x = 15, y = 12 })
    notNil(deadU, "deadU")
    notNil(delayedU, "delayedU")
    notNil(enemyU, "enemyU")

    -- 1. 默认半径 CAB_Config.DEFAULT_SCAN_RADIUS (3)
    local ctxDef = CAB_Collector.BuildUnitContextAndCandidates(0, 10)
    eq(#ctxDef.surrounding_tiles, countPlotsInRadius(12, 12, CAB_Config.DEFAULT_SCAN_RADIUS), "默认半径 3 格数")

    -- 2. 超大半径钳制至 CAB_Config.MAX_SCAN_RADIUS (8)
    local ctxMax = CAB_Collector.BuildUnitContextAndCandidates(0, 10, 999)
    eq(#ctxMax.surrounding_tiles, countPlotsInRadius(12, 12, CAB_Config.MAX_SCAN_RADIUS), "超大半径钳制至 MAX_SCAN_RADIUS=8")

    -- 3. 负半径钳制至 0（仅含中心 1 格，不崩溃）
    local ctxNeg = CAB_Collector.BuildUnitContextAndCandidates(0, 10, -5)
    eq(#ctxNeg.surrounding_tiles, 1, "负半径钳制至 0 仅导出中心格")
    eq(ctxNeg.surrounding_tiles[1].distance, 0, "中心格距离为 0")

    -- 4. 非数字半径返回结构化错误表
    local errRad = CAB_Collector.BuildUnitContextAndCandidates(0, 10, "bad")
    truthy(errRad.__is_object, "非法半径带 __is_object")
    isType(errRad.error, "string", "非法半径返回 error")

    -- 5. 非法/死亡/nil/越权玩家与单位均返回结构化错误表
    local badCalls = {
        { 2, 10 },   -- 死玩家
        { 3, 10 },   -- nil 玩家槽位
        { -1, 10 },  -- 负玩家 ID
        { 0, 11 },   -- 已死亡单位
        { 0, 12 },   -- 延迟死亡单位
        { 0, 99 },   -- 敌方单位（越权）
        { 0, 888 },  -- 不存在单位
        { 0, 1.5 },  -- 非整数 unitID
        { 0, nil },  -- nil unitID
    }
    for _, pair in ipairs(badCalls) do
        local res = CAB_Collector.BuildUnitContextAndCandidates(pair[1], pair[2], 2)
        truthy(res.__is_object, "错误返回带 __is_object")
        isType(res.error, "string", "非法入参应返回 error 字符串（player=" .. tostring(pair[1]) .. ", unit=" .. tostring(pair[2]) .. "）")
    end
end)

test("T-27", "F5/F6 IGE 兼容（D-05）：零跨调用状态缓存，实时反映态势、瞬移、血量与迷雾切换", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        turn = 10,
        players = {
            { id = 0, team = 0, civ = "Rome", gold = 200 },
            { id = 1, team = 1, name = "Hannibal", civ = "Carthage" },
        },
        wars = { { 0, 1 } },
    })
    w:show(0, 6, 6)
    w:show(0, 7, 6)
    local u0 = w:addUnit({ owner = 0, id = 1, unitType = "UNIT_WARRIOR", x = 6, y = 6, canMoveThrough = true })
    local e1 = w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 7, y = 6, damage = 0 })
    local c0 = w:addCity({ owner = 0, id = 1, name = "Rome", x = 6, y = 6, pop = 3 })

    -- 首次采样
    local ov1 = CAB_Collector.BuildTurnOverview(0)
    local ctx1 = CAB_Collector.BuildUnitContextAndCandidates(0, u0:GetID(), 1)
    eq(ov1.yields.gold, 200, "修改前金币 200")
    eq(ov1.our_cities[1].pop, 3, "修改前城市人口 3")
    eq(#findCandidates(ctx1.candidate_actions, "MELEE_ATTACK", 7, 6), 1, "修改前可近战 (7,6)")
    eq(findCandidates(ctx1.candidate_actions, "MELEE_ATTACK", 7, 6)[1].combat_preview.target_hp_before, 100, "修改前敌军满血")

    -- 模拟 IGE 即时刷金币、涨人口、重伤敌军并切雾隐藏 (7,6)
    w:setPlayer(0, { gold = 1234 })
    w:setCity(c0, { pop = 12 })
    w:setUnit(e1, { damage = 70 })
    w:show(0, 7, 6, false) -- (7,6) 退回已探索迷雾

    local ov2 = CAB_Collector.BuildTurnOverview(0)
    local ctx2 = CAB_Collector.BuildUnitContextAndCandidates(0, u0:GetID(), 1)
    eq(ov2.yields.gold, 1234, "IGE 改金币立即反映在 BuildTurnOverview")
    eq(ov2.our_cities[1].pop, 12, "IGE 改人口立即反映在 BuildTurnOverview")
    eq(#ov2.visible_enemies, 0, "IGE 切回迷雾后敌军立即消失")
    isNil(indexTiles(ctx2.surrounding_tiles)["7:6"].enemy_unit, "IGE 切回迷雾后局部网格不再导出敌军")
    eq(#findCandidates(ctx2.candidate_actions, "MELEE_ATTACK", 7, 6), 0, "切回迷雾后不再生成对该隐匿敌军的近战候选")

    -- IGE 重新点亮视野，立刻看到残血 30 的敌军
    w:show(0, 7, 6, true)
    local ctx3 = CAB_Collector.BuildUnitContextAndCandidates(0, u0:GetID(), 1)
    eq(findCandidates(ctx3.candidate_actions, "MELEE_ATTACK", 7, 6)[1].combat_preview.target_hp_before, 30, "重新点亮后立即反映残血 30")
end)

-- -----------------------------------------------------------------------------
-- 第 6 节：WP4 城市详情、城防目标与可购买项报价单用例（T-28 ~ T-35）
-- -----------------------------------------------------------------------------

test("T-28", "F7：GetCityDetail 基础契约、combat_str 换算、turns_to_growth、驻军与真实建筑", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome" },
            { id = 1, team = 1, civ = "Carthage" },
        },
        visibleAll = 0,
    })
    w:addText("TXT_KEY_BUILDING_GRANARY", "Granary")
    w:addText("TXT_KEY_BUILDING_PALACE", "Palace")
    w:addText("TXT_KEY_BUILDING_MONUMENT", "Monument")

    local garrison = w:addUnit({ owner = 0, id = 7, unitType = "UNIT_ARCHER", x = 10, y = 6 })
    local deadGar = w:addUnit({ owner = 0, id = 8, unitType = "UNIT_WARRIOR", x = 12, y = 6, dead = true })
    local delayedGar = w:addUnit({ owner = 0, id = 9, unitType = "UNIT_WARRIOR", x = 14, y = 6, delayedDeath = true })

    local rome = w:addCity({
        owner = 0, id = 10, name = "Rome", x = 10, y = 6,
        pop = 8, damage = 35, maxHp = 250, strength = 1589,
        isCapital = true, isPuppet = false, isOccupied = false, isResistance = false, isRazing = false,
        yields = {
            [YieldTypes.YIELD_FOOD] = 14,
            [YieldTypes.YIELD_PRODUCTION] = 11,
            [YieldTypes.YIELD_GOLD] = 9,
            [YieldTypes.YIELD_SCIENCE] = 10,
        },
        foodNet = 4, foodTurnsLeft = 5, culturePerTurn = 6, faithPerTurn = 3,
        orderQueueLength = 2, productionTurnsLeft = 3, productionNameKey = "TXT_KEY_BUILDING_GRANARY",
        garrison = garrison,
        realBuildings = {
            [GameInfoTypes.BUILDING_MONUMENT] = 1,
            [GameInfoTypes.BUILDING_GRANARY] = 0,
            [GameInfoTypes.BUILDING_PALACE] = 1,
        },
    })

    local detail = CAB_Collector.GetCityDetail(0, rome:GetID())
    exactKeys(detail, {
        "__is_object", "city", "yields", "production_state", "garrison_unit_id",
        "built_buildings", "ranged_attack_targets",
        "purchasable_buildings", "purchasable_units", "purchasable_plots",
    }, "CityDetailDTO 顶层键集合（有驻军时含 garrison_unit_id）")
    truthy(detail.__is_object, "顶层 __is_object")

    exactKeys(detail.city, {
        "__is_object", "city_id", "name", "x", "y", "pop", "hp", "max_hp", "combat_str",
        "is_capital", "is_puppet", "is_occupied", "is_in_resistance", "is_razing",
    }, "city 子表键集合")
    eq(detail.city.city_id, 10, "city_id")
    eq(detail.city.name, "Rome", "name")
    eq(detail.city.x, 10, "x")
    eq(detail.city.y, 6, "y")
    eq(detail.city.pop, 8, "pop")
    eq(detail.city.hp, 215, "hp = 250 - 35")
    eq(detail.city.max_hp, 250, "max_hp")
    eq(detail.city.combat_str, 15, "combat_str = floor(1589/100) = 15")
    truthy(detail.city.is_capital, "is_capital")
    falsy(detail.city.is_puppet, "is_puppet")
    falsy(detail.city.is_occupied, "is_occupied")
    falsy(detail.city.is_in_resistance, "is_in_resistance")
    falsy(detail.city.is_razing, "is_razing")

    exactKeys(detail.yields, {
        "__is_object", "food", "food_net", "turns_to_growth",
        "production", "gold", "science", "culture", "faith",
    }, "yields 子表键集合")
    eq(detail.yields.food, 14, "food")
    eq(detail.yields.food_net, 4, "food_net")
    eq(detail.yields.turns_to_growth, 5, "正向增长 turns_to_growth")
    eq(detail.yields.production, 11, "production")
    eq(detail.yields.gold, 9, "gold")
    eq(detail.yields.science, 10, "science")
    eq(detail.yields.culture, 6, "culture")
    eq(detail.yields.faith, 3, "faith")

    exactKeys(detail.production_state, {
        "__is_object", "current_item", "order_queue_length", "turns_left",
    }, "production_state 键集合")
    eq(detail.production_state.current_item, "Granary", "本地化当前生产名")
    eq(detail.production_state.order_queue_length, 2, "队列长度")
    eq(detail.production_state.turns_left, 3, "剩余回合")
    eq(detail.garrison_unit_id, 7, "存活驻军 ID")

    eq(#detail.built_buildings, 2, "仅导出数量 > 0 的真实建筑")
    exactKeys(detail.built_buildings[1], {
        "__is_object", "building_id", "building_type", "name", "count",
    }, "built_buildings 元素键集合")
    eq(detail.built_buildings[1].building_type, "BUILDING_MONUMENT", "第 1 个已建建筑")
    eq(detail.built_buildings[1].name, "Monument", "第 1 个已建建筑本地化名")
    eq(detail.built_buildings[1].count, 1, "建筑数量")
    eq(detail.built_buildings[2].building_type, "BUILDING_PALACE", "第 2 个已建建筑")

    -- 无驻军 / 死亡驻军 / 延迟死亡驻军均省略 garrison_unit_id，且空生产名映射为 "NONE"
    -- 同时验证造移民（foodGrowthBlocked）、停滞（foodDiffTimes100=0）与饥荒（foodNet<0）时 turns_to_growth 均为 -1
    local settlerCity = w:addCity({
        owner = 0, id = 11, name = "Antium", x = 12, y = 6,
        foodNet = 3, foodTurnsLeft = 4, foodGrowthBlocked = true,
        productionNameKey = "", orderQueueLength = 0, productionTurnsLeft = 0,
        garrison = deadGar,
    })
    local starvingCity = w:addCity({
        owner = 0, id = 12, name = "Cumae", x = 14, y = 6,
        foodNet = -2, foodTurnsLeft = 3,
        garrison = delayedGar,
    })
    local stagnantCity = w:addCity({
        owner = 0, id = 13, name = "Neapolis", x = 16, y = 6,
        foodNet = 0, foodDiffTimes100 = 0, foodTurnsLeft = 9,
    })

    local dSettler = CAB_Collector.GetCityDetail(0, settlerCity:GetID())
    local dStarve = CAB_Collector.GetCityDetail(0, starvingCity:GetID())
    local dStag = CAB_Collector.GetCityDetail(0, stagnantCity:GetID())

    isNil(dSettler.garrison_unit_id, "已死亡驻军必须省略 garrison_unit_id")
    isNil(dStarve.garrison_unit_id, "延迟死亡驻军必须省略 garrison_unit_id")
    isNil(dStag.garrison_unit_id, "无驻军时必须省略 garrison_unit_id")
    eq(dSettler.production_state.current_item, "NONE", "空生产键应回退为 NONE")
    eq(dSettler.yields.turns_to_growth, -1, "造移民冻结增长时 turns_to_growth 应为 -1")
    eq(dStarve.yields.turns_to_growth, -1, "饥荒时 turns_to_growth 应为 -1")
    eq(dStag.yields.turns_to_growth, -1, "停滞时 turns_to_growth 应为 -1")
end)

test("T-29", "F7：城防远程炮击目标（ranged_attack_targets）与 F-01/F-02/F-03 迷雾防侧信道", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, name = "Augustus", civ = "Rome" },
            { id = 1, team = 1, name = "Hannibal", civ = "Carthage" },
            { id = 2, team = 2, name = "Gandhi", civ = "India" }, -- 和平邻国
            { id = 63, team = 63, name = "Barbarians", barbarian = true },
        },
        wars = { { 0, 1 } },
    })

    local rome = w:addCity({
        owner = 0, id = 1, name = "Rome", x = 10, y = 6,
        canRangeStrikeNow = true,
        -- 全部周边格在桩中放开 true，用来钓鱼检测迷雾/隐形/和平单位是否被正确拦截
        canRangeStrikeAt = {
            ["11:6"] = true, -- 距 1，实时可见交战敌军（工人+勇士叠栈 -> 优先勇士）
            ["12:6"] = true, -- 距 2，实时可见蛮族
            ["9:6"]  = true, -- 距 1，实时可见但对己方隐形的敌军（F-02 严禁暴露）
            ["8:6"]  = true, -- 距 2，已探索迷雾中的敌军（F-01/F-03 严禁探测）
            ["10:4"] = true, -- 距 2，黑雾中的敌军（F-01/F-03 严禁探测）
            ["10:7"] = true, -- 距 1，实时可见但未宣战的和平邻国单位
            ["13:6"] = true, -- 距 3，超出默认 CITY_ATTACK_RANGE=2
        },
    })

    w:show(0, 10, 6)
    w:show(0, 11, 6)
    w:show(0, 12, 6)
    w:show(0, 9, 6)
    w:show(0, 10, 7)
    w:show(0, 13, 6)
    w:reveal(0, 8, 6) -- 普通迷雾
    -- (10,4) 保持黑雾

    -- (11,6) 敌军民用+主战叠栈
    w:addUnit({ owner = 1, id = 10, unitType = "UNIT_WORKER", x = 11, y = 6 })
    w:addUnit({ owner = 1, id = 11, unitType = "UNIT_WARRIOR", x = 11, y = 6, damage = 20 })
    -- (12,6) 蛮族
    w:addUnit({ owner = 63, id = 20, unitType = "UNIT_ARCHER", x = 12, y = 6, damage = 45 })
    -- (9,6) 隐形敌舰
    w:addUnit({ owner = 1, id = 12, unitType = "UNIT_TRIREME", x = 9, y = 6, invisibleTo = { [0] = true } })
    -- (8,6) 迷雾敌军与 (10,4) 黑雾敌军
    w:addUnit({ owner = 1, id = 13, unitType = "UNIT_WARRIOR", x = 8, y = 6 })
    w:addUnit({ owner = 1, id = 14, unitType = "UNIT_WARRIOR", x = 10, y = 4 })
    -- (10,7) 和平邻国单位
    w:addUnit({ owner = 2, id = 30, unitType = "UNIT_WARRIOR", x = 10, y = 7 })
    -- (13,6) 距 3 格敌军
    w:addUnit({ owner = 1, id = 15, unitType = "UNIT_WARRIOR", x = 13, y = 6 })

    local detail = CAB_Collector.GetCityDetail(0, rome:GetID(), false)
    eq(#detail.ranged_attack_targets, 2, "默认射程 2 仅应命中可见交战敌军 (11,6) 与可见蛮族 (12,6)")

    local byKey = {}
    for _, t in ipairs(detail.ranged_attack_targets) do
        exactKeys(t, {
            "__is_object", "x", "y", "distance", "enemy_id", "unit_type",
            "hp", "owner_id", "owner_name", "is_barbarian",
        }, "ranged_attack_targets 元素键集合")
        byKey[t.x .. ":" .. t.y] = t
    end

    notNil(byKey["11:6"], "命中可见交战敌军 (11,6)")
    eq(byKey["11:6"].enemy_id, "1:11", "军民叠栈应优先主战勇士 1:11")
    eq(byKey["11:6"].unit_type, "UNIT_WARRIOR", "目标兵种")
    eq(byKey["11:6"].hp, 80, "目标血量")
    eq(byKey["11:6"].distance, 1, "目标距离 1")
    falsy(byKey["11:6"].is_barbarian, "非蛮族")

    notNil(byKey["12:6"], "命中可见蛮族 (12,6)")
    eq(byKey["12:6"].enemy_id, "63:20", "蛮族复合 ID")
    eq(byKey["12:6"].hp, 55, "蛮族血量 55")
    eq(byKey["12:6"].distance, 2, "目标距离 2")
    truthy(byKey["12:6"].is_barbarian, "蛮族标记 true")

    -- F-01/F-03 红线断言：绝不对迷雾/黑雾格调用 CanRangeStrikeAt
    eq(#w:queriesOnInvisible("CanRangeStrikeAt"), 0, "不可见格 CanRangeStrikeAt 调用次数必须为 0")
    eq(#w:queriesOnForbiddenFog("CanRangeStrikeAt"), 0, "F-03 违禁迷雾探测必须为 0")

    -- CanRangeStrikeNow() == false 时直接返回空表且零调用 CanRangeStrikeAt
    w:setCity(rome, { canRangeStrikeNow = false })
    w:clearLog()
    local dOff = CAB_Collector.GetCityDetail(0, rome:GetID(), false)
    eq(#dOff.ranged_attack_targets, 0, "CanRangeStrikeNow=false 时无炮击目标")
    eq(w:logCount("CanRangeStrikeAt"), 0, "CanRangeStrikeNow=false 时不应调用 CanRangeStrikeAt")
end)

test("T-30", "F7：可购买建筑与单位双层 IsCanPurchase 金币/信仰双通道报价单（A-08）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = { { id = 0, team = 0, civ = "Rome", gold = 300, faith = 250 } },
        visibleAll = 0,
    })
    w:addText("TXT_KEY_BUILDING_GRANARY", "Granary")
    w:addText("TXT_KEY_BUILDING_WALLS", "Walls")
    w:addText("TXT_KEY_BUILDING_MONUMENT", "Monument")
    w:addText("TXT_KEY_UNIT_WARRIOR", "Warrior")
    w:addText("TXT_KEY_UNIT_ARCHER", "Archer")
    w:addText("TXT_KEY_UNIT_CATAPULT", "Catapult")

    local idMonument = GameInfoTypes.BUILDING_MONUMENT
    local idGranary  = GameInfoTypes.BUILDING_GRANARY
    local idWalls    = GameInfoTypes.BUILDING_WALLS
    local idWarrior  = GameInfoTypes.UNIT_WARRIOR
    local idArcher   = GameInfoTypes.UNIT_ARCHER
    local idCatapult = GameInfoTypes.UNIT_CATAPULT

    local rome = w:addCity({
        owner = 0, id = 1, name = "Rome", x = 10, y = 6,
        purchasable = {
            buildings = {
                [idMonument] = { gold = true, faith = false }, -- 仅金币，且买得起
                [idGranary]  = { gold = true, faith = true },  -- 金币+信仰双通道，金币买不起、信仰买得起
                [idWalls]    = { gold = false, faith = true }, -- 仅信仰，余额不足买不起
                -- Palace 不在候选池，不应导出
            },
            units = {
                [idWarrior]  = { gold = true, faith = false }, -- 仅金币，买得起
                [idArcher]   = { gold = true, faith = true },  -- 双通道，两者都买得起
                [idCatapult] = { gold = false, faith = true }, -- 仅信仰，买不起
            },
        },
        affordable = {
            buildings = {
                [idMonument] = { gold = true, faith = false },
                [idGranary]  = { gold = false, faith = true },
                [idWalls]    = { gold = false, faith = false },
            },
            units = {
                [idWarrior]  = { gold = true, faith = false },
                [idArcher]   = { gold = true, faith = true },
                [idCatapult] = { gold = false, faith = false },
            },
        },
        costs = {
            bldGold = { [idMonument] = 180, [idGranary] = 400, [idWalls] = 999 },
            bldFaith = { [idMonument] = 888, [idGranary] = 200, [idWalls] = 300 },
            unitGold = { [idWarrior] = 200, [idArcher] = 240, [idCatapult] = 777 },
            unitFaith = { [idWarrior] = 666, [idArcher] = 150, [idCatapult] = 400 },
        },
    })

    local detail = CAB_Collector.GetCityDetail(0, rome:GetID(), true)

    -- 1. 建筑报价单校验
    eq(#detail.purchasable_buildings, 3, "应导出 3 个满足前置条件的待购建筑")
    local bByType = {}
    for _, item in ipairs(detail.purchasable_buildings) do
        exactKeys(item, {
            "__is_object", "building_id", "building_type", "name",
            "gold_cost", "faith_cost", "can_afford_gold_now", "can_afford_faith_now",
        }, "purchasable_buildings 元素键集合")
        bByType[item.building_type] = item
    end

    eq(bByType["BUILDING_MONUMENT"].gold_cost, 180, "Monument 金币价")
    eq(bByType["BUILDING_MONUMENT"].faith_cost, 0, "不支持信仰通道的建筑 faith_cost 必须归零")
    truthy(bByType["BUILDING_MONUMENT"].can_afford_gold_now, "Monument 金币可买")
    falsy(bByType["BUILDING_MONUMENT"].can_afford_faith_now, "Monument 不可信仰购")

    eq(bByType["BUILDING_GRANARY"].gold_cost, 400, "Granary 金币价")
    eq(bByType["BUILDING_GRANARY"].faith_cost, 200, "Granary 信仰价")
    falsy(bByType["BUILDING_GRANARY"].can_afford_gold_now, "Granary 金币余额不足")
    truthy(bByType["BUILDING_GRANARY"].can_afford_faith_now, "Granary 信仰买得起")

    eq(bByType["BUILDING_WALLS"].gold_cost, 0, "仅信仰可购的建筑 gold_cost 必须归零")
    eq(bByType["BUILDING_WALLS"].faith_cost, 300, "Walls 信仰价")
    falsy(bByType["BUILDING_WALLS"].can_afford_gold_now, "Walls 不可金币购")
    falsy(bByType["BUILDING_WALLS"].can_afford_faith_now, "Walls 信仰余额不足")
    isNil(bByType["BUILDING_PALACE"], "不满足前置条件的建筑不得导出")

    -- 2. 单位报价单校验
    eq(#detail.purchasable_units, 3, "应导出 3 个满足前置条件的待购单位")
    local uByType = {}
    for _, item in ipairs(detail.purchasable_units) do
        exactKeys(item, {
            "__is_object", "unit_type_id", "unit_type", "name",
            "gold_cost", "faith_cost", "can_afford_gold_now", "can_afford_faith_now",
        }, "purchasable_units 元素键集合")
        uByType[item.unit_type] = item
    end

    eq(uByType["UNIT_WARRIOR"].gold_cost, 200, "Warrior 金币价")
    eq(uByType["UNIT_WARRIOR"].faith_cost, 0, "不支持信仰的单位 faith_cost 归零")
    truthy(uByType["UNIT_WARRIOR"].can_afford_gold_now, "Warrior 金币可买")
    falsy(uByType["UNIT_WARRIOR"].can_afford_faith_now, "Warrior 不可信仰购")

    eq(uByType["UNIT_ARCHER"].gold_cost, 240, "Archer 金币价")
    eq(uByType["UNIT_ARCHER"].faith_cost, 150, "Archer 信仰价")
    truthy(uByType["UNIT_ARCHER"].can_afford_gold_now, "Archer 金币可买")
    truthy(uByType["UNIT_ARCHER"].can_afford_faith_now, "Archer 信仰可买")

    eq(uByType["UNIT_CATAPULT"].gold_cost, 0, "仅信仰单位 gold_cost 归零")
    eq(uByType["UNIT_CATAPULT"].faith_cost, 400, "Catapult 信仰价")
    falsy(uByType["UNIT_CATAPULT"].can_afford_faith_now, "Catapult 信仰余额不足")
end)

test("T-31", "F7：可购买地块报价单、F-06 科技资源过滤与 BUY_PLOTS_DISABLED 开关", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome" },
            { id = 1, team = 1, civ = "Carthage" },
        },
    })
    -- 布置 5 个城市管辖地块：
    -- (10,6) 城心（不可买）
    -- (11,6) 已探索，可买且买得起，丘陵 + 森林 + 铁矿（仅队伍 0 已解锁铁器）
    -- (10,7) 已探索，可买但买不起，草原无地貌 + 铁矿（仅队伍 1 解锁，对队伍 0 未解锁！F-06）
    -- (9,6)  未探索黑雾（即使桩配置可买也不得泄露地形/资源）
    w:reveal(0, 10, 6)
    w:reveal(0, 11, 6)
    w:reveal(0, 10, 7)

    w:setPlot(11, 6, {
        terrain = "TERRAIN_PLAINS", feature = "FEATURE_FOREST", hills = true,
        resource = "RESOURCE_IRON", resourceKnownBy = { [0] = true },
    })
    w:setPlot(10, 7, {
        terrain = "TERRAIN_GRASS", hills = false,
        resource = "RESOURCE_IRON", resourceKnownBy = { [1] = true }, -- 队伍 0 未解锁铁器
    })
    w:setPlot(9, 6, {
        terrain = "TERRAIN_DESERT", resource = "RESOURCE_HORSE",
    })

    local rome = w:addCity({
        owner = 0, id = 1, name = "Rome", x = 10, y = 6,
        cityPlots = {
            { x = 10, y = 6 },
            { x = 11, y = 6 },
            { x = 10, y = 7 },
            { x = 9, y = 6 },
        },
        canBuyPlotAt = { ["11:6"] = true, ["10:7"] = true, ["9:6"] = true },
        canBuyPlotNow = { ["11:6"] = true, ["10:7"] = false, ["9:6"] = true },
        buyPlotCost = { ["11:6"] = 50, ["10:7"] = 85, ["9:6"] = 40 },
    })

    local detail = CAB_Collector.GetCityDetail(0, rome:GetID())
    eq(#detail.purchasable_plots, 2, "仅导出已探索且规则可买的 2 块地（跳过城心与黑雾格）")

    local p11 = detail.purchasable_plots[1]
    exactKeys(p11, {
        "__is_object", "x", "y", "gold_cost", "can_afford_now",
        "terrain", "feature", "is_hills", "resource_type",
    }, "含地貌与已解锁资源的可购地块键集合")
    eq(p11.x, 11, "x")
    eq(p11.y, 6, "y")
    eq(p11.gold_cost, 50, "gold_cost")
    truthy(p11.can_afford_now, "买得起")
    eq(p11.terrain, "TERRAIN_PLAINS", "地形")
    eq(p11.feature, "FEATURE_FOREST", "地貌")
    truthy(p11.is_hills, "丘陵")
    eq(p11.resource_type, "RESOURCE_IRON", "F-06：已解锁铁器时可见铁矿")

    local p10 = detail.purchasable_plots[2]
    exactKeys(p10, {
        "__is_object", "x", "y", "gold_cost", "can_afford_now",
        "terrain", "is_hills",
    }, "F-06：无地貌且未解锁科技资源时必须省略 feature 与 resource_type")
    eq(p10.gold_cost, 85, "gold_cost")
    falsy(p10.can_afford_now, "当前金币买不起")
    isNil(p10.feature, "无地貌省略")
    isNil(p10.resource_type, "F-06：未解锁科技时绝不泄露铁矿")
end)

test("T-32", "F7：includePurchasable=false 开关与傀儡/占领/抵抗/焚城特殊状态", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = { { id = 0, team = 0, civ = "Rome" } },
        visibleAll = 0,
    })

    local idMonument = GameInfoTypes.BUILDING_MONUMENT
    local idWarrior  = GameInfoTypes.UNIT_WARRIOR

    local normalCity = w:addCity({
        owner = 0, id = 1, name = "Rome", x = 10, y = 6,
        realBuildings = { [idMonument] = 1 },
        cityPlots = { { x = 10, y = 6 }, { x = 11, y = 6 } },
        purchasable = {
            buildings = { [idMonument] = { gold = true } },
            units = { [idWarrior] = { gold = true } },
        },
        costs = { bldGold = { [idMonument] = 150 }, unitGold = { [idWarrior] = 200 } },
        canBuyPlotAt = { ["11:6"] = true },
        buyPlotCost = { ["11:6"] = 55 },
    })

    -- 1. includePurchasable = false：三类购买数组均返回空数组，其余字段完整
    local dNoPurch = CAB_Collector.GetCityDetail(0, normalCity:GetID(), false)
    eq(#dNoPurch.purchasable_buildings, 0, "includePurchasable=false 时不导出待购建筑")
    eq(#dNoPurch.purchasable_units, 0, "includePurchasable=false 时不导出待购单位")
    eq(#dNoPurch.purchasable_plots, 0, "includePurchasable=false 时不导出可购地块")
    eq(#dNoPurch.built_buildings, 1, "includePurchasable=false 不影响已有建筑列表")
    eq(dNoPurch.city.name, "Rome", "includePurchasable=false 不影响基础信息")

    -- 2. 傀儡 / 抵抗 / 焚城状态：标记准确且禁止导出可购地块
    local puppetCity = w:addCity({
        owner = 0, id = 2, name = "PuppetTown", x = 6, y = 6,
        isPuppet = true,
        cityPlots = { { x = 6, y = 6 }, { x = 7, y = 6 } },
        canBuyPlotAt = { ["7:6"] = true }, buyPlotCost = { ["7:6"] = 50 },
    })
    local resistCity = w:addCity({
        owner = 0, id = 3, name = "ResistTown", x = 6, y = 10,
        isOccupied = true, isResistance = true,
        cityPlots = { { x = 6, y = 10 }, { x = 7, y = 10 } },
        canBuyPlotAt = { ["7:10"] = true }, buyPlotCost = { ["7:10"] = 50 },
    })
    local razingCity = w:addCity({
        owner = 0, id = 4, name = "RazeTown", x = 14, y = 10,
        isOccupied = true, isRazing = true,
        cityPlots = { { x = 14, y = 10 }, { x = 15, y = 10 } },
        canBuyPlotAt = { ["15:10"] = true }, buyPlotCost = { ["15:10"] = 50 },
    })
    -- 3. 仅占领（已过抵抗期、未焚城，需买法院的已吞并城）：仍允许购买地块
    local annexedOccupiedCity = w:addCity({
        owner = 0, id = 5, name = "OccupiedTown", x = 14, y = 6,
        isOccupied = true, isResistance = false, isRazing = false,
        cityPlots = { { x = 14, y = 6 }, { x = 15, y = 6 } },
        canBuyPlotAt = { ["15:6"] = true }, buyPlotCost = { ["15:6"] = 65 },
    })

    local dPuppet = CAB_Collector.GetCityDetail(0, puppetCity:GetID())
    local dResist = CAB_Collector.GetCityDetail(0, resistCity:GetID())
    local dRaze   = CAB_Collector.GetCityDetail(0, razingCity:GetID())
    local dOcc    = CAB_Collector.GetCityDetail(0, annexedOccupiedCity:GetID())

    truthy(dPuppet.city.is_puppet, "傀儡标记")
    eq(#dPuppet.purchasable_plots, 0, "傀儡城不得返回可购地块")
    truthy(dResist.city.is_in_resistance, "抵抗标记")
    eq(#dResist.purchasable_plots, 0, "抵抗城不得返回可购地块")
    truthy(dRaze.city.is_razing, "焚城标记")
    eq(#dRaze.purchasable_plots, 0, "焚城不得返回可购地块")
    truthy(dOcc.city.is_occupied, "占领标记")
    eq(#dOcc.purchasable_plots, 1, "已过抵抗期的普通占领城仍允许买地")
    eq(dOcc.purchasable_plots[1].gold_cost, 65, "占领城买地报价")
end)

test("T-33", "F7：非法入参与敌方城市越权拒绝（D-06/A-07）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome" },
            { id = 1, team = 1, civ = "Carthage" },
            { id = 2, team = 2, alive = false },
        },
        visibleAll = 0,
    })
    w:setNilPlayerSlot(3, true)
    w:addCity({ owner = 0, id = 1, name = "Rome", x = 10, y = 6 })
    w:addCity({ owner = 1, id = 77, name = "Carthage", x = 15, y = 6 })

    local badCalls = {
        { 2, 1 },      -- 死玩家
        { 3, 1 },      -- nil 玩家槽位
        { -1, 1 },     -- 负玩家 ID
        { "0", 1 },    -- 字符串玩家 ID
        { 0, nil },    -- nil cityID
        { 0, 1.5 },    -- 非整数 cityID
        { 0, "1" },    -- 字符串 cityID
        { 0, 999 },    -- 不存在 cityID
        { 0, 77 },     -- 敌方城市越权访问
    }
    for _, pair in ipairs(badCalls) do
        local res = notThrows(function()
            return CAB_Collector.GetCityDetail(pair[1], pair[2])
        end, "非法入参不应抛 Lua 异常")
        exactKeys(res, { "__is_object", "error" }, "错误返回仅含 __is_object 与 error")
        truthy(res.__is_object, "错误返回带 __is_object")
        isType(res.error, "string", "错误返回含英文说明（player=" .. tostring(pair[1]) .. ", city=" .. tostring(pair[2]) .. "）")
    end
end)

test("T-34", "F7：IGE 兼容（D-05）——零跨调用状态缓存，实时反映城市、建筑、驻军与报价变化", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = TWO_PLAYERS,
        wars = { { 0, 1 } },
        visibleAll = 0,
    })
    local idGranary = GameInfoTypes.BUILDING_GRANARY
    local idWalls   = GameInfoTypes.BUILDING_WALLS
    local gar1 = w:addUnit({ owner = 0, id = 1, unitType = "UNIT_ARCHER", x = 10, y = 6 })
    local enemy = w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 11, y = 6, damage = 0 })

    local rome = w:addCity({
        owner = 0, id = 1, name = "Rome", x = 10, y = 6,
        pop = 4, damage = 0, strength = 1000,
        garrison = gar1,
        realBuildings = { [idGranary] = 1 },
        canRangeStrikeNow = false,
        canRangeStrikeAt = { ["11:6"] = true },
        purchasable = { buildings = { [idWalls] = { gold = true } }, units = {} },
        affordable = { buildings = { [idWalls] = { gold = false } }, units = {} },
        costs = { bldGold = { [idWalls] = 300 } },
    })

    local d1 = CAB_Collector.GetCityDetail(0, rome:GetID())
    eq(d1.city.pop, 4, "修改前人口 4")
    eq(d1.city.combat_str, 10, "修改前城防 10")
    eq(d1.garrison_unit_id, 1, "修改前驻军 1")
    eq(#d1.built_buildings, 1, "修改前 1 座建筑")
    eq(#d1.ranged_attack_targets, 0, "修改前不可炮击")
    falsy(d1.purchasable_buildings[1].can_afford_gold_now, "修改前城墙买不起")

    -- 模拟 IGE 即时加人口、降血、加城防、删驻军、刷城墙、开启炮击并伤敌
    w:setUnit(gar1, { dead = true })
    w:setUnit(enemy, { damage = 60 })
    w:setCity(rome, {
        pop = 15, damage = 50, strength = 2850,
        realBuildings = { [idGranary] = 1, [idWalls] = 1 },
        canRangeStrikeNow = true,
        purchasable = { buildings = {}, units = {} },
    })

    local d2 = CAB_Collector.GetCityDetail(0, rome:GetID())
    eq(d2.city.pop, 15, "IGE 修改后人口立即变为 15")
    eq(d2.city.hp, 150, "IGE 降血后立即变为 150")
    eq(d2.city.combat_str, 28, "IGE 城防立即变为 28")
    isNil(d2.garrison_unit_id, "IGE 删除驻军后立即省略 garrison_unit_id")
    eq(#d2.built_buildings, 2, "IGE 刷城墙后真实建筑立即变为 2 座")
    eq(#d2.ranged_attack_targets, 1, "IGE 开启炮击后立即捕获可见敌军")
    eq(d2.ranged_attack_targets[1].hp, 40, "IGE 伤敌后炮击目标血量立即反映 40")
    eq(#d2.purchasable_buildings, 0, "IGE 刷新可购列表立即清空")
end)

test("T-35", "F7：动态 GameDefines 生效（CITY_ATTACK_RANGE=3 扩展城防射程 & BUY_PLOTS_DISABLED=1 禁用买地）", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = TWO_PLAYERS,
        wars = { { 0, 1 } },
        visibleAll = 0,
        gameDefines = {
            CITY_ATTACK_RANGE = 3,
            BUY_PLOTS_DISABLED = 1,
        },
    })
    local city = w:addCity({
        owner = 0, id = 1, name = "Fortress", x = 10, y = 6,
        canRangeStrikeNow = true,
        canRangeStrikeAt = { ["13:6"] = true },
        cityPlots = { { x = 10, y = 6 }, { x = 11, y = 6 } },
        canBuyPlotAt = { ["11:6"] = true },
        canBuyPlotNow = { ["11:6"] = true },
        buyPlotCost = { ["11:6"] = 50 },
    })
    w:addUnit({ owner = 1, id = 1, unitType = "UNIT_WARRIOR", x = 13, y = 6, damage = 15 })

    local detail = CAB_Collector.GetCityDetail(0, city:GetID())
    eq(#detail.ranged_attack_targets, 1, "CITY_ATTACK_RANGE=3 应实时生效并命中距 3 格可见敌军")
    eq(detail.ranged_attack_targets[1].distance, 3, "目标距离应为 3")
    eq(detail.ranged_attack_targets[1].hp, 85, "目标血量应为 85")
    eq(#detail.purchasable_plots, 0, "BUY_PLOTS_DISABLED=1 时 purchasable_plots 必须强制为空表")
end)

-- -----------------------------------------------------------------------------
-- 第 6.5 节：M1Sub3 WP5（D-08）三大回合硬阻塞只读查询接口用例（T-36 ~ T-39）
-- -----------------------------------------------------------------------------

test("T-36", "F8：GetResearchOptions 常规研究、免费科技过滤、禁用科研与非法玩家兜底", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        teams = { { id = 0, techs = { [0] = true } } }, -- 已掌握 TECH_AGRICULTURE
        players = {
            {
                id = 0, team = 0, civ = "China", science = 10, overflowResearch = 4,
                currentResearch = 1, -- TECH_POTTERY
                canResearch = { [1] = true, [2] = true, [3] = true },
                researchProgress = { [1] = 15 },
            },
        },
    })
    local dto = CAB_Collector.GetResearchOptions(0)
    truthy(dto.__is_object, "DTO 应带 __is_object")
    falsy(dto.science_disabled, "科研未禁用")
    eq(dto.science_per_turn, 10, "回合科研")
    eq(dto.overflow_research, 4, "溢出科研")
    eq(dto.free_techs_available, 0, "无免费科技")
    falsy(dto.is_free_tech_pending, "非免费科技待选态")
    notNil(dto.current_research, "应包含 current_research")
    eq(dto.current_research.tech_type, "TECH_POTTERY", "当前研究科技名匹配")
    eq(dto.current_research.progress, 15, "当前研究进度匹配")
    eq(dto.current_research.cost, 35, "当前研究花费匹配")
    eq(dto.current_research.turns_left, 2, "当前研究剩余回合匹配")
    same(dto.researched_techs, { "TECH_AGRICULTURE" }, "已研究科技列表匹配")
    eq(#dto.available_techs, 3, "常规可选科技数应为 3")

    -- 免费科技模式：仅保留 CanResearchForFree == true 的科技
    local wFree = S.newWorld({
        teams = { { id = 0, techs = { [0] = true } } },
        players = {
            {
                id = 0, team = 0, civ = "China", science = 10, freeTechs = 1,
                canResearch = { [1] = true, [2] = true, [5] = true },
                canResearchForFree = { [1] = true, [5] = true },
            },
        },
    })
    local dtoFree = CAB_Collector.GetResearchOptions(0)
    truthy(dtoFree.is_free_tech_pending, "应标记 is_free_tech_pending=true")
    eq(dtoFree.free_techs_available, 1, "free_techs_available=1")
    isNil(dtoFree.current_research, "无当前研究时应省略 current_research")
    eq(#dtoFree.available_techs, 2, "免费科技应经 CanResearchForFree 过滤为 2 项")

    -- GAMEOPTION_NO_SCIENCE 禁用科研
    S.newWorld({
        gameOptions = { [GameOptionTypes.GAMEOPTION_NO_SCIENCE] = true },
        players = { { id = 0, team = 0, canResearch = { [1] = true } } },
    })
    local dtoNoSci = CAB_Collector.GetResearchOptions(0)
    truthy(dtoNoSci.science_disabled, "应标记 science_disabled=true")
    eq(#dtoNoSci.available_techs, 0, "禁用科研时可选科技为空")

    -- 非法玩家兜底
    local bad = CAB_Collector.GetResearchOptions(99)
    truthy(bad.__is_object, "错误表带 __is_object")
    notNil(bad.error, "非法玩家应返回 error")
    eq(w:logCount("SelectUnit"), 0, "GetResearchOptions 零 UI 选区调用")
end)

test("T-37", "F9：GetPolicyOptions 常规分支、政策采纳、意识形态信条与无城/禁用规则守卫", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        teams = { { id = 0, currentEra = 0 } }, -- ERA_ANCIENT
        players = {
            {
                id = 0, team = 0, civ = "China",
                culture = 40, culturePerTurn = 6, nextPolicyCost = 25,
                unlockedBranches = { [0] = true }, -- POLICY_BRANCH_TRADITION 已开
                policies = { [1] = true }, -- POLICY_ARISTOCRACY 已采纳
                canAdoptPolicy = { [2] = true, [3] = true }, -- OLIGARCHY / LEGALISM
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
    })

    local dto = CAB_Collector.GetPolicyOptions(0)
    truthy(dto.__is_object, "DTO 应带 __is_object")
    falsy(dto.policies_disabled, "政策未禁用")
    eq(dto.culture, 40, "文化余额匹配")
    eq(dto.next_policy_cost, 25, "下一次政策花费匹配")
    eq(dto.num_cities, 1, "城市数为 1")
    truthy(dto.can_adopt_now, "满足文化花费应 can_adopt_now=true")
    -- 常规分支仅 5 个（排除 PurchaseByLevel=true 的 FREEDOM 意识形态分支）
    eq(#dto.policy_branches, 5, "常规政策分支表应排除意识形态分支")
    -- LIBERTY / HONOR / PIETY 可解锁（TRADITION 已开，RATIONALISM 需文艺复兴时代）
    eq(#dto.unlockable_branches, 3, "应有 3 个当前可解锁常规分支")
    eq(#dto.adoptable_policies, 2, "应有 2 项当前可采纳常规政策")
    same(dto.adopted_policies, { "POLICY_ARISTOCRACY" }, "已采纳政策应跳过自动开门 POLICY_TRADITION")

    -- 后期意识形态信条（已选 FREEDOM 且有 2 个 1 级信条槽位已填，应开放 2 级信条）
    S.newWorld({
        teams = { { id = 0, currentEra = 5 } },
        players = {
            {
                id = 0, team = 0, culture = 0, nextPolicyCost = 500, freeTenets = 1,
                ideologyBranch = 5, -- POLICY_BRANCH_FREEDOM
                tenets = { [1] = { 101, 102 } },
                availableTenets = { [1] = { 5 }, [2] = { 6 } },
            },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
    })
    local dtoIdeo = CAB_Collector.GetPolicyOptions(0)
    eq(dtoIdeo.ideology_branch_type, "POLICY_BRANCH_FREEDOM", "意识形态分支名匹配")
    truthy(dtoIdeo.can_adopt_now, "有免费信条应可采纳")
    eq(#dtoIdeo.adoptable_policies, 2, "应列出 1 级与 2 级可用意识形态信条")
    truthy(dtoIdeo.adoptable_policies[1].is_tenet, "信条应标记 is_tenet=true")

    -- 0 座城市时严禁开启或采纳（SocialPolicyPopup.lua:234）
    S.newWorld({
        players = { { id = 0, team = 0, culture = 100, nextPolicyCost = 25, canAdoptPolicy = { [1] = true } } },
    })
    local dtoNoCity = CAB_Collector.GetPolicyOptions(0)
    falsy(dtoNoCity.can_adopt_now, "无城市时 can_adopt_now=false")
    eq(#dtoNoCity.unlockable_branches, 0, "无城市时无解锁分支")
    eq(#dtoNoCity.adoptable_policies, 0, "无城市时无采纳政策")
    eq(w:logCount("SelectUnit"), 0, "GetPolicyOptions 零 UI 选区调用")
end)

test("T-38", "F10：GetUnitPromotions 晋升就绪/未就绪、InstaHeal 满血过滤与零 UI 选区副作用", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = TWO_PLAYERS,
    })
    local uReady = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5,
        damage = 30, level = 2, experience = 32, experienceNeeded = 30,
        promotionReady = true,
        promotions = { [0] = true }, -- 已有 PROMOTION_SHOCK_1
        availablePromotions = { [1] = true, [2] = true, [3] = true, [4] = true }, -- DRILL_1, SHOCK_2, INSTA_HEAL, EMBARKATION(CannotBeChosen)
    })
    local uFull = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 6, y = 5,
        damage = 0, promotionReady = true,
        availablePromotions = { [0] = true, [3] = true }, -- 满血不应出现 INSTA_HEAL
    })
    local uNotReady = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 7, y = 5,
        promotionReady = false,
        availablePromotions = { [0] = true },
    })
    local enemy = w:addUnit({ id = 99, owner = 1, unitType = "UNIT_WARRIOR", x = 8, y = 5, promotionReady = true })

    w:clearSelection()
    local dto = CAB_Collector.GetUnitPromotions(0, uReady:GetID())
    truthy(dto.__is_object, "DTO 应带 __is_object")
    eq(dto.unit_id, uReady:GetID(), "单位 ID 匹配")
    eq(dto.hp, 70, "伤血 HP 匹配")
    eq(dto.level, 2, "等级匹配")
    eq(dto.experience, 32, "经验匹配")
    eq(dto.experience_needed, 30, "升级所需经验匹配")
    truthy(dto.is_promotion_ready, "应处于待晋升态")
    eq(#dto.earned_promotions, 1, "已获得晋升数为 1")
    eq(dto.earned_promotions[1].promotion_type, "PROMOTION_SHOCK_1", "已获得晋升名匹配")
    eq(#dto.available_promotions, 3, "可选晋升应排除 CannotBeChosen，保留 DRILL_1 / SHOCK_2 / INSTA_HEAL")

    local dtoFull = CAB_Collector.GetUnitPromotions(0, uFull:GetID())
    eq(#dtoFull.available_promotions, 1, "满血单位应过滤掉 INSTA_HEAL，仅留 SHOCK_1")
    eq(dtoFull.available_promotions[1].promotion_type, "PROMOTION_SHOCK_1", "剩余晋升匹配")

    local dtoNotReady = CAB_Collector.GetUnitPromotions(0, uNotReady:GetID())
    falsy(dtoNotReady.is_promotion_ready, "未就绪单位标记 false")
    eq(#dtoNotReady.available_promotions, 0, "未就绪单位可选晋升列表应为空")

    -- 越权查敌军或非法 ID 返错
    notNil(CAB_Collector.GetUnitPromotions(0, enemy:GetID()).error, "查非己方单位应返错")
    notNil(CAB_Collector.GetUnitPromotions(0, "bad").error, "非整数 unitID 应返错")

    -- 关键红线验证：全程零 UI.SelectUnit / ClearSelectionList 调用（支撑入 AI 白名单）
    eq(w:logCount("SelectUnit"), 0, "GetUnitPromotions 必须零 UI.SelectUnit 选区副作用")
    eq(w:logCount("ClearSelectionList"), 0, "GetUnitPromotions 必须零 ClearSelectionList 调用")
end)

test("T-39", "WP5 IGE 兼容（D-05）：科研/政策/晋升查询零跨调用缓存实时反映变更", function()
    ensureCollectorLoaded()
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, science = 5, culture = 10, nextPolicyCost = 25, canResearch = { [1] = true } },
        },
        cities = { { owner = 0, name = "Beijing", x = 5, y = 5, isCapital = true } },
    })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5, promotionReady = false })

    eq(CAB_Collector.GetResearchOptions(0).free_techs_available, 0, "初始无免费科技")
    falsy(CAB_Collector.GetPolicyOptions(0).can_adopt_now, "初始文化不足")
    falsy(CAB_Collector.GetUnitPromotions(0, u:GetID()).is_promotion_ready, "初始不可晋升")

    -- 模拟 IGE 即时修改
    w:setPlayer(0, { freeTechs = 1, culture = 50 })
    w:setUnit(u, { promotionReady = true, availablePromotions = { [0] = true } })

    eq(CAB_Collector.GetResearchOptions(0).free_techs_available, 1, "IGE 后即时看到免费科技")
    truthy(CAB_Collector.GetPolicyOptions(0).can_adopt_now, "IGE 加文化后即时可采纳政策")
    eq(#CAB_Collector.GetUnitPromotions(0, u:GetID()).available_promotions, 1, "IGE 加经验后即时看到可选晋升")
end)

-- -----------------------------------------------------------------------------
-- 第 7 节：运行器与收尾守卫（FW-01）
-- -----------------------------------------------------------------------------

local PRINT_LINES_LIMIT = 30

-- -----------------------------------------------------------------------------
-- 函数：matchesFilter(case, filterStr)
-- 做什么：判断用例 ID 或标题是否命中命令行 --filter 子串。
-- 输入：case（用例表）、filterStr（可选过滤字符串）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
local function matchesFilter(case, filterStr)
    if filterStr == nil or filterStr == "" then return true end
    local needle = tostring(filterStr):lower()
    if tostring(case.id):lower():find(needle, 1, true) ~= nil then return true end
    if tostring(case.title):lower():find(needle, 1, true) ~= nil then return true end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：runOne(case)
-- 做什么：按 beginCase -> xpcall(case.fn) -> endCase 顺序执行单条用例并校验边界红线。
-- 输入：case（{ id, title, fn }）。
-- 输出：(status, message)。
-- -----------------------------------------------------------------------------
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
        if message == "" then
            message = boundaryMessage
        else
            message = message .. "\n" .. boundaryMessage
        end
    end

    if status == "fail" and #S.prints > 0 then
        local lines = {}
        for i = 1, math.min(#S.prints, PRINT_LINES_LIMIT) do
            lines[i] = S.prints[i]
        end
        if #S.prints > PRINT_LINES_LIMIT then
            lines[#lines + 1] = "…（共 " .. #S.prints .. " 行，仅显示前 " .. PRINT_LINES_LIMIT .. " 行）"
        end
        message = message .. "\n—— 被测模块 print 输出 ——\n" .. table.concat(lines, "\n")
    end
    return status, message
end

-- -----------------------------------------------------------------------------
-- 函数：runAll()
-- 做什么：依次执行所有匹配用例并在末尾追加 FW-01 全局只读守卫归零总检。
-- 输出：汇总表（供 Python 测试入口打印与判定退出码）。
-- -----------------------------------------------------------------------------
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
    if summary.guardViolations > 0 or summary.guardMissing > 0 then
        local parts = {}
        for _, record in ipairs(S.guard.violations) do
            parts[#parts + 1] = "违规调用：" .. record.owner .. "." .. record.method .. "()"
        end
        for _, record in ipairs(S.guard.missing) do
            parts[#parts + 1] = "桩未实现方法：" .. record.owner .. "." .. record.method .. "()"
        end
        summary.failed = summary.failed + 1
        summary.cases[#summary.cases + 1] = {
            id = "FW-01",
            status = "fail",
            title = "只读守卫累计违规不为零（框架收尾总检）",
            message = table.concat(parts, "\n"),
        }
    end
    return summary
end

return runAll()
