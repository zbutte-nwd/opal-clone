import { useState, type FormEvent } from 'react';
import { useAuth } from '../auth';
import { useToast } from '../components/Toasts';

export function LoginPage() {
  const { login, register } = useAuth();
  const toast = useToast();
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    try {
      if (mode === 'login') await login(email, password);
      else await register(email, password, name);
    } catch (err) {
      toast.error(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="center">
      <form className="card auth-card stack" onSubmit={submit}>
        <h1>Tether admin</h1>
        <p className="muted">{mode === 'login' ? 'Sign in to manage your devices and block rules.' : 'Create an account to manage devices.'}</p>
        {mode === 'register' && (
          <label>Name
            <input type="text" autoComplete="name" required value={name} onChange={(e) => setName(e.target.value)} />
          </label>
        )}
        <label>Email
          <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label>Password
          <input type="password" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        <button className="btn btn-primary" disabled={busy}>{mode === 'login' ? 'Sign in' : 'Create account'}</button>
        <button type="button" className="btn-link" onClick={() => setMode(mode === 'login' ? 'register' : 'login')}>
          {mode === 'login' ? 'No account? Register' : 'Have an account? Sign in'}
        </button>
      </form>
    </div>
  );
}
