///
/// CDN の purge の送り先。CMS_CDN_PURGE_URL と CMS_CDN_PURGE_TOKEN が両方ある時だけ有効。
///
/// - url: Cloudflare なら `https://api.cloudflare.com/client/v4/zones/<zone>/purge_cache`
/// - token: `Authorization: Bearer` に入れる API トークン
///
pub type alias PurgeTarget = { url = String, token = String }

///
/// CDN の purge。プロジェクトの版（content_version）が進んだプロジェクトを tick で拾って cdn_purges（outbox）に積み、
/// 拾って `purge_everything` を POST する。送り方・記録・再試行は WebhookDispatcher と同じ形。
///
/// WhyNot: 公開のユースケースと同じ Tx で積まないのは、送り先が環境変数（プロセスの設定）で、ユースケースがそれを知るには
/// 公開・取り下げ・削除・型の変更の全部の署名に effect を足す事になるため。版は同じ Tx で進んでいるので、
/// 「版が進んだのに積まれない」は起きない（積むのが次の tick まで最長 2 秒遅れるだけ）。
///
/// WhyNot: webhook_deliveries に相乗りしないのは、webhook_id を nullable にする `ALTER COLUMN ... DROP NOT NULL` を sqlfx の生成器が
/// 読めず、生成された decoder が NULL の行で落ちるため。表は別にし、送る側の作りを揃える。
///
mod CdnPurge {

    use Net.Http.Http
    use Net.HttpRequest
    use Net.HttpResponse

    /// 1 回に拾う数。
    def batchSize(): Int64 = 20i64

    ///
    /// 環境変数の生の値から送り先。両方が空でなければ Some。
    ///
    pub def targetOf(url: Option[String], token: Option[String]): Option[PurgeTarget] =
        match (url |> Option.filter(text -> not String.isEmpty(text)), token |> Option.filter(text -> not String.isEmpty(text))) {
            case (Some(foundUrl), Some(foundToken)) => Some({ url = foundUrl, token = foundToken })
            case _                                  => None
        }

    ///
    /// 版が進んだプロジェクトの purge を積む（1 Tx。purged_version を進めるのと同じ Tx）。積んだ数を返す。
    ///
    pub def enqueue(pool: Pool): Result[String, Int32] \ IO =
        IdGen.runWithRandom(() ->
            DbRunner.withTx(pool, None, () ->
                CdnPurgesQueries.claimPurgeTargets()
                    |> List.map(target -> CdnPurgesQueries.insertPurge({ id = IdGen.freshUlid(), projectId = target#id, contentVersion = target#contentVersion }))
                    |> List.length))
            |> Result.mapErr(failure -> "purge を積めません: ${failure}")

    ///
    /// 送る番の purge を拾って送る。送った数を返す。テストは Http の handler を差し替えて相手の応答を作る。
    ///
    pub def tick(pool: Pool, target: PurgeTarget): Result[String, Int32] \ {IO, Http, Log} =
        DbRunner.withTx(pool, None, () -> CdnPurgesQueries.claimDuePurges(batchSize()))
            |> Result.mapErr(failure -> "purge を拾えません: ${failure}")
            |> Result.flatMap(claimed -> Result.traverse(purgeOne(pool, target), claimed) |> Result.map(List.length))

    ///
    /// 1 件送って結果を書く。HTTP は Tx の外で送る。
    ///
    def purgeOne(pool: Pool, target: PurgeTarget, claimed: CdnPurgesQueries.ClaimDuePurgesRow): Result[String, Unit] \ {IO, Http, Log} =
        let outcome = Net.Http.send(buildRequest(target, claimed#id)) |> WebhookDispatcher.toOutcome;
        let labels = Log.Fields.empty() |> Log.Fields.str("project", claimed#projectSlug);
        record(pool, claimed, labels, outcome)

    ///
    /// purge の HTTP リクエスト。Cloudflare の purge_cache の形（`{"purge_everything": true}`、Bearer のトークン）。タイムアウトは 10 秒。
    ///
    pub def buildRequest(target: PurgeTarget, purgeId: String): HttpRequest =
        HttpRequest.post(target#url, "{\"purge_everything\":true}")
            |> HttpRequest.withContentType("application/json")
            |> HttpRequest.setHeader("Authorization", "Bearer ${target#token}")
            |> HttpRequest.setHeader("X-Cms-Delivery", purgeId)
            |> HttpRequest.withTimeout(Time.Duration.seconds(10))

    ///
    /// 結果を書く。失敗は Webhook と同じ間隔で次の時刻を置き、使い切れば failed。
    ///
    def record(pool: Pool, claimed: CdnPurgesQueries.ClaimDuePurgesRow, labels: Log.Fields, outcome: Result[(Int32, String), Int32]): Result[String, Unit] \ {IO, Log} =
        let write = () -> match outcome {
            case Ok(status) => discard CdnPurgesQueries.markPurgeDelivered({ id = claimed#id, projectId = claimed#projectId, lastStatus = status })
            case Err((status, reason)) => match WebhookDispatcher.retryDelaySeconds(claimed#attempts) {
                case Some(delay) => discard CdnPurgesQueries.markPurgeRetry({ id = claimed#id, projectId = claimed#projectId, delaySeconds = delay, lastStatus = status, lastError = reason })
                case None        => discard CdnPurgesQueries.markPurgeFailed({ id = claimed#id, projectId = claimed#projectId, lastStatus = status, lastError = reason })
            }
        };
        // 何回目の試行かと、次に試すまでの秒数（Webhook と同じ間隔）
        let retry = { attempts = claimed#attempts, delaySeconds = WebhookDispatcher.retryDelaySeconds(claimed#attempts) };
        match outcome {
            case Ok(status)       => JobLog.write({ kind = JobLog.JobKind.CdnPurge, id = claimed#id, outcome = JobLog.JobOutcome.Delivered, detail = "HTTP ${status} (v${claimed#contentVersion})" }, labels |> WebhookDispatcher.outcomeFields(outcome))
            case Err((_, reason)) => JobLog.write({ kind = JobLog.JobKind.CdnPurge, id = claimed#id, outcome = if (Option.isEmpty(retry#delaySeconds)) JobLog.JobOutcome.Failed else JobLog.JobOutcome.RetryLater, detail = reason }, labels |> WebhookDispatcher.outcomeFields(outcome) |> JobLog.retryFields(retry))
        };
        DbRunner.withTx(pool, None, write) |> Result.mapErr(failure -> "purge の結果を書けません: ${failure}")

}
