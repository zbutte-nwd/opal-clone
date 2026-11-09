import { randomInt } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { adminAuth, deviceAuth, DEVICE_TOKEN_PREFIX } from '../auth/plugin.js';
import type { Ctx, DeviceRow } from '../context.js';
import { deviceDetail, deviceSummary } from '../devices.js';
import { forbidden, invalid, notFound, parse } from '../errors.js';
import { assertGroupsExist } from '../policy/overrides.js';
import { LocalSnapshotSchema } from '../policy/schemas.js';
import { audit, buildBundle } from '../policy/service.js';
import { addMinutes, iso, newId, parseJson, randomToken, sha256Hex } from '../util.js';

const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const genCode = () => {
  let s = '';
  for (let i = 0; i < 8; i++) s += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  return `${s.slice(0, 4)}-${s.slice(4)}`;
};
const normCode = (c: string) => {
  const s = c.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4)}` : s;
};

const PairingBody = z.object({ deviceName: z.string().trim().min(1).max(100).optional() });
const PatchDevice = z.object({ name: z.string().trim().min(1).max(100) });
const Enroll = z.object({
  pairingCode: z.string().min(1).max(32),
  name: z.string().trim().min(1).max(100),
  model: z.string().max(100).optional().default(''),
  osVersion: z.string().max(50).optional().default(''),
  appVersion: z.string().max(50).optional().default(''),
});
const PushToken = z.object({
  token: z.string().regex(/^[0-9a-fA-F]{32,256}$/, 'must be a hex string'),
  environment: z.enum(['sandbox', 'production']),
});
function isValidTimeZone(tz: string): boolean {
  try { new Intl.DateTimeFormat('en-US', { timeZone: tz }); return true; } catch { return false; }
}
const Ack = z.object({
  version: z.number().int().min(0),
  appliedAt: z.string().refine((s) => !Number.isNaN(Date.parse(s)), 'must be RFC 3339'),
  blockedGroupIds: z.array(z.string().max(64)).max(500),
  authorizationStatus: z.enum(['approved', 'denied', 'notDetermined']),
  timeZone: z.string().max(64).refine(isValidTimeZone, 'must be an IANA time zone').optional(),
});
const Events = z.object({
  events: z
    .array(
      z.object({
        id: z.string().min(1).max(100),
        type: z.string().min(1).max(64),
        occurredAt: z.string().refine((s) => !Number.isNaN(Date.parse(s)), 'must be RFC 3339'),
        data: z.record(z.string(), z.unknown()).nullish(),
      }),
    )
    .max(200),
});
const UnlockCreate = z.object({
  kind: z.enum(['groups', 'disableProtection']),
  groupIds: z.array(z.string().min(1).max(64)).max(100).optional(),
  minutes: z.number().int().min(1).max(1440).optional(),
  reason: z.string().max(500).nullish(),
});

export function unlockOut(ctx: Ctx, r: Record<string, unknown>) {
  return {
    id: r.id, deviceId: r.device_id, deviceName: (ctx.db.prepare('SELECT name FROM devices WHERE id = ?').get(r.device_id) as { name: string } | undefined)?.name ?? null,
    kind: r.kind, groupIds: parseJson<string[]>(r.group_ids as string, []), minutes: r.minutes ?? null, reason: r.reason ?? null,
    status: r.status, createdAt: r.created_at, expiresAt: r.expires_at, decidedAt: r.decided_at ?? null,
    overrideId: r.override_id ?? null, note: r.note ?? null,
  };
}

/** Lazily expire pending requests past their 24 h window. */
export function expireUnlocks(ctx: Ctx): void {
  ctx.db.prepare("UPDATE unlock_requests SET status = 'expired' WHERE status = 'pending' AND expires_at <= ?").run(iso(ctx.now()));
}

export function adminDeviceRoutes(ctx: Ctx) {
  const { db } = ctx;
  const rl = { rateLimit: { max: ctx.config.rateLimit.pairingMax, timeWindow: ctx.config.rateLimit.windowMs } };
  const getDevice = (a: string, id: string) => {
    const d = db.prepare('SELECT * FROM devices WHERE id = ? AND admin_id = ?').get(id, a) as DeviceRow | undefined;
    if (!d) throw notFound('Device not found');
    return d;
  };
  return async (app: FastifyInstance) => {
    app.addHook('preHandler', adminAuth(ctx));

    app.post('/pairing-codes', { config: rl }, async (req, reply) => {
      const a = req.admin!.id;
      const b = parse(PairingBody, req.body);
      const code = genCode();
      const expires = addMinutes(ctx.now(), 10);
      db.prepare('INSERT INTO pairing_codes (code, admin_id, device_name, expires_at, created_at) VALUES (?,?,?,?,?)')
        .run(code, a, b.deviceName ?? null, iso(expires), iso(ctx.now()));
      const base = ctx.config.publicBaseUrl ?? `${req.protocol}://${req.headers.host}`;
      audit(ctx, a, a, 'pairing.create', null, { deviceName: b.deviceName });
      return reply.code(201).send({
        code, expiresAt: iso(expires), qrPayload: `tether://pair?code=${code}&server=${encodeURIComponent(base)}`,
      });
    });

    app.get('/devices', async (req) => ({
      devices: (db.prepare('SELECT * FROM devices WHERE admin_id = ? ORDER BY created_at, id').all(req.admin!.id) as DeviceRow[])
        .map((d) => deviceSummary(ctx, d)),
    }));

    app.get<{ Params: { id: string } }>('/devices/:id', async (req) => deviceDetail(ctx, getDevice(req.admin!.id, req.params.id)));

    app.patch<{ Params: { id: string } }>('/devices/:id', async (req) => {
      const a = req.admin!.id;
      const d = getDevice(a, req.params.id);
      const b = parse(PatchDevice, req.body);
      db.prepare('UPDATE devices SET name = ? WHERE id = ?').run(b.name, d.id);
      audit(ctx, a, a, 'device.rename', d.id, { name: b.name });
      return deviceDetail(ctx, getDevice(a, d.id));
    });

    app.delete<{ Params: { id: string } }>('/devices/:id', async (req, reply) => {
      const a = req.admin!.id;
      const d = getDevice(a, req.params.id);
      db.prepare('DELETE FROM devices WHERE id = ?').run(d.id);
      audit(ctx, a, a, 'device.unpair', d.id, { name: d.name });
      return reply.code(204).send();
    });

    app.post<{ Params: { id: string } }>('/devices/:id/push', async (req) => {
      const d = getDevice(req.admin!.id, req.params.id);
      await ctx.push.pushNow(d.id);
      return { ok: true, hasPushToken: !!(db.prepare('SELECT push_token FROM devices WHERE id = ?').get(d.id) as { push_token: string | null }).push_token };
    });

    app.get<{ Params: { id: string }; Querystring: { limit?: string } }>('/devices/:id/events', async (req) => {
      const d = getDevice(req.admin!.id, req.params.id);
      const limit = Math.min(Math.max(parseInt(req.query.limit ?? '50', 10) || 50, 1), 200);
      const rows = db
        .prepare('SELECT * FROM events WHERE device_id = ? ORDER BY occurred_at DESC, id LIMIT ?')
        .all(d.id, limit) as { id: string; type: string; occurred_at: string; data: string | null; received_at: string }[];
      return {
        events: rows.map((r) => ({ id: r.id, type: r.type, occurredAt: r.occurred_at, data: parseJson(r.data, null), receivedAt: r.received_at })),
      };
    });
  };
}

export function deviceRoutes(ctx: Ctx) {
  const { db } = ctx;
  const auth = deviceAuth(ctx);
  const rl = { rateLimit: { max: ctx.config.rateLimit.enrollMax, timeWindow: ctx.config.rateLimit.windowMs } };
  return async (app: FastifyInstance) => {
    app.post('/devices/enroll', { config: rl }, async (req, reply) => {
      const b = parse(Enroll, req.body);
      const code = normCode(b.pairingCode);
      const now = iso(ctx.now());
      const token = DEVICE_TOKEN_PREFIX + randomToken(32);
      const id = newId('dev');
      const ok = db.transaction(() => {
        const row = db.prepare('SELECT * FROM pairing_codes WHERE code = ?').get(code) as
          | { admin_id: string; expires_at: string; used_at: string | null } | undefined;
        if (!row || row.used_at || row.expires_at <= now) return null;
        db.prepare('UPDATE pairing_codes SET used_at = ? WHERE code = ?').run(now, code);
        db.prepare(
          `INSERT INTO devices (id, admin_id, name, model, os_version, app_version, token_hash, latest_version, latest_bumped_at, last_seen_at, created_at)
           VALUES (?,?,?,?,?,?,?,1,?,?,?)`,
        ).run(id, row.admin_id, b.name, b.model, b.osVersion, b.appVersion, sha256Hex(token), now, now, now);
        audit(ctx, row.admin_id, id, 'device.enroll', id, { name: b.name });
        return row.admin_id;
      })();
      if (!ok) throw notFound('Invalid or expired pairing code');
      const baseURL = ctx.config.publicBaseUrl ?? `${req.protocol}://${req.headers.host}`;
      return reply.code(201).send({ deviceId: id, deviceToken: token, baseURL });
    });

    app.register(async (d) => {
      d.addHook('preHandler', auth);

      d.put('/devices/me/push-token', async (req, reply) => {
        const b = parse(PushToken, req.body);
        db.prepare('UPDATE devices SET push_token = ?, push_env = ? WHERE id = ?').run(b.token.toLowerCase(), b.environment, req.device!.id);
        return reply.code(204).send();
      });

      d.get('/devices/me/policy', async (req, reply) => {
        const dev = db.prepare('SELECT * FROM devices WHERE id = ?').get(req.device!.id) as DeviceRow;
        const etag = `"${dev.latest_version}"`;
        const inm = req.headers['if-none-match'];
        if (inm && inm.split(',').some((t) => t.trim().replace(/^W\//, '').replace(/"/g, '') === String(dev.latest_version))) {
          return reply.code(304).header('ETag', etag).send();
        }
        return reply.header('ETag', etag).header('Cache-Control', 'no-cache').send(buildBundle(ctx, dev));
      });

      d.post('/devices/me/ack', async (req, reply) => {
        const b = parse(Ack, req.body);
        const dev = req.device!;
        db.prepare(
          `UPDATE devices SET applied_version = MAX(applied_version, ?), applied_at = ?, blocked_group_ids = ?, authorization_status = ?, time_zone = COALESCE(?, time_zone) WHERE id = ?`,
        ).run(Math.min(b.version, dev.latest_version), iso(new Date(b.appliedAt)), JSON.stringify(b.blockedGroupIds), b.authorizationStatus, b.timeZone ?? null, dev.id);
        return reply.code(204).send();
      });

      // Read-only snapshot of phone-made state; replaced whole, never merged. Same hash = no write.
      d.put('/devices/me/local', { bodyLimit: 256 * 1024 }, async (req, reply) => {
        const b = parse(LocalSnapshotSchema, req.body);
        const dev = req.device!;
        const cur = db.prepare('SELECT hash FROM device_local WHERE device_id = ?').get(dev.id) as { hash: string } | undefined;
        if (cur?.hash !== b.hash) {
          db.prepare(
            `INSERT INTO device_local (device_id, hash, snapshot, received_at) VALUES (?,?,?,?)
             ON CONFLICT(device_id) DO UPDATE SET hash = excluded.hash, snapshot = excluded.snapshot, received_at = excluded.received_at`,
          ).run(dev.id, b.hash, JSON.stringify(b), iso(ctx.now()));
        }
        return reply.code(204).send();
      });

      d.post('/devices/me/events', async (req, reply) => {
        const b = parse(Events, req.body);
        const dev = req.device!;
        const ins = db.prepare('INSERT OR IGNORE INTO events (device_id, id, type, occurred_at, data, received_at) VALUES (?,?,?,?,?,?)');
        const received = iso(ctx.now());
        db.transaction(() => {
          const sorted = [...b.events].sort((x, y) => Date.parse(x.occurredAt) - Date.parse(y.occurredAt));
          for (const e of sorted) {
            const r = ins.run(dev.id, e.id, e.type, iso(new Date(e.occurredAt)), e.data ? JSON.stringify(e.data) : null, received);
            if (!r.changes) continue;
            if (e.type === 'protectionDisabled') db.prepare('UPDATE devices SET protection_enabled = 0 WHERE id = ?').run(dev.id);
            else if (e.type === 'protectionEnabled') db.prepare('UPDATE devices SET protection_enabled = 1 WHERE id = ?').run(dev.id);
            else if (e.type === 'authorizationChanged' && typeof e.data?.status === 'string' && ['approved', 'denied', 'notDetermined'].includes(e.data.status)) {
              db.prepare('UPDATE devices SET authorization_status = ? WHERE id = ?').run(e.data.status, dev.id);
            }
          }
        })();
        return reply.code(202).send();
      });

      d.post('/devices/me/unlock-requests', async (req, reply) => {
        const b = parse(UnlockCreate, req.body);
        const dev = req.device!;
        let groupIds: string[] = [];
        let minutes: number | null = null;
        if (b.kind === 'groups') {
          if (!b.groupIds?.length || !b.minutes) {
            throw invalid('groupIds and minutes are required for kind "groups"');
          }
          assertGroupsExist(ctx, dev.admin_id, b.groupIds);
          groupIds = [...new Set(b.groupIds)];
          minutes = b.minutes;
        }
        const id = newId('unl');
        const now = ctx.now();
        db.prepare(
          `INSERT INTO unlock_requests (id, admin_id, device_id, kind, group_ids, minutes, reason, status, created_at, expires_at)
           VALUES (?,?,?,?,?,?,?, 'pending', ?, ?)`,
        ).run(id, dev.admin_id, dev.id, b.kind, JSON.stringify(groupIds), minutes, b.reason ?? null, iso(now), iso(addMinutes(now, 24 * 60)));
        audit(ctx, dev.admin_id, dev.id, 'unlock.request', id, { kind: b.kind });
        return reply.code(201).send(unlockOut(ctx, db.prepare('SELECT * FROM unlock_requests WHERE id = ?').get(id) as Record<string, unknown>));
      });

      d.get<{ Params: { id: string } }>('/devices/me/unlock-requests/:id', async (req) => {
        expireUnlocks(ctx);
        const r = db.prepare('SELECT * FROM unlock_requests WHERE id = ? AND device_id = ?').get(req.params.id, req.device!.id) as Record<string, unknown> | undefined;
        if (!r) throw notFound('Unlock request not found');
        return unlockOut(ctx, r);
      });

      d.delete('/devices/me', async (req, reply) => {
        const dev = db.prepare('SELECT * FROM devices WHERE id = ?').get(req.device!.id) as DeviceRow;
        let allowed = dev.protection_enabled === 0 || dev.protection_enabled === null;
        if (!allowed) {
          const since = iso(addMinutes(ctx.now(), -24 * 60));
          allowed = !!db
            .prepare("SELECT 1 FROM unlock_requests WHERE device_id = ? AND kind = 'disableProtection' AND status = 'approved' AND decided_at >= ?")
            .get(dev.id, since);
        }
        if (!allowed) throw forbidden('Disable protection before unpairing this device');
        db.prepare('DELETE FROM devices WHERE id = ?').run(dev.id);
        audit(ctx, dev.admin_id, dev.id, 'device.self_unpair', dev.id);
        return reply.code(204).send();
      });
    });
  };
}
