# Optional native-engine layer over the ordinary managed desktop image.
# Build the base from infra/sandboxes/computer before building this image.
ARG COMPUTER_IMAGE=rakazo/computer
FROM node:26.13.0-bookworm-slim@sha256:add5c17c14752c54d2f3d519ec46a3815684d41c33f198bcb09fb998f7dcbf68 AS native-tools

# Only the official distributions; lifecycle scripts run only for the native
# installer that requires them. Keep these versions aligned with configuration.ts.
RUN npm install --global --ignore-scripts \
      @openai/codex@0.167.0 \
      @anthropic-ai/claude-code@2.1.286 \
      @deepseek-ai/dsh@0.2.1-rc.2 \
    && node /usr/local/lib/node_modules/@anthropic-ai/claude-code/install.cjs \
    && npm cache clean --force

FROM ${COMPUTER_IMAGE}
USER root
# The desktop's NSS wrapper is enabled only after startup creates its account
# files. Build steps must use the image's ordinary root account lookup.
RUN env -u LD_PRELOAD /bin/sh -eu -c \
    'apt-get update; apt-get install -y --no-install-recommends libatomic1 util-linux; rm -rf /var/lib/apt/lists/*'
COPY --from=native-tools /usr/local/bin/node /usr/local/bin/node
COPY --from=native-tools /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
# The namespace init and permission bridge use this stable system entry point.
RUN env -u LD_PRELOAD /bin/sh -eu -c \
    'ln -sfn /usr/local/bin/node /usr/bin/node; \
     ln -sfn ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
     ln -sfn ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx; \
     ln -sfn ../lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex; \
     ln -sfn ../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe /usr/local/bin/claude; \
     ln -sfn ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh; \
     node --version; npm --version; codex --version; claude --version; dsh --version; command -v unshare; command -v setpriv'
USER 1000:1000
# Inherit the desktop's entry point, environment, ports and writable home.
