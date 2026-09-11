// コードブロックの言語。
//
// **要る物だけ後から読む。** highlight.js は 190 以上の言語を持つが、全部を最初に読むと
// エディタを開くだけで重くなる。ここは名前と読み込み方だけを持ち、実際の文法は
// 使われた時に import する。
//
// 選ぶ基準:
//   - 人が実際に貼るコードの言語（設定ファイル・シェル・SQL も含む）
//   - バージョン違いは持たない（`python3` のような名前は作らない）
//   - REPL の変種（`python-repl` など）と、極端に使われない物は入れない
//   - Flix と Elm は入れる（この CMS 自身がそれで書かれている）
//   - 古くても名前を聞く物（COBOL 世代の現役言語）までは入れる。歴史上の言語（Simula・Algol）は入れない

import type { LanguageFn } from "highlight.js";

export type Language = {
  // CMS に保存する名前。`[a-z][a-z0-9-]*`
  id: string;
  // 人に見せる名前
  label: string;
  // 検索で当てる別名（"js" で javascript が出る）
  aliases: string[];
  load: () => Promise<{ default: LanguageFn }>;
};

export const LANGUAGES: Language[] = [
  { id: "plaintext", label: "プレーンテキスト", aliases: ["text", "txt"], load: () => import("highlight.js/lib/languages/plaintext") },

  // **図。** highlight.js に文法は無いので色は付かないが、選べないと入口が無い
  // （``` と打って `mermaid` と続ける事を知っている人しか使えない）。
  // 言語を `mermaid` にすると、コードの上に図が出る（CMS も同じ名前で受ける）。
  { id: "mermaid", label: "図（mermaid）", aliases: ["diagram", "ずかい", "図"], load: () => import("highlight.js/lib/languages/plaintext") },

  // この CMS が書かれている物
  { id: "flix", label: "Flix", aliases: [], load: () => import("highlight.js/lib/languages/flix") },
  { id: "elm", label: "Elm", aliases: [], load: () => import("highlight.js/lib/languages/elm") },

  // Web
  { id: "typescript", label: "TypeScript", aliases: ["ts", "tsx"], load: () => import("highlight.js/lib/languages/typescript") },
  { id: "javascript", label: "JavaScript", aliases: ["js", "jsx", "mjs"], load: () => import("highlight.js/lib/languages/javascript") },
  { id: "html", label: "HTML", aliases: ["xml", "svg", "vue", "svelte"], load: () => import("highlight.js/lib/languages/xml") },
  { id: "css", label: "CSS", aliases: [], load: () => import("highlight.js/lib/languages/css") },
  { id: "scss", label: "SCSS", aliases: ["sass"], load: () => import("highlight.js/lib/languages/scss") },
  { id: "less", label: "Less", aliases: [], load: () => import("highlight.js/lib/languages/less") },
  { id: "graphql", label: "GraphQL", aliases: ["gql"], load: () => import("highlight.js/lib/languages/graphql") },

  // テンプレート
  // 別名は検索で当てるためだけに持つ（doc に入るのは id の 1 つ）。
  // 「Jinja」「ERB」のように、人が別の名前で覚えている物ほど別名が要る。
  { id: "django", label: "Django / Jinja", aliases: ["jinja", "jinja2", "j2"], load: () => import("highlight.js/lib/languages/django") },
  { id: "twig", label: "Twig", aliases: [], load: () => import("highlight.js/lib/languages/twig") },
  { id: "handlebars", label: "Handlebars", aliases: ["hbs", "mustache"], load: () => import("highlight.js/lib/languages/handlebars") },
  { id: "erb", label: "ERB", aliases: ["eruby", "rhtml"], load: () => import("highlight.js/lib/languages/erb") },

  // データと設定
  { id: "json", label: "JSON", aliases: [], load: () => import("highlight.js/lib/languages/json") },
  { id: "yaml", label: "YAML", aliases: ["yml"], load: () => import("highlight.js/lib/languages/yaml") },
  { id: "ini", label: "INI / TOML", aliases: ["toml", "conf"], load: () => import("highlight.js/lib/languages/ini") },
  { id: "properties", label: "Properties", aliases: ["env"], load: () => import("highlight.js/lib/languages/properties") },
  { id: "markdown", label: "Markdown", aliases: ["md"], load: () => import("highlight.js/lib/languages/markdown") },
  { id: "diff", label: "差分", aliases: ["patch"], load: () => import("highlight.js/lib/languages/diff") },
  { id: "http", label: "HTTP", aliases: [], load: () => import("highlight.js/lib/languages/http") },

  // シェルと運用
  { id: "bash", label: "Bash", aliases: ["sh", "zsh", "shell"], load: () => import("highlight.js/lib/languages/bash") },
  { id: "powershell", label: "PowerShell", aliases: ["ps1"], load: () => import("highlight.js/lib/languages/powershell") },
  { id: "dockerfile", label: "Dockerfile", aliases: ["docker"], load: () => import("highlight.js/lib/languages/dockerfile") },
  { id: "makefile", label: "Makefile", aliases: ["make"], load: () => import("highlight.js/lib/languages/makefile") },
  { id: "nginx", label: "nginx", aliases: [], load: () => import("highlight.js/lib/languages/nginx") },
  { id: "apache", label: "Apache", aliases: [], load: () => import("highlight.js/lib/languages/apache") },
  { id: "cmake", label: "CMake", aliases: [], load: () => import("highlight.js/lib/languages/cmake") },
  { id: "nix", label: "Nix", aliases: [], load: () => import("highlight.js/lib/languages/nix") },
  { id: "puppet", label: "Puppet", aliases: ["pp"], load: () => import("highlight.js/lib/languages/puppet") },
  // Terraform（HCL）は highlight.js が文法を持たない。third-party を足してまでは入れない。

  // データベース
  { id: "sql", label: "SQL", aliases: [], load: () => import("highlight.js/lib/languages/sql") },
  { id: "pgsql", label: "PL/pgSQL", aliases: ["postgres", "postgresql"], load: () => import("highlight.js/lib/languages/pgsql") },

  // よく使う言語
  { id: "python", label: "Python", aliases: ["py"], load: () => import("highlight.js/lib/languages/python") },
  { id: "ruby", label: "Ruby", aliases: ["rb"], load: () => import("highlight.js/lib/languages/ruby") },
  { id: "php", label: "PHP", aliases: [], load: () => import("highlight.js/lib/languages/php") },
  { id: "java", label: "Java", aliases: [], load: () => import("highlight.js/lib/languages/java") },
  { id: "kotlin", label: "Kotlin", aliases: ["kt"], load: () => import("highlight.js/lib/languages/kotlin") },
  { id: "scala", label: "Scala", aliases: [], load: () => import("highlight.js/lib/languages/scala") },
  { id: "groovy", label: "Groovy", aliases: [], load: () => import("highlight.js/lib/languages/groovy") },
  { id: "go", label: "Go", aliases: ["golang"], load: () => import("highlight.js/lib/languages/go") },
  { id: "rust", label: "Rust", aliases: ["rs"], load: () => import("highlight.js/lib/languages/rust") },
  { id: "c", label: "C", aliases: [], load: () => import("highlight.js/lib/languages/c") },
  { id: "cpp", label: "C++", aliases: ["c++", "cc"], load: () => import("highlight.js/lib/languages/cpp") },
  { id: "csharp", label: "C#", aliases: ["cs"], load: () => import("highlight.js/lib/languages/csharp") },
  { id: "swift", label: "Swift", aliases: [], load: () => import("highlight.js/lib/languages/swift") },
  { id: "objectivec", label: "Objective-C", aliases: ["objc"], load: () => import("highlight.js/lib/languages/objectivec") },
  { id: "dart", label: "Dart", aliases: [], load: () => import("highlight.js/lib/languages/dart") },
  { id: "lua", label: "Lua", aliases: [], load: () => import("highlight.js/lib/languages/lua") },
  { id: "perl", label: "Perl", aliases: ["pl"], load: () => import("highlight.js/lib/languages/perl") },
  { id: "r", label: "R", aliases: [], load: () => import("highlight.js/lib/languages/r") },
  { id: "julia", label: "Julia", aliases: [], load: () => import("highlight.js/lib/languages/julia") },
  { id: "matlab", label: "MATLAB", aliases: [], load: () => import("highlight.js/lib/languages/matlab") },
  { id: "nim", label: "Nim", aliases: [], load: () => import("highlight.js/lib/languages/nim") },
  { id: "haxe", label: "Haxe", aliases: [], load: () => import("highlight.js/lib/languages/haxe") },
  { id: "crystal", label: "Crystal", aliases: [], load: () => import("highlight.js/lib/languages/crystal") },
  { id: "vala", label: "Vala", aliases: [], load: () => import("highlight.js/lib/languages/vala") },
  { id: "tcl", label: "Tcl", aliases: ["tk"], load: () => import("highlight.js/lib/languages/tcl") },
  { id: "arduino", label: "Arduino", aliases: ["ino"], load: () => import("highlight.js/lib/languages/arduino") },

  // 古いが現役で名前を聞く物
  { id: "fortran", label: "Fortran", aliases: ["f90", "f95"], load: () => import("highlight.js/lib/languages/fortran") },
  { id: "delphi", label: "Delphi / Pascal", aliases: ["pascal", "objectpascal", "objfpc"], load: () => import("highlight.js/lib/languages/delphi") },
  { id: "vbnet", label: "Visual Basic", aliases: ["vb", "vb.net", "visual basic"], load: () => import("highlight.js/lib/languages/vbnet") },
  { id: "ada", label: "Ada", aliases: [], load: () => import("highlight.js/lib/languages/ada") },
  // COBOL は highlight.js が文法を持たない（`cos` は Caché ObjectScript で別物）。

  // 関数型
  { id: "haskell", label: "Haskell", aliases: ["hs"], load: () => import("highlight.js/lib/languages/haskell") },
  { id: "ocaml", label: "OCaml", aliases: ["ml"], load: () => import("highlight.js/lib/languages/ocaml") },
  { id: "fsharp", label: "F#", aliases: ["fs"], load: () => import("highlight.js/lib/languages/fsharp") },
  { id: "erlang", label: "Erlang", aliases: [], load: () => import("highlight.js/lib/languages/erlang") },
  { id: "elixir", label: "Elixir", aliases: ["ex"], load: () => import("highlight.js/lib/languages/elixir") },
  { id: "clojure", label: "Clojure", aliases: ["clj"], load: () => import("highlight.js/lib/languages/clojure") },
  { id: "scheme", label: "Scheme", aliases: [], load: () => import("highlight.js/lib/languages/scheme") },
  { id: "lisp", label: "Lisp", aliases: [], load: () => import("highlight.js/lib/languages/lisp") },
  { id: "reasonml", label: "ReasonML", aliases: ["reason"], load: () => import("highlight.js/lib/languages/reasonml") },
  { id: "sml", label: "Standard ML", aliases: [], load: () => import("highlight.js/lib/languages/sml") },
  { id: "d", label: "D", aliases: [], load: () => import("highlight.js/lib/languages/d") },
  { id: "coffeescript", label: "CoffeeScript", aliases: ["coffee"], load: () => import("highlight.js/lib/languages/coffeescript") },

  // その他
  { id: "protobuf", label: "Protocol Buffers", aliases: ["proto"], load: () => import("highlight.js/lib/languages/protobuf") },
  { id: "thrift", label: "Thrift", aliases: [], load: () => import("highlight.js/lib/languages/thrift") },
  { id: "latex", label: "LaTeX", aliases: ["tex"], load: () => import("highlight.js/lib/languages/latex") },
  { id: "gherkin", label: "Gherkin", aliases: ["cucumber"], load: () => import("highlight.js/lib/languages/gherkin") },
  { id: "prolog", label: "Prolog", aliases: [], load: () => import("highlight.js/lib/languages/prolog") },
  { id: "verilog", label: "Verilog", aliases: [], load: () => import("highlight.js/lib/languages/verilog") },
  { id: "vhdl", label: "VHDL", aliases: [], load: () => import("highlight.js/lib/languages/vhdl") },
  { id: "wasm", label: "WebAssembly", aliases: ["wat"], load: () => import("highlight.js/lib/languages/wasm") },
  { id: "x86asm", label: "アセンブリ（x86）", aliases: ["asm"], load: () => import("highlight.js/lib/languages/x86asm") },
  { id: "armasm", label: "アセンブリ（ARM）", aliases: ["arm", "asm"], load: () => import("highlight.js/lib/languages/armasm") },
  { id: "dos", label: "バッチファイル", aliases: ["bat", "batch", "cmd"], load: () => import("highlight.js/lib/languages/dos") },
  { id: "vim", label: "Vim script", aliases: [], load: () => import("highlight.js/lib/languages/vim") },
  { id: "awk", label: "AWK", aliases: [], load: () => import("highlight.js/lib/languages/awk") },
];

const byId = new Map(LANGUAGES.map((language) => [language.id, language]));

export function labelOf(id: string): string {
  if (!id) return "言語を選ぶ";
  return byId.get(id)?.label ?? id;
}

// 打った文字で絞る。id・表示名・別名のどれに当たっても出す。
export function search(query: string): Language[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return LANGUAGES;
  const hits = LANGUAGES.filter(
    (language) =>
      language.id.includes(needle) ||
      language.label.toLowerCase().includes(needle) ||
      language.aliases.some((alias) => alias.includes(needle))
  );
  // 前方一致を先に出す（"c" で C が Objective-C より先）。
  return hits.sort((a, b) => Number(b.id.startsWith(needle)) - Number(a.id.startsWith(needle)));
}

type Lowlight = {
  registered: (name: string) => boolean;
  register: (name: string, definition: LanguageFn) => void;
};

const loading = new Map<string, Promise<void>>();

// 文法を読み込んで lowlight に登録する。**同じ言語は 1 回だけ読む。**
export function ensure(lowlight: Lowlight, id: string): Promise<void> {
  if (!id) return Promise.resolve();
  if (lowlight.registered(id)) return Promise.resolve();
  const language = byId.get(id);
  if (!language) return Promise.resolve();
  const already = loading.get(id);
  if (already) return already;
  const task = language
    .load()
    .then((module) => {
      if (!lowlight.registered(id)) lowlight.register(id, module.default);
    })
    .catch(() => {
      // 読めなくても色が付かないだけ。書けなくはしない。
    });
  loading.set(id, task);
  return task;
}
