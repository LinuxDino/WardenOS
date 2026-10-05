-- figlet: big letters (WardenOS bigfont where it has the glyph, a built-in 3x5 font otherwise)
local cli = dofile("/os/lib/cli.lua").init(FIGLET_NAME or "figlet", shell)
local FONT = {
  A = { "010", "101", "111", "101", "101" }, B = { "110", "101", "110", "101", "110" },
  C = { "011", "100", "100", "100", "011" }, D = { "110", "101", "101", "101", "110" },
  E = { "111", "100", "110", "100", "111" }, F = { "111", "100", "110", "100", "100" },
  G = { "011", "100", "101", "101", "011" }, H = { "101", "101", "111", "101", "101" },
  I = { "111", "010", "010", "010", "111" }, J = { "001", "001", "001", "101", "010" },
  K = { "101", "101", "110", "101", "101" }, L = { "100", "100", "100", "100", "111" },
  M = { "10001", "11011", "10101", "10001", "10001" }, N = { "1001", "1101", "1011", "1001", "1001" },
  O = { "010", "101", "101", "101", "010" }, P = { "110", "101", "110", "100", "100" },
  Q = { "010", "101", "101", "110", "011" }, R = { "110", "101", "110", "101", "101" },
  S = { "011", "100", "010", "001", "110" }, T = { "111", "010", "010", "010", "010" },
  U = { "101", "101", "101", "101", "111" }, V = { "101", "101", "101", "101", "010" },
  W = { "10001", "10001", "10101", "11011", "10001" }, X = { "101", "101", "010", "101", "101" },
  Y = { "101", "101", "010", "010", "010" }, Z = { "111", "001", "010", "100", "111" },
  ["0"] = { "111", "101", "101", "101", "111" }, ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "110", "001", "010", "100", "111" }, ["3"] = { "110", "001", "010", "001", "110" },
  ["4"] = { "101", "101", "111", "001", "001" }, ["5"] = { "111", "100", "110", "001", "110" },
  ["6"] = { "011", "100", "110", "101", "010" }, ["7"] = { "111", "001", "010", "010", "010" },
  ["8"] = { "010", "101", "010", "101", "010" }, ["9"] = { "010", "101", "011", "001", "110" },
  [" "] = { "00", "00", "00", "00", "00" }, ["!"] = { "1", "1", "1", "0", "1" },
  ["?"] = { "110", "001", "010", "000", "010" }, ["."] = { "0", "0", "0", "0", "1" },
  [","] = { "00", "00", "00", "01", "10" }, [":"] = { "0", "1", "0", "1", "0" },
  ["-"] = { "000", "000", "111", "000", "000" }, ["+"] = { "000", "010", "111", "010", "000" },
  ["'"] = { "1", "1", "0", "0", "0" }, ["/"] = { "001", "001", "010", "100", "100" },
  ["_"] = { "000", "000", "000", "000", "111" }, ["="] = { "000", "111", "000", "111", "000" },
  ["("] = { "01", "10", "10", "10", "01" }, [")"] = { "10", "01", "01", "01", "10" },
  ["#"] = { "101", "111", "101", "111", "101" }, ["*"] = { "000", "101", "010", "101", "000" },
  ["<"] = { "001", "010", "100", "010", "001" }, [">"] = { "100", "010", "001", "010", "100" },
  ["@"] = { "111", "101", "111", "100", "111" }, ["%"] = { "101", "001", "010", "100", "101" },
}

-- a glyph from bigfont, read by drawing it onto a fake terminal
local big = cli.lib("/os/lib/bigfont.lua")
local cache = {}
local function glyph(ch)
  ch = ch:upper()
  if cache[ch] then return cache[ch] end
  local g
  if big and big.width and big.draw and ch ~= " " then
    local ok, gw = pcall(big.width, ch)
    if ok and gw and gw > 0 then
      local grid = {}
      for r = 1, 5 do grid[r] = {} for c = 1, gw do grid[r][c] = "0" end end
      local cx, cy = 1, 1
      local fake = { setBackgroundColor = function() end, setCursorPos = function(x, y) cx, cy = x, y end,
        write = function(s) for i = 1, #s do if grid[cy] and grid[cy][cx + i - 1] then grid[cy][cx + i - 1] = "1" end end end }
      if pcall(big.draw, fake, ch, 1, 1, colors.white) then
        g = {}
        for r = 1, 5 do g[r] = table.concat(grid[r]) end
      end
    end
  end
  g = g or FONT[ch] or FONT["?"]
  cache[ch] = g
  return g
end

return cli.main({
  usage = (FIGLET_NAME or "figlet") .. " [-c color] [-r] [-t] <text>",
  about = "Print text in big letters. Uses color blocks on color screens and # characters otherwise.",
  options = { "-c color  letter color (default cyan)", "-r        rainbow", "-t        # characters only",
              "-C char   draw with this character" },
  flags = { c = "str", r = true, t = true, C = "str" }, long = { color = "c", rainbow = "r", text = "t" }, stop = true,
  run = function(o, args)
    local text = table.concat(args, " ")
    if text == "" then cli.fail("usage: figlet <text>") end
    local col = o.c and (cli.NAMES[o.c:lower()] or cli.fail("unknown color " .. o.c)) or colors.cyan
    local blocks = cli.color and not o.t and not o.C
    local rainbow = { colors.red, colors.orange, colors.yellow, colors.lime, colors.cyan, colors.lightBlue, colors.magenta }
    local w = term.getSize()
    -- split into lines of letters that fit the screen (break at spaces when possible)
    local rows, cur, curW = {}, {}, 0
    local function flush() if #cur > 0 then rows[#rows + 1] = cur end cur, curW = {}, 0 end
    local words = {}
    for word in text:gmatch("%S+") do words[#words + 1] = word end
    for wi, word in ipairs(words) do
      local ww = 0
      for ch in word:gmatch(".") do ww = ww + #glyph(ch)[1] + 1 end
      if curW > 0 and curW + #glyph(" ")[1] + 1 + ww - 1 > w then flush() end
      if curW > 0 then local g = glyph(" ") cur[#cur + 1] = g curW = curW + #g[1] + 1 end
      for ch in word:gmatch(".") do
        local g = glyph(ch)
        if curW > 0 and curW + #g[1] > w then flush() end
        cur[#cur + 1] = g
        curW = curW + #g[1] + 1
      end
    end
    flush()
    local ci = 0
    local ch = (o.C or "#"):sub(1, 1)
    for _, row in ipairs(rows) do
      for r = 1, 5 do
        local x = 1
        for gi, g in ipairs(row) do
          local c = o.r and rainbow[(gi - 1 + ci) % #rainbow + 1] or col
          local bits = g[r]
          for k = 1, #bits do
            if x <= w then
              local on = bits:sub(k, k) == "1"
              if blocks then
                cli.bg(on and c or colors.black)
                term.write(" ")
              else
                cli.fg(c)
                term.write(on and ch or " ")
              end
            end
            x = x + 1
          end
          cli.bg(colors.black)
          if x <= w and gi < #row then term.write(" ") end
          x = x + 1
        end
        cli.bg(colors.black)
        cli.print("")
      end
      ci = ci + #row
      cli.print("")
    end
    cli.fg(colors.white)
  end,
}, ...)
