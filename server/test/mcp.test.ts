import { describe, expect, it } from 'vitest';
import { harness, type Harness } from './helpers.js';
import { parseTime } from '../src/mcp.js';

async function setup() {
  const h = await harness();
  const { token } = await h.register();
  const key = (await h.req('POST', '/v1/api-keys', token, { name: 'claude' })).json.key as string;
  const dev = await h.pair(token, 'Zakir iPhone');
  await h.req('PUT', '/v1/devices/me/push-token', dev.deviceToken, { token: 'ab'.repeat(32), environment: 'sandbox' });
  // Device reports its zone on ack; MCP renders and parses times in it.
  await h.req('POST', '/v1/devices/me/ack', dev.deviceToken, {
    version: 1, appliedAt: h.clock.t.toISOString(), blockedGroupIds: [], authorizationStatus: 'approved', timeZone: 'America/Los_Angeles',
  });
  let id = 0;
  const rpc = async (method: string, params?: unknown, k = key) =>
    h.req('POST', '/mcp', k, { jsonrpc: '2.0', id: ++id, method, params });
  const tool = async (name: string, args: Record<string, unknown> = {}) => {
    const r = await rpc('tools/call', { name, arguments: args });
    expect(r.status).toBe(200);
    return { text: r.json.result.content[0].text as string, isError: !!r.json.result.isError };
  };
  return { h, key, token, dev, rpc, tool };
}

describe('mcp protocol', () => {
  it('initialize, tools/list, notifications, auth', async () => {
    const { h, rpc } = await setup();
    const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '1' } });
    expect(init.json.result.protocolVersion).toBe('2025-06-18');
    expect(init.json.result.serverInfo.name).toBe('tether');
    const n = await h.req('POST', '/mcp', (await h.req('POST', '/v1/api-keys', (await h.register()).token, { name: 'x' })).json.key,
      { jsonrpc: '2.0', method: 'notifications/initialized' });
    expect(n.status).toBe(202);
    const list = await rpc('tools/list');
    expect(list.json.result.tools.map((t: { name: string }) => t.name)).toContain('block');
    expect((await rpc('nope')).json.error.code).toBe(-32601);
    expect((await h.req('POST', '/mcp', null, { jsonrpc: '2.0', id: 1, method: 'ping' })).status).toBe(401);
    expect((await h.req('GET', '/mcp', null)).status).toBe(405);
    expect((await h.req('POST', '/mcp', 'tk_live_bad', { jsonrpc: '2.0', id: 1, method: 'ping' })).status).toBe(401);
  });
});

describe('mcp tools', () => {
  it('create group, block for minutes, status, end by group', async () => {
    const { h, tool, dev } = await setup();
    expect((await tool('create_group', { name: 'Social', websites: ['instagram.com'] })).text).toContain('Choose apps for Social');
    await h.app.ctx.push.flush();
    const pushesBefore = h.push.sent.length;

    const b = await tool('block', { groups: ['social'], minutes: 45 });
    expect(b.isError).toBe(false);
    // 17:00Z = 09:00 PST; +45 min
    expect(b.text).toMatch(/Blocked Social until 9:45/);
    await h.app.ctx.push.flush();
    expect(h.push.sent.length).toBeGreaterThan(pushesBefore);

    const pol = await h.req('GET', '/v1/devices/me/policy', dev.deviceToken);
    expect(pol.json.overrides).toHaveLength(1);
    expect(pol.json.overrides[0].endsAt).toBe('2026-11-09T17:45:00Z');

    const st = await tool('status');
    expect(st.text).toContain('America/Los_Angeles');
    expect(st.text).toMatch(/BLOCK Social until 9:45/);
    expect(st.text).toMatch(/Zakir iPhone .*server expects: blocked Social/);
    // The phone hasn't applied the new policy yet: its own report is shown separately and flagged.
    expect(st.text).toMatch(/phone reports \(policy v1, latest v\d+ - not applied yet\): nothing blocked/);

    // Phone applies the latest policy and reports what it actually blocked (incl. a phone-made group).
    const latest = pol.json.version as number;
    const gid = pol.json.groups[0].id as string;
    await h.req('POST', '/v1/devices/me/ack', dev.deviceToken, {
      version: latest, appliedAt: h.clock.t.toISOString(), blockedGroupIds: [gid, 'lgrp_local1'],
      authorizationStatus: 'approved', timeZone: 'America/Los_Angeles',
    });
    expect((await tool('status')).text).toContain(`phone reports (policy v${latest}): blocked Social + 1 phone-made group`);

    expect((await tool('end', { groups: ['Social'] })).text).toContain('Ended 1');
    expect((await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json.overrides).toHaveLength(0);
  });

  it('scheduled time block in phone-local time; allow; validation errors', async () => {
    const { tool, h, dev } = await setup();
    await tool('create_group', { name: 'Games' });
    const b = await tool('block', { groups: ['Games'], start: '15:00', until: '17:00', reason: 'homework' });
    expect(b.text).toMatch(/from 3:00 PM until 5:00 PM/);
    const o = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json.overrides[0];
    expect(o.startsAt).toBe('2026-11-09T23:00:00Z');
    expect(o.endsAt).toBe('2026-11-10T01:00:00Z');
    expect((await tool('status')).text).toContain('Upcoming:');

    expect((await tool('allow', { groups: ['all'], minutes: 10 })).text).toMatch(/Allowed Games until 9:10/);
    expect((await tool('block', { groups: ['Games'] })).isError).toBe(true);
    expect((await tool('block', { groups: ['Nope'], minutes: 5 })).text).toContain('Unknown group "Nope". Known: Games');
    expect((await tool('end', { all: true })).text).toContain('Ended 2');
  });

  it('schedules, modes, group + settings updates', async () => {
    const { tool, h, dev } = await setup();
    await tool('create_group', { name: 'Social' });
    expect((await tool('add_schedule', { name: 'Work', groups: ['Social'], days: ['weekdays'], start: '9:00', end: '17:30' })).isError).toBe(false);
    const pol = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json;
    expect(pol.rules[0].trigger).toEqual({ type: 'schedule', windows: [{ days: [1, 2, 3, 4, 5], start: '09:00', end: '17:30' }] });
    expect((await tool('status')).text).toContain('Work: block Social | mon,tue,wed,thu,fri 09:00-17:30');
    expect((await tool('remove_schedule', { schedule: 'work' })).text).toBe('Removed Work.');

    expect((await tool('update_group', { group: 'Social', websites: ['x.com', 'reddit.com'] })).text).toContain('x.com, reddit.com');
    expect((await tool('update_settings', { allowLocalRules: false })).text).toContain('"allowLocalRules":false');
    const pol2 = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json;
    expect(pol2.groups[0].webDomains).toEqual(['x.com', 'reddit.com']);
    expect(pol2.settings.allowLocalRules).toBe(false);

    expect((await tool('pairing_code')).text).toMatch(/^Pairing code [A-Z0-9]{4}-[A-Z0-9]{4}/);
    expect((await tool('delete_group', { group: 'Social' })).text).toBe('Deleted group Social.');
  });

  it('unlock requests: list (also in status), approve groups with minutes, deny, approve disableProtection', async () => {
    const { tool, h, dev } = await setup();
    await tool('create_group', { name: 'Games' });
    const gid = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json.groups[0].id;
    expect((await tool('unlock_requests')).text).toBe('No pending unlock requests.');

    const g = (await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'groups', groupIds: [gid], minutes: 15, reason: 'homework done' })).json;
    const p = (await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'disableProtection' })).json;
    const list = (await tool('unlock_requests')).text;
    expect(list).toContain(`unlock Games for 15 min "homework done" from Zakir iPhone`);
    expect(list).toContain(`turn off protection from Zakir iPhone`);
    expect(list).toContain(`id=${g.id}`);
    expect((await tool('status')).text).toContain('Pending unlock requests: 2 (see unlock_requests)');

    const ap = await tool('approve_unlock', { id: g.id, minutes: 20 });
    expect(ap.text).toMatch(/^Approved: Games unlocked for 20 min/);
    const pol = (await h.req('GET', '/v1/devices/me/policy', dev.deviceToken)).json;
    expect(pol.overrides).toHaveLength(1);
    expect(pol.overrides[0].action).toBe('unblock');
    expect((await tool('approve_unlock', { id: g.id })).isError).toBe(true); // already decided

    const dn = await tool('deny_unlock', { id: p.id, note: 'not tonight' });
    expect(dn.text).toBe('Denied: turn off protection.');
    expect((await h.req('GET', `/v1/devices/me/unlock-requests/${p.id}`, dev.deviceToken)).json.status).toBe('denied');

    const p2 = (await h.req('POST', '/v1/devices/me/unlock-requests', dev.deviceToken, { kind: 'disableProtection' })).json;
    expect((await tool('approve_unlock', { id: p2.id })).text).toBe('Approved: the phone may now turn off protection.');
    expect((await tool('unlock_requests', { all: true })).text).toContain('[denied]');
    expect((await tool('unlock_requests')).text).toBe('No pending unlock requests.');
  });
});

describe('parseTime', () => {
  const after = new Date('2026-11-09T17:00:00Z'); // 09:00 in Los Angeles
  const tz = 'America/Los_Angeles';
  it('HH:mm is the next occurrence in the zone', () => {
    expect(parseTime('17:00', tz, after).toISOString()).toBe('2026-11-10T01:00:00.000Z');
    expect(parseTime('08:00', tz, after).toISOString()).toBe('2026-11-10T16:00:00.000Z'); // tomorrow
  });
  it('ISO without offset = wall time in zone; with offset = absolute', () => {
    expect(parseTime('2026-11-12T10:30', tz, after).toISOString()).toBe('2026-11-12T18:30:00.000Z');
    expect(parseTime('2026-11-12T10:30:00Z', tz, after).toISOString()).toBe('2026-11-12T10:30:00.000Z');
  });
  it('DST: summer wall time uses PDT', () => {
    expect(parseTime('2027-07-01T12:00', tz, after).toISOString()).toBe('2027-07-01T19:00:00.000Z');
  });
});

export type { Harness };
