///
/// Base64Url: base64url（パディング無し）の往復。
///
mod TestBase64Url {

    /// encode した物を decode すると元のバイト列に戻る。空でも同じ。
    @Test
    def testRoundTrip(): Unit \ Assert =
        let inputs = List#{ String.toBytes("hello"), String.toBytes("日本語"), Vector#{}, Vector#{0i8, -1i8, 127i8, -128i8} };
        Assert.assertEq(expected = inputs |> List.map(Ok), inputs |> List.map(bytes -> Base64Url.decode(Base64Url.encode(bytes))))

    /// 標準の base64 で + / になるバイト列は - _ になり、末尾の = は付かない。
    @Test
    def testUrlAlphabetWithoutPadding(): Unit \ Assert =
        let cases = List#{
            (Vector#{-5i8, -1i8, -65i8}, "-_-_"),
            (String.toBytes("a"),        "YQ"),
            (String.toBytes("ab"),       "YWI"),
            (String.toBytes("abc"),      "YWJj")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (bytes, _) -> (bytes, Base64Url.encode(bytes))))

    /// 壊れた文字列は Err。標準の base64 の + / も受けない。
    @Test
    def testDecodeRejectsBrokenInput(): Unit \ Assert =
        let cases = List#{ ("!!!", Err("base64url が壊れています")), ("+/+/", Err("base64url が壊れています")), ("YQ", Ok(String.toBytes("a"))) };
        Assert.assertEq(expected = cases, cases |> List.map(match (text, _) -> (text, Base64Url.decode(text))))

}
