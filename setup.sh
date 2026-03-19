#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/embr"
VENV_DIR="$DATA_DIR/.venv"
TMP_VENV="$DATA_DIR/.venv.tmp"

mkdir -p "$DATA_DIR"

cleanup() {
    if [ $? -ne 0 ]; then
        echo "ERROR: Setup failed. Cleaning up..." >&2
        rm -rf "$TMP_VENV"
        if [ -d "$VENV_DIR.old" ]; then
            mv "$VENV_DIR.old" "$VENV_DIR"
            echo "Rolled back to previous venv." >&2
        fi
        exit 1
    fi
}
trap cleanup EXIT

# Build everything in a temp venv.
rm -rf "$TMP_VENV"
python3 -m venv "$TMP_VENV"
# "$TMP_VENV/bin/pip" install playwright
# "$TMP_VENV/bin/python" -m playwright install firefox
"$TMP_VENV/bin/pip" install "camoufox[geoip]"
"$TMP_VENV/bin/python" -m camoufox fetch

# Swap atomically.
if [ -d "$VENV_DIR" ]; then
    mv "$VENV_DIR" "$VENV_DIR.old"
fi
mv "$TMP_VENV" "$VENV_DIR"
rm -rf "$VENV_DIR.old"

# Download ad/tracker blocklist into the package dir (next to embr.py).
BLOCKLIST="$SCRIPT_DIR/blocklist.txt"
echo "Downloading ad blocklist..."
curl -sL "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" \
    | grep "^0\.0\.0\.0 " \
    | awk '{print $2}' \
    | sort -u > "$BLOCKLIST.tmp"
mv "$BLOCKLIST.tmp" "$BLOCKLIST"
echo "Blocklist: $(wc -l < "$BLOCKLIST") domains"

echo "Setup complete. Camoufox is ready."
