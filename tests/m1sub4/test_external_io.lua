-- =============================================================================
-- 文件：tests/m1sub4/test_external_io.lua
-- 职责：M1Sub4（CAB_Json + CAB_ExternalIO + 最终壳层合龙）离线自动化验收测试集。
-- 依赖：由 tests/run_m1sub4_tests.py 在加载 tests/m1sub4/db_stubs.lua 后执行。
-- 对外契约：返回汇总表 { passed, failed, skipped, guardViolations, guardMissing,
--           totalOpens, totalDbWrites, totalDbReads, cases = {...} }。
--
-- 结构划分（对齐《docs/M1/M1Sub4/M1Sub4工作计划.md》WP1 ~ WP3）：
--   第 1 节  用例注册与断言工具库；
--   第 2 节  WP1 静态红线、CAB_Json 升级加固单测与真实 SQLite3 桩自检（T-00 ~ T-06）；
--   第 3 节  WP2 CAB_ExternalIO 全量契约、跨语言 UTF-8 分片、原子屏障、会话与异常隔离（T-07 ~ T-15）；
--   第 4 节  运行器与收尾总检（FW-01）。
-- =============================================================================

local S = CAB_TEST_STUBS
local cases = {}

-- -----------------------------------------------------------------------------
-- 第 1 节：用例注册与断言工具库
-- -----------------------------------------------------------------------------

local function test(id, title, fn)
    table.insert(cases, { id = id, title = title, fn = fn })
end

local function skip(reason)
    error({ __skip = true, reason = reason })
end

local function fail(msg)
    error(msg .. "\n" .. debug.traceback(), 2)
end

local function show(v)
    local kind = type(v)
    if kind == "string" then
        return '"' .. v .. '"'
    elseif kind == "table" then
        local parts = {}
        if v[1] ~= nil then
            for i = 1, #v do
                parts[i] = show(v[i])
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        for k, item in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. show(item)
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function isSame(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, item in pairs(a) do
        if not isSame(item, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

local function same(actual, expected, msg)
    if not isSame(actual, expected) then
        fail(msg .. "：期望 " .. show(expected) .. "，实际 " .. show(actual))
    end
end

local function truthy(actual, msg)
    if actual ~= true then
        fail(msg .. "：应为 true，实际 " .. show(actual))
    end
end

local function falsy(actual, msg)
    if actual ~= false then
        fail(msg .. "：应为 false，实际 " .. show(actual))
    end
end

local function isNil(actual, msg)
    if actual ~= nil then
        fail(msg .. "：应为 nil，实际 " .. show(actual))
    end
end

local function notNil(actual, msg)
    if actual == nil then
        fail(msg .. "：不应为 nil")
    end
end

local function isType(actual, typeName, msg)
    if type(actual) ~= typeName then
        fail(msg .. "：类型应为 " .. typeName .. "，实际 " .. type(actual))
    end
end

local function contains(str, needle, msg)
    if type(str) ~= "string" or str:find(needle, 1, true) == nil then
        fail(msg .. "：期望包含 " .. show(needle) .. "，实际 " .. show(str))
    end
end

local function globalSnapshot()
    local names = {}
    for name in pairs(_G) do
        names[name] = true
    end
    return names
end

local function newGlobals(snapshot)
    local added = {}
    for name in pairs(_G) do
        if not snapshot[name] then
            added[#added + 1] = name
        end
    end
    table.sort(added)
    return added
end

local function assertDecodeError(input, label)
    local val, err = CAB_Json.Decode(input)
    isNil(val, label .. " 解码结果应为 nil")
    notNil(err, label .. " 应返回明确错误信息")
    isType(err, "string", label .. " 错误信息应为 string")
end

-- -----------------------------------------------------------------------------
-- 第 2 节：WP1 静态红线、CAB_Json 升级加固单测与真实 SQLite3 桩自检（T-00 ~ T-06）
-- -----------------------------------------------------------------------------

test("T-00", "WP1 静态红线（I-01）与 CAB_Json 命名空间/全局符号洁净（A-01）", function()
    local forbidden = {
        "CAB_Dispatcher",
        "CAB_Collector",
        "CAB_Executor",
        "OpenUserData",
        "SimpleValues",
        "SelectionListMove",
        "SelectionListGameNetMessage",
        "SelectedCitiesGameNetMessage",
        "CityPurchase",
        "CityPushOrder",
        "SendCityBuyPlot",
        "SendResearch",
        "SendUpdatePolicies",
        "HandleAction",
        "DoControl",
        "UI.SelectUnit",
        "UI.SetInterfaceMode",
        "SetScriptData",
        "CanMoveOrAttackInto",
        "AirRaidCore",
    }
    local hits = S.scanForbiddenTokens("mod/Lua/Civ5AgentBridgeJson.lua", forbidden)
    eq(#hits, 0, "Civ5AgentBridgeJson.lua 不得命中红线 I-01 禁令符号，命中=" .. show(hits))

    -- 在清空目标全局符号后重新加载，验证精确导出且零多余全局泄露
    CAB_Json = nil
    CAB_JsonEncode = nil
    CAB_JsonDecode = nil
    CAB_JSON_NULL = nil
    local snap = globalSnapshot()
    S.loadModule("Civ5AgentBridgeJson")
    local added = newGlobals(snap)
    same(
        added,
        { "CAB_JSON_NULL", "CAB_Json", "CAB_JsonDecode", "CAB_JsonEncode" },
        "Civ5AgentBridgeJson.lua 应精确导出 4 个约定全局符号"
    )

    isType(CAB_Json, "table", "CAB_Json 应为 table")
    eq(CAB_Json.Encode, CAB_JsonEncode, "CAB_Json.Encode 应指向 CAB_JsonEncode")
    eq(CAB_Json.Decode, CAB_JsonDecode, "CAB_Json.Decode 应指向 CAB_JsonDecode")
    eq(CAB_Json.NULL, CAB_JSON_NULL, "CAB_Json.NULL 应指向 CAB_JSON_NULL")
    eq(tostring(CAB_Json.NULL), "null", "tostring(CAB_Json.NULL) 应为 'null'")

    local nsKeys = {}
    for k in pairs(CAB_Json) do
        nsKeys[#nsKeys + 1] = k
    end
    table.sort(nsKeys)
    same(nsKeys, { "Decode", "Encode", "NULL" }, "CAB_Json 命名空间键集合应精确匹配")
end)

test("T-01", "CAB_Json.Encode 核心类型、__is_object、NULL、非有限数、控制字符与 Python json.loads 互校验（A-02）", function()
    eq(CAB_Json.Encode(nil), "null", "nil 编码为 null")
    eq(CAB_Json.Encode(CAB_Json.NULL), "null", "CAB_Json.NULL 编码为 null")
    eq(CAB_Json.Encode(true), "true", "true 编码")
    eq(CAB_Json.Encode(false), "false", "false 编码")
    eq(CAB_Json.Encode(0), "0", "0 编码")
    eq(CAB_Json.Encode(-42), "-42", "负整数编码")
    eq(CAB_Json.Encode(0 / 0), "null", "NaN 编码为 null")
    eq(CAB_Json.Encode(math.huge), "null", "+inf 编码为 null")
    eq(CAB_Json.Encode(-math.huge), "null", "-inf 编码为 null")

    -- 空数组 vs 空对象及 __is_object 标记省略
    eq(CAB_Json.Encode({}), "[]", "普通空表编码为 []")
    eq(CAB_Json.Encode({ __is_object = true }), "{}", "携带 __is_object 的空表编码为 {}")
    local objWithMarker = CAB_Json.Encode({ __is_object = true, city = "北京", pop = 12 })
    falsy(objWithMarker:find("__is_object", 1, true) ~= nil, "序列化输出不应包含 __is_object 键本身")

    -- 数组内含 CAB_Json.NULL 占位符
    eq(CAB_Json.Encode({ 1, CAB_Json.NULL, 3 }), "[1,null,3]", "数组内 CAB_Json.NULL 应编码为 null")

    -- 字符串标准转义、NUL 字节与 UTF-8 中英文/表情透传
    local rawCtrl = "a\"b\\c\bd\fe\nf\rg\th\000i\001j\031k"
    local encCtrl = CAB_Json.Encode(rawCtrl)
    contains(encCtrl, "\\u0000", "NUL 字节应转义为 \\u0000")
    contains(encCtrl, "\\u0001", "0x01 应转义为 \\u0001")
    contains(encCtrl, "\\u001f", "0x1F 应转义为 \\u001f")
    local decCtrl, errCtrl = CAB_Json.Decode(encCtrl)
    isNil(errCtrl, "控制字符转义后应可无损解码")
    eq(decCtrl, rawCtrl, "控制字符（含 NUL）编解码往返一致")

    local utf8Payload = {
        __is_object = true,
        simplified = "文明5：美丽新世界",
        traditional = "羅馬帝國與社會政策",
        emoji = "😀🛡️⚔️",
        nested = {
            __is_object = true,
            empty_arr = {},
            empty_obj = { __is_object = true },
            null_field = CAB_Json.NULL,
            nums = { 1, -2.5, 0, true, false },
        },
    }
    local encoded = CAB_Json.Encode(utf8Payload)
    contains(encoded, "文明5：美丽新世界", "简体中文应 UTF-8 原样透传")
    contains(encoded, "羅馬帝國與社會政策", "繁体中文应 UTF-8 原样透传")
    contains(encoded, "😀🛡️⚔️", "4 字节 UTF-8 表情应原样透传")

    -- 使用 Python 标准库 json.loads 交叉校验全部编码结果严格符合 RFC 8259
    for idx, sample in ipairs({ encoded, encCtrl, objWithMarker, "[1,null,3]", "{}" }) do
        local pyOk, pyInfo = __py_json_loads_check(sample)
        truthy(pyOk, "Python json.loads 交叉校验样本 #" .. tostring(idx) .. " 失败：" .. tostring(pyInfo))
    end
end)

test("T-02", "CAB_Json.Decode 正向解析、旧全局函数兼容与往返保真（A-02）", function()
    -- 空白容忍 + 复杂嵌套结构 + 科学计数法 + 对象内 null
    local raw = ' \t\r\n { "method": "get_city_detail", "req_id": 108, "ratio": -2.5E-2, "flag": true, "off": false, "opt": null, "list": [0, -0, 42, "漢字", [], {}] } \r\n '
    local parsed, err = CAB_Json.Decode(raw)
    isNil(err, "合法 JSON 不应返回解码错误")
    isType(parsed, "table", "根对象应解码为 table")
    eq(parsed.method, "get_city_detail", "字符串字段一致")
    eq(parsed.req_id, 108, "整数字段一致")
    eq(parsed.ratio, -0.025, "科学计数法数字一致")
    truthy(parsed.flag, "true 字段一致")
    falsy(parsed.off, "false 字段一致")
    isNil(parsed.opt, "对象内 null 字段解码为 nil")
    eq(#parsed.list, 6, "数组长度一致")
    eq(parsed.list[1], 0, "数组第 1 项 0")
    eq(parsed.list[3], 42, "数组第 3 项 42")
    eq(parsed.list[4], "漢字", "数组第 4 项中文")
    same(parsed.list[5], {}, "空数组解码")
    same(parsed.list[6], {}, "空对象解码")

    -- 顶层 null 应返回 (nil, nil)
    local nullVal, nullErr = CAB_Json.Decode("  null  ")
    isNil(nullVal, "顶层 null 解码值应为 nil")
    isNil(nullErr, "顶层 null 解码不应报错")

    -- 旧全局函数 CAB_JsonEncode / CAB_JsonDecode / CAB_JSON_NULL 100% 向下兼容
    local legacyInput = { __is_object = true, a = "测试", b = CAB_JSON_NULL, c = { 1, 2, 3 } }
    local legacyEnc = CAB_JsonEncode(legacyInput)
    local nsEnc = CAB_Json.Encode(legacyInput)
    local legacyDec, lErr = CAB_JsonDecode(legacyEnc)
    local nsDec, nErr = CAB_Json.Decode(nsEnc)
    isNil(lErr, "旧全局 CAB_JsonDecode 不应报错")
    isNil(nErr, "CAB_Json.Decode 不应报错")
    same(legacyDec, nsDec, "旧全局接口与 CAB_Json 命名空间解码结果必须完全一致")
end)

test("T-03", "CAB_Json.Decode \\uXXXX 严格十六进制校验与 UTF-16 代理对转 4 字节 UTF-8（D-03 加固 2）", function()
    -- 1/2/3 字节 BMP 码点
    local v1, e1 = CAB_Json.Decode('"\\u0041\\u007a"')
    isNil(e1, "ASCII \\uXXXX 解码成功")
    eq(v1, "Az", "1 字节 UTF-8 正确")

    local v2, e2 = CAB_Json.Decode('"\\u00E9\\u00e9"')
    isNil(e2, "2 字节 BMP 解码成功")
    eq(v2, "éé", "大小写十六进制 2 字节 UTF-8 正确")

    local v3, e3 = CAB_Json.Decode('"\\u4E2D\\u6587\\u7F85\\u99AC"')
    isNil(e3, "3 字节简/繁中文 \\uXXXX 解码成功")
    eq(v3, "中文羅馬", "3 字节 UTF-8 中文正确")

    -- 4 字节补充平面字符（UTF-16 代理对）
    local vEmoji, eEmoji = CAB_Json.Decode('"Hi \\uD83D\\uDE00!"')
    isNil(eEmoji, "UTF-16 代理对表情解码成功")
    eq(vEmoji, "Hi 😀!", "代理对 \\uD83D\\uDE00 应解码为 4 字节 UTF-8 😀")
    eq(S.toHex(vEmoji:sub(4, 7)), "f09f9880", "😀 精确 UTF-8 字节应为 F0 9F 98 80")

    -- 补充平面边界：U+10000 (\uD800\uDC00) 与 U+10FFFF (\uDBFF\uDFFF)
    local vMin, eMin = CAB_Json.Decode('"\\uD800\\uDC00"')
    isNil(eMin, "U+10000 最小代理对解码成功")
    eq(S.toHex(vMin), "f0908080", "U+10000 UTF-8 精确字节 F0 90 80 80")

    local vMax, eMax = CAB_Json.Decode('"\\uDBFF\\uDFFF"')
    isNil(eMax, "U+10FFFF 最大代理对解码成功")
    eq(S.toHex(vMax), "f48fbfbf", "U+10FFFF UTF-8 精确字节 F4 8F BF BF")

    -- 全部畸形 \u 与孤立/错配代理对必须被严格拒绝
    assertDecodeError('"\\u123"', "不足 4 位十六进制")
    assertDecodeError('"\\u12GZ"', "非十六进制字符")
    assertDecodeError('"\\u"', "截断 \\u")
    assertDecodeError('"\\uD83D"', "孤立高代理（串尾）")
    assertDecodeError('"\\uD83Dabc"', "高代理后非 \\u")
    assertDecodeError('"\\uD83D\\u0041"', "高代理后跟 BMP 非低代理")
    assertDecodeError('"\\uD83D\\uDC"', "高代理后低代理截断")
    assertDecodeError('"\\uDE00"', "孤立低代理")
    assertDecodeError('"\\uDE00\\uD83D"', "低高代理顺序颠倒")
end)

test("T-04", "CAB_Json.Decode 尾随垃圾、非法字面量/数字、非法转义、未转义控制字符与超深嵌套拦截（D-03 加固 1 & 4）", function()
    -- 加固 1：根值后尾随非法字符
    assertDecodeError('{} 123', "对象后尾随数字")
    assertDecodeError('[1,2] trailing', "数组后尾随文本")
    assertDecodeError('true false', "布尔后尾随布尔")
    assertDecodeError('"ok" "extra"', "字符串后尾随字符串")
    assertDecodeError('42abc', "数字粘连字母")
    assertDecodeError('null 0', "null 后尾随数字")
    assertDecodeError('{"a":1},', "根对象后尾随逗号")

    -- 加固 4：非法字面量与 RFC 8259 非法数字
    assertDecodeError('true1', "非法字面量 true1")
    assertDecodeError('falsex', "非法字面量 falsex")
    assertDecodeError('nullify', "非法字面量 nullify")
    assertDecodeError('01', "前导零数字 01")
    assertDecodeError('-01', "负前导零数字 -01")
    assertDecodeError('1.', "小数点后无数字")
    assertDecodeError('.5', "缺少整数部分")
    assertDecodeError('1e', "残缺指数 1e")
    assertDecodeError('1e+', "残缺指数 1e+")
    assertDecodeError('+1', "非法正号 +1")
    assertDecodeError('NaN', "非标准字面量 NaN")
    assertDecodeError('Infinity', "非标准字面量 Infinity")
    assertDecodeError('1.2.3', "双小数点数字")

    -- 加固 2：非法转义与未转义控制字符（< 0x20）
    assertDecodeError('"\\x41"', "非法转义 \\x")
    assertDecodeError('"\\a"', "非法转义 \\a")
    assertDecodeError('"hello\nworld"', "字符串内未转义 LF")
    assertDecodeError('"hello\tworld"', "字符串内未转义 TAB")
    assertDecodeError('"zero\000byte"', "字符串内未转义 NUL")
    assertDecodeError('"ctrl\031char"', "字符串内未转义 0x1F")

    -- 空输入、非字符串与未闭合/畸形容器
    assertDecodeError('', "空字符串")
    assertDecodeError('   \r\n\t  ', "纯空白字符串")
    assertDecodeError(nil, "nil 输入")
    assertDecodeError(123, "number 输入")
    assertDecodeError('{a:1}', "未加引号的对象键")
    assertDecodeError('{"a":}', "对象缺值")
    assertDecodeError('{"a":1,}', "对象尾逗号")
    assertDecodeError('[1,]', "数组尾逗号")
    assertDecodeError('{"a":1', "未闭合对象")
    assertDecodeError('[1,2', "未闭合数组")
    assertDecodeError('"unterminated', "未闭合字符串")
    assertDecodeError('"unterminated\\', "未闭合转义")

    -- 超过最大解码深度（64）时必须安全报错返回，不得崩溃 Lua 5.1 栈
    local deepOkJson = string.rep("[", 64) .. "1" .. string.rep("]", 64)
    local deepVal, deepErr = CAB_Json.Decode(deepOkJson)
    isNil(deepErr, "64 层合法嵌套数组应允许解码")
    notNil(deepVal, "64 层解码结果非空")

    local tooDeepJson = string.rep("[", 65) .. "1" .. string.rep("]", 65)
    local badDeepVal, badDeepErr = CAB_Json.Decode(tooDeepJson)
    isNil(badDeepVal, "65 层超深嵌套数组应被拦截")
    contains(badDeepErr, "depth", "超深解码错误信息应指明 depth")
end)

test("T-05", "CAB_Json.Encode 循环引用检测、最大深度防护（64）与合法 DAG 共享子表（D-03 加固 3）", function()
    -- 1. 直接自环
    local selfLoop = { __is_object = true, name = "root" }
    selfLoop.self = selfLoop
    local ok1, err1 = pcall(CAB_Json.Encode, selfLoop)
    falsy(ok1, "直接自环必须被拦截")
    contains(tostring(err1), "circular", "错误信息应包含 circular")

    -- 2. 双节点间接环
    local nodeA = { __is_object = true, id = "A" }
    local nodeB = { __is_object = true, id = "B", back = nodeA }
    nodeA.next = nodeB
    local ok2, err2 = pcall(CAB_Json.Encode, nodeA)
    falsy(ok2, "双节点互环必须被拦截")
    contains(tostring(err2), "circular", "错误信息应包含 circular")

    -- 3. 数组自环
    local arrLoop = {}
    arrLoop[1] = arrLoop
    local ok3, err3 = pcall(CAB_Json.Encode, arrLoop)
    falsy(ok3, "数组自环必须被拦截")
    contains(tostring(err3), "circular", "错误信息应包含 circular")

    -- 4. 合法非环 DAG（同一子表被多处引用）必须正常编码不误报
    local shared = { __is_object = true, x = 10, y = 20 }
    local dag = { __is_object = true, first = shared, second = shared, list = { shared, shared } }
    local okDag, dagJson = pcall(CAB_Json.Encode, dag)
    truthy(okDag, "合法非环 DAG 共享子表不应误报循环引用：" .. tostring(dagJson))
    local pyOk, pyInfo = __py_json_loads_check(dagJson)
    truthy(pyOk, "DAG 编码结果应通过 Python json.loads 校验：" .. tostring(pyInfo))
    local decodedDag, decErr = CAB_Json.Decode(dagJson)
    isNil(decErr, "DAG 编码结果应可正常解码")
    eq(decodedDag.first.x, 10, "DAG first.x 保留")
    eq(decodedDag.second.y, 20, "DAG second.y 保留")
    eq(#decodedDag.list, 2, "DAG list 两项保留")

    -- 5. 深度边界：64 层通过，65 层拦截
    local function makeNested(depth)
        local root = { __is_object = true }
        local cur = root
        for _ = 2, depth do
            local child = { __is_object = true }
            cur.c = child
            cur = child
        end
        cur.leaf = 1
        return root
    end
    local ok64, enc64 = pcall(CAB_Json.Encode, makeNested(64))
    truthy(ok64, "64 层嵌套对象应允许编码：" .. tostring(enc64))

    local ok65, err65 = pcall(CAB_Json.Encode, makeNested(65))
    falsy(ok65, "65 层超深嵌套对象必须被拦截")
    contains(tostring(err65), "depth", "超深编码错误信息应指明 depth")
end)

test("T-06", "真实 Python sqlite3 SimpleValues 桩自检（跨语言 UTF-8 复现、写序审计与故障注入）", function()
    local db = Modding.OpenUserData(CAB_Config.DB_NAME, CAB_Config.DB_VERSION)
    notNil(db, "Modding.OpenUserData 应返回真实 SQLite 句柄")

    -- 1. 基本读写（ASCII、简/繁中文、4 字节表情、空串、数字）
    truthy(db.SetValue("k_ascii", "hello"), "写入 ASCII")
    truthy(db.SetValue("k_cn", "文明5：羅馬帝國😀"), "写入中英文与表情")
    truthy(db.SetValue("k_empty", ""), "写入空串")
    truthy(db.SetValue("k_num", 42), "写入数字")

    eq(db.GetValue("k_ascii"), "hello", "回读 ASCII")
    eq(db.GetValue("k_cn"), "文明5：羅馬帝國😀", "回读中英文与表情")
    eq(db.GetValue("k_empty"), "", "回读空串")
    eq(db.GetValue("k_num"), 42, "回读数字")
    isNil(db.GetValue("k_not_exist"), "不存在的键应返回 nil")

    -- 2. 跨语言严格 UTF-8 复现验证：
    --    a) 合法 UTF-8 写入后，Python 默认 text_factory=str 读库成功
    local okValid, valValid = S.pyDb.readTextStrict(db._testHandleId, "k_cn")
    truthy(okValid, "合法 UTF-8 应被 Python 默认 text_factory=str 正常读出")
    eq(valValid, "文明5：羅馬帝國😀", "Python 默认读取文本内容一致")

    --    b) 故意写入半截 3 字节中文（0xE4 0xB8），Python 默认 text_factory=str 必须真实报 OperationalError，
    --       而 Lua GetValue 与 Python text_factory=bytes 仍能无损取回原始字节
    local brokenUtf8 = string.char(0xE4, 0xB8)
    truthy(db.SetValue("k_broken", brokenUtf8), "允许写入原始残缺 UTF-8 字节以模拟未对齐分片")
    local okBroken, errBroken = S.pyDb.readTextStrict(db._testHandleId, "k_broken")
    falsy(okBroken, "残缺 UTF-8 必须触发 Python sqlite3 OperationalError")
    contains(errBroken, "OperationalError", "错误类型应为真实 sqlite3.OperationalError")
    eq(S.toHex(db.GetValue("k_broken")), "e4b8", "Lua GetValue 应无损回读原始字节")

    -- 3. 写顺序事件日志审计（为 WP2 红线 I-03 提供证据底座）
    same(
        S.db.writeKeys(),
        { "k_ascii", "k_cn", "k_empty", "k_num", "k_broken" },
        "S.db.writeLog 应严格记录每次 SetValue 的时间顺序"
    )
    eq(S.db.firstWriteIndex("k_cn"), 2, "firstWriteIndex 精准命中")
    eq(S.db.lastWriteIndex("k_broken"), 5, "lastWriteIndex 精准命中")

    -- 4. 故障注入开关验证（openFail / openThrow / setThrowOnKey / getThrowOnKey）
    S.faults.openFail = true
    isNil(Modding.OpenUserData("Civ5AgentBridge", 1), "openFail 开关应使 OpenUserData 返回 nil")
    S.faults.openFail = false

    S.faults.openThrow = "simulated open lock"
    local okOpen, errOpen = pcall(Modding.OpenUserData, "Civ5AgentBridge", 1)
    falsy(okOpen, "openThrow 开关应触发异常")
    contains(tostring(errOpen), "simulated open lock", "异常文本匹配")
    S.faults.openThrow = nil

    S.faults.setThrowOnKey = "k_fail"
    local okSet, errSet = pcall(db.SetValue, "k_fail", "x")
    falsy(okSet, "setThrowOnKey 应拦截目标键写入")
    contains(tostring(errSet), "k_fail", "写入故障文本含目标键")
    S.faults.setThrowOnKey = nil

    S.faults.getThrowOnKey = "k_cn"
    local okGet, errGet = pcall(db.GetValue, "k_cn")
    falsy(okGet, "getThrowOnKey 应拦截目标键读取")
    contains(tostring(errGet), "k_cn", "读取故障文本含目标键")
    S.faults.getThrowOnKey = nil

    -- 5. 验证 Python 侧分片写入 + Python 侧 bytes 拼片读回通道正常
    local bigCn = string.rep("繁體中文與簡體中文測試😀", 150)
    local pyChunks = S.pyDb.writePayload(db._testHandleId, "py_big", bigCn, 3000, false)
    truthy(pyChunks >= 2, "Python 写入大载荷应自动分为多片")
    local okJoin, joined, rawLen, readChunks = S.pyDb.readChunkedBytes(db._testHandleId, "py_big")
    truthy(okJoin, "Python bytes 拼片读取应成功：" .. tostring(joined))
    eq(joined, bigCn, "Python 写入并拼片读回内容 100% 一致")
    eq(rawLen, #bigCn, "原始字节长度一致")
    eq(readChunks, pyChunks, "分片数一致")
end)

-- -----------------------------------------------------------------------------
-- 第 3 节：WP2 CAB_ExternalIO 全量契约、跨语言 UTF-8 分片与协议隔离（T-07 ~ T-15）
-- -----------------------------------------------------------------------------

local function initExternalIOOrFail(cb)
    local callback = cb or function() end
    local ok, err = CAB_ExternalIO.Initialize(callback)
    truthy(ok, "CAB_ExternalIO.Initialize 应成功：" .. tostring(err))
    isNil(err, "CAB_ExternalIO.Initialize 成功时错误应为 nil")
    return S.db.lastHandleId
end

test("T-07", "WP2 CAB_ExternalIO 静态红线（I-01）、守卫式加载与精确 8 接口导出（A-01）", function()
    local forbidden = {
        "CAB_Dispatcher",
        "CAB_Collector",
        "CAB_Executor",
        "SelectionListMove",
        "SelectionListGameNetMessage",
        "SelectedCitiesGameNetMessage",
        "CityPurchase",
        "CityPushOrder",
        "SendCityBuyPlot",
        "SendResearch",
        "SendUpdatePolicies",
        "HandleAction",
        "DoControl",
        "UI.SelectUnit",
        "UI.SetInterfaceMode",
        "SetScriptData",
        "CanMoveOrAttackInto",
        "AirRaidCore",
    }
    local hits = S.scanForbiddenTokens("mod/Lua/CAB_ExternalIO.lua", forbidden)
    eq(#hits, 0, "CAB_ExternalIO.lua 不得命中红线 I-01 禁令符号，命中=" .. show(hits))

    -- 验证仅新增唯一全局表 CAB_ExternalIO，且守卫式加载不会重复 include 已就绪底座
    local cfgCountBefore = S.includeCount["CAB_Config"] or 0
    local jsonCountBefore = S.includeCount["Civ5AgentBridgeJson"] or 0
    CAB_ExternalIO = nil
    local snap = globalSnapshot()
    S.loadModule("CAB_ExternalIO")
    local added = newGlobals(snap)
    same(added, { "CAB_ExternalIO" }, "CAB_ExternalIO.lua 应且仅应导出唯一全局符号 CAB_ExternalIO")
    eq(S.includeCount["CAB_Config"] or 0, cfgCountBefore, "CAB_Config 已就绪时守卫式 include 不应重复加载")
    eq(S.includeCount["Civ5AgentBridgeJson"] or 0, jsonCountBefore, "CAB_Json 已就绪时守卫式 include 不应重复加载")

    -- 精确校验 8 个公开接口（X1 ~ X8）
    local exported = {}
    for k, v in pairs(CAB_ExternalIO) do
        isType(v, "function", "CAB_ExternalIO." .. tostring(k) .. " 必须为 function")
        exported[#exported + 1] = k
    end
    table.sort(exported)
    same(
        exported,
        {
            "GetRuntimeState",
            "Initialize",
            "PollIncomingRequest",
            "PushTurnOverview",
            "ReadPayload",
            "SendRpcResponse",
            "WriteHeartbeat",
            "WritePayload",
        },
        "CAB_ExternalIO 必须精确导出 8 个契约函数"
    )

    -- 未初始化前 GetRuntimeState 默认值校验
    local st = CAB_ExternalIO.GetRuntimeState()
    falsy(st.initialized, "初始 initialized 应为 false")
    falsy(st.db_connected, "初始 db_connected 应为 false")
    eq(st.last_processed_req_id, 0, "初始 last_processed_req_id 应为 0")
    eq(st.active_session_id, "", "初始 active_session_id 应为空串")
    falsy(st.has_callback, "初始 has_callback 应为 false")
    eq(st.chunk_size_bytes, CAB_Config.CHUNK_SIZE_BYTES, "初始 chunk_size_bytes 应读取 CAB_Config")
end)

test("T-08", "X1 Initialize 依赖校验、打开故障隔离与重载防重放水位线校准（I-04 / I-05）", function()
    -- 1. 回调参数缺失/非函数被拦截
    local okNoCb, errNoCb = CAB_ExternalIO.Initialize(nil)
    falsy(okNoCb, "nil 回调应初始化失败")
    contains(errNoCb, "onMessageCallback", "错误信息应指明 onMessageCallback")

    local okBadCb, errBadCb = CAB_ExternalIO.Initialize("not_a_fn")
    falsy(okBadCb, "非函数回调应初始化失败")
    contains(errBadCb, "onMessageCallback", "错误信息应指明 onMessageCallback")

    -- 2. 配置/依赖缺失被安全拦截（执行后立即还原全局表）
    local savedDbName = CAB_Config.DB_NAME
    CAB_Config.DB_NAME = ""
    local okCfg, errCfg = CAB_ExternalIO.Initialize(function() end)
    CAB_Config.DB_NAME = savedDbName
    falsy(okCfg, "空 DB_NAME 应初始化失败")
    contains(errCfg, "DB_NAME", "错误信息应指明 DB_NAME")

    local savedJson = CAB_Json
    CAB_Json = nil
    local okJson, errJson = CAB_ExternalIO.Initialize(function() end)
    CAB_Json = savedJson
    falsy(okJson, "缺失 CAB_Json 应初始化失败")
    contains(errJson, "CAB_Json", "错误信息应指明 CAB_Json")

    local savedModding = Modding
    Modding = nil
    local okMod, errMod = CAB_ExternalIO.Initialize(function() end)
    Modding = savedModding
    falsy(okMod, "缺失 Modding 应初始化失败")
    contains(errMod, "OpenUserData", "错误信息应指明 OpenUserData")

    -- 3. OpenUserData 返回 nil 与抛异常故障隔离
    S.faults.openFail = true
    local okNil, errNil = CAB_ExternalIO.Initialize(function() end)
    S.faults.openFail = false
    falsy(okNil, "OpenUserData 返回 nil 应初始化失败")
    contains(errNil, "OpenUserData", "错误信息应含 OpenUserData")

    S.faults.openThrow = "sqlite busy on open"
    local okThrow, errThrow = CAB_ExternalIO.Initialize(function() end)
    S.faults.openThrow = nil
    falsy(okThrow, "OpenUserData 抛错应被 pcall 拦截")
    contains(errThrow, "sqlite busy on open", "错误信息应保留异常文本")

    -- 4. 读档/重载防重放：先在真实 SQLite 中预置历史 req_id=25 与 session_id="sess-prev"
    local preDb = Modding.OpenUserData(CAB_Config.DB_NAME, CAB_Config.DB_VERSION)
    S.pyDb.sendRpcRequest(
        preDb._testHandleId,
        25,
        '{"method":"ping","params":{"echo":"stale"}}',
        "sess-prev"
    )

    local received = {}
    local okInit, errInit = CAB_ExternalIO.Initialize(function(reqObj)
        received[#received + 1] = reqObj
    end)
    truthy(okInit, "预置历史数据后 Initialize 应成功：" .. tostring(errInit))
    isNil(errInit, "无错误")

    local st = CAB_ExternalIO.GetRuntimeState()
    truthy(st.initialized, "initialized 应为 true")
    truthy(st.db_connected, "db_connected 应为 true")
    truthy(st.has_callback, "has_callback 应为 true")
    eq(st.last_processed_req_id, 25, "水位线必须对齐库内历史 rpc_request_req_id=25")
    eq(st.active_session_id, "sess-prev", "会话号必须对齐库内历史 rpc_session_id")

    -- 立即轮询严禁重放历史指令 #25
    falsy(CAB_ExternalIO.PollIncomingRequest(), "初始化对齐后同 req_id=25 不得触发重放")
    eq(#received, 0, "历史请求绝不应触发上层回调")

    -- 5. 热重载二次 Initialize 若失败必须复位内部状态（不残留旧句柄与回调）
    S.faults.openFail = true
    local okReFail, _ = CAB_ExternalIO.Initialize(function() end)
    S.faults.openFail = false
    falsy(okReFail, "二次初始化失败应返回 false")
    local stAfterFail = CAB_ExternalIO.GetRuntimeState()
    falsy(stAfterFail.initialized, "失败后 initialized 应复位为 false")
    falsy(stAfterFail.db_connected, "失败后 db_connected 应复位为 false")
    falsy(stAfterFail.has_callback, "失败后 has_callback 应复位为 false")
end)

test("T-09", "X2/X3 跨语言真实 SQLite3 UTF-8 分片边界与多尺寸载荷无损互操作（I-02 / A-03）", function()
    local hid = initExternalIOOrFail()

    local function verifyRoundTrip(key, payload, forceChunked, expectChunked, label)
        local wrote = CAB_ExternalIO.WritePayload(key, payload, forceChunked)
        truthy(wrote, label .. " WritePayload 应成功")

        local okCnt, cntStr = S.pyDb.readTextStrict(hid, key .. "#chunk_count")
        truthy(okCnt, label .. " #chunk_count 应可被 Python 严格文本读出")
        local chunkCount = tonumber(cntStr) or 0
        if expectChunked then
            truthy(chunkCount >= 1, label .. " 应进入分片路径（实际 chunk_count=" .. tostring(cntStr) .. "）")
            -- 核验每一个独立分片均可被 Python 默认 text_factory=str 读取且 0 次 OperationalError（红线 I-02）
            for i = 1, chunkCount do
                local okPart, partVal = S.pyDb.readTextStrict(hid, key .. "#chunk_" .. tostring(i))
                truthy(
                    okPart,
                    label .. " 分片 #" .. tostring(i) .. " 触发 Python UTF-8 解码错误：" .. tostring(partVal)
                )
            end
            local okMain, mainMarker = S.pyDb.readTextStrict(hid, key)
            truthy(okMain, label .. " 主槽位标记应可读")
            eq(mainMarker, "__CHUNKED__:" .. tostring(#payload), label .. " 主槽位长度标记精确匹配")
        else
            eq(chunkCount, 0, label .. " 单槽位 #chunk_count 应为 0")
            local okSingle, singleVal = S.pyDb.readTextStrict(hid, key)
            truthy(okSingle, label .. " 单槽位 Python 严格文本读取应成功")
            eq(singleVal, payload, label .. " 单槽位内容一致")
        end

        -- Python text_factory=bytes 拼片无损校验
        local okJoin, pyJoined, pyRawLen, pyChunks = S.pyDb.readChunkedBytes(hid, key)
        truthy(okJoin, label .. " Python bytes 拼片解码应成功：" .. tostring(pyJoined))
        eq(pyJoined, payload, label .. " Python bytes 拼片还原内容 100% 一致")
        eq(pyRawLen, #payload, label .. " Python bytes 原始字节数 100% 一致")
        eq(pyChunks, chunkCount, label .. " 分片数一致")

        -- Lua ReadPayload 往返还原校验
        local luaRead = CAB_ExternalIO.ReadPayload(key)
        eq(luaRead, payload, label .. " Lua ReadPayload 往返 100% 一致")
    end

    -- 1. 0B / 2999B / 3000B / 3001B 关键长度边界与 forceChunked
    verifyRoundTrip("p_0_single", "", false, false, "0B 单槽位")
    verifyRoundTrip("p_0_forced", "", true, true, "0B 强制分片")
    verifyRoundTrip("p_2999", string.rep("A", 2999), false, false, "2999B 单槽位")
    verifyRoundTrip("p_3000", string.rep("B", 3000), false, false, "3000B 精确单槽上限")
    verifyRoundTrip("p_3001", string.rep("C", 3001), false, true, "3001B 自动分片")
    verifyRoundTrip("p_short_forced", "短载荷強制分片😀", true, true, "短中文强制分片")

    -- 2. 精确构造 3 字节中文与 4 字节表情跨越 3000B 边界（每一种偏移位全覆盖）
    --    a) 3 字节 '中' (E4 B8 AD) 首字节落在第 3000 字节（2999 ASCII + 中 + 尾）
    verifyRoundTrip("p_cn_off0", string.rep("a", 2999) .. "中" .. string.rep("z", 20), false, true, "3字节中文首字节压3000B")
    --    b) 3 字节 '羅' (E7 BE 85) 首字节落在第 2999 字节（2998 ASCII + 羅 + 尾）
    verifyRoundTrip("p_cn_off1", string.rep("a", 2998) .. "羅" .. string.rep("z", 20), false, true, "3字节中文次字节压3000B")
    --    c) 4 字节 '😀' (F0 9F 98 80) 分别在 2997 / 2998 / 2999 / 3000 字节起跳
    verifyRoundTrip("p_em_2997", string.rep("a", 2996) .. "😀" .. string.rep("z", 20), false, true, "4字节表情2997..3000完整落片")
    verifyRoundTrip("p_em_2998", string.rep("a", 2997) .. "😀" .. string.rep("z", 20), false, true, "4字节表情第3字节压3000B")
    verifyRoundTrip("p_em_2999", string.rep("a", 2998) .. "😀" .. string.rep("z", 20), false, true, "4字节表情第2字节压3000B")
    verifyRoundTrip("p_em_3000", string.rep("a", 2999) .. "😀" .. string.rep("z", 20), false, true, "4字节表情首字节压3000B")

    -- 3. 纯繁体中文多跨界大包（~9600B）与 36KB+ 混合大包
    local tradCn = string.rep("羅馬帝國社會政策與文化遺產", 267)
    verifyRoundTrip("p_trad_9k", tradCn, false, true, "纯繁体中文 9.6KB 跨多边界")

    local mixed36k = string.rep('{"city":"長安/北京","note":"文明5：美麗新世界😀🛡️⚔️"},', 620)
    truthy(#mixed36k > 32768, "混合测试载荷应大于 32KB（实际 " .. tostring(#mixed36k) .. "B）")
    verifyRoundTrip("p_mixed_36k", mixed36k, false, true, "36KB+ 中繁英表情混合大包")

    -- 4. CHUNK_SIZE_BYTES 极端小值（2）自动兜底钳制为 4，仍完整保留 4 字节表情
    CAB_Config.CHUNK_SIZE_BYTES = 2
    eq(CAB_ExternalIO.GetRuntimeState().chunk_size_bytes, 4, "小于 4 的 CHUNK_SIZE_BYTES 必须兜底钳制为 4")
    verifyRoundTrip("p_min_chunk4", "a😀中b🛡️", false, true, "最小分片钳制 4B + 表情中文")
    CAB_Config.CHUNK_SIZE_BYTES = 3000

    -- 5. 反向跨语言验证：Python 侧分片写入 -> Lua ReadPayload 100% 无损读回
    local pyBig = string.rep("反向測試：簡體與繁體中文😀⚔️|", 160)
    local pyWrittenChunks = S.pyDb.writePayload(hid, "py_to_lua", pyBig, 3000, false)
    truthy(pyWrittenChunks >= 2, "Python 写入大载荷应分为多片")
    eq(CAB_ExternalIO.ReadPayload("py_to_lua"), pyBig, "Lua ReadPayload 读取 Python 写片应 100% 无损")

    -- 6. 风险 R-02 向前推进兜底守卫：连续非法续字节 0x80 绝不死循环且原始字节可无损回读
    CAB_Config.CHUNK_SIZE_BYTES = 4
    local rawContGarbage = string.rep(string.char(0x80), 17)
    truthy(CAB_ExternalIO.WritePayload("p_garbage_bytes", rawContGarbage, true), "畸形连续 0x80 字节流必须安全切分完成")
    eq(S.toHex(CAB_ExternalIO.ReadPayload("p_garbage_bytes")), S.toHex(rawContGarbage), "畸形字节流回读字节一致")
    CAB_Config.CHUNK_SIZE_BYTES = 3000

    -- 7. 兼容原生 Civ5 C++ SetValue 返回 nil 的行为
    S.faults.setReturnNil = true
    truthy(CAB_ExternalIO.WritePayload("p_civ5_nil_ret", "原生Civ5无返回值测试", false), "SetValue 返回 nil 时应判定成功")
    S.faults.setReturnNil = false
    eq(CAB_ExternalIO.ReadPayload("p_civ5_nil_ret"), "原生Civ5无返回值测试", "SetValue 返回 nil 时数据已真实落盘")
end)

test("T-10", "X2/X3 未初始化、非法键、分片缺失、单槽覆盖旧分片与 DB 异常隔离", function()
    -- 1. 未初始化时零异常安全返回 false / nil
    falsy(CAB_ExternalIO.WritePayload("k", "v", false), "未初始化 WritePayload 应返回 false")
    isNil(CAB_ExternalIO.ReadPayload("k"), "未初始化 ReadPayload 应返回 nil")

    local hid = initExternalIOOrFail()

    -- 2. 非法键安全拦截
    falsy(CAB_ExternalIO.WritePayload(nil, "v", false), "nil 键 WritePayload 返回 false")
    falsy(CAB_ExternalIO.WritePayload("", "v", false), "空串键 WritePayload 返回 false")
    falsy(CAB_ExternalIO.WritePayload(123, "v", false), "非字符串键 WritePayload 返回 false")
    isNil(CAB_ExternalIO.ReadPayload(nil), "nil 键 ReadPayload 返回 nil")
    isNil(CAB_ExternalIO.ReadPayload(""), "空串键 ReadPayload 返回 nil")
    isNil(CAB_ExternalIO.ReadPayload("never_written_key"), "不存在的键 ReadPayload 返回 nil")

    -- 3. 分片缺失时 ReadPayload 必须返回 nil（绝不静默拼出残缺载荷）
    local big = string.rep("分片測試", 600)
    truthy(CAB_ExternalIO.WritePayload("k_missing_part", big, false), "先写入多分片载荷")
    S.pyDb.deleteKey(hid, "k_missing_part#chunk_2")
    isNil(CAB_ExternalIO.ReadPayload("k_missing_part"), "任一分片缺失时 ReadPayload 应返回 nil")

    -- 4. 短单槽位覆盖历史分片键：#chunk_count 置 0 后应读出最新短串而非旧分片
    truthy(CAB_ExternalIO.WritePayload("k_overwrite", big, false), "先写入历史多分片")
    truthy(CAB_ExternalIO.WritePayload("k_overwrite", "new_short_val", false), "覆盖为短单槽位")
    eq(CAB_ExternalIO.ReadPayload("k_overwrite"), "new_short_val", "覆盖后应准确返回最新短串")

    -- 5. DB SetValue/GetValue 抛错与返回 false 均安全隔离
    S.faults.setThrowOnKey = "k_err#chunk_2"
    falsy(CAB_ExternalIO.WritePayload("k_err", big, false), "分片写故障应中止返回 false")
    S.faults.setThrowOnKey = nil

    S.faults.setReturnFalseOnKey = "k_false"
    falsy(CAB_ExternalIO.WritePayload("k_false", "abc", false), "SetValue 返回 false 应判定写入失败")
    S.faults.setReturnFalseOnKey = nil

    S.faults.getThrowOnKey = "k_overwrite#chunk_count"
    isNil(CAB_ExternalIO.ReadPayload("k_overwrite"), "GetValue 读异常应安全返回 nil")
    S.faults.getThrowOnKey = nil
end)

test("T-11", "X4/X5 WriteHeartbeat 7 字段契约与 PushTurnOverview 原子屏障写序审计（I-03 / A-04）", function()
    local hid = initExternalIOOrFail()
    S.setGameState({ turn = 45, activePlayer = 0, turnActive = true })

    -- 1. WriteHeartbeat 全部 7 字段契约校验（玩家活动回合）
    truthy(CAB_ExternalIO.WriteHeartbeat("IDLE", 7), "WriteHeartbeat 应返回 true")
    local okHbStr, hbRaw = S.pyDb.readTextStrict(hid, "bridge_heartbeat")
    truthy(okHbStr, "bridge_heartbeat 应可被 Python 严格文本读取")
    local pyOk, pyType = __py_json_loads_check(hbRaw)
    truthy(pyOk, "bridge_heartbeat 须通过 Python json.loads：" .. tostring(pyType))
    falsy(hbRaw:find("__is_object", 1, true) ~= nil, "bridge_heartbeat 不应泄露 __is_object")

    local hbObj, hbErr = CAB_Json.Decode(hbRaw)
    isNil(hbErr, "bridge_heartbeat 解码无错")
    eq(hbObj.turn, 45, "turn 字段一致")
    eq(hbObj.active_player, 0, "active_player 字段一致")
    truthy(hbObj.is_turn_active, "is_turn_active 应为 true")
    eq(hbObj.status, "IDLE", "status 字段一致")
    eq(hbObj.turn_seq, 7, "turn_seq 字段一致")
    eq(hbObj.last_req_id, 0, "last_req_id 字段一致")
    isType(hbObj.clock_ms, "number", "clock_ms 应为 number")
    truthy(hbObj.clock_ms >= 0, "clock_ms 应为非负数")

    -- 非活动回合（AI 回合）心跳校验
    S.setGameState({ turn = 46, activePlayer = 0, turnActive = false })
    truthy(CAB_ExternalIO.WriteHeartbeat("AI_TURN_PROCESSING", 8), "AI 回合心跳写入成功")
    local _, hbAiRaw = S.pyDb.readTextStrict(hid, "bridge_heartbeat")
    local hbAi, _ = CAB_Json.Decode(hbAiRaw)
    eq(hbAi.turn, 46, "AI 回合 turn 一致")
    falsy(hbAi.is_turn_active, "AI 回合 is_turn_active 应为 false")
    eq(hbAi.status, "AI_TURN_PROCESSING", "AI 回合 status 一致")

    -- 2. PushTurnOverview 大包分片写序审计（I-03）：
    --    turn_overview_auto 分片全部落盘 -> turn_overview_auto_seq -> bridge_heartbeat("TURN_SYNCED")
    S.setGameState({ turn = 47, activePlayer = 0, turnActive = true })
    local units = {}
    for i = 1, 60 do
        units[i] = {
            __is_object = true,
            unit_id = 1000 + i,
            name = "精銳長劍士與重裝騎士第" .. tostring(i) .. "軍團😀",
            x = i,
            y = 10,
            hp = 100,
        }
    end
    local bigOverview = {
        __is_object = true,
        turn_number = 47,
        active_player_id = 0,
        player_civ = "羅馬帝國",
        our_units = units,
    }

    S.db.clearWriteLog()
    truthy(CAB_ExternalIO.PushTurnOverview(bigOverview, 3), "PushTurnOverview 大包应成功")

    local idxChunk1 = S.db.firstWriteIndex("turn_overview_auto#chunk_1")
    local idxChunkCount = S.db.lastWriteIndex("turn_overview_auto#chunk_count")
    local idxMain = S.db.lastWriteIndex("turn_overview_auto")
    local idxSeq = S.db.firstWriteIndex("turn_overview_auto_seq")
    local idxHb = S.db.firstWriteIndex("bridge_heartbeat")

    notNil(idxChunk1, "大态势包应触发分片写入")
    notNil(idxChunkCount, "应写入 turn_overview_auto#chunk_count")
    notNil(idxMain, "应写入 turn_overview_auto 主标记")
    notNil(idxSeq, "应写入 turn_overview_auto_seq 原子序号屏障")
    notNil(idxHb, "应写入 bridge_heartbeat")
    truthy(idxChunk1 < idxChunkCount, "分片数据必须先于 #chunk_count 写入")
    truthy(idxChunkCount < idxMain, "#chunk_count 必须先于主槽位标记写入")
    truthy(idxMain < idxSeq, "载荷全部落盘必须严格先于 turn_overview_auto_seq（红线 I-03）")
    truthy(idxSeq < idxHb, "turn_overview_auto_seq 必须严格先于 TURN_SYNCED 心跳（红线 I-03）")

    local okSeqRead, seqVal = S.pyDb.readTextStrict(hid, "turn_overview_auto_seq")
    truthy(okSeqRead, "turn_overview_auto_seq 应可被 Python 读出")
    eq(tonumber(seqVal), 3, "turn_overview_auto_seq 数值应为 3（兼容 SQLite VARIANT 亲和性）")
    local _, hbSyncRaw = S.pyDb.readTextStrict(hid, "bridge_heartbeat")
    local hbSync, _ = CAB_Json.Decode(hbSyncRaw)
    eq(hbSync.status, "TURN_SYNCED", "PushTurnOverview 后心跳状态应为 TURN_SYNCED")
    eq(hbSync.turn_seq, 3, "PushTurnOverview 后心跳 turn_seq 应为 3")

    local okOv, ovJson, _, ovChunks = S.pyDb.readChunkedBytes(hid, "turn_overview_auto")
    truthy(okOv, "Python bytes 拼片读回 turn_overview_auto 应成功：" .. tostring(ovJson))
    truthy(ovChunks >= 2, "turn_overview_auto 应分为多片")
    local ovPyOk, ovPyInfo = __py_json_loads_check(ovJson)
    truthy(ovPyOk, "turn_overview_auto 须为合法 JSON：" .. tostring(ovPyInfo))

    -- 3. 故障注入验证红线 I-03：前置分片失败严禁推进 turn_overview_auto_seq 与 bridge_heartbeat
    S.db.clearWriteLog()
    S.faults.setThrowOnKey = "turn_overview_auto#chunk_2"
    falsy(CAB_ExternalIO.PushTurnOverview(bigOverview, 4), "分片写入失败时 PushTurnOverview 应返回 false")
    S.faults.setThrowOnKey = nil
    isNil(S.db.firstWriteIndex("turn_overview_auto_seq"), "分片失败时严禁写入 turn_overview_auto_seq")
    isNil(S.db.firstWriteIndex("bridge_heartbeat"), "分片失败时严禁写入 TURN_SYNCED 心跳")

    -- 序号屏障写入失败时严禁写入 TURN_SYNCED 心跳
    S.db.clearWriteLog()
    S.faults.setThrowOnKey = "turn_overview_auto_seq"
    falsy(CAB_ExternalIO.PushTurnOverview({ __is_object = true, turn_number = 48 }, 5), "序号屏障写失败应返回 false")
    S.faults.setThrowOnKey = nil
    isNil(S.db.firstWriteIndex("bridge_heartbeat"), "序号屏障失败时严禁写入 TURN_SYNCED 心跳")

    -- 非法循环表或非表入参零 DB 写入
    S.db.clearWriteLog()
    local loopTbl = { __is_object = true }
    loopTbl.self = loopTbl
    falsy(CAB_ExternalIO.PushTurnOverview(loopTbl, 6), "循环引用态势表应返回 false")
    falsy(CAB_ExternalIO.PushTurnOverview("not_a_table", 6), "非表态势入参应返回 false")
    eq(#S.db.writeLog, 0, "编码失败或非法入参不应产生任何 DB 写入")
end)

test("T-12", "X6 SendRpcResponse 原子发布屏障写序、信封契约与循环表降级兜底（I-03 / I-05 / A-04）", function()
    local hid = initExternalIOOrFail()

    -- 1. 大载荷成功响应：先写完 rpc_response 全部分片，最后一步写 rpc_response_req_id
    local bigData = {
        __is_object = true,
        policy_notes = string.rep("傳統與自主社會政策說明😀|", 220),
        count = 220,
    }
    S.db.clearWriteLog()
    truthy(CAB_ExternalIO.SendRpcResponse(101, true, bigData, nil, false), "大载荷响应发送应成功")

    local idxLastResp = S.db.lastWriteIndex("rpc_response")
    local idxLastCnt = S.db.lastWriteIndex("rpc_response#chunk_count")
    local idxBarrier = S.db.firstWriteIndex("rpc_response_req_id")
    notNil(idxLastResp, "应写入 rpc_response")
    notNil(idxLastCnt, "应写入 rpc_response#chunk_count")
    notNil(idxBarrier, "应写入 rpc_response_req_id 屏障")
    truthy(idxLastCnt < idxLastResp, "#chunk_count 应在 rpc_response 主标记之前")
    truthy(idxLastResp < idxBarrier, "rpc_response 全部落盘必须严格先于 rpc_response_req_id（红线 I-03）")
    eq(idxBarrier, #S.db.writeLog, "rpc_response_req_id 必须为最后一次 DB 写入")

    local okBarRead, barrierVal = S.pyDb.readTextStrict(hid, "rpc_response_req_id")
    truthy(okBarRead, "rpc_response_req_id 应可被 Python 读出")
    eq(tonumber(barrierVal), 101, "屏障值应为 101（兼容 SQLite VARIANT 亲和性）")
    local okResp, respJson, _, respChunks = S.pyDb.readChunkedBytes(hid, "rpc_response")
    truthy(okResp, "Python bytes 拼片读回 rpc_response 应成功")
    truthy(respChunks >= 2, "大响应应自动分片")
    local pyValid, _ = __py_json_loads_check(respJson)
    truthy(pyValid, "rpc_response 须通过 Python json.loads")
    local parsedResp, decErr = CAB_Json.Decode(respJson)
    isNil(decErr, "rpc_response 解码无错")
    eq(parsedResp.req_id, 101, "req_id 匹配")
    truthy(parsedResp.ok, "ok 为 true")
    eq(parsedResp.data.count, 220, "data 内容完整")
    isNil(parsedResp.error, "成功响应不应携带 error")

    -- 2. forceChunked=true 短响应 + 错返信封校验
    S.db.clearWriteLog()
    truthy(CAB_ExternalIO.SendRpcResponse(102, false, nil, "Unit is dead", true), "强制分片错返应成功")
    eq(S.db.lastWriteIndex("rpc_response_req_id"), #S.db.writeLog, "屏障仍须为最后一步写入")
    local okErrResp, errRespJson, _, errChunks = S.pyDb.readChunkedBytes(hid, "rpc_response")
    truthy(okErrResp, "强制分片错返可读")
    eq(errChunks, 1, "短串强制分片应为 1 片")
    local parsedErr, _ = CAB_Json.Decode(errRespJson)
    eq(parsedErr.req_id, 102, "req_id=102")
    falsy(parsedErr.ok, "ok 为 false")
    isNil(parsedErr.data, "错返 data 为 nil")
    eq(parsedErr.error, "Unit is dead", "error 文案一致")

    -- 3. 故障注入验证红线 I-03：载荷写入失败严禁推进 rpc_response_req_id
    S.db.clearWriteLog()
    S.faults.setThrowOnKey = "rpc_response#chunk_2"
    falsy(CAB_ExternalIO.SendRpcResponse(103, true, bigData, nil, false), "分片失败时 SendRpcResponse 应返回 false")
    S.faults.setThrowOnKey = nil
    isNil(S.db.firstWriteIndex("rpc_response_req_id"), "分片失败时严禁更新 rpc_response_req_id 屏障")
    local _, stillOldBarrier = S.pyDb.readTextStrict(hid, "rpc_response_req_id")
    eq(tonumber(stillOldBarrier), 102, "库内 rpc_response_req_id 应仍保持旧值 102")

    -- 4. 异常隔离（I-05）：dataTable 含循环引用时自动降级写回 ok=false JSON encode error
    local cyclicData = { __is_object = true, name = "bad" }
    cyclicData.loop = cyclicData
    S.db.clearWriteLog()
    truthy(CAB_ExternalIO.SendRpcResponse(104, true, cyclicData, nil, false), "循环引用应触发降级写回并返回 true")
    eq(S.db.lastWriteIndex("rpc_response_req_id"), #S.db.writeLog, "降级响应仍遵守屏障写序")
    local okFb, fbJson = S.pyDb.readChunkedBytes(hid, "rpc_response")
    truthy(okFb, "降级响应应可正常读取")
    local fbObj, fbErr = CAB_Json.Decode(fbJson)
    isNil(fbErr, "降级响应 JSON 合法")
    eq(fbObj.req_id, 104, "降级响应 req_id=104")
    falsy(fbObj.ok, "降级响应 ok 必须为 false")
    contains(fbObj.error, "JSON encode error:", "降级响应 error 应指明编码失败")
end)

test("T-13", "X7 PollIncomingRequest 轻量空轮询、单调水位线与严格 rpc_session_id 重置（I-04 / A-05）", function()
    local received = {}
    local hid = initExternalIOOrFail(function(reqObj)
        received[#received + 1] = reqObj
        CAB_ExternalIO.SendRpcResponse(reqObj.req_id, true, {
            __is_object = true,
            echoed_method = reqObj.method,
            echoed_session = reqObj.session_id,
            echoed_payload_len = #(reqObj.params.text or ""),
        }, nil, false)
    end)

    -- 1. 空库轻量轮询：返回 false，且严格仅触发 2 次 GetValue（session + req_id）
    local readsBefore = S.guard.totalDbReads
    falsy(CAB_ExternalIO.PollIncomingRequest(), "空库轮询应返回 false")
    eq(S.guard.totalDbReads - readsBefore, 2, "空轮询应严格仅执行 2 次轻量 GetValue")
    eq(#received, 0, "空轮询不触发回调")

    -- 2. 会话 A 正常请求 req_id=1，且测试缺省 params 自动规范化为 {}
    S.pyDb.sendRpcRequest(hid, 1, '{"method":"ping"}', "sess-A")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "发现新请求 #1 应返回 true")
    eq(#received, 1, "应触发回调 1 次")
    eq(received[1].req_id, 1, "req_id 规范化为 1")
    eq(received[1].method, "ping", "method 一致")
    isType(received[1].params, "table", "缺省 params 必须规范化为空表")
    eq(received[1].session_id, "sess-A", "自动补齐活跃 session_id")

    -- 3. 同一 req_id=1 再次轮询绝不重复消费（红线 I-04）
    falsy(CAB_ExternalIO.PollIncomingRequest(), "同 req_id=1 再次轮询应返回 false")
    eq(#received, 1, "同一 req_id 严禁触发两次回调")

    -- 4. 推进至 req_id=5（测试非 table params 规范化为 {} 与大中文分片请求重组）
    local bigCnText = string.rep("繁體中文請求載荷😀", 260)
    local chunkedReqJson = CAB_Json.Encode({
        __is_object = true,
        method = "test_large_payload",
        params = { __is_object = true, text = bigCnText },
    })
    truthy(#chunkedReqJson > 3000, "测试请求应大于 3000B 触发 Python 侧分片写入")
    S.pyDb.sendRpcRequest(hid, 5, chunkedReqJson, "sess-A", 3000, false)
    truthy(CAB_ExternalIO.PollIncomingRequest(), "分片中文请求 #5 应被正确重组并消费")
    eq(#received, 2, "累计消费 2 条")
    eq(received[2].req_id, 5, "req_id=5")
    eq(received[2].params.text, bigCnText, "大分片中文请求经 Python 写 -> Lua 读重组 100% 一致")

    -- 5. 严格会话重置（D-04 / I-04）：
    --    a) 同一 session 下 req_id 变小（如 2 < 5）绝不盲猜重置
    S.pyDb.sendRpcRequest(hid, 2, '{"method":"ping"}', "sess-A")
    falsy(CAB_ExternalIO.PollIncomingRequest(), "同 session 下 req_id 变小绝不得盲猜重置")
    eq(#received, 2, "不应触发回调")

    --    b) rpc_session_id 置空串 "" 且 req_id=1 绝不盲猜重置
    S.pyDb.sendRpcRequest(hid, 1, '{"method":"ping"}', "")
    falsy(CAB_ExternalIO.PollIncomingRequest(), "空 rpc_session_id 不得触发水位线重置")
    eq(#received, 2, "不应触发回调")
    eq(CAB_ExternalIO.GetRuntimeState().active_session_id, "sess-A", "空 session 不得覆盖当前活跃 session")

    --    c) 客户端重启切换为新非空 rpc_session_id="sess-B" 且 req_id=1 -> 准确重置并消费
    S.pyDb.sendRpcRequest(hid, 1, '{"method":"ping","params":"bad_scalar_params"}', "sess-B")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "新非空 rpc_session_id 切换应重置水位线并消费 #1")
    eq(#received, 3, "切换新会话后 req_id=1 应触发回调")
    eq(received[3].req_id, 1, "新会话 req_id=1")
    eq(received[3].session_id, "sess-B", "新会话 session_id='sess-B'")
    isType(received[3].params, "table", "非 table params 应规范化为 {}")
    eq(CAB_ExternalIO.GetRuntimeState().active_session_id, "sess-B", "状态快照同步新会话")
    eq(CAB_ExternalIO.GetRuntimeState().last_processed_req_id, 1, "状态快照同步新水位线")

    --    d) 纯数字会话号（受 SQLite VARIANT 亲和性存为整数）同样能正确触发切换与重置
    S.pyDb.sendRpcRequest(hid, 1, '{"method":"ping"}', "20261128")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "纯数字新会话号应兼容 VARIANT 亲和性并重置水位线")
    eq(#received, 4, "纯数字新会话应触发回调")
    eq(received[4].session_id, "20261128", "纯数字会话号规范化为字符串")
    eq(CAB_ExternalIO.GetRuntimeState().active_session_id, "20261128", "状态快照记录纯数字会话串")
end)

test("T-14", "X7 PollIncomingRequest 异常全隔离：空载荷、损坏 JSON、非对象、回调抛错与 DB 故障（I-05 / A-05）", function()
    local cbCalls = 0
    local shouldThrow = false
    local hid = initExternalIOOrFail(function(reqObj)
        cbCalls = cbCalls + 1
        if shouldThrow then
            error("simulated dispatcher crash on req " .. tostring(reqObj.req_id))
        end
    end)

    local function readLastResp()
        local _, bar = S.pyDb.readTextStrict(hid, "rpc_response_req_id")
        local okR, raw = S.pyDb.readChunkedBytes(hid, "rpc_response")
        truthy(okR, "读取错误响应应成功")
        local obj, err = CAB_Json.Decode(raw)
        isNil(err, "错误响应 JSON 必须合法")
        return tonumber(bar), obj
    end

    -- 1. 空载荷（键不存在）与空字符串载荷
    S.pyDb.sendRpcRequest(hid, 1, nil, "sess-err")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "空载荷请求应消费并回错")
    eq(cbCalls, 0, "空载荷不得调用上层回调")
    local bar1, r1 = readLastResp()
    eq(bar1, 1, "屏障推进至 1")
    falsy(r1.ok, "空载荷 ok=false")
    contains(r1.error, "Empty RPC request payload", "错误信息匹配空载荷")
    falsy(CAB_ExternalIO.PollIncomingRequest(), "消费后同 req_id=1 不得重试")

    S.pyDb.sendRpcRequest(hid, 2, "", "sess-err")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "空串载荷应消费并回错")
    eq(cbCalls, 0, "空串载荷不得调用回调")
    local bar2, r2 = readLastResp()
    eq(bar2, 2, "屏障推进至 2")
    falsy(r2.ok, "空串 ok=false")
    contains(r2.error, "Empty RPC request payload", "空串错误信息匹配")

    -- 2. 损坏 JSON 与尾随垃圾 JSON
    S.pyDb.sendRpcRequest(hid, 3, '{"method":"ping"', "sess-err")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "截断 JSON 应消费并回错")
    eq(cbCalls, 0, "截断 JSON 不得调用回调")
    local bar3, r3 = readLastResp()
    eq(bar3, 3, "屏障推进至 3")
    falsy(r3.ok, "截断 JSON ok=false")
    contains(r3.error, "JSON decode error:", "截断 JSON 错误前缀匹配")

    S.pyDb.sendRpcRequest(hid, 4, '{"method":"ping"} trailing', "sess-err")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "尾随垃圾 JSON 应消费并回错")
    eq(cbCalls, 0, "尾随垃圾不得调用回调")
    local bar4, r4 = readLastResp()
    eq(bar4, 4, "屏障推进至 4")
    falsy(r4.ok, "尾随垃圾 ok=false")
    contains(r4.error, "JSON decode error:", "尾随垃圾错误前缀匹配")

    -- 3. 全部非对象合法 JSON（null / 数字 / 布尔 / 字符串 / 非空数组 / 空数组）必须被 ExternalIO 直接拦截
    local nonObjects = { "null", "123", "true", '"ping"', '[1, 2, 3]', "  []  " }
    local nextReqId = 5
    for _, sample in ipairs(nonObjects) do
        S.pyDb.sendRpcRequest(hid, nextReqId, sample, "sess-err")
        truthy(CAB_ExternalIO.PollIncomingRequest(), "非对象 JSON " .. sample .. " 应消费并直接回错")
        eq(cbCalls, 0, "非对象 JSON " .. sample .. " 严禁触达上层回调")
        local barN, rN = readLastResp()
        eq(barN, nextReqId, "非对象 JSON " .. sample .. " 屏障推进")
        falsy(rN.ok, "非对象 JSON " .. sample .. " ok=false")
        contains(rN.error, "Invalid RPC request: expected JSON object", "非对象错误信息精确匹配")
        nextReqId = nextReqId + 1
    end

    -- 4. 上层回调抛出未捕获 Lua 异常：经 pcall 兜底写回错返，且永不重试同一 req_id
    shouldThrow = true
    S.pyDb.sendRpcRequest(hid, nextReqId, '{"method":"ping","params":{}}', "sess-err")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "回调抛错时 PollIncomingRequest 应安全隔离并返回 true")
    eq(cbCalls, 1, "回调被调用 1 次")
    local barCb, rCb = readLastResp()
    eq(barCb, nextReqId, "回调抛错兜底响应屏障推进")
    falsy(rCb.ok, "回调抛错兜底 ok=false")
    contains(rCb.error, "Dispatcher callback error:", "错误信息指明回调异常")
    contains(rCb.error, "simulated dispatcher crash", "保留底层异常原文")
    falsy(CAB_ExternalIO.PollIncomingRequest(), "抛错请求已推进水位线，后续轮询严禁重复重试")
    eq(cbCalls, 1, "未发生二次重试")
    shouldThrow = false

    -- 5. DB 读锁临时故障隔离与自愈（风险 R-01）
    local reqAfterLock = nextReqId + 1
    S.pyDb.sendRpcRequest(hid, reqAfterLock, '{"method":"ping"}', "sess-err")
    S.faults.getThrowAll = "database is locked"
    falsy(CAB_ExternalIO.PollIncomingRequest(), "DB 读锁异常应返回 false 不崩溃帧循环")
    eq(cbCalls, 1, "读锁异常期间不得误触发回调")
    S.faults.getThrowAll = nil

    -- 故障解除后下一轮询周期自动自愈消费该请求
    truthy(CAB_ExternalIO.PollIncomingRequest(), "DB 恢复后应自动消费待处理请求")
    eq(cbCalls, 2, "DB 恢复后回调正常触发")
end)

test("T-15", "X8 GetRuntimeState 只读诊断快照完整性与零句柄/闭包泄露（I-06）", function()
    local hid = initExternalIOOrFail(function() end)
    S.pyDb.sendRpcRequest(hid, 9, '{"method":"ping"}', "sess-diag")
    truthy(CAB_ExternalIO.PollIncomingRequest(), "推进一次请求")

    local snap = CAB_ExternalIO.GetRuntimeState()
    isType(snap, "table", "快照应为 table")
    truthy(snap.__is_object, "快照应携带 __is_object = true")

    local keys = {}
    for k, v in pairs(snap) do
        keys[#keys + 1] = k
        local vt = type(v)
        truthy(
            vt == "boolean" or vt == "number" or vt == "string",
            "GetRuntimeState 字段 " .. tostring(k) .. " 不得泄露句柄/表/函数引用，实际类型=" .. vt
        )
    end
    table.sort(keys)
    same(
        keys,
        {
            "__is_object",
            "active_session_id",
            "chunk_size_bytes",
            "db_connected",
            "has_callback",
            "initialized",
            "last_processed_req_id",
        },
        "GetRuntimeState 返回键集合应精确匹配契约"
    )

    eq(snap.initialized, true, "initialized=true")
    eq(snap.db_connected, true, "db_connected=true")
    eq(snap.last_processed_req_id, 9, "last_processed_req_id=9")
    eq(snap.active_session_id, "sess-diag", "active_session_id='sess-diag'")
    eq(snap.has_callback, true, "has_callback=true")
    eq(snap.chunk_size_bytes, 3000, "chunk_size_bytes=3000")

    -- 快照可直接 JSON 序列化并通过 Python 校验
    local snapJson = CAB_Json.Encode(snap)
    local pyOk, pyInfo = __py_json_loads_check(snapJson)
    truthy(pyOk, "GetRuntimeState 快照应可合法序列化为 JSON：" .. tostring(pyInfo))

    -- 篡改返回快照表不得影响模块内部真实私有状态
    snap.initialized = false
    snap.last_processed_req_id = 9999
    snap.active_session_id = "tampered"
    local snap2 = CAB_ExternalIO.GetRuntimeState()
    truthy(snap2.initialized, "外部篡改快照不影响内部 initialized")
    eq(snap2.last_processed_req_id, 9, "外部篡改快照不影响内部 last_processed_req_id")
    eq(snap2.active_session_id, "sess-diag", "外部篡改快照不影响内部 active_session_id")
end)

-- -----------------------------------------------------------------------------
-- 第 4 节：运行器与收尾总检（FW-01）
-- -----------------------------------------------------------------------------

local PRINT_LINES_LIMIT = 30

local function matchesFilter(case, filterStr)
    if filterStr == nil or filterStr == "" then
        return true
    end
    local needle = tostring(filterStr):lower()
    if tostring(case.id):lower():find(needle, 1, true) ~= nil then
        return true
    end
    if tostring(case.title):lower():find(needle, 1, true) ~= nil then
        return true
    end
    return false
end

local function runOne(case)
    local handler = function(err)
        if type(err) == "table" and err.__skip then
            return err
        end
        return tostring(err) .. "\n" .. debug.traceback()
    end

    S.beginCase()
    local ok, result = xpcall(case.fn, handler)

    local status, message
    if ok then
        status, message = "pass", ""
    elseif type(result) == "table" and result.__skip then
        status, message = "skip", tostring(result.reason)
    else
        status, message = "fail", tostring(result)
    end

    local boundaryOk, boundaryMessage = S.endCase()
    if not boundaryOk then
        status = "fail"
        message = (message == "") and boundaryMessage or (message .. "\n" .. boundaryMessage)
    end

    if status == "fail" and #S.prints > 0 then
        local lines = {}
        for i = 1, math.min(#S.prints, PRINT_LINES_LIMIT) do
            lines[i] = S.prints[i]
        end
        message = message .. "\n—— 被测模块 print 输出 ——\n" .. table.concat(lines, "\n")
    end
    return status, message
end

local function runAll()
    local filterStr = __py_case_filter
    local summary = { passed = 0, failed = 0, skipped = 0, cases = {} }
    local counter = { pass = "passed", fail = "failed", skip = "skipped" }

    for _, case in ipairs(cases) do
        if matchesFilter(case, filterStr) then
            local status, message = runOne(case)
            summary[counter[status]] = summary[counter[status]] + 1
            summary.cases[#summary.cases + 1] = {
                id = case.id,
                status = status,
                title = case.title,
                message = message,
            }
        end
    end

    summary.guardViolations = #S.guard.violations
    summary.guardMissing = #S.guard.missing
    summary.totalOpens = S.guard.totalOpens
    summary.totalDbWrites = S.guard.totalDbWrites
    summary.totalDbReads = S.guard.totalDbReads

    if summary.guardViolations > 0 or summary.guardMissing > 0 then
        local parts = {}
        for _, record in ipairs(S.guard.violations) do
            parts[#parts + 1] = "红线违规：" .. record.owner .. "." .. record.method .. "()"
        end
        for _, record in ipairs(S.guard.missing) do
            parts[#parts + 1] = "桩未实现方法：" .. record.owner .. "." .. record.method .. "()"
        end
        summary.failed = summary.failed + 1
        summary.cases[#summary.cases + 1] = {
            id = "FW-01",
            status = "fail",
            title = "红线守卫或未实现方法累计不为零（框架收尾总检）",
            message = table.concat(parts, "\n"),
        }
    end
    return summary
end

return runAll()
