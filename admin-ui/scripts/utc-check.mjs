// CMS から来る UTC の日時を、変換せずに画面へ出していないか見張る。src/ の Elm だけを見る。
//
// 使い方: npm run check の一部。単独なら  node scripts/utc-check.mjs
//
// WhyNot: 変換の単体テストだけに置かない。2026-09-12 のずれは変換ではなく**呼び忘れ**で、
// コンテンツ一覧だけが String.left 16 で切って出していた（一覧 07:49 / エディタ 16:49）。
// 落ちるのは `〜At` という名前の値を文字列として切る・繋ぐ形だけ。Ui/DateTime.elm は変換の本体なので見ない。

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// 日時の値（createdAt・updatedAt・runAt…）を文字列として切る／置き換える形。
const slicing =
  /String\.(?:left|right|slice|dropLeft|dropRight|replace)\b[^\n]*?\b\w*[a-z]At\b/;

const hint =
  "UTC の ISO 8601 をそのまま出さない。Ui.DateTime の formatLocal / formatLocalShort / localDate を通す";

function* sourceFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) yield* sourceFiles(path);
    else if (name.endsWith(".elm")) yield path;
  }
}

const problems = [];
for (const path of sourceFiles("src")) {
  if (path === join("src", "Ui", "DateTime.elm")) continue;
  const lines = readFileSync(path, "utf8").split("\n");
  lines.forEach((line, at) => {
    if (slicing.test(line)) problems.push(`${path}:${at + 1}: ${line.trim()}\n    → ${hint}`);
  });
}

if (problems.length) {
  console.error("手元のタイムゾーンに直していない日時が残っています:\n");
  for (const p of problems) console.error("  " + p);
  process.exit(1);
}
console.log("utc: OK");
