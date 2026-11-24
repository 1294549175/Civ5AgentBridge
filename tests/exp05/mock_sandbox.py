# -*- coding: utf-8 -*-
"""
模块名称：mock_sandbox.py
职责说明：
    提供脱离《文明5》游戏进程的离线六边形战场沙盘模拟器，严格复刻 Civ5AgentBridgeCore.lua 的数据契约与引擎规则：
    1. 采用《文明5》标准 odd-r offset 六边形网格距离公式计算视野、移动与射程；
    2. 严格遵守战争迷雾合规边界：潜伏在迷雾区的敌军（hidden_fog_enemies）在进入己方单位实时视野（IsVisible）前绝对不对外暴露；
    3. 遵循 1UPT（一格一兵）规则、远程射击耗尽移动力规则、近战击杀进占目标格规则，并精确计算单步动作后的增量揭盲视野（DeltaObservationDTO）。
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from .schemas import (
    ActionExecutionResultDTO,
    CandidateActionDTO,
    CitySummaryDTO,
    DeltaObservationDTO,
    EnemyCityDTO,
    EnemyUnitDTO,
    HandoffDocument,
    TileDTO,
    TurnOverviewDTO,
    UnitSummaryDTO,
    UnitTacticalContextDTO,
)


def hex_distance(x1: int, y1: int, x2: int, y2: int) -> int:
    """
    计算《文明5》标准 odd-r 水平偏移六边形网格上两点 (x1, y1) 与 (x2, y2) 的精确格数距离。
    原因：保证离线快照中的相邻单步移动、远程射程与 2 格视野半径与游戏内 Map.PlotDistance 完全一致。
    """
    cx1 = x1 - (y1 - (y1 & 1)) // 2
    cz1 = y1
    cy1 = -cx1 - cz1

    cx2 = x2 - (y2 - (y2 & 1)) // 2
    cz2 = y2
    cy2 = -cx2 - cz2

    return max(abs(cx1 - cx2), abs(cy1 - cy2), abs(cz1 - cz2))


class OfflineCiv5Sandbox:
    """
    离线《文明5》回合战术沙盘环境，向上层编排器暴露与未来 MCP Server 完全同构的异步查询与执行接口。
    """

    def __init__(self, snapshot_path: Path) -> None:
        self.snapshot_path = snapshot_path
        self.turn_number: int = 45
        self.player_civ: str = "中国"
        self.sight_radius: int = 2
        self.yields: dict[str, Any] = {}
        self.prev_handoff: HandoffDocument | None = None

        # 己方存活单位字典 (unit_id -> UnitSummaryDTO)
        self._our_units: dict[int, UnitSummaryDTO] = {}
        # 全图真实敌军池（含初始可见与迷雾潜伏，对外输出时必须经实时视野过滤）
        self._all_truth_enemies: dict[str, EnemyUnitDTO] = {}
        self._our_cities: list[CitySummaryDTO] = []
        self._enemy_cities: list[EnemyCityDTO] = []

        # 地块真值字典 ((x, y) -> raw_tile_dict) 与已探索记忆坐标集
        self._map_tiles: dict[tuple[int, int], dict[str, Any]] = {}
        self._revealed_coords: set[tuple[int, int]] = set()

        self._load_from_disk()

    def _load_from_disk(self) -> None:
        """从离线快照 JSON 初始化己方部队、地块属性、已探索记忆与迷雾潜伏敌军真值表。"""
        raw = json.loads(self.snapshot_path.read_text(encoding="utf-8"))
        self.sight_radius = int(raw.get("sight_radius", 2))
        self.prev_handoff = HandoffDocument.model_validate(raw["prev_handoff"])

        init_ov = raw["initial_overview"]
        self.turn_number = int(init_ov["turn_number"])
        self.player_civ = str(init_ov["player_civ"])
        self.yields = copy.deepcopy(init_ov["yields"])

        self._our_units = {
            u["unit_id"]: UnitSummaryDTO.model_validate(u) for u in init_ov.get("our_units", [])
        }
        self._our_cities = [
            CitySummaryDTO.model_validate(c) for c in init_ov.get("our_cities", [])
        ]
        self._enemy_cities = [
            EnemyCityDTO.model_validate(c) for c in init_ov.get("visible_enemy_cities", [])
        ]

        # 合并初始可见敌军与迷雾潜伏敌军至底层真值池，统一由实时视野过滤控制可见性
        self._all_truth_enemies = {}
        for e in init_ov.get("visible_enemies", []):
            dto = EnemyUnitDTO.model_validate(e)
            self._all_truth_enemies[dto.enemy_id] = dto
        for e in raw.get("hidden_fog_enemies", []):
            dto = EnemyUnitDTO.model_validate(e)
            self._all_truth_enemies[dto.enemy_id] = dto

        self._map_tiles = {}
        self._revealed_coords = set()
        for t in raw.get("map_tiles", []):
            coord = (int(t["x"]), int(t["y"]))
            self._map_tiles[coord] = copy.deepcopy(t)
            if t.get("initially_revealed", False):
                self._revealed_coords.add(coord)

        # 用初始己方单位与城市位置刷新一次视野与探索记忆
        self._refresh_visibility()

    def _compute_visible_coords(self) -> set[tuple[int, int]]:
        """
        计算当前时刻对玩家团队实时可见（IsVisible == True）的全部坐标集合。
        原因：所有敌军暴露判定与迷雾揭盲统计均以该集合作为唯一权威口径，杜绝迷雾作弊。
        """
        visible: set[tuple[int, int]] = set()
        # 收集全图已知坐标（含显式配置地块及单位/敌军所在坐标）
        candidate_coords = set(self._map_tiles.keys())
        for u in self._our_units.values():
            candidate_coords.add((u.x, u.y))
        for e in self._all_truth_enemies.values():
            candidate_coords.add((e.x, e.y))

        for ux, uy in [(u.x, u.y) for u in self._our_units.values() if u.hp > 0]:
            for cx, cy in candidate_coords:
                if hex_distance(ux, uy, cx, cy) <= self.sight_radius:
                    visible.add((cx, cy))

        for city in self._our_cities:
            for cx, cy in candidate_coords:
                if hex_distance(city.x, city.y, cx, cy) <= self.sight_radius + 1:
                    visible.add((cx, cy))

        return visible

    def _refresh_visibility(self) -> tuple[set[tuple[int, int]], int]:
        """刷新实时可见集并将新看见的地块永久并入已探索集合，返回 (当前可见集, 新揭开地块数)。"""
        visible_now = self._compute_visible_coords()
        before_revealed_cnt = len(self._revealed_coords)
        self._revealed_coords.update(visible_now)
        newly_revealed = len(self._revealed_coords) - before_revealed_cnt
        return visible_now, newly_revealed

    def _get_currently_visible_enemies(self) -> dict[str, EnemyUnitDTO]:
        """仅返回当前存活且所处格子处于实时可见集内的敌方单位字典。"""
        visible_coords = self._compute_visible_coords()
        result: dict[str, EnemyUnitDTO] = {}
        for eid, enemy in self._all_truth_enemies.items():
            if enemy.hp > 0 and not enemy.enemy_killed and (enemy.x, enemy.y) in visible_coords:
                result[eid] = enemy.model_copy(deep=True)
        return result

    def _ensure_tile_meta(self, x: int, y: int) -> dict[str, Any]:
        """获取指定坐标的地块静态属性；若快照未显式列出则返回默认平原属性。"""
        return self._map_tiles.get(
            (x, y),
            {
                "x": x,
                "y": y,
                "terrain": "TERRAIN_PLAINS",
                "feature": None,
                "is_hills": False,
                "has_river": False,
            },
        )

    async def get_turn_overview(self) -> TurnOverviewDTO:
        """导出符合战争迷雾规则的当前全局可见态势（对齐 MCP Tool: get_turn_overview）。"""
        visible_enemies = list(self._get_currently_visible_enemies().values())
        our_units = [u.model_copy(deep=True) for u in self._our_units.values() if u.hp > 0]
        return TurnOverviewDTO(
            turn_number=self.turn_number,
            player_civ=self.player_civ,
            yields=copy.deepcopy(self.yields),
            our_units=our_units,
            visible_enemies=visible_enemies,
            our_cities=[c.model_copy(deep=True) for c in self._our_cities],
            visible_enemy_cities=[c.model_copy(deep=True) for c in self._enemy_cities],
        )

    async def get_unit_context_and_candidates(
        self, unit_id: int, radius: int = 2
    ) -> UnitTacticalContextDTO:
        """
        提取指定单位周边半径 radius 内的已探索地块信息，并枚举所有合法的单步原子候选动作。
        原因：避免上层大模型臆造非法走位或穿模 1UPT 友军，严格对齐 Civ5AgentBridgeCore.lua 行为。
        """
        if unit_id not in self._our_units or self._our_units[unit_id].hp <= 0:
            raise ValueError(f"己方单位 {unit_id} 不存在或已阵亡")

        unit = self._our_units[unit_id].model_copy(deep=True)
        visible_coords = self._compute_visible_coords()
        visible_enemies_by_pos = {
            (e.x, e.y): e for e in self._get_currently_visible_enemies().values()
        }
        friendly_by_pos = {
            (u.x, u.y): u.unit_id for u in self._our_units.values() if u.hp > 0
        }

        tiles: list[TileDTO] = []
        candidates: list[CandidateActionDTO] = []
        act_idx = 1

        def add_candidate(
            action_type: Any,
            tx: int,
            ty: int,
            cost: float,
            note: str,
            preview: dict[str, Any] | None = None,
        ) -> None:
            nonlocal act_idx
            candidates.append(
                CandidateActionDTO(
                    action_id=f"ACT_{act_idx:02d}",
                    action_type=action_type,
                    target_x=tx,
                    target_y=ty,
                    estimated_cost_moves=cost,
                    combat_preview=preview,
                    note=note,
                )
            )
            act_idx += 1

        # 扫描周边坐标网格（仅返回已探索 _revealed_coords 中的地块）
        for px in range(unit.x - radius - 1, unit.x + radius + 2):
            for py in range(unit.y - radius - 1, unit.y + radius + 2):
                dist = hex_distance(unit.x, unit.y, px, py)
                if dist <= radius and (px, py) in self._revealed_coords:
                    is_vis = (px, py) in visible_coords
                    meta = self._ensure_tile_meta(px, py)
                    enemy_on_tile = visible_enemies_by_pos.get((px, py)) if is_vis else None
                    friendly_id = friendly_by_pos.get((px, py)) if is_vis else None

                    tiles.append(
                        TileDTO(
                            x=px,
                            y=py,
                            distance=dist,
                            visibility="VISIBLE" if is_vis else "REVEALED_FOG",
                            terrain=meta.get("terrain", "TERRAIN_PLAINS"),
                            feature=meta.get("feature"),
                            is_hills=bool(meta.get("is_hills", False)),
                            has_river=bool(meta.get("has_river", False)),
                            friendly_unit_id=friendly_id,
                            enemy_unit=enemy_on_tile,
                        )
                    )

                    # 枚举相邻 1 格移动或近战攻击（严格遵守 1UPT 不与友军重叠）
                    if dist == 1 and unit.moves_left > 0:
                        if enemy_on_tile is not None and unit.ranged_str == 0:
                            add_candidate(
                                "MELEE_ATTACK",
                                px,
                                py,
                                1.0,
                                f"近战攻击 ({px},{py}) 的 {enemy_on_tile.unit_type} (HP={enemy_on_tile.hp})",
                                preview={
                                    "target_enemy_type": enemy_on_tile.unit_type,
                                    "target_hp_before": enemy_on_tile.hp,
                                    "terrain_modifier_note": "HILL_DEFENSE" if meta.get("is_hills") else "OPEN_TERRAIN",
                                },
                            )
                        elif enemy_on_tile is None and friendly_id is None:
                            terrain_tag = "丘陵河岸" if meta.get("is_hills") else "开阔平原"
                            add_candidate(
                                "MOVE_STEP",
                                px,
                                py,
                                1.0,
                                f"单步移动至相邻{terrain_tag} ({px},{py})",
                            )

                    # 枚举射程内远程打击动作
                    if (
                        1 <= dist <= unit.range
                        and unit.moves_left > 0
                        and unit.ranged_str > 0
                        and enemy_on_tile is not None
                    ):
                        add_candidate(
                            "RANGE_ATTACK",
                            px,
                            py,
                            unit.moves_left,
                            f"远程射击 ({px},{py}) 的 {enemy_on_tile.unit_type} (HP={enemy_on_tile.hp})",
                            preview={
                                "target_enemy_type": enemy_on_tile.unit_type,
                                "target_hp_before": enemy_on_tile.hp,
                                "terrain_modifier_note": "RANGED_NO_RETALIATION",
                            },
                        )

        # 枚举原地驻扎/休整/跳过剩余移动力动作
        if unit.moves_left > 0:
            add_candidate(
                "FORTIFY",
                unit.x,
                unit.y,
                unit.moves_left,
                f"在当前地块 ({unit.x},{unit.y}) 就地驻扎防御",
            )
            if unit.hp < unit.max_hp:
                add_candidate(
                    "HEAL",
                    unit.x,
                    unit.y,
                    unit.moves_left,
                    f"在当前地块 ({unit.x},{unit.y}) 原地休整恢复生命",
                )
            add_candidate(
                "SKIP_TURN",
                unit.x,
                unit.y,
                0.0,
                f"保持当前位置 ({unit.x},{unit.y}) 结束本单位本回合行动",
            )

        return UnitTacticalContextDTO(
            unit=unit,
            surrounding_tiles=tiles,
            candidate_actions=candidates,
        )

    async def execute_unit_step(
        self, unit_id: int, action_type: str, target_x: int, target_y: int
    ) -> ActionExecutionResultDTO:
        """
        在离线沙盘中执行指定单位的单步动作，并在结算后对比动作前视野基线生成增量视野（DeltaObservationDTO）。
        原因：模拟游戏内两段式结算采样，向执行者与 Jev 精确反馈本步是否揭开迷雾撞见敌方主力或目标残血幸存。
        """
        if unit_id not in self._our_units:
            return ActionExecutionResultDTO(
                executed=False,
                error_reason=f"单位 {unit_id} 不存在",
                delta_observation=DeltaObservationDTO(),
            )

        unit = self._our_units[unit_id]
        if unit.hp <= 0 or unit.moves_left <= 0:
            return ActionExecutionResultDTO(
                executed=False,
                error_reason=f"单位 {unit_id} 无剩余移动力或已阵亡 (moves_left={unit.moves_left})",
                unit_after=unit.model_copy(deep=True),
                delta_observation=DeltaObservationDTO(),
            )

        # 1. 记录动作前可见敌军基线集合
        baseline_enemies = self._get_currently_visible_enemies()
        target_enemy_after: EnemyUnitDTO | None = None

        # 2. 按动作类型执行物理结算
        dist = hex_distance(unit.x, unit.y, target_x, target_y)

        if action_type == "MOVE_STEP":
            if dist != 1:
                return ActionExecutionResultDTO(
                    executed=False,
                    error_reason=f"MOVE_STEP 目标 ({target_x},{target_y}) 非相邻格 (dist={dist})",
                    unit_after=unit.model_copy(deep=True),
                    delta_observation=DeltaObservationDTO(),
                )
            # 1UPT 占用检查
            for other_u in self._our_units.values():
                if other_u.unit_id != unit_id and other_u.hp > 0 and (other_u.x, other_u.y) == (target_x, target_y):
                    return ActionExecutionResultDTO(
                        executed=False,
                        error_reason=f"PATH_BLOCKED_1UPT: 目标格 ({target_x},{target_y}) 已被友军 {other_u.unit_id} 占用",
                        unit_after=unit.model_copy(deep=True),
                        delta_observation=DeltaObservationDTO(),
                    )
            # 若目标格存在潜伏敌军则阻挡移动并暴露
            blocking_enemy = next(
                (
                    e
                    for e in self._all_truth_enemies.values()
                    if e.hp > 0 and (e.x, e.y) == (target_x, target_y)
                ),
                None,
            )
            if blocking_enemy is not None:
                return ActionExecutionResultDTO(
                    executed=False,
                    error_reason=f"目标格 ({target_x},{target_y}) 存在敌军阻挡",
                    unit_after=unit.model_copy(deep=True),
                    delta_observation=DeltaObservationDTO(
                        newly_spotted_enemies=[blocking_enemy.model_copy(deep=True)]
                    ),
                )

            unit.x = target_x
            unit.y = target_y
            unit.is_fortified = False
            unit.moves_left = max(0.0, round(unit.moves_left - 1.0, 2))
            unit.can_act = unit.moves_left > 0

        elif action_type == "RANGE_ATTACK":
            target_enemy = next(
                (
                    e
                    for e in self._all_truth_enemies.values()
                    if e.hp > 0 and (e.x, e.y) == (target_x, target_y)
                ),
                None,
            )
            if target_enemy is None or dist > unit.range:
                return ActionExecutionResultDTO(
                    executed=False,
                    error_reason=f"远程打击目标 ({target_x},{target_y}) 超出射程或无有效敌军",
                    unit_after=unit.model_copy(deep=True),
                    delta_observation=DeltaObservationDTO(),
                )
            # 《文明5》远程伤害近似公式：复合弓(11) 射击 蛮族弓手(4)，造成 29 点伤害（35 -> 6 HP 残血幸存）
            dmg = max(12, int(round(24 + (unit.ranged_str - target_enemy.combat_str) * 0.7)))
            target_enemy.hp = max(0, target_enemy.hp - dmg)
            if target_enemy.hp == 0:
                target_enemy.enemy_killed = True
            target_enemy_after = target_enemy.model_copy(deep=True)
            unit.is_fortified = False
            unit.moves_left = 0.0
            unit.can_act = False

        elif action_type == "MELEE_ATTACK":
            target_enemy = next(
                (
                    e
                    for e in self._all_truth_enemies.values()
                    if e.hp > 0 and (e.x, e.y) == (target_x, target_y)
                ),
                None,
            )
            if target_enemy is None or dist != 1:
                return ActionExecutionResultDTO(
                    executed=False,
                    error_reason=f"近战攻击目标 ({target_x},{target_y}) 非相邻格或无有效敌军",
                    unit_after=unit.model_copy(deep=True),
                    delta_observation=DeltaObservationDTO(),
                )
            dealt = max(20, int(round(30 + (unit.combat_str - target_enemy.combat_str) * 2.2)))
            recoil = max(3, int(round(12 - (unit.combat_str - target_enemy.combat_str) * 1.1)))
            target_enemy.hp = max(0, target_enemy.hp - dealt)
            unit.hp = max(1, unit.hp - recoil)
            if target_enemy.hp == 0:
                target_enemy.enemy_killed = True
                # 《文明5》近战消灭敌军后进占目标格
                unit.x = target_x
                unit.y = target_y
            target_enemy_after = target_enemy.model_copy(deep=True)
            unit.is_fortified = False
            unit.moves_left = 0.0
            unit.can_act = False

        elif action_type in ("FORTIFY", "HEAL", "SKIP_TURN"):
            unit.is_fortified = action_type == "FORTIFY"
            if action_type == "HEAL":
                unit.hp = min(unit.max_hp, unit.hp + 10)
            unit.moves_left = 0.0
            unit.can_act = False

        else:
            return ActionExecutionResultDTO(
                executed=False,
                error_reason=f"未知的动作类型: {action_type}",
                unit_after=unit.model_copy(deep=True),
                delta_observation=DeltaObservationDTO(),
            )

        # 3. 刷新视野记忆并对比动作前基线识别新揭开迷雾暴露的敌军
        _, newly_revealed_tiles = self._refresh_visibility()
        after_enemies = self._get_currently_visible_enemies()
        newly_spotted = [
            e_dto
            for eid, e_dto in after_enemies.items()
            if eid not in baseline_enemies
        ]

        return ActionExecutionResultDTO(
            executed=True,
            unit_died=(unit.hp <= 0),
            unit_after=unit.model_copy(deep=True),
            delta_observation=DeltaObservationDTO(
                newly_revealed_tiles_count=newly_revealed_tiles,
                newly_spotted_enemies=newly_spotted,
                target_enemy_after=target_enemy_after,
            ),
        )
