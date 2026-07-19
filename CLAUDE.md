# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image that runs Claude Code persistently on a host with Docker (developed against a Synology NAS), reachable over SSH, a web terminal (ttyd), and a web file manager (filebrowser). Sessions survive disconnects via tmux. See `README.md` for user-facing deployment/usage instructions — this file is about developing the image itself.

## Commands

There is no automated test suite, linter, or CI config in this repo. Verification means actually building the image and exercising it.

```bash
# Fast syntax check before a full rebuild (rebuilds are slow)
bash -n entrypoint.sh

# Build (default: latest claude-code, dev UID/GID 1000)
docker build -t claude-code-docker:test .

# Build for another arch (NAS may be ARM)
docker buildx build --platform linux/arm64 -t claude-code-docker:test --load .

# Build with a pinned claude-code version (tests the pre-Bun fallback path)
docker build --build-arg CLAUDE_CODE_VERSION=2.1.112 -t claude-code-docker:test .

# Smoke test the CLI without starting supervisord/sshd/ttyd
docker run --rm --entrypoint sh claude-code-docker:test -c 'gosu dev claude --version'

# Full local run: copy .env.example to .env, point the *_PATH vars at scratch
# directories (not real NAS paths), then:
docker compose up -d --build
docker logs claude-code-docker
```

For interactive checks (SSH login, tmux auto-attach, ttyd/filebrowser HTTP auth), there's no `sshpass` in the base images used for testing — spin up a throwaway `debian:bookworm-slim` container with `--network host`, install `expect` + `openssh-client` in it, and drive an `expect` script against the published SSH port. `curl` against the ttyd/filebrowser ports covers non-interactive auth checks (`curl -u dev:PASSWORD ...`, `curl -X POST .../api/login ...` for filebrowser).

To test changes to `getrandom_shim.c` without access to a genuinely old kernel, simulate one with a seccomp profile that returns `ENOSYS` for `getrandom`:

```json
{"defaultAction":"SCMP_ACT_ALLOW","archMap":[{"architecture":"SCMP_ARCH_X86_64","subArchitectures":["SCMP_ARCH_X86","SCMP_ARCH_X32"]}],
 "syscalls":[{"names":["getrandom"],"action":"SCMP_ACT_ERRNO","errnoRet":38}]}
```
```bash
docker run --rm --security-opt seccomp=<that-file> --entrypoint sh claude-code-docker:test -c 'gosu dev claude --version'
```
Without the shim this reproduces the real crash (`panic: getrandom failed: errno 38`); with it, `claude` should run normally.

Always clean up test containers/images/scratch dirs after manual verification (`docker rm -f`, `docker rmi`, `rm -rf` on scratch paths) — nothing here is meant to linger.

## Architecture

### Multi-stage Dockerfile
1. `shim-builder` stage: compiles `getrandom_shim.c` with gcc, kept isolated so the final image doesn't carry a C toolchain.
2. Final stage (`debian:bookworm-slim`): installs sshd/tmux/docker-CLI/Node+claude-code via apt/npm; installs `ttyd` and `filebrowser` as static binaries downloaded per-architecture in Dockerfile `RUN` steps (neither is packaged for Debian) rather than via apt; creates the `dev` user with UID/GID pinned via build args (not left to `useradd` defaults, so bind-mounted file ownership survives rebuilds); copies in the compiled shim, `entrypoint.sh`, `supervisord.conf`.

### Runtime flow: entrypoint.sh → supervisord → {sshd, ttyd, filebrowser}
`entrypoint.sh` runs once as root at container start, does first-run/every-boot setup, then `exec`s into `supervisord` (which becomes PID 1's replacement and supervises the three long-running services). Order of operations in `entrypoint.sh` matters and is worth reading top to bottom before editing it. Notable pieces:

- **Home directory seeding**: bind mounts (see below) aren't pre-populated from the image the way named volumes are, so entrypoint.sh manually `cp -rn`s `/etc/skel` into `/home/dev` on first use — this is where the tmux auto-attach `.bashrc` snippet comes from.
- **Password resolution**: on first run, `ACTUAL_PASSWORD` comes from `DEV_PASSWORD` if set, otherwise a random 20-char string — either way it's written to `/home/dev/.initial_password`, which becomes the single source of truth on every later boot. It is deliberately *not* re-derived from `DEV_PASSWORD` after first run, because that env var could later be changed or removed from `.env` while the real Linux password (set once) stays the same; re-deriving would desync ttyd/filebrowser auth from the actual password.
- **docker.sock access is sudo-gated, deliberately**: entrypoint.sh does *not* add `dev` to the socket's group. `dev`'s sudo already always requires a password (no NOPASSWD, see below) specifically so Claude Code can't self-elevate — putting `dev` directly in the socket's group would open the exact same bypass for `docker` (docker.sock access ≈ root on the host), letting Claude reach or disrupt real running containers on the NAS without a human ever entering a password. Docker is only usable via `sudo docker ...`, which still prompts every time; root always has access to the socket regardless of group membership, so no group setup is needed for that path.
- **SSH host keys**: generated under `/etc/ssh/host_keys` if missing.
- **filebrowser bootstrap**: creates a `dev` admin account (same password) on first run only, in a database kept outside `/home/dev`. Guards against filebrowser's 12-character minimum password requirement explicitly (skip + warn, not crash) — letting `filebrowser users add` fail here used to abort the whole entrypoint under `set -e` and take sshd/ttyd/claude down with it.
- **`TTYD_PASSWORD` export**: every boot (not just first run), since ttyd has no persistent account store of its own — supervisord reconstructs its `-c dev:PASSWORD` flag from this on every start via `%(ENV_TTYD_PASSWORD)s`.
- **Conditional `DISABLE_AUTOUPDATER`**: only set when `CLAUDE_CODE_VERSION` pinned a specific version at build time (via `/etc/claude-code-version-pin`); left alone for the default `latest` build so claude can self-update normally.

### SSH sessions vs. direct fork/exec: environment inheritance gotcha
Anything `entrypoint.sh` exports before `exec supervisord` reaches supervisord's direct children fine (ttyd, filebrowser). It does **not** reach SSH login sessions — sshd's PAM-based session setup rebuilds the environment rather than inheriting sshd's own process env. Any variable that needs to be visible in an SSH shell must *also* be written to `/etc/environment` (see the `DISABLE_AUTOUPDATER` handling for the pattern). This cost real debugging time once; don't reintroduce the same bug for a new variable.

### Bind mounts, not named volumes — and why some paths are split out
All persistent state uses bind mounts to host paths from `.env` (`DEV_HOME_PATH`, `DEV_SSH_HOSTKEYS_PATH`, `FILEBROWSER_DATA_PATH`), chosen so the NAS admin can snapshot/back up the underlying folders directly. Two things are deliberately mounted *outside* `/home/dev` rather than nested under it:
- `/etc/ssh/host_keys` (not all of `/etc/ssh`) — mounting the whole directory would shadow the image's baked-in `sshd_config`/`sshd_config.d/dev.conf` with an empty host directory on first use.
- `/var/lib/filebrowser` (filebrowser's own account/settings DB) — it must not live inside `/home/dev`, the directory filebrowser itself serves via `--root`, even in a dotfile subdirectory ("hide dotfiles" is a cosmetic UI setting, not real isolation).

### Three access methods, three independent credential stores
SSH (real Linux/PAM account), ttyd (`-c user:pass` CLI flag only, no store of its own), and filebrowser (its own BoltDB user table) are bootstrapped with the same password on first run but are **not** kept in sync afterward — changing one (`passwd`, or filebrowser's own UI) does not propagate to the others.

### getrandom() shim (`getrandom_shim.c`)
Bun — the runtime `claude` has been compiled with since `@anthropic-ai/claude-code` 2.1.113 — calls `getrandom(2)`, which doesn't exist on Linux kernels older than 3.17. Some Synology DSM platforms stay on kernel 3.10.x regardless of DSM version, so this is a real constraint, not a hypothetical. Confirmed via `nm -D` on the actual compiled `claude` binary that it imports only `syscall@GLIBC_2.2.5`, not `getrandom`/`getentropy` — i.e. Bun goes through the generic libc `syscall()` wrapper, which is what makes interception possible at all. The shim is an `LD_PRELOAD` library (compiled in the Dockerfile's builder stage, always active via `ENV LD_PRELOAD=...`) overriding both the `getrandom()` symbol and generic `syscall()`, falling back to reading `/dev/urandom` directly on `ENOSYS` and printing a one-line warning to stderr once per process (not per call). No syslog daemon runs in this container, so stderr is the only delivery mechanism right now — it reaches `docker logs` for entrypoint.sh itself and for supervisord-managed programs (their stderr is redirected to `/dev/stderr`), but not for an interactive SSH shell's stderr, which goes to the SSH client instead. On kernels that do have `getrandom(2)` this is a transparent no-op, so it's left on unconditionally.

`CLAUDE_CODE_VERSION` is an independent, secondary fallback for the same underlying problem: pinning to `2.1.112` or earlier installs the last pre-Bun, plain-Node.js `claude` build, sidestepping the issue entirely without needing the shim.

### Deployment target assumption
Meant to run directly on the target NAS's own Docker daemon via a bind-mounted `/var/run/docker.sock` — not a remote/SSH-based Docker context. This was a deliberate, previously-revisited decision (an SSH-remote-control redesign was started once and then reverted at the user's request); don't propose switching it without the user raising it first.
