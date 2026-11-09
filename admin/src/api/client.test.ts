import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError, api, list, onUnauthorized, parseError, setToken } from './client';

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

beforeEach(() => setToken(null));
afterEach(() => { vi.restoreAllMocks(); onUnauthorized(null); });

describe('error parsing', () => {
  it('parses {error:{code,message}}', async () => {
    const e = await parseError(json(422, { error: { code: 'validation_failed', message: 'name too long' } }));
    expect(e).toBeInstanceOf(ApiError);
    expect(e.status).toBe(422);
    expect(e.code).toBe('validation_failed');
    expect(e.message).toBe('name too long');
  });
  it('handles non-JSON bodies', async () => {
    const e = await parseError(new Response('Bad gateway', { status: 502 }));
    expect(e.status).toBe(502);
    expect(e.message).toBe('Bad gateway');
  });
  it('handles empty bodies', async () => {
    const e = await parseError(new Response('', { status: 500 }));
    expect(e.message).toMatch(/500/);
  });
});

describe('request', () => {
  it('sends bearer token and JSON body, unwraps lists', async () => {
    setToken('tok');
    const spy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(json(200, { groups: [{ id: 'grp_1', name: 'x', webDomains: [] }] }));
    const groups = await api.listGroups();
    expect(groups).toHaveLength(1);
    const [url, init] = spy.mock.calls[0]!;
    expect(url).toBe('/v1/groups');
    expect((init!.headers as Record<string, string>).Authorization).toBe('Bearer tok');
  });
  it('POSTs bodies and handles 204', async () => {
    const spy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(null, { status: 204 }));
    await expect(api.pushDevice('dev_1')).resolves.toBeUndefined();
    expect(spy.mock.calls[0]![1]!.method).toBe('POST');
  });
  it('calls unauthorized handler on 401 with a token', async () => {
    setToken('tok');
    const h = vi.fn();
    onUnauthorized(h);
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(json(401, { error: { code: 'unauthorized', message: 'expired' } }));
    await expect(api.me()).rejects.toMatchObject({ status: 401, code: 'unauthorized' });
    expect(h).toHaveBeenCalled();
  });
  it('maps network failures', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('fail'));
    await expect(api.me()).rejects.toMatchObject({ code: 'network' });
  });
  it('list() tolerates shapes', () => {
    expect(list([1], 'x')).toEqual([1]);
    expect(list({ other: [2] }, 'x')).toEqual([2]);
    expect(list(null, 'x')).toEqual([]);
  });
});
