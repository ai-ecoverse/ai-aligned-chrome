#!/bin/bash
#
# install.sh - install ai-aligned-chrome, wrap the test browsers already on
# disk, and start the LaunchAgent that wraps new downloads.
#
# Supports both local installation and curl | sh:
#   curl -fsSL https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-chrome/main/install.sh | sh

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
RAW_BASE_URL="https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-chrome/main"
SOURCE_SCRIPT="executable_ai-aligned-chrome"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
SOURCE="$SCRIPT_DIR/$SOURCE_SCRIPT"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "ai-aligned-chrome is macOS-only (found $(uname -s)); Linux has no keychain prompt to avoid"

say "Installing ai-aligned-chrome to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [ -r "$SOURCE" ]; then
    install -m 0755 "$SOURCE" "$INSTALL_DIR/ai-aligned-chrome"
    ok "installed ai-aligned-chrome from $SOURCE"
else
    say "No local copy found; downloading from $RAW_BASE_URL"
    curl -fsSL "$RAW_BASE_URL/$SOURCE_SCRIPT" -o "$INSTALL_DIR/ai-aligned-chrome"
    chmod 0755 "$INSTALL_DIR/ai-aligned-chrome"
    ok "downloaded and installed ai-aligned-chrome"
fi

say ""
say "Wrapping test browsers already on disk:"
"$INSTALL_DIR/ai-aligned-chrome" wrap

say ""
"$INSTALL_DIR/ai-aligned-chrome" agent install

say ""
"$INSTALL_DIR/ai-aligned-chrome" doctor || true
say ""
say "Undo with: ai-aligned-chrome agent uninstall && ai-aligned-chrome unwrap"
