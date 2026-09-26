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
#
# THE ENV RENAME (Ficus). The one time an upgrade rewrites the host's env
# files is the upgrade onto the first release that reads FICUS_* (its
# artifact.json says "envPrefix": "FICUS"; a git checkout's package.json is
# named ficus): every TAU_* setting in <dest>/.env, managed.env, backup.env,
# the config yaml's core.env, the core units and tau-backup.sh is renamed to
# FICUS_*, after a byte-for-byte backup set, journaled, and restored if the
# run fails, rolls back or is killed. See lib.sh's `env prefix rename`
# section, and --restore-env-backup below for the manual way back.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: upgrade-host.sh --config tau-setup.yaml [--ref REF]
       upgrade-host.sh [--config tau-setup.yaml] --restore-env-backup SET

Upgrades the tau instance ON THIS HOST to a source ref: source sync → build
(core AND web) → migrations → service restart + health wait.

Options:
  --config FILE   the config this host was set up with (see
                  tau-setup.example.yaml). Only source.* and core.* are read.
  --ref REF       branch, tag or commit sha to move to. Defaults to the
                  config's source.ref.
  --restore-env-backup SET
                  put a Ficus env-rename backup set (a directory under
                  /var/backups/ficus-env-rename) back byte for byte and exit —
                  the way back before running an OLDER toolkit or Core on a
                  renamed host. It also reverts any secret changed since that
                  set was taken. A set taken during a git->artifact
                  conversion re-renders the units, which needs --config.
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

CONFIG='' REF_OVERRIDE='' RESTORE_ENV_SET=''
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
    --restore-env-backup)
      RESTORE_ENV_SET=${2:?--restore-env-backup needs a backup set directory}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# ====================================================== --restore-env-backup
#
# The manual way back from the Ficus env rename: put a backup set back (every
# file verified against its MANIFEST sha256), clear the journal when it names
# this set, and exit. Nothing else in this script runs.
if [[ -n ${RESTORE_ENV_SET} ]]; then
  [[ -d ${RESTORE_ENV_SET} ]] || die "--restore-env-backup: '${RESTORE_ENV_SET}' is not a directory"
  RESTORE_ENV_SET=$(readlink -f -- "${RESTORE_ENV_SET}") || die "--restore-env-backup: could not resolve the set path"
  if [[ -n ${CONFIG} ]]; then
    [[ -f ${CONFIG} ]] || die "config file '${CONFIG}' not found"
    ensure_yq
    cfg_load "${CONFIG}"
    SRC_DEST=$(cfg_source_dest) || die "could not read source.dest from ${CONFIG}"
    # shellcheck disable=SC2034 # caller globals: lib.sh's render_core_unit reads them
    RUN_USER=$(cfg_get '.core.run_user' "$(id -un)")
    # shellcheck disable=SC2034
    DB_MODE=$(cfg_get '.database.mode' 'container')
    # shellcheck disable=SC2034
    BUN_BIN=/usr/local/bin/bun
  elif [[ -e ${RESTORE_ENV_SET}/UNITS_EXCLUDED ]]; then
    die "--restore-env-backup: ${RESTORE_ENV_SET} was taken during a git->artifact conversion, so restoring it re-renders the core units — pass --config <the host's tau-setup.yaml> as well"
  fi
  require_root_capability
  env_prefix_lock
  restore_rc=0
  env_rename_backup_restore "${RESTORE_ENV_SET}" || restore_rc=$?
  case ${restore_rc} in
    0) log_info "restored the env files from ${RESTORE_ENV_SET}; any secret changed since that set was taken is reverted too" ;;
    3) die "--restore-env-backup: ${RESTORE_ENV_SET} needs the unit templates next to this script (systemd/*.service.tmpl) — nothing was changed" ;;
    *) die "--restore-env-backup: restoring ${RESTORE_ENV_SET} failed (see above)" ;;
  esac
  exit 0
fi

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
# ai, secrets) is deliberately NOT read: an upgrade renders no .env and needs
# no credential, which is what makes it runnable long after provisioning
# without re-supplying anything. The one exception is the Ficus env rename
# (see the header): it RENAMES the existing settings in place — no value is
# read into this script, re-derived or re-generated.
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

# ====================================================== env prefix (Ficus)
#
# First, before any preflight: a journaled env rename that an earlier run
# left behind (killed, OOM, reboot) is made to match the release that is
# serving right now — restored if it reads TAU_*, finished if it reads
# FICUS_*. Then the traps that restore THIS run's rename if it fails, is
# rolled back or is signalled (bash runs an EXIT trap with $?=0 on a signal,
# hence the explicit TERM/HUP/INT ones).
# One toolkit run at a time may rename, restore or reconcile this host.
env_prefix_lock
reconcile_rc=0
env_prefix_reconcile || reconcile_rc=$?
[[ ${reconcile_rc} -eq 0 ]] ||
  die "a journaled env rename could not be reconciled (${reconcile_rc}) — push the complete toolkit (systemd/*.service.tmpl, tau-backup.sh.tmpl) and re-run"
env_prefix_install_traps

# ============================================================== artifact mode

artifact_upgrade() {
  local acq='' rc=0 sha digest12 tree release_dir before before_sha tmpl target_prefix conv_tree conv_prefix

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
  # The env rename re-renders an installed tau-backup.sh from its template
  # (the old copy reads the pre-rename backup names), so the template must
  # travel with the toolkit whenever the host has a nightly backup.
  if [[ -f ${BACKUP_SCRIPT_PATH} && ! -f ${SCRIPT_DIR}/tau-backup.sh.tmpl ]]; then
    die "missing ${SCRIPT_DIR}/tau-backup.sh.tmpl — this host has ${BACKUP_SCRIPT_PATH}, which the env rename re-renders; push scripts/setup/tau-backup.sh.tmpl alongside lib.sh and upgrade-host.sh"
  fi
  # ...and it must be a script this toolkit can re-render: parse it now,
  # before any migration, rather than find out in the pre-flip hook.
  if [[ -f ${BACKUP_SCRIPT_PATH} ]]; then
    backup_script_read_values "${BACKUP_SCRIPT_PATH}"
  fi
  ensure_swapfile
  ensure_system_bun_node "${RUN_USER}" "$(command -v bun)"
  # The services this run will restart read <dest>/.env (EnvironmentFile in
  # both units), and an upgrade renders no .env — so if that file never named
  # a sandbox runtime (under either env prefix), the flip at step 5 brings
  # both units back DEAD. Refuse here, while nothing on the box has moved.
  require_env_file_sandbox_runtime "${SRC_DEST}/.env"

  # The artifact public key is NOT a secret, but openssl needs it as a file.
  # 0600, and the toolkit EXIT trap (env_prefix_install_traps) removes it, so
  # no exit path — including a die deep inside the verify — leaves it behind.
  ARTIFACT_PUBKEY_FILE=$(mktemp)
  chmod 600 "${ARTIFACT_PUBKEY_FILE}"
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
    # The units now name <dest>/current, which is the CONVERTED checkout — a
    # git tree has no artifact.json, so its package.json decides which env
    # spelling it reads (TAU for a pre-rename checkout). The env rename of
    # this run then leaves the units out of its backup set; a restore
    # re-renders them for this layout (N-I3).
    conv_tree=$(active_release_tree) || die "could not resolve ${SRC_DEST}/current after the conversion"
    conv_prefix=$(core_release_env_prefix "${conv_tree}") || die "could not tell which env prefix the converted checkout reads"
    install_core_units "${SCRIPT_DIR}/systemd" "${conv_prefix}"
    # shellcheck disable=SC2034 # read by lib.sh's migrate_env_prefix_host / env_rename_backup_create
    ARTIFACT_CONVERTED_THIS_RUN=1
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

  # The direction of the env rename comes from the release being activated
  # (N-C2), never from a literal. A release that predates the rename cannot
  # read a renamed host's settings: refuse now, while the only thing that
  # moved is the staged release (and a conversion, which is harmless).
  target_prefix=$(core_release_env_prefix "${release_dir}") || die "could not tell which env prefix ${release_dir} reads"
  if [[ ${target_prefix} == TAU && $(host_env_prefix "${SRC_DEST}/.env") == FICUS ]]; then
    die "target Core predates the Ficus rename but this host's settings are FICUS_*; re-run with --restore-env-backup <set> (see $(env_rename_backup_root)) or choose a Ficus release"
  fi

  log_step "artifact upgrade 4/5: env settings and systemd units are prepared right before the flip"
  # Both happen inside artifact_activate's pre-flip hook
  # (migrate_env_prefix_host_for): AFTER the candidate's migration succeeded
  # and IMMEDIATELY before `current` moves, so the old core runs against
  # renamed files for no longer than that one step. The hook renders the
  # units in the spelling the target reads — the ONLY unit render for a box
  # that was already on the artifact layout, i.e. where a changed template
  # reaches it — and artifact_activate daemon-reloads before it restarts, so
  # a changed unit and the flip take effect together.

  log_step 'artifact upgrade 5/5: migrate → rename env → flip → restart (auto-rollback on a failed health check)'
  # No `||` and no `if`: a failed activation must abort this script through
  # set -e. artifact_activate emits FICUS_RELEASE_ROLLED_BACK itself — it is the
  # only code that knows whether the flip survived. Its rollback hook puts the
  # env backup set back before the rollback restart; the EXIT trap does the
  # same for any other failure after the rename.
  # shellcheck disable=SC2034 # read by lib.sh's artifact_activate
  ARTIFACT_PREFLIP_HOOK=migrate_env_prefix_host_for
  # shellcheck disable=SC2034 # read by lib.sh's artifact_activate
  ARTIFACT_ROLLBACK_HOOK=env_prefix_restore_pending
  artifact_activate "${SRC_DEST}" "${release_dir}" "${CORE_PORT}"
  # The renamed files are what the serving release reads now.
  env_prefix_commit
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
# tau-worker against <dest>/.env, which this script never renders. An .env
# with no (or a retired) sandbox runtime under either env prefix means both
# units come back dead AFTER the checkout has already moved — so check before
# phase 1.
require_env_file_sandbox_runtime "${SRC_DEST}/.env"
if [[ -f ${BACKUP_SCRIPT_PATH} && ! -f ${SCRIPT_DIR}/tau-backup.sh.tmpl ]]; then
  die "missing ${SCRIPT_DIR}/tau-backup.sh.tmpl — this host has ${BACKUP_SCRIPT_PATH}, which the env rename re-renders; push scripts/setup/tau-backup.sh.tmpl alongside lib.sh and upgrade-host.sh"
fi
if [[ -f ${BACKUP_SCRIPT_PATH} ]]; then
  backup_script_read_values "${BACKUP_SCRIPT_PATH}"
fi

BEFORE_SHA=$(git -C "${SRC_DEST}" rev-parse HEAD)

# The env prefix the target revision reads (its committed package.json name,
# N-C2), asked after the fetch and BEFORE the checkout moves: a revision that
# predates the Ficus rename cannot read a renamed host's settings, so it is
# refused with the checkout, the build and the database untouched.
git_target_prefix_check() { # REV
  GIT_TARGET_PREFIX=$(git_rev_env_prefix "${SRC_DEST}" "$1") || die "could not tell which env prefix revision $1 reads"
  if [[ ${GIT_TARGET_PREFIX} == TAU && $(host_env_prefix "${SRC_DEST}/.env") == FICUS ]]; then
    die "target Core predates the Ficus rename but this host's settings are FICUS_*; re-run with --restore-env-backup <set> (see $(env_rename_backup_root)) or choose a Ficus release"
  fi
}

log_step "phase 1/4: source → ${SRC_REF}"
# shellcheck disable=SC2034 # read by lib.sh's git_source_sync
GIT_PRE_CHECKOUT_HOOK=git_target_prefix_check
git_source_sync

# The checkout's own package.json now decides (it is the revision above).
GIT_TARGET_PREFIX=$(core_release_env_prefix "${SRC_DEST}") || die "could not tell which env prefix ${SRC_DEST} reads"

log_step "phase 2/4: dependencies + build (core + cli${CORE_SERVE_WEB:+ + web}) — ~1-2 min, silent while it builds"
build_app "${SRC_DEST}" "${CORE_SERVE_WEB}"

log_step "phase 3/4: database migrations"
run_db_migrations "${SRC_DEST}"

ensure_tau_api_memory_guardrail
if [[ ${FICUS_API_MEMORY_GUARDRAIL_CHANGED} -eq 1 ]]; then
  as_root systemctl daemon-reload
fi

# The env rename, immediately before the restart: the new checkout's
# migrations above already read the old names through its in-process bridge,
# so renaming as late as possible only shrinks the window. Git mode has no
# auto-rollback: a failed restart restores the backup set over the new
# checkout (the EXIT trap), which that release's one-release fallback boots.
migrate_env_prefix_host "${GIT_TARGET_PREFIX}" "${SRC_DEST}"

log_step "phase 4/4: restart tau-api + tau-worker"
restart_core_services "${CORE_PORT}"
env_prefix_commit

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
