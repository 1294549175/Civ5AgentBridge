# -*- coding: utf-8 -*-
"""
模块名称：jev_classifier.py
职责说明：
    实现《02_软件总体设计说明书》模块 5 与《03_接口设计说明书》§5 定义的 Jev 判别式状态分类器及轨迹采集器：
    1. evaluate_candidate_actions：结合参谋长 TaskPackage 的战术姿态与目标区域，对合法候选动作进行四分类评级；
    2. evaluate_step_escalation：对比单步结算后的增量视野（DeltaObservationDTO），判别中断级别：
       - LEVEL 0：正常继续执行；
       - LEVEL 1：局部战术异常（如远程射击后残敌幸存需友军补刀、1UPT 路径受阻），退回参谋长微调，不打扰玩家；
       - LEVEL 2：战略级警报（如揭开迷雾发现敌方主力军团、触及《工作文书》红线），逐级上报顾问请示玩家；
    3. record_jev_trajectory：将归一化状态特征与采纳标签实时落盘至 JSONL，供后续分类器训练。
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Literal
import uuid

from .mock_sandbox import hex_distance
from .schemas import (
    ActionExecutionResultDTO,
    CandidateActionDTO,
    JevEscalationDecisionDTO,
    JevScoredActionDTO,
    TaskPackage,
    UnitTacticalContextDTO,
)

LABEL_PRIORITY = {
    "OPTIMAL": 3,
    "ACCEPTABLE": 2,
    "HIGH_RISK": 1,
    "VIOLATES_ORDER": 0,
}


class JevClassifierService:
    """
    Jev 冷启动战术特征分类与轨迹落盘服务。
    保持与未来 Colab 微调模型完全一致的输入输出签名。
    """

    def __init__(self, trajectory_path: Path) -> None:
        self.trajectory_path = trajectory_path
        self.trajectory_path.parent.mkdir(parents=True, exist_ok=True)

    async def evaluate_candidate_actions(
        self,
        unit_context: UnitTacticalContextDTO,
        task_package: TaskPackage,
    ) -> list[JevScoredActionDTO]:
        """
        对单位当前全部合法候选动作进行四分类战术评级并按优先级降序排列。
        原因：将参谋长的高层战术姿态（tactical_posture）转化为对原子动作的安全与效率约束。
        """
        unit = unit_context.unit
        tx = task_package.target_area.target_x
        ty = task_package.target_area.target_y
        cur_dist = hex_distance(unit.x, unit.y, tx, ty)
        posture = task_package.tactical_posture

        tile_map = {(t.x, t.y): t for t in unit_context.surrounding_tiles}
        visible_enemies = [
            t.enemy_unit for t in unit_context.surrounding_tiles if t.enemy_unit is not None
        ]

        scored: list[JevScoredActionDTO] = []

        for cand in unit_context.candidate_actions:
            new_dist = hex_distance(cand.target_x, cand.target_y, tx, ty)
            target_tile = tile_map.get((cand.target_x, cand.target_y))
            is_hill_def = bool(target_tile and target_tile.is_hills)

            # 计算目标格邻近敌军数量（衡量孤军冒进风险）
            adj_enemy_cnt = sum(
                1
                for e in visible_enemies
                if hex_distance(cand.target_x, cand.target_y, e.x, e.y) <= 1
            )

            label, conf, reason = self._classify_single_action(
                cand=cand,
                posture=posture,
                cur_dist=cur_dist,
                new_dist=new_dist,
                is_hill_def=is_hill_def,
                adj_enemy_cnt=adj_enemy_cnt,
                unit_ranged_str=unit.ranged_str,
            )
            scored.append(
                JevScoredActionDTO(
                    action_id=cand.action_id,
                    label=label,
                    confidence=round(conf, 3),
                    rationale_short=reason,
                )
            )

        scored.sort(
            key=lambda s: (LABEL_PRIORITY[s.label], s.confidence),
            reverse=True,
        )
        return scored

    def _classify_single_action(
        self,
        cand: CandidateActionDTO,
        posture: str,
        cur_dist: int,
        new_dist: int,
        is_hill_def: bool,
        adj_enemy_cnt: int,
        unit_ranged_str: int,
    ) -> tuple[Literal["OPTIMAL", "ACCEPTABLE", "HIGH_RISK", "VIOLATES_ORDER"], float, str]:
        """基于战术姿态与局部几何特征完成单动作四分类推理。"""
        atype = cand.action_type

        if posture == "RECON_CAUTIOUS":
            if atype == "MOVE_STEP" and new_dist < cur_dist:
                if adj_enemy_cnt >= 2:
                    return ("HIGH_RISK", 0.86, "前出格紧邻多支敌军，违背谨慎侦察原则")
                bonus = 0.05 if is_hill_def else 0.0
                return ("OPTIMAL", min(0.96, 0.89 + bonus), f"向侦察目标稳步推进 (距离 {cur_dist}->{new_dist})")
            if atype in ("MELEE_ATTACK", "RANGE_ATTACK"):
                return ("VIOLATES_ORDER", 0.91, "谨慎侦察姿态严禁主动挑起战斗")
            if atype == "MOVE_STEP":
                return ("ACCEPTABLE", 0.62, "侧翼迂回移动，未直接逼近侦察目标")
            return ("ACCEPTABLE", 0.55, "原地警戒保守待命")

        if posture == "FOCUS_FIRE":
            if atype == "RANGE_ATTACK" and new_dist == 0:
                return ("OPTIMAL", 0.97, "精准命中参谋长指定集火目标且无反伤")
            if atype == "MELEE_ATTACK" and new_dist == 0:
                return ("OPTIMAL", 0.94, "近战突击指定残血目标完成收割")
            if atype in ("RANGE_ATTACK", "MELEE_ATTACK"):
                return ("ACCEPTABLE", 0.78, "打击射程内次要敌军目标")
            if atype == "MOVE_STEP" and new_dist < cur_dist:
                if unit_ranged_str > 0 and adj_enemy_cnt >= 1:
                    return ("HIGH_RISK", 0.82, "远程脆皮单位贴近敌军近战威胁区")
                return ("OPTIMAL", 0.88, f"机动接敌进入打击阵位 (距离 {cur_dist}->{new_dist})")
            return ("VIOLATES_ORDER", 0.80, "集火姿态下放弃有效接敌或火力输出")

        if posture == "HOLD_DEFEND":
            if cur_dist == 0 and atype == "FORTIFY":
                return ("OPTIMAL", 0.95, "已抵达指定防线阵地并就地筑垒驻防")
            if atype == "MOVE_STEP" and new_dist < cur_dist:
                bonus = 0.05 if is_hill_def else 0.0
                return ("OPTIMAL", min(0.94, 0.87 + bonus), f"向指定防御阵地机动抢占地形 (距离 {cur_dist}->{new_dist})")
            if atype == "RANGE_ATTACK":
                return ("OPTIMAL", 0.91, "依托防线远程消耗来袭之敌")
            if atype == "FORTIFY":
                return ("ACCEPTABLE", 0.76, "就地驻防稳固战线")
            if atype == "MOVE_STEP" and new_dist > cur_dist:
                return ("VIOLATES_ORDER", 0.85, "偏离指定驻防阵位")
            return ("ACCEPTABLE", 0.60, "常规待命动作")

        if posture == "RETREAT_HEAL":
            if atype == "HEAL":
                return ("OPTIMAL", 0.93, "原地休整恢复受损生命值")
            if atype == "MOVE_STEP" and new_dist < cur_dist and adj_enemy_cnt == 0:
                return ("OPTIMAL", 0.92, "向安全后方集结格撤离")
            if atype in ("MELEE_ATTACK", "RANGE_ATTACK"):
                return ("VIOLATES_ORDER", 0.90, "撤退休整姿态下禁止恋战")
            return ("ACCEPTABLE", 0.65, "保守驻留")

        # 默认 ADVANCE 推进姿态
        if atype in ("RANGE_ATTACK", "MELEE_ATTACK") and new_dist == 0:
            return ("OPTIMAL", 0.93, "直接打击推进路线上的指定目标")
        if atype == "MOVE_STEP" and new_dist < cur_dist:
            return ("OPTIMAL", 0.90, f"按部署向目标区域推进 (距离 {cur_dist}->{new_dist})")
        if atype == "FORTIFY" and cur_dist == 0:
            return ("OPTIMAL", 0.89, "已抵达推进终点并转入驻扎")
        return ("ACCEPTABLE", 0.60, "辅助战术动作")

    async def evaluate_step_escalation(
        self,
        before_context: UnitTacticalContextDTO,
        exec_result: ActionExecutionResultDTO,
        task_package: TaskPackage,
        redlines: list[str],
    ) -> JevEscalationDecisionDTO:
        """
        对比单步动作前后的增量态势（DeltaObservationDTO），输出三级中断决策（0 / 1 / 2）。
        原因：这是打破僵化自上而下流水线、实现“战术微调归参谋长、战略巨变归顾问与玩家”的核心守门员。
        """
        delta = exec_result.delta_observation
        spotted = delta.newly_spotted_enemies
        regular_enemies = [e for e in spotted if not e.is_barbarian]

        # 1. LEVEL 2 战略警报判定：揭开迷雾暴露敌方主力军团（达到阈值或发现多支正规军）
        if len(spotted) >= task_package.abort_on_new_enemy_count or len(regular_enemies) >= 2:
            enemy_desc = ", ".join(f"{e.owner_name}{e.unit_type}@({e.x},{e.y})" for e in spotted)
            return JevEscalationDecisionDTO(
                escalation_level=2,
                reason_tag="FOG_AMBUSH_DETECTED",
                confidence=0.98,
                rationale_short=(
                    f"单步揭盲瞬间发现 {len(spotted)} 支敌军主力 [{enemy_desc}]，"
                    f"触及任务阈值({task_package.abort_on_new_enemy_count})与战略红线({len(redlines)}条)，必须立即中断并逐级上报顾问请示玩家！"
                ),
            )

        # 2. LEVEL 1 战术微调判定 A：指令因 1UPT 阻塞或非法目标未成功执行
        if not exec_result.executed:
            err = exec_result.error_reason or ""
            tag = "PATH_BLOCKED_1UPT" if "1UPT" in err else "ACTION_INVALID"
            return JevEscalationDecisionDTO(
                escalation_level=1,
                reason_tag=tag,
                confidence=0.92,
                rationale_short=f"单步动作受阻 ({err})，需参谋长局部重排单位顺序或路径",
            )

        # 3. LEVEL 1 战术微调判定 B：攻击目标残血幸存且当前单位移动力耗尽，需参谋长调邻近友军补刀
        target_after = delta.target_enemy_after
        unit_after = exec_result.unit_after
        if (
            target_after is not None
            and not target_after.enemy_killed
            and 0 < target_after.hp <= 15
            and (unit_after is None or unit_after.moves_left <= 0)
        ):
            return JevEscalationDecisionDTO(
                escalation_level=1,
                reason_tag="TARGET_SURVIVED_LOW_HP",
                confidence=0.94,
                rationale_short=(
                    f"目标敌军 {target_after.enemy_id} 受击后仅剩 {target_after.hp} HP 残血幸存，"
                    f"当前单位已无移动力，上报参谋长局部改派邻近友军协同收割（无需打扰玩家）"
                ),
            )

        # 4. LEVEL 0 正常继续
        return JevEscalationDecisionDTO(
            escalation_level=0,
            reason_tag="NOMINAL_CONTINUE",
            confidence=0.96,
            rationale_short="单步执行正常，增量视野无超阈值敌情或局部阻碍",
        )

    def record_jev_trajectory(
        self,
        sample_type: Literal["ACTION_CLASSIFICATION", "ESCALATION_CLASSIFICATION"],
        state_features: dict[str, Any],
        jev_prediction: dict[str, Any],
        final_adopted_label: str | int,
        was_overridden_by_human_or_superior: bool,
    ) -> str:
        """
        将单次判别特征、预测结果与最终采纳标签追加写入 JSONL 样本库（对齐 §5.3）。
        原因：为后续 EXP-07 及 Colab 轻量分类器微调提供标准化落盘样本。
        """
        record_id = f"JEV_TRJ_{uuid.uuid4().hex[:10]}"
        entry = {
            "record_id": record_id,
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "sample_type": sample_type,
            "state_features": state_features,
            "jev_prediction": jev_prediction,
            "final_adopted_label": final_adopted_label,
            "was_overridden_by_human_or_superior": was_overridden_by_human_or_superior,
        }
        with self.trajectory_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        return record_id
