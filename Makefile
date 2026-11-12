BIN ?= $(HOME)/colibri/bin/hummin-menubar
AGENT ?= com.hummin.menubar
PLIST ?= $(HOME)/Library/LaunchAgents/$(AGENT).plist

.PHONY: build install run clean

build:
	swift build -c release

install: build
	@mkdir -p $(dir $(BIN))
	@# Unload, replace, load again. macOS Background Task Management pins a LaunchAgent to its
	@# binary's code identity: kickstarting it on a new binary fails with "Launch Constraint
	@# Violation" until BTM re-registers the agent ~10 s later; bootstrap re-registers it at once.
	@launchctl bootout gui/$$(id -u)/$(AGENT) 2>/dev/null || true
	@# copy then rename: overwriting the binary in place keeps its inode, and macOS then
	@# SIGKILLs the next launch with "Code Signature Invalid" (stale signature cache)
	cp .build/release/HumminMenubar $(BIN).new
	mv -f $(BIN).new $(BIN)
	@# SPM resource bundle must sit next to the binary or the app traps at launch
	@rm -rf $(dir $(BIN))HumminMenubar_HumminMenubar.bundle
	cp -R .build/release/HumminMenubar_HumminMenubar.bundle $(dir $(BIN))
	@# bootout can return before the job is gone, and bootstrap then fails with error 5: retry briefly
	@if [ -f $(PLIST) ]; then \
		for i in 1 2 3 4 5; do launchctl bootstrap gui/$$(id -u) $(PLIST) 2>/dev/null && break; sleep 1; done; \
		launchctl print gui/$$(id -u)/$(AGENT) | awk '/^\t(state|pid|last exit reason) = /'; \
	else echo "no $(PLIST): binary installed, agent not loaded"; fi
	@echo "installed to $(BIN) (+ resource bundle)"

run: build
	.build/release/HumminMenubar

clean:
	swift package clean
	rm -rf .build
