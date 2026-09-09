// 積んだ中身で主な画面を 4 つの幅で見る。
import { chromium } from "playwright";
import { open, overflow, widths } from "./stress-lib.mjs";
import fs from "node:fs";

const k = JSON.parse(fs.readFileSync("/tmp/ui-stress/keys.json", "utf8"));
fs.mkdirSync("/tmp/ui-stress", { recursive: true });

const paths = [
  ["list-long", `/p/default/c/zzstressart`],
  ["board-long", `/p/default/c/zzstressart/board`],
  ["editor-ja", `/p/default/c/zzstressart/${k.jaEntry}`],
  ["editor-en", `/p/default/c/zzstressart/${k.enEntry}`],
  ["editor-tags20", `/p/default/c/zzstressart/${k.manyTags}`],
  ["schema40", `/p/default/c/zzstresswide/schema`],
  ["list-empty", `/p/default/c/zzstressempty`],
  ["schema-empty", `/p/default/c/zzstressempty/schema`],
  ["media200", `/p/default/assets`],
];

const only = process.argv[2];
const browser = await chromium.launch();
for (const w of widths) {
  const page = await browser.newPage({ viewport: { width: w, height: 900 } });
  for (const [name, path] of paths) {
    if (only && !name.includes(only)) continue;
    await open(page, path, 2000);
    const o = await overflow(page);
    await page.screenshot({ path: `/tmp/ui-stress/${name}-${w}.png` });
    console.log(
      `${w} ${name} docOver=${o.docOver}` +
        (o.out.length ? ` OUT ${JSON.stringify(o.out)}` : "") +
        (o.tall.length ? ` TALL ${JSON.stringify(o.tall)}` : ""),
    );
  }
  await page.close();
}
await browser.close();
