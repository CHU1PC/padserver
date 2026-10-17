-- 承認済みの利用者と, 生のトークン spike-token に対応するセッションを入れる.
INSERT INTO users (id, email, name, created_at, updated_at, role, status)
VALUES ('00000000-0000-0000-0000-000000000001', 'spike@example.invalid', 'spike', now(), now(), 'user', 'approved');
INSERT INTO user_sessions (id, user_id, token_hash, created_at, expires_at, last_seen_at)
VALUES ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001',
        encode(sha256('spike-token'::bytea), 'hex'), now(), now() + interval '1 day', now());
