-- Claude: chat with Claude, who can act on this computer through tools (with your approval)
local api = dofile("/os/lib/claude.lua")
local json = api.json
local PROTO = "wardenos"
local MAX_STEPS = 25                            -- tool rounds per message, guards against runaway loops
local MAX_OUT = 6000                            -- characters of tool output sent back to Claude

---------------------------------------------------------------- tools Claude can use (/os/lib/claudetools.lua)
local tools = dofile("/os/lib/claudetools.lua")
local kit = tools.new({ where = "desktop", seq = 0, api = api })
local TOOLS, RISKY, RUN, describe, SYSTEM = kit.TOOLS, kit.RISKY, kit.RUN, kit.describe, kit.system

local function clip(s)
  s = tostring(s)
  if #s > MAX_OUT then s = s:sub(1, MAX_OUT) .. ("\n[cut: %d more characters]"):format(#s - MAX_OUT) end
  return s
end

---------------------------------------------------------------- app
return {
  name = "Claude", short = "AI", icon = "*", color = colors.orange, order = 2,
  w = 48, h = 18,
  art = { { "\\||/", "1111", "7117" }, { "/||\\", "1111", "7117" } },   -- 4x2 icon (blit; bg 7 = panel)
  main = function()
    local T = WardenOS.theme
    local cfg = api.loadConfig()
    local key = api.getKey()
    local msgs = json.array()
    local log = {}                                -- { kind, text } shown in the window
    local input, scroll = "", 0
    local busy, status = false, ""
    local approval                                -- { name, text } while waiting for the player
    local allowAlways = {}
    local tokens = 0
    local view = key and "chat" or "key"
    local zones = {}
    local worker, workerFilter

    local function add(kind, text) log[#log + 1] = { kind = kind, text = tostring(text) } scroll = 0 end

    -- undo the current turn: back to before the player's last message (the history stays valid)
    local function rollback()
      while #msgs > 0 do
        local m = table.remove(msgs)
        if m.role == "user" and type(m.content) == "string" then break end
      end
    end

    ------------------------------------------------ one conversation turn (runs as a coroutine)
    local function turn()
      for step = 1, MAX_STEPS do
        status = "Claude is thinking..."
        os.queueEvent("claude_redraw")
        local body = {
          model = cfg.model, max_tokens = 16000,
          system = json.array({ { type = "text", text = SYSTEM } }),
          tools = TOOLS, messages = msgs,
          output_config = { effort = cfg.effort },
          fallbacks = "default",                  -- a declined request is retried on another model
          cache_control = { type = "ephemeral" },
        }
        local res, err = api.send(key, body, function(msg, wait)
          status = ("%s - retrying in %ds"):format(msg, wait)
          os.queueEvent("claude_redraw")
        end)
        if not res then
          add("error", err)
          if step > 1 then add("info", "(this turn was undone; actions already done stay done)") end
          rollback()
          return
        end
        if type(res.usage) == "table" then
          tokens = tokens + (tonumber(res.usage.input_tokens) or 0) + (tonumber(res.usage.output_tokens) or 0)
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
          if #uses > 0 then                       -- unfinished tool calls can't stay in the history
            rollback()
            add("error", "That reply was cut off mid-action; nothing was run. Try again.")
            return
          end
          -- an empty reply can't stay in the history (the API rejects empty assistant messages)
          if #content == 0 then content = json.array({ { type = "text", text = "(no reply)" } }) end
          msgs[#msgs + 1] = { role = "assistant", content = content }
          return
        end

        msgs[#msgs + 1] = { role = "assistant", content = content }    -- appended unchanged
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
              approval = { name = name, text = describe(name, inp) }
              status = "Waiting for your OK"
              os.queueEvent("claude_redraw")
              local _, choice = os.pullEvent("claude_decision")
              approval = nil
              if choice == "always" then allowAlways[name] = true end
              allowed = choice ~= "deny"
            end
            if allowed then
              add("tool", name .. ": " .. describe(name, inp):gsub("\n", " "):sub(1, 60))
              status = "Running " .. name .. "..."
              os.queueEvent("claude_redraw")
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

    local function startTurn(text)
      add("user", text)
      if not http then add("error", "The http API is disabled on this server.") return end
      msgs[#msgs + 1] = { role = "user", content = text }
      busy = true
      worker = coroutine.create(function()
        local ok, err = pcall(turn)
        if not ok then add("error", "crashed: " .. tostring(err)) rollback() end   -- keep the history valid
        busy, status, approval = false, "", nil
      end)
      workerFilter = nil
    end

    local function resume(ev)
      if not worker then return end
      if workerFilter and ev[1] ~= workerFilter and ev[1] ~= "terminate" then return end
      local ok, f = coroutine.resume(worker, table.unpack(ev, 1, ev.n or #ev))
      if not ok then add("error", tostring(f)) busy = false end
      if coroutine.status(worker) == "dead" then worker, busy = nil, false else workerFilter = f end
    end

    ------------------------------------------------ drawing
    local function put(x, y, s, fg, bg)
      term.setCursorPos(x, y)
      term.setTextColor(fg or T.text)
      term.setBackgroundColor(bg or T.bg)
      term.write(s)
    end
    local function zone(x, y, w, fn) zones[#zones + 1] = { x, x + w - 1, y, fn } end
    local function button(x, y, label, fn, fg, bg)
      label = " " .. label .. " "
      put(x, y, label, fg or T.text, bg or T.panel)
      zone(x, y, #label, fn)
      return x + #label + 1
    end
    local function ascii(s) return (s:gsub("[\192-\255][\128-\191]*", "?")) end

    local function wrap(text, width, indent)
      local out = {}
      for para in (ascii(text) .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in para:gmatch("%S+") do
          while #word > width do
            if line ~= "" then out[#out + 1] = line line = "" end
            out[#out + 1] = word:sub(1, width)
            word = word:sub(width + 1)
          end
          if line == "" then line = word
          elseif #line + 1 + #word <= width then line = line .. " " .. word
          else out[#out + 1] = line line = word end
        end
        out[#out + 1] = line
      end
      while #out > 0 and out[#out] == "" do out[#out] = nil end
      for i = 1, #out do out[i] = (indent or "") .. out[i] end
      return out
    end

    local function drawKey(w, h)
      put(2, 3, "Connect Claude", T.accent)
      local y = 5
      for _, l in ipairs(wrap("Paste an Anthropic API key (from console.anthropic.com) and press Enter. Claude API use is billed to that key.", w - 2)) do
        put(2, y, l, T.dim) y = y + 1
      end
      y = y + 1
      for _, l in ipairs(wrap("The key is saved in /os/claude/key on this computer: anyone who can read this computer's files or the world save can see it.", w - 2)) do
        put(2, y, l, T.warn) y = y + 1
      end
      y = y + 1
      local shown = input == "" and "paste key here" or (input:sub(1, 7) .. string.rep("*", math.max(0, #input - 7)))
      put(2, y, (" " .. shown .. string.rep(" ", w)):sub(1, w - 2), input == "" and T.dim or T.text, T.panel)
      if key then button(2, y + 2, "Cancel", function() input, view = "", "chat" end) end
    end

    local function drawOptions(w)
      put(2, 3, "Model", T.text)
      local x = 2
      for _, m in ipairs(api.MODELS) do
        local label = m:gsub("^claude%-", "")
        x = button(x, 4, label, function() cfg.model = m api.saveConfig(cfg) end,
                   cfg.model == m and T.bg or T.text, cfg.model == m and T.accent or T.panel)
      end
      put(2, 6, "Effort (lower = faster, cheaper)", T.text)
      x = 2
      for _, e in ipairs(api.EFFORTS) do
        x = button(x, 7, e, function() cfg.effort = e api.saveConfig(cfg) end,
                   cfg.effort == e and T.bg or T.text, cfg.effort == e and T.accent or T.panel)
      end
      put(2, 9, "Actions (Lua, files, peripherals, drones)", T.text)
      x = button(2, 10, "Ask me first", function() cfg.auto = false api.saveConfig(cfg) end,
                 not cfg.auto and T.bg or T.text, not cfg.auto and T.accent or T.panel)
      button(x, 10, "Run without asking", function() cfg.auto = true api.saveConfig(cfg) end,
             cfg.auto and T.bg or T.text, cfg.auto and T.warn or T.panel)
      put(2, 12, "Drones Claude may use", T.text)
      x = button(2, 13, "Only given ones", function() cfg.allDrones = false api.saveConfig(cfg) end,
                 not cfg.allDrones and T.bg or T.text, not cfg.allDrones and T.accent or T.panel)
      button(x, 13, "All mine", function() cfg.allDrones = true api.saveConfig(cfg) end,
             cfg.allDrones and T.bg or T.text, cfg.allDrones and T.accent or T.panel)
      x = button(2, 15, "Change API key", function() input, view = "", "key" end)
      button(x, 15, "Forget key", function() api.forgetKey() key, input, view = nil, "", "key" end, T.bad)
      x = button(2, 17, "Back", function() view = "chat" end, T.bg, T.accent)
      put(x + 1, 17, ("%d tokens this session"):format(tokens):sub(1, math.max(0, w - x - 1)), T.dim)
    end

    local COLORS = { user = "accent", claude = "text", tool = "warn", info = "dim", error = "bad" }
    local function drawChat(w, h)
      local lines = {}
      for _, e in ipairs(log) do
        local prefix = e.kind == "user" and "> " or (e.kind == "tool" and "# " or "")
        for _, l in ipairs(wrap(prefix .. e.text, w - 1)) do
          lines[#lines + 1] = { l, T[COLORS[e.kind]] or T.text }
        end
        lines[#lines + 1] = { "", T.text }
      end
      if #log == 0 then
        for _, l in ipairs(wrap("Ask Claude anything about this computer, your mods or your drones. Claude can run Lua, use files and peripherals, and command drones you own" .. (cfg.auto and "." or " - it asks you first."), w - 2)) do
          lines[#lines + 1] = { l, T.dim }
        end
      end
      -- drones Claude is using right now (live phase/step from the drones' status), above the status line
      local dl = {}
      if not approval then
        local cache = type(WardenOS.drones) == "table" and WardenOS.drones or nil
        local okl, l = pcall(tools.lines, cache)
        if okl and type(l) == "table" then dl = l end
      end
      local nd = math.min(#dl, 2, math.max(0, h - 8))
      local statusY = busy and status ~= "" and h - 1 or nil
      local bottom = h - 2 - nd                    -- last transcript row
      if nd > 0 and not statusY then bottom = bottom + 1 end
      for i = 1, nd do
        local txt = dl[i].text .. (i == nd and #dl > nd and (" +" .. (#dl - nd)) or "")
        put(1, bottom + i, txt:sub(1, w), dl[i].running and T.accent or T.dim)
      end
      local cardH = 0
      if approval then
        local body = wrap(approval.text, w - 2)
        cardH = math.min(#body, math.max(1, h - 9)) + 3
        bottom = h - 1 - cardH
      end
      local rows = bottom - 1
      scroll = math.max(0, math.min(scroll, #lines - rows))
      local first = math.max(1, #lines - rows + 1 - scroll)
      for i = 0, rows - 1 do
        local l = lines[first + i]
        if l then put(1, 2 + i, l[1]:sub(1, w), l[2]) end
      end
      if approval then
        local y = bottom + 1
        term.setBackgroundColor(T.panel)
        for r = y, y + cardH - 1 do term.setCursorPos(1, r) term.clearLine() end
        put(2, y, ("Claude wants to use %s:"):format(approval.name), T.warn, T.panel)
        local body = wrap(approval.text, w - 2)
        for i = 1, cardH - 3 do put(2, y + i, (body[i] or ""):sub(1, w - 2), T.text, T.panel) end
        local bx = button(2, y + cardH - 2, "Allow", function() os.queueEvent("claude_decision", "allow") end, T.bg, T.good)
        bx = button(bx, y + cardH - 2, "Always", function() os.queueEvent("claude_decision", "always") end)
        button(bx, y + cardH - 2, "Deny", function() os.queueEvent("claude_decision", "deny") end, T.bg, T.bad)
      end
      if statusY then put(1, h - 1, status:sub(1, w), T.dim) end
      local shown = busy and "(wait...)" or input
      local room = w - 3
      if #shown > room then shown = shown:sub(-room) end
      term.setCursorPos(1, h)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(1, h, "> ", T.accent, T.panel)
      put(3, h, shown, busy and T.dim or T.text, T.panel)
    end

    local function render()
      pcall(kit.setBusy, busy, approval and "Waiting for your OK" or status)
      local parent = term.current()
      local w, h = parent.getSize()
      local buf = window.create(parent, 1, 1, w, h, false)
      term.redirect(buf)
      zones = {}
      term.setBackgroundColor(T.bg)
      term.clear()
      term.setCursorPos(1, 1)
      term.setBackgroundColor(T.panel)
      term.clearLine()
      put(2, 1, "Claude", T.accent, T.panel)
      put(9, 1, (cfg.model:gsub("^claude%-", "")):sub(1, math.max(0, w - 26)), T.dim, T.panel)
      if view == "chat" then
        local x = w - 15
        x = button(x, 1, "new", function()
          if not busy then msgs, log, allowAlways, scroll = json.array(), {}, {}, 0 end
        end, T.text, T.panel)
        button(x, 1, "options", function() view = "options" end, T.text, T.panel)
        drawChat(w, h)
      elseif view == "options" then
        drawOptions(w)
      else
        drawKey(w, h)
      end
      term.redirect(parent)
      buf.setVisible(true)
      if view == "chat" and not busy and not approval then
        parent.setCursorPos(math.min(w, 3 + math.min(#input, w - 3)), h)
        parent.setTextColor(T.text)
        parent.setCursorBlink(true)
      else
        parent.setCursorBlink(false)
      end
    end

    ------------------------------------------------ events
    render()
    while true do
      local ev = table.pack(os.pullEventRaw())
      local e, a, b, c = ev[1], ev[2], ev[3], ev[4]
      if e == "terminate" then error("Terminated", 0) end
      resume(ev)
      if e == "char" or e == "paste" then
        if (view == "chat" and not busy) or view == "key" then input = input .. a end
      elseif e == "key" then
        if a == keys.backspace then input = input:sub(1, -2)
        elseif a == keys.enter then
          if view == "key" and input:match("%S") then
            api.setKey(input)
            key, input, view = api.getKey(), "", "chat"
          elseif view == "chat" and not busy and input:match("%S") then
            local text = input
            input = ""
            startTurn(text)
            resume({ n = 0 })
          end
        elseif a == keys.up or a == keys.pageUp then scroll = scroll + (a == keys.up and 1 or 5)
        elseif a == keys.down or a == keys.pageDown then scroll = math.max(0, scroll - (a == keys.down and 1 or 5)) end
      elseif e == "mouse_scroll" then
        scroll = math.max(0, scroll - a)
      elseif e == "mouse_click" then
        for _, z in ipairs(zones) do
          if c == z[3] and b >= z[1] and b <= z[2] then z[4]() break end   -- button, x, y
        end
      end
      render()
    end
  end,
}
