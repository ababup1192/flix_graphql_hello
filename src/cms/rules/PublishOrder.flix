///
/// 複数の entry を公開する順を決める。純粋。参照先が先（深さ優先の後順）、要求した順は保つ、重複は最初の 1 回。
/// 循環と、計画の外の未公開の参照先は違反として返す（順は出すが、そのままでは公開できない）。
///
mod PublishOrder {

    ///
    /// 計画。steps は (entry id, 理由) の公開する順。violations は計画そのものの違反。
    ///
    pub type alias Plan = { steps = List[(EntryId, PlanReason)], violations = List[Violation] }

    /// 辿っている途中の状態。path は今の経路（先頭が今の entry）、onPath はその Set（会員判定用）。order は逆順に積む。
    type alias Walk = { done = Set[EntryId], order = List[EntryId], path = List[EntryId], onPath = Set[EntryId], cycles = List[List[EntryId]] }

    ///
    /// 公開する順を決める。dependencies は entry → 未公開の参照先（直接）。
    /// withDependencies なら requested から辿れる物を全部含め、でなければ requested だけを並べて、外への参照は違反にする。
    ///
    pub def plan(requested: List[EntryId], withDependencies: Bool, dependencies: Map[EntryId, List[EntryId]]): Plan =
        let unique = List.distinct(requested);
        let inPlan = if (withDependencies) closure(dependencies, Set.empty(), unique) else List.toSet(unique);
        let start = { done = Set.empty(), order = Nil, path = Nil, onPath = Set.empty(), cycles = Nil };
        let walked = List.foldLeft(visit(inPlan, dependencies), start, unique);
        let requestedSet = List.toSet(unique);
        {
            steps = walked#order |> List.reverse |> List.map(id -> (id, if (Set.memberOf(id, requestedSet)) PlanReason.Requested else PlanReason.Dependency)),
            violations = (walked#cycles |> List.reverse |> List.map(cycleViolation)) ::: outsideViolations(inPlan, dependencies, walked#order |> List.reverse)
        }

    /// ids から dependencies で辿れる entry の集合。
    def closure(dependencies: Map[EntryId, List[EntryId]], seen: Set[EntryId], ids: List[EntryId]): Set[EntryId] =
        List.foldLeft((acc, id) -> if (Set.memberOf(id, acc)) acc else closure(dependencies, Set.insert(id, acc), targetsOf(dependencies, id)), seen, ids)

    /// entry の未公開の参照先（直接）。表に無ければ無し。
    def targetsOf(dependencies: Map[EntryId, List[EntryId]], id: EntryId): List[EntryId] =
        Map.get(id, dependencies) |> Option.getWithDefault(Nil)

    /// 深さ優先で 1 つの entry を辿る。参照先（計画の中の物だけ）を先に済ませてから自分を order に積む。経路にある物へ戻れば循環。
    def visit(inPlan: Set[EntryId], dependencies: Map[EntryId, List[EntryId]], walk: Walk, id: EntryId): Walk =
        if (Set.memberOf(id, walk#done)) walk
        else if (Set.memberOf(id, walk#onPath)) { cycles = cycleFrom(id, walk#path) :: walk#cycles | walk }
        else {
            let entered = { path = id :: walk#path, onPath = Set.insert(id, walk#onPath) | walk };
            let after = List.foldLeft(visit(inPlan, dependencies), entered, targetsOf(dependencies, id) |> List.filter(target -> Set.memberOf(target, inPlan)));
            { done = Set.insert(id, after#done), order = id :: after#order, path = walk#path, onPath = walk#onPath | after }
        }

    /// 経路（先頭が今の entry）を id まで遡った循環。id → … → id の形。
    def cycleFrom(id: EntryId, path: List[EntryId]): List[EntryId] =
        (id :: (path |> List.takeWhile(found -> found != id) |> List.reverse)) ::: (id :: Nil)

    /// 循環の違反。経路を文言に出す。
    def cycleViolation(cycle: List[EntryId]): Violation =
        Violation.Violation("references", "参照が循環しています: ${cycle |> List.map(EntryId.text) |> List.join(" → ")}")

    /// 計画の外の未公開の参照先の違反（withDependencies: false の時だけ起きる）。steps の順。
    def outsideViolations(inPlan: Set[EntryId], dependencies: Map[EntryId, List[EntryId]], order: List[EntryId]): List[Violation] =
        order |> List.flatMap(id -> targetsOf(dependencies, id) |> List.filter(target -> not Set.memberOf(target, inPlan))
            |> List.map(target -> Violation.Violation("${EntryId.text(id)}.references", "参照先 '${EntryId.text(target)}' が未公開です（withDependencies: true で一緒に公開できます）")))

}
