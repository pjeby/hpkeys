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
; Build: Ahk2Exe with the "Unicode 32-bit" base. The tray icon is drawn at
; runtime (blue/grey keyboard); to give the exe file itself an icon, supply
; an .ico to Ahk2Exe as usual.
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
        hIcon := DrawIcon()
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
    global
    LoadConfig()
    TrayTip, HPKeys, Configuration reloaded., 1, 1
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

WriteDefaultIni() {
    global IniPath
    ini =
(
; HPKeys - configuration
; ----------------------
; Auto-generated on first run. Edit this file, then use "Reload config" in the
; tray menu (double-clicking the tray icon opens this file for editing).
;
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
; map it. Buttons: Eject PlayPause Stop Prev Next Find Print Fax HP
; Shortcut1 Shortcut2 Help EMail People Search Connect Finance
; Entertainment Shopping
Eject        = eject
PlayPause    = send {Media_Play_Pause}
Stop         = send {Media_Stop}
Prev         = send {Media_Prev}
Next         = send {Media_Next}
; Examples - remove the leading semicolon to activate:
;Shopping     = run https://www.amazon.com
;EMail        = run https://mail.proton.me
;Find         = send #e
;Print        = send ^p
;Fax          = run cmd.exe /c echo no fax modem detected
;HP           = url https://www.hp.com
;Shortcut1    = run C:\hp\kbd\dictate.exe
;Shortcut2    = run notepad.exe
;Help         = run https://www.autohotkey.com/docs/v1/

[Labels]
; What the OSD displays for each button (defaults shown)
Eject = Eject
PlayPause = Play/Pause
Stop = Stop
Prev = Prev Track
Next = Next Track
Find = Find
Print = Print
Fax = Fax
HP = HP
Shortcut1 = Shortcut 1
Shortcut2 = Shortcut 2
Help = Help
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
; set its [Labels] entry to an empty string.
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
OSD_OffsetY = 48
; 1 = show a tray tooltip with the raw report and decoded button on each press
Debug = 0
; Tray icon: auto = use HPKeys.ico next to this script if present, else the
; program-drawn blue/grey keyboard; default = script/exe icon.
; Takes effect at next start.
Icon = auto
)
    FileAppend, % ini, % IniPath
}

;--- tray icon (drawn at runtime per the SK-2506U shell geometry) --------------
DrawIcon() {
    hdc := DllCall("user32\GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("gdi32\CreateCompatibleDC", "Ptr", hdc, "Ptr")
    hbm := DllCall("gdi32\CreateCompatibleBitmap", "Ptr", hdc, "Int", 32, "Int", 32, "Ptr")
    DllCall("gdi32\SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    DllCall("user32\ReleaseDC", "Ptr", 0, "Ptr", hdc, "Ptr")
    if (!mdc || !hbm)
        return 0

    VarSetCapacity(mbits, 128, 0xFF)                ; AND mask: 1 = transparent
    Loop 32
    {
        y := A_Index - 1
        Loop 32
        {
            x := A_Index - 1
            c := IconPixel(x, y)
            if (c >= 0)
            {
                DllCall("gdi32\SetPixelV", "Ptr", mdc, "Int", x, "Int", y, "UInt", c, "Int")
                b := y * 4 + (x >> 3)
                NumPut(NumGet(mbits, b, "UChar") & ~(0x80 >> (x & 7)), mbits, b, "UChar")
            }
        }
    }
    hmask := DllCall("gdi32\CreateBitmap", "Int", 32, "Int", 32, "UInt", 1, "UInt", 1, "Ptr", &mbits, "Ptr")

    VarSetCapacity(ii, A_PtrSize = 8 ? 32 : 20, 0)
    NumPut(1, ii, 0, "UInt")                        ; fIcon = TRUE
    NumPut(0, ii, 4, "UInt"), NumPut(0, ii, 8, "UInt")
    NumPut(hmask, ii, A_PtrSize = 8 ? 16 : 12, "Ptr")
    NumPut(hbm,   ii, A_PtrSize = 8 ? 24 : 20, "Ptr")
    hIcon := DllCall("user32\CreateIconIndirect", "Ptr", &ii, "Ptr")
    DllCall("gdi32\DeleteDC", "Ptr", mdc, "Ptr")
    return hIcon
}

; Per-pixel icon color: -1 = transparent, else a COLORREF.
; Canvas 32x32; keyboard spans x1..x30 / y9..y22 with a light grey outline
; drawn on the 1px ring around the whole silhouette (for dark backgrounds).
;   Blue surround: x1..x30, y9..y18 - small rounded top corners, large
;   rounded bottom corners. Grey key well: x2..x21 from y11, protruding below
;   the surround to y22 (wrist rest, same grey, large rounded bottom corners).
;   Blue keypad zone: x22..x30; knob at its top.
IconPixel(x, y) {
    if InShape(x, y)
        return ShapeColor(x, y)
    if (InShape(x-1, y) || InShape(x+1, y) || InShape(x, y-1) || InShape(x, y+1)
      || InShape(x-1, y-1) || InShape(x+1, y-1) || InShape(x-1, y+1) || InShape(x+1, y+1))
        return RGB(200, 204, 208)                     ; light grey outline
    return -1
}

InShape(x, y) {
    ; grey key well + wrist rest (rounded bottom corners)
    if (x >= 2 && x <= 21 && y >= 11)
    {
        gBot := 22
        if (x <= 3 || x >= 20)
            gBot := 20
        else if (x <= 4 || x >= 19)
            gBot := 21
        if (y <= gBot)
            return 1
    }
    ; blue surround (small top / large bottom rounded corners)
    if (x >= 1 && x <= 30 && y >= 9 && y <= 18)
    {
        if (y = 9 && (x <= 2 || x >= 29))
            return 0
        if (y = 10 && (x = 1 || x = 30))
            return 0
        if (y = 18 && (x <= 3 || x >= 28))
            return 0
        if (y = 17 && (x <= 2 || x >= 29))
            return 0
        return 1
    }
    return 0
}

ShapeColor(x, y) {
    ; grey key well + wrist rest - uniform grey, no seam
    if (x >= 2 && x <= 21 && y >= 11)
    {
        gBot := 22
        if (x <= 3 || x >= 20)
            gBot := 20
        else if (x <= 4 || x >= 19)
            gBot := 21
        if (y <= gBot)
        {
            if (y <= 18 && (y = 13 || y = 15 || y = 17) && x >= 4 && x <= 19)
                return RGB(108, 112, 116)             ; key rows on the deck
            return RGB(152, 156, 160)
        }
    }
    ; blue surround
    if (y = 9 || y = 18 || x = 1 || x = 30)           ; edge shading
        return RGB(35, 80, 160)
    if (y = 10)                                       ; special-key strip
    {
        if (Mod(x - 4, 3) = 0 && x >= 4 && x <= 28)
            return RGB(90, 130, 185)                  ; dots
        return RGB(60, 110, 190)
    }
    if (x >= 24 && x <= 27 && y >= 11 && y <= 12)     ; volume knob
        return RGB(228, 230, 233)
    if (x >= 22 && (y = 14 || y = 17) && x <= 29)     ; keypad key rows
        return RGB(45, 90, 165)
    return RGB(60, 110, 190)
}

RGB(r, g, b) {
    return (b << 16) | (g << 8) | r                  ; COLORREF: 0x00BBGGRR
}
