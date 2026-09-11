// 画面に出す文字列の禁則。src/ の Elm の文字列リテラルだけを見る（コメントと識別子は見ない）。
//
// 使い方: npm run check の一部。単独なら  node scripts/wording-check.mjs
//
// WhyNot: 禁則をレビューと記憶だけに置かない。「版」は 2026-09-08 に決めた後も何度も入り込んだ。
// 決めた言葉は docs/design/admin-ui-spec.md の「言葉」の節が正で、ここはその機械の写し。

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// [正規表現, 直し方]。文字列リテラルの中身に当たれば落とす。
const rules = [
  // 「版」を単体で使わない。entry の履歴は「バージョン」、番号は「v3」。公開版 / 下書き版 の接尾辞は可
  [/(?<![公開下書き])版/u, "「版」は単体で使わない。番号は v3、名詞は「バージョン」（公開版 / 下書き版 は可）"],
  // 管理画面では content type を「API」と呼ぶ（サイドバー「API」「+ API を作る」）
  [/(?<![のる])型(?=[をがのにと]|$)/u, "content type は「API」。「型」は使わない（「コンテンツの型です」のような説明の中は可なら文を変える）"],
  // entry は「コンテンツ」。asset は「メディア」
  [/(?<![A-Za-z_./#])entry(?![A-Za-z_.:])/u, "entry は画面では「コンテンツ」（action 名や id の中は可）"],
  [/取り下げ/u, "unpublish は「公開を終える」「公開終了」"],
  // 動詞は漢語（作成 / 追加 / 削除 / 変更 / 修正）。和語の動詞は画面に出さない（spec 7.1）
  // まず過去形（出来事の文）と、エンジニアの口語だけ。現在形のボタン（作る / 消す）は 7.1 の全件点検で追う
  [/(?<![取り選び])(作った|足した|消した|直した|変えた|入れた|叩く|叩い|投げる|投げた|繋ぐ|繋いだ)/u, "動詞は 作成 / 追加 / 削除 / 変更 / 修正（spec 7.1。和語の動詞は出さない）"],
  [/並び替え/u, "並べ替え（API スキーマの画面と同じ綴り）"],
  [/ゴミ箱/u, "削除は「削除」。ゴミ箱の語は画面に無い"],
];

// 「文字列リテラル」だけを拾う。""" … """ と "…"（エスケープ込み）。
const literal = /"""([\s\S]*?)"""|"((?:[^"\\\n]|\\.)*)"/g;

function* elmFiles(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) yield* elmFiles(path);
    else if (name.endsWith(".elm")) yield path;
  }
}

const problems = [];
for (const path of elmFiles("src")) {
  const source = readFileSync(path, "utf8");
  for (const match of source.matchAll(literal)) {
    const body = match[1] ?? match[2] ?? "";
    // action 名（"entry.published" のような機械の綴り）と URL / クラス名は見ない
    if (/^[a-z_.]+$/.test(body) || /^https?:/.test(body) || /^[a-z0-9 :\-\[\]()_./%]+$/i.test(body)) continue;
    for (const [pattern, hint] of rules) {
      if (pattern.test(body)) {
        const line = source.slice(0, match.index).split("\n").length;
        problems.push(`${path}:${line}: ${JSON.stringify(body.slice(0, 60))}\n    → ${hint}`);
      }
    }
  }
}

if (problems.length) {
  console.error("画面の文言が決めに合っていません（docs/design/admin-ui-spec.md「言葉」）:\n");
  for (const p of problems) console.error("  " + p);
  process.exit(1);
}
console.log("wording: OK");
