;;; checkdoc.el --- Batch checkdoc runner for OFLP -*- lexical-binding: t; -*-

;;; Commentary:

;; Run checkdoc over the files passed after `--' and exit non-zero when
;; warnings are reported.

;;; Code:

(setq load-prefer-newer t)

(require 'checkdoc)
(require 'subr-x)

(defun oflp-checkdoc--files-from-args ()
  "Return file arguments after `--'."
  (let ((args command-line-args-left))
    (if-let ((sep (member "--" args)))
        (cdr sep)
      args)))

(defun oflp-checkdoc--real-warning-text (text)
  "Return TEXT when it contains real warnings, otherwise nil."
  (let ((trimmed (string-trim text)))
    (unless (or (string-empty-p trimmed)
                (string-match-p
                 "\\`[[:space:]\f]*\\*\\*\\* [^:\n]+: checkdoc-current-buffer[[:space:]\f]*\\'"
                 text))
      trimmed)))

(let ((files (oflp-checkdoc--files-from-args))
      failures)
  (dolist (file files)
    (checkdoc-file file)
    (when-let ((buffer (get-buffer "*warn*")))
      (with-current-buffer buffer
        (when-let ((warnings (oflp-checkdoc--real-warning-text
                              (buffer-string))))
          (push (cons file warnings) failures)))
      (kill-buffer buffer)))
  (if failures
      (progn
        (dolist (failure (nreverse failures))
          (princ (format "checkdoc warnings in %s\n%s\n"
                         (car failure)
                         (cdr failure))))
        (kill-emacs 1))
    (princ (format "checkdoc OK (%d files)\n" (length files)))))

;;; checkdoc.el ends here
