#!/bin/bash
# cw installer — downloads latest cw script into a bin directory on PATH
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dunzkoi/cw/main/install.sh | bash
#
# Env:
#   CW_INSTALL_DIR   install destination (default: $HOME/.local/bin)
#   CW_VERSION       tag/branch to install (default: main)

set -euo pipefail

REPO="dunzkoi/cw"
VERSION="${CW_VERSION:-main}"
INSTALL_DIR="${CW_INSTALL_DIR:-$HOME/.local/bin}"
URL="https://raw.githubusercontent.com/${REPO}/${VERSION}/cw"

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info() { echo "${C_CYAN}●${C_RESET} $*"; }
ok()   { echo "${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "${C_YELLOW}⚠${C_RESET} $*"; }

command -v git >/dev/null 2>&1 || { echo "git이 필요해 (설치 후 다시 실행)"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl이 필요해"; exit 1; }

mkdir -p "$INSTALL_DIR"
TARGET="$INSTALL_DIR/cw"

info "다운로드: ${C_BOLD}${URL}${C_RESET}"
if ! curl -fsSL "$URL" -o "$TARGET.tmp"; then
  echo "다운로드 실패: $URL"
  rm -f "$TARGET.tmp"
  exit 1
fi

chmod +x "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"
ok "설치 완료: ${C_BOLD}${TARGET}${C_RESET}"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ok "PATH에 이미 포함됨" ;;
  *)
    warn "${INSTALL_DIR}가 PATH에 없어. 아래를 쉘 rc 파일에 추가해:"
    echo ""
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
    ;;
esac

"$TARGET" help >/dev/null 2>&1 && ok "동작 확인됨 — ${C_CYAN}cw help${C_RESET}로 시작"
