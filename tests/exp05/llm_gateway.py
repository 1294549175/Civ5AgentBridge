# -*- coding: utf-8 -*-
"""
模块名称：llm_gateway.py
职责说明：
    实现《02_软件总体设计说明书》模块 3 与《03_接口设计说明书》§3 定义的多模型统一网关：
    1. AgyCliBackend：基于 EXP-01 实测定论，通过 asyncio.create_subprocess_exec 在独立空目录 cwd 下调用 agy.exe，
       解析 --output-format stream-json 的 NDJSON 流（init / step_update / result），支持 --conversation 多轮续接，
       采用“单轮 --effort low/medium JSON 提取 + 失败自动降级 --json-schema 重试”双保险机制；
    2. DeterministicMockBackend：毫秒级离线确定性推理桩，供不联网时快速回归验证状态机跳转与 Schema 契约。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
from pathlib import Path
import re
import shutil
import tempfile
import time
from typing import Any, Awaitable, Callable, Literal, TypeVar
from pydantic import BaseModel, ValidationError

from .schemas import (
    AdvisorEscalationAlertOutput,
    AdvisorProposalOutput,
    ChiefDispatchOutput,
    ChiefEscalationDecisionOutput,
)

TModel = TypeVar("TModel", bound=BaseModel)
StreamCallback = Callable[[str, Literal["THINKING", "TEXT"], str], Awaitable[None]]


@dataclass
class LLMCallMeta:
    """单次模型网关调用的耗时、会话与令牌统计元数据。"""

    role_tier: str
    backend_used: str
    latency_ms: float
    conversation_id: str | None = None
    used_schema_fallback: bool = False
    thinking_tokens: int = 0
    output_tokens: int = 0


def extract_first_json_object(raw_text: str) -> str:
    """
    从模型回复文本中剥离 Markdown 代码块并稳健提取最外层 JSON 对象字符串。
    原因：单轮 --effort low 模式下模型偶发包裹 ```json ... ``` 围栏，需在送入 Pydantic 前归一化。
    """
    cleaned = raw_text.strip()
    fence_match = re.search(r"```(?:json)?\s*(\{.*\})\s*```", cleaned, flags=re.DOTALL)
    if fence_match:
        return fence_match.group(1).strip()

    start_idx = cleaned.find("{")
    if start_idx == -1:
        raise ValueError(f"回复中未找到 '{'{'}' 起始符: {cleaned[:200]}")

    depth = 0
    in_str = False
    escape = False
    for idx in range(start_idx, len(cleaned)):
        ch = cleaned[idx]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return cleaned[start_idx : idx + 1]

    raise ValueError(f"JSON 大括号未闭合: {cleaned[:200]}")


class AgyCliBackend:
    """
    真实 agy.exe CLI 异步子进程后端。
    遵循 EXP-01 避坑定论：使用空隔离工作目录 cwd 杜绝工作区 AGENTS.md 诱导模型触发文件/终端工具权限阻塞。
    """

    def __init__(self, isolated_cwd: Path | None = None) -> None:
        agy_path = shutil.which("agy") or shutil.which("agy.exe")
        if not agy_path:
            raise RuntimeError("未在 PATH 中找到 agy.exe，无法启用 live-agy 模式")
        self.agy_exe = agy_path
        if isolated_cwd is None:
            isolated_cwd = Path(tempfile.gettempdir()) / "civ5_agent_agy_isolated_cwd"
        self.isolated_cwd = isolated_cwd
        self.isolated_cwd.mkdir(parents=True, exist_ok=True)

    async def generate_structured(
        self,
        role_tier: str,
        call_tag: str,
        system_prompt: str,
        user_prompt: str,
        response_model: type[TModel],
        conversation_id: str | None = None,
        effort: Literal["low", "medium"] = "low",
        on_stream: StreamCallback | None = None,
    ) -> tuple[TModel, LLMCallMeta]:
        """
        调用 agy.exe 生成严格符合 response_model 的结构化对象。
        若单轮快速 JSON 提取校验未过，自动回退启用 --json-schema 强制模式重试一次。
        """
        schema_dict = response_model.model_json_schema()
        schema_json_compact = json.dumps(schema_dict, ensure_ascii=False)

        composed_prompt = (
            "【系统最高指令】你正在离线战略沙盘中担任推理节点。严禁调用任何文件读写、目录查看、网页搜索或终端命令工具！"
            "请直接依据下方给定的 JSON 态势推理，并且只输出一个符合指定 JSON Schema 的纯 JSON 对象，不要输出任何额外说明。\n\n"
            f"【角色设定】\n{system_prompt}\n\n"
            f"【当前输入】\n{user_prompt}\n\n"
            f"【必须严格遵守的输出 JSON Schema】\n{schema_json_compact}\n"
        )

        t0 = time.perf_counter()
        try:
            parsed, conv_id, usage = await self._invoke_agy_once(
                role_tier=role_tier,
                prompt=composed_prompt,
                response_model=response_model,
                conversation_id=conversation_id,
                effort=effort,
                enforce_cli_schema=False,
                on_stream=on_stream,
            )
            latency_ms = round((time.perf_counter() - t0) * 1000.0, 2)
            return parsed, LLMCallMeta(
                role_tier=role_tier,
                backend_used=f"agy-cli(effort={effort})",
                latency_ms=latency_ms,
                conversation_id=conv_id,
                used_schema_fallback=False,
                thinking_tokens=int(usage.get("thinking_tokens", 0)),
                output_tokens=int(usage.get("output_tokens", 0)),
            )
        except (ValidationError, ValueError, json.JSONDecodeError):
            # 触发 EXP-01 兜底定论：单轮校验失败时启用 --json-schema 强约束重试
            parsed, conv_id, usage = await self._invoke_agy_once(
                role_tier=role_tier,
                prompt=composed_prompt,
                response_model=response_model,
                conversation_id=None,
                effort=effort,
                enforce_cli_schema=True,
                on_stream=on_stream,
            )
            latency_ms = round((time.perf_counter() - t0) * 1000.0, 2)
            return parsed, LLMCallMeta(
                role_tier=role_tier,
                backend_used=f"agy-cli(effort={effort},schema-fallback)",
                latency_ms=latency_ms,
                conversation_id=conv_id,
                used_schema_fallback=True,
                thinking_tokens=int(usage.get("thinking_tokens", 0)),
                output_tokens=int(usage.get("output_tokens", 0)),
            )

    async def _invoke_agy_once(
        self,
        role_tier: str,
        prompt: str,
        response_model: type[TModel],
        conversation_id: str | None,
        effort: str,
        enforce_cli_schema: bool,
        on_stream: StreamCallback | None,
    ) -> tuple[TModel, str | None, dict[str, Any]]:
        """启动 agy.exe 异步子进程，逐行消费 NDJSON 事件流并校验最终结果。"""
        cmd = [
            self.agy_exe,
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--effort",
            effort,
            "--disable-slash-commands",
        ]
        if conversation_id:
            cmd.extend(["--conversation", conversation_id])

        schema_file: Path | None = None
        if enforce_cli_schema:
            schema_file = self.isolated_cwd / f"schema_{int(time.time() * 1000)}.json"
            schema_file.write_text(
                json.dumps(response_model.model_json_schema(), ensure_ascii=False),
                encoding="utf-8",
            )
            cmd.extend(["--json-schema", str(schema_file)])

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(self.isolated_cwd),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            assert proc.stdout is not None
            assert proc.stderr is not None

            conv_id: str | None = conversation_id
            streamed_chunks: list[str] = []
            final_response_text: str = ""
            structured_obj: dict[str, Any] | None = None
            usage_info: dict[str, Any] = {}

            while True:
                line_bytes = await proc.stdout.readline()
                if not line_bytes:
                    break
                line_str = line_bytes.decode("utf-8", errors="replace").strip()
                if not line_str or not line_str.startswith("{"):
                    continue
                evt = json.loads(line_str)
                etype = evt.get("event")

                if etype == "init":
                    conv_id = evt.get("conversation_id") or conv_id

                elif etype == "step_update":
                    su = evt.get("step_update", {})
                    delta = su.get("text_delta", "")
                    if delta:
                        streamed_chunks.append(delta)
                        if on_stream is not None:
                            await on_stream(role_tier, "TEXT", delta)
                    if "usage" in su and isinstance(su["usage"], dict):
                        usage_info = su["usage"]

                elif etype == "result":
                    res = evt.get("result", {})
                    conv_id = res.get("conversation_id") or conv_id
                    final_response_text = res.get("response") or ""
                    if isinstance(res.get("structured_output"), dict):
                        structured_obj = res["structured_output"]
                    if "usage" in res and isinstance(res["usage"], dict):
                        usage_info = res["usage"]

            stderr_bytes = await proc.stderr.read()
            ret_code = await proc.wait()
            if ret_code != 0:
                err_msg = stderr_bytes.decode("utf-8", errors="replace")
                raise RuntimeError(f"agy.exe 退出码非零 ({ret_code}): {err_msg}")

            if structured_obj is not None:
                return response_model.model_validate(structured_obj), conv_id, usage_info

            candidate_raw = final_response_text or "".join(streamed_chunks)
            json_str = extract_first_json_object(candidate_raw)
            return response_model.model_validate_json(json_str), conv_id, usage_info
        finally:
            if schema_file and schema_file.exists():
                schema_file.unlink(missing_ok=True)


class DeterministicMockBackend:
    """
    离线确定性模型模拟桩，严格按 call_tag 与实时输入态势返回符合 Pydantic Schema 的公文与部署单。
    原因：支持无网络/零额度开销下毫秒级回归验证状态机全部分支与异常断言。
    """

    async def generate_structured(
        self,
        role_tier: str,
        call_tag: str,
        system_prompt: str,
        user_prompt: str,
        response_model: type[TModel],
        conversation_id: str | None = None,
        effort: Literal["low", "medium"] = "low",
        on_stream: StreamCallback | None = None,
    ) -> tuple[TModel, LLMCallMeta]:
        t0 = time.perf_counter()
        conv_id = conversation_id or "mock-conv-turn45-001"

        if call_tag == "ADVISOR_INITIAL_DRAFT":
            payload = {
                "advisor_brief_to_player": "第45回合北线态势平稳：建议派第1侦察队(101)先行向东北迷雾(16,18)探路，禁卫复合弓营(102)与北河长矛营(103)协同清剿(14,17)残血蛮族并跟进河岸高地。",
                "work_directive": {
                    "turn_number": 45,
                    "commander_intent_summary": "尖兵侦察先行探明东北战争迷雾，主力随后清理侧翼残余蛮族并推进占领北河丘陵要点。",
                    "theater_directives": [
                        {
                            "theater_id": "NORTH_RIVER_FRONT",
                            "priority": "HIGH",
                            "involved_unit_ids": [101, 102, 103],
                            "directive_text": "101侦察队沿(15,18)->(16,18)谨慎前出揭开东北迷雾；102复合弓远程清除(14,17)残血蛮族弓手，103长矛营推进掩护河岸高地。",
                        }
                    ],
                    "redline_constraints": [
                        "任何我方单位严禁孤军陷入敌方主力军团包围",
                        "侦察单位揭盲若发现2支及以上敌方正规军主力，必须立即停止东进并逐级上报请示",
                    ],
                },
                "next_handoff_draft": {
                    "from_turn": 45,
                    "long_term_strategy": "稳步控制北河丘陵视野，肃清边境威胁后护送移民建城。",
                    "active_operations": [
                        {
                            "op_name": "北河迷雾侦察与高地推进",
                            "assigned_unit_ids": [101, 102, 103],
                            "status": "PLANNED",
                            "next_turn_focus": "根据第45回合东北迷雾侦察结果决定继续前推或构筑防线。",
                        }
                    ],
                    "unresolved_threats": ["东北迷雾区潜在匈奴边境部队"],
                    "last_turn_execution_summary": "待本回合执行完毕后自动修订。",
                },
            }
            parsed = AdvisorProposalOutput.model_validate(payload)

        elif call_tag == "CHIEF_INITIAL_DISPATCH":
            payload = {
                "dispatch_summary": "按先侦察后主力原则拆分为2个有序任务包：TASK_T45_01由侦察兵101探明(16,18)迷雾；TASK_T45_02由复合弓102与矛兵103协同清除(14,17)残敌并跟进。",
                "tasks": [
                    {
                        "task_id": "TASK_T45_01",
                        "execution_order": 1,
                        "executor_type": "SCOUT_EXECUTOR",
                        "unit_ids": [101],
                        "tactical_posture": "RECON_CAUTIOUS",
                        "target_area": {"target_x": 16, "target_y": 18, "target_enemy_id": None},
                        "step_instruction": "第1侦察队(101)由(14,18)经(15,18)向(16,18)单步谨慎探路，遇2支以上敌军立即中止上报。",
                        "abort_on_new_enemy_count": 2,
                    },
                    {
                        "task_id": "TASK_T45_02",
                        "execution_order": 2,
                        "executor_type": "COMBAT_UNIT_EXECUTOR",
                        "unit_ids": [102, 103],
                        "tactical_posture": "ADVANCE",
                        "target_area": {"target_x": 15, "target_y": 18, "target_enemy_id": "63:501"},
                        "step_instruction": "主力梯队102与103在侦察确认安全后清剿侧翼蛮族并向(15,18)河岸高地推进。",
                        "abort_on_new_enemy_count": 2,
                    },
                ],
            }
            parsed = ChiefDispatchOutput.model_validate(payload)

        elif call_tag == "CHIEF_EVAL_ESCALATION_L2":
            payload = {
                "can_resolve_tactically": False,
                "chief_assessment": "侦察兵101在(16,18)揭盲发现3支满编匈奴正规军（2支骑射手+1支攻城槌），战力远超前锋梯队且直接触犯《工作文书》红线约束，参谋部无权继续执行原东进计划，立即转呈顾问请示玩家调整全局方针！",
                "replanned_tasks": [],
            }
            parsed = ChiefEscalationDecisionOutput.model_validate(payload)

        elif call_tag == "ADVISOR_ESCALATION_ALERT":
            payload = {
                "urgent_brief_to_player": "【紧急战略警报】第1侦察队(101)推进至(16,18)时揭开迷雾，正面遭遇匈奴主力兵团（骑射手x2、攻城槌x1）！侦察兵本回合移动力已耗尽，幸而主力复合弓(102)与长矛营(103)尚未前出。建议立即中止东进，转入河岸防线收缩并先清除侧翼残血蛮族。",
                "recommended_option_index": 0,
                "options_for_player": [
                    "A. 立即中止东进转入防御：102复合弓远程射击清除(14,17)侧翼蛮族，103长矛营抢占(14,18)河岸丘陵驻防掩护",
                    "B. 全线后撤至北京城郊(12,17)一线放弃河岸高地",
                    "C. 强行投入102与103向(16,18)迎击匈奴前锋",
                ],
            }
            parsed = AdvisorEscalationAlertOutput.model_validate(payload)

        elif call_tag == "ADVISOR_REVISED_DIRECTIVE":
            payload = {
                "advisor_brief_to_player": "已按指挥官决断签发修订版《工作文书》：放弃东进，101原地隐蔽待下回合撤回，102火力清除(14,17)蛮族消除侧翼隐患，103进占(14,18)河岸丘陵筑垒。",
                "work_directive": {
                    "turn_number": 45,
                    "commander_intent_summary": "应对东北匈奴主力逼近，全面中止东进扩张，收缩依托(14,18)河岸丘陵防线并肃清(14,17)侧翼残余蛮族。",
                    "theater_directives": [
                        {
                            "theater_id": "NORTH_RIVER_DEFENSE",
                            "priority": "CRITICAL",
                            "involved_unit_ids": [102, 103],
                            "directive_text": "禁卫复合弓营(102)原地对(14,17)残血蛮族弓箭手实施远程集火；北河长矛营(103)机动至(14,18)河岸丘陵驻扎构筑阻击阵地（101移动力已耗尽保持原地）。",
                        }
                    ],
                    "redline_constraints": [
                        "严禁主力越过(14,18)河岸防线向东冒进",
                        "必须在本回合彻底肃清(14,17)侧翼残血蛮族，防止腹背受敌",
                    ],
                },
                "next_handoff_draft": {
                    "from_turn": 45,
                    "long_term_strategy": "依托北河丘陵阻击匈奴主力南下，北京加速生产复合弓箭手增援前线。",
                    "active_operations": [
                        {
                            "op_name": "北河防线紧急阻击战",
                            "assigned_unit_ids": [101, 102, 103],
                            "status": "DEFENDING",
                            "next_turn_focus": "第46回合初接应101侦察队后撤过河，依托丘陵集火消耗来袭匈奴骑射手。",
                        }
                    ],
                    "unresolved_threats": [
                        "东北(17,17)~(18,18)方向3支满编匈奴主力军团（含攻城槌）即将压境"
                    ],
                    "last_turn_execution_summary": "侦察揭盲发现匈奴主力后及时刹车并调整部署。",
                },
            }
            parsed = AdvisorProposalOutput.model_validate(payload)

        elif call_tag == "CHIEF_REVISED_DISPATCH":
            payload = {
                "dispatch_summary": "根据防线收缩文书与现场状态（101已耗尽移动力），仅对剩余可行动的102与103编组2个有序任务包：先由102远程打击(14,17)残敌，再由103进占(14,18)河岸丘陵驻防。",
                "tasks": [
                    {
                        "task_id": "TASK_T45_03",
                        "execution_order": 1,
                        "executor_type": "COMBAT_UNIT_EXECUTOR",
                        "unit_ids": [102],
                        "tactical_posture": "FOCUS_FIRE",
                        "target_area": {"target_x": 14, "target_y": 17, "target_enemy_id": "63:501"},
                        "step_instruction": "复合弓102原地远程射击(14,17)残血蛮族弓手。",
                        "abort_on_new_enemy_count": 2,
                    },
                    {
                        "task_id": "TASK_T45_04",
                        "execution_order": 2,
                        "executor_type": "COMBAT_UNIT_EXECUTOR",
                        "unit_ids": [103],
                        "tactical_posture": "HOLD_DEFEND",
                        "target_area": {"target_x": 14, "target_y": 18, "target_enemy_id": None},
                        "step_instruction": "长矛营103移动至(14,18)河岸丘陵并就地驻扎防御。",
                        "abort_on_new_enemy_count": 2,
                    },
                ],
            }
            parsed = ChiefDispatchOutput.model_validate(payload)

        elif call_tag == "CHIEF_EVAL_ESCALATION_L1":
            payload = {
                "can_resolve_tactically": True,
                "chief_assessment": "102远程打击后(14,17)蛮族弓手仅剩6HP侥幸未死，属局部战术补刀范畴，未触犯战略红线，无需惊动顾问与玩家。立即将尚未行动的长矛营(103)改派经(14,18)突击收割(14,17)残敌！",
                "replanned_tasks": [
                    {
                        "task_id": "TASK_T45_04_REPLAN",
                        "execution_order": 1,
                        "executor_type": "COMBAT_UNIT_EXECUTOR",
                        "unit_ids": [103],
                        "tactical_posture": "FOCUS_FIRE",
                        "target_area": {"target_x": 14, "target_y": 17, "target_enemy_id": "63:501"},
                        "step_instruction": "长矛营103由(13,18)经(14,18)近战突击彻底歼灭(14,17)仅剩6HP的蛮族弓箭手，肃清侧翼威胁。",
                        "abort_on_new_enemy_count": 2,
                    }
                ],
            }
            parsed = ChiefEscalationDecisionOutput.model_validate(payload)

        else:
            raise ValueError(f"未知的确定性桩调用标签: {call_tag}")

        if on_stream is not None:
            await on_stream(role_tier, "TEXT", f"[{call_tag}] structured output ready")

        latency_ms = round((time.perf_counter() - t0) * 1000.0, 3)
        return parsed, LLMCallMeta(  # type: ignore[return-value]
            role_tier=role_tier,
            backend_used="deterministic-mock",
            latency_ms=latency_ms,
            conversation_id=conv_id,
        )
