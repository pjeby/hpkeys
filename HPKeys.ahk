;=============================================================================
; HPKeys.ahk - hotkey utility for the HP SK-2506U multimedia keyboard
;
; Replacement for the 2001 HP/Netropa KBD.EXE utility. Works by raw HID input:
; the keyboard's special buttons arrive as 4-byte reports on a vendor-defined
; HID collection (usage page 0xFF7F, usage 0x0001) of VID_03F0/PID_020C,
; which Windows' normal keyboard stack ignores. We register for raw input on
; that collection, decode the one-hot button bitmask, and dispatch actions.
;
; Report layout:  03 <b1> <b2> <b3>   (release = 03 00 00 00)
;   b1: 0x01=Next 0x02=Prev 0x04=Stop 0x08=Eject 0x10=Play/Pause
;   b2: 0x01=Find 0x02=Print 0x04=Fax 0x08=HP
;       0x20=Shortcut1 0x40=Shortcut2 0x80=Help
;   b3: 0x01=E-Mail 0x02=People 0x04=Search 0x08=Connect
;       0x10=Finance 0x20=Entertainment 0x40=Shopping
;
; Configuration: HPKeys.ini next to this script (or next to the compiled exe,
; named after it). Auto-generated with full comments on first run. Volume knob
; and Mute are intentionally ignored - Windows handles them natively.
;
; Build: run build.ahk in this directory - it embeds defaults.ini and
; HPKeys.ico into the marker blocks in this file and then compiles HPKeys.exe
; with Ahk2Exe (Unicode 32-bit base). The exe's shell icon comes from
; HPKeys.ico at compile time; the embedded copy drives the tray icon when the
; uncompiled script is run with no .ico next to the .ahk.
;
; AutoHotkey v1.1 Unicode required.
;=============================================================================
#NoEnv
#SingleInstance Force
SendMode Input
SetWorkingDir %A_ScriptDir%

;--- constants and shared state ----------------------------------------------
global WM_INPUT := 0x00FF, RID_INPUT := 0x10000003
global hdrSize := (A_PtrSize = 8) ? 24 : 16        ; sizeof(RAWINPUTHEADER)
global IniPath := A_ScriptDir "\" RegExReplace(A_ScriptName, "\.[^.]+$") ".ini"

global BtnNames  := ["Eject","PlayPause","Stop","Prev","Next","Find","Print","Fax","HP","Shortcut1","Shortcut2","Help","EMail","People","Search","Connect","Finance","Entertainment","Shopping"]
global BtnByte   := [1,1,1,1,1, 2,2,2,2,2,2,2, 3,3,3,3,3,3,3]
global BtnMask   := [0x08,0x10,0x04,0x02,0x01, 0x01,0x02,0x04,0x08,0x20,0x40,0x80, 0x01,0x02,0x04,0x08,0x10,0x20,0x40]
global DefLabels := ["Eject","Play/Pause","Stop","Prev Track","Next Track","Find","Print","Fax","HP","Shortcut 1","Shortcut 2","Help","E-Mail","People","Search","Connect","Finance","Entertainment","Shopping"]

global Actions := {}, Labels := {}, DevOK := {}, EvQueue := []
global OSD := 1, OSD_Send := 1, OSD_Timeout := 1200, OSD_Font := "Arial", OSD_Size := 48
global OSD_Color := "00FF00", OSD_OffsetX := 16, OSD_OffsetY := 48, OSD_Transparent := 1
global DebugMode := 0, IconMode := "auto", Paused := 0, LastHex := ""

;--- startup -------------------------------------------------------------------
if !FileExist(IniPath)
    WriteDefaultIni()
LoadConfig()

if (IconMode = "auto")
{
    IconFile := A_ScriptDir "\" RegExReplace(A_ScriptName, "\.[^.]+$") ".ico"
    if FileExist(IconFile)
        Menu, Tray, Icon, % IconFile
    else
    {
        icoLen := B64Decode(icoBytes, IconB64Text())
        hIcon := icoLen ? IconFromIcoBytes(icoBytes, icoLen) : 0
        if hIcon
            try Menu, Tray, Icon, % "HICON:" hIcon
    }
}
BuildTray()

; hidden window that receives raw input (RIDEV_INPUTSINK requires an hwnd)
Gui, sink:+LastFound +ToolWindow
global hSink := WinExist()

cb := (A_PtrSize = 8) ? 16 : 12                    ; sizeof(RAWINPUTDEVICE)
VarSetCapacity(rd, cb, 0)
NumPut(0xFF7F, rd, 0, "UShort")                    ; usUsagePage (vendor)
NumPut(0x0001, rd, 2, "UShort")                    ; usUsage
NumPut(0x100,  rd, 4, "UInt")                      ; RIDEV_INPUTSINK
NumPut(hSink,  rd, 8, "Ptr")
if !DllCall("RegisterRawInputDevices", "Ptr", &rd, "UInt", 1, "UInt", cb)
    MsgBox, 48, HPKeys, Raw input registration failed (error %A_LastError%).

OnMessage(WM_INPUT, "OnWM_INPUT")
OnMessage(0x404, "OnTrayClick")                      ; tray icon callback: single left click
return

;--- raw input handler (kept minimal: decode, enqueue, kick timer) -------------
OnWM_INPUT(wParam, lParam) {
    global
    static buf, bufCap := 0, pb1 := 0, pb2 := 0, pb3 := 0
    if Paused
        return
    size := 0
    DllCall("GetRawInputData", "Ptr", lParam, "UInt", RID_INPUT, "Ptr", 0, "UIntP", size, "UInt", hdrSize)
    if (size > bufCap)
        VarSetCapacity(buf, bufCap := size + 64)
    if (DllCall("GetRawInputData", "Ptr", lParam, "UInt", RID_INPUT, "Ptr", &buf, "UIntP", size, "UInt", hdrSize) <= 0)
        return
    if (NumGet(buf, 0, "UInt") != 2)               ; RIM_TYPEHID
        return
    hDev := NumGet(buf, 8, "Ptr")
    if !DevOK.HasKey(hDev)                          ; cache: is this our keyboard?
    {
        VarSetCapacity(di, 32, 0), NumPut(32, di, 0, "UInt")
        DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", 0x2000000b, "Ptr", &di, "UIntP", sz := 32)  ; RIDI_DEVICEINFO
        DevOK[hDev] := (NumGet(di, 8, "UInt") = 0x03F0 && NumGet(di, 12, "UInt") = 0x020C) ? 1 : 0
    }
    if !DevOK[hDev]
    {
        if DebugMode
        {
            ToolTip % "HPKeys debug: ignored HID event from device handle " hDev " (not VID_03F0/PID_020C)"
            SetTimer, TipClear, -1500
        }
        return
    }
    if (NumGet(buf, hdrSize, "UInt") * NumGet(buf, hdrSize + 4, "UInt") < 4)
        return
    base := hdrSize + 8
    b1 := NumGet(buf, base + 1, "UChar"), b2 := NumGet(buf, base + 2, "UChar"), b3 := NumGet(buf, base + 3, "UChar")
    LastHex := Format("{:02X} {:02X} {:02X} {:02X}", NumGet(buf, base, "UChar"), b1, b2, b3)
    fired := false
    Loop % BtnNames.Length()
    {
        nb := (BtnByte[A_Index] = 1) ? b1 : (BtnByte[A_Index] = 2) ? b2 : b3
        pb := (BtnByte[A_Index] = 1) ? pb1 : (BtnByte[A_Index] = 2) ? pb2 : pb3
        if ((nb & BtnMask[A_Index]) && !(pb & BtnMask[A_Index]))   ; press edge only
        {
            EvQueue.Push(A_Index)
            fired := true
        }
    }
    pb1 := b1, pb2 := b2, pb3 := b3
    if fired
        SetTimer, ProcessEvents, -1
}

;--- event dispatch (runs on its own timer thread, parallel with the OSD) -------
ProcessEvents:
    ProcessQueue()
return

ProcessQueue() {
    global
    while EvQueue.Length()
    {
        i := EvQueue[1]
        EvQueue.Remove(1)
        name := BtnNames[i]
        act := Actions[name]
        if DebugMode
        {
            ToolTip % "HPKeys: " name "  [" LastHex "]  " ((act = "") ? "(no-op)" : act)
            SetTimer, TipClear, -2000
        }
        if (act = "")
        {
            if OSD
                ShowOSD(Labels[name])
            continue
        }
        verb := "run", rest := act
        if RegExMatch(act, "i)^(run|send|url|eject)\b\s*(.*)$", m)
            verb := m1, rest := m2
        if (verb = "eject")
        {
            if (rest = "")
                r := DllCall("winmm\mciSendString", "Str", "set cdaudio door open", "Str", 0, "UInt", 0, "Ptr", 0, "UInt")
            else
            {
                r := DllCall("winmm\mciSendString", "Str", "open " Trim(rest) " type cdaudio alias hpkeyscd", "Str", 0, "UInt", 0, "Ptr", 0, "UInt")
                r := DllCall("winmm\mciSendString", "Str", "set hpkeyscd door open", "Str", 0, "UInt", 0, "Ptr", 0, "UInt")
                DllCall("winmm\mciSendString", "Str", "close hpkeyscd", "Str", 0, "UInt", 0, "Ptr", 0, "UInt")
            }
            if (r != 0)
            {
                ToolTip HPKeys: MCI eject failed (no optical drive?)
                SetTimer, TipClear, -2500
            }
            if OSD
                ShowOSD(Labels[name])
        }
        else if (verb = "send")
        {
            Send, % rest
            if (OSD && OSD_Send)
                ShowOSD(Labels[name])
        }
        else
        {
            try
                Run, % rest
            catch
            {
                ToolTip % "HPKeys: could not run: " rest
                SetTimer, TipClear, -2500
            }
            if OSD
                ShowOSD(Labels[name])
        }
    }
}

;--- on-screen display ----------------------------------------------------------
ShowOSD(text) {
    global
    if (text = "")
        return
    Gui, osd:Destroy
    Gui, osd:+AlwaysOnTop -Caption +ToolWindow +Disabled +E0x20   ; topmost, click-through
    Gui, osd:Color, 000000
    Gui, osd:Margin, 16, 8
    Gui, osd:Font, % "s" OSD_Size " c" OSD_Color, % OSD_Font
    Gui, osd:Add, Text, vOsdText, % text
    Gui, osd:Show, Hide
    Gui, osd:+LastFound
    if OSD_Transparent
        WinSet, TransColor, 000000
    w := 120, h := 48                                ; fallbacks in case measurement fails
    WinGetPos, , , w, h                              ; uses the last-found window
    VarSetCapacity(wa, 16, 0)                        ; primary monitor work area
    DllCall("SystemParametersInfo", "UInt", 0x30, "UInt", 0, "Ptr", &wa, "UInt", 0)
    x := NumGet(wa, 0, "Int") + (OSD_OffsetX + 0)
    y := NumGet(wa, 12, "Int") - (OSD_OffsetY + 0) - (h + 0)
    if x is not integer
        x := 16
    if y is not integer
        y := A_ScreenHeight // 2
    Gui, osd:Show, % "x" x " y" y " NoActivate"
    SetTimer, OsdHide, % OSD_Timeout * -1
}

OsdHide:
    Gui, osd:Hide
return

TipClear:
    ToolTip
return

;--- tray menu -------------------------------------------------------------------
BuildTray() {
    Menu, Tray, NoStandard
    Menu, Tray, Tip, HPKeys (SK-2506U)
    Menu, Tray, Add, Edit config, MenuEdit
    Menu, Tray, Add, Reload config, MenuReload
    if (!A_IsCompiled && FileExist(A_ScriptDir "\HPKeys.ahk") && FileExist(A_ScriptDir "\build.ahk"))
        Menu, Tray, Add, Rebuild and restart, MenuRebuild
    Menu, Tray, Add, Pause button handling, MenuPause
    Menu, Tray, Add
    Menu, Tray, Add, Run at startup, MenuStartup
    Menu, Tray, Add
    Menu, Tray, Add, Exit, MenuExit
    Menu, Tray, Default, Edit config
    Menu, Tray, % StartupEnabled() ? "Check" : "UnCheck", Run at startup
    Menu, Tray, % Paused ? "Check" : "UnCheck", Pause button handling
}

MenuEdit() {
    global
    if !FileExist(IniPath)
        WriteDefaultIni()
    Run, % IniPath
}

MenuReload() {
    ReloadConfigNow()
}

OnTrayClick(wParam, lParam) {
    if (lParam = 0x202)                              ; WM_LBUTTONUP - single left click: reload
        ReloadConfigNow()
    else if (lParam = 0x203)                         ; WM_LBUTTONDBLCLK: open the config
        MenuEdit()
}

ReloadConfigNow() {
    global
    LoadConfig()
    TrayNote("Configuration reloaded")
}

MenuRebuild() {
    global
    if !FileExist(A_ScriptDir "\defaults.ini") || !FileExist(A_ScriptDir "\HPKeys.ico")
    {
        TrayNote("Rebuild needs defaults.ini and HPKeys.ico next to the script.")
        return
    }
    interp := A_AhkPath
    mode := "ahk"
    if !FileExist(interp)
    {
        TrayNote("Rebuild could not determine the AutoHotkey interpreter path.")
        return
    }
    pid := DllCall("GetCurrentProcessId")
    q := """"
    cmd := q interp q " " q A_ScriptDir "\build.ahk" q " /relaunch " pid " " mode
    Run, % cmd, %A_ScriptDir%, UseErrorLevel
    if (UseErrorLevel = "ERROR")
    {
        TrayNote("Rebuild failed to launch build.ahk - see tooltip.")
        ToolTip % "HPKeys rebuild: failed to launch:`n" cmd
        SetTimer, TipClear, -5000
        return
    }
    ExitApp
}

TrayNote(msg) {
    ToolTip % "HPKeys: " msg
    SetTimer, TipClear, -3500
}

MenuPause() {
    global
    Paused := !Paused
    Menu, Tray, % Paused ? "Check" : "UnCheck", Pause button handling
}

MenuStartup() {
    global
    if StartupEnabled()
    {
        RegRead, ignored, HKCU\Software\Microsoft\Windows\CurrentVersion\Run, HPKeys
        RegDelete, HKCU\Software\Microsoft\Windows\CurrentVersion\Run, HPKeys
    }
    else
        RegWrite, REG_SZ, HKCU\Software\Microsoft\Windows\CurrentVersion\Run, HPKeys, % StartupCmd()
    Menu, Tray, % StartupEnabled() ? "Check" : "UnCheck", Run at startup
}

MenuExit() {
    ExitApp
}

StartupEnabled() {
    RegRead, v, HKCU\Software\Microsoft\Windows\CurrentVersion\Run, HPKeys
    return (ErrorLevel = 0)
}

StartupCmd() {
    if A_IsCompiled
        return """" A_ScriptFullPath """"
    return """" A_AhkPath """ """ A_ScriptFullPath """"
}

;--- configuration ----------------------------------------------------------------
LoadConfig() {
    global
    IniRead, OSD, % IniPath, Settings, OSD, 1
    IniRead, OSD_Send, % IniPath, Settings, OSD_Send, 1
    IniRead, OSD_Timeout, % IniPath, Settings, OSD_Timeout, 1200
    IniRead, OSD_Font, % IniPath, Settings, OSD_Font, Arial
    IniRead, OSD_Size, % IniPath, Settings, OSD_Size, 48
    IniRead, OSD_Color, % IniPath, Settings, OSD_Color, 00FF00
    IniRead, OSD_Transparent, % IniPath, Settings, OSD_Transparent, 1
    IniRead, OSD_OffsetX, % IniPath, Settings, OSD_OffsetX, 16
    IniRead, OSD_OffsetY, % IniPath, Settings, OSD_OffsetY, 48
    IniRead, DebugMode, % IniPath, Settings, Debug, 0
    IniRead, IconMode, % IniPath, Settings, Icon, auto
    if !RegExMatch(OSD_Color, "^[0-9A-Fa-f]{6}$")
        OSD_Color := "00FF00"
    if OSD_Timeout is not integer
        OSD_Timeout := 1200
    if (OSD_Timeout < 200)
        OSD_Timeout := 200
    if OSD_Size is not integer
        OSD_Size := 48
    Loop % BtnNames.Length()
    {
        name := BtnNames[A_Index]
        IniRead, a, % IniPath, Buttons, % name, % ""
        if (a = "ERROR")                            ; missing key = unassigned, not a command
            a := ""
        Actions[name] := a
        IniRead, l, % IniPath, Labels, % name, % DefLabels[A_Index]
        if (l = "ERROR")
            l := DefLabels[A_Index]
        Labels[name] := l
    }
}

;;@@DEFAULTS_INI_BEGIN - generated by build.ahk from defaults.ini - do not edit
DefaultsIniText() {
    static s := "
(LTrim
; HPKeys Configuration
; --------------------
; Button actions have the form:    <Button> = <verb> <rest>
;   run  <command line>   Anything ShellExecute accepts: a program (with
;                         arguments), a document, a folder, or a URL. This is
;                         the default: a value with no keyword is treated as run.
;   url  <url>            Same as run; kept as a self-documenting alias.
;   send <keys>           AutoHotkey Send syntax, e.g. {Media_Next}, #e (Win+E),
;                         ^p (Ctrl+P), {F5}, {Esc}.
;   eject [D:]            Opens the optical drive tray (via MCI - the standard
;                         media-key ejection is unreliable on Windows 10).
;
; Send syntax:  https://www.autohotkey.com/docs/v1/lib/Send.htm
; Key names:    https://www.autohotkey.com/docs/v1/KeyList.htm
; Run syntax:   https://www.autohotkey.com/docs/v1/lib/Run.htm
;
; An empty value (or an omitted line) makes the button a no-op; the OSD still
; shows its label so you can see the button was recognized.
; The Volume knob and Mute are handled by Windows itself and are not mapped.

[Buttons]
; The five media keys are preconfigured. Everything else is a no-op until you
; map it. Examples are commented out: remove the leading semicolon to activate
; them, then edit to your taste.

; Media Buttons
Eject        = eject
PlayPause    = send {Media_Play_Pause}
Stop         = send {Media_Stop}
Prev         = send {Media_Prev}
Next         = send {Media_Next}

; Left-side buttons
;Help         = run https://www.autohotkey.com/docs/v1/
;HP           = run C:\cygwin\cygwin.bat
;Shortcut1    = send {F5}
;Shortcut2    = run notepad.exe

; Top-bar buttons
;Find          = send #e
;Print         = send ^p
;Fax           = run cmd.exe /c echo no fax modem detected
;Shopping      = run https://www.amazon.com/
;Entertainment = url https://www.netflix.com/
;Finance       = url https://www.fool.com/
;Connect       = run ncpa.cpl
;Search        = url https://google.com/
;People        = url https://facebook.com/
;EMail         = run https://gmail.com/


[Labels]
; What the OSD displays for each button - the text can be empty if you
; don't want anything displayed for a specific key, or you can disable
; all OSD (or just for remapped keys) in the [Settings] section below.

; Media Buttons
Eject = Eject
PlayPause = Play/Pause
Stop = Stop
Prev = Prev Track
Next = Next Track

; Left-side buttons
Help = Help
HP = HP
Shortcut1 = Shortcut 1
Shortcut2 = Shortcut 2

; Top-bar buttons
Find = Find
Print = Print
Fax = Fax
EMail = E-Mail
People = People
Search = Search
Connect = Connect
Finance = Finance
Entertainment = Entertainment
Shopping = Shopping

[Settings]

    ; Show the on-screen display when a button is pressed
OSD = 1

; Also show the OSD for send-type actions. To silence an individual button,
; set its [Labels] entry to an empty string, or set this to zero to
; disable the OSD for mapped keys.
OSD_Send = 1

; How long the OSD stays visible, in milliseconds
OSD_Timeout = 1200

; OSD font, size and text color (RRGGBB) - the classic Netropa utility green:
OSD_Font = Arial
OSD_Size = 48
OSD_Color = 00FF00

; 1 = OSD text floats on a transparent background; 0 = solid black box
OSD_Transparent = 1

; OSD position: offsets in pixels from the left edge / bottom edge of the
; primary monitor's work area (bottom-left corner of the screen)
OSD_OffsetX = 16
OSD_OffsetY = 16

; 1 = show a tray tooltip with the raw report and decoded button on each press
Debug = 0

; Tray icon: auto = HPKeys.ico next to the program if present, else the icon
; embedded at build time; default = the script/exe icon.
; Takes effect at next start.
Icon = auto
)"
    return s
}
;;@@DEFAULTS_INI_END

WriteDefaultIni() {
    global IniPath
    FileAppend, % DefaultsIniText(), % IniPath
}

;;@@ICON_B64_BEGIN - generated by build.ahk from HPKeys.ico - do not edit
IconB64Text() {
    static s := "
(LTrim
AAABAAEAICAAAAEAIACoEAAAFgAAACgAAAAgAAAAQAAAAAEAIAAAAAAAgBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
+vfz//v69v///v3////+//j4+P///////////////////////v7+//39/f/9/f3////+/////v////////39//3+/P////7////+
//r7+f/7+fn///7///r3+f/29fn/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+fLv//z39P////z/yMXB/8C8u/+0srH/sK6u/6en
p/+lpaX/np6e/5ycnP+ZmZn/nZ2d/5ycnP+am5n/mpiX/56amf+koJ//oZ+f/5+fn/+jpab/qKqq/7Sysv+zr67/29TR///+/P//
/vr////5///9+f////v////7//f28v//+/f/7Obh/4yGgf+OioX/iYaC/4yLh/+LiYj/iIaF/4yMjP+Hh4f/iYmJ/4mJif+IiIj/
iIiI/4aHhf+NjIj/kYuG/42Hgv+JhIX/jIuP/4OCi/+IiI7/iIWH/4+Ggv+OfXD/emBP/5l5Yv+kgmr/sZJ9/7efjf/97eD///vu
////+P9lXVb/ZFtX/3FrZv9oY2D/aWZi/2xqaf9jYWD/bm5u/25ubv9zc3P/dHR0/21tbf9qamr/YGFf/2dmYv9qZmH/aWRh/25s
bP9gX2P/eHeA/2BgZv9kYmL/amJb/4h1Zv9UOST/Wjgg/1o3Hf9dPSb/SjEd/3dlVP////L////3/4R9dP9dVU7/nZeS/3p1cv98
eXX/ioiH/2tpaP+Li4v/iYmJ/4iIiP+Li4v/hYWF/4iIiP9wcW//aWpo/29ycP9wdXP/h4yL/3l7fP96eXv/qqio/3l0c/+SjIf/
joN7/0U5L/9fVEb/T0Q2/0Y6Lv9CNir/g3dt////9f////j/pJ2U/1FFP/+dko7/qaOe/3Jva/91c3L/ent5/3p4eP99e3v/d3d3
/3R0dP9qamr/fH5+/3Z4eP99f3//eH18/3R6ef99goH/m6Cf/4iIiP+vraz/qqal/66npP+Lgn7/V09I/1pXT/9WVUv/ZV9Y/0Y+
N/+poJz////7//3+9f/Mxr//PCkm/6iVkv+dlJD/endy/3Z3c/9zdHD/e3Z1/3dycf93dXX/dHR0/3Fzc/91enn/dXp5/3J3dv98
fn7/eHp6/3R2d/+TlZb/c3V2/2VnaP9tbmz/dnFu/3ltZ/9dUEj/VVFG/1tXTP9TSED/NSkl/9PMyf/++/f/+/71/+nj3P9GMCv/
pIuH/4R4cv97eHD/fX13/3t7df+CeXb/iHx6/4J9ev+IhYH/fXt6/35/ff9zdHL/eXp4/398eP95dnL/eXRz/5uWl/93dXX/eXd2
/4F+ev+IgHn/dGNa/2dVSv9fVkj/X1ZI/3hnXv8xHxj///v3//r38//9/PL///30/0gwKv+dg33/iXly/8O8s/9ycGb/fHdu/4F0
bP+BcWr/o5iQ/351bP97c2z/e3Ns/4yEff+Si4L/fnRq/4N5b/+Ed2//eW5m/4+Ffv92bWT/eG9l/4l9cf97Zlf/XUY2/15QPv9e
UD7/XEY6/1RANf////j///nw//v57v////f/a1RM/25UTf+JenH/cWhe/2ljWP9sY1n/c2JZ/3VjWP9vXlX/al5S/3BkWP9yZlr/
b2NX/3JkWP9zY1b/cWFU/3FhVf9zZVn/bWFX/3BkWv9wZFj/d2da/1hBMv9POCj/RDUi/05ALv9INSj/hXNo////+P/68+r/9/Xr
////+P/Js63/jnZw/35vZv9gVkz/ZV1Q/11UR/9qWE3/Xks+/2pYTf9lVUj/ZVVI/11QQv9iUkX/XEw//15NQP9gT0L/Y1NH/1hJ
QP9iVU3/XFJI/11TSf9lV0v/Yk9C/35rXv93alz/b2RW/3hnXv/dzcb///fz//r18v8AAAAA+vfv///99////vj////4////+P//
//j////1///88/////X///3x////8/////X////x////9P////X////0////9/////j///74///99v////j///73///+9v///vf/
///4////+P////f////7///59v8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPXw8f8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAA=
)"
    return s
}
;;@@ICON_B64_END

;--- embedded icon decoding ------------------------------------------------------
; Decode a base64 string into a raw byte buffer; returns byte count or 0.
B64Decode(ByRef out, s) {
    s := StrReplace(StrReplace(s, "`r"), "`n")
    need := StrLen(s)
    VarSetCapacity(out, need + 16, 0)
    sz := 0
    if !DllCall("Crypt32\CryptStringToBinary", "Str", s, "UInt", need, "UInt", 1, "Ptr", &out, "UIntP", sz, "Ptr", 0, "Ptr", 0)
        return 0
    return sz
}

; Build a tray HICON from raw .ico file bytes: picks the 32x32 entry when
; present, otherwise the smallest entry above 32 or the largest below it.
IconFromIcoBytes(ByRef ico, len) {
    if (len < 22)
        return 0
    cnt := NumGet(ico, 4, "UShort")
    best := 0, bestScore := -1
    Loop %cnt%
    {
        e := 6 + (A_Index - 1) * 16
        w := NumGet(ico, e, "UChar"), w := w ? w : 256
        if (w = 32)
            score := 1000000
        else if (w > 32)
            score := 1000 - (w - 32)
        else
            score := w
        if (score > bestScore)
            best := e, bestScore := score, bestW := w
    }
    if (best = 0)
        return 0
    off := NumGet(ico, best + 12, "UInt")
    sz  := NumGet(ico, best + 8, "UInt")
    h   := NumGet(ico, best + 1, "UChar"), h := h ? h : 256
    if (off + sz > len)
        return 0
    return DllCall("user32\CreateIconFromResourceEx", "Ptr", &ico + off, "UInt", sz, "Int", 1, "UInt", 0x00030000, "Int", bestW, "Int", h, "UInt", 0, "Ptr")
}