# Changelog

이 파일은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/) 형식을 따릅니다.

## 2026-10-12

### Added
- `cw clean -F`(`--fetch`)는 origin을 fetch한 뒤 `origin/<기준>`으로 머지를 판정하므로, GitHub에서 머지한 PR의 워크트리를 로컬 main을 pull하지 않고도 정리할 수 있습니다.
- `cw add`가 레포 루트 `.worktreeinclude`에 적힌 gitignore 파일(`.env` 등)을 새 워크트리로 복사합니다(`claude -w`와 같은 규칙).
- 에이전트가 레포 규칙과 검증 명령을 바로 찾도록 `CLAUDE.md`를 추가했습니다.
- `cw completion zsh|bash`로 서브커맨드와 워크트리 이름을 Tab으로 자동완성할 수 있습니다.
- `CW_OPEN_CMD` 환경변수로 `add`/`open`이 실행할 명령을 바꿀 수 있습니다(예: `CW_OPEN_CMD=codex`, `CW_OPEN_CMD=claude`).
- PR과 main push마다 GitHub Actions가 macOS(bash 3.2)와 Ubuntu에서 shellcheck와 `check.sh`를 실행합니다.

### Changed
- `cw clean`·`cw remove`·`cw prune`이 squash 머지(GitHub PR squash 등)된 브랜치도 머지된 것으로 판정합니다.
- README의 `cw clean` 설명을 실제 동작(patch-id 판정, 삭제 전 `[y/N]` 확인, `-y`)에 맞췄고 bash 배지를 3.2+로 고쳤습니다.

### Fixed
- `cw add`가 메인 레포의 `core.hooksPath`를 `/dev/null`로 덮어써 메인 레포와 다른 워크트리의 husky 등 hook이 꺼지던 문제를 고쳤습니다. 이제 새 워크트리에만 적용하고, bare 레포에서는 경고만 냅니다. 이전 버전이 남긴 값은 `git config --unset core.hooksPath`로 지워야 합니다.
- `cw remove`가 기준 브랜치에 없는 커밋이 있는 detached 워크트리를 `-f` 없이 지우던 문제를 고쳤습니다.
- `cw clean`이 방금 만든(작업하지 않은) detached 워크트리를 삭제 대상에 넣던 문제를 고쳤습니다.
- `cw prune`·`cw remove`가 `feat-x`가 머지됐다는 이유로 머지 안 된 `feat`까지 지우던 문제를 고쳤습니다. 두 명령도 `cw clean`과 같은 patch-id 판정을 쓰므로 cherry-pick으로 흡수된 브랜치는 `cw remove`로 지울 수 있고, 기준 브랜치 이름을 잘못 적으면 아무것도 지우지 않습니다.
- 경로에 공백이 들어간 레포(iCloud Drive 등)에서 모든 명령이 `메인 워크트리 경로 감지 실패`로 끝나던 문제를 고쳤습니다.
- `.claude/worktrees/x`와 `.worktrees/x`처럼 이름이 같은 워크트리가 있을 때 `cw clean`이 다른 쪽의 잠금 상태를 읽던 문제를 고쳤습니다.
- 제어 터미널이 없는 환경(CI, 에이전트, launchd)에서 실행할 때마다 붙던 `/dev/tty: Device not configured` 메시지를 없앴습니다.
