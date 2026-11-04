;;; embr.el --- Browse the web with headless Chromium in Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 emacs-os

;; Author: emacs-os
;; Package-Requires: ((emacs "30.1"))
;; Keywords: web, browser, hypermedia
;; URL: https://github.com/emacs-os/embr.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; embr runs headless Chromium and displays frames in an Emacs buffer.
;; Clicks, keystrokes, and scroll events are forwarded to the browser.
;; Two browser engines are supported: CloakBrowser (default,
;; anti-fingerprinting) and vanilla Playwright Chromium.  Frames are
;; delivered via CDP screencast.  On Emacs 32 and newer they are
;; blitted straight into a native canvas pixel buffer over a Unix
;; socket; older Emacs falls back to a JPEG file per frame.
;;
;; The Python daemon (`embr.py') controls the browser through
;; Playwright.  Communication uses JSON lines over stdin/stdout,
;; serialized with Emacs 30.1's native C JSON (`json-serialize').

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'shr)
(require 'transient)

;; `image-flush' is a primitive that exists only in Emacs builds with
;; window-system support; declare it so a terminal-only build compiles.
(declare-function image-flush "image.c" (spec &optional frame))
;; Built-in SQLite support (Emacs 29+, when compiled in).
(declare-function sqlite-available-p "sqlite.c")
(declare-function sqlite-open "sqlite.c" (&optional file))
(declare-function sqlite-select "sqlite.c" (db query &optional values return-type))
(declare-function sqlite-close "sqlite.c" (db))

;; ── Customization ──────────────────────────────────────────────────

(defgroup embr nil
  "Headless Chromium browser for Emacs."
  :group 'web
  :prefix "embr-")

(defvar embr--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory where embr package files live.
With :files in the package recipe, Elpaca/straight symlink .py and .sh
alongside the .el in the builds dir, so this just works.")

(defvar embr--data-dir
  (expand-file-name "embr" (or (getenv "XDG_DATA_HOME")
                                      (expand-file-name ".local/share" "~")))
  "Directory for persistent embr data (~/.local/share/embr/).")

(defcustom embr-python
  (expand-file-name ".venv/bin/python" embr--data-dir)
  "Path to the Python interpreter inside the project venv."
  :type 'file)

(defcustom embr-script
  (expand-file-name "embr.py" embr--directory)
  "Path to the embr Python daemon script."
  :type 'file)

(defcustom embr-browser-engine 'cloakbrowser
  "Browser engine to use.
`cloakbrowser' uses CloakBrowser (anti-fingerprinting Chromium).
`chromium' uses vanilla Playwright Chromium."
  :type '(choice (const :tag "CloakBrowser" cloakbrowser)
                 (const :tag "Chromium (Playwright)" chromium)))

(defcustom embr-viewport-sizing 'dynamic
  "How the browser viewport dimensions are determined.

`dynamic' derives viewport size from the Emacs window pixel
dimensions and resizes automatically when the window changes.
Pair with `display-pixel-width' and `display-pixel-height' for
accurate screen reporting:

  (setq embr-viewport-sizing \\='dynamic
        embr-screen-width (display-pixel-width)
        embr-screen-height (display-pixel-height))

`fixed' uses `embr-default-width' and `embr-default-height' with
hardcoded screen dimensions for a uniform browser fingerprint:

  (setq embr-viewport-sizing \\='fixed
        embr-default-width 1280
        embr-default-height 720
        embr-screen-width 1920
        embr-screen-height 1080)"
  :type '(choice (const :tag "Fixed" fixed)
                 (const :tag "Dynamic (match window)" dynamic)))

(defcustom embr-default-width 1280
  "Default viewport width in pixels.
Only effective when `embr-viewport-sizing' is `fixed', or as a
fallback when the window is not yet visible in `dynamic' mode."
  :type 'integer)

(defcustom embr-default-height 720
  "Default viewport height in pixels.
Only effective when `embr-viewport-sizing' is `fixed', or as a
fallback when the window is not yet visible in `dynamic' mode."
  :type 'integer)

(defcustom embr-screen-width 1920
  "Screen width reported to websites.
Should be >= viewport width.  Set to your monitor resolution for a
realistic browser fingerprint."
  :type 'integer)

(defcustom embr-screen-height 1080
  "Screen height reported to websites.
Should be >= viewport height.  Set to your monitor resolution for a
realistic browser fingerprint."
  :type 'integer)

(defcustom embr-fps 60
  "Target frame rate in Hz.
Caps how often frames are delivered and rendered.  With the
screencast source it throttles the frames the browser pushes; with
the screenshot source it is the polling rate."
  :type 'integer)

(defcustom embr-jpeg-quality 80
  "JPEG quality (1-100) for frame captures.
Used by both screencast and screenshot frame sources.
Lower values encode faster but degrade image quality."
  :type 'integer)

(defcustom embr-hover-rate 30
  "Mouse hover tracking rate in Hz."
  :type 'integer)

(defcustom embr-external-command "yt-dlp -o - %s | mpv -"
  "Shell command for `embr-play-external'.
%s is replaced with the current page URL (shell-quoted).
Examples:
  \"yt-dlp -o - %s | mpv -\"
    stream via yt-dlp into mpv (default)
  \"yt-dlp --cookies-from-browser
    chromium:~/.local/share/embr/chromium-profile
    -o - %s | mpv -\"
    same but with embr's cookies (age-restricted)
  \"mpv %s\"       open directly in mpv
  \"chromium %s\"  open in Chromium"
  :type 'string)

(defcustom embr-click-method 'immediate
  "How mouse clicks are sent to the browser.
`atomic' defers mousedown until drag is detected and uses Playwright's
atomic click for simple clicks — better compatibility with iframe widgets.
`immediate' sends mousedown instantly on press, mouseup on release.
Useful for sites that rely on press-and-hold interactions."
  :type '(choice (const :tag "Atomic (single click call)" atomic)
                 (const :tag "Immediate (mousedown/mouseup)" immediate)))

(defcustom embr-scroll-method 'instant
  "How scrolling behaves.
`instant' scrolls instantly.
`smooth' scrolls with CSS smooth behavior."
  :type '(choice (const :tag "Smooth" smooth)
                 (const :tag "Instant" instant)))

(defcustom embr-scroll-step 100
  "Scroll distance in pixels per wheel notch."
  :type 'integer)


(defcustom embr-color-scheme 'dark
  "Browser color scheme preference.
Controls `prefers-color-scheme' CSS media query.  Set to nil to let
the browser choose (CloakBrowser uses its fingerprint profile)."
  :type '(choice (const :tag "Dark" dark)
                 (const :tag "Light" light)
                 (const :tag "Auto (browser default)" nil)))

(defcustom embr-dom-caret-hack nil
  "Whether to inject a fake DOM caret in focused text fields.
Only needed with the screenshot transport.  Screencast captures
the native caret, so this defaults to nil."
  :type 'boolean)

(defcustom embr-download-directory "~/Downloads/"
  "Directory where downloaded files are saved."
  :type 'directory)


(defcustom embr-href-preview-hack t
  "Whether to inject a link preview overlay on hover.
Injects a DOM element at the bottom of the page that shows the
URL of hovered links, like a browser status bar."
  :type 'boolean)

(defcustom embr-search-engine 'google
  "Search engine for URL bar queries.
Can be a symbol (`brave', `google', `duckduckgo', `bing', `yandex',
`baidu'), a custom URL string with %s for the query, or a function
that takes a query string argument.  When set to a function, non-URL
input is passed to it instead of navigating the browser."
  :type '(choice (const :tag "Brave" brave)
                 (const :tag "Google" google)
                 (const :tag "DuckDuckGo" duckduckgo)
                 (const :tag "Bing" bing)
                 (const :tag "Yandex" yandex)
                 (const :tag "Baidu" baidu)
                 (string :tag "Custom URL (use %s for query)")
                 (function :tag "Custom function (takes query string)")))

(defcustom embr-search-prefix nil
  "String prepended to queries passed to a function search engine.
Only used when `embr-search-engine' is a function.  Set this to
inject a system prompt or context before the user's query."
  :type '(choice (const :tag "None" nil)
                 (string :tag "Prefix string")))

(defcustom embr-perf-log nil
  "Whether to enable performance logging in the daemon.
When non-nil, the daemon writes JSONL performance events to
/tmp/embr-perf.jsonl for analysis with tools/embr-perf-report.py."
  :type 'boolean)

(defcustom embr-input-priority-window-ms 35
  "Deprecated. Screenshot-only. Milliseconds to suppress captures after input."
  :type 'integer)

(defcustom embr-adaptive-capture nil
  "Deprecated. Screenshot-only. Auto-tune FPS and JPEG quality."
  :type 'boolean)

(defcustom embr-adaptive-fps-min 40
  "Deprecated. Screenshot-only. Minimum FPS for adaptive controller."
  :type 'integer)

(defcustom embr-adaptive-jpeg-quality-min 65
  "Deprecated. Screenshot-only. Minimum JPEG quality for adaptive controller."
  :type 'integer)

(defcustom embr-frame-source 'screencast
  "How frames are captured from the browser.
`screencast' uses CDP screencast (recommended).
`screenshot' uses the original screenshot polling loop."
  :type '(choice (const :tag "Screencast (recommended)" screencast)
                 (const :tag "Screenshot polling" screenshot)))

(defcustom embr-hover-move-threshold-px 0
  "Minimum pixel distance before sending a hover update.
Filters out sub-pixel jitter.  Higher values reduce CDP traffic
at the cost of hover precision."
  :type 'integer)

(defcustom embr-hover-rate-min 14
  "Hover tracking rate in Hz used briefly after keyboard or mouse input.
The daemon reports pressure during the input-priority window that
follows a key press or click; hover updates slow to this rate until
the window ends."
  :type 'integer)

(defcustom embr-render-backend 'auto
  "Render backend for frame display.
`auto' uses the native canvas pixel path when the running Emacs has
native canvas images (Emacs 32 and newer) and the embr-canvas module
builds and loads, and otherwise falls back to the JPEG file +
`create-image' path, which works on any Emacs.
`default' behaves exactly like `auto', so existing configurations that
set it get native canvas automatically when it is available.
`canvas' requires the native canvas path and signals an error when it
is not available."
  :type '(choice (const :tag "Auto (canvas when available)" auto)
                 (const :tag "Canvas (requires Emacs 32+)" canvas)
                 (const :tag "Default (same as auto)" default)))

(defcustom embr-display-method 'headless
  "How the browser display is managed.
`headless' runs without a window.
`headed' runs with a visible window (requires Xvfb).
`headed-offscreen' runs with a hidden window (requires Xvfb)."
  :type '(choice (const :tag "Headless" headless)
                 (const :tag "Headed (requires Xvfb)" headed)
                 (const :tag "Headed offscreen (requires Xvfb)" headed-offscreen)))

(defcustom embr-dispatch-key "C-c"
  "Key that opens the transient dispatch menu.
Must be set before embr is loaded."
  :type 'string)

(defcustom embr-vimium-leader "SPC"
  "Key that opens the dispatch menu in vimium normal mode."
  :type 'string)

(defcustom embr-vimium-start-in-normal t
  "Non-nil means start in normal mode when `embr-vimium-mode' is enabled."
  :type 'boolean)

(defcustom embr-tab-bar t
  "Non-nil means show a clickable tab bar above the page."
  :type 'boolean)

(defcustom embr-home-url "about:blank"
  "URL to navigate to when embr is launched interactively.
Only used when `embr-session-restore' is nil or there is no saved
session.  When a session is restored, the saved tabs are opened
instead."
  :type 'string)

(defcustom embr-session-restore t
  "Non-nil means save and restore open tabs across sessions.
On quit, tab URLs are saved to a file.  On next launch, tabs are
reopened automatically."
  :type 'boolean)

(defcustom embr-proxy-rules nil
  "Per-domain proxy routing rules.
Each entry is (SUFFIX TYPE ADDRESS).  SUFFIX is a domain suffix
like \".onion\" or an exact hostname like \"example.com\".  Use
\"*\" as a catch-all.  TYPE is `http' or `socks5'.  ADDRESS is
\"host:port\".  Domains not matching any rule go direct.

Example:
  \\='((\".onion\" socks5 \"127.0.0.1:9050\") ; Tor
    (\".i2p\"   http   \"127.0.0.1:4444\") ; I2P
    ;; (\"*\"   socks5 \"127.0.0.1:9050\") ; everything through Tor
    )"
  :type '(repeat (list (string :tag "Domain suffix")
                       (choice (const :tag "SOCKS5" socks5)
                               (const :tag "HTTP" http))
                       (string :tag "host:port")))
  :group 'embr)

(defface embr-tab-bar
  '((t :inherit header-line))
  "Face for the tab bar background."
  :group 'embr)

(defface embr-tab-active
  '((t :inherit mode-line :weight bold))
  "Face for the active tab label."
  :group 'embr)

(defface embr-tab-inactive
  '((t :inherit mode-line-inactive))
  "Face for inactive tab labels."
  :group 'embr)

(defface embr-tab-close
  '((t :inherit mode-line-inactive))
  "Face for the tab close button."
  :group 'embr)

(defun embr--search-url (query)
  "Build a search URL for QUERY using `embr-search-engine'.
Return a URL string.  If `embr-search-engine' is a function, call it
with QUERY and return nil."
  (if (functionp embr-search-engine)
      (progn
        (funcall embr-search-engine
                 (if embr-search-prefix
                     (concat embr-search-prefix query)
                   query))
        nil)
    (let ((template (pcase embr-search-engine
                      ('brave "https://search.brave.com/search?q=%s")
                      ('google "https://www.google.com/search?q=%s")
                      ('duckduckgo "https://duckduckgo.com/?q=%s")
                      ('bing "https://www.bing.com/search?q=%s")
                      ('yandex "https://yandex.com/search/?text=%s")
                      ('baidu "https://www.baidu.com/s?wd=%s")
                      ((pred stringp) embr-search-engine))))
      (format template (url-hexify-string query)))))

;; ── Setup & management ─────────────────────────────────────────────

(defun embr--setup-needed-p ()
  "Return non-nil if setup is needed for the configured browser engine.
Checks that the venv Python exists and the engine package and browser
binary are installed."
  (or (not (file-exists-p embr-python))
      (pcase embr-browser-engine
        ('cloakbrowser
         (not (zerop (call-process embr-python nil nil nil
                                   "-c" "import cloakbrowser"))))
        ('chromium
         (not (zerop
               (call-process
                embr-python nil nil nil "-c"
                "import os; from playwright.sync_api import sync_playwright; b = sync_playwright().start(); p = b.chromium.executable_path; b.stop(); assert os.path.isfile(p)"))))
        (_ t))))

(defun embr--run-setup (args msg)
  "Run setup.sh with ARGS and display MSG on completion."
  (let ((setup-script (expand-file-name "setup.sh" embr--directory)))
    (unless (file-exists-p setup-script)
      (error "embr: setup.sh not found in %s" embr--directory))
    (let ((buf (get-buffer-create "*embr-setup*")))
      (with-current-buffer buf (erase-buffer))
      (pop-to-buffer buf)
      (insert (format "Running setup.sh %s ...\n\n" (string-join args " ")))
      (let ((proc (apply #'start-process "embr-setup" buf
                          "bash" setup-script args)))
        (set-process-sentinel
         proc
         (lambda (proc event)
           (when (and (not (process-live-p proc))
                      (buffer-live-p buf))
             (with-current-buffer buf
               (goto-char (point-max))
               (insert (if (string-match-p "finished" event)
                           (format "\n%s\n" msg)
                         (format "\nembr: setup.sh %s failed: %s\n"
                                 (string-join args " ")
                                 (string-trim event))))))))))))

;;;###autoload
(defun embr-install-or-update-cloakbrowser ()
  "Install or update the Python venv and CloakBrowser binary."
  (interactive)
  (embr--run-setup '("--cloakbrowser") "Done. You can now run M-x embr-browse."))

;;;###autoload
(defun embr-install-or-update-chromium ()
  "Install or update the Python venv and Playwright Chromium binary."
  (interactive)
  (embr--run-setup '("--chromium") "Done. You can now run M-x embr-browse."))

;;;###autoload
(defun embr-install-or-update-blocklist ()
  "Install or update the ad/tracker domain blocklist."
  (interactive)
  (embr--run-setup '("--blocklist") "Blocklist installed/updated."))

;;;###autoload
(defun embr-install-or-update-ublock ()
  "Install or update uBlock Origin to the latest release.
Note: uBlock Origin requires one-time manual setup in headed mode.
See README.md for instructions."
  (interactive)
  (when (eq embr-browser-engine 'chromium)
    (user-error "embr: sideloaded extensions are not compatible with the chromium engine.  Install uBlock Origin from the Chrome Web Store in headed mode instead"))
  (embr--run-setup '("--ublock") "uBlock Origin installed/updated."))

;;;###autoload
(defun embr-install-or-update-darkreader ()
  "Install or update Dark Reader to the latest release.
Like uBlock Origin, requires one-time manual enable in headed mode
via chrome://extensions."
  (interactive)
  (when (eq embr-browser-engine 'chromium)
    (user-error "embr: sideloaded extensions are not compatible with the chromium engine.  Install Dark Reader from the Chrome Web Store in headed mode instead"))
  (embr--run-setup '("--darkreader") "Dark Reader installed/updated."))

;; Safety measures for management delete operations:
;;
;; 1. Hardcoded defconst paths -- not derived from any runtime variable.
;; 2. Sanity check on entry -- verifies the target string starts with the
;;    hardcoded base before doing anything.
;; 3. Per-path check -- every expanded path is re-verified to be inside
;;    the allowed base before deletion, refuses with error if not.
;; 4. Pure Elisp -- no shell subprocess.

(defconst embr--data-dir-prefix
  (file-name-as-directory embr--data-dir)
  "Base directory for embr data deletion safety checks.
Fixed at load time from $XDG_DATA_HOME, the same location `setup.sh'
and `embr.py' use, so the management commands act on the files that
were actually installed.  Every delete verifies its target lies
inside this directory and `embr--data-dir-sane-p' verifies the
directory itself.")

(defun embr--data-dir-sane-p (dir)
  "Return non-nil if DIR is an absolute directory whose last component is embr.
Guards the delete commands against a misconfigured data directory such
as \"/\" or the home directory."
  (and (stringp dir)
       (file-name-absolute-p dir)
       (string-suffix-p "/embr/" (file-name-as-directory dir))))

(defconst embr--browsers-dir
  (expand-file-name "~/.cloakbrowser/")
  "Hardcoded path to CloakBrowser's browser cache.")

(defconst embr--playwright-browsers-dir
  (expand-file-name "~/.cache/ms-playwright/")
  "Hardcoded path to Playwright's browser cache.")

(defun embr--safe-delete (path allowed-prefix description)
  "Delete PATH if it is inside ALLOWED-PREFIX.
Verifies the expanded PATH starts with ALLOWED-PREFIX before
deletion.  DESCRIPTION is used in messages."
  (let ((expanded (expand-file-name path)))
    (unless (string-prefix-p allowed-prefix expanded)
      (error "embr: refusing to delete outside %s: %s"
             allowed-prefix expanded))
    (if (file-directory-p expanded)
        (delete-directory expanded t)
      (delete-file expanded))
    (message "embr: %s removed" description)))

;;;###autoload
(defun embr-remove-ublock ()
  "Remove uBlock Origin extension."
  (interactive)
  (let ((dir (expand-file-name "extensions/ublock/"
                                embr--data-dir-prefix)))
    (unless (string-prefix-p embr--data-dir-prefix dir)
      (error "embr: path sanity check failed"))
    (if (file-directory-p dir)
        (when (y-or-n-p "Remove uBlock Origin? ")
          (embr--safe-delete dir embr--data-dir-prefix "uBlock Origin"))
      (message "embr: uBlock Origin not installed"))))

;;;###autoload
(defun embr-remove-darkreader ()
  "Remove Dark Reader extension."
  (interactive)
  (let ((dir (expand-file-name "extensions/darkreader/"
                                embr--data-dir-prefix)))
    (unless (string-prefix-p embr--data-dir-prefix dir)
      (error "embr: path sanity check failed"))
    (if (file-directory-p dir)
        (when (y-or-n-p "Remove Dark Reader? ")
          (embr--safe-delete dir embr--data-dir-prefix "Dark Reader"))
      (message "embr: Dark Reader not installed"))))

;;;###autoload
(defun embr-remove-blocklist ()
  "Remove the ad/tracker domain blocklist."
  (interactive)
  (let ((file (expand-file-name "blocklist.txt"
                                 embr--data-dir-prefix)))
    (unless (string-prefix-p embr--data-dir-prefix file)
      (error "embr: path sanity check failed"))
    (if (file-exists-p file)
        (when (y-or-n-p "Remove ad blocklist? ")
          (embr--safe-delete file embr--data-dir-prefix "ad blocklist"))
      (message "embr: blocklist not installed"))))

;;;###autoload
(defun embr-remove-profiles ()
  "Remove browser profiles for both engines.
Deletes chromium-profile/ and playwright-profile/ inside
~/.local/share/embr/.  Useful for clearing stale extension state
or starting fresh.  Does not remove extensions, venv, or browser
binaries."
  (interactive)
  (when (embr--profile-in-use-p)
    (user-error "embr: quit the browser first; it holds the profile open"))
  (let ((cb-profile (expand-file-name "chromium-profile/"
                                       embr--data-dir-prefix))
        (pw-profile (expand-file-name "playwright-profile/"
                                       embr--data-dir-prefix))
        (removed nil))
    (unless (string-prefix-p embr--data-dir-prefix cb-profile)
      (error "embr: CloakBrowser profile path sanity check failed"))
    (unless (string-prefix-p embr--data-dir-prefix pw-profile)
      (error "embr: Playwright profile path sanity check failed"))
    (let ((cb-exists (file-directory-p cb-profile))
          (pw-exists (file-directory-p pw-profile)))
      (unless (or cb-exists pw-exists)
        (user-error "embr: no profiles to remove"))
      (when (yes-or-no-p
             (format "Remove browser profiles? This deletes cookies, sessions, and extension state.%s%s "
                     (if cb-exists
                         (format "\n  %s" cb-profile) "")
                     (if pw-exists
                         (format "\n  %s" pw-profile) "")))
        (when cb-exists
          (embr--safe-delete cb-profile embr--data-dir-prefix
                             "CloakBrowser profile")
          (push "CloakBrowser" removed))
        (when pw-exists
          (embr--safe-delete pw-profile embr--data-dir-prefix
                             "Playwright profile")
          (push "Playwright" removed))
        (message "embr: removed %s profile(s)"
                 (string-join (nreverse removed) " and "))))))

(defvar embr--url-history)

;;;###autoload
(defun embr-uninstall ()
  "Remove everything: venv, profile, extensions, browser caches.
Deletes the embr data directory (~/.local/share/embr/ or
$XDG_DATA_HOME/embr/), ~/.cloakbrowser/, and ~/.cache/ms-playwright/
entirely.
Does not remove the Emacs package itself."
  (interactive)
  (unless (embr--data-dir-sane-p embr--data-dir-prefix)
    (error "embr: data dir sanity check failed"))
  (unless (and (stringp embr--browsers-dir)
               (string-prefix-p (expand-file-name "~/.cloakbrowser/")
                                embr--browsers-dir))
    (error "embr: CloakBrowser dir sanity check failed"))
  (unless (and (stringp embr--playwright-browsers-dir)
               (string-prefix-p (expand-file-name "~/.cache/ms-playwright/")
                                embr--playwright-browsers-dir))
    (error "embr: Playwright dir sanity check failed"))
  (when (yes-or-no-p
         "Remove ALL embr data (~/.local/share/embr/, ~/.cloakbrowser/, ~/.cache/ms-playwright/)? ")
    (when (file-directory-p embr--data-dir-prefix)
      (delete-directory embr--data-dir-prefix t))
    (when (file-directory-p embr--browsers-dir)
      (delete-directory embr--browsers-dir t))
    (when (file-directory-p embr--playwright-browsers-dir)
      (delete-directory embr--playwright-browsers-dir t))
    (setq embr--url-history nil)
    (message "embr: removed %s, %s, and %s"
             embr--data-dir-prefix embr--browsers-dir
             embr--playwright-browsers-dir)))

;;;###autoload
(defun embr-info ()
  "Show diagnostic info about the embr installation."
  (interactive)
  (let ((venv-dir (expand-file-name ".venv" embr--data-dir))
        (cb-dir (expand-file-name ".cloakbrowser" "~"))
        (pw-dir (expand-file-name ".cache/ms-playwright" "~"))
        (cb-profile (expand-file-name "chromium-profile" embr--data-dir))
        (pw-profile (expand-file-name "playwright-profile" embr--data-dir))
        (blocklist (expand-file-name "blocklist.txt" embr--data-dir))
        (ublock-dir (expand-file-name "extensions/ublock" embr--data-dir))
        (darkreader-dir (expand-file-name "extensions/darkreader" embr--data-dir)))
    (message "embr installation:
  Engine:     %s
  Source:     %s
  Python:     %s (%s)
  Script:     %s (%s)
  Venv:       %s (%s)
  CloakBrowser: %s (%s)
  Playwright: %s (%s)
  CB Profile: %s (%s)
  PW Profile: %s (%s)
  Blocklist:  %s
  uBlock:     %s
  Dark Reader:%s
  Setup needed: %s"
             embr-browser-engine
             embr--directory
             embr-python (if (file-exists-p embr-python) "OK" "MISSING")
             embr-script (if (file-exists-p embr-script) "OK" "MISSING")
             venv-dir (if (file-directory-p venv-dir) "OK" "MISSING")
             cb-dir (if (file-directory-p cb-dir) "OK" "not installed")
             pw-dir (if (file-directory-p pw-dir) "OK" "not installed")
             cb-profile (if (file-directory-p cb-profile) "exists" "not yet created")
             pw-profile (if (file-directory-p pw-profile) "exists" "not yet created")
             (if (file-exists-p blocklist) "installed" "not installed")
             (if (file-directory-p ublock-dir) "installed" "not installed")
             (if (file-directory-p darkreader-dir) "installed" "not installed")
             (if (embr--setup-needed-p) "yes" "no"))))

;; ── Internal state ─────────────────────────────────────────────────

;; Per-buffer state — these become buffer-local in `embr-mode' so that
;; multiple sessions (e.g. normal + incognito) each have their own daemon
;; process, callback, URL, frame path, timers, etc.
(defvar embr--process nil "The daemon subprocess.")
(defvar embr--buffer nil "The display buffer (buffer-local; points to self).")
(defvar embr--normal-buffer nil "Global pointer to the normal (non-incognito) embr buffer.")
(defvar embr--response-chunks nil
  "Chunks (most recent first) of an incomplete JSON line from the daemon.")
(defvar embr--pending-callbacks nil
  "Alist of (REQUEST-ID . FUNCTION) awaiting a daemon response.")
(defvar embr--request-id 0 "Counter for daemon request ids.")
(defvar embr--quit-requested nil
  "Non-nil once this buffer asked its daemon to quit.")
(defvar embr--current-url "" "The URL currently displayed.")
(defvar embr--current-title "" "The title of the current page.")
(defvar embr--viewport-width nil "Current viewport width.")
(defvar embr--viewport-height nil "Current viewport height.")
(defvar embr--frame-path nil "Path to the JPEG frame file written by the daemon.")
(defvar embr--url-history nil "History of visited URLs for completion.")
(defvar embr--hints nil "Current hint labels alist from the daemon.")
(defconst embr--hint-initial-read-delay 0.1
  "Seconds to wait before first hint prompt for overlay visibility.")
(defconst embr--hint-retry-delay 0.05
  "Seconds to wait before re-requesting hints after invalid state.")
(defconst embr--hint-max-retries 1
  "Maximum number of automatic hint re-request attempts.")
(defvar embr--hint-session-id 0
  "Monotonic identifier for invalidating stale hint timers.")
(defvar embr--hint-read-timer nil
  "Timer pending a hint read or retry for the current session.")
(defvar embr--hint-retry-count 0
  "Number of automatic retries attempted in the current hint session.")
(defvar embr--hint-action nil
  "Current hint action kind, one of `follow', `download', or `copy'.")
(defvar embr--hint-session-hints nil
  "Hint list captured for the active hint session.")
(defvar embr--hover-timer nil "Timer for mouse hover tracking.")
(defvar embr--hover-last-x nil "Last hover X coordinate sent.")
(defvar embr--hover-last-y nil "Last hover Y coordinate sent.")
(defvar embr--pending-frame nil "Latest frame response waiting to be rendered.")
(defvar embr--render-timer nil "One-shot timer armed while a frame is pending.")
(defvar embr--render-last-time 0.0 "Float-time of the last rendered frame.")
(defvar embr--default-image nil "Image spec currently displayed by the default backend.")
(defvar embr--pressure nil "Non-nil when daemon signals load pressure.")
(defvar embr--hover-last-send-time nil "Float-time of last hover send.")
(defvar embr--active-backend nil "Active render backend name: default or canvas.")
(defvar embr--canvas-image nil "Canvas image spec for the canvas backend.")
(defvar embr--canvas-socket nil "Network process for canvas frame socket.")
(defvar embr--canvas-recv-chunks nil
  "Chunks (most recent first) of the canvas packet being received.")
(defvar embr--canvas-recv-len 0 "Total bytes in `embr--canvas-recv-chunks'.")
(defvar embr--canvas-recv-expected nil
  "Total size of the canvas packet being received, once its header is in.")
(defvar embr--canvas-last-seq 0 "Sequence number of the last rendered canvas frame.")
(defvar embr--canvas-stream-id 0 "Current canvas frame stream generation.")
(defvar embr--canvas-mutation-flag nil
  "Non-nil while canvas clear/resize is mutating the canvas image.")
(defvar embr--canvas-stale-count 0 "Number of stale/out-of-order frames dropped.")
(defvar embr--canvas-error-count 0 "Consecutive canvas blit errors.")
(defvar embr--canvas-frame-count 0 "Total frames blitted via canvas backend.")
(defvar embr--canvas-resize-count 0 "Counter for generating unique canvas `:id' symbols on resize.")
(defvar embr--default-frame-count 0 "Total frames rendered via default backend.")
(defvar embr--zoom-level 1.0 "Current page zoom level.")
(defvar embr--incognito-flag nil "Non-nil when this buffer is an incognito session.")
(defvar embr--proxy-active nil "Non-nil when this session has proxy rules configured.")
(defvar embr--resize-timer nil "Debounce timer for dynamic viewport resize.")

(defun embr--url-proxied-p (url)
  "Return non-nil if URL matches a proxy rule in `embr-proxy-rules'."
  (when (and embr-proxy-rules url (not (string-empty-p url)))
    (let ((host (replace-regexp-in-string
                 "\\`https?://\\([^/:]+\\).*" "\\1" url)))
      (cl-some (lambda (r)
                 (let ((suffix (nth 0 r)))
                   (or (string= suffix "*")
                       (string-suffix-p suffix host))))
               embr-proxy-rules))))
(defvar embr--muted-flag nil "Non-nil when audio/video is muted.")
(defvar embr--tab-list nil "Cached tab list from the daemon.")
(defvar embr--incognito-buffer nil "The incognito display buffer.")

;; ── Process management ─────────────────────────────────────────────

(defun embr--start-daemon ()
  "Start the Python daemon process for the current embr buffer.
Respects `embr-display-method' and `embr--incognito-flag'."
  (when (and embr--process (process-live-p embr--process))
    (delete-process embr--process))
  (setq embr--response-chunks nil
        embr--pending-callbacks nil
        embr--quit-requested nil)
  (let* ((xvfb (and (eq embr-display-method 'headed-offscreen)
                    (executable-find "xvfb-run")))
         (display (cond (xvfb "headed-offscreen")
                        ((eq embr-display-method 'headed-offscreen)
                         ;; Without Xvfb a "headed" daemon would try to
                         ;; open a real window; tell it to go headless.
                         (message "embr: xvfb-run not found, falling back to headless")
                         "headless")
                        (t (symbol-name embr-display-method))))
         (command (if xvfb
                      (list xvfb "--auto-servernum"
                            "--server-args=-screen 0 1920x1080x24"
                            embr-python embr-script)
                    (list embr-python embr-script)))
         (name (if embr--incognito-flag "embr-incognito" "embr"))
         (process-environment
          (append (list (format "EMBR_ENGINE=%s"
                                (symbol-name embr-browser-engine))
                        (format "EMBR_DISPLAY=%s" display))
                  (when embr--incognito-flag '("EMBR_INCOGNITO=1"))
                  process-environment)))
    (setq embr--process
          (make-process
           :name name
           :command command
           :connection-type 'pipe
           :noquery t
           :stderr (get-buffer-create (format "*%s-stderr*" name))
           :filter #'embr--process-filter
           :sentinel #'embr--process-sentinel))
    (process-put embr--process 'embr-buffer (current-buffer))))

(defun embr--process-filter (proc output)
  "Handle OUTPUT from daemon PROC, routing to the owning buffer.
Complete lines are dispatched by `embr--process-lines'.  An incomplete
trailing line is kept as a list of chunks rather than concatenated on
every arrival: a large response such as a page's source arrives in
many chunks, and repeated concatenation would be quadratic."
  (let ((buf (process-get proc 'embr-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (not (string-search "\n" output))
            (push output embr--response-chunks)
          (let ((data (if embr--response-chunks
                          (mapconcat #'identity
                                     (nreverse (cons output
                                                     embr--response-chunks))
                                     "")
                        output))
                (start 0)
                (lines nil)
                pos)
            (setq embr--response-chunks nil)
            (while (setq pos (string-search "\n" data start))
              (push (substring data start pos) lines)
              (setq start (1+ pos)))
            (when (< start (length data))
              (push (substring data start) embr--response-chunks))
            (embr--process-lines (nreverse lines))))))))

(defun embr--process-lines (lines)
  "Dispatch complete JSON LINES from the daemon in the current buffer.
Frame notifications are not rendered here: only the latest one is
stashed for the render timer, so intermediate frames are skipped when
Emacs cannot keep up (e.g. during video playback)."
  (let (last-frame)
    (dolist (line lines)
      (unless (string-empty-p line)
        (condition-case err
            (let ((resp (json-parse-string line :object-type 'alist
                                                :array-type 'list
                                                :null-object nil
                                                :false-object :false)))
              (cond
               ((alist-get 'frame resp)
                (setq last-frame resp))
               ((alist-get 'metadata resp)
                ;; Navigation metadata, possibly with a tab refresh.
                (embr--update-metadata resp)
                (embr--update-tab-list-from-resp resp))
               ((alist-get 'notice resp)
                (message "embr: %s" (alist-get 'notice resp)))
               ((alist-get 'screencast_error resp)
                (message "embr: %s" (alist-get 'screencast_error resp)))
               (t
                ;; Command response: sync canvas stream generation and
                ;; the tab bar, then hand it to the matching callback.
                (embr--canvas-maybe-update-stream-id resp)
                (embr--update-tab-list-from-resp resp)
                (embr--dispatch-response resp))))
          (error (message "embr: JSON parse error: %s"
                          (error-message-string err))))))
    (when (and last-frame embr--active-backend)
      ;; A nested filter run (a callback that waited for output) may
      ;; already have stashed a newer frame; never replace it with an
      ;; older one.
      (let ((pending-id (and embr--pending-frame
                             (alist-get 'frame_id embr--pending-frame)))
            (new-id (alist-get 'frame_id last-frame)))
        (unless (and (integerp pending-id) (integerp new-id)
                     (> pending-id new-id))
          (setq embr--pending-frame last-frame)))
      (embr--render-schedule))))

(defun embr--dispatch-response (resp)
  "Call the callback registered for the request id in RESP, if any.
Responses without an id belong to fire-and-forget commands (hover
updates, frame acks) and carry no callback."
  (when-let* ((id (alist-get 'id resp))
              (entry (assoc id embr--pending-callbacks)))
    (setq embr--pending-callbacks (delq entry embr--pending-callbacks))
    (funcall (cdr entry) resp)))

(defun embr--fail-pending-callbacks (reason)
  "Invoke every pending callback with an error response citing REASON.
Lets synchronous callers such as `embr--send-sync' return instead of
waiting for a reply that can no longer arrive."
  (let ((pending (nreverse embr--pending-callbacks)))
    (setq embr--pending-callbacks nil)
    (dolist (entry pending)
      (condition-case err
          (funcall (cdr entry) (list (cons 'error reason)))
        (error (message "embr: callback error: %s"
                        (error-message-string err)))))))

(defun embr--process-sentinel (proc event)
  "Handle process EVENT (e.g. exit) for PROC."
  (unless (process-live-p proc)
    (let ((buf (process-get proc 'embr-buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (unless embr--quit-requested
            (message "embr: daemon exited: %s" (string-trim event)))
          (embr--hint-abort-session)
          (embr--hover-stop)
          (embr--backend-shutdown)
          (setq embr--process nil
                embr--response-chunks nil)
          (embr--fail-pending-callbacks "daemon exited"))))))

(defun embr--send (msg &optional callback)
  "Send MSG (an alist) to the daemon as JSON and return its request id.
Call CALLBACK with the response.  Each command carries an id that the
daemon echoes back, so replies are matched to their callbacks even
when several commands are in flight or fire-and-forget traffic is
interleaved."
  (unless (and embr--process (process-live-p embr--process))
    (user-error "embr: daemon not running"))
  ;; Purge any stale pending frame so the next render reflects post-input state.
  (setq embr--pending-frame nil)
  (let ((id (cl-incf embr--request-id)))
    (when callback
      (push (cons id callback) embr--pending-callbacks))
    (process-send-string embr--process
                         (concat (json-serialize (cons (cons 'id id) msg))
                                 "\n"))
    id))

(defun embr--send-no-callback (msg)
  "Send MSG as JSON, ignoring the response.  No-op when the daemon is down."
  (when (and embr--process (process-live-p embr--process))
    (process-send-string embr--process (concat (json-serialize msg) "\n"))))

(defconst embr--send-sync-timeout 40
  "Default seconds `embr--send-sync' waits before giving up.
Slightly longer than the daemon's own per-command timeout, so its
error message arrives first when a command hangs.")

(defun embr--send-sync (msg &optional timeout)
  "Send MSG and wait synchronously for the response.
Return the parsed response alist.  If the daemon exits, or TIMEOUT
seconds (default `embr--send-sync-timeout') pass without a reply,
return an alist with an `error' entry instead of waiting forever."
  (let* ((result nil)
         (done nil)
         (proc embr--process)
         (timeout (or timeout embr--send-sync-timeout))
         (deadline (+ (float-time) timeout))
         (id (embr--send msg (lambda (resp) (setq result resp done t)))))
    (while (and (not done)
                (process-live-p proc)
                (< (float-time) deadline))
      (accept-process-output proc 0.5))
    (unless done
      ;; Drop the stale callback so a late reply cannot fire it.
      (setq embr--pending-callbacks
            (assoc-delete-all id embr--pending-callbacks)))
    (or result
        (list (cons 'error (if (process-live-p proc)
                               (format "no response from daemon within %ss"
                                       timeout)
                             "daemon not running"))))))

(defun embr--shutdown-daemon (&optional timeout)
  "Ask the daemon to quit and wait up to TIMEOUT seconds for it to exit.
Default TIMEOUT is 3 seconds.  A daemon still running afterwards is
killed.  The quit lets it close the browser cleanly and remove its
runtime files (and an incognito profile), which a bare kill would
leave behind.  Pending callbacks fail and the sentinel's exit message
is suppressed."
  (let ((proc embr--process))
    (when (and proc (process-live-p proc))
      (setq embr--quit-requested t)
      (ignore-errors
        (process-send-string
         proc (concat (json-serialize '((cmd . "quit"))) "\n")))
      (let ((deadline (+ (float-time) (or timeout 3.0))))
        (while (and (process-live-p proc) (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (when (process-live-p proc)
        (delete-process proc)))
    (setq embr--process nil
          embr--frame-path nil)))

;; ── Render backend ─────────────────────────────────────────────────

(declare-function embr-canvas-supported-p "embr-canvas")
(declare-function embr-canvas-blit-jpeg "embr-canvas")
(declare-function embr-canvas-clear "embr-canvas")
(declare-function embr-canvas-version "embr-canvas")

(defconst embr--canvas-module-version "2.1.0"
  "Oldest embr-canvas module version with the current blit interface.
Version 2.1.0 takes the canvas size from the image spec and accepts
\(CANVAS JPEG-DATA) only; 2.0.0 was the first to target the Emacs 32
canvas API.")

(defvar embr--canvas-probe-result nil
  "Cached result of `embr--canvas-probe' for this Emacs session.
A cons (STATUS . DETAIL).  STATUS is one of `available',
`no-emacs-support', `module-build-failed', `module-load-failed',
`module-unsupported' or `smoke-test-failed'; DETAIL is a string
explaining it.  Not buffer-local: canvas support is a property of
the running Emacs, not of a session.")

(defvar embr--canvas-notice-shown nil
  "Non-nil once the canvas fallback notice was shown in this session.")

(defun embr--canvas-source-dir ()
  "Return the directory containing native module source.
Resolves symlinks so this works when Elpaca symlinks embr.el
from the build dir to the source repo."
  (file-name-directory (file-truename
                        (expand-file-name "embr.el" embr--directory))))

(defun embr--emacs-canvas-p ()
  "Return non-nil if the running Emacs has native canvas images.
Native canvas images arrived in Emacs 32 together with the Lisp
function `canvas-refresh'; the pre-merge canvas patch had the image
type but not the function, so it is treated as unsupported."
  (and (image-type-available-p 'canvas)
       (fboundp 'canvas-refresh)))

(defun embr--canvas-include-dir ()
  "Return the directory holding the running Emacs's `emacs-module.h', or nil.
Compiling the module against that header, rather than against whatever
header is first on the default include path, keeps a stale header from
another Emacs installation from producing a module without canvas
support."
  (cl-some (lambda (dir)
             (and dir
                  (file-exists-p (expand-file-name "emacs-module.h" dir))
                  (directory-file-name dir)))
           (list
            ;; Installed Emacs: PREFIX/share/emacs/VERSION/etc/ -> PREFIX/include.
            (expand-file-name "../../../../include" data-directory)
            ;; Emacs run from its build tree.
            (and (stringp source-directory)
                 (expand-file-name "src" source-directory)))))

(defun embr--canvas-maybe-compile ()
  "Compile the canvas native module when it is missing or out of date.
Return nil on success, or a string describing the failure."
  (let* ((native-dir (expand-file-name "native" (embr--canvas-source-dir)))
         (so (expand-file-name "embr-canvas.so" native-dir))
         (src (expand-file-name "embr-canvas.c" native-dir)))
    (cond
     ((not (file-exists-p src))
      (format "module source %s not found" src))
     ;; A module built from the current source is fine; a stale one
     ;; must be rebuilt before it is loaded, since Emacs cannot
     ;; unload a module.
     ((and (file-exists-p so) (not (file-newer-than-file-p src so)))
      nil)
     ((not (executable-find "make"))
      "make not found; install a C compiler, make and libjpeg-turbo headers")
     (t
      (message "embr: compiling canvas module...")
      (let* ((buf (get-buffer-create "*embr-canvas-build*"))
             (include (embr--canvas-include-dir))
             (args (append (list "-C" native-dir)
                           (and include
                                (list (concat "EMACS_INCLUDE=" include)))))
             ret)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "make " (mapconcat #'identity args " ") "\n")))
        (setq ret (apply #'call-process "make" nil buf nil args))
        (if (and (eql ret 0) (file-exists-p so))
            (progn
              (message "embr: compiling canvas module...done")
              nil)
          (format "make -C native failed (exit %s), see buffer %s"
                  ret (buffer-name buf))))))))

(defun embr--canvas-probe-1 ()
  "Run the canvas probe steps and return (STATUS . DETAIL).
See `embr--canvas-probe-result' for the possible values."
  (let ((so (expand-file-name "native/embr-canvas.so"
                              (embr--canvas-source-dir)))
        failure)
    (cond
     ;; Step 1: the running Emacs must have native canvas images.
     ((not (embr--emacs-canvas-p))
      (cons 'no-emacs-support
            (format "Emacs %s has no native canvas images" emacs-version)))
     ;; Step 2: build the module when it is missing or stale.
     ((setq failure (embr--canvas-maybe-compile))
      (cons 'module-build-failed failure))
     ;; Step 3: load the module and check that it targets this API.
     ((setq failure (condition-case err
                        (progn (module-load so) nil)
                      (error (error-message-string err))))
      (cons 'module-load-failed failure))
     ((not (and (fboundp 'embr-canvas-supported-p)
                (embr-canvas-supported-p)))
      (cons 'module-unsupported
            (concat "embr-canvas.so was built without the Emacs 32 canvas API; "
                    "rebuild it with make -C native clean all "
                    "EMACS_INCLUDE=<directory of emacs-module.h> and restart Emacs")))
     ((not (and (fboundp 'embr-canvas-version)
                (version<= embr--canvas-module-version (embr-canvas-version))))
      (cons 'module-unsupported
            (format "embr-canvas.so is version %s, need %s or newer; run make -C native clean all and restart Emacs"
                    (embr-canvas-version) embr--canvas-module-version)))
     ;; Step 4: smoke blit through the whole chain.  An empty JPEG
     ;; makes the blit return nil, but it exercises canvas_data and
     ;; the spec keywords end to end.
     ((setq failure (condition-case err
                        (progn
                          (embr-canvas-blit-jpeg
                           '(image :type canvas
                                   :id embr--smoke-test
                                   :data-width 4
                                   :data-height 4)
                           "")
                          nil)
                      (error (error-message-string err))))
      (cons 'smoke-test-failed failure))
     (t
      (cons 'available (format "embr-canvas %s" (embr-canvas-version)))))))

(defun embr--canvas-probe ()
  "Return whether native canvas rendering is available, as (STATUS . DETAIL).
The result is computed once per Emacs session and cached in
`embr--canvas-probe-result'."
  (or embr--canvas-probe-result
      (setq embr--canvas-probe-result (embr--canvas-probe-1))))

(defun embr--select-backend ()
  "Select the render backend based on `embr-render-backend'.
Return \"canvas\" or \"default\", the names the daemon understands."
  (pcase embr-render-backend
    ('canvas
     (let ((probe (embr--canvas-probe)))
       (if (eq (car probe) 'available)
           "canvas"
         (error "embr: canvas backend requested but not available: %s"
                (cdr probe)))))
    ;; `auto' and `default' (and anything else) behave the same.
    (_ (if (eq (car (embr--canvas-probe)) 'available)
           "canvas"
         (unless (image-type-available-p 'jpeg)
           (error "embr: this Emacs was built without JPEG image support, which the JPEG file backend needs"))
         "default"))))

(defun embr--canvas-maybe-notify ()
  "Say once per session why frames go through the JPEG file backend.
On an Emacs without native canvas images, point at Emacs 32 as the
version that includes them.  When Emacs has them but the module could
not be used, show the probe's diagnostic instead.  Do nothing when the
user forced `canvas', which signals its own error."
  (unless embr--canvas-notice-shown
    (let ((probe (unless (eq embr-render-backend 'canvas)
                   (embr--canvas-probe))))
      (when (and probe (not (eq (car probe) 'available)))
        (setq embr--canvas-notice-shown t)
        (if (eq (car probe) 'no-emacs-support)
            (message "embr: this Emacs has no native canvas images (included in Emacs 32 and newer); using the slower JPEG file backend.  Run an Emacs with native canvas support for faster rendering")
          (message "embr: native canvas is available but the embr module could not be used (%s); using the JPEG file backend.  See README, \"Native canvas rendering\""
                   (cdr probe)))))))

(defun embr--backend-report (resp prefix)
  "Report the transport and backend from init response RESP.
PREFIX names the session in the message.  When the canvas backend is
not in use, follow with the one-time notice from
`embr--canvas-maybe-notify'."
  (message "%s: %s transport, %s backend"
           prefix
           (or (alist-get 'frame_source resp) "unknown")
           (embr--backend-name))
  (unless (string= (embr--backend-name) "canvas")
    (embr--canvas-maybe-notify)))

;; ── Backend interface ─────────────────────────────────────────────

(defun embr--backend-name ()
  "Return the name of the active render backend."
  (or embr--active-backend "none"))

(defun embr--backend-init (name socket-path)
  "Initialize render backend NAME.
SOCKET-PATH is the daemon frame socket (used by canvas backend)."
  (setq embr--active-backend name
        embr--canvas-error-count 0
        embr--canvas-frame-count 0
        embr--default-frame-count 0
        embr--default-image nil)
  (embr--render-stop)
  (setq embr--render-last-time 0.0)
  (when (string= name "canvas")
    (embr--backend-init-canvas socket-path)))

(defun embr--backend-on-frame (resp)
  "Dispatch frame notification RESP to the active backend."
  (when embr--active-backend
    (if (string= embr--active-backend "default")
        (embr--default-display-frame resp)
      ;; Canvas: pixel data arrives via socket, nothing to do here.
      nil)))

(defun embr--backend-shutdown ()
  "Shut down the active render backend."
  (embr--render-stop)
  (embr--backend-shutdown-canvas)
  (when embr--default-image
    (image-flush embr--default-image t)
    (setq embr--default-image nil))
  (setq embr--active-backend nil))

;; ── Legacy backend ────────────────────────────────────────────────

(defun embr--default-display-frame (_resp)
  "Read the JPEG frame from disk and display it in the buffer."
  (when (and embr--frame-path
             (file-exists-p embr--frame-path))
    (let* ((path embr--frame-path)
           (data (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally path)
                   (buffer-string)))
           ;; :scale 1 -- `create-image' would otherwise apply
           ;; `image-scaling-factor' (based on the default font size),
           ;; and a scaled frame no longer matches the viewport, so
           ;; clicks and hover land in the wrong place.
           (image (create-image data 'jpeg t :scale 1))
           (old-image embr--default-image))
      (let ((inhibit-read-only t))
        (if (and old-image (= (buffer-size) 1))
            ;; Swap the display property in place rather than erasing
            ;; and re-inserting the buffer for every frame.
            (put-text-property (point-min) (point-max) 'display image)
          (erase-buffer)
          (insert-image image " ")
          (put-text-property (point-min) (point-max) 'pointer 'arrow)
          (goto-char (point-min))))
      (setq embr--default-image image)
      ;; Free the previous frame's decoded pixels now rather than after
      ;; `image-cache-eviction-delay' (5 minutes by default): at 30 fps
      ;; that delay would keep thousands of frames in memory.
      (when old-image
        (image-flush old-image t)))
    (cl-incf embr--default-frame-count)))

;; ── Canvas backend ────────────────────────────────────────────────

(defun embr--read-u32 (str offset)
  "Read a little-endian uint32 from unibyte STR at OFFSET."
  (logior (aref str offset)
          (ash (aref str (+ offset 1)) 8)
          (ash (aref str (+ offset 2)) 16)
          (ash (aref str (+ offset 3)) 24)))

(defun embr--canvas-maybe-update-stream-id (resp)
  "Update canvas stream generation from RESP if present.
Only the generation counter changes here.  Bytes already buffered from
the socket are left alone: the socket and stdout are separate pipes,
and dropping a half-received packet of the old stream would leave its
remainder to be parsed as a header, desynchronizing the stream.  Old
packets are rejected by their stream id instead."
  (when-let* ((stream-id (alist-get 'stream_id resp)))
    (when (and (integerp stream-id) (> stream-id embr--canvas-stream-id))
      (setq embr--canvas-stream-id stream-id
            embr--canvas-last-seq 0))))

(defun embr--canvas-next-id ()
  "Return a fresh uninterned canvas identifier."
  (cl-incf embr--canvas-resize-count)
  (make-symbol (format "embr-canvas-%s-%d"
                       (buffer-name)
                       embr--canvas-resize-count)))

(defun embr--canvas-with-mutation (thunk)
  "Call THUNK while suppressing canvas blits in this buffer."
  (let ((old embr--canvas-mutation-flag))
    (setq embr--canvas-mutation-flag t)
    (unwind-protect
        (funcall thunk)
      (setq embr--canvas-mutation-flag old))))

(defconst embr--canvas-header-size 20
  "Bytes in a canvas packet header: seq, width, height, length, stream id.")

(defconst embr--canvas-max-frame-bytes (* 64 1024 1024)
  "Largest JPEG payload accepted from the canvas socket.
Matches the limit in the native module; anything larger means the
byte stream is out of sync.")

(defun embr--canvas-recv-reset ()
  "Discard any partially received canvas packet."
  (setq embr--canvas-recv-chunks nil
        embr--canvas-recv-len 0
        embr--canvas-recv-expected nil))

(defun embr--canvas-recv-string ()
  "Join the buffered canvas chunks into one string and keep it buffered."
  (let ((str (if (cdr embr--canvas-recv-chunks)
                 (mapconcat #'identity (nreverse embr--canvas-recv-chunks) "")
               (car embr--canvas-recv-chunks))))
    (setq embr--canvas-recv-chunks (list str))
    str))

(defun embr--canvas-socket-filter (proc data)
  "Handle binary frame DATA from canvas socket PROC.
A packet is a 20-byte header (seq, width, height, JPEG length and
stream id, little-endian uint32 each) followed by the JPEG bytes.
Chunks are collected until a whole packet is present and joined once,
instead of re-concatenating the growing buffer on every chunk.
Routes to the owning buffer via a process property so buffer-local
variables resolve correctly."
  (let ((buf (process-get proc 'embr-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (push data embr--canvas-recv-chunks)
        (cl-incf embr--canvas-recv-len (length data))
        (catch 'wait
          (while t
            ;; Parse the header once enough bytes are in.
            (unless embr--canvas-recv-expected
              (when (< embr--canvas-recv-len embr--canvas-header-size)
                (throw 'wait nil))
              (let ((jpeg-len (embr--read-u32 (embr--canvas-recv-string) 12)))
                (when (> jpeg-len embr--canvas-max-frame-bytes)
                  (message "embr: canvas stream out of sync, resetting")
                  (embr--canvas-recv-reset)
                  (throw 'wait nil))
                (setq embr--canvas-recv-expected
                      (+ embr--canvas-header-size jpeg-len))))
            (when (< embr--canvas-recv-len embr--canvas-recv-expected)
              (throw 'wait nil))
            ;; A whole packet is buffered: split it off and handle it.
            (let* ((str (embr--canvas-recv-string))
                   (total embr--canvas-recv-expected)
                   (rest (substring str total)))
              (setq embr--canvas-recv-chunks (and (> (length rest) 0)
                                                  (list rest))
                    embr--canvas-recv-len (length rest)
                    embr--canvas-recv-expected nil)
              (embr--canvas-handle-packet str total))))))))

(defun embr--canvas-handle-packet (str total)
  "Handle the canvas packet occupying the first TOTAL bytes of STR.
Drop packets from an older stream generation and stale or
out-of-order frames; blit the rest to the canvas."
  (let ((seq (embr--read-u32 str 0))
        (stream-id (embr--read-u32 str 16)))
    ;; Stream generation changed (tab switch/screencast restart).
    (when (> stream-id embr--canvas-stream-id)
      (setq embr--canvas-stream-id stream-id
            embr--canvas-last-seq 0))
    (cond
     ;; Packet from an older stream: always drop.
     ((< stream-id embr--canvas-stream-id)
      (cl-incf embr--canvas-stale-count))
     ;; Drop stale or out-of-order packets.  Handle uint32 wraparound:
     ;; if the delta is huge (> 2^31), seq wrapped.
     ((and (<= seq embr--canvas-last-seq)
           (< (- embr--canvas-last-seq seq) #x80000000))
      (cl-incf embr--canvas-stale-count))
     ;; Skip blits while the canvas is being mutated.
     (embr--canvas-mutation-flag
      (setq embr--canvas-last-seq seq)
      (cl-incf embr--canvas-stale-count))
     (t
      (setq embr--canvas-last-seq seq)
      (when embr--canvas-image
        ;; The module takes the canvas size from the image spec and
        ;; clips the frame to it, so a frame of another size (during a
        ;; resize) can never write out of bounds.
        (condition-case err
            (if (embr-canvas-blit-jpeg
                 embr--canvas-image
                 (substring str embr--canvas-header-size total))
                (progn
                  (cl-incf embr--canvas-frame-count)
                  (setq embr--canvas-error-count 0))
              (embr--canvas-note-failure "frame could not be decoded"))
          (error
           (embr--canvas-note-failure (error-message-string err)))))))))

(defun embr--canvas-note-failure (reason)
  "Count a failed canvas blit and report REASON without flooding the echo area.
The first failure is reported, then every hundredth; a stream of bad
frames would otherwise print a message per frame."
  (cl-incf embr--canvas-error-count)
  (when (or (= embr--canvas-error-count 1)
            (zerop (% embr--canvas-error-count 100)))
    (message "embr: canvas blit failed (%d in a row): %s"
             embr--canvas-error-count reason)))


(defun embr--canvas-socket-sentinel (proc event)
  "Handle canvas socket PROC disconnect EVENT."
  (unless (process-live-p proc)
    (let ((buf (process-get proc 'embr-buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (embr--canvas-recv-reset))))
    (unless (string-match-p "deleted" event)
      (message "embr: canvas socket closed: %s" (string-trim event)))))

(defun embr--backend-init-canvas (socket-path)
  "Initialize the canvas render backend.
Connect to SOCKET-PATH and create the canvas image in the buffer."
  (let ((canvas-id (embr--canvas-next-id)))
    (setq embr--canvas-image
          `(image :type canvas
                  :id ,canvas-id
                  :data-width ,embr--viewport-width
                  :data-height ,embr--viewport-height)))
  (embr--canvas-recv-reset)
  (setq embr--canvas-error-count 0
        embr--canvas-last-seq 0
        embr--canvas-stream-id 0
        embr--canvas-stale-count 0)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize " " 'display embr--canvas-image))
    (put-text-property (point-min) (point-max) 'pointer 'arrow)
    (goto-char (point-min)))
  ;; Connect to the daemon's frame socket.
  (setq embr--canvas-socket
        (make-network-process
         :name "embr-canvas"
         :family 'local
         :service ""
         :remote socket-path
         :coding '(binary . binary)
         :filter #'embr--canvas-socket-filter
         :sentinel #'embr--canvas-socket-sentinel
         :noquery t))
  (process-put embr--canvas-socket 'embr-buffer (current-buffer)))

(defun embr--backend-shutdown-canvas ()
  "Shut down the canvas backend."
  (when (and embr--canvas-socket (process-live-p embr--canvas-socket))
    (delete-process embr--canvas-socket))
  ;; Drop the canvas from the image cache so Emacs can free its pixel
  ;; buffer once nothing references the spec any more.
  (when embr--canvas-image
    (image-flush embr--canvas-image t))
  (setq embr--canvas-socket nil
        embr--canvas-image nil
        embr--canvas-stream-id 0)
  (embr--canvas-recv-reset))

(defun embr--canvas-clear ()
  "Clear the current canvas pixel buffer in place."
  (when embr--canvas-image
    (embr--canvas-with-mutation
     (lambda ()
       (setq embr--canvas-last-seq 0)
       (embr-canvas-clear embr--canvas-image)))))

(defun embr--canvas-resize (width height)
  "Recreate the canvas image at WIDTH x HEIGHT.
Allocate a fresh `:id' so Emacs creates a new pixel buffer at the
correct size, then flush the old image from the cache so Emacs can
free its buffer."
  (embr--canvas-with-mutation
   (lambda ()
     (let ((old-image embr--canvas-image)
           (canvas-id (embr--canvas-next-id)))
       (setq embr--canvas-image
             `(image :type canvas
                     :id ,canvas-id
                     :data-width ,width
                     :data-height ,height))
       (setq embr--canvas-last-seq 0)
       (let ((inhibit-read-only t))
         (erase-buffer)
         (insert (propertize " " 'display embr--canvas-image))
         (put-text-property (point-min) (point-max) 'pointer 'arrow)
         (goto-char (point-min)))
       (when old-image
         (image-flush old-image t))))))

;; ── Backend debug ─────────────────────────────────────────────────

(defun embr-backend-info ()
  "Display render backend diagnostics, including the canvas probe result."
  (interactive)
  (let ((probe (or embr--canvas-probe-result
                   '(not-probed . "canvas not probed yet in this session"))))
    (message "embr backend: %s | canvas: %d frames, %d errors, %d stale | default: %d frames | canvas probe: %s (%s)"
             (embr--backend-name)
             embr--canvas-frame-count
             embr--canvas-error-count
             embr--canvas-stale-count
             embr--default-frame-count
             (car probe)
             (cdr probe))))

(defun embr-force-default-backend ()
  "No-op.  Backend switching is not supported mid-session."
  (interactive)
  (message "embr: backend switching is not supported — restart embr"))

;; ── Display ────────────────────────────────────────────────────────

(defun embr--handle-frame (resp)
  "Handle a frame notification from the daemon.
Dispatch to the active backend for display, then update metadata."
  (setq embr--pressure (eq (alist-get 'pressure resp) t))
  (let ((url (or (alist-get 'url resp) ""))
        (frame-id (alist-get 'frame_id resp))
        (capture-mono (alist-get 'capture_done_mono_ms resp)))
    ;; Backend-specific frame display.
    (embr--backend-on-frame resp)
    ;; Update URL from frame (title comes via metadata messages).
    (unless (string= url embr--current-url)
      (setq embr--current-url url)
      (force-mode-line-update))
    ;; Send render ack for perf logging.
    (when (and embr-perf-log frame-id capture-mono
               embr--process (process-live-p embr--process))
      (process-send-string
       embr--process
       (concat (json-serialize
                `((cmd . "frame_rendered")
                  (frame_id . ,frame-id)
                  (capture_done_mono_ms . ,capture-mono)))
               "\n")))))

(defun embr--update-metadata (resp)
  "Update URL and title from command RESP if present.
Also sync the active tab entry in `embr--tab-list' so that
`embr--render-tab-bar' sees fresh data without waiting for a tab
command round-trip."
  (let ((changed nil))
    (when-let* ((url (alist-get 'url resp)))
      (when (stringp url)
        (unless (string= url embr--current-url)
          (setq embr--current-url url
                changed t))))
    (when-let* ((title (alist-get 'title resp)))
      (when (stringp title)
        (unless (string= title embr--current-title)
          (setq embr--current-title title
                changed t))))
    (when changed
      ;; Keep the active tab entry in embr--tab-list in sync so the
      ;; tab bar renders the current title immediately.
      (dolist (tab embr--tab-list)
        (when (eq (alist-get 'active tab) t)
          (setf (alist-get 'title tab) embr--current-title)
          (setf (alist-get 'url tab) embr--current-url)))
      (rename-buffer (format "%s%s*"
                             (cond (embr--incognito-flag "*embr incognito: ")
                                   ((embr--url-proxied-p embr--current-url) "*embr proxy: ")
                                   (t "*embr: "))
                             (if (string-empty-p embr--current-title)
                                 embr--current-url embr--current-title))
                     t)
      (force-mode-line-update)
      ;; The active tab's URL may have changed: keep the saved session
      ;; current so a crash does not lose it.
      (embr--save-session))))

(defun embr--action-callback (resp)
  "Generic callback for command responses: report errors, update metadata."
  (when-let* ((err (alist-get 'error resp)))
    (message "embr error: %s" err))
  (embr--update-metadata resp)
  ;; After a tab switch the daemon restarts screencast on the new page.
  ;; Clear the existing canvas immediately so stale content from the
  ;; old tab is not shown while fresh frames arrive.
  (when (and (alist-get 'tabs resp)
             (equal embr--active-backend "canvas"))
    (embr--canvas-clear)))

;; ── Commands ───────────────────────────────────────────────────────

(defun embr-execute-js (expr)
  "Execute JavaScript EXPR in the browser and display the result."
  (interactive "sJS: ")
  (embr--send `((cmd . "js") (expr . ,expr))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "embr JS error: %s" err)
                         (message "=> %s" (alist-get 'result resp))))))

(defconst embr--url-scheme-regexp
  (concat "\\`\\(?:[[:alpha:]][[:alnum:]+.-]*://"
          "\\|\\(?:about\\|data\\|view-source\\|blob\\):\\)")
  "Regexp matching the scheme at the start of a URL.
Besides SCHEME:// this covers the schemes Chromium accepts without
slashes (about:blank, data:, view-source:, blob:).  A host:port pair
does not match, so \"localhost:8080\" is not mistaken for a scheme.")

(defun embr--url-like-p (input)
  "Return non-nil if INPUT looks like a URL rather than a search query.
That is, INPUT has a scheme, is localhost or an IPv4 address with an
optional port and path, or is a host name with a dot and no whitespace."
  (or (string-match-p embr--url-scheme-regexp input)
      (string-match-p "\\`localhost\\(?::[0-9]+\\)?\\(?:[/?#].*\\)?\\'" input)
      (string-match-p
       "\\`[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\(?::[0-9]+\\)?\\(?:[/?#].*\\)?\\'"
       input)
      (and (not (string-match-p "[[:space:]]" input))
           (string-match-p
            "\\`[^/?#:]+\\.[[:alpha:]][^/?#:.]*\\(?::[0-9]+\\)?\\(?:[/?#]\\|\\'\\)"
            input))))

(defun embr--maybe-search-url (input)
  "Return the URL to open for INPUT.
INPUT is returned when it looks like a URL (see `embr--url-like-p'),
with https:// prepended when it has no scheme; otherwise it becomes a
search URL via `embr--search-url'.  Surrounding whitespace is ignored
and empty input means about:blank.  Return nil when
`embr-search-engine' is a function, which handles the query itself."
  (let ((input (string-trim input)))
    (cond
     ((string-empty-p input) "about:blank")
     ((not (embr--url-like-p input)) (embr--search-url input))
     ((string-match-p embr--url-scheme-regexp input) input)
     (t (concat "https://" input)))))

(defconst embr--url-history-max 500
  "Number of entries kept in `embr--url-history'.")

(defvar embr--url-input-history nil
  "Minibuffer history of what was typed at the URL prompt.")

(defvar embr--incognito-input-history nil
  "Throwaway minibuffer history for incognito URL prompts.
Rebound around each read so nothing typed in incognito is kept.")

(defun embr--read-url (prompt &optional incognito)
  "Read a URL or search query with PROMPT.
Complete against `embr--url-history', most recent first.  When
INCOGNITO is non-nil, or in an incognito buffer, offer no completion
and remember nothing."
  (if (or incognito embr--incognito-flag)
      (let ((embr--incognito-input-history nil))
        (read-string prompt nil 'embr--incognito-input-history))
    (completing-read prompt
                     (lambda (str pred action)
                       (if (eq action 'metadata)
                           '(metadata (display-sort-function . identity)
                                      (cycle-sort-function . identity))
                         (complete-with-action action embr--url-history
                                               str pred)))
                     nil nil nil 'embr--url-input-history)))

(defun embr--url-history-add (input &optional target)
  "Record INPUT at the front of `embr--url-history', dropping duplicates.
TARGET is the URL INPUT resolved to (default INPUT); nothing is
recorded for proxied targets, in incognito sessions, or for empty
input.  The list is capped at `embr--url-history-max' entries."
  (unless (or embr--incognito-flag
              (string-empty-p input)
              (embr--url-proxied-p (or target input)))
    (setq embr--url-history (cons input (delete input embr--url-history)))
    (let ((tail (nthcdr (1- embr--url-history-max) embr--url-history)))
      (when (cdr tail)
        (setcdr tail nil)))))

(defun embr-navigate (url)
  "Navigate to URL, or search if the input does not look like a URL.
With a prefix argument, clear the URL history instead."
  (interactive
   (if current-prefix-arg
       (progn
         (setq embr--url-history nil)
         (message "embr: URL history cleared")
         (list nil))
     (list (embr--read-url "URL/Search: "))))
  (when url
    (let ((target (embr--maybe-search-url url)))
      (when target
        (embr--url-history-add url target)
        (embr--send `((cmd . "navigate") (url . ,target))
                    #'embr--action-callback)))))

(defun embr-refresh ()
  "Refresh the current page."
  (interactive)
  (embr--send '((cmd . "refresh"))
                     #'embr--action-callback))

(defun embr-back ()
  "Go back in browser history."
  (interactive)
  (embr--send '((cmd . "back"))
                     #'embr--action-callback))

(defun embr-forward ()
  "Go forward in browser history."
  (interactive)
  (embr--send '((cmd . "forward"))
                     #'embr--action-callback))

(defun embr--history-db-file ()
  "Return the browser profile's History SQLite database file."
  (expand-file-name "History" (embr--profile-default-directory)))

(defconst embr--history-query
  (concat "SELECT url, replace(replace(title, char(10), ' '), char(13), ' ')"
          " FROM urls WHERE hidden = 0 AND title <> ''"
          " ORDER BY last_visit_time DESC LIMIT 200")
  "SQL returning (URL TITLE) rows of recent history, newlines removed.")

(defun embr--history-rows (db-file)
  "Return (URL . TITLE) conses from the Chromium History database DB-FILE.
Most recently visited first.  Use Emacs's built-in SQLite support when
it has it, else the sqlite3 command."
  (cond
   ((and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (let ((db (sqlite-open db-file)))
      (unwind-protect
          (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row)))
                  (sqlite-select db embr--history-query))
        (sqlite-close db))))
   ((executable-find "sqlite3")
    (with-temp-buffer
      ;; The unit separator cannot occur in a URL, unlike a tab in a title.
      (let ((status (call-process "sqlite3" nil t nil "-separator" "\C-_"
                                  db-file embr--history-query)))
        (unless (eql status 0)
          (error "embr: sqlite3 failed (exit %s): %s"
                 status (string-trim (buffer-string)))))
      (mapcar (lambda (line)
                (let ((parts (split-string line "\C-_")))
                  (cons (car parts) (string-join (cdr parts) " "))))
              (split-string (buffer-string) "\n" t))))
   (t
    (user-error "embr: this Emacs has no SQLite support and sqlite3 is not on PATH"))))

(defun embr-history-persistent ()
  "Browse persistent Chromium history and navigate to a selection.
Reads the browser profile's History database directly, from a copy so
that Chromium's lock on the file does not get in the way."
  (interactive)
  (let ((db (embr--history-db-file)))
    (unless (file-exists-p db)
      (user-error "embr: no history database at %s" db))
    (let* ((tmp (make-temp-file "embr-hist" nil ".db"))
           (rows (unwind-protect
                     (progn (copy-file db tmp t)
                            (embr--history-rows tmp))
                   (delete-file tmp))))
      (if (null rows)
          (message "embr: history is empty")
        (let* ((candidates
                (mapcar (lambda (row)
                          (cons (if (string-empty-p (cdr row))
                                    (car row)
                                  (format "%s  —  %s" (cdr row) (car row)))
                                (car row)))
                        rows))
               (chosen (completing-read
                        "History (all): "
                        (lambda (str pred action)
                          (if (eq action 'metadata)
                              '(metadata (display-sort-function . identity))
                            (complete-with-action action candidates str pred)))
                        nil t)))
          (when-let* ((url (cdr (assoc chosen candidates))))
            (embr--send `((cmd . "navigate") (url . ,url))
                        #'embr--action-callback)))))))

(defun embr-download-history ()
  "Navigate to chrome://downloads."
  (interactive)
  (embr--send '((cmd . "navigate") (url . "chrome://downloads"))
              #'embr--action-callback))

(defvar embr--session-file
  (expand-file-name "session.json" embr--data-dir)
  "File where session tab URLs are saved for restore.")

(defvar embr--use-custom-session t
  "Non-nil to use embr's own session save/restore.")

(defvar embr--session-last-saved nil
  "Serialized session most recently written, to skip redundant writes.")

(defvar embr--session-loaded nil
  "Non-nil once `embr--restore-session' has run in this buffer.
Until then nothing is saved: the daemon's init response already
carries its one blank tab, and saving that would remove the session
file before it has been read.")

(defun embr--session-data ()
  "Return the session to save as an alist, or nil when no tab has a URL."
  (let ((active 0)
        (urls nil))
    (dolist (tab embr--tab-list)
      (let ((url (alist-get 'url tab)))
        (when (and (stringp url) (not (string= url "about:blank")))
          (when (eq (alist-get 'active tab) t)
            (setq active (length urls)))
          (push url urls))))
    (when urls
      `((urls . ,(vconcat (nreverse urls)))
        (active . ,active)))))

(defun embr--save-session ()
  "Write the open tabs to the session file, or remove it when none has a URL.
Called whenever the tab list changes, so a crash loses nothing; a
session identical to the last one written is not written again."
  (when (and embr--use-custom-session
             embr-session-restore
             (not embr--incognito-flag)
             embr--session-loaded
             embr--tab-list)
    (let* ((data (embr--session-data))
           (str (and data (json-serialize data))))
      (unless (equal str embr--session-last-saved)
        (setq embr--session-last-saved str)
        (condition-case err
            (if str
                (with-temp-file embr--session-file
                  (insert str))
              (when (file-exists-p embr--session-file)
                (delete-file embr--session-file)))
          (file-error
           (message "embr: could not save session: %s"
                    (error-message-string err))))))))

(defun embr--clear-saved-session ()
  "Forget the saved session, because the user closed every tab."
  (setq embr--tab-list nil
        embr--session-last-saved nil)
  (when (and (not embr--incognito-flag)
             (file-exists-p embr--session-file))
    (ignore-errors (delete-file embr--session-file))))

(defun embr--restore-session ()
  "Reopen the tabs saved in the session file.
Return the number of tabs restored, or nil when there is nothing to
restore.  The file is kept: it is rewritten as the tabs change and
removed only when the last tab is closed.  An unreadable file is
removed."
  ;; From here on tab list changes are saved; see `embr--session-loaded'.
  (setq embr--session-loaded t)
  (when (and embr--use-custom-session
             embr-session-restore
             (not embr--incognito-flag)
             (file-exists-p embr--session-file))
    (let* ((data (condition-case err
                     (with-temp-buffer
                       (insert-file-contents embr--session-file)
                       (json-parse-string (buffer-string)
                                          :object-type 'alist
                                          :array-type 'list))
                   (error
                    (message "embr: ignoring unreadable session file (%s)"
                             (error-message-string err))
                    (ignore-errors (delete-file embr--session-file))
                    nil)))
           ;; Support both the old format (a plain URL array) and the
           ;; current one; ignore anything that is not a URL string.
           (urls (seq-filter #'stringp
                             (cond ((not (listp data)) nil)
                                   ((alist-get 'urls data))
                                   (t data))))
           (active (let ((a (and (listp data) (alist-get 'active data))))
                     (if (and (integerp a) (<= 0 a) (< a (length urls)))
                         a
                       0)))
           (count 0))
      (when urls
        ;; Navigate the initial tab to the first URL.
        (embr--send-sync `((cmd . "navigate") (url . ,(car urls))))
        (setq count 1)
        ;; Open the remaining URLs as tabs without waiting for each to
        ;; load, so a slow site does not hold up the whole restore.
        (dolist (url (cdr urls))
          (let ((r (embr--send-sync `((cmd . "new-tab") (url . ,url)
                                      (wait . :false)))))
            (when (alist-get 'ok r)
              (setq count (1+ count)))))
        ;; Switch to the tab that was active when the session was saved.
        (embr--send-sync `((cmd . "switch-tab") (index . ,active)))
        count))))

(defun embr--kill-emacs-cleanup ()
  "Save the session and stop every daemon before Emacs exits.
Emacs only hangs up on its subprocesses when it exits; asking the
daemon to quit instead lets it close the browser and remove its
runtime files and any incognito profile."
  (dolist (buf (list embr--normal-buffer embr--incognito-buffer))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (embr--save-session)
        (embr--shutdown-daemon 2.0)))))

(add-hook 'kill-emacs-hook #'embr--kill-emacs-cleanup)

(defun embr-quit ()
  "Shut down the daemon and kill the embr buffer."
  (interactive)
  ;; `embr--kill-buffer-cleanup' on `kill-buffer-hook' does the work,
  ;; whichever way the buffer is killed.
  (kill-buffer (current-buffer)))

(defun embr-mouse-handler (event)
  "Handle mouse press, track drag, and forward to browser.
Dispatch method depends on `embr-click-method'."
  (interactive "e")
  (pcase embr-click-method
    ('immediate (embr--mouse-immediate event))
    (_ (embr--mouse-atomic event))))

(defun embr--mouse-immediate (event)
  "Send mousedown immediately, then mouseup on release."
  (let* ((start-posn (event-start event))
         (start-xy (posn-object-x-y start-posn))
         (start-x (car start-xy))
         (start-y (cdr start-xy)))
    (when (and start-x start-y)
      (embr--send `((cmd . "mousedown") (x . ,start-x) (y . ,start-y)) nil)
      (let ((end-x start-x)
            (end-y start-y)
            (ev nil))
        (track-mouse
          (while (progn
                   (setq ev (read-event))
                   (mouse-movement-p ev))
            (let* ((posn (event-start ev))
                   (xy (posn-object-x-y posn)))
              (when xy
                (setq end-x (car xy) end-y (cdr xy))))))
        (when (and ev (listp ev))
          (let* ((posn (event-end ev))
                 (xy (posn-object-x-y posn)))
            (when xy
              (setq end-x (car xy) end-y (cdr xy)))))
        (embr--send `((cmd . "mouseup") (x . ,end-x) (y . ,end-y))
                           #'embr--action-callback)))))

(defun embr--mouse-atomic (event)
  "Defer mousedown until drag is detected; use atomic click otherwise.
Better compatibility with iframe widgets like Cloudflare Turnstile."
  (let* ((start-posn (event-start event))
         (start-xy (posn-object-x-y start-posn))
         (start-x (car start-xy))
         (start-y (cdr start-xy)))
    (when (and start-x start-y)
      (let ((end-x start-x)
            (end-y start-y)
            (dragged nil)
            (ev nil))
        (track-mouse
          (while (progn
                   (setq ev (read-event))
                   (mouse-movement-p ev))
            (let* ((posn (event-start ev))
                   (xy (posn-object-x-y posn)))
              (when xy
                (unless dragged
                  (setq dragged t)
                  (embr--send `((cmd . "mousedown") (x . ,start-x) (y . ,start-y)) nil))
                (setq end-x (car xy) end-y (cdr xy))))))
        (when (and ev (listp ev))
          (let* ((posn (event-end ev))
                 (xy (posn-object-x-y posn)))
            (when xy
              (setq end-x (car xy) end-y (cdr xy)))))
        (if dragged
            (embr--send `((cmd . "mouseup") (x . ,end-x) (y . ,end-y))
                               #'embr--action-callback)
          (embr--send `((cmd . "click") (x . ,start-x) (y . ,start-y))
                             #'embr--action-callback))))))

(defvar embr--context-menu-coords nil
  "Dynamic click coordinates used by context-menu actions.")

(defun embr--context-menu-download ()
  "Download the link at the context-menu click coordinates."
  (interactive)
  (if (null embr--context-menu-coords)
      (embr--download-via-hints)
    (embr--send `((cmd . "link-at-point")
                  (x . ,(car embr--context-menu-coords))
                  (y . ,(cdr embr--context-menu-coords)))
                (lambda (resp)
                  (let ((href (alist-get 'href resp)))
                    (if href
                        (embr--download-url href)
                      (embr--download-via-hints)))))))

(defun embr--context-menu-open-url ()
  "Open link at the context-menu click, or prompt for a URL."
  (interactive)
  (if (null embr--context-menu-coords)
      (call-interactively #'embr-navigate)
    (let* ((resp (embr--send-sync `((cmd . "link-at-point")
                                    (x . ,(car embr--context-menu-coords))
                                    (y . ,(cdr embr--context-menu-coords)))))
           (err (alist-get 'error resp))
           (href (alist-get 'href resp)))
      (if err
          (progn
            (message "embr: %s" err)
            (call-interactively #'embr-navigate))
        (if href
            (embr-navigate href)
          (call-interactively #'embr-navigate))))))

(defvar embr--context-menu-map
  (let ((map (make-sparse-keymap)))
    (define-key map [open-url] '(menu-item "Open URL" embr--context-menu-open-url))
    (define-key-after map [reload] '(menu-item "Reload" embr-refresh) 'open-url)
    (define-key-after map [back] '(menu-item "Back" embr-back) 'reload)
    (define-key-after map [forward] '(menu-item "Forward" embr-forward) 'back)
    (define-key-after map [download] '(menu-item "Download" embr--context-menu-download) 'forward)
    (define-key-after map [download-url] '(menu-item "Download URL" embr-download-url) 'download)
    (define-key-after map [print-pdf] '(menu-item "Print PDF" embr-print-pdf) 'download-url)
    (define-key-after map [screenshot] '(menu-item "Screenshot" embr-screenshot) 'print-pdf)
    (define-key-after map [reader] '(menu-item "Reader" embr-reader) 'screenshot)
    (define-key-after map [view-text] '(menu-item "View text" embr-view-text) 'reader)
    (define-key-after map [open-in-eww] '(menu-item "Open in eww" embr-open-in-eww) 'view-text)
    (define-key-after map [view-source] '(menu-item "View source" embr-view-source) 'open-in-eww)
    (define-key-after map [page-info] '(menu-item "Page info" embr-page-info) 'view-source)
    map)
  "Context menu keymap for mouse actions in `embr-mode'.")

(defun embr--mouse-context-menu (event)
  "Show mouse context menu at EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (embr--context-menu-coords (posn-object-x-y posn)))
    (popup-menu embr--context-menu-map event)))

(defun embr--mouse-open-link-new-tab (event)
  "Open the link at EVENT in a new tab."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn)))
    (if (null xy)
        (message "embr: no link under pointer")
      (embr--send `((cmd . "link-at-point")
                    (x . ,(car xy))
                    (y . ,(cdr xy)))
                  (lambda (resp)
                    (if-let* ((err (alist-get 'error resp)))
                        (message "embr: %s" err)
                      (if-let* ((href (alist-get 'href resp)))
                          (embr-new-tab href)
                        (message "embr: no link under pointer"))))))))


(defun embr--scroll-delta ()
  "Return the scroll delta in pixels."
  embr-scroll-step)

(defun embr--scroll-behavior ()
  "Return the scroll behavior string based on `embr-scroll-method'."
  (pcase embr-scroll-method
    ('smooth "smooth")
    (_ "instant")))

(defun embr--wheel-scroll (event delta-x delta-y)
  "Scroll the page by DELTA-X and DELTA-Y pixels at the position of EVENT."
  (let ((xy (posn-object-x-y (event-start event))))
    (embr--send `((cmd . "scroll")
                  (x . ,(or (car xy) 0)) (y . ,(or (cdr xy) 0))
                  (delta_x . ,delta-x) (delta_y . ,delta-y)
                  (behavior . ,(embr--scroll-behavior)))
                #'embr--action-callback)))

(defun embr-scroll-down (event)
  "Scroll down in the browser on mouse wheel EVENT."
  (interactive "e")
  (embr--wheel-scroll event 0 (embr--scroll-delta)))

(defun embr-scroll-up (event)
  "Scroll up in the browser on mouse wheel EVENT."
  (interactive "e")
  (embr--wheel-scroll event 0 (- (embr--scroll-delta))))

(defun embr-scroll-left (event)
  "Scroll left in the browser on horizontal mouse wheel EVENT."
  (interactive "e")
  (embr--wheel-scroll event (- (embr--scroll-delta)) 0))

(defun embr-scroll-right (event)
  "Scroll right in the browser on horizontal mouse wheel EVENT."
  (interactive "e")
  (embr--wheel-scroll event (embr--scroll-delta) 0))

;; ── Hover tracking ────────────────────────────────────────────────

(defun embr--hover-tick (buf)
  "Send the mouse position to the browser if it moved.
BUF is the embr buffer that owns this timer.  Nothing is sent while
the pointer is outside the window showing BUF, or while it rests."
  (when (and (buffer-live-p buf) (eq (current-buffer) buf))
    (with-current-buffer buf
      (when (and embr--process (process-live-p embr--process))
        (pcase-let ((`(,img-x . ,img-y) (embr--pointer-image-coords)))
          (when (and img-x
                     (not (and (eql img-x embr--hover-last-x)
                               (eql img-y embr--hover-last-y))))
            ;; Distance threshold: filter sub-pixel jitter.
            (let* ((dx (- img-x (or embr--hover-last-x img-x)))
                   (dy (- img-y (or embr--hover-last-y img-y)))
                   (dist (sqrt (+ (* dx dx) (* dy dy))))
                   ;; Rate self-throttle: use the minimum rate under pressure.
                   (rate (if embr--pressure embr-hover-rate-min embr-hover-rate))
                   (min-interval (/ 1.0 rate))
                   (now (float-time)))
              (when (and (>= dist embr-hover-move-threshold-px)
                         (or (null embr--hover-last-send-time)
                             (>= (- now embr--hover-last-send-time)
                                 min-interval)))
                (setq embr--hover-last-x img-x
                      embr--hover-last-y img-y
                      embr--hover-last-send-time now)
                ;; Fire-and-forget: hover updates want no reply.
                (embr--send-no-callback
                 `((cmd . "mousemove") (x . ,img-x) (y . ,img-y)))))))))))


(defun embr--hover-start ()
  "Start the hover tracking timer."
  (embr--hover-stop)
  (let ((buf (current-buffer)))
    (setq embr--hover-timer
          (run-at-time 0 (/ 1.0 embr-hover-rate)
                       (lambda () (embr--hover-tick buf))))))

(defun embr--hover-stop ()
  "Stop the hover tracking timer."
  (when embr--hover-timer
    (cancel-timer embr--hover-timer)
    (setq embr--hover-timer nil
          embr--hover-last-x nil
          embr--hover-last-y nil
          embr--hover-last-send-time nil
          embr--pressure nil)))


;; ── Render timer ──────────────────────────────────────────────────

(defun embr--render-tick (buf)
  "Render the latest pending frame, if any.
BUF is the embr buffer that owns this timer."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq embr--render-timer nil)
      (when embr--pending-frame
        (let ((frame embr--pending-frame))
          (setq embr--pending-frame nil
                embr--render-last-time (float-time))
          (embr--handle-frame frame))))))

(defun embr--render-schedule ()
  "Arm a one-shot render of `embr--pending-frame', rate-limited to `embr-fps'.
The timer exists only while a frame is waiting, so an idle session
costs no periodic wakeups."
  (unless embr--render-timer
    (let* ((buf (current-buffer))
           (interval (/ 1.0 (max 1 embr-fps)))
           (delay (max 0.0 (- (+ embr--render-last-time interval)
                              (float-time)))))
      (setq embr--render-timer
            (run-at-time delay nil (lambda () (embr--render-tick buf)))))))

(defun embr--render-stop ()
  "Cancel any scheduled render and drop the pending frame."
  (when embr--render-timer
    (cancel-timer embr--render-timer)
    (setq embr--render-timer nil))
  (setq embr--pending-frame nil))

;; ── Link hints ─────────────────────────────────────────────────────

(defun embr--hint-action-prompt (action)
  "Return minibuffer prompt for hint ACTION."
  (pcase action
    ('follow "Hint: ")
    ('download "Download hint: ")
    ('copy "Copy link hint: ")
    (_ "Hint: ")))

(defun embr--hint-empty-message (action)
  "Return message shown when no hints exist for ACTION."
  (pcase action
    ('follow "embr: no clickable elements found")
    (_ "embr: no links found")))

(defun embr--hint-descriptions (hints)
  "Build completion descriptions from HINTS."
  (mapcar (lambda (h)
            (format "%s: %s"
                    (alist-get 'tag h)
                    (or (alist-get 'text h) "")))
          hints))

(defun embr--hint-valid-list-p (hints)
  "Return t if HINTS is non-empty and every hint has a tag string."
  (and (listp hints)
       hints
       (cl-every (lambda (h)
                   (let ((tag (alist-get 'tag h)))
                     (and (stringp tag)
                          (not (string-empty-p tag)))))
                 hints)))

(defun embr--hint-cancel-timer ()
  "Cancel the current hint timer, if any."
  (when embr--hint-read-timer
    (cancel-timer embr--hint-read-timer)
    (setq embr--hint-read-timer nil)))

(defun embr--hint-abort-session ()
  "Cancel and invalidate the active hint session."
  (embr--hint-cancel-timer)
  (setq embr--hint-session-id (1+ embr--hint-session-id)
        embr--hint-retry-count 0
        embr--hint-action nil
        embr--hint-session-hints nil
        embr--hints nil))

(defun embr--hint-current-session-p (session-id)
  "Return t if SESSION-ID matches the current hint session."
  (= session-id embr--hint-session-id))

(defun embr--hint-schedule (session-id delay function)
  "Run FUNCTION for SESSION-ID after DELAY seconds.
FUNCTION is called in the owning embr buffer."
  (embr--hint-cancel-timer)
  (let ((buf (current-buffer)))
    (setq embr--hint-read-timer
          (run-at-time
           delay nil
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (when (embr--hint-current-session-p session-id)
                   (setq embr--hint-read-timer nil)
                   (funcall function session-id)))))))))

(defun embr--hint-finish-session ()
  "Clear hint overlays and reset hint session state."
  (embr--send-no-callback '((cmd . "hints-clear")))
  (embr--hint-abort-session))

(defun embr--hint-find-choice (hints chosen)
  "Return selected hint from HINTS for completion string CHOSEN."
  (when (and chosen (string-match "\\`\\([^:]+\\):" chosen))
    (let ((tag (match-string 1 chosen)))
      (seq-find (lambda (h)
                  (string= (alist-get 'tag h) tag))
                hints))))

(defun embr--hint-apply-action (action hint)
  "Execute hint ACTION for HINT."
  (pcase action
    ('follow
     (embr--send `((cmd . "click")
                   (x . ,(alist-get 'x hint))
                   (y . ,(alist-get 'y hint)))
                 #'embr--action-callback))
    ('download
     (let ((href (alist-get 'href hint)))
       (if href
           (embr--download-url href)
         (message "embr: selected element is not a link"))))
    ('copy
     (let ((href (alist-get 'href hint)))
       (if href
           (progn
             (kill-new href)
             (message "Copied: %s" href))
         (message "embr: selected element is not a link"))))))

(defun embr--hint-retry-refresh (session-id)
  "Re-request hints for SESSION-ID and try reading again."
  (when (embr--hint-current-session-p session-id)
    (let ((resp (embr--send-sync '((cmd . "hints")))))
      (if-let* ((err (alist-get 'error resp)))
          (progn
            (message "embr error: %s" err)
            (embr--hint-finish-session))
        (let ((hints (alist-get 'hints resp)))
          (setq embr--hints hints
                embr--hint-session-hints hints)
          (embr--hint-read-session session-id))))))

(defun embr--hint-maybe-retry (session-id)
  "Retry hint collection for SESSION-ID when session state is invalid."
  (if (< embr--hint-retry-count embr--hint-max-retries)
      (progn
        (setq embr--hint-retry-count (1+ embr--hint-retry-count))
        (embr--hint-schedule session-id embr--hint-retry-delay
                             #'embr--hint-retry-refresh))
    (message "embr: hint retry failed; please try again")
    (embr--hint-finish-session)))

(defun embr--minibuffer-escape-setup ()
  "Bind ESC to abort in the current minibuffer."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map [escape] #'abort-recursive-edit)
    (use-local-map map)))

(defun embr--hint-read-session (session-id)
  "Prompt for and execute a hint selection for SESSION-ID."
  (when (embr--hint-current-session-p session-id)
    (let ((hints embr--hint-session-hints))
      (if (embr--hint-valid-list-p hints)
          (let ((action embr--hint-action)
                (chosen nil)
                (hint nil))
            (unwind-protect
                (progn
                  (setq chosen (condition-case nil
                                   (minibuffer-with-setup-hook
                                       #'embr--minibuffer-escape-setup
                                     (completing-read (embr--hint-action-prompt action)
                                                      (embr--hint-descriptions hints)
                                                      nil t))
                                 (quit nil)))
                  (setq hint (embr--hint-find-choice hints chosen)))
              (embr--hint-finish-session))
            (when hint
              (embr--hint-apply-action action hint)))
        (embr--hint-maybe-retry session-id)))))

(defun embr--hint-start-session (action hints)
  "Start a new hint ACTION session with HINTS."
  (embr--hint-cancel-timer)
  (setq embr--hint-session-id (1+ embr--hint-session-id)
        embr--hint-retry-count 0
        embr--hint-action action
        embr--hint-session-hints hints
        embr--hints hints)
  ;; Brief pause for the hint overlay frame to arrive.
  (embr--hint-schedule embr--hint-session-id embr--hint-initial-read-delay
                       #'embr--hint-read-session))

(defun embr--hint-start (action)
  "Request hints and begin hint ACTION selection."
  (let ((resp (embr--send-sync '((cmd . "hints")))))
    (if-let* ((err (alist-get 'error resp)))
        (message "embr error: %s" err)
      (let ((hints (alist-get 'hints resp)))
        (if (embr--hint-valid-list-p hints)
            (embr--hint-start-session action hints)
          (message "%s" (embr--hint-empty-message action)))))))

(defun embr-follow-hint ()
  "Show link hints on all clickable elements, then follow the chosen one."
  (interactive)
  (embr--hint-start 'follow))

;; ── Text extraction ────────────────────────────────────────────────

(defun embr-view-text ()
  "Extract page text and display in a separate buffer."
  (interactive)
  (embr--send '((cmd . "text"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "embr error: %s" err)
                         (let ((text (alist-get 'text resp))
                               (buf (get-buffer-create "*embr-text*")))
                           (with-current-buffer buf
                             (let ((inhibit-read-only t))
                               (erase-buffer)
                               (insert text))
                             (goto-char (point-min))
                             (view-mode 1))
                           (display-buffer buf))))))

(defun embr-view-source ()
  "Fetch page source and display in a separate buffer."
  (interactive)
  (embr--send '((cmd . "source"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "embr error: %s" err)
                         (let ((html (alist-get 'html resp))
                               (buf (get-buffer-create "*embr-source*")))
                           (with-current-buffer buf
                             (let ((inhibit-read-only t))
                               (erase-buffer)
                               (insert html))
                             (goto-char (point-min))
                             (html-mode)
                             (view-mode 1))
                           (display-buffer buf))))))

(defun embr-open-in-eww ()
  "Open the current page URL in eww."
  (interactive)
  (let ((url embr--current-url))
    (if (string-empty-p url)
        (user-error "No URL to open")
      (eww url)
      (message "Opened in eww: %s" url))))

(defun embr--pointer-image-coords (&optional clamp)
  "Return the mouse pointer position as image coordinates (X . Y), or nil.
Return nil when the pointer is on another frame or its position is
unknown, and when it is outside the window showing this buffer unless
CLAMP is non-nil, in which case the position is clamped to the
viewport (out-of-bounds coordinates confuse Playwright)."
  (pcase-let ((`(,frame ,px . ,py) (mouse-pixel-position)))
    (when (and frame px py (eq frame (selected-frame)))
      (let* ((win (get-buffer-window (current-buffer)))
             (edges (and win (window-inside-pixel-edges win))))
        (when edges
          (let ((x (- px (nth 0 edges)))
                (y (- py (nth 1 edges)))
                (w (or embr--viewport-width embr-default-width))
                (h (or embr--viewport-height embr-default-height)))
            (cond
             ((and (<= 0 x) (< x w) (<= 0 y) (< y h))
              (cons x y))
             (clamp
              (cons (max 0 (min x (1- w)))
                    (max 0 (min y (1- h))))))))))))

(defun embr--mouse-image-coords ()
  "Return the mouse position clamped to image coordinates (X . Y), or nil."
  (embr--pointer-image-coords t))

(defun embr--download-url (url)
  "Confirm and download URL via the browser."
  (let ((confirmed (read-string "Download: " url)))
    (when (and confirmed (not (string-empty-p confirmed)))
      (let ((dir (expand-file-name embr-download-directory)))
        (embr--send `((cmd . "download")
                      (url . ,confirmed)
                      (directory . ,dir))
                    (lambda (resp)
                      (if-let* ((err (alist-get 'error resp)))
                          (message "embr: %s" err)
                        (message "Saved: %s" (alist-get 'path resp)))))))))

(defun embr-download-url (url)
  "Download URL directly by entering it in the minibuffer."
  (interactive "sDownload URL: ")
  (unless (string-empty-p url)
    (let ((dir (expand-file-name embr-download-directory)))
      (embr--send `((cmd . "download")
                    (url . ,url)
                    (directory . ,dir))
                  (lambda (resp)
                    (if-let* ((err (alist-get 'error resp)))
                        (message "embr: %s" err)
                      (message "Saved: %s" (alist-get 'path resp))))))))

(defun embr-download ()
  "Download the link under the mouse cursor.
If the mouse is not over a link, fall back to hint selection.
With prefix argument, prompt for a URL instead."
  (interactive)
  (if current-prefix-arg
      (call-interactively #'embr-download-url)
    (let ((coords (embr--mouse-image-coords)))
      (if (null coords)
          (embr--download-via-hints)
        (embr--send `((cmd . "link-at-point")
                      (x . ,(car coords))
                      (y . ,(cdr coords)))
                    (lambda (resp)
                      (let ((href (alist-get 'href resp)))
                        (if href
                            (embr--download-url href)
                          (embr--download-via-hints)))))))))

(defun embr--download-via-hints ()
  "Show link hints, then download the chosen link."
  (embr--hint-start 'download))

(defun embr-copy-url ()
  "Copy the current page URL to the kill ring."
  (interactive)
  (let* ((resp (embr--send-sync '((cmd . "query-url"))))
         (url (or (alist-get 'url resp) embr--current-url)))
    (embr--update-metadata resp)
    (kill-new url)
    (message "Copied: %s" url)))

(defun embr--header-line-click (event)
  "Copy current URL and prompt for navigation from EVENT."
  (interactive "e")
  (ignore event)
  (embr-copy-url)
  (call-interactively #'embr-navigate))

;; ── Resolution toggle ─────────────────────────────────────────────


;; ── External player ───────────────────────────────────────────────

(defun embr-play-external ()
  "Run `embr-external-command' with the current page URL."
  (interactive)
  (let* ((resp (embr--send-sync '((cmd . "query-url"))))
         (url (or (alist-get 'url resp) embr--current-url)))
    (embr--update-metadata resp)
    (if (string-empty-p url)
        (message "embr: no URL to play")
      (let ((cmd (format embr-external-command (shell-quote-argument url))))
        (message "Running: %s" cmd)
        (start-process-shell-command "embr-player" nil cmd)))))

;; ── Find in page ───────────────────────────────────────────────────

(defvar embr--search-query "" "Current find-in-page query.")
(defvar embr--searching nil "Non-nil when in a search sequence.")
(defvar embr--search-direction 'forward
  "Direction of the last initiated search, either `forward' or `backward'.")

(defun embr--maybe-end-search ()
  "Clear search state if the next command is not a search command."
  (unless (memq this-command '(embr-isearch-forward
                               embr-isearch-backward
                               embr-vimium-search-forward
                               embr-vimium-search-backward
                               embr-vimium-search-next
                               embr-vimium-search-previous))
    (setq embr--searching nil)))

(defun embr--find-on-page (backwards)
  "Run window.find() with the current search query.  Search BACKWARDS if non-nil."
  (setq embr--searching t)
  ;; A JSON string literal is a valid JS string literal, so this
  ;; escapes quotes, backslashes and newlines alike.
  (let ((literal (substring (json-serialize (vector embr--search-query))
                            1 -1)))
    (embr--send
     `((cmd . "js")
       (expr . ,(format "window.find(%s, false, %s, true)"
                        literal (if backwards "true" "false"))))
     (lambda (resp)
       (if-let* ((err (alist-get 'error resp)))
           (message "embr find error: %s" err)
         (if (eq (alist-get 'result resp) :false)
             (message "embr: no more matches")
           (message "Search: %s" embr--search-query)))))))

(defun embr-isearch-forward ()
  "Search forward.  First call prompts for query; repeating finds next match."
  (interactive)
  (setq embr--search-direction 'forward)
  (if (and embr--searching
           (not (string-empty-p embr--search-query)))
      (embr--find-on-page nil)
    (setq embr--searching nil)
    (let ((query (read-string "Search: " embr--search-query)))
      (unless (string-empty-p query)
        (setq embr--search-query query)
        (embr--find-on-page nil)))))

(defun embr-isearch-backward ()
  "Search backward.  First call prompts for query; repeating finds previous match."
  (interactive)
  (setq embr--search-direction 'backward)
  (if (and embr--searching
           (not (string-empty-p embr--search-query)))
      (embr--find-on-page t)
    (setq embr--searching nil)
    (let ((query (read-string "Search backward: " embr--search-query)))
      (unless (string-empty-p query)
        (setq embr--search-query query)
        (embr--find-on-page t)))))

(defun embr-vimium-search-forward ()
  "Prompt for a query and search forward, vim-style.
Unlike `embr-isearch-forward', always prompt; use
`embr-vimium-search-next' to repeat."
  (interactive)
  (setq embr--search-direction 'forward)
  (let ((query (read-string "Search: " embr--search-query)))
    (unless (string-empty-p query)
      (setq embr--search-query query)
      (embr--find-on-page nil))))

(defun embr-vimium-search-backward ()
  "Prompt for a query and search backward, vim-style.
Unlike `embr-isearch-backward', always prompt; use
`embr-vimium-search-next' to repeat."
  (interactive)
  (setq embr--search-direction 'backward)
  (let ((query (read-string "Search backward: " embr--search-query)))
    (unless (string-empty-p query)
      (setq embr--search-query query)
      (embr--find-on-page t))))

(defun embr-vimium-search-next ()
  "Repeat the last search in the same direction, like vim's n."
  (interactive)
  (if (string-empty-p embr--search-query)
      (message "embr: no previous search")
    (embr--find-on-page (eq embr--search-direction 'backward))))

(defun embr-vimium-search-previous ()
  "Repeat the last search in the opposite direction, like vim's N."
  (interactive)
  (if (string-empty-p embr--search-query)
      (message "embr: no previous search")
    (embr--find-on-page (not (eq embr--search-direction 'backward)))))

;; ── Tab bar ────────────────────────────────────────────────────────

(defvar embr--tab-label-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'embr--tab-bar-click)
    (define-key map [tab-line mouse-1] #'embr--tab-bar-click)
    map)
  "Keymap for clickable tab labels in the tab bar.")

(defvar embr--tab-close-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'embr--tab-bar-close)
    (define-key map [tab-line mouse-1] #'embr--tab-bar-close)
    map)
  "Keymap for tab close buttons in the tab bar.")

(defvar embr--header-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'embr--header-line-click)
    (define-key map [mouse-1] #'embr--header-line-click)
    map)
  "Keymap for clickable header-line actions.")

(defun embr--truncate-tab-title (title max-len)
  "Truncate TITLE to MAX-LEN chars, adding ellipsis if needed."
  (if (> (length title) max-len)
      (concat (substring title 0 (- max-len 1)) "\u2026")
    title))

(defun embr--render-tab-bar ()
  "Build a propertized tab bar string from `embr--tab-list'.
Tabs are equal width and fill the window, like i3 tabbed layout."
  (let* ((ntabs (length embr--tab-list))
         (total-px (window-pixel-width))
         (char-w (frame-char-width))
         ;; Separators: 1 char each between tabs.
         (sep-total (1- ntabs))
         (sep-px (* sep-total char-w))
         (avail-px (- total-px sep-px))
         (tab-idx 0)
         (parts nil))
    (dolist (tab embr--tab-list)
      (let* ((idx (alist-get 'index tab))
             (active (eq (alist-get 'active tab) t))
             ;; Pixel boundaries for this tab (no truncation loss).
             (left-px (/ (* avail-px tab-idx) ntabs))
             (right-px (/ (* avail-px (1+ tab-idx)) ntabs))
             (this-tab-px (- right-px left-px))
             ;; Close button " [x] " = 5 chars.
             (close-px (* 5 char-w))
             (label-px (- this-tab-px close-px))
             (label-chars (max 1 (/ label-px char-w)))
             (title (or (alist-get 'title tab)
                        (alist-get 'url tab)
                        "untitled"))
             (label (embr--truncate-tab-title title (1- label-chars)))
             (text (concat " " label))
             (text-px (* (length text) char-w))
             (pad-px (max 0 (- label-px text-px)))
             ;; Pixel-precise padding via display space spec.
             (padded (if (> pad-px 0)
                        (concat text (propertize " " 'display
                                                 `(space :width (,pad-px))))
                      text))
             (face (if active 'embr-tab-active 'embr-tab-inactive))
             (tab-str (propertize padded
                                  'face face
                                  'mouse-face 'highlight
                                  'keymap embr--tab-label-map
                                  'embr-tab-index idx
                                  'pointer 'hand))
             (close-str (propertize " [x] "
                                    'face 'embr-tab-close
                                    'mouse-face '(:background "red" :foreground "white")
                                    'keymap embr--tab-close-map
                                    'embr-tab-index idx
                                    'pointer 'hand)))
        (push (concat tab-str close-str) parts)
        (cl-incf tab-idx)))
    (mapconcat #'identity (nreverse parts)
               (propertize " " 'face 'embr-tab-bar))))

(defun embr--tab-bar-event-index (event)
  "Extract the `embr-tab-index' from a tab-line click EVENT."
  (let* ((posn (event-start event))
         (str (car (posn-string posn)))
         (str-pos (cdr (posn-string posn))))
    (when (and str str-pos)
      (get-text-property str-pos 'embr-tab-index str))))

(defun embr--tab-bar-click (event)
  "Switch to the tab clicked in the tab bar."
  (interactive "e")
  (when-let* ((idx (embr--tab-bar-event-index event)))
    (embr--send `((cmd . "switch-tab") (index . ,idx))
                (lambda (resp)
                  (embr--action-callback resp)
                  (embr--update-tab-list-from-resp resp)))))

(defun embr--tab-bar-close (event)
  "Close the tab clicked in the tab bar.
If this is the last tab, kill the embr buffer."
  (interactive "e")
  (when-let* ((idx (embr--tab-bar-event-index event)))
    (embr--send `((cmd . "close-tab") (index . ,idx))
                (lambda (resp)
                  (if (alist-get 'last_tab resp)
                      (kill-buffer (current-buffer))
                    (embr--action-callback resp)
                    (embr--update-tab-list-from-resp resp))))))

(defun embr--update-tab-list-from-resp (resp)
  "Update `embr--tab-list' from the `tabs' field in RESP if present.
Redraw the tab bar and keep the saved session current."
  (when-let* ((tabs (alist-get 'tabs resp)))
    (setq embr--tab-list
          (mapcar (lambda (v) (append v nil)) tabs))
    (embr--refresh-tab-bar)
    (embr--save-session)))

(defun embr--refresh-tab-list ()
  "Fetch the tab list from the daemon and update the tab bar.
The list is kept even without a tab bar: session saving needs it."
  (when (and embr--process (process-live-p embr--process))
    (let ((resp (embr--send-sync '((cmd . "list-tabs")))))
      (embr--update-tab-list-from-resp resp))))

(defun embr--refresh-tab-bar ()
  "Trigger a tab-line redisplay from cached tab list."
  (when (and embr-tab-bar embr--tab-list)
    (force-mode-line-update)))

;; ── Tabs ───────────────────────────────────────────────────────────

(defun embr-new-tab (url)
  "Open URL in a new tab, or search if the input does not look like a URL."
  (interactive (list (embr--read-url "URL/Search for new tab: ")))
  (let ((target (embr--maybe-search-url url)))
    ;; Every response carrying a tab list updates the tab bar, so the
    ;; generic callback is enough here.
    (when target
      (embr--url-history-add url target)
      (embr--send `((cmd . "new-tab") (url . ,target))
                  #'embr--action-callback))))

(defun embr-close-tab ()
  "Close the current tab.
If this is the last tab, forget the saved session and kill the embr
buffer: the user closed everything on purpose."
  (interactive)
  (embr--send '((cmd . "close-tab"))
              (lambda (resp)
                (if (alist-get 'last_tab resp)
                    (progn
                      (embr--clear-saved-session)
                      (kill-buffer (current-buffer)))
                  (embr--action-callback resp)))))

(defun embr--switch-tab-relative (delta)
  "Switch to the tab DELTA positions from the active one, wrapping around."
  (embr--send '((cmd . "list-tabs"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr error: %s" err)
                  (let* ((tabs (alist-get 'tabs resp))
                         (n (length tabs))
                         (cur (seq-position tabs t
                                            (lambda (tab _)
                                              (eq (alist-get 'active tab) t)))))
                    (if (zerop n)
                        (message "embr: no tabs")
                      (embr--send `((cmd . "switch-tab")
                                    (index . ,(mod (+ (or cur 0) delta) n)))
                                  #'embr--action-callback)))))))

(defun embr-next-tab ()
  "Switch to the next tab."
  (interactive)
  (embr--switch-tab-relative 1))

(defun embr-prev-tab ()
  "Switch to the previous tab."
  (interactive)
  (embr--switch-tab-relative -1))

(defun embr-list-tabs ()
  "List all tabs and switch to the selected one."
  (interactive)
  (embr--send '((cmd . "list-tabs"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "embr error: %s" err)
                         (let* ((tabs (alist-get 'tabs resp))
                                (strs (mapcar
                                       (lambda (tab)
                                         (format "%s%d: %s"
                                                 (if (eq (alist-get 'active tab) t) "*" " ")
                                                 (alist-get 'index tab)
                                                 (or (alist-get 'title tab) (alist-get 'url tab))))
                                       tabs))
                                (chosen (completing-read "Tab: " strs nil t)))
                           (when (string-match "\\*?\\([0-9]+\\):" chosen)
                             (let ((idx (string-to-number (match-string 1 chosen))))
                               (embr--send `((cmd . "switch-tab") (index . ,idx))
                                                  #'embr--action-callback))))))))

;; ── Form fill ──────────────────────────────────────────────────────

(defun embr-fill (selector value)
  "Fill a form field matching CSS SELECTOR with VALUE."
  (interactive "sCSS selector: \nsValue: ")
  (embr--send `((cmd . "fill") (selector . ,selector) (value . ,value))
                     #'embr--action-callback))

;; ── Bookmarks ──────────────────────────────────────────────────────

(defun embr--bookmark-make-record ()
  "Create a bookmark record for the current embr page."
  (let ((resp (embr--send-sync '((cmd . "query-url")))))
    (embr--update-metadata resp)
    `(,(format "embr: %s" embr--current-title)
      (url . ,embr--current-url)
      (handler . embr--bookmark-handler))))

(defun embr--bookmark-handler (bookmark)
  "Jump to a embr BOOKMARK."
  (embr-browse (alist-get 'url (cdr bookmark))))

;; ── Clipboard bridge ──────────────────────────────────────────────

(defun embr-copy ()
  "Copy browser selection to Emacs kill ring and system clipboard."
  (interactive)
  (embr--send
   '((cmd . "js") (expr . "window.getSelection().toString()"))
   (lambda (resp)
     (if-let* ((err (alist-get 'error resp)))
         (message "embr copy error: %s" err)
       (let ((text (alist-get 'result resp)))
         (if (and text (not (equal text "")))
             (progn
               (kill-new text)
               (message "Copied: %s" (truncate-string-to-width text 60)))
           (message "embr: no selection to copy")))))))

(defun embr-paste ()
  "Paste from Emacs kill ring into the browser."
  (interactive)
  (let ((text (current-kill 0 t)))
    (if (and text (not (string-empty-p text)))
        (embr--send
         `((cmd . "js")
           (expr . ,(format "document.execCommand('insertText', false, %s)"
                            (json-serialize text))))
         #'embr--action-callback)
      (message "embr: kill ring empty"))))

;; ── Zoom ──────────────────────────────────────────────────────────

(defun embr-zoom-in ()
  "Zoom in the browser page."
  (interactive)
  (embr--send '((cmd . "zoom-in"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr: %s" err)
                  (setq embr--zoom-level (alist-get 'zoom resp))
                  (force-mode-line-update)
                  (message "Zoom: %d%%" (round (* embr--zoom-level 100)))))))

(defun embr-zoom-out ()
  "Zoom out the browser page."
  (interactive)
  (embr--send '((cmd . "zoom-out"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr: %s" err)
                  (setq embr--zoom-level (alist-get 'zoom resp))
                  (force-mode-line-update)
                  (message "Zoom: %d%%" (round (* embr--zoom-level 100)))))))

(defun embr-zoom-reset ()
  "Reset browser page zoom to 100%."
  (interactive)
  (embr--send '((cmd . "zoom-reset"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr: %s" err)
                  (setq embr--zoom-level 1.0)
                  (force-mode-line-update)
                  (message "Zoom: reset")))))

;; ── Copy link ────────────────────────────────────────────────────

(defun embr-copy-link ()
  "Copy the link under the mouse cursor to the kill ring.
If the mouse is not over a link, fall back to hint selection."
  (interactive)
  (let ((coords (embr--mouse-image-coords)))
    (if (null coords)
        (embr--copy-link-via-hints)
      (embr--send `((cmd . "link-at-point")
                    (x . ,(car coords))
                    (y . ,(cdr coords)))
                  (lambda (resp)
                    (let ((href (alist-get 'href resp)))
                      (if href
                          (progn
                            (kill-new href)
                            (message "Copied: %s" href))
                        (embr--copy-link-via-hints))))))))

(defun embr--copy-link-via-hints ()
  "Show link hints, then copy the chosen link to the kill ring."
  (embr--hint-start 'copy))

;; ── Print to PDF ─────────────────────────────────────────────────

(defun embr-print-pdf ()
  "Save the current page as a PDF file."
  (interactive)
  (let ((dir (read-directory-name "Save PDF to: "
                                  (expand-file-name embr-download-directory))))
    (embr--send `((cmd . "print-pdf")
                  (directory . ,(expand-file-name dir)))
                (lambda (resp)
                  (if-let* ((err (alist-get 'error resp)))
                      (message "embr: %s" err)
                    (message "Saved: %s" (alist-get 'path resp)))))))

;; ── Page screenshot ──────────────────────────────────────────────

(defun embr-screenshot ()
  "Save a full-resolution screenshot of the current page."
  (interactive)
  (let* ((default-name (format "embr-%s-%s.png"
                               (replace-regexp-in-string
                                "[^a-zA-Z0-9_-]" "_"
                                (or embr--current-title "page"))
                               (format-time-string "%Y%m%d-%H%M%S")))
         (path (read-file-name "Save screenshot: "
                               (expand-file-name embr-download-directory)
                               nil nil default-name)))
    (embr--send `((cmd . "screenshot")
                  (path . ,(expand-file-name path)))
                (lambda (resp)
                  (if-let* ((err (alist-get 'error resp)))
                      (message "embr: %s" err)
                    (message "Saved: %s" (alist-get 'path resp)))))))

;; ── Mute/unmute ──────────────────────────────────────────────────

(defun embr-toggle-mute ()
  "Toggle mute on all audio and video elements."
  (interactive)
  (embr--send '((cmd . "toggle-mute"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr: %s" err)
                  (setq embr--muted-flag (eq (alist-get 'muted resp) t))
                  (force-mode-line-update)
                  (message "embr: %s"
                           (if embr--muted-flag "muted" "unmuted"))))))

;; ── Reader mode ──────────────────────────────────────────────────

(defun embr-reader ()
  "Extract article content and display in a readable buffer."
  (interactive)
  (embr--send '((cmd . "reader"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr: %s" err)
                  (let* ((data (alist-get 'reader resp))
                         (title (alist-get 'title data))
                         (byline (alist-get 'byline data))
                         (excerpt (alist-get 'excerpt data))
                         (html (alist-get 'html data))
                         (buf (get-buffer-create "*embr-reader*")))
                    (with-current-buffer buf
                      (let ((inhibit-read-only t))
                        (erase-buffer)
                        (when (and title (not (string-empty-p title)))
                          (insert (propertize title 'face 'bold) "\n"))
                        (when (and byline (not (string-empty-p byline)))
                          (insert (propertize byline 'face 'italic) "\n"))
                        (when (and excerpt (not (string-empty-p excerpt)))
                          (insert (propertize excerpt 'face 'shadow) "\n"))
                        (when (or title byline excerpt)
                          (insert "\n"))
                        (let ((start (point)))
                          (insert html)
                          (shr-render-region start (point-max))))
                      (goto-char (point-min))
                      (view-mode 1))
                    (display-buffer buf))))))

;; ── Page info ────────────────────────────────────────────────────

(defun embr-page-info ()
  "Display information about the current page."
  (interactive)
  (embr--send '((cmd . "page-info"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr: %s" err)
                  (let* ((info (alist-get 'info resp))
                         (buf (get-buffer-create "*embr-page-info*")))
                    (with-current-buffer buf
                      (let ((inhibit-read-only t))
                        (erase-buffer)
                        (insert (format "%-15s %s\n" "URL:" (alist-get 'url info)))
                        (insert (format "%-15s %s\n" "Title:" (alist-get 'title info)))
                        (insert (format "%-15s %s\n" "Protocol:" (alist-get 'protocol info)))
                        (insert (format "%-15s %s\n" "Domain:" (alist-get 'domain info)))
                        (insert (format "%-15s %s\n" "Cookies:" (alist-get 'cookies info)))
                        (insert (format "%-15s %sx%s\n" "Page size:"
                                        (alist-get 'page_width info)
                                        (alist-get 'page_height info)))
                        (insert (format "%-15s %s\n" "Scripts:" (alist-get 'scripts info)))
                        (insert (format "%-15s %s\n" "Stylesheets:" (alist-get 'stylesheets info)))
                        (insert (format "%-15s %s\n" "Images:" (alist-get 'images info)))
                        (insert (format "%-15s %s\n" "Iframes:" (alist-get 'iframes info)))
                        (insert (format "%-15s %s\n" "Content-Type:" (or (alist-get 'content_type info) ""))))
                      (goto-char (point-min))
                      (special-mode))
                    (display-buffer buf))))))

;; ── Proxy info ──────────────────────────────────────────────────

(defun embr-proxy-info ()
  "Display proxy routing rules for this session."
  (interactive)
  (if embr-proxy-rules
      (message "embr: proxy rules: %s"
               (mapconcat (lambda (r)
                            (format "%s -> %s://%s"
                                    (nth 0 r) (nth 1 r) (nth 2 r)))
                          embr-proxy-rules ", "))
    (message "embr: no proxy")))

;; ── Incognito mode ───────────────────────────────────────────────
;;
;; Uses the same `embr-mode' with buffer-local state.  The only
;; difference is the EMBR_INCOGNITO=1 env var (temp profile on the
;; Python side) and the `embr--incognito-flag' for header line display.

;;;###autoload
(defun embr-browse-incognito (url)
  "Launch an incognito embr session and navigate to URL.
Input that does not look like a URL is searched for."
  (interactive (list (embr--read-url "Incognito URL/Search: " t)))
  (unless (and (buffer-live-p embr--incognito-buffer)
               (embr--buffer-daemon-live-p embr--incognito-buffer))
    (embr--check-setup nil))
  (unless (buffer-live-p embr--incognito-buffer)
    (setq embr--incognito-buffer (generate-new-buffer "*embr incognito*"))
    (with-current-buffer embr--incognito-buffer
      (embr-mode)
      (setq embr--incognito-flag t)))
  (switch-to-buffer embr--incognito-buffer)
  (with-current-buffer embr--incognito-buffer
    (unless (and embr--process (process-live-p embr--process))
      (embr--finish-session-start (embr--start-session "embr incognito")
                                  "embr incognito"))
    (embr-navigate url)))

;; ── Key forwarding ─────────────────────────────────────────────────

(defun embr--translate-key (key)
  "Translate an Emacs KEY description to a Playwright key name."
  (pcase key
    ("RET" "Enter")
    ("TAB" "Tab")
    ("DEL" "Backspace")
    ("SPC" " ")
    ("C-v" "PageDown")
    ("M-v" "PageUp")
    ("C-n" "ArrowDown")
    ("C-p" "ArrowUp")
    ("C-b" "ArrowLeft")
    ("C-f" "ArrowRight")
    ("C-a" "Home")
    ("C-e" "End")
    ("C-d" "Delete")
    ("M-f" "Control+ArrowRight")
    ("M-b" "Control+ArrowLeft")
    ("<backspace>" "Backspace")
    ("<return>" "Enter")
    ("<tab>" "Tab")
    ("<backtab>" "Shift+Tab")
    ("<delete>" "Delete")
    ("<home>" "Home")
    ("<end>" "End")
    ("<up>" "ArrowUp")
    ("<down>" "ArrowDown")
    ("<left>" "ArrowLeft")
    ("<right>" "ArrowRight")
    ("<prior>" "PageUp")
    ("<next>" "PageDown")
    ("<escape>" "Escape")
    ("<f5>" "F5")
    ("M-<" "Home")
    ("M->" "End")
    (_ key)))

(defun embr-self-insert ()
  "Forward the key that invoked this command to the browser.
A printable character, ASCII or not, is typed as text; any other key
is translated to a Playwright key name with `embr--translate-key'."
  (interactive)
  (let ((ev last-command-event))
    (if (and (characterp ev) (>= ev 32) (/= ev 127))
        (embr--send `((cmd . "type") (text . ,(string ev)))
                    #'embr--action-callback)
      (let ((pw-key (embr--translate-key
                     (key-description (this-command-keys-vector)))))
        (if (= (length pw-key) 1)
            (embr--send `((cmd . "type") (text . ,pw-key))
                        #'embr--action-callback)
          (embr--send `((cmd . "key") (key . ,pw-key))
                      #'embr--action-callback))))))

;; ── Dispatch menu ─────────────────────────────────────────────────

(transient-define-prefix embr-dispatch-keys ()
  "Show top-level embr bindings."
  [["Emacs Motion"
    ("C-n" "Down" embr-self-insert :transient nil)
    ("C-p" "Up" embr-self-insert :transient nil)
    ("C-f" "Right" embr-self-insert :transient nil)
    ("C-b" "Left" embr-self-insert :transient nil)
    ("C-a" "Home" embr-self-insert :transient nil)
    ("C-e" "End" embr-self-insert :transient nil)
    ("C-d" "Delete" embr-self-insert :transient nil)
    ("M-f" "Word right" embr-self-insert :transient nil)
    ("M-b" "Word left" embr-self-insert :transient nil)
    ("M-<" "Top of page" embr-self-insert :transient nil)
    ("M->" "Bottom of page" embr-self-insert :transient nil)]
   ["Scroll / Page"
    ("C-v" "Page down" embr-self-insert :transient nil)
    ("M-v" "Page up" embr-self-insert :transient nil)]
   ["Zoom"
    ("C-=" "Zoom in" embr-zoom-in)
    ("C--" "Zoom out" embr-zoom-out)
    ("C-0" "Reset zoom" embr-zoom-reset)]
   ["Clipboard"
    ("M-w" "Copy" embr-copy)
    ("C-y" "Paste" embr-paste)]
   ["Search"
    ("C-s" "Search forward" embr-isearch-forward)
    ("C-r" "Search backward" embr-isearch-backward)]
   ["Other"
    ("C-l" "Navigate" embr-navigate)
    ("&"   "External player" embr-play-external)
    ("<f5>" "Refresh" embr-refresh)
    ("q" "Close menu" embr-dispatch-close)
    ("<escape>" "Close menu" embr-dispatch-close)]])

;; ── Privacy: data clearing ────────────────────────────────────────
;;
;; It seemed wise to just manually wipe state ourselves than trust a
;; Playwright/Chromium API to do it for us, when it comes to wiping tracks.
;;
;; Safety measures for delete operations:
;;
;; 1. Fixed base path -- the profile directory is derived from
;;    `embr--data-dir' ($XDG_DATA_HOME/embr or ~/.local/share/embr)
;;    and the configured engine, nothing else.
;; 2. Sanity check on entry -- `embr--data-dir-sane-p' verifies that
;;    the data directory is absolute and ends in /embr/ before anything
;;    is deleted.
;; 3. Per-path check -- every expanded glob result is verified to be
;;    inside the profile dir before deletion, refuses with error if not.
;; 4. Nothing is deleted while a daemon runs on the profile: Chromium
;;    would write the data back from memory when it exits.

(defun embr--profile-directory ()
  "Return the persistent browser profile directory for the configured engine.
The daemon keeps the Playwright Chromium profile in playwright-profile/
and the CloakBrowser profile in chromium-profile/, both under
`embr--data-dir'."
  (expand-file-name (if (eq embr-browser-engine 'chromium)
                        "playwright-profile"
                      "chromium-profile")
                    embr--data-dir-prefix))

(defun embr--profile-default-directory ()
  "Return the Default/ directory of the browser profile, with a trailing slash."
  (file-name-as-directory
   (expand-file-name "Default" (embr--profile-directory))))

(defun embr--buffer-daemon-live-p (buffer)
  "Return non-nil if the embr BUFFER has a running daemon."
  (and (buffer-live-p buffer)
       (let ((proc (buffer-local-value 'embr--process buffer)))
         (and proc (process-live-p proc)))))

(defun embr--profile-in-use-p ()
  "Return non-nil if a daemon is running on the persistent profile."
  (embr--buffer-daemon-live-p embr--normal-buffer))

(defun embr--check-profile-clearable ()
  "Signal an error unless profile data can safely be deleted now."
  (unless (embr--data-dir-sane-p embr--data-dir)
    (error "embr: profile path sanity check failed"))
  (when (embr--profile-in-use-p)
    (user-error "embr: quit the browser first; it holds the profile open and would write the data back")))

(defun embr--clear-profile-paths (globs description)
  "Delete GLOBS under the browser profile after confirmation.
GLOBS is a list of file/directory names to match.
DESCRIPTION is shown in the prompt."
  (embr--check-profile-clearable)
  (let ((profile-dir (embr--profile-default-directory)))
    (when (y-or-n-p (format "Clear %s? " description))
      (dolist (glob globs)
        (dolist (path (file-expand-wildcards
                       (expand-file-name glob profile-dir)))
          (unless (string-prefix-p profile-dir path)
            (error "embr: refusing to delete outside profile: %s" path))
          (if (file-directory-p path)
              (delete-directory path t)
            (delete-file path))))
      (message "embr: cleared %s" description))))

(defun embr-clear-cookies ()
  "Clear browser cookies."
  (interactive)
  (embr--clear-profile-paths '("Cookies*") "cookies"))

(defun embr-clear-cache ()
  "Clear browser cache."
  (interactive)
  (embr--clear-profile-paths '("Cache" "Code Cache") "cache"))

(defun embr-clear-local-storage ()
  "Clear browser local storage."
  (interactive)
  (embr--clear-profile-paths '("Local Storage") "local storage"))

(defun embr-clear-sessions ()
  "Clear browser session data."
  (interactive)
  (embr--clear-profile-paths '("Sessions") "sessions"))

(defun embr-clear-browser-history ()
  "Clear browser history."
  (interactive)
  (embr--clear-profile-paths '("History*") "browser history"))

(defun embr-clear-url-history ()
  "Clear URL bar history."
  (interactive)
  (when (y-or-n-p "Clear URL history? ")
    (setq embr--url-history nil)
    (message "embr: URL history cleared")))

(defun embr-clear-all ()
  "Delete the entire browser profile and clear URL history."
  (interactive)
  (embr--check-profile-clearable)
  (when (y-or-n-p "Delete entire browser profile and URL history? ")
    (let ((profile (embr--profile-directory)))
      (when (file-directory-p profile)
        (delete-directory profile t)))
    (setq embr--url-history nil)
    (message "embr: browser profile deleted, URL history cleared")))

(defun embr--chrome-navigate (url)
  "Navigate to chrome:// URL."
  (embr--send `((cmd . "navigate") (url . ,url))
              #'embr--action-callback))

(defun embr-chrome-settings ()
  "Open chrome://settings."
  (interactive)
  (embr--chrome-navigate "chrome://settings"))

(defun embr-chrome-extensions ()
  "Open chrome://extensions."
  (interactive)
  (embr--chrome-navigate "chrome://extensions"))

(defun embr-chrome-flags ()
  "Open chrome://flags."
  (interactive)
  (embr--chrome-navigate "chrome://flags"))

(defun embr-chrome-downloads ()
  "Open chrome://downloads."
  (interactive)
  (embr--chrome-navigate "chrome://downloads"))

(defun embr-chrome-history ()
  "Open chrome://history."
  (interactive)
  (embr--chrome-navigate "chrome://history"))

(defun embr-chrome-gpu ()
  "Open chrome://gpu."
  (interactive)
  (embr--chrome-navigate "chrome://gpu"))

(defun embr--chrome-internals-heading ()
  "Return the heading string for the chrome internals dispatch menu."
  (if (eq embr-browser-engine 'cloakbrowser)
      "Chrome Internals\
\nWarning: CloakBrowser patches Chromium heavily, so settings may be\
\ngrayed out or have no effect.  Switching to 'headed mode may help for\
\nsome pages.  For extension management, see README FAQ.  CloakBrowser\
\nis configured to be performant and private out of the box, so\
\nhopefully no serious tweaks needed :)"
    "Chrome Internals"))

(transient-define-prefix embr-dispatch-chrome ()
  "Show chrome:// internal pages."
  [:description embr--chrome-internals-heading
   ("s" "Settings" embr-chrome-settings)
   ("e" "Extensions" embr-chrome-extensions)
   ("f" "Flags" embr-chrome-flags)
   ("d" "Downloads" embr-chrome-downloads)
   ("h" "History" embr-chrome-history)
   ("g" "GPU" embr-chrome-gpu)
   ("q" "Close menu" embr-dispatch-close)
   ("<escape>" "Close menu" embr-dispatch-close)])

(defun embr-home ()
  "Navigate to `embr-home-url'."
  (interactive)
  (embr--send `((cmd . "navigate") (url . ,embr-home-url))
              #'embr--action-callback))

(defun embr-dispatch-close ()
  "Close the dispatch menu."
  (interactive))

(transient-define-prefix embr-dispatch ()
  "Show available embr browser commands."
  [["Navigation"
    ("g" "Reload" embr-refresh)
    ("l" "Back" embr-back)
    ("r" "Forward" embr-forward)
    ("<home>" "Home" embr-home)
    ("h" "History" embr-history-persistent)
    ("H" "Download history" embr-download-history)]
   ["Tabs"
    ("c" "New" embr-new-tab)
    ("x" "Close" embr-close-tab)
    ("]" "Next" embr-next-tab)
    ("[" "Previous" embr-prev-tab)
    ("s" "Switch" embr-list-tabs)
    ("m" "Mute/unmute" embr-toggle-mute)]
   ["Bookmarks"
    ("b" "Add" bookmark-set)
    ("j" "Jump" bookmark-jump)
    ("u" "Unbookmark" bookmark-delete)]
   ["Actions"
    ("o" "Open URL" embr-navigate)
    ("f" "Hint link" embr-follow-hint)
    ("w" "Copy URL" embr-copy-url)
    ("y" "Copy link" embr-copy-link)
    ("d" "Download" embr-download)
    ("D" "Download URL" embr-download-url)
    (":" "Execute JS" embr-execute-js)]
   ["Export"
    ("i" "Print PDF" embr-print-pdf)
    ("n" "Screenshot" embr-screenshot)
    ("a" "Reader" embr-reader)
    ("p" "Page info" embr-page-info)
    ("v" "View text" embr-view-text)
    ("e" "Open in eww" embr-open-in-eww)
    ("E" "View source" embr-view-source)]
   ["Privacy"
    ("t" "Proxy info" embr-proxy-info)
    ("1" "Clear cookies" embr-clear-cookies)
    ("2" "Clear cache" embr-clear-cache)
    ("3" "Clear local storage" embr-clear-local-storage)
    ("4" "Clear sessions" embr-clear-sessions)
    ("5" "Clear URL history" embr-clear-url-history)
    ("6" "Clear browser history" embr-clear-browser-history)
    ("0" "Clear all (nuclear)" embr-clear-all)]
   ["Other"
    ("k" "Kill embr" embr-quit)
    ("q" "Close menu" embr-dispatch-close)
    ("<escape>" "Close menu" embr-dispatch-close)
    ("z" "Chrome internals" embr-dispatch-chrome)
    ("?" "Top-level bindkeys" embr-dispatch-keys)]])

;; ── Keymap ─────────────────────────────────────────────────────────

(defvar embr-mode-map nil "Keymap for `embr-mode'.")
(setq embr-mode-map
  (let ((map (make-sparse-keymap)))
    ;; All printable characters → forward to browser.  The remap
    ;; catches every other self-inserting character (non-ASCII input)
    ;; that would otherwise hit the read-only buffer.
    (dolist (c (number-sequence 32 126))
      (define-key map (vector c) #'embr-self-insert))
    (define-key map [remap self-insert-command] #'embr-self-insert)
    ;; Override & for external player (like eww).
    (define-key map (kbd "&") #'embr-play-external)
    (define-key map (kbd "<f5>") #'embr-refresh)
    ;; Special keys → forward to browser.
    (dolist (key '("<return>" "<backspace>" "<tab>" "<backtab>" "<delete>"
                   "<home>" "<end>" "<up>" "<down>" "<left>" "<right>"
                   "<prior>" "<next>" "<escape>"))
      (define-key map (kbd key) #'embr-self-insert))

    ;; Emacs-style convenience bindings.
    (define-key map (kbd "C-v") #'embr-self-insert)
    (define-key map (kbd "M-v") #'embr-self-insert)
    (define-key map (kbd "C-l") #'embr-navigate)
    (define-key map (kbd "C-n") #'embr-self-insert)
    (define-key map (kbd "C-p") #'embr-self-insert)
    (define-key map (kbd "C-b") #'embr-self-insert)
    (define-key map (kbd "C-f") #'embr-self-insert)
    (define-key map (kbd "C-a") #'embr-self-insert)
    (define-key map (kbd "C-e") #'embr-self-insert)
    (define-key map (kbd "C-d") #'embr-self-insert)
    (define-key map (kbd "M-f") #'embr-self-insert)
    (define-key map (kbd "M-b") #'embr-self-insert)
    (define-key map (kbd "M-<") #'embr-self-insert)
    (define-key map (kbd "M->") #'embr-self-insert)
    (define-key map (kbd "M-w") #'embr-copy)
    (define-key map (kbd "C-y") #'embr-paste)
    (define-key map (kbd "C-s") #'embr-isearch-forward)
    (define-key map (kbd "C-r") #'embr-isearch-backward)

    ;; Zoom bindings.
    (define-key map (kbd "C-=") #'embr-zoom-in)
    (define-key map (kbd "C--") #'embr-zoom-out)
    (define-key map (kbd "C-0") #'embr-zoom-reset)

    ;; Mouse → forward to browser.
    (define-key map [down-mouse-1] #'embr-mouse-handler)
    (define-key map [down-mouse-2] #'embr--mouse-open-link-new-tab)
    (define-key map [down-mouse-3] #'embr--mouse-context-menu)
    (define-key map [mouse-2] #'ignore)
    (define-key map [mouse-3] #'ignore)

    (define-key map [wheel-down] #'embr-scroll-down)
    (define-key map [wheel-up] #'embr-scroll-up)
    (define-key map [wheel-left] #'embr-scroll-left)
    (define-key map [wheel-right] #'embr-scroll-right)

    ;; Dispatch menu (default C-c).
    (define-key map (kbd embr-dispatch-key) #'embr-dispatch)
    map))

;; ── Major mode ─────────────────────────────────────────────────────

(define-derived-mode embr-mode nil "embr"
  "Major mode for the embr browser buffer."
  :group 'embr
  ;; Disable hl-line-mode: its line highlight overrides tab bar faces,
  ;; making the active tab indistinguishable from inactive tabs.
  (setq-local global-hl-line-mode nil)
  (hl-line-mode -1)
  ;; Make per-session state buffer-local so multiple instances
  ;; (e.g. normal + incognito) each have their own daemon.
  (setq-local embr--process nil)
  (setq-local embr--buffer (current-buffer))
  (setq-local embr--response-chunks nil)
  (setq-local embr--pending-callbacks nil)
  (setq-local embr--request-id 0)
  (setq-local embr--quit-requested nil)
  (setq-local embr--current-url "")
  (setq-local embr--current-title "")
  (setq-local embr--viewport-width nil)
  (setq-local embr--viewport-height nil)
  (setq-local embr--frame-path nil)
  (setq-local embr--hints nil)
  (setq-local embr--hint-session-id 0)
  (setq-local embr--hint-read-timer nil)
  (setq-local embr--hint-retry-count 0)
  (setq-local embr--hint-action nil)
  (setq-local embr--hint-session-hints nil)
  (setq-local embr--hover-timer nil)
  (setq-local embr--hover-last-x nil)
  (setq-local embr--hover-last-y nil)
  (setq-local embr--hover-last-send-time nil)
  (setq-local embr--pending-frame nil)
  (setq-local embr--render-timer nil)
  (setq-local embr--render-last-time 0.0)
  (setq-local embr--default-image nil)
  (setq-local embr--pressure nil)
  (setq-local embr--active-backend nil)
  (setq-local embr--canvas-image nil)
  (setq-local embr--canvas-socket nil)
  (setq-local embr--canvas-recv-chunks nil)
  (setq-local embr--canvas-recv-len 0)
  (setq-local embr--canvas-recv-expected nil)
  (setq-local embr--canvas-last-seq 0)
  (setq-local embr--canvas-stream-id 0)
  (setq-local embr--canvas-mutation-flag nil)
  (setq-local embr--canvas-stale-count 0)
  (setq-local embr--canvas-error-count 0)
  (setq-local embr--canvas-frame-count 0)
  (setq-local embr--canvas-resize-count 0)
  (setq-local embr--default-frame-count 0)
  (setq-local embr--zoom-level 1.0)
  (setq-local embr--incognito-flag nil)
  (setq-local embr--proxy-active nil)
  (setq-local embr--resize-timer nil)
  (setq-local embr--muted-flag nil)
  (setq-local embr--tab-list nil)
  (setq-local embr--session-loaded nil)
  (setq-local buffer-read-only t)
  ;; Frames replace the buffer text many times a second; recording
  ;; undo entries for that would only churn memory.
  (setq-local buffer-undo-list t)
  (setq-local cursor-type nil)
  (setq-local void-text-area-pointer 'arrow)
  (setq-local pointer-shape 'arrow)
  (setq-local bookmark-make-record-function #'embr--bookmark-make-record)
  (setq-local header-line-format
              '(:eval (let ((url (if (> (length embr--current-url) 40)
                                     (concat (substring embr--current-url 0 40) "...")
                                   embr--current-url)))
                        (propertize
                         (concat
                          (when (bound-and-true-p embr-vimium-mode)
                            (if embr-vimium--insert-mode
                                (propertize " INSERT " 'face '(:background "#22863a" :foreground "white"))
                              (propertize " NORMAL " 'face '(:background "#0366d6" :foreground "white"))))
                          (when embr--muted-flag
                            (propertize " MUTED " 'face '(:background "red" :foreground "white")))
                          (when embr--incognito-flag
                            (propertize " INCOGNITO " 'face '(:background "purple" :foreground "white")))
                          (when (embr--url-proxied-p embr--current-url)
                            (propertize " PROXY " 'face '(:background "red" :foreground "white")))
                          " "
                          (propertize url 'face 'shadow)
                          (unless embr-tab-bar
                            (unless (string-empty-p embr--current-title)
                              (concat
                               (propertize " — " 'face 'shadow)
                               (propertize embr--current-title 'face 'bold))))
                          (unless (= embr--zoom-level 1.0)
                            (format " [%d%%]" (round (* embr--zoom-level 100)))))
                         'mouse-face 'mode-line-highlight
                         'keymap embr--header-line-map
                         'pointer 'hand
                         'help-echo "mouse-1: Copy URL and open URL/Search prompt"))))
  (when embr-tab-bar
    (setq-local tab-line-format '(:eval (embr--render-tab-bar))))
  (add-hook 'pre-command-hook #'embr--maybe-end-search nil t)
  (add-hook 'kill-buffer-hook #'embr--kill-buffer-cleanup nil t))

(defun embr--kill-buffer-cleanup ()
  "Shut down the daemon when the buffer is killed by any means."
  (embr--hint-abort-session)
  (embr--save-session)
  (embr--shutdown-daemon)
  (embr--hover-stop)
  (embr--backend-shutdown)
  (when embr--resize-timer
    (cancel-timer embr--resize-timer)
    (setq embr--resize-timer nil))
  ;; Remove resize hook when no embr buffers remain.
  (unless (or (and embr--normal-buffer
                   (buffer-live-p embr--normal-buffer)
                   (not (eq embr--normal-buffer (current-buffer))))
              (and embr--incognito-buffer
                   (buffer-live-p embr--incognito-buffer)
                   (not (eq embr--incognito-buffer (current-buffer)))))
    (embr--resize-hook-remove)))

;; ── Vimium minor mode ──────────────────────────────────────────────

(defvar-local embr-vimium--insert-mode nil
  "Non-nil means vimium insert mode is active.")

(transient-define-prefix embr-vimium-dispatch-keys ()
  "Show vimium normal-mode bindings."
  [["Motion"
    ("j" "Down" embr-dispatch-close :transient nil)
    ("k" "Up" embr-dispatch-close :transient nil)
    ("h" "Left" embr-dispatch-close :transient nil)
    ("l" "Right" embr-dispatch-close :transient nil)
    ("0" "Line start" embr-dispatch-close :transient nil)
    ("$" "Line end" embr-dispatch-close :transient nil)
    ("w" "Word end" embr-dispatch-close :transient nil)
    ("e" "Word end" embr-dispatch-close :transient nil)
    ("b" "Word back" embr-dispatch-close :transient nil)]
   ["Scroll / Page"
    ("G" "Bottom of page" embr-dispatch-close :transient nil)
    ("g" "Top of page (gg)" embr-dispatch-close :transient nil)
    ("C-d" "Page down" embr-dispatch-close :transient nil)
    ("C-u" "Page up" embr-dispatch-close :transient nil)]
   ["Search"
    ("/" "Search forward" embr-vimium-search-forward)
    ("?" "Search backward" embr-vimium-search-backward)
    ("n" "Next match" embr-vimium-search-next)
    ("N" "Previous match" embr-vimium-search-previous)]
   ["Actions"
    ("f" "Hint link" embr-follow-hint)
    ("o" "Open URL" embr-navigate)
    ("y" "Copy URL (yy)" embr-copy-url)
    ("r" "Reload" embr-refresh)
    ("H" "Back" embr-back)
    ("L" "Forward" embr-forward)
    ("t" "New tab" embr-new-tab)
    ("d" "Close tab" embr-close-tab)
    ("J" "Next tab" embr-next-tab)
    ("K" "Prev tab" embr-prev-tab)]
   ["Mode"
    ("i" "Insert mode" embr-vimium-enter-insert)
    ("<escape>" "Normal mode" embr-vimium-enter-normal)
    ("SPC" "Leader" embr-vimium-dispatch)]
   ["Other"
    ("x" "Delete" embr-dispatch-close :transient nil)
    ("q" "Close menu" embr-dispatch-close)]])

(transient-define-prefix embr-vimium-dispatch ()
  "Show available embr browser commands (vimium leader)."
  [["Navigation"
    ("g" "Reload" embr-refresh)
    ("l" "Back" embr-back)
    ("r" "Forward" embr-forward)
    ("<home>" "Home" embr-home)
    ("h" "History" embr-history-persistent)
    ("H" "Download history" embr-download-history)]
   ["Tabs"
    ("c" "New" embr-new-tab)
    ("x" "Close" embr-close-tab)
    ("]" "Next" embr-next-tab)
    ("[" "Previous" embr-prev-tab)
    ("s" "Switch" embr-list-tabs)
    ("m" "Mute/unmute" embr-toggle-mute)]
   ["Bookmarks"
    ("b" "Add" bookmark-set)
    ("j" "Jump" bookmark-jump)
    ("u" "Unbookmark" bookmark-delete)]
   ["Actions"
    ("o" "Open URL" embr-navigate)
    ("f" "Hint link" embr-follow-hint)
    ("w" "Copy URL" embr-copy-url)
    ("y" "Copy link" embr-copy-link)
    ("d" "Download" embr-download)
    ("D" "Download URL" embr-download-url)
    (":" "Execute JS" embr-execute-js)]
   ["Export"
    ("i" "Print PDF" embr-print-pdf)
    ("n" "Screenshot" embr-screenshot)
    ("a" "Reader" embr-reader)
    ("p" "Page info" embr-page-info)
    ("v" "View text" embr-view-text)
    ("e" "Open in eww" embr-open-in-eww)
    ("E" "View source" embr-view-source)]
   ["Privacy"
    ("t" "Proxy info" embr-proxy-info)
    ("1" "Clear cookies" embr-clear-cookies)
    ("2" "Clear cache" embr-clear-cache)
    ("3" "Clear local storage" embr-clear-local-storage)
    ("4" "Clear sessions" embr-clear-sessions)
    ("5" "Clear URL history" embr-clear-url-history)
    ("6" "Clear browser history" embr-clear-browser-history)
    ("0" "Clear all (nuclear)" embr-clear-all)]
   ["Other"
    ("k" "Kill embr" embr-quit)
    ("q" "Close menu" embr-dispatch-close)
    ("<escape>" "Close menu" embr-dispatch-close)
    ("z" "Chrome internals" embr-dispatch-chrome)
    ("?" "Normal-mode bindkeys" embr-vimium-dispatch-keys)]])

(defun embr-vimium--send-key (key)
  "Send KEY name to the browser."
  (embr--send `((cmd . "key") (key . ,key))
              #'embr--action-callback))

(defvar embr-vimium-normal-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") (lambda () (interactive) (embr-vimium--send-key "ArrowDown")))
    (define-key map (kbd "k") (lambda () (interactive) (embr-vimium--send-key "ArrowUp")))
    (define-key map (kbd "h") (lambda () (interactive) (embr-vimium--send-key "ArrowLeft")))
    (define-key map (kbd "l") (lambda () (interactive) (embr-vimium--send-key "ArrowRight")))
    (define-key map (kbd "0") (lambda () (interactive) (embr-vimium--send-key "Home")))
    (define-key map (kbd "$") (lambda () (interactive) (embr-vimium--send-key "End")))
    (define-key map (kbd "w") (lambda () (interactive) (embr-vimium--send-key "Control+ArrowRight")))
    (define-key map (kbd "e") (lambda () (interactive) (embr-vimium--send-key "Control+ArrowRight")))
    (define-key map (kbd "b") (lambda () (interactive) (embr-vimium--send-key "Control+ArrowLeft")))
    (define-key map (kbd "x") (lambda () (interactive) (embr-vimium--send-key "Delete")))
    (define-key map (kbd "G") (lambda () (interactive) (embr-vimium--send-key "End")))
    (define-key map (kbd "C-d") (lambda () (interactive) (embr-vimium--send-key "PageDown")))
    (define-key map (kbd "C-u") (lambda () (interactive) (embr-vimium--send-key "PageUp")))
    (define-key map (kbd "/") #'embr-vimium-search-forward)
    (define-key map (kbd "?") #'embr-vimium-search-backward)
    (define-key map (kbd "n") #'embr-vimium-search-next)
    (define-key map (kbd "N") #'embr-vimium-search-previous)
    (define-key map (kbd "f") #'embr-follow-hint)
    (define-key map (kbd "H") #'embr-back)
    (define-key map (kbd "L") #'embr-forward)
    (define-key map (kbd "r") #'embr-refresh)
    (define-key map (kbd "o") #'embr-navigate)
    (define-key map (kbd "t") #'embr-new-tab)
    (define-key map (kbd "d") #'embr-close-tab)
    (define-key map (kbd "J") #'embr-next-tab)
    (define-key map (kbd "K") #'embr-prev-tab)
    (define-key map (kbd "i") #'embr-vimium-enter-insert)
    (let ((g-map (make-sparse-keymap)))
      (define-key g-map (kbd "g") (lambda () (interactive) (embr-vimium--send-key "Home")))
      (define-key map (kbd "g") g-map))
    (let ((y-map (make-sparse-keymap)))
      (define-key y-map (kbd "y") #'embr-copy-url)
      (define-key map (kbd "y") y-map))
    ;; Swallow all unbound printable chars so they don't leak through.
    (dolist (c (number-sequence 32 126))
      (unless (lookup-key map (vector c))
        (define-key map (vector c) #'ignore)))
    (define-key map [remap self-insert-command] #'ignore)
    map)
  "Keymap for vimium normal mode.")

;; Bind leader key separately so it picks up the user's customization.
(define-key embr-vimium-normal-map (kbd embr-vimium-leader) #'embr-vimium-dispatch)

(defvar embr-vimium-insert-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-g") #'embr-vimium-enter-normal)
    (define-key map (kbd "<escape>") #'embr-vimium-enter-normal)
    map)
  "Keymap for vimium insert mode.")

(defun embr-vimium-enter-insert ()
  "Switch to vimium insert mode."
  (interactive)
  (setq embr-vimium--insert-mode t)
  (setf (alist-get 'embr-vimium-mode minor-mode-overriding-map-alist)
        embr-vimium-insert-map)
  (force-mode-line-update))

(defun embr-vimium-enter-normal ()
  "Switch to vimium normal mode."
  (interactive)
  (setq embr-vimium--insert-mode nil)
  (setf (alist-get 'embr-vimium-mode minor-mode-overriding-map-alist)
        embr-vimium-normal-map)
  (force-mode-line-update))

(defun embr-vimium--minibuffer-setup ()
  "Bind ESC to abort minibuffers invoked from a vimium-mode buffer."
  (when-let* ((win (minibuffer-selected-window))
              (buf (window-buffer win)))
    (when (buffer-local-value 'embr-vimium-mode buf)
      (embr--minibuffer-escape-setup))))

(define-minor-mode embr-vimium-mode
  "Toggle vimium-style modal keybindings for embr.
In normal mode, bare keys act as vim-style navigation.
In insert mode, keys pass through to the browser.
While enabled, ESC aborts any minibuffer prompt invoked from the
vimium buffer."
  :lighter nil
  (if embr-vimium-mode
      (progn
        (setq embr-vimium--insert-mode (not embr-vimium-start-in-normal))
        (setf (alist-get 'embr-vimium-mode minor-mode-overriding-map-alist)
              (if embr-vimium-start-in-normal
                  embr-vimium-normal-map
                embr-vimium-insert-map))
        (add-hook 'minibuffer-setup-hook #'embr-vimium--minibuffer-setup)
        (force-mode-line-update))
    (setq embr-vimium--insert-mode nil)
    (setq minor-mode-overriding-map-alist
          (assq-delete-all 'embr-vimium-mode minor-mode-overriding-map-alist))
    (unless (seq-some (lambda (buf)
                        (buffer-local-value 'embr-vimium-mode buf))
                      (buffer-list))
      (remove-hook 'minibuffer-setup-hook #'embr-vimium--minibuffer-setup))
    (force-mode-line-update)))

;; ── Dynamic viewport sizing ──────────────────────────────────────

(defun embr--window-viewport-size (&optional window)
  "Return viewport size as (WIDTH . HEIGHT) from WINDOW pixel dimensions.
Return nil if the window is not live or has no pixel size."
  (let ((win (or window (get-buffer-window (current-buffer)))))
    (when (and win (window-live-p win))
      (let ((w (window-body-width win t))
            (h (window-body-height win t)))
        (when (and w h (> w 0) (> h 0))
          (cons (max 200 w) (max 200 h)))))))

(defun embr--resize-hook-install ()
  "Install the window size change hook for dynamic viewport sizing."
  (add-hook 'window-size-change-functions #'embr--on-window-resize))

(defun embr--resize-hook-remove ()
  "Remove the window size change hook for dynamic viewport sizing."
  (remove-hook 'window-size-change-functions #'embr--on-window-resize))

(defun embr--on-window-resize (frame)
  "Handle FRAME resize for dynamic viewport sizing.
Debounce by scheduling `embr--do-resize' after 0.3 seconds."
  (dolist (buf (list embr--normal-buffer embr--incognito-buffer))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (and embr--process (process-live-p embr--process)
                   (eq embr-viewport-sizing 'dynamic))
          (let ((win (get-buffer-window buf frame)))
            (when win
              (when embr--resize-timer
                (cancel-timer embr--resize-timer))
              (let ((target-buf buf))
                (setq embr--resize-timer
                      (run-at-time
                       0.3 nil
                       (lambda ()
                         (embr--do-resize target-buf))))))))))))

(defun embr--do-resize (buf)
  "Execute the viewport resize for BUF after debounce."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq embr--resize-timer nil)
      (when (and embr--process (process-live-p embr--process))
        (let ((size (embr--window-viewport-size)))
          (when size
            (let ((new-w (car size))
                  (new-h (cdr size)))
              ;; Ignore sub-8px jitter (e.g. tab-bar redraws) to
              ;; avoid spurious canvas recreations during tab switches.
              (unless (and (< (abs (- new-w embr--viewport-width)) 8)
                           (< (abs (- new-h embr--viewport-height)) 8))
                (setq embr--viewport-width new-w
                      embr--viewport-height new-h)
                ;; Recreate canvas BEFORE telling the daemon to
                ;; resize, so the new (larger) pixel buffer is ready
                ;; before larger frames arrive.
                (when (equal embr--active-backend "canvas")
                  (embr--canvas-resize new-w new-h))
                (embr--send `((cmd . "resize")
                              (width . ,new-w)
                              (height . ,new-h))
                            (lambda (resp)
                              (when-let* ((err (alist-get 'error resp)))
                                (message "embr: resize failed: %s" err))))))))))))

;; ── Entry point ────────────────────────────────────────────────────

(defun embr--build-init-params ()
  "Build the init command params alist from current defcustom values."
  `((cmd . "init")
    (width . ,embr--viewport-width)
    (height . ,embr--viewport-height)
    (screen_width . ,embr-screen-width)
    (screen_height . ,embr-screen-height)
    (fps . ,embr-fps)
    (jpeg_quality . ,embr-jpeg-quality)
    ,@(when embr-color-scheme
        `((color_scheme . ,(symbol-name embr-color-scheme))))
    ,@(when embr-dom-caret-hack
        '((dom_caret . t)))
    ,@(when embr-href-preview-hack
        '((href_preview . t)))
    ,@(when embr-perf-log
        '((perf_log . t)))
    (frame_source . ,(symbol-name embr-frame-source))
    (render_backend . ,(embr--select-backend))
    (input_priority_window_ms . ,embr-input-priority-window-ms)
    ,@(when embr-adaptive-capture
        `((adaptive_capture . t)
          (adaptive_fps_min . ,embr-adaptive-fps-min)
          (adaptive_jpeg_quality_min . ,embr-adaptive-jpeg-quality-min)))
    ,@(when embr-proxy-rules
        `((proxy_rules . ,(vconcat
                           (mapcar (lambda (r)
                                     `((suffix . ,(nth 0 r))
                                       (type . ,(symbol-name (nth 1 r)))
                                       (address . ,(nth 2 r))))
                                   embr-proxy-rules)))))))

(defconst embr--init-timeout 130
  "Seconds to wait for the daemon's init response.
The daemon's own init timeout is 120 seconds: a first launch may
have to download or set up the browser.")

(defun embr--check-setup (offer-install)
  "Signal a `user-error' if the browser engine is not installed.
When OFFER-INSTALL is non-nil, offer to start the installer first.
This runs the venv's Python, so callers skip it while a daemon is
already running."
  (when (embr--setup-needed-p)
    (let ((install-fn (if (eq embr-browser-engine 'chromium)
                          #'embr-install-or-update-chromium
                        #'embr-install-or-update-cloakbrowser)))
      (if (and offer-install
               (y-or-n-p (format "embr: Setup needed (venv or %s missing). Run now? "
                                 embr-browser-engine)))
          (progn
            (funcall install-fn)
            (user-error "embr: Setup started in *embr-setup* buffer.  Run M-x embr-browse again when it finishes"))
        (user-error "embr: Run M-x %s first" install-fn)))))

(defun embr--start-session (label)
  "Start the daemon for the current embr buffer and wait for it to initialize.
LABEL names the session in error messages.  Return the init response;
signal an error, with the daemon stopped, if initialization failed."
  ;; Always init at a safe default size.  In dynamic mode a deferred
  ;; timer resizes to the window dimensions once the backend is up
  ;; (avoids a canvas init race at large sizes).
  (setq embr--viewport-width (or embr--viewport-width embr-default-width)
        embr--viewport-height (or embr--viewport-height embr-default-height))
  (embr--start-daemon)
  (let ((resp (embr--send-sync (embr--build-init-params) embr--init-timeout)))
    (when (alist-get 'error resp)
      (embr--shutdown-daemon 1.0)
      (error "%s: init failed: %s" label (alist-get 'error resp)))
    ;; The daemon tells us where it writes frames.
    (setq embr--frame-path (alist-get 'frame_path resp)
          embr--proxy-active (and embr-proxy-rules t))
    resp))

(defun embr--finish-session-start (resp label)
  "Bring up frames, hover tracking and resizing for a session.
RESP is the daemon's init response and LABEL names the session in
messages.  Call this once the initial tabs exist, so the tab list is
complete before the first frame."
  (embr--refresh-tab-list)
  (embr--hover-start)
  (embr--backend-init
   (or (alist-get 'render_backend resp) "default")
   (alist-get 'frame_socket_path resp))
  (embr--backend-report resp label)
  (when (eq embr-viewport-sizing 'dynamic)
    (embr--resize-hook-install)
    (let ((buf (current-buffer)))
      (run-at-time 0.5 nil
                   (lambda () (embr--do-resize buf))))))

;;;###autoload
(defun embr-browse (&optional url _new-window)
  "Launch embr and navigate to URL.
When called interactively, restore the saved session or open
`embr-home-url'.  When called from Lisp with a URL argument, open it,
in a new tab if a session is already running; input that does not
look like a URL is searched for."
  (interactive)
  (let ((target (and url (embr--maybe-search-url url))))
    ;; The setup check runs the venv's Python: skip it once a daemon runs.
    (unless (embr--buffer-daemon-live-p embr--normal-buffer)
      (embr--check-setup t))
    (unless (buffer-live-p embr--normal-buffer)
      (setq embr--normal-buffer (generate-new-buffer "*embr*"))
      (with-current-buffer embr--normal-buffer
        (embr-mode)))
    (switch-to-buffer embr--normal-buffer)
    (with-current-buffer embr--normal-buffer
      (if (and embr--process (process-live-p embr--process))
          ;; Daemon already running: open the URL in a new tab.
          (when target
            (embr--send `((cmd . "new-tab") (url . ,target))
                        #'embr--action-callback))
        (let* ((resp (embr--start-session "embr"))
               ;; Restore the session or navigate before starting frames.
               (restored (embr--restore-session)))
          (if restored
              (progn
                (message "embr: session restored (%d tab%s)"
                         restored (if (= restored 1) "" "s"))
                (when target
                  (embr--send-sync `((cmd . "new-tab") (url . ,target)))))
            (embr--send-sync `((cmd . "navigate")
                               (url . ,(or target embr-home-url)))))
          (embr--finish-session-start resp "embr"))))))

(provide 'embr)

;;; embr.el ends here
