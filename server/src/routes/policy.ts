import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../context.js';
import { adminAuth } from '../auth/plugin.js';
import { invalid, notFound, parse } from '../errors.js';
import { assertGroupsExist, createOverride } from '../policy/overrides.js';
import {
  ActionInputSchema, GroupInputSchema, OverrideInputSchema, RuleInputSchema, SettingsPatchSchema,
  type GroupInput, type RuleInput,
} from '../policy/schemas.js';
import {
  audit, bumpPolicy, groupOut, overrideAdminOut, pruneOverrides, ruleOut, settingsOut,
} from '../policy/service.js';
import { iso, isValidTimeZone, newId, parseJson } from '../util.js';

const obj = (b: unknown): Record<string, unknown> => (b && typeof b === 'object' && !Array.isArray(b) ? (b as Record<string, unknown>) : {});

export function policyRoutes(ctx: Ctx) {
  const { db } = ctx;
  const actor = (req: { admin?: { id: string; via: string; keyId?: string } }) =>
    req.admin!.via === 'apikey' ? `apikey:${req.admin!.keyId}` : req.admin!.id;

  return async (app: FastifyInstance) => {
    app.addHook('preHandler', adminAuth(ctx));

    // ---------------- groups ----------------
    const getGroup = (a: string, id: string) => {
      const r = db.prepare('SELECT * FROM groups WHERE id = ? AND admin_id = ?').get(id, a) as Parameters<typeof groupOut>[0] | undefined;
      if (!r) throw notFound('Group not found');
      return r;
    };
    const groupJson = (r: Parameters<typeof groupOut>[0]) => ({
      ...groupOut(r), colorHex: r.color_hex, createdAt: r.created_at, updatedAt: r.updated_at,
    });

    app.get('/groups', async (req) => ({
      groups: (db.prepare('SELECT * FROM groups WHERE admin_id = ? ORDER BY created_at, id').all(req.admin!.id) as Parameters<typeof groupOut>[0][]).map(groupJson),
    }));

    app.post('/groups', async (req, reply) => {
      const a = req.admin!.id;
      const b = parse(GroupInputSchema, req.body);
      // One server copy per phone group: a repeat (e.g. parallel agent calls) gets the existing copy back.
      if (b.copiedFrom) {
        const ex = db.prepare('SELECT * FROM groups WHERE admin_id = ? AND copied_from = ? ORDER BY created_at, id LIMIT 1').get(a, b.copiedFrom) as
          | Parameters<typeof groupOut>[0] | undefined;
        if (ex) return reply.code(200).send(groupJson(ex));
      }
      const id = newId('grp');
      const now = iso(ctx.now());
      db.transaction(() => {
        db.prepare('INSERT INTO groups (id, admin_id, name, color_hex, web_domains, copied_from, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)')
          .run(id, a, b.name, b.colorHex ?? null, JSON.stringify(b.webDomains), b.copiedFrom ?? null, now, now);
        audit(ctx, a, actor(req), 'group.create', id, { name: b.name });
        bumpPolicy(ctx, a);
      })();
      return reply.code(201).send(groupJson(getGroup(a, id)));
    });

    app.patch<{ Params: { id: string } }>('/groups/:id', async (req) => {
      const a = req.admin!.id;
      const cur = getGroup(a, req.params.id);
      const existing: GroupInput = { name: cur.name, colorHex: cur.color_hex, webDomains: parseJson<string[]>(cur.web_domains, []), copiedFrom: cur.copied_from };
      const b = parse(GroupInputSchema, { ...existing, ...obj(req.body) });
      db.transaction(() => {
        db.prepare('UPDATE groups SET name = ?, color_hex = ?, web_domains = ?, copied_from = ?, updated_at = ? WHERE id = ? AND admin_id = ?')
          .run(b.name, b.colorHex ?? null, JSON.stringify(b.webDomains), b.copiedFrom ?? null, iso(ctx.now()), cur.id, a);
        audit(ctx, a, actor(req), 'group.update', cur.id);
        bumpPolicy(ctx, a);
      })();
      return groupJson(getGroup(a, cur.id));
    });

    app.delete<{ Params: { id: string } }>('/groups/:id', async (req, reply) => {
      const a = req.admin!.id;
      const g = getGroup(a, req.params.id);
      db.transaction(() => {
        // Strip the group from rules/overrides; drop those left with no groups.
        for (const r of db.prepare('SELECT id, group_ids FROM rules WHERE admin_id = ?').all(a) as { id: string; group_ids: string }[]) {
          const ids = parseJson<string[]>(r.group_ids, []);
          if (!ids.includes(g.id)) continue;
          const left = ids.filter((x) => x !== g.id);
          if (left.length) db.prepare('UPDATE rules SET group_ids = ?, updated_at = ? WHERE id = ?').run(JSON.stringify(left), iso(ctx.now()), r.id);
          else db.prepare('DELETE FROM rules WHERE id = ?').run(r.id);
        }
        for (const o of db.prepare('SELECT id, group_ids FROM overrides WHERE admin_id = ?').all(a) as { id: string; group_ids: string }[]) {
          const ids = parseJson<string[]>(o.group_ids, []);
          if (!ids.includes(g.id)) continue;
          const left = ids.filter((x) => x !== g.id);
          if (left.length) db.prepare('UPDATE overrides SET group_ids = ? WHERE id = ?').run(JSON.stringify(left), o.id);
          else db.prepare('DELETE FROM overrides WHERE id = ?').run(o.id);
        }
        db.prepare('DELETE FROM groups WHERE id = ? AND admin_id = ?').run(g.id, a);
        audit(ctx, a, actor(req), 'group.delete', g.id, { name: g.name });
        bumpPolicy(ctx, a);
      })();
      return reply.code(204).send();
    });

    // ---------------- rules ----------------
    type RuleRow = Parameters<typeof ruleOut>[0] & { created_at: string };
    const getRule = (a: string, id: string): RuleRow => {
      const r = db.prepare('SELECT * FROM rules WHERE id = ? AND admin_id = ?').get(id, a) as RuleRow | undefined;
      if (!r) throw notFound('Rule not found');
      return r;
    };
    const writeRule = (a: string, id: string, b: RuleInput, create: boolean) => {
      assertGroupsExist(ctx, a, b.groupIds);
      const now = iso(ctx.now());
      const vals = [b.name, JSON.stringify([...new Set(b.groupIds)]), b.enabled ? 1 : 0, b.action, JSON.stringify(b.trigger), b.strictness, b.priority, b.maxPausesPerDay ?? null];
      if (create) {
        db.prepare('INSERT INTO rules (name, group_ids, enabled, action, trigger, strictness, priority, max_pauses_per_day, id, admin_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)')
          .run(...vals, id, a, now, now);
      } else {
        db.prepare('UPDATE rules SET name=?, group_ids=?, enabled=?, action=?, trigger=?, strictness=?, priority=?, max_pauses_per_day=?, updated_at=? WHERE id=? AND admin_id=?')
          .run(...vals, now, id, a);
      }
    };

    app.get('/rules', async (req) => ({
      rules: (db.prepare('SELECT * FROM rules WHERE admin_id = ? ORDER BY created_at, id').all(req.admin!.id) as RuleRow[]).map(ruleOut),
    }));

    app.post('/rules', async (req, reply) => {
      const a = req.admin!.id;
      const b = parse(RuleInputSchema, req.body);
      const id = newId('rule');
      db.transaction(() => {
        writeRule(a, id, b, true);
        audit(ctx, a, actor(req), 'rule.create', id, { name: b.name });
        bumpPolicy(ctx, a);
      })();
      return reply.code(201).send(ruleOut(getRule(a, id)));
    });

    app.patch<{ Params: { id: string } }>('/rules/:id', async (req) => {
      const a = req.admin!.id;
      const cur = ruleOut(getRule(a, req.params.id));
      const existing = {
        name: cur.name, groupIds: cur.groupIds, enabled: cur.enabled, action: cur.action, trigger: cur.trigger,
        strictness: cur.strictness, priority: cur.priority, maxPausesPerDay: cur.maxPausesPerDay ?? null,
      };
      const b = parse(RuleInputSchema, { ...existing, ...obj(req.body) });
      db.transaction(() => {
        writeRule(a, cur.id, b, false);
        audit(ctx, a, actor(req), 'rule.update', cur.id);
        bumpPolicy(ctx, a);
      })();
      return ruleOut(getRule(a, cur.id));
    });

    app.delete<{ Params: { id: string } }>('/rules/:id', async (req, reply) => {
      const a = req.admin!.id;
      const r = getRule(a, req.params.id);
      db.transaction(() => {
        db.prepare('DELETE FROM rules WHERE id = ? AND admin_id = ?').run(r.id, a);
        audit(ctx, a, actor(req), 'rule.delete', r.id, { name: r.name });
        bumpPolicy(ctx, a);
      })();
      return reply.code(204).send();
    });

    app.post<{ Params: { id: string } }>('/rules/:id/toggle', async (req) => {
      const a = req.admin!.id;
      const cur = ruleOut(getRule(a, req.params.id));
      const body = obj(req.body);
      if (typeof body.active !== 'boolean') throw invalid('active: must be a boolean');
      if (cur.trigger.type !== 'manual') throw invalid('Only rules with a manual trigger can be toggled');
      db.transaction(() => {
        db.prepare('UPDATE rules SET trigger = ?, updated_at = ? WHERE id = ? AND admin_id = ?')
          .run(JSON.stringify({ type: 'manual', active: body.active }), iso(ctx.now()), cur.id, a);
        audit(ctx, a, actor(req), 'rule.toggle', cur.id, { active: body.active });
        bumpPolicy(ctx, a);
      })();
      return ruleOut(getRule(a, cur.id));
    });

    // ---------------- overrides & actions ----------------
    app.get<{ Querystring: { active?: string } }>('/overrides', async (req) => {
      const a = req.admin!.id;
      pruneOverrides(ctx, a);
      const nowIso = iso(ctx.now());
      const rows = db.prepare('SELECT * FROM overrides WHERE admin_id = ? ORDER BY issued_at DESC, id').all(a) as Parameters<typeof overrideAdminOut>[0][];
      const list = req.query.active === 'true' ? rows.filter((r) => !r.ends_at || r.ends_at > nowIso) : rows;
      return { overrides: list.map(overrideAdminOut) };
    });

    app.post('/overrides', async (req, reply) =>
      reply.code(201).send(createOverride(ctx, req.admin!.id, actor(req), parse(OverrideInputSchema, req.body))));

    app.delete<{ Params: { id: string } }>('/overrides/:id', async (req, reply) => {
      const a = req.admin!.id;
      const o = db.prepare('SELECT * FROM overrides WHERE id = ? AND admin_id = ?').get(req.params.id, a) as
        | { id: string; device_ids: string | null } | undefined;
      if (!o) throw notFound('Override not found');
      db.transaction(() => {
        db.prepare('DELETE FROM overrides WHERE id = ?').run(o.id);
        audit(ctx, a, actor(req), 'override.cancel', o.id);
        bumpPolicy(ctx, a, parseJson<string[] | null>(o.device_ids, null));
      })();
      return reply.code(204).send();
    });

    for (const action of ['block', 'unblock'] as const) {
      app.post(`/actions/${action}`, async (req, reply) => {
        const b = parse(ActionInputSchema, req.body);
        const o = createOverride(ctx, req.admin!.id, actor(req), {
          ...b, action, reason: b.reason ?? `API ${action}`,
        });
        return reply.code(201).send(o);
      });
    }

    // ---------------- settings ----------------
    app.get('/settings', async (req) => settingsOut(ctx, req.admin!.id));
    app.patch('/settings', async (req) => {
      const a = req.admin!.id;
      const b = parse(SettingsPatchSchema, req.body);
      if (b.timeZone && !isValidTimeZone(b.timeZone)) throw invalid('timeZone: not a valid IANA time zone');
      const cur = settingsOut(ctx, a);
      const next = {
        protectionLock: b.protectionLock ?? cur.protectionLock,
        allowLocalRules: b.allowLocalRules ?? cur.allowLocalRules,
        denyAppRemoval: b.denyAppRemoval ?? cur.denyAppRemoval,
        timeZone: b.timeZone === undefined ? cur.timeZone : b.timeZone,
      };
      db.transaction(() => {
        db.prepare('UPDATE settings SET protection_lock=?, allow_local_rules=?, deny_app_removal=?, time_zone=? WHERE admin_id=?')
          .run(next.protectionLock, next.allowLocalRules ? 1 : 0, next.denyAppRemoval ? 1 : 0, next.timeZone, a);
        audit(ctx, a, actor(req), 'settings.update', null, b);
        bumpPolicy(ctx, a);
      })();
      return settingsOut(ctx, a);
    });
  };
}
