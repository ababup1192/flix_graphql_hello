// 指定の画面を 4 つの幅で撮るだけ。
import { chromium } from "playwright";
import { open, shot } from "./stress-lib.mjs";
import fs from "node:fs";

fs.mkdirSync("/tmp/ui-stress", { recursive: true });
const arg = process.argv.slice(2);
const tag = arg[0];
const path = arg[1];
const ws = (arg[2] ?? "1440,1024,768,390").split(",").map(Number);
const full = arg[3] === "full";

const browser = await chromium.launch();
for (const w of ws) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  await open(page, path);
  const p = `/tmp/ui-stress/${tag}-${w}.png`;
  await page.screenshot({ path: p, fullPage: full });
  console.log(p);
  await page.close();
}
await browser.close();
