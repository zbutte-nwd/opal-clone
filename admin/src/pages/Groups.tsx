import { useState, type FormEvent } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import type { BlockGroup, GroupInput } from '../api/types';
import { Confirm, Empty, Modal, PageHeader, Spinner } from '../components/ui';
import { useToast } from '../components/Toasts';
import { MAX_DOMAINS, normalizeDomain, validateDomain } from '../lib/domains';

const COLORS = ['#e03131', '#f08c00', '#2f9e44', '#1c7ed6', '#7048e8', '#d6336c', '#495057'];

export function GroupsPage() {
  const qc = useQueryClient();
  const toast = useToast();
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  const [editing, setEditing] = useState<BlockGroup | 'new' | null>(null);
  const [deleting, setDeleting] = useState<BlockGroup | null>(null);
  const del = useMutation({
    mutationFn: (id: string) => api.deleteGroup(id),
    onSuccess: () => { setDeleting(null); void qc.invalidateQueries({ queryKey: ['groups'] }); void qc.invalidateQueries({ queryKey: ['rules'] }); },
    onError: (e) => { setDeleting(null); toast.error(e); },
  });
  return (
    <>
      <PageHeader title="Groups"><button className="btn btn-primary" onClick={() => setEditing('new')}>New group</button></PageHeader>
      <p className="note">Apps for this group are chosen on each phone (Apple privacy rule). Devices will be prompted to pick apps for new groups.
        The server only knows a group's name, colour and web domains, never which apps are in it.</p>
      <div style={{ height: 12 }} />
      {groups.isLoading ? <Spinner /> : !groups.data?.length ? <Empty title="No groups yet">Create a group such as “Social” or “Games”, then use it in rules.</Empty> : (
        <div className="grid">
          {groups.data.map((g) => (
            <div key={g.id} className="card stack">
              <div className="item"><h3><span className="dot" style={{ background: g.colorHex ?? 'var(--muted)', marginRight: 8 }} aria-hidden />{g.name}</h3>
                <div className="row"><button className="btn btn-small" onClick={() => setEditing(g)}>Edit</button>
                  <button className="btn btn-small" onClick={() => setDeleting(g)}>Delete</button></div></div>
              <div className="chips">{g.webDomains.length ? g.webDomains.map((d) => <span key={d} className="chip">{d}</span>) : <span className="muted small">No web domains</span>}</div>
            </div>
          ))}
        </div>
      )}
      {editing && <GroupEditor group={editing === 'new' ? null : editing} onClose={() => setEditing(null)} />}
      {deleting && (
        <Confirm title={`Delete “${deleting.name}”?`} danger confirmLabel="Delete" onCancel={() => setDeleting(null)} onConfirm={() => del.mutate(deleting.id)}>
          <p>Rules that use this group will lose it. Devices drop the group at their next sync.</p>
        </Confirm>
      )}
    </>
  );
}

export function DomainEditor({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);
  const add = () => {
    const parts = text.split(/[\s,]+/).map(normalizeDomain).filter(Boolean);
    let next = value;
    for (const p of parts) {
      const err = validateDomain(p, next);
      if (err) { setError(`${p}: ${err}`); return; }
      next = [...next, p];
    }
    setError(null); setText(''); onChange(next);
  };
  return (
    <div className="stack">
      <div className="label">Web domains <span className="help">({value.length}/{MAX_DOMAINS})</span></div>
      <div className="chips">
        {value.map((d) => (
          <span key={d} className="chip domain">{d}
            <button type="button" aria-label={`Remove ${d}`} onClick={() => onChange(value.filter((x) => x !== d))}>×</button></span>
        ))}
      </div>
      <div className="row">
        <input type="text" aria-label="Add domain" placeholder="example.com" value={text} style={{ flex: 1, minWidth: 160 }}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } }} />
        <button type="button" className="btn" onClick={add}>Add</button>
      </div>
      {error && <div className="error-text" role="alert">{error}</div>}
    </div>
  );
}

function GroupEditor({ group, onClose }: { group: BlockGroup | null; onClose: () => void }) {
  const qc = useQueryClient();
  const toast = useToast();
  const [name, setName] = useState(group?.name ?? '');
  const [color, setColor] = useState(group?.colorHex ?? COLORS[0]!);
  const [domains, setDomains] = useState<string[]>(group?.webDomains ?? []);
  const save = useMutation({
    mutationFn: (b: GroupInput) => (group ? api.updateGroup(group.id, b) : api.createGroup(b)),
    onSuccess: () => { void qc.invalidateQueries({ queryKey: ['groups'] }); onClose(); },
    onError: toast.error,
  });
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!name.trim()) return;
    save.mutate({ name: name.trim(), colorHex: color, webDomains: domains });
  };
  return (
    <Modal title={group ? 'Edit group' : 'New group'} onClose={onClose}>
      <form className="stack" onSubmit={submit}>
        <label>Name<input type="text" required maxLength={60} value={name} onChange={(e) => setName(e.target.value)} autoFocus /></label>
        <div className="label">Colour
          <div className="chips" role="radiogroup" aria-label="Colour">
            {COLORS.map((c) => (
              <button key={c} type="button" role="radio" aria-checked={color === c} aria-label={c}
                className={`chip chip-toggle ${color === c ? 'selected' : ''}`} onClick={() => setColor(c)}>
                <span className="dot" style={{ background: c }} />
              </button>
            ))}
          </div>
        </div>
        <DomainEditor value={domains} onChange={setDomains} />
        <p className="note info small">Apps for this group are chosen on each phone (Apple privacy rule). Devices will be prompted to pick apps for new groups.</p>
        <div className="row end"><button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" disabled={save.isPending}>Save</button></div>
      </form>
    </Modal>
  );
}
