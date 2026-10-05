-- du: disk usage per directory
local cli = dofile("/os/lib/cli.lua").init("du", shell)
return cli.main({
  usage = "du [-h] [-s] [-a] [-d N] [path]...",
  about = "Show how much space each directory uses (all its files, recursively). Sizes are in KB "
    .. "unless -h is given.",
  options = { "-h    human readable (512, 1.5K, 2.0M); --help for this text", "-s    only a total for each path",
              "-a    list files too", "-d N  list directories at most N levels deep" },
  flags = { h = true, s = true, a = true, d = "num", H = true, k = true },
  long = { ["human-readable"] = "H", summarize = "s", all = "a", ["max-depth"] = "d" },
  run = function(o, args)
    local fmt = function(n) return (o.h or o.H) and cli.human(n) or tostring(math.ceil(n / 1024)) end
    if #args == 0 then args = { "." } end
    local function out(n, name)
      local s = fmt(n)
      cli.write(s .. string.rep(" ", math.max(1, 7 - #s)), colors.yellow)
      cli.print(name, colors.white)
    end
    local function size(path, shown, depth)
      cli.yield(200)
      if not fs.isDir(path) then
        local n = fs.getSize(path)
        if o.a and not o.s and depth > 0 and not (o.d and depth > o.d) then out(n, shown) end
        return n
      end
      local total = 0
      for _, f in ipairs(fs.list(path)) do
        total = total + size(fs.combine(path, f), cli.join(shown == "." and "./" or shown, f), depth + 1)
      end
      if not o.s and not (o.d and depth > o.d) then out(total, shown) end
      return total
    end
    for _, a in ipairs(args) do
      local p = cli.resolve(a)
      if not fs.exists(p) then cli.print("du: " .. a .. ": No such file or directory", colors.red)
      else
        local n = size(p, a, 0)
        if o.s or not fs.isDir(p) then out(n, a) end
      end
    end
  end,
}, ...)
