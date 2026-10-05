-- env / printenv: the shell's "environment" (path, directory, user, ...) and CC settings
local cli = dofile("/os/lib/cli.lua").init("env", shell)
local function vars()
  local w, h = term.getSize()
  local list = {
    { "HOME", "/" },
    { "HOSTNAME", cli.hostname() },
    { "PATH", shell and shell.path and shell.path() or "" },
    { "PWD", "/" .. fs.combine(shell and shell.dir and shell.dir() or "", "") },
    { "SHELL", "/rom/programs/shell.lua" },
    { "TERM", ("craftos-%dx%d%s"):format(w, h, term.isColour() and "-color" or "") },
    { "USER", cli.user() },
    { "WARDENOS_VERSION", cli.version() },
  }
  if rawget(_G, "settings") and settings.getNames then
    for _, n in ipairs(settings.getNames()) do
      local v = settings.get(n)
      if type(v) == "table" then v = textutils.serialize(v):gsub("%s+", " ") end
      list[#list + 1] = { n, tostring(v) }
    end
  end
  return list
end
return cli.main({
  usage = "env | printenv [name]",
  about = "Print the environment: a few shell values (PATH, PWD, USER, ...) and every CC setting "
    .. "(change them with the CraftOS set program). With a name, print only its value.",
  run = function(_, args)
    local list = vars()
    if args[1] then
      for _, kv in ipairs(list) do if kv[1] == args[1] then cli.print(kv[2]) return true end end
      return false
    end
    for _, kv in ipairs(list) do
      cli.write(kv[1], colors.cyan)
      cli.write("=", colors.lightGray)
      cli.print(kv[2], colors.white)
    end
  end,
}, ...)
