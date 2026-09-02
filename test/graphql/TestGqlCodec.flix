///
/// GqlCodec: Flix の値と Value の相互変換。
///

/// スカラーは encode / decode で往復する。
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
