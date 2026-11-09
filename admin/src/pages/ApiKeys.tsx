import { useState, type FormEvent } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import type { CreatedApiKey } from '../api/types';
import { Confirm, Empty, PageHeader, Spinner } from '../components/ui';
import { useToast } from '../components/Toasts';
import { formatDateTime } from '../lib/time';

export function ApiKeysPage() {
  const qc = useQueryClient();
  const toast = useToast();
  const keys = useQuery({ queryKey: ['api-keys'], queryFn: api.listApiKeys });
  const [name, setName] = useState('');
  const [created, setCreated] = useState<CreatedApiKey | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);
  const create = useMutation({
    mutationFn: () => api.createApiKey(name.trim()),
    onSuccess: (k) => { setCreated(k); setName(''); void qc.invalidateQueries({ queryKey: ['api-keys'] }); },
    onError: toast.error,
  });
  const del = useMutation({
    mutationFn: (id: string) => api.deleteApiKey(id),
    onSuccess: () => { setDeleting(null); void qc.invalidateQueries({ queryKey: ['api-keys'] }); },
    onError: (e) => { setDeleting(null); toast.error(e); },
  });
  const copy = async (text: string) => {
    try { await navigator.clipboard.writeText(text); toast.success('Copied'); } catch { toast.error(new Error('Copy failed — select and copy manually.')); }
  };
  const origin = window.location.origin;
  const curl = `curl -X POST ${origin}/v1/actions/block \\
  -H "Authorization: Bearer ${created?.key ?? 'tk_live_YOUR_KEY'}" \\
  -H "Content-Type: application/json" \\
  -d '{"groupIds": ["grp_xxx"], "durationMinutes": 30}'`;
  return (
    <>
      <PageHeader title="API keys" />
      <p className="muted">Keys let scripts and automations (Shortcuts, Home Assistant, cron…) block or unblock groups. A key can do everything this dashboard can, except manage keys.</p>
      <form className="card row" onSubmit={(e: FormEvent) => { e.preventDefault(); if (name.trim()) create.mutate(); }} style={{ margin: '12px 0' }}>
        <label style={{ flex: 1 }}>Key name<input type="text" value={name} onChange={(e) => setName(e.target.value)} placeholder="Home Assistant" /></label>
        <button className="btn btn-primary" disabled={!name.trim() || create.isPending}>Create key</button>
      </form>
      {created && (
        <div className="card stack" role="alert">
          <strong>Copy your key now. It won't be shown again.</strong>
          <pre>{created.key}</pre>
          <div className="row"><button className="btn" onClick={() => copy(created.key)}>Copy key</button>
            <button className="btn" onClick={() => setCreated(null)}>I've saved it</button></div>
        </div>
      )}
      {keys.isLoading ? <Spinner /> : !keys.data?.length ? <Empty title="No API keys" /> : (
        <div className="list">
          {keys.data.map((k) => (
            <div key={k.id} className="card item"><div><strong>{k.name}</strong>
              <div className="muted small">{k.prefix ? `${k.prefix}… · ` : ''}{k.createdAt ? `created ${formatDateTime(k.createdAt)}` : ''}</div></div>
              <button className="btn btn-small" onClick={() => setDeleting(k.id)}>Delete</button></div>
          ))}
        </div>
      )}
      <h2 style={{ marginTop: 24 }}>Example</h2>
      <pre>{curl}</pre>
      <button className="btn" onClick={() => copy(curl)}>Copy example</button>
      {deleting && <Confirm title="Delete API key?" danger confirmLabel="Delete" onCancel={() => setDeleting(null)} onConfirm={() => del.mutate(deleting)}><p>Anything using this key will stop working.</p></Confirm>}
    </>
  );
}
