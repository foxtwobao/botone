# A release artifact for the trusted Linux host service, not a privileged container.
FROM node:24.22.2-bookworm@sha256:8fa96264f302f58bbb13aa7339c541547b56975766ce956c875da149452a3e40 AS build
ENV COREPACK_HOME=/usr/local/share/corepack
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .pnpmfile.cjs tsconfig.base.json ./
COPY patches ./patches
COPY scripts ./scripts
COPY apps/api/package.json apps/api/
COPY apps/worker/package.json apps/worker/
COPY apps/web/package.json apps/web/
COPY apps/desktop/package.json apps/desktop/
COPY apps/mobile/package.json apps/mobile/
COPY apps/www/package.json apps/www/
COPY packages ./packages
COPY infra/sandboxes/supervisor/package.json ./infra/sandboxes/supervisor/
COPY infra/updater/package.json ./infra/updater/
RUN pnpm install --frozen-lockfile --cpu=current --os=current --filter=. --filter="@rakazo/adapters..."
RUN pnpm --filter @rakazo/db generate
WORKDIR /app/packages/adapters
RUN node ../../scripts/build-server.mjs src/native-harness/daemon.ts src/native-harness/verify-cli.ts \
    && cp src/native-harness/computer-runner.mjs src/native-harness/permission-proxy.mjs dist/native-harness/
WORKDIR /app
RUN find . -name node_modules -type d -prune -exec rm -rf {} + \
    && pnpm install --frozen-lockfile --prod --cpu=current --os=current --filter="@rakazo/adapters..."
ARG GIT_SHA
RUN test -n "$GIT_SHA" && printf '%s\n' "$GIT_SHA" > /app/.execution-revision

FROM node:24.22.2-bookworm-slim@sha256:01d566e8d94d8c619591d78652babfccd3c6992a3dffa9ed5ab39e11cf6c70e9
COPY --from=build /app /app
WORKDIR /app
# Operators extract /app and the Node binary with install-control.sh.
CMD ["node", "--check", "packages/adapters/dist/native-harness/daemon.js"]
