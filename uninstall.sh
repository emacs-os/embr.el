#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VENV_DIR=".venv"
BROWSERS_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright"
PROFILE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/better-eww"

echo "This will delete:"
echo "  Python venv:         $(pwd)/$VENV_DIR"
echo "  Browser profile:     $PROFILE_DIR"
echo ""

read -rp "Proceed? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

if [ -d "$VENV_DIR" ]; then
    rm -rf "$VENV_DIR"
    echo "Deleted $VENV_DIR"
else
    echo "$VENV_DIR not found, skipping."
fi

if [ -d "$PROFILE_DIR" ]; then
    rm -rf "$PROFILE_DIR"
    echo "Deleted $PROFILE_DIR"
else
    echo "$PROFILE_DIR not found, skipping."
fi

echo ""
read -rp "Also delete Playwright's shared browser cache ($BROWSERS_DIR)? [y/N] " confirm2
if [[ "$confirm2" == [yY] ]] && [ -d "$BROWSERS_DIR" ]; then
    rm -rf "$BROWSERS_DIR"
    echo "Deleted $BROWSERS_DIR"
fi

echo ""
echo "Uninstall complete. Remove the Emacs package with your package manager."
