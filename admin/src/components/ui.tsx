import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import type { BlockGroup, DeviceStatus, IsoWeekday } from '../api/types';
import { ALL_DAYS, WEEKDAY_SHORT } from '../lib/schedule';

export function Switch({ checked, onChange, label, disabled }: { checked: boolean; onChange: (v: boolean) => void; label: string; disabled?: boolean }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      className={`switch ${checked ? 'on' : ''}`}
      onClick={() => onChange(!checked)}
    >
      <span className="knob" />
    </button>
  );
}

export const STATUS_INFO: Record<DeviceStatus, { label: string; help: string }> = {
  online: { label: 'Online', help: 'Seen in the last 15 minutes.' },
  idle: { label: 'Idle', help: 'Last seen under 24 hours ago.' },
  stale: { label: 'Stale', help: 'Not seen for over 24 hours. The phone may be off, offline, or the app was removed.' },
  revoked: { label: 'Revoked', help: 'Screen Time authorization was turned off on the phone, so blocking is not enforced.' },
  pending: { label: 'Pending', help: 'The phone has not applied the latest policy for over 5 minutes.' },
};
export function StatusBadge({ status }: { status: DeviceStatus }) {
  const info = STATUS_INFO[status] ?? { label: status, help: '' };
  return <span className={`badge badge-${status}`} title={info.help}>{info.label}</span>;
}

export function Spinner({ label = 'Loading…' }: { label?: string }) {
  return <p className="muted" role="status">{label}</p>;
}
export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return <div className="empty"><h3>{title}</h3>{children && <div className="muted">{children}</div>}</div>;
}

export function PageHeader({ title, children }: { title: string; children?: ReactNode }) {
  return <header className="page-header"><h1>{title}</h1><div className="actions">{children}</div></header>;
}

export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const id = useId();
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    ref.current?.focus();
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('keydown', onKey); prev?.focus?.(); };
  }, [onClose]);
  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby={id} tabIndex={-1} ref={ref}>
        <h2 id={id}>{title}</h2>
        {children}
      </div>
    </div>
  );
}

export function Confirm({ title, children, confirmLabel = 'Confirm', danger, onConfirm, onCancel }: {
  title: string; children: ReactNode; confirmLabel?: string; danger?: boolean; onConfirm: () => void; onCancel: () => void;
}) {
  return (
    <Modal title={title} onClose={onCancel}>
      <div>{children}</div>
      <div className="row end">
        <button className="btn" onClick={onCancel}>Cancel</button>
        <button className={`btn ${danger ? 'btn-danger' : 'btn-primary'}`} onClick={onConfirm}>{confirmLabel}</button>
      </div>
    </Modal>
  );
}

export function GroupChip({ group }: { group: Pick<BlockGroup, 'name' | 'colorHex'> }) {
  return (
    <span className="chip">
      <span className="dot" style={{ background: group.colorHex ?? 'var(--muted)' }} aria-hidden />
      {group.name}
    </span>
  );
}

/** Multi-select of groups as toggleable chips. */
export function GroupPicker({ groups, value, onChange, label = 'Groups' }: { groups: BlockGroup[]; value: string[]; onChange: (ids: string[]) => void; label?: string }) {
  if (groups.length === 0) return <p className="muted">No groups yet — create one on the Groups page first.</p>;
  return (
    <fieldset className="fieldset">
      <legend>{label}</legend>
      <div className="chips">
        {groups.map((g) => {
          const on = value.includes(g.id);
          return (
            <button
              key={g.id} type="button" aria-pressed={on}
              className={`chip chip-toggle ${on ? 'selected' : ''}`}
              onClick={() => onChange(on ? value.filter((x) => x !== g.id) : [...value, g.id])}
            >
              <span className="dot" style={{ background: g.colorHex ?? 'var(--muted)' }} aria-hidden />
              {g.name}
            </button>
          );
        })}
      </div>
    </fieldset>
  );
}

export function DayPicker({ value, onChange, label = 'Days' }: { value: number[]; onChange: (d: IsoWeekday[]) => void; label?: string }) {
  return (
    <fieldset className="fieldset">
      <legend className="sr-only">{label}</legend>
      <div className="chips" role="group" aria-label={label}>
        {ALL_DAYS.map((d) => {
          const on = value.includes(d);
          return (
            <button
              key={d} type="button" aria-pressed={on}
              className={`chip chip-toggle day ${on ? 'selected' : ''}`}
              onClick={() => onChange((on ? value.filter((x) => x !== d) : [...value, d]).sort((a, b) => a - b) as IsoWeekday[])}
            >{WEEKDAY_SHORT[d - 1]}</button>
          );
        })}
      </div>
    </fieldset>
  );
}

/** Re-renders every `ms` so countdowns tick. */
export function useNow(ms = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

export function groupNameMap(groups: BlockGroup[] | undefined): Record<string, string> {
  return Object.fromEntries((groups ?? []).map((g) => [g.id, g.name]));
}
