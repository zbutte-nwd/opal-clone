# Build from the repository root so the optional admin dashboard can be included:
#   docker build -f server/Dockerfile -t tether .
# If admin/dist exists (cd admin && npm run build) it is copied in and served at /.
FROM node:22-bookworm-slim AS build
WORKDIR /app/server
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY server/package*.json ./
RUN npm ci
COPY server/tsconfig*.json ./
COPY server/src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim
ENV NODE_ENV=production PORT=8787 DATABASE_PATH=/data/tether.db
WORKDIR /app/server
COPY --from=build /app/server/node_modules ./node_modules
COPY --from=build /app/server/dist ./dist
COPY server/package.json server/openapi.yaml ./
COPY contracts /app/contracts
# Optional: pre-built admin dashboard (glob keeps the build working when absent)
COPY admin/dis[t] /app/admin/dist
VOLUME /data
EXPOSE 8787
CMD ["node", "dist/index.js"]
