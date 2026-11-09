import { buildApp } from './app.js';
import { loadConfig } from './config.js';

const EMAIL = 'demo@tether.local';
const PASSWORD = 'tether-demo';

const base = loadConfig();
const app = await buildApp({ config: { ...base, publicBaseUrl: base.publicBaseUrl ?? `http://localhost:${base.port}`, logLevel: 'silent', maintenanceIntervalMs: 0 } });
const call = async (method: 'GET' | 'POST', url: string, token?: string, payload?: object) => {
  const r = await app.inject({ method, url, headers: token ? { authorization: `Bearer ${token}` } : {}, ...(payload ? { payload } : {}) });
  return { status: r.statusCode, json: r.body ? JSON.parse(r.body) : null };
};

let auth = await call('POST', '/v1/auth/login', undefined, { email: EMAIL, password: PASSWORD });
if (auth.status !== 200) {
  auth = await call('POST', '/v1/auth/register', undefined, { email: EMAIL, password: PASSWORD, name: 'Demo Admin' });
  if (auth.status !== 201) throw new Error(`register failed: ${JSON.stringify(auth.json)}`);
  const t = auth.json.token as string;
  const mk = async (name: string, colorHex: string, webDomains: string[]) =>
    (await call('POST', '/v1/groups', t, { name, colorHex, webDomains })).json.id as string;
  const social = await mk('Social', '#FF5A5F', ['tiktok.com', 'instagram.com', 'snapchat.com']);
  const games = await mk('Games', '#7B61FF', ['roblox.com', 'twitch.tv']);
  const news = await mk('News', '#2E9CCA', ['news.ycombinator.com', 'reddit.com']);
  await call('POST', '/v1/rules', t, {
    name: 'School hours', groupIds: [social, games, news], action: 'block', strictness: 'flexible', priority: 0,
    trigger: { type: 'schedule', windows: [{ days: [1, 2, 3, 4, 5], start: '08:00', end: '15:00' }] },
  });
  await call('POST', '/v1/rules', t, {
    name: 'Homework mode', groupIds: [games, social], action: 'block', strictness: 'strict', priority: 5,
    trigger: { type: 'manual', active: false },
  });
  console.log('Created demo account with groups Social/Games/News and two rules.');
} else {
  console.log('Demo account already exists.');
}
const code = await call('POST', '/v1/pairing-codes', auth.json.token, { deviceName: 'Demo iPhone' });
console.log(`\nAdmin login : ${EMAIL} / ${PASSWORD}`);
console.log(`Pairing code: ${code.json.code}  (expires ${code.json.expiresAt})`);
console.log(`QR payload  : ${code.json.qrPayload}`);
await app.close();
