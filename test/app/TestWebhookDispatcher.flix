// WebhookDispatcher: 署名と再試行の間隔（純粋な部分）。

/// 署名は "sha256=" + HMAC-SHA256(secret, "timestamp.body") の 16 進。secret かボディが違えば変わる。
@Test
def testWebhookSignature(): Unit \ Assert =
    let signed = { timestamp = "1700000000", body = "{\"event\":\"entry.published\"}" };
    let first = WebhookDispatcher.signature("whsec_abc", signed);
    let other = WebhookDispatcher.signature("whsec_abd", signed);
    Assert.assertEq(expected = (true, 7 + 64, false),
        (String.startsWith(prefix = "sha256=", first), String.length(first), first == other))

/// 送れなかった理由は人向けの文（Flix の enum の綴りではない）。種類ごとの言い方と、Java の例外名は残る。
@Test
def testWebhookDescribeSendErrorTable(): Unit \ Assert =
    let cases = List#{
        (IoError.IoError(IoError.ErrorKind.ConnectionFailed, "java.net.ConnectException"), "接続できませんでした: java.net.ConnectException"),
        (IoError.IoError(IoError.ErrorKind.UnknownHost, "hook.example"),                  "ホストが見つかりません: hook.example"),
        (IoError.IoError(IoError.ErrorKind.Timeout, "java.net.http.HttpTimeoutException"), "応答がありませんでした（タイムアウト）: java.net.http.HttpTimeoutException"),
        (IoError.IoError(IoError.ErrorKind.Other, "Circuit breaker is open"),             "送れませんでした（Other）: Circuit breaker is open")
    };
    Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (error, _) -> WebhookDispatcher.describeSendError(error)))

/// 結果の属性: 届いた・HTTP で断られた物は http.response.status_code、繋がらなかった物（status 0）は error.message だけ。
@Test
def testWebhookOutcomeFieldsTable(): Unit \ Assert =
    let cases = List#{
        (Ok(200),                                   List#{("http.response.status_code", Value.Int(200))}),
        (Err((500, "HTTP 500")),                    List#{("http.response.status_code", Value.Int(500))}),
        (Err((0, "接続できませんでした: java.net.ConnectException")), List#{("error.message", Value.Str("接続できませんでした: java.net.ConnectException"))})
    };
    Assert.assertEq(expected = cases |> List.map(snd), cases |> List.map(match (outcome, _) -> Log.Fields.empty() |> WebhookDispatcher.outcomeFields(outcome) |> Map.toList))

/// 1 分 → 5 分 → 30 分 → 2 時間、5 回目で諦める。
@Test
def testWebhookRetryDelays(): Unit \ Assert =
    Assert.assertEq(expected = List#{Some(60i64), Some(300i64), Some(1800i64), Some(7200i64), None},
        List#{1, 2, 3, 4, 5} |> List.map(WebhookDispatcher.retryDelaySeconds))
