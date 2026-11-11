PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS articles (
  id TEXT NOT NULL, revision TEXT NOT NULL, payload TEXT NOT NULL, collected_at TEXT NOT NULL,
  PRIMARY KEY(id, revision)
);
CREATE TABLE IF NOT EXISTS attempts (
  id INTEGER PRIMARY KEY, article_id TEXT, revision TEXT, stage TEXT NOT NULL,
  status TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS impacts (
  id TEXT PRIMARY KEY, event_id TEXT NOT NULL, version INTEGER NOT NULL,
  semantic_hash TEXT NOT NULL, payload TEXT NOT NULL, assertion_at TEXT
);
CREATE TABLE IF NOT EXISTS impact_history (
  impact_id TEXT NOT NULL, version INTEGER NOT NULL, payload TEXT NOT NULL,
  PRIMARY KEY(impact_id, version)
);
CREATE TABLE IF NOT EXISTS schedules (
  user_id TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
  PRIMARY KEY(user_id, id)
);
CREATE TABLE IF NOT EXISTS decisions (
  user_id TEXT NOT NULL, schedule_id TEXT NOT NULL, impact_id TEXT NOT NULL, payload TEXT NOT NULL,
  PRIMARY KEY(user_id, schedule_id, impact_id)
);
CREATE TABLE IF NOT EXISTS decision_history (
  id INTEGER PRIMARY KEY, user_id TEXT NOT NULL, schedule_id TEXT NOT NULL, impact_id TEXT NOT NULL, payload TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS notifications (
  user_id TEXT NOT NULL, schedule_id TEXT NOT NULL, impact_id TEXT NOT NULL,
  impact_version INTEGER NOT NULL, notification_kind TEXT NOT NULL, payload TEXT NOT NULL, displayed_at TEXT,
  PRIMARY KEY(user_id, schedule_id, impact_id, impact_version, notification_kind)
);
CREATE TABLE IF NOT EXISTS source_runs (
  id INTEGER PRIMARY KEY, payload TEXT NOT NULL, checked_at TEXT NOT NULL
);
PRAGMA user_version=1;
