///
/// content type の種別。
///
pub enum TypeKind with Eq, Order, ToString {
    /// entry を何件でも持つ
    case Collection
    /// entry を 1 件だけ持つ（サイト設定など）
    case Singleton
}

///
/// フィールドの種類。コンテンツ API の型と、entry の値の検証がここで決まる。
///
pub enum FieldKind with Eq, Order, ToString {
    /// 1 行のテキスト
    case Text
    /// 複数行のテキスト
    case TextArea
    /// URL に使う識別子。sourceField から自動生成し、型の中で一意
    case Slug
    /// 数値
    case Number
    /// 真偽値
    case Boolean
    /// 決まった選択肢から。config.options。many なら複数選べる（値は選択肢の配列）
    case Select
    /// 他の entry への参照。target が参照先の型
    case Reference
    /// 子フィールドを持つ入れ子（カスタムフィールド）。値は子の apiId → 値のオブジェクト
    case Object
    /// 複数の Object（variant）から選んで並べる。値は { blockType: <variant の apiId>, ... } の配列
    case Blocks
    /// 画像やファイル。値は asset の id。コンテンツ API では Asset（url など）に展開する
    case Asset
    /// 構造化した本文（ProseMirror の doc）。コンテンツ API では RichText（json / html / text）
    case RichText
    /// 日時（瞬間）。値は UTC の ISO 8601 の文字列（"2026-09-09T00:00:00Z"）ちょうど 1 通り
    case Date
    /// 日付だけ。値は "2026-09-09" ちょうど 1 通り。時刻を持たないので、読む側のタイムゾーンで日がずれない
    case DateOnly
}

///
/// kind ごとの設定。使わない項目は None。
///
/// - maxLength: Text / TextArea / Slug の最大文字数
/// - sourceField: Slug の元にするフィールドの apiId
/// - min / max: Number の範囲
/// - integer: Number を整数に限るか
/// - options: Select の選択肢。コンテンツ API では enum の値になるので UPPER_SNAKE
///
pub type alias FieldConfig = { maxLength = Option[Int32], sourceField = Option[ApiId], min = Option[Float64], max = Option[Float64], integer = Option[Bool], options = List[String] }

///
/// フィールドの定義。
///
/// - id: content_fields.id
/// - typeId: 属する content type
/// - apiId: 型の中で一意な識別子
/// - name: 管理画面に出す名前
/// - kind: 種類
/// - many: 配列か
/// - required: 公開時に値が要るか
/// - unique: 型の中で値が一意か
/// - localized: 言語ごとに値を持つか
/// - target: Reference の参照先の型。それ以外は None
/// - parent: Object / Blocks の子なら親のフィールド。最上位なら None
/// - children: Object の子フィールド、Blocks の variant（Object）。position 順
/// - config: kind ごとの設定
/// - position: 兄弟の中の並び順（0 始まり）
///
pub type alias FieldDef = {
    id = FieldId,
    typeId = TypeId,
    apiId = ApiId,
    name = String,
    kind = FieldKind,
    many = Bool,
    required = Bool,
    unique = Bool,
    localized = Bool,
    target = Option[TypeId],
    parent = Option[FieldId],
    children = Children,
    config = FieldConfig,
    position = Int32
}

///
/// 子フィールド。
///
/// WhyNot: FieldDef に List[FieldDef] を直に置かないのは、型の別名が自分を参照できないため。enum で切る。
///
pub enum Children {
    case Children(List[FieldDef])
}

mod Children {
    pub def none(): Children = Children.Children(Nil)

    pub def toList(children: Children): List[FieldDef] =
        let Children.Children(fields) = children;
        fields
}

///
/// content type の定義。フィールドを抱えて 1 度に読む。
///
/// - id: content_types.id
/// - apiId: 識別子（"blogs"）。コンテンツ API のクエリ名の元
/// - kind: collection か singleton
/// - name: 管理画面に出す名前
/// - singular: コンテンツ API の型名（"Blog"）
/// - plural: コンテンツ API の一覧クエリ名（"blogs"）
/// - previewUrl: 管理画面のプレビューが開く URL。無ければ None
/// - icon: 管理画面が絵を選ぶための短い識別子（"book"）。省いて作れば kind ごとの既定
/// - fields: position 順のフィールド
/// - createdAt / updatedAt: 作成と更新の時刻
///
pub type alias ContentType = {
    id = TypeId,
    apiId = ApiId,
    kind = TypeKind,
    name = String,
    singular = TypeName,
    plural = ApiId,
    previewUrl = Option[String],
    icon = String,
    fields = List[FieldDef],
    createdAt = Timestamp.Timestamp,
    updatedAt = Timestamp.Timestamp
}

///
/// 作る content type。singular / plural を省けば apiId から導き、icon を省けば kind ごとの既定。
///
pub type alias ContentTypeDraft = { apiId = ApiId, kind = TypeKind, name = String, singular = Option[TypeName], plural = Option[ApiId], previewUrl = Option[String], icon = Option[String] }

///
/// content type の変更。None は「触らない」。
///
pub type alias ContentTypeChanges = { name = Option[String], singular = Option[TypeName], plural = Option[ApiId], previewUrl = Option[String], icon = Option[String] }

///
/// 足すフィールド。
///
pub type alias FieldDraft = { apiId = ApiId, name = String, kind = FieldKind, many = Bool, required = Bool, unique = Bool, localized = Bool, target = Option[TypeId], parent = Option[FieldId], config = FieldConfig }

///
/// フィールドの変更。None は「触らない」。config は丸ごと置き換える。
///
pub type alias FieldChanges = { name = Option[String], required = Option[Bool], unique = Option[Bool], localized = Option[Bool], config = Option[FieldConfig] }

mod FieldConfig {

    use Util.Json.Json

    ///
    /// 何も設定していない config。
    ///
    pub def empty(): FieldConfig = { maxLength = None, sourceField = None, min = None, max = None, integer = None, options = Nil }

    ///
    /// content_fields.config の JSON にする。None の項目はキー自体を出さない。
    ///
    /// WhyNot: NaN や無限大の min / max を落とすのは、JSON に書けないため。GraphQL の Float からは来ない。
    ///
    pub def toJson(config: FieldConfig): Json =
        let entries =
            ("maxLength", config#maxLength |> Option.map(n -> Json.JNumber(Int32.toBigDecimal(n)))) ::
            ("sourceField", config#sourceField |> Option.map(id -> Json.JString(ApiId.text(id)))) ::
            ("min", config#min |> Option.flatMap(Float64.tryToBigDecimal) |> Option.map(Json.JNumber)) ::
            ("max", config#max |> Option.flatMap(Float64.tryToBigDecimal) |> Option.map(Json.JNumber)) ::
            ("integer", config#integer |> Option.map(Json.JBool)) ::
            ("options", if (List.isEmpty(config#options)) None else Some(Json.JArray(config#options |> List.map(Json.JString) |> List.toVector))) ::
            Nil;
        Json.JObject(entries |> List.filterMap(match (key, value) -> Option.map(json -> (key, json), value)) |> List.toMap)

    ///
    /// content_fields.config の JSON から。無いキーや型の違う値は None にする（壊れた config で落ちない）。
    ///
    pub def fromJson(json: Json): FieldConfig =
        let fields = match json {
            case Json.JObject(map) => map
            case _                 => Map.empty()
        };
        {
            maxLength   = Map.get("maxLength", fields) |> Option.flatMap(EntryValue.asInt32),
            sourceField = Map.get("sourceField", fields) |> Option.flatMap(EntryValue.asString) |> Option.flatMap(ApiId.parse),
            min         = Map.get("min", fields) |> Option.flatMap(EntryValue.asFloat64),
            max         = Map.get("max", fields) |> Option.flatMap(EntryValue.asFloat64),
            integer     = Map.get("integer", fields) |> Option.flatMap(EntryValue.asBool),
            options     = Map.get("options", fields) |> Option.map(EntryValue.asStrings) |> Option.getWithDefault(Nil)
        }


}
