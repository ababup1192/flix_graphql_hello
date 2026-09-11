///
/// linkCard の OGP の取り直し。古い行（fetched_at が 7 日より前）と失敗した行（1 時間より前）を tick で拾い、取り直して upsert する。
/// 初回の取得はここではなく管理 API（LinkCards.fetch）。1 回の tick で最大 20 件。
///
/// WhyNot: 拾う行に印（claimed_at）を付けないのは、同じ url を 2 台が同時に取っても upsert が同じ値を書くだけで、
/// 二重に困る物（Webhook の受け手）が無いため。
///
mod LinkCardRefresh {

    use Net.Http.Http

    /// 1 回の tick で取り直す数。
    pub def batchSize(): Int64 = 20i64

    ///
    /// 番の行を拾って取り直す。取り直した数（失敗も含む）を返す。HTTP は Tx の外で送る。
    ///
    pub def tick(pool: Pool): Result[String, Int32] \ {IO, Http, Log} =
        DbRunner.withTx(pool, None, () -> LinkCardsQueries.listStaleLinkCards(batchSize()))
            |> Result.mapErr(failure -> "リンクカードの取り直しの行を拾えません: ${failure}")
            |> Result.flatMap(claimed -> Result.traverse(refreshOne(pool), claimed) |> Result.map(List.length))

    /// 1 件取り直して書く。ログはプロジェクトの slug と url（job.id）。
    def refreshOne(pool: Pool, claimed: LinkCardsQueries.ListStaleLinkCardsRow): Result[String, Unit] \ {IO, Http, Log} =
        let outcome = LinkCards.fetchOver(LinkCards.userAgent(claimed#projectName), claimed#url);
        let labels = Log.Fields.empty() |> Log.Fields.str("project", claimed#projectSlug);
        match outcome {
            case Ok(meta)    => JobLog.write({ kind = JobLog.JobKind.LinkCard, id = claimed#url, outcome = JobLog.JobOutcome.Done, detail = meta#title |> Option.getWithDefault("") }, labels)
            case Err(reason) => JobLog.write({ kind = JobLog.JobKind.LinkCard, id = claimed#url, outcome = JobLog.JobOutcome.RetryLater, detail = reason }, labels)
        };
        DbRunner.withTx(pool, Some(ProjectId.ProjectId(claimed#projectId)), () -> LinkCards.store(claimed#projectId, claimed#url, outcome))
            |> Result.mapErr(failure -> "リンクカードの取り直しを書けません: ${failure}")

}
