## embr.el
**Em**acs **Br**owser

Emacs is the display server. Headless Firefox is the renderer.

## Prerequisites

- Python 3.10+
- Emacs 29.1+ (with image support)

## Installation

<table>
<tr>
<td> <b>Elpaca</b> </td>
<td> <b>straight.el</b> </td>
</tr>
<tr>
<td>

```elisp
(use-package embr
  :defer t
  :ensure (:host github
           :repo "emacs-os/embr.el"
           :files ("*.el" "*.py" "*.sh"))
  :config
  (setq embr-fps 30                    ; Target frames per second
        embr-default-width 1280         ; Viewport width in pixels
        embr-default-height 720         ; Viewport height in pixels
        embr-search-engine 'brave       ; 'brave, 'google, 'duckduckgo, or custom URL with %s
        embr-click-method 'atomic       ; 'atomic or 'immediate (see Configuration below)
        embr-scroll-method 'default     ; 'default or 'smooth (see Configuration below)
        embr-external-command "yt-dlp -o - %s | mpv -")) ; Shell command for & key (%s = URL)
```

</td>
<td>

```elisp
(use-package embr
  :defer t
  :straight (:host github
             :repo "emacs-os/embr.el"
             :files ("*.el" "*.py" "*.sh"))
  :config
  (setq embr-fps 30                    ; Target frames per second
        embr-default-width 1280         ; Viewport width in pixels
        embr-default-height 720         ; Viewport height in pixels
        embr-search-engine 'brave       ; 'brave, 'google, 'duckduckgo, or custom URL with %s
        embr-click-method 'atomic       ; 'atomic or 'immediate (see Configuration below)
        embr-scroll-method 'default     ; 'default or 'smooth (see Configuration below)
        embr-external-command "yt-dlp -o - %s | mpv -")) ; Shell command for & key (%s = URL)
```

</td>
</tr>
</table>

## Setup

After installing, run `M-x embr-setup-or-update` to create the Python venv and download Playwright's bundled Firefox (~100MB).

If you skip this step, `M-x embr-browse` will detect the missing venv and offer to run setup for you automatically.

### Management commands

All management is done from Emacs, no terminal needed.

| Command | Description |
|---------|-------------|
| `M-x embr-setup-or-update` | Install or update venv + Playwright + Firefox + ad blocklist (runs `setup.sh`) |
| `M-x embr-uninstall` | Remove venv, browsers, and browser profile (runs `uninstall.sh`) |
| `M-x embr-info` | Show diagnostic info about the installation |

The underlying `setup.sh` builds in a temp venv and swaps atomically, so it's always safe to re-run for both first install and updates.

### Where state is stored

| What | Path |
|------|------|
| Python venv | `~/.local/share/embr/.venv/` |
| Playwright browsers | `~/.cache/ms-playwright/` |
| Cookies & sessions | `~/.local/share/embr/firefox-profile/` |

`M-x embr-uninstall` cleans up all of the above.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `embr-fps` | `30` | Target frames per second |
| `embr-default-width` | `1280` | Viewport width in pixels |
| `embr-default-height` | `720` | Viewport height in pixels |
| `embr-search-engine` | `'brave` | `'brave`, `'google`, `'duckduckgo`, or custom URL with `%s` |
| `embr-click-method` | `'atomic` | Click dispatch method (see below) |
| `embr-scroll-method` | `'default` | Scroll behavior (see below) |
| `embr-external-command` | `"yt-dlp -o - %s \| mpv -"` | Shell command for `&` key (`%s` = URL). e.g. `"mpv %s"`, `"chromium %s"` |

### Click methods

| Method | Behavior |
|--------|----------|
| `'atomic` | Defers mousedown until drag is detected. Simple clicks use Playwright's atomic `page.mouse.click()`. Better compatibility with iframe widgets. |
| `'immediate` | Sends mousedown instantly on press, mouseup on release. Useful for sites that rely on press-and-hold interactions. |

### Scroll methods

| Method | Behavior |
|--------|----------|
| `'default` | 100px instant scroll per wheel tick. Choppy, line-by-line feel. |
| `'smooth` | 300px smooth-animated scroll per wheel tick. |

## Usage

```
M-x embr-browse RET https://example.com RET
```

## Keybindings

All keys are forwarded directly to the browser. Typing, arrows, backspace, tab, and enter work as expected. `C-x`, `M-x`, etc. stay free for Emacs.

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
| `F8` | Cycle viewport: iPhone → 720p → 1080p (Emacs handles up to 1080p well, higher loses perf) |
| `C-x` | Emacs prefix (not forwarded) |
| `M-x` | Emacs command (not forwarded) |
| `C-c` | Browser command prefix (see below) |

### Browser commands

Browser commands use the `C-c` prefix.

| Key | Action |
|-----|--------|
| `C-c l` | Go to URL or search (same as `C-l`) |
| `C-c h` | Follow link (Vimium-style hint labels) |
| `C-c r` | Refresh |
| `C-c b` / `C-c C-b` | Back |
| `C-c f` / `C-c C-f` | Forward |
| `C-c s` | Search forward (same as `C-s`) |
| `C-c t` | View page text in a separate buffer |
| `C-c w` | Copy current URL to kill ring |
| `C-c :` | Execute JavaScript |
| `C-c q` | Quit (kills daemon and buffer) |
| `C-c +` / `C-c -` | Zoom in / out |
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

Built-in domain-level ad blocking using the [StevenBlack/hosts](https://github.com/StevenBlack/hosts) blocklist (~82K ad and tracker domains). Requests to blocked domains are intercepted and killed before they hit the network.

The blocklist is downloaded automatically by `setup.sh` and refreshed every time you run `M-x embr-setup-or-update`. No extensions or extra configuration needed.

## How It Works

Emacs spawns a Python subprocess (`embr.py`) that controls headless Firefox through Playwright. They communicate via JSON lines over stdin/stdout. The daemon streams JPEG screenshots at ~30 FPS via a temp file on disk, giving live visual feedback.

Browser sessions persist across restarts. Cookies and login state are stored in `~/.local/share/embr/firefox-profile/`.

## FAQ

### Google won't let me sign in

![Google sign-in blocked](assets/google-sign-in-blocked.png)

Google detects and blocks automated/headless browsers. This is a Google-side restriction, not a bug.

### Cloudflare "Verify you are human" doesn't work

Cloudflare Turnstile detects and blocks headless/automated browsers. The checkbox will not respond regardless of click method. This is a Cloudflare-side restriction, not a bug.

### Does audio/video work?

**Video playback works.** Frame rate depends on `embr-fps` (default 30). YouTube may throttle unauthenticated sessions.

**Audio playback works.** Headless Firefox routes audio through PulseAudio/PipeWire.

**Mic, camera, and screen sharing do not work.** Headless Firefox has no access to input devices.

### YouTube videos error after a few minutes

YouTube detects the headless browser and kills playback. Press `&` to play the video through yt-dlp + mpv instead — it bypasses detection entirely and gives better quality since mpv gets the direct video stream.
