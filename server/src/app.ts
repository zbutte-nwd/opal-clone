import Fastify, { type FastifyInstance } from 'fastify';
import rateLimit from '@fastify/rate-limit';
import fastifyStatic from '@fastify/static';
import { ApiError } from './errors.js';
import { loadConfig, VERSION, type Config } from './config.js';
import { LogNotifier, type Ctx, type Notifier } from './context.js';
import { openDb, type DB } from './db.js';
import { runMaintenance } from './devices.js';
import { buildBundleById } from './policy/service.js';
import { ApnsTransport, MockPushTransport, type PushTransport } from './push/apns.js';
import { PushService } from './push/service.js';
import { authRoutes } from './routes/auth.js';
import { adminRoutes } from './routes/admin.js';
import { adminDeviceRoutes, deviceRoutes } from './routes/devices.js';
import { policyRoutes } from './routes/policy.js';

export interface RouteInfo { method: string; url: string }
export type TetherApp = FastifyInstance & { ctx: Ctx; routeList: RouteInfo[]; mockPush: MockPushTransport | null };

export interface BuildOptions {
  config?: Config;
  db?: DB;
  transport?: PushTransport;
  notifier?: Notifier;
  clock?: () => Date;
}

export async function buildApp(opts: BuildOptions = {}): Promise<TetherApp> {
  const config = opts.config ?? loadConfig();
  const app = Fastify({
    logger: config.logLevel === 'silent' ? false : {
      level: config.logLevel,
      redact: ['req.headers.authorization'],
      ...(process.stdout.isTTY ? { transport: { target: 'pino-pretty' } } : {}),
    },
    trustProxy: config.trustProxy,
    exposeHeadRoutes: false,
    bodyLimit: 1024 * 1024,
  }) as unknown as TetherApp;

  const db = opts.db ?? openDb(config.databasePath);
  const now = opts.clock ?? (() => new Date());

  let transport = opts.transport ?? null;
  let mockPush: MockPushTransport | null = null;
  if (!transport) {
    if (config.apns) transport = new ApnsTransport(config.apns, () => now().getTime());
    else transport = mockPush = new MockPushTransport(app.log);
  } else if (transport instanceof MockPushTransport) mockPush = transport;

  const push = new PushService(
    db, transport,
    { debounceMs: config.pushDebounceMs, topic: config.apns?.topic ?? 'com.newwestsite.tether', defaultEnv: config.apnsEnv, nowMs: () => now().getTime() },
    app.log,
  );
  const ctx: Ctx = { db, config, now, push, notifier: opts.notifier ?? new LogNotifier(app.log), log: app.log };
  push.buildBundle = (id) => buildBundleById(ctx, id);
  app.ctx = ctx;
  app.mockPush = mockPush;
  app.routeList = [];
  app.addHook('onRoute', (r) => {
    for (const m of Array.isArray(r.method) ? r.method : [r.method]) app.routeList.push({ method: m, url: r.url });
  });

  // Tolerate empty JSON bodies (e.g. DELETE with content-type: application/json).
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    const s = (body as string).trim();
    if (!s) return done(null, undefined);
    try { done(null, JSON.parse(s)); } catch { done(new ApiError(400, 'bad_request', 'Malformed JSON body'), undefined); }
  });

  app.setErrorHandler((err: Error & { statusCode?: number; validation?: unknown }, req, reply) => {
    if (err instanceof ApiError) return reply.code(err.status).send({ error: { code: err.code, message: err.message } });
    const status = err.statusCode ?? 500;
    if (status === 429) return reply.code(429).send({ error: { code: 'rate_limited', message: 'Too many requests, slow down' } });
    if (status >= 400 && status < 500) return reply.code(status).send({ error: { code: status === 404 ? 'not_found' : 'bad_request', message: err.message } });
    req.log.error({ err }, 'unhandled error');
    return reply.code(500).send({ error: { code: 'internal', message: 'Internal server error' } });
  });

  await app.register(rateLimit, { global: false });

  app.get('/healthz', async () => ({ ok: true, version: VERSION }));
  await app.register(
    async (v1) => {
      await v1.register(authRoutes(ctx));
      await v1.register(adminDeviceRoutes(ctx));
      await v1.register(deviceRoutes(ctx));
      await v1.register(policyRoutes(ctx));
      await v1.register(adminRoutes(ctx));
    },
    { prefix: '/v1' },
  );

  if (config.adminDist) {
    await app.register(fastifyStatic, { root: config.adminDist, wildcard: false });
  }
  app.setNotFoundHandler((req, reply) => {
    if (config.adminDist && req.method === 'GET' && !req.url.startsWith('/v1')) return reply.sendFile('index.html');
    return reply.code(404).send({ error: { code: 'not_found', message: 'Not found' } });
  });

  let timer: NodeJS.Timeout | null = null;
  if (config.maintenanceIntervalMs > 0) {
    timer = setInterval(() => void runMaintenance(ctx).catch((e) => app.log.error({ err: e }, 'maintenance failed')), config.maintenanceIntervalMs);
    timer.unref();
  }
  app.addHook('onClose', async () => {
    if (timer) clearInterval(timer);
    await push.flush();
    if (transport instanceof ApnsTransport) transport.close();
    if (!opts.db) db.close();
  });
  return app;
}
