# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project follows [Semantic Versioning](https://semver.org).

## [Unreleased]

### Fixed
- CI now installs the LaTeX `preview` package required by the render pipeline
  and documents that dependency explicitly.
- CI byte-compilation now passes on runner Emacs builds by fixing a wrapped
  docstring and declaring `max-image-size` for the compiler.

## [0.1.0] - Pending

Initial public release of `org-fast-latex-preview`.

### Added
- Asynchronous batched SVG LaTeX previews for Org buffers.
- Persistent on-disk cache with cache validation and corruption recovery.
- Adaptive scheduling with resilient fallback for hostile corpora.
- Aggregated failure reporting instead of per-fragment buffer spam.
- Dirty-range refresh, reveal-at-point behavior, and lifecycle teardown.
- Stress corpus generation plus benchmark, chaos, and soak harnesses.
- ERT and Python regression coverage for render, cache, UI, and stress tooling.

### Changed
- Default context resolution now follows native Org preview state via `auto`.
- OFLP command interception is now strictly mode-local and non-intrusive.

### Fixed
- Removed silent command remapping when Org-command interception is disabled.
- Hardened cache recovery, buffer teardown, revert handling, and failure splitting.
