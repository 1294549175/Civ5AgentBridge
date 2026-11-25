# -*- coding: utf-8 -*-
"""
子模块 1（游戏内信息收集子模块 CAB_Collector）桩测试入口。

做什么：依次执行三个阶段——
  1. 语法检查：用 lupa.lua51（内置 Lua 5.1，与游戏同主版本）编译原型与新增的 Lua 文件；
  2. 桩测试：加载 tests/m1sub1/engine_stubs.lua（引擎桩）与 test_collector.lua（用例），取回结果；
  3. 汇总：打印通过与失败数，有失败时退出码非 0。

为什么用 lupa：本机没有独立 Lua 解释器，而游戏的脚本环境是 Lua 5.1；
    lupa 自带标准 Lua 5.1，能做真实编译，而不是只做文本解析。

注意：桩测试验证的是本模块的逻辑，不是引擎的真实行为。桩测试通过不等于实机验证通过，
    二者不是一回事（计划 §9.6 的 R-9）。

运行方式（在项目根下）：
    .venv\\Scripts\\python.exe tests\\run_m1sub1_tests.py

退出码：0 = 全部通过；1 = 存在失败；2 = 测试框架自身出错。
"""

from __future__ import annotations

import sys
from pathlib import Path

# 项目根 = 本文件所在目录的上一级
PROJECT_ROOT = Path(__file__).resolve().parent.parent
STUB_FILE = "tests/m1sub1/engine_stubs.lua"
CASE_FILE = "tests/m1sub1/test_collector.lua"

# 语法检查对象。(相对路径, 是否为检查器自检对象)
# 自检对象是已实机验证的原型文件：它们必须通过，否则说明检查器本身坏了。
# 另一类是本子模块新增的文件：尚不存在时打印“待创建”，不判失败。
SYNTAX_TARGETS: list[tuple[str, bool]] = [
    ("mod/Lua/Civ5AgentBridgeCore.lua", True),
    ("mod/Lua/Civ5AgentBridgeJson.lua", True),
    ("mod/Lua/Civ5AgentBridgeLoader.lua", True),
    ("mod/Lua/Civ5AgentBridgeUI.lua", True),
    ("mod/Lua/CAB_Config.lua", False),
    ("mod/Lua/CAB_InfoCollector.lua", False),
    (STUB_FILE, False),
    (CASE_FILE, False),
]

# 负向自检样本：必须被检查器拒绝，用来证明检查器“查得出错”，而不是只会放行。
_SELFTEST_BAD = "local x = = 1\n"


def _configure_stdio() -> None:
    """把标准输出与标准错误切到 UTF-8。

    为什么：输出里有中文。在 Git Bash 等管道环境下，Windows 默认用本地代码页（GBK）编码输出，
    遇到不在其中的符号会抛 UnicodeEncodeError 让测试中途崩溃。
    真正的控制台保持 Python 自带的原生 Unicode 通道不动。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            is_utf8 = stream.encoding.lower().replace("-", "") == "utf8"
            if not stream.isatty() and not is_utf8:
                stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError, OSError):
            # 无法重配置时保持原样：个别字符显示异常不影响测试结论
            pass


def read_project_text(relpath: str) -> tuple[str | None, str | None]:
    """按项目根的相对路径读取文本，原样保留内容。

    做什么：以 UTF-8 严格解码读取文件，不转换换行、不剥离 BOM。
    为什么：游戏编译的就是磁盘上的那份字节。这里做任何“修正”（例如去掉 BOM），
        都可能让一份在游戏里加载失败的文件在这里显示通过。
    输入：relpath，相对项目根的路径，正斜杠分隔。
    输出：(内容, None) 或 (None, 错误说明)。
    """
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


_COMPILE_FN = "return function(src, name) local f, e = loadstring(src, name) return f, e end"


def make_compiler(lua):
    """造一个“编译器”：用 Lua 5.1 的 loadstring 编译源码，只编译不执行。

    做什么：返回一个 Python 可调用的编译函数 compile(src, name)。
    为什么多包一层 Lua 函数：loadstring 成功时只返回 1 个值（函数），失败时才返回 2 个值；
        直接从 Python 调它，返回值形态不稳定。包一层后恒返回两个值，调用处不用分支判断。
    为什么不直接用 loadfile：项目路径含空格和撇号，在其他机器上还可能含非 ASCII 字符，
        C 运行库打开这类路径时的编码行为不可控；由 Python 读文件可以绕开这个不确定性。
    """
    # 用 execute 而不是 eval：eval 只接受表达式，不接受以 return 开头的语句块
    return lua.execute(_COMPILE_FN)


def run_syntax_check(compile_lua) -> tuple[int, int, int]:
    """阶段 1：语法检查。

    做什么：逐个编译 SYNTAX_TARGETS 里的文件；最后用一段故意写错的代码做负向自检。
    输入：compile_lua，make_compiler 返回的编译函数。
    输出：返回 (通过数, 失败数, 待创建数)。
    """
    passed = failed = pending = 0
    print("—— 阶段 1：语法检查（Lua 5.1）——")
    for relpath, is_selftest in SYNTAX_TARGETS:
        src, err = read_project_text(relpath)
        if src is None:
            if is_selftest:
                # 自检对象缺失，检查器无从证明自己可用，按失败处理
                failed += 1
                print(f"  [失败] {relpath}：检查器自检对象缺失（{err}）")
            else:
                pending += 1
                print(f"  [待创建] {relpath}")
            continue
        chunk, compile_err = compile_lua(src, relpath)
        if chunk is None:
            failed += 1
            print(f"  [失败] {relpath}")
            for line in str(compile_err).splitlines():
                print(f"          {line}")
        else:
            passed += 1
            print(f"  [通过] {relpath}")

    # 负向自检：检查器必须拒绝坏代码，否则“全部通过”没有意义
    chunk, compile_err = compile_lua(_SELFTEST_BAD, "@selftest_bad.lua")
    if chunk is None:
        print("  [通过] 检查器负向自检（坏代码被正确拒绝）")
    else:
        failed += 1
        print("  [失败] 检查器负向自检：坏代码未被拒绝，语法检查结果不可信")
    return passed, failed, pending


def _lua_array(table) -> list:
    """把 Lua 的连续数组（下标从 1 起）转成 Python 列表。

    为什么：lupa 的 len() 只按 Lua 的边界规则计数，对含 [0] 或字符串键的表不可靠；
        用 nil 作终点逐个取值最稳。
    """
    items: list = []
    index = 1
    while table[index] is not None:
        items.append(table[index])
        index += 1
    return items


def run_stub_tests(lua, compile_lua) -> tuple[int, int, int] | None:
    """阶段 2：桩测试。

    做什么：注册 include 垫片要用的读文件回调，依次执行引擎桩与用例文件，取回汇总表并逐条打印。
    输入：lua，Lua 运行时；compile_lua，make_compiler 返回的编译函数。
    输出：返回 (通过数, 失败数, 跳过数)；桩文件或用例文件尚不存在时返回 None（待创建）。
    """
    print("—— 阶段 2：桩测试 ——")
    stub_src, _ = read_project_text(STUB_FILE)
    case_src, _ = read_project_text(CASE_FILE)
    if stub_src is None or case_src is None:
        missing = STUB_FILE if stub_src is None else CASE_FILE
        print(f"  [待创建] {missing}")
        return None

    # include 垫片的回调：Lua 侧按“项目根相对路径”取源码，拿不到时得到 (nil, 错误说明)
    lua.globals().__py_read_file = read_project_text

    stub_chunk, stub_compile_err = compile_lua(stub_src, STUB_FILE)
    if stub_chunk is None:
        print(f"  [失败] {STUB_FILE} 编译失败：{stub_compile_err}")
        return 0, 1, 0
    stub_chunk()

    case_chunk, case_compile_err = compile_lua(case_src, CASE_FILE)
    if case_chunk is None:
        print(f"  [失败] {CASE_FILE} 编译失败：{case_compile_err}")
        return 0, 1, 0
    summary = case_chunk()
    if summary is None:
        print("  [失败] 用例文件没有返回汇总表")
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
    print(f"  只读守卫累计：写入类调用 {summary['guardViolations']} 次，桩未实现的方法 {summary['guardMissing']} 次")
    return passed, failed, skipped


def main(argv: list[str]) -> int:
    """入口：建 Lua 运行时，依次跑三个阶段，按结果设置退出码。

    输入：argv，命令行参数（当前不使用，保留以便日后加过滤参数）。
    输出：退出码。0 = 全部通过；1 = 存在失败；2 = 测试框架自身出错。
    """
    _configure_stdio()
    try:
        from lupa import lua51
    except ImportError as exc:
        print(f"无法导入 lupa：{exc}")
        print("请先在项目根下执行：.venv\\Scripts\\python.exe -m pip install lupa")
        return 2

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    compile_lua = make_compiler(lua)

    try:
        syn_passed, syn_failed, syn_pending = run_syntax_check(compile_lua)
        stub_result = run_stub_tests(lua, compile_lua)
    except lua51.LuaError as exc:
        # 桩文件或用例文件在顶层崩溃，属于测试框架自身的问题
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
        print(
            f"桩测试：  通过 {case_passed}，失败 {case_failed}，跳过 {case_skipped}"
            f"（共 {case_passed + case_failed + case_skipped} 条）"
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
