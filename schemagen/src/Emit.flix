///
/// SdlDocument から GeneratedSchema.flix の本文を組み立てる。純粋な文字列生成。
///
mod Emit {

    ///
    /// 生成器のバージョン。生成物の形が変わる修正をしたら、本体の GeneratedCheck.expectedGeneratorVersion と一緒に上げる
    /// （本体が照合し、再生成が要求される）。
    ///
    pub def generatorVersion(): String = "1"

    ///
    /// Flix の予約語。SDL の名前がこれに当たれば末尾に _ を付ける。
    /// 一覧の出所は flix_game_engine の bin/lint-rules/flix-reserved.json（0.75.1 で実測）。
    ///
    def reservedWords(): Set[String] = Set#{
        "from", "into", "run", "spawn", "region", "project", "solve", "inject", "handler", "query", "select", "where",
        "force", "discard", "law", "alias", "lazy", "static", "par", "unsafe", "foreach", "forM", "forA", "new", "throw",
        "catch", "try", "import", "use", "match", "case", "let", "if", "else", "not", "and", "or", "true", "false",
        "null", "with", "yield", "checked_cast", "type", "def", "mod", "pub", "enum", "eff", "instance", "trait"
    }

    ///
    /// SDL の型名として使えない名前。生成物が使う Flix の名前と衝突する。
    ///
    def forbiddenTypeNames(): Set[String] = Set#{
        "Schema", "Context", "Field", "Out", "Value", "Id", "Arg", "Option", "Result", "List", "Map", "Unit", "Generated", "GqlCodec", "FieldError",
        "ObjectType", "Resolvers", "Int32", "Float64", "String", "Bool", "IO", "Nil", "Some", "None", "Ok", "Err", "Set", "Eq", "Order", "ToString"
    }

    ///
    /// GraphQL の組み込みスカラー → Flix の型名。
    ///
    def scalarTypes(): Map[String, String] = Map#{ "Int" => "Int32", "Float" => "Float64", "String" => "String", "Boolean" => "Bool", "ID" => "Id" }

    ///
    /// 組み込みスカラーの Codec / Out の関数名（GqlCodec.xxx() / Out.xxx()）。
    ///
    def scalarFns(): Map[String, String] = Map#{ "Int" => "int32", "Float" => "float64", "String" => "string", "Boolean" => "bool", "ID" => "id" }

    ///
    /// 生成物の全文。sdl は生成元の本文で、そのまま生成物に埋めて本体が schema.graphql と照合する。
    ///
    pub def render(document: SdlDocument, sdl: String): Result[String, String] =
        forM (
            _        <- validateNames(document);
            _        <- validateReachable(document);
            enums    <- Result.traverse(renderEnum, document#enums);
            objects  <- Result.traverse(renderObject(document), document#objects)
        ) yield {
            let resolverAliases = document#objects |> List.map(renderResolverAlias(document));
            let allResolvers = document#objects |> List.map(object -> "        ${typeLabel(document, object#name)} = ${object#name}Resolvers") |> List.join(",\n");
            let mutationExpr = document#mutationName |> Option.map(name -> "Some(${typeFn(name)}(resolvers))") |> Option.getWithDefault("None");
            let enumSection = if (List.isEmpty(enums)) Nil else (List.join("\n\n", enums) + "\n") :: Nil;
            List.join("\n",
                "///" ::
                "/// schema.graphql から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。" ::
                "///" ::
                "mod Generated {" ::
                "" ::
                "    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が schema.graphql と照合する" ::
                "    pub def sdlText(): String = ${stringLiteral(sdl)}" ::
                "" ::
                "    /// 生成した schemagen のバージョン" ::
                "    pub def generatorVersion(): String = \"${generatorVersion()}\"" ::
                "" ::
                enumSection :::
                List.join("\n\n", resolverAliases) ::
                "" ::
                "    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー" ::
                "    pub type alias Resolvers = {\n${allResolvers}\n    }" ::
                "" ::
                "    /// リゾルバ一式からスキーマを組み立てる" ::
                "    pub def schema(resolvers: Resolvers): Schema =" ::
                "        Schema.make(${typeFn(document#queryName)}(resolvers), ${mutationExpr})" ::
                "" ::
                List.join("\n\n", objects) ::
                "" ::
                "}" ::
                Nil)
        }

    ///
    /// 型名の禁止名・重複・大小文字、フィールド名と引数名の大小文字、enum 値の変換衝突、ルート型の存在を確かめる。
    ///
    def validateNames(document: SdlDocument): Result[String, Unit] =
        let typeNames = List.map(object -> object#name, document#objects) ::: List.map(enumDef -> enumDef#name, document#enums);
        let forbidden = typeNames |> List.filter(name -> Set.memberOf(name, forbiddenTypeNames()));
        let duplicated = duplicates(typeNames);
        let lowerTypes = typeNames |> List.filter(name -> not startsUpper(name));
        let upperFields = document#objects |> List.flatMap(object -> object#fields |> List.flatMap(field ->
            (if (startsUpper(field#name)) "${object#name}.${field#name}" :: Nil else Nil)
            ::: (field#args |> List.filter(arg -> startsUpper(arg#name)) |> List.map(arg -> "${object#name}.${field#name}(${arg#name})"))));
        let hasQuery = List.exists(object -> object#name == document#queryName, document#objects);
        let hasMutation = document#mutationName |> Option.map(name -> List.exists(object -> object#name == name, document#objects)) |> Option.getWithDefault(true);
        let enumProblems = document#enums |> List.filterMap(enumDef -> {
            let cases = List.map(caseName, enumDef#values);
            let collisions = duplicates(cases);
            let badStart = enumDef#values |> List.filter(value -> caseName(value) |> String.startsWith(prefix = "_"));
            if (not List.isEmpty(collisions)) Some("enum ${enumDef#name} の値が Flix の名前に変換すると衝突します")
            else if (not List.isEmpty(badStart)) Some("enum ${enumDef#name} の値 ${List.join(", ", badStart)} は Flix の名前にできません")
            else None
        });
        if (not List.isEmpty(forbidden)) Err("型名 ${List.join(", ", forbidden)} は生成物の名前と衝突するので使えません")
        else if (not List.isEmpty(duplicated)) Err("型 ${List.join(", ", duplicated)} が 2 回定義されています")
        else if (not List.isEmpty(lowerTypes)) Err("型名 ${List.join(", ", lowerTypes)} は大文字で始めてください（Flix の型名の決まり）")
        else if (not List.isEmpty(upperFields)) Err("フィールド名・引数名 ${List.join(", ", upperFields)} は小文字で始めてください（Flix のラベルの決まり）")
        else if (not hasQuery) Err("ルート型 ${document#queryName} がありません")
        else if (not hasMutation) Err("ルート型 ${document#mutationName |> Option.getWithDefault("")} がありません")
        else match enumProblems {
            case Nil          => Ok(())
            case message :: _ => Err(message)
        }

    ///
    /// 2 回以上現れる名前（重複なし、出現順）。
    ///
    def duplicates(names: List[String]): List[String] =
        let counts = List.foldLeft((accumulated, name) -> Map.insertWith((a, b) -> a + b, name, 1, accumulated), Map.empty(), names);
        names |> List.filter(name -> Map.getWithDefault(name, 0, counts) > 1) |> List.distinct

    ///
    /// 先頭が大文字か。
    ///
    def startsUpper(name: String): Bool =
        not String.isEmpty(name) and (String.charAt(0, name) |> Char.isUpperCase)

    ///
    /// ルート型から届かないオブジェクト型・enum があれば Err。
    ///
    /// WhyNot: 届かない型を黙って生成しないのは、生成物の private な関数が未使用になって本体のコンパイルが
    /// 落ちる（Redundancy Error）ため。SDL の書き間違いとして生成器で止める方が原因が読める。
    ///
    def validateReachable(document: SdlDocument): Result[String, Unit] =
        let roots = document#queryName :: Option.toList(document#mutationName);
        let reached = reach(document, roots, Set.empty());
        let all = List.map(object -> object#name, document#objects) ::: List.map(enumDef -> enumDef#name, document#enums);
        match List.filter(name -> not Set.memberOf(name, reached), all) {
            case Nil      => Ok(())
            case orphans  => Err("型 ${List.join(", ", orphans)} は Query / Mutation から届きません")
        }

    ///
    /// 名前の一覧から辿れる型名を集める（深さ優先）。
    ///
    def reach(document: SdlDocument, pending: List[String], seen: Set[String]): Set[String] = match pending {
        case Nil => seen
        case name :: rest =>
            if (Set.memberOf(name, seen)) reach(document, rest, seen)
            else {
                let referenced = document#objects |> List.find(object -> object#name == name) |> Option.map(object ->
                    object#fields |> List.flatMap(field -> baseName(field#ty) :: List.map(arg -> baseName(arg#ty), field#args))) |> Option.getWithDefault(Nil);
                reach(document, referenced ::: rest, Set.insert(name, seen))
            }
    }

    ///
    /// 型参照の中の名前。
    ///
    def baseName(ty: Ty): String = match ty {
        case Ty.Named(name)    => name
        case Ty.ListOf(inner)  => baseName(inner)
        case Ty.NonNull(inner) => baseName(inner)
    }

    ///
    /// enum 型と、その Codec を返す関数。
    ///
    def renderEnum(enumDef: EnumDef): Result[String, String] =
        match enumDef#values {
            case Nil => Err("enum ${enumDef#name} に値がありません")
            case _   => {
                let cases = enumDef#values |> List.map(value -> "        /// ${value}\n        case ${caseName(value)}") |> List.join("\n");
                let arms = enumDef#values |> List.map(value -> "case ${enumDef#name}.${caseName(value)} => ${stringLiteral(value)}") |> List.join(" ");
                let values = enumDef#values |> List.map(value -> "${enumDef#name}.${caseName(value)}") |> List.join(" :: ");
                Ok(List.join("\n",
                    "    /// enum ${enumDef#name}" ::
                    "    pub enum ${enumDef#name} with Eq, Order, ToString {" ::
                    cases ::
                    "    }" ::
                    "" ::
                    "    /// ${enumDef#name} の Codec" ::
                    "    pub def ${codecFn(enumDef#name)}(): GqlCodec[${enumDef#name}] =" ::
                    "        GqlCodec.enumOf(${stringLiteral(enumDef#name)}, value -> match value { ${arms} }, ${values} :: Nil)" ::
                    Nil))
            }
        }

    ///
    /// type X のリゾルバ一式のレコード型。
    ///
    def renderResolverAlias(document: SdlDocument, object: ObjectDef): String =
        let source = if (isRoot(document, object#name)) Nil else object#name :: Nil;
        let fields = object#fields |> List.map(field -> {
            let argTypes = List.map(arg -> flixType(document, arg#ty), field#args);
            let params = ("Context" :: source ::: argTypes) |> List.join(" -> ");
            "        ${label(field#name)} = ${params} -> Result[FieldError, ${flixType(document, field#ty)}] \\ IO"
        }) |> List.join(",\n");
        let sourceNote = if (isRoot(document, object#name)) "" else "。第 2 引数が source";
        "    /// type ${object#name} のリゾルバ一式${sourceNote}\n    pub type alias ${object#name}Resolvers = {\n${fields}\n    }"

    ///
    /// type X の ObjectType を作る関数。
    ///
    def renderObject(document: SdlDocument, object: ObjectDef): Result[String, String] =
        let sourceType = if (isRoot(document, object#name)) "Unit" else object#name;
        Result.traverse(renderField(document, object), object#fields) |> Result.map(fields ->
            List.join("\n",
                "    /// type ${object#name}" ::
                "    def ${typeFn(object#name)}(resolvers: Resolvers): ObjectType[${sourceType}] =" ::
                "        Schema.objectType(${stringLiteral(object#name)}, () ->" ::
                (fields |> List.map(field -> "${field} ::") |> List.join("\n")) ::
                "            Nil)" ::
                Nil))

    ///
    /// フィールド 1 つ分の Schema.fieldRaw の呼び出し。
    ///
    def renderField(document: SdlDocument, object: ObjectDef, field: FieldDef): Result[String, String] =
        let root = isRoot(document, object#name);
        let sourceParam = if (root) "_src" else "src";
        let sourceArg = if (root) Nil else "src" :: Nil;
        let indexed = List.zip(List.range(0, List.length(field#args)), field#args);
        forM (
            argLets <- Result.traverse(match (index, arg) -> codecExpr(document, arg#ty) |> Result.map(codec -> "                let arg${index} = Schema.arg(${stringLiteral(arg#name)}, ${codec})${argDecorations(arg)};"), indexed);
            out     <- outExpr(document, field#ty)
        ) yield {
            let infos = (indexed |> List.map(match (index, _) -> "Arg.info(arg${index}) :: ") |> List.join("")) + "Nil";
            let decodes = indexed |> List.map(match (index, _) -> "v${index} <- Arg.decode(arg${index}, args); ") |> List.join("");
            let callArgs = ("context" :: sourceArg ::: List.map(match (index, _) -> "v${index}", indexed)) |> List.join(", ");
            let call = "(resolvers#${typeLabel(document, object#name)}#${label(field#name)})(${callArgs})";
            let argsParam = if (List.isEmpty(field#args)) "_args" else "args";
            let body = if (List.isEmpty(field#args)) call else "forM (${decodes}result <- ${call}) yield result";
            List.join("\n",
                "            {" ::
                argLets :::
                "                Schema.fieldRaw(${stringLiteral(field#name)}, ${infos}, ${out}, (context, ${sourceParam}, ${argsParam}) ->" ::
                "                    ${body})${fieldDecorations(field)}" ::
                "            }" ::
                Nil)
        }

    ///
    /// description / deprecated の後付け。
    ///
    def fieldDecorations(field: FieldDef): String =
        (field#description |> Option.map(text -> " |> Field.withDescription(${stringLiteral(text)})") |> Option.getWithDefault(""))
        + (field#deprecated |> Option.map(deprecation -> match deprecation {
            case Deprecation.Reason(text) => " |> Field.withDeprecation(${stringLiteral(text)})"
            case Deprecation.NoReason     => " |> Field.deprecate"
        }) |> Option.getWithDefault(""))

    ///
    /// 引数の description / 既定値の後付け。
    ///
    def argDecorations(arg: ArgDef): String =
        (arg#description |> Option.map(text -> " |> Arg.withDescription(${stringLiteral(text)})") |> Option.getWithDefault(""))
        + (arg#defaultValue |> Option.map(expr -> " |> Arg.withDefaultValue(${expr})") |> Option.getWithDefault(""))

    ///
    /// SDL の型参照 → Flix の型。NonNull で無ければ Option に包む。
    ///
    def flixType(document: SdlDocument, ty: Ty): String = match ty {
        case Ty.NonNull(inner) => bareFlixType(document, inner)
        case _                 => "Option[${bareFlixType(document, ty)}]"
    }

    ///
    /// Option を付けない Flix の型。
    ///
    def bareFlixType(document: SdlDocument, ty: Ty): String = match ty {
        case Ty.Named(name)    => Map.get(name, scalarTypes()) |> Option.getWithDefault(name)
        case Ty.ListOf(inner)  => "List[${flixType(document, inner)}]"
        case Ty.NonNull(inner) => bareFlixType(document, inner)
    }

    ///
    /// 引数の Codec を作る式。オブジェクト型は引数にできない。
    ///
    def codecExpr(document: SdlDocument, ty: Ty): Result[String, String] = match ty {
        case Ty.NonNull(inner) => bareCodecExpr(document, inner)
        case _                 => bareCodecExpr(document, ty) |> Result.map(inner -> "GqlCodec.option(${inner})")
    }

    ///
    /// option を付けない Codec の式。
    ///
    def bareCodecExpr(document: SdlDocument, ty: Ty): Result[String, String] = match ty {
        case Ty.Named(name) =>
            if (Map.memberOf(name, scalarFns())) Ok("GqlCodec.${Map.getWithDefault(name, "", scalarFns())}()")
            else if (isEnum(document, name)) Ok("${codecFn(name)}()")
            else Err("オブジェクト型 ${name} は引数に使えません（input 型は未対応）")
        case Ty.ListOf(inner)  => codecExpr(document, inner) |> Result.map(c -> "GqlCodec.list(${c})")
        case Ty.NonNull(inner) => bareCodecExpr(document, inner)
    }

    ///
    /// 戻り値の Out を作る式。
    ///
    def outExpr(document: SdlDocument, ty: Ty): Result[String, String] = match ty {
        case Ty.NonNull(inner) => bareOutExpr(document, inner)
        case _                 => bareOutExpr(document, ty) |> Result.map(inner -> "Out.option(${inner})")
    }

    ///
    /// option を付けない Out の式。
    ///
    def bareOutExpr(document: SdlDocument, ty: Ty): Result[String, String] = match ty {
        case Ty.Named(name) =>
            if (Map.memberOf(name, scalarFns())) Ok("Out.${Map.getWithDefault(name, "", scalarFns())}()")
            else if (isEnum(document, name)) Ok("Out.scalar(${codecFn(name)}())")
            else if (Set.memberOf(name, document#objectNames)) Ok("Out.obj(${typeFn(name)}(resolvers))")
            else Err("型 ${name} が定義されていません")
        case Ty.ListOf(inner)  => outExpr(document, inner) |> Result.map(o -> "Out.list(${o})")
        case Ty.NonNull(inner) => bareOutExpr(document, inner)
    }

    ///
    /// name が enum か。
    ///
    def isEnum(document: SdlDocument, name: String): Bool =
        Set.memberOf(name, document#enumNames)

    ///
    /// name がルート型（Query / Mutation）か。
    ///
    def isRoot(document: SdlDocument, name: String): Bool =
        name == document#queryName or Some(name) == document#mutationName

    ///
    /// Resolvers レコードでのラベル。ルートは固定名（query が予約語のため）、他は先頭小文字。
    ///
    def typeLabel(document: SdlDocument, name: String): String =
        if (name == document#queryName) "queryRoot"
        else if (Some(name) == document#mutationName) "mutationRoot"
        else label(lowerFirst(name))

    ///
    /// ObjectType を作る関数の名前（Post → postType）。
    ///
    def typeFn(name: String): String = "${lowerFirst(name)}Type"

    ///
    /// enum の Codec を返す関数の名前（Color → colorCodec）。
    ///
    def codecFn(name: String): String = "${lowerFirst(name)}Codec"

    ///
    /// 予約語なら末尾に _ を付ける。
    ///
    def label(name: String): String =
        if (Set.memberOf(name, reservedWords())) "${name}_" else name

    ///
    /// SDL の enum 値 → Flix の case 名。_ で区切り、各区切りを先頭大文字・残り小文字にする。
    ///
    def caseName(value: String): String =
        String.splitOn(substr = "_", value) |> List.filter(part -> not String.isEmpty(part)) |> List.map(part -> upperFirst(String.toLowerCase(part))) |> List.join("")
            |> ensureIdentifier

    ///
    /// 先頭が数字なら _ を付ける（validateNames が拒否する印になる）。
    ///
    def ensureIdentifier(name: String): String =
        if (String.isEmpty(name) or (String.charAt(0, name) |> Char.isDigit)) "_${name}" else name

    ///
    /// 先頭を小文字に。
    ///
    def lowerFirst(name: String): String =
        String.toLowerCase(String.takeLeft(1, name)) + String.dropLeft(1, name)

    ///
    /// 先頭を大文字に。
    ///
    def upperFirst(name: String): String =
        String.toUpperCase(String.takeLeft(1, name)) + String.dropLeft(1, name)

    ///
    /// Flix の文字列リテラル。バックスラッシュ・引用符・改行・$ をエスケープする。
    ///
    pub def stringLiteral(text: String): String =
        let escaped = text
            |> String.replace(src = "\\", dst = "\\\\")
            |> String.replace(src = "\"", dst = "\\\"")
            |> String.replace(src = "\n", dst = "\\n")
            |> String.replace(src = "\r", dst = "\\r")
            |> String.replace(src = "$", dst = "\\$");
        "\"${escaped}\""

}
