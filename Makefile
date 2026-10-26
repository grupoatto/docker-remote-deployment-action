# Desenvolvimento local da action. `make help` lista os alvos.
IMAGE ?= drda:test

SHELL_FILES := entrypoint.sh test/integration.sh test/target/entrypoint.sh

.PHONY: help lint build test release-prep

help: ## Lista os alvos
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

lint: ## shellcheck, shfmt, hadolint e actionlint (por container)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:v0.10.0 $(SHELL_FILES)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt mvdan/shfmt:v3.10.0 -d -i 2 -ci $(SHELL_FILES)
	docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile
	docker run --rm -i hadolint/hadolint:v2.12.0 < test/target/Dockerfile
	docker run --rm -v "$(CURDIR):/repo" -w /repo rhysd/actionlint:1.7.7 -color

build: ## Constrói a imagem local ($(IMAGE))
	docker build -t $(IMAGE) .

test: build ## Teste de integração contra um Docker+sshd (dind)
	test/integration.sh $(IMAGE)

release-prep: ## Aponta o action.yaml para a imagem da versão (VERSION=v6.0.1)
	@echo "$(VERSION)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION=vX.Y.Z"; exit 1; }
	sed -i -E 's#(docker-remote-deployment-action:)v[0-9]+\.[0-9]+\.[0-9]+#\1$(VERSION)#' action.yaml
	@grep -n 'image:' action.yaml
	@echo "Atualize o CHANGELOG.md, faça o commit e crie a tag $(VERSION)."
