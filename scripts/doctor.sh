#!/usr/bin/env bash
set -euo pipefail

# doctor.sh - Check (and optionally install) autorun dependencies
#
# Usage: doctor.sh [--install]
#
# Checks: tmux, python3, git, claude CLI
# With --install: attempts to install missing dependencies via brew/apt

INSTALL="${1:-}"
MISSING=()
OK=()

check() {
  local name="$1" cmd="${2:-$1}"
  if command -v "$cmd" &>/dev/null; then
    local ver
    ver=$("$cmd" --version 2>&1 | head -1)
    OK+=("$name ($ver)")
  else
    MISSING+=("$name")
  fi
}

check tmux
check python3
check git
check "claude CLI" claude

echo "=== Autorun Dependency Check ==="
echo ""

for item in "${OK[@]+"${OK[@]}"}"; do
  echo "  [ok] $item"
done

for item in "${MISSING[@]+"${MISSING[@]}"}"; do
  echo "  [missing] $item"
done

echo ""

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "All dependencies satisfied."
  exit 0
fi

if [[ "$INSTALL" != "--install" ]]; then
  echo "Run with --install to attempt automatic installation."
  exit 1
fi

# Detect package manager
if command -v brew &>/dev/null; then
  PKG_MGR="brew"
  PKG_INSTALL="brew install"
elif command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
  PKG_INSTALL="sudo apt-get install -y"
else
  echo "No supported package manager found (brew or apt-get)."
  echo "Please install manually: ${MISSING[*]}"
  exit 1
fi

echo "Using $PKG_MGR to install: ${MISSING[*]}"
echo ""

for dep in "${MISSING[@]}"; do
  case "$dep" in
    tmux)
      echo "Installing tmux..."
      $PKG_INSTALL tmux
      ;;
    python3)
      echo "Installing python3..."
      $PKG_INSTALL python3
      ;;
    git)
      echo "Installing git..."
      $PKG_INSTALL git
      ;;
    "claude CLI")
      echo "Claude CLI must be installed manually:"
      echo "  npm install -g @anthropic-ai/claude-code"
      ;;
  esac
done

echo ""
echo "Done. Re-run without --install to verify."
