// 注目点と切り抜き枠の計算。DOM を触らない。部品は `focal-crop.ts`。
//
// 座標はすべて元の画像に対する割合（0〜1）。px は表示の時にだけ換算する。
//
// WhyNot: px で持たない。同じ画像を一覧のカード・OGP・正方形と違う大きさで出すので、
// px で持つと出す先ごとに換算が要り、画像を差し替えた時に値が意味を失う。

export type Point = { x: number; y: number };
export type Crop = { left: number; top: number; width: number; height: number };
export type Size = { width: number; height: number };
export type Ratio = "free" | "16:9" | "4:3" | "1:1" | "3:4";
export type Handle = "nw" | "n" | "ne" | "e" | "se" | "s" | "sw" | "w";

export const CENTER: Point = { x: 0.5, y: 0.5 };
export const FULL: Crop = { left: 0, top: 0, width: 1, height: 1 };

/** 枠の最小の一辺（割合）。これより小さくは縮めない。 */
export const MIN_SIDE = 0.05;

export function clamp01(n: number): number {
  return n < 0 ? 0 : n > 1 ? 1 : n;
}

/** 属性の文字列を 0〜1 の数に。読めなければ fallback。 */
export function fraction(raw: string | null, fallback: number): number {
  if (raw === null || raw.trim() === "") return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? clamp01(n) : fallback;
}

export function parseRatio(raw: string | null): Ratio {
  return raw === "16:9" || raw === "4:3" || raw === "1:1" || raw === "3:4" ? raw : "free";
}

/** 比率の値（幅 ÷ 高さ）。`free` は null。 */
export function ratioValue(ratio: Ratio): number | null {
  switch (ratio) {
    case "16:9":
      return 16 / 9;
    case "4:3":
      return 4 / 3;
    case "1:1":
      return 1;
    case "3:4":
      return 3 / 4;
    default:
      return null;
  }
}

/** 枠を画像の中に押し込む。辺は MIN_SIDE 以上、`left + width <= 1`。 */
export function clampCrop(c: Crop): Crop {
  const width = Math.min(1, Math.max(MIN_SIDE, c.width));
  const height = Math.min(1, Math.max(MIN_SIDE, c.height));
  const left = Math.min(1 - width, Math.max(0, c.left));
  const top = Math.min(1 - height, Math.max(0, c.top));
  return { left, top, width, height };
}

/** 注目点を枠の中に押し込む。 */
export function pinFocal(p: Point, c: Crop): Point {
  return {
    x: Math.min(c.left + c.width, Math.max(c.left, p.x)),
    y: Math.min(c.top + c.height, Math.max(c.top, p.y)),
  };
}

/** 枠の中での注目点の位置（%）。プレビューの `object-position` に使う。 */
export function objectPosition(p: Point, c: Crop): Point {
  const pinned = pinFocal(p, c);
  return {
    x: c.width === 0 ? 50 : ((pinned.x - c.left) / c.width) * 100,
    y: c.height === 0 ? 50 : ((pinned.y - c.top) / c.height) * 100,
  };
}

/** 枠の px 換算。整数に丸める。 */
export function cropPx(c: Crop, img: Size): Size {
  return { width: Math.round(c.width * img.width), height: Math.round(c.height * img.height) };
}

/** 枠の実際の比率（幅 ÷ 高さ、px で）。 */
export function cropAspect(c: Crop, img: Size): number {
  const h = c.height * img.height;
  return h === 0 ? 0 : (c.width * img.width) / h;
}

/**
 * 枠を比率に合わせる。`anchor` は動かしたハンドル。反対側の辺を動かさず、
 * 動かした側の高さ（角と左右の辺なら高さ、上下の辺なら幅）を直す。
 * 画像からはみ出す分は、はみ出さない大きさまで縮める。
 */
export function fitRatio(c: Crop, ratio: number | null, img: Size, anchor: Handle): Crop {
  if (ratio === null) return clampCrop(c);
  const a = img.width / img.height;
  // 割合の座標での「幅 ÷ 高さ」。ratio は px の比率なので画像の縦横比で割る。
  const k = ratio / a;
  let { left, top, width, height } = c;
  const fixHeight = anchor === "n" || anchor === "s";
  if (fixHeight) width = height * k;
  else height = width / k;
  // はみ出す時は縦横を同じ割合で縮める（比率は保つ）。
  const maxW = Math.min(1, anchor.includes("w") ? left + c.width : 1 - left);
  const maxH = Math.min(1, anchor.includes("n") ? top + c.height : 1 - top);
  const scale = Math.min(1, maxW / width, maxH / height);
  width *= scale;
  height *= scale;
  if (width < MIN_SIDE || height < MIN_SIDE) {
    const grow = Math.max(MIN_SIDE / width, MIN_SIDE / height);
    width *= grow;
    height *= grow;
  }
  // 掴んだ側が左・上なら、反対側の辺（右・下）を動かさない。
  if (anchor.includes("w")) left = c.left + c.width - width;
  if (anchor.includes("n")) top = c.top + c.height - height;
  return clampCrop({ left, top, width, height });
}

/** 枠を全体にした時の比率付きの初期枠（中央）。「元に戻す」で使う。 */
export function centeredCrop(ratio: Ratio, img: Size): Crop {
  const r = ratioValue(ratio);
  if (r === null) return FULL;
  const k = r / (img.width / img.height);
  const width = Math.min(1, k);
  const height = Math.min(1, 1 / k);
  return { left: (1 - width) / 2, top: (1 - height) / 2, width, height };
}

/**
 * ハンドルを (dx, dy) だけ動かした枠。free なら辺ごとに、比率固定なら `fitRatio` で直す。
 * 枠の中を掴んだ移動は `moveCrop`。
 */
export function resizeCrop(c: Crop, anchor: Handle, dx: number, dy: number, ratio: number | null, img: Size): Crop {
  let { left, top, width, height } = c;
  if (anchor.includes("w")) {
    const right = left + width;
    left = Math.min(right - MIN_SIDE, Math.max(0, left + dx));
    width = right - left;
  }
  if (anchor.includes("e")) width = Math.min(1 - left, Math.max(MIN_SIDE, width + dx));
  if (anchor.includes("n")) {
    const bottom = top + height;
    top = Math.min(bottom - MIN_SIDE, Math.max(0, top + dy));
    height = bottom - top;
  }
  if (anchor.includes("s")) height = Math.min(1 - top, Math.max(MIN_SIDE, height + dy));
  return fitRatio({ left, top, width, height }, ratio, img, anchor);
}

/** 枠を大きさを変えずに動かす。端で止まる。 */
export function moveCrop(c: Crop, dx: number, dy: number): Crop {
  return {
    left: Math.min(1 - c.width, Math.max(0, c.left + dx)),
    top: Math.min(1 - c.height, Math.max(0, c.top + dy)),
    width: c.width,
    height: c.height,
  };
}

/** 矢印キーの 1 回の移動量。Shift で 5%。 */
export function keyStep(shift: boolean): number {
  return shift ? 0.05 : 0.01;
}

export type Window = { size: Point; position: Point };

/**
 * プレビュー（比率 `box` の箱）に出す画像の窓。`background-size` と `background-position` の %。
 *
 * 枠を箱に cover で当て、注目点が中央に来るように動かし、枠の外は見せない。
 * `position` は CSS の background-position の意味（箱と画像の差に対する割合）。
 */
export function previewWindow(c: Crop, p: Point, img: Size, box: number): Window {
  const a = img.width / img.height;
  const wide = cropAspect(c, img) >= box;
  // 箱に見える範囲（画像に対する割合）。枠の長い方の辺は切り詰める。
  const vw = wide ? (c.height * box) / a : c.width;
  const vh = wide ? c.height : (c.width * a) / box;
  const f = pinFocal(p, c);
  const winLeft = Math.min(c.left + c.width - vw, Math.max(c.left, f.x - vw / 2));
  const winTop = Math.min(c.top + c.height - vh, Math.max(c.top, f.y - vh / 2));
  const pos = (start: number, visible: number) => (visible >= 1 ? 0 : (start / (1 - visible)) * 100);
  return {
    size: { x: 100 / vw, y: 100 / vh },
    position: { x: pos(winLeft, vw), y: pos(winTop, vh) },
  };
}

/** プレビューの箱の比率。表示の名前と一緒に持つ。 */
export const PREVIEWS: ReadonlyArray<{ id: string; label: string; box: number }> = [
  { id: "card", label: "一覧のカード 16:9", box: 16 / 9 },
  { id: "ogp", label: "OGP 1.91:1", box: 1.91 },
  { id: "square", label: "正方形 1:1", box: 1 },
];

/** OGP に足りるか。既定は 1200 × 630。 */
export function fitsOgp(c: Crop, img: Size, min: Size): boolean {
  const px = cropPx(c, img);
  return px.width >= min.width && px.height >= min.height;
}

/** 数値の表示。注目点は %、枠は px。 */
export function format(p: Point, c: Crop, img: Size): { focal: string; crop: string } {
  const px = cropPx(c, img);
  return {
    focal: `${Math.round(p.x * 100)}%, ${Math.round(p.y * 100)}%`,
    crop: `${px.width} × ${px.height}`,
  };
}
