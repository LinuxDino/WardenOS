-- vi: same as vim
local cli = dofile("/os/lib/cli.lua").init("vi", shell)
return cli.exec("/os/bin/vim.lua", _ENV, ...)
