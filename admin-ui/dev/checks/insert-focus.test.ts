// 入れた直後にカーソルが「続きを書ける所」に入る。
//
// 中に文字を書けるブロックは中に、書けないブロック（カード・埋め込み）はその下の段落に。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, toEnd, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const inside = (h: Harness) => (h.editor as any).editor.state.selection.$from.parent.type.name;
const indexAt = (h: Harness) => (h.editor as any).editor.state.selection.$from.index(0);
const kinds = (h: Harness) => ((h.doc() as any).content ?? []).map((node: any) => node.type);

// URL を 1 つ貼る。
function paste(h: Harness, url: string) {
  const data = new DataTransfer();
  data.setData("text/plain", url);
  (h.editor as any).editor.view.dom.dispatchEvent(
    new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }),
  );
}

test("``` の直後にコードブロックの中へ入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("```{Enter}");
  await vi.waitFor(() => expect(inside(h)).toBe("codeBlock"));
});

test("> の直後に引用の中へ入る", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  await userEvent.keyboard("> ");
  await vi.waitFor(() => expect(kinds(h)).toContain("blockquote"));
  expect(inside(h)).toBe("paragraph");
});

test("URL を貼った直後にカードの下の段落へ入り、そのまま続きが打てる", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  paste(h, "https://example.com/focus");
  await vi.waitFor(() => expect(kinds(h)).toEqual(["linkCard", "paragraph"]));
  expect({ inside: inside(h), index: indexAt(h) }).toEqual({ inside: "paragraph", index: 1 });
  await userEvent.keyboard("つづき");
  await settle();
  expect(h.text()).toContain("つづき");
});
