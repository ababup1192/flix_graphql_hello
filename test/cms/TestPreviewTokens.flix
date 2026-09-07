// PreviewTokens: 署名・期限・プロジェクトの検証（純粋な部分）と previewUrl の組み立て。

def pepper(): ApiKeys.Pepper = { pepperId = "test", secret = "test-pepper" }

/// 同じ手順で作ったトークン（テスト用。issue は DB を引くのでここでは組み立てだけ真似る）。
def tokenOf(secret: String, projectId: Int64, entryId: String, exp: Int64): String =
    let payload = "${projectId}.${entryId}.${exp}";
    "pv_" + Jwt.encodeBase64Url(String.toBytes(payload)) + "." + SigV4.hmacSha256Hex(secret, payload)

/// 正しい物は entry の id になり、期限切れ・別プロジェクト・別の鍵で署名した物・形が違う物は None。
@Test
def testPreviewTokenVerify(): Unit \ Assert =
    let now = 1_700_000_000_000i64;
    let good = tokenOf("test-pepper", 1i64, "e1", 1_700_000_100i64);
    Assert.assertEq(
        expected = (Some(CmsTestKit.entryId("e1")), None, None, None, None, None),
        (PreviewTokens.verify(pepper(), good, ProjectId.default(), now),
         PreviewTokens.verify(pepper(), tokenOf("test-pepper", 1i64, "e1", 1_699_999_999i64), ProjectId.default(), now),
         PreviewTokens.verify(pepper(), good, ProjectId.ProjectId(2i64), now),
         PreviewTokens.verify(pepper(), tokenOf("other", 1i64, "e1", 1_700_000_100i64), ProjectId.default(), now),
         PreviewTokens.verify(pepper(), "pv_garbage", ProjectId.default(), now),
         PreviewTokens.verify(pepper(), "cms_notpreview", ProjectId.default(), now)))

/// {id} を置き換え、クエリが無ければ ? で、あれば & で preview を付ける。
@Test
def testPreviewUrl(): Unit \ Assert =
    Assert.assertEq(
        expected = ("https://site.example/preview/e1?preview=pv_x", "https://site.example/p?slug=e1&preview=pv_x"),
        (PreviewTokens.previewUrl("https://site.example/preview/{id}", CmsTestKit.entryId("e1"), "pv_x"),
         PreviewTokens.previewUrl("https://site.example/p?slug={id}", CmsTestKit.entryId("e1"), "pv_x")))
