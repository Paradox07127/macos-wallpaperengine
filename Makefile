# Single entry point for "did I run everything".
#
# Before this file the gates lived in ~20 separate scripts, and whether a change
# had been fully checked depended on remembering which ones applied. CI now runs
# the same targets, so local green and CI green mean the same thing.
#
#   make verify        everything below, cheapest gate first
#   make fast          seconds; structure/boundaries/i18n
#   make contracts     ~15s; release tooling + entitlements + gate self-tests
#   make lint          changed lines only (never the whole repo — see below)
#   make test-packages SwiftPM package suites
#   make test-app      hardware-free app contract shard (Pro + Lite hosts)
#   make test-app-hosted  same, minus the Lite host — for machines with no cert
#   make hooks         local agent-gate self-test (skipped where .claude is absent)
#   make unregister-build-appex  drop LaunchServices records for throwaway build dirs

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

# Shipping toolchain is Xcode 27.0. CI overrides this with its own image path.
DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR

# Revision the changed-lines ratchets diff against. CI passes the PR/push base.
BASE ?= HEAD
export QUALITY_GATE_BASE = $(BASE)

DERIVED_DATA ?= /tmp/LiveWallpaperVerify
SWIFTPM_SCRATCH ?= /tmp/LiveWallpaperVerify-SwiftPM
PACKAGES := LiveWallpaperCore LiveWallpaperProWPE

.DEFAULT_GOAL := help
.PHONY: help verify fast contracts lint hooks test-packages test-app test-app-hosted \
        unregister-build-appex

help:
	@sed -n '/^#   make/s/^#   //p' $(MAKEFILE_LIST)

# Ordered cheapest-first so a structural break fails in seconds, not minutes.
verify: fast contracts lint test-packages test-app
	@echo "== make verify: all gates passed =="

fast:
	@echo "== Module import boundaries =="
	python3 scripts/check_module_import_boundaries.py
	@echo "== Quality exclusion ratchet =="
	python3 scripts/check_quality_exclusions.py
	@echo "== SwiftUI lifecycle hosts =="
	python3 scripts/check_swiftui_lifecycle_hosts.py --self-test
	python3 scripts/check_swiftui_lifecycle_hosts.py
	@echo "== Localization guard (whole app) =="
	I18N_GUARD_SCOPE=all bash scripts/i18n_guard.sh
	@echo "== Localization drift (translations vs their English) =="
	python3 scripts/check_localization_drift.py --self-test
	python3 scripts/check_localization_drift.py

contracts:
	@echo "== Release + quality tooling contract =="
	bash scripts/release_contract_check.sh

# A ratchet, not a sweep: most files still differ from SwiftFormat at whole-file
# granularity, so only lines this change touched are judged. A whole-repo gate
# would either stay red forever or bury every semantic diff under a reformat.
lint:
	@echo "== Lint changed lines (base: $(BASE)) =="
	python3 scripts/lint_changed_lines.py --base "$(BASE)"

test-packages:
	@for package in $(PACKAGES); do \
	  echo "== Package tests: $$package =="; \
	  swift test --package-path "Packages/$$package" \
	    --scratch-path "$(SWIFTPM_SCRATCH)/$$package"; \
	done

test-app:
	@echo "== Fast app architecture/security contracts =="
	DERIVED_DATA="$(DERIVED_DATA)" bash scripts/fast_app_contract_tests.sh

# CI's variant. The Lite host asserts on runtime entitlements, so it needs a real
# signing certificate that hosted runners do not have; Lite's grants stay gated
# by `make verify` here and by scripts/release_candidate_check.sh at release.
test-app-hosted:
	@echo "== Fast app architecture/security contracts (no Lite host) =="
	DERIVED_DATA="$(DERIVED_DATA)" bash scripts/fast_app_contract_tests.sh --pro-only

# .claude/ is gitignored, so this target is a local-only gate on the agent
# guards themselves; it no-ops on a clean clone rather than failing.
hooks:
	@if [[ -f .claude/hooks/test-hooks.py ]]; then \
	  echo "== Agent gate self-test =="; \
	  python3 .claude/hooks/test-hooks.py; \
	else \
	  echo "== Agent gate self-test: skipped (.claude absent) =="; \
	fi

# Every build registers its .app — and the wallpaper appex inside it — with
# LaunchServices, and the newest record displaces the installed app's. Observed
# 2026-09-01: /Applications/Loomscreen Pro.app was not registered at all, while
# 16 build directories were. WallpaperAgent instantiates every registered
# provider on each discovery pass, so these are also what it spuriously launches.
# The processes retire themselves (ProviderStaleness); this clears the records.
#
# Driven off pluginkit, not `lsregister -dump`: pluginkit lists exactly the
# wallpaper-extension providers, so nothing else in the database is touched.
# lsregister surfaces an older record whenever a newer one goes, hence the loop.
#
# Deliberately NOT part of `verify` — a gate must not mutate the machine's
# LaunchServices state.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

unregister-build-appex:
	@echo "== Wallpaper providers registered outside /Applications =="
	@removed=0; \
	for _ in $$(seq 1 60); do \
	  appex=$$(/usr/bin/pluginkit -mAvvv -p com.apple.wallpaper 2>/dev/null \
	    | awk '/loomscreen/ { getline; sub(/^[ \t]*Path = /, ""); print }' \
	    | grep -v '^/Applications/' | head -1); \
	  [ -z "$$appex" ] && break; \
	  app="$${appex%%.app/Contents/Extensions/*}.app"; \
	  echo "  unregister $$app"; \
	  "$(LSREGISTER)" -u "$$app" >/dev/null 2>&1; \
	  removed=$$((removed + 1)); \
	done; \
	echo "== removed $$removed record(s) =="
	@echo "== remaining =="
	@/usr/bin/pluginkit -mAvvv -p com.apple.wallpaper 2>/dev/null \
	  | awk '/loomscreen/ { id=$$1; getline; sub(/^[ \t]*Path = /, ""); print "  "id"  <- "$$0 }' \
	  || true
