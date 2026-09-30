SHELL := /bin/bash

.PHONY: help setup deps fmt lint test check audit flutter-analyze flutter-test release-linux-local release-gate workflow-hygiene workflow-hygiene-mutations canary canary-mutations

help:
	@echo "Photo Organizer dev targets:"
	@echo "  fmt                cargo fmt --check"
	@echo "  lint               cargo clippy -D warnings"
	@echo "  test               cargo test (Rust workspace)"
	@echo "  check              scripts/dev-check.sh (Rust + Flutter + release gate when available)"
	@echo "  deps               install the hash-pinned test dependencies (scripts/requirements-test.txt)"
	@echo "  audit              cargo audit"
	@echo "  flutter-analyze    flutter analyze (app/)"
	@echo "  flutter-test       flutter test (app/)"
	@echo "  release-gate       tests for the Android artifact/signing release gate"
	@echo "  release-linux-local build daemon + Flutter Linux bundle (scripts/build_linux_release.sh)"
	@echo "  workflow-hygiene   structural tests for .github/workflows (triggers, pins, timeouts, permissions)"
	@echo "  workflow-hygiene-mutations  prove those structural assertions fail when CI wiring drifts"
	@echo "  canary             tests for the schedule/liveness canary (scripts/canary_liveness.sh)"
	@echo "  canary-mutations   prove the canary suite's assertions fail when the logic is broken"

setup:
	@echo "Dependencies: stable Rust toolchain (rust-toolchain.toml), Flutter stable,"
	@echo "and the libsecret/dbus/gtk dev packages listed in .github/workflows/release.yml."

# The suites under scripts/tests/ parse YAML, so they need PyYAML. It is declared
# and hash-pinned in scripts/requirements-test.txt and installed here (and once
# per CI job) rather than by the suites themselves -- issue #136.
#
# CPython 3.8-3.13, on a FRESH environment. PyYAML 6.0.2 publishes no 3.14 wheel
# and the install is --only-binary on purpose, so an unsupported interpreter is
# refused rather than silently compiling the sdist into a different artifact than
# every hash in the file authorises. "Fresh" is not a nicety: if PyYAML is already
# installed, pip reports "Requirement already satisfied" and exits 0 without
# resolving a wheel, so neither flag are exercised. To exercise them, use a new
# venv -- which is what `make venv` is for.
#
# `make deps` prefers .venv-test when it exists. On a host whose default python3 is
# outside the supported range, telling the reader to run `make deps` without also
# giving them a way to succeed is an instruction that cannot be followed, so both
# the target and the suites' fail-closed messages point at `make venv`.
VENV := .venv-test
VENV_PY := $(VENV)/bin/python
VENV_MIN_MINOR := 8
VENV_MAX_MINOR := 13

# "Is this interpreter one the pin has a wheel for", as an exit status. Used by
# both $(shell) probes below, so the rule is written once.
define in_range_check
import sys; raise SystemExit(0 if sys.version_info[0] == 3 and $(VENV_MIN_MINOR) <= sys.version_info[1] <= $(VENV_MAX_MINOR) else 1)
endef

SYS_PY_OK := $(shell command -v python3 >/dev/null 2>&1 && python3 -c '$(in_range_check)' >/dev/null 2>&1 && echo yes || echo no)
VENV_PY_OK := $(shell test -x '$(VENV_PY)' && '$(VENV_PY)' -c '$(in_range_check)' >/dev/null 2>&1 && echo yes || echo no)
# The venv wins when it exists and is usable, because it is the interpreter the
# hash-pinned install is meant to run under. Otherwise fall back to the system one.
# Evaluated when the Makefile is read, so `make venv && make deps` in one shell
# works: the second make re-reads this and sees the venv.
DEPS_PY_OK := $(if $(filter yes,$(VENV_PY_OK)),yes,$(SYS_PY_OK))

venv:
	@echo "Looking for a CPython 3.$(VENV_MIN_MINOR)-3.$(VENV_MAX_MINOR) interpreter"
	@interpreter=""; \
	for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3 python; do \
	  path="$$(command -v "$$candidate" 2>/dev/null)" || continue; \
	  major="$$("$$path" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" || continue; \
	  minor="$$("$$path" -c 'import sys; print(sys.version_info[1])' 2>/dev/null)" || continue; \
	  if [ "$$major" = "3" ] && [ "$$minor" -ge "$(VENV_MIN_MINOR)" ] && [ "$$minor" -le "$(VENV_MAX_MINOR)" ]; then \
	    interpreter="$$path"; \
	    echo "  found $$path (3.$$minor)"; \
	    break; \
	  fi; \
	done; \
	if [ -z "$$interpreter" ]; then \
	  echo "  none found. This host has no CPython 3.$(VENV_MIN_MINOR)-3.$(VENV_MAX_MINOR)," >&2; \
	  echo "  and PyYAML 6.0.2 publishes no wheel outside that range, so the" >&2; \
	  echo "  hash-pinned suites cannot be provisioned here. Install one, or bump" >&2; \
	  echo "  the pin in scripts/requirements-test.txt to a version with a wheel" >&2; \
	  echo "  for your interpreter." >&2; \
	  exit 1; \
	fi; \
	rm -rf "$(VENV)"; \
	"$$interpreter" -m venv "$(VENV)" || exit 1; \
	echo "  created $(VENV) with $$interpreter"; \
	echo "  now run: make deps"

deps:
ifeq ($(DEPS_PY_OK),yes)
	@if [ -x "$(VENV_PY)" ]; then py="$(VENV_PY)"; else py="python3"; fi; \
	echo "  $$ $$py -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r scripts/requirements-test.txt"; \
	"$$py" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: \
		-r scripts/requirements-test.txt
else
	@echo "  python3 is $$("$$(command -v python3)" -c 'import sys; print("CPython %d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)," >&2
	@echo "  which is outside the supported range CPython 3.$(VENV_MIN_MINOR)-3.$(VENV_MAX_MINOR): PyYAML 6.0.2 publishes" >&2
	@echo "  no wheel outside it, and the install is --only-binary on purpose." >&2
	@echo "" >&2
	@echo "  Run 'make venv' to create a supported interpreter, then 'make deps'." >&2
	@exit 1
endif

fmt:
	cargo fmt --all -- --check

lint:
	cargo clippy --all-targets --all-features --locked -- -D warnings

test:
	cargo test --locked

check:
	./scripts/dev-check.sh

audit:
	cargo audit

flutter-analyze:
	cd app && flutter analyze

flutter-test:
	cd app && flutter test

release-gate:
	./scripts/tests/run_release_gate_tests.sh

release-linux-local:
	./scripts/build_linux_release.sh

workflow-hygiene:
	bash scripts/tests/workflow_hygiene_test.sh

# Proves the hygiene assertions fail when a pin, a version comment or the
# dependabot grouping is broken. 3.6s, and it runs in CI too.
workflow-hygiene-mutations:
	bash scripts/tests/workflow_hygiene_mutation_test.sh

# Every suite under scripts/tests/ is executed by some required check. This exists
# because three assertions in this repository were satisfied by a suite being
# *mentioned* -- in a step label, in a comment, or in the ShellCheck argument list
# (itself a `run:` block) -- rather than run. Runs in CI too.
test-wiring:
	bash scripts/tests/tests_wiring_test.sh

# The generator suite's own mutation pass, plus the wiring check. Offline, seconds.
test-deps-mutations:
	bash scripts/tests/gen_test_requirements_mutation_test.sh

canary:
	bash scripts/tests/canary_liveness_test.sh

# Project-board parsing, its helpers, and the wiring between them (issue #107).
# The two wiring suites exist because the parser and helper logic were once
# inline in the workflow, where nothing could test them; the mutation harnesses
# exist because a wiring suite is easy to write assertions into that are
# satisfied by the comments documenting the very bug they describe.
project-board:
	bash scripts/tests/project_board_refs_test.sh
	node --test scripts/tests/project_board_graphql_test.js
	bash scripts/tests/project_board_workflow_test.sh

# Not part of `make check`: each re-runs its suite once per mutation, so they
# cost minutes. They exist because "the tests pass" means nothing until you have
# watched a test fail for the right reason.
canary-mutations:
	bash scripts/tests/canary_mutation_test.sh

project-board-mutations:
	bash scripts/tests/project_board_refs_mutation_test.sh
	bash scripts/tests/project_board_workflow_mutation_test.sh