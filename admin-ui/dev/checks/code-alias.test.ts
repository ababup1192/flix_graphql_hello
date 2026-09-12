// コードブロックの言語に別名（`ts` / `js` / `py` / `yml`）が入っている doc。
// doc の値はそのままに、エディタ側が別名を解いて色を付け、欄に整った名前を出す。
import { expect, test, afterEach, vi } from "vitest";
import { mount, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

// 言語と中身を持つコードブロック 1 つだけの doc。
const codeDoc = (language: string, text: string) => ({
  type: "doc",
  content: [
    {
      type: "codeBlock",
      attrs: { language, fileName: null, highlightLines: null },
      content: [{ type: "text", text }],
    },
    { type: "paragraph" },
  ],
});

const langBox = (h: Harness) => h.editor.querySelector<HTMLInputElement>(".tt-code-lang")!;

const colored = (h: Harness) => h.editor.querySelectorAll("pre code span[class^='hljs-']").length;

test("別名 ts の doc でコードに色が付く", async () => {
  const h = (harness = await mount(codeDoc("ts", "const a: number = 1;")));
  await vi.waitFor(() => expect(colored(h)).toBeGreaterThan(0));
});

test("別名 ts の doc で言語の欄に TypeScript と出る", async () => {
  const h = (harness = await mount(codeDoc("ts", "const a: number = 1;")));
  await vi.waitFor(() => expect(langBox(h).value).toBe("TypeScript"));
});

test("別名 ts の doc でも doc の language は ts のまま", async () => {
  const h = (harness = await mount(codeDoc("ts", "const a: number = 1;")));
  await vi.waitFor(() => expect(colored(h)).toBeGreaterThan(0));
  expect((h.doc().content ?? [])[0].attrs.language).toBe("ts");
});

test("正の id typescript の doc でも色が付く", async () => {
  const h = (harness = await mount(codeDoc("typescript", "const a: number = 1;")));
  await vi.waitFor(() => expect(colored(h)).toBeGreaterThan(0));
});

for (const [alias, label, code] of [
  ["js", "JavaScript", "const a = 1;"],
  ["py", "Python", "import sys"],
  ["yml", "YAML", "name: value"],
  ["sh", "Bash", "if true; then echo hi; fi"],
] as const) {
  test(`別名 ${alias} の doc で色が付く`, async () => {
    const h = (harness = await mount(codeDoc(alias, code)));
    await vi.waitFor(() => expect(colored(h)).toBeGreaterThan(0));
  });

  test(`別名 ${alias} の doc で言語の欄に ${label} と出る`, async () => {
    const h = (harness = await mount(codeDoc(alias, code)));
    await vi.waitFor(() => expect(langBox(h).value).toBe(label));
  });
}

test("実在しない言語の doc でも中身はそのまま出る", async () => {
  const h = (harness = await mount(codeDoc("zzzznope", "const a = 1;")));
  expect(h.text()).toBe("const a = 1;");
});

test("実在しない言語の doc では欄にその名前がそのまま出る", async () => {
  const h = (harness = await mount(codeDoc("zzzznope", "const a = 1;")));
  await vi.waitFor(() => expect(langBox(h).value).toBe("zzzznope"));
});
