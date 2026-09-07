///
/// Account API のスキーマ。account.graphql から生成された GeneratedAccount.Resolvers に、src/account/ のリゾルバを当てはめる。
///
mod AccountSchema {

    ///
    /// スキーマを組み立てる。runner は AccountEff を IO に落とす。
    ///
    pub def make(deps: Deps, runner: Runner[AccountEff]): Schema =
        GeneratedAccount.schema({
            queryRoot              = AccountQueryResolvers.resolvers(),
            mutationRoot           = AccountMutationResolvers.resolvers(deps),
            me                     = AccountMeResolvers.resolvers(),
            organization           = AccountOrganizationResolvers.resolvers(),
            organizationMember     = AccountOrganizationMemberResolvers.resolvers(),
            organizationMembership = AccountOrganizationMembershipResolvers.resolvers(),
            project_               = AccountProjectResolvers.resolvers(),
            projectMembership      = AccountProjectMembershipResolvers.resolvers()
        }, runner)

    ///
    /// 本番のエンジン。組めないのは SDL と生成物の不一致なので起動時に止まる。
    ///
    pub def engine(pool: Pool, deps: Deps): Result[String, Graphql.Engine] \ IO =
        Graphql.buildEngine(make(deps, AccountRunner.make(pool, deps)))

}
