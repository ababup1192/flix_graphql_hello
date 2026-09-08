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
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Http, Log} =
        rounds(pool, maxRounds(), 0)

    def rounds(pool: Pool, remaining: Int32, sent: Int32): Result[String, Int32] \ {IO, Http, Log} =
        if (remaining <= 0) Ok(sent)
        else
            DbRunner.withTx(pool, None, () -> WebhooksQueries.claimDueDeliveries(batchSize()))
                |> Result.mapErr(failure -> "配信を拾えません: ${failure}")
                |> Result.flatMap(claimed ->
                    if (List.isEmpty(claimed)) Ok(sent)
                    else Result.traverse(deliverOne(pool), claimed) |> Result.flatMap(done -> rounds(pool, remaining - 1, sent + List.length(done))))

    ///
    /// 1 件送って結果を書く。
    ///
    def deliverOne(pool: Pool, claimed: { id = String, projectId = Int64, projectSlug = String, webhookId = Int64, event = String, payload = Util.Json.Json, attempts = Int32, createdAt = Timestamp.Timestamp }): Result[String, Unit] \ {IO, Http, Log} =
        let projectId = ProjectId.ProjectId(claimed#projectId);
        let projectLabel = Log.Fields.empty() |> Log.Fields.str("project", claimed#projectSlug);
        // 送り先（url と secret）をそのプロジェクトの RLS の印を置いた Tx で引く。HTTP はこの Tx の外で送る
        let target = DbRunner.withTx(pool, Some(projectId), () -> WebhooksQueries.findWebhookForDelivery({ id = claimed#webhookId, projectId = claimed#projectId }))
            |> Result.mapErr(failure -> "Webhook を引けません: ${failure}");
        Result.flatMap(found -> match found {
            // 積んだ後に Webhook が消えた物は失敗として書く（送らない）
            case None => record(pool, claimed, projectId, projectLabel, Err((0, "Webhook が消えています")))
            case Some(webhook) => {
                // 本文と署名付きのリクエストを組んで POST し、結果を別の Tx で書く
                let timestamp = Int64.toString(System.currentTimeMillis() / 1000i64);
                let outcome = Net.Http.send(buildRequest(webhook, claimed, timestamp)) |> toOutcome;
                record(pool, claimed, projectId, projectLabel |> Log.Fields.str("webhook.id", webhook#publicId), outcome)
            }
        }, target)

    ///
    /// 配信 1 件の HTTP リクエストを組む。本文は payload に積んだ時刻を足した JSON、ヘッダは event / delivery id / timestamp / 署名。タイムアウトは 10 秒。
    ///
    def buildRequest(webhook: { url = String, secret = String | r1 }, claimed: { id = String, event = String, payload = Util.Json.Json, createdAt = Timestamp.Timestamp | r2 }, timestamp: String): HttpRequest =
        // 積んだ時刻を本文にも入れる（受け手が本文だけ保存しても時刻が残る）
        let body = Util.Json.toCompactString(withAt(claimed#createdAt, claimed#payload));
        HttpRequest.post(webhook#url, body)
            |> HttpRequest.withContentType("application/json")
            |> HttpRequest.setHeader("X-Cms-Event", claimed#event)
            |> HttpRequest.setHeader("X-Cms-Delivery", claimed#id)
            |> HttpRequest.setHeader("X-Cms-Timestamp", timestamp)
            |> HttpRequest.setHeader("X-Cms-Signature", signature(webhook#secret, { timestamp = timestamp, body = body }))
            |> HttpRequest.withTimeout(Time.Duration.seconds(10))

    ///
    /// 送った結果を record の形に。2xx は Ok(status)、それ以外の応答は Err(status, "HTTP status")、繋がらなかった物は Err(0, 理由)。
    ///
    pub def toOutcome(sent: Result[IoError.IoError, HttpResponse]): Result[(Int32, String), Int32] = match sent {
        case Ok(response) => if (HttpResponse.isSuccess(response)) Ok(HttpResponse.status(response)) else Err((HttpResponse.status(response), "HTTP ${HttpResponse.status(response)}"))
        case Err(error)   => Err((0, describeSendError(error)))
    }

    ///
    /// 送れなかった理由の人向けの文。last_error とログの error.message に入れる。
    ///
    pub def describeSendError(error: IoError.IoError): String = match error {
        case IoError.IoError(IoError.ErrorKind.ConnectionFailed, detail) => "接続できませんでした: ${detail}"
        case IoError.IoError(IoError.ErrorKind.UnknownHost, detail)      => "ホストが見つかりません: ${detail}"
        case IoError.IoError(IoError.ErrorKind.Timeout, detail)          => "応答がありませんでした（タイムアウト）: ${detail}"
        case IoError.IoError(kind, detail)                               => "送れませんでした（${kind}）: ${detail}"
    }

    ///
    /// 結果の属性。届いた・HTTP で断られた物は http.response.status_code、繋がらなかった物（status 0）は error.message。
    ///
    /// WhyNot: 繋がらなかった物に status_code 0 を付けないのは、集計に 0 が混ざり「HTTP の応答があった」と読めてしまうため。
    ///
    pub def outcomeFields(outcome: Result[(Int32, String), Int32], fields: Log.Fields): Log.Fields = match outcome {
        case Ok(status)            => fields |> Log.Fields.int("http.response.status_code", Int32.toInt64(status))
        case Err((0, reason))      => fields |> Log.Fields.str("error.message", reason)
        case Err((status, _))      => fields |> Log.Fields.int("http.response.status_code", Int32.toInt64(status))
    }

    /// payload に "at"（ISO 8601）を足す。オブジェクトでなければそのまま。
    def withAt(at: Timestamp.Timestamp, payload: Util.Json.Json): Util.Json.Json = match payload {
        case Util.Json.Json.JObject(fields) => Util.Json.Json.JObject(Map.insert("at", Util.Json.Json.JString(Timestamp.toIso8601(at)), fields))
        case other => other
    }

    ///
    /// 結果を書く。失敗は回数に応じて次の時刻を置き、使い切れば failed。labels はログの行に付ける project / webhook.id。
    ///
    def record(pool: Pool, claimed: { id = String, attempts = Int32 | r }, projectId: ProjectId, labels: Log.Fields, outcome: Result[(Int32, String), Int32]): Result[String, Unit] \ {IO, Log} =
        // 書く内容: 届けば delivered、失敗は回数に応じて次の時刻（retry）か failed
        let write = () -> match outcome {
            case Ok(status) => discard WebhooksQueries.markDelivered({ id = claimed#id, projectId = ProjectId.toInt64(projectId), lastStatus = status })
            case Err((status, reason)) => match retryDelaySeconds(claimed#attempts) {
                case Some(delay) => discard WebhooksQueries.markRetry({ id = claimed#id, projectId = ProjectId.toInt64(projectId), delaySeconds = delay, lastStatus = status, lastError = reason })
                case None        => discard WebhooksQueries.markFailed({ id = claimed#id, projectId = ProjectId.toInt64(projectId), lastStatus = status, lastError = reason })
            }
        };
        // 仕事の行を先に出してから、そのプロジェクトの RLS の印を置いた Tx で書く
        match outcome {
            case Ok(status)       => JobLog.write({ kind = JobLog.JobKind.Webhook, id = claimed#id, outcome = JobLog.JobOutcome.Delivered, detail = "HTTP ${status}" }, labels |> outcomeFields(outcome))
            case Err((_, reason)) => JobLog.write({ kind = JobLog.JobKind.Webhook, id = claimed#id, outcome = if (Option.isEmpty(retryDelaySeconds(claimed#attempts))) JobLog.JobOutcome.Failed else JobLog.JobOutcome.RetryLater, detail = reason }, labels |> outcomeFields(outcome))
        };
        DbRunner.withTx(pool, Some(projectId), write) |> Result.mapErr(failure -> "配信の結果を書けません: ${failure}")

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
