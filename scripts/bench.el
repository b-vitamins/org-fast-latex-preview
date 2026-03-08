;;; bench.el --- Stress benchmark harness for org-fast-latex-preview -*- lexical-binding: t; -*-

;;; Code:

(setq load-prefer-newer t)

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-fast-latex-preview)

(defconst oflp-bench-progress-timeout 120.0
  "Seconds a live preview job may go without visible progress before failing.")

(defun oflp-bench--usage ()
  "Signal CLI usage."
  (error
   "Usage: emacs -Q --batch -L lisp --script scripts/bench.el -- --manifest PATH --results-dir PATH [--profile NAME] [--compiler NAME] [--chaos] [--soak-cycles N]"))

(defun oflp-bench--parse-args ()
  "Parse command-line arguments for the stress harness."
  (let ((args command-line-args-left)
        manifest
        results-dir
        compiler
        chaos
        soak-cycles
        profiles)
    (while args
      (pcase (pop args)
        ("--"
         nil)
        ("--manifest"
         (setq manifest (pop args)))
        ("--results-dir"
         (setq results-dir (pop args)))
        ("--profile"
         (push (pop args) profiles))
        ("--compiler"
         (setq compiler (pop args)))
        ("--chaos"
         (setq chaos t))
        ("--soak-cycles"
         (setq soak-cycles (string-to-number (pop args))))
        ("--help"
         (oflp-bench--usage))
        (other
         (error "Unknown bench argument %S" other))))
    (unless (and manifest results-dir)
      (oflp-bench--usage))
    (list :manifest manifest
          :results-dir results-dir
          :profiles (nreverse profiles)
          :compiler (or compiler "latex")
          :chaos chaos
          :soak-cycles (or soak-cycles 0))))

(defun oflp-bench--read-json-file (path)
  "Read JSON from PATH into hash tables and lists."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-buffer :object-type 'hash-table :array-type 'list)))

(defun oflp-bench--write-json-file (path data)
  "Write DATA as JSON to PATH."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (let ((json-encoding-pretty-print t))
      (insert (json-encode data)))))

(defun oflp-bench--json-string (data)
  "Return DATA encoded as JSON."
  (let ((json-encoding-pretty-print nil))
    (json-encode data)))

(defun oflp-bench--ensure-directory (directory)
  "Ensure DIRECTORY exists and return it."
  (unless (file-directory-p directory)
    (make-directory directory t))
  directory)

(defun oflp-bench--buffer-fragments ()
  "Return all LaTeX fragments in the current buffer."
  (let ((context (org-fast-latex-preview--build-context)))
    (org-fast-latex-preview--collect-fragments (point-min) (point-max) context)))

(defun oflp-bench--preview-overlays ()
  "Return preview overlays in the current buffer."
  (cl-remove-if-not #'org-fast-latex-preview--overlay-p
                    (overlays-in (point-min) (point-max))))

(defun oflp-bench--overlay-count ()
  "Return the number of preview overlays in the current buffer."
  (length (oflp-bench--preview-overlays)))

(defun oflp-bench--job-snapshot ()
  "Return a debugging snapshot of active preview jobs."
  (mapcar
   (lambda (job)
     `(("fragments" . ,(length (org-fast-latex-preview--job-fragments job)))
       ("placed" . ,(org-fast-latex-preview--job-placed-count job))
       ("canceled" . ,(if (org-fast-latex-preview--job-canceled job)
                          t
                        :json-false))
       ("latex_status" . ,(let ((proc (org-fast-latex-preview--job-latex-process job)))
                            (when proc
                              (symbol-name (process-status proc)))))
       ("image_status" . ,(let ((proc (org-fast-latex-preview--job-image-process job)))
                            (when proc
                              (symbol-name (process-status proc)))))
       ("temp_directory" . ,(org-fast-latex-preview--job-temp-directory job))))
   org-fast-latex-preview--jobs))

(defun oflp-bench--wait-for-jobs (&optional timeout)
  "Wait for active jobs to finish within TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 600.0)))
        (last-snapshot nil)
        (last-change (float-time)))
    (while (and org-fast-latex-preview--jobs
                (< (float-time) deadline))
      (let ((snapshot (oflp-bench--job-snapshot)))
        (if (equal snapshot last-snapshot)
            (when (> (- (float-time) last-change)
                     oflp-bench-progress-timeout)
              (error "Preview jobs stopped making progress: %s"
                     (oflp-bench--json-string snapshot)))
          (setq last-snapshot snapshot
                last-change (float-time))))
      (unless (cl-some #'org-fast-latex-preview--job-live-p
                       org-fast-latex-preview--jobs)
        (error "Preview jobs became inert: %s"
               (oflp-bench--json-string
                (oflp-bench--job-snapshot))))
      (accept-process-output nil 0.1))
    (when org-fast-latex-preview--jobs
      (error "Timed out waiting for preview jobs"))))

(defun oflp-bench--wait-for-idle (&optional timeout)
  "Wait for jobs and pending dirty timer activity within TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 600.0)))
        (last-snapshot nil)
        (last-change (float-time)))
    (while (and (< (float-time) deadline)
                (or org-fast-latex-preview--jobs
                    org-fast-latex-preview--dirty-timer))
      (when org-fast-latex-preview--jobs
        (let ((snapshot (oflp-bench--job-snapshot)))
          (if (equal snapshot last-snapshot)
              (when (> (- (float-time) last-change)
                       oflp-bench-progress-timeout)
                (error "Preview jobs stopped making progress while idle wait was active: %s"
                       (oflp-bench--json-string snapshot)))
            (setq last-snapshot snapshot
                  last-change (float-time)))))
      (when (and org-fast-latex-preview--jobs
                 (not (cl-some #'org-fast-latex-preview--job-live-p
                               org-fast-latex-preview--jobs)))
        (error "Preview jobs became inert while idle wait was active: %s"
               (oflp-bench--json-string
                (oflp-bench--job-snapshot))))
      (accept-process-output nil 0.1))
    (when org-fast-latex-preview--jobs
      (error "Timed out waiting for preview jobs to settle"))
    (when org-fast-latex-preview--dirty-timer
      (error "Timed out waiting for dirty refresh timer"))))

(defun oflp-bench--wait-for (predicate description &optional timeout)
  "Wait until PREDICATE returns non-nil or signal an error for DESCRIPTION."
  (let ((deadline (+ (float-time) (or timeout 30.0)))
        value)
    (while (and (< (float-time) deadline)
                (not (setq value (funcall predicate))))
      (accept-process-output nil 0.05))
    (unless value
      (error "Timed out waiting for %s" description))
    value))

(defun oflp-bench--wait-for-job (predicate description &optional timeout)
  "Return the first live job satisfying PREDICATE for DESCRIPTION."
  (oflp-bench--wait-for
   (lambda ()
     (cl-find-if predicate org-fast-latex-preview--jobs))
   description
   timeout))

(defun oflp-bench--measure-seconds (thunk)
  "Measure wall-clock seconds needed to run THUNK."
  (let ((start (float-time)))
    (funcall thunk)
    (- (float-time) start)))

(defun oflp-bench--cache-files (directory)
  "Return cache files below DIRECTORY."
  (if (file-directory-p directory)
      (directory-files directory t "\\.svg\\'")
    nil))

(defun oflp-bench--cache-bytes (directory)
  "Return total size in bytes of cache files in DIRECTORY."
  (cl-loop for file in (oflp-bench--cache-files directory)
           sum (file-attribute-size (file-attributes file))))

(defun oflp-bench--memory-snapshot ()
  "Return a simple memory snapshot."
  (garbage-collect)
  (if (fboundp 'memory-use-counts)
      (let ((counts (memory-use-counts)))
        `(("strings" . ,(nth 0 counts))
          ("conses" . ,(nth 1 counts))
          ("symbols" . ,(nth 2 counts))
          ("misc" . ,(nth 3 counts))
          ("intervals" . ,(nth 4 counts))
          ("buffers" . ,(nth 5 counts))))
    nil))

(defun oflp-bench--job-buffer-count ()
  "Return the number of live hidden job buffers."
  (cl-count-if
   (lambda (buffer)
     (string-match-p "^ \\*org-fast-latex-preview-job" (buffer-name buffer)))
   (buffer-list)))

(defun oflp-bench--failure-buffers ()
  "Return aggregated preview failure report buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (string-match-p "\\*org-fast-latex-preview-failure\\*" (buffer-name buffer)))
   (buffer-list)))

(defun oflp-bench--cleanup-failure-buffers ()
  "Kill aggregated preview failure report buffers."
  (mapc #'kill-buffer (oflp-bench--failure-buffers)))

(defun oflp-bench--clear-failure-state ()
  "Reset buffer-local and visible failure state."
  (org-fast-latex-preview--reset-failure-report)
  (oflp-bench--cleanup-failure-buffers))

(defun oflp-bench--assert (predicate format-string &rest args)
  "Signal an error with FORMAT-STRING and ARGS unless PREDICATE is non-nil."
  (unless predicate
    (error (apply #'format format-string args))))

(defun oflp-bench--assert-clean-runtime (name &optional allow-failure-buffers)
  "Assert that the current buffer has no leaked OFLP runtime state.

NAME is used in assertion messages.  When ALLOW-FAILURE-BUFFERS is non-nil,
visible aggregated failure reports are ignored."
  (oflp-bench--assert (null org-fast-latex-preview--jobs)
                      "%s leaked preview jobs" name)
  (oflp-bench--assert (zerop (oflp-bench--job-buffer-count))
                      "%s leaked hidden job buffers" name)
  (oflp-bench--assert (null org-fast-latex-preview--dirty-timer)
                      "%s leaked dirty timer" name)
  (unless allow-failure-buffers
    (oflp-bench--assert (zerop (length (oflp-bench--failure-buffers)))
                        "%s unexpectedly left failure buffers behind" name)))

(defun oflp-bench--subtree-range ()
  "Return the range of the first subtree in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward org-outline-regexp-bol nil t)
      (error "No subtree found in stress corpus"))
    (org-back-to-heading t)
    (cons (point) (org-entry-end-position))))

(defun oflp-bench--sample-overlay-toggle ()
  "Open and close a sample of overlays in the current buffer."
  (let ((overlays (cl-subseq (oflp-bench--preview-overlays)
                             0
                             (min 25 (oflp-bench--overlay-count)))))
    (dolist (overlay overlays)
      (org-fast-latex-preview--open-overlay overlay)
      (oflp-bench--assert (null (overlay-get overlay 'display))
                          "Overlay did not open correctly")
      (org-fast-latex-preview--close-overlay overlay)
      (oflp-bench--assert (overlay-get overlay 'display)
                          "Overlay did not close correctly"))
    (length overlays)))

(defun oflp-bench--sample-cache-files (&optional count)
  "Return up to COUNT distinct cache files for fragments in the current buffer."
  (let* ((fragments (oflp-bench--buffer-fragments))
         (files (cl-delete-duplicates
                 (mapcar #'org-fast-latex-preview--fragment-cache-file fragments)
                 :test #'string=)))
    (cl-subseq files 0 (min (or count 10) (length files)))))

(defun oflp-bench--corrupt-cache-files (files)
  "Overwrite FILES with invalid SVG payloads."
  (dolist (file files)
    (with-temp-file file
      (insert "not an svg"))))

(defun oflp-bench--delete-cache-files (files)
  "Delete FILES from the persistent cache."
  (dolist (file files)
    (when (file-exists-p file)
      (delete-file file))))

(defun oflp-bench--reset-cache-directory ()
  "Delete and recreate the active cache directory."
  (let ((directory org-fast-latex-preview-cache-directory))
    (when (file-directory-p directory)
      (delete-directory directory t))
    (make-directory directory t)))

(defun oflp-bench--replace-inline-fragments (fragments)
  "Replace a sample of inline FRAGMENTS with fresh valid expressions."
  (let* ((inline-fragments
          (cl-remove-if-not
           (lambda (fragment)
             (string-prefix-p "$"
                              (org-fast-latex-preview--fragment-source fragment)))
           fragments))
         (sample-count (min 5 (length inline-fragments)))
         replacements)
    (dotimes (index sample-count)
      (let* ((position (floor (* index (/ (float (length inline-fragments))
                                          sample-count))))
             (fragment (nth position inline-fragments))
             (beg (org-fast-latex-preview--fragment-begin-position fragment))
             (end (org-fast-latex-preview--fragment-end-position fragment)))
        (when (and beg end)
          (push (list beg end
                      (format "$\\vect{q}_{%d} = \\frac{%d}{%d + 1}$"
                              index
                              (+ 2 index)
                              (+ 3 index)))
                replacements))))
    (dolist (replacement (sort replacements (lambda (a b) (> (car a) (car b)))))
      (pcase-let ((`(,beg ,end ,text) replacement))
        (goto-char beg)
        (delete-region beg end)
        (insert text)))))

(defun oflp-bench--run-edit-churn-check (cache-dir expected-successful)
  "Run the edit-churn scenario using CACHE-DIR."
  (when (file-directory-p cache-dir)
    (delete-directory cache-dir t))
  (make-directory cache-dir t)
  (org-fast-latex-preview-clear)
  (org-fast-latex-preview-mode 1)
  (unwind-protect
      (let ((seconds
             (oflp-bench--measure-seconds
             (lambda ()
                (org-fast-latex-preview-buffer t)
                (let ((fragments (oflp-bench--buffer-fragments)))
                  (oflp-bench--replace-inline-fragments fragments))
                (sleep-for (+ org-fast-latex-preview-mode-update-delay 0.15))
                (when (timerp org-fast-latex-preview--dirty-timer)
                  (org-fast-latex-preview--flush-dirty-ranges))
                (oflp-bench--wait-for-idle 600.0)))))
        (oflp-bench--assert (= (oflp-bench--overlay-count) expected-successful)
                            "Edit churn overlay count mismatch: %d vs %d"
                            (oflp-bench--overlay-count)
                            expected-successful)
        (oflp-bench--assert (zerop (oflp-bench--job-buffer-count))
                            "Job buffers leaked after edit churn")
        (oflp-bench--assert (null org-fast-latex-preview--dirty-timer)
                            "Dirty timer leaked after edit churn")
        seconds)
    (org-fast-latex-preview-mode -1)))

(defun oflp-bench--assert-overlay-count (name expected-successful)
  "Assert that current buffer has EXPECTED-SUCCESSFUL preview overlays."
  (oflp-bench--assert (= (oflp-bench--overlay-count) expected-successful)
                      "%s overlay count mismatch: %d vs %d"
                      name
                      (oflp-bench--overlay-count)
                      expected-successful))

(defun oflp-bench--render-full-and-wait (&optional refresh timeout)
  "Render the whole buffer and wait for preview work to settle."
  (let ((result (org-fast-latex-preview--render-range
                 (point-min) (point-max) refresh)))
    (oflp-bench--wait-for-idle (or timeout 600.0))
    result))

(defun oflp-bench--run-kill-buffer-cycle (content)
  "Start rendering CONTENT in a secondary buffer and kill it mid-flight."
  (let ((buffer (generate-new-buffer " *oflp-chaos-kill*")))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert content)
          (goto-char (point-min))
          (oflp-bench--reset-cache-directory)
          (org-fast-latex-preview--render-range (point-min) (point-max) t)
          (oflp-bench--wait-for-job #'org-fast-latex-preview--job-live-p
                                    "secondary preview job"
                                    30.0)
          (kill-buffer buffer)
          (setq buffer nil))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (oflp-bench--wait-for
     (lambda ()
       (zerop (oflp-bench--job-buffer-count)))
     "hidden job buffer cleanup"
     60.0)))

(defun oflp-bench--run-cache-fault-check (expected-successful)
  "Corrupt and delete cache entries, then assert transparent recovery."
  (let (result)
    (oflp-bench--render-full-and-wait t 600.0)
    (let* ((files (oflp-bench--sample-cache-files 12))
           (corrupt-count (min 4 (length files)))
           (delete-count (min 4 (max 0 (- (length files) corrupt-count))))
           (corrupt-files (cl-subseq files 0 corrupt-count))
           (delete-files (cl-subseq files corrupt-count
                                    (+ corrupt-count delete-count))))
      (oflp-bench--assert (>= (length files) 4)
                          "Cache fault check needs at least four distinct cache files")
      (oflp-bench--corrupt-cache-files corrupt-files)
      (oflp-bench--delete-cache-files delete-files)
      (org-fast-latex-preview-clear)
      (setq result (org-fast-latex-preview--render-range
                    (point-min) (point-max) nil))
      (oflp-bench--wait-for-idle 600.0)
      (oflp-bench--assert (> (plist-get result :cached) 0)
                          "Cache fault recovery did not reuse surviving cache entries")
      (oflp-bench--assert (> (plist-get result :queued) 0)
                          "Cache fault recovery did not rerender invalidated entries")
      (oflp-bench--assert-overlay-count "cache fault recovery" expected-successful)
      (dolist (file (append corrupt-files delete-files))
        (oflp-bench--assert (org-fast-latex-preview--usable-cache-file-p file)
                            "Cache fault recovery left invalid cache entry %s"
                            file)))))

(defun oflp-bench--run-edit-cancel-chaos (expected-successful)
  "Stress edits, clears, and refreshes while preview jobs are active."
  (org-fast-latex-preview-mode 1)
  (unwind-protect
      (progn
        (oflp-bench--reset-cache-directory)
        (org-fast-latex-preview--render-range (point-min) (point-max) t)
        (oflp-bench--wait-for-job #'org-fast-latex-preview--job-live-p
                                  "active preview job"
                                  30.0)
        (dotimes (_step 3)
          (oflp-bench--replace-inline-fragments (oflp-bench--buffer-fragments))
          (sleep-for (+ org-fast-latex-preview-mode-update-delay 0.05))
          (when (timerp org-fast-latex-preview--dirty-timer)
            (org-fast-latex-preview--flush-dirty-ranges))
          (let ((subtree-range (oflp-bench--subtree-range)))
            (org-fast-latex-preview-clear (car subtree-range) (cdr subtree-range))
            (org-fast-latex-preview--render-range
             (car subtree-range) (cdr subtree-range) t))
          (accept-process-output nil 0.05))
        (oflp-bench--render-full-and-wait t 600.0)
        (oflp-bench--assert-overlay-count "edit/cancel chaos" expected-successful)
        (oflp-bench--assert-clean-runtime "edit/cancel chaos"))
    (org-fast-latex-preview-mode -1)
    (oflp-bench--clear-failure-state)))

(defun oflp-bench--run-lifecycle-chaos (expected-successful)
  "Stress disable, revert, and buffer-kill lifecycle paths."
  (let ((content (buffer-substring-no-properties (point-min) (point-max))))
    (org-fast-latex-preview-mode 1)
    (unwind-protect
        (progn
          (oflp-bench--reset-cache-directory)
          (org-fast-latex-preview--render-range (point-min) (point-max) t)
          (oflp-bench--wait-for-job #'org-fast-latex-preview--job-live-p
                                    "preview job before mode disable"
                                    30.0)
          (org-fast-latex-preview-mode -1)
          (oflp-bench--wait-for
           (lambda ()
             (zerop (oflp-bench--job-buffer-count)))
           "mode disable cleanup"
           60.0)
          (org-fast-latex-preview-mode 1)
          (oflp-bench--render-full-and-wait t 600.0)
          (oflp-bench--assert-overlay-count "mode disable recovery" expected-successful)
          (oflp-bench--reset-cache-directory)
          (org-fast-latex-preview--render-range (point-min) (point-max) t)
          (oflp-bench--wait-for-job #'org-fast-latex-preview--job-live-p
                                    "preview job before revert"
                                    30.0)
          (revert-buffer :ignore-auto :noconfirm)
          (oflp-bench--wait-for-idle 600.0)
          (oflp-bench--assert-overlay-count "revert recovery" expected-successful)
          (oflp-bench--run-kill-buffer-cycle content)
          (oflp-bench--assert-clean-runtime "lifecycle chaos"))
      (org-fast-latex-preview-mode -1)
      (oflp-bench--clear-failure-state))))

(defun oflp-bench--run-transient-fault (description injector expected-successful)
  "Inject a transient process fault with INJECTOR and assert recovery."
  (oflp-bench--reset-cache-directory)
  (org-fast-latex-preview--render-range (point-min) (point-max) t)
  (funcall injector)
  (oflp-bench--wait-for-idle 600.0)
  (oflp-bench--assert-overlay-count description expected-successful)
  (oflp-bench--assert-clean-runtime description)
  (oflp-bench--clear-failure-state))

(defun oflp-bench--run-toolchain-fault-check (expected-successful)
  "Inject transient toolchain faults and assert silent recovery."
  (let ((org-fast-latex-preview-batch-size
         (or org-fast-latex-preview-batch-size 128)))
    (org-fast-latex-preview-mode 1)
    (unwind-protect
        (progn
          (oflp-bench--run-transient-fault
           "latex process kill"
           (lambda ()
             (let* ((job (oflp-bench--wait-for-job
                          (lambda (candidate)
                            (process-live-p
                             (org-fast-latex-preview--job-latex-process candidate)))
                          "live latex process"
                          30.0))
                    (process (org-fast-latex-preview--job-latex-process job)))
               (interrupt-process process)))
           expected-successful)
          (oflp-bench--run-transient-fault
           "image process kill"
           (lambda ()
             (let* ((job (oflp-bench--wait-for-job
                          (lambda (candidate)
                            (process-live-p
                             (org-fast-latex-preview--job-image-process candidate)))
                          "live dvisvgm process"
                          60.0))
                    (process (org-fast-latex-preview--job-image-process job)))
               (interrupt-process process)))
           expected-successful)
          (oflp-bench--run-transient-fault
           "temp directory deletion"
           (lambda ()
             (let ((job (oflp-bench--wait-for-job
                         #'org-fast-latex-preview--job-live-p
                         "preview job before temp directory deletion"
                         30.0)))
               (delete-directory
                (org-fast-latex-preview--job-temp-directory job)
                t)))
           expected-successful))
      (org-fast-latex-preview-mode -1)
      (oflp-bench--clear-failure-state))))

(defun oflp-bench--run-soak-check (expected-successful cycles)
  "Run CYCLES of mixed render/edit/lifecycle abuse in the current buffer."
  (let ((baseline-buffers (length (buffer-list)))
        (max-buffers (length (buffer-list)))
        (sample-toggles 0)
        (content (buffer-substring-no-properties (point-min) (point-max))))
    (org-fast-latex-preview-mode 1)
    (unwind-protect
        (dotimes (cycle cycles)
          (oflp-bench--render-full-and-wait (zerop (% cycle 2)) 600.0)
          (oflp-bench--assert-overlay-count "soak render" expected-successful)
          (cl-incf sample-toggles (oflp-bench--sample-overlay-toggle))
          (oflp-bench--replace-inline-fragments (oflp-bench--buffer-fragments))
          (sleep-for (+ org-fast-latex-preview-mode-update-delay 0.05))
          (when (timerp org-fast-latex-preview--dirty-timer)
            (org-fast-latex-preview--flush-dirty-ranges))
          (oflp-bench--wait-for-idle 600.0)
          (oflp-bench--assert-overlay-count "soak dirty refresh" expected-successful)
          (when (zerop (% cycle 3))
            (let* ((files (oflp-bench--sample-cache-files 4))
                   (corrupt-files (cl-subseq files 0 (min 2 (length files)))))
              (oflp-bench--corrupt-cache-files corrupt-files)
              (org-fast-latex-preview-clear)
              (oflp-bench--render-full-and-wait nil 600.0)
              (oflp-bench--assert-overlay-count "soak cache recovery" expected-successful)))
          (when (zerop (% cycle 4))
            (org-fast-latex-preview-mode -1)
            (oflp-bench--assert-clean-runtime "soak mode disable")
            (org-fast-latex-preview-mode 1))
          (when (zerop (% cycle 5))
            (oflp-bench--run-kill-buffer-cycle content))
          (setq max-buffers (max max-buffers (length (buffer-list))))
          (oflp-bench--assert-clean-runtime "soak cycle"))
      (org-fast-latex-preview-mode -1)
      (oflp-bench--clear-failure-state))
    `(("cycles" . ,cycles)
      ("sample_overlay_toggles" . ,sample-toggles)
      ("baseline_buffers" . ,baseline-buffers)
      ("max_buffers" . ,max-buffers)
      ("final_buffers" . ,(length (buffer-list))))))

(defun oflp-bench--profile-metrics (manifest-entry extra-preamble compiler results-dir
                                                  &optional chaos soak-cycles)
  "Benchmark a single MANIFEST-ENTRY using EXTRA-PREAMBLE and COMPILER.

Store profile-specific results under RESULTS-DIR."
  (let* ((name (gethash "name" manifest-entry))
         (scenario (gethash "scenario" manifest-entry))
         (file (gethash "path" manifest-entry))
         (expected-total (gethash "total_fragments" manifest-entry))
         (expected-successful (gethash "expected_successful_fragments" manifest-entry))
         (expected-invalid (gethash "invalid_fragments" manifest-entry))
         (cache-dir (expand-file-name (concat "cache/" name "/") results-dir))
         (buffer (find-file-noselect file t))
         metrics)
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (let ((org-fast-latex-preview-cache-directory cache-dir)
                (org-fast-latex-preview-extra-preamble extra-preamble)
                (org-fast-latex-preview-preamble-source 'lean)
                (org-fast-latex-preview-compiler compiler)
                (org-fast-latex-preview-debug nil))
            (when (file-directory-p cache-dir)
              (delete-directory cache-dir t))
            (make-directory cache-dir t)
            (let* ((fragments (oflp-bench--buffer-fragments))
                   (fragment-count (length fragments))
                   cold-result
                   cold-seconds
                   cold-profile
                   subtree-result
                   subtree-seconds
                   subtree-profile
                   hot-result
                   hot-seconds
                   hot-profile
                   chaos-seconds
                   soak-seconds
                   soak-report
                   failure-count
                   final-failure-count)
              (oflp-bench--assert (= fragment-count expected-total)
                                  "%s fragment count mismatch: %d vs %d"
                                  name fragment-count expected-total)
              (setq metrics
                    `(("name" . ,name)
                      ("scenario" . ,scenario)
                      ("file" . ,file)
                      ("expected_total_fragments" . ,expected-total)
                      ("expected_successful_fragments" . ,expected-successful)
                      ("expected_invalid_fragments" . ,expected-invalid)
                      ("memory_before" . ,(oflp-bench--memory-snapshot))))

              (org-fast-latex-preview-clear)
              (setq cold-seconds
                    (oflp-bench--measure-seconds
                     (lambda ()
                       (setq cold-result
                             (org-fast-latex-preview--render-range
                              (point-min) (point-max) t))
                       (oflp-bench--wait-for-jobs 600.0))))
              (setq cold-profile (org-fast-latex-preview--profile-snapshot))
              (oflp-bench--assert (= (oflp-bench--overlay-count) expected-successful)
                                  "%s cold overlay count mismatch: %d vs %d"
                                  name
                                  (oflp-bench--overlay-count)
                                  expected-successful)
              (setq metrics
                    (append metrics
                            `(("cold_seconds" . ,cold-seconds)
                              ("cold_result" . (("cached" . ,(plist-get cold-result :cached))
                                                ("queued" . ,(plist-get cold-result :queued))))
                              ("cold_overlay_count" . ,(oflp-bench--overlay-count))
                              ("cold_profile" . ,cold-profile)
                              ("overlay_toggle_sample" . ,(oflp-bench--sample-overlay-toggle)))))

              (let ((subtree-range (oflp-bench--subtree-range)))
                (setq subtree-seconds
                      (oflp-bench--measure-seconds
                       (lambda ()
                         (setq subtree-result
                               (org-fast-latex-preview--render-range
                                (car subtree-range) (cdr subtree-range) nil))
                         (oflp-bench--wait-for-jobs 600.0)))))
              (setq subtree-profile (org-fast-latex-preview--profile-snapshot))
              (setq metrics
                    (append metrics
                            `(("subtree_seconds" . ,subtree-seconds)
                              ("subtree_result" . (("cached" . ,(plist-get subtree-result :cached))
                                                   ("queued" . ,(plist-get subtree-result :queued))))
                              ("subtree_profile" . ,subtree-profile))))

              (org-fast-latex-preview-clear)
              (setq hot-seconds
                    (oflp-bench--measure-seconds
                     (lambda ()
                       (setq hot-result
                             (org-fast-latex-preview--render-range
                              (point-min) (point-max) nil))
                       (oflp-bench--wait-for-jobs 600.0))))
              (setq hot-profile (org-fast-latex-preview--profile-snapshot))
              (oflp-bench--assert (= (oflp-bench--overlay-count) expected-successful)
                                  "%s hot overlay count mismatch: %d vs %d"
                                  name
                                  (oflp-bench--overlay-count)
                                  expected-successful)
              (setq metrics
                    (append metrics
                            `(("hot_seconds" . ,hot-seconds)
                              ("hot_result" . (("cached" . ,(plist-get hot-result :cached))
                                               ("queued" . ,(plist-get hot-result :queued))))
                              ("hot_overlay_count" . ,(oflp-bench--overlay-count))
                              ("hot_profile" . ,hot-profile))))

              (setq failure-count (length (oflp-bench--failure-buffers)))

              (when (string= scenario "edit-churn")
                (setq metrics
                      (append metrics
                              `(("edit_churn_seconds"
                                 . ,(oflp-bench--run-edit-churn-check
                                     cache-dir
                                     expected-successful))))))

              (when chaos
                (oflp-bench--assert (zerop expected-invalid)
                                    "%s chaos suite currently expects a fully valid corpus"
                                    name)
                (setq chaos-seconds
                      (oflp-bench--measure-seconds
                       (lambda ()
                         (oflp-bench--run-edit-cancel-chaos expected-successful)
                         (oflp-bench--run-lifecycle-chaos expected-successful)
                         (oflp-bench--run-cache-fault-check expected-successful)
                         (oflp-bench--run-toolchain-fault-check expected-successful))))
                (setq metrics
                      (append metrics
                              `(("chaos_seconds" . ,chaos-seconds)))))

              (when (> (or soak-cycles 0) 0)
                (setq soak-seconds
                      (oflp-bench--measure-seconds
                       (lambda ()
                         (setq soak-report
                               (oflp-bench--run-soak-check
                                expected-successful
                                soak-cycles)))))
                (setq metrics
                      (append metrics
                              `(("soak_seconds" . ,soak-seconds)
                                ("soak" . ,soak-report)))))

              (setq final-failure-count (length (oflp-bench--failure-buffers)))
              (if (> expected-invalid 0)
                  (oflp-bench--assert (> failure-count 0)
                                      "%s expected failure buffers for invalid corpus"
                                      name)
                (oflp-bench--assert (zerop failure-count)
                                    "%s unexpectedly produced failure buffers"
                                    name))
              (oflp-bench--assert (zerop (oflp-bench--job-buffer-count))
                                  "%s leaked hidden job buffers" name)
              (oflp-bench--assert (null org-fast-latex-preview--jobs)
                                  "%s leaked preview jobs" name)
              (setq metrics
                    (append metrics
                            `(("failure_buffer_count" . ,failure-count)
                              ("final_failure_buffer_count" . ,final-failure-count)
                              ("cache_files" . ,(length (oflp-bench--cache-files cache-dir)))
                              ("cache_bytes" . ,(oflp-bench--cache-bytes cache-dir))
                              ("memory_after" . ,(oflp-bench--memory-snapshot))))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (org-fast-latex-preview-mode -1)
          (org-fast-latex-preview--cancel-jobs)
          (org-fast-latex-preview-clear))
        (kill-buffer buffer))
      (oflp-bench--cleanup-failure-buffers))
    metrics))

(defun oflp-bench-main ()
  "Run the stress benchmark harness."
  (let* ((args (oflp-bench--parse-args))
         (manifest-path (plist-get args :manifest))
         (results-dir (file-name-as-directory (plist-get args :results-dir)))
         (profiles-filter (plist-get args :profiles))
         (compiler (plist-get args :compiler))
         (chaos (plist-get args :chaos))
         (soak-cycles (plist-get args :soak-cycles))
         (manifest (oflp-bench--read-json-file manifest-path))
         (profiles-table (gethash "profiles" manifest))
         (extra-preamble (gethash "extra_preamble" manifest))
         (available-profiles nil)
         (matched-profiles nil)
         items
         report)
    (oflp-bench--ensure-directory results-dir)
    (maphash
     (lambda (name entry)
       (push name available-profiles)
       (when (or (null profiles-filter)
                 (member name profiles-filter))
         (push name matched-profiles)
         (let ((metrics
                (oflp-bench--profile-metrics
                 entry extra-preamble compiler results-dir chaos soak-cycles)))
           (push metrics items)
           (princ
            (format "%s cold=%.3fs hot=%.3fs overlays=%d%s%s\n"
                    name
                    (alist-get "cold_seconds" metrics nil nil #'string=)
                    (alist-get "hot_seconds" metrics nil nil #'string=)
                    (alist-get "hot_overlay_count" metrics nil nil #'string=)
                    (if chaos
                        (format " chaos=%.3fs"
                                (alist-get "chaos_seconds" metrics nil nil #'string=))
                      "")
                    (if (> soak-cycles 0)
                        (format " soak=%.3fs"
                                (alist-get "soak_seconds" metrics nil nil #'string=))
                      ""))))))
     profiles-table)
    (when (and profiles-filter
               (null matched-profiles))
      (error "No requested profiles matched %s. Available profiles: %s"
             manifest-path
             (string-join (sort available-profiles #'string<) ", ")))
    (setq report
          `(("manifest" . ,manifest-path)
            ("compiler" . ,compiler)
            ("chaos" . ,(if chaos t :json-false))
            ("soak_cycles" . ,soak-cycles)
            ("profiles" . ,(nreverse items))))
    (oflp-bench--write-json-file
     (expand-file-name "report.json" results-dir)
     report)))

(when noninteractive
  (oflp-bench-main))

;;; bench.el ends here
