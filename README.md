# cw — Claude Worktree

`git worktree` + `claude -w`를 대체하는 CLI. 워크트리 생성부터 claude 실행, 잠금, 일괄 정리까지 서브커맨드로 관리.

## 만든 이유

### `git worktree`의 불편함
- 매번 `.claude/worktrees/<name>` 경로를 직접 타이핑해야 함 (`git worktree add .claude/worktrees/my-feature -b feature/my-feature main`)
- 생성 후 claude 실행까지 `cd` → `claude` 2단계
- 머지된 브랜치 일괄 정리 기능 없음
- 잠긴 워크트리 사유(reason) 관리 번거로움
- 어떤 워크트리가 "정리해도 되는지" 한 번에 안 보임

### `claude -w`의 불편함
- **브랜치명을 직접 지정 불가** — 항상 `worktree-<name>` 자동 작명
- 베이스 브랜치 지정 옵션 없음 (`main`/현재 브랜치 고정)
- 변경사항 없으면 세션 종료 시 자동 삭제 → 작업 중인 워크트리 날아갈 위험
- 잠금/정리/이름변경 기능 없음
- 워크트리 생성 후 초기화 훅 지원 없음

## cw가 제공하는 것

| 기능 | `git worktree` | `claude -w` | `cw` |
|---|---|---|---|
| `.claude/worktrees/` 경로 자동 | ❌ | ✅ | ✅ |
| 브랜치명 직접 지정 | ✅ | ❌ | ✅ |
| 베이스 브랜치 선택 | ✅ | ❌ | ✅ |
| 생성 후 claude 자동 실행 | ❌ | ✅ | ✅ |
| 머지 기반 일괄 정리 | ❌ | ❌ | ✅ |
| 잠금 + 사유 | ✅ (번거로움) | ❌ | ✅ |
| detached HEAD ancestor 체크 정리 | ❌ | ❌ | ✅ |
| init hook (`.env.local` 복사 등) | ❌ | ❌ | ✅ |
| 경로 출력 + 클립보드 복사 | ❌ | ❌ | ✅ |
| stale 참조 + 미사용 브랜치 동시 정리 | ❌ | ❌ | ✅ |
| 축약/번들 옵션 (`-Fn`, `-dFn`) | - | - | ✅ |
| 컬러 출력 (메인/잠금/prunable 강조) | 일부 | - | ✅ |

## 설치

### Homebrew (권장)
```bash
brew install dunzkoi/tap/cw
```

### Install script
```bash
curl -fsSL https://raw.githubusercontent.com/dunzkoi/cw/main/install.sh | bash
```

설치 경로 커스텀:
```bash
CW_INSTALL_DIR=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/dunzkoi/cw/main/install.sh | bash
```

### 수동
```bash
curl -fsSL https://raw.githubusercontent.com/dunzkoi/cw/main/cw -o ~/.local/bin/cw
chmod +x ~/.local/bin/cw
```

`NO_COLOR=1` 환경변수로 색상 비활성화 가능.

## 사용법

### 생성 + 진입
```bash
cw add my-feature                                     # worktrees-my-feature 브랜치로 생성
cw add BMSQUARE-16512 feature/BMSQUARE-16512          # 브랜치명 직접 지정
cw add BMSQUARE-16512 feature/BMSQUARE-16512 main     # 베이스 main
cw add hotfix -d main                                 # detached HEAD
cw add urgent -l                                      # 생성 즉시 잠금
cw add exp -F                                         # fetch 선행
cw add setup -n                                       # 생성만, claude 실행 X
cw add x -Fn                                          # 번들: fetch + no-open
```

### 기존 워크트리 접근
```bash
cw open my-feature       # claude 실행
cw path my-feature       # 경로 출력 + 클립보드 복사
```

### 목록
```bash
cw list
```
```
~/work/project                                082c77b7ec  [main]
~/work/project/.claude/worktrees/mobile-gnb   ce52264285  [feature/...] 🔒 locked
~/work/project/.claude/worktrees/dead         abc123ff00  [old-branch] ⚠ prunable
```

### 잠금
```bash
cw lock my-feature "MR 리뷰 중"     # 삭제 방지
cw unlock my-feature
```

### 이동
```bash
cw move old-name new-name
```

### 정리

```bash
cw remove my-feature             # 안전 모드: 변경사항 있으면 차단
cw remove my-feature -f          # 강제 (변경사항 무시)
```

```bash
cw clean                         # 메인 워크트리 현재 브랜치에 머지된 것만 일괄 삭제
cw clean main                    # 기준 브랜치 명시 override
```

`clean` 정책:
- 머지된 브랜치 → 워크트리 + 브랜치 둘 다 삭제
- 잠긴 워크트리 → 스킵
- detached HEAD → HEAD 커밋이 기준 브랜치 ancestor면 삭제, 아니면 유지
- 머지 안 됨 → 유지 (끝에 `cw remove <name> -f` 힌트 출력)

```bash
cw prune                         # stale 참조 정리 + 머지된 orphan 브랜치 삭제
cw repair                        # 레포 이동 후 워크트리 링크 복구
```

## 옵션 매핑

| 축약 | 전체 | 대상 명령 | 의미 |
|---|---|---|---|
| `-l` | `--lock` | add | 생성 즉시 잠금 |
| `-d` | `--detach` | add | detached HEAD 체크아웃 |
| `-F` | `--fetch` | add | 생성 전 `git fetch origin` |
| `-n` | `--no-open` | add | claude 실행 생략 |
| `-f` | `--force` | remove | 더티 상태 무시 |

번들링 지원: `cw add foo -dFn main` = `cw add foo --detach --fetch --no-open main`

## Init Hook

`~/.claude/worktree-init.sh`가 실행 가능하면 `cw add` 완료 후 자동 실행 (인자: 새 워크트리 경로).

활용 예:
```bash
#!/bin/bash
# ~/.claude/worktree-init.sh
WT="$1"
# 프로젝트 로컬 설정 복사
[ -f .env.local ] && cp .env.local "$WT/"
# VSCode workspace 설정 복사
[ -d .vscode ] && cp -r .vscode "$WT/"
```

## 환경변수

| 변수 | 용도 |
|---|---|
| `NO_COLOR=1` | 색상 출력 비활성화 |
| `NO_CLIPBOARD=1` | `cw path` 클립보드 복사 비활성화 |

## 안전장치

- **자동 hooksPath 차단** — 워크트리 생성 시 `core.hooksPath=/dev/null` (husky 등 중복 실행 방지)
- **dirty 보호** — `cw remove`는 기본 안전 모드. 변경사항 있으면 `-f` 없이 차단
- **잠금 우선** — 잠긴 워크트리는 `remove`/`clean`에서 스킵
- **머지 체크** — `clean`/`prune`은 기준 브랜치에 실제 머지된 것만 자동 삭제
- **TTY 감지** — 파이프/리다이렉트 시 색상 + 클립보드 복사 자동 비활성

## 주요 동작 플로우

### `cw add <folder>`
1. 폴더명 정규화 + 브랜치명 결정 (인자 or `worktrees-<folder>`)
2. 기존 브랜치 존재 확인 → 있으면 체크아웃 (base 인자 경고), 없으면 신규 생성
3. `core.hooksPath /dev/null` 설정
4. `--lock` 시 즉시 잠금
5. `~/.claude/worktree-init.sh` 실행
6. `--no-open` 아니면 `cd` + `exec claude --dangerously-skip-permissions`

### `cw clean`
1. 메인 워크트리의 현재 브랜치를 기준으로 선정 (override: `cw clean <base>`)
2. 각 워크트리 반복:
   - 잠금 → 스킵
   - detached HEAD → `merge-base --is-ancestor` 체크
   - 일반 브랜치 → `git branch --merged <base>` 체크
3. 삭제 대상: `git worktree remove --force` + `git branch -D`
4. 유지 대상 요약 + 수동 삭제 힌트 출력

## 제약

- **Darwin/Linux 대상** (Windows 미지원)
- `claude` CLI가 PATH에 있어야 `open`/`add` 기본 동작 가능 (`--no-open`으로 우회)
- 모든 워크트리는 `.claude/worktrees/<folder>` 규칙으로 고정 (다른 경로는 `git worktree` 직접 사용)
