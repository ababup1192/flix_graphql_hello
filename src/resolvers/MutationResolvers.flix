///
/// type Mutation のリゾルバ。`make scaffold` が作った雛形で、人が所有する（作り直されない）。
///
mod MutationResolvers {

    /// Mutation.increment
    pub def increment(): Generated.MutationIncrementResolver[AppEff] =
        (context, by) -> Counter.increment(context, by)

    /// type Mutation のリゾルバ一式
    pub def resolvers(): Generated.MutationResolvers[AppEff] =
        { increment = increment() }

}
