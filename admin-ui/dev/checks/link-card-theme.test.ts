// リンクカードの面の色が、ライトとダークの両方で本文の面の側にあるか。
//
// ダークで `--tt-lc-thumb` / `--tt-lc-loading` / `--tt-lc-loading-edge` が白のままだった
// （トークンの付け忘れではなく、ダーク側に白い値が書いてあった）。読み込み中のカードと
// 画像の無いカードが、暗い本文の中で真っ白な板になる。
import { expect, test, afterEach } from "vitest";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => {
  harness?.destroy();
  delete document.documentElement.dataset.theme;
});

// "rgb(r, g, b)" と "#rrggbb" を 0..255 の 3 つに。
function channels(color: string): [number, number, number] {
  const hex = color.trim().match(/^#([\da-f]{6})$/i);
  if (hex) {
    const n = parseInt(hex[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  const found = color.match(/[\d.]+/g)!.map(Number);
  return [found[0], found[1], found[2]];
}

// WCAG の相対輝度。
function luminance(color: string): number {
  const [r, g, b] = channels(color).map((one) => {
    const v = one / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// 2 色のコントラスト比（1 なら同じ色）。
function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// カードが今のテーマで持っている値。node view が立った実物から読む。
function token(card: HTMLElement, name: string): string {
  return getComputedStyle(card).getPropertyValue(name).trim();
}

const ground = () => getComputedStyle(document.documentElement).getPropertyValue("--color-panel").trim();

async function card(theme: "light" | "dark"): Promise<HTMLElement> {
  document.documentElement.dataset.theme = theme;
  const h = (harness = await mount("parts"));
  return h.editor.querySelector<HTMLElement>(".tt-link-card")!;
}

for (const theme of ["light", "dark"] as const) {
  test(`${theme}: カードの面はどれも本文の面と同じ明るさの側にある`, async () => {
    const found = await card(theme);
    const diffs = ["--tt-lc-thumb", "--tt-lc-loading", "--tt-lc-loading-edge"].map((name) =>
      contrast(token(found, name), ground()),
    );
    // 面どうしの差。3 を超える物は「本文と反対の明るさの板」で、ダークの白がここに当たる
    expect(diffs.every((one) => one < 3)).toBe(true);
  });

  test(`${theme}: サムネイルの絵は地に沈まず、しかし文字ほど強くもない`, async () => {
    const found = await card(theme);
    const diff = contrast(token(found, "--tt-lc-thumb-icon"), token(found, "--tt-lc-thumb"));
    expect({ 見える: diff >= 1.2, 出過ぎない: diff <= 2.5 }).toEqual({ 見える: true, 出過ぎない: true });
  });
}
