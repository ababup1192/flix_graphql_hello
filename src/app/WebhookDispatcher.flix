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

    /// 1 回に拾う数。
    def batchSize(): Int64 = 20i64

    /// 1 回の tick で拾い直す回数の上限。同じ Webhook 宛は 1 度に 1 件しか拾えない（順序を守るため）ので、送れたら続けて拾う。
    def maxRounds(): Int32 = 25

    ///
    /// 送る番の配信を拾って送る。送った数を返す。拾える物が無くなるか上限の回数まで繰り返す。
    /// テストは Http の handler を差し替えて相手の応答を作る。
    ///
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Http} =
        rounds(pool, maxRounds(), 0)

    def rounds(pool: Pool, remaining: Int32, sent: Int32): Result[String, Int32] \ {IO, Http} =
        if (remaining <= 0) Ok(sent)
        else
            DbRunner.retrying(() -> Pool.withLazyTx(pool, () -> WebhooksQueries.claimDueDeliveries(batchSize())))
                |> Result.mapErr(failure -> "配信を拾えません: ${failure}")
                |> Result.flatMap(claimed ->
                    if (List.isEmpty(claimed)) Ok(sent)
                    else Result.traverse(deliverOne(pool), claimed) |> Result.flatMap(done -> rounds(pool, remaining - 1, sent + List.length(done))))

    ///
    /// 1 件送って結果を書く。
    ///
    def deliverOne(pool: Pool, claimed: { id = String, projectId = Int64, webhookId = Int64, event = String, payload = Util.Json.Json, attempts = Int32, createdAt = Timestamp.Timestamp }): Result[String, Unit] \ {IO, Http} =
        let projectId = ProjectId.ProjectId(claimed#projectId);
        let target = DbRunner.retrying(() -> TenantTx.withLazyTx(pool, projectId, () -> WebhooksQueries.findWebhookForDelivery({ id = claimed#webhookId, projectId = claimed#projectId })))
            |> Result.mapErr(failure -> "Webhook を引けません: ${failure}");
        Result.flatMap(found -> match found {
            case None => record(pool, claimed, projectId, Err((0, "Webhook が消えています")))
            case Some(webhook) => {
                // 積んだ時刻を本文にも入れる（受け手が本文だけ保存しても時刻が残る）
                let body = Util.Json.toCompactString(withAt(claimed#createdAt, claimed#payload));
                let timestamp = Int64.toString(System.currentTimeMillis() / 1000i64);
                let request = HttpRequest.post(webhook#url, body)
                    |> HttpRequest.withContentType("application/json")
                    |> HttpRequest.setHeader("X-Cms-Event", claimed#event)
                    |> HttpRequest.setHeader("X-Cms-Delivery", claimed#id)
                    |> HttpRequest.setHeader("X-Cms-Timestamp", timestamp)
                    |> HttpRequest.setHeader("X-Cms-Signature", signature(webhook#secret, { timestamp = timestamp, body = body }))
                    |> HttpRequest.withTimeout(Time.Duration.seconds(10));
                let outcome = match Net.Http.send(request) {
                    case Ok(response) => if (HttpResponse.isSuccess(response)) Ok(HttpResponse.status(response)) else Err((HttpResponse.status(response), "HTTP ${HttpResponse.status(response)}"))
                    case Err(error)   => Err((0, "${error}"))
                };
                record(pool, claimed, projectId, outcome)
            }
        }, target)

    /// payload に "at"（ISO 8601）を足す。オブジェクトでなければそのまま。
    def withAt(at: Timestamp.Timestamp, payload: Util.Json.Json): Util.Json.Json = match payload {
        case Util.Json.Json.JObject(fields) => Util.Json.Json.JObject(Map.insert("at", Util.Json.Json.JString(Timestamp.toIso8601(at)), fields))
        case other => other
    }

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
        match outcome {
            case Ok(status)            => JobLog.write({ kind = JobLog.JobKind.Webhook, id = claimed#id, outcome = JobLog.JobOutcome.Delivered, detail = "HTTP ${status}" })
            case Err((status, reason)) => JobLog.write({ kind = JobLog.JobKind.Webhook, id = claimed#id, outcome = if (Option.isEmpty(retryDelaySeconds(claimed#attempts))) JobLog.JobOutcome.Failed else JobLog.JobOutcome.RetryLater, detail = "HTTP ${status} ${reason}" })
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
    pub def signature(secret: String, signed: { timestamp = String, body = String }): String =
        "sha256=" + Sha256.hmacHex(secret, "${signed#timestamp}.${signed#body}")

}
