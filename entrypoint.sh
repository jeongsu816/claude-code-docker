#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
MARKER="${DEV_HOME}/.container_setup_done"
DOCKER_SOCK="/var/run/docker.sock"

log() {
    echo "[entrypoint] $*"
}

# The home directory is typically bind-mounted from the host, so unlike a
# named volume Docker does NOT seed it from the image on first use. Populate
# it from /etc/skel (which carries the tmux auto-attach .bashrc snippet)
# whenever it's missing the basics, then (re)assert ownership.
mkdir -p "${DEV_HOME}"
if [ ! -e "${DEV_HOME}/.bashrc" ]; then
    cp -rn /etc/skel/. "${DEV_HOME}/"
    chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"
else
    chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}"
fi

# Resolve the dev account's actual current password on every boot (not just
# first run), since ttyd and filebrowser auth below need it every time
# supervisord (re)starts them. .initial_password is the single source of
# truth for this once set — NOT re-derived from DEV_PASSWORD on every boot,
# because that env var could be changed or dropped from .env later while the
# Linux password (set once, on first run) stays whatever it was.
if [ ! -f "${MARKER}" ]; then
    if [ -n "${DEV_PASSWORD:-}" ]; then
        ACTUAL_PASSWORD="${DEV_PASSWORD}"
        log "dev 계정 비밀번호를 DEV_PASSWORD 환경변수 값으로 설정했습니다."
    else
        # pipefail must be off for this one command: `head -c 20` exits as
        # soon as it has its 20 bytes, so `tr` reliably gets SIGPIPE on its
        # next write — a non-zero exit that pipefail would otherwise treat
        # as a hard failure under `set -e`, even though the substitution's
        # actual output is correct.
        ACTUAL_PASSWORD="$(set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
        log "=============================================="
        log " dev 계정 초기 비밀번호가 자동 생성되었습니다:"
        log " ${ACTUAL_PASSWORD}"
        log " (이 값은 ${DEV_HOME}/.initial_password 에도 저장됩니다)"
        log "=============================================="
    fi
    echo "${DEV_USER}:${ACTUAL_PASSWORD}" | chpasswd
    # Always persisted (even when it came from DEV_PASSWORD), so subsequent
    # boots have a reliable value to read back regardless of what .env says
    # by then.
    printf '%s\n' "${ACTUAL_PASSWORD}" >"${DEV_HOME}/.initial_password"
    chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.initial_password"
    chmod 600 "${DEV_HOME}/.initial_password"
    touch "${MARKER}"
    chown "${DEV_USER}:${DEV_USER}" "${MARKER}"
else
    ACTUAL_PASSWORD="$(cat "${DEV_HOME}/.initial_password")"
fi

# Deliberately NOT adding dev to the socket's group here. docker.sock access
# is equivalent to unrestricted root on the NAS host, and dev's sudo already
# always requires a password (no NOPASSWD, see Dockerfile) specifically so
# Claude Code can't silently self-elevate. Putting dev directly in the
# socket's group would bypass that same protection for docker, letting
# Claude run `docker` (and, through it, reach the whole host) without any
# password prompt. Leaving dev out of the group means docker is only usable
# via `sudo docker ...`, which still prompts every time; root always has
# access to the socket regardless of group membership, so no group setup is
# needed for that path to work.
if [ -S "${DOCKER_SOCK}" ]; then
    log "${DOCKER_SOCK} 가 마운트되어 있습니다. dev는 이 소켓의 그룹에 속하지 않으므로, NAS의 Docker를 제어하려면 'sudo docker ...' 로 매번 비밀번호를 입력해야 합니다."
else
    log "경고: ${DOCKER_SOCK} 가 마운트되지 않았습니다. NAS의 docker를 제어할 수 없습니다."
fi

mkdir -p /etc/ssh/host_keys
for key_type in rsa ecdsa ed25519; do
    key_path="/etc/ssh/host_keys/ssh_host_${key_type}_key"
    if [ ! -f "${key_path}" ]; then
        ssh-keygen -q -t "${key_type}" -f "${key_path}" -N ""
        log "SSH 호스트 키(${key_type})를 새로 생성했습니다."
    fi
done

if [ -f "${DEV_HOME}/.ssh/authorized_keys" ]; then
    chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.ssh"
    chmod 700 "${DEV_HOME}/.ssh"
    chmod 600 "${DEV_HOME}/.ssh/authorized_keys"
fi

mkdir -p /var/run/sshd

# filebrowser's own account DB lives outside /home/dev (the directory it
# serves) so its credentials/settings aren't part of the tree it exposes to
# the file manager UI. Bootstrap a single admin account on first run only,
# sharing the dev account's password — later changes made via the
# filebrowser UI are left alone on subsequent boots.
FILEBROWSER_DATA_DIR="/var/lib/filebrowser"
FILEBROWSER_DB="${FILEBROWSER_DATA_DIR}/filebrowser.db"
mkdir -p "${FILEBROWSER_DATA_DIR}"
chown "${DEV_USER}:${DEV_USER}" "${FILEBROWSER_DATA_DIR}"
if [ ! -f "${FILEBROWSER_DB}" ]; then
    # filebrowser refuses passwords under 12 chars; a custom DEV_PASSWORD
    # could be shorter. Check first — letting `users add` fail here would
    # otherwise abort the whole entrypoint (set -e) and take sshd/ttyd/claude
    # down with it over what's just a filebrowser-specific limitation.
    if [ "${#ACTUAL_PASSWORD}" -lt 12 ]; then
        log "경고: dev 비밀번호가 12자 미만이라 filebrowser 최소 비밀번호 길이(12자) 요구사항을 만족하지 못해 filebrowser 계정을 생성하지 않았습니다."
        log "       DEV_PASSWORD를 12자 이상으로 바꿔서 컨테이너를 재생성하거나, filebrowser 웹 UI에서 직접 초기 설정을 진행하세요."
    elif ! gosu "${DEV_USER}" filebrowser config init --database "${FILEBROWSER_DB}" --root "${DEV_HOME}" >/tmp/filebrowser-init.log 2>&1; then
        log "경고: filebrowser 초기화에 실패했습니다 (아래 로그 참고). 웹 UI에서 직접 설정해야 할 수 있습니다."
        cat /tmp/filebrowser-init.log
    elif ! gosu "${DEV_USER}" filebrowser users add "${DEV_USER}" "${ACTUAL_PASSWORD}" --database "${FILEBROWSER_DB}" --perm.admin >/tmp/filebrowser-adduser.log 2>&1; then
        log "경고: filebrowser 관리자 계정 생성에 실패했습니다 (아래 로그 참고)."
        cat /tmp/filebrowser-adduser.log
    else
        log "filebrowser 관리자 계정(${DEV_USER})을 dev 계정과 동일한 비밀번호로 생성했습니다."
    fi
fi

# ttyd only supports passing credentials as a CLI argument (-c user:pass),
# so it's threaded through via supervisord's %(ENV_TTYD_PASSWORD)s
# expansion. ttyd is a direct supervisord child, so a plain export here is
# enough (unlike DISABLE_AUTOUPDATER below, it doesn't need an SSH login
# session to see it).
export TTYD_PASSWORD="${ACTUAL_PASSWORD}"

# Only disable claude's auto-updater when a specific CLAUDE_CODE_VERSION was
# pinned at build time (see /etc/claude-code-version-pin, written by the
# Dockerfile). Left at "latest", claude is free to self-update as normal.
# Set two ways since the two access paths inherit environment differently:
# `export` covers processes forked directly from this script (supervisord ->
# ttyd -> tmux), while /etc/environment is what PAM applies to fresh SSH
# login sessions, which do NOT simply inherit sshd's own process env.
if [ -f /etc/claude-code-version-pin ] && [ "$(cat /etc/claude-code-version-pin)" != "latest" ]; then
    export DISABLE_AUTOUPDATER=1
    if ! grep -q '^DISABLE_AUTOUPDATER=' /etc/environment 2>/dev/null; then
        echo 'DISABLE_AUTOUPDATER=1' >> /etc/environment
    fi
    log "CLAUDE_CODE_VERSION이 $(cat /etc/claude-code-version-pin) 로 고정되어 있어 자동 업데이트를 비활성화합니다."
fi

exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
