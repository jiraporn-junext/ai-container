# ai-container

A Docker container that runs [Claude Code](https://claude.com/claude-code) with an LLM served by
[Ollama](https://ollama.com) inside the container — either a model running on your own machine, or a
cloud model served by Ollama. Either way there is no Anthropic API key and no per-token cost.

The container ships with:

- **Ollama** — the model server, running in the background under Supervisor
- **Claude Code** — pointed at Ollama's Anthropic-compatible API, so every session uses that model
- **Node 24.12.0** via NVM

## Quick start

```bash
./container.sh start local     # model runs on this machine
./container.sh start cloud     # model runs on Ollama's GPUs
./container.sh chat            # talk to it
```

The first start downloads the model into the `ollama-models` volume. Later starts reuse it.

## Local or cloud

|  | `local` | `cloud` |
| --- | --- | --- |
| Default model | `qwen3:1.7b` | `minimax-m3:cloud` |
| Where it runs | your CPU, inside the container | Ollama's GPUs |
| First start | downloads ~1.4 GB of weights | downloads nothing |
| Speed | ~3-4 tokens/second on CPU | as fast as the provider |
| Needs an Ollama account | no | usually yes — `./container.sh signin` |
| Needs the internet | only to download the model | yes, for every request |

Both modes expose the same API on `localhost:11435`, so Claude Code, Aider and everything else work
the same way with either one.

```bash
./container.sh start local     # switch to the local model
./container.sh start cloud     # switch to the cloud model
./container.sh start            # reuse whichever mode you used last
```

Cloud models need an Ollama account. Sign in once:

```bash
./container.sh signin          # opens a browser, or prints a code to paste
```

Signing in runs as a **one-shot container**: it starts Ollama, signs in, and stops again. The
credentials are written to the `ollama-models` volume, so the main container can be stopped and
started whenever you like — and signing in works even when it is already stopped. Use
`./container.sh signout` to remove the credentials again.

The mode is remembered in `.container-mode`, and the model is written into `.env` so plain
`docker compose` commands keep working too. Override the models with `LOCAL_MODEL` and
`CLOUD_MODEL`:

```bash
LOCAL_MODEL=qwen3:4b CLOUD_MODEL=gpt-oss:120b-cloud ./container.sh start cloud
```

## Versioning

The version lives in the `VERSION` file at the repo root, in semver form, and is the single source of
truth. It is baked into the image, so the container can report which release it is:

```bash
./container.sh version                        # 2.0.0
docker compose exec claude-cli ai-container --version
docker compose exec claude-cli ai-container    # version, endpoints, active model
```

To cut a release:

```bash
echo 2.1.0 > VERSION
git add VERSION && git commit -m "..." && git tag -a 2.1.0 -m "..."
```

The next `./container.sh start` notices the version changed and rebuilds the image with it. Releases
are tagged in semver form — `1.0.0` is the original container, `2.0.0` added the local and cloud
model support.

## Git inside the container

Git is installed in the image, and the container has your real repository mounted, so it is allowed
to work on it — commit, branch, merge, pull and diff all work normally. **Pushing to a remote is
blocked**, so the container can never publish anything on its own:

```
$ git push
git push is disabled inside the ai-container.
The repository is your own on the host - run it there instead.
Set GIT_ALLOW_PUSH=1 to override this for a single command.
```

This is enforced by a `git` wrapper on `PATH`; the real binary is moved out of `PATH` so it cannot be
reached by absolute path either. To push for real, run `git push` on your Mac, or set
`GIT_ALLOW_PUSH=1` for a single command inside the container.

Your host's `~/.gitconfig` is **not** mounted in. The container gets its own git setup — the
`squash` alias you have, `safe.directory` so mounted repositories are trusted, and the identity from
`GIT_USER_NAME` / `GIT_USER_EMAIL` in `.env`:

```
GIT_USER_NAME=Jiraporn Johansson
GIT_USER_EMAIL=jiraporn.junext@gmail.com
```

## What lands on your host

| Where | What | Notes |
| --- | --- | --- |
| `${WORKSPACE_PATH}` → `/home/workspace` | your project folder | The only bind mount. Anything the container writes there — files Claude Code edits, build output, git operations — is written straight to your Mac. |
| `ai-container_ollama-models` | model weights, and your Ollama identity after `signin` | ~1.4 GB for the local model, nothing for a cloud model. |
| `ai-container_claude-config` | Claude Code settings, tokens, history | |
| `ai-container_nvm-data` | installed Node versions | |
| `ai-container:local` | the image itself | ~1.5 GB plus Docker's build cache. |
| repo folder | `.env`, `.container-mode`, `.container-version` | Small, gitignored, written by `container.sh`. |

The three named volumes live in Docker's own storage, not in your project folder. On macOS that is
inside Docker Desktop's data directory:

```bash
docker volume inspect ai-container_ollama-models   # where it actually is
docker system df                                   # how much space Docker is using
```

Nothing else is written to your Mac. The container's port is bound to `127.0.0.1` on purpose —
Ollama's API has no authentication, so leaving it on all interfaces would let anyone on your network
use your model, and in cloud mode spend your Ollama account's quota.

To remove everything the container created:

```bash
./container.sh stop                                # keeps the volumes
docker compose down -v                             # also deletes the models and Claude config
```

## Everyday commands

| Command | What it does |
| --- | --- |
| `./container.sh start [local\|cloud]` | Build if needed, start, and wait for the model |
| `./container.sh stop` | Stop and remove the container (volumes are kept) |
| `./container.sh restart [local\|cloud]` | Restart, optionally switching mode |
| `./container.sh status` | Container state and the active model |
| `./container.sh chat` | Chat with the active model |
| `./container.sh shell` | Open a shell inside the container |
| `./container.sh models` | List the models in the container |
| `./container.sh logs` | Follow the Ollama server and pull logs |
| `./container.sh signin` | Sign in to Ollama (needed for some cloud models) |
| `./container.sh help` | Show usage |

`make up`, `make down`, `make shell`, `make chat` and the rest are still available and wrap the same
thing, so `docker compose exec claude-cli bash` works just as well if you prefer neither.

## Using Ollama without Claude Code

Claude Code is only one client. The Ollama server inside the container speaks the usual APIs, so you
can chat with it and drive coding tools from it directly.

### Chatting

**Inside the container**

```bash
make chat                                     # interactive REPL
docker compose exec claude-cli ollama run qwen3:1.7b
docker compose exec claude-cli ollama run qwen3:1.7b "Explain this diff in one line"
git diff | docker compose exec -T claude-cli ollama run qwen3:1.7b "Review this change"
```

The REPL has slash commands — `/set system`, `/show`, `/set parameter num_ctx 32768` — and `Ctrl+G`
opens your editor for a longer prompt.

**From your Mac** — the container publishes Ollama on `localhost:11435`

```bash
OLLAMA_HOST=localhost:11435 ollama run qwen3:1.7b
OLLAMA_HOST=localhost:11435 ollama list
```

**Over HTTP** — Ollama exposes the Anthropic, OpenAI and native APIs

```bash
# Anthropic Messages API (what Claude Code uses)
curl http://localhost:11435/v1/messages \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3:1.7b","max_tokens":200,"messages":[{"role":"user","content":"Hello"}]}'

# OpenAI Chat Completions API (works with most tools and SDKs)
curl http://localhost:11435/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3:1.7b","messages":[{"role":"user","content":"Hello"}]}'

# Plain Ollama API
curl http://localhost:11435/api/chat \
  -d '{"model":"qwen3:1.7b","messages":[{"role":"user","content":"Hello"}]}'
```

### Coding without Claude Code

Point any tool that speaks the OpenAI API at the container.

**Aider** (terminal, edits your files directly)

```bash
pip install aider-install && aider-install
export OLLAMA_API_BASE=http://localhost:11435
cd your-project && aider --model ollama_chat/qwen3:1.7b
```

Use the `ollama_chat/` prefix so aider uses the chat endpoint. Aider needs a larger context than
Ollama's default — set `OLLAMA_CONTEXT_LENGTH=16384` in `.env` and restart.

**OpenCode** (terminal agent)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "ollama": {
      "settings": { "baseURL": "http://localhost:11435" },
      "models": { "qwen3:1.7b": { "name": "Qwen3 1.7B" } }
    }
  }
}
```

**Cline / Roo Code / Continue** (VS Code): provider **Ollama**, base URL `http://localhost:11435`
(do **not** append `/v1`), API key blank, model id `qwen3:1.7b`. Turn on "Use Compact Prompt" to
save context.

**`ollama launch`** wires up an integration for you — it knows about OpenCode, Cline, VS Code, Qwen
Code, Codex and others:

```bash
ollama launch opencode --model qwen3:1.7b
ollama launch cline
ollama launch vscode
```

The port is deliberately **not** `11434` so it does not collide with an Ollama you already run natively
on your Mac.

## Models

The default is `qwen3:1.7b` — small enough to run on CPU, and it supports **native tool calls**, which
Claude Code depends on.

> **Pick a model that supports tools.** Some models, including `qwen2.5-coder:*`, write a tool call out
> as plain JSON text instead of emitting a real `tool_use` block. Claude Code then never actually calls
> the tool, so the session looks like it is working but nothing happens. Check before switching:
>
> ```bash
> docker compose exec claude-cli ollama show <model> | grep tools
> ```

Change the model in `.env`:

```
OLLAMA_MODEL=qwen2.5:3b
```

Then `make down && make up` to pull the new model. Anything from the Ollama library works.

Rough requirements for the popular sizes:

| Model | Download | RAM needed | Tool calls | Comfortable on CPU-only? |
| --- | --- | --- | --- | --- |
| `qwen3:0.6b` | ~520 MB | ~1 GB | yes | yes, fastest |
| `qwen2.5:1.5b` | ~1 GB | ~2 GB | yes | yes |
| `qwen3:1.7b` | ~1.4 GB | ~2.5 GB | yes | yes, default |
| `qwen2.5:3b` | ~2 GB | ~3.5 GB | yes | slowly |
| `qwen3:8b` | ~5.2 GB | ~6 GB | yes | painfully slow |
| `qwen2.5-coder:1.5b` | ~1 GB | ~2 GB | **no** | avoid |

## Configuration

`.env` is read by Docker Compose on every command:

| Variable | Default | Meaning |
| --- | --- | --- |
| `OLLAMA_MODEL` | `qwen3:1.7b` | Model pulled on first start and used by Claude Code |
| `OLLAMA_HOST_PORT` | `11435` | Host port mapped to Ollama's `11434` in the container |
| `OLLAMA_CONTEXT_LENGTH` | `16384` | Context window for the model |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | `ai-container` | Identity used for commits inside the container |
| `WORKSPACE_PATH` | `/Users/jirapornjohansson/workspace` | Host folder mounted at `/home/workspace` |

## Using the Anthropic API instead

The container is set up to always use the local model. To point a single session at the real API
instead, override the endpoint:

```bash
docker compose run --rm \
  -e ANTHROPIC_BASE_URL=https://api.anthropic.com \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  claude-cli
```

## Memory

The container has **no memory cap by default** — it can use everything the Docker Desktop VM has
been given. To check what it is actually using:

```bash
docker stats ai_container
docker inspect -f '{{.HostConfig.Memory}}' ai_container   # 0 means no limit
```

**To give it more**, the limit that matters is Docker Desktop's own: **Settings → Resources →
Memory**, then Apply & Restart. The container draws from that pool, so raising it is what actually
makes more memory available.

To put a ceiling on this container so it cannot starve the rest of your Mac, set a limit in `.env`:

```
MEM_LIMIT=8g
```

Then `./container.sh start` to apply it. `0` means no limit.

Two Ollama settings also move the needle:

| Setting | Effect |
| --- | --- |
| `OLLAMA_CONTEXT_LENGTH` | Bigger context means a bigger KV cache, so more RAM per model. 16384 is comfortable; 32768 roughly doubles the cache. |
| `OLLAMA_KEEP_ALIVE` | How long a model stays loaded after use (`5m` by default). A longer keep-alive means less reloading, at the cost of holding memory. |
| `OLLAMA_MAX_LOADED_MODELS` | How many models stay resident at once. Keep it at 1 on a small machine. |

## Performance

A Linux container on macOS cannot use the Mac's Metal GPU, so Ollama runs on the CPU only.

Measured on an ARM server CPU with `qwen3:1.7b`: about 3-4 tokens/second while generating, and roughly
15 seconds for a single tool-calling turn. A complete three-turn exchange through Claude Code took
about two minutes. On an Apple Silicon Mac expect several times better, but still well below the speed
of the hosted API — the local model is best for small, well-scoped edits rather than long refactors.

The first token takes a while because Claude Code sends a long system prompt plus every tool
definition, and Qwen3 emits a reasoning block before each tool call.

If you want full GPU speed, run Ollama natively on the Mac and point the container at it with
`http://host.docker.internal:11434` instead of `http://localhost:11434`.

On Linux with an NVIDIA GPU, add the runtime flags below to give the container access to the GPU:

```yaml
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

## Troubleshooting

**Claude Code says "There's an issue with the selected model".** The container sets `ANTHROPIC_MODEL` so
the session uses your local model. If you override `ANTHROPIC_BASE_URL` or `ANTHROPIC_MODEL` yourself,
make sure the value is a tag that `ollama list` shows.

**Claude Code warns `unrecognized_model`.** Harmless. It just means the model is not one of Anthropic's
own names.

**Ollama rejects the model name.** Claude Code asks for the 1M-context variant and sends the name as
`qwen3:1.7b[1m]`, which Ollama answers with a 400. The container sets
`CLAUDE_CODE_DISABLE_1M_CONTEXT=1` to prevent that. Keep it set if you change the model.

**The model never finishes downloading.** The pull runs in the background on first start. Watch it with
`make logs` or check `docker compose logs claude-cli`. Retry manually with `make pull`.

**`--dangerously-skip-permissions` is refused.** The container runs as root, and Claude Code refuses
that flag for root. Use the normal approval prompt, or pre-grant specific tools in
`~/.claude/settings.json` inside the container.

**Port already in use.** Set a different `OLLAMA_HOST_PORT` in `.env`.

**Ollama is not reachable from the host.** The server binds to `0.0.0.0` inside the container, which is
what makes the published port work. Check `docker compose ps` for the health status.

## Layout

```
Dockerfile                   image: Ollama + Claude Code + Node 24
docker-compose.yml           service wiring, volumes, Claude Code -> Ollama
container.sh                 start/stop the container, switch between local and cloud models
scripts/ollama-bootstrap.sh  pulls the model on first start
scripts/ollama-signin        one-shot sign-in that leaves nothing running
scripts/ai-container         reports the version and endpoints inside the container
scripts/git-guard.sh         git wrapper that blocks pushing to a remote
Makefile                     convenience wrappers around docker compose
VERSION                      the current version, in semver form
.env.example                 configuration template
```
