-- =============================================================================
-- 文件：mod/Lua/CAB_InfoCollector.lua
-- 职责：模块 1（游戏端纯 Lua 桥接 Mod）——子模块 1：游戏内信息收集子模块（CAB_Collector）。
--       作为严格只读传感器，将《文明5：BNW v1.0.3.279》引擎导出的 Player / Team /
--       Unit / City / Plot 状态转换为可 JSON 序列化的结构化纯 Lua DTO 表。
--
-- 依赖：仅允许 include("CAB_Config") 一次；零外部 Mod 依赖，零 JSON 编码器依赖。
-- 对外契约：
--   * 仅导出唯一全局变量 CAB_Collector，全部内部辅助工具均声明为 local；
--   * 7 个纯只读复用辅助函数（供本子模块与 CAB_TaskExecutor 复用，决策 D-03）：
--       SerializeUnitSummary / SerializeEnemyUnit / SerializeCitySummary /
--       InspectPlotUnits / CanUnitMoveThrough / HasSameClassFriendlyUnit /
--       FindGameActionIndex
--   * 基础域查询主接口（WP-2）：
--       GetEmpireEconomy / GetVisibilitySummary / CaptureRevealedPlotsSet /
--       GetEndTurnStatus
--   * 聚合与战术查询主接口（WP-3）：
--       BuildTurnOverview / BuildUnitContextAndCandidates
--   * 深度城市查询主接口（WP-4）：
--       GetCityDetail
--   * 三大回合硬阻塞选项查询主接口（M1Sub3 WP5 / D-08 增量扩充）：
--       GetResearchOptions / GetPolicyOptions / GetUnitPromotions
--
-- 架构红线与引擎依据（《docs/M1/M1Sub1/M1Sub1工作计划.md》§2 & §4）：
--   1. 纯只读零写入（A-03）：严禁调用任何修改游戏状态、经济、领土或单位指令的接口；
--   2. 战争迷雾与防侧信道（D-04 / F-01 ~ F-06）：敌军须 IsVisible 且 not IsInvisible；
--      已探索非可见敌城标 in_fog = true；未探索黑雾格绝不泄露任何实体或地形；
--   3. 原生 BNW 与 IGE 兼容（D-05）：零跨调用可变缓存，每次实时读取引擎与 GameDefines，
--      过滤 nil / IsDead / IsDelayedDeath 与死玩家/空玩家槽位；
--   4. DTO 与异常约定（D-06）：对象表均带 __is_object = true，可空字段省略（留 Lua nil），
--      非法入参统一返回结构化错误表，绝不抛未捕获 Lua 异常。
-- =============================================================================

include("CAB_Config")

CAB_Collector = {}

-- -----------------------------------------------------------------------------
-- 第 1 节：内部只读基础工具（全部声明为 local，零状态缓存）
-- -----------------------------------------------------------------------------

-- 官方 ActionInfoPanel.lua 中 24 种回合结束阻塞枚举的确定性名称清单
local ENDTURN_BLOCKING_ENUM_NAMES = {
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

-- -----------------------------------------------------------------------------
-- 函数：makeErrorDto(errMsg)
-- 做什么：构造统一格式的结构化错误返回表（带 __is_object = true）。
-- 为什么：遵循决策 D-06，非法入参时不抛 Lua 异常，由调用方安全识别 error 字段。
-- 输入：errMsg（英文错误说明字符串）。
-- 输出：{ __is_object = true, error = string }。
-- -----------------------------------------------------------------------------
local function makeErrorDto(errMsg)
    return {
        __is_object = true,
        error = tostring(errMsg),
    }
end

-- -----------------------------------------------------------------------------
-- 函数：isInteger(v)
-- 做什么：判断给定值是否为有限整数。
-- 为什么：拦截非数字、小数或 NaN 传入 Players[id] / Map.GetPlot(x, y) 导致未定义行为。
-- 输入：v（任意 Lua 值）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
local function isInteger(v)
    return type(v) == "number" and v == v and v == math.floor(v)
end

-- -----------------------------------------------------------------------------
-- 函数：trunc2(val)
-- 做什么：将浮点数保留两位小数向下截断，加入 1e-6 补偿抵消二进制浮点表示误差。
-- 为什么：对齐计划 §2.4 数值规范化约定，防止如 1.00 因 0.99999999 被截为 0.99。
-- 输入：val（数值）。
-- 输出：保留两位小数的数值。
-- -----------------------------------------------------------------------------
local function trunc2(val)
    return math.floor((val or 0) * 100 + 1e-6) / 100
end

-- -----------------------------------------------------------------------------
-- 函数：getMoveDenominator() / getMaxUnitHp(pUnit) / getMaxCityHp(pCity) / getMaxPlayers()
-- 做什么：实时读取 GameDefines 与对象上限常量，不在模块顶层缓存。
-- 为什么：遵循 D-05 零跨调用缓存原则，兼容自定义规则与测试桩动态覆盖 GameDefines。
-- 输入：可选的单位/城市对象。
-- 输出：正整数常量。
-- -----------------------------------------------------------------------------
local function getMoveDenominator()
    local denom = GameDefines and GameDefines.MOVE_DENOMINATOR
    if type(denom) == "number" and denom > 0 then
        return denom
    end
    return 60
end

local function getMaxUnitHp(pUnit)
    if pUnit ~= nil and pUnit.GetMaxHitPoints ~= nil then
        local ok, maxHp = pcall(function() return pUnit:GetMaxHitPoints() end)
        if ok and type(maxHp) == "number" and maxHp > 0 then
            return maxHp
        end
    end
    local defHp = GameDefines and GameDefines.MAX_HIT_POINTS
    if type(defHp) == "number" and defHp > 0 then
        return defHp
    end
    return 100
end

local function getMaxCityHp(pCity)
    if pCity ~= nil and pCity.GetMaxHitPoints ~= nil then
        local ok, maxHp = pcall(function() return pCity:GetMaxHitPoints() end)
        if ok and type(maxHp) == "number" and maxHp > 0 then
            return maxHp
        end
    end
    local defHp = GameDefines and GameDefines.MAX_CITY_HIT_POINTS
    if type(defHp) == "number" and defHp > 0 then
        return defHp
    end
    return 200
end

local function getMaxPlayers()
    local maxP = GameDefines and GameDefines.MAX_PLAYERS
    if type(maxP) == "number" and maxP > 0 then
        return maxP
    end
    return 64
end

local function getCityAttackRange()
    local rng = GameDefines and GameDefines.CITY_ATTACK_RANGE
    if type(rng) == "number" and rng > 0 then
        return math.floor(rng)
    end
    return 2
end

-- -----------------------------------------------------------------------------
-- 函数：safeLocale(textKey)
-- 做什么：通过 Locale.ConvertTextKey 安全转换本地化键；空值或空串返回空串。
-- 为什么：避免单位/城市生产名键缺失时直接传 nil 触发引擎本地化报错。
-- 输入：textKey（字符串或 nil）。
-- 输出：本地化后的字符串。
-- -----------------------------------------------------------------------------
local function safeLocale(textKey)
    if textKey == nil or textKey == "" then
        return ""
    end
    if Locale ~= nil and Locale.ConvertTextKey ~= nil then
        local ok, text = pcall(Locale.ConvertTextKey, textKey)
        if ok and text ~= nil then
            return tostring(text)
        end
    end
    return tostring(textKey)
end

-- -----------------------------------------------------------------------------
-- 函数：isValidAlivePlayer(playerID)
-- 做什么：校验 playerID 为有效整数且对应 Players[playerID] 存在并处于存活态。
-- 为什么：兼容原生 BNW 与 IGE 中 Players[i] 的三种槽位形态（存活/死玩家/nil），
--         为全部主查询接口提供一致的入参守卫。
-- 输入：playerID（玩家编号）。
-- 输出：(pPlayer, nil) 或 (nil, errMsg)。
-- -----------------------------------------------------------------------------
local function isValidAlivePlayer(playerID)
    if not isInteger(playerID) then
        return nil, "Invalid player ID: " .. tostring(playerID)
    end
    if Players == nil then
        return nil, "Players table unavailable"
    end
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        return nil, "Player not found: " .. tostring(playerID)
    end
    if not pPlayer:IsAlive() then
        return nil, "Player is not alive: " .. tostring(playerID)
    end
    return pPlayer, nil
end

-- -----------------------------------------------------------------------------
-- 函数：isUnitAlive(pUnit)
-- 做什么：判定单位对象非空、未阵亡且未处于延迟死亡态。
-- 为什么：战斗结算帧及 IGE 删兵瞬间可能出现 IsDelayedDeath() 为真的幽灵单位，
--         必须在所有单位序列化与遍历入口统一过滤（§2.3）。
-- 输入：pUnit（Unit 对象或 nil）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
local function isUnitAlive(pUnit)
    if pUnit == nil then
        return false
    end
    if pUnit:IsDead() then
        return false
    end
    if pUnit.IsDelayedDeath ~= nil then
        local ok, delayed = pcall(function() return pUnit:IsDelayedDeath() end)
        if ok and delayed == true then
            return false
        end
    end
    return true
end

-- -----------------------------------------------------------------------------
-- 函数：resolveUnitTypeStr(unitTypeId)
-- 做什么：根据单位类型整数 ID 查表返回 GameInfo.Units 中的 Type 字符串。
-- 为什么：对越界或自定义 Mod 未知单位 ID 做空表防护，避免索引 nil 崩溃。
-- 输入：unitTypeId（整数 ID）。
-- 输出：Type 字符串（回退为 tostring(unitTypeId)）。
-- -----------------------------------------------------------------------------
local function resolveUnitTypeStr(unitTypeId)
    if GameInfo ~= nil and GameInfo.Units ~= nil and unitTypeId ~= nil then
        local row = GameInfo.Units[unitTypeId]
        if row ~= nil and row.Type ~= nil then
            return row.Type
        end
    end
    return tostring(unitTypeId)
end

-- -----------------------------------------------------------------------------
-- 函数：resolveBlockingTypeName(blockingTypeId)
-- 做什么：将引擎 GetEndTurnBlockingType() 返回的整数枚举映射为可读名称。
-- 为什么：覆盖官方 ActionInfoPanel.lua 全部 24 种阻塞枚举并将无阻塞（-1）统一为
--         "NO_BLOCKING"，且按固定顺序匹配保证结果确定性。
-- 输入：blockingTypeId（整数或 nil）。
-- 输出：枚举名称字符串。
-- -----------------------------------------------------------------------------
local function resolveBlockingTypeName(blockingTypeId)
    local noBlockingId = (EndTurnBlockingTypes and EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE) or -1
    if blockingTypeId == nil or blockingTypeId == noBlockingId or blockingTypeId < 0 then
        return "NO_BLOCKING"
    end
    if EndTurnBlockingTypes ~= nil then
        for _, enumName in ipairs(ENDTURN_BLOCKING_ENUM_NAMES) do
            if EndTurnBlockingTypes[enumName] == blockingTypeId then
                return enumName
            end
        end
        for enumName, enumVal in pairs(EndTurnBlockingTypes) do
            if enumName ~= "NO_ENDTURN_BLOCKING_TYPE" and enumVal == blockingTypeId then
                return enumName
            end
        end
    end
    return "UNKNOWN_BLOCKING_" .. tostring(blockingTypeId)
end

-- -----------------------------------------------------------------------------
-- 函数：resolveRowType(infoTable, rowId)
-- 做什么：安全读取 GameInfo 某张表（Terrains/Features/Improvements 等）指定 ID 行的 Type 字符串。
-- 为什么：引擎 GameInfo 视图对越界或负数 ID 返回空表 {} 而非 nil，需同时判非空与 row.Type 存在。
-- 输入：infoTable（GameInfo 子表视图）、rowId（整数 ID 或 nil）。
-- 输出：Type 字符串，或无效时返回 nil。
-- -----------------------------------------------------------------------------
local function resolveRowType(infoTable, rowId)
    if infoTable == nil or type(rowId) ~= "number" or rowId < 0 then
        return nil
    end
    local row = infoTable[rowId]
    if row ~= nil and row.Type ~= nil and row.Type ~= "" then
        return row.Type
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- 函数：isTeamAtWarWithPlayer(pActiveTeam, otherPlayerID)
-- 做什么：安全判断指定己方队伍是否与目标玩家处于交战状态。
-- 为什么：兼容 Players[otherPlayerID] 为 nil、死玩家或队伍 ID 为负的边缘槽位（D-05）。
-- 输入：pActiveTeam（己方 Team 对象或 nil）、otherPlayerID（目标玩家 ID）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
local function isTeamAtWarWithPlayer(pActiveTeam, otherPlayerID)
    if pActiveTeam == nil or not isInteger(otherPlayerID) or Players == nil then
        return false
    end
    local pOther = Players[otherPlayerID]
    if pOther == nil then
        return false
    end
    local otherTeam = pOther:GetTeam()
    if type(otherTeam) ~= "number" or otherTeam < 0 then
        return false
    end
    return pActiveTeam:IsAtWar(otherTeam) == true
end

-- -----------------------------------------------------------------------------
-- 第 2 节：7 个公开纯只读复用辅助函数（H1 ~ H7，供 CAB_TaskExecutor 复用）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.SerializeUnitSummary(pUnit)  [H1]
-- 做什么：将存活的己方单位序列化为标准 UnitSummaryDTO（100% 对齐《03》§2.1）。
-- 为什么：同时检查 MovesLeft() > 0 与 IsReadyToMove() == true 判定 can_act，
--         准确排除已跳过或已驻扎但仍保留剩余移动力的单位（ActionInfoPanel.lua 避坑）。
-- 输入：pUnit（Unit 对象）。
-- 输出：UnitSummaryDTO 表（带 __is_object = true），或当单位无效/已死/延迟死时返回 nil。
-- -----------------------------------------------------------------------------
function CAB_Collector.SerializeUnitSummary(pUnit)
    if not isUnitAlive(pUnit) then
        return nil
    end

    local unitTypeStr = resolveUnitTypeStr(pUnit:GetUnitType())
    local domainStr = "LAND"
    local dType = pUnit:GetDomainType()
    if DomainTypes ~= nil then
        if dType == DomainTypes.DOMAIN_AIR then
            domainStr = "AIR"
        elseif dType == DomainTypes.DOMAIN_SEA then
            domainStr = "SEA"
        end
    end

    local maxHp = getMaxUnitHp(pUnit)
    local damage = pUnit:GetDamage() or 0
    local hp = math.max(0, maxHp - damage)

    local denom = getMoveDenominator()
    local rawMovesLeft = pUnit:MovesLeft() or 0
    local rawMaxMoves = pUnit:MaxMoves() or 0
    local movesLeft = trunc2(rawMovesLeft / denom)
    local maxMoves = trunc2(rawMaxMoves / denom)

    local isFortified = false
    if pUnit.GetFortifyTurns ~= nil then
        local okFort, fortTurns = pcall(function() return pUnit:GetFortifyTurns() end)
        if okFort and (fortTurns or 0) > 0 then
            isFortified = true
        end
    end

    local canAct = rawMovesLeft > 0
    if canAct and pUnit.IsReadyToMove ~= nil then
        local okReady, isReady = pcall(function() return pUnit:IsReadyToMove() end)
        if okReady then
            canAct = (isReady == true)
        end
    end

    return {
        __is_object = true,
        unit_id = pUnit:GetID(),
        name = safeLocale(pUnit:GetName()),
        unit_type = unitTypeStr,
        domain = domainStr,
        x = pUnit:GetX(),
        y = pUnit:GetY(),
        hp = hp,
        max_hp = maxHp,
        moves_left = movesLeft,
        max_moves = maxMoves,
        combat_str = pUnit:GetBaseCombatStrength() or 0,
        ranged_str = pUnit:GetBaseRangedCombatStrength() or 0,
        range = pUnit:Range() or 0,
        is_fortified = isFortified,
        can_act = canAct,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.SerializeEnemyUnit(pEnemyUnit)  [H2]
-- 做什么：将可见的敌方/蛮族存活单位序列化为标准 EnemyUnitDTO。
-- 为什么：使用 "<ownerID>:<unitID>" 复合 enemy_id，避免不同文明间单位 ID 碰撞导致
--         战后增量对比（Delta Observation）错配。
-- 输入：pEnemyUnit（敌方/蛮族 Unit 对象）。
-- 输出：EnemyUnitDTO 表（带 __is_object = true），或单位无效/已死/延迟死时返回 nil。
-- -----------------------------------------------------------------------------
function CAB_Collector.SerializeEnemyUnit(pEnemyUnit)
    if not isUnitAlive(pEnemyUnit) then
        return nil
    end

    local ownerID = pEnemyUnit:GetOwner()
    local pOwner = Players and Players[ownerID] or nil
    local unitTypeStr = resolveUnitTypeStr(pEnemyUnit:GetUnitType())
    local maxHp = getMaxUnitHp(pEnemyUnit)
    local damage = pEnemyUnit:GetDamage() or 0
    local hp = math.max(0, maxHp - damage)

    local ownerName = (pOwner and pOwner:GetName()) or "Unknown"
    if ownerName == "" then
        ownerName = "Unknown"
    end

    return {
        __is_object = true,
        enemy_id = tostring(ownerID) .. ":" .. tostring(pEnemyUnit:GetID()),
        owner_id = ownerID,
        owner_name = ownerName,
        is_barbarian = (pOwner ~= nil and pOwner:IsBarbarian() == true) or false,
        unit_type = unitTypeStr,
        x = pEnemyUnit:GetX(),
        y = pEnemyUnit:GetY(),
        hp = hp,
        combat_str = pEnemyUnit:GetBaseCombatStrength() or 0,
        ranged_str = pEnemyUnit:GetBaseRangedCombatStrength() or 0,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.SerializeCitySummary(pCity)  [H3]
-- 做什么：将己方城市序列化为标准 CitySummaryDTO（含产出概要与城防反击就绪标记）。
-- 为什么：供 BuildTurnOverview 与后续任务执行层购买/切换生产后的城市快照复用，
--         保持字段结构与《03》§2.1 及《模块内部接口设计.md》§4.4 完全一致。
-- 输入：pCity（City 对象）。
-- 输出：CitySummaryDTO 表（带 __is_object = true），或 pCity 为 nil 时返回 nil。
-- -----------------------------------------------------------------------------
function CAB_Collector.SerializeCitySummary(pCity)
    if pCity == nil then
        return nil
    end

    local maxHp = getMaxCityHp(pCity)
    local damage = pCity:GetDamage() or 0
    local hp = math.max(0, maxHp - damage)

    local prodKey = pCity:GetProductionNameKey()
    local currentProd = "NONE"
    if prodKey ~= nil and prodKey ~= "" then
        currentProd = safeLocale(prodKey)
    end
    local turnsLeft = pCity:GetProductionTurnsLeft() or 0

    local canRangeStrike = false
    if pCity.CanRangeStrikeNow ~= nil then
        local okStrike, canStrike = pcall(function() return pCity:CanRangeStrikeNow() end)
        if okStrike and canStrike == true then
            canRangeStrike = true
        end
    end

    local yields = {
        __is_object = true,
        food = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_FOOD)) or 0,
        food_net = pCity:FoodDifference() or 0,
        production = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_PRODUCTION)) or 0,
        gold = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_GOLD)) or 0,
        science = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_SCIENCE)) or 0,
        culture = pCity:GetJONSCulturePerTurn() or 0,
        faith = pCity:GetFaithPerTurn() or 0,
    }

    return {
        __is_object = true,
        city_id = pCity:GetID(),
        name = pCity:GetName() or "",
        x = pCity:GetX(),
        y = pCity:GetY(),
        pop = pCity:GetPopulation() or 0,
        hp = hp,
        max_hp = maxHp,
        current_production = currentProd,
        turns_left = turnsLeft,
        yields = yields,
        can_range_strike = canRangeStrike,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.InspectPlotUnits(pPlot, activePlayerID)  [H4]
-- 做什么：扫描可见地块上的存活单位，分别提取最具代表性的己方 unit_id 与敌方 EnemyUnitDTO。
-- 为什么：
--   1. 军民同格叠栈时优先保留主战单位（IsCombatUnit() == true），防止工人/大将军覆盖主战兵力；
--   2. 严格执行红线 F-02：对非己方单位强制调用 IsInvisible(activeTeam, false) 过滤隐形敌军。
-- 输入：pPlot（Plot 对象）、activePlayerID（当前玩家 ID）。
-- 输出：(friendlyId: number | nil, enemyDto: table | nil)。
-- -----------------------------------------------------------------------------
function CAB_Collector.InspectPlotUnits(pPlot, activePlayerID)
    if pPlot == nil then
        return nil, nil
    end

    local activeTeam = nil
    if isInteger(activePlayerID) and Players ~= nil and Players[activePlayerID] ~= nil then
        activeTeam = Players[activePlayerID]:GetTeam()
    end

    local friendlyId = nil
    local friendlyCombat = false
    local enemyDto = nil
    local enemyCombat = false

    local numUnits = pPlot:GetNumUnits() or 0
    for i = 0, numUnits - 1 do
        local pPlotUnit = pPlot:GetUnit(i)
        if isUnitAlive(pPlotUnit) then
            local isCombat = (pPlotUnit.IsCombatUnit ~= nil and pPlotUnit:IsCombatUnit() == true) or false
            if pPlotUnit:GetOwner() == activePlayerID then
                if friendlyId == nil or (isCombat and not friendlyCombat) then
                    friendlyId = pPlotUnit:GetID()
                    friendlyCombat = isCombat
                end
            else
                -- F-02 红线：即使地块实时可见，对己方队伍隐形的敌军单位严禁导出
                local isInvisible = false
                if activeTeam ~= nil and pPlotUnit.IsInvisible ~= nil then
                    local okInv, invRes = pcall(function() return pPlotUnit:IsInvisible(activeTeam, false) end)
                    if okInv and invRes == true then
                        isInvisible = true
                    end
                end
                if not isInvisible then
                    if enemyDto == nil or (isCombat and not enemyCombat) then
                        local dto = CAB_Collector.SerializeEnemyUnit(pPlotUnit)
                        if dto ~= nil then
                            enemyDto = dto
                            enemyCombat = isCombat
                        end
                    end
                end
            end
        end
    end

    return friendlyId, enemyDto
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.CanUnitMoveThrough(pUnit, pPlot)  [H5]
-- 做什么：通过 pcall 安全调用引擎原生 pUnit:CanMoveThrough(pPlot) 判定单位能否进入目标格。
-- 为什么：原版 BNW CvGameCore_Expansion2.dll 的移动攻击组合查询接口存在恒假缺陷，
--         必须统一经 CanMoveThrough 搭配 1UPT 停靠校验替代（红线 A-05）。
-- 输入：pUnit（Unit 对象）、pPlot（Plot 对象）。
-- 输出：布尔值（参数无效或调用失败时安全返回 false）。
-- -----------------------------------------------------------------------------
function CAB_Collector.CanUnitMoveThrough(pUnit, pPlot)
    if not isUnitAlive(pUnit) or pPlot == nil then
        return false
    end
    local ok, res = pcall(function() return pUnit:CanMoveThrough(pPlot) end)
    if ok then
        return res == true
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.HasSameClassFriendlyUnit(pPlot, activePlayerID, isSelfCombat)  [H6]
-- 做什么：检查目标地块是否已存在同类别（同为战斗单位或同为民用单位）的己方存活单位。
-- 为什么：配合 CanUnitMoveThrough 准确实施 1UPT 停靠规则（军民可叠栈、同类别不可停靠）。
-- 输入：pPlot（Plot 对象）、activePlayerID（玩家 ID）、isSelfCombat（boolean，待移动单位是否为战斗单位）。
-- 输出：布尔值。
-- -----------------------------------------------------------------------------
function CAB_Collector.HasSameClassFriendlyUnit(pPlot, activePlayerID, isSelfCombat)
    if pPlot == nil or not isInteger(activePlayerID) then
        return false
    end
    local targetCombat = (isSelfCombat == true)
    local numUnits = pPlot:GetNumUnits() or 0
    for i = 0, numUnits - 1 do
        local pOther = pPlot:GetUnit(i)
        if isUnitAlive(pOther) and pOther:GetOwner() == activePlayerID then
            local otherCombat = (pOther.IsCombatUnit ~= nil and pOther:IsCombatUnit() == true) or false
            if otherCombat == targetCombat then
                return true
            end
        end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.FindGameActionIndex(actionTypeStr)  [H7]
-- 做什么：遍历 GameInfoActions（0 .. #GameInfoActions），查找当前选中单位可合法执行的动作索引。
-- 为什么：与官方 UnitPanel.lua:202-206 判定口径保持 100% 一致，同时校验
--         Game.CanHandleAction(iAction, 0, 1) 与 Game.CanHandleAction(iAction)。
-- 输入：actionTypeStr（动作 Type 字符串，如 "MISSION_FORTIFY"）。
-- 输出：整数动作索引 iAction，若不存在或当前选中单位不可执行则返回 nil。
-- -----------------------------------------------------------------------------
function CAB_Collector.FindGameActionIndex(actionTypeStr)
    if type(actionTypeStr) ~= "string" or actionTypeStr == "" then
        return nil
    end
    if GameInfoActions == nil or Game == nil or Game.CanHandleAction == nil then
        return nil
    end
    for iAction = 0, #GameInfoActions do
        local action = GameInfoActions[iAction]
        if action ~= nil and action.Type == actionTypeStr then
            if Game.CanHandleAction(iAction, 0, 1) and Game.CanHandleAction(iAction) then
                return iAction
            end
        end
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- 第 3 节：4 个基础域主查询接口（WP-2，对应《模块内部接口设计.md》§4.1 ~ §4.3）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetEmpireEconomy(activePlayerID)  [F1]
-- 做什么：采集当前存活玩家的国库金币、回合金、科研、文化、信仰、快乐度、黄金时代态，
--         以及可用储量 > 0 的战略资源与奢侈资源明细字典。
-- 为什么：严格按 Game.GetResourceUsageType 区分战略/奢侈/加成资源，跳过加成资源与零储量条目，
--         并实时读取引擎最新值以兼容 IGE 即时修改金币/资源。
-- 输入：activePlayerID（玩家 ID）。
-- 输出：EconomyDTO 表（带 __is_object = true）；非法/非存活玩家返回 { __is_object = true, error = "..." }。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetEmpireEconomy(activePlayerID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end

    local strategicResources = { __is_object = true }
    local luxuryResources = { __is_object = true }

    if GameInfo ~= nil and GameInfo.Resources ~= nil and ResourceUsageTypes ~= nil then
        for res in GameInfo.Resources() do
            if res ~= nil and res.ID ~= nil and res.Type ~= nil then
                local okUsage, iUsage = pcall(Game.GetResourceUsageType, res.ID)
                if okUsage then
                    if iUsage == ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then
                        local avail = pPlayer:GetNumResourceAvailable(res.ID, true) or 0
                        if avail > 0 then
                            strategicResources[res.Type] = avail
                        end
                    elseif iUsage == ResourceUsageTypes.RESOURCEUSAGE_LUXURY then
                        local avail = pPlayer:GetNumResourceAvailable(res.ID, true) or 0
                        if avail > 0 then
                            luxuryResources[res.Type] = avail
                        end
                    end
                end
            end
        end
    end

    return {
        __is_object = true,
        gold = pPlayer:GetGold() or 0,
        gold_per_turn = pPlayer:CalculateGoldRate() or 0,
        science_per_turn = pPlayer:GetScience() or 0,
        culture_per_turn = pPlayer:GetTotalJONSCulturePerTurn() or 0,
        faith_per_turn = pPlayer:GetTotalFaithPerTurn() or 0,
        faith_total = pPlayer:GetFaith() or 0,
        happiness = pPlayer:GetExcessHappiness() or 0,
        is_golden_age = pPlayer:IsGoldenAge() == true,
        strategic_resources = strategicResources,
        luxury_resources = luxuryResources,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetVisibilitySummary(activePlayerID)  [F2]
-- 做什么：扫描全图所有非己方存活玩家的可见敌军单位与已探索非己方城市，同时返回
--         VisibilitySummaryDTO 与按 enemy_id 索引的字典 visibleEnemyMap。
-- 为什么：
--   * 严格执行迷雾红线 F-01（敌军必须所在格 IsVisible）、F-02（过滤 IsInvisible 隐形单位）、
--     F-04（已探索但不可见的敌城保留 hp/pop 并标 in_fog = true）、F-05（黑雾敌城完全隐藏）；
--   * 兼容 Players[i] 存活/死玩家/nil 三种槽位形态；
--   * 双返回值设计既满足对外查询 DTO，又供执行层 O(1) 对比战前/战后敌军增减。
-- 输入：activePlayerID（玩家 ID）。
-- 输出：(VisibilitySummaryDTO, visibleEnemyMap)；非法/非存活玩家返回
--       ({ __is_object = true, visible_enemies = {}, visible_enemy_cities = {}, error = "..." }, {})。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetVisibilitySummary(activePlayerID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return {
            __is_object = true,
            visible_enemies = {},
            visible_enemy_cities = {},
            error = errMsg,
        }, {}
    end

    local activeTeam = pPlayer:GetTeam()
    local pActiveTeam = (Teams ~= nil and activeTeam ~= nil and activeTeam >= 0) and Teams[activeTeam] or nil
    local maxPlayers = getMaxPlayers()

    local visibleEnemies = {}
    local visibleEnemyCities = {}
    local visibleEnemyMap = {}

    for iPlayer = 0, maxPlayers - 1 do
        if iPlayer ~= activePlayerID then
            local pOther = Players[iPlayer]
            if pOther ~= nil and pOther:IsAlive() then
                -- 1. 扫描实时可见且未对己方隐形的敌方/蛮族存活单位（F-01 / F-02）
                for pUnit in pOther:Units() do
                    if isUnitAlive(pUnit) then
                        local pPlot = pUnit:GetPlot()
                        if pPlot ~= nil and pPlot:IsVisible(activeTeam, false) == true then
                            local isInvisible = false
                            if pUnit.IsInvisible ~= nil then
                                local okInv, invRes = pcall(function() return pUnit:IsInvisible(activeTeam, false) end)
                                if okInv and invRes == true then
                                    isInvisible = true
                                end
                            end
                            if not isInvisible then
                                local dto = CAB_Collector.SerializeEnemyUnit(pUnit)
                                if dto ~= nil then
                                    table.insert(visibleEnemies, dto)
                                    visibleEnemyMap[dto.enemy_id] = dto
                                end
                            end
                        end
                    end
                end

                -- 2. 扫描已探索的非己方城市（F-04 迷雾敌城标 in_fog = true；F-05 黑雾敌城不导出）
                local otherTeam = pOther:GetTeam()
                local isAtWar = (
                    pActiveTeam ~= nil
                    and otherTeam ~= nil
                    and otherTeam >= 0
                    and pActiveTeam:IsAtWar(otherTeam) == true
                ) or false
                local ownerName = pOther:GetName() or "Unknown"
                if ownerName == "" then
                    ownerName = "Unknown"
                end
                local isMinorCiv = pOther:IsMinorCiv() == true

                for pCity in pOther:Cities() do
                    if pCity ~= nil then
                        local cPlot = pCity:Plot()
                        if cPlot ~= nil and cPlot:IsRevealed(activeTeam, false) == true then
                            local isVis = cPlot:IsVisible(activeTeam, false) == true
                            local maxHp = getMaxCityHp(pCity)
                            local damage = pCity:GetDamage() or 0
                            local hp = math.max(0, maxHp - damage)
                            table.insert(visibleEnemyCities, {
                                __is_object = true,
                                city_id = tostring(iPlayer) .. ":" .. tostring(pCity:GetID()),
                                owner_id = iPlayer,
                                owner_name = ownerName,
                                name = pCity:GetName() or "",
                                is_minor_civ = isMinorCiv,
                                is_at_war = isAtWar,
                                x = pCity:GetX(),
                                y = pCity:GetY(),
                                hp = hp,
                                pop = pCity:GetPopulation() or 0,
                                in_fog = not isVis,
                            })
                        end
                    end
                end
            end
        end
    end

    return {
        __is_object = true,
        visible_enemies = visibleEnemies,
        visible_enemy_cities = visibleEnemyCities,
    }, visibleEnemyMap
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.CaptureRevealedPlotsSet(activePlayerID, centerX, centerY, radius)  [F3]
-- 做什么：采集以 (centerX, centerY) 为中心、六边形半径 r 范围内所有已探索地块的坐标键集合。
-- 为什么：供动作前后差分统计新揭盲地块数（newly_revealed_tiles_count）；按决策 D-06 对外部
--         传入的 radius 钳制至 [0, CAB_Config.MAX_SCAN_RADIUS]，防止超大扫描范围卡死游戏。
-- 输入：activePlayerID（玩家 ID）、centerX / centerY（中心整数坐标）、radius（可选扫描半径）。
-- 输出：纯坐标集合表 { ["x:y"] = true, ... }（不带 __is_object）；非法入参或负半径安全返回 {}。
-- -----------------------------------------------------------------------------
function CAB_Collector.CaptureRevealedPlotsSet(activePlayerID, centerX, centerY, radius)
    local pPlayer = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return {}
    end
    if not isInteger(centerX) or not isInteger(centerY) then
        return {}
    end
    if Map == nil or Map.GetPlot(centerX, centerY) == nil then
        return {}
    end

    local defaultRadius = (CAB_Config and CAB_Config.DELTA_REVEAL_SCAN_RADIUS) or 5
    local maxRadius = (CAB_Config and CAB_Config.MAX_SCAN_RADIUS) or 8

    local r
    if radius == nil then
        r = defaultRadius
    else
        r = tonumber(radius)
        if r == nil or r ~= r or r < 0 then
            return {}
        end
    end
    r = math.floor(r)
    if r > maxRadius then
        r = maxRadius
    end

    local activeTeam = pPlayer:GetTeam()
    local revealedSet = {}

    for dx = -r, r do
        for dy = -r, r do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local px, py = pPlot:GetX(), pPlot:GetY()
                if Map.PlotDistance(centerX, centerY, px, py) <= r then
                    if pPlot:IsRevealed(activeTeam, false) == true then
                        revealedSet[tostring(px) .. ":" .. tostring(py)] = true
                    end
                end
            end
        end
    end

    return revealedSet
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetEndTurnStatus(activePlayerID)  [F4]
-- 做什么：诊断指定玩家当前是否处于活动回合、能否立即结束回合，并在存在阻塞时定位具体
--         阻塞类型名、关联单位/城市 ID 与阻塞通知摘要。
-- 为什么：参照官方 ActionInfoPanel.lua 实现完整 24 种阻塞枚举映射与关联实体检索；
--         生产阻塞严格跳过傀儡/抵抗/焚城城市，确保返回的 blocking_city_id 可直接排产。
-- 输入：activePlayerID（玩家 ID）。
-- 输出：EndTurnStatusDTO 表（带 __is_object = true，可空字段无值时省略）；
--       非法/非存活玩家返回 { __is_object = true, error = "..." }。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetEndTurnStatus(activePlayerID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end

    local isTurnActive = pPlayer:IsTurnActive() == true
    local rawBlockingId = pPlayer:GetEndTurnBlockingType()
    local noBlockingId = (EndTurnBlockingTypes and EndTurnBlockingTypes.NO_ENDTURN_BLOCKING_TYPE) or -1
    local blockingTypeId = (type(rawBlockingId) == "number") and rawBlockingId or noBlockingId
    local blockingTypeName = resolveBlockingTypeName(blockingTypeId)

    -- 按阻塞类型定位关联的待处理单位或城市（无匹配保持 nil 以省略键）
    local blockingUnitId = nil
    local blockingCityId = nil

    if blockingTypeName == "ENDTURN_BLOCKING_UNITS"
        or blockingTypeName == "ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS"
        or blockingTypeName == "ENDTURN_BLOCKING_STACKED_UNITS" then
        local pReadyUnit = pPlayer:GetFirstReadyUnit()
        if isUnitAlive(pReadyUnit) then
            blockingUnitId = pReadyUnit:GetID()
        end
    elseif blockingTypeName == "ENDTURN_BLOCKING_UNIT_PROMOTION" then
        for pUnit in pPlayer:Units() do
            if isUnitAlive(pUnit) and pUnit.IsPromotionReady ~= nil and pUnit:IsPromotionReady() == true then
                blockingUnitId = pUnit:GetID()
                break
            end
        end
    elseif blockingTypeName == "ENDTURN_BLOCKING_PRODUCTION" then
        for pCity in pPlayer:Cities() do
            if pCity ~= nil
                and (not pCity:IsPuppet())
                and (not pCity:IsResistance())
                and (not pCity:IsRazing())
                and (pCity:GetOrderQueueLength() or 0) == 0 then
                blockingCityId = pCity:GetID()
                break
            end
        end
    end

    -- 按引擎阻塞通知索引匹配对应通知摘要
    local notificationSummary = nil
    local blockingNotifIndex = pPlayer:GetEndTurnBlockingNotificationIndex()
    if type(blockingNotifIndex) == "number" and blockingNotifIndex >= 0 then
        local numNotifs = pPlayer:GetNumNotifications() or 0
        for i = 0, numNotifs - 1 do
            if pPlayer:GetNotificationIndex(i) == blockingNotifIndex then
                local summary = pPlayer:GetNotificationSummaryStr(i)
                if summary ~= nil and summary ~= "" then
                    notificationSummary = summary
                end
                break
            end
        end
    end

    -- 无阻塞且处于活动回合，并结合 UI.CanEndTurn()（若可用）综合判定是否可立即结束回合
    local canEndTurnNow = isTurnActive and (blockingTypeName == "NO_BLOCKING")
    if canEndTurnNow and UI ~= nil and UI.CanEndTurn ~= nil then
        local okCanEnd, uiCanEnd = pcall(UI.CanEndTurn)
        if okCanEnd then
            canEndTurnNow = canEndTurnNow and (uiCanEnd == true)
        end
    end

    return {
        __is_object = true,
        is_turn_active = isTurnActive,
        can_end_turn_now = canEndTurnNow,
        blocking_type_id = blockingTypeId,
        blocking_type_name = blockingTypeName,
        blocking_unit_id = blockingUnitId,
        blocking_city_id = blockingCityId,
        notification_summary = notificationSummary,
    }
end

-- -----------------------------------------------------------------------------
-- 第 4 节：聚合与局部战术查询主接口（WP-3，对应《模块内部接口设计.md》§4.4 ~ §4.5）
-- -----------------------------------------------------------------------------

-- 原生 BNW 空军最大射程上限（隐形轰炸机射程 20），防止异常数据导致过大扫描卡死
local MAX_AIR_SCAN_RADIUS = 20

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.BuildTurnOverview(activePlayerID)  [F5]
-- 做什么：聚合当前回合玩家可见的全局态势（TurnOverviewDTO），包括回合号、文明名、
--         全量帝国经济与资源、己方存活单位、己方城市摘要、全图可见敌军、已探索非己方城市
--         及当前回合结束阻塞诊断。
-- 为什么：严格聚合复用 GetEmpireEconomy / GetVisibilitySummary / GetEndTurnStatus /
--         SerializeUnitSummary / SerializeCitySummary，杜绝重复扫描逻辑并保证与《03》§2.1
--         及《模块内部接口设计.md》§4.4 100% 向下兼容。
-- 输入：activePlayerID（当前玩家 ID）。
-- 输出：TurnOverviewDTO 表（带 __is_object = true）；非法/非存活玩家返回
--       { __is_object = true, error = "..." }。
-- -----------------------------------------------------------------------------
function CAB_Collector.BuildTurnOverview(activePlayerID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end

    local economy = CAB_Collector.GetEmpireEconomy(activePlayerID)
    local visibilitySummary, _ = CAB_Collector.GetVisibilitySummary(activePlayerID)
    local endTurnStatus = CAB_Collector.GetEndTurnStatus(activePlayerID)

    local ourUnits = {}
    for pUnit in pPlayer:Units() do
        local uDto = CAB_Collector.SerializeUnitSummary(pUnit)
        if uDto ~= nil then
            table.insert(ourUnits, uDto)
        end
    end

    local ourCities = {}
    for pCity in pPlayer:Cities() do
        local cDto = CAB_Collector.SerializeCitySummary(pCity)
        if cDto ~= nil then
            table.insert(ourCities, cDto)
        end
    end

    local turnNumber = (Game ~= nil and Game.GetGameTurn ~= nil and Game.GetGameTurn()) or 0
    local playerCiv = pPlayer:GetCivilizationShortDescription() or ""

    return {
        __is_object = true,
        turn_number = turnNumber,
        active_player_id = activePlayerID,
        player_civ = playerCiv,
        yields = economy,
        our_units = ourUnits,
        visible_enemies = visibilitySummary.visible_enemies,
        our_cities = ourCities,
        visible_enemy_cities = visibilitySummary.visible_enemy_cities,
        end_turn_status = endTurnStatus,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.BuildUnitContextAndCandidates(activePlayerID, unitID, radius)  [F6]
-- 做什么：采集指定己方存活单位周边六边形战场网格（surrounding_tiles）及全部经引擎校验合法的
--         原子候选动作列表（candidate_actions：MOVE_STEP / MELEE_ATTACK / RANGE_ATTACK /
--         AIR_STRIKE / SETUP_FOR_RANGED / FORTIFY / HEAL / SKIP_TURN）。
-- 为什么：
--   1. 严格执行战争迷雾 5 条红线（F-01 ~ F-05）：黑雾格零信息泄露仅相邻陆海生成探路移动；
--      迷雾格省略动态改良与单位；远程/空袭判定仅允许对实时可见格或已探索交战敌城调用
--      CanRangeStrikeAt，杜绝普通迷雾侧信道探测；
--   2. 严格规避原版 BNW DLL 移动查询缺陷（A-05），统一复用 CanUnitMoveThrough + 1UPT；
--   3. 仅面向原生 BNW 与 IGE 兼容（D-05），不引入外部空袭 Mod 依赖，且原地动作探测期间
--      使用 pcall 包裹并在退出前无条件恢复原 UI 选区（存活复选，否则 ClearSelectionList）。
-- 输入：activePlayerID（玩家 ID）、unitID（己方单位 ID）、radius（可选网格半径，默认取
--       CAB_Config.DEFAULT_SCAN_RADIUS 并钳制至 [0, CAB_Config.MAX_SCAN_RADIUS]）。
-- 输出：UnitTacticalContextDTO（带 __is_object = true）；非法入参返回
--       { __is_object = true, error = "..." }。
-- -----------------------------------------------------------------------------
function CAB_Collector.BuildUnitContextAndCandidates(activePlayerID, unitID, radius)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end
    if not isInteger(unitID) then
        return makeErrorDto("Invalid unit ID: " .. tostring(unitID))
    end

    local pUnit = pPlayer:GetUnitByID(unitID)
    if not isUnitAlive(pUnit) or pUnit:GetOwner() ~= activePlayerID then
        return makeErrorDto("Unit not found or dead: " .. tostring(unitID))
    end

    local defaultRadius = (CAB_Config and CAB_Config.DEFAULT_SCAN_RADIUS) or 3
    local maxRadius = (CAB_Config and CAB_Config.MAX_SCAN_RADIUS) or 8

    local r
    if radius == nil then
        r = defaultRadius
    else
        local numR = tonumber(radius)
        if numR == nil or numR ~= numR then
            return makeErrorDto("Invalid radius: " .. tostring(radius))
        end
        r = math.floor(numR)
    end
    if r < 0 then
        r = 0
    elseif r > maxRadius then
        r = maxRadius
    end

    local activeTeam = pPlayer:GetTeam()
    local pActiveTeam = (Teams ~= nil and activeTeam ~= nil and activeTeam >= 0) and Teams[activeTeam] or nil
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local movesLeft = pUnit:MovesLeft() or 0
    local uDomain = pUnit:GetDomainType()
    local isAirUnit = (DomainTypes ~= nil and uDomain == DomainTypes.DOMAIN_AIR)
    local unitRange = math.max(0, math.floor(pUnit:Range() or 0))
    local selfIsCombat = (pUnit.IsCombatUnit ~= nil and pUnit:IsCombatUnit() == true) or false
    local unitCanAttack = true
    if pUnit.IsCanAttack ~= nil then
        local okCanAtk, canAtkRes = pcall(function() return pUnit:IsCanAttack() end)
        if okCanAtk then
            unitCanAttack = (canAtkRes == true)
        end
    end

    -- 计算内部扫描半径：surrounding_tiles 严格按 r 过滤，候选动作覆盖邻格与真实射程
    local effectiveRange = 0
    if isAirUnit then
        effectiveRange = math.min(unitRange, MAX_AIR_SCAN_RADIUS)
    else
        effectiveRange = math.min(unitRange, maxRadius)
    end
    local scanRadius = r
    if movesLeft > 0 and scanRadius < 1 then
        scanRadius = 1
    end
    if effectiveRange > scanRadius then
        scanRadius = effectiveRange
    end

    local tiles = {}
    local candidates = {}
    local actIdx = 1

    local function addCandidate(aType, tx, ty, cost, note, preview)
        table.insert(candidates, {
            __is_object = true,
            action_id = string.format("ACT_%02d", actIdx),
            action_type = aType,
            target_x = tx,
            target_y = ty,
            estimated_cost_moves = cost,
            combat_preview = preview,
            note = note or "",
        })
        actIdx = actIdx + 1
    end

    -- 1. 扫描周边六边形网格并枚举移动 / 近战 / 远程 / 空袭候选
    for dx = -scanRadius, scanRadius do
        for dy = -scanRadius, scanRadius do
            local pPlot = (Map ~= nil and Map.GetPlotXY ~= nil) and Map.GetPlotXY(ux, uy, dx, dy) or nil
            if pPlot ~= nil then
                local px, py = pPlot:GetX(), pPlot:GetY()
                local dist = Map.PlotDistance(ux, uy, px, py)
                if dist <= scanRadius then
                    local isRev = pPlot:IsRevealed(activeTeam, false) == true

                    if not isRev then
                        -- F-05 红线：未探索黑雾格绝不加入 surrounding_tiles，绝不调用远程探测，
                        -- 仅对相邻 1 格且仍有移动力的非空军单位生成无预览探路 MOVE_STEP
                        if dist == 1 and movesLeft > 0 and (not isAirUnit) then
                            addCandidate("MOVE_STEP", px, py, 1.0, "Explore adjacent unrevealed hex", nil)
                        end
                    else
                        local isVis = pPlot:IsVisible(activeTeam, false) == true
                        local friendlyId, enemyOnTile = nil, nil
                        if isVis then
                            -- F-01 / F-02：仅实时可见格采集单位，InspectPlotUnits 自动过滤隐形敌军
                            friendlyId, enemyOnTile = CAB_Collector.InspectPlotUnits(pPlot, activePlayerID)
                        end

                        local pPlotCity = pPlot:GetPlotCity()
                        local isHostileCity = false
                        local cityDto = nil
                        if pPlotCity ~= nil then
                            local cOwner = pPlotCity:GetOwner()
                            isHostileCity = (cOwner ~= activePlayerID) and isTeamAtWarWithPlayer(pActiveTeam, cOwner)
                            cityDto = {
                                __is_object = true,
                                city_id = pPlotCity:GetID(),
                                owner_id = cOwner,
                                name = pPlotCity:GetName() or "",
                                is_hostile = isHostileCity,
                            }
                        end

                        -- 导出半径 r 内的已探索地块（F-04：非可见迷雾格省略 improvement/单位）
                        if dist <= r then
                            local terrainStr = resolveRowType(GameInfo and GameInfo.Terrains, pPlot:GetTerrainType()) or "UNKNOWN"
                            local featureStr = resolveRowType(GameInfo and GameInfo.Features, pPlot:GetFeatureType())
                            local improvementStr = nil
                            if isVis then
                                improvementStr = resolveRowType(GameInfo and GameInfo.Improvements, pPlot:GetImprovementType())
                            end
                            table.insert(tiles, {
                                __is_object = true,
                                x = px,
                                y = py,
                                distance = dist,
                                visibility = isVis and "VISIBLE" or "REVEALED_FOG",
                                terrain = terrainStr,
                                feature = featureStr,
                                is_hills = pPlot:IsHills() == true,
                                has_river = pPlot:IsRiver() == true,
                                improvement = improvementStr,
                                friendly_unit_id = friendlyId,
                                enemy_unit = enemyOnTile,
                                city = cityDto,
                            })
                        end

                        -- 枚举相邻 1 格移动或近战/攻城攻击候选（非空军且仍有移动力）
                        if dist == 1 and movesLeft > 0 and (not isAirUnit) then
                            local hasWarEnemy = false
                            if enemyOnTile ~= nil then
                                hasWarEnemy = (enemyOnTile.is_barbarian == true)
                                    or isTeamAtWarWithPlayer(pActiveTeam, enemyOnTile.owner_id)
                            end

                            if hasWarEnemy or isHostileCity then
                                local domainCanMelee = false
                                if DomainTypes ~= nil then
                                    if uDomain == DomainTypes.DOMAIN_LAND then
                                        domainCanMelee = not (pPlot:IsWater() == true)
                                    elseif uDomain == DomainTypes.DOMAIN_SEA then
                                        domainCanMelee = (pPlot:IsWater() == true) or isHostileCity
                                    end
                                end

                                if selfIsCombat
                                    and unitCanAttack
                                    and unitRange == 0
                                    and (pUnit:GetBaseCombatStrength() or 0) > 0
                                    and (not (pPlot:IsImpassable() == true))
                                    and domainCanMelee then
                                    local targetType = "ENEMY_CITY"
                                    local targetHp = 0
                                    if enemyOnTile ~= nil then
                                        targetType = enemyOnTile.unit_type
                                        targetHp = enemyOnTile.hp
                                    elseif pPlotCity ~= nil then
                                        targetHp = math.max(0, getMaxCityHp(pPlotCity) - (pPlotCity:GetDamage() or 0))
                                    end
                                    local preview = {
                                        __is_object = true,
                                        target_enemy_type = targetType,
                                        target_hp_before = targetHp,
                                        terrain_modifier_note = (pPlot:IsHills() == true) and "HILLS" or "FLAT",
                                    }
                                    addCandidate("MELEE_ATTACK", px, py, 1.0, "Melee attack target", preview)
                                end
                            elseif enemyOnTile == nil and (pPlotCity == nil or pPlotCity:GetOwner() == activePlayerID) then
                                -- A-05 避坑：统一经 CanUnitMoveThrough + 1UPT 同类检查，绝不触发原版 DLL 恒假缺陷
                                if CAB_Collector.CanUnitMoveThrough(pUnit, pPlot)
                                    and (not CAB_Collector.HasSameClassFriendlyUnit(pPlot, activePlayerID, selfIsCombat)) then
                                    addCandidate("MOVE_STEP", px, py, 1.0, "Step move to adjacent hex", nil)
                                end
                            end
                        end

                        -- 枚举射程内远程打击或空军空袭候选
                        -- F-03 红线：仅允许对实时可见格或已探索交战敌城格调用 CanRangeStrikeAt，
                        -- 严禁对普通迷雾格探测以防止侧信道泄露隐匿敌军位置
                        local canProbeRange = isVis or (isRev and isHostileCity)
                        if canProbeRange and dist >= 1 and movesLeft > 0 and unitRange >= dist then
                            local okRange, canRange = pcall(function()
                                return pUnit:CanRangeStrikeAt(px, py, true, false)
                            end)
                            if okRange and canRange == true then
                                local aType = isAirUnit and "AIR_STRIKE" or "RANGE_ATTACK"
                                local preview = nil
                                if enemyOnTile ~= nil then
                                    preview = {
                                        __is_object = true,
                                        target_enemy_type = enemyOnTile.unit_type,
                                        target_hp_before = enemyOnTile.hp,
                                        terrain_modifier_note = (pPlot:IsHills() == true) and "HILLS" or "FLAT",
                                    }
                                elseif isHostileCity and pPlotCity ~= nil then
                                    preview = {
                                        __is_object = true,
                                        target_enemy_type = "ENEMY_CITY",
                                        target_hp_before = math.max(0, getMaxCityHp(pPlotCity) - (pPlotCity:GetDamage() or 0)),
                                        terrain_modifier_note = (pPlot:IsHills() == true) and "HILLS" or "FLAT",
                                    }
                                end
                                addCandidate(
                                    aType,
                                    px,
                                    py,
                                    1.0,
                                    aType .. " at (" .. tostring(px) .. "," .. tostring(py) .. ")",
                                    preview
                                )
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2. 枚举原地动作（SETUP_FOR_RANGED / FORTIFY / HEAL / SKIP_TURN）
    -- 唯一允许的临时 UI 选区探测：pcall 兜底确保异常路径也无条件恢复原选区（A-03 / D-05）
    if movesLeft > 0 then
        local prevSelected = (UI ~= nil and UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil
        local didChangeSelection = false

        local function restoreSelection()
            if not didChangeSelection or UI == nil then
                return
            end
            if isUnitAlive(prevSelected) then
                if UI.SelectUnit ~= nil then
                    pcall(UI.SelectUnit, prevSelected)
                end
            else
                if UI.ClearSelectionList ~= nil then
                    pcall(UI.ClearSelectionList)
                end
            end
            didChangeSelection = false
        end

        pcall(function()
            if UI ~= nil and UI.SelectUnit ~= nil then
                local alreadySelected = (
                    isUnitAlive(prevSelected)
                    and prevSelected:GetID() == pUnit:GetID()
                    and prevSelected:GetOwner() == pUnit:GetOwner()
                )
                if not alreadySelected then
                    UI.SelectUnit(pUnit)
                    didChangeSelection = true
                end
            end

            local uPlot = pUnit:GetPlot()

            if CAB_Collector.FindGameActionIndex("MISSION_SET_UP_FOR_RANGED_ATTACK") ~= nil then
                addCandidate("SETUP_FOR_RANGED", ux, uy, 1.0, "Set up siege unit for ranged attack", nil)
            end

            if CAB_Collector.FindGameActionIndex("MISSION_FORTIFY") ~= nil
                or CAB_Collector.FindGameActionIndex("MISSION_ALERT") ~= nil then
                addCandidate("FORTIFY", ux, uy, 1.0, "Fortify / Alert at current tile", nil)
            elseif uPlot ~= nil and pUnit.CanFortify ~= nil then
                local okFort, canFort = pcall(function() return pUnit:CanFortify(uPlot) end)
                if okFort and canFort == true then
                    addCandidate("FORTIFY", ux, uy, 1.0, "Fortify at current tile", nil)
                end
            end

            if CAB_Collector.FindGameActionIndex("MISSION_HEAL") ~= nil then
                addCandidate("HEAL", ux, uy, 1.0, "Heal at current tile", nil)
            elseif uPlot ~= nil and pUnit.CanHeal ~= nil then
                local okHeal, canHeal = pcall(function() return pUnit:CanHeal(uPlot) end)
                if okHeal and canHeal == true then
                    addCandidate("HEAL", ux, uy, 1.0, "Heal at current tile", nil)
                end
            end

            addCandidate("SKIP_TURN", ux, uy, 0.0, "Hold / Skip remaining movement this turn", nil)
        end)

        restoreSelection()
    end

    return {
        __is_object = true,
        unit = CAB_Collector.SerializeUnitSummary(pUnit),
        surrounding_tiles = tiles,
        candidate_actions = candidates,
    }
end

-- -----------------------------------------------------------------------------
-- 第 5 节：深度城市查询主接口（WP-4，对应《模块内部接口设计.md》§4.6）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetCityDetail(activePlayerID, cityID, includePurchasable)  [F7]
-- 做什么：采集单座己方城市的深度内政、城防远程目标与购买报价单（CityDetailDTO），
--         包含 city 基础态、yields 分项产出、production_state 队列、garrison_unit_id、
--         built_buildings 真实建筑、ranged_attack_targets 城防炮击目标，以及可选的
--         purchasable_buildings / purchasable_units / purchasable_plots。
-- 为什么：
--   1. city.combat_str 参照官方 CityView.lua:855 对 GetStrengthValue() 除以 100 向下取整；
--   2. yields.turns_to_growth 参照 CityView.lua:1666-1673，在造移民/停滞/饥荒时返回 -1；
--   3. ranged_attack_targets 严守迷雾防侧信道（F-01~F-03），仅对实时可见格复用
--      InspectPlotUnits 过滤隐形单位，仅对交战敌军/蛮族调用 CanRangeStrikeAt(px, py, true, true)；
--   4. 购买建筑/单位按 ProductionPopup.lua 双层 IsCanPurchase 分别判定规则候选与当前可负担，
--      单位信仰价格传第二参数 true（GetUnitFaithPurchaseCost(unitTypeId, true)）；
--   5. 购买地块校验 BUY_PLOTS_DISABLED == 0 及非傀儡/非抵抗/非焚城，资源严格经
--      pPlot:GetResourceType(activeTeam) 过滤以防止泄露未解锁科技资源（F-06）。
-- 输入：activePlayerID（当前存活玩家 ID）、cityID（己方城市整数 ID）、
--       includePurchasable（可选布尔值，缺省为 true；显式 false 时跳过三类购买列表采集）。
-- 输出：CityDetailDTO 表（带 __is_object = true，可空字段无值时省略）；
--       非法入参或越权访问非己方城市时返回 { __is_object = true, error = "..." }。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetCityDetail(activePlayerID, cityID, includePurchasable)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end
    if not isInteger(cityID) then
        return makeErrorDto("Invalid city ID: " .. tostring(cityID))
    end

    local pCity = pPlayer:GetCityByID(cityID)
    if pCity == nil or pCity:GetOwner() ~= activePlayerID then
        return makeErrorDto("City not found or not owned by player: " .. tostring(cityID))
    end

    local wantPurchasable = (includePurchasable ~= false)
    local activeTeam = pPlayer:GetTeam()
    local pActiveTeam = (Teams ~= nil and activeTeam ~= nil and activeTeam >= 0) and Teams[activeTeam] or nil

    -- 1. 城市基础属性与状态标记
    local cx, cy = pCity:GetX(), pCity:GetY()
    local maxHp = getMaxCityHp(pCity)
    local damage = pCity:GetDamage() or 0
    local hp = math.max(0, maxHp - damage)
    local combatStr = math.floor((pCity:GetStrengthValue() or 0) / 100)
    local isCapital = pCity:IsCapital() == true
    local isPuppet = pCity:IsPuppet() == true
    local isOccupied = pCity:IsOccupied() == true
    local isInResistance = pCity:IsResistance() == true
    local isRazing = pCity:IsRazing() == true

    local cityInfo = {
        __is_object = true,
        city_id = pCity:GetID(),
        name = pCity:GetName() or "",
        x = cx,
        y = cy,
        pop = pCity:GetPopulation() or 0,
        hp = hp,
        max_hp = maxHp,
        combat_str = combatStr,
        is_capital = isCapital,
        is_puppet = isPuppet,
        is_occupied = isOccupied,
        is_in_resistance = isInResistance,
        is_razing = isRazing,
    }

    -- 2. 本城每回合分项产出与人口增长回合（参照 CityView.lua:1666-1673）
    local foodNet = pCity:FoodDifference() or 0
    local foodDiffTimes100 = (pCity.FoodDifferenceTimes100 ~= nil and pCity:FoodDifferenceTimes100()) or (foodNet * 100)
    local isFoodProd = (pCity.IsFoodProduction ~= nil and pCity:IsFoodProduction() == true)
    local turnsToGrowth = -1
    if (not isFoodProd) and foodDiffTimes100 > 0 and foodNet >= 0 then
        local rawTurns = pCity:GetFoodTurnsLeft()
        if type(rawTurns) == "number" and rawTurns > 0 then
            turnsToGrowth = rawTurns
        end
    end

    local yields = {
        __is_object = true,
        food = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_FOOD)) or 0,
        food_net = foodNet,
        turns_to_growth = turnsToGrowth,
        production = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_PRODUCTION)) or 0,
        gold = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_GOLD)) or 0,
        science = (YieldTypes and pCity:GetYieldRate(YieldTypes.YIELD_SCIENCE)) or 0,
        culture = pCity:GetJONSCulturePerTurn() or 0,
        faith = pCity:GetFaithPerTurn() or 0,
    }

    -- 3. 当前生产队列状态
    local prodKey = pCity:GetProductionNameKey()
    local currentItem = "NONE"
    if prodKey ~= nil and prodKey ~= "" then
        currentItem = safeLocale(prodKey)
    end
    local productionState = {
        __is_object = true,
        current_item = currentItem,
        order_queue_length = pCity:GetOrderQueueLength() or 0,
        turns_left = pCity:GetProductionTurnsLeft() or 0,
    }

    -- 4. 驻城军事单位 ID（过滤 nil / 已死 / 延迟死亡 / 非己方，无驻军时留 nil 省略键）
    local garrisonUnitId = nil
    if pCity.GetGarrisonedUnit ~= nil then
        local okGar, pGarrison = pcall(function() return pCity:GetGarrisonedUnit() end)
        if okGar and isUnitAlive(pGarrison) and pGarrison:GetOwner() == activePlayerID then
            garrisonUnitId = pGarrison:GetID()
        end
    end

    -- 5. 已建成真实建筑列表
    local builtBuildings = {}
    if GameInfo ~= nil and GameInfo.Buildings ~= nil then
        for bld in GameInfo.Buildings() do
            if bld ~= nil and bld.ID ~= nil and bld.Type ~= nil then
                local count = pCity:GetNumRealBuilding(bld.ID) or 0
                if count > 0 then
                    table.insert(builtBuildings, {
                        __is_object = true,
                        building_id = bld.ID,
                        building_type = bld.Type,
                        name = safeLocale(bld.Description or bld.Type),
                        count = count,
                    })
                end
            end
        end
    end

    -- 6. 城防远程炮击目标（仅 CanRangeStrikeNow() == true 时扫描 CITY_ATTACK_RANGE 内实时可见敌军）
    local rangedAttackTargets = {}
    local canStrikeNow = false
    if pCity.CanRangeStrikeNow ~= nil then
        local okNow, nowRes = pcall(function() return pCity:CanRangeStrikeNow() end)
        if okNow and nowRes == true then
            canStrikeNow = true
        end
    end

    if canStrikeNow and Map ~= nil and Map.GetPlotXY ~= nil then
        local attackRange = getCityAttackRange()
        for dx = -attackRange, attackRange do
            for dy = -attackRange, attackRange do
                local pPlot = Map.GetPlotXY(cx, cy, dx, dy)
                if pPlot ~= nil then
                    local px, py = pPlot:GetX(), pPlot:GetY()
                    local dist = Map.PlotDistance(cx, cy, px, py)
                    if dist >= 1 and dist <= attackRange then
                        -- F-01 / F-02 / F-03：仅对实时可见格经 InspectPlotUnits 过滤隐形后，
                        -- 再对交战敌军或蛮族调用 CanRangeStrikeAt，杜绝迷雾侧信道探测
                        if pPlot:IsVisible(activeTeam, false) == true then
                            local _, enemyDto = CAB_Collector.InspectPlotUnits(pPlot, activePlayerID)
                            if enemyDto ~= nil then
                                local isHostileEnemy = (enemyDto.is_barbarian == true)
                                    or isTeamAtWarWithPlayer(pActiveTeam, enemyDto.owner_id)
                                if isHostileEnemy then
                                    local okAt, canAt = pcall(function()
                                        return pCity:CanRangeStrikeAt(px, py, true, true)
                                    end)
                                    if okAt and canAt == true then
                                        table.insert(rangedAttackTargets, {
                                            __is_object = true,
                                            x = px,
                                            y = py,
                                            distance = dist,
                                            enemy_id = enemyDto.enemy_id,
                                            unit_type = enemyDto.unit_type,
                                            hp = enemyDto.hp,
                                            owner_id = enemyDto.owner_id,
                                            owner_name = enemyDto.owner_name,
                                            is_barbarian = enemyDto.is_barbarian,
                                        })
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 7. 可购买建筑 / 单位 / 地块报价单（includePurchasable == false 时直接返回空数组）
    local purchasableBuildings = {}
    local purchasableUnits = {}
    local purchasablePlots = {}

    if wantPurchasable then
        if GameInfo ~= nil and YieldTypes ~= nil then
            -- 7.1 可购买建筑（双层 IsCanPurchase：规则候选 + 当前可负担）
            if GameInfo.Buildings ~= nil then
                for bld in GameInfo.Buildings() do
                    if bld ~= nil and bld.ID ~= nil and bld.Type ~= nil then
                        local bldId = bld.ID
                        local canGoldRule = pCity:IsCanPurchase(false, false, -1, bldId, -1, YieldTypes.YIELD_GOLD) == true
                        local canFaithRule = pCity:IsCanPurchase(false, false, -1, bldId, -1, YieldTypes.YIELD_FAITH) == true
                        if canGoldRule or canFaithRule then
                            local goldCost = 0
                            local canAffordGold = false
                            if canGoldRule then
                                goldCost = pCity:GetBuildingPurchaseCost(bldId) or 0
                                canAffordGold = pCity:IsCanPurchase(true, true, -1, bldId, -1, YieldTypes.YIELD_GOLD) == true
                            end

                            local faithCost = 0
                            local canAffordFaith = false
                            if canFaithRule then
                                faithCost = pCity:GetBuildingFaithPurchaseCost(bldId) or 0
                                canAffordFaith = pCity:IsCanPurchase(true, true, -1, bldId, -1, YieldTypes.YIELD_FAITH) == true
                            end

                            table.insert(purchasableBuildings, {
                                __is_object = true,
                                building_id = bldId,
                                building_type = bld.Type,
                                name = safeLocale(bld.Description or bld.Type),
                                gold_cost = goldCost,
                                faith_cost = faithCost,
                                can_afford_gold_now = canAffordGold,
                                can_afford_faith_now = canAffordFaith,
                            })
                        end
                    end
                end
            end

            -- 7.2 可购买单位（双层 IsCanPurchase，信仰价格按 ProductionPopup.lua:457 传参 true）
            if GameInfo.Units ~= nil then
                for unitRow in GameInfo.Units() do
                    if unitRow ~= nil and unitRow.ID ~= nil and unitRow.Type ~= nil then
                        local unitTypeId = unitRow.ID
                        local canGoldRule = pCity:IsCanPurchase(false, false, unitTypeId, -1, -1, YieldTypes.YIELD_GOLD) == true
                        local canFaithRule = pCity:IsCanPurchase(false, false, unitTypeId, -1, -1, YieldTypes.YIELD_FAITH) == true
                        if canGoldRule or canFaithRule then
                            local goldCost = 0
                            local canAffordGold = false
                            if canGoldRule then
                                goldCost = pCity:GetUnitPurchaseCost(unitTypeId) or 0
                                canAffordGold = pCity:IsCanPurchase(true, true, unitTypeId, -1, -1, YieldTypes.YIELD_GOLD) == true
                            end

                            local faithCost = 0
                            local canAffordFaith = false
                            if canFaithRule then
                                faithCost = pCity:GetUnitFaithPurchaseCost(unitTypeId, true) or 0
                                canAffordFaith = pCity:IsCanPurchase(true, true, unitTypeId, -1, -1, YieldTypes.YIELD_FAITH) == true
                            end

                            table.insert(purchasableUnits, {
                                __is_object = true,
                                unit_type_id = unitTypeId,
                                unit_type = unitRow.Type,
                                name = safeLocale(unitRow.Description or unitRow.Type),
                                gold_cost = goldCost,
                                faith_cost = faithCost,
                                can_afford_gold_now = canAffordGold,
                                can_afford_faith_now = canAffordFaith,
                            })
                        end
                    end
                end
            end
        end

        -- 7.3 可购买地块（校验 BUY_PLOTS_DISABLED == 0、非傀儡/非抵抗/非焚城及 F-06 科技资源过滤）
        local buyPlotsDisabled = (GameDefines and GameDefines.BUY_PLOTS_DISABLED) or 0
        if buyPlotsDisabled == 0 and (not isPuppet) and (not isInResistance) and (not isRazing) then
            local numCityPlots = pCity:GetNumCityPlots() or 0
            for i = 0, numCityPlots - 1 do
                local pPlot = pCity:GetCityIndexPlot(i)
                if pPlot ~= nil and pPlot:IsRevealed(activeTeam, false) == true then
                    local px, py = pPlot:GetX(), pPlot:GetY()
                    if pCity:CanBuyPlotAt(px, py, true) == true then
                        local canAffordNow = pCity:CanBuyPlotAt(px, py, false) == true
                        local goldCost = pCity:GetBuyPlotCost(px, py) or 0
                        local terrainStr = resolveRowType(GameInfo and GameInfo.Terrains, pPlot:GetTerrainType()) or "UNKNOWN"
                        local featureStr = resolveRowType(GameInfo and GameInfo.Features, pPlot:GetFeatureType())
                        -- F-06 红线：必须传入 activeTeam，严禁泄露未解锁科技的战略资源
                        local resourceStr = resolveRowType(GameInfo and GameInfo.Resources, pPlot:GetResourceType(activeTeam))

                        table.insert(purchasablePlots, {
                            __is_object = true,
                            x = px,
                            y = py,
                            gold_cost = goldCost,
                            can_afford_now = canAffordNow,
                            terrain = terrainStr,
                            feature = featureStr,
                            is_hills = pPlot:IsHills() == true,
                            resource_type = resourceStr,
                        })
                    end
                end
            end
        end
    end

    return {
        __is_object = true,
        city = cityInfo,
        yields = yields,
        production_state = productionState,
        garrison_unit_id = garrisonUnitId,
        built_buildings = builtBuildings,
        ranged_attack_targets = rangedAttackTargets,
        purchasable_buildings = purchasableBuildings,
        purchasable_units = purchasableUnits,
        purchasable_plots = purchasablePlots,
    }
end

-- -----------------------------------------------------------------------------
-- 第 6 节：三大回合硬阻塞选项查询主接口（M1Sub3 WP5 / D-08 增量扩充，F8 ~ F10）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：isGameOptionEnabled(optionName)
-- 做什么：安全查询 Game.IsOption(GameOptionTypes[optionName]) 是否开启。
-- 为什么：兼容测试桩或未定义某项游戏选项的场景，避免索引 nil 触发运行时错误。
-- 输入：optionName（GameOptionTypes 枚举键名字符串）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function isGameOptionEnabled(optionName)
    if Game == nil or Game.IsOption == nil or GameOptionTypes == nil then
        return false
    end
    local optId = GameOptionTypes[optionName]
    if optId == nil then
        return false
    end
    local ok, res = pcall(Game.IsOption, optId)
    return ok and res == true
end

-- -----------------------------------------------------------------------------
-- 函数：readTechCost(pPlayer, pTeamTechs, techRow) / readTechProgress(...) / readTechTurnsLeft(...)
-- 做什么：参照官方 TechPanel.lua:72-73 与 TechPopup.lua:228-230 安全读取科技花费、进度与剩余回合。
-- 为什么：同时兼容 Player 快捷方法与 TeamTechs 原生方法，零跨调用缓存，异常安全兜底。
-- 输入：pPlayer、pTeamTechs、techRow（GameInfo.Technologies 行表）。
-- 输出：number。
-- -----------------------------------------------------------------------------
local function readTechCost(pPlayer, pTeamTechs, techRow)
    local techId = techRow.ID
    if pPlayer ~= nil and pPlayer.GetResearchCost ~= nil then
        local ok, val = pcall(pPlayer.GetResearchCost, pPlayer, techId)
        if ok and type(val) == "number" then
            return val
        end
    end
    if pTeamTechs ~= nil and pTeamTechs.GetResearchCost ~= nil then
        local ok, val = pcall(pTeamTechs.GetResearchCost, pTeamTechs, techId)
        if ok and type(val) == "number" then
            return val
        end
    end
    return (type(techRow.Cost) == "number") and techRow.Cost or 0
end

local function readTechProgress(pPlayer, pTeamTechs, techId)
    if pPlayer ~= nil and pPlayer.GetResearchProgress ~= nil then
        local ok, val = pcall(pPlayer.GetResearchProgress, pPlayer, techId)
        if ok and type(val) == "number" then
            return val
        end
    end
    if pTeamTechs ~= nil and pTeamTechs.GetResearchProgress ~= nil then
        local ok, val = pcall(pTeamTechs.GetResearchProgress, pTeamTechs, techId)
        if ok and type(val) == "number" then
            return val
        end
    end
    return 0
end

local function readTechTurnsLeft(pPlayer, techId)
    if pPlayer ~= nil and pPlayer.GetResearchTurnsLeft ~= nil then
        local ok, val = pcall(pPlayer.GetResearchTurnsLeft, pPlayer, techId, true)
        if ok and type(val) == "number" then
            return val
        end
    end
    return 0
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetResearchOptions(activePlayerID)  [F8]
-- 做什么：采集当前存活玩家的科研状态与全部合法可选科技（含常规研究与免费科技），
--         供智能体处理 ENDTURN_BLOCKING_RESEARCH 与 ENDTURN_BLOCKING_FREE_TECH。
-- 为什么：
--   1. 参照官方 TechPopup.lua:122-147 与 TechTree.lua:579-696，严格校验
--      GAMEOPTION_NO_SCIENCE、pPlayer:CanResearch(techID)，并在 GetNumFreeTechs() > 0
--      时追加 pPlayer:CanResearchForFree(techID) 过滤；
--   2. 纯只读、零 UI 选区副作用、零跨调用缓存，可安全在 AI 回合白名单放行。
-- 输入：activePlayerID（当前玩家 ID）。
-- 输出：ResearchOptionsDTO 表（带 __is_object = true）；非法/非存活玩家返回错误表。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetResearchOptions(activePlayerID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end

    local activeTeam = pPlayer:GetTeam()
    local pActiveTeam = (Teams ~= nil and activeTeam ~= nil and activeTeam >= 0) and Teams[activeTeam] or nil
    local pTeamTechs = (pActiveTeam ~= nil and pActiveTeam.GetTeamTechs ~= nil) and pActiveTeam:GetTeamTechs() or nil

    local scienceDisabled = isGameOptionEnabled("GAMEOPTION_NO_SCIENCE")
    local sciencePerTurn = (pPlayer.GetScience ~= nil and pPlayer:GetScience()) or 0
    local overflowResearch = (pPlayer.GetOverflowResearch ~= nil and pPlayer:GetOverflowResearch()) or 0
    local freeTechs = (pPlayer.GetNumFreeTechs ~= nil and pPlayer:GetNumFreeTechs()) or 0
    local currTechId = (pPlayer.GetCurrentResearch ~= nil and pPlayer:GetCurrentResearch()) or -1

    local currentResearch = nil
    if type(currTechId) == "number" and currTechId >= 0 and GameInfo ~= nil and GameInfo.Technologies ~= nil then
        local currRow = GameInfo.Technologies[currTechId]
        if currRow ~= nil and currRow.Type ~= nil and currRow.Type ~= "" then
            currentResearch = {
                __is_object = true,
                tech_id = currTechId,
                tech_type = currRow.Type,
                name = safeLocale(currRow.Description or currRow.Type),
                era = currRow.Era or "",
                cost = readTechCost(pPlayer, pTeamTechs, currRow),
                progress = readTechProgress(pPlayer, pTeamTechs, currTechId),
                turns_left = readTechTurnsLeft(pPlayer, currTechId),
            }
        end
    end

    local availableTechs = {}
    local researchedTechs = {}

    if GameInfo ~= nil and GameInfo.Technologies ~= nil then
        for tech in GameInfo.Technologies() do
            if tech ~= nil and tech.ID ~= nil and tech.Type ~= nil and tech.Type ~= "" then
                local techId = tech.ID
                local hasTech = false
                if pTeamTechs ~= nil and pTeamTechs.HasTech ~= nil then
                    local okHas, resHas = pcall(pTeamTechs.HasTech, pTeamTechs, techId)
                    hasTech = (okHas and resHas == true)
                end
                if hasTech then
                    table.insert(researchedTechs, tech.Type)
                end

                if (not scienceDisabled) and pPlayer.CanResearch ~= nil then
                    local okCan, canRes = pcall(pPlayer.CanResearch, pPlayer, techId)
                    if okCan and canRes == true then
                        local eligible = true
                        if freeTechs > 0 and pPlayer.CanResearchForFree ~= nil then
                            local okFree, canFree = pcall(pPlayer.CanResearchForFree, pPlayer, techId)
                            eligible = (okFree and canFree == true)
                        end
                        if eligible then
                            table.insert(availableTechs, {
                                __is_object = true,
                                tech_id = techId,
                                tech_type = tech.Type,
                                name = safeLocale(tech.Description or tech.Type),
                                era = tech.Era or "",
                                cost = readTechCost(pPlayer, pTeamTechs, tech),
                                progress = readTechProgress(pPlayer, pTeamTechs, techId),
                                turns_left = readTechTurnsLeft(pPlayer, techId),
                                is_current = (currTechId == techId),
                                grid_x = tech.GridX or 0,
                                grid_y = tech.GridY or 0,
                            })
                        end
                    end
                end
            end
        end
    end

    return {
        __is_object = true,
        science_disabled = scienceDisabled,
        science_per_turn = sciencePerTurn,
        overflow_research = overflowResearch,
        free_techs_available = freeTechs,
        is_free_tech_pending = (freeTechs > 0),
        current_research = currentResearch,
        available_techs = availableTechs,
        researched_techs = researchedTechs,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetPolicyOptions(activePlayerID)  [F9]
-- 做什么：采集当前存活玩家的社会政策文化余额、下一次政策花费、免费政策/信条数、
--         9 大常规政策分支状态、当前可开启分支、当前可采纳政策（含已选意识形态信条）与已采纳清单。
-- 为什么：
--   1. 严格参照官方 SocialPolicyPopup.lua:155, 234-655, 795：使用原生 CanUnlockPolicyBranch(branchID)
--      校验分支开启，使用 CanAdoptPolicy(policyID) 校验政策采纳，过滤 PolicyBranchType == nil 的
--      自动赠予开/关门政策，并按 GetNumCities() > 0 守卫无城阶段；
--   2. 纯只读、零 UI 选区副作用、零跨调用缓存，可安全在 AI 回合白名单放行。
-- 输入：activePlayerID（当前玩家 ID）。
-- 输出：PolicyOptionsDTO 表（带 __is_object = true）；非法/非存活玩家返回错误表。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetPolicyOptions(activePlayerID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end

    local activeTeam = pPlayer:GetTeam()
    local pActiveTeam = (Teams ~= nil and activeTeam ~= nil and activeTeam >= 0) and Teams[activeTeam] or nil
    local currentEra = (pActiveTeam ~= nil and pActiveTeam.GetCurrentEra ~= nil and pActiveTeam:GetCurrentEra()) or 0

    local policiesDisabled = isGameOptionEnabled("GAMEOPTION_NO_POLICIES")
    local religionDisabled = isGameOptionEnabled("GAMEOPTION_NO_RELIGION")

    local culture = (pPlayer.GetJONSCulture ~= nil and pPlayer:GetJONSCulture()) or 0
    local culturePerTurn = (pPlayer.GetTotalJONSCulturePerTurn ~= nil and pPlayer:GetTotalJONSCulturePerTurn()) or 0
    local nextPolicyCost = (pPlayer.GetNextPolicyCost ~= nil and pPlayer:GetNextPolicyCost()) or 0
    local freePolicies = (pPlayer.GetNumFreePolicies ~= nil and pPlayer:GetNumFreePolicies()) or 0
    local freeTenets = (pPlayer.GetNumFreeTenets ~= nil and pPlayer:GetNumFreeTenets()) or 0
    local numCities = (pPlayer.GetNumCities ~= nil and pPlayer:GetNumCities()) or 0

    local ideologyBranchId = (pPlayer.GetLateGamePolicyTree ~= nil and pPlayer:GetLateGamePolicyTree()) or -1
    local ideologyBranchType = nil
    if type(ideologyBranchId) == "number" and ideologyBranchId >= 0
        and GameInfo ~= nil and GameInfo.PolicyBranchTypes ~= nil
    then
        local iRow = GameInfo.PolicyBranchTypes[ideologyBranchId]
        if iRow ~= nil and iRow.Type ~= nil and iRow.Type ~= "" then
            ideologyBranchType = iRow.Type
        end
    else
        ideologyBranchId = -1
    end

    local policyBranches = {}
    local unlockableBranches = {}

    if GameInfo ~= nil and GameInfo.PolicyBranchTypes ~= nil then
        for branch in GameInfo.PolicyBranchTypes() do
            if branch ~= nil and branch.ID ~= nil and branch.Type ~= nil and branch.Type ~= ""
                and branch.PurchaseByLevel ~= true
            then
                local branchId = branch.ID
                local unlocked = (pPlayer.IsPolicyBranchUnlocked ~= nil and pPlayer:IsPolicyBranchUnlocked(branchId) == true) or false
                local finished = (pPlayer.IsPolicyBranchFinished ~= nil and pPlayer:IsPolicyBranchFinished(branchId) == true) or false
                local blocked = (pPlayer.IsPolicyBranchBlocked ~= nil and pPlayer:IsPolicyBranchBlocked(branchId) == true) or false

                local eraPrereq = (type(branch.EraPrereq) == "string" and branch.EraPrereq ~= "") and branch.EraPrereq or nil
                local eraMet = true
                if eraPrereq ~= nil and GameInfoTypes ~= nil and type(GameInfoTypes[eraPrereq]) == "number" then
                    eraMet = (currentEra >= GameInfoTypes[eraPrereq])
                end

                local lockedByReligion = (branch.LockedWithoutReligion == true and religionDisabled)
                local canUnlockNow = false
                if (not policiesDisabled) and numCities > 0 and (not unlocked) and (not blocked)
                    and (not lockedByReligion) and pPlayer.CanUnlockPolicyBranch ~= nil
                then
                    local okU, resU = pcall(pPlayer.CanUnlockPolicyBranch, pPlayer, branchId)
                    canUnlockNow = (okU and resU == true)
                end

                table.insert(policyBranches, {
                    __is_object = true,
                    branch_id = branchId,
                    branch_type = branch.Type,
                    name = safeLocale(branch.Description or branch.Type),
                    era_prereq = eraPrereq,
                    era_met = eraMet,
                    unlocked = unlocked,
                    finished = finished,
                    blocked = blocked,
                    can_unlock_now = canUnlockNow,
                })

                if canUnlockNow then
                    table.insert(unlockableBranches, {
                        __is_object = true,
                        branch_id = branchId,
                        branch_type = branch.Type,
                        name = safeLocale(branch.Description or branch.Type),
                        help = safeLocale(branch.Help or branch.Description or branch.Type),
                    })
                end
            end
        end
    end

    local adoptablePolicies = {}
    local adoptedPolicies = {}
    local addedAdoptableIds = {}

    if GameInfo ~= nil and GameInfo.Policies ~= nil then
        for policy in GameInfo.Policies() do
            if policy ~= nil and policy.ID ~= nil and policy.Type ~= nil and policy.Type ~= ""
                and type(policy.PolicyBranchType) == "string" and policy.PolicyBranchType ~= ""
            then
                local policyId = policy.ID
                local owned = (pPlayer.HasPolicy ~= nil and pPlayer:HasPolicy(policyId) == true) or false
                if owned then
                    table.insert(adoptedPolicies, policy.Type)
                elseif (not policiesDisabled) and numCities > 0 then
                    local branchRow = (GameInfo.PolicyBranchTypes ~= nil)
                        and GameInfo.PolicyBranchTypes[policy.PolicyBranchType] or nil
                    local isIdeologyPolicy = (branchRow ~= nil and branchRow.PurchaseByLevel == true)
                    if not isIdeologyPolicy then
                        local blocked = (pPlayer.IsPolicyBlocked ~= nil and pPlayer:IsPolicyBlocked(policyId) == true) or false
                        if (not blocked) and pPlayer.CanAdoptPolicy ~= nil then
                            local okA, resA = pcall(pPlayer.CanAdoptPolicy, pPlayer, policyId)
                            if okA and resA == true then
                                addedAdoptableIds[policyId] = true
                                table.insert(adoptablePolicies, {
                                    __is_object = true,
                                    policy_id = policyId,
                                    policy_type = policy.Type,
                                    name = safeLocale(policy.Description or policy.Type),
                                    branch_type = policy.PolicyBranchType,
                                    is_tenet = false,
                                    level = 0,
                                    help = safeLocale(policy.Help or ""),
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    -- 已选定后期意识形态且具备采纳资源时，按 SocialPolicyPopup.lua:551-655, 795 枚举当前可采纳信条
    local hasTenetBudget = (freePolicies > 0 or freeTenets > 0 or culture >= nextPolicyCost)
    if ideologyBranchId >= 0 and (not policiesDisabled) and numCities > 0
        and hasTenetBudget and pPlayer.GetAvailableTenets ~= nil
        and GameInfo ~= nil and GameInfo.Policies ~= nil
    then
        local slotOpen = { [1] = true, [2] = true, [3] = true }
        if pPlayer.GetTenet ~= nil then
            local l1Count, l2Count, l3Count = 0, 0, 0
            for idx = 1, 7 do
                local okT, tid = pcall(pPlayer.GetTenet, pPlayer, ideologyBranchId, 1, idx)
                if okT and type(tid) == "number" and tid >= 0 then
                    l1Count = l1Count + 1
                end
            end
            for idx = 1, 4 do
                local okT, tid = pcall(pPlayer.GetTenet, pPlayer, ideologyBranchId, 2, idx)
                if okT and type(tid) == "number" and tid >= 0 then
                    l2Count = l2Count + 1
                end
            end
            for idx = 1, 3 do
                local okT, tid = pcall(pPlayer.GetTenet, pPlayer, ideologyBranchId, 3, idx)
                if okT and type(tid) == "number" and tid >= 0 then
                    l3Count = l3Count + 1
                end
            end
            slotOpen[1] = (l1Count < 7)
            slotOpen[2] = (l2Count < 4) and (l1Count >= l2Count + 2)
            slotOpen[3] = (l3Count < 3) and (l2Count >= l3Count + 2)
        end

        for lvl = 1, 3 do
            if slotOpen[lvl] then
                local okList, tenetList = pcall(pPlayer.GetAvailableTenets, pPlayer, lvl)
                if okList and type(tenetList) == "table" then
                    for _, tenetId in ipairs(tenetList) do
                        if type(tenetId) == "number" and tenetId >= 0 and not addedAdoptableIds[tenetId] then
                            local owned = (pPlayer.HasPolicy ~= nil and pPlayer:HasPolicy(tenetId) == true) or false
                            local tenetRow = GameInfo.Policies[tenetId]
                            if (not owned) and tenetRow ~= nil and tenetRow.Type ~= nil and tenetRow.Type ~= "" then
                                addedAdoptableIds[tenetId] = true
                                table.insert(adoptablePolicies, {
                                    __is_object = true,
                                    policy_id = tenetId,
                                    policy_type = tenetRow.Type,
                                    name = safeLocale(tenetRow.Description or tenetRow.Type),
                                    branch_type = tenetRow.PolicyBranchType or ideologyBranchType or "",
                                    is_tenet = true,
                                    level = lvl,
                                    help = safeLocale(tenetRow.Help or ""),
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    local canAdoptNow = (not policiesDisabled)
        and numCities > 0
        and (freePolicies > 0 or culture >= nextPolicyCost or (ideologyBranchId >= 0 and freeTenets > 0))

    return {
        __is_object = true,
        policies_disabled = policiesDisabled,
        culture = culture,
        culture_per_turn = culturePerTurn,
        next_policy_cost = nextPolicyCost,
        free_policies = freePolicies,
        free_tenets = freeTenets,
        num_cities = numCities,
        can_adopt_now = canAdoptNow,
        ideology_branch_id = (ideologyBranchId >= 0) and ideologyBranchId or nil,
        ideology_branch_type = ideologyBranchType,
        policy_branches = policyBranches,
        unlockable_branches = unlockableBranches,
        adoptable_policies = adoptablePolicies,
        adopted_policies = adoptedPolicies,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Collector.GetUnitPromotions(activePlayerID, unitID)  [F10]
-- 做什么：采集指定己方存活单位的经验、等级、晋升就绪态、已获得晋升与当前可获取晋升清单，
--         供智能体处理 ENDTURN_BLOCKING_UNIT_PROMOTION。
-- 为什么：
--   1. 直接调用 CvGameCore_Expansion2.dll 原生 Unit 只读方法（IsPromotionReady / CanPromote /
--      CanAcquirePromotion / IsHasPromotion / GetExperience / ExperienceNeeded / GetLevel），
--      全程零 UI.SelectUnit 选区副作用，因此可安全纳入 AI 回合只读白名单；
--   2. 严格区分常规晋升与 InstaHeal 立即回血晋升（满血单位不展示 InstaHeal），零缓存。
-- 输入：activePlayerID（当前存活玩家 ID）、unitID（己方单位整数 ID）。
-- 输出：UnitPromotionsDTO 表（带 __is_object = true）；非法/死亡/非己方单位返回错误表。
-- -----------------------------------------------------------------------------
function CAB_Collector.GetUnitPromotions(activePlayerID, unitID)
    local pPlayer, errMsg = isValidAlivePlayer(activePlayerID)
    if pPlayer == nil then
        return makeErrorDto(errMsg)
    end
    if not isInteger(unitID) then
        return makeErrorDto("Invalid unit ID: " .. tostring(unitID))
    end

    local pUnit = pPlayer:GetUnitByID(unitID)
    if not isUnitAlive(pUnit) or pUnit:GetOwner() ~= activePlayerID then
        return makeErrorDto("Unit not found or dead: " .. tostring(unitID))
    end

    local maxHp = getMaxUnitHp(pUnit)
    local damage = pUnit:GetDamage() or 0
    local hp = math.max(0, maxHp - damage)
    local level = (pUnit.GetLevel ~= nil and pUnit:GetLevel()) or 1
    local xp = (pUnit.GetExperience ~= nil and pUnit:GetExperience()) or 0
    local xpNeeded = (pUnit.ExperienceNeeded ~= nil and pUnit:ExperienceNeeded()) or 0

    local isReady = false
    if pUnit.IsPromotionReady ~= nil then
        local okR, resR = pcall(pUnit.IsPromotionReady, pUnit)
        isReady = (okR and resR == true)
    end

    local canPromote = isReady
    if pUnit.CanPromote ~= nil then
        local okP, resP = pcall(pUnit.CanPromote, pUnit)
        if okP then
            canPromote = (resP == true)
        end
    end

    local earnedPromotions = {}
    local availablePromotions = {}

    if GameInfo ~= nil and GameInfo.UnitPromotions ~= nil then
        for promo in GameInfo.UnitPromotions() do
            if promo ~= nil and promo.ID ~= nil and promo.Type ~= nil and promo.Type ~= "" then
                local promoId = promo.ID
                local hasPromo = false
                if pUnit.IsHasPromotion ~= nil then
                    local okH, resH = pcall(pUnit.IsHasPromotion, pUnit, promoId)
                    hasPromo = (okH and resH == true)
                end

                if hasPromo then
                    table.insert(earnedPromotions, {
                        __is_object = true,
                        promotion_id = promoId,
                        promotion_type = promo.Type,
                        name = safeLocale(promo.Description or promo.Type),
                        help = safeLocale(promo.Help or ""),
                    })
                end

                if isReady and promo.CannotBeChosen ~= true and pUnit.CanAcquirePromotion ~= nil then
                    local okAcq, canAcq = pcall(pUnit.CanAcquirePromotion, pUnit, promoId)
                    if okAcq and canAcq == true then
                        local isInstaHeal = (promo.InstaHeal == true)
                        if (not isInstaHeal) or damage > 0 then
                            table.insert(availablePromotions, {
                                __is_object = true,
                                promotion_id = promoId,
                                promotion_type = promo.Type,
                                name = safeLocale(promo.Description or promo.Type),
                                help = safeLocale(promo.Help or ""),
                                is_insta_heal = isInstaHeal,
                            })
                        end
                    end
                end
            end
        end
    end

    return {
        __is_object = true,
        unit_id = pUnit:GetID(),
        unit_type = resolveUnitTypeStr(pUnit:GetUnitType()),
        name = safeLocale(pUnit:GetName()),
        hp = hp,
        max_hp = maxHp,
        level = level,
        experience = xp,
        experience_needed = xpNeeded,
        is_promotion_ready = isReady,
        can_promote = canPromote,
        earned_promotions = earnedPromotions,
        available_promotions = availablePromotions,
    }
end
