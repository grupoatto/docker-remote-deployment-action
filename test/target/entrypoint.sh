#!/bin/bash
# Libera a chave do teste (montada em /keys), sobe o sshd e entrega para o dockerd do dind.
set -euo pipefail
install -d -m 700 -o deploy -g docker /home/deploy/.ssh
install -m 600 -o deploy -g docker /keys/authorized_keys /home/deploy/.ssh/authorized_keys
/usr/sbin/sshd -e
exec dockerd-entrypoint.sh "$@"
