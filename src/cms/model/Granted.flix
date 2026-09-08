///
/// 権限の証明。`Session.grant()` / `Session.grantOn(resource)` だけが作り、ユースケースの pub の入口が引数で受ける。
/// p は権限の印の型（下の ReadDraft / WriteEntries / …。Permission の腕と 1 対 1）で、値は持たない（phantom）。
/// 証明を要る所に別の権限の証明を渡すと型で落ち、証明を作らずに呼ぶと引数が足りずに落ちる。
///
/// WhyNot: Permission の値を引数にしないのは、呼ぶ側が任意の Permission を作れて証明にならないため。
/// 本体（`Session.Granted`）が mod Session の中にあるのは、Flix の enum の case が型と同じ可視性を持ち case だけを隠せないので、
/// 中身に非 pub の `Session.Seal` を入れて、作れるのを Session の中だけにするため。ここは署名で短く書くための alias。
///
pub type alias Granted[p] = Session.Granted[p]

///
/// 印の型から実行時の Permission を引く。印の型ごとに instance を 1 つ付ける。
///
/// WhyNot: `permission(): Permission` のように証明を受けない形にしないのは、Flix の trait の署名には型変数 p が
/// 現れなければならず、p が phantom の Granted は値として渡す以外に p を決める手が無いため。
///
pub trait Perm[p] {
    pub def permission(proof: Granted[p]): Permission
}

// ---- 印の型（Permission の腕と 1 対 1）----

/// 下書きと型の定義を読む
pub enum ReadDraft
/// entry の作成・更新・削除（下書き）
pub enum WriteEntries
/// 公開と取り下げ
pub enum PublishEntries
/// 型とフィールドの編集
pub enum ManageTypes
/// asset のアップロードと削除
pub enum ManageAssets
/// メンバーの招待と役割
pub enum ManageMembers
/// API キーの発行と失効
pub enum ManageApiKeys
/// プロジェクトの設定と削除
pub enum ManageProject

instance Perm[ReadDraft] {
    pub def permission(_proof: Granted[ReadDraft]): Permission = Permission.ReadDraft
}

instance Perm[WriteEntries] {
    pub def permission(_proof: Granted[WriteEntries]): Permission = Permission.WriteEntries
}

instance Perm[PublishEntries] {
    pub def permission(_proof: Granted[PublishEntries]): Permission = Permission.PublishEntries
}

instance Perm[ManageTypes] {
    pub def permission(_proof: Granted[ManageTypes]): Permission = Permission.ManageTypes
}

instance Perm[ManageAssets] {
    pub def permission(_proof: Granted[ManageAssets]): Permission = Permission.ManageAssets
}

instance Perm[ManageMembers] {
    pub def permission(_proof: Granted[ManageMembers]): Permission = Permission.ManageMembers
}

instance Perm[ManageApiKeys] {
    pub def permission(_proof: Granted[ManageApiKeys]): Permission = Permission.ManageApiKeys
}

instance Perm[ManageProject] {
    pub def permission(_proof: Granted[ManageProject]): Permission = Permission.ManageProject
}

// ---- 権限でなく来かたの印 ----

///
/// ログインの JWT で来た本人（かサーバ自身）。鍵や PAT の発行の入口が要求する（鍵で鍵を作る道を塞ぐ）。
/// Permission の腕ではないので Perm の instance は無く、`Session.grant()` では作れない。作るのは `Session.grantInteractive()` だけ。
///
pub enum Interactive
