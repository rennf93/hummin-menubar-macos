BIN ?= $(HOME)/colibri/bin/hummin-menubar
AGENT ?= com.hummin.menubar

.PHONY: build install run clean

build:
	swift build -c release

install: build
	@mkdir -p $(dir $(BIN))
	cp .build/release/HumminMenubar $(BIN)
	@launchctl kickstart -k gui/501/$(AGENT) 2>/dev/null || true
	@echo "installed to $(BIN) and restarted $(AGENT) (if it was loaded)"

run: build
	.build/release/HumminMenubar

clean:
	swift package clean
	rm -rf .build
