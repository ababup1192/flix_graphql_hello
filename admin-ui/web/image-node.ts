// 本文の画像と、画像の横並び（gallery）。
//
// CMS の `image` は `assetId` を持つ node で、`src` は持たない
// （`src/cms/rules/RichText.flix`）。URL は asset の id から画面では引けないので、
// **Elm が `assets` の属性で id → URL の対応を渡す**。
//
// キャプションは node の中身（text と marks）で、attrs には持たない。
//
// WhyNot: `@tiptap/extension-image` を使わない。あれは `src` を属性に持つ node で、
// 保存すると CMS が断る。属性を差し替えるより、`assetId` の node を自分で持つ方が
// 「保存できる形」と「画面に出る形」が 1 か所で揃う。
//
// WhyNot: キャプションを文字列の attr にしない。note はキャプションにリンクを書く文化で、
// attr だと link / bold のような mark を掛ける場所が無い。
//
// WhyNot: 画像を上げる所でも API を叩かない。エディタは URL もヘッダも知らない
// （`linkopen` と同じ決まり）。ファイルは `mediaupload` の event で外に出す。

import { Node, Extension } from "@tiptap/core";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { leaveBlock } from "./block-edges";
import { isHttpUrl } from "./note-input";
import { ICONS, svg } from "./icons";

export type AssetInfo = { id: string; url: string; alt?: string };

// gallery の列。CMS が受けるのは 2 〜 4（`minGalleryColumns` / `maxGalleryColumns`）。
const COLUMNS = [2, 3, 4];
const DEFAULT_COLUMNS = 2;

/** id → URL の対応。Elm から属性で来て、変わったら描き直す。 */
export class AssetStore {
  private map = new Map<string, AssetInfo>();
  private listeners = new Set<() => void>();

  set(list: AssetInfo[]) {
    this.map = new Map(list.filter((asset) => asset && asset.id).map((asset) => [asset.id, asset]));
    for (const listener of this.listeners) listener();
  }

  get(id: string | null | undefined): AssetInfo | undefined {
    return id ? this.map.get(id) : undefined;
  }

  watch(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}

type ViewArgs = {
  node: any;
  getPos: () => number | undefined;
  editor: any;
};

// CMS が受ける値（`RichText.checkImage`）。size は "small" だけ。
const SMALL = "small";
// 配置。中央は null（既定）。
const ALIGNS: Array<{ value: string | null; icon: string; title: string }> = [
  { value: "left", icon: ICONS.alignLeft, title: "左に寄せる" },
  { value: null, icon: ICONS.alignCenter, title: "中央に寄せる" },
  { value: "right", icon: ICONS.alignRight, title: "右に寄せる" },
];
// 帯のアイコンの大きさ。ツールバー（16px）より大きい（帯のボタンが 36px）。
const BAR_ICON = 22;

// 帯の中身。tools（リンク / ALT / …）、align（3 つの寄せ）、入力（alt / href / source）のどれか 1 つ。
type BarMode = "tools" | "align" | "alt" | "href" | "source";

// 帯が tools 以外になっている node view の「戻す」。Esc（エディタに焦点がある時）で呼ぶ。
const openBars = new Set<() => boolean>();

/** 選択が image のキャプションの中にあるか（キャプションの文字を選んでいる時も含む）。 */
export function insideImage(state: any): boolean {
  const $from = state.selection.$from;
  if (state.selection instanceof NodeSelection) return false;
  for (let depth = $from.depth; depth > 0; depth -= 1) if ($from.node(depth).type.name === "image") return true;
  return false;
}

// 知らない id が来ても壊さない。**枠だけ出す**（読み込みの途中と、消された asset の両方がある）。
//
// WhyNot: width / height が attrs に無い時も `<img>` を素で置かない。URL が引けた直後は
// 読み込みが終わるまで 0×0 で、選んでいると outline の輪だけが見える。読み込み中は
// `is-loading` の枡を出し、失敗は `is-unknown` に落とす（`onerror` は src を変えた時に限る。
// Elm が同じ URL を渡し直しても失敗が消えない）。
function paintImage(box: HTMLElement, img: HTMLImageElement, note: HTMLElement, store: AssetStore, attrs: Record<string, unknown>) {
  const assetId = typeof attrs.assetId === "string" ? attrs.assetId : "";
  const found = store.get(assetId);
  const alt = typeof attrs.alt === "string" ? attrs.alt : found?.alt ?? "";
  const unknown = (text: string) => {
    img.hidden = true;
    note.hidden = false;
    note.textContent = text;
    box.classList.add("is-unknown");
    box.classList.remove("is-loading");
  };
  if (!found) {
    img.removeAttribute("src");
    unknown(assetId ? assetId : "（メディアが選ばれていません）");
    return;
  }
  const size = (name: string) => (typeof attrs[name] === "number" && (attrs[name] as number) > 0 ? String(attrs[name]) : null);
  const width = size("width");
  const height = size("height");
  if (width && height) {
    img.setAttribute("width", width);
    img.setAttribute("height", height);
  } else {
    img.removeAttribute("width");
    img.removeAttribute("height");
  }
  img.alt = alt;
  const failed = `${assetId} 読み込めませんでした`;
  if (img.dataset.failed === found.url) {
    unknown(failed);
    return;
  }
  if (img.getAttribute("src") !== found.url) {
    box.classList.toggle("is-loading", !(width && height));
    img.onload = () => box.classList.remove("is-loading");
    img.onerror = () => {
      img.dataset.failed = found.url;
      unknown(failed);
    };
    img.src = found.url;
  }
  img.hidden = false;
  note.hidden = true;
  box.classList.remove("is-unknown");
}

// 帯に入る 1 行の欄。書くのは 適用 / Enter の時だけで、blur では書かない（× と Esc は捨てる）。
function barInput(placeholder: string, className: string, url: boolean): HTMLInputElement {
  const input = document.createElement("input");
  input.type = "text";
  input.className = `tt-image-field ${className}`;
  input.placeholder = placeholder;
  input.setAttribute("aria-label", placeholder);
  if (url) {
    input.inputMode = "url";
    const mark = () => input.classList.toggle("is-bad", !isHttpUrl(input.value.trim()));
    input.addEventListener("input", mark);
  }
  return input;
}

export function imageNode(store: AssetStore) {
  return Node.create({
    name: "image",
    group: "block",
    // WhyNot: `inline*` にしない。hardBreak が入り、キャプションが 2 行になる（1 行の決まり）。
    content: "text*",
    marks: "link bold italic strike code",
    draggable: true,
    isolating: true,

    addAttributes() {
      return {
        assetId: { default: null },
        alt: { default: null },
        source: { default: null },
        sourceUrl: { default: null },
        width: { default: null },
        height: { default: null },
        href: { default: null },
        size: { default: null },
        align: { default: null },
      };
    },

    parseHTML() {
      return [
        { tag: "figure[data-asset-id]", contentElement: "figcaption" },
        { tag: "img[data-asset-id]" },
      ];
    },

    renderHTML({ HTMLAttributes }) {
      return ["figure", { "data-asset-id": String(HTMLAttributes.assetId ?? "") }, ["figcaption", 0]];
    },

    addKeyboardShortcuts() {
      const inCaption = () => insideImage(this.editor.state);
      const swallow = () => inCaption();
      // 上下の矢印でキャプションから画像の外の段落へ。
      const leave = (dir: -1 | 1) => () => {
        const state = this.editor.state;
        if (!inCaption()) return false;
        const $from = state.selection.$from;
        const pos = $from.before($from.depth);
        return leaveBlock(this.editor.view, pos, $from.node($from.depth).nodeSize, dir);
      };
      // 端で Backspace / Delete を素の動きに任せると、隣の段落と結合して画像が消える。
      const atEdge = (end: boolean) => () => {
        const state = this.editor.state;
        if (!inCaption() || !state.selection.empty) return false;
        const $from = state.selection.$from;
        return $from.parentOffset === (end ? $from.parent.content.size : 0);
      };
      return {
        Enter: swallow,
        "Shift-Enter": swallow,
        "Mod-Enter": swallow,
        ArrowUp: leave(-1),
        ArrowDown: leave(1),
        Backspace: atEdge(false),
        Delete: atEdge(true),
        // 配置の 3 つに入れ替わった帯を元に戻す（入力の欄の Esc は欄が自分で受ける）。
        Escape: () => {
          let handled = false;
          for (const back of openBars) if (back()) handled = true;
          return handled;
        },
      };
    },

    addProseMirrorPlugins() {
      return [
        new Plugin({
          key: new PluginKey("imageClick"),
          props: {
            // キャプションの外（画像そのもの）を押したら node ごと選ぶ。
            // atom でなくなったので、ProseMirror は押しても node を選ばない。
            handleClickOn(view: any, _pos: number, node: any, nodePos: number, event: MouseEvent) {
              if (node.type.name !== "image") return false;
              const target = event.target as HTMLElement | null;
              if (target?.closest("figcaption")) return false;
              view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, nodePos)));
              return true;
            },
          },
        }),
      ];
    },

    addNodeView() {
      return ({ node, getPos, editor }: ViewArgs) => {
        const dom = document.createElement("figure");
        dom.className = "tt-image";

        const img = document.createElement("img");
        const note = document.createElement("span");
        note.className = "tt-image-note";
        // キャプションは画像の直下の figcaption で、本文と同じ contentDOM。
        // 代替テキストは、画像の上に浮く帯（ALT）から。値があっても最初から開かない。
        //
        // WhyNot: 代替テキストを画像の下に並べない。note は画像の下に説明文の欄が 1 つだけで、
        // alt は画像の上の帯から開く別の操作。読んでいる間に読まない欄があると本文が
        // 間延びする（`docs/design/richtext-note-style.md` 6.4）。
        const caption = document.createElement("figcaption");
        caption.className = "tt-image-caption";
        // 出典は contentDOM の外。値がある時だけキャプションの下に「出典: …」と出し、押すと帯が 2 欄の入力になる。
        // 新しく付けるのは Markdown / API から（帯には無い。note の画像の帯にも無い）。
        const source = document.createElement("button");
        source.type = "button";
        source.className = "tt-image-source";
        source.hidden = true;

        // 画像の上に浮く帯。中身は mode で入れ替わる（帯の下に面を足さない。note と同じ）。
        //
        // WhyNot: 本文の流れに置かない。開く度に下の本文が押し下がる。
        const bar = document.createElement("div");
        bar.className = "tt-image-bar";
        bar.hidden = true;
        let mode: BarMode = "tools";

        const current = () => {
          const pos = getPos();
          if (pos === undefined) return null;
          const found = editor.view.state.doc.nodeAt(pos);
          return found ? { pos, node: found } : null;
        };
        const writeAll = (changes: Record<string, string | null>) => {
          const found = current();
          if (!found) return;
          const next = { ...found.node.attrs };
          let changed = false;
          for (const [name, value] of Object.entries(changes)) {
            const normalized = value === "" ? null : value;
            if ((found.node.attrs[name] ?? null) === normalized) continue;
            next[name] = normalized;
            changed = true;
          }
          if (!changed) return;
          const state = editor.view.state;
          const tr = state.tr.setNodeMarkup(found.pos, undefined, next);
          // node ごと選んだまま attrs を変えても、帯が消えないように選び直す（NodeSelection は写像で外れる事がある）。
          if (state.selection instanceof NodeSelection && state.selection.from === found.pos) tr.setSelection(NodeSelection.create(tr.doc, found.pos));
          editor.view.dispatch(tr);
        };

        // WhyNot: 帯を文字にしない。note と同じくアイコンで、語は title / aria-label に持つ
        // （文字だと帯が画像より横に広がる）。ALT だけは note と同じく英字のまま。
        const label = (button: HTMLButtonElement, title: string) => {
          button.title = title;
          button.setAttribute("aria-label", title);
        };
        const tool = (icon: string | null, title: string, onClick: () => void) => {
          const button = document.createElement("button");
          button.type = "button";
          button.className = icon ? "tt-image-tool tt-image-icon" : "tt-image-tool";
          if (icon) button.innerHTML = svg(icon, BAR_ICON);
          else button.textContent = "ALT";
          label(button, title);
          // mousedown を止めないと ProseMirror が node の選択を外し、帯ごと消える。
          button.addEventListener("mousedown", (event) => event.preventDefault());
          button.addEventListener("click", onClick);
          return button;
        };
        const setMode = (next: BarMode, refocus: boolean) => {
          mode = next;
          render();
          if (mode === "tools" && refocus) editor.view.focus();
        };

        // tools: リンク / ALT / 縮小 / 配置 / 横に並べる / 削除。
        const linkTool = tool(ICONS.link, "リンク", () => setMode("href", false));
        const altTool = tool(null, "代替テキスト", () => setMode("alt", false));
        const smallTool = tool(ICONS.shrink, "縮小", () => {
          const found = current();
          if (!found) return;
          writeAll({ size: found.node.attrs.size === SMALL ? null : SMALL });
          editor.view.focus();
        });
        const alignTool = tool(ICONS.alignCenter, "配置", () => setMode("align", false));
        // 単独の image が隣り合っている時だけ出す。押すと続きの image を 1 つの gallery に畳む。
        const rowTool = tool(ICONS.columns, "横に並べる", () => {
          const found = current();
          if (found) foldIntoGallery(editor.view, found.pos);
        });
        const trashTool = tool(ICONS.trash, "削除", () => {
          const found = current();
          if (!found) return;
          editor.view.dispatch(editor.view.state.tr.delete(found.pos, found.pos + found.node.nodeSize));
          editor.view.focus();
        });
        const tools = [linkTool, altTool, smallTool, alignTool, rowTool, trashTool];

        // align: 左 / 中央 / 右。押すと書いて tools に戻る。
        const alignButtons = ALIGNS.map(({ value, icon, title }) => {
          const button = tool(icon, title, () => {
            writeAll({ align: value });
            setMode("tools", true);
          });
          button.dataset.align = value ?? "center";
          return { value, button };
        });

        // 入力: 欄 + 適用 + ×。
        const altField = barInput("代替テキスト", "tt-image-alt", false);
        const hrefField = barInput("https://", "tt-image-href", true);
        const sourceField = barInput("出典", "tt-image-source-name", false);
        const sourceUrlField = barInput("出典の URL", "tt-image-source-url", true);
        const fieldsOf = (key: BarMode): Array<[HTMLInputElement, string]> =>
          key === "alt" ? [[altField, "alt"]] : key === "href" ? [[hrefField, "href"]] : key === "source" ? [[sourceField, "source"], [sourceUrlField, "sourceUrl"]] : [];
        const apply = document.createElement("button");
        apply.type = "button";
        apply.className = "tt-image-apply";
        apply.textContent = "適用";
        apply.addEventListener("mousedown", (event) => event.preventDefault());
        apply.addEventListener("click", () => commit());
        const close = document.createElement("button");
        close.type = "button";
        close.className = "tt-image-close";
        close.textContent = "×";
        label(close, "閉じる");
        close.addEventListener("mousedown", (event) => event.preventDefault());
        close.addEventListener("click", () => setMode("tools", true));
        const commit = () => {
          const changes: Record<string, string | null> = {};
          for (const [input, name] of fieldsOf(mode)) changes[name] = input.value.trim();
          writeAll(changes);
          setMode("tools", true);
        };
        // 欄の中のキーはエディタにも Elm（Esc で画面を閉じる）にも漏らさない。
        bar.addEventListener("keydown", (event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            setMode("tools", true);
            return;
          }
          if (!(event.target instanceof HTMLInputElement)) return;
          event.stopPropagation();
          if (event.key === "Enter") {
            event.preventDefault();
            commit();
          }
        });

        const inGallery = () => {
          const pos = getPos();
          return pos !== undefined && editor.view.state.doc.resolve(pos).parent.type.name === "gallery";
        };
        // 帯は node ごと選んでいる間か、tools 以外に入れ替わっている間（出典は選んでいなくても押せる）。
        const render = () => {
          const selected = dom.classList.contains("ProseMirror-selectednode");
          bar.hidden = !(selected || mode !== "tools");
          bar.classList.toggle("is-input", mode === "alt" || mode === "href" || mode === "source");
          if (mode === "tools") {
            bar.replaceChildren(...tools);
            const pos = getPos();
            if (pos === undefined) return;
            const gallery = inGallery();
            smallTool.hidden = gallery;
            alignTool.hidden = gallery;
            rowTool.hidden = gallery || adjacentImages(editor.view.state.doc.resolve(pos)).length < 2;
            return;
          }
          if (mode === "align") {
            bar.replaceChildren(...alignButtons.map((entry) => entry.button));
            (bar.querySelector<HTMLElement>(".is-on") ?? alignButtons[1].button).focus();
            return;
          }
          const fields = fieldsOf(mode);
          const found = current();
          for (const [input, name] of fields) input.value = typeof found?.node.attrs[name] === "string" ? found.node.attrs[name] : "";
          for (const [input] of fields) input.dispatchEvent(new Event("input"));
          bar.replaceChildren(...fields.map(([input]) => input), apply, close);
          fields[0][0].focus();
          fields[0][0].select();
        };
        const back = () => {
          if (mode === "tools") return false;
          setMode("tools", false);
          return true;
        };
        openBars.add(back);
        // 帯の外を押したら tools に戻す（帯と「出典: …」の中は除く）。
        const onOutside = (event: MouseEvent) => {
          if (mode === "tools") return;
          const target = event.target as globalThis.Node | null;
          if (target && (bar.contains(target) || source.contains(target))) return;
          setMode("tools", false);
        };
        document.addEventListener("mousedown", onOutside, true);
        source.addEventListener("mousedown", (event) => event.preventDefault());
        source.addEventListener("click", () => (mode === "source" ? setMode("tools", true) : setMode("source", false)));

        dom.append(bar, img, note, caption, source);

        const paint = (next: Record<string, unknown>) => {
          paintImage(dom, img, note, store, next);
          // 幅と寄せは data 属性で当てる（`.tt-image[data-size=small]` など）。
          const small = next.size === SMALL;
          if (small) dom.dataset.size = SMALL;
          else delete dom.dataset.size;
          const align = typeof next.align === "string" ? next.align : null;
          if (align) dom.dataset.align = align;
          else delete dom.dataset.align;
          // 縮小している間は同じボタンが「拡大」になる（押すと戻る）。
          smallTool.innerHTML = svg(small ? ICONS.expand : ICONS.shrink, BAR_ICON);
          label(smallTool, small ? "拡大" : "縮小");
          smallTool.classList.toggle("is-on", small);
          smallTool.setAttribute("aria-pressed", String(small));
          // 帯の配置のアイコンは今の寄せ。3 つに入れ替えた時は今の寄せが is-on。
          alignTool.innerHTML = svg(ALIGNS.find((entry) => entry.value === align)?.icon ?? ICONS.alignCenter, BAR_ICON);
          for (const entry of alignButtons) {
            entry.button.classList.toggle("is-on", entry.value === align);
            entry.button.setAttribute("aria-pressed", String(entry.value === align));
          }
          const linked = typeof next.href === "string" && next.href !== "";
          linkTool.classList.toggle("is-on", linked);
          linkTool.setAttribute("aria-pressed", String(linked));
          // 値が入っているリンク / ALT は緑（掛かっている印。縮小中・今の配置と同じ規則）。
          const hasAlt = typeof next.alt === "string" && next.alt !== "";
          altTool.classList.toggle("is-on", hasAlt);
          altTool.setAttribute("aria-pressed", String(hasAlt));
          // 出典は source か sourceUrl のどちらかがある時だけ。URL があればリンク風に見せる。
          const sourceText = typeof next.source === "string" ? next.source : "";
          const sourceUrl = typeof next.sourceUrl === "string" ? next.sourceUrl : "";
          source.hidden = sourceText === "" && sourceUrl === "";
          source.replaceChildren();
          if (!source.hidden) {
            const cite = document.createElement("cite");
            cite.textContent = sourceText !== "" ? sourceText : sourceUrl;
            source.append("出典: ", cite);
            source.classList.toggle("is-linked", sourceUrl !== "");
            source.title = sourceUrl !== "" ? sourceUrl : "出典";
          }
          if (mode === "tools") render();
        };

        paint(node.attrs);
        dom.classList.toggle("is-empty", node.childCount === 0);
        let attrs = node.attrs;
        const stop = store.watch(() => paint(attrs));

        // 選んでいる（node ごと、またはキャプションの中）間だけ placeholder を出す。
        // 隣の node が変わっても update は来ないので、ここで「横に並べる」も出し直す。
        const syncActive = () => {
          const pos = getPos();
          if (pos === undefined) return;
          const selection = editor.state.selection;
          const size = editor.state.doc.nodeAt(pos)?.nodeSize ?? 1;
          const active = selection.from >= pos && selection.to <= pos + size;
          dom.classList.toggle("is-active", active);
          if (mode === "tools") render();
        };
        editor.on("transaction", syncActive);
        syncActive();

        return {
          dom,
          contentDOM: caption,
          // 帯と出典はこちらが描く物なので、触っても doc は動かさない。キャプションの中は ProseMirror に渡す。
          ignoreMutation: (mutation: { type: string; target: globalThis.Node }) =>
            mutation.type !== "selection" ? !caption.contains(mutation.target) : false,
          stopEvent: (event: Event) => {
            const target = event.target as globalThis.Node;
            return bar.contains(target) || source.contains(target);
          },
          update(updated: any) {
            if (updated.type.name !== "image") return false;
            attrs = updated.attrs;
            paint(attrs);
            dom.classList.toggle("is-empty", updated.childCount === 0);
            return true;
          },
          selectNode() {
            dom.classList.add("ProseMirror-selectednode");
            render();
          },
          deselectNode() {
            dom.classList.remove("ProseMirror-selectednode");
            // 欄に焦点がある間は選択が外れても帯を残す（欄を押した時に一度外れる事がある）。
            if (!bar.contains(document.activeElement)) mode = "tools";
            render();
          },
          destroy() {
            stop();
            openBars.delete(back);
            editor.off("transaction", syncActive);
            document.removeEventListener("mousedown", onOutside, true);
          },
        };
      };
    },
  });
}

// `$pos` の指す image と、その前後に続く image の並び（doc の直下だけ）。
function adjacentImages($pos: any): Array<{ pos: number; node: any }> {
  const parent = $pos.parent;
  const index = $pos.index();
  const isImage = (i: number) => i >= 0 && i < parent.childCount && parent.child(i).type.name === "image";
  let first = index;
  while (isImage(first - 1)) first -= 1;
  let last = index;
  while (isImage(last + 1)) last += 1;
  const run: Array<{ pos: number; node: any }> = [];
  let pos = $pos.start() + Array.from({ length: first }, (_, i) => parent.child(i).nodeSize).reduce((a, b) => a + b, 0);
  for (let i = first; i <= last; i += 1) {
    run.push({ pos, node: parent.child(i) });
    pos += parent.child(i).nodeSize;
  }
  return run;
}

// 隣り合う image を 1 つの gallery に畳む。畳んだ後は先頭の 1 枚を選んだままにする。
function foldIntoGallery(view: any, pos: number) {
  const state = view.state;
  const $pos = state.doc.resolve(pos);
  const run = adjacentImages($pos);
  if (run.length < 2) return;
  const galleryType = state.schema.nodes.gallery;
  if (!galleryType) return;
  // gallery の中では効かない attrs は落とす（CMS は gallery の image に size / align を受けない）。
  const images = run.map((found) => found.node.type.create({ ...found.node.attrs, size: null, align: null }, found.node.content, found.node.marks));
  const from = run[0].pos;
  const to = run[run.length - 1].pos + run[run.length - 1].node.nodeSize;
  const tr = state.tr.replaceWith(from, to, galleryType.create({ columns: DEFAULT_COLUMNS }, images));
  tr.setSelection(NodeSelection.create(tr.doc, from + 1));
  view.dispatch(tr);
  view.focus();
}

export function galleryNode(store: AssetStore) {
  return Node.create({
    name: "gallery",
    group: "block",
    // WhyNot: `image+` にしない。最後の 1 枚を消せなくなる。空になった物は
    // 下の plugin が node ごと落とす（空の gallery は CMS が断る）。
    content: "image*",

    addAttributes() {
      return { columns: { default: null } };
    },

    parseHTML() {
      return [{ tag: "div[data-gallery]" }];
    },

    renderHTML() {
      return ["div", { "data-gallery": "" }, 0];
    },

    addNodeView() {
      return ({ node, getPos, editor }: ViewArgs) => {
        const dom = document.createElement("div");
        dom.className = "tt-gallery";

        // 列の数は**ブロックの上で選ぶ**（`web/code-block.ts` の言語と同じ置き方）。
        const bar = document.createElement("div");
        bar.className = "tt-gallery-bar";
        const select = document.createElement("select");
        select.className = "tt-gallery-cols";
        select.setAttribute("aria-label", "列の数");
        for (const count of COLUMNS) {
          const option = document.createElement("option");
          option.value = String(count);
          option.textContent = `${count} 列`;
          select.appendChild(option);
        }
        bar.appendChild(select);

        const grid = document.createElement("div");
        grid.className = "tt-gallery-grid";
        dom.append(bar, grid);

        const paint = (attrs: Record<string, unknown>) => {
          const columns = typeof attrs.columns === "number" ? attrs.columns : DEFAULT_COLUMNS;
          select.value = String(columns);
          grid.style.gridTemplateColumns = `repeat(${columns}, minmax(0, 1fr))`;
        };
        paint(node.attrs);

        select.addEventListener("mousedown", (event) => event.stopPropagation());
        select.addEventListener("change", () => {
          const pos = getPos();
          if (pos === undefined) return;
          const state = editor.view.state;
          const found = state.doc.nodeAt(pos);
          if (!found) return;
          editor.view.dispatch(state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, columns: Number(select.value) }));
        });

        return {
          dom,
          contentDOM: grid,
          update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
            if (updated.type.name !== "gallery") return false;
            paint(updated.attrs);
            return true;
          },
          // 上の帯はこちらが描く物なので、触っても doc は動かさない。
          ignoreMutation(mutation: { target: globalThis.Node }) {
            return bar.contains(mutation.target);
          },
          stopEvent(event: Event) {
            return bar.contains(event.target as globalThis.Node);
          },
        };
      };
    },

    addProseMirrorPlugins() {
      return [emptyGalleryPlugin()];
    },
  });
}

// 中身が 0 になった gallery を node ごと落とす。
function emptyGalleryPlugin() {
  return new Plugin({
    key: new PluginKey("galleryNotEmpty"),
    appendTransaction(transactions: readonly { docChanged: boolean }[], _old: any, next: any) {
      if (!transactions.some((transaction) => transaction.docChanged)) return null;
      const empties: Array<{ pos: number; size: number }> = [];
      next.doc.descendants((node: any, pos: number) => {
        if (node.type.name === "gallery" && node.childCount === 0) empties.push({ pos, size: node.nodeSize });
      });
      if (empties.length === 0) return null;
      const tr = next.tr;
      for (const found of empties.reverse()) tr.delete(tr.mapping.map(found.pos), tr.mapping.map(found.pos + found.size));
      return tr;
    },
  });
}

/** 送っている間の仮の見た目。**保存には出さない**（`unfold` が落とす）。 */
export const UploadingImage = Node.create({
  name: "uploading",
  group: "block",
  atom: true,

  addAttributes() {
    return { token: { default: null }, name: { default: null } };
  },

  parseHTML() {
    return [{ tag: "div[data-uploading]" }];
  },

  renderHTML() {
    return ["div", { "data-uploading": "" }];
  },

  addNodeView() {
    return ({ node }: ViewArgs) => {
      const dom = document.createElement("div");
      dom.className = "tt-uploading";
      const spinner = document.createElement("span");
      spinner.className = "tt-uploading-spin";
      const label = document.createElement("span");
      label.textContent = `${typeof node.attrs.name === "string" ? node.attrs.name : "画像"} を送信中…`;
      dom.append(spinner, label);
      return { dom };
    };
  },
});

function imageFilesOf(data: DataTransfer | null): File[] {
  if (!data) return [];
  return Array.from(data.files).filter((file) => file.type.startsWith("image/"));
}

/** 貼り付けとドロップで来た画像のファイルを外に渡す。 */
export function imageDropExtension(onFiles: (files: File[]) => void) {
  return Extension.create({
    name: "imageDrop",
    addProseMirrorPlugins() {
      return [
        new Plugin({
          key: new PluginKey("imageDrop"),
          props: {
            handlePaste(_view: unknown, event: ClipboardEvent) {
              const files = imageFilesOf(event.clipboardData);
              if (files.length === 0) return false;
              event.preventDefault();
              onFiles(files);
              return true;
            },
            handleDrop(view: any, event: DragEvent) {
              const files = imageFilesOf(event.dataTransfer);
              if (files.length === 0) return false;
              event.preventDefault();
              // 落とした所に入れる。カーソルを先に move してから積む。
              const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
              if (at) view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(at.pos))));
              onFiles(files);
              return true;
            },
          },
        }),
      ];
    },
  });
}

/** 選んだメディアを本文に入れる形。**2 枚以上は横並び（gallery）にする。** */
export function insertionOf(assetIds: string[]): Record<string, unknown> | null {
  const images = assetIds.filter((id) => id).map((id) => ({ type: "image", attrs: { assetId: id } }));
  if (images.length === 0) return null;
  if (images.length === 1) return images[0];
  return { type: "gallery", attrs: { columns: DEFAULT_COLUMNS }, content: images };
}

/**
 * 書く時に、キャプションの先頭と末尾の空白を落とす。空白だけなら中身を空にする。
 * WhyNot: CMS 側で trim しない。Markdown に写すと `* cap*` が箇条書きに見えるので、画面で落とした形を正とする。
 */
export function trimCaption(node: any): any {
  if (!node || typeof node !== "object" || node.type !== "image" || !Array.isArray(node.content)) return node;
  const content = node.content.map((child: any) => ({ ...child }));
  const cut = (index: number, pattern: RegExp) => {
    const child = content[index];
    if (!child || typeof child.text !== "string") return;
    child.text = child.text.replace(pattern, "");
  };
  while (content.length > 0) {
    cut(0, /^\s+/);
    if (content[0].text !== "") break;
    content.shift();
  }
  while (content.length > 0) {
    cut(content.length - 1, /\s+$/);
    if (content[content.length - 1].text !== "") break;
    content.pop();
  }
  return { ...node, content };
}

/** 旧い形（attrs.caption の文字列）を、読む時だけ中身（text）に写す。書く時は中身しか出さない。 */
export function liftCaption(node: any): any {
  if (!node || typeof node !== "object") return node;
  const next = Array.isArray(node.content) ? { ...node, content: node.content.map(liftCaption) } : { ...node };
  if (next.type !== "image" || typeof next.attrs?.caption !== "string") return next;
  const { caption, ...attrs } = next.attrs;
  const empty = !Array.isArray(next.content) || next.content.length === 0;
  return {
    ...next,
    attrs,
    content: empty && caption !== "" ? [{ type: "text", text: caption }] : next.content ?? [],
  };
}
