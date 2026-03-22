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

;; embr runs a headless Chromium (via CloakBrowser/Playwright) and
;; displays screenshots in an Emacs buffer.  Clicks, keystrokes, and
;; scroll events are forwarded to the browser.  The daemon streams
;; JPEG frames via a temp file on disk, giving live visual feedback.
;;
;; The Python daemon (`embr.py') controls the browser through
;; CloakBrowser, a stealth Chromium with source-level fingerprint
;; patches.  Communication uses JSON lines over stdin/stdout.

;;; Code:

(require 'cl-lib)
(require 'image)
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

(defcustom embr-default-width 1280
  "Default viewport width in pixels."
  :type 'integer)

(defcustom embr-default-height 720
  "Default viewport height in pixels."
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
  "Deprecated. Screenshot-only. JPEG quality (1-100) for screenshot captures."
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
CloakBrowser choose from its fingerprint profile."
  :type '(choice (const :tag "Dark" dark)
                 (const :tag "Light" light)
                 (const :tag "Auto (CloakBrowser default)" nil)))

(defcustom embr-dom-caret-hack t
  "Whether to inject a fake DOM caret in focused text fields.
CDP screenshots do not capture the native browser caret, so embr
injects a thin DOM element that tracks the cursor position.  Set
to nil to disable."
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
`headless' runs Chromium in headless mode (no window, no audio).
`headed' runs Chromium on your real display (visible window, audio).
`headed-offscreen' runs Chromium headed on a virtual display via
xvfb-run (invisible window, audio works via PulseAudio/PipeWire)."
  :type '(choice (const :tag "Headless (no window, no audio)" headless)
                 (const :tag "Headed (visible window, audio)" headed)
                 (const :tag "Headed offscreen (hidden window, audio)" headed-offscreen)))

(defcustom embr-dispatch-key "C-c"
  "Key that opens the transient dispatch menu.
Must be set before embr is loaded."
  :type 'string)

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
  "Return non-nil if setup.sh needs to be run.
Checks that both the venv Python and the cloakbrowser package exist."
  (or (not (file-exists-p embr-python))
      (not (zerop
            (call-process embr-python nil nil nil
                          "-c" "import cloakbrowser")))))

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
(defun embr-setup-or-update-all ()
  "Install or update CloakBrowser, ad blocklist, and uBlock Origin.
Note: uBlock Origin requires one-time manual setup in headed mode.
See README.md for instructions."
  (interactive)
  (embr--run-setup '("--all") "Done. You can now run M-x embr-browse."))

;;;###autoload
(defun embr-update-blocklist ()
  "Update the ad/tracker domain blocklist."
  (interactive)
  (embr--run-setup '("--blocklist") "Blocklist updated."))

;;;###autoload
(defun embr-update-ublock ()
  "Update uBlock Origin to the latest release.
Note: uBlock Origin requires one-time manual setup in headed mode.
See README.md for instructions."
  (interactive)
  (embr--run-setup '("--ublock") "uBlock Origin updated."))

;;;###autoload
(defun embr-uninstall ()
  "Remove the Python venv, CloakBrowser, and browser profile.
Does not remove the Emacs package itself."
  (interactive)
  (let ((script (expand-file-name "uninstall.sh" embr--directory)))
    (unless (file-exists-p script)
      (error "embr: uninstall.sh not found in %s" embr--directory))
    (let ((buf (get-buffer-create "*embr-setup*")))
      (with-current-buffer buf (erase-buffer))
      (pop-to-buffer buf)
      (insert (format "Running uninstall.sh in %s ...\n\n" embr--directory))
      ;; Run with yes piped to stdin to auto-confirm (user already confirmed via M-x).
      (when (y-or-n-p "Remove Python venv and browser profile? ")
        (let* ((also-browsers (y-or-n-p "Also delete CloakBrowser's browser cache (~/.cloakbrowser)? "))
               (input (concat "y\n" (if also-browsers "y\n" "n\n")))
               (proc (start-process "embr-uninstall" buf "bash" "-c"
                                     (format "echo %s | bash %s"
                                             (shell-quote-argument input)
                                             (shell-quote-argument script)))))
          (set-process-sentinel
           proc
           (lambda (_proc event)
             (when (string-match-p "finished" event)
               (with-current-buffer (get-buffer "*embr-setup*")
                 (goto-char (point-max))
                 (insert "\nDone.\n"))))))))))

;;;###autoload
(defun embr-info ()
  "Show diagnostic info about the embr installation."
  (interactive)
  (let ((venv-dir (expand-file-name ".venv" embr--data-dir))
        (browsers-dir (expand-file-name ".cloakbrowser" "~"))
        (profile-dir (expand-file-name "chromium-profile" embr--data-dir)))
    (message "embr installation:
  Source:     %s
  Python:     %s (%s)
  Script:     %s (%s)
  Venv:       %s (%s)
  Browsers:   %s (%s)
  Profile:    %s (%s)
  Setup needed: %s"
             embr--directory
             embr-python (if (file-exists-p embr-python) "OK" "MISSING")
             embr-script (if (file-exists-p embr-script) "OK" "MISSING")
             venv-dir (if (file-directory-p venv-dir) "OK" "MISSING")
             browsers-dir (if (file-directory-p browsers-dir) "OK" "MISSING")
             profile-dir (if (file-directory-p profile-dir) "exists" "not yet created")
             (embr--setup-needed-p))))

;; ── Internal state ─────────────────────────────────────────────────

(defvar embr--process nil "The daemon subprocess.")
(defvar embr--buffer nil "The display buffer.")
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
(defvar embr--default-frame-count 0 "Total frames rendered via default backend.")

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
          (cons (format "EMBR_DISPLAY=%s"
                        (if xvfb "headed-offscreen"
                          (symbol-name embr-display-method)))
                process-environment)))
    (setq embr--process
          (make-process
           :name "embr"
           :command command
           :connection-type 'pipe
           :noquery t
           :stderr (get-buffer-create "*embr-stderr*")
           :filter #'embr--process-filter
           :sentinel #'embr--process-sentinel))))

(defun embr--process-filter (_proc output)
  "Handle OUTPUT from the daemon process."
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
                   (embr--update-metadata resp))
                  ((alist-get 'screencast_error resp)
                   ;; Screencast error notification — always show to user.
                   (message "embr: %s" (alist-get 'screencast_error resp)))
                  (t
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
      (setq embr--pending-frame last-frame))))

(defun embr--process-sentinel (_proc event)
  "Handle process EVENT (e.g. exit)."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (message "embr: daemon exited: %s" (string-trim event))
    (embr--hover-stop)
    (embr--backend-shutdown)
    (setq embr--process nil)))

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
  (if (string= embr--active-backend "default")
      (embr--default-display-frame resp)
    ;; Canvas: pixel data arrives via socket, nothing to do here.
    nil))

(defun embr--backend-shutdown ()
  "Shut down the active render backend."
  (embr--render-stop)
  (embr--backend-shutdown-canvas)
  (setq embr--active-backend nil))

;; ── Legacy backend ────────────────────────────────────────────────

(defun embr--default-display-frame (_resp)
  "Read JPEG from disk and display in buffer."
  (when (and embr--frame-path
             (file-exists-p embr--frame-path)
             (buffer-live-p embr--buffer))
    (let ((data (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally embr--frame-path)
                  (buffer-string))))
      (with-current-buffer embr--buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert-image (create-image data 'jpeg t))
          (remove-text-properties (point-min) (point-max) '(keymap nil))
          (put-text-property (point-min) (point-max) 'pointer 'arrow)
          (goto-char (point-min)))))
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

(defun embr--canvas-socket-filter (_proc data)
  "Handle binary frame data from the canvas socket.
Parse length-prefixed packets, drop stale/out-of-order frames,
and blit the latest to the canvas."
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
                            (error-message-string err))))))))))))

(defun embr--canvas-socket-sentinel (_proc event)
  "Handle canvas socket disconnect."
  (when (string-match-p "\\(closed\\|connection broken\\)" event)
    (message "embr: canvas socket closed")))

(defun embr--backend-init-canvas (socket-path)
  "Initialize the canvas render backend.
Connect to SOCKET-PATH and create the canvas image in the buffer."
  (setq embr--canvas-image
        `(image :type canvas
                :canvas-id embr-viewport-canvas
                :canvas-width ,embr--viewport-width
                :canvas-height ,embr--viewport-height))
  (setq embr--canvas-recv-buf ""
        embr--canvas-error-count 0
        embr--canvas-last-seq 0
        embr--canvas-stale-count 0)
  (with-current-buffer embr--buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize " " 'display embr--canvas-image))
      (put-text-property (point-min) (point-max) 'pointer 'arrow)
      (goto-char (point-min))))
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
         :noquery t)))

(defun embr--backend-shutdown-canvas ()
  "Shut down the canvas backend."
  (when (and embr--canvas-socket (process-live-p embr--canvas-socket))
    (delete-process embr--canvas-socket))
  (setq embr--canvas-socket nil
        embr--canvas-image nil
        embr--canvas-recv-buf ""))

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
    (when (buffer-live-p embr--buffer)
      ;; Backend-specific frame display.
      (embr--backend-on-frame resp)
      ;; Update URL from frame (title comes via metadata messages).
      (unless (string= url embr--current-url)
        (setq embr--current-url url)
        (with-current-buffer embr--buffer
          (force-mode-line-update)))
      ;; Send render ack for perf logging.
      (when (and embr-perf-log frame-id capture-mono
                 embr--process (process-live-p embr--process))
        (process-send-string
         embr--process
         (concat (json-serialize
                  `((cmd . "frame_rendered")
                    (frame_id . ,frame-id)
                    (capture_done_mono_ms . ,capture-mono)))
                 "\n"))))))

(defun embr--update-metadata (resp)
  "Update URL and title from command RESP if present."
  (let ((changed nil))
    (when-let* ((url (alist-get 'url resp)))
      (unless (string= url embr--current-url)
        (setq embr--current-url url
              changed t)))
    (when-let* ((title (alist-get 'title resp)))
      (unless (string= title embr--current-title)
        (setq embr--current-title title
              changed t)))
    (when (and changed (buffer-live-p embr--buffer))
      (with-current-buffer embr--buffer
        (rename-buffer (format "*embr: %s*"
                               (if (string-empty-p embr--current-title)
                                   embr--current-url embr--current-title))
                       t)
        (force-mode-line-update)))))

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
                            (lambda (str pred action)
                              (if (eq action 'metadata)
                                  '(metadata (display-sort-function . identity))
                                (complete-with-action
                                 action embr--url-history str pred)))
                            nil nil nil
                            'embr--url-history))))
  (if (or (null url) (string-empty-p url))
      ;; Empty input navigates to about:blank.
      (embr--send '((cmd . "navigate") (url . "about:blank"))
                  #'embr--action-callback)
    (let ((target (embr--maybe-search-url url)))
      (push url embr--url-history)
      (delete-dups embr--url-history)
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

(defun embr-history ()
  "Show browser history for the current tab and navigate to a selection."
  (interactive)
  (let* ((resp (embr--send-sync '((cmd . "history"))))
         (entries (alist-get 'entries resp)))
    (if (or (not entries) (null entries))
        (message "embr: no history")
      (let* ((candidates (mapcar (lambda (e)
                                   (let ((title (alist-get 'title e))
                                         (url (alist-get 'url e)))
                                     (cons (if (string-empty-p title)
                                               url
                                             (format "%s  —  %s" title url))
                                           url)))
                                 entries))
             (cands (mapcar #'car candidates))
             (chosen (completing-read "History: "
                                      (lambda (str pred action)
                                        (if (eq action 'metadata)
                                            '(metadata (display-sort-function . identity))
                                          (complete-with-action action cands str pred)))
                                      nil t)))
        (when chosen
          (let ((url (cdr (assoc chosen candidates))))
            (embr--send `((cmd . "navigate") (url . ,url))
                        #'embr--action-callback)))))))

(defun embr-quit ()
  "Kill the daemon and close the buffer."
  (interactive)
  (when (and embr--process (process-live-p embr--process))
    (embr--send '((cmd . "quit")))
    (sit-for 0.5)
    (when (process-live-p embr--process)
      (delete-process embr--process)))
  (embr--hover-stop)
  (embr--backend-shutdown)
  (setq embr--process nil
        embr--frame-path nil)
  (when (buffer-live-p embr--buffer)
    (kill-buffer embr--buffer)))

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

(defun embr--hover-tick ()
  "Send mouse position to the browser if it changed.  Runs on a timer."
  (when (and embr--process (process-live-p embr--process)
             (buffer-live-p embr--buffer)
             (eq (current-buffer) embr--buffer))
    (let* ((pos (mouse-pixel-position))
           (frame (car pos))
           (px (cadr pos))
           (py (cddr pos)))
      (when (and frame px py (eq frame (selected-frame)))
        ;; Convert frame pixel position to image coordinates.
        (let* ((win (get-buffer-window embr--buffer))
               (edges (and win (window-inside-pixel-edges win)))
               (img-x (and edges (- px (nth 0 edges))))
               (img-y (and edges (- py (nth 1 edges)))))
          ;; Clamp to viewport bounds — out-of-bounds coords confuse Playwright.
          (when img-x
            (setq img-x (max 0 (min img-x (1- (or embr--viewport-width embr-default-width))))))
          (when img-y
            (setq img-y (max 0 (min img-y (1- (or embr--viewport-height embr-default-height))))))
          ;; Distance threshold: filter sub-pixel jitter.
          (let* ((dx (- img-x (or embr--hover-last-x img-x)))
                 (dy (- img-y (or embr--hover-last-y img-y)))
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
              ;; Using embr--send here would clobber any pending command callback.
              (process-send-string
               embr--process
               (concat (json-serialize `((cmd . "mousemove") (x . ,img-x) (y . ,img-y))) "\n")))))))))


(defun embr--hover-start ()
  "Start the hover tracking timer."
  (embr--hover-stop)
  (setq embr--hover-timer (run-at-time 0 (/ 1.0 embr-hover-rate) #'embr--hover-tick)))

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

(defun embr--render-tick ()
  "Render the latest pending frame, if any.  Runs on a timer."
  (when embr--pending-frame
    (let ((frame embr--pending-frame))
      (setq embr--pending-frame nil)
      (embr--handle-frame frame))))

(defun embr--render-start ()
  "Start the frame render timer at `embr-fps' Hz."
  (embr--render-stop)
  (setq embr--render-timer
        (run-at-time 0 (/ 1.0 embr-fps) #'embr--render-tick)))

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
  (embr--send '((cmd . "hints"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "embr error: %s" err)
                         (let* ((hints (alist-get 'hints resp))
                                (tags (mapcar (lambda (h) (alist-get 'tag h)) hints)))
                           (if (null tags)
                               (message "embr: no clickable elements found")
                             (setq embr--hints hints)
                             ;; Frame stream will show the hint overlays.
                             ;; Read user input after a brief pause for the frame to arrive.
                             (run-at-time 0.1 nil #'embr--read-hint)))))))

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

(defun embr--mouse-image-coords ()
  "Return mouse position as image coordinates (X . Y), or nil."
  (let* ((pos (mouse-pixel-position))
         (frame (car pos))
         (px (cadr pos))
         (py (cddr pos)))
    (when (and frame px py (eq frame (selected-frame)))
      (let* ((win (get-buffer-window embr--buffer))
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

(defun embr-download ()
  "Download the link under the mouse cursor.
If the mouse is not over a link, fall back to hint selection."
  (interactive)
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
                        (embr--download-via-hints))))))))

(defun embr--download-via-hints ()
  "Show link hints, then download the chosen link."
  (embr--send '((cmd . "hints"))
              (lambda (resp)
                (if-let* ((err (alist-get 'error resp)))
                    (message "embr error: %s" err)
                  (let* ((hints (alist-get 'hints resp)))
                    (if (null hints)
                        (message "embr: no links found")
                      (setq embr--hints hints)
                      (run-at-time 0.1 nil #'embr--read-download-hint)))))))

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

;; ── Tabs ───────────────────────────────────────────────────────────

(defun embr-new-tab (url)
  "Open URL in a new tab, or search if input doesn't look like a URL."
  (interactive (list (completing-read "URL/Search for new tab: " embr--url-history nil nil nil
                                      'embr--url-history)))
  (let ((target (embr--maybe-search-url url)))
    (embr--send `((cmd . "new-tab") (url . ,target))
                       #'embr--action-callback)))

(defun embr-close-tab ()
  "Close the current tab."
  (interactive)
  (embr--send '((cmd . "close-tab"))
                     #'embr--action-callback))

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
                                              #'embr--action-callback))))))

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
                                              #'embr--action-callback))))))

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
    ("M-b" "Word left" embr-self-insert :transient nil)]
   ["Scroll / Page"
    ("C-v" "Page down" embr-self-insert :transient nil)
    ("M-v" "Page up" embr-self-insert :transient nil)]
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
    ("C-c" "You are here" embr-dispatch)
    ("q" "Close menu" embr-dispatch-close)]])

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

(defun embr-dispatch-close ()
  "Close the dispatch menu."
  (interactive))

(transient-define-prefix embr-dispatch ()
  "Show available embr browser commands."
  [["Navigation"
    ("g" "Reload" embr-refresh)
    ("l" "Back" embr-back)
    ("r" "Forward" embr-forward)
    ("p" "Past" embr-history)]
   ["Tabs"
    ("c" "New" embr-new-tab)
    ("x" "Close" embr-close-tab)
    ("]" "Next" embr-next-tab)
    ("[" "Previous" embr-prev-tab)
    ("s" "Switch" embr-list-tabs)]
   ["Bookmarks"
    ("b" "Add" bookmark-set)
    ("j" "Jump" bookmark-jump)
    ("f" "Forget" bookmark-delete)]
   ["Actions"
    ("o" "Open URL" embr-navigate)
    ("h" "Follow hint" embr-follow-hint)
    ("v" "View text" embr-view-text)
    ("e" "View source" embr-view-source)
    ("w" "Copy URL" embr-copy-url)
    ("d" "Download" embr-download)
    (":" "Execute JS" embr-execute-js)
    ("k" "Kill embr" embr-quit)
    ("q" "Close menu" embr-dispatch-close)
    ("?" "Top-level bindings" embr-dispatch-keys)]
   ["Privacy"
    ("1" "Clear cookies" embr-clear-cookies)
    ("2" "Clear cache" embr-clear-cache)
    ("3" "Clear local storage" embr-clear-local-storage)
    ("4" "Clear sessions" embr-clear-sessions)
    ("5" "Clear URL history" embr-clear-url-history)
    ("0" "Clear all (nuclear)" embr-clear-all)]])

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
    (define-key map (kbd "M-w") #'embr-copy)
    (define-key map (kbd "C-y") #'embr-paste)
    (define-key map (kbd "C-s") #'embr-isearch-forward)
    (define-key map (kbd "C-r") #'embr-isearch-backward)

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
                         " "
                         (if (string-empty-p embr--current-title)
                             (propertize url 'face 'shadow)
                           (concat
                            (propertize url 'face 'shadow)
                            (propertize " — " 'face 'shadow)
                            (propertize embr--current-title 'face 'bold)))))))
  (add-hook 'pre-command-hook #'embr--maybe-end-search nil t))

;; ── Entry point ────────────────────────────────────────────────────

;;;###autoload
(defun embr-browse (url &optional _new-window)
  "Launch embr and navigate to URL.
If the daemon is already running, just navigate to the new URL."
  (interactive "sURL: ")
  ;; Check if setup has been run.
  (when (embr--setup-needed-p)
    (if (y-or-n-p "embr: Setup needed (venv or CloakBrowser missing). Run now? ")
        (progn
          (embr-setup-or-update-all)
          (error "embr: Setup started in *embr-setup* buffer. Run M-x embr-browse again when it finishes"))
      (error "embr: Run M-x embr-setup-or-update-all first")))
  ;; Create buffer if needed.
  (unless (buffer-live-p embr--buffer)
    (setq embr--buffer (generate-new-buffer "*embr*"))
    (with-current-buffer embr--buffer
      (embr-mode)))
  ;; Start daemon if needed.
  (unless (and embr--process (process-live-p embr--process))
    (setq embr--viewport-width (or embr--viewport-width embr-default-width)
          embr--viewport-height (or embr--viewport-height embr-default-height))
    (embr--start-daemon)
    (let ((resp (embr--send-sync
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
                         (adaptive_jpeg_quality_min . ,embr-adaptive-jpeg-quality-min)))))))

      (if (alist-get 'error resp)
          (progn
            (when (and embr--process (process-live-p embr--process))
              (delete-process embr--process))
            (setq embr--process nil)
            (error "embr: init failed: %s" (alist-get 'error resp)))
        ;; Daemon tells us where it writes frames.
        (setq embr--frame-path (alist-get 'frame_path resp))
        (embr--hover-start)
        (embr--backend-init
         (or (alist-get 'render_backend resp) "default")
         (alist-get 'frame_socket_path resp))
        (message "embr: %s transport, %s backend"
                 (or (alist-get 'frame_source resp) "unknown")
                 (embr--backend-name)))))
  ;; Show buffer and navigate.
  (switch-to-buffer embr--buffer)
  (embr-navigate url))

(provide 'embr)

;;; embr.el ends here
