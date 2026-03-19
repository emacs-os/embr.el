#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/embr"
BROWSERS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/camoufox"
BLOCKLIST="$SCRIPT_DIR/blocklist.txt"

echo "This will delete:"
echo "  Data dir (venv + profile):  $DATA_DIR"
echo "  Blocklist:                  $BLOCKLIST"
echo ""

read -rp "Proceed? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR"
    echo "Deleted $DATA_DIR"
else
    echo "$DATA_DIR not found, skipping."
fi

rm -f "$BLOCKLIST"

echo ""
read -rp "Also delete Camoufox's browser cache ($BROWSERS_DIR)? [y/N] " confirm2
if [[ "$confirm2" == [yY] ]] && [ -d "$BROWSERS_DIR" ]; then
    rm -rf "$BROWSERS_DIR"
    echo "Deleted $BROWSERS_DIR"
fi

echo ""
echo "Uninstall complete. Remove the Emacs package with your package manager."
