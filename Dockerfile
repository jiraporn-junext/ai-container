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
    && nvm install 24 \
    && nvm alias default 24 \
    && nvm use default

# FIX: Lägg till den dolda bin-mappen permanent i systemets PATH så "claude" hittas överallt
ENV PATH="/root/.local/bin:$PATH"


# Ensure NVM automatically loads every time you attach/login to the container bash
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> /root/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /root/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> /root/.bashrc \ 
    && echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc


# Configure Supervisor to keep the Ollama server running automatically in the background
RUN mkdir -p /var/log/supervisor
RUN echo '[supervisord]\nnodaemon=true\n\n[program:ollama]\ncommand=ollama serve\nautostart=true\nautorestart=true\nstdout_logfile=/var/log/ollama.log\nstderr_logfile=/var/log/ollama.err.log' > /etc/supervisor/conf.d/ollama.conf

WORKDIR /home/workspace

# Launch supervisor to start Ollama server, then transition cleanly into bash
ENTRYPOINT ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]

