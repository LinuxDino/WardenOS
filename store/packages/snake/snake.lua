-- Snake for WardenOS: eat apples, grow, don't bite yourself. Arrows / WASD or tap where to turn. q quits.
local DATA = "/os/data/snake/best"

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local best, speaker = 0, nil
  local f = fs.exists(DATA) and fs.open(DATA, "r")
  if f then best = tonumber(f.readAll()) or 0 f.close() end

  local cols, rows, ox, oy                      -- board in cells (2 chars wide each)
  local snake, dir, nextDir, food, gold, score, state, ticker, speed, flash

  local function layout()
    cols = math.max(4, math.floor(W / 2))
    rows = math.max(3, H - 2)
    ox, oy = math.floor((W - cols * 2) / 2) + 1, 2
  end

  local function free(x, y)
    for _, s in ipairs(snake) do if s[1] == x and s[2] == y then return false end end
    return true
  end
  local function spot()
    for _ = 1, 200 do
      local x, y = math.random(1, cols), math.random(1, rows)
      if free(x, y) and not (food and food[1] == x and food[2] == y) then return { x, y } end
    end
    return { 1, 1 }
  end

  local function newGame()
    layout()
    local cx, cy = math.floor(cols / 2), math.floor(rows / 2) + 1
    snake = { { cx, cy }, { cx - 1, cy }, { cx - 2, cy } }
    dir, nextDir, score, speed, state, gold, flash = { 1, 0 }, { 1, 0 }, 0, 0.18, "play", nil, 0
    food = nil
    food = spot()
    ticker = os.startTimer(speed)
  end

  local function saveBest()
    if score <= best then return end
    best = score
    fs.makeDir("/os/data/snake")
    local h = fs.open(DATA, "w")
    if h then h.write(tostring(best)) h.close() end
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
    put(1, 1, string.rep(" ", W), colors.white, colors.green)
    put(2, 1, "SNAKE", colors.black, colors.green)
    local info = ("score %d  best %d"):format(score, best)
    put(W - #info, 1, info, colors.white, colors.green)
    for y = 1, rows do
      put(ox, oy + y - 1, string.rep(" ", cols * 2), colors.gray, (y % 2 == 0) and colors.black or colors.black)
    end
    local function cell(x, y, s, fg, bg) put(ox + (x - 1) * 2, oy + y - 1, s, fg, bg) end
    cell(food[1], food[2], "()", colors.red, colors.black)
    if gold then cell(gold[1], gold[2], "<>", colors.yellow, colors.black) end
    for i = #snake, 1, -1 do
      local s = snake[i]
      if i == 1 then
        local eyes = dir[1] ~= 0 and ": " or ".."
        if dir[1] < 0 then eyes = " :" end
        cell(s[1], s[2], eyes, colors.black, state == "over" and colors.red or colors.lime)
      else
        cell(s[1], s[2], "  ", colors.white, (i % 2 == 0) and colors.green or colors.lime)
      end
    end
    local foot = state == "pause" and "paused - p resumes" or "arrows/WASD  p pause  q quit"
    put(1, H, string.rep(" ", W), colors.lightGray, colors.gray)
    put(2, H, foot, colors.lightGray, colors.gray)
    if state == "over" then
      local lines = { " GAME OVER ", (" score %d "):format(score),
                      score >= best and score > 0 and " new best! " or (" best %d "):format(best),
                      " Enter / tap: again " }
      local y0 = math.floor(H / 2) - 1
      for i, l in ipairs(lines) do
        put(math.floor((W - #l) / 2) + 1, y0 + i - 1, l, i == 1 and colors.red or colors.white, colors.gray)
      end
    end
    if W < 12 or H < 6 then
      term.setBackgroundColor(colors.black)
      term.clear()
      put(1, 1, "too small", colors.red)
    end
  end

  local function render()
    buf.setVisible(false)
    local old = term.redirect(buf)
    draw()
    term.redirect(old)
    buf.setVisible(true)
  end

  local function step()
    dir = nextDir
    local head = snake[1]
    local nx, ny = head[1] + dir[1], head[2] + dir[2]
    if nx < 1 then nx = cols elseif nx > cols then nx = 1 end           -- walls wrap around
    if ny < 1 then ny = rows elseif ny > rows then ny = 1 end
    for i = 1, #snake - 1 do
      if snake[i][1] == nx and snake[i][2] == ny then
        state = "over"
        saveBest()
        if speaker then pcall(speaker.playNote, "bass", 1, 2) end
        return
      end
    end
    table.insert(snake, 1, { nx, ny })
    local grow = false
    if nx == food[1] and ny == food[2] then
      score, grow = score + 1, true
      food = spot()
      if math.random() < 0.15 and not gold then gold = spot() gold[3] = 40 end
      speed = math.max(0.07, speed - 0.005)
      if speaker then pcall(speaker.playNote, "bit", 1, 12 + (score % 12)) end
    elseif gold and nx == gold[1] and ny == gold[2] then
      score, grow, gold = score + 5, true, nil
      if speaker then pcall(speaker.playNote, "chime", 1, 18) end
    end
    if gold then gold[3] = gold[3] - 1 if gold[3] <= 0 then gold = nil end end
    if not grow then table.remove(snake) end
  end

  local function turn(dx, dy)
    if dx == -dir[1] and dy == -dir[2] then return end              -- no turning back into yourself
    nextDir = { dx, dy }
  end

  speaker = peripheral and peripheral.find and peripheral.find("speaker") or nil
  newGame()
  render()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == ticker then
      if state == "play" then step() end
      if state ~= "over" then ticker = os.startTimer(speed) end
      render()
    elseif e == "char" then
      a = a:lower()
      if a == "q" then break
      elseif a == "p" and state ~= "over" then
        state = state == "pause" and "play" or "pause"
        if state == "play" then ticker = os.startTimer(speed) end
      elseif a == "w" then turn(0, -1) elseif a == "s" then turn(0, 1)
      elseif a == "a" then turn(-1, 0) elseif a == "d" then turn(1, 0) end
      render()
    elseif e == "key" then
      if a == keys.up then turn(0, -1) elseif a == keys.down then turn(0, 1)
      elseif a == keys.left then turn(-1, 0) elseif a == keys.right then turn(1, 0)
      elseif a == keys.enter and state == "over" then newGame() end
      render()
    elseif e == "mouse_click" or e == "monitor_touch" then
      if state == "over" then newGame()
      elseif state == "play" then
        local hx = ox + (snake[1][1] - 1) * 2
        local hy = oy + snake[1][2] - 1
        local dx, dy = b - hx, (c - hy) * 2
        if dir[1] ~= 0 then turn(0, dy < 0 and -1 or 1)            -- moving sideways: tap above/below
        else turn(dx < 0 and -1 or 1, 0) end
      end
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
  name = "Snake", short = "Snake", icon = "~S", color = colors.lime, order = 60, w = 32, h = 18,
  art = { { " :  ", "0f00", "f55f" }, { "    ", "0000", "fdde" } },
  main = main,
}
