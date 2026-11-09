import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { api, getToken, onUnauthorized, setToken } from './api/client';
import type { Admin } from './api/types';

interface AuthState {
  admin: Admin | null;
  loading: boolean;
  login: (email: string, password: string) => Promise<void>;
  register: (email: string, password: string, name: string) => Promise<void>;
  logout: () => void;
}
const Ctx = createContext<AuthState | null>(null);
export function useAuth(): AuthState {
  const v = useContext(Ctx);
  if (!v) throw new Error('useAuth outside AuthProvider');
  return v;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [admin, setAdmin] = useState<Admin | null>(null);
  const [loading, setLoading] = useState<boolean>(() => !!getToken());
  const qc = useQueryClient();

  const logout = useCallback(() => {
    setToken(null);
    setAdmin(null);
    qc.clear();
  }, [qc]);

  useEffect(() => {
    onUnauthorized(logout); // any 401 → back to login
    return () => onUnauthorized(null);
  }, [logout]);

  useEffect(() => {
    if (!getToken()) return;
    api.me().then((r) => setAdmin(r.admin)).catch(() => setToken(null)).finally(() => setLoading(false));
  }, []);

  const value = useMemo<AuthState>(() => ({
    admin, loading, logout,
    login: async (email, password) => {
      const r = await api.login({ email, password });
      setToken(r.token);
      setAdmin(r.admin);
    },
    register: async (email, password, name) => {
      const r = await api.register({ email, password, name });
      setToken(r.token);
      setAdmin(r.admin);
    },
  }), [admin, loading, logout]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
