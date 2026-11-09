// MCP (Model Context Protocol) endpoint: lets an agent (Claude, Grok bot, …) drive Tether with a few
// high-level tools. Streamable HTTP transport, stateless, JSON responses only (no SSE): POST /mcp.
// Auth = the same bearer the REST API takes (an API key, tk_live_…). Every tool calls the REST routes
// in-process via `app.inject`, so validation, audit, policy bumps and APNs pushes are the REST ones.
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { adminAuth } from './auth/plugin.js';
import { VERSION } from './config.js';
import type { Ctx } from './context.js';
import { forbidden } from './errors.js';
import { isValidTimeZone } from './util.js';

const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const INSTRUCTIONS = `Tether blocks app/website groups on the user's iPhone.
- "Session" / "time block" = a block over a time range (tool: block). "Let me use X for 10 min" = allow.
- Groups are referenced by name (case-insensitive) or id; "all" means every group. Call status first if unsure.
- Times: minutes, or "HH:mm" (24 h, next occurrence), or ISO 8601. Times without an offset are in the
  phone's time zone, which status reports along with the current local time.
- Blocks from this server are strict on the phone (the user cannot pause them); end them with end.
- Schedules (add_schedule) are flexible, guarded or strict. Guarded = the user may pause, but cannot switch the
  schedule off, edit it, or remove apps from its groups while it is active (needs partner PIN or admin approval).
- Which apps belong to a group is chosen on the phone (Apple privacy rule); websites can be set here.
- status shows two views per device: "server expects" (computed from the policy) and "phone reports" (what the
  phone last acknowledged). Only the phone line, or the user looking at the phone, confirms an effect.
- Changes reach the phone within seconds via push (or at next app open if push isn't configured).
- Unlock requests come from the person holding the phone (unlock a group for N minutes, or turn off
  protection). status shows how many are pending; approve or deny one only when the admin tells you to.`;

// ---------------------------------------------------------------- tool schemas

const groupsArg = { type: 'array', items: { type: 'string' }, minItems: 1, description: 'Group names or ids, or ["all"]' };
const devicesArg = { type: 'array', items: { type: 'string' }, description: 'Device names or ids (default: all devices)' };
const timing = {
  minutes: { type: 'integer', minimum: 1, description: 'Duration in minutes (from start)' },
  until: { type: 'string', description: 'End time: "HH:mm" or ISO 8601' },
  start: { type: 'string', description: 'Start time: "HH:mm" or ISO 8601 (default: now)' },
  reason: { type: 'string', maxLength: 200, description: 'Shown on the phone' },
};
const days = { type: 'array', items: { type: 'string' }, description: 'mon..sun, or "weekdays", "weekends", "daily"' };

const TOOLS = [
  { name: 'status', description: 'Current local time, devices, what is blocked now, active/upcoming blocks, groups, schedules and settings. Call this first.',
    inputSchema: { type: 'object', properties: {} } },
  { name: 'block', description: 'Start a focus session now ("block social for 45 min") or schedule a one-off time block ("games 15:00-17:00"). Needs minutes or until, unless indefinite is true.',
    inputSchema: { type: 'object', required: ['groups'], properties: { groups: groupsArg, ...timing, indefinite: { type: 'boolean', description: 'No end time; lasts until ended' }, devices: devicesArg } } },
  { name: 'allow', description: 'Temporarily unblock groups (beats schedules and sessions), e.g. "allow social for 10 min".',
    inputSchema: { type: 'object', required: ['groups'], properties: { groups: groupsArg, ...timing, devices: devicesArg } } },
  { name: 'end', description: 'End (cancel) active or upcoming blocks/allows created by this server: by id, by groups, or all.',
    inputSchema: { type: 'object', properties: { id: { type: 'string' }, groups: groupsArg, all: { type: 'boolean' } } } },
  { name: 'create_group', description: 'Create a group. Websites apply immediately; the user picks the apps on the phone.',
    inputSchema: { type: 'object', required: ['name'], properties: { name: { type: 'string' }, websites: { type: 'array', items: { type: 'string' } }, color: { type: 'string', description: '#RRGGBB' } } } },
  { name: 'update_group', description: 'Rename a group, replace its websites, or change its color.',
    inputSchema: { type: 'object', required: ['group'], properties: { group: { type: 'string' }, name: { type: 'string' }, websites: { type: 'array', items: { type: 'string' } }, color: { type: 'string' } } } },
  { name: 'delete_group', description: 'Delete a group (also removes it from schedules and blocks).',
    inputSchema: { type: 'object', required: ['group'], properties: { group: { type: 'string' } } } },
  { name: 'add_schedule', description: 'Recurring time block, e.g. weekdays 09:00-17:00. Windows may cross midnight.',
    inputSchema: { type: 'object', required: ['name', 'groups', 'days', 'start', 'end'], properties: {
      name: { type: 'string' }, groups: groupsArg, days, start: { type: 'string', description: 'HH:mm' }, end: { type: 'string', description: 'HH:mm' },
      strictness: { enum: ['flexible', 'guarded', 'strict'], description: 'flexible (default): user can pause or edit it. guarded: user can pause, but changing or removing it while active needs the partner PIN or admin approval. strict: user cannot pause either.' },
      strict: { type: 'boolean', description: 'Same as strictness: "strict"' } } } },
  { name: 'remove_schedule', description: 'Delete a schedule or mode by name or id.',
    inputSchema: { type: 'object', required: ['schedule'], properties: { schedule: { type: 'string' } } } },
  { name: 'set_mode', description: 'Turn a manual mode rule (e.g. "Homework mode") on or off.',
    inputSchema: { type: 'object', required: ['mode', 'active'], properties: { mode: { type: 'string' }, active: { type: 'boolean' } } } },
  { name: 'update_settings', description: 'Change account settings pushed to the phone.',
    inputSchema: { type: 'object', properties: {
      protectionLock: { enum: ['partnerPIN', 'remoteApproval', 'osOnly'], description: 'How in-app protection can be turned off' },
      allowLocalRules: { type: 'boolean', description: 'Whether the phone may add its own schedules' },
      denyAppRemoval: { type: 'boolean', description: 'Block deleting apps while protected' },
      timeZone: { type: ['string', 'null'], description: 'IANA zone pinning schedules, or null = phone local' } } } },
  { name: 'pairing_code', description: 'Create a 10-minute code to pair a device (Tether app → Settings → Server).',
    inputSchema: { type: 'object', properties: { deviceName: { type: 'string' } } } },
  { name: 'unlock_requests', description: 'List unlock requests sent from the phone (unlock a group for a while, or turn off protection). Pending only unless all is true.',
    inputSchema: { type: 'object', properties: { all: { type: 'boolean', description: 'Include decided/expired requests' } } } },
  { name: 'approve_unlock', description: 'Approve a pending unlock request. Group requests unlock for the requested minutes (or minutes given here); a turn-off-protection request lets the phone switch protection off.',
    inputSchema: { type: 'object', required: ['id'], properties: { id: { type: 'string' },
      minutes: { type: 'integer', minimum: 1, maximum: 1440, description: 'Group requests only: override the requested duration' } } } },
  { name: 'deny_unlock', description: 'Deny a pending unlock request; the note is shown on the phone.',
    inputSchema: { type: 'object', required: ['id'], properties: { id: { type: 'string' }, note: { type: 'string', maxLength: 500 } } } },
] as const;

// ---------------------------------------------------------------- plumbing

class ToolError extends Error {}
type Json = any; // REST responses, shaped by contracts/api.md

interface Group { id: string; name: string; webDomains: string[]; colorHex?: string | null }
interface Rule { id: string; name: string; groupIds: string[]; enabled: boolean; action: string; strictness: string;
  trigger: { type: string; windows?: { days: number[]; start: string; end: string }[]; active?: boolean; dailyMinutes?: number } }
interface Unlock { id: string; deviceName: string | null; kind: 'groups' | 'disableProtection'; groupIds: string[];
  minutes: number | null; reason: string | null; status: string; createdAt: string; expiresAt: string; note: string | null }
interface Override { id: string; groupIds: string[]; action: string; startsAt: string; endsAt: string | null; reason: string | null; deviceIds?: string[] | null }

class Session {
  constructor(private app: FastifyInstance, private ctx: Ctx, private auth: string, private adminId: string) {}

  async api(method: 'GET' | 'POST' | 'PATCH' | 'DELETE', url: string, body?: unknown): Promise<Json> {
    const r = await this.app.inject({ method, url: '/v1' + url, headers: { authorization: this.auth },
      ...(body !== undefined ? { payload: body as object } : {}) });
    const json = r.body ? JSON.parse(r.body) : null;
    if (r.statusCode >= 400) throw new ToolError(json?.error?.message ?? `HTTP ${r.statusCode}`);
    return json;
  }

  /** Account tz if pinned, else the most recently seen device's reported tz, else this machine's zone. */
  timeZone(settingsTz: string | null): string {
    if (settingsTz) return settingsTz;
    const row = this.ctx.db.prepare(
      'SELECT time_zone FROM devices WHERE admin_id = ? AND time_zone IS NOT NULL ORDER BY last_seen_at DESC LIMIT 1',
    ).get(this.adminId) as { time_zone: string } | undefined;
    return row && isValidTimeZone(row.time_zone) ? row.time_zone : Intl.DateTimeFormat().resolvedOptions().timeZone;
  }

  async groups(): Promise<Group[]> { return (await this.api('GET', '/groups')).groups; }
  async rules(): Promise<Rule[]> { return (await this.api('GET', '/rules')).rules; }
  async tz(): Promise<string> { return this.timeZone((await this.api('GET', '/settings')).timeZone ?? null); }

  async resolveGroups(refs: string[]): Promise<Group[]> {
    const all = await this.groups();
    if (refs.some((r) => r.trim().toLowerCase() === 'all')) {
      if (!all.length) throw new ToolError('There are no groups yet; create one with create_group.');
      return all;
    }
    return refs.map((r) => findByNameOrId(all, r, 'group'));
  }

  async resolveDevices(refs: string[] | undefined): Promise<string[] | undefined> {
    if (!refs?.length) return undefined;
    const all = (await this.api('GET', '/devices')).devices as { id: string; name: string }[];
    return refs.map((r) => findByNameOrId(all, r, 'device').id);
  }
}

function findByNameOrId<T extends { id: string; name: string }>(list: T[], ref: string, what: string): T {
  const k = ref.trim().toLowerCase();
  const hit = list.find((x) => x.id === ref.trim()) ?? list.find((x) => x.name.toLowerCase() === k);
  if (!hit) throw new ToolError(`Unknown ${what} "${ref}". Known: ${list.map((x) => x.name).join(', ') || 'none'}`);
  return hit;
}

// ---------------------------------------------------------------- time helpers (exported for tests)

/** Offset (ms) of `tz` from UTC at instant `t`. */
function tzOffset(t: number, tz: string): number {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric',
    month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric' })
    .formatToParts(new Date(t)).map((x) => [x.type, Number(x.value)]));
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - Math.floor(t / 1000) * 1000;
}

/** Wall-clock time in `tz` → instant. */
function zoned(y: number, mo: number, d: number, h: number, mi: number, tz: string): Date {
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  let t = guess - tzOffset(guess, tz);
  t = guess - tzOffset(t, tz); // second pass settles DST edges
  return new Date(t);
}

/** "HH:mm" (next occurrence after `after`), ISO 8601 with offset, or ISO without offset (= wall time in tz). */
export function parseTime(s: string, tz: string, after: Date): Date {
  const v = s.trim();
  let m = /^(\d{1,2}):(\d{2})$/.exec(v);
  if (m) {
    const [h, mi] = [Number(m[1]), Number(m[2])];
    if (h > 23 || mi > 59) throw new ToolError(`Bad time "${s}"`);
    const local = new Date(after.getTime() + tzOffset(after.getTime(), tz));
    let d = zoned(local.getUTCFullYear(), local.getUTCMonth() + 1, local.getUTCDate(), h, mi, tz);
    if (d.getTime() <= after.getTime()) {
      const next = new Date(local.getTime() + 86_400_000);
      d = zoned(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), h, mi, tz);
    }
    return d;
  }
  m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$/.exec(v);
  if (m) return zoned(+m[1], +m[2], +m[3], +m[4], +m[5], tz);
  const t = Date.parse(v);
  if (Number.isNaN(t)) throw new ToolError(`Can't parse time "${s}" (use HH:mm or ISO 8601)`);
  return new Date(t);
}

export function fmtTime(iso: string | Date, tz: string, now: Date): string {
  const d = typeof iso === 'string' ? new Date(iso) : iso;
  const sameDay = (a: Date, b: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(a)
    === new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(b);
  const time = new Intl.DateTimeFormat('en-US', { timeZone: tz, hour: 'numeric', minute: '2-digit' }).format(d);
  if (sameDay(d, now)) return time;
  const day = new Intl.DateTimeFormat('en-US', { timeZone: tz, weekday: 'short', month: 'short', day: 'numeric' }).format(d);
  return `${day} ${time}`;
}

const DAY_NAMES = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
function parseDays(list: string[]): number[] {
  const out = new Set<number>();
  for (const raw of list) {
    const k = raw.trim().toLowerCase();
    if (k === 'daily' || k === 'everyday' || k === 'every day') [1, 2, 3, 4, 5, 6, 7].forEach((d) => out.add(d));
    else if (k === 'weekdays') [1, 2, 3, 4, 5].forEach((d) => out.add(d));
    else if (k === 'weekends') [6, 7].forEach((d) => out.add(d));
    else {
      const i = DAY_NAMES.indexOf(k.slice(0, 3));
      if (i < 0) throw new ToolError(`Unknown day "${raw}"`);
      out.add(i + 1);
    }
  }
  return [...out].sort();
}

function hhmm(s: string): string {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim());
  if (!m || +m[1] > 23 || +m[2] > 59) throw new ToolError(`Bad time "${s}" (use HH:mm, 24 h)`);
  return `${m[1].padStart(2, '0')}:${m[2]}`;
}

// ---------------------------------------------------------------- tools

type Args = Record<string, any>;

async function timedOverride(s: Session, now: Date, a: Args, action: 'block' | 'unblock'): Promise<string> {
  const groups = await s.resolveGroups(a.groups ?? []);
  const tz = await s.tz();
  const start = a.start ? parseTime(a.start, tz, now) : now;
  let endsAt: Date | null = null;
  if (a.minutes !== undefined && a.until) throw new ToolError('Give minutes or until, not both');
  if (a.minutes !== undefined) endsAt = new Date(start.getTime() + Number(a.minutes) * 60_000);
  else if (a.until) endsAt = parseTime(a.until, tz, start);
  else if (!(action === 'block' && a.indefinite)) throw new ToolError('Give minutes or until (or indefinite: true for an open-ended block)');
  const o: Override = await s.api('POST', '/overrides', {
    groupIds: groups.map((g) => g.id), action, startsAt: start.toISOString(), endsAt: endsAt?.toISOString() ?? null,
    reason: a.reason ?? (action === 'block' ? 'Focus session' : 'Allowed by admin'),
    deviceIds: (await s.resolveDevices(a.devices)) ?? null,
  });
  const names = groups.map((g) => g.name).join(', ');
  const when = start.getTime() > now.getTime() + 30_000 ? `from ${fmtTime(start, tz, now)} ` : '';
  const until = endsAt ? `until ${fmtTime(endsAt, tz, now)}` : 'until ended';
  return `${action === 'block' ? 'Blocked' : 'Allowed'} ${names} ${when}${until} (${tz}). id=${o.id}`;
}

function unlockWhat(r: Unlock, gname: (id: string) => string, minutes = r.minutes): string {
  return r.kind === 'disableProtection' ? 'turn off protection'
    : `unlock ${r.groupIds.map(gname).join(', ') || '(deleted groups)'}${minutes ? ` for ${minutes} min` : ''}`;
}

async function unlockRequests(s: Session, now: Date, all: boolean): Promise<string> {
  const [list, groups, tz] = await Promise.all([
    s.api('GET', all ? '/unlock-requests' : '/unlock-requests?status=pending'), s.groups(), s.tz()]);
  const reqs = list.requests as Unlock[];
  if (!reqs.length) return all ? 'No unlock requests.' : 'No pending unlock requests.';
  const gname = (id: string) => groups.find((g) => g.id === id)?.name ?? id;
  return reqs.map((r) => `${all ? `[${r.status}] ` : ''}${unlockWhat(r, gname)}${r.reason ? ` "${r.reason}"` : ''}`
    + ` from ${r.deviceName ?? 'unknown device'}, ${fmtTime(r.createdAt, tz, now)}${r.note ? ` (note: ${r.note})` : ''} id=${r.id}`).join('\n');
}

async function status(s: Session, now: Date): Promise<string> {
  const [settings, groups, rules, overrides, devices, unlocks] = await Promise.all([
    s.api('GET', '/settings'), s.groups(), s.rules(), s.api('GET', '/overrides?active=true'), s.api('GET', '/devices'),
    s.api('GET', '/unlock-requests?status=pending'),
  ]);
  const tz = s.timeZone(settings.timeZone ?? null);
  const gname = (id: string) => groups.find((g) => g.id === id)?.name ?? id;
  const L: string[] = [];
  L.push(`Now: ${new Intl.DateTimeFormat('en-US', { timeZone: tz, dateStyle: 'full', timeStyle: 'short' }).format(now)} (${tz})`);
  L.push('', 'Devices:');
  if (!devices.devices.length) L.push('  none paired (use pairing_code)');
  for (const d of devices.devices) {
    // Server view: what the policy says should be blocked now. Phone view: what the device last acked.
    const blocked = (d.currentState as { groupId: string; blocked: boolean }[]).filter((x) => x.blocked).map((x) => gname(x.groupId));
    L.push(`  ${d.name} [${d.status}]${d.hasPushToken ? '' : ' (no push token: updates on app open)'}: server expects: ${blocked.length ? 'blocked ' + blocked.join(', ') : 'nothing blocked'}`);
    const rep = (d.reportedBlockedGroupIds ?? []) as string[];
    const local = rep.filter((id) => id.startsWith('lgrp_')).length;
    const named = rep.filter((id) => !id.startsWith('lgrp_')).map(gname);
    const what = named.length || local
      ? `blocked ${[named.join(', '), local ? `${local} phone-made group${local > 1 ? 's' : ''}` : ''].filter(Boolean).join(' + ')}`
      : 'nothing blocked';
    const ver = d.appliedVersion == null ? 'no policy applied yet'
      : d.appliedVersion < d.latestVersion ? `policy v${d.appliedVersion}, latest v${d.latestVersion} - not applied yet` : `policy v${d.appliedVersion}`;
    const extra = [d.protectionEnabled === false ? 'protection OFF' : '', d.authorizationStatus && d.authorizationStatus !== 'approved' ? `Screen Time access ${d.authorizationStatus}` : '']
      .filter(Boolean).join(', ');
    L.push(`    phone reports (${ver}): ${what}${extra ? ` | ${extra}` : ''}`);
  }
  const list = overrides.overrides as Override[];
  const active = list.filter((o) => Date.parse(o.startsAt) <= now.getTime());
  const upcoming = list.filter((o) => Date.parse(o.startsAt) > now.getTime());
  const line = (o: Override) => `  ${o.action === 'block' ? 'BLOCK' : 'ALLOW'} ${o.groupIds.map(gname).join(', ')}`
    + `${Date.parse(o.startsAt) > now.getTime() ? ' from ' + fmtTime(o.startsAt, tz, now) : ''}`
    + ` until ${o.endsAt ? fmtTime(o.endsAt, tz, now) : 'ended'}${o.reason ? ` "${o.reason}"` : ''} id=${o.id}`;
  L.push('', 'Active blocks/allows:', ...(active.length ? active.map(line) : ['  none']));
  if (upcoming.length) L.push('', 'Upcoming:', ...upcoming.map(line));
  L.push('', 'Groups:', ...(groups.length ? groups.map((g) => `  ${g.name}${g.webDomains.length ? ' (sites: ' + g.webDomains.join(', ') + ')' : ''} id=${g.id}`) : ['  none']));
  L.push('', 'Schedules & modes:');
  if (!rules.length) L.push('  none');
  for (const r of rules) {
    const t = r.trigger;
    const what = t.type === 'schedule' ? t.windows!.map((w) => `${w.days.map((d) => DAY_NAMES[d - 1]).join(',')} ${w.start}-${w.end}`).join('; ')
      : t.type === 'manual' ? `mode, ${t.active ? 'ON' : 'off'}` : `${t.dailyMinutes} min/day limit`;
    L.push(`  ${r.name}: ${r.action} ${r.groupIds.map(gname).join(', ')} | ${what}${r.strictness !== 'flexible' ? ` | ${r.strictness}` : ''}${r.enabled ? '' : ' | disabled'} id=${r.id}`);
  }
  if (unlocks.requests.length) L.push('', `Pending unlock requests: ${unlocks.requests.length} (see unlock_requests)`);
  L.push('', `Settings: protectionLock=${settings.protectionLock}, allowLocalRules=${settings.allowLocalRules}, denyAppRemoval=${settings.denyAppRemoval}, timeZone=${settings.timeZone ?? 'phone local'}`);
  return L.join('\n');
}

async function callTool(s: Session, now: Date, name: string, a: Args): Promise<string> {
  switch (name) {
    case 'status': return status(s, now);
    case 'block': return timedOverride(s, now, a, 'block');
    case 'allow': return timedOverride(s, now, a, 'unblock');
    case 'end': {
      const list = (await s.api('GET', '/overrides?active=true')).overrides as Override[];
      let targets: Override[];
      if (a.id) targets = list.filter((o) => o.id === a.id);
      else if (a.all) targets = list;
      else if (a.groups?.length) {
        const ids = new Set((await s.resolveGroups(a.groups)).map((g) => g.id));
        targets = list.filter((o) => o.groupIds.some((g) => ids.has(g)));
      } else throw new ToolError('Give id, groups, or all: true');
      if (!targets.length) return 'Nothing active or upcoming matched; nothing ended.';
      for (const o of targets) await s.api('DELETE', `/overrides/${o.id}`);
      const groups = await s.groups();
      return `Ended ${targets.length}: ` + targets.map((o) => `${o.action} ${o.groupIds.map((g) => groups.find((x) => x.id === g)?.name ?? g).join(', ')} (${o.id})`).join('; ');
    }
    case 'create_group': {
      const g: Group = await s.api('POST', '/groups', { name: a.name, webDomains: a.websites ?? [], ...(a.color ? { colorHex: a.color } : {}) });
      return `Created group ${g.name} id=${g.id}. On the phone, open Tether and tap "Choose apps for ${g.name}" to pick its apps.`;
    }
    case 'update_group': {
      const [g] = await s.resolveGroups([a.group]);
      const patch: Args = {};
      if (a.name) patch.name = a.name;
      if (a.websites) patch.webDomains = a.websites;
      if (a.color) patch.colorHex = a.color;
      if (!Object.keys(patch).length) throw new ToolError('Nothing to change');
      const u: Group = await s.api('PATCH', `/groups/${g.id}`, patch);
      return `Updated ${u.name}: sites ${u.webDomains.join(', ') || 'none'}`;
    }
    case 'delete_group': {
      const [g] = await s.resolveGroups([a.group]);
      await s.api('DELETE', `/groups/${g.id}`);
      return `Deleted group ${g.name}.`;
    }
    case 'add_schedule': {
      const groups = await s.resolveGroups(a.groups ?? []);
      const r: Rule = await s.api('POST', '/rules', {
        name: a.name, groupIds: groups.map((g) => g.id), enabled: true, action: 'block', priority: 0,
        strictness: a.strictness ?? (a.strict ? 'strict' : 'flexible'),
        trigger: { type: 'schedule', windows: [{ days: parseDays(a.days ?? []), start: hhmm(a.start), end: hhmm(a.end) }] },
      });
      return `Added schedule ${r.name} id=${r.id}`;
    }
    case 'remove_schedule': {
      const r = findByNameOrId(await s.rules(), a.schedule, 'schedule');
      await s.api('DELETE', `/rules/${r.id}`);
      return `Removed ${r.name}.`;
    }
    case 'set_mode': {
      const r = findByNameOrId(await s.rules(), a.mode, 'mode');
      await s.api('POST', `/rules/${r.id}/toggle`, { active: !!a.active });
      return `${r.name} is now ${a.active ? 'ON' : 'off'}.`;
    }
    case 'update_settings': {
      const patch: Args = {};
      for (const k of ['protectionLock', 'allowLocalRules', 'denyAppRemoval', 'timeZone']) if (a[k] !== undefined) patch[k] = a[k];
      if (!Object.keys(patch).length) throw new ToolError('Nothing to change');
      const st = await s.api('PATCH', '/settings', patch);
      return `Settings: ${JSON.stringify(st)}`;
    }
    case 'pairing_code': {
      const c = await s.api('POST', '/pairing-codes', a.deviceName ? { deviceName: a.deviceName } : {});
      return `Pairing code ${c.code} (expires ${c.expiresAt}). In Tether: Settings → Server, enter the code. Link: ${c.qrPayload}`;
    }
    case 'unlock_requests': return unlockRequests(s, now, !!a.all);
    case 'approve_unlock': {
      const r: Unlock = await s.api('POST', `/unlock-requests/${encodeURIComponent(a.id)}/approve`, a.minutes !== undefined ? { minutes: a.minutes } : {});
      if (r.kind === 'disableProtection') return 'Approved: the phone may now turn off protection.';
      const groups = await s.groups();
      const gname = (id: string) => groups.find((g) => g.id === id)?.name ?? id;
      return `Approved: ${r.groupIds.map(gname).join(', ')} unlocked for ${r.minutes} min. id=${r.id}`;
    }
    case 'deny_unlock': {
      const r: Unlock = await s.api('POST', `/unlock-requests/${encodeURIComponent(a.id)}/deny`, a.note ? { note: a.note } : {});
      const groups = await s.groups();
      return `Denied: ${unlockWhat(r, (id) => groups.find((g) => g.id === id)?.name ?? id)}.`;
    }
    default: throw new ToolError(`Unknown tool ${name}`);
  }
}

// ---------------------------------------------------------------- JSON-RPC

interface RpcMsg { jsonrpc?: string; id?: string | number | null; method?: string; params?: any }
const rpcError = (id: RpcMsg['id'], code: number, message: string) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });

export function mcpRoutes(ctx: Ctx) {
  return async (app: FastifyInstance): Promise<void> => {
    const auth = adminAuth(ctx);

    app.post('/mcp', async (req: FastifyRequest, reply: FastifyReply) => {
      // DNS-rebinding guard (MCP spec): browsers send Origin; agents don't.
      const origin = req.headers.origin;
      if (origin && new URL(origin).host !== req.headers.host) throw forbidden('Origin not allowed');
      await auth(req);
      const session = new Session(app, ctx, req.headers.authorization!, req.admin!.id);
      const body = req.body as RpcMsg | RpcMsg[] | undefined;
      const msgs = Array.isArray(body) ? body : body ? [body] : [];
      const out: unknown[] = [];
      for (const m of msgs) {
        if (m.id === undefined || !m.method) continue; // notifications / responses: nothing to answer
        out.push(await handle(session, ctx.now(), m, req.headers['mcp-protocol-version'] as string | undefined));
      }
      if (!out.length) return reply.code(202).send();
      return reply.send(Array.isArray(body) ? out : out[0]);
    });

    // No server-initiated stream; sessions are stateless.
    for (const m of ['GET', 'DELETE'] as const)
      app.route({ method: m, url: '/mcp', handler: async (_req, reply) => reply.code(405).header('allow', 'POST').send() });
  };
}

async function handle(s: Session, now: Date, m: RpcMsg, _hdrVersion?: string): Promise<unknown> {
  const ok = (result: unknown) => ({ jsonrpc: '2.0', id: m.id, result });
  switch (m.method) {
    case 'initialize': {
      const asked = m.params?.protocolVersion;
      return ok({
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'tether', version: VERSION },
        instructions: INSTRUCTIONS,
      });
    }
    case 'ping': return ok({});
    case 'tools/list': return ok({ tools: TOOLS });
    case 'tools/call': {
      const name = m.params?.name;
      if (!TOOLS.some((t) => t.name === name)) return rpcError(m.id, -32602, `Unknown tool: ${name}`);
      try {
        return ok({ content: [{ type: 'text', text: await callTool(s, now, name, m.params?.arguments ?? {}) }] });
      } catch (e) {
        if (e instanceof ToolError) return ok({ content: [{ type: 'text', text: e.message }], isError: true });
        throw e;
      }
    }
    default: return rpcError(m.id, -32601, `Method not found: ${m.method}`);
  }
}
