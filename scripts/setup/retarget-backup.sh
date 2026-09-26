#!/usr/bin/env bash
# retarget-backup.sh — ON-TARGET tau backup-target retarget primitive.
#
# Points an ALREADY SET UP tau host's nightly encrypted backup at a new
# S3-compatible bucket (e.g. tau-backups -> ficus-backups) with a new scoped
# key, without re-running setup-host.sh. setup-host.sh's phase_backup bakes
# the endpoint/region/bucket into /usr/local/bin/tau-backup.sh and the S3 key
# into /etc/tau/backup.env at provision time, and nothing re-reads them
# later (upgrade-host.sh never touches backups), so a bucket move needs this
# narrow re-render. A full setup-host.sh re-run is not an option on a hosted
# tenant: it needs secrets that are deleted from the box after provisioning.
#
# First, unconditionally (in both --dry-run and real execution) and before
# anything is changed: validate the flags and the pushed secrets file, read
# the live backup.env (for the passphrase, which is carried over unchanged)
# and the live tau-backup.sh (for its non-S3 values: DEST, HOME_DIR, DB_MODE,
# DB_CONTAINER, S3_PREFIX, BACKUP_ENV_FILE), and render both replacements in
# memory. Then, for a real run only:
#
#   1. verify: one read-only signed ListObjectsV2 against the NEW bucket,
#      under this host's prefix, with the NEW key — the same request the
#      nightly job's retention step makes. A failure stops here, with
#      NOTHING changed (so a bad key or a missing bucket can never leave the
#      host's backups pointed somewhere they cannot write).
#   2. back up (timestamped copies next to the originals) whichever of
#      tau-backup.sh, backup.env and the yaml are about to change
#   3. stage each changed file next to its original (same directory, the
#      original's mode and owner:group), then swap tau-backup.sh and then
#      backup.env into place with an atomic rename each
#   4. rewrite backup.s3_endpoint / s3_region / s3_bucket in the on-VM yaml
#      (the non-secret keys only — never the credential env names, the
#      prefix, the schedule or backup.enabled)
#   5. read both installed files back and require them byte-identical to
#      what was verified in step 1
#
# Untouched, by design: the backup passphrase (FICUS_BACKUP_PASSPHRASE is read
# from the live backup.env and written back with the same value — a changed
# passphrase would make every existing backup unrestorable with the new
# config), tau-backup.timer/.service (the schedule), backup.s3_prefix, and
# every object in either bucket (copying old backups across is an ops step).
# tau-backup.sh is re-rendered from the tau-backup.sh.tmpl shipped next to
# this script, so its logic becomes that template's — exactly what a fresh
# provision would install; --dry-run prints the diff.
#
# Idempotent: when the rendered files and the yaml already match, nothing is
# written or backed up (the verification still runs) and the result is
# `unchanged`.
#
# FAILURE BEHAVIOR, exact. Validation, the step-1 verification, the backups
# and the staging (steps 2-3 up to the first rename) change nothing live: any
# failure there leaves both files and the yaml byte-identical and removes
# every staged file. The two renames in step 3 are the only non-atomic pair:
# if tau-backup.sh was swapped and backup.env's swap then fails, tau-backup.sh
# is put back (staged + renamed again, from the exact bytes read in
# validation) before exiting; if THAT fails, the message says so and names
# the step-2 backup to copy back by hand. A step-4 (yaml) failure happens
# after the host is already retargeted: the files are live and verified, the
# yaml still names the old target, and a re-run finishes it (it rewrites only
# the yaml). A step-5 mismatch means something rewrote a file under us: the
# message names it; re-run. SIGHUP (a dropped SSH session) is ignored across
# the two renames and their rollback. A nightly run starting mid-swap is harmless: the
# rename leaves any running copy reading the file it opened, and at worst
# that one night's upload is refused and systemd marks the unit failed.
#
# Output: log lines on stderr; on stdout, the dry-run plan and these markers
# (the last lines on stdout, always in this order):
#   FICUS_RETARGET_BACKUP_RESULT=retargeted|unchanged|dry-run|not-applicable
#   FICUS_RETARGET_BACKUP_ENDPOINT=<url>   (not with not-applicable)
#   FICUS_RETARGET_BACKUP_REGION=<region>  (not with not-applicable)
#   FICUS_RETARGET_BACKUP_BUCKET=<bucket>  (not with not-applicable)
# Secret values (the S3 secret key, the passphrase) are never printed, in
# logs, the plan, or error messages; the access key id is shown redacted.
#
# Exit codes: 0 retargeted, unchanged or dry-run; 3 not applicable (this host
# was set up with backup.enabled false, so there is no backup to retarget);
# 1 anything else (see FAILURE BEHAVIOR for what state that leaves).
#
# Run as root on the tenant VM (EUID 0; sudo is not supported), from the
# directory holding the copied toolkit: this script, lib.sh and
# tau-backup.sh.tmpl side by side.
set -euo pipefail
# Never trace: an inherited `bash -x` / SHELLOPTS=xtrace would print every
# assignment below, secret key and passphrase included.
set +x
# Byte semantics for everything this script parses and compares (backup.env,
# the secrets file, the live tau-backup.sh): whatever locale root's session
# carries, a non-ASCII passphrase byte is a byte, never a (possibly invalid)
# multibyte character. Exported so the render (sed) and yq see the same.
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

EXIT_NOT_APPLICABLE=3

usage() {
  cat <<'EOF'
Usage: retarget-backup.sh --config tau-setup.yaml --secrets FILE \
                          --bucket NAME --endpoint https://HOST [--region REGION] [--dry-run]

Points this host's nightly encrypted backup at a new S3-compatible bucket
with a new key. See the header comment in this file for the full behavior.

Options:
  --config FILE      the on-VM config this host was set up with (see
                      tau-setup.example.yaml) — backup.s3_endpoint/region/
                      bucket are rewritten in place
  --secrets FILE     the new key, as sourced-style KEY=VALUE lines (values
                      bare or single-quoted); must be mode 0600 (no group/
                      other access) and owned by the invoking user. Exactly
                      these keys, both required:
                        FICUS_BACKUP_S3_ACCESS_KEY
                        FICUS_BACKUP_S3_SECRET_KEY
  --bucket NAME      the new bucket (S3 naming rules: 3-63 of a-z 0-9 . -)
  --endpoint URL     the new endpoint: https://host[:port], nothing else
  --region REGION    the new SigV4 region (default: the region currently
                      in this host's tau-backup.sh)
  --dry-run          validate and print the plan without contacting S3 or
                      changing anything
  -h, --help         show this help

Exit codes: 0 done (or already done, or dry run); 3 backups are not enabled
on this host; 1 failure.
EOF
}

CONFIG='' SECRETS='' BUCKET='' ENDPOINT='' REGION='' DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG=${2:?--config needs a value}
      shift 2
      ;;
    --secrets)
      SECRETS=${2:?--secrets needs a value}
      shift 2
      ;;
    --bucket)
      BUCKET=${2:?--bucket needs a value}
      shift 2
      ;;
    --endpoint)
      ENDPOINT=${2:?--endpoint needs a value}
      shift 2
      ;;
    --region)
      REGION=${2:?--region needs a value}
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

for _flag in config secrets bucket endpoint; do
  _var=$(printf '%s' "${_flag}" | tr '[:lower:]' '[:upper:]')
  [[ -n ${!_var} ]] || {
    usage >&2
    die "--${_flag} is required"
  }
done
unset _flag _var

# Result markers — see the header. Always the last lines on stdout.
emit_result() { # RESULT
  printf 'FICUS_RETARGET_BACKUP_RESULT=%s\n' "$1"
  [[ $1 == not-applicable ]] && return 0
  printf 'FICUS_RETARGET_BACKUP_ENDPOINT=%s\nFICUS_RETARGET_BACKUP_REGION=%s\nFICUS_RETARGET_BACKUP_BUCKET=%s\n' \
    "${ENDPOINT}" "${REGION}" "${BUCKET}"
}

# ============================================================== validate
#
# Everything here runs BEFORE any host mutation, in both dry-run and real
# execution; every failure is a die() (exit 1) naming what is wrong.

# The new target. These regexes are also what makes the values safe to hand
# to render_backup_script_content's sed program (no '|', '&' or '\').
[[ ${BUCKET} =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
  die "--bucket must be an S3 bucket name: 3-63 characters of a-z, 0-9, '.', '-', starting and ending alphanumeric (got '${BUCKET}')"
[[ ${ENDPOINT} =~ ^https://[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*(:[0-9]{1,5})?$ ]] ||
  die "--endpoint must be https://<host>[:port] — no userinfo, path, query, fragment or trailing slash (got '${ENDPOINT}')"
if [[ -n ${REGION} ]]; then
  [[ ${REGION} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    die "--region must be a region name like nyc3 or us-east-1 (got '${REGION}')"
fi

[[ -f ${CONFIG} ]] || die "config file '${CONFIG}' not found — this host does not look like it was set up by this toolkit"

# The secrets file: the only channel the new key may arrive by (never argv).
# Refuse one other users could have read, or that someone else controls.
[[ ! -L ${SECRETS} ]] || die "--secrets '${SECRETS}' is a symlink — pass the file itself"
[[ -f ${SECRETS} ]] || die "--secrets file '${SECRETS}' not found"
[[ -O ${SECRETS} ]] || die "--secrets file '${SECRETS}' is not owned by the invoking user (EUID ${EUID})"
SECRETS_MOG=$(_file_mode_owner_group "${SECRETS}") || die "could not stat --secrets file '${SECRETS}'"
SECRETS_MODE=${SECRETS_MOG%% *}
[[ ${SECRETS_MODE} =~ ^[0-7]{3,4}$ ]] || die "could not read the mode of --secrets file '${SECRETS}'"
((8#${SECRETS_MODE} & 8#077)) &&
  die "--secrets file '${SECRETS}' is mode ${SECRETS_MODE} — it must not be readable by group/other (chmod 600 it)"
read_file_exact "${SECRETS}" SECRETS_RAW || die "could not read --secrets file '${SECRETS}'"
sh_env_parse "${SECRETS_RAW}" "--secrets file" \
  FICUS_BACKUP_S3_ACCESS_KEY:NEW_ACCESS_KEY FICUS_BACKUP_S3_SECRET_KEY:NEW_SECRET_KEY ||
  die "--secrets file '${SECRETS}' is not in the expected format (see --help)"
unset SECRETS_RAW
[[ -n ${NEW_ACCESS_KEY} ]] || die "--secrets file '${SECRETS}' does not set FICUS_BACKUP_S3_ACCESS_KEY"
[[ -n ${NEW_SECRET_KEY} ]] || die "--secrets file '${SECRETS}' does not set FICUS_BACKUP_S3_SECRET_KEY"

if [[ ${DRY_RUN} -eq 1 ]]; then
  yq_is_mikefarah || die "dry run needs mikefarah yq v4 on PATH to parse the config (brew install yq / see README)"
else
  ensure_yq
fi
cfg_load "${CONFIG}"

# Captured first, never inside [[ … ]]: a die() in a command substitution only
# ends that subshell, so `[[ $(cfg_bool …) != true ]]` would read an invalid
# value or a yq failure as "not enabled" and exit 3 instead of failing.
BACKUP_ENABLED=$(cfg_bool '.backup.enabled' 'false') ||
  die "could not read backup.enabled from ${CONFIG} (see the error above)"
if [[ ${BACKUP_ENABLED} != true ]]; then
  log_warn "backup.enabled is not true in ${CONFIG} — this host has no nightly backup to retarget; nothing to do"
  emit_result not-applicable
  exit "${EXIT_NOT_APPLICABLE}"
fi

TEMPLATE="${SCRIPT_DIR}/tau-backup.sh.tmpl"
[[ -f ${TEMPLATE} ]] || die "tau-backup.sh.tmpl not found next to this script (${TEMPLATE}) — push it with retarget-backup.sh and lib.sh"

# The live tau-backup.sh: the non-S3 values it was rendered with are carried
# over verbatim (re-deriving them would need setup-host.sh's whole config,
# secrets included). Each is a `NAME='value'` line near the top, as the
# template writes them.
[[ -f ${BACKUP_SCRIPT_PATH} ]] ||
  die "${BACKUP_SCRIPT_PATH} not found, but backup.enabled is true — setup-host.sh's phase_backup never completed on this host; re-run it rather than retargeting"
read_file_exact "${BACKUP_SCRIPT_PATH}" LIVE_SCRIPT || die "could not read ${BACKUP_SCRIPT_PATH}"
LIVE_TOKENS='DEST HOME_DIR DB_MODE DB_CONTAINER S3_ENDPOINT S3_REGION S3_BUCKET S3_PREFIX BACKUP_ENV_FILE'
_found=' '
_rest=${LIVE_SCRIPT}
while [[ -n ${_rest} ]]; do
  _line=${_rest%%$'\n'*}
  if [[ ${_line} == "${_rest}" ]]; then _rest=''; else _rest=${_rest#*$'\n'}; fi
  if [[ ${_line} =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] && [[ " ${LIVE_TOKENS} " == *" ${BASH_REMATCH[1]} "* ]] &&
    [[ ${_found} != *" ${BASH_REMATCH[1]} "* ]]; then
    printf -v "LIVE_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
    _found+="${BASH_REMATCH[1]} "
  fi
done
for _tok in ${LIVE_TOKENS}; do
  [[ ${_found} == *" ${_tok} "* ]] ||
    die "${BACKUP_SCRIPT_PATH} has no ${_tok}='…' line — it was not rendered from a tau-backup.sh.tmpl this script understands; re-run setup-host.sh's phase_backup instead"
done
unset _found _rest _line _tok
for _tok in DEST HOME_DIR DB_MODE S3_PREFIX BACKUP_ENV_FILE; do
  _val="LIVE_${_tok}"
  [[ -n ${!_val} ]] || die "${BACKUP_SCRIPT_PATH} has an empty ${_tok} — refusing to re-render it"
done
# Carried-over values go through the same sed program; refuse any it would
# corrupt (the original render could not have produced one, so this means
# the file was edited by hand).
for _tok in DEST HOME_DIR DB_MODE DB_CONTAINER S3_PREFIX BACKUP_ENV_FILE; do
  _val="LIVE_${_tok}"
  [[ ${!_val} != *[\|\&\\]* ]] || die "${BACKUP_SCRIPT_PATH}'s ${_tok} contains '|', '&' or '\\' — refusing to re-render it"
done
unset _tok _val
[[ ${LIVE_BACKUP_ENV_FILE} == "${BACKUP_ENV_TARGET}" ]] ||
  die "${BACKUP_SCRIPT_PATH} reads its secrets from ${LIVE_BACKUP_ENV_FILE}, not ${BACKUP_ENV_TARGET} — refusing to write a file it does not read"

[[ -n ${REGION} ]] || REGION=${LIVE_S3_REGION}
[[ ${REGION} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
  die "no usable region: pass --region (the current tau-backup.sh has '${REGION}')"

YAML_PREFIX=$(cfg_get '.backup.s3_prefix' '') || die "could not read backup.s3_prefix from ${CONFIG}"
[[ ${YAML_PREFIX} == "${LIVE_S3_PREFIX}" ]] ||
  log_warn "backup.s3_prefix in ${CONFIG} ('${YAML_PREFIX}') differs from the prefix tau-backup.sh actually uses ('${LIVE_S3_PREFIX}') — keeping the live one"

# The live backup.env: only the passphrase is carried over. Parsed, never
# sourced; any line this script would silently drop on re-render is refused.
[[ -f ${BACKUP_ENV_TARGET} ]] ||
  die "${BACKUP_ENV_TARGET} not found, but backup.enabled is true — setup-host.sh's phase_backup never completed on this host; re-run it rather than retargeting"
read_file_exact "${BACKUP_ENV_TARGET}" LIVE_ENV || die "could not read ${BACKUP_ENV_TARGET}"
sh_env_parse "${LIVE_ENV}" "${BACKUP_ENV_TARGET}" \
  FICUS_BACKUP_S3_ACCESS_KEY:LIVE_ACCESS_KEY FICUS_BACKUP_S3_SECRET_KEY:LIVE_SECRET_KEY FICUS_BACKUP_PASSPHRASE:PASSPHRASE ||
  die "${BACKUP_ENV_TARGET} is not in the format setup-host.sh writes — refusing to re-render it (and lose whatever it holds)"
[[ -n ${PASSPHRASE} ]] ||
  die "${BACKUP_ENV_TARGET} has no FICUS_BACKUP_PASSPHRASE — refusing to retarget a backup whose encryption passphrase is unknown"

# Both replacements, rendered in memory. The sentinel keeps command
# substitution from dropping the render's trailing newline(s), so the bytes
# match what install_rendered writes for setup-host.sh.
if ! NEW_SCRIPT=$(render_backup_script_content "${TEMPLATE}" \
  "${LIVE_DEST}" "${LIVE_HOME_DIR}" "${LIVE_DB_MODE}" "${LIVE_DB_CONTAINER}" \
  "${ENDPOINT}" "${REGION}" "${BUCKET}" "${LIVE_S3_PREFIX}" "${LIVE_BACKUP_ENV_FILE}" && printf x) ||
  [[ ${NEW_SCRIPT} != *x ]]; then
  die "failed to render ${TEMPLATE}"
fi
NEW_SCRIPT=${NEW_SCRIPT%x}
[[ -n ${NEW_SCRIPT} ]] || die "rendering ${TEMPLATE} produced nothing"
[[ ! ${NEW_SCRIPT} =~ @[A-Z_]+@ ]] || die "rendering ${TEMPLATE} left an unsubstituted @PLACEHOLDER@ — this template needs a newer retarget-backup.sh"

if ! NEW_ENV=$(render_backup_env_content real "${NEW_ACCESS_KEY}" "${NEW_SECRET_KEY}" "${PASSPHRASE}" && printf x) ||
  [[ ${NEW_ENV} != *x ]]; then
  die "failed to render the new ${BACKUP_ENV_TARGET}"
fi
NEW_ENV=${NEW_ENV%x}
# Self-check, independent of the renderer: the new file must read back as the
# new key and the UNCHANGED passphrase.
sh_env_parse "${NEW_ENV}" "rendered ${BACKUP_ENV_TARGET}" \
  FICUS_BACKUP_S3_ACCESS_KEY:CHECK_ACCESS_KEY FICUS_BACKUP_S3_SECRET_KEY:CHECK_SECRET_KEY FICUS_BACKUP_PASSPHRASE:CHECK_PASSPHRASE ||
  die "the rendered ${BACKUP_ENV_TARGET} does not parse back"
[[ ${CHECK_ACCESS_KEY} == "${NEW_ACCESS_KEY}" && ${CHECK_SECRET_KEY} == "${NEW_SECRET_KEY}" && ${CHECK_PASSPHRASE} == "${PASSPHRASE}" ]] ||
  die "the rendered ${BACKUP_ENV_TARGET} does not read back as the new key and the unchanged passphrase — refusing to install it"
unset CHECK_ACCESS_KEY CHECK_SECRET_KEY CHECK_PASSPHRASE

SCRIPT_CHANGED=0 ENV_CHANGED=0 YAML_CHANGED=0
[[ ${NEW_SCRIPT} == "${LIVE_SCRIPT}" ]] || SCRIPT_CHANGED=1
[[ ${NEW_ENV} == "${LIVE_ENV}" ]] || ENV_CHANGED=1
YAML_ENDPOINT=$(cfg_get '.backup.s3_endpoint' '') || die "could not read backup.s3_endpoint from ${CONFIG}"
YAML_REGION=$(cfg_get '.backup.s3_region' '') || die "could not read backup.s3_region from ${CONFIG}"
YAML_BUCKET=$(cfg_get '.backup.s3_bucket' '') || die "could not read backup.s3_bucket from ${CONFIG}"
[[ ${YAML_ENDPOINT} == "${ENDPOINT}" && ${YAML_REGION} == "${REGION}" && ${YAML_BUCKET} == "${BUCKET}" ]] || YAML_CHANGED=1

changed_word() { [[ $1 -eq 1 ]] && printf 'rewrite' || printf 'already current, not touched'; }

# ============================================================== dry run

if [[ ${DRY_RUN} -eq 1 ]]; then
  log_step "DRY RUN — printing the plan; nothing will be contacted, executed or modified"
  printf '\ncurrent target (from %s)\n' "${BACKUP_SCRIPT_PATH}"
  plan "endpoint ${LIVE_S3_ENDPOINT}  region ${LIVE_S3_REGION}  bucket ${LIVE_S3_BUCKET}  prefix ${LIVE_S3_PREFIX}"
  printf '\nnew target\n'
  plan "endpoint ${ENDPOINT}  region ${REGION}  bucket ${BUCKET}  prefix ${LIVE_S3_PREFIX} (unchanged)"
  printf '\nverify (before changing anything)\n'
  plan "signed ListObjectsV2 (max-keys=1, read-only) of s3://${BUCKET}/${LIVE_S3_PREFIX%/}/ at ${ENDPOINT} with the new key; stop with nothing changed unless it returns 200"
  printf '\n%s — %s (mode/owner preserved)\n' "${BACKUP_SCRIPT_PATH}" "$(changed_word "${SCRIPT_CHANGED}")"
  if [[ ${SCRIPT_CHANGED} -eq 1 ]]; then
    plan "re-render from ${TEMPLATE}; diff against the live file:"
    diff -u -L "${BACKUP_SCRIPT_PATH} (live)" -L "${BACKUP_SCRIPT_PATH} (new)" \
      <(printf '%s' "${LIVE_SCRIPT}") <(printf '%s' "${NEW_SCRIPT}") | sed 's/^/  | /' || true
  fi
  printf '\n%s — %s (mode/owner preserved; secrets redacted)\n' "${BACKUP_ENV_TARGET}" "$(changed_word "${ENV_CHANGED}")"
  plan "FICUS_BACKUP_S3_ACCESS_KEY=$(redact_secret "${NEW_ACCESS_KEY}")"
  plan "FICUS_BACKUP_S3_SECRET_KEY=<redacted>"
  plan "FICUS_BACKUP_PASSPHRASE=<unchanged, redacted>"
  printf '\nyaml — %s — %s\n' "${CONFIG}" "$(changed_word "${YAML_CHANGED}")"
  plan "backup.s3_endpoint: ${ENDPOINT} (was ${YAML_ENDPOINT:-<unset>})"
  plan "backup.s3_region: ${REGION} (was ${YAML_REGION:-<unset>})"
  plan "backup.s3_bucket: ${BUCKET} (was ${YAML_BUCKET:-<unset>})"
  printf '\nuntouched\n'
  plan "tau-backup.timer / tau-backup.service (schedule), FICUS_BACKUP_PASSPHRASE, backup.s3_prefix, backup credential env names, every bucket object"
  emit_result dry-run
  exit 0
fi

# Unattended, as root, against a live tenant: no sudo fallback.
[[ ${EUID} -eq 0 ]] ||
  die "retarget-backup.sh must run as root (EUID=${EUID}) — it rewrites root-owned ${BACKUP_ENV_TARGET} and ${BACKUP_SCRIPT_PATH}; run it as root directly (sudo is not supported here)"

# ============================================================== 1. verify

log_step "1/5: verify the new key can list s3://${BUCKET}/${LIVE_S3_PREFIX%/}/ at ${ENDPOINT}"
s3_list_probe "${ENDPOINT}" "${REGION}" "${BUCKET}" "${LIVE_S3_PREFIX}" "${NEW_ACCESS_KEY}" "${NEW_SECRET_KEY}" ||
  die "the new backup target failed verification — nothing was changed"
log_info "verified: the new key lists the new bucket under this host's prefix"

if [[ $((SCRIPT_CHANGED + ENV_CHANGED + YAML_CHANGED)) -eq 0 ]]; then
  log_info "already retargeted: ${BACKUP_SCRIPT_PATH}, ${BACKUP_ENV_TARGET} and ${CONFIG} all match — nothing written"
  emit_result unchanged
  exit 0
fi

# ============================================================== 2. back up

log_step "2/5: back up the files about to change"
SCRIPT_BACKUP='' ENV_BACKUP=''
if [[ ${SCRIPT_CHANGED} -eq 1 ]]; then
  SCRIPT_BACKUP=$(backup_file "${BACKUP_SCRIPT_PATH}") && [[ -n ${SCRIPT_BACKUP} ]] ||
    die "could not back up ${BACKUP_SCRIPT_PATH} — nothing was changed"
fi
if [[ ${ENV_CHANGED} -eq 1 ]]; then
  ENV_BACKUP=$(backup_file "${BACKUP_ENV_TARGET}") && [[ -n ${ENV_BACKUP} ]] ||
    die "could not back up ${BACKUP_ENV_TARGET} — nothing was changed"
fi
if [[ ${YAML_CHANGED} -eq 1 ]]; then
  _yaml_backup=$(backup_file "${CONFIG}") && [[ -n ${_yaml_backup} ]] ||
    die "could not back up ${CONFIG} — nothing was changed"
  unset _yaml_backup
fi

# ============================================================== 3. swap files

log_step "3/5: install the re-rendered ${BACKUP_SCRIPT_PATH} and ${BACKUP_ENV_TARGET}"
STAGED_SCRIPT='' STAGED_ENV='' RESTORE_STAGED=''
cleanup_staged() { rm -f -- ${STAGED_SCRIPT:+"${STAGED_SCRIPT}"} ${STAGED_ENV:+"${STAGED_ENV}"} ${RESTORE_STAGED:+"${RESTORE_STAGED}"}; }
trap cleanup_staged EXIT

if [[ ${SCRIPT_CHANGED} -eq 1 ]]; then
  stage_file_replacement "${BACKUP_SCRIPT_PATH}" "${NEW_SCRIPT}" STAGED_SCRIPT ||
    die "could not stage the new ${BACKUP_SCRIPT_PATH} — nothing was changed"
fi
if [[ ${ENV_CHANGED} -eq 1 ]]; then
  stage_file_replacement "${BACKUP_ENV_TARGET}" "${NEW_ENV}" STAGED_ENV ||
    die "could not stage the new ${BACKUP_ENV_TARGET} — nothing was changed"
fi

# From the first rename to the end of the rollback, a dropped SSH session
# (SIGHUP) must not kill this script between the two renames — that would
# leave the new tau-backup.sh with the old key. The previous HUP disposition
# (if any) is put back right after.
PREV_HUP_TRAP=$(trap -p HUP)
trap '' HUP
if [[ ${SCRIPT_CHANGED} -eq 1 ]]; then
  mv -f -- "${STAGED_SCRIPT}" "${BACKUP_SCRIPT_PATH}" ||
    die "could not install the new ${BACKUP_SCRIPT_PATH} — nothing was changed"
  STAGED_SCRIPT=''
fi
if [[ ${ENV_CHANGED} -eq 1 ]] && ! mv -f -- "${STAGED_ENV}" "${BACKUP_ENV_TARGET}"; then
  if [[ ${SCRIPT_CHANGED} -eq 0 ]]; then
    die "could not install the new ${BACKUP_ENV_TARGET} — nothing was changed"
  fi
  # tau-backup.sh is already the new one: put the old bytes back the same
  # atomic way, so the host keeps a consistent (old) script + key pair.
  if stage_file_replacement "${BACKUP_SCRIPT_PATH}" "${LIVE_SCRIPT}" RESTORE_STAGED &&
    mv -f -- "${RESTORE_STAGED}" "${BACKUP_SCRIPT_PATH}"; then
    RESTORE_STAGED=''
    die "could not install the new ${BACKUP_ENV_TARGET}; ${BACKUP_SCRIPT_PATH} was restored to its previous content — the host still backs up to the old target, nothing else was changed"
  fi
  die "could not install the new ${BACKUP_ENV_TARGET}, and FAILED to restore ${BACKUP_SCRIPT_PATH} — it now targets s3://${BUCKET} while ${BACKUP_ENV_TARGET} still holds the OLD key, so the next backup will fail; copy ${SCRIPT_BACKUP} back over ${BACKUP_SCRIPT_PATH} by hand (cp -p) or re-run this script"
fi
STAGED_ENV=''
if [[ -n ${PREV_HUP_TRAP} ]]; then eval "${PREV_HUP_TRAP}"; else trap - HUP; fi
unset PREV_HUP_TRAP
if [[ $((SCRIPT_CHANGED + ENV_CHANGED)) -eq 0 ]]; then
  log_info "${BACKUP_SCRIPT_PATH} and ${BACKUP_ENV_TARGET} were already current — not touched"
else
  log_info "installed:${SCRIPT_BACKUP:+ ${BACKUP_SCRIPT_PATH} (target s3://${BUCKET} at ${ENDPOINT}, region ${REGION})}${ENV_BACKUP:+ ${BACKUP_ENV_TARGET} (new key; passphrase unchanged; values not logged)}"
fi

# ============================================================== 4. yaml

if [[ ${YAML_CHANGED} -eq 1 ]]; then
  log_step "4/5: record the new target in ${CONFIG}"
  # A cfg_set failure dies inside it; the files are already live and
  # verified at this point, so say that rather than "nothing changed".
  if ! (
    cfg_set '.backup.s3_endpoint' "${ENDPOINT}"
    cfg_set '.backup.s3_region' "${REGION}"
    cfg_set '.backup.s3_bucket' "${BUCKET}"
  ); then
    die "the backup files ARE retargeted (the host now backs up to s3://${BUCKET}), but recording it in ${CONFIG} failed — re-run this script to finish (it will only rewrite the yaml)"
  fi
  # Each cfg_set above is `yq … || die`, and die() is a literal exit, so the
  # subshell's status is trustworthy even though errexit is suppressed in an
  # `if` condition. Read the result back anyway: cheap, and it is the record.
  if ! _rb_endpoint=$(cfg_get '.backup.s3_endpoint' '') || ! _rb_region=$(cfg_get '.backup.s3_region' '') ||
    ! _rb_bucket=$(cfg_get '.backup.s3_bucket' ''); then
    die "the backup files ARE retargeted, but ${CONFIG} could not be read back — re-run this script to finish"
  fi
  [[ ${_rb_endpoint} == "${ENDPOINT}" && ${_rb_region} == "${REGION}" && ${_rb_bucket} == "${BUCKET}" ]] ||
    die "the backup files ARE retargeted, but ${CONFIG} does not read back as the new target — re-run this script to finish"
  unset _rb_endpoint _rb_region _rb_bucket
fi

# ============================================================== 5. read back

log_step "5/5: read the installed files back"
read_file_exact "${BACKUP_SCRIPT_PATH}" INSTALLED_SCRIPT || die "could not read back ${BACKUP_SCRIPT_PATH} — re-run this script"
[[ ${INSTALLED_SCRIPT} == "${NEW_SCRIPT}" ]] ||
  die "${BACKUP_SCRIPT_PATH} does not match what was verified — something rewrote it during this run; re-run this script"
read_file_exact "${BACKUP_ENV_TARGET}" INSTALLED_ENV || die "could not read back ${BACKUP_ENV_TARGET} — re-run this script"
[[ ${INSTALLED_ENV} == "${NEW_ENV}" ]] ||
  die "${BACKUP_ENV_TARGET} does not match what was verified — something rewrote it during this run; re-run this script"
unset INSTALLED_ENV

log_info "retarget complete: nightly backups now go to s3://${BUCKET}/${LIVE_S3_PREFIX%/}/ at ${ENDPOINT} (region ${REGION}); schedule and passphrase unchanged"
emit_result retargeted
