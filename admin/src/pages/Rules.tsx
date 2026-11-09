import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '../api/client';
import type { Rule, RuleInput } from '../api/types';
import { Confirm, Empty, Modal, PageHeader, Spinner, Switch, groupNameMap } from '../components/ui';
import { useToast } from '../components/Toasts';
import { summarizeRule } from '../lib/schedule';
import { RuleEditor } from './RuleEditor';

export function RulesPage() {
  const qc = useQueryClient();
  const toast = useToast();
  const rules = useQuery({ queryKey: ['rules'], queryFn: api.listRules });
  const groups = useQuery({ queryKey: ['groups'], queryFn: api.listGroups });
  const [editing, setEditing] = useState<Rule | 'new' | null>(null);
  const [deleting, setDeleting] = useState<Rule | null>(null);
  const names = groupNameMap(groups.data);
  const invalidate = () => qc.invalidateQueries({ queryKey: ['rules'] });

  const save = useMutation({
    mutationFn: (b: RuleInput) => (editing && editing !== 'new' ? api.updateRule(editing.id, b) : api.createRule(b)),
    onSuccess: () => { setEditing(null); void invalidate(); },
    onError: toast.error,
  });
  const toggleEnabled = useMutation({ mutationFn: (r: Rule) => api.updateRule(r.id, { enabled: !r.enabled }), onSuccess: invalidate, onError: toast.error });
  const toggleManual = useMutation({ mutationFn: ({ r, active }: { r: Rule; active: boolean }) => api.toggleRule(r.id, active), onSuccess: invalidate, onError: toast.error });
  const del = useMutation({ mutationFn: (id: string) => api.deleteRule(id), onSuccess: () => { setDeleting(null); void invalidate(); }, onError: (e) => { setDeleting(null); toast.error(e); } });

  return (
    <>
      <PageHeader title="Rules"><button className="btn btn-primary" onClick={() => setEditing('new')} disabled={!groups.data?.length}>New rule</button></PageHeader>
      {groups.data && groups.data.length === 0 && <p className="note">Create a group first — rules decide when groups are blocked.</p>}
      {rules.isLoading ? <Spinner /> : !rules.data?.length ? <Empty title="No rules yet">Rules say when groups are blocked: on a schedule, after a usage limit, or with a manual switch.</Empty> : (
        <div className="list">
          {rules.data.map((r) => (
            <div key={r.id} className="card item">
              <div className="grow">
                <h3>{r.name}{r.source === 'local' && <span className="chip" style={{ marginLeft: 8 }}>on phone</span>}</h3>
                <div className="muted">{summarizeRule(r, names)}</div>
              </div>
              <div className="row">
                {r.trigger.type === 'manual' && (
                  <label className="inline">{r.trigger.active ? 'On' : 'Off'}
                    <Switch label={`${r.name} active`} checked={r.trigger.active} onChange={(active) => toggleManual.mutate({ r, active })} /></label>
                )}
                <label className="inline">Enabled
                  <Switch label={`${r.name} enabled`} checked={r.enabled} onChange={() => toggleEnabled.mutate(r)} /></label>
                <button className="btn btn-small" onClick={() => setEditing(r)}>Edit</button>
                <button className="btn btn-small" onClick={() => setDeleting(r)}>Delete</button>
              </div>
            </div>
          ))}
        </div>
      )}
      {editing && (
        <Modal title={editing === 'new' ? 'New rule' : 'Edit rule'} onClose={() => setEditing(null)}>
          <RuleEditor groups={groups.data ?? []} rule={editing === 'new' ? null : editing} busy={save.isPending}
            onSubmit={(b) => save.mutate(b)} onCancel={() => setEditing(null)} />
        </Modal>
      )}
      {deleting && <Confirm title={`Delete “${deleting.name}”?`} danger confirmLabel="Delete" onCancel={() => setDeleting(null)} onConfirm={() => del.mutate(deleting.id)}><p>This cannot be undone.</p></Confirm>}
    </>
  );
}
