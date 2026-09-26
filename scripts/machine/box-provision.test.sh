#!/usr/bin/env bash
# box-provision.test.sh — unit tests for box-provision.sh's pure helpers.
# Run: bash scripts/machine/box-provision.test.sh
#
# box-provision.sh dispatches at the bottom, so it cannot simply be sourced.
# Each test extracts the one function under test and evaluates it against a
# temporary archive directory.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
TARGET="${SCRIPT_DIR}/box-provision.sh"

PASS=0 FAIL=0
expect_eq() { # DESCRIPTION ACTUAL EXPECTED
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — expected %q, got %q\n' "$1" "$3" "$2" >&2
  fi
}

# Pull prune_box_archives out of the script, with SUDO stubbed to nothing.
extract_prune() {
  awk '/^prune_box_archives\(\) \{/,/^}/' "${TARGET}"
}

setup_fixture() { # DIR
  local d=$1
  mkdir -p "$d"
  # Three retries of one box, plus a second box with a single archive.
  : >"$d/box_aaaaaaaaaaaa-1000.tar.gz"
  : >"$d/box_aaaaaaaaaaaa-2000.tar.gz"
  : >"$d/box_aaaaaaaaaaaa-3000.tar.gz"
  : >"$d/box_bbbbbbbbbbbb-1500.tar.gz"
  # Not ours: must survive untouched.
  : >"$d/unrelated.txt"
}

run_prune() { # DIR [RETENTION_DAYS]
  local d=$1 keep=${2:-14}
  # shellcheck disable=SC2034
  SUDO=() FICUS_ARCHIVE_DIR="$d" FICUS_ARCHIVE_RETENTION_DAYS="$keep" \
    bash -c "
      # No -u: bash 3.2 (macOS) treats \"\${SUDO[@]}\" on an EMPTY array as an
      # unbound variable, which the real script never hits because machine hosts
      # run bash 5. The function under test is what matters here, not the shell.
      set -eo pipefail
      SUDO=()
      FICUS_ARCHIVE_DIR='$d'
      FICUS_ARCHIVE_RETENTION_DAYS='$keep'
      $(extract_prune)
      prune_box_archives
    "
}

# --- supersede: one tarball per box -----------------------------------------
# Every retry of a box that cannot be removed writes ANOTHER full-size tarball.
# Three boxes doing that produced 240 tarballs and 42GB on a live machine host
# and filled its disk, which then made removal itself fail with ENOSPC.
TMP=$(mktemp -d)
setup_fixture "$TMP"
run_prune "$TMP"
expect_eq 'keeps exactly one tarball for the retried box' \
  "$(ls -1 "$TMP" | grep -c '^box_aaaaaaaaaaaa-')" '1'
expect_eq 'and it is the NEWEST one' \
  "$(ls -1 "$TMP" | grep '^box_aaaaaaaaaaaa-' || true)" 'box_aaaaaaaaaaaa-3000.tar.gz'
expect_eq 'a box with a single archive is left alone' \
  "$(ls -1 "$TMP" | grep -c '^box_bbbbbbbbbbbb-')" '1'
expect_eq 'unrelated files are never touched' \
  "$([[ -f "$TMP/unrelated.txt" ]] && echo present || echo gone)" 'present'
rm -rf "$TMP"

# --- age cap ----------------------------------------------------------------
TMP=$(mktemp -d)
setup_fixture "$TMP"
# `touch -d '30 days ago'` is GNU-only; BSD touch (macOS) needs an explicit
# stamp. python3 is present on both and this file must run on both.
old_stamp=$(python3 -c 'import time; print(time.strftime("%Y%m%d%H%M", time.localtime(time.time() - 30*86400)))')
touch -t "${old_stamp}" "$TMP/box_bbbbbbbbbbbb-1500.tar.gz"
run_prune "$TMP" 14
expect_eq 'an archive older than the retention window is removed' \
  "$(ls -1 "$TMP" | grep -c '^box_bbbbbbbbbbbb-' || true)" '0'
expect_eq 'a fresh archive survives the age cap' \
  "$(ls -1 "$TMP" | grep -c '^box_aaaaaaaaaaaa-')" '1'
rm -rf "$TMP"

# --- idempotence + empty dir ------------------------------------------------
TMP=$(mktemp -d)
setup_fixture "$TMP"
run_prune "$TMP"
before=$(ls -1 "$TMP" | wc -l | tr -d ' ')
run_prune "$TMP"
expect_eq 'a second prune changes nothing' "$(ls -1 "$TMP" | wc -l | tr -d ' ')" "$before"
rm -rf "$TMP"

TMP=$(mktemp -d)
prune_rc=0
run_prune "$TMP" || prune_rc=$?
expect_eq 'an empty archive dir is not an error' "${prune_rc}" '0'
rm -rf "$TMP"

# Housekeeping in front of a removal must never block the removal.
missing_rc=0
run_prune "/nonexistent/archive/dir" || missing_rc=$?
expect_eq 'a missing archive dir is not an error' "${missing_rc}" '0'

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
