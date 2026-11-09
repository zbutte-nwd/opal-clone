import type { ZodType } from 'zod';

export type ErrorCode =
  | 'bad_request' | 'unauthorized' | 'forbidden' | 'not_found'
  | 'conflict' | 'validation_failed' | 'rate_limited' | 'internal';

export class ApiError extends Error {
  constructor(public status: number, public code: ErrorCode, message: string) {
    super(message);
  }
}
export const badRequest = (m: string) => new ApiError(400, 'bad_request', m);
export const unauthorized = (m = 'Authentication required') => new ApiError(401, 'unauthorized', m);
export const forbidden = (m = 'Not allowed') => new ApiError(403, 'forbidden', m);
export const notFound = (m = 'Not found') => new ApiError(404, 'not_found', m);
export const conflict = (m: string) => new ApiError(409, 'conflict', m);
export const invalid = (m: string) => new ApiError(422, 'validation_failed', m);

export function parse<T>(schema: ZodType<T>, body: unknown): T {
  const r = schema.safeParse(body ?? {});
  if (!r.success) {
    const msg = r.error.issues
      .map((i) => (i.path.length ? `${i.path.join('.')}: ${i.message}` : i.message))
      .join('; ');
    throw invalid(msg || 'Invalid request');
  }
  return r.data;
}
