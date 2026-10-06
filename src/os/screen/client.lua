-- Warden Screen client: shows ONE page of the main WardenOS computer (the "brain") live, full screen, on the
-- biggest attached monitor (or the computer's own screen). No desktop, no login, no apps.
-- Started by /startup.lua on boot; set up with the installer ("install screen", or S on the welcome screen).
-- Settings: /os/screen/screen.cfg (see /os/screen/core.lua). Works on a standard computer and monitor too
-- (black and white). Touch the monitor (or press Left / Right) to change the page. Hold Ctrl+T to stop.
local core = dofile("/os/screen/core.lua")

local cfg, err = core.read()
if not cfg then
  printError("Warden Screen: " .. tostring(err))
  print("Set this computer up with the installer: install screen")
  return
end

local PROTO = core.PROTO
local SCALES = { 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }
local HEXD = "0123456789abcdef"
local HEX = {}
for i = 0, 15 do HEX[2 ^ i] = HEXD:sub(i + 1, i + 1) end
local floor, max, min = math.floor, math.max, math.min

local function clean(s) return (tostring(s or ""):gsub("[^\32-\126]", "?")) end
local function cut(s, n)
  s = clean(s)
  if n <= 0 then return "" end
  if #s > n then return n > 2 and (s:sub(1, n - 2) .. "..") or s:sub(1, n) end
  return s
end
local function num(n)
  n = tonumber(n)
  if not n then return "?" end
  local a = math.abs(n)
  if a >= 1e9 then return ("%.1fG"):format(n / 1e9) end
  if a >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if a >= 1e4 then return ("%.0fk"):format(n / 1e3) end
  if a >= 1e3 then return ("%.1fk"):format(n / 1e3) end
  return tostring(floor(n))
end
local function dur(s)
  s = floor(tonumber(s) or 0)
  if s < 60 then return s .. "s" end
  if s < 3600 then return floor(s / 60) .. "m" end
  return floor(s / 3600) .. "h" .. (floor(s / 60) % 60 > 0 and ((floor(s / 60) % 60) .. "m") or "")
end
local function wrap(str, width)
  local lines, line = {}, ""
  if width < 1 then return lines end
  for word in clean(str):gmatch("%S+") do
    while #word > width do
      if line ~= "" then lines[#lines + 1] = line line = "" end
      lines[#lines + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else lines[#lines + 1] = line line = word end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

---------------------------------------------------------------- canvas: a buffered, clipped screen
-- every row is kept as text + colour strings and written with blit only when it changed: no flicker and
-- nothing is ever written off-screen
local function newCanvas(t)
  local cv = { t = t }
  local okC, col = pcall(t.isColour or t.isColor)
  cv.colour = okC and col == true
  local function c(a, grey) return cv.colour and a or grey end
  cv.T = {
    bg = colors.black, text = colors.white, dim = colors.lightGray, panel = colors.gray,
    accent = c(colors.cyan, colors.white), good = c(colors.lime, colors.white), bad = c(colors.red, colors.white),
    warn = c(colors.yellow, colors.white), bar = c(colors.cyan, colors.lightGray), barBg = colors.gray,
    badBg = c(colors.red, colors.lightGray), badText = c(colors.white, colors.black),
  }
  local rt, rf, rb, shown = {}, {}, {}, {}
  function cv.resize()
    local okS, w, h = pcall(t.getSize)
    cv.w, cv.h = okS and w or 1, okS and h or 1
    shown = {}
  end
  function cv.clear(bg)
    local b = HEX[bg or cv.T.bg]
    for y = 1, cv.h do
      rt[y], rf[y], rb[y] = (" "):rep(cv.w), HEX[cv.T.text]:rep(cv.w), b:rep(cv.w)
    end
  end
  -- text with one fg / bg colour
  function cv.put(x, y, s, fg, bg)
    s = clean(s)
    return cv.blit(x, y, s, HEX[fg or cv.T.text]:rep(#s), HEX[bg or cv.T.bg]:rep(#s))
  end
  -- text with per-character colours (hex strings of the same length)
  function cv.blit(x, y, s, f, b)
    if y < 1 or y > cv.h or not rt[y] then return end
    x = floor(x)
    if x < 1 then
      s, f, b = s:sub(2 - x), f:sub(2 - x), b:sub(2 - x)
      x = 1
    end
    if x > cv.w then return end
    local n = min(#s, cv.w - x + 1)
    if n <= 0 then return end
    s, f, b = s:sub(1, n), f:sub(1, n), b:sub(1, n)
    rt[y] = rt[y]:sub(1, x - 1) .. s .. rt[y]:sub(x + n)
    rf[y] = rf[y]:sub(1, x - 1) .. f .. rf[y]:sub(x + n)
    rb[y] = rb[y]:sub(1, x - 1) .. b .. rb[y]:sub(x + n)
  end
  function cv.fill(y, bg) cv.put(1, y, (" "):rep(cv.w), cv.T.text, bg) end
  function cv.center(y, s, fg, bg) s = cut(s, cv.w) cv.put(floor((cv.w - #s) / 2) + 1, y, s, fg, bg) end
  function cv.bar(x, y, w, frac, fg)
    if w < 1 then return end
    frac = max(0, min(1, tonumber(frac) or 0))
    local n = floor(w * frac + 0.5)
    cv.put(x, y, (" "):rep(w), cv.T.text, cv.T.barBg)
    if n > 0 then
      if cv.colour then cv.put(x, y, (" "):rep(n), cv.T.text, fg or cv.T.bar)
      else cv.put(x, y, ("#"):rep(n), colors.white, cv.T.barBg) end
    end
  end
  function cv.flush()
    pcall(t.setCursorBlink, false)
    for y = 1, cv.h do
      local key = rt[y] .. rf[y] .. rb[y]
      if shown[y] ~= key then
        t.setCursorPos(1, y)
        t.blit(rt[y], rf[y], rb[y])
        shown[y] = key
      end
    end
  end
  cv.resize()
  cv.clear()
  return cv
end

---------------------------------------------------------------- output: monitor or this computer
local native = term.current()
local out, outName, isMon            -- where the page is drawn
local cv                             -- its canvas
local status                         -- the computer's own screen when the page is on a monitor
local fitKey

local function pickOutput()
  local name
  if cfg.monitor == "term" then
    name = nil
  elseif cfg.monitor and peripheral.getType(cfg.monitor) == "monitor" then
    name = cfg.monitor
  else
    local best, area
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "monitor" then
        local m = peripheral.wrap(n)
        local okS, w, h = pcall(m.getSize)
        if okS and w and (not area or w * h > area) then best, area = n, w * h end
      end
    end
    name = best
  end
  if name == outName and out then return false end
  outName = name
  if name then
    out, isMon = peripheral.wrap(name), true
    pcall(out.setTextScale, 0.5)
    status = newCanvas(native)
  else
    out, isMon, status = native, false, nil
  end
  cv = newCanvas(out)
  fitKey = nil
  return true
end

-- text scale: "max" = the largest scale that still fits nw x nh characters; "fill" = the smallest scale that is
-- not bigger than nw x nh (the map: as many cells as the brain sends, but no more)
local function fit(mode, nw, nh)
  if not isMon then return end
  local key = mode .. ":" .. nw .. "x" .. nh
  if key == fitKey then return end
  fitKey = key
  local chosen = 0.5
  local function size(s)
    pcall(out.setTextScale, s)
    local okS, w, h = pcall(out.getSize)
    return okS and w or 0, okS and h or 0
  end
  if mode == "max" then
    for _, s in ipairs(SCALES) do
      local w, h = size(s)
      if w >= nw and h >= nh then chosen = s break end
    end
  else
    for i = #SCALES, 1, -1 do
      local w, h = size(SCALES[i])
      if w <= nw and h <= nh then chosen = SCALES[i] break end
    end
  end
  pcall(out.setTextScale, chosen)
  cv.resize()
  cv.clear()
end

---------------------------------------------------------------- state
local brainId = cfg.brain
local brainLabel
local data, dataAt, dataFor           -- last answer, os.clock() it came, the page it is for
local lastSent, lastWho = -1e9, -1e9
local lastAnswer                      -- os.clock() of the last answer from the brain
local seq = 0
local modems = core.openModems()
local started = os.clock()
local OFFLINE = max(8, cfg.interval * 3)

local function pageName(id) local p = core.page(id) return p and p.name or tostring(id) end

local function brainState()
  local now = os.clock()
  if modems == 0 then return "NO MODEM", "bad" end
  if not brainId then return "searching", "warn" end
  if not lastAnswer then return now - started > OFFLINE and "OFFLINE" or "waiting", now - started > OFFLINE and "bad" or "warn" end
  if now - lastAnswer > OFFLINE then return "OFFLINE", "bad" end
  return "ok", "good"
end

local function request()
  lastSent = os.clock()
  if modems == 0 then return end
  if not brainId then
    if os.clock() - lastWho >= 5 then
      lastWho = os.clock()
      rednet.broadcast({ t = "screen_who" }, PROTO)
    end
    return
  end
  seq = seq + 1
  local w, h = cv.w, max(1, cv.h - 1)
  if cfg.page == "map" then h = max(1, cv.h - 2) end
  rednet.send(brainId, { t = "screen_req", page = cfg.page, w = w, h = h, seq = seq, center = cfg.center,
                         zoom = cfg.zoom, label = os.getComputerLabel() }, PROTO)
end

---------------------------------------------------------------- pages
local R = {}                          -- renderers: R.page(d, y1, y2) draw rows y1..y2

local function more(y, n)
  cv.put(2, y, cut(("+%d more (a bigger monitor shows more)"):format(n), cv.w - 2), cv.T.dim)
end

function R.drones(d, y1, y2)
  local T, W = cv.T, cv.w
  local list = type(d.drones) == "table" and d.drones or {}
  if #list == 0 then
    cv.center(y1 + 1, "No drones heard yet.", T.dim)
    cv.center(y1 + 2, "Drones report to the brain over rednet.", T.dim)
    return
  end
  local wide = W >= 60
  local per = wide and 2 or 3
  local room = y2 - y1 + 1
  local fitN = floor(room / per)
  local total = max(#list, tonumber(d.count) or 0)
  local show = #list
  if total > fitN then show = max(0, fitN - (room - fitN * per >= 1 and 0 or 1)) end
  show = min(show, #list)
  local y = y1
  for i = 1, show do
    local e = list[i]
    -- line 1: id, label, state
    local name = "#" .. tostring(e.id) .. (e.label and (" " .. e.label) or "")
    local st, sc
    if not e.online then st, sc = "offline " .. dur(e.ago), T.bad
    elseif e.state == "working" then st, sc = "working", T.warn
    else st, sc = tostring(e.state or "idle"), T.good end
    local fuel
    if e.fuel == "unlimited" then fuel = "fuel unlimited"
    elseif tonumber(e.fuel) then fuel = "fuel " .. num(e.fuel) end
    local pos = type(e.pos) == "table" and table.concat(e.pos, " ") or "no position"
    cv.put(1, y, cut(name, W - #st - 2), e.online and T.text or T.dim)
    cv.put(W - #st + 1, y, st, sc)
    local fy = wide and y or (y + 2)
    if fy <= y2 then
      local fx = wide and 26 or 3
      local fw = wide and (W - #st - 2 - fx) or (W - fx + 1)
      local lowFuel = tonumber(e.fuel) and e.fuel < 500
      local fs = fuel or "fuel ?"
      cv.put(fx, fy, cut(fs, fw), lowFuel and T.warn or T.dim)
      if #fs + 2 < fw then cv.put(fx + #fs + 2, fy, cut(pos, fw - #fs - 2), T.dim) end
    end
    -- line 2: the task, its progress, who started it; or the last result
    local ty = y + 1
    if ty <= y2 then
      if e.task and e.state == "working" then
        local s = "> " .. tostring(e.task)
        if e.phase then s = s .. " " .. e.phase end
        local frac
        if tonumber(e.total) and e.total > 0 then
          s = s .. (" %d/%d"):format(tonumber(e.step) or 0, e.total)
          frac = (tonumber(e.step) or 0) / e.total
        end
        if tonumber(e.taskTime) then s = s .. " " .. dur(e.taskTime) end
        if e.by then s = s .. (e.by == "claude" and " by Claude" or " by player") end
        local bw = frac and min(16, W - #s - 5) or 0
        if bw >= 6 then
          cv.put(3, ty, s, T.text)
          cv.bar(W - bw, ty, bw, frac)
        else
          cv.put(3, ty, cut(s, W - 3), T.text)
        end
      elseif type(e.last) == "table" then
        local s = "last: " .. tostring(e.last.name) .. (e.last.ok and " ok" or " FAILED")
        if not e.last.ok and e.last.info and e.last.info ~= "" then s = s .. ": " .. e.last.info end
        if e.last.by then s = s .. (e.last.by == "claude" and " (Claude)" or "") end
        cv.put(3, ty, cut(s, W - 3), e.last.ok and T.dim or T.bad)
      else
        cv.put(3, ty, "idle", T.dim)
      end
    end
    y = y + per
  end
  if show < total and y <= y2 then more(y, total - show) end
end

local MAPCOL = {                      -- char -> fg, bg (colour monitors)
  ["?"] = { colors.gray, colors.black }, ["."] = { colors.gray, colors.black }, ["#"] = { colors.lightGray, colors.gray },
  [":"] = { colors.yellow, colors.brown }, [","] = { colors.lime, colors.green }, ["~"] = { colors.lightBlue, colors.blue },
  ["^"] = { colors.yellow, colors.orange }, ["T"] = { colors.lime, colors.green }, ["o"] = { colors.yellow, colors.gray },
  ["="] = { colors.white, colors.lightGray }, ["P"] = { colors.white, colors.red }, ["D"] = { colors.black, colors.cyan },
  ["H"] = { colors.black, colors.yellow },
}
local MAPBW = {                       -- black and white: only the markers stand out
  ["P"] = { colors.black, colors.lightGray }, ["D"] = { colors.black, colors.white }, ["H"] = { colors.black, colors.white },
  ["?"] = { colors.gray, colors.black }, ["."] = { colors.gray, colors.black },
}

function R.map(d, y1, y2)
  local T, W = cv.T, cv.w
  local rows = type(d.rows) == "table" and d.rows or {}
  local legendY = y2
  local mh = y2 - y1                  -- rows for the map, the last one is the legend
  local rw = 0
  for _, r in ipairs(rows) do rw = max(rw, #r) end
  local x0 = max(1, floor((W - rw) / 2) + 1)
  local table_ = cv.colour and MAPCOL or MAPBW
  for i = 1, min(#rows, mh) do
    local r = clean(rows[i])
    local f, b = {}, {}
    for j = 1, #r do
      local c = table_[r:sub(j, j)]
      f[j] = HEX[c and c[1] or colors.white]
      b[j] = HEX[c and c[2] or colors.black]
    end
    cv.blit(x0, y1 + i - 1, r, table.concat(f), table.concat(b))
  end
  if #rows == 0 then cv.center(y1 + 1, "The map is empty.", T.dim) end
  local parts = {}
  local a = type(d.area) == "table" and d.area or {}
  if d.note then parts[#parts + 1] = d.note end
  if a.scale then parts[#parts + 1] = a.scale end
  if a.cx then parts[#parts + 1] = ("center %d %d"):format(a.cx, a.cz) end
  for _, l in ipairs(type(d.legend) == "table" and d.legend or {}) do
    if l[1] ~= "?" then parts[#parts + 1] = tostring(l[1]) .. " " .. tostring(l[2]) end
  end
  cv.put(1, legendY, cut(table.concat(parts, "  "), W), T.dim)
end

function R.me(d, y1, y2)
  local T, W = cv.T, cv.w
  if d.reading then cv.center(y1 + 1, "Reading the storage...", T.dim) return end
  if d.error then
    cv.put(2, y1, cut("No ME / RS storage on the brain.", W - 1), T.warn)
    local y = y1 + 2
    for _, l in ipairs(wrap(d.error, W - 2)) do
      if y > y2 then break end
      cv.put(2, y, l, T.dim)
      y = y + 1
    end
    return
  end
  local y = y1
  local b = type(d.bridge) == "table" and d.bridge or {}
  local name = (b.kind == "rs" and "Refined Storage" or "AE2 ME") .. " (" .. tostring(b.name) .. ")"
  local cs, cc = "online", T.good
  if b.connected == false then cs, cc = "NOT CONNECTED", T.bad end
  cv.put(1, y, cut(name, W - #cs - 1), T.accent)
  cv.put(W - #cs + 1, y, cs, cc)
  y = y + 1
  local function meter(label, cur, cap, unit, extra)
    if y > y2 then return end
    cur, cap = tonumber(cur), tonumber(cap)
    local s = label .. " " .. num(cur) .. (cap and cap > 0 and ("/" .. num(cap)) or "") .. (unit and (" " .. unit) or "")
      .. (extra or "")
    local bw = (cap and cap > 0 and cur) and min(20, W - #s - 3) or 0
    cv.put(1, y, cut(s, W), T.text)
    if bw >= 5 then cv.bar(W - bw + 1, y, bw, cur / cap, cur / cap > 0.9 and T.bad or nil) end
    y = y + 1
  end
  local e = type(d.energy) == "table" and d.energy or {}
  if tonumber(e.stored) then
    meter("Energy", e.stored, e.max, e.unit, tonumber(e.usage) and (" use " .. num(e.usage) .. "/t") or nil)
  end
  local s = type(d.storage) == "table" and d.storage or {}
  if tonumber(s.used) or tonumber(s.total) then meter("Storage", s.used, s.total, "bytes") end
  -- crafting
  local cpus = type(d.cpus) == "table" and d.cpus or nil
  local jobs = {}
  if cpus then
    local busy = 0
    for _, c in ipairs(cpus) do
      if c.busy then
        busy = busy + 1
        if c.item then jobs[#jobs + 1] = { item = c.item, amount = c.amount, progress = c.progress, total = c.total } end
      end
    end
    if y <= y2 then cv.put(1, y, cut(("Crafting CPUs: %d/%d busy"):format(busy, #cpus), W), busy > 0 and T.warn or T.dim) y = y + 1 end
  end
  if #jobs == 0 and type(d.tasks) == "table" then
    for _, t in ipairs(d.tasks) do if not t.done then jobs[#jobs + 1] = t end end
  end
  for i, j in ipairs(jobs) do
    if y > y2 - 2 or i > 4 then break end
    local pct = (tonumber(j.total) and j.total > 0 and tonumber(j.progress)) and (" %d%%"):format(floor(j.progress / j.total * 100)) or ""
    cv.put(2, y, cut(("crafting %s%s%s"):format(tonumber(j.amount) and (num(j.amount) .. " ") or "",
      (tostring(j.item):gsub("^[%w_%.%-]+:", "")), pct), W - 1), T.text)
    y = y + 1
  end
  -- top items
  local items = type(d.items) == "table" and d.items or {}
  if y <= y2 then
    local title = "Top items"
    if tonumber(d.types) then title = title .. (" (%s types, %s items)"):format(num(d.types), num(d.total)) end
    if tonumber(d.age) and d.age > 15 then title = title .. ", " .. dur(d.age) .. " old" end
    cv.put(1, y, cut(title, W), T.accent)
    y = y + 1
  end
  if d.itemsError and y <= y2 then cv.put(2, y, cut(d.itemsError, W - 1), T.bad) y = y + 1 end
  local cols = W >= 60 and 2 or 1
  local cw = floor(W / cols)
  local rowsLeft = y2 - y + 1
  for i, it in ipairs(items) do
    local col = floor((i - 1) / max(1, rowsLeft))
    if col >= cols then break end
    local r = (i - 1) % max(1, rowsLeft)
    local x = col * cw + 1
    local c = num(it.count)
    cv.put(x, y + r, (" "):rep(max(0, 6 - #c)) .. c, T.text)
    cv.put(x + 7, y + r, cut(it.display, cw - 8), T.dim)
  end
end

function R.claude(d, y1, y2)
  local T, W = cv.T, cv.w
  local y = y1
  if d.busy then
    cv.put(1, y, "BUSY", T.warn)
    cv.put(6, y, cut(d.status ~= "" and d.status or "working", W - 6), T.text)
  else
    cv.put(1, y, "idle", T.dim)
  end
  y = y + 2
  local dl = type(d.drones) == "table" and d.drones or {}
  if y <= y2 then cv.put(1, y, "Drones Claude is using", T.accent) y = y + 1 end
  if #dl == 0 and y <= y2 then cv.put(2, y, "none", T.dim) y = y + 1 end
  for _, e in ipairs(dl) do
    if y > y2 then break end
    local s = "#" .. tostring(e.id) .. (e.label and (" " .. e.label) or "") .. ": " .. tostring(e.text)
    if e.phase then s = s .. " - " .. e.phase end
    local frac
    if tonumber(e.total) and e.total > 0 then
      s = s .. (" %d/%d"):format(tonumber(e.step) or 0, e.total)
      frac = (tonumber(e.step) or 0) / e.total
    elseif e.pending then s = s .. " ..." end
    local bw = frac and min(12, W - #s - 4) or 0
    cv.put(2, y, cut(s, W - 1), e.running and T.text or T.dim)
    if bw >= 5 then cv.bar(W - bw + 1, y, bw, frac) end
    y = y + 1
  end
  local rec = type(d.recent) == "table" and d.recent or {}
  if y + 1 <= y2 then
    y = y + 1
    cv.put(1, y, "Recent tools", T.accent)
    y = y + 1
    if #rec == 0 and y <= y2 then cv.put(2, y, "none yet", T.dim) y = y + 1 end
    for _, r in ipairs(rec) do
      if y > y2 - 2 then break end
      local a = dur(r.ago) .. " ago"
      cv.put(2, y, a, T.dim)
      cv.put(12, y, cut(r.text, W - 12), T.text)
      y = y + 1
    end
  end
  -- API calls (the brain's debug log)
  if d.calls and y + 1 <= y2 then
    y = max(y + 1, y2 - 1)
    local s = ("API: %d call%s, %d error%s"):format(d.calls, d.calls == 1 and "" or "s", d.errors or 0, d.errors == 1 and "" or "s")
    local l = type(d.last) == "table" and d.last or nil
    if l then
      s = s .. ("; last %s ago"):format(dur(l.ago))
      if l.ms then s = s .. (", %.1fs"):format(l.ms / 1000) end
      if l.input then s = s .. ", in " .. num(l.input) .. " out " .. num(l.output) end
    end
    cv.put(1, y, cut(s, W), T.dim)
    if l and l.error and y + 1 <= y2 then cv.put(1, y + 1, cut("error: " .. l.error, W), T.bad) end
  end
end

function R.gps(d, y1, y2)
  local T, W = cv.T, cv.w
  local y = y1
  local g = tostring(d.grade or "none"):upper()
  local gc = (d.grade == "excellent" or d.grade == "good") and T.good or (d.grade == "fair" and T.warn or T.bad)
  local s = "Constellation: "
  cv.put(1, y, s, T.text)
  cv.put(#s + 1, y, g .. (tonumber(d.score) and (" " .. d.score .. "/100") or ""), gc)
  y = y + 1
  if y <= y2 then
    cv.put(1, y, cut(("%d host%s, %d online"):format(d.n or 0, d.n == 1 and "" or "s", d.online or 0), W), T.dim)
    y = y + 1
  end
  local hosts = type(d.hosts) == "table" and d.hosts or {}
  local adv = type(d.advice) == "table" and d.advice or {}
  -- advice first (short), then the hosts
  local advLines = {}
  for _, a in ipairs(adv) do for _, l in ipairs(wrap(a, W - 2)) do advLines[#advLines + 1] = l end end
  local maxAdv = max(1, min(#advLines, (y2 - y + 1) - min(#hosts, 6) - 2))
  for i = 1, min(#advLines, maxAdv) do
    if y > y2 then break end
    cv.put(2, y, advLines[i], T.dim)
    y = y + 1
  end
  if #hosts > 0 and y + 1 <= y2 then
    y = y + 1
    for i, h in ipairs(hosts) do
      if y > y2 then break end
      if y == y2 and i < #hosts then more(y, #hosts - i + 1) break end
      local st = h.online and ("ok " .. dur(h.ago)) or ("off " .. dur(h.ago))
      local name = "#" .. tostring(h.id) .. (h.self and "*" or "") .. (h.label and (" " .. h.label) or "")
      local p = ("%d %d %d"):format(h.x, h.y, h.z)
      cv.put(1, y, cut(name, 14), T.text)
      if W >= 32 then cv.put(16, y, cut(p, W - 16 - #st - 1), T.dim) end
      cv.put(W - #st + 1, y, st, h.online and T.good or T.bad)
      y = y + 1
    end
  end
end

-- what the page needs: mode, width, height (for the text scale)
local function needs()
  local d = dataFor == cfg.page and data or nil
  if cfg.page == "map" then return "fill", 60, 42 end
  if not d then return "max", 30, 8 end
  if cfg.page == "drones" then
    local n = max(1, #(type(d.drones) == "table" and d.drones or {}))
    return "max", 40, 1 + 3 * n
  elseif cfg.page == "me" then
    return "max", 40, 16
  elseif cfg.page == "claude" then
    return "max", 40, 14
  elseif cfg.page == "gps" then
    return "max", 40, 5 + #(type(d.hosts) == "table" and d.hosts or {}) + 3
  end
  return "max", 30, 10
end

---------------------------------------------------------------- drawing
local function drawStatus(st, sc)
  if not status then return end
  local T = status.T
  status.clear()
  status.fill(1, T.panel)
  status.put(2, 1, "Warden Screen", T.accent, T.panel)
  local y = 3
  local function row(k, v, c)
    if y > status.h - 1 then return end
    status.put(2, y, k, T.dim)
    status.put(10, y, cut(v, status.w - 10), c or T.text)
    y = y + 1
  end
  row("Page", pageName(cfg.page))
  row("Monitor", tostring(outName) .. (cv and (" " .. cv.w .. "x" .. cv.h) or ""))
  row("Brain", brainId and ("#" .. brainId .. (brainLabel and (" " .. brainLabel) or "")) or "searching...")
  row("Status", st, T[sc])
  row("Modems", modems > 0 and tostring(modems) or "NONE - attach a wireless or ender modem", modems > 0 and T.text or T.bad)
  status.fill(status.h, T.panel)
  status.put(2, status.h, cut("<- -> page   Hold Ctrl+T to stop", status.w - 2), T.dim, T.panel)
  status.flush()
end

local function draw()
  local mode, nw, nh = needs()
  fit(mode, nw, nh)
  local T, W, H = cv.T, cv.w, cv.h
  cv.clear()
  -- header: page name left, brain state + data age right
  cv.fill(1, T.panel)
  local st, sc = brainState()
  local right = st
  if st == "ok" and dataAt then right = "#" .. tostring(brainId) .. " " .. dur(os.clock() - dataAt) end
  if st == "OFFLINE" and dataAt then right = "OFFLINE " .. dur(os.clock() - dataAt) end
  local title = pageName(cfg.page)
  if W < #title + #right + 3 then right = cut(right, max(0, W - #title - 2)) end
  cv.put(2, 1, cut(title, W - 1), T.accent, T.panel)
  if #right > 0 then cv.put(W - #right, 1, right, T[sc], T.panel) end
  local d = dataFor == cfg.page and data or nil
  if d then
    if d.error and cfg.page ~= "me" then
      local y = 3
      for _, l in ipairs(wrap(d.error, W - 2)) do if y <= H then cv.put(2, y, l, T.bad) y = y + 1 end end
    else
      local ok, e = pcall(R[cfg.page] or function() end, d, 2, H)
      if not ok then cv.put(1, H, cut("draw error: " .. tostring(e), W), T.bad) end
    end
    if st == "OFFLINE" then
      cv.fill(H, T.badBg)
      cv.put(1, H, cut(" Brain offline - showing data from " .. dur(os.clock() - (dataAt or 0)) .. " ago", W), T.badText, T.badBg)
    end
  else
    local mid = max(2, floor(H / 2))
    local a, b
    if st == "NO MODEM" then a, b = "No modem", "Attach a wireless or ender modem."
    elseif st == "searching" then a, b = "Looking for the brain...", "Is the WardenOS computer on, with a modem?"
    elseif st == "OFFLINE" then a, b = "Brain #" .. tostring(brainId) .. " offline", "WardenOS must run (logged in) on it."
    else a, b = "Waiting for brain #" .. tostring(brainId) .. "...", "" end
    cv.center(mid, a, st == "OFFLINE" and T.bad or T.text)
    for i, l in ipairs(wrap(b, W - 2)) do cv.center(mid + 1 + i, l, T.dim) end
  end
  cv.flush()
  drawStatus(st, sc)
end

local function setPage(step)
  local i = core.pageIndex(cfg.page) or 1
  i = (i - 1 + step) % #core.PAGES + 1
  cfg.page = core.PAGES[i].id
  pcall(core.write, cfg)
  fitKey = nil
  request()
  draw()
end

---------------------------------------------------------------- run
pickOutput()
if isMon then pcall(out.setTextScale, 0.5) end
cv.resize()
local function main()
  request()
  draw()
  local tick = os.startTimer(1)
  while true do
    local ev = table.pack(os.pullEvent())
    local e = ev[1]
    if e == "timer" and ev[2] == tick then
      tick = os.startTimer(1)
      if os.clock() - lastSent >= cfg.interval then request() end
      -- auto brain: look again when it has been gone for a while
      if not cfg.brain and brainId and lastAnswer and os.clock() - lastAnswer > 30 then
        brainId, brainLabel = nil, nil
      end
      draw()
    elseif e == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
      local from, msg = ev[2], ev[3]
      if msg.t == "screen_here" and not brainId then
        brainId = from
        brainLabel = msg.label ~= nil and tostring(msg.label) or nil
        request()
        draw()
      elseif msg.t == "screen_data" and from == brainId then
        lastAnswer = os.clock()
        if type(msg.brain) == "table" and msg.brain.label ~= nil then brainLabel = tostring(msg.brain.label) end
        if msg.page == cfg.page then
          data, dataAt, dataFor = msg, os.clock(), msg.page
          draw()
        end
      end
    elseif e == "monitor_touch" and ev[2] == outName and cfg.touch then
      setPage(1)
    elseif e == "key" and (ev[2] == keys.right or ev[2] == keys.left) then
      setPage(ev[2] == keys.right and 1 or -1)
    elseif e == "peripheral" or e == "peripheral_detach" then
      modems = core.openModems()
      pickOutput()
      draw()
    elseif e == "monitor_resize" or e == "term_resize" then
      fitKey = nil
      cv.resize()
      if status then status.resize() end
      draw()
    end
  end
end

local ok, e = pcall(main)
if isMon and out then                 -- leave a clear note on the monitor
  pcall(function()
    out.setBackgroundColor(colors.black)
    out.clear()
    out.setCursorPos(1, 1)
    out.setTextColor(colors.white)
    pcall(out.setTextScale, 0.5)
    local w = out.getSize()
    out.write(("Warden Screen stopped"):sub(1, w))
  end)
end
if not ok then error(e, 0) end
