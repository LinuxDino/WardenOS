-- free: memory and storage (CC has no RAM API; Lua heap and disk are shown instead)
local cli = dofile("/os/lib/cli.lua").init("free", shell)
return cli.main({
  usage = "free [-h] [-b]",
  about = "CC: Tweaked has no API for the computer's RAM, so free shows what can be measured: the Lua "
    .. "heap of this program's VM (collectgarbage) and the computer's storage. Sizes in KB.",
  options = { "-h  human readable; --help for this text", "-b  bytes" },
  flags = { h = true, b = true, k = true }, long = { human = "h", bytes = "b" },
  run = function(o)
    local fmt = o.h and cli.human or o.b and function(n) return tostring(math.floor(n)) end
      or function(n) return tostring(math.ceil(n / 1024)) end
    local heap = collectgarbage("count") * 1024
    local free = fs.getFreeSpace("/") or 0
    local okc, cap = pcall(fs.getCapacity, "/")
    cap = okc and tonumber(cap) or nil
    local w = term.getSize()
    local cw = w >= 36 and 9 or 6
    local function row(name, a, b, c, col)
      local cells = { a, b, c }
      cli.write(("%-6s"):format(name), col or colors.cyan)
      for _, v in ipairs(cells) do cli.write(("%" .. cw .. "s"):format(v), colors.white) end
      cli.print("")
    end
    row("", "total", "used", "free", colors.cyan)
    cli.fg(colors.cyan)
    row("Lua:", "-", fmt(heap), "-")
    row("Disk:", cap and fmt(cap) or "-", cap and fmt(cap - free) or "-", fmt(free))
    cli.print("RAM: n/a (no CC API)", colors.lightGray)
  end,
}, ...)
