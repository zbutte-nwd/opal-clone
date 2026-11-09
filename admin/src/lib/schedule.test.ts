import { describe, expect, it } from 'vitest';
import { formatDays, formatTime, formatWindow, isOvernight, summarizeRule, validateTrigger, validateWindow } from './schedule';
import type { Rule } from '../api/types';
import { formatCountdown, relativeTime } from './time';
import { normalizeDomain, validateDomain } from './domains';

const names = { a: 'Social', b: 'Games' };

describe('schedule formatting', () => {
  it('formats times', () => {
    expect(formatTime('08:00')).toBe('8:00 AM');
    expect(formatTime('00:30')).toBe('12:30 AM');
    expect(formatTime('12:00')).toBe('12:00 PM');
    expect(formatTime('15:05')).toBe('3:05 PM');
    expect(formatTime('24:00')).toBe('midnight');
  });
  it('formats day sets', () => {
    expect(formatDays([1, 2, 3, 4, 5])).toBe('Mon–Fri');
    expect(formatDays([1, 2, 3, 4, 5, 6, 7])).toBe('Every day');
    expect(formatDays([6, 7])).toBe('Sat–Sun');
    expect(formatDays([1, 3, 6])).toBe('Mon, Wed, Sat');
    expect(formatDays([5, 3, 4])).toBe('Wed–Fri');
  });
  it('formats overnight and 24:00 windows', () => {
    expect(formatWindow({ days: [1, 2, 3, 4, 5], start: '22:00', end: '06:00' })).toBe('Mon–Fri 10:00 PM–6:00 AM (→ next day)');
    expect(formatWindow({ days: [6], start: '09:00', end: '24:00' })).toBe('Sat 9:00 AM–midnight');
    expect(isOvernight({ start: '09:00', end: '24:00' })).toBe(false);
  });
  it('summarizes rules', () => {
    const rule: Pick<Rule, 'groupIds' | 'action' | 'trigger' | 'strictness'> = {
      groupIds: ['a', 'b'], action: 'block', strictness: 'strict',
      trigger: { type: 'schedule', windows: [{ days: [1, 2, 3, 4, 5], start: '08:00', end: '15:00' }] },
    };
    expect(summarizeRule(rule, names)).toBe('Blocks Social, Games · Mon–Fri 8:00 AM–3:00 PM · strict');
    expect(summarizeRule({ ...rule, action: 'allow', strictness: 'flexible', trigger: { type: 'usageLimit', dailyMinutes: 90, days: [1, 2, 3, 4, 5, 6, 7] } }, names))
      .toBe('Allows Social, Games · after 1h 30m/day · Every day · flexible');
    expect(summarizeRule({ ...rule, trigger: { type: 'manual', active: true } }, names)).toContain('manual · ON');
  });
});

describe('validation', () => {
  it('accepts valid windows incl. overnight and 24:00', () => {
    expect(validateWindow({ days: [1], start: '22:00', end: '06:00' })).toBeNull();
    expect(validateWindow({ days: [1], start: '09:00', end: '24:00' })).toBeNull();
  });
  it('rejects start == end, bad times, empty days', () => {
    expect(validateWindow({ days: [1], start: '09:00', end: '09:00' })).toMatch(/different/);
    expect(validateWindow({ days: [], start: '09:00', end: '10:00' })).toMatch(/day/);
    expect(validateWindow({ days: [1], start: '9:00', end: '10:00' })).toMatch(/start/i);
    expect(validateWindow({ days: [1], start: '24:00', end: '10:00' })).toMatch(/24:00/);
    expect(validateWindow({ days: [1, 1], start: '09:00', end: '10:00' })).toMatch(/unique/);
  });
  it('validates triggers', () => {
    expect(validateTrigger({ type: 'schedule', windows: [] })).toMatch(/at least one/);
    expect(validateTrigger({ type: 'usageLimit', dailyMinutes: 0, days: [1] })).toMatch(/1–1440/);
    expect(validateTrigger({ type: 'usageLimit', dailyMinutes: 30, days: [1] })).toBeNull();
    expect(validateTrigger({ type: 'manual', active: false })).toBeNull();
  });
  it('validates domains', () => {
    expect(normalizeDomain(' HTTPS://Reddit.com/r/x ')).toBe('reddit.com');
    expect(validateDomain('reddit.com')).toBeNull();
    expect(validateDomain('Reddit.com')).not.toBeNull();
    expect(validateDomain('localhost')).not.toBeNull();
    expect(validateDomain('a.com', ['a.com'])).toMatch(/Already/);
    expect(validateDomain('b.com', Array.from({ length: 50 }, (_, i) => `d${i}.com`))).toMatch(/50/);
  });
});

describe('time helpers', () => {
  const now = Date.parse('2026-11-09T12:00:00Z');
  it('relative', () => {
    expect(relativeTime(null, now)).toBe('never');
    expect(relativeTime('2026-11-09T11:55:00Z', now)).toBe('5 minutes ago');
    expect(relativeTime('2026-11-09T12:30:00Z', now)).toBe('in 30 minutes');
  });
  it('countdown', () => {
    expect(formatCountdown('2026-11-09T13:05:00Z', now)).toBe('1h 05m');
    expect(formatCountdown('2026-11-09T12:00:45Z', now)).toBe('45s');
    expect(formatCountdown('2026-11-09T11:00:00Z', now)).toBe('0s');
    expect(formatCountdown(null, now)).toBe('until you undo');
  });
});
