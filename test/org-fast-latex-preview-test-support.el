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
    (while (and org-fast-latex-preview--jobs
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
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

(defun org-fast-latex-preview-test--cleanup-failure-buffers ()
  "Kill any preserved failure buffers left by a test."
  (mapc #'kill-buffer (org-fast-latex-preview-test--failure-buffers)))

(provide 'org-fast-latex-preview-test-support)
;;; org-fast-latex-preview-test-support.el ends here
