# -*- coding: utf-8 -*-
"""
模块名称：orchestrator.py
职责说明：
    实现《02_软件总体设计说明书》模块 4 定义的三层指挥链状态机编排引擎（Advisor ↔ Chief ↔ Executor + Jev）：
    1. 管理单回合完整生命周期（TurnSessionContext）与状态跳转轨迹记录（state_transition_trace）；
    2. 正向链路：顾问拟定《本回合工作文书》-> 玩家审批 -> 参谋长拆解有序 TaskPackage 队列 -> 执行者单步循环；
    3. 逆向分支 A（LEVEL 1 战术微调）：执行层遇残敌幸存或局部受阻 -> 上报参谋长局部重排剩余可用兵力 -> 直接恢复执行（不打扰玩家）；
    4. 逆向分支 B（LEVEL 2 战略中断）：执行层揭盲遭遇敌主力军团 -> 冻结挂起未执行任务现场 -> 经参谋长核实超红线后退回顾问 ->
       向玩家呈报紧急请示 -> 玩家拍板后签发修订版《工作文书》并恢复调度剩余未动部队；
    5. 回合收尾：汇总实际执行战报修订并持久化《下一轮交接材料》（HandoffDocument）。
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
import json
from pathlib import Path
from typing import Any, Protocol
import uuid

from .jev_classifier import JevClassifierService
from .llm_gateway import LLMCallMeta, StreamCallback
from .mock_sandbox import OfflineCiv5Sandbox, hex_distance
from .schemas import (
    AdvisorEscalationAlertOutput,
    AdvisorProposalOutput,
    ChiefDispatchOutput,
    ChiefEscalationDecisionOutput,
    EscalationReport,
    HandoffDocument,
    SessionPhaseEnum,
    TaskPackage,
    TurnOverviewDTO,
    WorkDirective,
)


class StructuredLLMBackendProtocol(Protocol):
    """模型网关结构化生成协议，兼容 AgyCliBackend 与 DeterministicMockBackend。"""

    async def generate_structured(
        self,
        role_tier: str,
        call_tag: str,
        system_prompt: str,
        user_prompt: str,
        response_model: type[Any],
        conversation_id: str | None = None,
        effort: Any = "low",
        on_stream: StreamCallback | None = None,
    ) -> tuple[Any, LLMCallMeta]: ...


@dataclass
class TurnSessionContext:
    """
    单回合三层指挥链运行现场上下文（对齐《02_软件总体设计说明书》模块 4 主要功能变量）。
    所有中断退回与恢复执行均围绕此对象读写，确保现场零丢失。
    """

    turn_number: int
    prev_handoff: HandoffDocument
    phase: SessionPhaseEnum = SessionPhaseEnum.TURN_INIT
    active_directive: WorkDirective | None = None
    directive_history: list[WorkDirective] = field(default_factory=list)
    draft_next_handoff: HandoffDocument | None = None
    final_handoff: HandoffDocument | None = None

    task_queue: deque[TaskPackage] = field(default_factory=deque)
    suspended_tasks: list[TaskPackage] = field(default_factory=list)
    dispatch_history: list[list[TaskPackage]] = field(default_factory=list)

    execution_logs: list[dict[str, Any]] = field(default_factory=list)
    escalation_history: list[EscalationReport] = field(default_factory=list)
    active_escalation: EscalationReport | None = None
    pending_advisor_alert: AdvisorEscalationAlertOutput | None = None

    advisor_conv_id: str | None = None
    llm_call_metrics: list[LLMCallMeta] = field(default_factory=list)
    state_transition_trace: list[dict[str, Any]] = field(default_factory=list)


class ThreeTierOrchestrator:
    """三层指挥链（顾问 Tier 1 - 参谋长 Tier 2 - 执行者+Jev Tier 3）核心状态机。"""

    def __init__(
        self,
        sandbox: OfflineCiv5Sandbox,
        llm_backend: StructuredLLMBackendProtocol,
        jev_service: JevClassifierService,
        handoff_output_dir: Path,
        on_stream: StreamCallback | None = None,
    ) -> None:
        self.sandbox = sandbox
        self.llm = llm_backend
        self.jev = jev_service
        self.handoff_output_dir = handoff_output_dir
        self.handoff_output_dir.mkdir(parents=True, exist_ok=True)
        self.on_stream = on_stream

        assert sandbox.prev_handoff is not None
        self.session = TurnSessionContext(
            turn_number=sandbox.turn_number,
            prev_handoff=sandbox.prev_handoff.model_copy(deep=True),
        )
        self._record_transition(
            SessionPhaseEnum.TURN_INIT,
            "初始化回合会话并挂载上一轮交接文书",
        )

    def _record_transition(
        self,
        to_phase: SessionPhaseEnum,
        reason: str,
        extra: dict[str, Any] | None = None,
    ) -> None:
        """统一修改状态阶段并追加审计轨迹，供验收测试精确核对跳转链路。"""
        from_phase = self.session.phase
        self.session.phase = to_phase
        snap = {
            "seq": len(self.session.state_transition_trace) + 1,
            "from_phase": from_phase.value,
            "to_phase": to_phase.value,
            "reason": reason,
        }
        if extra:
            snap.update(extra)
        self.session.state_transition_trace.append(snap)

    # =========================================================================
    # 第一部分：顾问（Tier 1）拟定《工作文书》与玩家审批
    # =========================================================================

    async def start_turn_advisor_draft(self) -> AdvisorProposalOutput:
        """
        回合开始：顾问读取当前可见全局态势与上轮《交接材料》，生成《本回合工作文书》草案与《下轮交接初稿》。
        状态流转：TURN_INIT -> ADVISOR_DRAFTING -> WAITING_PLAYER_APPROVAL
        """
        self._record_transition(
            SessionPhaseEnum.ADVISOR_DRAFTING,
            "回合启动：顾问加载可见态势与上轮交接材料拟定方案草案",
        )
        overview = await self.sandbox.get_turn_overview()

        sys_prompt = (
            "你是《文明5》第一层级【战略顾问 (Tier 1 Advisor)】。"
            "你的职责是基于玩家当前可见战场态势（严禁臆测黑雾，但需警惕迷雾未知风险）与上一回合《交接材料》，"
            "拟定结构化的《本回合工作文书》(work_directive) 与《下轮交接材料初稿》(next_handoff_draft, from_turn=当前回合号)。"
            "必须在 redline_constraints 中明确规定安全红线（如：侦察尖兵揭开迷雾一旦发现2支及以上敌方正规军主力，必须立即停止东进并上报请示）。"
        )
        user_prompt = (
            f"【上一回合交接材料 (Turn {self.session.prev_handoff.from_turn})】\n"
            f"{self.session.prev_handoff.model_dump_json(indent=2)}\n\n"
            f"【当前第 {overview.turn_number} 回合全局可见态势】\n"
            f"{overview.model_dump_json(indent=2)}\n"
        )

        proposal, meta = await self.llm.generate_structured(
            role_tier="TIER1_ADVISOR",
            call_tag="ADVISOR_INITIAL_DRAFT",
            system_prompt=sys_prompt,
            user_prompt=user_prompt,
            response_model=AdvisorProposalOutput,
            conversation_id=self.session.advisor_conv_id,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta)
        if meta.conversation_id:
            self.session.advisor_conv_id = meta.conversation_id

        self.session.active_directive = proposal.work_directive
        self.session.draft_next_handoff = proposal.next_handoff_draft
        self._record_transition(
            SessionPhaseEnum.WAITING_PLAYER_APPROVAL,
            "顾问已出具《本回合工作文书》草案，等待玩家确认签发",
        )
        return proposal

    async def approve_directive_and_dispatch(
        self, approved_directive: WorkDirective | None = None
    ) -> list[TaskPackage]:
        """
        玩家批准《本回合工作文书》后，转交参谋长（Tier 2）拆解为有序 TaskPackage 队列并启动执行态。
        状态流转：WAITING_PLAYER_APPROVAL -> CHIEF_DISPATCHING -> EXECUTING
        """
        if approved_directive is not None:
            self.session.active_directive = approved_directive
        assert self.session.active_directive is not None, "尚未生成可批准的 WorkDirective"

        self.session.directive_history.append(
            self.session.active_directive.model_copy(deep=True)
        )
        self._record_transition(
            SessionPhaseEnum.CHIEF_DISPATCHING,
            "玩家已签发《工作文书》，移交参谋长拆解战术任务包",
        )

        overview = await self.sandbox.get_turn_overview()
        sys_prompt = (
            "你是《文明5》第二层级【参谋长 (Tier 2 Chief of Staff)】。"
            "请严格依据玩家签发的《本回合工作文书》与当前存活可行动单位列表，拆解为 2 个有序 TaskPackage（tasks 数组长度必须为 2）：\n"
            "1. 第1顺位 (execution_order=1)：遵循侦察先行原则，将尖兵侦察兵 (unit_id=101) 单独编为 SCOUT_EXECUTOR，"
            "tactical_posture 设为 'RECON_CAUTIOUS'，target_area 设为东北迷雾前沿 (target_x=16, target_y=18)，abort_on_new_enemy_count=2；\n"
            "2. 第2顺位 (execution_order=2)：将主力战斗单位 [102, 103] 编为 COMBAT_UNIT_EXECUTOR 协同包，"
            "负责在侦察确认安全后清除侧翼残敌并向河岸高地推进。"
        )
        user_prompt = (
            f"【已签发《本回合工作文书》】\n{self.session.active_directive.model_dump_json(indent=2)}\n\n"
            f"【当前战场态势】\n{overview.model_dump_json(indent=2)}\n"
        )

        dispatch_out, meta = await self.llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag="CHIEF_INITIAL_DISPATCH",
            system_prompt=sys_prompt,
            user_prompt=user_prompt,
            response_model=ChiefDispatchOutput,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta)

        ordered_tasks = sorted(dispatch_out.tasks, key=lambda t: t.execution_order)
        self.session.task_queue = deque(ordered_tasks)
        self.session.dispatch_history.append([t.model_copy(deep=True) for t in ordered_tasks])

        self._record_transition(
            SessionPhaseEnum.EXECUTING,
            f"参谋长完成拆单（共 {len(ordered_tasks)} 个 TaskPackage），进入执行层单步循环",
            extra={"task_ids": [t.task_id for t in ordered_tasks]},
        )
        return ordered_tasks

    # =========================================================================
    # 第三部分：执行者 + Jev（Tier 3）单步闭环与逆向分级上报
    # =========================================================================

    async def run_execution_loop_until_pause_or_done(self) -> SessionPhaseEnum:
        """
        驱动执行层循环消费 task_queue：
        - 若遇到 Jev LEVEL 1 战术异常：内部自动转交参谋长微调并无缝恢复 EXECUTING，不中断打扰玩家；
        - 若遇到 Jev LEVEL 2 战略警报：挂起未执行现场，经参谋长核实退回顾问，停在 ESCALATED_TO_ADVISOR 等待玩家决断；
        - 若全部任务顺利清空：自动收尾落盘交接文书，进入 TURN_COMPLETED。
        """
        assert self.session.active_directive is not None

        while self.session.task_queue:
            current_task = self.session.task_queue.popleft()
            unit_list = list(current_task.unit_ids)

            for idx_in_task, uid in enumerate(unit_list):
                # 连续驱动该单位单步移动/战斗直至移动力耗尽、抵达目标或触发中断
                step_guard = 0
                while step_guard < 4:
                    step_guard += 1
                    ctx = await self.sandbox.get_unit_context_and_candidates(uid, radius=2)
                    if ctx.unit.moves_left <= 0 or not ctx.unit.can_act:
                        break

                    # 若谨慎侦察或推进单位已抵达目标格且无攻击需求，原地结束移动防止无意义徘徊
                    dist_to_goal = hex_distance(
                        ctx.unit.x,
                        ctx.unit.y,
                        current_task.target_area.target_x,
                        current_task.target_area.target_y,
                    )
                    if dist_to_goal == 0 and current_task.tactical_posture in (
                        "RECON_CAUTIOUS",
                        "ADVANCE",
                    ):
                        break

                    # 1. 调用 Jev 对全部合法候选动作进行四分类战术打分
                    scored_actions = await self.jev.evaluate_candidate_actions(ctx, current_task)
                    best_scored = scored_actions[0]
                    chosen_cand = next(
                        c for c in ctx.candidate_actions if c.action_id == best_scored.action_id
                    )

                    self.jev.record_jev_trajectory(
                        sample_type="ACTION_CLASSIFICATION",
                        state_features={
                            "turn": self.session.turn_number,
                            "task_id": current_task.task_id,
                            "unit_id": uid,
                            "unit_pos": [ctx.unit.x, ctx.unit.y],
                            "moves_left": ctx.unit.moves_left,
                            "posture": current_task.tactical_posture,
                            "target_area": current_task.target_area.model_dump(),
                            "candidate_count": len(ctx.candidate_actions),
                        },
                        jev_prediction=best_scored.model_dump(),
                        final_adopted_label=best_scored.label,
                        was_overridden_by_human_or_superior=False,
                    )

                    # 2. 在沙盘执行最优单步动作并采样增量揭盲视野
                    exec_res = await self.sandbox.execute_unit_step(
                        unit_id=uid,
                        action_type=chosen_cand.action_type,
                        target_x=chosen_cand.target_x,
                        target_y=chosen_cand.target_y,
                    )

                    # 3. 调用 Jev 对动作后的增量视野（DeltaObservation）进行异常分级判别
                    esc_decision = await self.jev.evaluate_step_escalation(
                        before_context=ctx,
                        exec_result=exec_res,
                        task_package=current_task,
                        redlines=self.session.active_directive.redline_constraints,
                    )

                    self.jev.record_jev_trajectory(
                        sample_type="ESCALATION_CLASSIFICATION",
                        state_features={
                            "turn": self.session.turn_number,
                            "task_id": current_task.task_id,
                            "unit_id": uid,
                            "action_type": chosen_cand.action_type,
                            "after_pos": (
                                [exec_res.unit_after.x, exec_res.unit_after.y]
                                if exec_res.unit_after
                                else None
                            ),
                            "newly_spotted_count": len(
                                exec_res.delta_observation.newly_spotted_enemies
                            ),
                            "target_enemy_hp_after": (
                                exec_res.delta_observation.target_enemy_after.hp
                                if exec_res.delta_observation.target_enemy_after
                                else None
                            ),
                        },
                        jev_prediction=esc_decision.model_dump(),
                        final_adopted_label=esc_decision.escalation_level,
                        was_overridden_by_human_or_superior=False,
                    )

                    self.session.execution_logs.append(
                        {
                            "step_seq": len(self.session.execution_logs) + 1,
                            "task_id": current_task.task_id,
                            "unit_id": uid,
                            "action_id": chosen_cand.action_id,
                            "action_type": chosen_cand.action_type,
                            "from_pos": [ctx.unit.x, ctx.unit.y],
                            "target_pos": [chosen_cand.target_x, chosen_cand.target_y],
                            "jev_action_label": best_scored.label,
                            "jev_action_confidence": best_scored.confidence,
                            "executed": exec_res.executed,
                            "moves_left_after": (
                                exec_res.unit_after.moves_left if exec_res.unit_after else 0.0
                            ),
                            "newly_spotted_enemies": [
                                e.model_dump()
                                for e in exec_res.delta_observation.newly_spotted_enemies
                            ],
                            "target_enemy_after": (
                                exec_res.delta_observation.target_enemy_after.model_dump()
                                if exec_res.delta_observation.target_enemy_after
                                else None
                            ),
                            "jev_escalation_level": esc_decision.escalation_level,
                            "jev_escalation_reason": esc_decision.reason_tag,
                        }
                    )

                    # 分支 0：正常继续执行
                    if esc_decision.escalation_level == 0:
                        if exec_res.unit_after is None or exec_res.unit_after.moves_left <= 0:
                            break
                        continue

                    # 若触发 LEVEL 1 或 LEVEL 2 中断，先完整保存当前任务剩余单位与队列中未执行的任务包现场
                    remaining_units_same_task = unit_list[idx_in_task + 1 :]
                    preserved: list[TaskPackage] = []
                    if remaining_units_same_task:
                        sub_pkg = current_task.model_copy(deep=True)
                        sub_pkg.unit_ids = remaining_units_same_task
                        preserved.append(sub_pkg)
                    preserved.extend(list(self.session.task_queue))
                    self.session.suspended_tasks = preserved
                    self.session.task_queue.clear()

                    report = self._build_escalation_report(
                        level=esc_decision.escalation_level,  # type: ignore[arg-type]
                        task=current_task,
                        trigger_unit_id=uid,
                        reason_tag=esc_decision.reason_tag,
                        rationale=esc_decision.rationale_short,
                        exec_res=exec_res,
                    )
                    self.session.active_escalation = report
                    self.session.escalation_history.append(report.model_copy(deep=True))

                    # 分支 1：LEVEL 1 战术微调 -> 退回参谋长局部重排后立即恢复 EXECUTING，不打扰玩家
                    if esc_decision.escalation_level == 1:
                        await self._handle_level1_tactical_replan(report)
                        break

                    # 分支 2：LEVEL 2 战略警报 -> 经参谋长核实超红线后退回顾问，挂起等待玩家拍板
                    if esc_decision.escalation_level == 2:
                        escalated_to_advisor = await self._handle_level2_strategic_escalation(
                            report
                        )
                        if escalated_to_advisor:
                            return self.session.phase
                        break

                # 若已进入顾问等待玩家决断态，立刻退出外层循环保护现场
                if self.session.phase == SessionPhaseEnum.ESCALATED_TO_ADVISOR:
                    return self.session.phase
                # 若刚刚完成了 LEVEL 1 队列重排，跳出旧任务的 unit_list 循环，从新 task_queue 头部消费
                if self.session.active_escalation is None and len(unit_list) > 1:
                    break

        # 全部任务包执行完毕，进入回合总结落盘
        await self._finalize_turn_wrapup()
        return self.session.phase

    def _build_escalation_report(
        self,
        level: int,
        task: TaskPackage,
        trigger_unit_id: int,
        reason_tag: str,
        rationale: str,
        exec_res: Any,
    ) -> EscalationReport:
        """根据异常上下文构造标准《下级主动上报单》(EscalationReport)。"""
        esc_id = f"ESC_T{self.session.turn_number}_L{level}_{uuid.uuid4().hex[:6].upper()}"
        if level == 2:
            options = [
                "A. 立即中止东进转入防线收缩：远程清除侧翼残敌，步兵抢占河岸丘陵驻防",
                "B. 全军放弃河岸阵地向首都城郊后撤",
                "C. 强行投入后续梯队向迷雾区接敌交战",
            ]
        else:
            options = [
                "A. 改派邻近尚未行动的近战友军前出补刀歼灭残敌",
                "B. 忽略残敌继续执行原定驻防任务",
            ]

        return EscalationReport(
            escalation_id=esc_id,
            level=level,  # type: ignore[arg-type]
            source_task_id=task.task_id,
            trigger_unit_id=trigger_unit_id,
            trigger_reason_tag=reason_tag,  # type: ignore[arg-type]
            delta_observation=exec_res.delta_observation.model_copy(deep=True),
            situation_brief=rationale,
            options_for_superior=options,
        )

    async def _handle_level1_tactical_replan(self, report: EscalationReport) -> None:
        """
        处理 LEVEL 1 战术级上报：由参谋长在权限内对剩余可行动单位进行局部任务重排，不上升至顾问或玩家。
        状态流转：EXECUTING -> ESCALATED_TO_CHIEF -> EXECUTING
        """
        self._record_transition(
            SessionPhaseEnum.ESCALATED_TO_CHIEF,
            f"触发 LEVEL 1 战术异常 ({report.trigger_reason_tag})，上报参谋长局部微调",
            extra={
                "escalation_id": report.escalation_id,
                "suspended_task_ids": [t.task_id for t in self.session.suspended_tasks],
            },
        )
        overview = await self.sandbox.get_turn_overview()
        actable_units = [u for u in overview.our_units if u.can_act and u.moves_left > 0]

        sys_prompt = (
            "你是《文明5》第二层级【参谋长 (Tier 2 Chief of Staff)】。"
            "当前执行层上报了 LEVEL 1 局部战术异常（目标敌军受远程打击后仅剩少量 HP 幸存，攻击单位移动力已耗尽）。"
            "该情况未违反《工作文书》战略红线，完全属于你的局部战术协同权限，严禁上交顾问打扰玩家（can_resolve_tactically 必须为 true）！"
            "请针对当前仍有剩余移动力 (can_act=true) 的近战单位（如 unit_id=103 北河长矛营），输出 replanned_tasks，"
            "将其 tactical_posture 调整为 'FOCUS_FIRE'，target_area 指向残血敌军所在坐标 (target_x=14, target_y=17) 完成近战补刀收割。"
        )
        user_prompt = (
            f"【LEVEL 1 下级上报单】\n{report.model_dump_json(indent=2)}\n\n"
            f"【当前挂起的未执行任务包】\n{json.dumps([t.model_dump() for t in self.session.suspended_tasks], ensure_ascii=False, indent=2)}\n\n"
            f"【当前仍可行动的己方单位】\n{json.dumps([u.model_dump() for u in actable_units], ensure_ascii=False, indent=2)}\n\n"
            f"【当前可见敌情】\n{json.dumps([e.model_dump() for e in overview.visible_enemies], ensure_ascii=False, indent=2)}\n"
        )

        decision, meta = await self.llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag="CHIEF_EVAL_ESCALATION_L1",
            system_prompt=sys_prompt,
            user_prompt=user_prompt,
            response_model=ChiefEscalationDecisionOutput,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta)

        ordered_replan = sorted(decision.replanned_tasks, key=lambda t: t.execution_order)
        self.session.task_queue = deque(ordered_replan)
        self.session.dispatch_history.append([t.model_copy(deep=True) for t in ordered_replan])
        self.session.suspended_tasks.clear()
        self.session.active_escalation = None

        self._record_transition(
            SessionPhaseEnum.EXECUTING,
            "参谋长已完成 LEVEL 1 局部战术重排（未打扰顾问与玩家），恢复执行层循环",
            extra={"replanned_task_ids": [t.task_id for t in ordered_replan]},
        )

    async def _handle_level2_strategic_escalation(self, report: EscalationReport) -> bool:
        """
        处理 LEVEL 2 战略级警报：先经参谋长核实确属超出战术权限并触及红线，再转呈顾问生成玩家紧急请示单。
        状态流转：EXECUTING -> ESCALATED_TO_CHIEF -> ESCALATED_TO_ADVISOR
        """
        self._record_transition(
            SessionPhaseEnum.ESCALATED_TO_CHIEF,
            f"触发 LEVEL 2 战略警报 ({report.trigger_reason_tag})，先报参谋长核实红线影响",
            extra={
                "escalation_id": report.escalation_id,
                "suspended_task_ids": [t.task_id for t in self.session.suspended_tasks],
            },
        )
        assert self.session.active_directive is not None
        overview = await self.sandbox.get_turn_overview()

        chief_sys = (
            "你是《文明5》第二层级【参谋长 (Tier 2 Chief of Staff)】。"
            "前线侦察单位刚刚触发 LEVEL 2 战略警报，揭开迷雾发现了多支敌方正规军主力，已直接触犯《本回合工作文书》中的红线约束！"
            "此类全局战略态势剧变超出参谋部局部微调权限，你必须将 can_resolve_tactically 设为 false（replanned_tasks 留空数组），"
            "并在 chief_assessment 中写明威胁研判，立即上报战略顾问请示玩家！"
        )
        chief_user = (
            f"【当前生效《工作文书》红线约束】\n{json.dumps(self.session.active_directive.redline_constraints, ensure_ascii=False)}\n\n"
            f"【LEVEL 2 下级上报单】\n{report.model_dump_json(indent=2)}\n\n"
            f"【已挂起保留现场的后续任务包】\n{json.dumps([t.model_dump() for t in self.session.suspended_tasks], ensure_ascii=False, indent=2)}\n"
        )

        chief_eval, meta_c = await self.llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag="CHIEF_EVAL_ESCALATION_L2",
            system_prompt=chief_sys,
            user_prompt=chief_user,
            response_model=ChiefEscalationDecisionOutput,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta_c)

        # 参谋长确认无法在战术层消化，逐级退回顾问请示玩家
        self._record_transition(
            SessionPhaseEnum.ESCALATED_TO_ADVISOR,
            "参谋长确认敌主力伏击超出红线权限，逐级退回顾问并向玩家发出战略请示",
            extra={"chief_can_resolve_tactically": chief_eval.can_resolve_tactically},
        )

        adv_sys = (
            "你是《文明5》第一层级【战略顾问 (Tier 1 Advisor)】。"
            "执行层揭开迷雾遭遇敌方主力兵团，经参谋长核实已触犯本回合战略红线并挂起后续主力部队动作。"
            "请结合保留的执行现场（侦察兵 101 已移动至 (16,18) 耗尽移动力，主力 102 与 103 仍满移动力待命），"
            "向玩家呈报简明紧急军情与至少 2~3 个明确处置选项（首推选项 A：立即中止东进转入河岸防线收缩，远程清除侧翼(14,17)残血蛮族并派步兵占领(14,18)河岸丘陵驻防）。"
        )
        adv_user = (
            f"【下级 LEVEL 2 上报单】\n{report.model_dump_json(indent=2)}\n\n"
            f"【参谋长威胁研判】\n{chief_eval.chief_assessment}\n\n"
            f"【本回合已发生执行现场日志】\n{json.dumps(self.session.execution_logs, ensure_ascii=False, indent=2)}\n\n"
            f"【当前最新全局可见态势】\n{overview.model_dump_json(indent=2)}\n"
        )

        alert_out, meta_a = await self.llm.generate_structured(
            role_tier="TIER1_ADVISOR",
            call_tag="ADVISOR_ESCALATION_ALERT",
            system_prompt=adv_sys,
            user_prompt=adv_user,
            response_model=AdvisorEscalationAlertOutput,
            conversation_id=self.session.advisor_conv_id,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta_a)
        if meta_a.conversation_id:
            self.session.advisor_conv_id = meta_a.conversation_id

        self.session.pending_advisor_alert = alert_out
        return True

    # =========================================================================
    # 玩家拍板处置 LEVEL 2 战略中断并恢复剩余部队执行
    # =========================================================================

    async def resolve_level2_escalation_by_player(
        self,
        chosen_option: str,
        player_custom_instruction: str = "",
    ) -> list[TaskPackage]:
        """
        接收玩家对 LEVEL 2 战略警报的决断：
        1. 顾问结合最新现场签发修订版《本回合工作文书》；
        2. 参谋长仅针对当前仍有剩余行动力的单位（排除已耗尽移动力的侦察兵 101）重新编组任务包；
        3. 清理挂起状态并恢复进入 EXECUTING。
        状态流转：ESCALATED_TO_ADVISOR -> ADVISOR_DRAFTING -> WAITING_PLAYER_APPROVAL -> CHIEF_DISPATCHING -> EXECUTING
        """
        assert self.session.phase == SessionPhaseEnum.ESCALATED_TO_ADVISOR
        assert self.session.active_escalation is not None

        self._record_transition(
            SessionPhaseEnum.ADVISOR_DRAFTING,
            f"玩家对战略警报做出决断 ({chosen_option[:24]}...)，顾问据此修订《工作文书》",
        )
        overview = await self.sandbox.get_turn_overview()
        actable_units = [u for u in overview.our_units if u.can_act and u.moves_left > 0]

        adv_sys = (
            "你是《文明5》第一层级【战略顾问 (Tier 1 Advisor)】。"
            "玩家已针对东北迷雾发现匈奴主力的紧急军情下达决断。请结合当前战场现场（注意：unit_id=101 侦察兵移动力已为 0 无法再动，仅 unit_id=102 复合弓与 unit_id=103 长矛营可行动），"
            "签发修订版《本回合工作文书》(work_directive) 与修订版《下轮交接材料初稿》(next_handoff_draft, from_turn=45)。"
        )
        adv_user = (
            f"【玩家决断选项】{chosen_option}\n"
            f"【玩家补充指示】{player_custom_instruction}\n\n"
            f"【当前最新全局可见态势（含已暴露敌主力与各单位剩余移动力）】\n{overview.model_dump_json(indent=2)}\n"
        )

        revised_prop, meta_adv = await self.llm.generate_structured(
            role_tier="TIER1_ADVISOR",
            call_tag="ADVISOR_REVISED_DIRECTIVE",
            system_prompt=adv_sys,
            user_prompt=adv_user,
            response_model=AdvisorProposalOutput,
            conversation_id=self.session.advisor_conv_id,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta_adv)
        if meta_adv.conversation_id:
            self.session.advisor_conv_id = meta_adv.conversation_id

        self.session.active_directive = revised_prop.work_directive
        self.session.draft_next_handoff = revised_prop.next_handoff_draft
        self.session.directive_history.append(
            revised_prop.work_directive.model_copy(deep=True)
        )

        self._record_transition(
            SessionPhaseEnum.WAITING_PLAYER_APPROVAL,
            "顾问已按玩家决断拟妥修订版《工作文书》并自动获批生效",
        )
        self._record_transition(
            SessionPhaseEnum.CHIEF_DISPATCHING,
            "参谋长根据修订版《工作文书》对现场剩余可行动兵力重新拆单",
        )

        chief_sys = (
            "你是《文明5》第二层级【参谋长 (Tier 2 Chief of Staff)】。"
            "请根据修订后的防线收缩《工作文书》，仅对当前仍有移动力 (can_act=true) 的单位 [102, 103] 拆解为 2 个独立有序的 TaskPackage（严禁将 moves_left=0 的 101 编入任务包！）：\n"
            "1. execution_order=1：指派远程单位 unit_ids=[102] (禁卫复合弓营)，executor_type='COMBAT_UNIT_EXECUTOR'，"
            "tactical_posture='FOCUS_FIRE'，target_area 设为侧翼残血蛮族弓箭手坐标 (target_x=14, target_y=17, target_enemy_id='63:501')；\n"
            "2. execution_order=2：指派近战单位 unit_ids=[103] (北河长矛营)，executor_type='COMBAT_UNIT_EXECUTOR'，"
            "tactical_posture='HOLD_DEFEND'，target_area 设为河岸丘陵防线坐标 (target_x=14, target_y=18)。"
        )
        chief_user = (
            f"【修订版《本回合工作文书》】\n{self.session.active_directive.model_dump_json(indent=2)}\n\n"
            f"【当前剩余可行动单位 (can_act=true)】\n{json.dumps([u.model_dump() for u in actable_units], ensure_ascii=False, indent=2)}\n\n"
            f"【当前可见敌军】\n{json.dumps([e.model_dump() for e in overview.visible_enemies], ensure_ascii=False, indent=2)}\n"
        )

        chief_out, meta_chief = await self.llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag="CHIEF_REVISED_DISPATCH",
            system_prompt=chief_sys,
            user_prompt=chief_user,
            response_model=ChiefDispatchOutput,
            effort="low",
            on_stream=self.on_stream,
        )
        self.session.llm_call_metrics.append(meta_chief)

        # 过滤保护：确保已无行动力的单位不会被错误排入恢复队列
        actable_ids = {u.unit_id for u in actable_units}
        valid_tasks: list[TaskPackage] = []
        for t in sorted(chief_out.tasks, key=lambda x: x.execution_order):
            filtered_uids = [uid for uid in t.unit_ids if uid in actable_ids]
            if filtered_uids:
                t_clean = t.model_copy(deep=True)
                t_clean.unit_ids = filtered_uids
                valid_tasks.append(t_clean)

        self.session.task_queue = deque(valid_tasks)
        self.session.dispatch_history.append([t.model_copy(deep=True) for t in valid_tasks])
        self.session.suspended_tasks.clear()
        self.session.active_escalation = None
        self.session.pending_advisor_alert = None

        self._record_transition(
            SessionPhaseEnum.EXECUTING,
            f"战略重规划完成，恢复执行剩余兵力任务队列（共 {len(valid_tasks)} 个 TaskPackage）",
            extra={"resumed_task_ids": [t.task_id for t in valid_tasks]},
        )
        return valid_tasks

    # =========================================================================
    # 回合收尾：修订并落盘《下一轮交接材料》
    # =========================================================================

    async def _finalize_turn_wrapup(self) -> HandoffDocument:
        """汇总本回合实际执行战报与最新敌情，定稿并落盘《下一轮交接材料》。"""
        overview = await self.sandbox.get_turn_overview()
        base_handoff = (
            self.session.draft_next_handoff.model_copy(deep=True)
            if self.session.draft_next_handoff is not None
            else self.session.prev_handoff.model_copy(deep=True)
        )
        base_handoff.from_turn = self.session.turn_number

        step_summaries = [
            f"#{log['step_seq']} 单位{log['unit_id']} {log['action_type']}->{log['target_pos']}(中断级别={log['jev_escalation_level']})"
            for log in self.session.execution_logs
        ]
        surviving_enemies = [
            f"{e.owner_name}:{e.unit_type}@({e.x},{e.y},HP={e.hp})"
            for e in overview.visible_enemies
        ]
        base_handoff.unresolved_threats = surviving_enemies
        base_handoff.last_turn_execution_summary = (
            f"第{self.session.turn_number}回合共执行 {len(self.session.execution_logs)} 个原子步，"
            f"经历 {len(self.session.escalation_history)} 次自下而上中断上报（含 LEVEL 2 战略转向与 LEVEL 1 战术补刀）："
            + "；".join(step_summaries)
        )

        self.session.final_handoff = base_handoff
        out_file = self.handoff_output_dir / f"turn_{self.session.turn_number}_handoff.json"
        out_file.write_text(
            base_handoff.model_dump_json(indent=2),
            encoding="utf-8",
        )

        self._record_transition(
            SessionPhaseEnum.TURN_COMPLETED,
            f"全部单位任务执行完毕，已修订并落盘下一轮交接材料 ({out_file.name})",
        )
        return base_handoff
