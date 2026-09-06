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
        { apiId = apiId(api), name = api, kind = kind, many = false, required = false, unique = false, localized = false, target = None, config = config }

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
    /// 誤りのパスだけ取り出す（メッセージの文言はテストしない）。
    ///
    pub def violationPaths(violations: List[Violation]): List[String] =
        violations |> List.map(violation -> { let Violation.Violation(path, _) = violation; path })

}
