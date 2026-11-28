-- =============================================================================
-- 文件：mod/Lua/Civ5AgentBridgeJson.lua
-- 职责：面向《文明5：BNW v1.0.3.279》Lua 5.1 沙箱环境的零依赖纯 Lua JSON
--       序列化与反序列化库（同时导出新命名空间 CAB_Json 与向下兼容旧全局函数）。
-- 依赖：零依赖（禁止任何 include 或引擎 API 调用，严守单向分层与红线 I-01）。
-- 对外契约（《模块内部接口设计.md》§3.1 & 《M1Sub4工作计划.md》决策 D-03）：
--   * 命名空间表：CAB_Json = { Encode = CAB_JsonEncode, Decode = CAB_JsonDecode, NULL = CAB_JSON_NULL }
--   * 兼容全局符号：CAB_JSON_NULL、CAB_JsonEncode(val)、CAB_JsonDecode(str)
--   * 全部内部解析/转义辅助函数与常量严格声明为 local。
-- 生产边界加固（D-03）：
--   1. Decode 拦截根值后的非法尾随字符，并限制最大递归深度（MAX_DECODE_DEPTH = 64）；
--   2. Decode 严格校验 \uXXXX 四位十六进制，支持 UTF-16 代理对转 4 字节 UTF-8，
--      拦截孤立高/低代理、非法转义符及未转义 ASCII 控制字符（< 0x20）；
--   3. Encode 增加循环引用检测与最大递归深度防护（MAX_ENCODE_DEPTH = 64），
--      同时放行非环 DAG 共享子表，防止 Lua 5.1 C 栈溢出崩溃游戏；
--   4. 严格校验 RFC 8259 字面量与数字边界，NaN/±inf 统一编码为 "null"，
--      __is_object = true 强制输出 JSON 对象 {...} 并省略该标记键。
-- =============================================================================

-- JSON null 显式占位符（用于区分 Lua nil 缺省键与显式 JSON null 元素）
CAB_JSON_NULL = setmetatable({}, {
    __tostring = function()
        return "null"
    end
})

-- 编解码最大容器递归深度上限（防止恶意深嵌套或循环结构引发 Lua 5.1 栈溢出）
local MAX_ENCODE_DEPTH = 64
local MAX_DECODE_DEPTH = 64

-- JSON 字符串转义映射表（RFC 8259 标准短转义）
local ESCAPE_REPLACEMENTS = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

-- JSON 字符串反转义映射表（仅允许 RFC 8259 规定的 8 个单字符转义 + u）
local UNESCAPE_MAP = {
    ["\""] = "\"",
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

-- -----------------------------------------------------------------------------
-- 函数：CAB_EscapeString(s)
-- 做什么：对 Lua 字符串执行 RFC 8259 标准转义（双引号、反斜杠与 0x00..0x1F 控制字符），
--         原样保留 UTF-8 多字节字符（简/繁中文与 4 字节表情符号）。
-- 为什么：使用显式字节范围 [%z\001-\031\\"] 而非 locale 相关的 %c，确保在任意 Windows
--         区域设置下行为确定、支持 NUL (\0) 转 \u0000 且不破坏 UTF-8 多字节流。
-- 输入：s（任意值，经 tostring 转为字符串）。
-- 输出：带首尾双引号的合法 JSON 字符串字面量。
-- -----------------------------------------------------------------------------
local function CAB_EscapeString(s)
    return "\"" .. tostring(s):gsub("[%z\001-\031\\\"]", function(c)
        return ESCAPE_REPLACEMENTS[c] or string.format("\\u%04x", string.byte(c))
    end) .. "\""
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_IsArray(t)
-- 做什么：判断 Lua table 是否为连续正整数下标（1..N）数组；空表默认视为 []，
--         携带 __is_object = true 元标记时强制视为 JSON 对象 {}。
-- 为什么：Lua 只有 table 一种容器，必须借由连续下标判定与 __is_object 标记区分 [] 与 {}。
-- 输入：t（Lua table）。
-- 输出：(isArray: boolean, length: number)。
-- -----------------------------------------------------------------------------
local function CAB_IsArray(t)
    if t.__is_object then
        return false, 0
    end
    local maxIdx = 0
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= k or k == math.huge or math.floor(k) ~= k then
            return false, 0
        end
        if k > maxIdx then
            maxIdx = k
        end
        count = count + 1
    end
    if maxIdx ~= count then
        return false, 0
    end
    return true, count
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_EncodeValue(val, depth, visiting)
-- 做什么：带循环引用检测与递归深度上限保护的内部递归 JSON 编码器。
-- 为什么：防止表自引用或超深嵌套触发 Lua 5.1 栈溢出导致《文明5》进程崩溃；
--         退出表节点时清理 visiting[val] = nil，使合法非环 DAG 共享子表可正常编码。
-- 输入：val（待编码值）、depth（当前容器嵌套深度，顶层为 1）、visiting（当前递归栈访问集合）。
-- 输出：紧凑单行 JSON 片段字符串；检测到环或超限时抛出明确 Lua error。
-- -----------------------------------------------------------------------------
local function CAB_EncodeValue(val, depth, visiting)
    if val == nil or val == CAB_JSON_NULL then
        return "null"
    end
    local tv = type(val)
    if tv == "boolean" then
        return val and "true" or "false"
    elseif tv == "number" then
        -- 拦截 NaN、+inf 与 -inf，按约定统一降级为 JSON null
        if val ~= val or val <= -math.huge or val >= math.huge then
            return "null"
        end
        return tostring(val)
    elseif tv == "string" then
        return CAB_EscapeString(val)
    elseif tv == "table" then
        if visiting[val] then
            error("JSON encode error: circular reference detected")
        end
        if depth > MAX_ENCODE_DEPTH then
            error("JSON encode error: max recursion depth (" .. tostring(MAX_ENCODE_DEPTH) .. ") exceeded")
        end
        visiting[val] = true
        local isArr, len = CAB_IsArray(val)
        local parts = {}
        local nextDepth = depth + 1
        if isArr then
            for i = 1, len do
                parts[i] = CAB_EncodeValue(val[i], nextDepth, visiting)
            end
            visiting[val] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                if k ~= "__is_object" and (type(k) == "string" or type(k) == "number") then
                    table.insert(parts, CAB_EscapeString(tostring(k)) .. ":" .. CAB_EncodeValue(v, nextDepth, visiting))
                end
            end
            visiting[val] = nil
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return CAB_EscapeString(tostring(val))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_JsonEncode(val)
-- 做什么：将 Lua 值（nil/CAB_JSON_NULL/boolean/number/string/table）编码为单行紧凑 JSON 字符串。
-- 为什么：供 CAB_ExternalIO 序列化 turn_overview_auto、bridge_heartbeat 与 rpc_response；
--         遇到循环引用或超深嵌套时抛出错误，由上层 pcall 安全接管并写回错误响应。
-- 输入：val（任意 Lua 值）。
-- 输出：JSON 字符串。
-- -----------------------------------------------------------------------------
function CAB_JsonEncode(val)
    return CAB_EncodeValue(val, 1, {})
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_SkipWhitespace(str, idx)
-- 做什么：跳过 RFC 8259 允许的 4 种 JSON 空白字符（空格、\t、\r、\n）。
-- 为什么：避免 Lua 模式 %s 在不同区域设置下误匹配非标准空白符。
-- 输入：str（输入串）、idx（1-based 起始偏移）。
-- 输出：跳过空白后的 1-based 位置。
-- -----------------------------------------------------------------------------
local function CAB_SkipWhitespace(str, idx)
    local _, e = str:find("^[ \t\r\n]+", idx)
    return (e and e + 1) or idx
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_IsValueDelimiter(str, idx)
-- 做什么：判断位置 idx 是否已到达串尾或处于合法 JSON 值后继分隔符处。
-- 为什么：确保 true/false/null 与数字后不能粘连非法字符（如 true1、nullify、123abc）。
-- 输入：str（输入串）、idx（值结束后的下一位置）。
-- 输出：boolean。
-- -----------------------------------------------------------------------------
local function CAB_IsValueDelimiter(str, idx)
    if idx > #str then
        return true
    end
    local c = str:sub(idx, idx)
    return c == " " or c == "\t" or c == "\r" or c == "\n" or c == "," or c == "]" or c == "}"
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_EncodeUtf8CodePoint(cp)
-- 做什么：将合法 Unicode 码点（U+0000 .. U+10FFFF）编码为标准 1~4 字节 UTF-8 字符串。
-- 为什么：Lua 5.1 无内置 utf8.char，手工按位等价算术编码可零依赖支持 BMP 中文与
--         UTF-16 代理对合成的 4 字节 UTF-8 补充平面字符（如表情符号）。
-- 输入：cp（整数码点，0 <= cp <= 0x10FFFF）。
-- 输出：UTF-8 字节串。
-- -----------------------------------------------------------------------------
local function CAB_EncodeUtf8CodePoint(cp)
    if cp < 128 then
        return string.char(cp)
    elseif cp < 2048 then
        return string.char(
            192 + math.floor(cp / 64),
            128 + (cp % 64)
        )
    elseif cp < 65536 then
        return string.char(
            224 + math.floor(cp / 4096),
            128 + (math.floor(cp / 64) % 64),
            128 + (cp % 64)
        )
    else
        return string.char(
            240 + math.floor(cp / 262144),
            128 + (math.floor(cp / 4096) % 64),
            128 + (math.floor(cp / 64) % 64),
            128 + (cp % 64)
        )
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ParseHex4(str, startPos)
-- 做什么：严格校验并解析位于 startPos..startPos+3 的 4 位十六进制数。
-- 为什么：旧版直接 tonumber(hex, 16) or 63 会静默将畸形 \u 转义替换为 '?' 掩盖协议损坏；
--         生产加固要求显式报错拦截。
-- 输入：str（输入串）、startPos（4 位十六进制起始位置）。
-- 输出：0..65535 的整数码元；不合法时抛出明确错误。
-- -----------------------------------------------------------------------------
local function CAB_ParseHex4(str, startPos)
    local hex = str:sub(startPos, startPos + 3)
    if #hex ~= 4 or hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") == nil then
        error("JSON invalid \\uXXXX escape at pos " .. tostring(startPos))
    end
    return tonumber(hex, 16)
end

local CAB_ParseValue

-- -----------------------------------------------------------------------------
-- 函数：CAB_ParseString(str, idx)
-- 做什么：解析以双引号开头的 JSON 字符串，严格校验未转义控制字符、转义序列及
--         \uXXXX / UTF-16 代理对转 4 字节 UTF-8。
-- 为什么：严格符合 RFC 8259 字符串语法，杜绝畸形转义与孤立代理污染下游数据。
-- 输入：str（输入串）、idx（起始双引号位置）。
-- 输出：(parsedString, nextIdx)。
-- -----------------------------------------------------------------------------
local function CAB_ParseString(str, idx)
    local i = idx + 1
    local len = #str
    local out = {}
    while i <= len do
        local byteVal = str:byte(i)
        if byteVal == 34 then -- '"'
            return table.concat(out), i + 1
        elseif byteVal < 32 then
            error("JSON unescaped control character in string at pos " .. tostring(i))
        elseif byteVal == 92 then -- '\'
            i = i + 1
            if i > len then
                error("JSON unterminated escape sequence at pos " .. tostring(i))
            end
            local esc = str:sub(i, i)
            if esc == "u" then
                local code = CAB_ParseHex4(str, i + 1)
                if code >= 0xD800 and code <= 0xDBFF then
                    -- 高代理（Lead Surrogate）：必须紧跟 \uYYYY 低代理才能组成合法 4 字节 UTF-8
                    if str:sub(i + 5, i + 6) ~= "\\u" then
                        error("JSON missing low surrogate after high surrogate at pos " .. tostring(i))
                    end
                    local low = CAB_ParseHex4(str, i + 7)
                    if low < 0xDC00 or low > 0xDFFF then
                        error("JSON invalid low surrogate after high surrogate at pos " .. tostring(i + 7))
                    end
                    local cp = 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
                    table.insert(out, CAB_EncodeUtf8CodePoint(cp))
                    i = i + 11
                elseif code >= 0xDC00 and code <= 0xDFFF then
                    -- 孤立低代理（Trail Surrogate）：非法 JSON Unicode 序列
                    error("JSON unexpected lone low surrogate at pos " .. tostring(i))
                else
                    table.insert(out, CAB_EncodeUtf8CodePoint(code))
                    i = i + 5
                end
            else
                local mapped = UNESCAPE_MAP[esc]
                if mapped == nil then
                    error("JSON invalid escape character '\\" .. esc .. "' at pos " .. tostring(i))
                end
                table.insert(out, mapped)
                i = i + 1
            end
        else
            table.insert(out, str:sub(i, i))
            i = i + 1
        end
    end
    error("JSON unterminated string starting at pos " .. tostring(idx))
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ParseNumber(str, idx)
-- 做什么：按 RFC 8259 严格语法解析 JSON 数字（禁止前导零、孤立小数点、残缺指数与非法后继）。
-- 为什么：旧版正则 ^-?%d+%.?%d*[eE]?[+-]?%d* 会放行 01、1.、1e+ 等非法数字文本，
--         逐段扫描可精确拦截全部畸形数字。
-- 输入：str（输入串）、idx（数字起始位置）。
-- 输出：(numberValue, nextIdx)。
-- -----------------------------------------------------------------------------
local function CAB_ParseNumber(str, idx)
    local i = idx
    if str:sub(i, i) == "-" then
        i = i + 1
    end

    local first = str:sub(i, i)
    if first == "0" then
        i = i + 1
        local afterZero = str:sub(i, i)
        if afterZero ~= "" and afterZero:match("^[0-9]$") ~= nil then
            error("JSON leading zero in number at pos " .. tostring(idx))
        end
    elseif first ~= "" and first:match("^[1-9]$") ~= nil then
        local _, e = str:find("^[0-9]+", i)
        i = e + 1
    else
        error("JSON invalid number at pos " .. tostring(idx))
    end

    -- 可选小数部分：小数点后必须至少跟 1 位数字
    if str:sub(i, i) == "." then
        i = i + 1
        local _, e = str:find("^[0-9]+", i)
        if e == nil then
            error("JSON invalid number fraction at pos " .. tostring(idx))
        end
        i = e + 1
    end

    -- 可选科学计数指数部分：e/E 后可选 +/- 且必须至少跟 1 位数字
    local expChar = str:sub(i, i)
    if expChar == "e" or expChar == "E" then
        i = i + 1
        local signChar = str:sub(i, i)
        if signChar == "+" or signChar == "-" then
            i = i + 1
        end
        local _, e = str:find("^[0-9]+", i)
        if e == nil then
            error("JSON invalid number exponent at pos " .. tostring(idx))
        end
        i = e + 1
    end

    if not CAB_IsValueDelimiter(str, i) then
        error("JSON unexpected character after number at pos " .. tostring(i))
    end

    local num = tonumber(str:sub(idx, i - 1))
    if num == nil then
        error("JSON failed to convert number at pos " .. tostring(idx))
    end
    return num, i
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ParseArray(str, idx, depth)
-- 做什么：解析 JSON 数组 [...]，并在嵌套深度超限时中止。
-- 为什么：配合 MAX_DECODE_DEPTH 防止恶意深度嵌套数组耗尽 Lua 5.1 调用栈。
-- 输入：str（输入串）、idx（'[' 位置）、depth（当前嵌套深度）。
-- 输出：(arrayTable, nextIdx)。
-- -----------------------------------------------------------------------------
local function CAB_ParseArray(str, idx, depth)
    if depth > MAX_DECODE_DEPTH then
        error("JSON decode error: max recursion depth (" .. tostring(MAX_DECODE_DEPTH) .. ") exceeded")
    end
    local i = CAB_SkipWhitespace(str, idx + 1)
    local arr = {}
    if str:sub(i, i) == "]" then
        return arr, i + 1
    end
    local n = 1
    local nextDepth = depth + 1
    while i <= #str do
        local val
        val, i = CAB_ParseValue(str, i, nextDepth)
        arr[n] = val
        n = n + 1
        i = CAB_SkipWhitespace(str, i)
        local c = str:sub(i, i)
        if c == "]" then
            return arr, i + 1
        elseif c == "," then
            i = CAB_SkipWhitespace(str, i + 1)
        else
            error("JSON array expected ',' or ']' at pos " .. tostring(i))
        end
    end
    error("JSON unterminated array starting at pos " .. tostring(idx))
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ParseObject(str, idx, depth)
-- 做什么：解析 JSON 对象 {...}，强制键为合法 JSON 字符串并在超深嵌套时中止。
-- 为什么：严格拦截非字符串键、缺冒号、尾逗号及超深嵌套，保障解码输出结构可靠。
-- 输入：str（输入串）、idx（'{' 位置）、depth（当前嵌套深度）。
-- 输出：(objectTable, nextIdx)。
-- -----------------------------------------------------------------------------
local function CAB_ParseObject(str, idx, depth)
    if depth > MAX_DECODE_DEPTH then
        error("JSON decode error: max recursion depth (" .. tostring(MAX_DECODE_DEPTH) .. ") exceeded")
    end
    local i = CAB_SkipWhitespace(str, idx + 1)
    local obj = {}
    if str:sub(i, i) == "}" then
        return obj, i + 1
    end
    local nextDepth = depth + 1
    while i <= #str do
        if str:sub(i, i) ~= "\"" then
            error("JSON object key must be string at pos " .. tostring(i))
        end
        local key
        key, i = CAB_ParseString(str, i)
        i = CAB_SkipWhitespace(str, i)
        if str:sub(i, i) ~= ":" then
            error("JSON object expected ':' at pos " .. tostring(i))
        end
        i = CAB_SkipWhitespace(str, i + 1)
        local val
        val, i = CAB_ParseValue(str, i, nextDepth)
        obj[key] = val
        i = CAB_SkipWhitespace(str, i)
        local c = str:sub(i, i)
        if c == "}" then
            return obj, i + 1
        elseif c == "," then
            i = CAB_SkipWhitespace(str, i + 1)
        else
            error("JSON object expected ',' or '}' at pos " .. tostring(i))
        end
    end
    error("JSON unterminated object starting at pos " .. tostring(idx))
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_ParseValue(str, idx, depth)
-- 做什么：按首字符分派解析任意合法 JSON 值（字符串/对象/数组/布尔/null/数字）。
-- 为什么：对 true/false/null 强制校验边界分隔符，杜绝 true1、nullify 等脏前缀误通过。
-- 输入：str（输入串）、idx（当前扫描位置）、depth（当前递归深度）。
-- 输出：(luaValue, nextIdx)。
-- -----------------------------------------------------------------------------
CAB_ParseValue = function(str, idx, depth)
    local i = CAB_SkipWhitespace(str, idx)
    if i > #str then
        error("JSON unexpected end of input at pos " .. tostring(i))
    end
    local c = str:sub(i, i)
    if c == "\"" then
        return CAB_ParseString(str, i)
    elseif c == "{" then
        return CAB_ParseObject(str, i, depth)
    elseif c == "[" then
        return CAB_ParseArray(str, i, depth)
    elseif c == "t" then
        if str:sub(i, i + 3) == "true" and CAB_IsValueDelimiter(str, i + 4) then
            return true, i + 4
        end
        error("JSON invalid literal at pos " .. tostring(i))
    elseif c == "f" then
        if str:sub(i, i + 4) == "false" and CAB_IsValueDelimiter(str, i + 5) then
            return false, i + 5
        end
        error("JSON invalid literal at pos " .. tostring(i))
    elseif c == "n" then
        if str:sub(i, i + 3) == "null" and CAB_IsValueDelimiter(str, i + 4) then
            return nil, i + 4
        end
        error("JSON invalid literal at pos " .. tostring(i))
    elseif c == "-" or (c >= "0" and c <= "9") then
        return CAB_ParseNumber(str, i)
    else
        error("JSON unexpected token at pos " .. tostring(i))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_JsonDecode(str)
-- 做什么：将 JSON 字符串安全解析为对应 Lua 值；任何语法错误均经 pcall 捕获返回 (nil, err)。
-- 为什么：用于解析外部 MCP Server 写入的 rpc_request，解析完根值后必须检查是否残留
--         非法尾随字符，绝不放行半截拼接或被截断/污染的请求包。
-- 输入：str（JSON 字符串）。
-- 输出：成功返回 (parsedValue, nil)（注意根值 "null" 返回 (nil, nil)）；
--       失败返回 (nil, errorMessage)。
-- -----------------------------------------------------------------------------
function CAB_JsonDecode(str)
    if type(str) ~= "string" or str == "" then
        return nil, "Empty or non-string JSON input"
    end
    local ok, res = pcall(function()
        local val, nextIdx = CAB_ParseValue(str, 1, 1)
        nextIdx = CAB_SkipWhitespace(str, nextIdx)
        if nextIdx <= #str then
            error("JSON trailing characters at pos " .. tostring(nextIdx))
        end
        return val
    end)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end

-- 标准模块命名空间导出（《模块内部接口设计.md》§3.1 & 决策 D-03）
-- 100% 保留旧全局函数 CAB_JsonEncode / CAB_JsonDecode / CAB_JSON_NULL 向下兼容
CAB_Json = {
    Encode = CAB_JsonEncode,
    Decode = CAB_JsonDecode,
    NULL = CAB_JSON_NULL,
}
