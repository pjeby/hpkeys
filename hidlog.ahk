; hidlog.ahk - raw HID report logger for the HP multimedia keyboard
; AHK v1.1 Unicode. Writes hid-log.txt next to the script. Ctrl+Alt+X quits.
#NoEnv
#SingleInstance Force

WM_INPUT        := 0x00FF
RIDEV_INPUTSINK := 0x100
RIDI_DEVICENAME := 0x20000000
RIDI_DEVICEINFO := 0x2000000b

WATCH_VID := "03F0"    ; HP
WATCH_ALL := false     ; set true to log every HID device instead

LogPath := A_ScriptDir "\hid-log.txt"
FileDelete %LogPath%

hdrSize := (A_PtrSize = 8) ? 24 : 16    ; sizeof(RAWINPUTHEADER)
listCb  := (A_PtrSize = 8) ? 16 : 8     ; sizeof(RAWINPUTDEVICELIST)
regCb   := (A_PtrSize = 8) ? 16 : 12    ; sizeof(RAWINPUTDEVICE)

Gui, +LastFound +ToolWindow
hGui := WinExist()

; enumerate all top-level collections
DllCall("GetRawInputDeviceList", "Ptr", 0, "UIntP", n, "UInt", listCb)
VarSetCapacity(list, n * listCb)
DllCall("GetRawInputDeviceList", "Ptr", &list, "UIntP", n, "UInt", listCb)

VarSetCapacity(reg, n * regCb)
DevH := Object(), DevT := Object()
regN := 0, seen := "|"
Loop % n
{
    hDev := NumGet(list, (A_Index - 1) * listCb, "Ptr")
    if (NumGet(list, (A_Index - 1) * listCb + A_PtrSize, "UInt") != 2)  ; 2=RIM_TYPEHID
        continue
    len := 0
    DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", RIDI_DEVICENAME, "Ptr", 0, "UIntP", len)
    VarSetCapacity(nm, len * 2)
    DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", RIDI_DEVICENAME, "Str", nm, "UIntP", len)
    VarSetCapacity(di, 32, 0), NumPut(32, di, 0, "UInt")
    DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", RIDI_DEVICEINFO, "Ptr", &di, "UIntP", sz := 32)
    vid   := Format("{:04X}", NumGet(di,  8, "UInt"))
    pid   := Format("{:04X}", NumGet(di, 12, "UInt"))
    page  := NumGet(di, 20, "UShort")
    usage := NumGet(di, 22, "UShort")
    cap   := "VID_" vid " PID_" pid "  page=0x" Format("{:04X}", page) " usage=0x" Format("{:04X}", usage)
    FileAppend TLC  %cap%  %nm%`n, %LogPath%
    DevH.Push(hDev), DevT.Push(cap)
    if (!WATCH_ALL && vid != WATCH_VID)
        continue
    if InStr(seen, "|" page "|" usage "|")
        continue
    seen .= page "|" usage "|"
    off := regN * regCb
    NumPut(page,           reg, off,     "UShort")
    NumPut(usage,          reg, off + 2, "UShort")
    NumPut(RIDEV_INPUTSINK, reg, off + 4, "UInt")
    regN++
}
if (regN = 0)
{
    MsgBox 48, hidlog, No HID collections matched VID_%WATCH_VID%.`nSee hid-log.txt for what exists`, then set WATCH_ALL := true and rerun.
    ExitApp
}
Loop % regN
    NumPut(hGui, reg, (A_Index - 1) * regCb + 8, "Ptr")
if !DllCall("RegisterRawInputDevices", "Ptr", &reg, "UInt", regN, "UInt", regCb)
{
    MsgBox 16, hidlog, RegisterRawInputDevices failed (err %A_LastError%).
    ExitApp
}
OnMessage(WM_INPUT, "OnWM_INPUT")
TrayTip hidlog, Listening on %regN% collections - press keys - log: %LogPath%, 1, 1
return

^!x::ExitApp

OnWM_INPUT(wParam, lParam)
{
    global hdrSize, LogPath, DevH, DevT
    static buf, cap_ := 0
    size := 0
    DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", 0, "UIntP", size, "UInt", hdrSize)
    if (size > cap_)
        VarSetCapacity(buf, cap_ := size + 64)
    if (DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", &buf, "UIntP", size, "UInt", hdrSize) <= 0)
        return
    if (NumGet(buf, 0, "UInt") != 2)  ; RIM_TYPEHID
        return
    hDev := NumGet(buf, 8, "Ptr")
    idx := 0
    Loop % DevH.Length()
        if (DevH[A_Index] = hDev)
        {
            idx := A_Index
            break
        }
    if (idx = 0)
        return
    repSize := NumGet(buf, hdrSize,     "UInt")
    repCnt  := NumGet(buf, hdrSize + 4, "UInt")
    if (repSize < 1 || repCnt < 1)
        return
    hex := ""
    Loop % repSize * repCnt
        hex .= Format("{:02X} ", NumGet(buf, hdrSize + 8 + A_Index - 1, "UChar"))
    line := A_Hour ":" A_Min ":" A_Sec "." A_MSec "  " DevT[idx] "  report[" repSize "]x" repCnt "  " hex
    FileAppend %line%`n, %LogPath%
    ToolTip %line%
    SetTimer KillTip, -1200
    return
}

KillTip:
    ToolTip
return