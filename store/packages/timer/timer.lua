-- timer: a countdown in the terminal that rings an attached speaker when it is done.
--   timer 5m            five minutes        timer 90           90 seconds
--   timer 1h2m3s tea    with a label        q (or Ctrl+T) cancels
local args = { ... }
local color = term.isColour and term.isColour()
local function c(col) if color then term.setTextColor(col) end end

local function parse(s)
  if not s then return nil end
  if s:match("^%d+$") then return tonumber(s) end
  if s:match("^%d+:%d%d$") then local m, sec = s:match("^(%d+):(%d%d)$") return m * 60 + sec end
  local total, rest = 0, s:lower()
  for n, u in rest:gmatch("(%d+%.?%d*)([hms])") do
    total = total + tonumber(n) * ({ h = 3600, m = 60, s = 1 })[u]
  end
  if total == 0 or rest:gsub("%d+%.?%d*[hms]", "") ~= "" then return nil end
  return total
end

local secs = parse(args[1])
if not secs or secs <= 0 then
  c(colors.yellow) print("usage: timer <time> [label]") c(colors.white)
  print("  time: 90, 5m, 1h30m, 2m30s or 4:20")
  return
end
local label = table.concat(args, " ", 2)
if label == "" then label = "timer" end

local function clock(s)
  s = math.max(0, math.ceil(s))
  local h, m, x = math.floor(s / 3600), math.floor(s / 60) % 60, s % 60
  return h > 0 and ("%d:%02d:%02d"):format(h, m, x) or ("%02d:%02d"):format(m, x)
end

local speaker = peripheral.find and peripheral.find("speaker")
local W = term.getSize()
local y
local function now() return os.epoch("utc") / 1000 end
local ends = now() + secs
c(colors.cyan) print(label .. " - " .. clock(secs) .. "  (q cancels)") c(colors.white)
print()
y = select(2, term.getCursorPos()) - 1

local function line(left)
  local text = clock(left) .. " "
  local bw = math.max(0, W - #text - 2)
  local done = math.floor(bw * (1 - left / secs) + 0.5)
  term.setCursorPos(1, y)
  term.clearLine()
  c(left <= 0 and colors.lime or colors.white)
  term.write(text)
  if bw > 0 then
    if color then
      term.setBackgroundColor(colors.cyan) term.write(string.rep(" ", done))
      term.setBackgroundColor(colors.gray) term.write(string.rep(" ", bw - done))
      term.setBackgroundColor(colors.black)
    else
      term.write("[" .. string.rep("#", done) .. string.rep("-", bw - done) .. "]")
    end
  end
end

local tick = os.startTimer(0)
while true do
  local e, a = os.pullEventRaw()
  if e == "terminate" or (e == "char" and (a == "q" or a == "Q")) then
    term.setCursorPos(1, y + 1)
    c(colors.red) print("cancelled") c(colors.white)
    return
  elseif e == "timer" and a == tick then
    local left = ends - now()
    line(left)
    if left <= 0 then break end
    tick = os.startTimer(math.min(1, left))
  end
end

term.setCursorPos(1, y + 1)
c(colors.lime) print(("%s: time's up!"):format(label)) c(colors.white)
os.queueEvent("os_toast", label .. ": time's up!")
for i = 1, 3 do
  if speaker then pcall(speaker.playNote, "bell", 3, 18) end
  if i < 3 then sleep(0.4) end
end
