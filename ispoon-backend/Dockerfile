# Build context is THIS directory (ispoon-backend), not the repo root.
# The repo is a monorepo and the other three components are irrelevant here.
#
#   docker build -t ispoon-backend .
#
# Debian ("slim"), deliberately NOT Alpine. sharp 0.35 ships prebuilt libvips
# binaries compiled against glibc; Alpine is musl, so on Alpine the install
# either fails or silently falls back to a slow source build. This is the one
# base-image decision that actually matters for this service.
FROM node:22-slim AS deps

WORKDIR /app

# Copy only the manifests first. Docker caches each layer, so dependencies are
# re-installed only when these two files change — not on every source edit.
COPY package.json package-lock.json ./

# `npm ci` installs exactly what the lockfile says, which is what you want in a
# build. `--omit=dev` leaves out test tooling: it is not needed to serve the API
# and it is the bulk of the install.
RUN npm ci --omit=dev


FROM node:22-slim AS runtime

# Tells the app (and anything reading NODE_ENV) that this is production.
# validateSecurityConfig() refuses to start if this is not one of
# development | test | production.
ENV NODE_ENV=production

# Inside a container, 127.0.0.1 means "only this container", so a server bound
# to it is unreachable even with the port published. It MUST be 0.0.0.0.
#
# That in turn trips assertSafeListenConfig(), which refuses a wildcard bind
# while DATABASE_URL points at Neon — a guard against turning a laptop into a
# public database listener. In a real deployment that refusal is not what you
# want, so ALLOW_LAN_BIND acknowledges it explicitly.
ENV BIND_HOST=0.0.0.0
ENV ALLOW_LAN_BIND=1

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY src ./src

# Avatars and meal photos are written to ./uploads on local disk. A container
# filesystem is thrown away on every restart, so this MUST be mounted as a
# volume or moved to object storage, or uploads vanish on each deploy.
RUN mkdir -p uploads/avatars uploads/meal-photos \
 && chown -R node:node /app

# The base image ships an unprivileged `node` user. Running as root inside a
# container is a needless escalation if the process is ever compromised.
USER node

# Documentation only — it publishes nothing by itself. The app reads PORT from
# the environment and most platforms inject their own.
EXPOSE 5000

# Liveness, not readiness: /api/health/ready also probes Postgres, so a brief
# database blip would make Docker kill a perfectly healthy container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||5000)+'/api/health/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Migrations are deliberately NOT run here. An image can start several
# containers at once, and they would race each other. Run them as a one-off
# before the new version goes live:
#
#   docker run --rm --env-file .env ispoon-backend npm run migrate
CMD ["node", "src/server.js"]
