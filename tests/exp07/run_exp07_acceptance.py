# -*- coding: utf-8 -*-
"""
模块名称：run_exp07_acceptance.py
职责说明：
    EXP-07《Textual TUI 异步控制台 + Jev 冷启动判别与轨迹落盘试验》全自动端到端验收脚本：
    1. 通过 Textual 官方 Pilot（app.run_test）启动真实三栏军事指挥台，底层直连 EXP-06 标准 MCP Server；
    2. 在后台流式推演（agy/GLM 流）+ MCP 动作执行期间，以 60Hz 帧心跳采样事件循环抖动，
       并发测试 RichLog 滚动、顶部模型热切换、玩家对话、快照录制、公文批准与 LEVEL 2 警报拍板响应延迟；
    3. 核验完整第 45 回合状态机走完 TURN_COMPLETED（覆盖 LEVEL 2 战略中断 + LEVEL 1 参谋长局部补刀）；
    4. 对落盘的 jev_trajectories.jsonl 执行 Colab Notebook 训练就绪度质检（定长特征矩阵、无缺失、含人类修正样本）；
    5. 导出 TUI 警报态与终态 SVG 终端渲染快照及完整 JSON 验收报告。
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
import sys
import time
from typing import Any

# 允许直接脚本启动
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from textual.widgets import Button, Input, RichLog, Static

from Civ5AgentBridge.tests.exp05.schemas import SessionPhaseEnum
from Civ5AgentBridge.tests.exp07.jev_coldstart import validate_trajectories_for_colab
from Civ5AgentBridge.tests.exp07.tui_app import Civ5CommandTuiApp

OUTPUT_DIR = Path(__file__).resolve().parent / "output"


async def _wait_until(
    predicate: Any, timeout_sec: float = 20.0, poll_sec: float = 0.03, desc: str = ""
) -> None:
    """非阻塞轮询等待断言条件成立。"""
    deadline = time.perf_counter() + timeout_sec
    while time.perf_counter() < deadline:
        if predicate():
            return
        await asyncio.sleep(poll_sec)
    raise TimeoutError(f"等待超时 ({timeout_sec}s): {desc}")


async def run_exp07_acceptance() -> dict[str, Any]:
    """执行 EXP-07 端到端 Textual TUI 并发流畅度、全流程交互与 Jev 轨迹质检验收。"""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    t0 = time.perf_counter()

    app = Civ5CommandTuiApp(
        output_dir=OUTPUT_DIR,
        stream_chunk_delay_sec=0.015,
        mcp_poll_delay_sec=0.08,
    )

    interaction_latencies_ms: dict[str, float] = {}
    scroll_checks_passed = 0

    async with app.run_test(size=(160, 48)) as pilot:
        # 1. 等待后台异步连接 EXP-06 MCP Server 就绪
        await _wait_until(
            lambda: app.mcp_client.is_connected and len(app.mcp_tools_discovered) == 5,
            timeout_sec=15.0,
            desc="EXP-06 MCP Server 连接就绪",
        )

        # 2. 点击【同步态势】，触发 MCP 读取 + 顾问流式 THINKING/TEXT 拟稿
        t_btn = time.perf_counter()
        await pilot.click("#btn-sync")
        interaction_latencies_ms["click_sync_ms"] = round(
            (time.perf_counter() - t_btn) * 1000.0, 2
        )

        # 在顾问流式输出期间并发执行：热切换参谋长模型 + 滚动中栏日志（验证瓶颈 E-1 零阻塞）
        await _wait_until(
            lambda: app.controller.stream_chunks_emitted >= 3,
            timeout_sec=10.0,
            desc="顾问开始流式推送 chunk",
        )
        t_sw = time.perf_counter()
        await pilot.click("#btn-switch-chief-model")
        interaction_latencies_ms["click_switch_model_during_stream_ms"] = round(
            (time.perf_counter() - t_sw) * 1000.0, 2
        )
        adv_log = app.query_one("#advisor-log", RichLog)
        adv_log.scroll_down(animate=False)
        adv_log.scroll_up(animate=False)
        scroll_checks_passed += 1

        # 3. 等待进入 WAITING_PLAYER_APPROVAL（《工作文书》草案就绪）
        await _wait_until(
            lambda: app.controller.phase == SessionPhaseEnum.WAITING_PLAYER_APPROVAL
            and not app.query_one("#btn-approve", Button).disabled,
            timeout_sec=15.0,
            desc="顾问完成草案拟定并点亮批准按钮",
        )

        # 4. 玩家在输入框提交修改意见 + 点击【录制快照】验证真实 MCP save_turn_snapshot
        inp = app.query_one("#player-input", Input)
        inp.value = "侦察兵若遇匈奴骑射群务必立即停步固守"
        t_chat = time.perf_counter()
        await pilot.click("#btn-send-chat")
        interaction_latencies_ms["click_send_chat_ms"] = round(
            (time.perf_counter() - t_chat) * 1000.0, 2
        )
        await asyncio.sleep(0.35)

        t_snap = time.perf_counter()
        await pilot.click("#btn-snapshot")
        interaction_latencies_ms["click_record_snapshot_ms"] = round(
            (time.perf_counter() - t_snap) * 1000.0, 2
        )
        await _wait_until(
            lambda: app.controller.last_snapshot_path is not None
            and Path(app.controller.last_snapshot_path).exists(),
            timeout_sec=10.0,
            desc="MCP 快照录制落盘",
        )

        # 5. 点击【批准下发】启动参谋长拆单 + 执行层经真实 MCP Server 推进
        t_app = time.perf_counter()
        await pilot.click("#btn-approve")
        interaction_latencies_ms["click_approve_directive_ms"] = round(
            (time.perf_counter() - t_app) * 1000.0, 2
        )

        # 在执行层与 MCP Server 交互期间并发滚动右栏监控流
        await asyncio.sleep(0.25)
        exec_log = app.query_one("#execution-log", RichLog)
        exec_log.scroll_down(animate=False)
        exec_log.scroll_up(animate=False)
        scroll_checks_passed += 1

        # 6. 等待侦察兵 101 揭盲发现 3 支匈奴主力并触发 LEVEL 2 战略警报弹窗
        await _wait_until(
            lambda: app.controller.phase == SessionPhaseEnum.ESCALATED_TO_ADVISOR
            and not app.query_one("#btn-resolve-l2", Button).disabled
            and app.query_one("#escalation-banner", Static).has_class("visible"),
            timeout_sec=20.0,
            desc="触发 LEVEL 2 战略警报横幅并点亮拍板按钮",
        )

        # 导出 LEVEL 2 警报态 TUI 终端渲染快照
        l2_svg_path = OUTPUT_DIR / "tui_l2_alert_screen.svg"
        app.save_screenshot(str(l2_svg_path))

        # 7. 玩家点击【拍板收缩】恢复执行（触发人类修正轨迹样本 + LEVEL 1 参谋长补刀微调）
        t_res = time.perf_counter()
        await pilot.click("#btn-resolve-l2")
        interaction_latencies_ms["click_resolve_l2_ms"] = round(
            (time.perf_counter() - t_res) * 1000.0, 2
        )

        # 恢复执行期间再次验证并发滚动
        await asyncio.sleep(0.25)
        exec_log.scroll_down(animate=False)
        scroll_checks_passed += 1

        # 8. 等待整回合执行完毕进入 TURN_COMPLETED
        await _wait_until(
            lambda: app.controller.phase == SessionPhaseEnum.TURN_COMPLETED
            and app.turn_completed_event is not None,
            timeout_sec=25.0,
            desc="整回合收尾进入 TURN_COMPLETED",
        )
        await pilot.pause(0.1)

        # 导出终态 TUI 终端渲染快照
        final_svg_path = OUTPUT_DIR / "tui_final_screen.svg"
        app.save_screenshot(str(final_svg_path))

        frame_stats = app.telemetry.summarize()
        button_handler_latencies = dict(app.button_handler_latencies_ms)
        transitions = list(app.controller.state_transitions)
        mcp_calls = app.mcp_client.mcp_calls_count
        mcp_tools = list(app.mcp_tools_discovered)
        stream_chunks = app.controller.stream_chunks_emitted
        ui_events = app.ui_events_received
        model_history = list(app.controller.model_routes.history)
        snap_path = app.controller.last_snapshot_path
        handoff_path = app.turn_completed_event.handoff_path  # type: ignore[union-attr]
        traj_path = Path(app.turn_completed_event.trajectory_path)  # type: ignore[union-attr]
        exec_steps = len(app.controller.execution_logs)

    # 9. Colab Notebook 就绪度严格质检
    colab_check = validate_trajectories_for_colab(traj_path)

    # 10. 关键验收断言
    max_handler_ms = max(button_handler_latencies.values())
    max_pilot_click_ms = max(interaction_latencies_ms.values())
    assert frame_stats["samples"] >= 60, f"帧采样数不足: {frame_stats}"
    assert frame_stats["effective_fps"] >= 45.0, f"有效帧率偏低: {frame_stats}"
    assert frame_stats["p95_tick_ms"] <= 45.0, f"P95 帧间隔过高: {frame_stats}"
    assert max_handler_ms <= 20.0, f"按钮回调占用主线程耗时过高: {button_handler_latencies}"
    assert max_pilot_click_ms <= 800.0, f"Pilot 点击端到端耗时过高: {interaction_latencies_ms}"
    assert "ESCALATED_TO_ADVISOR" in transitions, f"未观测到 LEVEL 2 战略中断: {transitions}"
    assert transitions.count("ESCALATED_TO_CHIEF") >= 2, f"未观测到 LEVEL 2 + LEVEL 1 双中断: {transitions}"
    assert transitions[-1] == "TURN_COMPLETED"
    assert len(model_history) >= 1, "模型热切换未生效"
    assert Path(handoff_path).exists(), f"交接文书未落盘: {handoff_path}"
    assert colab_check["colab_ready"] is True

    report = {
        "experiment": "EXP-07",
        "all_passed": True,
        "elapsed_ms": round((time.perf_counter() - t0) * 1000.0, 2),
        "ui_responsiveness_60hz": {
            "passed": True,
            "frame_telemetry": frame_stats,
            "button_handler_latencies_ms": button_handler_latencies,
            "max_button_handler_ms": max_handler_ms,
            "pilot_click_roundtrip_ms": interaction_latencies_ms,
            "max_pilot_click_ms": max_pilot_click_ms,
            "concurrent_scroll_checks_passed": scroll_checks_passed,
            "stream_chunks_rendered": stream_chunks,
            "ui_events_processed": ui_events,
        },
        "end_to_end_command_chain": {
            "passed": True,
            "mcp_server_connected": True,
            "mcp_tools_discovered": mcp_tools,
            "mcp_calls_executed": mcp_calls,
            "unit_steps_executed": exec_steps,
            "model_hot_switches": model_history,
            "state_transitions": transitions,
            "recorded_snapshot_path": snap_path,
            "final_handoff_path": handoff_path,
        },
        "jev_colab_trajectory_validation": colab_check,
        "artifacts": {
            "trajectory_jsonl": str(traj_path),
            "l2_alert_svg": str(l2_svg_path),
            "final_screen_svg": str(final_svg_path),
        },
    }

    report_path = OUTPUT_DIR / "exp07_acceptance_report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return report


def main() -> None:
    report = asyncio.run(run_exp07_acceptance())
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
