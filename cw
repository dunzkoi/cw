#!/bin/bash
# cw — Claude Worktree: 서브커맨드 기반 claude worktree 관리

set -euo pipefail
IFS=$'\n\t'

WORKTREE_BASE=".claude/worktrees"
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

help() {
  cat <<EOF
${C_BOLD}cw — Claude Worktree${C_RESET}

${C_BOLD}Commands:${C_RESET}
  ${C_CYAN}add${C_RESET} <folder> [branch] [base] [옵션]
                                  워크트리 생성 후 claude 실행
  ${C_CYAN}open${C_RESET} <name>                    기존 워크트리에서 claude 실행
  ${C_CYAN}path${C_RESET} <name>                    워크트리 경로 출력 (claude 실행 X)
  ${C_CYAN}list${C_RESET}                            워크트리 목록
  ${C_CYAN}remove${C_RESET} <name> [-f|--force]     특정 워크트리 삭제 (브랜치 포함)
  ${C_CYAN}clean${C_RESET} [base]                    머지된 워크트리 일괄 정리 (기본: 메인 워크트리의 현재 브랜치)
  ${C_CYAN}lock${C_RESET} <name> [reason]           워크트리 잠금 (삭제 방지)
  ${C_CYAN}unlock${C_RESET} <name>                   워크트리 잠금 해제
  ${C_CYAN}move${C_RESET} <name> <new-name>          워크트리 이름 변경
  ${C_CYAN}prune${C_RESET} [base]                    stale 참조 정리 (기본: 메인 워크트리의 현재 브랜치)
  ${C_CYAN}repair${C_RESET}                          워크트리 링크 복구 (레포 이동 후)
  ${C_CYAN}help${C_RESET}                            이 도움말

${C_BOLD}Arguments (add):${C_RESET}
  ${C_DIM}folder${C_RESET}        워크트리 폴더명 (.claude/worktrees/<folder>)
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
  cw remove BMSQUARE-16512 -f
  cw repair
  cw list | cw clean | cw prune

${C_BOLD}Env:${C_RESET}
  ${C_DIM}NO_COLOR=1${C_RESET}   색상 비활성화
  ${C_DIM}${INIT_HOOK}${C_RESET}
            존재 시 cw add 완료 후 실행 (인자: 워크트리 경로)
EOF
  exit 0
}

require_repo() {
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { err "git repo 아님"; exit 1; }
}

require_claude() {
  command -v claude >/dev/null 2>&1 || { err "claude CLI 미설치"; exit 1; }
}

require_worktree() {
  local name="$1"
  local wpath="${REPO_ROOT}/${WORKTREE_BASE}/${name}"
  if [ ! -d "$wpath" ]; then
    err "워크트리 없음: ${wpath}"
    return 1
  fi
  WPATH="$wpath"
}

is_locked() {
  local wpath="$1"
  [ -f "$(git rev-parse --git-common-dir 2>/dev/null)/worktrees/$(basename "$wpath")/locked" ]
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
merge_base_branch() {
  local main_wt_path main_br
  main_wt_path="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')"
  if [ -n "$main_wt_path" ] && [ -d "$main_wt_path" ]; then
    main_br="$(git -C "$main_wt_path" branch --show-current 2>/dev/null || true)"
    if [ -n "$main_br" ]; then echo "$main_br"; return; fi
  fi
  repo_default_branch
}

# 안전한 디렉토리 목록 (공백/특수문자 OK)
list_worktree_dirs() {
  local wbase="$1"
  [ -d "$wbase" ] || return
  find "$wbase" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
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

  local wpath="${REPO_ROOT}/${WORKTREE_BASE}/${name}"

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

  mkdir -p "${REPO_ROOT}/${WORKTREE_BASE}"

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

cmd_list() {
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

_resolve_or_list() {
  local name="$1"
  local wpath="${REPO_ROOT}/${WORKTREE_BASE}/${name}"

  if [ -d "$wpath" ]; then
    RESOLVED_PATH="$wpath"
    return 0
  fi

  err "워크트리 없음: ${wpath}"
  local wbase="${REPO_ROOT}/${WORKTREE_BASE}"
  local -a entries=()
  if [ -d "$wbase" ]; then
    while IFS= read -r d; do
      entries+=("$(basename "$d")")
    done < <(find "$wbase" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
  fi
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

cmd_open() {
  if [ $# -lt 1 ]; then err "Usage: cw open <name>"; exit 1; fi
  if [ $# -gt 1 ]; then err "open은 옵션을 받지 않아. 경로만 필요하면 'cw path <name>' 사용"; exit 1; fi
  require_repo
  _resolve_or_list "$1" || exit 1
  require_claude
  cd "$RESOLVED_PATH"
  exec claude --dangerously-skip-permissions
}

cmd_path() {
  if [ $# -lt 1 ]; then err "Usage: cw path <name>"; exit 1; fi
  if [ $# -gt 1 ]; then err "path는 옵션을 받지 않아"; exit 1; fi
  require_repo
  _resolve_or_list "$1" || exit 1
  echo "$RESOLVED_PATH"

  # 클립보드 복사 (TTY일 때만, 파이프/리다이렉트 시 스킵)
  if [ -t 1 ] && [ -z "${NO_CLIPBOARD:-}" ]; then
    local copier=""
    if command -v pbcopy >/dev/null 2>&1; then copier="pbcopy"
    elif command -v wl-copy >/dev/null 2>&1; then copier="wl-copy"
    elif command -v xclip >/dev/null 2>&1; then copier="xclip -selection clipboard"
    fi
    if [ -n "$copier" ]; then
      printf '%s' "$RESOLVED_PATH" | eval "$copier" 2>/dev/null && \
        echo "${C_GRAY}(클립보드에 복사됨)${C_RESET}" >&2
    fi
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
  local wpath="$WPATH"

  local branch
  branch="$(git -C "$wpath" branch --show-current 2>/dev/null || true)"

  if is_locked "$wpath"; then
    warn "잠금 상태: ${C_BOLD}${name}${C_RESET} — 먼저 ${C_CYAN}cw unlock ${name}${C_RESET} 실행"
    exit 1
  fi

  # 더티 상태 확인
  local dirty
  dirty="$(git -C "$wpath" status --porcelain 2>/dev/null | grep -v '\.claude-worktree-keep$' || true)"
  if [ -n "$dirty" ] && [ "$opt_force" -eq 0 ]; then
    warn "변경사항 있음:"
    echo "$dirty" | head -10 | sed "s/^/  ${C_GRAY}·${C_RESET} /"
    echo ""
    hint "강제 삭제하려면: ${C_CYAN}cw remove ${name} -f${C_RESET}"
    exit 1
  fi

  # dirty 체크 통과 후에는 --force 필수:
  # - .claude-worktree-keep 같은 화이트리스트 파일이 남아있으면 git은 거부함
  # - 사용자 dirty 체크로 이미 안전성 판단됨
  git worktree remove "$wpath" --force || { err "제거 실패: ${name}"; exit 1; }

  if [ -n "$branch" ]; then
    if [ "$opt_force" -eq 1 ]; then
      git branch -D "$branch" 2>/dev/null || true
    else
      git branch -d "$branch" 2>/dev/null || warn "브랜치 ${C_CYAN}${branch}${C_RESET} 삭제 실패 (머지 안 됨). ${C_CYAN}git branch -D ${branch}${C_RESET}로 강제 삭제 가능"
    fi
  fi

  git worktree prune 2>/dev/null
  ok "정리 완료: ${C_BOLD}${name}${C_RESET}"
}

cmd_clean() {
  require_repo

  local wbase="${REPO_ROOT}/${WORKTREE_BASE}"
  if [ ! -d "$wbase" ]; then warn "워크트리 없음"; exit 0; fi

  local default_br
  default_br="${1:-$(merge_base_branch)}"
  if [ -z "$default_br" ]; then err "기준 브랜치 감지 실패 (명시: cw clean <base>)"; exit 1; fi

  info "기준 브랜치: ${C_CYAN}${default_br}${C_RESET}"
  echo ""

  local cleaned=0 skipped=0
  local -a kept_unmerged=()

  while IFS= read -r wtpath; do
    [ -n "$wtpath" ] || continue
    [ -d "$wtpath" ] || continue
    local name branch
    name="$(basename "$wtpath")"
    branch="$(git -C "$wtpath" branch --show-current 2>/dev/null || true)"

    if is_locked "$wtpath"; then
      skip "유지: ${name} ${branch:+(${branch}) }— 잠금됨"
      skipped=$((skipped + 1))
      continue
    fi

    # detached HEAD: HEAD 커밋이 기준 브랜치에 포함됐는지 SHA로 확인
    if [ -z "$branch" ]; then
      local head_sha
      head_sha="$(git -C "$wtpath" rev-parse HEAD 2>/dev/null || true)"
      if [ -z "$head_sha" ]; then
        skip "유지: ${name} — HEAD 해석 실패"
        skipped=$((skipped + 1))
        continue
      fi
      if git merge-base --is-ancestor "$head_sha" "$default_br" 2>/dev/null; then
        if git worktree remove "$wtpath" --force 2>/dev/null; then
          ok "정리: ${C_BOLD}${name}${C_RESET} (${C_DIM}detached ${head_sha:0:10}${C_RESET}) — ${default_br}에 포함됨"
          cleaned=$((cleaned + 1))
        else
          err "유지: ${name} (detached) — 제거 실패"
          skipped=$((skipped + 1))
        fi
      else
        skip "유지: ${name} — detached HEAD (${head_sha:0:10}) 미포함"
        skipped=$((skipped + 1))
      fi
      continue
    fi

    if git branch --merged "$default_br" 2>/dev/null | grep -qw "$branch"; then
      if git worktree remove "$wtpath" --force 2>/dev/null; then
        git branch -D "$branch" 2>/dev/null || true
        ok "정리: ${C_BOLD}${name}${C_RESET} (${C_DIM}${branch}${C_RESET}) — ${default_br}에 머지됨"
        cleaned=$((cleaned + 1))
      else
        err "유지: ${name} (${branch}) — 제거 실패"
        skipped=$((skipped + 1))
      fi
    else
      skipped=$((skipped + 1))
      kept_unmerged+=("${name}|${branch}")
      skip "유지: ${name} (${branch}) — 머지 안 됨"
    fi
  done < <(list_worktree_dirs "$wbase")

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
  local wpath="$WPATH"

  if [ -n "$reason" ]; then
    git worktree lock "$wpath" --reason "$reason" && ok "잠금: ${C_BOLD}${name}${C_RESET} — ${C_DIM}${reason}${C_RESET}"
  else
    git worktree lock "$wpath" && ok "잠금: ${C_BOLD}${name}${C_RESET}"
  fi
}

cmd_unlock() {
  if [ $# -lt 1 ]; then err "Usage: cw unlock <name>"; exit 1; fi
  require_repo

  local name="$1"
  require_worktree "$name" || exit 1
  git worktree unlock "$WPATH" && ok "잠금 해제: ${C_BOLD}${name}${C_RESET}"
}

cmd_move() {
  if [ $# -lt 2 ]; then err "Usage: cw move <name> <new-name>"; exit 1; fi
  require_repo

  local name="$1" newname="$2"
  require_worktree "$name" || exit 1
  local wpath="$WPATH"
  local newpath="${REPO_ROOT}/${WORKTREE_BASE}/${newname}"

  if [ -e "$newpath" ]; then err "대상 경로 이미 존재: ${newpath}"; exit 1; fi

  git worktree move "$wpath" "$newpath" && ok "이동: ${C_BOLD}${name}${C_RESET} → ${C_BOLD}${newname}${C_RESET}"
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
  list)   cmd_list ;;
  open)   shift; cmd_open "$@" ;;
  path)   shift; cmd_path "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  clean)  shift; cmd_clean "$@" ;;
  lock)   shift; cmd_lock "$@" ;;
  unlock) shift; cmd_unlock "$@" ;;
  move)   shift; cmd_move "$@" ;;
  prune)  shift; cmd_prune "$@" ;;
  repair) cmd_repair ;;
  help|--help|-h) help ;;
  *)      err "알 수 없는 명령: $1"; help ;;
esac
