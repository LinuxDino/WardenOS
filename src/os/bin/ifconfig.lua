-- ifconfig: network interfaces (modems)
local cli = dofile("/os/lib/cli.lua").init("ifconfig", shell)
local function call(n, m, ...)
  local ok, r = pcall(peripheral.call, n, m, ...)
  if ok then return r end
end
return cli.main({
  usage = "ifconfig [-a]",
  about = "Show this computer's network interfaces: every attached modem (wired or wireless), whether "
    .. "rednet is open on it, plus the computer ID that rednet uses as its address. Open a modem with "
    .. "the WardenOS desktop or rednet.open.",
  flags = { a = true },
  run = function()
    local id = os.getComputerID()
    local any = false
    cli.print("lo: <LOOPBACK,UP>", colors.cyan)
    cli.print(("    id #%d  label %s"):format(id, os.getComputerLabel() or "-"), colors.white)
    for _, n in ipairs(peripheral.getNames()) do
      if peripheral.getType(n) == "modem" then
        any = true
        local wireless = call(n, "isWireless")
        local open = rednet.isOpen(n)
        local kind = wireless == true and "wireless " or wireless == false and "wired " or ""
        if wireless == true and call(n, "isEnder") then kind = "ender " end
        cli.write(n .. ": ", colors.cyan)
        local wide = term.getSize() >= 32
        cli.print(("<%s>"):format(open and (wide and "UP,BROADCAST,RUNNING" or "UP") or "DOWN"),
          open and colors.green or colors.lightGray)
        cli.print(("    %smodem, rednet %s"):format(kind, open and "open" or "closed"), colors.white)
        local ch = {}
        for _, c in ipairs({ id, 65535, 65533 }) do
          if call(n, "isOpen", c) then ch[#ch + 1] = tostring(c) end
        end
        if #ch > 0 then cli.print("    channels " .. table.concat(ch, ", "), colors.lightGray) end
        if wireless == false then
          local remote = call(n, "getNamesRemote")
          if type(remote) == "table" then cli.print(("    %d peripherals on the network"):format(#remote), colors.lightGray) end
        end
      end
    end
    if not any then cli.print("no modems attached", colors.yellow) end
  end,
}, ...)
