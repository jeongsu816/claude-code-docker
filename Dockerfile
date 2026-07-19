# --- builder stage: compile the getrandom LD_PRELOAD shim -----------------
FROM debian:bookworm-slim AS shim-builder
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY getrandom_shim.c /tmp/getrandom_shim.c
RUN gcc -shared -fPIC -O2 -o /getrandom_shim.so /tmp/getrandom_shim.c -ldl

FROM debian:bookworm-slim

ARG NODE_MAJOR=20
ARG TTYD_VERSION=1.7.7
ARG FILEBROWSER_VERSION=2.63.18
ARG NVM_VERSION=0.40.6
ARG PYENV_VERSION=v2.8.1
ARG DEV_UID=1000
ARG DEV_GID=1000
ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

# --- base packages ------------------------------------------------------
# build-essential/gdb/cmake/pkg-config: baked-in C/C++ toolchain (no
# per-project version needed, unlike Node/Python below, so no reason to make
# this a user-space/no-sudo-required install).
# The libssl-dev..liblzma-dev block is pyenv's own documented "suggested
# build environment" for Debian/Ubuntu — without these, `pyenv install`
# either fails outright or silently produces a Python missing ssl/sqlite3/etc.
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
        build-essential \
        gdb \
        cmake \
        pkg-config \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        libncursesw5-dev \
        xz-utils \
        tk-dev \
        libxml2-dev \
        libxmlsec1-dev \
        libffi-dev \
        liblzma-dev \
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
# CLAUDE_CODE_VERSION defaults to latest and is left free to self-update at
# runtime (claude's built-in auto-updater). Setting it to a specific version
# instead pins that version — entrypoint.sh reads the marker file below and
# disables the auto-updater only in that case, so a pin actually sticks.
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force \
    && echo "${CLAUDE_CODE_VERSION}" > /etc/claude-code-version-pin

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

# --- filebrowser (static binary; web file manager for /home/dev) --------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) FB_ARCH=amd64 ;; \
        arm64) FB_ARCH=arm64 ;; \
        armhf) FB_ARCH=armv7 ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/filebrowser.tar.gz \
        "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VERSION}/linux-${FB_ARCH}-filebrowser.tar.gz"; \
    tar -xzf /tmp/filebrowser.tar.gz -C /usr/local/bin filebrowser; \
    chmod +x /usr/local/bin/filebrowser; \
    rm -f /tmp/filebrowser.tar.gz

# --- dev user -------------------------------------------------------------
# UID/GID are pinned (not left to useradd's default assignment) so that
# ownership of bind-mounted host paths (DEV_HOME_PATH etc.) stays valid
# across image rebuilds, not just container recreation.
# NOTE: no NOPASSWD entry is ever added for dev — sudo always prompts for a
# password so Claude Code cannot silently self-elevate.
RUN printf '%s\n' \
    '' \
    '# --- claude-code-docker: auto-attach to persistent tmux session ---' \
    'if [[ $- == *i* ]] && [[ -n "$SSH_TTY" ]] && [[ -z "$TMUX" ]]; then' \
    '    exec tmux new-session -A -s main' \
    'fi' \
    >> /etc/skel/.bashrc \
    && groupadd -g "${DEV_GID}" dev \
    && useradd -m -u "${DEV_UID}" -g "${DEV_GID}" -s /bin/bash dev \
    && echo 'dev ALL=(ALL:ALL) ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev \
    && visudo -cf /etc/sudoers.d/dev

# --- nvm/pyenv (user-space, no sudo needed) --------------------------------
# Installed under /etc/skel so entrypoint.sh's first-run `cp -rn /etc/skel/.`
# seeding carries them into /home/dev automatically, same as the tmux
# .bashrc snippet above. Deliberately not baked in as a system-wide Node/
# Python the way build-essential is for C/C++ above: the whole point is
# picking a version per project without ever needing root, which nvm/pyenv
# both do by installing entirely under $HOME. No default Node/Python version
# is pre-installed here — that would fix a version that may not match
# whatever a given project actually needs; `nvm install`/`pyenv install` pull
# one on demand.
RUN mkdir -p /etc/skel/.nvm \
    && NVM_DIR=/etc/skel/.nvm PROFILE=/dev/null \
       bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash" \
    && git clone --branch "${PYENV_VERSION}" --depth 1 https://github.com/pyenv/pyenv.git /etc/skel/.pyenv \
    && printf '%s\n' \
        '' \
        '# --- claude-code-docker: nvm ---' \
        'export NVM_DIR="$HOME/.nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' \
        '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' \
        '' \
        '# --- claude-code-docker: pyenv ---' \
        'export PYENV_ROOT="$HOME/.pyenv"' \
        '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' \
        'eval "$(pyenv init -)"' \
        >> /etc/skel/.bashrc

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

COPY --from=shim-builder /getrandom_shim.so /usr/local/lib/getrandom_shim.so
# Works around Bun's getrandom() crash on kernels < 3.17 (see
# getrandom_shim.c). A no-op passthrough on kernels that do have
# getrandom(2), so this is safe to leave on unconditionally. Set only after
# the .so is copied in, so earlier RUN steps don't warn about a missing
# preload target.
ENV LD_PRELOAD=/usr/local/lib/getrandom_shim.so

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 7681 8080

ENTRYPOINT ["/entrypoint.sh"]
