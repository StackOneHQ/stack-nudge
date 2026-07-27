# stack-nudge — local dev/build orchestration.
# Run `make` for the list of targets.

.DEFAULT_GOAL := help

APP := $(HOME)/Applications/stack-nudge.app
APP_LABEL := com.stackonehq.stack-nudge
BUILD_LOG := /tmp/stack-nudge-dev.log
WATCH_DIRS := panel shared notify.sh phrases

.PHONY: help
help:
	@echo "stack-nudge targets:"
	@echo "  make build      build stack-nudge.app into build/"
	@echo "  make install    full install (build + copy + register hooks + launchd)"
	@echo "  make uninstall  remove app, hooks, launchd agents, ~/.stack-nudge/"
	@echo "  make reload     rebuild + replace installed app + bounce the daemon"
	@echo "  make dev        watch sources; auto-reload on change (ctrl-c to stop)"
	@echo "  make test       run swift test (needs full Xcode for XCTest)"
	@echo "  make typecheck-tests  compile-check the test sources (no Xcode needed)"
	@echo "  make clean      remove build/ and .build/"

.PHONY: build
build:
	@./build.sh

.PHONY: install
install:
	@./install.sh

.PHONY: uninstall
uninstall:
	@./uninstall.sh

.PHONY: clean
clean:
	@rm -rf build .build

.PHONY: test
test:
	@if ! xcrun --find xctest >/dev/null 2>&1; then \
		echo "swift test needs XCTest, which only ships with full Xcode."; \
		echo "Install Xcode and run:"; \
		echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
		exit 1; \
	fi
	@swift test

# Compile-check the XCTest sources without Xcode. Catches the breakage `make
# test` can't reach on a Command Line Tools-only machine — a production API
# change leaving a test call site uncompilable. Does not run assertions.
.PHONY: typecheck-tests
typecheck-tests:
	@./scripts/typecheck-tests.sh

# One-shot dev cycle: rebuild, reinstall the app, refresh notify.sh in
# ~/.stack-nudge so hook-side changes propagate, kickstart the daemon.
# Build output goes to $(BUILD_LOG); on failure, last 20 lines tail to stderr.
.PHONY: reload
reload:
	@set -e; \
	printf '[%s] rebuilding... ' "$$(date +%H:%M:%S)"; \
	if ! ./build.sh > $(BUILD_LOG) 2>&1; then \
		printf 'FAILED\n'; \
		tail -20 $(BUILD_LOG) | sed 's/^/    /'; \
		exit 1; \
	fi; \
	rm -rf "$(APP)"; \
	cp -R build/stack-nudge.app "$(APP)"; \
	if [ -d "$$HOME/.stack-nudge" ]; then \
		cp notify.sh "$$HOME/.stack-nudge/notify.sh"; \
		if [ -d phrases ]; then \
			rm -rf "$$HOME/.stack-nudge/phrases"; \
			cp -R phrases "$$HOME/.stack-nudge/phrases"; \
		fi; \
	fi; \
	launchctl kickstart -k "gui/$$(id -u)/$(APP_LABEL)" 2>/dev/null || true; \
	printf 'reloaded\n'

# Watch loop. Polling-based (500 ms) — no fswatch / entr dependency. Uses a
# marker file + `find -newer` so it works regardless of stat flavor (BSD vs
# GNU coreutils on PATH).
WATCH_MARKER := /tmp/stack-nudge-watch.marker

.PHONY: dev
dev:
	@$(MAKE) --no-print-directory reload || true
	@echo "watching: $(WATCH_DIRS) — ctrl-c to stop"
	@touch $(WATCH_MARKER); \
	while true; do \
		sleep 0.5; \
		if find $(WATCH_DIRS) \( -name '*.swift' -o -name '*.sh' -o -name 'Info.plist' \) -newer $(WATCH_MARKER) -print -quit 2>/dev/null | grep -q .; then \
			touch $(WATCH_MARKER); \
			$(MAKE) --no-print-directory reload || true; \
		fi; \
	done
