-- Minimal CC: Tweaked mock for dry-running WardenOS outside Minecraft.
-- Globals provided by tests/check.py: HOST_READ(path) -> string|nil, CW, CH, MW, MH (MW = 0: no monitor),
-- SCRIPT_EVENTS (list of event tables), SCRIPT_LINES (list of strings for read()).
local M = { violations = 0, terms = {}, rebooted = false, log = {}, written = {} }
local unpack = table.unpack

colors = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32, pink = 64, gray = 128,
  lightGray = 256, cyan = 512, purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
colours = colors
keys = { enter = 28, up = 200, down = 208, pageUp = 201, pageDown = 209, q = 16, y = 21, n = 49, d = 32, u = 22,
  backspace = 14, tab = 15, f12 = 88, left = 203, right = 205, g = 34 }

---------------------------------------------------------------- terminals
local function newTerm(w, h, parent, ox, oy, name)
  local t = { w = w, h = h, cx = 1, cy = 1, rows = {}, name = name, visible = true }
  M.terms[#M.terms + 1] = t
  local function blank() for y = 1, t.h do t.rows[y] = string.rep(" ", t.w) end end
  blank()
  function t.getSize() return t.w, t.h end
  function t.setCursorPos(x, y) t.cx, t.cy = math.floor(x), math.floor(y) end
  function t.getCursorPos() return t.cx, t.cy end
  function t.write(s)
    s = tostring(s)
    if name ~= "win" then M.written[#M.written + 1] = s end
    if t.cy >= 1 and t.cy <= t.h then
      local row = t.rows[t.cy]
      for i = 1, #s do
        local x = t.cx + i - 1
        if x >= 1 and x <= t.w then row = row:sub(1, x - 1) .. s:sub(i, i) .. row:sub(x + 1)
        elseif s:sub(i, i) ~= " " and name ~= "win" then M.violations = M.violations + 1 M.log[#M.log + 1] = "OFFSCREEN " .. t.name .. " " .. t.cx .. "," .. t.cy .. " " .. s end
      end
      t.rows[t.cy] = row
    elseif s:match("%S") and name ~= "win" then M.violations = M.violations + 1 end
    if parent and t.visible and t.cy >= 1 and t.cy <= t.h then
      local from = math.max(1, t.cx)
      local vis = s:sub(from - t.cx + 1, t.w - t.cx + 1)
      if #vis > 0 then parent.setCursorPos(ox + from - 1, oy + t.cy - 1) parent.write(vis) end
    end
    t.cx = t.cx + #s
  end
  function t.blit(s) t.write(s) end
  function t.clear() blank() if parent and t.visible then t.redraw() end end
  function t.clearLine() if t.rows[t.cy] then t.rows[t.cy] = string.rep(" ", t.w) end end
  function t.scroll(n)
    for _ = 1, n do table.remove(t.rows, 1) t.rows[#t.rows + 1] = string.rep(" ", t.w) end
  end
  for _, n in ipairs { "setTextColor", "setTextColour", "setBackgroundColor", "setBackgroundColour",
    "setCursorBlink", "setPaletteColour", "setPaletteColor" } do t[n] = function() end end
  function t.getTextColor() return colors.white end
  function t.getBackgroundColor() return colors.black end
  function t.getPaletteColour() return 0, 0, 0 end
  t.getPaletteColor = t.getPaletteColour
  function t.isColor() return true end
  t.isColour = t.isColor
  function t.redraw()
    if not parent then return end
    for y = 1, t.h do parent.setCursorPos(ox, oy + y - 1) parent.write(t.rows[y]) end
  end
  function t.setVisible(v) t.visible = v if v then t.redraw() end end
  function t.restoreCursor() end
  function t.reposition(x, y, w2, h2)
    ox, oy = x, y
    if w2 then t.w, t.h = w2, h2 blank() end
  end
  return t
end

local native = newTerm(CW, CH, nil, 1, 1, "computer")
local mon = MW > 0 and newTerm(MW, MH, nil, 1, 1, "monitor") or nil
if mon then
  function mon.setTextScale(s)
    mon.scale = s
    mon.w, mon.h = math.floor(MW / (s * 2)), math.floor(MH / (s * 2))
    for y = 1, mon.h do mon.rows[y] = string.rep(" ", mon.w) end
  end
  mon.setTextScale(0.5)
end
M.native, M.mon = native, mon

local cur = native
term = {
  current = function() return cur end,
  native = function() return native end,
  redirect = function(t) local o = cur cur = t return o end,
  nativePaletteColour = function() return 0, 0, 0 end,
}
setmetatable(term, { __index = function(_, k) return function(...) return cur[k](...) end end })
window = { create = function(parent, x, y, w, h, vis)
  local t = newTerm(w, h, parent, x, y, "win")
  t.visible = vis ~= false
  return t
end }

---------------------------------------------------------------- peripherals
-- optional globals from the test: MODEM (wireless modem on "back"), DRIVE (disk drive "bottom" with a floppy),
-- TURTLE (this computer is a turtle)
peripheral = {
  getNames = function()
    local t = mon and { "right", "left" } or { "left" }
    if MODEM then t[#t + 1] = "back" end
    if DRIVE then t[#t + 1] = "bottom" end
    return t
  end,
  getType = function(n)
    if n == "right" and mon then return "monitor" end
    if n == "left" then return "create_stressometer", "inventory" end
    if n == "back" and MODEM then return "modem" end
    if n == "bottom" and DRIVE then return "drive" end
  end,
  wrap = function(n) if n == "right" then return mon end end,
  find = function(t) if t == "monitor" then return mon end end,
  getMethods = function(n) if n == "left" then return { "getStress", "getStressCapacity", "list" } end end,
}
function peripheral.isPresent(n) return peripheral.getType(n) ~= nil end
function peripheral.call(n, method, ...)
  if n == "left" and method == "getStress" then return 128 end
  if n == "left" and method == "getStressCapacity" then return 2048 end
  if n == "left" and method == "list" then return {} end
  error("No such method " .. tostring(method))
end
-- redstone: inputs per side come from M.redstone (set by a test), e.g. M.redstone.back = 15
M.redstone = {}
redstone = {
  getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
  getInput = function(side) return (M.redstone[side] or 0) > 0 end,
  getAnalogInput = function(side) return M.redstone[side] or 0 end,
  getAnalogueInput = function(side) return M.redstone[side] or 0 end,
  setOutput = function() end,
  setAnalogOutput = function() end,
}
disk = {
  isPresent = function(n) return DRIVE and n == "bottom" end,
  hasData = function(n) return DRIVE and n == "bottom" end,
  getMountPath = function(n) if DRIVE and n == "bottom" then return "disk" end end,
  setLabel = function() end,
}

-- rednet: what this computer sends is recorded in M.sent
M.sent, M.open = {}, {}
rednet = {
  open = function(n) if n == "back" and MODEM then M.open[n] = true else error("No such modem: " .. n) end end,
  isOpen = function(n)
    if n then return M.open[n] == true end
    return next(M.open) ~= nil
  end,
  send = function(id, msg, proto)
    if not next(M.open) then return false end
    M.sent[#M.sent + 1] = { to = id, msg = msg, proto = proto }
    return true
  end,
  broadcast = function(msg, proto) M.sent[#M.sent + 1] = { to = "all", msg = msg, proto = proto } end,
  receive = function(proto)
    while true do
      local _, id, msg, p = os.pullEvent("rednet_message")
      if proto == nil or p == proto then return id, msg, p end
    end
  end,
}
gps = { locate = function() return nil end }

-- turtle: actions are recorded in M.turtle
M.turtle = {}
if TURTLE then
  local sel, fuel = 1, 500
  local inv = { [1] = { name = "minecraft:coal", count = 12 }, [5] = { name = "minecraft:cobblestone", count = 64 } }
  turtle = {}
  for _, n in ipairs { "forward", "back", "up", "down", "turnLeft", "turnRight", "dig", "digUp", "digDown",
                       "place", "placeUp", "placeDown", "suck", "drop" } do
    turtle[n] = function() M.turtle[#M.turtle + 1] = n return true end
  end
  turtle.getFuelLevel = function() return fuel end
  turtle.getFuelLimit = function() return 20000 end
  turtle.getSelectedSlot = function() return sel end
  turtle.select = function(n) sel = n return true end
  turtle.getItemCount = function(n) return inv[n] and inv[n].count or 0 end
  turtle.getItemDetail = function(n) return inv[n] end
  turtle.refuel = function()
    if inv[sel] and inv[sel].name == "minecraft:coal" then fuel = fuel + 80 * inv[sel].count inv[sel] = nil return true end
    return false
  end
end

-- parallel, like CraftOS: every coroutine gets the events it waits for
parallel = {}
local function runAll(any, ...)
  local fns, cos, filters = { ... }, {}, {}
  for i, f in ipairs(fns) do cos[i] = coroutine.create(f) end
  local ev = { n = 0 }
  while true do
    local alive = 0
    for i = 1, #fns do
      local co = cos[i]
      if co then
        if filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate" then
          local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
          if not ok then error(f, 0) end
          filters[i] = f
        end
        if coroutine.status(co) == "dead" then
          if any then return i end
          cos[i] = false
        else
          alive = alive + 1
        end
      end
    end
    if alive == 0 then return end
    ev = table.pack(os.pullEventRaw())
  end
end
parallel.waitForAny = function(...) return runAll(true, ...) end
parallel.waitForAll = function(...) return runAll(false, ...) end

shell = {
  getRunningProgram = function() return M.program or "startup.lua" end,
  run = function(path, ...) M.shellRuns = (M.shellRuns or "") .. path .. ";" return true end,
}

---------------------------------------------------------------- filesystem
local FS = { ["/rom"] = true }          -- path -> string (file) | true (dir)
M.FS = FS
local function norm(p)
  local parts = {}
  for part in tostring(p):gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/")
end
fs = {}
function fs.combine(a, b) return (norm(a .. "/" .. b)):sub(2) end
function fs.getDir(p) local n = norm(p):sub(2) return n:match("^(.*)/[^/]*$") or "" end
function fs.getName(p) return norm(p):match("([^/]*)$") end
function fs.exists(p) p = norm(p) return p == "/" or FS[p] ~= nil end
function fs.isDir(p) p = norm(p) return p == "/" or FS[p] == true end
function fs.makeDir(p)
  p = norm(p)
  local acc = ""
  for part in p:gmatch("[^/]+") do
    acc = acc .. "/" .. part
    if type(FS[acc]) == "string" then error("file in the way: " .. acc) end
    FS[acc] = true
  end
end
function fs.list(p)
  p = norm(p)
  if not fs.isDir(p) then error("Not a directory: " .. p) end
  local out, prefix = {}, (p == "/" and "/" or p .. "/")
  for k in pairs(FS) do
    if k:sub(1, #prefix) == prefix and not k:sub(#prefix + 1):find("/") and k ~= p then
      out[#out + 1] = k:sub(#prefix + 1)
    end
  end
  table.sort(out)
  return out
end
function fs.delete(p)
  p = norm(p)
  if p == "/rom" or p:sub(1, 5) == "/rom/" then error("Access denied") end
  for k in pairs(FS) do if k == p or k:sub(1, #p + 1) == p .. "/" then FS[k] = nil end end
end
function fs.copy(a, b)
  a, b = norm(a), norm(b)
  if type(FS[a]) ~= "string" then error("No such file: " .. a) end
  if FS[b] ~= nil then error("File exists: " .. b) end
  fs.makeDir(fs.getDir(b))
  FS[b] = FS[a]
end
function fs.isReadOnly(p) p = norm(p) return p == "/rom" or p:sub(1, 5) == "/rom/" end
function fs.getDrive(p) p = norm(p) if p:sub(1, 4) == "/rom" then return "rom" end return "hdd" end
function fs.getSize(p) local v = FS[norm(p)] return type(v) == "string" and #v or 0 end
function fs.getFreeSpace() return 900000 end
function fs.getCapacity() return 1000000 end
function fs.open(p, mode)
  p = norm(p)
  if mode == "r" then
    local v = FS[p]
    if type(v) ~= "string" then return nil, "No such file" end
    local pos = 1
    return { readAll = function() return v end, close = function() end,
             readLine = function()                 -- like CC: next line without "\n", nil at the end
               if pos > #v then return nil end
               local e = v:find("\n", pos, true) or (#v + 1)
               local line = v:sub(pos, e - 1)
               pos = e + 1
               return line
             end }
  end
  local dir = fs.getDir(p)
  if dir ~= "" and FS["/" .. dir] ~= true then return nil, "No such directory" end
  local buf = {}
  if mode == "a" and type(FS[p]) == "string" then buf[1] = FS[p] end   -- append: keep what is there
  return { write = function(s) buf[#buf + 1] = tostring(s) end, close = function() FS[p] = table.concat(buf) end }
end

---------------------------------------------------------------- textutils
local function ser(v, ind)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do
    local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. k .. "]")
    parts[#parts + 1] = key .. " = " .. ser(x)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end
textutils = {
  serialize = function(v) return ser(v) end,
  unserialize = function(s) local f = load("return " .. s, "u", "t", {}) if not f then return nil end
    local ok, r = pcall(f) return ok and r or nil end,
  formatTime = function() return "12:00" end,
}

---------------------------------------------------------------- http (served from the repo)
http = { get = function(url)
  local path = url:match("^https://raw%.githubusercontent%.com/LinuxDino/WardenOS/[^?]-/(.-)%?") or
               url:match("^https://raw%.githubusercontent%.com/LinuxDino/WardenOS/main/(.*)$")
  M.log[#M.log + 1] = "GET " .. url
  local body = path and HOST_READ(path)
  if not body then
    return nil, "Not Found", { getResponseCode = function() return 404 end, close = function() end }
  end
  return { getResponseCode = function() return 200 end, readAll = function() return body end, close = function() end }
end }

-- http.request (async, like CC: Tweaked): every request is recorded in M.requests and answered by the test's
-- HOST_API(body, headers) -> status, responseBody[, retryAfter]; the reply arrives as http_success / http_failure.
-- status 0 = connection failure (http_failure without a handle).
M.requests = {}
function http.request(url, body, headers, binary)
  local req = type(url) == "table" and url or { url = url, body = body, headers = headers, binary = binary }
  M.requests[#M.requests + 1] = { url = req.url, headers = req.headers or {}, body = req.body,
                                  method = req.method or (req.body and "POST" or "GET"), timeout = req.timeout,
                                  binary = req.binary }
  if not HOST_API then os.queueEvent("http_failure", req.url, "Could not connect") return false, "Could not connect" end
  local code, text, after = HOST_API(req.body, req.headers or {})
  code, text = tonumber(code) or 0, text and tostring(text) or ""
  local function handle(hdrs)
    local done = false
    return {
      readAll = function() if done then return nil end done = true return text end,
      close = function() end,
      getResponseCode = function() return code end,
      getResponseHeaders = function() return hdrs end,
    }
  end
  if code >= 200 and code < 300 then
    os.queueEvent("http_success", req.url, handle({ ["Content-Type"] = "application/json" }))
  elseif code == 0 then
    os.queueEvent("http_failure", req.url, "Could not connect")
  else
    os.queueEvent("http_failure", req.url, "HTTP error message",
                  handle({ ["Retry-After"] = after and tostring(after) or nil }))
  end
  return true
end

---------------------------------------------------------------- os / events
local timerId, queue = 0, {}
os.epoch = function() return 123456 end
os.getComputerID = function() return 7 end
os.getComputerLabel = function() return M.label end
os.setComputerLabel = function(l) M.label = l end
os.day = function() return 1 end
os.time = function() return 12.5 end
os.version = function() return "CraftOS 1.9" end
os.reboot = function() M.rebooted = true error("REBOOT", 0) end
os.shutdown = function() M.rebooted = true error("SHUTDOWN", 0) end
os.startTimer = function() timerId = timerId + 1 M.lastTimer = timerId return timerId end
os.queueEvent = function(...) queue[#queue + 1] = table.pack(...) end
local EV, LINES = SCRIPT_EVENTS, SCRIPT_LINES
os.pullEventRaw = function(filter)
  local _, main = coroutine.running()
  if not main then return coroutine.yield(filter) end   -- inside an app: the kernel delivers events
  while true do
    local e = table.remove(queue, 1)
    if not e then
      e = table.remove(EV, 1)
      if not e then error("SCRIPT_END", 0) end
      -- {"host", ...}: the test's HOST_EVENT(...) builds the event at this moment (nil = skip it)
      if e[1] == "host" and HOST_EVENT then e = HOST_EVENT(unpack(e, 2)) end
      e = e and table.pack(unpack(e))
    end
    if e and (not filter or e[1] == filter or e[1] == "terminate") then return unpack(e, 1, e.n) end
  end
end
os.pullEvent = function(filter)
  local r = table.pack(os.pullEventRaw(filter))
  if r[1] == "terminate" then error("Terminated", 0) end
  return unpack(r, 1, r.n)
end
os.run = function(env, path, ...)            -- stand-in for shell/lua/edit: loops until terminated
  print("[" .. path .. "]")
  while true do os.pullEvent() end
end
sleep = function()                              -- inside a coroutine: wait for the next timer event
  local _, main = coroutine.running()
  if not main then coroutine.yield("timer") end
end
read = function() local l = table.remove(LINES, 1) if not l then error("SCRIPT_END", 0) end return l end
print = function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  local s = table.concat(t, "\t")
  M.log[#M.log + 1] = s
  local w, h = term.getSize()
  repeat                                         -- wraps like CraftOS print
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.write(s:sub(1, w))
    s = s:sub(w + 1)
    if y >= h then term.scroll(1) term.setCursorPos(1, h) else term.setCursorPos(1, y + 1) end
  until s == ""
end
printError = print
write = function(s) term.write(s) end
math.randomseed = function() end
dofile = function(p)
  local v = FS[norm(p)]
  if type(v) ~= "string" then error("dofile: no file " .. p, 2) end
  return assert(load(v, "=" .. p, "t", _G))()
end

return M
