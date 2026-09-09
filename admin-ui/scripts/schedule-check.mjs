import { chromium } from "playwright";

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
page.on("pageerror", (e) => console.log("PAGE ERROR:", e.message));

await page.goto("http://localhost:5173/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(1200);
const hrefs = await page.locator("a").evaluateAll((as) =>
  as.map((a) => a.getAttribute("href")).filter((h) => /^\/p\/default\/c\/blogs\/[0-9a-f]{12}$/.test(h ?? ""))
);
console.log("開くコンテンツ:", hrefs[0]);
await page.goto("http://localhost:5173" + hrefs[0], { waitUntil: "networkidle" });
await page.waitForTimeout(2200);

const rail = page.locator("div").filter({ hasText: "予約" }).last();
await page.getByText("予約する").click();
await page.waitForTimeout(600);

const cal = page.locator("div.w-\\[268px\\]");
console.log("カレンダー:", await cal.count());
const header = await cal.locator("span").first().innerText();
console.log("見出し:", header);
const weekdays = await cal.locator("div.grid > span").allInnerTexts();
console.log("曜日:", weekdays.slice(0, 7).join(" "));
const selects = cal.locator("select");
console.log("時:", await selects.nth(0).inputValue(), "分:", await selects.nth(1).inputValue());
const chosen = await cal.locator("button.bg-accent").innerText();
console.log("選ばれている日:", chosen);

// 前の月・次の月
await cal.locator("button[title='前の月']").click();
await page.waitForTimeout(200);
console.log("前の月:", await cal.locator("span").first().innerText());
await cal.locator("button[title='次の月']").click();
await cal.locator("button[title='次の月']").click();
await page.waitForTimeout(200);
console.log("次の月:", await cal.locator("span").first().innerText());
await cal.locator("button[title='前の月']").click();
await page.waitForTimeout(200);

// 日を選ぶ
await cal.locator("div.grid > button", { hasText: /^20$/ }).first().click();
await page.waitForTimeout(200);
console.log("選び直した日:", await cal.locator("button.bg-accent").innerText());

await page.screenshot({ path: "/tmp/schedule-calendar.png" });

// 予約する
await page.getByText("この時刻に公開").click();
await page.waitForTimeout(2000);
const list = await page.locator("div.flex.items-center.gap-2.text-xs").allInnerTexts();
console.log("予約の一覧:", JSON.stringify(list.filter((t) => t.includes("実行待ち") || t.includes("遅延"))));

await page.screenshot({ path: "/tmp/schedule-listed.png" });

// 取り消す
const cancel = page.getByText("取り消す").first();
if (await cancel.count()) {
  await cancel.click();
  await page.waitForTimeout(1500);
  console.log("取り消し後:", JSON.stringify((await page.locator("div.flex.items-center.gap-2.text-xs").allInnerTexts()).filter((t) => t.includes("実行待ち"))));
}

await browser.close();
