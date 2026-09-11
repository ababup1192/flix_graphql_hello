// 「+」と `/` の一覧から埋め込みを入れる。提供元で embed（YouTube 等）と linkCard に分かれる。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const kinds = (h: Harness) => ((h.doc() as any).content ?? []).map((node: any) => node.type);

// 一覧を開いて「埋め込み」を選び、URL の欄を出す。
async function openUrlBox(h: Harness, bySlash: boolean) {
  if (bySlash) {
    await userEvent.keyboard("/");
    await settle();
  } else {
    at(h, ".tt-plus").click();
    await settle();
  }
  const item = [...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find(
    (one) => one.textContent?.trim() === "埋め込み",
  )!;
  press(item);
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-blocks-url")).toHaveLength(1));
}

// URL の欄に入れて Enter で決める。
//
// WhyNot: `focus()` してから打鍵しない。欄は開いた直後に本文へ焦点を戻す道があり、
// 打った URL が本文にそのまま入る（実際に段落のリンクになった）。押してから入れる。
async function fillUrl(h: Harness, url: string) {
  const box = at<HTMLInputElement>(h, ".tt-blocks-url");
  await userEvent.click(box);
  await userEvent.fill(box, url);
  await userEvent.keyboard("{Enter}");
}

for (const bySlash of [false, true]) {
  const way = bySlash ? "`/`" : "「+」";

  test(`${way} の一覧の「埋め込み」で URL の欄が出る`, async () => {
    const h = (harness = await mount("empty"));
    toEnd(h);
    await settle();
    await openUrlBox(h, bySlash);
  });

  test(`${way} から YouTube の URL が embed になる`, async () => {
    const h = (harness = await mount("empty"));
    toEnd(h);
    await settle();
    await openUrlBox(h, bySlash);
    await fillUrl(h, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
    await vi.waitFor(() => expect(kinds(h)).toContain("embed"));
  });
}

test("「+」から他のサイトの URL は linkCard になる", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await settle();
  await openUrlBox(h, false);
  await fillUrl(h, "https://example.com/link-card");
  await vi.waitFor(() => expect(kinds(h)).toContain("linkCard"));
});
