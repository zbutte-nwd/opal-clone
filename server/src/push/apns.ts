import { createSign, createPrivateKey } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import * as http2 from 'node:http2';
import type { PolicyBundle } from '../engine/index.js';

export type PushEnv = 'sandbox' | 'production';

export interface PushMessage {
  deviceToken: string;
  environment: PushEnv;
  pushType: 'alert' | 'background';
  priority: 5 | 10;
  collapseId: string;
  expiration: number; // unix seconds
  topic: string;
  payload: Record<string, unknown>;
}
export interface PushResult { status: number; reason?: string }
export interface PushTransport { send(msg: PushMessage): Promise<PushResult> }

/** Records pushes; used in tests and whenever APNs credentials are not configured. */
export class MockPushTransport implements PushTransport {
  sent: PushMessage[] = [];
  /** Optional programmable response, e.g. to simulate 410 Unregistered. */
  respond: ((msg: PushMessage) => PushResult) | null = null;
  constructor(private log?: { info: (o: object, m?: string) => void }) {}
  async send(msg: PushMessage): Promise<PushResult> {
    this.sent.push(msg);
    this.log?.info({ push: msg.pushType, env: msg.environment, tether: (msg.payload as { tether?: unknown }).tether && 'tether' }, 'mock push');
    return this.respond ? this.respond(msg) : { status: 200 };
  }
  clear(): void { this.sent = []; }
}

const b64u = (b: Buffer | string) => Buffer.from(b).toString('base64url');

export function loadP8(keyOrPath: string): string {
  if (keyOrPath.includes('BEGIN PRIVATE KEY')) return keyOrPath.replace(/\\n/g, '\n');
  if (existsSync(keyOrPath)) return readFileSync(keyOrPath, 'utf8');
  throw new Error('APNS_KEY_P8 is neither PEM contents nor an existing file path');
}

/** ES256 provider token (RFC 7518 raw r||s signature via ieee-p1363). */
export function createProviderJwt(pem: string, keyId: string, teamId: string, iatSeconds: number): string {
  const head = b64u(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const body = b64u(JSON.stringify({ iss: teamId, iat: iatSeconds }));
  const signer = createSign('SHA256');
  signer.update(`${head}.${body}`);
  const sig = signer.sign({ key: createPrivateKey(pem), dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64u(sig)}`;
}

export interface ApnsOptions { keyP8: string; keyId: string; teamId: string; topic: string }

export class ApnsTransport implements PushTransport {
  private pem: string;
  private jwt: { token: string; at: number } | null = null;
  private sessions = new Map<string, http2.ClientHttp2Session>();
  constructor(private opts: ApnsOptions, private nowMs: () => number = Date.now) {
    this.pem = loadP8(opts.keyP8);
  }

  providerToken(): string {
    const now = this.nowMs();
    if (!this.jwt || now - this.jwt.at > 50 * 60_000) {
      this.jwt = { token: createProviderJwt(this.pem, this.opts.keyId, this.opts.teamId, Math.floor(now / 1000)), at: now };
    }
    return this.jwt.token;
  }

  private session(env: PushEnv): http2.ClientHttp2Session {
    const host = env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';
    let s = this.sessions.get(host);
    if (!s || s.closed || s.destroyed) {
      s = http2.connect(`https://${host}`);
      s.on('error', () => this.sessions.delete(host));
      s.on('close', () => this.sessions.delete(host));
      s.setTimeout(10 * 60_000, () => s?.close());
      this.sessions.set(host, s);
    }
    return s;
  }

  send(msg: PushMessage): Promise<PushResult> {
    return new Promise((resolve) => {
      const body = JSON.stringify(msg.payload);
      let done = false;
      const finish = (r: PushResult) => { if (!done) { done = true; resolve(r); } };
      try {
        const req = this.session(msg.environment).request({
          ':method': 'POST',
          ':path': `/3/device/${msg.deviceToken}`,
          authorization: `bearer ${this.providerToken()}`,
          'apns-topic': msg.topic,
          'apns-push-type': msg.pushType,
          'apns-priority': String(msg.priority),
          'apns-expiration': String(msg.expiration),
          'apns-collapse-id': msg.collapseId,
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(body),
        });
        let status = 0;
        let data = '';
        req.setTimeout(15_000, () => { req.close(http2.constants.NGHTTP2_CANCEL); finish({ status: 0, reason: 'Timeout' }); });
        req.on('response', (h) => { status = Number(h[':status']); });
        req.on('data', (c: Buffer) => { data += c.toString(); });
        req.on('end', () => {
          let reason: string | undefined;
          try { reason = data ? (JSON.parse(data) as { reason?: string }).reason : undefined; } catch { /* ignore */ }
          finish({ status, reason });
        });
        req.on('error', (e) => finish({ status: 0, reason: e.message }));
        req.end(body);
      } catch (e) {
        finish({ status: 0, reason: (e as Error).message });
      }
    });
  }

  close(): void { for (const s of this.sessions.values()) s.close(); this.sessions.clear(); }
}

// ---- payload builders (ARCHITECTURE §7) ----

export const INLINE_BUNDLE_LIMIT = 3000;

export type TetherPayload =
  | { type: 'policyUpdated'; version: number; bundle?: PolicyBundle }
  | { type: 'unlockDecided'; requestId: string };

export function policyTether(version: number, bundle: PolicyBundle | null): TetherPayload {
  const t: TetherPayload = { type: 'policyUpdated', version };
  if (bundle && Buffer.byteLength(JSON.stringify(bundle)) < INLINE_BUNDLE_LIMIT) t.bundle = bundle;
  return t;
}

export function alertPayload(tether: TetherPayload, body = 'Your focus settings were updated'): Record<string, unknown> {
  return { aps: { alert: { title: 'Tether', body }, 'mutable-content': 1 }, tether };
}
export function backgroundPayload(tether: TetherPayload): Record<string, unknown> {
  return { aps: { 'content-available': 1 }, tether };
}

export const REMOVE_TOKEN_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic']);
export const shouldClearToken = (r: PushResult): boolean =>
  r.status === 410 || (r.status === 400 && !!r.reason && REMOVE_TOKEN_REASONS.has(r.reason));
