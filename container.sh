#!/usr/bin/env bash
# Start and stop the ai-container, with a choice between a local model and a
# cloud model served through Ollama.
#
#   ./container.sh start local    # qwen3:1.7b, runs on this machine
#   ./container.sh start cloud    # minimax-m3:cloud, runs on Ollama's GPUs
#   ./container.sh stop
#
# Several instances can run side by side. Give each one its own name, compose
# project and port:
#
#   ./container.sh start local --name ai2 --project ai2 --port 11436
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

COMPOSE="${COMPOSE:-docker compose}"
SERVICE="${SERVICE:-claude-cli}"
LOCAL_MODEL="${LOCAL_MODEL:-qwen3:1.7b}"
CLOUD_MODEL="${CLOUD_MODEL:-minimax-m3:cloud}"
ENV_FILE=".env"
EXAMPLE_FILE=".env.example"
VERSION_FILE="VERSION"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"
DEFAULT_NAME="ai_container"
DEFAULT_PROJECT="ai-container"
DEFAULT_PORT="11435"

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./container.sh <command> [mode|instance] [instance] [options]

Commands:
  build [version]       Build the image and tag it with its version
  start [local|cloud]   Build if needed, start the container, wait for the model
  stop                  Stop and remove the container (volumes are kept)
  restart [local|cloud] Restart, optionally switching between local and cloud
  status                Show container state and the active model
  logs                  Follow the Ollama server and model-pull logs
  shell                 Open a bash shell inside the container
  models                List the models stored in the container
  chat                  Chat with the active model
  claude                Start Claude Code, wired to the local model
  signin                Sign in to Ollama (needed for some cloud models)
  signout               Sign out of Ollama
  version               Print the version of this repo
  help                  Show this help

Modes:
  local   Runs the model on this machine. Default: qwen3:1.7b
  cloud   Runs the model on Ollama's GPUs. Default: minimax-m3:cloud

An instance is a separate container with its own name, project and volumes.
Name it instead of a mode to run it:

  ./container.sh start ai2          # instance "ai2"
  ./container.sh start cloud ai2    # instance "ai2" in cloud mode

Options:
  --name NAME       Container name. Default: ai_container
  --project NAME    Compose project, which owns the volumes. Default: ai-container
  --port PORT       Host port for the Ollama API. Default: 11435
  --image TAG       Image tag to run. Default: latest

Give either the name or the project and the other follows from it, so
"--project ai2" is named ai2, and "--name work" runs in the project "work".

The chosen mode is remembered per project, so plain "./container.sh start"
reuses it.

Override the models with the LOCAL_MODEL and CLOUD_MODEL environment variables.
EOF
}

# ---------------------------------------------------------------- arguments

positional=()
name_override=""
project_override=""
port_override=""
image_override=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name) name_override="${2:-}"; shift 2 || true ;;
        --name=*) name_override="${1#*=}"; shift ;;
        --project) project_override="${2:-}"; shift 2 || true ;;
        --project=*) project_override="${1#*=}"; shift ;;
        --port) port_override="${2:-}"; shift 2 || true ;;
        --port=*) port_override="${1#*=}"; shift ;;
        --image) image_override="${2:-}"; shift 2 || true ;;
        --image=*) image_override="${1#*=}"; shift ;;
        --) shift; positional+=("$@"); break ;;
        *) positional+=("$1"); shift ;;
    esac
done

command_name="${positional[0]:-help}"

# "build" takes a version, every other command takes a mode or an instance
version_arg=""
mode_arg=""
instance_arg=""
first="${positional[1]:-}"
second="${positional[2]:-}"
if [ "$command_name" = "build" ]; then
    version_arg="$first"
elif [ "$command_name" = "claude" ]; then
    # "claude ai2 --resume": the instance, then anything for Claude Code
    if [ -n "$first" ] && [ "${first#-}" = "$first" ]; then
        instance_arg="$first"
    fi
elif [ -n "$first" ] && [ "${first#-}" = "$first" ] && [ "$first" != "local" ] && [ "$first" != "cloud" ]; then
    # "start ai2" runs the instance ai2
    instance_arg="$first"
elif [ -n "$second" ]; then
    # "start cloud ai2" runs it in cloud mode
    mode_arg="$first"
    instance_arg="$second"
else
    mode_arg="$first"
fi

# ------------------------------------------------------------------ compose

# docker compose with the project name pinned, and the shared .env plus any
# per-project overrides
compose() {
    local args=(-p "$PROJECT")
    local file
    for file in "$ENV_FILE" "$MODEL_ENV_FILE"; do
        [ -f "$file" ] && args+=(--env-file "$file")
    done
    $COMPOSE "${args[@]}" "$@"
}

# ------------------------------------------------------------------ helpers

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

# Project names are lowercase and may only contain letters, digits, dashes and
# underscores
sanitize_project() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//'
}

# The first port at or above the given one that nothing is listening on
free_port() {
    local port="$1"
    while [ "$port" -lt 11500 ]; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo "$1"
}

# The default project keeps its original container name, so the first instance
# is not renamed out from under it
name_from_project() {
    if [ "$1" = "$DEFAULT_PROJECT" ]; then
        echo "$DEFAULT_NAME"
    else
        echo "$1"
    fi
}

# Record the instance specific settings next to the model, so plain compose
# commands see the same values the script used
set_instance_settings() {
    local file="$MODEL_ENV_FILE"
    local key value
    for entry in "CONTAINER_NAME=$CONTAINER_NAME" "OLLAMA_HOST_PORT=${OLLAMA_HOST_PORT:-$DEFAULT_PORT}"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
            sed -i.bak -E "s|^[[:space:]]*${key}[[:space:]]*=.*$|${key}=${value}|" "$file" && rm -f "$file.bak"
        else
            printf '%s=%s\n' "$key" "$value" >> "$file"
        fi
    done
}

# Point the env file at a model, leaving every other setting in it alone
set_model() {
    local model="$1" file="$MODEL_ENV_FILE"
    if grep -qE '^[[:space:]]*OLLAMA_MODEL[[:space:]]*=' "$file" 2>/dev/null; then
        sed -i.bak -E "s|^[[:space:]]*OLLAMA_MODEL[[:space:]]*=.*$|OLLAMA_MODEL=${model}|" "$file" && rm -f "$file.bak"
    else
        printf 'OLLAMA_MODEL=%s\n' "$model" >> "$file"
    fi
}

active_mode() {
    if [ -f "$MODE_FILE" ]; then
        cat "$MODE_FILE"
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
        if compose exec -T "$SERVICE" \
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
    local mode="$1" model="$2" suffix=""
    if [ "$PROJECT" != "$DEFAULT_PROJECT" ]; then
        suffix=" $PROJECT"
    fi
    cat <<EOF

  mode     $mode
  model    $model
  version  $(current_version)
  name     $CONTAINER_NAME
  project  $PROJECT
  host     http://localhost:${OLLAMA_HOST_PORT:-$DEFAULT_PORT}

  chat     ./container.sh chat${suffix}
  code     ./container.sh shell${suffix}   (then: aider --model ollama_chat/$model)
  logs     ./container.sh logs${suffix}
  stop     ./container.sh stop${suffix}

EOF
}

# A container created outside this project but using the same name would stop
# "compose up" with a confusing error, so say what to do about it.
check_name_conflict() {
    local existing project

    existing="$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.ID}}' 2>/dev/null | head -1)"
    [ -n "$existing" ] || return 0

    # Containers made by this project carry its label and are replaced normally
    project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$existing" 2>/dev/null || echo "")"
    if [ "$project" = "$PROJECT" ]; then
        return 0
    fi

    warn "a container named '$CONTAINER_NAME' already exists and belongs to project '$project'"
    warn "use a different name to run alongside it:"
    warn ""
    warn "    ./container.sh start --name ${CONTAINER_NAME}2 --project ${PROJECT}2 --port 11436"
    warn ""
    warn "or remove the old one first:"
    warn ""
    warn "    docker rm -f $CONTAINER_NAME"
    warn ""
    exit 1
}

# ------------------------------------------------------------- resolution

# Whichever of the two you give, the other follows from it. Give a project and
# the container is named after it; give a name and the project follows from it.
name_given="${name_override:-${CONTAINER_NAME:-}}"
project_given="${project_override:-${COMPOSE_PROJECT_NAME:-}}"

if [ -n "$instance_arg" ] && [ -z "$project_given" ] && [ -z "$name_given" ]; then
    project_given="$(sanitize_project "$instance_arg")"
fi

if [ -n "$name_given" ] && [ -z "$project_given" ]; then
    project_given="$(sanitize_project "$name_given")"
fi
if [ -n "$project_given" ] && [ -z "$name_given" ]; then
    name_given="$(name_from_project "$project_given")"
fi

CONTAINER_NAME="${name_given:-$DEFAULT_NAME}"
PROJECT="${project_given:-$DEFAULT_PROJECT}"

if [ -n "$port_override" ]; then
    export OLLAMA_HOST_PORT="$port_override"
elif [ -n "$instance_arg" ] && [ -z "${OLLAMA_HOST_PORT:-}" ]; then
    # A second instance needs its own port, so take the next free one
    export OLLAMA_HOST_PORT="$(free_port 11436)"
fi

# Which image to run. Builds are tagged with their version and also as latest,
# so latest is the newest build unless a version is pinned.
IMAGE_TAG="${image_override:-${IMAGE_TAG:-latest}}"
export IMAGE_TAG

export CONTAINER_NAME

# Per-project files, so two instances do not overwrite each other's settings
MODE_FILE=".container-mode-${PROJECT}"
BUILT_FILE=".container-version"
MODEL_ENV_FILE=".env.${PROJECT}"

# ----------------------------------------------------------------- commands

# Build the image and tag it with its version, plus latest so that the newest
# build is what runs by default.
do_build() {
    local version="${1:-$(current_version)}"
    local tag="ai-container:${version}"

    info "building $tag"
    IMAGE_TAG="$version" compose build
    docker tag "$tag" "ai-container:latest"
    echo "$version" > "$BUILT_FILE"
    info "tagged $tag and ai-container:latest"
}

do_start() {
    local mode="${1:-$(active_mode)}"
    local model
    model="$(model_for_mode "$mode")"

    command -v docker >/dev/null 2>&1 || fail "docker is not installed"
    $COMPOSE version >/dev/null 2>&1 || fail "the docker compose plugin is not available"

    ensure_env
    set_model "$model"
    set_instance_settings
    echo "$mode" > "$MODE_FILE"

    local want have
    want="$(current_version)"
    have="$(built_version)"
    if [ "$want" != "$have" ]; then
        do_build "$want"
    else
        info "image is up to date (version $want)"
    fi

    check_name_conflict

    info "starting '$CONTAINER_NAME' in $mode mode (project $PROJECT)"
    compose up -d --remove-orphans

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
    printf 'name    %s\n' "$CONTAINER_NAME"
    printf 'project %s\n' "$PROJECT"
    printf 'env     %s\n' "$(grep -E '^OLLAMA_MODEL=' "$MODEL_ENV_FILE" 2>/dev/null || grep -E '^OLLAMA_MODEL=' "$ENV_FILE" 2>/dev/null || echo 'not set')"
    echo
    compose ps
    echo
    compose exec -T "$SERVICE" ollama list 2>/dev/null || true
}

case "$command_name" in
    build)
        do_build "$version_arg"
        ;;
    start)
        do_start "$mode_arg"
        ;;
    stop)
        info "stopping '$CONTAINER_NAME' (project $PROJECT)"
        compose down
        ;;
    restart)
        compose down
        do_start "$mode_arg"
        ;;
    status)
        do_status
        ;;
    logs)
        compose exec "$SERVICE" tail -f /var/log/ollama.log /var/log/ollama-bootstrap.log
        ;;
    shell)
        compose exec "$SERVICE" bash
        ;;
    models)
        compose exec "$SERVICE" ollama list
        ;;
    chat)
        compose exec "$SERVICE" ollama run "$(model_for_mode "$(active_mode)")"
        ;;
    claude)
        # Anything after the instance name is passed straight to Claude Code
        claude_args=()
        start_at=1
        [ -n "$instance_arg" ] && start_at=2
        for ((i = start_at; i < ${#positional[@]}; i++)); do
            claude_args+=("${positional[$i]}")
        done
        if [ ${#claude_args[@]} -gt 0 ]; then
            compose exec "$SERVICE" claude "${claude_args[@]}"
        else
            compose exec "$SERVICE" claude
        fi
        ;;
    signin)
        info "signing in to Ollama - a browser window opens, or paste a code"
        # A one-shot container: it starts Ollama, signs in, and stops again, so
        # nothing is left running. The container itself does not need to be up.
        compose run --rm --no-deps --entrypoint /usr/local/bin/ollama-signin "$SERVICE" signin
        ;;
    signout)
        info "signing out of Ollama"
        compose run --rm --no-deps --entrypoint /usr/local/bin/ollama-signin "$SERVICE" signout
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
