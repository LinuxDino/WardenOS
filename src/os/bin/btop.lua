-- btop: live WardenOS stats in the terminal. q (or Ctrl+T) quits.
local W, H = term.getSize()
local color = term.isColour()
local W_OS = rawget(_G, "WardenOS")

local function tryLib(p)
  if not fs.exists(p) then return nil end
  local ok, m = pcall(dofile, p)
  return ok and type(m) == "table" and m or nil
end
local cfg = tryLib("/os/config.lua") or {}
local log = tryLib("/os/lib/log.lua")
local map = tryLib("/os/lib/map.lua")

local C = {
  bg = colors.black, box = colors.gray, title = colors.cyan, text = colors.white, dim = colors.lightGray,
  good = colors.green, warn = colors.yellow, bad = colors.red, ai = colors.orange,
}

---------------------------------------------------------------- drawing
local function at(x, y, s, fg, bg)
  if y < 1 or y > H or x > W then return end
  if x < 1 then s = s:sub(2 - x) x = 1 end
  s = s:sub(1, W - x + 1)
  term.setCursorPos(x, y)
  if color then term.setTextColor(fg or C.text) term.setBackgroundColor(bg or C.bg) end
  term.write(s)
end
local function box(y, h, title)
  at(1, y, "+" .. string.rep("-", W - 2) .. "+", C.box)
  at(3, y, " " .. title .. " ", C.title)
  for i = 1, h - 2 do at(1, y + i, "|", C.box) at(W, y + i, "|", C.box) end
  at(1, y + h - 1, "+" .. string.rep("-", W - 2) .. "+", C.box)
end
local function bar(x, y, w, frac, col)
  frac = math.max(0, math.min(1, frac or 0))
  local n = math.floor(w * frac + 0.5)
  if color then
    at(x, y, string.rep(" ", n), C.text, col)
    at(x + n, y, string.rep(" ", w - n), C.text, C.box)
  else
    at(x, y, string.rep("#", n) .. string.rep(".", w - n), C.text)
  end
end
local SPARK = { " ", ".", ":", "|" }
local function spark(x, y, values, w, col)
  local maxv = 1
  for _, v in ipairs(values) do if v > maxv then maxv = v end end
  local s = {}
  for i = math.max(1, #values - w + 1), #values do
    local lvl = math.floor(values[i] / maxv * 3 + 0.5)
    s[#s + 1] = SPARK[lvl + 1]
  end
  at(x, y, table.concat(s), col)
end

local function human(n)
  if n >= 1048576 then return ("%.1fM"):format(n / 1048576) end
  if n >= 1024 then return ("%.0fK"):format(n / 1024) end
  return tostring(n)
end
local function uptime()
  local s = math.floor(os.clock())
  return ("%dh%02dm%02ds"):format(math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end

---------------------------------------------------------------- data
local hist = { events = {}, rednet = {} }        -- per-second samples, last 60
local secEvents, secRednet = 0, 0
local seen = {}                                  -- drones heard directly (outside the desktop)

local function push(t, v)
  t[#t + 1] = v
  if #t > 60 then table.remove(t, 1) end
end

local function drones()
  local src = (W_OS and type(W_OS.drones) == "table") and W_OS.drones or seen
  local list = {}
  for id, d in pairs(src) do
    if type(d) == "table" then list[#list + 1] = { id = id, d = d } end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

---------------------------------------------------------------- screen
local function draw()
  W, H = term.getSize()
  if color then term.setBackgroundColor(C.bg) end
  term.clear()
  local narrow = W < 36

  at(1, 1, (" btop - %s %s"):format(cfg.name or "WardenOS", tostring(cfg.version or "")), C.title)
  local up = "up " .. uptime() .. " q:quit "
  if not narrow then at(W - #up + 1, 1, up, C.dim) end

  -- system
  local y = 2
  box(y, 5, "system")
  local okc, cap = pcall(fs.getCapacity, "/")
  local free = fs.getFreeSpace("/")
  local lw = narrow and 5 or 7
  at(3, y + 1, "disk", C.dim)
  if okc and type(cap) == "number" and cap > 0 then
    local used = cap - free
    local frac = used / cap
    local txt = (" %s/%s"):format(human(used), human(cap))
    bar(3 + lw, y + 1, math.max(4, W - 4 - lw - #txt), frac, frac > 0.9 and C.bad or (frac > 0.7 and C.warn or C.good))
    at(W - #txt - 1, y + 1, txt, C.text)
  else
    at(3 + lw, y + 1, human(free) .. " free", C.text)
  end
  at(3, y + 2, "events", C.dim)
  local ev = hist.events
  local evNow = ev[#ev] or 0
  at(3 + lw, y + 2, ("%d/s"):format(evNow), C.text)
  spark(3 + lw + 6, y + 2, ev, W - lw - 10, C.good)
  at(3, y + 3, "id", C.dim)
  at(3 + lw, y + 3, ("#%d %s"):format(os.getComputerID(), os.getComputerLabel() or ""):sub(1, W - lw - 4), C.text)

  -- network
  y = y + 5
  box(y, 4, "network")
  local modems = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then modems[#modems + 1] = n .. (rednet.isOpen(n) and "*" or "") end
  end
  at(3, y + 1, "modems", C.dim)
  at(3 + lw, y + 1, (#modems > 0 and table.concat(modems, " ") or "none"):sub(1, W - lw - 4), #modems > 0 and C.text or C.warn)
  local rn = hist.rednet
  local perMin = 0
  for i = math.max(1, #rn - 59), #rn do perMin = perMin + rn[i] end
  if log and log.rate then
    local ok, r = pcall(log.rate, "rednet")
    if ok and type(r) == "number" then perMin = r end
  end
  at(3, y + 2, "rednet", C.dim)
  at(3 + lw, y + 2, ("%d/min"):format(perMin), C.text)
  spark(3 + lw + 8, y + 2, rn, W - lw - 12, C.title)

  -- claude
  y = y + 4
  local calls = log and log.list and select(2, pcall(log.list, "claude"))
  local ai = W_OS and W_OS.claude
  if type(calls) == "table" or type(ai) == "table" then
    box(y, 3, "claude")
    local tokens, errs = 0, 0
    for _, c in ipairs(type(calls) == "table" and calls or {}) do
      if type(c) == "table" then
        tokens = tokens + (tonumber(c.input or c.input_tokens or c.inTokens) or 0)
          + (tonumber(c.output or c.output_tokens or c.outTokens) or 0)
        if c.error or c.err then errs = errs + 1 end
      end
    end
    local busy = type(ai) == "table" and ai.busy
    local txt = ("%s  %d calls  %s tok%s"):format(busy and "busy" or "idle", type(calls) == "table" and #calls or 0,
      human(tokens), errs > 0 and ("  " .. errs .. " err") or "")
    at(3, y + 1, txt:sub(1, W - 4), busy and C.ai or C.text)
    y = y + 3
  end

  -- drones
  local list = drones()
  local rows = H - y - 1
  if rows >= 1 then
    box(y, rows + 2, ("drones %d"):format(#list))
    if #list == 0 then
      at(3, y + 1, (rednet.isOpen() and "none heard yet" or "no modem open"):sub(1, W - 4), C.dim)
    end
    for i = 1, math.min(#list, rows) do
      local id, d = list[i].id, list[i].d
      local yy = y + i
      local online = d.seen and (os.clock() - d.seen) < 10
      at(3, yy, online and "*" or "-", online and C.good or C.dim)
      local name = ("#%d %s"):format(id, tostring(d.label or "")):sub(1, narrow and 8 or 14)
      at(5, yy, name, online and C.text or C.dim)
      local x = narrow and 14 or 20
      local fuel, limit = tonumber(d.fuel), tonumber(d.fuelLimit)
      if fuel and limit and limit > 0 then
        local bw = narrow and 4 or 8
        bar(x, yy, bw, fuel / limit, fuel < 200 and C.bad or C.good)
        x = x + bw + 1
      end
      local isAI = type(d.by) == "table" and d.by.who == "claude"
      local task = tostring(d.task or "?")
      if type(d.progress) == "table" and d.progress.total then
        task = task .. (" %s/%s"):format(tostring(d.progress.step or 0), tostring(d.progress.total))
      end
      if isAI then at(x, yy, "AI", C.ai) x = x + 3 end
      at(x, yy, task:sub(1, math.max(0, W - x - 1)), d.state == "working" and C.warn or C.dim)
    end
  end
end

---------------------------------------------------------------- loop
local timer = os.startTimer(1)
if rednet.isOpen() then rednet.broadcast({ t = "ping" }, "wardenos") end
draw()
while true do
  local e, a, b, c = os.pullEventRaw()
  secEvents = secEvents + 1
  if e == "terminate" then break end
  if e == "char" and (a == "q" or a == "Q") then break end
  if e == "key" and a == keys.q then break end
  if e == "rednet_message" then
    secRednet = secRednet + 1
    if c == "wardenos" and type(b) == "table" and b.t == "status" and b.kind == "turtle" then
      b.seen = os.clock()
      seen[a] = b
    end
  elseif e == "timer" and a == timer then
    push(hist.events, secEvents)
    push(hist.rednet, secRednet)
    secEvents, secRednet = 0, 0
    timer = os.startTimer(1)
    if not (W_OS and W_OS.drones) and rednet.isOpen() and #hist.events % 5 == 0 then
      rednet.broadcast({ t = "ping" }, "wardenos")
    end
    draw()
  elseif e == "term_resize" then
    draw()
  end
end
if color then term.setBackgroundColor(colors.black) term.setTextColor(colors.white) end
term.clear()
term.setCursorPos(1, 1)
