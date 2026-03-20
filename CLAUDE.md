# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**embr.el** is an Emacs browser that uses headless Firefox (via Camoufox) as its rendering engine. Emacs acts as the display server showing JPEG screenshots, while a Python daemon handles browser automation.

## Architecture

Client-server over JSON lines on stdin/stdout:

```
Emacs (embr.el) ←→ JSON over stdin/stdout ←→ Python daemon (embr.py)
  UI / keybindings                            Playwright/Camoufox browser control
  Image display                               JPEG screenshot loop → /tmp/embr-frame.jpg
```

**embr.el** (~930 lines): Emacs Lisp major mode with process management, async JSON protocol, frame display, keybinding translation, link hints, tab management, bookmarks integration.

**embr.py** (~330 lines): asyncio-based daemon using Camoufox (Playwright API). Handles browser commands, screenshot capture loop, domain-level ad blocking (blocklist.txt), and form interaction.

**setup.sh**: Creates Python venv at `~/.local/share/embr/.venv/`, installs `camoufox[geoip]`, downloads browser, fetches StevenBlack/hosts blocklist. Builds in temp venv and swaps atomically.

## Key Design Patterns

- **JSON line protocol**: Each message is a single JSON line. Commands from Emacs have an `action` field; responses include `url`, `title`, and optionally `error`.
- **Frame streaming**: Python writes JPEG to temp file then renames atomically. Emacs reads the file on each frame notification. Frame batching skips intermediate frames if the UI can't keep up.
- **Async with callbacks**: `embr--send` dispatches commands with optional callback. `embr--send-sync` blocks via `accept-process-output` for synchronous results.
- **Dual click modes**: `atomic` defers mousedown until drag is detected (better iframe compat); `immediate` sends mousedown instantly.
- **Ad blocking**: Two layers — uBlock Origin (built into Camoufox) + domain-level route interception from blocklist.txt (~82K domains).

## Development Notes

- No formal test suite exists. Testing is manual via interactive Emacs commands.
- No linter/formatter configuration. Emacs Lisp follows GNU conventions; Python is PEP-ish.
- `blocklist.txt` is in `.gitignore` — it's downloaded by `setup.sh`, not checked in.
- Emacs 30.1+ required (native JSON parser). Python 3.10+ required.
- Browser profile persists at `~/.local/share/embr/firefox-profile/`.

## Git Policy

Never stage, commit, or push unless explicitly told to do so. Any such instruction is a one-time approval for that specific action only — never treat it as recurring authorization for future operations.

## Validation

After modifying code, always run `make test` before finishing. Do not consider the task complete if any check fails.

## Working with the Code

When modifying the JSON protocol (adding commands), both files must be updated:
1. Add the command handler in `embr.py`'s `handle_command` function
2. Add the Emacs-side command and keybinding in `embr.el`

Keybindings are defined near the bottom of `embr.el` in `embr-mode-map`. Printable chars (32-126) are forwarded to the browser. Emacs-style motion keys (C-n/p/b/f) are translated to arrow key equivalents. Browser commands use the `C-c` prefix.

## Keeping Docs in Sync

- **README.md `use-package` blocks**: The Elpaca and straight.el example configs in README.md must list all `defcustom` variables with their default values. When adding, removing, or renaming a config variable, update both `use-package` blocks to match.
- **README.md tables and keybindings**: After any change to configuration variables (add/remove/rename/default change) or keybindings (add/remove/rebind), update the corresponding Configuration table and Keybindings tables in README.md.
