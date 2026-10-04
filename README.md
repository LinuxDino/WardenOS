# WardenOS

A fast, touch-friendly desktop operating system for [CC: Tweaked](https://tweaked.cc),
built for modded Minecraft worlds.

- Dock + top bar desktop with real windows (move, maximize, minimize, close)
- Runs on a monitor (any side, auto-detected) mirrored to the computer screen, or on the computer alone
- **Peripheral Inspector**: browse every attached or networked peripheral from any mod and see its methods
- **Lua Console**, **Terminal** (full CraftOS shell), **Files**, **Editor**, **System Monitor**
- Dark and light theme, login with salted + hashed passwords
- 2 second boot menu: WardenOS or plain CraftOS
- One-command install and in-place updates straight from this repository

## Install

Needs an **Advanced Computer** and the CC: Tweaked `http` API enabled (it is by default).
An Advanced Monitor is optional (at least 3x2 blocks recommended).

From Pastebin:

```
pastebin get <CODE> install
install
```

Or straight from GitHub:

```
wget run https://raw.githubusercontent.com/LinuxDino/WardenOS/main/install.lua
```

The installer downloads and checks every file **before** it changes anything, then walks you through
the terms, your account and a clean install (this erases the computer).

## Update

Open the **WARDENOS** menu (top left) and pick **Update WardenOS**, or run `install update`.
Accounts, settings and your own files are kept.

To install from another branch: `install <branch>` or `install update <branch>`.

## Controls

- Tap a dock icon to open an app, tap it again to minimize.
- Tap a window title once, then tap where it should go, to move it. `-` `+` `x` minimize, maximize, close.
- **WARDENOS** (top left): theme, log out, update, exit to CraftOS, reboot, shut down.
- `F12` exits to CraftOS. In the boot menu: arrows + Enter, `D` saves the default.

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
