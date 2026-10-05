-- App Store backend: the package catalog from GitHub, install / remove / update, used by the Store app and `apt`.
--   local store = dofile("/os/lib/store.lua")
--   store.catalog(refresh)        list, message, offline   (cached in /os/store/index; refresh = fetch from GitHub)
--   store.find(id)                package | nil            (from the cached catalog, or a fresh one when there is none)
--   store.installed()             { {id, name, kind, version, files, dirs, at}, ... } sorted by id
--   store.status(id)              nil | "installed" | "update"
--   store.install(id, progress)   ok, message              progress(text, fraction) is called while it works
--   store.update(id, progress)    ok, message
--   store.remove(id, opts)        ok, message              opts.purge also deletes /os/data/<id>
--   store.upgrades()              { {id, name, from, to}, ... }
--   store.newer(a, b)             true when version a > version b
-- Catalog (store/index.lua in the repository):
--   return { version = 1, packages = { { id, name, kind = "app" | "command", category, version, author, description,
--     size, icon, color, art, featured, requires, files = { { from = "store/packages/<id>/x.lua", to = "/os/..." } } } } }
-- Packages may only write /os/apps/*.lua, /os/bin/*.lua and /os/data/<id>/..., never a file of the OS itself.
-- After a change it queues "os_apps_changed" (when an app was added or removed) and always "os_toast" with the message.
local M = {}

local DIR = "/os/store"
local INDEX, DB = DIR .. "/index", DIR .. "/installed"
M.DIR, M.INDEX, M.DB = DIR, INDEX, DB

-- files that always belong to the OS, even when /os/files.dat is missing
local CORE = { "/startup.lua", "/os/config.lua", "/os/boot.lua", "/os/kernel.lua", "/os/users.dat", "/os/files.dat",
  "/os/settings.lua", "/os/boot.cfg" }

---------------------------------------------------------------- small helpers
local function readFile(p)
  if not fs.exists(p) or fs.isDir(p) then return nil end
  local f = fs.open(p, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function writeFile(p, data)
  local dir = fs.getDir(p)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(p, "w")
  if not f then return false end
  f.write(data)
  f.close()
  return true
end

local function toast(msg)
  os.queueEvent("os_toast", msg)
end

function M.newer(a, b)
  local function parts(v)
    local t = {}
    for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
  end
  local x, y = parts(a), parts(b)
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return false
end

local function osInfo()
  local W = rawget(_G, "WardenOS")
  local repo, branch, version = "LinuxDino/WardenOS", "main", nil
  local ok, cfg = pcall(dofile, "/os/config.lua")
  if ok and type(cfg) == "table" then
    repo, branch, version = cfg.repo or repo, cfg.branch or branch, cfg.version
  end
  if type(W) == "table" then
    repo, branch, version = W.repo or repo, W.branch or branch, W.version or version
  end
  return tostring(repo), tostring(branch), version and tostring(version)
end

function M.source()
  local repo, branch = osInfo()
  return ("https://raw.githubusercontent.com/%s/%s/"):format(repo, branch), repo, branch
end

-- GET a file of the repository; 3 tries. body | nil, error
local function fetch(path)
  if not http then return nil, "the http API is disabled" end
  local url = M.source() .. path .. "?t=" .. tostring(os.epoch("utc"))
  local last
  for try = 1, 3 do
    local ok, h, err, resp = pcall(http.get, url, nil, true)
    if not ok then
      last = tostring(h)
    elseif h then
      local code = h.getResponseCode and h.getResponseCode() or 200
      local body = h.readAll()
      h.close()
      if code == 200 and body then return body end
      last = "HTTP " .. tostring(code)
    elseif resp then
      last = "HTTP " .. tostring(resp.getResponseCode and resp.getResponseCode() or "?")
      pcall(resp.close)
    else
      last = tostring(err or "request failed")
    end
    if last:find("HTTP 404") then break end          -- not there: retrying won't help
    if try < 3 then sleep(try * 0.5) end
  end
  return nil, last
end
M.fetch = fetch

---------------------------------------------------------------- catalog
local function validPath(p)
  return type(p) == "string" and not p:find("%.%.") and p:match("^[%w_%-%./]+$") ~= nil and not p:find("//", 1, true)
end

-- where a package may write: /os/apps/<name>.lua, /os/bin/<name>.lua, /os/data/<id>/...
local function allowedTarget(id, to)
  if not validPath(to) then return false end
  if to:match("^/os/apps/[%w_%-]+%.lua$") or to:match("^/os/bin/[%w_%-]+%.lua$") then return true end
  local prefix = "/os/data/" .. id .. "/"
  return to:sub(1, #prefix) == prefix and #to > #prefix and to:sub(-1) ~= "/"
end

local function clean(p)
  if type(p) ~= "table" then return nil end
  local id = type(p.id) == "string" and p.id:lower() or ""
  if not id:match("^[a-z0-9_%-]+$") or #id > 24 then return nil end
  if p.kind ~= "app" and p.kind ~= "command" then return nil end
  if type(p.files) ~= "table" or #p.files == 0 then return nil end
  local files = {}
  for _, f in ipairs(p.files) do
    if type(f) ~= "table" or not validPath(f.from) or not validPath(f.to) then return nil end
    files[#files + 1] = { from = f.from, to = f.to }
  end
  local art
  if type(p.art) == "table" and #p.art == 2 then
    art = {}
    for i = 1, 2 do
      local r = p.art[i]
      if type(r) ~= "table" or type(r[1]) ~= "string" or type(r[2]) ~= "string" or type(r[3]) ~= "string"
         or #r[1] ~= 4 or not r[2]:match("^[0-9a-f]+$") or not r[3]:match("^[0-9a-f]+$") or #r[2] ~= 4 or #r[3] ~= 4 then
        art = nil
        break
      end
      art[i] = { r[1], r[2], r[3] }
    end
  end
  local s = function(v, d) return type(v) == "string" and v or d end
  return {
    id = id, kind = p.kind, files = files, art = art,
    name = s(p.name, id):sub(1, 30),
    category = s(p.category, p.kind == "command" and "command" or "tool"),
    version = s(p.version, "0"),
    author = s(p.author, "unknown"),
    description = s(p.description, ""),
    summary = s(p.summary, (s(p.description, ""):match("^[^%.!?]*[%.!?]?") or "")),
    icon = s(p.icon, "?"):sub(1, 3),
    color = type(p.color) == "string" and colors[p.color] or (type(p.color) == "number" and p.color) or colors.white,
    size = tonumber(p.size) or 0,
    featured = p.featured == true,
    requires = p.requires and tostring(p.requires) or nil,
  }
end

local function parse(src)
  if type(src) ~= "string" then return nil, "no catalog" end
  local fn, err = load(src, "=index", "t", {})
  if not fn then return nil, "broken catalog: " .. tostring(err) end
  local ok, d = pcall(fn)
  if not ok or type(d) ~= "table" or type(d.packages) ~= "table" then return nil, "broken catalog" end
  local list, seen = {}, {}
  for _, p in ipairs(d.packages) do
    local c = clean(p)
    if c and not seen[c.id] then list[#list + 1] = c seen[c.id] = true end
  end
  return list
end

local cache                                     -- last parsed catalog (this session)

-- list, message, offline
function M.catalog(refresh)
  if not refresh and cache then return cache, nil, false end
  local src = readFile(INDEX)
  if refresh or not src then
    local body, err = fetch("store/index.lua")
    if body then
      local list, perr = parse(body)
      if list then
        writeFile(INDEX, body)
        cache = list
        return list, ("%d packages"):format(#list), false
      end
      err = perr
    end
    local old = parse(src)
    if old then
      cache = old
      return old, "offline (" .. tostring(err) .. "): showing the saved catalog", true
    end
    return {}, "can't load the catalog: " .. tostring(err), true
  end
  local list, perr = parse(src)
  if not list then return M.catalog(true) end
  cache = list
  return list, nil, false
end

function M.find(id, refresh)
  id = tostring(id or ""):lower()
  for _, p in ipairs((M.catalog(refresh))) do if p.id == id then return p end end
  return nil
end

---------------------------------------------------------------- installed packages
local function loadDb()
  local s = readFile(DB)
  local d = s and textutils.unserialize(s)
  if type(d) ~= "table" then d = {} end
  for id, e in pairs(d) do
    if type(e) ~= "table" or type(e.files) ~= "table" then d[id] = nil end
  end
  return d
end

local function saveDb(d)
  return writeFile(DB, textutils.serialize(d))
end

function M.installed()
  local out = {}
  for id, e in pairs(loadDb()) do
    out[#out + 1] = { id = id, name = e.name or id, kind = e.kind, version = tostring(e.version or "0"),
                      files = e.files, dirs = e.dirs or {}, at = e.at }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.status(id)
  local e = loadDb()[id]
  if not e then return nil end
  local p
  for _, q in ipairs(cache or {}) do if q.id == id then p = q end end
  if p and M.newer(p.version, e.version) then return "update" end
  return "installed"
end

function M.upgrades()
  local out = {}
  local list = M.catalog()
  local db = loadDb()
  for _, p in ipairs(list) do
    local e = db[p.id]
    if e and M.newer(p.version, e.version) then
      out[#out + 1] = { id = p.id, name = p.name, from = tostring(e.version), to = p.version }
    end
  end
  return out
end

-- every path that belongs to the OS: /os/files.dat (written by the installer), the manifest, core files
local manifestCache
local function osFiles()
  local set = {}
  for _, p in ipairs(CORE) do set[p] = true end
  local s = readFile("/os/files.dat")
  local d = s and textutils.unserialize(s)
  if type(d) == "table" and type(d.files) == "table" then
    for _, p in ipairs(d.files) do if type(p) == "string" then set[p] = true end end
  end
  if manifestCache == nil then
    manifestCache = false
    local body = fetch("manifest.lua")
    local fn = body and load(body, "=manifest", "t", {})
    local ok, m = pcall(fn or error)
    if ok and type(m) == "table" and type(m.files) == "table" then
      manifestCache = {}
      for _, p in ipairs(m.files) do if type(p) == "string" then manifestCache[#manifestCache + 1] = "/" .. p end end
    end
  end
  for _, p in ipairs(manifestCache or {}) do set[p] = true end
  return set
end

local function finish(ok, msg, appsChanged)
  if appsChanged then os.queueEvent("os_apps_changed") end
  toast(msg)
  return ok, msg
end

local function isApp(path) return path:match("^/os/apps/") ~= nil end

---------------------------------------------------------------- install / update
local function deploy(p, progress, upgrading)
  progress = progress or function() end
  local db = loadDb()
  local own = db[p.id]
  if own and not upgrading then return false, p.name .. " is already installed" end

  -- 1. this OS is new enough
  local _, _, osv = osInfo()
  if p.requires and osv and M.newer(p.requires, osv) then
    return false, ("%s needs WardenOS %s or newer"):format(p.name, p.requires)
  end

  -- 2. every target is allowed, not an OS file, not someone else's
  progress("Checking " .. p.name, 0)
  local protected = osFiles()
  local mine = {}
  if own then for _, f in ipairs(own.files) do mine[f] = true end end
  local owner = {}
  for id, e in pairs(db) do
    if id ~= p.id then for _, f in ipairs(e.files) do owner[f] = id end end
  end
  local targets = {}
  for _, f in ipairs(p.files) do
    if not f.from:match("^store/packages/") then return false, "bad source path " .. f.from end
    if not allowedTarget(p.id, f.to) then return false, "refused: " .. p.name .. " wants to write " .. f.to end
    if protected[f.to] then return false, "refused: " .. f.to .. " is a WardenOS file" end
    if owner[f.to] then return false, ("refused: %s belongs to %s"):format(f.to, owner[f.to]) end
    if targets[f.to] then return false, "refused: " .. f.to .. " listed twice" end
    if fs.exists(f.to) and not mine[f.to] then return false, "refused: " .. f.to .. " already exists" end
    targets[f.to] = true
  end

  -- 3. download everything and syntax-check every Lua file before anything is written
  local data = {}
  for i, f in ipairs(p.files) do
    progress(("Downloading %d/%d"):format(i, #p.files), (i - 1) / (#p.files + 1))
    local body, err = fetch(f.from)
    if not body then return false, ("download failed: %s (%s)"):format(f.from, tostring(err)) end
    if f.to:sub(-4) == ".lua" then
      local fn, lerr = load(body, "=" .. f.to, "t", {})
      if not fn then return false, "broken file in " .. p.name .. ": " .. tostring(lerr) end
    end
    data[i] = body
  end

  -- 4. write (with rollback on a disk error)
  progress("Installing", #p.files / (#p.files + 1))
  local created = {}
  local dirs = own and own.dirs and { table.unpack(own.dirs) } or {}
  local known = {}
  for _, d in ipairs(dirs) do known[d] = true end
  local backup = {}
  for i, f in ipairs(p.files) do
    local dir, chain = fs.getDir(f.to), {}
    while dir ~= "" and not fs.exists("/" .. dir) do
      table.insert(chain, 1, "/" .. dir)
      dir = fs.getDir(dir)
    end
    for _, d in ipairs(chain) do if not known[d] then known[d] = true dirs[#dirs + 1] = d end end
    if fs.exists(f.to) then backup[f.to] = readFile(f.to) end
    local ok = pcall(writeFile, f.to, data[i])
    if not ok or readFile(f.to) ~= data[i] then
      for _, w in ipairs(created) do
        if backup[w] then pcall(writeFile, w, backup[w]) else pcall(fs.delete, w) end
      end
      if backup[f.to] then pcall(writeFile, f.to, backup[f.to]) else pcall(fs.delete, f.to) end
      return false, "can't write " .. f.to .. " (disk full?)"
    end
    created[#created + 1] = f.to
  end

  -- files of the old version that the new one no longer has
  local appsChanged = false
  if own then
    for _, old in ipairs(own.files) do
      if not targets[old] and fs.exists(old) then
        fs.delete(old)
        if isApp(old) then appsChanged = true end
      end
    end
  end
  for _, f in ipairs(p.files) do if isApp(f.to) then appsChanged = true end end

  local files = {}
  for _, f in ipairs(p.files) do files[#files + 1] = f.to end
  db[p.id] = { name = p.name, kind = p.kind, version = p.version, files = files, dirs = dirs, at = os.epoch("utc") }
  saveDb(db)
  progress("Done", 1)
  return true, nil, appsChanged
end

local function lookup(id)
  id = tostring(id or ""):lower()
  local list = M.catalog()
  for _, p in ipairs(list) do if p.id == id then return p end end
  list = M.catalog(true)                       -- not in the saved catalog: maybe it is new
  for _, p in ipairs(list) do if p.id == id then return p end end
  return nil
end

function M.install(id, progress)
  local p = lookup(id)
  if not p then return finish(false, "Unknown package: " .. tostring(id)) end
  local ok, err, apps = deploy(p, progress, false)
  if not ok then return finish(false, err) end
  return finish(true, ("Installed %s %s"):format(p.name, p.version), apps)
end

function M.update(id, progress)
  local e = loadDb()[tostring(id or ""):lower()]
  if not e then return finish(false, tostring(id) .. " is not installed") end
  local p = lookup(id)
  if not p then return finish(false, "Unknown package: " .. tostring(id)) end
  if not M.newer(p.version, e.version) then return finish(true, ("%s is up to date (%s)"):format(p.name, e.version)) end
  local ok, err, apps = deploy(p, progress, true)
  if not ok then return finish(false, err) end
  return finish(true, ("Updated %s to %s"):format(p.name, p.version), apps)
end

---------------------------------------------------------------- remove
function M.remove(id, opts)
  id = tostring(id or ""):lower()
  local db = loadDb()
  local e = db[id]
  if not e then return finish(false, id .. " is not installed") end
  local apps = false
  for _, f in ipairs(e.files) do
    if type(f) == "string" and validPath(f) and fs.exists(f) and not fs.isDir(f) then
      fs.delete(f)
      if isApp(f) then apps = true end
    end
  end
  if opts and opts.purge and fs.isDir("/os/data/" .. id) then fs.delete("/os/data/" .. id) end
  -- directories it created, deepest first, only when empty
  local dirs = {}
  for _, d in ipairs(e.dirs or {}) do if type(d) == "string" and validPath(d) then dirs[#dirs + 1] = d end end
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, d in ipairs(dirs) do
    if fs.isDir(d) and #fs.list(d) == 0 then fs.delete(d) end
  end
  db[id] = nil
  saveDb(db)
  return finish(true, ("Removed %s"):format(e.name or id), apps)
end

return M
