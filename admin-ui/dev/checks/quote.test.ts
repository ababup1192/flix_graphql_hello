// 引用の出典（`web/quote-node.ts`）。
//
// 出典は引用の最後の子（quoteCite）で、キャプションと同じ 1 行の文字。
// 出典の行の置き所と、次のブロックに重ならない事は `quote-layout.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const inside = (h: Harness) => (h.editor as any).editor.state.selection.$from.parent.type.name;

// 出典の中にカーソルを置く。
function caretInCite(h: Harness) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "quoteCite") found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + 1);
}

// 出典の文字をぜんぶ選ぶ（帯は選んだ時だけ出る）。
function selectCite(h: Harness) {
  const view = (h.editor as any).editor;
  let range: { from: number; to: number } | null = null;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "quoteCite") range = { from: pos + 1, to: pos + node.nodeSize - 1 };
  });
  view.chain().focus().setTextSelection(range!).run();
  return range!;
}

// `> ` で引用を作る（出典はまだ空）。
async function freshQuote(): Promise<Harness> {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("> ひきよう");
  await settle();
  return h;
}

test("出典の行は 1 つだけで、印（ボタン）は出さない", async () => {
  const h = await freshQuote();
  expect(h.editor.querySelectorAll(".tt-quote-cite-row")).toHaveLength(1);
  expect(h.editor.querySelectorAll(".tt-quote-link")).toHaveLength(0);
});

test("空の出典には placeholder「出典を入力」が出る", async () => {
  const h = await freshQuote();
  expect(at(h, ".tt-quote-hint").textContent).toBe("出典を入力");
});

test("出典が空の間は quoteCite を作らない", async () => {
  const h = await freshQuote();
  expect(h.names()).not.toContain("quoteCite");
});

test("出典の行を押すと出典に焦点が入り、打った字が出典に入る", async () => {
  const h = await freshQuote();
  press(at(h, ".tt-quote-cite-row"));
  await vi.waitFor(() => expect(inside(h)).toBe("quoteCite"));
  await userEvent.keyboard("でんき");
  await vi.waitFor(() => expect(at(h, "cite.tt-quote-cite").textContent).toBe("でんき"));
});

test("出典は引用の最後の子（quoteCite）に入る", async () => {
  const h = (harness = await mount("quote"));
  const quote = ((h.doc() as any).content ?? []).find((node: any) => node.type === "blockquote");
  expect(quote.content.map((node: any) => node.type)).toEqual(["paragraph", "quoteCite"]);
});

test("出典の中では帯が 太字 / 打ち消し / リンク の 3 つで、「…」を出さない", async () => {
  const h = (harness = await mount("quote"));
  selectCite(h);
  await vi.waitFor(() => expect(document.querySelector(".tt-bubble-caption")).not.toBeNull());
  const tools = [...document.querySelectorAll(".tt-bubble-caption button")].map((one) => one.getAttribute("title"));
  expect(tools).toEqual(["太字", "打ち消し", "リンク"]);
  expect((document.querySelector(".tt-bubble .tt-more") as HTMLElement).hidden).toBe(true);
});

test("出典に太字とリンクが掛かる", async () => {
  const h = (harness = await mount("quote"));
  const range = selectCite(h);
  (h.editor as any).editor.chain().focus().setTextSelection(range).toggleBold().setLink({ href: "https://src.example/" }).run();
  await vi.waitFor(() => expect(h.editor.querySelectorAll("cite.tt-quote-cite strong")).toHaveLength(1));
  expect(h.editor.querySelectorAll("cite.tt-quote-cite a")).toHaveLength(1);
});

for (const key of ["ArrowUp", "ArrowDown"] as const) {
  test(`出典の ${key} で引用の外の行へ出る`, async () => {
    const h = (harness = await mount("quote"));
    caretInCite(h);
    await settle();
    expect(inside(h)).toBe("quoteCite");
    await userEvent.keyboard(`{${key}}`);
    await vi.waitFor(() => expect(inside(h)).not.toBe("quoteCite"));
  });
}

test("旧い attrs.cite / citeUrl は出典（quoteCite）に写る", async () => {
  const h = (harness = await mount({
    type: "doc",
    content: [
      {
        type: "blockquote",
        attrs: { cite: "むかしのしゅってん", citeUrl: "https://src.example/" },
        content: [{ type: "paragraph", content: [{ type: "text", text: "ふるいいんよう" }] }],
      },
    ],
  }));
  await vi.waitFor(() => expect(at(h, "cite.tt-quote-cite a").textContent).toBe("むかしのしゅってん"));
  expect(JSON.stringify(h.doc())).not.toContain('"cite":"むかしのしゅってん"');
});
