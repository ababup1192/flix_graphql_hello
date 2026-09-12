import "./graphiql-workers";
import { createRoot } from "react-dom/client";
import { GraphiQL } from "graphiql";
import { createGraphiQLFetcher } from "@graphiql/toolkit";
import { explorerPlugin } from "@graphiql/plugin-explorer";
import {
  buildClientSchema,
  getIntrospectionQuery,
  getNamedType,
  isEnumType,
  isObjectType,
  isScalarType,
  type GraphQLField,
  type GraphQLObjectType,
  type IntrospectionQuery,
} from "graphql";
import "graphiql/style.css";
import "@graphiql/plugin-explorer/style.css";

// プロジェクト slug は `?project=` で受ける。`/p/{slug}/graphiql` から書き換えるのは
// 配信側（vite dev の middleware / 本番の Caddy）の仕事で、この入口は URL の形を知らない。
// WhyNot: `?project=` だけを見ない。rewrite はサーバ側で起きるので、ブラウザの URL は
// `/p/{slug}/graphiql` のままで search が空になる（実機で slug が空になり、
// `/p//graphql` を叩いて「Error fetching schema」になった）。
function projectOf(location: Location): string {
  const fromQuery = new URLSearchParams(location.search).get("project");
  if (fromQuery) return fromQuery;
  const matched = /^\/p\/([^/]+)\/graphiql\/?$/.exec(location.pathname);
  return matched ? decodeURIComponent(matched[1]) : "";
}

const project = projectOf(window.location);
const endpoint = `/p/${encodeURIComponent(project)}/graphql`;

// WhyNot: 鍵を付けない。管理画面のホストは Access の内側で、cookie がそのまま身元になる
// （docs/design/admin-ui-spec.md 13.2）。公開サイト向けの API キーを試したい人は
// ヘッダの欄に `X-Api-Key` を書く。
const fetcher = createGraphiQLFetcher({
  url: endpoint,
  fetch: (input, init) => fetch(input, { ...init, credentials: "same-origin" }),
});

// 管理画面と同じ 3 状態を、同じ localStorage のキーで読む。GraphiQL 自身の
// テーマ設定は forcedTheme で隠す（画面ごとに別の明暗になるのを避ける）。
function themeOf(): "light" | "dark" | "system" {
  try {
    const t = localStorage.getItem("theme");
    return t === "light" || t === "dark" ? t : "system";
  } catch {
    return "system";
  }
}

// 既定の query。最初の型の一覧（`<plural>(first: 5) { nodes { id ... } }`）を、
// スキーマを introspection で読んで組む。root に一覧が無いプロジェクトは `{ __typename }`。
//
// WhyNot: SDL を決め打ちで書かない。コンテンツ API の型はプロジェクトごとに管理 API で
// 作られる物で、この入口が知れるのは introspection の結果だけ。
async function defaultQueryOf(): Promise<string> {
  const fallback = "{\n  __typename\n}";
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query: getIntrospectionQuery() }),
    });
    const body = (await response.json()) as { data?: IntrospectionQuery };
    if (!body.data) return fallback;
    const schema = buildClientSchema(body.data);
    const root = schema.getQueryType();
    if (!root) return fallback;
    const list = Object.values(root.getFields()).find((field) => field.args.some((arg) => arg.name === "first"));
    if (!list) return fallback;
    const rows = rowTypeOf(list);
    if (!rows) return fallback;
    const columns = Object.values(rows.getFields())
      .filter((field) => {
        const named = getNamedType(field.type);
        return (isScalarType(named) || isEnumType(named)) && field.args.length === 0;
      })
      .map((field) => field.name);
    const ordered = columns.includes("id") ? ["id", ...columns.filter((name) => name !== "id")] : columns;
    if (ordered.length === 0) return fallback;
    const selection = ordered.map((name) => `      ${name}`).join("\n");
    return `{\n  ${list.name}(first: 5) {\n    nodes {\n${selection}\n    }\n  }\n}`;
  } catch {
    return fallback;
  }
}

function rowTypeOf(list: GraphQLField<unknown, unknown>): GraphQLObjectType | null {
  const returned = getNamedType(list.type);
  if (!isObjectType(returned)) return null;
  const nodes = returned.getFields()["nodes"];
  if (!nodes) return returned;
  const row = getNamedType(nodes.type);
  return isObjectType(row) ? row : null;
}

function Band() {
  return (
    <div className="band">
      <strong>{project}</strong>
      <span className="note">
        公開中を読んでいます。下書きは <code>stage: DRAFT</code>（ログインした人の権限で読めます）
      </span>
      <a href={`/p/${encodeURIComponent(project)}/docs`}>リファレンス</a>
    </div>
  );
}

// 引き出しやリファレンスの「Explorer で開く」は `?query=` で query を渡す。
//
// WhyNot: `defaultQuery` に入れない。あれは保存済みのタブが無い時しか効かないので、
// 一度 GraphiQL を開いた人には渡した query が出ない（実機でそうなった）。
//
// WhyNot: `query` prop にしない。GraphiQL 5 で廃止されていて、渡すと画面が
// 真っ白になる（「The `query` prop has been removed. Use `initialQuery`」）。
const handedQuery = new URLSearchParams(window.location.search).get("query");

// チェックを入れて query を組む画面。`plugins` は組み込みのドキュメントと履歴に**足す**。
//
// WhyNot: App の中で作らない。プラグインは値で、描画のたびに作り直すと GraphiQL が
// 別のプラグインとして数え直し、開いている物が閉じる。
const explorer = explorerPlugin();

function App({ defaultQuery }: { defaultQuery: string }) {
  return (
    <>
      <Band />
      <GraphiQL
        fetcher={fetcher}
        plugins={[explorer]}
        {...(handedQuery ? { initialQuery: handedQuery } : {})}
        defaultQuery={defaultQuery}
        visiblePlugin="GraphiQL Explorer"
        forcedTheme={themeOf()}
        defaultEditorToolsVisibility="variables"
        shouldPersistHeaders
      />
    </>
  );
}

const root = document.getElementById("app");
if (root) {
  defaultQueryOf().then((defaultQuery) => {
    createRoot(root).render(<App defaultQuery={defaultQuery} />);
  });
}
