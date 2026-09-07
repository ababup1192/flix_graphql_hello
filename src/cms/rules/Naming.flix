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
        "id" :: "stage" :: "publishedAt" :: "updatedAt" :: "createdAt" :: "version" :: EntryValue.blockTypeKey() :: Nil

    ///
    /// コンテンツ API が自分で持つので、singular に使えない型名。
    ///
    pub def reservedTypeNames(): List[String] =
        "Query" :: "Mutation" :: "Subscription" :: "Entry" :: "Asset" :: "Stage" :: "RichText" :: "Heading" :: "PageInfo" :: "DateTime" :: "JSON" :: "Int" :: "Float" :: "String" :: "Boolean" :: "ID" :: Nil

    ///
    /// 型ごとに生える型の接尾辞。singular がこれで終わると、別の型から生えた名前と衝突しうる。
    ///
    pub def reservedSuffixes(): List[String] = "Where" :: "WhereLeaf" :: "OrderBy" :: "Connection" :: Nil

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
        TypeName.TypeName(upperFirst(stem))

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
    /// 入れ子・union・enum の型名。`<prefix><Field>`（Blog + related → BlogRelated）。コンテンツ API はこの規則で生やす。
    ///
    pub def nestedTypeName(prefix: String, apiId: ApiId): String = prefix + upperFirst(ApiId.text(apiId))

    ///
    /// 型がコンテンツ API に生やす型名の全部。singular と接尾辞付き、フィールドから生える入れ子・union・enum の名前。
    /// 型を作る・フィールドを足す時に、他の型（と自分）の物と重ねない事を守る（重なると graphql-java がスキーマを組めない）。
    ///
    pub def schemaTypeNames(singular: TypeName, fields: List[FieldDef]): List[String] =
        let root = TypeName.text(singular);
        root :: List.map(suffix -> root + suffix, reservedSuffixes()) ::: fieldTypeNames(root, fields)

    ///
    /// フィールド（木）から生える型名。Object と Blocks は入れ子の分も、Select は enum。
    ///
    pub def fieldTypeNames(prefix: String, fields: List[FieldDef]): List[String] =
        fields |> List.flatMap(field -> {
            let name = nestedTypeName(prefix, field#apiId);
            match field#kind {
                case FieldKind.Object => name :: fieldTypeNames(name, Children.toList(field#children))
                case FieldKind.Blocks => name :: fieldTypeNames(name, Children.toList(field#children))
                case FieldKind.Select => name :: Nil
                case _                => Nil
            }
        })

    ///
    /// 型（singular とそのフィールド）が生やす型名が、他の型の生やす型名と重ならない事。taken は他の型の schemaTypeNames。
    /// singular を変える時は、既にあるフィールドから生える名前も新しい singular で生え直すので、fields も渡す。
    ///
    pub def validateSchemaTypeNames(taken: List[String], singular: TypeName, fields: List[FieldDef]): List[Violation] =
        schemaTypeNames(singular, fields)
            |> List.filter(name -> List.memberOf(name, taken))
            |> List.map(name -> Violation.Violation("singular", "'${name}' は他の型がコンテンツ API に生やす型名と重なります"))

    ///
    /// フィールドが生やす型名が既にある物と重ならない事。taken は全型（自分を含む）の schemaTypeNames。
    ///
    pub def validateFieldTypeNames(taken: List[String], prefix: String, field: FieldDef): List[Violation] =
        fieldTypeNames(prefix, field :: Nil)
            |> List.filter(name -> List.memberOf(name, taken))
            |> List.map(name -> Violation.Violation("apiId", "'${name}' はコンテンツ API に既にある型名と重なります"))

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
        let queryName = lowerFirst(singular);
        if (List.memberOf(singular, reservedTypeNames())) Violation.Violation("singular", "'${singular}' はコンテンツ API が使う型名なので使えません") :: Nil
        else if (List.exists(suffix -> String.endsWith(suffix = suffix, singular), reservedSuffixes())) Violation.Violation("singular", "'${singular}' は ${List.join(" / ", reservedSuffixes())} で終わる名前なので使えません（他の型から生える型と衝突します）") :: Nil
        else if (List.exists(other -> other#singular == candidate#singular, others)) Violation.Violation("singular", "'${singular}' は既に他の型が使っています") :: Nil
        else if (List.exists(other -> ApiId.text(other#plural) == queryName, others)) Violation.Violation("singular", "'${singular}' の 1 件のクエリ名（${queryName}）が他の型の一覧のクエリ名と衝突します") :: Nil
        else Nil

    ///
    /// 先頭を小文字に。singular から 1 件のクエリ名を作る（Blog → blog）。コンテンツ API のクエリ名はこの規則で生える。
    ///
    pub def lowerFirst(text: String): String =
        String.toLowerCase(String.takeLeft(1, text)) + String.dropLeft(1, text)

    ///
    /// 先頭を大文字に。apiId から型名を作る（blog → Blog）。コンテンツ API の入れ子の型名もこの規則で生える。
    ///
    pub def upperFirst(text: String): String =
        String.toUpperCase(String.takeLeft(1, text)) + String.dropLeft(1, text)

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
    /// フィールドの性質の組み合わせ。unique は配列・OBJECT・BLOCKS・ASSET・RICH_TEXT に付けられない（値ごとの一意を DB で守れない）。
    /// BLOCKS は常に配列、RICH_TEXT は配列にできない。
    ///
    pub def validateFlags(field: { kind = FieldKind, many = Bool, unique = Bool | r }): List[Violation] =
        let many = field#many;
        let unique = field#unique;
        let uniqueChecks = if (many and unique) Violation.Violation("unique", "配列のフィールドには付けられません") :: Nil else Nil;
        let structureChecks = match field#kind {
            case FieldKind.Blocks if not many => Violation.Violation("many", "BLOCKS は常に配列です（many: true）") :: Nil
            case FieldKind.Object if unique   => Violation.Violation("unique", "OBJECT には付けられません") :: Nil
            case FieldKind.Blocks if unique   => Violation.Violation("unique", "BLOCKS には付けられません") :: Nil
            case FieldKind.Asset if unique    => Violation.Violation("unique", "ASSET には付けられません") :: Nil
            case FieldKind.RichText if many   => Violation.Violation("many", "RICH_TEXT は配列にできません") :: Nil
            case FieldKind.RichText if unique => Violation.Violation("unique", "RICH_TEXT には付けられません") :: Nil
            case _                            => Nil
        };
        uniqueChecks ::: structureChecks

    ///
    /// 参照先の有無。Reference には要り、他には付けられない。参照先の型が存在するかはユースケースが見る。
    ///
    pub def validateTarget(kind: FieldKind, target: Option[TypeId]): List[Violation] = match (kind, target) {
        case (FieldKind.Reference, None) => Violation.Violation("targetTypeId", "REFERENCE には参照先の型が要ります") :: Nil
        case (FieldKind.Reference, _)    => Nil
        case (_, Some(_))                => Violation.Violation("targetTypeId", "REFERENCE 以外には付けられません") :: Nil
        case (_, None)                   => Nil
    }

    ///
    /// 親子の組み合わせ。Blocks の子は Object（variant）だけで、variant は配列にできない。Object の子に Blocks は置けない（入れ子の union は複雑になる）。
    /// 親が無ければ何でもよい。
    ///
    pub def validateParent(parentKind: Option[FieldKind], childKind: FieldKind, childMany: Bool): List[Violation] = match (parentKind, childKind) {
        case (None, _)                              => Nil
        case (Some(FieldKind.Blocks), FieldKind.Object) => if (childMany) Violation.Violation("many", "BLOCKS の variant は配列にできません") :: Nil else Nil
        case (Some(FieldKind.Blocks), _)            => Violation.Violation("parentFieldId", "BLOCKS の子は OBJECT（variant）だけです") :: Nil
        case (Some(FieldKind.Object), FieldKind.Blocks) => Violation.Violation("parentFieldId", "OBJECT の中に BLOCKS は置けません") :: Nil
        case (Some(FieldKind.Object), _)            => Nil
        case (Some(_), _)                           => Violation.Violation("parentFieldId", "子を持てるのは OBJECT と BLOCKS だけです") :: Nil
    }

    ///
    /// 子フィールドの性質。required と unique は最上位だけ（公開の検査と一意の写しは最上位の値しか見ない）。
    ///
    /// WhyNot: 子でも黙って受けて無視しないのは、付けた人が効いていると思い込むため。効かせるなら検査と一意の写しを入れ子に広げてから外す。
    ///
    pub def validateChildFlags(field: { hasParent = Bool, required = Bool, unique = Bool }): List[Violation] =
        if (not field#hasParent) Nil
        else (if (field#required) Violation.Violation("required", "子フィールドには付けられません（公開の検査は最上位だけ）") :: Nil else Nil)
             ::: (if (field#unique) Violation.Violation("unique", "子フィールドには付けられません（一意は最上位だけ）") :: Nil else Nil)

    ///
    /// Select の選択肢の綴り。コンテンツ API の enum の値になるので UPPER_SNAKE（[A-Z][A-Z0-9_]*）。
    ///
    pub def isEnumValue(text: String): Bool = String.isMatch(regex = "^[A-Z][A-Z0-9_]*$", text)

    ///
    /// kind と config の組み合わせを検査する。siblings は同じ型の既存のフィールドの apiId（slug の sourceField の検査用）。
    ///
    pub def validateConfig(siblings: List[ApiId], kind: FieldKind, config: FieldConfig): List[Violation] =
        List.flatten(checkLength(config) :: checkRange(config) :: checkOptions(kind, config) :: checkKindConfig(siblings, kind, config) :: Nil)

    def checkLength(config: FieldConfig): List[Violation] = match config#maxLength {
        case Some(n) if n <= 0 => Violation.Violation("config.maxLength", "1 以上にしてください") :: Nil
        case _                 => Nil
    }

    def checkRange(config: FieldConfig): List[Violation] = match (config#min, config#max) {
        case (Some(low), Some(high)) if low > high => Violation.Violation("config.max", "min 以下にはできません") :: Nil
        case _                                     => Nil
    }

    ///
    /// SELECT の選択肢。SELECT には 1 つ以上・UPPER_SNAKE・重複無し。他の kind には置けない。
    ///
    def checkOptions(kind: FieldKind, config: FieldConfig): List[Violation] = match kind {
        case FieldKind.Select =>
            if (List.isEmpty(config#options)) Violation.Violation("config.options", "SELECT には選択肢が 1 つ以上要ります") :: Nil
            else if (List.exists(option -> not isEnumValue(option), config#options)) Violation.Violation("config.options", "選択肢は UPPER_SNAKE（[A-Z][A-Z0-9_]*）にしてください") :: Nil
            else if (List.length(List.distinct(config#options)) != List.length(config#options)) Violation.Violation("config.options", "選択肢が重複しています") :: Nil
            else Nil
        case _ => if (List.isEmpty(config#options)) Nil else Violation.Violation("config.options", "options は SELECT だけの設定です") :: Nil
    }

    ///
    /// kind ごとの設定。SLUG には同じ型にある sourceField が要り、min / max / integer は NUMBER だけ。
    ///
    def checkKindConfig(siblings: List[ApiId], kind: FieldKind, config: FieldConfig): List[Violation] = match kind {
        case FieldKind.Slug => match config#sourceField {
            case None                                                => Violation.Violation("config.sourceField", "SLUG には元にするフィールドの apiId が要ります") :: Nil
            case Some(source) if not List.memberOf(source, siblings) => Violation.Violation("config.sourceField", "'${source}' はこの型にありません") :: Nil
            case Some(_)                                             => Nil
        }
        case FieldKind.Number => Nil
        case _ =>
            let numberOnly = Option.isEmpty(config#min) and Option.isEmpty(config#max) and Option.isEmpty(config#integer);
            if (numberOnly) Nil else Violation.Violation("config", "min / max / integer は NUMBER だけの設定です") :: Nil
    }

}
