FROM ghcr.io/openclaw/openclaw:2026.6.11

USER root
COPY patch-sqlite-virtiofs.mjs /tmp/patch-sqlite-virtiofs.mjs
RUN node /tmp/patch-sqlite-virtiofs.mjs /app/dist \
    && rm /tmp/patch-sqlite-virtiofs.mjs
USER node
