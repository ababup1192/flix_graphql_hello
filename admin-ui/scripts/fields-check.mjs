// フィールドの種類ごとに「入れる → 下書き保存 → 読み直して残っている」を通す。
// 作った型と entry は消さない（id は /tmp/ui-stress/fields.json に残す）。
import fs from "node:fs";
import { chromium } from "playwright";
import { gql, open } from "./stress-lib.mjs";

fs.mkdirSync("/tmp/ui-stress", { recursive: true });
const made = { types: [], entries: [] };
const save = () => fs.writeFileSync("/tmp/ui-stress/fields.json", JSON.stringify(made, null, 1));

const ok = [];
const ng = [];
const check = (name, pass, detail = "") => {
  (pass ? ok : ng).push(`${name}${detail ? " — " + detail : ""}`);
  console.log(`${pass ? "OK  " : "NG  "} ${name}${detail ? " — " + detail : ""}`);
};

const types = (await gql(`{ contentTypes { id apiId fields { apiId } } }`)).contentTypes;
const find = (apiId) => types.find((t) => t.apiId === apiId);

const cityType = find("zzcity").id;
let allType = find("zzall")?.id;
let had = find("zzall")?.fields.map((f) => f.apiId) ?? [];
if (!allType) {
  const r = await gql(`mutation ($i: ContentTypeInput!) { createContentType(input: $i) { id } }`, {
    i: { apiId: "zzall", name: "zz 全種類", icon: "list", singular: "ZzAll", plural: "zzAlls" },
  });
  allType = r.createContentType.id;
  made.types.push(allType);
  save();
}
// 途中で止まった時にも足りない分だけ足せるようにする。
const addField = async (typeId, i) => {
  if (had.includes(i.apiId)) return;
  await gql(`mutation ($t: ID!, $i: FieldInput!) { addField(typeId: $t, input: $i) { id } }`, { t: typeId, i });
};
{
  await addField(allType, { apiId: "title", name: "題", kind: "TEXT" });
  await addField(allType, { apiId: "handle", name: "識別子", kind: "SLUG", config: { sourceField: "title" } });
  await addField(allType, { apiId: "lead", name: "リード", kind: "TEXT_AREA" });
  await addField(allType, { apiId: "score", name: "点", kind: "NUMBER" });
  await addField(allType, { apiId: "featured", name: "おすすめ", kind: "BOOLEAN" });
  await addField(allType, { apiId: "mood", name: "気分", kind: "SELECT", config: { options: ["SUNNY", "CLOUDY", "RAINY"] } });
  await addField(allType, { apiId: "moods", name: "気分いろいろ", kind: "SELECT", many: true, config: { options: ["MORNING", "NOON", "NIGHT"] } });
  await addField(allType, { apiId: "startsAt", name: "開始", kind: "DATE" });
  await addField(allType, { apiId: "onDay", name: "開催日", kind: "DATE_ONLY" });
  await addField(allType, { apiId: "cover", name: "アイキャッチ", kind: "ASSET" });
  await addField(allType, { apiId: "gallery", name: "図", kind: "ASSET", many: true });
  await addField(allType, { apiId: "city", name: "都市", kind: "REFERENCE", targetTypeId: cityType });
  await addField(allType, { apiId: "cities", name: "都市いろいろ", kind: "REFERENCE", many: true, targetTypeId: cityType });
}

// 一覧の 1 ページ目に居ないメディア（古い物）を選んでも見え姿が出るか。
const assetPage = await gql(`{ assets(first: 300) { nodes { id fileName mime } totalCount } }`);
const images = assetPage.assets.nodes.filter((a) => a.mime.startsWith("image/"));
// ピッカーが最初に引く 60 件の外に居る 1 枚。**ここが id のまま出ていた。**
const oldImage = images[images.length - 1];
console.log(`メディア ${assetPage.assets.totalCount} 件。1 ページ目の外の見本: ${oldImage.fileName}`);

// 一覧の 1 ページ目に居ないメディアを指した entry を API で作り、画面で見え姿が出るか見る。
const oldEntry = (
  await gql(`mutation ($t: ID!, $f: JSON!) { createEntry(typeId: $t, fields: $f) { id } }`, {
    t: allType,
    f: { title: "zz 古いメディアの検査", cover: oldImage.id, gallery: [oldImage.id, images[images.length - 2].id] },
  })
).createEntry.id;
made.entries.push(oldEntry);
save();

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
page.on("pageerror", (e) => ng.push("JS 例外: " + e.message));
// ラベルは必須の印（*）と件数（n）が付くので、その分だけ許して当てる。
const field = (name) =>
  page.locator(`div.flex.flex-col.gap-2:has(> label:text-matches("^${name}([ （*].*)?$"))`).first();

await open(page, "/p/default/c/zzall/new", 2200);

await field("題").getByRole("textbox").fill("zz 全種類の検査");
await field("識別子").getByRole("textbox").fill("zz-all-check");
await field("リード").locator("textarea").fill("リードの本文。\n2 行目。");
await field("点").getByRole("spinbutton").fill("42");
await field("おすすめ").getByRole("checkbox").check();
await field("気分").getByRole("combobox").selectOption("CLOUDY");
await field("気分いろいろ").getByRole("button", { name: "NIGHT" }).click();
await field("気分いろいろ").getByRole("button", { name: "MORNING" }).click();

// 日時
await field("開始").getByRole("button", { name: "日時を選ぶ" }).click();
await page.waitForTimeout(200);
await field("開始").getByRole("button", { name: "15", exact: true }).click();
await field("開始").getByRole("button", { name: "この日時にする" }).click();
await page.waitForTimeout(200);

// 日付だけ
await field("開催日").getByRole("button", { name: "日付を選ぶ" }).click();
await page.waitForTimeout(200);
check("日付だけの欄に時刻の行が無い", (await field("開催日").getByRole("combobox").count()) === 0);
await field("開催日").getByRole("button", { name: "16", exact: true }).click();
await field("開催日").getByRole("button", { name: "この日付にする" }).click();
await page.waitForTimeout(200);
const dayShown = (await field("開催日").locator("span.font-mono").first().textContent()).trim();
check("日付だけが YYYY-MM-DD で出る", /^\d{4}-\d{2}-16$/.test(dayShown), dayShown);

// メディア（単一）— 一覧の後ろの方の 1 枚を選ぶ
async function pickAsset(name, fileName) {
  try {
    await field(name).getByRole("button", { name: /メディアを(選ぶ|追加)/ }).waitFor({ timeout: 8000 });
  } catch (e) {
    console.log("DUMP labels:", JSON.stringify(await page.locator("div.flex.flex-col.gap-2 > label").allTextContents()));
    console.log("DUMP modal:", await page.locator("div.fixed.inset-0").count());
    console.log("DUMP body:", (await page.locator("body").innerText()).replace(/\s+/g, " ").slice(0, 600));
    throw e;
  }
  await field(name).getByRole("button", { name: /メディアを(選ぶ|追加)/ }).click();
  const tile = page.locator("div.fixed button", { hasText: fileName }).first();
  await tile.waitFor({ state: "visible", timeout: 10000 });
  await tile.click();
  await page.waitForTimeout(300);
}
await pickAsset("アイキャッチ", images[0].fileName);
const coverCard = await field("アイキャッチ").textContent();
check(
  "メディア（単一）が id ではなく見え姿で出る",
  coverCard.includes(images[0].fileName),
  coverCard.replace(/\s+/g, " ").slice(0, 70),
);
const coverImg = await field("アイキャッチ").locator("img").count();
check("メディア（単一）にサムネイルが出る", coverImg === 1, `img ${coverImg} 枚`);

await pickAsset("図", images[1].fileName);
await pickAsset("図", images[2].fileName);
const galleryCards = await field("図").locator("div.w-32").count();
const galleryRemove = await field("図").getByRole("button", { name: "外す" }).count();
check("メディア（複数）が 1 枚ごとのまとまりになる", galleryCards === 2 && galleryRemove === 2, `card ${galleryCards} / 外す ${galleryRemove}`);
const galleryLabel = await field("図").locator("label").first().textContent();
check("メディア（複数）のラベルに件数", galleryLabel.includes("（2）"), galleryLabel.trim());

// 参照
async function pickRef(name, query) {
  const at = field(name);
  await at.getByRole("textbox").fill(query);
  const c = at.locator("button.truncate", { hasText: query });
  await c.first().waitFor({ state: "visible", timeout: 10000 });
  await c.first().click();
  await page.waitForTimeout(250);
}
await pickRef("都市いろいろ", "zzfar101");
await pickRef("都市", "zzfar102");

// 赤いリンクは使っていない
const danger = await page.locator('div.flex.gap-8 button.text-\\[color\\:var\\(--color-bad\\)\\]').count();
check("フィールドに赤いリンクを使っていない", danger === 0, `${danger} 個`);

await page.getByRole("button", { name: "下書き保存" }).click();
await page.waitForTimeout(2500);
const state = await page.locator("div.sticky span.text-xs").first().textContent();
check("全種類を入れて下書き保存できる", state.trim() === "保存済み", state.trim());

const savedId = (
  await gql(`query ($t: ID!) { entries(typeId: $t, search: "zz 全種類の検査", first: 1) { nodes { id } } }`, { t: allType })
).entries.nodes[0].id;
made.entries.push(savedId);
save();
const back = (await gql(`query ($i: ID!) { entry(id: $i) { fields } }`, { i: savedId })).entry.fields;
const want = {
  題: back.title === "zz 全種類の検査",
  識別子: back.handle === "zz-all-check",
  リード: String(back.lead).startsWith("リードの本文。"),
  点: back.score === 42,
  おすすめ: back.featured === true,
  気分: back.mood === "CLOUDY",
  気分いろいろ: Array.isArray(back.moods) && back.moods.length === 2,
  開始: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(back.startsAt),
  開催日: /^\d{4}-\d{2}-16$/.test(back.onDay),
  アイキャッチ: back.cover === images[0].id,
  図: Array.isArray(back.gallery) && back.gallery.length === 2,
  都市: typeof back.city === "string" && back.city.length === 12,
  都市いろいろ: Array.isArray(back.cities) && back.cities.length === 1,
};
for (const [name, pass] of Object.entries(want)) check(`CMS に残る: ${name}`, pass);

// 読み直し
await open(page, `/p/default/c/zzall/${savedId}`, 2600);
const reread = {
  題: (await field("題").getByRole("textbox").inputValue()) === "zz 全種類の検査",
  点: (await field("点").getByRole("spinbutton").inputValue()) === "42",
  おすすめ: await field("おすすめ").getByRole("checkbox").isChecked(),
  気分: (await field("気分").getByRole("combobox").inputValue()) === "CLOUDY",
  開始: /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test((await field("開始").locator("span.font-mono").first().textContent()).trim()),
  開催日: (await field("開催日").locator("span.font-mono").first().textContent()).trim() === dayShown,
  アイキャッチ: (await field("アイキャッチ").locator("img").count()) === 1,
  図: (await field("図").locator("img").count()) === 2,
  都市: (await field("都市").locator("button.rounded-full").first().textContent()).includes("zzfar102"),
};
for (const [name, pass] of Object.entries(reread)) check(`読み直して出る: ${name}`, pass);

// 一覧の 1 ページ目に居ないメディアでもサムネイルが出る（id のまま出ないか）。
await open(page, `/p/default/c/zzall/${oldEntry}`, 3000);
const oldCover = await field("アイキャッチ").textContent();
check(
  "1 ページ目の外のメディアも id ではなく見え姿で出る",
  (await field("アイキャッチ").locator("img").count()) === 1 && oldCover.includes(oldImage.fileName),
  oldCover.replace(/\s+/g, " ").slice(0, 60),
);
check("1 ページ目の外のメディアが複数でも出る", (await field("図").locator("img").count()) === 2);

// 幅
for (const w of [1440, 1024, 768]) {
  await page.setViewportSize({ width: w, height: 1100 });
  await open(page, `/p/default/c/zzall/${savedId}`, 2200);
  const o = await page.evaluate(() => {
    const out = [];
    for (const el of document.querySelectorAll("body *")) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (getComputedStyle(el).position === "fixed") continue;
      if (Math.round(r.right - window.innerWidth) > 1) out.push(String(el.className).slice(0, 60));
    }
    return { docOver: document.documentElement.scrollWidth - window.innerWidth, out: [...new Set(out)].slice(0, 5) };
  });
  await page.screenshot({ path: `/tmp/ui-stress/fields-${w}.png`, fullPage: true });
  check(`幅 ${w} で横に溢れない`, o.docOver <= 0 && o.out.length === 0, `docOver=${o.docOver} ${JSON.stringify(o.out)}`);
}

await browser.close();
console.log(`\n通った ${ok.length} / 落ちた ${ng.length}`);
if (ng.length) {
  console.log(ng.map((n) => "  NG " + n).join("\n"));
  process.exit(1);
}
