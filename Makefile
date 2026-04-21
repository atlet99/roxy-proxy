ifneq (,$(wildcard ./.env))
include .env
export
endif

SOPS_KEY_FILE = $(HOME)/.sops/key.txt
LOGROTATE_CONF = /etc/logrotate.d/roxy-proxy-nginx

.PHONY: help \
        init up down restart logs ps check \
        sops-init sops-enc sops-dec \
        sops-enc-cf-api sops-dec-cf-api \
        cf-api-template cf-remote-tunnel \
        setup-deps setup-ufw setup-ufw-auto setup-fail2ban setup-logrotate logrotate-check logrotate-run \
        stage-prepare stage-cloudflare stage-secrets stage-start stage-hardening stage-verify \
        bootstrap bootstrap-no-cf

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

init: ## Prepare local env and directories
	@if [ ! -f .env ]; then cp .env.example .env; fi
	@mkdir -p certs secrets
	@echo "Initialized. Fill .env and (optionally) set up encrypted Cloudflare API token."

up: ## Start all services
	docker compose up -d --build

down: ## Stop all services
	docker compose down

restart: ## Restart all services
	docker compose restart

logs: ## Follow all logs
	docker compose logs -f --tail=150

ps: ## Show service status
	docker compose ps

check: ## Validate required runtime inputs
	@test -f .env || (echo "Missing .env (run make init)" && exit 1)
	@grep -qE '^TUNNEL_TOKEN=.+' .env || (echo "Missing TUNNEL_TOKEN in .env (run make cf-remote-tunnel or set manually)" && exit 1)
	@test -f certs/crt.pem || (echo "Missing certs/crt.pem (run make sops-dec)" && exit 1)
	@test -f certs/crt.key || (echo "Missing certs/crt.key (run make sops-dec)" && exit 1)
	@echo "Preflight checks passed"

sops-init: ## Generate AGE key for SOPS
	@mkdir -p $(HOME)/.sops
	@if [ ! -f $(SOPS_KEY_FILE) ]; then \
		age-keygen -o $(SOPS_KEY_FILE); \
		echo "Public key:"; \
		age-keygen -y $(SOPS_KEY_FILE); \
	else \
		echo "Key already exists at $(SOPS_KEY_FILE)"; \
	fi

sops-enc: ## Encrypt certs/crt.pem and certs/crt.key
	SOPS_AGE_KEY_FILE=$(SOPS_KEY_FILE) sops --encrypt certs/crt.pem > certs/enc.crt.pem
	SOPS_AGE_KEY_FILE=$(SOPS_KEY_FILE) sops --encrypt certs/crt.key > certs/enc.crt.key
	@echo "Encrypted cert files"

sops-dec: ## Decrypt certs for runtime
	SOPS_AGE_KEY_FILE=$(SOPS_KEY_FILE) sops --decrypt certs/enc.crt.pem > certs/crt.pem
	SOPS_AGE_KEY_FILE=$(SOPS_KEY_FILE) sops --decrypt certs/enc.crt.key > certs/crt.key
	@chmod 600 certs/crt.key
	@echo "Decrypted cert files"

cf-api-template: ## Create template for Cloudflare API token file
	@mkdir -p secrets
	@printf "CLOUDFLARE_API_TOKEN=\n" > secrets/cloudflare.api.env.template
	@echo "Created secrets/cloudflare.api.env.template"

sops-enc-cf-api: ## Encrypt secrets/cloudflare.api.env
	@test -f secrets/cloudflare.api.env || (echo "Missing secrets/cloudflare.api.env" && exit 1)
	SOPS_AGE_KEY_FILE=$(SOPS_KEY_FILE) sops --encrypt secrets/cloudflare.api.env > secrets/enc.cloudflare.api.env
	@echo "Encrypted Cloudflare API token -> secrets/enc.cloudflare.api.env"

sops-dec-cf-api: ## Decrypt secrets/enc.cloudflare.api.env
	@test -f secrets/enc.cloudflare.api.env || (echo "Missing secrets/enc.cloudflare.api.env" && exit 1)
	SOPS_AGE_KEY_FILE=$(SOPS_KEY_FILE) sops --decrypt secrets/enc.cloudflare.api.env > secrets/cloudflare.api.env
	@chmod 600 secrets/cloudflare.api.env
	@echo "Decrypted Cloudflare API token -> secrets/cloudflare.api.env"

cf-remote-tunnel: ## Create/update remote tunnel, DNS, ingress, and write TUNNEL_TOKEN to .env
	@set -a; [ -f .env ] && . ./.env; [ -f secrets/cloudflare.api.env ] && . ./secrets/cloudflare.api.env; set +a; ./scripts/cf-remote-tunnel-api.sh

setup-deps: ## Install ufw/fail2ban/logrotate/jq deps (Debian/Ubuntu)
	bash scripts/setup-deps.sh

setup-ufw: ## Configure UFW rules (interactive confirm)
	bash scripts/setup-ufw.sh

setup-ufw-auto: ## Configure UFW rules non-interactive
	UFW_AUTO_CONFIRM=1 bash scripts/setup-ufw.sh

setup-fail2ban: ## Configure fail2ban jails/filters
	bash scripts/setup-fail2ban.sh

setup-logrotate: ## Install nginx logrotate config
	sudo cp nginx/logrotate.conf $(LOGROTATE_CONF)
	@echo "Installed $(LOGROTATE_CONF)"

logrotate-check: ## Dry-run logrotate validation
	sudo logrotate -d $(LOGROTATE_CONF)

logrotate-run: ## Force logrotate now
	sudo logrotate -f $(LOGROTATE_CONF)

stage-prepare: ## Stage 1: init workspace
	@echo "== Stage 1/6: prepare =="
	$(MAKE) init

stage-cloudflare: ## Stage 2: apply Cloudflare remote tunnel config via API
	@echo "== Stage 2/6: cloudflare =="
	$(MAKE) sops-dec-cf-api
	$(MAKE) cf-remote-tunnel

stage-secrets: ## Stage 3: decrypt runtime certs
	@echo "== Stage 3/6: secrets =="
	$(MAKE) sops-dec

stage-start: ## Stage 4: preflight checks + start containers
	@echo "== Stage 4/6: start =="
	$(MAKE) check
	$(MAKE) up

stage-hardening: ## Stage 5: host hardening
	@echo "== Stage 5/6: hardening =="
	$(MAKE) setup-deps
	$(MAKE) setup-ufw-auto
	$(MAKE) setup-fail2ban
	$(MAKE) setup-logrotate

stage-verify: ## Stage 6: final validation
	@echo "== Stage 6/6: verify =="
	$(MAKE) ps
	$(MAKE) logrotate-check
	@echo "Bootstrap completed"

bootstrap: ## One-shot full flow (Cloudflare API + run + hardening)
	@echo "Starting full bootstrap"
	$(MAKE) stage-prepare
	$(MAKE) stage-cloudflare
	$(MAKE) stage-secrets
	$(MAKE) stage-start
	$(MAKE) stage-hardening
	$(MAKE) stage-verify

bootstrap-no-cf: ## One-shot flow without Cloudflare API stage (uses existing .env TUNNEL_TOKEN)
	@echo "Starting bootstrap without Cloudflare API stage"
	$(MAKE) stage-prepare
	$(MAKE) stage-secrets
	$(MAKE) stage-start
	$(MAKE) stage-hardening
	$(MAKE) stage-verify
