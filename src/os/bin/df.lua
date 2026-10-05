-- df: free space per drive, with a usage bar
local cli = dofile("/os/lib/cli.lua").init("df", shell)
return cli.main({
  usage = "df [-h] [path]",
  about = "Show size, used and free space of the computer's drives (the hard drive, disks in drives, "
    .. "and the read-only ROM), with a usage bar.",
  options = { "-h  human readable sizes (default here anyway); --help for this text", "-k  sizes in KB" },
  flags = { h = true, k = true }, long = { ["human-readable"] = "h" },
  run = function(o, args)
    local fmt = o.k and function(n) return tostring(math.ceil(n / 1024)) end or cli.human
    -- one row per drive: the root, then mounts like /disk
    local mounts = { { "/", "hdd" } }
    for _, n in ipairs(fs.list("/")) do
      local p = "/" .. n
      if fs.isDir(p) then
        local ok, d = pcall(fs.getDrive, p)
        if ok and d and d ~= "hdd" and n ~= "rom" then mounts[#mounts + 1] = { p, d } end
      end
    end
    if fs.exists("/rom") then mounts[#mounts + 1] = { "/rom", "rom" } end
    if args[1] then
      local p = cli.resolve(args[1])
      if not fs.exists(p) then cli.fail(args[1] .. ": No such file or directory") end
      local best = mounts[1]
      for _, m in ipairs(mounts) do
        if m[1] ~= "/" and (p == m[1] or p:sub(1, #m[1] + 1) == m[1] .. "/") then best = m end
      end
      mounts = { best }
    end
    local w = term.getSize()
    local wide = w >= 46
    if wide then cli.print(("%-10s %6s %6s %6s %4s  %s"):format("Drive", "Size", "Used", "Avail", "Use%", "Mounted on"), colors.cyan) end
    for _, m in ipairs(mounts) do
      local free = fs.getFreeSpace(m[1]) or 0
      local okc, cap = pcall(fs.getCapacity, m[1])
      cap = okc and tonumber(cap) or nil
      if m[2] == "rom" then cap = nil end
      local used = cap and math.max(0, cap - free) or nil
      local pct = cap and cap > 0 and math.floor(used / cap * 100 + 0.5) or nil
      local col = pct and (pct >= 90 and colors.red or pct >= 70 and colors.yellow or colors.green) or colors.lightGray
      if wide then
        cli.write(("%-10s %6s %6s %6s "):format(m[2]:sub(1, 10), cap and fmt(cap) or "-", used and fmt(used) or "-",
          m[2] == "rom" and "0" or fmt(free)), colors.white)
        cli.write(("%4s"):format(pct and (pct .. "%") or "-"), col)
        cli.print("  " .. m[1], colors.lightGray)
      else
        cli.write(m[2]:sub(1, 8) .. " ", colors.white)
        cli.print(m[1], colors.lightGray)
        if m[2] == "rom" then cli.print("  read-only", colors.lightGray)
        elseif cap then cli.print(("  %s of %s used"):format(fmt(used), fmt(cap)), colors.white)
        else cli.print(("  %s free"):format(fmt(free)), colors.white) end
      end
      if pct then
        local bw = math.max(4, math.min(w - 9, 40))
        local n = math.floor(bw * pct / 100 + 0.5)
        cli.write("  [", colors.gray)
        if cli.color then
          cli.write(string.rep("|", n), col)
          cli.write(string.rep(".", bw - n), colors.gray)
        else
          cli.write(string.rep("#", n) .. string.rep(".", bw - n))
        end
        cli.write("] ", colors.gray)
        cli.print(pct .. "%", col)
      end
    end
  end,
}, ...)
