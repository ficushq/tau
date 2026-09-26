#!/usr/bin/env bash
# retarget-origin.test.sh — tests the real retarget-origin.sh as a
# subprocess (never sourced): argument validation, --dry-run planning, AND
# (root-gated — see below) the full mutation phase (steps 1-6) run twice to
# prove idempotency.
#
# Every invocation below runs with a PATH-shimmed sudo/systemctl/caddy/id/
# curl/journalctl (retarget-origin.sh now hard-preflights caddy+the caddy
# user, hard-requires EUID 0, and shells out to systemctl/curl/journalctl
# for the restart+health-wait step) and with CADDY_TLS_DIR/CADDYFILE_PATH
# overridden to a scratch directory (lib.sh honors both as env overrides —
# see their definitions there — so setup-host.sh/upgrade-host.sh are
# unaffected: neither one ever sets them).
#
# The mutation-phase section additionally needs the WHOLE test process to
# be real root (retarget-origin.sh's own EUID check has no sudo fallback),
# so it self-skips with a loud warning outside of CI's
# `sudo env "PATH=$PATH" bash scripts/setup/retarget-origin.test.sh` — same
# idiom lib.test.sh already uses for its own root-only sections.
#
# Run: bash scripts/setup/retarget-origin.test.sh
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
RETARGET="${SCRIPT_DIR}/retarget-origin.sh"

PASS=0 FAIL=0
expect_eq() { # DESCRIPTION ACTUAL EXPECTED
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — expected %q, got %q\n' "$1" "$3" "$2" >&2
  fi
}
expect_match() { # DESCRIPTION ACTUAL REGEX
  if [[ $2 =~ $3 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %q does not match /%s/\n' "$1" "$2" "$3" >&2
  fi
}
# For "this exact line is somewhere in this multi-line content" checks:
# bash's [[ =~ ^X$ ]] anchors to the START/END OF THE WHOLE STRING, not
# per-line, so it cannot express "line X appears verbatim among others" —
# use this (grep -x, one line of CONTENT at a time) instead of reaching for
# ^...$ on a multi-line ACTUAL.
expect_has_line() { # DESCRIPTION CONTENT LINE
  if grep -qxF -- "$3" <<<"$2"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %q has no line exactly %q\n' "$1" "$2" "$3" >&2
  fi
}

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -q mikefarah; then
  printf 'SKIP: mikefarah yq v4 not on PATH — retarget-origin.test.sh needs it to parse the config (brew install yq)\n' >&2
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  exit 0
fi

SCRATCH=$(mktemp -d -t retarget-origin-test.XXXXXX)
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT

# --- PATH shims, in effect for every invocation below -------------------------
SHIM_DIR="${SCRATCH}/shim-bin"
mkdir -p "${SHIM_DIR}"
SHIM_LOG="${SCRATCH}/shim-calls.log"
: >"${SHIM_LOG}"

cat >"${SHIM_DIR}/sudo" <<'SHIM'
#!/usr/bin/env bash
exec "$@"
SHIM

cat >"${SHIM_DIR}/caddy" <<SHIM
#!/usr/bin/env bash
printf 'caddy %s\n' "\$*" >>"${SHIM_LOG}"
exit 0
SHIM

cat >"${SHIM_DIR}/id" <<'SHIM'
#!/usr/bin/env bash
if [[ $1 == -u && $2 == caddy ]]; then
  exit 0
fi
# NOT `exec command -p id "$@"`: `command` is a shell BUILTIN, not an
# executable, and `exec` can only replace the process image with a real
# program — it cannot exec a builtin at all. Hardcode the real binary's
# path instead of a PATH-based lookup (`env id`/bare `id` would just find
# THIS shim again, since it's ahead of the real id on PATH — infinite
# recursion).
exec /usr/bin/id "$@"
SHIM

cat >"${SHIM_DIR}/systemctl" <<SHIM
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"${SHIM_LOG}"
[[ \$1 == show ]] && echo 0
exit 0
SHIM

cat >"${SHIM_DIR}/curl" <<SHIM
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"${SHIM_LOG}"
printf '200'
exit 0
SHIM

cat >"${SHIM_DIR}/journalctl" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM

# Passes through to the REAL install(1) unless FICUS_TEST_FAIL_KEY_INSTALL is
# set, in which case it fails ONLY a call installing a file named
# `origin.key` — the failure-injection case below (install_origin_cert's
# SECOND `as_root install` call, lib.sh's key install). Everything else
# (the cert install, caddy_install_atomically's own Caddyfile install) must
# keep working even during that test, or this shim would fail the run for
# an unrelated reason. Off by default, so every OTHER invocation in this
# file (dry-run, validation, and mutation runs 1-2) is unaffected.
cat >"${SHIM_DIR}/install" <<'SHIM'
#!/usr/bin/env bash
if [[ -n ${FICUS_TEST_FAIL_KEY_INSTALL:-} ]]; then
  for arg in "$@"; do
    [[ $(basename -- "${arg}") == origin.key ]] && exit 1
  done
fi
exec /usr/bin/install "$@"
SHIM

# Passes through to the real cp unless FICUS_TEST_FAIL_KEY_RESTORE is set, in
# which case it fails ONLY a copy whose destination is named exactly
# `origin.key` — retarget-origin.sh's post-failure key RESTORE. The
# pre-install backup (destination origin.key.bak-…) is unaffected. Off by
# default.
cat >"${SHIM_DIR}/cp" <<'SHIM'
#!/usr/bin/env bash
if [[ -n ${FICUS_TEST_FAIL_KEY_RESTORE:-} && $(basename -- "${@: -1}") == origin.key ]]; then
  exit 1
fi
exec /bin/cp "$@"
SHIM

chmod +x "${SHIM_DIR}"/sudo "${SHIM_DIR}"/caddy "${SHIM_DIR}"/id "${SHIM_DIR}"/systemctl "${SHIM_DIR}"/curl "${SHIM_DIR}"/journalctl "${SHIM_DIR}"/install "${SHIM_DIR}"/cp
export PATH="${SHIM_DIR}:${PATH}"

# --- scratch Caddy paths (overridable in lib.sh; see its CADDY_TLS_DIR /
# CADDYFILE_PATH definitions) — never the real /etc/caddy -------------------
export CADDY_TLS_DIR="${SCRATCH}/caddy-tls"
export CADDYFILE_PATH="${SCRATCH}/Caddyfile"
mkdir -p "${CADDY_TLS_DIR}"

CORE_DEST="${SCRATCH}/core"
mkdir -p "${CORE_DEST}"

CONFIG="${SCRATCH}/tau-setup.yaml"
cat >"${CONFIG}" <<EOF
source:
  repo: git@example.com:acme/tau.git
  dest: ${CORE_DEST}
core:
  origin: https://acme.hiretau.ai
  port: 3000
  env: {}
ingress:
  caddy: true
  tls_cert_path: /etc/caddy/tls/origin.crt
  tls_key_path: /etc/caddy/tls/origin.key
dns:
  zone: hiretau.ai
EOF
printf 'APP_URL=https://acme.hiretau.ai\nFICUS_WEB_ORIGIN=https://acme.hiretau.ai\nFICUS_ENCRYPTION_KEY=deadbeef\n' >"${CORE_DEST}/.env"
CONFIG_BYTES_BEFORE=$(cat "${CONFIG}")
ENV_BYTES_BEFORE=$(cat "${CORE_DEST}/.env")

CERT="${SCRATCH}/origin.crt"
KEY="${SCRATCH}/origin.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=acme.ficus.sh' \
  -keyout "${KEY}" -out "${CERT}" >/dev/null 2>&1
OTHER_KEY="${SCRATCH}/other.key"
openssl genrsa -out "${OTHER_KEY}" 2048 >/dev/null 2>&1

# --- --dry-run ----------------------------------------------------------------
dry_run_out=$("${RETARGET}" --config "${CONFIG}" --origin https://acme.ficus.sh \
  --tls-cert "${CERT}" --tls-key "${KEY}" \
  --dns-zone ficus.sh --ingest-url https://ficus.sh --dry-run 2>&1)
dry_run_rc=0
"${RETARGET}" --config "${CONFIG}" --origin https://acme.ficus.sh \
  --tls-cert "${CERT}" --tls-key "${KEY}" \
  --dns-zone ficus.sh --ingest-url https://ficus.sh --dry-run >/dev/null 2>&1 || dry_run_rc=$?
expect_eq '--dry-run exits zero' "${dry_run_rc}" '0'
expect_match '--dry-run plans the new core.origin' "${dry_run_out}" 'core\.origin: https://acme\.ficus\.sh'
expect_match '--dry-run plans ingress.tls_cert_path' "${dry_run_out}" "ingress\\.tls_cert_path: ${CERT//\//\\/}"
expect_match '--dry-run plans ingress.tls_key_path' "${dry_run_out}" "ingress\\.tls_key_path: ${KEY//\//\\/}"
expect_match '--dry-run plans dns.zone' "${dry_run_out}" 'dns\.zone: ficus\.sh'
expect_match '--dry-run plans core.env.FICUS_PLATFORM_INGEST_URL' "${dry_run_out}" 'FICUS_PLATFORM_INGEST_URL: https://ficus\.sh'
expect_match '--dry-run plans the .env rewrite' "${dry_run_out}" 'APP_URL=https://acme\.ficus\.sh'
expect_match '--dry-run plans FICUS_WEB_ORIGIN' "${dry_run_out}" 'FICUS_WEB_ORIGIN=https://acme\.ficus\.sh'
expect_match '--dry-run names the derived Caddy host' "${dry_run_out}" 'caddy — host acme\.ficus\.sh'
expect_match '--dry-run mentions the Caddyfile path it would write' "${dry_run_out}" "write ${CADDYFILE_PATH//\//\\/} "
expect_eq '--dry-run does not modify the config file' "$(cat "${CONFIG}")" "${CONFIG_BYTES_BEFORE}"
expect_eq '--dry-run does not modify the .env file' "$(cat "${CORE_DEST}/.env")" "${ENV_BYTES_BEFORE}"
# The rename/fix for the old, misleadingly-named "never touches the live
# Caddyfile" assertion: CADDYFILE_PATH is overridden above to a scratch path
# that does not exist yet, so this is now a REAL check that --dry-run wrote
# nothing there — not just a string match against the plan text.
expect_eq '--dry-run does not create the Caddyfile it plans to write' \
  "$([[ -e ${CADDYFILE_PATH} ]] && echo exists || echo absent)" 'absent'

dry_run_out_2=$("${RETARGET}" --config "${CONFIG}" --origin https://acme.ficus.sh \
  --tls-cert "${CERT}" --tls-key "${KEY}" \
  --dns-zone ficus.sh --ingest-url https://ficus.sh --dry-run 2>&1)
# Strip each line's leading HH:MM:SS (log_step's own real-time timestamp)
# before comparing — the PLAN must be byte-identical across two runs, but
# the wall-clock second it happened to run in legitimately is not.
strip_ts() { sed -E 's/^[0-9]{2}:[0-9]{2}:[0-9]{2} //'; }
expect_eq '--dry-run is idempotent: running it twice prints the same plan' \
  "$(strip_ts <<<"${dry_run_out_2}")" "$(strip_ts <<<"${dry_run_out}")"

# --- validation failures: exit non-zero with a clear message ------------------
run_rc() { # ...ARGS
  local rc=0
  "${RETARGET}" "$@" >/dev/null 2>/dev/null || rc=$?
  printf '%s' "${rc}"
}
run_err() { # ...ARGS
  # Deliberate order (SC2069): duplicate the CURRENT stdout (the caller's
  # $(...) capture pipe) onto stderr first, THEN send stdout itself to
  # /dev/null — the standard "capture stderr only" idiom, not a typo.
  # shellcheck disable=SC2069
  "${RETARGET}" "$@" 2>&1 >/dev/null || true
}

# --- a host that was never renamed (Ficus): refused before anything changes --
# retarget-origin.sh reads and writes FICUS_* names only; on a host still on
# TAU_* ones it must stop before touching the yaml, the .env or Caddy.
printf 'APP_URL=https://acme.hiretau.ai\nTAU_WEB_ORIGIN=https://acme.hiretau.ai\nTAU_ENCRYPTION_KEY=deadbeef\n' >"${CORE_DEST}/.env" # legacy-env
TAU_ENV_BYTES=$(cat "${CORE_DEST}/.env")
for tau_mode in --dry-run real; do
  tau_args=(--config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}")
  [[ ${tau_mode} == --dry-run ]] && tau_args+=(--dry-run)
  expect_eq "TAU host (${tau_mode}): exits non-zero" "$(run_rc "${tau_args[@]}")" '1'
  expect_match "TAU host (${tau_mode}): says why" "$(run_err "${tau_args[@]}")" 'this host still uses TAU_\* settings'
  expect_eq "TAU host (${tau_mode}): the config is untouched" "$(cat "${CONFIG}")" "${CONFIG_BYTES_BEFORE}"
  expect_eq "TAU host (${tau_mode}): the .env is untouched" "$(cat "${CORE_DEST}/.env")" "${TAU_ENV_BYTES}"
  expect_eq "TAU host (${tau_mode}): no Caddyfile was written" "$([[ -e ${CADDYFILE_PATH} ]] && echo exists || echo absent)" 'absent'
done
printf '%s\n' "${ENV_BYTES_BEFORE}" >"${CORE_DEST}/.env"

expect_eq 'http origin: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin http://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'
expect_match 'http origin: names the requirement' \
  "$(run_err --config "${CONFIG}" --origin http://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" \
  'bare https origin'

expect_eq 'origin with a port: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh:8443 --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'

expect_eq 'origin with a path: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh/x --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'

expect_eq 'origin with a query string: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin 'https://acme.ficus.sh?x=1' --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'

expect_eq 'origin with a fragment: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin 'https://acme.ficus.sh#frag' --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'

expect_eq 'origin with userinfo: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin 'https://evil@acme.ficus.sh' --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'

expect_eq 'key/cert mismatch: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${OTHER_KEY}" --dry-run)" '1'
expect_match 'key/cert mismatch: names the mismatch' \
  "$(run_err --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${OTHER_KEY}" --dry-run)" \
  'do not match'

expect_eq 'missing --tls-cert file: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${SCRATCH}/nope.crt" --tls-key "${KEY}" --dry-run)" '1'
expect_match 'missing --tls-cert file: names the path' \
  "$(run_err --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${SCRATCH}/nope.crt" --tls-key "${KEY}" --dry-run)" \
  'file not found'

expect_eq 'missing --tls-key file: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${SCRATCH}/nope.key" --dry-run)" '1'

expect_eq 'missing --config file: exits non-zero' \
  "$(run_rc --config "${SCRATCH}/nope.yaml" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'
expect_match 'missing --config file: names the config path' \
  "$(run_err --config "${SCRATCH}/nope.yaml" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" \
  'not found'

expect_eq 'missing --dns-zone value is fine (optional flag)' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '0'

expect_eq 'bad --dns-zone (looks like a URL): exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dns-zone 'https://ficus.sh' --dry-run)" '1'

expect_eq 'bad --ingest-url (not https): exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --ingest-url 'http://ficus.sh' --dry-run)" '1'

expect_eq 'missing --config flag entirely: exits non-zero' \
  "$(run_rc --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'
expect_eq 'missing --origin flag entirely: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)" '1'
expect_eq 'missing --tls-cert flag entirely: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-key "${KEY}" --dry-run)" '1'
expect_eq 'missing --tls-key flag entirely: exits non-zero' \
  "$(run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --dry-run)" '1'

expect_eq '--help exits zero' "$(run_rc --help)" '0'
expect_eq 'an unknown flag exits non-zero' "$(run_rc --config "${CONFIG}" --wat)" '1'

# --- caddy/id preflight: exits non-zero (naming the reason) when caddy is
# missing ------------------------------------------------------------------
# A naively narrowed PATH like /usr/bin:/bin is NOT enough: confirmed by
# hand, a fresh ubuntu:24.04 image installs openssl/curl via apt to
# /usr/local/bin, and this repo's own macOS dev setup has yq (Homebrew)
# under /opt/homebrew/bin — either would make retarget-origin.sh die on an
# unrelated "command not found" before ever reaching the caddy check, and
# the exit code alone (1, identical to the real failure) would never reveal
# it. And on THIS machine specifically, caddy itself is ALSO real and
# installed (Homebrew, /opt/homebrew/bin) — disabling only our shim's
# caddy would still find that real one. So: build a PATH that keeps every
# directory needed for openssl/curl/yq/id/etc, MINUS every directory that
# resolves an actual `caddy` executable (ours or a real one) — and assert
# the actual failure MESSAGE, not just the exit code, so a die() for some
# other missing command can never be mistaken for this one.
path_without_caddy() {
  local dir result=()
  local -a dirs
  IFS=':' read -ra dirs <<<"${PATH}"
  for dir in "${dirs[@]}"; do
    [[ -n ${dir} && -x "${dir}/caddy" ]] && continue
    result+=("${dir}")
  done
  local IFS=':'
  printf '%s' "${result[*]}"
}
NO_CADDY_PATH=$(path_without_caddy)
no_caddy_rc=$(PATH="${NO_CADDY_PATH}" run_rc --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)
no_caddy_err=$(PATH="${NO_CADDY_PATH}" run_err --config "${CONFIG}" --origin https://acme.ficus.sh --tls-cert "${CERT}" --tls-key "${KEY}" --dry-run)
expect_eq 'no caddy on PATH: exits non-zero' "${no_caddy_rc}" '1'
expect_match 'no caddy on PATH: names the missing caddy ingress' "${no_caddy_err}" 'no caddy ingress to retarget'

# =============================================================================
# Mutation phase (steps 1-6), run TWICE, end to end — needs real root
# =============================================================================
# retarget-origin.sh's EUID check has no sudo fallback (by design — see its
# header comment), so THIS WHOLE TEST PROCESS must already be root for the
# section below to run for real. Locally that's essentially never true;
# CI's `sudo env "PATH=$PATH" bash scripts/setup/retarget-origin.test.sh`
# is what actually exercises it. Same self-skip idiom as lib.test.sh's own
# root-only sections.
#
# install_origin_cert's `install -o caddy -g caddy` needs a REAL system
# user to chown to — the PATH-shimmed `id -u caddy` earlier only satisfies
# retarget-origin.sh's own preflight CHECK, not the actual install(1) call
# a few steps later. Every check in THIS section therefore uses
# `command -p id`, which deliberately bypasses our own shim (via a fixed
# default PATH) to see the REAL system state — using the shimmed `id` here
# would always read as "caddy exists" and this section would never
# actually create (or correctly skip) anything. Create a throwaway,
# unprivileged system user/group named caddy if this host doesn't already
# have one (a real caddy install would have created exactly this), and
# remove it again on exit if we were the one who created it — never touch
# a caddy user that was already there.
CREATED_CADDY_USER=0
if [[ ${EUID} -eq 0 ]] && ! command -p id -u caddy >/dev/null 2>&1 && command -v useradd >/dev/null 2>&1; then
  groupadd --system caddy >/dev/null 2>&1 || true
  useradd --system --no-create-home --shell /usr/sbin/nologin --gid caddy caddy >/dev/null 2>&1 &&
    CREATED_CADDY_USER=1
fi
cleanup_caddy_user() {
  [[ ${CREATED_CADDY_USER} -eq 1 ]] || return 0
  userdel caddy >/dev/null 2>&1 || true
  groupdel caddy >/dev/null 2>&1 || true
}
trap 'cleanup_caddy_user; cleanup' EXIT

if [[ ${EUID} -eq 0 ]] && command -p id -u caddy >/dev/null 2>&1; then
  echo 'TAU retarget-origin mutation-phase section: ENABLED'

  MUT="${SCRATCH}/mutation"
  mkdir -p "${MUT}/core"
  export CADDY_TLS_DIR="${MUT}/caddy-tls"
  export CADDYFILE_PATH="${MUT}/Caddyfile"
  mkdir -p "${CADDY_TLS_DIR}"

  MUT_CONFIG="${MUT}/tau-setup.yaml"
  cat >"${MUT_CONFIG}" <<EOF
source:
  repo: git@example.com:acme/tau.git
  dest: ${MUT}/core
core:
  origin: https://acme.hiretau.ai
  port: 3000
  env: {}
ingress:
  caddy: true
  tls_cert_path: /pushed/old/origin.crt
  tls_key_path: /pushed/old/origin.key
dns:
  zone: hiretau.ai
EOF
  # PORT (4100) deliberately DIFFERS from the yaml's core.port (3000) — this
  # is exactly the drift the health-check-port fix targets: the Caddyfile's
  # reverse_proxy target, and the port the health check probes, must come
  # from the running .env, not the yaml default.
  printf '# a comment\nAPP_URL=https://acme.hiretau.ai\n\nFICUS_WEB_ORIGIN=https://acme.hiretau.ai\nPORT=4100\nFICUS_ENCRYPTION_KEY=deadbeef\n' >"${MUT}/core/.env"

  # A pre-existing "old" cert at the canonical (scratch) path, so the
  # cert-backup-before-install fix has something real to back up.
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=old.acme.hiretau.ai' \
    -keyout "${CADDY_TLS_DIR}/origin.key" -out "${CADDY_TLS_DIR}/origin.crt" >/dev/null 2>&1

  MUT_NEW_CERT="${MUT}/new-origin.crt"
  MUT_NEW_KEY="${MUT}/new-origin.key"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=acme.ficus.sh' \
    -keyout "${MUT_NEW_KEY}" -out "${MUT_NEW_CERT}" >/dev/null 2>&1
  NEW_CERT_BYTES=$(cat "${MUT_NEW_CERT}")
  NEW_KEY_BYTES=$(cat "${MUT_NEW_KEY}")

  run_mutation() {
    "${RETARGET}" --config "${MUT_CONFIG}" --origin https://acme.ficus.sh \
      --tls-cert "${MUT_NEW_CERT}" --tls-key "${MUT_NEW_KEY}" \
      --dns-zone ficus.sh --ingest-url https://ficus.sh
  }

  # Asserts the full post-mutation state — called after BOTH run 1 and run 2.
  assert_mutation_state() { # LABEL
    local label=$1
    expect_eq "${label}: yaml core.origin rewritten" "$(yq -r '.core.origin' "${MUT_CONFIG}")" 'https://acme.ficus.sh'
    expect_eq "${label}: yaml ingress.tls_cert_path rewritten" "$(yq -r '.ingress.tls_cert_path' "${MUT_CONFIG}")" "${MUT_NEW_CERT}"
    expect_eq "${label}: yaml ingress.tls_key_path rewritten" "$(yq -r '.ingress.tls_key_path' "${MUT_CONFIG}")" "${MUT_NEW_KEY}"
    expect_eq "${label}: yaml dns.zone rewritten" "$(yq -r '.dns.zone' "${MUT_CONFIG}")" 'ficus.sh'
    expect_eq "${label}: yaml core.env.FICUS_PLATFORM_INGEST_URL rewritten" \
      "$(yq -r '.core.env.FICUS_PLATFORM_INGEST_URL' "${MUT_CONFIG}")" 'https://ficus.sh'
    expect_eq "${label}: yaml source.repo untouched" "$(yq -r '.source.repo' "${MUT_CONFIG}")" 'git@example.com:acme/tau.git'
    expect_eq "${label}: yaml source.dest untouched" "$(yq -r '.source.dest' "${MUT_CONFIG}")" "${MUT}/core"

    expect_match "${label}: .env APP_URL rewritten" "$(cat "${MUT}/core/.env")" 'APP_URL=https://acme\.ficus\.sh'
    expect_match "${label}: .env FICUS_WEB_ORIGIN rewritten" "$(cat "${MUT}/core/.env")" 'FICUS_WEB_ORIGIN=https://acme\.ficus\.sh'
    expect_match "${label}: .env FICUS_PLATFORM_INGEST_URL rewritten" "$(cat "${MUT}/core/.env")" 'FICUS_PLATFORM_INGEST_URL=https://ficus\.sh'
    # Every OTHER .env line, byte-for-byte: the comment, the blank line, the
    # untouched PORT, and the untouched secret.
    expect_has_line "${label}: .env comment preserved" "$(cat "${MUT}/core/.env")" '# a comment'
    expect_has_line "${label}: .env PORT untouched" "$(cat "${MUT}/core/.env")" 'PORT=4100'
    expect_has_line "${label}: .env secret untouched" "$(cat "${MUT}/core/.env")" 'FICUS_ENCRYPTION_KEY=deadbeef'
    # The strongest form of "every other line byte-for-byte": the WHOLE file,
    # line order (including the blank line) and all, is exactly this.
    expect_eq "${label}: .env is exactly the expected content, in order" \
      "$(cat "${MUT}/core/.env")" \
      '# a comment
APP_URL=https://acme.ficus.sh

FICUS_WEB_ORIGIN=https://acme.ficus.sh
PORT=4100
FICUS_ENCRYPTION_KEY=deadbeef
FICUS_PLATFORM_INGEST_URL=https://ficus.sh'

    expect_eq "${label}: the new cert bytes were installed" "$(cat "${CADDY_TLS_DIR}/origin.crt")" "${NEW_CERT_BYTES}"
    expect_eq "${label}: the new key bytes were installed" "$(cat "${CADDY_TLS_DIR}/origin.key")" "${NEW_KEY_BYTES}"

    expect_eq "${label}: Caddyfile content is exactly render_caddyfile's output" \
      "$(cat "${CADDYFILE_PATH}")" \
      "acme.ficus.sh {
    tls ${CADDY_TLS_DIR}/origin.crt ${CADDY_TLS_DIR}/origin.key
    reverse_proxy 127.0.0.1:4100
}"

    expect_match "${label}: restart was invoked (systemctl restart tau-api tau-worker)" \
      "$(cat "${SHIM_LOG}")" 'systemctl restart tau-api tau-worker'
    expect_match "${label}: the health check probed the .env's PORT (4100), not the yaml's core.port (3000)" \
      "$(cat "${SHIM_LOG}")" '127\.0\.0\.1:4100/health'

    expect_eq "${label}: a yaml backup was created" "$(compgen -G "${MUT_CONFIG}.bak-*" >/dev/null && echo yes || echo no)" 'yes'
    expect_eq "${label}: an .env backup was created" "$(compgen -G "${MUT}/core/.env.bak-*" >/dev/null && echo yes || echo no)" 'yes'
    expect_eq "${label}: an origin-cert backup was created" "$(compgen -G "${CADDY_TLS_DIR}/origin.crt.bak-*" >/dev/null && echo yes || echo no)" 'yes'
    expect_eq "${label}: an origin-key backup was created" "$(compgen -G "${CADDY_TLS_DIR}/origin.key.bak-*" >/dev/null && echo yes || echo no)" 'yes'
  }

  : >"${SHIM_LOG}"
  run1_rc=0
  run1_out=$(run_mutation 2>&1) || run1_rc=$?
  expect_eq 'mutation run 1: exits zero' "${run1_rc}" '0'
  if [[ ${run1_rc} -ne 0 ]]; then printf '%s\n' "${run1_out}" >&2; fi
  assert_mutation_state 'run 1'

  # Full post-run-1 snapshot, to prove run 2 changes NOTHING further.
  after_run1_config=$(cat "${MUT_CONFIG}")
  after_run1_env=$(cat "${MUT}/core/.env")
  after_run1_caddyfile=$(cat "${CADDYFILE_PATH}")
  after_run1_cert=$(cat "${CADDY_TLS_DIR}/origin.crt")
  after_run1_key=$(cat "${CADDY_TLS_DIR}/origin.key")
  after_run1_backup_count=$(compgen -G "${MUT_CONFIG}.bak-*" | wc -l | tr -d ' ')

  : >"${SHIM_LOG}"
  run2_rc=0
  run2_out=$(run_mutation 2>&1) || run2_rc=$?
  expect_eq 'mutation run 2 (idempotent re-run): exits zero' "${run2_rc}" '0'
  if [[ ${run2_rc} -ne 0 ]]; then printf '%s\n' "${run2_out}" >&2; fi
  assert_mutation_state 'run 2'

  expect_eq 'idempotent: yaml identical after run 2' "$(cat "${MUT_CONFIG}")" "${after_run1_config}"
  expect_eq 'idempotent: .env identical after run 2' "$(cat "${MUT}/core/.env")" "${after_run1_env}"
  expect_eq 'idempotent: Caddyfile identical after run 2' "$(cat "${CADDYFILE_PATH}")" "${after_run1_caddyfile}"
  expect_eq 'idempotent: installed cert identical after run 2' "$(cat "${CADDY_TLS_DIR}/origin.crt")" "${after_run1_cert}"
  expect_eq 'idempotent: installed key identical after run 2' "$(cat "${CADDY_TLS_DIR}/origin.key")" "${after_run1_key}"
  # Backups are timestamped and NOT deduplicated (each run leaves its own
  # evidence) — run 2 adds another one rather than reusing run 1's.
  after_run2_backup_count=$(compgen -G "${MUT_CONFIG}.bak-*" | wc -l | tr -d ' ')
  expect_eq 'run 2 adds its own backup rather than skipping it' \
    "$([[ ${after_run2_backup_count} -gt ${after_run1_backup_count} ]] && echo more || echo same)" 'more'

  # ===========================================================================
  # FAILURE INJECTION (b): install_origin_cert's KEY install fails partway
  # through steps 3-5 — the previous cert/key must be restored, the
  # Caddyfile must be untouched (the caddy step is never reached), and the
  # script must exit non-zero. This is exactly the scenario the round-3
  # regression review found unprotected: a failing `as_root install` with
  # no explicit check used to be silently ignored inside the guarding
  # subshell, and this run would have reported SUCCESS.
  # ===========================================================================
  before_fail_cert=$(cat "${CADDY_TLS_DIR}/origin.crt")
  before_fail_key=$(cat "${CADDY_TLS_DIR}/origin.key")
  before_fail_caddyfile=$(cat "${CADDYFILE_PATH}")

  FAIL_NEW_CERT="${MUT}/fail-new-origin.crt"
  FAIL_NEW_KEY="${MUT}/fail-new-origin.key"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=should-never-install' \
    -keyout "${FAIL_NEW_KEY}" -out "${FAIL_NEW_CERT}" >/dev/null 2>&1

  : >"${SHIM_LOG}"
  export FICUS_TEST_FAIL_KEY_INSTALL=1
  fail_rc=0
  fail_out=$(
    "${RETARGET}" --config "${MUT_CONFIG}" --origin https://acme.ficus.sh \
      --tls-cert "${FAIL_NEW_CERT}" --tls-key "${FAIL_NEW_KEY}" 2>&1
  ) || fail_rc=$?
  unset FICUS_TEST_FAIL_KEY_INSTALL

  expect_eq 'failure injection: a failing key install exits non-zero' "${fail_rc}" '1'
  expect_match 'failure injection: names the failure and the rollback' "${fail_out}" 'steps 3-5 failed'
  expect_match 'failure injection: reports the cert/key restore as done' "${fail_out}" 'origin certificate/key restored to their previous values'
  expect_eq 'failure injection: the PREVIOUS cert bytes are restored (not the failed attempt, not empty)' \
    "$(cat "${CADDY_TLS_DIR}/origin.crt")" "${before_fail_cert}"
  expect_eq 'failure injection: the PREVIOUS key bytes are restored (not the failed attempt, not empty)' \
    "$(cat "${CADDY_TLS_DIR}/origin.key")" "${before_fail_key}"
  expect_eq 'failure injection: the failed attempt cert bytes were NOT installed' \
    "$([[ $(cat "${CADDY_TLS_DIR}/origin.crt") == "$(cat "${FAIL_NEW_CERT}")" ]] && echo installed || echo not-installed)" 'not-installed'
  expect_eq 'failure injection: the Caddyfile is completely untouched (the caddy step was never reached)' \
    "$(cat "${CADDYFILE_PATH}")" "${before_fail_caddyfile}"
  expect_match 'failure injection: tau-api/tau-worker were never restarted' \
    "$([[ $(cat "${SHIM_LOG}") == *'systemctl restart tau-api tau-worker'* ]] && echo restarted || echo not-restarted)" 'not-restarted'
  # The yaml IS updated with the new (unreachable, install failed) paths —
  # documented, deliberate FAILURE BEHAVIOR (step 2 is forward progress for
  # a retry, not rolled back on a steps-3-5 failure).
  expect_eq 'failure injection: the yaml rewrite (step 2, before the failure) is still forward progress, not rolled back' \
    "$(yq -r '.ingress.tls_cert_path' "${MUT_CONFIG}")" "${FAIL_NEW_CERT}"

  # ===========================================================================
  # FAILURE INJECTION (c): the same failing key install, AND the key RESTORE
  # afterwards fails too. The die message must say the restore FAILED and
  # name the key path — never claim the certificate was rolled back.
  # ===========================================================================
  : >"${SHIM_LOG}"
  export FICUS_TEST_FAIL_KEY_INSTALL=1 FICUS_TEST_FAIL_KEY_RESTORE=1
  restore_fail_rc=0
  restore_fail_out=$(
    "${RETARGET}" --config "${MUT_CONFIG}" --origin https://acme.ficus.sh \
      --tls-cert "${FAIL_NEW_CERT}" --tls-key "${FAIL_NEW_KEY}" 2>&1
  ) || restore_fail_rc=$?
  unset FICUS_TEST_FAIL_KEY_INSTALL FICUS_TEST_FAIL_KEY_RESTORE

  expect_eq 'restore-failure injection: exits non-zero' "${restore_fail_rc}" '1'
  expect_match 'restore-failure injection: says the restore FAILED' "${restore_fail_out}" 'FAILED to restore the previous origin certificate/key'
  expect_eq 'restore-failure injection: names the key path it could not restore' \
    "$([[ ${restore_fail_out} == *"${CADDY_TLS_DIR}/origin.key (from "* ]] && echo named || echo missing)" 'named'
  expect_eq 'restore-failure injection: does not claim a rollback' \
    "$([[ ${restore_fail_out} == *'restored to their previous values'* ]] && echo claims || echo no-claim)" 'no-claim'
  expect_eq 'restore-failure injection: the cert restore that did succeed still happened' \
    "$(cat "${CADDY_TLS_DIR}/origin.crt")" "${before_fail_cert}"
else
  if [[ ${EUID} -ne 0 ]]; then
    printf 'SKIP: not running as root (EUID=%s) — the mutation-phase end-to-end test needs this whole test process to be real root (retarget-origin.sh has no sudo fallback); run via `sudo env "PATH=$PATH" bash scripts/setup/retarget-origin.test.sh` (as CI does) to execute it\n' "${EUID}" >&2
  else
    printf 'SKIP: no real "caddy" system user exists and this host has no useradd to create one — install_origin_cert needs an ACTUAL caddy user (chown target), not just the PATH-shimmed "id -u caddy" preflight check\n' >&2
  fi
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
