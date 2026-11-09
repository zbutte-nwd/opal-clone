import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildApp, type TetherApp } from '../src/app.js';
import { testConfig, type Config } from '../src/config.js';
import { MockPushTransport } from '../src/push/apns.js';

export const START = new Date('2026-11-09T17:00:00Z');

export interface Harness {
  app: TetherApp;
  push: MockPushTransport;
  clock: { t: Date };
  advance(ms: number): void;
  req(method: string, url: string, token?: string | null, body?: unknown, headers?: Record<string, string>): Promise<{ status: number; json: any; headers: Record<string, any> }>;
  register(email?: string): Promise<{ token: string; adminId: string }>;
  pair(adminToken: string, name?: string, appVersion?: string): Promise<{ deviceId: string; deviceToken: string }>;
}

export async function harness(over: Partial<Config> = {}): Promise<Harness> {
  const dir = mkdtempSync(join(tmpdir(), 'tether-test-'));
  const clock = { t: new Date(START) };
  const push = new MockPushTransport();
  const app = await buildApp({
    config: testConfig({ databasePath: join(dir, 'test.db'), ...over }),
    transport: push,
    clock: () => new Date(clock.t),
  });
  const h: Harness = {
    app, push, clock,
    advance: (ms) => { clock.t = new Date(clock.t.getTime() + ms); },
    async req(method, url, token, body, headers = {}) {
      const res = await app.inject({
        method: method as 'GET', url,
        headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
        ...(body !== undefined ? { payload: body as object } : {}),
      });
      let json: any = null;
      try { json = res.body ? JSON.parse(res.body) : null; } catch { /* non-json */ }
      return { status: res.statusCode, json, headers: res.headers };
    },
    async register(email = `a${Math.random().toString(36).slice(2)}@x.test`) {
      const r = await h.req('POST', '/v1/auth/register', null, { email, password: 'password123', name: 'Admin' });
      if (r.status !== 201) throw new Error('register failed ' + JSON.stringify(r.json));
      return { token: r.json.token, adminId: r.json.admin.id };
    },
    async pair(adminToken, name = 'iPhone', appVersion = '1.0') {
      const c = await h.req('POST', '/v1/pairing-codes', adminToken, {});
      const e = await h.req('POST', '/v1/devices/enroll', null, { pairingCode: c.json.code, name, model: 'iPhone15,2', osVersion: '17.5', appVersion });
      if (e.status !== 201) throw new Error('enroll failed ' + JSON.stringify(e.json));
      return { deviceId: e.json.deviceId, deviceToken: e.json.deviceToken };
    },
  };
  return h;
}

const schema = JSON.parse(readFileSync(new URL('../../contracts/policy-bundle.schema.json', import.meta.url), 'utf8'));
const Ajv: any = (Ajv2020 as any).default ?? Ajv2020;
const ajv = new Ajv({ strict: false, allErrors: true });
((addFormats as any).default ?? addFormats)(ajv);
const validate = ajv.compile(schema);
export function validateBundle(b: unknown): string | null {
  return validate(b) ? null : ajv.errorsText(validate.errors);
}
