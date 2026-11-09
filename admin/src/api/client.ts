import type {
  ApiKey, AuthResponse, BlockGroup, CreatedApiKey, DeviceDetail, DeviceEvent, DeviceSummary,
  ErrorCode, GroupInput, Override, OverrideInput, PairingCode, Rule, RuleInput, Settings,
  UnlockRequest, Admin,
} from './types';

export class ApiError extends Error {
  constructor(public status: number, public code: ErrorCode | string, message: string) {
    super(message);
    this.name = 'ApiError';
  }
}

const TOKEN_KEY = 'tether.admin.token';
let memoryToken: string | null = null;
let unauthorizedHandler: (() => void) | null = null;

export function getToken(): string | null {
  if (memoryToken) return memoryToken;
  try {
    memoryToken = localStorage.getItem(TOKEN_KEY);
  } catch { /* storage unavailable */ }
  return memoryToken;
}
export function setToken(token: string | null): void {
  memoryToken = token;
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch { /* ignore */ }
}
export function onUnauthorized(fn: (() => void) | null): void {
  unauthorizedHandler = fn;
}

/** Parse a failed Response into an ApiError. Handles `{error:{code,message}}` and non-JSON bodies. */
export async function parseError(res: Response): Promise<ApiError> {
  let code: string = 'internal';
  let message = `Request failed (${res.status})`;
  try {
    const text = await res.text();
    if (text) {
      const body = JSON.parse(text) as { error?: { code?: string; message?: string } };
      if (body?.error) {
        code = body.error.code ?? code;
        message = body.error.message ?? message;
      } else {
        message = text.slice(0, 200);
      }
    }
  } catch { /* non-JSON body: keep default message */ }
  return new ApiError(res.status, code, message);
}

type Method = 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE';

export async function request<T>(method: Method, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let res: Response;
  try {
    res = await fetch(`/v1${path}`, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError(0, 'network', 'Cannot reach the server. Check your connection.');
  }
  if (!res.ok) {
    const err = await parseError(res);
    if (res.status === 401 && token && unauthorizedHandler) unauthorizedHandler();
    throw err;
  }
  if (res.status === 204 || res.status === 202) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

/** Tolerant list unwrapping: accepts `{key: [...]}`, a bare array, or any single array-valued property. */
export function list<T>(body: unknown, key: string): T[] {
  if (Array.isArray(body)) return body as T[];
  if (body && typeof body === 'object') {
    const o = body as Record<string, unknown>;
    if (Array.isArray(o[key])) return o[key] as T[];
    const arr = Object.values(o).find(Array.isArray);
    if (arr) return arr as T[];
  }
  return [];
}

const q = (params: Record<string, string | number | undefined>) => {
  const s = Object.entries(params)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join('&');
  return s ? `?${s}` : '';
};

export const api = {
  register: (b: { email: string; password: string; name: string }) => request<AuthResponse>('POST', '/auth/register', b),
  login: (b: { email: string; password: string }) => request<AuthResponse>('POST', '/auth/login', b),
  me: () => request<{ admin: Admin }>('GET', '/auth/me'),

  createPairingCode: (deviceName?: string) => request<PairingCode>('POST', '/pairing-codes', deviceName ? { deviceName } : {}),
  listDevices: () => request<unknown>('GET', '/devices').then((r) => list<DeviceSummary>(r, 'devices')),
  getDevice: (id: string) => request<DeviceDetail>('GET', `/devices/${id}`),
  renameDevice: (id: string, name: string) => request<DeviceSummary>('PATCH', `/devices/${id}`, { name }),
  unpairDevice: (id: string) => request<void>('DELETE', `/devices/${id}`),
  pushDevice: (id: string) => request<void>('POST', `/devices/${id}/push`),
  deviceEvents: (id: string, limit = 50) =>
    request<unknown>('GET', `/devices/${id}/events${q({ limit })}`).then((r) => list<DeviceEvent>(r, 'events')),

  listGroups: () => request<unknown>('GET', '/groups').then((r) => list<BlockGroup>(r, 'groups')),
  createGroup: (b: GroupInput) => request<BlockGroup>('POST', '/groups', b),
  updateGroup: (id: string, b: Partial<GroupInput>) => request<BlockGroup>('PATCH', `/groups/${id}`, b),
  deleteGroup: (id: string) => request<void>('DELETE', `/groups/${id}`),

  listRules: () => request<unknown>('GET', '/rules').then((r) => list<Rule>(r, 'rules')),
  createRule: (b: RuleInput) => request<Rule>('POST', '/rules', b),
  updateRule: (id: string, b: Partial<RuleInput>) => request<Rule>('PATCH', `/rules/${id}`, b),
  deleteRule: (id: string) => request<void>('DELETE', `/rules/${id}`),
  toggleRule: (id: string, active: boolean) => request<Rule>('POST', `/rules/${id}/toggle`, { active }),

  listOverrides: () => request<unknown>('GET', '/overrides').then((r) => list<Override>(r, 'overrides')),
  createOverride: (b: OverrideInput) => request<Override>('POST', '/overrides', b),
  cancelOverride: (id: string) => request<void>('DELETE', `/overrides/${id}`),

  getSettings: () => request<Settings>('GET', '/settings'),
  updateSettings: (b: Partial<Settings>) => request<Settings>('PATCH', '/settings', b),

  listUnlockRequests: (status?: string) =>
    request<unknown>('GET', `/unlock-requests${q({ status })}`).then((r) => list<UnlockRequest>(r, 'requests')),
  approveUnlock: (id: string, minutes?: number) =>
    request<UnlockRequest>('POST', `/unlock-requests/${id}/approve`, minutes ? { minutes } : {}),
  denyUnlock: (id: string, note?: string) =>
    request<UnlockRequest>('POST', `/unlock-requests/${id}/deny`, note ? { note } : {}),

  listApiKeys: () => request<unknown>('GET', '/api-keys').then((r) => list<ApiKey>(r, 'keys')),
  createApiKey: (name: string) => request<CreatedApiKey>('POST', '/api-keys', { name }),
  deleteApiKey: (id: string) => request<void>('DELETE', `/api-keys/${id}`),
};
