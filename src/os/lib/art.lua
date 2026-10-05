-- Pixel art drawn with colored spaces (term.blit). Used by the boot screen, login, desktop, installer and pocket.
--
--   art.get(name, size[, bg])         -> { w =, h =, rows = { { text, fg, bg }, ... } } or nil
--                                        blit strings of length w; transparent cells get bg (blit char or
--                                        color, default "f" = black)
--   art.draw(t, name, size, x, y[, map]) draws on terminal object t, clipped to t's size; transparent cells
--                                        are skipped (whatever is below stays). map = { [blit] = blit } recolors.
--                                        Returns w, h (0, 0 for an unknown name).
--   art.names()                        -> { "logo", "sculk", "warden" }
--   art.sizes(name)                    -> { "small", "medium", "large" } (smallest first)
--   art.fit(name, maxW, maxH)          -> the largest size that fits, or nil
--   art.blit(t, img, x, y[, map])      draws an image table ({ w, h, rows }) like art.draw
--   art.icon(t, app, x, y, panel)      draws an app header's 4x2 `art` (bg "7" = the panel behind it);
--                                        returns false when the app has no valid art (use the text icon)
--   art.validIcon(a)                   -> true when a is a valid 4x2 icon { { text, fg, bg }, { ... } }
--   art.hex(color)                     -> blit char of a colors.* value
--   art.wallpaper(t, x, y, w, h, bg, map) fills a region with bg plus the sculk pattern
--
-- Colors look right with the default CC palette and with the WardenOS themes (no palette tricks needed):
-- 7 (gray) = the Warden's dark body, f (black) = shade/mouth, 9 (cyan) = glow, 3 (lightBlue) = soul core,
-- 8 (lightGray) = bone. "." in the source grids below is transparent.
local M = {}

local HEX = "0123456789abcdef"
function M.hex(c)
  if type(c) == "string" then return c end
  local n = math.floor(math.log(tonumber(c) or 1) / math.log(2) + 0.5)
  if n < 0 or n > 15 then n = 15 end
  return HEX:sub(n + 1, n + 1)
end

-- grids: one string per row, a blit color char per cell or "." (transparent)
local ART = {
  warden = {
    small = {
      "3......3",
      "97777779",
      ".797797.",
      ".7f88f7.",
      "77933977",
    },
    medium = {
      "39..........93",
      "797........797",
      ".777777777777.",
      "...77777777...",
      "...79777797...",
      "...7f8ff8f7...",
      ".7777f88f7777.",
      "77778933987777",
    },
    large = {
      "39..................93",
      "997................799",
      "7977..............7797",
      ".77777777777777777777.",
      "..777777777777777777..",
      "....77777777777777....",
      "....79777777777797....",
      "....7ffffffffffff7....",
      "....7f8f8f88f8f8f7....",
      "....77ffffffffff77....",
      ".77777778999987777777.",
      "7777977879339787797777",
    },
  },
  sculk = {                                     -- sparse sculk veins and a few glowing sensors (tiles)
    small = {
      "..7......7..",
      "..77.....77.",
      "......9.....",
      "....7.......",
    },
    medium = {
      "................",
      "..77.......7....",
      "...7.......77...",
      ".........9......",
      "....7........77.",
      "...77...........",
    },
    large = {
      "........................",
      "..77..........7.........",
      "...7......9...77........",
      "..........77.......7....",
      "......7.............77..",
      ".....77.......7.........",
      "...............77.....9.",
      "....9...................",
    },
  },
}

-- WARDEN wordmark from 3x5 glyphs (same shapes as /os/lib/bigfont.lua), cyan with a teal shadow row
local GLYPH = {
  W = { "101", "101", "101", "111", "101" }, A = { "010", "101", "111", "101", "101" },
  R = { "110", "101", "110", "101", "101" }, D = { "110", "101", "101", "101", "110" },
  E = { "111", "100", "110", "100", "111" }, N = { "101", "111", "111", "101", "101" },
}
local function wordmark(sx, sy)
  local rows = {}
  for r = 1, 5 do
    local line = {}
    for i, ch in ipairs({ "W", "A", "R", "D", "E", "N" }) do
      if i > 1 then line[#line + 1] = string.rep(".", sx) end
      local c = r == 5 and "3" or "9"
      line[#line + 1] = (GLYPH[ch][r]:gsub("1", string.rep(c, sx)):gsub("0", string.rep(".", sx)))
    end
    local s = table.concat(line)
    for _ = 1, sy do rows[#rows + 1] = s end
  end
  return rows
end
ART.logo = { small = wordmark(1, 1), medium = wordmark(2, 1), large = wordmark(2, 2) }

local SIZES = { "small", "medium", "large" }

function M.names()
  local t = {}
  for k in pairs(ART) do t[#t + 1] = k end
  table.sort(t)
  return t
end

function M.sizes(name)
  local t = {}
  for _, s in ipairs(SIZES) do if ART[name] and ART[name][s] then t[#t + 1] = s end end
  return t
end

local function grid(name, size)
  local a = ART[name]
  if not a then return nil end
  return a[size or "medium"] or a.medium or a.small
end

function M.get(name, size, bg)
  local g = grid(name, size)
  if not g then return nil end
  bg = M.hex(bg or "f")
  local w = #g[1]
  local rows = {}
  for i, r in ipairs(g) do
    rows[i] = { string.rep(" ", w), string.rep("0", w), (r:gsub("%.", bg)) }
  end
  return { w = w, h = #g, rows = rows }
end

function M.fit(name, maxW, maxH)
  local best
  for _, s in ipairs(SIZES) do
    local g = ART[name] and ART[name][s]
    if g and #g[1] <= maxW and #g <= maxH then best = s end
  end
  return best
end

-- draw the cells x0..x1 (1-based, inclusive) of one image row at screen column x
local function seg(t, x, y, row, a, b)
  t.setCursorPos(x + a - 1, y)
  t.blit(row[1]:sub(a, b), row[2]:sub(a, b), row[3]:sub(a, b))
end

local function drawRows(t, rows, w, x, y, map, transparent)
  local tw, th = t.getSize()
  for i, row in ipairs(rows) do
    local yy = y + i - 1
    if yy >= 1 and yy <= th then
      local bgs = row[3]
      if map then bgs = bgs:gsub(".", function(c) return map[c] end) row = { row[1], row[2], bgs } end
      local a = math.max(1, 2 - x)                -- first visible cell
      local b = math.min(w, tw - x + 1)           -- last visible cell
      local i0 = a
      while i0 <= b do                            -- runs of opaque cells
        if transparent and bgs:sub(i0, i0) == "." then
          i0 = i0 + 1
        else
          local j = i0
          while j < b and not (transparent and bgs:sub(j + 1, j + 1) == ".") do j = j + 1 end
          seg(t, x, yy, row, i0, j)
          i0 = j + 1
        end
      end
    end
  end
end

function M.draw(t, name, size, x, y, map)
  local g = grid(name, size)
  if not g then return 0, 0 end
  local w = #g[1]
  local rows = {}
  for i, r in ipairs(g) do rows[i] = { string.rep(" ", w), string.rep("0", w), r } end
  drawRows(t, rows, w, x, y, map, true)
  return w, #g
end

function M.blit(t, img, x, y, map)
  if type(img) ~= "table" or type(img.rows) ~= "table" then return 0, 0 end
  drawRows(t, img.rows, img.w, x, y, map, false)
  return img.w, img.h
end

function M.validIcon(a)
  if type(a) ~= "table" or #a ~= 2 then return false end
  for _, r in ipairs(a) do
    if type(r) ~= "table" or type(r[1]) ~= "string" or type(r[2]) ~= "string" or type(r[3]) ~= "string" then
      return false
    end
    if #r[1] ~= 4 or #r[2] ~= 4 or #r[3] ~= 4 or not (r[2] .. r[3]):match("^[0-9a-f]+$") then return false end
  end
  return true
end

-- an app's 4x2 icon; bg cells "7" take the panel color behind the icon. On a light gray panel (light theme)
-- light gray cells and text are drawn gray so they stay visible.
function M.icon(t, app, x, y, panel)
  local a = type(app) == "table" and app.art
  if not M.validIcon(a) then return false end
  local p = M.hex(panel or colors.gray)
  local swap = p == "8" and "7" or "8"
  local rows = {}
  for i = 1, 2 do
    rows[i] = { a[i][1], (a[i][2]:gsub("8", swap)), (a[i][3]:gsub("[78]", { ["7"] = p, ["8"] = swap })) }
  end
  drawRows(t, rows, 4, x, y, nil, false)
  return true
end

-- fill x..x+w-1, y..y+h-1 with bg and the sculk pattern (one blit per row, never outside t)
function M.wallpaper(t, x, y, w, h, bg, map)
  local tw, th = t.getSize()
  local x1, x2 = math.max(1, x), math.min(tw, x + w - 1)
  if x2 < x1 then return end
  bg = M.hex(bg or "f")
  local tile = ART.sculk[w >= 60 and "large" or "medium"]
  local pw, ph = #tile[1], #tile
  for yy = math.max(1, y), math.min(th, y + h - 1) do
    local src = tile[(yy - 1) % ph + 1]
    local out = {}
    for xx = x1, x2 do
      local c = src:sub((xx - 1) % pw + 1, (xx - 1) % pw + 1)
      if c == "." then c = bg elseif map and map[c] then c = map[c] end
      out[#out + 1] = c
    end
    local n = x2 - x1 + 1
    t.setCursorPos(x1, yy)
    t.blit(string.rep(" ", n), string.rep("0", n), table.concat(out))
  end
end

return M
