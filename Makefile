SHELL := /bin/bash

.PHONY: help setup fmt lint test check audit flutter-analyze flutter-test release-linux-local release-gate workflow-hygiene canary canary-mutations

help:
	@echo "Photo Organizer dev targets:"
	@echo "  fmt                cargo fmt --check"
	@echo "  lint               cargo clippy -D warnings"
	@echo "  test               cargo test (Rust workspace)"
	@echo "  check              scripts/dev-check.sh (Rust + Flutter + structural tests + release gate)"
	@echo "  audit              cargo audit"
	@echo "  flutter-analyze    flutter analyze (app/)"
	@echo "  flutter-test       flutter test (app/)"
	@echo "  release-gate       tests for the Android artifact/signing release gate"
	@echo "  release-linux-local build daemon + Flutter Linux bundle (scripts/build_linux_release.sh)"
	@echo "  workflow-hygiene   structural tests for .github/workflows (triggers, pins, timeouts, permissions)"
	@echo "  canary             tests for the schedule/liveness canary (scripts/canary_liveness.sh)"
	@echo "  canary-mutations   prove the canary suite's assertions fail when the logic is broken"

setup:
	@echo "Dependencies: stable Rust toolchain (rust-toolchain.toml), Flutter stable,"
	@echo "and the libsecret/dbus/gtk dev packages listed in .github/workflows/release.yml."

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