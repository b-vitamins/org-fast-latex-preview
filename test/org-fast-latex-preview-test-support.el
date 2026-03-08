;;; org-fast-latex-preview-test-support.el --- Test helpers -*- lexical-binding: t; -*-

;;; Code:

(setq load-prefer-newer t)

(require 'cl-lib)
(require 'ert)
(require 'org)

(defmacro org-fast-latex-preview-test--with-temp-org-buffer (content &rest body)
  "Create a temporary Org buffer with CONTENT and run BODY there."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,content)
     (goto-char (point-min))
     ,@body))

(defun org-fast-latex-preview-test--reset-global-state ()
  "Reset OFLP global state between tests."
  (when (fboundp 'global-org-fast-latex-preview-mode)
    (global-org-fast-latex-preview-mode -1))
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (bound-and-true-p org-fast-latex-preview-mode)
          (org-fast-latex-preview-mode -1)))))
  (when (fboundp 'org-fast-latex-preview--advice-org-latex-preview)
    (advice-remove 'org-latex-preview
                   #'org-fast-latex-preview--advice-org-latex-preview))
  (when (fboundp 'org-fast-latex-preview--advice-org-clear-latex-preview)
    (advice-remove 'org-clear-latex-preview
                   #'org-fast-latex-preview--advice-org-clear-latex-preview))
  (when (boundp 'org-fast-latex-preview--org-command-shims-installed)
    (setq org-fast-latex-preview--org-command-shims-installed nil))
  (when (fboundp 'org-fast-latex-preview-test--cleanup-failure-buffers)
    (org-fast-latex-preview-test--cleanup-failure-buffers)))

(defmacro org-fast-latex-preview-test--with-clean-global-state (&rest body)
  "Run BODY with OFLP global state reset before and after the test."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (org-fast-latex-preview-test--reset-global-state)
         ,@body)
     (org-fast-latex-preview-test--reset-global-state)))

(defun org-fast-latex-preview-test--tools-available-p ()
  "Return non-nil when external preview tools are available."
  (and (executable-find "latex")
       (executable-find "dvisvgm")
       (executable-find "kpsewhich")
       (with-temp-buffer
         (eq 0 (call-process "kpsewhich" nil t nil "preview.sty")))))

(defun org-fast-latex-preview-test--wait-for-jobs (&optional timeout)
  "Wait for active preview jobs, failing after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30.0))))
    (while (and (or org-fast-latex-preview--jobs
                    org-fast-latex-preview--pending-batches)
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (should-not org-fast-latex-preview--pending-batches)
    (should-not org-fast-latex-preview--jobs)))

(defun org-fast-latex-preview-test--preview-overlays ()
  "Return all preview overlays in the current buffer."
  (cl-remove-if-not #'org-fast-latex-preview--overlay-p
                    (overlays-in (point-min) (point-max))))

(defun org-fast-latex-preview-test--job-buffer-count ()
  "Return the number of live hidden preview job buffers."
  (cl-count-if
   (lambda (buffer)
     (string-match-p "^ \\*org-fast-latex-preview-job" (buffer-name buffer)))
   (buffer-list)))

(defun org-fast-latex-preview-test--failure-buffers ()
  "Return all aggregated OFLP failure report buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (string-match-p "\\*org-fast-latex-preview-failure\\*" (buffer-name buffer)))
   (buffer-list)))

(defun org-fast-latex-preview-test--wait-for-global-settle (&optional timeout)
  "Wait until hidden preview job buffers disappear within TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30.0))))
    (while (and (> (org-fast-latex-preview-test--job-buffer-count) 0)
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (should (zerop (org-fast-latex-preview-test--job-buffer-count)))))

(defun org-fast-latex-preview-test--wait-for-overlay-count (count &optional timeout)
  "Wait until the current buffer contains COUNT preview overlays."
  (let ((deadline (+ (float-time) (or timeout 30.0))))
    (while (and (< (length (org-fast-latex-preview-test--preview-overlays))
                   count)
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (should (= count
               (length (org-fast-latex-preview-test--preview-overlays))))))

(defun org-fast-latex-preview-test--cleanup-failure-buffers ()
  "Kill any preserved failure buffers left by a test."
  (mapc #'kill-buffer (org-fast-latex-preview-test--failure-buffers)))

(provide 'org-fast-latex-preview-test-support)
;;; org-fast-latex-preview-test-support.el ends here
