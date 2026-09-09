// レールから中身がはみ出していないかを測る。予約の欄は開いた状態で見る。
import { chromium } from "playwright";

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, timezoneId: "Asia/Tokyo" });
await page.goto("http://localhost:5173" + (process.env.ENTRY ?? "/p/default/c/tags/50fdb5a09c5e"), { waitUntil: "networkidle" });
await page.waitForTimeout(2200);
await page.getByText(/^予約(する|を変える)$/).click();
await page.waitForTimeout(600);

const measured = await page.locator("div.w-64").first().evaluate((rail) => {
  const out = [{ what: "rail", w: rail.clientWidth, scroll: rail.scrollWidth, h: rail.getBoundingClientRect().height }];
  for (const el of rail.querySelectorAll("*")) {
    if (el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0) {
      out.push({ what: (el.className || el.tagName).toString().slice(0, 60), w: el.clientWidth, scroll: el.scrollWidth });
    }
  }
  const right = rail.getBoundingClientRect().right;
  for (const el of rail.querySelectorAll("*")) {
    if (el.getBoundingClientRect().right > right + 1) {
      out.push({ what: "はみ出し: " + (el.textContent || "").trim().slice(0, 24), over: Math.round(el.getBoundingClientRect().right - right) });
    }
  }
  return out;
});
console.log(JSON.stringify(measured, null, 1));
await page.screenshot({ path: "/tmp/rail-fit.png", clip: { x: 1140, y: 60, width: 300, height: 840 } });
await browser.close();
