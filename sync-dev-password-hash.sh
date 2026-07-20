#!/usr/bin/env bash
# Invoked by PAM (see /etc/pam.d/common-password, "optional pam_exec.so")
# after any successful password change for any user. Placed after
# pam_permit.so in the stack, so it only ever runs on the success path —
# a failed `passwd` attempt hits pam_deny.so's `requisite` first and never
# reaches this. Runs as an effective root (pam_exec's `seteuid` option), so
# it works whether `dev` changed their own password or root/sudo set it.
#
# `optional` in the PAM stack means this script's exit status is ignored —
# it can never block a login or a password change, even if it errors out.
# Deliberately not `set -e`: every step below already guards its own
# failure case explicitly, and letting the script hard-exit partway through
# is exactly the kind of surprise this file exists to avoid.
set -uo pipefail

[ "${PAM_USER:-}" = "dev" ] || exit 0

DEV_STATE_DIR="/var/lib/claude-code-docker"
HASH_FILE="${DEV_STATE_DIR}/.password_hash"

HASH="$(getent shadow dev | cut -d: -f2)"
[ -n "${HASH}" ] || exit 0

mkdir -p "${DEV_STATE_DIR}"
# Write-then-rename so a concurrent read (e.g. entrypoint.sh, though it only
# ever runs at boot, before any session could reach here) never sees a
# partially written file.
printf '%s' "${HASH}" >"${HASH_FILE}.tmp" && \
    chmod 600 "${HASH_FILE}.tmp" && \
    mv -f "${HASH_FILE}.tmp" "${HASH_FILE}"
