-- asciiquarium: fish swimming in the terminal. q or Ctrl+T quits.
local cli = dofile("/os/lib/cli.lua").init("asciiquarium", shell)
local RIGHT = { "><>", "><(('>", ">=>", "><_>" }
local LEFT = { "<><", "<'))><", "<=<", "<_><" }
local FISHCOL = { colors.orange, colors.yellow, colors.red, colors.magenta, colors.lime, colors.pink, colors.white }
return cli.main({
  usage = "asciiquarium",
  about = "An aquarium in your terminal: fish, bubbles and seaweed. q or Ctrl+T quits.",
  run = function()
    local w, h = term.getSize()
    local fish, bubbles = {}, {}
    local function newFish()
      local dir = math.random(1, 2) == 1 and 1 or -1
      local k = math.random(1, #RIGHT)
      local body = dir == 1 and RIGHT[k] or LEFT[k]
      return { x = dir == 1 and -#body or w + 1, y = math.random(3, math.max(3, h - 1)), dir = dir, body = body,
               col = FISHCOL[math.random(1, #FISHCOL)], speed = math.random(1, 3) }
    end
    for i = 1, math.max(2, math.floor(w * h / 120)) do fish[i] = newFish() fish[i].x = math.random(1, w) end
    local tick = 0
    cli.bg(colors.blue)
    while true do
      tick = tick + 1
      if cli.resized then cli.resized = false w, h = term.getSize() end
      cli.bg(colors.blue)
      term.clear()
      local wave = ("~^~-"):rep(math.ceil(w / 4) + 1)
      local off = tick % 4
      cli.at(1, 1, wave:sub(1 + off, w + off), colors.lightBlue, colors.blue)
      for x = 2, w, 7 do                              -- seaweed
        local sway = (math.floor(tick / 3) + x) % 2 == 0
        for k = 0, math.min(3, h - 3) do
          cli.at(x + ((sway and k % 2 == 0) and 1 or 0), h - k, k % 2 == 0 and "(" or ")", colors.green, colors.blue)
        end
      end
      for i = #bubbles, 1, -1 do
        local b = bubbles[i]
        b.y = b.y - 1
        if b.y < 2 then table.remove(bubbles, i) else cli.at(b.x, b.y, b.y % 3 == 0 and "O" or "o", colors.lightBlue, colors.blue) end
      end
      for i, f in ipairs(fish) do
        if tick % f.speed == 0 then f.x = f.x + f.dir end
        if (f.dir == 1 and f.x > w) or (f.dir == -1 and f.x < -#f.body) then fish[i] = newFish() f = fish[i] end
        cli.at(f.x, f.y, f.body, f.col, colors.blue)
        if math.random(1, 25) == 1 then
          bubbles[#bubbles + 1] = { x = f.dir == 1 and f.x + #f.body or f.x - 1, y = f.y }
        end
      end
      if not cli.sleep(0.15) then break end
    end
    cli.restore()
  end,
}, ...)
