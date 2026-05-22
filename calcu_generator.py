import os
import re
import sys
import tkinter as tk
from dataclasses import dataclass
from tkinter import filedialog, messagebox
from decimal import Decimal, ROUND_HALF_UP
import random

# 의존성: pillow (PIL)
try:
    from PIL import Image, ImageDraw, ImageFont, ImageTk
except ImportError as e:
    raise SystemExit(
        "Pillow가 필요합니다.\n\n설치:\n  pip install pillow\n\n오류: " + str(e)
    )


CANVAS_W = 462
CANVAS_H = 354


@dataclass
class CardState:
    percent: str = "+21.84%"
    profit: str = "+7,654,490 WON"
    symbol: str = "DOGE/USDT"
    side: str = "LONG"  # LONG / SHORT
    leverage: str = "100x"
    entry: str = "0.11445"
    exit: str = "0.1147"


COLORS = {
    "green": (10, 191, 127, 255),  # rgb(10,191,127)
    # (참고 스크린샷 기준) 라벨은 살짝 연한 흰색, 값은 거의 흰색
    "label": (255, 255, 255, int(255 * 0.65)),
    "value": (255, 255, 255, int(255 * 0.98)),
}


POS = {
    "pad_x": 18,
    # 아래 Y는 "baseline(글자 기준선)" 좌표로 맞춥니다. (웹의 textBaseline=alphabetic과 동일)
    "top_percent_y": 44,
    "top_profit_y": 74,
    "section_start_y": 118,
    "row_gap": 58,
    "label_to_value_gap": 24,
}


def _base_dir() -> str:
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def _join(*parts: str) -> str:
    return os.path.join(_base_dir(), *parts)


def _text_width(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont) -> float:
    # Pillow 버전에 따라 API가 달라서 안전하게 처리
    if hasattr(draw, "textlength"):
        return float(draw.textlength(text, font=font))
    try:
        return float(font.getlength(text))
    except Exception:
        bbox = draw.textbbox((0, 0), text, font=font)
        return float(bbox[2] - bbox[0])


def _find_font_file(candidates: list[str]) -> str | None:
    for p in candidates:
        if p and os.path.exists(p):
            return p
    return None


def load_fonts() -> tuple[dict[str, ImageFont.FreeTypeFont], str | None]:
    """
    Roboto 폰트 로딩.
    우선순위:
      1) ./calcu/fonts/Roboto-*.ttf (사용자가 넣어둔 경우)
      2) Windows Fonts 폴더에서 Roboto 검색
      3) 실패 시 기본 폰트(동일 렌더링 보장 불가)

    반환: (fonts, warning_message)
    """
    fonts_dir = _join("calcu", "fonts")
    win_fonts = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")

    # (중요) weight 별로 분리해서 사용 (Regular/Medium/Bold)
    reg = _find_font_file(
        [
            os.path.join(fonts_dir, "Roboto-Regular.ttf"),
            os.path.join(win_fonts, "Roboto-Regular.ttf"),
            os.path.join(win_fonts, "Roboto.ttf"),
        ]
    )
    med = _find_font_file(
        [
            os.path.join(fonts_dir, "Roboto-Medium.ttf"),
            os.path.join(win_fonts, "Roboto-Medium.ttf"),
        ]
    )
    bold = _find_font_file(
        [
            os.path.join(fonts_dir, "Roboto-Bold.ttf"),
            os.path.join(win_fonts, "Roboto-Bold.ttf"),
        ]
    )

    warning = None

    def ft(path: str | None, size: int) -> ImageFont.FreeTypeFont:
        nonlocal warning
        if path:
            return ImageFont.truetype(path, size=size)
        warning = (
            "Roboto 폰트를 찾지 못해 기본 폰트로 렌더링 중입니다.\n"
            "완전히 동일하게 맞추려면 아래 파일을 ./calcu/fonts/ 에 넣어주세요:\n"
            "  Roboto-Regular.ttf\n  Roboto-Medium.ttf\n  Roboto-Bold.ttf"
        )
        return ImageFont.load_default()

    fonts = {
        # 사용자 제공:
        # +21.84 = 32, % = 34
        "percent_num": ft(med, 32),
        "percent_sign": ft(med, 34),
        # +7,654,490 WON = 18
        "profit": ft(med, 18),
        # labels: 16
        "label": ft(reg, 16),
        # values: 18
        "value": ft(bold, 18),
        # LONG/SHORT: 18
        "side": ft(bold, 18),
    }
    return fonts, warning


def cover_crop(bg: Image.Image, target_w: int, target_h: int, zoom: float = 1.0) -> Image.Image:
    """
    CSS background-size: cover 와 동일한 방식으로 중앙 크롭.
    zoom:
      - 1.0 = 일반 cover
      - 1.0 보다 작게 = 더 넓게(덜 확대) 보이도록 (배경 그림이 더 크게 보인다는 요청 대응)
      - 1.0 보다 크게 = 더 확대해서 크롭
    """
    bg = bg.convert("RGBA")
    iw, ih = bg.size
    # zoom은 화면에 보이는 배경 영역을 조절하기 위한 계수
    scale = max(target_w / iw, target_h / ih) * float(zoom)
    sw = int(round(target_w / scale))
    sh = int(round(target_h / scale))
    sx = (iw - sw) // 2
    sy = (ih - sh) // 2
    cropped = bg.crop((sx, sy, sx + sw, sy + sh))
    return cropped.resize((target_w, target_h), resample=Image.LANCZOS)


def split_percent(text: str) -> tuple[str, str]:
    t = (text or "").strip()
    if t.endswith("%"):
        return t[:-1], "%"
    return t, ""


def draw_text_baseline(
    draw: ImageDraw.ImageDraw,
    x: float,
    baseline_y: float,
    text: str,
    font: ImageFont.FreeTypeFont,
    fill,
):
    """
    Pillow는 기본이 top-left 기준이라, 웹과 동일하게 baseline 기준으로 찍기 위한 함수.
    """
    try:
        ascent, _descent = font.getmetrics()
    except Exception:
        ascent = getattr(font, "size", 16)
    y = float(baseline_y) - float(ascent)
    draw.text((x, y), text, font=font, fill=fill)


def parse_float_range(text: str, default_min: float, default_max: float) -> tuple[float, float]:
    """
    예) "20~25", "20-25", " 20.1 ~ 25.9 " 또는 "22.5"
    """
    t = (text or "").strip()
    if not t:
        return default_min, default_max
    t = t.replace("%", "").replace("+", "").strip()
    t = re.sub(r"\s+", "", t)
    m = re.split(r"[~\-]", t)
    m = [x for x in m if x]
    if len(m) == 1:
        v = float(m[0])
        return v, v
    if len(m) >= 2:
        a = float(m[0])
        b = float(m[1])
        return (a, b) if a <= b else (b, a)
    return default_min, default_max


def parse_int_range(text: str, default_min: int, default_max: int) -> tuple[int, int]:
    """
    예) "3,000,000~10,000,000", "3000000-10000000", "5000000"
    """
    t = (text or "").strip()
    if not t:
        return default_min, default_max
    t = t.upper().replace("WON", "").replace("+", "").strip()
    t = re.sub(r"\s+", "", t)
    # 구분자 유지(~ 또는 -)만 남기고 나머지 제거
    cleaned = []
    for ch in t:
        if ch.isdigit() or ch in [",", "~", "-"]:
            cleaned.append(ch)
    t = "".join(cleaned).replace(",", "")
    parts = re.split(r"[~\-]", t)
    parts = [x for x in parts if x]
    if len(parts) == 1:
        v = int(parts[0])
        return v, v
    if len(parts) >= 2:
        a = int(parts[0])
        b = int(parts[1])
        return (a, b) if a <= b else (b, a)
    return default_min, default_max


def round_half_up(value: float, digits: int) -> float:
    q = Decimal("1").scaleb(-digits)  # 10^-digits
    return float(Decimal(str(value)).quantize(q, rounding=ROUND_HALF_UP))


def compute_exit(entry_text: str, percent_value: float, side: str) -> str:
    """
    entry(사용자 입력) + 수익률(%)로 exit 자동 계산.
    - LONG: exit = entry * (1 + p/100)
    - SHORT: exit = entry * (1 - p/100)
    소수점 5자리로 반올림 표시.
    """
    entry_val = float((entry_text or "0").strip())
    p = float(percent_value) / 100.0
    if (side or "").upper() == "SHORT":
        exit_val = entry_val * (1.0 - p)
    else:
        exit_val = entry_val * (1.0 + p)
    exit_val = round_half_up(exit_val, 5)
    return f"{exit_val:.5f}"


def format_percent(percent_value: float) -> str:
    return f"+{percent_value:.2f}%"


def format_profit(profit_value: int) -> str:
    return f"+{profit_value:,} WON"


def render_card(
    state: CardState,
    fonts: dict[str, ImageFont.FreeTypeFont],
    bg_zoom: float = 1.0,
) -> Image.Image:
    bg_path = _join("calcu", "bg.png")
    if not os.path.exists(bg_path):
        raise FileNotFoundError(f"배경 이미지가 없습니다: {bg_path}")

    bg = Image.open(bg_path)
    img = cover_crop(bg, CANVAS_W, CANVAS_H, zoom=bg_zoom)

    draw = ImageDraw.Draw(img)
    x0 = POS["pad_x"]

    # 상단 수익률
    p_num, p_sign = split_percent(state.percent)
    draw_text_baseline(draw, x0, POS["top_percent_y"], p_num, fonts["percent_num"], COLORS["green"])
    w_num = _text_width(draw, p_num, fonts["percent_num"])
    if p_sign:
        draw_text_baseline(
            draw,
            x0 + w_num + 1,
            POS["top_percent_y"],
            p_sign,
            fonts["percent_sign"],
            COLORS["green"],
        )

    # 상단 수익금
    draw_text_baseline(draw, x0, POS["top_profit_y"], state.profit, fonts["profit"], COLORS["green"])

    rows = [
        ("Stock", state.symbol, state.side),
        ("Leverage", state.leverage, None),
        ("Entry Price", state.entry, None),
        ("Exit Price", state.exit, None),
    ]

    for idx, (label, value, extra) in enumerate(rows):
        base_y = POS["section_start_y"] + idx * POS["row_gap"]
        draw_text_baseline(draw, x0, base_y, label, fonts["label"], COLORS["label"])

        value_y = base_y + POS["label_to_value_gap"]
        draw_text_baseline(draw, x0, value_y, value, fonts["value"], COLORS["value"])

        if idx == 0 and extra:
            w_val = _text_width(draw, value, fonts["value"])
            draw_text_baseline(
                draw,
                x0 + w_val + 6,
                value_y,
                extra,
                fonts["side"],
                COLORS["green"],
            )

    return img


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Calcu Screenshot Generator (Python)")

        self.fonts, self.font_warning = load_fonts()

        self.state = CardState()
        self.vars = {
            # 입력은 범위로 받습니다.
            "percent_range": tk.StringVar(value="20~25"),
            "profit_range": tk.StringVar(value="3,000,000~10,000,000"),
            "symbol": tk.StringVar(value=self.state.symbol),
            "side": tk.StringVar(value=self.state.side),
            "leverage": tk.StringVar(value=self.state.leverage),
            "entry": tk.StringVar(value=self.state.entry),
            "count": tk.StringVar(value="1"),
            "prefix": tk.StringVar(value="screenshot"),
            # 배경 확대/축소(cover zoom)
            "bg_zoom": tk.StringVar(value="1.00"),
        }

        self.preview_label = tk.Label(self, bd=0)
        self.preview_label.grid(row=0, column=0, padx=16, pady=16, sticky="n")

        right = tk.Frame(self)
        right.grid(row=0, column=1, padx=16, pady=16, sticky="n")

        tk.Label(right, text="숫자 수정", font=("Segoe UI", 14, "bold")).grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 10)
        )

        self._row(right, 1, "수익률 범위 (예: 20~25)", "percent_range")
        self._row(right, 2, "수익금 범위 (예: 3,000,000~10,000,000)", "profit_range")
        self._row(right, 3, "종목(Stock) 텍스트", "symbol")

        tk.Label(right, text="포지션(LONG/SHORT)").grid(row=4, column=0, sticky="w", pady=4)
        opt = tk.OptionMenu(right, self.vars["side"], "LONG", "SHORT")
        opt.config(width=18)
        opt.grid(row=4, column=1, sticky="w", pady=4)

        self._row(right, 5, "레버리지", "leverage")
        self._row(right, 6, "진입가(Entry Price)", "entry")

        tk.Label(right, text="청산가(Exit Price, 자동)").grid(row=7, column=0, sticky="w", pady=4)
        self.exit_value = tk.Label(right, text="", width=22, anchor="w")
        self.exit_value.grid(row=7, column=1, sticky="w", pady=4)

        self._row(right, 8, "생성 개수", "count")
        self._row(right, 9, "파일명 접두사", "prefix")

        self._row(right, 10, "배경 확대/축소 (예: 1.00)", "bg_zoom")

        btns = tk.Frame(right)
        btns.grid(row=11, column=0, columnspan=2, sticky="w", pady=(12, 0))
        tk.Button(btns, text="현재 1장 저장", command=self.save_one_png, width=12).grid(
            row=0, column=0, padx=(0, 8)
        )
        tk.Button(btns, text="대량 생성", command=self.save_batch, width=12).grid(row=0, column=1)
        tk.Button(btns, text="랜덤 갱신", command=self.refresh_random, width=12).grid(
            row=0, column=2, padx=(8, 0)
        )

        btns2 = tk.Frame(right)
        btns2.grid(row=12, column=0, columnspan=2, sticky="w", pady=(10, 0))
        tk.Button(btns2, text="기본값", command=self.reset, width=12).grid(row=0, column=0)

        self.status = tk.Label(
            right,
            text=self.font_warning or "",
            fg="#ffcc66" if self.font_warning else "#cccccc",
            justify="left",
            wraplength=340,
        )
        self.status.grid(row=13, column=0, columnspan=2, sticky="w", pady=(10, 0))

        for v in self.vars.values():
            v.trace_add("write", lambda *_: self.refresh())

        self._last_img: Image.Image | None = None
        self._last_tk: ImageTk.PhotoImage | None = None

        # 미리보기용 랜덤 샘플(범위 입력을 안정적으로 보여주기 위함)
        self._last_percent_range = None
        self._last_profit_range = None
        self._sample_percent_value = None  # float
        self._sample_profit_value = None  # int

        self.refresh()

    def _row(self, parent: tk.Widget, r: int, label: str, key: str):
        tk.Label(parent, text=label).grid(row=r, column=0, sticky="w", pady=4)
        e = tk.Entry(parent, textvariable=self.vars[key], width=22)
        e.grid(row=r, column=1, sticky="w", pady=4)

    def _get_bg_zoom(self) -> float:
        try:
            z = float(self.vars["bg_zoom"].get().strip() or "1.0")
            if z <= 0:
                return 1.0
            return z
        except Exception:
            return 1.0

    def _get_randomized_values(self, force_new: bool = False) -> tuple[float, int]:
        """
        미리보기에서는 범위가 바뀌지 않으면 같은 랜덤 샘플을 유지합니다.
        """
        pr = self.vars["percent_range"].get()
        fr = self.vars["profit_range"].get()

        if force_new or pr != self._last_percent_range or fr != self._last_profit_range:
            pmin, pmax = parse_float_range(pr, 20.0, 25.0)
            fmin, fmax = parse_int_range(fr, 3_000_000, 10_000_000)
            pv = round_half_up(random.uniform(pmin, pmax), 2)
            fv = random.randint(fmin, fmax)
            self._sample_percent_value = pv
            self._sample_profit_value = fv
            self._last_percent_range = pr
            self._last_profit_range = fr

        # 혹시 None이면 한 번 생성
        if self._sample_percent_value is None or self._sample_profit_value is None:
            return self._get_randomized_values(force_new=True)
        return float(self._sample_percent_value), int(self._sample_profit_value)

    def _build_state_for_preview(self) -> CardState:
        percent_value, profit_value = self._get_randomized_values(force_new=False)
        side = (self.vars["side"].get().strip() or "LONG").upper()
        entry_text = self.vars["entry"].get().strip()
        exit_text = compute_exit(entry_text, percent_value, side)
        self.exit_value.configure(text=exit_text)

        return CardState(
            percent=format_percent(percent_value),
            profit=format_profit(profit_value),
            symbol=self.vars["symbol"].get().strip(),
            side=side,
            leverage=self.vars["leverage"].get().strip(),
            entry=entry_text,
            exit=exit_text,
        )

    def refresh(self):
        try:
            st = self._build_state_for_preview()
            self._last_img = render_card(st, self.fonts, bg_zoom=self._get_bg_zoom())
        except Exception as e:
            # 프리뷰 영역에 오류 표시
            img = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 255))
            d = ImageDraw.Draw(img)
            msg = f"렌더링 오류:\n{e}"
            d.text((10, 10), msg, fill=(255, 255, 255, 255))
            self._last_img = img

        self._last_tk = ImageTk.PhotoImage(self._last_img)
        self.preview_label.configure(image=self._last_tk)

    def refresh_random(self):
        self._get_randomized_values(force_new=True)
        self.refresh()

    def reset(self):
        self.vars["percent_range"].set("20~25")
        self.vars["profit_range"].set("3,000,000~10,000,000")
        self.vars["symbol"].set("DOGE/USDT")
        self.vars["side"].set("LONG")
        self.vars["leverage"].set("100x")
        self.vars["entry"].set("0.11445")
        self.vars["count"].set("1")
        self.vars["prefix"].set("screenshot")
        self.vars["bg_zoom"].set("1.00")
        self.refresh_random()

    def save_one_png(self):
        if self._last_img is None:
            messagebox.showerror("오류", "이미지가 아직 생성되지 않았습니다.")
            return

        default_name = f"{self.vars['prefix'].get().strip() or 'screenshot'}.png"
        path = filedialog.asksaveasfilename(
            title="PNG 저장(1장)",
            defaultextension=".png",
            initialfile=default_name,
            filetypes=[("PNG Image", "*.png")],
        )
        if not path:
            return

        try:
            self._last_img.save(path, format="PNG")
            messagebox.showinfo("완료", f"저장했습니다:\n{path}")
        except Exception as e:
            messagebox.showerror("오류", f"저장 실패:\n{e}")

    def _parse_count(self) -> int:
        try:
            n = int(self.vars["count"].get().strip())
            return max(1, n)
        except Exception:
            return 1

    def save_batch(self):
        """
        사용자가 적은 개수만큼 스크린샷을 한 번에 생성.
        - 수익률: 입력 범위 내에서 소수점 2자리 랜덤
        - 수익금: 입력 범위 내에서 1의 자리까지 랜덤(정수)
        - entry: 사용자 입력 고정
        - exit: 수익률 기반 자동 계산(소수점 5자리 반올림)
        """
        out_dir = filedialog.askdirectory(title="저장할 폴더 선택")
        if not out_dir:
            return

        prefix = self.vars["prefix"].get().strip() or "screenshot"
        n = self._parse_count()
        side = (self.vars["side"].get().strip() or "LONG").upper()
        entry_text = self.vars["entry"].get().strip()

        pmin, pmax = parse_float_range(self.vars["percent_range"].get(), 20.0, 25.0)
        fmin, fmax = parse_int_range(self.vars["profit_range"].get(), 3_000_000, 10_000_000)
        bg_zoom = self._get_bg_zoom()

        try:
            # entry 숫자 검증
            float(entry_text)
        except Exception:
            messagebox.showerror("오류", "진입가(Entry Price)는 숫자로 입력해주세요.")
            return

        ok = 0
        for i in range(1, n + 1):
            percent_value = round_half_up(random.uniform(pmin, pmax), 2)
            profit_value = random.randint(fmin, fmax)
            exit_text = compute_exit(entry_text, percent_value, side)

            state = CardState(
                percent=format_percent(percent_value),
                profit=format_profit(profit_value),
                symbol=self.vars["symbol"].get().strip(),
                side=side,
                leverage=self.vars["leverage"].get().strip(),
                entry=entry_text,
                exit=exit_text,
            )

            img = render_card(state, self.fonts, bg_zoom=bg_zoom)
            filename = f"{prefix}_{i:04d}.png"
            path = os.path.join(out_dir, filename)
            img.save(path, format="PNG")
            ok += 1

        messagebox.showinfo("완료", f"{ok}개 생성했습니다.\n저장 폴더:\n{out_dir}")


def main():
    # 유저가 Roboto 폰트를 쉽게 넣을 수 있도록 폴더 생성
    os.makedirs(_join("calcu", "fonts"), exist_ok=True)
    app = App()
    app.resizable(False, False)
    app.mainloop()


if __name__ == "__main__":
    main()
