///
/// cms のテストで共有する部品。識別子と入力レコードを短く作る。
///
mod CmsTestKit {

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
        { apiId = apiId(api), kind = TypeKind.Collection, name = name, singular = None, plural = None, previewUrl = None }

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
    /// content type の定義。singular / plural は apiId から導く。
    ///
    pub def contentType(id: Int64, api: String, kind: TypeKind, name: String, fields: List[FieldDef]): ContentType =
        let at = Timestamp.at("2026-09-01T00:00:00Z");
        { id = TypeId.TypeId(id), apiId = apiId(api), kind = kind, name = name,
          singular = Naming.deriveSingular(apiId(api)), plural = Naming.derivePlural(apiId(api)), previewUrl = None,
          fields = fields, createdAt = at, updatedAt = at }

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
    /// 誤りのパスだけ取り出す（メッセージの文言はテストしない）。
    ///
    pub def violationPaths(violations: List[Violation]): List[String] =
        violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })

    ///
    /// 業務エラーの結果から誤りのパスだけ。invalid でなければ空。
    ///
    pub def failurePaths(result: Result[CmsErr.CmsFailure, a]): List[String] = match result {
        case Err(CmsErr.CmsFailure.Invalid(violations)) => violationPaths(violations)
        case _                                          => Nil
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
        CmsErr.runWithResult(thunk) |> Result.map(pick) |> Result.mapErr(CmsErr.toMessage)

}
