# better-eww

Browsers started as text renderers (Lynx, w3m, EWW). Then they became multi-gigabyte graphical platforms (Chromium, Firefox).

better-eww runs headless Firefox (~100MB, bundled by Playwright) as a backend. It screenshots the rendered page and streams pixels into an Emacs image buffer. Mouse, keyboard, and scroll events go back to Firefox. Emacs is the display server. Firefox is the renderer.

[Browsh](https://www.brow.sh/) does something similar but converts pages to text/ANSI for terminal output. better-eww keeps the pixels. Discord, Reddit, GitHub, YouTube all load and work.

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
(use-package better-eww
  :defer t
  :ensure (:host github
           :repo "emacs-os/better-eww"
           :files ("*.el" "*.py" "*.sh"))
  :config
  (setq better-eww-fps 30
        better-eww-default-width 1280
        better-eww-default-height 720
        better-eww-search-engine 'brave))
```

</td>
<td>

```elisp
(use-package better-eww
  :defer t
  :straight (:host github
             :repo "emacs-os/better-eww"
             :files ("*.el" "*.py" "*.sh"))
  :config
  (setq better-eww-fps 30
        better-eww-default-width 1280
        better-eww-default-height 720
        better-eww-search-engine 'brave))
```

</td>
</tr>
</table>

### Manual

```bash
git clone https://github.com/emacs-os/better-eww.git
cd better-eww
bash setup.sh
```

Then in your config:

```elisp
(load-file "/path/to/better-eww/better-eww.el")
```

## Setup

After installing, run `M-x better-eww-setup-or-update` to create the Python venv and download Playwright's bundled Firefox (~100MB).

If you skip this step, `M-x better-eww-browse` will detect the missing venv and offer to run setup for you automatically.

### Management commands

All management is done from Emacs, no terminal needed.

| Command | Description |
|---------|-------------|
| `M-x better-eww-setup-or-update` | Install or update venv + Playwright + Firefox (runs `setup.sh`) |
| `M-x better-eww-uninstall` | Remove venv, browsers, and browser profile (runs `uninstall.sh`) |
| `M-x better-eww-info` | Show diagnostic info about the installation |

The underlying `setup.sh` builds in a temp venv and swaps atomically, so it's always safe to re-run for both first install and updates.

### Where state is stored

| What | Path |
|------|------|
| Python venv | `<package-dir>/.venv/` |
| Playwright browsers | `~/.cache/ms-playwright/` |
| Cookies & sessions | `~/.local/share/better-eww/firefox-profile/` |

`M-x better-eww-uninstall` cleans up all of the above.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `better-eww-fps` | `30` | Target frames per second |
| `better-eww-default-width` | `1280` | Viewport width in pixels |
| `better-eww-default-height` | `720` | Viewport height in pixels |
| `better-eww-search-engine` | `'brave` | `'brave`, `'google`, `'duckduckgo`, or a custom URL string with `%s` |

## Usage

```
M-x better-eww-browse RET https://example.com RET
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
| `C-s` | Search forward (isearch-style) |
| `C-r` | Search backward (isearch-style) |
| `C-v` | Page down |
| `M-v` | Page up |
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
| `C-c b` | Back |
| `C-c f` | Forward |
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
| Scroll wheel | Scroll page |

### Bookmarks

Standard Emacs bookmarks work: `C-x r m` to save, `C-x r b` to jump.

## Ad Blocking

Built-in domain-level ad blocking using the [StevenBlack/hosts](https://github.com/StevenBlack/hosts) blocklist (~82K ad and tracker domains). Requests to blocked domains are intercepted and killed before they hit the network.

The blocklist is downloaded automatically by `setup.sh` and refreshed every time you run `M-x better-eww-setup-or-update`. No extensions or extra configuration needed.

## How It Works

Emacs spawns a Python subprocess (`better-eww.py`) that controls headless Firefox through Playwright. They communicate via JSON lines over stdin/stdout. The daemon streams JPEG screenshots at ~30 FPS via a temp file on disk, giving live visual feedback.

Browser sessions persist across restarts. Cookies and login state are stored in `~/.local/share/better-eww/firefox-profile/`.

## FAQ

### Google won't let me sign in

![Google sign-in blocked](assets/google-sign-in-blocked.png)

Google detects and blocks automated/headless browsers. This is a Google-side restriction, not a bug. Microsoft and Apple do the same.

**Workarounds:**
- Use app passwords or sign into Google in a regular browser first, then export/import cookies
- Sign in via a site that uses Google OAuth but is less strict about browser fingerprinting
- Most other sites (Discord, Reddit, GitHub, etc.) work fine

### Does audio/video work?

**Video playback works.** Frame rate depends on `better-eww-fps` (default 30). YouTube may throttle unauthenticated sessions.

**Audio playback works.** Headless Firefox routes audio through PulseAudio/PipeWire.

**Mic, camera, and screen sharing do not work.** Headless Firefox has no access to input devices.
