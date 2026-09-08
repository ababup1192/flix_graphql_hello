///
/// RequestTx: 読むだけの文書を 1 リクエスト 1 Tx にする時の状態の遷移（純粋）。接続の型は Int32 で回す。
///
mod TestRequestTx {

    use DbError.DbErrorKind
    use DbError.Failure
    use DbError.TransientKind
    use RequestTx.State.{Idle, Open, Broken}
    use RequestTx.Outcome

    /// 再実行しても直らない失敗。
    def permanent(): Failure = Failure.Permanent(DbErrorKind.Other("boom"))

    /// 一時的な失敗。
    def transient(): Failure = Failure.Transient(TransientKind.Timeout(0))

    ///
    /// フィールドの結果で次の状態が決まる。
    ///
    ///   Idle    + 成功 / 業務エラー → Idle（SQL を出さなかった）
    ///   Open    + 成功 / 業務エラー → Open（続ける。業務エラーでも COMMIT まで持つ）
    ///   Open    + DB の失敗         → Broken(Some(接続), 失敗)（接続は最後に ROLLBACK する）
    ///   Idle    + DB の失敗         → Broken(None, 失敗)（借りられなかった）
    ///   Broken  + 何でも            → 変わらない（最初の失敗を覚えたまま）
    ///
    @Test
    def testAfterFieldTable(): Unit \ Assert =
        let table: List[((RequestTx.State[Int32], Result[Failure, Result[String, Unit]]), RequestTx.State[Int32])] = List#{
            ((Idle, Ok(Ok(()))),                        Idle),
            ((Idle, Ok(Err("notFound"))),               Idle),
            ((Open(1), Ok(Ok(()))),                     Open(1)),
            ((Open(1), Ok(Err("notFound"))),            Open(1)),
            ((Open(1), Err(permanent())),               Broken(Some(1), permanent())),
            ((Open(1), Err(transient())),               Broken(Some(1), transient())),
            ((Idle, Err(transient())),                  Broken(None, transient())),
            ((Broken(Some(1), permanent()), Ok(Ok(()))), Broken(Some(1), permanent())),
            ((Broken(None, permanent()), Err(transient())), Broken(None, permanent()))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match ((state, outcome), _) -> RequestTx.afterField(state, outcome)))

    /// Broken になった後のフィールドは SQL を出さない（canRun が false）。Idle と Open は走る。
    @Test
    def testCanRunTable(): Unit \ Assert =
        let table: List[(RequestTx.State[Int32], Bool)] = List#{
            (Idle, true),
            (Open(1), true),
            (Broken(Some(1), permanent()), false),
            (Broken(None, transient()), false)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (state, _) -> RequestTx.canRun(state)))

    /// リクエストの行に載せる Tx の数。接続を借りなかった（Idle / Broken(None)）なら 0、借りたなら 1。
    @Test
    def testTransactionsOfTable(): Unit \ Assert =
        let table: List[(RequestTx.State[Int32], Int64)] = List#{
            (Idle, 0i64),
            (Open(1), 1i64),
            (Broken(Some(1), permanent()), 1i64),
            (Broken(None, transient()), 0i64)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (state, _) -> RequestTx.transactionsOf(state)))

    /// 閉じる時の結末。Open は COMMIT、接続を持つ Broken は ROLLBACK、借りていなければ Tx 無し。
    @Test
    def testOutcomeOfTable(): Unit \ Assert =
        let table: List[(RequestTx.State[Int32], Outcome)] = List#{
            (Idle, Outcome.NoTransaction),
            (Open(1), Outcome.Committed),
            (Broken(Some(1), permanent()), Outcome.RolledBack),
            (Broken(None, transient()), Outcome.NoTransaction)
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (state, _) -> RequestTx.outcomeOf(state)))

    /// リクエストの行の db.tx.outcome の値。綴りはログの API の一部。
    @Test
    def testOutcomeTextTable(): Unit \ Assert =
        let table = List#{ (Outcome.Committed, "committed"), (Outcome.RolledBack, "rolled_back"), (Outcome.NoTransaction, "none") };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (outcome, _) -> RequestTx.outcomeText(outcome)))

    /// Broken が覚えている最初の失敗。Idle / Open には無い。
    @Test
    def testBrokenByTable(): Unit \ Assert =
        let table: List[(RequestTx.State[Int32], Option[Failure])] = List#{
            (Idle, None),
            (Open(1), None),
            (Broken(Some(1), permanent()), Some(permanent())),
            (Broken(None, transient()), Some(transient()))
        };
        Assert.assertEq(expected = table |> List.map(snd), table |> List.map(match (state, _) -> RequestTx.brokenBy(state)))

}
