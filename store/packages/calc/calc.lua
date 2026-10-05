-- calc: a calculator for the terminal.
--   calc 2+3*4          prints 14
--   calc                interactive: one expression per line, "ans" is the last result, empty line or q quits
-- Knows + - * / % ^, brackets, sqrt sin cos tan abs ln log floor ceil round, pi and e.
-- tiny expression parser (no load(), so nothing but math can run)
local FN = { sqrt = math.sqrt, sin = math.sin, cos = math.cos, tan = math.tan, abs = math.abs, ln = math.log,
  log = function(x) return math.log(x) / math.log(10) end, floor = math.floor, ceil = math.ceil,
  round = function(x) return math.floor(x + 0.5) end }

local function evaluate(src, ans)
  local pos, tok = 1, nil
  local function nextTok()
    local s = src:match("^%s*()", pos)
    pos = s
    if pos > #src then tok = { "end" } return end
    local num = src:match("^%d*%.?%d+[eE][%+%-]?%d+", pos) or src:match("^%d+%.?%d*", pos) or src:match("^%.%d+", pos)
    if num then tok = { "num", tonumber(num) } pos = pos + #num return end
    local word = src:match("^%a+", pos)
    if word then tok = { "word", word:lower() } pos = pos + #word return end
    tok = { "op", src:sub(pos, pos) }
    pos = pos + 1
  end
  local expr
  local function atom()
    local t = tok
    if t[1] == "num" then nextTok() return t[2] end
    if t[1] == "op" and t[2] == "(" then
      nextTok()
      local v = expr()
      if tok[2] ~= ")" then error("missing )", 0) end
      nextTok()
      return v
    end
    if t[1] == "op" and t[2] == "-" then nextTok() return -atom() end
    if t[1] == "op" and t[2] == "+" then nextTok() return atom() end
    if t[1] == "word" then
      nextTok()
      if t[2] == "pi" then return math.pi end
      if t[2] == "e" then return math.exp(1) end
      if t[2] == "ans" then return ans or 0 end
      if FN[t[2]] then
        return FN[t[2]](atom())
      end
      error("unknown: " .. t[2], 0)
    end
    error(t[1] == "end" and "incomplete" or ("unexpected " .. tostring(t[2])), 0)
  end
  local function power()
    local v = atom()
    if tok[1] == "op" and tok[2] == "^" then nextTok() return v ^ power() end
    return v
  end
  local function term_()
    local v = power()
    while tok[1] == "op" and (tok[2] == "*" or tok[2] == "/" or tok[2] == "%") do
      local o = tok[2]
      nextTok()
      local r = power()
      if o == "*" then v = v * r elseif o == "/" then
        if r == 0 then error("division by zero", 0) end
        v = v / r
      else v = v % r end
    end
    return v
  end
  function expr()
    local v = term_()
    while tok[1] == "op" and (tok[2] == "+" or tok[2] == "-") do
      local o = tok[2]
      nextTok()
      local r = term_()
      v = (o == "+") and v + r or v - r
    end
    return v
  end
  local ok, res = pcall(function()
    nextTok()
    local v = expr()
    if tok[1] ~= "end" then error("unexpected " .. tostring(tok[2]), 0) end
    return v
  end)
  if not ok then return nil, res end
  if res ~= res then return nil, "not a number" end
  return res
end

local function fmt(v)
  if v == math.huge or v == -math.huge then return v > 0 and "inf" or "-inf" end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  local s = string.format("%.10g", v)
  return s
end

local args = { ... }
local color = term.isColour and term.isColour()
local function c(col) if color then term.setTextColor(col) end end

local ans
local function run(line)
  local v, err = evaluate(line, ans)
  if v then
    ans = v
    c(colors.lime) print(fmt(v))
  else
    c(colors.red) print("error: " .. tostring(err))
  end
  c(colors.white)
end

if #args > 0 then
  run(table.concat(args, " "))
  return
end
c(colors.cyan) print("calc - empty line or q quits, 'ans' = last result") c(colors.white)
while true do
  c(colors.yellow) write("calc> ") c(colors.white)
  local line = read()
  if not line or line == "" or line == "q" or line == "exit" then break end
  run(line)
end
