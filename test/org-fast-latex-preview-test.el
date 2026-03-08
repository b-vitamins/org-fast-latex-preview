;;; org-fast-latex-preview-test.el --- Integration tests for org-fast-latex-preview -*- lexical-binding: t; -*-

;;; Code:

(require 'org-fast-latex-preview-test-support)
(require 'org-fast-latex-preview)

(ert-deftest org-fast-latex-preview-does-not-shim-org-commands-until-enabled ()
  (unwind-protect
      (progn
        (setq org-fast-latex-preview--org-command-shims-installed nil)
        (advice-remove 'org-latex-preview
                       #'org-fast-latex-preview--advice-org-latex-preview)
        (advice-remove 'org-clear-latex-preview
                       #'org-fast-latex-preview--advice-org-clear-latex-preview)
        (should-not org-fast-latex-preview--org-command-shims-installed)
        (should-not
         (advice-member-p #'org-fast-latex-preview--advice-org-latex-preview
                          'org-latex-preview))
        (should-not
         (advice-member-p #'org-fast-latex-preview--advice-org-clear-latex-preview
                          'org-clear-latex-preview)))
    (advice-remove 'org-latex-preview
                   #'org-fast-latex-preview--advice-org-latex-preview)
    (advice-remove 'org-clear-latex-preview
                   #'org-fast-latex-preview--advice-org-clear-latex-preview)
    (setq org-fast-latex-preview--org-command-shims-installed nil)))

(ert-deftest org-fast-latex-preview-disabling-last-buffer-removes-org-shims ()
  (unwind-protect
      (progn
        (global-org-fast-latex-preview-mode -1)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (when (bound-and-true-p org-fast-latex-preview-mode)
              (org-fast-latex-preview-mode -1))))
        (org-fast-latex-preview-test--with-temp-org-buffer
            "Inline $E=mc^2$.\n"
          (org-fast-latex-preview-mode 1)
          (should org-fast-latex-preview--org-command-shims-installed)
          (should
           (advice-member-p #'org-fast-latex-preview--advice-org-latex-preview
                            'org-latex-preview))
          (org-fast-latex-preview-mode -1)
          (should-not org-fast-latex-preview--org-command-shims-installed)
          (should-not
           (advice-member-p #'org-fast-latex-preview--advice-org-latex-preview
                            'org-latex-preview))))
    (advice-remove 'org-latex-preview
                   #'org-fast-latex-preview--advice-org-latex-preview)
    (advice-remove 'org-clear-latex-preview
                   #'org-fast-latex-preview--advice-org-clear-latex-preview)
    (setq org-fast-latex-preview--org-command-shims-installed nil)))

(ert-deftest org-fast-latex-preview-stop-runtime-resets-ephemeral-state ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (let ((org-fast-latex-preview--dirty-ranges '((1 . 4)))
          (org-fast-latex-preview--failure-report 'sentinel)
          cancel-called
          reset-called)
      (setq org-fast-latex-preview--dirty-timer
            (run-with-timer 60 nil #'ignore))
      (setq org-fast-latex-preview--opened-overlay (make-overlay 8 16))
      (cl-letf (((symbol-function 'org-fast-latex-preview--cancel-jobs)
                 (lambda ()
                   (setq cancel-called t)))
                ((symbol-function 'org-fast-latex-preview--reset-failure-report)
                 (lambda ()
                   (setq reset-called t)
                   (setq org-fast-latex-preview--failure-report nil))))
        (org-fast-latex-preview--stop-runtime))
      (should cancel-called)
      (should reset-called)
      (should-not org-fast-latex-preview--dirty-ranges)
      (should-not org-fast-latex-preview--dirty-timer)
      (should-not org-fast-latex-preview--opened-overlay)
      (should-not org-fast-latex-preview--failure-report))))

(ert-deftest org-fast-latex-preview-before-revert-clears-state-and-schedules-rerender ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (let ((org-fast-latex-preview-mode t))
      (let ((overlay (make-overlay 8 16)))
        (overlay-put overlay 'org-fast-latex-preview t)
        (setq org-fast-latex-preview--overlay-count 1)
        (setq org-fast-latex-preview--dirty-ranges '((8 . 16)))
        (setq org-fast-latex-preview--dirty-timer
              (run-with-timer 60 nil #'ignore))
        (org-fast-latex-preview--before-revert)
        (should org-fast-latex-preview--rerender-after-revert)
        (should-not (overlays-in (point-min) (point-max)))
        (should-not org-fast-latex-preview--dirty-ranges)
        (should-not org-fast-latex-preview--dirty-timer)))))

(ert-deftest org-fast-latex-preview-mode-leaves-org-preview-keybinding-alone ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (org-fast-latex-preview-mode 1)
    (should (eq (key-binding (kbd "C-c C-x C-l"))
                #'org-latex-preview))
    (org-fast-latex-preview-mode -1)
    (should (eq (key-binding (kbd "C-c C-x C-l"))
                #'org-latex-preview))))

(ert-deftest org-fast-latex-preview-mode-routes-org-latex-preview ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (let (captured-arg)
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) t))
                ((symbol-function 'org-fast-latex-preview)
                 (lambda (&optional arg)
                   (setq captured-arg arg))))
        (org-fast-latex-preview-mode 1)
        (org-latex-preview '(16)))
      (should (equal '(16) captured-arg)))))

(ert-deftest org-fast-latex-preview-mode-routes-org-clear-latex-preview ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (let (captured-range)
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) t))
                ((symbol-function 'org-fast-latex-preview-clear)
                 (lambda (&optional beg end)
                   (setq captured-range (cons beg end)))))
        (org-fast-latex-preview-mode 1)
        (org-clear-latex-preview 8 16))
      (should (equal '(8 . 16) captured-range)))))

(ert-deftest org-fast-latex-preview-can-leave-org-commands-unmodified ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (let ((org-fast-latex-preview-override-org-commands nil)
          original-called)
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) t)))
        (org-fast-latex-preview-mode 1)
        (org-fast-latex-preview--advice-org-latex-preview
         (lambda (&optional arg)
         (setq original-called arg))
         '(4)))
      (should (equal '(4) original-called)))))

(ert-deftest org-fast-latex-preview-mode-does-not-remap-org-keybindings ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (org-fast-latex-preview-mode 1)
    (should (eq 'org-latex-preview
                (key-binding (kbd "C-c C-x C-l"))))))

(ert-deftest org-fast-latex-preview-mode-does-not-mutate-org-preview-state ()
  (let ((original-process org-preview-latex-default-process)
        (original-options (copy-tree org-format-latex-options))
        (original-header org-format-latex-header)
        (original-packages (copy-tree org-latex-packages-alist)))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "Inline $E=mc^2$.\n"
      (org-fast-latex-preview-mode 1)
      (should (eq original-process org-preview-latex-default-process))
      (should (equal original-options org-format-latex-options))
      (should (equal original-header org-format-latex-header))
      (should (equal original-packages org-latex-packages-alist)))
    (should (eq original-process org-preview-latex-default-process))
    (should (equal original-options org-format-latex-options))
    (should (equal original-header org-format-latex-header))
    (should (equal original-packages org-latex-packages-alist))))

(ert-deftest org-fast-latex-preview-global-mode-enables-org-buffers-only ()
  (unwind-protect
      (progn
        (global-org-fast-latex-preview-mode 1)
        (org-fast-latex-preview-test--with-temp-org-buffer
            "Inline $E=mc^2$.\n"
          (should org-fast-latex-preview-mode))
        (with-temp-buffer
          (text-mode)
          (should-not org-fast-latex-preview-mode)))
    (global-org-fast-latex-preview-mode -1)))

(ert-deftest org-fast-latex-preview-mode-binds-max-image-size-locally ()
  (let ((org-fast-latex-preview-max-image-size 40.0)
        (original max-image-size))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "Inline $E=mc^2$.\n"
      (org-fast-latex-preview-mode 1)
      (should (local-variable-p 'max-image-size))
      (should (equal 40.0 max-image-size))
      (org-fast-latex-preview-mode -1)
      (should-not (local-variable-p 'max-image-size))
      (should (equal original max-image-size)))))

(ert-deftest org-fast-latex-preview-renders-and-reuses-cache ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let ((cache-dir (make-temp-file "oflp-cache-" t))
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-debug nil))
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (org-fast-latex-preview-test--with-temp-org-buffer
              "Inline $E=mc^2$.\n\n\\begin{equation}\n\\int_0^1 x^2\\,dx = 1/3\n\\end{equation}\n"
            (let ((first (org-fast-latex-preview--render-range
                          (point-min) (point-max) t)))
              (should (= 0 (plist-get first :cached)))
              (should (= 2 (plist-get first :queued))))
            (org-fast-latex-preview-test--wait-for-jobs)
            (should (= 2 (length (org-fast-latex-preview-test--preview-overlays))))
            (should (= 2 (length (directory-files cache-dir nil "\\.svg\\'"))))
            (org-fast-latex-preview-clear)
            (let ((second (org-fast-latex-preview--render-range
                           (point-min) (point-max) nil)))
              (should (= 2 (plist-get second :cached)))
              (should (= 0 (plist-get second :queued)))
              (should-not org-fast-latex-preview--jobs)
              (should (= 2 (length (org-fast-latex-preview-test--preview-overlays)))))))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-recovers-from-corrupt-cache-file ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let ((cache-dir (make-temp-file "oflp-cache-" t))
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-debug nil))
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (org-fast-latex-preview-test--with-temp-org-buffer
              "Inline $E=mc^2$.\n"
            (org-fast-latex-preview--render-range (point-min) (point-max) t)
            (org-fast-latex-preview-test--wait-for-jobs)
            (let* ((overlay (car (org-fast-latex-preview-test--preview-overlays)))
                   (cache-file (overlay-get overlay 'org-fast-latex-preview-image)))
              (with-temp-file cache-file
                (insert "not an svg"))
              (org-fast-latex-preview-clear)
              (let ((result (org-fast-latex-preview--render-range
                             (point-min) (point-max) nil)))
                (should (= 0 (plist-get result :cached)))
                (should (= 1 (plist-get result :queued))))
              (org-fast-latex-preview-test--wait-for-jobs)
              (should (= 1 (length (org-fast-latex-preview-test--preview-overlays))))
              (should (org-fast-latex-preview--cache-file-valid-p cache-file)))))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-splits-failing-batches ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let ((cache-dir (make-temp-file "oflp-cache-" t))
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-failure-strategy 'split)
        (org-fast-latex-preview-debug nil))
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (org-fast-latex-preview-test--with-temp-org-buffer
              "Good $E=mc^2$.\nBad $\\thiscommanddoesnotexist$.\n"
            (org-fast-latex-preview--render-range (point-min) (point-max) t)
            (org-fast-latex-preview-test--wait-for-jobs)
            (let ((overlays (org-fast-latex-preview-test--preview-overlays)))
              (should (= 1 (length overlays)))
              (should (string=
                       "$E=mc^2$"
                       (overlay-get (car overlays) 'org-fast-latex-preview-source))))
            (let ((failure-buffers
                   (cl-remove-if-not
                    (lambda (buffer)
                      (string-match-p
                       "\\*org-fast-latex-preview-failure\\*"
                       (buffer-name buffer)))
                    (buffer-list))))
              (should (= 1 (length failure-buffers)))
              (with-current-buffer (car failure-buffers)
                (should (string-match-p "Failed fragments: 1"
                                        (buffer-string)))
                (should (string-match-p "Undefined control sequence"
                                        (buffer-string)))))))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-aggregates-repeated-failures ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let ((cache-dir (make-temp-file "oflp-cache-" t))
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-failure-strategy 'split)
        (org-fast-latex-preview-debug nil))
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (org-fast-latex-preview-test--with-temp-org-buffer
              "Bad $\\thiscommanddoesnotexist$.\nAlso bad $\\thiscommanddoesnotexist$.\n"
            (org-fast-latex-preview--render-range (point-min) (point-max) t)
            (org-fast-latex-preview-test--wait-for-jobs)
            (should-not (org-fast-latex-preview-test--preview-overlays))
            (let ((failure-buffers
                   (cl-remove-if-not
                    (lambda (buffer)
                      (string-match-p
                       "\\*org-fast-latex-preview-failure\\*"
                       (buffer-name buffer)))
                    (buffer-list))))
              (should (= 1 (length failure-buffers)))
              (with-current-buffer (car failure-buffers)
                (should (string-match-p "Failed fragments: 2"
                                        (buffer-string)))
                (should (string-match-p "1\\. LaTeX (2 fragments)"
                                        (buffer-string)))))))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-recovers-after-deleted-temp-directory ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let ((cache-dir (make-temp-file "oflp-cache-" t))
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-batch-size 4)
        (org-fast-latex-preview-failure-strategy 'split)
        (org-fast-latex-preview-debug nil))
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (org-fast-latex-preview-test--with-temp-org-buffer
              "A $E=mc^2$.\nB $a^2+b^2=c^2$.\nC $\\int_0^1 x\\,dx$.\nD $\\sum_{n=0}^4 n$.\n"
            (org-fast-latex-preview--render-range (point-min) (point-max) t)
            (while (not org-fast-latex-preview--jobs)
              (accept-process-output nil 0.01))
            (delete-directory
             (org-fast-latex-preview--job-temp-directory
              (car org-fast-latex-preview--jobs))
             t)
            (org-fast-latex-preview-test--wait-for-jobs)
            (should-not org-fast-latex-preview--jobs)
            (should (zerop (org-fast-latex-preview-test--job-buffer-count)))
            (org-fast-latex-preview-clear)
            (org-fast-latex-preview-test--cleanup-failure-buffers)
            (org-fast-latex-preview--render-range (point-min) (point-max) t)
            (org-fast-latex-preview-test--wait-for-jobs)
            (should (= 4 (length (org-fast-latex-preview-test--preview-overlays))))))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-disable-mode-cancels-active-jobs ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let ((cache-dir (make-temp-file "oflp-cache-" t))
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-batch-size 8)
        (org-fast-latex-preview-debug nil)
        (content (mapconcat
                  (lambda (index)
                    (format "Eq %d: $x_{%d} = y_{%d} + z_{%d}$"
                            index index index index))
                  (number-sequence 1 80)
                  "\n")))
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (with-temp-buffer
            (org-mode)
            (insert content)
            (goto-char (point-min))
            (org-fast-latex-preview-mode 1)
            (org-fast-latex-preview-buffer t)
            (while (not org-fast-latex-preview--jobs)
              (accept-process-output nil 0.01))
            (org-fast-latex-preview-mode -1)
            (should-not org-fast-latex-preview--jobs)
            (should-not org-fast-latex-preview--dirty-timer)
            (org-fast-latex-preview-test--wait-for-global-settle)))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-rerenders-after-revert ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let* ((cache-dir (make-temp-file "oflp-cache-" t))
         (path (make-temp-file "oflp-revert-" nil ".org"))
         (initial "Inline $E=mc^2$.\n")
         (updated "Inline $E=mc^2$.\n\nSecond $a^2+b^2=c^2$.\n")
         (org-fast-latex-preview-preamble-source 'lean)
         (org-fast-latex-preview-compiler 'latex)
         (org-fast-latex-preview-debug nil)
         buffer)
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (with-temp-file path
            (insert initial))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (org-mode)
            (org-fast-latex-preview-mode 1)
            (org-fast-latex-preview-buffer t)
            (org-fast-latex-preview-test--wait-for-jobs)
            (should (= 1 (length (org-fast-latex-preview-test--preview-overlays))))
            (with-temp-file path
              (insert updated))
            (revert-buffer :ignore-auto :noconfirm)
            (org-fast-latex-preview-test--wait-for-jobs)
            (should (= 2 (length (org-fast-latex-preview-test--preview-overlays))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p path)
        (delete-file path))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-kill-buffer-cleans-up-active-jobs ()
  (skip-unless (org-fast-latex-preview-test--tools-available-p))
  (let* ((cache-dir (make-temp-file "oflp-cache-" t))
         (path (make-temp-file "oflp-kill-" nil ".org"))
         (org-fast-latex-preview-preamble-source 'lean)
         (org-fast-latex-preview-compiler 'latex)
         (org-fast-latex-preview-batch-size 16)
         (org-fast-latex-preview-debug nil)
         (content
          (mapconcat
           (lambda (index)
             (format "Line %d: $\\int_0^1 x_{%d}^2\\,dx = \\frac{1}{3}$"
                     index index))
           (number-sequence 1 200)
           "\n"))
         buffer)
    (unwind-protect
        (let ((org-fast-latex-preview-cache-directory cache-dir))
          (with-temp-file path
            (insert content))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer
            (org-mode)
            (org-fast-latex-preview-buffer t)
            (while (not org-fast-latex-preview--jobs)
              (accept-process-output nil 0.01))
            (kill-buffer buffer))
          (setq buffer nil)
          (org-fast-latex-preview-test--wait-for-global-settle)
          (should (zerop (org-fast-latex-preview-test--job-buffer-count))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p path)
        (delete-file path))
      (delete-directory cache-dir t)
      (org-fast-latex-preview-test--cleanup-failure-buffers))))

(ert-deftest org-fast-latex-preview-flushes-dirty-ranges ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Inline $E=mc^2$.\n"
    (let ((org-fast-latex-preview-mode t)
          called)
      (setq org-fast-latex-preview--dirty-ranges '((8 . 12) (1 . 4)))
      (setq org-fast-latex-preview--dirty-timer
            (run-with-timer 60 nil #'ignore))
      (cl-letf (((symbol-function 'org-fast-latex-preview--refresh-dirty-range)
                 (lambda (beg end)
                   (setq called (list beg end)))))
        (org-fast-latex-preview--flush-dirty-ranges))
      (should (equal called '(1 12)))
      (should-not org-fast-latex-preview--dirty-ranges)
      (should-not org-fast-latex-preview--dirty-timer))))

(provide 'org-fast-latex-preview-test)
;;; org-fast-latex-preview-test.el ends here
