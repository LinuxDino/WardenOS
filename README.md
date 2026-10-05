# WardenOS

A fast, touch-friendly desktop operating system for [CC: Tweaked](https://tweaked.cc),
built for modded Minecraft worlds.

- Clean desktop: dock, **Apps** view with every app, real windows (move, maximize, minimize, close)
- **Settings** app: one-tap updates from GitHub, display mode, monitor text size, theme, dock, boot menu
- Uses the whole monitor (any side, auto-detected) at a small, crisp text size; or mirror it, or use the computer alone
- **Claude**: chat with Claude right on the in-game computer. Claude can run Lua, use files and peripherals, and
  command the drones you give it, asking you first before anything risky
- **Drones**: see every turtle and WardenOS computer on the network, live turtle status (task, fuel, position,
  inventory, activity log), remote control, homes and one-tap "call back"
- **Peripheral Inspector**: browse every attached or networked peripheral from any mod and see its methods
- **Map**: the world as your drones have seen it, zoom from 1 to 16 blocks per character, protected areas
- **Dashboard**: live cards for energy, fluids, inventories, Create stress/speed, AE2 / Refined Storage (via Advanced
  Peripherals), redstone, any peripheral method, plus drone and map stats
- **App Store**: one-tap installs from GitHub: games (Snake, 2048, Minesweeper, Blocks, Warden Run) and tools
  (Calculator, Stopwatch, Notes, Paint), plus terminal commands; also `apt install <pkg>` in the terminal
- **MineView**: TradingView for your resources: candle charts per item (1m to 1d), produced vs used per period,
  watchlist with 1h change; records chests / barrels (also over wired modems) or AE2 / RS via Advanced Peripherals
- **TradeView**: real markets (stocks, indices, crypto, gold, forex) with candles or line chart (1D to 5Y), crosshair,
  watchlist and search; delayed Yahoo Finance data, also `ticker BTC-USD ^IXIC` in the terminal. Not financial advice
- **To-Do**: tasks with priorities (start with `!` or `!!`), tick them off, filters, saved on the computer
- **System Monitor**: overview plus debug pages: network traffic, all drones, Claude API calls, error log, disk
- **Lua Console**, **Terminal** (full CraftOS shell, with `btop` and `neofetch`), **Files**, **Editor**
- Dark and light theme, login with salted + hashed passwords
- 2 second boot menu: WardenOS or plain CraftOS
- One-command install and in-place updates straight from this repository

## Install

Needs an **Advanced Computer** and the CC: Tweaked `http` API enabled (it is by default).
An Advanced Monitor is optional (at least 3x2 blocks recommended).

From Pastebin ([pastebin.com/CeQfPV78](https://pastebin.com/CeQfPV78)), on a computer or a turtle:

```
pastebin run CeQfPV78
```

(or `pastebin get CeQfPV78 install` and then `install`; if that says "File already exists", delete the old
file with `delete install` first, or just use `pastebin run`)

Or straight from GitHub:

```
wget run https://raw.githubusercontent.com/LinuxDino/WardenOS/main/install.lua
```

The installer downloads and checks every file **before** it changes anything, then walks you through
the terms, your account and a clean install (this erases the computer).

## Drones (turtles)

Put a wireless or ender modem on the turtle, then run the same Pastebin command on it
(`pastebin get CeQfPV78 install`, then `install`). On a turtle it installs the drone agent only: no erase, other
files stay, the old `startup.lua` is kept as `startup.old.lua`.

In **Drones**, tap a turtle and **Claim** it (only its owner can control it). Then drive it, dig, place, refuel,
locate (needs GPS) or **Update** it to the newest agent from GitHub.

- **update all** in the list updates every drone you own to the newest agent from GitHub (each one reboots).
- **Set home here** makes the drone's current spot and direction its home. The drone tracks every move it makes
  (no GPS needed), so **Go home** drives it back, and **all home** in the list calls every drone you own back.
- Drones can run **tasks**: small Lua programs that run on the turtle by themselves; their `print`/`report` lines
  show up live under Activity. **Stop** cancels a task.
- **Give to Claude** lets the Claude app control that drone (only the drones you give it), or switch
  Claude > options to **all my drones**.
- **Calibrate** (type the F3 position and facing) or **Use GPS** gives a drone world coordinates; then it reports
  what it sees to the **Map**, plans its own routes in 3D (`goto`) and respects protected areas.
- **Safe dig** (on by default): drones only dig natural blocks (stone, dirt, sand, gravel, ores, leaves), never
  planks, glass, bricks and the like. Mark your base in **Map > Protect** and nothing inside it is dug at all.
- Drones refuel from coal by themselves and drive home when fuel gets too low for the way back.
- **templates** (Drones list): programs Claude saved; tap one, pick a drone, run.
- When Claude is working with a drone, the top bar shows **AI>#12 ...**; tap it to open that drone. The Drones app
  shows Claude's job, phase, step and time.

## Claude

Open **Claude** (it's in the dock), paste an Anthropic API key from [console.anthropic.com](https://console.anthropic.com)
and chat. Claude API use is billed to that key; a Claude.ai subscription does not work here. The key is stored in
`/os/claude/key` on that computer, so anyone who can read the computer's files or the world save can see it.

Claude can run Lua, read and write files, use peripherals, scan the network and command its drones, including
writing whole tasks for a drone and watching them run. By default it asks before anything risky
(**Allow / Always / Deny**); **options** switches model (Opus 5.5 / Sonnet 5.5), effort, or "run without asking".
If replies time out, pick a lower effort in **options**, or ask the server owner to raise the HTTP timeout in the CC: Tweaked server config.

## WardenOS Pocket

Needs an **Advanced Pocket Computer** with a wireless or ender modem upgrade. Run the same Pastebin command on it
(`pastebin get CeQfPV78 install`, then `install`): it installs WardenOS Pocket only (no erase; the old `startup.lua`
is kept as `startup.old.lua`). On first start it asks how to work:

- **Connect to a WardenOS computer** (recommended): pick your computer from the list, then tap **Allow** on that
  computer's screen. Drones and Claude then run on the computer (its drones, its Claude key and settings); the pocket
  is a remote screen for them.
- **Run on this pocket only**: the pocket claims and drives drones itself and runs Claude with its own key.

The home screen has **Drones** (status, Go home, Stop, Set home, driving, all home), **Claude**, **Terminal**
(type `exit` to come back) and **Settings** (mode, pick/forget the computer, theme, update, exit to CraftOS).
Paired pockets are listed in `/os/pockets` on the computer. Rednet range is the modem's range (ender modems: unlimited).

## GPS (optional, recommended for drones)

Drones work without GPS, but with it they find their world position by themselves (Drones > Use GPS).

1. Build 4 computers with wireless (or ender) modems high up, e.g. around y = 200. They must not all be in one
   flat plane: put A, B 5 blocks east of A, C 5 blocks south of A, and D 5 blocks above A.
2. Look at each computer, press F3 and read "Targeted Block: x, y, z".
3. On each one: `edit startup.lua`, write `shell.run("gps", "host", X, Y, Z)` with that computer's own
   coordinates, save, reboot. Give each a label (`label set gps1`) so it keeps its program when broken.
4. They must stay loaded (near your base, or with a chunk loader). Test anywhere with `gps locate`.

Don't install WardenOS on the GPS computers; they only run `gps host`.

## Update

Open **Settings > System > Check for updates**, then **Update now**. Or run `install update` in CraftOS.
Accounts, settings and your own files are kept.

To install from another branch: `install <branch>` or `install update <branch>`.

## Controls

- **Apps** (top of the dock) shows every app. Pin your favourites to the dock in **Settings > Dock**.
- Tap a dock icon to open an app, tap it again to minimize.
- Tap a window title once, then tap where it should go, to move it. `-` `+` `x` minimize, maximize, close.
- **WARDENOS** (top left): Apps, Settings, log out, exit to CraftOS, reboot, shut down.
- With the desktop on the monitor, the keyboard still types into the active window.
- `F12` exits to CraftOS. In the boot menu: arrows + Enter, `D` saves the default.

## Look and feel

The Warden greets you at boot (skip with any key), on the desktop wallpaper, at login and on the pocket. Every app
has a pixel icon. The login has an **on-screen keyboard**, so you can type your name and password by tapping the
monitor. Themes: dark, light and **sculk** (Settings > Theme).

## Terminal commands

Every command has a manual page: `man <command>`, or `man -k <word>` to search.

- Everyday: `cat` `head` `tail` (`-f`) `grep` `wc` `touch` `tree` `du` `df` `free` `less` `sort` `rev` `seq` `factor`
  `base64` `sha256sum` `echo` `yes` `which` `env` `pwd` `ps` `nano` `vim`
- System: `uname -a` `whoami` `hostname` `uptime` `date` `cal` `neofetch` `btop` (`top`, `htop`) `ping <id|label>`
  `ifconfig` / `ip` `sudo` `apt` `ticker`
- Fun: `cowsay -f warden` `fortune` `sl` `cmatrix` `asciiquarium` `hollywood` `lolcat` `figlet` `banner` `pacman`

## Display modes (Settings > Display)

- **Auto / Monitor**: the desktop fills the whole monitor; the computer screen shows a status panel.
- **Mirror**: the same picture on the computer and, centered, on the monitor.
- **Computer**: ignore monitors.
- **Text size** 0.5x (most space, default) to 2x. Restart to apply.

## Development

```
src/               the OS exactly as it lands on the computer (/startup.lua, /os/...)
install.lua        the installer (always downloaded fresh from GitHub)
pastebin.lua       the tiny loader on Pastebin: fetches and runs install.lua from GitHub
manifest.lua       list of files the installer downloads; add new files here
tests/check.py     static checks + full dry run against a mocked CC: Tweaked (pip install lupa)
```

Apps live in `src/os/apps/*.lua` and return
`{ name, short, icon, color, order, w, h, multi, main = function(arg) ... end }`.
They draw on `term`, read the live theme from `WardenOS.theme` and get the `theme_changed` event.
Open another app with `os.queueEvent("os_launch", "appname", arg)`.

When you release a new version, bump `version` in both `manifest.lua` and `src/os/config.lua`.
