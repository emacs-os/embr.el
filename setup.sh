#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VENV_DIR=".venv"
TMP_VENV=".venv.tmp"

cleanup() {
    if [ $? -ne 0 ]; then
        echo "ERROR: Setup failed. Cleaning up..." >&2
        rm -rf "$TMP_VENV"
        if [ -d ".venv.old" ]; then
            mv ".venv.old" "$VENV_DIR"
            echo "Rolled back to previous venv." >&2
        fi
        exit 1
    fi
}
trap cleanup EXIT

# Build everything in a temp venv.
rm -rf "$TMP_VENV"
python3 -m venv "$TMP_VENV"
"$TMP_VENV/bin/pip" install playwright
"$TMP_VENV/bin/python" -m playwright install firefox

# Swap atomically.
if [ -d "$VENV_DIR" ]; then
    mv "$VENV_DIR" ".venv.old"
fi
mv "$TMP_VENV" "$VENV_DIR"
rm -rf ".venv.old"

echo "Setup complete. Firefox and Playwright are ready."
