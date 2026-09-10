///
/// これから押すスキーマの操作。
///
pub enum SchemaEdit {
    case RemoveField(FieldId)
    case UpdateField(FieldId, FieldChanges)
    case AddField(TypeId, FieldDraft)
    case DeleteContentType(TypeId)
}

///
/// 押した後のスキーマを組み立てて、押す前に差を出す。純粋。
///
/// WhyNot: 変更の列を操作ごとに手で作らない。「何を締めたら破壊か」（選択肢を減らす・上限を縮める）は
/// SchemaDiff が持っているので、押した後の姿を作って同じ diff に通せば、規則が 1 か所で済む。
///
/// WhyNot: ここが本物の mutation とずれていないかは型では見られない。TestSchemaPreviewPg が、
/// dry-run が出した影響と、実際に押した時に止まる理由を突き合わせる。
///
mod SchemaPreview {

    ///
    /// 押したら出る変更の列。
    ///
    pub def changesFor(edit: SchemaEdit, before: List[ContentType]): List[SchemaChange] =
        SchemaDiff.diff(before, applied(edit, before))

    /// 押した後のスキーマ。DB は触らない。
    def applied(edit: SchemaEdit, types: List[ContentType]): List[ContentType] = match edit {
        case SchemaEdit.RemoveField(id) =>
            types |> List.map(owner -> { fields = withoutField(id, owner#fields) | owner })
        case SchemaEdit.UpdateField(id, changes) =>
            types |> List.map(owner -> { fields = patched(id, changes, owner#fields) | owner })
        case SchemaEdit.AddField(typeId, draft) =>
            types |> List.map(owner -> if (owner#id == typeId) { fields = owner#fields ::: (fresh(owner, draft) :: Nil) | owner } else owner)
        case SchemaEdit.DeleteContentType(typeId) =>
            types |> List.filter(owner -> owner#id != typeId)
    }

    /// 木から 1 本抜く。子も一緒に消える（DB は FK の CASCADE で落とす）。
    def withoutField(id: FieldId, tree: List[FieldDef]): List[FieldDef] =
        tree |> List.filter(field -> field#id != id)
            |> List.map(field -> { children = Children.Children(withoutField(id, Children.toList(field#children))) | field })

    /// 木の 1 本に変更を重ねる。None は触らない。
    def patched(id: FieldId, changes: FieldChanges, tree: List[FieldDef]): List[FieldDef] =
        tree |> List.map(field ->
            let inner = { children = Children.Children(patched(id, changes, Children.toList(field#children))) | field };
            if (field#id != id) inner
            else {
                name = changes#name |> Option.getWithDefault(inner#name),
                required = changes#required |> Option.getWithDefault(inner#required),
                unique = changes#unique |> Option.getWithDefault(inner#unique),
                localized = changes#localized |> Option.getWithDefault(inner#localized),
                config = changes#config |> Option.getWithDefault(inner#config)
                | inner
            })

    ///
    /// まだ作られていないフィールド。id は 0（DB が振る前なので突き合わせには使わない）。
    ///
    /// 位置は末尾。addField が末尾に足すので、並びの変更としては出ない。
    ///
    def fresh(owner: ContentType, draft: FieldDraft): FieldDef =
        { id = FieldId.FieldId(0i64), typeId = owner#id, apiId = draft#apiId, name = draft#name, kind = draft#kind,
          many = draft#many, required = draft#required, unique = draft#unique, localized = draft#localized,
          target = draft#target, parent = draft#parent, children = Children.none(), config = draft#config,
          position = List.length(owner#fields) }

}
