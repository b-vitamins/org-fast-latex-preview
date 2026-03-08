EMACS ?= emacs
PYTHON ?= python3
LISPDIR := lisp
TESTDIR := test
STRESSDIR := stress
STRESS_GENERATED := $(STRESSDIR)/generated
STRESS_RESULTS := $(STRESSDIR)/results
COMPILER ?= latex

.PHONY: compile python-test test lint-checkdoc lint-elint lint-package lint check \
	stress-generate stress-bench stress-check stress-chaos stress-soak

compile:
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t byte-compile-error-on-warn t)" -f batch-byte-compile $(LISPDIR)/*.el

python-test:
	$(PYTHON) $(TESTDIR)/generate-corpus-test.py

test: python-test
	$(EMACS) -Q --batch -L $(LISPDIR) -L $(TESTDIR) --eval "(setq load-prefer-newer t)" \
		-l $(TESTDIR)/org-fast-latex-preview-test-support.el \
		-l $(TESTDIR)/org-fast-latex-preview-cache-test.el \
		-l $(TESTDIR)/org-fast-latex-preview-ui-test.el \
		-l $(TESTDIR)/org-fast-latex-preview-render-test.el \
		-l $(TESTDIR)/org-fast-latex-preview-test.el \
		-f ert-run-tests-batch-and-exit

lint-checkdoc:
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t)" \
		-l scripts/checkdoc.el -- \
		$(LISPDIR)/*.el

lint-elint:
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t)" \
		-l scripts/elint.el -- \
		$(LISPDIR)/*.el

lint-package:
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t)" \
		-l scripts/package-lint.el -- \
		$(LISPDIR)/org-fast-latex-preview.el

lint: lint-checkdoc lint-package lint-elint

check: compile test lint-checkdoc lint-package

stress-generate:
	$(PYTHON) scripts/generate-corpus.py --output-dir $(STRESS_GENERATED) $(if $(PROFILE),--profile $(PROFILE),)

stress-bench:
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t)" -l scripts/bench.el -- \
		--manifest $(STRESS_GENERATED)/manifest.json \
		--results-dir $(STRESS_RESULTS) \
		--compiler $(COMPILER) \
		$(if $(PROFILE),--profile $(PROFILE),)

stress-check: stress-generate stress-bench

stress-chaos: stress-generate
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t)" -l scripts/bench.el -- \
		--manifest $(STRESS_GENERATED)/manifest.json \
		--results-dir $(STRESS_RESULTS) \
		--compiler $(COMPILER) \
		--chaos \
		$(if $(PROFILE),--profile $(PROFILE),--profile edit-churn-10k)

SOAK_CYCLES ?= 12

stress-soak: stress-generate
	$(EMACS) -Q --batch -L $(LISPDIR) --eval "(setq load-prefer-newer t)" -l scripts/bench.el -- \
		--manifest $(STRESS_GENERATED)/manifest.json \
		--results-dir $(STRESS_RESULTS) \
		--compiler $(COMPILER) \
		--chaos \
		--soak-cycles $(SOAK_CYCLES) \
		$(if $(PROFILE),--profile $(PROFILE),--profile edit-churn-10k)
