# -*- coding: utf-8 -*-
"""
模块名称：events.py
职责说明：
    严格对齐《03_接口设计说明书》§6 定义“编排引擎 ↔ Textual TUI 控制台”异步事件总线契约：
    1. OrchestratorToUIMessage（6 类下行事件）：推送回合态势、流式思考/文本增量、工作文书草案、
       参谋长任务包队列、单步 Jev 执行战报与 LEVEL 2 战略警报；
    2. UIToOrchestratorCommand（5 类上行指令）：同步游戏态势、玩家向顾问发言、批准工作文书、
       拍板处理突发军情警报、动态热切换各层级模型路由。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from ..exp05.schemas import (
    ActionExecutionResultDTO,
    EscalationReport,
    HandoffDocument,
    JevScoredActionDTO,
    SessionPhaseEnum,
    TaskPackage,
    TurnOverviewDTO,
    WorkDirective,
)


# =============================================================================
# 一、 编排引擎 -> Textual TUI 下行事件（对齐 §6.1）
# =============================================================================


@dataclass(slots=True)
class TurnStateUpdatedEvent:
    """刷新左栏战场态势与部队列表。"""

    overview: TurnOverviewDTO
    phase: SessionPhaseEnum = SessionPhaseEnum.TURN_INIT
    runtime_mode: Literal["MOCK", "LIVE"] = "MOCK"


@dataclass(slots=True)
class AgentStreamChunkEvent:
    """实时流式追加到中栏（顾问对话）或右栏（参谋长/执行者日志）。"""

    tier: Literal["TIER1_ADVISOR", "TIER2_CHIEF", "TIER3_EXECUTOR"]
    chunk_type: Literal["THINKING", "TEXT"]
    content: str


@dataclass(slots=True)
class DirectiveDraftReadyEvent:
    """在中栏渲染《本回合工作文书》与《下轮交接材料》审批卡片，点亮审批按钮。"""

    directive_draft: WorkDirective
    handoff_draft: HandoffDocument
    advisor_brief: str = ""


@dataclass(slots=True)
class TaskQueueUpdatedEvent:
    """刷新右栏参谋长任务包队列与当前执行高亮。"""

    tasks: list[TaskPackage]
    active_task_id: str | None = None
    note: str = ""


@dataclass(slots=True)
class StepExecutedEvent:
    """在右栏打印单步 Jev 分类结果、游戏 MCP 执行反馈与落盘计数。"""

    unit_id: int
    scored_actions: list[JevScoredActionDTO]
    result: ActionExecutionResultDTO
    escalation_level: Literal[0, 1, 2] = 0
    escalation_reason: str = "NOMINAL_CONTINUE"
    trajectory_count: int = 0


@dataclass(slots=True)
class EscalationAlertEvent:
    """当发生 LEVEL 2 战略警报时，在中栏弹出高亮军情警报框并等待玩家决断。"""

    report: EscalationReport
    advisor_urgent_brief: str = ""
    recommended_option_index: int = 0


@dataclass(slots=True)
class TurnCompletedEvent:
    """整回合收尾通知，汇报交接材料路径与累计采集的 Jev 训练样本数。"""

    turn_number: int
    final_handoff: HandoffDocument
    handoff_path: str
    trajectory_path: str
    trajectory_count: int


@dataclass(slots=True)
class SystemNoticeEvent:
    """轻量状态栏/日志系统通知（如模型切换成功、快照已录制、已中止执行等）。"""

    level: Literal["INFO", "WARN", "ERROR"]
    message: str


OrchestratorToUIMessage = (
    TurnStateUpdatedEvent
    | AgentStreamChunkEvent
    | DirectiveDraftReadyEvent
    | TaskQueueUpdatedEvent
    | StepExecutedEvent
    | EscalationAlertEvent
    | TurnCompletedEvent
    | SystemNoticeEvent
)


# =============================================================================
# 二、 Textual TUI -> 编排引擎上行控制指令（对齐 §6.2）
# =============================================================================


@dataclass(slots=True)
class SyncTurnFromGameCommand:
    """主动从 MCP Server 拉取最新回合态势并启动顾问拟稿。"""

    auto_start_advisor: bool = True


@dataclass(slots=True)
class PlayerChatToAdvisorCommand:
    """玩家向顾问发送自然语言指令或文书修改意见。"""

    message: str


@dataclass(slots=True)
class ApproveWorkDirectiveCommand:
    """玩家确认批准《本回合工作文书》，启动参谋长拆单与执行环。"""

    edited_directive: WorkDirective | None = None


@dataclass(slots=True)
class ResolveEscalationCommand:
    """玩家对 LEVEL 2 突发军情做出决断，同时触发 Jev 人工修正轨迹样本落盘。"""

    escalation_id: str
    chosen_option: str
    custom_instruction: str | None = None
    override_jev_label: bool = True


@dataclass(slots=True)
class SwitchTierModelCommand:
    """动态热切换某层级的底层模型路由（如将参谋长从 agy 切为 zhipu:glm-5.4）。"""

    tier: Literal["TIER1_ADVISOR", "TIER2_CHIEF", "TIER3_EXECUTOR"]
    provider_and_model: str


@dataclass(slots=True)
class RecordSnapshotCommand:
    """触发 MCP Server 录制当前回合离线快照。"""

    tag: str = "tui_manual"


@dataclass(slots=True)
class AbortExecutionCommand:
    """玩家在 TUI 点击紧急中止执行按钮。"""

    reason: str = "玩家手动紧急中止"


UIToOrchestratorCommand = (
    SyncTurnFromGameCommand
    | PlayerChatToAdvisorCommand
    | ApproveWorkDirectiveCommand
    | ResolveEscalationCommand
    | SwitchTierModelCommand
    | RecordSnapshotCommand
    | AbortExecutionCommand
)


@dataclass(slots=True)
class ModelRouteTable:
    """三层指挥链当前生效的模型路由表，支持在 TUI 顶部状态栏热切换。"""

    tier1_advisor: str = "agy:gemini-pro"
    tier2_chief: str = "zhipu:glm-5.4"
    tier3_executor: str = "zhipu:glm-5.3-flash(thinking:disabled)"
    history: list[str] = field(default_factory=list)
