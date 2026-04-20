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
;; delivered via CDP screencast, with an optional canvas backend that
;; renders directly to a pixel buffer over a Unix socket.
;;
;; The Python daemon (`embr.py') controls the browser through
;; Playwright.  Communication uses JSON lines over stdin/stdout,
;; serialized with Emacs 30.1's native C JSON (`json-serialize').

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'shr)
(require 'transient)

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

(defcustom embr-viewport-sizing 'fixed
  "How the browser viewport dimensions are determined.
`fixed' uses `embr-default-width' and `embr-default-height'.
`dynamic' derives viewport size from the Emacs window pixel
dimensions and resizes automatically when the window changes.
Fixed dimensions are less fingerprintable."
  :type '(choice (const :tag "Fixed (default)" fixed)
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
  "Deprecated. Screenshot-only. Target FPS for the screenshot polling loop."
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
  "Deprecated. Screenshot-only. Minimum hover rate under load pressure."
  :type 'integer)

(defcustom embr-render-backend 'default
  "Render backend for frame display.
`default' uses the JPEG file + create-image path (works on any Emacs).
`canvas' uses the native canvas pixel path (requires canvas-patched Emacs)."
  :type '(choice (const :tag "Default (JPEG file)" default)
                 (const :tag "Canvas (requires patch)" canvas)))

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
      (insert (format "Running setup.sh %s ...\n\n" args))
      (let ((proc (apply #'start-process "embr-setup" buf
                          "bash" setup-script args)))
        (set-process-sentinel
         proc
         (lambda (_proc event)
           (when (string-match-p "finished" event)
             (with-current-buffer (get-buffer "*embr-setup*")
               (goto-char (point-max))
               (insert (format "\n%s\n" msg))))))))))

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
  (expand-file-name "~/.local/share/embr/")
  "Hardcoded base path for embr data deletion safety checks.")

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
Deletes ~/.local/share/embr/, ~/.cloakbrowser/, and
~/.cache/ms-playwright/ entirely.
Does not remove the Emacs package itself."
  (interactive)
  (unless (and (stringp embr--data-dir-prefix)
               (string-prefix-p (expand-file-name "~/.local/share/embr/")
                                embr--data-dir-prefix))
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
(defvar embr--response-buffer "" "Accumulator for partial JSON lines from the process.")
(defvar embr--callback nil "Function to call with the next command response.")
(defvar embr--current-url "" "The URL currently displayed.")
(defvar embr--current-title "" "The title of the current page.")
(defvar embr--viewport-width nil "Current viewport width.")
(defvar embr--viewport-height nil "Current viewport height.")
(defvar embr--frame-path nil "Path to the JPEG frame file written by the daemon.")
(defvar embr--url-history nil "History of visited URLs for completion.")
(defvar embr--hints nil "Current hint labels alist from the daemon.")
(defvar embr--hover-timer nil "Timer for mouse hover tracking.")
(defvar embr--hover-last-x nil "Last hover X coordinate sent.")
(defvar embr--hover-last-y nil "Last hover Y coordinate sent.")
(defvar embr--pending-frame nil "Latest frame response waiting to be rendered.")
(defvar embr--render-timer nil "Timer that renders pending frames at a capped rate.")
(defvar embr--pressure nil "Non-nil when daemon signals load pressure.")
(defvar embr--hover-last-send-time nil "Float-time of last hover send.")
(defvar embr--active-backend nil "Active render backend name: default or canvas.")
(defvar embr--canvas-image nil "Canvas image spec for the canvas backend.")
(defvar embr--canvas-socket nil "Network process for canvas frame socket.")
(defvar embr--canvas-recv-buf "" "Accumulator for partial canvas socket packets.")
(defvar embr--canvas-last-seq 0 "Sequence number of the last rendered canvas frame.")
(defvar embr--canvas-stale-count 0 "Number of stale/out-of-order frames dropped.")
(defvar embr--canvas-error-count 0 "Consecutive canvas blit errors.")
(defvar embr--canvas-frame-count 0 "Total frames blitted via canvas backend.")
(defvar embr--canvas-resize-count 0 "Counter for generating unique canvas-ids on resize.")
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

;; ── Process management ─────────────────────────────────────────────

(defun embr--start-daemon ()
  "Start the Python daemon process.
Respects `embr-display-method' for display modes."
  (when (and embr--process (process-live-p embr--process))
    (delete-process embr--process))
  (setq embr--response-buffer "")
  (let* ((inner (list embr-python embr-script))
         (xvfb (and (eq embr-display-method 'headed-offscreen)
                    (executable-find "xvfb-run")))
         (command
          (if xvfb
              (append (list xvfb "--auto-servernum"
                            "--server-args=-screen 0 1920x1080x24")
                      inner)
            (when (and (eq embr-display-method 'headed-offscreen)
                       (not (executable-find "xvfb-run")))
              (message "embr: xvfb-run not found, falling back to headless"))
            inner))
         (process-environment
          (cons (format "EMBR_ENGINE=%s"
                        (symbol-name embr-browser-engine))
                (cons (format "EMBR_DISPLAY=%s"
                              (if xvfb "headed-offscreen"
                                (symbol-name embr-display-method)))
                      process-environment))))
    (setq embr--process
          (make-process
           :name "embr"
           :command command
           :connection-type 'pipe
           :noquery t
           :stderr (get-buffer-create "*embr-stderr*")
           :filter #'embr--process-filter
           :sentinel #'embr--process-sentinel))
    (process-put embr--process 'embr-buffer (current-buffer))))

(defun embr--process-filter (proc output)
  "Handle OUTPUT from daemon PROC, routing to the owning buffer."
  (let ((buf (process-get proc 'embr-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq embr--response-buffer
              (concat embr--response-buffer output))
        ;; Process all complete lines.  For frame notifications, only render
        ;; the latest one (skip intermediate frames if Emacs can't keep up).
        (let (last-frame)
          (while (string-match "\n" embr--response-buffer)
            (let* ((pos (match-end 0))
                   (line (substring embr--response-buffer 0 (1- pos))))
              (setq embr--response-buffer (substring embr--response-buffer pos))
              (when (and line (not (string-empty-p line)))
                (condition-case err
                    (let ((resp (json-parse-string line :object-type 'alist
                                                        :array-type 'list
                                                        :null-object nil
                                                        :false-object :false)))
                      (cond
                       ((alist-get 'frame resp)
                        ;; Frame notification — just remember the latest one.
                        (setq last-frame resp))
                       ((alist-get 'metadata resp)
                        ;; Navigation metadata — update URL/title immediately.
                        (embr--update-metadata resp)
                        ;; Metadata may carry a background tab-title refresh.
                        (embr--update-tab-list-from-resp resp))
                       ((alist-get 'screencast_error resp)
                        ;; Screencast error notification — always show to user.
                        (message "embr: %s" (alist-get 'screencast_error resp)))
                       (t
                        ;; Update tab bar if response includes tabs.
                        (embr--update-tab-list-from-resp resp)
                        ;; Command response — dispatch to callback.
                        (when embr--callback
                          (let ((cb embr--callback))
                            (setq embr--callback nil)
                            (funcall cb resp))))))
                  (error (message "embr: JSON parse error: %s"
                                  (error-message-string err)))))))
          ;; Stash the latest frame for the render timer instead of
          ;; rendering synchronously — keeps Emacs responsive during
          ;; high-FPS streams (e.g. video playback).
          (when last-frame
            (setq embr--pending-frame last-frame)))))))

(defun embr--process-sentinel (proc event)
  "Handle process EVENT (e.g. exit) for PROC."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (let ((buf (process-get proc 'embr-buffer)))
      (message "embr: daemon exited: %s" (string-trim event))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (embr--hover-stop)
          (embr--backend-shutdown)
          (setq embr--process nil))))))

(defun embr--send (msg &optional callback)
  "Send MSG (an alist) to the daemon as JSON.  Call CALLBACK with the response."
  (unless (and embr--process (process-live-p embr--process))
    (error "embr: daemon not running"))
  ;; Purge any stale pending frame so the next render reflects post-input state.
  (setq embr--pending-frame nil)
  (setq embr--callback callback)
  (process-send-string embr--process (concat (json-serialize msg) "\n")))

(defun embr--send-sync (msg)
  "Send MSG and wait synchronously for the response.  Returns the parsed alist."
  (let ((result nil)
        (done nil))
    (embr--send msg (lambda (resp)
                            (setq result resp done t)))
    (while (not done)
      (accept-process-output embr--process 30))
    result))

;; ── Render backend ─────────────────────────────────────────────────

(declare-function embr-canvas-supported-p "embr-canvas")
(declare-function embr-canvas-blit-jpeg "embr-canvas")
(declare-function embr-canvas-version "embr-canvas")

(defconst embr--canvas-max-errors 5
  "Consecutive canvas blit errors before fallback to default.")

(defun embr--canvas-source-dir ()
  "Return the directory containing native module source.
Resolves symlinks so this works when Elpaca symlinks embr.el
from the build dir to the source repo."
  (file-name-directory (file-truename
                        (expand-file-name "embr.el" embr--directory))))

(defun embr--canvas-maybe-compile ()
  "Compile the canvas native module if source exists but .so does not."
  (let* ((source-dir (embr--canvas-source-dir))
         (so (expand-file-name "native/embr-canvas.so" source-dir))
         (src (expand-file-name "native/embr-canvas.c" source-dir)))
    (when (and (file-exists-p src) (not (file-exists-p so)))
      (message "embr: compiling canvas module...")
      (let ((ret (call-process
                  "make" nil nil nil "-C"
                  (expand-file-name "native" source-dir))))
        (if (= ret 0)
            (message "embr: canvas module compiled")
          (message "embr: canvas module compilation failed (exit %d)" ret))))))

(defun embr--canvas-available-p ()
  "Return non-nil if canvas rendering is available.
Layer 1: image type.  Layer 2: native module.  Layer 3: smoke render."
  (and
   ;; Layer 1: Elisp image type.
   (image-type-available-p 'canvas)
   ;; Layer 2: native module loads and reports support.
   (condition-case err
       (progn
         (embr--canvas-maybe-compile)
         (module-load
          (expand-file-name "native/embr-canvas.so"
                            (embr--canvas-source-dir)))
         (and (fboundp 'embr-canvas-supported-p)
              (embr-canvas-supported-p)))
     (error
      (message "embr: canvas module unavailable: %s"
               (error-message-string err))
      nil))
   ;; Layer 3: smoke render (create tiny canvas, call module, verify
   ;; no crash).  Blit returns nil for invalid JPEG but exercises
   ;; canvas_pixel internally, proving the API works end-to-end.
   (condition-case err
       (progn
         (embr-canvas-blit-jpeg
          '(image :type canvas
                  :canvas-id embr--smoke-test
                  :canvas-width 4
                  :canvas-height 4)
          "" 4 4 0)
         t)
     (error
      (message "embr: canvas smoke test failed: %s"
               (error-message-string err))
      nil))))

(defun embr--select-backend ()
  "Select the render backend based on `embr-render-backend'."
  (pcase embr-render-backend
    ('canvas
     (if (embr--canvas-available-p)
         "canvas"
       (error "embr: canvas backend requested but not available")))
    (_ "default")))

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
        embr--default-frame-count 0)
  (if (string= name "canvas")
      (embr--backend-init-canvas socket-path)
    (embr--render-start)))

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
  (setq embr--active-backend nil))

;; ── Legacy backend ────────────────────────────────────────────────

(defun embr--default-display-frame (_resp)
  "Read JPEG from disk and display in buffer."
  (when (and embr--frame-path
             (file-exists-p embr--frame-path))
    (let* ((path embr--frame-path)
           (data (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally path)
                   (buffer-string))))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-image (create-image data 'jpeg t))
        (remove-text-properties (point-min) (point-max) '(keymap nil))
        (put-text-property (point-min) (point-max) 'pointer 'arrow)
        (goto-char (point-min))))
    (cl-incf embr--default-frame-count)))

;; ── Canvas backend ────────────────────────────────────────────────

(defun embr--read-u32 (str offset)
  "Read a little-endian uint32 from unibyte STR at OFFSET."
  (logior (aref str offset)
          (ash (aref str (+ offset 1)) 8)
          (ash (aref str (+ offset 2)) 16)
          (ash (aref str (+ offset 3)) 24)))

(defun embr--canvas-fallback-to-default ()
  "Report canvas failure.  No automatic fallback."
  (message "embr: canvas backend failed — restart embr or check native module"))

(defun embr--canvas-socket-filter (proc data)
  "Handle binary frame data from canvas socket PROC.
Parse length-prefixed packets, drop stale/out-of-order frames,
and blit the latest to the canvas.  Routes to the owning buffer
via a process property so buffer-local vars resolve correctly."
  (let ((buf (process-get proc 'embr-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq embr--canvas-recv-buf (concat embr--canvas-recv-buf data))
        (let ((done nil))
          (while (and (not done)
                      (>= (length embr--canvas-recv-buf) 16))
            (let* ((hdr embr--canvas-recv-buf)
                   (seq (embr--read-u32 hdr 0))
                   (jpeg-len (embr--read-u32 hdr 12))
                   (total (+ 16 jpeg-len)))
              (if (< (length embr--canvas-recv-buf) total)
                  (setq done t)
                (let ((jpeg-data (substring embr--canvas-recv-buf 16 total))
                      (width (embr--read-u32 hdr 4))
                      (height (embr--read-u32 hdr 8)))
                  (setq embr--canvas-recv-buf
                        (substring embr--canvas-recv-buf total))
                  ;; Drop stale or out-of-order packets.  Handle uint32
                  ;; wraparound: if delta is huge (> 2^31), seq wrapped.
                  (if (and (<= seq embr--canvas-last-seq)
                           (< (- embr--canvas-last-seq seq) #x80000000))
                      (progn (cl-incf embr--canvas-stale-count) nil)
                    (setq embr--canvas-last-seq seq)
                    (when embr--canvas-image
                      (condition-case err
                          (progn
                            (embr-canvas-blit-jpeg
                             embr--canvas-image jpeg-data width height seq)
                            (cl-incf embr--canvas-frame-count)
                            (setq embr--canvas-error-count 0))
                        (error
                         (cl-incf embr--canvas-error-count)
                         (message "embr: canvas blit error %d: %s"
                                  embr--canvas-error-count
                                  (error-message-string err)))))))))))))))


(defun embr--canvas-socket-sentinel (_proc event)
  "Handle canvas socket disconnect."
  (when (string-match-p "\\(closed\\|connection broken\\)" event)
    (message "embr: canvas socket closed")))

(defun embr--backend-init-canvas (socket-path)
  "Initialize the canvas render backend.
Connect to SOCKET-PATH and create the canvas image in the buffer."
  (let ((canvas-id (intern (format "embr-canvas-%s" (buffer-name)))))
    (setq embr--canvas-image
          `(image :type canvas
                  :canvas-id ,canvas-id
                  :canvas-width ,embr--viewport-width
                  :canvas-height ,embr--viewport-height)))
  (setq embr--canvas-recv-buf ""
        embr--canvas-error-count 0
        embr--canvas-last-seq 0
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
  (setq embr--canvas-socket nil
        embr--canvas-image nil
        embr--canvas-recv-buf ""))

(defun embr--canvas-resize (width height)
  "Recreate the canvas image at WIDTH x HEIGHT.
Allocate a fresh canvas-id so the C module creates a new pixel
buffer at the correct size."
  (cl-incf embr--canvas-resize-count)
  (let ((canvas-id (intern (format "embr-canvas-%s-%d"
                                   (buffer-name)
                                   embr--canvas-resize-count))))
    (setq embr--canvas-image
          `(image :type canvas
                  :canvas-id ,canvas-id
                  :canvas-width ,width
                  :canvas-height ,height)))
  (setq embr--canvas-recv-buf ""
        embr--canvas-last-seq 0)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize " " 'display embr--canvas-image))
    (put-text-property (point-min) (point-max) 'pointer 'arrow)
    (goto-char (point-min))))

;; ── Backend debug ─────────────────────────────────────────────────

(defun embr-backend-info ()
  "Display render backend diagnostics."
  (interactive)
  (message "embr backend: %s | canvas: %d frames, %d errors, %d stale | default: %d frames"
           (embr--backend-name)
           embr--canvas-frame-count
           embr--canvas-error-count
           embr--canvas-stale-count
           embr--default-frame-count))

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
      (force-mode-line-update))))

(defun embr--action-callback (resp)
  "Generic callback for command responses: report errors, update metadata."
  (when-let* ((err (alist-get 'error resp)))
    (message "embr error: %s" err))
  (embr--update-metadata resp))

;; ── Commands ───────────────────────────────────────────────────────

(defun embr-execute-js (expr)
  "Execute JavaScript EXPR in the browser and display the result."
  (interactive "sJS: ")
  (embr--send `((cmd . "js") (expr . ,expr))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "embr JS error: %s" err)
                         (message "=> %s" (alist-get 'result resp))))))

(defun embr--maybe-search-url (input)
  "If INPUT looks like a URL, return it as-is; otherwise build a search URL."
  (if (or (string-match-p "\\`https?://" input)
          (string-match-p "\\`file://" input)
          (string-match-p "\\`chrome://" input)
          (and (string-match-p "\\." input)
               (not (string-match-p " " input))))
      input
    (embr--search-url input)))

(defun embr-navigate (url)
  "Navigate to URL, or search if input doesn't look like a URL.
With prefix argument, clear URL history."
  (interactive
   (if current-prefix-arg
       (progn
         (setq embr--url-history nil)
         (message "embr: URL history cleared")
         (list nil))
     (list (completing-read "URL/Search: "
                            (unless embr--incognito-flag
                              (lambda (str pred action)
                                (if (eq action 'metadata)
                                    '(metadata (display-sort-function . identity))
                                  (complete-with-action
                                   action embr--url-history str pred))))
                            nil nil nil
                            (unless embr--incognito-flag
                              'embr--url-history)))))
  (if (or (null url) (string-empty-p url))
      ;; Empty input navigates to about:blank.
      (embr--send '((cmd . "navigate") (url . "about:blank"))
                  #'embr--action-callback)
    (let ((target (embr--maybe-search-url url)))
      (unless (or embr--incognito-flag
                   (embr--url-proxied-p (or target url)))
        (push url embr--url-history)
        (delete-dups embr--url-history))
      (when target
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

(defconst embr--history-db
  (expand-file-name "~/.local/share/embr/chromium-profile/Default/History")
  "Hardcoded path to Chromium's History SQLite database.")

(defun embr-history-persistent ()
  "Browse persistent Chromium history and navigate to a selection.
Reads the History SQLite database directly.  Requires sqlite3 on PATH."
  (interactive)
  (cond
   ((not (executable-find "sqlite3"))
    (message "embr: sqlite3 not found on PATH"))
   ((not (file-exists-p embr--history-db))
    (message "embr: no history database found"))
   (t
    ;; Copy to temp file to avoid SQLite lock conflicts with Chromium.
    (let* ((tmp (make-temp-file "embr-hist" nil ".db"))
           (query "SELECT title, url FROM urls WHERE hidden=0 AND title <> '' ORDER BY last_visit_time DESC LIMIT 200;"))
      (unwind-protect
          (progn
            (copy-file embr--history-db tmp t)
            (let ((output (shell-command-to-string
                           (format "sqlite3 -separator '\t' %s %s"
                                   (shell-quote-argument tmp)
                                   (shell-quote-argument query)))))
              (if (string-empty-p output)
                  (message "embr: history is empty")
                (let* ((lines (split-string output "\n" t))
                       (candidates
                        (mapcar (lambda (line)
                                  (let* ((parts (split-string line "\t" nil))
                                         (title (or (car parts) ""))
                                         (url (or (cadr parts) "")))
                                    (cons (if (string-empty-p title)
                                              url
                                            (format "%s  —  %s" title url))
                                          url)))
                                lines))
                       (cands (mapcar #'car candidates))
                       (chosen (completing-read
                                "History (all): "
                                (lambda (str pred action)
                                  (if (eq action 'metadata)
                                      '(metadata (display-sort-function . identity))
                                    (complete-with-action action cands str pred)))
                                nil t)))
                  (when chosen
                    (let ((url (cdr (assoc chosen candidates))))
                      (embr--send `((cmd . "navigate") (url . ,url))
                                  #'embr--action-callback)))))))
        (delete-file tmp))))))

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

(defun embr--save-session ()
  "Save current tab URLs and active index to the session file."
  (when (and embr--use-custom-session
             embr-session-restore
             (not embr--incognito-flag)
             embr--tab-list)
    (let* ((active-idx 0)
           (urls nil)
           (i 0))
      (dolist (tab embr--tab-list)
        (let ((url (alist-get 'url tab)))
          (unless (string= url "about:blank")
            (when (eq (alist-get 'active tab) t)
              (setq active-idx (length urls)))
            (push url urls)))
        (setq i (1+ i)))
      (setq urls (nreverse urls))
      (when urls
        (with-temp-file embr--session-file
          (insert (json-serialize
                   `((urls . ,(vconcat urls))
                     (active . ,active-idx)))))))))

(defun embr--save-session-on-exit ()
  "Save session for the normal buffer on Emacs exit."
  (when (and embr--use-custom-session embr-session-restore
             (buffer-live-p embr--normal-buffer))
    (with-current-buffer embr--normal-buffer
      (embr--save-session))))

(add-hook 'kill-emacs-hook #'embr--save-session-on-exit)

(defun embr--restore-session ()
  "Restore tabs from the session file.
Return the number of tabs restored, or nil."
  (when (and embr--use-custom-session
             embr-session-restore
             (not embr--incognito-flag)
             (file-exists-p embr--session-file))
    (let* ((json-str (with-temp-buffer
                       (insert-file-contents embr--session-file)
                       (buffer-string)))
           (data (json-parse-string json-str :object-type 'alist
                                             :array-type 'list))
           ;; Support both old format (plain URL array) and new format.
           (urls (if (alist-get 'urls data)
                     (alist-get 'urls data)
                   data))
           (active (or (alist-get 'active data) 0))
           (count 0))
      (delete-file embr--session-file)
      (when urls
        ;; Navigate the initial tab to the first URL.
        (embr--send-sync `((cmd . "navigate") (url . ,(car urls))))
        (setq count 1)
        ;; Open remaining URLs as new tabs.
        (dolist (url (cdr urls))
          (let ((r (embr--send-sync `((cmd . "new-tab") (url . ,url)))))
            (when (alist-get 'ok r)
              (setq count (1+ count)))))
        ;; Switch to the tab that was active when session was saved.
        (embr--send-sync `((cmd . "switch-tab") (index . ,active)))
        ;; Update tab list with all tabs present.
        (let ((tr (embr--send-sync '((cmd . "list-tabs")))))
          (embr--update-tab-list-from-resp tr))
        count))))

(defun embr-quit ()
  "Kill the daemon and close the buffer."
  (interactive)
  (embr--save-session)
  (when (and embr--process (process-live-p embr--process))
    (embr--send '((cmd . "quit")))
    (sit-for 0.5)
    (when (and embr--process (process-live-p embr--process))
      (delete-process embr--process)))
  (embr--hover-stop)
  (embr--backend-shutdown)
  (setq embr--process nil
        embr--frame-path nil)
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


(defun embr--scroll-delta ()
  "Return the scroll delta in pixels."
  embr-scroll-step)

(defun embr--scroll-behavior ()
  "Return the scroll behavior string based on `embr-scroll-method'."
  (pcase embr-scroll-method
    ('smooth "smooth")
    (_ "instant")))

(defun embr-scroll-down (event)
  "Scroll down in the browser on mouse wheel EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (or (car xy) 0))
         (y (or (cdr xy) 0))
         (delta (embr--scroll-delta)))
    (embr--send `((cmd . "scroll") (x . ,x) (y . ,y)
                         (delta_x . 0) (delta_y . ,delta)
                         (behavior . ,(embr--scroll-behavior)))
                       #'embr--action-callback)))

(defun embr-scroll-up (event)
  "Scroll up in the browser on mouse wheel EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (or (car xy) 0))
         (y (or (cdr xy) 0))
         (delta (embr--scroll-delta)))
    (embr--send `((cmd . "scroll") (x . ,x) (y . ,y)
                         (delta_x . 0) (delta_y . ,(- delta))
                         (behavior . ,(embr--scroll-behavior)))
                       #'embr--action-callback)))

;; ── Hover tracking ────────────────────────────────────────────────

(defun embr--hover-tick (buf)
  "Send mouse position to the browser if it changed.
BUF is the embr buffer that owns this timer."
  (when (and (buffer-live-p buf) (eq (current-buffer) buf))
    (with-current-buffer buf
      (when (and embr--process (process-live-p embr--process))
        (let* ((pos (mouse-pixel-position))
               (frame (car pos))
               (px (cadr pos))
               (py (cddr pos)))
          (when (and frame px py (eq frame (selected-frame)))
            ;; Convert frame pixel position to image coordinates.
            (let* ((win (get-buffer-window buf))
                   (edges (and win (window-inside-pixel-edges win)))
                   (img-x (and edges (- px (nth 0 edges))))
                   (img-y (and edges (- py (nth 1 edges)))))
              ;; Clamp to viewport bounds — out-of-bounds coords confuse Playwright.
              (when img-x
                (setq img-x (max 0 (min img-x (1- (or embr--viewport-width embr-default-width))))))
              (when img-y
                (setq img-y (max 0 (min img-y (1- (or embr--viewport-height embr-default-height))))))
              ;; Distance threshold: filter sub-pixel jitter.
              (let* ((dx (- (or img-x 0) (or embr--hover-last-x img-x 0)))
                     (dy (- (or img-y 0) (or embr--hover-last-y img-y 0)))
                     (dist (sqrt (+ (* dx dx) (* dy dy))))
                     ;; Rate self-throttle: use min rate under pressure.
                     (rate (if embr--pressure embr-hover-rate-min embr-hover-rate))
                     (min-interval (/ 1.0 rate))
                     (now (float-time)))
                (when (and img-x img-y
                           (>= dist embr-hover-move-threshold-px)
                           (or (null embr--hover-last-send-time)
                               (>= (- now embr--hover-last-send-time) min-interval)))
                  (setq embr--hover-last-x img-x
                        embr--hover-last-y img-y
                        embr--hover-last-send-time now)
                  ;; Write directly to process — don't touch embr--callback.
                  (process-send-string
                   embr--process
                   (concat (json-serialize `((cmd . "mousemove") (x . ,img-x) (y . ,img-y))) "\n")))))))))))


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
      (when embr--pending-frame
        (let ((frame embr--pending-frame))
          (setq embr--pending-frame nil)
          (embr--handle-frame frame))))))

(defun embr--render-start ()
  "Start the frame render timer at `embr-fps' Hz."
  (embr--render-stop)
  (let ((buf (current-buffer)))
    (setq embr--render-timer
          (run-at-time 0 (/ 1.0 embr-fps)
                       (lambda () (embr--render-tick buf))))))

(defun embr--render-stop ()
  "Stop the frame render timer."
  (when embr--render-timer
    (cancel-timer embr--render-timer)
    (setq embr--render-timer nil
          embr--pending-frame nil)))

;; ── Link hints ─────────────────────────────────────────────────────

(defun embr-follow-hint ()
  "Show link hints on all clickable elements, then follow the chosen one."
  (interactive)
  (let ((resp (embr--send-sync '((cmd . "hints")))))
    (if-let* ((err (alist-get 'error resp)))
        (message "embr error: %s" err)
      (let* ((hints (alist-get 'hints resp))
             (tags (mapcar (lambda (h) (alist-get 'tag h)) hints)))
        (if (null tags)
            (message "embr: no clickable elements found")
          (setq embr--hints hints)
          ;; Brief pause for the hint overlay frame to arrive.
          (run-at-time 0.1 nil #'embr--read-hint))))))

(defun embr--read-hint ()
  "Read a hint tag from the user and click it."
  (let* ((descriptions (mapcar (lambda (h)
                                 (format "%s: %s" (alist-get 'tag h)
                                         (alist-get 'text h)))
                               embr--hints))
         (chosen (condition-case nil
                     (completing-read "Hint: " descriptions nil t)
                   (quit nil))))
    ;; Always clear hints, whether user picked one or cancelled.
    (embr--send '((cmd . "hints-clear")) nil)
    (when (and chosen (string-match "\\`\\([^:]+\\):" chosen))
      (let* ((tag (match-string 1 chosen))
             (hint (seq-find (lambda (h) (string= (alist-get 'tag h) tag))
                             embr--hints)))
        (when hint
          (embr--send `((cmd . "click")
                               (x . ,(alist-get 'x hint))
                               (y . ,(alist-get 'y hint)))
                             #'embr--action-callback))))))

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

(defun embr--mouse-image-coords ()
  "Return mouse position as image coordinates (X . Y), or nil."
  (let* ((pos (mouse-pixel-position))
         (frame (car pos))
         (px (cadr pos))
         (py (cddr pos)))
    (when (and frame px py (eq frame (selected-frame)))
      (let* ((win (get-buffer-window (current-buffer)))
             (edges (and win (window-inside-pixel-edges win))))
        (when edges
          (cons (max 0 (min (- px (nth 0 edges))
                            (1- (or embr--viewport-width embr-default-width))))
                (max 0 (min (- py (nth 1 edges))
                            (1- (or embr--viewport-height embr-default-height))))))))))

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
  (let ((resp (embr--send-sync '((cmd . "hints")))))
    (if-let* ((err (alist-get 'error resp)))
        (message "embr error: %s" err)
      (let* ((hints (alist-get 'hints resp)))
        (if (null hints)
            (message "embr: no links found")
          (setq embr--hints hints)
          (run-at-time 0.1 nil #'embr--read-download-hint))))))

(defun embr--read-download-hint ()
  "Read a hint tag from the user and download its link."
  (let* ((descriptions (mapcar (lambda (h)
                                 (format "%s: %s" (alist-get 'tag h)
                                         (alist-get 'text h)))
                               embr--hints))
         (chosen (condition-case nil
                     (completing-read "Download hint: " descriptions nil t)
                   (quit nil))))
    (embr--send '((cmd . "hints-clear")) nil)
    (when (and chosen (string-match "\\`\\([^:]+\\):" chosen))
      (let* ((tag (match-string 1 chosen))
             (hint (seq-find (lambda (h) (string= (alist-get 'tag h) tag))
                             embr--hints)))
        (when hint
          (let ((href (alist-get 'href hint)))
            (if href
                (embr--download-url href)
              (message "embr: selected element is not a link"))))))))

(defun embr-copy-url ()
  "Copy the current page URL to the kill ring."
  (interactive)
  (let* ((resp (embr--send-sync '((cmd . "query-url"))))
         (url (or (alist-get 'url resp) embr--current-url)))
    (embr--update-metadata resp)
    (kill-new url)
    (message "Copied: %s" url)))

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

(defun embr--maybe-end-search ()
  "Clear search state if the next command is not a search command."
  (unless (memq this-command '(embr-isearch-forward embr-isearch-backward))
    (setq embr--searching nil)))

(defun embr--find-on-page (backwards)
  "Run window.find() with the current search query.  Search BACKWARDS if non-nil."
  (setq embr--searching t)
  (let ((escaped (replace-regexp-in-string "'" "\\\\'" embr--search-query)))
    (embr--send
     `((cmd . "js")
       (expr . ,(format "window.find('%s', false, %s, true)"
                        escaped (if backwards "true" "false"))))
     (lambda (resp)
       (if-let* ((err (alist-get 'error resp)))
           (message "embr find error: %s" err)
         (if (eq (alist-get 'result resp) :false)
             (message "embr: no more matches")
           (message "Search: %s" embr--search-query)))))))

(defun embr-isearch-forward ()
  "Search forward.  First call prompts for query; repeating finds next match."
  (interactive)
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
  (if (and embr--searching
           (not (string-empty-p embr--search-query)))
      (embr--find-on-page t)
    (setq embr--searching nil)
    (let ((query (read-string "Search backward: " embr--search-query)))
      (unless (string-empty-p query)
        (setq embr--search-query query)
        (embr--find-on-page t)))))

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
  "Update `embr--tab-list' from the `tabs' field in RESP if present."
  (when-let* ((tabs (alist-get 'tabs resp)))
    (setq embr--tab-list
          (mapcar (lambda (v) (append v nil)) tabs))
    (embr--refresh-tab-bar)))

(defun embr--refresh-tab-list ()
  "Fetch tab list from daemon and update the tab bar."
  (when (and embr-tab-bar embr--process (process-live-p embr--process))
    (let ((resp (embr--send-sync '((cmd . "list-tabs")))))
      (embr--update-tab-list-from-resp resp))))

(defun embr--refresh-tab-bar ()
  "Trigger a tab-line redisplay from cached tab list."
  (when (and embr-tab-bar embr--tab-list)
    (force-mode-line-update)))

;; ── Tabs ───────────────────────────────────────────────────────────

(defun embr-new-tab (url)
  "Open URL in a new tab, or search if input doesn't look like a URL."
  (interactive (list (completing-read "URL/Search for new tab: "
                                      (unless embr--incognito-flag embr--url-history)
                                      nil nil nil
                                      (unless embr--incognito-flag 'embr--url-history))))
  (let ((target (embr--maybe-search-url url)))
    (embr--send `((cmd . "new-tab") (url . ,target))
                (lambda (resp)
                  (embr--action-callback resp)
                  (embr--update-tab-list-from-resp resp)))))

(defun embr-close-tab ()
  "Close the current tab.
If this is the last tab, kill the embr buffer."
  (interactive)
  (embr--send '((cmd . "close-tab"))
              (lambda (resp)
                (if (alist-get 'last_tab resp)
                    (kill-buffer (current-buffer))
                  (embr--action-callback resp)
                  (embr--update-tab-list-from-resp resp)))))

(defun embr-next-tab ()
  "Switch to the next tab."
  (interactive)
  (embr--send '((cmd . "list-tabs"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr error: %s" err)
                  (let* ((tabs (alist-get 'tabs resp))
                         (cur (seq-position tabs t
                                (lambda (tab _) (eq (alist-get 'active tab) t))))
                         (next (if cur (mod (1+ cur) (length tabs)) 0)))
                    (embr--send `((cmd . "switch-tab") (index . ,next))
                                (lambda (r)
                                  (embr--action-callback r)
                                  (embr--update-tab-list-from-resp r))))))))

(defun embr-prev-tab ()
  "Switch to the previous tab."
  (interactive)
  (embr--send '((cmd . "list-tabs"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr error: %s" err)
                  (let* ((tabs (alist-get 'tabs resp))
                         (cur (seq-position tabs t
                                (lambda (tab _) (eq (alist-get 'active tab) t))))
                         (prev (if cur (mod (1- cur) (length tabs))
                                 (1- (length tabs)))))
                    (embr--send `((cmd . "switch-tab") (index . ,prev))
                                (lambda (r)
                                  (embr--action-callback r)
                                  (embr--update-tab-list-from-resp r))))))))

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
  (let ((resp (embr--send-sync '((cmd . "hints")))))
    (if-let* ((err (alist-get 'error resp)))
        (message "embr error: %s" err)
      (let* ((hints (alist-get 'hints resp)))
        (if (null hints)
            (message "embr: no links found")
          (setq embr--hints hints)
          (run-at-time 0.1 nil #'embr--read-copy-link-hint))))))

(defun embr--read-copy-link-hint ()
  "Read a hint tag from the user and copy its link."
  (let* ((descriptions (mapcar (lambda (h)
                                 (format "%s: %s" (alist-get 'tag h)
                                         (alist-get 'text h)))
                               embr--hints))
         (chosen (condition-case nil
                     (completing-read "Copy link hint: " descriptions nil t)
                   (quit nil))))
    (embr--send '((cmd . "hints-clear")) nil)
    (when (and chosen (string-match "\\`\\([^:]+\\):" chosen))
      (let* ((tag (match-string 1 chosen))
             (hint (seq-find (lambda (h) (string= (alist-get 'tag h) tag))
                             embr--hints)))
        (when hint
          (let ((href (alist-get 'href hint)))
            (if href
                (progn
                  (kill-new href)
                  (message "Copied: %s" href))
              (message "embr: selected element is not a link"))))))))

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

(defvar embr--incognito-buffer nil "The incognito display buffer.")

;;;###autoload
(defun embr-browse-incognito (url)
  "Launch an incognito embr session and navigate to URL."
  (interactive "sURL: ")
  (when (embr--setup-needed-p)
    (error "embr: Run M-x %s first"
           (if (eq embr-browser-engine 'chromium)
               "embr-install-or-update-chromium"
             "embr-install-or-update-cloakbrowser")))
  ;; Create buffer.
  (unless (buffer-live-p embr--incognito-buffer)
    (setq embr--incognito-buffer (generate-new-buffer "*embr incognito*"))
    (with-current-buffer embr--incognito-buffer
      (embr-mode)
      (setq embr--incognito-flag t)))
  (switch-to-buffer embr--incognito-buffer)
  (with-current-buffer embr--incognito-buffer
    ;; Start daemon.
    (unless (and embr--process (process-live-p embr--process))
      (setq embr--viewport-width (or embr--viewport-width embr-default-width)
            embr--viewport-height (or embr--viewport-height embr-default-height))
      (let* ((inner (list embr-python embr-script))
             (xvfb (and (eq embr-display-method 'headed-offscreen)
                        (executable-find "xvfb-run")))
             (command
              (if xvfb
                  (append (list xvfb "--auto-servernum"
                                "--server-args=-screen 0 1920x1080x24")
                          inner)
                inner))
             (process-environment
              (cons (format "EMBR_ENGINE=%s"
                            (symbol-name embr-browser-engine))
                    (cons "EMBR_INCOGNITO=1"
                          (cons (format "EMBR_DISPLAY=%s"
                                        (if xvfb "headed-offscreen"
                                          (symbol-name embr-display-method)))
                                process-environment)))))
        (setq embr--process
              (make-process
               :name "embr-incognito"
               :command command
               :connection-type 'pipe
               :noquery t
               :stderr (get-buffer-create "*embr-incognito-stderr*")
               :filter #'embr--process-filter
               :sentinel #'embr--process-sentinel))
        (process-put embr--process 'embr-buffer embr--incognito-buffer))
      (let ((resp (embr--send-sync (embr--build-init-params))))
        (if (alist-get 'error resp)
            (progn
              (when (and embr--process (process-live-p embr--process))
                (delete-process embr--process))
              (setq embr--process nil)
              (error "embr incognito: init failed: %s" (alist-get 'error resp)))
          (setq embr--frame-path (alist-get 'frame_path resp))
          (setq embr--proxy-active (and embr-proxy-rules t))
          (when embr-tab-bar
            (let ((tr (embr--send-sync '((cmd . "list-tabs")))))
              (unless (alist-get 'error tr)
                (setq embr--tab-list
                      (mapcar (lambda (v) (append v nil))
                              (alist-get 'tabs tr))))))
          (embr--hover-start)
          (embr--backend-init
           (or (alist-get 'render_backend resp) "default")
           (alist-get 'frame_socket_path resp))
          (message "embr incognito: %s transport, %s backend"
                   (or (alist-get 'frame_source resp) "unknown")
                   (embr--backend-name))
          (when (eq embr-viewport-sizing 'dynamic)
            (embr--resize-hook-install)
            (let ((buf (current-buffer)))
              (run-at-time 0.5 nil
                           (lambda () (embr--do-resize buf)))))))))
  (embr-navigate url))

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
  "Forward the current key to the browser."
  (interactive)
  (let* ((keys (this-command-keys-vector))
         (key-desc (key-description keys))
         (pw-key (embr--translate-key key-desc)))
    (if (= (length pw-key) 1)
        (embr--send `((cmd . "type") (text . ,pw-key))
                           #'embr--action-callback)
      (embr--send `((cmd . "key") (key . ,pw-key))
                         #'embr--action-callback))))

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
;; 1. Hardcoded base path -- ~/.local/share/embr/chromium-profile/Default/
;;    as a defconst, not derived from any variable at runtime.
;; 2. Sanity check on entry -- verifies the profile dir string starts
;;    with ~/.local/share/embr/ before doing anything.
;; 3. Per-path check -- every expanded glob result is verified to be
;;    inside the profile dir before deletion, refuses with error if not.
;; 4. Nuclear option -- same sanity check, hardcoded path.

(defconst embr--profile-dir
  (expand-file-name "~/.local/share/embr/chromium-profile/Default/")
  "Hardcoded path to Chromium profile Default directory.")

(defun embr--clear-profile-paths (globs description)
  "Delete GLOBS under the Chromium profile after confirmation.
GLOBS is a list of file/directory names to match.
DESCRIPTION is shown in the prompt."
  (unless (and (stringp embr--profile-dir)
               (string-prefix-p (expand-file-name "~/.local/share/embr/")
                                embr--profile-dir))
    (error "embr: profile path sanity check failed"))
  (when (y-or-n-p (format "Clear %s? " description))
    (dolist (glob globs)
      (dolist (path (file-expand-wildcards
                     (expand-file-name glob embr--profile-dir)))
        (unless (string-prefix-p embr--profile-dir path)
          (error "embr: refusing to delete outside profile: %s" path))
        (if (file-directory-p path)
            (delete-directory path t)
          (delete-file path))))
    (message "embr: cleared %s" description)))

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
  "Delete the entire chromium profile and clear URL history."
  (interactive)
  (when (y-or-n-p "Delete entire chromium profile and URL history? ")
    (let ((profile (expand-file-name
                    "~/.local/share/embr/chromium-profile")))
      (unless (string-prefix-p (expand-file-name "~/.local/share/embr/")
                               profile)
        (error "embr: profile path sanity check failed"))
      (when (file-directory-p profile)
        (delete-directory profile t)))
    (setq embr--url-history nil)
    (message "embr: chromium profile deleted, URL history cleared")))

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
    ;; All printable characters → forward to browser.
    (dolist (c (number-sequence 32 126))
      (define-key map (vector c) #'embr-self-insert))
    ;; Override & for external player (like eww).
    (define-key map (kbd "&") #'embr-play-external)
    (define-key map (kbd "<f5>") #'embr-refresh)
    ;; Special keys → forward to browser.
    (dolist (key '("<return>" "<backspace>" "<tab>" "<delete>"
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

    (define-key map [wheel-down] #'embr-scroll-down)
    (define-key map [wheel-up] #'embr-scroll-up)

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
  (setq-local embr--response-buffer "")
  (setq-local embr--callback nil)
  (setq-local embr--current-url "")
  (setq-local embr--current-title "")
  (setq-local embr--viewport-width nil)
  (setq-local embr--viewport-height nil)
  (setq-local embr--frame-path nil)
  (setq-local embr--hints nil)
  (setq-local embr--hover-timer nil)
  (setq-local embr--hover-last-x nil)
  (setq-local embr--hover-last-y nil)
  (setq-local embr--hover-last-send-time nil)
  (setq-local embr--pending-frame nil)
  (setq-local embr--render-timer nil)
  (setq-local embr--pressure nil)
  (setq-local embr--active-backend nil)
  (setq-local embr--canvas-image nil)
  (setq-local embr--canvas-socket nil)
  (setq-local embr--canvas-recv-buf "")
  (setq-local embr--canvas-last-seq 0)
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
  (setq-local buffer-read-only t)
  (setq-local cursor-type nil)
  (setq-local void-text-area-pointer 'arrow)
  (setq-local pointer-shape 'arrow)
  (setq-local bookmark-make-record-function #'embr--bookmark-make-record)
  (setq-local header-line-format
              '(:eval (let ((url (if (> (length embr--current-url) 40)
                                     (concat (substring embr--current-url 0 40) "...")
                                   embr--current-url)))
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
                           (format " [%d%%]" (round (* embr--zoom-level 100))))))))
  (when embr-tab-bar
    (setq-local tab-line-format '(:eval (embr--render-tab-bar))))
  (add-hook 'pre-command-hook #'embr--maybe-end-search nil t)
  (add-hook 'kill-buffer-hook #'embr--kill-buffer-cleanup nil t))

(defun embr--kill-buffer-cleanup ()
  "Shut down the daemon when the buffer is killed by any means."
  (embr--save-session)
  (when (and embr--process (process-live-p embr--process))
    (process-send-string
     embr--process
     (concat (json-serialize '((cmd . "quit"))) "\n"))
    (sit-for 0.3)
    (when (and embr--process (process-live-p embr--process))
      (delete-process embr--process)))
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
    ("/" "Search forward" embr-isearch-forward)
    ("?" "Search backward" embr-isearch-backward)]
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
    (define-key map (kbd "/") #'embr-isearch-forward)
    (define-key map (kbd "?") #'embr-isearch-backward)
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

(define-minor-mode embr-vimium-mode
  "Toggle vimium-style modal keybindings for embr.
In normal mode, bare keys act as vim-style navigation.
In insert mode, keys pass through to the browser."
  :lighter nil
  (if embr-vimium-mode
      (progn
        (setq embr-vimium--insert-mode (not embr-vimium-start-in-normal))
        (setf (alist-get 'embr-vimium-mode minor-mode-overriding-map-alist)
              (if embr-vimium-start-in-normal
                  embr-vimium-normal-map
                embr-vimium-insert-map))
        (force-mode-line-update))
    (setq embr-vimium--insert-mode nil)
    (setq minor-mode-overriding-map-alist
          (assq-delete-all 'embr-vimium-mode minor-mode-overriding-map-alist))
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
              (unless (and (eql new-w embr--viewport-width)
                           (eql new-h embr--viewport-height))
                (setq embr--viewport-width new-w
                      embr--viewport-height new-h)
                ;; Recreate canvas BEFORE telling the daemon to
                ;; resize, so the new (larger) pixel buffer is ready
                ;; before larger frames arrive.
                (when (equal embr--active-backend "canvas")
                  (embr--canvas-resize new-w new-h))
                ;; Fire-and-forget -- bypass embr--send to avoid
                ;; clobbering the single callback slot.
                (process-send-string
                 embr--process
                 (concat (json-serialize
                          `((cmd . "resize")
                            (width . ,new-w)
                            (height . ,new-h)))
                         "\n"))))))))))

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

;;;###autoload
(defun embr-browse (&optional url _new-window)
  "Launch embr and navigate to URL.
When called interactively, open about:blank.  When called from
Lisp with a URL argument, navigate to that URL."
  (interactive)
  ;; Check if setup has been run.
  (when (embr--setup-needed-p)
    (let ((install-fn (if (eq embr-browser-engine 'chromium)
                          #'embr-install-or-update-chromium
                        #'embr-install-or-update-cloakbrowser)))
      (if (y-or-n-p (format "embr: Setup needed (venv or %s missing). Run now? "
                            embr-browser-engine))
          (progn
            (funcall install-fn)
            (user-error "embr: Setup started in *embr-setup* buffer.  Run M-x embr-browse again when it finishes"))
        (user-error "embr: Run M-x %s first" (symbol-name install-fn)))))
  ;; Create buffer if needed.
  (unless (buffer-live-p embr--normal-buffer)
    (setq embr--normal-buffer (generate-new-buffer "*embr*"))
    (with-current-buffer embr--normal-buffer
      (embr-mode)))
  (switch-to-buffer embr--normal-buffer)
  (with-current-buffer embr--normal-buffer
    ;; Start daemon if needed.
    (unless (and embr--process (process-live-p embr--process))
      ;; Always init at safe default size.  In dynamic mode, a
      ;; deferred timer resizes to the window dimensions after the
      ;; backend is fully up (avoids a canvas init race at large sizes).
      (setq embr--viewport-width (or embr--viewport-width embr-default-width)
            embr--viewport-height (or embr--viewport-height embr-default-height))
      (embr--start-daemon)
      (let ((resp (embr--send-sync (embr--build-init-params))))
        (if (alist-get 'error resp)
            (progn
              (when (and embr--process (process-live-p embr--process))
                (delete-process embr--process))
              (setq embr--process nil)
              (error "embr: init failed: %s" (alist-get 'error resp)))
          ;; Daemon tells us where it writes frames.
          (setq embr--frame-path (alist-get 'frame_path resp))
          (setq embr--proxy-active (and embr-proxy-rules t))
          ;; Restore session or navigate before starting frames.
          (let ((restored (embr--restore-session)))
            (if restored
                (progn
                  (message "embr: session restored (%d tab%s)"
                           restored (if (= restored 1) "" "s"))
                  (when url
                    (embr--send-sync
                     `((cmd . "new-tab") (url . ,url)))))
              (embr--send-sync
               `((cmd . "navigate")
                 (url . ,(or url embr-home-url))))))
          ;; Populate tab list after all tabs exist, before first frame.
          (when embr-tab-bar
            (let ((tr (embr--send-sync '((cmd . "list-tabs")))))
              (unless (alist-get 'error tr)
                (setq embr--tab-list
                      (mapcar (lambda (v) (append v nil))
                              (alist-get 'tabs tr))))))
          (embr--hover-start)
          (embr--backend-init
           (or (alist-get 'render_backend resp) "default")
           (alist-get 'frame_socket_path resp))
          (message "embr: %s transport, %s backend"
                   (or (alist-get 'frame_source resp) "unknown")
                   (embr--backend-name))
          (when (eq embr-viewport-sizing 'dynamic)
            (embr--resize-hook-install)
            (let ((buf (current-buffer)))
              (run-at-time 0.5 nil
                           (lambda () (embr--do-resize buf))))))))
    ;; Daemon already running -- open URL in a new tab.
    (when url
      (embr--send-sync `((cmd . "new-tab") (url . ,url))))))

(provide 'embr)

;;; embr.el ends here
