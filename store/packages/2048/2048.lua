-- 2048 for WardenOS: slide the tiles, merge equal numbers, reach 2048. Arrows / WASD or swipe-tap the edges.
local DATA = "/os/data/2048/best"
local TILE = {                                   -- value -> text color, background
  [2] = { colors.gray, colors.white }, [4] = { colors.gray, colors.lightGray },
  [8] = { colors.white, colors.orange }, [16] = { colors.white, colors.red },
  [32] = { colors.white, colors.pink }, [64] = { colors.white, colors.magenta },
  [128] = { colors.black, colors.yellow }, [256] = { colors.black, colors.lime },
  [512] = { colors.white, colors.green }, [1024] = { colors.white, colors.cyan },
  [2048] = { colors.white, colors.blue },
}

local function main()
  local parent = term.current()
  local W, H = parent.getSize()
  local buf = window.create(parent, 1, 1, W, H, false)
  local grid, score, best, state, moved = {}, 0, 0, "play", false
  local zones = {}

  local f = fs.exists(DATA) and fs.open(DATA, "r")
  if f then best = tonumber(f.readAll()) or 0 f.close() end
  local function saveBest()
    if score <= best then return end
    best = score
    fs.makeDir("/os/data/2048")
    local h = fs.open(DATA, "w")
    if h then h.write(tostring(best)) h.close() end
  end

  local function addTile()
    local empty = {}
    for y = 1, 4 do for x = 1, 4 do if grid[y][x] == 0 then empty[#empty + 1] = { x, y } end end end
    if #empty == 0 then return end
    local c = empty[math.random(1, #empty)]
    grid[c[2]][c[1]] = math.random() < 0.9 and 2 or 4
  end
  local function newGame()
    saveBest()
    for y = 1, 4 do grid[y] = { 0, 0, 0, 0 } end
    score, state = 0, "play"
    addTile() addTile()
  end

  -- slide one line towards index 1; returns the new line and the points earned
  local function slide(line)
    local out, pts, i = {}, 0, 1
    local vals = {}
    for _, v in ipairs(line) do if v ~= 0 then vals[#vals + 1] = v end end
    while i <= #vals do
      if vals[i + 1] and vals[i] == vals[i + 1] then
        out[#out + 1] = vals[i] * 2
        pts = pts + vals[i] * 2
        i = i + 2
      else
        out[#out + 1] = vals[i]
        i = i + 1
      end
    end
    for k = #out + 1, 4 do out[k] = 0 end
    return out, pts
  end

  local function canMove()
    for y = 1, 4 do for x = 1, 4 do
      local v = grid[y][x]
      if v == 0 then return true end
      if x < 4 and grid[y][x + 1] == v then return true end
      if y < 4 and grid[y + 1][x] == v then return true end
    end end
    return false
  end

  local function move(dx, dy)
    if state == "over" then return end
    moved = false
    for i = 1, 4 do
      local idx = {}
      for k = 1, 4 do
        -- the cells of row/column i, starting at the edge we slide towards
        local x, y
        if dx ~= 0 then y = i x = dx < 0 and k or 5 - k else x = i y = dy < 0 and k or 5 - k end
        idx[k] = { x, y }
      end
      local line = {}
      for k, c in ipairs(idx) do line[k] = grid[c[2]][c[1]] end
      local new, pts = slide(line)
      for k, c in ipairs(idx) do
        if grid[c[2]][c[1]] ~= new[k] then moved = true end
        grid[c[2]][c[1]] = new[k]
      end
      score = score + pts
    end
    if moved then
      addTile()
      for y = 1, 4 do for x = 1, 4 do
        if grid[y][x] == 2048 and state == "play" then state = "won" end
      end end
      if not canMove() then state = "over" saveBest() end
    end
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
    put(1, 1, string.rep(" ", W), colors.white, colors.orange)
    put(2, 1, "2048", colors.white, colors.orange)
    local info = ("score %d  best %d"):format(score, math.max(best, score))
    if W - #info > 7 then put(W - #info, 1, info, colors.white, colors.orange) end
    -- tile size: as big as fits (width 4..10, height 1..5)
    local tw = math.max(4, math.min(10, math.floor((W - 3) / 4)))
    local th = math.max(1, math.min(5, math.floor((H - 3) / 4)))
    if th >= 3 and tw < 6 then th = 2 end
    local bw, bh = tw * 4 + 3, th * 4 + 3
    local bx = math.floor((W - bw) / 2) + 1
    local by = 2 + math.max(0, math.floor((H - 2 - bh) / 2))
    for y = by, math.min(H - 1, by + bh - 1) do put(bx, y, string.rep(" ", bw), colors.white, colors.gray) end
    for gy = 1, 4 do for gx = 1, 4 do
      local v = grid[gy][gx]
      local c = TILE[v] or (v > 0 and { colors.white, colors.purple }) or { colors.gray, colors.lightGray }
      local x, y = bx + 1 + (gx - 1) * (tw + 1), by + 1 + (gy - 1) * (th + 1)
      local bg = v == 0 and colors.black or c[2]
      for r = 0, th - 1 do
        local text = string.rep(" ", tw)
        if r == math.floor((th - 1) / 2) and v > 0 then
          local s = tostring(v)
          if #s > tw then s = (v >= 1024 and math.floor(v / 1024) .. "k") or s:sub(1, tw) end
          local l = math.floor((tw - #s) / 2)
          text = string.rep(" ", l) .. s .. string.rep(" ", tw - l - #s)
        end
        if y + r <= H - 1 then put(x, y + r, text, c[1], bg) end
      end
    end end
    -- footer: touch buttons
    put(1, H, string.rep(" ", W), colors.lightGray, colors.gray)
    local x = 2
    for _, b in ipairs({ { "<", -1, 0 }, { "^", 0, -1 }, { "v", 0, 1 }, { ">", 1, 0 }, { "new", 0, 0 } }) do
      local label = " " .. b[1] .. " "
      if x + #label - 1 <= W then
        put(x, H, label, colors.white, b[1] == "new" and colors.orange or colors.black)
        zones[#zones + 1] = { x, x + #label - 1, H, b }
      end
      x = x + #label + 1
    end
    if x + 6 <= W then put(x, H, "q quit", colors.lightGray, colors.gray) end
    if state ~= "play" then
      local msg = state == "won" and " 2048! keep going " or " no moves left "
      put(math.floor((W - #msg) / 2) + 1, math.floor(H / 2), msg, colors.white, state == "won" and colors.blue or colors.red)
    end
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
    if e == "char" then
      a = a:lower()
      if a == "q" then break
      elseif a == "w" then move(0, -1) elseif a == "s" then move(0, 1)
      elseif a == "a" then move(-1, 0) elseif a == "d" then move(1, 0)
      elseif a == "n" then newGame() end
    elseif e == "key" then
      if a == keys.up then move(0, -1) elseif a == keys.down then move(0, 1)
      elseif a == keys.left then move(-1, 0) elseif a == keys.right then move(1, 0)
      elseif a == keys.enter and state == "over" then newGame() end
    elseif e == "mouse_click" or e == "monitor_touch" then
      local hit
      for _, z in ipairs(zones) do if c == z[3] and b >= z[1] and b <= z[2] then hit = z[4] end end
      if hit then
        if hit[1] == "new" then newGame() else move(hit[2], hit[3]) end
      elseif state == "over" then newGame()
      elseif c > 1 and c < H then
        -- tap a side of the board: slide that way
        local dx, dy = (b - W / 2) / W, (c - H / 2) / H
        if math.abs(dx) > math.abs(dy) then move(dx < 0 and -1 or 1, 0) else move(0, dy < 0 and -1 or 1) end
      end
    elseif e == "term_resize" then
      W, H = parent.getSize()
      buf = window.create(parent, 1, 1, W, H, false)
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
  name = "2048", short = "2048", icon = "2K", color = colors.orange, order = 61, w = 32, h = 18,
  art = { { "2048", "0000", "1e2a" }, { "    ", "0000", "45d9" } },
  main = main,
}
