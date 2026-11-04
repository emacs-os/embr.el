#!/bin/bash
set -euo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/embr"
VENV_DIR="$DATA_DIR/.venv"
TMP_VENV="$DATA_DIR/.venv.tmp"

MODE="${1:---cloakbrowser}"

mkdir -p "$DATA_DIR"

# Roll back to the previous venv if a step fails while TMP_VENV is being
# built.  Installed from a trap on EXIT by the venv-building functions.
cleanup() {
    if [ $? -ne 0 ]; then
        echo "ERROR: Setup failed. Cleaning up..." >&2
        rm -rf "$TMP_VENV"
        if [ -d "$VENV_DIR.old" ]; then
            rm -rf "$VENV_DIR"
            mv "$VENV_DIR.old" "$VENV_DIR"
            echo "Rolled back to previous venv." >&2
        fi
        exit 1
    fi
}

# Build a fresh venv in TMP_VENV with the given pip packages, then swap
# it into place atomically so a failed install leaves the old venv intact.
build_venv() {
    trap cleanup EXIT
    rm -rf "$TMP_VENV"
    python3 -m venv "$TMP_VENV"
    "$TMP_VENV/bin/pip" install "$@"
}

swap_venv() {
    rm -rf "$VENV_DIR.old"
    if [ -d "$VENV_DIR" ]; then
        mv "$VENV_DIR" "$VENV_DIR.old"
    fi
    mv "$TMP_VENV" "$VENV_DIR"
    rm -rf "$VENV_DIR.old"
}

do_cloakbrowser() {
    build_venv "cloakbrowser[geoip]"
    "$TMP_VENV/bin/python" -m cloakbrowser install
    swap_venv
}

do_chromium() {
    # Create a venv with playwright if none exists.  If a venv exists
    # (e.g. from --cloakbrowser), playwright is already present as a
    # dependency -- just download the browser binary.
    if [ ! -d "$VENV_DIR" ]; then
        build_venv playwright
        swap_venv
    fi
    # Download Playwright's bundled Chromium.
    "$VENV_DIR/bin/python" -m playwright install chromium
}

do_blocklist() {
    BLOCKLIST="$DATA_DIR/blocklist.txt"
    echo "Downloading ad blocklist..."
    curl -fsSL "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" \
        | grep "^0\.0\.0\.0 " \
        | awk '{print $2}' \
        | sort -u > "$BLOCKLIST.tmp"
    # A truncated download must not replace a good blocklist.
    if [ "$(wc -l < "$BLOCKLIST.tmp")" -lt 1000 ]; then
        rm -f "$BLOCKLIST.tmp"
        echo "ERROR: Blocklist download looks incomplete; keeping the existing one." >&2
        exit 1
    fi
    mv "$BLOCKLIST.tmp" "$BLOCKLIST"
    echo "Blocklist: $(wc -l < "$BLOCKLIST") domains"
}

# install_extension NAME LABEL REPO ASSET-SUFFIX
# Download the latest GitHub release asset of REPO whose name ends in
# ASSET-SUFFIX and unpack it into extensions/NAME, replacing the old
# copy only once the new one has unpacked.
install_extension() {
    local name="$1" label="$2" repo="$3" suffix="$4"
    local dir="$DATA_DIR/extensions/$name"
    local zip="$DATA_DIR/$name.zip"
    local tmp_dir="$dir.tmp"
    local url
    echo "Fetching latest $label release..."
    url=$(curl -fsSL -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$repo/releases/latest" \
        | grep -o "\"browser_download_url\": *\"[^\"]*$suffix\"" \
        | head -1 \
        | cut -d'"' -f4) || true
    if [ -z "$url" ]; then
        echo "ERROR: Could not find the $label release download URL." >&2
        exit 1
    fi
    curl -fsSL -o "$zip" "$url"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    unzip -qo "$zip" -d "$tmp_dir"
    rm -f "$zip"
    rm -rf "$dir"
    mv "$tmp_dir" "$dir"
    echo "$label installed to $dir"
}

case "$MODE" in
    --cloakbrowser)
        do_cloakbrowser
        ;;
    --chromium)
        do_chromium
        ;;
    --blocklist)
        do_blocklist
        ;;
    --ublock)
        install_extension ublock "uBlock Origin" gorhill/uBlock 'chromium\.zip'
        ;;
    --darkreader)
        install_extension darkreader "Dark Reader" darkreader/darkreader 'darkreader-chrome\.zip'
        ;;
    *)
        echo "Usage: setup.sh [--cloakbrowser|--chromium|--blocklist|--ublock|--darkreader]" >&2
        exit 1
        ;;
esac

echo "Done."
