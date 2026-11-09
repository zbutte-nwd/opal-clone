import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { adminAuth, API_KEY_PREFIX, sessionAuth } from '../auth/plugin.js';
import type { Ctx } from '../context.js';
import { conflict, notFound, parse } from '../errors.js';
import { createOverride } from '../policy/overrides.js';
import { audit } from '../policy/service.js';
import { iso, newId, parseJson, randomToken, sha256Hex } from '../util.js';
import { expireUnlocks, unlockOut } from './devices.js';

const Approve = z.object({ minutes: z.number().int().min(1).max(1440).optional() });
const Deny = z.object({ note: z.string().max(500).nullish() });
const KeyBody = z.object({ name: z.string().trim().min(1).max(100) });

export function adminRoutes(ctx: Ctx) {
  const { db } = ctx;
  return async (app: FastifyInstance) => {
    // ---------------- unlock requests ----------------
    app.register(async (u) => {
      u.addHook('preHandler', adminAuth(ctx));
      type Row = Record<string, unknown> & { id: string; device_id: string; kind: string; status: string; minutes: number | null; group_ids: string };
      const get = (a: string, id: string): Row => {
        expireUnlocks(ctx);
        const r = db.prepare('SELECT * FROM unlock_requests WHERE id = ? AND admin_id = ?').get(id, a) as Row | undefined;
        if (!r) throw notFound('Unlock request not found');
        return r;
      };
      const decide = (r: Row) => {
        if (r.status !== 'pending') throw conflict(`Request is already ${r.status}`);
      };

      u.get<{ Querystring: { status?: string } }>('/unlock-requests', async (req) => {
        expireUnlocks(ctx);
        const st = req.query.status;
        const rows = (st
          ? db.prepare('SELECT * FROM unlock_requests WHERE admin_id = ? AND status = ? ORDER BY created_at DESC, id').all(req.admin!.id, st)
          : db.prepare('SELECT * FROM unlock_requests WHERE admin_id = ? ORDER BY created_at DESC, id').all(req.admin!.id)) as Row[];
        return { requests: rows.map((r) => unlockOut(ctx, r)) };
      });

      u.post<{ Params: { id: string } }>('/unlock-requests/:id/approve', async (req) => {
        const a = req.admin!.id;
        const actor = req.admin!.via === 'apikey' ? `apikey:${req.admin!.keyId}` : a;
        const r = get(a, req.params.id);
        decide(r);
        const b = parse(Approve, req.body);
        const now = iso(ctx.now());
        db.transaction(() => {
          let overrideId: string | null = null;
          let minutes = r.minutes;
          if (r.kind === 'groups') {
            minutes = b.minutes ?? r.minutes ?? 15;
            const o = createOverride(ctx, a, actor, {
              groupIds: parseJson<string[]>(r.group_ids, []).filter((g) => db.prepare('SELECT 1 FROM groups WHERE id = ? AND admin_id = ?').get(g, a)),
              action: 'unblock', durationMinutes: minutes, deviceIds: [r.device_id], reason: 'Approved unlock request',
            });
            overrideId = o.id;
          }
          db.prepare("UPDATE unlock_requests SET status = 'approved', decided_at = ?, override_id = ?, minutes = ? WHERE id = ?")
            .run(now, overrideId, minutes, r.id);
          audit(ctx, a, actor, 'unlock.approve', r.id, { kind: r.kind, minutes });
        })();
        if (r.kind === 'disableProtection') {
          void ctx.push.sendTether(r.device_id, { type: 'unlockDecided', requestId: r.id }, 'Your unlock request was approved');
        }
        return unlockOut(ctx, get(a, r.id));
      });

      u.post<{ Params: { id: string } }>('/unlock-requests/:id/deny', async (req) => {
        const a = req.admin!.id;
        const r = get(a, req.params.id);
        decide(r);
        const b = parse(Deny, req.body);
        db.prepare("UPDATE unlock_requests SET status = 'denied', decided_at = ?, note = ? WHERE id = ?").run(iso(ctx.now()), b.note ?? null, r.id);
        audit(ctx, a, req.admin!.via === 'apikey' ? `apikey:${req.admin!.keyId}` : a, 'unlock.deny', r.id, { kind: r.kind });
        void ctx.push.sendTether(r.device_id, { type: 'unlockDecided', requestId: r.id }, 'Your unlock request was answered');
        return unlockOut(ctx, get(a, r.id));
      });

      u.get<{ Querystring: { limit?: string } }>('/audit-log', async (req) => {
        const limit = Math.min(Math.max(parseInt(req.query.limit ?? '100', 10) || 100, 1), 500);
        const rows = db.prepare('SELECT * FROM audit_log WHERE admin_id = ? ORDER BY seq DESC LIMIT ?').all(req.admin!.id, limit) as
          { seq: number; actor: string; action: string; target: string | null; detail: string | null; created_at: string }[];
        return { entries: rows.map((r) => ({ id: r.seq, actor: r.actor, action: r.action, target: r.target, detail: parseJson(r.detail, null), createdAt: r.created_at })) };
      });
    });

    // ---------------- API keys (session only) ----------------
    app.register(async (k) => {
      k.addHook('preHandler', sessionAuth(ctx));
      k.get('/api-keys', async (req) => ({
        keys: (db.prepare('SELECT id, name, prefix, created_at, last_used_at FROM api_keys WHERE admin_id = ? ORDER BY created_at, id').all(req.admin!.id) as
          { id: string; name: string; prefix: string; created_at: string; last_used_at: string | null }[])
          .map((r) => ({ id: r.id, name: r.name, prefix: r.prefix, createdAt: r.created_at, lastUsedAt: r.last_used_at })),
      }));
      k.post('/api-keys', async (req, reply) => {
        const a = req.admin!.id;
        const b = parse(KeyBody, req.body);
        const key = API_KEY_PREFIX + randomToken(32);
        const id = newId('key');
        const now = iso(ctx.now());
        db.prepare('INSERT INTO api_keys (id, admin_id, name, key_hash, prefix, created_at) VALUES (?,?,?,?,?,?)')
          .run(id, a, b.name, sha256Hex(key), key.slice(0, 12), now);
        audit(ctx, a, a, 'apikey.create', id, { name: b.name });
        return reply.code(201).send({ id, name: b.name, key, prefix: key.slice(0, 12), createdAt: now });
      });
      k.delete<{ Params: { id: string } }>('/api-keys/:id', async (req, reply) => {
        const a = req.admin!.id;
        const r = db.prepare('DELETE FROM api_keys WHERE id = ? AND admin_id = ?').run(req.params.id, a);
        if (!r.changes) throw notFound('API key not found');
        audit(ctx, a, a, 'apikey.delete', req.params.id);
        return reply.code(204).send();
      });
    });
  };
}
