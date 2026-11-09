import type { FastifyRequest } from 'fastify';
import type { Ctx, DeviceRow } from '../context.js';
import { forbidden, unauthorized } from '../errors.js';
import { bumpPolicy } from '../policy/service.js';
import { iso, sha256Hex } from '../util.js';
import { verifyJwt } from './crypto.js';

export interface AdminPrincipal { id: string; via: 'jwt' | 'apikey'; keyId?: string }

declare module 'fastify' {
  interface FastifyRequest {
    admin?: AdminPrincipal;
    device?: DeviceRow;
  }
}

export const API_KEY_PREFIX = 'tk_live_';
export const DEVICE_TOKEN_PREFIX = 'td_';

function bearer(req: FastifyRequest): string {
  const h = req.headers.authorization;
  if (!h || !/^Bearer\s+\S+$/i.test(h)) throw unauthorized();
  return h.replace(/^Bearer\s+/i, '');
}

/** Admin session JWT or API key. */
export function adminAuth(ctx: Ctx) {
  return async (req: FastifyRequest): Promise<void> => {
    const token = bearer(req);
    if (token.startsWith(DEVICE_TOKEN_PREFIX)) throw forbidden('Device tokens cannot access this endpoint');
    if (token.startsWith(API_KEY_PREFIX)) {
      const row = ctx.db.prepare('SELECT id, admin_id FROM api_keys WHERE key_hash = ?').get(sha256Hex(token)) as
        | { id: string; admin_id: string } | undefined;
      if (!row) throw unauthorized('Invalid API key');
      ctx.db.prepare('UPDATE api_keys SET last_used_at = ? WHERE id = ?').run(iso(ctx.now()), row.id);
      req.admin = { id: row.admin_id, via: 'apikey', keyId: row.id };
      return;
    }
    const claims = verifyJwt(token, ctx.config.jwtSecret, ctx.now().getTime());
    const sub = claims && typeof claims.sub === 'string' ? claims.sub : null;
    if (!sub || !ctx.db.prepare('SELECT 1 FROM admins WHERE id = ?').get(sub)) throw unauthorized('Invalid or expired token');
    req.admin = { id: sub, via: 'jwt' };
  };
}

/** Admin session only (API keys are rejected): key management, /auth/me. */
export function sessionAuth(ctx: Ctx) {
  const base = adminAuth(ctx);
  return async (req: FastifyRequest): Promise<void> => {
    await base(req);
    if (req.admin!.via !== 'jwt') throw forbidden('API keys cannot access this endpoint');
  };
}

export function deviceAuth(ctx: Ctx) {
  return async (req: FastifyRequest): Promise<void> => {
    const token = bearer(req);
    if (!token.startsWith(DEVICE_TOKEN_PREFIX)) throw token.startsWith(API_KEY_PREFIX) || token.includes('.') ? forbidden('Admin credentials cannot access device endpoints') : unauthorized();
    const row = ctx.db.prepare('SELECT * FROM devices WHERE token_hash = ?').get(sha256Hex(token)) as DeviceRow | undefined;
    if (!row) throw unauthorized('Invalid device token');
    ctx.db.prepare('UPDATE devices SET last_seen_at = ?, stale_notified_at = NULL WHERE id = ?').run(iso(ctx.now()), row.id);
    // app_version is sent at enroll only; the app's User-Agent keeps it current after updates. The bundle depends on it
    // (guarded gate), so a change re-versions this device's policy: its cached ETag would otherwise 304 the new shape.
    const ua = /^Tether-iOS\/(\d+(?:\.\d+)*)/.exec(req.headers['user-agent'] ?? '');
    if (ua && ua[1] !== row.app_version) {
      ctx.db.transaction(() => {
        ctx.db.prepare('UPDATE devices SET app_version = ? WHERE id = ?').run(ua[1], row.id);
        bumpPolicy(ctx, row.admin_id, [row.id]);
      })();
      req.device = ctx.db.prepare('SELECT * FROM devices WHERE id = ?').get(row.id) as DeviceRow;
      return;
    }
    req.device = row;
  };
}
