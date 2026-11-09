import { useState, type FormEvent } from 'react';
import type { BlockGroup, IsoWeekday, Rule, RuleInput, Trigger, Window } from '../api/types';
import { DayPicker, GroupPicker, Switch } from '../components/ui';
import { ALL_DAYS, WEEKDAYS, isOvernight, validateTrigger, validateWindow } from '../lib/schedule';

type TriggerType = Trigger['type'];

function defaultTrigger(type: TriggerType): Trigger {
  switch (type) {
    case 'schedule': return { type, windows: [{ days: [...WEEKDAYS], start: '09:00', end: '17:00' }] };
    case 'usageLimit': return { type, dailyMinutes: 60, days: [...ALL_DAYS] };
    case 'manual': return { type, active: false };
  }
}

export function RuleEditor({ groups, rule, onSubmit, onCancel, busy }: {
  groups: BlockGroup[]; rule?: Rule | null; onSubmit: (r: RuleInput) => void; onCancel: () => void; busy?: boolean;
}) {
  const [name, setName] = useState(rule?.name ?? '');
  const [groupIds, setGroupIds] = useState<string[]>(rule?.groupIds ?? []);
  const [enabled, setEnabled] = useState(rule?.enabled ?? true);
  const [action, setAction] = useState<Rule['action']>(rule?.action ?? 'block');
  const [strictness, setStrictness] = useState<Rule['strictness']>(rule?.strictness ?? 'flexible');
  const [trigger, setTrigger] = useState<Trigger>(rule?.trigger ?? defaultTrigger('schedule'));
  const [priority, setPriority] = useState<number>(rule?.priority ?? 0);
  const [maxPauses, setMaxPauses] = useState<string>(rule?.maxPausesPerDay == null ? '' : String(rule.maxPausesPerDay));
  const [showAdv, setShowAdv] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const setWindow = (i: number, w: Window) => {
    if (trigger.type !== 'schedule') return;
    setTrigger({ ...trigger, windows: trigger.windows.map((x, j) => (j === i ? w : x)) });
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!name.trim()) return setError('Give the rule a name.');
    if (groupIds.length === 0) return setError('Pick at least one group.');
    const tErr = validateTrigger(trigger);
    if (tErr) return setError(tErr);
    setError(null);
    const out: RuleInput = {
      name: name.trim(), groupIds, enabled, action, trigger, strictness, priority,
      maxPausesPerDay: maxPauses === '' ? null : Math.max(0, Math.floor(Number(maxPauses))),
    };
    onSubmit(out);
  };

  return (
    <form className="stack" onSubmit={submit} noValidate>
      <label>Name<input type="text" maxLength={60} value={name} onChange={(e) => setName(e.target.value)} /></label>
      <GroupPicker groups={groups} value={groupIds} onChange={setGroupIds} label="Groups" />

      <label>Trigger
        <select value={trigger.type} onChange={(e) => setTrigger(defaultTrigger(e.target.value as TriggerType))}>
          <option value="schedule">Schedule (time windows)</option>
          <option value="usageLimit">Usage limit (minutes per day)</option>
          <option value="manual">Manual (on/off switch)</option>
        </select>
      </label>

      {trigger.type === 'schedule' && (
        <div className="stack">
          {trigger.windows.map((w, i) => {
            const err = validateWindow(w);
            return (
              <div key={i} className="window" role="group" aria-label={`Window ${i + 1}`}>
                <DayPicker value={w.days} onChange={(days) => setWindow(i, { ...w, days })} label={`Window ${i + 1} days`} />
                <div className="row">
                  <label>Start<input type="time" value={w.start === '24:00' ? '00:00' : w.start} onChange={(e) => setWindow(i, { ...w, start: e.target.value })} /></label>
                  <label>End<input type="time" value={w.end === '24:00' ? '00:00' : w.end} disabled={w.end === '24:00'} onChange={(e) => setWindow(i, { ...w, end: e.target.value })} /></label>
                  <label className="inline"><input type="checkbox" checked={w.end === '24:00'} onChange={(e) => setWindow(i, { ...w, end: e.target.checked ? '24:00' : '17:00' })} /> Until midnight (end of day)</label>
                  {isOvernight(w) && <span className="chip">→ next day</span>}
                  {trigger.windows.length > 1 && (
                    <button type="button" className="btn btn-small" onClick={() => setTrigger({ ...trigger, windows: trigger.windows.filter((_, j) => j !== i) })}>Remove</button>)}
                </div>
                {err && <div className="error-text" role="alert">{err}</div>}
              </div>
            );
          })}
          <div><button type="button" className="btn" onClick={() => setTrigger({ ...trigger, windows: [...trigger.windows, { days: [...WEEKDAYS], start: '09:00', end: '17:00' }] })}>Add window</button></div>
        </div>
      )}

      {trigger.type === 'usageLimit' && (
        <div className="stack">
          <label>Minutes per day
            <input type="number" min={1} max={1440} value={trigger.dailyMinutes}
              onChange={(e) => setTrigger({ ...trigger, dailyMinutes: Number(e.target.value) })} /></label>
          <DayPicker value={trigger.days} onChange={(days) => setTrigger({ ...trigger, days: days as IsoWeekday[] })} label="Limit days" />
          <p className="help">The phone measures usage on-device; once the combined limit is reached the groups are blocked for the rest of the day.</p>
        </div>
      )}

      {trigger.type === 'manual' && (
        <div className="row"><Switch label="Active now" checked={trigger.active} onChange={(active) => setTrigger({ type: 'manual', active })} />
          <span>{trigger.active ? 'Active' : 'Off'} — you can flip this from the Rules list at any time.</span></div>
      )}

      <div className="row">
        <label>Action
          <select value={action} onChange={(e) => setAction(e.target.value as Rule['action'])}>
            <option value="block">Block</option><option value="allow">Allow (exception)</option>
          </select></label>
        <label>Strictness
          <select value={strictness} onChange={(e) => setStrictness(e.target.value as Rule['strictness'])}>
            <option value="flexible">Flexible (user can pause)</option><option value="strict">Strict (no pausing)</option>
          </select></label>
        <label className="inline"><Switch label="Enabled" checked={enabled} onChange={setEnabled} /> Enabled</label>
      </div>

      <button type="button" className="btn-link" aria-expanded={showAdv} onClick={() => setShowAdv((s) => !s)}>{showAdv ? '▾' : '▸'} Advanced</button>
      {showAdv && (
        <div className="row">
          <label>Priority<input type="number" value={priority} onChange={(e) => setPriority(Number(e.target.value))} />
            <span className="help">Higher wins when rules conflict.</span></label>
          <label>Max pauses per day<input type="number" min={0} value={maxPauses} placeholder="unlimited" onChange={(e) => setMaxPauses(e.target.value)} /></label>
        </div>
      )}

      {error && <div className="error-text" role="alert">{error}</div>}
      <div className="row end"><button type="button" className="btn" onClick={onCancel}>Cancel</button>
        <button className="btn btn-primary" disabled={busy}>Save rule</button></div>
    </form>
  );
}
