# Tether admin dashboard

React 18 + Vite + TypeScript (strict), React Router, TanStack Query, plain CSS (light/dark).
Talks to the REST API in `contracts/api.md` under `/v1`.

## Develop
```
cd admin
npm install
npm run dev        # http://localhost:5173, proxies /v1 -> http://localhost:8787
npm test           # vitest + testing-library
npm run build      # tsc --noEmit && vite build -> admin/dist
```
Start the server (`cd server && npm run dev`, port 8787) first, then register an account on the login page.

## Production
`npm run build` writes `admin/dist`. The server serves that directory at `/` when it exists
(single deploy, same origin, so no CORS and no base URL config). The API is always called at relative `/v1`.

## Layout
- `src/api/types.ts` – types mirroring the contract; `src/api/client.ts` – typed fetch wrapper
  (bearer JWT in memory + localStorage, `{error:{code,message}}` parsing, 401 -> logout).
- `src/lib/schedule.ts` – rule/window formatting and validation (ISO weekdays, 24:00); `time.ts` – relative times and countdowns; `domains.ts`.
- `src/pages/*` – one file per page; `src/components/*` – layout, toasts, shared UI.
- Devices auto-refresh every 15 s.

## Notes
- Groups hold only a name, colour and web domains. Apps are picked on each phone (Apple privacy rule), and the UI says so.
- List endpoints are unwrapped tolerantly (`{devices:[…]}` or a bare array).
