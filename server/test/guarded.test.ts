import { describe, expect, it } from 'vitest';
import { appVersionAtLeast } from '../src/util.js';
import { harness, validateBundle } from './helpers.js';

describe('appVersionAtLeast', () => {
  it('compares numerically; missing or garbage is old', () => {
    expect(appVersionAtLeast('0.2.0', '0.2.0')).toBe(true);
    expect(appVersionAtLeast('0.10.0', '0.2.0')).toBe(true);
    expect(appVersionAtLeast('1.0', '0.2.0')).toBe(true);
    expect(appVersionAtLeast('0.1.9', '0.2.0')).toBe(false);
    expect(appVersionAtLeast('0.2', '0.2.0')).toBe(true);
    expect(appVersionAtLeast(null, '0.2.0')).toBe(false);
    expect(appVersionAtLeast(undefined, '0.2.0')).toBe(false);
    expect(appVersionAtLeast('', '0.2.0')).toBe(false);
    expect(appVersionAtLeast('abc', '0.2.0')).toBe(false);
  });
});

const sched = { type: 'schedule', windows: [{ days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00' }] };

describe('guarded strictness', () => {
  it('only block rules may be guarded', async () => {
    const h = await harness();
    const { token } = await h.register();
    const g = (await h.req('POST', '/v1/groups', token, { name: 'Social' })).json.id;
    const allow = await h.req('POST', '/v1/rules', token, { name: 'a', groupIds: [g], action: 'allow', strictness: 'guarded', trigger: sched });
    expect(allow.status).toBe(422);
    const r = await h.req('POST', '/v1/rules', token, { name: 'w', groupIds: [g], action: 'block', strictness: 'guarded', trigger: sched });
    expect(r.status).toBe(201);
    expect(r.json.strictness).toBe('guarded');
    // PATCH to allow on a guarded rule is rejected too
    expect((await h.req('PATCH', `/v1/rules/${r.json.id}`, token, { action: 'allow' })).status).toBe(422);
  });

  it('sent as guarded to app >= 0.2.0, as flexible to older apps; both bundles valid', async () => {
    const h = await harness();
    const { token } = await h.register();
    const g = (await h.req('POST', '/v1/groups', token, { name: 'Social' })).json.id;
    await h.req('POST', '/v1/rules', token, { name: 'Work', groupIds: [g], action: 'block', strictness: 'guarded', trigger: sched });
    const nu = await h.pair(token, 'new', '0.2.0');
    const old = await h.pair(token, 'old', '0.1.0');
    const pn = (await h.req('GET', '/v1/devices/me/policy', nu.deviceToken)).json;
    const po = (await h.req('GET', '/v1/devices/me/policy', old.deviceToken)).json;
    expect(pn.rules[0].strictness).toBe('guarded');
    expect(po.rules[0].strictness).toBe('flexible');
    expect(validateBundle(pn)).toBeNull();
    expect(validateBundle(po)).toBeNull();

    // The push's inline bundle is gated the same way.
    await h.req('PUT', '/v1/devices/me/push-token', old.deviceToken, { token: 'ab'.repeat(32), environment: 'sandbox' });
    await h.req('PUT', '/v1/devices/me/push-token', nu.deviceToken, { token: 'cd'.repeat(32), environment: 'sandbox' });
    await h.app.ctx.push.flush();
    h.push.clear();
    await h.req('PATCH', `/v1/rules/${pn.rules[0].id}`, token, { name: 'Work2' });
    await h.app.ctx.push.flush();
    const inline = (tok: string) => (h.push.sent.find((p) => p.deviceToken === tok && p.pushType === 'alert')!.payload as any).tether.bundle;
    expect(inline('ab'.repeat(32)).rules[0].strictness).toBe('flexible');
    expect(inline('cd'.repeat(32)).rules[0].strictness).toBe('guarded');
  });

  it('app_version follows the User-Agent, and a change re-versions the policy', async () => {
    const h = await harness();
    const { token } = await h.register();
    const g = (await h.req('POST', '/v1/groups', token, { name: 'Social' })).json.id;
    await h.req('POST', '/v1/rules', token, { name: 'Work', groupIds: [g], action: 'block', strictness: 'guarded', trigger: sched });
    const dev = await h.pair(token, 'phone', '0.1.0');
    const p1 = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken, undefined, { 'user-agent': 'Tether-iOS/0.1.0' });
    expect(p1.json.rules[0].strictness).toBe('flexible');
    // The phone updates to 0.2.0: its cached ETag must not 304, and the rule now comes back guarded.
    const p2 = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken, undefined,
      { 'user-agent': 'Tether-iOS/0.2.0', 'if-none-match': p1.headers.etag as string });
    expect(p2.status).toBe(200);
    expect(p2.json.rules[0].strictness).toBe('guarded');
    expect(p2.json.version).toBeGreaterThan(p1.json.version);
    // Other User-Agents (curl, admin tools) leave the stored version alone.
    await h.req('GET', '/v1/devices/me/policy', dev.deviceToken, undefined, { 'user-agent': 'curl/8.0' });
    const row = h.app.ctx.db.prepare('SELECT app_version FROM devices WHERE id = ?').get(dev.deviceId) as { app_version: string };
    expect(row.app_version).toBe('0.2.0');
  });
});

describe('BlockGroup.copiedFrom', () => {
  it('POST /groups accepts copiedFrom (lgrp_ only); the bundle carries it; PATCH keeps it', async () => {
    const h = await harness();
    const { token } = await h.register();
    expect((await h.req('POST', '/v1/groups', token, { name: 'X', copiedFrom: 'grp_nope' })).status).toBe(422);
    const g = await h.req('POST', '/v1/groups', token, { name: 'Socials', copiedFrom: 'lgrp_socials1' });
    expect(g.status).toBe(201);
    expect(g.json.copiedFrom).toBe('lgrp_socials1');
    await h.req('PATCH', `/v1/groups/${g.json.id}`, token, { name: 'Socials 2' });
    const plain = (await h.req('POST', '/v1/groups', token, { name: 'Plain' })).json;
    expect('copiedFrom' in plain).toBe(false);
    const dev = await h.pair(token, 'p', '0.2.0');
    const b = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json;
    expect(b.groups.find((x: any) => x.id === g.json.id).copiedFrom).toBe('lgrp_socials1');
    expect(b.groups.find((x: any) => x.id === plain.id).copiedFrom).toBeUndefined();
    expect(validateBundle(b)).toBeNull();
  });
});
