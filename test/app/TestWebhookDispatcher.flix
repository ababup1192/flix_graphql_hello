// WebhookDispatcher: 署名と再試行の間隔（純粋な部分）。

/// 署名は "sha256=" + HMAC-SHA256(secret, "timestamp.body") の 16 進。secret かボディが違えば変わる。
@Test
def testWebhookSignature(): Unit \ Assert =
    let signed = { timestamp = "1700000000", body = "{\"event\":\"entry.published\"}" };
    let first = WebhookDispatcher.signature("whsec_abc", signed);
    let other = WebhookDispatcher.signature("whsec_abd", signed);
    Assert.assertEq(expected = (true, 7 + 64, false),
        (String.startsWith(prefix = "sha256=", first), String.length(first), first == other))

/// 1 分 → 5 分 → 30 分 → 2 時間、5 回目で諦める。
@Test
def testWebhookRetryDelays(): Unit \ Assert =
    Assert.assertEq(expected = List#{Some(60i64), Some(300i64), Some(1800i64), Some(7200i64), None},
        List#{1, 2, 3, 4, 5} |> List.map(WebhookDispatcher.retryDelaySeconds))
