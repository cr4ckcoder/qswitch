PREFIX ?= $(HOME)/.local
BIN := .build/release/qswitch

.PHONY: build release install uninstall test clean

build:
	swift build

release:
	swift build -c release

install: release
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/qswitch

uninstall:
	rm -f $(PREFIX)/bin/qswitch

test: build
	scripts/e2e.sh .build/debug/qswitch

clean:
	rm -rf .build
