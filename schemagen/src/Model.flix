///
/// SDL の型参照。NonNull が付いていなければ nullable（Flix では Option）。
///
pub enum Ty with Eq, ToString {
    /// 名前で参照する型（スカラー・enum・オブジェクト型）
    case Named(String)
    /// [T]
    case ListOf(Ty)
    /// T!
    case NonNull(Ty)
}

///
/// フィールドの引数。defaultValue は Flix の `Value` を作る式の文字列（生成物にそのまま埋める）。
///
pub type alias ArgDef = { name = String, ty = Ty, description = Option[String], defaultValue = Option[String] }

///
/// @deprecated の reason の有無。
///
pub enum Deprecation with Eq, ToString {
    /// @deprecated(reason: "...")
    case Reason(String)
    /// reason 無しの @deprecated
    case NoReason
}

///
/// オブジェクト型のフィールド。
///
pub type alias FieldDef = { name = String, args = List[ArgDef], ty = Ty, description = Option[String], deprecated = Option[Deprecation] }

///
/// type Name { ... }
///
pub type alias ObjectDef = { name = String, description = Option[String], interfaces = List[String], fields = List[FieldDef] }

///
/// union Name = A | B
///
pub type alias UnionDef = { name = String, description = Option[String], members = List[String] }

///
/// interface Name { ... }
///
pub type alias InterfaceDef = { name = String, description = Option[String], fields = List[FieldDef] }

///
/// input Name { ... }。フィールドは引数と同じ形。
///
pub type alias InputDef = { name = String, description = Option[String], fields = List[ArgDef] }

///
/// enum の値 1 つ。
///
pub type alias EnumValueDef = { name = String, description = Option[String], deprecated = Option[Deprecation] }

///
/// enum Name { ... }
///
pub type alias EnumDef = { name = String, description = Option[String], values = List[EnumValueDef] }

///
/// SDL 全体。queryName / mutationName は `schema { }` ブロックで変えられる（無ければ Query と、あれば Mutation）。
/// objectNames / enumNames は objects / enums の名前の集合（型参照の解決で毎回リストを走査しないため）。
///
pub type alias SdlDocument = {
    objects = List[ObjectDef], enums = List[EnumDef], inputs = List[InputDef], unions = List[UnionDef], interfaces = List[InterfaceDef],
    objectNames = Set[String], enumNames = Set[String], inputNames = Set[String], unionNames = Set[String], interfaceNames = Set[String],
    queryName = String, mutationName = Option[String]
}
