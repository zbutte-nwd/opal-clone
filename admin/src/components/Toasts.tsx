import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';
import { ApiError } from '../api/client';

interface Toast { id: number; kind: 'error' | 'success'; text: string }
interface ToastApi {
  error: (e: unknown) => void;
  success: (text: string) => void;
}
const Ctx = createContext<ToastApi>({ error: () => {}, success: () => {} });
export const useToast = () => useContext(Ctx);

export function errorMessage(e: unknown): string {
  if (e instanceof ApiError) return e.message;
  if (e instanceof Error) return e.message;
  return 'Something went wrong.';
}

let nextId = 1;
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const push = useCallback((kind: Toast['kind'], text: string) => {
    const id = nextId++;
    setToasts((t) => [...t, { id, kind, text }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), kind === 'error' ? 7000 : 3500);
  }, []);
  const api = useMemo<ToastApi>(() => ({
    error: (e) => push('error', errorMessage(e)),
    success: (text) => push('success', text),
  }), [push]);
  return (
    <Ctx.Provider value={api}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast toast-${t.kind}`}>
            <span>{t.text}</span>
            <button className="btn-link" aria-label="Dismiss" onClick={() => setToasts((x) => x.filter((y) => y.id !== t.id))}>×</button>
          </div>
        ))}
      </div>
    </Ctx.Provider>
  );
}
