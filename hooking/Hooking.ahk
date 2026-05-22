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

; ---------- [탭2] 윈도우 창 정렬(통합용) 전역 ----------
; (UI 생성 전에 초기화 필요: 미할당 변수 에러 방지)
global WT_GRID_COLS := 5
global WT_GRID_ROWS := 2
global WT_OVERLAP_PX := 8
global WT_TG_MIN_W := 396
global WT_TG_MIN_H := 513
global WT_StateIni := A_ScriptDir "\window_tiler_ahk_state.ini"
global WT_DefaultSettingsIni := A_ScriptDir "\window_tiler_ahk_settings.ini"

global WT_DesktopNotes := Map()
global WT_LastSettingsPath := ""
global WT_RecentSettingsPaths := []

global WT_Slots := []
global WT_SlotTitleButtons := []   ; 슬롯 버튼(1~10)
global WT_CaptureActive := false
global WT_CaptureSequential := false
global WT_CaptureIndex := 1
global WT_CaptureWasMinimized := false
global WT_SelectedMoveDesktop := 0
global WT_SelectedArrangeDesktop := 0
global WT_SuppressNoteSignal := false

global WT_LblFile := 0
global WT_LblStatus := 0
global WT_BtnSeq := 0
global WT_BtnSave := 0
global WT_BtnLoad := 0
global WT_BtnClearAll := 0
global WT_LstRecentSettings := 0
global WT_DesktopMoveButtons := Map()
global WT_ArrangeDesktopButtons := Map()
global WT_NoteEdits := Map()
global WT_BtnLeft := 0
global WT_BtnRight := 0

; ---------- GUI ----------
; AlwaysOnTop 해제(사용자가 창을 가리지 않게)
app := Gui("+Resize", "Hooking (Telegram)")
app.SetFont("s10", "Segoe UI")
; 버튼 배경색 표시를 위해 테마 비활성화(환경에 따라 기본 버튼은 색상 변경이 무시될 수 있음)
app.Opt("-Theme")

; ---------- 탭(통합) ----------
tabMain := app.AddTab3("xm ym w760 h680", ["후킹", "윈도우 창 정렬"])
tabMain.UseTab(1)

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

; ---------- 탭2: 윈도우 창 정렬 ----------
tabMain.UseTab(2)
WT_BuildUI()

; 탭 종료(이후 컨트롤은 기본 탭 밖)
tabMain.UseTab()

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

; ======================================================================
; [탭2] 윈도우 창 정렬 (통합본)
; - 업로드한 "윈도우 창 정렬.ahk"의 기능을 탭으로 통합
; - UI/UX 개선(디자인 변경)은 하지 않고 기능 중심으로 복구
; ======================================================================

WT_BuildUI() {
    global app
    global WT_LblFile, WT_LblStatus, WT_BtnSeq, WT_BtnSave, WT_BtnLoad, WT_BtnClearAll, WT_LstRecentSettings
    global WT_DesktopMoveButtons, WT_ArrangeDesktopButtons, WT_NoteEdits
    global WT_BtnLeft, WT_BtnRight

    WT_LoadState()
    WT_InitSlots()
    WT_SlotTitleButtons := []

    ; 속도/지연(원본 스크립트 의도)
    A_BatchLines := -1
    A_WinDelay := -1
    A_ControlDelay := -1
    A_KeyDelay := -1
    A_KeyDuration := -1
    A_MouseDelay := -1
    A_SendMode := "Input"

    ; 파일 라벨
    WT_LblFile := app.AddText("x10 y10 w740", "세팅 파일: (없음)")
    if (WT_LastSettingsPath != "")
        WT_LblFile.Value := "세팅 파일: " . WT_SplitPathName(WT_LastSettingsPath)

    ; 슬롯
    app.AddGroupBox("x10 y35 w740 h130", "슬롯 (1~10)")
    slotX := 25, slotY := 60
    slotW := 138, slotH := 26
    slotGapX := 6, slotGapY := 8
    Loop 10 {
        i := A_Index
        row := Floor((i - 1) / 5)
        col := Mod(i - 1, 5)
        x := slotX + col * (slotW + slotGapX)
        y := slotY + row * (slotH + slotGapY)
        b := app.AddButton("x" x " y" y " w" slotW " h" slotH, i ": (비어있음)")
        b.OnEvent("Click", WT_SlotCell_Click.Bind(i))
        WT_SlotTitleButtons.Push(b)
    }

    ; 동작
    app.AddGroupBox("x10 y175 w740 h340", "동작")
    WT_BtnSeq := app.AddButton("x25 y205 w120", "연속선택 시작")
    WT_BtnSave := app.AddButton("x155 y205 w110", "세팅저장")
    WT_BtnLoad := app.AddButton("x275 y205 w110", "세팅불러오기")
    WT_BtnClearAll := app.AddButton("x395 y205 w140", "목록해제(전체)")
    WT_BtnSeq.OnEvent("Click", (*) => WT_ToggleCaptureSequential())
    WT_BtnSave.OnEvent("Click", (*) => WT_SaveSettings())
    WT_BtnLoad.OnEvent("Click", (*) => WT_LoadSettings())
    WT_BtnClearAll.OnEvent("Click", (*) => WT_ClearAll())

    ; 최근 세팅
    app.AddText("x25 y235 w120", "최근 세팅:")
    WT_LstRecentSettings := app.AddListBox("x25 y255 w700 h140")
    WT_LstRecentSettings.OnEvent("Change", WT_RecentSettings_Selected)
    WT_RefreshRecentSettingsUI()

    ; 가상화면 이동/정렬
    startX := 25, startY := 430, bw := 58, bh := 24, gapX := 4, gapY := 6
    app.AddText("x25 y" (startY - 18) " w160", "가상화면 이동:")
    WT_DesktopMoveButtons := Map()
    Loop 10 {
        n := A_Index
        x := startX + (n - 1) * (bw + gapX)
        y := startY
        b := app.AddButton("x" x " y" y " w" bw " h" bh, "D" n)
        b.OnEvent("Click", WT_DesktopMoveButton_Click.Bind(n))
        WT_DesktopMoveButtons[n] := b
    }

    app.AddText("x25 y" (startY + bh + gapY - 2) " w160", "가상화면 정렬:")
    WT_ArrangeDesktopButtons := Map()
    arrY := startY + bh + gapY + 16
    Loop 10 {
        n := A_Index
        x := startX + (n - 1) * (bw + gapX)
        y := arrY
        b := app.AddCheckBox("x" x " y" y " w" bw " h" bh " +0x1000 Center", "D" n)  ; PushLike
        b.SetFont("s10 Norm c000000")
        b.OnEvent("Click", WT_ArrangeDesktopButton_Click.Bind(n))
        WT_ArrangeDesktopButtons[n] := b
    }

    ; 가상화면 메모
    noteY := arrY + bh + 10
    WT_NoteEdits := Map()
    global WT_SuppressNoteSignal
    WT_SuppressNoteSignal := true
    try {
        Loop 10 {
            n := A_Index
            x := startX + (n - 1) * (bw + gapX)
            e := app.AddEdit("x" x " y" noteY " w" bw " h24")
            e.OnEvent("Change", WT_DesktopNote_Changed.Bind(n))
            e.Value := WT_DesktopNotes.Has(n) ? WT_DesktopNotes[n] : ""
            WT_NoteEdits[n] := e
        }
    } finally {
        WT_SuppressNoteSignal := false
    }

    ; 정렬 버튼
    btnArrangeY := noteY + 32
    WT_BtnLeft := app.AddButton("x25 y" btnArrangeY " w120", "왼쪽정렬")
    WT_BtnRight := app.AddButton("x155 y" btnArrangeY " w120", "오른쪽정렬")
    WT_BtnLeft.OnEvent("Click", (*) => WT_ArrangeAll("left"))
    WT_BtnRight.OnEvent("Click", (*) => WT_ArrangeAll("right"))

    ; 상태 표시
    WT_LblStatus := app.AddText("x10 y605 w740", WT_VdaOk() ? "준비됨" : "주의: VirtualDesktopAccessor.dll 없음/오류")

    ; 캡처용 전역 핫키(필요할 때만 On)
    Hotkey("~LButton Up", WT_CaptureClick, "Off")
    ; 후킹의 F12와 충돌 방지: Ctrl+F12로 캡처 취소/GUI 복귀
    Hotkey("^F12", WT_StopCaptureAndShowGui, "On")

    WT_RefreshAllSlotUI()
    WT_InitMoveSelectionFromCurrentDesktop()
    WT_UpdateMoveButtonVisuals()
    WT_UpdateArrangeButtonVisuals()
}

WT_VdaOk() {
    global VDA
    return (IsObject(VDA) && VDA.ok)
}

WT_LoadState() {
    global WT_StateIni, WT_DesktopNotes, WT_LastSettingsPath, WT_RecentSettingsPaths
    try {
        WT_LastSettingsPath := IniRead(WT_StateIni, "state", "last_settings_path", "")
    } catch {
        WT_LastSettingsPath := ""
    }
    WT_DesktopNotes := Map()
    Loop 10 {
        n := A_Index
        v := ""
        try {
            v := IniRead(WT_StateIni, "desktop_notes", "d" n, "")
        } catch {
            v := ""
        }
        WT_DesktopNotes[n] := v
    }
    WT_RecentSettingsPaths := []
    Loop 10 {
        k := "file" A_Index
        v := ""
        try {
            v := IniRead(WT_StateIni, "recent_settings", k, "")
        } catch {
            v := ""
        }
        if (v != "")
            WT_RecentSettingsPaths.Push(v)
    }
}

WT_SaveState() {
    global WT_StateIni, WT_DesktopNotes, WT_LastSettingsPath, WT_RecentSettingsPaths
    try IniWrite WT_LastSettingsPath, WT_StateIni, "state", "last_settings_path"
    Loop 10 {
        n := A_Index
        try IniWrite (WT_DesktopNotes.Has(n) ? WT_DesktopNotes[n] : ""), WT_StateIni, "desktop_notes", "d" n
    }
    Loop 10 {
        k := "file" A_Index
        v := (A_Index <= WT_RecentSettingsPaths.Length) ? WT_RecentSettingsPaths[A_Index] : ""
        try IniWrite v, WT_StateIni, "recent_settings", k
    }
}

WT_InitSlots() {
    global WT_Slots
    WT_Slots := []
    Loop 10
        WT_Slots.Push(Map("hwnd", 0, "ident", Map()))
}

WT_SplitPathName(p) {
    SplitPath p, &name
    return name
}

WT_UpdateRecentSettings(path) {
    global WT_RecentSettingsPaths
    if (path = "")
        return
    norm := StrLower(path)
    newArr := []
    newArr.Push(path)
    for p in WT_RecentSettingsPaths {
        if (StrLower(p) = norm)
            continue
        newArr.Push(p)
    }
    WT_RecentSettingsPaths := []
    Loop Min(10, newArr.Length)
        WT_RecentSettingsPaths.Push(newArr[A_Index])
    WT_SaveState()
    WT_RefreshRecentSettingsUI()
}

WT_RefreshRecentSettingsUI() {
    global WT_LstRecentSettings, WT_RecentSettingsPaths
    if (!IsObject(WT_LstRecentSettings))
        return
    items := []
    for p in WT_RecentSettingsPaths {
        items.Push(WT_SplitPathName(p))
    }
    try {
        WT_LstRecentSettings.Delete()
        if (items.Length > 0)
            WT_LstRecentSettings.Add(items)
        WT_LstRecentSettings.Value := 0
    } catch {
        ; ignore
    }
}

WT_RecentSettings_Selected(ctrl, *) {
    global WT_RecentSettingsPaths
    idx := 0
    try {
        idx := ctrl.Value
    } catch {
        idx := 0
    }
    if (idx < 1 || idx > WT_RecentSettingsPaths.Length)
        return
    path := WT_RecentSettingsPaths[idx]
    if (!FileExist(path)) {
        AutoPopup("파일이 없습니다: " path, "안내", 48, 1.5)
        return
    }
    if (WT_LoadSettingsFromPath(path)) {
        WT_UpdateRecentSettings(path)
    }
}

WT_UpdateSlotUI(i) {
    global WT_Slots, WT_SlotTitleButtons
    if (i < 1 || i > WT_Slots.Length)
        return
    s := WT_Slots[i]
    title := ""
    if (s["hwnd"] && WinExist("ahk_id " s["hwnd"])) {
        try title := WinGetTitle("ahk_id " s["hwnd"])
        if (title = "")
            title := "(등록됨)"
    } else {
        title := "(비어있음)"
    }
    txt := i ": " title
    try WT_SlotTitleButtons[i].Text := txt
    catch {
        try WT_SlotTitleButtons[i].Value := txt
    }
}

WT_RefreshAllSlotUI() {
    Loop 10
        WT_UpdateSlotUI(A_Index)
}

WT_ClearSlot(i) {
    global WT_Slots
    WT_Slots[i]["hwnd"] := 0
    WT_Slots[i]["ident"] := Map()
    WT_UpdateSlotUI(i)
}

WT_ClearAll() {
    Loop 10
        WT_ClearSlot(A_Index)
    WT_SetStatus("목록이 모두 해제되었습니다.")
}

WT_SetStatus(msg) {
    global WT_LblStatus
    try WT_LblStatus.Value := msg
}

WT_SlotCell_Click(idx, *) {
    global WT_Slots
    if (WT_Slots[idx]["hwnd"] && WinExist("ahk_id " WT_Slots[idx]["hwnd"])) {
        WT_ClearSlot(idx)
    } else {
        WT_StartCaptureSingle(idx)
    }
}

WT_StartCaptureSingle(i) {
    global WT_CaptureActive, WT_CaptureSequential, WT_CaptureIndex
    WT_CaptureActive := true
    WT_CaptureSequential := false
    WT_CaptureIndex := i
    Hotkey("~LButton Up", WT_CaptureClick, "On")
    WT_SetStatus("[연결 대기] " i "번 슬롯에 넣을 창을 클릭하세요.")
}

WT_ToggleCaptureSequential() {
    global WT_CaptureActive, WT_CaptureSequential, WT_CaptureIndex, WT_CaptureWasMinimized
    global WT_BtnSeq, app
    if (WT_CaptureActive && WT_CaptureSequential) {
        WT_CancelCapture()
        return
    }
    WT_CaptureActive := true
    WT_CaptureSequential := true
    WT_CaptureIndex := 1
    try WT_BtnSeq.Text := "종료"
    Hotkey("~LButton Up", WT_CaptureClick, "On")
    WT_SetStatus("[연속선택] 1번 슬롯부터 순서대로 창을 클릭하세요. (Ctrl+F12로 종료/복귀)")
    WT_CaptureWasMinimized := true
    try WinMinimize("ahk_id " app.Hwnd)
}

WT_CancelCapture() {
    global WT_CaptureActive, WT_CaptureSequential, WT_BtnSeq
    WT_CaptureActive := false
    WT_CaptureSequential := false
    try WT_BtnSeq.Text := "연속선택 시작"
    Hotkey("~LButton Up", WT_CaptureClick, "Off")
    WT_SetStatus("취소됨. (이미 등록된 슬롯은 유지됩니다)")
}

WT_StopCaptureAndShowGui(*) {
    global WT_CaptureWasMinimized, app
    WT_CancelCapture()
    if (WT_CaptureWasMinimized) {
        WT_CaptureWasMinimized := false
        try WinRestore("ahk_id " app.Hwnd)
        try WinActivate("ahk_id " app.Hwnd)
    }
}

WT_CaptureClick(*) {
    global WT_CaptureActive, WT_CaptureSequential, WT_CaptureIndex, WT_Slots, app
    if (!WT_CaptureActive)
        return
    MouseGetPos , , &hwnd
    if (!hwnd)
        return
    hwndRoot := 0
    try {
        hwndRoot := DllCall("User32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr") ; GA_ROOT
    } catch {
        hwndRoot := hwnd
    }
    if (!hwndRoot)
        hwndRoot := hwnd
    if (hwndRoot = app.Hwnd)
        return
    if (!DllCall("User32\IsWindowVisible", "ptr", hwndRoot, "int"))
        return

    idx := WT_CaptureIndex
    WT_Slots[idx]["hwnd"] := hwndRoot
    WT_Slots[idx]["ident"] := WT_GetWindowIdentity(hwndRoot)
    WT_UpdateSlotUI(idx)

    if (!WT_CaptureSequential) {
        WT_CaptureActive := false
        Hotkey("~LButton Up", WT_CaptureClick, "Off")
        WT_SetStatus(idx "번 슬롯에 등록됨")
        return
    }

    WT_CaptureIndex += 1
    if (WT_CaptureIndex > 10) {
        WT_CancelCapture()
        WT_SetStatus("연속선택 완료(1~10). 이제 정렬을 누르세요.")
        if (WT_CaptureWasMinimized) {
            WT_CaptureWasMinimized := false
            try WinRestore("ahk_id " app.Hwnd)
            try WinActivate("ahk_id " app.Hwnd)
        }
    } else {
        WT_SetStatus("[연속선택] " idx "번 등록됨 → 다음은 " WT_CaptureIndex "번 슬롯. 계속 클릭하세요.")
    }
}

WT_GetWindowIdentity(hwnd) {
    ident := Map()
    try ident["hwnd"] := hwnd
    try ident["title"] := WinGetTitle("ahk_id " hwnd)
    try ident["class"] := WinGetClass("ahk_id " hwnd)
    try ident["exe"] := WinGetProcessPath("ahk_id " hwnd)
    return ident
}

WT_FindWindowByIdentity(ident) {
    hwnd := 0
    try hwnd := Integer(ident.Get("hwnd", 0))
    if (hwnd && WinExist("ahk_id " hwnd))
        return hwnd
    savedTitle := ident.Get("title", "")
    savedClass := ident.Get("class", "")
    savedExe := ident.Get("exe", "")
    wins := WinGetList()
    if (savedTitle != "" && savedExe != "") {
        for , h in wins {
            if (savedClass != "" && WinGetClass("ahk_id " h) != savedClass)
                continue
            if (WinGetTitle("ahk_id " h) != savedTitle)
                continue
            if (StrLower(WinGetProcessPath("ahk_id " h)) = StrLower(savedExe))
                return h
        }
    }
    if (savedTitle != "") {
        for , h in wins {
            if (savedClass != "" && WinGetClass("ahk_id " h) != savedClass)
                continue
            if (WinGetTitle("ahk_id " h) = savedTitle)
                return h
        }
    }
    if (savedTitle != "") {
        for , h in wins {
            if (savedClass != "" && WinGetClass("ahk_id " h) != savedClass)
                continue
            if InStr(WinGetTitle("ahk_id " h), savedTitle)
                return h
        }
    }
    return 0
}

WT_DesktopMoveButton_Click(num, *) {
    WT_MoveToDesktop(num)
}

WT_ArrangeDesktopButton_Click(num, *) {
    global WT_SelectedArrangeDesktop
    if (WT_SelectedArrangeDesktop = num)
        WT_SelectedArrangeDesktop := 0
    else
        WT_SelectedArrangeDesktop := num
    WT_UpdateArrangeButtonVisuals()
}

WT_DesktopNote_Changed(num, ctrl, *) {
    global WT_DesktopNotes, WT_SuppressNoteSignal
    if (WT_SuppressNoteSignal)
        return
    WT_DesktopNotes[num] := ctrl.Value
    WT_SaveState()
}

WT_InitMoveSelectionFromCurrentDesktop() {
    global WT_SelectedMoveDesktop
    d := 0
    try {
        d := GetCurrentDesktopOneBased()
    } catch {
        d := 0
    }
    if (d > 0)
        WT_SelectedMoveDesktop := d
}

WT_UpdateMoveButtonVisuals() {
    global WT_DesktopMoveButtons, WT_SelectedMoveDesktop
    Loop 10 {
        i := A_Index
        b := WT_DesktopMoveButtons[i]
        if (!IsObject(b))
            continue
        if (i = WT_SelectedMoveDesktop) {
            b.Opt("Background0078D7")
            b.SetFont("s10 Norm cFFFFFF")
        } else {
            b.Opt("BackgroundFFFFFF")
            b.SetFont("s10 Norm c000000")
        }
    }
}

WT_UpdateArrangeButtonVisuals() {
    global WT_ArrangeDesktopButtons, WT_SelectedArrangeDesktop
    Loop 10 {
        i := A_Index
        c := WT_ArrangeDesktopButtons[i]
        if (!IsObject(c))
            continue
        if (i = WT_SelectedArrangeDesktop) {
            c.Value := 1
            c.Opt("BackgroundFF3B30")
            c.SetFont("s10 Norm cFFFFFF")
        } else {
            c.Value := 0
            c.Opt("BackgroundFFFFFF")
            c.SetFont("s10 Norm c000000")
        }
    }
}

WT_EnsureDesktop(num1based) {
    global VDA
    if (!WT_VdaOk() || !VDA.GetDesktopCountProc) {
        AutoPopup("VirtualDesktopAccessor.dll이 필요합니다.", "안내", 48, 2)
        return false
    }
    cnt := 0
    try {
        cnt := DllCall(VDA.GetDesktopCountProc, "Int")
    } catch {
        cnt := 0
    }
    if (cnt > 0 && (num1based < 1 || num1based > cnt)) {
        AutoPopup("현재 가상 데스크톱은 " cnt "개 입니다. D" num1based "은 존재하지 않습니다.", "안내", 48, 2)
        return false
    }
    return true
}

WT_MoveWindowToDesktop(hwnd, num1based) {
    global VDA
    if (!WT_VdaOk() || !VDA.MoveWindowToDesktopNumberProc)
        return false
    try {
        DllCall(VDA.MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", num1based - 1, "Int")
        return true
    } catch {
        return false
    }
}

WT_MoveToDesktop(n) {
    global app, WT_SelectedMoveDesktop
    WT_SelectedMoveDesktop := n
    WT_UpdateMoveButtonVisuals()
    if (!WT_EnsureDesktop(n))
        return
    WT_MoveWindowToDesktop(app.Hwnd, n)
    GoToDesktop(n)
    Sleep 30
    try WinActivate("ahk_id " app.Hwnd)
}

WT_GetBoundHwnds() {
    global WT_Slots
    hwnds := []
    Loop 10 {
        h := WT_Slots[A_Index]["hwnd"]
        if (h && WinExist("ahk_id " h))
            hwnds.Push(h)
    }
    return hwnds
}

WT_GetSortedMonitorWorkAreas() {
    mons := []
    cnt := MonitorGetCount()
    Loop cnt {
        MonitorGetWorkArea(A_Index, &L, &T, &R, &B)
        mons.Push(Map("L", L, "T", T, "R", R, "B", B))
    }
    if (mons.Length > 1) {
        Loop mons.Length - 1 {
            i := A_Index
            Loop mons.Length - i {
                j := i + A_Index
                if (mons[j]["L"] < mons[i]["L"]) {
                    tmp := mons[i]
                    mons[i] := mons[j]
                    mons[j] := tmp
                }
            }
        }
    }
    return mons
}

WT_CellRect(i0, work) {
    global WT_GRID_COLS, WT_GRID_ROWS, WT_OVERLAP_PX
    L := work["L"], T := work["T"], R := work["R"], B := work["B"]
    ww := R - L, wh := B - T
    col := Mod(i0, WT_GRID_COLS)
    row := Floor(i0 / WT_GRID_COLS)

    x0 := L + Floor((col * ww) / WT_GRID_COLS)
    x1 := L + Floor(((col + 1) * ww) / WT_GRID_COLS)
    y0 := T + Floor((row * wh) / WT_GRID_ROWS)
    y1 := T + Floor(((row + 1) * wh) / WT_GRID_ROWS)

    if (col > 0)
        x0 -= WT_OVERLAP_PX
    if (col < WT_GRID_COLS - 1)
        x1 += WT_OVERLAP_PX
    if (row > 0)
        y0 -= WT_OVERLAP_PX
    if (row < WT_GRID_ROWS - 1)
        y1 += WT_OVERLAP_PX

    x0 := Max(L, x0), y0 := Max(T, y0)
    x1 := Min(R, x1), y1 := Min(B, y1)
    return Map("x", x0, "y", y0, "w", x1 - x0, "h", y1 - y0)
}

WT_ArrangeAll(side) {
    global WT_SelectedArrangeDesktop, WT_TG_MIN_W, WT_TG_MIN_H, app
    hwnds := WT_GetBoundHwnds()
    if (hwnds.Length = 0) {
        AutoPopup("등록된 창이 없습니다. 먼저 슬롯에 창을 연결하세요.", "안내", 48, 1.5)
        return
    }

    if (WT_SelectedArrangeDesktop != 0) {
        if (!WT_EnsureDesktop(WT_SelectedArrangeDesktop))
            return
        WT_MoveWindowToDesktop(app.Hwnd, WT_SelectedArrangeDesktop)
        for , h in hwnds
            WT_MoveWindowToDesktop(h, WT_SelectedArrangeDesktop)
        GoToDesktop(WT_SelectedArrangeDesktop)
        Sleep 30
        try WinActivate("ahk_id " app.Hwnd)
    }

    mons := WT_GetSortedMonitorWorkAreas()
    work := mons[1]
    if (mons.Length > 1) {
        if (side = "right")
            work := mons[mons.Length]
        else
            work := mons[1]
    }

    L := work["L"], T := work["T"], R := work["R"], B := work["B"]
    ww := R - L, wh := B - T

    moved := 0
    Loop 10 {
        i := A_Index
        hwnd := WT_Slots[i]["hwnd"]
        if (!hwnd || !WinExist("ahk_id " hwnd))
            continue
        try WinRestore("ahk_id " hwnd)
        i0 := i - 1

        refW := WT_TG_MIN_W, refH := WT_TG_MIN_H
        col := Mod(i0, WT_GRID_COLS)
        row := Floor(i0 / WT_GRID_COLS)
        gap := 8
        totalW := (WT_GRID_COLS * refW) + ((WT_GRID_COLS - 1) * gap)
        totalH := (WT_GRID_ROWS * refH) + ((WT_GRID_ROWS - 1) * gap)
        if (totalW > ww || totalH > wh) {
            gap := 0
            totalW := (WT_GRID_COLS * refW) + ((WT_GRID_COLS - 1) * gap)
            totalH := (WT_GRID_ROWS * refH) + ((WT_GRID_ROWS - 1) * gap)
        }

        if (totalW <= ww && totalH <= wh) {
            x := L + col * (refW + gap)
            y := T + row * (refH + gap)
            w := refW
            hgt := refH
        } else {
            r := WT_CellRect(i0, work)
            x := r["x"], y := r["y"], w := r["w"], hgt := r["h"]
        }
        try WinMove x, y, w, hgt, "ahk_id " hwnd
        moved += 1
    }

    WT_SetStatus((side = "left" ? "왼쪽" : "오른쪽") "정렬 완료: " moved "개 창")
}

WT_SaveSettings() {
    global WT_LastSettingsPath, WT_DefaultSettingsIni, WT_LblFile
    hwnds := WT_GetBoundHwnds()
    if (hwnds.Length = 0) {
        AutoPopup("저장할 슬롯이 없습니다. 먼저 1~10 슬롯에 창을 연결하세요.", "안내", 48, 1.5)
        return
    }
    base := (WT_LastSettingsPath != "" ? WT_LastSettingsPath : WT_DefaultSettingsIni)
    path := FileSelect("S16", base, "세팅 저장", "INI 파일 (*.ini)")
    if (!path)
        return
    if (!RegExMatch(path, "i)\.ini$"))
        path := path ".ini"

    Loop 10 {
        i := A_Index
        hwnd := WT_Slots[i]["hwnd"]
        section := "slot" i
        if (hwnd && WinExist("ahk_id " hwnd)) {
            ident := WT_GetWindowIdentity(hwnd)
            IniWrite hwnd, path, section, "hwnd"
            IniWrite ident.Get("title", ""), path, section, "title"
            IniWrite ident.Get("class", ""), path, section, "class"
            IniWrite ident.Get("exe", ""), path, section, "exe"
        } else {
            try IniDelete(path, section)
        }
    }

    WT_LastSettingsPath := path
    WT_SaveState()
    try WT_LblFile.Value := "세팅 파일: " . WT_SplitPathName(path)
    WT_SetStatus("세팅 저장됨")
    WT_UpdateRecentSettings(path)
}

WT_LoadSettings() {
    global WT_LastSettingsPath, WT_DefaultSettingsIni
    base := (WT_LastSettingsPath != "" ? WT_LastSettingsPath : WT_DefaultSettingsIni)
    path := FileSelect("", base, "세팅 불러오기", "INI 파일 (*.ini)")
    if (!path)
        return
    if (WT_LoadSettingsFromPath(path)) {
        WT_UpdateRecentSettings(path)
    }
}

WT_LoadSettingsFromPath(path) {
    global WT_LastSettingsPath, WT_LblFile
    if (!FileExist(path)) {
        AutoPopup("파일이 없습니다: " path, "안내", 48, 1.5)
        return false
    }
    WT_ClearAll()

    restored := 0
    missing := 0
    Loop 10 {
        i := A_Index
        section := "slot" i
        title := IniRead(path, section, "title", "")
        class := IniRead(path, section, "class", "")
        exe := IniRead(path, section, "exe", "")
        hwndSaved := IniRead(path, section, "hwnd", "0")

        if (title = "" && class = "" && exe = "" && hwndSaved = "0") {
            WT_ClearSlot(i)
            continue
        }
        ident := Map("hwnd", hwndSaved, "title", title, "class", class, "exe", exe)
        h := WT_FindWindowByIdentity(ident)
        if (h) {
            WT_Slots[i]["hwnd"] := h
            WT_Slots[i]["ident"] := ident
            WT_UpdateSlotUI(i)
            restored += 1
        } else {
            WT_ClearSlot(i)
            missing += 1
        }
    }

    WT_LastSettingsPath := path
    WT_SaveState()
    try WT_LblFile.Value := "세팅 파일: " . WT_SplitPathName(path)
    WT_SetStatus("세팅 불러옴: 복구 " restored "개 / 못 찾음 " missing "개")
    return true
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
