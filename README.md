# better-eww

A real web browser inside Emacs. Runs headless Firefox via Playwright, displays rendered pages as screenshots in an Emacs image buffer, and forwards clicks/keys/scroll back to Firefox. Full JS, cookies, sessions, images — the works.

## Prerequisites

- Python 3.10+
- Emacs 29.1+ (with image support)

## Installation

### Elpaca

```elisp
(use-package better-eww
  :defer t
  :ensure (:host github
           :repo "emacs-os/better-eww")
  :config
  (setq better-eww-fps 30
        better-eww-default-width 1280
        better-eww-default-height 720))
```

### straight.el

```elisp
(use-package better-eww
  :defer t
  :straight (:host github
             :repo "emacs-os/better-eww")
  :config
  (setq better-eww-fps 30
        better-eww-default-width 1280
        better-eww-default-height 720))
```

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

After installing, run `M-x better-eww-setup` to create the Python venv and download Playwright's bundled Firefox (~100MB). This only needs to be done once.

If you skip this step, `M-x better-eww-browse` will detect the missing venv and offer to run setup for you automatically.

### Management commands

| Command | Description |
|---------|-------------|
| `M-x better-eww-setup` | Install Python venv + Playwright + Firefox |
| `M-x better-eww-update` | Update Playwright and re-download Firefox |
| `M-x better-eww-uninstall` | Remove venv, browsers, and browser profile |
| `M-x better-eww-info` | Show diagnostic info about the installation |

### Where state is stored

| What | Path |
|------|------|
| Python venv | `<package-dir>/.venv/` |
| Playwright browsers | `~/.cache/ms-playwright/` |
| Cookies & sessions | `~/.local/share/better-eww/firefox-profile/` |

`M-x better-eww-uninstall` cleans up all of the above.

## Usage

```
M-x better-eww-browse RET https://example.com RET
```

## Keybindings

### Navigation mode (default)

| Key | Action |
|-----|--------|
| `g` | Go to URL (with history completion) |
| `f` | Follow link (Vimium-style hint labels) |
| `r` | Refresh |
| `B` | Back |
| `F` | Forward |
| `s` | Find in page |
| `t` | View page text in a separate buffer |
| `w` | Copy current URL to kill ring |
| `:` | Execute JavaScript |
| `q` | Quit (kills daemon and buffer) |
| `+` / `-` | Zoom in / out |
| `i` | Enter insert mode |
| Mouse click | Click at coordinates |
| Scroll wheel | Scroll page |

### Tabs

| Key | Action |
|-----|--------|
| `T` | Open new tab |
| `d` | Close current tab |
| `J` | Next tab |
| `K` | Previous tab |
| `b` | List all tabs |

### Insert mode

All keystrokes are forwarded to the browser for form input. Press `C-g` to return to navigation mode.

### Bookmarks

Standard Emacs bookmarks work: `C-x r m` to save, `C-x r b` to jump.

## How It Works

Emacs spawns a Python subprocess (`better-eww.py`) that controls headless Firefox through Playwright. They communicate via JSON lines over stdin/stdout. The daemon streams JPEG screenshots at ~30 FPS via a temp file on disk, giving live visual feedback.

Browser sessions persist across restarts — cookies and login state are stored in `~/.local/share/better-eww/firefox-profile/`.
