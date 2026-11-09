import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useMutation, useQuery } from '@tanstack/react-query';
import QRCode from 'qrcode';
import { api } from '../api/client';
import type { BlockGroup, DeviceSummary, PairingCode } from '../api/types';
import { Empty, Modal, PageHeader, Spinner, StatusBadge, groupNameMap, useNow } from '../components/ui';
import { useToast } from '../components/Toasts';
import { formatCountdown, relativeTime } from '../lib/time';

export function blockedGroupIds(d: DeviceSummary): string[] {
  if (d.currentState) return d.currentState.filter((s) => s.blocked).map((s) => s.groupId);
  return d.blockedGroupIds ?? [];
}

export function DeviceList({ devices, groups }: { devices: DeviceSummary[]; groups: BlockGroup[] }) {
  const names = groupNameMap(groups);
  return (
    <div className="grid">
      {devices.map((d) => {
        const blocked = blockedGroupIds(d);
        const behind = d.appliedVersion != null && d.appliedVersion < d.latestVersion;
        return (
          <article key={d.id} className="card stack" aria-label={d.name}>
            <div className="item">
              <h3><Link to={`/devices/${d.id}`}>{d.name}</Link></h3>
              <StatusBadge status={d.status} />
            </div>
            <dl className="small stack" style={{ margin: 0 }}>
              <div>Last seen: <strong>{relativeTime(d.lastSeenAt)}</strong></div>
              <div>Policy: applied v{d.appliedVersion ?? '—'} / latest v{d.latestVersion}{behind && <span className="muted"> (catching up)</span>}</div>
              <div>Screen Time access: <strong>{d.authorizationStatus ?? 'unknown'}</strong>
                {d.authorizationStatus && d.authorizationStatus !== 'approved' && <span className="error-text"> — blocking is not enforced</span>}
              </div>
              <div>Blocked now: {blocked.length ? blocked.map((id) => names[id] ?? id).join(', ') : <span className="muted">nothing</span>}</div>
            </dl>
          </article>
        );
      })}
    </div>
  );
}

export function DevicesPage() {
  const [adding, setAdding] = useState(false);
  const devices = useQuery({ queryKey: ['devices'], queryFn: api.listDevices, refetchInterval: 15_000 });
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  return (
    <>
      <PageHeader title="Devices">
        <button className="btn btn-primary" onClick={() => setAdding(true)}>Add device</button>
      </PageHeader>
      {devices.isLoading ? <Spinner /> : devices.data && devices.data.length > 0 ? (
        <DeviceList devices={devices.data} groups={groups.data ?? []} />
      ) : (
        <Empty title="No devices yet">Add a device to pair an iPhone with this account.</Empty>
      )}
      {adding && <AddDevice onClose={() => setAdding(false)} />}
    </>
  );
}

function AddDevice({ onClose }: { onClose: () => void }) {
  const toast = useToast();
  const [pairing, setPairing] = useState<PairingCode | null>(null);
  const create = useMutation({ mutationFn: () => api.createPairingCode(), onSuccess: setPairing, onError: toast.error });
  const started = useRef(false);
  useEffect(() => {
    if (!started.current) { started.current = true; create.mutate(); }
  }, [create]);
  const now = useNow();
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (pairing && canvas.current) {
      QRCode.toCanvas(canvas.current, pairing.qrPayload, { width: 220, margin: 1 }).catch(() => {});
    }
  }, [pairing]);
  const expired = pairing ? Date.parse(pairing.expiresAt) <= now : false;

  return (
    <Modal title="Add a device" onClose={onClose}>
      {!pairing ? <Spinner label="Generating pairing code…" /> : (
        <div className="stack">
          <div className="big-code" aria-label={`Pairing code ${pairing.code}`}>{pairing.code}</div>
          <canvas ref={canvas} className="qr" aria-label="Pairing QR code" />
          <p style={{ textAlign: 'center' }}>
            {expired ? <span className="error-text">This code has expired.</span> : <>Expires in <strong>{formatCountdown(pairing.expiresAt, now)}</strong></>}
            {' '}· single use
          </p>
          {expired && <button className="btn" onClick={() => create.mutate()}>Generate a new code</button>}
          <ol>
            <li>Install the Tether app on the iPhone.</li>
            <li>Open the app, go to <strong>Settings → Pair with server</strong>.</li>
            <li>Enter the code above (or scan the QR code).</li>
            <li>Grant Screen Time access when asked. The device appears here within a minute.</li>
          </ol>
        </div>
      )}
      <div className="row end"><button className="btn" onClick={onClose}>Done</button></div>
    </Modal>
  );
}
