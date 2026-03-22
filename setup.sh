#!/bin/bash
set -euo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/embr"
VENV_DIR="$DATA_DIR/.venv"
TMP_VENV="$DATA_DIR/.venv.tmp"

MODE="${1:---all}"

mkdir -p "$DATA_DIR"

do_venv() {
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

    rm -rf "$TMP_VENV"
    python3 -m venv "$TMP_VENV"
    "$TMP_VENV/bin/pip" install "cloakbrowser[geoip]"
    "$TMP_VENV/bin/python" -m cloakbrowser install

    if [ -d "$VENV_DIR" ]; then
        mv "$VENV_DIR" "$VENV_DIR.old"
    fi
    mv "$TMP_VENV" "$VENV_DIR"
    rm -rf "$VENV_DIR.old"
}

do_blocklist() {
    BLOCKLIST="$DATA_DIR/blocklist.txt"
    echo "Downloading ad blocklist..."
    curl -sL "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" \
        | grep "^0\.0\.0\.0 " \
        | awk '{print $2}' \
        | sort -u > "$BLOCKLIST.tmp"
    mv "$BLOCKLIST.tmp" "$BLOCKLIST"
    echo "Blocklist: $(wc -l < "$BLOCKLIST") domains"
}

do_ublock() {
    UBLOCK_DIR="$DATA_DIR/extensions/ublock"
    echo "Fetching latest uBlock Origin release..."
    UBLOCK_URL=$(curl -sL "https://api.github.com/repos/gorhill/uBlock/releases/latest" \
        | grep -o '"browser_download_url": *"[^"]*chromium\.zip"' \
        | head -1 \
        | cut -d'"' -f4)
    if [ -n "$UBLOCK_URL" ]; then
        UBLOCK_TMP="$DATA_DIR/ublock.zip"
        curl -sL -o "$UBLOCK_TMP" "$UBLOCK_URL"
        rm -rf "$UBLOCK_DIR"
        mkdir -p "$UBLOCK_DIR"
        unzip -qo "$UBLOCK_TMP" -d "$UBLOCK_DIR"
        rm -f "$UBLOCK_TMP"
        echo "uBlock Origin installed to $UBLOCK_DIR"
    else
        echo "WARNING: Could not fetch uBlock Origin release URL." >&2
    fi
}

do_darkreader() {
    DARKREADER_DIR="$DATA_DIR/extensions/darkreader"
    echo "Fetching latest Dark Reader release..."
    DARKREADER_URL=$(curl -sL "https://api.github.com/repos/darkreader/darkreader/releases/latest" \
        | grep -o '"browser_download_url": *"[^"]*darkreader-chrome\.zip"' \
        | head -1 \
        | cut -d'"' -f4)
    if [ -n "$DARKREADER_URL" ]; then
        DARKREADER_TMP="$DATA_DIR/darkreader.zip"
        curl -sL -o "$DARKREADER_TMP" "$DARKREADER_URL"
        rm -rf "$DARKREADER_DIR"
        mkdir -p "$DARKREADER_DIR"
        unzip -qo "$DARKREADER_TMP" -d "$DARKREADER_DIR"
        rm -f "$DARKREADER_TMP"
        echo "Dark Reader installed to $DARKREADER_DIR"
    else
        echo "WARNING: Could not fetch Dark Reader release URL." >&2
    fi
}

case "$MODE" in
    --all)
        do_venv
        do_blocklist
        do_ublock
        ;;
    --blocklist)
        do_blocklist
        ;;
    --ublock)
        do_ublock
        ;;
    --darkreader)
        do_darkreader
        ;;
    *)
        echo "Usage: setup.sh [--all|--blocklist|--ublock|--darkreader]" >&2
        exit 1
        ;;
esac

echo "Done."
