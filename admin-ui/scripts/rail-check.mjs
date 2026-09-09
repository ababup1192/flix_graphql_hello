// 右のレールが黙って打ち切っていないかを確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/rail-check.mjs
// 見る物: 変更履歴と予約が「件数 + 先頭 N 件 + 他 N 件 → 引き出し」の形になっているか。

import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const cms = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
const devUser = process.env.VITE_DEV_USER ?? "dev@localhost";
const problems = [];
const steps = [];

function check(ok, step, detail) {
  if (ok) steps.push(`  OK  ${step}`);
  else problems.push(`  NG  ${step} — ${detail}`);
}

async function call(query) {
  const response = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": devUser },
    body: JSON.stringify({ query }),
  });
  return response.json();
}

// 版が 8 を超える物を探す。**レールが切るのは 9 件目から**（版は公開の時に増える）。
const types = (await call(`query contentTypes { contentTypes { id apiId } }`)).data.contentTypes;
let target = null;
for (const type of types) {
  const nodes = (await call(`query entries { entries(typeId: "${type.id}", first: 50) { nodes { id versions { version } } } }`))
    .data.entries.nodes;
  const found = nodes.find((node) => node.versions.length > 8);
  if (found) {
    target = { apiId: type.apiId, entryId: found.id, versions: found.versions.length };
    break;
  }
}
if (!target) {
  console.log("  --  版が 9 件以上のコンテンツがありません（npm run seed と stress の後で走らせてください）");
  process.exit(0);
}
const entryId = target.entryId;

// 予約を入れ替えて、終わった（取り消された）予約を残す。
for (const day of ["2027-02-01", "2027-02-02", "2027-02-03"]) {
  await call(`mutation schedulePublish { schedulePublish(entryId: "${entryId}", at: "${day}T09:00:00Z") { id } }`);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
page.on("pageerror", (error) => problems.push(`  NG  JS の例外 — ${String(error).slice(0, 200)}`));

try {
  await page.goto(`${base}/p/default/c/${target.apiId}/${entryId}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(1500);
  const rail = (await page.locator("body").innerText()) ?? "";

  const versions = (await call(`query entry { entry(id: "${entryId}") { versions { version } } }`)).data.entry.versions.length;
  check(rail.includes(`変更履歴（${versions}）`), "変更履歴に件数が出る", rail.replace(/\s+/g, " ").slice(0, 300));
  check(
    rail.includes(`他 ${versions - 8} 件`),
    "変更履歴に「他 N 件」が出る",
    `版 ${versions} 件。画面: ${rail.replace(/\s+/g, " ").slice(0, 300)}`
  );

  await page.getByRole("button", { name: `他 ${versions - 8} 件` }).click();
  await page.waitForTimeout(600);
  const rows = await page.locator(".fixed .flex-col > div").count();
  check(rows > 0, "変更履歴の引き出しが開く", `行 ${rows}`);
  const drawer = (await page.locator("body").innerText()) ?? "";
  check(drawer.includes(`${versions} 件`), "引き出しに全部の件数が出る", drawer.replace(/\s+/g, " ").slice(0, 200));
  await page.getByRole("button", { name: "閉じる" }).first().click();
  await page.waitForTimeout(400);

  const done = (await call(`query schedules { schedules(entryId: "${entryId}", first: 50) { status } }`)).data.schedules.filter(
    (schedule) => schedule.status !== "PENDING" && schedule.status !== "FAILED"
  ).length;
  const after = (await page.locator("body").innerText()) ?? "";
  check(after.includes(`終わった予約 ${done} 件`), "終わった予約の件数が出る", after.replace(/\s+/g, " ").slice(0, 300));
  await page.getByRole("button", { name: `終わった予約 ${done} 件` }).click();
  await page.waitForTimeout(600);
  const scheduleDrawer = (await page.locator("body").innerText()) ?? "";
  check(scheduleDrawer.includes("取り消し"), "予約の引き出しに終わった物が出る", scheduleDrawer.replace(/\s+/g, " ").slice(0, 300));
} catch (error) {
  problems.push(`  NG  途中で落ちた — ${String(error).slice(0, 400)}`);
} finally {
  await browser.close();
}

console.log(steps.join("\n"));
if (problems.length > 0) {
  console.log("\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`\n通りました（${steps.length} 件）。`);
