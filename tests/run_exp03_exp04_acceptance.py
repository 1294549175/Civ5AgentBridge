# -*- coding: utf-8 -*-
"""
EXP-03 & EXP-04 跨进程 SQLite IPC、单位候选动作枚举与动作结算/增量视野验收测试脚本
支持两种模式：
1. --mode simulate : 启动独立子进程模拟《文明5》ModUserData SQLite 帧轮询引擎，执行双进程真实 SQLite 并发验收；
2. --mode live     : 连接正在运行的《文明5》ModUserData/Civ5AgentBridge-1.db 执行实机联机验收。
"""

import argparse
import json
import multiprocessing as mp
from pathlib import Path
import sqlite3
import sys
import time
from typing import Any

CHUNK_SIZE = 3000
DEFAULT_DB_PATH = Path(r"c:\Users\Admin\Documents\My Games\Sid Meier's Civilization 5\ModUserData\Civ5AgentBridge-1.db")


class Civ5SqliteBridgeClient:
    """外部 Python 侧与《文明5》Modding.OpenUserData SQLite 通信客户端。"""

    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self._req_counter = int(time.time() * 10) % 100000

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path), timeout=10.0, isolation_level=None)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS SimpleValues(Name TEXT Primary Key, Value VARIANT)"
        )
        return conn

    def get_value(self, key: str) -> str | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?", (key,)
            ).fetchone()
            return str(row[0]) if row and row[0] is not None else None

    def set_value(self, key: str, value: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                (key, value),
            )

    def write_payload(self, key: str, payload_str: str, force_chunked: bool = False) -> None:
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
        with self._connect() as conn:
            row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?", (f"{key}#chunk_count",)
            ).fetchone()
            chunk_count = int(row[0]) if row and str(row[0]).isdigit() else 0
            if chunk_count > 0:
                parts = []
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

    def rpc_call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout_sec: float = 5.0,
        force_chunked: bool = False,
    ) -> tuple[dict[str, Any], float]:
        self._req_counter += 1
        req_id = self._req_counter
        req_obj = {"req_id": req_id, "method": method, "params": params or {}}
        t0 = time.perf_counter()

        self.write_payload(
            "rpc_request", json.dumps(req_obj, ensure_ascii=False), force_chunked=force_chunked
        )
        self.set_value("rpc_request_req_id", str(req_id))

        deadline = time.perf_counter() + timeout_sec
        while time.perf_counter() < deadline:
            resp_id_str = self.get_value("rpc_response_req_id")
            if resp_id_str is not None and resp_id_str.isdigit() and int(resp_id_str) == req_id:
                raw_resp = self.read_payload("rpc_response")
                rtt_ms = (time.perf_counter() - t0) * 1000.0
                return json.loads(raw_resp or "{}"), rtt_ms
            time.sleep(0.015)
        raise TimeoutError(f"RPC call '{method}' (req_id={req_id}) timed out after {timeout_sec}s")


def _simulated_civ5_lua_loop(db_path_str: str, stop_event: Any) -> None:
    """独立子进程：严格复刻《文明5》SimpleValues 表行为与 Civ5AgentBridgeUI.lua 的 50ms/200ms 帧轮询结算状态机。"""
    client = Civ5SqliteBridgeClient(Path(db_path_str))
    last_req_id = -1
    unit_state = {
        "unit_id": 8192,
        "name": "侦察兵",
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
        "can_act": True,
    }
    client.set_value(
        "bridge_heartbeat",
        json.dumps({"turn": 45, "active_player": 0, "status": "IDLE", "mode": "SIMULATED"}),
    )

    while not stop_event.is_set():
        req_id_str = client.get_value("rpc_request_req_id")
        if req_id_str and req_id_str.isdigit() and int(req_id_str) > last_req_id:
            last_req_id = int(req_id_str)
            raw_req = client.read_payload("rpc_request")
            req = json.loads(raw_req or "{}")
            method = req.get("method", "")
            params = req.get("params", {})

            if method == "ping":
                resp_data = {"pong": params.get("echo", "pong"), "turn": 45, "active_player": 0}
                resp = {"req_id": last_req_id, "ok": True, "data": resp_data, "error": None}
                client.write_payload("rpc_response", json.dumps(resp))
                client.set_value("rpc_response_req_id", str(last_req_id))

            elif method == "test_large_payload":
                target_bytes = int(params.get("target_bytes", 32768))
                use_chunk = bool(params.get("use_chunk", False))
                incoming = str(params.get("payload", ""))
                blob = "X" * target_bytes
                resp_data = {
                    "received_len": len(incoming),
                    "generated_len": len(blob),
                    "payload_blob": blob,
                }
                resp = {"req_id": last_req_id, "ok": True, "data": resp_data, "error": None}
                client.write_payload("rpc_response", json.dumps(resp), force_chunked=use_chunk)
                client.set_value("rpc_response_req_id", str(last_req_id))

            elif method == "get_turn_overview":
                resp_data = {
                    "turn_number": 45,
                    "active_player_id": 0,
                    "player_civ": "中国",
                    "yields": {"gold": 240, "gold_per_turn": 14, "science_per_turn": 38, "happiness": 6},
                    "our_units": [unit_state],
                    "visible_enemies": [],
                    "our_cities": [{"city_id": 1, "name": "北京", "x": 11, "y": 15, "pop": 7, "hp": 100}],
                }
                resp = {"req_id": last_req_id, "ok": True, "data": resp_data, "error": None}
                client.write_payload("rpc_response", json.dumps(resp))
                client.set_value("rpc_response_req_id", str(last_req_id))

            elif method == "get_unit_context":
                resp_data = {
                    "unit": unit_state,
                    "surrounding_tiles": [
                        {"x": 14, "y": 18, "distance": 0, "visibility": "VISIBLE", "terrain": "TERRAIN_PLAINS", "is_hills": False, "has_river": False},
                        {"x": 15, "y": 18, "distance": 1, "visibility": "VISIBLE", "terrain": "TERRAIN_PLAINS", "is_hills": True, "has_river": True},
                        {"x": 16, "y": 18, "distance": 2, "visibility": "REVEALED_FOG", "terrain": "TERRAIN_FOREST", "is_hills": False, "has_river": False},
                    ],
                    "candidate_actions": [
                        {"action_id": "ACT_01", "action_type": "MOVE_STEP", "target_x": 15, "target_y": 18, "estimated_cost_moves": 1.0, "note": "Step move to adjacent hill"},
                        {"action_id": "ACT_02", "action_type": "FORTIFY", "target_x": 14, "target_y": 18, "estimated_cost_moves": 1.0, "note": "Fortify at current tile"},
                        {"action_id": "ACT_03", "action_type": "SKIP_TURN", "target_x": 14, "target_y": 18, "estimated_cost_moves": 0.0, "note": "Skip turn"},
                    ],
                }
                resp = {"req_id": last_req_id, "ok": True, "data": resp_data, "error": None}
                client.write_payload("rpc_response", json.dumps(resp))
                client.set_value("rpc_response_req_id", str(last_req_id))

            elif method == "execute_unit_action":
                wait_sec = float(params.get("settle_delay_sec", 0.25))
                if wait_sec > 0:
                    time.sleep(wait_sec)
                unit_state["x"] = int(params.get("target_x", unit_state["x"]))
                unit_state["y"] = int(params.get("target_y", unit_state["y"]))
                unit_state["moves_left"] = max(0.0, unit_state["moves_left"] - 1.0)
                newly_spotted = [
                    {
                        "enemy_id": "63:1024",
                        "owner_id": 63,
                        "owner_name": "蛮族",
                        "is_barbarian": True,
                        "unit_type": "UNIT_BARBARIAN_SWORDSMAN",
                        "x": 16,
                        "y": 18,
                        "hp": 100,
                        "combat_str": 14,
                        "ranged_str": 0,
                    }
                ]
                resp_data = {
                    "executed": True,
                    "action_type": params.get("action_type", "MOVE_STEP"),
                    "target_x": unit_state["x"],
                    "target_y": unit_state["y"],
                    "settle_wait_ms": int(wait_sec * 1000),
                    "unit_died": False,
                    "unit_after": unit_state,
                    "delta_observation": {
                        "newly_spotted_enemies": newly_spotted,
                        "newly_spotted_count": len(newly_spotted),
                    },
                    "sync_frame_comparison": {
                        "sync_moves_left": 2.0,
                        "sync_spotted_count": 0,
                    },
                }
                resp = {"req_id": last_req_id, "ok": True, "data": resp_data, "error": None}
                client.write_payload("rpc_response", json.dumps(resp))
                client.set_value("rpc_response_req_id", str(last_req_id))
        time.sleep(0.04)


def run_acceptance(client: Civ5SqliteBridgeClient, mode: str) -> dict[str, Any]:
    """执行 EXP-03 与 EXP-04 全套验收断言并输出结构化报告。"""
    report: dict[str, Any] = {"mode": mode, "exp03": {}, "exp04": {}, "all_passed": False}

    # 1. EXP-03.1: 50 次连续跨进程 SQLite RPC 往返与锁稳定性测试
    rtts = []
    for i in range(50):
        resp, rtt = client.rpc_call("ping", {"echo": f"msg_{i}"}, timeout_sec=5.0)
        assert resp.get("ok") is True and resp["data"]["pong"] == f"msg_{i}", f"Ping mismatch: {resp}"
        rtts.append(rtt)
    rtts_sorted = sorted(rtts)
    report["exp03"]["ping_50x"] = {
        "passed": True,
        "count": 50,
        "lock_errors": 0,
        "avg_rtt_ms": round(sum(rtts) / len(rtts), 2),
        "p50_rtt_ms": round(rtts_sorted[25], 2),
        "p95_rtt_ms": round(rtts_sorted[47], 2),
    }

    # 2. EXP-03.2: 32KB 大载荷单行直写与 3KB 自动分片双模式完整性测试
    for use_chunk in (False, True):
        test_str = "A" * 32768
        resp, rtt = client.rpc_call(
            "test_large_payload",
            {"target_bytes": 32768, "use_chunk": use_chunk, "payload": test_str},
            timeout_sec=5.0,
            force_chunked=use_chunk,
        )
        assert resp.get("ok") is True
        assert resp["data"]["received_len"] == 32768
        assert len(resp["data"]["payload_blob"]) == 32768
        key = "chunked_32kb" if use_chunk else "direct_32kb"
        report["exp03"][key] = {"passed": True, "bytes_verified": 32768, "rtt_ms": round(rtt, 2)}

    # 3. EXP-04.1: 全局可见态势提取 (get_turn_overview)
    ov_resp, ov_rtt = client.rpc_call("get_turn_overview", {}, timeout_sec=8.0)
    assert ov_resp.get("ok") is True, f"get_turn_overview failed: {ov_resp}"
    ov_data = ov_resp["data"]
    units = ov_data.get("our_units", [])
    assert len(units) >= 1, "No active player units found"
    actable_units = [u for u in units if u.get("can_act") and u.get("moves_left", 0) > 0]
    chosen_unit = actable_units[0] if actable_units else units[0]
    first_uid = chosen_unit["unit_id"]
    report["exp04"]["turn_overview"] = {
        "passed": True,
        "turn_number": ov_data.get("turn_number"),
        "player_civ": ov_data.get("player_civ"),
        "yields": ov_data.get("yields"),
        "unit_count": len(units),
        "city_count": len(ov_data.get("our_cities", [])),
        "visible_enemies_count": len(ov_data.get("visible_enemies", [])),
        "visible_enemy_cities_count": len(ov_data.get("visible_enemy_cities", [])),
        "rtt_ms": round(ov_rtt, 2),
    }

    # 4. EXP-04.2: 单位局部战场与合法候选动作枚举 (get_unit_context)
    ctx_resp, ctx_rtt = client.rpc_call(
        "get_unit_context", {"unit_id": first_uid, "radius": 2}, timeout_sec=8.0
    )
    assert ctx_resp.get("ok") is True, f"get_unit_context failed: {ctx_resp}"
    candidates = ctx_resp["data"].get("candidate_actions", [])
    assert len(candidates) >= 1, "Candidate action list should not be empty"
    report["exp04"]["unit_context_candidates"] = {
        "passed": True,
        "unit": ctx_resp["data"].get("unit"),
        "tiles_scanned": len(ctx_resp["data"].get("surrounding_tiles", [])),
        "candidate_count": len(candidates),
        "sample_candidates": candidates[:5],
        "rtt_ms": round(ctx_rtt, 2),
    }

    # 5. EXP-04.3: 单位单步动作执行、异步结算等待与增量揭盲视野对比 (execute_unit_action)
    # 优先挑选安全的 MOVE_STEP（便于触发真实移动与揭盲采样），若无则退化选择 FORTIFY / SKIP_TURN
    move_cands = [c for c in candidates if c["action_type"] == "MOVE_STEP"]
    chosen_act = move_cands[0] if move_cands else candidates[0]
    act_resp, act_rtt = client.rpc_call(
        "execute_unit_action",
        {
            "unit_id": first_uid,
            "action_type": chosen_act["action_type"],
            "target_x": chosen_act["target_x"],
            "target_y": chosen_act["target_y"],
            "settle_delay_sec": 0.35,
        },
        timeout_sec=10.0,
    )
    assert act_resp.get("ok") is True and act_resp["data"].get("executed") is True, f"execute_unit_action failed: {act_resp}"
    delta_obs = act_resp["data"].get("delta_observation", {})
    report["exp04"]["action_settlement_and_delta"] = {
        "passed": True,
        "action_executed": chosen_act["action_type"],
        "target_xy": [chosen_act["target_x"], chosen_act["target_y"]],
        "settle_wait_ms": act_resp["data"].get("settle_wait_ms"),
        "unit_after": act_resp["data"].get("unit_after"),
        "newly_revealed_tiles_count": delta_obs.get("newly_revealed_tiles_count"),
        "newly_spotted_count": delta_obs.get("newly_spotted_count"),
        "sync_frame_comparison": act_resp["data"].get("sync_frame_comparison"),
        "total_rtt_ms": round(act_rtt, 2),
    }

    report["all_passed"] = True
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["simulate", "live"], default="simulate")
    parser.add_argument("--db-path", type=str, default=str(DEFAULT_DB_PATH))
    parser.add_argument("--wait-game-sec", type=float, default=300.0)
    args = parser.parse_args()

    db_path = Path(args.db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    client = Civ5SqliteBridgeClient(db_path)

    if args.mode == "simulate":
        sim_db = Path(__file__).resolve().parent / "exp06" / "output" / "exp03_sim_temp.db"
        sim_db.parent.mkdir(parents=True, exist_ok=True)
        sim_client = Civ5SqliteBridgeClient(sim_db)
        stop_evt = mp.Event()
        proc = mp.Process(target=_simulated_civ5_lua_loop, args=(str(sim_db), stop_evt), daemon=True)
        proc.start()
        try:
            time.sleep(0.2)
            report = run_acceptance(sim_client, mode="simulate")
            print(json.dumps(report, ensure_ascii=False, indent=2))
        finally:
            stop_evt.set()
            proc.join(timeout=2.0)
    else:
        print(f"[LIVE] 正在等待《文明5》启动并进图生成原生数据库 ({db_path}, 最长等待 {args.wait_game_sec:.0f}s)...", flush=True)
        deadline = time.perf_counter() + args.wait_game_sec
        connected = False
        while time.perf_counter() < deadline:
            if not db_path.exists():
                time.sleep(2.0)
                continue
            try:
                hb_raw = client.get_value("bridge_heartbeat")
                if not hb_raw or '"SIMULATED"' in hb_raw:
                    time.sleep(2.0)
                    continue
                ping_resp, ping_rtt = client.rpc_call("ping", {"echo": "live_probe"}, timeout_sec=2.5)
                if ping_resp.get("ok") is True:
                    print(f"[LIVE] 实机握手成功! RTT={ping_rtt:.2f}ms, heartbeat={hb_raw}", flush=True)
                    connected = True
                    break
            except (TimeoutError, sqlite3.Error):
                pass
            time.sleep(2.0)
        if not connected:
            raise TimeoutError(
                f"在 {args.wait_game_sec:.0f}s 内未收到《文明5》实机响应。请确认已在 MODS 菜单勾选 'Civ5 Agent Command Bridge' 并进入单局地图玩家回合！"
            )
        report = run_acceptance(client, mode="live")
        out_report = Path(__file__).resolve().parent / "exp03_exp04_live_acceptance_report.json"
        out_report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
