-- touch: create empty files (or update a file's modification time)
local cli = dofile("/os/lib/cli.lua").init("touch", shell)
return cli.main({
  usage = "touch <file>...",
  about = "Create each file if it does not exist; otherwise update its modification time. "
    .. "Contents are never changed.",
  flags = { c = true }, long = { ["no-create"] = "c" },
  options = { "-c  do not create files that don't exist" },
  run = function(o, args)
    if #args == 0 then cli.fail("missing file operand") end
    for _, a in ipairs(args) do
      local p = cli.resolve(a)
      if fs.isDir(p) then
        -- nothing to do for directories
      elseif fs.isReadOnly(p) then
        cli.print("touch: " .. a .. ": Read-only file system", colors.red)
      elseif fs.exists(p) or not o.c then
        local dir = fs.getDir(p)
        if dir ~= "" and not fs.isDir(dir) then
          cli.print("touch: " .. a .. ": No such directory", colors.red)
        else
          local f = fs.open(p, "a")
          if f then f.close() else cli.print("touch: cannot touch " .. a, colors.red) end
        end
      end
    end
  end,
}, ...)
