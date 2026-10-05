-- printenv: same as env (printenv NAME prints one value)
local cli = dofile("/os/lib/cli.lua").init("printenv", shell)
return cli.exec("/os/bin/env.lua", _ENV, ...)
