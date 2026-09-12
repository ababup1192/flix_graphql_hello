-- entry_versions を audit_events と同じ append-only にする。
-- 版は「誰が・いつ・どんな中身にしたか」の記録で、監査（audit_events）が entry の編集と手での公開を
-- 積まないのは版がそれを持っているからなので、版の方が弱いと記録がどこにも残らない形が作れる。

-- RLS。1 本の policy（USING + WITH CHECK）を SELECT と INSERT の 2 本に分ける。
-- UPDATE と DELETE はどの policy にも当たらないので、FORCE の下ではアプリも表の所有者も書き換えられない。
-- 保持の都合で古い行を消す時は、この policy を足す migration を書く（消せる事を記録に残す）。
DROP POLICY entry_versions_project ON entry_versions;
CREATE POLICY entry_versions_read ON entry_versions FOR SELECT
    USING (project_id = nullif(current_setting('app.project_id', true), '')::bigint);
CREATE POLICY entry_versions_append ON entry_versions FOR INSERT
    WITH CHECK (project_id = nullif(current_setting('app.project_id', true), '')::bigint);

-- entry への外部キーをやめる。content type を消すと残っていたゴミ箱の entry を物理削除する
-- （ContentTypes.delete → purgeDeletedEntries）ので、CASCADE のままだと公開の記録がそこで消える。
--
-- WhyNot: RESTRICT にしないのは、版が 1 つでもあると content type が消せなくなり、
-- 「先に entry を消してください」で詰むため。SET NULL にしないのは、entry_id を失った版は
-- どの entry の記録か読めず、残す意味が無いため。audit_events も対象を target_id の TEXT で持ち、
-- 外部キーを張っていない（消えた物の記録を残すのが役目なので、参照先の生死に縛られない）。
ALTER TABLE entry_versions DROP CONSTRAINT entry_versions_entry_id_fkey;
