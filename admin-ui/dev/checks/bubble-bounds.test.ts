// 文字を選んだ時に出る帯（`.tt-bubble`）が、エディタの枠から出ていない事。
//
// **出ると管理画面の上の帯（タイトル・保存済みの表示）に重なって隠す。**
// 上の帯は Elm 側の殻で開発用の土台には無いので、同値で、直し方そのものでもある形
// 「帯の矩形がエディタの枠に収まっている」を見る。これを満たせば上の帯にも出て行けない。
//
// WhyNot: 画面（viewport）に収まっているだけで良い事にしない。エディタの枠を越えた帯は、
// 画面には収まっていても上下のフィールドに重なる（浮く面で実際に重なった。`ui.ts` の `bounds`）。
import { expect, test, afterEach, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(async () => {
  harness?.destroy();
  window.scrollTo(0, 0);
  await page.viewport(1440, 900);
});

const box = (el: Element) => el.getBoundingClientRect();
const frame = () => new Promise((done) => window.requestAnimationFrame(() => window.requestAnimationFrame(done)));

// 帯が出て、置き所が決まるまで待つ。
//
// **選択を作るだけでは足りない。** 帯は選んでから 80ms 後に出て（`updateDelay`）、
// Floating UI が非同期に測る。測る前の帯は本文の下に素で置かれていて、そこを測ると
// 「枠から出ている」と読めてしまう（実際にそう読めた）。
async function bubbleOf(h: Harness): Promise<DOMRect> {
  await vi.waitFor(() => expect(h.editor.querySelector(".tt-bubble")).not.toBeNull());
  await frame();
  await frame();
  return box(h.editor.querySelector<HTMLElement>(".tt-bubble")!);
}

// n 番目の段落に文字を打って、その 3 文字を選ぶ。
//
// WhyNot: `setTextSelection` だけで選ばない。本文が変わらないと BubbleMenu が
// 置き所を測り直さず、帯が素の場所に残る（実際に残った）。
async function pickInParagraph(h: Harness, index: number) {
  const view = (h.editor as any).editor;
  let at = -1;
  let seen = 0;
  view.state.doc.forEach((node: any, pos: number) => {
    if (node.type.name === "paragraph" && node.content.size > 3) {
      if (seen === index) at = pos;
      seen += 1;
    }
  });
  view.commands.focus();
  view.commands.setTextSelection(at + 1);
  await settle();
  await userEvent.keyboard("たいじ");
  h.selectBack(3);
  await settle();
}

// キャプションの中の 3 文字を選ぶ。**キャプションの帯だけは選んだ所の真上に出る**
// （`tiptap-editor.ts` の `getReferencedVirtualElement`）ので、上へ出て行く道がある。
async function pickInCaption(h: Harness) {
  h.caretInCaption();
  await settle();
  await userEvent.keyboard("せつめい");
  h.selectBack(4);
  await settle();
}

// [名前, 初期状態, 選ぶ]
const SPOTS: Array<[string, string, (h: Harness) => Promise<void>]> = [
  ["本文の上端に近い所", "long", (h) => pickInParagraph(h, 0)],
  ["本文の下端に近い所", "long", (h) => pickInParagraph(h, 19)],
  ["一番上の画像のキャプション", "image", pickInCaption],
  ["一番上の引用の出典", "quote", (h) => pickInCite(h)],
];

async function pickInCite(h: Harness) {
  const view = (h.editor as any).editor;
  let at = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "quoteCite" && at < 0) at = pos + 1;
  });
  view.commands.focus();
  view.commands.setTextSelection({ from: at, to: at + 3 });
  await settle();
}

for (const [name, fixture, go] of SPOTS) {
  test(`${name}を選んでも、帯がエディタの枠より上に出ない`, async () => {
    const h = (harness = await mount(fixture));
    await go(h);
    const bubble = await bubbleOf(h);
    expect(Math.round(bubble.top - box(h.editor).top)).toBeGreaterThanOrEqual(0);
  });

  test(`${name}を選んでも、帯がエディタの枠より下に出ない`, async () => {
    const h = (harness = await mount(fixture));
    await go(h);
    const bubble = await bubbleOf(h);
    expect(Math.round(box(h.editor).bottom - bubble.bottom)).toBeGreaterThanOrEqual(0);
  });
}

// 窓が低くて選んだ行の下に帯が入らない時も、上へ逃げてエディタの枠を越えない。
test("低い窓で上端の行を選んでも、帯がエディタの枠より上に出ない", async () => {
  await page.viewport(1440, 200);
  const h = (harness = await mount("long"));
  await pickInParagraph(h, 0);
  const bubble = await bubbleOf(h);
  expect(Math.round(bubble.top - box(h.editor).top)).toBeGreaterThanOrEqual(0);
});

// 管理画面の上の帯を土台にも置いて、その下に潜らない事を見る。
//
// **枠に収まっているだけでは足りない。** 上の 9 件は緑だが、Floating UI は画面
// （viewport）にクランプしていて、`dev/editor.html` ではエディタの上端が画面の上端と
// 同じなので差が出ない。実機で重なるのは、上の帯が画面の上端を占めているため。
// ここでは同じ高さの帯を `position: fixed` で置き、キャプションをその直下まで送って
// 帯が上へ逃げる道を作る。
//
// WhyNot: 帯の高さを当てずっぽうで決めない。56px は管理画面の `.app-bar` の高さ。
const APP_BAR = 56;

// **今は落ちる（実測: 帯の上端 23px、上の帯の下端 56px）。** `test.fails` は
// 「落ちる事」を検査にしている。直すとこの行が赤くなるので、その時に素の `test` へ戻す。
//
// WhyNot: skip にしない。skip は直っても何も言わないので、忘れたまま残る。
test.fails("上の帯がある時、キャプションの帯がその下に潜らない", async () => {
  const bar = document.createElement("div");
  bar.style.cssText = `position: fixed; top: 0; left: 0; right: 0; height: ${APP_BAR}px; z-index: 1;`;
  document.body.appendChild(bar);
  // 本文の下に余白を積んで、頁を送れるようにする。
  //
  // WhyNot: 余白なしで送ろうとしない。土台は本文がそのまま頁の高さなので
  // `scrollHeight === innerHeight` で 1px も動かず、キャプションが画面の上端に来ない
  // （実測: scrollY が 0 のまま、帯は 113 で上の帯の下に収まっていた）。
  const filler = document.createElement("div");
  filler.style.height = "2000px";
  try {
    const h = (harness = await mount("image-between"));
    document.body.appendChild(filler);
    const caption = h.editor.querySelector<HTMLElement>("figcaption");
    // キャプションを上の帯の直下へ送る（帯は真上に出るので、逃げ先が帯の裏になる）。
    if (caption) window.scrollTo(0, window.scrollY + box(caption).top - APP_BAR - 8);
    await pickInCaption(h);
    const bubble = await bubbleOf(h);
    expect(Math.round(bubble.top - APP_BAR)).toBeGreaterThanOrEqual(0);
  } finally {
    bar.remove();
    filler.remove();
  }
});
