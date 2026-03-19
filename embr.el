;;; embr.el --- Browse the web with headless Firefox in Emacs -*- lexical-binding: t; -*-

;; Author: embr contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: web, browser
;; URL: https://github.com/emacs-os/embr.el

;;; Commentary:

;; embr runs a headless Firefox (via Playwright) and displays
;; screenshots in an Emacs buffer.  Clicks, keystrokes, and scroll
;; events are forwarded to the browser.  The daemon streams frames
;; at ~30 FPS via JPEG files on disk.

;;; Code:

(require 'json)
(require 'image)

;; ── Customization ──────────────────────────────────────────────────

(defgroup embr nil
  "Headless Firefox browser for Emacs."
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

(defcustom embr-fps 30
  "Target frames per second for the screenshot stream."
  :type 'integer)

(defcustom embr-external-player "mpv"
  "External media player for `embr-play-external'.
The current URL is piped through yt-dlp and into this player."
  :type 'string)

(defcustom embr-search-engine 'brave
  "Search engine for URL bar queries.
Can be a symbol (`brave', `google', `duckduckgo') or a custom URL
string with %s for the query."
  :type '(choice (const :tag "Brave" brave)
                 (const :tag "Google" google)
                 (const :tag "DuckDuckGo" duckduckgo)
                 (string :tag "Custom URL (use %s for query)")))

(defun embr--search-url (query)
  "Build a search URL for QUERY using `embr-search-engine'."
  (let ((template (pcase embr-search-engine
                    ('brave "https://search.brave.com/search?q=%s")
                    ('google "https://www.google.com/search?q=%s")
                    ('duckduckgo "https://duckduckgo.com/?q=%s")
                    ((pred stringp) embr-search-engine))))
    (format template (url-hexify-string query))))

;; ── Setup & management ─────────────────────────────────────────────

(defun embr--setup-needed-p ()
  "Return non-nil if setup.sh needs to be run."
  (not (file-exists-p embr-python)))

;;;###autoload
(defun embr-setup-or-update ()
  "Run setup.sh to install or update the Python venv, Playwright, Firefox, and ad blocklist.
Safe to run at any time — rebuilds in a temp venv and swaps atomically."
  (interactive)
  (let ((setup-script (expand-file-name "setup.sh" embr--directory)))
    (unless (file-exists-p setup-script)
      (error "embr: setup.sh not found in %s" embr--directory))
    (let ((buf (get-buffer-create "*embr-setup*")))
      (with-current-buffer buf (erase-buffer))
      (pop-to-buffer buf)
      (insert (format "Running setup.sh in %s ...\n\n" embr--directory))
      (let ((proc (start-process "embr-setup" buf
                                  "bash" setup-script)))
        (set-process-sentinel
         proc
         (lambda (_proc event)
           (when (string-match-p "finished" event)
             (with-current-buffer (get-buffer "*embr-setup*")
               (goto-char (point-max))
               (insert "\nDone. You can now run M-x embr-browse.\n")))))))))


;;;###autoload
(defun embr-uninstall ()
  "Remove the Python venv, Playwright browsers, and browser profile.
This does NOT remove the Emacs package itself — use your package manager for that."
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
        (let* ((also-browsers (y-or-n-p "Also delete Playwright's shared browser cache (~/.cache/ms-playwright)? "))
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
        (browsers-dir (expand-file-name "ms-playwright" (or (getenv "XDG_CACHE_HOME")
                                                            (expand-file-name ".cache" "~"))))
        (profile-dir (expand-file-name "embr" (or (getenv "XDG_DATA_HOME")
                                                         (expand-file-name ".local/share" "~")))))
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

;; ── Process management ─────────────────────────────────────────────

(defun embr--start-daemon ()
  "Start the Python daemon process."
  (when (and embr--process (process-live-p embr--process))
    (delete-process embr--process))
  (setq embr--response-buffer "")
  (let ((process-environment (cons "PLAYWRIGHT_BROWSERS_PATH=" process-environment)))
    (setq embr--process
          (make-process
           :name "embr"
           :command (list embr-python embr-script)
           :connection-type 'pipe
           :noquery t
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
              (let ((json-object-type 'alist)
                    (json-array-type 'list)
                    (json-key-type 'symbol))
                (let ((resp (json-read-from-string line)))
                  (if (alist-get 'frame resp)
                      ;; Frame notification — just remember the latest one.
                      (setq last-frame resp)
                    ;; Command response — dispatch to callback.
                    (when embr--callback
                      (let ((cb embr--callback))
                        (setq embr--callback nil)
                        (funcall cb resp))))))
            (error (message "embr: JSON parse error: %s"
                            (error-message-string err)))))))
    ;; Render only the most recent frame.
    (when last-frame
      (embr--handle-frame last-frame))))

(defun embr--process-sentinel (_proc event)
  "Handle process EVENT (e.g. exit)."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (message "embr: daemon exited: %s" (string-trim event))
    (setq embr--process nil)))

(defun embr--send (msg &optional callback)
  "Send MSG (an alist) to the daemon as JSON.  Call CALLBACK with the response."
  (unless (and embr--process (process-live-p embr--process))
    (error "embr: daemon not running"))
  (setq embr--callback callback)
  (let ((json-str (json-encode msg)))
    (process-send-string embr--process (concat json-str "\n"))))

(defun embr--send-sync (msg)
  "Send MSG and wait synchronously for the response.  Returns the parsed alist."
  (let ((result nil)
        (done nil))
    (embr--send msg (lambda (resp)
                            (setq result resp done t)))
    (while (not done)
      (accept-process-output embr--process 30))
    result))

;; ── Display ────────────────────────────────────────────────────────

(defun embr--handle-frame (resp)
  "Read the JPEG frame from disk and display it.  Update title/url from RESP."
  (let ((title (or (alist-get 'title resp) ""))
        (url (or (alist-get 'url resp) "")))
    (setq embr--current-title title
          embr--current-url url)
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
            ;; `insert-image' adds `image-map' as a text-property keymap,
            ;; which steals keys like "i" (prefix for image commands in
            ;; Emacs 30+).  Remove it so our major-mode map handles all keys.
            (remove-text-properties (point-min) (point-max) '(keymap nil))
            (put-text-property (point-min) (point-max) 'pointer 'arrow)
            (goto-char (point-min)))
          (rename-buffer (format "*embr: %s*"
                                 (if (string-empty-p title) url title))
                         t))))))

(defun embr--action-callback (resp)
  "Generic callback for command responses: report errors."
  (when-let* ((err (alist-get 'error resp)))
    (message "embr error: %s" err)))

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
  "Navigate to URL, or search if input doesn't look like a URL."
  (interactive (list (completing-read "URL/Search: " embr--url-history nil nil nil
                                      'embr--url-history)))
  (let ((target (embr--maybe-search-url url)))
    (push url embr--url-history)
    (delete-dups embr--url-history)
    (embr--send `((cmd . "navigate") (url . ,target))
                       #'embr--action-callback)))

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

(defun embr-quit ()
  "Kill the daemon and close the buffer."
  (interactive)
  (when (and embr--process (process-live-p embr--process))
    (embr--send '((cmd . "quit")))
    (sit-for 0.5)
    (when (process-live-p embr--process)
      (delete-process embr--process)))
  (setq embr--process nil
        embr--frame-path nil)
  (when (buffer-live-p embr--buffer)
    (kill-buffer embr--buffer)))

(defun embr-mouse-handler (event)
  "Handle mouse press, track drag, and forward to browser."
  (interactive "e")
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
        ;; Get final position from release event if available.
        (when (and ev (listp ev))
          (let* ((posn (event-end ev))
                 (xy (posn-object-x-y posn)))
            (when xy
              (setq end-x (car xy) end-y (cdr xy)))))
        (embr--send `((cmd . "mouseup") (x . ,end-x) (y . ,end-y))
                           #'embr--action-callback)))))

(defun embr-double-click (event)
  "Handle double-click EVENT — select word in browser."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (car xy))
         (y (cdr xy)))
    (when (and x y)
      (embr--send `((cmd . "dblclick") (x . ,x) (y . ,y))
                         #'embr--action-callback))))

(defun embr-scroll-down (event)
  "Scroll down in the browser on mouse wheel EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (or (car xy) 0))
         (y (or (cdr xy) 0)))
    (embr--send `((cmd . "scroll") (x . ,x) (y . ,y)
                         (delta_x . 0) (delta_y . 300))
                       #'embr--action-callback)))

(defun embr-scroll-up (event)
  "Scroll up in the browser on mouse wheel EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (or (car xy) 0))
         (y (or (cdr xy) 0)))
    (embr--send `((cmd . "scroll") (x . ,x) (y . ,y)
                         (delta_x . 0) (delta_y . -300))
                       #'embr--action-callback)))

(defun embr-zoom-in ()
  "Increase viewport size (zoom in — larger viewport = more content)."
  (interactive)
  (setq embr--viewport-width (+ embr--viewport-width 160)
        embr--viewport-height (+ embr--viewport-height 90))
  (embr--send `((cmd . "resize")
                       (width . ,embr--viewport-width)
                       (height . ,embr--viewport-height))
                     #'embr--action-callback))

(defun embr-zoom-out ()
  "Decrease viewport size (zoom out — smaller viewport = larger content)."
  (interactive)
  (setq embr--viewport-width (max 320 (- embr--viewport-width 160))
        embr--viewport-height (max 180 (- embr--viewport-height 90)))
  (embr--send `((cmd . "resize")
                       (width . ,embr--viewport-width)
                       (height . ,embr--viewport-height))
                     #'embr--action-callback))

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

(defun embr-copy-url ()
  "Copy the current page URL to the kill ring."
  (interactive)
  (kill-new embr--current-url)
  (message "Copied: %s" embr--current-url))

;; ── Resolution toggle ─────────────────────────────────────────────

(defvar embr--resolutions
  '((393 . 852) (1280 . 720) (1920 . 1080))
  "List of (width . height) pairs to cycle through.")

(defun embr-cycle-resolution ()
  "Cycle viewport through 720p → 1080p → 1440p → 4K."
  (interactive)
  (let* ((current (cons embr--viewport-width embr--viewport-height))
         (pos (cl-position current embr--resolutions :test #'equal))
         (next (nth (mod (1+ (or pos -1)) (length embr--resolutions))
                    embr--resolutions)))
    (setq embr--viewport-width (car next)
          embr--viewport-height (cdr next))
    (embr--send `((cmd . "resize")
                         (width . ,(car next))
                         (height . ,(cdr next)))
                       #'embr--action-callback)
    (message "Viewport: %dx%d" (car next) (cdr next))))

;; ── External player ───────────────────────────────────────────────

(defun embr-play-external ()
  "Play the current URL with yt-dlp piped to `embr-external-player'."
  (interactive)
  (let ((url embr--current-url))
    (if (string-empty-p url)
        (message "embr: no URL to play")
      (message "Playing in %s: %s" embr-external-player url)
      (start-process-shell-command
       "embr-player" nil
       (format "yt-dlp -o - %s | %s -"
               (shell-quote-argument url)
               embr-external-player)))))

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
         (if (eq (alist-get 'result resp) :json-false)
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
  "Open URL in a new tab."
  (interactive "sURL for new tab: ")
  (embr--send `((cmd . "new-tab") (url . ,url))
                     #'embr--action-callback))

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
  `(,(format "embr: %s" embr--current-title)
    (url . ,embr--current-url)
    (handler . embr--bookmark-handler)))

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
                            (json-encode text))))
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
    (define-key map (kbd "<f8>") #'embr-cycle-resolution)
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
    (define-key map [double-mouse-1] #'embr-double-click)
    (define-key map [wheel-down] #'embr-scroll-down)
    (define-key map [wheel-up] #'embr-scroll-up)

    ;; Browser commands under C-c prefix (Emacs convention for major modes).
    (define-key map (kbd "C-c l") #'embr-navigate)
    (define-key map (kbd "C-c r") #'embr-refresh)
    (define-key map (kbd "C-c b") #'embr-back)
    (define-key map (kbd "C-c f") #'embr-forward)
    (define-key map (kbd "C-c q") #'embr-quit)
    (define-key map (kbd "C-c C-k") #'embr-quit)
    (define-key map (kbd "C-c C-f") #'embr-forward)
    (define-key map (kbd "C-c C-b") #'embr-back)
    (define-key map (kbd "C-c +") #'embr-zoom-in)
    (define-key map (kbd "C-c -") #'embr-zoom-out)
    (define-key map (kbd "C-c h") #'embr-follow-hint)
    (define-key map (kbd "C-c t") #'embr-view-text)
    (define-key map (kbd "C-c w") #'embr-copy-url)
    (define-key map (kbd "C-c s") #'embr-isearch-forward)
    (define-key map (kbd "C-c n") #'embr-new-tab)
    (define-key map (kbd "C-c d") #'embr-close-tab)
    (define-key map (kbd "C-c ]") #'embr-next-tab)
    (define-key map (kbd "C-c [") #'embr-prev-tab)
    (define-key map (kbd "C-c a") #'embr-list-tabs)
    (define-key map (kbd "C-c :") #'embr-execute-js)
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
  (add-hook 'pre-command-hook #'embr--maybe-end-search nil t))

;; ── Entry point ────────────────────────────────────────────────────

;;;###autoload
(defun embr-browse (url)
  "Launch embr and navigate to URL.
If the daemon is already running, just navigate to the new URL."
  (interactive "sURL: ")
  ;; Check if setup has been run.
  (when (embr--setup-needed-p)
    (if (y-or-n-p "embr: Python venv not found. Run setup now? ")
        (progn
          (embr-setup-or-update)
          (error "embr: Setup started in *embr-setup* buffer. Run M-x embr-browse again when it finishes"))
      (error "embr: Run M-x embr-setup-or-update first")))
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
                   (fps . ,embr-fps)))))
      (if (alist-get 'error resp)
          (error "embr: init failed: %s" (alist-get 'error resp))
        ;; Daemon tells us where it writes frames.
        (setq embr--frame-path (alist-get 'frame_path resp)))))
  ;; Show buffer and navigate.
  (switch-to-buffer embr--buffer)
  (embr-navigate url))

(provide 'embr)

;;; embr.el ends here
