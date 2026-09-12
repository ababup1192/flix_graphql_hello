// ブロックの中の全選択は、そのブロックの中だけに閉じる（`selectAllInBlock`）。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const onMac = navigator.platform.toUpperCase().includes("MAC");
const selectAll = onMac ? "{Meta>}a{/Meta}" : "{Control>}a{/Control}";

// n 番目のブロックの中にカーソルを置く。
function caretIn(h: Harness, name: string, offset = 1) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && found < 0) found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + offset);
}

test("コードブロックの中の全選択はそのブロックだけ", async () => {
  const h = (harness = await mount("blocks"));
  caretIn(h, "codeBlock");
  await settle();
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  const { from, to, $from } = view.state.selection;
  expect({
    node: $from.parent.type.name,
    whole: from === $from.start() && to === $from.end(),
    outside: view.state.doc.textBetween(from, to, " ").includes("外の段落"),
  }).toEqual({ node: "codeBlock", whole: true, outside: false });
});

test("数式の TeX の欄の全選択は欄の中だけ", async () => {
  const h = (harness = await mount("blocks"));
  await userEvent.click(at(h, ".tt-mathblock-out"));
  await vi.waitFor(() => expect(document.activeElement).toBe(at(h, ".tt-mathblock-src")));
  const view = (h.editor as any).editor;
  const before = view.state.selection.to - view.state.selection.from;
  await userEvent.keyboard(selectAll);
  await settle();
  const box = at<HTMLTextAreaElement>(h, ".tt-mathblock-src");
  expect({
    picked: box.value.slice(box.selectionStart ?? 0, box.selectionEnd ?? 0),
    span: view.state.selection.to - view.state.selection.from,
  }).toEqual({ picked: "E = mc^2", span: before });
});

test("ファイル名の欄の全選択は欄の中だけ", async () => {
  const h = (harness = await mount("blocks"));
  const box = at<HTMLInputElement>(h, ".tt-code-file");
  await userEvent.click(box);
  await userEvent.fill(box, "main.ts");
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  expect({
    picked: box.value.slice(box.selectionStart ?? 0, box.selectionEnd ?? 0),
    span: view.state.selection.to - view.state.selection.from,
  }).toEqual({ picked: "main.ts", span: 0 });
});

test.skipIf(!onMac)("macOS の Control+A は全選択ではなく行頭へ", async () => {
  const h = (harness = await mount("blocks"));
  caretIn(h, "codeBlock", 13);
  await settle();
  await userEvent.keyboard("{Control>}a{/Control}");
  await settle();
  const { from, to, $from } = (h.editor as any).editor.state.selection;
  expect({ empty: from === to, atHead: from === $from.start() + 12 }).toEqual({ empty: true, atHead: true });
});

test("画像のキャプションの中の全選択はキャプションだけ", async () => {
  const h = (harness = await mount("image-between"));
  h.caretInCaption();
  await settle();
  await userEvent.keyboard("せつめい");
  await settle();
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  const { from, to, $from } = view.state.selection;
  expect({
    node: $from.parent.type.name,
    whole: from === $from.start() && to === $from.end(),
    picked: view.state.doc.textBetween(from, to, " "),
  }).toEqual({ node: "imageItem", whole: true, picked: "せつめい" });
});

test("引用の出典の中の全選択は出典だけ", async () => {
  const h = (harness = await mount("quote"));
  caretIn(h, "quoteCite");
  await settle();
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  const { from, to, $from } = view.state.selection;
  expect({
    node: $from.parent.type.name,
    whole: from === $from.start() && to === $from.end(),
    picked: view.state.doc.textBetween(from, to, " "),
  }).toEqual({ node: "quoteCite", whole: true, picked: "出典の名前" });
});
