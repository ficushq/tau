#!/usr/bin/env bash
#
# upgrade-host.sh — ON-TARGET tau upgrade primitive.
#
# Moves an ALREADY SET UP tau host to a different source ref: fetch + checkout
# → dependencies + core build + web build → database migrations → restart
# tau-api/tau-worker and wait for both to actually serve.
#
# Why this exists as its own entrypoint rather than "just re-run setup-host.sh":
# a re-run of setup-host.sh re-resolves the FULL config, including every secret
# indirection (database DSN, AI provider key, backup passphrase, the bootstrap
# password, the platform usage token). Those values are deliberately not
# retained anywhere off-box after the initial provision — the control plane
# keeps a hash of the usage token, not the token — so a full re-run cannot be
# reproduced from the outside. An upgrade needs none of them: the host's
# <dest>/.env already holds everything the services read.
#
# What it is NOT allowed to become is a hand-rolled command sequence. The three
# steps that matter (build, migrate, restart) are lib.sh's build_app /
# run_db_migrations / restart_core_services — the exact same functions
# setup-host.sh's phases call. That is the whole point: `tau-api` runs
# `bun run dist/index.js`, so a fetch without a core build leaves the OLD
# server running while `git log` reports the new commit, and the only reliable
# defense is that there is one shared definition of the build rather than two
# that can drift.
#
# Reads the SAME config file setup-host.sh was given (for source.* and core.*
# only — it never touches the secrets sections), so the ref/repo/dest/port a
# host was set up with stay authoritative.
#
# Idempotent: re-running against the ref the host already has re-syncs,
# rebuilds, re-migrates and restarts. Requires root or passwordless-ish sudo.
#
# TWO MODES. The one above (git) is the escape hatch. When the four
# FICUS_ARTIFACT_* inputs arrive in the environment (delivered through the
# control plane's existing 0600 secrets.env channel — presigned URLs are
# credentials and never travel in argv), this runs the ARTIFACT flow instead:
# download a prebuilt, signed core release, verify it, migrate from the
# candidate, and activate it by moving one symlink. No repo access, no
# GH_TOKEN, no build toolchain, and no `.git` requirement — the first artifact
# upgrade of a git box CONVERTS it (the old checkout becomes
# releases/git-<sha>, the rollback target). See lib.sh's `core release
# artifacts` section for the box-side machinery.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: upgrade-host.sh --config tau-setup.yaml [--ref REF]

Upgrades the tau instance ON THIS HOST to a source ref: source sync → build
(core AND web) → migrations → service restart + health wait.

Options:
  --config FILE   the config this host was set up with (see
                  tau-setup.example.yaml). Only source.* and core.* are read.
  --ref REF       branch, tag or commit sha to move to. Defaults to the
                  config's source.ref.
  -h, --help      show this help

Private-repo source.mode=git-https needs $GH_TOKEN in the environment (same as
setup-host.sh); nothing is ever passed on the command line.

Artifact mode is selected by the environment, not by a flag: when ALL of
$FICUS_ARTIFACT_TARBALL_URL, $FICUS_ARTIFACT_MANIFEST_URL, $FICUS_ARTIFACT_SIG_URL
and $FICUS_ARTIFACT_PUBKEY_B64 are set, the host is moved to that prebuilt
release instead of being rebuilt from source (--ref is then ignored: the
artifact names its own commit). Any missing input = git mode.
EOF
}

CONFIG='' REF_OVERRIDE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG=${2:?--config needs a value}
      shift 2
      ;;
    --ref)
      REF_OVERRIDE=${2:?--ref needs a value}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n ${CONFIG} ]] || {
  usage >&2
  die "--config is required"
}
[[ -f ${CONFIG} ]] || die "config file '${CONFIG}' not found — this host does not look like it was set up by this toolkit"

ensure_yq
cfg_load "${CONFIG}"

# ============================================================== mode selection
#
# The artifact inputs arrive in the ENVIRONMENT (the control plane's
# /root/.tau-upgrade/secrets.env channel, 0600), never on the command line:
# three of them are presigned GET URLs, i.e. credentials, and argv is
# world-readable through ps. All four required — a partial set is a delivery
# bug, and running a half-configured artifact upgrade would either fail deep
# inside the verify or, worse, silently fall back to building from source when
# the control plane believed it shipped a verified release.
FICUS_ARTIFACT_TARBALL_URL=${FICUS_ARTIFACT_TARBALL_URL:-}
FICUS_ARTIFACT_MANIFEST_URL=${FICUS_ARTIFACT_MANIFEST_URL:-}
FICUS_ARTIFACT_SIG_URL=${FICUS_ARTIFACT_SIG_URL:-}
FICUS_ARTIFACT_PUBKEY_B64=${FICUS_ARTIFACT_PUBKEY_B64:-}
ARTIFACT_MODE=0
if [[ -n ${FICUS_ARTIFACT_TARBALL_URL} && -n ${FICUS_ARTIFACT_MANIFEST_URL} && -n ${FICUS_ARTIFACT_SIG_URL} && -n ${FICUS_ARTIFACT_PUBKEY_B64} ]]; then
  ARTIFACT_MODE=1
elif [[ -n ${FICUS_ARTIFACT_TARBALL_URL}${FICUS_ARTIFACT_MANIFEST_URL}${FICUS_ARTIFACT_SIG_URL}${FICUS_ARTIFACT_PUBKEY_B64} ]]; then
  # SOME but not all: a delivery bug. Falling through to git mode here would
  # rebuild from source while the control plane believes it shipped a verified
  # artifact — a silent divergence between what the fleet runs and what the CP
  # records. Fail loudly instead.
  die "artifact inputs are incomplete — refusing to fall back to a source build (need FICUS_ARTIFACT_TARBALL_URL, FICUS_ARTIFACT_MANIFEST_URL, FICUS_ARTIFACT_SIG_URL and FICUS_ARTIFACT_PUBKEY_B64; missing:$(
    [[ -z ${FICUS_ARTIFACT_TARBALL_URL} ]] && printf ' FICUS_ARTIFACT_TARBALL_URL'
    [[ -z ${FICUS_ARTIFACT_MANIFEST_URL} ]] && printf ' FICUS_ARTIFACT_MANIFEST_URL'
    [[ -z ${FICUS_ARTIFACT_SIG_URL} ]] && printf ' FICUS_ARTIFACT_SIG_URL'
    [[ -z ${FICUS_ARTIFACT_PUBKEY_B64} ]] && printf ' FICUS_ARTIFACT_PUBKEY_B64'
    true
  ))"
fi

# Only the source/core keys. Every secret-bearing section (database, backup,
# ai, secrets) is deliberately NOT read: an upgrade rewrites no .env and needs
# no credential, which is what makes it runnable long after provisioning
# without re-supplying anything.
SRC_MODE=$(cfg_get '.source.mode' 'git-ssh')
SRC_DEST=$(expand_tilde "$(cfg_get '.source.dest' '/opt/tau-core')")
if [[ ${ARTIFACT_MODE} -eq 0 ]]; then
  # shellcheck disable=SC2034 # SRC_REPO/SRC_DEPLOY_KEY are read by lib.sh's
  # git_source_sync as caller globals, exactly as in setup-host.sh.
  SRC_REPO=$(cfg_require '.source.repo' 'git repository')
  SRC_REF=${REF_OVERRIDE:-$(cfg_get '.source.ref' 'main')}
  # shellcheck disable=SC2034
  SRC_DEPLOY_KEY=$(expand_tilde "$(cfg_get '.source.deploy_key_path')")
  case "${SRC_MODE}" in
    git-ssh | git-https) ;;
    artifact) die "source.mode=artifact hosts are not upgradable from source (there is no checkout to move) — an artifact upgrade needs the FICUS_ARTIFACT_* inputs in the environment" ;;
    *) die "config: source.mode must be git-ssh or git-https (got '${SRC_MODE}')" ;;
  esac
fi

CORE_PORT=$(cfg_get '.core.port' '3000')
[[ ${CORE_PORT} =~ ^[0-9]+$ ]] || die "config: core.port must be a number"
CORE_SERVE_WEB=$(cfg_bool '.core.serve_web' 'true')
RUN_USER=$(cfg_get '.core.run_user' "$(id -un)")
# Not a secret and not a credential — the unit templates need it for the
# `After=… docker.service` ordering, and re-rendering a unit without it would
# quietly drop that ordering on a container-database box.
# shellcheck disable=SC2034 # caller global: lib.sh's render_core_unit reads it
DB_MODE=$(cfg_get '.database.mode' 'container')
# The managed system Bun, exactly as setup-host.sh renders it into the units
# (ensure_system_bun_node is what puts it there). Resolving it from PATH
# instead would rewrite ExecStart to whatever bun this ssh session happened to
# find.
# shellcheck disable=SC2034 # caller global: lib.sh's render_core_unit reads it
BUN_BIN=/usr/local/bin/bun

# ============================================================== artifact mode

artifact_upgrade() {
  local acq='' rc=0 sha digest12 tree release_dir before before_sha tmpl

  # The units must point at <dest>/current from this run onward. Forced rather
  # than inferred: on the very first conversion `releases/` may not exist yet
  # at the moment the render is prepared.
  # shellcheck disable=SC2034 # caller global: lib.sh's core_run_root reads it
  CORE_LAYOUT=artifact

  log_step 'artifact upgrade 1/5: preflight (no source checkout required)'
  # Deliberately NOT required here: `.git`, git itself, and any git env setup.
  # An artifact box may have no checkout at all. bun IS required — the
  # artifact ships no runtime — and artifact_acquire hard-fails if the host's
  # bun is not the version the artifact was built against.
  bun_path_prepend
  require_cmd bun "setup-host.sh installs bun at \${HOME}/.bun/bin — was this host set up by the toolkit?"
  require_cmd curl
  require_cmd jq
  require_cmd openssl
  require_root_capability
  id -u "${RUN_USER}" >/dev/null 2>&1 || die "core.run_user '${RUN_USER}' does not exist"
  # The unit templates are NOT part of this script: an artifact upgrade
  # re-renders tau-api/tau-worker, so whoever pushes upgrade-host.sh + lib.sh
  # to the box must push systemd/*.service.tmpl alongside them. Checked HERE,
  # before a single byte on the box moves — discovering it after the
  # conversion would leave the box mid-migration with stale units.
  for tmpl in tau-api tau-worker; do
    [[ -f ${SCRIPT_DIR}/systemd/${tmpl}.service.tmpl ]] ||
      die "missing ${SCRIPT_DIR}/systemd/${tmpl}.service.tmpl — an artifact upgrade re-renders the systemd units, so the caller must push scripts/setup/systemd/*.service.tmpl to the box alongside lib.sh and upgrade-host.sh"
  done
  ensure_swapfile
  ensure_system_bun_node "${RUN_USER}" "$(command -v bun)"
  # The services this run will restart read <dest>/.env (EnvironmentFile in
  # both units), and an upgrade rewrites no .env — so if that file never named
  # a FICUS_SANDBOX_RUNTIME, the flip at step 5 brings both units back DEAD.
  # Refuse here, while nothing on the box has moved.
  require_env_file_sandbox_runtime "${SRC_DEST}/.env"

  # The artifact public key is NOT a secret, but openssl needs it as a file.
  # 0600 + an EXIT trap so no exit path — including a die deep inside the
  # verify — leaves it behind.
  ARTIFACT_PUBKEY_FILE=$(mktemp)
  chmod 600 "${ARTIFACT_PUBKEY_FILE}"
  trap 'rm -f "${ARTIFACT_PUBKEY_FILE}"' EXIT
  printf '%s' "${FICUS_ARTIFACT_PUBKEY_B64}" | base64 -d >"${ARTIFACT_PUBKEY_FILE}" 2>/dev/null ||
    die "FICUS_ARTIFACT_PUBKEY_B64 is not valid base64"
  [[ -s ${ARTIFACT_PUBKEY_FILE} ]] || die "FICUS_ARTIFACT_PUBKEY_B64 decoded to an empty public key"

  # Read what this box is serving BEFORE anything on disk moves — after the
  # conversion below there is no checkout left to ask.
  before=$(artifact_current_release_id "${SRC_DEST}")
  log_info "current release: ${before}"

  # First artifact upgrade of a git box: the checkout becomes a release, and
  # the units move onto <dest>/current in the SAME step. Both halves happen
  # before anything is downloaded, so the box is consistent at every instant:
  # `current` exists the moment the units name it, an acquire failure leaves a
  # box that survives a reboot, and the first artifact activation has a real
  # `current` to auto-roll back to.
  #
  # The trigger is `.git` at <dest> — which is also the resume signal, because
  # artifact_convert_git_checkout moves `.git` last (an interrupted conversion
  # still looks like a checkout, and re-running finishes it).
  if [[ -d ${SRC_DEST}/.git ]]; then
    log_step 'artifact upgrade 2/5: converting the git checkout to the artifact layout (one-way)'
    artifact_convert_git_checkout "${SRC_DEST}"
    install_core_units "${SCRIPT_DIR}/systemd"
    ensure_tau_api_memory_guardrail
    as_root systemctl daemon-reload
    log_info "units now run from ${SRC_DEST}/current (conversion complete; a manual rollback is: point current at releases/git-<sha> and restart)"
  else
    log_step 'artifact upgrade 2/5: already on the artifact layout — no conversion needed'
  fi

  log_step 'artifact upgrade 3/5: download + verify the release artifact'
  # artifact_acquire EXITS (it does not return) on failure, printing its
  # reason token on stdout — so it has to be captured, and its status has to
  # be taken from the substitution. `local x=$(...)` would throw the status
  # away and read a failed, unverified acquire as success.
  acq='' rc=0
  acq=$(artifact_acquire "${SRC_DEST}" "${FICUS_ARTIFACT_TARBALL_URL}" "${FICUS_ARTIFACT_MANIFEST_URL}" "${FICUS_ARTIFACT_SIG_URL}" "${ARTIFACT_PUBKEY_FILE}") || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    # The FICUS_ARTIFACT_ERROR=<token> line went into ${acq}, not onto the log
    # stream — re-emit it or the control plane never learns why this failed.
    printf '%s\n' "${acq}"
    die "artifact acquisition failed"
  fi
  sha=$(printf '%s\n' "${acq}" | sed -n 1p | awk '{print $1}')
  digest12=$(printf '%s\n' "${acq}" | sed -n 1p | awk '{print $2}')
  tree=$(printf '%s\n' "${acq}" | sed -n 2p)
  [[ ${sha} =~ ^[0-9a-f]{40}$ && ${digest12} =~ ^[0-9a-f]{12}$ && -d ${tree} ]] ||
    die "artifact_acquire returned an unusable result (sha='${sha}', digest12='${digest12}')"

  artifact_stage "${SRC_DEST}" "${tree}" "${sha}" "${digest12}"
  release_dir=$(artifact_release_dir "${SRC_DEST}" "${sha}" "${digest12}")

  log_step "artifact upgrade 4/5: systemd units → ${SRC_DEST}/current"
  # Idempotent, and the ONLY unit render for a box that was already on the
  # artifact layout (the conversion branch above did its own, immediately).
  # This is where a changed template reaches an existing artifact box.
  # install_rendered --check-placeholders refuses to land a unit with an
  # unsubstituted marker; artifact_activate daemon-reloads before it restarts,
  # so a changed unit and the flip take effect together.
  install_core_units "${SCRIPT_DIR}/systemd"
  ensure_tau_api_memory_guardrail

  log_step 'artifact upgrade 5/5: migrate → flip → restart (auto-rollback on a failed health check)'
  # No `||` and no `if`: a failed activation must abort this script through
  # set -e. artifact_activate emits FICUS_RELEASE_ROLLED_BACK itself — it is the
  # only code that knows whether the flip survived.
  artifact_activate "${SRC_DEST}" "${release_dir}" "${CORE_PORT}"
  artifact_retention "${SRC_DEST}"

  log_info "activated release ${sha:0:12}-${digest12} (was ${before})"

  # Machine-readable trailer, last lines on stdout (all logging goes to
  # stderr). The FICUS_UPGRADE_* lines are kept in artifact mode too so anything
  # still grepping them keeps working: AFTER_SHA is the artifact's commit, and
  # AFTER_REF is 'artifact' because there is no branch to report.
  before_sha=${before#git-}
  before_sha=${before_sha%-*}
  artifact_emit_release_trailer "${before}" "${sha}-${digest12}"
  printf 'FICUS_UPGRADE_BEFORE_SHA=%s\n' "${before_sha}"
  printf 'FICUS_UPGRADE_AFTER_SHA=%s\n' "${sha}"
  printf 'FICUS_UPGRADE_AFTER_REF=%s\n' 'artifact'
}

if [[ ${ARTIFACT_MODE} -eq 1 ]]; then
  artifact_upgrade
  exit 0
fi

# ================================================================== git mode

[[ -d ${SRC_DEST}/.git ]] ||
  die "source.dest '${SRC_DEST}' is not a git checkout — nothing to upgrade (was this host set up from a git source?)"

require_cmd git
# An upgrade never INSTALLS bun — it only needs to SEE the one setup-host.sh
# already put on the box, which a non-interactive ssh shell cannot do unaided.
bun_path_prepend
require_cmd bun "setup-host.sh installs bun at \${HOME}/.bun/bin — was this host set up by the toolkit?"
require_cmd curl
require_root_capability
id -u "${RUN_USER}" >/dev/null 2>&1 || die "core.run_user '${RUN_USER}' does not exist"
ensure_swapfile
ensure_system_bun_node "${RUN_USER}" "$(command -v bun)"
# Same reasoning as artifact mode's preflight: phase 4 restarts tau-api and
# tau-worker against <dest>/.env, which this script never rewrites. An .env
# with no (or a retired) FICUS_SANDBOX_RUNTIME means both units come back dead
# AFTER the checkout has already moved — so check before phase 1.
require_env_file_sandbox_runtime "${SRC_DEST}/.env"

BEFORE_SHA=$(git -C "${SRC_DEST}" rev-parse HEAD)

log_step "phase 1/4: source → ${SRC_REF}"
git_source_sync

log_step "phase 2/4: dependencies + build (core + cli${CORE_SERVE_WEB:+ + web}) — ~1-2 min, silent while it builds"
build_app "${SRC_DEST}" "${CORE_SERVE_WEB}"

log_step "phase 3/4: database migrations"
run_db_migrations "${SRC_DEST}"

ensure_tau_api_memory_guardrail
if [[ ${FICUS_API_MEMORY_GUARDRAIL_CHANGED} -eq 1 ]]; then
  as_root systemctl daemon-reload
fi

log_step "phase 4/4: restart tau-api + tau-worker"
restart_core_services "${CORE_PORT}"

AFTER_SHA=$(git -C "${SRC_DEST}" rev-parse HEAD)
AFTER_REF=$(git -C "${SRC_DEST}" rev-parse --abbrev-ref HEAD)
# _tau_build_skipped is set by build_app (lib.sh) above — true only when the
# stamp proved the build current for this exact commit + bun.lock, in which
# case the expensive compile step was skipped (migrations + restart still
# ran, which is what keeps the platform's post-upgrade mtime probe honest;
# see build_app's comment in lib.sh).
log_info "$(upgrade_result_message "${BEFORE_SHA}" "${AFTER_SHA}" "${_tau_build_skipped:-false}")"

# Machine-readable trailer, last lines on stdout (all logging goes to stderr).
# The control plane parses these; humans get the log_info lines above.
printf 'FICUS_UPGRADE_BEFORE_SHA=%s\n' "${BEFORE_SHA}"
printf 'FICUS_UPGRADE_AFTER_SHA=%s\n' "${AFTER_SHA}"
printf 'FICUS_UPGRADE_AFTER_REF=%s\n' "${AFTER_REF}"
