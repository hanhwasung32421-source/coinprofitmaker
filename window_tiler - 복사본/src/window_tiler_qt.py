import json
import os
import sys
import time
from dataclasses import dataclass

import win32api
import win32con
import win32gui
import win32process
from pynput import mouse

from PyQt6 import QtCore, QtWidgets

try:
    # Windows 10/11 가상 데스크톱(CTRL+WIN+D) 제어용
    from pyvda import AppView, VirtualDesktop, get_virtual_desktops

    PYVDA_OK = True
    PYVDA_ERR = ""
except Exception as e:
    PYVDA_OK = False
    PYVDA_ERR = repr(e)


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


def _get_window_class(hwnd: int) -> str:
    try:
        return win32gui.GetClassName(hwnd) or ""
    except Exception:
        return ""


def _get_window_pid(hwnd: int) -> int:
    try:
        _tid, pid = win32process.GetWindowThreadProcessId(hwnd)
        return int(pid)
    except Exception:
        return 0


def _get_process_exe(pid: int) -> str:
    """
    프로세스 exe 경로를 가져옵니다(권한에 따라 실패할 수 있음).
    """
    if not pid:
        return ""
    try:
        access = win32con.PROCESS_QUERY_LIMITED_INFORMATION | win32con.PROCESS_VM_READ
        hproc = win32api.OpenProcess(access, False, pid)
        try:
            return win32process.GetModuleFileNameEx(hproc, 0) or ""
        finally:
            try:
                win32api.CloseHandle(hproc)
            except Exception:
                pass
    except Exception:
        return ""


def _window_identity(hwnd: int) -> dict:
    """
    저장/복구용 창 식별 정보(최대한 안정적으로 찾기 위한 힌트).
    """
    pid = _get_window_pid(hwnd)
    return {
        "hwnd": int(hwnd),
        "title": _get_window_title(hwnd),
        "class": _get_window_class(hwnd),
        "pid": pid,
        "exe": _get_process_exe(pid),
    }


def _enum_top_windows() -> list[int]:
    hwnds: list[int] = []

    def cb(hwnd, lparam):
        try:
            if not win32gui.IsWindowVisible(hwnd):
                return True
        except Exception:
            return True
        hwnds.append(int(hwnd))
        return True

    try:
        win32gui.EnumWindows(cb, None)
    except Exception:
        pass
    return hwnds


def _find_hwnd_by_identity(ident: dict) -> int:
    """
    저장된 식별정보로 현재 열려있는 창을 찾아 HWND를 복구합니다(베스트 에포트).
    """
    try:
        hwnd = int(ident.get("hwnd") or 0)
    except Exception:
        hwnd = 0
    if hwnd and win32gui.IsWindow(hwnd):
        return hwnd

    saved_title = str(ident.get("title") or "")
    saved_class = str(ident.get("class") or "")
    saved_exe = str(ident.get("exe") or "")

    candidates = _enum_top_windows()

    # 1) exe + class + title 정확히 일치
    if saved_exe and saved_title:
        for h in candidates:
            if saved_class and _get_window_class(h) != saved_class:
                continue
            if _get_window_title(h) != saved_title:
                continue
            pid = _get_window_pid(h)
            if pid and os.path.normcase(_get_process_exe(pid)) == os.path.normcase(saved_exe):
                return h

    # 2) class + title 정확히 일치
    if saved_title:
        for h in candidates:
            if saved_class and _get_window_class(h) != saved_class:
                continue
            if _get_window_title(h) == saved_title:
                return h

    # 3) title 포함(부분 일치)
    if saved_title:
        for h in candidates:
            if saved_class and _get_window_class(h) != saved_class:
                continue
            if saved_title in _get_window_title(h):
                return h

    return 0


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
        try:
            win32gui.MoveWindow(hwnd, x, y, w, h, True)
        except Exception:
            pass


def _get_monitor_work_area_from_cursor() -> tuple[int, int, int, int]:
    x, y = win32api.GetCursorPos()
    mon = win32api.MonitorFromPoint((x, y), win32con.MONITOR_DEFAULTTONEAREST)
    info = win32api.GetMonitorInfo(mon)
    return tuple(info["Work"])  # type: ignore[return-value]


def _get_sorted_monitor_work_areas() -> list[tuple[int, int, int, int]]:
    """
    연결된 모니터들의 작업영역(작업표시줄 제외)을 X(Left) 기준으로 정렬해서 반환합니다.
    """
    mons = []
    try:
        for (hmon, _hdc, _rect) in win32api.EnumDisplayMonitors():
            info = win32api.GetMonitorInfo(hmon)
            work = tuple(info["Work"])
            mons.append(work)
    except Exception:
        # 실패 시 커서 모니터만 반환
        return [_get_monitor_work_area_from_cursor()]

    mons.sort(key=lambda w: w[0])  # left
    return mons or [_get_monitor_work_area_from_cursor()]


def _cell_rect(slot_index_0_based: int, work: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    """
    5x2 그리드에서 slot_index(0~9)에 해당하는 셀의 (x, y, w, h)
    - 작업영역을 정확히 꽉 채우도록 나머지 픽셀을 분배
    - 경계는 살짝 겹치게 확장(빈틈 제거)
    """
    l, t, r, b = work
    ww = r - l
    wh = b - t

    col = slot_index_0_based % GRID_COLS
    row = slot_index_0_based // GRID_COLS

    x0 = l + (col * ww) // GRID_COLS
    x1 = l + ((col + 1) * ww) // GRID_COLS
    y0 = t + (row * wh) // GRID_ROWS
    y1 = t + ((row + 1) * wh) // GRID_ROWS

    if col > 0:
        x0 -= OVERLAP_PX
    if col < GRID_COLS - 1:
        x1 += OVERLAP_PX
    if row > 0:
        y0 -= OVERLAP_PX
    if row < GRID_ROWS - 1:
        y1 += OVERLAP_PX

    x0 = max(l, x0)
    y0 = max(t, y0)
    x1 = min(r, x1)
    y1 = min(b, y1)

    return x0, y0, x1 - x0, y1 - y0


class ClickRelay(QtCore.QObject):
    clicked = QtCore.pyqtSignal(int, int)


class WindowTiler(QtWidgets.QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("윈도우 창 정렬 (10칸)")
        self.setFixedWidth(760)

        self.slots: list[Slot] = [Slot() for _ in range(10)]
        self.num_labels: list[QtWidgets.QLabel] = []
        self.title_labels: list[QtWidgets.QLabel] = []

        self.status = QtWidgets.QLabel("준비됨")

        # 캡처(창 선택) 상태
        self._capture_active = False
        self._capture_sequential = False
        self._capture_index = 0

        self.own_hwnd = 0
        self._last_settings_path = ""
        # 가상 데스크톱 선택 (None이면 '현재 데스크톱')
        self._selected_desktop_num: int | None = None
        # 캡처 중 강조 표시(네모칸)
        self._highlight_index: int | None = None

        self._build_ui()

        self._relay = ClickRelay()
        self._relay.clicked.connect(self._handle_capture_click)
        self._start_mouse_listener()

    def showEvent(self, event):  # type: ignore[override]
        super().showEvent(event)
        # 실제 top-level HWND 확보(자기 자신 창 클릭 방지)
        try:
            self.own_hwnd = int(win32gui.GetAncestor(int(self.winId()), win32con.GA_ROOT))
        except Exception:
            try:
                self.own_hwnd = int(self.winId())
            except Exception:
                self.own_hwnd = 0

    def closeEvent(self, event):  # type: ignore[override]
        try:
            if hasattr(self, "_mouse_listener"):
                self._mouse_listener.stop()
        except Exception:
            pass
        super().closeEvent(event)

    def _build_ui(self) -> None:
        central = QtWidgets.QWidget()
        self.setCentralWidget(central)

        root = QtWidgets.QVBoxLayout(central)

        self.file_label = QtWidgets.QLabel("세팅 파일: (없음)")
        root.addWidget(self.file_label)

        slots_group = QtWidgets.QGroupBox("슬롯 (1~10)")
        root.addWidget(slots_group)
        grid = QtWidgets.QGridLayout(slots_group)
        grid.setColumnStretch(1, 1)

        for i in range(10):
            num = QtWidgets.QLabel(f"{i+1:>2}")
            title = QtWidgets.QLabel("(비어있음)")
            title.setMinimumWidth(470)
            title.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)

            btn_bind = QtWidgets.QPushButton("연결")
            btn_clear = QtWidgets.QPushButton("해제")

            btn_bind.clicked.connect(lambda checked=False, idx=i: self.start_capture_single(idx))
            btn_clear.clicked.connect(lambda checked=False, idx=i: self.clear_slot(idx))

            self.num_labels.append(num)
            self.title_labels.append(title)

            grid.addWidget(num, i, 0)
            grid.addWidget(title, i, 1)
            grid.addWidget(btn_bind, i, 2)
            grid.addWidget(btn_clear, i, 3)

        actions = QtWidgets.QGroupBox("동작")
        root.addWidget(actions)
        actions_v = QtWidgets.QVBoxLayout(actions)
        row_top = QtWidgets.QHBoxLayout()
        row_desktops = QtWidgets.QHBoxLayout()
        row_arrange = QtWidgets.QHBoxLayout()

        self.btn_seq = QtWidgets.QPushButton("연속선택 시작")
        self.btn_save = QtWidgets.QPushButton("세팅저장")
        self.btn_load = QtWidgets.QPushButton("세팅불러오기")
        self.btn_clear_all = QtWidgets.QPushButton("목록해제(전체)")

        # 가상 데스크톱 선택 버튼(D1~D5). 하나 선택하면 나머지는 비활성화.
        # 같은 버튼을 한 번 더 누르면 선택 해제(=현재 데스크톱).
        self.desktop_buttons: dict[int, QtWidgets.QPushButton] = {}
        for n in range(1, 6):
            b = QtWidgets.QPushButton(f"D{n}")
            b.setCheckable(True)
            b.clicked.connect(lambda checked=False, num=n: self.toggle_desktop(num))
            self.desktop_buttons[n] = b
            row_desktops.addWidget(b)

        self.btn_arrange_left = QtWidgets.QPushButton("왼쪽정렬")
        self.btn_arrange_right = QtWidgets.QPushButton("오른쪽정렬")
        self.btn_clear_all = QtWidgets.QPushButton("목록해제(전체)")

        self.btn_seq.clicked.connect(self.start_capture_sequential)

        self.btn_save.clicked.connect(self.save_settings)
        self.btn_load.clicked.connect(self.load_settings)
        self.btn_arrange_left.clicked.connect(lambda: self.arrange_all(side="left", desktop_num=self._selected_desktop_num))
        self.btn_arrange_right.clicked.connect(lambda: self.arrange_all(side="right", desktop_num=self._selected_desktop_num))
        self.btn_clear_all.clicked.connect(self.clear_all)

        for w in [self.btn_seq, self.btn_save, self.btn_load, self.btn_clear_all]:
            row_top.addWidget(w)

        row_arrange.addWidget(self.btn_arrange_left)
        row_arrange.addWidget(self.btn_arrange_right)

        actions_v.addLayout(row_top)
        actions_v.addLayout(row_desktops)
        actions_v.addLayout(row_arrange)

        root.addWidget(self.status)

        help_lbl = QtWidgets.QLabel(
            "사용법: [연결] 누른 뒤 대상 창을 클릭 → 슬롯 등록\n"
            "      [연속선택 시작] → 창을 1번부터 순서대로 클릭(필요한 만큼) → 버튼이 [종료]로 바뀌며 다시 누르면 종료\n"
            "      [세팅저장]으로 1~10을 파일로 저장, 목록 비운 뒤 [세팅불러오기]로 복구\n"
            "      D1~D5 중 하나를 누르면 해당 가상 데스크톱으로 정렬(자동 전환)\n"
            "      선택된 D버튼을 한 번 더 누르면 선택 해제되어 '현재 데스크톱'에 정렬됩니다."
        )
        root.addWidget(help_lbl)

        if not PYVDA_OK:
            self.status.setText(f"주의: {PYVDA_ERR} (가상 데스크톱 이동/전환 불가).")
        self._sync_desktop_buttons()
        self._set_capture_highlight(None)

    def _start_mouse_listener(self) -> None:
        def on_click(x, y, button, pressed):
            if button != mouse.Button.left or pressed:
                return
            if not self._capture_active:
                return
            # pynput 스레드 → Qt 메인 스레드로 전달
            self._relay.clicked.emit(int(x), int(y))

        self._mouse_listener = mouse.Listener(on_click=on_click)
        self._mouse_listener.daemon = True
        self._mouse_listener.start()

    # ---- 슬롯 관리 ----
    def clear_slot(self, idx: int) -> None:
        self.slots[idx] = Slot()
        self.title_labels[idx].setText("(비어있음)")

    def clear_all(self) -> None:
        for i in range(10):
            self.clear_slot(i)
        self.status.setText("목록이 모두 해제되었습니다.")

    # ---- 캡처(창 선택) ----
    def start_capture_single(self, idx: int) -> None:
        self._capture_active = True
        self._capture_sequential = False
        self._capture_index = idx
        self._set_capture_highlight(idx)
        self.status.setText(f"[연결 대기] {idx+1}번 슬롯에 넣을 창을 클릭하세요.")

    def start_capture_sequential(self) -> None:
        # 토글: 시작/종료
        if self._capture_active and self._capture_sequential:
            self.cancel_capture()
            return

        self._capture_active = True
        self._capture_sequential = True
        self._capture_index = 0
        self.btn_seq.setText("종료")
        self._set_capture_highlight(0)
        self.status.setText("[연속선택] 1번 슬롯부터 순서대로 창을 클릭하세요. (버튼 '종료'로 종료)")

    def cancel_capture(self) -> None:
        self._capture_active = False
        self._capture_sequential = False
        self.btn_seq.setText("연속선택 시작")
        self._set_capture_highlight(None)
        self.status.setText("취소됨. (이미 등록된 슬롯은 유지됩니다)")

    # ---- 가상 데스크톱 선택 ----
    def toggle_desktop(self, num: int) -> None:
        if self._selected_desktop_num == num:
            self._selected_desktop_num = None
        else:
            self._selected_desktop_num = num
        self._sync_desktop_buttons()

    def _sync_desktop_buttons(self) -> None:
        """
        - 다른 D 버튼을 눌렀을 때: 이전 선택 해제 + 새 선택 활성화
        - 같은 D 버튼을 한 번 더 누르면: 선택 해제(=현재 데스크톱)
        """
        for n, b in self.desktop_buttons.items():
            b.setEnabled(True)
            b.setChecked(self._selected_desktop_num == n)

    def keyPressEvent(self, event):  # type: ignore[override]
        # 취소 버튼이 없어도 ESC로 캡처 종료 가능
        if event.key() == QtCore.Qt.Key.Key_Escape and self._capture_active:
            self.cancel_capture()
            event.accept()
            return
        super().keyPressEvent(event)

    def _set_capture_highlight(self, idx: int | None) -> None:
        """
        연속선택/연결 대기 중 현재 슬롯 번호를 네모칸(강조)으로 표시합니다.
        """
        self._highlight_index = idx
        normal_num = ""
        normal_title = ""
        active_num = "border: 2px solid #0078d7; border-radius: 4px; padding: 2px 4px;"
        active_title = (
            "border: 2px solid #0078d7; border-radius: 4px; padding: 2px 6px;"
            "background-color: rgba(0,120,215,0.06);"
        )

        for i in range(10):
            is_active = idx is not None and i == idx
            try:
                self.num_labels[i].setStyleSheet(active_num if is_active else normal_num)
                self.title_labels[i].setStyleSheet(active_title if is_active else normal_title)
            except Exception:
                pass

    @QtCore.pyqtSlot(int, int)
    def _handle_capture_click(self, x: int, y: int) -> None:
        if not self._capture_active:
            return

        hwnd = _get_top_level_hwnd_from_point(x, y)
        if not hwnd:
            return
        if self.own_hwnd and hwnd == self.own_hwnd:
            return

        title = _get_window_title(hwnd)
        idx = self._capture_index

        self.slots[idx] = Slot(hwnd=hwnd, title=title)
        self.title_labels[idx].setText(title)

        if not self._capture_sequential:
            self._capture_active = False
            self._set_capture_highlight(None)
            self.status.setText(f"{idx+1}번 슬롯에 등록됨: {title}")
            return

        self._capture_index += 1
        if self._capture_index >= 10:
            self._capture_active = False
            self._capture_sequential = False
            self.btn_seq.setText("연속선택 시작")
            self._set_capture_highlight(None)
            self.status.setText("연속선택 완료(1~10). 이제 정렬을 누르세요.")
        else:
            self._set_capture_highlight(self._capture_index)
            self.status.setText(
                f"[연속선택] {idx+1}번 등록됨 → 다음은 {self._capture_index+1}번 슬롯. 계속 클릭하세요. (취소로 종료)"
            )

    # ---- 동작 ----
    def _get_bound_hwnds_in_order(self) -> list[int]:
        hwnds: list[int] = []
        for s in self.slots:
            if s.hwnd and win32gui.IsWindow(s.hwnd):
                hwnds.append(s.hwnd)
        return hwnds

    def _any_bound(self) -> bool:
        return any(s.hwnd for s in self.slots)

    def save_settings(self) -> None:
        if not self._any_bound():
            QtWidgets.QMessageBox.information(self, "안내", "저장할 슬롯이 없습니다. 먼저 1~10 슬롯에 창을 연결하세요.")
            return

        path, _ = QtWidgets.QFileDialog.getSaveFileName(
            self,
            "세팅 저장",
            self._last_settings_path or "window_tiler_settings.json",
            "JSON 파일 (*.json);;모든 파일 (*)",
        )
        if not path:
            return

        data = {
            "version": 1,
            "saved_at": int(time.time()),
            "slots": [],
        }
        for s in self.slots:
            if s.hwnd and win32gui.IsWindow(s.hwnd):
                data["slots"].append(_window_identity(s.hwnd))
            else:
                data["slots"].append(None)

        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            self._last_settings_path = path
            self.file_label.setText(f"세팅 파일: {os.path.basename(path)}")
            self.file_label.setToolTip(path)
            self.status.setText("세팅 저장됨")
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "오류", f"저장 실패: {e}")

    def load_settings(self) -> None:
        if self._any_bound():
            res = QtWidgets.QMessageBox.question(
                self,
                "확인",
                "현재 슬롯에 내용이 있습니다. 전부 지우고 불러올까요?",
                QtWidgets.QMessageBox.StandardButton.Yes | QtWidgets.QMessageBox.StandardButton.No,
            )
            if res != QtWidgets.QMessageBox.StandardButton.Yes:
                return
            self.clear_all()

        path, _ = QtWidgets.QFileDialog.getOpenFileName(
            self,
            "세팅 불러오기",
            os.path.dirname(self._last_settings_path) if self._last_settings_path else "",
            "JSON 파일 (*.json);;모든 파일 (*)",
        )
        if not path:
            return

        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            QtWidgets.QMessageBox.critical(self, "오류", f"불러오기 실패(파일 읽기): {e}")
            return

        slots = data.get("slots")
        if not isinstance(slots, list) or len(slots) != 10:
            QtWidgets.QMessageBox.critical(self, "오류", "세팅 파일 형식이 올바르지 않습니다(슬롯 10개 필요).")
            return

        restored = 0
        missing = 0
        for i in range(10):
            ident = slots[i]
            if not ident:
                self.clear_slot(i)
                continue

            hwnd = _find_hwnd_by_identity(ident)
            if hwnd:
                title = _get_window_title(hwnd)
                self.slots[i] = Slot(hwnd=hwnd, title=title)
                self.title_labels[i].setText(title)
                restored += 1
            else:
                self.clear_slot(i)
                missing += 1

        self._last_settings_path = path
        self.file_label.setText(f"세팅 파일: {os.path.basename(path)}")
        self.file_label.setToolTip(path)
        self.status.setText(f"세팅 불러옴: 복구 {restored}개 / 못 찾음 {missing}개")

    def _work_area_for_side(self, side: str) -> tuple[int, int, int, int]:
        mons = _get_sorted_monitor_work_areas()
        if len(mons) == 1:
            return mons[0]
        if side == "right":
            return mons[-1]
        return mons[0]

    def _ensure_virtual_desktop(self, desktop_num: int) -> bool:
        """
        지정한 가상 데스크톱 번호가 존재하는지 확인합니다.
        """
        if not PYVDA_OK:
            QtWidgets.QMessageBox.warning(
                self,
                "안내",
                "pyvda를 사용할 수 없어 가상 데스크톱 이동/전환은 불가합니다.\n"
                f"- 원인: {PYVDA_ERR}\n"
                "- 해결: python -m pip install pyvda  (또는 requirements.txt 재설치)",
            )
            return False
        try:
            count = len(get_virtual_desktops())
        except Exception:
            count = 0

        if count <= 0:
            QtWidgets.QMessageBox.warning(self, "안내", "가상 데스크톱 정보를 읽지 못했습니다.")
            return False
        if desktop_num < 1 or desktop_num > count:
            QtWidgets.QMessageBox.information(
                self,
                "안내",
                f"현재 가상 데스크톱은 {count}개 입니다. D{desktop_num}은 존재하지 않습니다.\n"
                f"(CTRL+WIN+D로 데스크톱을 추가한 뒤 다시 시도하세요.)",
            )
            return False
        return True

    def arrange_all(self, side: str = "left", desktop_num: int | None = None) -> None:
        any_bound = any(s.hwnd for s in self.slots)
        if not any_bound:
            QtWidgets.QMessageBox.information(self, "안내", "등록된 창이 없습니다. 먼저 슬롯에 창을 연결하세요.")
            return

        # 1) 가상 데스크톱 지정이 있으면: 해당 데스크톱으로 창 이동 + 데스크톱 전환
        if desktop_num is not None:
            if not self._ensure_virtual_desktop(desktop_num):
                return
            try:
                vd = VirtualDesktop(desktop_num)
                for s in self.slots:
                    if not s.hwnd or not win32gui.IsWindow(s.hwnd):
                        continue
                    try:
                        AppView(int(s.hwnd)).move(vd)
                    except Exception:
                        pass

                try:
                    vd.go()
                    QtWidgets.QApplication.processEvents()
                    time.sleep(0.12)
                except Exception:
                    pass
            except Exception:
                pass

        work = self._work_area_for_side(side)
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

        if desktop_num is None:
            self.status.setText(f"{'왼쪽' if side=='left' else '오른쪽'}정렬 완료: {moved}개 창 (현재 데스크톱, 5x2)")
        else:
            self.status.setText(
                f"{'왼쪽' if side=='left' else '오른쪽'}정렬 완료: {moved}개 창 (D{desktop_num}, 5x2)"
            )


def main() -> int:
    _set_dpi_aware()
    app = QtWidgets.QApplication(sys.argv)
    win = WindowTiler()
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
