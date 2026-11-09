import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { harness, validateBundle, type Harness } from './helpers.js';

let h: Harness;
let A: { token: string; adminId: string };
let B: { token: string; adminId: string };
let dev: { deviceId: string; deviceToken: string };
let social: string, games: string;

beforeAll(async () => {
  h = await harness();
  A = await h.register('a@x.test');
  B = await h.register('b@x.test');
});
afterAll(async () => { await h.app.close(); });

describe('auth', () => {
  it('rejects duplicate email, weak password, bad login', async () => {
    expect((await h.req('POST', '/v1/auth/register', null, { email: 'a@x.test', password: 'password123', name: 'x' })).status).toBe(409);
    const weak = await h.req('POST', '/v1/auth/register', null, { email: 'c@x.test', password: 'short', name: 'x' });
    expect(weak.status).toBe(422);
    expect(weak.json.error.code).toBe('validation_failed');
    expect((await h.req('POST', '/v1/auth/login', null, { email: 'a@x.test', password: 'nope-nope' })).status).toBe(401);
  });
  it('login + me', async () => {
    const r = await h.req('POST', '/v1/auth/login', null, { email: 'a@x.test', password: 'password123' });
    expect(r.status).toBe(200);
    const me = await h.req('GET', '/v1/auth/me', r.json.token);
    expect(me.json.admin.email).toBe('a@x.test');
    expect((await h.req('GET', '/v1/auth/me')).status).toBe(401);
    expect((await h.req('GET', '/v1/auth/me', 'garbage.token.here')).status).toBe(401);
  });
  it('malformed JSON is bad_request; unknown route is not_found', async () => {
    const r = await h.app.inject({ method: 'POST', url: '/v1/auth/login', headers: { 'content-type': 'application/json' }, payload: '{nope' });
    expect(r.statusCode).toBe(400);
    expect(JSON.parse(r.body).error.code).toBe('bad_request');
    expect((await h.req('GET', '/v1/nothing', A.token)).json.error.code).toBe('not_found');
  });
  it('healthz', async () => {
    const r = await h.req('GET', '/healthz');
    expect(r.json.ok).toBe(true);
  });
});

describe('validation', () => {
  it('groups', async () => {
    const bad = (body: unknown) => h.req('POST', '/v1/groups', A.token, body);
    expect((await bad({ name: '', webDomains: [] })).status).toBe(422);
    expect((await bad({ name: 'x', webDomains: ['NotLower.com'] })).status).toBe(422);
    expect((await bad({ name: 'x', webDomains: Array.from({ length: 51 }, (_, i) => `d${i}.com`) })).status).toBe(422);
    expect((await bad({ name: 'x', colorHex: 'red', webDomains: [] })).status).toBe(422);
  });
  it('rules', async () => {
    const g = (await h.req('POST', '/v1/groups', A.token, { name: 'V', webDomains: [] })).json.id;
    const rule = (trigger: unknown, groupIds = [g]) =>
      h.req('POST', '/v1/rules', A.token, { name: 'r', groupIds, action: 'block', trigger });
    const win = (start: string, end: string) => ({ type: 'schedule', windows: [{ days: [1], start, end }] });
    expect((await rule(win('09:00', '09:00'))).status).toBe(422);
    expect((await rule(win('9:00', '10:00'))).status).toBe(422);
    expect((await rule(win('09:00', '25:00'))).status).toBe(422);
    expect((await rule(win('09:00', '24:00'))).status).toBe(201);
    expect((await rule(win('22:00', '06:00'))).status).toBe(201);
    expect((await rule(win('09:00', '10:00'), ['grp_missing'])).status).toBe(422);
    expect((await rule({ type: 'schedule', windows: [{ days: [0], start: '09:00', end: '10:00' }] })).status).toBe(422);
    expect((await rule({ type: 'manual' })).status).toBe(422);
  });
  it('overrides', async () => {
    const g = (await h.req('POST', '/v1/groups', A.token, { name: 'O', webDomains: [] })).json.id;
    const o = (b: object) => h.req('POST', '/v1/overrides', A.token, { groupIds: [g], action: 'block', ...b });
    expect((await o({ endsAt: '2026-11-09T18:00:00Z', durationMinutes: 5 })).status).toBe(422);
    expect((await o({ endsAt: '2020-01-01T00:00:00Z' })).status).toBe(422);
    expect((await o({ deviceIds: ['dev_nope'] })).status).toBe(422);
    expect((await o({})).status).toBe(201); // open-ended
  });
});

describe('pairing, sync, push', () => {
  it('enroll with bad / reused code', async () => {
    expect((await h.req('POST', '/v1/devices/enroll', null, { pairingCode: 'AAAA-BBBB', name: 'x' })).status).toBe(404);
    const c = await h.req('POST', '/v1/pairing-codes', A.token, {});
    expect(c.status).toBe(201);
    expect(c.json.code).toMatch(/^[A-Z0-9]{4}-[A-Z0-9]{4}$/);
    expect(c.json.qrPayload).toBe(`tether://pair?code=${c.json.code}&server=${encodeURIComponent('https://tether.test')}`);
    const body = { pairingCode: c.json.code.toLowerCase(), name: 'P', model: 'm', osVersion: '17', appVersion: '1' };
    expect((await h.req('POST', '/v1/devices/enroll', null, body)).status).toBe(201);
    expect((await h.req('POST', '/v1/devices/enroll', null, body)).status).toBe(404);
    const c2 = await h.req('POST', '/v1/pairing-codes', A.token, {});
    h.advance(11 * 60_000);
    expect((await h.req('POST', '/v1/devices/enroll', null, { ...body, pairingCode: c2.json.code })).status).toBe(404);
  });

  it('full flow', async () => {
    social = (await h.req('POST', '/v1/groups', A.token, { name: 'Social', colorHex: '#FF5A5F', webDomains: ['tiktok.com'] })).json.id;
    games = (await h.req('POST', '/v1/groups', A.token, { name: 'Games', webDomains: [] })).json.id;
    dev = await h.pair(A.token, 'Kid phone');
    expect(dev.deviceToken).toMatch(/^td_[A-Za-z0-9_-]{43}$/);
    // stored only as a hash
    const row = h.app.ctx.db.prepare('SELECT token_hash FROM devices WHERE id = ?').get(dev.deviceId) as { token_hash: string };
    expect(row.token_hash).not.toContain('td_');
    expect(row.token_hash).toHaveLength(64);

    expect((await h.req('PUT', '/v1/devices/me/push-token', dev.deviceToken, { token: 'ab'.repeat(32), environment: 'sandbox' })).status).toBe(204);

    const p1 = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken);
    expect(p1.status).toBe(200);
    expect(validateBundle(p1.json)).toBeNull();
    expect(p1.headers.etag).toBe(`"${p1.json.version}"`);
    const v0 = p1.json.version;
    expect(p1.json.groups.map((g: any) => g.name)).toEqual(expect.arrayContaining(['Social', 'Games']));

    const nm = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken, undefined, { 'if-none-match': p1.headers.etag as string });
    expect(nm.status).toBe(304);

    // mutation bumps version and pushes with inline bundle
    h.push.clear();
    const r = await h.req('POST', '/v1/rules', A.token, {
      name: 'School', groupIds: [social], action: 'block', strictness: 'flexible',
      trigger: { type: 'schedule', windows: [{ days: [1, 2, 3, 4, 5], start: '08:00', end: '15:00' }] },
    });
    expect(r.status).toBe(201);
    await h.app.ctx.push.flush();
    expect(h.push.sent).toHaveLength(2);
    const [alert, bg] = h.push.sent;
    expect(alert!.pushType).toBe('alert');
    expect(alert!.priority).toBe(10);
    expect(alert!.collapseId).toBe('policy');
    expect(alert!.environment).toBe('sandbox');
    expect((alert!.payload as any).aps['mutable-content']).toBe(1);
    expect(bg!.pushType).toBe('background');
    expect(bg!.priority).toBe(5);
    expect((bg!.payload as any).aps['content-available']).toBe(1);
    const tether = (alert!.payload as any).tether;
    expect(tether.type).toBe('policyUpdated');
    expect(tether.version).toBe(v0 + 1);
    expect(validateBundle(tether.bundle)).toBeNull();

    const nm2 = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken, undefined, { 'if-none-match': p1.headers.etag as string });
    expect(nm2.status).toBe(200);
    expect(nm2.json.version).toBe(v0 + 1);
    expect(nm2.json.rules.map((r: any) => r.name)).toContain('School');
    expect(validateBundle(nm2.json)).toBeNull();

    // ack
    const ack = await h.req('POST', '/v1/devices/me/ack', dev.deviceToken, {
      version: v0 + 1, appliedAt: '2026-11-09T17:00:03Z', blockedGroupIds: [social], authorizationStatus: 'approved',
    });
    expect(ack.status).toBe(204);
    const d = await h.req('GET', `/v1/devices/${dev.deviceId}`, A.token);
    expect(d.json.appliedVersion).toBe(v0 + 1);
    expect(d.json.latestVersion).toBe(v0 + 1);
    expect(d.json.status).toBe('online');
    expect(d.json.reportedBlockedGroupIds).toEqual([social]);
    expect(d.json.authorizationStatus).toBe('approved');
    // Monday 2026-11-09 17:00Z, UTC fallback tz => outside 08-15 => not blocked
    const st = d.json.currentState.find((s: any) => s.groupId === social);
    expect(st.blocked).toBe(false);
    const list = await h.req('GET', '/v1/devices', A.token);
    expect(list.json.devices[0].currentState).toBeDefined();
  });

  it('timezone setting drives currentState and bundle.timeZone', async () => {
    await h.req('PATCH', '/v1/settings', A.token, { protectionLock: 'partnerPIN', allowLocalRules: true, denyAppRemoval: true, timeZone: 'Asia/Tokyo' });
    // 17:00Z Monday = 02:00 Tuesday Tokyo -> outside window
    let d = await h.req('GET', `/v1/devices/${dev.deviceId}`, A.token);
    expect(d.json.currentState.find((s: any) => s.groupId === social).blocked).toBe(false);
    await h.req('PATCH', '/v1/settings', A.token, { timeZone: 'America/Los_Angeles' }); // 09:00 PST Monday -> in window
    d = await h.req('GET', `/v1/devices/${dev.deviceId}`, A.token);
    const s = d.json.currentState.find((x: any) => x.groupId === social);
    expect(s.blocked).toBe(true);
    expect(s.reason.kind).toBe('rule');
    const p = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken);
    expect(p.json.timeZone).toBe('America/Los_Angeles');
    expect(validateBundle(p.json)).toBeNull();
    expect((await h.req('PATCH', '/v1/settings', A.token, { timeZone: 'Mars/Base' })).status).toBe(422);
    await h.req('PATCH', '/v1/settings', A.token, { timeZone: null });
  });

  it('pending / stale status', async () => {
    const before = (await h.req('GET', `/v1/devices/${dev.deviceId}`, A.token)).json;
    await h.req('POST', '/v1/groups', A.token, { name: 'Tmp', webDomains: [] });
    h.advance(6 * 60_000);
    await h.req('GET', '/v1/devices/me/policy', dev.deviceToken); // keeps it seen
    expect((await h.req('GET', `/v1/devices/${dev.deviceId}`, A.token)).json.status).toBe('pending');
    expect(before.status).toBe('online');
    h.advance(25 * 3600_000);
    expect((await h.req('GET', `/v1/devices/${dev.deviceId}`, A.token)).json.status).toBe('stale');
    const { runMaintenance } = await import('../src/devices.js');
    const res = await runMaintenance(h.app.ctx);
    expect(res.stale).toBeGreaterThanOrEqual(1);
    const audit = await h.req('GET', '/v1/audit-log', A.token);
    expect(audit.json.entries.some((e: any) => e.action === 'device.stale')).toBe(true);
    await h.req('GET', '/v1/devices/me/policy', dev.deviceToken);
  });

  it('revoked status after ack with denied authorization', async () => {
    const d2 = await h.pair(A.token, 'Second');
    await h.req('POST', '/v1/devices/me/ack', d2.deviceToken, { version: 1, appliedAt: '2026-11-09T17:00:00Z', blockedGroupIds: [], authorizationStatus: 'denied' });
    expect((await h.req('GET', `/v1/devices/${d2.deviceId}`, A.token)).json.status).toBe('revoked');
  });

  it('events are idempotent and update protection state', async () => {
    const ev = { events: [
      { id: 'evt_01', type: 'heartbeat', occurredAt: '2026-11-09T17:05:00Z' },
      { id: 'evt_02', type: 'protectionEnabled', occurredAt: '2026-11-09T17:06:00Z', data: { x: 1 } },
    ] };
    expect((await h.req('POST', '/v1/devices/me/events', dev.deviceToken, ev)).status).toBe(202);
    expect((await h.req('POST', '/v1/devices/me/events', dev.deviceToken, ev)).status).toBe(202);
    const e = await h.req('GET', `/v1/devices/${dev.deviceId}/events?limit=10`, A.token);
    expect(e.json.events).toHaveLength(2);
    // protection enabled => device cannot self-unpair
    expect((await h.req('DELETE', '/v1/devices/me', dev.deviceToken)).status).toBe(403);
    await h.req('POST', '/v1/devices/me/events', dev.deviceToken, { events: [{ id: 'evt_03', type: 'protectionDisabled', occurredAt: '2026-11-09T17:07:00Z' }] });
    expect((await h.req('DELETE', '/v1/devices/me', dev.deviceToken)).status).toBe(204);
    expect((await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).status).toBe(401);
  });

  it('410 clears push token', async () => {
    const d3 = await h.pair(A.token, 'Third');
    await h.req('PUT', '/v1/devices/me/push-token', d3.deviceToken, { token: 'cd'.repeat(32), environment: 'production' });
    h.push.respond = () => ({ status: 410, reason: 'Unregistered' });
    await h.req('POST', `/v1/devices/${d3.deviceId}/push`, A.token);
    h.push.respond = null;
    const row = h.app.ctx.db.prepare('SELECT push_token FROM devices WHERE id = ?').get(d3.deviceId) as any;
    expect(row.push_token).toBeNull();
  });
});

describe('overrides & actions', () => {
  it('durationMinutes, cancel, expiry, api key actions', async () => {
    const g = (await h.req('POST', '/v1/groups', A.token, { name: 'Ovr', webDomains: [] })).json.id;
    const d = await h.pair(A.token, 'OvrDev');
    const base = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json.version;

    const o = await h.req('POST', '/v1/overrides', A.token, { groupIds: [g], action: 'block', durationMinutes: 30, reason: 'focus' });
    expect(o.status).toBe(201);
    expect(Date.parse(o.json.endsAt) - Date.parse(o.json.startsAt)).toBe(30 * 60_000);
    expect(o.json.deviceIds).toBeNull();
    let p = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json;
    expect(p.version).toBe(base + 1);
    expect(p.overrides.map((x: any) => x.id)).toContain(o.json.id);
    expect(validateBundle(p)).toBeNull();

    // expired overrides are excluded from the bundle
    h.advance(31 * 60_000);
    p = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json;
    expect(p.overrides.map((x: any) => x.id)).not.toContain(o.json.id);
    // pruned after > 1 day
    h.advance(25 * 3600_000);
    await h.req('POST', '/v1/groups', A.token, { name: 'bump', webDomains: [] });
    expect((await h.req('GET', '/v1/overrides', A.token)).json.overrides.some((x: any) => x.id === o.json.id)).toBe(false);

    // device-targeted override isn't seen by other devices
    const d2 = await h.pair(A.token, 'Other');
    const t = await h.req('POST', '/v1/overrides', A.token, { groupIds: [g], action: 'unblock', durationMinutes: 10, deviceIds: [d2.deviceId] });
    const ids = async (tok: string) => (await h.req('GET', '/v1/devices/me/policy', tok)).json.overrides.map((x: any) => x.id);
    expect(await ids(d2.deviceToken)).toContain(t.json.id);
    expect(await ids(d.deviceToken)).not.toContain(t.json.id);
    expect((await h.req('DELETE', `/v1/overrides/${t.json.id}`, A.token)).status).toBe(204);
    expect(await ids(d2.deviceToken)).not.toContain(t.json.id);

    // API key
    const k = await h.req('POST', '/v1/api-keys', A.token, { name: 'ha' });
    expect(k.status).toBe(201);
    expect(k.json.key).toMatch(/^tk_live_/);
    const list = await h.req('GET', '/v1/api-keys', A.token);
    expect(list.json.keys[0]).not.toHaveProperty('key');
    const blocked = await h.req('POST', '/v1/actions/block', k.json.key, { groupIds: [g], durationMinutes: 60 });
    expect(blocked.status).toBe(201);
    expect(blocked.json.action).toBe('block');
    const pp = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json;
    expect(pp.overrides.some((x: any) => x.action === 'block')).toBe(true);
    const un = await h.req('POST', '/v1/actions/unblock', k.json.key, { groupIds: [g] });
    expect(un.status).toBe(201);
    const pp2 = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json;
    // later issuedAt wins deterministically
    const [b, u] = [pp2.overrides.find((x: any) => x.id === blocked.json.id), pp2.overrides.find((x: any) => x.id === un.json.id)];
    expect(Date.parse(u.issuedAt)).toBeGreaterThan(Date.parse(b.issuedAt));
    // keys cannot manage keys or sessions
    expect((await h.req('GET', '/v1/api-keys', k.json.key)).status).toBe(403);
    expect((await h.req('POST', '/v1/api-keys', k.json.key, { name: 'x' })).status).toBe(403);
    expect((await h.req('GET', '/v1/groups', k.json.key)).status).toBe(200);
    // device tokens cannot use admin endpoints and vice versa
    expect((await h.req('GET', '/v1/groups', d.deviceToken)).status).toBe(403);
    expect((await h.req('GET', '/v1/devices/me/policy', A.token)).status).toBe(403);
    // revoked key
    expect((await h.req('DELETE', `/v1/api-keys/${k.json.id}`, A.token)).status).toBe(204);
    expect((await h.req('POST', '/v1/actions/block', k.json.key, { groupIds: [g] })).status).toBe(401);
  });

  it('manual rule toggle', async () => {
    const g = (await h.req('POST', '/v1/groups', A.token, { name: 'HW', webDomains: [] })).json.id;
    const d = await h.pair(A.token, 'HWDev');
    const r = await h.req('POST', '/v1/rules', A.token, { name: 'Homework mode', groupIds: [g], action: 'block', strictness: 'strict', trigger: { type: 'manual', active: false } });
    const v = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json.version;
    const t = await h.req('POST', `/v1/rules/${r.json.id}/toggle`, A.token, { active: true });
    expect(t.json.trigger).toEqual({ type: 'manual', active: true });
    const p = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json;
    expect(p.version).toBe(v + 1);
    const det = await h.req('GET', `/v1/devices/${d.deviceId}`, A.token);
    expect(det.json.currentState.find((s: any) => s.groupId === g)).toMatchObject({ blocked: true, strict: true });
    const sched = await h.req('POST', '/v1/rules', A.token, { name: 's', groupIds: [g], action: 'block', trigger: { type: 'schedule', windows: [{ days: [1], start: '01:00', end: '02:00' }] } });
    expect((await h.req('POST', `/v1/rules/${sched.json.id}/toggle`, A.token, { active: true })).status).toBe(422);
    const pr = await h.req('PATCH', `/v1/rules/${r.json.id}`, A.token, { enabled: false });
    expect(pr.json.enabled).toBe(false);
    expect(pr.json.name).toBe('Homework mode');
  });

  it('group delete cascades', async () => {
    const g1 = (await h.req('POST', '/v1/groups', A.token, { name: 'C1', webDomains: [] })).json.id;
    const r = await h.req('POST', '/v1/rules', A.token, { name: 'c', groupIds: [g1], action: 'block', trigger: { type: 'manual', active: true } });
    expect((await h.req('DELETE', `/v1/groups/${g1}`, A.token)).status).toBe(204);
    expect((await h.req('GET', '/v1/rules', A.token)).json.rules.some((x: any) => x.id === r.json.id)).toBe(false);
  });
});

describe('account isolation', () => {
  it('admin B cannot see or touch A resources', async () => {
    const d = await h.pair(A.token, 'IsoDev');
    const g = (await h.req('POST', '/v1/groups', A.token, { name: 'Iso', webDomains: [] })).json.id;
    expect((await h.req('GET', '/v1/devices', B.token)).json.devices).toEqual([]);
    expect((await h.req('GET', `/v1/devices/${d.deviceId}`, B.token)).status).toBe(404);
    expect((await h.req('DELETE', `/v1/devices/${d.deviceId}`, B.token)).status).toBe(404);
    expect((await h.req('GET', '/v1/groups', B.token)).json.groups).toEqual([]);
    expect((await h.req('PATCH', `/v1/groups/${g}`, B.token, { name: 'x' })).status).toBe(404);
    expect((await h.req('POST', '/v1/rules', B.token, { name: 'r', groupIds: [g], action: 'block', trigger: { type: 'manual', active: true } })).status).toBe(422);
    expect((await h.req('POST', '/v1/actions/block', B.token, { groupIds: [g] })).status).toBe(422);
    expect((await h.req('GET', '/v1/overrides', B.token)).json.overrides).toEqual([]);
    expect((await h.req('GET', '/v1/unlock-requests', B.token)).json.requests).toEqual([]);
    // B's mutations don't bump A's devices
    const v = (await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json.version;
    await h.req('POST', '/v1/groups', B.token, { name: 'Bs', webDomains: [] });
    expect((await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json.version).toBe(v);
    expect((await h.req('GET', '/v1/devices/me/policy', d.deviceToken)).json.groups.some((x: any) => x.name === 'Bs')).toBe(false);
  });
});

describe('rate limiting', () => {
  it('limits login attempts', async () => {
    const rl = await harness({ rateLimit: { windowMs: 60_000, authMax: 3, enrollMax: 2, pairingMax: 50 } });
    for (let i = 0; i < 3; i++) expect((await rl.req('POST', '/v1/auth/login', null, { email: 'z@x.test', password: 'x' })).status).toBe(401);
    const r = await rl.req('POST', '/v1/auth/login', null, { email: 'z@x.test', password: 'x' });
    expect(r.status).toBe(429);
    expect(r.json.error.code).toBe('rate_limited');
    await rl.app.close();
  });
});

describe('device time zone', () => {
  it('server-side currentState uses the device tz reported on ack when the account has none', async () => {
    // Pin the clock: 2026-11-09T17:00Z = Monday 09:00 in Los Angeles, 17:00 in UTC.
    h.clock.t = new Date('2026-11-09T17:00:00Z');
    const g = (await h.req('POST', '/v1/groups', A.token, { name: 'TZ', webDomains: [] })).json.id;
    await h.req('POST', '/v1/rules', A.token, {
      name: 'tz-rule', groupIds: [g], enabled: true, action: 'block', strictness: 'flexible',
      trigger: { type: 'schedule', windows: [{ days: [1], start: '08:00', end: '10:00' }] },
    });
    const d3 = await h.pair(A.token, 'TZ phone');
    const blockedFor = async () =>
      (await h.req('GET', `/v1/devices/${d3.deviceId}`, A.token)).json.currentState.find((s: { groupId: string }) => s.groupId === g).blocked;
    expect(await blockedFor()).toBe(false); // evaluated in UTC: 17:00 is outside 08:00-10:00
    const ack = await h.req('POST', '/v1/devices/me/ack', d3.deviceToken, {
      version: 1, appliedAt: '2026-11-09T17:00:00Z', blockedGroupIds: [], authorizationStatus: 'approved', timeZone: 'America/Los_Angeles',
    });
    expect(ack.status).toBe(204);
    expect(await blockedFor()).toBe(true); // 09:00 Los Angeles
    const bad = await h.req('POST', '/v1/devices/me/ack', d3.deviceToken, {
      version: 1, appliedAt: '2026-11-09T17:00:00Z', blockedGroupIds: [], authorizationStatus: 'approved', timeZone: 'Mars/Olympus',
    });
    expect(bad.status).toBe(422);
  });
});
