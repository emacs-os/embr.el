;;; better-eww.el --- Browse the web with headless Firefox in Emacs -*- lexical-binding: t; -*-

;; Author: better-eww contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: web, browser
;; URL: https://github.com/user/better-eww

;;; Commentary:

;; better-eww runs a headless Firefox (via Playwright) and displays
;; screenshots in an Emacs buffer.  Clicks, keystrokes, and scroll
;; events are forwarded to the browser.  The daemon streams frames
;; at ~30 FPS via JPEG files on disk.

;;; Code:

(require 'json)
(require 'image)

;; ── Customization ──────────────────────────────────────────────────

(defgroup better-eww nil
  "Headless Firefox browser for Emacs."
  :group 'web
  :prefix "better-eww-")

(defvar better-eww--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory where better-eww package files live.
With :files in the package recipe, Elpaca/straight symlink .py and .sh
alongside the .el in the builds dir, so this just works.")

(defcustom better-eww-python
  (expand-file-name ".venv/bin/python" better-eww--directory)
  "Path to the Python interpreter inside the project venv."
  :type 'file)

(defcustom better-eww-script
  (expand-file-name "better-eww.py" better-eww--directory)
  "Path to the better-eww Python daemon script."
  :type 'file)

(defcustom better-eww-default-width 1280
  "Default viewport width in pixels."
  :type 'integer)

(defcustom better-eww-default-height 720
  "Default viewport height in pixels."
  :type 'integer)

(defcustom better-eww-fps 30
  "Target frames per second for the screenshot stream."
  :type 'integer)

(defcustom better-eww-search-engine 'brave
  "Search engine for URL bar queries.
Can be a symbol (`brave', `google', `duckduckgo') or a custom URL
string with %s for the query."
  :type '(choice (const :tag "Brave" brave)
                 (const :tag "Google" google)
                 (const :tag "DuckDuckGo" duckduckgo)
                 (string :tag "Custom URL (use %s for query)")))

(defun better-eww--search-url (query)
  "Build a search URL for QUERY using `better-eww-search-engine'."
  (let ((template (pcase better-eww-search-engine
                    ('brave "https://search.brave.com/search?q=%s")
                    ('google "https://www.google.com/search?q=%s")
                    ('duckduckgo "https://duckduckgo.com/?q=%s")
                    ((pred stringp) better-eww-search-engine))))
    (format template (url-hexify-string query))))

;; ── Setup & management ─────────────────────────────────────────────

(defun better-eww--setup-needed-p ()
  "Return non-nil if setup.sh needs to be run."
  (not (file-exists-p better-eww-python)))

;;;###autoload
(defun better-eww-setup-or-update ()
  "Run setup.sh to install or update the Python venv, Playwright, and Firefox.
Safe to run at any time — rebuilds in a temp venv and swaps atomically."
  (interactive)
  (let ((setup-script (expand-file-name "setup.sh" better-eww--directory)))
    (unless (file-exists-p setup-script)
      (error "better-eww: setup.sh not found in %s" better-eww--directory))
    (let ((buf (get-buffer-create "*better-eww-setup*")))
      (with-current-buffer buf (erase-buffer))
      (pop-to-buffer buf)
      (insert (format "Running setup.sh in %s ...\n\n" better-eww--directory))
      (let ((proc (start-process "better-eww-setup" buf
                                  "bash" setup-script)))
        (set-process-sentinel
         proc
         (lambda (_proc event)
           (when (string-match-p "finished" event)
             (with-current-buffer (get-buffer "*better-eww-setup*")
               (goto-char (point-max))
               (insert "\nDone. You can now run M-x better-eww-browse.\n")))))))))


;;;###autoload
(defun better-eww-uninstall ()
  "Remove the Python venv, Playwright browsers, and browser profile.
This does NOT remove the Emacs package itself — use your package manager for that."
  (interactive)
  (let ((script (expand-file-name "uninstall.sh" better-eww--directory)))
    (unless (file-exists-p script)
      (error "better-eww: uninstall.sh not found in %s" better-eww--directory))
    (let ((buf (get-buffer-create "*better-eww-setup*")))
      (with-current-buffer buf (erase-buffer))
      (pop-to-buffer buf)
      (insert (format "Running uninstall.sh in %s ...\n\n" better-eww--directory))
      ;; Run with yes piped to stdin to auto-confirm (user already confirmed via M-x).
      (when (y-or-n-p "Remove Python venv and browser profile? ")
        (let* ((also-browsers (y-or-n-p "Also delete Playwright's shared browser cache (~/.cache/ms-playwright)? "))
               (input (concat "y\n" (if also-browsers "y\n" "n\n")))
               (proc (start-process "better-eww-uninstall" buf "bash" "-c"
                                     (format "echo %s | bash %s"
                                             (shell-quote-argument input)
                                             (shell-quote-argument script)))))
          (set-process-sentinel
           proc
           (lambda (_proc event)
             (when (string-match-p "finished" event)
               (with-current-buffer (get-buffer "*better-eww-setup*")
                 (goto-char (point-max))
                 (insert "\nDone.\n"))))))))))

;;;###autoload
(defun better-eww-info ()
  "Show diagnostic info about the better-eww installation."
  (interactive)
  (let ((venv-dir (expand-file-name ".venv" better-eww--directory))
        (browsers-dir (expand-file-name "ms-playwright" (or (getenv "XDG_CACHE_HOME")
                                                            (expand-file-name ".cache" "~"))))
        (profile-dir (expand-file-name "better-eww" (or (getenv "XDG_DATA_HOME")
                                                         (expand-file-name ".local/share" "~")))))
    (message "better-eww installation:
  Source:     %s
  Python:     %s (%s)
  Script:     %s (%s)
  Venv:       %s (%s)
  Browsers:   %s (%s)
  Profile:    %s (%s)
  Setup needed: %s"
             better-eww--directory
             better-eww-python (if (file-exists-p better-eww-python) "OK" "MISSING")
             better-eww-script (if (file-exists-p better-eww-script) "OK" "MISSING")
             venv-dir (if (file-directory-p venv-dir) "OK" "MISSING")
             browsers-dir (if (file-directory-p browsers-dir) "OK" "MISSING")
             profile-dir (if (file-directory-p profile-dir) "exists" "not yet created")
             (better-eww--setup-needed-p))))

;; ── Internal state ─────────────────────────────────────────────────

(defvar better-eww--process nil "The daemon subprocess.")
(defvar better-eww--buffer nil "The display buffer.")
(defvar better-eww--response-buffer "" "Accumulator for partial JSON lines from the process.")
(defvar better-eww--callback nil "Function to call with the next command response.")
(defvar better-eww--current-url "" "The URL currently displayed.")
(defvar better-eww--current-title "" "The title of the current page.")
(defvar better-eww--viewport-width better-eww-default-width "Current viewport width.")
(defvar better-eww--viewport-height better-eww-default-height "Current viewport height.")
(defvar better-eww--frame-path nil "Path to the JPEG frame file written by the daemon.")
(defvar better-eww--url-history nil "History of visited URLs for completion.")
(defvar better-eww--hints nil "Current hint labels alist from the daemon.")

;; ── Process management ─────────────────────────────────────────────

(defun better-eww--start-daemon ()
  "Start the Python daemon process."
  (when (and better-eww--process (process-live-p better-eww--process))
    (delete-process better-eww--process))
  (setq better-eww--response-buffer "")
  (let ((process-environment (cons "PLAYWRIGHT_BROWSERS_PATH=" process-environment)))
    (setq better-eww--process
          (make-process
           :name "better-eww"
           :command (list better-eww-python better-eww-script)
           :connection-type 'pipe
           :noquery t
           :filter #'better-eww--process-filter
           :sentinel #'better-eww--process-sentinel))))

(defun better-eww--process-filter (_proc output)
  "Handle OUTPUT from the daemon process."
  (setq better-eww--response-buffer
        (concat better-eww--response-buffer output))
  ;; Process all complete lines.  For frame notifications, only render
  ;; the latest one (skip intermediate frames if Emacs can't keep up).
  (let (last-frame)
    (while (string-match "\n" better-eww--response-buffer)
      (let* ((pos (match-end 0))
             (line (substring better-eww--response-buffer 0 (1- pos))))
        (setq better-eww--response-buffer (substring better-eww--response-buffer pos))
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
                    (when better-eww--callback
                      (let ((cb better-eww--callback))
                        (setq better-eww--callback nil)
                        (funcall cb resp))))))
            (error (message "better-eww: JSON parse error: %s"
                            (error-message-string err)))))))
    ;; Render only the most recent frame.
    (when last-frame
      (better-eww--handle-frame last-frame))))

(defun better-eww--process-sentinel (_proc event)
  "Handle process EVENT (e.g. exit)."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (message "better-eww: daemon exited: %s" (string-trim event))
    (setq better-eww--process nil)))

(defun better-eww--send (msg &optional callback)
  "Send MSG (an alist) to the daemon as JSON.  Call CALLBACK with the response."
  (unless (and better-eww--process (process-live-p better-eww--process))
    (error "better-eww: daemon not running"))
  (setq better-eww--callback callback)
  (let ((json-str (json-encode msg)))
    (process-send-string better-eww--process (concat json-str "\n"))))

(defun better-eww--send-sync (msg)
  "Send MSG and wait synchronously for the response.  Returns the parsed alist."
  (let ((result nil)
        (done nil))
    (better-eww--send msg (lambda (resp)
                            (setq result resp done t)))
    (while (not done)
      (accept-process-output better-eww--process 30))
    result))

;; ── Display ────────────────────────────────────────────────────────

(defun better-eww--handle-frame (resp)
  "Read the JPEG frame from disk and display it.  Update title/url from RESP."
  (let ((title (or (alist-get 'title resp) ""))
        (url (or (alist-get 'url resp) "")))
    (setq better-eww--current-title title
          better-eww--current-url url)
    (when (and better-eww--frame-path
               (file-exists-p better-eww--frame-path)
               (buffer-live-p better-eww--buffer))
      (let ((data (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally better-eww--frame-path)
                    (buffer-string))))
        (with-current-buffer better-eww--buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert-image (create-image data 'jpeg t))
            ;; `insert-image' adds `image-map' as a text-property keymap,
            ;; which steals keys like "i" (prefix for image commands in
            ;; Emacs 30+).  Remove it so our major-mode map handles all keys.
            (remove-text-properties (point-min) (point-max) '(keymap nil))
            (goto-char (point-min)))
          (rename-buffer (format "*better-eww: %s*"
                                 (if (string-empty-p title) url title))
                         t))))))

(defun better-eww--action-callback (resp)
  "Generic callback for command responses: report errors."
  (when-let* ((err (alist-get 'error resp)))
    (message "better-eww error: %s" err)))

;; ── Commands ───────────────────────────────────────────────────────

(defun better-eww-execute-js (expr)
  "Execute JavaScript EXPR in the browser and display the result."
  (interactive "sJS: ")
  (better-eww--send `((cmd . "js") (expr . ,expr))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "better-eww JS error: %s" err)
                         (message "=> %s" (alist-get 'result resp))))))

(defun better-eww--maybe-search-url (input)
  "If INPUT looks like a URL, return it as-is; otherwise build a search URL."
  (if (or (string-match-p "\\`https?://" input)
          (string-match-p "\\`file://" input)
          (and (string-match-p "\\." input)
               (not (string-match-p " " input))))
      input
    (better-eww--search-url input)))

(defun better-eww-navigate (url)
  "Navigate to URL, or search if input doesn't look like a URL."
  (interactive (list (completing-read "URL/Search: " better-eww--url-history nil nil nil
                                      'better-eww--url-history)))
  (let ((target (better-eww--maybe-search-url url)))
    (push url better-eww--url-history)
    (delete-dups better-eww--url-history)
    (better-eww--send `((cmd . "navigate") (url . ,target))
                       #'better-eww--action-callback)))

(defun better-eww-refresh ()
  "Refresh the current page."
  (interactive)
  (better-eww--send '((cmd . "refresh"))
                     #'better-eww--action-callback))

(defun better-eww-back ()
  "Go back in browser history."
  (interactive)
  (better-eww--send '((cmd . "back"))
                     #'better-eww--action-callback))

(defun better-eww-forward ()
  "Go forward in browser history."
  (interactive)
  (better-eww--send '((cmd . "forward"))
                     #'better-eww--action-callback))

(defun better-eww-quit ()
  "Kill the daemon and close the buffer."
  (interactive)
  (when (and better-eww--process (process-live-p better-eww--process))
    (better-eww--send '((cmd . "quit")))
    (sit-for 0.5)
    (when (process-live-p better-eww--process)
      (delete-process better-eww--process)))
  (setq better-eww--process nil
        better-eww--frame-path nil)
  (when (buffer-live-p better-eww--buffer)
    (kill-buffer better-eww--buffer)))

(defun better-eww-click (event)
  "Handle a mouse click EVENT — forward coordinates to the browser."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (car xy))
         (y (cdr xy)))
    (when (and x y)
      (better-eww--send `((cmd . "click") (x . ,x) (y . ,y))
                         #'better-eww--action-callback))))

(defun better-eww-scroll-down (event)
  "Scroll down in the browser on mouse wheel EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (or (car xy) 0))
         (y (or (cdr xy) 0)))
    (better-eww--send `((cmd . "scroll") (x . ,x) (y . ,y)
                         (delta_x . 0) (delta_y . 300))
                       #'better-eww--action-callback)))

(defun better-eww-scroll-up (event)
  "Scroll up in the browser on mouse wheel EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn))
         (x (or (car xy) 0))
         (y (or (cdr xy) 0)))
    (better-eww--send `((cmd . "scroll") (x . ,x) (y . ,y)
                         (delta_x . 0) (delta_y . -300))
                       #'better-eww--action-callback)))

(defun better-eww-zoom-in ()
  "Increase viewport size (zoom in — larger viewport = more content)."
  (interactive)
  (setq better-eww--viewport-width (+ better-eww--viewport-width 160)
        better-eww--viewport-height (+ better-eww--viewport-height 90))
  (better-eww--send `((cmd . "resize")
                       (width . ,better-eww--viewport-width)
                       (height . ,better-eww--viewport-height))
                     #'better-eww--action-callback))

(defun better-eww-zoom-out ()
  "Decrease viewport size (zoom out — smaller viewport = larger content)."
  (interactive)
  (setq better-eww--viewport-width (max 320 (- better-eww--viewport-width 160))
        better-eww--viewport-height (max 180 (- better-eww--viewport-height 90)))
  (better-eww--send `((cmd . "resize")
                       (width . ,better-eww--viewport-width)
                       (height . ,better-eww--viewport-height))
                     #'better-eww--action-callback))

;; ── Link hints ─────────────────────────────────────────────────────

(defun better-eww-follow-hint ()
  "Show link hints on all clickable elements, then follow the chosen one."
  (interactive)
  (better-eww--send '((cmd . "hints"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "better-eww error: %s" err)
                         (let* ((hints (alist-get 'hints resp))
                                (tags (mapcar (lambda (h) (alist-get 'tag h)) hints)))
                           (if (null tags)
                               (message "better-eww: no clickable elements found")
                             (setq better-eww--hints hints)
                             ;; Frame stream will show the hint overlays.
                             ;; Read user input after a brief pause for the frame to arrive.
                             (run-at-time 0.1 nil #'better-eww--read-hint)))))))

(defun better-eww--read-hint ()
  "Read a hint tag from the user and click it."
  (let* ((descriptions (mapcar (lambda (h)
                                 (format "%s: %s" (alist-get 'tag h)
                                         (alist-get 'text h)))
                               better-eww--hints))
         (chosen (condition-case nil
                     (completing-read "Hint: " descriptions nil t)
                   (quit nil))))
    ;; Always clear hints, whether user picked one or cancelled.
    (better-eww--send '((cmd . "hints-clear")) nil)
    (when (and chosen (string-match "\\`\\([^:]+\\):" chosen))
      (let* ((tag (match-string 1 chosen))
             (hint (seq-find (lambda (h) (string= (alist-get 'tag h) tag))
                             better-eww--hints)))
        (when hint
          (better-eww--send `((cmd . "click")
                               (x . ,(alist-get 'x hint))
                               (y . ,(alist-get 'y hint)))
                             #'better-eww--action-callback))))))

;; ── Text extraction ────────────────────────────────────────────────

(defun better-eww-view-text ()
  "Extract page text and display in a separate buffer."
  (interactive)
  (better-eww--send '((cmd . "text"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "better-eww error: %s" err)
                         (let ((text (alist-get 'text resp))
                               (buf (get-buffer-create "*better-eww-text*")))
                           (with-current-buffer buf
                             (let ((inhibit-read-only t))
                               (erase-buffer)
                               (insert text))
                             (goto-char (point-min))
                             (view-mode 1))
                           (display-buffer buf))))))

(defun better-eww-copy-url ()
  "Copy the current page URL to the kill ring."
  (interactive)
  (kill-new better-eww--current-url)
  (message "Copied: %s" better-eww--current-url))

;; ── Find in page ───────────────────────────────────────────────────

(defvar better-eww--search-query "" "Current find-in-page query.")
(defvar better-eww--searching nil "Non-nil when in a search sequence.")

(defun better-eww--maybe-end-search ()
  "Clear search state if the next command is not a search command."
  (unless (memq this-command '(better-eww-isearch-forward better-eww-isearch-backward))
    (setq better-eww--searching nil)))

(defun better-eww--find-on-page (backwards)
  "Run window.find() with the current search query.  Search BACKWARDS if non-nil."
  (setq better-eww--searching t)
  (let ((escaped (replace-regexp-in-string "'" "\\\\'" better-eww--search-query)))
    (better-eww--send
     `((cmd . "js")
       (expr . ,(format "window.find('%s', false, %s, true)"
                        escaped (if backwards "true" "false"))))
     (lambda (resp)
       (if-let* ((err (alist-get 'error resp)))
           (message "better-eww find error: %s" err)
         (if (eq (alist-get 'result resp) :json-false)
             (message "better-eww: no more matches")
           (message "Search: %s" better-eww--search-query)))))))

(defun better-eww-isearch-forward ()
  "Search forward.  First call prompts for query; repeating finds next match."
  (interactive)
  (if (and better-eww--searching
           (not (string-empty-p better-eww--search-query)))
      (better-eww--find-on-page nil)
    (setq better-eww--searching nil)
    (let ((query (read-string "Search: " better-eww--search-query)))
      (unless (string-empty-p query)
        (setq better-eww--search-query query)
        (better-eww--find-on-page nil)))))

(defun better-eww-isearch-backward ()
  "Search backward.  First call prompts for query; repeating finds previous match."
  (interactive)
  (if (and better-eww--searching
           (not (string-empty-p better-eww--search-query)))
      (better-eww--find-on-page t)
    (setq better-eww--searching nil)
    (let ((query (read-string "Search backward: " better-eww--search-query)))
      (unless (string-empty-p query)
        (setq better-eww--search-query query)
        (better-eww--find-on-page t)))))

;; ── Tabs ───────────────────────────────────────────────────────────

(defun better-eww-new-tab (url)
  "Open URL in a new tab."
  (interactive "sURL for new tab: ")
  (better-eww--send `((cmd . "new-tab") (url . ,url))
                     #'better-eww--action-callback))

(defun better-eww-close-tab ()
  "Close the current tab."
  (interactive)
  (better-eww--send '((cmd . "close-tab"))
                     #'better-eww--action-callback))

(defun better-eww-next-tab ()
  "Switch to the next tab."
  (interactive)
  (better-eww--send '((cmd . "list-tabs"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "better-eww error: %s" err)
                         (let* ((tabs (alist-get 'tabs resp))
                                (cur (seq-position tabs t
                                       (lambda (tab _) (eq (alist-get 'active tab) t))))
                                (next (if cur (mod (1+ cur) (length tabs)) 0)))
                           (better-eww--send `((cmd . "switch-tab") (index . ,next))
                                              #'better-eww--action-callback))))))

(defun better-eww-prev-tab ()
  "Switch to the previous tab."
  (interactive)
  (better-eww--send '((cmd . "list-tabs"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "better-eww error: %s" err)
                         (let* ((tabs (alist-get 'tabs resp))
                                (cur (seq-position tabs t
                                       (lambda (tab _) (eq (alist-get 'active tab) t))))
                                (prev (if cur (mod (1- cur) (length tabs))
                                        (1- (length tabs)))))
                           (better-eww--send `((cmd . "switch-tab") (index . ,prev))
                                              #'better-eww--action-callback))))))

(defun better-eww-list-tabs ()
  "List all tabs and switch to the selected one."
  (interactive)
  (better-eww--send '((cmd . "list-tabs"))
                     (lambda (resp)
                       (if-let* ((err (alist-get 'error resp)))
                           (message "better-eww error: %s" err)
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
                               (better-eww--send `((cmd . "switch-tab") (index . ,idx))
                                                  #'better-eww--action-callback))))))))

;; ── Form fill ──────────────────────────────────────────────────────

(defun better-eww-fill (selector value)
  "Fill a form field matching CSS SELECTOR with VALUE."
  (interactive "sCSS selector: \nsValue: ")
  (better-eww--send `((cmd . "fill") (selector . ,selector) (value . ,value))
                     #'better-eww--action-callback))

;; ── Bookmarks ──────────────────────────────────────────────────────

(defun better-eww--bookmark-make-record ()
  "Create a bookmark record for the current better-eww page."
  `(,(format "better-eww: %s" better-eww--current-title)
    (url . ,better-eww--current-url)
    (handler . better-eww--bookmark-handler)))

(defun better-eww--bookmark-handler (bookmark)
  "Jump to a better-eww BOOKMARK."
  (better-eww-browse (alist-get 'url (cdr bookmark))))

;; ── Key forwarding ─────────────────────────────────────────────────

(defun better-eww--translate-key (key)
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
    (_ key)))

(defun better-eww-self-insert ()
  "Forward the current key to the browser."
  (interactive)
  (let* ((keys (this-command-keys-vector))
         (key-desc (key-description keys))
         (pw-key (better-eww--translate-key key-desc)))
    (if (= (length pw-key) 1)
        (better-eww--send `((cmd . "type") (text . ,pw-key))
                           #'better-eww--action-callback)
      (better-eww--send `((cmd . "key") (key . ,pw-key))
                         #'better-eww--action-callback))))

;; ── Keymap ─────────────────────────────────────────────────────────

(defvar better-eww-mode-map nil "Keymap for `better-eww-mode'.")
(setq better-eww-mode-map
  (let ((map (make-sparse-keymap)))
    ;; All printable characters → forward to browser.
    (dolist (c (number-sequence 32 126))
      (define-key map (vector c) #'better-eww-self-insert))
    ;; Special keys → forward to browser.
    (dolist (key '("<return>" "<backspace>" "<tab>" "<delete>"
                   "<home>" "<end>" "<up>" "<down>" "<left>" "<right>"
                   "<prior>" "<next>" "<escape>"))
      (define-key map (kbd key) #'better-eww-self-insert))

    ;; Emacs-style convenience bindings.
    (define-key map (kbd "C-v") #'better-eww-self-insert)
    (define-key map (kbd "M-v") #'better-eww-self-insert)
    (define-key map (kbd "C-l") #'better-eww-navigate)
    (define-key map (kbd "C-n") #'better-eww-self-insert)
    (define-key map (kbd "C-p") #'better-eww-self-insert)
    (define-key map (kbd "C-b") #'better-eww-self-insert)
    (define-key map (kbd "C-f") #'better-eww-self-insert)
    (define-key map (kbd "C-a") #'better-eww-self-insert)
    (define-key map (kbd "C-e") #'better-eww-self-insert)
    (define-key map (kbd "C-d") #'better-eww-self-insert)
    (define-key map (kbd "M-f") #'better-eww-self-insert)
    (define-key map (kbd "M-b") #'better-eww-self-insert)
    (define-key map (kbd "C-s") #'better-eww-isearch-forward)
    (define-key map (kbd "C-r") #'better-eww-isearch-backward)

    ;; Mouse → forward to browser.
    (define-key map [mouse-1] #'better-eww-click)
    (define-key map [wheel-down] #'better-eww-scroll-down)
    (define-key map [wheel-up] #'better-eww-scroll-up)

    ;; Browser commands under C-c prefix (Emacs convention for major modes).
    (define-key map (kbd "C-c l") #'better-eww-navigate)
    (define-key map (kbd "C-c r") #'better-eww-refresh)
    (define-key map (kbd "C-c b") #'better-eww-back)
    (define-key map (kbd "C-c f") #'better-eww-forward)
    (define-key map (kbd "C-c q") #'better-eww-quit)
    (define-key map (kbd "C-c C-k") #'better-eww-quit)
    (define-key map (kbd "C-c +") #'better-eww-zoom-in)
    (define-key map (kbd "C-c -") #'better-eww-zoom-out)
    (define-key map (kbd "C-c h") #'better-eww-follow-hint)
    (define-key map (kbd "C-c t") #'better-eww-view-text)
    (define-key map (kbd "C-c w") #'better-eww-copy-url)
    (define-key map (kbd "C-c s") #'better-eww-isearch-forward)
    (define-key map (kbd "C-c n") #'better-eww-new-tab)
    (define-key map (kbd "C-c d") #'better-eww-close-tab)
    (define-key map (kbd "C-c ]") #'better-eww-next-tab)
    (define-key map (kbd "C-c [") #'better-eww-prev-tab)
    (define-key map (kbd "C-c a") #'better-eww-list-tabs)
    (define-key map (kbd "C-c :") #'better-eww-execute-js)
    map))

;; ── Major mode ─────────────────────────────────────────────────────

(define-derived-mode better-eww-mode nil "better-eww"
  "Major mode for the better-eww browser buffer."
  :group 'better-eww
  (setq-local buffer-read-only t)
  (setq-local cursor-type nil)
  (setq-local bookmark-make-record-function #'better-eww--bookmark-make-record)
  (add-hook 'pre-command-hook #'better-eww--maybe-end-search nil t))

;; ── Entry point ────────────────────────────────────────────────────

;;;###autoload
(defun better-eww-browse (url)
  "Launch better-eww and navigate to URL.
If the daemon is already running, just navigate to the new URL."
  (interactive "sURL: ")
  ;; Check if setup has been run.
  (when (better-eww--setup-needed-p)
    (if (y-or-n-p "better-eww: Python venv not found. Run setup now? ")
        (progn
          (better-eww-setup-or-update)
          (error "better-eww: Setup started in *better-eww-setup* buffer. Run M-x better-eww-browse again when it finishes"))
      (error "better-eww: Run M-x better-eww-setup-or-update first")))
  ;; Create buffer if needed.
  (unless (buffer-live-p better-eww--buffer)
    (setq better-eww--buffer (generate-new-buffer "*better-eww*"))
    (with-current-buffer better-eww--buffer
      (better-eww-mode)))
  ;; Start daemon if needed.
  (unless (and better-eww--process (process-live-p better-eww--process))
    (better-eww--start-daemon)
    (let ((resp (better-eww--send-sync
                 `((cmd . "init")
                   (width . ,better-eww--viewport-width)
                   (height . ,better-eww--viewport-height)
                   (fps . ,better-eww-fps)))))
      (if (alist-get 'error resp)
          (error "better-eww: init failed: %s" (alist-get 'error resp))
        ;; Daemon tells us where it writes frames.
        (setq better-eww--frame-path (alist-get 'frame_path resp)))))
  ;; Show buffer and navigate.
  (switch-to-buffer better-eww--buffer)
  (better-eww-navigate url))

(provide 'better-eww)

;;; better-eww.el ends here
