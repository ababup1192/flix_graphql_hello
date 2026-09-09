// stress-seed.mjs が作った物を消す。/tmp/ui-stress/made.json を読む。
import fs from "node:fs";
import { gql } from "./stress-lib.mjs";

const made = JSON.parse(fs.readFileSync("/tmp/ui-stress/made.json", "utf8"));
const tryGql = async (what, q, v) => {
  try {
    await gql(q, v);
    return true;
  } catch (e) {
    console.log(`  残った ${what}: ${String(e.message).slice(0, 140)}`);
    return false;
  }
};

for (const id of made.schedules ?? [])
  await tryGql(`schedule ${id}`, `mutation ($i: ID!) { cancelSchedule(id: $i) { id } }`, { i: id });
for (const id of made.entries ?? [])
  await tryGql(`entry ${id}`, `mutation ($i: ID!) { deleteEntry(id: $i) }`, { i: id });
for (const id of made.assets ?? [])
  await tryGql(`asset ${id}`, `mutation ($i: ID!) { deleteAsset(id: $i) }`, { i: id });
for (const id of made.fields ?? [])
  await tryGql(`field ${id}`, `mutation ($i: ID!) { removeField(id: $i) }`, { i: id });
for (const id of made.types ?? [])
  await tryGql(`type ${id}`, `mutation ($i: ID!) { deleteContentType(id: $i) }`, { i: id });

for (const id of made.projects ?? []) {
  const r = await fetch("http://localhost:8080/account/graphql", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": "dev@localhost" },
    body: JSON.stringify({ query: `mutation ($i: ID!) { deleteProject(id: $i) }`, variables: { i: id } }),
  }).then((x) => x.json());
  if (r.errors) console.log(`  残った project ${id}: ${JSON.stringify(r.errors).slice(0, 160)}`);
}

// 残りを確かめる
const left = await gql(`{ contentTypes { apiId } assets(first: 300) { nodes { id fileName } } }`);
console.log(
  "残った型:",
  left.contentTypes.map((t) => t.apiId).join(","),
  "/ 残った zz-stress の asset:",
  left.assets.nodes.filter((a) => a.fileName.startsWith("zz-stress")).length,
);
for (const t of ["blogs", "tags", "authors"]) {
  const ty = left.contentTypes.find((x) => x.apiId === t);
  if (!ty) continue;
}
const counts = await gql(`{ contentTypes { apiId } }`);
console.log("型の数:", counts.contentTypes.length);
