# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versões em
[SemVer](https://semver.org/lang/pt-BR/).

## [v6.0.0] — não lançada

### Mudou

- Imagem pronta no GHCR (`ghcr.io/grupoatto/docker-remote-deployment-action`) em vez de
  construída a cada run; o build no ECR saiu (a action nunca usou aquela imagem).
- Base `docker:29.9.1-cli` (Docker CLI 29, compose v2, buildx) no lugar de
  `docker/compose:1.29.2` (CLI 19.03, compose v1).
- A versão da API é negociada com o daemon; `docker_api_version` deixa de ter padrão `1.40`.
- Modo padrão `script`. O script roda em `bash -eo pipefail`.
- `compose` usa `docker compose` (v2).
- `ssh_public_key` deixa de ser obrigatório e é ignorado.

### Adicionou

- `ssh_known_hosts` para verificar a chave do servidor.
- `stack_name` (obrigatório no modo `swarm`), `working_directory` e `debug`.
- Conexão SSH única para o deploy inteiro (`ControlMaster`), com keepalive.
- Teste de conexão no início, com erro claro.
- Output `docker_server_version` e resumo no job.
- Limpeza no fim: chave, `known_hosts` e login do registry apagados; `docker logout`.
- CI com shellcheck, shfmt, hadolint, actionlint e teste de integração (dind + sshd); release
  com SBOM e provenance; Renovate fixando digests.

### Corrigiu

- Modos `swarm` e `docker-compose` falhavam sempre (`cat` do comando antes de executar).
- O script inteiro era impresso no log.
- Chave e login ficavam no `HOME` compartilhado do runner.
