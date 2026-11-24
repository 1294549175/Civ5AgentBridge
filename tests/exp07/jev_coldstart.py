# -*- coding: utf-8 -*-
"""
模块名称：jev_coldstart.py
职责说明：
    在 EXP-05 的 JevClassifierService 基础上，实现面向 Colab 轻量分类器训练的
    Jev 冷启动判别与标准化特征轨迹采集器（HybridColdStartJevService）：
    1. 严格复用《03_接口设计说明书》§5 定义的 evaluate_candidate_actions / evaluate_step_escalation / record_jev_trajectory；
    2. 为每次动作判别与中断判别提取固定列、数值化、无缺失值的特征向量字典（state_features），
       确保生成的 jev_trajectories.jsonl 可直接被 Colab Notebook（pandas / datasets / LightGBM / PyTorch）零清洗读取；
    3. 所有磁盘 JSONL 追加写入通过 asyncio.to_thread 或极短原子追加完成，绝不阻塞 Textual 60fps 事件循环；
    4. 提供 validate_trajectories_for_colab() 自动质检工具，验证所有字段完备性、标签域合规性与特征矩阵可展开性。
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Literal
import uuid

from ..exp05.jev_classifier import JevClassifierService
from ..exp05.mock_sandbox import hex_distance
from ..exp05.schemas import (
    ActionExecutionResultDTO,
    CandidateActionDTO,
    JevEscalationDecisionDTO,
    JevScoredActionDTO,
    TaskPackage,
    UnitTacticalContextDTO,
)

JEV_TRAJECTORY_SCHEMA_VERSION = "jev_traj_v1"

ACTION_FEATURE_KEYS = (
    "turn_number",
    "unit_id",
    "unit_hp_ratio",
    "unit_moves_left",
    "unit_max_moves",
    "unit_combat_str",
    "unit_ranged_str",
    "unit_range",
    "tactical_posture",
    "action_type",
    "cur_dist_to_target",
    "new_dist_to_target",
    "dist_delta",
    "target_is_hills",
    "target_has_river",
    "adj_visible_enemies",
    "estimated_cost_moves",
    "has_combat_preview",
)

ESCALATION_FEATURE_KEYS = (
    "turn_number",
    "unit_id",
    "tactical_posture",
    "action_executed",
    "unit_died",
    "unit_hp_after_ratio",
    "unit_moves_left_after",
    "newly_revealed_tiles_count",
    "newly_spotted_count",
    "newly_spotted_regular_count",
    "abort_on_new_enemy_count",
    "target_enemy_survived_hp",
    "target_enemy_killed",
    "redline_count",
)


def extract_action_features(
    turn_number: int,
    unit_context: UnitTacticalContextDTO,
    task_package: TaskPackage,
    cand: CandidateActionDTO,
) -> dict[str, Any]:
    """
    从单位局部战场上下文与单个候选动作提取固定列特征字典（供 Colab 表格/文本混合模型直接训练）。
    原因：将嵌套的地图 DTO 压平为定长数值+枚举特征，避免训练脚本重复解析异构 JSON。
    """
    unit = unit_context.unit
    tx = task_package.target_area.target_x
    ty = task_package.target_area.target_y
    cur_dist = hex_distance(unit.x, unit.y, tx, ty)
    new_dist = hex_distance(cand.target_x, cand.target_y, tx, ty)

    tile_map = {(t.x, t.y): t for t in unit_context.surrounding_tiles}
    target_tile = tile_map.get((cand.target_x, cand.target_y))
    visible_enemies = [
        t.enemy_unit for t in unit_context.surrounding_tiles if t.enemy_unit is not None
    ]
    adj_enemies = sum(
        1
        for e in visible_enemies
        if hex_distance(cand.target_x, cand.target_y, e.x, e.y) <= 1
    )

    return {
        "turn_number": int(turn_number),
        "unit_id": int(unit.unit_id),
        "unit_hp_ratio": round(unit.hp / max(1, unit.max_hp), 4),
        "unit_moves_left": float(unit.moves_left),
        "unit_max_moves": float(unit.max_moves),
        "unit_combat_str": int(unit.combat_str),
        "unit_ranged_str": int(unit.ranged_str),
        "unit_range": int(unit.range),
        "tactical_posture": str(task_package.tactical_posture),
        "action_type": str(cand.action_type),
        "cur_dist_to_target": int(cur_dist),
        "new_dist_to_target": int(new_dist),
        "dist_delta": int(new_dist - cur_dist),
        "target_is_hills": int(bool(target_tile and target_tile.is_hills)),
        "target_has_river": int(bool(target_tile and target_tile.has_river)),
        "adj_visible_enemies": int(adj_enemies),
        "estimated_cost_moves": float(cand.estimated_cost_moves),
        "has_combat_preview": int(cand.combat_preview is not None),
    }


def extract_escalation_features(
    turn_number: int,
    before_context: UnitTacticalContextDTO,
    exec_result: ActionExecutionResultDTO,
    task_package: TaskPackage,
    redlines: list[str],
) -> dict[str, Any]:
    """
    从动作执行结算与增量视野（DeltaObservationDTO）提取中断分级特征向量。
    原因：用于训练 Jev 三分类中断判别器（0=继续 / 1=参谋长微调 / 2=顾问请示玩家）。
    """
    delta = exec_result.delta_observation
    spotted = delta.newly_spotted_enemies
    regular_cnt = sum(1 for e in spotted if not e.is_barbarian)
    unit_after = exec_result.unit_after
    target_after = delta.target_enemy_after

    hp_after_ratio = (
        round(unit_after.hp / max(1, unit_after.max_hp), 4)
        if unit_after is not None
        else 0.0
    )
    moves_after = float(unit_after.moves_left) if unit_after is not None else 0.0
    target_survived_hp = (
        int(target_after.hp)
        if (target_after is not None and not target_after.enemy_killed)
        else 0
    )
    target_killed = int(bool(target_after is not None and target_after.enemy_killed))

    return {
        "turn_number": int(turn_number),
        "unit_id": int(before_context.unit.unit_id),
        "tactical_posture": str(task_package.tactical_posture),
        "action_executed": int(bool(exec_result.executed)),
        "unit_died": int(bool(exec_result.unit_died)),
        "unit_hp_after_ratio": hp_after_ratio,
        "unit_moves_left_after": moves_after,
        "newly_revealed_tiles_count": int(delta.newly_revealed_tiles_count),
        "newly_spotted_count": int(len(spotted)),
        "newly_spotted_regular_count": int(regular_cnt),
        "abort_on_new_enemy_count": int(task_package.abort_on_new_enemy_count),
        "target_enemy_survived_hp": target_survived_hp,
        "target_enemy_killed": target_killed,
        "redline_count": int(len(redlines)),
    }


class HybridColdStartJevService(JevClassifierService):
    """
    EXP-07 强化版 Jev 冷启动分类与非阻塞轨迹采集服务。
    与 EXP-05 保持完全接口兼容，新增：
    - 规范化定长特征落盘（jev_traj_v1）；
    - 异步文件追加（asyncio.to_thread），保证高频落盘不产生任何 TUI 事件循环卡顿；
    - 统计实时采集条数，供 TUI 右栏监控面板实时展示。
    """

    def __init__(
        self,
        trajectory_path: Path,
        backend_mode: str = "hybrid-rule-flash-coldstart",
    ) -> None:
        super().__init__(trajectory_path=trajectory_path)
        self.backend_mode = backend_mode
        self.recorded_count: int = 0
        self._write_lock = asyncio.Lock()

    def record_jev_trajectory(
        self,
        sample_type: Literal["ACTION_CLASSIFICATION", "ESCALATION_CLASSIFICATION"],
        state_features: dict[str, Any],
        jev_prediction: dict[str, Any],
        final_adopted_label: str | int,
        was_overridden_by_human_or_superior: bool,
        meta: dict[str, Any] | None = None,
    ) -> str:
        """同步落盘单条标准 jev_traj_v1 样本（对齐 §5.3）。"""
        record_id = f"JEV_TRJ_{uuid.uuid4().hex[:10]}"
        entry: dict[str, Any] = {
            "schema_version": JEV_TRAJECTORY_SCHEMA_VERSION,
            "record_id": record_id,
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "backend_mode": self.backend_mode,
            "sample_type": sample_type,
            "state_features": state_features,
            "jev_prediction": jev_prediction,
            "final_adopted_label": final_adopted_label,
            "was_overridden_by_human_or_superior": bool(was_overridden_by_human_or_superior),
        }
        if meta:
            entry["meta"] = meta
        with self.trajectory_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.recorded_count += 1
        return record_id

    async def record_jev_trajectory_async(
        self,
        sample_type: Literal["ACTION_CLASSIFICATION", "ESCALATION_CLASSIFICATION"],
        state_features: dict[str, Any],
        jev_prediction: dict[str, Any],
        final_adopted_label: str | int,
        was_overridden_by_human_or_superior: bool,
        meta: dict[str, Any] | None = None,
    ) -> str:
        """非阻塞异步落盘封装：将磁盘 I/O 卸载至线程池并加锁保证 JSONL 行级原子性。"""
        async with self._write_lock:
            return await asyncio.to_thread(
                self.record_jev_trajectory,
                sample_type,
                state_features,
                jev_prediction,
                final_adopted_label,
                was_overridden_by_human_or_superior,
                meta,
            )


def validate_trajectories_for_colab(jsonl_path: Path) -> dict[str, Any]:
    """
    模拟 Colab Notebook 数据载入流程，对 jev_trajectories.jsonl 执行完整质检：
    1. 逐行 JSON 解析零错误；
    2. 校验必需顶层字段、合法标签域与定长特征键集合（ACTION 与 ESCALATION 分别展开为特征矩阵）；
    3. 核验是否同时覆盖自动采纳样本与人工/上级修正样本（用于监督微调纠偏）。
    """
    assert jsonl_path.exists(), f"轨迹文件不存在: {jsonl_path}"
    lines = [
        ln.strip()
        for ln in jsonl_path.read_text(encoding="utf-8").splitlines()
        if ln.strip()
    ]
    assert len(lines) >= 6, f"轨迹样本数不足: {len(lines)}"

    required_top_keys = {
        "schema_version",
        "record_id",
        "timestamp_utc",
        "backend_mode",
        "sample_type",
        "state_features",
        "jev_prediction",
        "final_adopted_label",
        "was_overridden_by_human_or_superior",
    }
    valid_action_labels = {"OPTIMAL", "ACCEPTABLE", "HIGH_RISK", "VIOLATES_ORDER"}
    valid_escalation_labels = {0, 1, 2}

    action_rows: list[dict[str, Any]] = []
    escalation_rows: list[dict[str, Any]] = []
    override_count = 0
    escalation_level_counts = {0: 0, 1: 0, 2: 0}

    for idx, line in enumerate(lines, start=1):
        obj = json.loads(line)
        missing_top = required_top_keys - set(obj.keys())
        assert not missing_top, f"第 {idx} 行缺少顶层字段: {missing_top}"
        assert obj["schema_version"] == JEV_TRAJECTORY_SCHEMA_VERSION

        features = obj["state_features"]
        assert isinstance(features, dict) and len(features) > 0
        if obj["was_overridden_by_human_or_superior"]:
            override_count += 1

        stype = obj["sample_type"]
        if stype == "ACTION_CLASSIFICATION":
            missing_f = set(ACTION_FEATURE_KEYS) - set(features.keys())
            assert not missing_f, f"第 {idx} 行 ACTION 缺少特征列: {missing_f}"
            assert obj["final_adopted_label"] in valid_action_labels, (
                f"第 {idx} 行非法 ACTION 标签: {obj['final_adopted_label']}"
            )
            for k in ACTION_FEATURE_KEYS:
                assert features[k] is not None, f"第 {idx} 行特征 {k} 为 None"
            action_rows.append(features)
        elif stype == "ESCALATION_CLASSIFICATION":
            missing_f = set(ESCALATION_FEATURE_KEYS) - set(features.keys())
            assert not missing_f, f"第 {idx} 行 ESCALATION 缺少特征列: {missing_f}"
            lbl = obj["final_adopted_label"]
            assert lbl in valid_escalation_labels, f"第 {idx} 行非法 ESCALATION 标签: {lbl}"
            escalation_level_counts[int(lbl)] += 1
            for k in ESCALATION_FEATURE_KEYS:
                assert features[k] is not None, f"第 {idx} 行特征 {k} 为 None"
            escalation_rows.append(features)
        else:
            raise AssertionError(f"第 {idx} 行未知 sample_type: {stype}")

    assert len(action_rows) >= 3, "ACTION_CLASSIFICATION 样本数不足"
    assert len(escalation_rows) >= 3, "ESCALATION_CLASSIFICATION 样本数不足"
    assert override_count >= 1, "缺少人工/上级决断修正样本 (was_overridden_by_human_or_superior=True)"

    return {
        "colab_ready": True,
        "schema_version": JEV_TRAJECTORY_SCHEMA_VERSION,
        "total_records": len(lines),
        "action_samples": len(action_rows),
        "action_feature_columns": len(ACTION_FEATURE_KEYS),
        "escalation_samples": len(escalation_rows),
        "escalation_feature_columns": len(ESCALATION_FEATURE_KEYS),
        "escalation_label_distribution": escalation_level_counts,
        "human_or_superior_override_samples": override_count,
    }
