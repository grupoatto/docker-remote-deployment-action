#!/usr/bin/env bash
# Entrada da action: prepara SSH e registry, conecta no Docker remoto e roda o deploy.
# Os inputs chegam como INPUT_<NOME> (runner do GitHub); contrato em action.yaml.
set -euo pipefail

log() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die() {
  printf '::error::%s\n' "$*"
  exit 1
}
is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

HOST_SPEC="${INPUT_REMOTE_DOCKER_HOST:-}"
PORT="${INPUT_REMOTE_DOCKER_PORT:-22}"
MODE="${INPUT_DEPLOYMENT_MODE:-script}"
STACK_NAME="${INPUT_STACK_NAME:-}"
REGISTRY="${INPUT_DOCKER_REGISTRY_URI:-}"
DEBUG="${INPUT_DEBUG:-false}"

[ -n "$HOST_SPEC" ] || die "remote_docker_host é obrigatório (ex. docker@172.16.0.63)"
[ -n "${INPUT_SSH_PRIVATE_KEY:-}" ] || die "ssh_private_key é obrigatório"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "remote_docker_port inválida: $PORT"
SSH_HOST="${HOST_SPEC#*@}"
[[ "$SSH_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "host inválido em remote_docker_host: $HOST_SPEC"
[ -z "$STACK_NAME" ] || [[ "$STACK_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
  die "stack_name inválido: $STACK_NAME"
[ -z "${INPUT_SSH_PUBLIC_KEY:-}" ] || log "ssh_public_key é obsoleto e foi ignorado"

# O HOME do runner (/github/home) é compartilhado entre os steps do job: chave, known_hosts e
# login do registry ficam só neste container e são apagados no fim.
export HOME=/root
SSH_DIR="$HOME/.ssh"
LOGGED_IN=0

cleanup() {
  local rc=$?
  if [ "$LOGGED_IN" = 1 ]; then
    docker logout ${REGISTRY:+"$REGISTRY"} >/dev/null 2>&1 || true
  fi
  ssh -O exit "$HOST_SPEC" >/dev/null 2>&1 || true
  rm -rf "$SSH_DIR" "$HOME/.docker"
  exit "$rc"
}
trap cleanup EXIT

umask 077
mkdir -p "$SSH_DIR"
printf '%s\n' "$INPUT_SSH_PRIVATE_KEY" | tr -d '\r' >"$SSH_DIR/id_deploy"

if [ -n "${INPUT_SSH_KNOWN_HOSTS:-}" ]; then
  printf '%s\n' "$INPUT_SSH_KNOWN_HOSTS" | tr -d '\r' >"$SSH_DIR/known_hosts"
else
  warn "ssh_known_hosts vazio: a chave de ${SSH_HOST}:${PORT} será aceita sem verificação"
  ssh-keyscan -T 10 -p "$PORT" "$SSH_HOST" >"$SSH_DIR/known_hosts" 2>/dev/null || true
  [ -s "$SSH_DIR/known_hosts" ] || die "não foi possível obter a chave SSH de ${SSH_HOST}:${PORT}"
fi

# Uma conexão SSH para o deploy inteiro (cada comando docker abriria a sua).
cat >"$SSH_DIR/config" <<EOF
Host ${SSH_HOST}
  Port ${PORT}
  IdentityFile ${SSH_DIR}/id_deploy
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ${SSH_DIR}/known_hosts
  ConnectTimeout 20
  ServerAliveInterval 30
  ServerAliveCountMax 4
  ControlMaster auto
  ControlPath ${SSH_DIR}/cm-%C
  ControlPersist 15m
  LogLevel $(is_true "$DEBUG" && echo VERBOSE || echo ERROR)
EOF

export DOCKER_HOST="ssh://${HOST_SPEC}:${PORT}"
if [ -n "${INPUT_DOCKER_API_VERSION:-}" ]; then
  export DOCKER_API_VERSION="$INPUT_DOCKER_API_VERSION"
fi

log "::group::Conectando em ${HOST_SPEC}:${PORT}"
if ! SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>&1)"; then
  log "$SERVER_VERSION"
  die "sem acesso ao Docker de ${HOST_SPEC}:${PORT}: confira chave, ssh_known_hosts, se o usuário está no grupo docker e a versão da API"
fi
docker version --format 'cliente {{.Client.Version}} (API {{.Client.APIVersion}}) · servidor {{.Server.Version}} (API {{.Server.APIVersion}})'
log "::endgroup::"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "docker_server_version=${SERVER_VERSION}" >>"$GITHUB_OUTPUT"
fi

if [ -n "${INPUT_DOCKER_REGISTRY_USERNAME:-}" ] && [ -n "${INPUT_DOCKER_REGISTRY_TOKEN:-}" ]; then
  log "docker login ${REGISTRY:-Docker Hub}"
  printf '%s' "$INPUT_DOCKER_REGISTRY_TOKEN" |
    docker login -u "$INPUT_DOCKER_REGISTRY_USERNAME" --password-stdin ${REGISTRY:+"$REGISTRY"} >/dev/null
  LOGGED_IN=1
fi

cd "${INPUT_WORKING_DIRECTORY:-.}"
read -r -a FILES <<<"${INPUT_STACK_FILE_NAME:-docker-compose.yaml}"
need_files() {
  local f
  for f in "${FILES[@]}"; do
    [ -f "$f" ] || die "arquivo não encontrado: $f (em $(pwd))"
  done
}

case "$MODE" in
  script)
    [ -n "${INPUT_DOCKER_SCRIPT:-}" ] || die "docker_script é obrigatório no modo script"
    SCRIPT="$(mktemp)"
    printf '%s\n' "$INPUT_DOCKER_SCRIPT" >"$SCRIPT"
    if is_true "$DEBUG"; then
      log "::group::docker_script"
      cat "$SCRIPT"
      log "::endgroup::"
    fi
    # Mesmo shell do `run:` do GitHub; só a primeira linha vai para o log (o script pode ter
    # valores interpolados).
    SHOWN="bash: $(head -n1 "$SCRIPT")"
    [ "$(wc -l <"$SCRIPT")" -le 1 ] || SHOWN+=" …"
    CMD=(bash -eo pipefail "$SCRIPT")
    ;;
  swarm)
    [ -n "$STACK_NAME" ] || die "stack_name é obrigatório no modo swarm"
    need_files
    ARGS=()
    for f in "${FILES[@]}"; do ARGS+=(-c "$f"); done
    CMD=(docker stack deploy --with-registry-auth --detach=false "${ARGS[@]}" "$STACK_NAME")
    SHOWN="${CMD[*]}"
    ;;
  compose)
    need_files
    ARGS=()
    for f in "${FILES[@]}"; do ARGS+=(-f "$f"); done
    [ -z "$STACK_NAME" ] || ARGS+=(-p "$STACK_NAME")
    CMD=(docker compose "${ARGS[@]}" up -d --remove-orphans)
    SHOWN="${CMD[*]}"
    ;;
  *) die "deployment_mode inválido: $MODE (use script, swarm ou compose)" ;;
esac

log "Executando: ${SHOWN}"
START=$SECONDS
set +e
"${CMD[@]}"
RC=$?
set -e
DURATION=$((SECONDS - START))

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Docker Remote Deployment"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Host | \`${HOST_SPEC}:${PORT}\` |"
    echo "| Docker do host | ${SERVER_VERSION} |"
    echo "| Modo | ${MODE} |"
    echo "| Resultado | $([ "$RC" = 0 ] && echo '✅ sucesso' || echo "❌ falhou (código ${RC})") |"
    echo "| Duração | ${DURATION}s |"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$RC" = 0 ] || die "deploy falhou (código ${RC}) após ${DURATION}s"
log "deploy concluído em ${DURATION}s"
