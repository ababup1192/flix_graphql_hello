///
/// SdlDocument から GeneratedSchema.flix の本文を組み立てる。純粋な文字列生成。
///
mod Emit {

    ///
    /// 生成器のバージョン。生成物の形が変わる修正をしたら、本体の GeneratedCheck.expectedGeneratorVersion と一緒に上げる
    /// （本体が照合し、再生成が要求される）。
    ///
    pub def generatorVersion(): String = "6"

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
        "ObjectType", "Resolvers", "Runner", "Int32", "Float64", "String", "Bool", "IO", "Nil", "Some", "None", "Ok", "Err", "Set", "Eq", "Order", "ToString"
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
    /// 生成物の全文。sdl は生成元の本文で、そのまま生成物に埋めて本体が SDL ファイルと照合する。
    /// moduleName は生成物のモジュール名（"Generated" / "GeneratedAdmin"）。スキーマが複数あるときに分ける。
    ///
    pub def render(moduleName: String, document: SdlDocument, sdl: String): Result[String, String] =
        forM (
            _        <- validate(document);
            enums    <- Result.traverse(renderEnum, document#enums);
            inputs   <- Result.traverse(renderInput(document), document#inputs);
            unions   <- Result.traverse(renderUnion(document), document#unions);
            ifaces   <- Result.traverse(renderInterface(document), document#interfaces);
            objects  <- Result.traverse(renderObject(document), document#objects)
        ) yield {
            let inputSection = if (List.isEmpty(inputs)) Nil else (List.join("\n\n", inputs) + "\n") :: Nil;
            let abstractSection = if (List.isEmpty(unions) and List.isEmpty(ifaces)) Nil else (List.join("\n\n", unions ::: ifaces) + "\n") :: Nil;
            let fieldAliases = document#objects |> List.flatMap(object -> List.map(renderFieldAlias(document, object), object#fields));
            let resolverAliases = document#objects |> List.map(renderResolverAlias(document));
            let defaults = document#objects |> List.filterMap(renderDefaults(document));
            let defaultsSection = if (List.isEmpty(defaults)) Nil else (List.join("\n\n", defaults) + "\n") :: Nil;
            let allResolvers = document#objects |> List.map(object -> "        ${typeLabel(document, object#name)} = ${object#name}Resolvers[ef]") |> List.join(",\n");
            let mutationExpr = document#mutationName |> Option.map(name -> "Some(${typeFn(name)}(resolvers))") |> Option.getWithDefault("None");
            let enumSection = if (List.isEmpty(enums)) Nil else (List.join("\n\n", enums) + "\n") :: Nil;
            List.join("\n",
                "///" ::
                "/// SDL から schemagen が生成したファイル。手で編集しない（`make generate` で作り直す）。" ::
                "///" ::
                "mod ${moduleName} {" ::
                "" ::
                "    /// 生成元の SDL 本文（改行は LF）。GeneratedCheck が SDL ファイルと照合する" ::
                "    pub def sdlText(): String = ${stringLiteral(sdl)}" ::
                "" ::
                "    /// 生成した schemagen のバージョン" ::
                "    pub def generatorVersion(): String = \"${generatorVersion()}\"" ::
                "" ::
                enumSection :::
                inputSection :::
                abstractSection :::
                List.join("\n", fieldAliases) ::
                "" ::
                List.join("\n\n", resolverAliases) ::
                "" ::
                defaultsSection :::
                "    /// 全型のリゾルバ。1 つでも欠けるとコンパイルエラー。ef は全リゾルバで共有する 1 つの効果" ::
                "    pub type alias Resolvers[ef: Eff] = {\n${allResolvers}\n    }" ::
                "" ::
                "    /// リゾルバ一式からスキーマを組み立てる。runner が ef を IO に落とす" ::
                "    pub def schema(resolvers: Resolvers[ef], runner: Runner[ef]): Schema =" ::
                "        Schema.make(${typeFn(document#queryName)}(resolvers), ${mutationExpr}, runner)" ::
                "" ::
                List.join("\n\n", objects) ::
                "" ::
                "}" ::
                Nil)
        }

    ///
    /// 生成できる SDL か確かめる。render と scaffold の両方が先に呼ぶ。
    ///
    pub def validate(document: SdlDocument): Result[String, Unit] =
        forM (
            _ <- validateNames(document);
            _ <- validateInputs(document);
            _ <- validateAbstract(document);
            _ <- validateReachable(document)
        ) yield ()

    ///
    /// 型名の禁止名・重複・大小文字・生成する別名との衝突、フィールド名と引数名の大小文字、enum 値の変換衝突、ルート型の存在を確かめる。
    ///
    def validateNames(document: SdlDocument): Result[String, Unit] =
        let typeNames = List.map(object -> object#name, document#objects) ::: List.map(enumDef -> enumDef#name, document#enums) ::: List.map(inputDef -> inputDef#name, document#inputs)
            ::: List.map(unionDef -> unionDef#name, document#unions) ::: List.map(ifaceDef -> ifaceDef#name, document#interfaces);
        let forbidden = typeNames |> List.filter(name -> Set.memberOf(name, forbiddenTypeNames()));
        let duplicated = duplicates(typeNames);
        let generatedNames = document#objects |> List.flatMap(object -> "${object#name}Resolvers" :: List.map(field -> fieldAliasName(object#name, field#name), object#fields));
        let clashes = typeNames |> List.filter(name -> List.memberOf(name, generatedNames));
        let duplicatedAliases = duplicates(generatedNames);
        let resolversFields = document#objects |> List.filter(object -> List.exists(field -> field#name == "resolvers", object#fields)) |> List.map(object -> object#name);
        let lowerTypes = typeNames |> List.filter(name -> not startsUpper(name));
        let upperFields = document#objects |> List.flatMap(object -> object#fields |> List.flatMap(field ->
            (if (startsUpper(field#name)) "${object#name}.${field#name}" :: Nil else Nil)
            ::: (field#args |> List.filter(arg -> startsUpper(arg#name)) |> List.map(arg -> "${object#name}.${field#name}(${arg#name})"))))
            ::: (document#inputs |> List.flatMap(inputDef -> inputDef#fields |> List.filter(field -> startsUpper(field#name)) |> List.map(field -> "${inputDef#name}.${field#name}")))
            ::: (document#interfaces |> List.flatMap(ifaceDef -> ifaceDef#fields |> List.filter(field -> startsUpper(field#name)) |> List.map(field -> "${ifaceDef#name}.${field#name}")));
        let hasQuery = List.exists(object -> object#name == document#queryName, document#objects);
        let hasMutation = document#mutationName |> Option.map(name -> List.exists(object -> object#name == name, document#objects)) |> Option.getWithDefault(true);
        let enumProblems = document#enums |> List.filterMap(enumDef -> {
            let cases = List.map(value -> caseName(value#name), enumDef#values);
            let collisions = duplicates(cases);
            let badStart = enumDef#values |> List.map(value -> value#name) |> List.filter(value -> caseName(value) |> String.startsWith(prefix = "_"));
            if (not List.isEmpty(collisions)) Some("enum ${enumDef#name} の値が Flix の名前に変換すると衝突します")
            else if (not List.isEmpty(badStart)) Some("enum ${enumDef#name} の値 ${List.join(", ", badStart)} は Flix の名前にできません")
            else None
        });
        if (not List.isEmpty(forbidden)) Err("型名 ${List.join(", ", forbidden)} は生成物の名前と衝突するので使えません")
        else if (not List.isEmpty(duplicated)) Err("型 ${List.join(", ", duplicated)} が 2 回定義されています")
        else if (not List.isEmpty(clashes)) Err("型名 ${List.join(", ", clashes)} は生成する別名と衝突するので使えません")
        else if (not List.isEmpty(duplicatedAliases)) Err("生成する別名 ${List.join(", ", duplicatedAliases)} が重複します（型名とフィールド名の組み合わせを変えてください）")
        else if (not List.isEmpty(resolversFields)) Err("型 ${List.join(", ", resolversFields)} のフィールド名 resolvers は雛形の関数名と衝突するので使えません")
        else if (not List.isEmpty(lowerTypes)) Err("型名 ${List.join(", ", lowerTypes)} は大文字で始めてください（Flix の型名の決まり）")
        else if (not List.isEmpty(upperFields)) Err("フィールド名・引数名 ${List.join(", ", upperFields)} は小文字で始めてください（Flix のラベルの決まり）")
        else if (not hasQuery) Err("ルート型 ${document#queryName} がありません")
        else if (not hasMutation) Err("ルート型 ${document#mutationName |> Option.getWithDefault("")} がありません")
        else match enumProblems {
            case Nil          => Ok(())
            case message :: _ => Err(message)
        }

    ///
    /// input 型の中身を確かめる。フィールドが無い、オブジェクト型を参照している、input 同士が循環している、のどれかで Err。
    ///
    /// WhyNot: input の循環参照（nullable を挟めば GraphQL では合法）を許さないのは、Flix のレコード型の別名が
    /// 再帰できず、生成物の `pub type alias PostInput = { … }` が書けないため。
    ///
    def validateInputs(document: SdlDocument): Result[String, Unit] =
        let empty = document#inputs |> List.filter(inputDef -> List.isEmpty(inputDef#fields)) |> List.map(inputDef -> inputDef#name);
        let duplicatedFields = document#inputs |> List.flatMap(inputDef -> duplicates(List.map(field -> field#name, inputDef#fields)) |> List.map(field -> "${inputDef#name}.${field}"));
        let objectRefs = document#inputs |> List.flatMap(inputDef -> inputDef#fields
            |> List.filter(field -> Set.memberOf(baseName(field#ty), document#objectNames))
            |> List.map(field -> "${inputDef#name}.${field#name}"));
        let cyclic = document#inputs |> List.filter(inputDef -> reachesInput(document, inputDef#name, inputDef#name :: Nil, Set.empty())) |> List.map(inputDef -> inputDef#name);
        if (not List.isEmpty(empty)) Err("input ${List.join(", ", empty)} にフィールドがありません")
        else if (not List.isEmpty(duplicatedFields)) Err("input 型のフィールド ${List.join(", ", duplicatedFields)} が 2 回定義されています")
        else if (not List.isEmpty(objectRefs)) Err("input 型のフィールド ${List.join(", ", objectRefs)} にオブジェクト型は使えません（input 型か、スカラー・enum にしてください）")
        else if (not List.isEmpty(cyclic)) Err("input 型 ${List.join(", ", cyclic)} が循環しています（Flix のレコード型の別名は再帰できません）")
        else Ok(())

    ///
    /// union / interface を確かめる。union の枝はオブジェクト型で重複なし、interface は実装型が 1 つ以上あって
    /// 各実装型が interface の全フィールドを同じ型・同じ引数で持ち、どちらもどこかのフィールドの型に使われていること。
    ///
    /// WhyNot: フィールドの型に使われない interface を許さないのは、interface の宣言をそれを返すフィールドから
    /// 辿って SDL に出しているため（implements だけでは宣言が出ず、graphql-java が未定義で止まる）。
    ///
    def validateAbstract(document: SdlDocument): Result[String, Unit] =
        let badMembers = document#unions |> List.flatMap(unionDef -> unionDef#members |> List.filter(member -> not Set.memberOf(member, document#objectNames)) |> List.map(member -> "${unionDef#name} の ${member}"));
        let duplicatedMembers = document#unions |> List.flatMap(unionDef -> duplicates(unionDef#members) |> List.map(member -> "${unionDef#name} の ${member}"));
        let emptyUnions = document#unions |> List.filter(unionDef -> List.isEmpty(unionDef#members)) |> List.map(unionDef -> unionDef#name);
        let unknownInterfaces = document#objects |> List.flatMap(object -> object#interfaces |> List.filter(name -> not Set.memberOf(name, document#interfaceNames)) |> List.map(name -> "${object#name} の ${name}"));
        let noImplementors = document#interfaces |> List.filter(ifaceDef -> List.isEmpty(implementors(document, ifaceDef#name))) |> List.map(ifaceDef -> ifaceDef#name);
        let missingFields = document#interfaces |> List.flatMap(ifaceDef -> implementors(document, ifaceDef#name) |> List.flatMap(object ->
            ifaceDef#fields |> List.filter(field -> not List.exists(own -> sameShape(own, field), object#fields)) |> List.map(field -> "${object#name} に ${ifaceDef#name}.${field#name} が無いか型が違います")));
        let usedAsField = document#objects |> List.flatMap(object -> object#fields |> List.map(field -> baseName(field#ty)))
            ::: document#interfaces |> List.flatMap(ifaceDef -> ifaceDef#fields |> List.map(field -> baseName(field#ty)));
        let unused = (List.map(unionDef -> unionDef#name, document#unions) ::: List.map(ifaceDef -> ifaceDef#name, document#interfaces)) |> List.filter(name -> not List.memberOf(name, usedAsField));
        if (not List.isEmpty(badMembers)) Err("union の枝 ${List.join(", ", badMembers)} はオブジェクト型ではありません")
        else if (not List.isEmpty(duplicatedMembers)) Err("union の枝 ${List.join(", ", duplicatedMembers)} が重複しています")
        else if (not List.isEmpty(emptyUnions)) Err("union ${List.join(", ", emptyUnions)} に枝がありません")
        else if (not List.isEmpty(unknownInterfaces)) Err("implements ${List.join(", ", unknownInterfaces)} は interface ではありません")
        else if (not List.isEmpty(noImplementors)) Err("interface ${List.join(", ", noImplementors)} を implements する型がありません")
        else if (not List.isEmpty(missingFields)) Err(List.join("、", missingFields))
        else if (not List.isEmpty(unused)) Err("union / interface ${List.join(", ", unused)} はどのフィールドの型にも使われていません（実装型からは辿れないので、SDL に出せません）")
        else Ok(())

    ///
    /// name を implements するオブジェクト型（SDL の順）。
    ///
    def implementors(document: SdlDocument, name: String): List[ObjectDef] =
        document#objects |> List.filter(object -> List.memberOf(name, object#interfaces))

    ///
    /// 名前・型・引数（名前と型）が同じか。description や既定値の違いは問わない。
    ///
    def sameShape(own: FieldDef, required: FieldDef): Bool =
        own#name == required#name and own#ty == required#ty
            and List.map(arg -> (arg#name, arg#ty), own#args) == List.map(arg -> (arg#name, arg#ty), required#args)

    ///
    /// pending の input 型から辿って target に戻れるか（input 同士の循環の検出）。
    ///
    def reachesInput(document: SdlDocument, target: String, pending: List[String], seen: Set[String]): Bool = match pending {
        case Nil => false
        case name :: rest =>
            let referenced = document#inputs |> List.find(inputDef -> inputDef#name == name)
                |> Option.map(inputDef -> inputDef#fields |> List.map(field -> baseName(field#ty)) |> List.filter(referencedName -> Set.memberOf(referencedName, document#inputNames)))
                |> Option.getWithDefault(Nil);
            if (List.memberOf(target, referenced)) true
            else reachesInput(document, target, List.filter(referencedName -> not Set.memberOf(referencedName, seen), referenced) ::: rest, Set.insert(name, seen))
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
        let all = List.map(object -> object#name, document#objects) ::: List.map(enumDef -> enumDef#name, document#enums) ::: List.map(inputDef -> inputDef#name, document#inputs)
            ::: List.map(unionDef -> unionDef#name, document#unions) ::: List.map(ifaceDef -> ifaceDef#name, document#interfaces);
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
                let fromObject = document#objects |> List.find(object -> object#name == name) |> Option.map(object ->
                    object#fields |> List.flatMap(field -> baseName(field#ty) :: List.map(arg -> baseName(arg#ty), field#args))) |> Option.getWithDefault(Nil);
                let fromInput = document#inputs |> List.find(inputDef -> inputDef#name == name) |> Option.map(inputDef ->
                    List.map(field -> baseName(field#ty), inputDef#fields)) |> Option.getWithDefault(Nil);
                let fromUnion = document#unions |> List.find(unionDef -> unionDef#name == name) |> Option.map(unionDef -> unionDef#members) |> Option.getWithDefault(Nil);
                let fromInterface = document#interfaces |> List.find(ifaceDef -> ifaceDef#name == name) |> Option.map(ifaceDef ->
                    List.map(field -> baseName(field#ty), ifaceDef#fields) ::: List.map(object -> object#name, implementors(document, name))) |> Option.getWithDefault(Nil);
                reach(document, fromObject ::: fromInput ::: fromUnion ::: fromInterface ::: rest, Set.insert(name, seen))
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
    /// enum 型と、その Codec を返す関数。case の doc コメントは SDL の description（無ければ SDL 名）。
    ///
    def renderEnum(enumDef: EnumDef): Result[String, String] =
        match enumDef#values {
            case Nil => Err("enum ${enumDef#name} に値がありません")
            case _   => {
                let cases = enumDef#values |> List.map(value -> "${docLines("        ", Option.getWithDefault(value#name, value#description))}\n        case ${caseName(value#name)}") |> List.join("\n");
                let arms = enumDef#values |> List.map(value -> "case ${enumDef#name}.${caseName(value#name)} => ${stringLiteral(value#name)}") |> List.join(" ");
                let values = enumDef#values |> List.map(value -> "${enumDef#name}.${caseName(value#name)}") |> List.join(" :: ");
                let typeDoc = enumDef#description |> Option.map(text -> "。${text}") |> Option.getWithDefault("");
                let decorations = typeDescriptionDecoration(enumDef#description) :: List.map(enumValueDecorations(enumDef#name), enumDef#values);
                Ok(List.join("\n",
                    docLines("    ", "enum ${enumDef#name}${typeDoc}") ::
                    "    pub enum ${enumDef#name} with Eq, Order, ToString {" ::
                    cases ::
                    "    }" ::
                    "" ::
                    "    /// ${enumDef#name} の Codec" ::
                    "    pub def ${codecFn(enumDef#name)}(): GqlCodec[${enumDef#name}] =" ::
                    "        GqlCodec.enumOf(${stringLiteral(enumDef#name)}, value -> match value { ${arms} }, ${values} :: Nil)${List.join("", decorations)}" ::
                    Nil))
            }
        }

    ///
    /// 本文を doc コメント（///）にする。行ごとに /// を付ける。
    ///
    /// WhyNot: 1 行にまとめないのは、SDL のブロック文字列の description が改行を含み、
    /// そのまま /// の後ろに置くと 2 行目が裸のコードになって生成物がパースエラーになるため。
    ///
    def docLines(indent: String, text: String): String =
        String.splitOn(substr = "\n", text) |> List.map(line -> "${indent}/// ${line}") |> List.join("\n")

    ///
    /// enum / input 型の description の後付け（GqlCodec.describe）。
    ///
    def typeDescriptionDecoration(description: Option[String]): String =
        description |> Option.map(text -> " |> GqlCodec.describe(${stringLiteral(text)})") |> Option.getWithDefault("")

    ///
    /// enum 値の description / @deprecated の後付け。
    ///
    def enumValueDecorations(enumName: String, value: EnumValueDef): String =
        let flixValue = "${enumName}.${caseName(value#name)}";
        (value#description |> Option.map(text -> " |> GqlCodec.describeValue(${flixValue}, ${stringLiteral(text)})") |> Option.getWithDefault(""))
        + (value#deprecated |> Option.map(deprecation -> match deprecation {
            case Deprecation.Reason(text) => " |> GqlCodec.deprecateValue(${flixValue}, Deprecation.Reason(${stringLiteral(text)}))"
            case Deprecation.NoReason     => " |> GqlCodec.deprecateValue(${flixValue}, Deprecation.NoReason)"
        }) |> Option.getWithDefault(""))

    ///
    /// input X のレコード型の別名と、その Codec。Codec は各フィールドを引数と同じ Arg で組み、Map からレコードに組み立てる。
    ///
    def renderInput(document: SdlDocument, inputDef: InputDef): Result[String, String] =
        let indexed = List.zip(List.range(0, List.length(inputDef#fields)), inputDef#fields);
        Result.traverse(match (index, field) -> codecExpr(document, field#ty) |> Result.map(codec -> "        let f${index} = Schema.arg(${stringLiteral(field#name)}, ${codec})${argDecorations(field)};"), indexed)
            |> Result.map(fieldLets -> {
                let labels = inputDef#fields |> List.map(field -> "${label(field#name)} = ${flixType(document, field#ty)}") |> List.join(", ");
                let infos = (indexed |> List.map(match (index, _) -> "Arg.info(f${index}) :: ") |> List.join("")) + "Nil";
                let decodes = indexed |> List.map(match (index, _) -> "v${index} <- Arg.decodeField(f${index}, fields)") |> List.join("; ");
                let record = indexed |> List.map(match (index, field) -> "${label(field#name)} = v${index}") |> List.join(", ");
                List.join("\n",
                    "    /// input ${inputDef#name}" ::
                    "    pub type alias ${inputDef#name} = { ${labels} }" ::
                    "" ::
                    "    /// ${inputDef#name} の Codec" ::
                    "    pub def ${codecFn(inputDef#name)}(): GqlCodec[${inputDef#name}] =" ::
                    fieldLets :::
                    "        GqlCodec.inputObject(${stringLiteral(inputDef#name)}, ${infos}, fields ->" ::
                    "            forM (${decodes}) yield { ${record} })${typeDescriptionDecoration(inputDef#description)}" ::
                    Nil)
            })

    ///
    /// union X の Flix の enum（枝ごとに case）と、その Out を作る関数。
    ///
    def renderUnion(document: SdlDocument, unionDef: UnionDef): Result[String, String] =
        Ok(renderAbstract(document, "union", unionDef#name, unionDef#description, unionDef#members,
            "Out.union(${stringLiteral(unionDef#name)}, ${memberList(unionDef#members)}, ${encodeLambda(unionDef#name, unionDef#members)})"))

    ///
    /// interface X の Flix の enum（実装型ごとに case）と、その Out を作る関数。フィールドは SDL の形だけを渡す。
    ///
    def renderInterface(document: SdlDocument, ifaceDef: InterfaceDef): Result[String, String] =
        let members = implementors(document, ifaceDef#name) |> List.map(object -> object#name);
        Result.traverse(renderAbstractField(document), ifaceDef#fields) |> Result.map(fields ->
            renderAbstract(document, "interface", ifaceDef#name, ifaceDef#description, members,
                "Out.interface(${stringLiteral(ifaceDef#name)},\n${fields |> List.map(field -> "${field} ::") |> List.join("\n")}\n            Nil, ${memberList(members)}, ${encodeLambda(ifaceDef#name, members)})"))

    ///
    /// union / interface に共通の enum と Out 関数。
    ///
    def renderAbstract(_document: SdlDocument, kind: String, name: String, description: Option[String], members: List[String], outExpr: String): String =
        let cases = members |> List.map(member -> "        /// ${member}\n        case ${member}(${member})") |> List.join("\n");
        let typeDoc = description |> Option.map(text -> "。${text}") |> Option.getWithDefault("");
        List.join("\n",
            docLines("    ", "${kind} ${name}${typeDoc}。人はこの enum に包んで返す") ::
            "    pub enum ${name} {" ::
            cases ::
            "    }" ::
            "" ::
            "    /// ${kind} ${name} の Out" ::
            "    def ${outFn(name)}(resolvers: Resolvers[ef]): Out[${name}, ef] =" ::
            "        ${outExpr}${description |> Option.map(text -> " |> Out.describe(${stringLiteral(text)})") |> Option.getWithDefault("")}" ::
            Nil)

    ///
    /// Out.member(xType(resolvers)) :: ... :: Nil
    ///
    def memberList(members: List[String]): String =
        (members |> List.map(member -> "Out.member(${typeFn(member)}(resolvers)) :: ") |> List.join("")) + "Nil"

    ///
    /// enum の値を枝の型で箱詰めするラムダ。
    ///
    def encodeLambda(name: String, members: List[String]): String =
        let arms = members |> List.map(member -> "case ${name}.${member}(x) => Out.taggedObj(${typeFn(member)}(resolvers), context, x)") |> List.join(" ");
        "(context, value) -> match value { ${arms} }"

    ///
    /// interface のフィールド 1 つ分の Schema.abstractField。
    ///
    def renderAbstractField(document: SdlDocument, field: FieldDef): Result[String, String] =
        let indexed = List.zip(List.range(0, List.length(field#args)), field#args);
        forM (
            argLets <- Result.traverse(match (index, arg) -> codecExpr(document, arg#ty) |> Result.map(codec -> "                let arg${index} = Schema.arg(${stringLiteral(arg#name)}, ${codec})${argDecorations(arg)};"), indexed);
            out     <- outExpr(document, field#ty)
        ) yield {
            let infos = (indexed |> List.map(match (index, _) -> "Arg.info(arg${index}) :: ") |> List.join("")) + "Nil";
            List.join("\n",
                "            {" ::
                argLets :::
                "                Schema.abstractField(${stringLiteral(field#name)}, ${infos}, ${out})${fieldDecorations(field)}" ::
                "            }" ::
                Nil)
        }

    ///
    /// フィールド 1 つのリゾルバの関数型（X.field → XFieldResolver）。利用側がフィールド単位の関数に注釈するための別名。
    ///
    def renderFieldAlias(document: SdlDocument, object: ObjectDef, field: FieldDef): String =
        let source = if (isRoot(document, object#name)) Nil else object#name :: Nil;
        let argTypes = List.map(arg -> flixType(document, arg#ty), field#args);
        let params = ("Context" :: source ::: argTypes) |> List.join(" -> ");
        "    /// ${object#name}.${field#name}\n    pub type alias ${fieldAliasName(object#name, field#name)}[ef: Eff] = ${params} -> Result[FieldError, ${flixType(document, field#ty)}] \\ ef"

    ///
    /// type X のリゾルバ一式のレコード型。
    ///
    def renderResolverAlias(document: SdlDocument, object: ObjectDef): String =
        let fields = object#fields |> List.map(field -> "        ${label(field#name)} = ${fieldAliasName(object#name, field#name)}[ef]") |> List.join(",\n");
        let sourceNote = if (isRoot(document, object#name)) "" else "。第 2 引数が source";
        "    /// type ${object#name} のリゾルバ一式${sourceNote}。ef はリゾルバの効果\n    pub type alias ${object#name}Resolvers[ef: Eff] = {\n${fields}\n    }"

    ///
    /// type X の既定リゾルバ。source の同名ラベルをそのまま返す素通しのフィールド（引数が無く、スカラーか enum か
    /// そのリストを返す物）だけを持つ。ルート型と、素通しのフィールドが無い型は None。
    ///
    /// WhyNot: source の型を X と書かず行変数で開けておくのは、X が SDL に無いラベル（authorId など）を
    /// 持てるようにするため。XResolvers[ef] と合わせた時に行変数が残りのラベルに決まる。
    ///
    def renderDefaults(document: SdlDocument, object: ObjectDef): Option[String] =
        let passthrough = List.filter(isPassthrough(document), object#fields);
        if (isRoot(document, object#name) or List.isEmpty(passthrough)) None
        else {
            let indexed = List.zip(List.range(0, List.length(passthrough)), passthrough);
            let types = indexed |> List.map(match (index, field) -> {
                let ty = flixType(document, field#ty);
                "        ${label(field#name)} = Context -> { ${label(field#name)} = ${ty} | r${index} } -> Result[FieldError, ${ty}] \\ ef"
            }) |> List.join(",\n");
            let values = passthrough |> List.map(field -> "        ${label(field#name)} = (_context, src) -> Ok(src#${label(field#name)})") |> List.join(",\n");
            let skipped = object#fields |> List.filter(field -> not isPassthrough(document, field)) |> List.map(field -> field#name);
            let note = if (List.isEmpty(skipped)) "" else "。${List.join(", ", skipped)} は含まない（オブジェクト型を返すか、引数を持つ）";
            Some("    /// type ${object#name} の既定リゾルバ。source の同名ラベルをそのまま返す${note}\n    pub def ${defaultsFn(object#name)}(): {\n${types}\n    } = {\n${values}\n    }")
        }

    ///
    /// 素通しにできるフィールドか（引数が無く、スカラーか enum かそのリストを返す）。
    ///
    pub def isPassthrough(document: SdlDocument, field: FieldDef): Bool =
        List.isEmpty(field#args) and not Set.memberOf(baseName(field#ty), document#objectNames) and not isAbstract(document, baseName(field#ty))

    ///
    /// name が union か interface か。
    ///
    def isAbstract(document: SdlDocument, name: String): Bool =
        Set.memberOf(name, document#unionNames) or Set.memberOf(name, document#interfaceNames)

    ///
    /// type X の ObjectType を作る関数。
    ///
    def renderObject(document: SdlDocument, object: ObjectDef): Result[String, String] =
        let sourceType = if (isRoot(document, object#name)) "Unit" else object#name;
        Result.traverse(renderField(document, object), object#fields) |> Result.map(fields ->
            List.join("\n",
                "    /// type ${object#name}" ::
                "    def ${typeFn(object#name)}(resolvers: Resolvers[ef]): ObjectType[${sourceType}, ef] =" ::
                "        Schema.objectType(${stringLiteral(object#name)}, () ->" ::
                (fields |> List.map(field -> "${field} ::") |> List.join("\n")) ::
                "            Nil)${object#description |> Option.map(text -> " |> ObjectType.withDescription(${stringLiteral(text)})") |> Option.getWithDefault("")}${implementsDecoration(object)}" ::
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
    /// implements の後付け（ObjectType.implementing）。
    ///
    def implementsDecoration(object: ObjectDef): String =
        if (List.isEmpty(object#interfaces)) ""
        else " |> ObjectType.implementing(" + (object#interfaces |> List.map(name -> "${stringLiteral(name)} :: ") |> List.join("")) + "Nil)"

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
    /// 引数（と input のフィールド）の Codec を作る式。オブジェクト型は引数にできない。
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
            else if (isEnum(document, name) or Set.memberOf(name, document#inputNames)) Ok("${codecFn(name)}()")
            else if (Set.memberOf(name, document#objectNames)) Err("オブジェクト型 ${name} は引数に使えません（input 型にしてください）")
            else if (isAbstract(document, name)) Err("union / interface 型 ${name} は引数に使えません")
            else Err("型 ${name} が定義されていません")
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
            else if (isAbstract(document, name)) Ok("${outFn(name)}(resolvers)")
            else if (Set.memberOf(name, document#inputNames)) Err("input 型 ${name} は戻り値に使えません")
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
    pub def isRoot(document: SdlDocument, name: String): Bool =
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
    /// union / interface の Out を返す関数の名前（SearchResult → searchResultOut）。
    ///
    def outFn(name: String): String = "${lowerFirst(name)}Out"

    ///
    /// 既定リゾルバを返す関数の名前（Post → postDefaults）。
    ///
    pub def defaultsFn(name: String): String = "${lowerFirst(name)}Defaults"

    ///
    /// フィールド 1 つのリゾルバの型別名の名前（Post.author → PostAuthorResolver）。
    ///
    /// WhyNot: 末尾に Resolver を付けるのは、Post.status → PostStatus のように型名とフィールド名を
    /// つなぐだけだと enum PostStatus と衝突するため。
    ///
    pub def fieldAliasName(objectName: String, fieldName: String): String = "${objectName}${upperFirst(fieldName)}Resolver"

    ///
    /// enum / input の Codec を返す関数の名前（Color → colorCodec）。
    ///
    def codecFn(name: String): String = "${lowerFirst(name)}Codec"

    ///
    /// 予約語なら末尾に _ を付ける。
    ///
    pub def label(name: String): String =
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
