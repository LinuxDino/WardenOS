-- base64: encode / decode
local cli = dofile("/os/lib/cli.lua").init("base64", shell)
local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function enc(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    out[#out + 1] = A:sub(q[1] + 1, q[1] + 1) .. A:sub(q[2] + 1, q[2] + 1)
      .. (b and A:sub(q[3] + 1, q[3] + 1) or "=") .. (c and A:sub(q[4] + 1, q[4] + 1) or "=")
    if i % 3000 == 1 then cli.yield(20) end
  end
  return table.concat(out)
end
local function dec(s)
  s = s:gsub("[%s=]", "")
  if s:find("[^%w%+/]") then return nil end
  local out = {}
  for i = 1, #s, 4 do
    local n, k = 0, 0
    for j = i, math.min(i + 3, #s) do
      n = n * 64 + (A:find(s:sub(j, j), 1, true) - 1)
      k = k + 1
    end
    for _ = k + 1, 4 do n = n * 64 end
    local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    out[#out + 1] = bytes:sub(1, k - 1)
  end
  return table.concat(out)
end
return cli.main({
  usage = "base64 [-d] [-w cols] <file|text>",
  about = "Encode a file (or, if the argument is not a file, the text) to base64; -d decodes.",
  options = { "-d       decode", "-w cols  wrap lines at cols (default: screen width, 0 = no wrap)",
              "e.g. base64 hello, base64 -d aGVsbG8=" },
  flags = { d = true, w = "num", i = true }, long = { decode = "d", wrap = "w" },
  run = function(o, args)
    local files, text = cli.filesOrText(args)
    if not files and not text then cli.fail("usage: base64 [-d] <file|text>") end
    local data = text or ""
    if files then
      local parts = {}
      for _, f in ipairs(files) do parts[#parts + 1] = cli.readFile(f) end
      data = table.concat(parts)
    end
    if o.d then
      local r = dec(data)
      if not r then cli.fail("invalid input") end
      cli.write(r)
      if r:sub(-1) ~= "\n" then cli.print("") end
      return
    end
    local s = enc(data)
    local w = o.w or term.getSize()
    if w <= 0 then cli.print(s) return end
    for i = 1, #s, w do cli.print(s:sub(i, i + w - 1)) end
  end,
}, ...)
