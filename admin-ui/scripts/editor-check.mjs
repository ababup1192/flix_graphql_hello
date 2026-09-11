// エディタの DOM の部品の見張り。`web/*.ts` のコード（コメントと文字列は見ない）を読んで、
// 帯と浮く面の手組みを止める。部品は `web/ui.ts`、決めは `docs/design/editor-dom-parts.md`。
//
// 使い方: npm run check の一部。単独なら  node scripts/editor-check.mjs
// 今の状態を固定する許可リストは scripts/editor-check-allow.json（ファイルと規則ごとの件数）。
//
// WhyNot: 部品を使う決めをレビューと記憶だけに置かない。2026-09-11 と 12 に直した 23 件の
// うち 9 件が「帯に文字が打てる」「浮く面が取り残される」で、部品で塞いだ後も手組みすれば戻る。
//
// WhyNot: 許可リストを行番号で持たない。1 行足しただけで全部ずれる。ファイルと規則ごとの
// 件数で持ち、増えた時だけ落とす。

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

// 部品そのものを書く場所。ここだけは手で組んで良い。
const PARTS = new Set(["web/ui.ts", "web/place.ts"]);

// [id, 正規表現, 直し方]
const rules = [
  [
    "editable",
    /\.contentEditable\s*=/,
    "帯は ui.ts の bar() / popover() で作る（contentEditable と押し始めの止めが部品に入っている）",
  ],
  [
    "measure",
    /\.getBoundingClientRect\s*\??\.?\s*\(|\.(offsetWidth|offsetHeight|offsetTop|offsetLeft)\b/,
    "浮く面の位置を自分で測らない。ui.ts の popover()（親を基準に置く）か place.ts の placeUnder() を使う。offsetWidth / offsetHeight も測定（?. 越しの rect も当てる）",
  ],
  [
    "bar",
    /\.className\s*=\s*["'`][^"'`]*-bar\b/,
    "帯の class を素の要素に付けない。ui.ts の bar({ className }) が帯を作る",
  ],
  [
    "place",
    /\.style\.(position|top|left|right|bottom|width|height)\s*=|\.style\.setProperty\s*\(|\.style\.cssText\s*=/,
    "面の置き所や大きさを直に書かない。ui.ts の popover() は親の中に置くので、本文を送っても取り残されない。setProperty / cssText / style.width / style.height も同じ",
  ],
];

/** コメントを空白に潰したコード。行番号は保つ。
 *
 * WhyNot: 文字列の中身まで潰さない。「帯の class を付けた」はリテラルを読まないと分からない。
 * 規則は `.名前 =` の形だけを見るので、文章の中に当たる心配は要らない。
 */
function codeOnly(source) {
  const out = source.split("");
  const blank = (from, to) => {
    for (let i = from; i < to && i < out.length; i++) if (out[i] !== "\n") out[i] = " ";
  };
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (c === "/" && source[i + 1] === "/") {
      const end = source.indexOf("\n", i);
      const to = end < 0 ? source.length : end;
      blank(i, to);
      i = to;
    } else if (c === "/" && source[i + 1] === "*") {
      const end = source.indexOf("*/", i + 2);
      const to = end < 0 ? source.length : end + 2;
      blank(i, to);
      i = to;
    }
  }
  return out.join("");
}

function* sourceFiles(dir) {
  for (const name of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, name.name);
    if (name.isDirectory()) yield* sourceFiles(path);
    else if (name.name.endsWith(".ts")) yield path;
  }
}

const allow = JSON.parse(readFileSync("scripts/editor-check-allow.json", "utf8"));
const allowed = new Map(allow.map((e) => [`${e.file}\u0000${e.rule}`, e.count]));

const found = new Map(); // file\0rule -> [{line, text}]
for (const path of [...sourceFiles("web")].sort()) {
  const key = path.split("\\").join("/");
  if (PARTS.has(key)) continue;
  const code = codeOnly(readFileSync(path, "utf8"));
  code.split("\n").forEach((line, index) => {
    for (const [id, pattern] of rules) {
      if (!pattern.test(line)) continue;
      const at = `${key}\u0000${id}`;
      if (!found.has(at)) found.set(at, []);
      found.get(at).push({ line: index + 1, text: line.trim().slice(0, 80) });
    }
  });
}

const problems = [];
for (const [at, hits] of found) {
  const [file, id] = at.split("\u0000");
  const limit = allowed.get(at) ?? 0;
  if (hits.length <= limit) continue;
  const hint = rules.find(([ruleId]) => ruleId === id)?.[2] ?? "";
  problems.push(
    `${file}: ${id} が ${hits.length} 件（許可は ${limit} 件）\n` +
      hits.map((h) => `      ${file}:${h.line}: ${h.text}`).join("\n") +
      `\n    → ${hint}`,
  );
}

// 許可リストが実際より多い時も知らせる（直した分を下げ忘れると、新しい手組みが隠れる）。
for (const [at, count] of allowed) {
  const [file, id] = at.split("\u0000");
  const hits = found.get(at)?.length ?? 0;
  if (hits < count) problems.push(`${file}: ${id} は ${hits} 件まで減っています。scripts/editor-check-allow.json の count を ${hits} に下げてください`);
}

if (problems.length) {
  console.error("エディタの部品の決めに合っていません（docs/design/editor-dom-parts.md）:\n");
  for (const p of problems) console.error("  " + p);
  process.exit(1);
}
console.log("editor-parts: OK");
