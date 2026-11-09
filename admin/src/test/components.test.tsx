import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { RuleEditor } from '../pages/RuleEditor';
import { DeviceList } from '../pages/Devices';
import type { BlockGroup, DeviceSummary } from '../api/types';

const groups: BlockGroup[] = [
  { id: 'grp_social', name: 'Social', webDomains: [] },
  { id: 'grp_games', name: 'Games', webDomains: [] },
];

describe('RuleEditor', () => {
  it('produces the correct JSON for a schedule rule', async () => {
    const user = userEvent.setup();
    const onSubmit = vi.fn();
    render(<RuleEditor groups={groups} onSubmit={onSubmit} onCancel={() => {}} />);
    await user.type(screen.getByLabelText('Name'), 'School hours');
    await user.click(screen.getByRole('button', { name: 'Social' }));
    await user.click(screen.getByRole('button', { name: 'Games' }));
    // default window: Mon–Fri 09:00–17:00; change times
    const start = screen.getByLabelText('Start') as HTMLInputElement;
    const end = screen.getByLabelText('End') as HTMLInputElement;
    await user.clear(start); await user.type(start, '08:00');
    await user.clear(end); await user.type(end, '15:00');
    await user.selectOptions(screen.getByLabelText('Strictness'), 'strict');
    await user.click(screen.getByRole('button', { name: 'Save rule' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
    expect(onSubmit.mock.calls[0]![0]).toEqual({
      name: 'School hours',
      groupIds: ['grp_social', 'grp_games'],
      enabled: true,
      action: 'block',
      strictness: 'strict',
      priority: 0,
      maxPausesPerDay: null,
      trigger: { type: 'schedule', windows: [{ days: [1, 2, 3, 4, 5], start: '08:00', end: '15:00' }] },
    });
  });

  it('rejects start == end and does not submit', async () => {
    const user = userEvent.setup();
    const onSubmit = vi.fn();
    render(<RuleEditor groups={groups} onSubmit={onSubmit} onCancel={() => {}} />);
    await user.type(screen.getByLabelText('Name'), 'x');
    await user.click(screen.getByRole('button', { name: 'Social' }));
    const end = screen.getByLabelText('End') as HTMLInputElement;
    await user.clear(end); await user.type(end, '09:00');
    expect(screen.getAllByRole('alert')[0]).toHaveTextContent(/different/);
    await user.click(screen.getByRole('button', { name: 'Save rule' }));
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('supports midnight (24:00) end', async () => {
    const user = userEvent.setup();
    const onSubmit = vi.fn();
    render(<RuleEditor groups={groups} onSubmit={onSubmit} onCancel={() => {}} />);
    await user.type(screen.getByLabelText('Name'), 'Evenings');
    await user.click(screen.getByRole('button', { name: 'Social' }));
    await user.click(screen.getByLabelText(/Until midnight/));
    await user.click(screen.getByRole('button', { name: 'Save rule' }));
    expect(onSubmit.mock.calls[0]![0].trigger.windows[0].end).toBe('24:00');
  });
});

describe('DeviceList', () => {
  it('renders status badges, versions and blocked groups', () => {
    const base = { latestVersion: 5, lastSeenAt: new Date().toISOString(), authorizationStatus: 'approved' as const };
    const devices: DeviceSummary[] = [
      { ...base, id: 'dev_1', name: 'Alice iPhone', status: 'online', appliedVersion: 5,
        currentState: [{ groupId: 'grp_social', blocked: true, reason: { kind: 'rule' }, strict: false }] },
      { ...base, id: 'dev_2', name: 'Old phone', status: 'stale', appliedVersion: 3 },
      { ...base, id: 'dev_3', name: 'Revoked', status: 'revoked', appliedVersion: 5, authorizationStatus: 'denied' },
      { ...base, id: 'dev_4', name: 'Lagging', status: 'pending', appliedVersion: 4 },
    ];
    render(<MemoryRouter><DeviceList devices={devices} groups={groups} /></MemoryRouter>);
    expect(screen.getByText('Online')).toBeInTheDocument();
    expect(screen.getByText('Stale')).toBeInTheDocument();
    expect(screen.getByText('Revoked', { selector: '.badge' })).toBeInTheDocument();
    expect(screen.getByText('Pending')).toBeInTheDocument();
    const alice = screen.getByRole('article', { name: 'Alice iPhone' });
    expect(alice).toHaveTextContent('Blocked now: Social');
    expect(alice).toHaveTextContent('applied v5 / latest v5');
    expect(screen.getByRole('article', { name: 'Old phone' })).toHaveTextContent('applied v3 / latest v5');
    expect(screen.getByText('Online')).toHaveAttribute('title', expect.stringMatching(/15 minutes/));
  });
});
