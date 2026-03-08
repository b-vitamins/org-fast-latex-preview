;;; org-fast-latex-preview-cache-test.el --- Cache tests -*- lexical-binding: t; -*-

;;; Code:

(require 'org-fast-latex-preview-test-support)
(require 'org-fast-latex-preview-core)
(require 'org-fast-latex-preview-cache)

(ert-deftest org-fast-latex-preview-cache-key-is-deterministic ()
  (let ((org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$E=mc^2$"
      (let* ((context (org-fast-latex-preview--build-context))
             (key-a (org-fast-latex-preview--cache-key-for-source
                     "$E=mc^2$" context))
             (key-b (org-fast-latex-preview--cache-key-for-source
                     "$E=mc^2$" context)))
        (should (string= key-a key-b))))))

(ert-deftest org-fast-latex-preview-cache-key-reflects-render-context ()
  (let ((org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$E=mc^2$"
      (let* ((org-fast-latex-preview-extra-preamble "")
             (context-a (org-fast-latex-preview--build-context))
             (key-a (org-fast-latex-preview--cache-key-for-source
                     "$E=mc^2$" context-a))
             (org-fast-latex-preview-extra-preamble "\\newcommand{\\foo}{x}\n")
             (context-b (org-fast-latex-preview--build-context))
             (key-b (org-fast-latex-preview--cache-key-for-source
                     "$E=mc^2$" context-b)))
        (should-not (string= key-a key-b))))))

(ert-deftest org-fast-latex-preview-cache-key-reflects-cache-version ()
  (let ((org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$E=mc^2$"
      (let* ((context (org-fast-latex-preview--build-context))
             (key-a (let ((org-fast-latex-preview--cache-version 1))
                      (org-fast-latex-preview--cache-key-for-source
                       "$E=mc^2$" context)))
             (key-b (let ((org-fast-latex-preview--cache-version 2))
                      (org-fast-latex-preview--cache-key-for-source
                       "$E=mc^2$" context))))
        (should-not (string= key-a key-b))))))

(ert-deftest org-fast-latex-preview-invalid-cache-file-is-rejected ()
  (let ((file (make-temp-file "oflp-cache-invalid-" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "not an svg"))
          (should-not (org-fast-latex-preview--usable-cache-file-p file))
          (should-not (file-exists-p file)))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest org-fast-latex-preview-cache-file-uses-context-directory ()
  (let* ((directory (make-temp-file "oflp-cache-test-" t))
         (context (org-fast-latex-preview--make-context
                   :cache-directory directory))
         (file (org-fast-latex-preview--cache-file-for-key "abc123" context)))
    (unwind-protect
        (should (string= file
                         (expand-file-name "abc123.svg" directory)))
      (delete-directory directory t))))

(provide 'org-fast-latex-preview-cache-test)
;;; org-fast-latex-preview-cache-test.el ends here
