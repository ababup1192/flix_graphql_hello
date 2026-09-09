import { chromium } from "playwright";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
await page.goto("http://localhost:5173/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(900);
await page.locator("a").filter({ hasText: "Datalog" }).first().click();
await page.waitForTimeout(2200);
const bar = page.locator(".tt-bar");
await bar.screenshot({ path: "/tmp/shot-toolbar.png" });
const labels = await page.locator(".tt-tool").evaluateAll((nodes) =>
  nodes.map((n) => n.getAttribute("aria-label") ?? n.textContent)
);
console.log("ボタン:", labels.join(" / "));
await browser.close();
