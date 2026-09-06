///
/// 型ごとのリゾルバの雛形（src/resolvers/XResolvers.flix）の本文。gqlgen の resolver.go に当たる物で、
/// 人が所有するファイルなので一度書いたら二度と触らない。
///
mod Scaffold {

    ///
    /// 雛形のファイル名。
    ///
    pub def fileName(typeName: String): String = "${typeName}Resolvers.flix"

    ///
    /// 雛形が参照する名前。
    ///
    /// - moduleName: 生成物のモジュール（"Generated"）
    /// - effName: リゾルバの効果の別名（"AppEff"）
    ///
    pub type alias Names = { moduleName = String, effName = String }

    ///
    /// type X の雛形。useDefaults なら素通しのフィールドは <moduleName>.xDefaults() に任せ、残りだけ空の関数を吐く。
    /// source が enum の型は既定を使えないので useDefaults を false にする。
    ///
    pub def render(target: Names, document: SdlDocument, object: ObjectDef, useDefaults: Bool): String =
        let root = Emit.isRoot(document, object#name);
        let withDefaults = useDefaults and not root and List.exists(Emit.isPassthrough(document), object#fields);
        let handwritten = if (withDefaults) List.filter(field -> not Emit.isPassthrough(document, field), object#fields) else object#fields;
        let functions = handwritten |> List.map(field -> {
            let names = "_context" :: (if (root) Nil else "_src" :: Nil) ::: List.map(arg -> "_${Emit.label(arg#name)}", field#args);
            let params = match names {
                case single :: Nil => single
                case _             => "(" + List.join(", ", names) + ")"
            };
            List.join("\n",
                "    /// ${object#name}.${field#name}" ::
                "    pub def ${Emit.label(field#name)}(): ${target#moduleName}.${Emit.fieldAliasName(object#name, field#name)}[${target#effName}] =" ::
                "        ${params} -> Err(\"not implemented: ${object#name}.${field#name}\")" ::
                Nil)
        });
        let record =
            if (not withDefaults) "{ " + (handwritten |> List.map(entry(false)) |> List.join(", ")) + " }"
            else if (List.isEmpty(handwritten)) "${target#moduleName}.${Emit.defaultsFn(object#name)}()"
            else "{ " + (handwritten |> List.map(entry(true)) |> List.join(", ")) + " | ${target#moduleName}.${Emit.defaultsFn(object#name)}() }";
        List.join("\n",
            "///" ::
            "/// type ${object#name} のリゾルバ。`make scaffold` が作った雛形で、人が所有する（作り直されない）。" ::
            "///" ::
            "mod ${object#name}Resolvers {" ::
            "" ::
            (functions |> List.map(function -> function + "\n")) :::
            "    /// type ${object#name} のリゾルバ一式" ::
            "    pub def resolvers(): ${target#moduleName}.${object#name}Resolvers[${target#effName}] =" ::
            "        ${record}" ::
            "" ::
            "}" ::
            Nil)

    ///
    /// レコードの 1 項目。既定に足す形なら + が付く。
    ///
    def entry(extending: Bool, field: FieldDef): String =
        let name = Emit.label(field#name);
        "${if (extending) "+" else ""}${name} = ${name}()"

}
