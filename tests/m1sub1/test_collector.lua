-- =============================================================================
-- 文件：tests/m1sub1/test_collector.lua
-- 做什么：《mod/Lua/CAB_InfoCollector.lua》的桩测试用例。每个用例自己建一个小世界，互不共享状态。
-- 为什么：按用户决策 U-03，本子模块用引擎桩测试验证逻辑；引擎环境由 engine_stubs.lua 提供。
--
-- 结构：
--   第 1 节  用例注册与断言工具；
--   第 2 节  冒烟与配置表用例（T-00、T-01）；
--   第 3 节  桩自检用例（T-02 至 T-09）；
--   第 4 节  运行器：逐条执行、核对用例边界、汇总结果并返回给 Python 入口。
--
-- 用例编号沿用《SubM1工作计划.md》§10.3 的清单。T-02 至 T-09 不在那份清单里，是 WP2 补充的
-- “桩自检”：桩写错会固化错误的调用方式，而普通用例本身发现不了（计划 §9.6 的 R-9），
-- 所以把桩的每条假设单独固定成用例。后续工作包的用例追加在第 3 节之后。
--
-- 写用例的约定：
--   * 需要第二个场景时新建一个世界，不要在调用被测函数之后继续布置同一个世界。
--     原因：世界快照的基线取自“最后一次布置之后、第一次被读之前”，事后再布置会刷新基线。
--   * 用例结束时，运行器会自动核对：世界状态没变、没有触发只读守卫、没有新建全局变量。
-- =============================================================================

local S = CAB_TEST_STUBS

-- 用例注册表，按注册顺序执行
local cases = {}

-- -----------------------------------------------------------------------------
-- 函数：test(id, title, fn)
-- 做什么：注册一条用例。
-- 输入：id，用例编号（如 "T-01"）；title，一句话说明；fn，用例函数，不带参数。
-- -----------------------------------------------------------------------------
local function test(id, title, fn)
    table.insert(cases, { id = id, title = title, fn = fn })
end

-- -----------------------------------------------------------------------------
-- 函数：skip(reason)
-- 做什么：把当前用例标记为“跳过”并终止它。用于被测文件尚未创建的情况。
-- 输入：reason，跳过原因。
-- -----------------------------------------------------------------------------
local function skip(reason)
    error({ __skip = true, reason = reason })
end

-- -----------------------------------------------------------------------------
-- 函数：fail(msg)
-- 做什么：断言失败时抛出带调用栈的错误，终止当前用例。
-- 为什么附带调用栈：运行器捕获错误时已经离开出错点，栈也回卷了，事后取不到。
-- -----------------------------------------------------------------------------
local function fail(msg)
    error(msg .. "\n" .. debug.traceback(), 2)
end

-- -----------------------------------------------------------------------------
-- 函数：show(v)
-- 做什么：把值转成便于阅读的形式，用在断言失败的提示里。
--     字符串加引号；桩对象显示成“种类(身份)”；数组显示成 {a, b}；其他表显示成 {k=v, …}。
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
-- 做什么：递归比较两个值是否相同。表按键逐个比较；桩对象按身份比较；数字与字符串按值比较。
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
-- 做什么：取出表的全部键并排序（数字在前、字符串在后），用于断言键集合。
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

-- 断言：actual 等于 expected
local function eq(actual, expected, msg)
    if actual ~= expected then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

-- 断言：actual 不等于 unexpected
local function ne(actual, unexpected, msg)
    if actual == unexpected then
        fail(msg .. "：不应等于 " .. show(unexpected))
    end
end

-- 断言：actual 与 expected 深度相同（表按内容比较）
local function same(actual, expected, msg)
    if not isSame(actual, expected) then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

-- 断言：严格为 true
local function truthy(actual, msg)
    if actual ~= true then
        fail(msg .. "：应为 true，实际 " .. show(actual))
    end
end

-- 断言：严格为 false
local function falsy(actual, msg)
    if actual ~= false then
        fail(msg .. "：应为 false，实际 " .. show(actual))
    end
end

-- 断言：值为 nil
local function isNil(actual, msg)
    if actual ~= nil then
        fail(msg .. "：应为 nil，实际 " .. show(actual))
    end
end

-- 断言：值不为 nil
local function notNil(actual, msg)
    if actual == nil then
        fail(msg .. "：不应为 nil")
    end
end

-- 断言：值的类型
local function isType(actual, typeName, msg)
    if type(actual) ~= typeName then
        fail(msg .. "：类型应为 " .. typeName .. "，实际 " .. type(actual) .. "（" .. show(actual) .. "）")
    end
end

-- -----------------------------------------------------------------------------
-- 函数：exactKeys(t, expectedKeys, msg)
-- 做什么：断言表的键集合恰好等于给定的键（不多不少）。
-- 为什么：DTO 的键集合是接口契约；“可空字段省略键”（D-02）也靠它核对。
-- 输入：t，待查的表；expectedKeys，键名数组；msg，断言说明。
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
-- 函数：throws(fn, msg)
-- 做什么：断言一段代码会抛错，并返回错误信息。
-- 输入：fn，不带参数的函数；msg，断言说明。
-- 输出：错误信息（转成字符串）。
-- -----------------------------------------------------------------------------
local function throws(fn, msg)
    local ok, err = pcall(fn)
    if ok then
        fail(msg .. "：应当抛错，实际正常返回")
    end
    return tostring(err)
end

-- -----------------------------------------------------------------------------
-- 函数：notThrows(fn, msg)
-- 做什么：断言一段代码不抛错。
-- 输出：fn，不带参数的函数；msg，断言说明。
-- 输出：这段代码的全部返回值。
-- -----------------------------------------------------------------------------
local function notThrows(fn, msg)
    local results = { pcall(fn) }
    if not results[1] then
        fail(msg .. "：不应抛错，实际报错：" .. tostring(results[2]))
    end
    return unpack(results, 2, #results)
end

-- -----------------------------------------------------------------------------
-- 函数：countPlotsInRadius(w, cx, cy, radius)
-- 做什么：按官方的包络扫描写法数出半径内的格数
--     （InGame.lua:598-614：for dx, dy 取 Map.GetPlotXY，再用 Map.PlotDistance 过滤）。
-- 输出：格数。
-- -----------------------------------------------------------------------------
local function countPlotsInRadius(w, cx, cy, radius)
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
-- 函数：includeDiff(before)
-- 做什么：比较 include 次数表的现状与先前的快照，得出“期间新发生的 include”。
-- 输入：before，先前的 S.includeCount 快照。
-- 输出：{ [模块名] = 新增次数 }，只列有新增的模块。
-- -----------------------------------------------------------------------------
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
-- 做什么：globalSnapshot 记下当前全部全局名；newGlobals 求出之后新增的全局名（已排序）。
-- 用途：核对被测文件没有额外定义全局（验收项 A-8）。
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

-- 常用规格：主玩家 0 在队伍 0，对手玩家 1 在队伍 1
local TWO_PLAYERS = { { id = 0, team = 0, civ = "Rome" }, { id = 1, team = 1, civ = "Carthage" } }

-- -----------------------------------------------------------------------------
-- 函数：snapshotIncludes()
-- 做什么：记下当前的 include 次数表，供 includeDiff 比较。
-- -----------------------------------------------------------------------------
local function snapshotIncludes()
    local snapshot = {}
    for name, n in pairs(S.includeCount) do
        snapshot[name] = n
    end
    return snapshot
end

-- -----------------------------------------------------------------------------
-- 第 2 节：冒烟与配置表用例
-- -----------------------------------------------------------------------------

test("T-00", "冒烟：桩环境可加载 CAB_InfoCollector.lua（文件不存在时跳过）", function()
    if not S.hasModule("CAB_InfoCollector") then
        skip("mod/Lua/CAB_InfoCollector.lua 尚未创建（WP3 起分步落盘）")
    end
    local globalsBefore = globalSnapshot()
    local includesBefore = snapshotIncludes()

    local ok, err = pcall(include, "CAB_InfoCollector")
    truthy(ok, "include('CAB_InfoCollector') 应成功，实际报错：" .. tostring(err))

    isType(CAB_Collector, "table", "应定义全局表 CAB_Collector")
    -- 采集文件只允许 include 配置表一次（验收项 A-9）
    same(includeDiff(includesBefore), { CAB_Config = 1 }, "采集文件的 include 记录")
    -- 采集文件不得定义额外全局。CAB_Config 是它 include 进来的，首次加载时也属于新增（验收项 A-8）
    local allowed = { CAB_Collector = true, CAB_Config = true }
    for _, name in ipairs(newGlobals(globalsBefore)) do
        truthy(allowed[name] ~= nil, "采集文件不应定义全局变量 " .. name)
    end
end)

test("T-01", "CAB_Config 的 12 个键的类型与默认值", function()
    if not S.hasModule("CAB_Config") then
        skip("mod/Lua/CAB_Config.lua 尚未创建（WP1）")
    end
    -- 键名、类型、默认值逐项照《模块设计说明.md》§4.1；MAX_SCAN_RADIUS 照计划 D-06
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
    -- 先让默认世界被读过一次，拍下基线；之后加载配置表若动了世界，运行器在用例结束时会报出来
    local defaultWorld = S.worlds[1]
    defaultWorld:reveal(0, 0, 0)
    _ = defaultWorld:getPlot(0, 0):IsVisible(0)

    local ok, err = pcall(include, "CAB_Config")
    truthy(ok, "include('CAB_Config') 应成功，实际报错：" .. tostring(err))

    isType(CAB_Config, "table", "应定义全局表 CAB_Config")
    same(CAB_Config, EXPECTED, "CAB_Config 的键与默认值（应恰好 12 个键，没有多余键）")
    isType(CAB_Config.DB_NAME, "string", "DB_NAME 的类型")
    isType(CAB_Config.ENABLE_DEBUG_LOG, "boolean", "ENABLE_DEBUG_LOG 的类型")
    for name, value in pairs(CAB_Config) do
        if name ~= "DB_NAME" and name ~= "ENABLE_DEBUG_LOG" then
            isType(value, "number", "CAB_Config." .. name .. " 的类型")
        end
    end

    -- 纯静态表：加载时不 include 别的文件、不调用引擎、不新建别的全局
    same(includeDiff(includesBefore), {}, "加载 CAB_Config 不应触发其他 include")
    eq(#defaultWorld.log, 0, "加载 CAB_Config 不应调用引擎判定")
    for _, name in ipairs(newGlobals(globalsBefore)) do
        eq(name, "CAB_Config", "加载 CAB_Config 只应新增全局变量 CAB_Config")
    end
end)

-- -----------------------------------------------------------------------------
-- 第 3 节：桩自检用例
-- 这些用例不测被测代码，只核对“桩的每条假设”确实成立（见文件头的说明）。
-- -----------------------------------------------------------------------------

test("T-02", "桩自检：Map.GetPlotXY 越界返回 nil，半径 0/1/2 的六边形盘各有 1/7/19 格", function()
    local w = S.newWorld({ width = 24, height = 20 })
    eq(Map.GetPlot(10, 5), w:getPlot(10, 5), "Map.GetPlot 应返回世界里同一个地块对象")
    eq(Map.GetPlotXY(10, 5, 2, -1), w:getPlot(12, 4), "GetPlotXY(x, y, dx, dy) 应等价于 GetPlot(x+dx, y+dy)")

    -- 越界返回 nil（InGame.lua:600-601 的官方判空写法）
    isNil(Map.GetPlotXY(10, 5, 14, 0), "x 越界应返回 nil")
    isNil(Map.GetPlotXY(10, 5, 0, 15), "y 越界应返回 nil")
    isNil(Map.GetPlotXY(10, 5, -11, 0), "x 负向越界应返回 nil")
    notNil(Map.GetPlot(23, 19), "地图边缘的最后一格应能取到")
    eq(Map.GetNumPlots(), 480, "地图总格数")
    eq(Map.GetPlotByIndex(479), w:getPlot(23, 19), "GetPlotByIndex 应从左上角起按行编号")

    -- 官方包络扫描（InGame.lua:598-614）在半径 0、1、2 内的格数
    eq(countPlotsInRadius(w, 10, 10, 0), 1, "半径 0 的格数")
    eq(countPlotsInRadius(w, 10, 10, 1), 7, "半径 1 的格数")
    eq(countPlotsInRadius(w, 10, 10, 2), 19, "半径 2 的格数")
    eq(Map.PlotDistance(3, 4, 15, 9), Map.PlotDistance(15, 9, 3, 4), "距离应对称")

    -- 相邻关系：桩的网格是“奇数行右偏半格”。偶数行的格 (10,6)，上邻是 (9,5) 与 (10,5)，
    -- 下邻是 (9,7) 与 (10,7)。T-30 的格数结论依赖这一点，所以单独固定下来。
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
    same(neighbors, { "10:5", "10:7", "11:6", "9:5", "9:6", "9:7" }, "偶数行格 (10,6) 的相邻格")
end)

test("T-03", "桩自检：可见蕴含已探索，视野与隐形都按队伍独立", function()
    local w = S.newWorld()
    local pPlot = w:getPlot(5, 5)
    falsy(pPlot:IsRevealed(0), "新格对队伍 0 应是未探索")
    falsy(pPlot:IsVisible(0), "新格对队伍 0 应是不可见")

    w:reveal(0, 5, 5)
    truthy(pPlot:IsRevealed(0), "reveal 之后应已探索")
    falsy(pPlot:IsVisible(0), "只 reveal 之后仍应不可见（迷雾格）")
    falsy(pPlot:IsRevealed(1), "对队伍 0 的探索不应影响队伍 1")

    w:show(0, 5, 5)
    truthy(pPlot:IsRevealed(0), "可见的格必然已探索")
    truthy(pPlot:IsVisible(0), "show 之后应可见")

    w:reveal(0, 5, 5, false)
    falsy(pPlot:IsRevealed(0), "改成未探索后应是未探索")
    falsy(pPlot:IsVisible(0), "未探索的格必然不可见")

    w:show(0, 5, 5)
    w:show(0, 5, 5, false)
    truthy(pPlot:IsRevealed(0), "取消可见不应取消探索")
    falsy(pPlot:IsVisible(0), "取消可见后应是迷雾格")

    -- setPlot 的视野字段按队伍设置
    w:setPlot(6, 5, { visible = { [1] = true }, revealed = { [2] = true } })
    local q = w:getPlot(6, 5)
    truthy(q:IsVisible(1), "队伍 1 可见")
    truthy(q:IsRevealed(1), "队伍 1 已探索")
    falsy(q:IsRevealed(0), "队伍 0 未探索")
    truthy(q:IsRevealed(2), "队伍 2 已探索")
    falsy(q:IsVisible(2), "队伍 2 不可见")

    -- 批量设置
    w:revealAll(3)
    truthy(w:getPlot(0, 0):IsRevealed(3), "revealAll 之后边缘格也应已探索")
    falsy(w:getPlot(0, 0):IsVisible(3), "revealAll 不应让格子可见")
    w:showAll(3)
    truthy(w:getPlot(0, 0):IsVisible(3), "showAll 之后应可见")
    w:unrevealAll(3)
    falsy(w:getPlot(0, 0):IsRevealed(3), "unrevealAll 之后应是未探索")

    -- 隐形按队伍：F2 的依据（PlotMouseoverInclude.lua:302）
    w:addPlayer({ id = 0, team = 0 })
    local sub = w:addUnit({ owner = 0, unitType = "UNIT_TRIREME", x = 8, y = 8, invisibleTo = { [1] = true } })
    falsy(sub:IsInvisible(0), "对队伍 0 不隐形")
    truthy(sub:IsInvisible(1), "对队伍 1 隐形")
    falsy(sub:IsInvisible(2), "对队伍 2 不隐形")
end)

test("T-04", "桩自检：GameInfo 按行号取行，长度是行数，越界项不是 nil", function()
    local w = S.newWorld()
    eq(#GameInfo.Units, 8, "GameInfo.Units 的长度应是行数")
    eq(GameInfo.Units[0].Type, "UNIT_WARRIOR", "行号从 0 起")
    eq(GameInfo.Units[0].ID, 0, "行带 ID 列")
    eq(GameInfo.Units["UNIT_ARCHER"].ID, 1, "可以按 Type 名取行")
    eq(GameInfo.Units.UNIT_ARCHER.ID, 1, "Type 名也可以用点号写")

    -- 官方惯用写法（UnitPanel.lua:202）：for i = 0, #GameInfoActions。长度是行数，
    -- 所以最后一轮取到的是越界项。它不能是 nil，否则官方代码读 action.Visible 时就会报错。
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
    eq(visited, 8, "官方惯用写法应恰好走遍全部有效行")
    truthy(lastIsEmpty, "越界项应是空表")
    isNil(GameInfo.Units[-1].Type, "负行号也应得到空表")

    -- 迭代器只走有效行（TopPanel.lua:190）
    local n = 0
    for row in GameInfo.Resources() do
        n = n + 1
        isType(row.Type, "string", "迭代器应返回有效行")
    end
    eq(n, 4, "迭代器的行数")
    eq(Game.GetResourceUsageType(GameInfo.Resources["RESOURCE_HORSE"].ID),
        ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC, "资源用途")

    -- 动作表与 GameInfoTypes
    eq(#GameInfoActions, 5, "默认动作数")
    eq(GameInfoActions[0].Type, "MISSION_FORTIFY", "动作的 Type 就是任务类型名")
    eq(GameInfoTypes.MISSION_HEAL, 2, "GameInfoTypes 按动作类型名给出行号")
    eq(GameInfoTypes.UNIT_ARCHER, 1, "GameInfoTypes 按单位类型名给出行号")

    -- 增行只影响本世界
    local newID = w:addInfoRow("Units", { Type = "UNIT_TEST", Description = "TXT_KEY_UNIT_TEST" })
    eq(newID, 8, "新行的行号")
    eq(#GameInfo.Units, 9, "增行后的长度")
    eq(GameInfoTypes.UNIT_TEST, 8, "增行后 GameInfoTypes 应刷新")
    local other = S.newWorld()
    eq(#GameInfo.Units, 8, "新建的世界不应继承上一个世界的行")
end)

test("T-05", "桩自检：判定类调用被记入日志，并带目标格当时的可见性", function()
    -- revealAll 只让全图“已探索”；下面把用到的目标格逐个设为可见，只留 (12,5) 作迷雾格
    local w = S.newWorld({ players = TWO_PLAYERS, revealAll = 0 })
    w:show(0, 11, 5)
    w:show(0, 13, 5)
    w:show(0, 9, 5)
    w:show(0, 8, 5)
    local archer = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 10, y = 5,
        canRangeStrike = true,
        canRangeStrikeAt = { ["11:5"] = true, ["12:5"] = true },
        canMoveThrough = { ["9:5"] = true },
    })

    truthy(archer:CanRangeStrike(), "canRangeStrike 应生效")
    truthy(archer:CanRangeStrikeAt(11, 5, true, true), "可见格上的判定")
    truthy(archer:CanRangeStrikeAt(12, 5, true, true), "迷雾格上的判定")
    falsy(archer:CanRangeStrikeAt(13, 5, true, true), "没有配置的格应为假")
    truthy(archer:CanMoveThrough(w:getPlot(9, 5)), "canMoveThrough 应生效")
    falsy(archer:CanMoveThrough(w:getPlot(8, 5)), "没有配置的格应为假")
    falsy(archer:CanRangeStrikeAt(999, 999, true, true), "越界目标应为假且不报错")

    eq(w:logCount("CanRangeStrikeAt"), 4, "CanRangeStrikeAt 的调用次数")
    eq(w:logCount("CanMoveThrough"), 2, "CanMoveThrough 的调用次数")
    local log = w:logOf("CanRangeStrikeAt")
    eq(log[1].x, 11, "第一条日志的目标格")
    truthy(log[1].visible, "可见格")
    truthy(log[1].revealed, "已探索")
    eq(log[2].y, 5, "第二条日志的目标格")
    falsy(log[2].visible, "迷雾格：不可见")
    truthy(log[2].revealed, "迷雾格：已探索")
    eq(log[1].args[3], true, "额外实参应原样记录")
    eq(log[1].args[4], true, "额外实参应原样记录")
    isNil(log[4].x, "越界目标在日志里没有坐标")

    -- 筛选“以不可见格为目标”的调用：泄露回归（T-68）的第二条断言用它
    local invisible = w:queriesOnInvisible({ "CanRangeStrikeAt", "CanMoveThrough" })
    eq(#invisible, 1, "对不可见格的调用次数")
    eq(invisible[1].x, 12, "对不可见格的调用的目标格")
    eq(w:queriesOnInvisible("CanMoveThrough"), {}, "CanMoveThrough 没有以不可见格为目标")

    -- 判定字段也可以写成函数
    local warrior = w:addUnit({
        owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 6,
        canMoveThrough = function(self, pPlot) return pPlot:IsRiver() end,
    })
    w:setPlot(10, 7, { river = true })
    truthy(warrior:CanMoveThrough(w:getPlot(10, 7)), "函数式判定：有河")
    falsy(warrior:CanMoveThrough(w:getPlot(9, 7)), "函数式判定：无河")

    w:clearLog()
    eq(w:logCount({ "CanRangeStrikeAt", "CanMoveThrough" }), 0, "clearLog 之后")
end)

test("T-06", "桩自检：写入类接口一被调用就报错并记录，选中例外不违规", function()
    local w = S.newWorld({ players = { { id = 0, team = 0 } } })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local c = w:addCity({ owner = 0, name = "Rome", x = 6, y = 5 })
    local pPlot = w:getPlot(5, 5)
    local base = #S.guard.violations

    -- 计划 WP2 第 4 点点名的名单，逐个验证。这一条用例故意制造违规，结束前会把记录清掉。
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
        local err = throws(trap[2], trap[1] .. " 应当抛错")
        truthy(err:find("只读守卫", 1, true) ~= nil, trap[1] .. " 的报错应来自只读守卫，实际：" .. err)
    end
    eq(#S.guard.violations, base + #traps, "每次违规都应被记录")

    -- Set* 是前缀模式：名单里没有的 Set 开头方法也会被拦
    throws(function() Players[0]:SetGold(999) end, "SetGold 应当抛错")
    throws(function() UI.SetInterfaceMode(1) end, "UI.SetInterfaceMode 应当抛错")
    eq(#S.guard.violations, base + #traps + 2, "Set 开头的方法也应被记录")

    -- 允许的例外：选中操作不违规（计划 §3.3 的 P-3），但要记入调用日志
    UI.SelectUnit(u)
    UI.ClearSelectionList()
    eq(#S.guard.violations, base + #traps + 2, "UI.SelectUnit 与 UI.ClearSelectionList 是允许的例外")
    eq(w:logCount("SelectUnit"), 1, "SelectUnit 应记入调用日志")
    eq(w:logOf("SelectUnit")[1].self, u, "日志里应有被选中的单位")
    eq(w:logCount("ClearSelectionList"), 1, "ClearSelectionList 应记入调用日志")

    for i = #S.guard.violations, base + 1, -1 do
        S.guard.violations[i] = nil
    end
    eq(#S.guard.violations, base, "清掉本用例故意制造的记录")
end)

test("T-07", "桩自检：Players 槽位恒有对象，未参战的是死玩家", function()
    local w = S.newWorld({ players = { { id = 0, team = 0 }, { id = 1, team = 1 } } })
    truthy(Players[0]:IsAlive(), "参战的玩家是存活的")
    falsy(Players[5]:IsAlive(), "没参战的槽位是死玩家")
    notNil(Players[5], "没参战的槽位也应返回对象，而不是 nil")
    isNil(Players[99999], "越界的编号才是 nil")

    -- 官方写法（CultureOverview.lua:1798-1800）：循环里不判 nil，直接调用
    local alive = 0
    for i = 0, GameDefines.MAX_CIV_PLAYERS - 1 do
        local p = Players[i]
        if p:IsAlive() then
            alive = alive + 1
        end
    end
    eq(alive, 2, "官方的不判 nil 循环应能在桩上运行")

    -- 被测代码遍历过玩家表之后，用例再 addPlayer，活玩家必须生效
    local late = w:addPlayer({ id = 7, team = 7 })
    truthy(Players[7]:IsAlive(), "后加入的玩家应是存活的")
    eq(Players[7], late, "应返回用例创建的玩家对象")
    eq(S.playerTeamOf(w, 5), -1, "没参战的玩家的队伍是 -1")
    eq(S.playerTeamOf(w, 7), 7, "参战玩家的队伍")
    eq(Teams[7]:IsAtWar(0), false, "新建的队伍默认不与任何人交战")
    isNil(Teams[9], "不存在的队伍是 nil")
    falsy(Teams[0]:IsAtWar(1), "没有设置过的队伍对默认不交战")
    w:atWar(0, 1)
    truthy(Teams[0]:IsAtWar(1), "atWar 之后应交战")
    truthy(Teams[1]:IsAtWar(0), "交战关系应对称")
end)

test("T-08", "桩自检：世界快照能检出对世界的改动，且不把界面状态算进去", function()
    local w = S.newWorld({ players = { { id = 0, team = 0 }, { id = 1, team = 1 } } })
    local u = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 5, y = 5 })
    local pPlot = w:getPlot(5, 5)
    isNil(w._snapshot, "还没被读过时不应有基线")
    _ = u:GetX()
    local baseline = w._snapshot
    notNil(baseline, "被读过之后应有基线")
    eq(S.snapshot(w), baseline, "没有改动时快照不变")

    -- 每一步都直接改内部状态，模拟“被测代码写了世界”；改完立刻还原
    local function mutates(label, change, restore)
        change()
        ne(S.snapshot(w), baseline, label .. " 之后快照应变化")
        restore()
        eq(S.snapshot(w), baseline, label .. " 还原之后快照应恢复")
    end
    mutates("改单位属性", function() u._s.damage = 10 end, function() u._s.damage = 0 end)
    mutates("改地块属性", function() pPlot._s.hills = true end, function() pPlot._s.hills = false end)
    mutates("改地块视野", function() pPlot._s.revealed[0] = true end, function() pPlot._s.revealed[0] = nil end)
    mutates("改 GameInfo 行", function() w.info.Units[0].Combat = 99 end, function() w.info.Units[0].Combat = 8 end)
    mutates("改交战关系", function() w.teams[1]._s.atWar[0] = true end,
        function() w.teams[1]._s.atWar[0] = nil end)
    mutates("改 GameDefines", function() GameDefines.MAX_HIT_POINTS = 1 end,
        function() GameDefines.MAX_HIT_POINTS = 100 end)

    -- 界面状态不在快照里：切换选中（P-3 允许）不会被当成写入
    UI.SelectUnit(u)
    eq(S.snapshot(w), baseline, "切换选中不应改变快照")

    -- 差异提示应给出前后对照，便于定位
    u._s.damage = 10
    local diff = S.firstDiff(baseline, S.snapshot(w))
    truthy(diff:find("=>", 1, true) ~= nil, "firstDiff 应给出前后对照")
    u._s.damage = 0
end)

test("T-09", "桩自检：单位、城市、玩家的取值方法返回布置时设置的值", function()
    -- 每行一个断言，逐个核对话“方法名 → 字段”的对应关系，防止桩里字段错位
    local w = S.newWorld({
        players = {
            { id = 0, team = 0, civ = "Rome", name = "Augustus", goldenAge = true,
              gold = 150, goldRate = 7, science = 12, culturePerTurn = 5, faith = 40, faithPerTurn = 3,
              happiness = 9, resourcesAvailable = { [0] = 4, [1] = 0 }, resourcesTotal = { [0] = 6 } },
            { id = 1, team = 1, turnActive = false,
              blockingType = EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION, blockingNotificationIndex = 7,
              notifications = { { index = 3, summary = "A", str = "a" },
                                { index = 7, summary = "Need production", str = "Pick something" } } },
        },
        gameDefines = { BUY_PLOTS_DISABLED = 1 },
    })
    local p = Players[0]

    -- 单位
    local u = w:addUnit({
        owner = 0, unitType = "UNIT_ARCHER", x = 10, y = 5, nameKey = "TXT_KEY_MY_ARCHER",
        damage = 30, maxHp = 100, moves = 60, maxMoves = 120, range = 3, fortifyTurns = 2, readyToMove = false,
        promotionReady = true, automated = true, delayedDeath = true, isCombat = true, embarked = true,
        invisibleTo = { [1] = true }, canRangeStrike = true, canAttack = false, mustSetUp = true,
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
    truthy(u:IsInvisible(1), "IsInvisible")
    falsy(u:IsInvisible(0), "IsInvisible")
    truthy(u:CanRangeStrike(), "CanRangeStrike")
    falsy(u:IsCanAttack(), "IsCanAttack")
    truthy(u:IsMustSetUpToRangedAttack(), "IsMustSetUpToRangedAttack")
    falsy(u:IsEverFortifyable(), "IsEverFortifyable")
    truthy(u:IsHurt(), "IsHurt")
    falsy(u:CanHeal(u:GetPlot()), "CanHeal")

    -- 不设置时按单位类型所在行推导
    local warrior = w:addUnit({ owner = 0, unitType = "UNIT_WARRIOR", x = 10, y = 6 })
    eq(warrior:GetID(), 1, "单位编号按拥有者递增")
    eq(warrior:GetName(), "TXT_KEY_UNIT_WARRIOR", "名称键默认取行里的 Description")
    eq(warrior:MaxMoves(), 120, "最大移动力默认 = 行里的 Moves × MOVE_DENOMINATOR")
    eq(warrior:MovesLeft(), 120, "剩余移动力默认等于最大移动力")
    eq(warrior:GetBaseCombatStrength(), 8, "战力默认取行里的 Combat")
    eq(warrior:Range(), 0, "射程默认取行里的 Range")
    truthy(warrior:IsCombatUnit(), "有战力的单位默认是战斗单位")
    truthy(warrior:IsReadyToMove(), "有移动力默认可行动")
    truthy(warrior:IsEverFortifyable(), "战斗单位默认可驻扎")
    truthy(warrior:IsCanAttack(), "有移动力的战斗单位默认可攻击")
    falsy(warrior:IsHurt(), "满血默认没有受伤")
    local settler = w:addUnit({ owner = 0, unitType = "UNIT_SETTLER", x = 10, y = 7 })
    falsy(settler:IsCombatUnit(), "没有战力的单位默认是民用单位")
    falsy(settler:IsEverFortifyable(), "民用单位默认不可驻扎")
    falsy(settler:IsCanAttack(), "民用单位默认不可攻击")

    -- 城市
    local c = w:addCity({
        owner = 0, name = "Rome", x = 10, y = 5, pop = 7, damage = 30, maxHp = 250, strength = 1234,
        isCapital = true, isPuppet = true, isOccupied = true, isResistance = true, isRazing = true,
        yields = { [YieldTypes.YIELD_FOOD] = 8, [YieldTypes.YIELD_PRODUCTION] = 6, [YieldTypes.YIELD_GOLD] = 5,
                   [YieldTypes.YIELD_SCIENCE] = 4, [YieldTypes.YIELD_CULTURE] = 1, [YieldTypes.YIELD_FAITH] = 2 },
        productionModifier = 25, foodNet = 3, foodStore = 12, growthThreshold = 30, foodTurnsLeft = 6,
        culturePerTurn = 2, faithPerTurn = 1,
        orderQueueLength = 2, isProduction = true, isProductionProcess = false, productionTurnsLeft = 4,
        productionNameKey = "TXT_KEY_BUILDING_GRANARY",
        garrison = u, realBuildings = { [3] = 1, [0] = 2 },
        cityPlots = { { x = 10, y = 5 }, { x = 11, y = 5 }, { x = 10, y = 6 } },
        canRangeStrike = true, canRangeStrikeNow = true, canRangeStrikeAt = { ["11:6"] = true },
        purchasable = { units = { [1] = { gold = true, faith = true } }, buildings = { [2] = { gold = true } } },
        affordable = { units = { [1] = { gold = false, faith = true } }, buildings = {} },
        costs = { unitGold = { [1] = 500 }, unitFaith = { [1] = 300 }, bldGold = { [2] = 200 }, bldFaith = { [2] = 0 } },
        canBuyPlotAt = { ["11:5"] = true, ["10:6"] = true }, canBuyPlotNow = { ["11:5"] = true },
        buyPlotCost = { ["11:5"] = 60, ["10:6"] = 45 },
    })
    eq(c:GetID(), 0, "GetID")
    eq(c:GetName(), "Rome", "GetName")
    eq(c:GetPopulation(), 7, "GetPopulation")
    eq(c:GetX(), 10, "GetX")
    eq(c:GetY(), 5, "GetY")
    eq(c:GetMaxHitPoints(), 250, "GetMaxHitPoints")
    eq(c:GetDamage(), 30, "GetDamage")
    eq(c:GetStrengthValue(), 1234, "GetStrengthValue")
    truthy(c:IsCapital(), "IsCapital")
    truthy(c:IsPuppet(), "IsPuppet")
    truthy(c:IsOccupied(), "IsOccupied")
    truthy(c:IsResistance(), "IsResistance")
    truthy(c:IsRazing(), "IsRazing")
    eq(c:GetOwner(), 0, "GetOwner")
    eq(c:GetTeam(), 0, "GetTeam")
    eq(c:Plot(), w:getPlot(10, 5), "Plot")
    eq(c:GetNumCityPlots(), 3, "GetNumCityPlots")
    eq(c:GetCityIndexPlot(2), w:getPlot(10, 6), "GetCityIndexPlot")
    isNil(c:GetCityIndexPlot(3), "GetCityIndexPlot 越界")
    eq(c:GetGarrisonedUnit(), u, "GetGarrisonedUnit")
    eq(c:GetOrderQueueLength(), 2, "GetOrderQueueLength")
    truthy(c:IsProduction(), "IsProduction")
    falsy(c:IsProductionProcess(), "IsProductionProcess")
    eq(c:GetProductionTurnsLeft(), 4, "GetProductionTurnsLeft")
    eq(c:GetProductionNameKey(), "TXT_KEY_BUILDING_GRANARY", "GetProductionNameKey")
    eq(c:GetYieldRate(YieldTypes.YIELD_FOOD), 8, "GetYieldRate(FOOD)")
    eq(c:GetYieldRate(YieldTypes.YIELD_PRODUCTION), 6, "GetYieldRate(PRODUCTION)")
    eq(c:GetYieldRate(YieldTypes.YIELD_GOLD), 5, "GetYieldRate(GOLD)")
    eq(c:GetYieldRate(YieldTypes.YIELD_SCIENCE), 4, "GetYieldRate(SCIENCE)")
    eq(c:GetYieldRate(YieldTypes.YIELD_CULTURE), 1, "GetYieldRate(CULTURE)")
    eq(c:GetYieldRate(YieldTypes.YIELD_FAITH), 2, "GetYieldRate(FAITH)")
    eq(c:GetProductionModifier(), 25, "GetProductionModifier")
    eq(c:FoodDifference(), 3, "FoodDifference")
    eq(c:GetJONSCulturePerTurn(), 2, "GetJONSCulturePerTurn")
    eq(c:GetFaithPerTurn(), 1, "GetFaithPerTurn")
    eq(c:GetFood(), 12, "GetFood")
    eq(c:GrowthThreshold(), 30, "GrowthThreshold")
    eq(c:GetFoodTurnsLeft(), 6, "GetFoodTurnsLeft")
    falsy(c:IsFoodProduction(), "IsFoodProduction")
    eq(c:FoodDifferenceTimes100(), 300, "FoodDifferenceTimes100 默认是净粮的 100 倍")
    eq(c:GetNumRealBuilding(3), 1, "GetNumRealBuilding")
    eq(c:GetNumRealBuilding(0), 2, "GetNumRealBuilding")
    eq(c:GetNumRealBuilding(1), 0, "没有的建筑是 0")

    -- 购买：官方双层判定。(false, false, …) 查规则，(true, true, …) 查现在的余额
    truthy(c:IsCanPurchase(false, false, 1, -1, -1, YieldTypes.YIELD_GOLD), "规则上可用金币买")
    truthy(c:IsCanPurchase(true, true, 1, -1, -1, YieldTypes.YIELD_FAITH), "现在可用信仰买")
    falsy(c:IsCanPurchase(true, true, 1, -1, -1, YieldTypes.YIELD_GOLD), "规则上可买但现在买不起")
    falsy(c:IsCanPurchase(false, false, -1, 2, -1, YieldTypes.YIELD_FAITH), "规则上不可用信仰买")
    truthy(c:IsCanPurchase(false, false, -1, 2, -1, YieldTypes.YIELD_GOLD), "规则上可用金币买")
    falsy(c:IsCanPurchase(false, false, 9, -1, -1, YieldTypes.YIELD_GOLD), "没配置的可买项是假")
    eq(c:GetUnitPurchaseCost(1), 500, "GetUnitPurchaseCost")
    eq(c:GetUnitFaithPurchaseCost(1, true), 300, "GetUnitFaithPurchaseCost")
    eq(c:GetBuildingPurchaseCost(2), 200, "GetBuildingPurchaseCost")
    eq(c:GetBuildingFaithPurchaseCost(2), 0, "GetBuildingFaithPurchaseCost")

    -- 买地与炮击
    truthy(c:CanBuyPlotAt(11, 5, true), "CanBuyPlotAt 忽略金币")
    truthy(c:CanBuyPlotAt(11, 5, false), "CanBuyPlotAt 含金币")
    truthy(c:CanBuyPlotAt(10, 6, true), "规则上可买")
    falsy(c:CanBuyPlotAt(10, 6, false), "规则上可买但现在买不起")
    falsy(c:CanBuyPlotAt(12, 5, true), "不可买的地块")
    eq(c:GetBuyPlotCost(11, 5), 60, "GetBuyPlotCost")
    eq(c:GetBuyPlotCost(12, 5), 0, "没配置价格的地块是 0")
    truthy(c:CanRangeStrike(), "CanRangeStrike")
    truthy(c:CanRangeStrikeNow(), "CanRangeStrikeNow")
    truthy(c:CanRangeStrikeAt(11, 6, true, true), "CanRangeStrikeAt")
    eq(GameDefines.BUY_PLOTS_DISABLED, 1, "gameDefines 覆盖项")

    -- 玩家
    eq(p:GetTeam(), 0, "GetTeam")
    truthy(p:IsTurnActive(), "IsTurnActive")
    truthy(p:IsAlive(), "IsAlive")
    falsy(p:IsMinorCiv(), "IsMinorCiv")
    falsy(p:IsBarbarian(), "IsBarbarian")
    eq(p:GetName(), "Augustus", "GetName")
    eq(p:GetCivilizationShortDescription(), "Rome", "GetCivilizationShortDescription")
    eq(p:GetGold(), 150, "GetGold")
    eq(p:CalculateGoldRate(), 7, "CalculateGoldRate")
    eq(p:GetScience(), 12, "GetScience")
    eq(p:GetTotalJONSCulturePerTurn(), 5, "GetTotalJONSCulturePerTurn")
    eq(p:GetFaith(), 40, "GetFaith")
    eq(p:GetTotalFaithPerTurn(), 3, "GetTotalFaithPerTurn")
    eq(p:GetExcessHappiness(), 9, "GetExcessHappiness")
    truthy(p:IsGoldenAge(), "IsGoldenAge")
    eq(p:GetNumResourceAvailable(0, true), 4, "GetNumResourceAvailable")
    eq(p:GetNumResourceAvailable(1, true), 0, "可用量为 0")
    eq(p:GetNumResourceAvailable(9, true), 0, "没配置的资源是 0")
    eq(p:GetNumResourceTotal(0, true), 6, "GetNumResourceTotal")
    eq(p:GetNumResourceTotal(1, true), 0, "没配置的资源是 0")
    eq(p:GetUnitByID(1), warrior, "GetUnitByID")
    eq(p:GetCityByID(0), c, "GetCityByID")
    isNil(p:GetUnitByID(99), "GetUnitByID 找不到")
    local unitCount = 0
    for _ in p:Units() do unitCount = unitCount + 1 end
    eq(unitCount, 3, "Units 迭代器")
    local cityCount = 0
    for _ in p:Cities() do cityCount = cityCount + 1 end
    eq(cityCount, 1, "Cities 迭代器")
    eq(p:GetFirstReadyUnit(), warrior, "GetFirstReadyUnit 返回第一个可行动的单位")
    eq(w:unit(0, 0), u, "w:unit")
    eq(w:city(0, 0), c, "w:city")

    -- 回合阻塞与通知：GetNotificationIndex(i) 的参数是列表下标，返回的是通知编号
    -- （ActionInfoPanel.lua:399-403）
    local q = Players[1]
    falsy(q:IsTurnActive(), "turnActive 为假")
    eq(q:GetEndTurnBlockingType(), EndTurnBlockingTypes.ENDTURN_BLOCKING_PRODUCTION, "GetEndTurnBlockingType")
    eq(q:GetEndTurnBlockingNotificationIndex(), 7, "GetEndTurnBlockingNotificationIndex")
    eq(q:GetNumNotifications(), 2, "GetNumNotifications")
    eq(q:GetNotificationIndex(1), 7, "GetNotificationIndex")
    eq(q:GetNotificationSummaryStr(1), "Need production", "GetNotificationSummaryStr")
    eq(q:GetNotificationStr(1), "Pick something", "GetNotificationStr")
end)

-- -----------------------------------------------------------------------------
-- 第 4 节：运行器
-- -----------------------------------------------------------------------------

-- 失败信息里最多附带多少行被测代码的 print 输出
local PRINT_LINES_LIMIT = 30

-- -----------------------------------------------------------------------------
-- 函数：runOne(case)
-- 做什么：执行一条用例并核对用例边界。
--     顺序：beginCase → 执行用例 → endCase。用例本身通过、但边界核对不通过的，也算失败。
--     失败信息后面附带被测代码的 print 输出，便于定位。
-- 输入：case，{ id, title, fn }。
-- 输出：状态（"pass"、"fail" 或 "skip"）与说明。
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
            lines[#lines + 1] = "…（共 " .. #S.prints .. " 行，只显示前 " .. PRINT_LINES_LIMIT .. " 行）"
        end
        message = message .. "\n—— 被测代码的 print 输出 ——\n" .. table.concat(lines, "\n")
    end
    return status, message
end

-- -----------------------------------------------------------------------------
-- 函数：runAll()
-- 做什么：按注册顺序执行全部用例，汇总结果；最后做一次只读守卫的总量检查。
--     每条用例结束时已经核对过“本条用例期间没有违规”，这里是跨用例的兜底：
--     守卫记录的总量必须为零，否则追加一条框架级失败。
-- 输出：汇总表 { passed, failed, skipped, guardViolations, guardMissing, cases = { {id, status, title, message}, … } }。
-- -----------------------------------------------------------------------------
local function runAll()
    local summary = { passed = 0, failed = 0, skipped = 0, cases = {} }
    local counter = { pass = "passed", fail = "failed", skip = "skipped" }
    for _, case in ipairs(cases) do
        local status, message = runOne(case)
        summary[counter[status]] = summary[counter[status]] + 1
        summary.cases[#summary.cases + 1] = {
            id = case.id, status = status, title = case.title, message = message,
        }
    end

    summary.guardViolations = #S.guard.violations
    summary.guardMissing = #S.guard.missing
    if summary.guardViolations > 0 or summary.guardMissing > 0 then
        local parts = {}
        for _, record in ipairs(S.guard.violations) do
            parts[#parts + 1] = "写入类调用：" .. record.owner .. "." .. record.method .. "()"
        end
        for _, record in ipairs(S.guard.missing) do
            parts[#parts + 1] = "桩未实现的方法：" .. record.owner .. "." .. record.method .. "()"
        end
        summary.failed = summary.failed + 1
        summary.cases[#summary.cases + 1] = {
            id = "FW-01",
            status = "fail",
            title = "只读守卫的累计记录不为零（框架收尾检查）",
            message = table.concat(parts, "\n"),
        }
    end
    return summary
end

return runAll()
