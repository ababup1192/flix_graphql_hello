///
/// テナントの守りが表そのものに付いているかを、表の一覧から検算する。
///
/// TestRlsPg は「policy が効くか」を中身の入った表で見る。こちらは「policy を付け忘れた表が無いか」を見る。
/// 表を足して RLS を書き忘れても、その表を使うテストが無ければ誰も気付かないため。
///
mod TestTenantGuardPg {

    ///
    /// 印の無い Tx が跨いで読む表。バックグラウンドの仕事（BackgroundJobs.tick）が
    /// プロジェクトを跨いで拾うので、RLS を付けると仕事が 0 行しか見えなくなる。
    ///
    /// **顧客の中身そのものを持つ表はここに入れない。** 入れて良いのは、印の無い Tx が
    /// 読む仕事の表だけ（queries/*.q に `// unscoped:` を持つ物）。
    ///
    /// link_cards は外のページの OGP の写し（url が鍵）。取り直しの仕事（LinkCardRefresh.tick）が跨いで拾う。
    def crossProjectTables(): List[String] =
        List#{"cdn_purges", "link_cards", "scheduled_actions", "webhook_deliveries"}

    def scan(sql: String): List[String] \ DbRead + RawSql + DbErr =
        Sql.fetchAs(Decoder.str("relname"), sql, Nil) |> List.sort

    /// project_id 列を持たない表を選ぶ条件（c が対象の pg_class）。
    def withoutProjectId(): String =
        "NOT EXISTS (SELECT 1 FROM information_schema.columns col WHERE col.table_schema = 'public' AND col.table_name = c.relname AND col.column_name = 'project_id')"

    /// entry を参照している表を選ぶ条件。
    def referencesEntries(): String =
        "SELECT c.relname FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_class p ON p.oid = k.confrelid WHERE k.contype = 'f' AND p.relname = 'entries'"

    /// RLS を強制していない public の表を選ぶ条件。
    def unforcedTables(): String =
        "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relforcerowsecurity"

    ///
    /// entry を参照する表は project_id を持つ。
    ///
    /// 持たない表には RLS の policy が書けないので、テナントの守りが `entries` 側の条件だけになる。
    /// 中身（entry_contents.data）はまさにその表で、条件を書き忘れた query 1 本で他のプロジェクトが漏れる。
    ///
    @Test
    def testPgEntryTablesCarryProjectId(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> scan("${referencesEntries()} AND ${withoutProjectId()}"));
        Assert.assertEq(expected = Nil, result)

    ///
    /// project_id を持つ表には FORCE ROW LEVEL SECURITY が付いている。例外は crossProjectTables だけ。
    ///
    /// 一致で見るので、表を足して付け忘れても、逆に例外の表に付けて一覧を直し忘れても落ちる。
    ///
    @Test
    def testPgProjectTablesForceRls(): Unit \ {IO, Assert} =
        let result = PgTestSupport.withDb(() -> scan("${unforcedTables()} AND NOT ${withoutProjectId()}"));
        Assert.assertEq(expected = List.sort(crossProjectTables()), result)

}
