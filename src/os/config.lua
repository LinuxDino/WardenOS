-- WardenOS config
return {
  name    = "WardenOS",
  version = "1.3.0",
  repo    = "LinuxDino/WardenOS",  -- GitHub repo used by "Update WardenOS"
  branch  = "main",

  side    = "right",    -- preferred monitor side; any other attached monitor is used if none is there
                        -- display mode and monitor text size are in the Settings app
  default = "dark",
  themes  = {
    dark = {
      bg = colors.black, panel = colors.gray, text = colors.white, dim = colors.lightGray,
      accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow,
      palette = {
        [colors.black] = 0x070b0f, [colors.gray] = 0x111c24,
        [colors.lightGray] = 0x6f8494, [colors.white] = 0xe6eef2,
        [colors.cyan] = 0x29dfeb, [colors.green] = 0x3ddc97,
        [colors.red] = 0xf87171, [colors.yellow] = 0xfbbf24, [colors.blue] = 0x5aa9f0,
      },
    },
    light = {
      bg = colors.white, panel = colors.lightGray, text = colors.black, dim = colors.gray,
      accent = colors.cyan, good = colors.green, bad = colors.red, warn = colors.yellow,
      palette = {
        [colors.black] = 0x10181e, [colors.gray] = 0x5b6b76,
        [colors.lightGray] = 0xdde4e8, [colors.white] = 0xf4f7f8,
        [colors.cyan] = 0x0b7f8c, [colors.green] = 0x15803d, [colors.blue] = 0x2563eb,
        [colors.red] = 0xdc2626, [colors.yellow] = 0xb7791f,
      },
    },
  },
}
