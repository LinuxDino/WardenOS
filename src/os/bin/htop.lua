-- htop: runs btop
local cli = dofile("/os/lib/cli.lua").init("htop", shell)
return cli.main({
  usage = "htop", about = "Live system monitor; the same as btop. q or Ctrl+T quits.", stop = true,
  run = function(_, args) return cli.run("/os/bin/btop.lua", table.unpack(args)) end,
}, ...)
