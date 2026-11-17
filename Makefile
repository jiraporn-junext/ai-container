SHELL := /bin/bash
COMPOSE ?= docker compose
SERVICE ?= claude-cli

MODEL ?= $(strip $(shell grep -E '^OLLAMA_MODEL=' .env 2>/dev/null | tail -n1 | cut -d= -f2-))
ifeq ($(strip $(MODEL)),)
MODEL := qwen3:1.7b
endif

.PHONY: help up down rebuild shell claude models pull chat logs ps wait-model

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Build the image and start the container
	./container.sh start

down: ## Stop the container
	./container.sh stop

rebuild: ## Rebuild the image from scratch and restart
	$(COMPOSE) build --no-cache
	./container.sh start

shell: ## Open a bash shell inside the container
	$(COMPOSE) exec $(SERVICE) bash

claude: ## Start Claude Code, wired to the local model
	$(COMPOSE) exec $(SERVICE) claude

models: ## List the models stored in the container
	$(COMPOSE) exec $(SERVICE) ollama list

pull: ## Pull a model into the container (make pull MODEL=qwen2.5:3b)
	$(COMPOSE) exec $(SERVICE) ollama pull $(MODEL)

chat: ## Chat with the model directly
	$(COMPOSE) exec $(SERVICE) ollama run $(MODEL)

logs: ## Follow the Ollama server and model-pull logs
	$(COMPOSE) exec $(SERVICE) tail -f /var/log/ollama.log /var/log/ollama-bootstrap.log

ps: ## Show container status
	$(COMPOSE) ps

wait-model: ## Block until the configured model is downloaded and ready
	@echo "waiting for $(MODEL) to be ready..."
	@for ((i = 0; i < 360; i++)); do \
		if $(COMPOSE) exec -T $(SERVICE) \
			sh -c 'curl -sf http://127.0.0.1:11434/api/tags | grep -Fq "$(MODEL)"' >/dev/null 2>&1; then \
			echo "$(MODEL) is ready"; exit 0; \
		fi; \
		sleep 5; \
	done; \
	echo "$(MODEL) did not become ready within 30 minutes."; \
	echo "check 'make logs' and retry with 'make pull MODEL=$(MODEL)'"; \
	exit 1
