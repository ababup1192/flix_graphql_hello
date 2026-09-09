// 実際に動いている CMS に document を投げ、200 が返るか・errors が無いかを見る。
//
// 型が通ってもサーバに拒まれる物（操作名の食い違い、引数の形、権限）は Elm の型では防げない。
// ここで捕まえる。投げるのは Queries.all の読むだけの物だけ（実データを増やさない）。
//
// 使い方: CMS を上げてから  npm run contract

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const base = process.env.CMS_BASE ?? "http://127.0.0.1:8080";
const devUser = process.env.VITE_DEV_USER ?? "dev@localhost";

const work = mkdtempSync(join(tmpdir(), "contract-"));
const bundle = join(work, "contract.js");

try {
  execFileSync("npx", ["elm", "make", "src/Contract.elm", "--output", bundle], { stdio: "pipe" });
} catch (error) {
  console.error("Contract.elm のコンパイルに失敗しました");
  console.error(String(error.stdout ?? error));
  process.exit(1);
}

// Elm の出力はブラウザ想定なので、scope として globalThis を渡して Elm を受け取る。
const source = readFileSync(bundle, "utf8");
rmSync(work, { recursive: true, force: true });
const scope = {};
// Elm は末尾で `}(this)` を呼ぶので、this を scope にして Elm を受け取る。
new Function(source).call(scope);

const Elm = scope.Elm;
if (!Elm) {
  console.error("Contract.elm の出力から Elm を取り出せませんでした");
  process.exit(1);
}
const app = Elm.Contract.init({});
const envelopes = await new Promise((resolve) => app.ports.contractOut.subscribe(resolve));

let failed = 0;
for (const envelope of envelopes) {
  const response = await fetch(base + envelope.path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Dev-User": devUser },
    body: JSON.stringify({ query: envelope.document }),
  });
  const body = await response.json().catch(() => null);
  const errors = body?.errors ?? [];
  // **NOT_FOUND は通ったとみなす。** 見本の id（組織 "1" など）は実在しないが、
  // NOT_FOUND が返る＝ document が読まれて実行された、という事。
  // ここで見たいのは形と権限のずれで、データの有無ではない。
  const real = errors.filter((e) => e.extensions?.code !== "NOT_FOUND");
  if (!response.ok || real.length > 0) {
    failed += 1;
    const why = !response.ok ? `HTTP ${response.status}` : real.map((e) => `${e.extensions?.code ?? "?"}: ${e.message}`).join(" / ");
    console.error(`  NG  ${envelope.kind} (${envelope.path}) — ${why}`);
  } else {
    console.log(`  OK  ${envelope.kind}`);
  }
}

if (failed > 0) {
  console.error(`\n${failed} 本が CMS に拒まれました。SDL と document のずれか、権限を疑ってください。`);
  process.exit(1);
}
console.log(`\n${envelopes.length} 本すべて通りました。`);
