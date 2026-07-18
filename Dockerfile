FROM debian:bookworm-slim

ARG NODE_MAJOR=20
ARG TTYD_VERSION=1.7.7

ENV DEBIAN_FRONTEND=noninteractive

# --- base packages ------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        openssh-server \
        tmux \
        curl \
        wget \
        ca-certificates \
        gnupg \
        git \
        supervisor \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# --- Docker CLI (client only; talks to the host's docker.sock) ---------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js + Claude Code CLI ------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# --- ttyd (static binary; not packaged for Debian bookworm) -------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) TTYD_ARCH=x86_64 ;; \
        arm64) TTYD_ARCH=aarch64 ;; \
        armhf) TTYD_ARCH=armhf ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}"; \
    chmod +x /usr/local/bin/ttyd

# --- dev user -------------------------------------------------------------
# NOTE: no NOPASSWD entry is ever added for dev — sudo always prompts for a
# password so Claude Code cannot silently self-elevate.
RUN printf '%s\n' \
    '' \
    '# --- claude-code-docker: auto-attach to persistent tmux session ---' \
    'if [[ $- == *i* ]] && [[ -n "$SSH_TTY" ]] && [[ -z "$TMUX" ]]; then' \
    '    exec tmux new-session -A -s main' \
    'fi' \
    >> /etc/skel/.bashrc \
    && useradd -m -s /bin/bash dev \
    && echo 'dev ALL=(ALL:ALL) ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev \
    && visudo -cf /etc/sudoers.d/dev

# --- SSH server hardening -------------------------------------------------
# Host keys live under /etc/ssh/host_keys so that path alone can be bind
# mounted for persistence, without shadowing the rest of /etc/ssh (sshd_config
# etc.) the way bind-mounting /etc/ssh itself would.
RUN rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /etc/ssh/host_keys \
    && printf '%s\n' \
    'PermitRootLogin no' \
    'PasswordAuthentication yes' \
    'AllowUsers dev' \
    'UsePAM yes' \
    'HostKey /etc/ssh/host_keys/ssh_host_rsa_key' \
    'HostKey /etc/ssh/host_keys/ssh_host_ecdsa_key' \
    'HostKey /etc/ssh/host_keys/ssh_host_ed25519_key' \
    > /etc/ssh/sshd_config.d/dev.conf

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 7681

ENTRYPOINT ["/entrypoint.sh"]
