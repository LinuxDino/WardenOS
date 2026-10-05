-- Minesweeper for WardenOS: tap to dig, switch to flag mode (f or the button) to mark mines. q quits.
local DATA = "/os/data/mines/best"
local LEVELS = { { "easy", 9, 9, 10 }, { "medium", 16, 12, 30 }, { "hard", 24, 14, 60 } }
local NUM = { colors.lightBlue, colors.lime, colors.red, colors.blue, colors.brown, colors.cyan, colors.purple, colors.gray }

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local level, flagMode = 1, false
  local cw, ch, mines, cells, state, started, opened, flags, t0, elapsed, tick
  local best, zones, cur = {}, {}, { 1, 1 }

  local f = fs.exists(DATA) and fs.open(DATA, "r")
  if f then best = textutils.unserialize(f.readAll()) or {} f.close() end

  local function cellW() return (W >= cw * 3 + 2) and 3 or ((W >= cw * 2 + 1) and 2 or 1) end

  local function newGame()
    local L = LEVELS[level]
    cw, ch, mines = L[2], L[3], L[4]
    -- smaller window: shrink the field so it fits
    cw = math.max(5, math.min(cw, W))
    ch = math.max(5, math.min(ch, H - 2))
    mines = math.min(mines, math.floor(cw * ch / 5))
    cells, state, started, opened, flags, elapsed = {}, "play", false, 0, 0, 0
    for y = 1, ch do
      cells[y] = {}
      for x = 1, cw do cells[y][x] = { mine = false, open = false, flag = false, n = 0 } end
    end
    cur = { math.ceil(cw / 2), math.ceil(ch / 2) }
  end

  local function each(x, y, fn)
    for dy = -1, 1 do for dx = -1, 1 do
      local c = cells[y + dy] and cells[y + dy][x + dx]
      if c and not (dx == 0 and dy == 0) then fn(c, x + dx, y + dy) end
    end end
  end

  -- mines are placed on the first dig, never on or next to that cell
  local function plant(sx, sy)
    local placed = 0
    while placed < mines do
      local x, y = math.random(1, cw), math.random(1, ch)
      if not cells[y][x].mine and (math.abs(x - sx) > 1 or math.abs(y - sy) > 1 or cw * ch - 9 < mines) then
        cells[y][x].mine = true
        placed = placed + 1
      end
    end
    for y = 1, ch do for x = 1, cw do
      local n = 0
      each(x, y, function(c) if c.mine then n = n + 1 end end)
      cells[y][x].n = n
    end end
    started, t0 = true, os.clock()
    tick = os.startTimer(1)
  end

  local function saveBest()
    fs.makeDir("/os/data/mines")
    local h = fs.open(DATA, "w")
    if h then h.write(textutils.serialize(best)) h.close() end
  end

  local function dig(x, y)
    local c = cells[y] and cells[y][x]
    if not c or c.open or c.flag or state ~= "play" then return end
    if not started then plant(x, y) end
    if c.mine then
      c.open, state = true, "lost"
      elapsed = math.floor(os.clock() - t0)
      for _, row in ipairs(cells) do for _, d in ipairs(row) do if d.mine then d.open = true end end end
      return
    end
    local stack = { { x, y } }
    while #stack > 0 do
      local p = table.remove(stack)
      local d = cells[p[2]][p[1]]
      if not d.open and not d.flag then
        d.open = true
        opened = opened + 1
        if d.n == 0 then each(p[1], p[2], function(e, ex, ey) if not e.open then stack[#stack + 1] = { ex, ey } end end) end
      end
    end
    if opened == cw * ch - mines then
      state = "won"
      elapsed = math.floor(os.clock() - t0)
      local key = LEVELS[level][1] .. "_" .. cw .. "x" .. ch
      if not best[key] or elapsed < best[key] then best[key] = elapsed saveBest() end
    end
  end

  -- tap an open number whose flags are all set: dig its neighbours (chord)
  local function chord(x, y)
    local c = cells[y][x]
    local n = 0
    each(x, y, function(e) if e.flag then n = n + 1 end end)
    if n == c.n then each(x, y, function(_, ex, ey) dig(ex, ey) end) end
  end

  local function act(x, y, flag)
    local c = cells[y] and cells[y][x]
    if not c or state ~= "play" then return end
    cur = { x, y }
    if c.open then chord(x, y)
    elseif flag then
      c.flag = not c.flag
      flags = flags + (c.flag and 1 or -1)
    else dig(x, y) end
  end

  local function put(x, y, s, fg, bg)
    if y < 1 or y > H or x > W then return end
    if x < 1 then s = s:sub(2 - x) x = 1 end
    s = s:sub(1, W - x + 1)
    if s == "" then return end
    term.setCursorPos(x, y)
    term.setTextColor(fg or colors.white)
    term.setBackgroundColor(bg or colors.black)
    term.write(s)
  end

  local function button(x, y, label, fn, fg, bg)
    label = " " .. label .. " "
    if x + #label - 1 > W then return x end
    put(x, y, label, fg, bg)
    zones[#zones + 1] = { x, x + #label - 1, y, fn }
    return x + #label + 1
  end

  local fx, fy, cwid
  local function draw()
    zones = {}
    term.setBackgroundColor(colors.black)
    term.clear()
    put(1, 1, string.rep(" ", W), colors.white, colors.gray)
    local face = state == "won" and "B)" or (state == "lost" and "X(" or ":)")
    local t = started and (state == "play" and math.floor(os.clock() - t0) or elapsed) or 0
    if state == "lost" then t = elapsed end
    local x = button(1, 1, face, function() newGame() end, colors.black, colors.yellow)
    put(x, 1, ("%d"):format(mines - flags), colors.red, colors.gray)
    x = x + #tostring(mines - flags) + 1
    x = button(x, 1, flagMode and "flag" or "dig", function() flagMode = not flagMode end,
               colors.white, flagMode and colors.red or colors.green)
    x = button(x, 1, LEVELS[level][1], function() level = level % #LEVELS + 1 newGame() end, colors.white, colors.blue)
    local ts = ("%ds"):format(t)
    if W - #ts > x then put(W - #ts, 1, ts, colors.white, colors.gray) end

    cwid = cellW()
    fx = math.floor((W - cw * cwid) / 2) + 1
    fy = 2 + math.max(0, math.floor((H - 2 - ch) / 2))
    for y = 1, ch do
      for xx = 1, cw do
        local c = cells[y][xx]
        local s, fg, bg = " ", colors.white, ((xx + y) % 2 == 0) and colors.lightGray or colors.white
        if c.open then
          bg = colors.black
          if c.mine then s, fg, bg = "*", colors.white, colors.red
          elseif c.n > 0 then s, fg = tostring(c.n), NUM[c.n] end
        elseif c.flag then s, fg = "F", colors.red
          if state == "lost" and not c.mine then s = "x" end
        end
        if state ~= "play" and c.mine and c.flag then s, fg, bg = "F", colors.white, colors.green end
        if cwid == 3 then s = " " .. s .. " " elseif cwid == 2 then s = s .. " " end
        if cur[1] == xx and cur[2] == y and state == "play" and not c.open then bg = colors.yellow end
        if fy + y - 1 <= H - 1 then put(fx + (xx - 1) * cwid, fy + y - 1, s, fg, bg) end
      end
    end
    put(1, H, string.rep(" ", W), colors.lightGray, colors.gray)
    local msg = state == "won" and ("cleared in %ds!"):format(elapsed)
      or (state == "lost" and "boom! tap the face to retry" or "tap: dig  f: flag  q: quit")
    local key = LEVELS[level][1] .. "_" .. cw .. "x" .. ch
    if best[key] and state ~= "lost" then msg = msg .. ("  best %ds"):format(best[key]) end
    put(2, H, msg, state == "won" and colors.lime or colors.lightGray, colors.gray)
  end

  local function render()
    buf.setVisible(false)
    local old = term.redirect(buf)
    draw()
    term.redirect(old)
    buf.setVisible(true)
  end

  newGame()
  render()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == tick then
      if state == "play" then tick = os.startTimer(1) end
    elseif e == "char" then
      a = a:lower()
      if a == "q" then break
      elseif a == "f" then flagMode = not flagMode
      elseif a == "n" then newGame()
      elseif a == "l" then level = level % #LEVELS + 1 newGame()
      elseif a == " " then act(cur[1], cur[2], flagMode) end
    elseif e == "key" then
      if a == keys.up then cur[2] = math.max(1, cur[2] - 1)
      elseif a == keys.down then cur[2] = math.min(ch, cur[2] + 1)
      elseif a == keys.left then cur[1] = math.max(1, cur[1] - 1)
      elseif a == keys.right then cur[1] = math.min(cw, cur[1] + 1)
      elseif a == keys.enter then
        if state == "play" then act(cur[1], cur[2], flagMode) else newGame() end
      end
    elseif e == "mouse_click" or e == "monitor_touch" then
      local hit
      for _, z in ipairs(zones) do if c == z[3] and b >= z[1] and b <= z[2] then hit = z[4] end end
      if hit then hit()
      elseif fx and c >= fy and c < fy + ch then
        local gx, gy = math.floor((b - fx) / cwid) + 1, c - fy + 1
        if gx >= 1 and gx <= cw then act(gx, gy, flagMode or (e == "mouse_click" and a == 2)) end
      end
    elseif e == "term_resize" then
      W, H = parent.getSize()
      buf = window.create(parent, 1, 1, W, H, false)
      if not started then newGame() end
    end
    render()
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return {
  name = "Minesweeper", short = "Mines", icon = "*F", color = colors.red, order = 62, w = 32, h = 15,
  art = { { "1F2 ", "be3f", "0880" }, { " *1 ", "f0bf", "8e08" } },
  main = main,
}
