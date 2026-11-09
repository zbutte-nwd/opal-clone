import Database from 'better-sqlite3';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type DB = Database.Database;

interface Migration { version: number; name: string; sql: string }

export const migrations: Migration[] = [
  {
    version: 1,
    name: 'initial',
    sql: `
CREATE TABLE admins (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE api_keys (
  id TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE,
  prefix TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT
);
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  model TEXT,
  os_version TEXT,
  app_version TEXT,
  token_hash TEXT NOT NULL UNIQUE,
  push_token TEXT,
  push_env TEXT,
  applied_version INTEGER NOT NULL DEFAULT 0,
  latest_version INTEGER NOT NULL DEFAULT 1,
  latest_bumped_at TEXT NOT NULL,
  applied_at TEXT,
  last_seen_at TEXT,
  authorization_status TEXT,
  blocked_group_ids TEXT NOT NULL DEFAULT '[]',
  protection_enabled INTEGER,
  stale_notified_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_devices_admin ON devices(admin_id);
CREATE TABLE pairing_codes (
  code TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  device_name TEXT,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE groups (
  id TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  color_hex TEXT,
  web_domains TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_groups_admin ON groups(admin_id);
CREATE TABLE rules (
  id TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  group_ids TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  action TEXT NOT NULL,
  trigger TEXT NOT NULL,
  strictness TEXT NOT NULL DEFAULT 'flexible',
  priority INTEGER NOT NULL DEFAULT 0,
  max_pauses_per_day INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_rules_admin ON rules(admin_id);
CREATE TABLE overrides (
  id TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  group_ids TEXT NOT NULL,
  action TEXT NOT NULL,
  starts_at TEXT NOT NULL,
  ends_at TEXT,
  issued_at TEXT NOT NULL,
  reason TEXT,
  device_ids TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_overrides_admin ON overrides(admin_id);
CREATE TABLE settings (
  admin_id TEXT PRIMARY KEY REFERENCES admins(id) ON DELETE CASCADE,
  protection_lock TEXT NOT NULL DEFAULT 'partnerPIN',
  allow_local_rules INTEGER NOT NULL DEFAULT 1,
  deny_app_removal INTEGER NOT NULL DEFAULT 1,
  time_zone TEXT
);
CREATE TABLE unlock_requests (
  id TEXT PRIMARY KEY,
  admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  group_ids TEXT NOT NULL DEFAULT '[]',
  minutes INTEGER,
  reason TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  decided_at TEXT,
  override_id TEXT,
  note TEXT
);
CREATE INDEX idx_unlock_admin ON unlock_requests(admin_id, status);
CREATE TABLE events (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  type TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  data TEXT,
  received_at TEXT NOT NULL,
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_events_device_time ON events(device_id, occurred_at DESC);
CREATE TABLE audit_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  admin_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  target TEXT,
  detail TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_audit_admin ON audit_log(admin_id, seq DESC);
`,
  },
  {
    version: 2,
    name: 'device_time_zone',
    sql: `ALTER TABLE devices ADD COLUMN time_zone TEXT;`,
  },
  {
    version: 3,
    name: 'device_local',
    // The phone's read-only snapshot of phone-made state (contracts/device-local.schema.json). Display only.
    sql: `
CREATE TABLE device_local (
  device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  hash TEXT NOT NULL,
  snapshot TEXT NOT NULL,
  received_at TEXT NOT NULL
);`,
  },
  {
    version: 4,
    name: 'group_copied_from',
    // Server copy of a phone-made group (lgrp_…): the phone carries that group's app selection over once.
    sql: `ALTER TABLE groups ADD COLUMN copied_from TEXT;`,
  },
];

export function migrate(db: DB): void {
  db.exec('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)');
  const done = new Set(
    (db.prepare('SELECT version FROM schema_migrations').all() as { version: number }[]).map((r) => r.version),
  );
  for (const m of migrations) {
    if (done.has(m.version)) continue;
    db.transaction(() => {
      db.exec(m.sql);
      db.prepare('INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)').run(
        m.version, m.name, new Date().toISOString(),
      );
    })();
  }
}

export function openDb(path: string): DB {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');
  migrate(db);
  return db;
}
