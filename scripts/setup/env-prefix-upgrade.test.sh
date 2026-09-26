#!/usr/bin/env bash
# env-prefix-upgrade.test.sh — the Ficus env rename (TAU_* -> FICUS_*) as the
# real entrypoints run it: upgrade-host.sh, apply-artifacts.sh and
# setup-host.sh run as subprocesses against a fake host in a scratch
# directory, moved onto a real signed artifact served over file:// URLs.
#
# What is proven here, end to end:
#   * an artifact upgrade onto a Ficus release renames every env-bearing file
#     (.env, managed.env, backup.env, the yaml, the units, tau-backup.sh),
#     keeps one backup set and leaves no journal;
#   * a failed health check rolls back AND restores all of them byte for byte;
#   * the env files always end up matching the ACTIVE release (Controller
#     Ruling 29): SIGTERM / SIGHUP / SIGINT before the flip restore them,
#     after it keep and commit the rename (exit 143 / 129 / 130); a dropped
#     control connection (SIGPIPE) settles the same way;
#   * SIGKILL between the rename and the flip leaves the journal, and the next
#     run with the same inputs reconciles (restores) and then completes; a
#     SIGKILL after the flip is reconciled FORWARD by the next toolkit run;
#   * a git->artifact conversion that rolls back restores the files and
#     re-renders the units with TAU_ROOT for the current layout (N-I3);
#   * a pre-rename target on a renamed host, and conflicting protected
#     values, are refused before anything is written (N-C2, Ruling 24);
#   * apply-artifacts.sh --config refuses (exit 3, FICUS_ENV_PREFIX_MISMATCH=1)
#     when the host's .env and its active release disagree;
#   * setup-host.sh refuses a pre-rename release (N-I8) and carries a
#     pre-rename TAU_ENCRYPTION_KEY forward from a restored archive.
#
# Nothing touches the real host: every path the toolkit writes is pointed at
# the scratch directory through its seams (FICUS_SYSTEMD_UNIT_DIR,
# FICUS_MANAGED_ENV_PATH, BACKUP_ENV_TARGET, BACKUP_SCRIPT_PATH,
# ENV_RENAME_BACKUP_ROOT, FICUS_SYSTEM_BIN_DIR), and systemctl, journalctl,
# swapon, sleep, pg_dump and pg_restore are PATH shims. curl is a shim that
# answers the core's /health probe (healthy only for the releases the test
# names) and passes everything else to the real curl.
#
# The entrypoints need real root (they install root-owned files and check
# EUID), GNU coreutils, OpenSSL 3, bun, jq, python3 and mikefarah yq, so the
# suite self-skips — loudly, without the ENABLED marker — anywhere else. CI
# runs it as root; locally, run it in a throwaway Ubuntu 24.04 container.
#
# Run: sudo bash scripts/setup/env-prefix-upgrade.test.sh
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
expect_match() { # DESCRIPTION ACTUAL REGEX
  if [[ $2 =~ $3 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %q does not match /%s/\n' "$1" "$2" "$3" >&2
  fi
}
summary() {
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  [[ ${FAIL} -eq 0 ]]
}

skip_reason=''
[[ ${EUID} -eq 0 ]] || skip_reason='not running as root'
if [[ -z ${skip_reason} ]]; then
  for cmd in bun jq python3 curl tar openssl sha256sum setsid runuser mkfifo git; do
    command -v "${cmd}" >/dev/null 2>&1 || skip_reason=${skip_reason:-"${cmd} is not on PATH"}
  done
fi
if [[ -z ${skip_reason} ]]; then
  command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q mikefarah || skip_reason='mikefarah yq v4 is not on PATH'
fi
if [[ -z ${skip_reason} ]]; then
  mv --version 2>/dev/null | grep -q 'GNU coreutils' || skip_reason='GNU coreutils are not on PATH'
  openssl pkeyutl -help 2>&1 | grep -q -- '-rawin' || skip_reason=${skip_reason:-'OpenSSL 3 (pkeyutl -rawin) is not on PATH'}
fi
if [[ -n ${skip_reason} ]]; then
  printf 'SKIP: the env-prefix upgrade suite needs real root and the Ubuntu toolchain (%s)\n' "${skip_reason}" >&2
  summary
  exit 0
fi
# Machine-readable positive marker: CI's step greps for it, so a run that
# self-skipped again can never look green.
echo 'FICUS env-prefix upgrade section: ENABLED'

SCRATCH=$(mktemp -d -t env-prefix-upgrade-test.XXXXXX)
BG_PIDS=()
cleanup() {
  local pid
  for pid in "${BG_PIDS[@]}"; do
    kill -KILL -- "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
  done
  rm -rf "${SCRATCH}"
}
trap cleanup EXIT

REAL_CURL=$(command -v curl)
REAL_SLEEP=$(command -v sleep)
BUN_VERSION=$(bun --version | tr -d '[:space:]')
# The artifact tarball's root dir is "<core-prefix>-<sha>"; kept in a variable.
CORE_PREFIX='tau-core'

# --------------------------------------------------------------- PATH shims
SHIM="${SCRATCH}/shim"
CTL="${SCRATCH}/ctl" # control files the shims read
mkdir -p "${SHIM}" "${CTL}"
CALLS="${CTL}/calls"
: >"${CALLS}"
mkfifo "${CTL}/fifo"

# systemctl: record; optionally block (on a FIFO) or fail one verb.
cat >"${SHIM}/systemctl" <<SHIMEOF
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >>"${CALLS}"
verb=\${1:-}
if [[ -f ${CTL}/block-\${verb} ]]; then
  rm -f "${CTL}/block-\${verb}"
  printf '%s' "\$\$" >"${CTL}/blocked.pid"
  read -r _ <"${CTL}/fifo" || true
  exit 1
fi
[[ -f ${CTL}/fail-\${verb} ]] && exit 1
case "\${verb}" in
  show) printf '0\n' ;;
esac
exit 0
SHIMEOF
printf '#!/usr/bin/env bash\nexit 0\n' >"${SHIM}/journalctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"${SHIM}/sleep"
printf '#!/usr/bin/env bash\nexit 0\n' >"${SHIM}/pg_dump"
printf '#!/usr/bin/env bash\nexit 0\n' >"${SHIM}/pg_restore"
# swapon: report an unrelated active swap device, so ensure_swapfile leaves
# the (container) host alone.
printf '#!/usr/bin/env bash\n[[ " $* " == *" --show"* ]] && printf "/dev/test-swap\\n"\nexit 0\n' >"${SHIM}/swapon"
# curl: the core's /health probe is answered here — healthy only when
# <dest>/current resolves to a release matching one of the globs in
# ctl/healthy; anything else is the real curl (file:// artifact downloads,
# the restore archive).
cat >"${SHIM}/curl" <<SHIMEOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ \${a} == */health ]]; then
    cur=\$(basename "\$(readlink -f "\$(cat "${CTL}/dest")/current" 2>/dev/null)" 2>/dev/null)
    while IFS= read -r glob; do
      # shellcheck disable=SC2053 # a glob on purpose
      if [[ -n \${cur} && -n \${glob} && \${cur} == \${glob} ]]; then
        printf '200'
        exit 0
      fi
    done <"${CTL}/healthy"
    exit 7
  fi
done
exec ${REAL_CURL} "\$@"
SHIMEOF
chmod +x "${SHIM}"/*
# A non-interactive shell starts background jobs with SIGINT/SIGQUIT ignored,
# and bash cannot trap a signal that was ignored when it started. The
# background runs go through this, which puts both back to the default (what
# a terminal session gives the toolkit) before exec'ing the command — and
# SIGPIPE too, which python itself ignores and exec would otherwise pass on
# (masking exactly the dropped-connection case below).
cat >"${SCRATCH}/sigdefault" <<'SIGEOF'
#!/usr/bin/env python3
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
SIGEOF
chmod +x "${SCRATCH}/sigdefault"

# ------------------------------------------------------------ artifact fixture
openssl genpkey -algorithm ed25519 -out "${SCRATCH}/key.pem" 2>/dev/null
openssl pkey -in "${SCRATCH}/key.pem" -pubout -out "${SCRATCH}/pub.pem" 2>/dev/null
PUBKEY_B64=$(base64 -w0 <"${SCRATCH}/pub.pem")

# The manifest, exactly as scripts/artifact/lib/manifest.ts builds it; the
# optional ENV_PREFIX is the field the Ficus rename added (N-C2).
cat >"${SCRATCH}/manifest.py" <<'PYEOF'
import hashlib, json, os, sys

root, commit, bun_version, env_prefix = sys.argv[1:5]
files = {}
for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel == "artifact.json":
            continue
        with open(path, "rb") as handle:
            files[rel] = "sha256:" + hashlib.sha256(handle.read()).hexdigest()
files = dict(sorted(files.items()))
digest = "sha256:" + hashlib.sha256(json.dumps(files, separators=(",", ":")).encode()).hexdigest()
manifest = {"schema": 1, "commit": commit, "commitDate": "2026-09-26T00:00:00Z", "bun": bun_version,
            "platform": "linux-x64", "builder": "test:fixture"}
if env_prefix:
    manifest["envPrefix"] = env_prefix
manifest["files"] = files
manifest["digest"] = digest
sys.stdout.write(json.dumps(manifest, indent=2) + "\n")
PYEOF

# A release tree: the root marker package.json, and a migrate.js that records
# the env it was run with.
make_tree() { # DIR ROOT_NAME
  mkdir -p "$1/apps/core/dist"
  printf '{"name":"%s","private":true,"workspaces":[]}\n' "$2" >"$1/package.json"
  cat >"$1/apps/core/dist/migrate.js" <<'JSEOF'
const fs = require('node:fs')
if (process.env.MIGRATE_PROOF) {
  fs.appendFileSync(process.env.MIGRATE_PROOF,
    `FICUS_ROOT=${process.env.FICUS_ROOT} TAU_ROOT=${process.env.TAU_ROOT} FICUS_MIGRATE_LIVE=${process.env.FICUS_MIGRATE_LIVE} TAU_MIGRATE_LIVE=${process.env.TAU_MIGRATE_LIVE}\n`)
}
JSEOF
}

# Publish a signed artifact: prints the four FICUS_ARTIFACT_* assignments.
publish() { # NAME SHA ROOT_NAME ENV_PREFIX
  local work="${SCRATCH}/pub-$1" tree
  tree="${work}/staging/${CORE_PREFIX}-$2"
  mkdir -p "${work}/dist"
  make_tree "${tree}" "$3"
  python3 "${SCRATCH}/manifest.py" "${tree}" "$2" "${BUN_VERSION}" "$4" >"${work}/dist/artifact.json"
  cp "${work}/dist/artifact.json" "${tree}/artifact.json"
  openssl pkeyutl -sign -inkey "${SCRATCH}/key.pem" -rawin -in "${work}/dist/artifact.json" -out "${work}/dist/artifact.sig.raw"
  base64 -w0 <"${work}/dist/artifact.sig.raw" >"${work}/dist/artifact.sig"
  tar -C "${work}/staging" -czf "${work}/dist/release.tar.gz" "${CORE_PREFIX}-$2"
  printf 'FICUS_ARTIFACT_TARBALL_URL=file://%s\n' "${work}/dist/release.tar.gz"
  printf 'FICUS_ARTIFACT_MANIFEST_URL=file://%s\n' "${work}/dist/artifact.json"
  printf 'FICUS_ARTIFACT_SIG_URL=file://%s\n' "${work}/dist/artifact.sig"
  printf 'FICUS_ARTIFACT_PUBKEY_B64=%s\n' "${PUBKEY_B64}"
}
SHA_NEW='5555555555555555555555555555555555555555'
SHA_OLD_ART='6666666666666666666666666666666666666666'
publish ficus "${SHA_NEW}" ficus FICUS >"${SCRATCH}/ficus.artifact.env"
publish tau "${SHA_OLD_ART}" tau '' >"${SCRATCH}/tau.artifact.env"

# ---------------------------------------------------------------- fake host
# A host on a pre-rename (TAU) artifact release, with every env-bearing file.
unit() { printf '%s/tau-%s.service' "${H}/units" "$1"; } # unit api|worker (phase5-unit-name)
new_host() { # NAME
  H="${SCRATCH}/host-$1"
  DEST="${H}/dest"
  OLD_REL="${DEST}/releases/1111111111111111111111111111111111111111-000000000000"
  mkdir -p "${OLD_REL}" "${H}/etc" "${H}/units" "${H}/bin" "${H}/sysbin" "${H}/stage/files" "${H}/setup"
  make_tree "${OLD_REL}" tau
  printf '{"schema":1,"commit":"1111111111111111111111111111111111111111"}\n' >"${OLD_REL}/artifact.json"
  printf '{"sha":"x"}\n' >"${OLD_REL}/.tau-release-complete"
  ln -sfn "${OLD_REL}" "${DEST}/current"
  printf '%s' "${DEST}" >"${CTL}/dest"
  basename "${OLD_REL}" >"${CTL}/healthy"
  write_tau_files
  cat >"${H}/setup/tau-setup.yaml" <<YAMLEOF
source:
  mode: artifact
  dest: ${DEST}
core:
  origin: https://acme.ficus.sh
  port: 3999
  run_user: root
  env:
    # a platform knob
    TAU_PLATFORM_INGEST_URL: https://ingest.ficus.sh
    TAU_PLATFORM_USAGE_TOKEN_ENV: PLATFORM_USAGE_TOKEN
database:
  mode: external
  dsn: postgres://user:pw@localhost/db
runtime:
  sandbox: host
backup:
  enabled: false
YAMLEOF
  CONFIG="${H}/setup/tau-setup.yaml"
  : >"${CALLS}"
  rm -f "${CTL}"/block-* "${CTL}"/fail-* "${CTL}/blocked.pid"
  snapshot "${H}/pristine"
}
# legacy-env: the pre-rename host's files are TAU_ on purpose.
write_tau_files() {
  printf 'DATABASE_URL=postgres://user:pw@localhost/db\nMIGRATE_PROOF=%s\nTAU_ENCRYPTION_KEY=enc-key-1\nTAU_PASSWORD=pw-1\nTAU_SANDBOX_RUNTIME=host\nAPP_URL=https://acme.ficus.sh\n' "${H}/migrate-proof" >"${DEST}/.env" # legacy-env
  printf 'TAU_MANAGED=1\nTAU_MANAGED_SECRET_KEYS=TAU_PLATFORM_INSTANCE_TOKEN\nTAU_PLATFORM_INSTANCE_TOKEN=tok\n' >"${H}/etc/managed.env" # legacy-env
  printf "TAU_BACKUP_S3_ACCESS_KEY='ak'\nTAU_BACKUP_S3_SECRET_KEY='sk'\nTAU_BACKUP_PASSPHRASE='pp'\n" >"${H}/etc/backup.env" # legacy-env
  bash -c 'source "$1/lib.sh"; render_backup_script_content "$1/tau-backup.sh.tmpl" "$2" /root/.ficus-test external "" https://s3.example.com us-east-1 bucket pfx "$3"' \
    _ "${SCRIPT_DIR}" "${DEST}" "${H}/etc/backup.env" | sed 's/FICUS_/TAU_/g' >"${H}/bin/tau-backup.sh" # legacy-env
  printf '[Service]\nWorkingDirectory=%s/current/apps/core\nEnvironment=TAU_ROOT=%s/current\n' "${DEST}" "${DEST}" >"$(unit api)" # legacy-env
  printf '[Service]\nWorkingDirectory=%s/current/apps/core\nEnvironment=TAU_ROOT=%s/current\n' "${DEST}" "${DEST}" >"$(unit worker)" # legacy-env
  chmod 0600 "${DEST}/.env" "${H}/etc/managed.env" "${H}/etc/backup.env"
  chmod 0755 "${H}/bin/tau-backup.sh"
}
# Copies of every env-bearing file (the yaml included) into DIR.
ENV_FILES=(dest/.env etc/managed.env etc/backup.env setup/tau-setup.yaml bin/tau-backup.sh)
snapshot() { # DIR
  local f
  mkdir -p "$1"
  for f in "${ENV_FILES[@]}"; do
    mkdir -p "$1/$(dirname "${f}")"
    cp -p "${H}/${f}" "$1/${f}"
  done
  mkdir -p "$1/units"
  cp -p "$(unit api)" "$(unit worker)" "$1/units/"
}
# "same" when every snapshotted file is byte-identical to the live one.
same_as() { # DIR
  local f diff=''
  for f in "${ENV_FILES[@]}"; do
    cmp -s "$1/${f}" "${H}/${f}" || diff+=" ${f}"
  done
  for f in api worker; do
    cmp -s "$1/units/tau-${f}.service" "$(unit "${f}")" || diff+=" ${f}-unit"
  done
  printf '%s' "${diff:-same}"
}
# "same" when every MANIFEST entry of SETDIR matches its live file.
same_as_manifest() { # SETDIR
  local idx _sha path diff=''
  while IFS=$'\t' read -r idx _sha path; do
    cmp -s "$1/${idx}" "${path}" || diff+=" ${path}"
  done <"$1/MANIFEST"
  printf '%s' "${diff:-same}"
}
sum_counts() { awk -F: '{ s += $NF } END { print s + 0 }'; }
tau_names() { # how many TAU_ names are left across the env-bearing files
  local legacy=TAU
  {
    grep -cE "^(export )?${legacy}_" "${DEST}/.env" "${H}/etc/managed.env" "${H}/etc/backup.env" || true
    yq -r '(.core.env // {}) | keys | .[]' "${CONFIG}" | grep -c "^${legacy}_" || true
    grep -cE "^Environment=\"?${legacy}_" "$(unit api)" "$(unit worker)" || true
    grep -c "${legacy}_BACKUP_" "${H}/bin/tau-backup.sh" || true
  } | sum_counts
}
sets() { find "${H}/bk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
pending() { [[ -e ${H}/bk/PENDING ]] && echo pending || echo none; }
# Ruling 29's invariant: without a journal, the .env prefix is the prefix
# the active release reads (TAU_ files under a FICUS_ release, or the
# reverse, with nothing pending to reconcile them, is a stranded host).
assert_converged() { # LABEL
  local env_p rel_p
  [[ $(pending) == none ]] || {
    PASS=$((PASS + 1))
    return 0
  }
  env_p=$(bash -c 'source "$1/lib.sh"; host_env_prefix "$2"' _ "${SCRIPT_DIR}" "${DEST}/.env")
  rel_p=$(bash -c 'source "$1/lib.sh"; SRC_DEST=$2; core_release_env_prefix "$(active_release_tree)"' _ "${SCRIPT_DIR}" "${DEST}" 2>/dev/null)
  expect_eq "$1: the .env prefix matches the active release's (no journal)" "${env_p}" "${rel_p}"
}

# Run an entrypoint as the fake host sees it. ARTIFACT_ENV names the file of
# FICUS_ARTIFACT_* assignments (or '' for none). Sets RC and OUT.
host_env() {
  printf '%s\n' \
    "PATH=${SHIM}:${PATH}" \
    "FICUS_SYSTEMD_UNIT_DIR=${H}/units" \
    "FICUS_MANAGED_ENV_PATH=${H}/etc/managed.env" \
    "BACKUP_ENV_TARGET=${H}/etc/backup.env" \
    "BACKUP_SCRIPT_PATH=${H}/bin/tau-backup.sh" \
    "ENV_RENAME_BACKUP_ROOT=${H}/bk" \
    "FICUS_SYSTEM_BIN_DIR=${H}/sysbin" \
    "PLATFORM_USAGE_TOKEN=usage-token"
}
run_script() { # ARTIFACT_ENV SCRIPT ARGS...
  local artifact_env=$1 script=$2
  shift 2
  local -a envs=()
  mapfile -t envs < <(host_env)
  [[ -z ${artifact_env} ]] || mapfile -t -O "${#envs[@]}" envs <"${artifact_env}"
  RC=0
  OUT=$(env "${envs[@]}" bash "${SCRIPT_DIR}/${script}" "$@" 2>&1) || RC=$?
  verbose_out "${script} $*"
}
# E2E_VERBOSE=1 prints every entrypoint's output (stderr), for debugging.
verbose_out() { # LABEL
  [[ -z ${E2E_VERBOSE:-} ]] || printf '\n===== %s (rc %s)\n%s\n' "$1" "${RC}" "${OUT}" >&2
}
# Start an entrypoint in the background in its own process group; prints the
# pid. Output goes to ${H}/bg.out.
start_bg() { # ARTIFACT_ENV SCRIPT ARGS...
  local artifact_env=$1 script=$2
  shift 2
  local -a envs=()
  mapfile -t envs < <(host_env)
  [[ -z ${artifact_env} ]] || mapfile -t -O "${#envs[@]}" envs <"${artifact_env}"
  setsid "${SCRATCH}/sigdefault" env "${envs[@]}" bash "${SCRIPT_DIR}/${script}" "$@" >"${H}/bg.out" 2>&1 &
  BG_PID=$!
  BG_PIDS+=("${BG_PID}")
}
wait_blocked() { # wait (bounded) until a shim reports it is blocked
  local _try
  for _try in $(seq 1 600); do
    [[ -s ${CTL}/blocked.pid ]] && return 0
    "${REAL_SLEEP}" 0.1
  done
  printf 'test: the run never reached the blocking shim; output:\n%s\n' "$(cat "${H}/bg.out")" >&2
  return 1
}
release_block() { # unblock the FIFO reader (bounded)
  timeout 10 bash -c "printf 'go\n' >'${CTL}/fifo'" || true
}
wait_bg() { # sets RC; bounded
  local _try
  for _try in $(seq 1 600); do
    kill -0 "${BG_PID}" 2>/dev/null || break
    "${REAL_SLEEP}" 0.1
  done
  RC=0
  # Braces + 2>/dev/null: no "Killed" job notice from bash for a KILLed group.
  { wait "${BG_PID}" || RC=$?; } 2>/dev/null
  OUT=$(cat "${H}/bg.out")
  verbose_out 'background run'
}

upgrade() { run_script "$1" upgrade-host.sh --config "${CONFIG}"; }

# ========================================================= 1. rename on upgrade
new_host happy
printf '%s-*\n' "${SHA_NEW}" >>"${CTL}/healthy"
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'upgrade onto a Ficus release: exits 0' "${RC}" '0'
[[ ${RC} -eq 0 ]] || printf '%s\n' "${OUT}" >&2
expect_eq 'upgrade onto a Ficus release: no TAU_ name is left in any env-bearing file' "$(tau_names)" '0'
expect_eq 'upgrade onto a Ficus release: the values are kept' \
  "$(grep -c '^FICUS_ENCRYPTION_KEY=enc-key-1$' "${DEST}/.env"):$(grep -c '^FICUS_MANAGED_SECRET_KEYS=FICUS_PLATFORM_INSTANCE_TOKEN$' "${H}/etc/managed.env")" '1:1'
expect_eq 'upgrade onto a Ficus release: the yaml core.env is renamed, comments kept' \
  "$(yq -r '.core.env.FICUS_PLATFORM_INGEST_URL' "${CONFIG}"):$(grep -c '# a platform knob' "${CONFIG}")" 'https://ingest.ficus.sh:1'
expect_eq 'upgrade onto a Ficus release: the units carry FICUS_ROOT' \
  "$(grep -hc "^Environment=FICUS_ROOT=${DEST}/current$" "$(unit api)" "$(unit worker)" | tr '\n' ' ')" '1 1 '
expect_eq 'upgrade onto a Ficus release: tau-backup.sh is re-rendered from the template' \
  "$(grep -c 'FICUS_BACKUP_' "${H}/bin/tau-backup.sh" | tr -d ' '):$(grep -c 'FICUS_BACKUP_' "${SCRIPT_DIR}/tau-backup.sh.tmpl" | tr -d ' ')" \
  "$(grep -c 'FICUS_BACKUP_' "${SCRIPT_DIR}/tau-backup.sh.tmpl" | tr -d ' '):$(grep -c 'FICUS_BACKUP_' "${SCRIPT_DIR}/tau-backup.sh.tmpl" | tr -d ' ')"
expect_eq 'upgrade onto a Ficus release: one backup set, no journal' "$(sets):$(pending)" '1:none'
expect_eq 'upgrade onto a Ficus release: the set is byte-identical to the host before the upgrade' \
  "$(cmp -s "$(find "${H}/bk" -mindepth 1 -maxdepth 1 -type d)/1" "${H}/pristine/dest/.env" && echo same)" 'same'
expect_match 'upgrade onto a Ficus release: the candidate migrate got both ROOT and MIGRATE_LIVE spellings' \
  "$(cat "${H}/migrate-proof")" "FICUS_ROOT=${DEST}/releases/${SHA_NEW}-[0-9a-f]{12} TAU_ROOT=${DEST}/releases/${SHA_NEW}-[0-9a-f]{12} FICUS_MIGRATE_LIVE=1 TAU_MIGRATE_LIVE=1"
expect_match 'upgrade onto a Ficus release: the trailer is FICUS_' "${OUT}" 'FICUS_RELEASE_ROLLED_BACK=0'
expect_match 'upgrade onto a Ficus release: current is the new release' "$(readlink "${DEST}/current")" "${SHA_NEW}-"
# The rename sits between the migrate and the flip: the rename's daemon-reload
# comes before the activation's restart.
expect_match 'upgrade onto a Ficus release: the rename (its daemon-reload) happens before the restart' \
  "$(tr '\n' '|' <"${CALLS}")" 'systemctl daemon-reload\|.*systemctl restart'
# A second upgrade onto the same release renames nothing and makes no new set.
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 're-running the upgrade: exits 0, still one set, no journal' "${RC}:$(sets):$(pending)" '0:1:none'
assert_converged 'upgrade onto a Ficus release'

# ======================================== 2. failed health check: roll back
new_host rollback # only the old release is healthy
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'unhealthy new release: the upgrade fails' "$([[ ${RC} -ne 0 ]] && echo failed)" 'failed'
expect_match 'unhealthy new release: FICUS_RELEASE_ROLLED_BACK=1' "${OUT}" 'FICUS_RELEASE_ROLLED_BACK=1'
expect_eq 'unhealthy new release: all env-bearing files are restored byte for byte' "$(same_as "${H}/pristine")" 'same'
expect_eq 'unhealthy new release: no journal is left' "$(pending)" 'none'
expect_eq 'unhealthy new release: current is back on the old release' "$(readlink "${DEST}/current")" "${OLD_REL}"
expect_match 'unhealthy new release: the restore ran before the rollback restart' \
  "$(tr '\n' '|' <"${CALLS}")" 'systemctl restart[^|]*\|.*systemctl daemon-reload\|.*systemctl restart'
assert_converged 'unhealthy new release'

# ================================= 3. signals: files follow the ACTIVE release
# Controller Ruling 29: after a signal the env files must match the release
# that is serving. Before the flip (old release active) the set is restored;
# after it (new release active) the rename is kept and committed.
for sig in TERM HUP INT; do
  case ${sig} in
    TERM) want_rc=143 ;;
    HUP) want_rc=129 ;;
    INT) want_rc=130 ;;
  esac
  # --- after the flip: blocked in the health wait (the activation's restart).
  new_host "after-flip-${sig}"
  : >"${CTL}/block-restart"
  start_bg "${SCRATCH}/ficus.artifact.env" upgrade-host.sh --config "${CONFIG}"
  wait_blocked || true
  expect_match "SIG${sig} after the flip: stopped with the new release active" "$(readlink "${DEST}/current")" "${SHA_NEW}-"
  kill "-${sig}" "${BG_PID}"
  release_block
  wait_bg
  expect_eq "SIG${sig} after the flip: exits ${want_rc}" "${RC}" "${want_rc}"
  expect_eq "SIG${sig} after the flip: the files stay renamed (FICUS_, what the active release reads)" "$(tau_names)" '0'
  expect_eq "SIG${sig} after the flip: the rename is committed (no journal)" "$(pending)" 'none'
  assert_converged "SIG${sig} after the flip"

  # --- before the flip: blocked on the rename's own daemon-reload.
  new_host "before-flip-${sig}"
  : >"${CTL}/block-daemon-reload"
  start_bg "${SCRATCH}/ficus.artifact.env" upgrade-host.sh --config "${CONFIG}"
  wait_blocked || true
  set_dir=$(find "${H}/bk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
  expect_eq "SIG${sig} before the flip: the run was stopped after the rename (journaled)" "$(pending)" 'pending'
  kill "-${sig}" "${BG_PID}"
  release_block
  wait_bg
  expect_eq "SIG${sig} before the flip: exits ${want_rc}" "${RC}" "${want_rc}"
  expect_eq "SIG${sig} before the flip: every file is byte-identical to the MANIFEST" "$(same_as_manifest "${set_dir}")" 'same'
  expect_eq "SIG${sig} before the flip: ...which is the host as it was" "$(same_as "${H}/pristine")" 'same'
  expect_eq "SIG${sig} before the flip: no journal, current unmoved" "$(pending):$(readlink "${DEST}/current")" "none:${OLD_REL}"
  assert_converged "SIG${sig} before the flip"
done

# ================== 3b. SIGKILL after the flip: the reconcile finishes FORWARD
new_host kill-after-flip
: >"${CTL}/block-restart"
start_bg "${SCRATCH}/ficus.artifact.env" upgrade-host.sh --config "${CONFIG}"
wait_blocked || true
kill -KILL -- "-${BG_PID}" 2>/dev/null || kill -KILL "${BG_PID}"
wait_bg
expect_eq 'SIGKILL after the flip: the journal is left, the new release active, the files renamed' \
  "$(pending):$(tau_names)" 'pending:0'
expect_match 'SIGKILL after the flip: current is the new release' "$(readlink "${DEST}/current")" "${SHA_NEW}-"
# The next toolkit run — here the control plane's artifact sync — reconciles.
run_script '' apply-artifacts.sh --config "${CONFIG}" "${H}/stage"
expect_eq 'SIGKILL after the flip, then apply-artifacts --config: applies (exit 0)' "${RC}" '0'
expect_match 'SIGKILL after the flip: the reconcile finished the rename forward' "${OUT}" 'reconcile: finished the rename'
expect_eq 'SIGKILL after the flip: files FICUS_, journal committed' "$(tau_names):$(pending)" '0:none'
assert_converged 'SIGKILL after the flip, reconciled'

# ============== 3c. the control connection drops (SIGPIPE on the next write)
# The upgrade's stdout/stderr go to a reader that is killed mid-run — what a
# dropped SSH session does. The next log write must not kill the script
# before its traps can settle the rename.
run_with_reader_killed() { # NAME BLOCK_VERB
  local -a envs=()
  new_host "$1"
  : >"${CTL}/block-$2"
  mapfile -t envs < <(host_env)
  mapfile -t -O "${#envs[@]}" envs <"${SCRATCH}/ficus.artifact.env"
  mkfifo "${H}/out.fifo"
  (
    rc=0
    setsid "${SCRATCH}/sigdefault" env "${envs[@]}" bash "${SCRIPT_DIR}/upgrade-host.sh" --config "${CONFIG}" >"${H}/out.fifo" 2>&1 || rc=$?
    printf '%s' "${rc}" >"${H}/rc"
  ) &
  BG_PID=$!
  BG_PIDS+=("${BG_PID}")
  cat "${H}/out.fifo" >"${H}/seen.log" &
  local reader=$!
  wait_blocked || true
  kill -KILL "${reader}" 2>/dev/null || true
  { wait "${reader}" || true; } 2>/dev/null
  release_block
  local _try
  for _try in $(seq 1 600); do
    [[ -s ${H}/rc ]] && break
    "${REAL_SLEEP}" 0.1
  done
  RC=$(cat "${H}/rc" 2>/dev/null || echo none)
}
run_with_reader_killed pipe-before-flip daemon-reload
expect_eq 'reader gone before the flip: the script did not die of SIGPIPE' "$([[ ${RC} != 141 && ${RC} != none ]] && echo ok || echo "rc ${RC}")" 'ok'
expect_eq 'reader gone before the flip: the set is restored byte for byte' "$(same_as "${H}/pristine")" 'same'
expect_eq 'reader gone before the flip: no journal, current unmoved' "$(pending):$(readlink "${DEST}/current")" "none:${OLD_REL}"
assert_converged 'reader gone before the flip'
run_with_reader_killed pipe-after-flip restart
expect_eq 'reader gone after the flip: the script did not die of SIGPIPE' "$([[ ${RC} != 141 && ${RC} != none ]] && echo ok || echo "rc ${RC}")" 'ok'
expect_eq 'reader gone after the flip: no journal is left' "$(pending)" 'none'
assert_converged 'reader gone after the flip'

# ======================= 4. SIGKILL between the rename and the flip, then re-run
# (Before the flip the active release is the old one, so the reconcile
# restores; see 3b for a SIGKILL after it, which finishes forward.)
new_host crash
# The rename's own daemon-reload (after renaming, before the flip) blocks.
: >"${CTL}/block-daemon-reload"
start_bg "${SCRATCH}/ficus.artifact.env" upgrade-host.sh --config "${CONFIG}"
wait_blocked || true
kill -KILL -- "-${BG_PID}" 2>/dev/null || kill -KILL "${BG_PID}"
wait_bg
expect_eq 'SIGKILL mid-rename: the journal is left behind' "$(pending)" 'pending'
expect_eq 'SIGKILL mid-rename: current never moved' "$(readlink "${DEST}/current")" "${OLD_REL}"
expect_eq 'SIGKILL mid-rename: the host really was renamed (nothing restored it)' "$([[ $(tau_names) -gt 0 ]] && echo partly || echo renamed)" 'renamed'
crash_set=$(find "${H}/bk" -mindepth 1 -maxdepth 1 -type d | head -n 1)
# Both the old and the new release are healthy for the re-run.
printf '%s-*\n' "${SHA_NEW}" >>"${CTL}/healthy"
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'the re-run after a SIGKILL: exits 0' "${RC}" '0'
[[ ${RC} -eq 0 ]] || printf '%s\n' "${OUT}" >&2
expect_match 'the re-run after a SIGKILL: its reconcile restored the set (the active release read TAU_)' "${OUT}" 'reconcile: restored'
expect_eq 'the re-run after a SIGKILL: then renamed and completed' "$(tau_names):$(pending)" '0:none'
expect_eq 'the re-run after a SIGKILL: two sets (the restored one and the committed one)' "$(sets)" '2'
expect_eq 'the re-run after a SIGKILL: the first set still matches the host as it was' \
  "$(cmp -s "${crash_set}/1" "${H}/pristine/dest/.env" && echo same)" 'same'
assert_converged 'the re-run after a SIGKILL'

# ========================= 5. conversion (git -> artifact) that rolls back
new_host convert
rm -f "${DEST}/current"
rm -rf "${DEST}/releases"
make_tree "${DEST}" tau
(
  cd "${DEST}"
  git init -q
  git -c user.email=t@example.com -c user.name=t add package.json apps
  git -c user.email=t@example.com -c user.name=t commit -q -m checkout
)
CONV_SHA=$(git -C "${DEST}" rev-parse HEAD)
printf 'git-%s\n' "${CONV_SHA}" >"${CTL}/healthy" # only the converted checkout is healthy
snapshot "${H}/pristine"
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'converted host, unhealthy new release: the upgrade fails' "$([[ ${RC} -ne 0 ]] && echo failed)" 'failed'
expect_match 'converted host: rolled back' "${OUT}" 'FICUS_RELEASE_ROLLED_BACK=1'
expect_eq 'converted host: current is the converted checkout' "$(readlink "${DEST}/current")" "${DEST}/releases/git-${CONV_SHA}"
set_dir=$(find "${H}/bk" -mindepth 1 -maxdepth 1 -type d | head -n 1)
expect_eq 'converted host: the set excluded the units' "$([[ -e ${set_dir}/UNITS_EXCLUDED ]] && echo excluded)" 'excluded'
for f in dest/.env etc/managed.env etc/backup.env setup/tau-setup.yaml bin/tau-backup.sh; do
  expect_eq "converted host: ${f} is restored byte for byte" "$(cmp -s "${H}/pristine/${f}" "${H}/${f}" && echo same)" 'same'
done
expect_eq 'converted host: the units are re-rendered for the current layout with TAU_ROOT' \
  "$(grep -hc "^Environment=TAU_ROOT=${DEST}/current$" "$(unit api)" "$(unit worker)" | tr '\n' ' ')" '1 1 ' # legacy-env
expect_eq 'converted host: no FICUS_ROOT is left in the units' "$(grep -hc '^Environment=FICUS_ROOT' "$(unit api)" "$(unit worker)" | tr '\n' ' ')" '0 0 '
expect_eq 'converted host: no journal is left' "$(pending)" 'none'
assert_converged 'converted host'

# ============================ 6. a pre-rename target on a renamed host is refused
new_host downgrade
printf '%s-*\n' "${SHA_NEW}" >>"${CTL}/healthy"
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'downgrade fixture: the first upgrade renamed the host' "${RC}:$(tau_names)" '0:0'
snapshot "${H}/renamed"
upgrade "${SCRATCH}/tau.artifact.env"
expect_eq 'pre-rename target on a FICUS host: refused' "${RC}" '1'
expect_match 'pre-rename target on a FICUS host: says why and how back' "${OUT}" 'target Core predates the Ficus rename but this host.s settings are FICUS_\*; re-run with --restore-env-backup'
expect_eq 'pre-rename target on a FICUS host: nothing on the host changed' "$(same_as "${H}/renamed")" 'same'
expect_match 'pre-rename target on a FICUS host: current did not move' "$(readlink "${DEST}/current")" "${SHA_NEW}-"
# --restore-env-backup is the documented way back, and it clears nothing else.
run_script '' upgrade-host.sh --config "${CONFIG}" --restore-env-backup "$(find "${H}/bk" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
expect_eq '--restore-env-backup: exits 0' "${RC}" '0'
expect_eq '--restore-env-backup: the files are back to the pre-rename bytes' \
  "$(for f in dest/.env etc/managed.env etc/backup.env setup/tau-setup.yaml bin/tau-backup.sh; do cmp -s "${H}/pristine/${f}" "${H}/${f}" || printf ' %s' "${f}"; done)" ''

# ================== 7. conflicting protected values: stop before any write
new_host conflict
printf 'FICUS_ENCRYPTION_KEY=value-bbb-other\n' >>"${DEST}/.env"
snapshot "${H}/pristine"
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'conflicting encryption keys: the upgrade stops' "${RC}" '1'
expect_match 'conflicting encryption keys: names the key' "${OUT}" 'TAU_ENCRYPTION_KEY and FICUS_ENCRYPTION_KEY disagree on this host'
expect_eq 'conflicting encryption keys: never prints either value' \
  "$(grep -c -e 'enc-key-1' -e 'value-bbb-other' <<<"${OUT}" || true)" '0'
expect_eq 'conflicting encryption keys: nothing was written' "$(same_as "${H}/pristine")" 'same'
expect_eq 'conflicting encryption keys: no set, no journal' "$(sets):$(pending)" '0:none'
expect_eq 'conflicting encryption keys: current did not move' "$(readlink "${DEST}/current")" "${OLD_REL}"
# (No convergence check here: the host carried both spellings before the run,
# which is exactly what the operator is asked to fix; the run changed nothing.)

# =========== 7b. a tau-backup.sh the rename could not re-render: refused early
new_host bad-backup-script
sed -i '/^DEST=/d' "${H}/bin/tau-backup.sh"
snapshot "${H}/pristine"
upgrade "${SCRATCH}/ficus.artifact.env"
expect_eq 'unparseable tau-backup.sh: the upgrade stops' "${RC}" '1'
expect_match 'unparseable tau-backup.sh: says why' "${OUT}" 'has no DEST=.* line'
expect_eq 'unparseable tau-backup.sh: in preflight — no migration ran, nothing renamed, no set' \
  "$([[ -e ${H}/migrate-proof ]] && echo migrated || echo none):$(same_as "${H}/pristine"):$(sets)" 'none:same:0'

# ======================== 8. apply-artifacts.sh --config: refuse a mismatch
new_host apply
printf 'FICUS_PLATFORM_BASE_URL=https://ficus.sh\n' >"${H}/stage/managed.env"
# A renamed .env under the (pre-rename) active release: the N-C1 crash state.
bash -c 'source "$1/lib.sh"; envfile_rename_prefix "$2" TAU FICUS' _ "${SCRIPT_DIR}" "${DEST}/.env" >/dev/null 2>&1
cp -p "${H}/etc/managed.env" "${H}/managed.before"
run_script '' apply-artifacts.sh --config "${CONFIG}" "${H}/stage"
expect_eq 'apply-artifacts --config, FICUS .env on a TAU release: exit 3' "${RC}" '3'
expect_match 'apply-artifacts --config, FICUS .env on a TAU release: the marker' "${OUT}" '(^|'$'\n'')FICUS_ENV_PREFIX_MISMATCH=1'
expect_eq 'apply-artifacts --config, FICUS .env on a TAU release: managed.env is untouched' \
  "$(cmp -s "${H}/etc/managed.env" "${H}/managed.before" && echo same)" 'same'
expect_eq 'apply-artifacts --config, FICUS .env on a TAU release: no restart/reload markers' \
  "$(grep -c '_CHANGED=' <<<"${OUT}" || true)" '0'
# A consistent host applies normally.
write_tau_files
run_script '' apply-artifacts.sh --config "${CONFIG}" "${H}/stage"
expect_eq 'apply-artifacts --config, consistent host: applies (exit 0)' "${RC}" '0'
expect_match 'apply-artifacts --config, consistent host: FICUS_MANAGED_ENV_CHANGED=1' "${OUT}" 'FICUS_MANAGED_ENV_CHANGED=1'
# A journaled rename the active (TAU) release cannot read: reconciled, then applied.
ENV_RENAME_BACKUP_ROOT="${H}/bk" bash -c 'source "$1/lib.sh"; SRC_DEST=$2; env_rename_backup_create FICUS "" "$2/.env" >/dev/null; envfile_rename_prefix "$2/.env" TAU FICUS' \
  _ "${SCRIPT_DIR}" "${DEST}" >/dev/null 2>&1 # hand-made journal: set + renamed .env
expect_eq 'apply-artifacts fixture: a journal is pending' "$(pending)" 'pending'
run_script '' apply-artifacts.sh --config "${CONFIG}" "${H}/stage"
expect_eq 'apply-artifacts --config, journaled rename on a TAU release: reconciled (restored), then applied' \
  "${RC}:$(pending):$(grep -c '^TAU_ENCRYPTION_KEY=' "${DEST}/.env")" '0:none:1' # legacy-env

# ================================ 9. setup-host.sh: Ficus releases only (N-I8)
# setup-host.sh really preflights (Linux + systemd + Ubuntu 24.04, packages,
# bun, the managed runtime) before it reaches its source phase; that needs a
# systemd host (CI's runner) or a container prepared with /run/systemd/system.
# A fresh host (nothing to rename) and a config as the control plane renders
# it after the rename (no TAU_ keys, no *_ENV indirection to resolve).
fresh_setup_host() { # NAME
  new_host "$1"
  rm -rf "${DEST:?}" "${H:?}/units"/* "${H:?}/etc"/* "${H:?}/bin"/*
  cat >"${CONFIG}" <<YAMLEOF
source:
  mode: artifact
  repo: https://example.invalid/core.git
  dest: ${DEST}
core:
  origin: https://acme.ficus.sh
  port: 3999
  run_user: root
database:
  mode: external
  dsn: postgres://user:pw@localhost/db
runtime:
  sandbox: host
YAMLEOF
}
if [[ -d /run/systemd/system ]] && grep -q '^ID=ubuntu' /etc/os-release && grep -q '^VERSION_ID="24.04"' /etc/os-release; then
  fresh_setup_host setup-old
  run_script "${SCRATCH}/tau.artifact.env" setup-host.sh --config "${CONFIG}"
  expect_eq 'setup-host.sh onto a pre-rename release: refused' "${RC}" '1'
  expect_match 'setup-host.sh onto a pre-rename release: says why' "${OUT}" 'this toolkit installs Ficus releases only; use the toolkit from the release you are installing'
  expect_eq 'setup-host.sh onto a pre-rename release: no .env was rendered' "$([[ -e ${DEST}/.env ]] && echo rendered || echo none)" 'none'

  # Restore from an archive whose .env predates the rename: the TAU_ key is
  # carried forward (PERMANENT fallback), never replaced by a generated one.
  fresh_setup_host setup-restore
  mkdir -p "${H}/archive"
  printf 'TAU_ENCRYPTION_KEY=archived-key-42\nDATABASE_URL=postgres://x@localhost/db\n' >"${H}/archive/.env" # legacy-env
  printf 'dump' >"${H}/archive/db.dump"
  tar -C "${H}/archive" -czf "${H}/backup.tar.gz" db.dump .env
  printf 'restore-pass' >"${H}/pass"
  openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:${H}/pass" -in "${H}/backup.tar.gz" -out "${H}/backup.tar.gz.enc"
  # Stop right after phase_env rendered the .env: the unit reload fails.
  : >"${CTL}/fail-daemon-reload"
  printf 'FICUS_SETUP_RESTORE_URL=file://%s\nFICUS_SETUP_RESTORE_PASSPHRASE=restore-pass\n' "${H}/backup.tar.gz.enc" >"${H}/restore.env"
  cat "${SCRATCH}/ficus.artifact.env" >>"${H}/restore.env"
  run_script "${H}/restore.env" setup-host.sh --config "${CONFIG}"
  expect_match 'setup-host.sh restore: carried the archived key forward' "${OUT}" 'carried FICUS_ENCRYPTION_KEY forward from the restored backup'
  expect_eq 'setup-host.sh restore: the rendered .env holds the ARCHIVED (TAU_) key' \
    "$(grep -c '^FICUS_ENCRYPTION_KEY=archived-key-42$' "${DEST}/.env" 2>/dev/null || true)" '1'
  expect_eq 'setup-host.sh restore: and no TAU_ name' "$(grep -c '^TAU_' "${DEST}/.env" 2>/dev/null || true)" '0'
else
  printf 'SKIP: the setup-host.sh cases need a systemd Ubuntu 24.04 host (/run/systemd/system)\n' >&2
  FAIL=$((FAIL + 1))
  printf 'FAIL: the setup-host.sh cases did not run — this suite requires them where it is ENABLED\n' >&2
fi

summary
