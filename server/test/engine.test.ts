import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { evaluate } from '../src/engine/index.js';

const data = JSON.parse(readFileSync(new URL('../../contracts/engine-vectors.json', import.meta.url), 'utf8'));

describe('engine vectors', () => {
  it('has 61 vectors', () => expect(data.vectors.length).toBe(61));
  for (const v of data.vectors) {
    it(v.name, () => {
      expect(evaluate(v.input, new Date(v.now), v.deviceTimeZone)).toEqual(v.expect);
    });
  }
});
