// Verifies every Fastify route is documented in openapi.yaml (and vice versa).
import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { buildApp } from '../src/app.js';
import { testConfig } from '../src/config.js';

const doc = parse(readFileSync(new URL('../openapi.yaml', import.meta.url), 'utf8')) as {
  openapi: string; paths: Record<string, Record<string, unknown>>;
};
if (!doc.openapi?.startsWith('3.1')) throw new Error('openapi.yaml must be OpenAPI 3.1');

const app = await buildApp({ config: testConfig({ databasePath: ':memory:' }) });
await app.ready();
const METHODS = new Set(['get', 'post', 'put', 'patch', 'delete']);
const routes = new Set(
  app.routeList
    .filter((r) => r.url === '/healthz' || r.url.startsWith('/v1/'))
    .map((r) => `${r.method.toLowerCase()} ${r.url.replace(/:([A-Za-z_]+)/g, '{$1}').replace(/\{[A-Za-z_]+\}/g, '{id}')}`),
);
const documented = new Set<string>();
for (const [path, item] of Object.entries(doc.paths))
  for (const m of Object.keys(item)) if (METHODS.has(m)) documented.add(`${m} ${path.replace(/\{[A-Za-z_]+\}/g, '{id}')}`);

const missing = [...routes].filter((r) => !documented.has(r));
const extra = [...documented].filter((r) => !routes.has(r));
await app.close();
if (missing.length || extra.length) {
  if (missing.length) console.error('Routes missing from openapi.yaml:\n  ' + missing.join('\n  '));
  if (extra.length) console.error('Documented but not implemented:\n  ' + extra.join('\n  '));
  process.exit(1);
}
console.log(`openapi.yaml OK: ${routes.size} routes documented`);
