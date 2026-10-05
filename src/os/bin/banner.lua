-- banner: big letters made of # (figlet -t)
local cli = dofile("/os/lib/cli.lua").init("banner", shell)
return cli.exec("/os/bin/figlet.lua", setmetatable({ FIGLET_NAME = "banner" }, { __index = _ENV }), "-t", ...)
