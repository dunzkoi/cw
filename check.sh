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
  RED=$'\033[31m'; GREEN=$'\033[32m'
  GRAY=$'\033[90m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; GRAY=""; BOLD=""; RESET=""
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
  init_repo "$d"
  echo "$d"
}

# 지정 경로에 커밋 1개짜리 main 레포 초기화
init_repo() {
  local d="$1"
  git init -q -b main "$d"
  git -C "$d" config user.email "test@cw"
  git -C "$d" config user.name "cw-test"
  git -C "$d" config commit.gpgsign false
  echo "init" > "$d/README"
  git -C "$d" add README
  git -C "$d" commit -q -m "init"
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
  # 진입 실패 시 테스트 중단: 엉뚱한 cwd(이 레포 등)에서 cw clean이 돌면 안 됨
  cd "$repo" || { fail "임시 레포 진입 실패: $repo"; return; }
  "$fn" "$repo"
  cd "$orig_cwd" || exit 1
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
  # 제어 터미널 없는 환경(CI·에이전트)에서 EXIT trap의 /dev/tty 에러 소음 없음
  out="$(cw_run "$1" -v 2>&1 >/dev/null)"
  assert_eq "$out" "" "-v — stderr 비어 있음"
  out="$(NO_CLIPBOARD=1 cw_run "$1" path nope 2>&1 >/dev/null)"
  assert_not_contains "$out" "/dev/tty" "에러 종료 — /dev/tty 소음 없음"
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

# 회귀: hooksPath를 공유 .git/config에 쓰면 메인 레포·다른 워크트리의 husky hook까지 꺼짐
t_add_hookspath_worktree_only() {
  local r="$1"
  git -C "$r" config core.hooksPath .husky/_
  cw_run "$r" add hk -n >/dev/null 2>&1
  assert_eq "$(git -C "$r" config core.hooksPath)" ".husky/_" "[회귀] add — 메인 레포 hooksPath 유지"
  assert_eq "$(git -C "$r/.claude/worktrees/hk" config core.hooksPath)" "/dev/null" "add — 새 워크트리만 hooksPath=/dev/null"
}

# 셋업: .env·config/secret.json·debug.log(무시 파일) + dirty README, .worktreeinclude에 .env·config/secret.json·README
_setup_worktreeinclude() {
  local r="$1"
  printf '.env\nconfig/\n*.log\n' > "$r/.gitignore"
  git -C "$r" add .gitignore
  git -C "$r" commit -q -m "ignore"
  mkdir -p "$r/config"
  echo "KEY=1" > "$r/.env"
  echo '{"s":1}' > "$r/config/secret.json"
  echo "log" > "$r/debug.log"
  echo "dirty" > "$r/README"
  printf '.env\nconfig/secret.json\nREADME\n' > "$r/.worktreeinclude"
}

# 회귀: bare 레포(core.bare=true)에서 worktreeConfig를 켜면 모든 링크 워크트리가 bare로 인식돼 깨짐
t_add_bare_repo_worktree_usable() {
  local bare="$1/r.git" out
  git clone -q --bare "$1" "$bare"
  (cd "$bare" && cw_run "$1" add bw -n >/dev/null 2>&1)
  out="$(git -C "$bare/.claude/worktrees/bw" rev-parse --is-inside-work-tree 2>&1)"
  assert_eq "$out" "true" "[회귀] bare 레포 add — 새 워크트리가 작업 트리로 동작"
  assert_eq "$(git -C "$bare" config extensions.worktreeConfig)" "" "[회귀] bare 레포 add — worktreeConfig 안 켬"
}

# .worktreeinclude: 목록에 맞고 gitignore된 파일만 새 워크트리로 복사 (claude -w 호환)
t_add_worktreeinclude() {
  local r="$1" wp="$1/.claude/worktrees/inc"
  _setup_worktreeinclude "$r"
  cw_run "$r" add inc -n >/dev/null 2>&1
  assert_eq "$(cat "$wp/.env" 2>/dev/null)" "KEY=1" ".worktreeinclude — .env 복사"
  assert_eq "$(cat "$wp/config/secret.json" 2>/dev/null)" '{"s":1}' ".worktreeinclude — 하위 경로 파일 복사"
  assert_eq "$(cat "$wp/README")" "init" ".worktreeinclude — 추적 파일은 커밋 내용 그대로"
  if [ ! -e "$wp/debug.log" ]; then pass ".worktreeinclude — 목록에 없는 무시 파일은 복사 안 함"
  else fail ".worktreeinclude — 목록에 없는 debug.log 복사됨"; fi
}

# 브랜치가 config를 외부 디렉토리 심링크로 추적해도 그 심링크를 따라 워크트리 밖에 쓰지 않음
t_add_worktreeinclude_symlink() {
  local r="$1" ext blob tree
  ext="$(mktemp -d -t cw-ext.XXXXXX)"
  _setup_worktreeinclude "$r"
  blob="$(printf '%s' "$ext" | git -C "$r" hash-object -w --stdin)"
  tree="$( (git -C "$r" ls-tree main; printf '120000 blob %s\tconfig\n' "$blob") | git -C "$r" mktree)"
  git -C "$r" branch evil "$(git -C "$r" commit-tree "$tree" -p main -m evil)"
  cw_run "$r" add ev evil -n >/dev/null 2>&1
  if [ ! -e "$ext/secret.json" ]; then pass "[보안] .worktreeinclude — 추적 심링크 밖으로 복사 안 함"
  else fail "[보안] .worktreeinclude — 심링크 따라 워크트리 밖에 씀 ($ext/secret.json)"; fi
  assert_eq "$(cat "$r/.claude/worktrees/ev/.env" 2>/dev/null)" "KEY=1" ".worktreeinclude — 심링크 아닌 파일은 복사"
  rm -rf "$ext"
}

t_add_no_open_outputs_path() {
  local r="$1"
  local out
  out="$(cw_run "$r" add no -n 2>/dev/null | tail -1)"
  assert_eq "$out" "$r/.claude/worktrees/no" "add -n — 마지막 줄 = 경로"
}

# 회귀: add가 .claude/worktrees만 확인해서 .worktrees/x가 있으면 같은 브랜치로 다시 만들다 실패했음
t_add_existing_dot_worktrees() {
  local r="$1" out rc=0
  _add_worktree_at_base "$r" ".worktrees" "x"
  out="$(cw_run "$r" add x -n 2>/dev/null)" || rc=$?
  assert_exit 0 "$rc" "[회귀] add — .worktrees 기존 워크트리면 exit 0"
  assert_eq "$(printf '%s' "$out" | tail -1)" "$r/.worktrees/x" "[회귀] add -n — .worktrees 경로 출력"
  assert_dir_missing "$r/.claude/worktrees/x" "add — .claude/worktrees에 새로 만들지 않음"
}

t_list() {
  local r="$1"
  cw_run "$r" add a -n >/dev/null 2>&1
  cw_run "$r" add b -n >/dev/null 2>&1
  local out
  out="$(cw_run "$r" list --plain 2>&1)"
  assert_contains "$out" ".claude/worktrees/a" "list — a 포함"
  assert_contains "$out" ".claude/worktrees/b" "list — b 포함"
}

t_path_worktrees_base() {
  local r="$1"
  mkdir -p "$r/.worktrees"
  git -C "$r" worktree add "$r/.worktrees/alt1" -b feature/alt1 main -q
  local out
  out="$(NO_CLIPBOARD=1 cw_run "$r" path alt1 2>/dev/null)"
  assert_eq "$out" "$r/.worktrees/alt1" "path — .worktrees 베이스 resolve"
  out="$(NO_CLIPBOARD=1 cw_run "$r" cd alt1 2>/dev/null)"
  assert_contains "$out" ".worktrees/alt1" "cd — .worktrees 베이스 resolve"
}

t_name_worktrees_base() {
  local r="$1"
  mkdir -p "$r/.worktrees"
  git -C "$r" worktree add "$r/.worktrees/alt1" -b feature/alt1 main -q
  local out
  out="$(NO_CLIPBOARD=1 cw_run "$r" name alt1 2>/dev/null)"
  assert_eq "$out" "alt1" "name — .worktrees 상대 이름"

  cw_run "$r" add nested/wt -n >/dev/null 2>&1
  out="$(NO_CLIPBOARD=1 cw_run "$r" name nested/wt 2>/dev/null)"
  assert_eq "$out" "nested/wt" "name — 중첩 상대 이름"
}

# .worktrees 베이스에 git worktree add (cw add는 .claude/worktrees만 생성)
_add_worktree_at_base() {
  local r="$1" base="$2" name="$3"
  local branch="${4:-worktrees-${name}}"
  mkdir -p "$r/${base}"
  git -C "$r" worktree add "$r/${base}/${name}" -b "$branch" main -q
}

t_remove_worktrees_base() {
  local r="$1"
  _add_worktree_at_base "$r" ".worktrees" "wt-rm" "worktrees-wt-rm"
  cw_run "$r" remove wt-rm >/dev/null 2>&1
  assert_dir_missing "$r/.worktrees/wt-rm" "remove — .worktrees 디렉토리 삭제"
  assert_branch_missing "$r" "worktrees-wt-rm" "remove — .worktrees 브랜치 삭제"
}

t_remove_worktrees_dirty_force() {
  local r="$1"
  _add_worktree_at_base "$r" ".worktrees" "wt-dirty" "worktrees-wt-dirty"
  echo dirty > "$r/.worktrees/wt-dirty/dirty.txt"
  cw_run "$r" remove wt-dirty -f >/dev/null 2>&1
  assert_dir_missing "$r/.worktrees/wt-dirty" "remove -f — .worktrees dirty 삭제"
}

t_clean_worktrees_merged() {
  local r="$1"
  local wp="$r/.worktrees/wt-clean"
  _add_worktree_at_base "$r" ".worktrees" "wt-clean" "worktrees-wt-clean"
  echo m > "$wp/m.txt"
  git -C "$wp" add m.txt
  git -C "$wp" commit -q -m "m"
  git -C "$r" merge --ff-only worktrees-wt-clean -q
  cw_run "$r" clean main -y >/dev/null 2>&1
  assert_dir_missing "$wp" "clean — .worktrees 머지 워크트리 삭제"
  assert_branch_missing "$r" "worktrees-wt-clean" "clean — .worktrees 머지 브랜치 삭제"
}

t_clean_worktrees_stray() {
  local r="$1"
  mkdir -p "$r/.worktrees"
  mkdir -p "$r/.worktrees/orphan-wt"
  echo x > "$r/.worktrees/orphan-wt/x"
  cw_run "$r" clean main -y >/dev/null 2>&1
  assert_dir_missing "$r/.worktrees/orphan-wt" "clean — .worktrees stray 삭제"
}

t_clean_mixed_bases() {
  local r="$1"
  cw_run "$r" add claude-wt -n >/dev/null 2>&1
  local wp1="$r/.claude/worktrees/claude-wt"
  echo a > "$wp1/a.txt" && git -C "$wp1" add a.txt && git -C "$wp1" commit -q -m a
  git -C "$r" merge --ff-only worktrees-claude-wt -q
  # 두 번째 워크트리는 첫 머지 반영된 main에서 생성 → ff 머지 가능
  _add_worktree_at_base "$r" ".worktrees" "dot-wt" "worktrees-dot-wt"
  local wp2="$r/.worktrees/dot-wt"
  echo b > "$wp2/b.txt" && git -C "$wp2" add b.txt && git -C "$wp2" commit -q -m b
  git -C "$r" merge --ff-only worktrees-dot-wt -q
  cw_run "$r" clean main -y >/dev/null 2>&1
  assert_dir_missing "$wp1" "mixed bases — .claude/worktrees 삭제"
  assert_dir_missing "$wp2" "mixed bases — .worktrees 삭제"
}

t_path() {
  local r="$1"
  cw_run "$r" add p1 -n >/dev/null 2>&1
  local out
  # NO_CLIPBOARD으로 stderr 노이즈 방지
  out="$(NO_CLIPBOARD=1 cw_run "$r" path p1 2>/dev/null)"
  assert_eq "$out" "$r/.claude/worktrees/p1" "path — 정확한 경로 출력"
}

# CW_OPEN_CMD: add/open이 실행할 명령 교체 (pwd → 워크트리 경로 출력)
t_open_cmd_env() {
  local r="$1" out rc=0
  cw_run "$r" add oc -n >/dev/null 2>&1
  out="$(CW_OPEN_CMD="pwd" cw_run "$r" open oc 2>/dev/null)"
  assert_eq "$out" "$r/.claude/worktrees/oc" "CW_OPEN_CMD — open이 워크트리에서 실행"
  out="$(CW_OPEN_CMD="pwd" cw_run "$r" add oc2 2>/dev/null | tail -1)"
  assert_eq "$out" "$r/.claude/worktrees/oc2" "CW_OPEN_CMD — add 후 워크트리에서 실행"
  out="$(CW_OPEN_CMD='printf "%s|" a "b c"' cw_run "$r" open oc 2>/dev/null)"
  assert_eq "$out" "a|b c|" "CW_OPEN_CMD — 따옴표 인자 유지"
  CW_OPEN_CMD=no-such-agent cw_run "$r" open oc >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "CW_OPEN_CMD — 없는 명령이면 exit 1"
}

# 자동완성: __names가 이름 후보를, completion이 셸 스크립트를 출력
t_completion() {
  local r="$1" out rc=0 names
  names="c1"$'\n'"fix/c2"
  cw_run "$r" add c1 -n >/dev/null 2>&1
  cw_run "$r" add fix/c2 -n >/dev/null 2>&1
  out="$(cw_run "$r" __names 2>/dev/null)"
  assert_eq "$out" "$names" "__names — 워크트리 이름 출력"
  cw_run "$r" completion zsh >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "completion zsh — exit 0"
  # 완성 함수 실제 호출: open 뒤 이름 후보 (cw는 PATH에서 찾음)
  out="$(PATH="$SCRIPT_DIR:$PATH" HOME="$r" bash -c \
    'eval "$(cw completion bash)"; COMP_WORDS=(cw open ""); COMP_CWORD=2; _cw; printf "%s\n" "${COMPREPLY[@]}"')"
  assert_eq "$out" "$names" "completion bash — open 이름 후보"
  if command -v zsh >/dev/null 2>&1; then
    # compinit 없이 compadd를 출력 함수로 대체해 로직만 검사
    out="$(PATH="$SCRIPT_DIR:$PATH" HOME="$r" zsh -fc \
      'compdef() {}; eval "$(cw completion zsh)"; compadd() { print -l -- "${@:#--}"; }; words=(cw open ""); CURRENT=3; _cw')"
    assert_eq "$out" "$names" "completion zsh — open 이름 후보"
  fi
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

# 셋업: 같은 이름 x가 두 베이스에 존재 → admin 디렉토리 .claude/worktrees/x=x, .worktrees/x=x1
# (cw add x는 .worktrees/x가 있으면 그걸 열므로 .claude 쪽을 먼저 만든다)
# 둘 다 커밋 후 ff-merge (잠금만 없으면 clean 삭제 대상)
_setup_same_name_bases() {
  local r="$1" a="$1/.worktrees/x" b="$1/.claude/worktrees/x"
  cw_run "$r" add x -n >/dev/null 2>&1
  echo b > "$b/b.txt" && git -C "$b" add b.txt && git -C "$b" commit -q -m b
  git -C "$r" merge --ff-only worktrees-x -q
  _add_worktree_at_base "$r" ".worktrees" "x" "wx"
  echo a > "$a/a.txt" && git -C "$a" add a.txt && git -C "$a" commit -q -m a
  git -C "$r" merge --ff-only wx -q
}

# 잠금 판정이 basename(worktrees/x/locked)을 보면 엉뚱한 워크트리의 잠금을 읽음
t_lock_same_name_dot_worktrees() {
  local r="$1" out
  _setup_same_name_bases "$r"
  git -C "$r" worktree lock "$r/.worktrees/x"
  out="$(cw_run "$r" clean main -y 2>&1)"
  assert_dir_exists "$r/.worktrees/x" "[회귀] 동명 잠금 — 잠긴 .worktrees/x 유지"
  assert_dir_missing "$r/.claude/worktrees/x" "[회귀] 동명 잠금 — 잠금 없는 .claude/worktrees/x 정리"
  assert_not_contains "$out" "제거 실패" "[회귀] 동명 잠금 — 제거 실패 없음"
}

t_lock_same_name_claude_worktrees() {
  local r="$1" out
  _setup_same_name_bases "$r"
  git -C "$r" worktree lock "$r/.claude/worktrees/x"
  out="$(cw_run "$r" clean main -y 2>&1)"
  assert_dir_exists "$r/.claude/worktrees/x" "[회귀] 동명 잠금 — 잠긴 .claude/worktrees/x 유지"
  assert_dir_missing "$r/.worktrees/x" "[회귀] 동명 잠금 — 잠금 없는 .worktrees/x 정리"
  assert_contains "$out" "잠금됨" "[회귀] 동명 잠금 — 잠금으로 판정"
  assert_not_contains "$out" "제거 실패" "[회귀] 동명 잠금 — 삭제 대상에 안 올림"
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

# 셋업: detached 워크트리에 기준(main)에 없는 커밋 1개
_setup_detached_commit() {
  local wp="$1/.claude/worktrees/dx"
  cw_run "$1" add dx -d -n >/dev/null 2>&1
  echo d > "$wp/d.txt"
  git -C "$wp" add d.txt
  git -C "$wp" commit -q -m "detached work"
}

# 회귀: detached는 브랜치가 없어 머지 판정 없이 지워져 커밋이 어떤 ref에서도 안 닿았음
t_remove_detached_unmerged_refused() {
  local r="$1" rc=0
  _setup_detached_commit "$r"
  cw_run "$r" remove dx >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "[회귀] remove detached 미포함 커밋 — exit 1"
  assert_dir_exists "$r/.claude/worktrees/dx" "[회귀] remove detached 미포함 커밋 — 워크트리 유지"
}

t_remove_detached_force() {
  local r="$1" rc=0
  # 기준에 포함된 detached(커밋 없음)는 -f 없이 삭제
  cw_run "$r" add d0 -d -n >/dev/null 2>&1
  cw_run "$r" remove d0 >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "remove detached 기준 포함 — exit 0"
  assert_dir_missing "$r/.claude/worktrees/d0" "remove detached 기준 포함 — 삭제"
  _setup_detached_commit "$r"
  cw_run "$r" remove dx -f >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/dx" "remove -f detached 미포함 커밋 — 삭제"
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
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/cm1" "clean — 머지된 워크트리 삭제"
  assert_branch_missing "$r" "worktrees-cm1" "clean — 머지된 브랜치 삭제"
}

# 삭제 전 확인: -y 없으면 목록만 보여주고 응답에 따라 실행/취소
t_clean_confirm_prompt() {
  local r="$1" out wp="$1/.claude/worktrees/cfn"
  cw_run "$r" add cfn -n >/dev/null 2>&1
  echo x > "$wp/x.txt"
  git -C "$wp" add x.txt
  git -C "$wp" commit -q -m "x"
  git -C "$r" merge --ff-only worktrees-cfn -q

  out="$(printf 'n\n' | cw_run "$r" clean 2>&1)"
  assert_contains "$out" "삭제 대상" "clean 확인 — 삭제 대상 목록 출력"
  assert_dir_exists "$r/.claude/worktrees/cfn" "clean 확인 — n 응답 시 워크트리 보존"
  assert_branch_exists "$r" "worktrees-cfn" "clean 확인 — n 응답 시 브랜치 보존"

  # 빈 stdin(cron 등) → EOF → 안전 폴백으로 보존
  cw_run "$r" clean </dev/null >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/cfn" "clean 확인 — stdin EOF 시 보존"

  printf 'y\n' | cw_run "$r" clean >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/cfn" "clean 확인 — y 응답 시 삭제"
  assert_branch_missing "$r" "worktrees-cfn" "clean 확인 — y 응답 시 브랜치 삭제"
}

# 회귀 테스트: cw add 후 작업 시작 안 한 워크트리 (HEAD == base) 자동 삭제 방지
t_clean_skips_untouched_branch() {
  local r="$1"
  cw_run "$r" add untouched -n >/dev/null 2>&1
  # 추가만 하고 commit 없음 → 브랜치 HEAD == main HEAD
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/untouched" "[회귀] clean — 미작업 워크트리 보존 (HEAD==base)"
  assert_branch_exists "$r" "worktrees-untouched" "[회귀] clean — 미작업 브랜치 보존"
}

# 회귀 테스트 (v0.1.9 — 사용자 실제 케이스):
# 옛 main commit에 머문 브랜치 + 워크트리에 uncommitted work 있음.
# git branch --merged main에는 포함되지만 (tip이 main ancestor) 실제 작업은 미커밋.
# 이전 버전은 br_sha != base_sha 라서 보호 우회 → dirty 검사 없이 삭제 → 데이터 손실.
t_clean_dirty_old_base_kept() {
  local r="$1"
  # 1. main에 후속 commit 추가 (브랜치 생성 시점을 옛 base로 만들기 위해)
  cw_run "$r" add stale feature/stale -n >/dev/null 2>&1
  # main을 advance — 다른 워크트리 만들고 머지
  cw_run "$r" add advancer -n >/dev/null 2>&1
  echo a > "$r/.claude/worktrees/advancer/a.txt"
  git -C "$r/.claude/worktrees/advancer" add a.txt
  git -C "$r/.claude/worktrees/advancer" commit -q -m "advance"
  git -C "$r" merge --ff-only worktrees-advancer -q
  # 이제 feature/stale은 옛 main에 머물러 있고 main은 앞으로 이동했음
  # feature/stale이 --merged main 에 포함되는지 확인 (sanity)
  if ! git -C "$r" branch --merged main | grep -q "feature/stale"; then
    fail "[회귀] 셋업 실패 — feature/stale이 --merged 에 포함 안 됨"
    return
  fi
  # 사용자가 워크트리에서 작업 중 (uncommitted)
  echo "WIP" > "$r/.claude/worktrees/stale/wip.txt"
  echo "MORE" >> "$r/README"
  # cw clean 실행 — 삭제되면 데이터 손실
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/stale" \
    "[회귀] clean — 옛 base + dirty 워크트리 보존 (사용자 케이스)"
  if [ -f "$r/.claude/worktrees/stale/wip.txt" ]; then
    pass "[회귀] clean — uncommitted 파일 보존"
  else
    fail "[회귀] clean — uncommitted 파일 사라짐 (데이터 손실)"
  fi
  assert_branch_exists "$r" "feature/stale" "[회귀] clean — 옛 base 브랜치 보존"
}

# 회귀: 옛 main tip에 주차 + 미작업(ancestor, reflog≤1) → 유지 (orca 워크스페이스 보호)
t_clean_old_base_no_work_kept() {
  local r="$1"
  cw_run "$r" add stale2 feature/stale2 -n >/dev/null 2>&1
  cw_run "$r" add advancer2 -n >/dev/null 2>&1
  echo a > "$r/.claude/worktrees/advancer2/a.txt"
  git -C "$r/.claude/worktrees/advancer2" add a.txt
  git -C "$r/.claude/worktrees/advancer2" commit -q -m "advance"
  git -C "$r" merge --ff-only worktrees-advancer2 -q
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/stale2" \
    "[회귀] clean — 옛 base 주차 미작업 보존"
  assert_branch_exists "$r" "feature/stale2" "[회귀] clean — 옛 base 주차 브랜치 보존"
}

# patch-equivalent(머지됨) + 빈 reflog → 삭제 (ceo-front 15764 케이스)
t_clean_patch_merged_empty_reflog() {
  local r="$1"
  cw_run "$r" add pm1 -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/pm1"
  echo y > "$wp/y.txt"
  git -C "$wp" add y.txt
  git -C "$wp" commit -q -m "feature y"
  echo m > "$r/m.txt"
  git -C "$r" add m.txt
  git -C "$r" commit -q -m "main side"
  git -C "$r" cherry-pick --quiet worktrees-pm1 >/dev/null 2>&1
  # reflog 비우기 — 실환경(복사/만료)에서 0줄인 경우 재현
  : > "$(git -C "$r" rev-parse --git-common-dir)/logs/refs/heads/worktrees-pm1"
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_missing "$wp" "[회귀] clean — patch-merged + 빈 reflog 삭제"
  assert_branch_missing "$r" "worktrees-pm1" "[회귀] clean — patch-merged 브랜치 삭제"
}

# 회귀 테스트 (v0.1.10 — 사용자 LMS 케이스):
# 브랜치가 rebase되어 main과 SHA가 다르지만 patch-id는 동일.
# `git branch --merged`는 reachability 기반이라 false-negative.
# is_effectively_merged()는 git cherry(patch-id) 기반이라 잡음.
t_clean_rebase_merged_removed() {
  local r="$1"
  cw_run "$r" add rb1 -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/rb1"
  # 워크트리에서 commit Y
  echo y > "$wp/y.txt"
  git -C "$wp" add y.txt
  git -C "$wp" commit -q -m "feature y"
  # main을 다른 방향으로 advance시킴 — cherry-pick 시 parent가 달라져 SHA 분기
  echo m > "$r/m.txt"
  git -C "$r" add m.txt
  git -C "$r" commit -q -m "main side commit"
  # main에 같은 patch를 cherry-pick (rebase 후 머지된 효과 — SHA만 다름, patch-id 동일)
  git -C "$r" cherry-pick --quiet worktrees-rb1 >/dev/null 2>&1
  # 셋업 sanity: SHA 분기됐는지 확인
  local main_sha rb_sha
  main_sha="$(git -C "$r" rev-parse main)"
  rb_sha="$(git -C "$r" rev-parse worktrees-rb1)"
  if [ "$main_sha" = "$rb_sha" ]; then
    fail "[회귀] 셋업 — rebase 시뮬레이션 SHA 동일"
    return
  fi
  # 워크트리는 깨끗 (uncommitted 변경 없음 — dirty 가드 통과)
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_missing "$wp" \
    "[회귀] clean — rebase 후 patch-equivalent 머지 삭제 (SHA 달라도 patch-id 일치)"
  assert_branch_missing "$r" "worktrees-rb1" \
    "[회귀] clean — rebase 후 머지 브랜치 삭제"
}

# 셋업: <name> 워크트리에 커밋 2개(<name>1, <name>2 파일). 세 번째 인자가 있으면 그 커밋까지 main에 squash 머지
_setup_squash() {
  local r="$1" name="$2" upto="${3:-}" wp="$1/.claude/worktrees/$2" f
  cw_run "$r" add "$name" -n >/dev/null 2>&1
  for f in "${name}1" "${name}2"; do
    echo "$f" > "$wp/$f"
    git -C "$wp" add "$f"
    git -C "$wp" commit -q -m "$f"
  done
  [ -n "$upto" ] || return 0
  git -C "$r" merge --squash -q "$upto" >/dev/null 2>&1
  git -C "$r" commit -q -m "squash ${name}"
}

# squash 머지(커밋 2개 → 1개)는 git cherry patch-id로 못 잡음 → 합친 diff로 재확인
t_clean_squash_merged() {
  local r="$1"
  _setup_squash "$r" sqf worktrees-sqf
  _setup_squash "$r" sqp worktrees-sqp~1
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/sqf" "clean — squash 머지 워크트리 삭제"
  assert_branch_missing "$r" "worktrees-sqf" "clean — squash 머지 브랜치 삭제"
  assert_dir_exists "$r/.claude/worktrees/sqp" "clean — 일부만 squash 머지된 워크트리 유지"
  assert_branch_exists "$r" "worktrees-sqp" "clean — 일부만 squash 머지된 브랜치 유지"
}

# 회귀: 커밋+revert(순 diff 0) 브랜치의 임시 commit이 main의 빈 commit(CI 트리거 등)과 매치돼 머지로 오판됐음
t_remove_net_zero_kept() {
  local r="$1" rc=0 wp="$1/.claude/worktrees/nz"
  cw_run "$r" add nz -n >/dev/null 2>&1
  echo z > "$wp/z.txt"
  git -C "$wp" add z.txt
  git -C "$wp" commit -q -m "z"
  git -C "$wp" revert --no-edit HEAD >/dev/null 2>&1
  git -C "$r" commit -q --allow-empty -m "ci: trigger"
  cw_run "$r" remove nz >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "[회귀] remove 순 diff 0 브랜치 — exit 1"
  assert_branch_exists "$r" "worktrees-nz" "[회귀] remove 순 diff 0 브랜치 — 브랜치 유지"
}

t_remove_prune_squash_merged() {
  local r="$1" rc=0
  _setup_squash "$r" sqr worktrees-sqr
  _setup_squash "$r" sqn worktrees-sqn
  cw_run "$r" remove sqr >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "remove squash 머지 — exit 0"
  assert_branch_missing "$r" "worktrees-sqr" "remove squash 머지 — 브랜치 삭제"
  rm -f "$r/.claude/worktrees/sqn/.git"
  cw_run "$r" prune >/dev/null 2>&1
  assert_branch_missing "$r" "worktrees-sqn" "prune squash 머지 — 브랜치 삭제"
}

# 회귀 테스트: detached HEAD에서도 dirty 보호
t_clean_detached_dirty_kept() {
  local r="$1"
  cw_run "$r" add det1 -d -n >/dev/null 2>&1
  echo dirty > "$r/.claude/worktrees/det1/wip.txt"
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/det1" \
    "[회귀] clean — detached + dirty 보존"
}

# 원격 main에만 머지(GitHub PR 머지 후 로컬 main 미 pull): clean은 유지, clean -F는 origin/main 기준으로 삭제
t_clean_fetch_remote_merged() {
  local r="$1" bare="$1/.remote.git" wp="$1/.claude/worktrees/rf" rc=0
  git init -q --bare "$bare"
  git -C "$r" remote add origin "$bare"
  git -C "$r" push -q origin main
  cw_run "$r" add rf -n >/dev/null 2>&1
  echo rf > "$wp/rf.txt"
  git -C "$wp" add rf.txt
  git -C "$wp" commit -q -m "rf"
  git -C "$r" push -q origin worktrees-rf
  # 원격에서 PR 머지 (로컬 origin/main은 그대로)
  git -C "$bare" update-ref refs/heads/main refs/heads/worktrees-rf
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$wp" "clean — 원격에만 머지된 워크트리 유지 (로컬 기준)"
  cw_run "$r" clean -F -y >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "clean -F — exit 0"
  assert_dir_missing "$wp" "clean -F — origin/main 기준으로 삭제"
  assert_branch_missing "$r" "worktrees-rf" "clean -F — 브랜치 삭제"
}

# 회귀: 방금 만든 detached(HEAD reflog≤1)는 기준 ancestor여도 유지, 커밋 후 머지된 detached는 삭제
t_clean_detached_untouched_kept() {
  local r="$1" wp2="$1/.claude/worktrees/d2"
  cw_run "$r" add d1 -d -n >/dev/null 2>&1
  cw_run "$r" add d2 -d -n >/dev/null 2>&1
  echo d > "$wp2/d.txt"
  git -C "$wp2" add d.txt
  git -C "$wp2" commit -q -m "d2"
  git -C "$r" merge --ff-only "$(git -C "$wp2" rev-parse HEAD)" -q
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$r/.claude/worktrees/d1" "[회귀] clean — 미작업 detached 보존"
  assert_dir_missing "$wp2" "clean — 커밋이 기준에 들어간 detached 삭제"
}

t_clean_unmerged_kept() {
  local r="$1"
  cw_run "$r" add cm2 -n >/dev/null 2>&1
  local wp="$r/.claude/worktrees/cm2"
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  cw_run "$r" clean -y >/dev/null 2>&1
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
  cw_run "$r" clean -y >/dev/null 2>&1
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
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/fix/ceoapp" "clean — 중첩 머지 워크트리 삭제"
  assert_dir_missing "$r/.claude/worktrees/fix" "clean — 빈 부모 디렉토리 정리"
  assert_branch_missing "$r" "worktrees-fix/ceoapp" "clean — 중첩 머지 브랜치 삭제"
}

t_clean_stray_dir() {
  local r="$1"
  mkdir -p "$r/.claude/worktrees/orphan"
  echo x > "$r/.claude/worktrees/orphan/x"
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_missing "$r/.claude/worktrees/orphan" "clean — stray 디렉토리 삭제"
}

t_clean_prunable() {
  local r="$1"
  cw_run "$r" add pr1 -n >/dev/null 2>&1
  # .git 파일 제거 → prunable 상태 시뮬레이션
  rm -f "$r/.claude/worktrees/pr1/.git"
  local before
  before="$(git -C "$r" worktree list --porcelain | grep -c "^worktree ")"
  cw_run "$r" clean -y >/dev/null 2>&1
  local after
  after="$(git -C "$r" worktree list --porcelain | grep -c "^worktree ")"
  assert_dir_missing "$r/.claude/worktrees/pr1" "clean prunable — 디렉토리 삭제"
  if [ "$after" -lt "$before" ]; then pass "clean prunable — git 메타데이터 정리"
  else fail "clean prunable — 메타데이터 잔존 (before=$before, after=$after)"; fi
}

# 회귀: 관리 베이스 밖 prunable(.git 파일만 잃은 orca 등)을 사용자 파일째 rm -rf 했음 — 메타데이터만 정리
t_clean_external_prunable_kept() {
  local r="$1" ext wp
  ext="$(mktemp -d -t cw-ext.XXXXXX)"
  ext="$(cd "$ext" && pwd -P)"
  wp="$ext/orca"
  git -C "$r" worktree add "$wp" -b orca main -q
  rm -f "$wp/.git"
  echo note > "$wp/notes.txt"
  cw_run "$r" clean -y >/dev/null 2>&1
  assert_dir_exists "$wp" "[회귀] clean — 외부 prunable 디렉토리 유지"
  assert_eq "$(cat "$wp/notes.txt" 2>/dev/null)" "note" "[회귀] clean — 외부 prunable 사용자 파일 유지"
  assert_not_contains "$(git -C "$r" worktree list --porcelain)" "$wp" "clean — 외부 prunable 메타데이터 정리"
  rm -rf "$ext"
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

  cw_run "$r" clean -y >/dev/null 2>&1

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

# 셋업: .worktrees/f(feat, 미머지 커밋) + feat-x(main tip = 머지됨)
# grep -w는 하이픈을 단어 경계로 봐서 feat-x 머지 시 feat도 머지로 오판했음
_setup_feat_prefix() {
  local r="$1"
  _add_worktree_at_base "$r" ".worktrees" "f" "feat"
  echo f > "$r/.worktrees/f/f.txt"
  git -C "$r/.worktrees/f" add f.txt
  git -C "$r/.worktrees/f" commit -q -m "feat"
  git -C "$r" branch feat-x main
}

t_prune_prefix_unmerged_kept() {
  local r="$1"
  _setup_feat_prefix "$r"
  rm -f "$r/.worktrees/f/.git"
  cw_run "$r" prune >/dev/null 2>&1
  assert_branch_exists "$r" "feat" "[회귀] prune — feat-x가 머지돼도 미머지 feat 유지"
}

t_remove_prefix_unmerged_refused() {
  local r="$1" rc=0
  _setup_feat_prefix "$r"
  cw_run "$r" remove f >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "[회귀] remove — feat-x가 머지돼도 미머지 feat는 exit 1"
  assert_dir_exists "$r/.worktrees/f" "[회귀] remove — 미머지 워크트리 유지"
  assert_branch_exists "$r" "feat" "[회귀] remove — 미머지 브랜치 유지"
}

# cherry-pick으로 main에 흡수된 브랜치: clean과 같은 patch-id 판정으로 remove도 삭제
t_remove_cherry_picked() {
  local r="$1" rc=0 wp="$1/.claude/worktrees/cp1"
  cw_run "$r" add cp1 -n >/dev/null 2>&1
  echo y > "$wp/y.txt"
  git -C "$wp" add y.txt
  git -C "$wp" commit -q -m "feature y"
  echo m > "$r/m.txt"
  git -C "$r" add m.txt
  git -C "$r" commit -q -m "main side"
  git -C "$r" cherry-pick --quiet worktrees-cp1 >/dev/null 2>&1
  cw_run "$r" remove cp1 >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "remove cherry-pick 흡수 — exit 0"
  assert_dir_missing "$wp" "remove cherry-pick 흡수 — 워크트리 삭제"
  assert_branch_missing "$r" "worktrees-cp1" "remove cherry-pick 흡수 — 브랜치 삭제"
}

# 기준 브랜치 오타: git cherry 실패를 머지로 오판하면 clean/prune이 미머지 브랜치를 지움
t_bad_base_keeps_unmerged() {
  local r="$1" wp="$1/.claude/worktrees/bb"
  cw_run "$r" add bb -n >/dev/null 2>&1
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  cw_run "$r" clean nope -y >/dev/null 2>&1
  assert_dir_exists "$wp" "[회귀] clean 기준 오타 — 미머지 워크트리 유지"
  rm -f "$wp/.git"
  cw_run "$r" prune nope >/dev/null 2>&1
  assert_branch_exists "$r" "worktrees-bb" "[회귀] prune 기준 오타 — 미머지 브랜치 유지"
}

# 관리 베이스(.claude/worktrees, .worktrees) 밖 linked worktree도 clean 대상
t_clean_external_merged() {
  local r="$1"
  local ext wp
  ext="$(mktemp -d -t cw-ext.XXXXXX)"
  ext="$(cd "$ext" && pwd -P)"
  wp="$ext/ext-merged"
  git -C "$r" worktree add "$wp" -b feature/ext-merged main -q
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "ext"
  git -C "$r" merge --ff-only feature/ext-merged -q
  cw_run "$r" clean main -y >/dev/null 2>&1
  assert_dir_missing "$wp" "clean — 외부 경로 머지 워크트리 삭제"
  assert_branch_missing "$r" "feature/ext-merged" "clean — 외부 경로 머지 브랜치 삭제"
  rm -rf "$ext"
}

t_clean_external_unmerged_kept() {
  local r="$1"
  local ext wp
  ext="$(mktemp -d -t cw-ext.XXXXXX)"
  ext="$(cd "$ext" && pwd -P)"
  wp="$ext/ext-keep"
  git -C "$r" worktree add "$wp" -b feature/ext-keep main -q
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "ext keep"
  cw_run "$r" clean main -y >/dev/null 2>&1
  assert_dir_exists "$wp" "clean — 외부 경로 미머지 워크트리 보존"
  assert_branch_exists "$r" "feature/ext-keep" "clean — 외부 경로 미머지 브랜치 보존"
  # resolve/remove도 basename으로 외부 경로를 찾는지
  cw_run "$r" remove ext-keep -f >/dev/null 2>&1
  assert_dir_missing "$wp" "remove — 외부 경로 basename resolve"
  rm -rf "$ext"
}

# 회귀: 메인 워크트리가 develop이면 main이 "develop에 머지됨"으로 보여 clean·remove·prune이 main 브랜치까지 지웠음
t_protect_default_branch() {
  local r="$1" wp="$1/.claude/worktrees/mw" out
  echo b > "$r/b.txt" && git -C "$r" add b.txt && git -C "$r" commit -q -m b
  git -C "$r" checkout -q -b develop
  cw_run "$r" add mw main -n >/dev/null 2>&1
  out="$(cw_run "$r" clean -y 2>&1)"
  assert_dir_exists "$wp" "[회귀] clean — 기본 브랜치 워크트리 유지"
  assert_branch_exists "$r" "main" "[회귀] clean — main 브랜치 유지"
  assert_contains "$out" "기본 브랜치 체크아웃" "clean — 유지 사유 출력"
  cw_run "$r" remove mw >/dev/null 2>&1
  assert_dir_missing "$wp" "remove — 기본 브랜치 워크트리는 삭제"
  assert_branch_exists "$r" "main" "[회귀] remove — main 브랜치 유지"
  cw_run "$r" add mw main -n >/dev/null 2>&1
  cw_run "$r" remove mw -f >/dev/null 2>&1
  assert_branch_exists "$r" "main" "[회귀] remove -f — main 브랜치 유지"
  cw_run "$r" add mw main -n >/dev/null 2>&1
  rm -f "$wp/.git"
  cw_run "$r" prune >/dev/null 2>&1
  assert_branch_exists "$r" "main" "[회귀] prune — main 브랜치 유지"
}

# 공백 경로 레포 (iCloud Drive, Application Support 등): porcelain을 첫 단어에서 자르면 전부 실패
t_space_in_repo_path() {
  local sp="$1/My Proj" wp out
  wp="$sp/.claude/worktrees/foo"
  init_repo "$sp"
  cd "$sp" || return
  cw_run "$sp" add foo -n >/dev/null 2>&1
  assert_dir_exists "$wp" "공백 경로 — add -n 생성"
  out="$(NO_CLIPBOARD=1 cw_run "$sp" path foo 2>/dev/null)"
  assert_eq "$out" "$wp" "공백 경로 — path 출력"
  echo c > "$wp/c.txt"
  git -C "$wp" add c.txt
  git -C "$wp" commit -q -m "c"
  git -C "$sp" merge --ff-only worktrees-foo -q
  cw_run "$sp" clean -y >/dev/null 2>&1
  assert_dir_missing "$wp" "공백 경로 — clean -y 머지 워크트리 삭제"
  assert_branch_missing "$sp" "worktrees-foo" "공백 경로 — clean -y 브랜치 삭제"
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
run_test "[회귀] add hooksPath 워크트리 한정" t_add_hookspath_worktree_only
run_test "[회귀] add bare 레포"         t_add_bare_repo_worktree_usable
run_test "add .worktreeinclude 복사"    t_add_worktreeinclude
run_test "[보안] .worktreeinclude 심링크" t_add_worktreeinclude_symlink
run_test "add -n 경로 출력"             t_add_no_open_outputs_path
run_test "[회귀] add .worktrees 기존"   t_add_existing_dot_worktrees
run_test "list"                         t_list
run_test "path .worktrees 베이스"       t_path_worktrees_base
run_test "name + 클립보드"              t_name_worktrees_base
run_test "path"                         t_path
run_test "path 없는 이름"               t_path_nonexistent
run_test "CW_OPEN_CMD"                  t_open_cmd_env
run_test "자동완성"                     t_completion
run_test "lock + unlock"                t_lock_unlock
run_test "lock이 remove 차단"           t_lock_blocks_remove
run_test "[회귀] 동명 잠금 .worktrees"  t_lock_same_name_dot_worktrees
run_test "[회귀] 동명 잠금 .claude"     t_lock_same_name_claude_worktrees
run_test "move (이름 변경)"             t_move
run_test "remove 깨끗"                  t_remove_clean
run_test "remove .worktrees"              t_remove_worktrees_base
run_test "remove .worktrees -f dirty"     t_remove_worktrees_dirty_force
run_test "remove dirty 거부"            t_remove_dirty_refused
run_test "remove -f dirty"              t_remove_dirty_force
run_test "remove unmerged 거부"         t_remove_unmerged_refused
run_test "[회귀] remove detached 미포함 거부" t_remove_detached_unmerged_refused
run_test "remove detached -f"           t_remove_detached_force
run_test "clean 머지된 워크트리"        t_clean_merged_removed
run_test "clean 삭제 전 확인"           t_clean_confirm_prompt
run_test "clean .worktrees 머지"          t_clean_worktrees_merged
run_test "clean .worktrees stray"       t_clean_worktrees_stray
run_test "clean 양쪽 베이스 혼합"       t_clean_mixed_bases
run_test "[회귀] clean 미작업 보존"     t_clean_skips_untouched_branch
run_test "[회귀] clean dirty+옛base"    t_clean_dirty_old_base_kept
run_test "[회귀] clean 옛base 주차보존" t_clean_old_base_no_work_kept
run_test "[회귀] clean patch+빈reflog"  t_clean_patch_merged_empty_reflog
run_test "[회귀] clean rebase 머지"     t_clean_rebase_merged_removed
run_test "clean squash 머지"            t_clean_squash_merged
run_test "remove/prune squash 머지"     t_remove_prune_squash_merged
run_test "[회귀] remove 순 diff 0 유지"  t_remove_net_zero_kept
run_test "[회귀] clean detached dirty"  t_clean_detached_dirty_kept
run_test "[회귀] clean detached 미작업" t_clean_detached_untouched_kept
run_test "clean 머지 안 된 보존"        t_clean_unmerged_kept
run_test "clean -F 원격 기준"           t_clean_fetch_remote_merged
run_test "[회귀] clean 중첩 보존"       t_clean_nested_unmerged_preserved
run_test "clean 중첩 머지된 삭제"       t_clean_nested_merged_removed
run_test "clean stray 디렉토리"         t_clean_stray_dir
run_test "clean prunable"               t_clean_prunable
run_test "[회귀] clean 외부 prunable 보존" t_clean_external_prunable_kept
run_test "clean 혼합 시나리오"          t_clean_mixed
run_test "prune"                        t_prune
run_test "[회귀] prune 접두 이름 미머지" t_prune_prefix_unmerged_kept
run_test "[회귀] remove 접두 이름 미머지" t_remove_prefix_unmerged_refused
run_test "remove cherry-pick 흡수"      t_remove_cherry_picked
run_test "[회귀] 기준 브랜치 오타"      t_bad_base_keeps_unmerged
run_test "clean 외부 경로 머지"         t_clean_external_merged
run_test "clean/remove 외부 경로"       t_clean_external_unmerged_kept
run_test "[회귀] 기본 브랜치 보호"      t_protect_default_branch
run_test "공백 들어간 레포 경로"        t_space_in_repo_path

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
