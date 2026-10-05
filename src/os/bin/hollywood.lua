-- hollywood: look very busy. q or Ctrl+T quits.
local cli = dofile("/os/lib/cli.lua").init("hollywood", shell)
local TASKS = { "Decrypting mainframe", "Bypassing firewall", "Rerouting rednet", "Compiling exploits",
  "Tracing sculk signal", "Downloading diamonds", "Cracking chest lock", "Injecting turtle firmware",
  "Hacking the Ender Dragon", "Reticulating splines", "Spoofing GPS", "Overclocking redstone" }
local WORDS = { "ACCESS GRANTED", "UPLINK ESTABLISHED", "ENCRYPTION BROKEN", "PROXY CHAIN OK", "ROOT SHELL",
  "TRACE EVADED", "PAYLOAD DELIVERED" }
local function hex(n) local t = {} for i = 1, n do t[i] = ("%02x"):format(math.random(0, 255)) end return table.concat(t, " ") end
return cli.main({
  usage = "hollywood",
  about = "Fill the screen with very important looking hacker stuff: hex dumps, progress bars and "
    .. "dramatic messages. q or Ctrl+T quits.",
  run = function()
    local w, h = term.getSize()
    local lines = {}
    local bars = {}
    local function add(s, col) lines[#lines + 1] = { s, col } if #lines > 200 then table.remove(lines, 1) end end
    local function newBar() return { name = TASKS[math.random(1, #TASKS)], p = 0, speed = math.random(2, 9) } end
    local tick = 0
    cli.bg(colors.black)
    term.clear()
    while true do
      tick = tick + 1
      if cli.resized then cli.resized = false w, h = term.getSize() end
      local nb = h >= 12 and 3 or (h >= 8 and 2 or 1)
      for i = 1, nb do bars[i] = bars[i] or newBar() end
      -- new log output
      for _ = 1, math.random(1, 3) do
        local r = math.random(1, 10)
        if r <= 5 then
          add(("%04x  %s"):format(math.random(0, 65535), hex(math.max(1, math.floor((w - 6) / 3)))), colors.green)
        elseif r <= 8 then
          add(("[ %s ] %s %s"):format(math.random(1, 9) == 1 and "FAIL" or " OK ", TASKS[math.random(1, #TASKS)]:lower(),
            ("0x%04x%04x"):format(math.random(0, 65535), math.random(0, 65535))), colors.lime)
        else
          add(">> " .. WORDS[math.random(1, #WORDS)] .. " <<", colors.red)
        end
      end
      term.clear()
      local logH = h - nb * 2
      for i = 1, logH do
        local l = lines[#lines - logH + i]
        if l then cli.at(1, i, l[1], l[2]) end
      end
      for i = 1, nb do
        local b = bars[i]
        b.p = math.min(100, b.p + b.speed)
        local y = logH + (i - 1) * 2 + 1
        cli.at(1, y, (b.name .. "..."):sub(1, w), colors.cyan)
        local bw = math.max(3, w - 7)
        local n = math.floor(bw * b.p / 100)
        cli.at(1, y + 1, "[" .. string.rep("#", n) .. string.rep(".", bw - n) .. "]", colors.green)
        cli.at(bw + 3, y + 1, ("%3d%%"):format(b.p), colors.white)
        if b.p >= 100 then add(b.name .. ": DONE", colors.yellow) bars[i] = newBar() end
      end
      if not cli.sleep(0.12) then break end
    end
    cli.restore()
  end,
}, ...)
