# -*- coding: utf-8 -*-
"""
模块名称：tui_app.py
职责说明：
    实现《02_软件总体设计说明书》模块 6 定义的三栏异步军事指挥台（Civ5CommandTuiApp）：
    - 顶部状态栏（HeaderBar）：显示运行模式（MOCK/LIVE）、当前回合号、MCP 连接状态、
      60Hz 事件循环实时 FPS / max_lag_ms 遥测，以及参谋长模型热切换按钮；
    - 左栏（TacticalOverviewPane）：我方待命部队面板、可见敌军警报面板，以及【同步游戏态势】【录制快照】按钮；
    - 中栏（AdvisorCommandPane）：顾问流式对话 RichLog、LEVEL 2 战略警报高亮横幅、玩家自然语言输入框、
      《本回合工作文书》预览卡片，以及【批准并下发参谋长】【要求顾问修改】【紧急中止】【拍板方案A】按钮；
    - 右栏（ExecutionMonitorPane）：参谋长 TaskPackage 队列面板 + 执行者/Jev 单步打分与轨迹落盘监控流。

    既支持直接终端交互启动（`python Civ5AgentBridge/tests/exp07/tui_app.py`），
    也支持由 `run_exp07_acceptance.py` 经 Textual Pilot 进行 60fps 并发压测与端到端自动验收。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path
import sys
import time
from typing import Any

# 允许直接脚本启动
if __package__ in (None, ""):
    _repo_root = Path(__file__).resolve().parents[3]
    if str(_repo_root) not in sys.path:
        sys.path.insert(0, str(_repo_root))
    from Civ5AgentBridge.tests.exp05.schemas import SessionPhaseEnum
    from Civ5AgentBridge.tests.exp06.bridge_service import EXP05_DEFAULT_SNAPSHOT
    from Civ5AgentBridge.tests.exp07.events import (
        AbortExecutionCommand,
        AgentStreamChunkEvent,
        ApproveWorkDirectiveCommand,
        DirectiveDraftReadyEvent,
        EscalationAlertEvent,
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
    )
    from Civ5AgentBridge.tests.exp07.jev_coldstart import HybridColdStartJevService
    from Civ5AgentBridge.tests.exp07.mcp_game_client import Civ5McpSessionAdapter
    from Civ5AgentBridge.tests.exp07.tui_orchestrator import TuiCommandController
else:
    from ..exp05.schemas import SessionPhaseEnum
    from ..exp06.bridge_service import EXP05_DEFAULT_SNAPSHOT
    from .events import (
        AbortExecutionCommand,
        AgentStreamChunkEvent,
        ApproveWorkDirectiveCommand,
        DirectiveDraftReadyEvent,
        EscalationAlertEvent,
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
    )
    from .jev_coldstart import HybridColdStartJevService
    from .mcp_game_client import Civ5McpSessionAdapter
    from .tui_orchestrator import TuiCommandController

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, Footer, Input, RichLog, Static

DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parent / "output"


@dataclass
class FrameLoopTelemetry:
    """60Hz 事件循环帧心跳采样器：量化验证后台并发期间 TUI 是否维持 60fps 零假死。"""

    target_interval_ms: float = 1000.0 / 60.0
    tick_intervals_ms: list[float] = field(default_factory=list)
    _last_tick_ts: float | None = None

    def record_tick(self, now: float | None = None) -> None:
        ts = now if now is not None else time.perf_counter()
        if self._last_tick_ts is not None:
            dt_ms = (ts - self._last_tick_ts) * 1000.0
            self.tick_intervals_ms.append(dt_ms)
        self._last_tick_ts = ts

    def summarize(self) -> dict[str, Any]:
        if not self.tick_intervals_ms:
            return {
                "samples": 0,
                "effective_fps": 0.0,
                "avg_tick_ms": 0.0,
                "p50_tick_ms": 0.0,
                "p95_tick_ms": 0.0,
                "max_tick_ms": 0.0,
                "max_loop_lag_ms": 0.0,
                "jank_frames_over_50ms": 0,
            }
        ordered = sorted(self.tick_intervals_ms)
        n = len(ordered)
        avg_ms = sum(ordered) / n
        p50 = ordered[int(0.50 * (n - 1))]
        p95 = ordered[int(0.95 * (n - 1))]
        max_ms = ordered[-1]
        jank_cnt = sum(1 for v in ordered if v > 50.0)
        return {
            "samples": n,
            "effective_fps": round(min(60.0, 1000.0 / max(1.0, avg_ms)), 2),
            "avg_tick_ms": round(avg_ms, 2),
            "p50_tick_ms": round(p50, 2),
            "p95_tick_ms": round(p95, 2),
            "max_tick_ms": round(max_ms, 2),
            "max_loop_lag_ms": round(max(0.0, max_ms - self.target_interval_ms), 2),
            "jank_frames_over_50ms": jank_cnt,
        }


class Civ5CommandTuiApp(App[None]):
    """《文明5》三层智能体指挥控制台（Textual 8.x 异步三栏军事指挥台）。"""

    TITLE = "Civ5 Agent Command — 三层智能体指挥控制台 (EXP-07)"

    CSS = """
    Screen {
        layout: vertical;
        background: #0f1419;
        color: #e6edf3;
    }
    #header-bar {
        height: 3;
        padding: 0 1;
        background: #161f2c;
        border-bottom: solid #2f81f7;
        align: left middle;
    }
    #status-label {
        width: 1fr;
        content-align: left middle;
        color: #79c0ff;
        text-style: bold;
    }
    #main-columns {
        height: 1fr;
    }
    .pane {
        border: solid #30363d;
        padding: 0 1;
        margin: 0;
    }
    #left-pane {
        width: 30%;
    }
    #center-pane {
        width: 38%;
    }
    #right-pane {
        width: 32%;
    }
    .pane-title {
        height: 1;
        color: #ffa657;
        text-style: bold;
        background: #161b22;
        padding: 0 1;
    }
    #units-panel {
        height: 1fr;
        overflow-y: auto;
        padding: 0 1;
    }
    #enemies-panel {
        height: 10;
        border-top: dashed #da3633;
        overflow-y: auto;
        padding: 0 1;
    }
    #left-actions {
        height: 3;
        align: center middle;
    }
    #advisor-log {
        height: 1fr;
        border: solid #21262d;
        background: #0d1117;
    }
    #escalation-banner {
        height: auto;
        display: none;
        background: #490202;
        color: #ffdcd7;
        border: heavy #f85149;
        padding: 0 1;
    }
    #escalation-banner.visible {
        display: block;
    }
    #directive-card {
        height: 10;
        border: solid #238636;
        background: #0d1c14;
        overflow-y: auto;
        padding: 0 1;
    }
    #chat-row {
        height: 3;
    }
    #player-input {
        width: 1fr;
    }
    #center-actions {
        height: 3;
        align: left middle;
    }
    #task-queue-panel {
        height: 10;
        border: solid #388bfd;
        background: #0d1826;
        overflow-y: auto;
        padding: 0 1;
    }
    #execution-log {
        height: 1fr;
        border: solid #21262d;
        background: #0d1117;
    }
    Button {
        margin: 0 1 0 0;
        min-width: 10;
    }
    """

    def __init__(
        self,
        output_dir: Path = DEFAULT_OUTPUT_DIR,
        snapshot_path: Path = EXP05_DEFAULT_SNAPSHOT,
        stream_chunk_delay_sec: float = 0.012,
        mcp_poll_delay_sec: float = 0.08,
    ) -> None:
        super().__init__()
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.trajectory_path = self.output_dir / "jev_trajectories.jsonl"
        if self.trajectory_path.exists():
            self.trajectory_path.unlink()

        self.mcp_client = Civ5McpSessionAdapter(
            mode="MOCK",
            snapshot_path=snapshot_path,
            snapshots_dir=self.output_dir / "snapshots",
            simulated_poll_delay_sec=mcp_poll_delay_sec,
        )
        self.jev_service = HybridColdStartJevService(
            trajectory_path=self.trajectory_path,
            backend_mode="hybrid-rule-flash-coldstart",
        )
        self.controller = TuiCommandController(
            mcp_client=self.mcp_client,
            jev_service=self.jev_service,
            output_dir=self.output_dir,
            emit_event=self._on_orchestrator_event,
            stream_chunk_delay_sec=stream_chunk_delay_sec,
        )

        self.telemetry = FrameLoopTelemetry()
        self.mcp_tools_discovered: list[str] = []
        self._chief_model_toggle_idx: int = 0
        self._chief_model_cycle = [
            "zhipu:glm-5.4",
            "zhipu:glm-5.3(thinking:disabled)",
            "agy:gemini-pro(effort=low)",
        ]
        self._pending_escalation_id: str | None = None
        self._stream_line_buffers: dict[str, str] = {}
        self.ui_events_received: int = 0
        self.turn_completed_event: TurnCompletedEvent | None = None
        self._active_worker_task: asyncio.Task[None] | None = None
        self.button_handler_latencies_ms: dict[str, float] = {}

    def compose(self) -> ComposeResult:
        with Horizontal(id="header-bar"):
            yield Static(
                "Civ5 Agent Command | 模式: MOCK | MCP: 连接中... | 回合: -- | FPS: --",
                id="status-label",
            )
            yield Button("切参谋模型", id="btn-switch-chief-model", variant="primary")

        with Horizontal(id="main-columns"):
            with Vertical(id="left-pane", classes="pane"):
                yield Static("【左栏】战场态势与我方部队", classes="pane-title")
                yield Static("等待同步游戏态势...", id="units-panel")
                yield Static("【可见敌军警报】暂无", id="enemies-panel")
                with Horizontal(id="left-actions"):
                    yield Button("同步态势", id="btn-sync", variant="success")
                    yield Button("录制快照", id="btn-snapshot", variant="default")

            with Vertical(id="center-pane", classes="pane"):
                yield Static("【中栏】顾问会议室与公文签发台 (Tier 1)", classes="pane-title")
                yield RichLog(id="advisor-log", highlight=True, markup=True, wrap=True)
                yield Static("", id="escalation-banner")
                yield Static("《本回合工作文书》待顾问拟稿...", id="directive-card")
                with Horizontal(id="chat-row"):
                    yield Input(placeholder="向顾问下达修改意见...", id="player-input")
                    yield Button("发送", id="btn-send-chat", variant="primary")
                with Horizontal(id="center-actions"):
                    yield Button("批准下发", id="btn-approve", variant="success", disabled=True)
                    yield Button("拍板收缩", id="btn-resolve-l2", variant="warning", disabled=True)
                    yield Button("紧急中止", id="btn-abort", variant="error")

            with Vertical(id="right-pane", classes="pane"):
                yield Static("【右栏】参谋部队列与执行监控流 (Tier 2/3 + Jev)", classes="pane-title")
                yield Static("参谋长任务部署单队列：待命", id="task-queue-panel")
                yield RichLog(id="execution-log", highlight=True, markup=True, wrap=True)

        yield Footer()

    async def on_mount(self) -> None:
        """启动 60Hz 帧心跳采样器并异步连接 EXP-06 MCP Server，绝不阻塞首帧渲染。"""
        self.set_interval(1.0 / 60.0, self._on_frame_tick)
        self.set_interval(0.25, self._refresh_header_bar)
        self._launch_background_task(self._connect_mcp_async())

    async def on_unmount(self) -> None:
        """退出应用时干净回收后台任务与持久 MCP 子进程连接。"""
        if self._active_worker_task and not self._active_worker_task.done():
            self._active_worker_task.cancel()
        await self.mcp_client.close()

    def _on_frame_tick(self) -> None:
        self.telemetry.record_tick()

    def _refresh_header_bar(self) -> None:
        stats = self.telemetry.summarize()
        mcp_state = "已连接(EXP-06)" if self.mcp_client.is_connected else "连接中..."
        text = (
            f"Civ5 Agent Command | {self.mcp_client.mode} | MCP:{mcp_state} | "
            f"T{self.controller.turn_number} [{self.controller.phase.value}] | "
            f"Tier2:{self.controller.model_routes.tier2_chief} | "
            f"FPS:{stats['effective_fps']:.1f} (max_lag:{stats['max_loop_lag_ms']:.1f}ms)"
        )
        self.query_one("#status-label", Static).update(text)

    def _launch_background_task(self, coro: Any) -> asyncio.Task[None]:
        """在 asyncio 事件循环上派生后台非阻塞协程并挂接异常可视化回调，防止后台静默失败。"""
        task = asyncio.create_task(coro)
        self._active_worker_task = task

        def _on_done(t: asyncio.Task[None]) -> None:
            if t.cancelled():
                return
            exc = t.exception()
            if exc is not None:
                try:
                    self.query_one("#execution-log", RichLog).write(
                        f"[bold red][WORKER ERROR][/bold red] {exc!r}"
                    )
                except Exception:
                    pass

        task.add_done_callback(_on_done)
        return task

    async def _connect_mcp_async(self) -> None:
        tools = await self.mcp_client.connect()
        self.mcp_tools_discovered = tools
        self.query_one("#execution-log", RichLog).write(
            f"[bold green][MCP][/bold green] 已通过 Stdio 连接 EXP-06 MCP Server，发现 {len(tools)} 个工具: {', '.join(tools)}"
        )
        self._refresh_header_bar()

    async def on_button_pressed(self, event: Button.Pressed) -> None:
        """全部按钮事件立即派发异步命令并返回，保持 UI 主线程零阻塞。"""
        t_handler = time.perf_counter()
        bid = event.button.id
        if bid == "btn-sync":
            self._launch_background_task(
                self.controller.handle_command(SyncTurnFromGameCommand(auto_start_advisor=True))
            )
        elif bid == "btn-snapshot":
            self._launch_background_task(
                self.controller.handle_command(RecordSnapshotCommand(tag="tui_capture"))
            )
        elif bid == "btn-send-chat":
            inp = self.query_one("#player-input", Input)
            msg = inp.value.strip()
            inp.value = ""
            if msg:
                self.query_one("#advisor-log", RichLog).write(
                    f"[bold cyan]【司令官】[/bold cyan]{msg}"
                )
                self._launch_background_task(
                    self.controller.handle_command(PlayerChatToAdvisorCommand(message=msg))
                )
        elif bid == "btn-approve":
            self.query_one("#btn-approve", Button).disabled = True
            self._launch_background_task(
                self.controller.handle_command(ApproveWorkDirectiveCommand())
            )
        elif bid == "btn-resolve-l2":
            esc_id = self._pending_escalation_id or "ESC_MANUAL"
            self.query_one("#btn-resolve-l2", Button).disabled = True
            self.query_one("#escalation-banner", Static).remove_class("visible")
            self._launch_background_task(
                self.controller.handle_command(
                    ResolveEscalationCommand(
                        escalation_id=esc_id,
                        chosen_option="A. 立即收缩防线依托北河丘陵固守，暂停东进并集中火力清剿侧翼残敌",
                        custom_instruction="优先保住侦察兵并肃清(14,17)残血蛮族",
                        override_jev_label=True,
                    )
                )
            )
        elif bid == "btn-abort":
            self._launch_background_task(
                self.controller.handle_command(AbortExecutionCommand())
            )
        elif bid == "btn-switch-chief-model":
            self._chief_model_toggle_idx = (self._chief_model_toggle_idx + 1) % len(
                self._chief_model_cycle
            )
            next_model = self._chief_model_cycle[self._chief_model_toggle_idx]
            self._launch_background_task(
                self.controller.handle_command(
                    SwitchTierModelCommand(
                        tier="TIER2_CHIEF", provider_and_model=next_model
                    )
                )
            )
        if bid:
            self.button_handler_latencies_ms[bid] = round(
                (time.perf_counter() - t_handler) * 1000.0, 3
            )

    async def _on_orchestrator_event(self, event: OrchestratorToUIMessage) -> None:
        """统一消费编排引擎推送的 8 类异步事件并更新三栏界面。"""
        self.ui_events_received += 1

        if isinstance(event, TurnStateUpdatedEvent):
            ov = event.overview
            unit_lines = [
                f"回合 T{ov.turn_number} | 文明: {ov.player_civ} | 金币:{ov.yields.get('gold',0)} (+{ov.yields.get('gold_per_turn',0)}) | 科研:+{ov.yields.get('science_per_turn',0)}",
                "─" * 34,
            ]
            for u in ov.our_units:
                act_tag = "待命" if u.can_act else "已动"
                unit_lines.append(
                    f"#{u.unit_id} {u.name} ({u.x},{u.y}) HP:{u.hp} MV:{u.moves_left:.1f} [{act_tag}]"
                )
            self.query_one("#units-panel", Static).update("\n".join(unit_lines))

            if ov.visible_enemies:
                enemy_lines = [f"【可见敌军 ({len(ov.visible_enemies)})】"]
                for e in ov.visible_enemies:
                    enemy_lines.append(
                        f"! {e.enemy_id} {e.owner_name} {e.unit_type} @({e.x},{e.y}) HP:{e.hp}"
                    )
                self.query_one("#enemies-panel", Static).update("\n".join(enemy_lines))
            else:
                self.query_one("#enemies-panel", Static).update("【可见敌军】当前视野无敌军")
            self._refresh_header_bar()

        elif isinstance(event, AgentStreamChunkEvent):
            buf_key = f"{event.tier}:{event.chunk_type}"
            buf = self._stream_line_buffers.get(buf_key, "") + event.content
            if "\n" in buf or len(buf) >= 36:
                target_log = (
                    "#advisor-log" if event.tier == "TIER1_ADVISOR" else "#execution-log"
                )
                prefix = (
                    "[dim italic][思考][/dim italic] "
                    if event.chunk_type == "THINKING"
                    else f"[bold yellow][{event.tier}][/bold yellow] "
                )
                self.query_one(target_log, RichLog).write(prefix + buf.strip())
                self._stream_line_buffers[buf_key] = ""
            else:
                self._stream_line_buffers[buf_key] = buf

        elif isinstance(event, DirectiveDraftReadyEvent):
            wd = event.directive_draft
            lines = [
                f"《第{wd.turn_number}回合工作文书》 {wd.commander_intent_summary}",
                f"战区指示({len(wd.theater_directives)}): "
                + "; ".join(f"{t.theater_id}:{t.involved_unit_ids}" for t in wd.theater_directives),
                f"红线约束({len(wd.redline_constraints)}): " + " | ".join(wd.redline_constraints[:2]),
            ]
            self.query_one("#directive-card", Static).update("\n".join(lines))
            if self.controller.phase == SessionPhaseEnum.WAITING_PLAYER_APPROVAL:
                self.query_one("#btn-approve", Button).disabled = False

        elif isinstance(event, TaskQueueUpdatedEvent):
            lines = [f"队列状态：{event.note}"]
            for t in event.tasks:
                mark = "▶" if t.task_id == event.active_task_id else "•"
                lines.append(
                    f"{mark} #{t.execution_order} {t.task_id} {t.unit_ids} [{t.tactical_posture}] -> ({t.target_area.target_x},{t.target_area.target_y})"
                )
            self.query_one("#task-queue-panel", Static).update("\n".join(lines))

        elif isinstance(event, StepExecutedEvent):
            top = event.scored_actions[0] if event.scored_actions else None
            top_desc = f"{top.action_id}:{top.label}({top.confidence:.2f})" if top else "N/A"
            u_after = event.result.unit_after
            pos = f"({u_after.x},{u_after.y})" if u_after else "(阵亡)"
            spotted = len(event.result.delta_observation.newly_spotted_enemies)
            self.query_one("#execution-log", RichLog).write(
                f"[bold green][STEP][/bold green] U#{event.unit_id}->{pos} | "
                f"Jev={top_desc} | 新暴露敌军={spotted} | "
                f"中断=L{event.escalation_level}({event.escalation_reason}) | 轨迹#{event.trajectory_count}"
            )

        elif isinstance(event, EscalationAlertEvent):
            self._pending_escalation_id = event.report.escalation_id
            banner = self.query_one("#escalation-banner", Static)
            banner.update(
                f"🚨 [LEVEL 2 战略警报 {event.report.escalation_id}] {event.report.trigger_reason_tag}\n"
                f"{event.advisor_urgent_brief}\n"
                f"建议方案: {event.report.options_for_superior[event.recommended_option_index]}"
            )
            banner.add_class("visible")
            self.query_one("#btn-resolve-l2", Button).disabled = False

        elif isinstance(event, TurnCompletedEvent):
            self.turn_completed_event = event
            self.query_one("#execution-log", RichLog).write(
                f"[bold cyan][DONE][/bold cyan] 第 {event.turn_number} 回合完成！交接文书已落盘，"
                f"累计 Jev 轨迹 {event.trajectory_count} 条。"
            )
            self._refresh_header_bar()

        elif isinstance(event, SystemNoticeEvent):
            color = {"INFO": "cyan", "WARN": "yellow", "ERROR": "red"}[event.level]
            self.query_one("#execution-log", RichLog).write(
                f"[bold {color}][{event.level}][/bold {color}] {event.message}"
            )
            self._refresh_header_bar()


if __name__ == "__main__":
    app = Civ5CommandTuiApp()
    app.run()
