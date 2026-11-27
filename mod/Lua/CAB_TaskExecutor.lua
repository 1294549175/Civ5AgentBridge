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

-- 保留对基础守卫的局部引用（WP2~WP4 各公开接口直接复用，避免静态分析误报未用局部）
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
