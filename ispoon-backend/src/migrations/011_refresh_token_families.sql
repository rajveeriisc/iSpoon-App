-- Track refresh-token lineage so replay of a rotated token can invalidate the
-- attacker's token and every descendant minted from the same login session.
ALTER TABLE refresh_tokens
  ADD COLUMN IF NOT EXISTS family_id UUID,
  ADD COLUMN IF NOT EXISTS parent_token_id BIGINT REFERENCES refresh_tokens(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS replaced_by_token_id BIGINT REFERENCES refresh_tokens(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS replay_detected_at TIMESTAMPTZ;

UPDATE refresh_tokens
SET family_id = uuid_generate_v4()
WHERE family_id IS NULL;

ALTER TABLE refresh_tokens
  ALTER COLUMN family_id SET DEFAULT uuid_generate_v4(),
  ALTER COLUMN family_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_family
  ON refresh_tokens(family_id);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_active_family
  ON refresh_tokens(family_id, expires_at)
  WHERE revoked_at IS NULL;
