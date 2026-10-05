-- Calculator for WardenOS: tap the keys or type. Enter =, Backspace deletes, q quits (when the line is empty).
-- Knows + - * / % ^, brackets, sqrt sin cos tan abs ln log floor ceil round, pi, e and ans.

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

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local T = (rawget(_G, "WardenOS") and WardenOS.theme) or {}
  local BG, PANEL, TEXT, DIM, ACC = T.bg or colors.black, T.panel or colors.gray, T.text or colors.white,
    T.dim or colors.lightGray, T.accent or colors.cyan
  local input, result, ans, err, history, last = "", "", nil, nil, {}, ""
  local zones = {}
  local KEYS = {
    { "C", "(", ")", "/", "<" },
    { "7", "8", "9", "*", "sqrt" },
    { "4", "5", "6", "-", "^" },
    { "1", "2", "3", "+", "%" },
    { "0", ".", "ans", "=", "pi" },
  }

  local function put(x, y, s, fg, bg)
    if y < 1 or y > H or x > W then return end
    if x < 1 then s = s:sub(2 - x) x = 1 end
    s = s:sub(1, W - x + 1)
    if s == "" then return end
    term.setCursorPos(x, y)
    term.setTextColor(fg or TEXT)
    term.setBackgroundColor(bg or BG)
    term.write(s)
  end

  local function calc()
    if input == "" then return end
    local v, e = evaluate(input, ans)
    if v then
      table.insert(history, 1, input .. " = " .. fmt(v))
      history[20] = nil
      ans, result, err, last = v, fmt(v), nil, input
      input = ""
    else
      err = e
    end
  end

  local function press(k)
    err = nil
    if k == "C" then input, result, last = "", "", ""
    elseif k == "<" then input = input:sub(1, -2)
    elseif k == "=" then calc()
    elseif k == "sqrt" then input = input .. "sqrt("
    else
      if input == "" and result ~= "" and k:match("^[%+%-%*/%%%^]$") then input = "ans" end
      input = input .. k
    end
  end

  local function draw()
    zones = {}
    term.setBackgroundColor(BG)
    term.clear()
    local sideW = (W >= 60) and math.min(30, math.floor(W / 3)) or 0
    local kw = W - sideW
    -- display
    for y = 1, 3 do put(1, y, string.rep(" ", kw), TEXT, PANEL) end
    local shown = input ~= "" and input or (result ~= "" and last or "0")
    if #shown > kw - 2 then shown = ".." .. shown:sub(-(kw - 4)) end
    put(kw - #shown, 1, shown, DIM, PANEL)
    local big = err and ("error: " .. err) or (input ~= "" and "" or (result ~= "" and ("= " .. result) or ""))
    if #big > kw - 2 then big = big:sub(1, kw - 2) end
    put(kw - #big, 2, big, err and (T.bad or colors.red) or TEXT, PANEL)
    -- keys
    local top = 4
    local bw = math.max(1, math.floor(kw / 5))
    local bh = math.max(1, math.floor((H - top + 1) / 5))
    local x0 = math.floor((kw - bw * 5) / 2) + 1
    for r, row in ipairs(KEYS) do
      for c, k in ipairs(row) do
        local x, y = x0 + (c - 1) * bw, top + (r - 1) * bh
        local bg = (k == "=") and ACC or ((k:match("^[%d%.]$")) and PANEL or BG)
        local fg = (k == "=") and BG or (k:match("^[%d%.]$") and TEXT or ACC)
        if k == "C" then fg = T.bad or colors.red end
        local w = bw - ((bw > 3) and 1 or 0)
        local hh = bh - ((bh > 2) and 1 or 0)
        local label = (#k > w) and k:sub(1, w) or k
        for i = 0, hh - 1 do
          local text = string.rep(" ", w)
          if i == math.floor((hh - 1) / 2) then
            local l = math.floor((w - #label) / 2)
            text = string.rep(" ", l) .. label .. string.rep(" ", w - l - #label)
          end
          if y + i <= H then put(x, y + i, text, fg, bg == BG and (T.panel or colors.gray) or bg) end
        end
        zones[#zones + 1] = { x, x + bw - 1, y, y + bh - 1, k }
      end
    end
    -- history (wide windows)
    if sideW > 0 then
      put(kw + 2, 1, "History", ACC)
      for i, h in ipairs(history) do
        if i + 1 > H then break end
        put(kw + 2, i + 1, h:sub(1, sideW - 2), DIM)
      end
    end
  end

  local function render()
    buf.setVisible(false)
    local old = term.redirect(buf)
    draw()
    term.redirect(old)
    buf.setVisible(true)
  end

  render()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "char" then
      if (a == "q" or a == "Q") and input == "" then break
      elseif a == "=" then press("=")
      elseif a:match("[%d%.%+%-%*/%%%^%(%)%a ]") then err = nil input = (input .. a):sub(1, 200) end
    elseif e == "paste" then
      input = (input .. a):sub(1, 200)
    elseif e == "key" then
      if a == keys.enter then press("=") elseif a == keys.backspace then press("<") end
    elseif e == "mouse_click" or e == "monitor_touch" then
      for _, z in ipairs(zones) do
        if b >= z[1] and b <= z[2] and c >= z[3] and c <= z[4] then press(z[5]) break end
      end
    elseif e == "term_resize" then
      W, H = parent.getSize()
      buf = window.create(parent, 1, 1, W, H, false)
    end
    render()
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return {
  name = "Calculator", short = "Calc", icon = "+-", color = colors.lightBlue, order = 65, w = 26, h = 16,
  art = { { " 42 ", "0000", "7777" }, { "+-x=", "3339", "8888" } },
  evaluate = evaluate, format = fmt,
  main = main,
}
