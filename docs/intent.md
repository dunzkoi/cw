# Intent

## Problem
`git worktree` + `claude -w` 각각이 빠뜨리는 축(브랜치명 지정, 머지 기반 일괄 정리, 잠금/사유, 경로 규칙)을 하나의 CLI로 묶는다.

## Goals
- `.claude/worktrees/`에 생성, 조회/정리는 git linked worktree 전체(메인 제외)
- 머지/rebase(patch-id) 기준으로 안전한 일괄 정리
- dirty·잠금·미작업(reflog≤1) 워크트리는 자동 삭제하지 않기

## Non-negotiables
- `cw clean`은 uncommitted 변경이 있으면 삭제 금지
- 중첩 경로(`fix/ceoapp`)의 부모 디렉토리를 stray로 오판해 `rm -rf` 하지 않기
- stray `rm`은 관리 베이스(`.claude/worktrees`, `.worktrees`) 안에서만 — orca 등 외부는 git 등록분만
- 테스트(`check.sh`) 회귀가 통과한 뒤에만 릴리즈/커밋 훅 통과

## Out of scope
- Windows
- `cw add` 생성 경로 확장 (생성은 `.claude/worktrees` 고정)

## Definition of done
- `./check.sh` 전체 통과
- Homebrew/install.sh로 단일 `cw` 스크립트 배포 가능

## Load-bearing notes
- `git cherry`(patch-id)로 rebase/cherry-pick 머지를 잡음. 미작업 보호는 tip==기준브랜치 tip(SHA)일 때만 — 빈 reflog는 “미작업”이 아님(patch-merged false-negative 방지)
- porcelain 파싱은 `collect_worktree_rows` 한 경로를 list/clean이 공유 (워크트리별 `git -C` walk-up 사고 방지)
- `cw clean`은 `git worktree list`의 메인·bare 제외 전부 대상 — orca/workspaces 등 외부 경로 포함
