import { createHash, randomBytes, randomInt } from 'node:crypto';

const ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';
export function newId(prefix: string): string {
  let s = '';
  for (let i = 0; i < 12; i++) s += ALPHABET[randomInt(ALPHABET.length)];
  return `${prefix}_${s}`;
}
export const sha256Hex = (s: string): string => createHash('sha256').update(s).digest('hex');
export const randomToken = (bytes = 32): string => randomBytes(bytes).toString('base64url');

/** RFC 3339 UTC without fractional seconds (Swift's default ISO8601DateFormatter requires this). */
export function iso(d: Date | number): string {
  const ms = typeof d === 'number' ? d : d.getTime();
  return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');
}
export const addMinutes = (d: Date, m: number): Date => new Date(d.getTime() + m * 60_000);

export function parseJson<T>(s: string | null | undefined, fallback: T): T {
  if (s == null) return fallback;
  try {
    return JSON.parse(s) as T;
  } catch {
    return fallback;
  }
}

/** Apps below this version fail to decode `strictness: "guarded"` (closed Swift enum); they get "flexible". */
export const GUARDED_MIN_APP_VERSION = '0.2.0';

/** Numeric dotted-version compare ("0.10.0" >= "0.2.0"); missing parts count as 0; null/garbage is "older". */
export function appVersionAtLeast(v: string | null | undefined, min: string): boolean {
  const parts = (s: string | null | undefined) => (s && /^\d+(\.\d+)*$/.test(s.trim()) ? s.trim().split('.').map(Number) : null);
  const a = parts(v);
  const b = parts(min);
  if (!a || !b) return false;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return true;
}

export function isValidTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
