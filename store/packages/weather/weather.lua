-- weather: time of day, sky and moon in your Minecraft world.
-- Uses an Environment Detector (Advanced Peripherals) for rain / thunder / biome when one is attached,
-- otherwise the in-game clock (os.time / os.day).   usage: weather [-s]
local args = { ... }
if args[1] == "-h" or args[1] == "--help" then
  print("usage: weather [-s]")
  print("  -s  one line only")
  return
end
local short = args[1] == "-s"
local color = term.isColour and term.isColour()
local function c(col) if color then term.setTextColor(col) end end
local W = term.getSize()

-- an environment detector, if there is one
local det
for _, n in ipairs(peripheral.getNames()) do
  local t = peripheral.getType(n)
  if t == "environmentDetector" or t == "environment_detector" then det = peripheral.wrap(n) break end
end
local function ask(m, ...)
  if not det or type(det[m]) ~= "function" then return nil end
  local ok, v = pcall(det[m], ...)
  if ok then return v end
end

local time, day = os.time(), os.day()
local h, m = math.floor(time), math.floor((time - math.floor(time)) * 60)
local rain, thunder, biome = ask("isRaining"), ask("isThunder"), ask("getBiome")
local MOONS = { "full moon", "waning gibbous", "third quarter", "waning crescent", "new moon", "waxing crescent",
  "first quarter", "waxing gibbous" }
local moon = MOONS[(day % 8) + 1]
local moonName = ask("getMoonName")
if type(moonName) == "string" and moonName ~= "" then moon = moonName:lower() end

local part
if h >= 5 and h < 6 then part = "dawn"
elseif h >= 6 and h < 12 then part = "morning"
elseif h >= 12 and h < 13 then part = "noon"
elseif h >= 13 and h < 18 then part = "afternoon"
elseif h >= 18 and h < 19 then part = "dusk"
else part = "night" end
local night = part == "night"

local sky = thunder and "thunderstorm" or (rain and "rain" or (det and "clear" or nil))
-- in-game hours until the next sunrise / nightfall; one in-game hour is 50 real seconds
local function untilHour(target)
  local d = target - time
  if d <= 0 then d = d + 24 end
  return d
end
local function span(hours)
  local secs = math.floor(hours * 50 + 0.5)
  if secs >= 60 then return ("%dm %02ds"):format(math.floor(secs / 60), secs % 60) end
  return secs .. "s"
end
local nextEvent = night and ("sunrise in " .. span(untilHour(6))) or ("nightfall in " .. span(untilHour(19)))

local clockStr = ("%02d:%02d"):format(h, m)
if short then
  c(colors.yellow)
  print(("Day %d %s %s, %s%s"):format(day, clockStr, part, sky or (night and moon or "sunny?"),
    night and "" or (", " .. nextEvent)))
  c(colors.white)
  return
end

-- the picture
local ART = {
  sun = { { "   \\ | /  ", colors.yellow }, { "  -- O -- ", colors.yellow }, { "   / | \\  ", colors.yellow } },
  moon = { { "    _..   ", colors.lightGray }, { "   (  (   ", colors.white }, { "    `''   ", colors.lightGray } },
  rain = { { "   .--.   ", colors.lightGray }, { "  (____)  ", colors.gray }, { "  / / / / ", colors.lightBlue } },
  storm = { { "   .--.   ", colors.gray }, { "  (____)  ", colors.gray }, { "   /_ /_  ", colors.yellow } },
  dusk = { { "          ", colors.orange }, { "  .-O-.   ", colors.orange }, { "~~~~~~~~~~", colors.red } },
}
local art = thunder and ART.storm or (rain and ART.rain or ((part == "dusk" or part == "dawn") and ART.dusk
  or (night and ART.moon or ART.sun)))

local info = {
  { "Time", ("%s (%s)"):format(clockStr, part), colors.white },
  { "Day", tostring(day), colors.white },
  { "Sky", sky or (det and "clear" or "?  (no sensor)"), (rain or thunder) and colors.lightBlue or colors.white },
  { "Moon", moon, colors.lightGray },
  { "Next", nextEvent, colors.orange },
}
if type(biome) == "string" then table.insert(info, 4, { "Biome", (biome:gsub("^.-:", ""):gsub("_", " ")), colors.lime }) end
if night then info[#info + 1] = { "Mobs", "monsters spawn in the dark!", colors.red } end

local side = W >= 34
for i = 1, math.max(#art, #info) do
  local line = ""
  if side then
    local a = art[i]
    if a then c(a[2]) write(a[1]) else write(string.rep(" ", 10)) end
    write(" ")
  end
  local r = info[i]
  if r then
    c(colors.cyan)
    write(("%-5s "):format(r[1]))
    c(r[3])
    local room = W - (side and 11 or 0) - 6
    write(r[2]:sub(1, math.max(1, room)))
  end
  print(line)
end
if not det and not short then
  c(colors.gray)
  print(("Tip: attach an Environment Detector for rain/biome."):sub(1, W))
end
c(colors.white)
