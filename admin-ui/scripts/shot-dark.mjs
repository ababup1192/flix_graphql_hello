import { chromium } from "playwright";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
await page.goto("http://localhost:5173/", { waitUntil: "networkidle" });
await page.evaluate(() => localStorage.setItem("theme", "dark"));
for (const [path, file] of [
  ["/p/default/c/blogs/board", "/tmp/dark-board.png"],
  ["/p/default/c/blogs", "/tmp/dark-list.png"],
]) {
  await page.goto("http://localhost:5173" + path, { waitUntil: "networkidle" });
  await page.waitForTimeout(1600);
  await page.screenshot({ path: file });
  console.log(file);
}
await browser.close();
