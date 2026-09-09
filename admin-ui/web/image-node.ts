// 本文の画像と、画像の横並び（gallery）。
//
// CMS の `image` は `assetId` を持つ node で、`src` は持たない
// （`src/cms/rules/RichText.flix`）。URL は asset の id から画面では引けないので、
// **Elm が `assets` の属性で id → URL の対応を渡す**。
//
// WhyNot: `@tiptap/extension-image` を使わない。あれは `src` を属性に持つ node で、
// 保存すると CMS が断る。属性を差し替えるより、`assetId` の node を自分で持つ方が
// 「保存できる形」と「画面に出る形」が 1 か所で揃う。
//
// WhyNot: 画像を上げる所でも API を叩かない。エディタは URL もヘッダも知らない
// （`web/link-dialog.ts` と同じ決まり）。ファイルは `mediaupload` の event で外に出す。

import { Node, Extension } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { leaveBlock } from "./block-edges";

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
  node: { attrs: Record<string, unknown>; type: { name: string } };
  getPos: () => number | undefined;
  editor: any;
};

// 知らない id が来ても壊さない。**枠だけ出す**（読み込みの途中と、消された asset の両方がある）。
function paintImage(box: HTMLElement, img: HTMLImageElement, note: HTMLElement, store: AssetStore, attrs: Record<string, unknown>) {
  const assetId = typeof attrs.assetId === "string" ? attrs.assetId : "";
  const found = store.get(assetId);
  const alt = typeof attrs.alt === "string" ? attrs.alt : found?.alt ?? "";
  if (found) {
    img.src = found.url;
    img.alt = alt;
    img.hidden = false;
    note.hidden = true;
    box.classList.remove("is-unknown");
  } else {
    img.removeAttribute("src");
    img.hidden = true;
    note.hidden = false;
    note.textContent = assetId ? assetId : "（メディアが選ばれていません）";
    box.classList.add("is-unknown");
  }
}

// 画像の下に付く 1 行の入力。打ち終わり（blur）と Enter で node に書く。
// 上下の矢印では、この欄から出て前後の行へ移る。
function noteInput(
  placeholder: string,
  className: string,
  onDone: (value: string) => void,
  onLeave: (dir: -1 | 1) => void
): HTMLInputElement {
  const input = document.createElement("input");
  input.type = "text";
  input.className = className;
  input.placeholder = placeholder;
  // WhyNot: input の度に書かない。1 文字ごとに doc が変わると undo が 1 文字ずつになり、
  // Elm への docchange も打鍵の数だけ飛ぶ。
  input.addEventListener("blur", () => onDone(input.value.trim()));
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      input.blur();
      return;
    }
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    onDone(input.value.trim());
    onLeave(event.key === "ArrowUp" ? -1 : 1);
  });
  return input;
}

export function imageNode(store: AssetStore) {
  return Node.create({
    name: "image",
    group: "block",
    atom: true,
    draggable: true,

    addAttributes() {
      return {
        assetId: { default: null },
        alt: { default: null },
        caption: { default: null },
        width: { default: null },
        height: { default: null },
      };
    },

    parseHTML() {
      return [{ tag: "img[data-asset-id]" }];
    },

    renderHTML({ HTMLAttributes }) {
      return ["img", { "data-asset-id": String(HTMLAttributes.assetId ?? "") }];
    },

    addNodeView() {
      return ({ node, getPos, editor }: ViewArgs) => {
        const dom = document.createElement("figure");
        dom.className = "tt-image";

        const img = document.createElement("img");
        const note = document.createElement("span");
        note.className = "tt-image-note";
        // 代替テキストは**その場で打つ**（CMS の image は attrs.alt を受ける）。
        //
        // WhyNot: キャプションの欄は置かない。ヘッドレス CMS の編集画面で画像の下に
        // キャプションを打たせる物は無い（microCMS・Contentful・Strapi・Sanity のどれも
        // 持たない。持っているのは Ghost・WordPress・Notion のような、見た目まで決める編集画面）。
        // `attrs.caption` は CMS 側に残してあるので、取り込んだ物は消えずに往復する。
        const alt = noteInput(
          "代替テキスト（読み上げ用）",
          "tt-image-alt",
          (value) => write("alt", value),
          (dir) => {
            const pos = getPos();
            if (pos === undefined) return;
            leaveBlock(editor.view, pos, editor.view.state.doc.nodeAt(pos)?.nodeSize ?? 1, dir);
          }
        );
        dom.append(img, note, alt);

        const write = (name: string, value: string) => {
          const pos = getPos();
          if (pos === undefined) return;
          const found = editor.view.state.doc.nodeAt(pos);
          if (!found) return;
          editor.view.dispatch(
            editor.view.state.tr.setNodeMarkup(pos, undefined, { ...found.attrs, [name]: value === "" ? null : value })
          );
        };

        const paint = (next: Record<string, unknown>) => {
          paintImage(dom, img, note, store, next);
          const altText = typeof next.alt === "string" ? next.alt : "";
          if (document.activeElement !== alt) alt.value = altText;
        };

        paint(node.attrs);
        let attrs = node.attrs;
        const stop = store.watch(() => paint(attrs));

        return {
          dom,
          // 打っている間に node の中身を作り直させない（1 文字ごとにフォーカスが飛ぶ）。
          ignoreMutation: () => true,
          stopEvent: (event: Event) => event.target === alt,
          update(updated: { type: { name: string }; attrs: Record<string, unknown> }) {
            if (updated.type.name !== "image") return false;
            attrs = updated.attrs;
            paint(attrs);
            return true;
          },
          destroy() {
            stop();
          },
        };
      };
    },
  });
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
      label.textContent = `${typeof node.attrs.name === "string" ? node.attrs.name : "画像"} を送っています…`;
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
