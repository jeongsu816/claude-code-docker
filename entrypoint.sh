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

if [ ! -f "${MARKER}" ]; then
    if [ -n "${DEV_PASSWORD:-}" ]; then
        echo "${DEV_USER}:${DEV_PASSWORD}" | chpasswd
        log "dev 계정 비밀번호를 DEV_PASSWORD 환경변수 값으로 설정했습니다."
    else
        GENERATED_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
        echo "${DEV_USER}:${GENERATED_PASSWORD}" | chpasswd
        printf '%s\n' "${GENERATED_PASSWORD}" >"${DEV_HOME}/.initial_password"
        chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.initial_password"
        chmod 600 "${DEV_HOME}/.initial_password"
        log "=============================================="
        log " dev 계정 초기 비밀번호가 자동 생성되었습니다:"
        log " ${GENERATED_PASSWORD}"
        log " (이 값은 ${DEV_HOME}/.initial_password 에도 저장됩니다)"
        log "=============================================="
    fi
    touch "${MARKER}"
    chown "${DEV_USER}:${DEV_USER}" "${MARKER}"
fi

if [ -S "${DOCKER_SOCK}" ]; then
    SOCK_GID="$(stat -c %g "${DOCKER_SOCK}")"
    EXISTING_GROUP="$(getent group "${SOCK_GID}" | cut -d: -f1 || true)"
    if [ -z "${EXISTING_GROUP}" ]; then
        groupadd -g "${SOCK_GID}" dockerhost
        EXISTING_GROUP="dockerhost"
    fi
    usermod -aG "${EXISTING_GROUP}" "${DEV_USER}"
    log "dev 사용자를 docker.sock 그룹(${EXISTING_GROUP}, gid=${SOCK_GID})에 추가했습니다."
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

exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
