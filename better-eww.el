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
  (file-name-directory (file-truename (or load-file-name buffer-file-name)))
  "Directory where better-eww source lives (resolved through symlinks).")

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

;; ── Internal state ─────────────────────────────────────────────────

(defvar better-eww--process nil "The daemon subprocess.")
(defvar better-eww--buffer nil "The display buffer.")
(defvar better-eww--response-buffer "" "Accumulator for partial JSON lines from the process.")
(defvar better-eww--callback nil "Function to call with the next command response.")
(defvar better-eww--insert-mode nil "Non-nil when insert mode is active.")
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

(defun better-eww-navigate (url)
  "Navigate to URL."
  (interactive (list (completing-read "URL: " better-eww--url-history nil nil nil
                                      'better-eww--url-history)))
  (push url better-eww--url-history)
  (delete-dups better-eww--url-history)
  (better-eww--send `((cmd . "navigate") (url . ,url))
                     #'better-eww--action-callback))

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
  (let* ((tags (mapcar (lambda (h) (alist-get 'tag h)) better-eww--hints))
         (descriptions (mapcar (lambda (h)
                                 (format "%s: %s" (alist-get 'tag h)
                                         (alist-get 'text h)))
                               better-eww--hints))
         (chosen (completing-read "Hint: " descriptions nil t)))
    ;; Extract the tag from "tag: description".
    (when (string-match "\\`\\([^:]+\\):" chosen)
      (let* ((tag (match-string 1 chosen))
             (hint (seq-find (lambda (h) (string= (alist-get 'tag h) tag))
                             better-eww--hints)))
        (when hint
          (better-eww--send '((cmd . "hints-clear")) nil)
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

(defun better-eww-find (query)
  "Highlight QUERY on the page using the browser's built-in find."
  (interactive "sFind: ")
  (better-eww--send
   `((cmd . "js")
     (expr . ,(format "window.find('%s')"
                      (replace-regexp-in-string "'" "\\\\'" query))))
   (lambda (resp)
     (if-let* ((err (alist-get 'error resp)))
         (message "better-eww find error: %s" err)
       (unless (eq (alist-get 'result resp) t)
         (message "better-eww: not found"))))))

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
  "Show all tabs in the echo area."
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
                                       tabs)))
                           (message "Tabs:\n%s" (string-join strs "\n")))))))

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

;; ── Insert mode ────────────────────────────────────────────────────

(defun better-eww-enter-insert-mode ()
  "Enter insert mode — forward keystrokes to the browser."
  (interactive)
  (setq better-eww--insert-mode t)
  (message "better-eww: INSERT mode (C-g to exit)"))

(defun better-eww-exit-insert-mode ()
  "Exit insert mode — return to navigation keybindings."
  (interactive)
  (setq better-eww--insert-mode nil)
  (message "better-eww: NAVIGATION mode"))

(defun better-eww--translate-key (key)
  "Translate an Emacs KEY description to a Playwright key name."
  (pcase key
    ("RET" "Enter")
    ("TAB" "Tab")
    ("DEL" "Backspace")
    ("SPC" " ")
    ("<backspace>" "Backspace")
    ("<return>" "Enter")
    ("<tab>" "Tab")
    ("<escape>" "Escape")
    ("<delete>" "Delete")
    ("<home>" "Home")
    ("<end>" "End")
    ("<up>" "ArrowUp")
    ("<down>" "ArrowDown")
    ("<left>" "ArrowLeft")
    ("<right>" "ArrowRight")
    ("<prior>" "PageUp")
    ("<next>" "PageDown")
    (_ key)))

(defun better-eww-self-insert ()
  "In insert mode, forward the key to the browser."
  (interactive)
  (if (not better-eww--insert-mode)
      (message "better-eww: press 'i' to enter insert mode first")
    (let* ((keys (this-command-keys-vector))
           (key-desc (key-description keys))
           (pw-key (better-eww--translate-key key-desc)))
      (if (= (length pw-key) 1)
          (better-eww--send `((cmd . "type") (text . ,pw-key))
                             #'better-eww--action-callback)
        (better-eww--send `((cmd . "key") (key . ,pw-key))
                           #'better-eww--action-callback)))))

;; ── Keymap ─────────────────────────────────────────────────────────

(defvar better-eww-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Insert mode: bind all printable characters + special keys FIRST.
    ;; Explicit navigation bindings below override these for their keys.
    (dolist (c (number-sequence 32 126))
      (define-key map (vector c) #'better-eww-self-insert))
    (dolist (key '("<return>" "<backspace>" "<tab>" "<escape>" "<delete>"
                   "<home>" "<end>" "<up>" "<down>" "<left>" "<right>"
                   "<prior>" "<next>"))
      (define-key map (kbd key) #'better-eww-self-insert))

    ;; Navigation mode bindings (override self-insert for these keys).
    (define-key map (kbd "g") #'better-eww-navigate)
    (define-key map (kbd "r") #'better-eww-refresh)
    (define-key map (kbd "B") #'better-eww-back)
    (define-key map (kbd "F") #'better-eww-forward)
    (define-key map (kbd "q") #'better-eww-quit)
    (define-key map (kbd "+") #'better-eww-zoom-in)
    (define-key map (kbd "-") #'better-eww-zoom-out)
    (define-key map (kbd "i") #'better-eww-enter-insert-mode)
    (define-key map (kbd "C-g") #'better-eww-exit-insert-mode)
    ;; Link hints.
    (define-key map (kbd "f") #'better-eww-follow-hint)
    ;; Text / clipboard.
    (define-key map (kbd "t") #'better-eww-view-text)
    (define-key map (kbd "w") #'better-eww-copy-url)
    ;; Find in page.
    (define-key map (kbd "s") #'better-eww-find)
    ;; Tabs.
    (define-key map (kbd "T") #'better-eww-new-tab)
    (define-key map (kbd "d") #'better-eww-close-tab)
    (define-key map (kbd "J") #'better-eww-next-tab)
    (define-key map (kbd "K") #'better-eww-prev-tab)
    (define-key map (kbd "b") #'better-eww-list-tabs)
    ;; JS console.
    (define-key map (kbd ":") #'better-eww-execute-js)

    ;; Mouse bindings.
    (define-key map [mouse-1] #'better-eww-click)
    (define-key map [wheel-down] #'better-eww-scroll-down)
    (define-key map [wheel-up] #'better-eww-scroll-up)
    map)
  "Keymap for `better-eww-mode'.")

;; ── Major mode ─────────────────────────────────────────────────────

(define-derived-mode better-eww-mode special-mode "better-eww"
  "Major mode for the better-eww browser buffer."
  :group 'better-eww
  (setq-local buffer-read-only t)
  (setq-local cursor-type nil)
  (setq-local better-eww--insert-mode nil)
  (setq-local bookmark-make-record-function #'better-eww--bookmark-make-record))

;; ── Entry point ────────────────────────────────────────────────────

;;;###autoload
(defun better-eww-browse (url)
  "Launch better-eww and navigate to URL.
If the daemon is already running, just navigate to the new URL."
  (interactive "sURL: ")
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
