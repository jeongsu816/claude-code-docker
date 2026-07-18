# claude-code-docker

시놀로지 NAS에서 Claude Code를 상시 실행하기 위한 Docker 이미지. `dev`
사용자로 SSH 또는 브라우저(ttyd)로 접속하며, 두 경로 모두 동일한 tmux
세션(`main`)에 붙기 때문에 접속이 끊겨도 실행 중이던 작업이 그대로
유지된다. `dev`는 `/var/run/docker.sock`을 통해 NAS의 Docker를 직접
제어할 수 있다.

## 요구사항

이 컨테이너는 **NAS 로컬에서 실행**되어야 한다 (`/var/run/docker.sock`을
bind mount하기 때문). 다른 호스트에서 NAS의 Docker를 원격 제어하려는
용도로는 쓸 수 없다.

## 빌드 & 실행

```bash
docker compose up -d --build
```

NAS가 ARM 아키텍처라면 buildx로 해당 아키텍처를 지정해서 빌드한다:

```bash
docker buildx build --platform linux/arm64 -t claude-code-dev:latest --load .
```

## 최초 비밀번호 확인

`dev` 계정의 sudo/로그인 비밀번호는 최초 실행 시 자동으로 설정된다.

- `docker-compose.yml`의 `DEV_PASSWORD` 환경변수에 값을 채워두면 그 값이 사용된다.
- 비워두면 무작위 비밀번호가 생성되어 다음 두 곳에 남는다:
  - `docker logs claude-code-dev`
  - 컨테이너 내부 `/home/dev/.initial_password`

이후 실행부터는 (홈 디렉토리가 볼륨으로 영속화되므로) 비밀번호를 다시
설정하지 않는다. 비밀번호를 바꾸려면 컨테이너 안에서 `passwd`를 사용한다.

## 접속

- SSH: `ssh -p 2222 dev@<NAS-IP>`
- 웹 터미널: `http://<NAS-IP>:7681`

두 경로 모두 `tmux new-session -A -s main`으로 같은 세션에 붙는다. 한쪽에서
작업하다 연결이 끊겨도 다른 경로로 재접속하면 그대로 이어진다.

## sudo 동작

`dev`는 `sudo` 그룹에 속하지만 **NOPASSWD 설정은 없다** — `sudo` 실행 시
항상 비밀번호를 요구한다. Claude Code가 셸 명령을 통해 `sudo`를 호출하더라도
비밀번호 없이 자동으로 권한 상승할 수 없다.

## NAS Docker 제어

컨테이너 시작 시 entrypoint가 마운트된 `/var/run/docker.sock`의 GID를
확인해 `dev`를 해당 그룹에 자동으로 추가한다. 정상적으로 매핑되면 `dev`
세션에서 `docker ps` 등으로 NAS의 컨테이너를 직접 조회/제어할 수 있다.

## 영속화되는 데이터

- `dev-home` 볼륨: `/home/dev` (Claude Code 로그인 정보, bash history,
  tmux 설정, 초기 비밀번호 파일 등)
- `dev-ssh-hostkeys` 볼륨: `/etc/ssh` (SSH 호스트 키 — 컨테이너를
  재생성해도 SSH 지문이 바뀌지 않도록 함)

## 보안 참고사항

- SSH는 비밀번호 인증을 허용한다. **인터넷에 직접 노출하지 말 것** —
  NAS 방화벽/VPN 뒤에 두거나, `dev-home` 볼륨의 `/home/dev/.ssh/authorized_keys`에
  공개키를 넣어 키 기반 인증으로 전환하는 것을 권장한다.
- `docker.sock` 마운트는 NAS 호스트 전체에 대한 강한 권한을 컨테이너에
  부여하는 것과 사실상 동등하다. `dev` 계정 자격증명을 신뢰할 수 있는
  사람에게만 공유할 것.

## Claude Code 실행

접속 후:

```bash
claude
```
