-- WardenOS Pocket: Claude conversation engine without a screen.
-- Used by the pocket in local mode (/os/pocket/main.lua) and by a WardenOS computer that serves
-- pockets (/os/lib/pocketserver.lua). The tools and the system prompt are shared with /os/apps/claude.lua
-- (/os/lib/claudetools.lua); the request body is built the same way here and there: keep both in step.
--
--   local core = dofile("/os/pocket/claudecore.lua")
--   local chat = core.new({ where = "pocket" | "server" })
--   chat.send(text, key)   start a turn (false, why when busy)
--   chat.decide(choice)    "allow" | "always" | "deny" for the pending approval
--   chat.reset()           new conversation (not while busy)
--   chat.resume(ev)        give it every event (it runs as a coroutine that waits with os.pullEvent)
--   chat.dirty             set when something visible changed; the owner clears it
--   chat.snapshot(n)       { log = last n {kind, text}, busy, status, approval = {name, text} | nil }
--   core.tools             /os/lib/claudetools.lua (tools.lines(cache): the drones Claude is using now)
local api = dofile("/os/lib/claude.lua")
local json = api.json
local PROTO = "wardenos"
local MAX_STEPS = 25                            -- tool rounds per message, guards against runaway loops
local MAX_OUT = 6000                            -- characters of tool output sent back to Claude
local MAX_LOG = 80                              -- transcript entries kept for the screen
local DECISION = "claudecore_decision"          -- own event name: the desktop Claude app waits for "claude_decision"

---------------------------------------------------------------- tools + system prompt (/os/lib/claudetools.lua)
local tools = dofile("/os/lib/claudetools.lua")

local function clip(s)
  s = tostring(s)
  if #s > MAX_OUT then s = s:sub(1, MAX_OUT) .. ("\n[cut: %d more characters]"):format(#s - MAX_OUT) end
  return s
end

---------------------------------------------------------------- one conversation
local M = { api = api, json = json, DECISION = DECISION, tools = tools }

function M.new(opts)
  opts = opts or {}
  -- own tool kit per conversation; drone command numbers far from the Drones app, Claude app and pocket relay
  local kit = tools.new({ where = opts.where == "server" and "server" or "pocket",
                          seq = 2000000 + math.random(0, 99999) * 10, api = api })
  local TOOLS, RISKY, RUN, describe, system = kit.TOOLS, kit.RISKY, kit.RUN, kit.describe, kit.system
  local E = { log = {}, busy = false, status = "", approval = nil, dirty = true, tokens = 0 }
  local msgs = json.array()
  local allowAlways = {}
  local worker, filter, choice, key

  local function add(kind, text)
    E.log[#E.log + 1] = { kind = kind, text = tostring(text) }
    while #E.log > MAX_LOG do table.remove(E.log, 1) end
    E.dirty = true
  end
  local function sync() pcall(kit.setBusy, E.busy, E.approval and "Waiting for your OK" or E.status) end
  local function setStatus(s) E.status = s E.dirty = true sync() end
  E.kit = kit

  -- undo the current turn: back to before the player's last message (the history stays valid)
  local function rollback()
    while #msgs > 0 do
      local m = table.remove(msgs)
      if m.role == "user" and type(m.content) == "string" then break end
    end
  end

  local function turn()
    local cfg = api.loadConfig()
    for step = 1, MAX_STEPS do
      setStatus("Claude is thinking...")
      local body = {
        model = cfg.model, max_tokens = 16000,
        system = json.array({ { type = "text", text = system } }),
        tools = TOOLS, messages = msgs,
        output_config = { effort = cfg.effort },
        fallbacks = "default",                    -- a declined request is retried on another model
        cache_control = { type = "ephemeral" },
      }
      local res, err = api.send(key, body, function(msg, wait)
        setStatus(("%s - retrying in %ds"):format(msg, wait))
      end)
      if not res then
        add("error", err)
        if step > 1 then add("info", "(this turn was undone; actions already done stay done)") end
        rollback()
        return
      end
      if type(res.usage) == "table" then
        E.tokens = E.tokens + (tonumber(res.usage.input_tokens) or 0) + (tonumber(res.usage.output_tokens) or 0)
          + (tonumber(res.usage.cache_read_input_tokens) or 0) + (tonumber(res.usage.cache_creation_input_tokens) or 0)
      end
      local content = type(res.content) == "table" and res.content or json.array()

      if res.stop_reason == "refusal" then
        add("error", "Claude declined this request.")
        rollback()
        return
      end

      local uses = {}
      for _, block in ipairs(content) do
        if block.type == "text" and type(block.text) == "string" and block.text:match("%S") then
          add("claude", block.text)
        elseif block.type == "tool_use" then
          uses[#uses + 1] = block
        end
      end

      if res.stop_reason ~= "tool_use" or #uses == 0 then
        if res.stop_reason == "max_tokens" then add("info", "(reply was cut off)") end
        if #uses > 0 then                         -- unfinished tool calls can't stay in the history
          rollback()
          add("error", "That reply was cut off mid-action; nothing was run. Try again.")
          return
        end
        if #content == 0 then content = json.array({ { type = "text", text = "(no reply)" } }) end
        msgs[#msgs + 1] = { role = "assistant", content = content }
        return
      end

      msgs[#msgs + 1] = { role = "assistant", content = content }      -- appended unchanged
      local results = json.array()
      for _, use in ipairs(uses) do
        local name, inp = tostring(use.name), type(use.input) == "table" and use.input or json.object()
        local text, isErr
        if not RUN[name] then
          text, isErr = "unknown tool " .. name, true
        else
          local allowed = true
          local early = kit.precheck(name, inp)  -- refused before asking: no point approving it
          if early then
            allowed = false
          elseif RISKY[name] and not cfg.auto and not allowAlways[name] then
            E.approval = { name = name, text = describe(name, inp) }
            choice = nil
            setStatus("Waiting for your OK")
            while not choice do os.pullEvent(DECISION) end
            local c = choice
            choice, E.approval = nil, nil
            if c == "always" then allowAlways[name] = true end
            allowed = c ~= "deny"
          end
          if allowed then
            add("tool", name .. ": " .. describe(name, inp):gsub("\n", " "):sub(1, 60))
            setStatus("Running " .. name .. "...")
            local ok, a, b = pcall(RUN[name], inp)
            if ok then text, isErr = a, b else text, isErr = "tool crashed: " .. tostring(a), true end
          elseif early then
            text, isErr = early, true
          else
            add("info", "denied: " .. name)
            text, isErr = "The player denied this action.", true
          end
        end
        results[#results + 1] = { type = "tool_result", tool_use_id = use.id, content = clip(text), is_error = isErr and true or false }
      end
      msgs[#msgs + 1] = { role = "user", content = results }
    end
    add("info", ("Stopped after %d steps. Say 'continue' to go on."):format(MAX_STEPS))
    msgs[#msgs + 1] = { role = "assistant", content = json.array({ { type = "text", text = "(paused)" } }) }
  end

  function E.resume(ev)
    if not worker then return end
    if ev[1] == "terminate" then return end      -- a turn is never killed by Ctrl+T on the owner
    if filter and ev[1] ~= filter then return end
    local ok, f = coroutine.resume(worker, table.unpack(ev, 1, ev.n or #ev))
    if not ok then add("error", tostring(f)) end
    if not ok or coroutine.status(worker) == "dead" then
      worker, filter = nil, nil
      E.busy, E.status, E.approval = false, "", nil
      E.dirty = true
      sync()
    else
      filter = f
    end
  end

  function E.send(text, k)
    text = tostring(text or "")
    if E.busy then return false, "Claude is busy" end
    if not text:match("%S") then return false, "empty message" end
    if not http then
      add("user", text)
      add("error", "The http API is disabled on this server.")
      return false, "http disabled"
    end
    if not k then return false, "no API key" end
    key = k
    add("user", text)
    msgs[#msgs + 1] = { role = "user", content = text }
    E.busy, E.status = true, "Claude is thinking..."
    sync()
    worker = coroutine.create(function()
      local ok, err = pcall(turn)
      if not ok then add("error", "crashed: " .. tostring(err)) rollback() end   -- keep the history valid
    end)
    filter = nil
    E.resume({ n = 0 })
    return true
  end

  function E.decide(c)
    if not E.approval then return false end
    if c ~= "allow" and c ~= "always" then c = "deny" end
    choice = c
    os.queueEvent(DECISION, c)
    return true
  end

  function E.reset()
    if E.busy then return false end
    msgs, E.log, allowAlways = json.array(), {}, {}
    E.dirty = true
    return true
  end

  function E.snapshot(n)
    n = n or 30
    local log = {}
    for i = math.max(1, #E.log - n + 1), #E.log do
      local e = E.log[i]
      log[#log + 1] = { kind = e.kind, text = #e.text > 1500 and (e.text:sub(1, 1500) .. " [...]") or e.text }
    end
    local ap = E.approval and { name = E.approval.name, text = E.approval.text:sub(1, 1500) } or nil
    return { log = log, busy = E.busy, status = E.status, approval = ap }
  end

  return E
end

return M
