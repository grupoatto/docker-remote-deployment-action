#!/usr/bin/env bash
# Teste de integração: roda a imagem da action, como o runner do GitHub roda, contra um Docker
# real (dind) acessado por SSH com o usuário "deploy".
# Uso: test/integration.sh [imagem]   (padrão drda:test, construída por `make build`)
# Os scripts dos casos rodam dentro da action: as aspas simples são de propósito.
# shellcheck disable=SC2016
set -euo pipefail

IMAGE="${1:-drda:test}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
NET="drda-test-$$"
TARGET="drda-target-$$"
PASS=0
FAIL=0

cleanup() {
  docker rm -f "$TARGET" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== preparando o alvo"
ssh-keygen -q -t ed25519 -N '' -C drda-test -f "$WORK/key"
ssh-keygen -q -t ed25519 -N '' -C outro-host -f "$WORK/other_host"
mkdir -p "$WORK/keys" "$WORK/gh"
cp "$WORK/key.pub" "$WORK/keys/authorized_keys"
chmod 755 "$WORK/keys" && chmod 644 "$WORK/keys/authorized_keys"
docker build -q -t drda-target:test "$ROOT/test/target" >/dev/null
docker network create "$NET" >/dev/null
docker run -d --privileged --name "$TARGET" --network "$NET" -v "$WORK/keys:/keys:ro" \
  -e DOCKER_TLS_CERTDIR= drda-target:test --host=unix:///var/run/docker.sock >/dev/null
for _ in $(seq 60); do
  docker exec "$TARGET" docker info >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$TARGET" docker swarm init >/dev/null
KNOWN="${TARGET} $(docker exec "$TARGET" cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"
WRONG="${TARGET} $(cut -d' ' -f1,2 "$WORK/other_host.pub")"

# Roda a action com os inputs dados (NOME=valor, viram INPUT_NOME) e grava a saída em
# $WORK/<caso>.log.
run_action() {
  local name=$1
  shift
  local args=(--rm --network "$NET" -v "$ROOT/test/fixtures:/github/workspace:ro"
    -w /github/workspace -v "$WORK/gh:/github/file_commands"
    -e GITHUB_OUTPUT=/github/file_commands/output
    -e GITHUB_STEP_SUMMARY=/github/file_commands/summary
    -e INPUT_REMOTE_DOCKER_HOST="deploy@${TARGET}"
    -e INPUT_SSH_PRIVATE_KEY="$(cat "$WORK/key")")
  local kv
  for kv in "$@"; do
    case "$kv" in
      INPUT_* | APP_*) args+=(-e "$kv") ;;
      *) args+=(-e "INPUT_${kv}") ;;
    esac
  done
  : >"$WORK/gh/output"
  : >"$WORK/gh/summary"
  docker run "${args[@]}" "$IMAGE" >"$WORK/$name.log" 2>&1
}

check() {
  local name=$1 expect=$2
  shift 2
  local rc=0
  run_action "$name" "$@" || rc=$?
  if { [ "$expect" = ok ] && [ "$rc" = 0 ]; } || { [ "$expect" = fail ] && [ "$rc" != 0 ]; }; then
    echo "ok   - $name"
    PASS=$((PASS + 1))
    return 0
  fi
  echo "FAIL - $name (rc=$rc, esperado $expect)"
  sed 's/^/       /' "$WORK/$name.log"
  FAIL=$((FAIL + 1))
  return 1
}

assert() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   - $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "== casos"
check script ok SSH_KNOWN_HOSTS="$KNOWN" APP_VAR=do-step \
  DOCKER_SCRIPT='docker info --format "{{.Swarm.LocalNodeState}}" | grep -qx active
[ "$APP_VAR" = do-step ]
ls "$HOME"/.ssh/cm-* >/dev/null' || true
assert "output docker_server_version" grep -q '^docker_server_version=29\.' "$WORK/gh/output"
assert "resumo do step" grep -q '✅ sucesso' "$WORK/gh/summary"
assert "chave privada fora do log" bash -c "! grep -q BEGIN '$WORK/script.log'"

check script-falha fail SSH_KNOWN_HOSTS="$KNOWN" DOCKER_SCRIPT='exit 3' || true
assert "código do script no resumo" grep -q 'código 3' "$WORK/gh/summary"

check known-hosts-errado fail SSH_KNOWN_HOSTS="$WRONG" DOCKER_SCRIPT='docker ps' || true
assert "recusa host com chave diferente" grep -q 'Host key verification failed' "$WORK/known-hosts-errado.log"
check keyscan ok DOCKER_SCRIPT='docker ps -q' || true
assert "aviso sem known_hosts" grep -q '::warning::ssh_known_hosts vazio' "$WORK/keyscan.log"

check swarm ok SSH_KNOWN_HOSTS="$KNOWN" DEPLOYMENT_MODE=swarm STACK_NAME=drda \
  STACK_FILE_NAME=stack.yaml || true
assert "serviço da stack 1/1" bash -c \
  "docker exec '$TARGET' docker service ls --filter name=drda_web --format '{{.Replicas}}' | grep -qx 1/1"
check swarm-sem-nome fail SSH_KNOWN_HOSTS="$KNOWN" DEPLOYMENT_MODE=swarm \
  STACK_FILE_NAME=stack.yaml || true
assert "erro de stack_name ausente" grep -q 'stack_name é obrigatório' "$WORK/swarm-sem-nome.log"

check compose ok SSH_KNOWN_HOSTS="$KNOWN" DEPLOYMENT_MODE=compose STACK_NAME=drda-compose \
  STACK_FILE_NAME=compose.yaml || true
assert "container do compose rodando" bash -c \
  "docker exec '$TARGET' docker ps --filter label=com.docker.compose.project=drda-compose -q | grep -q ."

check api-forcada ok SSH_KNOWN_HOSTS="$KNOWN" DOCKER_API_VERSION=1.44 \
  DOCKER_SCRIPT='[ "$DOCKER_API_VERSION" = 1.44 ] && docker version >/dev/null' || true
check modo-invalido fail SSH_KNOWN_HOSTS="$KNOWN" DEPLOYMENT_MODE=kubernetes || true
assert "erro de modo inválido" grep -q 'deployment_mode inválido' "$WORK/modo-invalido.log"

echo "== ${PASS} ok, ${FAIL} falha(s)"
[ "$FAIL" = 0 ]
