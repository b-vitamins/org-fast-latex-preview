;;; org-fast-latex-preview-core.el --- Shared state for Org fast previews -*- lexical-binding: t; -*-

;;; Commentary:

;; Customization, shared structs, logging, and render-context resolution.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'org)
(require 'ox-latex)
(require 'subr-x)

(eval-when-compile
  ;; Emacs 29 emits docstring-width warnings for `cl-defstruct' generated
  ;; accessors with OFLP's long internal names.  `checkdoc' is the actual
  ;; docstring gate for this file, so relax the byte-compiler limit here.
  (setq byte-compile-docstring-max-column 200))

(defgroup org-fast-latex-preview nil
  "Fast batched LaTeX previews for Org."
  :group 'org
  :prefix "org-fast-latex-preview-")

(defconst org-fast-latex-preview--cache-version 1
  "Cache format version.")

(defconst org-fast-latex-preview--svg-extension "svg"
  "Rendered image file extension.")

(defconst org-fast-latex-preview--log-buffer-name " *org-fast-latex-preview-log*"
  "Name of the hidden debug log buffer.")

(defconst org-fast-latex-preview--failure-buffer-name
  "*org-fast-latex-preview-failure*"
  "Base name of the aggregated failure report buffer.")

(defcustom org-fast-latex-preview-cache-directory
  (expand-file-name
   "org-fast-latex-preview/"
   (or (getenv "XDG_CACHE_HOME")
       (expand-file-name "~/.cache/")))
  "Directory where persistent preview images are stored."
  :type 'directory)

(defcustom org-fast-latex-preview-appearance-options
  '(:page-width nil)
  "Appearance options for generated previews.

Supported keys:

`:foreground'
  Foreground color.  May be a color string, `default', or `auto'.
  `auto' currently resolves to the foreground of the default face.

`:background'
  Background color.  May be a color string, `default', `auto', or
  \"Transparent\".

`:scale'
  Additional scale multiplier for the generated SVGs.  The effective
  render scale is this value multiplied by the display DPI relative to
  140 DPI.

`:page-width'
  Optional page width override.  When a string, it is inserted as a
  LaTeX dimension, for example \"18cm\".  When a floating-point number
  between 0 and 1, it is interpreted as a fraction of `\\paperwidth'.

When `:foreground', `:background', or `:scale' are omitted here, OFLP
inherits the corresponding values from `org-format-latex-options'."
  :type 'plist)

(defcustom org-fast-latex-preview-preamble-source 'lean
  "How to build the LaTeX preamble for preview rendering.

`lean' uses a minimal preview-oriented preamble intended for speed.
`org' reuses Org's export preamble for maximum compatibility."
  :type '(choice (const :tag "Lean preview preamble" lean)
                 (const :tag "Org export preamble" org)))

(defcustom org-fast-latex-preview-extra-preamble ""
  "Extra LaTeX inserted into the preview preamble.

Use this for custom macros and package imports required by your notes."
  :type 'string)

(defcustom org-fast-latex-preview-profile 'auto
  "Context resolution profile for preview rendering.

`auto'
  Resolve a render context from the current Org preview state.  Stock
  Org setups prefer the lean fast path, while customized preview
  setups prefer an Org-compatible path and may promote from the fast
  path on failure.

`manual'
  Use `org-fast-latex-preview-compiler' and
  `org-fast-latex-preview-preamble-source' exactly.

`org-state'
  Always build the preview preamble from the current Org preview
  variables and infer the compiler from Org preview/export settings.

`scientific-lualatex'
  Use a built-in LuaLaTeX + unicode-math preset intended for
  scientific notes."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "Manual" manual)
                 (const :tag "Current Org state" org-state)
                 (const :tag "Scientific LuaLaTeX preset" scientific-lualatex)))

(defcustom org-fast-latex-preview-compiler nil
  "Compiler to use for preview generation.

When nil, derive the preview compiler from `org-latex-compiler'.

Supported values are the symbols or strings `latex', `pdflatex',
`xelatex', `lualatex', and `dvilualatex'."
  :type '(choice (const :tag "Follow Org compiler" nil)
                 (symbol :tag "Compiler symbol")
                 (string :tag "Compiler string")))

(defcustom org-fast-latex-preview-batch-size nil
  "Base maximum number of uncached fragments to render in a single batch.

When nil, render all uncached fragments from the request in one batch.
This setting defines the resilient scheduler profile and is also used
when `org-fast-latex-preview-scheduler' is set to `resilient'."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Fragments per batch")))

(defcustom org-fast-latex-preview-max-concurrent-jobs 4
  "Base maximum number of concurrent preview subprocess pipelines per buffer.

When nil, start every queued batch immediately.  Lower values improve
stability under heavy failure-splitting or very large refreshes at the
cost of some throughput.  This setting defines the resilient scheduler
profile and is also used when `org-fast-latex-preview-scheduler' is set
to `resilient'."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Concurrent jobs")))

(defcustom org-fast-latex-preview-scheduler 'adaptive
  "Scheduling policy for bulk preview renders.

`resilient' always uses the base batch and concurrency settings.
`throughput' always uses the throughput tuning knobs below.
`adaptive' uses throughput mode for large bulk renders, falls back to
resilient mode on the first batch failure, and always keeps dirty
refreshes on the resilient path."
  :type '(choice (const :tag "Adaptive" adaptive)
                 (const :tag "Resilient" resilient)
                 (const :tag "Throughput" throughput)))

(defcustom org-fast-latex-preview-adaptive-fragment-threshold 2000
  "Minimum uncached fragment count before adaptive scheduling uses throughput mode."
  :type 'integer)

(defcustom org-fast-latex-preview-throughput-batch-size 2500
  "Fragments per batch for the throughput scheduler profile."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Fragments per batch")))

(defcustom org-fast-latex-preview-throughput-max-concurrent-jobs 2
  "Concurrent jobs for the throughput scheduler profile."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Concurrent jobs")))

(defcustom org-fast-latex-preview-failure-strategy 'split
  "How to handle batch failures.

When set to `split', a failing batch is recursively split to isolate
bad fragments.  When nil, the failing batch is reported as-is."
  :type '(choice (const :tag "Split failing batches" split)
                 (const :tag "Do not split" nil)))

(defcustom org-fast-latex-preview-max-failure-samples 5
  "Maximum number of sample fragments shown for each failure group."
  :type 'integer)

(defcustom org-fast-latex-preview-max-failure-groups 20
  "Maximum number of failure groups shown in the aggregated failure report.

When nil, show every distinct failure group."
  :type '(choice (const :tag "All groups" nil)
                 (integer :tag "Maximum groups")))

(defcustom org-fast-latex-preview-mode-update-delay 0.35
  "Idle delay, in seconds, before re-rendering dirty fragments."
  :type 'number)

(defcustom org-fast-latex-preview-max-image-size 40.0
  "Buffer-local `max-image-size' used while OFLP mode is active.

When nil, OFLP leaves `max-image-size' unchanged.

When an integer, it is interpreted as a pixel limit.

When a floating-point number, it is interpreted as a ratio relative to
the selected frame size."
  :type '(choice (const :tag "Keep current setting" nil)
                 (integer :tag "Pixel limit")
                 (float :tag "Frame-relative ratio")))

(defcustom org-fast-latex-preview-override-org-commands t
  "When non-nil, route Org preview commands through OFLP while the mode is active.

This affects `org-latex-preview' and `org-clear-latex-preview' only in
buffers where `org-fast-latex-preview-mode' is enabled.  When nil, OFLP
provides its own commands and minor mode, but does not intercept Org's
standard preview entry points."
  :type 'boolean)

(defcustom org-fast-latex-preview-mode-ignored-commands nil
  "Commands that should not toggle preview visibility at point."
  :type '(repeat symbol))

(defcustom org-fast-latex-preview-debug nil
  "When non-nil, keep job log buffers and emit verbose log messages."
  :type 'boolean)

(defcustom org-fast-latex-preview-dpi-function
  #'org-fast-latex-preview-default-dpi
  "Function returning the effective preview DPI for the selected frame."
  :type 'function)

(defconst org-fast-latex-preview--scientific-lualatex-packages
  '(("" "amsmath" t)
    ("" "amssymb" t)
    ("" "amsthm" t)
    ("" "mathtools" t)
    ("" "physics" t)
    ("" "braket" t)
    ("" "tensor" t)
    ("" "dsfont" t)
    ("" "bbm" t)
    ("" "mathrsfs" t)
    ("" "esint" t)
    ("" "cancel" t)
    ("" "nicematrix" t)
    ("" "array" t)
    ("binary-units=true" "siunitx" t)
    ("" "tikz" t)
    ("" "pgfplots" t)
    ("" "chemfig" t)
    ("" "mhchem" t)
    ("" "algorithm2e" t)
    ("" "microtype" t)
    ("" "xcolor" t))
  "Built-in package set for `scientific-lualatex' preview contexts.")

(defconst org-fast-latex-preview--scientific-lualatex-header
  "\\documentclass{article}
\\usepackage[usenames]{color}
[DEFAULT-PACKAGES]
[PACKAGES]
\\usepackage{unicode-math}
\\setmathfont{TeX Gyre Pagella Math}
\\setmainfont{TeX Gyre Pagella}
\\pagestyle{empty}
\\setlength{\\textwidth}{\\paperwidth}
\\addtolength{\\textwidth}{-3cm}
\\setlength{\\oddsidemargin}{1.5cm}
\\addtolength{\\oddsidemargin}{-2.54cm}
\\setlength{\\evensidemargin}{\\oddsidemargin}
\\setlength{\\textheight}{\\paperheight}
\\addtolength{\\textheight}{-\\headheight}
\\addtolength{\\textheight}{-\\headsep}
\\addtolength{\\textheight}{-\\footskip}
\\addtolength{\\textheight}{-3cm}
\\setlength{\\topmargin}{1.5cm}
\\addtolength{\\topmargin}{-2.54cm}
"
  "Built-in header used by the `scientific-lualatex' preview profile.")

(cl-defstruct (org-fast-latex-preview--context
               (:constructor org-fast-latex-preview--make-context))
  label
  appearance
  compiler-key
  compiler-command
  compiler-program
  input-extension
  preamble
  foreground-rgb
  background-rgb
  render-scale
  cache-directory)

(cl-defstruct (org-fast-latex-preview--plan
               (:constructor org-fast-latex-preview--make-plan))
  generation
  mode
  batch-size
  max-concurrent-jobs
  replace-existing-overlays
  fallback-triggered)

(cl-defstruct (org-fast-latex-preview--fragment
               (:constructor org-fast-latex-preview--make-fragment))
  beg
  end
  begin-marker
  end-marker
  source
  cache-key
  cache-file
  existing-overlay)

(cl-defstruct (org-fast-latex-preview--job
               (:constructor org-fast-latex-preview--make-job))
  buffer
  generation
  fragments
  plan
  context
  temp-directory
  tex-file
  input-file
  log-buffer
  latex-process
  image-process
  latex-start-time
  image-start-time
  placed-count
  image-output-remainder
  failure-stage
  failure-summary
  failure-internal
  canceled)

(cl-defstruct (org-fast-latex-preview--render-profile
               (:constructor org-fast-latex-preview--make-render-profile))
  generation
  started-at
  finished-at
  timings
  counters)

(cl-defstruct (org-fast-latex-preview--failure-instance
               (:constructor org-fast-latex-preview--make-failure-instance))
  generation
  stage
  summary
  internal
  source
  begin-marker
  end-marker)

(cl-defstruct (org-fast-latex-preview--failure-report
               (:constructor org-fast-latex-preview--make-failure-report))
  generation
  instances
  buffer
  notified)

(defvar-local org-fast-latex-preview--generation 0
  "Monotonic generation counter for the current buffer.")

(defvar-local org-fast-latex-preview--jobs nil
  "List of active preview jobs for the current buffer.")

(defvar-local org-fast-latex-preview--pending-batches nil
  "FIFO queue of preview batches waiting to be started.")

(defvar-local org-fast-latex-preview--failure-report nil
  "Aggregated failure information for the current buffer generation.")

(defvar-local org-fast-latex-preview--dirty-ranges nil
  "Pending dirty ranges in the current buffer.")

(defvar-local org-fast-latex-preview--dirty-timer nil
  "Idle timer used to debounce dirty fragment refreshes.")

(defvar-local org-fast-latex-preview--opened-overlay nil
  "Preview overlay currently opened at point.")

(defvar-local org-fast-latex-preview--overlay-count 0
  "Approximate number of live OFLP overlays in the current buffer.")

(defvar-local org-fast-latex-preview--active-profile nil
  "Active render profile for the current buffer generation.")

(defvar-local org-fast-latex-preview--last-render-profile nil
  "Most recently completed or active render profile for the current buffer.")

(defvar-local org-fast-latex-preview--context-chain nil
  "Resolved render contexts for the current generation.")

(defvar-local org-fast-latex-preview--context-chain-index 0
  "Index of the active context inside `org-fast-latex-preview--context-chain'.")

(defvar-local org-fast-latex-preview--generation-range nil
  "Cons cell of the active render range for the current generation.")

(defun org-fast-latex-preview-default-dpi ()
  "Return the effective preview DPI for the selected frame."
  (cond
   ((not (display-graphic-p)) 140.0)
   ((fboundp 'org--get-display-dpi)
    (float (org--get-display-dpi)))
   (t 140.0)))

(defun org-fast-latex-preview--fragment-begin-position (fragment)
  "Return FRAGMENT's current beginning position."
  (let ((marker (org-fast-latex-preview--fragment-begin-marker fragment)))
    (if (markerp marker)
        (marker-position marker)
      (org-fast-latex-preview--fragment-beg fragment))))

(defun org-fast-latex-preview--fragment-end-position (fragment)
  "Return FRAGMENT's current ending position."
  (let ((marker (org-fast-latex-preview--fragment-end-marker fragment)))
    (if (markerp marker)
        (marker-position marker)
      (org-fast-latex-preview--fragment-end fragment))))

(defun org-fast-latex-preview--ensure-fragment-markers (fragment)
  "Ensure FRAGMENT has tracking markers and return it."
  (unless (markerp (org-fast-latex-preview--fragment-begin-marker fragment))
    (setf (org-fast-latex-preview--fragment-begin-marker fragment)
          (copy-marker (org-fast-latex-preview--fragment-beg fragment))))
  (unless (markerp (org-fast-latex-preview--fragment-end-marker fragment))
    (setf (org-fast-latex-preview--fragment-end-marker fragment)
          (copy-marker (org-fast-latex-preview--fragment-end fragment) t)))
  fragment)

(defun org-fast-latex-preview--make-resilient-plan (generation replace-existing-overlays)
  "Return the resilient render plan for GENERATION.

REPLACE-EXISTING-OVERLAYS controls whether overlay placement should
clear overlapping previews first."
  (org-fast-latex-preview--make-plan
   :generation generation
   :mode 'resilient
   :batch-size org-fast-latex-preview-batch-size
   :max-concurrent-jobs org-fast-latex-preview-max-concurrent-jobs
   :replace-existing-overlays replace-existing-overlays
   :fallback-triggered nil))

(defun org-fast-latex-preview--make-throughput-plan (generation replace-existing-overlays)
  "Return the throughput render plan for GENERATION.

REPLACE-EXISTING-OVERLAYS controls whether overlay placement should
clear overlapping previews first."
  (org-fast-latex-preview--make-plan
   :generation generation
   :mode 'throughput
   :batch-size org-fast-latex-preview-throughput-batch-size
   :max-concurrent-jobs org-fast-latex-preview-throughput-max-concurrent-jobs
   :replace-existing-overlays replace-existing-overlays
   :fallback-triggered nil))

(defun org-fast-latex-preview--plan-for-render
    (generation fragment-count replace-existing-overlays &optional dirty-refresh)
  "Return the scheduler plan for GENERATION.

FRAGMENT-COUNT is the number of fragments in the request.
REPLACE-EXISTING-OVERLAYS controls whether placement should clear
overlapping previews first.

When DIRTY-REFRESH is non-nil, always choose the resilient plan."
  (pcase org-fast-latex-preview-scheduler
    ('throughput
     (if dirty-refresh
         (org-fast-latex-preview--make-resilient-plan
          generation replace-existing-overlays)
       (org-fast-latex-preview--make-throughput-plan
        generation replace-existing-overlays)))
    ('adaptive
     (if (or dirty-refresh
             (< fragment-count org-fast-latex-preview-adaptive-fragment-threshold))
         (org-fast-latex-preview--make-resilient-plan
          generation replace-existing-overlays)
       (org-fast-latex-preview--make-throughput-plan
        generation replace-existing-overlays)))
    (_
     (org-fast-latex-preview--make-resilient-plan
      generation replace-existing-overlays))))

(defun org-fast-latex-preview--log (format-string &rest args)
  "Append a debug line using FORMAT-STRING and ARGS."
  (when org-fast-latex-preview-debug
    (with-current-buffer (get-buffer-create org-fast-latex-preview--log-buffer-name)
      (goto-char (point-max))
      (insert (apply #'format
                     (concat (format-time-string "[%F %T] ") format-string "\n")
                     args)))))

(defun org-fast-latex-preview--start-profile (generation)
  "Create and install a render profile for GENERATION."
  (setq org-fast-latex-preview--active-profile
        (org-fast-latex-preview--make-render-profile
         :generation generation
         :started-at (float-time)
         :finished-at nil
         :timings (make-hash-table :test 'eq)
         :counters (make-hash-table :test 'eq)))
  (setq org-fast-latex-preview--last-render-profile
        org-fast-latex-preview--active-profile))

(defun org-fast-latex-preview--current-profile (&optional generation)
  "Return the active render profile for GENERATION, or the current one."
  (when (and org-fast-latex-preview--active-profile
             (or (null generation)
                 (= generation
                    (org-fast-latex-preview--render-profile-generation
                     org-fast-latex-preview--active-profile))))
    org-fast-latex-preview--active-profile))

(defun org-fast-latex-preview--profile-add-time (profile key seconds)
  "Accumulate SECONDS under KEY in PROFILE."
  (when profile
    (let ((table (org-fast-latex-preview--render-profile-timings profile)))
      (puthash key (+ seconds (gethash key table 0.0)) table))))

(defun org-fast-latex-preview--profile-inc (profile key &optional delta)
  "Increment KEY in PROFILE by DELTA."
  (when profile
    (let ((table (org-fast-latex-preview--render-profile-counters profile)))
      (puthash key (+ (or delta 1) (gethash key table 0)) table))))

(defmacro org-fast-latex-preview--with-timing (profile key &rest body)
  "Evaluate BODY and add elapsed time under KEY in PROFILE."
  (declare (indent 2) (debug (form form body)))
  (let ((start (make-symbol "start"))
        (value (make-symbol "value")))
    `(let ((,start (float-time))
           ,value)
       (setq ,value (progn ,@body))
       (org-fast-latex-preview--profile-add-time
        ,profile ',key (- (float-time) ,start))
       ,value)))

(defun org-fast-latex-preview--finish-profile-if-settled ()
  "Mark the active render profile as finished when no work remains."
  (when (and org-fast-latex-preview--active-profile
             (null org-fast-latex-preview--jobs)
             (null org-fast-latex-preview--pending-batches))
    (setf (org-fast-latex-preview--render-profile-finished-at
           org-fast-latex-preview--active-profile)
          (float-time))))

(defun org-fast-latex-preview--profile-snapshot (&optional profile)
  "Return PROFILE as a JSON-friendly alist."
  (when-let* ((profile (or profile org-fast-latex-preview--last-render-profile))
              (timings (org-fast-latex-preview--render-profile-timings profile))
              (counters (org-fast-latex-preview--render-profile-counters profile)))
    (let (timing-items counter-items)
      (maphash
       (lambda (key value)
         (push (cons (format "%s_seconds" (symbol-name key)) value)
               timing-items))
       timings)
      (maphash
       (lambda (key value)
         (push (cons (symbol-name key) value) counter-items))
       counters)
      `(("generation" . ,(org-fast-latex-preview--render-profile-generation
                          profile))
        ("elapsed_seconds" . ,(- (or (org-fast-latex-preview--render-profile-finished-at
                                      profile)
                                     (float-time))
                                 (org-fast-latex-preview--render-profile-started-at
                                  profile)))
        ("timings" . ,(sort timing-items
                            (lambda (left right)
                              (string< (car left) (car right)))))
        ("counters" . ,(sort counter-items
                             (lambda (left right)
                               (string< (car left) (car right)))))))))

;;;###autoload
(defun org-fast-latex-preview-open-log ()
  "Open the package log buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create org-fast-latex-preview--log-buffer-name)))

(defun org-fast-latex-preview--ensure-directory (directory)
  "Ensure DIRECTORY exists and return it."
  (unless (file-directory-p directory)
    (make-directory directory t))
  directory)

(defun org-fast-latex-preview--normalize-face-color (color fallback)
  "Return COLOR unless it is unspecified, otherwise FALLBACK."
  (if (or (memq color '(unspecified unspecified-fg unspecified-bg nil))
          (and (stringp color)
               (string-prefix-p "unspecified" color)))
      fallback
    color))

(defun org-fast-latex-preview--compiler-from-command (command)
  "Infer a compiler name from COMMAND."
  (when command
    (let* ((command-string (if (stringp command)
                               command
                             (car command)))
           (program (car (split-string-shell-command command-string))))
      (when program
        (pcase (file-name-nondirectory (downcase program))
          ((or "latex" "pdflatex" "xelatex" "lualatex" "dvilualatex")
           (file-name-nondirectory (downcase program))))))))

(defun org-fast-latex-preview--compiler-from-preview-process ()
  "Infer a compiler from Org's active preview process configuration."
  (when (and (boundp 'org-preview-latex-default-process)
             (boundp 'org-preview-latex-process-alist))
    (when-let* ((entry (assq org-preview-latex-default-process
                             org-preview-latex-process-alist))
                (compiler (plist-get (cdr entry) :latex-compiler)))
      (org-fast-latex-preview--compiler-from-command compiler))))

(defun org-fast-latex-preview--effective-appearance-options ()
  "Return the effective appearance options for the current buffer."
  (let ((options (copy-sequence '(:foreground auto
                                   :background "Transparent"
                                   :scale 1.0
                                   :page-width nil)))
        (user-options (copy-sequence org-fast-latex-preview-appearance-options)))
    (when (boundp 'org-format-latex-options)
      (dolist (key '(:foreground :background :scale))
        (when (plist-member org-format-latex-options key)
          (setq options (plist-put options key
                                   (plist-get org-format-latex-options key))))))
    (while user-options
      (setq options
            (plist-put options
                       (pop user-options)
                       (pop user-options))))
    options))

(defun org-fast-latex-preview--rgb-components (color)
  "Return COLOR as a list of three RGB floats."
  (let ((resolved
         (cond
          ((or (null color) (equal color "Transparent")) nil)
          ((eq color 'default)
           (org-fast-latex-preview--normalize-face-color
            (face-attribute 'default :foreground nil t)
            "black"))
          ((eq color 'auto)
           (org-fast-latex-preview--normalize-face-color
            (face-attribute 'default :foreground nil t)
            "black"))
          (t color))))
    (when resolved
      (or (color-name-to-rgb resolved)
          (user-error "Cannot resolve color %S for previews" resolved)))))

(defun org-fast-latex-preview--background-rgb-components (color)
  "Return background COLOR as RGB floats or nil for transparency."
  (cond
   ((or (null color) (equal color "Transparent")) nil)
   ((eq color 'default)
    (color-name-to-rgb
     (org-fast-latex-preview--normalize-face-color
      (face-attribute 'default :background nil t)
      "white")))
   ((eq color 'auto)
    (color-name-to-rgb
     (org-fast-latex-preview--normalize-face-color
      (face-attribute 'default :background nil t)
      "white")))
   (t
    (or (color-name-to-rgb color)
        (user-error "Cannot resolve background color %S for previews" color)))))

(defun org-fast-latex-preview--rgb-string (components)
  "Format RGB COMPONENTS as a LaTeX rgb string."
  (mapconcat (lambda (component)
               (format "%.6f" component))
             components
             ","))

(defun org-fast-latex-preview--page-width-snippet (page-width)
  "Return LaTeX code for PAGE-WIDTH."
  (cond
   ((null page-width) "")
   ((and (numberp page-width)
         (<= 0.0 page-width)
         (<= page-width 1.0))
    (format "\\setlength{\\textwidth}{%.6f\\paperwidth}\n" page-width))
   ((stringp page-width)
    (format "\\setlength{\\textwidth}{%s}\n" page-width))
   (t
    (user-error "Unsupported :page-width value: %S" page-width))))

(defun org-fast-latex-preview--manual-compiler-base ()
  "Return the manually configured compiler name."
  (let* ((candidate (or org-fast-latex-preview-compiler
                        (and (boundp 'org-latex-compiler) org-latex-compiler)
                        "latex")))
    (downcase (if (symbolp candidate)
                  (symbol-name candidate)
                candidate))))

(defun org-fast-latex-preview--inferred-compiler-base ()
  "Return the compiler name inferred from Org preview state."
  (or (and org-fast-latex-preview-compiler
           (org-fast-latex-preview--manual-compiler-base))
      (org-fast-latex-preview--compiler-from-preview-process)
      (and (boundp 'org-latex-compiler)
           org-latex-compiler
           (downcase (if (symbolp org-latex-compiler)
                         (symbol-name org-latex-compiler)
                       org-latex-compiler)))
      "latex"))

(defun org-fast-latex-preview--compiler-spec-for-base (compiler-base)
  "Return the preview compiler specification for COMPILER-BASE."
  (pcase compiler-base
    ((or "latex" "pdflatex")
     (list :key 'latex
           :program "latex"
           :input-extension "dvi"
           :command '("latex" "-interaction=nonstopmode" "-halt-on-error"
                      "-output-directory")))
    ("xelatex"
     (list :key 'xelatex
           :program "xelatex"
           :input-extension "xdv"
           :command '("xelatex" "-no-pdf" "-interaction=nonstopmode" "-halt-on-error"
                      "-output-directory")))
    ((or "lualatex" "dvilualatex")
     (list :key 'dvilualatex
           :program "dvilualatex"
           :input-extension "dvi"
           :command '("dvilualatex" "-interaction=nonstopmode" "-halt-on-error"
                      "-output-directory")))
    (other
     (user-error "Unsupported preview compiler %S" other))))

(defun org-fast-latex-preview--org-state-customized-p ()
  "Return non-nil when the current Org preview setup appears customized."
  (let ((compiler (org-fast-latex-preview--inferred-compiler-base)))
    (or (not (member compiler '("latex" "pdflatex")))
        (and (boundp 'org-preview-latex-default-process)
             (not (memq org-preview-latex-default-process
                        '(dvipng dvisvgm imagemagick))))
        (and (boundp 'org-latex-packages-alist)
             org-latex-packages-alist)
        (and (boundp 'org-format-latex-header)
             (stringp org-format-latex-header)
             (string-match-p
              (regexp-opt '("unicode-math" "setmathfont" "setmainfont"))
              org-format-latex-header)))))

(defun org-fast-latex-preview--lean-preamble (&optional compiler-base extra-preamble)
  "Return the lean default preview preamble for COMPILER-BASE.

EXTRA-PREAMBLE overrides `org-fast-latex-preview-extra-preamble' when
non-nil."
  (concat
   "\\documentclass{article}\n"
   (when (member (or compiler-base (org-fast-latex-preview--manual-compiler-base))
                 '("latex" "pdflatex"))
     "\\usepackage[utf8]{inputenc}\n")
   "\\usepackage{amsmath}\n"
   "\\usepackage{amssymb}\n"
   "\\pagestyle{empty}\n"
   (or extra-preamble org-fast-latex-preview-extra-preamble)
   (unless (string-suffix-p "\n" (or extra-preamble org-fast-latex-preview-extra-preamble))
     "\n")))

(defun org-fast-latex-preview--org-preamble (&optional header packages extra-preamble)
  "Return the resolved Org export preamble for HEADER and PACKAGES.

EXTRA-PREAMBLE overrides `org-fast-latex-preview-extra-preamble' when
non-nil."
  (let ((org-format-latex-header (or header org-format-latex-header))
        (org-latex-packages-alist (or packages org-latex-packages-alist))
        (extra-preamble (or extra-preamble org-fast-latex-preview-extra-preamble)))
    (concat
     (org-latex-make-preamble
      (org-export-get-environment (org-export-get-backend 'latex))
      org-format-latex-header
      'snippet)
     extra-preamble
     (unless (string-suffix-p "\n" extra-preamble)
       "\n"))))

(defun org-fast-latex-preview--context-signature (context)
  "Return a signature that identifies CONTEXT for deduplication."
  (list (org-fast-latex-preview--context-compiler-key context)
        (org-fast-latex-preview--context-input-extension context)
        (org-fast-latex-preview--context-preamble context)))

(defun org-fast-latex-preview--context-from-settings
    (label compiler-base preamble-source &optional header packages extra-preamble)
  "Build a render context from the supplied settings.

LABEL names the context.  COMPILER-BASE and PREAMBLE-SOURCE select the
renderer and preamble style.  HEADER, PACKAGES, and EXTRA-PREAMBLE are
used when building Org-compatible contexts."
  (let* ((appearance (org-fast-latex-preview--effective-appearance-options))
         (compiler (org-fast-latex-preview--compiler-spec-for-base compiler-base))
         (foreground (plist-get appearance :foreground))
         (background (plist-get appearance :background))
         (scale (or (plist-get appearance :scale) 1.0))
         (dpi (float (funcall org-fast-latex-preview-dpi-function)))
         (render-scale (* scale (/ dpi 140.0)))
         (preamble
          (pcase preamble-source
            ('lean
             (org-fast-latex-preview--lean-preamble compiler-base extra-preamble))
            ('org
             (org-fast-latex-preview--org-preamble header packages extra-preamble))
            (other
             (user-error "Unsupported preamble source %S" other)))))
    (org-fast-latex-preview--make-context
     :label label
     :appearance appearance
     :compiler-key (plist-get compiler :key)
     :compiler-command (plist-get compiler :command)
     :compiler-program (plist-get compiler :program)
     :input-extension (plist-get compiler :input-extension)
     :preamble preamble
     :foreground-rgb (org-fast-latex-preview--rgb-components foreground)
     :background-rgb (org-fast-latex-preview--background-rgb-components background)
     :render-scale render-scale
     :cache-directory
     (org-fast-latex-preview--ensure-directory
      org-fast-latex-preview-cache-directory))))

(defun org-fast-latex-preview--dedupe-context-chain (contexts)
  "Return CONTEXTS with duplicate compiler/preamble combinations removed."
  (let ((seen (make-hash-table :test 'equal))
        kept)
    (dolist (context contexts)
      (let ((signature (org-fast-latex-preview--context-signature context)))
        (unless (gethash signature seen)
          (puthash signature t seen)
          (push context kept))))
    (nreverse kept)))

(defun org-fast-latex-preview--resolve-context-chain ()
  "Return the ordered render contexts for the current buffer."
  (pcase org-fast-latex-preview-profile
    ('manual
     (list
      (org-fast-latex-preview--context-from-settings
       "manual"
       (org-fast-latex-preview--manual-compiler-base)
       org-fast-latex-preview-preamble-source
       org-format-latex-header
       org-latex-packages-alist
       org-fast-latex-preview-extra-preamble)))
    ('org-state
     (list
      (org-fast-latex-preview--context-from-settings
       "org-state"
       (org-fast-latex-preview--inferred-compiler-base)
       'org
       org-format-latex-header
       org-latex-packages-alist
       org-fast-latex-preview-extra-preamble)))
    ('scientific-lualatex
     (list
      (org-fast-latex-preview--context-from-settings
       "scientific-lualatex"
       "lualatex"
       'org
       org-fast-latex-preview--scientific-lualatex-header
       org-fast-latex-preview--scientific-lualatex-packages
       org-fast-latex-preview-extra-preamble)))
    (_
     (let ((lean-context
            (org-fast-latex-preview--context-from-settings
             "lean"
             (org-fast-latex-preview--inferred-compiler-base)
             'lean
             nil nil
             org-fast-latex-preview-extra-preamble))
           (org-context
            (org-fast-latex-preview--context-from-settings
             "org-state"
             (org-fast-latex-preview--inferred-compiler-base)
             'org
             org-format-latex-header
             org-latex-packages-alist
             org-fast-latex-preview-extra-preamble)))
       (org-fast-latex-preview--dedupe-context-chain
        (if (org-fast-latex-preview--org-state-customized-p)
            (list org-context lean-context)
          (list lean-context org-context)))))))

(defun org-fast-latex-preview--build-context ()
  "Build the active render context for the current buffer."
  (or (nth org-fast-latex-preview--context-chain-index
           org-fast-latex-preview--context-chain)
      (car (org-fast-latex-preview--resolve-context-chain))))

(provide 'org-fast-latex-preview-core)
;;; org-fast-latex-preview-core.el ends here
