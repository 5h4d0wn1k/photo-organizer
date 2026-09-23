SHELL := /bin/bash

.PHONY: help setup fmt lint test check audit flutter-analyze flutter-test release-linux-local

help:
	@echo "Photo Organizer dev targets:"
	@echo "  fmt                cargo fmt --check"
	@echo "  lint               cargo clippy -D warnings"
	@echo "  test               cargo test (Rust workspace)"
	@echo "  check              scripts/dev-check.sh (Rust + Flutter when available)"
	@echo "  audit              cargo audit"
	@echo "  flutter-analyze    flutter analyze (app/)"
	@echo "  flutter-test       flutter test (app/)"
	@echo "  release-linux-local build daemon + Flutter Linux bundle (scripts/build_linux_release.sh)"

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

release-linux-local:
	./scripts/build_linux_release.sh