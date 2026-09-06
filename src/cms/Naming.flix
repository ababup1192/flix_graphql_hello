///
/// content type とフィールドの名前の規則。全部純粋。
/// コンテンツ API の GraphQL スキーマはこの名前から生えるので、GraphQL の識別子として成り立つ事と、
/// 生える型（<Singular>Where など）や予約名と衝突しない事をここで守る。
///
mod Naming {

    use GeneratedAdmin.FieldKind

    ///
    /// lowerCamel の識別子か（[a-z][A-Za-z0-9]*）。apiId と plural に使う。
    ///
    pub def isLowerCamel(text: String): Bool = String.isMatch(regex = "^[a-z][A-Za-z0-9]*$", text)

    ///
    /// UpperCamel の識別子か（[A-Z][A-Za-z0-9]*）。singular に使う。
    ///
    pub def isUpperCamel(text: String): Bool = String.isMatch(regex = "^[A-Z][A-Za-z0-9]*$", text)

    ///
    /// Entry interface が持つので、フィールドの apiId に使えない名前。
    ///
    pub def reservedFieldApiIds(): List[String] =
        "id" :: "stage" :: "publishedAt" :: "updatedAt" :: "createdAt" :: "version" :: Nil

    ///
    /// コンテンツ API が自分で持つので、singular に使えない型名。
    ///
    pub def reservedTypeNames(): List[String] =
        "Query" :: "Mutation" :: "Subscription" :: "Entry" :: "Asset" :: "Stage" :: "RichText" :: "Heading" :: "PageInfo" :: "DateTime" :: "JSON" :: "Int" :: "Float" :: "String" :: "Boolean" :: "ID" :: Nil

    ///
    /// 型ごとに生える型の接尾辞。singular がこれで終わると、別の型から生えた名前と衝突しうる。
    ///
    pub def reservedSuffixes(): List[String] = "Where" :: "OrderBy" :: "Connection" :: "Edge" :: Nil

    ///
    /// 先頭を大文字にする。
    ///
    pub def toUpperCamel(text: String): String =
        String.toUpperCase(String.takeLeft(1, text)) + String.dropLeft(1, text)

    ///
    /// apiId から singular を導く。"blogs" → "Blog"、"categories" → "Category"、"news" → "News"（s 1 つでは落とさない語もあるので、合わなければ入力で上書きする）。
    ///
    pub def deriveSingular(apiId: String): String =
        let keepsS = List.exists(suffix -> String.endsWith(suffix = suffix, apiId), "ss" :: "us" :: "is" :: "ws" :: Nil);
        let stem =
            if (String.endsWith(suffix = "ies", apiId)) String.dropRight(3, apiId) + "y"
            else if (keepsS) apiId
            else if (String.endsWith(suffix = "s", apiId)) String.dropRight(1, apiId)
            else apiId;
        toUpperCamel(stem)

    ///
    /// apiId から plural を導く。一覧クエリ名は apiId そのまま。
    ///
    pub def derivePlural(apiId: String): String = apiId

    ///
    /// 型の名前の組。衝突の検査に使う。
    ///
    /// - apiId: 識別子
    /// - singular: コンテンツ API の型名
    /// - plural: コンテンツ API の一覧クエリ名
    ///
    pub type alias TypeNames = { apiId = String, singular = String, plural = String }

    ///
    /// 型の名前を検査する。others は自分以外の既存の型。
    /// apiId に誤りがあればそれだけ返す（singular / plural は apiId から導くので、続けて見ても同じ原因の誤りが並ぶだけ）。
    ///
    pub def validateType(others: List[TypeNames], candidate: TypeNames): List[Violation] =
        match validateApiId(others, candidate) {
            case Nil        => validateSingularAndPlural(others, candidate)
            case violations => violations
        }

    def validateApiId(others: List[TypeNames], candidate: TypeNames): List[Violation] =
        if (not isLowerCamel(candidate#apiId)) Violation.Violation("apiId", "lowerCamel の識別子（[a-z][A-Za-z0-9]*）にしてください") :: Nil
        else if (List.exists(other -> other#apiId == candidate#apiId, others)) Violation.Violation("apiId", "'${candidate#apiId}' は既にあります") :: Nil
        else Nil

    def validateSingularAndPlural(others: List[TypeNames], candidate: TypeNames): List[Violation] =
        let singularChecks =
            if (not isUpperCamel(candidate#singular)) Violation.Violation("singular", "UpperCamel の識別子（[A-Z][A-Za-z0-9]*）にしてください") :: Nil
            else if (List.memberOf(candidate#singular, reservedTypeNames())) Violation.Violation("singular", "'${candidate#singular}' はコンテンツ API が使う型名なので使えません") :: Nil
            else if (List.exists(suffix -> String.endsWith(suffix = suffix, candidate#singular), reservedSuffixes())) Violation.Violation("singular", "'${candidate#singular}' は ${List.join(" / ", reservedSuffixes())} で終わる名前なので使えません（他の型から生える型と衝突します）") :: Nil
            else if (List.exists(other -> other#singular == candidate#singular, others)) Violation.Violation("singular", "'${candidate#singular}' は既に他の型が使っています") :: Nil
            else Nil;
        let pluralChecks =
            if (not isLowerCamel(candidate#plural)) Violation.Violation("plural", "lowerCamel の識別子（[a-z][A-Za-z0-9]*）にしてください") :: Nil
            else if (String.toLowerCase(candidate#plural) == String.toLowerCase(candidate#singular)) Violation.Violation("plural", "singular と同じ名前は使えません（コンテンツ API の 1 件と一覧のクエリ名が衝突します）") :: Nil
            else if (List.exists(other -> other#plural == candidate#plural or String.toLowerCase(other#singular) == candidate#plural, others)) Violation.Violation("plural", "'${candidate#plural}' は既に他の型が使っています") :: Nil
            else Nil;
        singularChecks ::: pluralChecks

    ///
    /// フィールドの apiId を検査する。siblings は同じ型の既存のフィールド（自分を除く）の apiId。
    ///
    pub def validateFieldApiId(siblings: List[String], apiId: String): List[Violation] =
        if (not isLowerCamel(apiId)) Violation.Violation("apiId", "lowerCamel の識別子（[a-z][A-Za-z0-9]*）にしてください") :: Nil
        else if (List.memberOf(apiId, reservedFieldApiIds())) Violation.Violation("apiId", "'${apiId}' は全 entry が持つ名前なので使えません") :: Nil
        else if (List.memberOf(apiId, siblings)) Violation.Violation("apiId", "'${apiId}' は既にこの型にあります") :: Nil
        else Nil

    ///
    /// kind と config の組み合わせを検査する。siblings は同じ型の既存のフィールドの apiId（slug の sourceField の検査用）。
    ///
    pub def validateConfig(siblings: List[String], kind: FieldKind, config: FieldConfig): List[Violation] =
        let lengthChecks = match config#maxLength {
            case Some(n) if n <= 0 => Violation.Violation("config.maxLength", "1 以上にしてください") :: Nil
            case _                 => Nil
        };
        let rangeChecks = match (config#min, config#max) {
            case (Some(low), Some(high)) if low > high => Violation.Violation("config.max", "min 以下にはできません") :: Nil
            case _                                     => Nil
        };
        let kindChecks = match kind {
            case FieldKind.Slug => match config#sourceField {
                case None                                          => Violation.Violation("config.sourceField", "SLUG には元にするフィールドの apiId が要ります") :: Nil
                case Some(source) if not List.memberOf(source, siblings) => Violation.Violation("config.sourceField", "'${source}' はこの型にありません") :: Nil
                case Some(_)                                       => Nil
            }
            case FieldKind.Number => Nil
            case _ =>
                let numberOnly = Option.isEmpty(config#min) and Option.isEmpty(config#max) and Option.isEmpty(config#integer);
                if (numberOnly) Nil else Violation.Violation("config", "min / max / integer は NUMBER だけの設定です") :: Nil
        };
        lengthChecks ::: rangeChecks ::: kindChecks

}
