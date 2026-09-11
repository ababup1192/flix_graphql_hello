// コードブロックの帯（ファイル名 / 言語）と、左の行番号（強調行）。
//
// 見るのは **doc に何が入るか**と一覧の中身だけ。帯の位置と行の揃いは遅い層。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const codeAttr = (h: Harness, name: string) =>
  ((h.doc() as any).content ?? []).find((node: any) => node.type === "codeBlock")?.attrs?.[name] ?? null;

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;

// 帯の欄に入れて Enter で決める。
async function typeInto(box: HTMLInputElement, text: string) {
  await userEvent.click(box);
  await userEvent.fill(box, text);
  await userEvent.keyboard("{Enter}");
  await settle();
}

const pickLine = (row: HTMLElement, shiftKey = false) => press(row, { shiftKey });

test("ファイル名が codeBlock の attrs に入る", async () => {
  const h = (harness = await mount("code-lines"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), "src/main.ts");
  expect(codeAttr(h, "fileName")).toBe("src/main.ts");
});

test("CMS が受けない形のファイル名は doc に入らない", async () => {
  const h = (harness = await mount("code-lines"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), 'bad name<>"');
  expect(codeAttr(h, "fileName")).toBe(null);
});

test("受けない形のファイル名に印が付く", async () => {
  const h = (harness = await mount("code-lines"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), 'bad name<>"');
  expect(at(h, ".tt-code-file").classList.contains("is-bad")).toBe(true);
});

test("行番号が行の数だけ 1 から並ぶ", async () => {
  const h = (harness = await mount("code-lines"));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-line")).toHaveLength(5));
  expect([...h.editor.querySelectorAll(".tt-code-line")].map((row) => row.textContent)).toEqual(["1", "2", "3", "4", "5"]);
});

test("行番号を押すとその行が強調に入る", async () => {
  const h = (harness = await mount("code-lines"));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-line")).toHaveLength(5));
  pickLine(h.editor.querySelectorAll<HTMLElement>(".tt-code-line")[0]);
  await settle();
  expect(codeAttr(h, "highlightLines")).toBe("1");
});

test("Shift で押すと範囲が強調に入る", async () => {
  const h = (harness = await mount("code-lines"));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-line")).toHaveLength(5));
  const rows = () => h.editor.querySelectorAll<HTMLElement>(".tt-code-line");
  pickLine(rows()[0]);
  await settle();
  pickLine(rows()[2]);
  await settle();
  pickLine(rows()[4], true);
  await settle();
  expect(codeAttr(h, "highlightLines")).toBe("1,3-5");
});

test("もう一度押すと強調が外れる", async () => {
  const h = (harness = await mount("code-lines"));
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-line")).toHaveLength(5));
  const rows = () => h.editor.querySelectorAll<HTMLElement>(".tt-code-line");
  pickLine(rows()[0]);
  await settle();
  expect(codeAttr(h, "highlightLines")).toBe("1");
  pickLine(rows()[0]);
  await settle();
  expect(codeAttr(h, "highlightLines")).toBe(null);
});

test("別名は正式名の行に添えて出る", async () => {
  const h = (harness = await mount("code-lines"));
  const box = at<HTMLInputElement>(h, ".tt-code-lang");
  await userEvent.click(box);
  await userEvent.fill(box, "c++");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-item").length).toBeGreaterThan(0));
  expect([...h.editor.querySelectorAll(".tt-code-item")].map((row) => row.textContent)).toEqual(["CPcppc++, cc"]);
});

test("別名で選んでも doc には正の名前が入り、欄には整った名前が出る", async () => {
  const h = (harness = await mount("code-lines"));
  const box = at<HTMLInputElement>(h, ".tt-code-lang");
  await userEvent.click(box);
  await userEvent.fill(box, "c++");
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-code-item").length).toBeGreaterThan(0));
  await userEvent.keyboard("{Enter}");
  await vi.waitFor(() => expect(codeAttr(h, "language")).toBe("cpp"));
  expect(box.value).toBe("C++");
});

test("`test.flix` と打つと言語に Flix が入る", async () => {
  const h = (harness = await mount("code-lines"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), "test.flix");
  await vi.waitFor(() => expect(at<HTMLInputElement>(h, ".tt-code-lang").value).toBe("Flix"));
});

test("言語を選んだ後にファイル名を変えても言語が変わらない", async () => {
  const h = (harness = await mount("code-lines"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), "test.flix");
  await vi.waitFor(() => expect(at<HTMLInputElement>(h, ".tt-code-lang").value).toBe("Flix"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), "test.py");
  await settle();
  expect(at<HTMLInputElement>(h, ".tt-code-lang").value).toBe("Flix");
});

test("知らない拡張子では言語が入らない", async () => {
  const h = (harness = await mount("code-lines"));
  await typeInto(at<HTMLInputElement>(h, ".tt-code-file"), "test.zzzz");
  await settle();
  expect(at<HTMLInputElement>(h, ".tt-code-lang").value).toBe("");
});

for (const [key, where] of [["ArrowUp", "前"], ["ArrowDown", "次"]] as const) {
  test(`ファイル名の欄の ${key} で${where}の行へ出る`, async () => {
    const h = (harness = await mount("blocks"));
    const box = at<HTMLInputElement>(h, ".tt-code-file");
    await userEvent.click(box);
    await vi.waitFor(() => expect(document.activeElement).toBe(box));
    await userEvent.keyboard(`{${key}}`);
    await vi.waitFor(() => expect(document.activeElement).not.toBe(box));
  });
}
