-- yes: print a line forever (until Ctrl+T or q)
local cli = dofile("/os/lib/cli.lua").init("yes", shell)
return cli.main({
  usage = "yes [text]",
  about = "Print \"y\" (or the text) over and over until Ctrl+T or q.",
  stop = true,
  run = function(_, args)
    local s = #args > 0 and table.concat(args, " ") or "y"
    repeat
      local _, h = term.getSize()
      for _ = 1, h do cli.print(s) end
    until not cli.sleep(0.05)
  end,
}, ...)
