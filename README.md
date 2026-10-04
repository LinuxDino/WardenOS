# WardenOS

A fast, touch-friendly desktop operating system for [CC: Tweaked](https://tweaked.cc),
built for modded Minecraft worlds.

- Clean desktop: dock, **Apps** view with every app, real windows (move, maximize, minimize, close)
- **Settings** app: one-tap updates from GitHub, display mode, monitor text size, theme, dock, boot menu
- Uses the whole monitor (any side, auto-detected) at a small, crisp text size; or mirror it, or use the computer alone
- **Peripheral Inspector**: browse every attached or networked peripheral from any mod and see its methods
- **Lua Console**, **Terminal** (full CraftOS shell), **Files**, **Editor**, **System Monitor**
- Dark and light theme, login with salted + hashed passwords
- 2 second boot menu: WardenOS or plain CraftOS
- One-command install and in-place updates straight from this repository

## Install

Needs an **Advanced Computer** and the CC: Tweaked `http` API enabled (it is by default).
An Advanced Monitor is optional (at least 3x2 blocks recommended).

From Pastebin ([pastebin.com/CeQfPV78](https://pastebin.com/CeQfPV78)):

```
pastebin get CeQfPV78 install
install
```

Or straight from GitHub:

```
wget run https://raw.githubusercontent.com/LinuxDino/WardenOS/main/install.lua
```

The installer downloads and checks every file **before** it changes anything, then walks you through
the terms, your account and a clean install (this erases the computer).

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

## Display modes (Settings > Display)

- **Auto / Monitor**: the desktop fills the whole monitor; the computer screen shows a status panel.
- **Mirror**: the same picture on the computer and, centered, on the monitor.
- **Computer**: ignore monitors.
- **Text size** 0.5x (most space, default) to 2x. Restart to apply.

## Development

```
src/               the OS exactly as it lands on the computer (/startup.lua, /os/...)
install.lua        the installer (this is what goes on Pastebin)
manifest.lua       list of files the installer downloads; add new files here
tests/check.py     static checks + full dry run against a mocked CC: Tweaked (pip install lupa)
```

Apps live in `src/os/apps/*.lua` and return
`{ name, short, icon, color, order, w, h, multi, main = function(arg) ... end }`.
They draw on `term`, read the live theme from `WardenOS.theme` and get the `theme_changed` event.
Open another app with `os.queueEvent("os_launch", "appname", arg)`.

When you release a new version, bump `version` in both `manifest.lua` and `src/os/config.lua`.
