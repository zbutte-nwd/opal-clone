import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { harness, validateBundle, type Harness } from './helpers.js';

let h: Harness;
let A: { token: string };
let dev: { deviceId: string; deviceToken: string };
let g: string;

beforeAll(async () => {
  h = await harness();
  A = await h.register();
  g = (await h.req('POST', '/v1/groups', A.token, { name: 'Social', webDomains: [] })).json.id;
  dev = await h.pair(A.token);
  await h.req('PUT', '/v1/devices/me/push-token', dev.deviceToken, { token: 'ab'.repeat(32), environment: 'sandbox' });
});
afterAll(async () => { await h.app.close(); });

describe('unlock requests', () => {
  it('validates creation', async () => {
    expect((await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'groups' })).status).toBe(422);
    expect((await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'groups', groupIds: ['grp_x'], minutes: 5 })).status).toBe(422);
  });

  it('groups: approve creates unblock override and bumps', async () => {
    const c = await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'groups', groupIds: [g], minutes: 15, reason: 'homework' });
    expect(c.status).toBe(201);
    expect(c.json).toMatchObject({ kind: 'groups', status: 'pending', minutes: 15, groupIds: [g] });
    const v = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json.version;
    const pend = await h.req('GET', '/v1/unlock-requests?status=pending', A.token);
    expect(pend.json.requests).toHaveLength(1);
    h.push.clear();
    const ap = await h.req('POST', `/v1/unlock-requests/${c.json.id}/approve`, A.token, { minutes: 20 });
    expect(ap.status).toBe(200);
    expect(ap.json.status).toBe('approved');
    expect(ap.json.overrideId).toMatch(/^ovr_/);
    const p = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json;
    expect(p.version).toBe(v + 1);
    const o = p.overrides.find((x: any) => x.id === ap.json.overrideId);
    expect(o.action).toBe('unblock');
    expect(Date.parse(o.endsAt) - Date.parse(o.startsAt)).toBe(20 * 60_000);
    expect(validateBundle(p)).toBeNull();
    await h.app.ctx.push.flush();
    expect(h.push.sent.length).toBe(2);
    // device sees decision; double-decide conflicts
    const got = await h.req('GET', `/v1/devices/me/unlock-requests/${c.json.id}`, dev.deviceToken);
    expect(got.json.status).toBe('approved');
    expect((await h.req('POST', `/v1/unlock-requests/${c.json.id}/deny`, A.token, {})).status).toBe(409);
    expect((await h.req('GET', '/v1/unlock-requests', A.token)).json.requests).toHaveLength(1);
  });

  it('disableProtection: approve pushes unlockDecided, no policy change', async () => {
    const c = await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'disableProtection', reason: 'new phone' });
    expect(c.status).toBe(201);
    const v = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json.version;
    h.push.clear();
    const ap = await h.req('POST', `/v1/unlock-requests/${c.json.id}/approve`, A.token, {});
    expect(ap.json.status).toBe('approved');
    expect(ap.json.overrideId).toBeNull();
    await h.app.ctx.push.flush();
    expect(h.push.sent.length).toBe(2);
    expect((h.push.sent[0]!.payload as any).tether).toEqual({ type: 'unlockDecided', requestId: c.json.id });
    expect((await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json.version).toBe(v);
    // approved disableProtection allows self-unpair
    h.app.ctx.db.prepare('UPDATE devices SET protection_enabled = 1 WHERE id = ?').run(dev.deviceId);
    expect((await h.req('DELETE', '/v1/devices/me', dev.deviceToken)).status).toBe(204);
  });

  it('deny with note, and 24h expiry', async () => {
    const d = await h.pair(A.token, 'D2');
    const c = await h.req('POST', '/v1/devices/me/unlock-requests', d.deviceToken, { kind: 'groups', groupIds: [g], minutes: 5 });
    const den = await h.req('POST', `/v1/unlock-requests/${c.json.id}/deny`, A.token, { note: 'not now' });
    expect(den.json).toMatchObject({ status: 'denied', note: 'not now' });

    const c2 = await h.req('POST', '/v1/devices/me/unlock-requests', d.deviceToken, { kind: 'disableProtection' });
    h.advance(24 * 3600_000 + 1000);
    const st = await h.req('GET', `/v1/devices/me/unlock-requests/${c2.json.id}`, d.deviceToken);
    expect(st.json.status).toBe('expired');
    expect((await h.req('POST', `/v1/unlock-requests/${c2.json.id}/approve`, A.token, {})).status).toBe(409);
    expect((await h.req('GET', '/v1/unlock-requests?status=pending', A.token)).json.requests).toHaveLength(0);
    expect((await h.req('GET', '/v1/unlock-requests', A.token)).json.requests.length).toBeGreaterThanOrEqual(2);
  });
});
