I need you to stop guessing, stop treating me like I'm dumb, ask me more questions about how I want to solve this, etc.

NEVER USE em dashes, semicolons, or emojis in the README file. The audience is smart. Be brief, keep it simple. No jargon dumps or over-explaining.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**embr.el** is an Emacs browser that uses headless Chromium (via CloakBrowser) as its rendering engine. Emacs acts as the display server showing JPEG screenshots, while a Python daemon handles browser automation.

## Architecture

Client-server over JSON lines on stdin/stdout:

```
Emacs (embr.el) ←→ JSON over stdin/stdout ←→ Python daemon (embr.py)
  UI / keybindings                            Playwright/CloakBrowser browser control
  Image display                               JPEG screenshot loop → /tmp/embr-frame.jpg
```

**embr.el** (~930 lines): Emacs Lisp major mode with process management, async JSON protocol, frame display, keybinding translation, link hints, tab management, bookmarks integration.

**embr.py** (~330 lines): asyncio-based daemon using CloakBrowser (Playwright API). Handles browser commands, screenshot capture loop, domain-level ad blocking (blocklist.txt), and form interaction.

**setup.sh**: Creates Python venv at `~/.local/share/embr/.venv/`, installs `cloakbrowser[geoip]`, downloads browser, fetches StevenBlack/hosts blocklist. Builds in temp venv and swaps atomically.

## Key Design Patterns

- **JSON line protocol**: Each message is a single JSON line. Commands from Emacs have an `action` field; responses include `url`, `title`, and optionally `error`.
- **Frame streaming**: Python writes JPEG to temp file then renames atomically. Emacs reads the file on each frame notification. Frame batching skips intermediate frames if the UI can't keep up.
- **Async with callbacks**: `embr--send` dispatches commands with optional callback. `embr--send-sync` blocks via `accept-process-output` for synchronous results.
- **Dual click modes**: `atomic` defers mousedown until drag is detected (better iframe compat); `immediate` sends mousedown instantly.
- **Ad blocking**: Domain-level route interception from blocklist.txt (~82K domains).

## Development Notes

- No formal test suite exists. Testing is manual via interactive Emacs commands.
- No linter/formatter configuration. Emacs Lisp follows GNU conventions; Python is PEP-ish.
- `blocklist.txt` is in `.gitignore` — it's downloaded by `setup.sh`, not checked in.
- Emacs 30.1+ required (native JSON parser). Python 3.10+ required.
- Browser profile persists at `~/.local/share/embr/chromium-profile/`.

## Git Policy

Never stage, commit, or push unless explicitly told to do so. Any such instruction is a one-time approval for that specific action only — never treat it as recurring authorization for future operations.

## Validation

After modifying code, always run `make test` before finishing. This runs `make checkparens` (balanced parens), `make bytecompile` (byte-compilation), `make checkpy` (Python syntax), and `make shellcheck` (shell scripts). Do not consider the task complete if any check fails.

## Emacs Lisp Standards

All Elisp code must follow GNU Coding Standards and Emacs Lisp conventions.

Full references:
- GNU Coding Standards: https://www.gnu.org/prep/standards/
- Emacs Lisp Tips and Conventions: https://www.gnu.org/software/emacs/manual/html_node/elisp/Tips.html

### Naming Conventions

- All global symbols use the package prefix `embr-` (public) or `embr--` (private)
- Predicates: one-word names end in `p`, multi-word in `-p`
- Boolean variables: use `-flag` suffix or `is-foo`, not `-p` (unless bound to a predicate function)
- Function-storing variables: end in `-function`; hook variables: follow hook naming conventions
- File/directory variables: use `file`, `file-name`, or `directory`, never `path` (reserved for search paths)
- No `*var*` naming convention; that is not used in Emacs Lisp

### Coding Conventions

- Lexical binding required
- Use `require` for hard dependencies; `(eval-when-compile (require 'bar))` for compile-time-only macro dependencies
- Use `cl-lib`, never the deprecated `cl` library
- Never use `defadvice`, `eval-after-load`, or `with-eval-after-load`
- Loading a package must not change editing behavior; require explicit enable/invoke commands
- Use default indentation; never put closing parens on their own line
- Remove all trailing whitespace; use `?\s` for space character (not `? `)

### Documentation Strings

- Every public function and variable needs a docstring
- First line: complete sentence, imperative voice, capital letter, ends with period, max 74 chars
- Function docstrings: "Return X." not "Returns X." Active voice, present tense.
- Argument references: UPPERCASE (e.g., "Evaluate FORM and return its value.")
- Symbol references: lowercase with backtick-quote (e.g., `` `lambda' ``) -- except t and nil unquoted
- Predicates: start with "Return t if"
- Boolean variables: start with "Non-nil means"
- User options: use `defcustom`

### Comment Conventions

- `;` -- right-aligned inline comments on code lines
- `;;` -- indented to code level, describes following code or program state
- `;;;` -- left margin, section headings (Outline mode)

### Performance and Programming Tips

- Prefer iteration over recursion (function calls are slow in Elisp)
- Prefer lists over vectors unless random access on large tables is needed
- Use `memq`, `member`, `assq`, `assoc` over manual iteration
- Use `forward-line` not `next-line`/`previous-line`
- Don't call `beginning-of-buffer`, `end-of-buffer`, `replace-string`, `replace-regexp`, `insert-file`, `insert-buffer` in programs
- Use `message` for echo area output, not `princ`
- Use `error` or `signal` for error conditions (not `message`, `throw`, `sleep-for`, `beep`)
- Error messages: capital letter, no trailing period. Optionally prefix with `symbol-name:`
- Minibuffer prompts: questions end with `?`, defaults shown as `(default VALUE)`
- Progress messages: `"Operating..."` then `"Operating...done"` (no spaces around ellipsis)

### Compiler Warnings

- Use `(defvar foo)` to suppress free variable warnings
- Use `declare-function` for functions known to be defined elsewhere
- Use `with-no-warnings` as last resort for intentional non-standard usage

## Working with the Code

When modifying the JSON protocol (adding commands), both files must be updated:
1. Add the command handler in `embr.py`'s `handle_command` function
2. Add the Emacs-side command and keybinding in `embr.el`

Keybindings are defined near the bottom of `embr.el` in `embr-mode-map`. Printable chars (32-126) are forwarded to the browser. Emacs-style motion keys (C-n/p/b/f) are translated to arrow key equivalents. Browser commands use the `C-c` prefix.

## Keeping Docs in Sync

- **README.md `use-package` blocks**: The example configs show only commonly-tuned settings (e.g. color scheme, search engine, display method) — not every `defcustom`. Keep them minimal and representative.
- **README.md Configuration table**: All `defcustom` variables with their defaults must appear here. When adding, removing, renaming, or changing a default, update this table.
- **README.md Keybindings tables**: After any keybinding change (add/remove/rebind), update the corresponding tables.
