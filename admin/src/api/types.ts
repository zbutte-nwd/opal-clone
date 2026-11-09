// TypeScript mirror of contracts/api.md and contracts/policy-bundle.schema.json.

export type IsoWeekday = 1 | 2 | 3 | 4 | 5 | 6 | 7;
export type Source = 'server' | 'local';

export interface Admin {
  id: string;
  email: string;
  name: string;
}
export interface AuthResponse {
  admin: Admin;
  token: string;
}

export interface BlockGroup {
  id: string;
  name: string;
  colorHex?: string | null;
  webDomains: string[];
  source?: Source;
}
export interface GroupInput {
  name: string;
  colorHex?: string | null;
  webDomains: string[];
}

export interface Window {
  days: IsoWeekday[];
  start: string; // HH:mm or 24:00
  end: string;
}
export type Trigger =
  | { type: 'schedule'; windows: Window[] }
  | { type: 'usageLimit'; dailyMinutes: number; days: IsoWeekday[] }
  | { type: 'manual'; active: boolean };

export type RuleAction = 'block' | 'allow';
export type Strictness = 'flexible' | 'strict';

export interface Rule {
  id: string;
  name: string;
  groupIds: string[];
  enabled: boolean;
  action: RuleAction;
  trigger: Trigger;
  strictness: Strictness;
  priority?: number;
  maxPausesPerDay?: number | null;
  source?: Source;
}
export type RuleInput = Omit<Rule, 'id' | 'source'>;

export type OverrideAction = 'block' | 'unblock';
export interface Override {
  id: string;
  groupIds: string[];
  action: OverrideAction;
  startsAt: string;
  endsAt?: string | null;
  issuedAt: string;
  reason?: string | null;
  deviceIds?: string[] | null; // assumption: server echoes targeting; null/absent = all devices
}
export interface OverrideInput {
  groupIds: string[];
  action: OverrideAction;
  startsAt?: string;
  endsAt?: string;
  durationMinutes?: number;
  reason?: string;
  deviceIds?: string[];
}

export type ProtectionLock = 'partnerPIN' | 'remoteApproval' | 'osOnly';
export interface Settings {
  protectionLock: ProtectionLock;
  allowLocalRules: boolean;
  denyAppRemoval: boolean;
  timeZone?: string | null;
}

export type DeviceStatus = 'online' | 'idle' | 'stale' | 'revoked' | 'pending';
export type AuthorizationStatus = 'approved' | 'denied' | 'notDetermined';

export interface GroupState {
  groupId: string;
  blocked: boolean;
  reason: { kind: 'override' | 'session' | 'rule' | 'pause' | 'none'; id?: string | null };
  strict: boolean;
  until?: string | null;
}

export interface DeviceSummary {
  id: string;
  name: string;
  model?: string | null;
  osVersion?: string | null;
  appVersion?: string | null;
  status: DeviceStatus;
  lastSeenAt?: string | null;
  appliedVersion?: number | null;
  latestVersion: number;
  authorizationStatus?: AuthorizationStatus | null;
  currentState?: GroupState[];
  blockedGroupIds?: string[]; // as reported by device ack (assumption: present on summary and/or detail)
}
export interface DeviceDetail extends DeviceSummary {
  pairedAt?: string | null;
  reportedBlockedGroupIds?: string[];
}

export interface DeviceEvent {
  id: string;
  type: string;
  occurredAt: string;
  data?: Record<string, unknown> | null;
}

export interface PairingCode {
  code: string;
  expiresAt: string;
  qrPayload: string;
}

export type UnlockKind = 'groups' | 'disableProtection';
export type UnlockStatus = 'pending' | 'approved' | 'denied' | 'expired';
export interface UnlockRequest {
  id: string;
  deviceId: string;
  kind: UnlockKind;
  groupIds: string[];
  minutes?: number | null;
  reason?: string | null;
  status: UnlockStatus;
  createdAt: string;
  decidedAt?: string | null;
  overrideId?: string | null;
  note?: string | null;
}

export interface ApiKey {
  id: string;
  name: string;
  createdAt?: string;
  lastUsedAt?: string | null;
  prefix?: string; // assumption: server may return a display prefix
}
export interface CreatedApiKey {
  id: string;
  name: string;
  key: string;
}

export type ErrorCode =
  | 'bad_request' | 'unauthorized' | 'forbidden' | 'not_found'
  | 'conflict' | 'validation_failed' | 'rate_limited' | 'internal' | 'network';
