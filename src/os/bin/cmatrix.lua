-- cmatrix: digital rain. q or Ctrl+T quits.
local cli = dofile("/os/lib/cli.lua").init("cmatrix", shell)
local CHARS = "0123456789ABCDEFabcdef@#$%&*+=<>?/\\|"
return cli.main({
  usage = "cmatrix [-c color] [-s]",
  about = "Green characters rain down the screen, like the movie. q or Ctrl+T quits.",
  options = { "-c color  rain color: green (default), cyan, red, ...", "-s       slower" },
  flags = { c = "str", s = true, b = true },
  run = function(o)
    local main = o.c and cli.NAMES[o.c:lower()] or colors.green
    local head = colors.white
    local tail = main == colors.green and colors.lime or main
    local w, h = term.getSize()
    local drops = {}
    local function reset(i) drops[i] = { y = -math.random(0, h), len = math.random(3, math.max(4, h - 2)),
                                        speed = math.random(1, 2) } end
    for i = 1, w do reset(i) end
    local function ch() local i = math.random(1, #CHARS) return CHARS:sub(i, i) end
    cli.bg(colors.black)
    term.clear()
    local tick = 0
    while true do
      tick = tick + 1
      if cli.resized then
        cli.resized = false
        w, h = term.getSize()
        term.clear()
        for i = 1, w do if not drops[i] then reset(i) end end
      end
      for x = 1, w do
        local d = drops[x]
        if tick % d.speed == 0 then
          d.y = d.y + 1
          cli.at(x, d.y - 1, ch(), tail)
          cli.at(x, d.y, ch(), head)
          cli.at(x, d.y - d.len, " ")
          if math.random(1, 6) == 1 then cli.at(x, d.y - math.random(2, d.len), ch(), main) end
          if d.y - d.len > h then reset(x) end
        end
      end
      if not cli.sleep(o.s and 0.15 or 0.08) then break end
    end
    cli.restore()
  end,
}, ...)
