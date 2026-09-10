///
/// 型ごとの「パスの形」。型紙（`/blog/{slug}`）から、entry がサイト上で持つ path を作る。全部純粋。
///
/// **URL の形は CMS が持つ。** 持たないと、本文のコンテンツへのリンクが id しか運べず、
/// サイトが id → path の対応を自分で書く事になる（Contentful と Sanity はそうしている）。
/// 型紙を 1 つ持てば `RichText.toHtml` が最初から踏める href を出せる。
///
/// 使える印は `{id}` と `{slug}` の 2 つ。`{slug}` は値が無ければ id に落ちる（リンクが壊れない）。
/// 型紙が無い型は今まで通り `#entry:{id}` で、サイトが `data-entry-id` を見て置き換える。
///
mod LinkPath {

    /// 型紙に使える印。
    pub def tokens(): List[String] = "id" :: "slug" :: Nil

    ///
    /// 型紙に id と slug を差し込む。
    ///
    /// WhyNot: slug を percent encode しない。SLUG のフィールドは元にした文字から作る物で、
    /// `/` や空白が入るのは設定の間違い。ここで encode すると `%2F` になって黙って通ってしまう。
    ///
    pub def render(template: String, id: String, slug: Option[String]): String =
        let value = slug |> Option.filter(String.nonEmpty) |> Option.getWithDefault(id);
        template
            |> String.replace(src = "{id}", dst = id)
            |> String.replace(src = "{slug}", dst = value)

    /// 型紙があれば path。無ければ None。
    pub def of(template: Option[String], id: String, slug: Option[String]): Option[String] =
        template |> Option.filter(String.nonEmpty) |> Option.map(found -> render(found, id, slug))

    /// 本文のリンクに出す href。型紙が無ければ `#entry:{id}`。
    pub def href(template: Option[String], id: String, slug: Option[String]): String =
        of(template, id, slug) |> Option.getWithDefault("#entry:${id}")

    ///
    /// 型紙の検査。空は「設定なし」なので通る。
    ///
    /// WhyNot: `javascript:` を弾くだけにしない。`//evil.example.com/` は scheme 相対で、
    /// `/` で始まるのに別のホストへ飛ぶ。始まりを `/`（ただし `//` は除く）と http(s):// に絞る。
    ///
    pub def check(path: String, template: String): List[Violation] =
        if (String.isEmpty(template)) Nil
        else checkStart(path, template) ::: checkTokens(path, template)

    def checkStart(path: String, template: String): List[Violation] =
        let absolute = String.startsWith(prefix = "http://", template) or String.startsWith(prefix = "https://", template);
        let rooted = String.startsWith(prefix = "/", template) and not String.startsWith(prefix = "//", template);
        if (absolute or rooted) Nil
        else Violation.Violation(path, "パスの形は / か http:// か https:// で始めてください") :: Nil

    ///
    /// `{...}` を左から読み、知らない物と閉じていない物を止める。
    ///
    def checkTokens(path: String, template: String): List[Violation] =
        if (readTokens(String.toList(template), false, Nil))
            Nil
        else
            Violation.Violation(path, "パスの形に使えるのは ${tokens() |> List.map(name -> "{${name}}") |> List.join(" と ")} だけです") :: Nil

    /// (残りの文字, `{` の中か, 中で積んだ文字（逆順）) を左から畳む。全部読み切って外に居れば通る。
    def readTokens(rest: List[Char], inside: Bool, acc: List[Char]): Bool = match rest {
        case Nil        => not inside
        case c :: after => match (c, inside) {
            case ('{', false) => readTokens(after, true, Nil)
            case ('{', true)  => false
            case ('}', false) => false
            case ('}', true)  =>
                let name = acc |> List.reverse |> List.map(Char.toString) |> List.join("");
                if (List.memberOf(name, tokens())) readTokens(after, false, Nil) else false
            case (_, true)    => readTokens(after, true, c :: acc)
            case (_, false)   => readTokens(after, false, Nil)
        }
    }

}
