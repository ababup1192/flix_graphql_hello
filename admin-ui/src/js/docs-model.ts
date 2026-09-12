// コンテンツ API のリファレンス。introspection の JSON からセクションと HTML を組む純粋な部分。
// DOM も fetch も触らない（vitest で JSON を入れて文字列を見る）。

export type TypeRef = { kind: string; name: string | null; ofType?: TypeRef | null };

export type IntroInput = { name: string; description: string | null; defaultValue: string | null; type: TypeRef };

export type IntroField = { name: string; description: string | null; args: IntroInput[]; type: TypeRef };

export type IntroType = {
  kind: string;
  name: string;
  description: string | null;
  fields?: IntroField[] | null;
  inputFields?: IntroInput[] | null;
  enumValues?: { name: string; description: string | null }[] | null;
};

export type IntroSchema = { queryType: { name: string }; types: IntroType[] };

export type Group = "Queries" | "Objects" | "Input objects" | "Enums" | "Scalars";

export const groups: Group[] = ["Queries", "Objects", "Input objects", "Enums", "Scalars"];

export type Section =
  | { group: "Queries"; id: string; name: string; description: string | null; args: IntroInput[]; type: TypeRef; example: string }
  | { group: "Objects"; id: string; name: string; description: string | null; fields: IntroField[] }
  | { group: "Input objects"; id: string; name: string; description: string | null; inputFields: IntroInput[] }
  | { group: "Enums"; id: string; name: string; description: string | null; values: { name: string; description: string | null }[] }
  | { group: "Scalars"; id: string; name: string; description: string | null };

// ofType は 4 段しか取っていない。それより深い入れ子はスキーマの側で作れない（[[X!]!]! で 4 段）。
export const introspectionQuery = `query Reference {
  __schema {
    queryType { name }
    types {
      kind name description
      fields { name description args { ...Input } type { ...Ref } }
      inputFields { ...Input }
      enumValues { name description }
    }
  }
}
fragment Input on __InputValue { name description defaultValue type { ...Ref } }
fragment Ref on __Type { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } }`;

const byName = <T extends { name: string }>(a: T, b: T) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);

export function namedType(ref: TypeRef): string {
  return ref.name ?? (ref.ofType ? namedType(ref.ofType) : "");
}

// `[BlogOrderBy!]!` のような綴り。
export function typeRefText(ref: TypeRef): string {
  if (ref.kind === "NON_NULL" && ref.ofType) return `${typeRefText(ref.ofType)}!`;
  if (ref.kind === "LIST" && ref.ofType) return `[${typeRefText(ref.ofType)}]`;
  return ref.name ?? "";
}

// 同じ綴りで、名前の部分だけをそのセクションへのリンクにする（`[` `!` はリンクに入れない）。
export function typeRefHtml(ref: TypeRef, ids: ReadonlySet<string>): string {
  if (ref.kind === "NON_NULL" && ref.ofType) return `${typeRefHtml(ref.ofType, ids)}!`;
  if (ref.kind === "LIST" && ref.ofType) return `[${typeRefHtml(ref.ofType, ids)}]`;
  const name = ref.name ?? "";
  return ids.has(name) ? `<a href="#${escapeHtml(name)}">${escapeHtml(name)}</a>` : escapeHtml(name);
}

export function toSections(schema: IntroSchema): Section[] {
  const visible = schema.types.filter((t) => !t.name.startsWith("__"));
  const byTypeName = new Map(visible.map((t) => [t.name, t] as const));
  const query = byTypeName.get(schema.queryType.name);

  const queries: Section[] = [...(query?.fields ?? [])].sort(byName).map((f) => ({
    group: "Queries",
    id: `query-${f.name}`,
    name: f.name,
    description: f.description,
    args: f.args,
    type: f.type,
    example: exampleQuery(f, byTypeName),
  }));

  const objects: Section[] = visible
    .filter((t) => t.kind === "OBJECT" && t.name !== schema.queryType.name)
    .sort(byName)
    .map((t) => ({ group: "Objects", id: t.name, name: t.name, description: t.description, fields: [...(t.fields ?? [])].sort(byName) }));

  const inputs: Section[] = visible
    .filter((t) => t.kind === "INPUT_OBJECT")
    .sort(byName)
    .map((t) => ({ group: "Input objects", id: t.name, name: t.name, description: t.description, inputFields: [...(t.inputFields ?? [])].sort(byName) }));

  // enum の値は定義の順のまま（DRAFT → PUBLISHED のように順に意味がある）
  const enums: Section[] = visible
    .filter((t) => t.kind === "ENUM")
    .sort(byName)
    .map((t) => ({ group: "Enums", id: t.name, name: t.name, description: t.description, values: t.enumValues ?? [] }));

  const scalars: Section[] = visible
    .filter((t) => t.kind === "SCALAR")
    .sort(byName)
    .map((t) => ({ group: "Scalars", id: t.name, name: t.name, description: t.description }));

  return [...queries, ...objects, ...inputs, ...enums, ...scalars];
}

// ---- 例の query ----

// 1 つの型に対して選ぶフィールド。id と scalar / enum、RichText は { html }、Asset は { url }、
// id を持つ object（参照）は { id }。それ以外（OBJECT / BLOCKS の入れ子）は出さない。
function selectionOf(type: IntroType | undefined, byTypeName: Map<string, IntroType>): string[] {
  if (!type || type.kind !== "OBJECT") return [];
  const lines: string[] = [];
  for (const f of [...(type.fields ?? [])].sort((a, b) => (a.name === "id" ? -1 : b.name === "id" ? 1 : byName(a, b)))) {
    if (f.args.length > 0) continue;
    const target = byTypeName.get(namedType(f.type));
    if (!target) continue;
    if (target.kind === "SCALAR" || target.kind === "ENUM") lines.push(f.name);
    else if (target.name === "RichText") lines.push(`${f.name} { html }`);
    else if (target.name === "Asset") lines.push(`${f.name} { url }`);
    else if (target.kind === "OBJECT" && (target.fields ?? []).some((g) => g.name === "id")) lines.push(`${f.name} { id }`);
  }
  return lines;
}

function indent(lines: string[], depth: number): string {
  return lines.map((l) => "  ".repeat(depth) + l).join("\n");
}

export function exampleQuery(field: IntroField, byTypeName: Map<string, IntroType>): string {
  const returned = byTypeName.get(namedType(field.type));
  const hasFirst = field.args.some((a) => a.name === "first");
  const nodes = returned?.fields?.find((f) => f.name === "nodes");
  if (returned && hasFirst && nodes) {
    const body = selectionOf(byTypeName.get(namedType(nodes.type)), byTypeName);
    return [
      "query {",
      `  ${field.name}(first: 5) {`,
      "    totalCount",
      "    nodes {",
      indent(body, 3),
      "    }",
      "  }",
      "}",
    ].join("\n");
  }
  const call = field.args.some((a) => a.name === "id") ? `${field.name}(id: "<id>")` : field.name;
  const body = selectionOf(returned, byTypeName);
  if (body.length === 0) return `query {\n  ${call}\n}`;
  return ["query {", `  ${call} {`, indent(body, 2), "  }", "}"].join("\n");
}

export function explorerUrl(slug: string, query: string): string {
  return `/p/${encodeURIComponent(slug)}/graphiql?query=${encodeURIComponent(query)}`;
}

// ---- 検索 ----

// 型名・query 名・フィールド名・引数名・enum の値で当てる。description は見ない
// （日時の演算子の説明が 12 個同じ文で並び、何を打っても全部残る）。
export function filterSections(sections: Section[], raw: string): Section[] {
  const q = raw.trim().toLowerCase();
  if (q === "") return sections;
  const hit = (s: string) => s.toLowerCase().includes(q);
  return sections.filter((s) => {
    if (hit(s.name)) return true;
    switch (s.group) {
      case "Queries":
        return s.args.some((a) => hit(a.name));
      case "Objects":
        return s.fields.some((f) => hit(f.name) || f.args.some((a) => hit(a.name)));
      case "Input objects":
        return s.inputFields.some((f) => hit(f.name));
      case "Enums":
        return s.values.some((v) => hit(v.name));
      case "Scalars":
        return false;
    }
  });
}

// ---- HTML ----

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const desc = (d: string | null) => (d ? `<p class="docs-desc">${escapeHtml(d)}</p>` : "");
const cell = (d: string | null) => (d ? escapeHtml(d) : "");

export function renderToc(sections: Section[]): string {
  return groups
    .map((g) => {
      const items = sections.filter((s) => s.group === g);
      if (items.length === 0) return "";
      const links = items.map((s) => `<li><a href="#${escapeHtml(s.id)}">${escapeHtml(s.name)}</a></li>`).join("");
      return `<section class="docs-toc-group"><h2>${g}</h2><ul>${links}</ul></section>`;
    })
    .join("");
}

function argsTable(args: IntroInput[], ids: ReadonlySet<string>): string {
  const rows = args
    .map(
      (a) =>
        `<tr><td><code>${escapeHtml(a.name)}</code></td><td><code>${typeRefHtml(a.type, ids)}</code></td>` +
        `<td>${a.defaultValue === null ? "" : `<code>${escapeHtml(a.defaultValue)}</code>`}</td><td>${cell(a.description)}</td></tr>`,
    )
    .join("");
  return (
    `<table class="docs-args"><thead><tr><th>Name</th><th>Type</th><th>Default</th><th>Description</th></tr></thead>` +
    `<tbody>${rows}</tbody></table>`
  );
}

function heading(s: Section, label: string): string {
  return `<h2 id="${escapeHtml(s.id)}"><a class="docs-anchor" href="#${escapeHtml(s.id)}">${escapeHtml(s.name)}</a><span class="docs-kind">${label}</span></h2>`;
}

export function renderSection(s: Section, ids: ReadonlySet<string>, slug: string): string {
  switch (s.group) {
    case "Queries":
      return (
        `<section class="docs-section">${heading(s, "Query")}${desc(s.description)}` +
        `<p class="docs-returns">Type: <code>${typeRefHtml(s.type, ids)}</code></p>` +
        (s.args.length > 0 ? `<h3>Arguments</h3>${argsTable(s.args, ids)}` : "") +
        `<pre class="docs-example"><code>${escapeHtml(s.example)}</code></pre>` +
        `<p><a class="docs-explorer" href="${escapeHtml(explorerUrl(slug, s.example))}">Explorer で開く</a></p></section>`
      );
    case "Objects": {
      const rows = s.fields
        .map((f) => {
          const row =
            `<tr><td><code>${escapeHtml(f.name)}</code></td><td><code>${typeRefHtml(f.type, ids)}</code></td><td>${cell(f.description)}</td></tr>`;
          const args = f.args.length > 0 ? `<tr class="docs-args-row"><td colspan="3"><h4>Arguments</h4>${argsTable(f.args, ids)}</td></tr>` : "";
          return row + args;
        })
        .join("");
      return (
        `<section class="docs-section">${heading(s, "Object")}${desc(s.description)}<h3>Fields</h3>` +
        `<table class="docs-fields"><thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead><tbody>${rows}</tbody></table></section>`
      );
    }
    case "Input objects": {
      const rows = s.inputFields
        .map((f) => `<tr><td><code>${escapeHtml(f.name)}</code></td><td><code>${typeRefHtml(f.type, ids)}</code></td><td>${cell(f.description)}</td></tr>`)
        .join("");
      return (
        `<section class="docs-section">${heading(s, "Input object")}${desc(s.description)}<h3>Input fields</h3>` +
        `<table class="docs-fields"><thead><tr><th>Name</th><th>Type</th><th>Description</th></tr></thead><tbody>${rows}</tbody></table></section>`
      );
    }
    case "Enums": {
      const rows = s.values.map((v) => `<tr><td><code>${escapeHtml(v.name)}</code></td><td>${cell(v.description)}</td></tr>`).join("");
      return (
        `<section class="docs-section">${heading(s, "Enum")}${desc(s.description)}<h3>Values</h3>` +
        `<table class="docs-fields"><thead><tr><th>Value</th><th>Description</th></tr></thead><tbody>${rows}</tbody></table></section>`
      );
    }
    case "Scalars":
      return `<section class="docs-section">${heading(s, "Scalar")}${desc(s.description)}</section>`;
  }
}

export function renderBody(sections: Section[], slug: string): string {
  const ids = new Set(sections.map((s) => s.id));
  return groups
    .map((g) => {
      const items = sections.filter((s) => s.group === g);
      if (items.length === 0) return "";
      return `<section class="docs-group"><h1 id="group-${escapeHtml(g.replace(" ", "-"))}">${g}</h1>${items.map((s) => renderSection(s, ids, slug)).join("")}</section>`;
    })
    .join("");
}
