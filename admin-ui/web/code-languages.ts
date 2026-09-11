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
  // ファイル名から言語を決める時の拡張子（点は付けない）。無い言語は空でよい。
  //
  // WhyNot: 別名で兼ねない。別名は「人が打って探す語」で、拡張子は「ファイル名の末尾」。
  // `ts` のように重なる物もあるが、`h`（C）や `m`（Objective-C）のように、探す語としては
  // 出したくないが拡張子としては当てたい物がある。
  extensions?: string[];
  load: () => Promise<{ default: LanguageFn }>;
};

export const LANGUAGES: Language[] = [
  { id: "plaintext", label: "Plain text", aliases: ["text", "txt"], extensions: ["txt", "text"], load: () => import("highlight.js/lib/languages/plaintext") },

  // **図。** highlight.js に文法は無いので色は付かないが、選べないと入口が無い
  // （``` と打って `mermaid` と続ける事を知っている人しか使えない）。
  // 言語を `mermaid` にすると、コードの上に図が出る（CMS も同じ名前で受ける）。
  { id: "mermaid", label: "Mermaid", aliases: ["diagram", "ずかい", "図"], extensions: ["mmd"], load: () => import("highlight.js/lib/languages/plaintext") },

  // この CMS が書かれている物
  { id: "flix", label: "Flix", aliases: [], extensions: ["flix"], load: () => import("highlight.js/lib/languages/flix") },
  { id: "elm", label: "Elm", aliases: [], extensions: ["elm"], load: () => import("highlight.js/lib/languages/elm") },

  // Web
  { id: "typescript", label: "TypeScript", aliases: ["ts", "tsx"], extensions: ["ts", "tsx", "mts", "cts"], load: () => import("highlight.js/lib/languages/typescript") },
  { id: "javascript", label: "JavaScript", aliases: ["js", "jsx", "mjs"], extensions: ["js", "jsx", "mjs", "cjs"], load: () => import("highlight.js/lib/languages/javascript") },
  { id: "html", label: "HTML", aliases: ["xml", "svg", "vue", "svelte"], extensions: ["html", "htm", "xml", "svg", "vue", "svelte"], load: () => import("highlight.js/lib/languages/xml") },
  { id: "css", label: "CSS", aliases: [], extensions: ["css"], load: () => import("highlight.js/lib/languages/css") },
  { id: "scss", label: "SCSS", aliases: ["sass"], extensions: ["scss", "sass"], load: () => import("highlight.js/lib/languages/scss") },
  { id: "less", label: "Less", aliases: [], extensions: ["less"], load: () => import("highlight.js/lib/languages/less") },
  { id: "graphql", label: "GraphQL", aliases: ["gql"], extensions: ["graphql", "gql"], load: () => import("highlight.js/lib/languages/graphql") },

  // テンプレート
  // 別名は検索で当てるためだけに持つ（doc に入るのは id の 1 つ）。
  // 「Jinja」「ERB」のように、人が別の名前で覚えている物ほど別名が要る。
  { id: "django", label: "Django / Jinja", aliases: ["jinja", "jinja2", "j2"], extensions: ["jinja", "jinja2", "j2"], load: () => import("highlight.js/lib/languages/django") },
  { id: "twig", label: "Twig", aliases: [], extensions: ["twig"], load: () => import("highlight.js/lib/languages/twig") },
  { id: "handlebars", label: "Handlebars", aliases: ["hbs", "mustache"], extensions: ["hbs", "handlebars"], load: () => import("highlight.js/lib/languages/handlebars") },
  { id: "erb", label: "ERB", aliases: ["eruby", "rhtml"], extensions: ["erb"], load: () => import("highlight.js/lib/languages/erb") },

  // データと設定
  { id: "json", label: "JSON", aliases: [], extensions: ["json", "jsonc"], load: () => import("highlight.js/lib/languages/json") },
  { id: "yaml", label: "YAML", aliases: ["yml"], extensions: ["yaml", "yml"], load: () => import("highlight.js/lib/languages/yaml") },
  { id: "ini", label: "INI / TOML", aliases: ["toml", "conf"], extensions: ["toml", "ini", "cfg", "conf"], load: () => import("highlight.js/lib/languages/ini") },
  { id: "properties", label: "Properties", aliases: ["env"], extensions: ["properties", "env"], load: () => import("highlight.js/lib/languages/properties") },
  { id: "markdown", label: "Markdown", aliases: ["md"], extensions: ["md", "markdown"], load: () => import("highlight.js/lib/languages/markdown") },
  { id: "diff", label: "diff", aliases: ["patch"], extensions: ["diff", "patch"], load: () => import("highlight.js/lib/languages/diff") },
  { id: "http", label: "HTTP", aliases: [], extensions: ["http"], load: () => import("highlight.js/lib/languages/http") },

  // シェルと運用
  { id: "bash", label: "Bash", aliases: ["sh", "zsh", "shell"], extensions: ["sh", "bash", "zsh"], load: () => import("highlight.js/lib/languages/bash") },
  { id: "powershell", label: "PowerShell", aliases: ["ps1"], extensions: ["ps1", "psm1"], load: () => import("highlight.js/lib/languages/powershell") },
  { id: "dockerfile", label: "Dockerfile", aliases: ["docker"], extensions: ["dockerfile"], load: () => import("highlight.js/lib/languages/dockerfile") },
  { id: "makefile", label: "Makefile", aliases: ["make"], extensions: ["makefile", "mk"], load: () => import("highlight.js/lib/languages/makefile") },
  { id: "nginx", label: "nginx", aliases: [], load: () => import("highlight.js/lib/languages/nginx") },
  { id: "apache", label: "Apache", aliases: [], load: () => import("highlight.js/lib/languages/apache") },
  { id: "cmake", label: "CMake", aliases: [], extensions: ["cmake"], load: () => import("highlight.js/lib/languages/cmake") },
  { id: "nix", label: "Nix", aliases: [], extensions: ["nix"], load: () => import("highlight.js/lib/languages/nix") },
  { id: "puppet", label: "Puppet", aliases: ["pp"], extensions: ["pp"], load: () => import("highlight.js/lib/languages/puppet") },
  // Terraform（HCL）は highlight.js が文法を持たない。third-party を足してまでは入れない。

  // データベース
  { id: "sql", label: "SQL", aliases: [], extensions: ["sql"], load: () => import("highlight.js/lib/languages/sql") },
  { id: "pgsql", label: "PL/pgSQL", aliases: ["postgres", "postgresql"], load: () => import("highlight.js/lib/languages/pgsql") },

  // よく使う言語
  { id: "python", label: "Python", aliases: ["py"], extensions: ["py", "pyw", "pyi"], load: () => import("highlight.js/lib/languages/python") },
  { id: "ruby", label: "Ruby", aliases: ["rb"], extensions: ["rb", "rake", "gemspec"], load: () => import("highlight.js/lib/languages/ruby") },
  { id: "php", label: "PHP", aliases: [], extensions: ["php"], load: () => import("highlight.js/lib/languages/php") },
  { id: "java", label: "Java", aliases: [], extensions: ["java"], load: () => import("highlight.js/lib/languages/java") },
  { id: "kotlin", label: "Kotlin", aliases: ["kt"], extensions: ["kt", "kts"], load: () => import("highlight.js/lib/languages/kotlin") },
  { id: "scala", label: "Scala", aliases: [], extensions: ["scala", "sc"], load: () => import("highlight.js/lib/languages/scala") },
  { id: "groovy", label: "Groovy", aliases: [], extensions: ["groovy", "gradle"], load: () => import("highlight.js/lib/languages/groovy") },
  { id: "go", label: "Go", aliases: ["golang"], extensions: ["go"], load: () => import("highlight.js/lib/languages/go") },
  { id: "rust", label: "Rust", aliases: ["rs"], extensions: ["rs"], load: () => import("highlight.js/lib/languages/rust") },
  { id: "c", label: "C", aliases: [], extensions: ["c", "h"], load: () => import("highlight.js/lib/languages/c") },
  { id: "cpp", label: "C++", aliases: ["c++", "cc"], extensions: ["cpp", "cc", "cxx", "hpp", "hh"], load: () => import("highlight.js/lib/languages/cpp") },
  { id: "csharp", label: "C#", aliases: ["cs"], extensions: ["cs", "csx"], load: () => import("highlight.js/lib/languages/csharp") },
  { id: "swift", label: "Swift", aliases: [], extensions: ["swift"], load: () => import("highlight.js/lib/languages/swift") },
  { id: "objectivec", label: "Objective-C", aliases: ["objc"], extensions: ["m", "mm"], load: () => import("highlight.js/lib/languages/objectivec") },
  { id: "dart", label: "Dart", aliases: [], extensions: ["dart"], load: () => import("highlight.js/lib/languages/dart") },
  { id: "lua", label: "Lua", aliases: [], extensions: ["lua"], load: () => import("highlight.js/lib/languages/lua") },
  { id: "perl", label: "Perl", aliases: ["pl"], extensions: ["pl", "pm"], load: () => import("highlight.js/lib/languages/perl") },
  { id: "r", label: "R", aliases: [], extensions: ["r"], load: () => import("highlight.js/lib/languages/r") },
  { id: "julia", label: "Julia", aliases: [], extensions: ["jl"], load: () => import("highlight.js/lib/languages/julia") },
  { id: "matlab", label: "MATLAB", aliases: [], load: () => import("highlight.js/lib/languages/matlab") },
  { id: "nim", label: "Nim", aliases: [], extensions: ["nim"], load: () => import("highlight.js/lib/languages/nim") },
  { id: "haxe", label: "Haxe", aliases: [], extensions: ["hx"], load: () => import("highlight.js/lib/languages/haxe") },
  { id: "crystal", label: "Crystal", aliases: [], extensions: ["cr"], load: () => import("highlight.js/lib/languages/crystal") },
  { id: "vala", label: "Vala", aliases: [], extensions: ["vala"], load: () => import("highlight.js/lib/languages/vala") },
  { id: "tcl", label: "Tcl", aliases: ["tk"], extensions: ["tcl", "tk"], load: () => import("highlight.js/lib/languages/tcl") },
  { id: "arduino", label: "Arduino", aliases: ["ino"], extensions: ["ino"], load: () => import("highlight.js/lib/languages/arduino") },

  // 古いが現役で名前を聞く物
  { id: "fortran", label: "Fortran", aliases: ["f90", "f95"], extensions: ["f90", "f95", "f03", "for"], load: () => import("highlight.js/lib/languages/fortran") },
  { id: "delphi", label: "Delphi / Pascal", aliases: ["pascal", "objectpascal", "objfpc"], extensions: ["pas", "dpr"], load: () => import("highlight.js/lib/languages/delphi") },
  { id: "vbnet", label: "Visual Basic", aliases: ["vb", "vb.net", "visual basic"], extensions: ["vb"], load: () => import("highlight.js/lib/languages/vbnet") },
  { id: "ada", label: "Ada", aliases: [], extensions: ["adb", "ads"], load: () => import("highlight.js/lib/languages/ada") },
  // COBOL は highlight.js が文法を持たない（`cos` は Caché ObjectScript で別物）。

  // 関数型
  { id: "haskell", label: "Haskell", aliases: ["hs"], extensions: ["hs"], load: () => import("highlight.js/lib/languages/haskell") },
  { id: "ocaml", label: "OCaml", aliases: ["ml"], extensions: ["ml", "mli"], load: () => import("highlight.js/lib/languages/ocaml") },
  { id: "fsharp", label: "F#", aliases: ["fs"], extensions: ["fs", "fsx"], load: () => import("highlight.js/lib/languages/fsharp") },
  { id: "erlang", label: "Erlang", aliases: [], extensions: ["erl"], load: () => import("highlight.js/lib/languages/erlang") },
  { id: "elixir", label: "Elixir", aliases: ["ex"], extensions: ["ex", "exs"], load: () => import("highlight.js/lib/languages/elixir") },
  { id: "clojure", label: "Clojure", aliases: ["clj"], extensions: ["clj", "cljs", "cljc", "edn"], load: () => import("highlight.js/lib/languages/clojure") },
  { id: "scheme", label: "Scheme", aliases: [], extensions: ["scm", "ss"], load: () => import("highlight.js/lib/languages/scheme") },
  { id: "lisp", label: "Lisp", aliases: [], extensions: ["lisp", "lsp", "el"], load: () => import("highlight.js/lib/languages/lisp") },
  { id: "reasonml", label: "ReasonML", aliases: ["reason"], extensions: ["re"], load: () => import("highlight.js/lib/languages/reasonml") },
  { id: "sml", label: "Standard ML", aliases: [], extensions: ["sml"], load: () => import("highlight.js/lib/languages/sml") },
  { id: "d", label: "D", aliases: [], extensions: ["d"], load: () => import("highlight.js/lib/languages/d") },
  { id: "coffeescript", label: "CoffeeScript", aliases: ["coffee"], extensions: ["coffee"], load: () => import("highlight.js/lib/languages/coffeescript") },

  // その他
  { id: "protobuf", label: "Protocol Buffers", aliases: ["proto"], extensions: ["proto"], load: () => import("highlight.js/lib/languages/protobuf") },
  { id: "thrift", label: "Thrift", aliases: [], extensions: ["thrift"], load: () => import("highlight.js/lib/languages/thrift") },
  { id: "latex", label: "LaTeX", aliases: ["tex"], extensions: ["tex", "sty"], load: () => import("highlight.js/lib/languages/latex") },
  { id: "gherkin", label: "Gherkin", aliases: ["cucumber"], extensions: ["feature"], load: () => import("highlight.js/lib/languages/gherkin") },
  { id: "prolog", label: "Prolog", aliases: [], extensions: ["pro"], load: () => import("highlight.js/lib/languages/prolog") },
  { id: "verilog", label: "Verilog", aliases: [], extensions: ["v", "sv"], load: () => import("highlight.js/lib/languages/verilog") },
  { id: "vhdl", label: "VHDL", aliases: [], extensions: ["vhd", "vhdl"], load: () => import("highlight.js/lib/languages/vhdl") },
  { id: "wasm", label: "WebAssembly", aliases: ["wat"], extensions: ["wat", "wasm"], load: () => import("highlight.js/lib/languages/wasm") },
  { id: "x86asm", label: "x86 Assembly", aliases: ["asm"], extensions: ["asm", "s"], load: () => import("highlight.js/lib/languages/x86asm") },
  { id: "armasm", label: "ARM Assembly", aliases: ["arm", "asm"], load: () => import("highlight.js/lib/languages/armasm") },
  { id: "dos", label: "Batch", aliases: ["bat", "batch", "cmd"], extensions: ["bat", "cmd"], load: () => import("highlight.js/lib/languages/dos") },
  { id: "vim", label: "Vim script", aliases: [], extensions: ["vim"], load: () => import("highlight.js/lib/languages/vim") },
  { id: "awk", label: "AWK", aliases: [], extensions: ["awk"], load: () => import("highlight.js/lib/languages/awk") },
];

const byId = new Map(LANGUAGES.map((language) => [language.id, language]));

// 拡張子 → 言語の id。**先に書いてある言語が勝つ**（`ts` は TypeScript、`m` は Objective-C）。
//
// 紛らわしい物は「よく使われる方」に倒した: `.m` は Objective-C（MATLAB ではない）、
// `.h` は C（C++ / Objective-C ではない）、`.pl` は Perl（Prolog は `.pro`）、`.r` は R。
const byExtension = new Map<string, string>();
for (const language of LANGUAGES) {
  for (const extension of language.extensions ?? []) {
    if (!byExtension.has(extension)) byExtension.set(extension, language.id);
  }
}

/** ファイル名から言語の id を決める。当てが無ければ空。
 *
 * 拡張子が無いファイル名（`Dockerfile` / `Makefile`）は、名前そのものを拡張子として引く。
 */
export function extensionOf(fileName: string): string {
  const name = fileName.trim().toLowerCase().split(/[/\\]/).pop() ?? "";
  if (name === "") return "";
  const dot = name.lastIndexOf(".");
  const key = dot > 0 ? name.slice(dot + 1) : name;
  return byExtension.get(key) ?? "";
}

export function labelOf(id: string): string {
  if (!id) return "";
  return byId.get(id)?.label ?? id;
}

// 候補の 1 行。`id` は doc に入る正の名前で、行に出る素の名前でもある。
export type Option = { id: string; aliases: string[] };

// **別名は独立した行にしない。** `co` で coffee と coffeescript が並ぶと、同じ言語が 2 行に
// 分かれ、どちらが正式名か分からない。正式名の行に薄く添える。
export function search(query: string): Option[] {
  const needle = query.trim().toLowerCase();
  const hits = needle
    ? LANGUAGES.filter(
        (language) =>
          language.id.includes(needle) ||
          language.label.toLowerCase().includes(needle) ||
          language.aliases.some((alias) => alias.includes(needle))
      )
    : LANGUAGES;
  // 前方一致を先に出す（"c" で c が objectivec より先）。別名の前方一致も同じ重さで拾う。
  const heads = (language: Language) =>
    Number(language.id.startsWith(needle) || language.aliases.some((alias) => alias.startsWith(needle)));
  return [...hits]
    .sort((a, b) => heads(b) - heads(a) || a.id.localeCompare(b.id))
    .map((language) => ({ id: language.id, aliases: language.aliases }));
}

// 候補のアイコン。**外部の画像を読まない。** Devicon のような一式を CDN から読むと依存が増え、
// オフラインで崩れる。`Ui.initialMark` と同じで、頭の 2 文字を id から決まる色の四角に載せる。
export function markOf(option: Option): { text: string; tone: number } {
  let hash = 7;
  for (const letter of option.id) hash = (hash * 31 + letter.charCodeAt(0)) % 4096;
  return { text: option.id.slice(0, 2).toUpperCase(), tone: (hash % 8) + 1 };
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
