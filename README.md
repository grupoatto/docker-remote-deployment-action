# Docker Remote Deployment Action

Action do GitHub que faz deploy num **Docker ou Docker Swarm remoto por SSH**: roda um script
(`make deploy`, por exemplo), um `docker stack deploy` ou um `docker compose up` com o
`DOCKER_HOST` apontando para o servidor.

- Docker CLI 29 com os plugins `compose` e `buildx`; a versão da API é **negociada** com cada
  daemon (não precisa mais de `docker_api_version` para servidores com Docker novo).
- Imagem pronta no GHCR: o deploy não constrói nada antes de começar.
- **Uma** conexão SSH reaproveitada pelo deploy inteiro.
- Chave do host verificada com `ssh_known_hosts`.
- Chave privada e login do registry só dentro do container da action, apagados no fim.
- Resumo no job (host, Docker do servidor, modo, resultado, duração) e output
  `docker_server_version`.

## Uso

### Modo script (padrão)

O script roda em `bash -eo pipefail` (como um `run:`), no diretório do repositório, com
`DOCKER_HOST` já definido. As variáveis do `env:` do step chegam ao script.

```yaml
- uses: grupoatto/docker-remote-deployment-action@v6
  env:
    SECRETS_JSON: ${{ toJSON(secrets) }}
  with:
    remote_docker_host: ${{ vars.DEPLOY_HOST }} # docker@172.16.0.63
    ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
    ssh_known_hosts: ${{ vars.DEPLOY_KNOWN_HOSTS }}
    docker_registry_uri: ghcr.io
    docker_registry_username: ${{ github.actor }}
    docker_registry_token: ${{ secrets.GITHUB_TOKEN }}
    docker_script: make deploy ENV=dev TAG=v1.2.3
```

### Modo swarm

```yaml
- uses: grupoatto/docker-remote-deployment-action@v6
  with:
    remote_docker_host: ${{ vars.DEPLOY_HOST }}
    ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
    ssh_known_hosts: ${{ vars.DEPLOY_KNOWN_HOSTS }}
    deployment_mode: swarm
    stack_name: minha-app-dev
    stack_file_name: ci/deploy/stack.yaml ci/deploy/stack.dev.yaml
```

Roda `docker stack deploy --with-registry-auth --detach=false -c <arquivo>... <stack_name>` e
espera os serviços convergirem.

### Modo compose

```yaml
- uses: grupoatto/docker-remote-deployment-action@v6
  with:
    remote_docker_host: ${{ vars.DEPLOY_HOST }}
    ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
    ssh_known_hosts: ${{ vars.DEPLOY_KNOWN_HOSTS }}
    deployment_mode: compose
    stack_name: minha-app
    stack_file_name: compose.yaml
```

Roda `docker compose -f <arquivo>... [-p <stack_name>] up -d --remove-orphans`.

## Inputs

| Input | Obrigatório | Padrão | Descrição |
|---|---|---|---|
| `remote_docker_host` | sim | — | `usuario@host` do Docker remoto |
| `remote_docker_port` | não | `22` | Porta SSH |
| `ssh_private_key` | sim | — | Chave privada SSH (conteúdo) |
| `ssh_known_hosts` | não (recomendado) | — | Linhas do `known_hosts` do servidor; sem ele a chave do host é aceita na primeira conexão, com aviso |
| `deployment_mode` | não | `script` | `script`, `swarm` ou `compose` |
| `docker_script` | no modo script | — | Script bash a executar |
| `stack_file_name` | não | `docker-compose.yaml` | Arquivo(s) de stack/compose, separados por espaço |
| `stack_name` | no modo swarm | — | Nome da stack (project name no compose) |
| `working_directory` | não | `.` | Diretório, relativo ao workspace, onde o deploy roda |
| `docker_registry_uri` | não | Docker Hub | Registry do `docker login` (ex. `ghcr.io`) |
| `docker_registry_username` | não | — | Usuário do registry |
| `docker_registry_token` | não | — | Token do registry (login só com usuário e token) |
| `docker_api_version` | não | negociada | Força `DOCKER_API_VERSION` (escape; normalmente desnecessário) |
| `debug` | não | `false` | Imprime o script completo e liga o log detalhado do SSH |
| `ssh_public_key` | não | — | **Obsoleto**, ignorado |

## Outputs

| Output | Descrição |
|---|---|
| `docker_server_version` | Versão do Docker do servidor (ex. `26.1.4`) |

## Segurança

- **`ssh_known_hosts`**: gere uma vez e confira a impressão digital com quem administra o
  servidor, depois guarde numa variável do Environment (não é segredo):

  ```sh
  ssh-keyscan -p 22 172.16.0.63 2>/dev/null   # conferir com: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub (no servidor)
  ```

  Sem ele, a action usa `ssh-keyscan` na hora e aceita qualquer chave (sujeito a
  man-in-the-middle) e avisa no log.
- O usuário SSH precisa estar no grupo `docker` do servidor. Isso equivale a root no servidor:
  use uma chave dedicada ao deploy, por Environment.
- A chave privada, o `known_hosts` e o login do registry ficam em `/root` **dentro do container
  da action** (não no `HOME` compartilhado do runner) e são apagados no fim, com sucesso ou
  falha. O login do registry também é desfeito.
- O log mostra só a primeira linha do `docker_script` (pode ter valores interpolados);
  `debug: true` mostra tudo.

## Migrar da v5 para a v6

| v5 | v6 |
|---|---|
| Imagem construída a cada run (`docker/compose:1.29.2`, CLI 19.03) | Imagem pronta no GHCR, CLI 29 + compose v2 |
| `docker_api_version` padrão `1.40` | Negociada com o daemon; remova `docker_api_version: 1.44` dos workflows |
| `ssh_public_key` obrigatório | Ignorado; pode remover |
| Host aceito sem verificação | `ssh_known_hosts` recomendado |
| Modo padrão `docker-compose` (quebrado) | Modo padrão `script`; `compose` usa `docker compose` (v2) |
| `swarm` sem nome de stack (quebrado) | `swarm` exige `stack_name` |
| Script em `bash -c` (erros no meio eram ignorados) | Script em `bash -eo pipefail`: o primeiro comando que falha encerra o deploy |
| `docker-compose` (v1) disponível | Só `docker compose` (v2) |

Na maioria dos workflows basta trocar `@v5` por `@v6`, remover `docker_api_version` e
`ssh_public_key` e acrescentar `ssh_known_hosts`. Scripts com várias linhas que dependiam de um
comando falhar sem parar o deploy precisam de `|| true` nesse comando.

As tags `v1`–`v5` continuam publicadas e não mudam.

## Versionamento e release

- Tags `vX.Y.Z` imutáveis e `vX` móvel (aponta para a última `vX.Y.Z`).
- O `action.yaml` de cada versão aponta para a imagem `ghcr.io/grupoatto/docker-remote-deployment-action:vX.Y.Z`.
- Para lançar uma versão:

  ```sh
  make release-prep VERSION=v6.0.1   # aponta o action.yaml para a imagem da versão
  # atualizar o CHANGELOG.md, commit, merge na main
  git tag v6.0.1 && git push origin v6.0.1
  ```

  O workflow `release.yaml` confere o `action.yaml`, roda lint e testes, publica a imagem
  (`:v6.0.1` e `:v6`, com SBOM e provenance), move a tag `v6` e cria a release.
- O pacote no GHCR precisa ser **público**: o runner baixa a imagem da action sem credencial.
  A imagem não contém segredo.

## Desenvolvimento

Requer Docker (os linters rodam em container).

```sh
make lint    # shellcheck, shfmt, hadolint, actionlint
make test    # constrói a imagem e roda test/integration.sh
```

`test/integration.sh` sobe um Docker (dind) com sshd e um usuário `deploy` no grupo `docker`,
e roda a imagem da action como o runner roda (inputs em `INPUT_*`). Cobre os três modos,
known_hosts certo e errado, keyscan, código de saída, variáveis do step, API forçada, outputs e
resumo.

```text
action.yaml            contrato (inputs, outputs, imagem)
entrypoint.sh          lógica da action
Dockerfile             imagem publicada no GHCR
test/                  teste de integração (alvo dind + fixtures)
.github/workflows/     ci.yaml (lint + teste) e release.yaml (publicação)
```
