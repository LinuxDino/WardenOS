-- factor: prime factors
local cli = dofile("/os/lib/cli.lua").init("factor", shell)
return cli.main({
  usage = "factor <number>...",
  about = "Print the prime factors of each whole number (up to 2^53).",
  numbers = true,
  run = function(_, args)
    if #args == 0 then cli.fail("missing number") end
    for _, a in ipairs(args) do
      local n = tonumber(a)
      if not n or n ~= math.floor(n) or n < 0 or n > 2 ^ 53 then
        cli.print("factor: '" .. a .. "' is not a valid positive integer", colors.red)
      else
        local out = {}
        local d = 2
        while n > 1 and d * d <= n do
          while n % d == 0 do out[#out + 1] = ("%d"):format(d) n = n / d end
          d = d + (d == 2 and 1 or 2)
          if d % 20001 == 0 then cli.yield(1) end
        end
        if n > 1 then out[#out + 1] = ("%d"):format(n) end
        cli.write(("%d:"):format(tonumber(a)), colors.cyan)
        cli.print((#out > 0 and " " or "") .. table.concat(out, " "), colors.white)
      end
    end
  end,
}, ...)
