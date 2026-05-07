#!/bin/bash
# check.sh — cw 기능 자동 테스트
# 사용법: ./check.sh
# 매 수정마다 실행해서 회귀 방지

set -u
IFS=$'\n\t'

# pre-commit 훅 등 git 호출 컨텍스트 격리:
# git이 export하는 GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE 등이 남아 있으면
# 임시 repo 안의 git 명령이 부모 cw 레포를 가리켜 테스트가 전부 깨짐.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_COMMON_DIR GIT_PREFIX GIT_NAMESPACE GIT_REFLOG_ACTION 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CW="${SCRIPT_DIR}/cw"

if [ ! -x "$CW" ]; then
  echo "✗ cw 실행 파일 없음: $CW" >&2
  exit 1
fi

# 색상 (TTY일 때만)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; GRAY=$'\033[90m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; GRAY=""; BOLD=""; RESET=""
fi

PASS=0
FAIL=0
TESTS_RUN=0
FAILED_TESTS=()
CURRENT_TEST=""

pass() {
  PASS=$((PASS + 1))
  echo "  ${GREEN}✓${RESET} $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ${RED}✗${RESET} $1" >&2
  FAILED_TESTS+=("${CURRENT_TEST} :: $1")
}

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"
  else fail "$3 (expected '$2', got '$1')"
  fi
}

assert_dir_exists() {
  if [ -d "$1" ]; then pass "$2"
  else fail "$2 (디렉토리 없음: $1)"
  fi
}

assert_dir_missing() {
  if [ ! -d "$1" ]; then pass "$2"
  else fail "$2 (디렉토리 잔존: $1)"
  fi
}

assert_branch_exists() {
  if git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then pass "$3"
  else fail "$3 (브랜치 없음: $2)"
  fi
}

assert_branch_missing() {
  if ! git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then pass "$3"
  else fail "$3 (브랜치 잔존: $2)"
  fi
}

assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"
  else fail "$3 (출력에 '$2' 없음. 실제: $(printf '%s' "$1" | head -3))"
  fi
}

assert_not_contains() {
  if ! printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"
  else fail "$3 (출력에 '$2' 포함됨)"
  fi
}

assert_exit() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$actual" -eq "$expected" ]; then pass "$msg"
  else fail "$msg (exit ${actual}, 기대 ${expected})"
  fi
}

# 임시 git repo 생성 — 각 테스트마다 격리
setup_repo() {
  local d
  d="$(mktemp -d -t cw-check.XXXXXX)"
  # macOS의 /var → /private/var 심링크 정규화 (git이 canonical 경로 반환)
  d="$(cd "$d" && pwd -P)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@cw"
  git -C "$d" config user.name "cw-test"
  git -C "$d" config commit.gpgsign false
  echo "init" > "$d/README"
  git -C "$d" add README
  git -C "$d" commit -q -m "init"
  echo "$d"
}

# cw 실행 — HOME을 임시 디렉토리로 격리해서 init hook 차단
cw_run() {
  local repo="$1"; shift
  HOME="$repo" NO_COLOR=1 "$CW" "$@"
}

# 테스트 러너 — 서브셸 안 씀 (카운터 누적 위해). cwd만 저장/복구.
run_test() {
  local name="$1" fn="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  CURRENT_TEST="$name"
  echo ""
  echo "${BOLD}── ${TESTS_RUN}. ${name} ──${RESET}"
  local repo orig_cwd
  repo="$(setup_repo)"
  orig_cwd="$(pwd)"
  cd "$repo"
  "$fn" "$repo"
  cd "$orig_cwd"
  rm -rf "$repo"
}

# ─────────────────────────────────────────────────────────────
# 테스트들
# ─────────────────────────────────────────────────────────────

t_version() {
  local out
  out="$(cw_run "$1" --version 2>&1)"
  assert_contains "$out" "cw" "version 출력"
  out="$(cw_run "$1" -v 2>&1)"
  assert_contains "$out" "cw" "-v 출력"
}

t_help() {
  local out
  out="$(cw_run "$1" help 2>&1)"
  assert_contains "$out" "Commands" "help 출력"
  assert_contains "$out" "add" "help에 add 표시"
  assert_contains "$out" "clean" "help에 clean 표시"
}

t_add_basic() {
  local r="$1"
  cw_run "$r" add t1 -n >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/t1" "add 기본 — 디렉토리 생성"
  assert_branch_exists "$r" "worktrees-t1" "add 기본 — 브랜치 생성"
}

t_add_custom_branch() {
  local r="$1"
  cw_run "$r" add t2 feature/foo -n >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/t2" "add 커스텀 브랜치 — 디렉토리"
  assert_branch_exists "$r" "feature/foo" "add 커스텀 브랜치 — 브랜치"
}

t_add_nested() {
  local r="$1"
  cw_run "$r" add fix/ceoapp -n >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/fix/ceoapp" "add 중첩 — 디렉토리"
  assert_branch_exists "$r" "worktrees-fix/ceoapp" "add 중첩 — 브랜치"
}

t_add_detached() {
  local r="$1"
  cw_run "$r" add det -d -n >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/det" "add detached — 디렉토리"
  local br
  br="$(git -C "$r/.claude/worktrees/det" branch --show-current 2>/dev/null || true)"
  assert_eq "$br" "" "add detached — 브랜치 없음"
}

t_add_locked() {
  local r="$1"
  cw_run "$r" add lk -l -n >/dev/null 2>&1
  local lock_file
  lock_file="$(git -C "$r" rev-parse --git-common-dir)/worktrees/lk/locked"
  if [ -f "$lock_file" ]; then pass "add -l — locked 마커 생성"
  else fail "add -l — locked 마커 없음 ($lock_file)"
  fi
}

t_add_no_open_outputs_path() {
  local r="$1"
  local out
  out="$(cw_run "$r" add no -n 2>/dev/null | tail -1)"
  assert_eq "$out" "$r/.claude/worktrees/no" "add -n — 마지막 줄 = 경로"
}

t_list() {
  local r="$1"
  cw_run "$r" add a -n >/dev/null 2>&1
  cw_run "$r" add b -n >/dev/null 2>&1
  local out
  out="$(cw_run "$r" list 2>&1)"
  assert_contains "$out" ".claude/worktrees/a" "list — a 포함"
  assert_contains "$out" ".claude/worktrees/b" "list — b 포함"
}

t_path() {
  local r="$1"
  cw_run "$r" add p1 -n >/dev/null 2>&1
  local out
  # NO_CLIPBOARD으로 stderr 노이즈 방지
  out="$(NO_CLIPBOARD=1 cw_run "$r" path p1 2>/dev/null)"
  assert_eq "$out" "$r/.claude/worktrees/p1" "path — 정확한 경로 출력"
}

t_path_nonexistent() {
  local r="$1"
  local rc=0
  NO_CLIPBOARD=1 cw_run "$r" path nope >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass "path 없는 이름 — 실패 종료"
  else fail "path 없는 이름 — exit 0 (실패 기대)"
  fi
}

t_lock_unlock() {
  local r="$1"
  cw_run "$r" add x -n >/dev/null 2>&1
  cw_run "$r" lock x "테스트" >/dev/null 2>&1
  local lf
  lf="$(git -C "$r" rev-parse --git-common-dir)/worktrees/x/locked"
  if [ -f "$lf" ]; then pass "lock — locked 마커 생성"
  else fail "lock — locked 마커 없음"; fi
  cw_run "$r" unlock x >/dev/null 2>&1
  if [ ! -f "$lf" ]; then pass "unlock — locked 마커 제거"
  else fail "unlock — locked 마커 잔존"; fi
}

t_lock_blocks_remove() {
  local r="$1"
  cw_run "$r" add lkr -n >/dev/null 2>&1
  cw_run "$r" lock lkr >/dev/null 2>&1
  local rc=0
  cw_run "$r" remove lkr >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass "lock — remove 차단"
  else fail "lock — remove 가 성공함 (차단 기대)"; fi
  assert_dir_exists "$r/.claude/worktrees/lkr" "lock — 워크트리 잔존"
}

t_move() {
  local r="$1"
  cw_run "$r" add old -n >/dev/null 2>&1
  cw_run "$r" move old new >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/old" "move — 이전 경로 삭제"
  assert_dir_exists "$r/.claude/worktrees/new" "move — 새 경로 존재"
}

t_remove_clean() {
  local r="$1"
  # main과 동일한 HEAD라 자동으로 머지 상태로 간주됨
  cw_run "$r" add rm1 -n >/dev/null 2>&1
  cw_run "$r" remove rm1 >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/rm1" "remove 깨끗 — 디렉토리 삭제"
  assert_branch_missing "$r" "worktrees-rm1" "remove 깨끗 — 브랜치 삭제"
}

t_remove_dirty_refused() {
  local r="$1"
  cw_run "$r" add rm2 -n >/dev/null 2>&1
  echo "dirty" > "$r/.claude/worktrees/rm2/dirty.txt"
  local rc=0
  cw_run "$r" remove rm2 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass "remove dirty — 거부됨"
  else fail "remove dirty — 성공함 (거부 기대)"; fi
  assert_dir_exists "$r/.claude/worktrees/rm2" "remove dirty — 워크트리 잔존"
}

t_remove_dirty_force() {
  local r="$1"
  cw_run "$r" add rm3 -n >/dev/null 2>&1
  echo "dirty" > "$r/.claude/worktrees/rm3/dirty.txt"
  cw_run "$r" remove rm3 -f >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/rm3" "remove -f dirty — 삭제"
}

t_remove_unmerged_refused() {
  local r="$1"
  cw_run "$r" add rm4 -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/rm4"
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  local rc=0
  cw_run "$r" remove rm4 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then pass "remove unmerged — 거부됨"
  else fail "remove unmerged — 성공함 (거부 기대)"; fi
  assert_dir_exists "$wp" "remove unmerged — 워크트리 잔존"
}

t_clean_merged_removed() {
  local r="$1"
  cw_run "$r" add cm1 -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/cm1"
  # 워크트리에서 작업 후 main으로 fast-forward 머지 → 진짜 머지된 상태
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  git -C "$r" merge --ff-only worktrees-cm1 -q
  cw_run "$r" clean >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/cm1" "clean — 머지된 워크트리 삭제"
  assert_branch_missing "$r" "worktrees-cm1" "clean — 머지된 브랜치 삭제"
}

# 회귀 테스트: cw add 후 작업 시작 안 한 워크트리 (HEAD == base) 자동 삭제 방지
t_clean_skips_untouched_branch() {
  local r="$1"
  cw_run "$r" add untouched -n >/dev/null 2>&1
  # 추가만 하고 commit 없음 → 브랜치 HEAD == main HEAD
  cw_run "$r" clean >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/untouched" "[회귀] clean — 미작업 워크트리 보존 (HEAD==base)"
  assert_branch_exists "$r" "worktrees-untouched" "[회귀] clean — 미작업 브랜치 보존"
}

t_clean_unmerged_kept() {
  local r="$1"
  cw_run "$r" add cm2 -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/cm2"
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  cw_run "$r" clean >/dev/null 2>&1
  assert_dir_exists "$wp" "clean — 머지 안 된 워크트리 유지"
  assert_branch_exists "$r" "worktrees-cm2" "clean — 머지 안 된 브랜치 유지"
}

# 회귀 테스트: 중첩 워크트리의 부모 디렉토리를 stray로 오판해 rm -rf 하던 버그
t_clean_nested_unmerged_preserved() {
  local r="$1"
  cw_run "$r" add fix/ceoapp -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/fix/ceoapp"
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  # 중요한 마커 파일 — clean이 부모를 통째로 rm 하면 사라짐
  echo "important" > "$wp/IMPORTANT.txt"
  cw_run "$r" clean >/dev/null 2>&1
  assert_dir_exists "$wp" "[회귀] clean — 중첩 워크트리 보존"
  if [ -f "$wp/IMPORTANT.txt" ]; then pass "[회귀] clean — 중첩 워크트리 파일 보존"
  else fail "[회귀] clean — 중첩 워크트리 파일 삭제됨 (데이터 손실 버그)"; fi
  assert_branch_exists "$r" "worktrees-fix/ceoapp" "[회귀] clean — 중첩 브랜치 보존"
}

t_clean_nested_merged_removed() {
  local r="$1"
  cw_run "$r" add fix/ceoapp -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/fix/ceoapp"
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  git -C "$r" merge --ff-only "worktrees-fix/ceoapp" -q
  cw_run "$r" clean >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/fix/ceoapp" "clean — 중첩 머지 워크트리 삭제"
  assert_dir_missing "$r/.claude/worktrees/fix" "clean — 빈 부모 디렉토리 정리"
  assert_branch_missing "$r" "worktrees-fix/ceoapp" "clean — 중첩 머지 브랜치 삭제"
}

t_clean_stray_dir() {
  local r="$1"
  mkdir -p "$r/.claude/worktrees/orphan"
  echo x > "$r/.claude/worktrees/orphan/x"
  cw_run "$r" clean >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/orphan" "clean — stray 디렉토리 삭제"
}

t_clean_prunable() {
  local r="$1"
  cw_run "$r" add pr1 -n >/dev/null 2>&1
  # .git 파일 제거 → prunable 상태 시뮬레이션
  rm -f "$r/.claude/worktrees/pr1/.git"
  local before
  before="$(git -C "$r" worktree list --porcelain | grep -c "^worktree ")"
  cw_run "$r" clean >/dev/null 2>&1
  local after
  after="$(git -C "$r" worktree list --porcelain | grep -c "^worktree ")"
  assert_dir_missing "$r/.claude/worktrees/pr1" "clean prunable — 디렉토리 삭제"
  if [ "$after" -lt "$before" ]; then pass "clean prunable — git 메타데이터 정리"
  else fail "clean prunable — 메타데이터 잔존 (before=$before, after=$after)"; fi
}

t_clean_mixed() {
  local r="$1"
  # 진짜 머지된 워크트리 (commit + ff merge)
  cw_run "$r" add merged -n >/dev/null 2>&1
  echo m > "$r/.claude/worktrees/merged/m.txt"
  git -C "$r/.claude/worktrees/merged" add m.txt
  git -C "$r/.claude/worktrees/merged" commit -q -m "m"
  git -C "$r" merge --ff-only worktrees-merged -q
  # 머지 안 된 워크트리
  cw_run "$r" add unmerged -n >/dev/null 2>&1
  echo c > "$r/.claude/worktrees/unmerged/c.txt"
  git -C "$r/.claude/worktrees/unmerged" add c.txt
  git -C "$r/.claude/worktrees/unmerged" commit -q -m "c"
  # 중첩 워크트리 (머지 안 됨)
  cw_run "$r" add nested/wt -n >/dev/null 2>&1
  echo c > "$r/.claude/worktrees/nested/wt/c.txt"
  git -C "$r/.claude/worktrees/nested/wt" add c.txt
  git -C "$r/.claude/worktrees/nested/wt" commit -q -m "c"
  # 미작업 워크트리 (HEAD == base) — 보존돼야 함
  cw_run "$r" add untouched -n >/dev/null 2>&1
  # stray 디렉토리
  mkdir -p "$r/.claude/worktrees/stray"
  echo x > "$r/.claude/worktrees/stray/x"

  cw_run "$r" clean >/dev/null 2>&1

  assert_dir_missing "$r/.claude/worktrees/merged" "mixed — 머지 워크트리 삭제"
  assert_dir_exists "$r/.claude/worktrees/unmerged" "mixed — 머지 안 된 보존"
  assert_dir_exists "$r/.claude/worktrees/nested/wt" "mixed — 중첩 머지 안 된 보존"
  assert_dir_exists "$r/.claude/worktrees/untouched" "mixed — 미작업 보존"
  assert_dir_missing "$r/.claude/worktrees/stray" "mixed — stray 삭제"
}

t_prune() {
  local r="$1"
  cw_run "$r" add pruneme -n >/dev/null 2>&1
  rm -f "$r/.claude/worktrees/pruneme/.git"
  cw_run "$r" prune >/dev/null 2>&1
  local count
  count="$(git -C "$r" worktree list --porcelain | grep -c "^prunable" || true)"
  assert_eq "$count" "0" "prune — prunable 메타데이터 정리"
}

# ─────────────────────────────────────────────────────────────
# 실행
# ─────────────────────────────────────────────────────────────

echo "${BOLD}cw 자동 테스트${RESET} ${GRAY}(${CW})${RESET}"

run_test "version 출력"                 t_version
run_test "help 출력"                    t_help
run_test "add 기본"                     t_add_basic
run_test "add 커스텀 브랜치"            t_add_custom_branch
run_test "add 중첩 경로"                t_add_nested
run_test "add detached HEAD"            t_add_detached
run_test "add lock 옵션"                t_add_locked
run_test "add -n 경로 출력"             t_add_no_open_outputs_path
run_test "list"                         t_list
run_test "path"                         t_path
run_test "path 없는 이름"               t_path_nonexistent
run_test "lock + unlock"                t_lock_unlock
run_test "lock이 remove 차단"           t_lock_blocks_remove
run_test "move (이름 변경)"             t_move
run_test "remove 깨끗"                  t_remove_clean
run_test "remove dirty 거부"            t_remove_dirty_refused
run_test "remove -f dirty"              t_remove_dirty_force
run_test "remove unmerged 거부"         t_remove_unmerged_refused
run_test "clean 머지된 워크트리"        t_clean_merged_removed
run_test "[회귀] clean 미작업 보존"     t_clean_skips_untouched_branch
run_test "clean 머지 안 된 보존"        t_clean_unmerged_kept
run_test "[회귀] clean 중첩 보존"       t_clean_nested_unmerged_preserved
run_test "clean 중첩 머지된 삭제"       t_clean_nested_merged_removed
run_test "clean stray 디렉토리"         t_clean_stray_dir
run_test "clean prunable"               t_clean_prunable
run_test "clean 혼합 시나리오"          t_clean_mixed
run_test "prune"                        t_prune

echo ""
echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo "${BOLD}결과:${RESET} ${GREEN}${PASS} pass${RESET}, ${RED}${FAIL} fail${RESET} (총 어서션 $((PASS + FAIL)) / 테스트 ${TESTS_RUN}개)"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "${RED}${BOLD}실패한 어서션:${RESET}"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  ${RED}✗${RESET} $t"
  done
  exit 1
fi

echo "${GREEN}${BOLD}전체 통과${RESET}"
exit 0
