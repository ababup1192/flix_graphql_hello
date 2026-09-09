const q = async (s) =>
  (await fetch("http://localhost:8080/p/default/admin/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
    body: JSON.stringify({ query: s }),
  })).json();
const types = (await q("{ contentTypes { id apiId } }")).data.contentTypes;
let gone = 0;
for (const type of types) {
  const page = await q(`{ entries(typeId: ${JSON.stringify(type.id)}, first: 200) { nodes { id fields } } }`);
  for (const node of page.data.entries.nodes) {
    const title = String(node.fields?.title ?? node.fields?.name ?? "");
    if (/^(code-check|link-check|math-check|smoke-test|smoke-rich|手動保存の確認)/.test(title)) {
      const r = await q(`mutation { deleteEntry(id: ${JSON.stringify(node.id)}) }`);
      if (r.data) gone += 1;
      else console.log("  消せない:", title, JSON.stringify(r.errors).slice(0, 120));
    }
  }
}
console.log("消した:", gone, "件");
