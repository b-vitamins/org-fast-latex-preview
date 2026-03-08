;;; org-fast-latex-preview-render.el --- Rendering pipeline for Org fast previews -*- lexical-binding: t; -*-

;;; Commentary:

;; Fragment collection, async TeX jobs, context promotion, and render
;; scheduling.

;;; Code:

(declare-function org-fast-latex-preview--ensure-lifecycle-hooks
                  "org-fast-latex-preview")

(require 'org-fast-latex-preview-core)
(require 'org-fast-latex-preview-cache)
(require 'org-fast-latex-preview-ui)

(defun org-fast-latex-preview--trim-fragment (beg end)
  "Return a cons cell of trimmed bounds between BEG and END."
  (save-excursion
    (goto-char end)
    (skip-chars-backward " \r\t\n" beg)
    (cons beg (point))))

(defun org-fast-latex-preview--make-fragment-from-bounds
    (frag-beg frag-end context cache-entry-table)
  "Create a preview fragment between FRAG-BEG and FRAG-END.

CONTEXT and CACHE-ENTRY-TABLE are reused while collecting fragments."
  (pcase-let* ((`(,trimmed-beg . ,trimmed-end)
                (org-fast-latex-preview--trim-fragment frag-beg frag-end))
               (source (buffer-substring-no-properties trimmed-beg trimmed-end))
               (cache-entry
                (or (gethash source cache-entry-table)
                    (let* ((cache-key
                            (org-fast-latex-preview--cache-key-for-source
                             source context))
                           (cache-file
                            (org-fast-latex-preview--cache-file-for-key
                             cache-key context))
                           (entry (cons cache-key cache-file)))
                      (puthash source entry cache-entry-table)
                      entry))))
    (org-fast-latex-preview--make-fragment
     :beg trimmed-beg
     :end trimmed-end
     :begin-marker nil
     :end-marker nil
     :source source
     :cache-key (car cache-entry)
     :cache-file (cdr cache-entry)
     :existing-overlay nil)))

(defun org-fast-latex-preview--collect-bracket-display-fragments
    (beg end context cache-entry-table)
  "Collect full `\\[ ... \\]' fragments between BEG and END.

CONTEXT and CACHE-ENTRY-TABLE are reused while collecting fragments."
  (let (fragments)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward "\\\\\\[" end t)
        (let ((frag-beg (match-beginning 0)))
          (when (re-search-forward "\\\\\\]" end t)
            (push (org-fast-latex-preview--make-fragment-from-bounds
                   frag-beg (match-end 0) context cache-entry-table)
                  fragments)))))
    (nreverse fragments)))

(defun org-fast-latex-preview--fragment-within-ranges-p (frag-beg frag-end ranges)
  "Return non-nil when FRAG-BEG and FRAG-END are contained in RANGES."
  (cl-some
   (lambda (range)
     (and (> frag-beg (car range))
          (< frag-end (cdr range))))
   ranges))

(defun org-fast-latex-preview--collect-fragments (beg end context)
  "Collect LaTeX fragments between BEG and END for CONTEXT."
  (let ((math-regexp "\\$\\|\\\\[([]\\|^[ \t]*\\\\begin{[A-Za-z0-9*]+}")
        fragments
        (cache-entry-table (make-hash-table :test 'equal))
        (seen-ranges (make-hash-table :test 'equal))
        display-ranges)
    (dolist (fragment
             (org-fast-latex-preview--collect-bracket-display-fragments
              beg end context cache-entry-table))
      (let ((range (cons (org-fast-latex-preview--fragment-beg fragment)
                         (org-fast-latex-preview--fragment-end fragment))))
        (push range display-ranges)
        (puthash range t seen-ranges)
        (push fragment fragments)))
    (save-excursion
      (goto-char beg)
      (while (re-search-forward math-regexp end t)
        (let* ((datum (org-element-context))
               (type (org-element-type datum)))
          (when (memq type '(latex-fragment latex-environment))
            (pcase-let* ((`(,frag-beg . ,frag-end)
                          (org-fast-latex-preview--trim-fragment
                           (org-element-property :begin datum)
                           (org-element-property :end datum)))
                         (range (cons frag-beg frag-end)))
              (unless (or (gethash range seen-ranges)
                          (org-fast-latex-preview--fragment-within-ranges-p
                           frag-beg frag-end
                           display-ranges))
                (puthash range t seen-ranges)
                (push
                 (org-fast-latex-preview--make-fragment-from-bounds
                  frag-beg frag-end context cache-entry-table)
                 fragments)))
            (goto-char (if end
                           (min end (org-element-property :end datum))
                         (org-element-property :end datum)))))))
    (nreverse fragments)))

(defun org-fast-latex-preview--fragment-current-p (fragment)
  "Return non-nil when FRAGMENT still matches current buffer text."
  (let* ((beg (org-fast-latex-preview--fragment-begin-position fragment))
         (end (org-fast-latex-preview--fragment-end-position fragment)))
    (and beg end
         (<= beg end)
         (<= end (point-max))
         (string=
          (buffer-substring-no-properties beg end)
          (org-fast-latex-preview--fragment-source fragment)))))

(defun org-fast-latex-preview--existing-overlay-valid-p (fragment)
  "Return non-nil when FRAGMENT already has a valid preview overlay."
  (let ((overlay (or (org-fast-latex-preview--fragment-existing-overlay fragment)
                     (setf (org-fast-latex-preview--fragment-existing-overlay fragment)
                           (org-fast-latex-preview--find-overlay
                            (org-fast-latex-preview--fragment-beg fragment)
                            (org-fast-latex-preview--fragment-end fragment))))))
    (and (overlayp overlay)
         (overlay-buffer overlay)
         (string=
          (overlay-get overlay 'org-fast-latex-preview-cache-key)
          (org-fast-latex-preview--fragment-cache-key fragment))
         (org-fast-latex-preview--fragment-current-p fragment)
         (org-fast-latex-preview--usable-cache-file-p
          (overlay-get overlay 'org-fast-latex-preview-image)))))

(defun org-fast-latex-preview--page-width-code (context)
  "Return page-width LaTeX code for CONTEXT."
  (org-fast-latex-preview--page-width-snippet
   (plist-get (org-fast-latex-preview--context-appearance context)
              :page-width)))

(defun org-fast-latex-preview--batch-source (fragments context)
  "Return a TeX document for FRAGMENTS rendered with CONTEXT."
  (let ((foreground (org-fast-latex-preview--context-foreground-rgb context))
        (background (org-fast-latex-preview--context-background-rgb context)))
    (concat
     (org-fast-latex-preview--context-preamble context)
     "\n\\usepackage[active,tightpage]{preview}\n"
     "\\usepackage{xcolor}\n"
     "\\pagestyle{empty}\n"
     (org-fast-latex-preview--page-width-code context)
     (when foreground
       (format "\\definecolor{oflpfg}{rgb}{%s}\n"
               (org-fast-latex-preview--rgb-string foreground)))
     (when background
       (format "\\definecolor{oflpbg}{rgb}{%s}\n\\pagecolor{oflpbg}\n"
               (org-fast-latex-preview--rgb-string background)))
     "\\begin{document}\n"
     (mapconcat
      (lambda (fragment)
        (concat
         "\\begin{preview}\n"
         (if foreground "{\\color{oflpfg}\n" "")
         (org-fast-latex-preview--fragment-source fragment)
         (if foreground "\n}\n" "\n")
         "\\end{preview}\n"))
      fragments
      "\\clearpage\n")
     "\n\\end{document}\n")))

(defun org-fast-latex-preview--write-batch-file (job)
  "Write the TeX source for JOB and return the file path."
  (let* ((temp-directory (org-fast-latex-preview--job-temp-directory job))
         (tex-file (expand-file-name "preview-batch.tex" temp-directory))
         (profile (with-current-buffer (org-fast-latex-preview--job-buffer job)
                    (org-fast-latex-preview--current-profile
                     (org-fast-latex-preview--job-generation job)))))
    (with-temp-file tex-file
      (insert
       (org-fast-latex-preview--with-timing profile batch_source
         (org-fast-latex-preview--batch-source
          (org-fast-latex-preview--job-fragments job)
          (org-fast-latex-preview--job-context job)))))
    tex-file))

(defun org-fast-latex-preview--latex-command (job)
  "Return the LaTeX command vector for JOB."
  (let* ((context (org-fast-latex-preview--job-context job))
         (spec (org-fast-latex-preview--context-compiler-command context)))
    (append spec
            (list (org-fast-latex-preview--job-temp-directory job)
                  (org-fast-latex-preview--job-tex-file job)))))

(defun org-fast-latex-preview--dvisvgm-command (job)
  "Return the dvisvgm command vector for JOB."
  (let* ((context (org-fast-latex-preview--job-context job))
         (scale (org-fast-latex-preview--context-render-scale context))
         (output-pattern
          (expand-file-name "page-%p.svg"
                            (org-fast-latex-preview--job-temp-directory job))))
    (list "dvisvgm"
          "--page=1-"
          "-n"
          "-b" "min"
          "-c" (format "%.6f" scale)
          "-o" output-pattern
          (org-fast-latex-preview--job-input-file job))))

(defun org-fast-latex-preview--make-job-buffer ()
  "Create a hidden worker buffer."
  (generate-new-buffer " *org-fast-latex-preview-job*"))

(defun org-fast-latex-preview--keep-or-discard-job-buffer (buffer)
  "Dispose of BUFFER unless debugging is enabled."
  (when (buffer-live-p buffer)
    (if org-fast-latex-preview-debug
        (rename-buffer
         (generate-new-buffer-name " *org-fast-latex-preview-job-log*")
         t)
      (kill-buffer buffer))))

(defun org-fast-latex-preview--failure-buffer-name (buffer)
  "Return the aggregated failure buffer name for BUFFER."
  (format "%s: %s"
          org-fast-latex-preview--failure-buffer-name
          (buffer-name buffer)))

(defun org-fast-latex-preview--dispose-failure-log-buffer (buffer)
  "Dispose of a failed job log BUFFER."
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(defun org-fast-latex-preview--reset-failure-report ()
  "Clear failure state for the current buffer."
  (when-let ((report org-fast-latex-preview--failure-report))
    (when-let ((buffer (org-fast-latex-preview--failure-report-buffer report)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))
  (setq org-fast-latex-preview--failure-report nil))

(defun org-fast-latex-preview--ensure-failure-report (generation)
  "Return the failure report for GENERATION in the current buffer."
  (when (or (null org-fast-latex-preview--failure-report)
            (/= generation
                (org-fast-latex-preview--failure-report-generation
                 org-fast-latex-preview--failure-report)))
    (org-fast-latex-preview--reset-failure-report)
    (setq org-fast-latex-preview--failure-report
          (org-fast-latex-preview--make-failure-report
           :generation generation
           :instances nil
           :buffer nil
           :notified nil)))
  org-fast-latex-preview--failure-report)

(defun org-fast-latex-preview--job-log-summary (job)
  "Return a concise failure summary extracted from JOB."
  (or (org-fast-latex-preview--job-failure-summary job)
      (when-let ((buffer (org-fast-latex-preview--job-log-buffer job)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (let (headline location fallback)
              (save-excursion
                (goto-char (point-min))
                (when (re-search-forward "^! \\(.*\\)$" nil t)
                  (setq headline (string-trim (match-string 1)))
                  (when (re-search-forward "^l\\.[0-9]+ \\(.*\\)$" nil t)
                    (setq location (string-trim (match-string 1))))))
              (unless headline
                (save-excursion
                  (goto-char (point-max))
                  (let (lines)
                    (while (and (> (point) (point-min))
                                (< (length lines) 3))
                      (forward-line -1)
                      (let ((line (string-trim
                                   (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position)))))
                        (unless (string-empty-p line)
                          (push line lines))))
                    (when lines
                      (setq fallback (string-join lines " | "))))))
              (cond
               (headline
                (if location
                    (format "%s (%s)" headline location)
                  headline))
               (fallback fallback))))))
      "Unknown preview failure"))

(defun org-fast-latex-preview--failure-source-snippet (source)
  "Return a compact one-line snippet for SOURCE."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[ \t\n\r]+" " "
    (string-trim source))
   120 nil nil t))

(defun org-fast-latex-preview--failure-instance-overlaps-p (instance beg end)
  "Return non-nil when INSTANCE overlaps the range between BEG and END."
  (let ((instance-beg
         (marker-position
          (org-fast-latex-preview--failure-instance-begin-marker instance)))
        (instance-end
         (marker-position
          (org-fast-latex-preview--failure-instance-end-marker instance))))
    (and instance-beg instance-end
         (< instance-beg end)
         (> instance-end beg))))

(defun org-fast-latex-preview--remove-failure-instances-in-range (beg end)
  "Forget recorded failures overlapping BEG and END in the current buffer."
  (when-let ((report org-fast-latex-preview--failure-report))
    (let* ((instances (org-fast-latex-preview--failure-report-instances report))
           (filtered
            (cl-remove-if
             (lambda (instance)
               (org-fast-latex-preview--failure-instance-overlaps-p
                instance beg end))
             instances)))
      (unless (eq filtered instances)
        (setf (org-fast-latex-preview--failure-report-instances report) filtered
              (org-fast-latex-preview--failure-report-notified report) nil)
        (if filtered
            (org-fast-latex-preview--render-failure-report)
          (org-fast-latex-preview--reset-failure-report))))))

(defun org-fast-latex-preview--failure-groups (instances)
  "Group failure INSTANCES by stage and summary."
  (let ((table (make-hash-table :test 'equal))
        groups)
    (dolist (instance instances)
      (let* ((key (list (org-fast-latex-preview--failure-instance-stage instance)
                        (org-fast-latex-preview--failure-instance-summary instance)
                        (org-fast-latex-preview--failure-instance-internal instance)))
             (bucket (gethash key table)))
        (puthash key (cons instance bucket) table)))
    (maphash
     (lambda (key bucket)
       (push (list :stage (nth 0 key)
                   :summary (nth 1 key)
                   :internal (nth 2 key)
                   :count (length bucket)
                   :instances (nreverse bucket))
             groups))
     table)
    (sort groups
          (lambda (left right)
            (> (plist-get left :count)
               (plist-get right :count))))))

(defun org-fast-latex-preview--failure-buffer ()
  "Return the aggregated failure buffer for the current buffer."
  (let* ((report (org-fast-latex-preview--ensure-failure-report
                  org-fast-latex-preview--generation))
         (buffer (org-fast-latex-preview--failure-report-buffer report)))
    (unless (buffer-live-p buffer)
      (setq buffer
            (get-buffer-create
             (org-fast-latex-preview--failure-buffer-name (current-buffer))))
      (setf (org-fast-latex-preview--failure-report-buffer report) buffer))
    buffer))

(defun org-fast-latex-preview--render-failure-report ()
  "Refresh the aggregated failure report buffer for the current buffer."
  (when-let ((report org-fast-latex-preview--failure-report))
    (let* ((instances (org-fast-latex-preview--failure-report-instances report))
           (groups (org-fast-latex-preview--failure-groups instances))
           (display-groups
            (if org-fast-latex-preview-max-failure-groups
                (cl-subseq groups
                           0
                           (min (length groups)
                                org-fast-latex-preview-max-failure-groups))
              groups))
           (omitted-groups (- (length groups) (length display-groups)))
           (source-buffer (current-buffer))
           (source-name (buffer-name (current-buffer)))
           (buffer (org-fast-latex-preview--failure-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Org fast LaTeX preview failures for %s\n\n"
                          source-name))
          (insert (format "Generation: %d\n"
                          (org-fast-latex-preview--failure-report-generation
                           report)))
          (insert (format "Failed fragments: %d\n" (length instances)))
          (insert (format "Failure groups: %d\n\n" (length groups)))
          (when (> omitted-groups 0)
            (insert (format "Showing the %d most common groups; %d additional groups omitted.\n\n"
                            (length display-groups)
                            omitted-groups)))
          (cl-loop for group in display-groups
                   for index from 1
                   do (insert (format "%d. %s (%d fragment%s)\n"
                                      index
                                      (if (plist-get group :internal)
                                          (format "%s [internal]" (plist-get group :stage))
                                        (plist-get group :stage))
                                      (plist-get group :count)
                                      (if (= 1 (plist-get group :count)) "" "s")))
                   do (insert (format "   %s\n"
                                      (plist-get group :summary)))
                   do (cl-loop for instance in (cl-subseq
                                                (plist-get group :instances)
                                                0
                                                (min (length (plist-get group :instances))
                                                     org-fast-latex-preview-max-failure-samples))
                               for beg = (marker-position
                                          (org-fast-latex-preview--failure-instance-begin-marker
                                           instance))
                               for line = (and beg
                                               (buffer-live-p source-buffer)
                                               (with-current-buffer source-buffer
                                                 (when (<= beg (point-max))
                                                   (line-number-at-pos beg))))
                               do (insert (format "   - line %s: %s\n"
                                                  (or line "?")
                                                  (org-fast-latex-preview--failure-source-snippet
                                                   (org-fast-latex-preview--failure-instance-source
                                                    instance)))))
                   do (insert "\n"))
          (goto-char (point-min))
          (special-mode)))
      buffer)))

(defun org-fast-latex-preview--record-job-failure (job)
  "Add JOB to the aggregated failure report of its source buffer."
  (let ((buffer (org-fast-latex-preview--job-buffer job))
        (generation (org-fast-latex-preview--job-generation job))
        (summary (org-fast-latex-preview--job-log-summary job))
        (stage (or (org-fast-latex-preview--job-failure-stage job)
                   "preview"))
        (internal (org-fast-latex-preview--job-failure-internal job))
        (fragments (org-fast-latex-preview--job-fragments job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (= generation org-fast-latex-preview--generation)
          (let ((report (org-fast-latex-preview--ensure-failure-report generation)))
            (dolist (fragment fragments)
              (push (org-fast-latex-preview--make-failure-instance
                     :generation generation
                     :stage stage
                     :summary summary
                     :internal internal
                     :source (org-fast-latex-preview--fragment-source fragment)
                     :begin-marker (copy-marker
                                    (marker-position
                                     (org-fast-latex-preview--fragment-begin-marker fragment)))
                     :end-marker (copy-marker
                                  (marker-position
                                   (org-fast-latex-preview--fragment-end-marker fragment))
                                  t))
                    (org-fast-latex-preview--failure-report-instances report)))
            (setf (org-fast-latex-preview--failure-report-notified report) nil)))))))

(defun org-fast-latex-preview--notify-failure-report-if-needed ()
  "Emit a single aggregated failure notification when work has settled."
  (when (and org-fast-latex-preview--failure-report
             (null org-fast-latex-preview--jobs)
             (null org-fast-latex-preview--pending-batches)
             (not (org-fast-latex-preview--failure-report-notified
                   org-fast-latex-preview--failure-report)))
    (let* ((instances
            (org-fast-latex-preview--failure-report-instances
             org-fast-latex-preview--failure-report))
           (groups (org-fast-latex-preview--failure-groups instances))
           (internal-count
            (cl-count-if #'org-fast-latex-preview--failure-instance-internal
                         instances)))
      (when instances
        (setf (org-fast-latex-preview--failure-report-notified
               org-fast-latex-preview--failure-report)
              t)
        (let ((buffer (org-fast-latex-preview--render-failure-report)))
          (if (> internal-count 0)
              (message
               "Org fast LaTeX preview skipped %d fragment(s) in %d error group(s), including %d internal error%s.  See %s"
               (length instances)
               (length groups)
               internal-count
               (if (= internal-count 1) "" "s")
               (buffer-name buffer))
            (message
             "Org fast LaTeX preview skipped %d fragment(s) in %d error group(s).  See %s"
             (length instances)
             (length groups)
             (buffer-name buffer))))))))

(defun org-fast-latex-preview--cleanup-job-files (job)
  "Delete temporary files for JOB."
  (let ((directory (org-fast-latex-preview--job-temp-directory job)))
    (when (and directory (file-directory-p directory))
      (ignore-errors
        (delete-directory directory t)))))

(defun org-fast-latex-preview--remove-job (job)
  "Remove JOB from its source buffer's active job list."
  (let ((buffer (org-fast-latex-preview--job-buffer job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq org-fast-latex-preview--jobs
              (delq job org-fast-latex-preview--jobs))
        (org-fast-latex-preview--dispatch-pending-batches)))))

(defun org-fast-latex-preview--job-live-p (job)
  "Return non-nil when JOB still has a live subprocess."
  (or (process-live-p (org-fast-latex-preview--job-latex-process job))
      (process-live-p (org-fast-latex-preview--job-image-process job))))

(defun org-fast-latex-preview--handle-internal-job-error (job stage err)
  "Abort JOB after an internal ERR at STAGE."
  (let ((details (error-message-string err)))
    (setf (org-fast-latex-preview--job-canceled job) t)
    (setf (org-fast-latex-preview--job-failure-stage job) stage)
    (setf (org-fast-latex-preview--job-failure-summary job) details)
    (setf (org-fast-latex-preview--job-failure-internal job) t)
    (dolist (process (list (org-fast-latex-preview--job-latex-process job)
                           (org-fast-latex-preview--job-image-process job)))
      (when (process-live-p process)
        (delete-process process)))
    (org-fast-latex-preview--remove-job job)
    (org-fast-latex-preview--record-job-failure job)
    (org-fast-latex-preview--dispose-failure-log-buffer
     (org-fast-latex-preview--job-log-buffer job))
    (org-fast-latex-preview--cleanup-job-files job)
    (org-fast-latex-preview--log "internal job error at %s: %s" stage details)
    (when-let ((buffer (org-fast-latex-preview--job-buffer job)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (org-fast-latex-preview--notify-failure-report-if-needed)
          (org-fast-latex-preview--finish-profile-if-settled))))))

(defun org-fast-latex-preview--job-buffer-current-p (job)
  "Return non-nil when JOB still targets the current buffer generation."
  (and (buffer-live-p (org-fast-latex-preview--job-buffer job))
       (with-current-buffer (org-fast-latex-preview--job-buffer job)
         (= (org-fast-latex-preview--job-generation job)
            org-fast-latex-preview--generation))))

(defun org-fast-latex-preview--commit-output-file (job fragment output-file)
  "Move OUTPUT-FILE from JOB into cache for FRAGMENT and place its overlay."
  (let ((cache-file (org-fast-latex-preview--fragment-cache-file fragment)))
    (when (file-exists-p output-file)
      (if (org-fast-latex-preview--cache-file-valid-p cache-file)
          (delete-file output-file)
        (rename-file output-file cache-file t)))
    (when (and (org-fast-latex-preview--job-buffer-current-p job)
               (org-fast-latex-preview--usable-cache-file-p cache-file))
      (with-current-buffer (org-fast-latex-preview--job-buffer job)
        (let ((profile (org-fast-latex-preview--current-profile
                        (org-fast-latex-preview--job-generation job))))
          (org-fast-latex-preview--with-timing profile async_overlay
            (org-fast-latex-preview--place-overlay
             fragment
             cache-file
             (and (org-fast-latex-preview--job-plan job)
                  (org-fast-latex-preview--plan-replace-existing-overlays
                   (org-fast-latex-preview--job-plan job)))))
          (org-fast-latex-preview--profile-inc profile 'async_overlay_count))))))

(defun org-fast-latex-preview--remaining-output-files (job)
  "Return uncommitted output files for JOB."
  (let* ((directory (org-fast-latex-preview--job-temp-directory job))
         (files (when (file-directory-p directory)
                  (directory-files directory t "^page-[0-9]+\\.svg$"))))
    (sort files #'string<)))

(defun org-fast-latex-preview--job-fragment-at (job index)
  "Return fragment INDEX from JOB, or nil."
  (nth index (org-fast-latex-preview--job-fragments job)))

(defun org-fast-latex-preview--handle-image-process-output (job chunk)
  "Handle dvisvgm process CHUNK for JOB."
  (when (and chunk (not (string-empty-p chunk)))
    (org-fast-latex-preview--log "dvisvgm[%s]: %s"
                                 (buffer-name
                                  (org-fast-latex-preview--job-buffer job))
                                 (string-trim-right chunk))
    (let* ((pending (concat (or (org-fast-latex-preview--job-image-output-remainder job)
                                "")
                            chunk))
           (lines (split-string pending "\n"))
           (complete-lines (if (string-suffix-p "\n" pending)
                               lines
                             (butlast lines)))
           (remainder (if (string-suffix-p "\n" pending)
                          ""
                        (car (last lines)))))
      (setf (org-fast-latex-preview--job-image-output-remainder job) remainder)
      (dolist (line complete-lines)
        (when (string-match "output written to \\(.*\\.svg\\)$" line)
          (let* ((index (org-fast-latex-preview--job-placed-count job))
                 (fragment (org-fast-latex-preview--job-fragment-at job index))
                 (output-file (match-string 1 line)))
            (when fragment
              (cl-incf (org-fast-latex-preview--job-placed-count job))
              (org-fast-latex-preview--commit-output-file
               job fragment output-file))))))))

(defun org-fast-latex-preview--report-job-failure (job stage)
  "Mark JOB as having failed at STAGE."
  (setf (org-fast-latex-preview--job-failure-stage job) stage)
  (setf (org-fast-latex-preview--job-failure-internal job) nil)
  (org-fast-latex-preview--log "job failure at %s for buffer %s"
                               stage
                               (if (buffer-live-p
                                    (org-fast-latex-preview--job-buffer job))
                                   (buffer-name
                                    (org-fast-latex-preview--job-buffer job))
                                 "<dead buffer>")))

(defun org-fast-latex-preview--start-image-process (job on-success on-failure)
  "Start dvisvgm for JOB.

ON-SUCCESS is called with JOB when conversion completes.
ON-FAILURE is called with JOB when conversion fails."
  (let* ((buffer (org-fast-latex-preview--job-log-buffer job))
         (command (org-fast-latex-preview--dvisvgm-command job))
         (process
          (make-process
           :name "org-fast-latex-preview-dvisvgm"
           :buffer buffer
           :command command
           :coding 'utf-8-unix
           :connection-type 'pipe
           :filter (lambda (_process chunk)
                     (condition-case err
                         (org-fast-latex-preview--handle-image-process-output
                          job chunk)
                       (error
                        (org-fast-latex-preview--handle-internal-job-error
                         job "dvisvgm filter" err))))
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unwind-protect
                   (unless (org-fast-latex-preview--job-canceled job)
                     (when-let ((source-buffer
                                 (org-fast-latex-preview--job-buffer job)))
                       (when (buffer-live-p source-buffer)
                         (with-current-buffer source-buffer
                           (when-let ((profile
                                       (org-fast-latex-preview--current-profile
                                        (org-fast-latex-preview--job-generation job))))
                             (org-fast-latex-preview--profile-add-time
                              profile
                              'image
                              (- (float-time)
                                 (or (org-fast-latex-preview--job-image-start-time job)
                                     (float-time))))))))
                     (condition-case err
                         (if (and (eq (process-status proc) 'exit)
                                  (zerop (process-exit-status proc)))
                             (progn
                               (dolist (file (org-fast-latex-preview--remaining-output-files
                                              job))
                                 (let ((fragment
                                        (org-fast-latex-preview--job-fragment-at
                                         job
                                         (org-fast-latex-preview--job-placed-count
                                          job))))
                                   (when fragment
                                     (cl-incf (org-fast-latex-preview--job-placed-count
                                               job))
                                     (org-fast-latex-preview--commit-output-file
                                      job fragment file))))
                               (funcall on-success job))
                           (org-fast-latex-preview--report-job-failure job "dvisvgm")
                           (funcall on-failure job))
                       (error
                        (org-fast-latex-preview--handle-internal-job-error
                         job "dvisvgm sentinel" err))))
                 (set-process-query-on-exit-flag proc nil)))))))
    (setf (org-fast-latex-preview--job-image-process job) process)
    (setf (org-fast-latex-preview--job-image-start-time job) (float-time))
    (set-process-query-on-exit-flag process nil)
    (org-fast-latex-preview--log "started dvisvgm: %S" command)
    process))

(defun org-fast-latex-preview--start-latex-process (job on-success on-failure)
  "Start LaTeX compilation for JOB.

ON-SUCCESS is called with JOB when LaTeX succeeds.
ON-FAILURE is called with JOB when LaTeX fails."
  (let* ((buffer (org-fast-latex-preview--job-log-buffer job))
         (command (org-fast-latex-preview--latex-command job))
         (process
          (make-process
           :name "org-fast-latex-preview-latex"
           :buffer buffer
           :command command
           :coding 'utf-8-unix
           :connection-type 'pipe
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unless (org-fast-latex-preview--job-canceled job)
                 (when-let ((source-buffer
                             (org-fast-latex-preview--job-buffer job)))
                   (when (buffer-live-p source-buffer)
                     (with-current-buffer source-buffer
                       (when-let ((profile
                                   (org-fast-latex-preview--current-profile
                                    (org-fast-latex-preview--job-generation job))))
                         (org-fast-latex-preview--profile-add-time
                          profile
                          'latex
                          (- (float-time)
                             (or (org-fast-latex-preview--job-latex-start-time job)
                                 (float-time))))))))
                 (condition-case err
                     (if (and (eq (process-status proc) 'exit)
                              (zerop (process-exit-status proc))
                              (file-exists-p (org-fast-latex-preview--job-input-file
                                              job)))
                         (funcall on-success job)
                       (org-fast-latex-preview--report-job-failure job "LaTeX")
                       (funcall on-failure job))
                   (error
                    (org-fast-latex-preview--handle-internal-job-error
                     job "LaTeX sentinel" err))))
               (set-process-query-on-exit-flag proc nil))))))
    (setf (org-fast-latex-preview--job-latex-process job) process)
    (setf (org-fast-latex-preview--job-latex-start-time job) (float-time))
    (set-process-query-on-exit-flag process nil)
    (org-fast-latex-preview--log "started latex: %S" command)
    process))

(defun org-fast-latex-preview--cancel-job (job)
  "Cancel JOB and clean up its resources."
  (setf (org-fast-latex-preview--job-canceled job) t)
  (dolist (process (list (org-fast-latex-preview--job-latex-process job)
                         (org-fast-latex-preview--job-image-process job)))
    (when (process-live-p process)
      (delete-process process)))
  (org-fast-latex-preview--keep-or-discard-job-buffer
   (org-fast-latex-preview--job-log-buffer job))
  (org-fast-latex-preview--cleanup-job-files job))

(defun org-fast-latex-preview--cancel-jobs ()
  "Cancel all active jobs for the current buffer."
  (dolist (job (copy-sequence org-fast-latex-preview--jobs))
    (org-fast-latex-preview--cancel-job job))
  (setq org-fast-latex-preview--jobs nil
        org-fast-latex-preview--pending-batches nil))

(defun org-fast-latex-preview--partition-fragments (fragments &optional batch-size)
  "Partition FRAGMENTS according to BATCH-SIZE.

When BATCH-SIZE is omitted or equal to `use-default', use
`org-fast-latex-preview-batch-size'.  When BATCH-SIZE is
`:unlimited', keep FRAGMENTS in a single batch regardless of size."
  (let ((batch-size (cond
                     ((or (null batch-size)
                          (eq batch-size 'use-default))
                      org-fast-latex-preview-batch-size)
                     ((eq batch-size :unlimited) nil)
                     (t batch-size))))
    (if (or (null batch-size) (<= (length fragments) batch-size))
        (list fragments)
      (let (batches)
        (while fragments
          (push (cl-subseq fragments 0 (min batch-size (length fragments)))
                batches)
          (setq fragments (nthcdr (min batch-size (length fragments))
                                  fragments)))
        (nreverse batches)))))

(defun org-fast-latex-preview--plan-can-start-job-p (plan)
  "Return non-nil when PLAN may start another batch immediately."
  (let ((limit (if plan
                   (org-fast-latex-preview--plan-max-concurrent-jobs plan)
                 org-fast-latex-preview-max-concurrent-jobs)))
    (or (null limit)
        (< (length org-fast-latex-preview--jobs) limit))))

(defun org-fast-latex-preview--dispatch-pending-batches ()
  "Start queued batches until the concurrency limit is reached."
  (while (and org-fast-latex-preview--pending-batches
              (pcase-let ((`(,_fragments ,_context ,_generation ,plan)
                           (car org-fast-latex-preview--pending-batches)))
                (org-fast-latex-preview--plan-can-start-job-p plan)))
    (pcase-let ((`(,fragments ,context ,generation ,plan)
                 (pop org-fast-latex-preview--pending-batches)))
      (org-fast-latex-preview--start-batch
       fragments context generation plan))))

(defun org-fast-latex-preview--enqueue-batch
    (fragments context generation &optional plan)
  "Queue FRAGMENTS for rendering with CONTEXT and GENERATION.

PLAN is the active scheduler plan when non-nil."
  (mapc #'org-fast-latex-preview--ensure-fragment-markers fragments)
  (if (org-fast-latex-preview--plan-can-start-job-p plan)
      (org-fast-latex-preview--start-batch
       fragments context generation plan)
    (setq org-fast-latex-preview--pending-batches
          (nconc org-fast-latex-preview--pending-batches
                 (list (list fragments
                             context
                             generation
                             plan))))))

(defun org-fast-latex-preview--start-batch
    (fragments context generation &optional plan)
  "Start rendering FRAGMENTS under CONTEXT for GENERATION.

PLAN is the active scheduler plan when non-nil.

Return the created job."
  (let* ((profile (org-fast-latex-preview--current-profile generation))
         (temp-directory nil)
         (log-buffer nil)
         (job nil))
    (org-fast-latex-preview--profile-inc profile 'batches_started)
    (setq job
          (org-fast-latex-preview--with-timing profile batch_prep
            (setq temp-directory (make-temp-file "org-fast-latex-preview-" t)
                  log-buffer (org-fast-latex-preview--make-job-buffer))
            (setq job (org-fast-latex-preview--make-job
                       :buffer (current-buffer)
                       :generation generation
                       :fragments fragments
                       :plan plan
                       :context context
                       :temp-directory temp-directory
                       :log-buffer log-buffer
                       :placed-count 0
                       :image-output-remainder ""))
            (setf (org-fast-latex-preview--job-tex-file job)
                  (org-fast-latex-preview--write-batch-file job))
            (setf (org-fast-latex-preview--job-input-file job)
                  (expand-file-name
                   (format "preview-batch.%s"
                           (org-fast-latex-preview--context-input-extension context))
                   temp-directory))
            job))
    (push job org-fast-latex-preview--jobs)
    (org-fast-latex-preview--start-latex-process
     job
     (lambda (active-job)
       (org-fast-latex-preview--start-image-process
        active-job
        (lambda (finished-job)
          (org-fast-latex-preview--remove-job finished-job)
          (org-fast-latex-preview--keep-or-discard-job-buffer
           (org-fast-latex-preview--job-log-buffer finished-job))
          (org-fast-latex-preview--cleanup-job-files finished-job)
          (org-fast-latex-preview--log
           "finished batch for %s (%d fragments)"
           (if (buffer-live-p (org-fast-latex-preview--job-buffer finished-job))
               (buffer-name (org-fast-latex-preview--job-buffer finished-job))
             "<dead buffer>")
           (length (org-fast-latex-preview--job-fragments finished-job)))
          (when (buffer-live-p (org-fast-latex-preview--job-buffer finished-job))
            (with-current-buffer (org-fast-latex-preview--job-buffer finished-job)
              (org-fast-latex-preview--notify-failure-report-if-needed)
              (org-fast-latex-preview--finish-profile-if-settled))))
        (lambda (failed-job)
          (org-fast-latex-preview--remove-job failed-job)
          (org-fast-latex-preview--handle-batch-failure failed-job))))
     (lambda (failed-job)
       (org-fast-latex-preview--remove-job failed-job)
       (org-fast-latex-preview--handle-batch-failure failed-job)))
    job))

(defun org-fast-latex-preview--job-unplaced-fragments (job)
  "Return the fragments from JOB that still need rendering."
  (nthcdr (min (org-fast-latex-preview--job-placed-count job)
               (length (org-fast-latex-preview--job-fragments job)))
          (org-fast-latex-preview--job-fragments job)))

(defun org-fast-latex-preview--drain-pending-batches (generation)
  "Remove pending batches for GENERATION and return their fragments."
  (let (fragments kept)
    (dolist (entry org-fast-latex-preview--pending-batches)
      (pcase-let ((`(,batch-fragments ,_context ,entry-generation ,_plan) entry))
        (if (= generation entry-generation)
            (setq fragments (nconc fragments batch-fragments))
          (push entry kept))))
    (setq org-fast-latex-preview--pending-batches (nreverse kept))
    fragments))

(defun org-fast-latex-preview--cancel-generation-jobs (generation)
  "Cancel live jobs for GENERATION and return their unresolved fragments."
  (let (fragments)
    (dolist (other (copy-sequence org-fast-latex-preview--jobs))
      (when (= generation (org-fast-latex-preview--job-generation other))
        (setq fragments
              (nconc fragments (org-fast-latex-preview--job-unplaced-fragments other)))
        (org-fast-latex-preview--cancel-job other)
        (setq org-fast-latex-preview--jobs
              (delq other org-fast-latex-preview--jobs))))
    fragments))

(defun org-fast-latex-preview--fallback-to-resilient-plan (job)
  "Reschedule JOB's unresolved work under the resilient plan.

Return non-nil when a fallback was triggered."
  (let ((buffer (org-fast-latex-preview--job-buffer job))
        (generation (org-fast-latex-preview--job-generation job))
        (plan (org-fast-latex-preview--job-plan job))
        (context (org-fast-latex-preview--job-context job)))
    (when (and plan
               (eq 'throughput (org-fast-latex-preview--plan-mode plan))
               (not (org-fast-latex-preview--plan-fallback-triggered plan))
               (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (= generation org-fast-latex-preview--generation)
          (setf (org-fast-latex-preview--plan-mode plan) 'resilient
                (org-fast-latex-preview--plan-batch-size plan)
                org-fast-latex-preview-batch-size
                (org-fast-latex-preview--plan-max-concurrent-jobs plan)
                org-fast-latex-preview-max-concurrent-jobs
                (org-fast-latex-preview--plan-replace-existing-overlays plan) t
                (org-fast-latex-preview--plan-fallback-triggered plan) t)
          (let ((remaining
                 (nconc (org-fast-latex-preview--job-unplaced-fragments job)
                        (org-fast-latex-preview--drain-pending-batches generation)
                        (org-fast-latex-preview--cancel-generation-jobs generation))))
            (org-fast-latex-preview--log
             "falling back to resilient plan in %s with %d remaining fragments"
             (buffer-name)
             (length remaining))
            (dolist (batch (org-fast-latex-preview--partition-fragments
                            remaining
                            (or (org-fast-latex-preview--plan-batch-size plan)
                                :unlimited)))
              (org-fast-latex-preview--enqueue-batch batch context generation plan))
            t))))))

(defun org-fast-latex-preview--promote-context (job)
  "Promote JOB's generation to the next resolved render context.

Return non-nil when the generation was requeued under a richer context."
  (let ((buffer (org-fast-latex-preview--job-buffer job))
        (generation (org-fast-latex-preview--job-generation job))
        (plan (org-fast-latex-preview--job-plan job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (= generation org-fast-latex-preview--generation)
          (when-let* ((next-index (1+ org-fast-latex-preview--context-chain-index))
                      (next-context (nth next-index org-fast-latex-preview--context-chain))
                      (range org-fast-latex-preview--generation-range)
                      (beg (car range))
                      (end (cdr range)))
            (setq org-fast-latex-preview--context-chain-index next-index)
            (when plan
              (setf (org-fast-latex-preview--plan-replace-existing-overlays plan) t))
            (org-fast-latex-preview--log
             "promoting render context in %s from %s to %s"
             (buffer-name)
             (or (org-fast-latex-preview--context-label
                  (org-fast-latex-preview--job-context job))
                 "<unknown>")
             (or (org-fast-latex-preview--context-label next-context)
                 "<unknown>"))
            (org-fast-latex-preview--drain-pending-batches generation)
            (org-fast-latex-preview--cancel-generation-jobs generation)
            (org-fast-latex-preview-clear beg end)
            (org-fast-latex-preview--reset-failure-report)
            (let* ((profile (org-fast-latex-preview--current-profile generation))
                   (fragments
                    (org-fast-latex-preview--with-timing profile collect
                      (org-fast-latex-preview--collect-fragments
                       beg end next-context))))
              (org-fast-latex-preview--profile-inc profile 'context_promotions)
              (org-fast-latex-preview--preview-fragments
               fragments next-context nil profile plan)
              t)))))))

(defun org-fast-latex-preview--handle-batch-failure (job)
  "Handle a failed JOB."
  (let ((fragments (org-fast-latex-preview--job-fragments job))
        (buffer (org-fast-latex-preview--job-buffer job))
        (generation (org-fast-latex-preview--job-generation job))
        (context (org-fast-latex-preview--job-context job))
        rescheduled)
    (when (org-fast-latex-preview--promote-context job)
      (setq rescheduled t))
    (when (org-fast-latex-preview--fallback-to-resilient-plan job)
      (setq rescheduled t))
    (when (and (not rescheduled)
               (eq org-fast-latex-preview-failure-strategy 'split)
               (> (length fragments) 1)
               (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (= generation org-fast-latex-preview--generation)
          (let* ((mid (/ (length fragments) 2))
                 (left (cl-subseq fragments 0 mid))
                 (right (nthcdr mid fragments)))
            (org-fast-latex-preview--log
             "splitting failed batch in %s into %d and %d fragments"
             (buffer-name)
             (length left)
             (length right))
            (setq rescheduled t)
            (when left
              (org-fast-latex-preview--enqueue-batch
               left context generation (org-fast-latex-preview--job-plan job)))
            (when right
              (org-fast-latex-preview--enqueue-batch
               right context generation (org-fast-latex-preview--job-plan job)))))))
    (if rescheduled
        (org-fast-latex-preview--dispose-failure-log-buffer
         (org-fast-latex-preview--job-log-buffer job))
      (progn
        (org-fast-latex-preview--record-job-failure job)
        (org-fast-latex-preview--dispose-failure-log-buffer
         (org-fast-latex-preview--job-log-buffer job))))
    (org-fast-latex-preview--cleanup-job-files job)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (org-fast-latex-preview--notify-failure-report-if-needed)
        (org-fast-latex-preview--finish-profile-if-settled)))))

(defun org-fast-latex-preview--preview-fragments
    (fragments context refresh &optional profile plan)
  "Preview FRAGMENTS in the current buffer.

When REFRESH is non-nil, clear overlapping previews before reusing
cached images.  CONTEXT selects the active render context.  PROFILE and
PLAN track profiling and scheduler state when non-nil."
  (let ((generation org-fast-latex-preview--generation)
        cached
        uncached
        batches)
    (org-fast-latex-preview--with-timing profile classify
      (dolist (fragment fragments)
        (when refresh
          (org-fast-latex-preview--clear-fragment-overlays fragment))
        (cond
         ((org-fast-latex-preview--existing-overlay-valid-p fragment)
          (org-fast-latex-preview--profile-inc profile 'overlay_reuse_count))
         ((org-fast-latex-preview--usable-cache-file-p
           (org-fast-latex-preview--fragment-cache-file fragment))
          (push fragment cached))
         (t
          (push fragment uncached)))))
    (setq cached (nreverse cached))
    (org-fast-latex-preview--profile-inc profile 'cached_fragments (length cached))
    (org-fast-latex-preview--profile-inc profile 'queued_fragments (length uncached))
    (org-fast-latex-preview--with-timing profile cached_overlay
      (dolist (fragment cached)
        (org-fast-latex-preview--place-overlay
         fragment
         (org-fast-latex-preview--fragment-cache-file fragment)
         (and plan
              (org-fast-latex-preview--plan-replace-existing-overlays plan)))))
    (setq uncached (nreverse uncached))
    (when uncached
      (setq batches
            (org-fast-latex-preview--partition-fragments
             uncached
             (if plan
                 (or (org-fast-latex-preview--plan-batch-size plan)
                     :unlimited)
               'use-default)))
      (org-fast-latex-preview--profile-inc
       profile 'batches_queued
      (length batches))
      (dolist (batch batches)
        (org-fast-latex-preview--enqueue-batch
         batch context generation plan)))
    (list :cached (length cached)
          :queued (length uncached))))

(defun org-fast-latex-preview--render-range (beg end &optional refresh)
  "Render LaTeX previews between BEG and END.

When REFRESH is non-nil, clear existing OFLP overlays in the range first."
  (when (fboundp 'org-fast-latex-preview--ensure-lifecycle-hooks)
    (org-fast-latex-preview--ensure-lifecycle-hooks))
  (when refresh
    (org-fast-latex-preview-clear beg end))
  (cl-incf org-fast-latex-preview--generation)
  (org-fast-latex-preview--cancel-jobs)
  (org-fast-latex-preview--reset-failure-report)
  (org-fast-latex-preview--start-profile org-fast-latex-preview--generation)
  (let* ((profile (org-fast-latex-preview--current-profile
                   org-fast-latex-preview--generation))
         (context-chain (org-fast-latex-preview--with-timing profile build_context
                          (org-fast-latex-preview--resolve-context-chain)))
         (context (car context-chain)))
    (setq org-fast-latex-preview--context-chain context-chain
          org-fast-latex-preview--context-chain-index 0
          org-fast-latex-preview--generation-range (cons beg end))
    (let* (
         (fragments (org-fast-latex-preview--with-timing profile collect
                      (org-fast-latex-preview--collect-fragments beg end context)))
         (plan (org-fast-latex-preview--plan-for-render
                org-fast-latex-preview--generation
                (length fragments)
                (> org-fast-latex-preview--overlay-count 0)))
         (result (org-fast-latex-preview--preview-fragments
                  fragments context refresh profile plan)))
      (org-fast-latex-preview--profile-inc
       profile
       (if (eq 'throughput (org-fast-latex-preview--plan-mode plan))
           'throughput_plan
         'resilient_plan))
      (org-fast-latex-preview--profile-inc profile 'fragments_total (length fragments))
      (org-fast-latex-preview--log
       "render request for %s via %s: %d fragments (%d cached, %d queued)"
       (buffer-name)
       (or (org-fast-latex-preview--context-label context) "<unknown>")
       (length fragments)
       (plist-get result :cached)
       (plist-get result :queued))
      (org-fast-latex-preview--finish-profile-if-settled)
      result)))

(defun org-fast-latex-preview--refresh-dirty-range (beg end)
  "Refresh previews between BEG and END without canceling unrelated jobs."
  (org-fast-latex-preview--remove-failure-instances-in-range beg end)
  (org-fast-latex-preview-clear beg end)
  (let* ((context (org-fast-latex-preview--build-context))
         (fragments (org-fast-latex-preview--collect-fragments beg end context))
         (plan (org-fast-latex-preview--plan-for-render
                org-fast-latex-preview--generation
                (length fragments)
                t
                t))
         (result (org-fast-latex-preview--preview-fragments
                  fragments context nil nil plan)))
    (org-fast-latex-preview--log
     "dirty refresh for %s: %d fragments (%d cached, %d queued)"
     (buffer-name)
     (length fragments)
     (plist-get result :cached)
     (plist-get result :queued))
    result))

(provide 'org-fast-latex-preview-render)
;;; org-fast-latex-preview-render.el ends here
