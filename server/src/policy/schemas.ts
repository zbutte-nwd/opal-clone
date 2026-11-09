import { z } from 'zod';

// Zod mirror of contracts/policy-bundle.schema.json (input side) plus the extra server-side validation rules.

export const HHMM = /^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$/;
export const DOMAIN = /^[a-z0-9.-]+\.[a-z]{2,}$/;
export const COLOR = /^#[0-9A-Fa-f]{6}$/;

const isoWeekday = z.number().int().min(1).max(7);
const days = z.array(isoWeekday).min(1).refine((d) => new Set(d).size === d.length, 'days must be unique');
const hhmm = z.string().regex(HHMM, 'must be HH:mm (00:00-23:59) or 24:00');

export const WindowSchema = z
  .object({ days, start: hhmm, end: hhmm })
  .strict()
  .superRefine((w, ctx) => {
    if (w.start === w.end) ctx.addIssue({ code: 'custom', message: 'window start and end must differ', path: ['end'] });
    if (w.start === '24:00') ctx.addIssue({ code: 'custom', message: 'window start cannot be 24:00', path: ['start'] });
  });

export const TriggerSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('schedule'), windows: z.array(WindowSchema).min(1) }).strict(),
  z.object({ type: z.literal('usageLimit'), dailyMinutes: z.number().int().min(1).max(1440), days }).strict(),
  z.object({ type: z.literal('manual'), active: z.boolean() }).strict(),
]);

export const GroupInputSchema = z.object({
  name: z.string().trim().min(1).max(60),
  colorHex: z.string().regex(COLOR, 'must be #RRGGBB').nullish(),
  webDomains: z
    .array(z.string().regex(DOMAIN, 'must be a lowercase domain like example.com'))
    .max(50, 'at most 50 domains')
    .default([]),
});
export type GroupInput = z.infer<typeof GroupInputSchema>;

export const RuleInputSchema = z.object({
  name: z.string().trim().min(1).max(60),
  groupIds: z.array(z.string().min(1).max(64)).min(1),
  enabled: z.boolean().default(true),
  action: z.enum(['block', 'allow']),
  trigger: TriggerSchema,
  strictness: z.enum(['flexible', 'strict']).default('flexible'),
  priority: z.number().int().min(-1000).max(1000).default(0),
  maxPausesPerDay: z.number().int().min(0).nullish(),
});
export type RuleInput = z.infer<typeof RuleInputSchema>;

export const SettingsPatchSchema = z.object({
  protectionLock: z.enum(['partnerPIN', 'remoteApproval', 'osOnly']).optional(),
  allowLocalRules: z.boolean().optional(),
  denyAppRemoval: z.boolean().optional(),
  timeZone: z.string().min(1).max(64).nullish(),
});

const rfc3339 = z
  .string()
  .refine((s) => /^\d{4}-\d{2}-\d{2}T/.test(s) && !Number.isNaN(Date.parse(s)), 'must be an RFC 3339 timestamp');

export const OverrideInputSchema = z.object({
  groupIds: z.array(z.string().min(1).max(64)).min(1),
  action: z.enum(['block', 'unblock']),
  startsAt: rfc3339.optional(),
  endsAt: rfc3339.nullish(),
  durationMinutes: z.number().int().min(1).max(60 * 24 * 365).optional(),
  reason: z.string().max(200).nullish(),
  deviceIds: z.array(z.string().min(1).max(64)).min(1).nullish(),
});
export type OverrideInput = z.infer<typeof OverrideInputSchema>;

export const ActionInputSchema = z.object({
  groupIds: z.array(z.string().min(1).max(64)).min(1),
  durationMinutes: z.number().int().min(1).max(60 * 24 * 365).optional(),
  reason: z.string().max(200).nullish(),
  deviceIds: z.array(z.string().min(1).max(64)).min(1).nullish(),
});
