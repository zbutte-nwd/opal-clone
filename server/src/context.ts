import type { FastifyBaseLogger } from 'fastify';
import type { Config } from './config.js';
import type { DB } from './db.js';
import type { PushService } from './push/service.js';

export interface DeviceRow {
  id: string; admin_id: string; name: string; model: string | null; os_version: string | null; app_version: string | null;
  token_hash: string; push_token: string | null; push_env: string | null; applied_version: number; latest_version: number;
  latest_bumped_at: string; applied_at: string | null; last_seen_at: string | null; authorization_status: string | null; time_zone?: string | null;
  blocked_group_ids: string; protection_enabled: number | null; stale_notified_at: string | null; created_at: string;
}

/** Hook for admin alerting (email etc. is P1). */
export interface Notifier {
  deviceStale(device: DeviceRow): void | Promise<void>;
}
export class LogNotifier implements Notifier {
  constructor(private log: FastifyBaseLogger) {}
  deviceStale(d: DeviceRow): void {
    this.log.warn({ deviceId: d.id, adminId: d.admin_id, lastSeenAt: d.last_seen_at }, 'device is stale (would notify admin)');
  }
}

export interface Ctx {
  db: DB;
  config: Config;
  now(): Date;
  push: PushService;
  notifier: Notifier;
  log: FastifyBaseLogger;
}
