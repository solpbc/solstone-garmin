#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

CIQ_WRAPPER="${CIQ_WRAPPER:-}"
DEV_KEY="${DEV_KEY:?DEV_KEY is required}"
TEST_DEVICES="${TEST_DEVICES:-fr970 fenix8solar47mm venu441mm venux1}"

run_ciq() {
  if [[ -n "$CIQ_WRAPPER" ]]; then
    $CIQ_WRAPPER "$@"
  else
    "$@"
  fi
}

mkdir -p bin/tests

for dev in $TEST_DEVICES; do
  prg="bin/tests/solstone-test-${dev}.prg"
  echo "--- Compiling unit tests for ${dev} ---"
  run_ciq monkeyc -d "$dev" -f monkey.jungle -o "$prg" -y "$DEV_KEY" --unit-test -O 2 -l 3 -w

  echo "--- Running Run No Evil simulator tests on ${dev} ---"
  # Note: Connect IQ's monkeydo can exit non-zero on simulator disconnect even
  # when every Run No Evil test passes; verify the authoritative RESULTS block.
  out=$(run_ciq bash -c "
    set -u
    SDK=\$(dirname \"\$(command -v monkeyc)\")
    if [ -z \"\${DISPLAY:-}\" ] && command -v Xvfb >/dev/null 2>&1; then
      DISP_NUM=\$((70 + (RANDOM % 25)))
      Xvfb :\${DISP_NUM} -screen 0 1280x1024x24 >/tmp/xvfb-\${DISP_NUM}.log 2>&1 &
      XP=\$!
      export DISPLAY=:\${DISP_NUM}
      sleep 2
    else
      XP=''
    fi
    \"\$SDK/simulator\" >/tmp/sim-${dev}.log 2>&1 &
    SP=\$!
    sleep 10
    timeout 60 monkeydo \"$prg\" \"$dev\" -t
    kill \$SP 2>/dev/null || true
    [ -n \"\$XP\" ] && kill \$XP 2>/dev/null || true
    wait \$SP 2>/dev/null || true
    [ -n \"\$XP\" ] && wait \$XP 2>/dev/null || true
    exit 0
  " 2>&1) || true
  printf '%s\n' "$out" | grep -E 'Executing test|DEBUG|PASS|FAIL|ERROR|PASSED|Ran ' || true
  if ! printf '%s\n' "$out" | grep -q "PASSED (passed=13, failed=0, errors=0)"; then
    echo "error: simulator unit tests failed on ${dev}" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  rm -f "$prg" "${prg}.debug.xml"
done

rmdir bin/tests 2>/dev/null || true
echo "All simulator unit tests passed across: ${TEST_DEVICES}"
