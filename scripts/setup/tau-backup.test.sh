#!/usr/bin/env bash
# tau-backup.test.sh — round-trip test of the RENDERED tau-backup.sh.tmpl.
#
# This does not exercise phase_backup()'s rendering machinery in
# setup-host.sh (that needs a full cfg_load + secrets-resolution
# environment); instead it renders the template directly with the same
# @TOKEN@ substitutions setup-host.sh's render_backup_script() performs, then
# runs the rendered script for real against a scratch DEST/.env + HOME_DIR
# tree and a fake pg_dump (via the FICUS_BACKUP_PG_DUMP_CMD test seam — no live
# postgres needed), with FICUS_BACKUP_DRY_RUN=1 so it stops before contacting
# S3. Asserts the resulting encrypted artifact decrypts + untars back to
# exactly the inputs (db dump, HOME_DIR tree, .env).
#
# Run: bash scripts/setup/tau-backup.test.sh
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)

PASS=0 FAIL=0
expect_eq() { # DESCRIPTION ACTUAL EXPECTED
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — expected %q, got %q\n' "$1" "$3" "$2" >&2
  fi
}
expect_file_exists() { # DESCRIPTION FILE
  if [[ -f $2 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %q does not exist\n' "$1" "$2" >&2
  fi
}
expect_file_absent() { # DESCRIPTION FILE
  if [[ ! -f $2 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %q unexpectedly exists\n' "$1" "$2" >&2
  fi
}

SCRATCH=$(mktemp -d -t tau-backup-test.XXXXXX)
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT

DEST="${SCRATCH}/dest"
HOME_DIR="${SCRATCH}/home/.tau"
WORKDIR="${SCRATCH}/work"
BACKUP_ENV_FILE="${SCRATCH}/backup.env"
RENDERED="${SCRATCH}/tau-backup.sh"
DECRYPT_DIR="${SCRATCH}/decrypted"

mkdir -p "${DEST}" "${HOME_DIR}/workspace/agent-1" "${DECRYPT_DIR}"
printf 'FICUS_ENCRYPTION_KEY=test-encryption-key-envelope\nDATABASE_URL=postgres://postgres:pw@127.0.0.1:5432/tau\n' >"${DEST}/.env"
printf 'agent memory contents\n' >"${HOME_DIR}/workspace/agent-1/notes.md"
printf 'shared context\n' >"${HOME_DIR}/context.md"

# --- render the template with the same tokens render_backup_script() uses --
sed \
  -e "s|@DEST@|${DEST}|g" \
  -e "s|@HOME_DIR@|${HOME_DIR}|g" \
  -e "s|@DB_MODE@|container|g" \
  -e "s|@DB_CONTAINER@|tau-postgres-test-unused|g" \
  -e "s|@S3_ENDPOINT@|https://s3.invalid.example|g" \
  -e "s|@S3_REGION@|test-region|g" \
  -e "s|@S3_BUCKET@|test-bucket|g" \
  -e "s|@S3_PREFIX@|tenants/test|g" \
  -e "s|@BACKUP_ENV_FILE@|${BACKUP_ENV_FILE}|g" \
  "${SCRIPT_DIR}/tau-backup.sh.tmpl" >"${RENDERED}"
chmod 755 "${RENDERED}"

unrendered_rc=0
grep -q '@[A-Z_]*@' "${RENDERED}" && unrendered_rc=1
expect_eq 'no @TOKEN@ placeholders left unrendered' "${unrendered_rc}" '0'

# --- backup.env (0600) with a passphrase; S3 creds are fake/unused in dry run
PASSPHRASE='test-passphrase-do-not-use-in-prod'
printf 'FICUS_BACKUP_S3_ACCESS_KEY=unused-in-dry-run\nFICUS_BACKUP_S3_SECRET_KEY=unused-in-dry-run\nFICUS_BACKUP_PASSPHRASE=%s\n' "${PASSPHRASE}" >"${BACKUP_ENV_FILE}"
chmod 600 "${BACKUP_ENV_FILE}"

# --- fake pg_dump seam: write deterministic content instead of shelling to a
# live postgres (see tau-backup.sh.tmpl's FICUS_BACKUP_PG_DUMP_CMD test seam).
FAKE_DUMP_CONTENT='FAKE-PG-DUMP-CONTENT-1234'
FAKE_PG_DUMP="${SCRATCH}/fake-pg-dump.sh"
cat >"${FAKE_PG_DUMP}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '${FAKE_DUMP_CONTENT}' >"\$1"
EOF
chmod 755 "${FAKE_PG_DUMP}"

# --- run the rendered script for real, dry-run (stops before upload/retention)
set +e
FICUS_BACKUP_DRY_RUN=1 \
  FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${WORKDIR}" \
  "${RENDERED}"
run_rc=$?
set -e
expect_eq 'rendered tau-backup.sh exits 0 under FICUS_BACKUP_DRY_RUN=1' "${run_rc}" '0'

TODAY=$(date -u '+%Y-%m-%d')
ENC_FILE="${WORKDIR}/${TODAY}.tar.gz.enc"
expect_file_exists "encrypted artifact left on disk at ${ENC_FILE}" "${ENC_FILE}"
expect_file_absent 'dry run pruned the unencrypted intermediate tar file' "${WORKDIR}/backup.tar.gz"
expect_file_absent 'dry run pruned the unencrypted intermediate db dump' "${WORKDIR}/db.dump"

# --- decrypt + untar and verify it round-trips back to the exact inputs -----
DECRYPTED_TAR="${SCRATCH}/decrypted.tar.gz"
openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:${PASSPHRASE}" -in "${ENC_FILE}" -out "${DECRYPTED_TAR}"
expect_file_exists 'decryption with the correct passphrase succeeds' "${DECRYPTED_TAR}"

tar -xzf "${DECRYPTED_TAR}" -C "${DECRYPT_DIR}"

expect_eq 'db.dump round-trips' "$(cat "${DECRYPT_DIR}/db.dump" 2>/dev/null || echo MISSING)" "${FAKE_DUMP_CONTENT}"
expect_eq '.env round-trips (carries FICUS_ENCRYPTION_KEY into the envelope)' \
  "$(cat "${DECRYPT_DIR}/.env" 2>/dev/null || echo MISSING)" \
  "$(cat "${DEST}/.env")"
expect_eq 'HOME_DIR file round-trips (context.md)' \
  "$(cat "${DECRYPT_DIR}/.tau/context.md" 2>/dev/null || echo MISSING)" 'shared context'
expect_eq 'HOME_DIR nested file round-trips (workspace/agent-1/notes.md)' \
  "$(cat "${DECRYPT_DIR}/.tau/workspace/agent-1/notes.md" 2>/dev/null || echo MISSING)" 'agent memory contents'

# --- a wrong passphrase must NOT decrypt (encryption is doing something) ----
wrong_rc=0
openssl enc -d -aes-256-cbc -pbkdf2 -pass 'pass:wrong-passphrase' -in "${ENC_FILE}" -out "${SCRATCH}/should-fail.tar.gz" >/dev/null 2>&1 || wrong_rc=$?
expect_eq 'decryption with the WRONG passphrase fails (non-zero exit)' "$([[ ${wrong_rc} -ne 0 ]] && echo yes || echo no)" 'yes'

# --- Finding 1 (review): a mid-run failure (e.g. the S3 upload step dying)
# must leave NO workdir/artifact behind — only FICUS_BACKUP_DRY_RUN=1 may do
# that. Force the upload to fail via a `curl` function override, exported so
# the rendered script's own `#!/usr/bin/env bash` process inherits it (a
# forced-failure seam — no real/unreachable network call needed).
FAIL_WORKDIR="${SCRATCH}/fail-work"
curl() { return 1; }
export -f curl
set +e
FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${FAIL_WORKDIR}" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/fail-run.stderr"
fail_run_rc=$?
set -e
unset -f curl
expect_eq 'a failed upload exits non-zero' "$([[ ${fail_run_rc} -ne 0 ]] && echo yes || echo no)" 'yes'
expect_eq 'a failed upload dies with an upload-failure message' \
  "$([[ $(cat "${SCRATCH}/fail-run.stderr") == *'upload to S3 failed'* ]] && echo yes || echo no)" 'yes'
expect_eq 'a failed (non-dry-run) run leaves NO workdir behind (no /tmp leak)' \
  "$([[ -e ${FAIL_WORKDIR} ]] && echo leaked || echo clean)" 'clean'

# --- Finding 3b (review): retention must only ever delete keys matching this
# backup's own <prefix>/<YYYY-MM-DD>.tar.gz.enc shape — defense-in-depth
# behind phase_backup's "backup.s3_prefix must be non-empty" validation (see
# the setup-host.sh test below). Mock curl (same exported-function seam) to
# serve a fake S3 ListObjectsV2 body with 16 correctly-shaped keys plus two
# that must NEVER be deleted: one under the right prefix but the wrong shape,
# and one with the right shape but under a DIFFERENT prefix (simulating a
# listing that, for any reason, returns objects outside our own prefix).
RETENTION_WORKDIR="${SCRATCH}/retention-work"
DELETE_LOG="${SCRATCH}/delete.log"
LIST_BODY_FILE="${SCRATCH}/list-body.xml"
: >"${DELETE_LOG}"
{
  printf '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>'
  for i in $(seq -w 1 16); do
    printf '<Contents><Key>tenants/test/2024-01-%s.tar.gz.enc</Key></Contents>' "${i}"
  done
  printf '<Contents><Key>tenants/test/README.txt</Key></Contents>'
  printf '<Contents><Key>other-tenant/2024-01-01.tar.gz.enc</Key></Contents>'
  printf '</ListBucketResult>'
} >"${LIST_BODY_FILE}"

curl() {
  local a is_delete=0 url=''
  for a in "$@"; do
    [[ ${a} == DELETE ]] && is_delete=1
    url=${a}
  done
  if [[ ${is_delete} -eq 1 ]]; then
    printf '%s\n' "${url}" >>"${DELETE_LOG}"
    return 0
  fi
  if [[ ${url} == *'list-type=2'* ]]; then
    cat "${LIST_BODY_FILE}"
    return 0
  fi
  return 0 # the PUT upload call
}
export -f curl
export DELETE_LOG LIST_BODY_FILE

set +e
FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${RETENTION_WORKDIR}" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/retention-run.stderr"
retention_run_rc=$?
set -e
unset -f curl

expect_eq 'retention run (mocked S3) exits 0' "${retention_run_rc}" '0'
expect_eq 'retention deletes exactly 2 objects (16 matching-shape kept-14)' \
  "$(wc -l <"${DELETE_LOG}" | tr -d ' ')" '2'
expect_eq 'retention deletes the two OLDEST matching-shape objects' \
  "$(sort "${DELETE_LOG}")" \
  "$(printf '%s\n%s' \
    'https://s3.invalid.example/test-bucket/tenants/test/2024-01-01.tar.gz.enc' \
    'https://s3.invalid.example/test-bucket/tenants/test/2024-01-02.tar.gz.enc' | sort)"
expect_eq 'retention NEVER deletes a right-prefix wrong-shape key (README.txt)' \
  "$([[ $(cat "${DELETE_LOG}") == *'README.txt'* ]] && echo leaked || echo safe)" 'safe'
expect_eq 'retention NEVER deletes a right-shape wrong-prefix key (other-tenant)' \
  "$([[ $(cat "${DELETE_LOG}") == *'other-tenant'* ]] && echo leaked || echo safe)" 'safe'

# --- Final teardown backups use one immutable effect-scoped object identity.
EFFECT_ID='123e4567-e89b-42d3-a456-426614174000'
CURL_ARGS_LOG="${SCRATCH}/curl-args.log"
: >"${CURL_ARGS_LOG}"
curl() {
  printf '%q ' "$@" >>"${CURL_ARGS_LOG}"
  printf '\n' >>"${CURL_ARGS_LOG}"
  local a url=''
  for a in "$@"; do url=${a}; done
  if [[ ${url} == *'list-type=2'* ]]; then
    printf '<ListBucketResult></ListBucketResult>'
  fi
  return 0
}
export -f curl
export CURL_ARGS_LOG
FICUS_TERMINATION_BACKUP_EFFECT_ID="${EFFECT_ID}" \
  FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${SCRATCH}/termination-work" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/termination.stderr"
unset -f curl
expect_eq 'termination backup uploads to its immutable effect-scoped key' \
  "$([[ $(cat "${CURL_ARGS_LOG}") == *"tenants/test/terminations/${EFFECT_ID}.tar.gz.enc"* ]] && echo yes || echo no)" 'yes'
expect_eq 'termination backup sends exactly one matching effect metadata header' \
  "$(grep -o "x-amz-meta-tau-termination-backup-effect-id:${EFFECT_ID}" "${CURL_ARGS_LOG}" | wc -l | tr -d ' ')" '1'

: >"${CURL_ARGS_LOG}"
curl() {
  printf '%q ' "$@" >>"${CURL_ARGS_LOG}"
  printf '\n' >>"${CURL_ARGS_LOG}"
  local a url=''
  for a in "$@"; do url=${a}; done
  [[ ${url} == *'list-type=2'* ]] && printf '<ListBucketResult></ListBucketResult>'
  return 0
}
export -f curl
FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${SCRATCH}/ordinary-work" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/ordinary.stderr"
unset -f curl
expect_eq 'ordinary nightly upload sends no termination metadata' \
  "$([[ $(cat "${CURL_ARGS_LOG}") == *'x-amz-meta-tau-termination-backup-effect-id'* ]] && echo leaked || echo absent)" 'absent'

# The control plane sends the effect id under BOTH names for one release (the
# installed copy may predate the Ficus rename): this template reads the
# FICUS_ one, and a TAU_ one passed alongside it changes nothing.
OTHER_EFFECT_ID='99999999-e89b-42d3-a456-426614174000'
: >"${CURL_ARGS_LOG}"
curl() {
  printf '%q ' "$@" >>"${CURL_ARGS_LOG}"
  printf '\n' >>"${CURL_ARGS_LOG}"
  local a url=''
  for a in "$@"; do url=${a}; done
  [[ ${url} == *'list-type=2'* ]] && printf '<ListBucketResult></ListBucketResult>'
  return 0
}
export -f curl
FICUS_TERMINATION_BACKUP_EFFECT_ID="${EFFECT_ID}" TAU_TERMINATION_BACKUP_EFFECT_ID="${OTHER_EFFECT_ID}" \
  FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${SCRATCH}/dual-effect-work" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/dual-effect.stderr"
unset -f curl
expect_eq 'termination backup honours FICUS_TERMINATION_BACKUP_EFFECT_ID when both names are sent' \
  "$([[ $(cat "${CURL_ARGS_LOG}") == *"tenants/test/terminations/${EFFECT_ID}.tar.gz.enc"* ]] && echo yes || echo no)" 'yes'
expect_eq 'termination backup ignores the TAU_ name passed alongside it' \
  "$([[ $(cat "${CURL_ARGS_LOG}") == *"${OTHER_EFFECT_ID}"* ]] && echo leaked || echo ignored)" 'ignored'
: >"${CURL_ARGS_LOG}"
curl() {
  printf '%q ' "$@" >>"${CURL_ARGS_LOG}"
  printf '\n' >>"${CURL_ARGS_LOG}"
  local a url=''
  for a in "$@"; do url=${a}; done
  [[ ${url} == *'list-type=2'* ]] && printf '<ListBucketResult></ListBucketResult>'
  return 0
}
export -f curl
TAU_TERMINATION_BACKUP_EFFECT_ID="${OTHER_EFFECT_ID}" \
  FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${SCRATCH}/tau-only-effect-work" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/tau-only-effect.stderr" # legacy-env
unset -f curl
expect_eq 'a TAU_ effect id alone is ignored: an ordinary dated upload' \
  "$([[ $(cat "${CURL_ARGS_LOG}") == *'/terminations/'* ]] && echo termination || echo ordinary)" 'ordinary'

malformed_rc=0
FICUS_TERMINATION_BACKUP_EFFECT_ID='../other' \
  FICUS_BACKUP_PG_DUMP_CMD="${FAKE_PG_DUMP}" \
  FICUS_BACKUP_WORKDIR="${SCRATCH}/malformed-effect-work" \
  "${RENDERED}" >/dev/null 2>"${SCRATCH}/malformed-effect.stderr" || malformed_rc=$?
expect_eq 'malformed termination effect ID is rejected' "$([[ ${malformed_rc} -ne 0 ]] && echo yes || echo no)" 'yes'
expect_eq 'malformed termination effect rejection names canonical UUID requirement' \
  "$([[ $(cat "${SCRATCH}/malformed-effect.stderr") == *'canonical UUID'* ]] && echo yes || echo no)" 'yes'

# --- Finding 3a (review): backup.enabled requires a non-empty
# backup.s3_prefix — setup-host.sh's config validation, exercised via
# --dry-run so this needs no host mutation, root, or network (config
# validation runs before any of that, even in dry-run mode).
if command -v yq >/dev/null 2>&1; then
  PREFIX_CFG="${SCRATCH}/empty-prefix.yaml"
  cat >"${PREFIX_CFG}" <<'EOF'
source:
  repo: git@example.com:acme/tau.git
core:
  origin: https://tau.example.com
backup:
  enabled: true
  s3_endpoint: https://s3.example.com
  s3_region: us-east-1
  s3_bucket: acme-backups
  s3_prefix: ''
EOF
  set +e
  prefix_die_out=$("${SCRIPT_DIR}/setup-host.sh" --config "${PREFIX_CFG}" --dry-run 2>&1)
  prefix_die_rc=$?
  set -e
  expect_eq 'setup-host.sh dies on backup.enabled with an empty s3_prefix' \
    "$([[ ${prefix_die_rc} -ne 0 ]] && echo yes || echo no)" 'yes'
  expect_eq 'the die message names backup.s3_prefix' \
    "$([[ ${prefix_die_out} == *'backup.s3_prefix'* ]] && echo yes || echo no)" 'yes'
else
  printf 'SKIP: yq not on PATH — skipping backup.s3_prefix validation test\n' >&2
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
