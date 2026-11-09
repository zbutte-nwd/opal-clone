import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import type { ProtectionLock, Settings } from '../api/types';
import { PageHeader, Spinner, Switch } from '../components/ui';
import { useToast } from '../components/Toasts';

const LOCKS: Array<[ProtectionLock, string, string]> = [
  ['partnerPIN', 'Partner PIN (default)', 'A 6–8 digit Tether PIN set by a partner on the phone. Needed to disable protection or loosen rules in the app. Tip: use the same number as the Screen Time passcode.'],
  ['remoteApproval', 'Remote approval', 'The phone sends a request to this dashboard, and you approve or deny it under Unlock requests. Good for parent or employer managed devices.'],
  ['osOnly', 'OS only', 'No in-app way to disable protection. The only way out is revoking access in iOS Settings, which needs the Screen Time passcode. Maximum strictness.'],
];

function timeZones(): string[] {
  try {
    const f = (Intl as unknown as { supportedValuesOf?: (k: string) => string[] }).supportedValuesOf;
    if (f) return f('timeZone');
  } catch { /* fallthrough */ }
  return ['UTC', 'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles', 'Europe/London', 'Europe/Berlin', 'Asia/Tokyo', 'Australia/Sydney'];
}

export function SettingsPage() {
  const qc = useQueryClient();
  const toast = useToast();
  const q = useQuery({ queryKey: ['settings'], queryFn: api.getSettings });
  const [form, setForm] = useState<Settings | null>(null);
  useEffect(() => { if (q.data) setForm(q.data); }, [q.data]);
  const save = useMutation({
    mutationFn: (s: Settings) => api.updateSettings({ ...s, timeZone: s.timeZone || null }),
    onSuccess: (s) => { toast.success('Settings saved'); qc.setQueryData(['settings'], s); },
    onError: toast.error,
  });
  if (!form) return <Spinner />;
  const set = (p: Partial<Settings>) => setForm({ ...form, ...p });
  return (
    <>
      <PageHeader title="Settings" />
      <form className="stack" onSubmit={(e) => { e.preventDefault(); save.mutate(form); }}>
        <fieldset className="card fieldset stack">
          <legend><h2>Protection lock</h2></legend>
          <p className="muted">iOS gives apps no way to check the Screen Time passcode, so Tether gates in-app disabling in one of these ways. No Face ID is ever used.</p>
          {LOCKS.map(([v, title, text]) => (
            <label key={v} className="inline" style={{ alignItems: 'flex-start' }}>
              <input type="radio" name="lock" checked={form.protectionLock === v} onChange={() => set({ protectionLock: v })} />
              <span><strong>{title}</strong><br /><span className="help">{text}</span></span>
            </label>
          ))}
        </fieldset>
        <div className="card stack">
          <div className="item"><div><strong>Allow rules created on the phone</strong><div className="help">If off, only rules from this dashboard apply.</div></div>
            <Switch label="Allow local rules" checked={form.allowLocalRules} onChange={(v) => set({ allowLocalRules: v })} /></div>
          <div className="item"><div><strong>Deny app removal</strong><div className="help">Stops the phone from deleting apps while protection is on, including Tether.</div></div>
            <Switch label="Deny app removal" checked={form.denyAppRemoval} onChange={(v) => set({ denyAppRemoval: v })} /></div>
        </div>
        <div className="card">
          <label>Time zone
            <select value={form.timeZone ?? ''} onChange={(e) => set({ timeZone: e.target.value || null })}>
              <option value="">Each device's local time</option>
              {timeZones().map((z) => <option key={z} value={z}>{z}</option>)}
            </select>
            <span className="help">Schedules run in this time zone. Leave empty to use each phone's own time zone.</span>
          </label>
        </div>
        <div><button className="btn btn-primary" disabled={save.isPending}>Save settings</button></div>
      </form>
    </>
  );
}
