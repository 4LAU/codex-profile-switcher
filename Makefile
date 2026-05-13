SHELL := /bin/bash

BUILD_OUT ?= /tmp/codex-profile-switcher-build-check

.PHONY: build check test test-unit test-integration

build:
	./build.sh "$(BUILD_OUT)"

test: test-unit

test-unit:
	./Tests/run-swift-tests.sh

test-integration:
	@if [[ -x ./Tests/run-integration-tests.sh ]]; then \
		./Tests/run-integration-tests.sh; \
	else \
		echo "No integration test runner exists yet."; \
		echo "Add ./Tests/run-integration-tests.sh when helper integration tests are Keychain-safe."; \
	fi

check: test build
