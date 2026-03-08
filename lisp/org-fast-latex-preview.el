;;; org-fast-latex-preview.el --- Fast batched LaTeX previews for Org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ayan Das

;; Author: Ayan Das <bvits@riseup.net>
;; Maintainer: Ayan Das <bvits@riseup.net>
;; Package-Requires: ((emacs "29.1") (org "9.7"))
;; Keywords: tex, outlines, tools
;; URL: https://github.com/b-vitamins/org-fast-latex-preview
;; Version: 0.1.0

;;; Commentary:

;; `org-fast-latex-preview' provides fast, batched LaTeX previews for
;; Org buffers.
;;
;; The package is intentionally scoped:
;; - Org buffers only
;; - SVG rendering via `dvisvgm'
;; - Persistent on-disk cache
;; - Asynchronous batched rendering
;; - Stable overlay lifecycle with quiet hidden worker buffers
;;
;; The primary interactive entry point is `org-fast-latex-preview'.
;; Turn on `org-fast-latex-preview-mode' to reveal previews at point and
;; re-render changed fragments after an idle delay.

;;; Code:

(require 'org-fast-latex-preview-core)
(require 'org-fast-latex-preview-cache)
(require 'org-fast-latex-preview-ui)
(require 'org-fast-latex-preview-render)

(defvar org-fast-latex-preview-mode-map
  (make-sparse-keymap)
  "Keymap for `org-fast-latex-preview-mode'.")

(defvar org-fast-latex-preview-mode nil
  "Non-nil when `org-fast-latex-preview-mode' is enabled.")

(defvar global-org-fast-latex-preview-mode nil
  "Non-nil when `global-org-fast-latex-preview-mode' is enabled.")

(defvar-local org-fast-latex-preview--lifecycle-hooks-installed nil
  "Non-nil when OFLP lifecycle hooks are installed in the current buffer.")

(defvar-local org-fast-latex-preview--rerender-after-revert nil
  "Non-nil when previews should be restored after a buffer revert.")

(defvar-local org-fast-latex-preview--saved-max-image-size nil
  "Saved `max-image-size' value from before OFLP mode was enabled.")

(defvar-local org-fast-latex-preview--saved-max-image-size-local nil
  "Whether `max-image-size' was buffer-local before OFLP mode was enabled.")

(defvar org-fast-latex-preview--org-command-shims-installed nil
  "Non-nil when OFLP's Org command shims are currently installed.")

(put 'org-fast-latex-preview--lifecycle-hooks-installed 'permanent-local t)
(put 'org-fast-latex-preview--rerender-after-revert 'permanent-local t)

(defun org-fast-latex-preview--install-org-command-shims ()
  "Install Org command shims when configured to do so."
  (when (and org-fast-latex-preview-override-org-commands
             (not org-fast-latex-preview--org-command-shims-installed))
    (advice-add 'org-latex-preview :around
                #'org-fast-latex-preview--advice-org-latex-preview)
    (advice-add 'org-clear-latex-preview :around
                #'org-fast-latex-preview--advice-org-clear-latex-preview)
    (setq org-fast-latex-preview--org-command-shims-installed t)))

(defun org-fast-latex-preview--maybe-remove-org-command-shims ()
  "Remove Org command shims when OFLP no longer needs them."
  (unless (or global-org-fast-latex-preview-mode
              (cl-some (lambda (buffer)
                         (buffer-local-value 'org-fast-latex-preview-mode buffer))
                       (buffer-list)))
    (when org-fast-latex-preview--org-command-shims-installed
      (advice-remove 'org-latex-preview
                     #'org-fast-latex-preview--advice-org-latex-preview)
      (advice-remove 'org-clear-latex-preview
                     #'org-fast-latex-preview--advice-org-clear-latex-preview)
      (setq org-fast-latex-preview--org-command-shims-installed nil))))

(defun org-fast-latex-preview--org-command-shim-active-p ()
  "Return non-nil when Org preview commands should route through OFLP."
  (and org-fast-latex-preview-override-org-commands
       org-fast-latex-preview-mode
       (derived-mode-p 'org-mode)
       (display-graphic-p)))

(defun org-fast-latex-preview--advice-org-latex-preview (orig-fun &optional arg)
  "Route `org-latex-preview' to OFLP when the minor mode is active.

ORIG-FUN is the original `org-latex-preview' function and ARG is its
optional prefix argument."
  (if (org-fast-latex-preview--org-command-shim-active-p)
      (org-fast-latex-preview arg)
    (funcall orig-fun arg)))

(defun org-fast-latex-preview--advice-org-clear-latex-preview
    (orig-fun &optional beg end)
  "Route `org-clear-latex-preview' to OFLP while the minor mode is active.

ORIG-FUN is the original `org-clear-latex-preview' function.  BEG and
END restrict clearing to a subrange when non-nil."
  (if (org-fast-latex-preview--org-command-shim-active-p)
      (org-fast-latex-preview-clear beg end)
    (funcall orig-fun beg end)))

(defun org-fast-latex-preview--preview-present-p ()
  "Return non-nil when the current buffer has any OFLP preview overlays."
  (or (> org-fast-latex-preview--overlay-count 0)
      (cl-some #'org-fast-latex-preview--overlay-p
               (overlays-in (point-min) (point-max)))))

(defun org-fast-latex-preview--stop-runtime ()
  "Stop OFLP runtime activity in the current buffer without clearing overlays."
  (when (timerp org-fast-latex-preview--dirty-timer)
    (cancel-timer org-fast-latex-preview--dirty-timer)
    (setq org-fast-latex-preview--dirty-timer nil))
  (setq org-fast-latex-preview--dirty-ranges nil)
  (setq org-fast-latex-preview--context-chain nil
        org-fast-latex-preview--context-chain-index 0
        org-fast-latex-preview--generation-range nil)
  (when (and (overlayp org-fast-latex-preview--opened-overlay)
             (overlay-buffer org-fast-latex-preview--opened-overlay))
    (org-fast-latex-preview--close-overlay
     org-fast-latex-preview--opened-overlay))
  (setq org-fast-latex-preview--opened-overlay nil)
  (org-fast-latex-preview--cancel-jobs)
  (org-fast-latex-preview--reset-failure-report))

(defun org-fast-latex-preview--teardown-buffer ()
  "Fully tear down OFLP state in the current buffer."
  (org-fast-latex-preview--stop-runtime)
  (org-fast-latex-preview-clear))

(defun org-fast-latex-preview--before-revert ()
  "Tear down preview state before the current buffer is reverted."
  (setq org-fast-latex-preview--rerender-after-revert
        (and org-fast-latex-preview-mode
             (or org-fast-latex-preview--jobs
                 org-fast-latex-preview--pending-batches
                 org-fast-latex-preview--dirty-ranges
                 (org-fast-latex-preview--preview-present-p))))
  (org-fast-latex-preview--teardown-buffer))

(defun org-fast-latex-preview--after-revert ()
  "Restore previews after a buffer revert when appropriate."
  (when org-fast-latex-preview--rerender-after-revert
    (setq org-fast-latex-preview--rerender-after-revert nil)
    (org-fast-latex-preview-buffer t)))

(defun org-fast-latex-preview--kill-buffer ()
  "Tear down preview state before the current buffer is killed."
  (org-fast-latex-preview--teardown-buffer))

(defun org-fast-latex-preview--ensure-lifecycle-hooks ()
  "Install buffer-local lifecycle hooks for OFLP."
  (unless org-fast-latex-preview--lifecycle-hooks-installed
    (add-hook 'kill-buffer-hook #'org-fast-latex-preview--kill-buffer nil t)
    (add-hook 'before-revert-hook #'org-fast-latex-preview--before-revert nil t)
    (add-hook 'after-revert-hook #'org-fast-latex-preview--after-revert nil t)
    (setq org-fast-latex-preview--lifecycle-hooks-installed t)))

;;;###autoload
(defun org-fast-latex-preview-buffer (&optional refresh)
  "Render previews in the current buffer.

When REFRESH is non-nil, clear existing previews first."
  (interactive "P")
  (let ((result (org-fast-latex-preview--render-range (point-min) (point-max)
                                                      refresh)))
    (message "Org fast LaTeX preview: %d cached, %d queued"
             (plist-get result :cached)
             (plist-get result :queued))))

;;;###autoload
(defun org-fast-latex-preview-region (beg end &optional refresh)
  "Render previews between BEG and END.

When REFRESH is non-nil, clear existing previews first."
  (interactive "r\nP")
  (let ((result (org-fast-latex-preview--render-range beg end refresh)))
    (message "Org fast LaTeX preview: %d cached, %d queued"
             (plist-get result :cached)
             (plist-get result :queued))))

;;;###autoload
(defun org-fast-latex-preview-subtree (&optional refresh)
  "Render previews in the current Org subtree.

When REFRESH is non-nil, clear existing previews first."
  (interactive "P")
  (save-excursion
    (let ((beg (if (org-before-first-heading-p)
                   (point-min)
                 (progn
                   (org-back-to-heading t)
                   (point))))
          (end (org-entry-end-position)))
      (org-fast-latex-preview-region beg end refresh))))

;;;###autoload
(defun org-fast-latex-preview-at-point (&optional refresh)
  "Toggle or refresh the preview at point.

When REFRESH is non-nil, force a re-render."
  (interactive "P")
  (let ((datum (org-element-context)))
    (unless (org-element-type-p datum '(latex-fragment latex-environment))
      (user-error "Point is not on a LaTeX fragment"))
    (pcase-let* ((`(,beg . ,end)
                  (org-fast-latex-preview--trim-fragment
                   (org-element-property :begin datum)
                   (org-element-property :end datum)))
                 (overlay (org-fast-latex-preview--find-overlay beg end)))
      (if (and overlay (not refresh))
          (progn
            (org-fast-latex-preview--delete-overlay overlay)
            (message "LaTeX preview removed"))
        (org-fast-latex-preview-region beg end t)))))

;;;###autoload
(defun org-fast-latex-preview-refresh (&optional arg)
  "Refresh previews according to ARG.

With no prefix ARG, refresh at point when on a fragment, otherwise refresh
the current subtree.

With a double prefix argument, refresh the whole buffer."
  (interactive "P")
  (cond
   ((equal arg '(16))
    (org-fast-latex-preview-buffer t))
   ((org-element-type-p (org-element-context)
                        '(latex-fragment latex-environment))
    (org-fast-latex-preview-at-point t))
   (t
    (org-fast-latex-preview-subtree t))))

;;;###autoload
(defun org-fast-latex-preview (&optional arg)
  "Preview LaTeX fragments according to prefix ARG.

No prefix:
  Toggle preview at point when on a fragment, otherwise preview the
  current subtree, or the active region.

Single prefix argument:
  Clear previews in the active region or current subtree.

Double prefix argument:
  Preview the entire buffer.

Triple prefix argument:
  Clear previews in the entire buffer."
  (interactive "P")
  (cond
   ((equal arg '(64))
    (org-fast-latex-preview-clear)
    (message "LaTeX previews removed from buffer"))
   ((equal arg '(16))
    (org-fast-latex-preview-buffer))
   ((equal arg '(4))
    (if (use-region-p)
        (org-fast-latex-preview-clear (region-beginning) (region-end))
      (save-excursion
        (let ((beg (if (org-before-first-heading-p)
                       (point-min)
                     (progn (org-back-to-heading t) (point))))
              (end (org-entry-end-position)))
          (org-fast-latex-preview-clear beg end)))))
   ((use-region-p)
    (org-fast-latex-preview-region (region-beginning) (region-end)))
   ((org-element-type-p (org-element-context)
                        '(latex-fragment latex-environment))
    (org-fast-latex-preview-at-point))
   (t
    (org-fast-latex-preview-subtree))))

(defun org-fast-latex-preview--post-command ()
  "Handle reveal/hide behavior for previews at point."
  (unless (memq this-command org-fast-latex-preview-mode-ignored-commands)
    (let ((overlay (org-fast-latex-preview--at-point-overlay)))
      (unless (eq overlay org-fast-latex-preview--opened-overlay)
        (when (and (overlayp org-fast-latex-preview--opened-overlay)
                   (overlay-buffer org-fast-latex-preview--opened-overlay))
          (org-fast-latex-preview--close-overlay
           org-fast-latex-preview--opened-overlay))
        (setq org-fast-latex-preview--opened-overlay nil)
        (when (and (overlayp overlay) (overlay-buffer overlay))
          (org-fast-latex-preview--open-overlay overlay)
          (setq org-fast-latex-preview--opened-overlay overlay))))))

(defun org-fast-latex-preview--flush-dirty-ranges ()
  "Render any queued dirty ranges immediately."
  (when (timerp org-fast-latex-preview--dirty-timer)
    (cancel-timer org-fast-latex-preview--dirty-timer))
  (setq org-fast-latex-preview--dirty-timer nil)
  (when (and org-fast-latex-preview-mode
             org-fast-latex-preview--dirty-ranges)
    (let ((beg (apply #'min
                      (mapcar #'car org-fast-latex-preview--dirty-ranges)))
          (end (apply #'max
                      (mapcar #'cdr org-fast-latex-preview--dirty-ranges))))
      (setq org-fast-latex-preview--dirty-ranges nil)
      (org-fast-latex-preview--refresh-dirty-range beg end))))

(defun org-fast-latex-preview--run-dirty-timer (buffer)
  "Flush queued dirty ranges in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (org-fast-latex-preview--flush-dirty-ranges))))

(defun org-fast-latex-preview--queue-dirty-range (beg end)
  "Queue the dirty range between BEG and END."
  (push (cons beg end) org-fast-latex-preview--dirty-ranges)
  (when (timerp org-fast-latex-preview--dirty-timer)
    (cancel-timer org-fast-latex-preview--dirty-timer))
  (setq org-fast-latex-preview--dirty-timer
        (run-with-idle-timer
         org-fast-latex-preview-mode-update-delay nil
         #'org-fast-latex-preview--run-dirty-timer
         (current-buffer))))

(defun org-fast-latex-preview--after-change (beg end _len)
  "Track modifications between BEG and END."
  (dolist (overlay (overlays-in beg end))
    (when (org-fast-latex-preview--overlay-p overlay)
      (org-fast-latex-preview--delete-overlay overlay)))
  (when org-fast-latex-preview-mode
    (org-fast-latex-preview--queue-dirty-range beg end)))

(defun org-fast-latex-preview--enable-mode ()
  "Enable OFLP mode in the current buffer."
  (org-fast-latex-preview--install-org-command-shims)
  (setq org-fast-latex-preview--saved-max-image-size max-image-size
        org-fast-latex-preview--saved-max-image-size-local
        (local-variable-p 'max-image-size))
  (when org-fast-latex-preview-max-image-size
    (setq-local max-image-size org-fast-latex-preview-max-image-size))
  (org-fast-latex-preview--ensure-lifecycle-hooks)
  (add-hook 'post-command-hook #'org-fast-latex-preview--post-command nil t)
  (add-hook 'after-change-functions #'org-fast-latex-preview--after-change nil t))

(defun org-fast-latex-preview--disable-mode ()
  "Disable OFLP mode in the current buffer."
  (remove-hook 'post-command-hook #'org-fast-latex-preview--post-command t)
  (remove-hook 'after-change-functions #'org-fast-latex-preview--after-change t)
  (if org-fast-latex-preview--saved-max-image-size-local
      (setq-local max-image-size org-fast-latex-preview--saved-max-image-size)
    (kill-local-variable 'max-image-size))
  (setq org-fast-latex-preview--saved-max-image-size nil
        org-fast-latex-preview--saved-max-image-size-local nil)
  (org-fast-latex-preview--stop-runtime)
  (org-fast-latex-preview--maybe-remove-org-command-shims))

(defun org-fast-latex-preview--turn-on-in-org-buffer ()
  "Enable OFLP in the current buffer when it is an Org buffer."
  (when (derived-mode-p 'org-mode)
    (org-fast-latex-preview-mode 1)))

(defun org-fast-latex-preview--apply-global-mode-state (enabled)
  "Apply global OFLP mode state ENABLED to existing Org buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (org-fast-latex-preview-mode (if enabled 1 -1))))))

;;;###autoload
(define-minor-mode org-fast-latex-preview-mode
  "Reveal previews at point and refresh dirty fragments after edits."
  :lighter " OFLP"
  :keymap org-fast-latex-preview-mode-map
  (if org-fast-latex-preview-mode
      (org-fast-latex-preview--enable-mode)
    (org-fast-latex-preview--disable-mode)))

;;;###autoload
(define-minor-mode global-org-fast-latex-preview-mode
  "Enable `org-fast-latex-preview-mode' in Org buffers."
  :global t
  :group 'org-fast-latex-preview
  (if global-org-fast-latex-preview-mode
      (add-hook 'org-mode-hook #'org-fast-latex-preview--turn-on-in-org-buffer)
    (remove-hook 'org-mode-hook #'org-fast-latex-preview--turn-on-in-org-buffer))
  (org-fast-latex-preview--apply-global-mode-state
   global-org-fast-latex-preview-mode))

(provide 'org-fast-latex-preview)
;;; org-fast-latex-preview.el ends here
