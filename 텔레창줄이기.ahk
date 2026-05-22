#Requires AutoHotkey v2.0
#SingleInstance Force

; 텔레그램(Desktop) 창이 활성화된 상태에서
; 마우스 휠(중간버튼)을 누르면 "최소화(작업표시줄로 숨김)"가 아니라
; 텔레그램이 허용하는 "최소 크기"로 창 크기를 줄입니다.
; (아래 TG_MIN_W / TG_MIN_H 값은 질문에서 주신 스크립트의 값과 동일)
;
; 사용법:
; 1) AutoHotkey v2 설치
; 2) 이 파일을 더블클릭해서 실행

; 텔레그램 최소 크기(고정값)
global TG_MIN_W := 396
global TG_MIN_H := 513

MButton:: {
    hwnd := WinGetID("A")

    ; 활성 창이 Telegram Desktop인지 확인 (프로세스 기준)
    try proc := WinGetProcessName("ahk_id " hwnd)
    catch {
        return
    }
    if (proc != "Telegram.exe")
        return

    ; 최대화 상태면 먼저 복원해야 WinMove가 먹습니다.
    if (WinGetMinMax("ahk_id " hwnd) = 1)
        WinRestore("ahk_id " hwnd)

    ShrinkWindowToMinimum(hwnd)
}

ShrinkWindowToMinimum(hwnd) {
    global TG_MIN_W, TG_MIN_H
    win := "ahk_id " hwnd
    WinGetPos &x, &y, &w, &h, win
    if (w = "" || h = "")
        return

    newW := TG_MIN_W
    newH := TG_MIN_H
    nx := x, ny := y
    AdjustIntoWorkArea(&nx, &ny, newW, newH)
    WinMove nx, ny, newW, newH, win
}

AdjustIntoWorkArea(&x, &y, w, h) {
    ; 창이 화면 밖으로 밀려나지 않도록, "해당 창이 있는 모니터"의 작업 영역 안으로 보정
    GetWorkAreaForRect(x, y, w, h, &L, &T, &R, &B)

    if (x < L)
        x := L
    if (y < T)
        y := T
    if (x + w > R)
        x := R - w
    if (y + h > B)
        y := B - h
}

GetWorkAreaForRect(x, y, w, h, &L, &T, &R, &B) {
    cx := x + Floor(w / 2)
    cy := y + Floor(h / 2)

    cnt := MonitorGetCount()
    Loop cnt {
        m := A_Index
        MonitorGet(m, &mL, &mT, &mR, &mB)
        if (cx >= mL && cx < mR && cy >= mT && cy < mB) {
            MonitorGetWorkArea(m, &L, &T, &R, &B)
            return
        }
    }

    ; 못 찾으면 기본(주 모니터)로 처리
    ; (환경에 따라 MonitorGetPrimary()가 없을 수 있어 1번 모니터로 fallback)
    MonitorGetWorkArea(1, &L, &T, &R, &B)
}
