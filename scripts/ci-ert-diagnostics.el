;;; ci-ert-diagnostics.el --- CI diagnostics for unexpected ERT results -*- lexical-binding: t; -*-

;;; Commentary:

;; Load the OFLP test files before this script.  It reruns the loaded ERT
;; tests, prints each unexpected result with its condition, and exits non-zero
;; when any unexpected result remains.

;;; Code:

(require 'ert)

(let (failures)
  (dolist (test (ert-select-tests t t))
    (let ((result (ert-run-test test)))
      (unless (or (ert-test-passed-p result)
                  (and (fboundp 'ert-test-skipped-p)
                       (ert-test-skipped-p result)))
        (push (format "%S => %S"
                      (ert-test-name test)
                      (if (fboundp 'ert-test-result-with-condition-condition)
                          (ert-test-result-with-condition-condition result)
                        result))
              failures))))
  (setq failures (nreverse failures))
  (if failures
      (progn
        (princ (mapconcat #'identity failures "\n"))
        (princ "\n")
        (kill-emacs 1))
    (princ "No unexpected ERT results.\n")
    (kill-emacs 0)))

;;; ci-ert-diagnostics.el ends here
