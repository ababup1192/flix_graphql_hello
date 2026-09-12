// 長い本文の途中の表を組み直した時、面の送りが動かない事。
//
// **何が壊れたら落ちるか**: 表の組み直し（`writeGrid`）が編集していた場所を見失い、
// 面が本文の別の所へ飛ぶようになったら落ちる。
import { expect, test, afterEach } from "vitest";
import { mount, settle, type Harness } from "../harness";
import { moveColumn, moveRow, resizeTable } from "../../web/table-tools";

let harness: Harness | null = null;
afterEach(() => {
  harness?.destroy();
  window.scrollTo(0, 0);
});

const inner = (h: Harness) => (h.editor as any).editor;

// 表の最初の升にカーソルを置き、表が画面の真ん中に来るまで送る。
async function caretInTableAndScroll(h: Harness): Promise<number> {
  const view = inner(h);
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableHeader" && found < 0) found = pos;
  });
  view.view.dom.focus();
  view.commands.setTextSelection(found + 2);
  await settle();
  const table = h.editor.querySelector("table")!;
  table.scrollIntoView({ block: "center" });
  await settle();
  return window.scrollY;
}

test("長い本文の途中で表の大きさを変えても面は飛ばない", async () => {
  const h = (harness = await mount("table-in-long"));
  const before = await caretInTableAndScroll(h);
  expect(before).toBeGreaterThan(200);

  resizeTable(inner(h), 3, 5);
  await settle();

  expect(Math.abs(window.scrollY - before)).toBeLessThan(60);
});

test("カーソルが表の外にあっても大きさを変えた表の所に留まる", async () => {
  const h = (harness = await mount("table-in-long"));
  const before = await caretInTableAndScroll(h);
  const view = inner(h);
  let at = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "table" && at < 0) at = pos + 2;
  });
  // 帯はカーソルの無い表にも出る。本文の先頭にカーソルを置いたまま帯から大きさを変える。
  view.commands.setTextSelection(2);
  await settle();
  window.scrollTo(0, before);
  await settle();

  resizeTable(view, 3, 5, at);
  await settle();

  expect(Math.abs(window.scrollY - before)).toBeLessThan(60);
});

test("長い本文の途中で行を入れ替えても面は飛ばない", async () => {
  const h = (harness = await mount("table-in-long"));
  const before = await caretInTableAndScroll(h);

  moveRow(inner(h), 1, 2);
  await settle();

  expect(Math.abs(window.scrollY - before)).toBeLessThan(60);
});

test("長い本文の途中で列を入れ替えても面は飛ばない", async () => {
  const h = (harness = await mount("table-in-long"));
  const before = await caretInTableAndScroll(h);

  moveColumn(inner(h), 0, 2);
  await settle();

  expect(Math.abs(window.scrollY - before)).toBeLessThan(60);
});
