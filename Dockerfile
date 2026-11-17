# Start from a clean, lightweight Ubuntu image
FROM ubuntu:22.04

# Prevent interactive prompts during package installations
ENV DEBIAN_FRONTEND=noninteractive

# Install core dependencies, compiler tools, supervisor, and zstd (required by Ollama)
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    bash \
    ca-certificates \
    supervisor \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# Install Ollama directly via its standard Linux installer script
RUN curl -fsSL https://ollama.com/install.sh | sh

# Install Claude Code globally using Anthropic's recommended native script
RUN curl -fsSL https://claude.ai/install.sh | bash

# Set up NVM directory environment variables
ENV NVM_DIR=/root/.nvm

# Install NVM and immediately install Node 24 as the default runtime environment
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install 24.12.0 \
    && nvm alias default 24.12.0 \
    && nvm use default

# FIX: Lägg till den dolda bin-mappen permanent i systemets PATH så "claude" hittas överallt
ENV PATH="/root/.local/bin:$PATH"

# Ollama server settings. Bind to all interfaces so the published port works, and
# raise the default 4096 token context, which is too small for coding tools.
ENV OLLAMA_HOST=0.0.0.0:11434
ENV OLLAMA_CONTEXT_LENGTH=16384


# Ensure NVM automatically loads every time you attach/login to the container bash
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> /root/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /root/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> /root/.bashrc \
    && echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc


# Makes sure the configured model is present in the local Ollama store on first start
COPY scripts/ollama-bootstrap.sh /usr/local/bin/ollama-bootstrap
RUN chmod +x /usr/local/bin/ollama-bootstrap

# One-shot sign-in: starts Ollama, signs in, and stops again, so signing in
# never leaves anything running in the background
COPY scripts/ollama-signin /usr/local/bin/ollama-signin
RUN chmod +x /usr/local/bin/ollama-signin

# Git wrapper that blocks pushing to a remote while leaving everything else
# working, so the container can commit but cannot publish anything. The real
# binary is moved off PATH so the wrapper is the only way to reach git.
COPY scripts/git-guard.sh /usr/local/bin/git
RUN mkdir -p /usr/local/libexec \
    && mv /usr/bin/git /usr/local/libexec/git \
    && chmod +x /usr/local/bin/git \
    && /usr/local/bin/git --version

# Version of the image, reported by "ai-container --version" inside the container
ARG VERSION=dev
ENV AI_CONTAINER_VERSION=${VERSION}
COPY VERSION /etc/ai-container/VERSION
COPY scripts/ai-container /usr/local/bin/ai-container
RUN chmod +x /usr/local/bin/ai-container

# Configure Supervisor to keep the Ollama server running automatically in the background
RUN mkdir -p /var/log/supervisor
RUN printf '%s\n' \
    '[program:ollama]' \
    'command=ollama serve' \
    'environment=OLLAMA_HOST="%(ENV_OLLAMA_HOST)s",OLLAMA_CONTEXT_LENGTH="%(ENV_OLLAMA_CONTEXT_LENGTH)s"' \
    'autostart=true' \
    'autorestart=true' \
    'startsecs=3' \
    'stdout_logfile=/var/log/ollama.log' \
    'stderr_logfile=/var/log/ollama.err.log' \
    'stdout_logfile_maxbytes=10MB' \
    'stderr_logfile_maxbytes=10MB' \
    '' \
    '[program:ollama-bootstrap]' \
    'command=/usr/local/bin/ollama-bootstrap' \
    'autostart=true' \
    'autorestart=false' \
    'startsecs=0' \
    'startretries=0' \
    'priority=20' \
    'stdout_logfile=/var/log/ollama-bootstrap.log' \
    'stderr_logfile=/var/log/ollama-bootstrap.err.log' \
    'stdout_logfile_maxbytes=10MB' \
    'stderr_logfile_maxbytes=10MB' \
    > /etc/supervisor/conf.d/ollama.conf

WORKDIR /home/workspace

# Run supervisor in the foreground so it stays PID 1 and keeps Ollama alive
ENTRYPOINT ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
