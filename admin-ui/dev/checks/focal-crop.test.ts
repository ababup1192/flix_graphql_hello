// 注目点と切り抜き枠の部品（`web/focal-crop.ts`）。**掴んで離した時に 1 回だけ出るか**、
// 比率が保たれるか、矢印キーで動くか。計算の表は focal-crop-math.test.ts。
import { expect, test, afterEach, vi } from "vitest";
import "../../src/styles.css";
import "../../web/focal-crop";
import { CHANGED, type FocalCropDetail } from "../../web/focal-crop";

let part: HTMLElement | null = null;
afterEach(() => {
  part?.remove();
  part = null;
});

// 400×200 の偽の画像。外へ取りに行かない。
const IMG =
  "data:image/svg+xml;utf8," +
  encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><rect width="400" height="200" fill="#3b6ea5"/></svg>');

async function mountPart(attrs: Record<string, string>): Promise<{ el: HTMLElement; events: FocalCropDetail[] }> {
  const el = document.createElement("focal-crop");
  el.setAttribute("src", IMG);
  el.setAttribute("width", "400");
  el.setAttribute("height", "200");
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  const events: FocalCropDetail[] = [];
  el.addEventListener(CHANGED, (e) => events.push((e as CustomEvent<FocalCropDetail>).detail));
  document.body.appendChild(el);
  part = el;
  // 舞台が画像の大きさになるまで待つ（ドラッグの差を舞台の幅で割る）。
  await vi.waitFor(() => {
    const stage = el.querySelector<HTMLElement>(".fc-stage")!;
    if (stage.clientWidth < 100) throw new Error("まだ画像が出ていない");
  });
  return { el, events };
}

function pointer(type: string, target: EventTarget, x: number, y: number) {
  target.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0, pointerId: 1 }));
}

function drag(target: HTMLElement, dx: number, dy: number) {
  pointer("pointerdown", target, 100, 100);
  for (let i = 1; i <= 5; i++) pointer("pointermove", window, 100 + (dx * i) / 5, 100 + (dy * i) / 5);
  pointer("pointerup", window, 100 + dx, 100 + dy);
}

test("注目点を掴んで動かし、離すとイベントは 1 回だけ", async () => {
  const { el, events } = await mountPart({});
  const stage = el.querySelector<HTMLElement>(".fc-stage")!;
  drag(el.querySelector<HTMLElement>(".fc-dot")!, stage.clientWidth / 4, 0);
  expect({ 回数: events.length, x: +events[0].focalPoint.x.toFixed(2), y: events[0].focalPoint.y }).toEqual({ 回数: 1, x: 0.75, y: 0.5 });
});

test("比率固定で右のハンドルを動かしても比率が保たれる", async () => {
  const { el, events } = await mountPart({ ratio: "1:1" });
  const stage = el.querySelector<HTMLElement>(".fc-stage")!;
  drag(el.querySelector<HTMLElement>(".fc-handle-w")!, stage.clientWidth / 8, 0);
  const c = events[0].crop;
  expect(+((c.width * 400) / (c.height * 200)).toFixed(3)).toBe(1);
});

test("矢印キーで注目点が 1% 動き、離すと 1 回出る", async () => {
  const { el, events } = await mountPart({});
  const dot = el.querySelector<HTMLElement>(".fc-dot")!;
  dot.focus();
  dot.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  dot.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, shiftKey: true }));
  dot.dispatchEvent(new KeyboardEvent("keyup", { key: "ArrowDown", bubbles: true }));
  expect({ 回数: events.length, x: +events[0].focalPoint.x.toFixed(2), y: +events[0].focalPoint.y.toFixed(2) }).toEqual({ 回数: 1, x: 0.51, y: 0.55 });
});
