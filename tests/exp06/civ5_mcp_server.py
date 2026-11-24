# -*- coding: utf-8 -*-
"""
模块名称：civ5_mcp_server.py
职责说明：
    实现《02_软件总体设计说明书》模块 2 与《03_接口设计说明书》§2 定义的标准化 Civ5 MCP Server：
    1. 适配本机官方 mcp 2.x SDK（MCPServer，原 FastMCP，并保留 v1 FastMCP 兼容回退）；
    2. 严格暴露 5 个标准 MCP Tools：
       - get_turn_overview()
       - get_unit_context_and_candidates(unit_id, radius=3)
       - execute_unit_step(unit_id, action_type, target_x, target_y)
       - save_turn_snapshot(tag)
       - load_turn_snapshot(snapshot_path)
    3. 支持通过 CLI 参数（--mock-snapshot / --live-db）或环境变量（CIV5_BRIDGE_MODE / CIV5_MOCK_SNAPSHOT / CIV5_LIVE_DB）
       一键切换离线 MOCK 与实机 LIVE 模式；
    4. 支持 stdio（默认，供编排器与 agy mcp add 挂载）与 streamable-http（多客户端并发兜底方案）双传输协议。
"""

from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
import sys
from typing import Any

# 允许直接以 `python path/to/civ5_mcp_server.py` 方式被 agy mcp add 启动
if __package__ in (None, ""):
    _repo_root = Path(__file__).resolve().parents[3]
    if str(_repo_root) not in sys.path:
        sys.path.insert(0, str(_repo_root))
    from Civ5AgentBridge.tests.exp06.bridge_service import Civ5BridgeRuntime
else:
    from .bridge_service import Civ5BridgeRuntime

try:
    # mcp >= 2.0 官方类名（本机实测 mcp 2.3.0）
    from mcp.server.mcpserver import MCPServer as _BaseMCPServer

    MCP_SDK_FLAVOR = "mcp2.MCPServer"
except ImportError:  # pragma: no cover - 兼容 mcp 1.x 环境
    from mcp.server.fastmcp import FastMCP as _BaseMCPServer  # type: ignore[no-redef]

    MCP_SDK_FLAVOR = "mcp1.FastMCP"


def create_civ5_mcp_server(runtime: Civ5BridgeRuntime) -> _BaseMCPServer:
    """
    创建并注册包含全部 5 个《文明5》桥接工具的 MCP Server 实例。
    原因：采用工厂函数解耦运行时实例化与服务器注册，既便于命令行启动，也便于单元测试直接注入自定义运行时。
    """
    server = _BaseMCPServer(
        name="civ5-agent-bridge",
        instructions=(
            "《文明5：美丽新世界 (BNW)》智能体桥接 MCP 服务。"
            "严格遵守战争迷雾合规边界，仅返回当前玩家实时可见或已探索的战场态势。"
            "可调用 get_turn_overview 读取全局态势，调用 get_unit_context_and_candidates 查询单兵周边与合法动作，"
            "调用 execute_unit_step 下发单步原子动作并获取增量揭盲敌情，或使用 save_turn_snapshot / load_turn_snapshot 管理离线快照。"
        ),
        log_level="WARNING",
    )

    @server.tool()
    async def get_turn_overview() -> dict[str, Any]:
        """
        获取《文明5》当前回合的全局可见态势（TurnOverviewDTO）。
        返回回合号、玩家文明、经济科研产出、己方存活单位列表、当前实时可见的敌方/蛮族单位、己方城市与已探索敌方城市。
        严禁透传战争迷雾内未见敌军。
        """
        return await runtime.get_turn_overview()

    @server.tool()
    async def get_unit_context_and_candidates(
        unit_id: int, radius: int = 3
    ) -> dict[str, Any]:
        """
        提取指定己方单位周边半径 radius 格内的已探索六边形地块信息，以及由规则引擎校验过的合法单步候选动作列表（UnitTacticalContextDTO）。
        参数:
            unit_id: 己方单位唯一 ID（来自 get_turn_overview.our_units）。
            radius: 局部网格扫描半径（默认 3 格）。
        """
        return await runtime.get_unit_context_and_candidates(
            unit_id=unit_id, radius=radius
        )

    @server.tool()
    async def execute_unit_step(
        unit_id: int, action_type: str, target_x: int, target_y: int
    ) -> dict[str, Any]:
        """
        在游戏或离线沙盘中驱动指定单位执行单步原子动作，并在结算后立即返回最新单位状态与增量揭盲视野（ActionExecutionResultDTO）。
        参数:
            unit_id: 己方单位唯一 ID。
            action_type: 合法动作类型（MOVE_STEP / MELEE_ATTACK / RANGE_ATTACK / AIR_STRIKE / FORTIFY / HEAL / SKIP_TURN）。
            target_x: 目标六边形地块 X 坐标。
            target_y: 目标六边形地块 Y 坐标。
        """
        return await runtime.execute_unit_step(
            unit_id=unit_id,
            action_type=action_type,
            target_x=target_x,
            target_y=target_y,
        )

    @server.tool()
    async def save_turn_snapshot(tag: str) -> str:
        """
        将当前回合完整态势导出为本地离线 JSON 快照文件（data/snapshots），返回保存后的绝对文件路径。
        参数:
            tag: 快照自定义标签（例如 'before_ambush' 或 'turn45_live'）。
        """
        return await runtime.save_turn_snapshot(tag=tag)

    @server.tool()
    async def load_turn_snapshot(snapshot_path: str) -> dict[str, Any]:
        """
        将 MCP Server 切换为离线 MOCK 模式并加载指定路径的 JSON 回合快照，返回加载状态与最新全局态势（overview）。
        参数:
            snapshot_path: 快照文件的绝对路径或位于快照目录下的文件名。
        """
        return await runtime.load_turn_snapshot(snapshot_path=snapshot_path)

    return server


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """解析命令行参数，支持通过 CLI 或环境变量一键切换 MOCK / LIVE 与 stdio / streamable-http。"""
    parser = argparse.ArgumentParser(
        description="Civ5 Agent Bridge MCP Server (支持 MOCK 离线快照与 LIVE 实机 SQLite 双模式)"
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--mock-snapshot",
        type=str,
        default=None,
        help="以离线 MOCK 模式启动并加载指定回合快照 JSON 文件（覆盖环境变量 CIV5_BRIDGE_MODE）",
    )
    mode_group.add_argument(
        "--live-db",
        type=str,
        default=None,
        help="以实机 LIVE 模式启动并连接指定 ModUserData SQLite 文件（覆盖环境变量 CIV5_BRIDGE_MODE）",
    )
    parser.add_argument(
        "--snapshots-dir",
        type=str,
        default=None,
        help="save_turn_snapshot 默认输出目录",
    )
    parser.add_argument(
        "--rpc-timeout",
        type=float,
        default=None,
        help="LIVE 模式 SQLite RPC 超时秒数（默认 8.0）",
    )
    parser.add_argument(
        "--transport",
        choices=["stdio", "streamable-http"],
        default=os.environ.get("CIV5_MCP_TRANSPORT", "stdio"),
        help="MCP 传输协议：stdio（默认）或 streamable-http（多客户端并发兜底）",
    )
    parser.add_argument(
        "--host",
        type=str,
        default=os.environ.get("CIV5_MCP_HOST", "127.0.0.1"),
        help="streamable-http 模式监听地址（默认 127.0.0.1）",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("CIV5_MCP_PORT", "8765")),
        help="streamable-http 模式监听端口（默认 8765）",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    """MCP Server 命令行主入口；强制日志写入 stderr 以防污染 stdio JSON-RPC 帧流。"""
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.WARNING,
        format="[Civ5MCP] %(levelname)s %(message)s",
    )
    args = parse_args(argv)
    runtime = Civ5BridgeRuntime.from_env_and_args(
        mock_snapshot=args.mock_snapshot,
        live_db=args.live_db,
        snapshots_dir=args.snapshots_dir,
        rpc_timeout_sec=args.rpc_timeout,
    )
    server = create_civ5_mcp_server(runtime)

    if args.transport == "streamable-http":
        server.run(
            transport="streamable-http",
            host=args.host,
            port=args.port,
            streamable_http_path="/mcp",
        )
    else:
        server.run(transport="stdio")


if __name__ == "__main__":
    main()
