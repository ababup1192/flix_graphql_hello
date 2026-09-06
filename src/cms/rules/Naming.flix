///
/// content type とフィールドの名前の規則。全部純粋。
/// 識別子の形は ApiId / TypeName の parse が守るので、ここで見るのは予約名・衝突・kind と config の組み合わせ。
/// コンテンツ API の GraphQL スキーマはこの名前から生えるので、生える型（<Singular>Where など）や予約名と衝突しない事を守る。
///
mod Naming {

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
    /// apiId から singular を導く。"blogs" → "Blog"、"categories" → "Category"、"news" → "News"（s 1 つでは落とさない語もあるので、合わなければ入力で上書きする）。
    ///
    /// WhyNot: TypeName.parse を通さず直に包むのは、lowerCamel の先頭を大文字にした物は必ず UpperCamel になるため。
    ///
    pub def deriveSingular(apiId: ApiId): TypeName =
        let text = ApiId.text(apiId);
        let keepsS = List.exists(suffix -> String.endsWith(suffix = suffix, text), "ss" :: "us" :: "is" :: "ws" :: Nil);
        let stem =
            if (String.endsWith(suffix = "ies", text)) String.dropRight(3, text) + "y"
            else if (keepsS) text
            else if (String.endsWith(suffix = "s", text)) String.dropRight(1, text)
            else text;
        TypeName.TypeName(String.toUpperCase(String.takeLeft(1, stem)) + String.dropLeft(1, stem))

    ///
    /// apiId から plural を導く。一覧クエリ名は apiId そのまま。
    ///
    pub def derivePlural(apiId: ApiId): ApiId = apiId

    ///
    /// 型の名前の組。衝突の検査に使う。
    ///
    /// - apiId: 識別子
    /// - singular: コンテンツ API の型名
    /// - plural: コンテンツ API の一覧クエリ名
    ///
    pub type alias TypeNames = { apiId = ApiId, singular = TypeName, plural = ApiId }

    ///
    /// ContentType から名前の組を取り出す。
    ///
    pub def namesOf(contentType: ContentType): TypeNames =
        { apiId = contentType#apiId, singular = contentType#singular, plural = contentType#plural }

    ///
    /// 型の名前を検査する。others は自分以外の既存の型。
    /// apiId が既にあればそれだけ返す（singular / plural は apiId から導くので、続けて見ても同じ原因の誤りが並ぶだけ）。
    ///
    pub def validateType(others: List[TypeNames], candidate: TypeNames): List[Violation] =
        if (List.exists(other -> other#apiId == candidate#apiId, others))
            Violation.Violation("apiId", "'${candidate#apiId}' は既にあります") :: Nil
        else
            validateSingular(others, candidate) ::: validatePlural(others, candidate)

    def validateSingular(others: List[TypeNames], candidate: TypeNames): List[Violation] =
        let singular = TypeName.text(candidate#singular);
        if (List.memberOf(singular, reservedTypeNames())) Violation.Violation("singular", "'${singular}' はコンテンツ API が使う型名なので使えません") :: Nil
        else if (List.exists(suffix -> String.endsWith(suffix = suffix, singular), reservedSuffixes())) Violation.Violation("singular", "'${singular}' は ${List.join(" / ", reservedSuffixes())} で終わる名前なので使えません（他の型から生える型と衝突します）") :: Nil
        else if (List.exists(other -> other#singular == candidate#singular, others)) Violation.Violation("singular", "'${singular}' は既に他の型が使っています") :: Nil
        else Nil

    def validatePlural(others: List[TypeNames], candidate: TypeNames): List[Violation] =
        let plural = ApiId.text(candidate#plural);
        if (String.toLowerCase(plural) == String.toLowerCase(TypeName.text(candidate#singular))) Violation.Violation("plural", "singular と同じ名前は使えません（コンテンツ API の 1 件と一覧のクエリ名が衝突します）") :: Nil
        else if (List.exists(other -> other#plural == candidate#plural or String.toLowerCase(TypeName.text(other#singular)) == plural, others)) Violation.Violation("plural", "'${plural}' は既に他の型が使っています") :: Nil
        else Nil

    ///
    /// フィールドの apiId を検査する。siblings は同じ型の既存のフィールド（自分を除く）の apiId。
    ///
    pub def validateFieldApiId(siblings: List[ApiId], apiId: ApiId): List[Violation] =
        if (List.memberOf(ApiId.text(apiId), reservedFieldApiIds())) Violation.Violation("apiId", "'${apiId}' は全 entry が持つ名前なので使えません") :: Nil
        else if (List.memberOf(apiId, siblings)) Violation.Violation("apiId", "'${apiId}' は既にこの型にあります") :: Nil
        else Nil

    ///
    /// フィールドの性質の組み合わせ。unique は配列に付けられない（値ごとの一意を DB で守れない）。
    ///
    pub def validateFlags(many: Bool, unique: Bool): List[Violation] =
        if (many and unique) Violation.Violation("unique", "配列のフィールドには付けられません") :: Nil else Nil

    ///
    /// kind と config の組み合わせを検査する。siblings は同じ型の既存のフィールドの apiId（slug の sourceField の検査用）。
    ///
    pub def validateConfig(siblings: List[ApiId], kind: FieldKind, config: FieldConfig): List[Violation] =
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
                case None                                                => Violation.Violation("config.sourceField", "SLUG には元にするフィールドの apiId が要ります") :: Nil
                case Some(source) if not List.memberOf(source, siblings) => Violation.Violation("config.sourceField", "'${source}' はこの型にありません") :: Nil
                case Some(_)                                             => Nil
            }
            case FieldKind.Number => Nil
            case _ =>
                let numberOnly = Option.isEmpty(config#min) and Option.isEmpty(config#max) and Option.isEmpty(config#integer);
                if (numberOnly) Nil else Violation.Violation("config", "min / max / integer は NUMBER だけの設定です") :: Nil
        };
        lengthChecks ::: rangeChecks ::: kindChecks

}
