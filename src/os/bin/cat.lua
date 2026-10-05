-- cat: print files
local cli = dofile("/os/lib/cli.lua").init("cat", shell)
return cli.main({
  usage = "cat [-n] <file>...",
  about = "Print files to the screen, one after another.",
  options = { "-n  number all output lines", "-b  number non-empty lines" },
  flags = { n = true, b = true }, long = { number = "n", ["number-nonblank"] = "b" },
  run = function(o, args)
    if #args == 0 then cli.fail("missing file operand (CC has no stdin; try: cat <file>)") end
    local n, bad = 0, false
    for _, a in ipairs(args) do
      local s, err = cli.readFile(a)
      if not s then
        cli.print("cat: " .. err, colors.red)
        bad = true
      else
        for _, l in ipairs(cli.splitLines(s)) do
          if (o.n or o.b) and not (o.b and l == "") then
            n = n + 1
            cli.write(("%6d  "):format(n), colors.lightGray)
          end
          cli.print(l, colors.white)
          cli.yield(400)
        end
      end
    end
    return not bad
  end,
}, ...)
