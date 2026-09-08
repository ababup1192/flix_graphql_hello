///
/// 読むだけの文書（mutation の無い GraphQL）を 1 リクエスト 1 Tx で読むための状態。
/// 接続は最初の SQL で借り（Idle → Open）、リゾルバごとに handler を入れ直しながら同じ接続で読み、
/// 応答の直前に COMMIT して返す。DB の失敗が 1 度でも出れば Broken で、残りのフィールドは SQL を出さず INTERNAL、最後に ROLLBACK。
///
/// 遷移の判断はここ（純粋）に置き、接続に触る物は DbRunner（openRequestTx / transactShared / closeRequestTx）。
///
/// WhyNot: 文書全体を 1 つの withLazyTx で包まないのは、リゾルバは graphql-java の Java コールバックの中で呼ばれ、
/// effect の handler がそこを越えないため。接続を値（Context の Handle）で持ち込み、フィールドごとに handler を入れ直す。
///
/// WhyNot: 業務エラー（CmsErr）で Broken にしないのは、読むだけの Tx では業務エラーが Tx を汚さず、他のフィールドは独立に答えられるため。
/// DB の失敗で Broken にするのは、接続の状態（aborted な Tx、切れた接続）が同じ接続を使う残りのフィールドに波及するため。
///
mod RequestTx {

    import java.sql.Connection

    use DbError.Failure

    ///
    /// リクエストの Tx の状態。c は接続の型（本番は java.sql.Connection、テストは Int32）。
    ///
    pub enum State[c] with Eq, ToString {
        /// まだ SQL を出していない（接続を借りていない）
        case Idle
        /// 接続を借りて Tx を開いた
        case Open(c)
        /// DB の失敗が出た。接続があれば最後に ROLLBACK する。失敗は最初の 1 つを覚える
        case Broken(Option[c], Failure)
    }

    ///
    /// 閉じた時の結末。リクエストの行の db.tx.outcome。
    ///
    pub enum Outcome with Eq, ToString {
        case Committed
        case RolledBack
        case NoTransaction
    }

    ///
    /// 1 フィールドの結果で次の状態を決める。DB の失敗（外側の Result の Err）だけが Broken にし、業務エラー（内側の Err）は状態を変えない。
    /// Broken は変わらない（最初の失敗を覚えたまま）。
    ///
    pub def afterField(state: State[c], outcome: Result[Failure, Result[e, a]]): State[c] = match (state, outcome) {
        case (State.Open(conn), Err(failure)) => State.Broken(Some(conn), failure)
        case (State.Idle, Err(failure))       => State.Broken(None, failure)
        case (found, _)                       => found
    }

    ///
    /// このフィールドで SQL を出してよいか。Broken なら出さない。
    ///
    pub def canRun(state: State[c]): Bool = match state {
        case State.Broken(_, _) => false
        case _                  => true
    }

    ///
    /// リクエストの行に載せる Tx の数。接続を借りたら 1、借りなかったら 0。
    ///
    pub def transactionsOf(state: State[c]): Int64 = match state {
        case State.Open(_)          => 1i64
        case State.Broken(Some(_), _) => 1i64
        case _                      => 0i64
    }

    ///
    /// 閉じる時の結末。
    ///
    pub def outcomeOf(state: State[c]): Outcome = match state {
        case State.Open(_)            => Outcome.Committed
        case State.Broken(Some(_), _) => Outcome.RolledBack
        case _                        => Outcome.NoTransaction
    }

    ///
    /// db.tx.outcome の文字列。ログの API の一部なので綴りは変えない。
    ///
    pub def outcomeText(outcome: Outcome): String = match outcome {
        case Outcome.Committed     => "committed"
        case Outcome.RolledBack    => "rolled_back"
        case Outcome.NoTransaction => "none"
    }

    ///
    /// Broken が覚えている最初の失敗。
    ///
    pub def brokenBy(state: State[c]): Option[Failure] = match state {
        case State.Broken(_, failure) => Some(failure)
        case _                        => None
    }

    ///
    /// 1 フィールドの試み。Broken の後は走らせず（Skipped）、最初の失敗を値で返す。
    /// Ran の Infrastructure だけが Error の行になり、Skipped は行を出さない（洪水を避ける）。
    ///
    pub enum Attempt[a] {
        case Ran(Result[ApplicationFailure, a])
        case Skipped(Failure)
    }

    ///
    /// リクエストの Tx の持ち物。Context に値として載せ、フィールドを跨いで同じ物を見る。
    ///
    /// - openConnection: 最初の SQL で接続を借りて Tx を開く（借りる・BEGIN・READ ONLY・RLS の印まで）。DbRunner が組む
    /// - state: 今の状態
    /// - openedAt: 接続を借りた時刻（UNIX ミリ秒）。db.tx.held_ms 用。借りていなければ None
    /// - lastClosedAt: プロセスで最後に Tx を閉じた時刻を置く場所（SelfHeal が「満杯」と「壊れた」を分けるのに読む）
    ///
    /// WhyNot: 接続を開く関数を値で持つのは、DB 無しのテストがプールを組まずに Handle を作れるようにするため。
    ///
    pub type alias Handle = {
        openConnection = Unit -> Connection \ {IO, TransientDbErr, DbErr},
        state = Ref[State[Connection], Static],
        openedAt = Ref[Option[Int64], Static],
        lastClosedAt = Ref[Option[Int64], Static] }

    ///
    /// 閉じた結果。
    ///
    /// - outcome: COMMIT / ROLLBACK / Tx 無し
    /// - transactions: リクエストの行に足す Tx の数（0 か 1）
    /// - brokenBy: Broken にした最初の失敗（error.kind 用）
    /// - commitFailure: COMMIT が失敗した時の失敗（応答は変えず Error の行だけ）
    /// - heldMs: 借りてから閉じるまでのミリ秒。借りていなければ None
    ///
    pub type alias Closed = { outcome = Outcome, transactions = Int64, brokenBy = Option[Failure], commitFailure = Option[Failure], heldMs = Option[Int64] }

}
