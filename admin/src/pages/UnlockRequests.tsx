import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import type { UnlockRequest } from '../api/types';
import { Empty, PageHeader, Spinner, groupNameMap } from '../components/ui';
import { useToast } from '../components/Toasts';
import { relativeTime } from '../lib/time';

export function UnlockRequestsPage() {
  const reqs = useQuery({ queryKey: ['unlock-requests', 'all'], queryFn: () => api.listUnlockRequests(), refetchInterval: 15_000 });
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  const devices = useQuery({ queryKey: ['devices'], queryFn: api.listDevices });
  const names = groupNameMap(groups.data);
  const dev = Object.fromEntries((devices.data ?? []).map((d) => [d.id, d.name]));
  const sorted = [...(reqs.data ?? [])].sort((a, b) =>
    (a.status === 'pending' ? 0 : 1) - (b.status === 'pending' ? 0 : 1) || Date.parse(b.createdAt) - Date.parse(a.createdAt));
  return (
    <>
      <PageHeader title="Unlock requests" />
      {reqs.isLoading ? <Spinner /> : !sorted.length ? <Empty title="No unlock requests">When someone asks to unlock groups on a phone, it shows up here.</Empty> : (
        <div className="list">{sorted.map((r) => <RequestCard key={r.id} r={r} names={names} deviceName={dev[r.deviceId] ?? r.deviceId} />)}</div>
      )}
    </>
  );
}

function RequestCard({ r, names, deviceName }: { r: UnlockRequest; names: Record<string, string>; deviceName: string }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [minutes, setMinutes] = useState<number>(r.minutes ?? 15);
  const [note, setNote] = useState('');
  const done = () => { void qc.invalidateQueries({ queryKey: ['unlock-requests'] }); void qc.invalidateQueries({ queryKey: ['overrides'] }); };
  const approve = useMutation({
    mutationFn: () => api.approveUnlock(r.id, r.kind === 'groups' ? minutes : undefined),
    onSuccess: () => { toast.success('Approved'); done(); }, onError: toast.error,
  });
  const deny = useMutation({ mutationFn: () => api.denyUnlock(r.id, note.trim() || undefined), onSuccess: () => { toast.success('Denied'); done(); }, onError: toast.error });
  const pending = r.status === 'pending';
  return (
    <div className="card stack">
      <div className="item">
        <div className="grow">
          <h3>{r.kind === 'groups' ? `Unlock ${r.groupIds.map((g) => names[g] ?? g).join(', ')}` : 'Turn off protection'}</h3>
          <div className="muted small">{deviceName} · requested {relativeTime(r.createdAt)} · {r.status}
            {r.kind === 'groups' && r.minutes ? ` · asked for ${r.minutes} min` : ''}</div>
          {r.reason && <p>“{r.reason}”</p>}
        </div>
      </div>
      {pending && r.kind === 'disableProtection' && (
        <div className="note danger" role="alert">Approving lets this phone switch off ALL blocking. Only approve if you are sure.</div>
      )}
      {pending && (
        <div className="row">
          {r.kind === 'groups' && <label>Minutes<input type="number" min={1} value={minutes} onChange={(e) => setMinutes(Number(e.target.value))} /></label>}
          <button className="btn btn-primary" disabled={approve.isPending || (r.kind === 'groups' && !(minutes >= 1))} onClick={() => approve.mutate()}>Approve</button>
          <label>Note (optional)<input type="text" value={note} onChange={(e) => setNote(e.target.value)} /></label>
          <button className="btn" disabled={deny.isPending} onClick={() => deny.mutate()}>Deny</button>
        </div>
      )}
    </div>
  );
}
