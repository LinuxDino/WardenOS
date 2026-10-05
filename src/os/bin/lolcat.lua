-- lolcat: rainbow text
local cli = dofile("/os/lib/cli.lua").init("lolcat", shell)
local RAINBOW = { colors.red, colors.orange, colors.yellow, colors.lime, colors.green, colors.cyan,
                  colors.lightBlue, colors.blue, colors.purple, colors.magenta, colors.pink }
return cli.main({
  usage = "lolcat [-s spread] <file...|text>",
  about = "Print files (or the text) in rainbow colors.",
  options = { "-s n  how many characters per color (default 2)", "e.g. lolcat /os/man/lolcat.txt" },
  flags = { s = "num", p = "num" }, long = { spread = "s" }, stop = true,
  run = function(o, args)
    local files, text = cli.filesOrText(args)
    if not files and not text then cli.fail("usage: lolcat <file...|text>") end
    local lines = {}
    if text then lines = { text } else
      for _, f in ipairs(files) do for _, l in ipairs(cli.splitLines(cli.readFile(f))) do lines[#lines + 1] = l end end
    end
    local spread = math.max(1, o.s or o.p or 2)
    local seed = math.random(0, #RAINBOW - 1)
    for i, l in ipairs(lines) do
      if not cli.color then cli.print(l) else
        local pos = 1
        while pos <= #l do
          local c = RAINBOW[(seed + i + math.floor((pos - 1) / spread)) % #RAINBOW + 1]
          cli.write(l:sub(pos, pos + spread - 1), c)
          pos = pos + spread
        end
        cli.print("")
      end
      cli.yield(300)
    end
    cli.fg(colors.white)
  end,
}, ...)
