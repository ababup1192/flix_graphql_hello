///
/// CounterStore effect を SQLite（sqlite-jdbc）で処理するハンドラ。JDBC はこのモジュールに閉じる。
///
/// WhyNot: Connection を使い回さず呼び出しごとに開くのは、sqlite-jdbc の Connection が
/// スレッドセーフではなく、接続ごとのスレッドから同時に触ると壊れるため。
///
mod SqliteCounter {
    import java.lang.Exception
    import java.sql.Connection
    import java.sql.SQLException
    import java.util.Properties
    import org.sqlite.JDBC

    ///
    /// カウンタを保存する SQLite データベース。JDBC の URL を包む。
    ///
    pub enum Database {
        /// "jdbc:sqlite:<ファイルパス>" の形の URL
        case Database(String)
    }

    ///
    /// データベースを開き、カウンタのテーブルと 1 行だけの初期値（0）を用意する。
    ///
    pub def open(path: String): Result[String, Database] \ IO =
        let database = Database.Database("jdbc:sqlite:${path}");
        withConnection(database, connection -> {
            discard connection.createStatement().executeUpdate("CREATE TABLE IF NOT EXISTS counter (id INTEGER PRIMARY KEY CHECK (id = 1), value INTEGER NOT NULL)");
            discard connection.createStatement().executeUpdate("INSERT OR IGNORE INTO counter (id, value) VALUES (1, 0)")
        }) |> Result.map(_ -> database)

    ///
    /// CounterStore の load / increment を SQLite の読み書きに置き換えるハンドラ。
    ///
    pub def runWithSqlite(database: Database, f: Unit -> a \ ef): a \ (ef - CounterStore) + IO =
        run f() with handler CounterStore {
            def load(resume)          = resume(selectValue(database))
            def increment(by, resume) = resume(updateValue(by, database))
        }

    ///
    /// 今の値を読む。
    ///
    def selectValue(database: Database): Result[String, Int32] \ IO =
        withConnection(database, connection -> {
            let rows = connection.createStatement().executeQuery("SELECT value FROM counter WHERE id = 1");
            discard rows.next();
            rows.getInt(1)
        })

    ///
    /// 値を by だけ増やし、増やした後の値を返す。
    ///
    def updateValue(by: Int32, database: Database): Result[String, Int32] \ IO =
        withConnection(database, connection -> {
            let statement = connection.prepareStatement("UPDATE counter SET value = value + ? WHERE id = 1 RETURNING value");
            statement.setInt(1, by);
            let rows = statement.executeQuery();
            discard rows.next();
            rows.getInt(1)
        })

    ///
    /// 接続を開いて f を実行し、必ず閉じる。f が投げた例外はメッセージにして Err で返す。
    ///
    /// WhyNot: 内側の catch を SQLException に絞らないのは、f が RuntimeException を投げたときに
    /// close が飛ばされ、SQLite のファイルロックを握ったままになるため。
    ///
    /// WhyNot: DriverManager.getConnection を使わないのは、Flix が Maven の jar を独自の
    /// クラスローダで読むため ServiceLoader によるドライバの自動登録が効かず、
    /// "No suitable driver" になるため。sqlite-jdbc のドライバを直接呼ぶ。
    ///
    def withConnection(database: Database, f: Connection -> a \ IO): Result[String, a] \ IO =
        let Database.Database(url) = database;
        try {
            let connection: Connection = checked_cast(JDBC.createConnection(url, new Properties()));
            let result = try {
                Ok(f(connection))
            } catch {
                case e: Exception => Err("SQLite error: ${e.getMessage()}")
            };
            connection.close();
            result
        } catch {
            case e: SQLException => Err("SQLite error: ${e.getMessage()}")
        }

}
