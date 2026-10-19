.PHONY: build test check format lint package install uninstall

build:
	swift build

test:
	./scripts/test.sh

format:
	swift format format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --strict --recursive Sources Tests Package.swift
	for script in scripts/*.sh; do bash -n "$$script" || exit; done
	if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh; fi
	plutil -lint Resources/Info.plist

check: lint test

package:
	./scripts/package_app.sh

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh
