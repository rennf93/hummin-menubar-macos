BIN ?= $(HOME)/colibri/bin/hummin-menubar
AGENT ?= com.hummin.menubar

.PHONY: build install run clean

build:
	swift build -c release

install: build
	@mkdir -p $(dir $(BIN))
	cp .build/release/HumminMenubar $(BIN)
	@# SPM resource bundle must sit next to the binary or the app traps at launch
	@rm -rf $(dir $(BIN))HumminMenubar_HumminMenubar.bundle
	cp -R .build/release/HumminMenubar_HumminMenubar.bundle $(dir $(BIN))
	@launchctl kickstart -k gui/501/$(AGENT) 2>/dev/null || true
	@echo "installed to $(BIN) (+ resource bundle) and restarted $(AGENT) (if it was loaded)"

run: build
	.build/release/HumminMenubar

clean:
	swift package clean
	rm -rf .build
