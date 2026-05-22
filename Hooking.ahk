#Requires AutoHotkey v2.0
#SingleInstance Force

; ==========================================================
; Hooking - Telegram 자동화(좌표 기반)
; - 각 창마다: 창 최신화 / 공감 클릭 / 메시지 입력+Enter 전송
; - 현재 가상화면에서 감지된 모든 Telegram 창 대상
; - 다중실행: 선택한 가상화면(D1~D10)으로 이동하며 실행(딜레이 사용자 지정)
; - 중단: F12
; ==========================================================

CoordMode "Mouse", "Client"
SetTitleMatchMode 2

global StopFlag := false
Hotkey "F12", StopAll
; 자동 팝업 GUI 핸들(초기값 필수: 미할당 상태면 클릭 이벤트에서 오류 발생)
global _autoPopupGui := 0
; 완료 팝업 등 클릭으로 즉시 닫기(좌/우클릭)
OnMessage(0x201, AutoPopup_Click) ; WM_LBUTTONDOWN
OnMessage(0x204, AutoPopup_Click) ; WM_RBUTTONDOWN

; ---------- 설정 ----------
global IniPath := A_ScriptDir "\Hooking.ini"
global CFG := LoadConfig(IniPath)

; ---------- 가상 데스크톱 DLL(번호로 바로 이동) ----------
; VirtualDesktopAccessor.dll(또는 vDesktop.dll)을 hooking 폴더에 두면
; Ctrl+Win+Left/Right 없이 데스크톱 번호로 바로 이동합니다.
global VDA := InitVDA()
; Hooking 프로그램이 실행되는(홈) 가상화면 번호(1-based)
; (실행 시작 시점에 갱신됩니다. GetCurrentDesktopNumber 미지원 환경도 대비)
global HOME_DESKTOP := 1
; 최근 메시지 파일(최대 5개)
global recentMsgPaths := CFG.RecentMsgFiles
global LAST_SENT_MSG := ""

; ---------- GUI ----------
; AlwaysOnTop 해제(사용자가 창을 가리지 않게)
app := Gui("+Resize", "Hooking (Telegram)")
app.SetFont("s10", "Segoe UI")
; 버튼 배경색 표시를 위해 테마 비활성화(환경에 따라 기본 버튼은 색상 변경이 무시될 수 있음)
app.Opt("-Theme")

app.AddText("xm ym", "상태:")
lblStatus := app.AddText("x+m w520", "준비됨")

app.AddGroupBox("xm y+8 w670 h78 Section", "실행 딜레이(초) - 창 넘어갈 때")
app.AddText("xs+10 ys+26 w60", "최신화")
edtDelayRefMin := app.AddEdit("x+6 yp-3 w45 h22", Round(CFG.DelayRefreshMinMs/1000, 2))
app.AddText("x+6 yp+3", "~")
edtDelayRefMax := app.AddEdit("x+6 yp-3 w45 h22", Round(CFG.DelayRefreshMaxMs/1000, 2))

app.AddText("x+20 ys+26 w45", "공감")
edtDelayReactMin := app.AddEdit("x+6 yp-3 w45 h22", Round(CFG.DelayReactMinMs/1000, 2))
app.AddText("x+6 yp+3", "~")
edtDelayReactMax := app.AddEdit("x+6 yp-3 w45 h22", Round(CFG.DelayReactMaxMs/1000, 2))

app.AddText("x+20 ys+26 w45", "메시지")
edtDelaySendMin := app.AddEdit("x+6 yp-3 w45 h22", Round(CFG.DelaySendMinMs/1000, 2))
app.AddText("x+6 yp+3", "~")
edtDelaySendMax := app.AddEdit("x+6 yp-3 w45 h22", Round(CFG.DelaySendMaxMs/1000, 2))

app.AddText("xm y+8", "최신화 PgDn 횟수:")
edtRefreshCount := app.AddEdit("x+m yp-3 w60 h22", CFG.RefreshPgDnCount)

; 설정 자동 저장(입력 후 Enter / 포커스 이동 / 타이핑 종료 시 저장)
for c in [edtDelayRefMin, edtDelayRefMax, edtDelayReactMin, edtDelayReactMax, edtDelaySendMin, edtDelaySendMax, edtRefreshCount] {
    c.OnEvent("Change", SettingsEdited)
    ; 일부 환경에서 LoseFocus 이벤트가 없을 수 있어 try로 보호
    try c.OnEvent("LoseFocus", SettingsEdited)
}

; ---------- 가상 데스크톱 이동(D1~D10, 단일 선택) ----------
app.AddGroupBox("xm y+10 w670 h70 Section", "가상화면 이동 (프로그램 GUI)")
global moveDesktopBtns := Map()
global moveDesktopCtrlToNum := Map()
global selectedMoveDesktop := 1

Loop 10 {
    n := A_Index
    x := "xs+" (10 + (n - 1) * 62)
    y := "ys+24"
    b := app.AddCheckBox(x " " y " w58 h24 +0x1000", "D" n)  ; BS_PUSHLIKE
    moveDesktopCtrlToNum[b.Hwnd] := n
    b.OnEvent("Click", MoveDesktopBtn_Click)
    moveDesktopBtns[n] := b
}
RefreshMoveDesktopButtons()

; ---------- 가상 데스크톱 선택(D1~D10, 멀티 선택) ----------
; 버튼 아래 라벨(2글자) 입력칸이 있어 높이를 조금 더 줍니다.
app.AddGroupBox("xm y+10 w670 h110 Section", "가상화면 선택 (D1~D10, 여러개 선택 가능)")
global desktopBtns := Map()
global selectedDesktops := Map()  ; key: desktop number, value: true
global desktopCtrlToNum := Map()  ; key: control hwnd, value: desktop number
global desktopLabelEdits := Map() ; key: desktop number, value: edit control
global desktopLabelCtrlToNum := Map() ; key: edit hwnd, value: desktop number

Loop 10 {
    n := A_Index
    x := "xs+" (10 + (n - 1) * 62)
    y := "ys+24"
    ; 토글(눌림 유지) 버튼처럼 보이게: 체크박스를 PushLike로 사용
    b := app.AddCheckBox(x " " y " w58 h24 +0x1000", "D" n)  ; BS_PUSHLIKE
    desktopCtrlToNum[b.Hwnd] := n
    b.OnEvent("Click", DesktopBtn_Click)
    desktopBtns[n] := b

    ; 버튼 아래 라벨(20글자) - 바로 저장
    e := app.AddEdit(x " ys+52 w58 h22 Center")
    e.Opt("Limit20")
    try {
        e.Value := IniRead(IniPath, "DesktopLabels", "D" n, "")
    } catch {
        e.Value := ""
    }
    desktopLabelEdits[n] := e
    desktopLabelCtrlToNum[e.Hwnd] := n
    e.OnEvent("Change", DesktopLabel_Changed)
}
btnClearDesktop := app.AddButton("xs+10 ys+80 w120 h24", "선택해제")
btnClearDesktop.OnEvent("Click", (*) => ClearDesktopSelection())
RefreshDesktopButtons()

; ---------- 좌표 찍기/저장 ----------
app.AddGroupBox("xm y+12 w670 h110", "좌표(직접 찍기)")
app.AddText("xm+10 yp+26 w140 Section", "공감(👍):")
; 세 버튼을 정확히 같은 y(ys)로 고정
btnPickThumb := app.AddButton("x+m ys-3 w60 h24", "좌표1")
btnPickThumb2 := app.AddButton("x+m ys-3 w60 h24", "좌표2")
btnPickThumb3 := app.AddButton("x+m ys-3 w60 h24", "좌표3")
; 좌표 표시(버튼 아래 한 줄로 1/2/3 모두 보이게)
lblThumb := app.AddText("xm+10 yp+34 w650", "(좌표 미설정)")

btnPickThumb.OnEvent("Click", (*) => PickCoord("thumb1"))
btnPickThumb2.OnEvent("Click", (*) => PickCoord("thumb2"))
btnPickThumb3.OnEvent("Click", (*) => PickCoord("thumb3"))

; ---------- 메시지(20개) ----------
; 여백/간격이 일정하도록 Section 기준으로 고정 배치
app.AddGroupBox("xm y+10 w670 h300 Section", "메시지 목록(랜덤 1개 전송)")
msgEdits := []
rowStep := 22
startY := 30
Loop 20 {
    i := A_Index
    col := (i <= 10) ? 0 : 1
    row := (i <= 10) ? i : (i - 10)
    xLabel := (col = 0) ? "xs+10" : "xs+340"
    yPos := "ys+" (startY + (row - 1) * rowStep)

    app.AddText(xLabel " " yPos " w26 h18", i)
    e := app.AddEdit("x+8 yp-3 w280 h20", "")
    msgEdits.Push(e)
}
btnMsgSave := app.AddButton("xs+10 ys+260 w150 h28", "메시지 저장")
btnMsgLoad := app.AddButton("x+10 yp w150 h28", "메시지 불러오기")
btnMsgSave.OnEvent("Click", (*) => SaveMessages())
btnMsgLoad.OnEvent("Click", (*) => LoadMessages())

; 최근 메시지 파일(5개) - 클릭하면 즉시 불러오기
app.AddGroupBox("xm y+10 w670 h140", "최근 메시지 (클릭하면 바로 불러오기)")
lstRecent := app.AddListBox("xm+10 yp+28 w650 h100")
lstRecent.OnEvent("Change", RecentMsg_Selected)
RefreshRecentListUI()

; 가상화면 다중 실행(창 최신화/공감/메시지)
btnMultiArrow := app.AddButton("xm+10 y+12 w200 h32", "다중실행: 창 최신화")
btnMultiThumb := app.AddButton("x+m yp w200 h32", "다중실행: 공감")
btnMultiSend := app.AddButton("x+m yp w200 h32", "다중실행: 메시지")
btnMultiArrow.OnEvent("Click", (*) => RunOnSelectedDesktops("arrow"))
btnMultiThumb.OnEvent("Click", (*) => RunOnSelectedDesktops("thumb"))
btnMultiSend.OnEvent("Click", (*) => RunOnSelectedDesktops("send"))

btnMultiComboRT := app.AddButton("xm+10 y+10 w305 h32", "다중실행: 최신화+공감")
btnMultiComboRTS := app.AddButton("x+m yp w305 h32", "다중실행: 최신화+공감+메시지")
btnMultiComboRT.OnEvent("Click", (*) => RunOnSelectedDesktopsCombo(["arrow", "thumb"]))
btnMultiComboRTS.OnEvent("Click", (*) => RunOnSelectedDesktopsCombo(["arrow", "thumb", "send"]))

app.AddText("xm y+10 cGray", "팁: 메시지는 랜덤 1개 전송, 창 순서는 랜덤입니다. F12 누르면 모든 작업 즉시 중단됩니다.")
app.OnEvent("Close", (*) => ExitApp())

RefreshCoordLabels()
AutoLoadLastMessages()
app.Show()
SetHomeDesktop()  ; 프로그램이 있는 가상화면 저장(복귀용)
selectedMoveDesktop := HOME_DESKTOP
RefreshMoveDesktopButtons()

; ---------- 핵심 로직 ----------

RunOnSelectedDesktops(action) {
    global selectedDesktops, VDA
    global StopFlag
    SetHomeDesktop()
    StopFlag := false
    desktops := []
    for k, _v in selectedDesktops
        desktops.Push(k)
    if (desktops.Length < 1) {
        AutoPopup("선택된 가상화면(D1~D10)이 없습니다.", "안내", 48, 1.5)
        return
    }
    ; 가상화면 존재 여부 선검사(D9인데 실제 데스크톱이 없으면 팝업 후 중지)
    if (VDA.ok && VDA.GetDesktopCountProc) {
        cnt := 0
        try {
            cnt := DllCall(VDA.GetDesktopCountProc, "Int")
        } catch {
            cnt := 0
        }
        if (cnt > 0) {
            for d in desktops {
                if (d < 1 || d > cnt) {
                    AutoPopup("가상화면이 없습니다: D" d " (현재 " cnt "개)", "안내", 48, 2)
                    return
                }
            }
        }
    }
    ArraySort(desktops, (a, b) => a - b)
    MinimizeGuiForRun()
    RunActionAcrossDesktops(action, desktops)
    ReturnHome()
    RestoreGuiAfterRun()
    if (!StopFlag)
        AutoPopup("프로세스가 완료되었습니다.", "완료", 64, 1.2)
}

RunOnSelectedDesktopsCombo(actions) {
    global selectedDesktops, VDA
    global StopFlag
    SetHomeDesktop()
    StopFlag := false
    desktops := []
    for k, _v in selectedDesktops
        desktops.Push(k)
    if (desktops.Length < 1) {
        AutoPopup("선택된 가상화면(D1~D10)이 없습니다.", "안내", 48, 1.5)
        return
    }
    ; 가상화면 존재 여부 선검사
    if (VDA.ok && VDA.GetDesktopCountProc) {
        cnt := 0
        try {
            cnt := DllCall(VDA.GetDesktopCountProc, "Int")
        } catch {
            cnt := 0
        }
        if (cnt > 0) {
            for d in desktops {
                if (d < 1 || d > cnt) {
                    AutoPopup("가상화면이 없습니다: D" d " (현재 " cnt "개)", "안내", 48, 2)
                    return
                }
            }
        }
    }
    ArraySort(desktops, (a, b) => a - b)
    MinimizeGuiForRun()
    RunActionsAcrossDesktops(actions, desktops)
    ReturnHome()
    RestoreGuiAfterRun()
    if (!StopFlag)
        AutoPopup("프로세스가 완료되었습니다.", "완료", 64, 1.2)
}

RunActionAcrossDesktops(action, desktops) {
    global StopFlag, CFG
    for d in desktops {
        if (StopFlag) {
            SetStatus("중단됨")
            ReturnHome()
            return
        }
        SetStatus("가상화면 D" d "로 이동…")
        ok := GoToDesktop(d)
        if (!ok) {
            SetStatus("가상화면 이동 실패(DLL 확인 필요)")
            ReturnHome()
            return
        }
        if (!SleepCancelable(700))
        {
            ReturnHome()
            return
        }
        map := DetectCurrentDesktopOrStop("D" d)
        if (!map) {
            StopFlag := true
            ReturnHome()
            return
        }
        RunActionOnSlots(action, MakeIndexList(map.Length), map)
        ; 데스크톱 사이에도 딜레이(사용자 설정)
        dr := GetDelayRangeMs(action)
        if (!SleepCancelable(Random(dr.min, dr.max)))
        {
            ReturnHome()
            return
        }
    }
    SetStatus("완료")
}

RunActionsAcrossDesktops(actions, desktops) {
    global StopFlag, CFG
    for d in desktops {
        if (StopFlag) {
            SetStatus("중단됨")
            ReturnHome()
            return
        }
        SetStatus("가상화면 D" d "로 이동…")
        ok := GoToDesktop(d)
        if (!ok) {
            SetStatus("가상화면 이동 실패(DLL 확인 필요)")
            ReturnHome()
            return
        }
        if (!SleepCancelable(700)) {
            ReturnHome()
            return
        }
        map := DetectCurrentDesktopOrStop("D" d)
        if (!map) {
            StopFlag := true
            ReturnHome()
            return
        }
        for a in actions {
            if (StopFlag) {
                ReturnHome()
                return
            }
            RunActionOnSlots(a, MakeIndexList(map.Length), map)
        }
        last := actions[actions.Length]
        dr := GetDelayRangeMs(last)
        if (!SleepCancelable(Random(dr.min, dr.max))) {
            ReturnHome()
            return
        }
    }
    SetStatus("완료")
}

; ---------- 프로그램 GUI 가상화면 이동 ----------
MoveGuiToDesktop(n) {
    global VDA, app
    if (!VDA.ok) {
        AutoPopup("가상화면 이동 기능을 사용하려면 VirtualDesktopAccessor.dll(또는 vDesktop.dll)이 필요합니다.", "안내", 48, 2)
        return false
    }
    if (!VDA.MoveWindowToDesktopNumberProc) {
        AutoPopup("현재 DLL에서 MoveWindowToDesktopNumber 함수를 찾지 못했습니다.", "안내", 48, 2)
        return false
    }

    ; 이미 해당 가상화면이면 이동 생략
    if (GetCurrentDesktopOneBased() = n) {
        SetHomeDesktop()
        return true
    }

    hwnd := 0
    try {
        hwnd := app.Hwnd
    } catch {
        hwnd := 0
    }
    if (!hwnd)
        return false

    target := n - 1  ; 0-based
    try {
        DllCall(VDA.MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", target, "Int")
    } catch {
        ; ignore
    }

    ; 화면 전환(사용자에게 보이도록)
    if (!GoToDesktop(n))
        return false

    SetHomeDesktop()
    return true
}

MoveDesktopBtn_Click(ctrl, *) {
    global moveDesktopCtrlToNum, selectedMoveDesktop
    n := 0
    try {
        n := moveDesktopCtrlToNum[ctrl.Hwnd]
    } catch {
        return
    }
    selectedMoveDesktop := n
    RefreshMoveDesktopButtons()
    MoveGuiToDesktop(n)
    ; 이동 후 홈/현재 데스크톱이 바뀔 수 있어 다시 반영
    selectedMoveDesktop := HOME_DESKTOP
    RefreshMoveDesktopButtons()
}

RefreshMoveDesktopButtons() {
    global moveDesktopBtns, selectedMoveDesktop
    for n, b in moveDesktopBtns {
        if (n = selectedMoveDesktop)
            b.Value := 1
        else
            b.Value := 0
    }
}

ToggleDesktop(n) {
    global selectedDesktops
    if selectedDesktops.Has(n)
        selectedDesktops.Delete(n)
    else
        selectedDesktops[n] := true
    RefreshDesktopButtons()
}

DesktopBtn_Click(ctrl, *) {
    global desktopCtrlToNum
    n := 0
    try {
        n := desktopCtrlToNum[ctrl.Hwnd]
    } catch {
        return
    }
    ToggleDesktop(n)
}

DesktopLabel_Changed(ctrl, *) {
    global desktopLabelCtrlToNum, IniPath
    n := 0
    try {
        n := desktopLabelCtrlToNum[ctrl.Hwnd]
    } catch {
        return
    }
    v := ""
    try {
        v := ctrl.Value
    } catch {
        v := ""
    }
    ; 혹시 20글자 넘으면 자름(대부분 Limit20으로 해결되지만 안전장치)
    if (StrLen(v) > 20)
        v := SubStr(v, 1, 20)
    try {
        IniWrite v, IniPath, "DesktopLabels", "D" n
    } catch {
        ; ignore
    }
}

ClearDesktopSelection() {
    global selectedDesktops
    selectedDesktops := Map()
    RefreshDesktopButtons()
}

RefreshDesktopButtons() {
    global desktopBtns, selectedDesktops
    for n, b in desktopBtns {
        if selectedDesktops.Has(n) {
            b.Value := 1
            ; 선택됨: 빨간색으로 표시
            b.Opt("BackgroundFF3B30")
            b.SetFont("cFFFFFF")
        } else {
            b.Value := 0
            b.Opt("BackgroundFFFFFF")
            b.SetFont("c000000")
        }
    }
}

GoToDesktop(n) {
    global VDA
    if (!VDA.ok) {
        AutoPopup(
            "가상화면 번호로 바로 이동하려면 VirtualDesktopAccessor.dll(또는 vDesktop.dll)이 필요합니다.`n"
            . "hooking 폴더에 DLL을 넣은 뒤 다시 실행하세요.",
            "안내",
            48,
            2.5
        )
        return false
    }
    ; DLL은 0-based 번호를 받는 경우가 많아 D1 -> 0 변환
    target := n - 1
    if (VDA.GetDesktopCountProc) {
        cnt := 0
        try {
            cnt := DllCall(VDA.GetDesktopCountProc, "Int")
        } catch {
            cnt := 0
        }
        if (cnt > 0 && (target < 0 || target >= cnt)) {
            AutoPopup("가상화면이 없습니다: D" n " (현재 " cnt "개)", "안내", 48, 2)
            return false
        }
    }
    try {
        DllCall(VDA.GoToDesktopNumberProc, "Int", target, "Int")
        return true
    } catch {
        return false
    }
}

InitVDA() {
    v := { ok: false
        , dll: ""
        , h: 0
        , GoToDesktopNumberProc: 0
        , MoveWindowToDesktopNumberProc: 0
        , IsWindowOnCurrentVirtualDesktopProc: 0
        , GetDesktopCountProc: 0
        , GetCurrentDesktopNumberProc: 0
        , GetWindowDesktopNumberProc: 0 }

    dll1 := A_ScriptDir "\VirtualDesktopAccessor.dll"
    dll2 := A_ScriptDir "\vDesktop.dll"
    dll := ""
    if FileExist(dll1)
        dll := dll1
    else if FileExist(dll2)
        dll := dll2

    if (dll = "")
        return v

    try {
        h := DllCall("Kernel32.dll\LoadLibrary", "Str", dll, "Ptr")
    } catch {
        return v
    }
    if (!h)
        return v

    proc := 0
    try {
        proc := DllCall("Kernel32.dll\GetProcAddress", "Ptr", h, "AStr", "GoToDesktopNumber", "Ptr")
    } catch {
        proc := 0
    }
    if (!proc) {
        ; 일부 빌드에서 함수명이 GoToDesktopNumber가 아닐 수 있어 안전하게 종료
        return v
    }

    isProc := 0
    try {
        isProc := DllCall("Kernel32.dll\GetProcAddress", "Ptr", h, "AStr", "IsWindowOnCurrentVirtualDesktop", "Ptr")
    } catch {
        isProc := 0
    }

    cntProc := 0
    try {
        cntProc := DllCall("Kernel32.dll\GetProcAddress", "Ptr", h, "AStr", "GetDesktopCount", "Ptr")
    } catch {
        cntProc := 0
    }

    curProc := 0
    try {
        curProc := DllCall("Kernel32.dll\GetProcAddress", "Ptr", h, "AStr", "GetCurrentDesktopNumber", "Ptr")
    } catch {
        curProc := 0
    }

    winProc := 0
    try {
        winProc := DllCall("Kernel32.dll\GetProcAddress", "Ptr", h, "AStr", "GetWindowDesktopNumber", "Ptr")
    } catch {
        winProc := 0
    }

    mvProc := 0
    try {
        mvProc := DllCall("Kernel32.dll\GetProcAddress", "Ptr", h, "AStr", "MoveWindowToDesktopNumber", "Ptr")
    } catch {
        mvProc := 0
    }

    v.ok := true
    v.dll := dll
    v.h := h
    v.GoToDesktopNumberProc := proc
    v.MoveWindowToDesktopNumberProc := mvProc
    v.IsWindowOnCurrentVirtualDesktopProc := isProc
    v.GetDesktopCountProc := cntProc
    v.GetCurrentDesktopNumberProc := curProc
    v.GetWindowDesktopNumberProc := winProc
    return v
}

GetCurrentDesktopOneBased() {
    global VDA
    if (!VDA.ok || !VDA.GetCurrentDesktopNumberProc)
        return 1
    cur := 0
    try {
        cur := DllCall(VDA.GetCurrentDesktopNumberProc, "Int")
    } catch {
        cur := 0
    }
    return cur + 1
}

GetAppDesktopOneBased() {
    global VDA, app
    if (!VDA.ok || !VDA.GetWindowDesktopNumberProc)
        return 0
    hwnd := 0
    try {
        hwnd := app.Hwnd
    } catch {
        hwnd := 0
    }
    if (!hwnd)
        return 0
    n := 0
    try {
        n := DllCall(VDA.GetWindowDesktopNumberProc, "Ptr", hwnd, "Int")
    } catch {
        n := 0
    }
    return n + 1
}

SetHomeDesktop() {
    global HOME_DESKTOP
    d := GetAppDesktopOneBased()
    if (d <= 0)
        d := GetCurrentDesktopOneBased()
    if (d <= 0)
        d := 1
    HOME_DESKTOP := d
}

MinimizeGuiForRun() {
    global app
    hwnd := 0
    try {
        hwnd := app.Hwnd
    } catch {
        hwnd := 0
    }
    if (!hwnd)
        return
    try {
        WinMinimize "ahk_id " hwnd
    } catch {
        ; ignore
    }
}

RestoreGuiAfterRun() {
    global app
    hwnd := 0
    try {
        hwnd := app.Hwnd
    } catch {
        hwnd := 0
    }
    if (!hwnd)
        return
    ; 최소화 상태일 때만 복구
    mm := 0
    try {
        mm := WinGetMinMax("ahk_id " hwnd)
    } catch {
        mm := 0
    }
    if (mm = -1) {
        try {
            WinRestore "ahk_id " hwnd
        } catch {
            ; ignore
        }
    }
    try {
        WinActivate "ahk_id " hwnd
    } catch {
        ; ignore
    }
}

ReturnHome() {
    global HOME_DESKTOP, VDA
    ; 홈(프로그램이 있는 가상화면)으로 복귀.
    ; 이미 홈에 있으면 이동 호출을 생략.
    if (VDA.ok && VDA.GetCurrentDesktopNumberProc) {
        cur := 0
        try {
            cur := DllCall(VDA.GetCurrentDesktopNumberProc, "Int")
        } catch {
            cur := 0
        }
        if ((cur + 1) = HOME_DESKTOP)
            return
    }
    GoToDesktopSilent(HOME_DESKTOP)
}

GoToDesktopSilent(n) {
    global VDA
    if (!VDA.ok)
        return false
    target := n - 1
    try {
        DllCall(VDA.GoToDesktopNumberProc, "Int", target, "Int")
        return true
    } catch {
        return false
    }
}

GetDelayRangeMs(action := "") {
    global CFG, edtDelayRefMin, edtDelayRefMax, edtDelayReactMin, edtDelayReactMax, edtDelaySendMin, edtDelaySendMax
    ; 액션별 기본값(ini)
    minMs := CFG.DelaySendMinMs
    maxMs := CFG.DelaySendMaxMs

    ; UI 값 우선
    if (action = "arrow") {
        minMs := CFG.DelayRefreshMinMs
        maxMs := CFG.DelayRefreshMaxMs
        try {
            a := edtDelayRefMin.Value + 0
            b := edtDelayRefMax.Value + 0
            minMs := Round(a * 1000)
            maxMs := Round(b * 1000)
        } catch {
            ; ignore
        }
    } else if (action = "thumb") {
        minMs := CFG.DelayReactMinMs
        maxMs := CFG.DelayReactMaxMs
        try {
            a := edtDelayReactMin.Value + 0
            b := edtDelayReactMax.Value + 0
            minMs := Round(a * 1000)
            maxMs := Round(b * 1000)
        } catch {
            ; ignore
        }
    } else if (action = "send") {
        minMs := CFG.DelaySendMinMs
        maxMs := CFG.DelaySendMaxMs
        try {
            a := edtDelaySendMin.Value + 0
            b := edtDelaySendMax.Value + 0
            minMs := Round(a * 1000)
            maxMs := Round(b * 1000)
        } catch {
            ; ignore
        }
    } else {
        ; 알 수 없는 액션이면 메시지 딜레이를 사용
        minMs := CFG.DelaySendMinMs
        maxMs := CFG.DelaySendMaxMs
    }

    if (maxMs < minMs)
        maxMs := minMs
    if (minMs < 0)
        minMs := 0
    if (maxMs < 0)
        maxMs := 0
    return { min: minMs, max: maxMs }
}

SaveDelaySettings(silent := false) {
    global IniPath, CFG, edtRefreshCount, edtDelayRefMin, edtDelayRefMax, edtDelayReactMin, edtDelayReactMax, edtDelaySendMin, edtDelaySendMax
    ; 액션별 딜레이 저장(초 -> ms)
    try {
        CFG.DelayRefreshMinMs := Round((edtDelayRefMin.Value + 0) * 1000)
        CFG.DelayRefreshMaxMs := Round((edtDelayRefMax.Value + 0) * 1000)
        CFG.DelayReactMinMs := Round((edtDelayReactMin.Value + 0) * 1000)
        CFG.DelayReactMaxMs := Round((edtDelayReactMax.Value + 0) * 1000)
        CFG.DelaySendMinMs := Round((edtDelaySendMin.Value + 0) * 1000)
        CFG.DelaySendMaxMs := Round((edtDelaySendMax.Value + 0) * 1000)
    } catch {
        ; ignore
    }

    ; 정합성 보정
    if (CFG.DelayRefreshMaxMs < CFG.DelayRefreshMinMs)
        CFG.DelayRefreshMaxMs := CFG.DelayRefreshMinMs
    if (CFG.DelayReactMaxMs < CFG.DelayReactMinMs)
        CFG.DelayReactMaxMs := CFG.DelayReactMinMs
    if (CFG.DelaySendMaxMs < CFG.DelaySendMinMs)
        CFG.DelaySendMaxMs := CFG.DelaySendMinMs

    IniWrite CFG.DelayRefreshMinMs, IniPath, "General", "DelayRefreshMinMs"
    IniWrite CFG.DelayRefreshMaxMs, IniPath, "General", "DelayRefreshMaxMs"
    IniWrite CFG.DelayReactMinMs, IniPath, "General", "DelayReactMinMs"
    IniWrite CFG.DelayReactMaxMs, IniPath, "General", "DelayReactMaxMs"
    IniWrite CFG.DelaySendMinMs, IniPath, "General", "DelaySendMinMs"
    IniWrite CFG.DelaySendMaxMs, IniPath, "General", "DelaySendMaxMs"

    ; 호환용 키(예전 DelayMin/Max): 최신화 값을 기록
    IniWrite CFG.DelayRefreshMinMs, IniPath, "General", "DelayMinMs"
    IniWrite CFG.DelayRefreshMaxMs, IniPath, "General", "DelayMaxMs"

    ; 최신화 PgDn 횟수도 함께 저장
    try {
        v := edtRefreshCount.Value + 0
        if (v < 1)
            v := 1
        if (v > 2000)
            v := 2000
        CFG.RefreshPgDnCount := Round(v)
        IniWrite CFG.RefreshPgDnCount, IniPath, "General", "RefreshPgDnCount"
    } catch {
        ; ignore
    }
    if (!silent)
        SetStatus("설정 저장됨(Hooking.ini)")
}

SettingsEdited(*) {
    ScheduleSettingsSave()
}

ScheduleSettingsSave() {
    ; 연속 타이핑 중에는 저장을 미루고, 입력이 잠깐 멈추면 자동 저장
    SetTimer(DoSettingsAutoSave, 0)      ; 기존 예약 취소
    SetTimer(DoSettingsAutoSave, -400)   ; 0.4초 후 1회 실행
}

DoSettingsAutoSave() {
    ; 조용히 저장(상태창 스팸 방지)
    SaveDelaySettings(true)
}

GetRefreshPgDnCount() {
    global edtRefreshCount, CFG
    v := CFG.RefreshPgDnCount
    try {
        t := edtRefreshCount.Value + 0
        if (t >= 1)
            v := Round(t)
    } catch {
        ; ignore
    }
    if (v < 1)
        v := 1
    if (v > 2000)
        v := 2000
    return v
}

MakeIndexList(n) {
    arr := []
    if (n < 1)
        return arr
    Loop n
        arr.Push(A_Index)
    return arr
}

RunActionOnSlots(action, slots, map := 0) {
    global StopFlag, CFG
    if (!IsObject(map))
        map := GetSlotMap()
    if (map.Length < 1)
        return false

    dr := GetDelayRangeMs(action)

    ; 실행 순서 랜덤(매번 바뀜)
    if (slots.Length > 1) {
        ArrayShuffle(slots)
    }

    for slot in slots {
        if (StopFlag) {
            SetStatus("중단됨")
            return
        }

        if (slot > map.Length) {
            SetStatus("슬롯 " slot "번: 창 없음(스킵)")
            continue
        }
        hwnd := map[slot].hwnd

        ok := DoAction(hwnd, action)
        if !ok {
            SetStatus("슬롯 " slot "번: 실패/스킵")
        }

        ; 전체 적용일 때만 딜레이
        if (slots.Length > 1) {
            ; 메시지는 "클릭 후 → 딜레이 → 글쓰기"로 동작해야 해서
            ; send 액션은 DoAction 내부에서 딜레이를 처리하고, 여기서는 추가 딜레이를 주지 않습니다.
            if (action != "send") {
                if (!SleepCancelable(Random(dr.min, dr.max)))
                    return
            }
        }
    }

    SetStatus("완료")
    return true
}

DetectCurrentDesktopOrStop(label := "") {
    map := GetSlotMap()
    if (map.Length < 1) {
        msg := "감지된 창이 없습니다."
        if (label != "")
            msg .= " (" label ")"
        AutoPopup(msg, "안내", 48, 1.5)
        return false
    }
    SetStatus("창 감지: " map.Length "개")
    return map
}

DoAction(hwnd, action) {
    global CFG, StopFlag
    try {
        WinRestore "ahk_id " hwnd
        WinActivate "ahk_id " hwnd
        WinWaitActive "ahk_id " hwnd, , 1.5
    } catch {
        return false
    }

    ; client size
    try {
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    } catch {
        return false
    }

    if (cw < 50 || ch < 50)
        return false

    if (action = "arrow") {
        ; 창 최신화: PgDn 연타 (텔레그램에서 End가 안 먹는 경우 대응)
        ; 요청: PgDn 횟수는 UI에서 입력
        SetStatus("창 최신화(PgDn)")
        ; 메시지 전송과 동일한 위치(입력창)를 클릭해서 포커스를 준 뒤 PgDn
        try {
            Click CFG.InputX, ch - CFG.InputDy
        } catch {
            ; ignore
        }
        cnt := GetRefreshPgDnCount()
        Loop cnt {
            if (StopFlag)
                return false
            Send "{PgDn}"
            Sleep 1
        }
        return true
    }

    if (action = "thumb") {
        x := ""
        y := ""
        x2 := CFG.Thumb2X
        y2 := CFG.Thumb2Y
        x3 := CFG.Thumb3X
        y3 := CFG.Thumb3Y

        ; 1~3 중 랜덤 선택(설정된 것만 후보)
        candidates := []
        if (CFG.ThumbX != "" && CFG.ThumbY != "")
            candidates.Push({x: CFG.ThumbX, y: CFG.ThumbY})
        if (x2 != "" && y2 != "")
            candidates.Push({x: x2, y: y2})
        if (x3 != "" && y3 != "")
            candidates.Push({x: x3, y: y3})

        if (candidates.Length > 0) {
            i := Random(1, candidates.Length)
            x := candidates[i].x
            y := candidates[i].y
        } else {
            ; fallback (기존 방식)
            x := CFG.ThumbX
            y := ch - CFG.ThumbDy
        }
        SetStatus("공감 클릭")
        Click x, y
        return true
    }

    if (action = "send") {
        x := CFG.InputX
        y := ch - CFG.InputDy
        SetStatus("메시지 입력/전송")
        Click x, y
        ; 요구사항: 창이동 > 하단클릭 > 시간지연 > 글쓰기
        dr := GetDelayRangeMs("send")
        if (!SleepCancelable(Random(dr.min, dr.max)))
            return false
        msg := GetRandomMessageText()
        if (msg != "") {
            SendText msg
            Sleep 60
            Send "{Enter}"
            return true
        }
        return false
    }

    return false
}

GetRandomMessageText() {
    global msgEdits, LAST_SENT_MSG
    list := []
    for e in msgEdits {
        v := ""
        try {
            v := Trim(e.Value)
        } catch {
            v := ""
        }
        if (v != "")
            list.Push(v)
    }
    if (list.Length < 1)
        return ""
    ; 바로 직전 메시지는 다음 번에 연속으로 선택되지 않게 함
    if (list.Length = 1) {
        LAST_SENT_MSG := list[1]
        return list[1]
    }

    candidates := []
    for v in list {
        if (v != LAST_SENT_MSG)
            candidates.Push(v)
    }
    if (candidates.Length < 1) {
        ; 전부 같은 문구면 어쩔 수 없이 그대로 사용
        LAST_SENT_MSG := list[1]
        return list[1]
    }
    idx := Random(1, candidates.Length)
    LAST_SENT_MSG := candidates[idx]
    return candidates[idx]
}

; ---------- 창 매핑 ----------

GetSlotMap() {
    global CFG, VDA

    hwnds := WinGetList(CFG.WinFilter)
    arr := []

    for hwnd in hwnds {
        try WinGetPos &x, &y, &w, &h, "ahk_id " hwnd
        catch
            continue

        ; DLL이 있으면 "현재 가상화면" 필터를 정확히 적용
        if (VDA.ok && VDA.IsWindowOnCurrentVirtualDesktopProc) {
            onCurrent := 0
            try {
                onCurrent := DllCall(VDA.IsWindowOnCurrentVirtualDesktopProc, "Ptr", hwnd, "Int")
            } catch {
                onCurrent := 1
            }
            if (onCurrent = 0)
                continue
        }

        ; 현재 보이는(현재 가상화면) 창만 대상으로 (Win32 API 직접 호출 대신 AHK 내장 사용)
        ; 일부 환경에서 DllCall("user32\\...") 경로가 깨지는 문제 회피
        if (!WinExist("ahk_id " hwnd))
            continue
        vis := 0
        try {
            vis := WinGetMinMax("ahk_id " hwnd)
        } catch {
            vis := 0
        }
        ; 최소화(-1)된 창은 제외
        if (vis = -1)
            continue

        if (w < 200 || h < 200)
            continue

        arr.Push({ hwnd: hwnd, x: x, y: y, w: w, h: h })
    }

    ; 정렬: 위→아래, 왼→오
    ArraySort(arr, (a, b) => (a.y = b.y ? (a.x - b.x) : (a.y - b.y)))

    return arr
}

; ---------- UI 헬퍼 ----------

SetStatus(text) {
    global lblStatus
    lblStatus.Text := text
}

; ---------- 설정 로딩 ----------

LoadConfig(path) {
    cfg := {}
    cfg.WinFilter := IniRead(path, "General", "WinFilter", "ahk_exe Telegram.exe")
    cfg.ThumbX := IniRead(path, "General", "ThumbX", "70")
    cfg.ThumbY := IniRead(path, "General", "ThumbY", "")
    cfg.Thumb2X := IniRead(path, "General", "Thumb2X", "")
    cfg.Thumb2Y := IniRead(path, "General", "Thumb2Y", "")
    cfg.Thumb3X := IniRead(path, "General", "Thumb3X", "")
    cfg.Thumb3Y := IniRead(path, "General", "Thumb3Y", "")
    cfg.ThumbDy := Integer(IniRead(path, "General", "ThumbDy", "135"))
    cfg.InputX := Integer(IniRead(path, "General", "InputX", "120"))
    cfg.InputDy := Integer(IniRead(path, "General", "InputDy", "30"))
    ; (구버전 호환) 딜레이 기본값
    cfg.DelayMinMs := Integer(IniRead(path, "General", "DelayMinMs", "1000"))
    cfg.DelayMaxMs := Integer(IniRead(path, "General", "DelayMaxMs", "3000"))
    ; 액션별 딜레이(ms) - 없으면 구버전 딜레이를 기본으로 사용
    cfg.DelayRefreshMinMs := Integer(IniRead(path, "General", "DelayRefreshMinMs", cfg.DelayMinMs ""))
    cfg.DelayRefreshMaxMs := Integer(IniRead(path, "General", "DelayRefreshMaxMs", cfg.DelayMaxMs ""))
    cfg.DelayReactMinMs := Integer(IniRead(path, "General", "DelayReactMinMs", cfg.DelayMinMs ""))
    cfg.DelayReactMaxMs := Integer(IniRead(path, "General", "DelayReactMaxMs", cfg.DelayMaxMs ""))
    cfg.DelaySendMinMs := Integer(IniRead(path, "General", "DelaySendMinMs", cfg.DelayMinMs ""))
    cfg.DelaySendMaxMs := Integer(IniRead(path, "General", "DelaySendMaxMs", cfg.DelayMaxMs ""))
    cfg.RefreshPgDnCount := Integer(IniRead(path, "General", "RefreshPgDnCount", "300"))
    cfg.LastMsgFile := IniRead(path, "General", "LastMsgFile", "")
    cfg.RecentMsgFiles := []
    ; 최근 메시지 목록(최대 5개)
    Loop 5 {
        k := "File" A_Index
        v := ""
        try {
            v := IniRead(path, "RecentMsgFiles", k, "")
        } catch {
            v := ""
        }
        if (v != "")
            cfg.RecentMsgFiles.Push(v)
    }
    return cfg
}

; ---------- 좌표 찍기/저장 ----------
PickCoord(which) {
    global CFG, lblThumb, IniPath
    SetStatus("좌표찍기: 3초 안에 원하는 버튼 위에 마우스를 올려두세요…")
    Sleep 3000

    CoordMode "Mouse", "Screen"
    MouseGetPos &sx, &sy, &hwnd
    CoordMode "Mouse", "Client"

    if (hwnd = 0) {
        SetStatus("좌표찍기 실패: 창을 찾지 못함")
        return
    }

    ; Telegram 창인지 확인(가능한 경우)
    exe := ""
    try {
        exe := WinGetProcessName("ahk_id " hwnd)
    } catch {
        exe := ""
    }
    if (exe != "" && exe != "Telegram.exe") {
        SetStatus("좌표찍기 실패: Telegram 창 위에서 찍어주세요")
        return
    }

    ; 클라이언트 기준 좌표로 변환
    try {
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    } catch {
        SetStatus("좌표찍기 실패: 클라이언트 좌표 변환 실패")
        return
    }
    rx := sx - cx
    ry := sy - cy
    if (rx < 0 || ry < 0 || rx > cw || ry > ch) {
        SetStatus("좌표찍기 실패: 클라이언트 영역 안에서 찍어주세요")
        return
    }

    if (which = "thumb1") {
        CFG.ThumbX := rx
        CFG.ThumbY := ry
        RefreshCoordLabels()
        IniWrite CFG.ThumbX, IniPath, "General", "ThumbX"
        IniWrite CFG.ThumbY, IniPath, "General", "ThumbY"
        SetStatus("공감 좌표1 저장됨")
    } else if (which = "thumb2") {
        CFG.Thumb2X := rx
        CFG.Thumb2Y := ry
        RefreshCoordLabels()
        IniWrite CFG.Thumb2X, IniPath, "General", "Thumb2X"
        IniWrite CFG.Thumb2Y, IniPath, "General", "Thumb2Y"
        SetStatus("공감 좌표2 저장됨")
    } else if (which = "thumb3") {
        CFG.Thumb3X := rx
        CFG.Thumb3Y := ry
        RefreshCoordLabels()
        IniWrite CFG.Thumb3X, IniPath, "General", "Thumb3X"
        IniWrite CFG.Thumb3Y, IniPath, "General", "Thumb3Y"
        SetStatus("공감 좌표3 저장됨")
    }
}

RefreshCoordLabels() {
    global CFG, lblThumb
    parts := []
    p1 := (CFG.ThumbX != "" && CFG.ThumbY != "") ? ("1:X=" CFG.ThumbX ",Y=" CFG.ThumbY) : "1:(미설정)"
    p2 := (CFG.Thumb2X != "" && CFG.Thumb2Y != "") ? ("2:X=" CFG.Thumb2X ",Y=" CFG.Thumb2Y) : "2:(미설정)"
    p3 := (CFG.Thumb3X != "" && CFG.Thumb3Y != "") ? ("3:X=" CFG.Thumb3X ",Y=" CFG.Thumb3Y) : "3:(미설정)"
    lblThumb.Text := p1 "   |   " p2 "   |   " p3
}

ArrayShuffle(arr) {
    ; Fisher–Yates shuffle
    n := arr.Length
    if (n <= 1)
        return arr
    i := n
    while (i > 1) {
        j := Random(1, i)
        tmp := arr[i]
        arr[i] := arr[j]
        arr[j] := tmp
        i -= 1
    }
    return arr
}

StopAll(*) {
    global StopFlag
    StopFlag := true
    ReturnHome()
    RestoreGuiAfterRun()
    AutoPopup("모든 작업을 중단했습니다.", "중단", 64, 1.5)
}

SleepCancelable(ms) {
    global StopFlag
    if (ms <= 0)
        return true
    slice := 50
    remain := ms
    while (remain > 0) {
        if (StopFlag)
            return false
        s := (remain > slice) ? slice : remain
        Sleep s
        remain -= s
    }
    return true
}

AutoPopup(text, title := "안내", icon := 48, timeoutSec := 1.5) {
    ; 일부 AutoHotkey v2 빌드에서는 MsgBox에 timeout 파라미터가 없어
    ; "Too many parameters" 오류가 날 수 있어, 자체 팝업 GUI로 대체합니다.
    global _autoPopupGui
    ms := Round(timeoutSec * 1000)
    if (ms < 500)
        ms := 500

    ; 이전 팝업이 있으면 닫기
    try {
        if IsObject(_autoPopupGui)
            _autoPopupGui.Destroy()
    } catch {
        ; ignore
    }

    isDone := (title = "완료" || icon = 64)

    g := Gui("+AlwaysOnTop -Caption +ToolWindow +Border")
    g.MarginX := 14
    g.MarginY := 10

    if (isDone) {
        ; 완료 팝업: 파란 배경 + 흰색 Bold + 큰 글씨 + 가운데 정렬
        g.BackColor := "0078D7"
        g.SetFont("s40 Bold cFFFFFF", "Segoe UI")
        ; 0x200 = SS_CENTERIMAGE (세로 가운데)
        ; 글씨가 잘리지 않도록 창/컨트롤 크기를 넉넉하게 잡음(긴 문구도 표시)
        g.AddText("Center 0x200 w860 h170", text)
    } else {
        g.SetFont("s10", "Segoe UI")
        g.AddText("w420", title)
        g.AddText("w420", text)
    }

    ; 화면 중앙에 띄우기
    w := isDone ? 900 : 460
    h := isDone ? 220 : 120
    x := (A_ScreenWidth - w) // 2
    y := (A_ScreenHeight - h) // 2
    _autoPopupGui := g
    g.Show("x" x " y" y " NoActivate")

    ; 완료 팝업은 2초 더 길게
    if (isDone)
        ms += 2000

    SetTimer(AutoPopup_Close, -ms)
    try SetStatus(text)
}

AutoPopup_Click(wParam, lParam, msg, hwnd) {
    global _autoPopupGui
    g := 0
    try {
        g := _autoPopupGui
    } catch {
        return
    }
    if (!IsObject(g))
        return
    root := 0
    try {
        root := g.Hwnd
    } catch {
        root := 0
    }
    if (!root)
        return

    ; 클릭된 hwnd가 팝업 GUI(또는 그 자식 컨트롤)인 경우 닫기
    h := hwnd
    Loop 20 {
        if (h = root) {
            AutoPopup_Close()
            return
        }
        ; 부모로 타고 올라감
        try {
            h := DllCall("User32.dll\GetParent", "Ptr", h, "Ptr")
        } catch {
            break
        }
        if (!h)
            break
    }
}

AutoPopup_Close() {
    global _autoPopupGui
    try {
        if IsObject(_autoPopupGui) {
            _autoPopupGui.Destroy()
            _autoPopupGui := 0
        }
    } catch {
        ; ignore
    }
}

; ---------- 메시지 저장/불러오기 ----------
SaveMessages() {
    global msgEdits, IniPath, CFG
    path := FileSelect("S16", A_ScriptDir, "메시지 저장", "텍스트 (*.txt)")
    if (!path)
        return
    ; 확장자를 안 붙이고 저장하면 불러오기(필터 *.txt)에서 안 보일 수 있어 자동으로 .txt 추가
    if (!RegExMatch(path, "\.[^\\\/]+$"))
        path .= ".txt"
    out := []
    for e in msgEdits {
        v := ""
        try {
            v := Trim(e.Value)
        } catch {
            v := ""
        }
        if (v != "")
            out.Push(v)
    }
    ; 파일이 없으면 FileDelete에서 (2) 오류가 날 수 있어 예외 무시
    try {
        if FileExist(path)
            FileDelete path
    } catch {
        ; ignore
    }
    if (out.Length > 0)
        FileAppend StrJoin(out, "`n"), path, "UTF-8"
    CFG.LastMsgFile := path
    IniWrite path, IniPath, "General", "LastMsgFile"
    UpdateRecentFiles(path)
    RefreshRecentListUI()
    SetStatus("메시지 저장됨: " path)
}

LoadMessages() {
    global IniPath, CFG
    ; Open dialog: 옵션은 비움(일부 환경에서 "1" 같은 값이 문제될 수 있음)
    path := FileSelect("", A_ScriptDir, "메시지 불러오기", "텍스트 (*.txt)")
    if (!path)
        return
    if (LoadMessagesFromPath(path)) {
        CFG.LastMsgFile := path
        IniWrite path, IniPath, "General", "LastMsgFile"
        UpdateRecentFiles(path)
        RefreshRecentListUI()
        SetStatus("메시지 불러옴: " path)
    } else {
        SetStatus("메시지 불러오기 실패")
    }
}

RecentMsg_Selected(ctrl, *) {
    global recentMsgPaths, IniPath, CFG
    idx := 0
    try {
        idx := ctrl.Value
    } catch {
        idx := 0
    }
    if (idx < 1 || idx > recentMsgPaths.Length)
        return
    path := recentMsgPaths[idx]
    if (!FileExist(path)) {
        AutoPopup("파일이 없습니다: " path, "안내", 48, 1.5)
        return
    }
    if (LoadMessagesFromPath(path)) {
        CFG.LastMsgFile := path
        IniWrite path, IniPath, "General", "LastMsgFile"
        UpdateRecentFiles(path)
        RefreshRecentListUI()
        SetStatus("메시지 불러옴: " path)
    }
}

RefreshRecentListUI() {
    global lstRecent, recentMsgPaths
    ; 리스트에 파일명만 표시
    items := []
    for p in recentMsgPaths {
        name := p
        try {
            SplitPath p, &name
        } catch {
            name := p
        }
        items.Push(name)
    }
    try {
        lstRecent.Delete()
        if (items.Length > 0)
            lstRecent.Add(items)
    } catch {
        ; ignore
    }
}

UpdateRecentFiles(path) {
    global recentMsgPaths, IniPath
    if (path = "")
        return
    ; 중복 제거(대소문자 무시) + 최상단으로
    norm := StrLower(path)
    newList := []
    newList.Push(path)
    for p in recentMsgPaths {
        if (StrLower(p) = norm)
            continue
        newList.Push(p)
    }
    ; 최대 5개
    recentMsgPaths := []
    Loop Min(5, newList.Length)
        recentMsgPaths.Push(newList[A_Index])

    ; ini 저장
    Loop 5 {
        k := "File" A_Index
        v := (A_Index <= recentMsgPaths.Length) ? recentMsgPaths[A_Index] : ""
        try {
            IniWrite v, IniPath, "RecentMsgFiles", k
        } catch {
            ; ignore
        }
    }
}

AutoLoadLastMessages() {
    global CFG
    path := CFG.LastMsgFile
    if (path = "")
        return
    if (!FileExist(path))
        return
    LoadMessagesFromPath(path)
    UpdateRecentFiles(path)
    RefreshRecentListUI()
}

LoadMessagesFromPath(path) {
    global msgEdits
    txt := ""
    try {
        txt := FileRead(path, "UTF-8")
    } catch {
        return false
    }
    lines := StrSplit(txt, "`n", "`r")
    ; 초기화
    for e in msgEdits {
        try {
            e.Value := ""
        } catch {
            ; ignore
        }
    }
    i := 1
    for line in lines {
        v := Trim(line)
        if (v = "")
            continue
        if (i > msgEdits.Length)
            break
        msgEdits[i].Value := v
        i += 1
    }
    return true
}

StrJoin(arr, sep) {
    s := ""
    for i, v in arr {
        if (i > 1)
            s .= sep
        s .= v
    }
    return s
}

; ---------- 호환 정렬(배열 Sort 메서드 없는 버전 대비) ----------
; 작은 배열(최대 10~20개) 정렬용: 단순 버블정렬
ArraySort(arr, cmp) {
    n := arr.Length
    if (n <= 1)
        return arr

    Loop n - 1 {
        swapped := false
        i := 1
        while (i <= n - A_Index) {
            a := arr[i]
            b := arr[i + 1]
            if (cmp(a, b) > 0) {
                arr[i] := b
                arr[i + 1] := a
                swapped := true
            }
            i += 1
        }
        if (!swapped)
            break
    }
    return arr
}
