-- man: manual pages (/os/man/<cmd>.txt), CraftOS help topics, or a command's --help
local cli = dofile("/os/lib/cli.lua").init("man", shell)
return cli.main({
  usage = "man [-k] <command>",
  about = "Show the manual page for a command. Pages live in /os/man/<command>.txt; for CraftOS "
    .. "programs the built-in help topic is shown; otherwise the command's --help. Long pages open in a "
    .. "pager: arrows/space to scroll, q to quit.",
  options = { "-k  list the commands with a manual page", "e.g. man grep, man man" },
  flags = { k = true, l = true }, long = { apropos = "k", list = "l" },
  run = function(o, args)
    if o.k or o.l then
      local list = fs.isDir("/os/man") and fs.list("/os/man") or {}
      local pat = args[1] and args[1]:lower()
      for _, f in ipairs(list) do
        local name = f:gsub("%.txt$", "")
        local h = fs.open("/os/man/" .. f, "r")
        local src = h and h.readAll() or ""
        if h then h.close() end
        local what = src:match("NAME%s*\n%s*(.-)\n") or name
        if not pat or what:lower():find(pat, 1, true) then
          cli.print(what, colors.white)
        end
      end
      return
    end
    local name = args[1]
    if not name then cli.fail("What manual page do you want? (try: man man)") end
    name = name:gsub("%.lua$", "")
    local text
    local p = "/os/man/" .. name .. ".txt"
    if fs.exists(p) then
      local h = fs.open(p, "r")
      text = h.readAll()
      h.close()
    elseif rawget(_G, "help") and help.lookup and help.lookup(name) then
      local h = fs.open(help.lookup(name), "r")
      if h then text = "NAME\n  " .. name .. " (CraftOS)\n\nDESCRIPTION\n" .. h.readAll() h.close() end
    end
    if not text then
      local prog = shell and shell.resolveProgram and shell.resolveProgram(name)
      if prog then return cli.run(name, "--help") end
      cli.fail("No manual entry for " .. name)
    end
    local w, h = term.getSize()
    local lines = {}
    for _, raw in ipairs(cli.splitLines(text)) do
      local head = raw:match("^%u[%u%s]+$")
      for _, l in ipairs(cli.wrap(raw, w)) do
        lines[#lines + 1] = { l, head and colors.yellow or (l:match("^%s*%-") and colors.cyan or colors.white) }
      end
    end
    if #lines < h then
      for _, l in ipairs(lines) do cli.print(l[1], l[2]) end
    else
      cli.pager(lines, name .. "(1)")
    end
  end,
}, ...)
