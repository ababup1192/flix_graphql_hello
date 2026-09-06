///
/// このサーバのリゾルバが使う効果の和。型ごと・フィールドごとのリゾルバは全部この別名で書く。
/// 効果を足すときはここに `+` でつなぐ（`CounterStore + Clock` など）。
///
/// WhyNot: 型ごとに別の効果で書かないのは、Generated.Resolvers[ef] の ef がレコード全体で 1 つで、
/// 型の付いた値には subeffecting が効かず `PostResolvers[Store]` と `AuthorResolvers[Clock]` が
/// 1 つの Resolvers に入らないため。
///
pub type alias AppEff = CounterStore
