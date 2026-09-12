-- entry_autosaves: 編集中の中身の、利用者ごとの置き場。
--
-- 自動保存が entry_contents の draft の行を上書きすると、「下書きの中身 ≠ 公開の中身」で導く
-- changedSincePublish（EntryRows.toEntry）が立ち、公開中の entry がボードの列を移って
-- チーム全員に「未公開の変更がある」と見える。閲覧のつもりで開いて 1 文字触っただけで、
-- チームに見える状態変化になる。別の表に逃がせば下書きは動かない。
--
-- WhyNot: entry_contents.stage に 'autosave' を足さない。stage は entries.stage と
-- entry_contents.stage で同じ値の集合を使い回していて、CHECK が 2 本（002_entries.sql:12, :24）、
-- Flix の Stage が 8 か所で照合され、うち 3 か所（ContentEntries.flix:157, :344,
-- EntryRows.flix:66）は match ではなく `== Stage.Published` の等値で、新しい値が入っても黙って通る。
-- さらに entry_contents の RLS（024_schema_guard.sql:25）は stage を見ないので自動保存の行が
-- プロジェクトの全員に見え、assets.q の assetHolders と schema_impact.q の listFieldValues は
-- stage で絞っていないので、自動保存にしかない asset が「使用中」になって消せなくなり、
-- スキーマ変更の影響の件数にも混ざる。掃除の口も無い（entry_contents からの DELETE は
-- entries.q:77 の 1 本だけで、常に stage = 'published'）。
--
-- WhyNot: 利用者ごとにせず 1 つの置き場を共有しない。A と B の自動保存が 3 秒ごとに
-- 互いを上書きし合うか、競合を出し合うだけになる。
CREATE TABLE entry_autosaves (
    entry_id TEXT NOT NULL,
    user_id BIGINT NOT NULL,
    project_id BIGINT NOT NULL,
    data JSONB NOT NULL DEFAULT '{}',
    base_version INTEGER NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 引き方は常に（entry, 自分）の 1 行で、掃除は entry_id の前方一致。
    -- entry_contents の PK が (entry_id, stage) で project_id を含めないのと同じ形にする（entries.id は全体で一意）
    PRIMARY KEY (entry_id, user_id),
    -- WhyNot: entry_versions（029）のように外部キーを外さない。版は「消えた物の記録を残す」のが役目だが、
    -- 自動保存は戻す先の entry が無ければ意味が無い一時的な物なので、道連れに消えるのが正しい。
    -- CASCADE にしておくと content type の削除（ContentTypes.delete → purgeDeletedEntries の物理削除）で
    -- 掃除が要らなくなる
    CONSTRAINT entry_autosaves_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE,
    CONSTRAINT entry_autosaves_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT entry_autosaves_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id)
);

-- RLS。プロジェクトの印に加えて、本人の印（app.user_id。TenantTx.stampActor が Actor.User の時だけ置く）で
-- 自分の行しか見えない・書けないようにする。
-- 印の無い主体（API キー・匿名・プレビュー・system）は nullif が NULL になり 1 行も当たらないので、
-- 鍵で叩いても他人の自動保存は読めず、鍵の自動保存も作れない（ドメイン側も Session.currentUser() で止める）。
--
-- DELETE だけプロジェクト全体にするのは、entry をゴミ箱に入れた時に「その entry の全員分」を消すため。
-- 消す側が他人の行を読めないまま消せる形にする（USING はプロジェクトだけ、SELECT は自分だけ）。
ALTER TABLE entry_autosaves ENABLE ROW LEVEL SECURITY;
ALTER TABLE entry_autosaves FORCE ROW LEVEL SECURITY;

CREATE POLICY entry_autosaves_own_read ON entry_autosaves FOR SELECT
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           AND user_id = nullif(current_setting('app.user_id', true), '')::bigint);

CREATE POLICY entry_autosaves_own_insert ON entry_autosaves FOR INSERT
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint
                AND user_id = nullif(current_setting('app.user_id', true), '')::bigint);

CREATE POLICY entry_autosaves_own_update ON entry_autosaves FOR UPDATE
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           AND user_id = nullif(current_setting('app.user_id', true), '')::bigint)
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint
                AND user_id = nullif(current_setting('app.user_id', true), '')::bigint);

CREATE POLICY entry_autosaves_purge ON entry_autosaves FOR DELETE
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
