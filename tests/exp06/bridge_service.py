# -*- coding: utf-8 -*-
"""
模块名称：bridge_service.py
职责说明：
    提供 Civ5 MCP Server 的双模式运行时管理器（Civ5BridgeRuntime）：
    1. 统一支持 MOCK（离线沙盘快照）与 LIVE（实机 ModUserData SQLite IPC）两种模式，
       并可通过环境变量或 CLI 参数一键切换，也支持运行期通过 load_turn_snapshot 热切入 MOCK 模式；
    2. 严格按照《03_接口设计说明书》§2 对所有返回值执行 Pydantic v2 强契约规范化
       （补齐 Lua 端可选缺省字段，确保上游编排器与 agy CLI 拿到完全一致的 DTO）；
    3. 负责 save_turn_snapshot / load_turn_snapshot 的录制与回载，兼容 EXP-05 完整沙盘快照与 LIVE 录制快照。
"""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import re
from typing import Any, Literal

from ..exp05.mock_sandbox import OfflineCiv5Sandbox
from ..exp05.schemas import (
    ActionExecutionResultDTO,
    CitySummaryDTO,
    DeltaObservationDTO,
    EnemyUnitDTO,
    HandoffDocument,
    TurnOverviewDTO,
    UnitSummaryDTO,
    UnitTacticalContextDTO,
)
from .sqlite_bridge import AsyncSqliteBridgeClient, DEFAULT_LIVE_DB_PATH

EXP05_DEFAULT_SNAPSHOT = (
    Path(__file__).resolve().parent.parent
    / "exp05"
    / "snapshots"
    / "turn45_ambush_snapshot.json"
)
DEFAULT_SNAPSHOTS_DIR = Path(__file__).resolve().parent / "output" / "snapshots"


def _normalize_live_turn_overview(raw: dict[str, Any]) -> TurnOverviewDTO:
    """
    将游戏端 Civ5AgentBridgeCore.lua 返回的原始全局态势补齐为标准 TurnOverviewDTO。
    原因：Lua 端为了精简首版实现省略了 strategic_resources / is_fortified / current_production 等字段，
    由 MCP Server 适配层统一补齐默认值，保证 MOCK 与 LIVE 两种模式契约完全一致。
    """
    yields = dict(raw.get("yields") or {})
    yields.setdefault("gold", 0)
    yields.setdefault("gold_per_turn", 0)
    yields.setdefault("science_per_turn", 0)
    yields.setdefault("happiness", 0)
    yields.setdefault("strategic_resources", {})

    our_units = []
    for u in raw.get("our_units") or []:
        item = dict(u)
        item.setdefault("is_fortified", False)
        item.setdefault("max_hp", 100)
        our_units.append(UnitSummaryDTO.model_validate(item))

    visible_enemies = []
    for e in raw.get("visible_enemies") or []:
        item = dict(e)
        item.setdefault("enemy_killed", False)
        visible_enemies.append(EnemyUnitDTO.model_validate(item))

    our_cities = []
    for c in raw.get("our_cities") or []:
        item = dict(c)
        item.setdefault("current_production", "UNKNOWN")
        item.setdefault("turns_left", 0)
        our_cities.append(CitySummaryDTO.model_validate(item))

    return TurnOverviewDTO(
        turn_number=int(raw.get("turn_number", 0)),
        player_civ=str(raw.get("player_civ", "Unknown")),
        yields=yields,
        our_units=our_units,
        visible_enemies=visible_enemies,
        our_cities=our_cities,
        visible_enemy_cities=raw.get("visible_enemy_cities") or [],
    )


def _normalize_live_unit_context(raw: dict[str, Any]) -> UnitTacticalContextDTO:
    """将 Lua 端 get_unit_context 原始字典规范化为标准 UnitTacticalContextDTO。"""
    unit_raw = dict(raw.get("unit") or {})
    unit_raw.setdefault("is_fortified", False)
    unit_raw.setdefault("max_hp", 100)

    tiles = []
    for t in raw.get("surrounding_tiles") or []:
        t_item = dict(t)
        t_item.setdefault("feature", None)
        t_item.setdefault("improvement", None)
        t_item.setdefault("city", None)
        if isinstance(t_item.get("enemy_unit"), dict):
            e_item = dict(t_item["enemy_unit"])
            e_item.setdefault("enemy_killed", False)
            t_item["enemy_unit"] = e_item
        tiles.append(t_item)

    candidates = []
    for act in raw.get("candidate_actions") or []:
        a_item = dict(act)
        a_item.setdefault("combat_preview", None)
        a_item.setdefault("note", "")
        candidates.append(a_item)

    return UnitTacticalContextDTO.model_validate(
        {
            "unit": unit_raw,
            "surrounding_tiles": tiles,
            "candidate_actions": candidates,
        }
    )


def _normalize_live_action_result(raw: dict[str, Any]) -> ActionExecutionResultDTO:
    """将 Lua 端 execute_unit_action 结算返回规范化为标准 ActionExecutionResultDTO。"""
    unit_after_raw = raw.get("unit_after")
    if isinstance(unit_after_raw, dict):
        unit_after_raw = dict(unit_after_raw)
        unit_after_raw.setdefault("is_fortified", False)
        unit_after_raw.setdefault("max_hp", 100)

    delta_raw = dict(raw.get("delta_observation") or {})
    spotted = []
    for e in delta_raw.get("newly_spotted_enemies") or []:
        e_item = dict(e)
        e_item.setdefault("enemy_killed", False)
        spotted.append(e_item)

    delta_dto = DeltaObservationDTO.model_validate(
        {
            "newly_revealed_tiles_count": int(
                delta_raw.get("newly_revealed_tiles_count", len(spotted))
            ),
            "newly_spotted_enemies": spotted,
            "target_enemy_after": delta_raw.get("target_enemy_after"),
        }
    )

    return ActionExecutionResultDTO.model_validate(
        {
            "executed": bool(raw.get("executed", False)),
            "error_reason": raw.get("error_reason"),
            "unit_died": bool(raw.get("unit_died", False)),
            "unit_after": unit_after_raw,
            "delta_observation": delta_dto.model_dump(),
        }
    )


def _ensure_sandbox_compatible_snapshot(snapshot_path: Path) -> Path:
    """
    检查待加载快照是否具备 OfflineCiv5Sandbox 所需的 prev_handoff / map_tiles 等扩展字段；
    若遇到仅含 initial_overview 的精简录制快照，则生成标准兼容结构供沙盘安全加载。
    """
    raw = json.loads(snapshot_path.read_text(encoding="utf-8"))
    if "prev_handoff" in raw and "initial_overview" in raw:
        return snapshot_path

    # 兼容直接保存 TurnOverviewDTO 的精简文件
    overview = raw.get("initial_overview", raw)
    turn_num = int(overview.get("turn_number", 1))
    hydrated = {
        "scenario_id": raw.get("scenario_id", f"RECORDED_TURN_{turn_num}"),
        "description": raw.get("description", "由 Civ5 MCP Server 录制的离线回合快照"),
        "sight_radius": int(raw.get("sight_radius", 2)),
        "prev_handoff": HandoffDocument(
            from_turn=max(0, turn_num - 1),
            long_term_strategy="由实机录制快照自动生成的默认交接占位。",
            active_operations=[],
            unresolved_threats=[],
            last_turn_execution_summary="自动录制快照。",
        ).model_dump(),
        "initial_overview": overview,
        "map_tiles": raw.get("map_tiles", []),
        "hidden_fog_enemies": raw.get("hidden_fog_enemies", []),
    }
    temp_path = snapshot_path.with_suffix(".hydrated.json")
    temp_path.write_text(
        json.dumps(hydrated, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return temp_path


class Civ5BridgeRuntime:
    """
    Civ5 MCP Server 核心运行时状态容器。
    负责在 MOCK（离线沙盘）与 LIVE（实机 SQLite RPC）之间路由所有 5 个标准 MCP Tool。
    """

    def __init__(
        self,
        mode: Literal["MOCK", "LIVE"] = "MOCK",
        mock_snapshot_path: Path | None = None,
        live_db_path: Path | None = None,
        snapshots_dir: Path | None = None,
        rpc_timeout_sec: float = 8.0,
    ) -> None:
        self.runtime_mode: Literal["MOCK", "LIVE"] = mode
        self.mock_snapshot_path: Path = mock_snapshot_path or EXP05_DEFAULT_SNAPSHOT
        self.live_db_path: Path = live_db_path or DEFAULT_LIVE_DB_PATH
        self.snapshots_dir: Path = snapshots_dir or DEFAULT_SNAPSHOTS_DIR
        self.snapshots_dir.mkdir(parents=True, exist_ok=True)
        self.rpc_timeout_sec = rpc_timeout_sec

        self._sandbox: OfflineCiv5Sandbox | None = None
        self._sqlite_client: AsyncSqliteBridgeClient | None = None

        if self.runtime_mode == "MOCK":
            self._init_mock_sandbox(self.mock_snapshot_path)
        else:
            self._init_live_client(self.live_db_path)

    @classmethod
    def from_env_and_args(
        cls,
        mock_snapshot: str | None = None,
        live_db: str | None = None,
        snapshots_dir: str | None = None,
        rpc_timeout_sec: float | None = None,
    ) -> "Civ5BridgeRuntime":
        """
        依据“CLI 参数优先，环境变量兜底”规则构建双模式运行时。
        支持的环境变量：
        - CIV5_BRIDGE_MODE: "MOCK" 或 "LIVE"
        - CIV5_MOCK_SNAPSHOT: 离线快照 JSON 路径
        - CIV5_LIVE_DB: 实机 ModUserData SQLite 路径
        - CIV5_SNAPSHOTS_DIR: save_turn_snapshot 导出目录
        - CIV5_RPC_TIMEOUT: SQLite RPC 等待超时秒数
        """
        env_mode = os.environ.get("CIV5_BRIDGE_MODE", "").strip().upper()
        env_mock = os.environ.get("CIV5_MOCK_SNAPSHOT", "").strip()
        env_live = os.environ.get("CIV5_LIVE_DB", "").strip()
        env_snap_dir = os.environ.get("CIV5_SNAPSHOTS_DIR", "").strip()
        env_timeout = os.environ.get("CIV5_RPC_TIMEOUT", "").strip()

        if mock_snapshot and live_db:
            raise ValueError("不能同时指定 --mock-snapshot 与 --live-db")

        mode: Literal["MOCK", "LIVE"]
        if live_db:
            mode = "LIVE"
        elif mock_snapshot:
            mode = "MOCK"
        elif env_mode in ("MOCK", "LIVE"):
            mode = env_mode  # type: ignore[assignment]
        elif env_live and not env_mock:
            mode = "LIVE"
        else:
            mode = "MOCK"

        resolved_mock = Path(mock_snapshot or env_mock) if (mock_snapshot or env_mock) else EXP05_DEFAULT_SNAPSHOT
        resolved_live = Path(live_db or env_live) if (live_db or env_live) else DEFAULT_LIVE_DB_PATH
        resolved_snap_dir = (
            Path(snapshots_dir or env_snap_dir)
            if (snapshots_dir or env_snap_dir)
            else DEFAULT_SNAPSHOTS_DIR
        )
        resolved_timeout = (
            rpc_timeout_sec
            if rpc_timeout_sec is not None
            else (float(env_timeout) if env_timeout else 8.0)
        )

        return cls(
            mode=mode,
            mock_snapshot_path=resolved_mock,
            live_db_path=resolved_live,
            snapshots_dir=resolved_snap_dir,
            rpc_timeout_sec=resolved_timeout,
        )

    def _init_mock_sandbox(self, snapshot_path: Path) -> None:
        """初始化或重新加载离线沙盘模拟器。"""
        if not snapshot_path.exists():
            raise FileNotFoundError(f"离线快照文件不存在: {snapshot_path}")
        compat_path = _ensure_sandbox_compatible_snapshot(snapshot_path)
        self._sandbox = OfflineCiv5Sandbox(compat_path)
        self.mock_snapshot_path = snapshot_path
        self.runtime_mode = "MOCK"

    def _init_live_client(self, db_path: Path) -> None:
        """初始化实机 SQLite RPC 客户端。"""
        self._sqlite_client = AsyncSqliteBridgeClient(
            db_path=db_path, default_timeout_sec=self.rpc_timeout_sec
        )
        self.live_db_path = db_path
        self.runtime_mode = "LIVE"

    async def get_turn_overview(self) -> dict[str, Any]:
        """Tool 1：获取当前回合全局可见态势（TurnOverviewDTO）。"""
        if self.runtime_mode == "MOCK":
            assert self._sandbox is not None
            dto = await self._sandbox.get_turn_overview()
            return dto.model_dump()

        assert self._sqlite_client is not None
        raw = await self._sqlite_client.send_ipc_request("get_turn_overview", {})
        return _normalize_live_turn_overview(raw).model_dump()

    async def get_unit_context_and_candidates(
        self, unit_id: int, radius: int = 3
    ) -> dict[str, Any]:
        """Tool 2：获取指定单位周边局部网格与合法候选动作（UnitTacticalContextDTO）。"""
        if self.runtime_mode == "MOCK":
            assert self._sandbox is not None
            dto = await self._sandbox.get_unit_context_and_candidates(
                unit_id=unit_id, radius=radius
            )
            return dto.model_dump()

        assert self._sqlite_client is not None
        raw = await self._sqlite_client.send_ipc_request(
            "get_unit_context", {"unit_id": unit_id, "radius": radius}
        )
        return _normalize_live_unit_context(raw).model_dump()

    async def execute_unit_step(
        self, unit_id: int, action_type: str, target_x: int, target_y: int
    ) -> dict[str, Any]:
        """Tool 3：驱动单位执行单步动作并返回结算与增量揭盲视野（ActionExecutionResultDTO）。"""
        if self.runtime_mode == "MOCK":
            assert self._sandbox is not None
            dto = await self._sandbox.execute_unit_step(
                unit_id=unit_id,
                action_type=action_type,
                target_x=target_x,
                target_y=target_y,
            )
            return dto.model_dump()

        assert self._sqlite_client is not None
        raw = await self._sqlite_client.send_ipc_request(
            "execute_unit_action",
            {
                "unit_id": unit_id,
                "action_type": action_type,
                "target_x": target_x,
                "target_y": target_y,
                "settle_delay_sec": 0.25,
            },
        )
        return _normalize_live_action_result(raw).model_dump()

    async def save_turn_snapshot(self, tag: str) -> str:
        """
        Tool 4：将当前回合完整状态导出为本地 JSON 快照文件，返回绝对路径字符串。
        原因：支持从 LIVE 实机录制现场，或在 MOCK 演练中途存档断点，且产出文件可直接被 load_turn_snapshot 回载。
        """
        safe_tag = re.sub(r"[^A-Za-z0-9_\-]+", "_", tag.strip()) or "snapshot"
        overview = await self.get_turn_overview()
        turn_num = int(overview.get("turn_number", 0))
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = self.snapshots_dir / f"turn{turn_num}_{safe_tag}_{ts}.json"

        if self.runtime_mode == "MOCK" and self._sandbox is not None:
            # 完整持久化沙盘状态（包含地图地块、探索记忆与迷雾真值敌军），实现无损断点回载
            visible_ids = {e["enemy_id"] for e in overview.get("visible_enemies", [])}
            hidden_enemies = [
                e.model_dump()
                for eid, e in self._sandbox._all_truth_enemies.items()
                if e.hp > 0 and not e.enemy_killed and eid not in visible_ids
            ]
            map_tiles_dump = []
            for coord, meta in sorted(self._sandbox._map_tiles.items()):
                item = dict(meta)
                item["initially_revealed"] = coord in self._sandbox._revealed_coords
                map_tiles_dump.append(item)

            payload: dict[str, Any] = {
                "scenario_id": f"SAVED_{safe_tag}_T{turn_num}",
                "description": f"从 MOCK 模式导出的回合快照 (tag={tag})",
                "recorded_from_mode": "MOCK",
                "sight_radius": self._sandbox.sight_radius,
                "prev_handoff": (
                    self._sandbox.prev_handoff.model_dump()
                    if self._sandbox.prev_handoff
                    else HandoffDocument(
                        from_turn=max(0, turn_num - 1),
                        long_term_strategy="",
                        active_operations=[],
                        unresolved_threats=[],
                        last_turn_execution_summary="",
                    ).model_dump()
                ),
                "initial_overview": overview,
                "map_tiles": map_tiles_dump,
                "hidden_fog_enemies": hidden_enemies,
            }
        else:
            # LIVE 模式录制：额外抓取每个存活单位周边地块作为初始 map_tiles，使录制快照离线也可直接演练
            tiles_by_coord: dict[tuple[int, int], dict[str, Any]] = {}
            for u in overview.get("our_units", []):
                try:
                    ctx = await self.get_unit_context_and_candidates(
                        unit_id=int(u["unit_id"]), radius=2
                    )
                    for t in ctx.get("surrounding_tiles", []):
                        coord = (int(t["x"]), int(t["y"]))
                        tiles_by_coord[coord] = {
                            "x": coord[0],
                            "y": coord[1],
                            "terrain": t.get("terrain", "TERRAIN_PLAINS"),
                            "feature": t.get("feature"),
                            "is_hills": bool(t.get("is_hills", False)),
                            "has_river": bool(t.get("has_river", False)),
                            "initially_revealed": True,
                        }
                except Exception:
                    continue

            payload = {
                "scenario_id": f"LIVE_SNAPSHOT_{safe_tag}_T{turn_num}",
                "description": f"从 LIVE 游戏 SQLite 录制的回合快照 (tag={tag})",
                "recorded_from_mode": "LIVE",
                "sight_radius": 2,
                "prev_handoff": HandoffDocument(
                    from_turn=max(0, turn_num - 1),
                    long_term_strategy="实机录制回合，等待顾问拟定战略。",
                    active_operations=[],
                    unresolved_threats=[],
                    last_turn_execution_summary=f"于第 {turn_num} 回合录制自 LIVE 进程。",
                ).model_dump(),
                "initial_overview": overview,
                "map_tiles": list(tiles_by_coord.values()),
                "hidden_fog_enemies": [],
            }

        out_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return str(out_path.resolve())

    async def load_turn_snapshot(self, snapshot_path: str) -> dict[str, Any]:
        """
        Tool 5：切换 MCP Server 进入离线 MOCK 模式并加载指定 JSON 回合快照，
        返回加载元信息与最新全局态势（TurnOverviewDTO）。
        """
        target_path = Path(snapshot_path)
        if not target_path.is_absolute():
            candidate = self.snapshots_dir / target_path
            if candidate.exists():
                target_path = candidate
        self._init_mock_sandbox(target_path)
        overview = await self.get_turn_overview()
        return {
            "loaded": True,
            "runtime_mode": self.runtime_mode,
            "snapshot_path": str(target_path.resolve()),
            "overview": overview,
        }
