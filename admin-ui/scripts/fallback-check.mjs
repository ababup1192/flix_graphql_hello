// 解析に失敗した時の「暗黙の既定値」を見張る。src/ の Elm だけを見る。
//
// 使い方: npm run check の一部。単独なら  node scripts/fallback-check.mjs
//
// WhyNot: レビューと記憶だけに置かない。2026-09-12 に踏んだ 3 件は全部この形で、
// Maybe.withDefault "default" はサイドバーのリンク先を丸ごと別のプロジェクトに変えていた。
// 落ちるのは**識別子の形をした文字列**（slug・id・キーの名前）だけ。画面に出す日本語の
// 言い換え（Maybe.withDefault "プロジェクト未選択"）や、空文字は見ない。

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Maybe.withDefault のすぐ後ろに来る文字列リテラル。
const withDefault = /Maybe\.withDefault\s+"([^"\\\n]*)"/g;

// 識別子の形。slug（tech-blog）・id（p1）・キーの名前（apiId）が当たる。
const identifierLike = /^[a-z][a-z0-9]*(?:[-_][a-z0-9]+)*$/;

// 落ちた時の直し方。
const hint =
  "解析に失敗した時に別の有効な値へ落とさない。Maybe のまま返して呼ぶ側で分岐するか、" +
  "Route.NotFound のように「読めなかった」を型で持つ";

// 見逃す物。**解析の結果ではない**既定値だけを、理由を書いて載せる。
const allowed = new Map([
  ["src/Page/Schema.elm:list", "読み込み中にどのアイコンを押した形にするか。URL も id も決めていない"],
]);

function* sourceFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) yield* sourceFiles(path);
    else if (name.endsWith(".elm")) yield path;
  }
}

const problems = [];
for (const path of sourceFiles("src")) {
  const source = readFileSync(path, "utf8");
  for (const m of source.matchAll(withDefault)) {
    if (!identifierLike.test(m[1])) continue;
    if (allowed.has(`${path}:${m[1]}`)) continue;
    const line = source.slice(0, m.index).split("\n").length;
    problems.push(`${path}:${line}: Maybe.withDefault ${JSON.stringify(m[1])}\n    → ${hint}`);
  }
}

if (problems.length) {
  console.error("解析に失敗した時の既定値が残っています:\n");
  for (const p of problems) console.error("  " + p);
  process.exit(1);
}
console.log("fallback: OK");
