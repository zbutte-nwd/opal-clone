export const MAX_DOMAINS = 50;
const DOMAIN_RE = /^[a-z0-9.-]+\.[a-z]{2,}$/;

/** Normalizes user input: trims, lowercases, strips scheme/path/leading "www."-less. */
export function normalizeDomain(raw: string): string {
  let s = raw.trim().toLowerCase();
  s = s.replace(/^[a-z]+:\/\//, '').replace(/[/?#].*$/, '');
  return s;
}
/** Returns an error message or null. Expects an already-normalized domain. */
export function validateDomain(d: string, existing: string[] = []): string | null {
  if (!d) return 'Enter a domain like example.com.';
  if (!DOMAIN_RE.test(d)) return 'Use a lowercase domain like example.com.';
  if (d.startsWith('.') || d.endsWith('.') || d.includes('..')) return 'Use a lowercase domain like example.com.';
  if (existing.includes(d)) return 'Already added.';
  if (existing.length >= MAX_DOMAINS) return `At most ${MAX_DOMAINS} domains per group.`;
  return null;
}
