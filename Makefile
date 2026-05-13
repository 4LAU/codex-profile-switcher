SHELL := /bin/bash

BUILD_OUT ?= /tmp/codex-profile-switcher-build-check

.PHONY: build check test test-unit test-integration

build:
	./build.sh "$(BUILD_OUT)"

test: test-unit test-integration

test-unit:
	./Tests/run-swift-tests.sh

test-integration:
	./Tests/run-integration-tests.sh

check: test build
