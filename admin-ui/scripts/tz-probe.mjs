const admin = "http://localhost:8080/p/default/admin/graphql";
const gql = async (q) => (await fetch(admin, { method: "POST", headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" }, body: JSON.stringify({ query: q }) })).json();
const t = (await gql(`{ contentTypes { id apiId } }`)).data.contentTypes.find((x) => x.apiId === "blogs");
const one = (await gql(`{ entries(typeId: ${JSON.stringify(t.id)}, first: 1) { nodes { id } } }`)).data.entries.nodes[0];

console.log("--- 予約の at に何を受けるか ---");
for (const at of ["2027-01-15T09:00:00Z", "2027-01-15T18:00:00+09:00", "2027-01-15T09:00:00", "2027-01-15"]) {
  const r = await gql(`mutation { schedulePublish(entryId: ${JSON.stringify(one.id)}, at: ${JSON.stringify(at)}) { id runAt status } }`);
  console.log(`  ${at.padEnd(28)} → ${r.data ? "runAt=" + r.data.schedulePublish.runAt : (r.errors?.[0]?.message ?? "").slice(0, 70)}`);
}
// 片付け
const rows = (await gql(`{ schedules(entryId: ${JSON.stringify(one.id)}) { id status } }`)).data.schedules;
for (const s of rows) if (s.status === "PENDING") await gql(`mutation { cancelSchedule(id: ${JSON.stringify(s.id)}) }`);
console.log("  （予約は取り消しました）");

console.log("--- DATE のフィールドは何を返すか ---");
const cur = (await gql(`{ entry(id: ${JSON.stringify(one.id)}) { version fields } }`)).data.entry;
for (const v of ["2027-03-05", "2027-03-05T18:00:00+09:00", "2027-03-05T09:00:00Z"]) {
  const now = (await gql(`{ entry(id: ${JSON.stringify(one.id)}) { version } }`)).data.entry.version;
  const r = await gql(`mutation { updateEntry(id: ${JSON.stringify(one.id)}, fields: { publishAt: ${JSON.stringify(v)} }, expectedVersion: ${now}) { fields } }`);
  console.log(`  ${v.padEnd(28)} → ${r.data ? JSON.stringify(r.data.updateEntry.fields.publishAt) : (r.errors?.[0]?.message ?? "").slice(0, 70)}`);
}
// 元に戻す
const now = (await gql(`{ entry(id: ${JSON.stringify(one.id)}) { version } }`)).data.entry.version;
await gql(`mutation { updateEntry(id: ${JSON.stringify(one.id)}, fields: { publishAt: ${JSON.stringify(cur.fields.publishAt)} }, expectedVersion: ${now}) { id } }`);
console.log("  （元に戻しました）");
