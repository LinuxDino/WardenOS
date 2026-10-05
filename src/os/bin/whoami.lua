-- whoami: the logged-in WardenOS user (or the computer label)
local cli = dofile("/os/lib/cli.lua").init("whoami", shell)
return cli.main({
  usage = "whoami",
  about = "Print the user logged in to the WardenOS desktop; outside the desktop, the computer's label.",
  run = function() cli.print(cli.user()) end,
}, ...)
