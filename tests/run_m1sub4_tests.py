# -*- coding: utf-8 -*-
"""
M1Sub4（外部交互子模块 CAB_ExternalIO + CAB_Json 与最终壳层合龙）离线自动化验收入口。

做什么：基于本机 Python、lupa.lua51（标准 Lua 5.1，与《文明5：BNW》主版本一致）与标准库
sqlite3 / xml.etree.ElementTree，依次执行四个阶段：
  1. 语法检查：用 Lua 5.1 loadstring 编译全部 13 个 Mod 与 M1Sub4 测试 Lua 文件，并执行
     3 项负向语法自检（拒绝普通语法错误、Lua 5.2+ goto 与 Lua 5.3+ 整除 //）；
  2. .modinfo 与退役存根结构校验（A-06）：解析 mod/Civ5AgentBridge.modinfo XML，核验
     10 文件正式 VFS 清单（全 import="1"、正斜杠、磁盘存在、移除 Core）、空壳 Loader
     入口、AffectsSavedGames=0 及 Civ5AgentBridgeCore.lua 纯注释退役存根合规性；
  3. 外部交互与 JSON 真实 SQLite3 跨语言单测（WP1~WP2，T-00 ~ T-15）：在独立 Lua 5.1
     沙箱中对接真实 SQLite SimpleValues 临时库与红线 I-01 写接口陷阱守卫，运行
     tests/m1sub4/db_stubs.lua 与 tests/m1sub4/test_external_io.lua；
  4. 五模块 + UI 壳层真实 SQLite3 全栈端到端联调（WP3，T-16 ~ T-22）：在第二个隔离
     Lua 5.1 沙箱中只读复用 BNW 引擎世界桩并叠加真实 SQLite3 与 Civ5 UI 宿主桩，冷加载
     Civ5AgentBridgeUI.lua 驱动全部 6 个正式模块完成全链路闭环验证。

为什么采用真实 Python sqlite3 + Hex 原始字节桥 + CAST(? AS TEXT)：
  原生《文明5》C++ Modding.OpenUserData 直接将 Lua 原始字节流写入 SQLite TEXT 槽位；
  本后端通过无损十六进制字节桥将 Lua 原始字节传给 Python，再用 SQLite CAST(? AS TEXT)
  落盘，既保留 lupa.lua51 默认 UTF-8 友好的测试交互体验，又能 100% 真实复现“写入残缺
  UTF-8 切片时 Python 默认 text_factory=str 触发 sqlite3.OperationalError”的真机现象。

运行方式（在项目根或任意目录均可）：
    python Civ5AgentBridge/tests/run_m1sub4_tests.py
    python Civ5AgentBridge/tests/run_m1sub4_tests.py --filter T-03
    python Civ5AgentBridge/tests/run_m1sub4_tests.py --filter T-19

退出码：
    0 = 全部通过（且红线违规为 0、未实现方法调用为 0）
    1 = 存在语法检查、.modinfo 校验或用例失败
    2 = 测试框架自身出错（如缺少 lupa 或顶层脚本异常）
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

# 项目根目录：Civ5AgentBridge/
PROJECT_ROOT = Path(__file__).resolve().parent.parent
STUB_FILE = "tests/m1sub4/db_stubs.lua"
CASE_FILE = "tests/m1sub4/test_external_io.lua"
FULLSTACK_STUB_FILE = "tests/m1sub4/fullstack_stubs.lua"
FULLSTACK_CASE_FILE = "tests/m1sub4/test_fullstack.lua"

# 语法检查目标列表（全量 13 文件）：(相对路径, 是否为检查器正样本)
SYNTAX_TARGETS: list[tuple[str, bool]] = [
    ("mod/Lua/Civ5AgentBridgeCore.lua", True),
    ("mod/Lua/Civ5AgentBridgeJson.lua", True),
    ("mod/Lua/Civ5AgentBridgeLoader.lua", True),
    ("mod/Lua/Civ5AgentBridgeUI.lua", True),
    ("mod/Lua/CAB_Config.lua", True),
    ("mod/Lua/CAB_InfoCollector.lua", True),
    ("mod/Lua/CAB_TaskExecutor.lua", True),
    ("mod/Lua/CAB_Dispatcher.lua", True),
    ("mod/Lua/CAB_ExternalIO.lua", True),
    (STUB_FILE, True),
    (CASE_FILE, True),
    (FULLSTACK_STUB_FILE, True),
    (FULLSTACK_CASE_FILE, True),
]

# 正式合龙 10 个 VFS 文件清单（严格对齐决策 D-02 / D-05 与《M1Sub4工作计划.md》§4.3）
EXPECTED_MODINFO_FILES: list[str] = [
    "Lua/CAB_Config.lua",
    "Lua/Civ5AgentBridgeJson.lua",
    "Lua/CAB_ExternalIO.lua",
    "Lua/CAB_InfoCollector.lua",
    "Lua/CAB_TaskExecutor.lua",
    "Lua/CAB_Dispatcher.lua",
    "Lua/Civ5AgentBridgeUI.xml",
    "Lua/Civ5AgentBridgeUI.lua",
    "Lua/Civ5AgentBridgeLoader.lua",
    "Lua/Civ5AgentBridgeLoader.xml",
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


def run_modinfo_validation() -> tuple[int, int]:
    """阶段 2：校验 mod/Civ5AgentBridge.modinfo XML 装配规范与 Core 退役存根合规性（A-06）。"""
    passed = failed = 0
    print("—— 阶段 2：.modinfo XML 结构与退役存根校验（A-06）——")

    def check(label: str, cond: bool, detail: str = "") -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"  [通过] {label}")
        else:
            failed += 1
            msg = f"（{detail}）" if detail else ""
            print(f"  [失败] {label}{msg}")

    modinfo_src, err = read_project_text("mod/Civ5AgentBridge.modinfo")
    if modinfo_src is None:
        check("读取 mod/Civ5AgentBridge.modinfo", False, str(err))
        return passed, failed

    try:
        root = ET.fromstring(modinfo_src)
        check("XML 格式合法", root.tag == "Mod", f"根标签={root.tag}")
    except ET.ParseError as exc:
        check("XML 格式合法", False, str(exc))
        return passed, failed

    check(
        "Mod UUID 与版本号一致",
        root.attrib.get("id") == "c5a8b901-71d5-48fa-9d32-b265eb5fd373"
        and root.attrib.get("version") == "1",
        f"attrib={root.attrib}",
    )

    props = root.find("Properties")
    affects_saved = props.findtext("AffectsSavedGames") if props is not None else None
    single_player = props.findtext("SupportsSinglePlayer") if props is not None else None
    multi_player = props.findtext("SupportsMultiplayer") if props is not None else None
    check(
        "Properties 标志合规（AffectsSavedGames=0 / SinglePlayer=1 / Multiplayer=0）",
        affects_saved == "0" and single_player == "1" and multi_player == "0",
        f"AffectsSavedGames={affects_saved}, SP={single_player}, MP={multi_player}",
    )

    game_dep = root.find("./Dependencies/Game")
    check(
        "Dependencies 锁定原生 BNW 1.0.3.279",
        game_dep is not None
        and game_dep.attrib.get("minversion") == "1.0.3.279"
        and game_dep.attrib.get("maxversion") == "1.0.3.279",
        f"dep={game_dep.attrib if game_dep is not None else None}",
    )

    file_elems = root.findall("./Files/File")
    actual_files = [(elem.text or "").strip() for elem in file_elems]
    all_import_1 = all(elem.attrib.get("import") == "1" for elem in file_elems)
    all_forward_slash = all("\\" not in p for p in actual_files)
    no_duplicates = len(actual_files) == len(set(actual_files))
    no_core = all("Civ5AgentBridgeCore" not in p for p in actual_files)
    exact_10_match = set(actual_files) == set(EXPECTED_MODINFO_FILES) and len(actual_files) == 10
    all_exist = all((PROJECT_ROOT / "mod" / p).is_file() for p in actual_files)

    check("VFS 文件清单精确为 10 个正式文件且无重复", exact_10_match and no_duplicates, f"actual={actual_files}")
    check("全部 <File> 均为 import='1' 且全正斜杠 /", all_import_1 and all_forward_slash, f"import1={all_import_1}, slash={all_forward_slash}")
    check("已彻底移除旧单体 Lua/Civ5AgentBridgeCore.lua", no_core, f"actual={actual_files}")
    check("清单中全部 10 个文件均存在于 mod/ 磁盘目录", all_exist, f"missing={[p for p in actual_files if not (PROJECT_ROOT / 'mod' / p).is_file()]}")

    entry_elems = root.findall("./EntryPoints/EntryPoint")
    check(
        "唯一 InGameUIAddin 入口为空壳 Lua/Civ5AgentBridgeLoader.lua",
        len(entry_elems) == 1
        and entry_elems[0].attrib.get("type") == "InGameUIAddin"
        and entry_elems[0].attrib.get("file") == "Lua/Civ5AgentBridgeLoader.lua",
        f"entries={[e.attrib for e in entry_elems]}",
    )

    core_src, core_err = read_project_text("mod/Lua/Civ5AgentBridgeCore.lua")
    if core_src is None:
        check("Civ5AgentBridgeCore.lua 退役存根存在", False, str(core_err))
    else:
        non_comment_lines = [
            line for line in core_src.splitlines()
            if line.strip() != "" and not line.lstrip().startswith("--")
        ]
        legacy_tokens = ["AirRaidCore", "CanMoveOrAttackInto", "OpenUserData", "CAB_DbWritePayload"]
        hit_legacy = [tok for tok in legacy_tokens if tok in core_src]
        check(
            "Civ5AgentBridgeCore.lua 为零代码退役存根且零遗留禁令符号（D-02）",
            len(non_comment_lines) == 0 and len(hit_legacy) == 0,
            f"code_lines={len(non_comment_lines)}, hit_legacy={hit_legacy}",
        )

    return passed, failed


def _lua_array(table) -> list:
    """将 Lua 1-based 连续数组安全转换为 Python 列表。"""
    items: list = []
    index = 1
    while table[index] is not None:
        items.append(table[index])
        index += 1
    return items


def _inject_py_bridge(lua, backend: SqliteTestBackend, case_filter: str | None) -> None:
    """向指定 Lua 5.1 沙箱注入文件读取与真实 SQLite3 跨语言桥接函数。"""
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


def run_lua_suite(
    stage_title: str,
    stub_file: str,
    case_file: str,
    lua,
    compile_lua,
    backend: SqliteTestBackend,
    case_filter: str | None,
) -> tuple[int, int, int] | None:
    """在指定隔离 Lua 5.1 沙箱中执行一套桩测试与用例集。"""
    print(f"—— {stage_title} ——")
    stub_src, _ = read_project_text(stub_file)
    case_src, _ = read_project_text(case_file)
    if stub_src is None or case_src is None:
        missing = stub_file if stub_src is None else case_file
        print(f"  [待创建] {missing}")
        return None

    _inject_py_bridge(lua, backend, case_filter)

    stub_chunk, stub_err = compile_lua(stub_src, "@" + stub_file)
    if stub_chunk is None:
        print(f"  [失败] {stub_file} 编译失败：{stub_err}")
        return 0, 1, 0
    stub_chunk()

    case_chunk, case_err = compile_lua(case_src, "@" + case_file)
    if case_chunk is None:
        print(f"  [失败] {case_file} 编译失败：{case_err}")
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
        description="M1Sub4 (CAB_Json + CAB_ExternalIO + 最终壳层合龙) Lua 5.1 语法检查、.modinfo 校验与真实 SQLite3 离线测试入口"
    )
    parser.add_argument(
        "--filter",
        dest="case_filter",
        default=None,
        help="仅运行用例 ID 或标题包含该子串的用例（如 --filter T-03 或 --filter T-19）",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    """主入口：依次执行语法检查、.modinfo 校验、WP1~WP2 隔离单测与 WP3 五模块全栈联调。"""
    _configure_stdio()
    args = parse_args(argv)

    try:
        from lupa import lua51
    except ImportError as exc:
        print(f"无法导入 lupa.lua51：{exc}")
        print("请确认本机 Python 已安装 lupa（pip install lupa）。")
        return 2

    lua_unit = lua51.LuaRuntime(unpack_returned_tuples=True)
    compile_unit = make_compiler(lua_unit)
    backend_unit = SqliteTestBackend(lua_unit)

    lua_full = lua51.LuaRuntime(unpack_returned_tuples=True)
    compile_full = make_compiler(lua_full)
    backend_full = SqliteTestBackend(lua_full)

    try:
        try:
            syn_passed, syn_failed, syn_pending = run_syntax_check(compile_unit)
            modinfo_passed, modinfo_failed = run_modinfo_validation()
            unit_result = run_lua_suite(
                "阶段 3：真实 SQLite3 跨语言单测（WP1~WP2：CAB_Json + CAB_ExternalIO）",
                STUB_FILE,
                CASE_FILE,
                lua_unit,
                compile_unit,
                backend_unit,
                args.case_filter,
            )
            full_result = run_lua_suite(
                "阶段 4：五模块 + UI 壳层真实 SQLite3 全栈端到端联调（WP3）",
                FULLSTACK_STUB_FILE,
                FULLSTACK_CASE_FILE,
                lua_full,
                compile_full,
                backend_full,
                args.case_filter,
            )
        except lua51.LuaError as exc:
            print(f"  [失败] 测试框架出错：{exc}")
            print("—— 汇总 ——")
            print("结果：测试框架出错（见上方 Lua 错误与调用栈）")
            print("退出码：2")
            return 2
    finally:
        backend_unit.close()
        backend_full.close()

    u_pass, u_fail, u_skip = unit_result or (0, 0, 0)
    f_pass, f_fail, f_skip = full_result or (0, 0, 0)
    case_passed = u_pass + f_pass
    case_failed = u_fail + f_fail
    case_skipped = u_skip + f_skip
    total_cases = case_passed + case_failed + case_skipped

    print("—— 汇总 ——")
    print(f"语法检查：    通过 {syn_passed}，失败 {syn_failed}，待创建 {syn_pending}")
    print(f"Modinfo校验： 通过 {modinfo_passed}，失败 {modinfo_failed}")
    print(
        f"桩测试合计：  通过 {case_passed}，失败 {case_failed}，跳过 {case_skipped}"
        f"（共 {total_cases} 条；单测 {u_pass}/{u_pass + u_fail + u_skip}，全栈 {f_pass}/{f_pass + f_fail + f_skip}）"
    )

    total_failed = syn_failed + modinfo_failed + case_failed
    if total_failed == 0:
        print("结果：全部通过")
        print("退出码：0")
        return 0
    print(f"结果：存在失败（共 {total_failed} 项）")
    print("退出码：1")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
