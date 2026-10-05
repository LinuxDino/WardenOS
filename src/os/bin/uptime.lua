-- uptime: how long this computer has been running
local cli = dofile("/os/lib/cli.lua").init("uptime", shell)
local function plural(n, w) return n .. " " .. w .. (n == 1 and "" or "s") end
return cli.main({
  usage = "uptime [-p] [-s]",
  about = "Show the time, how long the computer has been on, users, and the load (events per minute, "
    .. "from the WardenOS log when it is running).",
  options = { "-p  pretty: up 1 hour, 2 minutes", "-s  when the computer started (seconds ago)" },
  flags = { p = true, s = true }, long = { pretty = "p", since = "s" },
  run = function(o)
    local s = math.floor(os.clock())
    local d, h, m = math.floor(s / 86400), math.floor(s / 3600) % 24, math.floor(s / 60) % 60
    if o.s then cli.print(("started %d seconds ago"):format(s)) return end
    if o.p then
      local parts = {}
      if d > 0 then parts[#parts + 1] = plural(d, "day") end
      if h > 0 then parts[#parts + 1] = plural(h, "hour") end
      parts[#parts + 1] = plural(m, "minute")
      cli.print("up " .. table.concat(parts, ", "))
      return
    end
    local up = (d > 0 and (d .. "d ") or "") .. ("%dh %02dm"):format(h, m)
    local users = rawget(_G, "WardenOS") and rawget(_G, "WardenOS").user and 1 or 0
    local load = ""
    local log = rawget(_G, "WardenLog")
    if type(log) == "table" and log.count then
      local ok, total, rate = pcall(log.count)
      if ok and tonumber(rate) then
        local rn = 0
        if log.rate then local ok2, r = pcall(log.rate, "rednet") if ok2 then rn = tonumber(r) or 0 end end
        load = (", load: %d ev/min, %d rednet/min"):format(rate, rn)
      end
    end
    cli.write(os.date("%H:%M:%S") .. " ", colors.white)
    cli.write("up " .. up, colors.green)
    cli.print((", %d user%s"):format(users, users == 1 and "" or "s") .. load, colors.white)
  end,
}, ...)
