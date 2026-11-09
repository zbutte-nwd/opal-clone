import { useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import { Confirm, Empty, GroupPicker, PageHeader, Spinner, StatusBadge, groupNameMap } from '../components/ui';
import { useToast } from '../components/Toasts';
import { formatDateTime, formatCountdown, relativeTime } from '../lib/time';
import type { GroupState } from '../api/types';

const DURATIONS: Array<[string, number | undefined]> = [
  ['15 minutes', 15], ['30 minutes', 30], ['1 hour', 60], ['2 hours', 120], ['Until I undo', undefined],
];

function reasonText(s: GroupState): string {
  switch (s.reason.kind) {
    case 'override': return 'remote override';
    case 'session': return 'focus session';
    case 'rule': return 'rule';
    case 'pause': return 'paused';
    default: return s.blocked ? 'blocked' : 'not blocked';
  }
}

export function DeviceDetailPage() {
  const { id = '' } = useParams();
  const nav = useNavigate();
  const qc = useQueryClient();
  const toast = useToast();
  const device = useQuery({ queryKey: ['device', id], queryFn: () => api.getDevice(id), refetchInterval: 15_000 });
  const events = useQuery({ queryKey: ['device', id, 'events'], queryFn: () => api.deviceEvents(id, 50), refetchInterval: 30_000 });
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  const [selected, setSelected] = useState<string[]>([]);
  const [duration, setDuration] = useState<string>('30');
  const [renaming, setRenaming] = useState<string | null>(null);
  const [confirmUnpair, setConfirmUnpair] = useState(false);

  const refresh = () => { void qc.invalidateQueries({ queryKey: ['device', id] }); void qc.invalidateQueries({ queryKey: ['devices'] }); void qc.invalidateQueries({ queryKey: ['overrides'] }); };

  const override = useMutation({
    mutationFn: (action: 'block' | 'unblock') => api.createOverride({
      groupIds: selected, action, deviceIds: [id],
      ...(duration === 'forever' ? {} : { durationMinutes: Number(duration) }),
      reason: 'Quick action from dashboard',
    }),
    onSuccess: (_, action) => { toast.success(`${action === 'block' ? 'Block' : 'Unblock'} sent`); refresh(); },
    onError: toast.error,
  });
  const push = useMutation({ mutationFn: () => api.pushDevice(id), onSuccess: () => toast.success('Push sent'), onError: toast.error });
  const rename = useMutation({ mutationFn: (name: string) => api.renameDevice(id, name), onSuccess: () => { setRenaming(null); refresh(); }, onError: toast.error });
  const unpair = useMutation({
    mutationFn: () => api.unpairDevice(id),
    onSuccess: () => { void qc.invalidateQueries({ queryKey: ['devices'] }); toast.success('Device unpaired'); nav('/devices'); },
    onError: toast.error,
  });

  if (device.isLoading) return <Spinner />;
  if (!device.data) return <Empty title="Device not found" />;
  const d = device.data;
  const names = groupNameMap(groups.data);
  const state = d.currentState ?? [];
  const reported = d.reportedBlockedGroupIds ?? d.blockedGroupIds ?? [];

  return (
    <>
      <PageHeader title={d.name}>
        <StatusBadge status={d.status} />
        <button className="btn" onClick={() => setRenaming(d.name)}>Rename</button>
        <button className="btn" onClick={() => push.mutate()} disabled={push.isPending}>Force push</button>
        <button className="btn btn-danger" onClick={() => setConfirmUnpair(true)}>Unpair</button>
      </PageHeader>

      <div className="card stack">
        <div className="small">
          {d.model ?? 'iPhone'}{d.osVersion ? ` · iOS ${d.osVersion}` : ''}{d.appVersion ? ` · app ${d.appVersion}` : ''} ·
          last seen {relativeTime(d.lastSeenAt)} · policy applied v{d.appliedVersion ?? '—'} / latest v{d.latestVersion} ·
          Screen Time access: {d.authorizationStatus ?? 'unknown'}
        </div>
      </div>

      <section className="card stack" aria-labelledby="state-h">
        <h2 id="state-h">Current state (computed by server)</h2>
        {state.length === 0 ? <p className="muted">No state yet.</p> : (
          <div className="table-wrap"><table>
            <thead><tr><th>Group</th><th>State</th><th>Why</th><th>Strict</th><th>Until</th></tr></thead>
            <tbody>{state.map((s) => (
              <tr key={s.groupId}>
                <td>{names[s.groupId] ?? s.groupId}</td>
                <td>{s.blocked ? <strong>Blocked</strong> : 'Open'}</td>
                <td>{reasonText(s)}</td>
                <td>{s.strict ? 'yes' : 'no'}</td>
                <td>{s.until ? formatCountdown(s.until) : '—'}</td>
              </tr>))}
            </tbody>
          </table></div>
        )}
        <p className="small muted">
          Reported by the phone: {reported.length ? reported.map((g) => names[g] ?? g).join(', ') : 'nothing blocked'}.
          Differences from the server's view mean the phone has not applied the latest policy yet.
        </p>
      </section>

      <section className="card stack" aria-labelledby="qa-h">
        <h2 id="qa-h">Quick actions</h2>
        <GroupPicker groups={groups.data ?? []} value={selected} onChange={setSelected} label="Groups to change" />
        <label>For
          <select value={duration} onChange={(e) => setDuration(e.target.value)}>
            {DURATIONS.map(([label, mins]) => <option key={label} value={mins ?? 'forever'}>{label}</option>)}
          </select>
        </label>
        <div className="row">
          <button className="btn btn-primary" disabled={!selected.length || override.isPending} onClick={() => override.mutate('block')}>Block now</button>
          <button className="btn" disabled={!selected.length || override.isPending} onClick={() => override.mutate('unblock')}>Unblock now</button>
        </div>
        <p className="help">Creates an override for this device only. Overrides beat rules and can be cancelled on the Overrides page.</p>
      </section>

      <section className="card" aria-labelledby="ev-h">
        <h2 id="ev-h">Events</h2>
        {events.isLoading ? <Spinner /> : !events.data?.length ? <p className="muted">No events yet.</p> : (
          <ul className="timeline">
            {events.data.map((e) => (
              <li key={e.id}><time dateTime={e.occurredAt}>{formatDateTime(e.occurredAt)}</time><strong>{e.type}</strong>
                {e.data && <span className="muted small">{JSON.stringify(e.data)}</span>}</li>
            ))}
          </ul>
        )}
      </section>

      {renaming !== null && (
        <Confirm title="Rename device" confirmLabel="Save" onCancel={() => setRenaming(null)} onConfirm={() => renaming.trim() && rename.mutate(renaming.trim())}>
          <label>Name<input type="text" value={renaming} onChange={(e) => setRenaming(e.target.value)} autoFocus /></label>
        </Confirm>
      )}
      {confirmUnpair && (
        <Confirm title="Unpair this device?" danger confirmLabel="Unpair" onCancel={() => setConfirmUnpair(false)} onConfirm={() => unpair.mutate()}>
          <p>The phone will stop receiving remote policy. Blocks already applied on the phone follow its local protection lock.</p>
        </Confirm>
      )}
    </>
  );
}
