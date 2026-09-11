// Ulid: 時刻 10 文字 + 乱数 16 文字の 26 文字。文字列の並びが時刻順になる。

/// 仕様の例（時刻 1469918176385 → 01ARYZ6S41）。乱数が全部 0 なら後ろは 0 が 16 個。
@Test
def testUlidEncodeSpecExample(): Unit \ Assert =
    Assert.assertEq(expected = ("01ARYZ6S410000000000000000", 26),
        (Ulid.encode(1469918176385i64, Vector.repeat(10, 0i8)), String.length(Ulid.encode(1469918176385i64, Vector.repeat(10, 0i8)))))

/// 乱数の最大（全ビット 1）は Z が 16 個。時刻が 1 ミリ秒進めば文字列も大きくなる。
@Test
def testUlidOrderAndRandom(): Unit \ Assert =
    let later = Ulid.encode(1469918176386i64, Vector.repeat(10, 0i8));
    let earlier = Ulid.encode(1469918176385i64, Vector.repeat(10, -1i8));
    Assert.assertEq(expected = ("01ARYZ6S41ZZZZZZZZZZZZZZZZ", true), (earlier, later > earlier))

/// その時刻の下限は、同じ時刻のどの ULID 以下で、1 ミリ秒前のどの ULID より大きい（時刻の範囲を id の範囲に変えられる）。
@Test
def testUlidLowerBoundAt(): Unit \ Assert =
    let bound = Ulid.lowerBoundAt(1469918176385i64);
    Assert.assertEq(expected = ("01ARYZ6S410000000000000000", true, true),
        (bound, bound <= Ulid.encode(1469918176385i64, Vector.repeat(10, 0i8)), bound > Ulid.encode(1469918176384i64, Vector.repeat(10, -1i8))))
