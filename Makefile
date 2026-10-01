SHELL := /bin/sh
RUBY ?= ruby
PREFIX ?= $(HOME)/.local
APP_HOME ?= $(PREFIX)/share/cronbar
BIN_DIR ?= $(PREFIX)/bin
SOLVERFORGE_PATH ?= $(HOME)/.local/share/solverforge
DIST_DIR ?= $(CURDIR)/dist
export PREFIX APP_HOME BIN_DIR SOLVERFORGE_PATH DIST_DIR
RELEASE_AS ?=
RELEASE_ARGS = $(if $(RELEASE_AS),--release-as $(RELEASE_AS),)
RELEASE_TOOL = node_modules/.bin/commit-and-tag-version
.DEFAULT_GOAL := help
.PHONY: help check test syntax lint install-user install-solverforge uninstall dist release-check release-dry-run release release-first release-deps release-ready
help:
	@printf '%s\n' 'CronBar targets:' \
	 '  check / release-check  Ruby/JS syntax, all tests, isolated CLI/install/archive smoke' \
	 '  test                   Run every test/*_test.rb (no desktop launch)' \
	 '  syntax                 Check each Ruby file, bin entrypoints, release config' \
	 '  lint                   Strict local QML lint; requires qmllint + QuickShell imports' \
	 '  install-user           Install under PREFIX (default ~/.local)' \
	 '  install-solverforge    Install Waybar wrapper only; run install-user first' \
	 '  uninstall              Remove owned app/link/wrapper; preserve config/state/gate' \
	 '  dist                   Build dist/cronbar-VERSION.tar.gz and SHA256 sidecar' \
	 '  release-dry-run        Gate, then preview release (RELEASE_AS=x.y.z optional)' \
	 '  release-first          Gate, generate first changelog/commit/tag without bump' \
	 '  release                Gate, bump both surfaces, generate changelog/commit/tag' \
	 '                         Release requires clean committed tree; never pushes.'
test:
	$(RUBY) -Itest test/run.rb
syntax:
	$(RUBY) bin/release-check --syntax
lint:
	@command -v qmllint >/dev/null || { printf '%s\n' 'qmllint is required (with resolvable QuickShell imports)' >&2; exit 1; }
	qmllint frontend/quickshell/shell.qml
check release-check:
	$(RUBY) bin/release-check
install-user:
	$(RUBY) bin/release-check --install
install-solverforge:
	$(RUBY) bin/release-check --install-solverforge
uninstall:
	$(RUBY) bin/release-check --uninstall
dist:
	$(RUBY) bin/release-check --dist
release-deps:
	npm ci --include=dev --ignore-scripts --no-audit --no-fund
release-ready:
	@git rev-parse --is-inside-work-tree >/dev/null
	@test -z "$$(git status --porcelain)" || { printf '%s\n' 'Release requires a clean, committed worktree' >&2; exit 1; }
release-dry-run: release-ready release-check release-deps
	@if test -z "$(RELEASE_AS)" && test -z "$$(git tag -l 'v*')"; then \
	  $(RELEASE_TOOL) --first-release --dry-run; \
	else \
	  $(RELEASE_TOOL) --dry-run $(RELEASE_ARGS); \
	fi
release: release-ready release-check release-deps
	$(RELEASE_TOOL) $(RELEASE_ARGS)
release-first: release-ready release-check release-deps
	@test -z "$$(git tag -l 'v*')" || { printf '%s\n' 'First release requires no existing v* tags' >&2; exit 1; }
	$(RELEASE_TOOL) --first-release
