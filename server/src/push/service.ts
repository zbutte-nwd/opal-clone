import type { FastifyBaseLogger } from 'fastify';
import type { DB } from '../db.js';
import type { PolicyBundle } from '../engine/index.js';
import {
  alertPayload, backgroundPayload, policyTether, shouldClearToken,
  type PushEnv, type PushMessage, type PushTransport, type TetherPayload,
} from './apns.js';

interface PushRow { push_token: string | null; push_env: string | null; latest_version: number }

export class PushService {
  private pending = new Map<string, NodeJS.Timeout>();
  private inflight = new Set<Promise<void>>();
  /** Set by the app after construction (avoids a circular dependency with the bundle builder). */
  buildBundle: (deviceId: string) => PolicyBundle | null = () => null;

  constructor(
    private db: DB,
    public transport: PushTransport,
    private opts: { debounceMs: number; topic: string; defaultEnv: PushEnv; nowMs: () => number },
    private log: FastifyBaseLogger,
  ) {}

  /** Debounced policy push for a device (collapses bursts of mutations). */
  schedulePolicy(deviceId: string): void {
    const existing = this.pending.get(deviceId);
    if (existing) clearTimeout(existing);
    const t = setTimeout(() => {
      this.pending.delete(deviceId);
      this.track(this.sendPolicy(deviceId));
    }, this.opts.debounceMs);
    t.unref();
    this.pending.set(deviceId, t);
  }

  /** Immediately (no debounce) push the current policy to a device. */
  pushNow(deviceId: string): Promise<void> {
    const existing = this.pending.get(deviceId);
    if (existing) { clearTimeout(existing); this.pending.delete(deviceId); }
    return this.track(this.sendPolicy(deviceId));
  }

  /** Run all debounced pushes right now and wait for in-flight sends. For tests and graceful shutdown. */
  async flush(): Promise<void> {
    for (const [id, t] of [...this.pending]) {
      clearTimeout(t);
      this.pending.delete(id);
      this.track(this.sendPolicy(id));
    }
    while (this.inflight.size) await Promise.all([...this.inflight]);
  }

  private track(p: Promise<void>): Promise<void> {
    const q = p.catch((e) => this.log.error({ err: e }, 'push failed')).finally(() => this.inflight.delete(q));
    this.inflight.add(q);
    return q;
  }

  async sendPolicy(deviceId: string): Promise<void> {
    const row = this.row(deviceId);
    if (!row?.push_token) return;
    const bundle = this.buildBundle(deviceId);
    await this.sendPair(deviceId, row, policyTether(row.latest_version, bundle));
  }

  /** Non-debounced custom tether push, e.g. unlockDecided. */
  sendTether(deviceId: string, tether: TetherPayload, body: string): Promise<void> {
    return this.track((async () => {
      const row = this.row(deviceId);
      if (!row?.push_token) return;
      await this.sendPair(deviceId, row, tether, body);
    })());
  }

  private row(deviceId: string): PushRow | undefined {
    return this.db.prepare('SELECT push_token, push_env, latest_version FROM devices WHERE id = ?').get(deviceId) as PushRow | undefined;
  }

  private async sendPair(deviceId: string, row: PushRow, tether: TetherPayload, body?: string): Promise<void> {
    const env = (row.push_env === 'production' || row.push_env === 'sandbox' ? row.push_env : this.opts.defaultEnv) as PushEnv;
    const base = {
      deviceToken: row.push_token!, environment: env, collapseId: 'policy', topic: this.opts.topic,
      expiration: Math.floor(this.opts.nowMs() / 1000) + 24 * 3600,
    };
    const msgs: PushMessage[] = [
      { ...base, pushType: 'alert', priority: 10, payload: alertPayload(tether, body) },
      { ...base, pushType: 'background', priority: 5, payload: backgroundPayload(tether) },
    ];
    for (const m of msgs) {
      const res = await this.transport.send(m);
      if (shouldClearToken(res)) {
        this.db.prepare('UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?').run(deviceId, row.push_token);
        this.log.warn({ deviceId, status: res.status, reason: res.reason }, 'cleared invalid push token');
        return;
      }
      if (res.status !== 200) this.log.warn({ deviceId, status: res.status, reason: res.reason, type: m.pushType }, 'apns rejected push');
    }
  }
}
