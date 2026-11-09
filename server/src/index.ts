import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { buildApp } from './app.js';
import { loadConfig } from './config.js';

// server/.env (written by `npm run setup` on a workstation); real env vars win. Absent on Fly/Docker.
const envFile = fileURLToPath(new URL('../.env', import.meta.url));
if (existsSync(envFile)) process.loadEnvFile(envFile);
const config = loadConfig();
const app = await buildApp({ config });
if (!config.apns) app.log.warn('APNs not configured: using logging mock push transport');
if (config.adminDist) app.log.info({ adminDist: config.adminDist }, 'serving admin dashboard');
for (const sig of ['SIGINT', 'SIGTERM'] as const) process.on(sig, () => void app.close().then(() => process.exit(0)));
await app.listen({ port: config.port, host: config.host });
