#!/bin/bash
# cw — Claude Worktree: 서브커맨드 기반 claude worktree 관리

set -euo pipefail
IFS=$'\n\t'

CW_VERSION="0.1.18"
DEFAULT_WORKTREE_BASE=".claude/worktrees"
# resolve/clean 대상 — 앞쪽이 우선 (.claude/worktrees → .worktrees)
WORKTREE_BASES=(".claude/worktrees" ".worktrees")
INIT_HOOK="${HOME}/.claude/worktree-init.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
  C_GRAY=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

ok()   { echo "${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "${C_YELLOW}⚠${C_RESET} $*"; }
err()  { echo "${C_RED}✗${C_RESET} $*" >&2; }
info() { echo "${C_CYAN}●${C_RESET} $*"; }
hint() { echo "${C_BLUE}💡${C_RESET} $*"; }
skip() { echo "${C_GRAY}·${C_RESET} ${C_DIM}$*${C_RESET}"; }

# 진행 스피너 — TTY일 때 백그라운드에서 회전 프레임 출력
_SPINNER_PID=""
_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spinner_start() {
  [ -t 1 ] || return 0
  spinner_stop  # 이전 스피너 잔존 방지
  local msg="$1"
  (
    local i=0 fcount=${#_SPINNER_FRAMES[@]}
    while :; do
      printf '\r\033[K%s%s %s%s' "$C_DIM" "${_SPINNER_FRAMES[$((i % fcount))]}" "$msg" "$C_RESET"
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  _SPINNER_PID=$!
}

spinner_stop() {
  [ -n "${_SPINNER_PID:-}" ] || return 0
  kill "$_SPINNER_PID" 2>/dev/null || true
  wait "$_SPINNER_PID" 2>/dev/null || true
  _SPINNER_PID=""
  [ -t 1 ] && printf '\r\033[K'
}

# 인터럽트/종료 시 스피너·커서 정리
trap 'spinner_stop; printf "\033[?25h" > /dev/tty 2>/dev/null || true' EXIT INT TERM

help() {
  cat <<EOF
${C_BOLD}cw — Claude Worktree${C_RESET} ${C_DIM}v${CW_VERSION}${C_RESET}

${C_BOLD}Commands:${C_RESET}
  ${C_CYAN}add${C_RESET} <folder> [branch] [base] [옵션]
                                  워크트리 생성 후 claude 실행
  ${C_CYAN}open${C_RESET} <name>                    기존 워크트리에서 claude 실행
  ${C_CYAN}path${C_RESET} <name>                    워크트리 경로 출력 (claude 실행 X)
  ${C_CYAN}list${C_RESET} [옵션]                  워크트리 목록 (TTY: 대화형 선택)
  ${C_CYAN}cd${C_RESET} <name>                      cd 명령 출력 (eval "\$(cw cd <name>)")
  ${C_CYAN}cursor${C_RESET} <name>                  Cursor에서 워크트리 열기
  ${C_CYAN}name${C_RESET} <name>                    워크트리 이름 출력 + 클립보드 복사
  ${C_CYAN}remove${C_RESET} <name> [-f|--force]     특정 워크트리 삭제 (브랜치 포함)
  ${C_CYAN}clean${C_RESET} [base]                    머지된 워크트리 일괄 정리 (git worktree 전체, 메인 제외)
  ${C_CYAN}lock${C_RESET} <name> [reason]           워크트리 잠금 (삭제 방지)
  ${C_CYAN}unlock${C_RESET} <name>                   워크트리 잠금 해제
  ${C_CYAN}move${C_RESET} <name> <new-name>          워크트리 이름 변경
  ${C_CYAN}prune${C_RESET} [base]                    stale 참조 정리 (기본: 메인 워크트리의 현재 브랜치)
  ${C_CYAN}repair${C_RESET}                          워크트리 링크 복구 (레포 이동 후)
  ${C_CYAN}help${C_RESET}                            이 도움말
  ${C_CYAN}-v, --version${C_RESET}                   버전 출력

${C_BOLD}Arguments (add):${C_RESET}
  ${C_DIM}folder${C_RESET}        워크트리 폴더명 (조회/삭제/정리: .claude/worktrees + .worktrees)
  ${C_DIM}branch${C_RESET}        생성할 git 브랜치명 (생략 시 worktrees-<folder>)
  ${C_DIM}base${C_RESET}          베이스 브랜치 (생략 시 기본 브랜치 감지)
  ${C_DIM}-l, --lock${C_RESET}        생성 즉시 잠금
  ${C_DIM}-d, --detach${C_RESET}      브랜치 없이 detached HEAD로 체크아웃
  ${C_DIM}-F, --fetch${C_RESET}       생성 전 origin fetch
  ${C_DIM}-n, --no-open${C_RESET}     claude 실행 생략 (경로 출력만)

${C_BOLD}Examples:${C_RESET}
  cw add test
  cw add BMSQUARE-16512 feature/BMSQUARE-16512 main -l
  cw add hotfix -d main
  cw add feature -Fn
  cw open BMSQUARE-16512
  cw path BMSQUARE-16512
  cw cursor BMSQUARE-16512
  cw name BMSQUARE-16512
  eval "\$(cw cd BMSQUARE-16512)"
  cw list --plain                  # 파이프/스크립트용 텍스트 목록
  cw list                          # TTY: ↑↓ 선택 + 액션 메뉴
  cw BMSQUARE-16512              # 이름만 입력 → 액션 메뉴

${C_BOLD}Env:${C_RESET}
  ${C_DIM}NO_COLOR=1${C_RESET}   색상 비활성화
  ${C_DIM}${INIT_HOOK}${C_RESET}
            존재 시 cw add 완료 후 실행 (인자: 워크트리 경로)
EOF
  exit 0
}

require_repo() {
  # linked worktree 안에서도 항상 메인 워크트리(repo root)를 기준으로 동작
  git rev-parse --git-dir >/dev/null 2>&1 || { err "git repo 아님"; exit 1; }
  REPO_ROOT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')"
  if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
    err "메인 워크트리 경로 감지 실패"
    exit 1
  fi
}

# path가 cw 관리 베이스 하위인지 (.claude/worktrees, .worktrees)
is_managed_worktree_path() {
  local path="$1" base
  for base in "${WORKTREE_BASES[@]}"; do
    case "$path" in
      "${REPO_ROOT}/${base}"/*) return 0 ;;
    esac
  done
  return 1
}

# 관리 베이스 기준 상대 이름 (예: BMSQUARE-15764, fix/ceoapp)
worktree_relative_name() {
  local path="$1" base fullbase
  for base in "${WORKTREE_BASES[@]}"; do
    fullbase="${REPO_ROOT}/${base}"
    case "$path" in
      "$fullbase"/*)
        printf '%s' "${path#"$fullbase"/}"
        return 0
        ;;
    esac
  done
  return 1
}

# clean/로그용 라벨: 관리 베이스 상대경로 > basename (orca 등 외부 경로)
worktree_label() {
  local path="$1" name
  name="$(worktree_relative_name "$path" 2>/dev/null || true)"
  if [ -n "$name" ]; then
    printf '%s' "$name"
  else
    basename "$path"
  fi
}

# RESOLVED_PATH / RESOLVED_BASE / RESOLVED_NAME 설정. 없으면 1.
# 1) 관리 베이스 경로 우선  2) git worktree list 전역 basename/상대이름 매칭
resolve_worktree_by_name() {
  local name="$1" base wpath wtpath rel label
  RESOLVED_PATH=""
  RESOLVED_BASE=""
  RESOLVED_NAME=""
  for base in "${WORKTREE_BASES[@]}"; do
    wpath="${REPO_ROOT}/${base}/${name}"
    if [ -d "$wpath" ]; then
      RESOLVED_PATH="$wpath"
      RESOLVED_BASE="$base"
      RESOLVED_NAME="$name"
      return 0
    fi
  done
  # orca/workspaces 등 관리 베이스 밖 linked worktree
  while IFS= read -r wtpath; do
    [ -n "$wtpath" ] || continue
    [ "$wtpath" = "$REPO_ROOT" ] && continue
    [ -d "$wtpath" ] || continue
    rel="$(worktree_relative_name "$wtpath" 2>/dev/null || true)"
    label="$(basename "$wtpath")"
    if [ "$rel" = "$name" ] || [ "$label" = "$name" ]; then
      RESOLVED_PATH="$wtpath"
      RESOLVED_BASE=""
      RESOLVED_NAME="$name"
      return 0
    fi
  done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2}')
  return 1
}

# git worktree list에서 정리/조회 가능한 이름 나열 (메인 제외)
list_managed_worktree_names() {
  local wtpath
  while IFS= read -r wtpath; do
    [ -n "$wtpath" ] || continue
    [ "$wtpath" = "$REPO_ROOT" ] && continue
    printf '%s\n' "$(worktree_label "$wtpath")"
  done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2}')
}

require_claude() {
  command -v claude >/dev/null 2>&1 || { err "claude CLI 미설치"; exit 1; }
}

require_worktree() {
  local name="$1"
  resolve_worktree_by_name "$name" && return 0
  err "워크트리 없음: ${name} ${C_DIM}(관리 베이스 + git worktree list)${C_RESET}"
  return 1
}

is_locked() {
  local wpath="$1"
  [ -f "$(git rev-parse --git-common-dir 2>/dev/null)/worktrees/$(basename "$wpath")/locked" ]
}

# 워크트리의 dirty(uncommitted) 변경 목록 출력. 깨끗하면 빈 문자열.
# .claude-worktree-keep 화이트리스트 파일은 무시 (cmd_remove와 동일 정책).
# stdout: dirty 라인들. 호출자는 [ -n "$(...)" ] 로 판단.
worktree_dirty() {
  local wpath="$1"
  git -C "$wpath" status --porcelain 2>/dev/null | grep -v '\.claude-worktree-keep$' || true
}

# branch의 모든 commit이 base에 patch-equivalent로 존재하면 0(effectively merged) 반환.
# git cherry 출력: '+ <sha>' = base에 없는 commit, '- <sha>' = patch-id 매치 commit.
# ancestor 케이스(branch가 base의 조상)도 빈 출력으로 동일 판정.
# 한계: squash merge로 다수 commit이 1개로 합쳐지면 patch-id가 달라져 못 잡음.
is_effectively_merged() {
  local branch="$1" base="$2"
  local unmerged
  unmerged="$(git cherry "$base" "$branch" 2>/dev/null | awk '/^\+/ {c++} END {print c+0}')"
  [ "${unmerged:-99}" -eq 0 ]
}

# 번들 단일 문자 옵션 확장: -Fn → -F -n
expand_short_opts() {
  local -a out=()
  for arg in "$@"; do
    if [[ "$arg" =~ ^-[a-zA-Z]{2,}$ ]]; then
      local i
      for (( i=1; i<${#arg}; i++ )); do
        out+=("-${arg:$i:1}")
      done
    else
      out+=("$arg")
    fi
  done
  printf '%s\n' "${out[@]}"
}

# 기본 브랜치 감지: origin/HEAD → main → master (폴백 체인)
repo_default_branch() {
  local br
  br="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  if [ -n "$br" ]; then echo "$br"; return; fi
  for cand in main master; do
    if git show-ref --verify --quiet "refs/heads/${cand}"; then echo "$cand"; return; fi
  done
}

# 머지 기준 브랜치: 메인 워크트리의 현재 브랜치 > repo_default_branch
# require_repo 이후 호출 전제 (REPO_ROOT 사용)
merge_base_branch() {
  local main_br
  if [ -n "${REPO_ROOT:-}" ] && [ -d "$REPO_ROOT" ]; then
    main_br="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
    if [ -n "$main_br" ]; then echo "$main_br"; return; fi
  fi
  repo_default_branch
}

cmd_add() {
  local -a positional=()
  local opt_lock=0 opt_detach=0 opt_fetch=0 opt_no_open=0

  local -a args=()
  while IFS= read -r a; do args+=("$a"); done < <(expand_short_opts "$@")
  set -- "${args[@]}"

  while [ $# -gt 0 ]; do
    case "$1" in
      -l|--lock)       opt_lock=1; shift ;;
      -d|--detach)     opt_detach=1; shift ;;
      -F|--fetch)      opt_fetch=1; shift ;;
      -n|--no-open)    opt_no_open=1; shift ;;
      --)              shift; break ;;
      -*)              err "알 수 없는 옵션: $1"; exit 1 ;;
      *)               positional+=("$1"); shift ;;
    esac
  done

  if [ ${#positional[@]} -lt 1 ]; then err "Usage: cw add <folder> [branch] [base] [옵션]"; exit 1; fi
  require_repo

  local name="${positional[0]}"
  local branch_arg="${positional[1]:-}"
  local base_arg="${positional[2]:-}"

  local default_br
  default_br="$(merge_base_branch)"
  if [ -z "$default_br" ]; then err "기본 브랜치 감지 실패 (main/master 없음)"; exit 1; fi

  local branch base
  branch="${branch_arg:-worktrees-${name}}"
  base="${base_arg:-$default_br}"

  local wpath="${REPO_ROOT}/${DEFAULT_WORKTREE_BASE}/${name}"

  if [ -d "$wpath" ]; then
    info "이미 존재: ${C_DIM}${wpath}${C_RESET}"
    if [ "$opt_no_open" -eq 1 ]; then
      echo "$wpath"
      exit 0
    fi
    require_claude
    info "기존 워크트리에서 claude 실행"
    cd "$wpath"
    exec claude --dangerously-skip-permissions
  fi

  [ "$opt_no_open" -eq 1 ] || require_claude

  if [ "$opt_fetch" -eq 1 ]; then
    info "origin fetch 중..."
    git fetch origin 2>/dev/null || warn "fetch 실패 (네트워크/원격 확인)"
  fi

  mkdir -p "${REPO_ROOT}/${DEFAULT_WORKTREE_BASE}"

  info "워크트리 생성: ${C_BOLD}${wpath}${C_RESET}"

  if [ "$opt_detach" -eq 1 ]; then
    echo "  ${C_DIM}모드:${C_RESET} ${C_YELLOW}detached HEAD${C_RESET}"
    echo "  ${C_DIM}베이스:${C_RESET} ${C_CYAN}${base}${C_RESET}"
    git worktree add --detach "$wpath" "$base" || { err "워크트리 생성 실패"; exit 1; }
  else
    echo "  ${C_DIM}브랜치:${C_RESET} ${C_CYAN}${branch}${C_RESET}"

    if git show-ref --verify --quiet "refs/heads/${branch}"; then
      echo "  ${C_DIM}(기존 브랜치 사용)${C_RESET}"
      if [ -n "$base_arg" ]; then
        warn "base=${C_CYAN}${base_arg}${C_RESET} 인자 무시됨 (기존 브랜치 사용)"
      fi
      git worktree add "$wpath" "$branch" || { err "워크트리 생성 실패"; exit 1; }
    else
      echo "  ${C_DIM}베이스:${C_RESET} ${C_CYAN}${base}${C_RESET}"
      git worktree add "$wpath" -b "$branch" "$base" || { err "워크트리 생성 실패"; exit 1; }
    fi
  fi

  git -C "$wpath" config core.hooksPath /dev/null 2>/dev/null || true

  if [ "$opt_lock" -eq 1 ]; then
    git worktree lock "$wpath" 2>/dev/null && ok "잠금 적용"
  fi

  if [ -x "$INIT_HOOK" ]; then
    info "init hook 실행: ${C_DIM}${INIT_HOOK}${C_RESET}"
    "$INIT_HOOK" "$wpath" || warn "init hook 실패 (계속 진행)"
  fi

  ok "생성 완료"

  if [ "$opt_no_open" -eq 1 ]; then
    echo "$wpath"
    exit 0
  fi

  cd "$wpath"
  exec claude --dangerously-skip-permissions
}

_tty_saved=""

tty_raw_on() {
  [ -t 0 ] || return 1
  _tty_saved="$(stty -g 2>/dev/null || true)"
  # min 1 time 0: 1바이트 올 때까지 블록 (bash 3.2 호환)
  stty -echo -icanon min 1 time 0 2>/dev/null || return 1
  # 커서 숨김 — 전체 clear 반복 시 깜빡임 완화
  printf '\033[?25l' > /dev/tty 2>/dev/null || true
}

tty_raw_off() {
  printf '\033[?25h' > /dev/tty 2>/dev/null || true
  [ -n "${_tty_saved:-}" ] && stty "$_tty_saved" 2>/dev/null || true
  _tty_saved=""
}

# 화면 갱신: clear(1) 대신 홈+이하 삭제 (깜빡임 적음). UI는 항상 /dev/tty.
ui_redraw_start() {
  printf '\033[H\033[J' > /dev/tty
}

ui_puts() {
  printf '%s\n' "$*" > /dev/tty
}

ui_printf() {
  # shellcheck disable=SC2059
  printf "$@" > /dev/tty
}

# 키 1회 읽기 → REPLY_KEY.
# - 방향키: ESC [ A / ESC O A (즉시 도착)
# - Enter: raw 모드 CR(\r) → \n 정규화
# - 단독 ESC: bash 3.2는 read -t 소수초 미지원 → 최대 1초 대기 후 확정
# macOS에서 stty min0+bash read 조합은 hang 나므로 쓰지 않음
read_key() {
  REPLY_KEY=""
  local k="" e1="" e2=""
  IFS= read -r -n1 k || return 1

  if [[ -z "$k" || "$k" == $'\n' || "$k" == $'\r' ]]; then
    REPLY_KEY=$'\n'
    return 0
  fi

  if [[ "$k" != $'\x1b' ]]; then
    REPLY_KEY="$k"
    return 0
  fi

  if IFS= read -r -n1 -t 1 e1; then
    if [[ "$e1" == '[' || "$e1" == 'O' ]]; then
      IFS= read -r -n1 -t 1 e2 || e2=""
      REPLY_KEY=$'\x1b'"${e1}${e2}"
      return 0
    fi
    # ESC+다른 키 (Alt 조합 등)
    REPLY_KEY=$'\x1b'"${e1}"
    return 0
  fi

  # 후속 바이트 없음 → 단독 ESC
  REPLY_KEY=$'\x1b'
  return 0
}

_tilde_path() {
  local p="$1" hl="${#HOME}"
  if [ "$hl" -gt 0 ] && [[ "$p" == "$HOME"* ]]; then
    printf '~%s' "${p:$hl}"
  else
    printf '%s' "$p"
  fi
}

copy_to_clipboard() {
  local text="$1"
  [ -z "${NO_CLIPBOARD:-}" ] || return 1
  local copier=""
  if command -v pbcopy >/dev/null 2>&1; then copier="pbcopy"
  elif command -v wl-copy >/dev/null 2>&1; then copier="wl-copy"
  elif command -v xclip >/dev/null 2>&1; then copier="xclip -selection clipboard"
  fi
  [ -n "$copier" ] || return 1
  printf '%s' "$text" | eval "$copier" 2>/dev/null
}

# 관리 베이스 상대 이름 > 현재 브랜치 > basename
worktree_display_name() {
  local wpath="$1" name
  name="$(worktree_relative_name "$wpath" 2>/dev/null || true)"
  if [ -z "$name" ]; then
    name="$(git -C "$wpath" branch --show-current 2>/dev/null || true)"
  fi
  if [ -z "$name" ]; then
    name="$(basename "$wpath")"
  fi
  printf '%s' "$name"
}

open_in_cursor() {
  local path="$1"
  if command -v cursor >/dev/null 2>&1; then
    cursor "$path" >/dev/null 2>&1 &
    ok "Cursor 열림: ${C_DIM}$(_tilde_path "$path")${C_RESET}"
    return 0
  fi
  if command -v open >/dev/null 2>&1 && [ -d "/Applications/Cursor.app" ]; then
    open -a Cursor "$path"
    ok "Cursor 열림: ${C_DIM}$(_tilde_path "$path")${C_RESET}"
    return 0
  fi
  err "Cursor CLI/app 없음"
  return 1
}

collect_worktree_rows() {
  _WT_PATHS=()
  _WT_BRANCHES=()
  _WT_SHAS=()
  _WT_LOCKED=()
  _WT_PRUNABLE=()
  _WT_BARE=()
  local path="" sha="" branch="" locked=0 prunable=0 bare=0
  _wt_flush() {
    [ -n "$path" ] || return 0
    _WT_PATHS+=("$path")
    _WT_BRANCHES+=("$branch")
    _WT_SHAS+=("$sha")
    _WT_LOCKED+=("$locked")
    _WT_PRUNABLE+=("$prunable")
    _WT_BARE+=("$bare")
    path=""; sha=""; branch=""; locked=0; prunable=0; bare=0
  }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) _wt_flush; path="${line#worktree }" ;;
      "HEAD "*)     sha="${line#HEAD }"; sha="${sha:0:10}" ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "detached"*)  branch="" ;;
      "bare"*)      bare=1 ;;
      "locked"*)    locked=1 ;;
      "prunable"*)  prunable=1 ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  _wt_flush
  unset -f _wt_flush
}

_print_worktree_row() {
  local idx="$1" selected="$2" main_path="$3"
  local path="${_WT_PATHS[$idx]}"
  local branch="${_WT_BRANCHES[$idx]:-}"
  local sha="${_WT_SHAS[$idx]:-}"
  local disp branch_out status=""
  disp="$(_tilde_path "$path")"

  if [ "$selected" -eq 1 ]; then ui_printf "  ${C_BOLD}${C_CYAN}> "
  else ui_printf "    "; fi

  if [ "$path" = "$main_path" ]; then
    ui_printf '%s%s%s' "$C_GREEN" "$disp" "$C_RESET"
  else
    ui_printf '%s%s%s' "$C_DIM" "$disp" "$C_RESET"
  fi
  ui_printf '  %s%s%s  ' "$C_DIM" "$sha" "$C_RESET"
  if [ -n "$branch" ]; then branch_out="${C_CYAN}[${branch}]${C_RESET}"
  else branch_out="${C_YELLOW}[detached]${C_RESET}"; fi
  [ "${_WT_LOCKED[$idx]:-0}" = "1" ] && status="${status} ${C_YELLOW}🔒 locked${C_RESET}"
  [ "${_WT_PRUNABLE[$idx]:-0}" = "1" ] && status="${status} ${C_RED}⚠ prunable${C_RESET}"
  [ "${_WT_BARE[$idx]:-0}" = "1" ] && status="${status} ${C_GRAY}(bare)${C_RESET}"
  ui_printf '%s%s\n' "$branch_out" "$status"
}

# 선택 결과를 REPLY_PICK에 저장. UI는 /dev/tty로만 출력 (커맨드 치환 오염 방지).
menu_pick() {
  local title="$1"
  shift
  local -a items=("$@")
  local n=${#items[@]} idx=0 i
  REPLY_PICK=""
  [ "$n" -gt 0 ] || return 1
  tty_raw_on || return 1
  while true; do
    ui_redraw_start
    ui_puts "${C_BOLD}${title}${C_RESET}"
    ui_puts ""
    for i in $(seq 0 $((n - 1))); do
      if [ "$i" -eq "$idx" ]; then
        ui_printf "  ${C_BOLD}${C_CYAN}> %s${C_RESET}\n" "${items[$i]}"
      else
        ui_printf "    %s\n" "${items[$i]}"
      fi
    done
    ui_puts ""
    ui_printf "${C_DIM}↑↓ 이동 · Enter 선택 · q 취소${C_RESET}\n"
    read_key || { tty_raw_off; return 1; }
    case "$REPLY_KEY" in
      $'\x1b[A'|$'\x1bOA'|k) idx=$(( (idx + n - 1) % n )) ;;
      $'\x1b[B'|$'\x1bOB'|j) idx=$(( (idx + 1) % n )) ;;
      $'\n') tty_raw_off; REPLY_PICK="$idx"; return 0 ;;
      q|Q|$'\x1b') tty_raw_off; return 1 ;;
    esac
  done
}

worktree_action_menu() {
  local wpath="$1"
  local rel_name="${2:-}"
  if [ -z "$rel_name" ] && is_managed_worktree_path "$wpath"; then
    rel_name="$(worktree_relative_name "$wpath" 2>/dev/null || true)"
  fi
  local -a actions=(
    "Cursor에서 열기"
    "Claude 실행"
    "경로 복사"
    "이름 복사"
    "cd 명령 출력"
    "취소"
  )
  local disp_name
  disp_name="$(worktree_display_name "$wpath")"
  # 절대 pick="$(menu_pick ...)" 쓰지 말 것 — UI stdout이 결과에 섞임
  menu_pick "무엇을 할까요? $(_tilde_path "$wpath")" "${actions[@]}" || return 0
  case "$REPLY_PICK" in
    0) open_in_cursor "$wpath" ;;
    1)
      require_claude
      cd "$wpath"
      exec claude --dangerously-skip-permissions
      ;;
    2)
      if copy_to_clipboard "$wpath"; then ok "클립보드(경로): $(_tilde_path "$wpath")"
      else echo "$wpath"; fi
      ;;
    3)
      if copy_to_clipboard "$disp_name"; then ok "클립보드(이름): ${disp_name}"
      else echo "$disp_name"; fi
      ;;
    4)
      printf 'cd %q\n' "$wpath"
      if [ -n "$rel_name" ]; then
        hint "현재 쉘: eval \"\$(cw cd '${rel_name}')\""
      fi
      ;;
    *) return 0 ;;
  esac
}

cmd_list_interactive() {
  local main_path="$REPO_ROOT"
  collect_worktree_rows
  local n=${#_WT_PATHS[@]}
  if [ "$n" -eq 0 ]; then warn "워크트리 없음"; return 0; fi

  local idx=0 i sel_path
  tty_raw_on || { cmd_list_plain; return; }
  while true; do
    ui_redraw_start
    ui_printf "${C_BOLD}워크트리 선택${C_RESET} ${C_DIM}(↑↓ · Enter · q)${C_RESET}\n"
    ui_puts ""
    for i in $(seq 0 $((n - 1))); do
      local sel=0; [ "$i" -eq "$idx" ] && sel=1
      _print_worktree_row "$i" "$sel" "$main_path"
    done
    ui_puts ""
    ui_printf "${C_DIM}Enter: 액션 메뉴 · q: 종료${C_RESET}\n"
    read_key || break
    case "$REPLY_KEY" in
      $'\x1b[A'|$'\x1bOA'|k) idx=$(( (idx + n - 1) % n )) ;;
      $'\x1b[B'|$'\x1bOB'|j) idx=$(( (idx + 1) % n )) ;;
      $'\n')
        sel_path="${_WT_PATHS[$idx]}"
        tty_raw_off
        echo ""
        worktree_action_menu "$sel_path"
        return
        ;;
      q|Q|$'\x1b') break ;;
    esac
  done
  tty_raw_off
}

cmd_list_plain() {
  local main_path
  main_path="$(git rev-parse --show-toplevel 2>/dev/null || true)"

  git worktree list --porcelain 2>/dev/null | awk -v main="$main_path" -v home="$HOME" \
    -v cB="$C_BOLD" -v cD="$C_DIM" -v cG="$C_GRAY" -v cC="$C_CYAN" \
    -v cY="$C_YELLOW" -v cR="$C_RED" -v cGr="$C_GREEN" -v cRs="$C_RESET" '
    function tilde(p,    hl) {
      hl = length(home)
      if (hl > 0 && substr(p, 1, hl) == home && (length(p) == hl || substr(p, hl+1, 1) == "/")) {
        return "~" substr(p, hl+1)
      }
      return p
    }
    function flush(   disp) {
      if (path == "") return
      disp = tilde(path)
      # 경로를 parent + basename 으로 분리, basename만 강조
      slash = 0
      for (i = length(disp); i > 0; i--) {
        if (substr(disp, i, 1) == "/") { slash = i; break }
      }
      if (slash > 0) {
        parent = substr(disp, 1, slash)
        base = substr(disp, slash + 1)
      } else {
        parent = ""; base = disp
      }

      if (path == main) {
        path_out = cGr cB disp cRs
      } else {
        path_out = cD parent cRs cC cB base cRs
      }

      branch_out = (branch != "") ? cC cB "[" branch "]" cRs : cY "[detached]" cRs
      status = ""
      if (locked)   status = status " " cY "🔒 locked" cRs
      if (prunable) status = status " " cR "⚠ prunable" cRs
      if (bare)     status = status " " cG "(bare)" cRs
      printf "%s  %s%s%s  %s%s\n", path_out, cD, sha, cRs, branch_out, status
      path=""; sha=""; branch=""; locked=0; prunable=0; bare=0
    }
    /^worktree / { flush(); path = substr($0, 10) }
    /^HEAD /     { sha = substr($0, 6, 10) }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
    /^detached/  { branch = "" }
    /^bare/      { bare = 1 }
    /^locked/    { locked = 1 }
    /^prunable/  { prunable = 1 }
    END { flush() }
  '

  local prunable_count
  prunable_count="$(git worktree list --porcelain 2>/dev/null | awk '/^prunable/ {n++} END {print n+0}')"
  if [ "${prunable_count:-0}" -gt 0 ]; then
    echo ""
    warn "prunable worktree ${C_BOLD}${prunable_count}${C_RESET}개 있음. ${C_CYAN}cw prune${C_RESET}으로 정리 가능."
  fi
}

cmd_list() {
  local opt_plain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --plain|-p) opt_plain=1; shift ;;
      *) err "Usage: cw list [--plain|-p]"; exit 1 ;;
    esac
  done
  if [ "$opt_plain" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    require_repo
    cmd_list_interactive
    return
  fi
  cmd_list_plain
}

_resolve_or_list() {
  local name="$1"

  if resolve_worktree_by_name "$name"; then
    return 0
  fi

  err "워크트리 없음: ${name} ${C_DIM}(관리 베이스 + git worktree list)${C_RESET}"
  local -a entries=()
  while IFS= read -r rel; do
    [ -n "$rel" ] && entries+=("$rel")
  done < <(list_managed_worktree_names | sort -u)
  if [ ${#entries[@]} -gt 0 ]; then
    info "사용 가능:"
    for e in "${entries[@]}"; do
      echo "  ${C_CYAN}·${C_RESET} ${e}"
    done
  else
    warn "생성된 워크트리 없음"
  fi
  return 1
}

# 단일 <name> 인자 명령 공통: Usage 검사 → resolve. 실패 시 exit.
require_named() {
  local cmd="$1"; shift
  [ $# -ge 1 ] || { err "Usage: cw ${cmd} <name>"; exit 1; }
  [ $# -eq 1 ] || { err "${cmd}는 옵션을 받지 않아"; exit 1; }
  require_repo
  _resolve_or_list "$1" || exit 1
}

cmd_cd() {
  require_named cd "$@"
  printf 'cd %q\n' "$RESOLVED_PATH"
}

cmd_cursor() {
  require_named cursor "$@"
  open_in_cursor "$RESOLVED_PATH"
}

cmd_name() {
  require_named name "$@"
  local disp
  disp="$(worktree_display_name "$RESOLVED_PATH")"
  echo "$disp"
  if [ -t 1 ] && copy_to_clipboard "$disp"; then
    echo "${C_GRAY}(클립보드에 복사됨)${C_RESET}" >&2
  fi
}

cmd_open() {
  if [ $# -gt 1 ]; then
    err "open은 옵션을 받지 않아. 경로만 필요하면 'cw path <name>' 사용"
    exit 1
  fi
  require_named open "$@"
  require_claude
  cd "$RESOLVED_PATH"
  exec claude --dangerously-skip-permissions
}

cmd_path() {
  require_named path "$@"
  echo "$RESOLVED_PATH"
  if [ -t 1 ] && copy_to_clipboard "$RESOLVED_PATH"; then
    echo "${C_GRAY}(클립보드에 복사됨)${C_RESET}" >&2
  fi
}

cmd_remove() {
  local opt_force=0
  local -a positional=()

  local -a args=()
  while IFS= read -r a; do args+=("$a"); done < <(expand_short_opts "$@")
  set -- "${args[@]}"

  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) opt_force=1; shift ;;
      -*)         err "알 수 없는 옵션: $1"; exit 1 ;;
      *)          positional+=("$1"); shift ;;
    esac
  done

  if [ ${#positional[@]} -lt 1 ]; then err "Usage: cw remove <name> [-f|--force]"; exit 1; fi
  require_repo

  local name="${positional[0]}"
  require_worktree "$name" || exit 1
  local wpath="$RESOLVED_PATH"

  local branch
  branch="$(git -C "$wpath" branch --show-current 2>/dev/null || true)"

  if is_locked "$wpath"; then
    warn "잠금 상태: ${C_BOLD}${name}${C_RESET} — 먼저 ${C_CYAN}cw unlock ${name}${C_RESET} 실행"
    exit 1
  fi

  # 더티 상태 확인
  local dirty
  dirty="$(worktree_dirty "$wpath")"
  if [ -n "$dirty" ] && [ "$opt_force" -eq 0 ]; then
    warn "변경사항 있음:"
    echo "$dirty" | head -10 | sed "s/^/  ${C_GRAY}·${C_RESET} /"
    echo ""
    hint "강제 삭제하려면: ${C_CYAN}cw remove ${name} -f${C_RESET}"
    exit 1
  fi

  # 머지 여부 선검증: 워크트리 제거 후 브랜치 삭제만 실패하는 반쪽 상태 방지
  if [ -n "$branch" ] && [ "$opt_force" -eq 0 ]; then
    local base_br
    base_br="$(merge_base_branch)"
    if [ -n "$base_br" ] && [ "$base_br" != "$branch" ] \
       && ! git branch --merged "$base_br" 2>/dev/null | grep -qw "$branch"; then
      warn "브랜치 ${C_CYAN}${branch}${C_RESET} 머지 안 됨 (${C_CYAN}${base_br}${C_RESET} 기준) — 워크트리 유지"
      hint "강제 삭제하려면: ${C_CYAN}cw remove ${name} -f${C_RESET}"
      exit 1
    fi
  fi

  # dirty 체크 통과 후에는 --force 필수:
  # - .claude-worktree-keep 같은 화이트리스트 파일이 남아있으면 git은 거부함
  # - 사용자 dirty 체크로 이미 안전성 판단됨
  git worktree remove "$wpath" --force || { err "제거 실패: ${name}"; exit 1; }
  # 디렉토리 잔존 대비 (turbo daemon 등 외부 프로세스가 파일 재생성하는 경우)
  [ -d "$wpath" ] && rm -rf "$wpath"

  if [ -n "$branch" ]; then
    if [ "$opt_force" -eq 1 ]; then
      git branch -D "$branch" 2>/dev/null || true
    else
      git branch -d "$branch" 2>/dev/null || warn "브랜치 ${C_CYAN}${branch}${C_RESET} 삭제 실패. ${C_CYAN}git branch -D ${branch}${C_RESET}로 강제 삭제 가능"
    fi
  fi

  git worktree prune 2>/dev/null
  ok "정리 완료: ${C_BOLD}${name}${C_RESET}"
}

cmd_clean() {
  require_repo

  local default_br base wbase
  default_br="${1:-$(merge_base_branch)}"
  if [ -z "$default_br" ]; then err "기준 브랜치 감지 실패 (명시: cw clean <base>)"; exit 1; fi

  info "기준 브랜치: ${C_CYAN}${default_br}${C_RESET}"
  echo ""

  local is_tty=0
  [ -t 1 ] && is_tty=1

  # 등록된 linked worktree 전부 (메인·bare 제외) — orca/workspaces 등 외부 경로 포함
  # (워크트리별 git -C 호출이 부모 워크트리로 walk up 하는 사고 방지)
  collect_worktree_rows
  local -a registered=() reg_branches=() reg_prunable=()
  local i n_all=${#_WT_PATHS[@]}
  for (( i=0; i<n_all; i++ )); do
    [ "${_WT_BARE[$i]:-0}" = "1" ] && continue
    [ "${_WT_PATHS[$i]}" = "$REPO_ROOT" ] && continue
    registered+=("${_WT_PATHS[$i]}")
    reg_branches+=("${_WT_BRANCHES[$i]}")
    reg_prunable+=("${_WT_PRUNABLE[$i]}")
  done

  # stray = 관리 베이스 직속 디렉토리만 (외부 orca 경로는 git 등록분만 처리)
  local -a strays=()
  for base in "${WORKTREE_BASES[@]}"; do
    wbase="${REPO_ROOT}/${base}"
    [ -d "$wbase" ] || continue
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      [ -d "$dir" ] || continue
      local is_parent_or_self=0 r
      for r in "${registered[@]+"${registered[@]}"}"; do
        if [ "$r" = "$dir" ] || [[ "$r" == "$dir"/* ]]; then
          is_parent_or_self=1
          break
        fi
      done
      [ "$is_parent_or_self" -eq 0 ] && strays+=("$dir")
    done < <(find "$wbase" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  done

  local total=$((${#registered[@]} + ${#strays[@]}))
  if [ "$total" -eq 0 ]; then
    warn "정리할 워크트리 없음"
    exit 0
  fi

  # NOTE: merged_list 사전 조회는 v0.1.10에서 제거.
  # `git branch --merged`는 reachability(SHA 기반)만 봐서 rebase 후 patch-equivalent
  # 케이스를 false-negative 처리함. 대신 워크트리별로 `git cherry`(patch-id 기반)를
  # is_effectively_merged()로 호출해 ancestor + rebase 둘 다 잡는다.

  local cleaned=0 skipped=0
  local -a kept_unmerged=()
  local idx=0

  # 1) stray 디렉토리 (관리 베이스, git 등록 없음) — 단순 rm
  for wtpath in "${strays[@]+"${strays[@]}"}"; do
    idx=$((idx + 1))
    local name prefix
    name="$(worktree_label "$wtpath")"
    prefix="${C_DIM}[${idx}/${total}]${C_RESET}"
    spinner_start "[${idx}/${total}] 정리 중: ${name} (stray)"
    rm -rf "$wtpath"
    spinner_stop
    ok "${prefix} 정리: ${C_BOLD}${name}${C_RESET} ${C_DIM}(stray 디렉토리 — git 등록 없음)${C_RESET}"
    cleaned=$((cleaned + 1))
  done

  # 2) 등록된 워크트리 처리 (관리 베이스 + 외부 경로)
  local i_reg=-1
  for wtpath in "${registered[@]+"${registered[@]}"}"; do
    i_reg=$((i_reg + 1))
    idx=$((idx + 1))
    local name branch prunable prefix
    name="$(worktree_label "$wtpath")"
    branch="${reg_branches[$i_reg]}"
    prunable="${reg_prunable[$i_reg]}"
    prefix="${C_DIM}[${idx}/${total}]${C_RESET}"

    # 진행 표시: TTY일 때만 덮어쓰기 가능한 "확인 중" 라인
    if [ "$is_tty" -eq 1 ]; then
      printf '\r\033[K%s[%d/%d] 확인 중: %s...%s' "$C_DIM" "$idx" "$total" "$name" "$C_RESET"
    fi

    # prunable: git 내부 메타데이터는 살아있지만 워크트리 .git 파일이 사라진 상태
    # → 디렉토리 정리하고 git worktree prune이 메타데이터 정리하게 둠
    if [ "$prunable" = "1" ]; then
      spinner_start "[${idx}/${total}] 정리 중: ${name} (prunable)"
      [ -d "$wtpath" ] && rm -rf "$wtpath"
      spinner_stop
      ok "${prefix} 정리: ${C_BOLD}${name}${C_RESET} ${C_DIM}(prunable — git 등록 메타데이터만 잔존)${C_RESET}"
      cleaned=$((cleaned + 1))
      continue
    fi

    if is_locked "$wtpath"; then
      [ "$is_tty" -eq 1 ] && printf '\r\033[K'
      skip "${prefix} 유지: ${name} ${branch:+(${branch}) }— 잠금됨"
      skipped=$((skipped + 1))
      continue
    fi

    # detached HEAD: HEAD 커밋이 기준 브랜치에 포함됐는지 SHA로 확인
    if [ -z "$branch" ]; then
      local head_sha
      head_sha="$(git -C "$wtpath" rev-parse HEAD 2>/dev/null || true)"
      [ "$is_tty" -eq 1 ] && printf '\r\033[K'
      if [ -z "$head_sha" ]; then
        skip "${prefix} 유지: ${name} — HEAD 해석 실패"
        skipped=$((skipped + 1))
        continue
      fi
      if git merge-base --is-ancestor "$head_sha" "$default_br" 2>/dev/null; then
        # 보호: dirty(uncommitted) 변경 있으면 자동 삭제 금지
        local dirty
        dirty="$(worktree_dirty "$wtpath")"
        if [ -n "$dirty" ]; then
          [ "$is_tty" -eq 1 ] && printf '\r\033[K'
          skip "${prefix} 유지: ${name} (detached) — 변경사항 있음 (cw remove ${name} -f 로 강제)"
          kept_unmerged+=("${name}|detached")
          skipped=$((skipped + 1))
          continue
        fi
        spinner_start "[${idx}/${total}] 정리 중: ${name} (detached, 워크트리 삭제)"
        local _rc=0
        git worktree remove "$wtpath" --force 2>/dev/null || _rc=$?
        if [ "$_rc" -eq 0 ]; then
          [ -d "$wtpath" ] && rm -rf "$wtpath"
          spinner_stop
          ok "${prefix} 정리: ${C_BOLD}${name}${C_RESET} (${C_DIM}detached ${head_sha:0:10}${C_RESET}) — ${default_br}에 포함됨"
          cleaned=$((cleaned + 1))
        else
          spinner_stop
          err "${prefix} 유지: ${name} (detached) — 제거 실패"
          skipped=$((skipped + 1))
        fi
      else
        skip "${prefix} 유지: ${name} — detached HEAD (${head_sha:0:10}) 미포함"
        skipped=$((skipped + 1))
      fi
      continue
    fi

    # patch-id 기반 머지 판정 (ancestor + rebase/cherry-pick 커버, squash 다→1은 한계).
    # 삭제 전 가드:
    #   (1) dirty 없음
    #   (2) tip ≠ 기준 tip → patch-merged/옛 tip 흡수 → 삭제 (reflog 무시: 빈 reflog false-negative 방지)
    #   (3) tip == 기준 tip → 미작업 vs 방금 ff-merge. reflog>1 이면 삭제, ≤1·빈 reflog면 유지
    if is_effectively_merged "$branch" "$default_br"; then
      # 보호 1: dirty 워크트리 (작업 중)는 절대 자동 삭제 금지
      local dirty
      dirty="$(worktree_dirty "$wtpath")"
      if [ -n "$dirty" ]; then
        [ "$is_tty" -eq 1 ] && printf '\r\033[K'
        skip "${prefix} 유지: ${name} (${branch}) — 변경사항 있음 (cw remove ${name} -f 로 강제)"
        kept_unmerged+=("${name}|${branch}")
        skipped=$((skipped + 1))
        continue
      fi
      local br_sha base_sha
      br_sha="$(git rev-parse "$branch" 2>/dev/null || true)"
      base_sha="$(git rev-parse "$default_br" 2>/dev/null || true)"
      if [ -n "$br_sha" ] && [ -n "$base_sha" ] && [ "$br_sha" = "$base_sha" ]; then
        local refcount
        refcount="$(git reflog show "$branch" 2>/dev/null | wc -l | tr -d ' ')"
        if [ "${refcount:-0}" -le 1 ]; then
          [ "$is_tty" -eq 1 ] && printf '\r\033[K'
          skip "${prefix} 유지: ${name} (${branch}) — 기준 브랜치 tip과 동일 (미작업)"
          skipped=$((skipped + 1))
          continue
        fi
      fi
      spinner_start "[${idx}/${total}] 정리 중: ${name} (${branch}, 워크트리 삭제)"
      local _rc=0
      git worktree remove "$wtpath" --force 2>/dev/null || _rc=$?
      if [ "$_rc" -eq 0 ]; then
        [ -d "$wtpath" ] && rm -rf "$wtpath"
        git branch -D "$branch" 2>/dev/null || true
        spinner_stop
        ok "${prefix} 정리: ${C_BOLD}${name}${C_RESET} (${C_DIM}${branch}${C_RESET}) — ${default_br}에 머지됨"
        cleaned=$((cleaned + 1))
      else
        spinner_stop
        err "${prefix} 유지: ${name} (${branch}) — 제거 실패"
        skipped=$((skipped + 1))
      fi
    else
      [ "$is_tty" -eq 1 ] && printf '\r\033[K'
      skipped=$((skipped + 1))
      kept_unmerged+=("${name}|${branch}")
      skip "${prefix} 유지: ${name} (${branch}) — 머지 안 됨"
    fi
  done

  # 진행 라인 잔여 정리
  [ "$is_tty" -eq 1 ] && printf '\r\033[K'

  # 중첩 워크트리(fix/ceoapp) 제거 후 비게 된 부모 디렉토리(fix/) 정리
  for base in "${WORKTREE_BASES[@]}"; do
    wbase="${REPO_ROOT}/${base}"
    [ -d "$wbase" ] || continue
    find "$wbase" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
  done

  git worktree prune 2>/dev/null
  echo ""
  echo "${C_GREEN}${cleaned}개 정리${C_RESET}, ${C_GRAY}${skipped}개 유지${C_RESET}"

  if [ ${#kept_unmerged[@]} -gt 0 ]; then
    echo ""
    hint "머지 안 된 워크트리를 직접 삭제하려면:"
    for item in "${kept_unmerged[@]}"; do
      local n="${item%%|*}"
      echo "   ${C_CYAN}cw remove ${n} -f${C_RESET}  ${C_DIM}(워크트리 + 브랜치 모두 강제 삭제)${C_RESET}"
    done
  fi
}

cmd_lock() {
  if [ $# -lt 1 ]; then err "Usage: cw lock <name> [reason]"; exit 1; fi
  require_repo

  local name="$1"
  local reason="${2:-}"
  require_worktree "$name" || exit 1

  if [ -n "$reason" ]; then
    git worktree lock "$RESOLVED_PATH" --reason "$reason" && ok "잠금: ${C_BOLD}${name}${C_RESET} — ${C_DIM}${reason}${C_RESET}"
  else
    git worktree lock "$RESOLVED_PATH" && ok "잠금: ${C_BOLD}${name}${C_RESET}"
  fi
}

cmd_unlock() {
  if [ $# -lt 1 ]; then err "Usage: cw unlock <name>"; exit 1; fi
  require_repo

  local name="$1"
  require_worktree "$name" || exit 1
  git worktree unlock "$RESOLVED_PATH" && ok "잠금 해제: ${C_BOLD}${name}${C_RESET}"
}

cmd_move() {
  if [ $# -lt 2 ]; then err "Usage: cw move <name> <new-name>"; exit 1; fi
  require_repo

  local name="$1" newname="$2"
  require_worktree "$name" || exit 1
  if [ -z "$RESOLVED_BASE" ] || ! is_managed_worktree_path "$RESOLVED_PATH"; then
    err "관리 베이스(${WORKTREE_BASES[*]}) 밖 워크트리는 move 불가"
    exit 1
  fi
  local newpath="${REPO_ROOT}/${RESOLVED_BASE}/${newname}"

  if [ -e "$newpath" ]; then err "대상 경로 이미 존재: ${newpath}"; exit 1; fi

  git worktree move "$RESOLVED_PATH" "$newpath" && ok "이동: ${C_BOLD}${name}${C_RESET} → ${C_BOLD}${newname}${C_RESET}"
}

cmd_prune() {
  require_repo

  local default_br
  default_br="${1:-$(merge_base_branch)}"

  local -a prunable_branches=()
  while IFS= read -r line; do
    prunable_branches+=("$line")
  done < <(git worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { path = $2; branch = "" }
    /^branch / { branch = $2; sub(/^refs\/heads\//, "", branch) }
    /^prunable/ { if (branch) print branch; branch = "" }
    /^$/ { branch = "" }
  ')

  git worktree prune --verbose

  if [ ${#prunable_branches[@]} -eq 0 ]; then
    ok "prune 완료"
    return
  fi

  if [ -z "$default_br" ]; then
    warn "기본 브랜치 감지 실패 — 브랜치 정리 스킵"
    return
  fi

  local deleted=0 kept=0
  local -a kept_branches=()
  for br in "${prunable_branches[@]}"; do
    [ -z "$br" ] && continue
    git show-ref --verify --quiet "refs/heads/${br}" || continue

    if git branch --merged "$default_br" 2>/dev/null | grep -qw "$br"; then
      git branch -D "$br" 2>/dev/null && {
        ok "브랜치 삭제: ${C_BOLD}${br}${C_RESET} — ${default_br}에 머지됨"
        deleted=$((deleted + 1))
      }
    else
      skip "브랜치 유지: ${br} — 머지 안 됨"
      kept_branches+=("$br")
      kept=$((kept + 1))
    fi
  done

  echo ""
  echo "prune 완료 — ${C_GREEN}브랜치 ${deleted}개 삭제${C_RESET}, ${C_GRAY}${kept}개 유지${C_RESET}"

  if [ ${#kept_branches[@]} -gt 0 ]; then
    echo ""
    hint "머지 안 된 브랜치를 직접 삭제하려면:"
    for br in "${kept_branches[@]}"; do
      echo "   ${C_CYAN}git branch -D ${br}${C_RESET}"
    done
  fi
}

cmd_repair() {
  require_repo
  git worktree repair
  ok "repair 완료"
}

case "${1:-help}" in
  add)    shift; cmd_add "$@" ;;
  list)   shift; cmd_list "$@" ;;
  open)   shift; cmd_open "$@" ;;
  path)   shift; cmd_path "$@" ;;
  cd)     shift; cmd_cd "$@" ;;
  cursor) shift; cmd_cursor "$@" ;;
  name)   shift; cmd_name "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  clean)  shift; cmd_clean "$@" ;;
  lock)   shift; cmd_lock "$@" ;;
  unlock) shift; cmd_unlock "$@" ;;
  move)   shift; cmd_move "$@" ;;
  prune)  shift; cmd_prune "$@" ;;
  repair) cmd_repair ;;
  --version|-v) echo "cw ${CW_VERSION}" ;;
  help|--help|-h) help ;;
  *)
    if [[ "${1:-}" != -* ]] && [ -n "${1:-}" ]; then
      require_repo
      if resolve_worktree_by_name "$1"; then
        worktree_action_menu "$RESOLVED_PATH" "$1"
        exit 0
      fi
    fi
    err "알 수 없는 명령: $1"
    help
    ;;
esac
