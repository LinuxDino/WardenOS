-- neofetch: WardenOS system information
local W, H = term.getSize()
local color = term.isColour()

local function c(col) if color then term.setTextColor(col) end end
local function tryLib(p) local ok, m = pcall(dofile, p) return ok and type(m) == "table" and m or nil end

local cfg = tryLib("/os/config.lua") or {}
local W_OS = rawget(_G, "WardenOS")

local function human(n)
  if n >= 1024 * 1024 then return ("%.1f MB"):format(n / 1048576) end
  if n >= 1024 then return ("%.0f KB"):format(n / 1024) end
  return n .. " B"
end
local function uptime()
  local s = math.floor(os.clock())
  local d, h, m = math.floor(s / 86400), math.floor(s / 3600) % 24, math.floor(s / 60) % 60
  if d > 0 then return ("%dd %dh %dm"):format(d, h, m) end
  if h > 0 then return ("%dh %dm"):format(h, m) end
  return ("%dm %ds"):format(m, s % 60)
end
local function device()
  local adv = term.isColour() and "Advanced " or ""
  if turtle then return adv .. "Turtle" end
  if pocket then return adv .. "Pocket Computer" end
  if commands then return "Command Computer" end
  return adv .. "Computer"
end

-- info lines
local user = (W_OS and W_OS.user) or "player"
local label = os.getComputerLabel() or ("computer-" .. os.getComputerID())
local info = {}
local function add(k, v) info[#info + 1] = { k, tostring(v) } end
add("", user .. "@" .. label)
add("", string.rep("-", #user + 1 + #label))
add("OS", (cfg.name or "WardenOS") .. " " .. tostring(cfg.version or "?"))
add("Host", device() .. " #" .. os.getComputerID())
add("Kernel", os.version())
if _HOST then add("Mod", (_HOST:gsub("^ComputerCraft ", "CC: Tweaked "))) end
add("Uptime", uptime())
add("Shell", "CraftOS shell" .. (multishell and " (multishell)" or ""))
add("Resolution", W .. "x" .. H)
local mons = { peripheral.find("monitor") }
if #mons > 0 then
  local mw, mh = mons[1].getSize()
  add("Monitor", ("%d (%dx%d)"):format(#mons, mw, mh))
end
local okc, cap = pcall(fs.getCapacity, "/")
local free = fs.getFreeSpace("/")
if okc and type(cap) == "number" and cap > 0 then
  add("Disk", ("%s / %s (%d%%)"):format(human(cap - free), human(cap), math.floor((cap - free) / cap * 100 + 0.5)))
else
  add("Disk", human(free) .. " free")
end
local names = peripheral.getNames()
local modems = 0
for _, n in ipairs(names) do if peripheral.getType(n) == "modem" then modems = modems + 1 end end
add("Peripherals", #names .. (modems > 0 and (" (" .. modems .. " modem" .. (modems > 1 and "s" or "") .. ")") or ""))
if turtle then
  local fuel = turtle.getFuelLevel()
  add("Fuel", fuel == "unlimited" and "unlimited" or (fuel .. " / " .. turtle.getFuelLimit()))
end
if W_OS and type(W_OS.drones) == "table" then
  local n, on = 0, 0
  for _, d in pairs(W_OS.drones) do
    n = n + 1
    if type(d) == "table" and d.seen and os.clock() - d.seen < 10 then on = on + 1 end
  end
  add("Drones", ("%d known, %d online"):format(n, on))
end
if fs.exists("/os/lib/map.lua") then
  local map = tryLib("/os/lib/map.lua")
  if map and map.info then
    local ok, i = pcall(map.info)
    if ok and type(i) == "table" and i.total then add("Map", ("%d blocks"):format(i.total)) end
  end
end
add("Theme", (W_OS and W_OS.theme and "WardenOS " or "") .. (term.isColour() and "16 colors" or "grayscale"))

-- fit the screen: drop the least important lines first
local DROP = { "Theme", "Map", "Shell", "Monitor", "Peripherals", "Resolution", "Kernel", "Mod" }
local function fits() return #info + 2 <= H - 1 end
for _, key in ipairs(DROP) do
  if fits() then break end
  for i = #info, 1, -1 do if info[i][1] == key then table.remove(info, i) end end
end
while not fits() and #info > 1 do table.remove(info) end

-- logo
local LOGO = {
  " __      __ ",
  " \\ \\ /\\ / / ",
  "  \\ V  V /  ",
  "   \\_/\\_/   ",
  "            ",
  "  WARDEN OS ",
}
local showLogo = W >= 40
local lx = showLogo and (#LOGO[1] + 2) or 0

local _, y0 = term.getCursorPos()
local rows = math.max(#info + 2, showLogo and #LOGO or 0)
for _ = 1, rows do print() end                     -- make room (scrolls if needed)
local _, yEnd = term.getCursorPos()
local top = yEnd - rows

if showLogo then
  for i, l in ipairs(LOGO) do
    term.setCursorPos(1, top + i - 1)
    c(i == #LOGO and colors.lightGray or colors.cyan)
    term.write(l)
  end
end
for i, kv in ipairs(info) do
  term.setCursorPos(lx + 1, top + i - 1)
  if kv[1] == "" then
    c(i == 1 and colors.cyan or colors.lightGray)
    term.write(kv[2]:sub(1, W - lx))
  else
    c(colors.cyan)
    term.write(kv[1])
    c(colors.lightGray)
    term.write((": " .. kv[2]):sub(1, math.max(0, W - lx - #kv[1])))
  end
end
-- color bar
if color then
  term.setCursorPos(lx + 1, top + #info + 1)
  for _, col in ipairs({ colors.black, colors.gray, colors.lightGray, colors.white, colors.cyan,
                         colors.green, colors.yellow, colors.orange, colors.red, colors.magenta, colors.blue }) do
    local x = term.getCursorPos()
    if x + 1 > W then break end
    term.setBackgroundColor(col)
    term.write("  ")
  end
  term.setBackgroundColor(colors.black)
end
c(colors.white)
term.setCursorPos(1, yEnd)
