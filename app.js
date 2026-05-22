/* eslint-disable no-alert */
(() => {
  const CANVAS_W = 462;
  const CANVAS_H = 354;

  /** @type {HTMLCanvasElement} */
  const canvas = document.getElementById("cardCanvas");
  const ctx = canvas.getContext("2d");

  const els = {
    percentMin: document.getElementById("inpPercentMin"),
    percentMax: document.getElementById("inpPercentMax"),
    profitMin: document.getElementById("inpProfitMin"),
    profitMax: document.getElementById("inpProfitMax"),
    symbol: document.getElementById("inpSymbol"),
    side: document.getElementById("inpSide"),
    leverage: document.getElementById("inpLeverage"),
    entry: document.getElementById("inpEntry"),
    entryReal: document.getElementById("inpEntryReal"),
    exit: document.getElementById("inpExit"),
    bgZoom: document.getElementById("inpBgZoom"),
    shiftUp: document.getElementById("btnShiftUp"),
    shiftDown: document.getElementById("btnShiftDown"),
    shiftLeft: document.getElementById("btnShiftLeft"),
    shiftRight: document.getElementById("btnShiftRight"),
    shiftReset: document.getElementById("btnShiftReset"),

    padX: document.getElementById("inpPadX"),
    topPercentY: document.getElementById("inpTopPercentY"),
    topProfitY: document.getElementById("inpTopProfitY"),
    percentSignDy: document.getElementById("inpPercentSignDy"),
    sectionStartY: document.getElementById("inpSectionStartY"),
    rowGap: document.getElementById("inpRowGap"),
    labelToValueGap: document.getElementById("inpLabelToValueGap"),
    sideDx: document.getElementById("inpSideDx"),
    sideDy: document.getElementById("inpSideDy"),
    r1LabelDy: document.getElementById("inpR1LabelDy"),
    r1ValueDy: document.getElementById("inpR1ValueDy"),
    r2LabelDy: document.getElementById("inpR2LabelDy"),
    r2ValueDy: document.getElementById("inpR2ValueDy"),
    r3LabelDy: document.getElementById("inpR3LabelDy"),
    r3ValueDy: document.getElementById("inpR3ValueDy"),
    r4LabelDy: document.getElementById("inpR4LabelDy"),
    r4ValueDy: document.getElementById("inpR4ValueDy"),

    count: document.getElementById("inpCount"),
    prefix: document.getElementById("inpPrefix"),
    generate: document.getElementById("btnGenerate"),
    downloadZip: document.getElementById("btnDownloadZip"),
    reroll: document.getElementById("btnReroll"),
    reset: document.getElementById("btnReset"),

  };

  const sideUi = {
    longBtn: document.getElementById("btnSideLong"),
    shortBtn: document.getElementById("btnSideShort"),
    modal: document.getElementById("sideModal"),
    modalLong: document.getElementById("modalSideLong"),
    modalShort: document.getElementById("modalSideShort"),
  };

  const DEFAULTS = {
    percentMin: "20",
    percentMax: "25",
    // 만원 단위 입력
    profitMin: "300",
    profitMax: "1000",
    symbol: "DOGE/USDT",
    side: "LONG",
    leverage: "100x",
    entry: "0.11445",
    bgZoom: 1.0,
    count: 1,
    prefix: "screenshot",
  };

  // 배경 이동은 입력칸 없이 버튼으로만 조절
  let bgShiftX = 0;
  let bgShiftY = 28;

  // ---- 스타일 (사용자 제공 값 반영) ----
  const COLORS = {
    green: "rgb(10,191,127)",
    red: "rgb(250,75,75)",
    // (스크린샷 기준) label은 연한 흰색, value는 거의 흰색
    label: "rgb(166,166,166)",
    value: "rgb(255,255,255)",
  };

  // 폰트: Roboto
  const FONT = {
    percentNum: "500 32px Roboto",
    percentSign: "500 34px Roboto",
    profit: "500 20px Roboto",
    label: "400 16px Roboto",
    value: "700 18px Roboto",
    side: "700 18px Roboto",
  };

  // 좌표 (462x354 캔버스 기준). (제공된 .dg-body 카드 기준)
  const POS = {
    padX: 18,
    topPercentY: 44,
    topProfitY: 76,
    sectionStartY: 118,
    rowGap: 58,
    labelToValueGap: 24,
    // %가 숫자보다 살짝 아래에 붙는 느낌
    percentSignDy: 3,
    // 배경을 조금 더 "내려" 보이게(카드 안에서 배경이 아래로 이동)
    bgShiftDownPx: 28,
  };

  function numFrom(inputEl, fallback) {
    // inputEl이 없을 때 Number(null)=0 이 되어 좌표가 전부 0으로 깨지는 문제 방지
    if (!inputEl) return fallback;
    const v = Number(inputEl.value);
    return Number.isFinite(v) ? v : fallback;
  }

  function getFont() {
    // 사용자 입력이 없으면 기존 FONT 기반으로 fallback
    const sPercentNum = Math.max(1, Math.round(numFrom(els.sizePercentNum, 32)));
    const sPercentSign = Math.max(1, Math.round(numFrom(els.sizePercentSign, 34)));
    const sProfit = Math.max(1, Math.round(numFrom(els.sizeProfit, 20)));
    const sLabel = Math.max(1, Math.round(numFrom(els.sizeLabel, 16)));
    const sValue = Math.max(1, Math.round(numFrom(els.sizeValue, 18)));
    const sSide = Math.max(1, Math.round(numFrom(els.sizeSide, 18)));
    return {
      percentNum: `500 ${sPercentNum}px Roboto`,
      percentSign: `500 ${sPercentSign}px Roboto`,
      profit: `500 ${sProfit}px Roboto`,
      label: `400 ${sLabel}px Roboto`,
      value: `700 ${sValue}px Roboto`,
      side: `700 ${sSide}px Roboto`,
    };
  }

  function getPos() {
    return {
      padX: Math.round(numFrom(els.padX, POS.padX)),
      topPercentY: Math.round(numFrom(els.topPercentY, POS.topPercentY)),
      topProfitY: Math.round(numFrom(els.topProfitY, POS.topProfitY)),
      sectionStartY: Math.round(numFrom(els.sectionStartY, POS.sectionStartY)),
      rowGap: Math.round(numFrom(els.rowGap, POS.rowGap)),
      labelToValueGap: Math.round(numFrom(els.labelToValueGap, POS.labelToValueGap)),
      percentSignDy: Math.round(numFrom(els.percentSignDy, POS.percentSignDy)),
      sideDx: Math.round(numFrom(els.sideDx, 6)),
      sideDy: Math.round(numFrom(els.sideDy, 0)),
      rowLabelDy: [
        Math.round(numFrom(els.r1LabelDy, 0)),
        Math.round(numFrom(els.r2LabelDy, 0)),
        Math.round(numFrom(els.r3LabelDy, 0)),
        Math.round(numFrom(els.r4LabelDy, 0)),
      ],
      rowValueDy: [
        Math.round(numFrom(els.r1ValueDy, 0)),
        Math.round(numFrom(els.r2ValueDy, 0)),
        Math.round(numFrom(els.r3ValueDy, 0)),
        Math.round(numFrom(els.r4ValueDy, 0)),
      ],
    };
  }

  const bgImg = new Image();
  bgImg.src = "./calcu/bg.png";

  // 미리보기에서는 범위가 바뀌지 않으면 같은 랜덤 값을 유지
  let samplePercent = null; // number
  let sampleProfit = null; // number (int)
  let sampleEntry = null; // string (0.11445)
  let lastEntryBase = null; // string
  let lastPercentKey = null;
  let lastProfitKey = null;

  // 생성 결과(갤러리)
  /** @type {{percent:number, profit:number}[]} */
  let generatedItems = [];
  let previewIndex = -1; // 생성된 것 중 현재 미리보기로 보여줄 인덱스

  // 캔버스 클릭 선택(글자 항목별 조정)
  /** @type {null | string} */
  let selectedTextId = null;
  /** @type {Record<string, {dx:number, dy:number, size:number|null, bold:boolean|null}>} */
  const textAdjust = {};
  /** @type {Record<string, {x:number, y:number}>} */
  const baseAnchor = {};
  /** @type {{id:string,name:string,x:number,y:number,w:number,h:number,size:number}[]} */
  let lastHitboxes = [];

  function parseRange(text, fallbackMin, fallbackMax) {
    const t = String(text || "")
      .trim()
      .replace("%", "")
      .replace("+", "")
      .replace(/\s+/g, "");
    if (!t) return [fallbackMin, fallbackMax];
    const parts = t.split(/~|-/).filter(Boolean);
    if (parts.length === 1) {
      const v = Number(parts[0].replace(/,/g, ""));
      return [v, v];
    }
    if (parts.length >= 2) {
      const a = Number(parts[0].replace(/,/g, ""));
      const b = Number(parts[1].replace(/,/g, ""));
      return a <= b ? [a, b] : [b, a];
    }
    return [fallbackMin, fallbackMax];
  }

  function roundTo(value, digits) {
    const f = 10 ** digits;
    return Math.round((value + Number.EPSILON) * f) / f;
  }

  function parseNumber(text, fallback) {
    const t = String(text ?? "")
      .trim()
      .replace(/,/g, "")
      .replace("%", "");
    const n = Number(t);
    return Number.isFinite(n) ? n : fallback;
  }

  function pickPercent2NoZeroSecondDigit(pMin, pMax) {
    // 0.01 단위 정수로 뽑되, (x*100)%10 != 0  (백분의 자리 0 금지)
    const minI = Math.ceil(Math.min(pMin, pMax) * 100);
    const maxI = Math.floor(Math.max(pMin, pMax) * 100);
    let pi = minI;
    if (minI === maxI) {
      // 범위가 단일 값이면 그대로 사용 (이 값이 0으로 끝나면 범위 내에서 해결 불가)
    } else {
      for (let k = 0; k < 60; k++) {
        const cand = Math.floor(Math.random() * (maxI - minI + 1)) + minI;
        if (Math.abs(cand) % 10 !== 0) {
          pi = cand;
          break;
        }
        pi = cand;
      }
      if (Math.abs(pi) % 10 === 0) {
        if (pi + 1 <= maxI) pi += 1;
        else if (pi - 1 >= minI) pi -= 1;
      }
    }
    return pi / 100;
  }

  function formatPercent(p) {
    // 소수점 2자리 무조건 표시
    return `+${Number(p).toFixed(2)}%`;
  }

  function formatProfit(won) {
    return `+${won.toLocaleString("en-US")} WON`;
  }

  function getPercentMinMax() {
    const a = parseNumber(els.percentMin?.value, 20);
    const b = parseNumber(els.percentMax?.value, 25);
    const minP = Math.min(a, b);
    const maxP = Math.max(a, b);
    return { minP, maxP };
  }

  function parseEntryToInt(entryText) {
    // 기본 진입가 형식: 0.11445 (소수 5자리)
    const n = Number(String(entryText || "").trim());
    if (!Number.isFinite(n)) return null;
    return Math.round(n * 100000); // 1e5
  }

  function entryIntToText(intVal) {
    return (intVal / 100000).toFixed(5);
  }

  function randomEntryFromBase(entryBaseText) {
    const baseInt = parseEntryToInt(entryBaseText);
    if (baseInt == null) return String(entryBaseText || "").trim();
    // 마지막 자리(소수 5번째 자리) 기준 +-2
    const deltas = [-2, -1, 1, 2];
    const d = deltas[Math.floor(Math.random() * deltas.length)];
    const next = Math.max(0, baseInt + d);
    return entryIntToText(next);
  }

  function parseLeverage(text) {
    // "100x", "50X", "100" 등에서 숫자만 추출
    const m = String(text || "").match(/(\d+(\.\d+)?)/);
    const v = m ? Number(m[1]) : 1;
    return Number.isFinite(v) && v > 0 ? v : 1;
  }

  function computeExit(entry, pnlPercent, side, leverageText) {
    /**
     * 첨부 스크린샷 기준:
     * - 표시되는 +21.84% 는 '가격 변동률'이 아니라 레버리지 적용된 PnL% 입니다.
     * - 가격 변동률(%) = pnlPercent / leverage
     *   예) 100x, +21.84%  => 가격은 +0.2184% 움직임
     *
     * LONG: exit = entry * (1 + (pnlPercent/100)/leverage)
     * SHORT: exit = entry * (1 - (pnlPercent/100)/leverage)
     *
     * 소수점 5자리 반올림 후 5자리로 표시.
     */
    const e = Number(entry);
    const lev = parseLeverage(leverageText);
    const p = (Number(pnlPercent) / 100) / lev;
    const isShort = String(side || "").toUpperCase() === "SHORT";
    const raw = isShort ? e * (1 - p) : e * (1 + p);
    const rounded = roundTo(raw, 5);
    return rounded.toFixed(5);
  }

  function getBgZoom() {
    if (!els.bgZoom) return 1.0;
    const z = Number(els.bgZoom.value);
    if (!Number.isFinite(z) || z <= 0) return 1.0;
    return z;
  }

  function getBgShiftX() {
    return Math.round(bgShiftX);
  }

  function getBgShiftY() {
    return Math.round(bgShiftY);
  }

  function getCount() {
    const n = Number(els.count.value);
    if (!Number.isFinite(n)) return 1;
    return Math.max(1, Math.floor(n));
  }

  function rerollIfNeeded(force = false) {
    const fk = `${String(els.profitMin?.value || "")}|${String(els.profitMax?.value || "")}`;
    const { minP, maxP } = getPercentMinMax();
    const pk = `${minP}|${maxP}`;
    if (force || pk !== lastPercentKey || fk !== lastProfitKey || samplePercent === null || sampleProfit === null) {
      samplePercent = pickPercent2NoZeroSecondDigit(minP, maxP);
      const { minWon, maxWon } = getProfitMinMax();
      sampleProfit = minWon === maxWon ? minWon : Math.floor(Math.random() * (maxWon - minWon + 1)) + minWon;
      lastPercentKey = pk;
      lastProfitKey = fk;
    }
    return { percent: samplePercent, profit: sampleProfit };
  }

  function parseManWon(text, fallbackManWon) {
    // 만원 단위 입력 -> WON 변환
    const man = parseNumber(text, fallbackManWon);
    return Math.floor(man * 10000);
  }

  function getProfitMinMax() {
    const a = parseManWon(els.profitMin?.value, 300);
    const b = parseManWon(els.profitMax?.value, 1000);
    const minWon = Math.min(a, b);
    const maxWon = Math.max(a, b);
    return { minWon, maxWon };
  }

  function randomPercentProfit() {
    const { minP: pMin, maxP: pMax } = getPercentMinMax();
    const { minWon: fMin, maxWon: fMax } = getProfitMinMax();
    const p = pickPercent2NoZeroSecondDigit(pMin, pMax);
    const f = fMin === fMax ? fMin : Math.floor(Math.random() * (fMax - fMin + 1)) + fMin;
    return { percent: p, profit: f };
  }

  function drawBackgroundCoverTo(targetCtx) {
    // cover 렌더링 (center/cover)
    const iw = bgImg.naturalWidth || bgImg.width;
    const ih = bgImg.naturalHeight || bgImg.height;
    if (!iw || !ih) return;

    // zoom < 1.0: 더 넓게 보이도록(덜 확대) / zoom > 1.0: 더 확대
    const zoom = getBgZoom();
    const scale = Math.max(CANVAS_W / iw, CANVAS_H / ih) * zoom;
    const sw = CANVAS_W / scale;
    const sh = CANVAS_H / scale;
    // 배경 이동: +X(오른쪽) => crop window를 왼쪽으로(sx 감소)
    const sx0 = (iw - sw) / 2;
    const sy0 = (ih - sh) / 2;
    const shiftXSrc = getBgShiftX() / scale;
    const shiftYSrc = getBgShiftY() / scale;
    let sx = sx0 - shiftXSrc;
    let sy = sy0 - shiftYSrc;

    sy = Math.max(0, Math.min(sy, ih - sh));
    sx = Math.max(0, Math.min(sx, iw - sw));
    targetCtx.drawImage(bgImg, sx, sy, sw, sh, 0, 0, CANVAS_W, CANVAS_H);
  }

  function drawBackgroundCover() {
    drawBackgroundCoverTo(ctx);
  }

  function splitPercentText(text) {
    // "+21.84%" => ["+21.84", "%"]
    const t = (text || "").trim();
    if (t.endsWith("%")) return [t.slice(0, -1), "%"];
    return [t, ""];
  }

  function getOrInitAdjust(id) {
    if (!textAdjust[id]) textAdjust[id] = { dx: 0, dy: 0, size: null, bold: null };
    return textAdjust[id];
  }

  function parseFontSizePx(fontStr, fallback = 16) {
    const m = String(fontStr || "").match(/(\d+(?:\.\d+)?)px/);
    return m ? Number(m[1]) : fallback;
  }

  function fontForTextId(id, baseSizes) {
    // baseSizes: {percentNum, percentSign, profit, label, value, side}
    const adj = getOrInitAdjust(id);
    const baseW = (() => {
      if (id === "profit" || id === "percentNum" || id === "percentSign") return 500;
      if (id.endsWith("Label")) return 400;
      // values + side
      return 700;
    })();
    const w = adj.bold === true ? 700 : adj.bold === false ? baseW : baseW;
    const base = (() => {
      if (id === "percentNum") return baseSizes.percentNum;
      if (id === "percentSign") return baseSizes.percentSign;
      if (id === "profit") return baseSizes.profit;
      if (id.endsWith("Label")) return baseSizes.label;
      if (id === "side") return baseSizes.side;
      return baseSizes.value;
    })();
    const size = adj.size == null ? base : adj.size;
    return `${w} ${size}px Roboto`;
  }

  function drawTextTo(targetCtx, { id, name, text, x, y, font, fill, recordHitbox }) {
    const adj = getOrInitAdjust(id);
    const xx = x + adj.dx;
    const yy = y + adj.dy;
    targetCtx.font = font;
    targetCtx.fillStyle = fill;
    targetCtx.fillText(text, xx, yy);

    const size = parseFontSizePx(font, 16);
    if (recordHitbox) {
      const m = targetCtx.measureText(text);
      const asc = Number.isFinite(m.actualBoundingBoxAscent) ? m.actualBoundingBoxAscent : size * 0.8;
      const des = Number.isFinite(m.actualBoundingBoxDescent) ? m.actualBoundingBoxDescent : size * 0.25;
      lastHitboxes.push({
        id,
        name,
        x: xx,
        y: yy - asc,
        w: m.width,
        h: asc + des,
        size,
      });
      return m.width;
    }
    return targetCtx.measureText(text).width;
  }

  function buildCardTextData(percentValue, profitValue, entryOverride) {
    const symbol = (els.symbol?.value || "").trim();
    const side = (els.side?.value || "LONG").trim();
    const leverage = (els.leverage?.value || "").trim();
    const entry = (entryOverride ?? els.entry?.value ?? "").trim();
    if (els.entryReal) els.entryReal.value = entry;
    const exit = computeExit(entry, percentValue, side, leverage);
    if (els.exit) els.exit.value = exit;
    return {
      percentText: formatPercent(percentValue),
      profitText: formatProfit(profitValue),
      symbol,
      side,
      leverage,
      entry,
      exit,
    };
  }

  function getBaseSizes() {
    // 기본 글자 크기는 고정 (UI에서 항목별 +/- 로 조절)
    return { percentNum: 32, percentSign: 34, profit: 20, label: 16, value: 18, side: 18 };
  }

  function drawCardTo(targetCtx, percentValue, profitValue, { recordHitboxes = false, entryOverride } = {}) {
    const POS2 = getPos();
    const baseSizes = getBaseSizes();

    if (recordHitboxes) lastHitboxes = [];

    targetCtx.clearRect(0, 0, CANVAS_W, CANVAS_H);
    drawBackgroundCoverTo(targetCtx);

    const t = buildCardTextData(percentValue, profitValue, entryOverride);
    targetCtx.textAlign = "left";
    targetCtx.textBaseline = "alphabetic";

    // percent (+24.8%)
    const [pNum, pSign] = splitPercentText(t.percentText);
    const x0 = POS2.padX;
    // 요청: 수익률(숫자) 시작점을 현재보다 5px 아래로
    const y0 = POS2.topPercentY + 5;
    const wNum = drawTextTo(targetCtx, {
      id: "percentNum",
      name: "수익률 숫자",
      text: pNum,
      x: x0,
      y: y0,
      font: fontForTextId("percentNum", baseSizes),
      fill: COLORS.green,
      recordHitbox: recordHitboxes,
    });
    if (pSign) {
      // % 위치는 최초 렌더링 기준(anchor)을 고정하고, 이후에는 그 기준에서만 이동
      // 요청: % 시작점을 위로 1px 더 이동 => 아래 3px, 왼쪽 1px
      if (!baseAnchor.percentSign) baseAnchor.percentSign = { x: x0 + wNum + 1 - 1, y: y0 + POS2.percentSignDy + 3 };
      drawTextTo(targetCtx, {
        id: "percentSign",
        name: "%",
        text: pSign,
        x: baseAnchor.percentSign.x,
        y: baseAnchor.percentSign.y,
        font: fontForTextId("percentSign", baseSizes),
        fill: COLORS.green,
        recordHitbox: recordHitboxes,
      });
    }

    // profit
    drawTextTo(targetCtx, {
      id: "profit",
      name: "수익금",
      text: t.profitText,
      x: POS2.padX,
      y: POS2.topProfitY,
      font: fontForTextId("profit", baseSizes),
      fill: COLORS.green,
      recordHitbox: recordHitboxes,
    });

    // rows
    const rows = [
      { key: "stock", label: "Stock", value: t.symbol, extra: t.side },
      { key: "leverage", label: "Leverage", value: t.leverage },
      { key: "entry", label: "Entry Price", value: t.entry },
      { key: "exit", label: "Exit Price", value: t.exit },
    ];

    rows.forEach((row, idx) => {
      const baseY = POS2.sectionStartY + idx * POS2.rowGap;
      const labelY = baseY + (POS2.rowLabelDy?.[idx] ?? 0);
      const valueY = baseY + POS2.labelToValueGap + (POS2.rowValueDy?.[idx] ?? 0);

      const labelId = `${row.key}Label`;
      const valueId = `${row.key}Value`;

      drawTextTo(targetCtx, {
        id: labelId,
        name: `${row.label} 라벨`,
        text: row.label,
        x: POS2.padX,
        y: labelY,
        font: fontForTextId(labelId, baseSizes),
        fill: COLORS.label,
        recordHitbox: recordHitboxes,
      });

      const wVal = drawTextTo(targetCtx, {
        id: valueId,
        name: `${row.label} 값`,
        text: row.value,
        x: POS2.padX,
        y: valueY,
        font: fontForTextId(valueId, baseSizes),
        fill: COLORS.value,
        recordHitbox: recordHitboxes,
      });

      if (idx === 0 && row.extra) {
        // LONG/SHORT 위치도 최초 렌더링 기준(anchor)을 고정
        if (!baseAnchor.side) {
          baseAnchor.side = { x: POS2.padX + wVal + POS2.sideDx, y: valueY + POS2.sideDy };
        }
        drawTextTo(targetCtx, {
          id: "side",
          name: "LONG/SHORT",
          text: row.extra,
          x: baseAnchor.side.x,
          y: baseAnchor.side.y,
          font: fontForTextId("side", baseSizes),
          fill: String(row.extra).toUpperCase() === "SHORT" ? COLORS.red : COLORS.green,
          recordHitbox: recordHitboxes,
        });
      }
    });

    // 선택 강조 표시(미리보기)
    if (recordHitboxes && selectedTextId) {
      const b = lastHitboxes.find((x) => x.id === selectedTextId);
      if (b) {
        targetCtx.save();
        targetCtx.strokeStyle = "rgba(255,255,255,0.55)";
        targetCtx.lineWidth = 1;
        targetCtx.strokeRect(b.x - 2, b.y - 2, b.w + 4, b.h + 4);
        targetCtx.restore();
      }
    }
  }

  function renderPreview() {
    // 생성된 결과가 있으면 그 중 선택된(또는 첫번째) 것을 미리보기로
    if (generatedItems.length > 0) {
      if (previewIndex < 0 || previewIndex >= generatedItems.length) previewIndex = 0;
      const it = generatedItems[previewIndex];
      drawCardTo(ctx, it.percent, it.profit, { recordHitboxes: true, entryOverride: it.entry });
      return;
    }
    // 생성된 결과가 없을 때: 기준진입가 마지막 자리 +-2 랜덤 적용
    const baseEntry = (els.entry?.value || "").trim();
    if (sampleEntry == null || lastEntryBase !== baseEntry) {
      sampleEntry = randomEntryFromBase(baseEntry);
      lastEntryBase = baseEntry;
    }
    const { percent, profit } = rerollIfNeeded(false);
    drawCardTo(ctx, percent, profit, { recordHitboxes: true, entryOverride: sampleEntry });
  }

  function renderGallery() {
    // (생성 결과 UI 제거됨)
  }

  function renderAll() {
    renderPreview();
  }

  function setSide(value, { closeModal = true } = {}) {
    if (els.side) els.side.value = value;
    if (sideUi.longBtn) sideUi.longBtn.classList.toggle("active", value === "LONG");
    if (sideUi.shortBtn) sideUi.shortBtn.classList.toggle("active", value === "SHORT");
    if (closeModal && sideUi.modal) sideUi.modal.classList.add("hidden");
    renderAll();
  }

  function bindSideUi() {
    // 메인 버튼
    if (sideUi.longBtn) sideUi.longBtn.addEventListener("click", () => setSide("LONG", { closeModal: false }));
    if (sideUi.shortBtn) sideUi.shortBtn.addEventListener("click", () => setSide("SHORT", { closeModal: false }));

    // 모달 버튼(최초 진입 강제)
    if (sideUi.modalLong) sideUi.modalLong.addEventListener("click", () => setSide("LONG", { closeModal: true }));
    if (sideUi.modalShort) sideUi.modalShort.addEventListener("click", () => setSide("SHORT", { closeModal: true }));

    // 최초 로딩 시 모달 띄우기 (값이 없으면)
    if (sideUi.modal) {
      const v = String(els.side?.value || "").trim();
      if (!v) sideUi.modal.classList.remove("hidden");
      else sideUi.modal.classList.add("hidden");
    }
  }

  async function ensureFontsReady() {
    // Roboto 로딩 대기(가능한 경우)
    if (document.fonts && document.fonts.ready) {
      try {
        await document.fonts.ready;
      } catch {
        // ignore
      }
    }
  }

  function downloadPng() {
    try {
      const url = canvas.toDataURL("image/png");
      const a = document.createElement("a");
      a.href = url;
      a.download = "screenshot.png";
      a.click();
    } catch (e) {
      alert(
        "PNG 내보내기에 실패했습니다. (파일을 더블클릭으로 열면 보안 정책 때문에 실패할 수 있어요)\n\n" +
          "권장: python -m http.server 로 서버 실행 후 http://localhost:8000/index.html 로 접속해서 다시 시도해주세요."
      );
    }
  }

  function dataUrlToUint8Array(dataUrl) {
    const [meta, b64] = dataUrl.split(",");
    const bin = atob(b64);
    const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    return arr;
  }

  async function downloadZip() {
    if (!window.JSZip) {
      alert("JSZip 로딩에 실패했습니다. 인터넷 연결을 확인해주세요.");
      return;
    }

    const n = getCount();
    const prefix = (els.prefix.value || "screenshot").trim() || "screenshot";

    const zip = new JSZip();

    // 오프스크린 캔버스에서 렌더링
    const off = document.createElement("canvas");
    off.width = CANVAS_W;
    off.height = CANVAS_H;
    const offCtx = off.getContext("2d");

    function renderTo(targetCtx, percentValue, profitValue, entryOverride) {
      drawCardTo(targetCtx, percentValue, profitValue, { recordHitboxes: false, entryOverride });
    }

    // 폰트 로딩 대기(가능한 경우)
    await ensureFontsReady();

    for (let i = 1; i <= n; i++) {
      const { percent: pv, profit: fv } = randomPercentProfit();
      const entryV = randomEntryFromBase((els.entry?.value || "").trim());
      renderTo(offCtx, pv, fv, entryV);
      const dataUrl = off.toDataURL("image/png");
      const bytes = dataUrlToUint8Array(dataUrl);
      const name = `${prefix}_${String(i).padStart(4, "0")}.png`;
      zip.file(name, bytes);
    }

    const blob = await zip.generateAsync({ type: "blob" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${prefix}.zip`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }

  function bind() {
    const reRender = () => renderAll();
    Object.values(els).forEach((el) => {
      if (!el) return;
      if (el.tagName === "INPUT" || el.tagName === "SELECT") {
        el.addEventListener("input", reRender);
        el.addEventListener("change", reRender);
      }
    });

    if (els.generate)
      els.generate.addEventListener("click", () => {
        const n = getCount();
        const baseEntry = (els.entry?.value || "").trim();
        generatedItems = Array.from({ length: n }, () => {
          const { percent, profit } = randomPercentProfit();
          return { percent, profit, entry: randomEntryFromBase(baseEntry) };
        });
        previewIndex = generatedItems.length > 0 ? 0 : -1;
        renderAll();
      });
    if (els.downloadZip) els.downloadZip.addEventListener("click", downloadZip);
    if (els.reroll)
      els.reroll.addEventListener("click", () => {
        if (generatedItems.length > 0) {
          const baseEntry = (els.entry?.value || "").trim();
          generatedItems = generatedItems.map(() => {
            const { percent, profit } = randomPercentProfit();
            return { percent, profit, entry: randomEntryFromBase(baseEntry) };
          });
          previewIndex = generatedItems.length > 0 ? Math.min(Math.max(previewIndex, 0), generatedItems.length - 1) : -1;
          renderAll();
        } else {
          rerollIfNeeded(true);
          // 미리보기(단건)도 생성할 때마다 진입가 랜덤 변경
          const baseEntry = (els.entry?.value || "").trim();
          sampleEntry = randomEntryFromBase(baseEntry);
          lastEntryBase = baseEntry;
          renderAll();
        }
      });
    if (els.reset)
      els.reset.addEventListener("click", () => {
      if (els.percentMin) els.percentMin.value = DEFAULTS.percentMin;
      if (els.percentMax) els.percentMax.value = DEFAULTS.percentMax;
      if (els.profitMin) els.profitMin.value = DEFAULTS.profitMin;
      if (els.profitMax) els.profitMax.value = DEFAULTS.profitMax;
      els.symbol.value = DEFAULTS.symbol;
      els.side.value = DEFAULTS.side;
      els.leverage.value = DEFAULTS.leverage;
      els.entry.value = DEFAULTS.entry;
      els.bgZoom.value = String(DEFAULTS.bgZoom.toFixed(2));
      bgShiftX = 0;
      bgShiftY = 28;
      els.count.value = String(DEFAULTS.count);
      els.prefix.value = DEFAULTS.prefix;
      if (els.padX) els.padX.value = "18";
      if (els.topPercentY) els.topPercentY.value = "44";
      if (els.topProfitY) els.topProfitY.value = "76";
      if (els.percentSignDy) els.percentSignDy.value = "3";
      if (els.sectionStartY) els.sectionStartY.value = "118";
      if (els.rowGap) els.rowGap.value = "58";
      if (els.labelToValueGap) els.labelToValueGap.value = "24";
      if (els.sideDx) els.sideDx.value = "6";
      if (els.sideDy) els.sideDy.value = "0";
      if (els.r1LabelDy) els.r1LabelDy.value = "0";
      if (els.r1ValueDy) els.r1ValueDy.value = "0";
      if (els.r2LabelDy) els.r2LabelDy.value = "0";
      if (els.r2ValueDy) els.r2ValueDy.value = "0";
      if (els.r3LabelDy) els.r3LabelDy.value = "0";
      if (els.r3ValueDy) els.r3ValueDy.value = "0";
      if (els.r4LabelDy) els.r4LabelDy.value = "0";
      if (els.r4ValueDy) els.r4ValueDy.value = "0";
      // 생성 결과/선택/개별 조정 초기화
      generatedItems = [];
      previewIndex = -1;
      selectedTextId = null;
      Object.keys(textAdjust).forEach((k) => delete textAdjust[k]);
      Object.keys(baseAnchor).forEach((k) => delete baseAnchor[k]);
      sampleEntry = null;
      lastEntryBase = null;
      rerollIfNeeded(true);
      renderAll();
      });

    const bump = (key, delta) => {
      if (key === "x") bgShiftX = Math.round(bgShiftX) + delta;
      else bgShiftY = Math.round(bgShiftY) + delta;
      renderAll();
    };
    if (els.shiftUp) els.shiftUp.addEventListener("click", () => bump("y", -1));
    if (els.shiftDown) els.shiftDown.addEventListener("click", () => bump("y", +1));
    if (els.shiftLeft) els.shiftLeft.addEventListener("click", () => bump("x", -1));
    if (els.shiftRight) els.shiftRight.addEventListener("click", () => bump("x", +1));
    if (els.shiftReset)
      els.shiftReset.addEventListener("click", () => {
        bgShiftX = 0;
        bgShiftY = 28;
        renderAll();
      });

    // 텍스트 항목별 1px 이동 버튼
    document.querySelectorAll(".text-move-pad").forEach((pad) => {
      const id = pad.getAttribute("data-text-id");
      if (!id) return;

      const move = (dx, dy) => {
        selectedTextId = id;
        const adj = getOrInitAdjust(id);
        adj.dx += dx;
        adj.dy += dy;
        renderAll();
      };

      pad.querySelectorAll(".text-move-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
          const dir = btn.getAttribute("data-dir");
          if (dir === "up") return move(0, -1);
          if (dir === "down") return move(0, +1);
          if (dir === "left") return move(-1, 0);
          if (dir === "right") return move(+1, 0);
        });
      });

      const resetBtn = pad.querySelector(".text-move-reset");
      if (resetBtn)
        resetBtn.addEventListener("click", () => {
          selectedTextId = id;
          delete textAdjust[id];
          renderAll();
        });

      // 글씨 크기 +/- (항목별)
      pad.querySelectorAll(".text-size-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
          selectedTextId = id;
          const dir = btn.getAttribute("data-size");
          const delta = dir === "down" ? -1 : +1;
          const baseSizes = getBaseSizes();
          const baseFont = fontForTextId(id, baseSizes);
          const baseSize = parseFontSizePx(baseFont, 16);
          const adj = getOrInitAdjust(id);
          const cur = adj.size == null ? baseSize : adj.size;
          adj.size = Math.max(1, Math.round(cur + delta));
          renderAll();
        });
      });

      // 볼드 토글 (항목별)
      const boldBtn = pad.querySelector(".text-bold-btn");
      if (boldBtn) {
        const sync = () => {
          const adj = getOrInitAdjust(id);
          boldBtn.classList.toggle("active", adj.bold === true);
        };
        sync();
        boldBtn.addEventListener("click", () => {
          selectedTextId = id;
          const adj = getOrInitAdjust(id);
          adj.bold = adj.bold === true ? false : true;
          sync();
          renderAll();
        });
      }
    });

    // 캔버스에서 텍스트 클릭 선택
    canvas.addEventListener("click", (ev) => {
      const rect = canvas.getBoundingClientRect();
      const x = ((ev.clientX - rect.left) / rect.width) * CANVAS_W;
      const y = ((ev.clientY - rect.top) / rect.height) * CANVAS_H;
      const hit = lastHitboxes.find((b) => x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h);
      selectedTextId = hit ? hit.id : null;
      renderPreview();
    });
  }

  async function init() {
    bind();
    bindSideUi();
    await ensureFontsReady();

    if (bgImg.complete) {
      rerollIfNeeded(true);
      renderAll();
    } else {
      bgImg.addEventListener(
        "load",
        () => {
          rerollIfNeeded(true);
          renderAll();
        },
        { once: true }
      );
      bgImg.addEventListener(
        "error",
        () => {
          ctx.clearRect(0, 0, CANVAS_W, CANVAS_H);
          ctx.fillStyle = "#000";
          ctx.fillRect(0, 0, CANVAS_W, CANVAS_H);
          ctx.fillStyle = "#fff";
          ctx.font = "14px Roboto, Arial";
          ctx.fillText("배경 이미지 로드 실패: ./calcu/bg.png", 12, 24);
        },
        { once: true }
      );
    }
  }

  init();
})();
