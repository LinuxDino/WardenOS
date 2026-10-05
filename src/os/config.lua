-- WardenOS config
return {
  name    = "WardenOS",
  version = "1.7.0",
  repo    = "LinuxDino/WardenOS",  -- GitHub repo used by "Update WardenOS"
  branch  = "main",

  side    = "right",    -- preferred monitor side; any other attached monitor is used if none is there
                        -- display mode and monitor text size are in the Settings app
  default = "dark",
  -- color roles: bg, panel, text, dim, accent, good, bad, warn. lightBlue is tuned to the soul glow of the
  -- Warden art (/os/lib/art.lua); gray, the panel color, is its dark teal body.
  themes  = {
    dark = {
      label = "Dark",
      bg = colors.black, panel = colors.gray, text = colors.white, dim = colors.lightGray,
      accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow,
      palette = {
        [colors.black] = 0x070b0f, [colors.gray] = 0x152a33,
        [colors.lightGray] = 0x7489a0, [colors.white] = 0xe6eef2,
        [colors.cyan] = 0x29dfeb, [colors.green] = 0x3ddc97,
        [colors.red] = 0xf87171, [colors.yellow] = 0xfbbf24, [colors.blue] = 0x5aa9f0, [colors.lightBlue] = 0xa5f7fb,
      },
    },
    light = {
      label = "Light",
      bg = colors.white, panel = colors.lightGray, text = colors.black, dim = colors.gray,
      accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow,
      palette = {
        [colors.black] = 0x10181e, [colors.gray] = 0x56677a,
        [colors.lightGray] = 0xdce5ea, [colors.white] = 0xf5f8f9,
        [colors.cyan] = 0x0b7f8c, [colors.green] = 0x15803d, [colors.blue] = 0x2563eb,
        [colors.red] = 0xdc2626, [colors.yellow] = 0xb7791f, [colors.lightBlue] = 0x3fe0ec,
      },
    },
    sculk = {
      label = "Sculk",
      bg = colors.black, panel = colors.gray, text = colors.white, dim = colors.lightGray,
      accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow,
      palette = {
        [colors.black] = 0x02090c, [colors.gray] = 0x0a2a31,
        [colors.lightGray] = 0x4f939c, [colors.white] = 0xd4fbff,
        [colors.cyan] = 0x19e6f2, [colors.green] = 0x34d399,
        [colors.red] = 0xfb7185, [colors.yellow] = 0xfacc15, [colors.blue] = 0x38bdf8, [colors.lightBlue] = 0xb0fdff,
      },
    },
  },
  themeOrder = { "dark", "light", "sculk" },
}
