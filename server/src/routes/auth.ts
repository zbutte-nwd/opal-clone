import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { hashPassword, signJwt, verifyPassword } from '../auth/crypto.js';
import { sessionAuth } from '../auth/plugin.js';
import type { Ctx } from '../context.js';
import { conflict, forbidden, parse, unauthorized } from '../errors.js';
import { audit } from '../policy/service.js';
import { iso, newId } from '../util.js';

const Register = z.object({
  email: z.string().trim().toLowerCase().email().max(200),
  password: z.string().min(8, 'must be at least 8 characters').max(200),
  name: z.string().trim().min(1).max(100),
});
const Login = z.object({ email: z.string().trim().toLowerCase().max(200), password: z.string().min(1).max(200) });

interface AdminRow { id: string; email: string; name: string; password_hash: string }
const adminOut = (a: AdminRow) => ({ id: a.id, email: a.email, name: a.name });

// A throwaway hash so login timing doesn't reveal whether an email exists.
let dummyHash: Promise<string> | null = null;

export function authRoutes(ctx: Ctx) {
  const token = (id: string) => signJwt({ sub: id }, ctx.config.jwtSecret, ctx.config.jwtTtlSeconds, ctx.now().getTime());
  const rl = (max: number) => ({ rateLimit: { max, timeWindow: ctx.config.rateLimit.windowMs } });

  return async (app: FastifyInstance) => {
    app.post('/auth/register', { config: rl(ctx.config.rateLimit.authMax) }, async (req, reply) => {
      if (!ctx.config.allowRegistration) throw forbidden('Registration is disabled');
      const b = parse(Register, req.body);
      if (ctx.db.prepare('SELECT 1 FROM admins WHERE email = ?').get(b.email)) throw conflict('Email already registered');
      const admin: AdminRow = { id: newId('adm'), email: b.email, name: b.name, password_hash: await hashPassword(b.password) };
      ctx.db.transaction(() => {
        ctx.db
          .prepare('INSERT INTO admins (id, email, name, password_hash, created_at) VALUES (?, ?, ?, ?, ?)')
          .run(admin.id, admin.email, admin.name, admin.password_hash, iso(ctx.now()));
        ctx.db.prepare('INSERT INTO settings (admin_id) VALUES (?)').run(admin.id);
      })();
      audit(ctx, admin.id, admin.id, 'admin.register');
      return reply.code(201).send({ admin: adminOut(admin), token: token(admin.id) });
    });

    app.post('/auth/login', { config: rl(ctx.config.rateLimit.authMax) }, async (req) => {
      const b = parse(Login, req.body);
      const a = ctx.db.prepare('SELECT * FROM admins WHERE email = ?').get(b.email) as AdminRow | undefined;
      dummyHash ??= hashPassword('dummy-password');
      const ok = await verifyPassword(b.password, a ? a.password_hash : await dummyHash);
      if (!a || !ok) throw unauthorized('Invalid email or password');
      audit(ctx, a.id, a.id, 'admin.login');
      return { admin: adminOut(a), token: token(a.id) };
    });

    app.get('/auth/me', { preHandler: sessionAuth(ctx) }, async (req) => {
      const a = ctx.db.prepare('SELECT * FROM admins WHERE id = ?').get(req.admin!.id) as AdminRow;
      return { admin: adminOut(a) };
    });
  };
}
