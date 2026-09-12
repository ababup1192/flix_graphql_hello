-- 030 が entry_autosaves に置いた「DELETE だけプロジェクト全体」の policy は効かない。
--
-- PostgreSQL は UPDATE / DELETE が WHERE で行を絞る時、DELETE の policy に加えて **SELECT の policy も**
-- その走査に当てる。SELECT が自分の行だけなら、DELETE の USING をプロジェクト全体にしても消せるのは自分の行だけになる
-- （実測: 2 行のうち 1 行しか消えなかった）。つまり entry をゴミ箱に入れた時の「その entry の全員分を捨てる」が
-- 黙って 0 行になり、行が残り続ける。
--
-- 読む境界は緩めない。代わりに「ゴミ箱に入った entry の行」だけをプロジェクト全体で見せる・消せるようにする。
-- 生きている entry の預かり物は今までどおり本人にしか見えず、ゴミ箱に入った entry の預かり物には
-- 管理 API から読む道が無い（読みは全部 ContentEntries の lookup を通り、deleted_at IS NULL で落ちる）。
DROP POLICY entry_autosaves_purge ON entry_autosaves;

CREATE POLICY entry_autosaves_own_delete ON entry_autosaves FOR DELETE
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           AND user_id = nullif(current_setting('app.user_id', true), '')::bigint);

CREATE POLICY entry_autosaves_trashed_read ON entry_autosaves FOR SELECT
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           AND EXISTS (SELECT 1 FROM entries AS e WHERE e.id = entry_autosaves.entry_id AND e.deleted_at IS NOT NULL));

CREATE POLICY entry_autosaves_trashed_delete ON entry_autosaves FOR DELETE
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint
           AND EXISTS (SELECT 1 FROM entries AS e WHERE e.id = entry_autosaves.entry_id AND e.deleted_at IS NOT NULL));
