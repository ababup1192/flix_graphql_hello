///
/// 監査に残す出来事。版の残らない変更（メンバー・役割・鍵・型・Webhook・asset・公開範囲と、版を作らない entry の取り下げ・削除、
/// 予約公開の実行）だけを持つ。ユースケースが 1 つ作って `Audit.record` に渡す。
///
/// WhyNot: entry の編集と手での公開をここに入れないのは、`entry_versions` が誰が・いつ・どんな中身にしたかを版として全部持っていて、
/// 監査としてはそちらの方が強いため。二重に持つと、片方だけ残る形が作れてしまう。取り下げと論理削除は版を作らないので積む。
///
pub enum AuditChange with Eq {
    /// 招待した（既にログイン済みの人はその場でメンバーになる）
    case MemberInvited(String, Role)
    /// メンバーの役割を変えた
    case MemberRoleChanged(UserId, Role)
    /// メンバーを外した
    case MemberRemoved(UserId)
    /// 招待を取り消した
    case InvitationCancelled(String)
    /// プロジェクトの API キーを発行した（公開 id, 名前）
    case ApiKeyCreated(String, String)
    /// API キーを失効させた
    case ApiKeyRevoked(String)
    /// content type を作った / 直した / 消した。直した・消した物は変更前の姿を持つ（SchemaSnapshot）。消した物は物理削除した entry の件数も
    case TypeCreated(ApiId)
    case TypeUpdated(ApiId, Util.Json.Json)
    case TypeDeleted(ApiId, Util.Json.Json, Int32)
    /// フィールドを足した / 直した / 消した（型の apiId, フィールドの apiId, 変更前の姿）
    case FieldAdded(ApiId, String)
    case FieldUpdated(ApiId, String, Util.Json.Json)
    case FieldRemoved(ApiId, String, Util.Json.Json)
    /// 最上位のフィールドを並べ替えた（変更前の並び）
    case FieldsReordered(ApiId, Util.Json.Json)
    /// プロジェクトの公開範囲を変えた（プロジェクト slug, 前, 後）
    case ProjectVisibilityChanged(String, Visibility, Visibility)
    /// Webhook を作った / 直した / 消した（公開 id, 姿。直した・消した物は変更前の姿。AuditSnapshot.ofWebhook）
    case WebhookCreated(String, Util.Json.Json)
    case WebhookUpdated(String, Util.Json.Json)
    case WebhookDeleted(String, Util.Json.Json)
    /// 配信をもう 1 度送る番にした（配信の id）
    case WebhookRedelivered(String)
    /// asset を ready にした / 消した（id, 姿。消した物は変更前の姿。AuditSnapshot.ofAsset）
    case AssetConfirmed(AssetId, Util.Json.Json)
    case AssetDeleted(AssetId, Util.Json.Json)
    /// entry の公開を取り下げた / ゴミ箱に入れた（id, 型の apiId, その時点の版）
    case EntryUnpublished(EntryId, ApiId, Int32)
    case EntryDeleted(EntryId, ApiId, Int32)
    /// 予約公開を実行した（id, 型の apiId, 公開した版, 予約の時刻）。手で公開した物は版が author を持つので積まない
    case EntryPublishedBySchedule(EntryId, ApiId, Int32, Timestamp.Timestamp)
}

///
/// 監査の記録。業務の書き込みと同じ Tx で 1 行積む。
///
/// WhyNot: `DbRunner.transact` で全 mutation をまとめて 1 か所で積まないのは、そこに揃っているのが主体と
/// プロジェクトだけで、何をどの対象にしたかが無いため。操作名だけの記録は監査に使えない。
///
/// WhyNot: 出来事の表（events）+ consumer にしないのは、この記録の消費者が監査の 1 つだけで、業務の Tx の中で終わるため
/// （`Publishing` と同じ判断。[docs/design/cdn.md]）。
///
/// WhyNot: 証明（`Granted[p]`）を取らないのは、記録を積むのは操作の結果で、誰ができるかは各ユースケースの入口が
/// 既に決めているため（`Webhooks.emit` と同じ）。ここで別の証明を要求すると同じ操作に 2 つの権限が要る事になる。
///
mod Audit {

    use Util.Json.Json

    ///
    /// 積む行。`rowOf` が出来事から作る純粋な値。
    ///
    pub type alias AuditRow = { actorKind = ActorKind, actorId = String, actor = String, action = String, targetKind = String, targetId = String, detail = Json }

    ///
    /// 出来事を今の主体で積む。ユースケースが業務の書き込みと同じ Tx で 1 回呼ぶ。
    ///
    pub def record(change: AuditChange): Unit \ Db + IdGen + Tenant + Session =
        let row = rowOf(Session.actorRef(), change);
        discard AuditQueries.insertAuditEvent({
            id = IdGen.freshUlid(), projectId = Tenant.currentId(),
            actorKind = ActorKind.text(row#actorKind), actorId = row#actorId, actor = row#actor,
            action = row#action, targetKind = row#targetKind, targetId = row#targetId, detail = row#detail })

    ///
    /// 出来事 → 積む行。action は `<対象>.<した事>`、targetId は後から人が引ける値。
    ///
    /// スキーマ・Webhook・asset の変更は detail に変更前の姿を持つ。消した型・フィールドはここからしか組み直せない
    /// （entry と違って版が無い）。作った・足した物は変更前を持たない（元に戻すのは消す事なので、要る物が無い）。
    ///
    /// WhyNot: メンバーや API キーの変更前を入れない。役割は 3 通りしか無く action と targetId から読めて、
    /// 鍵は値を二度と出せないため。
    ///
    /// WhyNot: entry の中身を入れない。版（`entry_versions`）が持っていて、行からは型と版の番号で辿れる。
    ///
    pub def rowOf(actor: ActorRef, change: AuditChange): AuditRow = match change {
        case AuditChange.MemberInvited(email, role)                       => row(actor, "member.invited", "member", email, roleDetail(role))
        case AuditChange.MemberRoleChanged(userId, role)                  => row(actor, "member.role_changed", "member", "${userId}", roleDetail(role))
        case AuditChange.MemberRemoved(userId)                            => row(actor, "member.removed", "member", "${userId}", empty())
        case AuditChange.InvitationCancelled(publicId)                    => row(actor, "invitation.cancelled", "invitation", publicId, empty())
        case AuditChange.ApiKeyCreated(publicId, name)                    => row(actor, "api_key.created", "api_key", publicId, Json.JObject(Map#{ "name" => Json.JString(name) }))
        case AuditChange.ApiKeyRevoked(publicId)                          => row(actor, "api_key.revoked", "api_key", publicId, empty())
        case AuditChange.TypeCreated(apiId)                               => row(actor, "type.created", "type", "${apiId}", empty())
        case AuditChange.TypeUpdated(apiId, was)                          => row(actor, "type.updated", "type", "${apiId}", before(was))
        case AuditChange.TypeDeleted(apiId, was, purged)                  => row(actor, "type.deleted", "type", "${apiId}", Json.JObject(Map#{ "before" => was, "purgedEntries" => number(purged) }))
        case AuditChange.FieldAdded(apiId, field)                         => row(actor, "field.added", "field", "${apiId}.${field}", empty())
        case AuditChange.FieldUpdated(apiId, field, was)                  => row(actor, "field.updated", "field", "${apiId}.${field}", before(was))
        case AuditChange.FieldRemoved(apiId, field, was)                  => row(actor, "field.removed", "field", "${apiId}.${field}", before(was))
        case AuditChange.FieldsReordered(apiId, was)                      => row(actor, "fields.reordered", "type", "${apiId}", before(was))
        case AuditChange.ProjectVisibilityChanged(slug, was, now)         => row(actor, "project.visibility_changed", "project", slug, Json.JObject(Map#{ "before" => Json.JString(Visibility.text(was)), "after" => Json.JString(Visibility.text(now)) }))
        case AuditChange.WebhookCreated(publicId, snapshot)               => row(actor, "webhook.created", "webhook", publicId, snapshot)
        case AuditChange.WebhookUpdated(publicId, was)                    => row(actor, "webhook.updated", "webhook", publicId, before(was))
        case AuditChange.WebhookDeleted(publicId, was)                    => row(actor, "webhook.deleted", "webhook", publicId, before(was))
        case AuditChange.WebhookRedelivered(deliveryId)                   => row(actor, "webhook.redelivered", "webhook_delivery", deliveryId, empty())
        case AuditChange.AssetConfirmed(id, snapshot)                     => row(actor, "asset.confirmed", "asset", AssetId.text(id), snapshot)
        case AuditChange.AssetDeleted(id, was)                            => row(actor, "asset.deleted", "asset", AssetId.text(id), before(was))
        case AuditChange.EntryUnpublished(id, apiId, version)             => row(actor, "entry.unpublished", "entry", EntryId.text(id), entryDetail(apiId, version, Nil))
        case AuditChange.EntryDeleted(id, apiId, version)                 => row(actor, "entry.deleted", "entry", EntryId.text(id), entryDetail(apiId, version, Nil))
        case AuditChange.EntryPublishedBySchedule(id, apiId, version, at) => row(actor, "entry.published", "entry", EntryId.text(id), entryDetail(apiId, version, ("scheduledFor", Json.JString(Timestamp.toIso8601(at))) :: Nil))
    }

    /// 行を組む。
    def row(actor: ActorRef, action: String, targetKind: String, targetId: String, detail: Json): AuditRow =
        { actorKind = actor#kind, actorId = actor#id, actor = actor#name, action = action, targetKind = targetKind, targetId = targetId, detail = detail }

    /// 役割の付く出来事の詳細。
    def roleDetail(role: Role): Json = Json.JObject(Map#{ "role" => Json.JString(Role.text(role)) })

    /// entry の出来事の詳細。型と、その時点の版の番号（中身は版から辿る）に、出来事ごとの値を足した物。
    def entryDetail(apiId: ApiId, version: Int32, extra: List[(String, Json)]): Json =
        Json.JObject(List.toMap(("typeApiId", Json.JString(ApiId.text(apiId))) :: ("version", number(version)) :: extra))

    /// 変更前の姿を持つ出来事。キーを 1 つに決めておけば、後から読む側が種類ごとに探さずに済む。
    def before(was: Json): Json = Json.JObject(Map#{ "before" => was })

    /// 詳細の無い出来事。
    def empty(): Json = Json.JObject(Map.empty())

    /// 整数の値。
    def number(n: Int32): Json = Json.JNumber(Int32.toBigDecimal(n))

    ///
    /// 新しい順に読む。今のプロジェクトの分だけ（RLS の印が効く）。絞り込みは `AuditQuery`（全部任意）。
    /// since / until は id が ULID なので、その時刻の最小の ULID に変えて id の範囲で引く（index が効く）。
    ///
    pub def recent(_proof: Granted[ManageMembers], filter: AuditQuery): List[AuditEvent] \ DbRead + Tenant =
        AuditQueries.listAuditEvents({
            projectId = Tenant.currentId(), max = filter#max, afterId = filter#after,
            actorKind = filter#actorKind |> Option.map(ActorKind.text),
            actionPrefix = filter#actionPrefix,
            sinceId = filter#since |> Option.map(at -> Ulid.lowerBoundAt(Timestamp.toEpochMillis(at))),
            untilId = filter#until |> Option.map(at -> Ulid.lowerBoundAt(Timestamp.toEpochMillis(at))) })
            |> List.map(toEvent)

    ///
    /// 絞り込み無しで新しい順に max 件。
    ///
    pub def latest(proof: Granted[ManageMembers], max: Int64): List[AuditEvent] \ DbRead + Tenant =
        recent(proof, { max = max, after = None, actorKind = None, actionPrefix = None, since = None, until = None })

    /// 行を読む値に。
    ///
    /// WhyNot: 知らない actor_kind（新しい版が積んだ物を古い版が読んだ時）で読むのを止めない。監査は読めない事の方が困るので User に倒す。
    def toEvent(found: AuditQueries.ListAuditEventsRow): AuditEvent =
        { id = found#id, actorKind = ActorKind.parse(found#actorKind) |> Option.getWithDefault(ActorKind.User), actorId = found#actorId, actor = found#actor,
          action = found#action, targetKind = found#targetKind, targetId = found#targetId, detail = found#detail, createdAt = found#createdAt }

}
