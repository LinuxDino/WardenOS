-- 3x5 pixel font drawn with colored spaces. Usage: bigfont.draw(termObj, "WARDEN", x, y, color)
local G = {
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "001", "001", "001" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
  [":"] = { "0", "1", "0", "1", "0" },
  ["A"] = { "010", "101", "111", "101", "101" },
  ["D"] = { "110", "101", "101", "101", "110" },
  ["E"] = { "111", "100", "110", "100", "111" },
  ["N"] = { "101", "111", "111", "101", "101" },
  ["O"] = { "111", "101", "101", "101", "111" },
  ["R"] = { "110", "101", "110", "101", "101" },
  ["S"] = { "111", "100", "111", "001", "111" },
  ["W"] = { "101", "101", "101", "111", "101" },
  [" "] = { "0", "0", "0", "0", "0" },
}

local M = {}

function M.width(str)
  local w = 0
  for ch in str:upper():gmatch(".") do
    local g = G[ch]
    if g then w = w + #g[1] + 1 end
  end
  return math.max(0, w - 1)
end

function M.draw(t, str, x, y, color)
  t.setBackgroundColor(color)
  local cx = x
  for ch in str:upper():gmatch(".") do
    local g = G[ch]
    if g then
      for r = 1, 5 do
        local row = g[r]
        local c = 1
        while c <= #row do
          if row:sub(c, c) == "1" then
            local s = c
            while c < #row and row:sub(c + 1, c + 1) == "1" do c = c + 1 end
            t.setCursorPos(cx + s - 1, y + r - 1)
            t.write(string.rep(" ", c - s + 1))
          end
          c = c + 1
        end
      end
      cx = cx + #g[1] + 1
    end
  end
end

return M
