import type { Ctx } from '../context.js';
import { invalid } from '../errors.js';
import { addMinutes, iso, newId } from '../util.js';
import { audit, bumpPolicy, overrideAdminOut } from './service.js';

export function assertGroupsExist(ctx: Ctx, adminId: string, ids: string[]): void {
  const q = ctx.db.prepare('SELECT 1 FROM groups WHERE id = ? AND admin_id = ?');
  const missing = [...new Set(ids)].filter((id) => !q.get(id, adminId));
  if (missing.length) throw invalid(`Unknown groupIds: ${missing.join(', ')}`);
}

export function assertDevicesExist(ctx: Ctx, adminId: string, ids: string[]): void {
  const q = ctx.db.prepare('SELECT 1 FROM devices WHERE id = ? AND admin_id = ?');
  const missing = [...new Set(ids)].filter((id) => !q.get(id, adminId));
  if (missing.length) throw invalid(`Unknown deviceIds: ${missing.join(', ')}`);
}

export interface NewOverride {
  groupIds: string[];
  action: 'block' | 'unblock';
  startsAt?: string;
  endsAt?: string | null;
  durationMinutes?: number;
  reason?: string | null;
  deviceIds?: string[] | null;
}

/** Validates, inserts and bumps policy for the targeted devices. Returns the admin-facing override. */
export function createOverride(ctx: Ctx, adminId: string, actor: string, input: NewOverride) {
  if (input.endsAt && input.durationMinutes !== undefined) throw invalid('Provide either endsAt or durationMinutes, not both');
  if (!input.groupIds.length) throw invalid('groupIds: at least one group is required');
  assertGroupsExist(ctx, adminId, input.groupIds);
  if (input.deviceIds?.length) assertDevicesExist(ctx, adminId, input.deviceIds);
  const now = ctx.now();
  const startsAt = input.startsAt ? new Date(iso(new Date(input.startsAt))) : new Date(iso(now));
  let endsAt: Date | null = null;
  if (input.durationMinutes !== undefined) endsAt = addMinutes(startsAt, input.durationMinutes);
  else if (input.endsAt) endsAt = new Date(iso(new Date(input.endsAt)));
  if (endsAt && endsAt.getTime() <= startsAt.getTime()) throw invalid('endsAt must be after startsAt');

  // issuedAt must be strictly increasing within the account so "latest issuedAt wins" is deterministic.
  const maxRow = ctx.db.prepare('SELECT MAX(issued_at) AS m FROM overrides WHERE admin_id = ?').get(adminId) as { m: string | null };
  let issued = new Date(iso(now));
  if (maxRow.m && Date.parse(maxRow.m) >= issued.getTime()) issued = new Date(Date.parse(maxRow.m) + 1000);

  const id = newId('ovr');
  const groupIds = [...new Set(input.groupIds)];
  const deviceIds = input.deviceIds?.length ? [...new Set(input.deviceIds)] : null;
  const row = {
    id, group_ids: JSON.stringify(groupIds), action: input.action, starts_at: iso(startsAt),
    ends_at: endsAt ? iso(endsAt) : null, issued_at: iso(issued), reason: input.reason ?? null,
    device_ids: deviceIds ? JSON.stringify(deviceIds) : null,
  };
  ctx.db.transaction(() => {
    ctx.db
      .prepare(
        `INSERT INTO overrides (id, admin_id, group_ids, action, starts_at, ends_at, issued_at, reason, device_ids, created_at)
         VALUES (@id, @admin, @group_ids, @action, @starts_at, @ends_at, @issued_at, @reason, @device_ids, @created)`,
      )
      .run({ ...row, admin: adminId, created: iso(now) });
    audit(ctx, adminId, actor, `override.${input.action}`, id, { groupIds, deviceIds, endsAt: row.ends_at });
    bumpPolicy(ctx, adminId, deviceIds);
  })();
  return overrideAdminOut(row);
}
