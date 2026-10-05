-- more: same as less
local cli = dofile("/os/lib/cli.lua").init("more", shell)
return cli.exec("/os/bin/less.lua", _ENV, ...)
