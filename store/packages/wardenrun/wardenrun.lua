-- Warden Run for WardenOS: the Warden is right behind you in the Deep Dark. Jump over the sculk, grab echo shards.
-- space / up / tap = jump, p pause, q quit.
local DATA = "/os/data/wardenrun/best"
local ARC = { 1, 2, 3, 3, 4, 4, 4, 3, 3, 2, 1 }   -- jump height per tick

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local best = 0
  local f = fs.exists(DATA) and fs.open(DATA, "r")
  if f then best = tonumber(f.readAll()) or 0 f.close() end
  local speaker = peripheral and peripheral.find and peripheral.find("speaker") or nil

  local state, ticker, t, dist, shards, jump, obs, gems, stars, rate, ground, px, lastGap, stomp

  local function saveBest()
    local s = dist + shards * 10
    if s <= best then return end
    best = s
    fs.makeDir("/os/data/wardenrun")
    local h = fs.open(DATA, "w")
    if h then h.write(tostring(best)) h.close() end
  end

  local function newGame()
    ground = H - 2
    px = math.min(12, math.max(6, math.floor(W / 4)))
    state, t, dist, shards, jump, rate, lastGap, stomp = "play", 0, 0, 0, 0, 0.1, 0, 0
    obs, gems, stars = {}, {}, {}
    for _ = 1, math.floor(W * (H - 4) / 40) do
      stars[#stars + 1] = { math.random(1, W), math.random(2, math.max(2, ground - 5)) }
    end
    ticker = os.startTimer(rate)
  end

  local function height() return jump > 0 and ARC[jump] or 0 end

  local function update()
    t = t + 1
    dist = dist + 1
    if jump > 0 then jump = jump + 1 if jump > #ARC then jump = 0 end end
    for _, o in ipairs(obs) do o.x = o.x - 1 end
    for _, g in ipairs(gems) do g.x = g.x - 1 end
    if t % 3 == 0 then for _, s in ipairs(stars) do s[1] = s[1] - 1 if s[1] < 1 then s[1] = W end end end
    while obs[1] and obs[1].x < -2 do table.remove(obs, 1) end
    while gems[1] and gems[1].x < 1 do table.remove(gems, 1) end
    -- new sculk: gaps shrink as you get faster
    lastGap = lastGap + 1
    local minGap = math.max(10, 22 - math.floor(dist / 150))
    if lastGap >= minGap and math.random() < 0.18 then
      local tall = dist > 120 and math.random() < 0.35
      obs[#obs + 1] = { x = W + 1, h = tall and 2 or 1, w = math.random() < 0.3 and 2 or 1 }
      lastGap = 0
      if math.random() < 0.5 then gems[#gems + 1] = { x = W + 1, y = ground - (tall and 4 or 3) } end
    end
    -- collisions (the runner is 1 column wide, 2 rows tall)
    local feet = ground - height()
    for _, o in ipairs(obs) do
      if px >= o.x and px < o.x + o.w and feet > ground - o.h then
        state = "over"
        saveBest()
        if speaker then pcall(speaker.playSound, "entity.warden.roar", 1, 1) end
        return
      end
    end
    for i = #gems, 1, -1 do
      local g = gems[i]
      if g.x == px and (g.y == feet or g.y == feet - 1) then
        shards = shards + 1
        table.remove(gems, i)
        if speaker then pcall(speaker.playNote, "chime", 1, 20) end
      end
    end
    if t % 50 == 0 then rate = math.max(0.05, rate - 0.005) end
    stomp = (stomp + 1) % 4
    if stomp == 0 and speaker and t % 8 == 0 then pcall(speaker.playNote, "basedrum", 0.6, 1) end
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

  local function draw()
    term.setBackgroundColor(colors.black)
    term.clear()
    for _, s in ipairs(stars) do put(s[1], s[2], ".", colors.gray) end
    -- ground: sculk
    put(1, ground + 1, string.rep(" ", W), colors.cyan, colors.blue)
    for x = 1, W do
      if (x + dist) % 5 == 0 then put(x, ground + 1, "~", colors.cyan, colors.blue) end
    end
    for _, o in ipairs(obs) do
      for r = 0, o.h - 1 do
        put(o.x, ground - r, (r == o.h - 1 and "/\\" or "##"):sub(1, o.w), colors.cyan, colors.gray)
      end
    end
    for _, g in ipairs(gems) do put(g.x, g.y, "*", colors.lightBlue, colors.black) end
    -- the runner
    local feet = ground - height()
    local legs = (state == "over") and "x" or (jump > 0 and "^" or ((t % 2 == 0) and "/" or "\\"))
    put(px, feet - 1, "o", colors.white, colors.black)
    put(px, feet, legs, colors.lightBlue, colors.black)
    -- the Warden, 2 columns behind
    local wx = px - 4 - ((state == "over") and -2 or 0)
    local bob = (stomp < 2) and 0 or 1
    put(wx, ground - 2 + bob, "oo", colors.cyan, colors.gray)
    put(wx - 1, ground - 1 + bob, "\\  /", colors.cyan, colors.gray)
    put(wx, ground, (stomp % 2 == 0) and "/\\" or "||", colors.cyan, colors.gray)
    -- top bar
    put(1, 1, string.rep(" ", W), colors.white, colors.gray)
    put(2, 1, "WARDEN RUN", colors.cyan, colors.gray)
    local sc = ("%dm  *%d  best %d"):format(dist, shards, best)
    if W - #sc > 13 then put(W - #sc, 1, sc, colors.white, colors.gray) end
    put(1, H, string.rep(" ", W), colors.lightGray, colors.black)
    put(2, H, state == "pause" and "paused - p resumes" or "space / tap: jump  p pause  q quit", colors.lightGray, colors.black)
    if state == "over" then
      local lines = { " THE WARDEN GOT YOU ", (" %d m  +  %d shards = %d "):format(dist, shards, dist + shards * 10),
                      " Enter / tap: run again " }
      for i, l in ipairs(lines) do
        put(math.floor((W - #l) / 2) + 1, math.floor(H / 2) - 2 + i, l, i == 1 and colors.red or colors.white, colors.gray)
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

  local function hop()
    if state == "over" then newGame() return end
    if state == "play" and jump == 0 then jump = 1 end
  end

  newGame()
  render()
  while true do
    local e, a = os.pullEvent()
    if e == "timer" and a == ticker then
      if state == "play" then update() end
      if state == "play" then ticker = os.startTimer(rate) end
      render()
    elseif e == "char" then
      a = a:lower()
      if a == "q" then break
      elseif a == " " or a == "w" then hop()
      elseif a == "p" and state ~= "over" then
        state = state == "pause" and "play" or "pause"
        if state == "play" then ticker = os.startTimer(rate) end
        render()
      end
    elseif e == "key" then
      if a == keys.up then hop() elseif a == keys.enter and state == "over" then newGame() end
      render()
    elseif e == "mouse_click" or e == "monitor_touch" then
      hop()
      render()
    elseif e == "term_resize" then
      W, H = parent.getSize()
      buf = window.create(parent, 1, 1, W, H, false)
      newGame()
      render()
    end
  end
  saveBest()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return {
  name = "Warden Run", short = "Run", icon = "o/", color = colors.cyan, order = 64, w = 40, h = 14,
  art = { { "99 o", "99f0", "777f" }, { "/\\ \\", "999b", "777f" } },
  main = main,
}
