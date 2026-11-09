import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

export const VERSION = '0.1.0';

export interface Config {
  port: number;
  host: string;
  databasePath: string;
  jwtSecret: string;
  jwtTtlSeconds: number;
  publicBaseUrl: string | null;
  apns: { keyP8: string; keyId: string; teamId: string; topic: string } | null;
  apnsEnv: 'sandbox' | 'production';
  adminDist: string | null;
  trustProxy: boolean;
  allowRegistration: boolean;
  logLevel: string;
  pushDebounceMs: number;
  maintenanceIntervalMs: number;
  rateLimit: { windowMs: number; authMax: number; enrollMax: number; pairingMax: number };
}

const here = dirname(fileURLToPath(import.meta.url));

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const prod = env.NODE_ENV === 'production';
  let jwtSecret = env.JWT_SECRET;
  if (!jwtSecret) {
    if (prod) throw new Error('JWT_SECRET is required in production');
    jwtSecret = 'dev-insecure-jwt-secret-change-me';
  }
  const apns =
    env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC
      ? { keyP8: env.APNS_KEY_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC }
      : null;
  const defaultDist = resolve(here, '../../admin/dist');
  const distCandidate = env.ADMIN_DIST ? resolve(env.ADMIN_DIST) : defaultDist;
  return {
    port: Number(env.PORT ?? 8787),
    host: env.HOST ?? '0.0.0.0',
    databasePath: env.DATABASE_PATH ?? './data/tether.db',
    jwtSecret,
    jwtTtlSeconds: 7 * 24 * 3600,
    publicBaseUrl: env.PUBLIC_BASE_URL ? env.PUBLIC_BASE_URL.replace(/\/+$/, '') : null,
    apns,
    apnsEnv: env.APNS_ENV === 'production' ? 'production' : 'sandbox',
    adminDist: existsSync(resolve(distCandidate, 'index.html')) ? distCandidate : null,
    trustProxy: env.TRUST_PROXY === 'true' || env.TRUST_PROXY === '1',
    allowRegistration: env.ALLOW_REGISTRATION !== 'false',
    logLevel: env.LOG_LEVEL ?? 'info',
    pushDebounceMs: 500,
    maintenanceIntervalMs: 5 * 60 * 1000,
    rateLimit: { windowMs: 60_000, authMax: 10, enrollMax: 10, pairingMax: 30 },
  };
}

export function testConfig(over: Partial<Config> = {}): Config {
  return {
    ...loadConfig({ JWT_SECRET: 'test-secret-' + randomBytes(4).toString('hex') }),
    adminDist: null,
    apns: null,
    logLevel: 'silent',
    pushDebounceMs: 60_000,
    maintenanceIntervalMs: 0,
    rateLimit: { windowMs: 60_000, authMax: 10_000, enrollMax: 10_000, pairingMax: 10_000 },
    publicBaseUrl: 'https://tether.test',
    ...over,
  };
}
