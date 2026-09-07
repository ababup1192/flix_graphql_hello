///
/// 積まれた配信（webhook_deliveries）を拾って POST する。サーバの起動時に 1 本のスレッドで回す。
/// 拾うのはプロジェクトを跨ぐが、送る時は 1 件ずつそのプロジェクトの印で Webhook（url と secret）を引く。
///
/// WhyNot: HTTP を Tx の中で送らないのは、相手が遅いと接続を長く占めるため。拾う Tx を COMMIT してから送り、結果を別の Tx で書く。
/// 送っている最中に落ちれば status が sending のまま残るが、それは「不明」として残す（二重送信より安全）。受け手は X-Cms-Delivery で重複を見分けられる。
///
mod WebhookDispatcher {

    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse

    import java.lang.System
    import java.lang.Thread

    /// 1 回に拾う数。
    def batchSize(): Int64 = 20i64

    /// 拾う間隔（ミリ秒）。
    def intervalMs(): Int64 = 2000i64

    ///
    /// 止まらずに回す。失敗はログに出して次の周へ。
    ///
    pub def runForever(pool: Pool): Unit \ IO =
        match Net.Http.runWithIO(() -> tick(pool)) {
            case Ok(_)        => ()
            case Err(message) => println("webhook: ${message}")
        };
        Thread.sleep(intervalMs());
        runForever(pool)

    ///
    /// 送る番の配信を拾って送る。送った数を返す。テストは Http の handler を差し替えて相手の応答を作る。
    ///
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Http} =
        DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> WebhooksQueries.claimDueDeliveries(batchSize())))
            |> Result.mapErr(failure -> "配信を拾えません: ${failure}")
            |> Result.flatMap(claimed -> Result.traverse(deliverOne(pool), claimed) |> Result.map(List.length))

    ///
    /// 1 件送って結果を書く。
    ///
    def deliverOne(pool: Pool, claimed: { id = String, projectId = Int64, webhookId = Int64, event = String, payload = Util.Json.Json, attempts = Int32 }): Result[String, Unit] \ {IO, Http} =
        let projectId = ProjectId.ProjectId(claimed#projectId);
        let target = DbRunner.retrying(() -> TenantTx.withLazyTx(pool, projectId, () -> WebhooksQueries.findWebhookForDelivery({ id = claimed#webhookId, projectId = claimed#projectId })))
            |> Result.mapErr(failure -> "Webhook を引けません: ${failure}");
        Result.flatMap(found -> match found {
            case None => record(pool, claimed, projectId, Err((0, "Webhook が消えています")))
            case Some(webhook) => {
                let body = Util.Json.toCompactString(claimed#payload);
                let timestamp = Int64.toString(System.currentTimeMillis() / 1000i64);
                let request = HttpRequest.post(webhook#url, body)
                    |> HttpRequest.withContentType("application/json")
                    |> HttpRequest.setHeader("X-Cms-Event", claimed#event)
                    |> HttpRequest.setHeader("X-Cms-Delivery", claimed#id)
                    |> HttpRequest.setHeader("X-Cms-Timestamp", timestamp)
                    |> HttpRequest.setHeader("X-Cms-Signature", signature(webhook#secret, timestamp, body))
                    |> HttpRequest.withTimeout(Time.Duration.seconds(10));
                let outcome = match Net.Http.send(request) {
                    case Ok(response) => if (HttpResponse.isSuccess(response)) Ok(HttpResponse.status(response)) else Err((HttpResponse.status(response), "HTTP ${HttpResponse.status(response)}"))
                    case Err(error)   => Err((0, "${error}"))
                };
                record(pool, claimed, projectId, outcome)
            }
        }, target)

    ///
    /// 結果を書く。失敗は回数に応じて次の時刻を置き、使い切れば failed。
    ///
    def record(pool: Pool, claimed: { id = String, attempts = Int32 | r }, projectId: ProjectId, outcome: Result[(Int32, String), Int32]): Result[String, Unit] \ IO =
        let write = () -> match outcome {
            case Ok(status) => discard WebhooksQueries.markDelivered({ id = claimed#id, projectId = ProjectId.toInt64(projectId), lastStatus = status })
            case Err((status, reason)) => match retryDelaySeconds(claimed#attempts) {
                case Some(delay) => discard WebhooksQueries.markRetry({ id = claimed#id, projectId = ProjectId.toInt64(projectId), delaySeconds = delay, lastStatus = status, lastError = reason })
                case None        => discard WebhooksQueries.markFailed({ id = claimed#id, projectId = ProjectId.toInt64(projectId), lastStatus = status, lastError = reason })
            }
        };
        DbRunner.retrying(() -> TenantTx.withLazyTx(pool, projectId, write)) |> Result.mapErr(failure -> "配信の結果を書けません: ${failure}")

    ///
    /// 何回目の失敗の後に何秒待つか。1 分 → 5 分 → 30 分 → 2 時間、5 回目で諦める。
    ///
    pub def retryDelaySeconds(attempts: Int32): Option[Int64] = match attempts {
        case 1 => Some(60i64)
        case 2 => Some(300i64)
        case 3 => Some(1800i64)
        case 4 => Some(7200i64)
        case _ => None
    }

    ///
    /// X-Cms-Signature の値。secret を鍵に "timestamp.body" の HMAC-SHA256（16 進）。受け手は同じ計算で照合し、timestamp が古ければ捨てる。
    ///
    pub def signature(secret: String, timestamp: String, body: String): String =
        "sha256=" + SigV4.hmacSha256Hex(secret, "${timestamp}.${body}")

}
