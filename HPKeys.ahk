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
AAABAAMAICAAAAEAIACoEAAANgAAABgYAAABAAgAyAYAAN4QAAAQEAAAAQAIAGgFAACmFwAAKAAAACAAAABAAAAAAQAgAAAAAAAA
EAAAww4AAMMOAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////
AP///wD///8A////AP///wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD///8A/v7+AP///wD29fQA7evoAOXh3QDY0swAvbSrAHVh
TQD///8A////Av///wP///8E////Bf///wX///8F////Bf///wT///8D////Av///wBhSjQAuK6jANbQygDk4NwA7ernAPb19AD/
//8A/v7+AP///wAAAAAAAAAAAP///wD///8A////C/j39kTy8e9h8O7rb+3r6H7s6eaK6ufklejl4p/n5OCm5uPfrOXi3rHl4d6z
5eHdteXh3bXl4d6z5eLesebj36zn5OCm6OXin+rn5Jbs6eaM7uzqf/Dv7nHz8vFi+fr6RP///wv///8A//7+AAAAAAD///8A////
AP///wfs6eeQ1tHL99DJw//Ox8D/zca+/8zEvf/Lw7z/ysK7/8nCuv/Jwbr/ycG5/8nBuf/Iwbn/yMG5/8nBuf/Jwbn/ycG6/8nC
uv/Kwrv/y8O8/8vDvP/KvLL/y7yx/8y9s//TxLv36eHbkP///wf///8AAAAAAPz59wD9/fwA////KtrV0OvGvrX/xr62/8a+tv/G
vrb/xr62/8a+tv/Hvrb/x7+2/8e/tv/Hv7f/x7+3/8e/t//Hv7f/x7+3/8e/t//Hv7f/x7+3/8e/t//HwLj/waud/6xsS/+oZUL/
qGVC/6hkQf/GmIDr/fv6Kvv49wD///4A////AP///xzv492a0ce//MzFvf/RycP/0cnD/9HJw//RycP/0cnD/9HJw//RycP/0cnD
/9DJwv/QycL/0MnC/9DJwv/QycL/zcW+/8rCuv/Ox8D/z8fA/87Iwf+/o5P/nlcz/5dRL/+YUS//l1At/7d+Yfzz6OKD////C///
/wD///8I6dXLoryCZP/AppX/29bR/+7q5v/v6uf/7+rn/+/q5//v6uf/7+rn/+/q5//u6eb/6uXh/+rl4f/r5uL/6+bi/+vm4v/c
1dD/z8jB/9bPyf/Wz8n/1tDL/8Gmlv+waET/uG9K/7duSf+2bUj/q2I8/8aUevzz6eNw0quXAP///yXWsqDgsXJS/8CllP/c1tH/
7ejk/+3o5P/t6OT/7ejk/+3o5P/t6OT/7ejk/+zo5P/q5eH/6uXh/+rl4f/q5eH/6+bi/9zW0P/QycL/19DK/9fQyv/X0cz/wqeX
/69nQ/+1bUj/tWxI/7RrR/+oXTf/rWVA/+LJvLb///8H////LtGqluawcVD/wKWU/9zX0v/t6OT/7Ojk/+zo5P/s5+T/7Ofk/+zo
5P/s6OT/7Ojk/+zn5P/s5+T/7Ojk/+zo5P/t6OT/3dbR/9PMxv/m4d3/5+Ld/+bh3f/EqZn/r2dD/7ZtSP+2bUj/tWxH/6heOP+r
Yjz/3sGzwP///wz///8u0aqW5rBxUP/ApZT/3NfS/+vm4v/r5uL/6+bi/+vm4v/r5uL/6+bi/+vm4v/r5uL/6+bi/+vm4v/r5uL/
6+bi/+vm4//c1tD/1M3G/+nj3//p5OD/6OTg/8Spmf+xaUT/uW9K/7hvSv+3bkn/qV44/6tiPP/ewbPA////DP///y7RqpbmsHFQ
/8CllP/c19L/6+bi/+vm4v/r5uL/6uXi/+rl4v/r5uL/6+bi/+vm4v/q5eL/6uXi/+vm4v/r5uL/6+bi/9zW0P/Uzcb/6OPf/+nk
4P/o4+D/xKmZ/69nQ/+2bUj/tm1I/7RsR/+oXjj/q2I8/97Bs8D///8M////LtGqluawcVD/wKWU/9zX0v/t6OT/7ejk/+zo5P/s
5+T/7Ofk/+zo5P/t6OT/7Ojk/+zn5P/s5+T/7Ojk/+3o5P/t6OX/3dbR/9TNxv/o49//6eTg/+jj4P/EqZn/r2dD/7VtSP+1bEj/
tGtH/6heOP+rYjz/3sGzwP///wz///8u0aqW5rBxUP/ApZX/3NbR/+vm4v/q5eH/6uXh/+rl4f/q5eH/6uXh/+rl4f/q5eH/6uXh
/+rl4f/q5eH/6uXh/+vm4v/c1dD/1M3G/+nj3//p5OD/6OTg/8Spmf+waET/uG9K/7duSf+2bUj/qV44/6tiPP/ewbPA////DP//
/y7RqpbmsHFQ/8CllP/c1tH/6+bi/+rl4f/q5eH/6uXh/+rl4f/q5eH/6uXh/+rl4f/q5eH/6uXh/+rl4f/q5eH/6+bi/9zV0P/T
zMb/5+Le/+jj3//m4t7/xKqb/55XNP+XUS7/l1Eu/5hSL/+kWzX/q2I9/97Bs8D///8M////LtGqluawcE//uZF7/8zCuv/Px7//
z8a//8/Gv//Pxr//z8a//8/Gv//Pxr//z8a//8/Gv//Pxr//z8a//8/Gv//Px7//zMO7/8nAuP/Pxr//z8e//8/Gv//Ftqv/t5B6
/7OIcf+0iHD/tIhv/691Vv+rYjz/3sGzwP///wz///8uz6WP5qdZMf+qYj3/r3RV/7B4Wf+wd1n/sHdZ/7B3Wf+wd1n/sHdZ/7B3
Wf+wd1n/sHdZ/7B3Wf+wd1n/sHdZ/7B3Wf+wd1n/sHdZ/7B3WP+wd1j/sHdY/7F4Wv+xeVz/tYNo/7WUgf+1inP/q2RA/6thPP/e
wbPA////DP///ynRqZTjp1oz/6hbNP+wb07/sG5L/7BvTf+xcVD/sG9N/7BuS/+xcE7/sXFP/7BuTP+wbkz/sXFP/7FwTv+vbUv/
snNT/7h+YP+4f2H/uH9h/7h/YP+5f2L/r2pG/6ldNf+eeWX/YlhS/31sYv+sbk7/q2I8/+DFt7v///8K////DuPLv7i2dlX/q2I8
/7BuTP+wbkv/sG5M/7FwTv+wbkz/sG5L/7FvTf+xb07/sG5M/7BuTP+xb07/sW9N/7BtS/+ycVD/tXhY/7V4WP+1eFj/tXhY/7Z5
Wf+va0j/r2hD/5J6bP9QSEL/YllS/657YP+/hmn/7+DZhgwAAAD48vAA/fz7L+rXzp7fw7TA3sCxwd7AscHewLHB3sCxwd7AscHe
wLHB3sCxwd7AscHewLHB3sCxwd7AscHewLHB3sCxwd7AscHdwLDB3cCwwd3AsMHdwLDB3cCwwd7AscDgxbbG3NHL9Kmjn//Bu7f/
5tPK2O7g2If///8Y////ANm4pwD69vQA////Av///wr///8K////Cv///wr///8K////Cv///wr///8K////Cv///wr///8K////
Cv///wr///8K////Cv///wr///8K////Cv///wr///8K////Cv///w7///9W////oP///4b///8lrWQ/AP///wD9+/sA////AP//
/wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD///8A////AP///wD/
//8A////AP///wD///8A////AP7+/gD///8A9/X0AP///wD///8A////AP///wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD///8A////
AP///wD///8A////AP///wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////////////
////////////////////4Af/4AAAB8AAAAPAAAADgAAAAQAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAYAAAAHAAAAH/////////////////////////////////////ygAAAAYAAAAMAAAAAEACAAAAAAAQAIAAMMOAADDDgAA
AAEAAAABAAAAAAAA////AP37+QD+/v0A/v7+AO3r6ADs6ecA////AP///wD///8A////AP///wD///8A////AP///wD+/v4A////
AP///wD///8A69rRANe0ogDWsZ8A1rKgANWxnwDWs6AA1bGeANWwnQDYuqoA28O2APDi2wD///8A+fTxAM6jjQD///8A9eznAMWS
eAD9+/sAxZJ4AMWTeQDFk3kA/fv6APfv7ADImH8A//7+AP///wDbuqoA5Mu/AP///wD///8A39rUAM2kjwD///8A7+3rAOre1wD/
//8A////APn49wD19PIA8/HwAPHv7QDw7esA7uzqAO3r6ADt6ucA7OrnAPHw7gD09PMA9vb2APr7+wD///8A////AP///wD///8A
////AP///wD///8ArqWgAKafmgDDjnQAplkxAK5rSACydFQArWdDALN3VwCsZUAAtHlZAKtjPgC1elwAqmI8ALV8XgCoWzQAp1oy
AKdZMQCqZ0UAbF1TAGJWTwCobE0Aun1eAKhfOQCwdFUAsXlaALB2VwCyeVsAsHVWALJ6XACvdFQAsXdYAKuHcwCphnMAqmM/ALp9
XQC1hmwAzsO7ANHHvwDQx78AxbOnALCAZwCtel8ArXpeAKpnRAC6k30A3djTAOjj3wDo494A5eHcAMavoQCoYT4AuW9JAK9mQQCi
VzAA29bQAOTf2gDk3tkA4t3YAMWuoACzbEgA0IRdAMF2UACjWDEA29bRAOXf2gDi3tkAsmtIAM+DXADAdlAA3NfSAOfi3gDn4t0A
5ODbALyBYwC5kXsA0INcAKNXMADDpZMA2dPNAOLc1wDg29YAxK2eAK1mQwDFelQAt21IALBwUADIv7gAycG5AMnBugDJwroAysO7
AMCqmwCjXzwAoVo2AKBXMwDVz8kAz8jCAM3GvwDMxb0Ay8O8AMrCugDLxLwAy8G4AMaunwDGrJ0AzLOlAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBAQEBAQEBAQEBAQEBAQEBAQEB
AQEAAQEEBQBFRkdISUpLS0pJSEdGRQAGBAEBAQM3ODk6Ozw9Pj9AQD8+PTxBQkNENwEBATM0q6ytrq+msKWkpKWwprGys7S1NTYB
BzAxoqOkpKSkpaWlpaWlpKanqKmqMiECLC2Zmpubm5ubm5ubm5ubm5ydnp+goS4vKZWWgoODg4ODg4ODg4ODg4WGh5eJmCorIm54
kZKTk5OTk5OTk5OTkpSGjo+QiicoImF4i4yMjIyMjIyMjIyMjI2Gjo+QiiYkImF4goOEhISEhISEhISEg4WGh4iJiiYkImF4eXp7
e3t7e3t7e3t7enx9fn+AgSYkIm5vcHFxcXFxcXFxcXFxcXJzdHV2dyUkImFiY2RlZmVmZ2hnaGlpaWlpamtsbSMkH05PUFFSU1RV
VldYWVpbW1tcXV5fYCAhEhMUFRYVFhcWFxgZGBkZGRkaG0xNHB0eAQkKCwsLCwsLCwsLCwsLCwsMDQ4PEBEBAQEBAQEBAQEBAQEB
AQEBAQEBAQcIAQEBAAAAAAAAAAAAAAAAAAAAAAABAQEBAQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////AP///wD///8A////APgAHwDAAAMAgAABAAAAAQAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAABAP//5wD///8A////AP///wD///8AKAAAABAAAAAgAAAAAQAIAAAAAAAA
AQAAww4AAMMOAAAAAQAAAAEAAAAAAAD///8A/v39AP38+wD+/PwA+vn4APHv7gD9/PwA+/r5APz//wD39vUA+/v6AO7s6QDi3tkA
1M7IAMC3rwCmmYwAjHxrAOHd2QDu6+kA////AP///wD//v4A///+AP///wD///8A/f39APj39gD///8A////AOrYzwDLnYYAyJmA
AMiYgADImYEAyJqCAMSQdgDFkXYAupqJAMysmwDv4NgA2rqqAOHHuQDYtqQA4MW3AODGuADYtaQA2rmoAOLJvADt29IA0bmrAMST
egD06uUA7OrnAOLNwgD///8A/fz8APPy8ADv7esA7evoAOzp5gDr6OUA6ufkAO3r6QDw8O8A9fX1AP///wCUi4UArGZCALF2VwCx
dlgAsXdYALJ4WgCxd1kArW1MAK1tSwCndFkAknVkAK9yUgC2g2gA0sW8ANfMxADXzMMA183FAMm1qACveFsArnNUAK9uTQC5i3EA
3tjTAObh3QDm4dwA5uLeAM25rQC5c08AwHRNAK1oRQC5inEA3dfSAObg2wDl4NsAvXdTAMR4UgCuaUYAuotyAN7Y0gDm4t0AxHlS
AK9rSADUzcYA2tPNANnTzQDa1M8AyLOmAK9pRgCxZ0EA0szFAM7HwADMxb4AzMS9AMvEvADLw7wAyr20AL2ZhADAmYQAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAABAQEBAQEBAQEBAQEAAAoLDA0ODxARERAPDhITCwoIODk6Ozw9Pj49PD9AQUIJFDV0dXZ3eHl5eHZ6e3w2NzEy
bW5vbm5ubm5wcXJzMzQvaGlbW1tbW1tbal1la2wwLmFiY2RkZGRkZFpdZWZnLCtYWVpbW1tbW1tcXV5fYC0rT1BRUlJSUVJRU1RV
VlcsKURFRkdIR0VJSkpLTE1OKh4fICEiIyIhIiQkJSZDJygUFRYXFhYWFxYYGBkaGxwdAQIDAwMDAwMDAwMEBQYHAQAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//8AAP//AAD//wAAgAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AP//AAD//wAA//8AAA==
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