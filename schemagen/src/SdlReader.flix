///
/// graphql-java のパーサで SDL を読み、SdlDocument に落とす。Java の AST はここから外に出さない。
///
/// WhyNot: SchemaParser → TypeDefinitionRegistry を使わないのは、getType の戻りが
/// Optional<TypeDefinition<?>> で Flix から型を決めにくいため。Document.getDefinitions() は
/// 具象の List で受けられる。
///
mod SdlReader {
    import graphql.language.Argument
    import graphql.language.ArrayValue
    import graphql.language.BooleanValue
    import graphql.language.Definition
    import graphql.language.Description
    import graphql.language.Directive
    import graphql.language.Document
    import graphql.language.EnumTypeDefinition
    import graphql.language.EnumValue
    import graphql.language.EnumValueDefinition
    import graphql.language.FieldDefinition
    import graphql.language.FloatValue
    import graphql.language.InputObjectTypeDefinition
    import graphql.language.InputValueDefinition
    import graphql.language.InterfaceTypeDefinition
    import graphql.language.UnionTypeDefinition
    import graphql.language.IntValue
    import graphql.language.ListType
    import graphql.language.NonNullType
    import graphql.language.ObjectTypeDefinition
    import graphql.language.OperationTypeDefinition
    import graphql.language.SchemaDefinition
    import graphql.language.StringValue
    import graphql.language.Type
    import graphql.language.TypeName
    import graphql.language.{Value => AstValue}
    import graphql.parser.InvalidSyntaxException
    import graphql.parser.Parser
    import java.lang.Class
    import java.lang.Object
    import java.util.{List => JList}
    import java.util.Objects

    ///
    /// SDL 文字列を読む。対応していない定義（scalar / directive / subscription / extend）や、
    /// 型・input に付いた directive、enum 値の @deprecated 以外の directive があれば Err。
    ///
    pub def read(sdl: String): Result[String, SdlDocument] \ IO =
        try {
            let document = Parser.parse(sdl);
            let definitions: List[Definition[Object]] = Adaptor.fromList(document.getDefinitions());
            let objects = definitions |> List.filter(isA("graphql.language.ObjectTypeDefinition")) |> List.map(readObject) |> Result.sequence;
            let enums = definitions |> List.filter(isA("graphql.language.EnumTypeDefinition")) |> List.map(readEnum) |> Result.sequence;
            let inputs = definitions |> List.filter(isA("graphql.language.InputObjectTypeDefinition")) |> List.map(readInput) |> Result.sequence;
            let unions = definitions |> List.filter(isA("graphql.language.UnionTypeDefinition")) |> List.map(readUnion) |> Result.sequence;
            let interfaces = definitions |> List.filter(isA("graphql.language.InterfaceTypeDefinition")) |> List.map(readInterface) |> Result.sequence;
            let roots = readRoots(definitions);
            let extensions = definitions |> List.filter(isExtension) |> List.map(unsupported) |> firstErr;
            let others = definitions |> List.filter(definition -> not (isA("graphql.language.ObjectTypeDefinition", definition) or isA("graphql.language.EnumTypeDefinition", definition) or isA("graphql.language.InputObjectTypeDefinition", definition) or isA("graphql.language.UnionTypeDefinition", definition) or isA("graphql.language.InterfaceTypeDefinition", definition) or isA("graphql.language.SchemaDefinition", definition))) |> List.map(unsupported) |> firstErr;
            forM (
                _          <- extensions;
                _          <- others;
                objectDefs <- objects;
                enumDefs   <- enums;
                inputDefs  <- inputs;
                unionDefs  <- unions;
                ifaceDefs  <- interfaces;
                rootNames  <- roots
            ) yield {
                objects = objectDefs, enums = enumDefs, inputs = inputDefs, unions = unionDefs, interfaces = ifaceDefs,
                objectNames = objectDefs |> List.map(object -> object#name) |> List.toSet,
                enumNames = enumDefs |> List.map(enumDef -> enumDef#name) |> List.toSet,
                inputNames = inputDefs |> List.map(inputDef -> inputDef#name) |> List.toSet,
                unionNames = unionDefs |> List.map(unionDef -> unionDef#name) |> List.toSet,
                interfaceNames = ifaceDefs |> List.map(ifaceDef -> ifaceDef#name) |> List.toSet,
                queryName = fst(rootNames), mutationName = snd(rootNames)
            }
        } catch {
            case e: InvalidSyntaxException => Err("SDL を読めません: ${e.getMessage()}")
        }

    ///
    /// Err の一覧なら先頭の Err、無ければ Ok。
    ///
    def firstErr(errors: List[String]): Result[String, Unit] = match errors {
        case Nil            => Ok(())
        case message :: _   => Err(message)
    }

    ///
    /// 対応していない定義のエラー文。
    ///
    def unsupported(definition: Definition[Object]): String \ IO =
        "対応していない定義です: ${definition.getClass().getSimpleName()}"

    ///
    /// extend type / extend enum / extend schema か。
    ///
    /// WhyNot: 他の未対応と同じ経路で弾かないのは、extension が graphql-java では元の定義クラスの
    /// サブクラスで、放っておくと「2 回定義」という原因の読めないエラーになるか黙って読まれるため。先に名指しで弾く。
    ///
    def isExtension(definition: Definition[Object]): Bool \ IO =
        isA("graphql.language.ObjectTypeExtensionDefinition", definition)
            or isA("graphql.language.EnumTypeExtensionDefinition", definition)
            or isA("graphql.language.InputObjectTypeExtensionDefinition", definition)
            or isA("graphql.language.UnionTypeExtensionDefinition", definition)
            or isA("graphql.language.InterfaceTypeExtensionDefinition", definition)
            or isA("graphql.language.SchemaExtensionDefinition", definition)

    ///
    /// schema { query: X mutation: Y } を読む。無ければ Query と、定義されていれば Mutation。
    /// type Subscription があれば、届かない型として落ちる前に「未対応」と伝える。
    ///
    def readRoots(definitions: List[Definition[Object]]): Result[String, (String, Option[String])] \ IO =
        match List.find(isA("graphql.language.SchemaDefinition"), definitions) {
            case None =>
                let hasType = name -> definitions |> List.exists(definition ->
                    isA("graphql.language.ObjectTypeDefinition", definition) and (unchecked_cast(definition as ObjectTypeDefinition)).getName() == name);
                if (hasType("Subscription")) Err("subscription は未対応です")
                else Ok(("Query", if (hasType("Mutation")) Some("Mutation") else None))
            case Some(definition) =>
                let schemaDefinition = unchecked_cast(definition as SchemaDefinition);
                let operations: List[OperationTypeDefinition] = Adaptor.fromList(schemaDefinition.getOperationTypeDefinitions());
                let named = operation -> operations |> List.find(op -> op.getName() == operation) |> Option.map(op -> op.getTypeName().getName());
                match (named("query"), named("subscription")) {
                    case (None, _)          => Err("schema ブロックに query がありません")
                    case (_, Some(_))       => Err("subscription は未対応です")
                    case (Some(name), None) => Ok((name, named("mutation")))
                }
        }

    ///
    /// type Name { ... } を読む。
    ///
    def readObject(definition: Definition[Object]): Result[String, ObjectDef] \ IO =
        let objectDefinition = unchecked_cast(definition as ObjectTypeDefinition);
        let fields: List[FieldDefinition] = Adaptor.fromList(objectDefinition.getFieldDefinitions());
        let directives: List[Directive] = Adaptor.fromList(objectDefinition.getDirectives());
        let name = objectDefinition.getName();
        let description = descriptionOf(objectDefinition.getDescription());
        let implements: List[Type[Object]] = Adaptor.fromList(objectDefinition.getImplements());
        let fieldDefs = fields |> List.map(readField) |> Result.sequence;
        forM (
            _          <- noDirectives(directives);
            interfaces <- implements |> List.map(readNamedType) |> Result.sequence;
            fields_    <- fieldDefs
        ) yield { name = name, description = description, interfaces = interfaces, fields = fields_ }

    ///
    /// union Name = A | B を読む。
    ///
    def readUnion(definition: Definition[Object]): Result[String, UnionDef] \ IO =
        let unionDefinition = unchecked_cast(definition as UnionTypeDefinition);
        let memberTypes: List[Type[Object]] = Adaptor.fromList(unionDefinition.getMemberTypes());
        let directives: List[Directive] = Adaptor.fromList(unionDefinition.getDirectives());
        let name = unionDefinition.getName();
        let description = descriptionOf(unionDefinition.getDescription());
        forM (
            _       <- noDirectives(directives);
            members <- memberTypes |> List.map(readNamedType) |> Result.sequence
        ) yield { name = name, description = description, members = members }

    ///
    /// interface Name { ... } を読む。interface が interface を implements するのは未対応。
    ///
    def readInterface(definition: Definition[Object]): Result[String, InterfaceDef] \ IO =
        let interfaceDefinition = unchecked_cast(definition as InterfaceTypeDefinition);
        let fields: List[FieldDefinition] = Adaptor.fromList(interfaceDefinition.getFieldDefinitions());
        let directives: List[Directive] = Adaptor.fromList(interfaceDefinition.getDirectives());
        let implements: List[Type[Object]] = Adaptor.fromList(interfaceDefinition.getImplements());
        let name = interfaceDefinition.getName();
        let description = descriptionOf(interfaceDefinition.getDescription());
        let fieldDefs = fields |> List.map(readField) |> Result.sequence;
        forM (
            _       <- noDirectives(directives);
            _       <- if (List.isEmpty(implements)) Ok(()) else Err("interface ${name} が interface を implements するのは未対応です");
            fields_ <- fieldDefs
        ) yield { name = name, description = description, fields = fields_ }

    ///
    /// 名前だけの型参照（implements や union の枝）。リストや ! は SDL の文法上ここに来ない。
    ///
    def readNamedType(ty: Type[Object]): Result[String, String] \ IO =
        readType(ty) |> Result.flatMap(read -> match read {
            case Ty.Named(name) => Ok(name)
            case other          => Err("型名だけを書く場所に ${other} があります")
        })

    ///
    /// input Name { ... } を読む。フィールドは引数と同じ読み方。
    ///
    def readInput(definition: Definition[Object]): Result[String, InputDef] \ IO =
        let inputDefinition = unchecked_cast(definition as InputObjectTypeDefinition);
        let values: List[InputValueDefinition] = Adaptor.fromList(inputDefinition.getInputValueDefinitions());
        let directives: List[Directive] = Adaptor.fromList(inputDefinition.getDirectives());
        let name = inputDefinition.getName();
        let description = descriptionOf(inputDefinition.getDescription());
        let fieldDefs = values |> List.map(readArg) |> Result.sequence;
        forM (
            _       <- noDirectives(directives);
            fields_ <- fieldDefs
        ) yield { name = name, description = description, fields = fields_ }

    ///
    /// フィールド 1 つ。
    ///
    def readField(field: FieldDefinition): Result[String, FieldDef] \ IO =
        let inputs: List[InputValueDefinition] = Adaptor.fromList(field.getInputValueDefinitions());
        let directives: List[Directive] = Adaptor.fromList(field.getDirectives());
        let args = inputs |> List.map(readArg) |> Result.sequence;
        let ty = readType(field.getType());
        let name = field.getName();
        let description = descriptionOf(field.getDescription());
        let deprecated = deprecationOf(directives);
        forM (
            _       <- onlyDeprecated(directives);
            argDefs <- args;
            fieldTy <- ty
        ) yield { name = name, args = argDefs, ty = fieldTy, description = description, deprecated = deprecated }

    ///
    /// @deprecated 以外の directive があれば Err（未対応を黙って落とさない）。
    ///
    def onlyDeprecated(directives: List[Directive]): Result[String, Unit] \ IO =
        directives |> List.filter(directive -> directive.getName() != "deprecated") |> noDirectives

    ///
    /// directive が 1 つでもあれば Err（型・enum・input・引数には対応する directive が無い。enum 値は onlyDeprecated 経由）。
    ///
    def noDirectives(directives: List[Directive]): Result[String, Unit] \ IO =
        directives |> List.map(directive -> "対応していない directive です: @${directive.getName()}") |> firstErr

    ///
    /// 引数 1 つ。
    ///
    def readArg(input: InputValueDefinition): Result[String, ArgDef] \ IO =
        let defaultValue: AstValue[Object] = input.getDefaultValue();
        let directives: List[Directive] = Adaptor.fromList(input.getDirectives());
        let ty = readType(input.getType());
        let default_ = if (Objects.isNull(defaultValue)) Ok(None) else readValue(defaultValue) |> Result.map(Some);
        let name = input.getName();
        let description = descriptionOf(input.getDescription());
        forM (
            _     <- noDirectives(directives);
            argTy <- ty;
            value <- default_
        ) yield { name = name, ty = argTy, description = description, defaultValue = value }

    ///
    /// 型参照。NonNullType / ListType / TypeName の 3 種。
    ///
    def readType(ty: Type[Object]): Result[String, Ty] \ IO =
        let obj: Object = checked_cast(ty);
        if (isA("graphql.language.NonNullType", obj))
            readType((unchecked_cast(obj as NonNullType)).getType()) |> Result.map(Ty.NonNull)
        else if (isA("graphql.language.ListType", obj))
            readType((unchecked_cast(obj as ListType)).getType()) |> Result.map(Ty.ListOf)
        else if (isA("graphql.language.TypeName", obj))
            Ok(Ty.Named((unchecked_cast(obj as TypeName)).getName()))
        else
            Err("対応していない型参照です: ${obj.getClass().getSimpleName()}")

    ///
    /// 既定値の AST を、生成物に埋める Flix の式（Value を作る式）にする。
    ///
    def readValue(value: AstValue[Object]): Result[String, String] \ IO =
        let obj: Object = checked_cast(value);
        if (isA("graphql.language.IntValue", obj))
            (unchecked_cast(obj as IntValue)).getValue().toString() |> Int32.fromString |> Option.map(n -> "Value.Int(${n})") |> Option.toOk("Int の既定値が Int32 に収まりません")
        else if (isA("graphql.language.FloatValue", obj))
            Ok("Value.Float(${floatLiteral((unchecked_cast(obj as FloatValue)).getValue().toPlainString())})")
        else if (isA("graphql.language.StringValue", obj))
            Ok("Value.Str(${Emit.stringLiteral((unchecked_cast(obj as StringValue)).getValue())})")
        else if (isA("graphql.language.BooleanValue", obj))
            Ok("Value.Bool(${(unchecked_cast(obj as BooleanValue)).isValue()})")
        else if (isA("graphql.language.EnumValue", obj))
            Ok("Value.Str(${Emit.stringLiteral((unchecked_cast(obj as EnumValue)).getName())})")
        else if (isA("graphql.language.NullValue", obj))
            Ok("Value.Null")
        else if (isA("graphql.language.ArrayValue", obj)) {
            let items: List[AstValue[Object]] = Adaptor.fromList((unchecked_cast(obj as ArrayValue)).getValues());
            items |> List.map(readValue) |> Result.sequence |> Result.map(exprs -> "Value.List(${List.join(" :: ", exprs)} :: Nil)")
        } else
            Err("対応していない既定値です: ${obj.getClass().getSimpleName()}")

    ///
    /// Flix の Float64 リテラルにする。小数点が無ければ .0 を足す。
    ///
    /// WhyNot: BigDecimal の toString を使わないのは、1e10 が "1E+10" になって Flix の字句にならないため。
    ///
    def floatLiteral(plain: String): String =
        if (String.contains(substr = ".", plain)) plain else "${plain}.0"

    ///
    /// enum Name { ... } を読む。値の description と @deprecated も読む。
    ///
    def readEnum(definition: Definition[Object]): Result[String, EnumDef] \ IO =
        let enumDefinition = unchecked_cast(definition as EnumTypeDefinition);
        let values: List[EnumValueDefinition] = Adaptor.fromList(enumDefinition.getEnumValueDefinitions());
        let directives: List[Directive] = Adaptor.fromList(enumDefinition.getDirectives());
        let name = enumDefinition.getName();
        let description = descriptionOf(enumDefinition.getDescription());
        let valueDefs = values |> List.map(readEnumValue) |> Result.sequence;
        forM (
            _       <- noDirectives(directives);
            values_ <- valueDefs
        ) yield { name = name, description = description, values = values_ }

    ///
    /// enum の値 1 つ。
    ///
    def readEnumValue(value: EnumValueDefinition): Result[String, EnumValueDef] \ IO =
        let directives: List[Directive] = Adaptor.fromList(value.getDirectives());
        let name = value.getName();
        let description = descriptionOf(value.getDescription());
        let deprecated = deprecationOf(directives);
        onlyDeprecated(directives) |> Result.map(_ -> { name = name, description = description, deprecated = deprecated })

    ///
    /// description。無ければ None。
    ///
    def descriptionOf(description: Description): Option[String] \ IO =
        if (Objects.isNull(description)) None else Some(description.getContent())

    ///
    /// @deprecated の有無と reason。directive が無ければ None。
    ///
    def deprecationOf(directives: List[Directive]): Option[Deprecation] \ IO =
        directives |> List.find(directive -> directive.getName() == "deprecated") |> Option.map(directive -> {
            let reason: Argument = directive.getArgument("reason");
            if (Objects.isNull(reason)) Deprecation.NoReason else Deprecation.Reason(stringOf(reason.getValue()))
        })

    ///
    /// StringValue の中身。StringValue でなければ toString。
    ///
    def stringOf(value: AstValue[Object]): String \ IO =
        let obj: Object = checked_cast(value);
        if (isA("graphql.language.StringValue", obj)) (unchecked_cast(obj as StringValue)).getValue() else obj.toString()

    ///
    /// obj が className のインスタンスか。
    ///
    def isA(className: String, obj: t): Bool \ IO =
        Class.forName(className).isInstance(unchecked_cast(obj as Object))

}
