#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

FIX=0
if [[ "${1:-}" == "--fix" ]]; then
  FIX=1
fi

fail=0

# 1. Verify SPDX AGPL-3.0-only header on all Monkey C sources and shell scripts
for f in source/*.mc scripts/*.sh; do
  [[ -f "$f" ]] || continue
  if ! head -n 3 "$f" | grep -q "SPDX-License-Identifier: AGPL-3.0-only"; then
    echo "missing SPDX header: $f" >&2
    fail=1
  fi
  if ! head -n 4 "$f" | grep -q "Copyright (c) 2026 sol pbc"; then
    echo "missing copyright header: $f" >&2
    fail=1
  fi
done

# 2. Verify no CRLF line endings or trailing spaces in tracked text files
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if [[ "$FIX" -eq 1 ]]; then
    sed -i 's/\r$//; s/[[:blank:]]\+$//' "$f"
  else
    if grep -q $'\r' "$f"; then
      echo "CRLF found: $f" >&2
      fail=1
    fi
    if grep -nE '[[:blank:]]+$' "$f" >/dev/null; then
      echo "trailing whitespace: $f" >&2
      fail=1
    fi
  fi
done < <({
  find source scripts docs resources* -type f \( -name '*.mc' -o -name '*.sh' -o -name '*.xml' -o -name '*.svg' -o -name '*.md' \)
  find . -maxdepth 1 -type f \( -name 'manifest.xml' -o -name 'monkey.jungle' -o -name 'Makefile' -o -name '*.md' \)
})

# 3. Verify manifest declares strictly the 4 allowed permissions (AudioInput, Background, Communications, ComplicationPublisher)
allowed_perms="AudioInput Background Communications ComplicationPublisher"
found_perms=$(grep -oE '<iq:uses-permission[[:space:]]+id="[^"]+"' manifest.xml | sed -E 's/.*id="([^"]+)".*/\1/' | sort -u)
if [[ -z "$found_perms" ]]; then
  echo "no permissions parsed from manifest.xml" >&2
  fail=1
fi
for perm in $found_perms; do
  if ! grep -qw "$perm" <<< "$allowed_perms"; then
    echo "disallowed permission in manifest.xml: $perm (allowed: $allowed_perms)" >&2
    fail=1
  fi
done
for req in $allowed_perms; do
  if ! grep -qx "$req" <<< "$found_perms"; then
    echo "missing required permission in manifest.xml: $req" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "format-check: OK"
