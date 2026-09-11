// 表を入れる所と、升の中に入れられる物。
//
// 帯と掴みの位置・幅・掴んだ入れ替えは遅い層（`scripts/rich-check.mjs`）。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;

// 最初の升の中にカーソルを置く。**升は押しても ProseMirror のカーソルが動かない**
// （素の click は DOM の選択を作らない）ので、選択そのものを置く。
function caretInCell(h: Harness) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "tableHeader" && found < 0) found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + 2);
}

// 「+」の一覧の「表」から、升目で 行 × 列 を選ぶ。
async function insertTable(h: Harness, rows: number, cols: number) {
  at(h, ".tt-plus").click();
  await settle();
  const item = [...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find(
    (one) => one.textContent?.trim() === "表",
  )!;
  press(item);
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-size-cell").length).toBeGreaterThan(0));
  press(h.editor.querySelectorAll<HTMLElement>(".tt-size-cell")[(rows - 1) * 8 + (cols - 1)]);
  await vi.waitFor(() => expect(h.names()).toContain("table"));
}

test("大きさは 8 × 8 の升目で選ぶ", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await settle();
  at(h, ".tt-plus").click();
  await settle();
  const item = [...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find(
    (one) => one.textContent?.trim() === "表",
  )!;
  press(item);
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-size-cell")).toHaveLength(64));
});

test("選んだ行と列の数で、見出しの行のある表が入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await settle();
  await insertTable(h, 3, 4);
  const table = ((h.doc() as any).content ?? []).find((node: any) => node.type === "table");
  expect(table.content.map((row: any) => row.content.map((cell: any) => cell.type))).toEqual([
    ["tableHeader", "tableHeader", "tableHeader", "tableHeader"],
    ["tableCell", "tableCell", "tableCell", "tableCell"],
    ["tableCell", "tableCell", "tableCell", "tableCell"],
  ]);
});

test("表を入れた直後は最初の升の中にカーソルが入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await settle();
  await insertTable(h, 3, 3);
  await userEvent.keyboard("あ");
  await settle();
  const table = ((h.doc() as any).content ?? []).find((node: any) => node.type === "table");
  expect(table.content[0].content[0].content[0].content[0].text).toBe("あ");
});

test("寄せは列ぜんたい（3 行）に付く", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await vi.waitFor(() => expect(h.editor.querySelector('.tt-tablebar-button[title="中央に寄せる"]')).not.toBeNull());
  press(at<HTMLElement>(h, '.tt-tablebar-button[title="中央に寄せる"]'));
  await vi.waitFor(() => expect(JSON.stringify(h.doc()).split('"align":"center"')).toHaveLength(3));
});

test("表の升の中に箇条書きは入らない", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await settle();
  at<HTMLElement>(h, '.tt-bar .tt-tool[title="箇条書き"]').click();
  await settle();
  expect(h.names().filter((name) => name === "bulletList")).toEqual([]);
});

test("表の升の中では「+」が出ない", async () => {
  const h = (harness = await mount("table"));
  caretInCell(h);
  await settle();
  expect(at(h, ".tt-plus").hidden).toBe(true);
});
