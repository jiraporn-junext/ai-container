#!/usr/bin/env bash
# Start and stop the ai-container, with a choice between a local model and a
# cloud model served through Ollama.
#
#   ./container.sh start local    # qwen3:1.7b, runs on this machine
#   ./container.sh start cloud    # minimax-m3:cloud, runs on Ollama's GPUs
#   ./container.sh stop
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

COMPOSE="${COMPOSE:-docker compose}"
SERVICE="${SERVICE:-claude-cli}"
LOCAL_MODEL="${LOCAL_MODEL:-qwen3:1.7b}"
CLOUD_MODEL="${CLOUD_MODEL:-minimax-m3:cloud}"
ENV_FILE=".env"
EXAMPLE_FILE=".env.example"
STATE_FILE=".container-mode"
BUILT_FILE=".container-version"
VERSION_FILE="VERSION"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./container.sh <command> [mode]

Commands:
  start [local|cloud]   Build if needed, start the container, wait for the model
  stop                  Stop and remove the container (volumes are kept)
  restart [local|cloud] Restart, optionally switching between local and cloud
  status                Show container state and the active model
  logs                  Follow the Ollama server and model-pull logs
  shell                 Open a bash shell inside the container
  models                List the models stored in the container
  chat                  Chat with the active model
  signin                Sign in to Ollama (needed for some cloud models)
  signout               Sign out of Ollama
  version               Print the version of this repo
  help                  Show this help

Modes:
  local   Runs the model on this machine. Default: qwen3:1.7b
  cloud   Runs the model on Ollama's GPUs. Default: minimax-m3:cloud

The chosen mode is remembered, so plain "./container.sh start" reuses it.

Override the models with the LOCAL_MODEL and CLOUD_MODEL environment variables.
EOF
}

ensure_env() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$EXAMPLE_FILE" ]; then
            cp "$EXAMPLE_FILE" "$ENV_FILE"
            info "created $ENV_FILE from $EXAMPLE_FILE"
        else
            touch "$ENV_FILE"
        fi
    fi
}

# Point .env at a model, leaving every other setting in the file alone
set_model() {
    local model="$1"
    if grep -qE '^[[:space:]]*OLLAMA_MODEL[[:space:]]*=' "$ENV_FILE"; then
        # Keep the value on one line and keep the file's trailing newline intact
        sed -i.bak -E "s|^[[:space:]]*OLLAMA_MODEL[[:space:]]*=.*$|OLLAMA_MODEL=${model}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    else
        printf '\nOLLAMA_MODEL=%s\n' "$model" >> "$ENV_FILE"
    fi
}

active_mode() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo local
    fi
}

current_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d ' \t\n\r' < "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

built_version() {
    if [ -f "$BUILT_FILE" ]; then
        cat "$BUILT_FILE"
    else
        echo "none"
    fi
}

model_for_mode() {
    case "$1" in
        local) echo "$LOCAL_MODEL" ;;
        cloud) echo "$CLOUD_MODEL" ;;
        *) fail "unknown mode '$1' - use local or cloud" ;;
    esac
}

wait_for_model() {
    local model="$1" waited=0
    info "waiting for $model to be ready"
    while [ "$waited" -lt "$WAIT_SECONDS" ]; do
        if $COMPOSE exec -T "$SERVICE" \
            sh -c "curl -sf http://127.0.0.1:11434/api/tags | grep -Fq '$model'" >/dev/null 2>&1; then
            info "$model is ready"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        if [ $((waited % 60)) -eq 0 ]; then
            info "still waiting for $model (${waited}s)"
        fi
    done
    warn "$model did not become ready within $WAIT_SECONDS seconds"
    warn "check './container.sh logs' and retry with './container.sh start'"
    return 1
}

print_banner() {
    local mode="$1" model="$2"
    cat <<EOF

  mode     $mode
  model    $model
  version  $(current_version)
  host     http://localhost:\${OLLAMA_HOST_PORT:-11435}

  chat     ./container.sh chat
  code     ./container.sh shell   (then: aider --model ollama_chat/$model)
  logs     ./container.sh logs

EOF
}

do_start() {
    local mode="${1:-$(active_mode)}"
    local model
    model="$(model_for_mode "$mode")"

    command -v docker >/dev/null 2>&1 || fail "docker is not installed"
    $COMPOSE version >/dev/null 2>&1 || fail "the docker compose plugin is not available"

    ensure_env
    set_model "$model"
    echo "$mode" > "$STATE_FILE"

    local want have
    want="$(current_version)"
    have="$(built_version)"
    if [ "$want" != "$have" ]; then
        info "building the image (version $want, first build takes a few minutes)"
        $COMPOSE build
        echo "$want" > "$BUILT_FILE"
    else
        info "image is up to date (version $want)"
    fi

    info "starting the container in $mode mode"
    $COMPOSE up -d --remove-orphans

    if ! wait_for_model "$model"; then
        exit 1
    fi

    print_banner "$mode" "$model"
}

do_status() {
    local mode
    mode="$(active_mode)"
    printf 'version %s\n' "$(current_version)"
    printf 'mode    %s\n' "$mode"
    printf 'model   %s\n' "$(model_for_mode "$mode")"
    printf 'env     %s\n' "$(grep -E '^OLLAMA_MODEL=' "$ENV_FILE" 2>/dev/null || echo 'not set')"
    echo
    $COMPOSE ps
    echo
    $COMPOSE exec -T "$SERVICE" ollama list 2>/dev/null || true
}

case "${1:-help}" in
    start)
        do_start "${2:-}"
        ;;
    stop)
        info "stopping the container"
        $COMPOSE down
        ;;
    restart)
        $COMPOSE down
        do_start "${2:-}"
        ;;
    status)
        do_status
        ;;
    logs)
        $COMPOSE exec "$SERVICE" tail -f /var/log/ollama.log /var/log/ollama-bootstrap.log
        ;;
    shell)
        $COMPOSE exec "$SERVICE" bash
        ;;
    models)
        $COMPOSE exec "$SERVICE" ollama list
        ;;
    chat)
        $COMPOSE exec "$SERVICE" ollama run "$(model_for_mode "$(active_mode)")"
        ;;
    signin)
        info "signing in to Ollama - a browser window opens, or paste a code"
        # A one-shot container: it starts Ollama, signs in, and stops again, so
        # nothing is left running. The container itself does not need to be up.
        $COMPOSE run --rm --no-deps --entrypoint /usr/local/bin/ollama-signin "$SERVICE" signin
        ;;
    signout)
        info "signing out of Ollama"
        $COMPOSE run --rm --no-deps --entrypoint /usr/local/bin/ollama-signin "$SERVICE" signout
        ;;
    version)
        echo "$(current_version)"
        ;;
    help | -h | --help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
