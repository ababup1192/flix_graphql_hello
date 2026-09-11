-- 鍵の末尾 4 文字。一覧で「.env のどの鍵か」を突き合わせるための目印で、これだけでは鍵にならない。
-- 既存の行は生の鍵を持っていないので空のまま（一覧では「…」で出す）
ALTER TABLE api_keys ADD COLUMN key_hint TEXT NOT NULL DEFAULT '';
