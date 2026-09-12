///
/// microCMS のスキーマをこの CMS の型に写し、ダミーの entry を作って公開する（器の確認用）。
/// 既存のユースケース（ContentTypes / ContentEntries / Assets）だけを通るので、検査も Webhook も通常と同じ。
///
mod MicrocmsImport {

    use Util.Json.Json
    use MicrocmsSchema.Api
    use MicrocmsSchema.Field
    use MicrocmsSchema.Kind
    use Net.HttpRequest
    use Net.HttpResponse

    /// 写した型。endpoint → TypeId。
    pub type alias Types = Map[String, TypeId]

    ///
    /// 全 API の型を作り、フィールドを足す。参照は全部の型を作った後に足す（相互参照と自己参照のため）。
    /// 写せないフィールドがあれば何もせず invalid（1 つずつ path に "schema"、文言に API 名.フィールド名: 種類）。
    ///
    pub def importSchema(apis: List[Api]): Types \ Db + CmsErr + IdGen + Tenant + Session =
        CmsErr.raiseIfAny(apis |> List.flatMap(MicrocmsSchema.unsupported) |> List.map(problem -> Violation.Violation("schema", "写せないフィールド ${problem}")));
        let types = apis |> List.map(api -> (api#endpoint, ContentTypes.create(Session.grant(), typeDraft(api))#id)) |> List.toMap;
        List.forEach(api -> addFields(types, api), apis);
        types

    ///
    /// 型の draft。microCMS のエンドポイント名は複数形とは限らない（"insidesales-feature"）ので、apiId から導いた singular が
    /// 一覧のクエリ名（apiId）と同じになる時は plural を `<apiId>List` にして衝突を避ける。
    ///
    def typeDraft(api: Api): ContentTypeDraft =
        let singular = Naming.deriveSingular(api#apiId);
        let singularQuery = String.toLowerCase(String.takeLeft(1, TypeName.text(singular))) + String.dropLeft(1, TypeName.text(singular));
        let plural = if (singularQuery == ApiId.text(api#apiId)) ApiId.parse("${ApiId.text(api#apiId)}List") else None;
        { apiId = api#apiId, kind = TypeKind.Collection, name = api#endpoint, singular = Some(singular), plural = plural, previewUrl = None, linkPath = linkPathOf(api), icon = None }

    ///
    /// slug を持つ API のパスの形。`/<apiId>/{slug}` にして、外向きの URL に entry id を出さない。
    ///
    /// WhyNot: slug が無い API に `/<apiId>/{id}` を置かない。id は外から引ける物ではなく、
    /// 置くとサイトが「id で引ける」前提で書かれてしまう。
    ///
    def linkPathOf(api: Api): Option[String] =
        slugSourceOf(api) |> Option.map(_source -> "/${ApiId.text(api#apiId)}/{slug}")

    ///
    /// SLUG に写す microCMS のフィールド。fieldId が "slug" のテキストだけ。
    ///
    /// WhyNot: isUnique の付いたテキストを全部 SLUG にしない。microCMS の isUnique は
    /// 社員番号のような URL に出ない値にも付く。
    ///
    def isSlugField(field: Field): Bool = match field#kind {
        case Kind.Text => field#fieldId == "slug"
        case _         => false
    }

    ///
    /// SLUG の元にするフィールド。slug より前にある最初のテキスト（普通は name / title）。
    /// slug が無いか、元にできるテキストが無ければ None（この時は SLUG に写さない）。
    ///
    def slugSourceOf(api: Api): Option[ApiId] =
        let before = api#fields |> List.takeWhile(field -> not isSlugField(field));
        if (List.length(before) == List.length(api#fields))
            None
        else
            before |> List.find(field -> match field#kind { case Kind.Text => true case _ => false })
                |> Option.map(field -> apiIdOf(field#fieldId))

    def addFields(types: Types, api: Api): Unit \ Db + CmsErr + IdGen + Tenant + Session =
        let typeId = Map.get(api#endpoint, types) |> Option.getWithDefault(TypeId.TypeId(0i64));
        List.forEach(field -> match field#kind {
            case Kind.Repeater(variants) =>
                let blocks = ContentTypes.addField(Session.grant(), typeId, draftOf(field, FieldKind.Blocks, true, None, None));
                List.forEach(variantId -> match List.find(custom -> custom#fieldId == variantId, api#customFields) {
                    case None => ()
                    case Some(custom) =>
                        let variant = ContentTypes.addField(Session.grant(), typeId, { apiId = apiIdOf(custom#fieldId), name = custom#name, kind = FieldKind.Object, many = false, required = false, unique = false, localized = false, target = None, parent = Some(blocks#id), config = FieldConfig.empty() });
                        // microCMS は custom field と同名の子（serviceValuePoint の中の serviceValuePoint）を許すが、この CMS の apiId は型の中で一意なので、子に Value を付けて逃がす
                        List.forEach(child -> discard ContentTypes.addField(Session.grant(), typeId, leafDraft(api, types, childRenamed(custom#fieldId, child), Some(variant#id))), custom#fields)
                }, variants)
            case _ => discard ContentTypes.addField(Session.grant(), typeId, leafDraft(api, types, field, None))
        }, api#fields)

    /// variant と同名の子は `<名前>Value` に改名する。値を作る時も同じ名前にする。
    def childRenamed(variantId: String, child: Field): Field =
        if (child#fieldId == variantId) { fieldId = "${child#fieldId}Value" | child } else child

    /// 子を持たないフィールドの draft。最上位の slug だけ SLUG（一意）にして、元にするフィールドを config に入れる。
    def leafDraft(api: Api, types: Types, field: Field, parent: Option[FieldId]): FieldDraft = match field#kind {
        case Kind.Text if isSlugField(field) and Option.isEmpty(parent) and Option.nonEmpty(slugSourceOf(api)) =>
            { unique = true, config = { sourceField = slugSourceOf(api) | FieldConfig.empty() } | draftOf(field, FieldKind.Slug, false, None, parent) }
        case Kind.Text              => draftOf(field, FieldKind.Text, false, None, parent)
        case Kind.TextArea          => draftOf(field, FieldKind.TextArea, false, None, parent)
        case Kind.RichEditor        => draftOf(field, FieldKind.RichText, false, None, parent)
        case Kind.Media             => draftOf(field, FieldKind.Asset, false, None, parent)
        case Kind.Boolean           => draftOf(field, FieldKind.Boolean, false, None, parent)
        case Kind.Number            => draftOf(field, FieldKind.Number, false, None, parent)
        case Kind.Date              => draftOf(field, FieldKind.Date, false, None, parent)
        case Kind.Relation(target)     => draftOf(field, FieldKind.Reference, false, Map.get(target, types), parent)
        case Kind.RelationList(target) => draftOf(field, FieldKind.Reference, true, Map.get(target, types), parent)
        case _                      => draftOf(field, FieldKind.Text, false, None, parent)
    }

    /// 子フィールドは required を付けられない（最上位だけ）ので、親があれば落とす。
    def draftOf(field: Field, kind: FieldKind, many: Bool, target: Option[TypeId], parent: Option[FieldId]): FieldDraft =
        { apiId = apiIdOf(field#fieldId), name = field#name, kind = kind, many = many, required = field#required and Option.isEmpty(parent),
          unique = false, localized = false, target = target, parent = parent, config = FieldConfig.empty() }

    /// microCMS の fieldId は lowerCamel なのでそのまま。規則外なら英数字だけにして頭を小文字に。
    def apiIdOf(fieldId: String): ApiId = match ApiId.parse(fieldId) {
        case Some(found) => found
        case None => MicrocmsSchema.apiIdOf(fieldId) |> Option.getWithDefault(ApiId.ApiId("field"))
    }

    // ---- ダミーの entry ----

    ///
    /// 各 API に count 件のダミー entry を作り、参照を張って、全部公開する。ダミーの画像を 1 つ置いて全 media に使う。
    /// 戻りは endpoint → 作った entry の id。
    ///
    pub def seedDummy(apis: List[Api], types: Types, count: Int32): Map[String, List[EntryId]] \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore + Net.Http.Http =
        let asset = placeDummyImage();
        let created = apis |> List.map(api -> {
            let typeId = Map.get(api#endpoint, types) |> Option.getWithDefault(TypeId.TypeId(0i64));
            (api#endpoint, List.range(1, count + 1) |> List.map(n -> ContentEntries.create(Session.grant(), typeId, None, valuesOf(api, asset, Map.empty(), n, false))#id))
        }) |> List.toMap;
        // 参照は全部の entry ができてから張る（相互参照・自己参照のため）
        List.forEach(api -> Map.get(api#endpoint, created) |> Option.getWithDefault(Nil) |> List.forEachWithIndex((index, id) -> {
            let entry = ContentEntries.get(Session.grant(), id);
            discard ContentEntries.update(Session.grant(), id, valuesOf(api, asset, created, index + 1, true), entry#version)
        }), apis);
        List.forEach(api -> Map.get(api#endpoint, created) |> Option.getWithDefault(Nil) |> List.forEach(id -> discard ContentEntries.publish(Session.grant(), id, "microcms-import", true)), apis);
        created

    /// フィールドの値。withReferences が false なら参照のフィールドを入れない（1 回目の作成用）。
    def valuesOf(api: Api, asset: AssetId, created: Map[String, List[EntryId]], n: Int32, withReferences: Bool): EntryData =
        api#fields
            |> List.filterMap(field -> valueOf(api, asset, created, n, withReferences, field) |> Option.map(value -> (apiIdOf(field#fieldId), value)))
            |> List.toMap

    def valueOf(api: Api, asset: AssetId, created: Map[String, List[EntryId]], n: Int32, withReferences: Bool, field: Field): Option[Json] = match field#kind {
        // slug は URL に出るので、名前（"名前 1"）ではなく apiId と番号から作る
        case Kind.Text if isSlugField(field) => Some(Json.JString("${ApiId.text(api#apiId)}-${n}"))
        case Kind.Text       => Some(Json.JString("${field#name} ${n}"))
        case Kind.TextArea   => Some(Json.JString("${field#name} ${n} の 1 行目\n2 行目"))
        case Kind.RichEditor => Some(richTextDoc(field#name, n, asset))
        case Kind.Media      => Some(Json.JString(AssetId.text(asset)))
        case Kind.Boolean    => Some(Json.JBool(Int32.remainder(n, 2) == 0))
        case Kind.Number     => Some(Json.JNumber(Int32.toBigDecimal(n)))
        case Kind.Date       => Some(Json.JString("2026-09-${String.padLeft(2, '0', "${Int32.remainder(n - 1, 28) + 1}")}T00:00:00Z"))
        case Kind.Relation(target) =>
            if (withReferences) Map.get(target, created) |> Option.flatMap(List.head) |> Option.map(id -> Json.JString(EntryId.text(id))) else None
        case Kind.RelationList(target) =>
            if (withReferences) Map.get(target, created) |> Option.map(ids -> Json.JArray(ids |> List.take(2) |> List.map(id -> Json.JString(EntryId.text(id))) |> List.toVector)) else None
        case Kind.Repeater(variants) =>
            let blocks = variants |> List.filterMap(variantId -> List.find(custom -> custom#fieldId == variantId, api#customFields)) |> List.map(custom ->
                Json.JObject(Map.insert("blockType", Json.JString(ApiId.text(apiIdOf(custom#fieldId))),
                    custom#fields |> List.map(childRenamed(custom#fieldId)) |> List.filterMap(child -> valueOf(api, asset, created, n, withReferences, child) |> Option.map(value -> (ApiId.text(apiIdOf(child#fieldId)), value))) |> List.toMap)));
            Some(Json.JArray(List.toVector(blocks)))
        case Kind.Unsupported(_) => None
    }

    ///
    /// RichText が受け付けるノードとマークを全部 1 本に並べた doc。公開側の見た目の確認用。
    ///
    /// WhyNot: 古い形（attrs.assetId を持つ image / gallery / blockquote の attrs.cite）を入れない。
    /// 読む側だけの互換で、書き出す側が作る形ではないので、ここに置くと新しく作る doc の見本にならない。
    ///
    def richTextDoc(name: String, n: Int32, asset: AssetId): Json =
        docNode(
            List#{ headingNode(2, Some("demo-top"), "${name} ${n} の全部盛り") }
                ::: marksSection()
                ::: listsSection()
                ::: quoteSection()
                ::: codeSection()
                ::: tableSection()
                ::: imageSection(asset)
                ::: mathSection()
                ::: mediaSection(asset))

    /// 段落に掛けられるマークを一通り。
    def marksSection(): List[Json] =
        List#{
            headingNode(3, None, "文字に掛ける印"),
            node("paragraph", Map.empty(), List#{
                textNode("この段落には", Nil),
                textNode("太字", markNode("bold") :: Nil),
                textNode("・", Nil),
                textNode("斜体", markNode("italic") :: Nil),
                textNode("・", Nil),
                textNode("打ち消し", markNode("strike") :: Nil),
                textNode("・", Nil),
                textNode("下線", markNode("underline") :: Nil),
                textNode("・", Nil),
                textNode("蛍光ペン", markNode("highlight") :: Nil),
                textNode("・", Nil),
                textNode("Map.get", markNode("code") :: Nil),
                textNode("を並べています。", Nil)
            }),
            node("paragraph", Map.empty(), List#{
                textNode("水は H", Nil),
                textNode("2", markNode("sub") :: Nil),
                textNode("O、面積は 10 m", Nil),
                textNode("2", markNode("sup") :: Nil),
                textNode(" です。文の中の数式は ", Nil),
                textNode("e^{i\\pi} + 1 = 0", markNode("math") :: Nil),
                textNode(" のように書けます。", Nil)
            }),
            node("paragraph", Map.empty(), List#{
                textNode("外部リンクは", Nil),
                textNode("example.com", linkMark("https://example.com/docs") :: Nil),
                textNode("、同じサイトの中は", Nil),
                textNode("トップ", linkMark("/") :: Nil),
                textNode("、ページの中は", Nil),
                textNode("この見出し", linkMark("#demo-top") :: Nil),
                textNode("、メールは", Nil),
                textNode("問い合わせ先", linkMark("mailto:info@example.com") :: Nil),
                textNode("。改行はここで入ります。", Nil),
                leafNode("hardBreak", Map.empty()),
                textNode("改行の次の行です。", Nil)
            })
        }

    /// 箇条書き・番号付き・チェックリストと、その入れ子。
    def listsSection(): List[Json] =
        List#{
            headingNode(3, None, "リスト"),
            node("bulletList", Map.empty(), List#{
                listItem(Map.empty(), List#{ paragraphOf("一つ目の項目") }),
                listItem(Map.empty(), List#{
                    paragraphOf("二つ目の項目（入れ子あり）"),
                    node("bulletList", Map.empty(), List#{
                        listItem(Map.empty(), List#{ paragraphOf("入れ子の項目") }),
                        listItem(Map.empty(), List#{
                            paragraphOf("さらに入れ子"),
                            node("orderedList", Map.empty(), List#{
                                listItem(Map.empty(), List#{ paragraphOf("番号付きの入れ子") })
                            })
                        })
                    })
                })
            }),
            node("orderedList", Map.empty(), List#{
                listItem(Map.empty(), List#{ paragraphOf("手順 1: プロジェクトを作る") }),
                listItem(Map.empty(), List#{ paragraphOf("手順 2: API スキーマを決める") }),
                listItem(Map.empty(), List#{ paragraphOf("手順 3: entry を書いて公開する") })
            }),
            node("bulletList", Map.empty(), List#{
                listItem(Map#{ "checked" => Json.JBool(true) }, List#{ paragraphOf("済んだタスク") }),
                listItem(Map#{ "checked" => Json.JBool(false) }, List#{ paragraphOf("まだのタスク") })
            })
        }

    /// 引用と出典（quoteCite）。
    def quoteSection(): List[Json] =
        List#{
            headingNode(3, None, "引用"),
            node("blockquote", Map.empty(), List#{
                paragraphOf("ヘッドレス CMS の役割は中身で、見た目はサイトが決める。"),
                node("quoteCite", Map.empty(), List#{
                    textNode("設計メモ", markNode("italic") :: Nil),
                    textNode(" / ", Nil),
                    textNode("example.com", linkMark("https://example.com/notes") :: Nil)
                })
            })
        }

    /// コードブロック（言語・ファイル名・強調行・折り返し）と Mermaid。
    def codeSection(): List[Json] =
        List#{
            headingNode(3, None, "コード"),
            node("codeBlock",
                Map#{ "language" => Json.JString("ts"), "fileName" => Json.JString("src/demo.ts"),
                      "highlightLines" => Json.JString("2,4-5"), "wrap" => Json.JBool(true) },
                List#{ textNode("export function greet(who: string) {\n  const message = \"こんにちは、\" + who;\n  console.log(message);\n  return message;\n}", Nil) }),
            node("codeBlock", Map#{ "language" => Json.JString("mermaid") },
                List#{ textNode("graph TD\n  draft[下書き] --> review[レビュー]\n  review --> published[公開]", Nil) })
        }

    ///
    /// 表。見出し行・セルの結合・寄せ・セルの中のマークを 1 つに入れる。
    ///
    def tableSection(): List[Json] =
        List#{
            headingNode(3, None, "表"),
            node("table", Map.empty(), List#{
                node("tableRow", Map.empty(), List#{
                    node("tableHeader", Map#{ "align" => Json.JString("left") }, List#{ paragraphOf("プラン") }),
                    node("tableHeader", Map#{ "align" => Json.JString("right") }, List#{ paragraphOf("entry 数") }),
                    node("tableHeader", Map#{ "align" => Json.JString("center") }, List#{ paragraphOf("備考") })
                }),
                node("tableRow", Map.empty(), List#{
                    node("tableCell", Map#{ "align" => Json.JString("left"), "rowspan" => Json.JNumber(Int32.toBigDecimal(2)) }, List#{
                        node("paragraph", Map.empty(), List#{
                            textNode("Free", markNode("bold") :: Nil),
                            textNode("（2 行分）", Nil)
                        })
                    }),
                    node("tableCell", Map#{ "align" => Json.JString("right") }, List#{ paragraphOf("100") }),
                    node("tableCell", Map#{ "align" => Json.JString("center") }, List#{
                        node("paragraph", Map.empty(), List#{
                            textNode("セルの中にも", Nil),
                            textNode("リンク", linkMark("https://example.com/pricing") :: Nil),
                            textNode("と", Nil),
                            textNode("code", markNode("code") :: Nil),
                            textNode("を置けます。", Nil)
                        })
                    })
                }),
                node("tableRow", Map.empty(), List#{
                    node("tableCell", Map#{ "align" => Json.JString("right") }, List#{ paragraphOf("300") }),
                    node("tableCell", Map#{ "align" => Json.JString("center") }, List#{
                        node("paragraph", Map.empty(), List#{ textNode("試用中", markNode("highlight") :: Nil) })
                    })
                }),
                node("tableRow", Map.empty(), List#{
                    node("tableCell", Map#{ "align" => Json.JString("left"), "colspan" => Json.JNumber(Int32.toBigDecimal(3)) }, List#{
                        node("paragraph", Map.empty(), List#{
                            textNode("3 列を結合した行。", Nil),
                            textNode("打ち消し", markNode("strike") :: Nil),
                            textNode("も効きます。", Nil)
                        })
                    })
                })
            })
        }

    /// 画像。1 枚（キャプション・出典・リンク・縮小・配置）と、並べた 2 枚。
    def imageSection(asset: AssetId): List[Json] =
        List#{
            headingNode(3, None, "画像"),
            node("image", Map.empty(), List#{
                node("imageItem",
                    Map#{ "assetId" => Json.JString(AssetId.text(asset)), "alt" => Json.JString("ダミー画像"),
                          "source" => Json.JString("社内資料"), "sourceUrl" => Json.JString("https://example.com/source"),
                          "href" => Json.JString("https://example.com/photo"), "size" => Json.JString("small"),
                          "align" => Json.JString("right") },
                    List#{
                        textNode("キャプションの中の", Nil),
                        textNode("斜体", markNode("italic") :: Nil),
                        textNode("と", Nil),
                        textNode("リンク", linkMark("https://example.com/caption") :: Nil)
                    })
            }),
            node("image", Map.empty(), List#{
                node("imageItem", Map#{ "assetId" => Json.JString(AssetId.text(asset)), "alt" => Json.JString("並べた 1 枚目") },
                    List#{ textNode("1 枚目", Nil) }),
                node("imageItem", Map#{ "assetId" => Json.JString(AssetId.text(asset)), "alt" => Json.JString("並べた 2 枚目") },
                    List#{ textNode("2 枚目", Nil) })
            })
        }

    /// 区切り線とブロックの数式。
    def mathSection(): List[Json] =
        List#{
            leafNode("horizontalRule", Map.empty()),
            headingNode(3, None, "数式"),
            leafNode("mathBlock", Map#{ "tex" => Json.JString("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}") })
        }

    /// callout / details / video / linkCard / embed と、レベル 4 の見出し。
    def mediaSection(asset: AssetId): List[Json] =
        List#{
            headingNode(3, None, "囲みと埋め込み"),
            node("callout", Map#{ "kind" => Json.JString("note") }, List#{ paragraphOf("note の囲みです。補足を入れます。") }),
            node("callout", Map#{ "kind" => Json.JString("tip") }, List#{ paragraphOf("tip の囲みです。こつを入れます。") }),
            node("callout", Map#{ "kind" => Json.JString("warning") }, List#{ paragraphOf("warning の囲みです。気を付ける事を入れます。") }),
            node("details", Map#{ "summary" => Json.JString("折りたたみの見出し") }, List#{
                paragraphOf("開いた時に出る本文です。"),
                node("bulletList", Map.empty(), List#{ listItem(Map.empty(), List#{ paragraphOf("中にリストも置けます") }) })
            }),
            headingNode(4, Some("demo-media"), "動画とカード"),
            leafNode("video", Map#{ "assetId" => Json.JString(AssetId.text(asset)),
                                    "poster" => Json.JString(AssetId.text(asset)),
                                    "caption" => Json.JString("ダミー動画") }),
            leafNode("linkCard", Map#{ "url" => Json.JString("https://example.com/blog/hello") }),
            leafNode("embed", Map#{ "url" => Json.JString("https://www.youtube.com/watch?v=dQw4w9WgXcQ") }),
            leafNode("embed", Map#{ "url" => Json.JString("https://vimeo.com/76979871") }),
            leafNode("embed", Map#{ "url" => Json.JString("https://x.com/example/status/1234567890123456789") })
        }

    // ---- doc を組み立てる部品 ----

    def docNode(content: List[Json]): Json = node("doc", Map.empty(), content)

    def node(kind: String, nodeAttrs: Map[String, Json], content: List[Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind), "attrs" => Json.JObject(nodeAttrs), "content" => Json.JArray(List.toVector(content)) })

    def leafNode(kind: String, nodeAttrs: Map[String, Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind), "attrs" => Json.JObject(nodeAttrs) })

    def textNode(value: String, marks: List[Json]): Json =
        Json.JObject(Map#{ "type" => Json.JString("text"), "text" => Json.JString(value), "marks" => Json.JArray(List.toVector(marks)) })

    def markNode(kind: String): Json =
        Json.JObject(Map#{ "type" => Json.JString(kind), "attrs" => Json.JObject(Map.empty()) })

    def linkMark(href: String): Json =
        Json.JObject(Map#{ "type" => Json.JString("link"), "attrs" => Json.JObject(Map#{ "href" => Json.JString(href) }) })

    def headingNode(level: Int32, id: Option[String], value: String): Json =
        let levelAttr = Map#{ "level" => Json.JNumber(Int32.toBigDecimal(level)) };
        let headingAttrs = id |> Option.map(found -> Map.insert("id", Json.JString(found), levelAttr)) |> Option.getWithDefault(levelAttr);
        node("heading", headingAttrs, List#{ textNode(value, Nil) })

    def paragraphOf(value: String): Json = node("paragraph", Map.empty(), List#{ textNode(value, Nil) })

    def listItem(itemAttrs: Map[String, Json], content: List[Json]): Json = node("listItem", itemAttrs, content)

    /// ダミーの画像を 1 つ置いて READY にする。中身は PNG ではなく短い文字列（器の確認なので描画はしない）。
    def placeDummyImage(): AssetId \ Db + CmsErr + IdGen + Tenant + Session + ObjectStore + Net.Http.Http =
        let body = "dummy";
        let upload = Assets.createUpload(Session.grant(), { fileName = "dummy.png", mime = "image/png", size = Int32.toInt64(String.length(body)) });
        match Net.Http.send(HttpRequest.put(upload#uploadUrl, body) |> HttpRequest.withContentType("image/png")) {
            case Ok(response) if HttpResponse.isSuccess(response) => ()
            case Ok(response) => CmsErr.invalid(Violation.Violation("asset", "ダミー画像を置けません（HTTP ${HttpResponse.status(response)}）") :: Nil)
            case Err(error)   => CmsErr.invalid(Violation.Violation("asset", "ダミー画像を置けません: ${error}") :: Nil)
        };
        Assets.confirm(Session.grant(), upload#asset#id, { width = Some(1), height = Some(1), alt = Some("ダミー画像") })#id

}
