# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**embr.el** is an Emacs browser that uses headless Chromium (via CloakBrowser) as its rendering engine. Emacs acts as the display server, while a Python daemon handles browser automation.

## Architecture

Client-server over JSON lines on stdin/stdout:

```
Emacs (embr.el) ←→ JSON over stdin/stdout ←→ Python daemon (embr.py)
  UI / keybindings                            Playwright/CloakBrowser browser control
  Frame display                               CDP screencast or screenshot capture
  Canvas or JPEG rendering                    JPEG frames → file or Unix socket
```

**embr.el** (~3900 lines): Emacs Lisp major mode. Process management, async JSON protocol, two render backends (default + canvas), two frame sources (screencast + screenshot), link hints, tabs, bookmarks, zoom, mute, reader mode, page info, incognito mode.

**embr.py** (~1800 lines): asyncio daemon using CloakBrowser (Playwright API). Browser commands, CDP screencast, screenshot capture loop, canvas frame socket, domain-level ad blocking, extension loading (uBlock Origin, Dark Reader), incognito temp profiles.

**native/embr-canvas.c** (~400 lines): Emacs dynamic module for the canvas backend. Decodes JPEG frames with libjpeg-turbo straight into the Emacs 32 canvas pixel buffer (ARGB32), taking the canvas size from the image spec.

**setup.sh** (~140 lines): Creates Python venv at `$XDG_DATA_HOME/embr/.venv/` (default `~/.local/share/embr/.venv/`), installs `cloakbrowser[geoip]`, downloads browser. Separate flags for blocklist, uBlock Origin, and Dark Reader (downloaded from GitHub releases API). Builds in temp venv and swaps atomically; downloads fail loudly rather than replacing a good file with a truncated one.

## Frame Pipeline

Two frame sources (`embr-frame-source`):

- **`'screencast`** (default, recommended): CDP `Page.screencastFrame` pushes frames from Chromium. Python decodes base64 JPEG data and writes to disk or sends over Unix socket.
- **`'screenshot`**: Python polls `page.screenshot()` in a loop at target FPS. Older, slower.

Two render backends (`embr-render-backend`):

- **`'default`**: Python writes JPEG to `frame.jpg` in a private per-daemon runtime directory (`tempfile.mkdtemp`, mode 0700; the path comes back in the init response as `frame_path`), renames atomically. Emacs reads the file via `insert-file-contents-literally` and displays with `create-image` at `:scale 1`, flushing the previous frame from the image cache. A one-shot render timer is armed only while a frame is pending, rate-limited to `embr-fps`.
- **`'canvas`**: Python sends JPEG bytes over a Unix socket in the same runtime directory, with a 20-byte binary header (seq, width, height, length, stream id). Emacs native C module (`embr-canvas-blit-jpeg CANVAS JPEG-DATA`) decodes directly into the canvas pixel buffer (clipping to the canvas size read from the spec's `:data-width`/`:data-height`, black-filling the rest), then calls `canvas-refresh`. Requires Emacs 32+ (native canvas images). `embr-render-backend` defaults to `'auto` (`'default` behaves identically): `embr--canvas-probe` (Emacs support, module build, module load, smoke blit) decides once per session and `embr--select-backend` falls back to the JPEG file backend with a one-time notice.

## Buffer-Local State and Multi-Session

All per-session state is buffer-local in `embr-mode`. This enables normal + incognito sessions running simultaneously in separate buffers with separate daemon processes.

Key patterns:
- `embr--process`, `embr--pending-callbacks`, `embr--frame-path`, `embr--active-backend`, all timers, all canvas state are buffer-local (set via `setq-local` in `embr-mode`)
- Process filter (`embr--process-filter`) routes output to the correct buffer via `(process-get proc 'embr-buffer)` + `with-current-buffer`
- Canvas socket filter (`embr--canvas-socket-filter`) uses the same routing pattern
- Hover and render timers capture the owning buffer in a closure at creation time and use `with-current-buffer` in the tick function
- `embr--default-display-frame` captures `embr--frame-path` in a let binding before entering `with-temp-buffer` (buffer-local vars are not visible inside `with-temp-buffer`)
- Each canvas image gets a unique uninterned `:id` symbol derived from the buffer name (the image cache compares specs with `equal`, so a resize must produce a non-`equal` spec)

Incognito mode (`embr-browse-incognito`) uses the same `embr-mode` with `embr--incognito-flag` set. The daemon gets `EMBR_INCOGNITO=1` env var, uses `tempfile.mkdtemp()` for its profile, separate frame/perf-log paths, and `shutil.rmtree()` on quit.

## Key Design Patterns

- **JSON line protocol**: Each message is a single JSON line. Commands from Emacs have a `cmd` field and an `id` that the daemon echoes in the response, so `embr--send` can hold several callbacks in flight (`embr--pending-callbacks`) while fire-and-forget traffic (hover, frame acks) is interleaved. Responses include `url`, `title`, and optionally `error`. Use `json-serialize` / `json-parse-string` (Emacs 30.1+ native C JSON, not the old `json.el`).
- **Frame batching**: Process filter stashes latest frame in `embr--pending-frame` and arms a one-shot render timer (`embr--render-schedule`, rate-limited to `embr-fps`). The tick picks up the latest frame, skipping intermediate frames if Emacs can't keep up; an idle session has no periodic timer.
- **Sessions persist on change**: `embr--save-session` runs from every tab-list update and URL change (deduplicated against the last write) and removes the file when the last tab is closed; `embr--restore-session` keeps the file. Saving starts only once `embr--session-loaded` is set, because the init response already carries the daemon's blank tab.
- **Async with callbacks**: `embr--send` dispatches commands with optional callback. `embr--send-sync` blocks via `accept-process-output` for synchronous results.
- **Dual click modes**: `atomic` defers mousedown until drag is detected (better iframe compat); `immediate` sends mousedown instantly.
- **Ad blocking**: Domain-level route interception from blocklist.txt (~82K domains).
- **Extension loading**: Python collects extension dirs into a single `--load-extension=dir1,dir2` Chrome arg. Extensions auto-detected at startup if present.
- **Transient dispatch**: `C-c` opens a transient menu (`embr-dispatch`). Top-level bindings shown via `C-c ?` (`embr-dispatch-keys`). Both are `transient-define-prefix` forms.
- **kill-buffer-hook**: `embr--kill-buffer-cleanup` sends quit to the daemon when the buffer is killed by any means, preventing orphan processes.
- **Shared init params**: `embr--build-init-params` builds the init command alist from defcustom values. Used by both `embr-browse` and `embr-browse-incognito`.

## Development Notes

- No formal test suite. Testing is manual via interactive Emacs commands.
- No linter/formatter config. Emacs Lisp follows GNU conventions; Python is PEP-ish.
- `blocklist.txt` is in `.gitignore` -- downloaded by `setup.sh`, not checked in.
- Emacs 30.1+ required (native JSON via `json-serialize`/`json-parse-string`). Emacs 32+ required for the canvas backend. Python 3.10+ required.
- Browser profile persists at `~/.local/share/embr/chromium-profile/`.
- Extensions stored at `~/.local/share/embr/extensions/` (ublock/, darkreader/).
- Incognito uses temp profile wiped on quit. Separate frame path (`embr-incognito-frame.jpg`) and perf log (`embr-incognito-perf.jsonl`).

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
1. Add the command handler in `embr.py`'s `handle(cmd, params)` function
2. Add the Emacs-side command and keybinding in `embr.el`
3. Add the dispatch menu entry in the appropriate `transient-define-prefix`

Keybindings are defined near the bottom of `embr.el` in `embr-mode-map`. Printable chars (32-126) are forwarded to the browser. Emacs-style motion keys (C-n/p/b/f) are translated to arrow key equivalents. Browser commands use the `C-c` prefix via transient dispatch.

When adding buffer-local state, follow the existing pattern:
1. Add `(defvar embr--foo ...)` with the global default
2. Add `(setq-local embr--foo ...)` in `embr-mode`
3. Never read buffer-local vars inside `with-temp-buffer` -- capture them in a `let` first
4. Timer callbacks must capture the owning buffer in a closure and use `with-current-buffer`
5. Process/socket filters must route via `(process-get proc 'embr-buffer)`

## Keeping Docs in Sync

- **README.md `use-package` blocks**: The example configs show only commonly-tuned settings (e.g. color scheme, search engine, display method) — not every `defcustom`. Keep them minimal and representative.
- **README.md Configuration table**: Only user-tunable `defcustom` variables belong here — settings a user would adjust to improve their experience (viewport size, color scheme, hover rate, etc.). Omit internal plumbing (venv paths, script paths, installer-tied defaults) and deprecated variables. Exposing either invites misconfiguration; experts will find them via `describe-variable` anyway. When adding, removing, renaming, or changing a default for a user-tunable variable, update this table.
- **README.md Keybindings tables**: After any keybinding change (add/remove/rebind), update the corresponding tables.
