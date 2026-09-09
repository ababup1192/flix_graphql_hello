import { chromium } from "playwright";
const base = "http://localhost:5173";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
const shots = [
  ["/p/default/c/blogs", "/tmp/shot-list.png"],
  ["/p/default/c/blogs/schema", "/tmp/shot-schema.png"],
  ["/p/default/c/blogs/board", "/tmp/shot-board.png"],
];
for (const [path, file] of shots) {
  await page.goto(base + path, { waitUntil: "networkidle" });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: file });
  console.log(file);
}
// エディタは一覧の 1 件目を開く
await page.goto(base + "/p/default/c/blogs", { waitUntil: "networkidle" });
await page.waitForTimeout(800);
await page.locator("a").filter({ hasText: "Datalog" }).first().click();
await page.waitForTimeout(2000);
await page.screenshot({ path: "/tmp/shot-editor.png" });
console.log("/tmp/shot-editor.png");
await browser.close();
