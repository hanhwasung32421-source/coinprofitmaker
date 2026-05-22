import threading
import tkinter as tk
from dataclasses import dataclass
from tkinter import messagebox, ttk

import win32api
import win32con
import win32gui
from pynput import mouse


GRID_COLS = 5
GRID_ROWS = 2

# 창 테두리/그림자(DWM shadow) 때문에 창 사이에 미세한 "빈칸"이 보일 수 있어
# 서로 살짝 겹치게(오버랩) 배치해서 빈틈이 안 보이게 합니다.
OVERLAP_PX = 8


def _set_dpi_aware() -> None:
    """
    DPI 스케일링이 켜져 있어도 좌표/크기 계산이 최대한 일치하도록 DPI aware 설정.
    """
    try:
        # Per-monitor DPI aware (Windows 8.1+)
        import ctypes

        shcore = ctypes.windll.shcore  # type: ignore[attr-defined]
        shcore.SetProcessDpiAwareness(2)  # PROCESS_PER_MONITOR_DPI_AWARE
    except Exception:
        try:
            import ctypes

            ctypes.windll.user32.SetProcessDPIAware()  # type: ignore[attr-defined]
        except Exception:
            pass


@dataclass
class Slot:
    hwnd: int = 0
    title: str = ""


def _get_top_level_hwnd_from_point(x: int, y: int) -> int:
    hwnd = win32gui.WindowFromPoint((x, y))
    if not hwnd:
        return 0

    try:
        hwnd = win32gui.GetAncestor(hwnd, win32con.GA_ROOT)
    except Exception:
        pass

    # 보이지 않는 창 등은 제외
    try:
        if not win32gui.IsWindow(hwnd):
            return 0
        if not win32gui.IsWindowVisible(hwnd):
            return 0
    except Exception:
        return 0

    return int(hwnd)


def _get_window_title(hwnd: int) -> str:
    try:
        return win32gui.GetWindowText(hwnd) or f"HWND={hwnd}"
    except Exception:
        return f"HWND={hwnd}"


def _restore_window(hwnd: int) -> None:
    try:
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    except Exception:
        pass


def _set_window_rect(hwnd: int, x: int, y: int, w: int, h: int) -> None:
    flags = win32con.SWP_NOZORDER | win32con.SWP_NOACTIVATE
    try:
        win32gui.SetWindowPos(hwnd, 0, x, y, w, h, flags)
    except Exception:
        # 일부 창은 SetWindowPos가 실패할 수 있어 MoveWindow로 재시도
        try:
            win32gui.MoveWindow(hwnd, x, y, w, h, True)
        except Exception:
            pass


def _get_monitor_work_area_from_cursor() -> tuple[int, int, int, int]:
    """
    현재 마우스가 있는 모니터의 작업영역(작업표시줄 제외)을 반환: (L, T, R, B)
    """
    x, y = win32api.GetCursorPos()
    mon = win32api.MonitorFromPoint((x, y), win32con.MONITOR_DEFAULTTONEAREST)
    info = win32api.GetMonitorInfo(mon)
    # {'Work': (L,T,R,B), 'Monitor': (L,T,R,B), ...}
    return tuple(info["Work"])  # type: ignore[return-value]


def _cell_rect(
    slot_index_0_based: int, work: tuple[int, int, int, int]
) -> tuple[int, int, int, int]:
    """
    5x2 그리드에서 slot_index(0~9)에 해당하는 셀의 (x, y, w, h)
    - 작업영역을 정확히 꽉 채우도록 나머지 픽셀을 분배(정렬 시 '딱 맞게' 느낌)
    """
    l, t, r, b = work
    ww = r - l
    wh = b - t

    col = slot_index_0_based % GRID_COLS
    row = slot_index_0_based // GRID_COLS  # 0..GRID_ROWS-1

    x0 = l + (col * ww) // GRID_COLS
    x1 = l + ((col + 1) * ww) // GRID_COLS
    y0 = t + (row * wh) // GRID_ROWS
    y1 = t + ((row + 1) * wh) // GRID_ROWS

    # "빈칸" 방지: 내부 경계는 서로 약간 겹치게 확장(그림자/테두리 가림)
    if col > 0:
        x0 -= OVERLAP_PX
    if col < GRID_COLS - 1:
        x1 += OVERLAP_PX
    if row > 0:
        y0 -= OVERLAP_PX
    if row < GRID_ROWS - 1:
        y1 += OVERLAP_PX

    # 작업영역 밖으로 나가지 않도록 클램프
    x0 = max(l, x0)
    y0 = max(t, y0)
    x1 = min(r, x1)
    y1 = min(b, y1)

    return x0, y0, x1 - x0, y1 - y0


class WindowTilerApp:
    def __init__(self) -> None:
        _set_dpi_aware()

        self.root = tk.Tk()
        self.root.title("윈도우 창 정렬 (10칸)")
        self.root.resizable(False, False)

        self.slots: list[Slot] = [Slot() for _ in range(10)]
        self.slot_title_vars: list[tk.StringVar] = [
            tk.StringVar(value="(비어있음)") for _ in range(10)
        ]

        self.status_var = tk.StringVar(value="준비됨")

        # 캡처(창 선택) 상태
        self._capture_active = False
        self._capture_sequential = False
        self._capture_index = 0  # 0~9

        # Tkinter HWND (자기 자신 창 클릭 방지)
        try:
            self.own_hwnd = int(
                win32gui.GetAncestor(int(self.root.winfo_id()), win32con.GA_ROOT)
            )
        except Exception:
            self.own_hwnd = int(self.root.winfo_id())

        self._build_ui()
        self._start_mouse_listener()

        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self) -> None:
        container = ttk.Frame(self.root, padding=10)
        container.grid(row=0, column=0, sticky="nsew")

        slots_frame = ttk.LabelFrame(container, text="슬롯 (1~10)", padding=10)
        slots_frame.grid(row=0, column=0, sticky="nsew")

        for i in range(10):
            num_lbl = ttk.Label(slots_frame, text=f"{i+1:>2}")
            num_lbl.grid(row=i, column=0, padx=(0, 6), pady=2, sticky="w")

            title_lbl = ttk.Label(
                slots_frame, textvariable=self.slot_title_vars[i], width=52
            )
            title_lbl.grid(row=i, column=1, padx=(0, 6), pady=2, sticky="w")

            btn = ttk.Button(
                slots_frame,
                text="연결",
                command=lambda idx=i: self.start_capture_single(idx),
                width=8,
            )
            btn.grid(row=i, column=2, padx=(0, 6), pady=2)

            clear_btn = ttk.Button(
                slots_frame, text="해제", command=lambda idx=i: self.clear_slot(idx), width=8
            )
            clear_btn.grid(row=i, column=3, pady=2)

        actions = ttk.LabelFrame(container, text="동작", padding=10)
        actions.grid(row=1, column=0, sticky="ew", pady=(10, 0))

        self.btn_seq = ttk.Button(actions, text="연속선택 시작", command=self.start_capture_sequential)
        self.btn_seq.grid(row=0, column=0, padx=4, pady=4)

        self.btn_cancel = ttk.Button(actions, text="취소", command=self.cancel_capture)
        self.btn_cancel.grid(row=0, column=1, padx=4, pady=4)
        # ttk 버튼 command는 "마우스 버튼 놓을 때" 실행되는데,
        # 연속선택 중에 취소 버튼을 클릭하면 그 클릭(릴리즈)이 캡처로 잡혀서
        # 다음 슬롯(예: 6번)에 프로그램 창이 들어가는 문제가 생길 수 있어
        # 버튼 "누르는 순간"에 먼저 캡처를 꺼서 방지합니다.
        self.btn_cancel.bind("<ButtonPress-1>", lambda e: self.cancel_capture())

        self.btn_resize = ttk.Button(actions, text="크기변경", command=self.resize_all)
        self.btn_resize.grid(row=0, column=2, padx=4, pady=4)

        self.btn_arrange = ttk.Button(actions, text="정렬", command=self.arrange_all)
        self.btn_arrange.grid(row=0, column=3, padx=4, pady=4)

        self.btn_clear_all = ttk.Button(actions, text="목록해제(전체)", command=self.clear_all)
        self.btn_clear_all.grid(row=0, column=4, padx=4, pady=4)

        status = ttk.Label(container, textvariable=self.status_var, foreground="#333")
        status.grid(row=2, column=0, sticky="w", pady=(10, 0))

        help_text = (
            "사용법: [연결] 누른 뒤 대상 창을 클릭 → 슬롯 등록\n"
            "      [연속선택 시작] → 창을 1번부터 순서대로 클릭(필요한 만큼) → [취소]로 종료\n"
            "      배치는 '마우스가 있는 모니터'의 작업영역 기준(작업표시줄 제외)"
        )
        help_lbl = ttk.Label(container, text=help_text, justify="left")
        help_lbl.grid(row=3, column=0, sticky="w", pady=(8, 0))

    def _start_mouse_listener(self) -> None:
        def on_click(x, y, button, pressed):
            if button != mouse.Button.left or pressed:
                return
            if not self._capture_active:
                return
            # Tkinter는 메인 스레드에서만 UI 변경 가능
            self.root.after(0, lambda: self._handle_capture_click(int(x), int(y)))

        self._mouse_listener = mouse.Listener(on_click=on_click)
        self._mouse_listener.daemon = True
        self._mouse_listener.start()

    # ---- 슬롯 관리 ----
    def clear_slot(self, idx: int) -> None:
        self.slots[idx] = Slot()
        self.slot_title_vars[idx].set("(비어있음)")

    def clear_all(self) -> None:
        for i in range(10):
            self.clear_slot(i)
        self.status_var.set("목록이 모두 해제되었습니다.")

    # ---- 캡처(창 선택) ----
    def start_capture_single(self, idx: int) -> None:
        self._capture_active = True
        self._capture_sequential = False
        self._capture_index = idx
        self.status_var.set(f"[연결 대기] {idx+1}번 슬롯에 넣을 창을 클릭하세요.")

    def start_capture_sequential(self) -> None:
        # 1번부터 덮어쓰기(원하면 목록해제 후 시작)
        self._capture_active = True
        self._capture_sequential = True
        self._capture_index = 0
        self.status_var.set("[연속선택] 1번 슬롯부터 순서대로 창을 클릭하세요. (취소로 종료)")

    def cancel_capture(self) -> None:
        self._capture_active = False
        self._capture_sequential = False
        self.status_var.set("취소됨. (이미 등록된 슬롯은 유지됩니다)")

    def _handle_capture_click(self, x: int, y: int) -> None:
        if not self._capture_active:
            return

        hwnd = _get_top_level_hwnd_from_point(x, y)
        if not hwnd:
            return
        if hwnd == self.own_hwnd:
            return

        title = _get_window_title(hwnd)

        idx = self._capture_index
        self.slots[idx] = Slot(hwnd=hwnd, title=title)
        self.slot_title_vars[idx].set(title)

        if not self._capture_sequential:
            self._capture_active = False
            self.status_var.set(f"{idx+1}번 슬롯에 등록됨: {title}")
            return

        # sequential
        self._capture_index += 1
        if self._capture_index >= 10:
            self._capture_active = False
            self._capture_sequential = False
            self.status_var.set("연속선택 완료(1~10). 이제 크기변경/정렬을 누르세요.")
        else:
            self.status_var.set(
                f"[연속선택] {idx+1}번 등록됨 → 다음은 {self._capture_index+1}번 슬롯. 계속 클릭하세요. (취소로 종료)"
            )

    # ---- 동작 ----
    def _get_bound_hwnds_in_order(self) -> list[int]:
        hwnds: list[int] = []
        for s in self.slots:
            if s.hwnd and win32gui.IsWindow(s.hwnd):
                hwnds.append(s.hwnd)
        return hwnds

    def resize_all(self) -> None:
        hwnds = self._get_bound_hwnds_in_order()
        if not hwnds:
            messagebox.showinfo("안내", "등록된 창이 없습니다. 먼저 슬롯에 창을 연결하세요.")
            return

        work = _get_monitor_work_area_from_cursor()
        l, t, r, b = work
        ww = r - l
        wh = b - t

        # 일괄 크기: 대표 크기(5x2 기준)
        w = max(50, ww // GRID_COLS)
        h = max(50, wh // GRID_ROWS)

        for hwnd in hwnds:
            _restore_window(hwnd)
            try:
                cur = win32gui.GetWindowRect(hwnd)
                x0, y0 = cur[0], cur[1]
                _set_window_rect(hwnd, x0, y0, w, h)
            except Exception:
                pass

        self.status_var.set(f"크기변경 완료: {w}x{h} (작업영역 기준)")

    def arrange_all(self) -> None:
        any_bound = any(s.hwnd for s in self.slots)
        if not any_bound:
            messagebox.showinfo("안내", "등록된 창이 없습니다. 먼저 슬롯에 창을 연결하세요.")
            return

        work = _get_monitor_work_area_from_cursor()

        moved = 0
        for i, s in enumerate(self.slots):
            if not s.hwnd:
                continue
            if not win32gui.IsWindow(s.hwnd):
                continue

            x, y, w, h = _cell_rect(i, work)
            _restore_window(s.hwnd)
            _set_window_rect(s.hwnd, x, y, w, h)
            moved += 1

        self.status_var.set(f"정렬 완료: {moved}개 창 (5x2)")

    # ---- 종료 ----
    def _on_close(self) -> None:
        try:
            if hasattr(self, "_mouse_listener"):
                self._mouse_listener.stop()
        except Exception:
            pass
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


if __name__ == "__main__":
    WindowTilerApp().run()
