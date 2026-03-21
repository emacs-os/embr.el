## embr.el
**Em**acs **Br**owser

Emacs is the display server. Headless Chromium via [CloakBrowser](https://cloakbrowser.dev) is the renderer. Frame transport uses CDP screencast. Emacs canvas (optional) is also supported for added performance. If you build Emacs with the [canvas patch](https://github.com/minad/emacs-canvas-patch) (see [./canvasmacs](./canvasmacs)), embr renders frames directly to a pixel buffer via a native C module, skipping the per-frame disk round-trip.

![embr screenshot](assets/screenshot.png)

## Prerequisites

- Python 3.10+
- Emacs 30.1+

## Installation

**Elpaca**

```elisp
(use-package embr
  :defer t
  :ensure (:host github
           :repo "emacs-os/embr.el"
           :files ("*.el" "*.py" "*.sh" "native/*.c" "native/Makefile"))
  :config
  (setq embr-hover-rate 30
        embr-default-width 1280
        embr-default-height 720
        embr-screen-width 1920
        embr-screen-height 1080
        embr-color-scheme 'dark
        embr-search-engine 'google
        embr-scroll-method 'instant
        embr-scroll-step 100
        embr-frame-source 'screencast
        embr-render-backend 'default
        embr-display-method 'headless))
```

**straight.el**

```elisp
(use-package embr
  :defer t
  :straight (:host github
             :repo "emacs-os/embr.el"
             :files ("*.el" "*.py" "*.sh" "native/*.c" "native/Makefile"))
  :config
  (setq embr-hover-rate 30
        embr-default-width 1280
        embr-default-height 720
        embr-screen-width 1920
        embr-screen-height 1080
        embr-color-scheme 'dark
        embr-search-engine 'google
        embr-scroll-method 'instant
        embr-scroll-step 100
        embr-frame-source 'screencast
        embr-render-backend 'default
        embr-display-method 'headless))
```

**Tip:** Of all the settings available, `embr-hover-rate` is the most mystifying. Higher values (e.g. 60) give lower-latency hover and can help with finicky buttons. Lower values (e.g. 20) reduce CDP traffic and may improve click reliability on slower machines. Setting this too high risks input lockups. Worth fiddling with.

**Tip:** Make embr your default Emacs browser and enable clickable URLs everywhere:

```elisp
(setq browse-url-browser-function 'embr-browse)
(global-goto-address-mode 1)
```

## Setup

After installing, run `M-x embr-setup-or-update-all` to create the Python venv and download CloakBrowser.

If you skip this step, `M-x embr-browse` will detect the missing venv and offer to run setup for you automatically.

### Management commands

All management is done from Emacs, no terminal needed.

| Command | Description |
|---------|-------------|
| `M-x embr-setup-or-update-all` | Install or update CloakBrowser + ad blocklist + uBlock Origin (runs `setup.sh --all`) |
| `M-x embr-update-blocklist` | Update the ad/tracker domain blocklist |
| `M-x embr-update-ublock` | Update uBlock Origin to the latest release |
| `M-x embr-uninstall` | Remove venv and browser profile. Optionally delete browser cache (runs `uninstall.sh`). |
| `M-x embr-info` | Show diagnostic info about the installation |

The underlying `setup.sh` builds in a temp venv and swaps atomically, so it's always safe to re-run for both first install and updates.

### Where state is stored

| What | Path (0.40+) | Path (0.30) |
|------|--------------|-------------|
| Python venv | `~/.local/share/embr/.venv/` | same |
| Browser binary | `~/.cloakbrowser/` | `~/.cache/camoufox/` |
| Cookies & sessions | `~/.local/share/embr/chromium-profile/` | `~/.local/share/embr/firefox-profile/` |

`M-x embr-uninstall` removes the venv and profile. Browser cache deletion is offered as an optional prompt.

## Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `embr-python` | file | `~/.local/share/embr/.venv/bin/python` | Path to Python interpreter in the embr venv. |
| `embr-script` | file | `embr.py` in package dir | Path to the embr.py daemon script. |
| `embr-hover-rate` | integer | `30` | Mouse hover tracking rate in Hz. Higher values (e.g. 60) give lower-latency hover and can help with finicky buttons. Lower values (e.g. 20) reduce CDP traffic and may improve click reliability on slower machines. Setting this too high risks input lockups. |
| `embr-default-width` | integer | `1280` | Viewport width in pixels |
| `embr-default-height` | integer | `720` | Viewport height in pixels |
| `embr-screen-width` | integer | `1920` | Screen width reported to websites (should be >= viewport) |
| `embr-screen-height` | integer | `1080` | Screen height reported to websites (should be >= viewport) |
| `embr-color-scheme` | symbol/nil | `'dark` | `'dark`, `'light`, or `nil` to let CloakBrowser choose. Controls `prefers-color-scheme`. |
| `embr-search-engine` | symbol/string | `'google` | `'google`, `'brave`, `'duckduckgo`, or custom URL with `%s` |
| `embr-click-method` | symbol | `'immediate` | `'atomic` defers mousedown until drag detected, better iframe compat. `'immediate` sends mousedown instantly, for press-and-hold sites. |
| `embr-scroll-method` | symbol | `'instant` | `'instant` scrolls instantly. `'smooth` scrolls with CSS animation. |
| `embr-scroll-step` | integer | `100` | Scroll distance in pixels per wheel notch |
| `embr-dom-caret-hack` | boolean | `t` | Inject a fake DOM caret in focused text fields. CDP screenshots don't capture the native caret. |
| `embr-perf-log` | boolean | `nil` | Write JSONL perf events to `/tmp/embr-perf.jsonl`. Analyze with `tools/embr-perf-report.py`. |
| `embr-hover-move-threshold-px` | integer | `0` | Minimum pixel distance before sending a hover update. Filters sub-pixel jitter. |
| `embr-external-command` | string | yt-dlp + mpv | Shell command for `&` key (`%s` = URL). Default pipes through yt-dlp into mpv. |
| `embr-frame-source` | symbol | `'screencast` | `'screencast` uses CDP screencast (recommended). `'screenshot` uses polling only. |
| `embr-render-backend` | symbol | `'default` | `'default` uses JPEG file + create-image. `'canvas` requires canvas-patched Emacs + native module. |
| `embr-display-method` | symbol | `'headless` | `'headless` (no window, no audio), `'headed` (visible window, audio), `'headed-offscreen` (hidden window via Xvfb, audio). |


## Usage

```
M-x embr-browse RET example.com RET
```

## Keybindings

All keys are forwarded directly to the browser. Typing, arrows, backspace, tab, and enter work as expected. `C-x`, `M-x`, etc. stay free for Emacs.

The top-level keybindings below translate familiar Emacs motion keys into their browser equivalents. If you're familiar with EXWM, same concept as simulation keys.

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

Browser commands use the `C-c` prefix. Eww-inspired commands, just behind a prefix instead of on top-level keys. This gives a more natural browser typing experience while keeping power tools a combo away.

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

Two layers of ad blocking are available. Running `M-x embr-setup-or-update-all` periodically keeps everything up to date. You can also update each layer individually with `M-x embr-update-blocklist` or `M-x embr-update-ublock`.

**Domain-level blocklist** (built in). The [StevenBlack/hosts](https://github.com/StevenBlack/hosts) list (~82K ad and tracker domains) intercepts and kills requests to blocked domains before they hit the network.

### uBlock Origin (optional)

For ad blocking beyond domain-level, you can install [uBlock Origin](https://github.com/gorhill/uBlock) as a Chromium extension. `M-x embr-setup-or-update-all` downloads the latest release for you. You just need to enable it once in headed mode (headless Chromium does not support extensions).

1. **Install Xvfb** (if you don't have it, needed for `headed-offscreen` mode):

   ```sh
   # Arch
   sudo pacman -S xorg-server-xvfb
   # Debian/Ubuntu
   sudo apt install xvfb
   # Fedora
   sudo dnf install xorg-x11-server-Xvfb
   ```

2. **Switch to headed mode** so you can see the browser:

   ```elisp
   (setq embr-display-method 'headed)
   ```

3. **Enable the extension.** Navigate to `chrome://extensions`, turn on **Developer mode** (top-right toggle), and enable uBlock Origin if it is not already active. (PR accepted if you find a way to automate this in our `embr.py`.)

4. **Switch to headed-offscreen** and restart embr. The extension persists in your browser profile across restarts.

   ```elisp
   (setq embr-display-method 'headed-offscreen)
   ```


## FAQ

### Does audio/video work?

**Video playback works.**

**Audio playback works.** Headless Chromium routes audio through PulseAudio/PipeWire.

**Mic, camera, and screen sharing do not work.**

### Will you add vim-like modal keybindings (like Vimium)?

No plans to add this upstream, but PRs are welcome. If you implement it, gate it behind a `defcustom` (e.g. `embr-keymap-style` with `'default` and `'modal` options) and make sure the default behavior is unchanged. Do not break existing keybindings.

### Does this work on macOS?

Unknown. Let us know.

### Windows?

No.
