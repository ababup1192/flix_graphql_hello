// DATE のフィールドと、参照を選ぶ面の実測。
// 型と entry を作るが、消さない（作った物の id は /tmp/ui-stress/refdate.json に残す）。
import fs from "node:fs";
import { execSync } from "node:child_process";
import { chromium } from "playwright";
import { base, gql, open } from "./stress-lib.mjs";

fs.mkdirSync("/tmp/ui-stress", { recursive: true });
const made = { types: [], entries: [] };
const save = () => fs.writeFileSync("/tmp/ui-stress/refdate.json", JSON.stringify(made, null, 1));

const ok = [];
const ng = [];
const check = (name, pass, detail = "") => {
  (pass ? ok : ng).push(`${name}${detail ? " — " + detail : ""}`);
  console.log(`${pass ? "OK  " : "NG  "} ${name}${detail ? " — " + detail : ""}`);
};

// ---- 検査用のデータ（既にあれば作り直さない）

const types = (await gql(`{ contentTypes { id apiId name } }`)).contentTypes;
const find = (apiId) => types.find((t) => t.apiId === apiId);

async function makeType(apiId, name, icon, singular, plural) {
  const found = find(apiId);
  if (found) return found.id;
  const r = await gql(`mutation ($i: ContentTypeInput!) { createContentType(input: $i) { id } }`, {
    i: { apiId, name, icon, singular, plural },
  });
  made.types.push(r.createContentType.id);
  save();
  return r.createContentType.id;
}
const addField = (typeId, i) =>
  gql(`mutation ($t: ID!, $i: FieldInput!) { addField(typeId: $t, input: $i) { id } }`, { t: typeId, i });
async function entryIn(typeId, fields, publish = false) {
  const e = await gql(`mutation ($t: ID!, $f: JSON!) { createEntry(typeId: $t, fields: $f) { id } }`, {
    t: typeId,
    f: fields,
  });
  made.entries.push(e.createEntry.id);
  save();
  if (publish) await gql(`mutation ($i: ID!) { publishEntry(id: $i, withDependencies: true) { id } }`, { i: e.createEntry.id });
  return e.createEntry.id;
}

const many = 130;
const cityNew = !find("zzcity");
const cityType = await makeType("zzcity", "zz 都市", "tag", "ZzCity", "zzCities");
if (cityNew) {
  await addField(cityType, { apiId: "name", name: "名前", kind: "TEXT" });
  console.log(`都市を ${many} 件…`);
  for (let i = 0; i < many; i += 1) {
    // 101 件目以降だけに出る語を混ぜる（先読み 100 件では絶対に出ない）。
    const tail = i >= 100 ? `zzfar${i}` : `zznear${i}`;
    await entryIn(cityType, { name: `zz 都市 ${String(i).padStart(3, "0")} ${tail}` }, true);
  }
}

const eventNew = !find("zzevent");
const eventType = await makeType("zzevent", "zz 催し", "list", "ZzEvent", "zzEvents");
if (eventNew) {
  await addField(eventType, { apiId: "title", name: "題", kind: "TEXT", required: true });
  await addField(eventType, { apiId: "opensAt", name: "開始日時", kind: "DATE", required: true });
  await addField(eventType, { apiId: "closesAt", name: "終了日時", kind: "DATE" });
  await addField(eventType, { apiId: "place", name: "会場", kind: "REFERENCE", targetTypeId: cityType });
  await addField(eventType, { apiId: "stops", name: "巡る所", kind: "REFERENCE", many: true, targetTypeId: cityType });
}

// 非 canonical な既存の値（ミリ秒付き）。**CMS は今これを受けない**ので、
// 厳格化より前に入っていた行として DB に直接置く。読んで落ちない事を見る。
const legacy = await entryIn(eventType, { title: "zz 旧い日時", opensAt: "2026-09-09T09:00:00Z" });
execSync(
  `docker exec -i flix_graphql_hello-postgres-1 psql -U cms -d cms -c ` +
    `"update entry_contents set data = jsonb_set(data, '{opensAt}', '\\"2026-09-09T09:00:00.000Z\\"') where entry_id = '${legacy}'"`,
  { stdio: "pipe" },
);

const cityRows = (await gql(`query ($t: ID!) { entries(typeId: $t, first: 200) { nodes { id fields } } }`, { t: cityType }))
  .entries.nodes;
const far = cityRows.find((r) => String(r.fields.name).includes("zzfar129"));
console.log(`都市 ${cityRows.length} 件、101 件目以降の見本: ${far && far.fields.name}`);

// ---- 画面

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
page.on("pageerror", (e) => ng.push("JS 例外: " + e.message));

const newUrl = `/p/default/c/zzevent/new`;
// ラベルは必須の印（*）と件数（n）が付くので、その分だけ許して当てる。
const field = (name) =>
  page.locator(`div.flex.flex-col.gap-2:has(> label:text-matches("^${name}([ （*].*)?$"))`).first();

// 1) DATE を入れて保存 → 読み直して同じ値
await open(page, newUrl, 1800);
await field("題").getByRole("textbox").fill("zz 日時と参照の検査");
await field("開始日時").getByRole("button", { name: "日時を選ぶ" }).click();
await page.waitForTimeout(200);
const cal = field("開始日時");
await cal.getByRole("button", { name: "20", exact: true }).click();
await cal.getByRole("button", { name: "この日時にする" }).click();
await page.waitForTimeout(200);
const shownBefore = (await field("開始日時").locator("span.font-mono").first().textContent()).trim();
check("暦で選んだ日時が手元の時刻で出る", /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(shownBefore), shownBefore);

// 打って絞り、出た候補を選ぶ。候補が出るのを待つ（固定の待ちだと取りこぼす）。
async function pick(name, query) {
  const at = field(name);
  await at.getByRole("textbox").fill(query);
  const candidate = at.locator("button.truncate", { hasText: query });
  await candidate.first().waitFor({ state: "visible", timeout: 10000 });
  const label = await candidate.first().textContent();
  await candidate.first().click();
  await page.waitForTimeout(250);
  return label.trim();
}

// 参照（1 件）— 101 件目以降を打って絞って選ぶ
const farLabel = await pick("会場", "zzfar129");
check("101 件目以降が打って絞れて選べる", farLabel.includes("zzfar129"), farLabel);
const chip = await field("会場").locator("button.rounded-full").first().textContent();
check("選んだ物がチップで出る", chip.includes("zzfar129"), chip.trim().slice(0, 40));

// 参照（複数）
await pick("巡る所", "zznear77");
await pick("巡る所", "zzfar118");
const stopChips = await field("巡る所").locator("button.rounded-full").allTextContents();
check("複数参照が 2 件入る", stopChips.length === 2, stopChips.join(" / ").slice(0, 60));
const stopsLabel = await field("巡る所").locator("label").first().textContent();
check("ラベルに件数が付く", stopsLabel.includes("（2）"), stopsLabel.trim());

await page.getByRole("button", { name: "下書き保存" }).click();
await page.waitForTimeout(2000);
const saveState = await page.locator("div.sticky span.text-xs").first().textContent();
check("下書き保存が CMS に通る", saveState.trim() === "保存済み", saveState.trim());

// 新規の URL は `/new` のままなので、題で引き当てる。
const savedId = (
  await gql(`query ($t: ID!) { entries(typeId: $t, search: "zz 日時と参照の検査", first: 1) { nodes { id } } }`, {
    t: eventType,
  })
).entries.nodes[0].id;
made.entries.push(savedId);
save();
const savedUrl = `/p/default/c/zzevent/${savedId}`;
const back = await gql(`query ($i: ID!) { entry(id: $i) { fields } }`, { i: savedId });
check("CMS 側の DATE が canonical", /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(back.entry.fields.opensAt), back.entry.fields.opensAt);
check("CMS 側に参照が入っている", back.entry.fields.place === far.id, String(back.entry.fields.place));
check("CMS 側に複数参照が 2 件", (back.entry.fields.stops || []).length === 2, JSON.stringify(back.entry.fields.stops));

// 2) 読み直して同じ値・同じ参照が出る
await open(page, savedUrl, 2200);
const shownAfter = (await field("開始日時").locator("span.font-mono").first().textContent()).trim();
check("読み直して同じ日時が出る", shownAfter === shownBefore, `${shownBefore} → ${shownAfter}`);
const chipAfter = await field("会場").locator("button.rounded-full").first().textContent();
check("読み直して参照の見出しが出る（id ではない）", chipAfter.includes("zzfar129"), chipAfter.trim().slice(0, 40));

// 3) 必須でない DATE を入れてから空にできる
const closes = field("終了日時");
await closes.getByRole("button", { name: "日時を選ぶ" }).click();
await page.waitForTimeout(200);
await field("終了日時").getByRole("button", { name: "21", exact: true }).click();
await field("終了日時").getByRole("button", { name: "この日時にする" }).click();
await page.waitForTimeout(200);
await field("終了日時").getByRole("button", { name: "消す" }).click();
await page.waitForTimeout(200);
const emptied = await field("終了日時").textContent();
check("必須でない DATE を空に戻せる", emptied.includes("日時が入っていません"), emptied.trim().slice(0, 30));
await page.getByRole("button", { name: "下書き保存" }).click();
await page.waitForTimeout(2000);
const back2 = await gql(`query ($i: ID!) { entry(id: $i) { fields } }`, { i: savedId });
check("空にした DATE が CMS に残らない", back2.entry.fields.closesAt == null, JSON.stringify(back2.entry.fields.closesAt));

// 4) 必須の DATE が空のまま公開を押した時の断り
await open(page, newUrl, 1800);
await field("題").getByRole("textbox").fill("zz 必須の日時が空");
await page.getByRole("button", { name: "公開する" }).click();
await page.waitForTimeout(2500);
const dialog = await page.locator("div.fixed").last().textContent();
check("必須の DATE が空だと公開前の確認が断る", dialog.includes("直す所"), dialog.replace(/\s+/g, " ").slice(0, 120));
await page.getByRole("button", { name: "やめる" }).click();

// 5) 候補が 0 件の型（まだ 1 件も無い）
const emptyNew = !find("zzempty");
const emptyType = await makeType("zzempty", "zz 空っぽ", "tag", "ZzEmpty", "zzEmpties");
if (emptyNew) await addField(emptyType, { apiId: "name", name: "名前", kind: "TEXT" });
const holderNew = !find("zzholder");
const holderType = await makeType("zzholder", "zz 置き場", "list", "ZzHolder", "zzHolders");
if (holderNew) {
  await addField(holderType, { apiId: "title", name: "題", kind: "TEXT" });
  await addField(holderType, { apiId: "link", name: "繋ぎ先", kind: "REFERENCE", targetTypeId: emptyType });
}
await open(page, "/p/default/c/zzholder/new", 2000);
await field("繋ぎ先").getByRole("textbox").click();
await page.waitForTimeout(600);
const none = await field("繋ぎ先").textContent();
check("候補 0 件で「まだ 1 件もありません」と導線", none.includes("まだ 1 件もありません") && none.includes("を作る"), none.replace(/\s+/g, " ").slice(0, 80));

// 6) 非 canonical な既存の値を開いても落ちない
await open(page, `/p/default/c/zzevent/${legacy}`, 2200);
const legacyShown = (await field("開始日時").locator("span.font-mono").first().textContent()).trim();
check("ミリ秒付きの既存の値でも落ちずに出る", /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(legacyShown), legacyShown);
await field("開始日時").getByRole("button", { name: "選び直す" }).click();
await page.waitForTimeout(300);
const opened = await field("開始日時").textContent();
check("ミリ秒付きでも暦がその月で開く", opened.includes("2026 年 9 月"), opened.replace(/\s+/g, " ").slice(0, 40));

// 7) 幅 1440 / 768 で崩れない
for (const w of [1440, 768]) {
  await page.setViewportSize({ width: w, height: 1000 });
  await open(page, savedUrl, 1800);
  await field("会場").getByRole("textbox").click();
  await page.waitForTimeout(700);
  const o = await page.evaluate(() => {
    const de = document.documentElement;
    const out = [];
    for (const el of document.querySelectorAll("body *")) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (getComputedStyle(el).position === "fixed") continue;
      if (Math.round(r.right - window.innerWidth) > 1) out.push(String(el.className).slice(0, 60));
    }
    return { docOver: de.scrollWidth - window.innerWidth, out: [...new Set(out)].slice(0, 5) };
  });
  await page.screenshot({ path: `/tmp/ui-stress/refdate-${w}.png` });
  check(`幅 ${w} で横に溢れない`, o.docOver <= 0 && o.out.length === 0, `docOver=${o.docOver} ${JSON.stringify(o.out)}`);
}

await browser.close();
console.log(`\n通った ${ok.length} / 落ちた ${ng.length}`);
if (ng.length) {
  console.log(ng.map((n) => "  NG " + n).join("\n"));
  process.exit(1);
}
