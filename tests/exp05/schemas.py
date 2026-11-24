# -*- coding: utf-8 -*-
"""
模块名称：schemas.py
职责说明：
    严格按照《02_软件总体设计说明书》与《03_接口设计说明书》定义 EXP-05 所需的全部强类型数据契约（Pydantic v2）：
    1. 战场态势、局部六边形网格、候选动作与增量揭盲视野 DTO（§2.1 ~ §2.3）；
    2. 三层指挥链标准化电子公文：跨回合交接材料、本回合工作文书、参谋长任务部署单、下级主动上报单（§4.1 ~ §4.4）；
    3. Jev 决策分类判别与异常中断分级 DTO（§5.1 ~ §5.2）；
    4. 状态机阶段枚举与 LLM 网关辅助包装 Schema。
"""

from __future__ import annotations

from enum import Enum
from typing import Any, Literal
from pydantic import BaseModel, Field


# =============================================================================
# 一、 编排器状态机阶段枚举（对齐《02_软件总体设计说明书》模块 4）
# =============================================================================


class SessionPhaseEnum(str, Enum):
    """定义单回合内三层指挥链编排状态机的全部合法阶段节点。"""

    TURN_INIT = "TURN_INIT"
    ADVISOR_DRAFTING = "ADVISOR_DRAFTING"
    WAITING_PLAYER_APPROVAL = "WAITING_PLAYER_APPROVAL"
    CHIEF_DISPATCHING = "CHIEF_DISPATCHING"
    EXECUTING = "EXECUTING"
    ESCALATED_TO_CHIEF = "ESCALATED_TO_CHIEF"
    ESCALATED_TO_ADVISOR = "ESCALATED_TO_ADVISOR"
    TURN_COMPLETED = "TURN_COMPLETED"


# =============================================================================
# 二、 战场态势、局部网格与动作执行结算 DTO（对齐《03_接口设计说明书》§2）
# =============================================================================


class UnitSummaryDTO(BaseModel):
    """己方存活单位摘要数据结构。"""

    unit_id: int
    name: str
    unit_type: str
    domain: Literal["LAND", "AIR", "SEA"] = "LAND"
    x: int
    y: int
    hp: int = Field(ge=0, le=100)
    max_hp: int = 100
    moves_left: float = Field(ge=0.0)
    max_moves: float = Field(ge=0.0)
    combat_str: int = Field(ge=0)
    ranged_str: int = Field(ge=0)
    range: int = Field(ge=0)
    is_fortified: bool = False
    can_act: bool


class EnemyUnitDTO(BaseModel):
    """当前玩家视野实时可见（IsVisible == True）的敌方或蛮族单位数据结构。"""

    enemy_id: str
    owner_id: int = 63
    owner_name: str
    is_barbarian: bool
    unit_type: str
    x: int
    y: int
    hp: int = Field(ge=0, le=100)
    combat_str: int = Field(ge=0)
    ranged_str: int = Field(ge=0)
    enemy_killed: bool = False


class CitySummaryDTO(BaseModel):
    """己方城市摘要数据结构。"""

    city_id: int
    name: str
    x: int
    y: int
    pop: int
    hp: int
    current_production: str = "UNIT_COMPOSITE_BOWMAN"
    turns_left: int = 2


class EnemyCityDTO(BaseModel):
    """已探索或可见的敌方/城邦城市摘要数据结构。"""

    city_id: str
    owner_name: str
    name: str
    x: int
    y: int
    hp: int
    in_fog: bool = True


class TurnOverviewDTO(BaseModel):
    """全局可见态势快照（对应 MCP Tool: get_turn_overview 返回值）。"""

    turn_number: int
    player_civ: str
    yields: dict[str, Any]
    our_units: list[UnitSummaryDTO]
    visible_enemies: list[EnemyUnitDTO]
    our_cities: list[CitySummaryDTO]
    visible_enemy_cities: list[EnemyCityDTO] = Field(default_factory=list)


class TileDTO(BaseModel):
    """单位周边局部六边形地块信息（严格仅含 VISIBLE 与 REVEALED_FOG，不含黑雾）。"""

    x: int
    y: int
    distance: int
    visibility: Literal["VISIBLE", "REVEALED_FOG"]
    terrain: str
    feature: str | None = None
    is_hills: bool = False
    has_river: bool = False
    improvement: str | None = None
    friendly_unit_id: int | None = None
    enemy_unit: EnemyUnitDTO | None = None
    city: dict[str, Any] | None = None


ActionTypeLiteral = Literal[
    "MOVE_STEP",
    "MELEE_ATTACK",
    "RANGE_ATTACK",
    "AIR_STRIKE",
    "SETUP_FOR_RANGED",
    "FORTIFY",
    "HEAL",
    "SKIP_TURN",
]


class CandidateActionDTO(BaseModel):
    """由底层规则/引擎枚举出的单步合法候选动作。"""

    action_id: str
    action_type: ActionTypeLiteral
    target_x: int
    target_y: int
    estimated_cost_moves: float
    combat_preview: dict[str, Any] | None = None
    note: str = ""


class UnitTacticalContextDTO(BaseModel):
    """指定单位局部战场网格与合法候选动作集合（对应 get_unit_context_and_candidates）。"""

    unit: UnitSummaryDTO
    surrounding_tiles: list[TileDTO]
    candidate_actions: list[CandidateActionDTO]


class DeltaObservationDTO(BaseModel):
    """单步动作结算后的增量视野数据，核心用于识别新揭开迷雾暴露的敌军。"""

    newly_revealed_tiles_count: int = 0
    newly_spotted_enemies: list[EnemyUnitDTO] = Field(default_factory=list)
    target_enemy_after: EnemyUnitDTO | None = None


class ActionExecutionResultDTO(BaseModel):
    """单步动作执行结算返回结构（对应 execute_unit_step）。"""

    executed: bool
    error_reason: str | None = None
    unit_died: bool = False
    unit_after: UnitSummaryDTO | None = None
    delta_observation: DeltaObservationDTO


# =============================================================================
# 三、 三层指挥链电子公文流转与中断上报 Schema（对齐《03_接口设计说明书》§4）
# =============================================================================


class ActiveOperationDTO(BaseModel):
    """跨回合持续作战或建设行动条目。"""

    op_name: str
    assigned_unit_ids: list[int]
    status: str
    next_turn_focus: str


class HandoffDocument(BaseModel):
    """跨回合交接材料（§4.1），连接上一回合复盘与下一回合战略延续。"""

    from_turn: int
    long_term_strategy: str
    active_operations: list[ActiveOperationDTO]
    unresolved_threats: list[str]
    last_turn_execution_summary: str


class TheaterDirectiveDTO(BaseModel):
    """《本回合工作文书》中的分战区/方向具体指示条目。"""

    theater_id: str
    priority: Literal["CRITICAL", "HIGH", "NORMAL"]
    involved_unit_ids: list[int]
    directive_text: str


class WorkDirective(BaseModel):
    """顾问拟定并由玩家签发生效的《本回合工作文书》（§4.2）。"""

    turn_number: int
    commander_intent_summary: str
    theater_directives: list[TheaterDirectiveDTO]
    redline_constraints: list[str] = Field(min_length=1)


TacticalPostureLiteral = Literal[
    "ADVANCE",
    "FOCUS_FIRE",
    "HOLD_DEFEND",
    "RETREAT_HEAL",
    "RECON_CAUTIOUS",
]

ExecutorTypeLiteral = Literal[
    "COMBAT_UNIT_EXECUTOR",
    "SCOUT_EXECUTOR",
    "AIR_STRIKE_EXECUTOR",
]


class TargetAreaDTO(BaseModel):
    """参谋长任务部署单中的目标区域或目标敌军标识。"""

    target_x: int
    target_y: int
    target_enemy_id: str | None = None


class TaskPackage(BaseModel):
    """参谋长（Tier 2）拆解下发给执行者（Tier 3）的有序任务部署单（§4.3）。"""

    task_id: str
    execution_order: int = Field(ge=1)
    executor_type: ExecutorTypeLiteral
    unit_ids: list[int] = Field(min_length=1)
    tactical_posture: TacticalPostureLiteral
    target_area: TargetAreaDTO
    step_instruction: str
    abort_on_new_enemy_count: int = Field(default=2, ge=1)


TriggerReasonTagLiteral = Literal[
    "FOG_AMBUSH_DETECTED",
    "PATH_BLOCKED_1UPT",
    "TARGET_SURVIVED_LOW_HP",
    "REDLINE_RISK_HIGH",
    "ACTION_INVALID",
]


class EscalationReport(BaseModel):
    """执行层遇险或遇阻时逆向上抛的《下级主动上报单》（§4.4）。"""

    escalation_id: str
    level: Literal[1, 2]
    source_task_id: str
    trigger_unit_id: int
    trigger_reason_tag: TriggerReasonTagLiteral
    delta_observation: DeltaObservationDTO
    situation_brief: str
    options_for_superior: list[str] = Field(min_length=2)


# =============================================================================
# 四、 Jev 决策分类与异常中断判别 DTO（对齐《03_接口设计说明书》§5）
# =============================================================================


class JevScoredActionDTO(BaseModel):
    """Jev 对单个候选动作的四分类战术评级结果（§5.1）。"""

    action_id: str
    label: Literal["OPTIMAL", "ACCEPTABLE", "HIGH_RISK", "VIOLATES_ORDER"]
    confidence: float = Field(ge=0.0, le=1.0)
    rationale_short: str


class JevEscalationDecisionDTO(BaseModel):
    """Jev 对单步动作后增量态势的中断级别判别结果（§5.2）。"""

    escalation_level: Literal[0, 1, 2]
    reason_tag: str
    confidence: float = Field(ge=0.0, le=1.0)
    rationale_short: str = ""


# =============================================================================
# 五、 各层级大模型结构化输出包装契约（供 LLM 网关强校验解析）
# =============================================================================


class AdvisorProposalOutput(BaseModel):
    """顾问（Tier 1）在回合初或响应战略警报修正时输出的结构化文书包。"""

    advisor_brief_to_player: str
    work_directive: WorkDirective
    next_handoff_draft: HandoffDocument


class AdvisorEscalationAlertOutput(BaseModel):
    """顾问（Tier 1）接收到参谋长转呈的 LEVEL 2 战略警报后向玩家呈报的请示包。"""

    urgent_brief_to_player: str
    recommended_option_index: int = Field(ge=0)
    options_for_player: list[str] = Field(min_length=2)


class ChiefDispatchOutput(BaseModel):
    """参谋长（Tier 2）拆解《本回合工作文书》输出的有序任务部署列表。"""

    dispatch_summary: str
    tasks: list[TaskPackage] = Field(min_length=1)


class ChiefEscalationDecisionOutput(BaseModel):
    """参谋长（Tier 2）处理下级上报单时的分级处置输出（局部战术微调 vs 转呈顾问）。"""

    can_resolve_tactically: bool
    chief_assessment: str
    replanned_tasks: list[TaskPackage] = Field(default_factory=list)
