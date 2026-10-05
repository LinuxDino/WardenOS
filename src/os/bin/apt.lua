-- apt: the WardenOS App Store in the terminal (packages from /os/lib/store.lua)
--   apt update | list [--installed|--upgradable] | search <text> | show <pkg> | install <pkg>... |
--   remove <pkg>... | purge <pkg>... | upgrade
local args = {}
for _, a in ipairs({ ... }) do
  if a ~= "-y" and a ~= "--yes" and a ~= "-q" then args[#args + 1] = a end
end
if args[1] == "sudo" then table.remove(args, 1) end    -- no root here: everybody is root

local W = term.getSize()
local color = term.isColour and term.isColour()
local function c(col) if color then term.setTextColor(col) end end

-- one line of colored pieces (too long for the screen: printed wrapped, in one color)
local function line(...)
  local parts, all = { ... }, ""
  for _, p in ipairs(parts) do all = all .. tostring(p[1]) end
  if #all > W then
    c(parts[1] and parts[1][2] or colors.white)
    print(all)
  else
    for _, p in ipairs(parts) do
      c(p[2] or colors.white)
      term.write(tostring(p[1]))
    end
    print()
  end
  c(colors.white)
end
local function say(s, col) c(col or colors.white) print(s) c(colors.white) end
local function err(s) say("E: " .. s, colors.red) end
local function warn(s) say("W: " .. s, colors.yellow) end
local function done(s) line({ s .. "... ", colors.white }, { "Done", colors.white }) end

local function wrapped(text, indent)
  local width = math.max(10, W - #indent)
  local cur = ""
  for word in tostring(text):gmatch("%S+") do
    if cur ~= "" and #cur + 1 + #word > width then say(indent .. cur) cur = word
    else cur = cur == "" and word or (cur .. " " .. word) end
  end
  if cur ~= "" then say(indent .. cur) end
end

local function kb(n)
  n = tonumber(n) or 0
  if n >= 1024 then return ("%.1f kB"):format(n / 1024) end
  return n .. " B"
end

local cmd = table.remove(args, 1)

---------------------------------------------------------------- help / moo (work without the store)
local function usage()
  say("apt 1.0 (WardenOS App Store)", colors.cyan)
  say("Usage: apt [sudo] command [packages]")
  print()
  say("Most used commands:")
  local rows = {
    { "list", "list packages (--installed, --upgradable)" },
    { "search", "search in package descriptions" },
    { "show", "show package details" },
    { "install", "install packages" },
    { "remove", "remove packages (purge: also their data)" },
    { "update", "update the list of available packages" },
    { "upgrade", "upgrade all installed packages" },
  }
  for _, r in ipairs(rows) do line({ "  " .. ("%-8s"):format(r[1]), colors.lime }, { " " .. r[2], colors.lightGray }) end
  print()
  say(("This APT has Super Cow Powers."):sub(1, W), colors.lightGray)
end

if not cmd or cmd == "help" or cmd == "-h" or cmd == "--help" then usage() return end

if cmd == "moo" then
  local n = 1
  for _, a in ipairs(args) do if a == "moo" then n = n + 1 end end
  local cow = {
    "                 (__)",
    "                 (oo)",
    "           /------\\/",
    "          / |    ||",
    "         *  /\\---/\\",
    "            ~~   ~~",
  }
  local msgs = {
    '..."Have you mooed today?"...',
    '..."Have you mooed twice today?"...',
    '..."Shh. The Warden can hear you mooing."...',
  }
  if W >= 22 then
    c(colors.white)
    for _, l in ipairs(cow) do print(l:sub(1, W)) end
  end
  say(msgs[math.min(n, #msgs)], n >= 3 and colors.cyan or colors.yellow)
  return
end

local okS, store = pcall(dofile, "/os/lib/store.lua")
if not okS or type(store) ~= "table" then err("the App Store library is missing (/os/lib/store.lua)") return end

local function source()
  local base, repo, branch = store.source()
  return ("https://raw.githubusercontent.com/%s %s"):format(repo, branch), base
end

-- the catalog: the saved one, or a fresh one when there is none yet
local function catalog()
  local list, msg, offline = store.catalog(false)
  if offline and msg then warn(msg) end
  return list
end
local function byId(list)
  local t = {}
  for _, p in ipairs(list) do t[p.id] = p end
  return t
end
local function installedMap()
  local t = {}
  for _, e in ipairs(store.installed()) do t[e.id] = e end
  return t
end
local function notUpgraded(list, inst, except)
  local n = 0
  for _, p in ipairs(list) do
    local e = inst[p.id]
    if e and store.newer(p.version, e.version) and not (except and except[p.id]) then n = n + 1 end
  end
  return n
end
local function summary(up, new, rem, notUp)
  say(("%d upgraded, %d newly installed, %d to remove and %d not upgraded."):format(up, new, rem, notUp))
end
local function readingLists()
  done("Reading package lists")
  done("Building dependency tree")
  done("Reading state information")
end

---------------------------------------------------------------- commands
local commands = {}

function commands.update()
  local src = source()
  line({ "Hit:1 ", colors.lime }, { src .. " InRelease", colors.white })
  local list, msg, offline = store.catalog(true)
  if offline then
    line({ "Err:2 ", colors.red }, { src .. " store/index.lua", colors.white })
    warn("Failed to fetch store/index.lua  " .. tostring(msg))
    if #list == 0 then err("Some index files failed to download. They have been ignored, or old ones used instead.") return end
  else
    local size = fs.exists(store.INDEX) and fs.getSize(store.INDEX) or 0
    line({ "Get:2 ", colors.lime }, { src .. " store/index.lua [" .. kb(size) .. "]", colors.white })
    say(("Fetched %s"):format(kb(size)))
  end
  readingLists()
  local n = #store.upgrades()
  if n > 0 then
    say(("%d package%s can be upgraded. Run 'apt list --upgradable' to see %s."):format(n, n == 1 and "" or "s",
      n == 1 and "it" or "them"))
  else
    say("All packages are up to date.")
  end
end

local function entry(p, inst)
  local e = inst[p.id]
  local tag = ""
  if e and store.newer(p.version, e.version) then tag = " [upgradable from: " .. e.version .. "]"
  elseif e then tag = " [installed]" end
  line({ p.id, colors.lime }, { "/stable ", colors.lightGray }, { p.version .. " " .. p.kind, colors.white },
       { tag, colors.yellow })
end

function commands.list()
  local list, inst = catalog(), installedMap()
  local mode, pat
  for _, a in ipairs(args) do
    if a == "--installed" then mode = "installed"
    elseif a == "--upgradable" or a == "--upgradeable" then mode = "upgradable"
    elseif a:sub(1, 1) ~= "-" then pat = a:lower():gsub("%*", "") end
  end
  say("Listing... Done")
  local seen = {}
  for _, p in ipairs(list) do
    local e = inst[p.id]
    seen[p.id] = true
    local ok = (not mode) or (mode == "installed" and e) or (mode == "upgradable" and e and store.newer(p.version, e.version))
    if ok and (not pat or p.id:find(pat, 1, true)) then entry(p, inst) end
  end
  if mode ~= "upgradable" then
    for id, e in pairs(inst) do
      if not seen[id] and (not pat or id:find(pat, 1, true)) then
        line({ id, colors.lime }, { "/now ", colors.lightGray }, { e.version, colors.white },
             { " [installed,local]", colors.yellow })
      end
    end
  end
end

function commands.search()
  if #args == 0 then err("You must give at least one search pattern") return end
  local list, inst = catalog(), installedMap()
  done("Sorting")
  done("Full Text Search")
  for _, p in ipairs(list) do
    local hay = (p.id .. " " .. p.name .. " " .. p.description):lower()
    local all = true
    for _, a in ipairs(args) do if not hay:find(a:lower(), 1, true) then all = false end end
    if all then
      entry(p, inst)
      wrapped(p.summary ~= "" and p.summary or p.description, "  ")
      print()
    end
  end
end

function commands.show()
  if #args == 0 then err("No packages found") return end
  local list, inst = catalog(), installedMap()
  local ids = byId(list)
  for i, id in ipairs(args) do
    local p = ids[id:lower()]
    if not p then
      say("N: Unable to locate package " .. id, colors.yellow)
      err("No packages found")
    else
      if i > 1 then print() end
      local function field(k, v) line({ k .. ": ", colors.cyan }, { tostring(v), colors.white }) end
      field("Package", p.id)
      field("Version", p.version)
      field("Priority", "optional")
      field("Section", p.kind == "command" and "utils" or (p.category == "game" and "games" or "tools"))
      field("Maintainer", p.author)
      field("Installed-Size", kb(p.size))
      if p.requires then field("Depends", "wardenos (>= " .. p.requires .. ")") end
      field("APT-Sources", source())
      local e = inst[p.id]
      field("Status", e and ("installed " .. e.version) or "not installed")
      local files = {}
      for _, f in ipairs(p.files) do files[#files + 1] = f.to end
      c(colors.cyan) write("Files:") c(colors.white) print()
      for _, f in ipairs(files) do say((" " .. f):sub(1, W)) end
      c(colors.cyan) write("Description: ") c(colors.white) print()
      wrapped(p.description, " ")
    end
  end
end

-- install / upgrade the given packages (p, upgrade?) with apt-style output
local function deploy(todo, list, inst)
  local total = 0
  for _, t in ipairs(todo) do total = total + t[1].size end
  if total > 0 then
    say(("Need to get %s of archives."):format(kb(total)))
    say(("After this operation, %s of additional disk space will be used."):format(kb(total)))
  end
  local src = source()
  for i, t in ipairs(todo) do
    local p = t[1]
    line({ ("Get:%d "):format(i), colors.lime }, { ("%s %s %s [%s]"):format(src, p.id, p.version, kb(p.size)), colors.white })
  end
  local failed = 0
  for _, t in ipairs(todo) do
    local p = t[1]
    if t[2] then say(("Preparing to unpack %s (%s) over (%s) ..."):format(p.id, p.version, inst[p.id].version))
    else say(("Selecting previously unselected package %s."):format(p.id)) end
    say(("Unpacking %s (%s) ..."):format(p.id, p.version))
    local ok, msg
    if t[2] then ok, msg = store.update(p.id) else ok, msg = store.install(p.id) end
    if ok then
      say(("Setting up %s (%s) ..."):format(p.id, p.version))
      if p.kind == "command" then
        local name = (p.files[1] and p.files[1].to or ""):match("^/os/bin/(.-)%.lua$")
        if name then say("  run it with: " .. name, colors.lightGray) end
      else
        say("  open it from Apps (the App Store app)", colors.lightGray)
      end
    else
      failed = failed + 1
      err(("Sub-process failed for %s: %s"):format(p.id, tostring(msg)))
    end
  end
  if failed > 0 then err(("%d package%s could not be installed."):format(failed, failed == 1 and "" or "s")) end
end

function commands.install()
  if #args == 0 then
    readingLists()
    summary(0, 0, 0, 0)
    return
  end
  local list = catalog()
  local ids, inst = byId(list), installedMap()
  -- not in the saved catalog: maybe it is new, refresh once
  for _, id in ipairs(args) do
    if not ids[id:lower()] then
      list = store.catalog(true)
      ids = byId(list)
      break
    end
  end
  readingLists()
  local todo, new, up, missing, picked = {}, {}, {}, false, {}
  for _, id in ipairs(args) do
    local p = ids[id:lower()]
    if not p then
      err("Unable to locate package " .. id)
      missing = true
    elseif not picked[p.id] then
      picked[p.id] = true
      local e = inst[p.id]
      if e and not store.newer(p.version, e.version) then
        say(("%s is already the newest version (%s)."):format(p.id, e.version))
      else
        todo[#todo + 1] = { p, e ~= nil }
        if e then up[#up + 1] = p.id else new[#new + 1] = p.id end
      end
    end
  end
  if missing then return end
  if #new > 0 then
    say("The following NEW packages will be installed:")
    wrapped(table.concat(new, " "), "  ")
  end
  if #up > 0 then
    say("The following packages will be upgraded:")
    wrapped(table.concat(up, " "), "  ")
  end
  summary(#up, #new, 0, notUpgraded(list, inst, picked))
  if #todo > 0 then deploy(todo, list, inst) end
end

local function removeCmd(purge)
  local list = catalog()
  local inst = installedMap()
  readingLists()
  local gone, freed, sizes = {}, 0, byId(list)
  for _, id in ipairs(args) do
    id = id:lower()
    if inst[id] then
      gone[#gone + 1] = id
      freed = freed + (sizes[id] and sizes[id].size or 0)
    elseif sizes[id] then
      say(("Package '%s' is not installed, so not removed"):format(id))
    else
      err("Unable to locate package " .. id)
      return
    end
  end
  if #gone > 0 then
    say("The following packages will be REMOVED:")
    wrapped(table.concat(gone, purge and "* " or " ") .. (purge and "*" or ""), "  ")
  end
  summary(0, 0, #gone, notUpgraded(list, inst))
  if #gone == 0 then return end
  if freed > 0 then say(("After this operation, %s disk space will be freed."):format(kb(freed))) end
  for _, id in ipairs(gone) do
    say(("Removing %s (%s) ..."):format(id, inst[id].version))
    local ok, msg = store.remove(id, { purge = purge })
    if not ok then err(msg)
    elseif purge then say(("Purging configuration files for %s (%s) ..."):format(id, inst[id].version)) end
  end
end
function commands.remove() removeCmd(false) end
function commands.purge() removeCmd(true) end
commands.uninstall = commands.remove

function commands.upgrade()
  local list = catalog()
  local inst = installedMap()
  done("Reading package lists")
  done("Building dependency tree")
  done("Calculating upgrade")
  local todo, names = {}, {}
  for _, p in ipairs(list) do
    local e = inst[p.id]
    if e and store.newer(p.version, e.version) then todo[#todo + 1] = { p, true } names[#names + 1] = p.id end
  end
  if #todo == 0 then summary(0, 0, 0, 0) return end
  say("The following packages will be upgraded:")
  wrapped(table.concat(names, " "), "  ")
  summary(#todo, 0, 0, 0)
  deploy(todo, list, inst)
end
commands["full-upgrade"] = commands.upgrade
commands["dist-upgrade"] = commands.upgrade

local fn = commands[cmd]
if not fn then
  err("Invalid operation " .. tostring(cmd))
  return
end
fn()
