-- audit_events: 主体を種類と id で持つ。actor（表示名）だけだと、鍵の名前を付け直した時や
-- 同じ email の人が別の user になった時に、後から「誰」を機械で引けない。
-- actor_kind は user / pat / api_key / system。actor_id は人なら users.public_id（内部の連番は外に出さない）、鍵なら名前。
-- この migration より前の行は actor_id が空（表示名しか残していない）。
ALTER TABLE audit_events ADD COLUMN actor_kind TEXT NOT NULL DEFAULT 'user';
ALTER TABLE audit_events ADD COLUMN actor_id TEXT NOT NULL DEFAULT '';

-- action の前方一致（"webhook." で Webhook の記録だけ）を新しい順で引く。
-- text_pattern_ops でないと LIKE 'x%' が索引を使わない（collation が C でない DB）。
CREATE INDEX audit_events_action_idx ON audit_events (project_id, action text_pattern_ops, id DESC);
