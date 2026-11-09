import type { Ctx, DeviceRow } from '../context.js';
import type { BlockGroup, Override, PolicyBundle, Rule, Settings, Trigger } from '../engine/index.js';
import { iso, parseJson } from '../util.js';

// ---- row <-> API shapes ----

interface GroupRow { id: string; name: string; color_hex: string | null; web_domains: string; created_at: string; updated_at: string }
interface RuleRow {
  id: string; name: string; group_ids: string; enabled: number; action: string; trigger: string; strictness: string;
  priority: number; max_pauses_per_day: number | null;
}
interface OverrideRow {
  id: string; group_ids: string; action: string; starts_at: string; ends_at: string | null; issued_at: string;
  reason: string | null; device_ids: string | null;
}
interface SettingsRow { protection_lock: string; allow_local_rules: number; deny_app_removal: number; time_zone: string | null }

export const groupOut = (r: GroupRow): BlockGroup => ({
  id: r.id, name: r.name, ...(r.color_hex ? { colorHex: r.color_hex } : {}),
  webDomains: parseJson<string[]>(r.web_domains, []), source: 'server',
});
export const ruleOut = (r: RuleRow): Rule => ({
  id: r.id, name: r.name, groupIds: parseJson<string[]>(r.group_ids, []), enabled: !!r.enabled,
  action: r.action as Rule['action'], trigger: parseJson<Trigger>(r.trigger, { type: 'manual', active: false }),
  strictness: r.strictness as Rule['strictness'], priority: r.priority,
  ...(r.max_pauses_per_day != null ? { maxPausesPerDay: r.max_pauses_per_day } : {}), source: 'server',
});
export const overrideOut = (r: OverrideRow): Override => ({
  id: r.id, groupIds: parseJson<string[]>(r.group_ids, []), action: r.action as Override['action'],
  startsAt: r.starts_at, ...(r.ends_at ? { endsAt: r.ends_at } : {}), issuedAt: r.issued_at,
  ...(r.reason ? { reason: r.reason } : {}),
});
/** Admin-facing override: bundle shape + targeting. */
export const overrideAdminOut = (r: OverrideRow) => ({
  ...overrideOut(r), endsAt: r.ends_at, reason: r.reason, deviceIds: parseJson<string[] | null>(r.device_ids, null),
});

export function getSettingsRow(ctx: Ctx, adminId: string): SettingsRow {
  ctx.db.prepare('INSERT OR IGNORE INTO settings (admin_id) VALUES (?)').run(adminId);
  return ctx.db.prepare('SELECT * FROM settings WHERE admin_id = ?').get(adminId) as SettingsRow;
}
export function settingsOut(ctx: Ctx, adminId: string): Settings & { timeZone: string | null } {
  const s = getSettingsRow(ctx, adminId);
  return {
    protectionLock: s.protection_lock as Settings['protectionLock'],
    allowLocalRules: !!s.allow_local_rules,
    denyAppRemoval: !!s.deny_app_removal,
    timeZone: s.time_zone,
  };
}

// ---- bundle ----

export function buildBundle(ctx: Ctx, device: Pick<DeviceRow, 'id' | 'admin_id' | 'latest_version'>): PolicyBundle {
  const now = ctx.now();
  const nowIso = iso(now);
  const a = device.admin_id;
  const groups = (ctx.db.prepare('SELECT * FROM groups WHERE admin_id = ? ORDER BY created_at, id').all(a) as GroupRow[]).map(groupOut);
  const rules = (ctx.db.prepare('SELECT * FROM rules WHERE admin_id = ? ORDER BY created_at, id').all(a) as RuleRow[]).map(ruleOut);
  const ovRows = ctx.db
    .prepare('SELECT * FROM overrides WHERE admin_id = ? AND (ends_at IS NULL OR ends_at > ?) ORDER BY issued_at, id')
    .all(a, nowIso) as OverrideRow[];
  const overrides = ovRows
    .filter((o) => {
      const ids = parseJson<string[] | null>(o.device_ids, null);
      return ids == null || ids.includes(device.id);
    })
    .map(overrideOut);
  const s = settingsOut(ctx, a);
  return {
    version: device.latest_version,
    generatedAt: nowIso,
    timeZone: s.timeZone,
    groups, rules, overrides,
    settings: { protectionLock: s.protectionLock, allowLocalRules: s.allowLocalRules, denyAppRemoval: s.denyAppRemoval },
  };
}

export function buildBundleById(ctx: Ctx, deviceId: string): PolicyBundle | null {
  const d = ctx.db.prepare('SELECT id, admin_id, latest_version FROM devices WHERE id = ?').get(deviceId) as
    | Pick<DeviceRow, 'id' | 'admin_id' | 'latest_version'> | undefined;
  return d ? buildBundle(ctx, d) : null;
}

// ---- versioning: the single path for any policy-affecting mutation ----

/** Bump latest_version for the given devices (default: all devices of the account) and queue pushes. */
export function bumpPolicy(ctx: Ctx, adminId: string, deviceIds?: string[] | null): string[] {
  const nowIso = iso(ctx.now());
  pruneOverrides(ctx, adminId);
  const rows = (
    deviceIds && deviceIds.length
      ? ctx.db
          .prepare(`SELECT id FROM devices WHERE admin_id = ? AND id IN (${deviceIds.map(() => '?').join(',')})`)
          .all(adminId, ...deviceIds)
      : ctx.db.prepare('SELECT id FROM devices WHERE admin_id = ?').all(adminId)
  ) as { id: string }[];
  const upd = ctx.db.prepare('UPDATE devices SET latest_version = latest_version + 1, latest_bumped_at = ? WHERE id = ?');
  for (const r of rows) {
    upd.run(nowIso, r.id);
    ctx.push.schedulePolicy(r.id);
  }
  return rows.map((r) => r.id);
}

/** Drop overrides that ended more than a day ago. */
export function pruneOverrides(ctx: Ctx, adminId?: string): number {
  const cutoff = iso(new Date(ctx.now().getTime() - 24 * 3600_000));
  const r = adminId
    ? ctx.db.prepare('DELETE FROM overrides WHERE admin_id = ? AND ends_at IS NOT NULL AND ends_at < ?').run(adminId, cutoff)
    : ctx.db.prepare('DELETE FROM overrides WHERE ends_at IS NOT NULL AND ends_at < ?').run(cutoff);
  return r.changes;
}

export function audit(ctx: Ctx, adminId: string, actor: string, action: string, target?: string | null, detail?: unknown): void {
  ctx.db
    .prepare('INSERT INTO audit_log (admin_id, actor, action, target, detail, created_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(adminId, actor, action, target ?? null, detail === undefined ? null : JSON.stringify(detail), iso(ctx.now()));
}
