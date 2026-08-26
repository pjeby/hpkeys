# HPKeys - Softkey Mapper for HP Multimedia Keyboards

A vibe-coded modern replacement for the HP/Netropa `KBD.EXE` keyboard utility, for the **HP SK-2506U multimedia keyboard** (HP Pavilion era, circa 2000 or so — USB, VID `03F0` / PID `020C`).

Unlike the original utility, it supports mapping softkeys to keystrokes or macros as well as launching URLs, and it even supports command-line arguments for launched programs.  The on-screen display also doesn't delay invocation of the command, URL or hotkey: it runs in parallel so you don't have to wait for it to disappear before anything else happens.

The OSD is also at least as configurable as the original utiltity's version, and can be disabled altogether or configured not to show anything for specific softkeys.

Note: this utility has only been tested with the one specific keyboard model, but it *might* work for you anyway if your keyboard has similar buttons and knobs; see also the "Different keyboard?" section below for porting notes.

## Why this exists

My wife and I both have used this particular keyboard since Windows 98 was still a thing, but somewhere along the way the original software to remap the buttons quit working.  (It was also slow and quirky to begin with.)

Unfortunately, you can't use ordinary keyboard remapping software for its various special buttons (Eject, media keys, the internet/multimedia buttons, Find/Print/Fax, HP, Shortcuts, Help): the only ones that use stock keyboard scan codes are the volume knob and mute button. (So HPKeys doesn't touch those.)

Everything else is just raw HID reports on a vendor-defined HID collection (usage page `0xFF7F`) that Windows' keyboard stack silently ignores.

The original 2000-ish `C:\hp\kbd\kbd.exe` utility read those reports itself; HPKeys does the same job via the Windows Raw Input API, with a straightforward configuration file inplace of the bizarre maze of GUIDs, plugins, .htm files and whatnot of the old utility.

## Requirements

- Windows 10 (older and newer versions likely work, untested)
- Either:
  - run `HPKeys.exe` directly (compiled, 32-bit Unicode — no install), or
  - run `HPKeys.ahk` with [AutoHotkey v1.1](https://www.autohotkey.com/) (Unicode build) installed

## Installation

1. Copy `HPKeys.exe` (or `HPKeys.ahk` if Windows smart-screen blocks the .exe) to a **writable** folder — e.g. `%LOCALAPPDATA%\Programs\HPKeys`. Do *not* use `Program Files`: the configuration file is written next to the program. No other files are needed — the icon and the default configuration are embedded in the executable.
2. Run it. On first start it creates `HPKeys.ini` (named after the executable) with every option present and documented.
3. Optional: tray icon right-click → **Run at startup**.

> [!CAUTION]
>
> **Important:** if the original HP/Netropa `KBD.EXE` is still installed and running, stop it and remove it from startup — otherwise every button triggers both utilities (double actions, double OSDs).

## Usage

The five media buttons are preconfigured; the other buttons are all no-ops until you map them.  Double-click the tray icon (or right-click and choose **Edit config**) to open `HPKeys.ini` in Notepad, then use **Reload config** from the tray menu after saving. Settings include the on-screen display (font, size, color, position, timeout), debug tooltips, and the tray icon source.

Each button gets one line in `[Buttons]` with a verb:

```ini
[Buttons]
Eject        = eject                        ; open the optical tray (MCI)
PlayPause    = send {Media_Play_Pause}      ; AHK Send syntax: {Media_Next}, #e, ^p
Shopping     = run https://www.amazon.com
Search       = url https://www.gooogle.com  ; url and run are aliases
Shortcut1    = run notepad.exe C:\notes.txt ; arguments are supported
Find         = send #e                      ; Win+E
```

- `run` (the default if no verb is given) — anything ShellExecute accepts: program + arguments, document, folder, URL
- `url` — alias of `run`
- `send` — AutoHotkey Send syntax ([docs](https://www.autohotkey.com/docs/v1/lib/Send.htm), [key list](https://www.autohotkey.com/docs/v1/KeyList.htm))
- `eject` — opens the optical drive tray (`eject D:` for a specific drive)

`[Labels]` controls the on-screen display text per button; an **empty label** silences that button's OSD. Unassigned buttons still flash their label so you can see they were recognized.

The complete list of buttons supported by the script can be found in the default labels section.

## Building from source

Run **`build.ahk`** (with AutoHotkey v1.1 Unicode, i.e. `AutohotkeyU64.exe`). It embeds `defaults.ini` (the default configuration offered to fresh installs) and `HPKeys.ico` (used for the tray icon when no external `.ico` sits next to the uncompiled .ahk) into `HPKeys.ahk`, then compiles `HPKeys.exe` with Ahk2Exe (Unicode 32-bit base). Stop any running HPKeys.exe first — the exe cannot be overwritten while running. To change what new installs get by default, edit `defaults.ini` (not your live `HPKeys.ini`) and rebuild.

## Different keyboard?

This build is tailored to the SK-2506U (VID `03F0`/PID `020C`) and its exact report format. If you have a **different** multimedia keyboard whose extra buttons are invisible to remapping tools, the capture-and-adapt procedure is in [AGENTS.md](AGENTS.md): read it yourself, or hand that file plus the `hidlog.ahk` script to an AI assistant and let it do the porting.
