-- cowsay: a talking cow (or Tux, or the Warden)
local cli = dofile("/os/lib/cli.lua").init("cowsay", shell)
local ANIMALS = {
  cow = {
    "        \\   ^__^",
    "         \\  (oo)\\_______",
    "            (__)\\       )\\/\\",
    "                ||----w |",
    "                ||     ||",
  },
  tux = {
    "   \\",
    "    \\",
    "        .--.",
    "       |o_o |",
    "       |:_/ |",
    "      //   \\ \\",
    "     (|     | )",
    "    /'\\_   _/`\\",
    "    \\___)=(___/",
  },
  warden = {
    "   \\",
    "    \\   \\\\      //",
    "         \\\\.--.//",
    "         /  ..  \\",
    "        | (    ) |",
    "        |  \\__/  |",
    "       /|  /\\/\\  |\\",
    "      / |________| \\",
    "         |_|  |_|",
  },
}
return cli.main({
  usage = "cowsay [-f cow|tux|warden] [-l] <text>",
  about = "A cow (or Tux, or the Warden) says your text in a speech bubble. With the WardenOS art "
    .. "library on a color screen, the Warden is drawn in color.",
  options = { "-f name  who speaks: cow (default), tux, warden", "-l       list them",
              "-e eyes  the cow's eyes (2 characters)", "e.g. cowsay -f warden Shhh..." },
  flags = { f = "str", l = true, e = "str" }, long = { file = "f", list = "l", eyes = "e" }, stop = true,
  run = function(o, args)
    if o.l then cli.print("cow tux warden") return end
    local who = (o.f or "cow"):lower():gsub("%.cow$", "")
    if not ANIMALS[who] then cli.fail("unknown animal '" .. who .. "' (try: cowsay -l)") end
    local text = table.concat(args, " ")
    if text == "" then cli.fail("what should it say? (usage: cowsay <text>)") end
    local w = term.getSize()
    local lines = cli.wrap(text, math.max(4, math.min(36, w - 4)))
    local width = 0
    for _, l in ipairs(lines) do width = math.max(width, #l) end
    cli.fg(colors.white)
    cli.line(" " .. string.rep("_", width + 2))
    for i, l in ipairs(lines) do
      local pad = l .. string.rep(" ", width - #l)
      local a, b = "|", "|"
      if #lines == 1 then a, b = "<", ">"
      elseif i == 1 then a, b = "/", "\\"
      elseif i == #lines then a, b = "\\", "/" end
      cli.line(a .. " " .. pad .. " " .. b)
    end
    cli.line(" " .. string.rep("-", width + 2))
    local art = ANIMALS[who]
    if who == "warden" then
      local _, h = term.getSize()
      local img = cli.art("warden", { "small" }, w - 4, h)
      if img then
        cli.line("   \\", colors.white)
        cli.line("    \\", colors.white)
        cli.image(img, 6)
        return
      end
      cli.fg(colors.cyan)
    end
    if who == "cow" and o.e then
      local eyes = (o.e .. "  "):sub(1, 2)
      art = { art[1], (art[2]:gsub("%(oo%)", "(" .. eyes .. ")")), art[3], art[4], art[5] }
    end
    cli.art_lines(art)
  end,
}, ...)
