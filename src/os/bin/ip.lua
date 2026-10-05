-- ip: interfaces, the iproute2 way (ip a)
local cli = dofile("/os/lib/cli.lua").init("ip", shell)
local function call(n, m, ...)
  local ok, r = pcall(peripheral.call, n, m, ...)
  if ok then return r end
end
return cli.main({
  usage = "ip [a|addr|link|route]",
  about = "Show the network interfaces (modems) in the style of Linux ip. The address of a "
    .. "computer on rednet is its computer ID.",
  run = function(_, args)
    local what = args[1] or "a"
    local id = os.getComputerID()
    if what == "r" or what == "route" then
      local any = false
      for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" and rednet.isOpen(n) then
          cli.print("default via rednet dev " .. n, colors.white)
          any = true
        end
      end
      if not any then cli.print("no route (no modem open)", colors.yellow) end
      return
    end
    if not ({ a = 1, addr = 1, address = 1, l = 1, link = 1, show = 1 })[what] then
      cli.fail("unknown object '" .. what .. "' (try: ip a)")
    end
    local i = 1
    cli.write(i .. ": ", colors.lightGray) cli.print("lo: <LOOPBACK,UP>", colors.cyan)
    if what ~= "l" and what ~= "link" then cli.print("    inet #" .. id .. "/local", colors.white) end
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "modem" then
        i = i + 1
        local open = rednet.isOpen(n)
        local wl = call(n, "isWireless")
        cli.write(i .. ": ", colors.lightGray)
        cli.print(("%s: <%s>%s"):format(n, open and "BROADCAST,UP" or "DOWN",
          wl == true and " wireless" or wl == false and " wired" or ""), open and colors.cyan or colors.lightGray)
        if what ~= "l" and what ~= "link" and open then
          cli.print(("    inet #%d rednet %s"):format(id, os.getComputerLabel() or ""), colors.white)
        end
      end
    end
  end,
}, ...)
