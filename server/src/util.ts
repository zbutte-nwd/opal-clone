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

export function isValidTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}
