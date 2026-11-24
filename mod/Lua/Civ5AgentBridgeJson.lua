-- =============================================================================
-- 文件：Lua/Civ5AgentBridgeJson.lua
-- 做什么：面向《文明5》Lua 5.1 沙箱环境的零依赖纯 Lua JSON 序列化与反序列化库（CAB_JsonEncode / CAB_JsonDecode）。
-- 为什么：《文明5》内置 Lua 沙箱未提供标准 json 模块且禁用了外部 require；
--         为实现 Lua Mod 与外部 Python MCP Server 之间经 SQLite SimpleValues 表的结构化通信，
--         必须提供纯 Lua 实现的紧凑 JSON 编解码器（支持 UTF-8 中文直通、转义字符、数组、字典与 null）。
-- =============================================================================

CAB_JSON_NULL = setmetatable({}, {
    __tostring = function() return "null" end
})

-- -----------------------------------------------------------------------------
-- 函数：CAB_EscapeString(s)
-- 做什么：对 Lua 字符串执行 JSON 标准转义（双引号、反斜杠、控制字符），保留 UTF-8 多字节中文原样输出。
-- 为什么：保证生成的 JSON 字符串可被 Python json.loads 严格解析。
-- -----------------------------------------------------------------------------
local function CAB_EscapeString(s)
    local replacements = {
        ["\\"] = "\\\\",
        ["\""] = "\\\"",
        ["\b"] = "\\b",
        ["\f"] = "\\f",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t",
    }
    return "\"" .. tostring(s):gsub("[\\\"%c]", function(c)
        return replacements[c] or string.format("\\u%04x", string.byte(c))
    end) .. "\""
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_IsArray(t)
-- 做什么：判断一个 Lua table 是否为连续整数下标（1..N）的数组；空表默认按空数组 [] 处理（可通过 __is_object 标记覆盖）。
-- 为什么：Lua 只有 table 一种容器，序列化为 JSON 时需区分 [] 与 {}。
-- -----------------------------------------------------------------------------
local function CAB_IsArray(t)
    if t.__is_object then
        return false, 0
    end
    local maxIdx = 0
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
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
-- 函数：CAB_JsonEncode(val)
-- 做什么：将 Lua 值（nil/CAB_JSON_NULL/boolean/number/string/table）递归编码为单行紧凑 JSON 字符串。
-- 为什么：用于向 SQLite SimpleValues 表写入 turn_overview_auto 与 rpc_response。
-- -----------------------------------------------------------------------------
function CAB_JsonEncode(val)
    if val == nil or val == CAB_JSON_NULL then
        return "null"
    end
    local tv = type(val)
    if tv == "boolean" then
        return val and "true" or "false"
    elseif tv == "number" then
        if val ~= val or val <= -math.huge or val >= math.huge then
            return "null"
        end
        return tostring(val)
    elseif tv == "string" then
        return CAB_EscapeString(val)
    elseif tv == "table" then
        local isArr, len = CAB_IsArray(val)
        local parts = {}
        if isArr then
            for i = 1, len do
                parts[i] = CAB_JsonEncode(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                if k ~= "__is_object" and (type(k) == "string" or type(k) == "number") then
                    table.insert(parts, CAB_EscapeString(tostring(k)) .. ":" .. CAB_JsonEncode(v))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return CAB_EscapeString(tostring(val))
    end
end

-- -----------------------------------------------------------------------------
-- 函数：CAB_JsonDecode(str)
-- 做什么：将外部 Python 写入 SQLite 的 JSON 字符串递归解析为 Lua table/基础类型。
-- 为什么：用于解析 MCP Server 发来的 rpc_request，任何格式异常均通过 pcall 捕获避免阻塞游戏帧循环。
-- -----------------------------------------------------------------------------
local function CAB_SkipWhitespace(str, idx)
    local _, e = str:find("^[ \t\r\n]+", idx)
    return (e and e + 1) or idx
end

local CAB_ParseValue

local function CAB_ParseString(str, idx)
    -- idx 指向起始双引号 "
    local i = idx + 1
    local len = #str
    local out = {}
    local escapes = {
        ["\""] = "\"", ["\\"] = "\\", ["/"] = "/",
        ["b"] = "\b", ["f"] = "\f", ["n"] = "\n", ["r"] = "\r", ["t"] = "\t"
    }
    while i <= len do
        local c = str:sub(i, i)
        if c == "\"" then
            return table.concat(out), i + 1
        elseif c == "\\" then
            i = i + 1
            local esc = str:sub(i, i)
            if esc == "u" then
                local hex = str:sub(i + 1, i + 4)
                local code = tonumber(hex, 16) or 63
                if code < 128 then
                    table.insert(out, string.char(code))
                elseif code < 2048 then
                    table.insert(out, string.char(192 + math.floor(code / 64), 128 + (code % 64)))
                else
                    table.insert(out, string.char(
                        224 + math.floor(code / 4096),
                        128 + (math.floor(code / 64) % 64),
                        128 + (code % 64)
                    ))
                end
                i = i + 5
            else
                table.insert(out, escapes[esc] or esc)
                i = i + 1
            end
        else
            table.insert(out, c)
            i = i + 1
        end
    end
    error("JSON 字符串未闭合")
end

local function CAB_ParseArray(str, idx)
    local i = CAB_SkipWhitespace(str, idx + 1)
    local arr = {}
    if str:sub(i, i) == "]" then
        return arr, i + 1
    end
    local n = 1
    while i <= #str do
        local val
        val, i = CAB_ParseValue(str, i)
        arr[n] = val
        n = n + 1
        i = CAB_SkipWhitespace(str, i)
        local c = str:sub(i, i)
        if c == "]" then
            return arr, i + 1
        elseif c == "," then
            i = CAB_SkipWhitespace(str, i + 1)
        else
            error("JSON 数组缺少逗号或右括号，位置: " .. tostring(i))
        end
    end
    error("JSON 数组未闭合")
end

local function CAB_ParseObject(str, idx)
    local i = CAB_SkipWhitespace(str, idx + 1)
    local obj = {}
    if str:sub(i, i) == "}" then
        return obj, i + 1
    end
    while i <= #str do
        if str:sub(i, i) ~= "\"" then
            error("JSON 对象键必须为字符串，位置: " .. tostring(i))
        end
        local key
        key, i = CAB_ParseString(str, i)
        i = CAB_SkipWhitespace(str, i)
        if str:sub(i, i) ~= ":" then
            error("JSON 对象缺少冒号，位置: " .. tostring(i))
        end
        i = CAB_SkipWhitespace(str, i + 1)
        local val
        val, i = CAB_ParseValue(str, i)
        obj[key] = val
        i = CAB_SkipWhitespace(str, i)
        local c = str:sub(i, i)
        if c == "}" then
            return obj, i + 1
        elseif c == "," then
            i = CAB_SkipWhitespace(str, i + 1)
        else
            error("JSON 对象缺少逗号或右花括号，位置: " .. tostring(i))
        end
    end
    error("JSON 对象未闭合")
end

CAB_ParseValue = function(str, idx)
    local i = CAB_SkipWhitespace(str, idx)
    local c = str:sub(i, i)
    if c == "\"" then
        return CAB_ParseString(str, i)
    elseif c == "{" then
        return CAB_ParseObject(str, i)
    elseif c == "[" then
        return CAB_ParseArray(str, i)
    elseif str:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif str:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif str:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if s and e >= s then
            local num = tonumber(str:sub(s, e))
            if num ~= nil then
                return num, e + 1
            end
        end
        error("无法解析的 JSON 令牌，位置: " .. tostring(i))
    end
end

function CAB_JsonDecode(str)
    if type(str) ~= "string" or str == "" then
        return nil, "空字符串"
    end
    local ok, res = pcall(function()
        local val, _ = CAB_ParseValue(str, 1)
        return val
    end)
    if not ok then
        return nil, tostring(res)
    end
    return res, nil
end
