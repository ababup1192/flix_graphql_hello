import { chromium } from "playwright";
const theme = process.env.THEME ?? "light";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
await page.goto("http://localhost:5173/", { waitUntil: "networkidle" });
await page.evaluate((t) => localStorage.setItem("theme", t), theme);
for (const [path, name] of [
  ["/p/default/c/blogs", "list"],
  ["/p/default/c/blogs/schema", "schema"],
  ["/p/default/settings/members", "members"],
  ["/p/default/assets", "media"],
]) {
  await page.goto("http://localhost:5173" + path, { waitUntil: "networkidle" });
  await page.waitForTimeout(1400);
  await page.screenshot({ path: `/tmp/${theme}-${name}.png` });
}
console.log("撮りました");
await browser.close();
