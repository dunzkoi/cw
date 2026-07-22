# Intent

## Problem
`git worktree` + `claude -w` 각각이 빠뜨리는 축(브랜치명 지정, 머지 기반 일괄 정리, 잠금/사유, 경로 규칙)을 하나의 CLI로 묶는다.

## Goals
- `.claude/worktrees/`(생성) + `.worktrees/`(조회/관리)를 같은 서브커맨드로 다루기
- 머지/rebase(patch-id) 기준으로 안전한 일괄 정리
- dirty·잠금·미작업(reflog≤1) 워크트리는 자동 삭제하지 않기

## Non-negotiables
- `cw clean`은 uncommitted 변경이 있으면 삭제 금지
- 중첩 경로(`fix/ceoapp`)의 부모 디렉토리를 stray로 오판해 `rm -rf` 하지 않기
- 테스트(`check.sh`) 회귀가 통과한 뒤에만 릴리즈/커밋 훅 통과

## Out of scope
- Windows
- 임의 worktree 경로 규칙 확장 (생성은 `.claude/worktrees` 고정)

## Definition of done
- `./check.sh` 전체 통과
- Homebrew/install.sh로 단일 `cw` 스크립트 배포 가능

## Load-bearing notes
- `git cherry`(patch-id)로 rebase 머지를 잡고, reflog 길이로 "옛 base에 머문 미작업 브랜치" false-positive를 막음
- porcelain 파싱은 `collect_worktree_rows` 한 경로를 list/clean이 공유 (워크트리별 `git -C` walk-up 사고 방지)
