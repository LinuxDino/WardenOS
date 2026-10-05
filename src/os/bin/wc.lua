-- wc: count lines, words and bytes
local cli = dofile("/os/lib/cli.lua").init("wc", shell)
return cli.main({
  usage = "wc [-lwc] <file>...",
  about = "Print line, word and byte counts for each file (and a total for several files).",
  options = { "-l  lines only", "-w  words only", "-c  bytes only" },
  flags = { l = true, w = true, c = true, m = true }, long = { lines = "l", words = "w", bytes = "c", chars = "m" },
  run = function(o, args)
    if #args == 0 then cli.fail("missing file operand (try: wc <file>)") end
    o.c = o.c or o.m
    local all = not (o.l or o.w or o.c)
    local rows, tot = {}, { 0, 0, 0 }
    for _, a in ipairs(args) do
      local s, err = cli.readFile(a)
      if not s then cli.print("wc: " .. err, colors.red)
      else
        local _, lines = s:gsub("\n", "")
        local words = 0
        for _ in s:gmatch("%S+") do words = words + 1 end
        rows[#rows + 1] = { lines, words, #s, a }
        tot[1], tot[2], tot[3] = tot[1] + lines, tot[2] + words, tot[3] + #s
      end
    end
    if #rows > 1 then rows[#rows + 1] = { tot[1], tot[2], tot[3], "total" } end
    local width = 1
    for _, r in ipairs(rows) do for k = 1, 3 do width = math.max(width, #tostring(r[k])) end end
    for _, r in ipairs(rows) do
      local cols = {}
      if all or o.l then cols[#cols + 1] = ("%" .. width .. "d"):format(r[1]) end
      if all or o.w then cols[#cols + 1] = ("%" .. width .. "d"):format(r[2]) end
      if all or o.c then cols[#cols + 1] = ("%" .. width .. "d"):format(r[3]) end
      cli.write(table.concat(cols, " ") .. " ", colors.white)
      cli.print(r[4], r[4] == "total" and colors.yellow or colors.lightGray)
    end
  end,
}, ...)
