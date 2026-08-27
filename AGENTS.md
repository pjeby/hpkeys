# AGENTS.md — HPKeys internals & porting guide

Audience: AI agents or engineers adapting HPKeys to another multimedia keyboard. User-facing usage is in `README.md`.

## What the program does

`HPKeys.ahk` (AutoHotkey v1.1 Unicode) turns the extra buttons of the HP SK-2506U multimedia keyboard into configurable actions (`run` / `url` / `send` / `eject`), with an on-screen label display, tray menu, and a plain INI config.  It is a clean-room replacement for the 2001 HP/Netropa `C:\hp\kbd\kbd.exe`.

Repo layout: `HPKeys.ahk` (source, contains build-generated marker blocks embedding the default config and the tray icon), `defaults.ini` (source of the embedded default config), `icons/` (vibe-authored SVG sources for the tray icon — `icon.svg` detailed artwork rendered at 32 px, `icon-small.svg` simplified variant for 24/16 px, `preview.svg` multi-scale review sheet), `makeIcon` (bash script that regenerates `HPKeys.ico` from the SVGs via ImageMagick), `HPKeys.ico` (generated tray icon: last-known-good kept as `HPKeys.ico.bak`), `build.ahk` (re-embeds both into `HPKeys.ahk` and compiles `HPKeys.exe` via Ahk2Exe), `hidlog.ahk` (HID capture tool, see below).

## How it works

1. **Raw Input registration.** At startup the script registers for raw HID input on usage page `0xFF7F`, usage `0x0001` (the keyboard's vendor-defined top-level collection) with `RIDEV_INPUTSINK`, targeting a hidden GUI window (`RIDEV_INPUTSINK` requires a valid hwnd — an anonymous/NULL target fails).
2. **`WM_INPUT` handling (function `OnWM_INPUT`).** `GetRawInputData` fetches the report; the source device is filtered by comparing `GetRawInputDeviceInfo(..., RIDI_DEVICEINFO, ...)` vendor/product IDs   (`0x03F0`/`0x020C`) — cached per device handle. **Do not** switch this to `RIDI_DEVICENAME` with AHK's `"Str"` output mode: it returns an empty string in practice (verified empirically; it silently broke the first working build).
3. **Report decoding.** Reports are 4 bytes: `03 b1 b2 b3` — a report-ID byte (`0x03`) followed by a **24-bit one-hot button bitmask** (b1..b3). Reports carry **absolute** state (release = `03 00 00 00`), so presses are detected by edge-diffing against the previous report. Unknown bits are ignored.
4. **Dispatch.** The handler stays minimal (AHK message monitors run on the main thread): press events are queued and a 1 ms one-shot timer (`ProcessEvents:` → `ProcessQueue()`) executes actions and shows the OSD on its own thread. There is **no hardware auto-repeat** — each press is a single report pair; repeat would have to be emulated in software.
5. **Buttons.** `BtnNames` / `BtnByte` / `BtnMask` / `DefLabels` are parallel arrays mapping bitmask bits to names (see table below). `[Buttons]` / `[Labels]` INI sections are keyed by those names.
6. **Volume knob / Mute** live on a separate standard consumer-page (`0x000C`) collection (reports `01 01` vol-up, `01 7F` vol-down, `01 80`
mute per detent). Windows translates these natively; HPKeys never registers that page and ignores them by design.

### SK-2506U button bitmask map (vendor report `03 b1 b2 b3`)

| byte | 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x80 |
|------|------|------|------|------|------|------|------|------|
| b1   | Next | Prev | Stop | Eject | Play/Pause | — | — | — |
| b2   | Find | Print | Fax | HP | — | Shortcut 1 | Shortcut 2 | Help |
| b3   | E-Mail | People | Search | Connect | Finance | Entertainment | Shopping | — |

## Icon pipeline

`makeIcon` (bash, requires ImageMagick 7 on PATH) renders `icons/icon.svg` down to 32 px and `icons/icon-small.svg` at 24 and 16 px, packs the three PNGs into `HPKeys.ico` with `magick`, and preserves the previous icon once as `HPKeys.ico.bak` (the backup is never overwritten by re-runs; on any magick failure the backup is restored). To restyle the icon: edit the SVGs — `icons/preview.svg` shows the artwork at 1× down to 1/16 on light and dark backgrounds, open it in a browser — then run `./makeIcon`, stop `HPKeys.exe`, and run `build.ahk` to re-embed the icon and recompile.

The 32 px ceiling is deliberate: `build.ahk` base64-embeds the entire .ico into a single AHK v1 continuation section, which fails to load with "Continuation section too long" once the base64 grows past ~16 KB (hit in practice when the icon also carried 48–256 px sizes). The tray only ever draws 16/24/32 px anyway, so larger entries buy nothing.

## Hard-won gotchas

- Windows' `kbdhid` drops these vendor usages entirely — that is why keyboard hooks (AutoHotkey key history, PowerToys) see *nothing*. Only Raw Input or a direct `CreateFile`+`ReadFile` on the HID interface sees them.
- `IniRead` returns the literal string `ERROR` for a missing key **even when given an empty-string default**; the config loader normalizes it.
- Binary files cannot be searched with ordinary grep tools here (they are
skipped silently) — use a strings dump for static analysis.
- The original utility's `usb.dll` matched a hardcoded whitelist (`VID_03F0&PID_020C`, `VID_03F0&PID_010C`, `VID_058F&PID_9254`) and read
the device with overlapped `ReadFile`. The **PS/2** variant of this keyboard family works completely differently (kernel upper-filter driver `PS2.sys` with scancode remap tables) — out of scope for this project.
- Raw Input registration is by usage page/usage, not device handle, so unplug/replug and sleep/resume need no re-registration; the per-handle device filter self-heals (unknown handle → queried and cached on arrival).
- AHK v1 caps each continuation section at ~16 KB — see Icon pipeline for the concrete failure ("Continuation section too long" at the `IconB64Text()` block) and why the icon is generated at 32/24/16 px only.

## Porting to another keyboard

`hidlog.ahk` in this directory is the capture tool. It enumerates every HID top-level collection, registers the non-keyboard ones (default: only devices with VID `03F0` — see `WATCH_VID` / `WATCH_ALL` at the top), and appends every report to `hid-log.txt` next to itself with timestamp, device, usage page and raw bytes. `Ctrl+Alt+X` quits it.

Procedure:

1. Stop HPKeys and any OEM keyboard utility (avoid doubled events).
2. Run `hidlog.ahk` (AutoHotkey v1.1 Unicode). Don't watch `hid-log.txt` with `tail -f` or any locking viewer while it writes.
3. Read the `TLC` header lines: they list each collection's VID/PID and usage page/usage. Identify which collection the special buttons use (a vendor page like `0xFFxx`, or a consumer page `0x000C`). If no entry
matches the device, set `WATCH_ALL := true` and rerun.
4. Press each button once or twice, ~1.5–2 s apart, writing down the order. Include any button known to work natively as a sanity baseline.
5. Decode `hid-log.txt`: timestamps map to your written order. Identify the constant leading byte (report ID), then determine the payload encoding — one-hot bitmask bits (like this keyboard), usage-value bytes, or per-button distinct values. Watch for press/release pairs (all-zero or repeated reports) and detent-style pulses (no release) from wheels/knobs.
6. Modify `HPKeys.ahk`:
   - Registration constants: the `NumPut(0xFF7F/0x0001, ...)` pair in the
     startup block → your collection's usage page/usage.
   - Device filter in `OnWM_INPUT`: the VID/PID comparison.
   - `BtnNames` / `BtnByte` / `BtnMask` / `DefLabels`: one entry per button,
     consistent order across all four arrays.
   - If the encoding is not a one-hot bitmask, adapt the decode loop in
     `OnWM_INPUT` accordingly.
   - Update the report-layout comment in the file header.
7. Verify: set `Debug = 1` in `HPKeys.ini` — each press shows a tooltip with the decoded name and raw hex; then update `defaults.ini` and run `build.ahk` if button names changed (it re-embeds the default config and rebuilds the exe).

`HPKeys.ini` is a generated file — safe to delete to regenerate; users' edits are the source of truth once it exists.
