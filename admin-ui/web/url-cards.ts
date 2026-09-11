// URL 1 つから、外部リンクのカード（linkCard）か埋め込み（embed）かを決める。
//
// 判定は CMS の `RichText.embedOf` の写し。YouTube / Vimeo / X だけが embed で、他の http(s) は
// linkCard。**doc に持つのは `url` だけ**（OGP は doc に写さない。`richtext-note-style.md` 3.3）。
//
// WhyNot: 提供元の一覧を画面側で増やさない。CMS が知らない提供元を embed にすると保存で断られる。

import type { Editor } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { Extension } from "@tiptap/core";

export type Provider = "YouTube" | "Vimeo" | "X";

const PROVIDERS: Array<[Provider, RegExp]> = [
  ["YouTube", /^https:\/\/(www\.)?youtube\.com\/watch\?v=[A-Za-z0-9_-]{6,20}([&#].*)?$/],
  ["YouTube", /^https:\/\/youtu\.be\/[A-Za-z0-9_-]{6,20}([?#].*)?$/],
  ["Vimeo", /^https:\/\/vimeo\.com\/[0-9]{1,20}([?#].*)?$/],
  ["X", /^https:\/\/(x\.com|twitter\.com)\/[A-Za-z0-9_]{1,15}\/status\/[0-9]{1,25}([?#].*)?$/],
];

export function providerOf(url: string): Provider | null {
  for (const [name, pattern] of PROVIDERS) {
    if (pattern.test(url)) return name;
  }
  return null;
}

// 空白を含まない http(s) の URL 1 つだけ（CMS の「URL だけの行」の判定 `^https?://\S+$` と同じ）。
const SOLE_URL = /^https?:\/\/\S+$/i;

export function soleUrl(text: string): string | null {
  const trimmed = text.trim();
  return SOLE_URL.test(trimmed) ? trimmed : null;
}

export function hostnameOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

/** URL 1 つを本文に置く時の node の形。 */
export function cardOf(url: string): Record<string, unknown> {
  return providerOf(url) ? { type: "embed", attrs: { url } } : { type: "linkCard", attrs: { url } };
}

// カーソルの居る段落が空で、他の block の中（表・引用・リスト）に居ないか。
function inEmptyTopParagraph(editor: Editor): boolean {
  const { $from, empty } = editor.state.selection;
  if (!empty) return false;
  const parent = $from.parent;
  return parent.type.name === "paragraph" && parent.content.size === 0 && $from.depth === 1;
}

/** 今の位置に URL を置く。空の段落ならカード / 埋め込みに、文中ならリンク付きの文字に。 */
export function placeUrl(editor: Editor, url: string) {
  if (inEmptyTopParagraph(editor)) {
    const { $from } = editor.state.selection;
    const at = $from.before();
    const after = $from.after();
    // カードと埋め込みは中に書けないので、続きを打つ段落が下に要る。
    // WhyNot: いつも段落を足さない。既に下が段落なら 2 つ並んで空行が空く。
    const next = editor.state.doc.nodeAt(after);
    const content: Array<Record<string, unknown>> = [cardOf(url)];
    if (next?.type.name !== "paragraph") content.push({ type: "paragraph" });
    editor
      .chain()
      .focus()
      .insertContentAt({ from: at, to: after }, content)
      .command(({ tr, dispatch }) => {
        if (!dispatch) return true;
        const card = tr.doc.nodeAt(at);
        if (!card) return true;
        const below = at + card.nodeSize;
        if (tr.doc.nodeAt(below)?.type.name !== "paragraph") return true;
        tr.setSelection(TextSelection.create(tr.doc, below + 1));
        return true;
      })
      .run();
    return;
  }
  editor
    .chain()
    .focus()
    .insertContent({ type: "text", text: url, marks: [{ type: "link", attrs: { href: url, entryId: null } }] })
    .run();
}

/** 貼られた文字が URL 1 つだけなら `placeUrl` に回す。 */
export const UrlPaste = Extension.create({
  name: "urlPaste",
  // Link の linkOnPaste より先に受ける。
  priority: 1100,
  addProseMirrorPlugins() {
    const editor = this.editor;
    return [
      new Plugin({
        key: new PluginKey("urlPaste"),
        props: {
          handlePaste(_view, event) {
            const url = soleUrl(event.clipboardData?.getData("text/plain") ?? "");
            if (!url) return false;
            // 文字を選んでいる時は Link の linkOnPaste（選んだ文字にリンクを掛ける）に任せる。
            if (!editor.state.selection.empty) return false;
            event.preventDefault();
            placeUrl(editor, url);
            return true;
          },
        },
      }),
    ];
  },
});
