import { createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual } from 'node:crypto';

const scrypt = (pw: string, salt: Buffer, len: number, opts: { N: number; r: number; p: number }) =>
  new Promise<Buffer>((res, rej) => scryptCb(pw, salt, len, opts, (e, k) => (e ? rej(e) : res(k))));

const N = 16384, R = 8, P = 1;

export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(pw, salt, 64, { N, r: R, p: P });
  return `scrypt$${N}$${R}$${P}$${salt.toString('base64')}$${key.toString('base64')}`;
}

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, n, r, p, salt, hash] = stored.split('$');
  if (alg !== 'scrypt' || !salt || !hash) return false;
  const expected = Buffer.from(hash, 'base64');
  const key = await scrypt(pw, Buffer.from(salt, 'base64'), expected.length, { N: Number(n), r: Number(r), p: Number(p) });
  return key.length === expected.length && timingSafeEqual(key, expected);
}

const b64u = (b: Buffer | string) => Buffer.from(b).toString('base64url');

export function signJwt(claims: Record<string, unknown>, secret: string, ttlSeconds: number, nowMs = Date.now()): string {
  const iat = Math.floor(nowMs / 1000);
  const head = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64u(JSON.stringify({ ...claims, iat, exp: iat + ttlSeconds }));
  const sig = createHmac('sha256', secret).update(`${head}.${body}`).digest();
  return `${head}.${body}.${b64u(sig)}`;
}

export function verifyJwt(token: string, secret: string, nowMs = Date.now()): Record<string, unknown> | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [h, b, s] = parts as [string, string, string];
  try {
    const head = JSON.parse(Buffer.from(h, 'base64url').toString());
    if (head.alg !== 'HS256') return null;
    const expected = createHmac('sha256', secret).update(`${h}.${b}`).digest();
    const got = Buffer.from(s, 'base64url');
    if (got.length !== expected.length || !timingSafeEqual(got, expected)) return null;
    const claims = JSON.parse(Buffer.from(b, 'base64url').toString());
    if (typeof claims.exp !== 'number' || claims.exp * 1000 <= nowMs) return null;
    return claims;
  } catch {
    return null;
  }
}
