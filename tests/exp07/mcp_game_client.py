# -*- coding: utf-8 -*-
"""
模块名称：mcp_game_client.py
职责说明：
    为 Textual TUI 与编排引擎提供持久化的异步 MCP Client 适配器（Civ5McpSessionAdapter）：
    1. 通过官方 mcp 2.3.0 的 stdio_client + ClientSession 启动并复用 EXP-06 交付的 civ5_mcp_server.py；
    2. 暴露强类型异步方法（get_turn_overview / get_unit_context_and_candidates / execute_unit_step / save_turn_snapshot），
       使 EXP-07 的 TUI 真正跑通“Textual TUI -> 编排器 -> MCP 协议 -> 沙盘/游戏桥接”端到端链路；
    3. 全部调用均为非阻塞 asyncio 协程，并可通过可选 simulated_rtt_sec 模拟游戏内 SQLite 轮询与动画结算耗时，
       以严苛验证 TUI 在等待游戏响应期间仍维持 60fps 流畅交互。
"""

from __future__ import annotations

import asyncio
from contextlib import AsyncExitStack
import json
import os
from pathlib import Path
import sys
from typing import Any, Literal

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from ..exp05.schemas import (
    ActionExecutionResultDTO,
    HandoffDocument,
    TurnOverviewDTO,
    UnitTacticalContextDTO,
)
from ..exp06.bridge_service import EXP05_DEFAULT_SNAPSHOT

EXP06_MCP_SERVER_SCRIPT = (
    Path(__file__).resolve().parent.parent / "exp06" / "civ5_mcp_server.py"
)


def _extract_mcp_payload(result: Any) -> Any:
    """兼容提取 mcp 2.x CallToolResult 内的 structured_content 或 JSON 文本。"""
    if getattr(result, "is_error", False):
        raise RuntimeError(f"MCP Tool 调用失败: {result.content}")
    sc = getattr(result, "structured_content", None)
    if sc is not None:
        if (
            isinstance(sc, dict)
            and set(sc.keys()) == {"result"}
            and isinstance(sc["result"], str)
        ):
            return sc["result"]
        return sc
    texts = [
        getattr(b, "text", "")
        for b in (getattr(result, "content", None) or [])
        if getattr(b, "type", None) == "text"
    ]
    joined = "\n".join(texts).strip()
    try:
        return json.loads(joined)
    except json.JSONDecodeError:
        return joined


class Civ5McpSessionAdapter:
    """
    持久异步 MCP Client 会话适配器。
    原因：避免每调用一次工具就冷启动一次 Python MCP Server 子进程，显著降低回合交互延迟并保持沙盘状态连续。
    """

    def __init__(
        self,
        mode: Literal["MOCK", "LIVE"] = "MOCK",
        snapshot_path: Path = EXP05_DEFAULT_SNAPSHOT,
        live_db_path: Path | None = None,
        snapshots_dir: Path | None = None,
        simulated_poll_delay_sec: float = 0.12,
    ) -> None:
        self.mode: Literal["MOCK", "LIVE"] = mode
        self.snapshot_path = snapshot_path
        self.live_db_path = live_db_path
        self.snapshots_dir = snapshots_dir
        self.simulated_poll_delay_sec = simulated_poll_delay_sec

        self._owner_task: asyncio.Task[None] | None = None
        self._ready_event: asyncio.Event | None = None
        self._stop_event: asyncio.Event | None = None
        self._connect_error: BaseException | None = None
        self._discovered_tools: list[str] = []
        self._session: ClientSession | None = None
        self._call_lock = asyncio.Lock()
        self.prev_handoff: HandoffDocument = self._load_prev_handoff(snapshot_path)
        self.mcp_calls_count: int = 0

    @staticmethod
    def _load_prev_handoff(snapshot_path: Path) -> HandoffDocument:
        """从离线快照中读取上一回合交接材料（若无则构造默认占位）。"""
        if snapshot_path.exists():
            raw = json.loads(snapshot_path.read_text(encoding="utf-8"))
            if isinstance(raw.get("prev_handoff"), dict):
                return HandoffDocument.model_validate(raw["prev_handoff"])
        return HandoffDocument(
            from_turn=44,
            long_term_strategy="北线稳健推进与视野控制。",
            active_operations=[],
            unresolved_threats=[],
            last_turn_execution_summary="默认交接占位。",
        )

    @property
    def is_connected(self) -> bool:
        return self._session is not None

    async def _session_lifecycle_loop(self, params: StdioServerParameters) -> None:
        """
        单协程独占 MCP Stdio 会话生命周期任务（Owner Task）。
        原因：mcp 2.x 的 stdio_client / ClientSession 底层使用 anyio.TaskGroup，
        anyio 严格要求 enter 与 exit 必须在同一个 asyncio.Task 中完成，否则在 Textual on_unmount
        跨任务关闭时会触发 `Attempted to exit cancel scope in a different task`。
        """
        assert self._ready_event is not None and self._stop_event is not None
        try:
            async with AsyncExitStack() as stack:
                read_stream, write_stream = await stack.enter_async_context(
                    stdio_client(params)
                )
                session = await stack.enter_async_context(
                    ClientSession(read_stream, write_stream)
                )
                await session.initialize()
                tools = await session.list_tools()
                self._discovered_tools = sorted(t.name for t in tools.tools)
                self._session = session
                self._ready_event.set()
                await self._stop_event.wait()
        except BaseException as exc:
            self._connect_error = exc
            if not self._ready_event.is_set():
                self._ready_event.set()
        finally:
            self._session = None

    async def connect(self) -> list[str]:
        """建立与 EXP-06 MCP Server 的持久 Stdio 连接并返回可用工具列表。"""
        if self._session is not None:
            return list(self._discovered_tools)

        env = dict(os.environ)
        env["CIV5_BRIDGE_MODE"] = self.mode
        env["CIV5_MOCK_SNAPSHOT"] = str(self.snapshot_path)
        if self.live_db_path is not None:
            env["CIV5_LIVE_DB"] = str(self.live_db_path)
        if self.snapshots_dir is not None:
            self.snapshots_dir.mkdir(parents=True, exist_ok=True)
            env["CIV5_SNAPSHOTS_DIR"] = str(self.snapshots_dir)

        params = StdioServerParameters(
            command=sys.executable,
            args=[str(EXP06_MCP_SERVER_SCRIPT)],
            env=env,
        )
        self._ready_event = asyncio.Event()
        self._stop_event = asyncio.Event()
        self._connect_error = None
        self._owner_task = asyncio.create_task(self._session_lifecycle_loop(params))
        await self._ready_event.wait()
        if self._connect_error is not None:
            raise self._connect_error
        return list(self._discovered_tools)

    async def close(self) -> None:
        """通知独占生命周期任务安全退出并等待其完成资源回收。"""
        if self._stop_event is not None:
            self._stop_event.set()
        if self._owner_task is not None:
            try:
                await asyncio.wait_for(self._owner_task, timeout=5.0)
            except asyncio.TimeoutError:
                self._owner_task.cancel()
            finally:
                self._owner_task = None
                self._session = None

    async def _call_tool(self, name: str, args: dict[str, Any]) -> Any:
        assert self._session is not None, "MCP 会话尚未连接，请先调用 connect()"
        async with self._call_lock:
            if self.simulated_poll_delay_sec > 0:
                # 模拟游戏内 SQLite 轮询/动画结算等待，检验异步事件循环绝不阻塞 UI
                await asyncio.sleep(self.simulated_poll_delay_sec)
            res = await self._session.call_tool(name, args)
            self.mcp_calls_count += 1
            return _extract_mcp_payload(res)

    async def get_turn_overview(self) -> TurnOverviewDTO:
        raw = await self._call_tool("get_turn_overview", {})
        return TurnOverviewDTO.model_validate(raw)

    async def get_unit_context_and_candidates(
        self, unit_id: int, radius: int = 2
    ) -> UnitTacticalContextDTO:
        raw = await self._call_tool(
            "get_unit_context_and_candidates", {"unit_id": unit_id, "radius": radius}
        )
        return UnitTacticalContextDTO.model_validate(raw)

    async def execute_unit_step(
        self, unit_id: int, action_type: str, target_x: int, target_y: int
    ) -> ActionExecutionResultDTO:
        raw = await self._call_tool(
            "execute_unit_step",
            {
                "unit_id": unit_id,
                "action_type": action_type,
                "target_x": target_x,
                "target_y": target_y,
            },
        )
        return ActionExecutionResultDTO.model_validate(raw)

    async def save_turn_snapshot(self, tag: str) -> str:
        raw = await self._call_tool("save_turn_snapshot", {"tag": tag})
        return str(raw)
