-- ping: rednet ping to a WardenOS computer, pocket or drone (protocol "wardenos")
local cli = dofile("/os/lib/cli.lua").init("ping", shell)
local PROTO = "wardenos"

local function openModem()
  if rednet.isOpen() then return true end
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then pcall(rednet.open, n) end
  end
  return rednet.isOpen()
end
local function now()
  local ok, t = pcall(os.epoch, "utc")
  return ok and tonumber(t) or os.clock() * 1000
end

return cli.main({
  usage = "ping [-c N] [-W secs] <id|label>",
  about = "Send WardenOS pings over rednet and print each reply with its round-trip time, like "
    .. "Linux ping. A label is looked up among the drones the desktop knows, or by asking everyone. "
    .. "Runs until Ctrl+T or q unless -c is given.",
  options = { "-c N     stop after N pings", "-W secs  how long to wait for each reply (default 2)",
              "-i secs  time between pings (default 1)" },
  flags = { c = "num", W = "num", i = "num" }, long = { count = "c", timeout = "W", interval = "i" },
  run = function(o, args)
    local target = args[1]
    if not target then cli.fail("usage: ping <id|label>") end
    if not openModem() then cli.fail("no modem attached (rednet needs one)") end
    local wait, every = math.max(0.1, o.W or 2), math.max(0.2, o.i or 1)
    local id = tonumber(target)
    local label
    if not id then
      local W = rawget(_G, "WardenOS")
      if type(W) == "table" and type(W.drones) == "table" then
        for k, d in pairs(W.drones) do
          if type(d) == "table" and d.label == target then id = k break end
        end
      end
    end
    if not id then
      -- ask everyone and take the first status whose label matches
      cli.print("resolving " .. target .. "...", colors.lightGray)
      rednet.broadcast({ t = "ping" }, PROTO)
      local t = os.startTimer(wait)
      while not id do
        local e, a, b, c = os.pullEventRaw()
        if e == "terminate" or (e == "char" and a == "q") then return false end
        if e == "timer" and a == t then break end
        if e == "rednet_message" and c == PROTO and type(b) == "table" and b.t == "status" and b.label == target then
          id = a
        end
      end
      if not id then cli.fail(target .. ": Name or service not known") end
    end
    if id == os.getComputerID() then label = cli.hostname() end
    label = label or target
    cli.print(("PING %s (#%d) over rednet \"%s\""):format(label, id, PROTO), colors.white)
    local sent, got, times = 0, 0, {}
    local quit = false
    while not quit and (not o.c or sent < o.c) do
      sent = sent + 1
      local t0 = now()
      rednet.send(id, { t = "ping" }, PROTO)
      local t = os.startTimer(wait)
      local replied = false
      while true do
        local e, a, b, c = os.pullEventRaw()
        if e == "terminate" or (e == "char" and (a == "q" or a == "Q")) then quit = true break end
        if e == "timer" and a == t then break end
        if e == "rednet_message" and a == id and c == PROTO and type(b) == "table" and b.t == "status" then
          local ms = math.max(0, now() - t0)
          got = got + 1
          times[#times + 1] = ms
          if type(b.label) == "string" and b.label ~= "" then label = b.label end
          local bytes = #textutils.serialize(b)
          cli.write(("%d bytes from #%d"):format(bytes, id), colors.white)
          if label ~= tostring(id) then cli.write(" (" .. label .. ")", colors.cyan) end
          cli.write((": seq=%d"):format(sent), colors.white)
          if b.kind then cli.write(" " .. tostring(b.kind), colors.lightGray) end
          cli.print((" time=%d ms"):format(ms), colors.green)
          replied = true
          break
        end
      end
      if quit then break end
      if not replied then cli.print(("Request timeout for seq %d"):format(sent), colors.yellow) end
      if o.c and sent >= o.c then break end
      if replied and not cli.sleep(every) then quit = true end
    end
    cli.print(("--- %s ping statistics ---"):format(label), colors.white)
    local loss = sent > 0 and math.floor((sent - got) / sent * 100 + 0.5) or 0
    cli.print(("%d sent, %d received, %d%% loss"):format(sent, got, loss), loss > 0 and colors.yellow or colors.green)
    if #times > 0 then
      local mn, mx, sum = math.huge, 0, 0
      for _, v in ipairs(times) do mn, mx, sum = math.min(mn, v), math.max(mx, v), sum + v end
      cli.print(("rtt min/avg/max = %d/%d/%d ms"):format(mn, math.floor(sum / #times + 0.5), mx), colors.lightGray)
    end
    return got > 0
  end,
}, ...)
