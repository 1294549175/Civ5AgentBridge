# -*- coding: utf-8 -*-
"""
EXP-05 自动化验收测试入口：三层指挥链（顾问-参谋长-执行者+Jev）与自下而上中断离线 Mock 试验。
支持两种运行模式：
1. --mode simulate : 使用确定性模型桩毫秒级验证正向公文流转、LEVEL 2 战略中断退回、LEVEL 1 战术微调与现场保留；
2. --mode live-agy : 调用本机真实 agy.exe CLI（Gemini 大模型）执行端到端真实推理、会话复用与结构化 Schema 联调。
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import sys
import time
from typing import Any

# 允许直接以脚本方式运行：将父目录加入模块搜索路径
EXP05_DIR = Path(__file__).resolve().parent
TESTS_DIR = EXP05_DIR.parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from exp05.jev_classifier import JevClassifierService  # noqa: E402
from exp05.llm_gateway import AgyCliBackend, DeterministicMockBackend  # noqa: E402
from exp05.mock_sandbox import OfflineCiv5Sandbox  # noqa: E402
from exp05.orchestrator import ThreeTierOrchestrator  # noqa: E402
from exp05.schemas import SessionPhaseEnum  # noqa: E402


async def execute_exp05_acceptance(mode: str, verbose_stream: bool = False) -> dict[str, Any]:
    """
    执行完整的 EXP-05 验收剧本并对所有通过标准逐项断言，返回结构化测试报告。
    """
    t_start = time.perf_counter()
    snapshot_path = EXP05_DIR / "snapshots" / "turn45_ambush_snapshot.json"
    output_dir = EXP05_DIR / "output" / mode
    output_dir.mkdir(parents=True, exist_ok=True)
    trajectory_path = output_dir / "jev_trajectories.jsonl"
    if trajectory_path.exists():
        trajectory_path.unlink()

    sandbox = OfflineCiv5Sandbox(snapshot_path)
    jev = JevClassifierService(trajectory_path=trajectory_path)
    llm_backend = (
        AgyCliBackend(isolated_cwd=output_dir / "agy_isolated_cwd")
        if mode == "live-agy"
        else DeterministicMockBackend()
    )

    async def stream_printer(tier: str, kind: str, delta: str) -> None:
        if verbose_stream:
            sys.stderr.write(delta)
            sys.stderr.flush()

    orch = ThreeTierOrchestrator(
        sandbox=sandbox,
        llm_backend=llm_backend,
        jev_service=jev,
        handoff_output_dir=output_dir / "handoffs",
        on_stream=stream_printer if verbose_stream else None,
    )

    # -------------------------------------------------------------------------
    # 断言 0：初始战争迷雾隔离性验证（东北 3 支匈奴主力未揭盲前严格不可见）
    # -------------------------------------------------------------------------
    init_ov = await sandbox.get_turn_overview()
    assert len(init_ov.our_units) == 3, f"初始己方单位应为3个，实际={len(init_ov.our_units)}"
    assert len(init_ov.visible_enemies) == 1, (
        f"初始可见敌军应仅为1支侧翼蛮族，严禁泄露迷雾敌军，实际={len(init_ov.visible_enemies)}"
    )

    # -------------------------------------------------------------------------
    # 阶段 1：正向公文流转（顾问出具《工作文书》 -> 玩家审批 -> 参谋长拆分为 2 个 TaskPackage）
    # -------------------------------------------------------------------------
    initial_proposal = await orch.start_turn_advisor_draft()
    assert orch.session.phase == SessionPhaseEnum.WAITING_PLAYER_APPROVAL
    assert len(initial_proposal.work_directive.redline_constraints) >= 1

    initial_tasks = await orch.approve_directive_and_dispatch()
    assert orch.session.phase == SessionPhaseEnum.EXECUTING
    assert len(initial_tasks) == 2, f"参谋长初次拆单应生成 2 个 TaskPackage，实际={len(initial_tasks)}"
    assert initial_tasks[0].unit_ids == [101], "第1顺位任务包必须遵循侦察先行原则指派 101"

    # -------------------------------------------------------------------------
    # 阶段 2：执行探路（第 1 步正常 LEVEL 0 -> 第 2 步揭盲遇敌主力触发 LEVEL 2 逐级退回）
    # -------------------------------------------------------------------------
    paused_phase = await orch.run_execution_loop_until_pause_or_done()
    assert paused_phase == SessionPhaseEnum.ESCALATED_TO_ADVISOR, (
        f"第2步遭遇敌主力后状态机应停在 ESCALATED_TO_ADVISOR 等待玩家，实际={paused_phase}"
    )

    # 校验前两步执行明细
    assert len(orch.session.execution_logs) == 2, (
        f"中断前应恰好执行了侦察兵的 2 个单步，实际={len(orch.session.execution_logs)}"
    )
    step1, step2 = orch.session.execution_logs[0], orch.session.execution_logs[1]
    assert step1["unit_id"] == 101 and step1["jev_escalation_level"] == 0
    assert step1["newly_spotted_enemies"] == []
    assert step2["unit_id"] == 101 and step2["jev_escalation_level"] == 2
    assert len(step2["newly_spotted_enemies"]) == 3, "第2步至(16,18)应揭盲发现 3 支匈奴正规军主力"

    # 校验现场保留完整性：主力 102、103 任务已挂起保护且未在沙盘内乱动
    assert len(orch.session.suspended_tasks) == 1, "未执行的第2任务包必须被完整挂起保留现场"
    assert set(orch.session.suspended_tasks[0].unit_ids) == {102, 103}
    mid_ov = await sandbox.get_turn_overview()
    mid_units = {u.unit_id: u for u in mid_ov.our_units}
    assert mid_units[101].moves_left == 0.0 and (mid_units[101].x, mid_units[101].y) == (16, 18)
    assert mid_units[102].moves_left == 2.0 and (mid_units[102].x, mid_units[102].y) == (13, 17)
    assert mid_units[103].moves_left == 2.0 and (mid_units[103].x, mid_units[103].y) == (13, 18)
    assert orch.session.pending_advisor_alert is not None

    # -------------------------------------------------------------------------
    # 阶段 3：模拟玩家拍板防线收缩 -> 恢复执行 -> 触发 LEVEL 1 参谋长战术补刀微调 -> 完成回合
    # -------------------------------------------------------------------------
    alert_opts = orch.session.pending_advisor_alert.options_for_player
    rec_idx = min(
        orch.session.pending_advisor_alert.recommended_option_index,
        len(alert_opts) - 1,
    )
    chosen_opt = alert_opts[rec_idx]

    resumed_tasks = await orch.resolve_level2_escalation_by_player(
        chosen_option=chosen_opt,
        player_custom_instruction="立即停止东进！102复合弓先远程清除(14,17)侧翼蛮族弓箭手，103长矛营抢占(14,18)河岸丘陵驻防，101移动力已尽原地隐蔽。",
    )
    assert orch.session.phase == SessionPhaseEnum.EXECUTING
    resumed_uids = {uid for t in resumed_tasks for uid in t.unit_ids}
    assert 101 not in resumed_uids, "恢复调度时严禁将已耗尽移动力的 101 重新排入任务包"
    assert resumed_uids == {102, 103}, f"恢复调度应精确覆盖剩余可用主力 {{102, 103}}，实际={resumed_uids}"

    # 恢复执行：102 射击 (14,17) 致蛮族剩 6HP -> 触发 LEVEL 1 退回参谋长改派 103 补刀 -> TURN_COMPLETED
    final_phase = await orch.run_execution_loop_until_pause_or_done()
    assert final_phase == SessionPhaseEnum.TURN_COMPLETED, (
        f"恢复执行及 LEVEL 1 战术微调后应直达 TURN_COMPLETED（不打扰玩家），实际={final_phase}"
    )

    # 校验逆向分支 A（LEVEL 1 战术微调闭环）与逆向分支 B（LEVEL 2 战略中断）均已准确触发
    esc_levels = [e.level for e in orch.session.escalation_history]
    assert esc_levels == [2, 1], f"本局应依次触发 LEVEL 2 战略中断与 LEVEL 1 战术微调，实际={esc_levels}"

    phases_seq = [t["to_phase"] for t in orch.session.state_transition_trace]
    # 校验存在 EXECUTING -> ESCALATED_TO_CHIEF -> ESCALATED_TO_ADVISOR（LEVEL 2 分支）
    # 以及 EXECUTING -> ESCALATED_TO_CHIEF -> EXECUTING（LEVEL 1 分支，不经 ADVISOR）
    has_l2_chain = any(
        phases_seq[i : i + 3]
        == ["EXECUTING", "ESCALATED_TO_CHIEF", "ESCALATED_TO_ADVISOR"]
        for i in range(len(phases_seq) - 2)
    )
    has_l1_chain = any(
        phases_seq[i : i + 3] == ["EXECUTING", "ESCALATED_TO_CHIEF", "EXECUTING"]
        for i in range(len(phases_seq) - 2)
    )
    assert has_l2_chain, f"状态轨迹缺失 LEVEL 2 逐级退回链路: {phases_seq}"
    assert has_l1_chain, f"状态轨迹缺失 LEVEL 1 参谋长局部微调闭环链路: {phases_seq}"

    # 校验侧翼蛮族已被补刀歼灭，且跨回合交接文书与 Jev 轨迹文件已完整落盘
    end_ov = await sandbox.get_turn_overview()
    barb_alive = [e for e in end_ov.visible_enemies if e.enemy_id == "63:501"]
    assert len(barb_alive) == 0, "经 LEVEL 1 参谋长改派长矛营补刀后，(14,17)残血蛮族必须已被歼灭"

    handoff_file = output_dir / "handoffs" / "turn_45_handoff.json"
    assert handoff_file.exists(), "回合收尾必须落盘 turn_45_handoff.json"
    trj_lines = [
        json.loads(line)
        for line in trajectory_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert len(trj_lines) >= 8, f"Jev 轨迹样本数应 >= 8 条，实际={len(trj_lines)}"

    total_ms = round((time.perf_counter() - t_start) * 1000.0, 2)
    llm_latencies = [m.latency_ms for m in orch.session.llm_call_metrics]

    report = {
        "experiment": "EXP-05",
        "mode": mode,
        "all_passed": True,
        "total_elapsed_ms": total_ms,
        "llm_calls": {
            "count": len(orch.session.llm_call_metrics),
            "avg_latency_ms": (
                round(sum(llm_latencies) / len(llm_latencies), 2) if llm_latencies else 0.0
            ),
            "schema_fallbacks_triggered": sum(
                1 for m in orch.session.llm_call_metrics if m.used_schema_fallback
            ),
            "advisor_conversation_id_reused": orch.session.advisor_conv_id is not None,
            "details": [
                {
                    "role": m.role_tier,
                    "backend": m.backend_used,
                    "latency_ms": m.latency_ms,
                    "thinking_tokens": m.thinking_tokens,
                    "output_tokens": m.output_tokens,
                }
                for m in orch.session.llm_call_metrics
            ],
        },
        "state_machine_verification": {
            "total_transitions": len(orch.session.state_transition_trace),
            "phase_sequence": phases_seq,
            "level2_strategic_chain_verified": has_l2_chain,
            "level1_tactical_chain_verified": has_l1_chain,
            "context_preservation_verified": True,
        },
        "execution_summary": {
            "atomic_steps_executed": len(orch.session.execution_logs),
            "escalations_triggered": [
                {
                    "id": e.escalation_id,
                    "level": e.level,
                    "reason_tag": e.trigger_reason_tag,
                    "trigger_unit_id": e.trigger_unit_id,
                }
                for e in orch.session.escalation_history
            ],
            "steps": orch.session.execution_logs,
            "jev_trajectory_samples_saved": len(trj_lines),
            "handoff_saved_path": str(handoff_file),
        },
    }

    report_path = output_dir / "exp05_acceptance_report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="EXP-05 三层指挥链与自下而上中断验收脚本")
    parser.add_argument(
        "--mode",
        choices=["simulate", "live-agy"],
        default="simulate",
        help="simulate=离线确定性桩验证；live-agy=调用本机真实 agy.exe CLI 大模型联调",
    )
    parser.add_argument(
        "--verbose-stream",
        action="store_true",
        help="是否在 stderr 实时打印大模型流式输出",
    )
    args = parser.parse_args()

    report = asyncio.run(
        execute_exp05_acceptance(mode=args.mode, verbose_stream=args.verbose_stream)
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
