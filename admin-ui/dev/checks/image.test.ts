// 画像（`image` > `imageItem`+）の帯と、キャプション・代替テキスト・配置。
//
// 帯は image の node ごとに 1 つずつ作られていて、選んでいない物は隠れている。
// 出ている帯が 1 つだけである事も一緒に見る（2 つ出ていたら帯を作る所が二重に走っている）。
// 並べた画像の枠と列、キャプションから矢印で出る所は `gallery-layout.test.ts` と `caption-exit.test.ts`。
import { expect, test, afterEach, vi } from "vitest";
import { userEvent } from "@vitest/browser/context";
import { mount, settle, type Harness } from "../harness";

let harness: Harness | null = null;
afterEach(() => harness?.destroy());

const at = <T extends HTMLElement>(h: Harness, selector: string) => h.editor.querySelector<T>(selector)!;

const itemsOf = (h: Harness): any[] => {
  const found: any[] = [];
  const walk = (node: any) => {
    if (node?.type === "imageItem") found.push(node);
    for (const child of node?.content ?? []) walk(child);
  };
  walk(h.doc());
  return found;
};

// 今出ている帯 1 つの中身。
function openBar(h: Harness): string {
  const bars = [...h.editor.querySelectorAll<HTMLElement>(".tt-image-bar")]
    .filter((bar) => !bar.hidden)
    .map((bar) =>
      [...bar.querySelectorAll<HTMLElement>(".tt-image-tool")]
        .filter((tool) => !tool.hidden)
        .map((tool) => tool.getAttribute("aria-label"))
        .join("/"),
    );
  return bars.length === 1 ? bars[0] : `帯が ${bars.length} つ出ています: ${JSON.stringify(bars)}`;
}

// n 枚目の画像を node ごと選ぶ（帯は node ごと選んだ時だけ出る）。
function pickImage(h: Harness, index = 0) {
  const view = (h.editor as any).editor;
  const found: number[] = [];
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "imageItem") found.push(pos);
  });
  view.chain().focus().setNodeSelection(found[index]).run();
}

// 並べた画像ぜんたい（`image` の node）を選ぶ。
function pickWhole(h: Harness) {
  const view = (h.editor as any).editor;
  let found = -1;
  view.state.doc.descendants((node: any, pos: number) => {
    if (node.type.name === "image" && found < 0) found = pos;
  });
  view.chain().focus().setNodeSelection(found).run();
}

test("1 枚でも image の中に imageItem が 1 つ（image に attrs は無い）", async () => {
  const h = (harness = await mount("image"));
  const image = ((h.doc() as any).content ?? []).find((node: any) => node.type === "image");
  expect({ attrs: image.attrs, items: image.content.map((one: any) => one.type) }).toEqual({
    attrs: undefined,
    items: ["imageItem"],
  });
});

test("画像の帯は リンク / ALT / 縮小 / 配置 / 削除 の順に並ぶ", async () => {
  const h = (harness = await mount("image"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toBe("リンク/代替テキスト/縮小/配置/削除"));
});

test("配置を押すと帯が 左 / 中央 / 右 に入れ替わる", async () => {
  const h = (harness = await mount("image"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("配置"));
  at<HTMLElement>(h, '.tt-image-tool[title="配置"]').click();
  await vi.waitFor(() => expect(openBar(h)).toBe("左に寄せる/中央に寄せる/右に寄せる"));
});

test("左に寄せる で align=left が入り、元の帯に戻る", async () => {
  const h = (harness = await mount("image"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("配置"));
  at<HTMLElement>(h, '.tt-image-tool[title="配置"]').click();
  await vi.waitFor(() => expect(openBar(h)).toContain("左に寄せる"));
  at<HTMLElement>(h, '.tt-image-tool[title="左に寄せる"]').click();
  await vi.waitFor(() => expect(itemsOf(h)[0]?.attrs?.align).toBe("left"));
  expect(openBar(h)).toContain("配置");
});

test("キャプションが imageItem の content に入り、中の Enter は何もしない", async () => {
  const h = (harness = await mount("image"));
  h.caretInCaption();
  await settle();
  await userEvent.keyboard("きゃぷしょん{Enter}");
  await vi.waitFor(() => expect(itemsOf(h)[0]?.content?.[0]?.text).toBe("きゃぷしょん"));
  expect({ items: itemsOf(h).length, parts: itemsOf(h)[0]?.content?.length, caption: itemsOf(h)[0]?.attrs?.caption }).toEqual({
    items: 1,
    parts: 1,
    caption: undefined,
  });
});

test("キャプションを打っている間は画像の帯が出ず、キャプションの帯は 3 つ", async () => {
  const h = (harness = await mount("image"));
  h.caretInCaption();
  await settle();
  await userEvent.keyboard("きゃぷしょん");
  await vi.waitFor(() => expect(document.querySelector(".tt-bubble-caption")).not.toBeNull());
  expect(at(h, ".tt-image .tt-image-bar").hidden).toBe(true);
  const tools = [...document.querySelectorAll(".tt-bubble-caption button")].map((one) => one.getAttribute("aria-label"));
  expect(tools).toEqual(["太字", "打ち消し", "リンク"]);
});

test("ALT を押すと代替テキストの欄に入れ替わり、焦点が入る", async () => {
  const h = (harness = await mount("image"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("代替テキスト"));
  at<HTMLElement>(h, '.tt-image-tool[title="代替テキスト"]').click();
  await vi.waitFor(() => expect(document.activeElement).toBe(at(h, ".tt-image-alt")));
});

test("代替テキストが imageItem の attrs に入り、元の帯に戻る", async () => {
  const h = (harness = await mount("image"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("代替テキスト"));
  at<HTMLElement>(h, '.tt-image-tool[title="代替テキスト"]').click();
  await vi.waitFor(() => expect(document.activeElement).toBe(at(h, ".tt-image-alt")));
  // WhyNot: `focus()` のまま打鍵に頼らない。帯は選択が動くたびに描き直され、
  // 打っている途中で欄から焦点が外れる事がある。押してから入れる。
  const box = at<HTMLInputElement>(h, ".tt-image-alt");
  await userEvent.click(box);
  await userEvent.fill(box, "さんぷるの代替");
  await userEvent.keyboard("{Enter}");
  await vi.waitFor(() => expect(itemsOf(h)[0]?.attrs?.alt).toBe("さんぷるの代替"));
  expect(openBar(h)).toContain("配置");
});

test("並べた中の 1 枚の帯は リンク / ALT / 削除", async () => {
  const h = (harness = await mount("gallery"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toBe("リンク/代替テキスト/削除"));
});

test("並べた画像ぜんたいの帯は 1 枚ずつに戻す / 削除", async () => {
  const h = (harness = await mount("gallery"));
  pickWhole(h);
  await vi.waitFor(() => expect(openBar(h)).toBe("1 枚ずつに戻す/削除"));
  expect(h.editor.querySelectorAll(".tt-gallery.ProseMirror-selectednode")).toHaveLength(1);
});

test("「1 枚ずつに戻す」で image が 1 枚ずつに分かれる", async () => {
  const h = (harness = await mount("gallery"));
  pickWhole(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("1 枚ずつに戻す"));
  at<HTMLElement>(h, '.tt-image-tool[title="1 枚ずつに戻す"]').click();
  await vi.waitFor(() => {
    const images = ((h.doc() as any).content ?? []).filter((node: any) => node.type === "image");
    expect(images.map((node: any) => node.content.length)).toEqual([1, 1, 1]);
  });
});

test("隣り合う 1 枚の帯には「横に並べる」が出て、押すと image 1 つに畳まれる", async () => {
  const h = (harness = await mount("gallery"));
  pickWhole(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("1 枚ずつに戻す"));
  at<HTMLElement>(h, '.tt-image-tool[title="1 枚ずつに戻す"]').click();
  await vi.waitFor(() => expect(((h.doc() as any).content ?? []).filter((node: any) => node.type === "image")).toHaveLength(3));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toBe("リンク/代替テキスト/縮小/配置/横に並べる/削除"));
  at<HTMLElement>(h, '.tt-image-tool[title="横に並べる"]').click();
  await vi.waitFor(() => {
    const images = ((h.doc() as any).content ?? []).filter((node: any) => node.type === "image");
    expect(images.map((node: any) => node.content.length)).toEqual([3]);
  });
});

test("最後の 1 枚を消すと image ごと消える", async () => {
  const h = (harness = await mount("image"));
  pickImage(h);
  await vi.waitFor(() => expect(openBar(h)).toContain("削除"));
  at<HTMLElement>(h, '.tt-image-tool[title="削除"]').click();
  await vi.waitFor(() => expect(h.names()).not.toContain("image"));
});

test("旧い gallery と attrs.assetId の image は、読む時に新しい形へ写る", async () => {
  const h = (harness = await mount({
    type: "doc",
    content: [
      { type: "image", attrs: { assetId: "asset-1", caption: "ふるいきゃぷしょん", size: "small" } },
      {
        type: "gallery",
        attrs: { columns: 2 },
        content: [
          { type: "image", attrs: { assetId: "asset-2" } },
          { type: "image", attrs: { assetId: "asset-3" } },
        ],
      },
      { type: "paragraph" },
    ],
  }));
  await vi.waitFor(() => expect(JSON.stringify(h.doc())).not.toContain('"gallery"'));
  const images = ((h.doc() as any).content ?? []).filter((node: any) => node.type === "image");
  expect(images.map((node: any) => node.content.length)).toEqual([1, 2]);
  expect({
    caption: images[0].content[0].content?.[0]?.text,
    size: images[0].content[0].attrs?.size,
  }).toEqual({ caption: "ふるいきゃぷしょん", size: "small" });
});
