# syntax=docker/dockerfile:1
# Alvo dos testes: Docker (dind) + sshd, com um usuário "deploy" no grupo docker, como nos
# servidores.
FROM docker:29.9.1-dind@sha256:3e5756e2b6dad6a5f1f5deacf0a19f9eaa2581b76ae092b2d4a118162e1d4d4e

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache bash openssh-server \
    && ssh-keygen -A \
    && { getent group docker >/dev/null || addgroup -S docker; } \
    && adduser -D -s /bin/bash -G docker deploy \
    && echo 'deploy:*' | chpasswd -e \
    && printf 'PasswordAuthentication no\nPermitRootLogin no\n' >>/etc/ssh/sshd_config

COPY entrypoint.sh /target-entrypoint.sh

ENTRYPOINT ["/target-entrypoint.sh"]
