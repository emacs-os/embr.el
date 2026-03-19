# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

embr is a real web browser inside Emacs. It runs headless Firefox via Playwright, renders pages as PNG screenshots displayed in an Emacs image buffer, and forwards mouse/keyboard/scroll events back to Firefox. Two files do all the work: a Python daemon and an Emacs package.

## Architecture

Emacs (`embr.el`) spawns a Python subprocess (`embr.py`). They communicate via JSON lines over stdin/stdout — one JSON object per line, no sockets or HTTP. Every command (click, type, scroll, navigate) returns a base64-encoded PNG screenshot plus page title and URL.

The daemon holds a single Playwright persistent browser context with one page. Persistent context means cookies/sessions survive across restarts (stored in `~/.local/share/embr/firefox-profile/`). Playwright uses its own bundled Firefox (not the system one) — this is required because Playwright patches Firefox for its automation protocol.

The Emacs side has two input modes: **navigation mode** (vim-like keys: `g` navigate, `B` back, `F` forward, `r` refresh, `q` quit) and **insert mode** (`i` to enter, `C-g` to exit) where all keystrokes are forwarded to the browser.

## Setup

```bash
bash setup.sh   # creates .venv, installs playwright, downloads bundled firefox
```

## Testing the Daemon Standalone

```bash
printf '{"cmd":"init","width":1280,"height":720}\n{"cmd":"navigate","url":"https://example.com"}\n{"cmd":"quit"}\n' | .venv/bin/python embr.py
```

First line of output is `{"ok": true}`, second is a JSON object with `screenshot` (base64 PNG), `title`, and `url`.

## Testing in Emacs

```elisp
(load-file "/path/to/embr/embr.el")
M-x embr-browse RET https://example.com RET
```

## README Convention

The use-package blocks in the README (Elpaca and straight.el) must always list every `defcustom` configuration option with its default value. This gives users copy-paste-ready config with all knobs visible. When adding a new `defcustom`, always add it to both use-package blocks and the Configuration table in the README.

## Key Conventions

- Python daemon: async (`asyncio`), single-file, no classes — just `async def handle()` with a flat if/elif command dispatch. Stdout is exclusively for JSON responses; all logging/errors from Playwright go to stderr.
- Elisp package: single-file, `embr-` public prefix, `embr--` private prefix. Communication is async via process filters and callbacks; `embr--send-sync` is only used during init.
- Playwright key names (e.g. `"Enter"`, `"ArrowDown"`, `"Backspace"`) are used in the JSON protocol. The elisp side translates Emacs key descriptions to Playwright names in `embr--translate-key`.
