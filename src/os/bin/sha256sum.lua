-- sha256sum: SHA-256 of files (or of a string with -s)
local cli = dofile("/os/lib/cli.lua").init("sha256sum", shell)
return cli.main({
  usage = "sha256sum [-s text] [file...]",
  about = "Print the SHA-256 checksum of each file, or of the text given with -s.",
  options = { "-s text  hash this text", "e.g. sha256sum /startup.lua" },
  flags = { s = "str" }, long = { string = "s" },
  run = function(o, args)
    local lib = cli.lib("/os/lib/sha256.lua")
    if not lib or not lib.sha256 then cli.fail("/os/lib/sha256.lua is missing") end
    if not o.s and #args == 0 then cli.fail("missing file operand (or -s text)") end
    local w = term.getSize()
    local function show(h, name)
      if 64 + 2 + #name > w then
        cli.print(h, colors.white)
        cli.print("  " .. name, colors.lightGray)
      else
        cli.write(h .. "  ", colors.white)
        cli.print(name, colors.lightGray)
      end
    end
    if o.s then show(lib.sha256(o.s), '"' .. o.s .. '"') end
    for _, a in ipairs(args) do
      local s, err = cli.readFile(a)
      if not s then cli.print("sha256sum: " .. err, colors.red)
      else show(lib.sha256(s), a) end
    end
  end,
}, ...)
