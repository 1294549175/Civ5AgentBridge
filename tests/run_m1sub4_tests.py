# -*- coding: utf-8 -*-
"""
M1Sub4（外部交互子模块 CAB_ExternalIO + CAB_Json 与最终壳层合龙）离线自动化验收入口。

做什么：基于本机 Python、lupa.lua51（标准 Lua 5.1，与《文明5：BNW》主版本一致）与标准库
sqlite3，依次执行三个阶段：
  1. 语法检查：用 Lua 5.1 loadstring 编译全部 Mod 与 M1Sub4 测试 Lua 文件，并执行 3 项
     负向语法自检（拒绝普通语法错误、Lua 5.2+ goto 与 Lua 5.3+ 整除 //）；
  2. 真实 SQLite3 跨语言测试：在临时目录中建立真实 SQLite SimpleValues 数据库，将底层
     跨语言读写桥接函数注入 Lua 5.1 沙箱，加载 tests/m1sub4/db_stubs.lua 与
     tests/m1sub4/test_external_io.lua 执行 CAB_Json 加固单测、CAB_ExternalIO 通信协议
     测试及后续合龙全栈联调；
  3. 汇总报告：打印逐条用例结果、红线守卫与真实 SQLite 读写审计统计，返回标准退出码。

为什么采用真实 Python sqlite3 + Hex 原始字节桥 + CAST(? AS TEXT)：
  原生《文明5》C++ Modding.OpenUserData 直接将 Lua 原始字节流写入 SQLite TEXT 槽位；
  本后端通过无损十六进制字节桥将 Lua 原始字节传给 Python，再用 SQLite CAST(? AS TEXT)
  落盘，既保留 lupa.lua51 默认 UTF-8 友好的测试交互体验，又能 100% 真实复现“写入残缺
  UTF-8 切片时 Python 默认 text_factory=str 触发 sqlite3.OperationalError”的真机现象。

运行方式（在项目根或任意目录均可）：
    python Civ5AgentBridge/tests/run_m1sub4_tests.py
    python Civ5AgentBridge/tests/run_m1sub4_tests.py --filter T-03

退出码：
    0 = 全部通过（且红线违规为 0、未实现方法调用为 0）
    1 = 存在语法检查或用例失败
    2 = 测试框架自身出错（如缺少 lupa 或顶层脚本异常）
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import tempfile
from pathlib import Path

# 项目根目录：Civ5AgentBridge/
PROJECT_ROOT = Path(__file__).resolve().parent.parent
STUB_FILE = "tests/m1sub4/db_stubs.lua"
CASE_FILE = "tests/m1sub4/test_external_io.lua"

# 语法检查目标列表：(相对路径, 是否为检查器正样本)
# 正样本为已实证或已正式验收的前序文件，必须存在且通过 Lua 5.1 编译；
# 非正样本为 M1Sub4 分包逐步交付的目标文件，尚未创建时输出 [待创建] 而不判失败。
SYNTAX_TARGETS: list[tuple[str, bool]] = [
    ("mod/Lua/Civ5AgentBridgeCore.lua", True),
    ("mod/Lua/Civ5AgentBridgeJson.lua", True),
    ("mod/Lua/Civ5AgentBridgeLoader.lua", True),
    ("mod/Lua/Civ5AgentBridgeUI.lua", True),
    ("mod/Lua/CAB_Config.lua", True),
    ("mod/Lua/CAB_InfoCollector.lua", True),
    ("mod/Lua/CAB_TaskExecutor.lua", True),
    ("mod/Lua/CAB_Dispatcher.lua", True),
    ("mod/Lua/CAB_ExternalIO.lua", False),
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


class SqliteTestBackend:
    """
    真实临时 SQLite3 SimpleValues 跨语言测试后端。

    每个测试用例通过 reset() 隔离临时目录内的 .db 文件，完整复现《文明5》
    Modding.OpenUserData(dbName, dbVersion) 对应的 SimpleValues(Name TEXT Primary Key, Value VARIANT)
    存储结构，并提供 Python 侧严格 UTF-8 文本读取与 bytes 拼片读取双通道验证接口。
    """

    def __init__(self, lua) -> None:
        self._lua = lua
        self._temp_dir = tempfile.TemporaryDirectory(prefix="cab_m1sub4_")
        self._root = Path(self._temp_dir.name)
        self._handles: dict[int, Path] = {}
        self._next_handle_id = 1

    def close(self) -> None:
        """销毁临时目录与全部临时数据库文件。"""
        self._handles.clear()
        self._temp_dir.cleanup()

    def reset(self) -> None:
        """清空临时目录中的全部 .db 文件与句柄映射，实现用例级数据库完全隔离。"""
        self._handles.clear()
        self._next_handle_id = 1
        for item in self._root.iterdir():
            if item.is_file():
                try:
                    item.unlink()
                except OSError:
                    pass

    def _connect(self, db_path: Path, text_factory=str) -> sqlite3.Connection:
        conn = sqlite3.connect(str(db_path), timeout=10.0, isolation_level=None)
        conn.text_factory = text_factory
        conn.execute(
            "CREATE TABLE IF NOT EXISTS SimpleValues(Name TEXT Primary Key, Value VARIANT)"
        )
        return conn

    def _get_path(self, handle_id: int) -> Path:
        path = self._handles.get(int(handle_id))
        if path is None:
            raise ValueError(f"无效的 SQLite 句柄 ID: {handle_id}")
        return path

    def open_db(self, db_name: str, db_version: int) -> tuple[int, str]:
        """创建或打开 <temp>/<dbName>-<dbVersion>.db 并确保 SimpleValues 表存在。"""
        safe_name = "".join(ch if ch.isalnum() or ch in ("_", "-") else "_" for ch in str(db_name))
        db_path = self._root / f"{safe_name}-{int(db_version)}.db"
        conn = self._connect(db_path)
        conn.close()
        handle_id = self._next_handle_id
        self._next_handle_id += 1
        self._handles[handle_id] = db_path
        return handle_id, str(db_path)

    def set_value(self, handle_id: int, key: str, val_type: str, val_payload) -> bool:
        """向 SimpleValues 表写入单个键值，字符串通过 CAST(? AS TEXT) 保留原始字节。"""
        db_path = self._get_path(handle_id)
        conn = self._connect(db_path)
        try:
            if val_type == "nil":
                conn.execute("DELETE FROM SimpleValues WHERE Name = ?", (str(key),))
            elif val_type == "string_hex":
                raw = bytes.fromhex(str(val_payload or ""))
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, CAST(? AS TEXT))",
                    (str(key), raw),
                )
            elif val_type == "number":
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (str(key), val_payload),
                )
            elif val_type == "boolean":
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (str(key), 1 if bool(val_payload) else 0),
                )
            else:
                raise ValueError(f"不支持的 SetValue 类型标记: {val_type}")
            return True
        finally:
            conn.close()

    def get_value(self, handle_id: int, key: str) -> tuple[str, object]:
        """使用 text_factory=bytes 读取单键，确保即便库内含非 UTF-8 原始字节也能无损回传 Lua。"""
        db_path = self._get_path(handle_id)
        conn = self._connect(db_path, text_factory=bytes)
        try:
            row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?", (str(key),)
            ).fetchone()
            if row is None or row[0] is None:
                return "nil", None
            val = row[0]
            if isinstance(val, (bytes, bytearray)):
                return "string_hex", bytes(val).hex()
            if isinstance(val, (int, float)):
                return "number", val
            return "string_hex", str(val).encode("utf-8").hex()
        finally:
            conn.close()

    def delete_key(self, handle_id: int, key: str) -> bool:
        """删除 SimpleValues 表中的指定键（用于模拟分片缺失等故障场景）。"""
        db_path = self._get_path(handle_id)
        conn = self._connect(db_path)
        try:
            conn.execute("DELETE FROM SimpleValues WHERE Name = ?", (str(key),))
            return True
        finally:
            conn.close()

    def list_keys(self, handle_id: int):
        """返回 SimpleValues 表内全部有序键名（作为 Lua 1-based 数组表）。"""
        db_path = self._get_path(handle_id)
        conn = self._connect(db_path)
        try:
            rows = conn.execute("SELECT Name FROM SimpleValues ORDER BY Name ASC").fetchall()
            return self._lua.table(*(str(r[0]) for r in rows))
        finally:
            conn.close()

    def read_text_strict(self, handle_id: int, key: str) -> tuple[bool, object]:
        """使用 Python 默认 text_factory=str 读取单键；非法 UTF-8 将真实触发 OperationalError。"""
        db_path = self._get_path(handle_id)
        conn = self._connect(db_path, text_factory=str)
        try:
            row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?", (str(key),)
            ).fetchone()
            if row is None or row[0] is None:
                return True, None
            return True, row[0]
        except Exception as exc:
            return False, f"{type(exc).__name__}: {exc}"
        finally:
            conn.close()

    def read_chunked_bytes(self, handle_id: int, key: str) -> tuple[bool, object, int, int]:
        """
        Python 正式客户端等价拼片读取器（text_factory=bytes）：
        先读 <key>#chunk_count，再按 1..N 拼接原始字节并统一 UTF-8 解码。
        返回：(ok, decoded_str_or_err, raw_byte_len, chunk_count)。
        """
        db_path = self._get_path(handle_id)
        conn = self._connect(db_path, text_factory=bytes)
        try:
            cnt_row = conn.execute(
                "SELECT Value FROM SimpleValues WHERE Name = ?",
                (f"{key}#chunk_count",),
            ).fetchone()
            chunk_count = 0
            if cnt_row is not None and cnt_row[0] is not None:
                cnt_raw = cnt_row[0]
                cnt_str = cnt_raw.decode("utf-8", errors="replace") if isinstance(cnt_raw, bytes) else str(cnt_raw)
                if cnt_str.isdigit():
                    chunk_count = int(cnt_str)

            if chunk_count > 0:
                parts: list[bytes] = []
                for idx in range(1, chunk_count + 1):
                    crow = conn.execute(
                        "SELECT Value FROM SimpleValues WHERE Name = ?",
                        (f"{key}#chunk_{idx}",),
                    ).fetchone()
                    if crow is None or crow[0] is None:
                        return False, f"Missing chunk #{idx} of {chunk_count}", 0, chunk_count
                    val = crow[0]
                    parts.append(val if isinstance(val, bytes) else str(val).encode("utf-8"))
                raw = b"".join(parts)
            else:
                vrow = conn.execute(
                    "SELECT Value FROM SimpleValues WHERE Name = ?",
                    (str(key),),
                ).fetchone()
                if vrow is None or vrow[0] is None:
                    return True, None, 0, 0
                val = vrow[0]
                raw = val if isinstance(val, bytes) else str(val).encode("utf-8")

            try:
                decoded = raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                return False, f"UnicodeDecodeError: {exc}", len(raw), chunk_count
            return True, decoded, len(raw), chunk_count
        except Exception as exc:
            return False, f"{type(exc).__name__}: {exc}", 0, 0
        finally:
            conn.close()

    def write_payload_py(
        self,
        handle_id: int,
        key: str,
        raw_hex: str,
        chunk_size: int = 3000,
        force_chunked: bool = False,
    ) -> int:
        """
        Python 侧向 SimpleValues 写入载荷（按 UTF-8 首字节边界对齐分片），
        供双向跨语言测试检验 Lua CAB_ExternalIO.ReadPayload 还原能力。返回写入分片数。
        """
        db_path = self._get_path(handle_id)
        raw = bytes.fromhex(str(raw_hex or ""))
        csize = max(4, int(chunk_size or 3000))
        conn = self._connect(db_path)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if force_chunked or len(raw) > csize:
                if len(raw) == 0:
                    conn.execute(
                        "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, CAST(? AS TEXT))",
                        (f"{key}#chunk_1", b""),
                    )
                    conn.execute(
                        "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                        (f"{key}#chunk_count", "1"),
                    )
                    conn.execute(
                        "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                        (str(key), "__CHUNKED__:0"),
                    )
                    conn.execute("COMMIT")
                    return 1
                start = 0
                idx = 0
                total_len = len(raw)
                while start < total_len:
                    end = min(start + csize, total_len)
                    if end < total_len:
                        back = 0
                        while end > start and back < 3 and (0x80 <= raw[end] <= 0xBF):
                            end -= 1
                            back += 1
                        if end <= start:
                            end = min(start + csize, total_len)
                    idx += 1
                    conn.execute(
                        "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, CAST(? AS TEXT))",
                        (f"{key}#chunk_{idx}", raw[start:end]),
                    )
                    start = end
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (f"{key}#chunk_count", str(idx)),
                )
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (str(key), f"__CHUNKED__:{total_len}"),
                )
                conn.execute("COMMIT")
                return idx
            else:
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, CAST(? AS TEXT))",
                    (str(key), raw),
                )
                conn.execute(
                    "INSERT OR REPLACE INTO SimpleValues (Name, Value) VALUES (?, ?)",
                    (f"{key}#chunk_count", "0"),
                )
                conn.execute("COMMIT")
                return 0
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    @staticmethod
    def json_loads_check(json_str: str) -> tuple[bool, str]:
        """用 Python 标准库 json.loads 交叉校验 Lua CAB_Json.Encode 输出的 RFC 8259 合规性。"""
        try:
            parsed = json.loads(str(json_str))
            return True, type(parsed).__name__
        except Exception as exc:
            return False, f"{type(exc).__name__}: {exc}"


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


def run_stub_tests(
    lua,
    compile_lua,
    backend: SqliteTestBackend,
    case_filter: str | None,
) -> tuple[int, int, int] | None:
    """阶段 2：注入真实 SQLite3 桥接后端并运行 M1Sub4 桩测试与用例集。"""
    print("—— 阶段 2：真实 SQLite3 跨语言桩测试 ——")
    stub_src, _ = read_project_text(STUB_FILE)
    case_src, _ = read_project_text(CASE_FILE)
    if stub_src is None or case_src is None:
        missing = STUB_FILE if stub_src is None else CASE_FILE
        print(f"  [待创建] {missing}")
        return None

    g = lua.globals()
    g.__py_read_file = read_project_text
    g.__py_case_filter = case_filter
    g.__py_db_reset = backend.reset
    g.__py_db_open = backend.open_db
    g.__py_db_set_value = backend.set_value
    g.__py_db_get_value = backend.get_value
    g.__py_db_delete_key = backend.delete_key
    g.__py_db_list_keys = backend.list_keys
    g.__py_db_read_text_strict = backend.read_text_strict
    g.__py_db_read_chunked_bytes = backend.read_chunked_bytes
    g.__py_db_write_payload_py = backend.write_payload_py
    g.__py_json_loads_check = backend.json_loads_check

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
        f"桩未实现方法 {summary['guardMissing']} 次"
    )
    print(
        f"  真实DB审计：  建库/打开 {summary['totalOpens']} 次，"
        f"SetValue {summary['totalDbWrites']} 次，"
        f"GetValue {summary['totalDbReads']} 次"
    )
    return passed, failed, skipped


def parse_args(argv: list[str]) -> argparse.Namespace:
    """解析命令行参数。"""
    parser = argparse.ArgumentParser(
        description="M1Sub4 (CAB_Json + CAB_ExternalIO + 最终壳层合龙) Lua 5.1 语法检查与真实 SQLite3 离线测试入口"
    )
    parser.add_argument(
        "--filter",
        dest="case_filter",
        default=None,
        help="仅运行用例 ID 或标题包含该子串的用例（如 --filter T-03）",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    """主入口：初始化 lupa.lua51 与真实 SQLite3 临时库后端，串行执行三阶段并输出退出码。"""
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
    backend = SqliteTestBackend(lua)

    try:
        try:
            syn_passed, syn_failed, syn_pending = run_syntax_check(compile_lua)
            stub_result = run_stub_tests(lua, compile_lua, backend, args.case_filter)
        except lua51.LuaError as exc:
            print(f"  [失败] 测试框架出错：{exc}")
            print("—— 汇总 ——")
            print("结果：测试框架出错（见上方 Lua 错误与调用栈）")
            print("退出码：2")
            return 2
    finally:
        backend.close()

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
