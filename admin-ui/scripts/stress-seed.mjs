// 可変長の中身を積む。作った物の id は /tmp/ui-stress/made.json に残し、
// scripts/stress-clean.mjs が消す。見本のデータ（blogs 20 / authors 5 / tags 8）は触らない。
import zlib from "node:zlib";
import fs from "node:fs";
import { gql } from "./stress-lib.mjs";

fs.mkdirSync("/tmp/ui-stress", { recursive: true });
const made = { entries: [], types: [], fields: [], assets: [], schedules: [], projects: [] };
const save = () => fs.writeFileSync("/tmp/ui-stress/made.json", JSON.stringify(made, null, 1));

const types = (await gql(`{ contentTypes { id apiId fields { id apiId } } }`)).contentTypes;
const byId = Object.fromEntries(types.map((t) => [t.apiId, t]));

const rep = (s, n) => s.repeat(Math.ceil(n / s.length)).slice(0, n);
const jaLong = rep("あのイーハトーヴォのすきとおった風夏でも底に冷たさをもつ青いそら", 100);
const enLong =
  "Supercalifragilisticexpialidocious" +
  "Pneumonoultramicroscopicsilicovolcanoconiosis" +
  "Antidisestablishmentarianism";

// blogs は title 60 文字までの検査が入っているので、長さを試す型は自分で作る。
async function makeType(apiId, name, icon) {
  const r = await gql(`mutation ($i: ContentTypeInput!) { createContentType(input: $i) { id } }`, {
    i: { apiId, name, icon, singular: `Zz${apiId.slice(8)}One`, plural: `zz${apiId.slice(8)}List` },
  });
  made.types.push(r.createContentType.id);
  save();
  return r.createContentType.id;
}
async function addField(typeId, input) {
  const r = await gql(`mutation ($t: ID!, $i: FieldInput!) { addField(typeId: $t, input: $i) { id } }`, {
    t: typeId,
    i: input,
  });
  made.fields.push(r.addField.id);
  save();
  return r.addField.id;
}
async function entryIn(typeId, fields, publish = false) {
  const e = await gql(`mutation ($t: ID!, $f: JSON!) { createEntry(typeId: $t, fields: $f) { id } }`, {
    t: typeId,
    f: fields,
  });
  const id = e.createEntry.id;
  made.entries.push(id);
  save();
  if (publish) await gql(`mutation ($i: ID!) { publishEntry(id: $i, withDependencies: true) { id } }`, { i: id });
  return id;
}

console.log("タグの型…");
const tagType = await makeType("zzstresstag", "zz ストレス タグ", "tag");
await addField(tagType, { apiId: "name", name: "名前", kind: "TEXT" });

console.log("記事の型…");
const artType = await makeType("zzstressart", rep("とても長い API の表示名です", 60), "list");
await addField(artType, { apiId: "title", name: rep("とても長いフィールドの表示名", 50), kind: "TEXT" });
await addField(artType, { apiId: "body", name: "本文", kind: "TEXT_AREA" });
await addField(artType, { apiId: "tags", name: "タグ", kind: "REFERENCE", many: true, targetTypeId: tagType });

console.log("タグ 20 個…");
const tagIds = [];
for (let i = 0; i < 20; i += 1) {
  const name = i < 4 ? `${rep("とても長いタグの名前です", 40)}${i}` : `zz-stress-tag-${i}`;
  tagIds.push(await entryIn(tagType, { name }, true));
}

console.log("長いタイトル…");
const jaEntry = await entryIn(artType, { title: jaLong, body: rep("長い本文。", 400) });
const enEntry = await entryIn(artType, { title: enLong.slice(0, 100), body: enLong });
const manyTags = await entryIn(artType, { title: "zz-stress タグ 20 個", tags: tagIds });

// ---- 3. 40 フィールドの型（表示名も長い） ----
console.log("40 フィールドの型…");
const wideType = await makeType("zzstresswide", rep("とても長い API の表示名です", 60), "list");
const kinds = ["TEXT", "TEXT_AREA", "NUMBER", "BOOLEAN", "DATE", "TEXT"];
for (let i = 0; i < 40; i += 1) {
  await addField(wideType, {
    apiId: `f${i}`,
    name: i < 4 ? `${rep("とても長いフィールドの表示名", 50)}${i}` : `フィールド ${i}`,
    kind: kinds[i % kinds.length],
    required: i % 7 === 0,
    many: false,
  });
}

// ---- 4. フィールド 0 個・中身 0 件の型 ----
await makeType("zzstressempty", "zz 空っぽ", "list");

// ---- 5. 変更履歴 30 版 ----
console.log("履歴 30 版…");
let ver = (await gql(`query ($i: ID!) { entry(id: $i) { version } }`, { i: jaEntry })).entry.version;
for (let i = 0; i < 30; i += 1) {
  const r = await gql(
    `mutation ($i: ID!, $f: JSON!, $v: Int!) { updateEntry(id: $i, fields: $f, expectedVersion: $v) { version } }`,
    { i: jaEntry, f: { title: jaLong, body: `長い本文 ${i}` }, v: ver },
  );
  ver = r.updateEntry.version;
  await gql(`mutation ($i: ID!) { saveVersion(id: $i) { id } }`, { i: jaEntry });
}

// ---- 6. 予約を複数 ----
console.log("予約…");
for (let i = 1; i <= 4; i += 1) {
  const at = new Date(Date.now() + i * 86400000).toISOString().replace(/\.\d+Z$/, "Z");
  const s = await gql(`mutation ($e: ID!, $a: String!) { schedulePublish(entryId: $e, at: $a) { id } }`, {
    e: enEntry,
    a: at,
  });
  made.schedules.push(s.schedulePublish.id);
}
save();

// ---- 7. メディア 200 枚（1 枚はファイル名が長い） ----
const CRC = (() => {
  const t = [];
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
const crc32 = (b) => {
  let c = 0xffffffff;
  for (const x of b) c = CRC[(c ^ x) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const h = Buffer.alloc(8);
  h.writeUInt32BE(data.length, 0);
  h.write(type, 4, "ascii");
  const c = Buffer.alloc(4);
  c.writeUInt32BE(crc32(Buffer.concat([h.subarray(4), data])), 0);
  return Buffer.concat([h, data, c]);
};
const png = (w, h, rgb) => {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  let at = 0;
  for (let y = 0; y < h; y += 1) {
    at += 1;
    for (let x = 0; x < w; x += 1) {
      raw[at] = rgb[0];
      raw[at + 1] = rgb[1];
      raw[at + 2] = rgb[2];
      at += 3;
    }
  }
  const hd = Buffer.alloc(13);
  hd.writeUInt32BE(w, 0);
  hd.writeUInt32BE(h, 4);
  hd[8] = 8;
  hd[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", hd),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
};
async function upload(fileName, bytes) {
  const m = await gql(
    `mutation ($i: UploadInput!) { createUploadUrl(input: $i) { asset { id } uploadUrl } }`,
    { i: { fileName, mime: "image/png", size: bytes.length } },
  );
  await fetch(m.createUploadUrl.uploadUrl, {
    method: "PUT",
    headers: { "Content-Type": "image/png" },
    body: bytes,
  });
  made.assets.push(m.createUploadUrl.asset.id);
  await gql(`mutation ($i: ID!, $p: AssetConfirmInput) { confirmAsset(id: $i, input: $p) { id } }`, {
    i: m.createUploadUrl.asset.id,
    p: { width: 64, height: 48, alt: "zz-stress" },
  });
}

const count = Number(process.env.ASSETS ?? 200);
console.log(`メディア ${count} 枚…`);
await upload(
  `zz-stress-${rep("very-long-file-name-without-any-break-opportunity-", 140)}.png`,
  png(64, 48, [200, 80, 80]),
);
save();
for (let i = 0; i < count - 1; i += 1) {
  await upload(`zz-stress-${String(i).padStart(3, "0")}.png`, png(64, 48, [(i * 7) % 256, 120, 200]));
  if (i % 25 === 0) save();
}
save();

// プロジェクトは account API に delete が無いので作らない（画面側で差し替えて見る）。

console.log("できました", JSON.stringify({ ...made, assets: made.assets.length }, null, 1));
console.log("jaEntry", jaEntry, "enEntry", enEntry, "manyTags", manyTags);
fs.writeFileSync(
  "/tmp/ui-stress/keys.json",
  JSON.stringify({ jaEntry, enEntry, manyTags, art: "zzstressart", tag: "zzstresstag", wide: "zzstresswide", empty: "zzstressempty" }),
);
