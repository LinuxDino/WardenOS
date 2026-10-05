-- Stopwatch & Timer for WardenOS. The timer rings an attached speaker (or flashes) when it runs out.
-- space start/stop, l lap, r reset, t switches tab, q quits.
local function now() return os.epoch("utc") / 1000 end

local function clock(s, tenths)
  s = math.max(0, s)
  local h, m, sec = math.floor(s / 3600), math.floor(s / 60) % 60, math.floor(s) % 60
  local out = h > 0 and ("%d:%02d:%02d"):format(h, m, sec) or ("%02d:%02d"):format(m, sec)
  if tenths then out = out .. "." .. math.floor((s * 10) % 10) end
  return out
end

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local T = (rawget(_G, "WardenOS") and WardenOS.theme) or {}
  local BG, PANEL, TEXT, DIM, ACC = T.bg or colors.black, T.panel or colors.gray, T.text or colors.white,
    T.dim or colors.lightGray, T.accent or colors.cyan
  local GOOD, BAD, WARN = T.good or colors.green, T.bad or colors.red, T.warn or colors.yellow
  local okF, font = pcall(dofile, "/os/lib/bigfont.lua")
  if not okF or type(font) ~= "table" then font = nil end
  local speaker = peripheral and peripheral.find and peripheral.find("speaker") or nil

  local tab = "stopwatch"
  local sw = { running = false, start = 0, acc = 0, laps = {} }
  local tm = { set = 300, left = 300, running = false, ends = 0, ringing = false, rings = 0 }
  local ticker, zones, flash = nil, {}, false

  local function swTime() return sw.acc + (sw.running and (now() - sw.start) or 0) end
  local function tmLeft() return tm.running and math.max(0, tm.ends - now()) or tm.left end
  local function tick() ticker = os.startTimer(tm.ringing and 0.5 or 0.1) end

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
  local function button(x, y, label, fn, fg, bg)
    label = " " .. label .. " "
    if x + #label - 1 > W then return x end
    put(x, y, label, fg or BG, bg or ACC)
    zones[#zones + 1] = { x, x + #label - 1, y, fn }
    return x + #label + 1
  end

  -- the time, as big as fits
  local function bigTime(y, s, color)
    if font and font.width(s) <= W - 2 and H >= 12 then
      local x = math.floor((W - font.width(s)) / 2) + 1
      font.draw(term, s, x, y, color)
      return y + 6
    end
    put(math.floor((W - #s) / 2) + 1, y + 1, s, color, BG)
    return y + 3
  end

  local function swToggle()
    if sw.running then sw.acc, sw.running = swTime(), false
    else sw.start, sw.running = now(), true end
  end
  local function swLap()
    if sw.running then table.insert(sw.laps, 1, swTime()) end
  end
  local function tmToggle()
    if tm.ringing then tm.ringing = false tm.left = tm.set return end
    if tm.running then tm.left, tm.running = tmLeft(), false
    elseif tm.left > 0 then tm.ends, tm.running = now() + tm.left, true end
  end
  local function tmAdd(d)
    if tm.running or tm.ringing then return end
    tm.left = math.max(0, math.min(99 * 3600, tm.left + d))
    tm.set = tm.left
  end

  local function draw()
    zones = {}
    term.setBackgroundColor(BG)
    term.clear()
    put(1, 1, string.rep(" ", W), TEXT, PANEL)
    local x = 1
    for _, t in ipairs({ { "stopwatch", "Stopwatch" }, { "timer", "Timer" } }) do
      local on = tab == t[1]
      local label = " " .. t[2] .. " "
      if x + #label - 1 <= W then
        put(x, 1, label, on and BG or DIM, on and ACC or PANEL)
        zones[#zones + 1] = { x, x + #label - 1, 1, function() tab = t[1] end }
      end
      x = x + #label
    end
    if speaker and W - x > 9 then put(W - 8, 1, "speaker", GOOD, PANEL) end

    local y = 3
    if tab == "stopwatch" then
      local t = swTime()
      y = bigTime(y, clock(t), sw.running and ACC or TEXT)
      put(math.floor((W - 3) / 2) + 1, y - 1, "." .. math.floor((t * 10) % 10), DIM)
      local bx = 2
      bx = button(bx, y, sw.running and "Stop" or "Start", swToggle, BG, sw.running and BAD or GOOD)
      bx = button(bx, y, "Lap", swLap, TEXT, PANEL)
      button(bx, y, "Reset", function() sw = { running = false, start = 0, acc = 0, laps = {} } end, TEXT, PANEL)
      y = y + 2
      for i, l in ipairs(sw.laps) do
        if y > H then break end
        local n = #sw.laps - i + 1
        local split = l - (sw.laps[i + 1] or 0)
        put(2, y, ("Lap %2d  %s  +%s"):format(n, clock(l, true), clock(split, true)), i == 1 and TEXT or DIM)
        y = y + 1
      end
    else
      local left = tmLeft()
      local color = tm.ringing and (flash and BG or BAD) or (tm.running and ACC or TEXT)
      if tm.ringing and flash then
        for r = 2, H do put(1, r, string.rep(" ", W), TEXT, BAD) end
      end
      y = bigTime(y, clock(math.ceil(left - 0.001)), color)
      if tm.ringing then
        local msg = " Time's up! tap to stop "
        put(math.floor((W - #msg) / 2) + 1, y, msg, BG, WARN)
        zones[#zones + 1] = { 1, W, 2, function() end }
        for r = 2, H do zones[#zones + 1] = { 1, W, r, tmToggle } end
        return
      end
      local bx = 2
      bx = button(bx, y, tm.running and "Pause" or "Start", tmToggle, BG, tm.running and WARN or GOOD)
      button(bx, y, "Reset", function() tm.running = false tm.left = tm.set end, TEXT, PANEL)
      y = y + 2
      if not tm.running then
        bx = 2
        for _, d in ipairs({ { "-1m", -60 }, { "-10s", -10 }, { "+10s", 10 }, { "+1m", 60 }, { "+10m", 600 } }) do
          bx = button(bx, y, d[1], function() tmAdd(d[2]) end, TEXT, PANEL)
        end
        y = y + 2
        bx = 2
        put(bx, y, "presets", DIM) bx = bx + 8
        for _, m in ipairs({ 1, 3, 5, 10, 30 }) do
          bx = button(bx, y, m .. "m", function() tm.left, tm.set = m * 60, m * 60 end, TEXT, PANEL)
        end
      else
        -- progress bar
        local frac = tm.set > 0 and (1 - left / tm.set) or 1
        local bw = W - 4
        put(3, y, string.rep(" ", bw), TEXT, PANEL)
        put(3, y, string.rep(" ", math.floor(bw * frac + 0.5)), TEXT, ACC)
      end
    end
    put(1, H, string.rep(" ", W), DIM, BG)
    if H > y then put(2, H, "space start/stop  t tab  q quit", DIM, BG) end
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
    if not ticker and (sw.running or tm.running or tm.ringing) then tick() end
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == ticker then
      if tm.running and tmLeft() <= 0 then
        tm.running, tm.ringing, tm.left, tm.rings = false, true, 0, 0
        tab = "timer"
        os.queueEvent("os_toast", "Timer: time's up!")
      end
      if tm.ringing then
        flash = not flash
        tm.rings = tm.rings + 1
        if speaker then pcall(speaker.playNote, "bell", 3, flash and 18 or 13) end
        if tm.rings > 120 then tm.ringing = false tm.left = tm.set end     -- stop after a minute
      end
      if sw.running or tm.running or tm.ringing then tick() render() else ticker = nil end
    elseif e == "char" then
      a = a:lower()
      if a == "q" then break
      elseif tm.ringing then tmToggle()
      elseif a == " " then if tab == "stopwatch" then swToggle() else tmToggle() end
      elseif a == "l" then swLap()
      elseif a == "r" then if tab == "stopwatch" then sw = { running = false, start = 0, acc = 0, laps = {} }
        else tm.running = false tm.left = tm.set end
      elseif a == "t" then tab = tab == "stopwatch" and "timer" or "stopwatch"
      elseif a == "+" then tmAdd(60) elseif a == "-" then tmAdd(-60) end
      render()
    elseif e == "key" then
      if a == keys.enter or tm.ringing then if tab == "stopwatch" then swToggle() else tmToggle() end end
      render()
    elseif e == "mouse_click" or e == "monitor_touch" then
      for _, z in ipairs(zones) do
        if c == z[3] and b >= z[1] and b <= z[2] then z[4]() break end
      end
      render()
    elseif e == "term_resize" then
      W, H = parent.getSize()
      buf = window.create(parent, 1, 1, W, H, false)
      render()
    end
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return {
  name = "Stopwatch", short = "Watch", icon = "(:)", color = colors.yellow, order = 66, w = 34, h = 16,
  art = { { " /\\ ", "0440", "f44f" }, { " \\/ ", "0440", "f44f" } },
  main = main,
}
