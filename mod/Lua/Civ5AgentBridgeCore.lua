-- =============================================================================
-- 文件：Lua/Civ5AgentBridgeCore.lua
-- 做什么：《文明5》智能体指挥系统桥接核心逻辑库（CAB_* 前缀全局函数）：
--   1. SQLite 大载荷自动分片读写（CAB_DbWritePayload / CAB_DbReadPayload）；
--   2. 全局可见态势提取（CAB_BuildTurnOverview）——严格遵守战争迷雾边界（IsVisible / IsRevealed）；
--   3. 指定单位局部战场与合法候选动作枚举（CAB_BuildUnitContextAndCandidates）；
--   4. 单位原子动作下发（CAB_DispatchUnitAction）与动作后增量视野结算对比（CAB_SettlePendingAction）。
--
-- 接口核实依据（本机 CivilizationV.exe 与 CvGameCore_Expansion2.dll 二进制表 + 官方 WorldView.lua / UnitPanel.lua）：
--   Modding.OpenUserData：GetValue / SetValue / Query（CivilizationV.exe 内直接执行 SELECT/INSERT OR REPLACE）；
--   Unit：CanMoveOrAttackInto / CanMoveThrough / CanRangeStrikeAt / CanFortify / CanHeal /
--         MovesLeft / MaxMoves / GetDamage / GetBaseCombatStrength / GetBaseRangedCombatStrength /Range；
--   动作下发：UI.SelectUnit + Game.SelectionListMove / Game.SelectionListGameNetMessage / Game.HandleAction。
-- =============================================================================

include("Civ5AgentBridgeJson")

-- 按需加载 AirRaidLegacyUnits 逻辑库（不同 LuaContext 全局表 _G 隔离，经 VFS include 共享逻辑函数）
local g_HasAirRaidLegacy = pcall(function() include("AirRaidCore") end) and (type(AR_ExecuteStrike) == "function")

-- 单字段分片阈值（默认 3000 字节分片，规避潜在定长缓冲区截断风险，同时保留大载荷单行直写测试能力）
local CAB_CHUNK_SIZE = 3000
local CAB_MOVE_DENOMINATOR = (GameDefines and GameDefines["MOVE_DENOMINATOR"]) or 60
local CAB_MAX_HP = (GameDefines and GameDefines["MAX_HIT_POINTS"]) or 100

-- -----------------------------------------------------------------------------
-- 函数：CAB_DbWritePayload(db, key, strValue, forceChunked)
-- 做什么：将字符串写入 ModUserData SQLite 的 SimpleValues 表；当长度超过阈值或显式开启分片时，
--         按 1-based 槽位写入 key#chunk_1..N 与 key#chunk_count，主槽位仅写短标记 "__CHUNKED__:<len>"。
-- 为什么：防止超长字符串直接写入主槽位触发 C++ 定长缓冲区截断或报错；调用方在末尾写入 rpc_*_req_id 作发布屏障。
-- -----------------------------------------------------------------------------
function CAB_DbWritePayload(db, key, strValue, forceChunked)
    if db == nil then return false end
    local s = tostring(strValue or "")
    if forceChunked or (#s > CAB_CHUNK_SIZE) then
        local totalChunks = math.ceil(#s / CAB_CHUNK_SIZE)
        for i = 1, totalChunks do
            local startIdx = (i - 1) * CAB_CHUNK_SIZE + 1
            local endIdx = math.min(i * CAB_CHUNK_SIZE, #s)
            db.SetValue(key .. "#chunk_" .. tostring(i), s:sub(startIdx, endIdx))
        end
        db.SetValue(key .. "#chunk_count", tostring(totalChunks))
        db.SetValue(key, "__CHUNKED__:" .. tostring(#s))
    else
        db.SetValue(key, s)
        db.SetValue(key .. "#chunk_count", "0")
    end
    return true
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_DbReadPayload(db, key)
-- 做什么：从 SimpleValues 表读取字符串；若存在分片标记（key#chunk_count > 0），自动拼接全部分片返回。
-- -----------------------------------------------------------------------------
function CAB_DbReadPayload(db, key)
    if db == nil then return nil end
    local chunkCountStr = db.GetValue(key .. "#chunk_count")
    local chunkCount = tonumber(chunkCountStr) or 0
    if chunkCount > 0 then
        local parts = {}
        for i = 1, chunkCount do
            parts[i] = tostring(db.GetValue(key .. "#chunk_" .. tostring(i)) or "")
        end
        return table.concat(parts)
    end
    return db.GetValue(key)
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_SerializeUnitSummary(pUnit)
-- 做什么：将己方单位对象序列化为标准 UnitSummaryDTO 表。
-- -----------------------------------------------------------------------------
function CAB_SerializeUnitSummary(pUnit)
    if pUnit == nil or pUnit:IsDead() then return nil end
    local unitInfo = GameInfo.Units[pUnit:GetUnitType()]
    local unitTypeStr = (unitInfo and unitInfo.Type) or tostring(pUnit:GetUnitType())
    local domainStr = "LAND"
    local dType = pUnit:GetDomainType()
    if dType == DomainTypes.DOMAIN_AIR then
        domainStr = "AIR"
    elseif dType == DomainTypes.DOMAIN_SEA then
        domainStr = "SEA"
    end
    local damage = pUnit:GetDamage() or 0
    local hp = math.max(0, CAB_MAX_HP - damage)
    local movesLeft = (pUnit:MovesLeft() or 0) / CAB_MOVE_DENOMINATOR
    local maxMoves = (pUnit:MaxMoves() or 0) / CAB_MOVE_DENOMINATOR

    local isFortified = false
    local okFortTurns, fortTurns = pcall(function() return pUnit:GetFortifyTurns() end)
    if okFortTurns and (fortTurns or 0) > 0 then
        isFortified = true
    end

    -- 参照官方 ActionInfoPanel.lua:444/468，用 IsReadyToMove() 区分“仍有移动力但已 SKIP_TURN/FORTIFY”的单位
    local canAct = (pUnit:MovesLeft() or 0) > 0
    if canAct and pUnit.IsReadyToMove then
        local okReady, isReady = pcall(function() return pUnit:IsReadyToMove() end)
        if okReady then
            canAct = (isReady == true)
        end
    end

    return {
        __is_object = true,
        unit_id = pUnit:GetID(),
        name = Locale.ConvertTextKey(pUnit:GetName()),
        unit_type = unitTypeStr,
        domain = domainStr,
        x = pUnit:GetX(),
        y = pUnit:GetY(),
        hp = hp,
        max_hp = CAB_MAX_HP,
        moves_left = math.floor(movesLeft * 100) / 100,
        max_moves = math.floor(maxMoves * 100) / 100,
        combat_str = pUnit:GetBaseCombatStrength() or 0,
        ranged_str = pUnit:GetBaseRangedCombatStrength() or 0,
        range = pUnit:Range() or 0,
        is_fortified = isFortified,
        can_act = canAct
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_SerializeEnemyUnit(pEnemyUnit)
-- 做什么：将当前视野内可见的敌方/蛮族单位序列化为 EnemyUnitDTO 表。
-- -----------------------------------------------------------------------------
function CAB_SerializeEnemyUnit(pEnemyUnit)
    if pEnemyUnit == nil or pEnemyUnit:IsDead() then return nil end
    local ownerID = pEnemyUnit:GetOwner()
    local pOwner = Players[ownerID]
    local unitInfo = GameInfo.Units[pEnemyUnit:GetUnitType()]
    local unitTypeStr = (unitInfo and unitInfo.Type) or tostring(pEnemyUnit:GetUnitType())
    local damage = pEnemyUnit:GetDamage() or 0
    return {
        __is_object = true,
        enemy_id = tostring(ownerID) .. ":" .. tostring(pEnemyUnit:GetID()),
        owner_id = ownerID,
        owner_name = (pOwner and pOwner:GetName()) or "Unknown",
        is_barbarian = (pOwner and pOwner:IsBarbarian()) or false,
        unit_type = unitTypeStr,
        x = pEnemyUnit:GetX(),
        y = pEnemyUnit:GetY(),
        hp = math.max(0, CAB_MAX_HP - damage),
        combat_str = pEnemyUnit:GetBaseCombatStrength() or 0,
        ranged_str = pEnemyUnit:GetBaseRangedCombatStrength() or 0
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ScanVisibleEnemies(activePlayerID)
-- 做什么：扫描全图所有当前对玩家团队实时可见（pPlot:IsVisible(activeTeam) == true）的非己方单位。
-- 为什么：既用于 TurnOverview 全局敌情汇总，又用于单步动作前后的视野基线对比（Delta Observation）。
-- -----------------------------------------------------------------------------
function CAB_ScanVisibleEnemies(activePlayerID)
    local pActivePlayer = Players[activePlayerID]
    if not pActivePlayer then return {}, {} end
    local activeTeam = pActivePlayer:GetTeam()
    local enemyList = {}
    local enemyMap = {}

    for iPlayer = 0, GameDefines.MAX_PLAYERS - 1 do
        if iPlayer ~= activePlayerID then
            local pOther = Players[iPlayer]
            if pOther and pOther:IsAlive() then
                for pUnit in pOther:Units() do
                    if not pUnit:IsDead() then
                        local pPlot = pUnit:GetPlot()
                        if pPlot and pPlot:IsVisible(activeTeam, false) then
                            local dto = CAB_SerializeEnemyUnit(pUnit)
                            if dto then
                                table.insert(enemyList, dto)
                                enemyMap[dto.enemy_id] = dto
                            end
                        end
                    end
                end
            end
        end
    end
    return enemyList, enemyMap
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_BuildTurnOverview(activePlayerID)
-- 做什么：构建当前回合玩家可见全局态势（对应 03_接口设计说明书 §2.1 TurnOverviewDTO）。
-- -----------------------------------------------------------------------------
function CAB_BuildTurnOverview(activePlayerID)
    local pPlayer = Players[activePlayerID]
    if not pPlayer then
        return { __is_object = true, error = "Invalid activePlayerID" }
    end

    local ourUnits = {}
    for pUnit in pPlayer:Units() do
        local uDto = CAB_SerializeUnitSummary(pUnit)
        if uDto then
            table.insert(ourUnits, uDto)
        end
    end

    local activeTeam = pPlayer:GetTeam()
    local ourCities = {}
    for pCity in pPlayer:Cities() do
        local prodKey = pCity:GetProductionNameKey()
        local prodName = (prodKey and prodKey ~= "") and Locale.ConvertTextKey(prodKey) or "NONE"
        local turnsLeft = pCity:GetProductionTurnsLeft() or 0
        table.insert(ourCities, {
            __is_object = true,
            city_id = pCity:GetID(),
            name = pCity:GetName(),
            x = pCity:GetX(),
            y = pCity:GetY(),
            pop = pCity:GetPopulation(),
            hp = math.max(0, ((pCity.GetMaxHitPoints and pCity:GetMaxHitPoints()) or 200) - (pCity:GetDamage() or 0)),
            current_production = prodName,
            turns_left = turnsLeft
        })
    end

    -- 采集战略资源可用储量（参照 GenericWorldAnchor.lua:157-163）
    local stratRes = { __is_object = true }
    for res in GameInfo.Resources() do
        local okUsage, iUsage = pcall(function() return Game.GetResourceUsageType(res.ID) end)
        if okUsage and iUsage == ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then
            local count = pPlayer:GetNumResourceAvailable(res.ID, true) or 0
            if count > 0 then
                stratRes[res.Type] = count
            end
        end
    end

    -- 扫描已探索的非己方城市（严守战争迷雾：未探索黑雾中的敌城不导出，已探索迷雾城标注 in_fog=true）
    local visibleEnemyCities = {}
    for iPlayer = 0, GameDefines.MAX_PLAYERS - 1 do
        if iPlayer ~= activePlayerID then
            local pOther = Players[iPlayer]
            if pOther and pOther:IsAlive() then
                for pCity in pOther:Cities() do
                    local cPlot = pCity:Plot()
                    if cPlot and cPlot:IsRevealed(activeTeam, false) then
                        local isVis = cPlot:IsVisible(activeTeam, false)
                        table.insert(visibleEnemyCities, {
                            __is_object = true,
                            city_id = tostring(iPlayer) .. ":" .. tostring(pCity:GetID()),
                            owner_name = pOther:GetName(),
                            name = pCity:GetName(),
                            x = pCity:GetX(),
                            y = pCity:GetY(),
                            hp = math.max(0, ((pCity.GetMaxHitPoints and pCity:GetMaxHitPoints()) or 200) - (pCity:GetDamage() or 0)),
                            in_fog = not isVis
                        })
                    end
                end
            end
        end
    end

    local visibleEnemies, _ = CAB_ScanVisibleEnemies(activePlayerID)

    return {
        __is_object = true,
        turn_number = Game.GetGameTurn(),
        active_player_id = activePlayerID,
        player_civ = pPlayer:GetCivilizationShortDescription(),
        yields = {
            __is_object = true,
            gold = pPlayer:GetGold(),
            gold_per_turn = pPlayer:CalculateGoldRate(),
            science_per_turn = pPlayer:GetScience(),
            happiness = pPlayer:GetExcessHappiness(),
            strategic_resources = stratRes
        },
        our_units = ourUnits,
        visible_enemies = visibleEnemies,
        our_cities = ourCities,
        visible_enemy_cities = visibleEnemyCities
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_FindGameActionIndex(actionTypeStr)
-- 做什么：参照 UnitPanel.lua:202-206 遍历 GameInfoActions，查找当前选中单位可合法执行的动作索引。
-- 为什么：驻扎/休整/跳过/攻城器械架设通过 Game.CanHandleAction + Game.HandleAction 触发与官方按钮 100% 等价。
-- -----------------------------------------------------------------------------
function CAB_FindGameActionIndex(actionTypeStr)
    if not GameInfoActions then return nil end
    for iAction = 0, #GameInfoActions, 1 do
        local action = GameInfoActions[iAction]
        if action and action.Type == actionTypeStr then
            if Game.CanHandleAction(iAction, 0, 1) and Game.CanHandleAction(iAction) then
                return iAction
            end
        end
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_InspectPlotUnits(pPlot, activePlayerID)
-- 做什么：扫描可见地块上的单位，当存在军民同格叠栈时优先返回主战单位（IsCombatUnit()）。
-- 为什么：防止工人/大将军后遍历覆盖同格主战部队导致威胁战力漏报。
-- -----------------------------------------------------------------------------
function CAB_InspectPlotUnits(pPlot, activePlayerID)
    local friendlyId = nil
    local friendlyCombat = false
    local enemyDto = nil
    local enemyCombat = false
    local numUnits = pPlot:GetNumUnits()
    for i = 0, numUnits - 1 do
        local pPlotUnit = pPlot:GetUnit(i)
        if pPlotUnit and not pPlotUnit:IsDead() then
            local isCombat = (pPlotUnit.IsCombatUnit and pPlotUnit:IsCombatUnit()) or false
            if pPlotUnit:GetOwner() == activePlayerID then
                if friendlyId == nil or (isCombat and not friendlyCombat) then
                    friendlyId = pPlotUnit:GetID()
                    friendlyCombat = isCombat
                end
            else
                if enemyDto == nil or (isCombat and not enemyCombat) then
                    enemyDto = CAB_SerializeEnemyUnit(pPlotUnit)
                    enemyCombat = isCombat
                end
            end
        end
    end
    return friendlyId, enemyDto
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_CanUnitMoveThrough(pUnit, pPlot)
-- 做什么：调用引擎原生 pUnit:CanMoveThrough(pPlot) 判定单位能否进入指定相邻地块。
-- 为什么：实机+逆向核实原版 BNW CvGameCore_Expansion2.dll (0x102bef50) 确认 Firaxis 在
--         CvLuaUnit::lCanMoveOrAttackInto 中存在官方 Bug（丢弃返回值、硬编码 lua_pushboolean(L, 0) 恒返回 false）；
--         紧邻的 lCanMoveThrough (0x102bf0aa) 正确返回 CvUnit::canMoveThrough(*pkPlot, 0) 的真实布尔值。
-- -----------------------------------------------------------------------------
function CAB_CanUnitMoveThrough(pUnit, pPlot)
    if pUnit == nil or pPlot == nil then return false end
    local ok, res = pcall(function() return pUnit:CanMoveThrough(pPlot) end)
    if ok then
        return res == true
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_HasSameClassFriendlyUnit(pPlot, activePlayerID, isSelfCombat)
-- 做什么：检查目标地块是否已存在同类别（同为战斗单位或同为民用单位）的己方单位，遵循 1UPT 停靠规则。
-- -----------------------------------------------------------------------------
function CAB_HasSameClassFriendlyUnit(pPlot, activePlayerID, isSelfCombat)
    local numUnits = pPlot:GetNumUnits()
    for i = 0, numUnits - 1 do
        local u = pPlot:GetUnit(i)
        if u and (not u:IsDead()) and u:GetOwner() == activePlayerID then
            local uCombat = (u.IsCombatUnit and u:IsCombatUnit()) or false
            if uCombat == isSelfCombat then
                return true
            end
        end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_BuildUnitContextAndCandidates(activePlayerID, unitID, radius)
-- 做什么：提取指定单位周围 radius 格已探索地块详情及引擎原生判定的合法候选动作列表。
-- -----------------------------------------------------------------------------
function CAB_BuildUnitContextAndCandidates(activePlayerID, unitID, radius)
    local pPlayer = Players[activePlayerID]
    if not pPlayer then return { __is_object = true, error = "Invalid player" } end
    local pUnit = pPlayer:GetUnitByID(unitID)
    if not pUnit or pUnit:IsDead() then
        return { __is_object = true, error = "Unit not found or dead: " .. tostring(unitID) }
    end

    local activeTeam = pPlayer:GetTeam()
    local pTeam = Teams[activeTeam]
    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local r = tonumber(radius) or 2
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
            note = note or ""
        })
        actIdx = actIdx + 1
    end

    local scanRadius = r
    if pUnit:GetDomainType() == DomainTypes.DOMAIN_AIR and (pUnit:Range() or 0) > scanRadius then
        scanRadius = pUnit:Range()
    end

    -- 遍历周围地块（仅向 surrounding_tiles 导出已探索 IsRevealed 的地块，严禁泄露黑雾地形与隐军）
    for dx = -scanRadius, scanRadius do
        for dy = -scanRadius, scanRadius do
            local pPlot = Map.GetPlotXY(ux, uy, dx, dy)
            if pPlot then
                local px, py = pPlot:GetX(), pPlot:GetY()
                local dist = Map.PlotDistance(ux, uy, px, py)
                local isRev = pPlot:IsRevealed(activeTeam, false)

                if dist == 1 and (not isRev) and (pUnit:MovesLeft() or 0) > 0 and pUnit:GetDomainType() ~= DomainTypes.DOMAIN_AIR then
                    -- 相邻未探索黑雾格：允许探路移动，但不透传任何黑雾地形或单位信息
                    addCandidate("MOVE_STEP", px, py, 1.0, "Explore adjacent unrevealed hex", nil)
                elseif dist <= scanRadius and isRev then
                    local isVis = pPlot:IsVisible(activeTeam, false)
                    local friendlyId, enemyOnTile = nil, nil
                    if isVis then
                        friendlyId, enemyOnTile = CAB_InspectPlotUnits(pPlot, activePlayerID)
                    end
                    local pPlotCity = pPlot:GetPlotCity()
                    local isHostileCity = false
                    local cityDto = nil
                    if pPlotCity then
                        local cOwner = pPlotCity:GetOwner()
                        isHostileCity = (cOwner ~= activePlayerID) and pTeam and pTeam:IsAtWar(Players[cOwner]:GetTeam())
                        cityDto = {
                            __is_object = true,
                            city_id = pPlotCity:GetID(),
                            owner_id = cOwner,
                            name = pPlotCity:GetName(),
                            is_hostile = isHostileCity
                        }
                    end

                    if dist <= r then
                        local tInfo = GameInfo.Terrains[pPlot:GetTerrainType()]
                        local fId = pPlot:GetFeatureType()
                        local fInfo = (fId and fId >= 0) and GameInfo.Features[fId] or nil
                        local impId = pPlot:GetImprovementType()
                        local impInfo = (isVis and impId and impId >= 0) and GameInfo.Improvements[impId] or nil
                        table.insert(tiles, {
                            __is_object = true,
                            x = px,
                            y = py,
                            distance = dist,
                            visibility = isVis and "VISIBLE" or "REVEALED_FOG",
                            terrain = (tInfo and tInfo.Type) or "UNKNOWN",
                            feature = (fInfo and fInfo.Type) or nil,
                            is_hills = pPlot:IsHills(),
                            has_river = pPlot:IsRiver(),
                            improvement = (impInfo and impInfo.Type) or nil,
                            friendly_unit_id = friendlyId,
                            enemy_unit = enemyOnTile,
                            city = cityDto
                        })
                    end

                    -- 枚举相邻 1 格移动或近战/攻城攻击候选
                    if dist == 1 and (pUnit:MovesLeft() or 0) > 0 and pUnit:GetDomainType() ~= DomainTypes.DOMAIN_AIR then
                        local selfIsCombat = (pUnit.IsCombatUnit and pUnit:IsCombatUnit()) or false
                        local hasWarEnemy = (enemyOnTile ~= nil and pTeam and pTeam:IsAtWar(Players[enemyOnTile.owner_id]:GetTeam()))
                        if hasWarEnemy or isHostileCity then
                            -- 近战攻击：排除远程专属单位（Range > 0）与不可通行/水域域不匹配地形
                            local uDomain = pUnit:GetDomainType()
                            local domainCanMelee = (uDomain == DomainTypes.DOMAIN_LAND and (not pPlot:IsWater()))
                                or (uDomain == DomainTypes.DOMAIN_SEA and (pPlot:IsWater() or isHostileCity))
                            if selfIsCombat and (pUnit:Range() or 0) == 0 and (pUnit:GetBaseCombatStrength() or 0) > 0 and (not pPlot:IsImpassable()) and domainCanMelee then
                                local preview = {
                                    __is_object = true,
                                    target_enemy_type = (enemyOnTile and enemyOnTile.unit_type) or "ENEMY_CITY",
                                    target_hp_before = (enemyOnTile and enemyOnTile.hp) or 100,
                                    terrain_modifier_note = pPlot:IsHills() and "HILLS" or "FLAT"
                                }
                                addCandidate("MELEE_ATTACK", px, py, 1.0, "Melee attack target", preview)
                            end
                        elseif enemyOnTile == nil and (pPlotCity == nil or pPlotCity:GetOwner() == activePlayerID) then
                            if CAB_CanUnitMoveThrough(pUnit, pPlot) and (not CAB_HasSameClassFriendlyUnit(pPlot, activePlayerID, selfIsCombat)) then
                                addCandidate("MOVE_STEP", px, py, 1.0, "Step move to adjacent hex", nil)
                            end
                        end
                    end

                    -- 枚举射程内远程打击或空军空袭候选
                    if dist >= 1 and (pUnit:MovesLeft() or 0) > 0 and (pUnit:Range() or 0) >= dist then
                        local okRange, canRange = pcall(function() return pUnit:CanRangeStrikeAt(px, py, true, false) end)
                        if okRange and canRange then
                            local aType = (pUnit:GetDomainType() == DomainTypes.DOMAIN_AIR) and "AIR_STRIKE" or "RANGE_ATTACK"
                            local preview = enemyOnTile and {
                                __is_object = true,
                                target_enemy_type = enemyOnTile.unit_type,
                                target_hp_before = enemyOnTile.hp,
                                terrain_modifier_note = pPlot:IsHills() and "HILLS" or "FLAT"
                            } or nil
                            addCandidate(aType, px, py, 1.0, aType .. " at (" .. px .. "," .. py .. ")", preview)
                        end
                    end
                end
            end
        end
    end

    -- 若启用 AirRaidLegacyUnits，补充对地打击（敌城/改良地块）AIR_STRIKE 候选
    if g_HasAirRaidLegacy and pUnit:GetDomainType() == DomainTypes.DOMAIN_AIR and (pUnit:MovesLeft() or 0) > 0 then
        local okAr, arTargets = pcall(function() return AR_EnumerateTargets(pUnit) end)
        if okAr and arTargets then
            local existingAir = {}
            for _, c in ipairs(candidates) do
                if c.action_type == "AIR_STRIKE" then
                    existingAir[tostring(c.target_x) .. ":" .. tostring(c.target_y)] = true
                end
            end
            for _, ct in ipairs(arTargets.cities or {}) do
                local key = tostring(ct.x) .. ":" .. tostring(ct.y)
                if not existingAir[key] then
                    addCandidate("AIR_STRIKE", ct.x, ct.y, 1.0, "AirRaidLegacy strike city: " .. tostring(ct.name), nil)
                    existingAir[key] = true
                end
            end
            for _, pt in ipairs(arTargets.plots or {}) do
                local key = tostring(pt.x) .. ":" .. tostring(pt.y)
                if not existingAir[key] then
                    addCandidate("AIR_STRIKE", pt.x, pt.y, 1.0, "AirRaidLegacy strike plot", nil)
                    existingAir[key] = true
                end
            end
        end
    end

    -- 枚举原地驻扎/休整/攻城架设/跳过候选（临时选中后经 Game.CanHandleAction 精确判定并恢复原选中单位）
    if (pUnit:MovesLeft() or 0) > 0 then
        local prevSelected = UI and UI.GetHeadSelectedUnit and UI.GetHeadSelectedUnit() or nil
        if UI and UI.SelectUnit then UI.SelectUnit(pUnit) end

        if CAB_FindGameActionIndex("MISSION_SET_UP_FOR_RANGED_ATTACK") ~= nil then
            addCandidate("SETUP_FOR_RANGED", ux, uy, 1.0, "Set up siege unit for ranged attack", nil)
        end
        if CAB_FindGameActionIndex("MISSION_FORTIFY") ~= nil or CAB_FindGameActionIndex("MISSION_ALERT") ~= nil then
            addCandidate("FORTIFY", ux, uy, 1.0, "Fortify / Alert at current tile", nil)
        else
            local uPlot = pUnit:GetPlot()
            local okFort, canFort = pcall(function() return pUnit:CanFortify(uPlot) end)
            if okFort and canFort then
                addCandidate("FORTIFY", ux, uy, 1.0, "Fortify at current tile", nil)
            end
        end
        if CAB_FindGameActionIndex("MISSION_HEAL") ~= nil then
            addCandidate("HEAL", ux, uy, 1.0, "Heal at current tile", nil)
        else
            local uPlot = pUnit:GetPlot()
            local okHeal, canHeal = pcall(function() return pUnit:CanHeal(uPlot) end)
            if okHeal and canHeal then
                addCandidate("HEAL", ux, uy, 1.0, "Heal at current tile", nil)
            end
        end
        addCandidate("SKIP_TURN", ux, uy, 0.0, "Hold / Skip remaining movement this turn", nil)

        if prevSelected and (not prevSelected:IsDead()) and prevSelected:GetID() ~= pUnit:GetID() then
            UI.SelectUnit(prevSelected)
        end
    end

    return {
        __is_object = true,
        unit = CAB_SerializeUnitSummary(pUnit),
        surrounding_tiles = tiles,
        candidate_actions = candidates
    }
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ExecuteActionImmediate(activePlayerID, unitID, actionType, targetX, targetY)
-- 做什么：选中目标单位并调用官方标准接口执行单步动作，记录动作前视野基线供结算对比。
-- -----------------------------------------------------------------------------
function CAB_ExecuteActionImmediate(activePlayerID, unitID, actionType, targetX, targetY)
    local pPlayer = Players[activePlayerID]
    if not pPlayer then return false, "Invalid activePlayerID", nil end
    local pUnit = pPlayer:GetUnitByID(unitID)
    if not pUnit or pUnit:IsDead() then
        return false, "Unit not found or dead: " .. tostring(unitID), nil
    end

    local tx = tonumber(targetX) or pUnit:GetX()
    local ty = tonumber(targetY) or pUnit:GetY()
    local pTargetPlot = Map.GetPlot(tx, ty)
    if not pTargetPlot then
        return false, "Invalid target plot (" .. tostring(tx) .. "," .. tostring(ty) .. ")", nil
    end

    -- 1. 采集动作前可见敌军、受击目标与已探索地块基线（供结算后计算 newly_spotted_enemies / target_enemy_after / newly_revealed_tiles_count）
    local activeTeam = pPlayer:GetTeam()
    local _, baselineEnemyMap = CAB_ScanVisibleEnemies(activePlayerID)
    local _, targetEnemyBefore = CAB_InspectPlotUnits(pTargetPlot, activePlayerID)
    local revealedBefore = {}
    local ux0, uy0 = pUnit:GetX(), pUnit:GetY()
    for dx = -5, 5 do
        for dy = -5, 5 do
            local rp = Map.GetPlotXY(ux0, uy0, dx, dy)
            if rp and rp:IsRevealed(activeTeam, false) then
                revealedBefore[tostring(rp:GetX()) .. ":" .. tostring(rp:GetY())] = true
            end
        end
    end

    local baselineInfo = {
        activePlayerID = activePlayerID,
        unitID = unitID,
        actionType = actionType,
        targetX = tx,
        targetY = ty,
        beforeX = ux0,
        beforeY = uy0,
        beforeMoves = pUnit:MovesLeft() or 0,
        baselineEnemyMap = baselineEnemyMap,
        targetEnemyBefore = targetEnemyBefore,
        revealedBefore = revealedBefore
    }

    -- 2. 选中目标单位（WorldView.lua & UnitPanel.lua 标准前提）
    UI.SelectUnit(pUnit)

    local function triggerPanelOrPushMission(actionNameList, fallbackMission)
        for _, actName in ipairs(actionNameList) do
            local iAct = CAB_FindGameActionIndex(actName)
            if iAct ~= nil then
                Game.HandleAction(iAct)
                return true
            end
        end
        if fallbackMission ~= nil then
            Game.SelectionListGameNetMessage(
                GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
                fallbackMission, pUnit:GetX(), pUnit:GetY(), 0, false, false
            )
            return true
        end
        return false
    end

    -- 3. 按动作类型分发引擎指令
    if actionType == "MOVE_STEP" or actionType == "MELEE_ATTACK" then
        Game.SelectionListMove(pTargetPlot, false, false, false)
    elseif actionType == "RANGE_ATTACK" then
        local iMission = (pUnit:GetDomainType() == DomainTypes.DOMAIN_AIR) and MissionTypes.MISSION_MOVE_TO or MissionTypes.MISSION_RANGE_ATTACK
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            iMission, tx, ty, 0, false, false
        )
    elseif actionType == "AIR_STRIKE" then
        -- 优先尝试原版空袭（当目标格有可空袭敌军），否则若启用 AirRaidLegacyUnits 则调用 AR_ExecuteStrike 对地打击
        local okRange, canRange = pcall(function() return pUnit:CanRangeStrikeAt(tx, ty, true, false) end)
        if g_HasAirRaidLegacy and (not (okRange and canRange)) then
            local okAr, arRes = pcall(function() return AR_ExecuteStrike(activePlayerID, unitID, tx, ty) end)
            if not okAr or (arRes and arRes.ok == false) then
                return false, "AR_ExecuteStrike failed: " .. tostring(arRes and arRes.reason or arRes), nil
            end
        else
            Game.SelectionListGameNetMessage(
                GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
                MissionTypes.MISSION_MOVE_TO, tx, ty, 0, false, false
            )
        end
    elseif actionType == "SETUP_FOR_RANGED" then
        if not triggerPanelOrPushMission({"MISSION_SET_UP_FOR_RANGED_ATTACK"}, nil) then
            return false, "Cannot set up unit for ranged attack", nil
        end
    elseif actionType == "FORTIFY" then
        triggerPanelOrPushMission({"MISSION_FORTIFY", "MISSION_ALERT", "MISSION_SLEEP"}, MissionTypes.MISSION_FORTIFY)
    elseif actionType == "HEAL" then
        triggerPanelOrPushMission({"MISSION_HEAL"}, MissionTypes.MISSION_HEAL)
    elseif actionType == "SKIP_TURN" then
        if not triggerPanelOrPushMission({"MISSION_SKIP"}, nil) then
            local skipMission = (GameInfoTypes and GameInfoTypes.MISSION_SKIP) or MissionTypes.MISSION_SKIP
            Game.SelectionListGameNetMessage(
                GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
                skipMission, pUnit:GetID(), 0, 0, false
            )
        end
    else
        return false, "Unsupported action_type: " .. tostring(actionType), nil
    end

    return true, nil, baselineInfo
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_CollectSettlementResult(baselineInfo, settleWaitMs)
-- 做什么：在动作结算完成后，采集单位最新状态并计算 newly_spotted_enemies、newly_revealed_tiles_count 与 target_enemy_after。
-- -----------------------------------------------------------------------------
function CAB_CollectSettlementResult(baselineInfo, settleWaitMs)
    local pPlayer = Players[baselineInfo.activePlayerID]
    local activeTeam = pPlayer and pPlayer:GetTeam() or 0
    local pUnit = pPlayer and pPlayer:GetUnitByID(baselineInfo.unitID)
    local unitAfter = CAB_SerializeUnitSummary(pUnit)
    local unitDied = (pUnit == nil or pUnit:IsDead())

    local currentEnemies, currentEnemyMap = CAB_ScanVisibleEnemies(baselineInfo.activePlayerID)
    local newlySpotted = {}
    for _, eDto in ipairs(currentEnemies) do
        if baselineInfo.baselineEnemyMap[eDto.enemy_id] == nil then
            table.insert(newlySpotted, eDto)
        end
    end

    -- 统计本步新揭开迷雾的地块数
    local newlyRevealedCount = 0
    local cx = (unitAfter and unitAfter.x) or baselineInfo.beforeX
    local cy = (unitAfter and unitAfter.y) or baselineInfo.beforeY
    for dx = -5, 5 do
        for dy = -5, 5 do
            local rp = Map.GetPlotXY(cx, cy, dx, dy)
            if rp and rp:IsRevealed(activeTeam, false) then
                local k = tostring(rp:GetX()) .. ":" .. tostring(rp:GetY())
                if not baselineInfo.revealedBefore[k] then
                    newlyRevealedCount = newlyRevealedCount + 1
                end
            end
        end
    end

    -- 计算攻击动作受击敌军的战后残血/击杀状态（保障 Jev LEVEL 1 TARGET_SURVIVED_LOW_HP 精确触发）
    local targetEnemyAfter = nil
    local isAttackAction = (baselineInfo.actionType == "MELEE_ATTACK" or baselineInfo.actionType == "RANGE_ATTACK" or baselineInfo.actionType == "AIR_STRIKE")
    if isAttackAction and baselineInfo.targetEnemyBefore ~= nil then
        local prevEnemy = baselineInfo.targetEnemyBefore
        local liveEnemy = currentEnemyMap[prevEnemy.enemy_id]
        if liveEnemy ~= nil then
            liveEnemy.enemy_killed = false
            targetEnemyAfter = liveEnemy
        else
            targetEnemyAfter = {
                __is_object = true,
                enemy_id = prevEnemy.enemy_id,
                owner_id = prevEnemy.owner_id,
                owner_name = prevEnemy.owner_name,
                is_barbarian = prevEnemy.is_barbarian,
                unit_type = prevEnemy.unit_type,
                x = prevEnemy.x,
                y = prevEnemy.y,
                hp = 0,
                combat_str = prevEnemy.combat_str,
                ranged_str = prevEnemy.ranged_str,
                enemy_killed = true
            }
        end
    end

    return {
        __is_object = true,
        executed = true,
        action_type = baselineInfo.actionType,
        target_x = baselineInfo.targetX,
        target_y = baselineInfo.targetY,
        settle_wait_ms = settleWaitMs,
        unit_died = unitDied,
        unit_after = unitAfter,
        delta_observation = {
            __is_object = true,
            newly_revealed_tiles_count = newlyRevealedCount,
            newly_spotted_enemies = newlySpotted,
            newly_spotted_count = #newlySpotted,
            target_enemy_after = targetEnemyAfter
        }
    }
end
