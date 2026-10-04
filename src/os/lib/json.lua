-- Exact JSON for API traffic: arrays/objects (even empty ones) and null survive a decode -> encode
-- round trip, strings stay UTF-8, object keys are written sorted (stable bytes for prompt caching).
local M = {}

local ARRAY = { __json = "array" }
local OBJECT = { __json = "object" }
M.null = setmetatable({}, { __json = "null", __tostring = function() return "null" end })

function M.array(t) return setmetatable(t or {}, ARRAY) end
function M.object(t) return setmetatable(t or {}, OBJECT) end
function M.isArray(t) return getmetatable(t) == ARRAY end

---------------------------------------------------------------- encode
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
              ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESC[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isSequence(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local encode
local function encodeValue(v, out)
  local t = type(v)
  if v == M.null or v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("can't encode " .. tostring(v), 0) end
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.17g", v)
    end
  elseif t == "string" then
    out[#out + 1] = encodeString(v)
  elseif t == "table" then
    local mt = getmetatable(v)
    local asArray
    if mt == ARRAY then asArray = true
    elseif mt == OBJECT then asArray = false
    else asArray = next(v) ~= nil and isSequence(v) end
    if asArray then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encodeValue(v[i], out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k)
        out[#out + 1] = ":"
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        encodeValue(val, out)
      end
      out[#out + 1] = "}"
    end
  else
    error("can't encode a " .. t, 0)
  end
end

function M.encode(v)
  local out = {}
  encodeValue(v, out)
  return table.concat(out)
end

---------------------------------------------------------------- decode
local function utf8char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                     0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function M.decode(s)
  local pos = 1
  local function fail(msg) error(("bad JSON at %d: %s"):format(pos, msg), 0) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end

  local value
  local function str()
    pos = pos + 1                                   -- opening quote
    local out = {}
    while true do
      local a, b = s:find('["\\]', pos)
      if not a then fail("unterminated string") end
      out[#out + 1] = s:sub(pos, a - 1)
      if s:sub(a, a) == '"' then pos = a + 1 break end
      local c = s:sub(a + 1, a + 1)
      if c == "u" then
        local hex = s:sub(a + 2, a + 5)
        if not hex:match("^%x%x%x%x$") then fail("bad \\u escape") end
        local cp = tonumber(hex, 16)
        pos = a + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
          local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        out[#out + 1] = utf8char(cp)
      else
        local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if not map[c] then fail("bad escape") end
        out[#out + 1] = map[c]
        pos = a + 2
      end
    end
    return table.concat(out)
  end

  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local t = M.object()
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then fail("expected a key") end
        local k = str()
        ws()
        if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
        pos = pos + 1
        t[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1
      local t = M.array()
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return M.null
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" or num == "-" then fail("unexpected character") end
      pos = pos + #num
      local n = tonumber(num)
      if not n then fail("bad number") end
      return n
    end
  end

  local v = value()
  ws()
  if pos <= #s then fail("trailing characters") end
  return v
end

return M
