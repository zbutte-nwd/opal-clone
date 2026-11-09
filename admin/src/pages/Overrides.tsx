import { useState, type FormEvent } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import type { Override, OverrideInput } from '../api/types';
import { Empty, GroupPicker, Modal, PageHeader, Spinner, groupNameMap, useNow } from '../components/ui';
import { useToast } from '../components/Toasts';
import { formatCountdown, formatDateTime, fromLocalInput, toLocalInput } from '../lib/time';

export function OverridesPage() {
  const qc = useQueryClient();
  const toast = useToast();
  const now = useNow();
  const overrides = useQuery({ queryKey: ['overrides'], queryFn: api.listOverrides, refetchInterval: 15_000 });
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  const devices = useQuery({ queryKey: ['devices'], queryFn: api.listDevices });
  const [creating, setCreating] = useState(false);
  const names = groupNameMap(groups.data);
  const deviceNames = Object.fromEntries((devices.data ?? []).map((d) => [d.id, d.name]));
  const cancel = useMutation({
    mutationFn: (id: string) => api.cancelOverride(id),
    onSuccess: () => { toast.success('Override cancelled'); void qc.invalidateQueries({ queryKey: ['overrides'] }); },
    onError: toast.error,
  });
  // active & upcoming only
  const list = (overrides.data ?? []).filter((o) => !o.endsAt || Date.parse(o.endsAt) > now)
    .sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));

  return (
    <>
      <PageHeader title="Overrides"><button className="btn btn-primary" onClick={() => setCreating(true)}>New override</button></PageHeader>
      <p className="note info">Overrides apply immediately and beat rules. Use them to block or unblock groups for a while.</p>
      <div style={{ height: 12 }} />
      {overrides.isLoading ? <Spinner /> : !list.length ? <Empty title="No active or upcoming overrides" /> : (
        <div className="list">
          {list.map((o) => {
            const active = Date.parse(o.startsAt) <= now;
            return (
              <div key={o.id} className="card item">
                <div className="grow">
                  <h3>{o.action === 'block' ? 'Block' : 'Unblock'} {o.groupIds.map((g) => names[g] ?? g).join(', ')}</h3>
                  <div className="muted small">
                    {active ? <>Active · {o.endsAt ? <>ends in <strong>{formatCountdown(o.endsAt, now)}</strong></> : 'until cancelled'}</>
                      : <>Starts {formatDateTime(o.startsAt)} (in {formatCountdown(o.startsAt, now)})</>}
                    {' · '}{o.deviceIds?.length ? o.deviceIds.map((d) => deviceNames[d] ?? d).join(', ') : 'all devices'}
                    {o.reason ? ` · “${o.reason}”` : ''}
                  </div>
                </div>
                <button className="btn btn-small" onClick={() => cancel.mutate(o.id)} disabled={cancel.isPending}>Cancel</button>
              </div>
            );
          })}
        </div>
      )}
      {creating && <OverrideForm onClose={() => setCreating(false)} />}
    </>
  );
}

export function buildOverride(f: {
  groupIds: string[]; action: 'block' | 'unblock'; start: 'now' | 'later'; startLocal: string;
  end: 'duration' | 'time' | 'forever'; minutes: number; endLocal: string; allDevices: boolean; deviceIds: string[]; reason: string;
}): OverrideInput {
  const body: OverrideInput = { groupIds: f.groupIds, action: f.action };
  if (f.start === 'later') body.startsAt = fromLocalInput(f.startLocal);
  if (f.end === 'duration') body.durationMinutes = f.minutes;
  if (f.end === 'time') body.endsAt = fromLocalInput(f.endLocal);
  if (!f.allDevices) body.deviceIds = f.deviceIds;
  if (f.reason.trim()) body.reason = f.reason.trim();
  return body;
}

function OverrideForm({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const toast = useToast();
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  const devices = useQuery({ queryKey: ['devices'], queryFn: api.listDevices });
  const [groupIds, setGroupIds] = useState<string[]>([]);
  const [action, setAction] = useState<'block' | 'unblock'>('block');
  const [start, setStart] = useState<'now' | 'later'>('now');
  const [startLocal, setStartLocal] = useState(toLocalInput(new Date(Date.now() + 3600_000)));
  const [end, setEnd] = useState<'duration' | 'time' | 'forever'>('duration');
  const [minutes, setMinutes] = useState(60);
  const [endLocal, setEndLocal] = useState(toLocalInput(new Date(Date.now() + 2 * 3600_000)));
  const [allDevices, setAllDevices] = useState(true);
  const [deviceIds, setDeviceIds] = useState<string[]>([]);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const create = useMutation({
    mutationFn: (b: OverrideInput) => api.createOverride(b),
    onSuccess: (_: Override) => { void qc.invalidateQueries({ queryKey: ['overrides'] }); toast.success('Override created'); onClose(); },
    onError: toast.error,
  });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!groupIds.length) return setError('Pick at least one group.');
    if (!allDevices && !deviceIds.length) return setError('Pick at least one device.');
    if (end === 'duration' && !(minutes >= 1)) return setError('Duration must be at least 1 minute.');
    if (end === 'time') {
      const s = start === 'later' ? Date.parse(fromLocalInput(startLocal)) : Date.now();
      if (Date.parse(fromLocalInput(endLocal)) <= s) return setError('End time must be after the start.');
    }
    setError(null);
    create.mutate(buildOverride({ groupIds, action, start, startLocal, end, minutes, endLocal, allDevices, deviceIds, reason }));
  };
  return (
    <Modal title="New override" onClose={onClose}>
      <form className="stack" onSubmit={submit}>
        <GroupPicker groups={groups.data ?? []} value={groupIds} onChange={setGroupIds} />
        <div className="row">
          <label>Action<select value={action} onChange={(e) => setAction(e.target.value as 'block' | 'unblock')}>
            <option value="block">Block</option><option value="unblock">Unblock</option></select></label>
          <label>Starts<select value={start} onChange={(e) => setStart(e.target.value as 'now' | 'later')}>
            <option value="now">Now</option><option value="later">At a set time</option></select></label>
          {start === 'later' && <label>Start time<input type="datetime-local" value={startLocal} onChange={(e) => setStartLocal(e.target.value)} /></label>}
        </div>
        <div className="row">
          <label>Ends<select value={end} onChange={(e) => setEnd(e.target.value as 'duration' | 'time' | 'forever')}>
            <option value="duration">After a duration</option><option value="time">At a set time</option><option value="forever">When I cancel it</option></select></label>
          {end === 'duration' && <label>Minutes<input type="number" min={1} value={minutes} onChange={(e) => setMinutes(Number(e.target.value))} /></label>}
          {end === 'time' && <label>End time<input type="datetime-local" value={endLocal} onChange={(e) => setEndLocal(e.target.value)} /></label>}
        </div>
        <fieldset className="fieldset"><legend>Devices</legend>
          <label className="inline"><input type="checkbox" checked={allDevices} onChange={(e) => setAllDevices(e.target.checked)} /> All devices</label>
          {!allDevices && (devices.data ?? []).map((d) => (
            <label key={d.id} className="inline"><input type="checkbox" checked={deviceIds.includes(d.id)}
              onChange={(e) => setDeviceIds(e.target.checked ? [...deviceIds, d.id] : deviceIds.filter((x) => x !== d.id))} /> {d.name}</label>
          ))}
        </fieldset>
        <label>Reason (optional)<input type="text" maxLength={200} value={reason} onChange={(e) => setReason(e.target.value)} /></label>
        {error && <div className="error-text" role="alert">{error}</div>}
        <div className="row end"><button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" disabled={create.isPending}>Create override</button></div>
      </form>
    </Modal>
  );
}
