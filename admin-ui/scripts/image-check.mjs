// 本文に画像を入れる道を、実際の画面で確かめる。
//
// 使い方: CMS と vite を上げてから  node scripts/image-check.mjs
// 見る物:
//   1. ツールバーの画像のボタン → メディアを選ぶ → 本文に image が入る
//   2. クリップボードから貼れる（DataTransfer を組んで paste を送る）
//   3. 入れた後に下書き保存が通る（CMS が assetId の形を受ける）
//   4. 2 枚以上で gallery になり、列の数を変えられて、保存も通る
//   5. 長い題が 1 行に収まり、title でホバーで全部読める

import zlib from "node:zlib";
import { chromium } from "playwright";

const base = process.env.UI_BASE ?? "http://localhost:5173";
const problems = [];
const steps = [];

function note(step, detail = "") {
  steps.push(`  OK  ${step}${detail ? " — " + detail : ""}`);
}

function fail(step, detail) {
  problems.push(`  NG  ${step} — ${detail}`);
}

function check(ok, step, detail) {
  if (ok) note(step);
  else fail(step, detail);
}

// 依存を増やさずに PNG を作る（`scripts/seed.mjs` と同じやり方）。
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

function png(width, height, pixel) {
  const raw = Buffer.alloc((width * 3 + 1) * height);
  let at = 0;
  for (let y = 0; y < height; y += 1) {
    raw[at] = 0;
    at += 1;
    for (let x = 0; x < width; x += 1) {
      const [r, g, b] = pixel(x, y);
      raw[at] = r;
      raw[at + 1] = g;
      raw[at + 2] = b;
      at += 3;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

page.on("pageerror", (error) => problems.push(`  NG  JS の例外 — ${String(error).slice(0, 200)}`));
page.on("console", (message) => {
  if (message.type() === "error") problems.push(`  NG  コンソールのエラー — ${message.text().slice(0, 200)}`);
});

const docOf = () => page.evaluate(() => document.querySelector("tiptap-editor")?.getAttribute("doc") ?? "");

async function openNew(title) {
  await page.goto(base + "/p/default/c/blogs/new", { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  await page.locator("input").first().fill(title);
  await page.locator("tiptap-editor .tt-body").click();
}

async function save(step) {
  await page.getByRole("button", { name: "下書き保存" }).click();
  await page.waitForTimeout(1600);
  const body = (await page.textContent("body")) ?? "";
  check(body.includes("保存済み"), step, body.replace(/\s+/g, " ").slice(0, 200));
}

try {
  // 1. ツールバーの画像のボタン → ピッカー → 1 枚入れる
  await openNew(`image-check ${Date.now()}`);
  const imageButton = page.locator('.tt-tool[aria-label="画像"]');
  check((await imageButton.count()) === 1, "ツールバーに画像のボタンがある", `${await imageButton.count()} 個`);
  await imageButton.click();
  await page.waitForTimeout(900);
  const pickable = page.locator(".fixed .grid button");
  check((await pickable.count()) > 0, "メディアのピッカーが開く", `候補 ${await pickable.count()} 件`);
  await pickable.nth(0).click();
  await page.getByRole("button", { name: /本文に入れる/ }).click();
  await page.waitForTimeout(700);
  const one = JSON.parse((await docOf()) || "{}");
  const firstImage = (one.content ?? []).find((node) => node.type === "image");
  check(Boolean(firstImage), "本文に image が入る", JSON.stringify(one).slice(0, 200));
  check(
    Boolean(firstImage?.attrs?.assetId) && !("src" in (firstImage?.attrs ?? {})),
    "image は assetId を持ち src を持たない",
    JSON.stringify(firstImage?.attrs ?? {})
  );
  check((await page.locator(".tt-image img").count()) >= 1, "本文に画像が描かれる", "img が出ません");
  await save("画像を入れた下書きが保存できる");

  // 2. クリップボードから貼る
  await openNew(`image-paste ${Date.now()}`);
  const bytes = png(48, 32, (x, y) => [(x * 5) % 256, (y * 7) % 256, 180]);
  await page.evaluate(async (base64) => {
    const binary = atob(base64);
    const buffer = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) buffer[i] = binary.charCodeAt(i);
    const file = new File([buffer], "pasted.png", { type: "image/png" });
    const data = new DataTransfer();
    data.items.add(file);
    document
      .querySelector("tiptap-editor .tt-body")
      .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  }, bytes.toString("base64"));
  // **上がり切る前に見る。** 待ってから数えると、もう image に化けている。
  try {
    await page.waitForSelector(".tt-uploading", { timeout: 3000 });
    note("貼った直後に「送っています…」が出る");
  } catch {
    fail("貼った直後に「送っています…」が出る", "仮の見た目が出ませんでした");
  }
  await page.waitForTimeout(4000);
  const pasted = JSON.parse((await docOf()) || "{}");
  const pastedImage = (pasted.content ?? []).find((node) => node.type === "image");
  check(Boolean(pastedImage?.attrs?.assetId), "貼った画像が image になる", JSON.stringify(pasted).slice(0, 250));
  check((await page.locator(".tt-uploading").count()) === 0, "仮の見た目が消える", "残っています");
  await save("貼った画像を入れた下書きが保存できる");

  // 3. 2 枚以上で gallery になり、列の数を変えられる
  await openNew(`image-gallery ${Date.now()}`);
  await page.locator('.tt-tool[aria-label="画像"]').click();
  await page.waitForTimeout(900);
  const many = page.locator(".fixed .grid button");
  await many.nth(0).click();
  await many.nth(1).click();
  await many.nth(2).click();
  await page.getByRole("button", { name: /本文に入れる（3）/ }).click();
  await page.waitForTimeout(700);
  const grouped = JSON.parse((await docOf()) || "{}");
  const gallery = (grouped.content ?? []).find((node) => node.type === "gallery");
  check(Boolean(gallery), "2 枚以上で gallery になる", JSON.stringify(grouped).slice(0, 250));
  check(gallery?.content?.length === 3, "gallery に image が 3 つ入る", JSON.stringify(gallery?.content ?? []).slice(0, 200));
  check(
    (gallery?.content ?? []).every((child) => child.type === "image"),
    "gallery の中は image だけ",
    JSON.stringify(gallery?.content ?? []).slice(0, 200)
  );
  const cols = page.locator(".tt-gallery-cols");
  check((await cols.count()) === 1, "gallery の上に列の数の選択がある", `${await cols.count()} 個`);
  await cols.selectOption("4");
  await page.waitForTimeout(500);
  const wide = JSON.parse((await docOf()) || "{}");
  check(
    (wide.content ?? []).find((node) => node.type === "gallery")?.attrs?.columns === 4,
    "列の数を変えられる",
    JSON.stringify(wide).slice(0, 250)
  );
  await save("gallery を入れた下書きが保存できる");

  // 4. 中の画像を全部消すと gallery ごと消える
  await page.locator(".tt-gallery .tt-image").first().click();
  for (let i = 0; i < 3; i += 1) {
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(250);
  }
  const emptied = JSON.parse((await docOf()) || "{}");
  check(
    !(emptied.content ?? []).some((node) => node.type === "gallery" && (node.content ?? []).length === 0),
    "空の gallery は残らない",
    JSON.stringify(emptied).slice(0, 250)
  );

  // 5. 長い題は 1 行に収まり、ホバーで全部読める
  const long = "とても長いタイトルの見本です".repeat(6);
  await openNew(long);
  await page.waitForTimeout(500);
  const head = page.locator(".sticky.top-0 span.truncate").first();
  const box = await head.boundingBox();
  const barBox = await page.locator(".sticky.top-0").first().boundingBox();
  check(box.height < 30, "長い題が 1 行に収まる", `題の高さ ${box?.height}`);
  check(barBox.height < 80, "帯が縦に伸びない", `帯の高さ ${barBox?.height}`);
  check((await head.getAttribute("title")) === long, "題の title に元の文字が入る", String(await head.getAttribute("title")).slice(0, 60));
  // 6. 保存した物を CMS から読み直す。**画面の doc ではなく、入った物を見る。**
  const cms = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
  const found = await fetch(`${cms}/p/default/admin/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": process.env.VITE_DEV_USER ?? "dev@localhost" },
    body: JSON.stringify({
      query: `query entries { entries(typeId: "5", first: 10) { nodes { id fields } } }`,
    }),
  }).then((response) => response.json());
  const saved = JSON.stringify(found.data?.entries?.nodes ?? found);
  check(saved.includes('"type":"image"') && saved.includes("assetId"), "CMS に image(assetId) の形で入っている", saved.slice(0, 250));
  check(saved.includes('"type":"gallery"'), "CMS に gallery が入っている", saved.slice(0, 250));
} catch (error) {
  fail("途中で落ちた", String(error).slice(0, 400));
} finally {
  await browser.close();
}

console.log(steps.join("\n"));
if (problems.length > 0) {
  console.log("\n" + problems.join("\n"));
  process.exit(1);
}
console.log(`\n通りました（${steps.length} 件）。`);
