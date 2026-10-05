-- seq: print a sequence of numbers
local cli = dofile("/os/lib/cli.lua").init("seq", shell)
return cli.main({
  usage = "seq [-s sep] [-w] [first [step]] last",
  about = "Print numbers from first (default 1) to last, counting by step (default 1).",
  options = { "-s sep  separator instead of a new line", "-w      pad with zeros to equal width",
              "e.g. seq 5, seq 2 10, seq 10 -2 0" },
  flags = { s = "str", w = true }, long = { separator = "s", ["equal-width"] = "w" }, numbers = true,
  run = function(o, args)
    local n = {}
    for i, a in ipairs(args) do
      n[i] = tonumber(a)
      if not n[i] then cli.fail("invalid number '" .. a .. "'") end
    end
    local first, step, last
    if #n == 1 then first, step, last = 1, 1, n[1]
    elseif #n == 2 then first, step, last = n[1], 1, n[2]
    elseif #n == 3 then first, step, last = n[1], n[2], n[3]
    else cli.fail("usage: seq [first [step]] last") end
    if step == 0 then cli.fail("step must not be zero") end
    if math.abs((last - first) / step) > 100000 then cli.fail("too many numbers (max 100000)") end
    local dec = 0
    for _, a in ipairs(args) do local d = a:match("%.(%d+)$") if d then dec = math.max(dec, #d) end end
    local fmt = dec > 0 and ("%." .. dec .. "f") or "%d"
    local width = 0
    if o.w then width = math.max(#fmt:format(first), #fmt:format(last)) end
    local out = {}
    local i = 0
    while true do
      local v = first + i * step
      if (step > 0 and v > last + 1e-9) or (step < 0 and v < last - 1e-9) then break end
      local s = fmt:format(dec > 0 and v or math.floor(v + 0.5))
      if width > 0 and #s < width then
        s = (s:sub(1, 1) == "-" and "-" .. string.rep("0", width - #s) .. s:sub(2)) or (string.rep("0", width - #s) .. s)
      end
      if o.s then out[#out + 1] = s else cli.print(s) cli.yield(500) end
      i = i + 1
    end
    if o.s then cli.print(table.concat(out, o.s)) end
  end,
}, ...)
