///
/// 管理 API のスキーマの影響（SchemaImpact / SchemaEffect）の型のリゾルバ。source はドメインの値。
///
mod SchemaEffectResolvers {

    /// type SchemaEffect のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.SchemaEffectResolvers[AdminEff] =
        {
            kind      = (_context, source) -> Ok(AdminMapping.effectKindTo(source#kind)),
            field     = (_context, source) -> Ok(source#apiId |> Option.map(ApiId.text)),
            draft     = (_context, source) -> Ok(Int64.clampToInt32(min = Int32.minValue(), max = Int32.maxValue(), source#draft)),
            published = (_context, source) -> Ok(Int64.clampToInt32(min = Int32.minValue(), max = Int32.maxValue(), source#published))
        }

}

mod SchemaImpactResolvers {

    /// type SchemaImpact のリゾルバ一式
    pub def resolvers(): GeneratedAdmin.SchemaImpactResolvers[AdminEff] =
        {
            safe    = (_context, source) -> Ok(source#safe),
            effects = (_context, source) -> Ok(source#effects)
        }

}
