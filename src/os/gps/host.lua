-- Warden GPS host: a dedicated GPS computer. Answers GPS pings (like `gps host`), announces itself to WardenOS and
-- shows its status. Started by /startup.lua on boot; set up with the installer ("GPS host").
-- Works on a standard computer too (no colors needed). Hold Ctrl+T to stop it.
local core = dofile("/os/gps/core.lua")

local cfg, err = core.read()
if not cfg then
  printError("Warden GPS: " .. tostring(err))
  print("Set this computer up with the installer and choose GPS host.")
  return
end

local h = core.new(cfg)
h.open()
local colour = term.isColour()
local function col(c, grey) return colour and c or grey end
local C = {
  bg = colors.black, text = colors.white, dim = colors.lightGray, panel = colors.gray,
  accent = col(colors.cyan, colors.white), good = col(colors.green, colors.white),
  bad = col(colors.red, colors.white), warn = col(colors.yellow, colors.white),
}

local function put(x, y, s, fg, bg)
  local w, hh = term.getSize()
  if y < 1 or y > hh or x > w then return end
  if x < 1 then s = s:sub(2 - x) x = 1 end
  term.setCursorPos(x, y)
  term.setTextColor(fg or C.text)
  term.setBackgroundColor(bg or C.bg)
  term.write(s:sub(1, w - x + 1))
end

local function dur(s)
  s = math.floor(s)
  if s < 60 then return s .. "s" end
  if s < 3600 then return ("%dm %02ds"):format(math.floor(s / 60), s % 60) end
  return ("%dh %02dm"):format(math.floor(s / 3600), math.floor((s % 3600) / 60))
end

local function draw()
  local w, hh = term.getSize()
  term.setBackgroundColor(C.bg)
  term.clear()
  put(1, 1, string.rep(" ", w), C.text, C.panel)
  put(2, 1, "Warden GPS host", C.accent, C.panel)
  local v = "v" .. tostring(h.version)
  if w > 18 + #v then put(w - #v, 1, v, C.dim, C.panel) end
  local rows = {
    { "Position", ("%d %d %d"):format(h.x, h.y, h.z), C.text },
    { "Label", os.getComputerLabel() or ("#" .. os.getComputerID()), C.text },
  }
  if #h.modems == 0 then
    rows[#rows + 1] = { "Modem", "NONE - attach a wireless or ender modem", C.bad }
  else
    rows[#rows + 1] = { "Modem", table.concat(h.modems, ", "), C.good }
  end
  rows[#rows + 1] = { "Served", tostring(h.served) .. " request" .. (h.served == 1 and "" or "s"), C.text }
  if h.last then
    rows[#rows + 1] = { "Last", ("%.1f blocks away, %s ago"):format(h.last.dist, dur(os.clock() - h.last.at)), C.dim }
  end
  rows[#rows + 1] = { "Uptime", dur(os.clock() - h.started), C.dim }
  local y = 3
  for _, r in ipairs(rows) do
    if y > hh - 1 then break end
    put(2, y, r[1], C.dim)
    put(11, y, r[2], r[3])
    y = y + 1
  end
  if y + 1 <= hh - 2 then
    put(2, y + 1, "The coordinates must be this computer's block.", C.dim)
  end
  put(1, hh, string.rep(" ", w), C.dim, C.panel)
  put(2, hh, "Hold Ctrl+T to stop", C.dim, C.panel)
end

draw()
local tick = os.startTimer(1)
while true do
  local ev = table.pack(os.pullEvent())
  local changed = h.event(ev)
  if ev[1] == "timer" and ev[2] == tick then
    tick = os.startTimer(1)
    changed = true
  elseif ev[1] == "term_resize" then
    changed = true
  end
  if changed then draw() end
end
