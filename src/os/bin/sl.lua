-- sl: a steam locomotive crosses the screen (you meant ls)
local cli = dofile("/os/lib/cli.lua").init("sl", shell)
local SMOKE = { { "  (  )  (@@)  ( ) ", "      (   )       " }, { " (@@)  ( )  (   ) ", "    ( )   (@)     " } }
local ENGINE = {
  "  ___||___________    _____ ",
  " |  _   |  [] [] |__|  []  |",
  " |_|_|__|________|  |______|",
  "/_(O)-(O)--(O)-(O)\\_(O)--(O)",
}
local WHEELS = { "/_(O)-(O)--(O)-(O)\\_(O)--(O)", "/_(o)=(o)--(o)=(o)\\_(o)==(o)" }
return cli.main({
  usage = "sl [-l]",
  about = "Steam Locomotive: what you get for typing sl instead of ls. q or Ctrl+T skips it.",
  options = { "-l  a little one" },
  flags = { l = true, a = true, F = true },
  run = function(o)
    local train = {}
    for _, l in ipairs(ENGINE) do train[#train + 1] = l end
    if o.l then train = { " _||__", "|_|__|", "(o)(o)" } end
    local tw = 0
    for _, l in ipairs(train) do tw = math.max(tw, #l) end
    local x = term.getSize() + 1
    local frame = 0
    cli.bg(colors.black)
    term.clear()
    while true do
      local w, h = term.getSize()
      if x < -tw then break end
      local th = #train + (o.l and 0 or 2)
      local y0 = math.max(1, math.floor((h - th) / 2) + 1)
      term.clear()
      if not o.l then
        local s = SMOKE[math.floor(frame / 2) % 2 + 1]
        cli.at(x + 1, y0, s[1], colors.lightGray)
        cli.at(x + 4, y0 + 1, s[2], colors.gray)
        y0 = y0 + 2
      end
      for i, l in ipairs(train) do
        if i == #train and not o.l then l = WHEELS[frame % 2 + 1] end
        cli.at(x, y0 + i - 1, l, i == #train and colors.lightGray or colors.white)
      end
      frame = frame + 1
      x = x - 1
      if not cli.sleep(0.06) then break end
      if w < 1 then break end
    end
    cli.restore()
  end,
}, ...)
