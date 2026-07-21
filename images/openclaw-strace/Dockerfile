FROM localhost/openclaw-kuasar:2026.6.11-virtiofs

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends strace \
    && rm -rf /var/lib/apt/lists/*
USER node
