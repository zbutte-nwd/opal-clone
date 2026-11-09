import { generateKeyPairSync, createVerify } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  alertPayload, backgroundPayload, createProviderJwt, policyTether, shouldClearToken, ApnsTransport,
} from '../src/push/apns.js';
import type { PolicyBundle } from '../src/engine/index.js';

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();

const bundle = (n: number): PolicyBundle => ({
  version: 7, generatedAt: '2026-11-09T17:00:00Z', timeZone: null, rules: [], overrides: [],
  groups: Array.from({ length: n }, (_, i) => ({ id: `grp_${i}`, name: `Group ${i}`, webDomains: ['example.com'] })),
  settings: { protectionLock: 'partnerPIN', allowLocalRules: true, denyAppRemoval: true },
});

describe('APNs', () => {
  it('provider JWT has ES256 header/claims and a verifiable raw signature', () => {
    const jwt = createProviderJwt(pem, 'KEYID12345', 'TEAMID1234', 1_700_000_000);
    const [h, c, s] = jwt.split('.');
    expect(JSON.parse(Buffer.from(h!, 'base64url').toString())).toEqual({ alg: 'ES256', kid: 'KEYID12345', typ: 'JWT' });
    expect(JSON.parse(Buffer.from(c!, 'base64url').toString())).toEqual({ iss: 'TEAMID1234', iat: 1_700_000_000 });
    const sig = Buffer.from(s!, 'base64url');
    expect(sig.length).toBe(64);
    const v = createVerify('SHA256').update(`${h}.${c}`);
    expect(v.verify({ key: publicKey, dsaEncoding: 'ieee-p1363' }, sig)).toBe(true);
  });

  it('caches the provider token for ~50 minutes', () => {
    let t = 1_700_000_000_000;
    const tr = new ApnsTransport({ keyP8: pem, keyId: 'K', teamId: 'T', topic: 'x' }, () => t);
    const a = tr.providerToken();
    t += 49 * 60_000;
    expect(tr.providerToken()).toBe(a);
    t += 2 * 60_000;
    expect(tr.providerToken()).not.toBe(a);
  });

  it('payload shapes', () => {
    const small = policyTether(7, bundle(2));
    expect(small.type === 'policyUpdated' && small.bundle).toBeTruthy();
    expect(alertPayload(small)).toEqual({
      aps: { alert: { title: 'Tether', body: 'Your focus settings were updated' }, 'mutable-content': 1 }, tether: small,
    });
    expect(backgroundPayload(small)).toEqual({ aps: { 'content-available': 1 }, tether: small });
    const big = policyTether(7, bundle(100));
    expect(big).toEqual({ type: 'policyUpdated', version: 7 });
  });

  it('token-clearing rules', () => {
    expect(shouldClearToken({ status: 410, reason: 'Unregistered' })).toBe(true);
    expect(shouldClearToken({ status: 400, reason: 'BadDeviceToken' })).toBe(true);
    expect(shouldClearToken({ status: 400, reason: 'PayloadEmpty' })).toBe(false);
    expect(shouldClearToken({ status: 200 })).toBe(false);
  });
});
