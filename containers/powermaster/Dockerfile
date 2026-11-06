# syntax=docker/dockerfile:1
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl libstdc++6 libusb-1.0-0 procps tini \
    && rm -rf /var/lib/apt/lists/*

FROM base AS installer

ARG TARGETARCH
ARG POWERMASTER_VERSION=1.2.3
ARG POWERMASTER_URL=https://powerwalker.com/wp-content/uploads/2025/07/pmp123_linux64.zip
ARG POWERMASTER_SHA256=2e6b2b86fd5187d9664c1e79449f9a51106e051069a287a43c5300bf3140d316

RUN test "$TARGETARCH" = amd64
RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*

COPY response.varfile /tmp/response.varfile

RUN curl --fail --location --retry 3 "$POWERMASTER_URL" -o /tmp/powermaster.zip \
    && printf '%s  %s\n' "$POWERMASTER_SHA256" /tmp/powermaster.zip | sha256sum --check - \
    && unzip -q /tmp/powermaster.zip -d /tmp/installer \
    && sh "/tmp/installer/pmasterp$(printf '%s' "$POWERMASTER_VERSION" | tr -d .)-linux-x86_x64.sh" \
        -q -dir /opt/powermaster -varfile /tmp/response.varfile \
    && test -x /opt/powermaster/jre/bin/java \
    && test -f /opt/powermaster/web/AgentWeb-0.0.1-SNAPSHOT.war

FROM base AS runtime

ARG POWERMASTER_VERSION=1.2.3
LABEL org.opencontainers.image.title="PowerMaster+ Local" \
      org.opencontainers.image.description="PowerWalker PowerMaster+ Local USB management service" \
      org.opencontainers.image.version="$POWERMASTER_VERSION" \
      org.opencontainers.image.source="https://github.com/iitsdani/homelabs"

COPY --from=installer /opt/powermaster /opt/powermaster
COPY --chmod=755 entrypoint.sh /usr/local/bin/powermaster-entrypoint

RUN mkdir -p /usr/share/powermaster-defaults /data \
    && for directory in cert db_cloud db_local etc extcmd log uploads; do \
        mkdir -p "/opt/powermaster/$directory"; \
        mv "/opt/powermaster/$directory" /usr/share/powermaster-defaults/; \
        ln -s "/data/$directory" "/opt/powermaster/$directory"; \
    done

ENV HOME=/data
WORKDIR /opt/powermaster

EXPOSE 3052/tcp 3052/udp 53568/tcp 53566/udp 162/udp

HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=4 \
    CMD curl --fail --silent --show-error --max-time 4 http://127.0.0.1:3052/ > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/powermaster-entrypoint"]
CMD ["/opt/powermaster/pmasterpd", "run"]
