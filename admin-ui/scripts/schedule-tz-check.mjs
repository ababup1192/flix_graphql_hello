// 予約が 1 件に保たれる事と、時刻が手元のタイムゾーンで出る事を見る。
// 最後に必ず取り消す。
import { chromium } from "playwright";

const TZ = process.env.TZ_CHECK ?? "Asia/Tokyo";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, timezoneId: TZ });
page.on("pageerror", (e) => console.log("PAGE ERROR:", e.message));

const gql = (entryId) =>
  page.evaluate(async (id) => {
    const response = await fetch("/p/default/admin/graphql", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query: `{ schedules(entryId: "${id}") { id runAt status } }` }),
    });
    return await response.json();
  }, entryId);

const href = process.env.ENTRY ?? "/p/default/c/blogs/1f1ac55ebe9a";
const entryId = href.split("/").pop();
console.log("タイムゾーン:", TZ, "entry id:", entryId);

await page.goto("http://localhost:5173" + href, { waitUntil: "networkidle" });
await page.waitForTimeout(2000);


// 1 回目
await page.getByText("予約する", { exact: true }).click();
await page.waitForTimeout(500);
const cal = page.locator("div.w-\\[268px\\]");
console.log("タイムゾーンの目印:", await cal.locator("span").last().innerText());
await cal.locator("select").nth(0).selectOption("21");
await cal.locator("select").nth(1).selectOption("30");
const day = await cal.locator("button.bg-accent").innerText();
const monthHead = await cal.locator("span").first().innerText();
console.log("選んだ:", monthHead, day, "日 21:30");
await page.getByText("この時刻に公開", { exact: true }).click();
await page.waitForTimeout(1500);
console.log("1 回目の後の予約:", await page.locator("span.font-mono.text-\\[11px\\]").allInnerTexts());

// 2 回目（同じ時刻。置き換わるはず）
await page.getByText("予約を変える", { exact: true }).click();
await page.waitForTimeout(500);
await cal.locator("select").nth(0).selectOption("21");
await cal.locator("select").nth(1).selectOption("30");
console.log("置き換わる断り:", await page.getByText("今の予約は取り消され").count());
await page.locator("div.w-64").first().screenshot({ path: "/tmp/schedule-rail.png" });
await page.getByText("この時刻に変える", { exact: true }).click();
await page.waitForTimeout(1500);

const shown = await page.locator("span.font-mono.text-\\[11px\\]").allInnerTexts();
console.log("2 回目の後の予約（画面）:", shown);
console.log("CMS 側:", JSON.stringify((await gql(entryId)).data.schedules));

// 取り消す
const cancels = page.getByText("取り消す", { exact: true });
const count = await cancels.count();
for (let at = 0; at < count; at += 1) {
  await cancels.first().click();
  await page.waitForTimeout(900);
}
await page.waitForTimeout(800);
console.log("取り消した後（画面）:", await page.locator("span.font-mono.text-\\[11px\\]").allInnerTexts());
console.log("取り消した後（CMS）:", JSON.stringify((await gql(entryId)).data.schedules));

await page.screenshot({ path: "/tmp/schedule-tz.png", fullPage: true });
await browser.close();
