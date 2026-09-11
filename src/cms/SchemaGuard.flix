///
/// スキーマを変える操作の入口。前後の差から影響を出し、確認していない破壊を止める。
///
/// **条件は「どの操作か」ではなく「影響が空か」。** addField や reorderFields や microCMS の
/// 取り込みを操作の種類で除くと、mutation が増えるたびに例外が増える。影響が空なら通す形なら、
/// 壊さない操作は何も書かずに通り、将来 mutation を足しても規則を書き足すだけで対象になる。
///
/// WhyNot: effect のハンドラや非 pub の封で「見ずには呼べない」を作らない。Flix はどちらも
/// 外の mod から差し替えられる（2026-09-11 に実測）。守りになるのは Tx の中でサーバが数え直す
/// この形だけで、偽の指紋を渡しても再計算で落ちる。
///
mod SchemaGuard {

    ///
    /// 画面が見た影響の指紋。
    ///
    /// WhyNot: 完全一致で見ない。件数は他人が別の entry を保存するたびに動くので、
    /// 一致で止めると確認の画面を開いて考えている間に必ず外れる。増えた時だけ止める。
    ///
    pub type alias Fingerprint = { kinds = List[SchemaEffectKind], published = Int64 }

    ///
    /// スキーマを変える f を包む。前後を撮って差を取り、影響が空なら素通り。
    ///
    /// - expected = None: 影響は無いはずだった。あれば止めて、出した影響を violations で返す
    /// - expected = Some: 画面が見た指紋。見た時より悪くなっていれば止める
    ///
    /// 止める時は f の書き込みごと Tx が巻き戻る（CmsErr は Tx の境界まで上がる）。
    ///
    pub def withImpact(proof: Granted[ManageTypes], expected: Option[Fingerprint], f: Unit -> a \ ef): a \ ef + DbRead + CmsErr + Tenant =
        let reader = Session.readDraftOfTypeManager(proof);
        let before = ContentTypes.list(reader);
        let result = f();
        let changes = SchemaDiff.diff(before, ContentTypes.list(reader));
        // 変わっていなければ数え上げの SQL を 1 本も打たない
        if (List.isEmpty(changes)) result
        else {
            let (fields, types) = SchemaCounts.forChanges(changes);
            let effects = FieldImpact.of(changes, fields, types);
            CmsErr.raiseIfAny(violationsFor(expected, effects));
            result
        }

    ///
    /// 止める理由。影響が無ければ空（通す）。
    ///
    def violationsFor(expected: Option[Fingerprint], effects: List[SchemaEffect]): List[Violation] =
        if (List.isEmpty(effects)) Nil
        else match expected {
            case None     => effects |> List.map(unconfirmed)
            case Some(fp) => if (worsened(fp, effects)) worsening(fp, effects) :: Nil else Nil
        }

    ///
    /// 見た時より悪くなったか。新しい種類が出たか、公開中に当たる件数が増えたか。
    ///
    /// 減った時と、下書きに当たる件数が動いた時は止めない。prune が保存のたびに
    /// 型に無いキーを落とすので、件数は放っておいても減る方向に動く。
    ///
    def worsened(expected: Fingerprint, effects: List[SchemaEffect]): Bool =
        let kinds = effects |> List.map(effect -> effect#kind) |> List.distinct;
        let published = publishedTotal(effects);
        (kinds |> List.exists(kind -> not List.memberOf(kind, expected#kinds))) or published > expected#published

    /// 公開中に当たる件数の合計。List.sum は Int32 だけなので畳む。
    def publishedTotal(effects: List[SchemaEffect]): Int64 =
        effects |> List.foldLeft((acc, effect) -> acc + effect#published, 0i64)

    def unconfirmed(effect: SchemaEffect): Violation =
        Violation.Violation(pathOf(effect), "${describe(effect#kind)}（${effect#draft + effect#published} 件）。影響を確認してから実行してください")

    def worsening(expected: Fingerprint, effects: List[SchemaEffect]): Violation =
        let published = publishedTotal(effects);
        Violation.Violation("expected", "確認時より影響が増えています（公開中 ${expected#published} 件 → ${published} 件）。もう一度確認してください")

    /// 影響の場所。フィールドの物は apiId、型ごとの物は型を指す。
    def pathOf(effect: SchemaEffect): String =
        effect#apiId |> Option.map(apiId -> "fields.${ApiId.text(apiId)}") |> Option.getWithDefault("id")

    def describe(kind: SchemaEffectKind): String = match kind {
        case SchemaEffectKind.ValuesHidden       => "値が API から見えなくなります"
        case SchemaEffectKind.ReferencesHidden   => "参照が API から見えなくなります"
        case SchemaEffectKind.AssetsHidden       => "メディアの参照が API から見えなくなります"
        case SchemaEffectKind.ValuesResurrected  => "削除した値が API に再表示されます"
        case SchemaEffectKind.PublishBlocked     => "公開中のコンテンツが再公開できなくなります"
        case SchemaEffectKind.DraftBlocked       => "下書きの保存ができなくなります"
        case SchemaEffectKind.EntriesRemoved     => "API と一緒にコンテンツが削除されます"
    }

}
