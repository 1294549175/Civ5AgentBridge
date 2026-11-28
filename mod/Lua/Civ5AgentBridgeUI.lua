-- =============================================================================
-- 文件：mod/Lua/Civ5AgentBridgeUI.lua
-- 职责：模块 1（游戏端纯 Lua 桥接 Mod）最终 UI 壳层与引擎事件挂载点。
--       作为纯事件转发壳层，仅负责：
--         1. 按自底向上的严格分层顺序守卫式按需加载 6 个正式 Lua 模块；
--         2. 提供右上角状态栏标签刷新回调 CAB_UpdateStatusLabel；
--         3. 调用 CAB_Dispatcher.Initialize(CAB_UpdateStatusLabel) 启动全栈桥接；
--         4. 仅当初始化成功返回 true 时挂载 4 项宿主回调（按钮点击、回合开始、
--            回合结束、ContextPtr:SetUpdate 帧循环），失败则显示错误文案且不挂帧循环。
--
-- 依赖：严格自底向上守卫式按需加载（决策 D-05），避免 Civ5 VFS 重复执行 include()
--       重置有状态子模块的私有 local 状态：
--         CAB_Config -> Civ5AgentBridgeJson -> CAB_ExternalIO
--         -> CAB_InfoCollector -> CAB_TaskExecutor -> CAB_Dispatcher
--
-- 对外契约：
--   * 零全局变量导出（全部内部标志与引导函数均声明为 local）；
--   * 严守红线 I-01：严禁直接调用 SQLite、JSON 编解码、采集器、执行器或任何游戏写接口，
--     全部业务逻辑严格转发给 CAB_Dispatcher；
--   * 严守风险防护 R-04：通过文件级 local s_HooksRegistered 防止宿主回调重复注册。
-- =============================================================================

if CAB_Config == nil then
    include("CAB_Config")
end
if CAB_Json == nil then
    include("Civ5AgentBridgeJson")
end
if CAB_ExternalIO == nil then
    include("CAB_ExternalIO")
end
if CAB_Collector == nil then
    include("CAB_InfoCollector")
end
if CAB_Executor == nil then
    include("CAB_TaskExecutor")
end
if CAB_Dispatcher == nil then
    include("CAB_Dispatcher")
end

-- 文件级防重入标志：确保按钮与引擎事件监听仅注册一次（风险 R-04）
local s_HooksRegistered = false

-- -----------------------------------------------------------------------------
-- 函数：CAB_UpdateStatusLabel(statusText)
-- 做什么：将调度器下发的状态文案安全刷新至右上角 BridgeStatusLabel 控件。
-- 为什么：UI 控件在极端卸载或测试桩环境中可能为空，须前置判空防运行时崩溃。
-- 输入：statusText（任意值，统一 tostring 转换）。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function CAB_UpdateStatusLabel(statusText)
    if Controls ~= nil
        and Controls.BridgeStatusLabel ~= nil
        and type(Controls.BridgeStatusLabel.SetText) == "function"
    then
        Controls.BridgeStatusLabel:SetText(tostring(statusText or ""))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_RegisterHostHooks()
-- 做什么：一次性挂载右上角手动同步按钮点击、玩家回合开始/结束事件与每帧轮询回调。
-- 为什么：所有宿主入口均薄转发至 CAB_Dispatcher 公开接口，并用 s_HooksRegistered
--         守卫杜绝重复 Add 导致单回合事件触发多次。
-- 输入：无。
-- 输出：nil。
-- -----------------------------------------------------------------------------
local function CAB_RegisterHostHooks()
    if s_HooksRegistered then
        return
    end

    if Controls ~= nil
        and Controls.BridgeSyncButton ~= nil
        and type(Controls.BridgeSyncButton.RegisterCallback) == "function"
        and Mouse ~= nil
        and Mouse.eLClick ~= nil
    then
        Controls.BridgeSyncButton:RegisterCallback(Mouse.eLClick, CAB_Dispatcher.OnManualSyncClicked)
    end

    if Events ~= nil
        and Events.ActivePlayerTurnStart ~= nil
        and type(Events.ActivePlayerTurnStart.Add) == "function"
    then
        Events.ActivePlayerTurnStart.Add(CAB_Dispatcher.OnActivePlayerTurnStart)
    end

    if Events ~= nil
        and Events.ActivePlayerTurnEnd ~= nil
        and type(Events.ActivePlayerTurnEnd.Add) == "function"
    then
        Events.ActivePlayerTurnEnd.Add(CAB_Dispatcher.OnActivePlayerTurnEnd)
    end

    if ContextPtr ~= nil and type(ContextPtr.SetUpdate) == "function" then
        ContextPtr:SetUpdate(CAB_Dispatcher.OnFrameUpdate)
    end

    s_HooksRegistered = true
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_Bootstrap()
-- 做什么：校验 CAB_Dispatcher 核心入口就绪，经 pcall 执行全栈初始化并按结果决定
--         挂载宿主回调或降级显示失败提示。
-- 为什么：遵循决策 D-05，初始化失败时绝不挂载 ContextPtr:SetUpdate 帧循环，
--         防止游戏每帧刷屏报错影响玩家正常体验。
-- 输入：无。
-- 输出：boolean（引导启动是否成功）。
-- -----------------------------------------------------------------------------
local function CAB_Bootstrap()
    if type(CAB_Dispatcher) ~= "table"
        or type(CAB_Dispatcher.Initialize) ~= "function"
        or type(CAB_Dispatcher.OnManualSyncClicked) ~= "function"
        or type(CAB_Dispatcher.OnActivePlayerTurnStart) ~= "function"
        or type(CAB_Dispatcher.OnActivePlayerTurnEnd) ~= "function"
        or type(CAB_Dispatcher.OnFrameUpdate) ~= "function"
    then
        CAB_UpdateStatusLabel("Agent Bridge: Init Failed")
        if print ~= nil then
            print("[Civ5AgentBridge][ERROR] Civ5AgentBridgeUI bootstrap failed: CAB_Dispatcher interface incomplete.")
        end
        return false
    end

    local okCall, okInit = pcall(CAB_Dispatcher.Initialize, CAB_UpdateStatusLabel)
    if okCall and okInit == true then
        CAB_RegisterHostHooks()
        if print ~= nil then
            print("[Civ5AgentBridge] Civ5AgentBridgeUI initialized (modular 5-layer bridge active).")
        end
        return true
    end

    CAB_UpdateStatusLabel("Agent Bridge: Init Failed")
    if print ~= nil then
        local reason = okCall and "CAB_Dispatcher.Initialize returned false" or tostring(okInit)
        print("[Civ5AgentBridge][ERROR] Civ5AgentBridgeUI bootstrap failed: " .. reason)
    end
    return false
end

CAB_Bootstrap()
