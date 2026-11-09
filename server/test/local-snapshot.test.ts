import { describe, expect, it } from 'vitest';
import { harness, localFixture, validateLocal } from './helpers.js';

async function setup() {
  const h = await harness();
  const admin = await h.register();
  const dev = await h.pair(admin.token, 'phone', '0.2.0');
  const local = async () => (await h.req('GET', `/v1/devices/${dev.deviceId}`, admin.token)).json.local;
  return { h, admin, dev, local };
}

describe('PUT /devices/me/local (read-only phone snapshot)', () => {
  it('stores the snapshot; GET /devices/:id returns it; it matches the contract', async () => {
    const { h, dev, local } = await setup();
    expect(await local()).toBeNull();
    const snap = localFixture();
    expect(validateLocal(snap)).toBeNull();
    expect((await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, snap)).status).toBe(204);
    const l = await local();
    expect(l.receivedAt).toBe('2026-11-09T17:00:00Z');
    expect(l.snapshot).toEqual(snap);
    expect(validateLocal(l.snapshot)).toBeNull();
  });

  it('unchanged hash: 204 and no write (receivedAt unchanged); a new hash replaces it', async () => {
    const { h, dev, local } = await setup();
    const snap = localFixture();
    await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, snap);
    h.advance(60_000);
    const again = { ...snap, reportedAt: '2026-11-09T17:06:00Z' };
    expect((await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, again)).status).toBe(204);
    expect((await local()).receivedAt).toBe('2026-11-09T17:00:00Z');
    expect((await local()).snapshot.reportedAt).toBe(snap.reportedAt);
    const changed = { ...snap, hash: 'a'.repeat(64), groups: [] };
    expect((await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, changed)).status).toBe(204);
    expect((await local()).receivedAt).toBe('2026-11-09T17:01:00Z');
    expect((await local()).snapshot.groups).toEqual([]);
  });

  it('rejects app identities / unknown keys (422), oversize bodies (413), admin credentials', async () => {
    const { h, admin, dev } = await setup();
    const snap = localFixture();
    snap.groups[0].appTokens = ['abc'];
    const bad = await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, snap);
    expect(bad.status).toBe(422);
    const top = { ...localFixture(), extra: 1 };
    expect((await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, top)).status).toBe(422);
    const big = { ...localFixture(), groups: [{ ...localFixture().groups[0], name: 'x'.repeat(300_000) }] };
    expect((await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, big)).status).toBe(413);
    const key = (await h.req('POST', '/v1/api-keys', admin.token, { name: 'k' })).json.key;
    expect((await h.req('PUT', '/v1/devices/me/local', key, localFixture())).status).toBe(403);
    expect((await h.req('PUT', '/v1/devices/me/local', admin.token, localFixture())).status).toBe(403);
    expect((await h.req('PUT', '/v1/devices/me/local', null, localFixture())).status).toBe(401);
  });

  it('a guarded allow rule in the snapshot is rejected like the contract does', async () => {
    const { h, dev } = await setup();
    const snap = localFixture();
    snap.rules[0].action = 'allow';
    expect(validateLocal(snap)).not.toBeNull();
    expect((await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, snap)).status).toBe(422);
  });

  it('is deleted with the device (admin unpair and device self-unpair)', async () => {
    const { h, admin, dev } = await setup();
    await h.req('PUT', '/v1/devices/me/local', dev.deviceToken, localFixture());
    expect((await h.req('DELETE', `/v1/devices/${dev.deviceId}`, admin.token)).status).toBe(204);
    const count = () => (h.app.ctx.db.prepare('SELECT COUNT(*) AS n FROM device_local').get() as { n: number }).n;
    expect(count()).toBe(0);

    const dev2 = await h.pair(admin.token, 'phone2', '0.2.0');
    await h.req('PUT', '/v1/devices/me/local', dev2.deviceToken, localFixture());
    expect(count()).toBe(1);
    // protection_enabled is NULL until the phone reports, so self-unpair is allowed
    expect((await h.req('DELETE', '/v1/devices/me', dev2.deviceToken)).status).toBe(204);
    expect(count()).toBe(0);
  });
});
