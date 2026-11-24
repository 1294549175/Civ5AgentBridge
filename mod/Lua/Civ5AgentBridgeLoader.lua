--------------------------------------------------------------------------------
-- Civ5AgentBridgeLoader.lua —— InGameUIAddin 空壳装配器脚本
-- 做什么：作为 modinfo 的 InGameUIAddin 入口被加载，仅输出一条装配日志；
--         实际业务上下文 Civ5AgentBridgeUI 由同名 Civ5AgentBridgeLoader.xml 内嵌 <LuaContext> 装配。
-- 为什么：严格遵循 AGENTS.md 硬性纪律第3条（参照 IGE_Loader.lua 与 AirRaidLoader.lua 实证形态）。
--------------------------------------------------------------------------------

print("[Civ5AgentBridge] Civ5AgentBridgeLoader context loaded.");
