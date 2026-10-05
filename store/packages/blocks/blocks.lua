-- Blocks for WardenOS: falling blocks, fill whole rows to clear them.
-- left/right move, up rotates, down drops faster, space drops, p pause, q quit. Touch: the buttons at the bottom.
local DATA = "/os/data/blocks/best"
local SHAPES = {
  { c = colors.cyan,   s = { { 0, 0, 0, 0 }, { 1, 1, 1, 1 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } } },   -- I
  { c = colors.yellow, s = { { 1, 1 }, { 1, 1 } } },                                             -- O
  { c = colors.purple, s = { { 0, 1, 0 }, { 1, 1, 1 }, { 0, 0, 0 } } },                         -- T
  { c = colors.lime,   s = { { 0, 1, 1 }, { 1, 1, 0 }, { 0, 0, 0 } } },                         -- S
  { c = colors.red,    s = { { 1, 1, 0 }, { 0, 1, 1 }, { 0, 0, 0 } } },                         -- Z
  { c = colors.blue,   s = { { 1, 0, 0 }, { 1, 1, 1 }, { 0, 0, 0 } } },                         -- J
  { c = colors.orange, s = { { 0, 0, 1 }, { 1, 1, 1 }, { 0, 0, 0 } } },                         -- L
}
local POINTS = { 40, 100, 300, 1200 }

local function rotate(s)
  local n, r = #s, {}
  for y = 1, n do
    r[y] = {}
    for x = 1, n do r[y][x] = s[n - x + 1][y] end
  end
  return r
end

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local BW = 10
  local BH, well, piece, nextP, score, lines, lvl, state, ticker, best, zones
  best, zones = 0, {}
  local f = fs.exists(DATA) and fs.open(DATA, "r")
  if f then best = tonumber(f.readAll()) or 0 f.close() end

  local function saveBest()
    if score <= best then return end
    best = score
    fs.makeDir("/os/data/blocks")
    local h = fs.open(DATA, "w")
    if h then h.write(tostring(best)) h.close() end
  end

  local function newPiece(kind)
    local k = kind or math.random(1, #SHAPES)
    return { k = k, s = SHAPES[k].s, x = math.floor((BW - #SHAPES[k].s) / 2) + 1, y = 1 }
  end

  local function fits(s, px, py)
    for y = 1, #s do for x = 1, #s do
      if s[y][x] == 1 then
        local gx, gy = px + x - 1, py + y - 1
        if gx < 1 or gx > BW or gy > BH then return false end
        if gy >= 1 and well[gy][gx] ~= 0 then return false end
      end
    end end
    return true
  end

  local function delay() return math.max(0.08, 0.6 - (lvl - 1) * 0.06) end

  local function newGame()
    BH = math.max(8, math.min(20, H - 2))
    well = {}
    for y = 1, BH do well[y] = {} for x = 1, BW do well[y][x] = 0 end end
    score, lines, lvl, state = 0, 0, 1, "play"
    piece, nextP = newPiece(), newPiece()
    ticker = os.startTimer(delay())
  end

  local function lock()
    for y = 1, #piece.s do for x = 1, #piece.s do
      if piece.s[y][x] == 1 then
        local gy = piece.y + y - 1
        if gy >= 1 then well[gy][piece.x + x - 1] = SHAPES[piece.k].c end
      end
    end end
    local cleared = 0
    local y = BH
    while y >= 1 do
      local full = true
      for x = 1, BW do if well[y][x] == 0 then full = false break end end
      if full then
        table.remove(well, y)
        local row = {}
        for x = 1, BW do row[x] = 0 end
        table.insert(well, 1, row)
        cleared = cleared + 1
      else
        y = y - 1
      end
    end
    if cleared > 0 then
      score = score + POINTS[cleared] * lvl
      lines = lines + cleared
      lvl = math.floor(lines / 10) + 1
    end
    piece, nextP = nextP, newPiece()
    if not fits(piece.s, piece.x, piece.y) then state = "over" saveBest() end
  end

  local function fall()
    if fits(piece.s, piece.x, piece.y + 1) then piece.y = piece.y + 1 return true end
    lock()
    return false
  end

  local function shift(dx)
    if fits(piece.s, piece.x + dx, piece.y) then piece.x = piece.x + dx end
  end
  local function turn()
    local r = rotate(piece.s)
    for _, dx in ipairs({ 0, -1, 1, -2, 2 }) do                     -- simple wall kicks
      if fits(r, piece.x + dx, piece.y) then piece.s, piece.x = r, piece.x + dx return end
    end
  end
  local function drop()
    local n = 0
    while fits(piece.s, piece.x, piece.y + 1) do piece.y = piece.y + 1 n = n + 1 end
    score = score + n * 2
    lock()
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
    zones = {}
    term.setBackgroundColor(colors.black)
    term.clear()
    local cell = (W >= BW * 2 + 14) and 2 or 1
    local side = W - BW * cell - 2 >= 10
    local total = BW * cell + 2 + (side and 11 or 0)
    local bx = math.floor((W - total) / 2) + 1
    local by = 1 + math.max(0, math.floor((H - 1 - (BH + 1)) / 2))
    -- well with walls
    for y = 1, BH do
      put(bx, by + y - 1, " ", colors.white, colors.gray)
      put(bx + BW * cell + 1, by + y - 1, " ", colors.white, colors.gray)
      for x = 1, BW do
        local c = well[y][x]
        put(bx + 1 + (x - 1) * cell, by + y - 1, (c == 0 and (x % 2 == 0 and "." or " ") or " "):rep(cell):sub(1, cell),
            colors.gray, c == 0 and colors.black or c)
      end
    end
    put(bx, by + BH, string.rep(" ", BW * cell + 2), colors.white, colors.gray)
    if state ~= "over" then
      -- ghost, then the piece
      local gy = piece.y
      while fits(piece.s, piece.x, gy + 1) do gy = gy + 1 end
      for pass = 1, 2 do
        local py = pass == 1 and gy or piece.y
        for y = 1, #piece.s do for x = 1, #piece.s do
          if piece.s[y][x] == 1 and py + y - 1 >= 1 then
            local sx, sy = bx + 1 + (piece.x + x - 2) * cell, by + py + y - 2
            if pass == 1 then put(sx, sy, ("::"):sub(1, cell), SHAPES[piece.k].c, colors.black)
            else put(sx, sy, ("  "):sub(1, cell), colors.white, SHAPES[piece.k].c) end
          end
        end end
      end
    end
    -- side panel
    local sx = bx + BW * cell + 3
    local function stat(y, label, v)
      if side then put(sx, by + y, label, colors.lightGray) put(sx, by + y + 1, tostring(v), colors.white) end
    end
    if side then
      put(sx, by, "BLOCKS", colors.orange)
      put(sx, by + 1, "next", colors.lightGray)
      local n = 0
      for _, row in ipairs(SHAPES[nextP.k].s) do
        local any = false
        for x = 1, #row do
          if row[x] == 1 then any = true put(sx + (x - 1) * 2, by + 2 + n, "  ", colors.white, SHAPES[nextP.k].c) end
        end
        if any then n = n + 1 end
      end
      stat(5, "score", score)
      stat(7, "lines", lines)
      stat(9, "level", lvl)
      stat(11, "best", math.max(best, score))
    else
      put(1, 1, ("%d L%d"):format(score, lvl), colors.white)
    end
    -- touch buttons
    local x = 1
    for _, b in ipairs({ { "<", "left" }, { "o", "turn" }, { ">", "right" }, { "v", "down" }, { "drop", "drop" },
                         { state == "pause" and "go" or "||", "pause" } }) do
      local label = " " .. b[1] .. " "
      if x + #label - 1 <= W then
        put(x, H, label, colors.white, colors.gray)
        zones[#zones + 1] = { x, x + #label - 1, H, b[2] }
      end
      x = x + #label + 1
    end
    if state ~= "play" then
      local msg = state == "over" and " GAME OVER - Enter / tap " or " PAUSED "
      put(math.max(1, math.floor((W - #msg) / 2) + 1), math.floor(H / 2), msg, colors.white,
          state == "over" and colors.red or colors.blue)
    end
  end

  local function render()
    buf.setVisible(false)
    local old = term.redirect(buf)
    draw()
    term.redirect(old)
    buf.setVisible(true)
  end

  local function action(a)
    if state == "over" then if a ~= "pause" then newGame() end return end
    if a == "pause" then
      state = state == "pause" and "play" or "pause"
      if state == "play" then ticker = os.startTimer(delay()) end
      return
    end
    if state ~= "play" then return end
    if a == "left" then shift(-1) elseif a == "right" then shift(1)
    elseif a == "turn" then turn() elseif a == "down" then if fall() then score = score + 1 end
    elseif a == "drop" then drop() end
  end

  newGame()
  render()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == ticker then
      if state == "play" then fall() ticker = os.startTimer(delay()) end
    elseif e == "char" then
      a = a:lower()
      if a == "q" then break
      elseif a == " " then action("drop") elseif a == "p" then action("pause")
      elseif a == "a" then action("left") elseif a == "d" then action("right")
      elseif a == "w" then action("turn") elseif a == "s" then action("down") end
    elseif e == "key" then
      if a == keys.left then action("left") elseif a == keys.right then action("right")
      elseif a == keys.up then action("turn") elseif a == keys.down then action("down")
      elseif a == keys.enter and state == "over" then newGame() end
    elseif e == "mouse_click" or e == "monitor_touch" then
      local hit
      for _, z in ipairs(zones) do if c == z[3] and b >= z[1] and b <= z[2] then hit = z[4] end end
      if hit then action(hit) elseif state == "over" then newGame() else action("turn") end
    elseif e == "term_resize" then
      W, H = parent.getSize()
      buf = window.create(parent, 1, 1, W, H, false)
      if math.max(8, math.min(20, H - 2)) ~= BH then newGame() end
    end
    render()
  end
  saveBest()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return {
  name = "Blocks", short = "Block", icon = "[]=", color = colors.purple, order = 63, w = 36, h = 18,
  art = { { "    ", "0000", "a99f" }, { "    ", "0000", "aa4e" } },
  main = main,
}
