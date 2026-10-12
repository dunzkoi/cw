# cw

`git worktree` + `claude -w`를 대체하는 단일 bash 스크립트 CLI. 사용자 설명은 `README.md`.

## 구조

| 파일 | 역할 |
|---|---|
| `cw` | CLI 전체 (배포 단위는 이 파일 하나) |
| `check.sh` | 회귀 테스트. 테스트마다 임시 레포를 만들고 `cw_run`(HOME 격리)으로 실행 |
| `install.sh` | curl 설치 스크립트 |
| `docs/intent.md` | 목표·불변 조건·Load-bearing notes |
| `.github/workflows/check.yml` | PR·main push마다 macOS(bash 3.2)·Ubuntu에서 shellcheck + check.sh |

## 검증

```bash
./check.sh
shellcheck -S warning cw install.sh check.sh
```

둘 다 통과해야 커밋한다. 버그를 고치면 check.sh에 `[회귀]` 테스트를 함께 넣는다.

## 불변 조건

`docs/intent.md`의 Non-negotiables와 Load-bearing notes를 따른다. 여기에 복사하지 않는다.

## 코딩 규칙

- bash 3.2 호환: 연관 배열(`declare -A`), `mapfile`/`readarray`, `read -t` 소수 초를 쓰지 않는다. 빈 배열은 `"${arr[@]+"${arr[@]}"}"`로 펼친다(`set -u`).
- `git worktree list --porcelain`의 경로는 줄 전체(`${line#worktree }`, awk `substr($0, 10)`)로 읽는다. `$2`는 공백 경로를 자른다.
- 머지 판정은 clean·remove·prune 모두 `is_effectively_merged` 한 경로로 한다. 새 판정 로직을 명령마다 따로 만들지 않는다.
- 사용자 메시지는 `ok`/`warn`/`err`/`info`/`hint`/`skip` 헬퍼로 낸다. 색은 TTY이고 `NO_COLOR`가 없을 때만 켜진다.
