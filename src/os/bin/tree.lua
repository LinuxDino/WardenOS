-- tree: directory tree, directories first
local cli = dofile("/os/lib/cli.lua").init("tree", shell)
return cli.main({
  usage = "tree [-L depth] [-a] [-d] [dir]",
  about = "List a directory and everything below it as a tree. Directories come first; colors: "
    .. "directories blue, programs green, read-only gray.",
  options = { "-L N  descend at most N levels", "-a    show hidden files (.name)", "-d    directories only" },
  flags = { L = "num", a = true, d = true }, long = { level = "L", all = "a" },
  run = function(o, args)
    local root = args[1] or "."
    local path = cli.resolve(root)
    if not fs.exists(path) then cli.fail(root .. ": No such file or directory") end
    local dirs, files = 0, 0
    local function color(p, isDir)
      if isDir then return colors.blue end
      if fs.isReadOnly(p) then return colors.lightGray end
      if p:sub(-4) == ".lua" then return colors.green end
      return colors.white
    end
    cli.print(root, colors.blue)
    local function walk(dir, prefix, depth)
      if o.L and depth > o.L then return end
      local ok, list = pcall(fs.list, dir)
      if not ok then return end
      local ds, fl = {}, {}
      for _, n in ipairs(list) do
        if o.a or n:sub(1, 1) ~= "." then
          if fs.isDir(fs.combine(dir, n)) then ds[#ds + 1] = n elseif not o.d then fl[#fl + 1] = n end
        end
      end
      table.sort(ds) table.sort(fl)
      local all = {}
      for _, n in ipairs(ds) do all[#all + 1] = { n, true } end
      for _, n in ipairs(fl) do all[#all + 1] = { n, false } end
      for i, e in ipairs(all) do
        cli.yield(200)
        local last = i == #all
        local p = "/" .. fs.combine(dir, e[1])
        cli.write(prefix .. (last and "`-- " or "|-- "), colors.gray)
        cli.print(e[1], color(p, e[2]))
        if e[2] then
          dirs = dirs + 1
          walk(p, prefix .. (last and "    " or "|   "), depth + 1)
        else
          files = files + 1
        end
      end
    end
    if fs.isDir(path) then walk(path, "", 1) end
    cli.print("")
    cli.print(("%d director%s%s"):format(dirs, dirs == 1 and "y" or "ies",
      o.d and "" or (", %d file%s"):format(files, files == 1 and "" or "s")), colors.lightGray)
  end,
}, ...)
