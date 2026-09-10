///
/// 監査の 1 件（読む値）。積む側は `AuditChange`（src/cms/Audit.flix）で、これは積んだ行を読み返した形。
///
/// - actor: した人。人は email、鍵は "api-key:<鍵の名前>"（版の author と同じ形）
/// - action: `<対象>.<した事>`（`member.role_changed` / `type.deleted` など）
/// - targetKind / targetId: 対象の種類と、後から人が引ける値
/// - detail: 付随する値。役割なら {"role": "editor"}、鍵の発行なら {"name": "CI"}
///
pub type alias AuditEvent = { id = String, actor = String, action = String, targetKind = String, targetId = String, detail = Util.Json.Json, createdAt = Timestamp.Timestamp }
