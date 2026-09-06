///
/// entry の中身の検証。全部純粋。
/// 下書きは緩く（値の形と長さ・範囲だけ）、必須・一意・参照先の存在は公開時に見る（公開はステップ 5）。
///
mod EntryValidation {

    use Util.Json.Json

    ///
    /// 下書きとして保存できるか。型に無いフィールド、kind に合わない値、maxLength / min / max / integer の違反を返す。
    /// 無いフィールドは構わない。null は「値を消す」なのでどの kind でも通る。
    ///
    pub def draft(fields: List[FieldDef], data: EntryData): List[Violation] =
        data |> Map.toList |> List.flatMap(match (apiId, value) ->
            match List.find(field -> field#apiId == apiId, fields) {
                case None        => Violation.Violation("fields.${apiId}", "この型にありません") :: Nil
                case Some(field) => checkField(field, value)
            })

    ///
    /// 変更を重ねる。patch のキーだけ上書きし、null は消す。
    ///
    pub def merge(before: EntryData, patch: EntryData): EntryData =
        Map.foldLeftWithKey((acc, apiId, value) -> match value {
            case Json.JNull => Map.remove(apiId, acc)
            case _          => Map.insert(apiId, value, acc)
        }, before, patch)

    def checkField(field: FieldDef, value: Json): List[Violation] =
        let path = "fields.${field#apiId}";
        match (field#many, value) {
            case (_, Json.JNull)          => Nil
            case (true, Json.JArray(items)) => items |> Vector.toList |> List.flatMap(item -> checkScalar(path, field, item))
            case (true, _)                => Violation.Violation(path, "配列にしてください") :: Nil
            case (false, _)               => checkScalar(path, field, value)
        }

    def checkScalar(path: String, field: FieldDef, value: Json): List[Violation] =
        match (field#kind, value) {
            case (FieldKind.Text, Json.JString(text))     => checkLength(path, field#config, text)
            case (FieldKind.TextArea, Json.JString(text)) => checkLength(path, field#config, text)
            case (FieldKind.Slug, Json.JString(text))     => checkLength(path, field#config, text)
            case (FieldKind.Number, Json.JNumber(n))      => checkNumber(path, field#config, n)
            case (FieldKind.Boolean, Json.JBool(_))       => Nil
            case (FieldKind.Text, _)                      => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.TextArea, _)                  => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.Slug, _)                      => Violation.Violation(path, "文字列にしてください") :: Nil
            case (FieldKind.Number, _)                    => Violation.Violation(path, "数値にしてください") :: Nil
            case (FieldKind.Boolean, _)                   => Violation.Violation(path, "真偽値にしてください") :: Nil
        }

    def checkLength(path: String, config: FieldConfig, text: String): List[Violation] =
        match config#maxLength {
            case Some(limit) if String.length(text) > limit => Violation.Violation(path, "${limit} 文字以内にしてください") :: Nil
            case _                                          => Nil
        }

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
        let integerChecks = match (config#integer, BigDecimal.tryToInt32(number), asFloat) {
            case (Some(true), Some(whole), Some(x)) if Int32.toFloat64(whole) != x => Violation.Violation(path, "整数にしてください") :: Nil
            case (Some(true), None, _)                                              => Violation.Violation(path, "整数にしてください") :: Nil
            case _                                                                  => Nil
        };
        lowChecks ::: highChecks ::: integerChecks

}
