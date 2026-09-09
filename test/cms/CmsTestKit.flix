///
/// cms のテストで共有する部品。識別子と入力レコードを短く作る。
///
mod CmsTestKit {

    ///
    /// 業務エラー（CmsErr）を Result に落とす。テストは自分で境界を作るのが仕事なので、本番の境界（DbRunner の private）と同じ handler をここに持つ。
    ///
    pub def runWithResult(thunk: Unit -> a \ ef): Result[CmsErr.CmsFailure, a] \ ef - CmsErr =
        run {
            Ok(thunk())
        } with handler CmsErr {
            def notFound(entity, id, _resume) = Err(CmsErr.CmsFailure.NotFound(entity, id))
            def invalid(violations, _resume) = Err(CmsErr.CmsFailure.Invalid(violations))
            def conflict(entity, id, expectedVersion, currentVersion, _resume) = Err(CmsErr.CmsFailure.Conflict(entity, id, expectedVersion, currentVersion))
            def forbidden(permission, _resume) = Err(CmsErr.CmsFailure.Forbidden(permission))
            def requiresLogin(requirement, _resume) = Err(CmsErr.CmsFailure.RequiresLogin(requirement))
        }

    ///
    /// 規則に合う綴りだけ渡す。合わなければテストの誤りなので止める。
    ///
    pub def apiId(text: String): ApiId = match ApiId.parse(text) {
        case Some(found) => found
        case None        => bug!("'${text}' は ApiId の規則に合わない（テストの誤り）")
    }

    ///
    /// 規則に合う綴りだけ渡す。
    ///
    pub def typeName(text: String): TypeName = match TypeName.parse(text) {
        case Some(found) => found
        case None        => bug!("'${text}' は TypeName の規則に合わない（テストの誤り）")
    }

    ///
    /// 型の名前の組。
    ///
    pub def names(api: String, singular: String, plural: String): Naming.TypeNames =
        { apiId = apiId(api), singular = typeName(singular), plural = apiId(plural) }

    ///
    /// collection の型の入力。singular / plural は導出に任せる。
    ///
    pub def typeDraft(api: String, name: String): ContentTypeDraft =
        { apiId = apiId(api), kind = TypeKind.Collection, name = name, singular = None, plural = None, previewUrl = None, icon = None }

    ///
    /// フィールドの入力。many / required / unique / localized は全部 false。
    ///
    pub def fieldDraft(api: String, kind: FieldKind, config: FieldConfig): FieldDraft =
        { apiId = apiId(api), name = api, kind = kind, many = false, required = false, unique = false, localized = false, target = None, parent = None, config = config }

    ///
    /// フィールドの定義。id は 0、性質は全部 false、config は空。変えたい所だけ `{ kind = ... | CmsTestKit.fieldDef(...) }` で上書きする。
    ///
    pub def fieldDef(api: String, kind: FieldKind): FieldDef =
        { id = FieldId.FieldId(0i64), typeId = TypeId.TypeId(1i64), apiId = apiId(api), name = api, kind = kind,
          many = false, required = false, unique = false, localized = false,
          target = None, parent = None, children = Children.none(), config = FieldConfig.empty(), position = 0 }

    ///
    /// content type の定義。singular / plural は apiId から導く。fields の typeId はこの型の id に合わせる。
    ///
    pub def contentType(id: Int64, api: String, kind: TypeKind, name: String, fields: List[FieldDef]): ContentType =
        let at = Timestamp.at("2026-09-01T00:00:00Z");
        { id = TypeId.TypeId(id), apiId = apiId(api), kind = kind, name = name,
          singular = Naming.deriveSingular(apiId(api)), plural = Naming.derivePlural(apiId(api)), previewUrl = None, icon = Naming.deriveIcon(kind),
          fields = fields |> List.map(field -> { typeId = TypeId.TypeId(id) | field }), createdAt = at, updatedAt = at }

    ///
    /// entry の中身。(apiId, 値) の並びから。
    ///
    pub def entryData(pairs: List[(String, Util.Json.Json)]): EntryData =
        pairs |> List.map(match (key, value) -> (apiId(key), value)) |> List.toMap

    ///
    /// 整数の JSON 値。
    ///
    pub def intJson(n: Int32): Util.Json.Json = Util.Json.Json.JNumber(Int32.toBigDecimal(n))

    ///
    /// 小数の JSON 値。表せなければ null。
    ///
    pub def floatJson(x: Float64): Util.Json.Json =
        Float64.tryToBigDecimal(x) |> Option.map(Util.Json.Json.JNumber) |> Option.getWithDefault(Util.Json.Json.JNull)

    ///
    /// 規則に合う綴りだけ渡す。合わなければテストの誤りなので止める。
    ///
    /// WhyNot: filterMap で黙って落とさないのは、IdGen に渡す並びが 1 つずれると以降の id が全部ずれ、原因の分からない失敗になるため。
    ///
    pub def entryId(text: String): EntryId = match EntryId.parse(text) {
        case Some(found) => found
        case None        => bug!("'${text}' は EntryId の規則に合わない（テストの誤り）")
    }

    ///
    /// entry の id の並び。
    ///
    pub def entryIds(texts: List[String]): List[EntryId] = List.map(entryId, texts)

    ///
    /// 決めた id を順に振る。
    ///
    pub def withIds(texts: List[String], body: Unit -> a \ ef): a \ ef - IdGen =
        IdGen.runWithFixed(entryIds(texts), body)

    ///
    /// System として、決めた id 無し（連番の public_id / ULID だけ）で走らせる。DB 無しのユースケースのテスト用。
    ///
    pub def asSystem(body: Unit -> a \ ef): a \ ef - {Session, IdGen} =
        Session.runWith(Actor.System, () -> IdGen.runWithFixed(Nil, body))

    ///
    /// テスト用の pepper。API キー・PAT・プレビュートークンの hash と署名に使う。
    ///
    pub def pepper(): SecretHash.Pepper = { pepperId = "test", secret = "test-pepper" }

    ///
    /// 誤りのパスだけ取り出す（メッセージの文言はテストしない）。
    ///
    pub def violationPaths(violations: List[Violation]): List[String] =
        violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })

    ///
    /// 業務エラーの結果から誤りのパスだけ。invalid 以外（成功・notFound・conflict）はテストの誤りなので落とす。
    ///
    pub def failurePaths(result: Result[CmsErr.CmsFailure, a]): List[String] = match result {
        case Err(CmsErr.CmsFailure.Invalid(violations)) => violationPaths(violations)
        case Err(other)                                 => bug!("invalid ではありません: ${other}")
        case Ok(_)                                      => bug!("invalid のはずが成功しました")
    }

    ///
    /// 業務エラーの文言だけ見る（成功時の値は捨てる）。
    ///
    pub def failureMessage(thunk: Unit -> a \ ef): Result[String, Unit] \ ef - CmsErr =
        messageOr(_ -> (), thunk)

    ///
    /// 業務エラーを文言にし、成功側は pick で見る。
    ///
    pub def messageOr(pick: a -> b, thunk: Unit -> a \ ef): Result[String, b] \ ef - CmsErr =
        CmsTestKit.runWithResult(thunk) |> Result.map(pick) |> Result.mapErr(CmsErr.toMessage)

    ///
    /// GraphQL の Value を比べる。違えば、両方を整形した JSON の行差分（`- 期待` / `+ 実際`）だけを文面にする。
    ///
    /// WhyNot: assertEq に任せないのは、応答の木が 1 行の ToString で出ると、どこが違うのか読めないため。
    ///
    pub def assertSameValue(expected: Value, actual: Value): Unit \ Assert =
        Assert.assertEqWithMsg(expected = expected, actual, "Value が違います:\n" + valueDiff(expected, actual))

    /// 整形した JSON の行差分のうち、違う行だけを改行で繋ぐ。
    def valueDiff(expected: Value, actual: Value): String =
        EntryDiff.diffLines(prettyJson(expected), prettyJson(actual))
            |> List.filterMap(line -> match line {
                case DiffLine.Same(_)    => None
                case DiffLine.Del(text)  => Some("- ${text}")
                case DiffLine.Add(text)  => Some("+ ${text}")
            })
            |> List.join("\n")

    def prettyJson(value: Value): String = Util.Json.toPrettyString(2, JsonValue.toJson(value))

    // ---- richText の doc の組み立て ----

    ///
    /// GraphQL の引数に書く、平文の段落 1 つの doc のリテラル。
    ///
    pub def docOf(text: String): String =
        "{ type: \"doc\", content: [{ type: \"paragraph\", content: [{ type: \"text\", text: \"${text}\" }] }] }"

    ///
    /// 子を持つノード。attrs は空なら付けない。content は空でも付ける（doc と空の段落の形）。
    ///
    pub def richNode(kind: String, attrs: List[(String, Util.Json.Json)], content: List[Util.Json.Json]): Util.Json.Json =
        Util.Json.Json.JObject(
            Map#{ "type" => Util.Json.Json.JString(kind), "content" => Util.Json.Json.JArray(List.toVector(content)) }
                |> withRichAttrs(attrs))

    ///
    /// 子を持たないノード（image / embed / horizontalRule / hardBreak）。attrs は空なら付けない。
    ///
    pub def richLeaf(kind: String, attrs: List[(String, Util.Json.Json)]): Util.Json.Json =
        Util.Json.Json.JObject(Map#{ "type" => Util.Json.Json.JString(kind) } |> withRichAttrs(attrs))

    ///
    /// text ノード。marks は空なら付けない。
    ///
    pub def richText(marks: List[Util.Json.Json], text: String): Util.Json.Json =
        Util.Json.Json.JObject(
            Map#{ "type" => Util.Json.Json.JString("text"), "text" => Util.Json.Json.JString(text) }
                |> fields -> if (List.isEmpty(marks)) fields else Map.insert("marks", Util.Json.Json.JArray(List.toVector(marks)), fields))

    ///
    /// マーク。attrs は空なら付けない（link は href か entryId を持つ）。
    ///
    pub def richMark(kind: String, attrs: List[(String, Util.Json.Json)]): Util.Json.Json =
        Util.Json.Json.JObject(Map#{ "type" => Util.Json.Json.JString(kind) } |> withRichAttrs(attrs))

    def withRichAttrs(attrs: List[(String, Util.Json.Json)], fields: Map[String, Util.Json.Json]): Map[String, Util.Json.Json] =
        if (List.isEmpty(attrs)) fields else Map.insert("attrs", Util.Json.Json.JObject(List.toMap(attrs)), fields)

}
