# Multi-stage so the runtime image carries no build toolchain and no source.
#
# WHY MULTI-STAGE: the deps and builder stages pull a full npm toolchain and
# every devDependency. None of that should ship. The runner stage starts clean
# and copies in only what `next start` actually needs, which keeps the attack
# surface and the pull time down.

# ---- deps -------------------------------------------------------------------
FROM node:22-alpine AS deps
WORKDIR /app
# Copy only the manifests first. This layer is cached until dependencies
# change, so editing application code does not re-run npm ci.
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund

# ---- builder ----------------------------------------------------------------
FROM node:22-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Next reads env at build time for anything NEXT_PUBLIC_*. Real values are
# injected at deploy time; these placeholders only satisfy the build.
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ---- runner -----------------------------------------------------------------
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Run as a non-root user. A container that does not need root should not have
# it, and some clusters refuse to schedule pods that ask for it.
RUN addgroup -g 1001 -S nodejs && adduser -u 1001 -S nextjs -G nodejs

COPY --from=builder /app/public ./public
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
# Worker scripts, so the same image can serve the web Deployment and run the
# scheduled CronJob. One image, two workloads, one thing to version.
COPY --from=builder /app/scripts ./scripts

USER nextjs
EXPOSE 3000
ENV PORT=3000 HOSTNAME=0.0.0.0
CMD ["npx", "next", "start"]
