;;; elint.el --- Batch elint runner for OFLP -*- lexical-binding: t; -*-

;;; Commentary:

;; Run elint over the files passed after `--' and exit non-zero when
;; warnings are reported.

;;; Code:

(setq load-prefer-newer t)

(require 'elint)
(require 'subr-x)

(defun oflp-elint--files-from-args ()
  "Return file arguments after `--'."
  (let ((args command-line-args-left))
    (if-let ((sep (member "--" args)))
        (cdr sep)
      args)))

(let* ((files (oflp-elint--files-from-args))
       (root (file-name-directory
              (directory-file-name
               (file-name-directory load-file-name))))
       (lisp-dir (expand-file-name "lisp" root))
       failures)
  (setq max-lisp-eval-depth (max 4000 max-lisp-eval-depth))
  (add-to-list 'load-path lisp-dir)
  (require 'org-fast-latex-preview)
  (dolist (file files)
    (when (get-buffer elint-log-buffer)
      (kill-buffer elint-log-buffer))
    (elint-file file)
    (when-let ((buffer (get-buffer elint-log-buffer)))
      (with-current-buffer buffer
        (let ((warnings (string-trim (buffer-string))))
          (unless (string-empty-p warnings)
            (push (cons file warnings) failures))))
      (kill-buffer buffer)))
  (if failures
      (progn
        (dolist (failure (nreverse failures))
          (princ (format "elint warnings in %s\n%s\n"
                         (car failure)
                         (cdr failure))))
        (kill-emacs 1))
    (princ (format "elint OK (%d files)\n" (length files)))))

;;; elint.el ends here
