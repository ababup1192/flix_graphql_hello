import { describe, expect, test } from "vitest";
import {
  exampleQuery,
  explorerUrl,
  filterSections,
  renderSection,
  renderToc,
  toSections,
  typeRefHtml,
  typeRefText,
  type IntroSchema,
  type IntroType,
  type TypeRef,
} from "../../src/js/docs-model";

const nn = (inner: TypeRef): TypeRef => ({ kind: "NON_NULL", name: null, ofType: inner });
const list = (inner: TypeRef): TypeRef => ({ kind: "LIST", name: null, ofType: inner });
const named = (kind: string, name: string): TypeRef => ({ kind, name, ofType: null });
const scalar = (name: string) => named("SCALAR", name);
const obj = (name: string) => named("OBJECT", name);

// 小さな見本。Blog（一覧と 1 件）、Author（参照先）、RichText、Asset、enum、input、`_types`。
const schema: IntroSchema = {
  queryType: { name: "Query" },
  types: [
    {
      kind: "OBJECT",
      name: "Query",
      description: null,
      fields: [
        { name: "blogs", description: "一覧", args: [
          { name: "first", description: "件数", defaultValue: "20", type: scalar("Int") },
          { name: "orderBy", description: null, defaultValue: null, type: list(nn(named("INPUT_OBJECT", "BlogOrderBy"))) },
        ], type: nn(obj("BlogConnection")) },
        { name: "blog", description: "1 件", args: [{ name: "id", description: null, defaultValue: null, type: nn(scalar("ID")) }], type: obj("Blog") },
        { name: "_types", description: "型の数", args: [], type: nn(scalar("Int")) },
        { name: "about", description: "singleton", args: [], type: obj("About") },
      ],
    },
    { kind: "OBJECT", name: "BlogConnection", description: "1 ページ", fields: [
      { name: "totalCount", description: null, args: [], type: nn(scalar("Int")) },
      { name: "nodes", description: null, args: [], type: nn(list(nn(obj("Blog")))) },
    ] },
    { kind: "OBJECT", name: "Blog", description: "ブログ", fields: [
      { name: "title", description: "題", args: [], type: nn(scalar("String")) },
      { name: "id", description: null, args: [], type: nn(scalar("ID")) },
      { name: "body", description: null, args: [], type: obj("RichText") },
      { name: "eyecatch", description: null, args: [], type: obj("Asset") },
      { name: "author", description: null, args: [], type: obj("Author") },
      { name: "meta", description: null, args: [], type: obj("Meta") },
      { name: "status", description: null, args: [], type: nn(named("ENUM", "Stage")) },
    ] },
    { kind: "OBJECT", name: "About", description: null, fields: [{ name: "id", description: null, args: [], type: nn(scalar("ID")) }] },
    { kind: "OBJECT", name: "Author", description: null, fields: [{ name: "id", description: null, args: [], type: nn(scalar("ID")) }] },
    { kind: "OBJECT", name: "Meta", description: null, fields: [{ name: "note", description: null, args: [], type: scalar("String") }] },
    { kind: "OBJECT", name: "RichText", description: null, fields: [{ name: "html", description: null, args: [], type: nn(scalar("String")) }] },
    { kind: "OBJECT", name: "Asset", description: null, fields: [{ name: "url", description: null, args: [], type: nn(scalar("String")) }] },
    { kind: "INPUT_OBJECT", name: "BlogOrderBy", description: "並べ替え", inputFields: [
      { name: "field", description: null, defaultValue: null, type: nn(scalar("String")) },
      { name: "direction", description: null, defaultValue: "ASC", type: named("ENUM", "Direction") },
    ] },
    { kind: "ENUM", name: "Stage", description: null, enumValues: [{ name: "PUBLISHED", description: "公開中" }, { name: "DRAFT", description: "下書き" }] },
    { kind: "ENUM", name: "Direction", description: null, enumValues: [{ name: "ASC", description: null }] },
    { kind: "SCALAR", name: "String", description: "文字列" },
    { kind: "SCALAR", name: "Int", description: null },
    { kind: "SCALAR", name: "ID", description: null },
    { kind: "OBJECT", name: "__Schema", description: null, fields: [] },
    { kind: "SCALAR", name: "__TypeKind", description: null },
  ],
};

const sections = toSections(schema);
const byTypeName = new Map(schema.types.map((t) => [t.name, t] as const));
const ids = new Set(sections.map((s) => s.id));

describe("toSections", () => {
  test("Queries → Objects → Input objects → Enums → Scalars の順で、各グループの中はアルファベット順", () => {
    expect(sections.map((s) => `${s.group}:${s.name}`)).toEqual([
      "Queries:_types", "Queries:about", "Queries:blog", "Queries:blogs",
      "Objects:About", "Objects:Asset", "Objects:Author", "Objects:Blog", "Objects:BlogConnection", "Objects:Meta", "Objects:RichText",
      "Input objects:BlogOrderBy",
      "Enums:Direction", "Enums:Stage",
      "Scalars:ID", "Scalars:Int", "Scalars:String",
    ]);
  });

  test("__ で始まる型は出さない", () => {
    expect(sections.some((s) => s.name.startsWith("__"))).toBe(false);
  });

  test("Query 型そのものは Objects に入れない", () => {
    expect(sections.filter((s) => s.group === "Objects").map((s) => s.name)).not.toContain("Query");
  });

  test("Objects のフィールドはアルファベット順", () => {
    const blog = sections.find((s) => s.group === "Objects" && s.name === "Blog");
    expect(blog?.group === "Objects" ? blog.fields.map((f) => f.name) : []).toEqual(["author", "body", "eyecatch", "id", "meta", "status", "title"]);
  });

  test("enum の値は定義の順のまま", () => {
    const stage = sections.find((s) => s.group === "Enums" && s.name === "Stage");
    expect(stage?.group === "Enums" ? stage.values.map((v) => v.name) : []).toEqual(["PUBLISHED", "DRAFT"]);
  });
});

describe("typeRef", () => {
  test("[BlogOrderBy!]! の綴り", () => {
    expect(typeRefText(nn(list(nn(named("INPUT_OBJECT", "BlogOrderBy")))))).toBe("[BlogOrderBy!]!");
  });

  test("名前の部分だけがリンクになる", () => {
    expect(typeRefHtml(nn(list(nn(named("INPUT_OBJECT", "BlogOrderBy")))), ids)).toBe('[<a href="#BlogOrderBy">BlogOrderBy</a>!]!');
  });

  test("セクションの無い名前はリンクにしない", () => {
    expect(typeRefHtml(nn(scalar("Unknown")), ids)).toBe("Unknown!");
  });
});

describe("exampleQuery", () => {
  const queryFields = (byTypeName.get("Query") as IntroType).fields ?? [];
  const field = (name: string) => queryFields.find((f) => f.name === name)!;

  test("一覧は first: 5 と totalCount / nodes。id を先頭に、scalar・enum はそのまま、RichText は { html }、Asset は { url }、参照は { id }、入れ子は出さない", () => {
    expect(exampleQuery(field("blogs"), byTypeName)).toBe(
      ["query {", "  blogs(first: 5) {", "    totalCount", "    nodes {", "      id", "      author { id }", "      body { html }", "      eyecatch { url }", "      status", "      title", "    }", "  }", "}"].join("\n"),
    );
  });

  test('1 件は id: "<id>"', () => {
    expect(exampleQuery(field("blog"), byTypeName)).toBe(
      ["query {", '  blog(id: "<id>") {', "    id", "    author { id }", "    body { html }", "    eyecatch { url }", "    status", "    title", "  }", "}"].join("\n"),
    );
  });

  test("singleton は引数無しで呼ぶ", () => {
    expect(exampleQuery(field("about"), byTypeName)).toBe(["query {", "  about {", "    id", "  }", "}"].join("\n"));
  });

  test("scalar を返す query は選択を持たない", () => {
    expect(exampleQuery(field("_types"), byTypeName)).toBe("query {\n  _types\n}");
  });

  test("Explorer の URL は query を URL エンコードして渡す", () => {
    expect(explorerUrl("blog-example", "query {\n  _types\n}")).toBe("/p/blog-example/graphiql?query=query%20%7B%0A%20%20_types%0A%7D");
  });
});

describe("filterSections", () => {
  test("フィールド名で当たった型だけ残る（大文字小文字は見ない）", () => {
    expect(filterSections(sections, "EYECATCH").map((s) => s.name)).toEqual(["Blog"]);
  });

  test("型名でも query 名でも当たる", () => {
    expect(filterSections(sections, "blog").map((s) => `${s.group}:${s.name}`)).toEqual([
      "Queries:blog", "Queries:blogs", "Objects:Blog", "Objects:BlogConnection", "Input objects:BlogOrderBy",
    ]);
  });

  test("enum の値でも当たる", () => {
    expect(filterSections(sections, "draft").map((s) => s.name)).toEqual(["Stage"]);
  });

  test("空欄なら全部", () => {
    expect(filterSections(sections, "  ").length).toBe(sections.length);
  });
});

describe("render", () => {
  test("目次はグループの見出しの下に型名を並べる", () => {
    expect(renderToc(sections.filter((s) => s.group === "Enums"))).toBe(
      '<section class="docs-toc-group"><h2>Enums</h2><ul><li><a href="#Direction">Direction</a></li><li><a href="#Stage">Stage</a></li></ul></section>',
    );
  });

  test("Objects の引数があるフィールドの下に Arguments の表が付く", () => {
    const withArgs = toSections({
      queryType: { name: "Query" },
      types: [
        { kind: "OBJECT", name: "Query", description: null, fields: [] },
        { kind: "OBJECT", name: "Post", description: null, fields: [
          { name: "tags", description: "タグ", args: [{ name: "first", description: "件数", defaultValue: "10", type: scalar("Int") }], type: nn(list(nn(scalar("String")))) },
        ] },
        { kind: "SCALAR", name: "Int", description: null },
        { kind: "SCALAR", name: "String", description: null },
      ],
    });
    const post = withArgs.find((s) => s.name === "Post")!;
    expect(renderSection(post, new Set(withArgs.map((s) => s.id)), "x")).toBe(
      '<section class="docs-section"><h2 id="Post"><a class="docs-anchor" href="#Post">Post</a><span class="docs-kind">Object</span></h2><h3>Fields</h3>' +
        '<table class="docs-fields"><thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead><tbody>' +
        '<tr><td><code>tags</code></td><td><code>[<a href="#String">String</a>!]!</code></td><td>タグ</td></tr>' +
        '<tr class="docs-args-row"><td colspan="3"><h4>Arguments</h4><table class="docs-args"><thead><tr><th>Name</th><th>Type</th><th>Default</th><th>Description</th></tr></thead>' +
        '<tbody><tr><td><code>first</code></td><td><code><a href="#Int">Int</a></code></td><td><code>10</code></td><td>件数</td></tr></tbody></table></td></tr>' +
        "</tbody></table></section>",
    );
  });

  test("description の < は escape する", () => {
    const s = toSections({ queryType: { name: "Query" }, types: [
      { kind: "OBJECT", name: "Query", description: null, fields: [] },
      { kind: "SCALAR", name: "Int", description: "<b>" },
    ] }).find((x) => x.name === "Int")!;
    expect(renderSection(s, new Set(["Int"]), "x")).toContain("&lt;b&gt;");
  });

  test("query のセクションは Explorer へのリンクで終わる", () => {
    const q = sections.find((s) => s.group === "Queries" && s.name === "_types")!;
    expect(renderSection(q, ids, "blog-example")).toContain('<a class="docs-explorer" href="/p/blog-example/graphiql?query=query%20%7B%0A%20%20_types%0A%7D">Explorer で開く</a>');
  });
});
