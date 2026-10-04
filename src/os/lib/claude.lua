-- Claude API client for WardenOS (raw HTTP to the Messages API; CC: Tweaked has no Anthropic SDK).
-- Must run inside a coroutine that gets events (an app): it waits with os.pullEvent.
local json = dofile("/os/lib/json.lua")

local M = { json = json }
M.URL = "https://api.anthropic.com/v1/messages"
M.MODELS = { "claude-opus-5-5", "claude-sonnet-5-5" }
M.EFFORTS = { "low", "medium", "high" }

local DIR = "/os/claude"
local KEY, CONFIG = DIR .. "/key", DIR .. "/config"

---------------------------------------------------------------- key + config (stored on this computer)
local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end
local function writeFile(p, s)
  fs.makeDir(DIR)
  local f = fs.open(p, "w")
  f.write(s)
  f.close()
end

function M.getKey()
  local k = readFile(KEY)
  k = k and k:gsub("%s", "")
  if k and k ~= "" then return k end
end
function M.setKey(k) writeFile(KEY, (k:gsub("%s", ""))) end
function M.forgetKey() if fs.exists(KEY) then fs.delete(KEY) end end

function M.loadConfig()
  local c = { model = M.MODELS[1], effort = "low", auto = false, allDrones = false }
  local d = textutils.unserialize(readFile(CONFIG) or "")
  if type(d) == "table" then
    for _, m in ipairs(M.MODELS) do if d.model == m then c.model = m end end
    for _, e in ipairs(M.EFFORTS) do if d.effort == e then c.effort = e end end
    c.auto = d.auto == true
    c.allDrones = d.allDrones == true            -- true: every drone this computer owns is Claude's
  end
  return c
end
function M.saveConfig(c)
  writeFile(CONFIG, textutils.serialize({ model = c.model, effort = c.effort, auto = c.auto, allDrones = c.allDrones == true }))
end

-- drones the player gave to Claude: { [id] = true }
local DRONES = DIR .. "/drones"
function M.getDrones()
  local d = textutils.unserialize(readFile(DRONES) or "")
  local out = {}
  if type(d) == "table" then
    for id, v in pairs(d) do if v == true and tonumber(id) then out[tonumber(id)] = true end end
  end
  return out
end
function M.setDrone(id, given)
  local d = M.getDrones()
  d[id] = given and true or nil
  writeFile(DRONES, textutils.serialize(d))
end

---------------------------------------------------------------- one HTTP round trip
-- returns decoded response | nil, message, retryable, retryAfterSeconds
local function post(key, payload)
  local headers = {
    ["Content-Type"] = "application/json",
    ["x-api-key"] = key,
    ["anthropic-version"] = "2023-06-01",
    ["anthropic-beta"] = "server-side-fallback-2026-07-01",   -- for fallbacks = "default"
  }
  -- Ask for a long timeout (Claude can take a while), but servers cap it ("timeout out of range"
  -- is a hard error), so step down and finally use the server's default.
  -- A request that fails later still queues http_failure, which the loop below picks up.
  local req = { url = M.URL, body = payload, headers = headers, method = "POST", binary = true }
  local ok, err
  for _, t in ipairs({ 300, 120, 60, 30, false }) do
    req.timeout = t or nil
    ok, err = pcall(http.request, req)
    if ok or not tostring(err):lower():find("timeout") then break end
  end
  if not ok then return nil, "could not send the request: " .. tostring(err), false end
  while true do
    local e, url, a, b = os.pullEvent()
    if url == M.URL and e == "http_success" then
      local text = a.readAll()
      a.close()
      local okj, res = pcall(json.decode, text)
      if not okj then return nil, "unreadable reply: " .. tostring(res), true end
      return res
    elseif url == M.URL and e == "http_failure" then
      local code, text, after
      if b then
        code = b.getResponseCode()
        text = b.readAll()
        local h = b.getResponseHeaders and b.getResponseHeaders() or {}
        after = tonumber(h["retry-after"] or h["Retry-After"] or "")
        b.close()
      end
      local msg = tostring(a)
      local okj, res = pcall(json.decode, text or "")
      if okj and type(res) == "table" and type(res.error) == "table" and res.error.message then
        msg = tostring(res.error.message)
      end
      if code then msg = ("HTTP %d: %s"):format(code, msg) end
      if code == 401 then msg = "API key rejected (401). Check it in Claude > options." end
      local retry = code == nil or code == 408 or code == 409 or code == 429 or code >= 500
      return nil, msg, retry, after
    end
  end
end

-- Replies are matched by URL only, so requests from different conversations on this computer
-- (desktop app, pocket relay) must take turns. A request abandoned by a closed window is
-- considered gone after its timeout.
local function postOne(key, payload)
  local L = rawget(_G, "WardenClaudeHttp")
  if not L then L = {} rawset(_G, "WardenClaudeHttp", L) end
  while L.busy and os.clock() - L.since < 310 do sleep(0.25) end
  L.busy, L.since = true, os.clock()
  local ok, a, b, c, d = pcall(post, key, payload)
  L.busy = false
  if not ok then error(a, 0) end
  return a, b, c, d
end

-- Messages API call with up to 2 retries for 429 / 5xx / network errors.
-- body is a Lua table (use json.array / json.object where the JSON type matters).
function M.send(key, body, onRetry)
  local payload = json.encode(body)
  local res, msg, retry, after
  for attempt = 1, 3 do
    res, msg, retry, after = postOne(key, payload)
    if res or not retry or attempt == 3 then break end
    local wait = math.min(after or (2 ^ attempt), 20)
    if onRetry then onRetry(msg, wait) end
    sleep(wait)
  end
  if not res then return nil, msg end
  if res.type == "error" then
    return nil, type(res.error) == "table" and tostring(res.error.message) or "API error"
  end
  return res
end

return M
