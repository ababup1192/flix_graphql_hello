///
/// Sha256: SHA-256 と HMAC-SHA256 の既知ベクタ（FIPS 180-2 の "abc"、RFC 4231 の Test Case 1 と 2）。
///
mod TestSha256 {

    /// "abc" の SHA-256 は FIPS 180-2 の例の値。空文字も決まった値。
    @Test
    def testHexKnownVectors(): Unit \ Assert =
        let cases = List#{
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("",    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        };
        Assert.assertEq(expected = cases, cases |> List.map(match (data, _) -> (data, Sha256.hex(data))))

    /// RFC 4231 Test Case 1。鍵は 0x0b が 20 バイト、データは "Hi There"。
    @Test
    def testHmacRfc4231Case1(): Unit \ Assert =
        Assert.assertEq(
            expected = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            Sha256.hmac(List.repeat(20, 11i8) |> List.toVector, "Hi There") |> Sha256.hexOf)

    /// RFC 4231 Test Case 2。鍵は "Jefe"、データは "what do ya want for nothing?"。文字列の鍵の口で取る。
    @Test
    def testHmacHexRfc4231Case2(): Unit \ Assert =
        Assert.assertEq(
            expected = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            Sha256.hmacHex("Jefe", "what do ya want for nothing?"))

}
