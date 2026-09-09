// 参照が多い entry を開き、レールが伸び続けない事と、引き出しで全部見られる事を見る。
// データは書き換えない（タグ 50fdb5a09c5e は 9 件のブログから参照されている）。
import { chromium } from "playwright";

const target = process.env.ENTRY ?? "/p/default/c/tags/50fdb5a09c5e";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
page.on("pageerror", (e) => console.log("PAGE ERROR:", e.message));

await page.goto("http://localhost:5173" + target, { waitUntil: "networkidle" });
await page.waitForTimeout(2200);

const rail = page.locator("div.w-64").first();
const box = await rail.boundingBox();
console.log("レールの高さ:", Math.round(box.height), "画面の高さ: 900");

const section = page.locator("div").filter({ hasText: /^参照されています（/ }).last();
console.log("見出し:", await page.getByText(/参照されています（/).first().innerText());
console.log("レールの参照の行:", await rail.locator("a.truncate").count());
console.log("レールの見出し:", (await rail.locator("span.text-\\[11px\\]").allInnerTexts()).filter((t) => t.includes("参照")));
console.log("断り:", await rail.getByText("公開中の参照があるうちは").count());

const more = rail.getByText(/^他 \d+ 件$/);
console.log("他 N 件:", await more.count(), await more.first().innerText());
await more.first().click();
await page.waitForTimeout(600);

const drawer = page.locator("div.fixed.inset-0 > div").first();
console.log("引き出しの見出し:", await drawer.locator("h2, span, div").first().innerText());
console.log("引き出しの行:", await drawer.locator("a").count());
console.log("引き出しの中身:", (await drawer.locator("a").allInnerTexts()).join(" / "));
console.log("引き出しの見出し（分け方）:", (await drawer.locator("span.text-\\[11px\\]").allInnerTexts()).join(" / "));

await page.screenshot({ path: "/tmp/referrers-drawer.png" });
await page.locator("div.fixed.inset-0").first().click({ position: { x: 10, y: 10 } });
await page.waitForTimeout(400);
console.log("閉じた後の引き出し:", await page.locator("div.fixed.inset-0").count());
await page.screenshot({ path: "/tmp/referrers-rail.png" });
await browser.close();
