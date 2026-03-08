;;; org-fast-latex-preview-cache.el --- Cache helpers for Org fast previews -*- lexical-binding: t; -*-

;;; Commentary:

;; Cache key generation, validation, and cache clearing helpers.

;;; Code:

(require 'org-fast-latex-preview-core)

(defconst org-fast-latex-preview--cache-validation-bytes 2048
  "Number of bytes read when validating a cached SVG.")

(defvar org-fast-latex-preview--cache-validation-table
  (make-hash-table :test 'equal)
  "Memoized cache validation results keyed by file name.")

(defun org-fast-latex-preview--cache-key-for-source (source context)
  "Return the cache key for SOURCE rendered using CONTEXT."
  (sha1
   (prin1-to-string
    (list org-fast-latex-preview--cache-version
          source
          (org-fast-latex-preview--context-preamble context)
          (org-fast-latex-preview--context-compiler-key context)
          (org-fast-latex-preview--context-foreground-rgb context)
          (org-fast-latex-preview--context-background-rgb context)
          (org-fast-latex-preview--context-render-scale context)
          (plist-get (org-fast-latex-preview--context-appearance context)
                     :page-width)))))

(defun org-fast-latex-preview--cache-file-for-key (cache-key context)
  "Return the cache file for CACHE-KEY under CONTEXT."
  (expand-file-name
   (format "%s.%s" cache-key org-fast-latex-preview--svg-extension)
   (org-fast-latex-preview--context-cache-directory context)))

(defun org-fast-latex-preview--cache-file-stat (file)
  "Return a compact file stat for FILE, or nil when absent."
  (when (file-regular-p file)
    (let ((attributes (file-attributes file)))
      (list (file-attribute-size attributes)
            (file-attribute-modification-time attributes)))))

(defun org-fast-latex-preview--cache-file-valid-p (file)
  "Return non-nil when FILE is a usable cached SVG."
  (and (stringp file)
       (file-regular-p file)
       (condition-case nil
           (with-temp-buffer
             (insert-file-contents-literally
              file nil 0 org-fast-latex-preview--cache-validation-bytes)
             (save-excursion
               (goto-char (point-min))
               (search-forward "<svg" nil t)))
         (error nil))))

(defun org-fast-latex-preview--usable-cache-file-p (file)
  "Return non-nil when FILE is a valid cache entry.

Invalid cache files are removed so future renders regenerate them."
  (when-let ((profile (org-fast-latex-preview--current-profile)))
    (org-fast-latex-preview--profile-inc profile 'cache_validation_checks))
  (let ((stat (org-fast-latex-preview--cache-file-stat file)))
    (cond
     ((null stat)
      (remhash file org-fast-latex-preview--cache-validation-table)
      nil)
     (t
      (pcase-let ((`(,cached-stat . ,cached-validity)
                   (gethash file org-fast-latex-preview--cache-validation-table
                            '(nil . nil))))
        (if (equal cached-stat stat)
            (progn
              (when-let ((profile (org-fast-latex-preview--current-profile)))
                (org-fast-latex-preview--profile-inc profile 'cache_validation_memo_hits))
              cached-validity)
          (when-let ((profile (org-fast-latex-preview--current-profile)))
            (org-fast-latex-preview--profile-inc profile 'cache_validation_scans))
          (if (org-fast-latex-preview--cache-file-valid-p file)
              (progn
                (puthash file (cons stat t)
                         org-fast-latex-preview--cache-validation-table)
                t)
            (remhash file org-fast-latex-preview--cache-validation-table)
            (ignore-errors
              (delete-file file))
            nil)))))))

;;;###autoload
(defun org-fast-latex-preview-clear-cache ()
  "Clear the persistent preview cache."
  (interactive)
  (let ((directory (org-fast-latex-preview--ensure-directory
                    org-fast-latex-preview-cache-directory)))
    (dolist (file (directory-files directory t "\\.svg\\'"))
      (delete-file file))
    (clrhash org-fast-latex-preview--cache-validation-table)
    (message "Cleared Org fast LaTeX preview cache")))

(provide 'org-fast-latex-preview-cache)
;;; org-fast-latex-preview-cache.el ends here
