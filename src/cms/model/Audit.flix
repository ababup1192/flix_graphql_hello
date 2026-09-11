///
/// 監査に載る主体の種類。`audit_events.actor_kind` の綴りと 1 対 1。
///
/// WhyNot: `ViewerKind` を使い回さない。あちらは「今の身元の見え方」で、PAT は PersonalToken と綴る。監査の綴りは
/// 列に残って二度と変えられないので、短く固定した別の物にする。
///
pub enum ActorKind with Eq, Order, ToString {
    /// ログインの JWT で来た人
    case User
    /// PAT で来た人
    case Pat
    /// プロジェクトの API キー
    case ApiKey
    /// サーバ自身（予約公開の実行など）
    case System
    /// 身元無し（監査に積む操作はできないが、綴りは決めておく）
    case Anonymous
    /// プレビュートークン（同上）
    case Preview
}

mod ActorKind {

    pub def text(kind: ActorKind): String = match kind {
        case ActorKind.User      => "user"
        case ActorKind.Pat       => "pat"
        case ActorKind.ApiKey    => "api_key"
        case ActorKind.System    => "system"
        case ActorKind.Anonymous => "anonymous"
        case ActorKind.Preview   => "preview"
    }

    /// 列の綴りから。知らない綴り（将来の版が積んだ物）は User に倒さず None。
    pub def parse(text: String): Option[ActorKind] = match text {
        case "user"      => Some(ActorKind.User)
        case "pat"       => Some(ActorKind.Pat)
        case "api_key"   => Some(ActorKind.ApiKey)
        case "system"    => Some(ActorKind.System)
        case "anonymous" => Some(ActorKind.Anonymous)
        case "preview"   => Some(ActorKind.Preview)
        case _           => None
    }

}

///
/// 監査に載る主体。表示名（`actor`）だけでは鍵の同名再発行や email の変更で追えないので、種類と id を別に持つ。
///
/// - kind: 種類
/// - id: 人なら users.id、鍵なら鍵の名前、system は空
/// - name: 表示名。人は email、鍵は "api-key:<鍵の名前>"（版の author と同じ形）
///
pub type alias ActorRef = { kind = ActorKind, id = String, name = String }

///
/// 監査の 1 件（読む値）。積む側は `AuditChange`（src/cms/Audit.flix）で、これは積んだ行を読み返した形。
///
/// - actorKind / actorId: 主体の種類と id（`ActorRef`）。列を足す前の行は actorId が空
/// - actor: した人の表示名。人は email、鍵は "api-key:<鍵の名前>"（版の author と同じ形）
/// - action: `<対象>.<した事>`（`member.role_changed` / `type.deleted` など）
/// - targetKind / targetId: 対象の種類と、後から人が引ける値
/// - detail: 付随する値。役割なら {"role": "editor"}、鍵の発行なら {"name": "CI"}
///
pub type alias AuditEvent = { id = String, actorKind = ActorKind, actorId = String, actor = String, action = String, targetKind = String, targetId = String, detail = Util.Json.Json, createdAt = Timestamp.Timestamp }

///
/// 監査を読む時の絞り込み。全部任意で、無ければ今のプロジェクトの全部を新しい順に。
///
/// - max: 件数の上限
/// - after: 前のページの最後の id（それより古い物から）
/// - actorKind: 主体の種類
/// - actionPrefix: action の前方一致（"webhook." で Webhook の全部）
/// - since / until: 時刻の範囲（since 以上 until 未満）。id が ULID なので id の範囲で引く
///
pub type alias AuditQuery = { max = Int64, after = Option[String], actorKind = Option[ActorKind], actionPrefix = Option[String], since = Option[Timestamp.Timestamp], until = Option[Timestamp.Timestamp] }

///
/// 監査の絞り込みだけ（`AuditQuery` からページの引数を除いた物）。件数を数える時と、書き出した事を記録する時の形。
///
/// - actorKind / actionPrefix / since / until: `AuditQuery` と同じ意味
///
pub type alias AuditFilter = { actorKind = Option[ActorKind], actionPrefix = Option[String], since = Option[Timestamp.Timestamp], until = Option[Timestamp.Timestamp] }

mod AuditFilter {

    use Util.Json.Json

    /// 絞り込み無し。
    pub def all(): AuditFilter = { actorKind = None, actionPrefix = None, since = None, until = None }

    /// ページの引数を足して `AuditQuery` に。
    pub def toQuery(max: Int64, after: Option[String], filter: AuditFilter): AuditQuery =
        { max = max, after = after, actorKind = filter#actorKind, actionPrefix = filter#actionPrefix, since = filter#since, until = filter#until }

    ///
    /// 監査の detail に残す形。キーは管理 API の引数と同じ（actorKind / action / since / until）で、渡していない物はキーごと無い。
    /// actorKind は列の綴り（user / api_key …）、時刻は ISO 8601。
    ///
    pub def toJson(filter: AuditFilter): Json =
        List#{
            ("actorKind", filter#actorKind |> Option.map(kind -> Json.JString(ActorKind.text(kind)))),
            ("action", filter#actionPrefix |> Option.map(Json.JString)),
            ("since", filter#since |> Option.map(at -> Json.JString(Timestamp.toIso8601(at)))),
            ("until", filter#until |> Option.map(at -> Json.JString(Timestamp.toIso8601(at))))
        }
            |> List.filterMap(match (key, value) -> value |> Option.map(found -> (key, found)))
            |> List.toMap
            |> Json.JObject

}

///
/// 監査の書き出しの形式。管理 API の `AuditExportFormat` と 1 対 1。
///
pub enum AuditExportFormat with Eq, Order, ToString {
    /// UTF-8 with BOM の CSV。detail は JSON の文字列を 1 セルに
    case Csv
    /// JSON Lines。detail は入れ子のまま
    case Json
}

mod AuditExportFormat {

    /// 監査の targetId に使う綴り。
    pub def text(format: AuditExportFormat): String = match format {
        case AuditExportFormat.Csv  => "csv"
        case AuditExportFormat.Json => "json"
    }

}
