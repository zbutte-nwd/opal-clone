import type { IsoWeekday, Rule, Trigger, Window } from '../api/types';

export const WEEKDAY_SHORT = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const;
export const ALL_DAYS: IsoWeekday[] = [1, 2, 3, 4, 5, 6, 7];
export const WEEKDAYS: IsoWeekday[] = [1, 2, 3, 4, 5];
export const WEEKEND: IsoWeekday[] = [6, 7];

export const HHMM = /^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$/;

export function weekdayName(d: IsoWeekday | number): string {
  return WEEKDAY_SHORT[d - 1] ?? '?';
}

/** Sort + dedupe. */
export function normalizeDays(days: number[]): IsoWeekday[] {
  return [...new Set(days)].filter((d) => d >= 1 && d <= 7).sort((a, b) => a - b) as IsoWeekday[];
}

/** "Every day", "Weekdays", "Weekends", "Mon–Fri", "Mon, Wed, Sat". */
export function formatDays(input: number[]): string {
  const days = normalizeDays(input);
  if (days.length === 0) return 'No days';
  if (days.length === 7) return 'Every day';
  const key = days.join('');
  if (key === '12345') return 'Mon–Fri';
  if (key === '67') return 'Sat–Sun';
  // contiguous run of >= 3
  const contiguous = days.every((d, i) => i === 0 || d === days[i - 1]! + 1);
  if (contiguous && days.length >= 3) return `${weekdayName(days[0]!)}–${weekdayName(days[days.length - 1]!)}`;
  return days.map(weekdayName).join(', ');
}

/** "HH:mm" → minutes since midnight (24:00 → 1440), or null if invalid. */
export function parseHHmm(s: string): number | null {
  if (!HHMM.test(s)) return null;
  const [h, m] = s.split(':').map(Number) as [number, number];
  return h * 60 + m;
}

/** "08:00" → "8:00 AM"; "24:00" → "midnight". */
export function formatTime(s: string): string {
  if (s === '24:00') return 'midnight';
  const mins = parseHHmm(s);
  if (mins === null) return s;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  const suffix = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${String(m).padStart(2, '0')} ${suffix}`;
}

export function isOvernight(w: Pick<Window, 'start' | 'end'>): boolean {
  const s = parseHHmm(w.start);
  const e = parseHHmm(w.end);
  return s !== null && e !== null && e < s;
}

/** "8:00 AM–3:00 PM", "10:00 PM–6:00 AM (→ next day)", "9:00 AM–midnight". */
export function formatWindowTimes(w: Pick<Window, 'start' | 'end'>): string {
  return `${formatTime(w.start)}–${formatTime(w.end)}${isOvernight(w) ? ' (→ next day)' : ''}`;
}

/** "Mon–Fri 8:00 AM–3:00 PM". */
export function formatWindow(w: Window): string {
  return `${formatDays(w.days)} ${formatWindowTimes(w)}`;
}

/** Returns an error message, or null when valid. */
export function validateWindow(w: Window): string | null {
  if (!w.days || w.days.length === 0) return 'Pick at least one day.';
  if (new Set(w.days).size !== w.days.length) return 'Days must be unique.';
  if (w.days.some((d) => !Number.isInteger(d) || d < 1 || d > 7)) return 'Days must be Mon–Sun.';
  const s = parseHHmm(w.start);
  const e = parseHHmm(w.end);
  if (s === null) return 'Enter a valid start time.';
  if (e === null) return 'Enter a valid end time.';
  if (w.start === '24:00') return 'Start time cannot be 24:00.';
  if (s === e) return 'Start and end must be different.';
  return null;
}

export function validateTrigger(t: Trigger): string | null {
  switch (t.type) {
    case 'schedule': {
      if (t.windows.length === 0) return 'Add at least one time window.';
      for (const [i, w] of t.windows.entries()) {
        const err = validateWindow(w);
        if (err) return `Window ${i + 1}: ${err}`;
      }
      return null;
    }
    case 'usageLimit':
      if (!Number.isInteger(t.dailyMinutes) || t.dailyMinutes < 1 || t.dailyMinutes > 1440) return 'Daily limit must be 1–1440 minutes.';
      if (t.days.length === 0) return 'Pick at least one day.';
      return null;
    case 'manual':
      return null;
  }
}

function listNames(ids: string[], names: Record<string, string>): string {
  const n = ids.map((id) => names[id] ?? 'Unknown group');
  return n.length ? n.join(', ') : 'no groups';
}

export function formatDuration(mins: number): string {
  if (mins < 60) return `${mins} min`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m ? `${h}h ${m}m` : `${h}h`;
}

export function summarizeTrigger(t: Trigger): string {
  switch (t.type) {
    case 'schedule':
      return t.windows.map(formatWindow).join('; ');
    case 'usageLimit':
      return `after ${formatDuration(t.dailyMinutes)}/day · ${formatDays(t.days)}`;
    case 'manual':
      return t.active ? 'manual · ON' : 'manual · off';
  }
}

/** e.g. "Blocks Social, Games · Mon–Fri 8:00 AM–3:00 PM · strict" */
export function summarizeRule(rule: Pick<Rule, 'groupIds' | 'action' | 'trigger' | 'strictness'>, groupNames: Record<string, string>): string {
  const verb = rule.action === 'block' ? 'Blocks' : 'Allows';
  return [`${verb} ${listNames(rule.groupIds, groupNames)}`, summarizeTrigger(rule.trigger), rule.strictness].join(' · ');
}
