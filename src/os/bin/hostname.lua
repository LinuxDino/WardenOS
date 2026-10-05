-- hostname: show or set the computer label
local cli = dofile("/os/lib/cli.lua").init("hostname", shell)
return cli.main({
  usage = "hostname [-i] [name]",
  about = "Print the computer's label (its host name), or set it to name. Like the CraftOS label program.",
  options = { "-i  print the computer ID" },
  flags = { i = true }, long = { ["ip-address"] = "i" },
  run = function(o, args)
    if o.i then cli.print(tostring(os.getComputerID())) return end
    if args[1] then
      local name = table.concat(args, " ")
      if #name > 32 then cli.fail("name too long (max 32 characters)") end
      os.setComputerLabel(name)
      return
    end
    cli.print(cli.hostname())
  end,
}, ...)
