-- Drone templates: saved drone programs the player can rerun with one tap (Drones app) and Claude can save/run.
--   local tpl = dofile("/os/lib/templates.lua")
--   tpl.slug(name)               lowercase, [^a-z0-9_-] -> "_", max 32 characters
--   tpl.list()                   { {slug, name, description, author, created}, ... } sorted by name (no code)
--   tpl.get(nameOrSlug)          { slug, name, description, code, author, created } | nil
--   tpl.save(t)                  t = {name, description, code, author = "claude" | "player"} -> slug | nil, why
--                                (the code must compile; an existing template is replaced)
--   tpl.delete(nameOrSlug)       true | false
-- Files: /os/templates/<slug>.dat = textutils.serialize({ name, description, code, author, created = os.epoch("utc") })
local DIR = "/os/templates"
local MAX_CODE = 32000

local M = { DIR = DIR }

function M.slug(name)
  local s = tostring(name or ""):lower():gsub("[^a-z0-9_%-]", "_"):sub(1, 32)
  return s
end

local function path(slug) return DIR .. "/" .. slug .. ".dat" end

local function load_(slug)
  local p = path(slug)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) ~= "table" or type(d.code) ~= "string" then return nil end
  return { slug = slug, name = tostring(d.name or slug), description = tostring(d.description or ""), code = d.code,
           author = d.author == "claude" and "claude" or "player", created = tonumber(d.created) or 0 }
end

function M.get(name)
  local s = M.slug(name)
  if s == "" then return nil end
  return load_(s)
end

function M.list()
  local out = {}
  if fs.isDir(DIR) then
    for _, f in ipairs(fs.list(DIR)) do
      local slug = f:match("^(.+)%.dat$")
      local t = slug and load_(slug)
      if t then
        out[#out + 1] = { slug = t.slug, name = t.name, description = t.description, author = t.author, created = t.created }
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

function M.save(t)
  if type(t) ~= "table" then return nil, "bad template" end
  local name = tostring(t.name or ""):gsub("%c", ""):sub(1, 40)
  local slug = M.slug(name)
  if not name:match("%S") or not slug:match("[a-z0-9]") then return nil, "the template needs a name" end
  local code = tostring(t.code or "")
  if not code:match("%S") then return nil, "the code is empty" end
  if #code > MAX_CODE then return nil, "the code is too long (max " .. MAX_CODE .. " characters)" end
  local fn, err = load(code, "=t", "t", {})
  if not fn then return nil, "syntax error: " .. tostring(err) end
  fs.makeDir(DIR)
  local f = fs.open(path(slug), "w")
  if not f then return nil, "can't write " .. path(slug) end
  f.write(textutils.serialize({ name = name, description = tostring(t.description or ""):sub(1, 400), code = code,
                                author = t.author == "claude" and "claude" or "player", created = os.epoch("utc") }))
  f.close()
  return slug
end

function M.delete(name)
  local p = path(M.slug(name))
  if not fs.exists(p) then return false end
  fs.delete(p)
  return true
end

return M
