SHELL := /bin/bash

BUILD_OUT ?= /tmp/codex-profile-switcher-build-check
APP_IDENTITY ?= Developer ID Application: Aaron Lau (W3ZHLSH96F)
CLI_INSTALL_PATH ?= $(HOME)/.local/bin/codex-profile

.PHONY: build check test test-unit test-integration format install-cli

# Installs the CLI signed with a stable Developer ID identity. This loose CLI
# is file-vault-only: it intentionally lacks the packaged helper's Keychain
# Sharing entitlement and cannot access the packaged app's Keychain vault.
# Never copy a raw `swift build` binary to ~/.local/bin.
install-cli:
	swift build -c release --product codex-profile
	cp "$$(swift build -c release --show-bin-path)/codex-profile" "$(CLI_INSTALL_PATH)"
	codesign --force --options runtime --identifier codex-profile \
		--sign "$(APP_IDENTITY)" "$(CLI_INSTALL_PATH)"
	codesign --verify "$(CLI_INSTALL_PATH)"

# Requires swiftformat (brew install swiftformat). Config lives in .swiftformat.
format:
	swiftformat .

build:
	./build.sh "$(BUILD_OUT)"

test: test-unit test-integration

test-unit:
	./Tests/run-swift-tests.sh

test-integration:
	./Tests/run-integration-tests.sh

check: test build
