#!/usr/bin/env bash
# setup-host.sh — ON-TARGET tau setup primitive.
#
# Takes a fresh Ubuntu 24.04 host from nothing → a running tau (core API +
# worker under systemd, DB migrated, web UI served, and — only when
# ai.model/squad.name are explicitly configured — an AI provider + starter
# squad seeded) whose ONLY remaining step is a human opening the printed URL
# and creating the first admin passkey (the in-app onboarding checklist
# takes it from there).
#
# Idempotent: safe to re-run. Clone becomes fetch+checkout, the DB container
# is reused, secrets already in <dest>/.env are preserved, systemd units are
# re-rendered and services restarted, and seeding checks before creating.
#
# See scripts/setup/README.md and tau-setup.example.yaml for the full story.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: setup-host.sh --config tau-setup.yaml [options]
       setup-host.sh --wizard [--config OUT.yaml]

Sets up a complete tau instance ON THIS HOST (fresh Ubuntu 24.04 + systemd).
To provision a cloud VM and set it up remotely, use provision.sh instead.

Options:
  --config FILE   config file (see tau-setup.example.yaml). With --wizard,
                  the path the generated config is written to (default
                  ./tau-setup.yaml).
  --wizard        interactively generate a config file, then exit
  --dry-run       print the full plan (phases, rendered .env with secrets
                  redacted, rendered systemd units) without executing anything
  -h, --help      show this help

Secrets are supplied via env vars, key-file paths, or TTY prompts — never via
the config file. Requires root or passwordless-ish sudo for apt/systemd/docker.

Phases: preflight → source → build → database → .env → migrate → systemd
        services → caddy ingress (optional, ingress.caddy) → nightly backup
        (optional, backup.enabled) → seed (provider key + starter squad+agent
        optional — see ai.model/squad.name; exe key delegated to seed.sh) →
        report.
EOF
}

CONFIG='' WIZARD=0 DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG=${2:?--config needs a value}
      shift 2
      ;;
    --wizard)
      WIZARD=1
      shift
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

if [[ ${WIZARD} -eq 1 ]]; then
  ensure_yq
  wizard_write_config "${CONFIG:-./tau-setup.yaml}"
  exit 0
fi

[[ -n ${CONFIG} ]] || {
  usage >&2
  die "--config is required (or use --wizard to generate one)"
}

# yq is needed to parse the config at all. In execute mode it is auto-installed
# on Linux; a dry run just requires it to be present.
if [[ ${DRY_RUN} -eq 1 ]]; then
  yq_is_mikefarah || die "dry run needs mikefarah yq v4 on PATH to parse the config (brew install yq / see README)"
else
  ensure_yq
fi
cfg_load "${CONFIG}"

# ============================================================== configuration

SRC_MODE=$(cfg_get '.source.mode' 'git-ssh')
SRC_REPO=$(cfg_require '.source.repo' 'git repository')
SRC_REF=$(cfg_get '.source.ref' 'main')
# Default dest is /opt/tau-CORE, deliberately NOT /opt/tau: the prebaked
# ficus-machine image (the default core VM image) OWNS /opt/tau for its own
# tooling (/opt/tau/bin, /opt/tau/prebaked, /opt/tau/bun, ...), so cloning the
# app there collides with a non-empty root-owned dir. Keep them separate.
SRC_DEST=$(expand_tilde "$(cfg_get '.source.dest' '/opt/tau-core')")
SRC_DEPLOY_KEY=$(expand_tilde "$(cfg_get '.source.deploy_key_path')")
case "${SRC_MODE}" in git-ssh | git-https | artifact) ;; *) die "config: source.mode must be git-ssh, git-https, or artifact (got '${SRC_MODE}')" ;; esac

# ============================================================== artifact mode
#
# The artifact inputs arrive in the ENVIRONMENT (the control plane's
# secrets.env channel), never the config file: three of them are presigned
# GET URLs, i.e. credentials, and a config file is not where credentials
# belong. All four required — a partial set is a delivery bug, and
# provisioning with a half-configured artifact input would either fail deep
# inside the verify or, worse, silently fall back to a source build when the
# control plane believed it shipped a verified release. Same all-or-nothing
# rule as upgrade-host.sh's mode selection, so the two paths cannot disagree
# about what "artifact mode" requires.
if [[ ${SRC_MODE} == artifact ]]; then
  # The units must point at <dest>/current from this run onward. Forced
  # rather than inferred: on a fresh box `releases/` does not exist yet at
  # the moment the render is prepared, and this must be set BEFORE anything
  # renders units.
  # shellcheck disable=SC2034 # caller global: lib.sh's core_run_root reads it
  CORE_LAYOUT=artifact

  FICUS_ARTIFACT_TARBALL_URL=${FICUS_ARTIFACT_TARBALL_URL:-}
  FICUS_ARTIFACT_MANIFEST_URL=${FICUS_ARTIFACT_MANIFEST_URL:-}
  FICUS_ARTIFACT_SIG_URL=${FICUS_ARTIFACT_SIG_URL:-}
  FICUS_ARTIFACT_PUBKEY_B64=${FICUS_ARTIFACT_PUBKEY_B64:-}
  if [[ -n ${FICUS_ARTIFACT_TARBALL_URL} && -n ${FICUS_ARTIFACT_MANIFEST_URL} && -n ${FICUS_ARTIFACT_SIG_URL} && -n ${FICUS_ARTIFACT_PUBKEY_B64} ]]; then
    : # all four present — proceed
  elif [[ -n ${FICUS_ARTIFACT_TARBALL_URL}${FICUS_ARTIFACT_MANIFEST_URL}${FICUS_ARTIFACT_SIG_URL}${FICUS_ARTIFACT_PUBKEY_B64} ]]; then
    # SOME but not all: a delivery bug. Falling through would either build
    # from source while the control plane believes it shipped a verified
    # artifact, or fail deep inside the verify with no clue why. Fail loudly
    # instead, naming exactly which inputs are missing.
    die "artifact inputs are incomplete — refusing to fall back to a source build (need FICUS_ARTIFACT_TARBALL_URL, FICUS_ARTIFACT_MANIFEST_URL, FICUS_ARTIFACT_SIG_URL and FICUS_ARTIFACT_PUBKEY_B64; missing:$(
      [[ -z ${FICUS_ARTIFACT_TARBALL_URL} ]] && printf ' FICUS_ARTIFACT_TARBALL_URL'
      [[ -z ${FICUS_ARTIFACT_MANIFEST_URL} ]] && printf ' FICUS_ARTIFACT_MANIFEST_URL'
      [[ -z ${FICUS_ARTIFACT_SIG_URL} ]] && printf ' FICUS_ARTIFACT_SIG_URL'
      [[ -z ${FICUS_ARTIFACT_PUBKEY_B64} ]] && printf ' FICUS_ARTIFACT_PUBKEY_B64'
      true
    ))"
  else
    # NONE set: unlike upgrade-host.sh (where this just means "not an
    # artifact upgrade — fall through to git mode"), setup-host.sh already
    # knows source.mode=artifact from the config, so there is no fallback —
    # this is a delivery bug. Named per-variable too: the control plane's
    # secrets writer silently skips unset vars, so an operator staring at
    # this message needs to know WHICH ones never arrived.
    die "source.mode=artifact needs FICUS_ARTIFACT_TARBALL_URL/_MANIFEST_URL/_SIG_URL/_PUBKEY_B64 in the environment (secrets.env); missing:$(
      [[ -z ${FICUS_ARTIFACT_TARBALL_URL} ]] && printf ' FICUS_ARTIFACT_TARBALL_URL'
      [[ -z ${FICUS_ARTIFACT_MANIFEST_URL} ]] && printf ' FICUS_ARTIFACT_MANIFEST_URL'
      [[ -z ${FICUS_ARTIFACT_SIG_URL} ]] && printf ' FICUS_ARTIFACT_SIG_URL'
      [[ -z ${FICUS_ARTIFACT_PUBKEY_B64} ]] && printf ' FICUS_ARTIFACT_PUBKEY_B64'
      true
    )"
  fi
fi

CORE_ORIGIN=$(cfg_require '.core.origin' 'browser-facing origin')
[[ ${CORE_ORIGIN} =~ ^https?://[^/[:space:]]+$ ]] ||
  die "config: core.origin must be a bare origin scheme://host[:port] with NO path (got '${CORE_ORIGIN}') — anything else silently breaks WebAuthn passkeys"
CORE_PORT=$(cfg_get '.core.port' '3000')
[[ ${CORE_PORT} =~ ^[0-9]+$ ]] || die "config: core.port must be a number"
CORE_SERVE_WEB=$(cfg_bool '.core.serve_web' 'true')
RUN_USER=$(cfg_get '.core.run_user' "$(id -un)")
# shellcheck disable=SC2034 # caller global: lib.sh's render_core_unit reads it
BUN_BIN=/usr/local/bin/bun

# Optional operator/control-plane env passthrough: a flat string map appended
# verbatim to <dest>/.env, after the built-ins (see build_env_content). A
# future cloud control plane uses this to inject per-tenant knobs (e.g.
# FICUS_MAX_MACHINES tier limits) without needing a new config field per knob.
# Built-ins always win — an attempt to override one is a configuration error,
# not something to silently ignore. Validation (and *_ENV secret-indirection
# resolution — see cfg_env_pairs in lib.sh) happens once here so a bad
# core.env fails fast, before any host mutation, in BOTH dry-run and real
# execution.
CORE_ENV_PAIRS=$(cfg_env_pairs '.core.env' real)
while IFS='=' read -r core_env_key _; do
  [[ -z ${core_env_key} ]] && continue
  case "${core_env_key}" in
    APP_URL | FICUS_WEB_ORIGIN | DATABASE_URL | FICUS_ENCRYPTION_KEY | FICUS_PASSWORD | FICUS_INTERNAL_EVENT_TOKEN)
      die "config: core.env may not set '${core_env_key}' — it is a built-in derived from core.origin/database/secrets, not a passthrough knob" ;;
    # FICUS_ROOT is owned by the systemd units (Environment=FICUS_ROOT=<run root>)
    # and decides which tree core reads its config, migrations and web dist
    # from. systemd applies EnvironmentFile= AFTER Environment=, so a FICUS_ROOT
    # in <dest>/.env WINS over the unit's — on an artifact box that means the
    # services silently run one release's code against another tree's files,
    # with no error anywhere. Refuse it at render time, where it is a one-line
    # config fix instead of a mystery.
    FICUS_ROOT)
      die "config: core.env may not set 'FICUS_ROOT' — it is unit-managed (Environment=FICUS_ROOT in tau-api/tau-worker, pointing at the active release) and a value in .env would override the unit and detach the running code from its own tree" ;;
  esac
done <<<"${CORE_ENV_PAIRS}"

# Optional caddy ingress (TLS-terminating vhost in front of core.origin) — off
# by default; the cloud control plane renders tenant configs with
# ingress.caddy: true.
#
# TLS is a SUPPLIED certificate (Cloudflare Origin CA), never ACME — see the
# origin TLS doctrine block in lib.sh for why, and never reintroduce ACME here.
# The paths are wherever the pair currently lives on THIS host: provision.sh
# pushes them to <remote dir>/keys/ and rewrites these two keys to match, the
# same way it already does for source.deploy_key_path.
CADDY_ENABLE=$(cfg_bool '.ingress.caddy' 'false')
CADDY_CERT_PATH=$(expand_tilde "$(cfg_get '.ingress.tls_cert_path' '')")
CADDY_KEY_PATH=$(expand_tilde "$(cfg_get '.ingress.tls_key_path' '')")
CADDY_HOST=''
if [[ ${CADDY_ENABLE} == true ]]; then
  [[ ${CORE_ORIGIN} == https://* ]] ||
    die "config: ingress.caddy requires core.origin to use https (caddy terminates TLS with the supplied origin certificate) — got '${CORE_ORIGIN}'"
  CADDY_HOST=$(caddy_host_from_origin "${CORE_ORIGIN}")
  [[ -n ${CADDY_CERT_PATH} ]] ||
    die "config: ingress.caddy requires ingress.tls_cert_path (the Cloudflare Origin CA certificate for this host — there is no ACME fallback)"
  [[ -n ${CADDY_KEY_PATH} ]] ||
    die "config: ingress.caddy requires ingress.tls_key_path (the origin certificate's private key)"
fi

# Optional nightly encrypted backup (pg dump + HOME_DIR → S3-compatible
# storage) — off by default; a future cloud control plane turns this on so
# tenant VMs have backups before anything else does. See phase_backup and
# tau-backup.sh.tmpl for the mechanics.
BACKUP_ENABLE=$(cfg_bool '.backup.enabled' 'false')
BACKUP_S3_ENDPOINT=$(cfg_get '.backup.s3_endpoint' '')
BACKUP_S3_REGION=$(cfg_get '.backup.s3_region' '')
BACKUP_S3_BUCKET=$(cfg_get '.backup.s3_bucket' '')
BACKUP_S3_PREFIX=$(cfg_get '.backup.s3_prefix' '')
BACKUP_S3_ACCESS_KEY_ENV=$(cfg_get '.backup.s3_access_key_env' 'FICUS_BACKUP_S3_ACCESS_KEY')
BACKUP_S3_SECRET_KEY_ENV=$(cfg_get '.backup.s3_secret_key_env' 'FICUS_BACKUP_S3_SECRET_KEY')
BACKUP_PASSPHRASE_ENV=$(cfg_get '.backup.passphrase_env' 'FICUS_BACKUP_PASSPHRASE')
BACKUP_SCHEDULE=$(cfg_get '.backup.schedule' '03:15')
BACKUP_ONCALENDAR='' BACKUP_HOME_DIR=''
if [[ ${BACKUP_ENABLE} == true ]]; then
  [[ -n ${BACKUP_S3_ENDPOINT} ]] || die "config: backup.enabled requires backup.s3_endpoint"
  [[ -n ${BACKUP_S3_REGION} ]] || die "config: backup.enabled requires backup.s3_region"
  [[ -n ${BACKUP_S3_BUCKET} ]] || die "config: backup.enabled requires backup.s3_bucket"
  # A non-empty prefix is required, not just conventional: tau-backup.sh.tmpl's
  # 14-object retention window lists and deletes by this prefix — an empty
  # prefix would scope retention to the ENTIRE bucket, silently deleting any
  # unrelated object that happens to match the <YYYY-MM-DD>.tar.gz.enc shape.
  [[ -n ${BACKUP_S3_PREFIX} ]] || die "config: backup.enabled requires a non-empty backup.s3_prefix (an empty prefix would scope retention deletes to the whole bucket)"
  BACKUP_ONCALENDAR=$(backup_oncalendar_from_schedule "${BACKUP_SCHEDULE}")

  # HOME_DIR resolution — MUST match what apps/core itself resolves
  # (process.env.HOME_DIR || join(os.homedir(), '.tau'), see
  # apps/core/src/lib/utils/home.ts). core.env can pass an explicit HOME_DIR
  # through to <dest>/.env (it's not one of the built-ins core.env is
  # forbidden from overriding), so honor that override first; otherwise
  # derive it deterministically from core.run_user's actual home directory
  # (NOT the setup-invoking user's — the services run as RUN_USER, and that
  # is whose os.homedir() the app process sees).
  _backup_core_env_home_dir=''
  while IFS= read -r _backup_env_line; do
    [[ ${_backup_env_line} == HOME_DIR=* ]] && _backup_core_env_home_dir=${_backup_env_line#HOME_DIR=}
  done <<<"${CORE_ENV_PAIRS}"
  if [[ -n ${_backup_core_env_home_dir} ]]; then
    BACKUP_HOME_DIR=${_backup_core_env_home_dir}
  else
    _backup_run_user_home=''
    if have getent; then
      _backup_run_user_home=$(getent passwd "${RUN_USER}" 2>/dev/null | cut -d: -f6)
    fi
    if [[ -z ${_backup_run_user_home} && ${RUN_USER} == "$(id -un)" ]]; then
      _backup_run_user_home=${HOME}
    fi
    [[ -n ${_backup_run_user_home} ]] ||
      die "config: backup.enabled could not resolve core.run_user '${RUN_USER}''s home directory to derive HOME_DIR — set it explicitly via core.env.HOME_DIR"
    BACKUP_HOME_DIR="${_backup_run_user_home}/.tau"
  fi
  unset _backup_core_env_home_dir _backup_env_line _backup_run_user_home
fi

# Optional restore-from-backup (cloud control plane only). When
# FICUS_SETUP_RESTORE_URL is set, phase_restore (between the database and env
# phases) downloads that presigned archive, decrypts it with
# $FICUS_SETUP_RESTORE_PASSPHRASE, pg_restores the dump, lays down the workspace
# tree, and carries the archived FICUS_ENCRYPTION_KEY forward. All three arrive
# as forwarded env vars (provision.sh's FORWARD_ENVS), never in the yaml — the
# URL and passphrase are credentials. RESTORE_PASSPHRASE is deliberately NOT
# captured into a global here: phase_restore reads it straight from the
# environment into a 0600 passfile, minimizing its exposure window.
RESTORE_URL=${FICUS_SETUP_RESTORE_URL:-}
RESTORE_STRIP_CREDENTIALS=${FICUS_SETUP_RESTORE_STRIP_CREDENTIALS:-0}

DB_MODE=$(cfg_get '.database.mode' 'container')
DB_DSN_CFG=${FICUS_SETUP_DATABASE_DSN:-$(cfg_get '.database.dsn')}
# CA certificate for an external postgres, on THIS host — provision.sh pushes
# it into <remote dir>/keys/ and rewrites this key to match, exactly like the
# origin cert. phase_database installs it at lib.sh's FICUS_DB_CA_PATH.
DB_CA_PATH=$(expand_tilde "$(cfg_get '.database.ca_path')")
# Platform-managed artifact STAGING DIRECTORY, on THIS host — provision.sh scp's
# it into <remote dir>/artifacts and rewrites this key to match, exactly like
# the database CA above. phase_artifacts installs its managed.env + files.
# Empty (the common case: a self-hosted install, or a platform tenant with no
# artifacts yet) makes phase_artifacts a no-op — byte-identical to a run that
# never had this key.
ARTIFACTS_DIR=$(expand_tilde "$(cfg_get '.artifacts.dir')")
DB_IMAGE='paradedb/paradedb:latest'
DB_CONTAINER='tau-postgres'
DB_VOLUME='tau-pgdata'
case "${DB_MODE}" in
  container) ;;
  external)
    [[ -n ${DB_DSN_CFG} ]] || die "config: database.mode=external needs database.dsn (or \$FICUS_SETUP_DATABASE_DSN)"
    # verify-full has no fallback: with no CA to verify against, EVERY
    # connection fails closed. Say so here, while it is still a config error
    # with an obvious fix, instead of letting it surface later as an opaque
    # TLS error from inside the app on an already-built host.
    if [[ ${DB_DSN_CFG} == *sslmode=verify-full* && -z ${DB_CA_PATH} ]]; then
      die "config: the database DSN asks for sslmode=verify-full but database.ca_path is unset — there is nothing to verify the server's certificate against"
    fi
    ;;
  *) die "config: database.mode must be container or external (got '${DB_MODE}')" ;;
esac

# runtime.sandbox is REQUIRED and explicit — there is no default and no
# auto-detection (the core itself refuses to start without FICUS_SANDBOX_RUNTIME),
# so a config that never chose one must fail here rather than silently install a
# runtime nobody picked.
# Trimmed at the read site: this value is compared against `vm` below AND
# written into the rendered .env verbatim, where ` vm ` would pass the core's
# (trimming) boot guard and then fail every isVmRuntime() comparison.
RT_SANDBOX=$(trim_ws "$(cfg_get '.runtime.sandbox')")
EXE_KEY_PATH=$(expand_tilde "$(cfg_get '.runtime.exe.ssh_key_path')")
EXE_IMAGE=$(cfg_get '.runtime.exe.machine_image' 'ghcr.io/ficushq/ficus-machine:latest')
require_sandbox_runtime "${RT_SANDBOX}"
# Under `host` there is no sandbox image to pin gh in, so agents run this
# machine's gh; warn (never abort) when it cannot serve `gh --attach`.
check_host_runtime_gh "${RT_SANDBOX}"
# Identity mapping: runtime.sandbox and FICUS_SANDBOX_RUNTIME name the same five
# values, so what the config chose is exactly what lands in the .env.
SANDBOX_RUNTIME_ENV=${RT_SANDBOX}

# Optional AI provider account + starter squad seeding (delegated to
# seed.sh in phase 7) — off unless ai.model is explicitly configured.
# Presence is probed on ai.model specifically, NOT ai.provider: ai.provider
# has a non-empty default of its own ('openai'), and ai.model is the field
# that was unconditionally required pre-change — so a config that sets ONLY
# ai.model (relying on the provider default) must still opt in. A config
# with no ai.model provisions cleanly and seeds nothing; self-hosters who
# want the toolkit to seed a provider key + starter squad opt in by
# supplying ai.model (the in-app onboarding checklist is the path for
# everyone else — see
# docs/history/superpowers/specs/2026-08-05-onboarding-checklist-design.md).
AI_MODEL=$(cfg_get '.ai.model' '')
AI_SECTION_PRESENT=0
[[ -n ${AI_MODEL} ]] && AI_SECTION_PRESENT=1

AI_PROVIDER=$(cfg_get '.ai.provider' 'openai')
case "${AI_PROVIDER}" in
  openai)
    AI_KEY_ENV_DEFAULT='OPENAI_API_KEY'
    AI_KEY_TARGET='OPENAI_API_KEY'
    ;;
  anthropic)
    AI_KEY_ENV_DEFAULT='ANTHROPIC_API_KEY'
    AI_KEY_TARGET='ANTHROPIC_API_KEY'
    ;;
  openai-codex)
    AI_KEY_ENV_DEFAULT=''
    AI_KEY_TARGET=''
    ;;
  *) die "config: ai.provider must be openai, anthropic, or openai-codex (got '${AI_PROVIDER}')" ;;
esac
AI_KEY_ENV=$(cfg_get '.ai.key_env' "${AI_KEY_ENV_DEFAULT}")
AGENT_MODEL=$(cfg_get '.squad.agent.model' "${AI_MODEL}")

if [[ ${AI_SECTION_PRESENT} -eq 1 ]]; then
  if [[ ${AI_PROVIDER} != openai-codex && (${AI_MODEL} == openai-codex:* || ${AGENT_MODEL} == openai-codex:*) ]]; then
    die "ai.model/squad.agent.model must match the seeded api-key provider '${AI_PROVIDER}' — an openai-codex:* model needs interactive OAuth and would leave the starter agent unable to run headless"
  fi
  if [[ ${AI_PROVIDER} == openai-codex && (${AI_MODEL} == openai:* || ${AGENT_MODEL} == openai:*) ]]; then
    die "openai and openai-codex are distinct auth namespaces; ai.model/squad.agent.model must match ai.provider '${AI_PROVIDER}'"
  fi
fi

SEC_ENC_ENV=$(cfg_get '.secrets.encryption_key_env')
SEC_PW_ENV=$(cfg_get '.secrets.password_env')

ENV_FILE="${SRC_DEST}/.env"

# ============================================================== secrets

# Values live only in shell variables and <dest>/.env (0600) — never in yaml.
FICUS_ENC_VALUE='' FICUS_PW_VALUE='' AI_KEY_VALUE='' DB_PASSWORD='' FICUS_EVENT_TOKEN_VALUE=''
ENC_SOURCE='' PW_SOURCE='' AI_KEY_SOURCE='' EVENT_TOKEN_SOURCE='' PW_GENERATED=0 DB_PW_RECOVERED=0
BACKUP_S3_ACCESS_KEY_VALUE='' BACKUP_S3_SECRET_KEY_VALUE='' BACKUP_PASSPHRASE_VALUE=''

valid_env_name() { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

resolve_secrets() {
  # FICUS_ENCRYPTION_KEY — encrypts the DB secret store; MUST be stable across
  # re-runs or the store becomes unreadable, so <dest>/.env wins over generate.
  if [[ -n ${SEC_ENC_ENV} ]] && valid_env_name "${SEC_ENC_ENV}" && [[ -n ${!SEC_ENC_ENV:-} ]]; then
    FICUS_ENC_VALUE=${!SEC_ENC_ENV}
    ENC_SOURCE="\$${SEC_ENC_ENV}"
  elif FICUS_ENC_VALUE=$(envfile_get "${ENV_FILE}" 'FICUS_ENCRYPTION_KEY') && [[ -n ${FICUS_ENC_VALUE} ]]; then
    ENC_SOURCE="existing ${ENV_FILE}"
  elif [[ ${DRY_RUN} -eq 1 ]]; then
    FICUS_ENC_VALUE='<generated-at-run-time>'
    ENC_SOURCE='generated (openssl rand -hex 32)'
  else
    FICUS_ENC_VALUE=$(gen_hex_secret 32)
    ENC_SOURCE='generated (openssl rand -hex 32)'
  fi

  # FICUS_PASSWORD — the bootstrap bearer; self-disables on first admin passkey.
  if [[ -n ${SEC_PW_ENV} ]] && valid_env_name "${SEC_PW_ENV}" && [[ -n ${!SEC_PW_ENV:-} ]]; then
    FICUS_PW_VALUE=${!SEC_PW_ENV}
    PW_SOURCE="\$${SEC_PW_ENV}"
  elif FICUS_PW_VALUE=$(envfile_get "${ENV_FILE}" 'FICUS_PASSWORD') && [[ -n ${FICUS_PW_VALUE} ]]; then
    PW_SOURCE="existing ${ENV_FILE}"
  elif [[ ${DRY_RUN} -eq 1 ]]; then
    FICUS_PW_VALUE='<generated-at-run-time>'
    PW_SOURCE='generated (openssl rand -hex 32)'
  else
    FICUS_PW_VALUE=$(gen_hex_secret 32)
    PW_SOURCE='generated (openssl rand -hex 32)'
    PW_GENERATED=1
  fi

  # FICUS_INTERNAL_EVENT_TOKEN — shared secret authenticating the loopback HTTP
  # event transport between tau-api and tau-worker (agent control signals,
  # event forwarding, secret invalidation). Both units read THIS .env, which is
  # what lets them agree on one value. Without it, both derive the token from
  # FICUS_ENCRYPTION_KEY; only if both are absent do random per-process tokens
  # make every cross-process post fail closed.
  # Unlike FICUS_ENCRYPTION_KEY, rotating it is harmless — both units restart
  # together — but preserving it keeps re-runs from churning the file.
  if FICUS_EVENT_TOKEN_VALUE=$(envfile_get "${ENV_FILE}" 'FICUS_INTERNAL_EVENT_TOKEN') && [[ -n ${FICUS_EVENT_TOKEN_VALUE} ]]; then
    EVENT_TOKEN_SOURCE="existing ${ENV_FILE}"
  elif [[ ${DRY_RUN} -eq 1 ]]; then
    FICUS_EVENT_TOKEN_VALUE='<generated-at-run-time>'
    EVENT_TOKEN_SOURCE='generated (openssl rand -hex 32)'
  else
    FICUS_EVENT_TOKEN_VALUE=$(gen_hex_secret 32)
    EVENT_TOKEN_SOURCE='generated (openssl rand -hex 32)'
  fi

  # AI provider API key — only when ai: is configured; fail fast for
  # unattended runs (headless setup REQUIRES an api-key provider;
  # openai-codex is OAuth-only and skipped).
  if [[ ${AI_SECTION_PRESENT} -eq 1 && ${AI_PROVIDER} != openai-codex ]]; then
    valid_env_name "${AI_KEY_ENV}" || die "config: ai.key_env ('${AI_KEY_ENV}') is not a valid env var name"
    AI_KEY_VALUE=${!AI_KEY_ENV:-}
    AI_KEY_SOURCE="\$${AI_KEY_ENV}"
    if [[ -z ${AI_KEY_VALUE} ]]; then
      if [[ ${DRY_RUN} -eq 1 ]]; then
        AI_KEY_VALUE='<supplied-at-run-time>'
        AI_KEY_SOURCE="\$${AI_KEY_ENV} (unset — would prompt on a TTY, else fail)"
      else
        prompt_value "API key for ${AI_PROVIDER} (\$${AI_KEY_ENV} unset)" AI_KEY_VALUE silent
        [[ -n ${AI_KEY_VALUE} ]] || die "no API key for ${AI_PROVIDER}: set \$${AI_KEY_ENV}"
        AI_KEY_SOURCE='prompt'
      fi
    fi
  fi

  # Backup S3 credentials + encryption passphrase — only when backup.enabled.
  # These never live in <dest>/.env (unlike the secrets above): they are
  # rendered into their own 0600 root-owned /etc/tau/backup.env by
  # phase_backup, so the tenant .env backed up nightly never itself carries
  # the credentials that can reach the backups.
  if [[ ${BACKUP_ENABLE} == true ]]; then
    valid_env_name "${BACKUP_S3_ACCESS_KEY_ENV}" || die "config: backup.s3_access_key_env ('${BACKUP_S3_ACCESS_KEY_ENV}') is not a valid env var name"
    valid_env_name "${BACKUP_S3_SECRET_KEY_ENV}" || die "config: backup.s3_secret_key_env ('${BACKUP_S3_SECRET_KEY_ENV}') is not a valid env var name"
    valid_env_name "${BACKUP_PASSPHRASE_ENV}" || die "config: backup.passphrase_env ('${BACKUP_PASSPHRASE_ENV}') is not a valid env var name"
    BACKUP_S3_ACCESS_KEY_VALUE=${!BACKUP_S3_ACCESS_KEY_ENV:-}
    BACKUP_S3_SECRET_KEY_VALUE=${!BACKUP_S3_SECRET_KEY_ENV:-}
    BACKUP_PASSPHRASE_VALUE=${!BACKUP_PASSPHRASE_ENV:-}
    if [[ ${DRY_RUN} -eq 1 ]]; then
      [[ -n ${BACKUP_S3_ACCESS_KEY_VALUE} ]] || BACKUP_S3_ACCESS_KEY_VALUE='<supplied-at-run-time>'
      [[ -n ${BACKUP_S3_SECRET_KEY_VALUE} ]] || BACKUP_S3_SECRET_KEY_VALUE='<supplied-at-run-time>'
      [[ -n ${BACKUP_PASSPHRASE_VALUE} ]] || BACKUP_PASSPHRASE_VALUE='<supplied-at-run-time>'
    else
      [[ -n ${BACKUP_S3_ACCESS_KEY_VALUE} ]] ||
        prompt_value "S3 access key for backups (\$${BACKUP_S3_ACCESS_KEY_ENV} unset)" BACKUP_S3_ACCESS_KEY_VALUE silent
      [[ -n ${BACKUP_S3_SECRET_KEY_VALUE} ]] ||
        prompt_value "S3 secret key for backups (\$${BACKUP_S3_SECRET_KEY_ENV} unset)" BACKUP_S3_SECRET_KEY_VALUE silent
      [[ -n ${BACKUP_PASSPHRASE_VALUE} ]] ||
        prompt_value "encryption passphrase for backups (\$${BACKUP_PASSPHRASE_ENV} unset)" BACKUP_PASSPHRASE_VALUE silent
      [[ -n ${BACKUP_S3_ACCESS_KEY_VALUE} && -n ${BACKUP_S3_SECRET_KEY_VALUE} && -n ${BACKUP_PASSPHRASE_VALUE} ]] ||
        die "backup.enabled requires an S3 access key, secret key, and passphrase — set \$${BACKUP_S3_ACCESS_KEY_ENV}/\$${BACKUP_S3_SECRET_KEY_ENV}/\$${BACKUP_PASSPHRASE_ENV} (or supply them at a TTY prompt)"
    fi
  fi

  # Local DB container password — recover from existing .env so a re-run keeps
  # talking to the existing container.
  if [[ ${DB_MODE} == container ]]; then
    local existing_dsn=''
    existing_dsn=$(envfile_get "${ENV_FILE}" 'DATABASE_URL' || true)
    if [[ ${existing_dsn} =~ ^postgres://postgres:([^@]+)@ ]]; then
      DB_PASSWORD=${BASH_REMATCH[1]}
      DB_PW_RECOVERED=1
    elif [[ ${DRY_RUN} -eq 1 ]]; then
      DB_PASSWORD='<generated-at-run-time>'
    else
      DB_PASSWORD=$(gen_hex_secret 16)
    fi
  fi
}

resolve_secrets

# On a restore, FICUS_ENCRYPTION_KEY is carried forward from the archived .env
# rather than generated (otherwise every encrypted secret in the restored DB
# is undecryptable). The real-run override happens in phase_restore, before
# phase_env renders the file; here we only fix up the dry-run PLAN so it
# reflects the true source. Gated on RESTORE_URL so a non-restore config's
# dry-run output stays byte-for-byte identical.
if [[ -n ${RESTORE_URL} && ${DRY_RUN} -eq 1 ]]; then
  FICUS_ENC_VALUE='<carried from restored backup>'
  ENC_SOURCE='restored backup envelope (extracted at run time)'
fi

db_dsn() {
  if [[ ${DB_MODE} == container ]]; then
    printf 'postgres://postgres:%s@127.0.0.1:5432/tau' "$1" # $1 = password (real or redacted)
  else
    printf '%s' "${DB_DSN_CFG}"
  fi
}

# ============================================================== rendering

# Dry-run placeholders like <generated-at-run-time> are not secrets — show
# them verbatim instead of "redacting" them.
redact_unless_placeholder() {
  if [[ $1 == '<'*'>' ]]; then printf '%s' "$1"; else redact_secret "$1"; fi
}

build_env_content() { # redact|real
  local mode=$1 enc pw key tok dsn core_env
  if [[ ${mode} == redact ]]; then
    enc=$(redact_unless_placeholder "${FICUS_ENC_VALUE}")
    pw=$(redact_unless_placeholder "${FICUS_PW_VALUE}")
    key=$(redact_unless_placeholder "${AI_KEY_VALUE}")
    tok=$(redact_unless_placeholder "${FICUS_EVENT_TOKEN_VALUE}")
    dsn=$(db_dsn '<redacted>')
    [[ ${DB_MODE} == external ]] && dsn='<external dsn, redacted>'
    # *_ENV-indirected core.env values are secrets — redact them too. Literal
    # entries are re-resolved identically either way (cfg_env_pairs redact
    # only changes *_ENV rendering), so this is just CORE_ENV_PAIRS redacted.
    core_env=$(cfg_env_pairs '.core.env' redact)
  else
    enc=${FICUS_ENC_VALUE} pw=${FICUS_PW_VALUE} key=${AI_KEY_VALUE} tok=${FICUS_EVENT_TOKEN_VALUE}
    dsn=$(db_dsn "${DB_PASSWORD}")
    core_env=${CORE_ENV_PAIRS}
  fi
  cat <<EOF
# Generated by scripts/setup/setup-host.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# Re-running setup-host.sh overwrites this file (secret values are preserved).
DATABASE_URL=${dsn}
# Bind IPv4 loopback EXPLICITLY. apps/core defaults to 'localhost', which on
# Ubuntu resolves to IPv6 ::1 first — so the core listened on [::1]:3000 while
# BOTH the health probe (api_health_ok) and caddy's reverse_proxy dial
# 127.0.0.1, and got connection-refused. That made a perfectly healthy core
# fail provisioning with "core API failed to start", and would have surfaced
# again as a 502 through caddy. Setting it here makes the bind deterministic
# instead of dependent on /etc/hosts resolution order, and matches what
# everything downstream already assumes.
HOST=127.0.0.1
PORT=${CORE_PORT}
FICUS_API_URL=http://127.0.0.1:${CORE_PORT}
# APP_URL and FICUS_WEB_ORIGIN MUST equal the exact browser-facing origin
# (scheme://host[:port], no path) or WebAuthn passkey registration fails.
APP_URL=${CORE_ORIGIN}
FICUS_WEB_ORIGIN=${CORE_ORIGIN}
FICUS_ENCRYPTION_KEY=${enc}
# Bootstrap bearer — fully privileged ONLY until the first admin passkey
# exists, then it self-disables.
FICUS_PASSWORD=${pw}
# tau-api and tau-worker exchange events over authenticated HTTP instead of pg
# LISTEN/NOTIFY. The worker binds loopback by default; supported split-namespace
# deployments may override it to a private interface. The token authenticates
# BOTH directions and MUST be identical in both units, which is
# why it lives in this shared EnvironmentFile. Override the port via core.env
# if 3003 is already taken on this host.
FICUS_WORKER_EVENT_PORT=3003
FICUS_INTERNAL_EVENT_TOKEN=${tok}
FICUS_SANDBOX_RUNTIME=${SANDBOX_RUNTIME_ENV}
FICUS_SYSTEM_LOG_PROVIDER=systemd
FICUS_SERVE_WEB=${CORE_SERVE_WEB}
EOF
  if [[ ${RT_SANDBOX} == vm ]]; then
    printf 'FICUS_EXE_MACHINE_IMAGE=%s\n' "${EXE_IMAGE}"
  fi
  if [[ -n ${AI_KEY_TARGET} && -n ${AI_KEY_VALUE} ]]; then
    printf '# Provider key (also seeded into the encrypted store via the API).\n'
    printf '%s=%s\n' "${AI_KEY_TARGET}" "${key}"
  fi
  if [[ -n ${core_env} ]]; then
    printf '# core.env passthrough (operator/control-plane env knobs; see tau-setup.example.yaml).\n'
    printf '%s\n' "${core_env}"
  fi
}

# The core units are rendered and installed by lib.sh's render_core_unit /
# install_core_units — shared verbatim with upgrade-host.sh's artifact mode,
# so a provision and an upgrade can never disagree about what the unit says.
# They read SRC_DEST / RUN_USER / BUN_BIN / DB_MODE as caller globals, exactly
# as this script's other lib.sh calls do.

# BACKUP_SCRIPT_PATH / BACKUP_ENV_TARGET and the template render itself live
# in lib.sh, shared with retarget-backup.sh (which re-renders a live host's
# backup target without re-running this script).
render_backup_script() {
  render_backup_script_content "${SCRIPT_DIR}/tau-backup.sh.tmpl" \
    "${SRC_DEST}" "${BACKUP_HOME_DIR}" "${DB_MODE}" "${DB_CONTAINER}" \
    "${BACKUP_S3_ENDPOINT}" "${BACKUP_S3_REGION}" "${BACKUP_S3_BUCKET}" "${BACKUP_S3_PREFIX}" \
    "${BACKUP_ENV_TARGET}"
}

render_backup_unit() { # TEMPLATE_FILE
  local db_after=''
  [[ ${DB_MODE} == container ]] && db_after=' docker.service'
  sed -e "s|@SCRIPT_PATH@|${BACKUP_SCRIPT_PATH}|g" \
    -e "s|@ONCALENDAR@|${BACKUP_ONCALENDAR}|g" \
    -e "s|@DB_AFTER@|${db_after}|g" \
    "$1"
}

# The self-updater (apps/core/src/services/updates) restarts the services after a
# git-diff-driven rebuild via `systemctl restart tau-api`/`tau-worker`. When the
# services run as a non-root RUN_USER it shells out with `sudo -n`, which refuses
# to prompt — so without a NOPASSWD rule the restart step fails and every update
# is recorded as failed. Root installs restart directly and need no rule. The
# grant is scoped to exactly these two commands (no wildcards).
UPDATE_SUDOERS_FILE='/etc/sudoers.d/tau-update'
update_sudoers_content() {
  printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl restart tau-api, /usr/bin/systemctl restart tau-worker\n' "${RUN_USER}"
}

install_update_sudoers() {
  local tmp
  tmp=$(mktemp)
  update_sudoers_content >"${tmp}"
  if as_root sh -c 'command -v visudo >/dev/null 2>&1'; then
    as_root visudo -cf "${tmp}" >/dev/null || {
      rm -f "${tmp}"
      die "generated sudoers rule failed visudo validation — refusing to install ${UPDATE_SUDOERS_FILE}"
    }
  fi
  as_root install -m 0440 -o root -g root "${tmp}" "${UPDATE_SUDOERS_FILE}"
  rm -f "${tmp}"
  log_info "installed ${UPDATE_SUDOERS_FILE} (NOPASSWD systemctl restart tau-api/tau-worker for ${RUN_USER})"
}

# ============================================================== dry run

if [[ ${DRY_RUN} -eq 1 ]]; then
  log_step "DRY RUN — printing the plan; nothing will be executed or modified"
  printf '\nPhase 0 — preflight\n'
  plan "assert: Linux + systemd (PID 1) + Ubuntu 24.04 (override: FICUS_SETUP_SKIP_OS_CHECK=1)"
  if [[ ${SRC_MODE} == artifact ]]; then
    plan "ensure: curl jq openssl ca-certificates (apt; git dropped — artifact mode never clones), mikefarah yq v4, bun (official installer)"
  else
    plan "ensure: git curl jq openssl ca-certificates (apt), mikefarah yq v4, bun (official installer)"
  fi
  [[ ${DB_MODE} == container ]] && plan "ensure: docker (apt docker.io if missing; unmask if the image masks rootful docker)"
  [[ ${DB_MODE} == external ]] && plan "ensure: pg_dump via PGDG postgresql-client (latest major — Ubuntu's v16 cannot dump the managed cluster's v18; needed by the nightly backup timer)"
  printf '\nPhase 1 — source (%s)\n' "${SRC_MODE}"
  case "${SRC_MODE}" in
    git-ssh)
      plan "GIT_SSH_COMMAND='ssh -i ${SRC_DEPLOY_KEY:-<deploy key — would prompt>} -o IdentitiesOnly=yes -o IdentityAgent=none'"
      plan "clone ${SRC_REPO} @ ${SRC_REF} → ${SRC_DEST} (idempotent: fetch + checkout if it already exists)"
      ;;
    git-https)
      plan "clone https with token from \$GH_TOKEN ($(redact_secret "${GH_TOKEN:-}")) → ${SRC_DEST} via a GIT_ASKPASS helper (token never in git argv); remote URL is reset to the token-less URL after clone"
      plan "repo ${SRC_REPO} @ ${SRC_REF} (idempotent: fetch + checkout if it already exists)"
      ;;
    artifact)
      # Never the URL VALUES — they are presigned GET credentials borne by
      # the environment, not the config file. Only the env var NAMES appear.
      plan "download + verify: FICUS_ARTIFACT_TARBALL_URL / FICUS_ARTIFACT_MANIFEST_URL / FICUS_ARTIFACT_SIG_URL (presigned GET URLs, env-borne — values never printed) against FICUS_ARTIFACT_PUBKEY_B64 (Ed25519 signature)"
      plan "stage the verified release under ${SRC_DEST}/releases/<sha>-<digest12> (idempotent: re-verifies and re-stages on re-run)"
      ;;
  esac
  [[ ${SRC_MODE} != artifact ]] && plan "git clone avoids macOS AppleDouble '._*' files entirely (they crash config-sync YAML parsing)"
  printf '\nPhase 2 — deps + build\n'
  if [[ ${SRC_MODE} == artifact ]]; then
    plan "prebuilt artifact — nothing to build (dist/index.js, dist/worker.js and apps/web/dist ship inside the staged release)"
  else
    plan "bun install --ignore-scripts   # skips the root postinstall (submodules + extensions)"
    plan "bun run extensions:install     # the root postinstall step we still need"
    plan "(cd apps/core && bun run build)  → dist/index.js + dist/worker.js"
    [[ ${CORE_SERVE_WEB} == true ]] && plan "bun run build:web  → apps/web/dist (served by core, FICUS_SERVE_WEB)"
  fi
  printf '\nPhase 3 — database (%s)\n' "${DB_MODE}"
  if [[ ${DB_MODE} == container ]]; then
    plan "unmask+start docker if needed (ficus-machine masks rootful docker for BOX security; the core host is not a box host)"
    plan "docker run -d --name ${DB_CONTAINER} --restart unless-stopped -p 127.0.0.1:5432:5432 -v ${DB_VOLUME}:/var/lib/postgresql ${DB_IMAGE}"
    plan "wait: pg_isready; ensure database 'tau' exists (reuses container + password from ${ENV_FILE} on re-run)"
  else
    [[ -n ${DB_CA_PATH} ]] &&
      plan "install ${DB_CA_PATH} → ${FICUS_DB_CA_PATH} (0644 root; a CA certificate is public, and the app/worker/pg_dump all read it)"
    plan "use external DSN from config/\$FICUS_SETUP_DATABASE_DSN; TCP-probe host before migrating"
  fi
  if [[ -n ${RESTORE_URL} ]]; then
    printf '\nPhase 3.5 — restore from backup\n'
    # NEVER print the URL's query string — for a presigned S3 GET it is the
    # credential. Everything after '?' is stripped.
    plan "download the encrypted backup from ${RESTORE_URL%%\?*} (presigned GET; query string omitted — it is a credential)"
    plan "decrypt (openssl aes-256-cbc/pbkdf2, passphrase via \$FICUS_SETUP_RESTORE_PASSPHRASE, never argv) + untar to a 0700 temp dir"
    plan "pg_restore --clean --if-exists --no-owner the db.dump into the tenant database — BEFORE the migrate phase, which then fast-forwards if the code is newer"
    plan "unpack the archived HOME_DIR tree into ${BACKUP_HOME_DIR:-<run_user home>/.tau} (before services start)"
    plan "carry FICUS_ENCRYPTION_KEY forward from the archived .env (else the restored DB's encrypted secrets are unreadable)"
    [[ ${RESTORE_STRIP_CREDENTIALS} == 1 ]] &&
      plan "cross-subdomain restore: DELETE FROM user_credentials (WebAuthn passkeys are origin-bound; users are kept)"
    plan "temp dir + downloaded archive are removed regardless of outcome; any failure dies (a half-restored instance fails the provision)"
  fi
  printf '\nPhase 4 — %s (umask 077; secrets redacted below)\n' "${ENV_FILE}"
  plan "FICUS_ENCRYPTION_KEY from: ${ENC_SOURCE}"
  plan "FICUS_PASSWORD (bootstrap bearer) from: ${PW_SOURCE}"
  plan "FICUS_INTERNAL_EVENT_TOKEN (api↔worker event transport) from: ${EVENT_TOKEN_SOURCE}"
  [[ ${AI_SECTION_PRESENT} -eq 1 && ${AI_PROVIDER} != openai-codex ]] && plan "AI provider key from: ${AI_KEY_SOURCE}"
  build_env_content redact | sed 's/^/  | /'
  printf '\nPhase 5 — migrate\n'
  if [[ ${SRC_MODE} == artifact ]]; then
    plan "migrations run inside artifact_activate (phase 6) — nothing to do here"
  else
    plan "(cd ${SRC_DEST}/apps/core && bun run db:migrate)"
  fi
  if [[ -n ${ARTIFACTS_DIR} ]]; then
    printf '\nPhase 5.5 — platform-managed artifacts (from %s)\n' "${ARTIFACTS_DIR}"
    if [[ -f ${ARTIFACTS_DIR}/managed.env ]]; then
      plan "install managed.env → ${FICUS_MANAGED_ENV_PATH} (0600 root; env credential VALUES never printed)"
    fi
    if [[ -f ${ARTIFACTS_DIR}/manifest ]]; then
      plan "install files → ${FICUS_ARTIFACTS_DIR}/ per manifest (modes + names below; file CONTENTS never printed):"
      sed 's/^/  | /' "${ARTIFACTS_DIR}/manifest"
    fi
  fi
  printf '\nPhase 6 — systemd services\n'
  [[ ${RUN_USER} != "$(id -un)" ]] && plan "preflight: run_user '${RUN_USER}' exists AND can execute the resolved bun binary (fails fast with instructions otherwise)"
  for unit in tau-api tau-worker; do
    plan "install /etc/systemd/system/${unit}.service:"
    render_core_unit "${SCRIPT_DIR}/systemd/${unit}.service.tmpl" | sed 's/^/  | /'
  done
  if [[ ${RUN_USER} != root ]]; then
    plan "install ${UPDATE_SUDOERS_FILE} (0440, visudo-validated) so the self-updater can restart non-root services:"
    update_sudoers_content | sed 's/^/  | /'
  fi
  plan "systemctl daemon-reload && enable tau-api tau-worker"
  if [[ ${SRC_MODE} == artifact ]]; then
    plan "artifact_activate ${SRC_DEST} <release_dir> ${CORE_PORT}: migrate → flip ${SRC_DEST}/current → restart → health-check (auto-rollback on a failed check; no rollback target on a fresh box)"
    plan "artifact_retention ${SRC_DEST}: prune old releases"
  else
    plan "restart; wait for GET /health → 401/200 (journald tail on failure)"
    plan "worker: wait active, then require NRestarts to hold still for 8s (crash-loop guard; journald tail on failure)"
  fi
  if [[ ${CADDY_ENABLE} == true ]]; then
    printf '\nPhase 6.5 — caddy ingress (%s)\n' "${CADDY_HOST}"
    plan "install caddy from the official cloudsmith apt repo if absent"
    # Only PATHS are printed here — the private key's contents never appear in
    # a plan, a log line, or the rendered Caddyfile.
    plan "install ${CADDY_CERT_PATH} → ${CADDY_TLS_CERT_PATH} (0644 root) and ${CADDY_KEY_PATH} → ${CADDY_TLS_KEY_PATH} (0600 caddy-owned; contents never printed)"
    plan "no ACME, no port 80: TLS is the supplied Cloudflare Origin CA certificate (requires a PROXIED DNS record)"
    plan "write ${CADDYFILE_PATH} (idempotent: rewrite + reload, never restart, only on content change):"
    render_caddyfile "${CADDY_HOST}" "${CORE_PORT}" "${CADDY_TLS_CERT_PATH}" "${CADDY_TLS_KEY_PATH}" | sed 's/^/  | /'
    plan "systemctl enable --now caddy"
  fi
  if [[ ${BACKUP_ENABLE} == true ]]; then
    printf '\nPhase 6.6 — nightly encrypted backup (S3 prefix %s)\n' "${BACKUP_S3_PREFIX:-<none>}"
    plan "HOME_DIR resolved to: ${BACKUP_HOME_DIR}"
    plan "render ${BACKUP_SCRIPT_PATH} from tau-backup.sh.tmpl (dest=${SRC_DEST}, db.mode=${DB_MODE}, s3=${BACKUP_S3_ENDPOINT}/${BACKUP_S3_BUCKET})"
    plan "write ${BACKUP_ENV_TARGET} (0600 root-owned; secrets redacted below):"
    render_backup_env_content redact "${BACKUP_S3_ACCESS_KEY_VALUE}" "${BACKUP_S3_SECRET_KEY_VALUE}" "${BACKUP_PASSPHRASE_VALUE}" | sed 's/^/  | /'
    plan "install tau-backup.service + tau-backup.timer (OnCalendar=${BACKUP_ONCALENDAR}):"
    render_backup_unit "${SCRIPT_DIR}/systemd/tau-backup.timer.tmpl" | sed 's/^/  | /'
    plan "systemctl daemon-reload && enable --now tau-backup.timer"
  fi
  printf '\nPhase 7 — seed (delegated to seed.sh)\n'
  bash "${SCRIPT_DIR}/seed.sh" --config "${CFG_FILE}" --env-file "${ENV_FILE}" --api-url "http://127.0.0.1:${CORE_PORT}" --dry-run
  printf '\nPhase 8 — report\n'
  plan "assert GET /api/auth/status → {mode: password, hasAdminUser: false, emailConfigured: false} (warn if email IS configured — code is emailed, not shown inline)"
  plan "print ${CORE_ORIGIN} + 'create your first admin passkey' handoff"
  plan "bootstrap token: ${PW_SOURCE} — self-disables when the first admin passkey is created"
  exit 0
fi

# ============================================================== phases

phase_preflight() {
  phase_step preflight "phase 0/8: preflight"
  [[ $(uname -s) == Linux ]] || die "setup-host.sh runs ON the Linux target — from a control machine use provision.sh"
  [[ -d /run/systemd/system ]] || die "systemd is required (is this a container?)"
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
      if [[ ${FICUS_SETUP_SKIP_OS_CHECK:-0} == 1 ]]; then
        log_warn "untested OS ${ID:-?} ${VERSION_ID:-?} (expected Ubuntu 24.04) — continuing per FICUS_SETUP_SKIP_OS_CHECK=1"
      else
        die "expected Ubuntu 24.04, found ${ID:-?} ${VERSION_ID:-?} (set FICUS_SETUP_SKIP_OS_CHECK=1 to try anyway)"
      fi
    fi
  fi
  require_root_capability

  local missing=()
  local pkg
  # unzip is NOT optional: bun's official installer unpacks a .zip and aborts
  # with "unzip is required to install bun". Ubuntu 24.04 server images do not
  # ship it, so a fresh TENANT VM dies in preflight. The identical bug was
  # fixed in setup-platform.sh first; this script has its own package list and
  # needed the same fix — observed on the first real tenant provision.
  #
  # git is dropped in artifact mode: an artifact box never clones anything —
  # phase_source downloads a signed tarball over curl and verifies it with
  # openssl — so requiring git would fail a fresh tenant VM on a package it
  # never uses.
  local required_pkgs=(git curl jq openssl unzip)
  [[ ${SRC_MODE} == artifact ]] && required_pkgs=(curl jq openssl unzip)
  for pkg in "${required_pkgs[@]}"; do
    have "${pkg}" || missing+=("${pkg}")
  done

  # Make every apt call on this host wait for the dpkg lock instead of dying
  # with exit 100. Fresh cloud VMs run unattended-upgrades on first boot, and
  # provisioning reaches this phase within ~2 minutes of VM creation — both
  # observed scratch-tenant provisions failed their FIRST attempt with
  # provision.sh exit 100 (apt's failure code) and succeeded on retry minutes
  # later, exactly the lock-release window. A config file (not per-call flags)
  # covers all 13 apt invocations across the toolkit in one place.
  printf 'DPkg::Lock::Timeout "120";\n' |
    as_root tee /etc/apt/apt.conf.d/99tau-lock-timeout >/dev/null

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "installing missing packages: ${missing[*]}"
    as_root apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates
  fi

  # Must precede the build phase — see ensure_swapfile's comment for why a
  # 2GB tenant VM cannot bundle the web app without it.
  ensure_swapfile

  # Shared with upgrade-host.sh so the two paths cannot disagree about where
  # bun lives; only setup falls through to installing it.
  bun_path_prepend
  # PINNED, and reinstalled on version mismatch — never "latest", and never
  # "whatever is already there". An unpinned install took down provisioning
  # for every new tenant on 2026-08-13: bun 1.3.14 broke .env loading for
  # `bun run db:migrate` ("DATABASE_URL environment variable is required" on
  # a correctly configured host). The mismatch reinstall matters as much as
  # the pin: a VM that already got a broken bun skips `! have bun` forever.
  # `.bun-version` is the single source of truth. When this script runs from a
  # checkout (it and .bun-version travel together), read the pinned value from
  # it so the two can never diverge. The literal below is a fallback for the
  # (pathological) no-checkout case AND the anchor the bun-version gate keeps in
  # lockstep with .bun-version — enforced by .github/bun-version-gate.test.ts.
  FICUS_BUN_VERSION="1.4.2"
  # Unquoted final assignment (`=${var}`, not `="…"`) on purpose: the gate
  # matches the single literal pin above via `^\s*FICUS_BUN_VERSION="…"`, and a
  # second quoted assignment here would register as a divergent pin.
  _tau_bun_version_file="${SCRIPT_DIR}/../../.bun-version"
  if [[ -f "${_tau_bun_version_file}" ]]; then
    _tau_bun_version_pinned=$(tr -d '[:space:]' <"${_tau_bun_version_file}")
    [[ -n "${_tau_bun_version_pinned}" ]] && FICUS_BUN_VERSION=${_tau_bun_version_pinned}
  fi
  if have bun && [[ "$(bun --version)" != "${FICUS_BUN_VERSION}" ]]; then
    log_info "bun $(bun --version) does not match pinned ${FICUS_BUN_VERSION} — reinstalling"
  fi
  if ! have bun || [[ "$(bun --version)" != "${FICUS_BUN_VERSION}" ]]; then
    log_info "installing bun ${FICUS_BUN_VERSION} (official installer, pinned)"
    curl -fsSL https://bun.sh/install | bash -s "bun-v${FICUS_BUN_VERSION}"
    export BUN_INSTALL="${HOME}/.bun"
    export PATH="${BUN_INSTALL}/bin:${PATH}"
  fi
  require_cmd bun "bun install failed — check network access to bun.sh"
  if [[ "$(bun --version)" != "${FICUS_BUN_VERSION}" ]]; then
    die "bun version $(bun --version) still does not match pinned ${FICUS_BUN_VERSION} after install"
  fi
  log_info "bun: $(command -v bun) ($(bun --version))"
  id -u "${RUN_USER}" >/dev/null 2>&1 ||
    die "core.run_user '${RUN_USER}' does not exist on this host — create it first (useradd) or leave core.run_user empty"
  ensure_system_bun_node "${RUN_USER}" "$(command -v bun)"

  if [[ ${DB_MODE} == container ]] && ! have docker; then
    log_info "installing docker (docker.io) for the local database container"
    as_root apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
  fi

  # External mode needs pg_dump for the nightly backup timer — and it must
  # come from PGDG, not Ubuntu. Observed on the first live tenant: the timer
  # fired with no pg_dump installed at all, and Ubuntu 24.04's packaged
  # client is v16 while the managed cluster runs v18 — pg_dump only dumps
  # servers up to its own major, so the distro package would fail anyway.
  # PGDG's `postgresql-client` metapackage tracks the newest major, and a
  # newer pg_dump handles older servers fine, so latest is the robust pick.
  # Installed here at setup time, not discovered at 03:15 by a failing timer.
  if [[ ${DB_MODE} == external ]] && ! have pg_dump; then
    log_info "installing postgresql-client (PGDG) for the backup timer's pg_dump"
    as_root install -d /usr/share/postgresql-common/pgdg
    curl -fsS -o /tmp/pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
    as_root install -m 0644 /tmp/pgdg.asc /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    rm -f /tmp/pgdg.asc
    install_rendered 0644 root root /etc/apt/sources.list.d/pgdg.list \
      printf 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' \
      "$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"
    as_root apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client
    require_cmd pg_dump "postgresql-client install failed — the nightly backup cannot run without pg_dump"
    log_info "pg_dump: $(pg_dump --version)"
  fi

  if [[ ${SRC_MODE} == git-ssh ]]; then
    if [[ -z ${SRC_DEPLOY_KEY} ]]; then
      prompt_value "path to the git deploy key (source.deploy_key_path unset)" SRC_DEPLOY_KEY
    fi
    SRC_DEPLOY_KEY=$(expand_tilde "${SRC_DEPLOY_KEY}")
    [[ -f ${SRC_DEPLOY_KEY} ]] || die "deploy key not found: ${SRC_DEPLOY_KEY}"
    chmod 600 "${SRC_DEPLOY_KEY}" 2>/dev/null || true
  fi

  if [[ ${RT_SANDBOX} == vm ]]; then
    EXE_KEY_PATH=$(resolve_exe_key_path "${RT_SANDBOX}" "${EXE_KEY_PATH}" \
      "path to the exe.dev account SSH key (runtime.exe.ssh_key_path unset)")
    [[ -z ${EXE_KEY_PATH} || -f ${EXE_KEY_PATH} ]] || die "exe SSH key not found: ${EXE_KEY_PATH}"
  fi

  # Fail here, not in phase 6.5: a missing certificate would otherwise surface
  # only after the services are already up and the host has been mutated.
  if [[ ${CADDY_ENABLE} == true ]]; then
    [[ -f ${CADDY_CERT_PATH} ]] || die "ingress.tls_cert_path: certificate not found: ${CADDY_CERT_PATH}"
    [[ -f ${CADDY_KEY_PATH} ]] || die "ingress.tls_key_path: private key not found: ${CADDY_KEY_PATH}"
    chmod 600 "${CADDY_KEY_PATH}" 2>/dev/null || true
  fi

  # Same reasoning for the external-database CA: without it a verify-full DSN
  # cannot connect at all, so catch it before phase 3 mutates anything.
  if [[ -n ${DB_CA_PATH} ]]; then
    [[ -f ${DB_CA_PATH} ]] || die "database.ca_path: CA certificate not found: ${DB_CA_PATH}"
  fi
}

# --- source acquisition (SWAPPABLE: git-ssh | git-https | artifact) ----------
#
# git_env_setup / git_source_sync live in lib.sh: setup-platform.sh clones the
# very same repo the very same way (git-https + GH_TOKEN) onto the control
# plane, and duplicating a token-handling routine is exactly the sort of thing
# that drifts. Only `artifact` (a tenant-only seam) stays here.

phase_source() {
  phase_step source "phase 1/8: source acquisition (${SRC_MODE}) → ${SRC_DEST}"
  if [[ ${SRC_MODE} == artifact ]]; then
    local acq='' rc=0 sha digest12 tree

    # git_source_sync does this same dest-creation for git mode
    # (lib.sh ~1832) — artifact mode needs it too, and for the identical
    # reason: on the default exe provider the ssh_user (e.g. exedev) cannot
    # create /opt/tau-core, and artifact_acquire's first writes (the
    # incoming/ staging dir) are unprivileged. Skipping this here would die
    # deep inside artifact_acquire with a misleading "could not create an
    # incoming dir" instead of a clear one.
    if [[ ! -d ${SRC_DEST} ]]; then
      as_root mkdir -p "${SRC_DEST}"
      as_root chown "$(id -u):$(id -g)" "${SRC_DEST}"
    fi

    # The artifact public key is NOT a secret, but openssl needs it as a
    # file. 0600 + an EXIT trap so no exit path — including a die deep
    # inside the verify — leaves it behind.
    ARTIFACT_PUBKEY_FILE=$(mktemp)
    chmod 600 "${ARTIFACT_PUBKEY_FILE}"
    trap 'rm -f "${ARTIFACT_PUBKEY_FILE}"' EXIT
    printf '%s' "${FICUS_ARTIFACT_PUBKEY_B64}" | base64 -d >"${ARTIFACT_PUBKEY_FILE}" 2>/dev/null ||
      die "FICUS_ARTIFACT_PUBKEY_B64 is not valid base64"
    [[ -s ${ARTIFACT_PUBKEY_FILE} ]] || die "FICUS_ARTIFACT_PUBKEY_B64 decoded to an empty public key"

    # artifact_acquire EXITS (it does not return) on failure, printing its
    # reason token on stdout — so it has to be captured, and its status has
    # to be taken from the substitution. `local x=$(...)` would throw the
    # status away and read a failed, unverified acquire as success. This
    # matters MORE than it looks: bash does not set `inherit_errexit` here,
    # so `set -e` is suspended for the whole $(...) substitution — every
    # step inside artifact_acquire has to carry its own explicit
    # `|| _artifact_fail`/`|| die`, because a bare failing command in there
    # would NOT abort the substitution on its own.
    acq='' rc=0
    acq=$(artifact_acquire "${SRC_DEST}" "${FICUS_ARTIFACT_TARBALL_URL}" "${FICUS_ARTIFACT_MANIFEST_URL}" "${FICUS_ARTIFACT_SIG_URL}" "${ARTIFACT_PUBKEY_FILE}") || rc=$?
    if [[ ${rc} -ne 0 ]]; then
      # The FICUS_ARTIFACT_ERROR=<token> line went into ${acq}, not onto the
      # log stream — re-emit it or the control plane never learns why this
      # failed.
      printf '%s\n' "${acq}"
      die "artifact acquisition failed"
    fi
    sha=$(printf '%s\n' "${acq}" | sed -n 1p | awk '{print $1}')
    digest12=$(printf '%s\n' "${acq}" | sed -n 1p | awk '{print $2}')
    tree=$(printf '%s\n' "${acq}" | sed -n 2p)
    [[ ${sha} =~ ^[0-9a-f]{40}$ && ${digest12} =~ ^[0-9a-f]{12}$ && -d ${tree} ]] ||
      die "artifact_acquire returned an unusable result (sha='${sha}', digest12='${digest12}')"

    artifact_stage "${SRC_DEST}" "${tree}" "${sha}" "${digest12}"
    # Caller globals for phase_services (artifact_activate) and phase_report
    # (the release trailer).
    ARTIFACT_RELEASE_DIR=$(artifact_release_dir "${SRC_DEST}" "${sha}" "${digest12}")
    ARTIFACT_RELEASE_ID="${sha}-${digest12}"
  else
    git_source_sync
  fi
}

phase_build() {
  phase_step build "phase 2/8: dependencies + build"
  if [[ ${SRC_MODE} == artifact ]]; then
    log_info "artifact mode: prebuilt artifact — nothing to build"
    return 0
  fi
  # lib.sh's build_app, NOT an inline sequence — upgrade-host.sh runs the very
  # same function, so the fleet-upgrade path cannot drift into "fetched the new
  # ref but never rebuilt apps/core/dist". See build_app's comment.
  build_app "${SRC_DEST}" "${CORE_SERVE_WEB}"
}

docker_service_ready() { as_root docker info >/dev/null 2>&1; }
pg_query_ok() { as_root docker exec "${DB_CONTAINER}" psql -U postgres -tAc 'SELECT 1' >/dev/null 2>&1; }

# ParadeDB's first boot is initdb → start → install extensions → RESTART → ready,
# so postgres briefly accepts connections BEFORE the init-restart. A single
# pg_isready (or one SELECT 1) can pass in that pre-restart window, and then the
# very next step (migrations) hits `57P03 the database system is starting up`.
# Require several CONSECUTIVE successful real queries spaced ~1s apart: a restart
# mid-window breaks the streak, so we only proceed once postgres is STABLY up.
pg_stably_ready() {
  local i
  for i in 1 2 3; do
    pg_query_ok || return 1
    [[ ${i} -lt 3 ]] && sleep 1
  done
  return 0
}

phase_database() {
  phase_step database "phase 3/8: database (${DB_MODE})"
  if [[ ${DB_MODE} == external ]]; then
    # The CA goes in FIRST: the DSN names it via `sslrootcert`, and every
    # later consumer — the app's own connections, `bun run db:migrate`, the
    # nightly pg_dump — needs it present at that exact path or the connection
    # is refused outright under verify-full.
    [[ -z ${DB_CA_PATH} ]] || install_database_ca "${DB_CA_PATH}"
    # Best-effort reachability probe before we try to migrate.
    if [[ ${DB_DSN_CFG} =~ @([^:/@]+):([0-9]+)/ ]]; then
      local host=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
      retry_until 30 2 "postgres TCP ${host}:${port}" bash -c "exec 3<>/dev/tcp/${host}/${port}" ||
        die "cannot reach external postgres at ${host}:${port}"
    fi
    log_info "using external database"
    return
  fi

  # The ficus-machine image masks rootful docker for BOX security. This host is
  # the CORE host (not a box host), so unmasking it for the local DB container
  # is correct and intended.
  if [[ $(as_root systemctl is-enabled docker.service 2>/dev/null || true) == masked ]]; then
    log_info "docker.service is masked (ficus-machine box hardening) — unmasking for the core DB container"
    as_root systemctl unmask docker.service docker.socket
  fi
  as_root systemctl enable --now docker.service
  retry_until 60 2 'docker daemon' docker_service_ready || die "docker daemon did not come up"

  if as_root docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
    if [[ ${DB_PW_RECOVERED} -ne 1 ]]; then
      die "container ${DB_CONTAINER} exists but its password could not be recovered from ${ENV_FILE} — remove it (docker rm -f ${DB_CONTAINER}; docker volume rm ${DB_VOLUME}) or use database.mode=external"
    fi
    if [[ $(as_root docker inspect -f '{{.State.Running}}' "${DB_CONTAINER}") != true ]]; then
      log_info "starting existing ${DB_CONTAINER} container"
      as_root docker start "${DB_CONTAINER}" >/dev/null
    else
      log_info "reusing running ${DB_CONTAINER} container"
    fi
  else
    log_info "starting ${DB_IMAGE} as ${DB_CONTAINER} (ParadeDB: postgres + pgvector + pg_search)"
    as_root docker run -d --name "${DB_CONTAINER}" --restart unless-stopped \
      -e POSTGRES_USER=postgres -e "POSTGRES_PASSWORD=${DB_PASSWORD}" -e POSTGRES_DB=tau \
      -p 127.0.0.1:5432:5432 -v "${DB_VOLUME}:/var/lib/postgresql" \
      "${DB_IMAGE}" >/dev/null
  fi
  retry_until 120 2 'postgres stably ready' pg_stably_ready || die "postgres did not become ready"
  if ! as_root docker exec "${DB_CONTAINER}" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='tau'" | grep -q 1; then
    log_info "creating database 'tau'"
    as_root docker exec "${DB_CONTAINER}" createdb -U postgres tau
  fi
  log_info "database ready"
}

# Restore-from-backup — runs ONLY when FICUS_SETUP_RESTORE_URL is set, between
# phase_database and phase_env. Ordering is load-bearing:
#   * AFTER phase_database  — the tenant database (external mode: created by the
#     control plane before the toolkit runs; container mode: created above)
#     must exist, and its CA must be installed, before pg_restore connects.
#   * BEFORE phase_migrate  — the dump carries the drizzle __drizzle_migrations
#     table, so restoring first lets the subsequent migrate phase FAST-FORWARD
#     (apply only migrations newer than the backup) instead of re-running them.
#   * BEFORE phase_env      — the archived FICUS_ENCRYPTION_KEY is carried forward
#     into the rendered .env (overriding the generated one), so the restored
#     DB's encrypted secret store stays readable.
#   * BEFORE phase_services — the workspace tree is laid down before the app
#     that reads it starts.
# Any failure (download, decrypt, restore) dies: a half-restored instance must
# fail the whole provision, not limp onward. The temp dir + downloaded archive
# are always cleaned up.
phase_restore() {
  phase_step restore "phase 3.5/8: restore from backup"
  local passphrase=${FICUS_SETUP_RESTORE_PASSPHRASE:-}
  [[ -n ${passphrase} ]] ||
    die "restore: FICUS_SETUP_RESTORE_URL is set but FICUS_SETUP_RESTORE_PASSPHRASE is empty — cannot decrypt the archive"

  local dsn
  dsn=$(db_dsn "${DB_PASSWORD}")
  [[ -n ${dsn} ]] || die "restore: no database DSN available to restore into"

  # Target HOME_DIR for the workspace tree. BACKUP_HOME_DIR is already resolved
  # when backup.enabled (which the control plane always sets); derive it the
  # same way otherwise so a standalone restore still works.
  local target_home=${BACKUP_HOME_DIR}
  if [[ -z ${target_home} ]]; then
    local run_home=''
    have getent && run_home=$(getent passwd "${RUN_USER}" 2>/dev/null | cut -d: -f6)
    [[ -z ${run_home} && ${RUN_USER} == "$(id -un)" ]] && run_home=${HOME}
    [[ -n ${run_home} ]] || die "restore: could not resolve HOME_DIR for run_user '${RUN_USER}' (set core.env.HOME_DIR)"
    target_home="${run_home}/.tau"
  fi

  local workdir passfile archive
  workdir=$(mktemp -d -t tau-restore.XXXXXX)
  chmod 700 "${workdir}"
  passfile=$(mktemp)
  chmod 600 "${passfile}"
  archive="${workdir}/backup.tar.gz.enc"
  # Clean up the temp dir (unencrypted dump/.env/workspace intermediates AND
  # the encrypted download) + the passfile on EVERY exit path.
  # shellcheck disable=SC2317 # invoked via trap
  _restore_cleanup() { rm -f "${passfile}"; rm -rf "${workdir}"; }
  trap _restore_cleanup RETURN
  printf '%s' "${passphrase}" >"${passfile}"

  # Presigned GET — no extra auth, so a plain curl. -f fails on HTTP errors
  # (an expired/incorrect presign is a 403 body, not a partial file). The URL
  # is a credential; never log it.
  log_info "downloading encrypted backup archive"
  curl -fsSL -o "${archive}" "${RESTORE_URL}" ||
    die "restore: failed to download the backup archive (presigned URL expired, or object missing)"

  log_info "decrypting + extracting archive"
  restore_unpack_archive "${archive}" "${passfile}" "${workdir}"
  # The encrypted download is no longer needed; shrink the exposure window.
  rm -f "${archive}"

  # (a) pg_restore the dump. --clean --if-exists makes a retried provision
  # idempotent (a prior run's objects are dropped-then-recreated); --no-owner
  # ignores the source's role ownership (the target cluster's login role
  # differs). Runs BEFORE migrate on purpose (see the phase header).
  log_info "restoring database (pg_restore)"
  if [[ ${DB_MODE} == container ]]; then
    as_root docker exec -i "${DB_CONTAINER}" pg_restore --clean --if-exists --no-owner -U postgres -d tau \
      <"${workdir}/db.dump" || die "restore: pg_restore into the ${DB_CONTAINER} container failed"
  else
    pg_restore --clean --if-exists --no-owner -d "${dsn}" "${workdir}/db.dump" ||
      die "restore: pg_restore into the external database failed"
  fi

  # (b) lay down the workspace tree at the target HOME_DIR. The archive's
  # workspace dir may carry a different basename than the target, so copy its
  # CONTENTS in rather than relying on the name matching.
  local home_src
  home_src=$(restore_home_subdir "${workdir}")
  if [[ -n ${home_src} ]]; then
    log_info "restoring workspace tree into ${target_home}"
    mkdir -p "${target_home}"
    cp -a "${home_src}/." "${target_home}/" || die "restore: failed to lay down the workspace tree into ${target_home}"
  else
    log_warn "restore: archive carried no workspace directory — skipping HOME_DIR restore"
  fi

  # (c) carry FICUS_ENCRYPTION_KEY forward from the archived .env, overriding the
  # value resolve_secrets computed. phase_env (next) renders the .env from
  # these globals, so the restored DB's encrypted secret store stays readable.
  local archived_key
  archived_key=$(envfile_get "${workdir}/.env" 'FICUS_ENCRYPTION_KEY' || true)
  [[ -n ${archived_key} ]] ||
    die "restore: archived .env carried no FICUS_ENCRYPTION_KEY — the restored DB's secrets would be permanently undecryptable"
  FICUS_ENC_VALUE=${archived_key}
  ENC_SOURCE='restored backup envelope'
  log_info "carried FICUS_ENCRYPTION_KEY forward from the restored backup"

  # (d) cross-subdomain restore: WebAuthn passkeys are bound to the origin they
  # were registered against, so credentials from the old subdomain can never
  # authenticate here. Drop them (keeping users) so the instance isn't locked
  # to dead passkeys. NEVER touches core code — a plain DELETE via the DSN.
  if [[ ${RESTORE_STRIP_CREDENTIALS} == 1 ]]; then
    log_info "cross-subdomain restore: stripping WebAuthn credentials (users kept)"
    if [[ ${DB_MODE} == container ]]; then
      as_root docker exec "${DB_CONTAINER}" psql -U postgres -d tau -c 'DELETE FROM user_credentials;' >/dev/null ||
        die "restore: failed to strip WebAuthn credentials"
    else
      psql "${dsn}" -c 'DELETE FROM user_credentials;' >/dev/null ||
        die "restore: failed to strip WebAuthn credentials"
    fi
  fi

  log_info "restore complete"
}

phase_env() {
  phase_step env "phase 4/8: render ${ENV_FILE}"
  # Staged + verified non-empty before landing (install_rendered), never a
  # direct `> ${ENV_FILE}` — that truncates the previous good env the instant
  # the render starts, so a render that dies midway leaves the services with
  # a gutted EnvironmentFile. No placeholder check: env values are arbitrary
  # secrets/DSNs. Owned by the invoking user (who owns ${SRC_DEST}), 0600.
  install_rendered 0600 "$(id -un)" "$(id -gn)" "${ENV_FILE}" build_env_content real
  log_info "wrote ${ENV_FILE} (0600) — APP_URL=FICUS_WEB_ORIGIN=${CORE_ORIGIN}"
}

# Platform-managed artifacts (SES env creds, APNs cert files, ...). Installs
# managed.env → /etc/tau/managed.env and each staged file → /etc/tau/artifacts/
# from the staging directory provision.sh pushed (artifacts.dir). Runs BEFORE
# phase_services so managed.env exists when the units first start (they load it
# via EnvironmentFile=-/etc/tau/managed.env). A no-op when artifacts.dir is
# empty — the self-hosted / no-artifacts case, byte-identical to before.
phase_artifacts() {
  phase_step artifacts "phase 5.5/8: platform-managed artifacts"
  install_managed_env "${ARTIFACTS_DIR}"
  install_artifacts "${ARTIFACTS_DIR}"
  # Reconcile parity with the sync path (apply-artifacts.sh): a re-run on an
  # existing droplet (provision retries reuse the VM) must also DROP files for
  # artifacts deleted from the registry since the earlier attempt. Fresh VM:
  # empty dir, no-op.
  prune_artifacts "${ARTIFACTS_DIR}"
  log_info "artifacts installed from ${ARTIFACTS_DIR}"
}

phase_migrate() {
  phase_step migrations "phase 5/8: database migrations"
  if [[ ${SRC_MODE} == artifact ]]; then
    log_info "artifact mode: migrations run inside artifact_activate (phase 6) — nothing to do here"
    return 0
  fi
  run_db_migrations "${SRC_DEST}"
}

phase_services() {
  phase_step services "phase 6/8: systemd services (tau-api, tau-worker)"
  install_core_units "${SCRIPT_DIR}/systemd"
  # Non-root services need a NOPASSWD sudoers rule so the self-updater can restart
  # them (`sudo -n systemctl restart ...`). Root installs restart directly.
  if [[ ${RUN_USER} != root ]]; then
    install_update_sudoers
  fi
  ensure_tau_api_memory_guardrail
  as_root systemctl daemon-reload
  as_root systemctl enable tau-api tau-worker >/dev/null 2>&1
  if [[ ${SRC_MODE} == artifact ]]; then
    # Activation migrates, flips <dest>/current, restarts, health-checks, and
    # auto-rolls-back on a failed health check — on a fresh box there is no
    # rollback target, which artifact_activate already handles.
    artifact_activate "${SRC_DEST}" "${ARTIFACT_RELEASE_DIR}" "${CORE_PORT}"
    artifact_retention "${SRC_DEST}"
  else
    # lib.sh's restart_core_services — shared verbatim with upgrade-host.sh, so
    # both paths refuse to report success on a unit that never came up.
    restart_core_services "${CORE_PORT}"
  fi
}

phase_caddy() {
  phase_step ingress "phase 6.5/8: caddy ingress (${CADDY_HOST})"
  # install_caddy first: it is what creates the caddy service user the private
  # key is chowned to. Both live in lib.sh — setup-platform.sh installs the
  # very same certificate on the control-plane host.
  install_caddy
  install_origin_cert "${CADDY_CERT_PATH}" "${CADDY_KEY_PATH}"
  caddy_write_and_reload "$(render_caddyfile "${CADDY_HOST}" "${CORE_PORT}" "${CADDY_TLS_CERT_PATH}" "${CADDY_TLS_KEY_PATH}")"
}

phase_backup() {
  phase_step backup "phase 6.6/8: nightly encrypted backup (S3 prefix '${BACKUP_S3_PREFIX}', HOME_DIR ${BACKUP_HOME_DIR})"
  as_root mkdir -p /etc/tau

  # Secrets: rendered to their own 0600 root-owned file via install_rendered's
  # 0600 tmp file — never through `as_root tee` (which would create the file
  # under root's umask, not a guaranteed mode) and never in argv. No
  # placeholder check on the env file: S3 keys/passphrases are arbitrary
  # values that may legitimately contain `@…@`.
  install_rendered 0600 root root "${BACKUP_ENV_TARGET}" \
    render_backup_env_content real "${BACKUP_S3_ACCESS_KEY_VALUE}" "${BACKUP_S3_SECRET_KEY_VALUE}" "${BACKUP_PASSPHRASE_VALUE}"

  install_rendered --check-placeholders 0755 root root "${BACKUP_SCRIPT_PATH}" \
    render_backup_script

  # The units go through the same staged+verified path — a failed render here
  # once landed a 0-byte tau-backup.service that daemon-reload accepted
  # silently, so the nightly backup never ran.
  install_rendered --check-placeholders 0644 root root /etc/systemd/system/tau-backup.service \
    render_backup_unit "${SCRIPT_DIR}/systemd/tau-backup.service.tmpl"
  install_rendered --check-placeholders 0644 root root /etc/systemd/system/tau-backup.timer \
    render_backup_unit "${SCRIPT_DIR}/systemd/tau-backup.timer.tmpl"

  as_root systemctl daemon-reload
  as_root systemctl enable --now tau-backup.timer
  log_info "backup timer installed (OnCalendar=${BACKUP_ONCALENDAR}); script: ${BACKUP_SCRIPT_PATH}, secrets: ${BACKUP_ENV_TARGET} (0600)"
}

phase_seed() {
  phase_step seed "phase 7/8: seed provider, secrets, starter squad (via bootstrap bearer)"
  # Secrets travel as exported env vars in a subshell — NOT as `env KEY=VALUE`
  # arguments, which would put them in the env process's ps-visible argv.
  (
    export FICUS_PASSWORD="${FICUS_PW_VALUE}"
    if [[ -n ${AI_KEY_VALUE} && ${AI_KEY_VALUE} != '<'*'>' ]]; then
      export "${AI_KEY_ENV}=${AI_KEY_VALUE}"
    fi
    exec bash "${SCRIPT_DIR}/seed.sh" \
      --config "${CFG_FILE}" \
      --env-file "${ENV_FILE}" \
      --api-url "http://127.0.0.1:${CORE_PORT}"
  )
}

phase_report() {
  phase_step verify "phase 8/8: verify + handoff"
  local status mode has_admin email_cfg
  status=$(curl -sS --max-time 10 "http://127.0.0.1:${CORE_PORT}/api/auth/status")
  mode=$(jq -r '.mode' <<<"${status}")
  has_admin=$(jq -r '.hasAdminUser' <<<"${status}")
  email_cfg=$(jq -r '.emailConfigured' <<<"${status}")
  log_info "auth status: ${status}"
  if [[ ${has_admin} == true ]]; then
    log_info "an admin user already exists — this instance is already owned; nothing to hand off"
    # Machine-readable trailer the control plane parses to learn what this
    # run activated — upgrade-host.sh documents this trailer as the LAST
    # lines on stdout, so a future tail-based parser must see it there even
    # on this early-return path, not buried before a log line.
    # `if`, not `[[ … ]] &&`: this is the LAST statement before the return on
    # both paths, and the && form returns 1 in git mode — which set -e turns
    # into "every git-mode provision exits 1 after fully succeeding"
    # (final-review catch).
    if [[ ${SRC_MODE} == artifact ]]; then
      artifact_emit_release_trailer "none" "${ARTIFACT_RELEASE_ID}"
    fi
    return
  fi
  [[ ${mode} == password ]] || log_warn "expected auth mode 'password' before first admin, got '${mode}'"

  # A fresh unattended setup has no email provider, so the verification code
  # is shown inline in the UI. If email IS configured, the handoff changes.
  local code_note='(email is unconfigured, so the verification code is shown inline)'
  if [[ ${email_cfg} == true ]]; then
    log_warn "emailConfigured=true — the inline-code handoff does not apply; the verification code will be EMAILED to the address used at registration"
    code_note='(email is configured — the verification code is emailed to the address you register with)'
  fi

  cat <<EOF

================================================================================
 tau is up.

   URL:  ${CORE_ORIGIN}

 Finish setup in your browser:
   1. Open ${CORE_ORIGIN}
   2. Create your account — the FIRST passkey registered becomes the system
      admin ${code_note}.

 Bootstrap token (FICUS_PASSWORD):
EOF
  render_bootstrap_token_block "${PW_GENERATED}" "${FICUS_PW_VALUE}" "${PW_SOURCE}" "${ENV_FILE}"
  cat <<EOF
   This token is fully privileged ONLY while no admin exists. It disables
   itself automatically the moment the first admin passkey is created —
   nothing to revoke.

 Services: systemctl status tau-api tau-worker   (logs: journalctl -u tau-api)
================================================================================
EOF

  # Machine-readable trailer the control plane parses to learn what this run
  # activated. Provisioning has no BEFORE release — this is the box's first
  # release — so BEFORE is the literal string "none", passed explicitly (the
  # function's own default for an absent argument is "unknown").
  # Deliberately the LAST statement in this function — upgrade-host.sh
  # documents the trailer as the last lines on stdout, and a future
  # tail-based parser must not have to guess where the human-facing handoff
  # banner above ends and the trailer begins.
  # `if`, not `[[ … ]] &&`: this is the LAST statement on both paths, and the
  # && form returns 1 in git mode — which set -e turns into "every git-mode
  # provision exits 1 after fully succeeding" (final-review catch).
  if [[ ${SRC_MODE} == artifact ]]; then
    artifact_emit_release_trailer "none" "${ARTIFACT_RELEASE_ID}"
  fi
}

phase_preflight
phase_source
phase_build
phase_database
[[ -n ${RESTORE_URL} ]] && phase_restore
phase_env
phase_migrate
[[ -n ${ARTIFACTS_DIR} ]] && phase_artifacts
phase_services
[[ ${CADDY_ENABLE} == true ]] && phase_caddy
[[ ${BACKUP_ENABLE} == true ]] && phase_backup
phase_seed
phase_report
