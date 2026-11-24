# -*- coding: utf-8 -*-
"""
模块名称：run_exp06_acceptance.py
职责说明：
    EXP-06《MCP Server 封装与客户端挂载试验》全自动端到端验收脚本，覆盖 4 套独立验收套件：
    1. Suite A（Stdio + 环境变量 MOCK 模式）：使用官方 MCP ClientSession 校验 5 个标准 Tool Schema
       与全部读/写闭环（含侦察兵两步推进揭盲发现 3 支匈奴主力、快照导出与无损回载）；
    2. Suite B（Stdio + LIVE SQLite 跨进程 IPC 模式）：启动独立子进程模拟《文明5》SimpleValues 引擎，
       通过 --live-db / CIV5_BRIDGE_MODE=LIVE 实测全链路跨进程 SQLite RPC、LIVE 录制快照并热切换 MOCK；
    3. Suite C（Streamable HTTP 兜底方案多客户端并发测试）：以 --transport streamable-http 启动本地服务，
       同时拉起 2 个并发 MCP Client 并行访问，验证零争抢与低延迟；
    4. Suite D（agy mcp add 真实挂载与自主调用验证）：通过 `agy mcp add` 注册本 Server，
       调用真实 `agy.exe -p` 验证大模型自主调用 `get_turn_overview` 读取态势，并在结束后自动清理临时挂载项。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import multiprocessing as mp
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from typing import Any

# 允许直接脚本方式运行
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.streamable_http import streamable_http_client

from Civ5AgentBridge.tests.exp05.schemas import (
    ActionExecutionResultDTO,
    TurnOverviewDTO,
    UnitTacticalContextDTO,
)
from Civ5AgentBridge.tests.exp06.bridge_service import EXP05_DEFAULT_SNAPSHOT
from Civ5AgentBridge.tests.exp06.sqlite_bridge import simulated_civ5_lua_loop

SERVER_SCRIPT = Path(__file__).resolve().parent / "civ5_mcp_server.py"
OUTPUT_DIR = Path(__file__).resolve().parent / "output"
EXPECTED_TOOLS = {
    "get_turn_overview",
    "get_unit_context_and_candidates",
    "execute_unit_step",
    "save_turn_snapshot",
    "load_turn_snapshot",
}


def _extract_tool_payload(result: Any) -> Any:
    """
    兼容提取 mcp 2.x CallToolResult 中的业务返回值。
    原因：mcp 2.x 返回 dict 工具时会同时填充 structured_content 与 TextContent；
    返回 str 工具时 structured_content 可能是 {'result': '...'} 或为 None。
    """
    if getattr(result, "is_error", False):
        raise RuntimeError(f"MCP Tool 返回错误: {result.content}")

    sc = getattr(result, "structured_content", None)
    if sc is not None:
        if isinstance(sc, dict) and set(sc.keys()) == {"result"} and isinstance(sc["result"], str):
            return sc["result"]
        return sc

    text_parts = [
        getattr(block, "text", "")
        for block in (getattr(result, "content", None) or [])
        if getattr(block, "type", None) == "text"
    ]
    joined = "\n".join(text_parts).strip()
    try:
        return json.loads(joined)
    except json.JSONDecodeError:
        return joined


def _find_free_port() -> int:
    """在本机 127.0.0.1 申请一个当前空闲 TCP 端口供 Streamable HTTP 测试使用。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


async def run_suite_a_stdio_mock() -> dict[str, Any]:
    """
    Suite A：通过环境变量切换为 MOCK 模式，以 Stdio MCP Client 完整验收全部 5 个 Tool 契约。
    """
    t0 = time.perf_counter()
    snap_out_dir = OUTPUT_DIR / "snapshots_suite_a"
    snap_out_dir.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    env["CIV5_BRIDGE_MODE"] = "MOCK"
    env["CIV5_MOCK_SNAPSHOT"] = str(EXP05_DEFAULT_SNAPSHOT)
    env["CIV5_SNAPSHOTS_DIR"] = str(snap_out_dir)

    server_params = StdioServerParameters(
        command=sys.executable,
        args=[str(SERVER_SCRIPT)],
        env=env,
    )

    async with stdio_client(server_params) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            init_res = await session.initialize()

            # 1. 校验暴露工具集与参数 Schema
            tools_res = await session.list_tools()
            tool_names = {t.name for t in tools_res.tools}
            assert tool_names == EXPECTED_TOOLS, f"工具集合不匹配: {tool_names}"
            tool_schemas = {t.name: t.input_schema for t in tools_res.tools}

            # 2. get_turn_overview（验证迷雾合规：仅见 1 名蛮族，不可见 3 支匈奴伏兵）
            ov_raw = _extract_tool_payload(await session.call_tool("get_turn_overview", {}))
            ov = TurnOverviewDTO.model_validate(ov_raw)
            assert ov.turn_number == 45 and ov.player_civ == "中国"
            assert len(ov.our_units) == 3
            assert len(ov.visible_enemies) == 1 and ov.visible_enemies[0].enemy_id == "63:501"

            # 3. get_unit_context_and_candidates（查询侦察兵 101 周边与合法动作）
            ctx_raw = _extract_tool_payload(
                await session.call_tool(
                    "get_unit_context_and_candidates", {"unit_id": 101, "radius": 2}
                )
            )
            ctx = UnitTacticalContextDTO.model_validate(ctx_raw)
            assert ctx.unit.unit_id == 101 and len(ctx.candidate_actions) >= 3
            assert any(
                a.action_type == "MOVE_STEP" and (a.target_x, a.target_y) == (15, 18)
                for a in ctx.candidate_actions
            )

            # 4. execute_unit_step 第 1 步：(14,18) -> (15,18)，安全无新敌军
            step1_raw = _extract_tool_payload(
                await session.call_tool(
                    "execute_unit_step",
                    {
                        "unit_id": 101,
                        "action_type": "MOVE_STEP",
                        "target_x": 15,
                        "target_y": 18,
                    },
                )
            )
            step1 = ActionExecutionResultDTO.model_validate(step1_raw)
            assert step1.executed is True
            assert len(step1.delta_observation.newly_spotted_enemies) == 0

            # 5. execute_unit_step 第 2 步：(15,18) -> (16,18)，揭开战争迷雾发现 3 支匈奴主力
            step2_raw = _extract_tool_payload(
                await session.call_tool(
                    "execute_unit_step",
                    {
                        "unit_id": 101,
                        "action_type": "MOVE_STEP",
                        "target_x": 16,
                        "target_y": 18,
                    },
                )
            )
            step2 = ActionExecutionResultDTO.model_validate(step2_raw)
            assert step2.executed is True
            assert len(step2.delta_observation.newly_spotted_enemies) == 3
            assert step2.unit_after is not None and (step2.unit_after.x, step2.unit_after.y) == (16, 18)

            # 6. save_turn_snapshot 导出揭盲后的断点快照，再用 load_turn_snapshot 回载验证无损
            saved_path = _extract_tool_payload(
                await session.call_tool("save_turn_snapshot", {"tag": "after_ambush_mock"})
            )
            assert isinstance(saved_path, str) and Path(saved_path).exists()

            reloaded = _extract_tool_payload(
                await session.call_tool("load_turn_snapshot", {"snapshot_path": saved_path})
            )
            assert reloaded["loaded"] is True and reloaded["runtime_mode"] == "MOCK"
            reloaded_ov = TurnOverviewDTO.model_validate(reloaded["overview"])
            # 回载后应保留 4 名可见敌军（1 蛮族 + 3 匈奴）及侦察兵新坐标 (16,18)
            assert len(reloaded_ov.visible_enemies) == 4
            scout_after = next(u for u in reloaded_ov.our_units if u.unit_id == 101)
            assert (scout_after.x, scout_after.y) == (16, 18) and scout_after.moves_left == 0.0

    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    return {
        "passed": True,
        "server_name": getattr(init_res.server_info, "name", "civ5-agent-bridge"),
        "tools_verified": sorted(tool_names),
        "tool_input_required_fields": {
            name: schema.get("required", []) for name, schema in sorted(tool_schemas.items())
        },
        "step2_newly_spotted_enemies": len(step2.delta_observation.newly_spotted_enemies),
        "saved_snapshot_path": saved_path,
        "reloaded_visible_enemies_count": len(reloaded_ov.visible_enemies),
        "elapsed_ms": elapsed_ms,
    }


async def run_suite_b_stdio_live_sqlite() -> dict[str, Any]:
    """
    Suite B：启动独立子进程模拟《文明5》ModUserData SQLite 引擎，
    以 CLI `--live-db` 参数启动 MCP Server，验证真实跨进程 SQLite RPC 与 LIVE->MOCK 快照热切换。
    """
    t0 = time.perf_counter()
    live_db_path = OUTPUT_DIR / "exp06_sim_live.db"
    if live_db_path.exists():
        live_db_path.unlink()
    snap_out_dir = OUTPUT_DIR / "snapshots_suite_b"
    snap_out_dir.mkdir(parents=True, exist_ok=True)

    stop_evt = mp.Event()
    sim_proc = mp.Process(
        target=simulated_civ5_lua_loop,
        args=(str(live_db_path), stop_evt),
        daemon=True,
    )
    sim_proc.start()

    try:
        # 等待模拟游戏进程写出心跳
        await asyncio.sleep(0.25)

        server_params = StdioServerParameters(
            command=sys.executable,
            args=[
                str(SERVER_SCRIPT),
                "--live-db",
                str(live_db_path),
                "--snapshots-dir",
                str(snap_out_dir),
            ],
            env=dict(os.environ),
        )

        async with stdio_client(server_params) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()

                # 1. LIVE 读取全局态势（验证 Lua 缺省字段被正确规范化为标准 DTO）
                t_ov = time.perf_counter()
                ov_raw = _extract_tool_payload(await session.call_tool("get_turn_overview", {}))
                ov_rtt_ms = round((time.perf_counter() - t_ov) * 1000.0, 2)
                ov = TurnOverviewDTO.model_validate(ov_raw)
                assert ov.turn_number == 45 and ov.our_units[0].unit_id == 8192
                assert "strategic_resources" in ov.yields

                # 2. LIVE 查询单位上下文与候选动作
                ctx_raw = _extract_tool_payload(
                    await session.call_tool(
                        "get_unit_context_and_candidates", {"unit_id": 8192, "radius": 2}
                    )
                )
                ctx = UnitTacticalContextDTO.model_validate(ctx_raw)
                assert ctx.unit.unit_id == 8192 and len(ctx.candidate_actions) == 3

                # 3. LIVE 执行单步移动（含 250ms 异步结算与增量揭盲 1 名蛮族剑士）
                t_act = time.perf_counter()
                act_raw = _extract_tool_payload(
                    await session.call_tool(
                        "execute_unit_step",
                        {
                            "unit_id": 8192,
                            "action_type": "MOVE_STEP",
                            "target_x": 15,
                            "target_y": 18,
                        },
                    )
                )
                act_rtt_ms = round((time.perf_counter() - t_act) * 1000.0, 2)
                act = ActionExecutionResultDTO.model_validate(act_raw)
                assert act.executed is True
                assert act.unit_after is not None and (act.unit_after.x, act.unit_after.y) == (15, 18)
                assert len(act.delta_observation.newly_spotted_enemies) == 1

                # 4. 从 LIVE 录制快照并调用 load_turn_snapshot 热切为离线 MOCK 模式
                saved_live_snap = _extract_tool_payload(
                    await session.call_tool("save_turn_snapshot", {"tag": "live_recorded"})
                )
                assert isinstance(saved_live_snap, str) and Path(saved_live_snap).exists()

                loaded = _extract_tool_payload(
                    await session.call_tool("load_turn_snapshot", {"snapshot_path": saved_live_snap})
                )
                assert loaded["loaded"] is True and loaded["runtime_mode"] == "MOCK"
                loaded_ov = TurnOverviewDTO.model_validate(loaded["overview"])
                assert loaded_ov.our_units[0].unit_id == 8192
                assert len(loaded_ov.visible_enemies) == 1

    finally:
        stop_evt.set()
        sim_proc.join(timeout=2.0)

    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    return {
        "passed": True,
        "live_db_path": str(live_db_path),
        "overview_rtt_ms": ov_rtt_ms,
        "execute_step_rtt_ms": act_rtt_ms,
        "newly_spotted_count": len(act.delta_observation.newly_spotted_enemies),
        "live_recorded_snapshot": saved_live_snap,
        "hot_switched_to_mock": True,
        "elapsed_ms": elapsed_ms,
    }


async def run_suite_c_streamable_http_concurrent() -> dict[str, Any]:
    """
    Suite C：验证失败兜底方案（Streamable HTTP 本地端口模式），
    由 2 个并发 MCP Client 同时连接同一服务器并交替发起读请求，验证无连接争抢与低延迟。
    """
    t0 = time.perf_counter()
    port = _find_free_port()
    url = f"http://127.0.0.1:{port}/mcp"

    proc = await asyncio.create_subprocess_exec(
        sys.executable,
        str(SERVER_SCRIPT),
        "--mock-snapshot",
        str(EXP05_DEFAULT_SNAPSHOT),
        "--transport",
        "streamable-http",
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        # 轮询等待本地 TCP 端口就绪
        ready = False
        for _ in range(50):
            try:
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                writer.close()
                await writer.wait_closed()
                ready = True
                break
            except OSError:
                await asyncio.sleep(0.1)
        assert ready, f"Streamable HTTP Server 在端口 {port} 上启动超时"

        async def _worker(client_label: str, unit_id: int) -> dict[str, Any]:
            w0 = time.perf_counter()
            async with streamable_http_client(url) as (read_stream, write_stream):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    assert {t.name for t in tools.tools} == EXPECTED_TOOLS

                    ov_raw = _extract_tool_payload(await session.call_tool("get_turn_overview", {}))
                    ov = TurnOverviewDTO.model_validate(ov_raw)
                    ctx_raw = _extract_tool_payload(
                        await session.call_tool(
                            "get_unit_context_and_candidates",
                            {"unit_id": unit_id, "radius": 2},
                        )
                    )
                    ctx = UnitTacticalContextDTO.model_validate(ctx_raw)
                    assert ov.turn_number == 45 and ctx.unit.unit_id == unit_id
                    return {
                        "client": client_label,
                        "unit_id": unit_id,
                        "candidates": len(ctx.candidate_actions),
                        "elapsed_ms": round((time.perf_counter() - w0) * 1000.0, 2),
                    }

        worker_results = await asyncio.gather(
            _worker("client_advisor", 101),
            _worker("client_executor", 102),
        )
    finally:
        proc.terminate()
        try:
            await asyncio.wait_for(proc.wait(), timeout=3.0)
        except asyncio.TimeoutError:
            proc.kill()

    return {
        "passed": True,
        "endpoint": url,
        "concurrent_clients": len(worker_results),
        "worker_results": worker_results,
        "elapsed_ms": round((time.perf_counter() - t0) * 1000.0, 2),
    }


async def run_suite_d_agy_mcp_mount() -> dict[str, Any]:
    """
    Suite D：真实执行 `agy mcp add` 将 Civ5 MCP Server 挂载到本机 `agy.exe` CLI，
    验证 `agy` 能否自主调用 `get_turn_overview` 读取离线快照态势，并在结束后自动卸载清理。
    """
    agy_exe = shutil.which("agy") or shutil.which("agy.exe")
    if not agy_exe:
        raise RuntimeError("未在 PATH 中找到 agy.exe")

    server_alias = "civ5-bridge-exp06"
    isolated_cwd = OUTPUT_DIR / "agy_mcp_isolated_cwd"
    isolated_cwd.mkdir(parents=True, exist_ok=True)
    snap_dir = OUTPUT_DIR / "snapshots_suite_d"
    snap_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()

    # 1. 注册 MCP Server（通过 --env 注入 MOCK 模式与快照路径）
    add_cmd = [
        agy_exe,
        "mcp",
        "add",
        "--env",
        "CIV5_BRIDGE_MODE=MOCK",
        "--env",
        f"CIV5_MOCK_SNAPSHOT={EXP05_DEFAULT_SNAPSHOT}",
        "--env",
        f"CIV5_SNAPSHOTS_DIR={snap_dir}",
        server_alias,
        sys.executable,
        str(SERVER_SCRIPT),
    ]
    add_proc = subprocess.run(
        add_cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30
    )
    if add_proc.returncode != 0:
        raise RuntimeError(f"agy mcp add 失败: {add_proc.stderr or add_proc.stdout}")

    try:
        # 2. 确认 agy mcp list 可见且处于 enabled 状态
        list_proc = subprocess.run(
            [agy_exe, "mcp", "list"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        assert list_proc.returncode == 0 and server_alias in list_proc.stdout, (
            f"agy mcp list 未发现 {server_alias}: {list_proc.stdout}"
        )

        # 3. 驱动 agy.exe 非交互调用，要求自主调用 get_turn_overview 读取并汇报态势
        prompt = (
            f"请立刻调用已挂载的 MCP 服务器 '{server_alias}' 的工具 `get_turn_overview` 获取当前《文明5》回合态势。"
            "严禁臆测数据，也不要调用文件或终端工具。"
            "拿到工具返回后，只输出一个纯 JSON 对象，字段必须包含："
            '{"turn_number": int, "player_civ": str, "our_unit_ids": [int], "visible_enemy_ids": [str], "city_names": [str]}。'
        )
        invoke_cmd = [
            agy_exe,
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--effort",
            "low",
            "--dangerously-skip-permissions",
            "--disable-slash-commands",
        ]

        t_agy = time.perf_counter()
        proc = await asyncio.create_subprocess_exec(
            *invoke_cmd,
            cwd=str(isolated_cwd),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert proc.stdout is not None and proc.stderr is not None

        raw_events: list[dict[str, Any]] = []
        observed_tool_events: list[dict[str, Any]] = []
        final_response = ""
        conv_id: str | None = None

        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace").strip()
            if not text or not text.startswith("{"):
                continue
            evt = json.loads(text)
            raw_events.append(evt)
            etype = evt.get("event")
            if etype == "init":
                conv_id = evt.get("conversation_id")
            elif etype == "step_update":
                su = evt.get("step_update", {})
                stype = su.get("step_type", "")
                if "tool" in stype.lower() or "mcp" in json.dumps(su, ensure_ascii=False).lower():
                    observed_tool_events.append(su)
            elif etype == "result":
                res = evt.get("result", {})
                final_response = res.get("response") or ""

        stderr_text = (await proc.stderr.read()).decode("utf-8", errors="replace").strip()
        retcode = await proc.wait()
        agy_latency_ms = round((time.perf_counter() - t_agy) * 1000.0, 2)

        # 保存完整 NDJSON 轨迹供排障与留档
        (OUTPUT_DIR / "agy_mcp_stream_events.json").write_text(
            json.dumps(raw_events, ensure_ascii=False, indent=2), encoding="utf-8"
        )

        if retcode != 0:
            raise RuntimeError(f"agy -p 退出异常 (code={retcode}): {stderr_text}")

        # 从回复文本提取 JSON 并严格比对快照真值
        cleaned = final_response.strip()
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        assert start != -1 and end > start, f"agy 回复未包含 JSON 对象: {final_response}"
        parsed = json.loads(cleaned[start : end + 1])

        assert parsed["turn_number"] == 45, f"turn_number 不符: {parsed}"
        assert "中国" in str(parsed["player_civ"]), f"player_civ 不符: {parsed}"
        assert sorted(int(x) for x in parsed["our_unit_ids"]) == [101, 102, 103], f"our_unit_ids 不符: {parsed}"
        assert parsed["visible_enemy_ids"] == ["63:501"], f"visible_enemy_ids 不符（不得泄露迷雾敌军）: {parsed}"
        assert "北京" in parsed["city_names"], f"city_names 不符: {parsed}"

        # 确认流中确实发生了针对 get_turn_overview 的工具调用
        events_dump = json.dumps(raw_events, ensure_ascii=False)
        tool_invoked_confirmed = "get_turn_overview" in events_dump and len(observed_tool_events) > 0

        return {
            "passed": True,
            "mcp_server_alias": server_alias,
            "conversation_id": conv_id,
            "agy_latency_ms": agy_latency_ms,
            "observed_tool_event_count": len(observed_tool_events),
            "tool_invoked_confirmed": tool_invoked_confirmed,
            "parsed_overview_summary": parsed,
            "cleaned_up_after_test": True,
            "elapsed_ms": round((time.perf_counter() - t0) * 1000.0, 2),
        }
    finally:
        # 无论成功失败都清理试验注册项，保持用户全局 agy mcp list 整洁
        subprocess.run(
            [agy_exe, "mcp", "remove", server_alias],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )


async def run_all(skip_agy: bool = False) -> dict[str, Any]:
    """依次执行 EXP-06 全部验收套件并落盘结构化验收报告。"""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "experiment": "EXP-06",
        "suites": {},
        "all_passed": False,
    }

    report["suites"]["suite_a_stdio_mock"] = await run_suite_a_stdio_mock()
    report["suites"]["suite_b_stdio_live_sqlite"] = await run_suite_b_stdio_live_sqlite()
    report["suites"]["suite_c_streamable_http_concurrent"] = (
        await run_suite_c_streamable_http_concurrent()
    )
    if not skip_agy:
        report["suites"]["suite_d_agy_mcp_mount"] = await run_suite_d_agy_mcp_mount()

    report["all_passed"] = all(s.get("passed") is True for s in report["suites"].values())
    report_path = OUTPUT_DIR / "exp06_acceptance_report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="EXP-06 MCP Server 封装与客户端挂载全套验收")
    parser.add_argument(
        "--skip-agy",
        action="store_true",
        help="仅跑本地 Stdio(Mock/Live) 与 Streamable HTTP 验收，跳过真实 agy CLI 挂载调用",
    )
    args = parser.parse_args()
    report = asyncio.run(run_all(skip_agy=args.skip_agy))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
