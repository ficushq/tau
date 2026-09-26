#!/usr/bin/env bash
# retarget-backup.test.sh — tests the real retarget-backup.sh as a subprocess
# (never sourced): argument/secrets-file/live-file validation and --dry-run
# (any user), AND (root-gated — see below) the real mutation run twice to
# prove idempotency, plus failure injection at every step that can fail.
#
# Every invocation runs with BACKUP_SCRIPT_PATH / BACKUP_ENV_TARGET pointed
# at a scratch directory (lib.sh honors both as env overrides; setup-host.sh
# and upgrade-host.sh never set them) and with PATH shims for curl (the S3
# verification — records its argv and the curl --config it was handed, and
# answers with a chosen HTTP status or exit code), systemctl (records; must
# never be called), and mv/chmod/chown/mktemp/cat/cp/yq (pass through to the
# real binary unless a FICUS_TEST_* switch tells one to fail a specific call).
#
# The mutation section needs the WHOLE test process to be real root
# (retarget-backup.sh has no sudo fallback), so it self-skips outside CI's
# `sudo env "PATH=$PATH" bash scripts/setup/retarget-backup.test.sh` — the
# same idiom as retarget-origin.test.sh.
#
# Run: bash scripts/setup/retarget-backup.test.sh
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
RETARGET="${SCRIPT_DIR}/retarget-backup.sh"

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
expect_contains() { # DESCRIPTION ACTUAL LITERAL
  if [[ $2 == *"$3"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %q does not contain %q\n' "$1" "$2" "$3" >&2
  fi
}
expect_not_contains() { # DESCRIPTION ACTUAL LITERAL — never echoes ACTUAL (it may hold a leaked secret)
  if [[ $2 != *"$3"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — output contains a value it must not\n' "$1" >&2
  fi
}

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>/dev/null | grep -q mikefarah; then
  printf 'SKIP: mikefarah yq v4 not on PATH — retarget-backup.test.sh needs it to parse the config (brew install yq)\n' >&2
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  exit 0
fi

SCRATCH=$(mktemp -d -t retarget-backup-test.XXXXXX)
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT

# --- PATH shims ---------------------------------------------------------------
# Real binaries are resolved BEFORE the shim dir goes on PATH and baked into
# each shim, so a pass-through can never find the shim itself again.
SHIM_DIR="${SCRATCH}/shim-bin"
mkdir -p "${SHIM_DIR}"
SHIM_LOG="${SCRATCH}/shim-calls.log"
CURL_CONFIG_SEEN="${SCRATCH}/curl-config-seen"
MV_COUNT_DIR="${SCRATCH}/mv-counts"
mkdir -p "${MV_COUNT_DIR}"
: >"${SHIM_LOG}"
real() { command -v "$1" || die_test "no $1 on PATH"; }
die_test() {
  printf 'test setup: %s\n' "$*" >&2
  exit 1
}
# shellcheck disable=SC2034 # REAL_CHMOD/CHOWN/MKTEMP/CP are read via ${!real_var} below
REAL_MV=$(real mv) REAL_CHMOD=$(real chmod) REAL_CHOWN=$(real chown) REAL_MKTEMP=$(real mktemp)
# shellcheck disable=SC2034 # REAL_CP is read via ${!real_var} below
REAL_CAT=$(real cat) REAL_CP=$(real cp) REAL_YQ=$(real yq) REAL_HEAD=$(real head)

# curl: record argv, copy out the --config it was handed (proves the key
# travelled there and not on argv), then answer with FICUS_TEST_S3_STATUS
# (default 200) as %{http_code}, or fail with exit FICUS_TEST_CURL_EXIT.
cat >"${SHIM_DIR}/curl" <<SHIM
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >>"${SHIM_LOG}"
prev=''
for a in "\$@"; do
  [[ \${prev} == --config ]] && ${REAL_CAT} "\${a}" >"${CURL_CONFIG_SEEN}"
  prev=\${a}
done
if [[ -n \${FICUS_TEST_CURL_EXIT:-} ]]; then
  printf 'curl: (%s) Failed to connect (test shim)\n' "\${FICUS_TEST_CURL_EXIT}" >&2
  exit "\${FICUS_TEST_CURL_EXIT}"
fi
printf '%s' "\${FICUS_TEST_S3_STATUS:-200}"
SHIM

cat >"${SHIM_DIR}/systemctl" <<SHIM
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"${SHIM_LOG}"
exit 0
SHIM

# mv: FICUS_TEST_FAIL_MV="backup.env:1 tau-backup.sh:2" fails the 1st rename
# onto a file named backup.env and the 2nd onto one named tau-backup.sh.
cat >"${SHIM_DIR}/mv" <<SHIM
#!/usr/bin/env bash
dest=\$(basename -- "\${@: -1}")
n=\$(( \$(${REAL_CAT} "${MV_COUNT_DIR}/\${dest}" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\${n}" >"${MV_COUNT_DIR}/\${dest}"
for rule in \${FICUS_TEST_FAIL_MV:-}; do
  [[ \${rule} == "\${dest}:\${n}" ]] && exit 1
done
# FICUS_TEST_HUP_ON_MV=<dest basename>: SIGHUP the calling script first (a
# dropped SSH session mid-swap), then do the rename anyway.
[[ -n \${FICUS_TEST_HUP_ON_MV:-} && \${dest} == "\${FICUS_TEST_HUP_ON_MV}" ]] && kill -HUP "\${PPID}"
exec ${REAL_MV} "\$@"
SHIM

# chmod/chown/mktemp/cp: fail any call with an argument containing the
# FICUS_TEST_FAIL_<CMD> substring.
for cmd in chmod chown mktemp cp; do
  upper=$(printf '%s' "${cmd}" | tr '[:lower:]' '[:upper:]')
  real_var="REAL_${upper}"
  cat >"${SHIM_DIR}/${cmd}" <<SHIM
#!/usr/bin/env bash
if [[ -n \${FICUS_TEST_FAIL_${upper}:-} ]]; then
  for a in "\$@"; do
    [[ \${a} == *"\${FICUS_TEST_FAIL_${upper}}"* ]] && exit 1
  done
fi
exec ${!real_var} "\$@"
SHIM
done

# cat: FICUS_TEST_CAT_SHORT=<path> returns only its first line, exit 0 (a
# silently short read); FICUS_TEST_CAT_FAIL=<path> returns its first line and
# exits 1 (a read error partway).
cat >"${SHIM_DIR}/cat" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ -n \${FICUS_TEST_CAT_SHORT:-} && \${a} == "\${FICUS_TEST_CAT_SHORT}" ]]; then
    ${REAL_HEAD} -n 1 "\${a}"
    exit 0
  fi
  if [[ -n \${FICUS_TEST_CAT_FAIL:-} && \${a} == "\${FICUS_TEST_CAT_FAIL}" ]]; then
    ${REAL_HEAD} -n 1 "\${a}"
    exit 1
  fi
done
exec ${REAL_CAT} "\$@"
SHIM

# yq: FICUS_TEST_FAIL_YQ_WRITE=1 fails any in-place write (yq -i);
# FICUS_TEST_FAIL_YQ_READ=<substring> fails any call with an argument
# containing it; FICUS_TEST_HUP_ON_YQ_WRITE=1 sends SIGHUP to the script's MAIN
# shell (the yq -i calls run inside a ( … ) subshell, so that is the
# grandparent — Linux /proc) before an in-place write.
cat >"${SHIM_DIR}/yq" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  [[ -n \${FICUS_TEST_FAIL_YQ_READ:-} && \${a} == *"\${FICUS_TEST_FAIL_YQ_READ}"* ]] && exit 1
  if [[ \${a} == -i ]]; then
    [[ -n \${FICUS_TEST_FAIL_YQ_WRITE:-} ]] && exit 1
    if [[ -n \${FICUS_TEST_HUP_ON_YQ_WRITE:-} ]]; then
      gp=\$(awk '{print \$4}' "/proc/\${PPID}/stat")
      kill -HUP "\${gp}"
    fi
  fi
done
exec ${REAL_YQ} "\$@"
SHIM

chmod +x "${SHIM_DIR}"/*
export PATH="${SHIM_DIR}:${PATH}"

# A staged write cannot be failed with a PATH shim — it is the printf
# BUILTIN writing through a redirect. BASH_ENV runs this file in the script's
# own shell before anything else, shadowing printf with a function that
# fails ONLY when its stdout is a file whose path contains
# FICUS_TEST_FAIL_WRITE (Linux /proc; the root section only runs there).
FAIL_WRITE_ENV="${SCRATCH}/fail-write.bash"
cat >"${FAIL_WRITE_ENV}" <<'EOF'
printf() {
  local me=${BASHPID} target
  target=$(readlink "/proc/${me}/fd/1" 2>/dev/null) || target=''
  [[ -n ${FICUS_TEST_FAIL_WRITE:-} && ${target} == *"${FICUS_TEST_FAIL_WRITE}"* ]] && return 1
  # shellcheck disable=SC2059 # pass-through: forwards the caller's own format
  builtin printf "$@"
}
EOF

# --- fixtures -----------------------------------------------------------------
LIB="${SCRIPT_DIR}/lib.sh"
TEMPLATE="${SCRIPT_DIR}/tau-backup.sh.tmpl"
lib() { bash -c 'source "$0"; "$@"' "${LIB}" "$@"; }

export BACKUP_SCRIPT_PATH="${SCRATCH}/bin/tau-backup.sh"
export BACKUP_ENV_TARGET="${SCRATCH}/etc/backup.env"
mkdir -p "${SCRATCH}/bin" "${SCRATCH}/etc" "${SCRATCH}/core"

OLD_ENDPOINT='https://nyc3.digitaloceanspaces.com' OLD_REGION='nyc3' OLD_BUCKET='tau-backups'
NEW_ENDPOINT='https://sfo3.digitaloceanspaces.com' NEW_REGION='sfo3' NEW_BUCKET='ficus-backups'
PREFIX='tenants/acct-1/acme'
OLD_AK='DO00OLDACCESSKEY0000' OLD_SK='old-secret-value-XYZ/abc'
NEW_AK='DO00NEWACCESSKEY1234' NEW_SK="new/secret+key'with\"quotes\\and\$(x)"
PASSPHRASE="p@ss 'quoted' \$(echo pwned) \`id\` \"dq\" \\ end"

render_old_script() { lib render_backup_script_content "${TEMPLATE}" "${SCRATCH}/core" /home/tau/.tau container tau-postgres \
  "${OLD_ENDPOINT}" "${OLD_REGION}" "${OLD_BUCKET}" "${PREFIX}" "${BACKUP_ENV_TARGET}"; }
render_new_script() { # ENDPOINT REGION BUCKET
  lib render_backup_script_content "${TEMPLATE}" "${SCRATCH}/core" /home/tau/.tau container tau-postgres \
    "$1" "$2" "$3" "${PREFIX}" "${BACKUP_ENV_TARGET}"
}
PRISTINE="${SCRATCH}/pristine"
mkdir -p "${PRISTINE}"
render_old_script >"${PRISTINE}/tau-backup.sh"
lib render_backup_env_content real "${OLD_AK}" "${OLD_SK}" "${PASSPHRASE}" >"${PRISTINE}/backup.env"
render_new_script "${NEW_ENDPOINT}" "${NEW_REGION}" "${NEW_BUCKET}" >"${SCRATCH}/expected-tau-backup.sh"
lib render_backup_env_content real "${NEW_AK}" "${NEW_SK}" "${PASSPHRASE}" >"${SCRATCH}/expected-backup.env"

CONFIG="${SCRATCH}/tau-setup.yaml"
cat >"${PRISTINE}/tau-setup.yaml" <<EOF
source:
  dest: ${SCRATCH}/core
core:
  origin: https://acme.ficus.sh
backup:
  enabled: true
  s3_endpoint: ${OLD_ENDPOINT}
  s3_region: ${OLD_REGION}
  s3_bucket: ${OLD_BUCKET}
  s3_prefix: ${PREFIX}
  s3_access_key_env: PLATFORM_BACKUP_S3_ACCESS_KEY
  s3_secret_key_env: PLATFORM_BACKUP_S3_SECRET_KEY
  passphrase_env: FICUS_BACKUP_PASSPHRASE
  schedule: '03:15'
EOF

# The host's core .env, renamed to FICUS_* (the Ficus rename): retarget-backup.sh
# reads and writes FICUS_ names only and refuses a host still on TAU_ ones.
CORE_ENV="${SCRATCH}/core/.env"
printf 'FICUS_ENCRYPTION_KEY=k\nFICUS_SANDBOX_RUNTIME=host\n' >"${CORE_ENV}"

SECRETS="${SCRATCH}/secrets.env"
write_secrets() { # ACCESS SECRET — always a fresh file (owner = this user)
  rm -f "${SECRETS}"
  {
    printf '# pushed by the control plane\n'
    printf 'FICUS_BACKUP_S3_ACCESS_KEY=%s\n' "$(lib sh_single_quote "$1")"
    printf 'FICUS_BACKUP_S3_SECRET_KEY=%s\n' "$(lib sh_single_quote "$2")"
  } >"${SECRETS}"
  chmod 600 "${SECRETS}"
}

# Put the host back to its pre-retarget state (old files, old yaml, no
# backups, fresh shim log/counters). Modes/owners are set by the caller.
reset_fixture() {
  cp "${PRISTINE}/tau-backup.sh" "${BACKUP_SCRIPT_PATH}"
  cp "${PRISTINE}/backup.env" "${BACKUP_ENV_TARGET}"
  cp "${PRISTINE}/tau-setup.yaml" "${CONFIG}"
  chmod 755 "${BACKUP_SCRIPT_PATH}"
  chmod 600 "${BACKUP_ENV_TARGET}"
  rm -f "${SCRATCH}"/bin/*.bak-* "${SCRATCH}"/etc/*.bak-* "${CONFIG}".bak-* "${CURL_CONFIG_SEEN}"
  rm -f "${MV_COUNT_DIR}"/*
  : >"${SHIM_LOG}"
  write_secrets "${NEW_AK}" "${NEW_SK}"
}
same() { cmp -s "$1" "$2" && echo same || echo differs; }
count() { # GLOB
  local n=0 f
  for f in $1; do [[ -e ${f} ]] && n=$((n + 1)); done
  printf '%s' "${n}"
}
staged_count() { printf '%s' "$(($(count "${SCRATCH}/bin/.tau-backup.sh.*") + $(count "${SCRATCH}/etc/.backup.env.*")))"; }
backup_count() { printf '%s' "$(($(count "${SCRATCH}/bin/tau-backup.sh.bak-*") + $(count "${SCRATCH}/etc/backup.env.bak-*") + $(count "${CONFIG}.bak-*")))"; }
assert_no_secrets() { # LABEL OUTPUT
  expect_not_contains "$1: never prints the new secret key" "$2" "${NEW_SK}"
  expect_not_contains "$1: never prints the old secret key" "$2" "${OLD_SK}"
  expect_not_contains "$1: never prints the passphrase" "$2" "${PASSPHRASE}"
  expect_not_contains "$1: never prints the new access key in full" "$2" "${NEW_AK}"
  expect_not_contains "$1: never prints the old access key in full" "$2" "${OLD_AK}"
}
# Everything is exactly as before the run: both live files and the yaml
# byte-identical, nothing staged left behind.
assert_untouched() { # LABEL
  expect_eq "$1: tau-backup.sh is byte-identical" "$(same "${BACKUP_SCRIPT_PATH}" "${PRISTINE}/tau-backup.sh")" same
  expect_eq "$1: backup.env is byte-identical" "$(same "${BACKUP_ENV_TARGET}" "${PRISTINE}/backup.env")" same
  expect_eq "$1: the yaml is byte-identical" "$(same "${CONFIG}" "${PRISTINE}/tau-setup.yaml")" same
  expect_eq "$1: no staged file is left behind" "$(staged_count)" 0
}

ARGS=(--config "${CONFIG}" --secrets "${SECRETS}" --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}" --region "${NEW_REGION}")
RC=0 OUT=''
run() { # ...ARGS — sets RC and OUT (stdout+stderr)
  RC=0
  OUT=$("${RETARGET}" "$@" 2>&1) || RC=$?
}

reset_fixture

# =============================================================================
# a host that was never renamed (Ficus): refused before anything is written
# =============================================================================
# All three live files get an old mtime first, so any write — even one that
# rewrote the same bytes — would show.
printf 'TAU_ENCRYPTION_KEY=k\nTAU_SANDBOX_RUNTIME=host\n' >"${CORE_ENV}" # legacy-env
touch -d '2001-01-01 00:00:00' "${BACKUP_SCRIPT_PATH}" "${BACKUP_ENV_TARGET}" "${CONFIG}"
mtimes() { stat -c %Y "${BACKUP_SCRIPT_PATH}" "${BACKUP_ENV_TARGET}" "${CONFIG}" 2>/dev/null || stat -f %m "${BACKUP_SCRIPT_PATH}" "${BACKUP_ENV_TARGET}" "${CONFIG}"; }
before_mtimes=$(mtimes)
for mode in real --dry-run; do
  if [[ ${mode} == real ]]; then run "${ARGS[@]}"; else run "${ARGS[@]}" --dry-run; fi
  expect_eq "TAU host (${mode}): exits 1" "${RC}" 1
  expect_contains "TAU host (${mode}): says why" "${OUT}" 'this host still uses TAU_* settings — upgrade it to the Ficus Core release first'
  expect_eq "TAU host (${mode}): no file was written (mtimes unchanged)" "$(mtimes)" "${before_mtimes}"
  expect_not_contains "TAU host (${mode}): prints no RESULT marker" "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT='
  expect_eq "TAU host (${mode}): the S3 check never ran" "$(grep -c '^curl ' "${SHIM_LOG}" || true)" 0
done
assert_untouched 'TAU host'
printf 'FICUS_ENCRYPTION_KEY=k\nFICUS_SANDBOX_RUNTIME=host\n' >"${CORE_ENV}"
reset_fixture

# =============================================================================
# --dry-run (any user)
# =============================================================================
run "${ARGS[@]}" --dry-run
expect_eq '--dry-run exits zero' "${RC}" 0
[[ ${RC} -eq 0 ]] || printf '%s\n' "${OUT}" >&2
expect_contains '--dry-run shows the current target' "${OUT}" "endpoint ${OLD_ENDPOINT}  region ${OLD_REGION}  bucket ${OLD_BUCKET}  prefix ${PREFIX}"
expect_contains '--dry-run shows the new target, prefix unchanged' "${OUT}" "endpoint ${NEW_ENDPOINT}  region ${NEW_REGION}  bucket ${NEW_BUCKET}  prefix ${PREFIX} (unchanged)"
expect_contains '--dry-run plans the verification' "${OUT}" "ListObjectsV2 (max-keys=1, read-only) of s3://${NEW_BUCKET}/${PREFIX}/ at ${NEW_ENDPOINT}"
expect_contains '--dry-run diffs the old bucket out of tau-backup.sh' "${OUT}" "  | -S3_BUCKET='${OLD_BUCKET}'"
expect_contains '--dry-run diffs the new bucket into tau-backup.sh' "${OUT}" "  | +S3_BUCKET='${NEW_BUCKET}'"
expect_contains '--dry-run shows the access key redacted' "${OUT}" "FICUS_BACKUP_S3_ACCESS_KEY=DO00… (20 chars, redacted)"
expect_contains '--dry-run masks the secret key completely' "${OUT}" 'FICUS_BACKUP_S3_SECRET_KEY=<redacted>'
expect_contains '--dry-run keeps the passphrase' "${OUT}" 'FICUS_BACKUP_PASSPHRASE=<unchanged, redacted>'
expect_contains '--dry-run plans the yaml endpoint' "${OUT}" "backup.s3_endpoint: ${NEW_ENDPOINT} (was ${OLD_ENDPOINT})"
expect_contains '--dry-run plans the yaml bucket' "${OUT}" "backup.s3_bucket: ${NEW_BUCKET} (was ${OLD_BUCKET})"
expect_contains '--dry-run names what stays untouched' "${OUT}" 'tau-backup.timer / tau-backup.service (schedule)'
assert_no_secrets '--dry-run' "${OUT}"
dry_stdout=$("${RETARGET}" "${ARGS[@]}" --dry-run 2>/dev/null)
# Each marker on its own line, each findable by its own full name (the
# multi-marker printf used to hide the last two behind `\n`).
for marker in ENDPOINT REGION BUCKET; do
  expect_eq "--dry-run emits FICUS_RETARGET_BACKUP_${marker}= on its own line" \
    "$(grep -c "^FICUS_RETARGET_BACKUP_${marker}=" <<<"${dry_stdout}")" '1'
done
expect_eq '--dry-run ends stdout with the result markers' "$(tail -n 4 <<<"${dry_stdout}")" \
  "FICUS_RETARGET_BACKUP_RESULT=dry-run
FICUS_RETARGET_BACKUP_ENDPOINT=${NEW_ENDPOINT}
FICUS_RETARGET_BACKUP_REGION=${NEW_REGION}
FICUS_RETARGET_BACKUP_BUCKET=${NEW_BUCKET}"
assert_untouched '--dry-run'
expect_eq '--dry-run creates no backups' "$(backup_count)" 0
expect_eq '--dry-run never contacts S3 (no curl call)' "$(grep -c '^curl ' "${SHIM_LOG}" || true)" 0

strip_ts() { sed -E 's/^[0-9]{2}:[0-9]{2}:[0-9]{2} //'; }
dry_1=${OUT}
run "${ARGS[@]}" --dry-run
expect_eq '--dry-run is idempotent: twice prints the same plan' "$(strip_ts <<<"${OUT}")" "$(strip_ts <<<"${dry_1}")"

run --config "${CONFIG}" --secrets "${SECRETS}" --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}" --dry-run
expect_eq '--dry-run without --region exits zero' "${RC}" 0
expect_contains 'without --region, the live region is kept' "${OUT}" "FICUS_RETARGET_BACKUP_REGION=${OLD_REGION}"

# =============================================================================
# validation failures: exit 1 with a clear message, nothing touched
# =============================================================================
expect_run_fails() { # LABEL MESSAGE_LITERAL ...ARGS
  local label=$1 msg=$2
  shift 2
  run "$@"
  expect_eq "${label}: exits 1" "${RC}" 1
  expect_contains "${label}: says why" "${OUT}" "${msg}"
  assert_no_secrets "${label}" "${OUT}"
}
V=(--config "${CONFIG}" --secrets "${SECRETS}" --endpoint "${NEW_ENDPOINT}" --region "${NEW_REGION}" --dry-run)
expect_run_fails 'bucket with uppercase' 'must be an S3 bucket name' "${V[@]}" --bucket Ficus-Backups
expect_run_fails 'bucket too short' 'must be an S3 bucket name' "${V[@]}" --bucket ab
expect_run_fails 'bucket with a slash' 'must be an S3 bucket name' "${V[@]}" --bucket 'ficus/backups'
V=(--config "${CONFIG}" --secrets "${SECRETS}" --bucket "${NEW_BUCKET}" --region "${NEW_REGION}" --dry-run)
expect_run_fails 'http endpoint' '--endpoint must be https://' "${V[@]}" --endpoint http://sfo3.digitaloceanspaces.com
expect_run_fails 'endpoint with a path' '--endpoint must be https://' "${V[@]}" --endpoint https://sfo3.digitaloceanspaces.com/x
expect_run_fails 'endpoint with a trailing slash' '--endpoint must be https://' "${V[@]}" --endpoint https://sfo3.digitaloceanspaces.com/
expect_run_fails 'endpoint with a query' '--endpoint must be https://' "${V[@]}" --endpoint 'https://sfo3.digitaloceanspaces.com?x=1'
expect_run_fails 'endpoint with userinfo' '--endpoint must be https://' "${V[@]}" --endpoint 'https://u:p@sfo3.digitaloceanspaces.com'
expect_run_fails 'bad region' '--region must be a region name' --config "${CONFIG}" --secrets "${SECRETS}" \
  --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}" --region 'NYC 3' --dry-run
for flag in config secrets bucket endpoint; do
  args=()
  [[ ${flag} == config ]] || args+=(--config "${CONFIG}")
  [[ ${flag} == secrets ]] || args+=(--secrets "${SECRETS}")
  [[ ${flag} == bucket ]] || args+=(--bucket "${NEW_BUCKET}")
  [[ ${flag} == endpoint ]] || args+=(--endpoint "${NEW_ENDPOINT}")
  expect_run_fails "missing --${flag}" "--${flag} is required" "${args[@]}" --dry-run
done
run --help
expect_eq '--help exits zero' "${RC}" 0
expect_run_fails 'unknown flag' 'unknown argument: --wat' "${ARGS[@]}" --wat
expect_run_fails 'missing config file' 'not found' --config "${SCRATCH}/nope.yaml" --secrets "${SECRETS}" \
  --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}" --dry-run

# --- the secrets file ---------------------------------------------------------
expect_run_fails 'missing secrets file' 'not found' --config "${CONFIG}" --secrets "${SCRATCH}/nope.env" \
  --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}" --dry-run
chmod 644 "${SECRETS}"
expect_run_fails 'group/other-readable secrets file' 'must not be readable by group/other' "${ARGS[@]}" --dry-run
chmod 600 "${SECRETS}"
ln -s "${SECRETS}" "${SCRATCH}/secrets-link.env"
expect_run_fails 'symlinked secrets file' 'is a symlink' --config "${CONFIG}" --secrets "${SCRATCH}/secrets-link.env" \
  --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}" --dry-run
secrets_case() { # LABEL MESSAGE CONTENT
  printf '%s' "$3" >"${SECRETS}"
  chmod 600 "${SECRETS}"
  expect_run_fails "$1" "$2" "${ARGS[@]}" --dry-run
  assert_untouched "$1"
}
secrets_case 'secrets file that tries to change the passphrase' 'line 3: unexpected key' \
  "FICUS_BACKUP_S3_ACCESS_KEY=${NEW_AK}
FICUS_BACKUP_S3_SECRET_KEY='${OLD_SK}'
FICUS_BACKUP_PASSPHRASE='${OLD_SK}'
"
secrets_case 'secrets file without the secret key' 'does not set FICUS_BACKUP_S3_SECRET_KEY' \
  "FICUS_BACKUP_S3_ACCESS_KEY=${NEW_AK}
"
secrets_case 'secrets file with a double-quoted (shell-evaluated) value' 'is not a bare word or a single-quoted string' \
  "FICUS_BACKUP_S3_ACCESS_KEY=${NEW_AK}
FICUS_BACKUP_S3_SECRET_KEY=\"${OLD_SK}\"
"
secrets_case 'secrets file with a non-assignment line' 'line 2 is not a KEY=VALUE assignment' \
  "FICUS_BACKUP_S3_ACCESS_KEY=${NEW_AK}
export FICUS_BACKUP_S3_SECRET_KEY='${OLD_SK}'
"
write_secrets "${NEW_AK}" "${NEW_SK}"

# --- not applicable: backups were never enabled ----------------------------------
yq -i '.backup.enabled = false' "${CONFIG}"
run "${ARGS[@]}"
expect_eq 'backup.enabled false: exits 3 (not applicable)' "${RC}" 3
expect_contains 'backup.enabled false: says so' "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT=not-applicable'
cp "${PRISTINE}/tau-setup.yaml" "${CONFIG}"
assert_untouched 'backup.enabled false'

# --- backup.enabled that cannot be read is a FAILURE (exit 1), never "not
# applicable" (exit 3): an invalid value, and a yq read error.
enabled_fails() { # LABEL [ENV_ASSIGNMENT]
  local label=$1
  shift
  RC=0
  OUT=$(env "$@" "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq "${label}: exits 1, not 3" "${RC}" 1
  expect_not_contains "${label}: prints no RESULT marker" "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT='
  expect_contains "${label}: says it could not read backup.enabled" "${OUT}" 'could not read backup.enabled'
}
yq -i '.backup.enabled = "maybe"' "${CONFIG}"
enabled_fails 'backup.enabled: maybe'
cp "${PRISTINE}/tau-setup.yaml" "${CONFIG}"
enabled_fails 'a yq failure reading backup.enabled' FICUS_TEST_FAIL_YQ_READ=.backup.enabled
assert_untouched 'unreadable backup.enabled'
expect_eq 'unreadable backup.enabled: backs nothing up' "$(backup_count)" 0

# --- xtrace inherited from the caller must never trace a secret
RC=0
OUT=$(bash -x "${RETARGET}" "${ARGS[@]}" --dry-run 2>&1) || RC=$?
expect_eq 'bash -x --dry-run: exits zero' "${RC}" 0
assert_no_secrets 'bash -x --dry-run' "${OUT}"
RC=0
OUT=$(env SHELLOPTS=xtrace "${RETARGET}" "${ARGS[@]}" --dry-run 2>&1) || RC=$?
expect_eq 'SHELLOPTS=xtrace --dry-run: exits zero' "${RC}" 0
assert_no_secrets 'SHELLOPTS=xtrace --dry-run' "${OUT}"

# --- a non-ASCII passphrase (valid UTF-8 + a lone 0xff byte) is carried over,
# not refused, whatever locale the caller runs in (the script forces C).
NONASCII_PASSPHRASE=$'p\xc3\xa4ss \xe2\x9c\x93 \xff \'q\' end'
lib render_backup_env_content real "${OLD_AK}" "${OLD_SK}" "${NONASCII_PASSPHRASE}" >"${SCRATCH}/nonascii-backup.env"
for loc in C C.UTF-8 en_US.UTF-8; do
  cp "${SCRATCH}/nonascii-backup.env" "${BACKUP_ENV_TARGET}"
  RC=0
  OUT=$(LC_ALL=${loc} "${RETARGET}" "${ARGS[@]}" --dry-run 2>&1) || RC=$?
  expect_eq "non-ASCII passphrase (caller LC_ALL=${loc}): accepted" "${RC}" 0
  expect_not_contains "non-ASCII passphrase (caller LC_ALL=${loc}): never printed" "${OUT}" "${NONASCII_PASSPHRASE}"
done
cp "${PRISTINE}/backup.env" "${BACKUP_ENV_TARGET}"

# --- the live files ---------------------------------------------------------------
mv "${BACKUP_SCRIPT_PATH}" "${SCRATCH}/held"
expect_run_fails 'no installed tau-backup.sh' 'phase_backup never completed' "${ARGS[@]}" --dry-run
mv "${SCRATCH}/held" "${BACKUP_SCRIPT_PATH}"
mv "${BACKUP_ENV_TARGET}" "${SCRATCH}/held"
expect_run_fails 'no installed backup.env' 'phase_backup never completed' "${ARGS[@]}" --dry-run
mv "${SCRATCH}/held" "${BACKUP_ENV_TARGET}"

live_env_case() { # LABEL MESSAGE CONTENT
  printf '%s' "$3" >"${BACKUP_ENV_TARGET}"
  expect_run_fails "$1" "$2" "${ARGS[@]}" --dry-run
  cp "${PRISTINE}/backup.env" "${BACKUP_ENV_TARGET}"
}
live_env_case 'backup.env without a passphrase' 'has no FICUS_BACKUP_PASSPHRASE' \
  "FICUS_BACKUP_S3_ACCESS_KEY='${OLD_AK}'
FICUS_BACKUP_S3_SECRET_KEY='${OLD_SK}'
"
live_env_case 'backup.env with a key re-rendering would drop' 'line 8: unexpected key' \
  "$(cat "${PRISTINE}/backup.env")
EXTRA_THING='keep me'
"
live_env_case 'backup.env with a double-quoted passphrase' 'not in the format setup-host.sh writes' \
  "FICUS_BACKUP_S3_ACCESS_KEY='${OLD_AK}'
FICUS_BACKUP_S3_SECRET_KEY='${OLD_SK}'
FICUS_BACKUP_PASSPHRASE=\"${OLD_SK}\"
"
# A bare (unquoted) value is accepted and carried over with its VALUE intact.
printf "FICUS_BACKUP_S3_ACCESS_KEY=%s\nFICUS_BACKUP_S3_SECRET_KEY=%s\nFICUS_BACKUP_PASSPHRASE=bare-passphrase-123\n" "${OLD_AK}" old >"${BACKUP_ENV_TARGET}"
run "${ARGS[@]}" --dry-run
expect_eq 'backup.env with bare values: accepted' "${RC}" 0
cp "${PRISTINE}/backup.env" "${BACKUP_ENV_TARGET}"

live_script_case() { # LABEL MESSAGE SED_EXPR
  sed -e "$3" "${PRISTINE}/tau-backup.sh" >"${BACKUP_SCRIPT_PATH}"
  expect_run_fails "$1" "$2" "${ARGS[@]}" --dry-run
  cp "${PRISTINE}/tau-backup.sh" "${BACKUP_SCRIPT_PATH}"
}
live_script_case 'tau-backup.sh without an S3_PREFIX line' "has no S3_PREFIX='…' line" '/^S3_PREFIX=/d'
live_script_case 'tau-backup.sh that reads a different backup.env' 'refusing to write a file it does not read' \
  "s|^BACKUP_ENV_FILE=.*|BACKUP_ENV_FILE='/somewhere/else.env'|"
live_script_case 'tau-backup.sh whose DEST the sed render would corrupt' "contains '|', '&' or '\\'" \
  "s|^DEST=.*|DEST='/opt/a\\&b'|"
live_script_case 'tau-backup.sh with an empty prefix' 'has an empty S3_PREFIX' "s|^S3_PREFIX=.*|S3_PREFIX=''|"

# The template must travel with the script.
TOOLKIT_NO_TMPL="${SCRATCH}/toolkit-no-tmpl"
mkdir -p "${TOOLKIT_NO_TMPL}"
cp "${RETARGET}" "${LIB}" "${TOOLKIT_NO_TMPL}/"
rc=0
out=$("${TOOLKIT_NO_TMPL}/retarget-backup.sh" "${ARGS[@]}" --dry-run 2>&1) || rc=$?
expect_eq 'no tau-backup.sh.tmpl next to the script: exits 1' "${rc}" 1
expect_contains 'no tau-backup.sh.tmpl next to the script: names it' "${out}" 'tau-backup.sh.tmpl not found next to this script'

# Read-side injection (dry-run reaches every read): a silently short read of
# the live backup.env, and a read error on the secrets file, must refuse.
FICUS_TEST_CAT_SHORT="${BACKUP_ENV_TARGET}" run "${ARGS[@]}" --dry-run
expect_eq 'short read of backup.env (dry-run): exits 1' "${RC}" 1
expect_contains 'short read of backup.env (dry-run): says so' "${OUT}" "read of ${BACKUP_ENV_TARGET} came up short"
FICUS_TEST_CAT_FAIL="${SECRETS}" run "${ARGS[@]}" --dry-run
expect_eq 'read error on the secrets file (dry-run): exits 1' "${RC}" 1
expect_contains 'read error on the secrets file (dry-run): says so' "${OUT}" "could not read --secrets file"
assert_untouched 'after the validation cases'

if [[ ${EUID} -ne 0 ]]; then
  run "${ARGS[@]}"
  expect_eq 'a real run as non-root: exits 1' "${RC}" 1
  expect_contains 'a real run as non-root: says it needs root' "${OUT}" 'must run as root'
  assert_untouched 'a real run as non-root'
  expect_eq 'a real run as non-root never contacts S3' "$(grep -c '^curl ' "${SHIM_LOG}" || true)" 0
fi

# =============================================================================
# Mutation phase — needs real root
# =============================================================================
if [[ ${EUID} -eq 0 ]]; then
  echo 'TAU retarget-backup mutation-phase section: ENABLED'

  # Non-default ownership, to prove it is carried over rather than reset.
  set_modes() {
    chown root:daemon "${BACKUP_SCRIPT_PATH}"
    chmod 750 "${BACKUP_SCRIPT_PATH}"
    chown root:root "${BACKUP_ENV_TARGET}"
    chmod 600 "${BACKUP_ENV_TARGET}"
  }
  mode_of() { stat -c '%a %U:%G' "$1"; }
  reset_fixture
  set_modes
  cp -p "${BACKUP_SCRIPT_PATH}" "${PRISTINE}/tau-backup.sh"
  EXPECTED_SCRIPT_MODE=$(mode_of "${BACKUP_SCRIPT_PATH}")
  EXPECTED_ENV_MODE=$(mode_of "${BACKUP_ENV_TARGET}")

  assert_retargeted() { # LABEL
    local label=$1
    expect_eq "${label}: tau-backup.sh is exactly the new render" "$(same "${BACKUP_SCRIPT_PATH}" "${SCRATCH}/expected-tau-backup.sh")" same
    expect_eq "${label}: backup.env is exactly the new render" "$(same "${BACKUP_ENV_TARGET}" "${SCRATCH}/expected-backup.env")" same
    # Only the three S3 lines changed in the script; DEST/HOME_DIR/DB_*/prefix carried over.
    expect_eq "${label}: tau-backup.sh differs from the old one in exactly the three S3 lines" \
      "$(diff "${PRISTINE}/tau-backup.sh" "${BACKUP_SCRIPT_PATH}" | grep -c '^[<>]' || true)" 6
    expect_eq "${label}: the passphrase line is byte-identical to before" \
      "$(grep '^FICUS_BACKUP_PASSPHRASE=' "${BACKUP_ENV_TARGET}")" "$(grep '^FICUS_BACKUP_PASSPHRASE=' "${PRISTINE}/backup.env")"
    expect_eq "${label}: backup.env still sources to the exact passphrase" \
      "$(bash -c '. "$1"; printf %s "${FICUS_BACKUP_PASSPHRASE}"' _ "${BACKUP_ENV_TARGET}")" "${PASSPHRASE}"
    expect_eq "${label}: backup.env sources to the new secret key" \
      "$(bash -c '. "$1"; printf %s "${FICUS_BACKUP_S3_SECRET_KEY}"' _ "${BACKUP_ENV_TARGET}")" "${NEW_SK}"
    expect_eq "${label}: tau-backup.sh mode/owner preserved" "$(mode_of "${BACKUP_SCRIPT_PATH}")" "${EXPECTED_SCRIPT_MODE}"
    expect_eq "${label}: backup.env mode/owner preserved" "$(mode_of "${BACKUP_ENV_TARGET}")" "${EXPECTED_ENV_MODE}"
    expect_eq "${label}: yaml backup.s3_endpoint" "$(yq -r '.backup.s3_endpoint' "${CONFIG}")" "${NEW_ENDPOINT}"
    expect_eq "${label}: yaml backup.s3_region" "$(yq -r '.backup.s3_region' "${CONFIG}")" "${NEW_REGION}"
    expect_eq "${label}: yaml backup.s3_bucket" "$(yq -r '.backup.s3_bucket' "${CONFIG}")" "${NEW_BUCKET}"
    expect_eq "${label}: every other yaml key untouched" \
      "$(yq -r 'del(.backup.s3_endpoint, .backup.s3_region, .backup.s3_bucket)' "${CONFIG}")" \
      "$(yq -r 'del(.backup.s3_endpoint, .backup.s3_region, .backup.s3_bucket)' "${PRISTINE}/tau-setup.yaml")"
    expect_eq "${label}: systemd was never touched (timer/schedule unchanged)" "$(grep -c '^systemctl ' "${SHIM_LOG}" || true)" 0
    expect_eq "${label}: no staged file is left behind" "$(staged_count)" 0
  }
  assert_verified() { # LABEL — the S3 probe ran once, as a signed list with the new key off argv
    local label=$1
    expect_eq "${label}: verified with exactly one S3 request" "$(grep -c '^curl ' "${SHIM_LOG}" || true)" 1
    expect_contains "${label}: the request is a max-keys=1 list of the new bucket under this host's prefix" \
      "$(cat "${SHIM_LOG}")" "${NEW_ENDPOINT}/${NEW_BUCKET}?list-type=2&max-keys=1&prefix=${PREFIX}/"
    expect_contains "${label}: the request is SigV4-signed for the new region" "$(cat "${SHIM_LOG}")" "--aws-sigv4 aws:amz:${NEW_REGION}:s3"
    expect_not_contains "${label}: the secret key is not on curl's argv" "$(cat "${SHIM_LOG}")" "${NEW_SK}"
    expect_eq "${label}: curl got the new key through its --config file" "$(cat "${CURL_CONFIG_SEEN}" 2>/dev/null)" \
      "$(lib _s3_curl_user_config "${NEW_AK}" "${NEW_SK}")"
  }

  # --- run 1 --------------------------------------------------------------------
  run1_stdout=$("${RETARGET}" "${ARGS[@]}" 2>"${SCRATCH}/run1.err") && run1_rc=0 || run1_rc=$?
  run1_all="${run1_stdout}
$(cat "${SCRATCH}/run1.err")"
  expect_eq 'run 1: exits zero' "${run1_rc}" 0
  [[ ${run1_rc} -eq 0 ]] || printf '%s\n' "${run1_all}" >&2
  expect_eq 'run 1: stdout is exactly the result markers' "${run1_stdout}" \
    "FICUS_RETARGET_BACKUP_RESULT=retargeted
FICUS_RETARGET_BACKUP_ENDPOINT=${NEW_ENDPOINT}
FICUS_RETARGET_BACKUP_REGION=${NEW_REGION}
FICUS_RETARGET_BACKUP_BUCKET=${NEW_BUCKET}"
  assert_no_secrets 'run 1' "${run1_all}"
  assert_retargeted 'run 1'
  assert_verified 'run 1'
  expect_eq 'run 1: backed up all three changed files' "$(backup_count)" 3
  env_backup=$(compgen -G "${SCRATCH}/etc/backup.env.bak-*" | head -n 1)
  expect_eq 'run 1: the backup.env backup keeps the old content' "$(same "${env_backup}" "${PRISTINE}/backup.env")" same
  expect_eq 'run 1: the backup.env backup is still 0600' "$(stat -c '%a' "${env_backup}")" 600

  # --- run 2: idempotent ----------------------------------------------------------
  cp -p "${BACKUP_SCRIPT_PATH}" "${SCRATCH}/after1-script"
  cp -p "${BACKUP_ENV_TARGET}" "${SCRATCH}/after1-env"
  cp -p "${CONFIG}" "${SCRATCH}/after1-yaml"
  : >"${SHIM_LOG}"
  run "${ARGS[@]}"
  expect_eq 'run 2 (idempotent re-run): exits zero' "${RC}" 0
  expect_contains 'run 2: reports unchanged' "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT=unchanged'
  assert_no_secrets 'run 2' "${OUT}"
  assert_retargeted 'run 2'
  assert_verified 'run 2 (still verifies)'
  expect_eq 'run 2: tau-backup.sh byte-identical to after run 1' "$(same "${BACKUP_SCRIPT_PATH}" "${SCRATCH}/after1-script")" same
  expect_eq 'run 2: backup.env byte-identical to after run 1' "$(same "${BACKUP_ENV_TARGET}" "${SCRATCH}/after1-env")" same
  expect_eq 'run 2: yaml byte-identical to after run 1' "$(same "${CONFIG}" "${SCRATCH}/after1-yaml")" same
  expect_eq 'run 2: writes no new backups' "$(backup_count)" 3

  # --- without --region: the live region is kept --------------------------------------
  reset_fixture
  set_modes
  run --config "${CONFIG}" --secrets "${SECRETS}" --bucket "${NEW_BUCKET}" --endpoint "${NEW_ENDPOINT}"
  expect_eq 'no --region: exits zero' "${RC}" 0
  expect_eq 'no --region: tau-backup.sh keeps the live region' "$(grep '^S3_REGION=' "${BACKUP_SCRIPT_PATH}")" "S3_REGION='${OLD_REGION}'"
  expect_eq 'no --region: yaml keeps the live region' "$(yq -r '.backup.s3_region' "${CONFIG}")" "${OLD_REGION}"

  # --- secrets file owned by someone else -----------------------------------------------
  reset_fixture
  set_modes
  chown nobody "${SECRETS}"
  run "${ARGS[@]}"
  expect_eq 'secrets file owned by another user: exits 1' "${RC}" 1
  expect_contains 'secrets file owned by another user: says so' "${OUT}" 'is not owned by the invoking user'
  assert_untouched 'secrets file owned by another user'

  # ===========================================================================
  # FAILURE INJECTION — each from the pre-retarget state, as a real run.
  # ===========================================================================
  # Cases that must leave EVERYTHING as it was (and back nothing up when they
  # fail before step 2).
  inject_untouched() { # LABEL MESSAGE BACKUPS_EXPECTED ENV_ASSIGNMENTS...
    local label=$1 msg=$2 backups=$3
    shift 3
    reset_fixture
    set_modes
    RC=0
    OUT=$(env "$@" "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
    expect_eq "${label}: exits 1" "${RC}" 1
    expect_contains "${label}: says why" "${OUT}" "${msg}"
    assert_no_secrets "${label}" "${OUT}"
    assert_untouched "${label}"
    [[ ${backups} == any ]] || expect_eq "${label}: backs nothing up" "$(backup_count)" "${backups}"
    expect_not_contains "${label}: never reports success" "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT='
  }
  inject_untouched 'S3 refuses the new key (403)' 'failed verification — nothing was changed' 0 FICUS_TEST_S3_STATUS=403
  inject_untouched 'S3 unreachable (curl exit 7)' 'curl exit 7' 0 FICUS_TEST_CURL_EXIT=7
  inject_untouched 'short read of the live backup.env' "read of ${BACKUP_ENV_TARGET} came up short" 0 FICUS_TEST_CAT_SHORT="${BACKUP_ENV_TARGET}"
  inject_untouched 'short read of the live tau-backup.sh' "read of ${BACKUP_SCRIPT_PATH} came up short" 0 FICUS_TEST_CAT_SHORT="${BACKUP_SCRIPT_PATH}"
  inject_untouched 'read error on the secrets file' 'could not read --secrets file' 0 FICUS_TEST_CAT_FAIL="${SECRETS}"
  inject_untouched 'backing up backup.env fails' "could not back up ${BACKUP_ENV_TARGET} — nothing was changed" any FICUS_TEST_FAIL_CP=backup.env
  inject_untouched 'staging mktemp fails for backup.env' "could not stage the new ${BACKUP_ENV_TARGET} — nothing was changed" any FICUS_TEST_FAIL_MKTEMP=.backup.env.
  inject_untouched 'chmod of the staged tau-backup.sh fails' "could not stage the new ${BACKUP_SCRIPT_PATH} — nothing was changed" any FICUS_TEST_FAIL_CHMOD=.tau-backup.sh.
  inject_untouched 'chown of the staged backup.env fails' "could not stage the new ${BACKUP_ENV_TARGET} — nothing was changed" any FICUS_TEST_FAIL_CHOWN=.backup.env.
  inject_untouched 'installing tau-backup.sh (rename) fails' "could not install the new ${BACKUP_SCRIPT_PATH} — nothing was changed" any FICUS_TEST_FAIL_MV=tau-backup.sh:1
  inject_untouched 'installing backup.env fails after tau-backup.sh was swapped' \
    "${BACKUP_SCRIPT_PATH} was restored to its previous content" any FICUS_TEST_FAIL_MV=backup.env:1
  if [[ -e /proc/self/fd/1 ]]; then
    inject_untouched 'the staged write of backup.env fails' "failed to write the staged replacement for ${BACKUP_ENV_TARGET}" any \
      BASH_ENV="${FAIL_WRITE_ENV}" FICUS_TEST_FAIL_WRITE=/.backup.env.
    inject_untouched 'the staged write of tau-backup.sh fails' "failed to write the staged replacement for ${BACKUP_SCRIPT_PATH}" any \
      BASH_ENV="${FAIL_WRITE_ENV}" FICUS_TEST_FAIL_WRITE=/.tau-backup.sh.
  else
    printf 'SKIP: staged-write injection needs /proc (Linux)\n' >&2
  fi

  # --- xtrace on a REAL run: still no secret in the output --------------------
  reset_fixture
  set_modes
  RC=0
  OUT=$(bash -x "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq 'bash -x real run: exits zero' "${RC}" 0
  assert_no_secrets 'bash -x real run' "${OUT}"
  assert_retargeted 'bash -x real run'

  # --- non-ASCII passphrase survives a real run byte-for-byte, any caller locale
  for loc in C C.UTF-8 en_US.UTF-8; do
    reset_fixture
    set_modes
    cp "${SCRATCH}/nonascii-backup.env" "${BACKUP_ENV_TARGET}"
    before_line=$(grep '^FICUS_BACKUP_PASSPHRASE=' "${BACKUP_ENV_TARGET}" | od -An -tx1 | tr -d ' \n')
    RC=0
    OUT=$(LC_ALL=${loc} "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
    expect_eq "non-ASCII passphrase real run (caller LC_ALL=${loc}): exits zero" "${RC}" 0
    expect_eq "non-ASCII passphrase real run (caller LC_ALL=${loc}): passphrase line byte-identical" \
      "$(grep '^FICUS_BACKUP_PASSPHRASE=' "${BACKUP_ENV_TARGET}" | od -An -tx1 | tr -d ' \n')" "${before_line}"
    expect_eq "non-ASCII passphrase real run (caller LC_ALL=${loc}): sources to the exact bytes" \
      "$(bash -c '. "$1"; printf %s "${FICUS_BACKUP_PASSPHRASE}"' _ "${BACKUP_ENV_TARGET}" | od -An -tx1 | tr -d ' \n')" \
      "$(printf '%s' "${NONASCII_PASSPHRASE}" | od -An -tx1 | tr -d ' \n')"
    expect_eq "non-ASCII passphrase real run (caller LC_ALL=${loc}): new secret key installed" \
      "$(bash -c '. "$1"; printf %s "${FICUS_BACKUP_S3_SECRET_KEY}"' _ "${BACKUP_ENV_TARGET}")" "${NEW_SK}"
    expect_not_contains "non-ASCII passphrase real run (caller LC_ALL=${loc}): never printed" "${OUT}" "${NONASCII_PASSPHRASE}"
  done

  # --- SIGHUP (a dropped SSH session) during the two renames is ignored -------
  reset_fixture
  set_modes
  RC=0
  OUT=$(FICUS_TEST_HUP_ON_MV=tau-backup.sh "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq 'SIGHUP between the renames: the run still completes (exit 0)' "${RC}" 0
  expect_contains 'SIGHUP between the renames: reports retargeted' "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT=retargeted'
  assert_retargeted 'SIGHUP between the renames'
  # ...and the default disposition is back afterwards: a SIGHUP during the
  # yaml step (after the swap block) terminates the script as usual.
  reset_fixture
  set_modes
  RC=0
  OUT=$(FICUS_TEST_HUP_ON_YQ_WRITE=1 "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq 'SIGHUP after the swap block: default disposition restored (killed, 128+1)' "${RC}" 129
  expect_eq 'SIGHUP after the swap block: both files were already swapped together' \
    "$(same "${BACKUP_SCRIPT_PATH}" "${SCRATCH}/expected-tau-backup.sh") $(same "${BACKUP_ENV_TARGET}" "${SCRATCH}/expected-backup.env")" 'same same'
  # ...and a HUP handler the caller already had is put back, not dropped.
  HUP_TRAP_ENV="${SCRATCH}/hup-trap.bash"
  printf '%s\n' "trap 'builtin printf \"hup-handler-ran\\n\" >&2' HUP" >"${HUP_TRAP_ENV}"
  reset_fixture
  set_modes
  RC=0
  OUT=$(BASH_ENV="${HUP_TRAP_ENV}" FICUS_TEST_HUP_ON_MV=tau-backup.sh FICUS_TEST_HUP_ON_YQ_WRITE=1 "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq 'pre-existing HUP handler: the run completes' "${RC}" 0
  expect_contains 'pre-existing HUP handler: restored after the swap (it ran for the yaml-step SIGHUP)' "${OUT}" 'hup-handler-ran'
  assert_retargeted 'pre-existing HUP handler'

  # backup.env's rename fails AND putting tau-backup.sh back fails: the
  # message must say the restore FAILED and name the backup to copy back.
  reset_fixture
  set_modes
  RC=0
  OUT=$(FICUS_TEST_FAIL_MV='backup.env:1 tau-backup.sh:2' "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq 'restore failure: exits 1' "${RC}" 1
  expect_contains 'restore failure: says the restore FAILED' "${OUT}" "FAILED to restore ${BACKUP_SCRIPT_PATH}"
  expect_match 'restore failure: names the backup to copy back' "${OUT}" "copy ${SCRATCH}/bin/tau-backup\\.sh\\.bak-[^ ]+ back over"
  expect_not_contains 'restore failure: does not claim a rollback' "${OUT}" 'was restored to its previous content'
  expect_eq 'restore failure: backup.env still holds the old key (its swap never happened)' "$(same "${BACKUP_ENV_TARGET}" "${PRISTINE}/backup.env")" same
  expect_eq 'restore failure: no staged file is left behind' "$(staged_count)" 0
  named_backup=$(compgen -G "${SCRATCH}/bin/tau-backup.sh.bak-*" | head -n 1)
  expect_eq 'restore failure: the named backup holds the old tau-backup.sh' "$(same "${named_backup}" "${PRISTINE}/tau-backup.sh")" same
  run "${ARGS[@]}"
  expect_eq 'restore failure: a plain re-run completes the retarget' "${RC}" 0
  assert_retargeted 'restore failure, then re-run'

  # The yaml write fails AFTER the files are live: say exactly that, and a
  # re-run finishes by rewriting only the yaml.
  reset_fixture
  set_modes
  RC=0
  OUT=$(FICUS_TEST_FAIL_YQ_WRITE=1 "${RETARGET}" "${ARGS[@]}" 2>&1) || RC=$?
  expect_eq 'yaml write failure: exits 1' "${RC}" 1
  expect_contains 'yaml write failure: says the files ARE retargeted' "${OUT}" 'the backup files ARE retargeted'
  expect_eq 'yaml write failure: tau-backup.sh is the new render' "$(same "${BACKUP_SCRIPT_PATH}" "${SCRATCH}/expected-tau-backup.sh")" same
  expect_eq 'yaml write failure: backup.env is the new render' "$(same "${BACKUP_ENV_TARGET}" "${SCRATCH}/expected-backup.env")" same
  expect_eq 'yaml write failure: the yaml is untouched' "$(same "${CONFIG}" "${PRISTINE}/tau-setup.yaml")" same
  backups_before_rerun=$(backup_count)
  : >"${SHIM_LOG}"
  run "${ARGS[@]}"
  expect_eq 'yaml write failure, then re-run: exits zero' "${RC}" 0
  expect_contains 'yaml write failure, then re-run: reports retargeted' "${OUT}" 'FICUS_RETARGET_BACKUP_RESULT=retargeted'
  assert_retargeted 'yaml write failure, then re-run'
  expect_eq 'yaml write failure, then re-run: backs up only the yaml' "$(backup_count)" "$((backups_before_rerun + 1))"
else
  printf 'SKIP: not running as root (EUID=%s) — the mutation-phase test needs this whole test process to be real root (retarget-backup.sh has no sudo fallback); run via `sudo env "PATH=$PATH" bash scripts/setup/retarget-backup.test.sh` (as CI does) to execute it\n' "${EUID}" >&2
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
