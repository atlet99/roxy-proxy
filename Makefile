ifneq (,$(wildcard ./.env))
include .env
export
endif

SOPS_KEY_FILE ?= $(HOME)/.sops/key.txt
LOGROTATE_CONF = /etc/logrotate.d/roxy-proxy-nginx

.PHONY: help init up down restart logs ps render-cloudflared check deploy deploy-safe \
        sops-init sops-enc sops-dec setup-deps setup-ufw setup-ufw-auto setup-fail2ban setup-logrotate \
        logrotate-check logrotate-run \
        stage-prepare stage-secrets stage-start stage-hardening stage-verify bootstrap

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

init: ## Prepare local env files
	@if [ ! -f .env ]; then cp .env.example .env; fi
	@mkdir -p cloudflared certs
	@echo "Initialized. Fill .env and place tunnel credentials JSON file."

render-cloudflared: ## Render cloudflared/config.yml from template
	@set -a; [ -f .env ] && . ./.env; set +a; ./scripts/render-cloudflared-config.sh

up: render-cloudflared ## Start all services
	docker compose up -d --build

down: ## Stop all services
	docker compose down

restart: ## Restart all services
	docker compose restart

logs: ## Follow all logs
	docker compose logs -f --tail=100

ps: ## Show service status
	docker compose ps

check: ## Validate generated config and runtime assumptions
	@test -f cloudflared/config.yml || (echo "Missing cloudflared/config.yml" && exit 1)
	@test -f certs/crt.pem || (echo "Missing certs/crt.pem (run make sops-dec)" && exit 1)
	@test -f certs/crt.key || (echo "Missing certs/crt.key (run make sops-dec)" && exit 1)
	@test -f .env || (echo "Missing .env (run make init)" && exit 1)
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

setup-deps: ## Install ufw/fail2ban/logrotate deps (Debian/Ubuntu)
	bash scripts/setup-deps.sh

setup-ufw: ## Configure UFW rules for this stack (interactive confirm)
	bash scripts/setup-ufw.sh

setup-ufw-auto: ## Configure UFW rules non-interactive (for bootstrap flow)
	UFW_AUTO_CONFIRM=1 bash scripts/setup-ufw.sh

setup-fail2ban: ## Configure fail2ban jails/filters
	bash scripts/setup-fail2ban.sh

setup-logrotate: ## Install nginx logrotate config to /etc/logrotate.d
	sudo cp nginx/logrotate.conf $(LOGROTATE_CONF)
	@echo "Installed $(LOGROTATE_CONF)"

logrotate-check: ## Dry-run logrotate validation
	sudo logrotate -d $(LOGROTATE_CONF)

logrotate-run: ## Force logrotate now
	sudo logrotate -f $(LOGROTATE_CONF)

deploy: sops-dec check up ## Full deploy (decrypt, validate, up)

deploy-safe: init sops-dec check up ## Safe deploy from zero state

stage-prepare: ## Stage 1: init files + render cloudflared config
	@echo "== Stage 1/5: prepare =="
	$(MAKE) init
	$(MAKE) render-cloudflared
	@echo "Stage prepare completed"

stage-secrets: ## Stage 2: decrypt runtime certificates
	@echo "== Stage 2/5: secrets =="
	$(MAKE) sops-dec
	@echo "Stage secrets completed"

stage-start: ## Stage 3: preflight checks + start containers
	@echo "== Stage 3/5: start =="
	$(MAKE) check
	$(MAKE) up
	@echo "Stage start completed"

stage-hardening: ## Stage 4: deps + ufw + fail2ban + logrotate
	@echo "== Stage 4/5: hardening =="
	$(MAKE) setup-deps
	$(MAKE) setup-ufw-auto
	$(MAKE) setup-fail2ban
	$(MAKE) setup-logrotate
	@echo "Stage hardening completed"

stage-verify: ## Stage 5: final checks
	@echo "== Stage 5/5: verify =="
	$(MAKE) ps
	$(MAKE) logrotate-check
	@echo "Bootstrap flow completed successfully"

bootstrap: ## One-shot full flow with stop-on-error and resumable stages
	@echo "Starting one-shot bootstrap flow"
	$(MAKE) stage-prepare
	$(MAKE) stage-secrets
	$(MAKE) stage-start
	$(MAKE) stage-hardening
	$(MAKE) stage-verify
