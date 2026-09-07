///
/// content type の id。content_types.id を包む。FieldId と取り違えない。
///
pub enum TypeId with Eq, Order {
    case TypeId(Int64)
}

instance ToString[TypeId] {
    pub def toString(id: TypeId): String = Int64.toString(TypeId.toInt64(id))
}

mod TypeId {
    pub def toInt64(id: TypeId): Int64 =
        let TypeId.TypeId(number) = id;
        number
}

///
/// フィールドの id。content_fields.id を包む。
///
pub enum FieldId with Eq, Order {
    case FieldId(Int64)
}

instance ToString[FieldId] {
    pub def toString(id: FieldId): String = Int64.toString(FieldId.toInt64(id))
}

mod FieldId {
    pub def toInt64(id: FieldId): Int64 =
        let FieldId.FieldId(number) = id;
        number
}

///
/// lowerCamel の識別子（[a-z][A-Za-z0-9]*）。型の apiId、一覧クエリ名、フィールドの apiId に使う。
/// コンテンツ API の GraphQL のフィールド名になるので、`parse` を通した物だけを作る。
///
pub enum ApiId with Eq, Order {
    case ApiId(String)
}

instance ToString[ApiId] {
    pub def toString(id: ApiId): String = ApiId.text(id)
}

mod ApiId {

    ///
    /// 規則に合えば Some。
    ///
    pub def parse(text: String): Option[ApiId] =
        if (String.isMatch(regex = "^[a-z][A-Za-z0-9]*$", text)) Some(ApiId.ApiId(text)) else None

    ///
    /// 中の文字列。
    ///
    pub def text(id: ApiId): String =
        let ApiId.ApiId(raw) = id;
        raw

    ///
    /// 規則の説明。エラーメッセージ用。
    ///
    pub def rule(): String = "lowerCamel の識別子（[a-z][A-Za-z0-9]*）"

}

///
/// UpperCamel の識別子（[A-Z][A-Za-z0-9]*）。コンテンツ API の型名（singular）に使う。`parse` を通した物だけを作る。
///
pub enum TypeName with Eq, Order {
    case TypeName(String)
}

instance ToString[TypeName] {
    pub def toString(name: TypeName): String = TypeName.text(name)
}

mod TypeName {

    ///
    /// 規則に合えば Some。
    ///
    pub def parse(text: String): Option[TypeName] =
        if (String.isMatch(regex = "^[A-Z][A-Za-z0-9]*$", text)) Some(TypeName.TypeName(text)) else None

    ///
    /// 中の文字列。
    ///
    pub def text(name: TypeName): String =
        let TypeName.TypeName(raw) = name;
        raw

    ///
    /// 規則の説明。エラーメッセージ用。
    ///
    pub def rule(): String = "UpperCamel の識別子（[A-Z][A-Za-z0-9]*）"

}

///
/// プロジェクトの id。projects.id を包む。1 つの DB に複数のプロジェクト（型と entry の集まり）を持つための区切り。
///
pub enum ProjectId with Eq, Order {
    case ProjectId(Int64)
}

instance ToString[ProjectId] {
    pub def toString(id: ProjectId): String = Int64.toString(ProjectId.toInt64(id))
}

mod ProjectId {
    pub def toInt64(id: ProjectId): Int64 =
        let ProjectId.ProjectId(number) = id;
        number

    ///
    /// 既定プロジェクト（migration が作る id 1、プロジェクト slug "default"）。セルフホストで 1 つだけ使う時はこれ。
    ///
    pub def default(): ProjectId = ProjectId.ProjectId(1i64)
}

///
/// プロジェクト slug。URL の /p/{プロジェクト slug}/ と subdomain でプロジェクトを選ぶ、人が読める名前。
/// DNS のラベルとして使えるよう [a-z0-9][a-z0-9-]{0,63} に限り、`parse` を通した物だけを作る。予約した名前の検査は Projects が持つ。
///
pub enum ProjectSlug with Eq, Order {
    case ProjectSlug(String)
}

instance ToString[ProjectSlug] {
    pub def toString(slug: ProjectSlug): String = ProjectSlug.text(slug)
}

mod ProjectSlug {

    ///
    /// 規則に合えば Some。大文字は許さない（Host は小文字で来るので、入口で小文字に揃える）。
    ///
    pub def parse(text: String): Option[ProjectSlug] =
        if (String.isMatch(regex = "^[a-z0-9][a-z0-9-]{0,63}$", text)) Some(ProjectSlug.ProjectSlug(text)) else None

    ///
    /// 中の文字列。
    ///
    pub def text(slug: ProjectSlug): String =
        let ProjectSlug.ProjectSlug(raw) = slug;
        raw

    ///
    /// 規則の説明。エラーメッセージ用。
    ///
    pub def rule(): String = "英小文字・数字・- を 1 〜 64 文字（先頭は英数字）"

    ///
    /// 既定プロジェクトのプロジェクト slug。
    ///
    pub def default(): ProjectSlug = ProjectSlug.ProjectSlug("default")

}
