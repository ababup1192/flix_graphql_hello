///
/// PublishOrder: 公開する順（依存が先）。純粋。
///
/// 入力は要求した id の列・withDependencies・entry → 未公開の参照先（直接）の表。
/// 出力は (id, 理由) の順と、計画の違反（循環と、計画の外の未公開の参照先）。
mod TestPublishOrder {

    /// (id, 参照先) の並びを表にする。
    def graph(edges: List[(String, List[String])]): Map[EntryId, List[EntryId]] =
        edges |> List.map(match (source, targets) -> (CmsTestKit.entryId(source), CmsTestKit.entryIds(targets))) |> List.toMap

    /// 計画を (id, 理由) の列と違反の列に平らにする。
    def flatten(plan: PublishOrder.Plan): (List[(String, PlanReason)], List[(String, String)]) =
        (plan#steps |> List.map(match (id, reason) -> (EntryId.text(id), reason)),
         plan#violations |> List.map(violation -> { let Violation.Violation(path, message) = violation; (path, message) }))

    /// 要求した物は REQUESTED、withDependencies で足した参照先は DEPENDENCY で、参照先が先に並ぶ。
    ///
    ///   鎖:    a → b → c            c, b, a
    ///   菱形:  a → b, a → c, b → d, c → d    d, b, c, a（d は 1 回だけ）
    ///   要求同士: a → b（両方要求）  b, a（両方 REQUESTED）
    ///   重複した要求は最初の位置に 1 回
    @Test
    def testPublishOrderDependenciesFirst(): Unit \ Assert =
        let table = List#{
            ((Nil, true, graph(Nil)), (Nil, Nil)),
            ((List#{"a"}, true, graph(List#{("a", Nil)})), (List#{("a", PlanReason.Requested)}, Nil)),
            ((List#{"a"}, true, graph(List#{("a", List#{"b"}), ("b", List#{"c"}), ("c", Nil)})),
                (List#{("c", PlanReason.Dependency), ("b", PlanReason.Dependency), ("a", PlanReason.Requested)}, Nil)),
            ((List#{"a"}, true, graph(List#{("a", List#{"b", "c"}), ("b", List#{"d"}), ("c", List#{"d"}), ("d", Nil)})),
                (List#{("d", PlanReason.Dependency), ("b", PlanReason.Dependency), ("c", PlanReason.Dependency), ("a", PlanReason.Requested)}, Nil)),
            ((List#{"a", "b"}, false, graph(List#{("a", List#{"b"}), ("b", Nil)})),
                (List#{("b", PlanReason.Requested), ("a", PlanReason.Requested)}, Nil)),
            ((List#{"b", "a"}, true, graph(List#{("a", List#{"b"}), ("b", Nil)})),
                (List#{("b", PlanReason.Requested), ("a", PlanReason.Requested)}, Nil)),
            ((List#{"a", "a", "b"}, true, graph(List#{("a", Nil), ("b", Nil)})),
                (List#{("a", PlanReason.Requested), ("b", PlanReason.Requested)}, Nil))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match ((requested, withDependencies, dependencies), _) -> PublishOrder.plan(CmsTestKit.entryIds(requested), withDependencies, dependencies) |> flatten))

    /// 公開できない計画は違反になる。順は出るが ok にはならない。
    ///
    ///   withDependencies: false で計画の外の参照先（a → b、b は要求していない）  "a.references"
    ///   循環 a → b → a                                                       "references"（経路を文言に）
    ///   自己参照 a → a
    @Test
    def testPublishOrderViolations(): Unit \ Assert =
        let table = List#{
            ((List#{"a"}, false, graph(List#{("a", List#{"b"})})),
                (List#{("a", PlanReason.Requested)}, List#{("a.references", "参照先 'b' が未公開です（withDependencies: true で一緒に公開できます）")})),
            ((List#{"a"}, true, graph(List#{("a", List#{"b"}), ("b", List#{"a"})})),
                (List#{("b", PlanReason.Dependency), ("a", PlanReason.Requested)}, List#{("references", "参照が循環しています: a → b → a")})),
            ((List#{"a"}, true, graph(List#{("a", List#{"a"})})),
                (List#{("a", PlanReason.Requested)}, List#{("references", "参照が循環しています: a → a")}))
        };
        Assert.assertEq(
            expected = table |> List.map(snd),
            table |> List.map(match ((requested, withDependencies, dependencies), _) -> PublishOrder.plan(CmsTestKit.entryIds(requested), withDependencies, dependencies) |> flatten))

}
