;;; package-lint.el --- Batch package-lint runner for OFLP -*- lexical-binding: t; -*-

;;; Commentary:

;; Install package-lint into a local temp package dir when needed, then
;; run it over the files passed after `--'.

;;; Code:

(setq load-prefer-newer t)

(require 'package)

(defun oflp-package-lint--files-from-args ()
  "Return file arguments after `--'."
  (let ((args command-line-args-left))
    (if-let ((sep (member "--" args)))
        (cdr sep)
      args)))

(let ((package-user-dir (expand-file-name ".pkg-lint" default-directory))
      (package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                          ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                          ("melpa" . "https://melpa.org/packages/"))))
  (package-initialize)
  (unless (package-installed-p 'package-lint)
    (package-refresh-contents)
    (package-install 'package-lint))
  (require 'package-lint)
  (setq command-line-args-left (oflp-package-lint--files-from-args))
  (package-lint-batch-and-exit))

;;; package-lint.el ends here
