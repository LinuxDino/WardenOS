-- Warden GPS helpers: accurate locating and constellation checks. No WardenOS dependencies, so it also works on a
-- plain computer or a turtle (dofile it, or copy it next to the program).
--
--   G.CHANNEL                      the CC GPS channel (gps.CHANNEL_GPS, 65534)
--   G.modem([side])                name of a wireless (or ender) modem, or nil
--   G.ping(opts)                   -> fixes, or nil + reason. Sends one GPS "PING" and collects EVERY reply until
--                                  opts.timeout (default 1 s): { { x, y, z, d }, ... } (d = distance to that host).
--                                  Hosts that `gps host` and Warden GPS hosts both answer. opts.modem = side,
--                                  opts.other(ev) gets every other event meanwhile (nothing is lost).
--   G.solve(fixes)                 -> { x, y, z } (unrounded), info. Least squares over ALL hosts (vanilla
--                                  gps.locate uses the first 4); info = { used, residual, ambiguous, bad = { fix } }.
--                                  A host whose coordinates are wrong shows up in info.bad (with 5+ hosts).
--   G.consensus(points, tol)       -> { x, y, z, agree, spread }: median of the points, outliers (> tol blocks from
--                                  the median, default 0.5) rejected, the rest averaged
--   G.locate(opts)                 -> result, or nil + reason. opts.samples pings (default 3), each solved, outliers
--                                  rejected. result = { x, y, z (rounded), raw = { x, y, z }, samples, tried, agree,
--                                  spread, hosts, residual, offGrid, bad = { fix }, fixes, quality }; quality is
--                                  "exact" | "good" | "noisy". opts.vanilla = true: use gps.locate() samples instead.
--   G.analyze(hosts)               -> constellation report for { { x, y, z, ... } }: { n, score 0-100, grade,
--                                  coplanar, collinear, shape, minSep, maxSep, minY, dups, advice = { text } }
local G = {}
G.CHANNEL = (type(gps) == "table" and gps.CHANNEL_GPS) or 65534

local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local function round(v) return floor(v + 0.5) end
G.round = round

---------------------------------------------------------------- modem + ping
function G.modem(side)
  local function wireless(n)
    if peripheral.getType(n) ~= "modem" then return false end
    local ok, w = pcall(peripheral.call, n, "isWireless")
    return ok and w == true
  end
  if side then return wireless(side) and side or nil end
  for _, n in ipairs(peripheral.getNames()) do
    if wireless(n) then return n end
  end
  return nil
end

function G.ping(opts)
  opts = opts or {}
  local side = G.modem(opts.modem)
  if not side then return nil, "no wireless or ender modem" end
  local opened = false
  local okc, isOpen = pcall(peripheral.call, side, "isOpen", G.CHANNEL)
  if not (okc and isOpen) then
    if not pcall(peripheral.call, side, "open", G.CHANNEL) then return nil, "cannot open the GPS channel" end
    opened = true
  end
  local timer = os.startTimer(opts.timeout or 1)
  pcall(peripheral.call, side, "transmit", G.CHANNEL, G.CHANNEL, "PING")
  local fixes, seen = {}, {}
  while true do
    local ev = table.pack(os.pullEvent())
    local e = ev[1]
    if e == "modem_message" and ev[2] == side and ev[3] == G.CHANNEL and type(ev[5]) == "table"
        and type(ev[6]) == "number" then
      local m = ev[5]
      local x, y, z = tonumber(m[1]), tonumber(m[2]), tonumber(m[3])
      if x and y and z then
        local key = ("%s,%s,%s,%s"):format(x, y, z, ev[6])
        if not seen[key] then
          seen[key] = true
          fixes[#fixes + 1] = { x = x, y = y, z = z, d = ev[6] }
        end
      end
    elseif e == "timer" and ev[2] == timer then
      break
    elseif opts.other then
      pcall(opts.other, ev)
    end
  end
  if opened then pcall(peripheral.call, side, "close", G.CHANNEL) end
  return fixes
end

---------------------------------------------------------------- math
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function len(a) return sqrt(dot(a, a)) end
local function vec(p) return { p.x or p[1], p.y or p[2], p.z or p[3] } end
local function det3(m)
  return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
       - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
       + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
end

local function residuals(p, pts, ds)
  local sum, worst = 0, 0
  for i = 1, #pts do
    local r = abs(len(sub(p, pts[i])) - ds[i])
    sum = sum + r * r
    if r > worst then worst = r end
  end
  return sqrt(sum / #pts), worst
end

-- positions relative to the first host (keeps the numbers small: far from spawn squares would lose precision)
local function solveRaw(fixes)
  local n = #fixes
  if n < 3 then return nil, { used = n, reason = "need 3 or more GPS hosts (heard " .. n .. ")" } end
  local o = vec(fixes[1])
  local pts, ds = {}, {}
  for i, f in ipairs(fixes) do pts[i] = sub(vec(f), o) ds[i] = f.d end
  -- |x - p_i|^2 - |x - p_1|^2 = d_i^2 - d_1^2, p_1 = 0  ->  2 p_i . x = |p_i|^2 - d_i^2 + d_1^2
  local A, b = {}, {}
  for i = 2, n do
    A[#A + 1] = { 2 * pts[i][1], 2 * pts[i][2], 2 * pts[i][3] }
    b[#b + 1] = dot(pts[i], pts[i]) - ds[i] * ds[i] + ds[1] * ds[1]
  end
  local N = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  local v = { 0, 0, 0 }
  for r = 1, #A do
    for i = 1, 3 do
      v[i] = v[i] + A[r][i] * b[r]
      for j = 1, 3 do N[i][j] = N[i][j] + A[r][i] * A[r][j] end
    end
  end
  local D = det3(N)
  local tr = N[1][1] + N[2][2] + N[3][3]
  local info = { used = n }
  local p
  if tr > 0 and abs(D) > 1e-9 * tr * tr * tr then
    p = {}
    for k = 1, 3 do                               -- Cramer's rule
      local M = { { N[1][1], N[1][2], N[1][3] }, { N[2][1], N[2][2], N[2][3] }, { N[3][1], N[3][2], N[3][3] } }
      for r = 1, 3 do M[r][k] = v[r] end
      p[k] = det3(M) / D
    end
  else
    -- every host in one plane: solve inside the plane, then step off it by the leftover distance (two mirror fixes)
    local bestN, bestL = nil, 0
    for i = 2, n do
      for j = i + 1, n do
        local c = cross(pts[i], pts[j])
        local l = len(c)
        if l > bestL then bestN, bestL = c, l end
      end
    end
    if not bestN or bestL < 1e-6 then
      info.reason = "all GPS hosts are on one line"
      return nil, info
    end
    local nz = { bestN[1] / bestL, bestN[2] / bestL, bestN[3] / bestL }
    local u
    for i = 2, n do if len(pts[i]) > 1e-6 then u = pts[i] break end end
    local ul = len(u)
    u = { u[1] / ul, u[2] / ul, u[3] / ul }
    local w = cross(nz, u)
    local a11, a12, a22, c1, c2 = 0, 0, 0, 0, 0
    for r = 1, #A do
      local au, aw = dot(A[r], u), dot(A[r], w)
      a11, a12, a22 = a11 + au * au, a12 + au * aw, a22 + aw * aw
      c1, c2 = c1 + au * b[r], c2 + aw * b[r]
    end
    local d2 = a11 * a22 - a12 * a12
    if abs(d2) < 1e-12 then
      info.reason = "all GPS hosts are on one line"
      return nil, info
    end
    local s, t = (c1 * a22 - c2 * a12) / d2, (a11 * c2 - a12 * c1) / d2
    local base = { s * u[1] + t * w[1], s * u[2] + t * w[2], s * u[3] + t * w[3] }
    local h2 = ds[1] * ds[1] - dot(base, base)
    local h = h2 > 0 and sqrt(h2) or 0
    p = { base[1] + h * nz[1], base[2] + h * nz[2], base[3] + h * nz[3] }
    if h > 0.5 then
      info.ambiguous = true
      info.reason = "the GPS hosts are all in one plane: two mirror positions fit"
      local q = { base[1] - h * nz[1], base[2] - h * nz[2], base[3] - h * nz[3] }
      info.mirror = { x = q[1] + o[1], y = q[2] + o[2], z = q[3] + o[3] }
    end
  end
  info.residual, info.worst = residuals(p, pts, ds)
  return { x = p[1] + o[1], y = p[2] + o[2], z = p[3] + o[3] }, info
end

function G.solve(fixes)
  local p, info = solveRaw(fixes)
  if not p then return nil, info end
  info.bad = {}
  if info.worst > 0.5 and #fixes >= 5 then
    -- someone lies (wrong coordinates in a host): find the one host whose removal makes the rest agree
    local best, bestInfo, bestK
    for k = 1, #fixes do
      local rest = {}
      for i, f in ipairs(fixes) do if i ~= k then rest[#rest + 1] = f end end
      local q, qi = solveRaw(rest)
      if q and not qi.ambiguous and qi.worst < 0.1 and (not bestInfo or qi.worst < bestInfo.worst) then
        best, bestInfo, bestK = q, qi, k
      end
    end
    if best then
      local bad = fixes[bestK]
      local off = abs(len(sub(vec(bad), { best.x, best.y, best.z })) - bad.d)
      bestInfo.bad = { { x = bad.x, y = bad.y, z = bad.z, d = bad.d, off = off } }
      return best, bestInfo
    end
  end
  return p, info
end

local function median(t)
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  local n = #s
  if n % 2 == 1 then return s[(n + 1) / 2] end
  return (s[n / 2] + s[n / 2 + 1]) / 2
end

function G.consensus(points, tol)
  tol = tol or 0.5
  if #points == 0 then return nil end
  local xs, ys, zs = {}, {}, {}
  for i, p in ipairs(points) do xs[i], ys[i], zs[i] = p.x, p.y, p.z end
  local m = { median(xs), median(ys), median(zs) }
  local kept, spread = {}, 0
  for _, p in ipairs(points) do
    local d = len(sub({ p.x, p.y, p.z }, m))
    if d <= tol then kept[#kept + 1] = p end
  end
  if #kept == 0 then kept = { { x = m[1], y = m[2], z = m[3] } } end
  local sx, sy, sz = 0, 0, 0
  for _, p in ipairs(kept) do sx, sy, sz = sx + p.x, sy + p.y, sz + p.z end
  local c = { x = sx / #kept, y = sy / #kept, z = sz / #kept }
  for _, p in ipairs(points) do
    local d = len(sub({ p.x, p.y, p.z }, { c.x, c.y, c.z }))
    if d > spread then spread = d end
  end
  c.agree, c.spread = #kept, spread
  return c
end

function G.locate(opts)
  opts = opts or {}
  local n = math.max(1, opts.samples or 3)
  local sols, bad, badSeen = {}, {}, {}
  local hosts, why, fixes, resid = 0, nil, nil, 0
  for _ = 1, n do
    if opts.vanilla then
      local x, y, z = gps.locate(opts.timeout or 2)
      if x then sols[#sols + 1] = { x = x, y = y, z = z } else why = "no GPS fix" end
    else
      local f, err = G.ping(opts)
      if not f then return nil, err end
      fixes = f
      if #f > hosts then hosts = #f end
      local p, info = G.solve(f)
      if p and not info.ambiguous then
        sols[#sols + 1] = p
        if info.residual > resid then resid = info.residual end
        for _, b in ipairs(info.bad or {}) do
          local key = b.x .. "," .. b.y .. "," .. b.z
          if not badSeen[key] then badSeen[key] = true bad[#bad + 1] = b end
        end
      else
        why = info.reason or "no GPS fix"
      end
    end
  end
  if #sols == 0 then
    if hosts == 0 and not opts.vanilla then why = "no GPS hosts in range" end
    return nil, why or "no GPS fix"
  end
  local c = G.consensus(sols, opts.tolerance or 0.5)
  local r = { x = round(c.x), y = round(c.y), z = round(c.z), raw = { x = c.x, y = c.y, z = c.z },
              samples = #sols, tried = n, agree = c.agree, spread = c.spread, hosts = hosts, residual = resid,
              bad = bad, fixes = fixes }
  r.offGrid = math.max(abs(c.x - r.x), abs(c.y - r.y), abs(c.z - r.z))
  if c.agree == #sols and #sols == n and r.offGrid < 0.05 and resid < 0.05 and #bad == 0 then
    r.quality = "exact"
  elseif c.agree * 2 > #sols and r.offGrid < 0.25 then
    r.quality = "good"
  else
    r.quality = "noisy"
  end
  return r
end

---------------------------------------------------------------- constellation check
function G.analyze(hosts)
  local pts = {}
  for _, h in ipairs(hosts or {}) do
    local x, y, z = tonumber(h.x), tonumber(h.y), tonumber(h.z)
    if x and y and z then pts[#pts + 1] = { x, y, z, h = h } end
  end
  local n = #pts
  local r = { n = n, advice = {}, score = 0, grade = "none", dups = {} }
  local function say(s) r.advice[#r.advice + 1] = s end
  if n == 0 then
    say("No GPS hosts found. Run the installer on a computer with a wireless or ender modem and choose GPS host.")
    return r
  end
  local cap = math.min(n, 12)                   -- geometry over at most 12 hosts (enough to judge the shape)
  local minSep, maxSep, minY = math.huge, 0, math.huge
  for i = 1, n do
    if pts[i][2] < minY then minY = pts[i][2] end
    for j = i + 1, n do
      local d = len(sub(pts[i], pts[j]))
      if d < minSep then minSep = d end
      if d > maxSep then maxSep = d end
      if d < 0.5 then r.dups[#r.dups + 1] = { pts[i].h, pts[j].h } end
    end
  end
  if n == 1 then minSep = 0 end
  local area, vol = 0, 0
  for i = 1, cap do
    for j = i + 1, cap do
      for k = j + 1, cap do
        local c = cross(sub(pts[j], pts[i]), sub(pts[k], pts[i]))
        local a = len(c) / 2
        if a > area then area = a end
        for l = k + 1, cap do
          local v = abs(dot(c, sub(pts[l], pts[i]))) / 6
          if v > vol then vol = v end
        end
      end
    end
  end
  r.minSep, r.maxSep, r.minY, r.area, r.volume = minSep, maxSep, minY, area, vol
  r.collinear = n >= 3 and area < 0.25
  r.coplanar = n >= 4 and vol < 0.5
  -- 1 = a regular tetrahedron (best), 0 = flat
  r.shape = maxSep > 0 and math.min(1, (6 * vol / (maxSep ^ 3)) / 0.7071) or 0

  local score
  if n < 3 then score = 10 * n
  elseif r.collinear then score = 15
  elseif n == 3 then score = 30
  elseif r.coplanar then score = 25
  else
    score = 55 + round(25 * math.min(1, r.shape * 2))
    if n >= 5 then score = score + 10 end
    if minY >= 128 then score = score + 10 elseif minY >= 64 then score = score + 5 end
  end
  if #r.dups > 0 then score = score - 30 end
  if maxSep < 6 and n >= 2 then score = score - 10 end
  r.score = math.max(0, math.min(100, score))
  r.grade = r.score >= 85 and "excellent" or (r.score >= 65 and "good" or (r.score >= 40 and "fair" or "poor"))

  if #r.dups > 0 then
    say("Two hosts claim the same position: one of them has wrong coordinates. Check it with F3.")
  end
  if n < 4 then
    say(("Only %d host%s. GPS needs at least 4: add %d more."):format(n, n == 1 and "" or "s", 4 - n))
  end
  if r.collinear then
    say("All hosts are on one straight line. Move some of them sideways.")
  elseif n == 3 then
    say("Place the 4th host higher or lower than the other three (5+ blocks), or fixes are mirrored.")
  elseif r.coplanar then
    say("All hosts are in one flat plane, so every fix has a mirror twin. Move one host 5+ blocks up or down.")
  elseif n >= 4 and r.shape < 0.15 then
    say("The hosts are almost flat. Move one further up or down for steadier fixes.")
  end
  if n >= 2 and maxSep < 6 then
    say("The hosts are very close together. Spread them 5-10 blocks apart: a small typo in a position then hurts less.")
  end
  if n == 4 and not r.coplanar then
    say("Add a 5th host as a spare: with only 4, GPS stops when one goes offline.")
  end
  if minY < 64 then
    say(("The lowest host is at y=%d. Wireless modems reach farther up high (y 128+), or use ender modems.")
        :format(floor(minY)))
  end
  if #r.advice == 0 then say("Looks great: GPS works everywhere in range.") end
  return r
end

return G
