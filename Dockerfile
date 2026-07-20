# --- builder stage: compile the getrandom LD_PRELOAD shim -----------------
FROM debian:bookworm-slim AS shim-builder
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY getrandom_shim.c /tmp/getrandom_shim.c
RUN gcc -shared -fPIC -O2 -o /getrandom_shim.so /tmp/getrandom_shim.c -ldl

FROM debian:bookworm-slim

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
        vim \
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

# --- Claude Code CLI (Anthropic's native installer, not npm) --------------
# CLAUDE_CODE_VERSION defaults to latest and is left free to self-update at
# runtime (claude's built-in auto-updater). Setting it to a specific version
# instead pins that version — entrypoint.sh reads the marker file below and
# disables the auto-updater only in that case, so a pin actually sticks.
#
# An earlier version of this installed via `npm install -g` (which needed
# Node.js as a system apt package just for this). Reading the actual
# claude.exe binary's own strings (`strings` on the extracted npm package)
# showed it recognizes multiple install methods on its own — npm-global,
# npm-local, and a separate "native" method — and its own bundled guidance
# explicitly nudges npm-local installs toward switching to native
# (`Consider using native installation: \`claude install\``). The native
# installer (claude.ai/install.sh) needs no Node/npm at all — pure
# curl+bash, self-contained — so this drops the whole Node.js apt dependency
# in favor of it.
#
# Installed with HOME=/etc/skel (root, at build time) so it lands under
# /etc/skel/.local and /etc/skel/.claude, following the same pattern already
# used for nvm/pyenv: entrypoint.sh's first-run `cp -rn /etc/skel/.
# /home/dev/` carries it into /home/dev, genuinely dev-owned via the normal
# home-directory ownership path — no npm prefix, no /usr involvement, no
# write-permission workaround needed at all for the auto-updater to do its
# job. The installer bakes an *absolute* symlink
# (~/.local/bin/claude -> $HOME/.local/share/claude/versions/<version>)
# pointing at whatever $HOME was at install time — since that's /etc/skel
# here, it's always wrong once copied into /home/dev. entrypoint.sh fixes
# this up as a relative symlink instead (see there), which resolves
# correctly regardless of what $HOME actually is at runtime. Also see
# entrypoint.sh for the per-boot migration check that backfills this into
# *already*-bootstrapped homes (unlike nvm/pyenv, which only reaches
# brand-new ones) — this one's core functionality, not an optional extra,
# so it isn't left as a manual migration step. `~/.local/bin` doesn't need
# any PATH wiring of our own — it's already in Debian's default
# /etc/skel/.profile.
RUN HOME=/etc/skel bash -c "$(curl -fsSL https://claude.ai/install.sh)" -- "${CLAUDE_CODE_VERSION}" \
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

# --- PAM hook: keep the persisted password hash in sync with /etc/shadow --
# entrypoint.sh only ever applies the persisted hash *at boot*, so without
# this, an interactive `passwd`/`sudo passwd dev` change would work until
# the container is recreated, then silently get reverted to the old value.
# Appended after pam_permit.so in the "Additional block" this file's own
# header comment says is the place for local hooks — `optional` means the
# module's result is ignored entirely, so it can never block a login or a
# password change even if something about it fails. It also only runs on
# the success path: a failed password attempt hits pam_deny.so's
# `requisite` first and the stack stops before reaching this line at all.
COPY sync-dev-password-hash.sh /usr/local/sbin/sync-dev-password-hash.sh
RUN chmod +x /usr/local/sbin/sync-dev-password-hash.sh \
    && printf '%s\n' \
    'password	optional			pam_exec.so seteuid /usr/local/sbin/sync-dev-password-hash.sh' \
    >> /etc/pam.d/common-password

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
