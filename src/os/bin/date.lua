-- date: real-world date/time (os.date formats) and the Minecraft time
local cli = dofile("/os/lib/cli.lua").init("date", shell)
return cli.main({
  usage = "date [-u] [-m] [+FORMAT]",
  about = "Print the real-world date and time, then the Minecraft day and time. +FORMAT uses os.date "
    .. "codes: %Y year, %m month, %d day, %H:%M:%S time, %A weekday, %B month name, %s epoch seconds.",
  options = { "-u  UTC", "-m  Minecraft time only", "e.g. date +%Y-%m-%d" },
  flags = { u = true, m = true }, long = { utc = "u", minecraft = "m" },
  run = function(o, args)
    local function mc()
      local t = os.time()
      local ok, s = pcall(textutils.formatTime, t, true)
      return ("Minecraft day %d, %s"):format(os.day(), ok and s or ("%.2f"):format(t))
    end
    if o.m then cli.print(mc(), colors.green) return end
    local secs
    local ok, ms = pcall(os.epoch, o.u and "utc" or "local")
    if ok and tonumber(ms) then secs = math.floor(ms / 1000) end
    local fmt = args[1]
    if fmt and fmt:sub(1, 1) ~= "+" then cli.fail("invalid date '" .. fmt .. "' (formats start with +)") end
    -- os.epoch("local") is already shifted to local time, so format it as UTC ("!")
    local function d(f)
      if f:find("%%s") then f = f:gsub("%%s", tostring(secs or os.time())) end
      if secs then return os.date("!" .. f, secs) end
      return os.date(f)
    end
    if fmt then
      local okf, s = pcall(d, fmt:sub(2))
      if not okf then cli.fail("bad format: " .. fmt) end
      cli.print(s)
      return
    end
    cli.print(d("%a %b %d %H:%M:%S ") .. (o.u and "UTC " or "") .. d("%Y"), colors.white)
    cli.print(mc(), colors.green)
  end,
}, ...)
