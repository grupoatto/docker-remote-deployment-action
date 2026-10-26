# syntax=docker/dockerfile:1
# Docker CLI atual (com os plugins compose e buildx); a API é negociada com cada daemon.
FROM docker:29.9.1-cli@sha256:6fae2214c3121a28d5aa639d09032f61310b7c9c75ffbad1025f261a1b621800

LABEL org.opencontainers.image.title="docker-remote-deployment-action" \
      org.opencontainers.image.description="Deploy em Docker/Swarm remoto por SSH" \
      org.opencontainers.image.source="https://github.com/grupoatto/docker-remote-deployment-action"

# hadolint ignore=DL3018
RUN apk add --no-cache bash coreutils git jq make openssh-client

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
