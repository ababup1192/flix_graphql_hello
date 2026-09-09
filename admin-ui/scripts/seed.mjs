// 技術ブログの見本データを入れる。手で触って確かめるための物で、本番には使わない。
//
// 使い方: CMS を上げてから  npm run seed
// 入れる物: 著者 5 件 / タグ 8 件 / ブログ 20 件（公開・下書き・変更ありが混ざる）と、画像。
//
// **コンテンツどうしの繋がりと、メディアを両方入れる**（管理画面で確かめる時に、
// 参照が 1 対 1 だけ・画像が 1 枚も無い、では足りない）。
//
//   - タグは**コンテンツ**（`tags` の型）。ブログから REFERENCE の複数で繋ぐ
//   - 著者はブログから REFERENCE の 1 件で繋ぐ
//   - ブログにアイキャッチ（ASSET 1 枚）と本文中の図（ASSET の複数）
//   - 著者に顔写真（ASSET 1 枚）
//
// **もう一度走らせる時は先に片付ける**（`--reset` を付けると、同じ apiId の型と中身を消してから入れる）。

import zlib from "node:zlib";

const base = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
const project = process.env.CMS_PROJECT ?? "default";
const devUser = process.env.VITE_DEV_USER ?? "dev@localhost";

async function call(kind, query) {
  const response = await fetch(`${base}/p/${project}/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": devUser },
    body: JSON.stringify({ query }),
  });
  const body = await response.json();
  if (body.errors) {
    const first = body.errors[0];
    const violations = first.extensions?.violations?.map((v) => `${v.field ?? v.path}: ${v.message}`).join(" / ") ?? "";
    throw new Error(`${kind}: ${first.message} ${violations}`);
  }
  return body.data;
}

// enum は引用符なしで出す（GraphQL の EnumValue）。
class Enum {
  constructor(name) {
    this.name = name;
  }
}

const enumValue = (name) => new Enum(name);

// GraphQL のオブジェクトリテラルにする（キーは引用符なし）。
function literal(value) {
  if (value === null || value === undefined) return "null";
  if (value instanceof Enum) return value.name;
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return `[${value.map(literal).join(", ")}]`;
  return `{${Object.entries(value).map(([key, inner]) => `${key}: ${literal(inner)}`).join(", ")}}`;
}

const reset = process.argv.includes("--reset");


// 同じ apiId の型があれば、中身ごと消す。
async function clear(apiId) {
  const found = await call("contentTypes", `query contentTypes { contentTypes { id apiId } }`);
  const type = found.contentTypes.find((item) => item.apiId === apiId);
  if (!type) return;

  for (let round = 0; round < 6; round += 1) {
    const page = await call("entries", `query entries { entries(typeId: ${JSON.stringify(type.id)}, first: 200) { nodes { id } } }`);
    if (page.entries.nodes.length === 0) break;
    for (const node of page.entries.nodes) {
      await call("deleteEntry", `mutation deleteEntry { deleteEntry(id: ${JSON.stringify(node.id)}) }`);
    }
  }
  await call("deleteContentType", `mutation deleteContentType { deleteContentType(id: ${JSON.stringify(type.id)}) }`);
  console.log(`  片付けました: ${apiId}`);
}


async function createType(apiId, name, icon) {
  const input = literal(icon ? { apiId, name, icon } : { apiId, name });
  const data = await call("createContentType", `mutation createContentType { createContentType(input: ${input}) { id apiId } }`);
  console.log(`  API を作りました: ${name} (${apiId})`);
  return data.createContentType.id;
}

async function addField(typeId, input) {
  await call("addField", `mutation addField { addField(typeId: ${JSON.stringify(typeId)}, input: ${literal(input)}) { apiId } }`);
}

async function createEntry(typeId, fields) {
  const data = await call("createEntry", `mutation createEntry { createEntry(typeId: ${JSON.stringify(typeId)}, fields: ${literal(fields)}) { id } }`);
  return data.createEntry.id;
}

// ---- 画像を作って置く ----
//
// 依存を増やさずに PNG を作る。**見本に本物の画像が要る**（メディアの画面も
// アイキャッチの表示も、実物が無いと確かめられない）。zlib は Node が持っている。

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

function png(width, height, pixel) {
  const raw = Buffer.alloc((width * 3 + 1) * height);
  let at = 0;
  for (let y = 0; y < height; y += 1) {
    raw[at] = 0;
    at += 1;
    for (let x = 0; x < width; x += 1) {
      const [r, g, b] = pixel(x, y);
      raw[at] = r;
      raw[at + 1] = g;
      raw[at + 2] = b;
      at += 3;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// 斜めのグラデーション。色は種で決めるので、同じ記事は毎回同じ絵になる。
function cover(seed, width, height) {
  const a = [(seed * 53) % 160, (seed * 97) % 120, 140 + ((seed * 31) % 110)];
  const b = [30 + ((seed * 17) % 60), 40 + ((seed * 41) % 80), 70 + ((seed * 71) % 90)];
  return png(width, height, (x, y) => {
    const t = (x / width + y / height) / 2;
    return [
      Math.round(a[0] * (1 - t) + b[0] * t),
      Math.round(a[1] * (1 - t) + b[1] * t),
      Math.round(a[2] * (1 - t) + b[2] * t),
    ];
  });
}

async function upload(fileName, bytes, { width, height, alt }) {
  const made = await call(
    "createUploadUrl",
    `mutation createUploadUrl { createUploadUrl(input: ${literal({ fileName, mime: "image/png", size: bytes.length })}) { asset { id } uploadUrl } }`
  );
  const put = await fetch(made.createUploadUrl.uploadUrl, {
    method: "PUT",
    headers: { "Content-Type": "image/png" },
    body: bytes,
  });
  if (!put.ok) throw new Error(`置けませんでした: ${fileName} (${put.status})`);
  const id = made.createUploadUrl.asset.id;
  await call(
    "confirmAsset",
    `mutation confirmAsset { confirmAsset(id: ${JSON.stringify(id)}, input: ${literal({ width, height, alt })}) { id status } }`
  );
  return id;
}

// 今ある asset を全部消す。**entry が使っていると消せない**ので、entry を消した後に呼ぶ。
async function clearAssets() {
  const page = await call("assets", `query assets { assets(first: 200) { nodes { id } } }`);
  for (const node of page.assets.nodes) {
    try {
      await call("deleteAsset", `mutation deleteAsset { deleteAsset(id: ${JSON.stringify(node.id)}) }`);
    } catch (error) {
      // 手で入れた物が残っていても止めない。
      console.log(`  消せませんでした: ${node.id}`);
    }
  }
}

async function publish(entryId) {
  await call("publishEntry", `mutation publishEntry { publishEntry(id: ${JSON.stringify(entryId)}, withDependencies: true) { id stage } }`);
}

// 段落と見出しから doc を組む。
function doc(blocks) {
  return {
    type: "doc",
    content: blocks.map((block) =>
      block.startsWith("## ")
        ? { type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: block.slice(3) }] }
        : { type: "paragraph", content: [{ type: "text", text: block }] }
    ),
  };
}

// タグは**コンテンツ**にする。SELECT の選択肢だと UPPER_SNAKE しか置けず、
// 説明も付けられない（docs/design/admin-ui-spec.md 10.2 の `optionLabels`）。
// コンテンツにすれば、名前も説明も自由に書けて、後からタグだけを一覧で直せる。
const TAGS = [
  { slug: "flix", name: "Flix", description: "JVM の上で動く関数型言語。algebraic effect を持つ。" },
  { slug: "graphql", name: "GraphQL", description: "この CMS の API の形。管理 API とコンテンツ API の 2 本。" },
  { slug: "postgresql", name: "PostgreSQL", description: "RLS でテナントを分けている。JSONB に entry の中身を持つ。" },
  { slug: "elm", name: "Elm", description: "管理画面の言語。副作用は Effect の値にしてテストする。" },
  { slug: "ops", name: "運用", description: "落ちない仕組みより、落ちても戻る仕組み。" },
  { slug: "design", name: "設計", description: "決めた事と、決めなかった理由。" },
  { slug: "testing", name: "テスト", description: "純粋な規則はテストファースト。実 PG は後付け。" },
  { slug: "performance", name: "性能", description: "N+1、ETag、接続プール。計測してから直す。" },
];

const AUTHORS = [
  { name: "あばば", title: "CMS の作者", bio: "Flix で headless CMS を書いています。大規模システムの運用が長く、最近は Elm で管理画面を作っています。" },
  { name: "きたむら", title: "バックエンド", bio: "PostgreSQL と JVM の性能まわりを見ています。障害の再現と計測が好きです。" },
  { name: "みやざき", title: "フロントエンド", bio: "Elm と TypeScript。型で守れる範囲を広げるのが趣味です。" },
  { name: "さいとう", title: "SRE", bio: "落ちない仕組みより、落ちても戻る仕組みを作ります。" },
  { name: "たなか", title: "テクニカルライター", bio: "書く人が迷わない書き味を追いかけています。" },
];

const POSTS = [
  ["Flix の algebraic effect で Tx の境界を書く", ["flix", "design"], 0, "PUBLISHED", 12,
    ["## なぜ effect か", "Flix の algebraic effect は、DB の Tx のように「開いて閉じる」物を型で表せる。handler を入れる場所を型が強制するので、閉じ忘れがコンパイルで落ちる。",
     "## handler を入れる場所", "Tx を開く関数の中だけに handler を置く。外に出すと、業務エラーを受けた時に COMMIT と ROLLBACK が飛ぶ。"]],
  ["graphql-java を Flix から叩く", ["flix", "graphql"], 2, "CHANGED", 9,
    ["## Java interop の勘所", "Flix には GraphQL の実装が無いので、JVM の上で動く利点を活かして graphql-java を借りる。",
     "## VerifyError に注意", "リゾルバのラムダに effect を使う式を直に書くと JVM の VerifyError になる。関数に切り出す。"]],
  ["RLS でテナントを三重に守る", ["postgresql", "design"], 1, "PUBLISHED", 14,
    ["## 三重の意味", "型（effect）・生成器・DB の RLS の三段で守る。どれか 1 つが抜けても他が止める。",
     "## 印は Tx の先頭で", "BEGIN の直後にプロジェクトの印を置く。印の無い Tx は中身の表が 0 行になる。"]],
  ["接続プールが壊れたまま戻らない時に自分で終わる", ["ops", "postgresql"], 3, "PUBLISHED", 11,
    ["## 満杯と故障を分ける", "借りられないのが「混んでいる」だけなのか「壊れている」のかを、最後に接続が返った時刻で見分ける。",
     "## 終わって再起動させる", "直せないと分かったら drain して exit する。docker が起こし直す。"]],
  ["1 リクエスト 1 行の構造化ログにする", ["ops"], 3, "PUBLISHED", 8,
    ["## 行が増えると読めない", "1 リクエストで何行も出すと、grep しても筋が追えない。属性を足して 1 行にまとめる。",
     "## request id で繋ぐ", "受けた id を応答にも返し、クライアントの申告からログを引けるようにする。"]],
  ["Elm の Effect 型でテストできる副作用にする", ["elm", "testing"], 2, "PUBLISHED", 10,
    ["## Cmd を返さない", "update が Cmd を返すと中身が見えず、「どの操作で何が飛ぶか」を検査できない。",
     "## perform は 1 か所", "Cmd にするのは perform だけ。テストは同じ値を SimulatedEffect に写す。"]],
  ["elm-graphql は variables を使わない", ["elm", "graphql"], 2, "PUBLISHED", 7,
    ["## 引数は document に埋まる", "生成されるクエリは引数をリテラルで持つ。richText の doc もそのまま入る。",
     "## パーサの上限に当たる", "graphql-java の既定はトークン 15,000。長い記事で当たるので上げておく。"]],
  ["予約公開をチャンクで回す", ["ops", "performance"], 1, "PUBLISHED", 6,
    ["## 1 回の tick の予算", "100 件ずつ拾い、10 秒の予算に達するまで繰り返す。満杯でない claim で終わる。"]],
  ["outbox で二重配信を避ける", ["design", "postgresql"], 1, "PUBLISHED", 9,
    ["## 業務の Tx で積む", "配信の行を業務と同じ Tx で積み、tick が FOR UPDATE SKIP LOCKED で拾う。複数台でも二重にならない。"]],
  ["ETag で GraphQL の GET を返さない", ["performance", "graphql"], 3, "PUBLISHED", 8,
    ["## 版と query の sha", "プロジェクトの版とクエリの sha から弱い ETag を組む。合えば実行せずに 304。"]],
  ["richText の doc を Markdown と往復させる", ["design"], 4, "PUBLISHED", 13,
    ["## 方言を決める", "GFM に alerts と id と asset: と entry: を足した物にした。自前のパーサで依存を増やさない。"]],
  ["フィールドの種類を後から変えない", ["design"], 0, "PUBLISHED", 5,
    ["## 変えられない理由", "既にある値の意味が変わる。作る時に伝えて、変えたい時は新しいフィールドを足す。"]],
  ["テストは純粋な規則から書く", ["testing", "design"], 4, "PUBLISHED", 7,
    ["## 表駆動で書く", "入力と期待の表にすると、境界の抜けが目で見える。"]],
  ["JVM の例外で接続が漏れる話", ["ops", "postgresql"], 1, "PUBLISHED", 10,
    ["## finally が無い", "withLazyTx の catch は内側に handler が入ると素通りされる。guard を一番内側に置く。"]],
  ["SIGTERM で drain してから閉じる", ["ops"], 3, "CHANGED", 6,
    ["## 順番が全部", "listen を閉じる → 接続を待つ → 仕事を drain → プールを閉じる。間に合わなければ終了コードで伝える。"]],
  ["Datalog で役割から権限を出す", ["design", "flix"], 0, "PUBLISHED", 9,
    ["## 判定を 1 か所に", "役割と権限の対応を Datalog に置き、画面もサーバも同じ答えを見る。"]],
  ["管理画面の一覧の状態を URL に持つ", ["elm", "design"], 2, "DRAFT", 6,
    ["## 共有できる一覧", "絞り込みと並びを URL に持つと、そのまま人に渡せる。戻っても消えない。"]],
  ["TipTap を Web Component に包む", ["elm"], 2, "DRAFT", 8,
    ["## Elm は知らなくていい", "doc を属性で渡し、変わったら event で返す。Elm 側に TipTap は出てこない。"]],
  ["MCP で管理画面と同じ物を AI に見せる", ["graphql", "design"], 0, "PUBLISHED", 11,
    ["## 隠し API を作らない", "MCP のツールは管理 API の薄い写しにする。足りない物は SDL に足す。"]],
  ["Playwright で自分の画面を触る", ["testing", "elm"], 2, "DRAFT", 5,
    ["## 人が見つける前に", "画面を実際に開いて、詰まりと JS の例外を先に見つける。"]],
];

// CMS は UTC の秒までの形しか受けない（ミリ秒付きは INVALID）。
const day = (index) => {
  const date = new Date(Date.UTC(2026, 7, 1 + index, 9, 0, 0));
  return date.toISOString().replace(/\.\d+Z$/, "Z");
};

console.log("見本データを入れます");

if (reset) {
  // **参照している側から消す。** ブログが著者とタグを参照しているので、ブログが先。
  await clear("blogs");
  await clear("authors");
  await clear("tags");
  // asset は entry が使っている間は消せないので、entry を消した後に。
  await clearAssets();
}

// ---- タグ（コンテンツ） ----

const tagTypeId = await createType("tags", "タグ", "tag");
await addField(tagTypeId, { apiId: "name", name: "名前", kind: enumValue("TEXT"), required: true, config: { maxLength: 24 } });
await addField(tagTypeId, { apiId: "slug", name: "スラッグ", kind: enumValue("SLUG"), required: true, unique: true, config: { sourceField: "name" } });
await addField(tagTypeId, { apiId: "description", name: "説明", kind: enumValue("TEXT_AREA"), config: { maxLength: 100 } });

const tagIds = {};
for (const tag of TAGS) {
  const id = await createEntry(tagTypeId, { name: tag.name, slug: tag.slug, description: tag.description });
  await publish(id);
  tagIds[tag.slug] = id;
}
console.log(`  タグ ${TAGS.length} 件（コンテンツ）`);

// ---- 著者（顔写真つき） ----

const authorTypeId = await createType("authors", "著者", "user");
await addField(authorTypeId, { apiId: "name", name: "名前", kind: enumValue("TEXT"), required: true });
await addField(authorTypeId, { apiId: "title", name: "肩書", kind: enumValue("TEXT") });
await addField(authorTypeId, { apiId: "bio", name: "自己紹介", kind: enumValue("TEXT_AREA") });
await addField(authorTypeId, { apiId: "avatar", name: "顔写真", kind: enumValue("ASSET") });

const authorIds = [];
for (const [index, author] of AUTHORS.entries()) {
  const avatar = await upload(`avatar-${index + 1}.png`, cover(index * 7 + 3, 160, 160), {
    width: 160,
    height: 160,
    alt: `${author.name} の顔写真`,
  });
  const id = await createEntry(authorTypeId, {
    name: author.name,
    title: author.title,
    bio: author.bio,
    avatar,
  });
  await publish(id);
  authorIds.push(id);
}
console.log(`  著者 ${authorIds.length} 件（顔写真つき）`);

const blogTypeId = await createType("blogs", "ブログ", "book");
await addField(blogTypeId, { apiId: "title", name: "タイトル", kind: enumValue("TEXT"), required: true, config: { maxLength: 60 } });
await addField(blogTypeId, { apiId: "slug", name: "スラッグ", kind: enumValue("SLUG"), required: true, unique: true, config: { sourceField: "title" } });
await addField(blogTypeId, { apiId: "excerpt", name: "概要", kind: enumValue("TEXT_AREA"), config: { maxLength: 120 } });
await addField(blogTypeId, { apiId: "body", name: "本文", kind: enumValue("RICH_TEXT"), required: true });
await addField(blogTypeId, { apiId: "author", name: "著者", kind: enumValue("REFERENCE"), required: true, targetTypeId: authorTypeId });
// **コンテンツがコンテンツに繋がる形**。1 件（著者）と複数（タグ）の両方を入れる。
await addField(blogTypeId, { apiId: "tags", name: "タグ", kind: enumValue("REFERENCE"), many: true, targetTypeId: tagTypeId });
await addField(blogTypeId, { apiId: "cover", name: "アイキャッチ", kind: enumValue("ASSET") });
await addField(blogTypeId, { apiId: "figures", name: "本文中の図", kind: enumValue("ASSET"), many: true });
await addField(blogTypeId, { apiId: "readMinutes", name: "読了目安（分）", kind: enumValue("NUMBER"), config: { min: 1, max: 60, integer: true } });
await addField(blogTypeId, { apiId: "featured", name: "おすすめ", kind: enumValue("BOOLEAN") });
await addField(blogTypeId, { apiId: "publishAt", name: "公開日", kind: enumValue("DATE") });

let published = 0;
let drafts = 0;
let changed = 0;
for (const [index, [title, tags, authorIndex, stage, minutes, blocks]] of POSTS.entries()) {
  const coverId = await upload(`cover-${index + 1}.png`, cover(index * 13 + 5, 640, 360), {
    width: 640,
    height: 360,
    alt: title,
  });
  // 3 記事に 1 つは図を 2 枚持たせる（ASSET の複数を確かめられるように）。
  const figures =
    index % 3 === 0
      ? [
          await upload(`figure-${index + 1}-a.png`, cover(index * 23 + 11, 480, 270), { width: 480, height: 270, alt: `${title} の図 1` }),
          await upload(`figure-${index + 1}-b.png`, cover(index * 29 + 17, 480, 270), { width: 480, height: 270, alt: `${title} の図 2` }),
        ]
      : [];
  const id = await createEntry(blogTypeId, {
    title,
    slug: `post-${index + 1}`,
    excerpt: blocks[1] ? blocks[1].slice(0, 110) : title,
    body: doc(blocks),
    author: authorIds[authorIndex],
    tags: tags.map((slug) => tagIds[slug]),
    cover: coverId,
    figures,
    readMinutes: minutes,
    featured: index % 5 === 0,
    publishAt: day(index),
  });
  if (stage !== "DRAFT") {
    await publish(id);
    published += 1;
  } else {
    drafts += 1;
  }
  // 「公開中 · 下書きあり」を作る: 公開した後にもう一度直す。
  // **版は読み直してから渡す**（公開で版がいくつ進むかは CMS の都合）。
  if (stage === "CHANGED") {
    const current = await call("entry", `query entry { entry(id: ${JSON.stringify(id)}) { version } }`);
    await call(
      "updateEntry",
      `mutation updateEntry { updateEntry(id: ${JSON.stringify(id)}, fields: ${literal({ excerpt: "（下書きで直した概要）" })}, expectedVersion: ${current.entry.version}) { id stage } }`
    );
    changed += 1;
    published -= 1;
  }
}

console.log(`  ブログ ${POSTS.length} 件（公開 ${published} / 公開中・下書きあり ${changed} / 下書き ${drafts}）`);
console.log("\n入りました。http://localhost:5173/p/default/c/blogs");
