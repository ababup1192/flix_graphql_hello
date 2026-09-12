// コンテンツ API のリファレンス（/p/{slug}/docs）。vite の別の入口で、Elm を持たない。
// 開いた時にブラウザが introspection を 1 回投げ、docs-model の純粋な関数で描く。
import "../styles.css";
import "../docs.css";
import { filterSections, introspectionQuery, renderBody, renderToc, toSections, type IntroSchema, type Section } from "./docs-model";

// dev は `?project=` への rewrite、本番も同じ。URL の /p/{slug}/docs からも読めるようにしておく
// （rewrite の無い配信で index が開いてしまった時に、どこから来たかは残る）。
function slugOf(location: Location): string | null {
  const fromQuery = new URLSearchParams(location.search).get("project");
  if (fromQuery) return fromQuery;
  const m = /^\/p\/([^/]+)\/docs\/?$/.exec(location.pathname);
  return m ? decodeURIComponent(m[1]) : null;
}

const escape = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function shell(slug: string, main: string): string {
  return (
    `<header class="docs-bar"><span class="docs-slug">${escape(slug)}</span>` +
    `<span class="docs-note">introspection から生成。型は API スキーマの定義で変わります</span>` +
    `<a class="docs-bar-link" href="/p/${encodeURIComponent(slug)}/graphiql">Explorer（GraphiQL）</a></header>` +
    `<div class="docs-layout"><nav class="docs-side"><input id="docs-search" class="docs-search" type="search" placeholder="型名・フィールド名で検索" autocomplete="off" />` +
    `<div id="docs-toc"></div></nav><main class="docs-main" id="docs-main">${main}</main></div>`
  );
}

async function fetchSchema(slug: string): Promise<IntroSchema> {
  const response = await fetch(`/p/${encodeURIComponent(slug)}/graphql`, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query: introspectionQuery }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const json = (await response.json()) as { data?: { __schema?: IntroSchema }; errors?: { message: string }[] };
  if (!json.data?.__schema) throw new Error(json.errors?.map((e) => e.message).join(" / ") ?? "応答に __schema がありません");
  return json.data.__schema;
}

function wireSearch(root: HTMLElement, sections: Section[]) {
  const toc = root.querySelector<HTMLElement>("#docs-toc");
  const input = root.querySelector<HTMLInputElement>("#docs-search");
  if (!toc || !input) return;
  const draw = () => {
    const shown = filterSections(sections, input.value);
    toc.innerHTML = shown.length > 0 ? renderToc(shown) : `<p class="docs-empty">見つかりません</p>`;
  };
  input.addEventListener("input", draw);
  draw();
}

async function main() {
  const root = document.getElementById("docs");
  if (!root) return;
  const slug = slugOf(window.location);
  if (!slug) {
    root.innerHTML = `<main class="docs-main"><p class="docs-empty">プロジェクトが指定されていません。/p/{slug}/docs から開いてください</p></main>`;
    return;
  }
  document.title = `${slug} - API リファレンス`;
  root.innerHTML = shell(slug, `<p class="docs-empty">読み込み中…</p>`);
  try {
    const sections = toSections(await fetchSchema(slug));
    const main = root.querySelector<HTMLElement>("#docs-main");
    if (main) main.innerHTML = renderBody(sections, slug);
    wireSearch(root, sections);
    // 描く前に hash があった時は、描いた後にその位置へ送る
    if (window.location.hash) document.getElementById(decodeURIComponent(window.location.hash.slice(1)))?.scrollIntoView();
  } catch (e) {
    const main = root.querySelector<HTMLElement>("#docs-main");
    if (main) main.innerHTML = `<p class="docs-error">スキーマを取得できませんでした（${escape(e instanceof Error ? e.message : String(e))}）</p>`;
  }
}

void main();
