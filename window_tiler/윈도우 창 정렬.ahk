#Requires AutoHotkey v2.0
#SingleInstance Force

; ------------------------------------------------------------
; Window Tiler (10 slots / 5x2) - AutoHotkey v2
; - D1~D10 가상 데스크톱(외부 VirtualDesktopAccessor.dll 필요)
; - 슬롯 1~10 창 연결(클릭) / 연속선택 / 왼쪽/오른쪽 정렬
; - 가상화면 메모(각 D별 3글자) + 즉시 저장
; - 세팅 저장/불러오기(ini)
; ------------------------------------------------------------

global GRID_COLS := 5
global GRID_ROWS := 2
global OVERLAP_PX := 8

; 속도/지연(정렬이 0.2초씩 끊겨 보이는 현상 완화)
; - WinMove 등 윈도우 관련 명령 후 기본 지연을 제거
; - 스크립트를 가능한 최대 속도로 실행
; AHK v2.0 호환을 위해 함수(SetBatchLines 등) 대신 내장 변수로 설정합니다.
A_BatchLines := -1
A_WinDelay := -1
A_ControlDelay := -1
A_KeyDelay := -1
A_KeyDuration := -1
A_MouseDelay := -1
A_SendMode := "Input"

; 텔레그램 최소크기(고정값)
global TG_MIN_W := 396
global TG_MIN_H := 513

global ScriptDir := A_ScriptDir
global StateIni := ScriptDir "\window_tiler_ahk_state.ini"
global DefaultSettingsIni := ScriptDir "\window_tiler_ahk_settings.ini"

; ---------------------- Virtual Desktop (VDA) ----------------------
class VDA {
    static dll := 0
    static ok := false
    static err := ""
    static path := ""

    static Init() {
        if (VDA.ok)
            return true
        VDA.path := ScriptDir "\VirtualDesktopAccessor.dll"
        if !FileExist(VDA.path) {
            VDA.ok := false
            VDA.err := "VirtualDesktopAccessor.dll 없음"
            return false
        }
        try {
            VDA.dll := DllCall("Kernel32\LoadLibraryW", "str", VDA.path, "ptr")
            if !VDA.dll
                throw Error("LoadLibrary 실패")
            ; 간단한 호출로 동작 여부 확인
            _ := VDA.GetDesktopCount()
            VDA.ok := true
            VDA.err := ""
            return true
        } catch as e {
            VDA.ok := false
            VDA.err := e.Message
            return false
        }
    }

    static GetDesktopCount() {
        ; VirtualDesktopAccessor: int GetDesktopCount()
        return DllCall(VDA.path "\GetDesktopCount", "int")
    }

    static GetCurrentDesktopNumber() {
        ; int GetCurrentDesktopNumber()  // 0-based (일부 빌드에서 제공)
        return DllCall(VDA.path "\GetCurrentDesktopNumber", "int")
    }

    static GetWindowDesktopNumber(hwnd) {
        ; int GetWindowDesktopNumber(HWND hwnd)  // 0-based (일부 빌드에서 제공)
        return DllCall(VDA.path "\GetWindowDesktopNumber", "ptr", hwnd, "int")
    }

    static GoToDesktop(num1based) {
        ; void GoToDesktopNumber(int number)  // 0-based
        return DllCall(VDA.path "\GoToDesktopNumber", "int", num1based - 1)
    }

    static MoveWindowToDesktop(hwnd, num1based) {
        ; void MoveWindowToDesktopNumber(HWND hwnd, int number)  // 0-based
        return DllCall(VDA.path "\MoveWindowToDesktopNumber", "ptr", hwnd, "int", num1based - 1)
    }
}

; ---------------------- State ----------------------
global DesktopNotes := Map()   ; 1..10 => "3글자"
global LastSettingsPath := ""
global RecentSettingsPaths := []  ; 최근 세팅 파일(최대 10개, 전체 경로)

LoadState() {
    global DesktopNotes, LastSettingsPath, RecentSettingsPaths, StateIni
    try {
        LastSettingsPath := IniRead(StateIni, "state", "last_settings_path", "")
    } catch {
        LastSettingsPath := ""
    }
    DesktopNotes := Map()
    loop 10 {
        n := A_Index
        val := ""
        try val := IniRead(StateIni, "desktop_notes", "d" n, "")
        ; 메모 글자수 제한 없음
        DesktopNotes[n] := val
    }

    RecentSettingsPaths := []
    loop 10 {
        k := "file" A_Index
        v := ""
        try v := IniRead(StateIni, "recent_settings", k, "")
        if (v != "")
            RecentSettingsPaths.Push(v)
    }
}

SaveState() {
    global DesktopNotes, LastSettingsPath, RecentSettingsPaths, StateIni
    try IniWrite(LastSettingsPath, StateIni, "state", "last_settings_path")
    loop 10 {
        n := A_Index
        try IniWrite(DesktopNotes.Has(n) ? DesktopNotes[n] : "", StateIni, "desktop_notes", "d" n)
    }
    loop 10 {
        k := "file" A_Index
        v := (A_Index <= RecentSettingsPaths.Length) ? RecentSettingsPaths[A_Index] : ""
        try IniWrite(v, StateIni, "recent_settings", k)
    }
}

; ---------------------- Slot identity (save/load) ----------------------
; 저장 항목: title/class/exe (best effort)
GetWindowIdentity(hwnd) {
    ident := Map()
    try ident["hwnd"] := hwnd
    try ident["title"] := WinGetTitle("ahk_id " hwnd)
    try ident["class"] := WinGetClass("ahk_id " hwnd)
    try ident["exe"] := WinGetProcessPath("ahk_id " hwnd)
    return ident
}

FindWindowByIdentity(ident) {
    ; 1) hwnd 살아있으면 우선
    hwnd := 0
    try hwnd := Integer(ident.Get("hwnd", 0))
    if (hwnd && WinExist("ahk_id " hwnd))
        return hwnd

    savedTitle := ident.Get("title", "")
    savedClass := ident.Get("class", "")
    savedExe := ident.Get("exe", "")

    wins := WinGetList()  ; 모든 top-level
    ; 1) exe + class + title 정확
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
    ; 2) class + title 정확
    if (savedTitle != "") {
        for , h in wins {
            if (savedClass != "" && WinGetClass("ahk_id " h) != savedClass)
                continue
            if (WinGetTitle("ahk_id " h) = savedTitle)
                return h
        }
    }
    ; 3) title 부분
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

; ---------------------- Geometry ----------------------
GetSortedMonitorWorkAreas() {
    mons := []
    cnt := MonitorGetCount()
    loop cnt {
        MonitorGetWorkArea(A_Index, &L, &T, &R, &B)
        mons.Push(Map("L", L, "T", T, "R", R, "B", B))
    }
    ; 일부 AutoHotkey v2 환경에서는 Array.Sort() 메서드가 없을 수 있어
    ; (오류: Array has no method named "Sort")
    ; 간단한 수동 정렬로 대체합니다.
    if (mons.Length > 1) {
        loop mons.Length - 1 {
            i := A_Index
            loop mons.Length - i {
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

CellRect(i0, work) {
    ; i0: 0..9
    L := work["L"], T := work["T"], R := work["R"], B := work["B"]
    ww := R - L, wh := B - T
    col := Mod(i0, GRID_COLS)
    row := Floor(i0 / GRID_COLS)

    x0 := L + Floor((col * ww) / GRID_COLS)
    x1 := L + Floor(((col + 1) * ww) / GRID_COLS)
    y0 := T + Floor((row * wh) / GRID_ROWS)
    y1 := T + Floor(((row + 1) * wh) / GRID_ROWS)

    if (col > 0)
        x0 -= OVERLAP_PX
    if (col < GRID_COLS - 1)
        x1 += OVERLAP_PX
    if (row > 0)
        y0 -= OVERLAP_PX
    if (row < GRID_ROWS - 1)
        y1 += OVERLAP_PX

    x0 := Max(L, x0), y0 := Max(T, y0)
    x1 := Min(R, x1), y1 := Min(B, y1)
    return Map("x", x0, "y", y0, "w", x1 - x0, "h", y1 - y0)
}

; ---------------------- App UI + Logic ----------------------
LoadState()
VDA.Init()

global Slots := []                 ; each: Map("hwnd", 0, "ident", Map())
global SlotTitleTexts := []        ; Gui Text controls
global CaptureActive := false
global CaptureSequential := false
global CaptureIndex := 1           ; 1..10
global SelectedMoveDesktop := 0     ; 1..10 (이동용 버튼 눌림 표시)
global SelectedArrangeDesktop := 0  ; 0=현재 데스크톱, 1..10=D (정렬용)
global SuppressNoteSignal := false
global NoteEdits := Map()          ; 1..10 => Edit control
global CaptureWasMinimized := false
global LstRecentSettings := 0

loop 10 {
    Slots.Push(Map("hwnd", 0, "ident", Map()))
}

; OnEvent 콜백에서 루프 변수 캡처 문제(예: D1~D9 누르면 D10으로 처리됨)를 피하기 위해
; Bind()로 인자를 고정한 래퍼 함수를 사용합니다.
SlotBind_Click(idx, *) {
    StartCaptureSingle(idx)
}
SlotClear_Click(idx, *) {
    ClearSlot(idx)
}
SlotCell_Click(idx, *) {
    ; 슬롯 표시(버튼)를 클릭하면:
    ; - 이미 등록된 경우: 해당 슬롯만 해제
    ; - 비어있는 경우: 해당 슬롯에 연결(캡처) 시작
    global Slots
    if (Slots[idx]["hwnd"] && WinExist("ahk_id " Slots[idx]["hwnd"])) {
        ClearSlot(idx)
    } else {
        StartCaptureSingle(idx)
    }
}
DesktopMoveButton_Click(num, *) {
    MoveToDesktop(num)
}
ArrangeDesktopButton_Click(num, *) {
    ToggleArrangeDesktop(num)
}
DesktopNote_Changed(num, ctrl, *) {
    global DesktopNotes, SuppressNoteSignal
    if (SuppressNoteSignal)
        return
    ; 메모 글자수 제한 없음
    DesktopNotes[num] := ctrl.Value
    SaveState()
}

UpdateRecentSettings(path) {
    global RecentSettingsPaths
    if (path = "")
        return
    norm := StrLower(path)
    newArr := []
    newArr.Push(path)
    for p in RecentSettingsPaths {
        if (StrLower(p) = norm)
            continue
        newArr.Push(p)
    }
    RecentSettingsPaths := []
    Loop Min(10, newArr.Length)
        RecentSettingsPaths.Push(newArr[A_Index])
    SaveState()
    RefreshRecentSettingsUI()
}

RefreshRecentSettingsUI() {
    global LstRecentSettings, RecentSettingsPaths
    if (!IsObject(LstRecentSettings))
        return
    items := []
    for p in RecentSettingsPaths {
        name := p
        try SplitPath p, &name
        items.Push(name)
    }
    try {
        LstRecentSettings.Delete()
        if (items.Length > 0)
            LstRecentSettings.Add(items)
    } catch {
        ; ignore
    }
}

RecentSettings_Selected(ctrl, *) {
    global RecentSettingsPaths
    idx := 0
    try {
        idx := ctrl.Value
    } catch {
        idx := 0
    }
    if (idx < 1 || idx > RecentSettingsPaths.Length)
        return
    path := RecentSettingsPaths[idx]
    if (!FileExist(path)) {
        MsgBox "파일이 없습니다: " path, "안내", "Icon!"
        return
    }
    if (LoadSettingsFromPath(path)) {
        UpdateRecentSettings(path) ; 최상단으로 올림 + 즉시 반영
    }
}

UpdateDesktopButtonVisuals() {
    global ArrangeDesktopButtons, SelectedArrangeDesktop
    loop 10 {
        i := A_Index
        c := ArrangeDesktopButtons[i]
        if (i = SelectedArrangeDesktop) {
            c.Value := 1
            c.Text := "D" i
            c.Opt("BackgroundFF3B30")  ; 선택: 빨강
            c.SetFont("s10 Norm cFFFFFF")
        } else {
            c.Value := 0
            c.Text := "D" i
            c.Opt("BackgroundFFFFFF")
            c.SetFont("s10 Norm c000000")
        }
    }
}

UpdateMoveButtonVisuals() {
    global DesktopMoveButtons, SelectedMoveDesktop
    loop 10 {
        i := A_Index
        b := DesktopMoveButtons[i]
        if (i = SelectedMoveDesktop) {
            b.Opt("Background0078D7")  ; 이동 선택: 파랑
            b.SetFont("s10 Norm cFFFFFF")
            ; 눌림(pressed) 상태로 보이게 유지
            try DllCall("User32\SendMessageW", "ptr", b.Hwnd, "uint", 0x00F3, "ptr", 1, "ptr", 0) ; BM_SETSTATE
        } else {
            b.Opt("BackgroundFFFFFF")
            b.SetFont("s10 Norm c000000")
            try DllCall("User32\SendMessageW", "ptr", b.Hwnd, "uint", 0x00F3, "ptr", 0, "ptr", 0) ; BM_SETSTATE
        }
    }
}

; AlwaysOnTop 해제 + Hooking.ahk 스타일: Theme 비활성화(버튼 배경색 적용)
g := Gui("+Resize -MinimizeBox", "윈도우 창 정렬 (10칸) - AHK v2")
g.SetFont("s10", "Segoe UI")
g.Opt("-Theme")

; 파일 라벨
global LblFile := g.AddText("x10 y10 w740", "세팅 파일: (없음)")
if (LastSettingsPath != "")
    LblFile.Value := "세팅 파일: " . SplitPathName(LastSettingsPath)

; 슬롯 영역
g.AddGroupBox("x10 y35 w740 h130", "슬롯 (1~10)")

; 슬롯 UI: 1~5 (1줄) / 6~10 (2줄)로 표시, 연결/해제 버튼은 제거
slotX := 25, slotY := 60
slotW := 138, slotH := 26
slotGapX := 6, slotGapY := 8
loop 10 {
    i := A_Index
    row := Floor((i - 1) / 5)   ; 0 or 1
    col := Mod(i - 1, 5)        ; 0..4
    x := slotX + col * (slotW + slotGapX)
    y := slotY + row * (slotH + slotGapY)

    ; 버튼 형태로 만들어 클릭 가능하게(클릭 시 해제/연결 토글)
    b := g.AddButton("x" x " y" y " w" slotW " h" slotH, i ": (비어있음)")
    b.OnEvent("Click", SlotCell_Click.Bind(i))
    SlotTitleTexts.Push(b)
}

; 동작 영역
g.AddGroupBox("x10 y175 w740 h340", "동작")

global BtnSeq := g.AddButton("x25 y205 w120", "연속선택 시작")
global BtnSave := g.AddButton("x155 y205 w110", "세팅저장")
global BtnLoad := g.AddButton("x275 y205 w110", "세팅불러오기")
global BtnClearAll := g.AddButton("x395 y205 w140", "목록해제(전체)")

BtnSeq.OnEvent("Click", (*) => ToggleCaptureSequential())
BtnSave.OnEvent("Click", (*) => SaveSettings())
BtnLoad.OnEvent("Click", (*) => LoadSettings())
BtnClearAll.OnEvent("Click", (*) => ClearAll())

; 최근 세팅(최대 10개) - 클릭(선택)하면 바로 불러오기
g.AddText("x25 y235 w120", "최근 세팅:")
LstRecentSettings := g.AddListBox("x25 y255 w700 h140")
LstRecentSettings.OnEvent("Change", RecentSettings_Selected)
RefreshRecentSettingsUI()

; D1~D10 (위: 이동용, 아래: 정렬용)
startX := 25, startY := 430, bw := 58, bh := 24, gapX := 4, gapY := 6

; 1) 위: 이동용 버튼(클릭 즉시 프로그램 창+화면을 해당 가상화면으로 이동)
global DesktopMoveButtons := Map()
g.AddText("x25 y" (startY - 18) " w160", "가상화면 이동:")
loop 10 {
    n := A_Index
    x := startX + (n - 1) * (bw + gapX)
    y := startY
    b := g.AddButton("x" x " y" y " w" bw " h" bh, "D" n)
    b.OnEvent("Click", DesktopMoveButton_Click.Bind(n))
    DesktopMoveButtons[n] := b
}

; 2) 아래: 정렬용 토글 버튼(선택된 데스크톱으로 창 이동+정렬)
global ArrangeDesktopButtons := Map()
g.AddText("x25 y" (startY + bh + gapY - 2) " w160", "가상화면 정렬:")
arrY := startY + bh + gapY + 16
loop 10 {
    n := A_Index
    x := startX + (n - 1) * (bw + gapX)
    y := arrY
    b := g.AddCheckBox("x" x " y" y " w" bw " h" bh " +0x1000 Center", "D" n)  ; BS_PUSHLIKE
    b.SetFont("s10 Norm c000000")
    b.OnEvent("Click", ArrangeDesktopButton_Click.Bind(n))
    ArrangeDesktopButtons[n] := b
}

; 가상화면 메모(각 D 아래에 10개 고정 표시, 각 3글자, 즉시 저장)
noteY := arrY + bh + 10
SuppressNoteSignal := true
try {
    loop 10 {
        n := A_Index
        x := startX + (n - 1) * (bw + gapX)
        e := g.AddEdit("x" x " y" noteY " w" bw " h24")
        e.OnEvent("Change", DesktopNote_Changed.Bind(n))
        ; 흰 배경 고정
        e.SetFont()
        e.Value := DesktopNotes.Has(n) ? DesktopNotes[n] : ""
        NoteEdits[n] := e
    }
} finally {
    SuppressNoteSignal := false
}

; 정렬 버튼
btnArrangeY := noteY + 32
global BtnLeft := g.AddButton("x25 y" btnArrangeY " w120", "왼쪽정렬")
global BtnRight := g.AddButton("x155 y" btnArrangeY " w120", "오른쪽정렬")
BtnLeft.OnEvent("Click", (*) => ArrangeAll("left"))
BtnRight.OnEvent("Click", (*) => ArrangeAll("right"))

; 상태 표시
global LblStatus := g.AddText("x10 y605 w740", VDA.ok ? "준비됨" : ("주의: " VDA.err " (D 이동/전환 불가)"))

; ESC로 캡처 취소
g.OnEvent("Escape", (*) => CancelCapture())

; 클릭 캡처용 전역 핫키(필요할 때만 On)
Hotkey("~LButton Up", CaptureClick, "Off")
; 연속선택 중지 + GUI 다시 표시
Hotkey("F12", StopCaptureAndShowGui)

g.Show("w760 h650")
; 시작 시: 현재 GUI가 위치한 가상화면(D번호)을 감지해서 "가상화면 이동" 버튼에 반영
SetTimer(InitMoveSelectionFromCurrentDesktop, -50)
UpdateDesktopButtonVisuals()
return

InitMoveSelectionFromCurrentDesktop() {
    global g, SelectedMoveDesktop
    if (!VDA.ok)
        return
    d0 := -1
    ; 1) GUI 윈도우가 속한 데스크톱 번호(0-based) 시도
    try {
        d0 := VDA.GetWindowDesktopNumber(g.Hwnd)
    } catch {
        d0 := -1
    }
    ; 2) 실패 시 현재 데스크톱 번호(0-based) 시도
    if (d0 < 0) {
        try {
            d0 := VDA.GetCurrentDesktopNumber()
        } catch {
            d0 := -1
        }
    }
    if (d0 >= 0) {
        SelectedMoveDesktop := d0 + 1
        UpdateMoveButtonVisuals()
    }
}

; ---------------------- Helpers/UI ----------------------
SplitPathName(p) {
    ; 파일명만
    SplitPath p, &name
    return name
}

SetStatus(msg) {
    global LblStatus
    LblStatus.Value := msg
}

UpdateSlotUI(i) {
    global Slots, SlotTitleTexts
    s := Slots[i]
    if (s["hwnd"] && WinExist("ahk_id " s["hwnd"])) {
        title := ""
        try title := WinGetTitle("ahk_id " s["hwnd"])
        if (title = "")
            title := "(등록됨)"
    } else {
        title := "(비어있음)"
    }

    txt := i ": " title
    ; 컨트롤 종류에 따라 Text/Value가 다를 수 있어 방어적으로 설정
    try {
        SlotTitleTexts[i].Text := txt
    } catch {
        try SlotTitleTexts[i].Value := txt
    }
}

; ---------------------- Capture (bind windows) ----------------------
StartCaptureSingle(i) {
    global CaptureActive, CaptureSequential, CaptureIndex, BtnSeq
    CaptureActive := true
    CaptureSequential := false
    CaptureIndex := i
    BtnSeq.Text := "연속선택 시작"
    Hotkey("~LButton Up", CaptureClick, "On")
    SetStatus("[연결 대기] " i "번 슬롯에 넣을 창을 클릭하세요.")
}

ToggleCaptureSequential() {
    global CaptureActive, CaptureSequential, CaptureIndex, BtnSeq, g, CaptureWasMinimized
    if (CaptureActive && CaptureSequential) {
        CancelCapture()
        return
    }
    CaptureActive := true
    CaptureSequential := true
    CaptureIndex := 1
    BtnSeq.Text := "종료"
    Hotkey("~LButton Up", CaptureClick, "On")
    SetStatus("[연속선택] 1번 슬롯부터 순서대로 창을 클릭하세요. (버튼 '종료'로 종료)")
    ; 요구사항: 연속선택 시작 시 GUI 최소화
    CaptureWasMinimized := true
    try WinMinimize("ahk_id " g.Hwnd)
}

CancelCapture() {
    global CaptureActive, CaptureSequential, BtnSeq
    CaptureActive := false
    CaptureSequential := false
    BtnSeq.Text := "연속선택 시작"
    Hotkey("~LButton Up", CaptureClick, "Off")
    SetStatus("취소됨. (이미 등록된 슬롯은 유지됩니다)")
}

StopCaptureAndShowGui(*) {
    global CaptureActive, CaptureSequential, g, CaptureWasMinimized
    ; F12: 연속선택(또는 연결 대기) 중지 + GUI 다시 표시
    if (CaptureActive) {
        CancelCapture()
    }
    if (CaptureWasMinimized) {
        CaptureWasMinimized := false
        try WinRestore("ahk_id " g.Hwnd)
        try WinActivate("ahk_id " g.Hwnd)
    }
}

CaptureClick(*) {
    global CaptureActive, CaptureSequential, CaptureIndex, Slots, g, CaptureWasMinimized
    if (!CaptureActive)
        return

    MouseGetPos , , &hwnd
    if (!hwnd)
        return

    ; top-level로 올리기
    hwndRoot := DllCall("User32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr") ; GA_ROOT=2
    if (!hwndRoot)
        hwndRoot := hwnd

    ; 자기 창 클릭 방지
    if (hwndRoot = g.Hwnd)
        return

    ; 보이는 창만
    if (!DllCall("User32\IsWindowVisible", "ptr", hwndRoot, "int"))
        return

    idx := CaptureIndex
    Slots[idx]["hwnd"] := hwndRoot
    Slots[idx]["ident"] := GetWindowIdentity(hwndRoot)
    UpdateSlotUI(idx)

    if (!CaptureSequential) {
        CaptureActive := false
        Hotkey("~LButton Up", CaptureClick, "Off")
        SetStatus(idx "번 슬롯에 등록됨")
        return
    }

    CaptureIndex += 1
    if (CaptureIndex > 10) {
        CancelCapture()
        SetStatus("연속선택 완료(1~10). 이제 정렬을 누르세요.")
        ; 완료 시에도 GUI를 다시 표시
        if (CaptureWasMinimized) {
            CaptureWasMinimized := false
            try WinRestore("ahk_id " g.Hwnd)
            try WinActivate("ahk_id " g.Hwnd)
        }
    } else {
        SetStatus("[연속선택] " idx "번 등록됨 → 다음은 " CaptureIndex "번 슬롯. 계속 클릭하세요. (버튼 '종료'로 종료)")
    }
}

; ---------------------- Slot ops ----------------------
ClearSlot(i) {
    global Slots
    Slots[i]["hwnd"] := 0
    Slots[i]["ident"] := Map()
    UpdateSlotUI(i)
}

ClearAll() {
    loop 10
        ClearSlot(A_Index)
    SetStatus("목록이 모두 해제되었습니다.")
}

GetBoundHwnds() {
    global Slots
    hwnds := []
    loop 10 {
        h := Slots[A_Index]["hwnd"]
        if (h && WinExist("ahk_id " h))
            hwnds.Push(h)
    }
    return hwnds
}

; ---------------------- Desktop + Note ----------------------
MoveToDesktop(n) {
    global g, SelectedMoveDesktop
    SelectedMoveDesktop := n
    UpdateMoveButtonVisuals()
    if (!EnsureDesktop(n))
        return
    try VDA.MoveWindowToDesktop(g.Hwnd, n)
    try VDA.GoToDesktop(n)
    Sleep 30
    try WinActivate("ahk_id " g.Hwnd)
}

ToggleArrangeDesktop(n) {
    global SelectedArrangeDesktop
    if (SelectedArrangeDesktop = n)
        SelectedArrangeDesktop := 0
    else
        SelectedArrangeDesktop := n
    UpdateDesktopButtonVisuals()
}

; ---------------------- Arrange ----------------------
EnsureDesktop(num1based) {
    if (!VDA.ok && !VDA.Init())
        return false
    try {
        cnt := VDA.GetDesktopCount()
    } catch {
        return false
    }
    if (num1based < 1 || num1based > cnt) {
        MsgBox "현재 가상 데스크톱은 " cnt "개 입니다. D" num1based "은 존재하지 않습니다.`n(CTRL+WIN+D로 데스크톱을 추가한 뒤 다시 시도하세요.)", "안내", "Icon!"
        return false
    }
    return true
}

ArrangeAll(side) {
    global SelectedArrangeDesktop, LastSettingsPath, g
    hwnds := GetBoundHwnds()
    if (hwnds.Length = 0) {
        MsgBox "등록된 창이 없습니다. 먼저 슬롯에 창을 연결하세요.", "안내", "Iconi"
        return
    }

    ; 1) 데스크톱 이동/전환
    if (SelectedArrangeDesktop != 0) {
        if (!EnsureDesktop(SelectedArrangeDesktop))
            return
        ; 요구사항: 정렬 대상이 D6 등 다른 가상화면이면,
        ; 정렬 실행 시 GUI도 그 가상화면으로 같이 이동 + 화면 전환
        try VDA.MoveWindowToDesktop(g.Hwnd, SelectedArrangeDesktop)
        for , h in hwnds {
            try VDA.MoveWindowToDesktop(h, SelectedArrangeDesktop)
        }
        try VDA.GoToDesktop(SelectedArrangeDesktop)
        ; 전환 직후 약간만 대기(너무 길면 정렬이 끊겨 보임)
        Sleep 30
        try WinActivate("ahk_id " g.Hwnd)
    }

    ; 2) 모니터 선택
    mons := GetSortedMonitorWorkAreas()
    work := mons[1]
    if (mons.Length > 1) {
        if (side = "right")
            work := mons[mons.Length]
        else
            work := mons[1]
    }

    L := work["L"], T := work["T"], R := work["R"], B := work["B"]
    ww := R - L, wh := B - T

    ; 텔레그램 최소크기(396x513)를 기본값으로 "항상" 적용
    tgMin := true
    refW := TG_MIN_W
    refH := TG_MIN_H

    moved := 0
    loop 10 {
        i := A_Index
        h := Slots[i]["hwnd"]
        if (!h || !WinExist("ahk_id " h))
            continue

        try {
            WinRestore("ahk_id " h)
        } catch {
            ; ignore
        }

        x := 0, y := 0, w := 0, hgt := 0
        i0 := i - 1

        if (tgMin && refW > 0 && refH > 0) {
            col := Mod(i0, GRID_COLS)
            row := Floor(i0 / GRID_COLS)
            gap := 8
            totalW := (GRID_COLS * refW) + ((GRID_COLS - 1) * gap)
            totalH := (GRID_ROWS * refH) + ((GRID_ROWS - 1) * gap)
            if (totalW > ww || totalH > wh) {
                gap := 0
                totalW := (GRID_COLS * refW) + ((GRID_COLS - 1) * gap)
                totalH := (GRID_ROWS * refH) + ((GRID_ROWS - 1) * gap)
            }
            if (totalW <= ww && totalH <= wh) {
                x := L + col * (refW + gap)
                y := T + row * (refH + gap)
                w := refW
                hgt := refH
            } else {
                r := CellRect(i0, work)
                x := r["x"], y := r["y"], w := r["w"], hgt := r["h"]
            }
        } else {
            r := CellRect(i0, work)
            x := r["x"], y := r["y"], w := r["w"], hgt := r["h"]
        }

        try WinMove x, y, w, hgt, "ahk_id " h
        moved += 1
    }

    SetStatus((side = "left" ? "왼쪽" : "오른쪽") "정렬 완료: " moved "개 창")
}

; ---------------------- Settings save/load (INI) ----------------------
SaveSettings() {
    global LastSettingsPath, LblFile
    hwnds := GetBoundHwnds()
    if (hwnds.Length = 0) {
        MsgBox "저장할 슬롯이 없습니다. 먼저 1~10 슬롯에 창을 연결하세요.", "안내", "Iconi"
        return
    }

    path := FileSelect("S16", (LastSettingsPath != "" ? LastSettingsPath : DefaultSettingsIni), "세팅 저장", "INI 파일 (*.ini)")
    if (!path)
        return

    ; 확장자를 안 붙이면 "불러오기"에서 필터 때문에 안 보일 수 있어 자동으로 .ini를 붙입니다.
    if !RegExMatch(path, "i)\.ini$") {
        path := path ".ini"
    }

    loop 10 {
        i := A_Index
        h := Slots[i]["hwnd"]
        section := "slot" i
        if (h && WinExist("ahk_id " h)) {
            ident := GetWindowIdentity(h)
            IniWrite(h, path, section, "hwnd")
            IniWrite(ident.Get("title", ""), path, section, "title")
            IniWrite(ident.Get("class", ""), path, section, "class")
            IniWrite(ident.Get("exe", ""), path, section, "exe")
        } else {
            IniDelete(path, section)
        }
    }

    LastSettingsPath := path
    SaveState()
    LblFile.Value := "세팅 파일: " . SplitPathName(path)
    LblFile.ToolTip := path
    SetStatus("세팅 저장됨")
    UpdateRecentSettings(path)
}

LoadSettings() {
    global LastSettingsPath, LblFile
    path := FileSelect("1", (LastSettingsPath != "" ? LastSettingsPath : DefaultSettingsIni), "세팅 불러오기", "INI 파일 (*.ini)")
    if (!path)
        return

    if (LoadSettingsFromPath(path)) {
        UpdateRecentSettings(path)
    }
}

LoadSettingsFromPath(path) {
    global LastSettingsPath, LblFile
    if (!FileExist(path)) {
        MsgBox "파일이 없습니다: " path, "안내", "Icon!"
        return false
    }

    ; 요구사항: 항상 "불러오면 전부 지우고" 진행(확인 팝업 없이)
    ClearAll()

    restored := 0
    missing := 0
    loop 10 {
        i := A_Index
        section := "slot" i
        title := IniRead(path, section, "title", "")
        class := IniRead(path, section, "class", "")
        exe := IniRead(path, section, "exe", "")
        hwndSaved := IniRead(path, section, "hwnd", "0")

        if (title = "" && class = "" && exe = "" && hwndSaved = "0") {
            ClearSlot(i)
            continue
        }

        ident := Map("hwnd", hwndSaved, "title", title, "class", class, "exe", exe)
        h := FindWindowByIdentity(ident)
        if (h) {
            Slots[i]["hwnd"] := h
            Slots[i]["ident"] := ident
            UpdateSlotUI(i)
            restored += 1
        } else {
            ClearSlot(i)
            missing += 1
        }
    }

    LastSettingsPath := path
    SaveState()
    LblFile.Value := "세팅 파일: " . SplitPathName(path)
    LblFile.ToolTip := path
    SetStatus("세팅 불러옴: 복구 " restored "개 / 못 찾음 " missing "개")
    return true
}
