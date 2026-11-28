# -*- coding: utf-8 -*-
"""
M1Sub3（调度控制子模块 CAB_Dispatcher）离线自动化验收入口。

做什么：基于本机 Python 与 lupa.lua51（标准 Lua 5.1，与《文明5：BNW》主版本一致）
依次执行三个阶段：
  1. 语法检查：用 Lua 5.1 loadstring 编译原型、M1Sub1、M1Sub2 与 M1Sub3 全部 Lua 文件，
     并执行 3 项负向语法自检（拒绝普通语法错误、Lua 5.2+ goto 与 Lua 5.3+ 整除 //）；
  2. 四模块联调桩测试：加载独立有状态 Civ5 BNW 引擎桩与 CAB_ExternalIO 契约模拟桩
     （tests/m1sub3/engine_stubs.lua）及用例集（tests/m1sub3/test_dispatcher.lua），
     在真实加载 CAB_Config + CAB_InfoCollector + CAB_TaskExecutor + CAB_Dispatcher
     的环境下核验状态机、生命周期、IPC 路由、异步结算与红线守卫；
  3. 汇总报告：打印通过/失败/跳过数及守卫/外部 IO 审计计数，并返回标准退出码。

运行方式（在项目根或任意目录均可）：
    python Civ5AgentBridge/tests/run_m1sub3_tests.py
    python Civ5AgentBridge/tests/run_m1sub3_tests.py --filter T-00

退出码：
    0 = 全部通过（且红线违规为 0、未实现方法调用为 0）
    1 = 存在语法检查或用例失败
    2 = 测试框架自身出错（如缺少 lupa 或顶层脚本异常）
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 项目根目录：Civ5AgentBridge/
PROJECT_ROOT = Path(__file__).resolve().parent.parent
STUB_FILE = "tests/m1sub3/engine_stubs.lua"
CASE_FILE = "tests/m1sub3/test_dispatcher.lua"

# 语法检查目标列表：(相对路径, 是否为检查器正样本)
# 正样本为已实机验证或已正式验收的原型、M1Sub1 与 M1Sub2 文件，必须存在且通过编译；
# 非正样本为 M1Sub3 产出或测试脚本，尚未创建时输出 [待创建] 而不判失败。
SYNTAX_TARGETS: list[tuple[str, bool]] = [
    ("mod/Lua/Civ5AgentBridgeCore.lua", True),
    ("mod/Lua/Civ5AgentBridgeJson.lua", True),
    ("mod/Lua/Civ5AgentBridgeLoader.lua", True),
    ("mod/Lua/Civ5AgentBridgeUI.lua", True),
    ("mod/Lua/CAB_Config.lua", True),
    ("mod/Lua/CAB_InfoCollector.lua", True),
    ("mod/Lua/CAB_TaskExecutor.lua", True),
    ("mod/Lua/CAB_Dispatcher.lua", False),
    (STUB_FILE, False),
    (CASE_FILE, False),
]

# 3 项负向语法自检样本：必须全部被 Lua 5.1 loadstring 拒绝
_NEGATIVE_SELFTESTS: list[tuple[str, str, str]] = [
    ("普通语法错误", "@selftest_syntax_err.lua", "local x = = 1\n"),
    ("Lua 5.2+ 专属语法 (goto)", "@selftest_lua52_goto.lua", "local function f() goto done ::done:: end\n"),
    ("Lua 5.3+ 整除运算符 (//)", "@selftest_lua53_idiv.lua", "local x = 5 // 2\n"),
]

# 包装 Lua 5.1 loadstring，恒定返回 (chunk_or_nil, err_or_nil) 二元组
_COMPILE_FN = "return function(src, name) local f, e = loadstring(src, name) return f, e end"


def _configure_stdio() -> None:
    """在非 TTY 管道环境下将标准输出/错误流切至 UTF-8，避免 Windows GBK 编码崩溃。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            is_utf8 = stream.encoding.lower().replace("-", "") == "utf8"
            if not stream.isatty() and not is_utf8:
                stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError, OSError):
            pass


def read_project_text(relpath: str) -> tuple[str | None, str | None]:
    """按项目根相对路径原样读取 UTF-8 文本，禁止越出项目根且不做换行/BOM 改写。"""
    path = (PROJECT_ROOT / relpath.replace("\\", "/")).resolve()
    if not path.is_relative_to(PROJECT_ROOT):
        return None, f"路径越出项目根: {relpath}"
    if not path.is_file():
        return None, f"文件不存在: {relpath}"
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            return handle.read(), None
    except (OSError, UnicodeDecodeError) as exc:
        return None, f"读取失败: {relpath}（{exc}）"


def make_compiler(lua):
    """构造 Lua 5.1 只编译不执行的函数 compile(src, name) -> (chunk, err)。"""
    return lua.execute(_COMPILE_FN)


def run_syntax_check(compile_lua) -> tuple[int, int, int]:
    """阶段 1：逐文件执行 Lua 5.1 语法编译检查，并跑完 3 项负向语法自检。"""
    passed = failed = pending = 0
    print("—— 阶段 1：语法检查（Lua 5.1）——")
    for relpath, is_selftest in SYNTAX_TARGETS:
        src, err = read_project_text(relpath)
        if src is None:
            if is_selftest:
                failed += 1
                print(f"  [失败] {relpath}：检查器正样本缺失（{err}）")
            else:
                pending += 1
                print(f"  [待创建] {relpath}")
            continue
        chunk, compile_err = compile_lua(src, "@" + relpath)
        if chunk is None:
            failed += 1
            print(f"  [失败] {relpath}")
            for line in str(compile_err).splitlines():
                print(f"          {line}")
        else:
            passed += 1
            print(f"  [通过] {relpath}")

    for label, chunk_name, bad_src in _NEGATIVE_SELFTESTS:
        chunk, _ = compile_lua(bad_src, chunk_name)
        if chunk is None:
            print(f"  [通过] 负向自检：{label}被正确拒绝")
        else:
            failed += 1
            print(f"  [失败] 负向自检：{label}未被拒绝，语法检查器不可信")
    return passed, failed, pending


def _lua_array(table) -> list:
    """将 Lua 1-based 连续数组安全转换为 Python 列表。"""
    items: list = []
    index = 1
    while table[index] is not None:
        items.append(table[index])
        index += 1
    return items


def run_stub_tests(lua, compile_lua, case_filter: str | None) -> tuple[int, int, int] | None:
    """阶段 2：在 Lua 5.1 沙箱内加载四模块联调引擎桩与用例文件并打印逐条结果。"""
    print("—— 阶段 2：四模块联调引擎桩测试 ——")
    stub_src, _ = read_project_text(STUB_FILE)
    case_src, _ = read_project_text(CASE_FILE)
    if stub_src is None or case_src is None:
        missing = STUB_FILE if stub_src is None else CASE_FILE
        print(f"  [待创建] {missing}")
        return None

    lua.globals().__py_read_file = read_project_text
    lua.globals().__py_case_filter = case_filter

    stub_chunk, stub_err = compile_lua(stub_src, "@" + STUB_FILE)
    if stub_chunk is None:
        print(f"  [失败] {STUB_FILE} 编译失败：{stub_err}")
        return 0, 1, 0
    stub_chunk()

    case_chunk, case_err = compile_lua(case_src, "@" + CASE_FILE)
    if case_chunk is None:
        print(f"  [失败] {CASE_FILE} 编译失败：{case_err}")
        return 0, 1, 0
    summary = case_chunk()
    if summary is None:
        print("  [失败] 用例文件未返回汇总表")
        return 0, 1, 0

    passed = failed = skipped = 0
    for case in _lua_array(summary["cases"]):
        status = case["status"]
        title = case["title"] or ""
        if status == "pass":
            passed += 1
            print(f"  [通过] {case['id']}  {title}")
        elif status == "skip":
            skipped += 1
            print(f"  [跳过] {case['id']}  {title}（{case['message']}）")
        else:
            failed += 1
            print(f"  [失败] {case['id']}  {title}")
            for line in str(case["message"] or "").splitlines():
                print(f"          {line}")
    print(
        f"  守卫审计累计：红线违规 {summary['guardViolations']} 次，"
        f"桩未实现方法 {summary['guardMissing']} 次，"
        f"有效写操作记录 {summary['totalWrites']} 次"
    )
    print(
        f"  外部IO审计：  态势推送 {summary['extOverviewCount']} 次，"
        f"心跳写入 {summary['extHeartbeatCount']} 次，"
        f"RPC 响应 {summary['extRpcResponseCount']} 次，"
        f"入站轮询 {summary['extPollCount']} 次"
    )
    return passed, failed, skipped


def parse_args(argv: list[str]) -> argparse.Namespace:
    """解析命令行参数。"""
    parser = argparse.ArgumentParser(
        description="M1Sub3 (CAB_Dispatcher) Lua 5.1 语法检查与四模块联调引擎桩测试入口"
    )
    parser.add_argument(
        "--filter",
        dest="case_filter",
        default=None,
        help="仅运行用例 ID 或标题包含该子串的用例（如 --filter T-00）",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    """主入口：初始化 lupa.lua51 运行时，串行执行三阶段并输出退出码。"""
    _configure_stdio()
    args = parse_args(argv)

    try:
        from lupa import lua51
    except ImportError as exc:
        print(f"无法导入 lupa.lua51：{exc}")
        print("请确认本机 Python 已安装 lupa（pip install lupa）。")
        return 2

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    compile_lua = make_compiler(lua)

    try:
        syn_passed, syn_failed, syn_pending = run_syntax_check(compile_lua)
        stub_result = run_stub_tests(lua, compile_lua, args.case_filter)
    except lua51.LuaError as exc:
        print(f"  [失败] 测试框架出错：{exc}")
        print("—— 汇总 ——")
        print("结果：测试框架出错（见上方 Lua 错误与调用栈）")
        print("退出码：2")
        return 2

    if stub_result is None:
        case_passed = case_failed = case_skipped = 0
    else:
        case_passed, case_failed, case_skipped = stub_result

    print("—— 汇总 ——")
    print(f"语法检查：通过 {syn_passed}，失败 {syn_failed}，待创建 {syn_pending}")
    if stub_result is None:
        print("桩测试：  待创建")
    else:
        total_cases = case_passed + case_failed + case_skipped
        print(
            f"桩测试：  通过 {case_passed}，失败 {case_failed}，跳过 {case_skipped}"
            f"（共 {total_cases} 条）"
        )

    total_failed = syn_failed + case_failed
    if total_failed == 0:
        print("结果：全部通过")
        print("退出码：0")
        return 0
    print(f"结果：存在失败（共 {total_failed} 项）")
    print("退出码：1")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
