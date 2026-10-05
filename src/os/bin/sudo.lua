-- sudo: there is no root on a CC computer, so sudo just runs the command (after the lecture)
local cli = dofile("/os/lib/cli.lua").init("sudo", shell)
local KEY = "WardenOS_sudo"                       -- per boot: lecture shown, last password time
return cli.main({
  usage = "sudo [-k] <command> [args...]",
  about = "Run a command as root. Every program already has full access on a CC computer, so this "
    .. "simply runs the command - after the usual lecture and a password prompt (any password works).",
  options = { "-k  forget the password (ask again next time)" },
  flags = { k = true }, long = { reset = "k" }, stop = true,
  run = function(o, args)
    local st = rawget(_G, KEY)
    if type(st) ~= "table" then st = {} rawset(_G, KEY, st) end
    if o.k then st.at = nil if #args == 0 then return end end
    if #args == 0 then cli.fail("usage: sudo <command> [args...]") end
    local line = table.concat(args, " ")
    if line == "make me a sandwich" then cli.print("Okay.", colors.white) return end
    if not st.at or os.clock() - st.at > 300 then
      if not st.lectured then
        st.lectured = true
        cli.print("")
        cli.print("We trust you have received the usual lecture from the local System Administrator. "
          .. "It usually boils down to these three things:", colors.white)
        cli.print("")
        cli.print("    #1) Respect the privacy of others.", colors.white)
        cli.print("    #2) Think before you type.", colors.white)
        cli.print("    #3) With great power comes great responsibility.", colors.white)
        cli.print("")
      end
      cli.write(("[sudo] password for %s: "):format(cli.user()), colors.white)
      read("*")
      st.at = os.clock()
    end
    return cli.run(table.unpack(args))
  end,
}, ...)
