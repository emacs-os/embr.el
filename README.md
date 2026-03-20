## embr.el
**Em**acs **Br**owser

Emacs is the display server. Headless Chromium via [CloakBrowser](https://cloakbrowser.dev) is the renderer.

![embr screenshot](assets/screenshot.png)

## Prerequisites

- Python 3.10+
- Emacs 30.1+ (with image support)

## Installation

**Elpaca**

```elisp
(use-package embr
  :defer t
  :ensure (:host github
           :repo "emacs-os/embr.el"
           :files ("*.el" "*.py" "*.sh"))
  :config
  (setq embr-fps 60
        embr-jpeg-quality 80
        embr-hover-rate 20
        embr-default-width 1280
        embr-default-height 720
        embr-screen-width 1920
        embr-screen-height 1080
        embr-color-scheme 'dark
        embr-search-engine 'google
        embr-click-method 'immediate
        embr-scroll-method 'smooth
        embr-scroll-step 300
        embr-dom-caret-hack t
        embr-perf-log nil
        embr-input-priority-window-ms 35
        embr-adaptive-capture t
        embr-adaptive-fps-min 40
        embr-adaptive-jpeg-quality-min 65
        embr-hover-move-threshold-px 0
        embr-hover-rate-min 14
        embr-external-command "yt-dlp -o - %s | mpv -"
))
```

**straight.el**

```elisp
(use-package embr
  :defer t
  :straight (:host github
             :repo "emacs-os/embr.el"
             :files ("*.el" "*.py" "*.sh"))
  :config
  (setq embr-fps 60
        embr-jpeg-quality 80
        embr-hover-rate 20
        embr-default-width 1280
        embr-default-height 720
        embr-screen-width 1920
        embr-screen-height 1080
        embr-color-scheme 'dark
        embr-search-engine 'google
        embr-click-method 'immediate
        embr-scroll-method 'smooth
        embr-scroll-step 300
        embr-dom-caret-hack t
        embr-perf-log nil
        embr-input-priority-window-ms 35
        embr-adaptive-capture t
        embr-adaptive-fps-min 40
        embr-adaptive-jpeg-quality-min 65
        embr-hover-move-threshold-px 0
        embr-hover-rate-min 14
        embr-external-command "yt-dlp -o - %s | mpv -"
))
```

**Tip:** Make embr your default Emacs browser and enable clickable URLs everywhere:

```elisp
(setq browse-url-browser-function 'embr-browse)
(global-goto-address-mode 1)
```

## Setup

After installing, run `M-x embr-setup-or-update` to create the Python venv and download CloakBrowser (a stealth Chromium with source-level fingerprint patches).

If you skip this step, `M-x embr-browse` will detect the missing venv and offer to run setup for you automatically.

### Management commands

All management is done from Emacs, no terminal needed.

| Command | Description |
|---------|-------------|
| `M-x embr-setup-or-update` | Install or update venv + CloakBrowser + ad blocklist (runs `setup.sh`) |
| `M-x embr-uninstall` | Remove venv and browser profile; optionally delete browser cache (runs `uninstall.sh`) |
| `M-x embr-info` | Show diagnostic info about the installation |

The underlying `setup.sh` builds in a temp venv and swaps atomically, so it's always safe to re-run for both first install and updates.

### Where state is stored

| What | Path (0.40+) | Path (0.30) |
|------|--------------|-------------|
| Python venv | `~/.local/share/embr/.venv/` | same |
| Browser binary | `~/.cache/cloakbrowser/` | `~/.cache/camoufox/` |
| Cookies & sessions | `~/.local/share/embr/chromium-profile/` | `~/.local/share/embr/firefox-profile/` |

`M-x embr-uninstall` removes the venv and profile; browser cache deletion is offered as an optional prompt.

### Migrating from 0.30 to 0.40

Version 0.40 replaces the browser engine (Camoufox/Firefox → CloakBrowser/Chromium). A clean install is recommended:

1. On 0.30, run `M-x embr-uninstall` to remove the old venv, browser cache, and profile.
2. Remove the package from Elpaca/straight (delete from your config, restart Emacs, let it re-clone).
3. Install 0.40 fresh and run `M-x embr-setup-or-update`.

If you skipped step 1, you can manually remove leftover 0.30 state:

```sh
rm -rf ~/.local/share/embr ~/.cache/camoufox
```

## Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `embr-python` | file | `~/.local/share/embr/.venv/bin/python` | Path to Python interpreter in the embr venv. |
| `embr-script` | file | `embr.py` in package dir | Path to the embr.py daemon script. |
| `embr-fps` | integer | `60` | Target frames per second |
| `embr-jpeg-quality` | integer | `80` | JPEG quality (1-100). Lower = smaller frames, less CDP contention, worse image. 50 halves frame size. |
| `embr-hover-rate` | integer | `20` | Mouse hover tracking rate in Hz. Lower = better click reliability during video, less responsive hover. |
| `embr-default-width` | integer | `1280` | Viewport width in pixels |
| `embr-default-height` | integer | `720` | Viewport height in pixels |
| `embr-screen-width` | integer | `1920` | Screen width reported to websites (should be >= viewport) |
| `embr-screen-height` | integer | `1080` | Screen height reported to websites (should be >= viewport) |
| `embr-color-scheme` | symbol/nil | `'dark` | `'dark`, `'light`, or `nil` to let CloakBrowser choose. Controls `prefers-color-scheme`. |
| `embr-search-engine` | symbol/string | `'google` | `'google`, `'brave`, `'duckduckgo`, or custom URL with `%s` |
| `embr-click-method` | symbol | `'immediate` | `'atomic` defers mousedown until drag detected, better iframe compat. `'immediate` sends mousedown instantly, for press-and-hold sites. |
| `embr-scroll-method` | symbol | `'smooth` | `'smooth` scrolls with CSS animation. `'instant` scrolls instantly, line-by-line feel. |
| `embr-scroll-step` | integer | `300` | Scroll distance in pixels per wheel notch |
| `embr-dom-caret-hack` | boolean | `t` | Inject a fake DOM caret in focused text fields. CDP screenshots don't capture the native caret. |
| `embr-perf-log` | boolean | `nil` | Write JSONL perf events to `/tmp/embr-perf.jsonl`. Analyze with `tools/embr-perf-report.py`. |
| `embr-input-priority-window-ms` | integer | `35` | Milliseconds to suppress frame capture after interactive input. Frees CDP pipe for input commands. 0 to disable. |
| `embr-adaptive-capture` | boolean | `t` | Auto-tune FPS and JPEG quality based on capture cost. Lowers when over budget, recovers when stable. |
| `embr-adaptive-fps-min` | integer | `40` | Minimum FPS the adaptive controller will step down to. |
| `embr-adaptive-jpeg-quality-min` | integer | `65` | Minimum JPEG quality the adaptive controller will step down to. |
| `embr-hover-move-threshold-px` | integer | `0` | Minimum pixel distance before sending a hover update. Filters sub-pixel jitter. |
| `embr-hover-rate-min` | integer | `14` | Minimum hover rate (Hz) under load pressure. Hover self-throttles from `embr-hover-rate` to this. |
| `embr-external-command` | string | yt-dlp + mpv | Shell command for `&` key (`%s` = URL). Default pipes through yt-dlp into mpv. |

## Usage

```
M-x embr-browse RET https://example.com RET
```

## Keybindings

All keys are forwarded directly to the browser. Typing, arrows, backspace, tab, and enter work as expected. `C-x`, `M-x`, etc. stay free for Emacs.

The top-level keybindings below translate familiar Emacs motion keys into their browser equivalents — if you're familiar with EXWM, same concept as simulation keys.

| Key | Action |
|-----|--------|
| `C-l` | Go to URL or search (with history completion) |
| `C-b` | Left arrow |
| `C-f` | Right arrow |
| `C-n` | Down arrow |
| `C-p` | Up arrow |
| `C-a` | Home |
| `C-e` | End |
| `C-d` | Delete forward |
| `M-f` | Word forward |
| `M-b` | Word backward |
| `M-w` | Copy browser selection to kill ring (system clipboard) |
| `C-y` | Paste from kill ring into browser |
| `C-s` | Search forward (isearch-style) |
| `C-r` | Search backward (isearch-style) |
| `C-v` | Page down |
| `M-v` | Page up |
| `&` | Run `embr-external-command` on current URL (default: yt-dlp + mpv) |
| `F5` | Refresh page |
| `C-x` | Emacs prefix (not forwarded) |
| `M-x` | Emacs command (not forwarded) |
| `C-c` | Browser command prefix (see below) |

### Browser commands

Browser commands use the `C-c` prefix — eww-inspired commands, just behind a prefix instead of on top-level keys. This gives a more natural browser typing experience while keeping power tools a combo away.

| Key | Action |
|-----|--------|
| `C-c l` | Go to URL or search (same as `C-l`) |
| `C-c h` | Follow link (Vimium-style hint labels) |
| `C-c r` | Refresh |
| `C-c b` / `C-c C-b` | Back |
| `C-c f` / `C-c C-f` | Forward |
| `C-c t` | View page text in a separate buffer |
| `C-c w` | Copy current URL to kill ring |
| `C-c :` | Execute JavaScript |
| `C-c q` | Quit (kills daemon and buffer) |
| `C-c n` | Open new tab |
| `C-c d` | Close current tab |
| `C-c ]` / `C-c [` | Next / previous tab |
| `C-c a` | List all tabs |
| Mouse click | Click at coordinates |
| Click and drag | Select text |
| Scroll wheel | Scroll page |

### Bookmarks

Standard Emacs bookmarks work: `C-x r m` to save, `C-x r b` to jump.

## Ad Blocking

**Domain-level blocklist** — using the [StevenBlack/hosts](https://github.com/StevenBlack/hosts) list (~82K ad and tracker domains), requests to blocked domains are intercepted and killed before they hit the network.

The blocklist is downloaded automatically by `setup.sh` and refreshed every time you run `M-x embr-setup-or-update`.

## How It Works

Emacs spawns a Python subprocess (`embr.py`) that controls headless Chromium through [CloakBrowser](https://cloakbrowser.dev) (a stealth Chromium with source-level fingerprint patches). They communicate via JSON lines over stdin/stdout. The daemon streams JPEG screenshots via a temp file on disk, giving live visual feedback.

Browser sessions persist across restarts. Cookies and login state are stored in `~/.local/share/embr/chromium-profile/`.

### Avoiding CDP deadlocks

The browser is controlled via the Chrome DevTools Protocol (CDP) over a single pipe. Screenshot capture (`Page.captureScreenshot`) sends ~60KB per frame and dominates the pipe's bandwidth. Mouse and keyboard input (`Input.dispatch*`) must share the same pipe.

Under video playback, screenshot traffic can starve input commands — a CDP `Input.dispatchMouseEvent` call may hang indefinitely waiting for pipe bandwidth, freezing all mouse interaction while the video keeps playing.

embr uses several strategies to prevent this:

- **Decoupled rendering**: The Emacs process filter stashes the latest frame instead of rendering synchronously. A timer renders frames at a capped rate, giving the Emacs event loop idle time to process user input between frames.
- **Batch-read with mousemove coalescing**: The daemon reads all pending stdin commands at once and collapses consecutive `mousemove` messages down to one, preventing hover traffic (`embr-hover-rate` Hz, default 20) from starving real commands like clicks and navigation.
- **Split CDP domains for input**: Click events are dispatched via `page.evaluate()` (Runtime domain) instead of `page.mouse.*()` (Input domain), so they don't contend with screenshot traffic. Mousedown and mouseup use CDP Input domain (`page.mouse.down()`/`page.mouse.up()`) for `isTrusted=true` native text selection — they are fire-and-forget and infrequent (one per drag). Scroll uses `page.evaluate()` (Runtime domain).
- **Fire-and-forget mousemove**: Hover tracking uses CDP `page.mouse.move()` (for `isTrusted=true` CSS `:hover` support) but as a cancel-and-replace background task — each new move cancels the previous in-flight one. A hung move can never block screenshots, clicks, or the command loop.
- **Fire-and-forget keyboard/scroll**: Keyboard and scroll commands run as independent asyncio tasks. Keyboard uses `page.keyboard.type()`/`page.keyboard.press()` (CDP Input domain) for `isTrusted=true` events; scroll uses `page.evaluate()` (Runtime domain). Both are fire-and-forget and cannot block each other or the command loop.
- **Title caching**: `page.title()` is queried once per second instead of every frame, halving per-frame CDP traffic.
- **Safety timeout**: A 35-second outer timeout on the command loop ensures that even if a navigation or page load hangs, the daemon recovers and continues processing input.

The net effect: video playback stays smooth, mouse hover updates CSS `:hover` state correctly, and clicks/keyboard/scroll never hang regardless of screenshot throughput. Click events are JavaScript-dispatched (`isTrusted=false`), which works for most sites but may not trigger browser-gated actions like the Fullscreen API.

### Keyboard-driven browsing

The keyboard flow does not hit the deadlock conditions because:

1. **No continuous CDP Input traffic** — the hover timer is silent when the mouse isn't moving, so zero background `page.mouse.move()` calls competing with screenshots.
2. **No shared mutable state** — keyboard events are independent (no position/button state to corrupt between concurrent calls).
3. **One-off not sustained** — a key press is a single CDP call, not 20/sec like hover. Even under full screenshot load, it finds a gap within one frame cycle (~60ms).
4. **Fire-and-forget** — even if a key event lags, nothing blocks. The command loop continues, screenshots continue, and the next key press goes through independently.

The mouse deadlock chain was always: sustained hover traffic (20 Hz) + screenshot traffic (60 Hz) = saturated pipe → any additional CDP Input call hangs → cascading failure. Keyboard-only removes the sustained part entirely. You go from ~80 CDP calls/sec (60 screenshot + 20 hover) down to ~60 (just screenshots) with occasional key presses that slip through the gaps.

The full keyboard flow: `C-n`/`C-p` to scroll, `C-c h` for Vimium-style link hints, `Tab` to cycle form fields, `C-s` to find text, `C-c l` to navigate. See [Keybindings](#keybindings) for the complete list.

## FAQ

### Does audio/video work?

**Video playback works.** Frame rate depends on `embr-fps` (default 60). YouTube may throttle unauthenticated sessions.

**Audio playback works.** Headless Chromium routes audio through PulseAudio/PipeWire.

**Mic, camera, and screen sharing do not work.** Headless Chromium has no access to input devices.

### Will you add vim-like modal keybindings (like Vimium)?

No plans to add this upstream, but PRs are welcome. If you implement it, gate it behind a `defcustom` (e.g. `embr-keymap-style` with `'default` and `'modal` options) and make sure the default behavior is unchanged. Do not break existing keybindings.

### Does this work on macOS?

Unknown. Let us know.

### Windows?

No.
