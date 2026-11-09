// TypeScript port of ARCHITECTURE.md §3 (resolution semantics). Verified by contracts/engine-vectors.json.
// Wall-clock math uses Intl.DateTimeFormat with an explicit IANA time zone; no Temporal needed.

export interface BlockGroup { id: string; name: string; colorHex?: string | null; webDomains: string[]; source?: 'server' | 'local'; copiedFrom?: string }
export interface Window { days: number[]; start: string; end: string }
export type Trigger =
  | { type: 'schedule'; windows: Window[] }
  | { type: 'usageLimit'; dailyMinutes: number; days: number[] }
  | { type: 'manual'; active: boolean };
export interface Rule {
  id: string; name: string; groupIds: string[]; enabled: boolean; action: 'block' | 'allow';
  trigger: Trigger; strictness: 'flexible' | 'guarded' | 'strict'; priority?: number; maxPausesPerDay?: number | null;
  source?: 'server' | 'local';
}
export interface Override {
  id: string; groupIds: string[]; action: 'block' | 'unblock'; startsAt: string; endsAt?: string | null;
  issuedAt: string; reason?: string | null;
}
export interface Settings { protectionLock: 'partnerPIN' | 'remoteApproval' | 'osOnly'; allowLocalRules: boolean; denyAppRemoval: boolean }
export interface PolicyBundle {
  version: number; generatedAt: string; timeZone?: string | null;
  groups: BlockGroup[]; rules: Rule[]; overrides: Override[]; settings: Settings;
}
export interface FocusSession {
  id: string; name?: string | null; groupIds: string[]; startsAt: string; endsAt: string; strict: boolean; endedAt?: string | null;
}
export interface Pause { id: string; groupIds: string[]; startsAt: string; endsAt: string; ruleId?: string | null }
export interface UsageLimitHit { ruleId: string; day: string }
export interface EngineInput {
  bundle?: PolicyBundle | null;
  localGroups: BlockGroup[]; localRules: Rule[]; sessions: FocusSession[]; pauses: Pause[]; usageLimitHits: UsageLimitHit[];
}
export type ReasonKind = 'override' | 'session' | 'rule' | 'pause' | 'none';
export interface GroupState { blocked: boolean; strict: boolean; reason: { kind: ReasonKind; id: string | null } }

const WEEKDAYS: Record<string, number> = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
const fmtCache = new Map<string, Intl.DateTimeFormat>();

interface Local { isoWeekday: number; minutes: number; day: string }

function localParts(ms: number, tz: string): Local {
  let f = fmtCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short',
    });
    fmtCache.set(tz, f);
  }
  const p: Record<string, string> = {};
  for (const part of f.formatToParts(new Date(ms))) p[part.type] = part.value;
  const hour = Number(p.hour) % 24;
  return {
    isoWeekday: WEEKDAYS[p.weekday!]!,
    minutes: hour * 60 + Number(p.minute) + Number(p.second) / 60,
    day: `${p.year}-${p.month}-${p.day}`,
  };
}

const hm = (s: string): number => {
  const [h, m] = s.split(':').map(Number);
  return h! * 60 + m!;
};
const T = (s: string): number => Date.parse(s);
const lt = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0); // code-point comparison, like Python

function windowActive(w: Window, l: Local): boolean {
  const s = hm(w.start), e = hm(w.end);
  if (s === e) return false;
  const prev = l.isoWeekday === 1 ? 7 : l.isoWeekday - 1;
  if (e > s) return w.days.includes(l.isoWeekday) && s <= l.minutes && l.minutes < e;
  return (w.days.includes(l.isoWeekday) && l.minutes >= s) || (w.days.includes(prev) && l.minutes < e);
}

export function evaluate(input: EngineInput, now: Date, deviceTimeZone: string): Record<string, GroupState> {
  const b = input.bundle ?? null;
  const nowMs = now.getTime();
  const local = localParts(nowMs, b?.timeZone || deviceTimeZone);
  const groups = [...(b?.groups ?? []).map((g) => g.id), ...input.localGroups.map((g) => g.id)];
  const allowLocal = b ? b.settings.allowLocalRules : true;
  const rules = [...(b?.rules ?? []), ...(allowLocal ? input.localRules : [])];

  const ruleActive = (r: Rule): boolean => {
    if (!r.enabled) return false;
    const tr = r.trigger;
    if (tr.type === 'schedule') return tr.windows.some((w) => windowActive(w, local));
    if (tr.type === 'manual') return tr.active;
    return tr.days.includes(local.isoWeekday) && input.usageLimitHits.some((h) => h.ruleId === r.id && h.day === local.day);
  };

  const out: Record<string, GroupState> = {};
  for (const g of groups) {
    const ovs = (b?.overrides ?? []).filter(
      (o) => o.groupIds.includes(g) && T(o.startsAt) <= nowMs && (o.endsAt == null || nowMs < T(o.endsAt)),
    );
    if (ovs.length) {
      const o = ovs.reduce((best, c) => {
        const d = T(c.issuedAt) - T(best.issuedAt);
        return d > 0 || (d === 0 && lt(c.id, best.id) > 0) ? c : best;
      });
      out[g] = { blocked: o.action === 'block', strict: o.action === 'block', reason: { kind: 'override', id: o.id } };
      continue;
    }
    const sessions = input.sessions.filter(
      (s) => s.groupIds.includes(g) && T(s.startsAt) <= nowMs && nowMs < T(s.endsAt) && (s.endedAt == null || nowMs < T(s.endedAt)),
    );
    const active = rules.filter((r) => r.groupIds.includes(g) && ruleActive(r));
    let winner: Rule | undefined;
    if (active.length) {
      const mp = Math.max(...active.map((r) => r.priority ?? 0));
      const top = active.filter((r) => (r.priority ?? 0) === mp);
      const blocks = top.filter((r) => r.action === 'block');
      winner = blocks.length
        ? [...blocks].sort((a, c) => Number(a.strictness !== 'strict') - Number(c.strictness !== 'strict') || lt(a.id, c.id))[0]
        : [...top].sort((a, c) => lt(a.id, c.id))[0];
    }
    let cand: GroupState | null = null;
    if (sessions.length) {
      const strictOnes = sessions.filter((s) => s.strict);
      const pick = strictOnes.length
        ? [...strictOnes].sort((a, c) => lt(a.id, c.id))[0]!
        : [...sessions].sort((a, c) => T(a.endsAt) - T(c.endsAt) || lt(a.id, c.id))[0]!;
      const strict = strictOnes.length > 0 || (winner !== undefined && winner.action === 'block' && winner.strictness === 'strict');
      cand = { blocked: true, strict, reason: { kind: 'session', id: pick.id } };
    } else if (winner) {
      if (winner.action === 'allow') {
        out[g] = { blocked: false, strict: false, reason: { kind: 'rule', id: winner.id } };
        continue;
      }
      cand = { blocked: true, strict: winner.strictness === 'strict', reason: { kind: 'rule', id: winner.id } };
    }
    if (cand) {
      if (!cand.strict) {
        const ps = input.pauses.filter((p) => p.groupIds.includes(g) && T(p.startsAt) <= nowMs && nowMs < T(p.endsAt));
        if (ps.length) {
          const pb = [...ps].sort((a, c) => T(c.endsAt) - T(a.endsAt) || lt(a.id, c.id))[0]!;
          out[g] = { blocked: false, strict: false, reason: { kind: 'pause', id: pb.id } };
          continue;
        }
      }
      out[g] = cand;
      continue;
    }
    out[g] = { blocked: false, strict: false, reason: { kind: 'none', id: null } };
  }
  return out;
}
