# claude-code-docker

시놀로지 NAS에서 Claude Code를 상시 실행하기 위한 Docker 이미지. `dev`
사용자로 SSH 또는 브라우저(wetty)로 접속하며, 두 경로 모두 동일한 tmux
세션(`main`)에 붙기 때문에 접속이 끊겨도 실행 중이던 작업이 그대로
유지된다. wetty는 실제 SSH 클라이언트라 인증도 SSH와 동일하다(아래 "접속과
인증" 참고). `dev`는 `/var/run/docker.sock`을 통해 NAS의 Docker를
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
WETTY_PORT=3000
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
`dev` 계정 비밀번호의 해시가 담긴 `.password_hash`)을 전부 밖으로 뺀
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

네트워크는 compose가 프로젝트 전용으로 새로 만드는 네트워크가 아니라
`network_mode: bridge`로 도커의 기본 `bridge` 네트워크를 그대로 쓴다 —
시놀로지 Container Manager로 띄운 다른 컨테이너들과 같은 네트워크에 있어야
나중에 "링크" 기능이나 Authentik 연동을 붙이기 쉽기 때문이다.

## 최초 비밀번호 확인

`dev` 계정의 sudo/로그인 비밀번호는 최초 실행 시 자동으로 설정된다.

- `.env`의 `DEV_PASSWORD`에 값을 채워두면 그 값이 사용된다.
- 비워두면 무작위 비밀번호가 생성되어 **`docker logs claude-code-docker`에
  딱 한 번만** 출력된다. **평문으로는 어디에도 저장되지 않으므로**, 그
  자리에서 안전한 곳에 따로 적어둬야 한다.

컨테이너는 dev 계정 비밀번호의 평문을 전혀 보관하지 않는다 — `/etc/shadow`
와 동일한 방식의 **해시**만 `${DEV_SECRETS_PATH}`(`/var/lib/claude-code-docker`)
에 저장해두고, 컨테이너가 재생성될 때마다(재빌드, `down` 후 `up` 등,
`/etc/shadow` 자체는 bind mount가 아니라 매번 사라진다) 그 해시를 그대로
다시 적용한다. `.env`의 `DEV_PASSWORD` 값은 이 해시가 이미 만들어진
이후로는 무시된다.

비밀번호를 잊었다면 NAS에서 직접 재설정한다 (호스트에서, Docker가 있는
NAS에 로그인해서):

```bash
docker exec -u root claude-code-docker passwd dev
```

컨테이너 안에서 SSH로 접속해 `passwd`(본인 비밀번호 변경) 또는
`sudo passwd dev`(root 권한으로 변경)로 바꾼 비밀번호는 PAM 훅이 자동으로
감지해서 같은 해시 저장소에 즉시 반영하므로, 이후 컨테이너를 재생성해도
새로 바꾼 비밀번호가 그대로 유지된다.

## 접속과 인증

- SSH: `ssh -p ${SSH_PORT} dev@<NAS-IP>` (기본 2222) — Linux 계정 인증(PAM)
- 웹 터미널(wetty): `http://<NAS-IP>:${WETTY_PORT}` (기본 3000) — **SSH와
  완전히 동일한 인증.** wetty는 ttyd처럼 로컬 명령을 그냥 열어주는 게
  아니라 컨테이너 자기 자신의 sshd에 실제로 SSH 접속하는 클라이언트라서,
  브라우저 터미널 화면에 진짜 `dev@localhost's password:` 프롬프트가 뜬다.
  아이디는 `dev`로 미리 채워져 있어 비밀번호만 입력하면 된다. **반드시
  `http://`로 접속할 것** — `https://`로 접속하면 이 컨테이너는 TLS를
  전혀 설정하지 않았으므로 그냥 안 열린다 (브라우저 주소창 자동완성이나
  "HTTPS 우선" 설정 때문에 자기도 모르게 https로 붙는 경우가 흔하니 주의).
- 파일 매니저(filebrowser): `http://<NAS-IP>:${FILEBROWSER_PORT}` (기본 8080)
  — 자체 로그인 화면, `dev` / 위 비밀번호

> 예전에는 ttyd를 썼는데, ttyd는 그냥 로컬 명령(tmux)을 pty로 열어주는
> 방식이라 자체 인증이 없으면 완전히 무방비, 있으면 평문 비밀번호를
> 어딘가에 계속 저장해둬야 하는 딜레마가 있었다. wetty는 진짜 SSH
> 클라이언트라 이 문제가 구조적으로 없다 — 인증은 전부 sshd/PAM이
> 처리하고, wetty 자신은 어떤 자격증명도 저장하지 않는다. 그래도 SSH
> 자체가 비밀번호 인증이니 `WETTY_PORT`를 인터넷에 직접 노출하지 않는 건
> 마찬가지로 권장된다 (아래 "보안 참고사항" 참고).

SSH와 filebrowser는 **최초 실행 시 같은 비밀번호로 부트스트랩**된다
(wetty는 SSH와 완전히 같은 계정이라 별도로 셀 것도 없다). 다만 filebrowser는
별개의 계정 저장소라는 점에 주의:

- SSH(그리고 wetty)는 Linux 시스템 계정(`passwd`로 변경)
- filebrowser는 별도 DB(`${FILEBROWSER_DATA_PATH}`)에 자기 계정을 저장하며,
  **최초 1회만** 부트스트랩한다 — filebrowser 웹 UI에서 비밀번호를 바꾸면
  그 이후로는 SSH와 달라진다. filebrowser 기본 최소 비밀번호 길이는 12자지만,
  `filebrowser config init --minimumPasswordLength 8`로 8자로 낮춰뒀다
  (하드코딩된 제약이 아니라 filebrowser 자체 설정값이다). 그래도
  `DEV_PASSWORD`가 8자 미만이면 filebrowser 계정 부트스트랩이 건너뛰어지고
  로그에 경고가 남는다 — 이 경우 filebrowser 자체의 quick-setup이 무작위
  비밀번호로 `admin` 계정을 만들어주니 로그에서 확인하거나, `DEV_PASSWORD`를
  8자 이상으로 바꿔 컨테이너를 재생성하면 된다. (filebrowser는 흔한
  비밀번호 목록도 따로 걸러내므로, 짧더라도 너무 단순한 값은 여전히
  거부될 수 있다.)
- `passwd`로 SSH 비밀번호를 나중에 바꿔도 filebrowser에는 자동
  반영되지 않는다.

SSH와 wetty 둘 다 (wetty도 결국 SSH 로그인이므로) `.bashrc`의 tmux
자동 attach 로직을 그대로 타서 `tmux new-session -A -s main`으로 같은
세션에 붙는다. 한쪽에서 작업하다 연결이 끊겨도 다른 경로로 재접속하면
그대로 이어진다.

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
- `${DEV_SECRETS_PATH}` → `/var/lib/claude-code-docker` (`dev` 계정 비밀번호의
  해시가 담긴 `.password_hash` — 평문은 저장하지 않는다. 역시 `/home/dev`와
  분리되어 있음)

## 보안 참고사항

- SSH·wetty·filebrowser 모두 비밀번호 인증이다(wetty는 SSH 그 자체이므로
  사실상 SSH와 같은 노출 위험). 인터넷에 직접 노출하지 말고 NAS 방화벽/VPN
  뒤에 두는 것을 권장한다. SSH(및 wetty)는
  `${DEV_HOME_PATH}/.ssh/authorized_keys`에 공개키를 넣어 키 기반 인증으로
  전환할 수도 있다.
- `docker.sock` 마운트는 NAS 호스트 전체에 대한 강한 권한을 컨테이너에
  부여하는 것과 사실상 동등하다. `dev`는 이 소켓의 그룹에 속하지 않으므로
  `sudo` 비밀번호 없이는 사용할 수 없지만(위 "NAS Docker 제어" 참고),
  `dev` 계정 자격증명(로그인 비밀번호)을 신뢰할 수 있는 사람에게만 공유할
  것.
- 여러 서비스를 Authentik 같은 SSO 뒤에 두고 운영 중이라면, wetty와
  filebrowser는 둘 다 HTTP 기반이라 forward-auth(리버스 프록시 + Authentik
  Outpost)를 앞단에 추가로 얹을 수 있다 — filebrowser는 `--auth.method=proxy`
  로 프록시가 전달한 사용자명을 그대로 신뢰하는 방식까지 지원한다. wetty는
  이미 자체적으로 SSH/PAM 인증을 하므로 forward-auth는 필수는 아니고
  이중 방어(defense in depth) 성격이다. SSH 자체는 구조상 forward-auth
  대상이 아니라서 계속 Linux 계정 비밀번호로 남는다. 현재
  `docker-compose.yml`은 포트를 호스트에 직접 publish하므로, 이렇게
  묶으려면 기존 Traefik/Authentik이 쓰는 Docker 네트워크에 join하고 포트
  직접 노출은 끄는 재구성이 필요하다 (아직 미구현).

## Claude Code 실행

접속 후:

```bash
claude
```

`claude` CLI는 npm이 아니라 Anthropic의 **네이티브 설치 스크립트**
(`claude.ai/install.sh`)로 설치되어 있다 — Node.js/npm 의존성이 전혀 없고,
설치 위치도 시스템 전역이 아니라 **`dev` 계정 홈 안**(`~/.local/share/claude`,
`~/.local/bin/claude`)이다. `dev`가 직접 소유하고 있어야 내장 자동 업데이트
기능이 파일을 직접 덮어쓸 수 있기 때문이다(시스템 전역 설치였다면 root
소유라 dev가 쓰기 권한이 없어서 업데이트 시도마다 `Auto-update failed: no
write permission to npm prefix` 에러가 난다 — 예전에 npm 전역 설치로 시도했을
때 실제로 겪은 문제). nvm/pyenv와 마찬가지로 `/etc/skel`에 심어서 최초 부팅
시 홈으로 복사되며, 이미 부팅된 적 있는 기존 홈 디렉토리에도 entrypoint가
매 부팅마다 확인해서 없으면 자동으로 채워 넣는다(수동으로 옮길 필요 없음 —
nvm/pyenv와 달리 이건 핵심 기능이라 자동 반영되게 해뒀다).

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
`.bashrc`에서 자동으로 로드되므로, **인터랙티브 셸(SSH/wetty로 접속해
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
