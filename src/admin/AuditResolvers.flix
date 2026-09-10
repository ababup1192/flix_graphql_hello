///
/// 管理 API の AuditEvent（監査の記録）のリゾルバ。積んだ行をそのまま出すだけ。
///
mod AuditResolvers {

    /// type AuditEvent のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.AuditEventResolvers[AdminEff] =
        {
            id         = (_context, source) -> Ok(AdminMapping.idOfUlid(source#id)),
            actor      = (_context, source) -> Ok(source#actor),
            action     = (_context, source) -> Ok(source#action),
            targetKind = (_context, source) -> Ok(source#targetKind),
            targetId   = (_context, source) -> Ok(source#targetId),
            detail     = (_context, source) -> Ok(JsonValue.fromJson(source#detail)),
            createdAt  = (_context, source) -> Ok(Timestamp.toIso8601(source#createdAt))
            | GeneratedAdmin.auditEventDefaults()
        }

}
