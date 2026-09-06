///
/// Calc: 計算そのもの。GraphQL も graphql-java も使わない。
///

/// add は 2 つの整数の和を返す。
@Test
def testCalcAdd(): Unit \ Assert =
    Assert.assertEq(expected = 3, Calc.add(1, 2))

/// fibonacci は 0 番目から順に 0, 1, 1, 2, 3, 5, 8 を返す。負の n は 0 番目とみなす。
@Test
def testCalcFibonacci(): Unit \ Assert =
    Assert.assertEq(expected = 0 :: 0 :: 1 :: 1 :: 2 :: 3 :: 5 :: 8 :: Nil,
        List.map(Calc.fibonacci, -1 :: 0 :: 1 :: 2 :: 3 :: 4 :: 5 :: 6 :: Nil))
