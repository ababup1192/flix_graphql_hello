// 今のデータのまま、主な画面を 4 つの幅で見る（基準）。
import { chromium } from "playwright";
import { open, overflow, shot, widths } from "./stress-lib.mjs";
import fs from "node:fs";

fs.mkdirSync("/tmp/ui-stress", { recursive: true });

const paths = [
  ["home", "/"],
  ["projects", "/projects"],
  ["entries", "/p/default/c/blogs"],
  ["board", "/p/default/c/blogs/board"],
  ["schema", "/p/default/c/blogs/schema"],
  ["media", "/p/default/assets"],
  ["settings", "/p/default/settings/members"],
  ["account", "/account"],
];

const browser = await chromium.launch();
for (const w of widths) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  for (const [name, path] of paths) {
    await open(page, path);
    const o = await overflow(page);
    const flag = o.docOver > 0 || o.out.length || o.tall.length;
    if (flag) await shot(page, `base-${name}-${w}`);
    console.log(
      `${w} ${name} docOver=${o.docOver}` +
        (o.out.length ? ` OUT ${JSON.stringify(o.out)}` : "") +
        (o.tall.length ? ` TALL ${JSON.stringify(o.tall)}` : ""),
    );
  }
  await page.close();
}
await browser.close();
