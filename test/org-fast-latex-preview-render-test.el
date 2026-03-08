;;; org-fast-latex-preview-render-test.el --- Render pipeline unit tests -*- lexical-binding: t; -*-

;;; Code:

(require 'org-fast-latex-preview-test-support)
(require 'org-fast-latex-preview)

(ert-deftest org-fast-latex-preview-collects-fragments ()
  (let ((org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "Inline $E=mc^2$.\n\n\\begin{equation}\n\\int_0^1 x^2\\,dx = 1/3\n\\end{equation}\n"
      (let* ((context (org-fast-latex-preview--build-context))
             (fragments (org-fast-latex-preview--collect-fragments
                         (point-min) (point-max) context)))
        (should (= 2 (length fragments)))
        (should (string= "$E=mc^2$"
                         (org-fast-latex-preview--fragment-source
                          (nth 0 fragments))))
        (should-not (org-fast-latex-preview--fragment-begin-marker
                     (nth 0 fragments)))
        (should-not (org-fast-latex-preview--fragment-end-marker
                     (nth 0 fragments)))
        (should (string-match-p
                 "\\\\begin{equation}"
                 (org-fast-latex-preview--fragment-source
                  (nth 1 fragments))))))))

(ert-deftest org-fast-latex-preview-collects-bracket-displays-as-whole-fragments ()
  (let ((org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-compiler 'latex))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "Display:\n\\[\\frac{K}{\\xi_t^2}=t+4u\\bar{m}^2=\n\\begin{cases}\nt & \\text{for } t>0,\\\\\n0 & \\text{for } t<0.\n\\end{cases}\n\\label{eq-demo}\\]\n"
      (let* ((context (org-fast-latex-preview--build-context))
             (fragments (org-fast-latex-preview--collect-fragments
                         (point-min) (point-max) context)))
        (should (= 1 (length fragments)))
        (should (string-prefix-p
                 "\\[\\frac{K}{\\xi_t^2}"
                 (org-fast-latex-preview--fragment-source
                  (car fragments))))
        (should (string-match-p
                 "\\\\begin{cases}"
                 (org-fast-latex-preview--fragment-source
                  (car fragments))))
        (should (string-suffix-p
                 "\\label{eq-demo}\\]"
                 (org-fast-latex-preview--fragment-source
                  (car fragments))))))))

(ert-deftest org-fast-latex-preview-auto-profile-prefers-org-state-for-customized-preview-setup ()
  (let ((org-fast-latex-preview-profile 'auto)
        (org-fast-latex-preview-compiler nil)
        (org-preview-latex-default-process 'luamagick)
        (org-preview-latex-process-alist
         '((luamagick :latex-compiler ("lualatex -interaction nonstopmode -output-directory %o %f"))))
        (org-latex-packages-alist '(("" "physics" t)))
        (org-format-latex-header
         "\\documentclass{article}\n[DEFAULT-PACKAGES]\n[PACKAGES]\n\\usepackage{unicode-math}\n\\setmathfont{TeX Gyre Pagella Math}\n"))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$x$"
      (let ((chain (org-fast-latex-preview--resolve-context-chain)))
        (should (equal "org-state"
                       (org-fast-latex-preview--context-label (car chain))))
        (should (eq 'dvilualatex
                    (org-fast-latex-preview--context-compiler-key
                     (car chain))))
        (should (string-match-p
                 "unicode-math"
                 (org-fast-latex-preview--context-preamble
                  (car chain))))))))

(ert-deftest org-fast-latex-preview-scientific-lualatex-profile-builds-preset-context ()
  (let ((org-fast-latex-preview-profile 'scientific-lualatex))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$x$"
      (let ((chain (org-fast-latex-preview--resolve-context-chain)))
        (should (= 1 (length chain)))
        (should (equal "scientific-lualatex"
                       (org-fast-latex-preview--context-label (car chain))))
        (should (eq 'dvilualatex
                    (org-fast-latex-preview--context-compiler-key
                     (car chain))))
        (should (string-match-p
                 "unicode-math"
                 (org-fast-latex-preview--context-preamble
                  (car chain))))
        (should (string-match-p
                 "TeX Gyre Pagella"
                 (org-fast-latex-preview--context-preamble
                  (car chain))))))))

(ert-deftest org-fast-latex-preview-inherits-org-scale-by-default ()
  (let ((org-fast-latex-preview-profile 'manual)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-appearance-options '(:page-width nil))
        (org-format-latex-options '(:scale 2.5))
        (org-fast-latex-preview-dpi-function (lambda () 140.0)))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$x$"
      (let ((context (org-fast-latex-preview--build-context)))
        (should (= 2.5
                   (org-fast-latex-preview--context-render-scale context)))
        (should (= 2.5
                   (plist-get
                    (org-fast-latex-preview--context-appearance context)
                    :scale)))))))

(ert-deftest org-fast-latex-preview-explicit-appearance-scale-overrides-org-scale ()
  (let ((org-fast-latex-preview-profile 'manual)
        (org-fast-latex-preview-compiler 'latex)
        (org-fast-latex-preview-preamble-source 'lean)
        (org-fast-latex-preview-appearance-options '(:scale 1.5 :page-width nil))
        (org-format-latex-options '(:scale 2.5))
        (org-fast-latex-preview-dpi-function (lambda () 140.0)))
    (org-fast-latex-preview-test--with-temp-org-buffer
        "$x$"
      (let ((context (org-fast-latex-preview--build-context)))
        (should (= 1.5
                   (org-fast-latex-preview--context-render-scale context)))
        (should (= 1.5
                   (plist-get
                    (org-fast-latex-preview--context-appearance context)
                    :scale)))))))

(ert-deftest org-fast-latex-preview-enqueue-batch-ensures-fragment-markers ()
  (let ((source-buffer (generate-new-buffer " *oflp-marker-source*"))
        started-fragments)
    (unwind-protect
        (with-current-buffer source-buffer
          (let* ((fragment (org-fast-latex-preview--make-fragment
                            :beg 3
                            :end 7
                            :source "$x$"
                            :cache-key "demo"
                            :cache-file "/tmp/demo.svg"))
                 (org-fast-latex-preview-max-concurrent-jobs nil))
            (cl-letf (((symbol-function 'org-fast-latex-preview--start-batch)
                       (lambda (fragments _context _generation &optional _replace-existing)
                         (setq started-fragments fragments))))
              (org-fast-latex-preview--enqueue-batch (list fragment) 'context 1))
            (should started-fragments)
            (should (markerp (org-fast-latex-preview--fragment-begin-marker
                              (car started-fragments))))
            (should (markerp (org-fast-latex-preview--fragment-end-marker
                              (car started-fragments))))))
      (kill-buffer source-buffer))))

(ert-deftest org-fast-latex-preview-partitions-fragments-by-batch-size ()
  (let ((org-fast-latex-preview-batch-size 2))
    (should (equal '((a b) (c d) (e))
                   (org-fast-latex-preview--partition-fragments
                    '(a b c d e))))))

(ert-deftest org-fast-latex-preview-adaptive-plan-prefers-throughput-for-large-bulk-renders ()
  (let ((org-fast-latex-preview-scheduler 'adaptive)
        (org-fast-latex-preview-adaptive-fragment-threshold 4)
        (org-fast-latex-preview-throughput-batch-size 2500)
        (org-fast-latex-preview-throughput-max-concurrent-jobs 2))
    (let ((plan (org-fast-latex-preview--plan-for-render 9 4 nil)))
      (should (eq 'throughput
                  (org-fast-latex-preview--plan-mode plan)))
      (should (= 2500
                 (org-fast-latex-preview--plan-batch-size plan)))
      (should (= 2
                 (org-fast-latex-preview--plan-max-concurrent-jobs plan)))
      (should-not (org-fast-latex-preview--plan-replace-existing-overlays plan))
      (should-not (org-fast-latex-preview--plan-fallback-triggered plan)))))

(ert-deftest org-fast-latex-preview-adaptive-plan-keeps-dirty-refreshes-resilient ()
  (let ((org-fast-latex-preview-scheduler 'adaptive)
        (org-fast-latex-preview-adaptive-fragment-threshold 2)
        (org-fast-latex-preview-batch-size 8)
        (org-fast-latex-preview-max-concurrent-jobs 1))
    (let ((plan (org-fast-latex-preview--plan-for-render 11 50 t t)))
      (should (eq 'resilient
                  (org-fast-latex-preview--plan-mode plan)))
      (should (= 8
                 (org-fast-latex-preview--plan-batch-size plan)))
      (should (= 1
                 (org-fast-latex-preview--plan-max-concurrent-jobs plan)))
      (should (org-fast-latex-preview--plan-replace-existing-overlays plan))
      (should-not (org-fast-latex-preview--plan-fallback-triggered plan)))))

(ert-deftest org-fast-latex-preview-removes-jobs-from-source-buffer ()
  (let ((source-buffer (generate-new-buffer " *oflp-source-test*"))
        (log-buffer (generate-new-buffer " *oflp-log-test*")))
    (unwind-protect
        (let ((job (org-fast-latex-preview--make-job
                    :buffer source-buffer
                    :generation 1
                    :fragments nil
                    :context nil
                    :temp-directory nil
                    :log-buffer log-buffer)))
          (with-current-buffer source-buffer
            (setq org-fast-latex-preview--jobs (list job)))
          (with-current-buffer log-buffer
            (org-fast-latex-preview--remove-job job))
          (with-current-buffer source-buffer
            (should-not org-fast-latex-preview--jobs)))
      (kill-buffer source-buffer)
      (kill-buffer log-buffer))))

(ert-deftest org-fast-latex-preview-enqueues-batches-at-concurrency-limit ()
  (let ((org-fast-latex-preview-max-concurrent-jobs 1)
        (source-buffer (generate-new-buffer " *oflp-queue-source*"))
        (log-buffer (generate-new-buffer " *oflp-queue-log*")))
    (unwind-protect
        (let ((job (org-fast-latex-preview--make-job
                    :buffer source-buffer
                    :generation 1
                    :fragments nil
                    :context nil
                    :temp-directory nil
                    :log-buffer log-buffer))
              (fragment (org-fast-latex-preview--make-fragment
                         :beg 1
                         :end 5
                         :source "$x$"
                         :cache-key "demo"
                         :cache-file "/tmp/demo.svg")))
          (with-current-buffer source-buffer
            (setq org-fast-latex-preview--jobs (list job)
                  org-fast-latex-preview--pending-batches nil)
            (org-fast-latex-preview--enqueue-batch (list fragment) 'context 7)
            (should (= 1 (length org-fast-latex-preview--pending-batches)))
            (should (= 1 (length org-fast-latex-preview--jobs)))))
      (kill-buffer source-buffer)
      (kill-buffer log-buffer))))

(ert-deftest org-fast-latex-preview-throughput-fallback-requeues-unresolved-work ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "A $x$.\nB $y$.\nC $z$.\n"
    (let* ((org-fast-latex-preview--generation 12)
           (org-fast-latex-preview-batch-size 2)
           (org-fast-latex-preview-max-concurrent-jobs 1)
           (plan (org-fast-latex-preview--make-throughput-plan 12 nil))
           (failing-job (org-fast-latex-preview--make-job
                         :buffer (current-buffer)
                         :generation 12
                         :fragments '(f1 f2 f3)
                         :plan plan
                         :context 'ctx
                         :placed-count 1))
           (active-job (org-fast-latex-preview--make-job
                        :buffer (current-buffer)
                        :generation 12
                        :fragments '(g1 g2)
                        :plan plan
                        :context 'ctx
                        :placed-count 1))
           queued-batches
           canceled-jobs)
      (setq org-fast-latex-preview--jobs (list active-job)
            org-fast-latex-preview--pending-batches
            (list (list '(p1 p2) 'ctx 12 plan)))
      (cl-letf (((symbol-function 'org-fast-latex-preview--enqueue-batch)
                 (lambda (fragments _context _generation &optional passed-plan)
                   (push (list fragments passed-plan) queued-batches)))
                ((symbol-function 'org-fast-latex-preview--cancel-job)
                 (lambda (job)
                   (push job canceled-jobs)
                   (setf (org-fast-latex-preview--job-canceled job) t))))
        (should (org-fast-latex-preview--fallback-to-resilient-plan failing-job)))
      (setq queued-batches (nreverse queued-batches))
      (should (eq 'resilient
                  (org-fast-latex-preview--plan-mode plan)))
      (should (org-fast-latex-preview--plan-fallback-triggered plan))
      (should (= org-fast-latex-preview-batch-size
                 (org-fast-latex-preview--plan-batch-size plan)))
      (should (= org-fast-latex-preview-max-concurrent-jobs
                 (org-fast-latex-preview--plan-max-concurrent-jobs plan)))
      (should (org-fast-latex-preview--plan-replace-existing-overlays plan))
      (should (equal (list (list '(f2 f3) plan)
                           (list '(p1 p2) plan)
                           (list '(g2) plan))
                     queued-batches))
      (should (equal (list active-job) canceled-jobs))
      (should-not org-fast-latex-preview--jobs)
      (should-not org-fast-latex-preview--pending-batches))))

(ert-deftest org-fast-latex-preview-context-promotion-rerenders-whole-range ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Equation \\[\\begin{cases}\na & b\n\\end{cases}\\]\n"
    (let* ((org-fast-latex-preview--generation 5)
           (first-context (org-fast-latex-preview--make-context :label "lean"))
           (second-context (org-fast-latex-preview--make-context :label "org-state"))
           (job (org-fast-latex-preview--make-job
                 :buffer (current-buffer)
                 :generation 5
                 :fragments '(old)
                 :context first-context))
           collected
           preview-call)
      (setq org-fast-latex-preview--context-chain (list first-context second-context)
            org-fast-latex-preview--context-chain-index 0
            org-fast-latex-preview--generation-range (cons (point-min) (point-max)))
      (cl-letf (((symbol-function 'org-fast-latex-preview--drain-pending-batches)
                 (lambda (_generation) nil))
                ((symbol-function 'org-fast-latex-preview--cancel-generation-jobs)
                 (lambda (_generation) nil))
                ((symbol-function 'org-fast-latex-preview-clear)
                 (lambda (&rest _args) nil))
                ((symbol-function 'org-fast-latex-preview--reset-failure-report)
                 (lambda () nil))
                ((symbol-function 'org-fast-latex-preview--collect-fragments)
                 (lambda (beg end context)
                   (setq collected (list beg end context))
                   '(new-fragment)))
                ((symbol-function 'org-fast-latex-preview--preview-fragments)
                 (lambda (fragments context refresh &optional profile plan)
                   (setq preview-call (list fragments context refresh profile plan))
                   '(:cached 0 :queued 1))))
        (should (org-fast-latex-preview--promote-context job)))
      (should (= 1 org-fast-latex-preview--context-chain-index))
      (should (eq second-context (nth 2 collected)))
      (should (equal '(new-fragment) (nth 0 preview-call)))
      (should (eq second-context (nth 1 preview-call)))
      (should-not (nth 2 preview-call)))))

(ert-deftest org-fast-latex-preview-groups-failures-by-stage-and-summary ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "First $x$.\nSecond $y$.\nThird $z$.\n"
    (let ((org-fast-latex-preview--generation 7))
      (setq org-fast-latex-preview--failure-report
            (org-fast-latex-preview--make-failure-report
             :generation 7
             :instances
             (list
              (org-fast-latex-preview--make-failure-instance
               :generation 7
               :stage "LaTeX"
               :summary "Undefined control sequence"
               :internal nil
               :source "$x$"
               :begin-marker (copy-marker 7)
               :end-marker (copy-marker 10 t))
              (org-fast-latex-preview--make-failure-instance
               :generation 7
               :stage "LaTeX"
               :summary "Undefined control sequence"
               :internal nil
               :source "$y$"
               :begin-marker (copy-marker 19)
               :end-marker (copy-marker 22 t))
              (org-fast-latex-preview--make-failure-instance
               :generation 7
               :stage "dvisvgm"
               :summary "Conversion failed"
               :internal nil
               :source "$z$"
               :begin-marker (copy-marker 32)
               :end-marker (copy-marker 35 t)))))
      (let ((groups (org-fast-latex-preview--failure-groups
                     (org-fast-latex-preview--failure-report-instances
                      org-fast-latex-preview--failure-report))))
        (should (= 2 (length groups)))
        (should (equal "LaTeX" (plist-get (car groups) :stage)))
        (should (= 2 (plist-get (car groups) :count)))
        (should (equal "dvisvgm" (plist-get (cadr groups) :stage)))
        (should (= 1 (plist-get (cadr groups) :count)))))))

(ert-deftest org-fast-latex-preview-removes-stale-failures-in-dirty-range ()
  (org-fast-latex-preview-test--with-temp-org-buffer
      "Bad $\\badone$.\nGood $E=mc^2$.\nBad $\\badtwo$.\n"
    (let ((org-fast-latex-preview--generation 3))
      (setq org-fast-latex-preview--failure-report
            (org-fast-latex-preview--make-failure-report
             :generation 3
             :instances
             (list
              (org-fast-latex-preview--make-failure-instance
               :generation 3
               :stage "LaTeX"
               :summary "Undefined control sequence"
               :internal nil
               :source "$\\badone$"
               :begin-marker (copy-marker 5)
               :end-marker (copy-marker 14 t))
              (org-fast-latex-preview--make-failure-instance
               :generation 3
               :stage "LaTeX"
               :summary "Undefined control sequence"
               :internal nil
               :source "$\\badtwo$"
               :begin-marker (copy-marker 33)
               :end-marker (copy-marker 42 t)))))
      (org-fast-latex-preview--render-failure-report)
      (org-fast-latex-preview--remove-failure-instances-in-range 1 20)
      (let ((instances
             (org-fast-latex-preview--failure-report-instances
              org-fast-latex-preview--failure-report)))
        (should (= 1 (length instances)))
        (should (equal "$\\badtwo$"
                       (org-fast-latex-preview--failure-instance-source
                        (car instances))))))
    (org-fast-latex-preview-test--cleanup-failure-buffers)))

(provide 'org-fast-latex-preview-render-test)
;;; org-fast-latex-preview-render-test.el ends here
