;;; embr-passwd.el --- Password manager for embr  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 emacs-os

;; Author: emacs-os

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

;; Local GPG-encrypted password vault for embr.  Stores login/password
;; pairs in a JSON file encrypted via EasyPG.

;;; Code:

(require 'cl-lib)
(require 'epg)

;; ── Customization ──────────────────────────────────────────────────

(defgroup embr-passwd nil
  "GPG-encrypted password vault."
  :group 'embr
  :prefix "embr-passwd-")

(defcustom embr-passwd-encrypt-to nil
  "GPG key ID used to encrypt the vault.
Must be set before using any `embr-passwd' commands."
  :type 'string
  :group 'embr-passwd)

(defcustom embr-passwd-length 12
  "Length of generated passwords."
  :type 'integer
  :group 'embr-passwd)

(defcustom embr-passwd-pwgen-args "-ycn"
  "Arguments passed to pwgen before the length."
  :type 'string
  :group 'embr-passwd)

(defcustom embr-passwd-file
  (expand-file-name "passwd.json.gpg" "~/Documents")
  "Path to the GPG-encrypted password vault file."
  :type 'file
  :group 'embr-passwd)

;; ── Internal ───────────────────────────────────────────────────────

(defun embr-passwd--ensure-key ()
  "Error if `embr-passwd-encrypt-to' is not set."
  (unless embr-passwd-encrypt-to
    (user-error "Set `embr-passwd-encrypt-to' to your GPG key ID first")))

(defun embr-passwd--gpg-keys ()
  "Return the GPG key objects for `embr-passwd-encrypt-to'."
  (let* ((context (epg-make-context))
         (keys (epg-list-keys context embr-passwd-encrypt-to)))
    (unless keys
      (user-error "GPG key \"%s\" not found" embr-passwd-encrypt-to))
    keys))

(defun embr-passwd--read ()
  "Read the password vault and return a list of entries.
Each entry is an alist with `site', `password', and optional
`username', `email', and `notes' keys.
Return nil if the vault is empty."
  (embr-passwd--ensure-key)
  (unless (file-exists-p embr-passwd-file)
    (user-error "Vault does not exist; run `embr-passwd-init' first"))
  (let* ((context (epg-make-context))
         (cipher (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (let ((inhibit-file-name-handlers
                          (cons 'epa-file-handler
                                (and (eq inhibit-file-name-operation
                                         'insert-file-contents)
                                     inhibit-file-name-handlers)))
                         (inhibit-file-name-operation 'insert-file-contents))
                     (insert-file-contents-literally embr-passwd-file))
                   (buffer-string)))
         (plain (decode-coding-string
                 (epg-decrypt-string context cipher)
                 'utf-8)))
    (if (string-empty-p plain)
        nil
      (json-parse-string plain :array-type 'list :object-type 'alist))))

(defun embr-passwd--write (entries)
  "Write ENTRIES to the password vault.
ENTRIES is a list of alists with `site', `password', and optional
`username', `email', and `notes' keys."
  (embr-passwd--ensure-key)
  (let* ((context (epg-make-context))
         (plain (if entries
                    (encode-coding-string (json-serialize (vconcat entries))
                                          'utf-8)
                  ""))
         (keys (embr-passwd--gpg-keys))
         (cipher (epg-encrypt-string context plain keys)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert cipher)
      (let ((coding-system-for-write 'no-conversion)
            (inhibit-file-name-handlers
             (cons 'epa-file-handler
                   (and (eq inhibit-file-name-operation 'write-region)
                        inhibit-file-name-handlers)))
            (inhibit-file-name-operation 'write-region))
        (write-region (point-min) (point-max) embr-passwd-file)))))

;; ── Commands ───────────────────────────────────────────────────────

;;;###autoload
(defun embr-passwd-init ()
  "Create an empty password vault at `embr-passwd-file'.
Requires `embr-passwd-encrypt-to' to be set to a GPG key ID.
To generate a GPG key, see URL
`https://docs.github.com/en/authentication/managing-commit-signature-verification/generating-a-new-gpg-key'.
Give your own key ultimate trust: gpg --edit-key KEYID trust (select 5)."
  (interactive)
  (embr-passwd--ensure-key)
  (if (file-exists-p embr-passwd-file)
      (message "Vault already exists at %s" embr-passwd-file)
    (let ((dir (file-name-directory embr-passwd-file)))
      (unless (file-directory-p dir)
        (make-directory dir t)))
    (let* ((context (epg-make-context))
           (keys (embr-passwd--gpg-keys))
           (cipher (epg-encrypt-string context "" keys)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert cipher)
        (let ((coding-system-for-write 'no-conversion)
              (inhibit-file-name-handlers
               (cons 'epa-file-handler
                     (and (eq inhibit-file-name-operation 'write-region)
                          inhibit-file-name-handlers)))
              (inhibit-file-name-operation 'write-region))
          (write-region (point-min) (point-max) embr-passwd-file))))
    (message "Created empty vault at %s" embr-passwd-file)))

(defun embr-passwd--generate ()
  "Return a new password from pwgen, signaling an error if it fails.
Reading the command's output through a shell would hand back its
error message as the password; running it directly and checking the
exit status does not."
  (unless (executable-find "pwgen")
    (user-error "pwgen not found; install it first"))
  (with-temp-buffer
    (let ((status (apply #'call-process "pwgen" nil t nil
                         (append (split-string-and-unquote
                                  embr-passwd-pwgen-args)
                                 (list (number-to-string embr-passwd-length)
                                       "1")))))
      (unless (eql status 0)
        (error "pwgen failed (exit %s): %s"
               status (string-trim (buffer-string)))))
    (let ((pw (string-trim (buffer-string))))
      (when (string-empty-p pw)
        (error "pwgen produced no output"))
      pw)))

;;;###autoload
(defun embr-passwd-add (site username email password &optional notes)
  "Add an entry for SITE with USERNAME, EMAIL, PASSWORD, and optional NOTES.
USERNAME and EMAIL are each optional; supply at least one."
  (interactive
   (list (read-string "Site: ")
         (let ((u (read-string "Username (optional): ")))
           (unless (string-empty-p u) u))
         (let ((e (read-string "Email (optional): ")))
           (unless (string-empty-p e) e))
         (let ((pw (read-passwd "Password (empty to generate): ")))
           (when (string-empty-p pw)
             (setq pw (embr-passwd--generate))
             (kill-new pw)
             (message "Generated password copied to kill ring"))
           pw)
         (let ((n (read-string "Notes (optional): ")))
           (unless (string-empty-p n) n))))
  (when (string-empty-p site)
    (user-error "Site cannot be empty"))
  (when (string-empty-p password)
    (user-error "Password cannot be empty"))
  (let ((entries (embr-passwd--read)))
    (when (cl-find site entries
                   :key (lambda (e) (alist-get 'site e))
                   :test #'string=)
      (user-error "Entry for \"%s\" already exists; remove it first" site))
    (push `((site . ,site)
            ,@(when username `((username . ,username)))
            ,@(when email    `((email    . ,email)))
            (password . ,password)
            ,@(when notes    `((notes    . ,notes))))
          entries)
    (embr-passwd--write entries)
    (message "Added entry for \"%s\"" site)))

;;;###autoload
(defun embr-passwd-remove (site)
  "Remove the entry matching SITE from the vault."
  (interactive
   (let* ((entries (embr-passwd--read))
          (sites (mapcar (lambda (e) (alist-get 'site e)) entries)))
     (unless sites
       (user-error "Vault is empty"))
     (list (completing-read "Remove site: " sites nil t))))
  (let* ((entries (embr-passwd--read))
         (filtered (cl-remove site entries
                              :key (lambda (e) (alist-get 'site e))
                              :test #'string=)))
    (if (= (length entries) (length filtered))
        (message "No entry found for \"%s\"" site)
      (if (y-or-n-p (format "Remove \"%s\"? " site))
          (progn
            (embr-passwd--write filtered)
            (message "Removed entry for \"%s\"" site))
        (message "Cancelled")))))

;;;###autoload
(defun embr-passwd-get (site)
  "Copy the password for SITE to the kill ring."
  (interactive
   (let* ((entries (embr-passwd--read))
          (sites (mapcar (lambda (e) (alist-get 'site e)) entries)))
     (unless sites
       (user-error "Vault is empty"))
     (list (completing-read "Get password for: " sites nil t))))
  (let* ((entries (embr-passwd--read))
         (entry (cl-find site entries
                         :key (lambda (e) (alist-get 'site e))
                         :test #'string=)))
    (if entry
        (progn
          (kill-new (alist-get 'password entry))
          (message "Password for \"%s\" copied to kill ring" site))
      (user-error "No entry found for \"%s\"" site))))

;;;###autoload
(defun embr-passwd-generate ()
  "Generate a password with pwgen and copy it to the kill ring.
Password length is controlled by `embr-passwd-length'."
  (interactive)
  (let ((pw (embr-passwd--generate)))
    (kill-new pw)
    (message "Generated password copied to kill ring")))

;; ── Browser integration ────────────────────────────────────────────

(defvar embr--current-url)
(declare-function embr--send "embr")
(declare-function embr--send-sync "embr")
(declare-function embr--mouse-image-coords "embr")

(defun embr-passwd--domain (url)
  "Extract the domain from URL."
  (if (string-match "://\\([^/:]+\\)" url)
      (match-string 1 url)
    url))

(defun embr-passwd--wait-for-confirm (prompt)
  "Show PROMPT overlay on the page, let user navigate freely.
Return when RET is pressed.  All other input is dispatched normally."
  (embr--send-sync `((cmd . "overlay") (text . ,prompt) (show . t)))
  (unwind-protect
      (catch 'embr-passwd--confirmed
        (while t
          (let* ((keys (read-key-sequence-vector nil))
                 (event (aref keys 0))
                 (binding (key-binding keys)))
            (cond
             ((eq event ?\C-j)
              (throw 'embr-passwd--confirmed nil))
             ((eq binding 'keyboard-quit) (keyboard-quit))
             (binding (call-interactively binding))))))
    (embr--send-sync `((cmd . "overlay") (show . :false)))))

;;;###autoload
(defun embr-passwd-inject ()
  "Fill credential fields on the current page from the vault.
For each field present in the entry (username, email, password),
prompt the user to select the target field, then fill it."
  (interactive)
  (let* ((entries (embr-passwd--read))
         (_ (unless entries (user-error "Vault is empty")))
         (labels (mapcar (lambda (e)
                           (let* ((u  (alist-get 'username e))
                                  (em (alist-get 'email e))
                                  (id (cond ((and u em) (format "%s / %s" u em))
                                            (u u) (em em) (t "?"))))
                             (format "%s -- %s" (alist-get 'site e) id)))
                         entries))
         (chosen (completing-read "Credentials: " labels nil t))
         (entry (nth (cl-position chosen labels :test #'string=)
                     entries))
         (steps `(,@(when (alist-get 'username entry)
                      `(("Select the username field, press C-j to fill"
                         . ,(alist-get 'username entry))))
                  ,@(when (alist-get 'email entry)
                      `(("Select the email field, press C-j to fill"
                         . ,(alist-get 'email entry))))
                  ,@(when (alist-get 'password entry)
                      `(("Select the password field, press C-j to fill"
                         . ,(alist-get 'password entry)))))))
    (dolist (step steps)
      (embr-passwd--wait-for-confirm (car step))
      (embr--send-sync `((cmd . "type-text") (value . ,(cdr step)))))
    (message "Filled credentials for \"%s\"" (alist-get 'site entry))))

(provide 'embr-passwd)

;;; embr-passwd.el ends here
