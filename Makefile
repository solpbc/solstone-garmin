# solstone-garmin: Connect IQ build, test, and packaging targets.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := build

# Optional wrapper command for running Connect IQ SDK tools (e.g., container shim)
CIQ_WRAPPER ?=
MONKEYC     := $(if $(CIQ_WRAPPER),$(CIQ_WRAPPER) monkeyc,monkeyc)
DEVICE      ?= fr970
TEST_DEVICES ?= fr970 fenix8solar47mm venu441mm venux1
BIN_DIR     := bin
EPHEMERAL_KEY := $(BIN_DIR)/.ephemeral_dev_key.der

# All 23 microphone-equipped watches in manifest.xml (Connect IQ API >= 6.0.3)
ALL_DEVICES := \
	approachs7243mm approachs7247mm \
	d2mach2 d2mach2pro \
	fenix843mm fenix847mm fenix8pro47mm fenix8solar47mm fenix8solar51mm \
	fenix943mm fenix947mm fenix9pro43mm fenix9pro47mm fenix9pro51mm fenix9prosolar47mm fenix9prosolar51mm \
	fr57042mm fr57047mm fr970 \
	marq3 \
	venu441mm venu445mm venux1

RELEASE_FLAGS := -r -O 3pz -l 3 -w
DEBUG_FLAGS   := -O 2 -l 3 -w

.PHONY: install build build-debug build-all package test format format-check ci clean

$(BIN_DIR):
	@mkdir -p $(BIN_DIR)

# Generate a throwaway RSA-4096 PKCS#8 DER key for local builds/CI when DEV_KEY is not provided
$(EPHEMERAL_KEY): | $(BIN_DIR)
	@openssl genrsa 4096 2>/dev/null | openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt -out $@

EFFECTIVE_KEY = $(if $(DEV_KEY),$(DEV_KEY),$(EPHEMERAL_KEY))
KEY_DEP       = $(if $(DEV_KEY),,$(EPHEMERAL_KEY))

install:
	@echo "Checking Connect IQ toolchain..."
	@$(MONKEYC) --version
	@command -v openssl >/dev/null || { echo "error: openssl is required to generate a local dev signing key"; exit 1; }
	@echo "Toolchain ready. Run 'make ci' to build all 23 watches and run simulator tests."

build: $(KEY_DEP) | $(BIN_DIR)
	$(MONKEYC) -d $(DEVICE) -f monkey.jungle -o $(BIN_DIR)/solstone-$(DEVICE).prg -y $(EFFECTIVE_KEY) $(RELEASE_FLAGS) --build-stats 0

build-debug: $(KEY_DEP) | $(BIN_DIR)
	$(MONKEYC) -d $(DEVICE) -f monkey.jungle -o $(BIN_DIR)/solstone-$(DEVICE)-debug.prg -y $(EFFECTIVE_KEY) $(DEBUG_FLAGS) --build-stats 0

build-all: $(KEY_DEP) | $(BIN_DIR)
	@set -euo pipefail; \
	mkdir -p $(BIN_DIR)/fleet; \
	pass=0; warn_total=0; \
	for d in $(ALL_DEVICES); do \
		if ! out=$$($(MONKEYC) -d "$$d" -f monkey.jungle -o "$(BIN_DIR)/fleet/solstone-$$d.prg" -y "$(EFFECTIVE_KEY)" $(RELEASE_FLAGS) 2>&1); then \
			echo "  FAIL  $$d" >&2; \
			printf '%s\n' "$$out" >&2; \
			exit 1; \
		fi; \
		w=$$(printf '%s\n' "$$out" | grep -c "WARNING:" || true); \
		warn_total=$$((warn_total + w)); \
		sz=$$(stat -c %s "$(BIN_DIR)/fleet/solstone-$$d.prg"); \
		printf "  PASS  %-20s  %6d B  warnings=%d\n" "$$d" "$$sz" "$$w"; \
		if [ "$$w" -ne 0 ]; then printf '%s\n' "$$out" >&2; exit 1; fi; \
		pass=$$((pass + 1)); \
	done; \
	echo "Built $$pass/23 microphone-equipped watches with $$warn_total warnings."

package: | $(BIN_DIR)
	@if [ -z "$(DEV_KEY)" ]; then \
		echo "error: DEV_KEY=/path/to/developer_key.der is required for 'make package' (never sign a store .iq with an ephemeral key)" >&2; \
		exit 2; \
	fi
	$(MONKEYC) -e -f monkey.jungle -o $(BIN_DIR)/solstone.iq -y $(DEV_KEY) $(RELEASE_FLAGS)
	@ls -lh $(BIN_DIR)/solstone.iq

format:
	@scripts/check-format.sh --fix

format-check:
	@scripts/check-format.sh

test: $(KEY_DEP) | $(BIN_DIR)
	@CIQ_WRAPPER="$(CIQ_WRAPPER)" DEV_KEY="$(EFFECTIVE_KEY)" TEST_DEVICES="$(TEST_DEVICES)" scripts/run-sim-tests.sh

ci: format-check build-all test
	@echo "CI PASSED (format + 23/23 zero-warning release builds + multi-watch simulator tests)."

clean:
	rm -rf $(BIN_DIR)
