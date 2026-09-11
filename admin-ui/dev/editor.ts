// 開発用のエディタの画面。**CMS のサーバもログインも要らない。**
//
// Elm の本体がやっている繋ぎ（メディアを選ぶ、上げる、リンクを決める、
// 指しているコンテンツを引く、OGP を取る）を、その場で答える偽物に差し替える。
// 手元だけで開く物で、本番のビルドには入らない（vite.config.ts の localOnly）。
import "katex/dist/katex.min.css";
import "../src/styles.css";
import "../web/tiptap-editor";
import { FIXTURES, fixtureOf } from "./fixtures";

// 偽の asset。**外へ取りに行かない**（手元だけで動く事が開発用の画面の値打ち）。
const swatch = (label: string, color: string) =>
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="${color}"/><text x="400" y="270" font-family="sans-serif" font-size="64" fill="#fff" text-anchor="middle">${label}</text></svg>`,
  );

const ASSETS = [
  { id: "asset-1", url: swatch("1", "#3b6ea5"), alt: "偽の画像 1" },
  { id: "asset-2", url: swatch("2", "#a55b3b"), alt: "偽の画像 2" },
  { id: "asset-3", url: swatch("3", "#3ba56e"), alt: "偽の画像 3" },
  { id: "asset-4", url: swatch("4", "#6e3ba5"), alt: "偽の画像 4" },
];

const editor = document.querySelector("tiptap-editor") as HTMLElement & { linkchoice?: unknown };
const state = document.getElementById("state") as HTMLSelectElement;
const json = document.getElementById("json") as HTMLPreElement;
const picker = document.getElementById("picker") as HTMLElement;
const linkRow = document.getElementById("link-row") as HTMLElement;
const linkInput = document.getElementById("link-href") as HTMLInputElement;
const upload = document.getElementById("upload") as HTMLInputElement;

let insertSeq = 0;
let linkSeq = 0;

function load(name: string) {
  const fixture = fixtureOf(name);
  state.value = fixture.name;
  editor.setAttribute("doc", JSON.stringify(fixture.doc));
  show(JSON.stringify(fixture.doc));
  const url = new URL(window.location.href);
  url.searchParams.set("doc", fixture.name);
  window.history.replaceState(null, "", url);
}

function show(text: string) {
  try {
    json.textContent = JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    json.textContent = text;
  }
}

for (const fixture of FIXTURES) {
  const option = document.createElement("option");
  option.value = fixture.name;
  option.textContent = fixture.title;
  state.appendChild(option);
}
state.addEventListener("change", () => load(state.value));

// 偽のメディアの画面。押した 1 枚（Shift で足す）を `insert` の属性で渡す。
const chosen = new Set<string>();
for (const asset of ASSETS) {
  const button = document.createElement("button");
  button.type = "button";
  button.dataset.assetId = asset.id;
  const image = document.createElement("img");
  image.src = asset.url;
  image.alt = asset.alt;
  button.appendChild(image);
  button.addEventListener("click", (event) => {
    if (!event.shiftKey) chosen.clear();
    chosen.add(asset.id);
    insertSeq += 1;
    editor.setAttribute("insert", JSON.stringify({ seq: insertSeq, assetIds: [...chosen] }));
    picker.hidden = true;
    chosen.clear();
  });
  picker.appendChild(button);
}

editor.setAttribute("assets", JSON.stringify(ASSETS));
editor.setAttribute("uploadinput", upload.id);

editor.addEventListener("mediapick", () => {
  picker.hidden = !picker.hidden;
});

// 上げるのは偽物なので、その場で終わった事にする。
editor.addEventListener("mediaupload", (event) => {
  const token = (event as CustomEvent).detail?.token;
  const file = upload.files?.[0];
  const asset = { id: `upload-${token}`, url: file ? URL.createObjectURL(file) : swatch("上", "#555"), alt: file?.name ?? "" };
  ASSETS.push(asset);
  editor.setAttribute("assets", JSON.stringify(ASSETS));
  upload.value = "";
  editor.setAttribute("resolved", JSON.stringify([{ token, assetId: asset.id }]));
});

// 指しているコンテンツ。偽の題を返す。
editor.addEventListener("linkresolve", (event) => {
  const ids = ((event as CustomEvent).detail ?? []) as string[];
  editor.setAttribute(
    "linked",
    JSON.stringify(ids.map((id) => ({ id, title: `偽のコンテンツ ${id}`, type: "blog", stageName: "公開中", path: `/blog/${id}` }))),
  );
});

// OGP。相手のサイトを読みに行かず、URL から作る。**溜める。**
// 属性は一覧を丸ごと受けるので、その回の分だけ渡すと前のカードが消える。
const cards = new Map<string, unknown>();

function card(url: string) {
  let host = url;
  try {
    host = new URL(url).host;
  } catch {
    // URL になっていない物はそのまま題にする。
  }
  return { url, title: `偽のページ（${host}）`, description: "開発用の画面が作った偽の説明です。", image: "", siteName: host };
}

for (const name of ["linkcardlookup", "linkcardfetch"]) {
  editor.addEventListener(name, (event) => {
    const detail = (event as CustomEvent).detail;
    const urls = Array.isArray(detail) ? detail : [detail];
    for (const url of urls) cards.set(url, card(url));
    editor.setAttribute("cards", JSON.stringify([...cards.values()]));
  });
}

// リンクの面。Elm の Ui.Link の代わりに、下の欄で受ける。
editor.addEventListener("linkopen", (event) => {
  const detail = (event as CustomEvent).detail;
  linkSeq = detail?.seq ?? 0;
  linkInput.value = detail?.href ?? "";
  linkRow.hidden = false;
  linkInput.focus();
});

function decide(remove: boolean, cancel: boolean) {
  linkRow.hidden = true;
  editor.linkchoice = { seq: linkSeq, href: linkInput.value, entryId: "", label: "", remove, cancel };
}

document.getElementById("link-ok")!.addEventListener("click", () => decide(false, false));
document.getElementById("link-remove")!.addEventListener("click", () => decide(true, false));
document.getElementById("link-cancel")!.addEventListener("click", () => decide(false, true));

editor.addEventListener("docchange", (event) => show((event as CustomEvent).detail ?? ""));

load(new URL(window.location.href).searchParams.get("doc") ?? "empty");
