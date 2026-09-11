// 外部リンクのカード（linkCard）。attrs は `url` だけ。
//
// 編集画面では note と同じ形のカード（`docs/design/richtext-note-linkcard-ui.md`）。
// 左に タイトル / 説明 / ドメイン、右 30% にサムネイル。貼った瞬間に OGP を取りに行き、
// 取れるまでは同じ大きさの白い箱に「…」。OGP は doc に持たず、`CardStore` が url → OGP で持つ。
//
// WhyNot: エディタが管理 API を叩かない。URL もヘッダも `js/api.ts` と Elm が持つ（画像の
// `assets` と同じ決まり）。欲しい URL は `onAsk` で外に出し、答えは `cards` の属性で受ける。
//
// WhyNot: 枠の中に iframe を置かない。相手のページが編集中に動くとスクロールとキー操作を奪う。
//
// 消す時は**素の URL の段落に戻す**（note と同じ逃げ道。カードを消したら URL も消えた、にしない）。

import { Node } from "@tiptap/core";
import type { Editor } from "@tiptap/core";
import { NodeSelection, TextSelection } from "@tiptap/pm/state";
import { hostnameOf } from "./url-cards";
import { ICONS, svg } from "./icons";

export type LinkCard = {
  url: string;
  title?: string | null;
  description?: string | null;
  imageUrl?: string | null;
  siteName?: string | null;
  fetchedAt?: string | null;
  error?: string | null;
};

// 「…」を出したままにしない目安。これを超えたら箱の中に薄く文字を足す。
const SLOW_MS = 3000;
// 帯のアイコンの大きさ（画像の帯と同じ）。
const BAR_ICON = 22;

type AskMode = "lookup" | "fetch";

/** url → OGP の対応。Elm から属性で来て、変わったら描き直す。 */
export class CardStore {
  private map = new Map<string, LinkCard>();
  private listeners = new Set<() => void>();
  private asked = new Set<string>();
  private wanted = new Set<string>();
  private batching = false;
  private timer: number | null = null;

  constructor(private onAsk: (urls: string[], mode: AskMode) => void) {}

  set(list: LinkCard[]) {
    this.map = new Map(list.filter((card) => card && typeof card.url === "string").map((card) => [card.url, card]));
    for (const listener of this.listeners) listener();
  }

  get(url: string): LinkCard | undefined {
    return this.map.get(url);
  }

  watch(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // node view が「この URL の OGP が無い」と言ってきた物を溜め、まとめて外に出す。
  // 同じ URL は 1 回しか頼まない（描き直しの度に飛ばない）。
  ask(url: string) {
    if (!url || this.map.has(url) || this.asked.has(url)) return;
    this.asked.add(url);
    this.wanted.add(url);
    if (this.batching || this.timer !== null) return;
    this.timer = window.setTimeout(() => this.flush("fetch"), 0);
  }

  // doc を読み込む間に頼まれた物は「表から引く」（lookup）でまとめる。
  // それ以外（貼った瞬間）は「その場で取る」（fetch）。
  batch(run: () => void) {
    this.batching = true;
    try {
      run();
    } finally {
      this.batching = false;
      this.flush("lookup");
    }
  }

  private flush(mode: AskMode) {
    if (this.timer !== null) {
      window.clearTimeout(this.timer);
      this.timer = null;
    }
    if (this.wanted.size === 0) return;
    const urls = [...this.wanted];
    this.wanted.clear();
    this.onAsk(urls, mode);
  }
}

type ViewArgs = { node: { attrs: Record<string, unknown> }; editor: any };

function urlOf(attrs: Record<string, unknown>): string {
  return typeof attrs.url === "string" ? attrs.url : "";
}

/** 薄い枠。上の行が見出し（提供元）、下の行が URL。embed が使う。 */
export function cardView(name: string, className: string, head: (url: string) => string) {
  return ({ node }: ViewArgs) => {
    const dom = document.createElement("div");
    dom.className = `tt-card ${className}`;
    const title = document.createElement("span");
    title.className = "tt-card-head";
    const url = document.createElement("span");
    url.className = "tt-card-url";
    dom.append(title, url);
    const paint = (attrs: Record<string, unknown>) => {
      const value = urlOf(attrs);
      title.textContent = head(value);
      url.textContent = value;
      dom.title = value;
    };
    paint(node.attrs);
    return {
      dom,
      update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
        if (updated.type.name !== name) return false;
        paint(updated.attrs);
        return true;
      },
    };
  };
}

/** 選ばれているカードを、URL だけの段落に置き換える。選ばれていなければ何もしない。 */
export function revertToUrl(editor: Editor, name: string): boolean {
  const { selection, schema } = editor.state;
  if (!(selection instanceof NodeSelection) || selection.node.type.name !== name) return false;
  const url = urlOf(selection.node.attrs);
  const paragraph = schema.nodes.paragraph.create(null, url ? schema.text(url) : null);
  const tr = editor.state.tr.replaceWith(selection.from, selection.to, paragraph);
  tr.setSelection(TextSelection.create(tr.doc, selection.from + 1 + url.length));
  editor.view.dispatch(tr);
  return true;
}

const THUMB_ICON = `<svg viewBox="0 0 24 24"><path d="M3 5h18v14H3z M5 17l4-5 3 4 2-2 5 3z" fill-rule="evenodd"/></svg>`;

function element(tag: string, className: string): HTMLElement {
  const created = document.createElement(tag);
  created.className = className;
  return created;
}

// カードの node view。取れるまで「…」、取れたらカード、取れなければ URL と理由。
function linkCardView(store: CardStore) {
  return ({ node, editor }: ViewArgs) => {
    const dom = element("div", "tt-link-card");
    dom.contentEditable = "false";

    // 上に浮く帯。削除だけ（画像の帯と同じ見た目）。
    const bar = element("div", "tt-image-bar");
    bar.hidden = true;
    const trash = document.createElement("button");
    trash.type = "button";
    trash.className = "tt-image-tool tt-image-icon";
    trash.innerHTML = svg(ICONS.trash, BAR_ICON);
    trash.title = "削除";
    trash.setAttribute("aria-label", "削除");
    // mousedown を止めないと ProseMirror が node の選択を外し、帯ごと消える。
    trash.addEventListener("mousedown", (event) => event.preventDefault());
    trash.addEventListener("click", () => {
      revertToUrl(editor, "linkCard");
      editor.view.focus();
    });
    bar.append(trash);

    // 取りに行っている間の「…」。3 秒を超えたら薄く文字。
    const loading = element("div", "tt-link-card-loading");
    const dots = element("span", "tt-link-card-dots");
    dots.append(element("i", ""), element("i", ""), element("i", ""));
    const slow = element("span", "tt-link-card-slow");
    slow.textContent = "取得中…";
    slow.hidden = true;
    loading.append(dots, slow);

    // カード本体。左が文字、右がサムネイル。
    const text = element("div", "tt-link-card-text");
    const title = element("div", "tt-link-card-title");
    const desc = element("div", "tt-link-card-desc");
    const site = element("div", "tt-link-card-site");
    text.append(title, desc, site);
    const thumb = element("div", "tt-link-card-thumb");
    const img = document.createElement("img");
    img.alt = "";
    img.hidden = true;
    const icon = element("span", "tt-link-card-thumb-icon");
    icon.innerHTML = THUMB_ICON;
    thumb.append(img, icon);

    dom.append(bar, loading, text, thumb);

    let slowTimer: number | null = null;
    const stopSlow = () => {
      if (slowTimer !== null) window.clearTimeout(slowTimer);
      slowTimer = null;
    };

    let url = "";
    const paint = () => {
      const card = store.get(url);
      const done = !!card && (!!card.fetchedAt || !!card.error);
      dom.classList.toggle("is-loading", !done);
      dom.classList.toggle("is-failed", !!card?.error);
      dom.title = url;
      if (!done) {
        store.ask(url);
        if (slowTimer === null) {
          slow.hidden = true;
          slowTimer = window.setTimeout(() => {
            slow.hidden = false;
          }, SLOW_MS);
        }
        return;
      }
      stopSlow();
      const host = hostnameOf(url);
      if (card?.error) {
        title.textContent = url;
        desc.textContent = card.error;
        site.textContent = "";
      } else {
        title.textContent = card?.title || host;
        desc.textContent = card?.description ?? "";
        site.textContent = host;
      }
      desc.hidden = desc.textContent === "";
      site.hidden = site.textContent === "";
      const image = !card?.error && typeof card?.imageUrl === "string" ? card.imageUrl : "";
      // WhyNot: `onerror` を src を変えた時に限る。同じ URL を渡し直しても失敗が消えないようにする。
      if (image && img.dataset.failed !== image) {
        if (img.getAttribute("src") !== image) {
          img.onerror = () => {
            img.dataset.failed = image;
            img.hidden = true;
            icon.hidden = false;
          };
          img.src = image;
        }
        img.hidden = false;
        icon.hidden = true;
      } else {
        img.removeAttribute("src");
        img.hidden = true;
        icon.hidden = false;
      }
    };

    const load = (attrs: Record<string, unknown>) => {
      url = urlOf(attrs);
      paint();
    };
    load(node.attrs);
    const stop = store.watch(paint);

    return {
      dom,
      // 帯はこちらが描く物なので、触っても doc は動かさない。
      ignoreMutation: () => true,
      stopEvent: (event: Event) => bar.contains(event.target as globalThis.Node),
      update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
        if (updated.type.name !== "linkCard") return false;
        load(updated.attrs);
        return true;
      },
      selectNode() {
        dom.classList.add("ProseMirror-selectednode");
        bar.hidden = false;
      },
      deselectNode() {
        dom.classList.remove("ProseMirror-selectednode");
        bar.hidden = true;
      },
      destroy() {
        stop();
        stopSlow();
      },
    };
  };
}

export function linkCardNode(store: CardStore) {
  return Node.create({
    name: "linkCard",
    group: "block",
    atom: true,
    draggable: true,
    selectable: true,

    addAttributes() {
      return { url: { default: null } };
    },

    parseHTML() {
      return [{ tag: "a[data-link-card]", getAttrs: (element) => ({ url: (element as HTMLElement).getAttribute("href") }) }];
    },

    renderHTML({ HTMLAttributes }) {
      const url = String(HTMLAttributes.url ?? "");
      return ["a", { "data-link-card": "", href: url }, url];
    },

    addNodeView() {
      return linkCardView(store);
    },

    addKeyboardShortcuts() {
      return {
        Backspace: () => revertToUrl(this.editor, this.name),
        Delete: () => revertToUrl(this.editor, this.name),
      };
    },
  });
}
