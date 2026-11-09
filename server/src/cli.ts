// Workstation helper. Run from server/ (see docs/WORKSTATION.md):
//   npm run setup -- [--url https://pc.tailnet.ts.net] [--apns-key AuthKey_X.p8 --apns-key-id X]
//   npm run cli -- pair [deviceName] | apikey <name> | info
// `setup` is idempotent: writes .env (only missing keys), creates the admin + an API key on first run.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { buildApp } from './app.js';
import { signJwt } from './auth/crypto.js';
import { loadConfig } from './config.js';

const SERVER_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ENV_PATH = resolve(SERVER_DIR, '.env');
const ADMIN_EMAIL = 'admin@tether.local';

const [cmd = 'info', ...rest] = process.argv.slice(2);
const flag = (name: string): string | undefined => {
  const i = rest.indexOf(`--${name}`);
  return i >= 0 ? rest[i + 1] : undefined;
};
const positional = rest.filter((a, i) => !a.startsWith('--') && !rest[i - 1]?.startsWith('--'));

function readEnv(): Record<string, string> {
  if (!existsSync(ENV_PATH)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(ENV_PATH, 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]!] = m[2]!.replace(/^"(.*)"$/, '$1');
  }
  return out;
}

/** This machine's MagicDNS name via the tailscale CLI, or null. */
function tailscaleUrl(): string | null {
  for (const bin of ['tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe', '/Applications/Tailscale.app/Contents/MacOS/Tailscale']) {
    try {
      const j = JSON.parse(execFileSync(bin, ['status', '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
      const dns = String(j?.Self?.DNSName ?? '').replace(/\.$/, '');
      if (dns) return `https://${dns}`;
    } catch { /* try next */ }
  }
  return null;
}

function writeEnv(): Record<string, string> {
  const cur = readEnv();
  const want: Record<string, string | undefined> = {
    HOST: '127.0.0.1',            // only `tailscale serve` (local proxy) reaches it
    PORT: '8787',
    DATABASE_PATH: resolve(SERVER_DIR, 'data', 'tether.db'),
    JWT_SECRET: randomBytes(48).toString('base64url'),
    PUBLIC_BASE_URL: flag('url') ?? tailscaleUrl() ?? undefined,
    TRUST_PROXY: 'true',
    ALLOW_REGISTRATION: 'false',
    NODE_ENV: 'production',
    LOG_LEVEL: 'warn',            // keep data/server.log small on an always-on box
    APNS_TOPIC: 'com.newwestsite.tether',
    APNS_TEAM_ID: 'W6Y8QLHYZ3',
    APNS_ENV: 'sandbox',          // fallback only; each device reports its own environment
    APNS_KEY_P8: flag('apns-key') ? resolve(flag('apns-key')!) : undefined,
    APNS_KEY_ID: flag('apns-key-id'),
  };
  const next = { ...cur };
  for (const [k, v] of Object.entries(want)) {
    const explicit = (k === 'PUBLIC_BASE_URL' && flag('url')) || (k.startsWith('APNS_KEY') && v);
    if (v !== undefined && (next[k] === undefined || explicit)) next[k] = v;
  }
  writeFileSync(ENV_PATH, Object.entries(next).map(([k, v]) => `${k}=${v}`).join('\n') + '\n', { mode: 0o600 });
  return next;
}

async function withApp<T>(fn: (call: (method: 'GET' | 'POST', url: string, payload?: object) => Promise<any>, adminId: string | null, app: Awaited<ReturnType<typeof buildApp>>) => Promise<T>): Promise<T> {
  process.chdir(SERVER_DIR);
  if (existsSync(ENV_PATH)) process.loadEnvFile(ENV_PATH);
  const base = loadConfig();
  const app = await buildApp({ config: { ...base, logLevel: 'silent', maintenanceIntervalMs: 0, allowRegistration: true } });
  const admin = app.ctx.db.prepare('SELECT id FROM admins ORDER BY created_at LIMIT 1').get() as { id: string } | undefined;
  const jwt = admin ? signJwt({ sub: admin.id }, base.jwtSecret, 600) : null;
  const call = async (method: 'GET' | 'POST', url: string, payload?: object) => {
    const r = await app.inject({ method, url, headers: jwt ? { authorization: `Bearer ${jwt}` } : {}, ...(payload ? { payload } : {}) });
    const json = r.body ? JSON.parse(r.body) : null;
    if (r.statusCode >= 400) throw new Error(`${method} ${url}: ${json?.error?.message ?? r.statusCode}`);
    return json;
  };
  try { return await fn(call, admin?.id ?? null, app); } finally { await app.close(); }
}

function mcpHelp(url: string | undefined, key: string): string {
  const mcp = `${url ?? 'https://<this-pc>.<tailnet>.ts.net'}/mcp`;
  return [
    `MCP endpoint : ${mcp}`,
    `API key      : ${key}   (shown once — store it in the agent's config)`,
    '',
    'Claude Code (any machine on the tailnet):',
    `  claude mcp add --transport http --scope user tether ${mcp} --header "Authorization: Bearer ${key}"`,
    'Other MCP clients: Streamable HTTP, same URL, header Authorization: Bearer <key>.',
  ].join('\n');
}

async function setup(): Promise<void> {
  const env = writeEnv();
  console.log(`Wrote ${ENV_PATH}`);
  if (!env.PUBLIC_BASE_URL) console.log('! PUBLIC_BASE_URL unknown (tailscale not found). Re-run with --url https://<pc>.<tailnet>.ts.net');
  if (!env.APNS_KEY_P8) console.log('! No APNs key yet: changes reach the phone when Tether is opened. Add later: npm run setup -- --apns-key <file.p8> --apns-key-id <id>');
  await withApp(async (_call, adminId, app) => {
    if (adminId) {
      console.log('Admin already exists — nothing else to create. Use `npm run cli -- apikey <name>` for a new agent key.');
      return;
    }
    const password = randomBytes(12).toString('base64url');
    const reg = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: ADMIN_EMAIL, password, name: 'Admin' } });
    if (reg.statusCode !== 201) throw new Error(`register failed: ${reg.body}`);
    const jwt = JSON.parse(reg.body).token as string;
    const key = await app.inject({ method: 'POST', url: '/v1/api-keys', headers: { authorization: `Bearer ${jwt}` }, payload: { name: 'claude' } });
    const code = await app.inject({ method: 'POST', url: '/v1/pairing-codes', headers: { authorization: `Bearer ${jwt}` }, payload: { deviceName: 'iPhone' } });
    console.log(`\nAdmin dashboard login: ${ADMIN_EMAIL} / ${password}  (shown once)\n`);
    console.log(mcpHelp(env.PUBLIC_BASE_URL, JSON.parse(key.body).key));
    const c = JSON.parse(code.body);
    console.log(`\nPhone pairing code: ${c.code} (expires ${c.expiresAt}; make another with: npm run cli -- pair)`);
  });
}

async function main(): Promise<void> {
  switch (cmd) {
    case 'setup': return setup();
    case 'pair': return withApp(async (call, adminId) => {
      if (!adminId) throw new Error('Run `npm run setup` first');
      const c = await call('POST', '/v1/pairing-codes', positional[0] ? { deviceName: positional[0] } : {});
      console.log(`Pairing code: ${c.code}  (expires ${c.expiresAt})\nServer URL  : ${readEnv().PUBLIC_BASE_URL ?? '?'}\nLink        : ${c.qrPayload}`);
    });
    case 'apikey': return withApp(async (call, adminId) => {
      if (!adminId) throw new Error('Run `npm run setup` first');
      const name = positional[0] ?? 'agent';
      const k = await call('POST', '/v1/api-keys', { name });
      console.log(mcpHelp(readEnv().PUBLIC_BASE_URL, k.key));
    });
    case 'info': return withApp(async (call, adminId) => {
      const env = readEnv();
      console.log(`env file : ${existsSync(ENV_PATH) ? ENV_PATH : 'missing (run npm run setup)'}`);
      console.log(`URL      : ${env.PUBLIC_BASE_URL ?? '?'}  (local http://127.0.0.1:${env.PORT ?? 8787})`);
      console.log(`APNs     : ${env.APNS_KEY_P8 ? 'configured' : 'not configured'}`);
      if (!adminId) return void console.log('admin    : none (run npm run setup)');
      const devs = (await call('GET', '/v1/devices')).devices as { name: string; status: string; lastSeenAt: string | null; hasPushToken: boolean }[];
      const keys = (await call('GET', '/v1/api-keys')).keys as { name: string; prefix: string; lastUsedAt: string | null }[] | undefined;
      console.log(`devices  : ${devs.map((d) => `${d.name} [${d.status}${d.hasPushToken ? '' : ', no push'}]`).join(', ') || 'none'}`);
      if (keys) console.log(`api keys : ${keys.map((k) => `${k.name} (${k.prefix}…)`).join(', ') || 'none'}`);
    });
    default:
      console.error('usage: cli setup|pair [name]|apikey <name>|info');
      process.exit(2);
  }
}

await main();
