# -*- coding: utf-8 -*-
"""
模块名称：sqlite_bridge.py
职责说明：
    将 EXP-03 / EXP-04 验证通过的《文明5》ModUserData SQLite SimpleValues 跨进程通信协议
    封装为面向 MCP Server 的异步 RPC 客户端（AsyncSqliteBridgeClient）：
    1. 使用 asyncio.Lock 串行化飞行中的单工请求-应答，避免并发调用争抢同一个 rpc_request/rpc_response 槽位；
    2. 将全部 SQLite 阻塞磁盘 I/O 放入 asyncio.to_thread，确保 MCP Server 事件循环零阻塞；
    3. 复用 3KB 自动分片读写机制（key#chunk_count / key#chunk_i），兼容大载荷 JSON；
    4. 提供独立的模拟《文明5》Lua SQLite 轮询进程（simulated_civ5_lua_loop），供无游戏进程时的 LIVE 模式双进程联调验收。
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
import sqlite3
import time
from typing import Any

CHUNK_SIZE = 3000
DEFAULT_LIVE_DB_PATH = Path(
    r"c:\Users\Admin\Documents\My Games\Sid Meier's Civilization 5\ModUserData\Civ5AgentBridge-1.db"
)


class SyncSqliteBridgeClient:
    """
    底层同步 SQLite SimpleValues 读写与分片传输客户端。
    原因：sqlite3 连接不可跨线程复用，每次同步调用使用短连接 + BEGIN IMMEDIATE 事务，
    既兼容《文明5》自带旧版 SQLite 引擎，又能避免跨线程句柄冲突与文件锁死锁。
    """

    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self._req_counter = int(time.time() * 100) % 1_000_000

    def _connect(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.db_path), timeout=10.0, isolation_level=None)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS SimpleValues(Name TEXT Primary Key, Value VARIANT)"
        )
        return conn

    def get_value(self, key: str) -> str | None:
        """读取 SimpleValues 表单个键值。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?", (key,)
            ).fetchone()
            return str(row[0]) if row and row[0] is not None else None

    def set_value(self, key: str, value: str) -> None:
        """写入 SimpleValues 表单个键值。"""
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                (key, value),
            )

    def write_payload(
        self, key: str, payload_str: str, force_chunked: bool = False
    ) -> None:
        """
        将任意长度 JSON 字符串写入 SimpleValues，并在超过 CHUNK_SIZE 时同步写入分片槽位。
        原因：与 Civ5AgentBridgeCore.lua 的 CAB_DbWritePayload / CAB_DbReadPayload 协议严格对称。
        """
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if force_chunked or len(payload_str) > CHUNK_SIZE:
                total = (len(payload_str) + CHUNK_SIZE - 1) // CHUNK_SIZE
                for idx in range(total):
                    part = payload_str[idx * CHUNK_SIZE : (idx + 1) * CHUNK_SIZE]
                    conn.execute(
                        "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                        (f"{key}#chunk_{idx + 1}", part),
                    )
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (f"{key}#chunk_count", str(total)),
                )
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (key, f"__CHUNKED__:{len(payload_str)}"),
                )
            else:
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (key, payload_str),
                )
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (f"{key}#chunk_count", "0"),
                )
            conn.execute("COMMIT")

    def read_payload(self, key: str) -> str | None:
        """读取 SimpleValues 载荷，若存在分片标记则自动拼接全部分片。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?",
                (f"{key}#chunk_count",),
            ).fetchone()
            chunk_count = int(row[0]) if row and str(row[0]).isdigit() else 0
            if chunk_count > 0:
                parts: list[str] = []
                for idx in range(1, chunk_count + 1):
                    crow = conn.execute(
                        "SELECT Value FROM SimpleValues WHERE Name = ?",
                        (f"{key}#chunk_{idx}",),
                    ).fetchone()
                    parts.append(str(crow[0]) if crow and crow[0] is not None else "")
                return "".join(parts)
            vrow = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?", (key,)
            ).fetchone()
            return str(vrow[0]) if vrow and vrow[0] is not None else None

    def next_req_id(self) -> int:
        """生成严格递增的请求序号，避免 Lua 端按 g_LastReqId 去重时忽略新请求。"""
        current_in_db = self.get_value("rpc_request_req_id")
        if current_in_db and current_in_db.isdigit():
            self._req_counter = max(self._req_counter, int(current_in_db))
        self._req_counter += 1
        return self._req_counter


class AsyncSqliteBridgeClient:
    """
    面向 FastMCP / MCPServer 的异步 SQLite RPC 客户端。
    保证在多客户端并发请求（如 Streamable HTTP）下通过 asyncio.Lock 严格串行访问管道。
    """

    def __init__(
        self,
        db_path: Path,
        default_timeout_sec: float = 8.0,
        poll_interval_sec: float = 0.02,
    ) -> None:
        self.db_path = db_path
        self.default_timeout_sec = default_timeout_sec
        self.poll_interval_sec = poll_interval_sec
        self._sync = SyncSqliteBridgeClient(db_path)
        self._req_lock = asyncio.Lock()

    async def read_heartbeat(self) -> dict[str, Any] | None:
        """异步读取游戏 Lua Mod 写入的 bridge_heartbeat 心跳信息。"""
        raw = await asyncio.to_thread(self._sync.get_value, "bridge_heartbeat")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"raw": raw}

    async def send_ipc_request(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout_sec: float | None = None,
    ) -> dict[str, Any]:
        """
        向游戏端发送一次 JSON-RPC 请求并异步轮询等待对应 req_id 的响应。
        原因：使用 asyncio.Lock 确保同一时刻只有一个 RPC 在 SimpleValues 槽位飞行，
        且轮询休眠使用 await asyncio.sleep，不会卡住 MCP Server 的并发事件循环。
        """
        timeout = timeout_sec if timeout_sec is not None else self.default_timeout_sec
        async with self._req_lock:
            req_id = await asyncio.to_thread(self._sync.next_req_id)
            req_obj = {"req_id": req_id, "method": method, "params": params or {}}
            req_json = json.dumps(req_obj, ensure_ascii=False)

            def _submit_request() -> None:
                self._sync.write_payload("rpc_request", req_json)
                self._sync.set_value("rpc_request_req_id", str(req_id))

            await asyncio.to_thread(_submit_request)

            deadline = time.perf_counter() + timeout
            while time.perf_counter() < deadline:
                resp_id_str = await asyncio.to_thread(
                    self._sync.get_value, "rpc_response_req_id"
                )
                if (
                    resp_id_str is not None
                    and resp_id_str.isdigit()
                    and int(resp_id_str) == req_id
                ):
                    raw_resp = await asyncio.to_thread(
                        self._sync.read_payload, "rpc_response"
                    )
                    resp_obj = json.loads(raw_resp or "{}")
                    if not resp_obj.get("ok", False):
                        err_msg = resp_obj.get("error") or "Unknown Lua RPC error"
                        raise RuntimeError(f"Lua RPC '{method}' failed: {err_msg}")
                    return resp_obj.get("data", {})
                await asyncio.sleep(self.poll_interval_sec)

            raise TimeoutError(
                f"SQLite RPC '{method}' (req_id={req_id}, db={self.db_path}) "
                f"timed out after {timeout:.1f}s. 请确认《文明5》已启用 Civ5AgentBridge Mod 且处于玩家回合。"
            )


def simulated_civ5_lua_loop(db_path_str: str, stop_event: Any) -> None:
    """
    独立子进程：忠实模拟《文明5》Civ5AgentBridgeUI.lua + Civ5AgentBridgeCore.lua 的
    SimpleValues 帧轮询与单位状态机，用于 EXP-06 的 LIVE 模式真实跨进程 SQLite 联调。
    """
    sync = SyncSqliteBridgeClient(Path(db_path_str))
    last_req_id = -1

    unit_state: dict[str, Any] = {
        "unit_id": 8192,
        "name": "第1侦察队",
        "unit_type": "UNIT_SCOUT",
        "domain": "LAND",
        "x": 14,
        "y": 18,
        "hp": 100,
        "max_hp": 100,
        "moves_left": 2.0,
        "max_moves": 2.0,
        "combat_str": 5,
        "ranged_str": 0,
        "range": 0,
        "is_fortified": False,
        "can_act": True,
    }
    visible_enemies: list[dict[str, Any]] = []

    sync.set_value(
        "bridge_heartbeat",
        json.dumps(
            {
                "turn": 45,
                "active_player": 0,
                "lua_ts": time.time(),
                "status": "IDLE",
                "mode": "SIMULATED_LIVE",
            },
            ensure_ascii=False,
        ),
    )

    while not stop_event.is_set():
        req_id_str = sync.get_value("rpc_request_req_id")
        if req_id_str and req_id_str.isdigit() and int(req_id_str) > last_req_id:
            last_req_id = int(req_id_str)
            raw_req = sync.read_payload("rpc_request")
            req = json.loads(raw_req or "{}")
            method = req.get("method", "")
            params = req.get("params", {})

            if method == "ping":
                resp_data: dict[str, Any] = {
                    "pong": params.get("echo", "pong"),
                    "turn": 45,
                    "active_player": 0,
                }
            elif method == "get_turn_overview":
                # 故意保持与 Civ5AgentBridgeCore.lua 完全一致的原始输出结构，验证 Python 适配层补齐逻辑
                resp_data = {
                    "turn_number": 45,
                    "active_player_id": 0,
                    "player_civ": "中国",
                    "yields": {
                        "gold": 240,
                        "gold_per_turn": 14,
                        "science_per_turn": 38,
                        "happiness": 6,
                    },
                    "our_units": [unit_state],
                    "visible_enemies": visible_enemies,
                    "our_cities": [
                        {
                            "city_id": 1,
                            "name": "北京",
                            "x": 11,
                            "y": 15,
                            "pop": 7,
                            "hp": 100,
                        }
                    ],
                }
            elif method == "get_unit_context":
                ux, uy = unit_state["x"], unit_state["y"]
                resp_data = {
                    "unit": unit_state,
                    "surrounding_tiles": [
                        {
                            "x": ux,
                            "y": uy,
                            "distance": 0,
                            "visibility": "VISIBLE",
                            "terrain": "TERRAIN_PLAINS",
                            "feature": None,
                            "is_hills": True,
                            "has_river": True,
                            "friendly_unit_id": unit_state["unit_id"],
                            "enemy_unit": None,
                        },
                        {
                            "x": ux + 1,
                            "y": uy,
                            "distance": 1,
                            "visibility": "VISIBLE",
                            "terrain": "TERRAIN_PLAINS",
                            "feature": None,
                            "is_hills": True,
                            "has_river": False,
                            "friendly_unit_id": None,
                            "enemy_unit": None,
                        },
                        {
                            "x": ux + 2,
                            "y": uy,
                            "distance": 2,
                            "visibility": "REVEALED_FOG",
                            "terrain": "TERRAIN_PLAINS",
                            "feature": "FEATURE_FOREST",
                            "is_hills": False,
                            "has_river": False,
                            "friendly_unit_id": None,
                            "enemy_unit": None,
                        },
                    ],
                    "candidate_actions": [
                        {
                            "action_id": "ACT_01",
                            "action_type": "MOVE_STEP",
                            "target_x": ux + 1,
                            "target_y": uy,
                            "estimated_cost_moves": 1.0,
                            "note": "Step move to adjacent hex",
                        },
                        {
                            "action_id": "ACT_02",
                            "action_type": "FORTIFY",
                            "target_x": ux,
                            "target_y": uy,
                            "estimated_cost_moves": 1.0,
                            "note": "Fortify at current tile",
                        },
                        {
                            "action_id": "ACT_03",
                            "action_type": "SKIP_TURN",
                            "target_x": ux,
                            "target_y": uy,
                            "estimated_cost_moves": 0.0,
                            "note": "Hold / Skip remaining movement this turn",
                        },
                    ],
                }
            elif method == "execute_unit_action":
                wait_sec = float(params.get("settle_delay_sec", 0.25))
                if wait_sec > 0:
                    time.sleep(wait_sec)
                action_type = str(params.get("action_type", "MOVE_STEP"))
                tx = int(params.get("target_x", unit_state["x"]))
                ty = int(params.get("target_y", unit_state["y"]))
                if action_type == "MOVE_STEP":
                    unit_state["x"] = tx
                    unit_state["y"] = ty
                    unit_state["moves_left"] = max(0.0, unit_state["moves_left"] - 1.0)
                    unit_state["can_act"] = unit_state["moves_left"] > 0
                else:
                    unit_state["is_fortified"] = action_type == "FORTIFY"
                    unit_state["moves_left"] = 0.0
                    unit_state["can_act"] = False

                newly_spotted = [
                    {
                        "enemy_id": "63:1024",
                        "owner_id": 63,
                        "owner_name": "蛮族",
                        "is_barbarian": True,
                        "unit_type": "UNIT_BARBARIAN_SWORDSMAN",
                        "x": tx + 1,
                        "y": ty,
                        "hp": 100,
                        "combat_str": 14,
                        "ranged_str": 0,
                    }
                ]
                visible_enemies = newly_spotted
                resp_data = {
                    "executed": True,
                    "action_type": action_type,
                    "target_x": tx,
                    "target_y": ty,
                    "settle_wait_ms": int(wait_sec * 1000),
                    "unit_died": False,
                    "unit_after": unit_state,
                    "delta_observation": {
                        "newly_spotted_enemies": newly_spotted,
                        "newly_spotted_count": len(newly_spotted),
                    },
                }
            else:
                resp = {
                    "req_id": last_req_id,
                    "ok": False,
                    "data": None,
                    "error": f"Unknown method: {method}",
                }
                sync.write_payload("rpc_response", json.dumps(resp, ensure_ascii=False))
                sync.set_value("rpc_response_req_id", str(last_req_id))
                continue

            resp = {"req_id": last_req_id, "ok": True, "data": resp_data, "error": None}
            sync.write_payload("rpc_response", json.dumps(resp, ensure_ascii=False))
            sync.set_value("rpc_response_req_id", str(last_req_id))
        time.sleep(0.03)
