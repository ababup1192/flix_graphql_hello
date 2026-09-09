///
/// entry の中身の検証。全部純粋。
/// 下書きは緩く（値の形と長さ・範囲だけ）、必須は公開時に見る。一意と参照先の公開は DB が要るので ContentEntries.publish が見る。
///
mod EntryValidation {

    use Util.Json.Json

    ///
    /// 下書きとして保存できるか。型に無いフィールド、kind に合わない値、maxLength / min / max / integer の違反を返す。
    /// 無いフィールドは構わない。null は「値を消す」なのでどの kind でも通る。
    ///
    pub def draft(fields: List[FieldDef], data: EntryData): List[Violation] =
        draftAt("fields", fields, data)

    ///
    /// prefix 付きの検査。入れ子（Object / Blocks）は "fields.related.label" / "fields.sections[0].headline" のようにパスが伸びる。
    ///
    def draftAt(prefix: String, fields: List[FieldDef], data: EntryData): List[Violation] =
        let byApiId = fields |> List.map(field -> (field#apiId, field)) |> List.toMap;
        data |> Map.toList |> List.flatMap(match (apiId, value) ->
            match Map.get(apiId, byApiId) {
                case None        => Violation.Violation("${prefix}.${apiId}", "この型にありません") :: Nil
                case Some(field) => checkField("${prefix}.${apiId}", field, value)
            })

    ///
    /// 型に無いキーを落とす。フィールドを消した後に残った古い値を、保存や公開のたびに「この型にありません」と言わないため。
    ///
    pub def prune(fields: List[FieldDef], data: EntryData): EntryData =
        let known = fields |> List.map(field -> field#apiId) |> List.toSet;
        data |> Map.filterWithKey((apiId, _) -> Set.memberOf(apiId, known))

    ///
    /// 公開できるか。下書きの検査に加えて、required のフィールドに値がある事を見る（null・無い・空文字・空の配列は駄目）。
    /// unique はここでは見ない（公開中の値との照合は DB が要る。ContentEntries.publish）。
    ///
    pub def publish(fields: List[FieldDef], data: EntryData): List[Violation] =
        let missing = fields |> List.filter(field -> field#required) |> List.filter(field -> not hasValue(Map.get(field#apiId, data)))
            |> List.map(field -> Violation.Violation("fields.${field#apiId}", "公開には値が要ります"));
        draft(fields, data) ::: missing

    def hasValue(value: Option[Json]): Bool = match value {
        case None                    => false
        case Some(Json.JNull)        => false
        case Some(Json.JArray(items)) => not Vector.isEmpty(items)
        case Some(Json.JString(s))   => s != ""
        case Some(_)                 => true
    }

    ///
    /// 変更を重ねる。patch のキーだけ上書きし、null は消す。
    ///
    pub def merge(before: EntryData, patch: EntryData): EntryData =
        Map.foldLeftWithKey((acc, apiId, value) -> match value {
            case Json.JNull => Map.remove(apiId, acc)
            case _          => Map.insert(apiId, value, acc)
        }, before, patch)

    def checkField(path: String, field: FieldDef, value: Json): List[Violation] =
        match (field#many, value) {
            case (_, Json.JNull)          => Nil
            case (true, Json.JArray(items)) => items |> Vector.toList |> List.zipWithIndex |> List.flatMap(match (index, item) -> checkScalar("${path}[${index}]", field, item))
            case (true, _)                => Violation.Violation(path, "配列にしてください") :: Nil
            case (false, _)               => checkScalar(path, field, value)
        }

    def checkScalar(path: String, field: FieldDef, value: Json): List[Violation] =
        match (field#kind, value) {
            case (FieldKind.Object, Json.JObject(fields)) => badKeys(path, fields) ::: draftAt(path, Children.toList(field#children), EntryValue.objectData(fields))
            case (FieldKind.Object, _)                    => Violation.Violation(path, "オブジェクトにしてください") :: Nil
            case (FieldKind.Blocks, Json.JObject(fields)) => match EntryValue.readBlock(Children.toList(field#children), value) {
                case Some((variant, inner)) => badKeys(path, Map.remove(EntryValue.blockTypeKey(), fields)) ::: draftAt(path, Children.toList(variant#children), inner)
                case None                   => Violation.Violation(path, "${EntryValue.blockTypeKey()} は ${Children.toList(field#children) |> List.map(variant -> ApiId.text(variant#apiId)) |> List.join(" / ")} のどれかにしてください") :: Nil
            }
            case (FieldKind.Blocks, _)                    => Violation.Violation(path, "オブジェクト（${EntryValue.blockTypeKey()} 付き）にしてください") :: Nil
            case (FieldKind.Text, Json.JString(text))     => checkLength(path, field#config, text)
            case (FieldKind.TextArea, Json.JString(text)) => checkLength(path, field#config, text)
            case (FieldKind.Slug, Json.JString(text))     => checkLength(path, field#config, text)
            case (FieldKind.Number, Json.JNumber(n))      => checkNumber(path, field#config, n)
            case (FieldKind.Boolean, Json.JBool(_))       => Nil
            case (FieldKind.Select, Json.JString(text))   => if (List.memberOf(text, field#config#options)) Nil else Violation.Violation(path, "選択肢（${List.join(", ", field#config#options)}）にありません") :: Nil
            case (FieldKind.Reference, Json.JString(text)) => if (Option.nonEmpty(EntryId.parse(text))) Nil else Violation.Violation(path, "entry の id（${EntryId.rule()}）にしてください") :: Nil
            case (FieldKind.Asset, Json.JString(text))    => if (Option.nonEmpty(AssetId.parse(text))) Nil else Violation.Violation(path, "asset の id（${EntryId.rule()}）にしてください") :: Nil
            case (FieldKind.RichText, Json.JObject(_))    => RichText.validate(path, value)
            case (FieldKind.Date, Json.JString(text))     => if (DateValues.isCanonical(text)) Nil else Violation.Violation(path, DateValues.rejection(ApiId.text(field#apiId), text)) :: Nil
            case (FieldKind.Date, _)                      => Violation.Violation(path, "日時の文字列にしてください") :: Nil
            case (FieldKind.DateOnly, Json.JString(text)) => if (DateOnlyValues.isCanonical(text)) Nil else Violation.Violation(path, DateOnlyValues.rejection(ApiId.text(field#apiId), text)) :: Nil
            case (FieldKind.DateOnly, _)                  => Violation.Violation(path, "日付の文字列にしてください") :: Nil
            case (FieldKind.Asset, _)                     => Violation.Violation(path, "asset の id にしてください") :: Nil
            case (FieldKind.RichText, _)                  => Violation.Violation(path, "richText は { type: \"doc\", content: [...] } のオブジェクトにしてください") :: Nil
            case (FieldKind.Select, _)                    => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.Reference, _)                 => Violation.Violation(path, "entry の id にしてください") :: Nil
            case (FieldKind.Text, _)                      => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.TextArea, _)                  => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.Slug, _)                      => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.Number, _)                    => Violation.Violation(path, "数値にしてください") :: Nil
            case (FieldKind.Boolean, _)                   => Violation.Violation(path, "真偽値にしてください") :: Nil
        }

    ///
    /// 入れ子のキーの形。objectData は規則外のキーを黙って落とすので、検証ではそれを違反として言う（保存されて API から見えないゴミを残さない）。
    ///
    def badKeys(path: String, fields: Map[String, Json]): List[Violation] =
        fields |> Map.keysOf |> Set.toList |> List.filter(key -> Option.isEmpty(ApiId.parse(key)))
            |> List.map(key -> Violation.Violation("${path}.${key}", "フィールド名は ${ApiId.rule()} にしてください"))

    ///
    /// maxLength は文字（コードポイント）で数える。
    ///
    /// WhyNot: String.length で数えないのは、UTF-16 の単位なので絵文字が 2 文字に数えられるため。
    ///
    def checkLength(path: String, config: FieldConfig, text: String): List[Violation] =
        match config#maxLength {
            case Some(limit) if codePointCount(text) > limit => Violation.Violation(path, "${limit} 文字以内にしてください") :: Nil
            case _                                           => Nil
        }

    def codePointCount(text: String): Int32 =
        let surrogates = String.toList(text) |> List.count(Char.isSurrogate);
        String.length(text) - surrogates / 2

    def checkNumber(path: String, config: FieldConfig, number: BigDecimal): List[Violation] =
        let asFloat = BigDecimal.tryToFloat64(number);
        let lowChecks = match (config#min, asFloat) {
            case (Some(low), Some(x)) if x < low => Violation.Violation(path, "${low} 以上にしてください") :: Nil
            case _                               => Nil
        };
        let highChecks = match (config#max, asFloat) {
            case (Some(high), Some(x)) if x > high => Violation.Violation(path, "${high} 以下にしてください") :: Nil
            case _                                 => Nil
        };
        let integerChecks = match (config#integer, asFloat) {
            case (Some(true), Some(x)) if Float64.floor(x) != x => Violation.Violation(path, "整数にしてください") :: Nil
            case _                                              => Nil
        };
        lowChecks ::: highChecks ::: integerChecks

}
