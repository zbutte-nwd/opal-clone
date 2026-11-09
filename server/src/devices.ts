import type { Ctx, DeviceRow } from './context.js';
import { evaluate } from './engine/index.js';
import type { LocalSnapshot } from './policy/schemas.js';
import { buildBundle, audit, pruneOverrides } from './policy/service.js';
import { iso, parseJson } from './util.js';

export type DeviceStatus = 'online' | 'idle' | 'stale' | 'revoked' | 'pending';

const MIN = 60_000;

export function deviceStatus(d: DeviceRow, now: Date): DeviceStatus {
  if (d.authorization_status && d.authorization_status !== 'approved') return 'revoked';
  const seen = d.last_seen_at ? Date.parse(d.last_seen_at) : Date.parse(d.created_at);
  const age = now.getTime() - seen;
  if (age >= 24 * 60 * MIN) return 'stale';
  if (d.applied_version < d.latest_version && now.getTime() - Date.parse(d.latest_bumped_at) > 5 * MIN) return 'pending';
  return age < 15 * MIN ? 'online' : 'idle';
}

export function deviceSummary(ctx: Ctx, d: DeviceRow) {
  const bundle = buildBundle(ctx, d);
  const states = evaluate(
    { bundle, localGroups: [], localRules: [], sessions: [], pauses: [], usageLimitHits: [] },
    ctx.now(),
    // Account tz pins evaluation; else the device's reported IANA tz (sent on ack); else UTC.
    bundle.timeZone || d.time_zone || 'UTC',
  );
  const currentState = bundle.groups.map((g) => {
    const s = states[g.id]!;
    return { groupId: g.id, blocked: s.blocked, reason: s.reason, strict: s.strict };
  });
  const reported = parseJson<string[]>(d.blocked_group_ids, []);
  const loc = ctx.db.prepare('SELECT snapshot, received_at FROM device_local WHERE device_id = ?').get(d.id) as
    | { snapshot: string; received_at: string } | undefined;
  return {
    id: d.id,
    name: d.name,
    model: d.model,
    osVersion: d.os_version,
    appVersion: d.app_version,
    status: deviceStatus(d, ctx.now()),
    lastSeenAt: d.last_seen_at,
    appliedVersion: d.applied_version,
    latestVersion: d.latest_version,
    authorizationStatus: d.authorization_status,
    currentState,
    reportedBlockedGroupIds: reported,
    blockedGroupIds: reported,
    hasPushToken: !!d.push_token,
    protectionEnabled: d.protection_enabled == null ? null : !!d.protection_enabled,
    pairedAt: d.created_at,
    /** The phone's last read-only snapshot of phone-made state (display only), or null if it never sent one. */
    local: loc ? { receivedAt: loc.received_at, snapshot: parseJson<LocalSnapshot | null>(loc.snapshot, null) } : null,
  };
}

export const deviceDetail = deviceSummary;

export function touchDevice(ctx: Ctx, deviceId: string): void {
  ctx.db.prepare('UPDATE devices SET last_seen_at = ?, stale_notified_at = NULL WHERE id = ?').run(iso(ctx.now()), deviceId);
}

/** Periodic job: mark stale devices (audit + notifier), expire unlock requests, prune old overrides. */
export async function runMaintenance(ctx: Ctx): Promise<{ stale: number; expired: number; pruned: number }> {
  const now = ctx.now();
  const nowIso = iso(now);
  const cutoff = iso(new Date(now.getTime() - 24 * 60 * MIN));
  const stale = ctx.db
    .prepare(
      `SELECT * FROM devices WHERE stale_notified_at IS NULL AND COALESCE(last_seen_at, created_at) <= ?`,
    )
    .all(cutoff) as DeviceRow[];
  for (const d of stale) {
    ctx.db.prepare('UPDATE devices SET stale_notified_at = ? WHERE id = ?').run(nowIso, d.id);
    audit(ctx, d.admin_id, 'system', 'device.stale', d.id, { lastSeenAt: d.last_seen_at });
    try {
      await ctx.notifier.deviceStale(d);
    } catch (e) {
      ctx.log.error({ err: e }, 'notifier failed');
    }
  }
  const expired = ctx.db
    .prepare("UPDATE unlock_requests SET status = 'expired' WHERE status = 'pending' AND expires_at <= ?")
    .run(nowIso).changes;
  const pruned = pruneOverrides(ctx);
  return { stale: stale.length, expired, pruned };
}
