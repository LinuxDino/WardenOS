-- WardenOS Pocket server: lets paired WardenOS Pocket computers use this computer over rednet ("wardenos").
-- Loaded once by the kernel, which calls:
--   M.event(ev)      with every event (except "terminate"); true = the pairing prompt changed (redraw)
--   M.prompt()       the pairing request to show ({ id = pocketId }) or nil
--   M.decide(allow)  the player's answer to that prompt
-- Nothing here blocks: drone commands are relayed with a table of pending relays + timers, and the
-- pocket's Claude conversation runs as a coroutine (/os/pocket/claudecore.lua) resumed from M.event.
--
-- Pocket -> server: pocket_pair, pocket_unpair, pocket_drones, pocket_cmd {drone, cmd, arg, seq},
--                   pocket_claude {op = send (text) | decision (choice) | new | poll}
-- Server -> pocket: pocket_paired {ok}, pocket_unpaired, pocket_drones {drones}, pocket_ack {seq, cmd, ok, info},
--                   pocket_claude {log, busy, status, approval, error}, pocket_error {info, req, seq}
local PROTO = "wardenos"
local PAIRED = "/os/pockets"
local ONLINE = 10                               -- seconds since the last status: drone is online
local RELAY_TIMEOUT = 15
local PAIR_TIMEOUT = 60
local WATCH = 300                               -- pockets that used Claude recently get live updates
local NO_KEY = "No Claude key on the server; open Claude on the computer first"

local M = {}
local me = os.getComputerID()

---------------------------------------------------------------- paired pockets
local paired = {}
if fs.exists(PAIRED) then
  local f = fs.open(PAIRED, "r")
  local d = f and textutils.unserialize(f.readAll())
  if f then f.close() end
  if type(d) == "table" then
    for id, v in pairs(d) do if v == true and tonumber(id) then paired[tonumber(id)] = true end end
  end
end
local function savePaired()
  local f = fs.open(PAIRED, "w")
  if f then
    f.write(textutils.serialize(paired))
    f.close()
  end
end
function M.isPaired(id) return paired[id] == true end

---------------------------------------------------------------- helpers
local function reply(id, msg)
  if rednet.isOpen() then rednet.send(id, msg, PROTO) end
end

local own = {}                                  -- [id] = latest turtle status + seen (os.clock), when alone
-- the kernel's shared cache (WardenOS.drones, filled by /os/lib/world.lua) when there is one
local function shared()
  local W = rawget(_G, "WardenOS")
  return type(W) == "table" and type(W.drones) == "table" and W.drones or nil
end
local function cache() return shared() or own end
local requests = {}                             -- pairing requests waiting for the player: { id, timer }
local relays, relayTimers = {}, {}              -- [relaySeq] = { pocket, seq, drone, cmd, timer }
local relaySeq = 1000000 + math.random(0, 99999) * 10   -- far from the Drones / Claude apps' numbers
local lastPing = -100
local watchers = {}                             -- [pocketId] = os.clock() of its last Claude request
local chat, core, coreErr
local sandbox                                   -- hidden window: run_lua output never lands on the desktop

local function droneList()
  local now, out = os.clock(), {}
  for id, d in pairs(cache()) do
    local log = {}
    for i = 1, 5 do if type(d.log) == "table" and d.log[i] then log[i] = tostring(d.log[i]) end end
    out[#out + 1] = {
      id = id, label = d.label, owner = d.owner, task = d.task, state = d.state,
      fuel = d.fuel, fuelLimit = d.fuelLimit, nav = d.nav, homeSet = d.homeSet, pos = d.pos,
      log = log, lastTask = d.lastTask, online = (now - (d.seen or -1e9)) < ONLINE,
      abs = d.abs, calibrated = d.calibrated, fuelItems = d.fuelItems, safeDig = d.safeDig,
    }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

---------------------------------------------------------------- Claude for pockets
local function getChat()
  if chat then return chat end
  if not core then
    local ok, m = pcall(dofile, "/os/pocket/claudecore.lua")
    if not ok or type(m) ~= "table" then coreErr = tostring(m) return nil end
    core = m
  end
  chat = core.new({ where = "server" })
  return chat
end

local function chatState(err)
  local s = chat and chat.snapshot(30) or { log = {}, busy = false, status = "" }
  s.t = "pocket_claude"
  if not err and not (core and core.api.getKey()) then err = NO_KEY end
  s.error = err
  return s
end

local function flushChat(extra)                  -- send the conversation to every pocket watching it
  if not chat or not chat.dirty then return end
  chat.dirty = false
  local s = chatState()
  local now = os.clock()
  for id, t in pairs(watchers) do
    if not paired[id] or now - t > WATCH then watchers[id] = nil
    elseif id ~= extra then reply(id, s) end
  end
end

local function resumeChat(ev)
  if not chat or not chat.busy then return end
  local parent = term.current()
  if not sandbox then sandbox = window.create(parent, 1, 1, 26, 20, false) end
  term.redirect(sandbox)
  local ok, err = pcall(chat.resume, ev)
  term.redirect(parent)
  if not ok then chat.dirty = true coreErr = tostring(err) end
end

local function onClaude(from, msg)
  watchers[from] = os.clock()
  local c = getChat()
  if not c then reply(from, chatState("Claude is not available: " .. tostring(coreErr))) return end
  local op, err = msg.op, nil
  if op == "send" then
    local key = core.api.getKey()
    if not key then
      err = NO_KEY
    elseif type(msg.text) ~= "string" or not msg.text:match("%S") then
      err = "empty message"
    else
      local parent = term.current()
      if not sandbox then sandbox = window.create(parent, 1, 1, 26, 20, false) end
      term.redirect(sandbox)
      local ok, a, b = pcall(c.send, msg.text:sub(1, 4000), key)
      term.redirect(parent)
      if not ok then err = tostring(a) elseif not a then err = b end
    end
  elseif op == "decision" then
    if not c.decide(msg.choice) then err = "nothing to decide" end
  elseif op == "new" then
    if not c.reset() then err = "Claude is busy" end
  elseif op ~= "poll" then
    err = "unknown op"
  end
  c.dirty = false
  reply(from, chatState(err))
  flushChat(from)
end

---------------------------------------------------------------- drone relay
local function onCmd(from, msg)
  local drone, cmd = tonumber(msg.drone), msg.cmd
  if not drone or type(cmd) ~= "string" or cmd == "" or #cmd > 32 then
    reply(from, { t = "pocket_ack", seq = msg.seq, cmd = cmd, ok = false, info = "bad command" })
    return
  end
  if not rednet.isOpen() then
    reply(from, { t = "pocket_ack", seq = msg.seq, cmd = cmd, ok = false, info = "no modem on the server" })
    return
  end
  relaySeq = relaySeq + 1
  local r = { pocket = from, seq = msg.seq, drone = drone, cmd = cmd, timer = os.startTimer(RELAY_TIMEOUT) }
  relays[relaySeq], relayTimers[r.timer] = r, relaySeq
  rednet.send(drone, { t = "cmd", to = drone, seq = relaySeq, cmd = cmd, arg = msg.arg }, PROTO)
end

local function onAck(from, msg)
  local r = relays[msg.seq]
  if not r or r.drone ~= from or msg.cmd ~= r.cmd then return end
  relays[msg.seq], relayTimers[r.timer] = nil, nil
  reply(r.pocket, { t = "pocket_ack", seq = r.seq, cmd = r.cmd, drone = from, ok = msg.ok and true or false,
                    info = msg.info and tostring(msg.info) or nil })
end

---------------------------------------------------------------- pairing
local function findRequest(id)
  for i, r in ipairs(requests) do if r.id == id then return i, r end end
end

function M.prompt()
  local r = requests[1]
  return r and { id = r.id } or nil
end

function M.decide(allow)
  local r = table.remove(requests, 1)
  if not r then return false end
  if allow then
    paired[r.id] = true
    savePaired()
  end
  reply(r.id, { t = "pocket_paired", ok = allow and true or false, info = (not allow) and "denied" or nil })
  return true
end

---------------------------------------------------------------- messages
local function onMessage(from, msg)
  local t = msg.t
  if t == "status" then
    if msg.kind == "turtle" and not shared() then   -- with a kernel, /os/lib/world.lua keeps the cache
      local d = {}
      for k, v in pairs(msg) do d[k] = v end
      d.seen = os.clock()
      own[from] = d
    end
    return false
  elseif t == "ack" then
    onAck(from, msg)
    return false
  end
  if type(t) ~= "string" or t:sub(1, 7) ~= "pocket_" then return false end

  if t == "pocket_pair" then
    if paired[from] then reply(from, { t = "pocket_paired", ok = true }) return false end
    if findRequest(from) then return false end
    requests[#requests + 1] = { id = from, timer = os.startTimer(PAIR_TIMEOUT) }
    return #requests == 1
  elseif t == "pocket_unpair" then
    local i = findRequest(from)
    if i then table.remove(requests, i) end
    if paired[from] then
      paired[from] = nil
      savePaired()
    end
    watchers[from] = nil
    reply(from, { t = "pocket_unpaired" })
    return i == 1
  end

  if not paired[from] then
    reply(from, { t = "pocket_error", info = "not paired", req = t, seq = msg.seq })
    return false
  end
  if t == "pocket_drones" then
    if os.clock() - lastPing > 4 and rednet.isOpen() then
      lastPing = os.clock()
      rednet.broadcast({ t = "ping" }, PROTO)
    end
    reply(from, { t = "pocket_drones", server = me, drones = droneList() })
  elseif t == "pocket_cmd" then
    onCmd(from, msg)
  elseif t == "pocket_claude" then
    onClaude(from, msg)
  else
    reply(from, { t = "pocket_error", info = "unknown request", req = t, seq = msg.seq })
  end
  return false
end

local function onTimer(id)
  local rs = relayTimers[id]
  if rs then
    local r = relays[rs]
    relays[rs], relayTimers[id] = nil, nil
    if r then reply(r.pocket, { t = "pocket_ack", seq = r.seq, cmd = r.cmd, drone = r.drone, ok = false, info = "no answer" }) end
    return false
  end
  for i, r in ipairs(requests) do
    if r.timer == id then
      table.remove(requests, i)
      reply(r.id, { t = "pocket_paired", ok = false, info = "timed out" })
      return i == 1
    end
  end
  return false
end

function M.event(ev)
  local name, changed = ev[1], false
  if name == "terminate" then return false end
  if name == "rednet_message" and ev[4] == PROTO and type(ev[3]) == "table" then
    changed = onMessage(ev[2], ev[3])
  elseif name == "timer" then
    changed = onTimer(ev[2])
  end
  if chat then
    resumeChat(ev)
    flushChat()
  end
  return changed
end

-- for tests and the curious
M._drones, M._relays = own, relays

return M
