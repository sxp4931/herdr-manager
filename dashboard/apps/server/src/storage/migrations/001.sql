CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS quota_samples (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  sampled_at TEXT NOT NULL,
  payload_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_quota_samples_provider_time
  ON quota_samples (provider, sampled_at);

CREATE TABLE IF NOT EXISTS source_health (
  source_id TEXT PRIMARY KEY,
  payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_state (
  id TEXT PRIMARY KEY,
  session_identity TEXT,
  status TEXT NOT NULL,
  entered_at TEXT NOT NULL,
  last_output_at TEXT,
  observed_at TEXT NOT NULL,
  payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS git_cache (
  id TEXT PRIMARY KEY,
  payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS alerts (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  payload_json TEXT NOT NULL
);
