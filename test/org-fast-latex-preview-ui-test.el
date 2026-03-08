;;; org-fast-latex-preview-ui-test.el --- Overlay tests -*- lexical-binding: t; -*-

;;; Code:

(require 'org-fast-latex-preview-test-support)
(require 'org-fast-latex-preview-core)
(require 'org-fast-latex-preview-ui)

(ert-deftest org-fast-latex-preview-ui-overlay-lifecycle ()
  (let ((svg-file (make-temp-file "oflp-ui-" nil ".svg" "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")))
    (unwind-protect
        (org-fast-latex-preview-test--with-temp-org-buffer
            "$E=mc^2$"
          (let* ((fragment (org-fast-latex-preview--make-fragment
                            :begin-marker (copy-marker (point-min))
                            :end-marker (copy-marker (point-max) t)
                            :source "$E=mc^2$"
                            :cache-key "demo"
                            :cache-file svg-file))
                 (overlay (org-fast-latex-preview--place-overlay fragment svg-file)))
            (should (overlayp overlay))
            (should (= 1 org-fast-latex-preview--overlay-count))
            (should (eq overlay
                        (org-fast-latex-preview--find-overlay
                         (point-min) (point-max))))
            (should (overlay-get overlay 'display))
            (org-fast-latex-preview--open-overlay overlay)
            (should-not (overlay-get overlay 'display))
            (org-fast-latex-preview--close-overlay overlay)
            (should (overlay-get overlay 'display))
            (org-fast-latex-preview-clear)
            (should (zerop org-fast-latex-preview--overlay-count))
            (should-not (org-fast-latex-preview-test--preview-overlays))))
      (delete-file svg-file))))

(provide 'org-fast-latex-preview-ui-test)
;;; org-fast-latex-preview-ui-test.el ends here
