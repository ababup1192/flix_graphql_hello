// 注目点と切り抜き枠の計算（`web/focal-crop-math.ts`）。**DOM 無しの表**。
import { expect, test } from "vitest";
import {
  centeredCrop,
  clampCrop,
  cropPx,
  fitRatio,
  fitsOgp,
  format,
  fraction,
  keyStep,
  moveCrop,
  objectPosition,
  parseRatio,
  pinFocal,
  previewWindow,
  resizeCrop,
  type Crop,
  type Point,
} from "../../web/focal-crop-math";

const IMG = { width: 2000, height: 1000 };
const FULL: Crop = { left: 0, top: 0, width: 1, height: 1 };

const near = (c: Crop) => ({
  left: +c.left.toFixed(4),
  top: +c.top.toFixed(4),
  width: +c.width.toFixed(4),
  height: +c.height.toFixed(4),
});

test.each<[string, string | null, number, number]>([
  ["無ければ既定", null, 0.5, 0.5],
  ["空も既定", "  ", 0.5, 0.5],
  ["読めなければ既定", "abc", 0.5, 0.5],
  ["0〜1 に丸める（上）", "1.7", 0.5, 1],
  ["0〜1 に丸める（下）", "-0.2", 0.5, 0],
  ["そのまま", "0.25", 0.5, 0.25],
])("属性の数: %s", (_name, raw, fallback, want) => {
  expect(fraction(raw, fallback)).toBe(want);
});

test.each<[string | null, string]>([
  ["16:9", "16:9"],
  ["1:1", "1:1"],
  ["2:1", "free"],
  [null, "free"],
])("比率の属性 %s は %s", (raw, want) => {
  expect(parseRatio(raw)).toBe(want);
});

test.each<[string, Crop, Crop]>([
  ["右にはみ出したら左を戻す", { left: 0.8, top: 0, width: 0.5, height: 1 }, { left: 0.5, top: 0, width: 0.5, height: 1 }],
  ["負は 0", { left: -0.1, top: -0.1, width: 0.5, height: 0.5 }, { left: 0, top: 0, width: 0.5, height: 0.5 }],
  ["1 より大きい辺は 1", { left: 0, top: 0, width: 2, height: 3 }, FULL],
  ["小さすぎる辺は最小に", { left: 0.5, top: 0.5, width: 0.001, height: 0.001 }, { left: 0.5, top: 0.5, width: 0.05, height: 0.05 }],
])("枠の丸め: %s", (_name, input, want) => {
  expect(near(clampCrop(input))).toEqual(want);
});

const BOX: Crop = { left: 0.2, top: 0.2, width: 0.4, height: 0.4 };
test.each<[string, Point, Point]>([
  ["中なら動かない", { x: 0.3, y: 0.3 }, { x: 0.3, y: 0.3 }],
  ["左に外れたら左辺", { x: 0.1, y: 0.3 }, { x: 0.2, y: 0.3 }],
  ["右下に外れたら右下の角", { x: 0.9, y: 0.9 }, { x: 0.6, y: 0.6 }],
])("注目点を枠に押し込む: %s", (_name, p, want) => {
  const got = pinFocal(p, BOX);
  expect({ x: +got.x.toFixed(4), y: +got.y.toFixed(4) }).toEqual(want);
});

test.each<[string, Point, Crop, Point]>([
  ["全体の中央は 50%", { x: 0.5, y: 0.5 }, FULL, { x: 50, y: 50 }],
  ["枠の左上は 0%", { x: 0.2, y: 0.2 }, BOX, { x: 0, y: 0 }],
  ["枠の中の 3/4", { x: 0.5, y: 0.5 }, BOX, { x: 75, y: 75 }],
  ["枠の外は端に寄せる", { x: 0.9, y: 0.1 }, BOX, { x: 100, y: 0 }],
])("object-position: %s", (_name, p, c, want) => {
  const got = objectPosition(p, c);
  expect({ x: +got.x.toFixed(4), y: +got.y.toFixed(4) }).toEqual(want);
});

test.each<[Crop, { width: number; height: number }]>([
  [FULL, { width: 2000, height: 1000 }],
  [{ left: 0, top: 0, width: 0.6, height: 0.63 }, { width: 1200, height: 630 }],
  [{ left: 0, top: 0, width: 0.33333, height: 0.5 }, { width: 667, height: 500 }],
])("px 換算 %j", (c, want) => {
  expect(cropPx(c, IMG)).toEqual(want);
});

// 比率固定。2000×1000 の画像で 1:1 なら、割合の幅は高さの半分。
test.each<[string, Crop, number | null, string, Crop]>([
  ["free は丸めるだけ", { left: 0.1, top: 0.1, width: 0.5, height: 0.5 }, null, "se", { left: 0.1, top: 0.1, width: 0.5, height: 0.5 }],
  ["右下を掴んだら幅から高さを決める", { left: 0, top: 0, width: 0.25, height: 0.9 }, 1, "se", { left: 0, top: 0, width: 0.25, height: 0.5 }],
  ["下の辺を掴んだら高さから幅を決める", { left: 0, top: 0, width: 0.9, height: 0.4 }, 1, "s", { left: 0, top: 0, width: 0.2, height: 0.4 }],
  ["左上を掴んだら右下の角は動かない", { left: 0.3, top: 0.3, width: 0.2, height: 0.2 }, 1, "nw", { left: 0.3, top: 0.1, width: 0.2, height: 0.4 }],
  ["はみ出すなら比率を保って縮める", { left: 0.5, top: 0.5, width: 0.5, height: 0.5 }, 16 / 9, "se", { left: 0.5, top: 0.5, width: 0.4444, height: 0.5 }],
  ["全体を 16:9 に", FULL, 16 / 9, "se", { left: 0, top: 0, width: 0.8889, height: 1 }],
])("比率固定: %s", (_name, c, ratio, anchor, want) => {
  expect(near(fitRatio(c, ratio, IMG, anchor as "se"))).toEqual(want);
});

test.each<[string, string, Crop]>([
  ["free", "free", FULL],
  ["1:1 は中央の正方形", "1:1", { left: 0.25, top: 0, width: 0.5, height: 1 }],
  ["4:3", "4:3", { left: 0.1667, top: 0, width: 0.6667, height: 1 }],
])("元に戻した枠: %s", (_name, ratio, want) => {
  expect(near(centeredCrop(ratio as "1:1", IMG))).toEqual(want);
});

const HALF: Crop = { left: 0.25, top: 0.25, width: 0.5, height: 0.5 };
test.each<[string, string, number, number, Crop]>([
  ["右辺を右へ", "e", 0.1, 0, { left: 0.25, top: 0.25, width: 0.6, height: 0.5 }],
  ["左辺を左へ（右辺は動かない）", "w", -0.1, 0, { left: 0.15, top: 0.25, width: 0.6, height: 0.5 }],
  ["上辺を下へ（下辺は動かない）", "n", 0, 0.1, { left: 0.25, top: 0.35, width: 0.5, height: 0.4 }],
  ["左上の角", "nw", 0.05, 0.05, { left: 0.3, top: 0.3, width: 0.45, height: 0.45 }],
  ["右辺を画像の外へは出ない", "e", 0.9, 0, { left: 0.25, top: 0.25, width: 0.75, height: 0.5 }],
  ["左辺は右辺を越えない", "w", 0.9, 0, { left: 0.7, top: 0.25, width: 0.05, height: 0.5 }],
])("free の枠の大きさ: %s", (_name, anchor, dx, dy, want) => {
  expect(near(resizeCrop(HALF, anchor as "e", dx, dy, null, IMG))).toEqual(want);
});

test("比率固定で右辺を動かしても比率が保たれる", () => {
  const got = resizeCrop({ left: 0, top: 0, width: 0.5, height: 1 }, "e", 0.2, 0, 1, IMG);
  expect(near(got)).toEqual({ left: 0, top: 0, width: 0.5, height: 1 });
});

test.each<[string, number, number, Crop]>([
  ["中を動かす", 0.1, -0.1, { left: 0.35, top: 0.15, width: 0.5, height: 0.5 }],
  ["端で止まる", 0.9, 0.9, { left: 0.5, top: 0.5, width: 0.5, height: 0.5 }],
])("枠の移動: %s", (_name, dx, dy, want) => {
  expect(near(moveCrop(HALF, dx, dy))).toEqual(want);
});

test.each<[boolean, number]>([
  [false, 0.01],
  [true, 0.05],
])("矢印キー（Shift=%s）は %d", (shift, want) => {
  expect(keyStep(shift)).toBe(want);
});

test.each<[string, Crop, Point, number, { size: Point; position: Point }]>([
  ["枠が全体で箱が画像と同じ比率なら等倍", FULL, { x: 0.5, y: 0.5 }, 2, { size: { x: 100, y: 100 }, position: { x: 0, y: 0 } }],
  ["正方形の箱: 横に 2 倍、注目点の中央が中央に", FULL, { x: 0.5, y: 0.5 }, 1, { size: { x: 200, y: 100 }, position: { x: 50, y: 0 } }],
  ["正方形の箱: 注目点が左端なら左端", FULL, { x: 0, y: 0.5 }, 1, { size: { x: 200, y: 100 }, position: { x: 0, y: 0 } }],
  ["枠の外は見せない（右端で止まる）", { left: 0, top: 0, width: 0.5, height: 1 }, { x: 0.5, y: 0.5 }, 1, { size: { x: 200, y: 100 }, position: { x: 0, y: 0 } }],
  ["枠が箱より縦長なら幅を合わせる", { left: 0.25, top: 0, width: 0.25, height: 1 }, { x: 0.375, y: 0.5 }, 1, { size: { x: 400, y: 200 }, position: { x: 33.3333, y: 50 } }],
])("プレビューの窓: %s", (_name, c, p, box, want) => {
  const got = previewWindow(c, p, IMG, box);
  const round = (q: Point) => ({ x: +q.x.toFixed(4), y: +q.y.toFixed(4) });
  expect({ size: round(got.size), position: round(got.position) }).toEqual(want);
});

test.each<[string, Crop, boolean]>([
  ["全体は足りる", FULL, true],
  ["ちょうど 1200×630 は足りる", { left: 0, top: 0, width: 0.6, height: 0.63 }, true],
  ["幅が足りない", { left: 0, top: 0, width: 0.5, height: 1 }, false],
])("OGP の大きさ: %s", (_name, c, want) => {
  expect(fitsOgp(c, IMG, { width: 1200, height: 630 })).toBe(want);
});

test("数値の表示", () => {
  expect(format({ x: 0.333, y: 0.5 }, { left: 0, top: 0, width: 0.6, height: 0.63 }, IMG)).toEqual({
    focal: "33%, 50%",
    crop: "1200 × 630",
  });
});
