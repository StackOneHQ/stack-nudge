# stack-nudge — local dev/build orchestration.
# Run `make` for the list of targets.

.DEFAULT_GOAL := help

PANEL_APP := $(HOME)/Applications/stack-nudge-panel.app
PANEL_LABEL := com.stackonehq.stack-nudge-panel
BUILD_LOG := /tmp/stack-nudge-dev.log
WATCH_DIRS := panel shared notifier notify.sh phrases

.PHONY: help
help:
	@echo "stack-nudge targets:"
	@echo "  make build      build both .app bundles into build/"
	@echo "  make install    full install (build + copy + register hooks + launchd)"
	@echo "  make uninstall  remove apps, hooks, launchd agents, ~/.stack-nudge/"
	@echo "  make reload     rebuild + replace installed panel + bounce the daemon"
	@echo "  make dev        watch sources; auto-reload on change (ctrl-c to stop)"
	@echo "  make clean      remove build/ output"

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
	@rm -rf build

# One-shot dev cycle: rebuild, reinstall the panel.app, refresh notify.sh in
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
	rm -rf "$(PANEL_APP)"; \
	cp -R build/stack-nudge-panel.app "$(PANEL_APP)"; \
	if [ -d "$$HOME/.stack-nudge" ]; then \
		cp notify.sh "$$HOME/.stack-nudge/notify.sh"; \
		if [ -d phrases ]; then \
			rm -rf "$$HOME/.stack-nudge/phrases"; \
			cp -R phrases "$$HOME/.stack-nudge/phrases"; \
		fi; \
	fi; \
	launchctl kickstart -k "gui/$$(id -u)/$(PANEL_LABEL)" 2>/dev/null || true; \
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
		if find $(WATCH_DIRS) \( -name '*.swift' -o -name 'Info.plist' \) -newer $(WATCH_MARKER) -print -quit 2>/dev/null | grep -q .; then \
			touch $(WATCH_MARKER); \
			$(MAKE) --no-print-directory reload || true; \
		fi; \
	done
