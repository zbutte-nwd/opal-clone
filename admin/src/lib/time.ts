/** Relative-time helpers. All take an explicit `now` for testability. */

export function relativeTime(iso: string | null | undefined, now: number = Date.now()): string {
  if (!iso) return 'never';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return 'unknown';
  const diff = Math.round((now - t) / 1000);
  const abs = Math.abs(diff);
  const fut = diff < 0;
  let s: string;
  if (abs < 45) return fut ? 'in a few seconds' : 'just now';
  if (abs < 90) s = '1 minute';
  else if (abs < 45 * 60) s = `${Math.round(abs / 60)} minutes`;
  else if (abs < 90 * 60) s = '1 hour';
  else if (abs < 22 * 3600) s = `${Math.round(abs / 3600)} hours`;
  else if (abs < 36 * 3600) s = '1 day';
  else s = `${Math.round(abs / 86400)} days`;
  return fut ? `in ${s}` : `${s} ago`;
}

/** "1h 05m", "12m 30s", "45s"; "0s" when already past. */
export function formatCountdown(iso: string | null | undefined, now: number = Date.now()): string {
  if (!iso) return 'until you undo';
  const ms = Date.parse(iso) - now;
  if (Number.isNaN(ms)) return '';
  if (ms <= 0) return '0s';
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m`;
  if (m > 0) return `${m}m ${String(s).padStart(2, '0')}s`;
  return `${s}s`;
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

/** Convert an ISO string to the value format of <input type="datetime-local"> (local time). */
export function toLocalInput(iso: string | Date): string {
  const d = typeof iso === 'string' ? new Date(iso) : iso;
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
export function fromLocalInput(v: string): string {
  return new Date(v).toISOString();
}

export function formatDuration(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m ? `${h}h ${m}m` : `${h}h`;
}
