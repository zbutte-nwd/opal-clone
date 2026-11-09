import { useState } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { api } from '../api/client';
import { useAuth } from '../auth';

const NAV = [
  ['/devices', 'Devices'],
  ['/groups', 'Groups'],
  ['/rules', 'Rules'],
  ['/overrides', 'Overrides'],
  ['/unlock-requests', 'Unlock requests'],
  ['/settings', 'Settings'],
  ['/api-keys', 'API keys'],
] as const;

export function Layout() {
  const [open, setOpen] = useState(false);
  const { admin, logout } = useAuth();
  const pending = useQuery({
    queryKey: ['unlock-requests', 'pending'],
    queryFn: () => api.listUnlockRequests('pending'),
    refetchInterval: 30_000,
  });
  const count = pending.data?.length ?? 0;
  return (
    <div className="shell">
      <a className="skip" href="#main">Skip to content</a>
      <div className="topbar">
        <button className="btn" aria-expanded={open} aria-controls="sidebar" onClick={() => setOpen((o) => !o)}>☰ Menu</button>
        <strong>Tether</strong>
      </div>
      <nav id="sidebar" className={`sidebar ${open ? 'open' : ''}`} aria-label="Main">
        <div className="brand">Tether <span className="muted">admin</span></div>
        <ul>
          {NAV.map(([to, label]) => (
            <li key={to}>
              <NavLink to={to} onClick={() => setOpen(false)}>
                {label}
                {to === '/unlock-requests' && count > 0 && <span className="count" aria-label={`${count} pending`}>{count}</span>}
              </NavLink>
            </li>
          ))}
        </ul>
        <div className="sidebar-foot">
          <div className="muted small">{admin?.email}</div>
          <button className="btn btn-small" onClick={logout}>Sign out</button>
        </div>
      </nav>
      <main id="main" className="main"><Outlet /></main>
    </div>
  );
}
