CREATE TABLE IF NOT EXISTS event_records (
  id TEXT NOT NULL, source_id TEXT NOT NULL, source_revision TEXT NOT NULL,
  payload TEXT NOT NULL, PRIMARY KEY(id, source_id, source_revision)
);
PRAGMA user_version=2;
