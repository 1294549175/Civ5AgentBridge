-- =============================================================================
-- 文件：mod/Lua/CAB_TaskExecutor.lua
-- 职责：模块 1（游戏端纯 Lua 桥接 Mod）——子模块 2：游戏内任务执行子模块（CAB_Executor）。
--       负责将智能体下达的单位战术动作、城防远程炮击、城市内政（买建筑/买单位/设生产/买地块）
--       与安全结束回合指令，经严格前置校验后精准驱动《文明5：BNW v1.0.3.279》原生引擎接口，
--       并配合调度层完成两段式异步动画结算与战后增量观测汇总。
--
-- 依赖：仅允许 include("CAB_Config") 与 include("CAB_InfoCollector") 各一次；
--       严禁引入 Civ5AgentBridgeJson、CAB_ExternalIO、CAB_Dispatcher 或 AirRaidCore。
-- 对外契约：
--   * 仅导出唯一全局变量 CAB_Executor（规划共 9 个公开接口，按 WP1~WP4 渐进落盘）：
--       WP1: Initialize
--       WP2: StartUnitAction / StartCityRangeAttack
--       WP3: IsSettlementBusy / FinalizeActionSettlement
--       WP4: PurchaseCityItem / SetCityProduction / PurchaseCityPlot / ExecuteEndTurn
--   * 全部内部校验、动作分发与结算辅助函数一律声明为 local；
--   * 模块私有状态仅保留 s_Initialized，零跨调用实体缓存。
--
-- 安全红线与官方 UI 脚本依据（《docs/M1/M1Sub2/M1Sub2工作计划.md》§2 & §4）：
--   * E-01 非活动回合零写入：所有写操作必须通过 activePlayer 存活、IsTurnActive() 与
--         not Game.IsProcessingMessages() 三重门控；
--   * E-02 校验失败零副作用：前置校验失败时零引擎写调用，临时选区经 pcall 无条件恢复；
--   * E-03 远程攻击防迷雾侧信道：严禁对普通迷雾/黑雾格调用 CanRangeStrikeAt；
--   * E-04 防误宣战与可控显式宣战：默认 allowDeclareWar = false 拒绝攻击非交战中立势力；
--         为 true 时先校验 CanDeclareWar(targetTeam)，全部前置校验通过后再显式 DeclareWar；
--   * E-05 黑雾探路零信息泄露：MOVE_STEP 允许非空军向相邻未探索黑雾探路，不窥探黑雾地形/敌军；
--   * E-06 原生 BNW + IGE 兼容：零跨调用缓存，严禁 CanMoveOrAttackInto / AirRaidCore /
--         SetScriptData / UI.SetInterfaceMode；
--   * 本机官方 UI 参考：WorldView.lua、UnitPanel.lua、ProductionPopup.lua、
--         CityView.lua、ActionInfoPanel.lua。
-- =============================================================================

include("CAB_Config")
include("CAB_InfoCollector")

CAB_Executor = {}

-- 模块唯一私有初始化状态标记（遵循《模块设计说明.md》§4.2，零实体缓存）
local s_Initialized = false

-- -----------------------------------------------------------------------------
-- 第 1 节：内部基础工具与安全守卫（全部声明为 local，严禁污染 _G）
-- -----------------------------------------------------------------------------

-- Initialize 依赖校验清单：CAB_Config 核心键与 CAB_Collector 全部 14 项公开函数
local REQUIRED_CONFIG_KEYS = {
    "DEFAULT_UNIT_SETTLE_SEC",
    "PLOT_BUY_SETTLE_SEC",
    "MAX_SETTLE_TIMEOUT_SEC",
    "DELTA_REVEAL_SCAN_RADIUS",
    "MAX_SCAN_RADIUS",
    "ENABLE_DEBUG_LOG",
}

local REQUIRED_COLLECTOR_FUNCS = {
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
}

-- -----------------------------------------------------------------------------
-- 函数：debugLog(msg)
-- 做什么：按 CAB_Config.ENABLE_DEBUG_LOG 开关输出带模块前缀的调试日志。
-- 为什么：避免生产关闭日志时产生多余输出，且在 CAB_Config 缺失时不抛出运行时错误。
-- 输入：msg（日志文本）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function debugLog(msg)
    if type(CAB_Config) == "table" and CAB_Config.ENABLE_DEBUG_LOG == true then
        print("[CAB_Executor] " .. tostring(msg))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：isInteger(v)
-- 做什么：判断给定值是否为有限整数。
-- 为什么：对外部传入的 playerID / unitID / cityID / 坐标做严格类型守卫，避免引擎崩溃。
-- 输入：v（任意 Lua 值）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function isInteger(v)
    return type(v) == "number" and v == v and v == math.floor(v)
end

-- -----------------------------------------------------------------------------
-- 函数：isUnitAlive(pUnit)
-- 做什么：判定单位对象是否有效存活（非 nil、非 IsDead 且非 IsDelayedDeath）。
-- 为什么：遵循 E-06，过滤已阵亡或处于延迟死亡态的幽灵单位引用。
-- 输入：pUnit（Civ5 Unit 对象或 nil）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function isUnitAlive(pUnit)
    if pUnit == nil then
        return false
    end
    if pUnit.IsDead ~= nil and pUnit:IsDead() == true then
        return false
    end
    if pUnit.IsDelayedDeath ~= nil and pUnit:IsDelayedDeath() == true then
        return false
    end
    return true
end

-- -----------------------------------------------------------------------------
-- 函数：validateActivePlayerWriteGate(activePlayerID)
-- 做什么：执行写操作前统一门控校验（合法玩家 ID、玩家存活、处于活动回合、消息队列非忙）。
-- 为什么：严格落实红线 E-01（非活动回合零写入），防止在 AI 回合或消息队列拥塞时发包。
-- 输入：activePlayerID（预期当前人类玩家整数 ID）。
-- 输出：(ok: boolean, errMsg: string | nil, pPlayer: Player | nil,
--        activeTeam: number | nil, pActiveTeam: Team | nil)。
-- -----------------------------------------------------------------------------
local function validateActivePlayerWriteGate(activePlayerID)
    if not isInteger(activePlayerID) or activePlayerID < 0 then
        return false, "Invalid activePlayerID", nil, nil, nil
    end
    if Players == nil then
        return false, "Players global table is unavailable", nil, nil, nil
    end
    local pPlayer = Players[activePlayerID]
    if pPlayer == nil or pPlayer:IsAlive() ~= true then
        return false, "Active player does not exist or is not alive", nil, nil, nil
    end
    if pPlayer.IsTurnActive == nil or pPlayer:IsTurnActive() ~= true then
        return false, "Player turn is not active", nil, nil, nil
    end
    if Game ~= nil and Game.IsProcessingMessages ~= nil and Game.IsProcessingMessages() == true then
        return false, "Game is currently processing messages", nil, nil, nil
    end
    local activeTeam = pPlayer:GetTeam()
    local pActiveTeam = (Teams ~= nil and activeTeam ~= nil) and Teams[activeTeam] or nil
    if pActiveTeam == nil then
        return false, "Active player team is unavailable", nil, nil, nil
    end
    return true, nil, pPlayer, activeTeam, pActiveTeam
end

-- -----------------------------------------------------------------------------
-- 函数：withTempUnitSelection(pUnit, fn)
-- 做什么：在 pcall 保护下临时选中目标单位执行探测或只读校验，退出前无条件恢复原 UI 选区。
-- 为什么：落实红线 E-02（前置校验失败零副作用）与 E-06（不调用 UI.SetInterfaceMode）。
-- 输入：pUnit（待临时选中的存活单位）、fn（待执行闭包函数）。
-- 输出：(ok: boolean, ...fn 的返回值或错误信息)。
-- -----------------------------------------------------------------------------
local function withTempUnitSelection(pUnit, fn)
    local prevUnit = nil
    if UI ~= nil and UI.GetHeadSelectedUnit ~= nil then
        prevUnit = UI.GetHeadSelectedUnit()
    end

    local function restoreSelection()
        if UI == nil then
            return
        end
        if isUnitAlive(prevUnit) then
            if UI.SelectUnit ~= nil then
                pcall(UI.SelectUnit, prevUnit)
            end
        else
            if UI.ClearSelectionList ~= nil then
                pcall(UI.ClearSelectionList)
            end
        end
    end

    if UI ~= nil and UI.SelectUnit ~= nil then
        UI.SelectUnit(pUnit)
    end
    local results = { pcall(fn) }
    restoreSelection()
    return unpack(results)
end

-- -----------------------------------------------------------------------------
-- 函数：checkHostileOrWarPrecondition(activePlayerID, pActiveTeam, targetOwnerID, allowDeclareWar)
-- 做什么：校验目标归属势力是否处于可攻击的交战态；若为非交战中立势力，按 allowDeclareWar
--         与 pActiveTeam:CanDeclareWar(targetTeam) 决定拦截或生成待提交宣战计划（零写入）。
-- 为什么：拆分为“零写入前置检查 + 发包前显式提交”两步，同时满足 E-02（校验失败零副作用）
--         与 E-04 / D-03（默认防误宣战、allowDeclareWar=true 时无弹窗显式宣战、和约期拦截）。
-- 输入：activePlayerID（己方玩家 ID）、pActiveTeam（己方 Team 对象）、
--       targetOwnerID（目标归属玩家 ID）、allowDeclareWar（boolean | nil）。
-- 输出：(ok: boolean, errMsg: string | nil, warPlan: table | nil)。
--       warPlan 若非 nil 则为 { needDeclare = true, targetOwnerID = int, targetTeam = int }。
-- -----------------------------------------------------------------------------
local function checkHostileOrWarPrecondition(activePlayerID, pActiveTeam, targetOwnerID, allowDeclareWar)
    if not isInteger(targetOwnerID) or targetOwnerID < 0 then
        return false, "Invalid target owner ID", nil
    end
    if targetOwnerID == activePlayerID then
        return false, "Cannot attack own unit or city", nil
    end
    local pTargetPlayer = Players and Players[targetOwnerID] or nil
    if pTargetPlayer == nil or pTargetPlayer:IsAlive() ~= true then
        return false, "Target owner does not exist or is not alive", nil
    end
    -- 蛮族天然处于敌对交战态，无需宣战
    if pTargetPlayer.IsBarbarian ~= nil and pTargetPlayer:IsBarbarian() == true then
        return true, nil, nil
    end

    local activeTeam = Players[activePlayerID]:GetTeam()
    local targetTeam = pTargetPlayer:GetTeam()
    if targetTeam == activeTeam then
        return false, "Cannot attack allied team unit or city", nil
    end
    if pActiveTeam:IsAtWar(targetTeam) == true then
        return true, nil, nil
    end

    -- 非交战中立势力：默认拦截，仅 allowDeclareWar == true 且 CanDeclareWar 通过才放行
    if allowDeclareWar ~= true then
        return false, "Target belongs to neutral player (allowDeclareWar is false)", nil
    end
    if pActiveTeam.CanDeclareWar == nil or pActiveTeam:CanDeclareWar(targetTeam) ~= true then
        return false, "Cannot declare war on target team (e.g. active peace treaty)", nil
    end
    return true, nil, {
        needDeclare = true,
        targetOwnerID = targetOwnerID,
        targetTeam = targetTeam,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：commitDeclareWarIfNeeded(pActiveTeam, warPlan)
-- 做什么：在全部前置校验通过、即将下发攻击指令前，按 warPlan 显式执行 DeclareWar。
-- 为什么：规避 Civ5 引擎在直接攻击中立单位时弹出模态“是否宣战”确认框卡死自动化流程（D-03）。
-- 输入：pActiveTeam（己方 Team 对象）、warPlan（checkHostileOrWarPrecondition 返回值）。
-- 输出：(warDeclared: boolean, declaredInfo: table | nil)。
-- -----------------------------------------------------------------------------
local function commitDeclareWarIfNeeded(pActiveTeam, warPlan)
    if warPlan == nil or warPlan.needDeclare ~= true then
        return false, nil
    end
    pActiveTeam:DeclareWar(warPlan.targetTeam)
    debugLog(
        "Explicitly declared war on player=" .. tostring(warPlan.targetOwnerID)
            .. " team=" .. tostring(warPlan.targetTeam)
    )
    return true, {
        target_owner_id = warPlan.targetOwnerID,
        target_team_id = warPlan.targetTeam,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：getCityAttackRange() / getMaxCityHp(pCity) / getDeltaRevealParams()
-- 做什么：实时读取 GameDefines 与 CAB_Config 结算/射程参数，不做模块顶层缓存。
-- 为什么：严格落实红线 E-06（原生 BNW + IGE 零跨调用缓存），兼容动态配置变更。
-- 输入：可选 pCity（城市对象）。
-- 输出：对应正整数或数值配置。
-- -----------------------------------------------------------------------------
local function getCityAttackRange()
    local r = GameDefines and GameDefines.CITY_ATTACK_RANGE
    if type(r) == "number" and r >= 1 then
        return math.floor(r)
    end
    return 2
end

local function getMaxCityHp(pCity)
    if pCity ~= nil and pCity.GetMaxHitPoints ~= nil then
        local ok, hp = pcall(function() return pCity:GetMaxHitPoints() end)
        if ok and type(hp) == "number" and hp > 0 then
            return hp
        end
    end
    local cfg = GameDefines and GameDefines.MAX_CITY_HIT_POINTS
    if type(cfg) == "number" and cfg > 0 then
        return cfg
    end
    return 200
end

local function getDeltaRevealParams()
    local r = (type(CAB_Config) == "table" and tonumber(CAB_Config.DELTA_REVEAL_SCAN_RADIUS)) or 5
    local maxR = (type(CAB_Config) == "table" and tonumber(CAB_Config.MAX_SCAN_RADIUS)) or 8
    r = math.max(0, math.min(math.floor(r), math.floor(maxR)))
    local rBefore = math.min(r + 1, math.floor(maxR))
    return r, rBefore
end

-- -----------------------------------------------------------------------------
-- 函数：captureDualCenterRevealedSet(activePlayerID, beforeX, beforeY, targetX, targetY)
-- 做什么：按决策 D-04 采集双圆心联合已探索地块集合：
--         CaptureRevealedPlotsSet(id, beforeX, beforeY, min(r+1, MAX_SCAN_RADIUS))
--         ∪ CaptureRevealedPlotsSet(id, targetX, targetY, r)。
-- 为什么：彻底消除单位移动 1 格后，圆周前沿原本已探索格进入新圆心范围造成的揭盲假阳性。
-- 输入：activePlayerID、移动前坐标 (beforeX, beforeY)、目标坐标 (targetX, targetY)。
-- 输出：(revealedBefore: table, scanRadius: number)。
-- -----------------------------------------------------------------------------
local function captureDualCenterRevealedSet(activePlayerID, beforeX, beforeY, targetX, targetY)
    local r, rBefore = getDeltaRevealParams()
    local unionSet = CAB_Collector.CaptureRevealedPlotsSet(activePlayerID, beforeX, beforeY, rBefore)
    if targetX ~= beforeX or targetY ~= beforeY then
        local targetSet = CAB_Collector.CaptureRevealedPlotsSet(activePlayerID, targetX, targetY, r)
        for k, v in pairs(targetSet) do
            if v then
                unionSet[k] = true
            end
        end
    end
    return unionSet, r
end

-- -----------------------------------------------------------------------------
-- 函数：captureTargetCitySnapshot(pPlot, activePlayerID, activeTeam)
-- 做什么：当已探索目标格存在非己方城市时，采集战前城市快照供 WP3 结算比对。
-- 为什么：遵循 D-04 为攻城与城市炮击提供 target_city_after 基线，同时严守 E-05 不窥探黑雾。
-- 输入：pPlot（目标地块）、activePlayerID（当前玩家 ID）、activeTeam（当前队伍 ID）。
-- 输出：战前城市快照表或 nil。
-- -----------------------------------------------------------------------------
local function captureTargetCitySnapshot(pPlot, activePlayerID, activeTeam)
    if pPlot == nil or pPlot:IsRevealed(activeTeam, false) ~= true then
        return nil
    end
    local pPlotCity = pPlot:GetPlotCity()
    if pPlotCity == nil then
        return nil
    end
    local cOwner = pPlotCity:GetOwner()
    if cOwner == activePlayerID then
        return nil
    end
    local maxHp = getMaxCityHp(pPlotCity)
    local dmg = pPlotCity:GetDamage() or 0
    return {
        city_id = tostring(cOwner) .. ":" .. tostring(pPlotCity:GetID()),
        raw_city_id = pPlotCity:GetID(),
        owner_id = cOwner,
        name = pPlotCity:GetName() or "",
        x = pPlotCity:GetX(),
        y = pPlotCity:GetY(),
        hp = math.max(0, maxHp - dmg),
        max_hp = maxHp,
    }
end

-- 支持的 8 种单位战术动作白名单
local VALID_UNIT_ACTIONS = {
    MOVE_STEP = true,
    MELEE_ATTACK = true,
    RANGE_ATTACK = true,
    AIR_STRIKE = true,
    SETUP_FOR_RANGED = true,
    FORTIFY = true,
    HEAL = true,
    SKIP_TURN = true,
}

local IN_PLACE_UNIT_ACTIONS = {
    SETUP_FOR_RANGED = true,
    FORTIFY = true,
    HEAL = true,
    SKIP_TURN = true,
}

-- 保留对基础守卫的局部引用（WP2~WP4 各公开接口直接复用）
local _INTERNAL_GUARDS = {
    debugLog = debugLog,
    isInteger = isInteger,
    isUnitAlive = isUnitAlive,
    validateActivePlayerWriteGate = validateActivePlayerWriteGate,
    withTempUnitSelection = withTempUnitSelection,
    checkHostileOrWarPrecondition = checkHostileOrWarPrecondition,
    commitDeclareWarIfNeeded = commitDeclareWarIfNeeded,
}

-- -----------------------------------------------------------------------------
-- 第 2 节：公开接口 E1 — CAB_Executor.Initialize
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.Initialize()
-- 做什么：校验 CAB_Config 与 CAB_Collector 全部依赖项已加载就绪，并置位初始化标记。
-- 为什么：确保调度层在运行期调用任何执行接口前可明确感知依赖完整性；严格遵循原生 BNW
--         基线，不探测或引入任何外部空袭 Mod。
-- 输入：无。
-- 输出：boolean（依赖全部完备返回 true，任一缺失返回 false）。
-- -----------------------------------------------------------------------------
function CAB_Executor.Initialize()
    s_Initialized = false

    if type(CAB_Config) ~= "table" then
        debugLog("Initialize failed: CAB_Config is not loaded")
        return false
    end
    for _, key in ipairs(REQUIRED_CONFIG_KEYS) do
        if CAB_Config[key] == nil then
            debugLog("Initialize failed: CAB_Config." .. tostring(key) .. " is missing")
            return false
        end
    end

    if type(CAB_Collector) ~= "table" then
        debugLog("Initialize failed: CAB_Collector is not loaded")
        return false
    end
    for _, fnName in ipairs(REQUIRED_COLLECTOR_FUNCS) do
        if type(CAB_Collector[fnName]) ~= "function" then
            debugLog("Initialize failed: CAB_Collector." .. tostring(fnName) .. " is missing")
            return false
        end
    end

    -- 确认内部守卫表完备
    if _INTERNAL_GUARDS == nil then
        return false
    end

    s_Initialized = true
    debugLog("Initialized successfully (native BNW v1.0.3.279 baseline)")
    return s_Initialized
end

-- -----------------------------------------------------------------------------
-- 第 3 节：公开接口 E2 / E3 — 单位战术动作与城防远程炮击下发（WP2）
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.StartUnitAction(activePlayerID, unitID, actionType, targetX, targetY, allowDeclareWar)
-- 做什么：对 8 种单位战术动作执行同源前置校验，采集战前视野/敌军/双圆心揭盲基线，
--         必要时执行受控无弹窗显式宣战，随后调用原生 BNW 官方指令下发动作。
-- 为什么：
--   1. 严格落实 E-01（活动回合与消息队列门控）与 E-02（任何校验失败零写副作用且恢复选区）；
--   2. 严格落实 E-03（远程/空袭严禁探测普通迷雾与黑雾格，防侧信道泄露隐匿敌军）；
--   3. 严格落实 E-04 / D-02 / D-03（默认防误宣战，allowDeclareWar=true 经 CanDeclareWar
--      守卫后显式 DeclareWar 规避游戏弹窗卡死）；
--   4. 严格落实 E-05（相邻黑雾探路零信息泄露）与 E-06（零 CanMoveOrAttackInto / AirRaidCore）。
-- 输入：
--   activePlayerID (int)       - 当前人类玩家 ID
--   unitID (int)               - 己方单位 ID
--   actionType (string)        - 8 种动作枚举之一
--   targetX, targetY (int|nil) - 目标格坐标（原地动作可省略，默认取单位当前格）
--   allowDeclareWar (bool|nil) - 向后兼容可选参数，默认 false
-- 输出：(ok: boolean, errMsg: string | nil, baselineContext: table | nil)。
-- -----------------------------------------------------------------------------
function CAB_Executor.StartUnitAction(activePlayerID, unitID, actionType, targetX, targetY, allowDeclareWar)
    -- 1. E-01 活动回合与消息队列门控
    local gateOk, gateErr, pPlayer, activeTeam, pActiveTeam = validateActivePlayerWriteGate(activePlayerID)
    if not gateOk then
        return false, gateErr, nil
    end

    -- 2. 基础入参与单位存活性校验
    if not isInteger(unitID) then
        return false, "Invalid unitID: " .. tostring(unitID), nil
    end
    if type(actionType) ~= "string" or not VALID_UNIT_ACTIONS[actionType] then
        return false, "Unsupported actionType: " .. tostring(actionType), nil
    end

    local pUnit = pPlayer:GetUnitByID(unitID)
    if not isUnitAlive(pUnit) or pUnit:GetOwner() ~= activePlayerID then
        return false, "Unit not found, dead, or not owned by active player: " .. tostring(unitID), nil
    end

    local movesLeft = pUnit:MovesLeft() or 0
    if movesLeft <= 0 then
        return false, "Unit has no moves left", nil
    end

    local ux, uy = pUnit:GetX(), pUnit:GetY()
    local isInPlace = IN_PLACE_UNIT_ACTIONS[actionType] == true

    local tx, ty
    if isInPlace then
        if targetX ~= nil and not isInteger(targetX) then
            return false, "Invalid targetX: " .. tostring(targetX), nil
        end
        if targetY ~= nil and not isInteger(targetY) then
            return false, "Invalid targetY: " .. tostring(targetY), nil
        end
        tx, ty = ux, uy
    else
        if not isInteger(targetX) or not isInteger(targetY) then
            return false, "Invalid target coordinates (" .. tostring(targetX) .. "," .. tostring(targetY) .. ")", nil
        end
        tx, ty = targetX, targetY
    end

    if Map == nil or Map.GetPlot == nil then
        return false, "Map global is unavailable", nil
    end
    local pTargetPlot = Map.GetPlot(tx, ty)
    if pTargetPlot == nil then
        return false, "Target plot out of map bounds (" .. tostring(tx) .. "," .. tostring(ty) .. ")", nil
    end

    local dist = Map.PlotDistance(ux, uy, tx, ty)
    local uDomain = pUnit:GetDomainType()
    local isAirUnit = (DomainTypes ~= nil and uDomain == DomainTypes.DOMAIN_AIR)
    local unitRange = math.max(0, math.floor(pUnit:Range() or 0))
    local selfIsCombat = (pUnit.IsCombatUnit ~= nil and pUnit:IsCombatUnit() == true) or false

    -- 3. 分动作执行同源前置校验（本阶段零引擎写调用；若临时切换选区则无条件恢复）
    local warPlan = nil
    local needFogNeutralCityDeclareFirst = false
    local resolvedActionIndex = nil
    local fallbackMission = nil
    local targetEnemyBefore = nil
    local targetCityBefore = nil

    if actionType == "MOVE_STEP" then
        if isAirUnit then
            return false, "Air unit cannot execute MOVE_STEP", nil
        end
        if dist ~= 1 then
            return false, "MOVE_STEP requires adjacent target plot (distance == 1)", nil
        end

        local isRev = pTargetPlot:IsRevealed(activeTeam, false) == true
        if isRev then
            local isVis = pTargetPlot:IsVisible(activeTeam, false) == true
            if isVis then
                local _, enemyOnTile = CAB_Collector.InspectPlotUnits(pTargetPlot, activePlayerID)
                if enemyOnTile ~= nil then
                    return false, "Target plot has a visible non-friendly unit; use MELEE_ATTACK", nil
                end
            end
            local pPlotCity = pTargetPlot:GetPlotCity()
            if pPlotCity ~= nil and pPlotCity:GetOwner() ~= activePlayerID then
                return false, "Target plot has a non-friendly city; use MELEE_ATTACK", nil
            end
            if not CAB_Collector.CanUnitMoveThrough(pUnit, pTargetPlot) then
                return false, "Unit cannot move through target plot", nil
            end
            if CAB_Collector.HasSameClassFriendlyUnit(pTargetPlot, activePlayerID, selfIsCombat) then
                return false, "Target plot already has a same-class friendly unit (1UPT)", nil
            end
        end
        -- E-05：未探索黑雾格（not isRev）直接允许相邻探路，严禁读取黑雾地形/单位/城市

    elseif actionType == "MELEE_ATTACK" then
        if isAirUnit then
            return false, "Air unit cannot execute MELEE_ATTACK", nil
        end
        if dist ~= 1 then
            return false, "MELEE_ATTACK requires adjacent target plot (distance == 1)", nil
        end
        local unitCanAttack = true
        if pUnit.IsCanAttack ~= nil then
            local okCanAtk, canAtkRes = pcall(function() return pUnit:IsCanAttack() end)
            if okCanAtk then
                unitCanAttack = (canAtkRes == true)
            end
        end
        if (not selfIsCombat) or (not unitCanAttack) or unitRange ~= 0 or (pUnit:GetBaseCombatStrength() or 0) <= 0 then
            return false, "Unit is not capable of MELEE_ATTACK", nil
        end
        if pTargetPlot:IsRevealed(activeTeam, false) ~= true then
            return false, "Cannot MELEE_ATTACK an unrevealed black-fog plot", nil
        end
        if pTargetPlot:IsImpassable() == true then
            return false, "Target plot is impassable for MELEE_ATTACK", nil
        end

        local isVis = pTargetPlot:IsVisible(activeTeam, false) == true
        local enemyOnTile = nil
        if isVis then
            _, enemyOnTile = CAB_Collector.InspectPlotUnits(pTargetPlot, activePlayerID)
        end
        local pPlotCity = pTargetPlot:GetPlotCity()
        local targetCity = (pPlotCity ~= nil and pPlotCity:GetOwner() ~= activePlayerID) and pPlotCity or nil
        if enemyOnTile == nil and targetCity == nil then
            return false, "No visible enemy unit or non-friendly city at target plot", nil
        end

        local domainCanMelee = false
        if DomainTypes ~= nil then
            if uDomain == DomainTypes.DOMAIN_LAND then
                domainCanMelee = not (pTargetPlot:IsWater() == true)
            elseif uDomain == DomainTypes.DOMAIN_SEA then
                domainCanMelee = (pTargetPlot:IsWater() == true) or (targetCity ~= nil)
            end
        end
        if not domainCanMelee then
            return false, "Unit domain cannot melee attack target terrain", nil
        end

        local targetOwnerID = (enemyOnTile ~= nil) and enemyOnTile.owner_id or targetCity:GetOwner()
        local warOk, warErr, plan = checkHostileOrWarPrecondition(activePlayerID, pActiveTeam, targetOwnerID, allowDeclareWar)
        if not warOk then
            return false, warErr, nil
        end
        warPlan = plan
        targetEnemyBefore = enemyOnTile
        targetCityBefore = captureTargetCitySnapshot(pTargetPlot, activePlayerID, activeTeam)

    elseif actionType == "RANGE_ATTACK" or actionType == "AIR_STRIKE" then
        if actionType == "RANGE_ATTACK" and isAirUnit then
            return false, "Air unit must use AIR_STRIKE instead of RANGE_ATTACK", nil
        end
        if actionType == "AIR_STRIKE" and (not isAirUnit) then
            return false, "Only air units can execute AIR_STRIKE", nil
        end
        if unitRange <= 0 or dist < 1 or dist > unitRange then
            return false, "Target plot is out of unit attack range", nil
        end

        -- E-03 防迷雾侧信道：严禁对黑雾或普通迷雾（非已探索非己方城市）调用 CanRangeStrikeAt
        local isRev = pTargetPlot:IsRevealed(activeTeam, false) == true
        if not isRev then
            return false, "Cannot strike an unrevealed black-fog plot", nil
        end
        local isVis = pTargetPlot:IsVisible(activeTeam, false) == true
        local pPlotCity = pTargetPlot:GetPlotCity()
        local targetCity = (pPlotCity ~= nil and pPlotCity:GetOwner() ~= activePlayerID) and pPlotCity or nil
        if (not isVis) and (targetCity == nil) then
            return false, "Target plot is in fog of war (not visible and not a known city)", nil
        end

        local enemyOnTile = nil
        if isVis then
            _, enemyOnTile = CAB_Collector.InspectPlotUnits(pTargetPlot, activePlayerID)
        end
        if enemyOnTile == nil and targetCity == nil then
            return false, "No visible non-invisible enemy unit or known non-friendly city at target plot", nil
        end

        local targetOwnerID = (enemyOnTile ~= nil) and enemyOnTile.owner_id or targetCity:GetOwner()
        local warOk, warErr, plan = checkHostileOrWarPrecondition(activePlayerID, pActiveTeam, targetOwnerID, allowDeclareWar)
        if not warOk then
            return false, warErr, nil
        end
        warPlan = plan

        if warPlan == nil then
            -- 已交战目标（含实时可见格与已探索交战敌城）：按原生 BNW 参数 (tx, ty, true, false) 校验
            local okRange, canRange = pcall(function()
                return pUnit:CanRangeStrikeAt(tx, ty, true, false)
            end)
            if not (okRange and canRange == true) then
                return false, "Unit cannot range strike target plot", nil
            end
        elseif isVis then
            -- 实时可见中立目标 + allowDeclareWar=true：以 bNeedWar=false 预检射程/视线/架设，
            -- 失败时零宣战零写入（E-02），且因 isVis==true 严格满足 E-03
            local okRange, canRange = pcall(function()
                return pUnit:CanRangeStrikeAt(tx, ty, false, false)
            end)
            if not (okRange and canRange == true) then
                return false, "Unit cannot range strike target plot", nil
            end
        else
            -- 已探索但处于迷雾中的中立城市 + allowDeclareWar=true：
            -- 先于发包阶段显式宣战使其成为交战敌城，再以 (tx, ty, true, false) 核验，严守 E-03
            needFogNeutralCityDeclareFirst = true
        end

        targetEnemyBefore = enemyOnTile
        targetCityBefore = captureTargetCitySnapshot(pTargetPlot, activePlayerID, activeTeam)

    elseif actionType == "SETUP_FOR_RANGED" then
        local probeOk, foundIdx = withTempUnitSelection(pUnit, function()
            return CAB_Collector.FindGameActionIndex("MISSION_SET_UP_FOR_RANGED_ATTACK")
        end)
        if not probeOk or foundIdx == nil then
            return false, "Unit cannot set up for ranged attack", nil
        end
        resolvedActionIndex = foundIdx

    elseif actionType == "FORTIFY" then
        local probeOk, foundIdx, canFallback = withTempUnitSelection(pUnit, function()
            local idx = CAB_Collector.FindGameActionIndex("MISSION_FORTIFY")
                or CAB_Collector.FindGameActionIndex("MISSION_ALERT")
                or CAB_Collector.FindGameActionIndex("MISSION_SLEEP")
            if idx ~= nil then
                return idx, false
            end
            local uPlot = pUnit:GetPlot()
            if uPlot ~= nil and pUnit.CanFortify ~= nil then
                local okF, resF = pcall(function() return pUnit:CanFortify(uPlot) end)
                if okF and resF == true then
                    return nil, true
                end
            end
            return nil, false
        end)
        if not probeOk or (foundIdx == nil and not canFallback) then
            return false, "Unit cannot fortify at current plot", nil
        end
        resolvedActionIndex = foundIdx
        if foundIdx == nil then
            fallbackMission = MissionTypes and MissionTypes.MISSION_FORTIFY or nil
        end

    elseif actionType == "HEAL" then
        local probeOk, foundIdx, canFallback = withTempUnitSelection(pUnit, function()
            local idx = CAB_Collector.FindGameActionIndex("MISSION_HEAL")
            if idx ~= nil then
                return idx, false
            end
            local uPlot = pUnit:GetPlot()
            if uPlot ~= nil and pUnit.CanHeal ~= nil then
                local okH, resH = pcall(function() return pUnit:CanHeal(uPlot) end)
                if okH and resH == true then
                    return nil, true
                end
            end
            return nil, false
        end)
        if not probeOk or (foundIdx == nil and not canFallback) then
            return false, "Unit cannot heal at current plot", nil
        end
        resolvedActionIndex = foundIdx
        if foundIdx == nil then
            fallbackMission = MissionTypes and MissionTypes.MISSION_HEAL or nil
        end

    elseif actionType == "SKIP_TURN" then
        if pUnit.IsReadyToMove ~= nil then
            local okReady, isReady = pcall(function() return pUnit:IsReadyToMove() end)
            if okReady and isReady == false then
                return false, "Unit is not ready to move (already skipped or fortified)", nil
            end
        end
        local probeOk, foundIdx = withTempUnitSelection(pUnit, function()
            return CAB_Collector.FindGameActionIndex("MISSION_SKIP")
        end)
        if probeOk and foundIdx ~= nil then
            resolvedActionIndex = foundIdx
        else
            fallbackMission = (MissionTypes and MissionTypes.MISSION_SKIP)
                or (GameInfoTypes and GameInfoTypes.MISSION_SKIP)
        end
    end

    -- 4. 采集动作前基线（双圆心联合揭盲 + 全局可见敌军映射）
    local _, baselineEnemyMap = CAB_Collector.GetVisibilitySummary(activePlayerID)
    local revealedBefore, revealScanRadius = captureDualCenterRevealedSet(activePlayerID, ux, uy, tx, ty)

    -- 5. 提交可控显式宣战（若需要）
    local warDeclared, warDeclaredInfo = commitDeclareWarIfNeeded(pActiveTeam, warPlan)
    if needFogNeutralCityDeclareFirst then
        local okRange, canRange = pcall(function()
            return pUnit:CanRangeStrikeAt(tx, ty, true, false)
        end)
        if not (okRange and canRange == true) then
            return false, "Unit cannot range strike target city after declaring war", nil
        end
    end

    -- 6. 选中单位并下发原生 BNW 官方引擎指令
    if UI ~= nil and UI.SelectUnit ~= nil then
        UI.SelectUnit(pUnit)
    end

    if actionType == "MOVE_STEP" or actionType == "MELEE_ATTACK" then
        Game.SelectionListMove(pTargetPlot, false, false, false)
    elseif actionType == "RANGE_ATTACK" then
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            MissionTypes.MISSION_RANGE_ATTACK,
            tx, ty, 0, false, false
        )
    elseif actionType == "AIR_STRIKE" then
        -- 原生 BNW 空袭使用 MISSION_MOVE_TO（WorldView.lua:683 "Air strikes are moves"）
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            MissionTypes.MISSION_MOVE_TO,
            tx, ty, 0, false, false
        )
    elseif resolvedActionIndex ~= nil then
        Game.HandleAction(resolvedActionIndex)
    elseif actionType == "SKIP_TURN" then
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            fallbackMission,
            pUnit:GetID(), 0, 0, false
        )
    elseif fallbackMission ~= nil then
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            fallbackMission,
            ux, uy, 0, false, false
        )
    end

    -- 7. 组装两段式异步结算 baselineContext 返回调度层
    local baselineContext = {
        settlementKind = "UNIT_ACTION",
        activePlayerID = activePlayerID,
        unitID = unitID,
        actionType = actionType,
        targetX = tx,
        targetY = ty,
        beforeX = ux,
        beforeY = uy,
        beforeMoves = movesLeft,
        revealScanRadius = revealScanRadius,
        revealedBefore = revealedBefore,
        baselineEnemyMap = baselineEnemyMap,
        targetEnemyBefore = targetEnemyBefore,
        targetCityBefore = targetCityBefore,
        warDeclared = warDeclared,
        warDeclaredInfo = warDeclaredInfo,
        minWaitSec = (type(CAB_Config) == "table" and CAB_Config.DEFAULT_UNIT_SETTLE_SEC) or 0.35,
        maxTimeoutSec = (type(CAB_Config) == "table" and CAB_Config.MAX_SETTLE_TIMEOUT_SEC) or 1.50,
    }
    return true, nil, baselineContext
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.StartCityRangeAttack(activePlayerID, cityID, targetX, targetY, allowDeclareWar)
-- 做什么：校验己方城市远程反击合法性并驱动城防炮击射程内实时可见敌军，返回异步结算基线。
-- 为什么：
--   1. 严格落实 E-01（活动回合与消息队列门控）、E-02（失败零写入、不改变选区）；
--   2. 严格落实 E-03（目标格必须实时可见且经 InspectPlotUnits 过滤隐形敌军，严禁对迷雾/黑雾
--      调用 CanRangeStrikeAt）与 E-04 / D-03（默认防误宣战，allowDeclareWar=true 可控宣战）；
--   3. 严格参照本机官方 WorldView.lua:519 调用序列（ClearSelectionList -> SelectCity ->
--      SelectedCitiesGameNetMessage -> SpecificCityInfoDirty -> ClearSelectedCities）。
-- 输入：
--   activePlayerID (int)       - 当前人类玩家 ID
--   cityID (int)               - 己方城市 ID
--   targetX, targetY (int)     - 目标格坐标
--   allowDeclareWar (bool|nil) - 向后兼容可选参数，默认 false
-- 输出：(ok: boolean, errMsg: string | nil, baselineContext: table | nil)。
-- -----------------------------------------------------------------------------
function CAB_Executor.StartCityRangeAttack(activePlayerID, cityID, targetX, targetY, allowDeclareWar)
    -- 1. E-01 活动回合与消息队列门控
    local gateOk, gateErr, pPlayer, activeTeam, pActiveTeam = validateActivePlayerWriteGate(activePlayerID)
    if not gateOk then
        return false, gateErr, nil
    end

    -- 2. 参数与己方城市校验
    if not isInteger(cityID) then
        return false, "Invalid cityID: " .. tostring(cityID), nil
    end
    if not isInteger(targetX) or not isInteger(targetY) then
        return false, "Invalid target coordinates (" .. tostring(targetX) .. "," .. tostring(targetY) .. ")", nil
    end

    local pCity = pPlayer:GetCityByID(cityID)
    if pCity == nil or pCity:GetOwner() ~= activePlayerID then
        return false, "City not found or not owned by active player: " .. tostring(cityID), nil
    end

    local canStrikeNow = false
    if pCity.CanRangeStrikeNow ~= nil then
        local okNow, resNow = pcall(function() return pCity:CanRangeStrikeNow() end)
        if okNow and resNow == true then
            canStrikeNow = true
        end
    end
    if not canStrikeNow then
        return false, "City cannot range strike right now", nil
    end

    if Map == nil or Map.GetPlot == nil then
        return false, "Map global is unavailable", nil
    end
    local pTargetPlot = Map.GetPlot(targetX, targetY)
    if pTargetPlot == nil then
        return false, "Target plot out of map bounds (" .. tostring(targetX) .. "," .. tostring(targetY) .. ")", nil
    end

    -- 3. 实时读取 CITY_ATTACK_RANGE 校验射程（E-06 零缓存）
    local cx, cy = pCity:GetX(), pCity:GetY()
    local dist = Map.PlotDistance(cx, cy, targetX, targetY)
    local attackRange = getCityAttackRange()
    if dist < 1 or dist > attackRange then
        return false, "Target plot is out of city attack range", nil
    end

    -- 4. E-03 迷雾防侧信道：城防炮击目标格必须实时可见，严禁对迷雾/黑雾调用 CanRangeStrikeAt
    if pTargetPlot:IsVisible(activeTeam, false) ~= true then
        return false, "Target plot is not currently visible", nil
    end

    -- 5. 复用 H4 过滤隐形敌军，并执行 E-04 交战/宣战前置检查
    local _, enemyOnTile = CAB_Collector.InspectPlotUnits(pTargetPlot, activePlayerID)
    if enemyOnTile == nil then
        return false, "No visible non-invisible enemy unit at target plot", nil
    end

    local warOk, warErr, warPlan = checkHostileOrWarPrecondition(
        activePlayerID, pActiveTeam, enemyOnTile.owner_id, allowDeclareWar
    )
    if not warOk then
        return false, warErr, nil
    end

    -- 6. 引擎级射程/视线合法性校验（中立待宣战传 bNeedWar=false，确保失败零宣战 E-02）
    local needWar = (warPlan == nil)
    local okAt, canAt = pcall(function()
        return pCity:CanRangeStrikeAt(targetX, targetY, needWar, true)
    end)
    if not (okAt and canAt == true) then
        return false, "City cannot range strike target plot", nil
    end

    -- 7. 采集战前基线
    local _, baselineEnemyMap = CAB_Collector.GetVisibilitySummary(activePlayerID)
    local revealedBefore, revealScanRadius = captureDualCenterRevealedSet(activePlayerID, cx, cy, targetX, targetY)
    local targetCityBefore = captureTargetCitySnapshot(pTargetPlot, activePlayerID, activeTeam)

    -- 8. 提交可控显式宣战（若需要），并按 WorldView.lua:519 序列下发城防炮击
    local warDeclared, warDeclaredInfo = commitDeclareWarIfNeeded(pActiveTeam, warPlan)

    if UI ~= nil and UI.ClearSelectionList ~= nil then
        UI.ClearSelectionList()
    end
    if UI ~= nil and UI.SelectCity ~= nil then
        UI.SelectCity(pCity)
    end
    Game.SelectedCitiesGameNetMessage(
        GameMessageTypes.GAMEMESSAGE_DO_TASK,
        TaskTypes.TASK_RANGED_ATTACK,
        targetX,
        targetY
    )
    if Events ~= nil and Events.SpecificCityInfoDirty ~= nil then
        local updateType = (CityUpdateTypes and CityUpdateTypes.CITY_UPDATE_TYPE_BANNER) or 1
        pcall(Events.SpecificCityInfoDirty, activePlayerID, cityID, updateType)
    end
    if UI ~= nil and UI.ClearSelectedCities ~= nil then
        UI.ClearSelectedCities()
    end

    -- 9. 组装两段式异步结算 baselineContext
    local baselineContext = {
        settlementKind = "CITY_ATTACK",
        activePlayerID = activePlayerID,
        cityID = cityID,
        actionType = "CITY_RANGE_ATTACK",
        targetX = targetX,
        targetY = targetY,
        beforeX = cx,
        beforeY = cy,
        revealScanRadius = revealScanRadius,
        revealedBefore = revealedBefore,
        baselineEnemyMap = baselineEnemyMap,
        targetEnemyBefore = enemyOnTile,
        targetCityBefore = targetCityBefore,
        warDeclared = warDeclared,
        warDeclaredInfo = warDeclaredInfo,
        minWaitSec = (type(CAB_Config) == "table" and CAB_Config.DEFAULT_UNIT_SETTLE_SEC) or 0.35,
        maxTimeoutSec = (type(CAB_Config) == "table" and CAB_Config.MAX_SETTLE_TIMEOUT_SEC) or 1.50,
    }
    return true, nil, baselineContext
end

-- -----------------------------------------------------------------------------
-- 第 4 节：公开接口 E8 / E9 — 两段式异步结算与精准增量观测（WP3）
-- -----------------------------------------------------------------------------

local ATTACK_UNIT_ACTIONS = {
    MELEE_ATTACK = true,
    RANGE_ATTACK = true,
    AIR_STRIKE = true,
}

-- -----------------------------------------------------------------------------
-- 函数：safeCallBool(obj, methodName)
-- 做什么：经 pcall 安全调用引擎对象的无参布尔方法（如 IsBusy / IsFighting）。
-- 为什么：避免在部分对象缺省方法或边缘状态下抛出未捕获 Lua 运行时错误。
-- 输入：obj（引擎对象或 nil）、methodName（方法名字符串）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function safeCallBool(obj, methodName)
    if obj == nil or obj[methodName] == nil then
        return false
    end
    local ok, res = pcall(function() return obj[methodName](obj) end)
    return ok and res == true
end

-- -----------------------------------------------------------------------------
-- 函数：normalizeWaitMs(settleWaitMs)
-- 做什么：将外部传入的结算等待毫秒数规范化为有限数值，非法值回退为 0。
-- 为什么：确保序列化 DTO 中 settle_wait_ms 始终为合法 JSON 数值，零异常。
-- 输入：settleWaitMs（number | nil）。
-- 输出：number。
-- -----------------------------------------------------------------------------
local function normalizeWaitMs(settleWaitMs)
    if type(settleWaitMs) == "number" and settleWaitMs == settleWaitMs then
        return settleWaitMs
    end
    return 0
end

-- -----------------------------------------------------------------------------
-- 函数：resolvePlotFromCoords(x, y)
-- 做什么：校验整数坐标并通过 Map.GetPlot 安全获取地块对象。
-- 为什么：避免非法或越界坐标传入 Map.GetPlot 触发异常。
-- 输入：x, y（坐标）。
-- 输出：Plot 对象或 nil。
-- -----------------------------------------------------------------------------
local function resolvePlotFromCoords(x, y)
    if Map == nil or Map.GetPlot == nil then
        return nil
    end
    if not isInteger(x) or not isInteger(y) then
        return nil
    end
    return Map.GetPlot(x, y)
end

-- -----------------------------------------------------------------------------
-- 函数：resolveBuyPlotCoords(baselineContext)
-- 做什么：提取 BUY_PLOT 基线中的目标地块坐标，兼容 targetX/targetY 与 plotX/plotY。
-- 为什么：保持与 UNIT_ACTION / CITY_ATTACK 一致的字段规范，同时兼容 WP4 扩展调用。
-- 输入：baselineContext（表）。
-- 输出：(tx, ty)。
-- -----------------------------------------------------------------------------
local function resolveBuyPlotCoords(baselineContext)
    local tx = baselineContext.targetX
    if tx == nil then
        tx = baselineContext.plotX
    end
    local ty = baselineContext.targetY
    if ty == nil then
        ty = baselineContext.plotY
    end
    return tx, ty
end

-- -----------------------------------------------------------------------------
-- 函数：countNewlyRevealedTiles(activePlayerID, centerX, centerY, scanRadius, revealedBefore)
-- 做什么：对比动作前双圆心联合基线 revealedBefore 与动作后 CaptureRevealedPlotsSet，
--         精确统计本步动作真正新揭开的迷雾地块数。
-- 为什么：严格落实 D-04（双圆心联合基线消除移动 1 格前沿已探索格假阳性），并与采集层
--         保持同一六边形半径口径。
-- 输入：activePlayerID、动作后采样中心 (centerX, centerY)、scanRadius、revealedBefore。
-- 输出：integer（>= 0）。
-- -----------------------------------------------------------------------------
local function countNewlyRevealedTiles(activePlayerID, centerX, centerY, scanRadius, revealedBefore)
    if not isInteger(centerX) or not isInteger(centerY) then
        return 0
    end
    local r = scanRadius
    if not isInteger(r) or r < 0 then
        r = getDeltaRevealParams()
    end
    local revealedAfter = CAB_Collector.CaptureRevealedPlotsSet(activePlayerID, centerX, centerY, r)
    local beforeSet = (type(revealedBefore) == "table") and revealedBefore or {}
    local count = 0
    for key, isRev in pairs(revealedAfter) do
        if isRev and not beforeSet[key] then
            count = count + 1
        end
    end
    return count
end

-- -----------------------------------------------------------------------------
-- 函数：buildTargetEnemyAfter(prevEnemy, currentEnemyMap)
-- 做什么：根据动作前受击敌军快照与动作后全局可见敌军映射，生成 target_enemy_after DTO。
-- 为什么：严格遵循《03》§2.3 与战争迷雾红线（仅依据可见映射判定存活残血或击杀，绝不
--         直接读取迷雾下隐匿敌军对象，并浅拷贝避免污染可见敌军原表）。
-- 输入：prevEnemy（战前敌军快照或 nil）、currentEnemyMap（战后可见敌军映射表）。
-- 输出：table（带 __is_object = true 与 enemy_killed）或 nil。
-- -----------------------------------------------------------------------------
local function buildTargetEnemyAfter(prevEnemy, currentEnemyMap)
    if type(prevEnemy) ~= "table" then
        return nil
    end
    local liveEnemy = (type(currentEnemyMap) == "table") and currentEnemyMap[prevEnemy.enemy_id] or nil
    if liveEnemy ~= nil then
        local copy = {}
        for k, v in pairs(liveEnemy) do
            copy[k] = v
        end
        copy.__is_object = true
        copy.enemy_killed = false
        return copy
    end
    return {
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
        enemy_killed = true,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：buildTargetCityAfter(prevCity, activePlayerID)
-- 做什么：根据战前已探索目标敌城快照，核验动作后该地块城市状态（残血 / 占领 / 毁城）。
-- 为什么：落实决策 D-04（攻城或城市炮击敌城时补充 target_city_after 精准反馈）。
-- 输入：prevCity（战前目标城市快照或 nil）、activePlayerID（己方玩家 ID）。
-- 输出：table（带 __is_object = true 及 captured / destroyed）或 nil。
-- -----------------------------------------------------------------------------
local function buildTargetCityAfter(prevCity, activePlayerID)
    if type(prevCity) ~= "table" then
        return nil
    end
    local pPlot = resolvePlotFromCoords(prevCity.x, prevCity.y)
    local pCityNow = (pPlot ~= nil) and pPlot:GetPlotCity() or nil
    if pCityNow == nil then
        return {
            __is_object = true,
            city_id = prevCity.city_id,
            owner_id = prevCity.owner_id,
            name = prevCity.name or "",
            x = prevCity.x,
            y = prevCity.y,
            hp = 0,
            max_hp = prevCity.max_hp or 200,
            captured = false,
            destroyed = true,
        }
    end

    local newOwner = pCityNow:GetOwner()
    local maxHp = getMaxCityHp(pCityNow)
    local dmg = pCityNow:GetDamage() or 0
    local hp = math.max(0, maxHp - dmg)
    local captured = (newOwner == activePlayerID)
    return {
        __is_object = true,
        city_id = tostring(newOwner) .. ":" .. tostring(pCityNow:GetID()),
        owner_id = newOwner,
        name = pCityNow:GetName() or prevCity.name or "",
        x = pCityNow:GetX(),
        y = pCityNow:GetY(),
        hp = hp,
        max_hp = maxHp,
        captured = captured,
        destroyed = false,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：collectDeltaObservation(baselineContext, activePlayerID, centerX, centerY, includeTargetEnemy)
-- 做什么：采集动作后可见敌军增量（过滤隐形）、精准新揭盲地块数以及受击敌军/敌城结果。
-- 为什么：复用于 UNIT_ACTION 与 CITY_ATTACK 两类异步结算，确保增量口径 100% 一致。
-- 输入：baselineContext、activePlayerID、采样中心 (centerX, centerY)、includeTargetEnemy（bool）。
-- 输出：DeltaObservationDTO（带 __is_object = true）。
-- -----------------------------------------------------------------------------
local function collectDeltaObservation(baselineContext, activePlayerID, centerX, centerY, includeTargetEnemy)
    local visSummary, currentEnemyMap = CAB_Collector.GetVisibilitySummary(activePlayerID)
    local baselineEnemyMap = (type(baselineContext.baselineEnemyMap) == "table")
        and baselineContext.baselineEnemyMap or {}

    local newlySpotted = {}
    local visEnemies = (type(visSummary) == "table" and type(visSummary.visible_enemies) == "table")
        and visSummary.visible_enemies or {}
    for _, eDto in ipairs(visEnemies) do
        if eDto ~= nil and eDto.enemy_id ~= nil and baselineEnemyMap[eDto.enemy_id] == nil then
            table.insert(newlySpotted, eDto)
        end
    end

    local newlyRevealedCount = countNewlyRevealedTiles(
        activePlayerID,
        centerX,
        centerY,
        baselineContext.revealScanRadius,
        baselineContext.revealedBefore
    )
    local targetEnemyAfter = includeTargetEnemy
        and buildTargetEnemyAfter(baselineContext.targetEnemyBefore, currentEnemyMap) or nil
    local targetCityAfter = buildTargetCityAfter(baselineContext.targetCityBefore, activePlayerID)

    return {
        __is_object = true,
        newly_revealed_tiles_count = newlyRevealedCount,
        newly_spotted_enemies = newlySpotted,
        newly_spotted_count = #newlySpotted,
        target_enemy_after = targetEnemyAfter,
        target_city_after = targetCityAfter,
    }
end

-- -----------------------------------------------------------------------------
-- 函数：attachWarDeclaredFields(resultDto, baselineContext)
-- 做什么：当动作触发可控显式宣战时，向结算结果 DTO 附带 war_declared 与目标玩家/团队 ID。
-- 为什么：严格落实 D-03（未宣战时省略键以保持与《03》§2.3 精简兼容）。
-- 输入：resultDto（待补充字段的结果表）、baselineContext。
-- 输出：nil（原地写入）。
-- -----------------------------------------------------------------------------
local function attachWarDeclaredFields(resultDto, baselineContext)
    if baselineContext.warDeclared == true then
        resultDto.war_declared = true
        if type(baselineContext.warDeclaredInfo) == "table" then
            resultDto.war_declared_target_player_id = baselineContext.warDeclaredInfo.target_owner_id
            resultDto.war_declared_target_team_id = baselineContext.warDeclaredInfo.target_team_id
        end
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.IsSettlementBusy(baselineContext)  [E8]
-- 做什么：供调度层帧轮询只读检测当前挂起的异步动作是否仍处于动画或网络结算忙碌态。
-- 为什么：区分三类 settlementKind（UNIT_ACTION / CITY_ATTACK / BUY_PLOT），在单位阵亡
--         时仍继续观测目标格战斗动画并在买地时以实时领土归属翻转作为完成信号；非法入参
--         安全返回 false，严守只读零写入。
-- 输入：baselineContext（StartUnitAction / StartCityRangeAttack / PurchaseCityPlot 返回值）。
-- -----------------------------------------------------------------------------
-- 函数：snapshotAliveUnitIds(pPlayer) / findNewlySpawnedUnitId(...)
-- 做什么：记录购买单位前的己方存活单位 ID 集合，并在异步结算阶段精准识别新生成的单位 ID。
-- 为什么：Game.CityPurchaseUnit 无返回值且经引擎消息队列跨帧生效，需通过购买前后
--         pPlayer:Units() 存活集合差分定位新生 spawned_unit_id（优先匹配城格与单位类型）。
-- 输入：pPlayer、beforeIds、cityX、cityY、expectedUnitTypeId。
-- 输出：snapshotAliveUnitIds 返回 { [unitId] = true }；findNewlySpawnedUnitId 返回 int | nil。
-- -----------------------------------------------------------------------------
local function snapshotAliveUnitIds(pPlayer)
    local ids = {}
    if pPlayer ~= nil and pPlayer.Units ~= nil then
        for pUnit in pPlayer:Units() do
            if isUnitAlive(pUnit) then
                ids[pUnit:GetID()] = true
            end
        end
    end
    return ids
end

local function findNewlySpawnedUnitId(pPlayer, beforeIds, cityX, cityY, expectedUnitTypeId)
    if pPlayer == nil or pPlayer.Units == nil or type(beforeIds) ~= "table" then
        return nil
    end
    local exactMatchId = nil
    local cityTileMatchId = nil
    local typeMatchId = nil
    local anyNewId = nil

    for pUnit in pPlayer:Units() do
        if isUnitAlive(pUnit) then
            local uid = pUnit:GetID()
            if not beforeIds[uid] then
                local onCity = (pUnit:GetX() == cityX and pUnit:GetY() == cityY)
                local sameType = (pUnit:GetUnitType() == expectedUnitTypeId)
                if onCity and sameType then
                    exactMatchId = uid
                elseif onCity then
                    cityTileMatchId = uid
                elseif sameType then
                    typeMatchId = uid
                elseif anyNewId == nil then
                    anyNewId = uid
                end
            end
        end
    end
    return exactMatchId or cityTileMatchId or typeMatchId or anyNewId
end

-- SetCityProduction 各类订单对应的原生 BNW 当前生产项查询方法
local PRODUCTION_GETTER_BY_CATEGORY = {
    BUILDING = "GetProductionBuilding",
    UNIT = "GetProductionUnit",
    PROJECT = "GetProductionProject",
    PROCESS = "GetProductionProcess",
}

-- -----------------------------------------------------------------------------
-- 函数：isCityPurchaseApplied(pPlayer, pCity, baselineContext)
-- 做什么：判定 PURCHASE_ITEM 购买指令是否已在真实引擎中完成落地。
-- 为什么：BNW 实机验证 Game.CityPurchaseBuilding / CityPurchaseUnit 经消息队列跨帧生效，
--         建筑按 GetNumRealBuilding 增量判定，单位按 findNewlySpawnedUnitId 差分判定。
-- 输入：pPlayer、pCity、baselineContext。
-- 输出：(applied: boolean, spawnedUnitId: int | nil)。
-- -----------------------------------------------------------------------------
local function isCityPurchaseApplied(pPlayer, pCity, baselineContext)
    if pCity == nil or type(baselineContext) ~= "table" then
        return false, nil
    end
    if baselineContext.itemCategory == "UNIT" then
        local spawnedId = findNewlySpawnedUnitId(
            pPlayer,
            baselineContext.beforeUnitIds,
            baselineContext.cityX,
            baselineContext.cityY,
            baselineContext.itemId
        )
        return (spawnedId ~= nil), spawnedId
    end
    local beforeCount = (type(baselineContext.beforeBuildingCount) == "number")
        and baselineContext.beforeBuildingCount or 0
    local nowCount = (pCity.GetNumRealBuilding ~= nil and isInteger(baselineContext.itemId))
        and (pCity:GetNumRealBuilding(baselineContext.itemId) or 0) or 0
    return (nowCount > beforeCount), nil
end

-- -----------------------------------------------------------------------------
-- 函数：isCityProductionApplied(pCity, baselineContext)
-- 做什么：判定 SET_PRODUCTION 设产/追加指令是否已在真实引擎队列中生效。
-- 为什么：BNW 实机验证 Game.CityPushOrder 经消息队列跨帧生效；追加队列时核验队列长度
--         递增，清空/首项设产时优先核验原生 GetProductionBuilding/Unit/Project/Process ID。
-- 输入：pCity、baselineContext。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function isCityProductionApplied(pCity, baselineContext)
    if pCity == nil or type(baselineContext) ~= "table" then
        return false
    end
    local queueLenNow = (pCity.GetOrderQueueLength ~= nil and pCity:GetOrderQueueLength()) or 0
    local queueLenBefore = (type(baselineContext.queueLenBefore) == "number")
        and baselineContext.queueLenBefore or 0
    local shouldClear = (baselineContext.clearQueue ~= false)

    if (not shouldClear) and queueLenBefore > 0 then
        return queueLenNow > queueLenBefore
    end

    local getterName = PRODUCTION_GETTER_BY_CATEGORY[baselineContext.orderCategory]
    if getterName ~= nil and pCity[getterName] ~= nil and isInteger(baselineContext.itemId) then
        local okGet, activeId = pcall(function() return pCity[getterName](pCity) end)
        if okGet and activeId == baselineContext.itemId then
            return true
        end
        return false
    end

    local summaryNow = CAB_Collector.SerializeCitySummary(pCity)
    local prodNow = (summaryNow ~= nil and summaryNow.current_production) or "NONE"
    return (queueLenNow >= 1) and (prodNow ~= "NONE")
end

-- 输出：boolean（true 表示仍在忙碌，false 表示结算完成或输入无效）。
-- -----------------------------------------------------------------------------
function CAB_Executor.IsSettlementBusy(baselineContext)
    if type(baselineContext) ~= "table" then
        return false
    end
    local activePlayerID = baselineContext.activePlayerID
    if not isInteger(activePlayerID) or activePlayerID < 0 or Players == nil then
        return false
    end
    local pPlayer = Players[activePlayerID]
    if pPlayer == nil or pPlayer:IsAlive() ~= true then
        return false
    end

    local kind = baselineContext.settlementKind
    if kind == "UNIT_ACTION" then
        if isInteger(baselineContext.unitID) then
            local pUnit = pPlayer:GetUnitByID(baselineContext.unitID)
            if isUnitAlive(pUnit) then
                if safeCallBool(pUnit, "IsBusy") or safeCallBool(pUnit, "IsFighting") then
                    return true
                end
                local pUnitPlot = (pUnit.GetPlot ~= nil) and pUnit:GetPlot() or nil
                if pUnitPlot ~= nil and safeCallBool(pUnitPlot, "IsFighting") then
                    return true
                end
            end
        end
        local pTargetPlot = resolvePlotFromCoords(baselineContext.targetX, baselineContext.targetY)
        if pTargetPlot ~= nil and safeCallBool(pTargetPlot, "IsFighting") then
            return true
        end
        return false

    elseif kind == "CITY_ATTACK" then
        local pTargetPlot = resolvePlotFromCoords(baselineContext.targetX, baselineContext.targetY)
        if pTargetPlot ~= nil and safeCallBool(pTargetPlot, "IsFighting") then
            return true
        end
        return false

    elseif kind == "BUY_PLOT" then
        local tx, ty = resolveBuyPlotCoords(baselineContext)
        local pTargetPlot = resolvePlotFromCoords(tx, ty)
        if pTargetPlot == nil then
            return false
        end
        return pTargetPlot:GetOwner() ~= activePlayerID

    elseif kind == "PURCHASE_ITEM" then
        local pCity = isInteger(baselineContext.cityID) and pPlayer:GetCityByID(baselineContext.cityID) or nil
        if pCity == nil then
            return false
        end
        local applied = isCityPurchaseApplied(pPlayer, pCity, baselineContext)
        return not applied

    elseif kind == "SET_PRODUCTION" then
        local pCity = isInteger(baselineContext.cityID) and pPlayer:GetCityByID(baselineContext.cityID) or nil
        if pCity == nil then
            return false
        end
        return not isCityProductionApplied(pCity, baselineContext)
    end

    return false
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.FinalizeActionSettlement(baselineContext, settleWaitMs)  [E9]
-- 做什么：在异步等待结束（或触发超时兜底）后，对比 baselineContext 与最新引擎状态，
--         组装标准 ActionExecutionResultDTO（UNIT_ACTION / CITY_ATTACK）、
--         PurchasePlotResultDTO（BUY_PLOT）、PurchaseItemResultDTO（PURCHASE_ITEM）
--         或 SetProductionResultDTO（SET_PRODUCTION）。
-- 为什么：
--   1. 全程只读零写入，零迷雾侧信道，直接复用 CAB_Collector 保持与采集层 100% 同源；
--   2. 严格落实 D-04 与 BNW 实机跨帧消息队列实证：涵盖 5 类 settlementKind，统一附带
--      settle_wait_ms 与 timed_out，精准回读扣费、新生单位 ID、归属翻转与生产队列；
--   3. 对非法或未知 baselineContext 返回结构化错返 DTO，绝不抛未捕获 Lua 异常。
-- 输入：
--   baselineContext (table) - 动作启动阶段返回的基线上下文
--   settleWaitMs (number)   - 调度层实际等待的结算耗时（毫秒）
-- 输出：table（带 __is_object = true 的结算结果 DTO）。
-- -----------------------------------------------------------------------------
function CAB_Executor.FinalizeActionSettlement(baselineContext, settleWaitMs)
    local waitMs = normalizeWaitMs(settleWaitMs)
    if type(baselineContext) ~= "table" then
        return {
            __is_object = true,
            executed = false,
            error_reason = "Invalid baselineContext",
            settle_wait_ms = waitMs,
            timed_out = false,
        }
    end

    local kind = baselineContext.settlementKind
    local activePlayerID = baselineContext.activePlayerID
    local pPlayer = (isInteger(activePlayerID) and activePlayerID >= 0 and Players ~= nil)
        and Players[activePlayerID] or nil
    local timedOut = CAB_Executor.IsSettlementBusy(baselineContext)

    if kind == "UNIT_ACTION" then
        local pUnit = (pPlayer ~= nil and isInteger(baselineContext.unitID))
            and pPlayer:GetUnitByID(baselineContext.unitID) or nil
        local unitAfter = CAB_Collector.SerializeUnitSummary(pUnit)
        local unitDied = not isUnitAlive(pUnit)

        local centerX = (unitAfter ~= nil and unitAfter.x) or baselineContext.beforeX
        local centerY = (unitAfter ~= nil and unitAfter.y) or baselineContext.beforeY
        local isAttack = ATTACK_UNIT_ACTIONS[baselineContext.actionType] == true
        local deltaObs = collectDeltaObservation(baselineContext, activePlayerID, centerX, centerY, isAttack)

        local result = {
            __is_object = true,
            executed = true,
            action_type = baselineContext.actionType,
            target_x = baselineContext.targetX,
            target_y = baselineContext.targetY,
            settle_wait_ms = waitMs,
            timed_out = timedOut,
            unit_died = unitDied,
            unit_after = unitAfter,
            delta_observation = deltaObs,
        }
        attachWarDeclaredFields(result, baselineContext)
        return result

    elseif kind == "CITY_ATTACK" then
        local pCity = (pPlayer ~= nil and isInteger(baselineContext.cityID))
            and pPlayer:GetCityByID(baselineContext.cityID) or nil
        local cityAfter = CAB_Collector.SerializeCitySummary(pCity)

        local centerX = baselineContext.targetX or baselineContext.beforeX
        local centerY = baselineContext.targetY or baselineContext.beforeY
        local deltaObs = collectDeltaObservation(baselineContext, activePlayerID, centerX, centerY, true)

        local result = {
            __is_object = true,
            executed = true,
            action_type = baselineContext.actionType or "CITY_RANGE_ATTACK",
            city_id = baselineContext.cityID,
            city_after = cityAfter,
            target_x = baselineContext.targetX,
            target_y = baselineContext.targetY,
            settle_wait_ms = waitMs,
            timed_out = timedOut,
            delta_observation = deltaObs,
        }
        attachWarDeclaredFields(result, baselineContext)
        return result

    elseif kind == "BUY_PLOT" then
        local tx, ty = resolveBuyPlotCoords(baselineContext)
        local pTargetPlot = resolvePlotFromCoords(tx, ty)
        local newOwner = (pTargetPlot ~= nil) and pTargetPlot:GetOwner() or -1
        local purchased = isInteger(activePlayerID) and (newOwner == activePlayerID)

        local goldBefore = (type(baselineContext.goldBefore) == "number") and baselineContext.goldBefore or 0
        local goldAfter = (pPlayer ~= nil and pPlayer.GetGold ~= nil)
            and (pPlayer:GetGold() or goldBefore) or goldBefore
        local expectedCost = (type(baselineContext.expectedCost) == "number")
            and baselineContext.expectedCost or 0
        local costPaid = math.max(0, goldBefore - goldAfter)

        local errorReason = nil
        if not purchased then
            if timedOut then
                errorReason = "Plot ownership did not transfer to active player before settlement timeout"
            else
                errorReason = "Plot ownership did not transfer to active player"
            end
        end

        return {
            __is_object = true,
            purchased = purchased,
            error_reason = errorReason,
            city_id = baselineContext.cityID,
            x = tx,
            y = ty,
            cost_paid = costPaid,
            expected_cost = expectedCost,
            gold_before = goldBefore,
            gold_after = goldAfter,
            new_owner_id = newOwner,
            settle_wait_ms = waitMs,
            timed_out = timedOut,
        }

    elseif kind == "PURCHASE_ITEM" then
        local pCity = (pPlayer ~= nil and isInteger(baselineContext.cityID))
            and pPlayer:GetCityByID(baselineContext.cityID) or nil
        local category = baselineContext.itemCategory or "BUILDING"
        local yieldStr = baselineContext.yieldType or "GOLD"
        local purchased, spawnedId = isCityPurchaseApplied(pPlayer, pCity, baselineContext)
        local expectedCost = (type(baselineContext.expectedCost) == "number")
            and baselineContext.expectedCost or 0

        local errorReason = nil
        if not purchased then
            if timedOut then
                errorReason = "City purchase did not apply before settlement timeout"
            else
                errorReason = "City purchase did not apply"
            end
        end

        local resultDto = {
            __is_object = true,
            purchased = purchased,
            error_reason = errorReason,
            city_id = baselineContext.cityID,
            item_category = category,
            item_type = baselineContext.itemType,
            yield_type = yieldStr,
            cost_paid = 0,
            expected_cost = expectedCost,
            city_summary_after = (pCity ~= nil) and CAB_Collector.SerializeCitySummary(pCity) or nil,
            settle_wait_ms = waitMs,
            timed_out = timedOut,
        }

        if yieldStr == "FAITH" then
            local faithBefore = (type(baselineContext.faithBefore) == "number") and baselineContext.faithBefore or 0
            local faithAfter = (pPlayer ~= nil and pPlayer.GetFaith ~= nil)
                and (pPlayer:GetFaith() or faithBefore) or faithBefore
            resultDto.cost_paid = math.max(0, faithBefore - faithAfter)
            resultDto.faith_before = faithBefore
            resultDto.faith_after = faithAfter
        else
            local goldBefore = (type(baselineContext.goldBefore) == "number") and baselineContext.goldBefore or 0
            local goldAfter = (pPlayer ~= nil and pPlayer.GetGold ~= nil)
                and (pPlayer:GetGold() or goldBefore) or goldBefore
            resultDto.cost_paid = math.max(0, goldBefore - goldAfter)
            resultDto.gold_before = goldBefore
            resultDto.gold_after = goldAfter
        end

        if category == "UNIT" then
            resultDto.spawned_unit_id = spawnedId
        end

        return resultDto

    elseif kind == "SET_PRODUCTION" then
        local pCity = (pPlayer ~= nil and isInteger(baselineContext.cityID))
            and pPlayer:GetCityByID(baselineContext.cityID) or nil
        local applied = isCityProductionApplied(pCity, baselineContext)
        local summaryAfter = (pCity ~= nil) and CAB_Collector.SerializeCitySummary(pCity) or nil
        local currentProduction = (summaryAfter ~= nil and summaryAfter.current_production) or "NONE"
        local turnsLeft = (summaryAfter ~= nil and summaryAfter.turns_left)
            or ((pCity ~= nil and pCity.GetProductionTurnsLeft ~= nil) and (pCity:GetProductionTurnsLeft() or 0) or 0)
        local queueLen = (pCity ~= nil and pCity.GetOrderQueueLength ~= nil) and (pCity:GetOrderQueueLength() or 0) or 0

        local errorReason = nil
        if not applied then
            if timedOut then
                errorReason = "City production order did not apply before settlement timeout"
            else
                errorReason = "City production order did not apply"
            end
        end

        return {
            __is_object = true,
            executed = applied,
            error_reason = errorReason,
            city_id = baselineContext.cityID,
            order_category = baselineContext.orderCategory,
            item_type = baselineContext.itemType,
            clear_queue = (baselineContext.clearQueue ~= false),
            current_production = currentProduction,
            turns_left = turnsLeft,
            order_queue_length = queueLen,
            settle_wait_ms = waitMs,
            timed_out = timedOut,
        }
    end

    return {
        __is_object = true,
        executed = false,
        error_reason = "Unsupported settlementKind: " .. tostring(kind),
        settle_wait_ms = waitMs,
        timed_out = false,
    }
end

-- -----------------------------------------------------------------------------
-- 第 5 节：公开接口 E4 / E5 / E6 / E7 — 城市内政与安全下一回合（WP4）
-- -----------------------------------------------------------------------------

-- 允许在 ExecuteEndTurn(autoSkipReadyUnits == true) 时触发守卫式自动跳过的阻塞类型
local SKIPPABLE_ENDTURN_BLOCKING = {
    ENDTURN_BLOCKING_UNITS = true,
    ENDTURN_BLOCKING_UNIT_NEEDS_ORDERS = true,
}

-- SetCityProduction 4 类订单映射（对齐官方 ProductionPopup.lua 与 BNW OrderTypes）
local ORDER_CATEGORY_SPECS = {
    BUILDING = {
        infoTableName = "Buildings",
        orderKey = "ORDER_CONSTRUCT",
        checkMethod = "CanConstruct",
    },
    UNIT = {
        infoTableName = "Units",
        orderKey = "ORDER_TRAIN",
        checkMethod = "CanTrain",
    },
    PROJECT = {
        infoTableName = "Projects",
        orderKey = "ORDER_CREATE",
        checkMethod = "CanCreate",
    },
    PROCESS = {
        infoTableName = "Processes",
        orderKey = "ORDER_MAINTAIN",
        checkMethod = "CanMaintain",
    },
}

-- -----------------------------------------------------------------------------
-- 函数：resolveGameInfoEntry(infoTable, itemKeyOrId)
-- 做什么：按 Type 字符串或非负整数 ID 在指定 GameInfo 表视图中解析条目的 (ID, Type)。
-- 为什么：Civ5 GameInfo 表对越界整数或未知字符串会返回空表 {} 而非 nil，需显式核验
--         row.ID 与 row.Type 合法性，防止误将空表当作有效条目传入引擎写接口。
-- 输入：infoTable（GameInfo 子表视图）、itemKeyOrId（string | int）。
-- 输出：(itemId: int | nil, itemType: string | nil)。
-- -----------------------------------------------------------------------------
local function resolveGameInfoEntry(infoTable, itemKeyOrId)
    if infoTable == nil then
        return nil, nil
    end
    if type(itemKeyOrId) == "string" then
        if itemKeyOrId == "" then
            return nil, nil
        end
        local row = infoTable[itemKeyOrId]
        if row ~= nil and isInteger(row.ID) and row.ID >= 0 and row.Type == itemKeyOrId then
            return row.ID, row.Type
        end
        return nil, nil
    end
    if isInteger(itemKeyOrId) and itemKeyOrId >= 0 then
        local row = infoTable[itemKeyOrId]
        if row ~= nil and isInteger(row.ID) and row.ID == itemKeyOrId
            and type(row.Type) == "string" and row.Type ~= ""
        then
            return row.ID, row.Type
        end
        return nil, nil
    end
    return nil, nil
end

-- -----------------------------------------------------------------------------
-- 函数：notifySpecificCityInfoDirty(activePlayerID, cityID, updateType)
-- 做什么：通过 pcall 安全触发 Events.SpecificCityInfoDirty 刷新城市横幅/生产/购买 UI。
-- 为什么：对齐官方 ProductionPopup.lua 与 WorldView.lua，且防止测试或异常宿主缺少事件槽位。
-- 输入：activePlayerID、cityID、updateType（CityUpdateTypes 枚举值）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function notifySpecificCityInfoDirty(activePlayerID, cityID, updateType)
    if Events ~= nil and Events.SpecificCityInfoDirty ~= nil then
        pcall(Events.SpecificCityInfoDirty, activePlayerID, cityID, updateType)
    end
end

-- -----------------------------------------------------------------------------
-- 函数：checkCityDomesticWritable(pCity)
-- 做什么：校验城市当前不处于傀儡、占领抵抗或焚城受限状态。
-- 为什么：SetCityProduction 与 PurchaseCityPlot 均严禁对受限城发包（对齐官方
--         ProductionPopup.lua 与 CityView.lua），确保校验失败零写入副作用（E-02）。
-- 输入：pCity（己方 City 对象）。
-- 输出：(ok: boolean, errMsg: string | nil)。
-- -----------------------------------------------------------------------------
local function checkCityDomesticWritable(pCity)
    if safeCallBool(pCity, "IsPuppet") then
        return false, "Puppet city does not allow this domestic action"
    end
    if safeCallBool(pCity, "IsResistance") then
        return false, "City in resistance does not allow this domestic action"
    end
    if safeCallBool(pCity, "IsRazing") then
        return false, "Razing city does not allow this domestic action"
    end
    return true, nil
end

-- -----------------------------------------------------------------------------
-- 函数：isUnitIllegallyStacked(pUnit, activePlayerID)
-- 做什么：判断待命单位当前所在格是否存在另一同类别（同战斗或同民用）的非空军己方存活单位。
-- 为什么：
--   1. 不能对自身所在格直接调用 CAB_Collector.HasSameClassFriendlyUnit（会命中单位自身）；
--   2. 严格落实决策 D-05：ExecuteEndTurn 自动跳过时必须保护同格非法叠栈单位，同时允许
--      合法的军民叠栈及城内空军叠栈单位被正常跳过。
-- 输入：pUnit（待检查存活单位）、activePlayerID（玩家 ID）。
-- 输出：boolean（true 表示处于同类非法叠栈，严禁自动跳过）。
-- -----------------------------------------------------------------------------
local function isUnitIllegallyStacked(pUnit, activePlayerID)
    local pPlot = (pUnit.GetPlot ~= nil) and pUnit:GetPlot() or nil
    if pPlot == nil then
        return false
    end
    local uDomain = pUnit:GetDomainType()
    if DomainTypes ~= nil and uDomain == DomainTypes.DOMAIN_AIR then
        return false
    end

    local selfId = pUnit:GetID()
    local selfIsCombat = (pUnit.IsCombatUnit ~= nil and pUnit:IsCombatUnit() == true) or false
    local numUnits = pPlot:GetNumUnits() or 0
    for i = 0, numUnits - 1 do
        local pOther = pPlot:GetUnit(i)
        if isUnitAlive(pOther)
            and pOther:GetOwner() == activePlayerID
            and pOther:GetID() ~= selfId
        then
            local otherDomain = pOther:GetDomainType()
            if not (DomainTypes ~= nil and otherDomain == DomainTypes.DOMAIN_AIR) then
                local otherIsCombat = (pOther.IsCombatUnit ~= nil and pOther:IsCombatUnit() == true) or false
                if otherIsCombat == selfIsCombat then
                    return true
                end
            end
        end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：dispatchSkipMission(pUnit)
-- 做什么：选中指定待命单位并下发原版跳过本回合指令（优先 HandleAction，回退 PUSH_MISSION）。
-- 为什么：供 ExecuteEndTurn 守卫式自动跳过复用，与 StartUnitAction 的 SKIP_TURN 保持同源口径。
-- 输入：pUnit（待跳过存活单位）。
-- 输出：boolean（是否成功下发跳过指令）。
-- -----------------------------------------------------------------------------
local function dispatchSkipMission(pUnit)
    if UI ~= nil and UI.SelectUnit ~= nil then
        UI.SelectUnit(pUnit)
    end
    local iAction = CAB_Collector.FindGameActionIndex("MISSION_SKIP")
    if iAction ~= nil then
        Game.HandleAction(iAction)
        return true
    end
    local skipMission = (MissionTypes and MissionTypes.MISSION_SKIP)
        or (GameInfoTypes and GameInfoTypes.MISSION_SKIP)
    if skipMission ~= nil and GameMessageTypes ~= nil then
        Game.SelectionListGameNetMessage(
            GameMessageTypes.GAMEMESSAGE_PUSH_MISSION,
            skipMission,
            pUnit:GetID(), 0, 0, false
        )
        return true
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.PurchaseCityItem(activePlayerID, cityID, itemCategory, itemKeyOrId, yieldTypeStr)  [E4]
-- 做什么：校验并在指定己方城市使用金币（默认）或信仰购买建筑或单位，触发城市刷新事件，
--         返回 PURCHASE_ITEM 短延迟异步结算基线（联动 IsSettlementBusy / FinalizeActionSettlement）。
-- 为什么：
--   1. 严格落实 E-01（活动回合与消息队列门控）与 E-02（前置失败零写副作用）；
--   2. 参照官方 ProductionPopup.lua:136-161 双层 IsCanPurchase 校验，精准区分
--      “科技/前置未满足或已拥有”与“金币/信仰不足或城内驻军叠栈”两类失败原因；
--   3. 购买单位信仰报价对齐 ProductionPopup.lua:457 传入第二参数 true；
--   4. BNW v1.0.3.279 真机实证 Game.CityPurchaseBuilding/Unit 经引擎消息队列跨帧生效，
--      采用与 PurchaseCityPlot 对称的 0.10s 短延迟结算可精准回读扣费、新生单位 ID 与城市摘要。
-- 输入：
--   activePlayerID (int)            - 当前人类玩家 ID
--   cityID (int)                    - 目标己方城市 ID
--   itemCategory ("BUILDING"|"UNIT"|nil) - 购买类别，默认 "BUILDING"
--   itemKeyOrId (string|int)        - 建筑/单位 Type 字符串或整数 ID
--   yieldTypeStr ("GOLD"|"FAITH"|nil)    - 货币类型，默认 "GOLD"
-- 输出：(ok: boolean, errMsg: string | nil, baselineContext: table | nil)。
-- -----------------------------------------------------------------------------
function CAB_Executor.PurchaseCityItem(activePlayerID, cityID, itemCategory, itemKeyOrId, yieldTypeStr)
    -- 1. E-01 活动回合与消息队列门控
    local gateOk, gateErr, pPlayer = validateActivePlayerWriteGate(activePlayerID)
    if not gateOk then
        return false, gateErr, nil
    end

    -- 2. 基础入参、己方城市、类别与货币校验
    if not isInteger(cityID) then
        return false, "Invalid cityID: " .. tostring(cityID), nil
    end
    local pCity = pPlayer:GetCityByID(cityID)
    if pCity == nil or pCity:GetOwner() ~= activePlayerID then
        return false, "City not found or not owned by active player: " .. tostring(cityID), nil
    end

    local category = (itemCategory == nil) and "BUILDING" or itemCategory
    if category ~= "BUILDING" and category ~= "UNIT" then
        return false, "Unsupported itemCategory: " .. tostring(itemCategory), nil
    end

    local yieldStr = (yieldTypeStr == nil) and "GOLD" or yieldTypeStr
    if yieldStr ~= "GOLD" and yieldStr ~= "FAITH" then
        return false, "Unsupported yieldTypeStr: " .. tostring(yieldTypeStr), nil
    end
    if YieldTypes == nil then
        return false, "YieldTypes enum is unavailable", nil
    end
    local eYield = (yieldStr == "FAITH") and YieldTypes.YIELD_FAITH or YieldTypes.YIELD_GOLD
    if eYield == nil then
        return false, "Resolved YieldType is unavailable for: " .. yieldStr, nil
    end

    -- 3. 解析建筑或单位数据库条目（支持 Type 字符串或整数 ID）
    local infoTable = nil
    if GameInfo ~= nil then
        infoTable = (category == "UNIT") and GameInfo.Units or GameInfo.Buildings
    end
    local itemId, itemType = resolveGameInfoEntry(infoTable, itemKeyOrId)
    if itemId == nil or itemType == nil then
        return false, "Unknown " .. category .. " identifier: " .. tostring(itemKeyOrId), nil
    end

    local uID = (category == "UNIT") and itemId or -1
    local bID = (category == "BUILDING") and itemId or -1

    -- 4. 参照 ProductionPopup.lua:136-161 双层 IsCanPurchase 校验与错误细分（零写入）
    local okFull, canFull = pcall(function()
        return pCity:IsCanPurchase(true, true, uID, bID, -1, eYield)
    end)
    if not (okFull and canFull == true) then
        local okRule, canRule = pcall(function()
            return pCity:IsCanPurchase(false, false, uID, bID, -1, eYield)
        end)
        if not (okRule and canRule == true) then
            return false,
                "City cannot purchase " .. itemType .. " with " .. yieldStr
                    .. " (prerequisites unmet, already owned, or not purchasable)",
                nil
        end

        local expectedCost = 0
        local balance = 0
        if yieldStr == "FAITH" then
            balance = pPlayer:GetFaith() or 0
            if category == "UNIT" then
                expectedCost = (pCity.GetUnitFaithPurchaseCost ~= nil and pCity:GetUnitFaithPurchaseCost(uID, true)) or 0
            else
                expectedCost = (pCity.GetBuildingFaithPurchaseCost ~= nil and pCity:GetBuildingFaithPurchaseCost(bID)) or 0
            end
        else
            balance = pPlayer:GetGold() or 0
            if category == "UNIT" then
                expectedCost = (pCity.GetUnitPurchaseCost ~= nil and pCity:GetUnitPurchaseCost(uID)) or 0
            else
                expectedCost = (pCity.GetBuildingPurchaseCost ~= nil and pCity:GetBuildingPurchaseCost(bID)) or 0
            end
        end

        if expectedCost > 0 and balance < expectedCost then
            return false,
                string.format(
                    "Insufficient %s to purchase %s: need %d, have %d",
                    yieldStr, itemType, expectedCost, balance
                ),
                nil
        end
        return false,
            "Cannot purchase " .. itemType .. " right now (insufficient funds, stacking conflict, or city restriction)",
            nil
    end

    -- 5. 计算预期价格、记录购买前基线，下发购买指令并刷新城市事件
    --    注：BNW 真机实证 Game.CityPurchaseBuilding/Unit 经引擎消息队列跨帧生效，
    --    返回 settlementKind = "PURCHASE_ITEM" 基线，由 IsSettlementBusy + FinalizeActionSettlement 精准回读。
    local expectedCost = 0
    if yieldStr == "FAITH" then
        if category == "UNIT" then
            expectedCost = (pCity.GetUnitFaithPurchaseCost ~= nil and pCity:GetUnitFaithPurchaseCost(uID, true)) or 0
        else
            expectedCost = (pCity.GetBuildingFaithPurchaseCost ~= nil and pCity:GetBuildingFaithPurchaseCost(bID)) or 0
        end
    else
        if category == "UNIT" then
            expectedCost = (pCity.GetUnitPurchaseCost ~= nil and pCity:GetUnitPurchaseCost(uID)) or 0
        else
            expectedCost = (pCity.GetBuildingPurchaseCost ~= nil and pCity:GetBuildingPurchaseCost(bID)) or 0
        end
    end

    local goldBefore = pPlayer:GetGold() or 0
    local faithBefore = pPlayer:GetFaith() or 0
    local beforeUnitIds = (category == "UNIT") and snapshotAliveUnitIds(pPlayer) or nil
    local beforeBuildingCount = (category == "BUILDING" and pCity.GetNumRealBuilding ~= nil)
        and (pCity:GetNumRealBuilding(bID) or 0) or 0

    if category == "UNIT" then
        Game.CityPurchaseUnit(pCity, uID, eYield)
    else
        Game.CityPurchaseBuilding(pCity, bID, eYield)
    end

    local updateType = (CityUpdateTypes and CityUpdateTypes.CITY_UPDATE_TYPE_PURCHASE) or 2
    notifySpecificCityInfoDirty(activePlayerID, cityID, updateType)

    debugLog(
        "PurchaseCityItem dispatched " .. category .. "=" .. itemType
            .. " in city=" .. tostring(cityID)
            .. " via " .. yieldStr .. " expectedCost=" .. tostring(expectedCost)
    )

    -- 6. 组装短延迟异步结算基线（与 PurchaseCityPlot / BUY_PLOT 完全对称）
    local baselineContext = {
        settlementKind = "PURCHASE_ITEM",
        activePlayerID = activePlayerID,
        cityID = cityID,
        actionType = "PURCHASE_CITY_ITEM",
        itemCategory = category,
        itemId = itemId,
        itemType = itemType,
        yieldType = yieldStr,
        expectedCost = expectedCost,
        goldBefore = goldBefore,
        faithBefore = faithBefore,
        beforeBuildingCount = beforeBuildingCount,
        beforeUnitIds = beforeUnitIds,
        cityX = pCity:GetX(),
        cityY = pCity:GetY(),
        minWaitSec = (type(CAB_Config) == "table" and CAB_Config.PLOT_BUY_SETTLE_SEC) or 0.10,
        maxTimeoutSec = (type(CAB_Config) == "table" and CAB_Config.MAX_SETTLE_TIMEOUT_SEC) or 1.50,
    }
    return true, nil, baselineContext
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.SetCityProduction(activePlayerID, cityID, orderCategory, itemKeyOrId, clearQueue)  [E5]
-- 做什么：为非受限己方城市设置或追加生产队列项目（建筑/单位/项目/转化），返回 SET_PRODUCTION
--         短延迟异步结算基线（联动 IsSettlementBusy / FinalizeActionSettlement 精准回读队列）。
-- 为什么：
--   1. 严格落实 E-01 / E-02，拦截傀儡/抵抗/焚城与前置未满足项目，保证零写副作用；
--   2. 参照官方 ProductionPopup.lua:133 调用 Game.CityPushOrder(pCity, eOrder, iData, false, clearQueue ~= false, true)
--      并触发 CITY_UPDATE_TYPE_PRODUCTION 脏事件；
--   3. BNW v1.0.3.279 真机实证 Game.CityPushOrder 经引擎消息队列跨帧生效，采用与
--      PurchaseCityPlot 对称的 0.10s 短延迟结算可精准回读最新生产项与队列长度。
-- 输入：
--   activePlayerID (int)       - 当前人类玩家 ID
--   cityID (int)               - 目标己方城市 ID
--   orderCategory (string)     - "BUILDING" | "UNIT" | "PROJECT" | "PROCESS"
--   itemKeyOrId (string|int)   - 目标条目的 Type 字符串或整数 ID
--   clearQueue (boolean|nil)   - 默认 true（清空原队列）；传 false 表示追加至队列末尾
-- 输出：(ok: boolean, errMsg: string | nil, baselineContext: table | nil)。
-- -----------------------------------------------------------------------------
function CAB_Executor.SetCityProduction(activePlayerID, cityID, orderCategory, itemKeyOrId, clearQueue)
    -- 1. E-01 活动回合与消息队列门控
    local gateOk, gateErr, pPlayer = validateActivePlayerWriteGate(activePlayerID)
    if not gateOk then
        return false, gateErr, nil
    end

    -- 2. 基础入参、己方城市与非受限状态校验
    if not isInteger(cityID) then
        return false, "Invalid cityID: " .. tostring(cityID), nil
    end
    local pCity = pPlayer:GetCityByID(cityID)
    if pCity == nil or pCity:GetOwner() ~= activePlayerID then
        return false, "City not found or not owned by active player: " .. tostring(cityID), nil
    end

    local writableOk, writableErr = checkCityDomesticWritable(pCity)
    if not writableOk then
        return false, writableErr, nil
    end

    local spec = (type(orderCategory) == "string") and ORDER_CATEGORY_SPECS[orderCategory] or nil
    if spec == nil then
        return false, "Unsupported orderCategory: " .. tostring(orderCategory), nil
    end

    local eOrder = (OrderTypes ~= nil) and OrderTypes[spec.orderKey] or nil
    if eOrder == nil then
        return false, "OrderTypes." .. spec.orderKey .. " is unavailable", nil
    end

    local infoTable = (GameInfo ~= nil) and GameInfo[spec.infoTableName] or nil
    local itemId, itemType = resolveGameInfoEntry(infoTable, itemKeyOrId)
    if itemId == nil or itemType == nil then
        return false, "Unknown " .. orderCategory .. " identifier: " .. tostring(itemKeyOrId), nil
    end

    -- 3. 引擎级可建造/可训练/可创建/可维持校验
    local checkFn = pCity[spec.checkMethod]
    if checkFn == nil then
        return false, "City check method unavailable: " .. spec.checkMethod, nil
    end
    local okCan, canOrder = pcall(function() return checkFn(pCity, itemId) end)
    if not (okCan and canOrder == true) then
        return false, "City cannot set production order for " .. itemType, nil
    end

    -- 4. 记录队列基线，参照 ProductionPopup.lua:133 下发队列指令并刷新 UI 事件
    --    注：BNW 真机实证 Game.CityPushOrder 经引擎消息队列跨帧生效，
    --    返回 settlementKind = "SET_PRODUCTION" 基线，由 IsSettlementBusy + FinalizeActionSettlement 精准回读。
    local shouldClear = (clearQueue ~= false)
    local queueLenBefore = (pCity.GetOrderQueueLength ~= nil and pCity:GetOrderQueueLength()) or 0

    Game.CityPushOrder(pCity, eOrder, itemId, false, shouldClear, true)

    local updateType = (CityUpdateTypes and CityUpdateTypes.CITY_UPDATE_TYPE_PRODUCTION) or 0
    notifySpecificCityInfoDirty(activePlayerID, cityID, updateType)

    debugLog(
        "SetCityProduction dispatched city=" .. tostring(cityID)
            .. " category=" .. orderCategory
            .. " item=" .. itemType
            .. " clearQueue=" .. tostring(shouldClear)
    )
    local baselineContext = {
        settlementKind = "SET_PRODUCTION",
        activePlayerID = activePlayerID,
        cityID = cityID,
        actionType = "SET_CITY_PRODUCTION",
        orderCategory = orderCategory,
        itemId = itemId,
        itemType = itemType,
        clearQueue = shouldClear,
        queueLenBefore = queueLenBefore,
        minWaitSec = (type(CAB_Config) == "table" and CAB_Config.PLOT_BUY_SETTLE_SEC) or 0.10,
        maxTimeoutSec = (type(CAB_Config) == "table" and CAB_Config.MAX_SETTLE_TIMEOUT_SEC) or 1.50,
    }
    return true, nil, baselineContext
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.PurchaseCityPlot(activePlayerID, cityID, plotX, plotY)  [E6]
-- 做什么：校验城市买地合法性并发送 Network.SendCityBuyPlot，返回 BUY_PLOT 异步结算基线。
-- 为什么：
--   1. 严格落实 E-01 / E-02 及 E-06（实时读取 GameDefines.BUY_PLOTS_DISABLED，零缓存）；
--   2. 参照官方 CityView.lua:2003, 2143 使用双层 CanBuyPlotAt 精准区分“金币不足（附报价）”
--      与“坐标不在本城合法可购范围内”；
--   3. 返回与 WP3 IsSettlementBusy / FinalizeActionSettlement 完全对齐的 BUY_PLOT 基线。
-- 输入：activePlayerID (int)、cityID (int)、plotX (int)、plotY (int)。
-- 输出：(ok: boolean, errMsg: string | nil, baselineContext: table | nil)。
-- -----------------------------------------------------------------------------
function CAB_Executor.PurchaseCityPlot(activePlayerID, cityID, plotX, plotY)
    -- 1. E-01 活动回合与消息队列门控
    local gateOk, gateErr, pPlayer = validateActivePlayerWriteGate(activePlayerID)
    if not gateOk then
        return false, gateErr, nil
    end

    -- 2. E-06 实时读取 BUY_PLOTS_DISABLED 规则开关（零缓存）
    local buyPlotsDisabled = (GameDefines and GameDefines.BUY_PLOTS_DISABLED) or 0
    if buyPlotsDisabled ~= 0 then
        return false, "Buying plots is disabled by game rules (BUY_PLOTS_DISABLED)", nil
    end

    -- 3. 基础入参、己方城市与非受限状态校验
    if not isInteger(cityID) then
        return false, "Invalid cityID: " .. tostring(cityID), nil
    end
    if not isInteger(plotX) or not isInteger(plotY) then
        return false, "Invalid plot coordinates (" .. tostring(plotX) .. "," .. tostring(plotY) .. ")", nil
    end

    local pCity = pPlayer:GetCityByID(cityID)
    if pCity == nil or pCity:GetOwner() ~= activePlayerID then
        return false, "City not found or not owned by active player: " .. tostring(cityID), nil
    end

    local writableOk, writableErr = checkCityDomesticWritable(pCity)
    if not writableOk then
        return false, writableErr, nil
    end

    local pPlot = resolvePlotFromCoords(plotX, plotY)
    if pPlot == nil then
        return false, "Target plot out of map bounds (" .. tostring(plotX) .. "," .. tostring(plotY) .. ")", nil
    end

    -- 4. 参照 CityView.lua:2003, 2143 双层 CanBuyPlotAt 校验与错误细分
    local okBuyNow, canBuyNow = pcall(function()
        return pCity:CanBuyPlotAt(plotX, plotY, false)
    end)
    if not (okBuyNow and canBuyNow == true) then
        local okIgnore, canIgnoreCost = pcall(function()
            return pCity:CanBuyPlotAt(plotX, plotY, true)
        end)
        if okIgnore and canIgnoreCost == true then
            local cost = (pCity.GetBuyPlotCost ~= nil and pCity:GetBuyPlotCost(plotX, plotY)) or 0
            local goldNow = pPlayer:GetGold() or 0
            return false,
                string.format(
                    "Insufficient gold to purchase plot (%d,%d): need %d, have %d",
                    plotX, plotY, cost, goldNow
                ),
                nil
        end
        return false,
            string.format(
                "Plot (%d,%d) is not within valid purchasable range for city %d",
                plotX, plotY, cityID
            ),
            nil
    end

    -- 5. 记录买地前基线并下发 Network.SendCityBuyPlot（若城市界面打开则安全刷新）
    local goldBefore = pPlayer:GetGold() or 0
    local expectedCost = (pCity.GetBuyPlotCost ~= nil and pCity:GetBuyPlotCost(plotX, plotY)) or 0

    Network.SendCityBuyPlot(cityID, plotX, plotY)

    if UI ~= nil and UI.IsCityScreenUp ~= nil and UI.UpdateCityScreen ~= nil then
        local okUp, isUp = pcall(UI.IsCityScreenUp)
        if okUp and isUp == true then
            pcall(UI.UpdateCityScreen)
        end
    end

    debugLog(
        "PurchaseCityPlot dispatched city=" .. tostring(cityID)
            .. " plot=(" .. tostring(plotX) .. "," .. tostring(plotY) .. ")"
            .. " expectedCost=" .. tostring(expectedCost)
    )

    -- 6. 组装短延迟异步结算基线（与 WP3 IsSettlementBusy / FinalizeActionSettlement 无缝衔接）
    local baselineContext = {
        settlementKind = "BUY_PLOT",
        activePlayerID = activePlayerID,
        cityID = cityID,
        actionType = "PURCHASE_CITY_PLOT",
        targetX = plotX,
        targetY = plotY,
        goldBefore = goldBefore,
        expectedCost = expectedCost,
        minWaitSec = (type(CAB_Config) == "table" and CAB_Config.PLOT_BUY_SETTLE_SEC) or 0.10,
        maxTimeoutSec = (type(CAB_Config) == "table" and CAB_Config.MAX_SETTLE_TIMEOUT_SEC) or 1.50,
    }
    return true, nil, baselineContext
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Executor.ExecuteEndTurn(activePlayerID, autoSkipReadyUnits)  [E7]
-- 做什么：安全执行下一回合：先诊断当前回合阻塞态，仅在显式开启 autoSkipReadyUnits 且
--         当前为待命单位类阻塞时执行守卫式自动跳过并复查，无阻塞时提交 CONTROL_ENDTURN。
-- 为什么：
--   1. 严格落实决策 D-05 与官方 ActionInfoPanel.lua:174-175 逻辑：默认不跳过任何单位；
--   2. 当存在硬阻塞（生产/科研/政策/待晋升/叠栈等）时绝不浪费待命单位行动力；
--   3. 自动跳过严格避开死亡/延迟死亡、自动化、待晋升与同格非法叠栈单位，并经 pcall 无条件
--      恢复原 UI 选区（满足 E-02 / E-06）。
-- 输入：
--   activePlayerID (int)            - 当前人类玩家 ID
--   autoSkipReadyUnits (bool | nil) - 可选，默认 false
-- 输出：(ok: boolean, errMsg: string | nil, EndTurnResultDTO | nil)。
--       门控失败（非法玩家/非活动回合/消息队列忙）第 3 项返回 nil；
--       阻塞拒绝第 3 项返回带 blocking_info 的 EndTurnResultDTO。
-- -----------------------------------------------------------------------------
function CAB_Executor.ExecuteEndTurn(activePlayerID, autoSkipReadyUnits)
    -- 1. E-01 活动回合与消息队列门控
    local gateOk, gateErr, pPlayer = validateActivePlayerWriteGate(activePlayerID)
    if not gateOk then
        return false, gateErr, nil
    end

    local turnNumber = (Game ~= nil and Game.GetGameTurn ~= nil and Game.GetGameTurn()) or 0

    -- 2. 先查询最新回合阻塞状态（决策 D-05：诊断优先）
    local endTurnStatus = CAB_Collector.GetEndTurnStatus(activePlayerID)
    if type(endTurnStatus) ~= "table" or endTurnStatus.error ~= nil then
        return false, (type(endTurnStatus) == "table" and endTurnStatus.error) or "Failed to query end turn status", nil
    end

    local autoSkippedUnitIds = {}

    -- 3. 决策 D-05 守卫式自动跳过：仅当显式开启且当前为可跳过的待命单位阻塞时才执行
    if autoSkipReadyUnits == true
        and endTurnStatus.can_end_turn_now ~= true
        and SKIPPABLE_ENDTURN_BLOCKING[endTurnStatus.blocking_type_name] == true
    then
        local unitsToSkip = {}
        for pUnit in pPlayer:Units() do
            if isUnitAlive(pUnit)
                and pUnit:GetOwner() == activePlayerID
                and safeCallBool(pUnit, "IsReadyToMove")
                and (not safeCallBool(pUnit, "IsAutomated"))
                and (not safeCallBool(pUnit, "IsPromotionReady"))
                and (not isUnitIllegallyStacked(pUnit, activePlayerID))
            then
                table.insert(unitsToSkip, pUnit)
            end
        end

        if #unitsToSkip > 0 then
            local prevUnit = (UI ~= nil and UI.GetHeadSelectedUnit ~= nil) and UI.GetHeadSelectedUnit() or nil

            pcall(function()
                for _, pUnit in ipairs(unitsToSkip) do
                    if isUnitAlive(pUnit) and safeCallBool(pUnit, "IsReadyToMove") then
                        if dispatchSkipMission(pUnit) then
                            table.insert(autoSkippedUnitIds, pUnit:GetID())
                        end
                    end
                end
            end)

            -- 无条件恢复原 UI 选区（E-02 / E-06，绝不触碰 UI.SetInterfaceMode）
            if UI ~= nil then
                if isUnitAlive(prevUnit) then
                    if UI.SelectUnit ~= nil then
                        pcall(UI.SelectUnit, prevUnit)
                    end
                else
                    if UI.ClearSelectionList ~= nil then
                        pcall(UI.ClearSelectionList)
                    end
                end
            end

            -- 跳过后重新复查阻塞态
            endTurnStatus = CAB_Collector.GetEndTurnStatus(activePlayerID)
        end
    end

    -- 4. 复查仍存在阻塞：安全拒绝，绝不强行调用 CONTROL_ENDTURN
    if type(endTurnStatus) ~= "table" or endTurnStatus.can_end_turn_now ~= true then
        local blockingName = (type(endTurnStatus) == "table" and endTurnStatus.blocking_type_name) or "UNKNOWN_BLOCKING"
        return false, "End turn blocked: " .. blockingName, {
            __is_object = true,
            turn_ended = false,
            ended_turn_number = turnNumber,
            auto_skipped_unit_ids = autoSkippedUnitIds,
            status = "BLOCKED",
            blocking_info = endTurnStatus,
        }
    end

    -- 5. 无任何阻塞：提交官方 CONTROL_ENDTURN 并立即返回 WAITING_NEXT_TURN
    local ctrlEndTurn = (GameInfoTypes and GameInfoTypes.CONTROL_ENDTURN)
        or (ControlTypes and ControlTypes.CONTROL_ENDTURN)
    Game.DoControl(ctrlEndTurn)

    debugLog("ExecuteEndTurn submitted CONTROL_ENDTURN for turn=" .. tostring(turnNumber))
    return true, nil, {
        __is_object = true,
        turn_ended = true,
        ended_turn_number = turnNumber,
        auto_skipped_unit_ids = autoSkippedUnitIds,
        status = "WAITING_NEXT_TURN",
    }
end
