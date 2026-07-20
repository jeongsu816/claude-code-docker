# claude-code-docker

시놀로지 NAS에서 Claude Code를 상시 실행하기 위한 Docker 이미지. `dev`
사용자로 SSH 또는 브라우저(ttyd)로 접속하며, 두 경로 모두 동일한 tmux
세션(`main`)에 붙기 때문에 접속이 끊겨도 실행 중이던 작업이 그대로
유지된다. `dev`는 `/var/run/docker.sock`을 통해 NAS의 Docker를
`sudo docker ...`로 제어할 수 있다 (매번 비밀번호 필요 — 아래 "NAS Docker
제어" 참고). 웹 파일 매니저(filebrowser)도 포함되어 있어 `/home/dev`를
브라우저에서 직접 관리할 수 있다.

## 요구사항

이 컨테이너는 **NAS 로컬에서 실행**되어야 한다 (`/var/run/docker.sock`을
bind mount하기 때문). 다른 호스트에서 NAS의 Docker를 원격 제어하려는
용도로는 쓸 수 없다.

## 설정

`.env.example`을 `.env`로 복사한 뒤 값을 채운다 (`.env`는 git에 커밋되지 않는다):

```bash
cp .env.example .env
vi .env
```

```dotenv
DEV_HOME_PATH=/volume1/docker/claude-code-docker/home
DEV_SSH_HOSTKEYS_PATH=/volume1/docker/claude-code-docker/ssh-host-keys
FILEBROWSER_DATA_PATH=/volume1/docker/claude-code-docker/filebrowser
DEV_SECRETS_PATH=/volume1/docker/claude-code-docker/secrets
DEV_PASSWORD=
SSH_PORT=2222
TTYD_PORT=7681
FILEBROWSER_PORT=8080
DEV_UID=1000
DEV_GID=1000
```

`DEV_UID`/`DEV_GID`는 이미지 빌드 시 `dev` 계정에 고정되는 값이다(기본 1000).
재빌드해도 값이 흔들리지 않으므로 bind mount한 NAS 경로의 파일 소유권이
꼬이지 않는다. NAS의 다른 계정과 UID를 맞추고 싶을 때만 바꾸면 된다.

`DEV_HOME_PATH`, `DEV_SSH_HOSTKEYS_PATH`, `FILEBROWSER_DATA_PATH`,
`DEV_SECRETS_PATH`는 NAS의 실제 디렉토리 경로로, 컨테이너의 `/home/dev`,
`/etc/ssh/host_keys`, `/var/lib/filebrowser`, `/var/lib/claude-code-docker`에
각각 bind mount된다. 뒤의 세 개가 `/home/dev` 밖의 별도 경로인 이유는 모두
같다 — filebrowser가 정확히 `/home/dev`를 그대로 서빙하기 때문에, 그
트리 안에 두면 안 되는 것들(SSH 호스트 키, filebrowser 자신의 계정 DB,
`dev` 계정의 평문 비밀번호가 담긴 `.initial_password`)을 전부 밖으로 뺀
것이다. 디렉토리가 없으면 Docker가 자동으로 생성하고, 소유권/최초 초기화는
컨테이너 entrypoint가 알아서 처리한다.

## 빌드 & 실행

```bash
docker compose up -d --build
```

NAS가 ARM 아키텍처라면 buildx로 해당 아키텍처를 지정해서 빌드한다:

```bash
docker buildx build --platform linux/arm64 -t claude-code-docker:latest --load .
```

## 최초 비밀번호 확인

`dev` 계정의 sudo/로그인 비밀번호는 최초 실행 시 자동으로 설정된다.

- `.env`의 `DEV_PASSWORD`에 값을 채워두면 그 값이 사용된다.
- 비워두면 무작위 비밀번호가 생성되어 다음 두 곳에 남는다:
  - `docker logs claude-code-docker`
  - 컨테이너 내부 `/var/lib/claude-code-docker/.initial_password`
    (`/home/dev` 밖에 있다 — filebrowser가 서빙하는 트리에 평문 비밀번호가
    노출되지 않도록 일부러 분리해뒀다. 아래 "접속과 인증" 참고)

이후 실행부터는 (홈 디렉토리가 bind mount로 영속화되므로) `.env`의
`DEV_PASSWORD` 값이 바뀌어도 새로 반영하지 않고 항상 최초에 정해진 값을
그대로 유지한다 — 다만 그 값 자체는 컨테이너를 재생성해도(재빌드, `down`
후 `up` 등) 매번 다시 적용되므로 SSH/sudo 비밀번호가 풀리는 일은 없다.

## 접속과 인증

- SSH: `ssh -p ${SSH_PORT} dev@<NAS-IP>` (기본 2222) — Linux 계정 인증(PAM)
- 웹 터미널(ttyd): `http://<NAS-IP>:${TTYD_PORT}` (기본 7681) — **인증 없음.**
  접속하면 곧바로 `dev` 계정 tmux 세션으로 들어간다.
- 파일 매니저(filebrowser): `http://<NAS-IP>:${FILEBROWSER_PORT}` (기본 8080)
  — 자체 로그인 화면, `dev` / 위 비밀번호

> **ttyd는 자체 인증이 없다.** `TTYD_PORT`에 네트워크로 닿을 수 있는 사람은
> 누구나 비밀번호 없이 `dev` 셸을 그대로 얻는다. 원래는 ttyd가 매 시작마다
> `-c dev:PASSWORD`로 basic auth를 재구성했는데, 그러려면 평문 비밀번호를
> 컨테이너 안에 계속 저장해둬야 했고 그 파일이 `/home/dev`(filebrowser가
> 서빙하는 트리) 안에 있어서 별도 문제가 있었다. 지금은 그 인증 자체를
> 뺐다 — **`TTYD_PORT`를 신뢰할 수 없는 네트워크(인터넷 등)에 노출하면
> 절대 안 된다.** NAS 방화벽/VPN 뒤에 두거나, 나중에 Authentik 같은
> forward-auth를 앞단에 붙이는 것을 전제로 한다 (아래 "보안 참고사항"
> 참고, 아직 미구현).

SSH와 filebrowser는 **최초 실행 시 같은 비밀번호로 부트스트랩**된다. 다만
둘은 서로 다른 별개의 계정 저장소라는 점에 주의:

- SSH는 Linux 시스템 계정(`passwd`로 변경)
- filebrowser는 별도 DB(`${FILEBROWSER_DATA_PATH}`)에 자기 계정을 저장하며,
  **최초 1회만** 부트스트랩한다 — filebrowser 웹 UI에서 비밀번호를 바꾸면
  그 이후로는 SSH와 달라진다. filebrowser는 새 계정 비밀번호가 12자
  미만이면 생성에 실패하므로(최소 길이 요구사항), `DEV_PASSWORD`를 짧게
  설정하면 filebrowser 계정 부트스트랩이 건너뛰어지고 로그에 경고가 남는다
  — 이 경우 filebrowser 자체의 quick-setup이 무작위 비밀번호로 `admin`
  계정을 만들어주니 로그에서 확인하거나, `DEV_PASSWORD`를 12자 이상으로
  바꿔 컨테이너를 재생성하면 된다.
- `passwd`로 SSH 비밀번호를 나중에 바꿔도 filebrowser에는 자동
  반영되지 않는다.

SSH와 ttyd 둘 다 `tmux new-session -A -s main`으로 같은 세션에 붙는다.
한쪽에서 작업하다 연결이 끊겨도 다른 경로로 재접속하면 그대로 이어진다.

같은 세션 안에서 창(window)을 여러 개 두고 전환할 수 있어서, 예를 들어
한 창에서 `claude`를 실행해두고 다른 창에서 별도 작업을 할 수 있다:

- `Ctrl-b c` — 새 창 생성
- `Ctrl-b n` / `Ctrl-b p` — 다음/이전 창으로 전환
- `Ctrl-b 0`~`9` — 번호로 바로 이동
- `Ctrl-b w` — 창 목록 보고 선택
- `Ctrl-b %` / `Ctrl-b "` — 세로/가로 pane 분할 (한 화면에 여러 창 동시에 보기)

## sudo 동작

`dev`는 `sudo` 그룹에 속하지만 **NOPASSWD 설정은 없다** — `sudo` 실행 시
항상 비밀번호를 요구한다. Claude Code가 셸 명령을 통해 `sudo`를 호출하더라도
비밀번호 없이 자동으로 권한 상승할 수 없다.

## NAS Docker 제어

`dev`는 `/var/run/docker.sock`의 그룹에 **의도적으로 속하지 않는다**.
`docker.sock` 접근 권한은 사실상 NAS 호스트 전체에 대한 root 권한과
동등한데, `dev`를 그 그룹에 바로 넣어버리면 sudo에 비밀번호를 요구하게
막아둔 것(위 "sudo 동작" 참고)과 별개로 Claude Code가 비밀번호 없이
`docker` 명령으로 호스트에 무제한 접근할 수 있게 되기 때문이다. 대신
`sudo docker ps` 처럼 **매번 비밀번호를 입력**해야 NAS의 컨테이너를
조회/제어할 수 있다 — root는 소켓 소유자라서 그룹 멤버십과 무관하게 항상
접근 가능하므로 별도 그룹 설정 없이 `sudo`만으로 동작한다. 사람이 직접
비밀번호를 입력하는 순간에만 실제 운영 중인 컨테이너에 영향을 줄 수 있는
명령이 실행되도록 하기 위한 설계다.

## 영속화되는 데이터

`.env`에서 지정한 NAS 경로에 bind mount되므로, 컨테이너를 재생성해도
그대로 유지되고 NAS에서 직접 백업/스냅샷을 관리할 수 있다.

- `${DEV_HOME_PATH}` → `/home/dev` (Claude Code 로그인 정보, bash history,
  tmux 설정, 초기 비밀번호 파일 등)
- `${DEV_SSH_HOSTKEYS_PATH}` → `/etc/ssh/host_keys` (SSH 호스트 키 —
  컨테이너를 재생성해도 SSH 지문이 바뀌지 않도록 함)
- `${FILEBROWSER_DATA_PATH}` → `/var/lib/filebrowser` (filebrowser 계정/설정
  DB — `/home/dev`와 분리되어 있음)
- `${DEV_SECRETS_PATH}` → `/var/lib/claude-code-docker` (`dev` 계정의 평문
  비밀번호가 담긴 `.initial_password` — 역시 `/home/dev`와 분리되어 있음)

## 보안 참고사항

- **ttyd는 인증이 전혀 없다.** `TTYD_PORT`는 반드시 NAS 방화벽/VPN 뒤에만
  둘 것 — 인터넷은 물론 신뢰하지 않는 내부망에도 노출하면 안 된다. 이
  포트에 닿을 수 있는 사람은 곧바로 `dev` 셸을 얻는다.
- SSH·filebrowser는 비밀번호 인증이다. 이것도 인터넷에 직접 노출하지 말고
  NAS 방화벽/VPN 뒤에 두거나, SSH는
  `${DEV_HOME_PATH}/.ssh/authorized_keys`에 공개키를 넣어 키 기반 인증으로
  전환하는 것을 권장한다.
- `docker.sock` 마운트는 NAS 호스트 전체에 대한 강한 권한을 컨테이너에
  부여하는 것과 사실상 동등하다. `dev`는 이 소켓의 그룹에 속하지 않으므로
  `sudo` 비밀번호 없이는 사용할 수 없지만(위 "NAS Docker 제어" 참고),
  `dev` 계정 자격증명(로그인 비밀번호)을 신뢰할 수 있는 사람에게만 공유할
  것.
- 여러 서비스를 Authentik 같은 SSO 뒤에 두고 운영 중이라면, ttyd와
  filebrowser는 둘 다 HTTP 기반이라 forward-auth(리버스 프록시 +
  Authentik Outpost)로 붙일 수 있다 — filebrowser는 `--auth.method=proxy`
  로 프록시가 전달한 사용자명을 그대로 신뢰하는 방식까지 지원하고, ttyd는
  지금 자체 인증이 아예 없으므로 forward-auth가 사실상 유일한 접근 통제
  수단이 된다. SSH는 구조상 forward-auth 대상이 아니라서 계속 Linux 계정
  비밀번호로 남는다. 현재 `docker-compose.yml`은 포트를 호스트에 직접
  publish하므로, 이렇게 묶으려면 기존 Traefik/Authentik이 쓰는 Docker
  네트워크에 join하고 포트 직접 노출은 끄는 재구성이 필요하다 (아직
  미구현 — Authentik을 실제로 붙이기 전까지는 `TTYD_PORT`를 신뢰할 수
  있는 네트워크 밖으로 노출하지 말 것).

## Claude Code 실행

접속 후:

```bash
claude
```

## 개발 툴체인

claude가 이 컨테이너 안에서 실제로 빌드/실행까지 하는 개발 용도이므로,
언어별 도구가 기본으로 들어있다:

- **C/C++**: `gcc`/`g++`/`make`/`cmake`/`gdb`/`pkg-config` — 이미지에
  시스템 전역으로 설치되어 있어 sudo 없이 바로 쓸 수 있다.
- **Node.js**: [nvm](https://github.com/nvm-sh/nvm) — `nvm install <버전>`으로
  프로젝트별 버전을 root 권한 없이 설치/전환한다. 기본으로 미리 설치된
  Node 버전은 없다(어떤 프로젝트든 맞는 버전을 그때그때 설치).
- **Python**: [pyenv](https://github.com/pyenv/pyenv) — `pyenv install <버전>`도
  마찬가지로 root 권한 없이 동작한다.

nvm/pyenv는 `dev`의 홈 디렉토리(`$HOME/.nvm`, `$HOME/.pyenv`) 안에 설치되고
`.bashrc`에서 자동으로 로드되므로, **인터랙티브 셸(SSH/ttyd로 접속해
tmux 세션 안에 들어온 상태)에서만** 잡힌다 — `ssh host "명령어"`처럼
비대화형으로 원격 명령만 실행하는 경우에는 `.bashrc`가 로드되지 않아
`nvm`/`pyenv` 명령을 못 찾는다(nvm/pyenv 자체의 일반적인 제약사항이며 이
컨테이너만의 문제는 아니다).

새 이미지를 빌드해도 **이미 이전에 한 번 실행한 적 있는 기존
`DEV_HOME_PATH`에는 자동으로 반영되지 않는다** — `entrypoint.sh`는
`.bashrc`가 이미 있으면(= 최초 실행이 아니면) `/etc/skel` 시딩을 건너뛰기
때문이다. 이미 운영 중인 홈 디렉토리에 nvm/pyenv를 추가하려면 수동으로
옮겨야 한다.

## 구형 커널(getrandom 미지원) 대응

`@anthropic-ai/claude-code`는 2.1.113부터 `claude`가 Bun으로 컴파일된
바이너리로 바뀌었다. Bun은 내부적으로 `getrandom(2)`를 쓰는데, 이 syscall은
Linux 3.17부터 생겨서, 커널이 그보다 오래된 호스트(일부 구형 시놀로지 NAS
등, DSM 버전과 무관하게 플랫폼별로 커널이 3.10.x에 머물러 있는 경우가 있다)
에서는 `panic: getrandom failed: errno 38`로 크래시가 난다.

이미지 빌드 시 `getrandom_shim.c`가 자동으로 컴파일되어
`/usr/local/lib/getrandom_shim.so`로 설치되고, `LD_PRELOAD` 환경변수로
항상 적용된다. libc의 `getrandom()`과 `syscall()` 양쪽 경로를 모두
가로채서(Bun은 `syscall()`을 쓰지만, 컨테이너 안 다른 프로그램이 직접
`getrandom()`을 부를 수도 있으므로 둘 다 후킹한다) `ENOSYS`로 실패하면
`/dev/urandom`을 직접 읽어 대신 반환한다. 컨테이너는 항상 이 심을 켠 채로
실행되므로 이 폴백 경로는 예외적인 상황이 아니라 정상적인 동작이라, 별도로
로그를 남기지 않고 조용히 동작한다. 정상 커널에서는 실제 syscall이 그대로
성공하므로 완전히 무해한 passthrough다.

glibc 2.36 이상의 `arc4random()`/`arc4random_buf()`/`arc4random_uniform()`은
별도로 후킹한다 — `sshd`가 이 함수들을 직접 호출하는데, glibc 내부 구현이
`getrandom(2)`를 raw `syscall` 명령어로 인라인 호출해서 위의 두 후킹을
우회하고, `ENOSYS`를 받으면 복구 불가능한 오류로 보고 그대로
`abort()`한다(`Fatal glibc error: cannot get entropy for arc4random`) —
이게 구형 커널에서 SSH 접속마다 생기는 자식 프로세스가 죽던 원인이었다.
`arc4random*` 자체는 일반적으로 export된 동적 심볼이라 이것도 그대로
후킹해서 같은 폴백 경로로 우회한다.

시놀로지 DS216+II(커널 3.10.108)에서 실제로 정상 동작을 확인했다.

참고로 `.env`의 `CLAUDE_CODE_VERSION`으로 설치 버전을 고정할 수도 있다.
기본값 `latest`면 빌드 시점의 최신 버전이 설치되고 `claude`의 내장
자동 업데이트 기능도 그대로 켜져 있다. 특정 버전(예: `2.1.112`)으로
지정하면 그 버전이 설치되고, entrypoint가 자동 업데이트를 꺼서 고정된
버전이 실제로 유지되도록 한다. 위 심과는 무관한 일반적인 버전 고정
기능이다.
