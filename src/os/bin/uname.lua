-- uname: system information
local cli = dofile("/os/lib/cli.lua").init("uname", shell)
return cli.main({
  usage = "uname [-asnrvmo]",
  about = "Print system information. Without options: the system name.",
  options = { "-a  everything", "-s  system name", "-n  host name (label)", "-r  WardenOS version",
              "-v  CC: Tweaked version", "-m  device type", "-o  operating system" },
  flags = { a = true, s = true, n = true, r = true, v = true, m = true, o = true },
  long = { all = "a", ["kernel-name"] = "s", nodename = "n", ["kernel-release"] = "r", machine = "m" },
  run = function(o)
    local host = tostring(rawget(_G, "_HOST") or os.version())
    local cc = host:gsub("^ComputerCraft ", "")
    if o.a then
      cli.print(("WardenOS %s CC: Tweaked %s %s"):format(cli.version(), cc, cli.device()))
      return
    end
    local parts = {}
    if o.s or not (o.n or o.r or o.v or o.m or o.o) then parts[#parts + 1] = "WardenOS" end
    if o.n then parts[#parts + 1] = cli.hostname() end
    if o.r then parts[#parts + 1] = cli.version() end
    if o.v then parts[#parts + 1] = "CC: Tweaked " .. cc end
    if o.m then parts[#parts + 1] = cli.device() end
    if o.o then parts[#parts + 1] = os.version() end
    cli.print(table.concat(parts, " "))
  end,
}, ...)
