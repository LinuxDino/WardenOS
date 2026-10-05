-- ps: what is running. CC can't list coroutines, so this shows what it can see: the BIOS, the WardenOS
-- desktop and its windows (when the kernel shares them), multishell tabs and the shell running ps.
local cli = dofile("/os/lib/cli.lua").init("ps", shell)
return cli.main({
  usage = "ps [-a]",
  about = "List running programs. CraftOS does not expose its coroutines, so ps shows what can be "
    .. "seen: the BIOS, the WardenOS desktop and its open windows (if the desktop shares them), "
    .. "multishell tabs, and this shell's program.",
  options = { "-a  also list the installed desktop apps" },
  flags = { a = true, e = true, x = true, u = true },
  run = function(o)
    local rows = {}
    local function add(cmd, info) rows[#rows + 1] = { cmd, info or "" } end
    add("bios", "CraftOS")
    if fs.exists("/startup.lua") then add("/startup.lua", "boot") end
    local W = rawget(_G, "WardenOS")
    if type(W) == "table" then
      add("kernel", "WardenOS " .. tostring(W.version or "") .. (W.user and (" user " .. tostring(W.user)) or ""))
      local wins = W.windows or W.wins or W.running or W.tasks
      if type(wins) == "table" then
        for _, w in ipairs(wins) do
          if type(w) == "table" then add("  " .. tostring(w.title or w.app or w.name or "?"), w.min and "minimized" or "window")
          else add("  " .. tostring(w), "window") end
        end
      end
      if (o.a or o.e or o.x) and type(W.apps) == "table" then
        for _, id in ipairs(W.apps) do
          add("  [" .. tostring(id) .. "]", (type(W.appNames) == "table" and W.appNames[id]) or "app")
        end
      end
    end
    if multishell and multishell.getCount then
      local cur = multishell.getCurrent and multishell.getCurrent()
      for i = 1, multishell.getCount() do
        add("multishell:" .. i, tostring(multishell.getTitle(i) or "") .. (i == cur and " *" or ""))
      end
    end
    add("shell", "/rom/programs/shell.lua")
    local me = shell and shell.getRunningProgram and shell.getRunningProgram() or "ps"
    add("  " .. fs.getName(me):gsub("%.lua$", ""), "/" .. fs.combine(me, ""))
    local w = term.getSize()
    cli.print(("%4s %s"):format("PID", "CMD"), colors.cyan)
    for i, r in ipairs(rows) do
      cli.write(("%4d "):format(i), colors.lightGray)
      local cmd = r[1]
      cli.write(cmd, colors.white)
      local rest = w - 5 - #cmd - 1
      if rest > 3 and r[2] ~= "" then cli.write(" " .. r[2]:sub(1, rest), colors.gray) end
      cli.print("")
    end
  end,
}, ...)
