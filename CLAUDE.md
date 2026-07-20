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

For interactive checks (SSH login, tmux auto-attach, filebrowser HTTP auth), there's no `sshpass` in the base images used for testing — spin up a throwaway `debian:bookworm-slim` container with `--network host`, install `expect` + `openssh-client` in it, and drive an `expect` script against the published SSH port. `curl` against the filebrowser port covers its non-interactive auth check (`curl -X POST .../api/login ...`). ttyd has no auth of its own to check (see below) — a plain `curl -o /dev/null -w '%{http_code}' http://localhost:$TTYD_PORT/` returning 200 is enough to confirm it's up.

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

- **Home directory seeding**: bind mounts (see below) aren't pre-populated from the image the way named volumes are, so entrypoint.sh manually `cp -rn`s `/etc/skel` into `/home/dev` on first use — this is where the tmux auto-attach `.bashrc` snippet and the nvm/pyenv setup below come from. Gated on `.bashrc` not already existing in `/home/dev`, so **this only happens once, ever, per `DEV_HOME_PATH`** — anything later added to `/etc/skel` (e.g. nvm/pyenv, added after some users' homes were already bootstrapped) does *not* retroactively reach already-initialized homes on a rebuild; that requires manually copying the new `/etc/skel` content across. Don't assume a Dockerfile change here reaches existing deployments without telling the user.
- **Password resolution**: on first run, `ACTUAL_PASSWORD` comes from `DEV_PASSWORD` if set, otherwise a random 20-char string — either way it's written to `/var/lib/claude-code-docker/.initial_password` (bind-mounted via `DEV_SECRETS_PATH`), which becomes the single source of truth on every later boot. It is deliberately *not* re-derived from `DEV_PASSWORD` after first run, because that env var could later be changed or removed from `.env` while the real Linux password (set once) stays the same; re-deriving would desync filebrowser auth from the actual password. `chpasswd` itself runs on **every** boot (not just first run) using whatever `ACTUAL_PASSWORD` resolved to — `/etc/shadow` lives in the container's own filesystem, not a bind mount, so unlike the paths above it does *not* survive container recreation (`docker compose down`/`up`, image rebuild, etc.). An earlier version only called `chpasswd` inside the first-run branch, which silently left `dev` with no usable Linux password after any recreation of an already-bootstrapped container — SSH login and `sudo` would fail even though `.initial_password`/filebrowser all still had the right value. Confirmed via a real repro: built the buggy version, ran it once, `docker rm`'d and recreated it against the same bind-mounted home, and SSH login itself was rejected (`Permission denied`) until `chpasswd` was moved out of the first-run-only branch.
- **`.initial_password` lives outside `/home/dev`, not inside it**: earlier versions stored it at `/home/dev/.initial_password`, which filebrowser serves in full via `--root /home/dev` — meaning the plaintext dev password was browsable/downloadable through the file manager UI, and anyone with filebrowser access (even via a filebrowser-only password that had since drifted from the real one, since the three credential stores are otherwise independent) could read it and get the SSH/sudo password too. Moved to `/var/lib/claude-code-docker/.initial_password` (own bind mount, `DEV_SECRETS_PATH`), which filebrowser never touches. `entrypoint.sh` migrates existing deployments automatically: if a legacy `/home/dev/.initial_password`/`.container_setup_done` exists and the new path doesn't yet, it `mv`s them across (not copy, so the old exposed copy doesn't linger) — this preserves the existing password rather than silently generating a new one. Verified end-to-end: built the container, seeded a legacy-layout home dir with a known password, booted the new image against it, confirmed the migration log line, confirmed the old path was gone, and confirmed SSH login still worked with the migrated password.
- **docker.sock access is sudo-gated, deliberately**: entrypoint.sh does *not* add `dev` to the socket's group. `dev`'s sudo already always requires a password (no NOPASSWD, see below) specifically so Claude Code can't self-elevate — putting `dev` directly in the socket's group would open the exact same bypass for `docker` (docker.sock access ≈ root on the host), letting Claude reach or disrupt real running containers on the NAS without a human ever entering a password. Docker is only usable via `sudo docker ...`, which still prompts every time; root always has access to the socket regardless of group membership, so no group setup is needed for that path.
- **SSH host keys**: generated under `/etc/ssh/host_keys` if missing.
- **filebrowser bootstrap**: creates a `dev` admin account (same password) on first run only, in a database kept outside `/home/dev`. Guards against filebrowser's 12-character minimum password requirement explicitly (skip + warn, not crash) — letting `filebrowser users add` fail here used to abort the whole entrypoint under `set -e` and take sshd/ttyd/claude down with it.
- **Conditional `DISABLE_AUTOUPDATER`**: only set when `CLAUDE_CODE_VERSION` pinned a specific version at build time (via `/etc/claude-code-version-pin`); left alone for the default `latest` build so claude can self-update normally.

### SSH sessions vs. direct fork/exec: environment inheritance gotcha
Anything `entrypoint.sh` exports before `exec supervisord` reaches supervisord's direct children fine (ttyd, filebrowser). It does **not** reach SSH login sessions — sshd's PAM-based session setup rebuilds the environment rather than inheriting sshd's own process env. Any variable that needs to be visible in an SSH shell must *also* be written to `/etc/environment` (see the `DISABLE_AUTOUPDATER` handling for the pattern). This cost real debugging time once; don't reintroduce the same bug for a new variable.

### Bind mounts, not named volumes — and why some paths are split out
All persistent state uses bind mounts to host paths from `.env` (`DEV_HOME_PATH`, `DEV_SSH_HOSTKEYS_PATH`, `FILEBROWSER_DATA_PATH`, `DEV_SECRETS_PATH`), chosen so the NAS admin can snapshot/back up the underlying folders directly. Three things are deliberately mounted *outside* `/home/dev` rather than nested under it, all for the same underlying reason — filebrowser serves `/home/dev` in full via `--root`, so anything nested under it is browsable/downloadable through the file manager UI, even in a dotfile subdirectory ("hide dotfiles" is a cosmetic UI setting, not real isolation):
- `/etc/ssh/host_keys` (not all of `/etc/ssh`) — mounting the whole directory would shadow the image's baked-in `sshd_config`/`sshd_config.d/dev.conf` with an empty host directory on first use.
- `/var/lib/filebrowser` (filebrowser's own account/settings DB).
- `/var/lib/claude-code-docker` (`.initial_password`, the dev account's plaintext password — see the password-resolution bullet above for why this one moved late and needed a migration path).

### Dev toolchain: system-wide C/C++, user-space nvm/pyenv for everything else
`docker.sock` is mounted for the user to deploy projects claude builds here, not for claude to drive Docker itself — actual development (compiling, running, testing) happens inside this container, so it needs real toolchains, unlike the original "control tower" framing. C/C++ (`build-essential`/`gdb`/`cmake`/`pkg-config`) is installed system-wide via apt at build time, since there's no meaningful "pick a version per project" concept for it here. Node and Python are different: nvm and pyenv are installed under `/etc/skel/.nvm` and `/etc/skel/.pyenv` (seeded into `/home/dev` the same way as the tmux `.bashrc` snippet — see the home-seeding caveat above) specifically so a version can be picked per project **without ever needing sudo**, consistent with the sudo-is-always-password-gated design elsewhere in this repo. No default Node/Python version is pre-installed; `nvm install`/`pyenv install` pull one on demand. pyenv also needed its documented Debian/Ubuntu "suggested build environment" apt packages (`libssl-dev`, `zlib1g-dev`, etc.) — without them `pyenv install` either fails or silently produces a Python missing modules like `ssl`/`sqlite3`.

**nvm's install script bug, worth remembering if touching this block again**: nvm's `install.sh` writes whatever `$NVM_DIR` was set to *at install time* literally into the profile snippet it appends — not a `$HOME`-relative path. Since the Dockerfile installs nvm with `NVM_DIR=/etc/skel/.nvm` (so the install lands in the right seed location), letting the script auto-write its snippet would hardcode `export NVM_DIR="/etc/skel/.nvm"` into `/etc/skel/.bashrc` — broken for every actual user, who needs `$HOME/.nvm`. Fixed by installing with `PROFILE=/dev/null` (suppress the script's own profile edit) and appending the correct `$HOME`-relative snippet manually instead. Caught by actually inspecting the built image's `/etc/skel/.bashrc` (`docker create` + `docker cp`, no need to even run the container) rather than trusting the install script's own success output.

Both were verified end-to-end against a real running container (not just presence checks): C/C++ via `gcc`/`g++`/`make`/`cmake`/`gdb --version`; nvm/pyenv via an actual SSH `-tt` login through an `expect` script (not `ssh host "cmd"`, which — like nvm/pyenv's usual caveat — never sources `.bashrc` at all, non-interactive-non-login shells don't, regardless of this container). The real path (interactive SSH → tmux auto-attach → pane shell) is what needed confirming, and does work.

### Two access methods with credentials, plus ttyd (deliberately unauthenticated)
SSH (real Linux/PAM account) and filebrowser (its own BoltDB user table) are bootstrapped with the same password on first run but are **not** kept in sync afterward — changing one (`passwd`, or filebrowser's own UI) does not propagate to the other.

**ttyd has no authentication of its own.** It used to re-supply `-c dev:PASSWORD` (HTTP Basic Auth) on every boot, which is the reason `.initial_password` needed to be readable repeatedly at runtime — ttyd has no persistent credential store, so feeding it a password at all means keeping a plaintext copy somewhere the container can read at boot. The user explicitly asked to remove ttyd's own auth after weighing the alternatives: running `login`+PAM inside the ttyd session instead (would need ttyd running as root, not `gosu dev`, to do the setuid — same trust model as `sshd` but on a less-audited codebase); or Authentik forward-auth (needs infra — Traefik/Authentik network — that doesn't exist yet; see README "보안 참고사항" for the plan). Consequence: **`TTYD_PORT` must only ever be reachable from a trusted network** (NAS firewall/VPN) — anyone who can reach it gets an unauthenticated `dev` shell. See README "접속과 인증"/"보안 참고사항" for the user-facing warning. If Authentik forward-auth gets wired up later, that becomes ttyd's real access-control layer.

### getrandom() shim (`getrandom_shim.c`)
Bun — the runtime `claude` has been compiled with since `@anthropic-ai/claude-code` 2.1.113 — calls `getrandom(2)`, which doesn't exist on Linux kernels older than 3.17. Some Synology DSM platforms stay on kernel 3.10.x regardless of DSM version, so this is a real constraint, not a hypothetical. Confirmed via `nm -D` on the actual compiled `claude` binary that it imports only `syscall@GLIBC_2.2.5`, not `getrandom`/`getentropy` — i.e. Bun goes through the generic libc `syscall()` wrapper, which is what makes interception possible at all. The shim is an `LD_PRELOAD` library (compiled in the Dockerfile's builder stage, always active via `ENV LD_PRELOAD=...`) overriding both the `getrandom()` symbol and generic `syscall()`, falling back to reading `/dev/urandom` directly on `ENOSYS`. It does not log anything (an earlier version printed a stderr warning per-process, but since the shim is always active, hitting the fallback is the expected/routine case, not an exceptional one, so the logging was removed). On kernels that do have `getrandom(2)` this is a transparent no-op, so it's left on unconditionally.

A third path needed its own override: glibc >= 2.36's `arc4random()`/`arc4random_buf()`/`arc4random_uniform()` (confirmed via `nm -D /usr/sbin/sshd` showing them as undefined `GLIBC_2.36` symbols — `sshd` calls these directly). glibc's own implementation reaches `SYS_getrandom` via a raw `syscall` instruction inlined in its internal helper, not through the public `getrandom()` or `syscall()` symbols, so neither of the first two overrides ever sees that call. On `ENOSYS` glibc treats this as unrecoverable and aborts (`Fatal glibc error: cannot get entropy for arc4random`), which crashed sshd's per-connection child on affected kernels — sshd itself stayed up (only the forked child handling an actual login died), so this only surfaced when someone tried to SSH in, not at container-start smoke-test time. Since `arc4random*` are themselves normal exported dynamic symbols, overriding them intercepts the call before it reaches glibc's fragile internal path, sidestepping the raw syscall entirely. Reproduced and verified with the seccomp `ENOSYS` technique above plus an actual SSH login attempt (not just `claude --version`) — the failure mode only shows up on the per-connection path.

`CLAUDE_CODE_VERSION` is an independent, secondary fallback for the same underlying problem: pinning to `2.1.112` or earlier installs the last pre-Bun, plain-Node.js `claude` build, sidestepping the issue entirely without needing the shim.

### Deployment target assumption
Meant to run directly on the target NAS's own Docker daemon via a bind-mounted `/var/run/docker.sock` — not a remote/SSH-based Docker context. This was a deliberate, previously-revisited decision (an SSH-remote-control redesign was started once and then reverted at the user's request); don't propose switching it without the user raising it first.
