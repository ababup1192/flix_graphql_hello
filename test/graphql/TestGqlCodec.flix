///
/// GqlCodec: Flix の値と Value の相互変換。
///
/// スカラーは encode / decode で往復する。
mod TestGqlCodec {

    @Test
    def testGqlCodecRoundTrip(): Unit \ Assert =
        Assert.assertEq(expected = (Ok(42), Ok("x"), Ok(true), Ok(1.5), Ok(Id.Id("p1"))),
            (GqlCodec.decode(GqlCodec.int32(), GqlCodec.encode(GqlCodec.int32(), 42)),
             GqlCodec.decode(GqlCodec.string(), GqlCodec.encode(GqlCodec.string(), "x")),
             GqlCodec.decode(GqlCodec.bool(), GqlCodec.encode(GqlCodec.bool(), true)),
             GqlCodec.decode(GqlCodec.float64(), GqlCodec.encode(GqlCodec.float64(), 1.5)),
             GqlCodec.decode(GqlCodec.id(), GqlCodec.encode(GqlCodec.id(), Id.Id("p1")))))

    /// 型が合わない Value は期待した型名を含む Err。Float は Int も受け付ける。
    @Test
    def testGqlCodecMismatch(): Unit \ Assert =
        Assert.assertEq(expected = (Err("expected Int"), Err("expected String"), Ok(2.0)),
            (GqlCodec.decode(GqlCodec.int32(), Value.Str("x")),
             GqlCodec.decode(GqlCodec.string(), Value.Int(1)),
             GqlCodec.decode(GqlCodec.float64(), Value.Int(2))))

    /// option は Null を None に、list は要素を 1 つずつ変換する。
    @Test
    def testGqlCodecOptionAndList(): Unit \ Assert =
        Assert.assertEq(expected = (Ok(None), Ok(Some(1)), Ok(1 :: 2 :: Nil), Value.List(Value.Int(1) :: Value.Null :: Nil)),
            (GqlCodec.decode(GqlCodec.option(GqlCodec.int32()), Value.Null),
             GqlCodec.decode(GqlCodec.option(GqlCodec.int32()), Value.Int(1)),
             GqlCodec.decode(GqlCodec.list(GqlCodec.int32()), Value.List(Value.Int(1) :: Value.Int(2) :: Nil)),
             GqlCodec.encode(GqlCodec.list(GqlCodec.option(GqlCodec.int32())), Some(1) :: None :: Nil)))

    /// SDL の型表記。option は ! が取れ、list は [T!]!。
    @Test
    def testGqlCodecTypeRef(): Unit \ Assert =
        Assert.assertEq(expected = ("Int!", "Int", "[String!]!", "[ID]"),
            (TypeRef.toSdl(GqlCodec.typeRef(GqlCodec.int32())),
             TypeRef.toSdl(GqlCodec.typeRef(GqlCodec.option(GqlCodec.int32()))),
             TypeRef.toSdl(GqlCodec.typeRef(GqlCodec.list(GqlCodec.string()))),
             TypeRef.toSdl(GqlCodec.typeRef(GqlCodec.option(GqlCodec.list(GqlCodec.option(GqlCodec.id())))))))

    ///
    /// { n: Int!, tag: String } の input。
    ///
    def pairCodec(): GqlCodec[{ n = Int32, tag = Option[String] }] =
        let n = Arg.arg("n", GqlCodec.int32());
        let tag = Arg.arg("tag", GqlCodec.option(GqlCodec.string()));
        GqlCodec.inputObject("Pair", Arg.info(n) :: Arg.info(tag) :: Nil, fields ->
            forM (nv <- Arg.decodeField(n, fields); tv <- Arg.decodeField(tag, fields)) yield { n = nv, tag = tv })

    /// input は Obj をレコードにする。無いフィールドは nullable なら None、non-null ならフィールド名と型を含む Err。Obj 以外は型名の Err。
    @Test
    def testGqlCodecInputObject(): Unit \ Assert =
        Assert.assertEq(expected = (Ok((1, None)), Err("field 'n' must be Int!: expected Int"), Err("expected Pair")),
            (GqlCodec.decode(pairCodec(), Value.Obj(Map#{ "n" => Value.Int(1) })) |> Result.map(r -> (r#n, r#tag)),
             GqlCodec.decode(pairCodec(), Value.Obj(Map#{ "tag" => Value.Str("x") })) |> Result.map(r -> (r#n, r#tag)),
             GqlCodec.decode(pairCodec(), Value.Int(1)) |> Result.map(r -> (r#n, r#tag))))

    /// input を引数に使うと、エラー文は引数の位置から中のフィールドまでつながる。SDL の型は input の名前。
    @Test
    def testGqlCodecInputAsArgument(): Unit \ Assert =
        Assert.assertEq(expected = (Err("argument 'p' must be Pair!: field 'n' must be Int!: expected Int"), "Pair!"),
            (Arg.decode(Arg.arg("p", pairCodec()), Map#{ "p" => Value.Obj(Map#{ "n" => Value.Str("x") }) }) |> Result.map(r -> (r#n, r#tag)) |> Result.mapErr(FieldError.message),
             TypeRef.toSdl(GqlCodec.typeRef(pairCodec()))))

    /// ネストした input のエラー文は、引数 → 外の input のフィールド → 内の input のフィールドと位置がつながる。
    @Test
    def testGqlCodecNestedInputError(): Unit \ Assert =
        let inner = Arg.arg("inner", pairCodec());
        let outer = GqlCodec.inputObject("Outer", Arg.info(inner) :: Nil, fields -> Arg.decodeField(inner, fields) |> Result.map(p -> { inner = p }));
        Assert.assertEq(expected = Err("argument 'p' must be Outer!: field 'inner' must be Pair!: field 'n' must be Int!: expected Int"),
            Arg.decode(Arg.arg("p", outer), Map#{ "p" => Value.Obj(Map#{ "inner" => Value.Obj(Map#{ "n" => Value.Str("x") }) }) })
                |> Result.map(o -> o#inner#n) |> Result.mapErr(FieldError.message))

    /// describeValue / deprecateValue は指定した値だけを書き換える（Color は GraphqlFixtures の enum）。
    @Test
    def testGqlCodecDescribeValueOnlyTouchesTarget(): Unit \ Assert =
        let color = Color.codec()
            |> GqlCodec.describeValue(Color.Red, "赤") |> GqlCodec.deprecateValue(Color.Blue, Deprecation.NoReason);
        Assert.assertEq(expected = ("RED" :: "BLUE" :: Nil, Some("赤") :: None :: Nil, None :: Some(Deprecation.NoReason) :: Nil),
            match GqlCodec.typeRef(color) {
                case TypeRef.Enum(_, _, infos) => (List.map(i -> i#name, infos), List.map(i -> i#description, infos), List.map(i -> i#deprecated, infos))
                case _                         => bug!("enumOf の typeRef は Enum のはず")
            })

}
