///
/// CalcResolvers: Args（Map[String, Value]）を受けて Result[String, Value] を返す。graphql-java は使わない。
///

/// addResolver は引数 a, b を足した Int を返す。
@Test
def testCalcResolversAdd(): Unit \ Assert =
    Assert.assertEq(expected = Ok(Value.Int(3)),
        CalcResolvers.addResolver(Map#{ "a" => Value.Int(1), "b" => Value.Int(2) }))

/// fibonacciResolver は引数 n 番目のフィボナッチ数を返す。
@Test
def testCalcResolversFibonacci(): Unit \ Assert =
    Assert.assertEq(expected = Ok(Value.Int(55)),
        CalcResolvers.fibonacciResolver(Map#{ "n" => Value.Int(10) }))

/// 引数が Int でない・無いときは、その引数名を含む Err になる。
@Test
def testCalcResolversMissingArgs(): Unit \ Assert =
    Assert.assertEq(expected = (Err("argument 'a' must be Int"), Err("argument 'n' must be Int")),
        (CalcResolvers.addResolver(Map#{ "a" => Value.Str("x"), "b" => Value.Int(2) }),
         CalcResolvers.fibonacciResolver(Map#{})))

/// intArg は Int の引数をそのまま取り出す。
@Test
def testCalcResolversIntArg(): Unit \ Assert =
    Assert.assertEq(expected = Ok(7), CalcResolvers.intArg("a", Map#{ "a" => Value.Int(7) }))

/// resolvers は Query.add と Query.fibonacci の 2 つを登録している。
@Test
def testCalcResolversKeys(): Unit \ Assert =
    Assert.assertEq(expected = ("Query", "add") :: ("Query", "fibonacci") :: Nil,
        Map.keysOf(CalcResolvers.resolvers()) |> Set.toList)
