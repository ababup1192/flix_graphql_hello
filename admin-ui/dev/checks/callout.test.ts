// 囲み（callout）と折りたたみ（details）。
//
// callout は attrs.kind が note / tip / warning、details は attrs.summary が空でない文字列。
// どちらも中身は普通のブロックで、CMS の `RichText.validate` がその形しか受けない。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { mount, toEnd, settle, press, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;
const inside = (h: Harness) => (h.editor as any).editor.state.selection.$from.parent.type.name;
const kinds = (h: Harness) => ((h.doc() as any).content ?? []).map((node: any) => node.type);
const nodeOf = (h: Harness, type: string) => ((h.doc() as any).content ?? []).find((node: any) => node.type === type);
const box = (el: HTMLElement) => el.getBoundingClientRect();
const onMac = navigator.platform.toUpperCase().includes("MAC");
const selectAll = onMac ? "{Meta>}a{/Meta}" : "{Control>}a{/Control}";

// 「+」の一覧から名前で選ぶ。
async function insert(h: Harness, label: string) {
  toEnd(h);
  await settle();
  at(h, ".tt-plus").click();
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-blocks-item").length).toBeGreaterThan(0));
  const item = [...h.editor.querySelectorAll<HTMLElement>(".tt-blocks-item")].find((one) =>
    one.textContent?.includes(label),
  );
  press(item!);
  await settle();
}

// n 番目のブロックの中にカーソルを置く。
function caretIn(h: Harness, name: string) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === name && found < 0) found = pos;
  });
  view.commands.focus();
  view.commands.setTextSelection(found + 2);
}

test("「+」の一覧に 囲み と 折りたたみ が並ぶ", async () => {
  const h = (harness = await mount("empty"));
  toEnd(h);
  at(h, ".tt-plus").click();
  await vi.waitFor(() => expect(h.editor.querySelectorAll(".tt-blocks-item").length).toBeGreaterThan(0));
  const labels = [...h.editor.querySelectorAll(".tt-blocks-item")].map((one) => one.textContent);
  expect(labels).toEqual([
    "画像",
    "区切り線",
    "引用",
    "囲み",
    "折りたたみ",
    "コード",
    "表",
    "数式",
    "チェックリスト",
    "埋め込み",
  ]);
});

test("「+」から入れた囲みは kind が note の段落 1 つ", async () => {
  const h = (harness = await mount("empty"));
  await insert(h, "囲み");
  await vi.waitFor(() => expect(kinds(h)).toContain("callout"));
  const node = nodeOf(h, "callout");
  expect({ kind: node.attrs.kind, children: node.content.map((one: any) => one.type) }).toEqual({
    kind: "note",
    children: ["paragraph"],
  });
});

test("「+」から入れた折りたたみは summary が空でない", async () => {
  const h = (harness = await mount("empty"));
  await insert(h, "折りたたみ");
  await vi.waitFor(() => expect(kinds(h)).toContain("details"));
  expect(nodeOf(h, "details").attrs.summary).not.toBe("");
});

test("入れた直後は囲みの中へカーソルが入る", async () => {
  const h = (harness = await mount("empty"));
  await insert(h, "囲み");
  await vi.waitFor(() => expect(inside(h)).toBe("paragraph"));
  await userEvent.keyboard("なかみ");
  await settle();
  expect(nodeOf(h, "callout").content[0].content[0].text).toBe("なかみ");
});

for (const [kind, title] of [
  ["tip", "ヒント"],
  ["warning", "警告"],
] as const) {
  test(`帯の「${title}」を押すと attrs.kind が ${kind} になる`, async () => {
    const h = (harness = await mount("callout"));
    const bar = h.editor.querySelector<HTMLElement>(".tt-callout-bar")!;
    bar.querySelector<HTMLElement>(`[title="${title}"]`)!.click();
    await vi.waitFor(() => expect(nodeOf(h, "callout").attrs.kind).toBe(kind));
  });
}

test("囲みの種別は帯で 3 つ（ノート / ヒント / 警告）", async () => {
  const h = (harness = await mount("callout"));
  const bar = h.editor.querySelector<HTMLElement>(".tt-callout-bar")!;
  expect([...bar.querySelectorAll("button")].map((one) => one.getAttribute("title"))).toEqual([
    "ノート",
    "ヒント",
    "警告",
  ]);
});

test("囲みの中身は段落・箇条書き・コードブロックを受ける", async () => {
  const h = (harness = await mount("empty"));
  await insert(h, "囲み");
  await vi.waitFor(() => expect(inside(h)).toBe("paragraph"));
  await userEvent.keyboard("だんらく{Enter}- こうもく{Enter}{Enter}");
  await settle();
  await userEvent.keyboard("```{Enter}");
  await settle();
  const node = nodeOf(h, "callout");
  expect(node.content.map((one: any) => one.type)).toEqual(["paragraph", "bulletList", "codeBlock"]);
});

test("summary の欄に打つと attrs.summary が変わる", async () => {
  const h = (harness = await mount("callout"));
  const input = at<HTMLInputElement>(h, ".tt-details-summary");
  await userEvent.fill(input, "あたらしいみだし");
  await vi.waitFor(() => expect(nodeOf(h, "details").attrs.summary).toBe("あたらしいみだし"));
});

test("summary を空にしても doc の summary は空にならない", async () => {
  const h = (harness = await mount("callout"));
  const input = at<HTMLInputElement>(h, ".tt-details-summary");
  await userEvent.fill(input, "");
  await settle();
  expect(nodeOf(h, "details").attrs.summary.trim()).not.toBe("");
});

test("summary を空にして離れると、欄にも既定の見出しが戻る", async () => {
  const h = (harness = await mount("callout"));
  const input = at<HTMLInputElement>(h, ".tt-details-summary");
  await userEvent.fill(input, "");
  input.blur();
  await vi.waitFor(() => expect(input.value.trim()).not.toBe(""));
});

test("折りたたみはエディタの中では開いたまま（中身が見えている）", async () => {
  const h = (harness = await mount("callout"));
  expect(at(h, ".tt-details-body").getClientRects().length).toBeGreaterThan(0);
});

test("折りたたみの中身は段落・箇条書きを受ける", async () => {
  const h = (harness = await mount("empty"));
  await insert(h, "折りたたみ");
  await vi.waitFor(() => expect(inside(h)).toBe("paragraph"));
  await userEvent.keyboard("だんらく{Enter}- こうもく");
  await settle();
  expect(nodeOf(h, "details").content.map((one: any) => one.type)).toEqual(["paragraph", "bulletList"]);
});

test("囲みの中の全選択は囲みの中だけ", async () => {
  const h = (harness = await mount("callout"));
  caretIn(h, "callout");
  await settle();
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  const { from, to } = view.state.selection;
  expect({
    picked: view.state.doc.textBetween(from, to, " "),
    outside: view.state.doc.textBetween(from, to, " ").includes("ヒントの囲み"),
  }).toEqual({ picked: "ノートの囲みです。", outside: false });
});

test("折りたたみの中の全選択は折りたたみの中だけ", async () => {
  const h = (harness = await mount("callout"));
  caretIn(h, "details");
  await settle();
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  const { from, to } = view.state.selection;
  expect(view.state.doc.textBetween(from, to, " ")).toBe("折りたたみの中身です。");
});

test("summary の欄の全選択は欄の中だけ", async () => {
  const h = (harness = await mount("callout"));
  const input = at<HTMLInputElement>(h, ".tt-details-summary");
  await userEvent.click(input);
  await userEvent.fill(input, "みだし");
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  expect({
    picked: input.value.slice(input.selectionStart ?? 0, input.selectionEnd ?? 0),
    span: view.state.selection.to - view.state.selection.from,
  }).toEqual({ picked: "みだし", span: 0 });
});

test("囲みの帯の余白を押しても本文にキャレットが残らない", async () => {
  const h = (harness = await mount("callout"));
  const bar = h.editor.querySelector<HTMLElement>('.tt-callout[data-kind="warning"] .tt-callout-bar')!;
  await userEvent.click(bar, { position: { x: box(bar).width - 6, y: box(bar).height / 2 } });
  await settle();
  expect(document.activeElement).toBe(bar);
});

test("折りたたみの帯の余白を押しても本文にキャレットが残らない", async () => {
  const h = (harness = await mount("callout"));
  const bar = h.editor.querySelector<HTMLElement>(".tt-details-bar")!;
  await userEvent.click(bar, { position: { x: 4, y: box(bar).height / 2 } });
  await settle();
  expect(document.activeElement).toBe(bar);
});

for (const [name, selector] of [
  ["囲み", ".tt-callout"],
  ["折りたたみ", ".tt-details"],
] as const) {
  test(`${name}の帯が箱の枠からはみ出さない`, async () => {
    const h = (harness = await mount("callout"));
    const frame = box(h.editor.querySelector<HTMLElement>(selector)!);
    const bar = box(h.editor.querySelector<HTMLElement>(`${selector} > .tt-block-bar`)!);
    expect({
      left: bar.left >= frame.left - 0.5,
      right: bar.right <= frame.right + 0.5,
      top: bar.top >= frame.top - 0.5,
    }).toEqual({ left: true, right: true, top: true });
  });
}

// 折りたたみの開閉は node view の中だけの状態で、doc には残らない。
const toggle = (h: Harness) => at<HTMLButtonElement>(h, ".tt-details-toggle");
const shut = (h: Harness) => at(h, ".tt-details").classList.contains("is-closed");

test("折りたたみは開いた状態で立ち上がる", async () => {
  const h = (harness = await mount("callout"));
  expect(shut(h)).toBe(false);
});

test("三角を押すと畳まれ、もう一度押すと開く", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await vi.waitFor(() => expect(shut(h)).toBe(true));
  toggle(h).click();
  await vi.waitFor(() => expect(shut(h)).toBe(false));
});

test("畳んでも doc は 1 文字も変わらない", async () => {
  const h = (harness = await mount("callout"));
  const before = JSON.stringify(h.doc());
  toggle(h).click();
  await settle();
  expect(JSON.stringify(h.doc())).toBe(before);
});

test("畳んだ中身は見えない", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await settle();
  expect(at(h, ".tt-details-body").getClientRects().length).toBe(0);
});

test("畳んでから開くと中身がそのまま出る", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await settle();
  toggle(h).click();
  await vi.waitFor(() => expect(at(h, ".tt-details-body").textContent).toBe("折りたたみの中身です。"));
});

test("中にカーソルがある時に畳むと、カーソルは折りたたみの外へ出る", async () => {
  const h = (harness = await mount("callout"));
  caretIn(h, "details");
  await settle();
  toggle(h).click();
  await vi.waitFor(() => {
    const view = (h.editor as any).editor;
    const { $from } = view.state.selection;
    const depths = Array.from({ length: $from.depth }, (_ignore, index) => $from.node(index + 1).type.name);
    expect(depths).not.toContain("details");
  });
});

test("畳んだ中へ矢印で入ってもカーソルは外へ戻される", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await settle();
  caretIn(h, "details");
  await settle();
  await settle();
  const view = (h.editor as any).editor;
  const { $from } = view.state.selection;
  const depths = Array.from({ length: $from.depth }, (_ignore, index) => $from.node(index + 1).type.name);
  expect(depths).not.toContain("details");
});

test("畳んだ状態で ⌘A を押しても、カーソルは畳んだ中身に入らない", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await settle();
  (h.editor as any).editor.commands.focus("end");
  await userEvent.keyboard(selectAll);
  await settle();
  const view = (h.editor as any).editor;
  const { $from } = view.state.selection;
  const depths = Array.from({ length: $from.depth }, (_ignore, index) => $from.node(index + 1).type.name);
  expect(depths).not.toContain("details");
});

test("畳んだまま本文を打っても畳まれたまま", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await settle();
  (h.editor as any).editor.commands.focus("end");
  await userEvent.keyboard("ほんぶん");
  await settle();
  expect(shut(h)).toBe(true);
});

test("畳んだ状態でも summary は打てる", async () => {
  const h = (harness = await mount("callout"));
  toggle(h).click();
  await settle();
  const input = at<HTMLInputElement>(h, ".tt-details-summary");
  await userEvent.fill(input, "たたんだまま");
  await vi.waitFor(() => expect(nodeOf(h, "details").attrs.summary).toBe("たたんだまま"));
});

test("囲みと折りたたみは灰色枠（Passthrough）に畳まれない", async () => {
  const h = (harness = await mount("callout"));
  expect(h.editor.querySelectorAll(".tt-passthrough")).toHaveLength(0);
});
