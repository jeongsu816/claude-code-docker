#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
DOCKER_SOCK="/var/run/docker.sock"

# Kept outside /home/dev deliberately: filebrowser serves that whole tree
# (--root /home/dev), so anything under it is browsable/downloadable through
# the file manager UI. Only a *hash* of the dev account's password is
# persisted here (never plaintext) — see the password-resolution block
# below for why a hash is enough and how it stays in sync with /etc/shadow.
DEV_STATE_DIR="/var/lib/claude-code-docker"
PASSWORD_HASH_FILE="${DEV_STATE_DIR}/.password_hash"

log() {
    echo "[entrypoint] $*"
}

mkdir -p "${DEV_STATE_DIR}"

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

# The above only ever fires once, ever, per DEV_HOME_PATH (gated on
# .bashrc), so anything added to /etc/skel afterward — like this — doesn't
# reach homes that were already bootstrapped before it existed. Unlike
# nvm/pyenv (optional extras, left as a documented manual migration),
# claude itself is core functionality, so this backfills it into an
# already-bootstrapped home on every boot instead: if it's missing, copy it
# in fresh and let `claude`'s own auto-updater keep it current from there
# (this container doesn't try to keep re-syncing it after the initial copy).
# ~/.local/bin is already on PATH via Debian's default /etc/skel/.profile,
# so no PATH wiring needed here (unlike the earlier npm --prefix approach
# this replaced).
if [ ! -e "${DEV_HOME}/.local/share/claude" ]; then
    mkdir -p "${DEV_HOME}/.local/bin" "${DEV_HOME}/.local/share" "${DEV_HOME}/.local/state"
    cp -r /etc/skel/.local/share/claude "${DEV_HOME}/.local/share/claude"
    [ -d /etc/skel/.local/state/claude ] && cp -r /etc/skel/.local/state/claude "${DEV_HOME}/.local/state/claude"
    chown -R "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.local"
    log "claude-code CLI를 ${DEV_HOME}/.local 에 새로 설치했습니다 (dev 계정 소유, 자체 업데이트 가능)."
fi
# The installer's own ~/.local/bin/claude symlink is an *absolute* path
# baked in at install time (`$HOME/.local/share/claude/versions/<version>`)
# — since this image installs with HOME=/etc/skel (see Dockerfile), that
# absolute path is always wrong once copied into /home/dev, whether via the
# block above or the whole-skel-copy path for a brand-new home. Recreate it
# as a relative symlink instead, which resolves correctly regardless of what
# $HOME actually is. Runs every boot (cheap, idempotent) rather than only
# alongside the copy above, so it also self-heals if this ever drifts.
CLAUDE_INSTALLED_VERSION="$(ls "${DEV_HOME}/.local/share/claude/versions/" 2>/dev/null | head -1)"
if [ -n "${CLAUDE_INSTALLED_VERSION}" ]; then
    ln -sf "../share/claude/versions/${CLAUDE_INSTALLED_VERSION}" "${DEV_HOME}/.local/bin/claude"
    chown -h "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.local/bin/claude"
fi

# Resolve the dev account's password on every boot, since /etc/shadow lives
# in the container's own filesystem (not a bind mount) and does NOT survive
# container recreation (docker compose down/up, image rebuild, etc.) the way
# DEV_STATE_DIR does. Only a *hash* is ever persisted, never plaintext:
#   - If PASSWORD_HASH_FILE exists, this isn't the first boot for this
#     DEV_SECRETS_PATH — reapply that exact hash via `chpasswd -e` (installs
#     an already-hashed password as-is, no re-hashing/plaintext involved).
#   - Otherwise, resolve a plaintext password once (from an older version's
#     leftover plaintext file, DEV_PASSWORD, or a fresh random value),
#     apply it normally, then persist only the resulting hash and forget
#     the plaintext.
# ACTUAL_PASSWORD stays empty except during that one first-boot path, where
# filebrowser bootstrap below still needs the plaintext once (in memory only
# — it's never written to disk).
ACTUAL_PASSWORD=""
if [ -f "${PASSWORD_HASH_FILE}" ]; then
    echo "${DEV_USER}:$(cat "${PASSWORD_HASH_FILE}")" | chpasswd -e
else
    # Earlier versions of this image persisted the password in plaintext,
    # at one of two now-retired locations. If either is present, this is a
    # migration, not a true first boot: reuse that value (so the real
    # password doesn't change out from under the user), then delete the
    # plaintext original once its hash is safely persisted below.
    LEGACY_PLAINTEXT_FILES=(
        "${DEV_HOME}/.initial_password"
        "${DEV_STATE_DIR}/.initial_password"
    )
    for legacy_file in "${LEGACY_PLAINTEXT_FILES[@]}"; do
        if [ -f "${legacy_file}" ]; then
            ACTUAL_PASSWORD="$(cat "${legacy_file}")"
            log "기존 평문 비밀번호 파일(${legacy_file})을 발견해 해시로 전환합니다. 평문 원본은 곧 삭제됩니다."
            break
        fi
    done
    if [ -z "${ACTUAL_PASSWORD}" ] && [ -n "${DEV_PASSWORD:-}" ]; then
        ACTUAL_PASSWORD="${DEV_PASSWORD}"
        log "dev 계정 비밀번호를 DEV_PASSWORD 환경변수 값으로 설정했습니다."
    fi
    if [ -z "${ACTUAL_PASSWORD}" ]; then
        # pipefail must be off for this one command: `head -c 20` exits as
        # soon as it has its 20 bytes, so `tr` reliably gets SIGPIPE on its
        # next write — a non-zero exit that pipefail would otherwise treat
        # as a hard failure under `set -e`, even though the substitution's
        # actual output is correct.
        ACTUAL_PASSWORD="$(set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
        log "=============================================="
        log " dev 계정 초기 비밀번호가 자동 생성되었습니다:"
        log " ${ACTUAL_PASSWORD}"
        log " 이 비밀번호는 지금 이 순간에만 로그로 출력되고, 평문으로는"
        log " 저장되지 않습니다 — 지금 안전한 곳에 따로 적어두세요."
        log " 잊어버렸다면: docker exec -u root <컨테이너> passwd ${DEV_USER}"
        log "=============================================="
    fi

    echo "${DEV_USER}:${ACTUAL_PASSWORD}" | chpasswd
    getent shadow "${DEV_USER}" | cut -d: -f2 >"${PASSWORD_HASH_FILE}"
    chmod 600 "${PASSWORD_HASH_FILE}"
    for legacy_file in "${LEGACY_PLAINTEXT_FILES[@]}"; do
        rm -f "${legacy_file}"
    done
    rm -f "${DEV_HOME}/.container_setup_done" "${DEV_STATE_DIR}/.container_setup_done"
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
    # filebrowser's own default minimum password length is 12, but that's
    # just Settings.MinimumPasswordLength (a DB-stored value, not hardcoded
    # into the binary) — lowered to 8 via --minimumPasswordLength on config
    # init below, to match this project's own random-password length and
    # not force DEV_PASSWORD to be longer than it needs to be.
    # ACTUAL_PASSWORD is only ever non-empty on the one boot where the
    # password hash was just (re)created above — if this DB is missing on
    # any other boot (e.g. someone deleted just FILEBROWSER_DATA_PATH), the
    # plaintext genuinely isn't available anymore to bootstrap it with.
    if [ -z "${ACTUAL_PASSWORD}" ]; then
        log "경고: filebrowser 계정이 없는데 평문 비밀번호를 보관하지 않아 자동으로 만들 수 없습니다."
        log "       filebrowser 웹 UI에서 직접 초기 설정을 진행하세요."
    elif [ "${#ACTUAL_PASSWORD}" -lt 8 ]; then
        log "경고: dev 비밀번호가 8자 미만이라 filebrowser 최소 비밀번호 길이(8자) 요구사항을 만족하지 못해 filebrowser 계정을 생성하지 않았습니다."
        log "       DEV_PASSWORD를 8자 이상으로 바꿔서 컨테이너를 재생성하거나, filebrowser 웹 UI에서 직접 초기 설정을 진행하세요."
    elif ! gosu "${DEV_USER}" filebrowser config init --database "${FILEBROWSER_DB}" --root "${DEV_HOME}" --minimumPasswordLength 8 >/tmp/filebrowser-init.log 2>&1; then
        log "경고: filebrowser 초기화에 실패했습니다 (아래 로그 참고). 웹 UI에서 직접 설정해야 할 수 있습니다."
        cat /tmp/filebrowser-init.log
    elif ! gosu "${DEV_USER}" filebrowser users add "${DEV_USER}" "${ACTUAL_PASSWORD}" --database "${FILEBROWSER_DB}" --perm.admin >/tmp/filebrowser-adduser.log 2>&1; then
        log "경고: filebrowser 관리자 계정 생성에 실패했습니다 (아래 로그 참고)."
        cat /tmp/filebrowser-adduser.log
    else
        log "filebrowser 관리자 계정(${DEV_USER})을 dev 계정과 동일한 비밀번호로 생성했습니다."
    fi
fi

# minimumPasswordLength는 Settings.MinimumPasswordLength로 DB에 저장되는
# 값이라, 위 config init은 최초 부팅(DB가 없을 때) 한 번만 적용한다 — DB가
# 이미 있던 채로 이미지를 올린 배포는 이 줄을 타지 않아 filebrowser 자체
# 기본값(12)이 그대로 남아있을 수 있다(실제로 겪은 사례). 매 부팅마다
# FILEBROWSER_MIN_PASSWORD_LENGTH 값으로 다시 맞춰서, DB가 어떤 경로로
# 만들어졌든 항상 원하는 값을 유지하도록 한다. filebrowser 서버가 아직
# 뜨기 전(supervisord 이전)이라 DB 잠금 걱정 없이 바로 적용 가능하다.
if [ -f "${FILEBROWSER_DB}" ]; then
    if ! gosu "${DEV_USER}" filebrowser config set --database "${FILEBROWSER_DB}" \
        --minimumPasswordLength "${FILEBROWSER_MIN_PASSWORD_LENGTH:-8}" >/tmp/filebrowser-minpwlen.log 2>&1; then
        log "경고: filebrowser 최소 비밀번호 길이 설정에 실패했습니다 (아래 로그 참고)."
        cat /tmp/filebrowser-minpwlen.log
    fi
fi

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
