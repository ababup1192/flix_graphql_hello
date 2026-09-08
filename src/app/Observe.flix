///
/// リクエストの行に乗せる属性を、Route の handler や 404 / 405 の分岐から積む口。Main が extra の Ref で受け、処理の後にリクエストの行に乗せる。
/// 後から積んだ属性が勝つ。
///
/// WhyNot: RouteRequest に関数の値（Context の observe と同じ形）を持たせないのは、それを呼ぶ handler 全部と Server.handle に IO が付き、
/// テストの署名まで広がるため。effect なら Ref を持たない handler で捨てたり集めたりできる。
///
pub eff Observe {
    def note(fields: Log.Fields): Unit
}

mod Observe {

    ///
    /// Static の Ref に積む。Main の serveRequest が使う。
    ///
    pub def runWithRef(extra: Ref[Log.Fields, Static], f: Unit -> a \ ef): a \ (ef - Observe) + IO =
        run f() with handler Observe {
            def note(fields, resume) = {
                Ref.put(Ref.get(extra) |> Log.Fields.merge(fields), extra);
                resume(())
            }
        }

    ///
    /// 捨てる。テストで属性を見ない時。
    ///
    pub def ignore(f: Unit -> a \ ef): a \ ef - Observe =
        run f() with handler Observe {
            def note(_fields, resume) = resume(())
        }

    ///
    /// 積んだ属性を結果と一緒に返す。テスト用。
    ///
    pub def collect(f: Unit -> a \ ef): (a, Log.Fields) \ ef - Observe =
        run {
            (f(), Log.Fields.empty())
        } with handler Observe {
            def note(fields, k) = {
                let (result, later) = k();
                (result, Log.Fields.merge(later, fields))
            }
        }

}
