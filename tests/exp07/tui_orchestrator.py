# -*- coding: utf-8 -*-
"""
模块名称：tui_orchestrator.py
职责说明：
    将 EXP-05 的三层指挥链状态机与 EXP-06 的真实 MCP Server 异步客户端接入 Textual 事件总线：
    1. 以非阻塞协程形式模拟 agy CLI / GLM API 高频流式 THINKING + TEXT 输出，实时推向 TUI 中栏与右栏；
    2. 完整运行第 45 回合北河迷雾伏击沙盘闭环：
       顾问拟稿 -> 玩家审批 -> 参谋长拆单 -> 执行者经真实 MCP Server 逐格执行 ->
       Jev 候选打分与轨迹落盘 -> 侦察兵揭盲触发 LEVEL 2 警报冻结现场 -> 玩家在 TUI 点击决断并落盘人工修正样本 ->
       修订文书恢复执行 -> 复合弓触发 LEVEL 1 参谋长局部补刀微调 -> 全军收尾并落盘交接材料；
    3. 响应 TUI 上行指令：同步态势、玩家对话、模型热切换、录制快照、紧急中止。
"""

from __future__ import annotations

import asyncio
from collections import deque
import json
from pathlib import Path
from typing import Any, Awaitable, Callable, Literal
import uuid

from ..exp05.llm_gateway import DeterministicMockBackend
from ..exp05.schemas import (
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
from .events import (
    AbortExecutionCommand,
    AgentStreamChunkEvent,
    ApproveWorkDirectiveCommand,
    DirectiveDraftReadyEvent,
    EscalationAlertEvent,
    ModelRouteTable,
    OrchestratorToUIMessage,
    PlayerChatToAdvisorCommand,
    RecordSnapshotCommand,
    ResolveEscalationCommand,
    StepExecutedEvent,
    SwitchTierModelCommand,
    SyncTurnFromGameCommand,
    SystemNoticeEvent,
    TaskQueueUpdatedEvent,
    TurnCompletedEvent,
    TurnStateUpdatedEvent,
    UIToOrchestratorCommand,
)
from .jev_coldstart import (
    HybridColdStartJevService,
    extract_action_features,
    extract_escalation_features,
)
from .mcp_game_client import Civ5McpSessionAdapter

UIEventEmitter = Callable[[OrchestratorToUIMessage], Awaitable[None]]


class TuiCommandController:
    """
    面向 Textual TUI 的三层指挥链异步编排控制器。
    原因：通过纯异步事件回调与 TUI 完全解耦，全部 LLM 流式推演、MCP 通信与磁盘落盘均在后台异步任务执行，
    确保 Textual 主事件循环恒定 60fps 响应玩家滚动与按键操作。
    """

    def __init__(
        self,
        mcp_client: Civ5McpSessionAdapter,
        jev_service: HybridColdStartJevService,
        output_dir: Path,
        emit_event: UIEventEmitter,
        stream_chunk_delay_sec: float = 0.015,
    ) -> None:
        self.mcp = mcp_client
        self.jev = jev_service
        self.output_dir = output_dir
        self.handoff_dir = output_dir / "handoffs"
        self.handoff_dir.mkdir(parents=True, exist_ok=True)
        self.emit = emit_event
        self.stream_chunk_delay_sec = stream_chunk_delay_sec

        self._mock_llm = DeterministicMockBackend()
        self.model_routes = ModelRouteTable()

        self.phase: SessionPhaseEnum = SessionPhaseEnum.TURN_INIT
        self.turn_number: int = 45
        self.prev_handoff: HandoffDocument = mcp_client.prev_handoff.model_copy(deep=True)
        self.active_directive: WorkDirective | None = None
        self.draft_next_handoff: HandoffDocument | None = None
        self.final_handoff: HandoffDocument | None = None

        self.task_queue: deque[TaskPackage] = deque()
        self.suspended_tasks: list[TaskPackage] = []
        self.active_escalation: EscalationReport | None = None
        self.last_escalation_features: dict[str, Any] | None = None
        self.execution_logs: list[dict[str, Any]] = []
        self.state_transitions: list[str] = [SessionPhaseEnum.TURN_INIT.value]
        self.stream_chunks_emitted: int = 0
        self.last_snapshot_path: str | None = None
        self._abort_requested: bool = False

    def _set_phase(self, new_phase: SessionPhaseEnum) -> None:
        self.phase = new_phase
        self.state_transitions.append(new_phase.value)

    async def _emit_stream_text(
        self,
        tier: Literal["TIER1_ADVISOR", "TIER2_CHIEF", "TIER3_EXECUTOR"],
        chunk_type: Literal["THINKING", "TEXT"],
        full_text: str,
        chunk_size: int = 10,
    ) -> None:
        """
        将大模型思维链或正文切片按异步帧率流式推送给 TUI。
        原因：模拟 agy stream-json / GLM SSE 高频 token 推流负载，同时每帧让出控制权给事件循环。
        """
        for idx in range(0, len(full_text), chunk_size):
            if self._abort_requested:
                break
            chunk = full_text[idx : idx + chunk_size]
            self.stream_chunks_emitted += 1
            await self.emit(
                AgentStreamChunkEvent(tier=tier, chunk_type=chunk_type, content=chunk)
            )
            if self.stream_chunk_delay_sec > 0:
                await asyncio.sleep(self.stream_chunk_delay_sec)

    async def handle_command(self, cmd: UIToOrchestratorCommand) -> None:
        """统一分发来自 TUI 界面的 7 类控制指令。"""
        if isinstance(cmd, SyncTurnFromGameCommand):
            await self._cmd_sync_turn(cmd)
        elif isinstance(cmd, PlayerChatToAdvisorCommand):
            await self._cmd_player_chat(cmd)
        elif isinstance(cmd, ApproveWorkDirectiveCommand):
            await self._cmd_approve_and_execute(cmd)
        elif isinstance(cmd, ResolveEscalationCommand):
            await self._cmd_resolve_escalation(cmd)
        elif isinstance(cmd, SwitchTierModelCommand):
            await self._cmd_switch_model(cmd)
        elif isinstance(cmd, RecordSnapshotCommand):
            await self._cmd_record_snapshot(cmd)
        elif isinstance(cmd, AbortExecutionCommand):
            self._abort_requested = True
            await self.emit(
                SystemNoticeEvent(level="WARN", message=f"已收到紧急中止请求：{cmd.reason}")
            )

    async def _cmd_sync_turn(self, cmd: SyncTurnFromGameCommand) -> None:
        """经真实 MCP Server 拉取当前全局可见态势，并可自动触发顾问首轮流式拟稿。"""
        self._abort_requested = False
        overview = await self.mcp.get_turn_overview()
        self.turn_number = overview.turn_number
        await self.emit(
            TurnStateUpdatedEvent(
                overview=overview, phase=self.phase, runtime_mode=self.mcp.mode
            )
        )
        await self.emit(
            SystemNoticeEvent(
                level="INFO",
                message=f"已同步第 {overview.turn_number} 回合态势（我方 {len(overview.our_units)} 单位，可见敌军 {len(overview.visible_enemies)} 支）。",
            )
        )

        if cmd.auto_start_advisor:
            await self._run_advisor_initial_draft(overview)

    async def _run_advisor_initial_draft(self, overview: TurnOverviewDTO) -> None:
        """第一部分：顾问（Tier 1）流式推演并签发《本回合工作文书》草案。"""
        self._set_phase(SessionPhaseEnum.ADVISOR_DRAFTING)
        await self.emit(
            TurnStateUpdatedEvent(
                overview=overview, phase=self.phase, runtime_mode=self.mcp.mode
            )
        )

        await self._emit_stream_text(
            "TIER1_ADVISOR",
            "THINKING",
            f"[{self.model_routes.tier1_advisor}] 正在分析第{overview.turn_number}回合态势：北京东北迷雾未知，"
            "须严格执行“侦察先行”并设立≥2支正规军即刻停步上报红线，侧翼(14,17)残血蛮族弓手可由复合弓与矛兵协同肃清。",
            chunk_size=12,
        )

        proposal, _ = await self._mock_llm.generate_structured(
            role_tier="TIER1_ADVISOR",
            call_tag="ADVISOR_INITIAL_DRAFT",
            system_prompt="",
            user_prompt=overview.model_dump_json(),
            response_model=AdvisorProposalOutput,
        )
        await self._emit_stream_text(
            "TIER1_ADVISOR",
            "TEXT",
            proposal.advisor_brief_to_player + "\n",
            chunk_size=12,
        )

        self.active_directive = proposal.work_directive
        self.draft_next_handoff = proposal.next_handoff_draft
        self._set_phase(SessionPhaseEnum.WAITING_PLAYER_APPROVAL)
        await self.emit(
            DirectiveDraftReadyEvent(
                directive_draft=proposal.work_directive,
                handoff_draft=proposal.next_handoff_draft,
                advisor_brief=proposal.advisor_brief_to_player,
            )
        )
        await self.emit(
            TurnStateUpdatedEvent(
                overview=overview, phase=self.phase, runtime_mode=self.mcp.mode
            )
        )

    async def _cmd_player_chat(self, cmd: PlayerChatToAdvisorCommand) -> None:
        """响应玩家在中栏输入的自然语言意见，流式回馈顾问修订确认。"""
        msg = cmd.message.strip()
        if not msg:
            return
        await self._emit_stream_text(
            "TIER1_ADVISOR",
            "THINKING",
            f"[{self.model_routes.tier1_advisor}] 收到司令官批示“{msg}”，校核《工作文书》红线条款与优先顺位。",
            chunk_size=14,
        )
        if self.active_directive is not None:
            self.active_directive.redline_constraints.append(f"玩家补充批示：{msg}")
            assert self.draft_next_handoff is not None
            await self.emit(
                DirectiveDraftReadyEvent(
                    directive_draft=self.active_directive,
                    handoff_draft=self.draft_next_handoff,
                    advisor_brief=f"已按司令官指示将「{msg}」写入本回合执行红线，请随时点击【批准并下发参谋长】。",
                )
            )
        await self._emit_stream_text(
            "TIER1_ADVISOR",
            "TEXT",
            f"明白！已将您的意见「{msg}」纳入《本回合工作文书》红线，随时可点击批准按钮下发参谋部。\n",
            chunk_size=14,
        )

    async def _cmd_approve_and_execute(self, cmd: ApproveWorkDirectiveCommand) -> None:
        """玩家批准公文后：参谋长（Tier 2）拆单 -> 执行者+Jev（Tier 3）经真实 MCP Server 循环执行。"""
        if cmd.edited_directive is not None:
            self.active_directive = cmd.edited_directive
        if self.active_directive is None:
            await self.emit(
                SystemNoticeEvent(level="WARN", message="当前无待审批的《工作文书》，请先同步回合态势。")
            )
            return

        self._abort_requested = False
        self._set_phase(SessionPhaseEnum.CHIEF_DISPATCHING)
        overview = await self.mcp.get_turn_overview()
        await self.emit(
            TurnStateUpdatedEvent(
                overview=overview, phase=self.phase, runtime_mode=self.mcp.mode
            )
        )

        await self._emit_stream_text(
            "TIER2_CHIEF",
            "THINKING",
            f"[{self.model_routes.tier2_chief}] 正在依据已签发《工作文书》拆解有序任务包：侦察兵101首顺位探明东北迷雾，主力[102,103]次顺位待命。",
            chunk_size=14,
        )
        dispatch_out, _ = await self._mock_llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag="CHIEF_INITIAL_DISPATCH",
            system_prompt="",
            user_prompt=self.active_directive.model_dump_json(),
            response_model=ChiefDispatchOutput,
        )
        await self._emit_stream_text(
            "TIER2_CHIEF", "TEXT", dispatch_out.dispatch_summary + "\n", chunk_size=14
        )

        ordered = sorted(dispatch_out.tasks, key=lambda t: t.execution_order)
        self.task_queue = deque(ordered)
        self._set_phase(SessionPhaseEnum.EXECUTING)
        await self.emit(
            TaskQueueUpdatedEvent(
                tasks=list(self.task_queue),
                active_task_id=ordered[0].task_id if ordered else None,
                note="参谋长初始拆单完成",
            )
        )
        await self._run_execution_loop()

    async def _run_execution_loop(self) -> None:
        """执行层单步循环：调用真实 MCP Server 获取候选 -> Jev 打分 -> MCP 执行 -> Jev 中断判别与轨迹落盘。"""
        assert self.active_directive is not None

        while self.task_queue and not self._abort_requested:
            task = self.task_queue.popleft()
            await self.emit(
                TaskQueueUpdatedEvent(
                    tasks=[task, *list(self.task_queue)],
                    active_task_id=task.task_id,
                    note=f"正在执行 {task.task_id} ({task.tactical_posture})",
                )
            )

            interrupted = False
            for idx, uid in enumerate(task.unit_ids):
                if self._abort_requested:
                    break
                remaining_ids = task.unit_ids[idx + 1 :]

                for _step_guard in range(4):
                    if self._abort_requested:
                        break
                    ctx = await self.mcp.get_unit_context_and_candidates(
                        unit_id=uid, radius=2
                    )
                    if ctx.unit.moves_left <= 0 or not ctx.candidate_actions:
                        break

                    # 1. Jev 候选动作四分类打分
                    scored = await self.jev.evaluate_candidate_actions(ctx, task)
                    best_score = scored[0]
                    chosen_cand = next(
                        c for c in ctx.candidate_actions if c.action_id == best_score.action_id
                    )

                    # 将所有候选动作中的首选及次选（若存在）按标准特征落盘，丰富 Colab 训练集类别多样性
                    best_features = extract_action_features(
                        self.turn_number, ctx, task, chosen_cand
                    )
                    await self.jev.record_jev_trajectory_async(
                        sample_type="ACTION_CLASSIFICATION",
                        state_features=best_features,
                        jev_prediction=best_score.model_dump(),
                        final_adopted_label=best_score.label,
                        was_overridden_by_human_or_superior=False,
                        meta={"task_id": task.task_id, "action_id": chosen_cand.action_id},
                    )
                    if len(scored) >= 2:
                        alt_score = scored[-1]
                        alt_cand = next(
                            c for c in ctx.candidate_actions if c.action_id == alt_score.action_id
                        )
                        alt_features = extract_action_features(
                            self.turn_number, ctx, task, alt_cand
                        )
                        await self.jev.record_jev_trajectory_async(
                            sample_type="ACTION_CLASSIFICATION",
                            state_features=alt_features,
                            jev_prediction=alt_score.model_dump(),
                            final_adopted_label=alt_score.label,
                            was_overridden_by_human_or_superior=False,
                            meta={"task_id": task.task_id, "action_id": alt_cand.action_id, "contrastive": True},
                        )

                    # 2. 通过真实 EXP-06 MCP Server 执行单步原子动作
                    exec_res = await self.mcp.execute_unit_step(
                        unit_id=uid,
                        action_type=chosen_cand.action_type,
                        target_x=chosen_cand.target_x,
                        target_y=chosen_cand.target_y,
                    )

                    # 3. Jev 动作后增量视野中断判别并落盘特征样本
                    esc_decision = await self.jev.evaluate_step_escalation(
                        before_context=ctx,
                        exec_result=exec_res,
                        task_package=task,
                        redlines=self.active_directive.redline_constraints,
                    )
                    esc_features = extract_escalation_features(
                        self.turn_number,
                        ctx,
                        exec_res,
                        task,
                        self.active_directive.redline_constraints,
                    )
                    await self.jev.record_jev_trajectory_async(
                        sample_type="ESCALATION_CLASSIFICATION",
                        state_features=esc_features,
                        jev_prediction=esc_decision.model_dump(),
                        final_adopted_label=esc_decision.escalation_level,
                        was_overridden_by_human_or_superior=False,
                        meta={"task_id": task.task_id, "reason_tag": esc_decision.reason_tag},
                    )

                    self.execution_logs.append(
                        {
                            "task_id": task.task_id,
                            "unit_id": uid,
                            "action_type": chosen_cand.action_type,
                            "target": [chosen_cand.target_x, chosen_cand.target_y],
                            "jev_action_label": best_score.label,
                            "escalation_level": esc_decision.escalation_level,
                            "escalation_reason": esc_decision.reason_tag,
                        }
                    )

                    await self.emit(
                        StepExecutedEvent(
                            unit_id=uid,
                            scored_actions=scored[:3],
                            result=exec_res,
                            escalation_level=esc_decision.escalation_level,
                            escalation_reason=esc_decision.reason_tag,
                            trajectory_count=self.jev.recorded_count,
                        )
                    )
                    latest_ov = await self.mcp.get_turn_overview()
                    await self.emit(
                        TurnStateUpdatedEvent(
                            overview=latest_ov,
                            phase=self.phase,
                            runtime_mode=self.mcp.mode,
                        )
                    )

                    # 4. 中断分流：LEVEL 1（参谋长局部微调） vs LEVEL 2（冻结退回顾问请示玩家）
                    if esc_decision.escalation_level in (1, 2):
                        if remaining_ids:
                            sliced = task.model_copy(
                                update={"unit_ids": list(remaining_ids)}
                            )
                            self.suspended_tasks = [sliced, *list(self.task_queue)]
                        else:
                            self.suspended_tasks = list(self.task_queue)
                        self.task_queue.clear()

                        report = EscalationReport(
                            escalation_id=f"ESC_{uuid.uuid4().hex[:8].upper()}",
                            level=esc_decision.escalation_level,
                            source_task_id=task.task_id,
                            trigger_unit_id=uid,
                            trigger_reason_tag=esc_decision.reason_tag,  # type: ignore[arg-type]
                            delta_observation=exec_res.delta_observation,
                            situation_brief=esc_decision.rationale_short,
                            options_for_superior=(
                                [
                                    "A. 立即收缩防线依托北河丘陵固守，暂停东进并集中火力清剿侧翼残敌",
                                    "B. 维持原东进探路计划，强行渗透匈奴侧翼",
                                ]
                                if esc_decision.escalation_level == 2
                                else [
                                    "A. 参谋长调遣邻近满血矛兵103前出补刀收割残血蛮族",
                                    "B. 忽略残敌直接就地驻扎",
                                ]
                            ),
                        )
                        self.active_escalation = report
                        self.last_escalation_features = esc_features

                        should_pause = await self._handle_escalation(report)
                        interrupted = True
                        if should_pause:
                            return
                        break

                    if exec_res.unit_after is None or exec_res.unit_after.moves_left <= 0:
                        break
                if interrupted:
                    break

        if not self._abort_requested and not self.task_queue:
            await self._finalize_turn()

    async def _handle_escalation(self, report: EscalationReport) -> bool:
        """处理下级上报单：LEVEL 1 由参谋长内部闭环返回 False；LEVEL 2 退回顾问请示玩家返回 True。"""
        self._set_phase(SessionPhaseEnum.ESCALATED_TO_CHIEF)
        await self._emit_stream_text(
            "TIER2_CHIEF",
            "THINKING",
            f"[{self.model_routes.tier2_chief}] 接到 LEVEL {report.level} 上报 ({report.trigger_reason_tag})，研判是否可战术内部消化。",
            chunk_size=14,
        )

        call_tag = (
            "CHIEF_EVAL_ESCALATION_L2"
            if report.level == 2
            else "CHIEF_EVAL_ESCALATION_L1"
        )
        decision, _ = await self._mock_llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag=call_tag,
            system_prompt="",
            user_prompt=report.model_dump_json(),
            response_model=ChiefEscalationDecisionOutput,
        )
        await self._emit_stream_text(
            "TIER2_CHIEF", "TEXT", decision.chief_assessment + "\n", chunk_size=14
        )

        if decision.can_resolve_tactically and decision.replanned_tasks:
            # LEVEL 1 战术微调：过滤可行动单位并直接跳回 EXECUTING，不打扰玩家
            ov = await self.mcp.get_turn_overview()
            actable = {u.unit_id for u in ov.our_units if u.can_act and u.moves_left > 0}
            filtered = []
            for t in sorted(decision.replanned_tasks, key=lambda x: x.execution_order):
                valid_ids = [u for u in t.unit_ids if u in actable]
                if valid_ids:
                    filtered.append(t.model_copy(update={"unit_ids": valid_ids}))
            self.task_queue = deque(filtered)
            self.suspended_tasks.clear()
            self.active_escalation = None
            self._set_phase(SessionPhaseEnum.EXECUTING)
            await self.emit(
                TaskQueueUpdatedEvent(
                    tasks=list(self.task_queue),
                    active_task_id=filtered[0].task_id if filtered else None,
                    note="参谋长 LEVEL 1 局部改派完成（未打扰玩家）",
                )
            )
            return False

        # LEVEL 2 战略警报：逐级退回顾问并弹窗请示玩家
        self._set_phase(SessionPhaseEnum.ESCALATED_TO_ADVISOR)
        await self._emit_stream_text(
            "TIER1_ADVISOR",
            "THINKING",
            f"[{self.model_routes.tier1_advisor}] 收到参谋长转呈 LEVEL 2 战略警报，正在拟定紧急请示简报与备选方案。",
            chunk_size=14,
        )
        alert_out, _ = await self._mock_llm.generate_structured(
            role_tier="TIER1_ADVISOR",
            call_tag="ADVISOR_ESCALATION_ALERT",
            system_prompt="",
            user_prompt=report.model_dump_json(),
            response_model=AdvisorEscalationAlertOutput,
        )
        await self._emit_stream_text(
            "TIER1_ADVISOR", "TEXT", alert_out.urgent_brief_to_player + "\n", chunk_size=14
        )

        await self.emit(
            EscalationAlertEvent(
                report=report,
                advisor_urgent_brief=alert_out.urgent_brief_to_player,
                recommended_option_index=alert_out.recommended_option_index,
            )
        )
        latest_ov = await self.mcp.get_turn_overview()
        await self.emit(
            TurnStateUpdatedEvent(
                overview=latest_ov, phase=self.phase, runtime_mode=self.mcp.mode
            )
        )
        return True

    async def _cmd_resolve_escalation(self, cmd: ResolveEscalationCommand) -> None:
        """玩家在 TUI 对 LEVEL 2 警报拍板：记录人类修正样本 -> 顾问签发修订文书 -> 参谋长重拆单恢复执行。"""
        if self.active_escalation is None:
            await self.emit(
                SystemNoticeEvent(level="WARN", message="当前没有待决断的 LEVEL 2 警报。")
            )
            return

        # 落盘人类/上级决断修正轨迹（验证 §5.3 was_overridden_by_human_or_superior=True）
        if self.last_escalation_features is not None:
            await self.jev.record_jev_trajectory_async(
                sample_type="ESCALATION_CLASSIFICATION",
                state_features=self.last_escalation_features,
                jev_prediction={
                    "escalation_level": self.active_escalation.level,
                    "reason_tag": self.active_escalation.trigger_reason_tag,
                    "confidence": 0.98,
                },
                final_adopted_label=2,
                was_overridden_by_human_or_superior=cmd.override_jev_label,
                meta={
                    "escalation_id": cmd.escalation_id,
                    "player_chosen_option": cmd.chosen_option,
                    "custom_instruction": cmd.custom_instruction or "",
                },
            )

        self._set_phase(SessionPhaseEnum.ADVISOR_DRAFTING)
        await self._emit_stream_text(
            "TIER1_ADVISOR",
            "TEXT",
            f"遵命！依据司令官决断「{cmd.chosen_option}」，签发修订版《工作文书》，指示主力收缩防线并肃清侧翼残敌。\n",
            chunk_size=14,
        )
        revised, _ = await self._mock_llm.generate_structured(
            role_tier="TIER1_ADVISOR",
            call_tag="ADVISOR_REVISED_DIRECTIVE",
            system_prompt="",
            user_prompt=cmd.chosen_option,
            response_model=AdvisorProposalOutput,
        )
        self.active_directive = revised.work_directive
        self.draft_next_handoff = revised.next_handoff_draft
        await self.emit(
            DirectiveDraftReadyEvent(
                directive_draft=revised.work_directive,
                handoff_draft=revised.next_handoff_draft,
                advisor_brief=revised.advisor_brief_to_player,
            )
        )

        # 参谋长仅对剩余可行动单位 [102, 103] 重新拆单
        self._set_phase(SessionPhaseEnum.CHIEF_DISPATCHING)
        re_dispatch, _ = await self._mock_llm.generate_structured(
            role_tier="TIER2_CHIEF",
            call_tag="CHIEF_REVISED_DISPATCH",
            system_prompt="",
            user_prompt=revised.work_directive.model_dump_json(),
            response_model=ChiefDispatchOutput,
        )
        await self._emit_stream_text(
            "TIER2_CHIEF", "TEXT", re_dispatch.dispatch_summary + "\n", chunk_size=14
        )

        ov = await self.mcp.get_turn_overview()
        actable = {u.unit_id for u in ov.our_units if u.can_act and u.moves_left > 0}
        filtered = []
        for t in sorted(re_dispatch.tasks, key=lambda x: x.execution_order):
            valid_ids = [u for u in t.unit_ids if u in actable]
            if valid_ids:
                filtered.append(t.model_copy(update={"unit_ids": valid_ids}))

        self.task_queue = deque(filtered)
        self.suspended_tasks.clear()
        self.active_escalation = None
        self._set_phase(SessionPhaseEnum.EXECUTING)
        await self.emit(
            TaskQueueUpdatedEvent(
                tasks=list(self.task_queue),
                active_task_id=filtered[0].task_id if filtered else None,
                note="已按修订文书对剩余可行动部队重排任务包",
            )
        )
        await self._run_execution_loop()

    async def _finalize_turn(self) -> None:
        """整回合执行完毕：修订并落盘《下一轮交接材料》，通知 TUI 进入 TURN_COMPLETED。"""
        ov = await self.mcp.get_turn_overview()
        base = self.draft_next_handoff or self.prev_handoff
        final_handoff = base.model_copy(
            update={
                "from_turn": ov.turn_number,
                "last_turn_execution_summary": (
                    f"第 {ov.turn_number} 回合执行完毕：共经真实 MCP Server 执行 {len(self.execution_logs)} 步原子动作，"
                    f"完成 LEVEL 2 伏击紧急收缩与 LEVEL 1 侧翼残敌收割，累计采集 {self.jev.recorded_count} 条 Jev 轨迹样本。"
                ),
            }
        )
        self.final_handoff = final_handoff
        handoff_path = self.handoff_dir / f"turn_{ov.turn_number}_handoff.json"
        await asyncio.to_thread(
            handoff_path.write_text,
            json.dumps(final_handoff.model_dump(), ensure_ascii=False, indent=2),
            "utf-8",
        )
        self._set_phase(SessionPhaseEnum.TURN_COMPLETED)
        await self.emit(
            TurnStateUpdatedEvent(
                overview=ov, phase=self.phase, runtime_mode=self.mcp.mode
            )
        )
        await self.emit(
            TurnCompletedEvent(
                turn_number=ov.turn_number,
                final_handoff=final_handoff,
                handoff_path=str(handoff_path.resolve()),
                trajectory_path=str(self.jev.trajectory_path.resolve()),
                trajectory_count=self.jev.recorded_count,
            )
        )

    async def _cmd_switch_model(self, cmd: SwitchTierModelCommand) -> None:
        """动态热切换三层指挥链底层模型路由。"""
        if cmd.tier == "TIER1_ADVISOR":
            self.model_routes.tier1_advisor = cmd.provider_and_model
        elif cmd.tier == "TIER2_CHIEF":
            self.model_routes.tier2_chief = cmd.provider_and_model
        else:
            self.model_routes.tier3_executor = cmd.provider_and_model
        record = f"{cmd.tier} -> {cmd.provider_and_model}"
        self.model_routes.history.append(record)
        await self.emit(
            SystemNoticeEvent(level="INFO", message=f"已热切换模型路由：{record}")
        )

    async def _cmd_record_snapshot(self, cmd: RecordSnapshotCommand) -> None:
        """经真实 MCP Server 录制当前回合离线快照。"""
        path = await self.mcp.save_turn_snapshot(cmd.tag)
        self.last_snapshot_path = path
        await self.emit(
            SystemNoticeEvent(level="INFO", message=f"快照已录制保存：{Path(path).name}")
        )
