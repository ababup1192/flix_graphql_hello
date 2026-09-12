// generated/ が SDL（../admin.graphql / ../account.graphql）と同じ物か見張る。
//
// 使い方: npm run check の一部。単独なら  node scripts/gen-check.mjs
// 直すには  npm run gen
//
// WhyNot: 生成し直して git の差分を見る形にしない。作業ツリーを書き換えると、直している途中の
// 他の差分と混ざって何が自分の変更か分からなくなる。別の場所に生成して比べ、ツリーは触らない。
//
// WhyNot: Flix 側の TestApiSurface に任せない。あれは SDL の面を見張る物で、Elm の生成物が
// SDL に追従しているかは見ない。2026-09-12 に SDL だけ進んで generated/ が遅れたまま
// コミットされ、別の目的で npm run gen を走らせた時に初めて型で落ちた。

import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

const targets = [
  { schema: "../admin.graphql", base: "Api.Admin", codecs: "ScalarCodecs" },
  { schema: "../account.graphql", base: "Api.Account", codecs: "AccountCodecs" },
];

function* files(dir) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) yield* files(path);
    else yield path;
  }
}

// 中身で比べる。生成物の日時などは無い（elm-graphql は決定的）。
function snapshot(root) {
  const out = new Map();
  for (const path of files(root)) out.set(relative(root, path), readFileSync(path, "utf8"));
  return out;
}

const scratch = mkdtempSync(join(tmpdir(), "elm-graphql-"));
try {
  for (const t of targets) {
    execFileSync(
      "npx",
      ["elm-graphql", "--schema-file", t.schema, "--base", t.base, "--output", scratch, "--scalar-codecs", t.codecs],
      { stdio: ["ignore", "ignore", "inherit"] },
    );
  }

  const fresh = snapshot(scratch);
  const committed = snapshot("generated");
  const stale = [];
  for (const [path, text] of fresh) if (committed.get(path) !== text) stale.push(path);
  for (const path of committed.keys()) if (!fresh.has(path)) stale.push(path);

  if (stale.length > 0) {
    console.error("generated/ が SDL から遅れています。npm run gen を走らせてコミットに含めてください:");
    for (const path of stale.sort()) console.error(`  generated/${path}`);
    process.exit(1);
  }
  console.log("gen: OK");
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
