#!/usr/bin/env bash
# provision.sh — ORCHESTRATOR: new tenant → running tau, from a control
# machine. (Formerly provision-exe.sh — renamed when a second VM provider
# joined exe.dev; provision-exe.sh is now a compat shim to this file.)
#
#   1. provisions a fresh VM (PROVIDER SEAM: provision_vm() dispatches on
#      provision.provider — exe.dev's prebaked ficus-machine image, Hetzner
#      Cloud, or DigitalOcean + optional Cloudflare DNS)
#   2. waits for SSH
#   3. pushes the setup toolkit + config + credential files (COPYFILE_DISABLE=1
#      so macOS never ships AppleDouble '._*' files; the SOURCE tree itself is
#      never copied — setup-host.sh git-clones it on the target)
#   4. runs setup-host.sh on the VM
#   5. prints the tenant URL + admin-passkey handoff
#
# Idempotent: if the VM already exists it is reused (exe: answers SSH;
# hetzner/digitalocean: a same-name server/droplet exists); setup-host.sh
# itself is fully re-runnable.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: provision.sh --config tau-setup.yaml [options]
       provision.sh --wizard [--config OUT.yaml]

Provisions a VM (exe.dev, Hetzner Cloud, or DigitalOcean — see
provision.provider) and runs setup-host.sh on it over SSH. The result is a
running tau whose only remaining step is creating the first admin passkey in
a browser.

Options:
  --config FILE   config file (see tau-setup.example.yaml); the `provision`
                  section drives this script. With --wizard, the output path.
  --wizard        interactively generate a config file, then exit
  --dry-run       print the plan (VM command, files pushed with secrets
                  redacted, remote command) without provisioning anything
  -h, --help      show this help

Requires on this machine: ssh, scp, jq, mikefarah yq v4 (brew install yq).
Secrets travel as env vars / key files pushed over scp (0600), never in yaml.
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

yq_is_mikefarah || ensure_yq # dies with install instructions on non-Linux

if [[ ${WIZARD} -eq 1 ]]; then
  wizard_write_config "${CONFIG:-./tau-setup.yaml}"
  exit 0
fi

[[ -n ${CONFIG} ]] || {
  usage >&2
  die "--config is required (or use --wizard to generate one)"
}

require_cmd ssh
require_cmd scp
require_cmd jq
cfg_load "${CONFIG}"

# ============================================================== configuration

PROVIDER=$(cfg_get '.provision.provider' 'exe')
VM_NAME=$(cfg_require '.provision.name' 'VM name')
case "${PROVIDER}" in
  hetzner | digitalocean) SSH_USER_DEFAULT='root' ;;
  *) SSH_USER_DEFAULT='exedev' ;;
esac
SSH_USER=$(cfg_get '.provision.ssh_user' "${SSH_USER_DEFAULT}")
ACCOUNT_KEY=$(expand_tilde "$(cfg_get '.provision.account_key_path')")
[[ -n ${ACCOUNT_KEY} ]] || ACCOUNT_KEY=$(expand_tilde "$(cfg_get '.runtime.exe.ssh_key_path')")
MACHINE_IMAGE=$(cfg_get '.runtime.exe.machine_image' 'ghcr.io/ficushq/ficus-machine:latest')
CORE_ORIGIN=$(cfg_require '.core.origin' 'browser-facing origin')
CORE_PORT=$(cfg_get '.core.port' '3000')
SRC_MODE=$(cfg_get '.source.mode' 'git-ssh')
DEPLOY_KEY=$(expand_tilde "$(cfg_get '.source.deploy_key_path')")
# Origin TLS (ingress.caddy) — the Cloudflare Origin CA cert+key pair, on THIS
# control machine. Delivered to the VM exactly like the deploy key above: scp
# into ${REMOTE_DIR}/keys (0600), config paths rewritten to match. ONE pair
# covers hiretau.ai and *.hiretau.ai, so the same private key lands on every
# tenant VM — an accepted operator decision: an origin certificate only
# authenticates an origin TO Cloudflare, and is worthless to a browser.
CADDY_ENABLE=$(cfg_bool '.ingress.caddy' 'false')
INGRESS_CERT=$(expand_tilde "$(cfg_get '.ingress.tls_cert_path')")
INGRESS_KEY=$(expand_tilde "$(cfg_get '.ingress.tls_key_path')")
# CA certificate for an EXTERNAL postgres (database.ca_path) — a file on THIS
# control machine, delivered to the VM over the very same scp path as the
# origin cert above. It is what a `sslmode=verify-full` DSN verifies the
# server's certificate against.
#
# NOT a secret: a CA certificate is public. So unlike the origin key it ends up
# world-readable (0644) on the target — see install_database_ca in lib.sh. It
# still travels the keys/ path here because that is the one mechanism the
# toolkit already has for "small file this machine holds that the VM needs".
DB_CA_PATH=$(expand_tilde "$(cfg_get '.database.ca_path')")
# Platform-managed artifact STAGING DIRECTORY on THIS control machine
# (the hosted control plane's provision executor builds it: managed.env + files/ +
# manifest). Delivered to the VM over the same seam as the CA above — scp'd
# recursively into ${REMOTE_DIR}/artifacts, config path rewritten to match,
# setup-host.sh's phase_artifacts installs it. Contents (env credential values,
# file bodies) never touch the yaml or a log line. Empty for self-hosted /
# no-artifacts installs → nothing is pushed and setup-host skips the phase.
ARTIFACTS_DIR=$(expand_tilde "$(cfg_get '.artifacts.dir')")
EXE_KEY=$(expand_tilde "$(cfg_get '.runtime.exe.ssh_key_path')")
# REQUIRED and explicit — no default, and validated against the SAME five values
# the core accepts (lib.sh's require_sandbox_runtime, shared with setup-host.sh).
RT_SANDBOX=$(trim_ws "$(cfg_get '.runtime.sandbox')") # compared against `vm` below; padding would silently mis-compare
require_sandbox_runtime "${RT_SANDBOX}"
# Seeding an exe.dev key is OPT-IN too, same reasoning as AI_SECTION_PRESENT
# just below: do_droplet configs are ALSO `runtime.sandbox: vm` (the platform
# provisions its own machine host, not an exe VM), so gating the key
# resolution on RT_SANDBOX alone made every do_droplet provision run through
# resolve_exe_key_path and log its "ssh_key_path is unset" warning for a key
# that config never asked for. Probed via structural presence (cfg_has), NOT
# cfg_get's non-empty check — a self-hoster's `runtime.exe.ssh_key_path: ''`
# (present, empty, meaning "prompt me for it") must still resolve; only a
# config with no `runtime.exe` section at all skips resolution entirely.
EXE_SECTION_PRESENT=0
cfg_has '.runtime.exe.ssh_key_path' && EXE_SECTION_PRESENT=1
# Seeding an AI provider is OPT-IN: presence of the ai: section is probed via
# .ai.model (the field setup-host.sh's AI_SECTION_PRESENT keys on), NOT via
# .ai.provider — which defaults to 'openai' and so is ALWAYS non-empty. Keying
# the "key required" check off the provider default is exactly what made an
# ai-less config (the do_droplet / onboarding-configures-it-later path) die on
# "$OPENAI_API_KEY must be set" below. With no ai: section, AI_KEY_ENV stays
# empty and the unattended-run guard is skipped entirely.
AI_SECTION_PRESENT=0
[[ -n $(cfg_get '.ai.model' '') ]] && AI_SECTION_PRESENT=1
AI_PROVIDER=$(cfg_get '.ai.provider' 'openai')
AI_KEY_ENV=''
if [[ ${AI_SECTION_PRESENT} -eq 1 ]]; then
  case "${AI_PROVIDER}" in
    openai) AI_KEY_ENV_DEFAULT='OPENAI_API_KEY' ;;
    anthropic) AI_KEY_ENV_DEFAULT='ANTHROPIC_API_KEY' ;;
    *) AI_KEY_ENV_DEFAULT='' ;;
  esac
  AI_KEY_ENV=$(cfg_get '.ai.key_env' "${AI_KEY_ENV_DEFAULT}")
fi
SEC_ENC_ENV=$(cfg_get '.secrets.encryption_key_env')
SEC_PW_ENV=$(cfg_get '.secrets.password_env')
# core.env's *_ENV-suffixed entries (secret indirection) — the underlying env
# var names, so they can be forwarded to the target alongside the other
# secrets below. Validated on the control machine too (dies fast, before any
# VM work, on a malformed core.env) — setup-host.sh re-validates + resolves
# them on the target.
CORE_ENV_FORWARD_NAMES=$(cfg_env_forward_names '.core.env')
# backup.*_env name the env vars holding the S3 credentials + passphrase (see
# lib.sh render_backup_env_content) — forward them too so a headless run on
# the target can resolve them, same as secrets.*_env above. Always non-empty
# (cfg_get defaults match setup-host.sh's), so no -n guard is needed; whether
# anything actually ships depends on the FORWARD_ENVS push loop below finding
# a set value.
BACKUP_S3_ACCESS_KEY_ENV=$(cfg_get '.backup.s3_access_key_env' 'FICUS_BACKUP_S3_ACCESS_KEY')
BACKUP_S3_SECRET_KEY_ENV=$(cfg_get '.backup.s3_secret_key_env' 'FICUS_BACKUP_S3_SECRET_KEY')
BACKUP_PASSPHRASE_ENV=$(cfg_get '.backup.passphrase_env' 'FICUS_BACKUP_PASSPHRASE')

# Hetzner provider + Cloudflare DNS knobs (ignored unless provision.provider /
# dns.provider select them).
HZ_SERVER_TYPE=$(cfg_get '.provision.hetzner.server_type' 'cx32')
HZ_LOCATION=$(cfg_get '.provision.hetzner.location' 'fsn1')
HZ_IMAGE=$(cfg_get '.provision.hetzner.image' 'ubuntu-24.04')
HZ_SSH_KEY_NAME=$(cfg_get '.provision.hetzner.ssh_key_name' '')

# DigitalOcean provider knobs (ignored unless provision.provider=digitalocean).
# fallbacks is an ORDERED list of alternate {size, region} pairs tried, in
# order, when the primary size/region create fails with a capacity error
# (do_is_capacity_error in lib.sh) — see provision_vm_digitalocean below.
# DO_TAG is set on every droplet this toolkit creates and is the idempotent
# reuse/destroy lookup key (paired with an exact name match; see
# do_droplet_lookup in lib.sh) — not config-driven, deliberately fixed so a
# renamed tag can never silently orphan existing tenant droplets.
DO_SIZE=$(cfg_get '.provision.digitalocean.size' 's-2vcpu-4gb')
DO_REGION=$(cfg_get '.provision.digitalocean.region' 'nyc3')
DO_IMAGE=$(cfg_get '.provision.digitalocean.image' 'ubuntu-24-04-x64')
DO_SSH_KEY_ID=$(cfg_get '.provision.digitalocean.ssh_key_id' '')
DO_FALLBACKS=$(cfg_do_fallbacks '.provision.digitalocean.fallbacks')
# Both optional (empty = leave it to DO's defaults / skip the call).
#   vpc_uuid    pins the droplet to a specific VPC network instead of the
#               region's CURRENT default VPC — required whenever the droplet
#               must reach something on a private network (a managed
#               database's private host, other droplets), because which VPC
#               is "the default" is a mutable console setting.
#   project_id  DO project the droplet is filed under. Droplet-create has no
#               project field, so this is a separate POST after create — see
#               do_project_assign below.
DO_VPC_UUID=$(cfg_get '.provision.digitalocean.vpc_uuid' '')
DO_PROJECT_ID=$(cfg_get '.provision.digitalocean.project_id' '')
DO_TAG='tau-tenant'

DNS_PROVIDER=$(cfg_get '.dns.provider' '')
DNS_ZONE=$(cfg_get '.dns.zone' '')
# Record name = the host of core.origin (the DNS name the browser opens); not
# to be confused with VM_HOST below, which for hetzner is the SSH target
# (raw server IP — DNS may not have propagated yet).
DNS_HOST=$(origin_host "${CORE_ORIGIN}")

# VM_HOST is the SSH target. exe.dev assigns a stable *.exe.xyz hostname
# before the VM even exists, so it's known here; hetzner only hands out an IP
# once the server is created, so provision_vm_hetzner() sets it (never DNS —
# a freshly-upserted record may not have propagated yet).
case "${PROVIDER}" in
  exe) VM_HOST="${VM_NAME}.exe.xyz" ;;
  *) VM_HOST='' ;;
esac
if [[ ${SSH_USER} == root ]]; then
  REMOTE_HOME='/root'
else
  REMOTE_HOME="/home/${SSH_USER}"
fi
REMOTE_DIR="${REMOTE_HOME}/tau-setup"

if [[ ${PROVIDER} == exe ]]; then
  EXPECTED_ORIGIN="https://${VM_HOST}:${CORE_PORT}"
  if [[ ${CORE_ORIGIN} != "${EXPECTED_ORIGIN}" ]]; then
    log_warn "core.origin (${CORE_ORIGIN}) != derived VM origin (${EXPECTED_ORIGIN})"
    log_warn "if the browser will open ${EXPECTED_ORIGIN}, passkey registration WILL fail — fix core.origin unless a proxy/DNS in front changes the origin deliberately"
  fi
fi

# Secrets forwarded to the target as env vars (pushed as a 0600 env file,
# deleted after the run). Never written into the yaml. HCLOUD_TOKEN /
# CLOUDFLARE_API_TOKEN are control-machine-only (they authorize this script to
# talk to the provider APIs) and must never appear here.
FORWARD_ENVS=()
[[ -n ${AI_KEY_ENV} ]] && FORWARD_ENVS+=("${AI_KEY_ENV}")
[[ ${SRC_MODE} == git-https ]] && FORWARD_ENVS+=('GH_TOKEN')
# Artifact mode: the tarball/manifest/sig URLs are presigned S3 GETs and the
# pubkey is used to verify the manifest signature on the target — none of
# them are secret in the confidentiality sense, but they ride the same 0600
# secrets.env channel as everything else here because the presigned URLs
# are bearer credentials (anyone holding the URL can fetch the artifact) and
# because that's the one channel this script already has for getting
# per-run values onto the target without writing them into the yaml. GH_TOKEN
# deliberately does NOT ride here: artifact mode never clones from GitHub —
# the whole point of shipping a prebuilt artifact is to skip that path — so
# forwarding a GitHub credential in this mode would be a live, unused secret
# on the target for no reason.
if [[ ${SRC_MODE} == artifact ]]; then
  FORWARD_ENVS+=('FICUS_ARTIFACT_TARBALL_URL' 'FICUS_ARTIFACT_MANIFEST_URL' 'FICUS_ARTIFACT_SIG_URL' 'FICUS_ARTIFACT_PUBKEY_B64')
fi
[[ -n ${SEC_ENC_ENV} ]] && FORWARD_ENVS+=("${SEC_ENC_ENV}")
[[ -n ${SEC_PW_ENV} ]] && FORWARD_ENVS+=("${SEC_PW_ENV}")
FORWARD_ENVS+=('FICUS_SETUP_DATABASE_DSN')
FORWARD_ENVS+=("${BACKUP_S3_ACCESS_KEY_ENV}" "${BACKUP_S3_SECRET_KEY_ENV}" "${BACKUP_PASSPHRASE_ENV}")
# Restore-from-backup (cloud control plane): the presigned archive URL, its
# decryption passphrase, and the cross-subdomain credential-strip flag. Only
# ship when the control plane actually set them (the push loop below is
# `-n`-gated), so a non-restore provision forwards nothing extra. The URL is a
# presigned S3 GET and carries many `&` — sh_single_quote in the push loop is
# what keeps `source`ing secrets.env from backgrounding at the first `&`.
FORWARD_ENVS+=('FICUS_SETUP_RESTORE_URL' 'FICUS_SETUP_RESTORE_PASSPHRASE' 'FICUS_SETUP_RESTORE_STRIP_CREDENTIALS')
# core.env's *_ENV secret-indirection entries — forward each named var so the
# headless run on the target can resolve them (mirrors secrets.*_env above).
while IFS= read -r core_env_forward_name; do
  [[ -n ${core_env_forward_name} ]] && FORWARD_ENVS+=("${core_env_forward_name}")
done <<<"${CORE_ENV_FORWARD_NAMES}"

REMOTE_CMD="set -a; [ -f ${REMOTE_DIR}/secrets.env ] && . ${REMOTE_DIR}/secrets.env; set +a; bash ${REMOTE_DIR}/setup-host.sh --config ${REMOTE_DIR}/tau-setup.yaml"

HCLOUD_API_BASE='https://api.hetzner.cloud/v1'
DO_API_BASE='https://api.digitalocean.com/v2'
CF_API_BASE='https://api.cloudflare.com/client/v4'

# ============================================================== dry run

if [[ ${DRY_RUN} -eq 1 ]]; then
  log_step "DRY RUN — printing the plan; nothing will be provisioned or contacted"
  printf '\nStep 1 — provision VM (provider seam: %s)\n' "${PROVIDER}"
  case "${PROVIDER}" in
    hetzner)
      plan "GET ${HCLOUD_API_BASE}/servers?name=${VM_NAME} (Bearer \$HCLOUD_TOKEN) — reuse if a server with this name exists"
      plan "else POST ${HCLOUD_API_BASE}/servers {name:${VM_NAME}, server_type:${HZ_SERVER_TYPE}, location:${HZ_LOCATION}, image:${HZ_IMAGE}, ssh_keys:[${HZ_SSH_KEY_NAME:-<provision.hetzner.ssh_key_name — required>}]}"
      plan "poll GET ${HCLOUD_API_BASE}/servers/<id> until status=running and a public IPv4 is assigned (timeout 300s)"
      plan "SSH target = that IPv4 (not DNS — a freshly-upserted record may not have propagated yet)"
      ;;
    digitalocean)
      plan "GET ${DO_API_BASE}/droplets?tag_name=${DO_TAG} (Bearer \$DIGITALOCEAN_TOKEN), filtered to name=${VM_NAME} — reuse if found"
      plan "else POST ${DO_API_BASE}/droplets {name:${VM_NAME}, region:${DO_REGION}, size:${DO_SIZE}, image:${DO_IMAGE}, ssh_keys:[${DO_SSH_KEY_ID:-<provision.digitalocean.ssh_key_id — required>}], tags:[${DO_TAG}]${DO_VPC_UUID:+, vpc_uuid:${DO_VPC_UUID}}}"
      if [[ -n ${DO_FALLBACKS} ]]; then
        plan "on a capacity/availability error (422/503), try each fallback in order, not on auth/image errors:"
        while IFS= read -r fb; do
          [[ -n ${fb} ]] && plan "  fallback: size=${fb% *} region=${fb#* }"
        done <<<"${DO_FALLBACKS}"
      fi
      [[ -n ${DO_PROJECT_ID} ]] &&
        plan "POST ${DO_API_BASE}/projects/${DO_PROJECT_ID}/resources {resources:[do:droplet:<id>]} — best-effort, a failure warns and continues"
      plan "poll GET ${DO_API_BASE}/droplets/<id> until status=active and a public IPv4 (networks.v4[].type==public) is assigned (timeout 300s)"
      plan "SSH target = that public IPv4 (not DNS — a freshly-upserted record may not have propagated yet)"
      ;;
    *)
      plan "ssh -i ${ACCOUNT_KEY:-<account key — required>} -o IdentitiesOnly=yes -o IdentityAgent=none exe.dev \\"
      plan "    new --name ${VM_NAME} --image ${MACHINE_IMAGE} --json"
      plan "(skipped if ${SSH_USER}@${VM_HOST} already answers SSH — idempotent re-run)"
      ;;
  esac
  if [[ -n ${DNS_PROVIDER} ]]; then
    printf '\nStep 1b — DNS (%s)\n' "${DNS_PROVIDER}"
    case "${DNS_PROVIDER}" in
      cloudflare)
        plan "GET ${CF_API_BASE}/zones?name=${DNS_ZONE} (Bearer \$CLOUDFLARE_API_TOKEN) → zone id"
        plan "GET ${CF_API_BASE}/zones/<zone id>/dns_records?type=A&name=${DNS_HOST} → existing record?"
        plan "PUT (if found) or POST (if not) an A record: ${DNS_HOST} → <provisioned VM IP>, proxied:true (the origin cert is trusted by Cloudflare's proxy ONLY)"
        ;;
      *) die "dns.provider '${DNS_PROVIDER}' is not implemented (only: cloudflare)" ;;
    esac
  fi
  printf '\nStep 2 — wait for SSH\n'
  plan "retry ssh ${SSH_USER}@${VM_HOST:-<resolved after VM creation>} true (account key, IdentityAgent=none) until reachable (timeout 300s)"
  printf '\nStep 3 — push toolkit + config + credentials (COPYFILE_DISABLE=1)\n'
  plan "→ ${REMOTE_DIR}/: lib.sh setup-host.sh seed.sh systemd/*.tmpl"
  plan "→ ${REMOTE_DIR}/tau-setup.yaml (key paths rewritten to ${REMOTE_DIR}/keys/*)"
  [[ ${SRC_MODE} == git-ssh && -n ${DEPLOY_KEY} ]] && plan "→ ${REMOTE_DIR}/keys/deploy_key (0600) from ${DEPLOY_KEY}"
  [[ ${RT_SANDBOX} == vm && -n ${EXE_KEY} ]] && plan "→ ${REMOTE_DIR}/keys/exe_key (0600) from ${EXE_KEY}"
  # Paths only — the origin key's CONTENTS are never printed, here or anywhere.
  [[ ${CADDY_ENABLE} == true && -n ${INGRESS_CERT} ]] && plan "→ ${REMOTE_DIR}/keys/origin_cert.pem (0600) from ${INGRESS_CERT}"
  [[ ${CADDY_ENABLE} == true && -n ${INGRESS_KEY} ]] && plan "→ ${REMOTE_DIR}/keys/origin_key.pem (0600) from ${INGRESS_KEY} (contents never printed)"
  [[ -n ${ARTIFACTS_DIR} ]] && plan "→ ${REMOTE_DIR}/artifacts (recursive, 0700) from ${ARTIFACTS_DIR} — managed.env + files + manifest (credential contents never printed)"
  for name in "${FORWARD_ENVS[@]}"; do
    if [[ -n ${!name:-} ]]; then
      plan "→ ${REMOTE_DIR}/secrets.env (0600): ${name}=$(redact_secret "${!name}")"
    fi
  done
  printf '\nStep 4 — run setup on the VM\n'
  plan "ssh ${SSH_USER}@${VM_HOST:-<resolved after VM creation>} '${REMOTE_CMD}'"
  plan "then: setup-host.sh phases 0-8 (run it with --dry-run locally to see its full plan)"
  printf '\nStep 5 — cleanup + handoff\n'
  plan "delete ${REMOTE_DIR}/secrets.env on the VM"
  plan "print ${CORE_ORIGIN} + 'create your first admin passkey' handoff"
  exit 0
fi

# ============================================================== preflight

[[ -n ${ACCOUNT_KEY} ]] || die "no SSH key for the provisioned VM: set provision.account_key_path (or runtime.exe.ssh_key_path)"
[[ -f ${ACCOUNT_KEY} ]] || die "SSH key not found: ${ACCOUNT_KEY}"
if [[ ${PROVIDER} == hetzner ]]; then
  [[ -n ${HCLOUD_TOKEN:-} ]] || die "provision.provider=hetzner needs \$HCLOUD_TOKEN"
  [[ -n ${HZ_SSH_KEY_NAME} ]] || die "config: provision.hetzner.ssh_key_name is required for provider=hetzner"
fi
if [[ ${PROVIDER} == digitalocean ]]; then
  [[ -n ${DIGITALOCEAN_TOKEN:-} ]] || die "provision.provider=digitalocean needs \$DIGITALOCEAN_TOKEN"
  [[ -n ${DO_SSH_KEY_ID} ]] || die "config: provision.digitalocean.ssh_key_id is required for provider=digitalocean"
fi
if [[ ${DNS_PROVIDER} == cloudflare ]]; then
  [[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || die "dns.provider=cloudflare needs \$CLOUDFLARE_API_TOKEN"
  [[ -n ${DNS_ZONE} ]] || die "config: dns.zone is required for dns.provider=cloudflare"
fi
if [[ ${SRC_MODE} == git-ssh ]]; then
  [[ -n ${DEPLOY_KEY} ]] || die "source.mode=git-ssh needs source.deploy_key_path in the config"
  [[ -f ${DEPLOY_KEY} ]] || die "deploy key not found: ${DEPLOY_KEY}"
fi
# Checked HERE, before a VM is created and billed — setup-host.sh would
# otherwise only discover a missing certificate after the droplet exists.
if [[ ${CADDY_ENABLE} == true ]]; then
  [[ -n ${INGRESS_CERT} ]] || die "ingress.caddy needs ingress.tls_cert_path (the Cloudflare Origin CA certificate — there is no ACME fallback)"
  [[ -n ${INGRESS_KEY} ]] || die "ingress.caddy needs ingress.tls_key_path (the origin certificate's private key)"
  [[ -f ${INGRESS_CERT} ]] || die "origin certificate not found: ${INGRESS_CERT}"
  [[ -f ${INGRESS_KEY} ]] || die "origin certificate key not found: ${INGRESS_KEY}"
  # READABILITY, not just existence. This script runs as the control plane's
  # unprivileged service user and scp's the key to the tenant VM, so a
  # root-only 0600 key fails LATER — after the droplet exists and has been
  # paid for — with an opaque `scp: Permission denied`. Checking here turns
  # that into an actionable pre-flight error with no VM created.
  [[ -r ${INGRESS_CERT} ]] || die "origin certificate is not readable by $(id -un): ${INGRESS_CERT} (chgrp it to this user and chmod 0640)"
  [[ -r ${INGRESS_KEY} ]] || die "origin certificate key is not readable by $(id -un): ${INGRESS_KEY} (chgrp it to this user and chmod 0640)"
fi
# Same reasoning, same place, for the external-database CA. It matters MORE
# here than for the origin certificate: a tenant DSN using sslmode=verify-full
# has no fallback, so a CA that never arrives is not a degradation but a total
# connection failure on a VM that has already been created and billed.
if [[ -n ${DB_CA_PATH} ]]; then
  [[ -f ${DB_CA_PATH} ]] || die "database.ca_path: CA certificate not found: ${DB_CA_PATH}"
  [[ -r ${DB_CA_PATH} ]] || die "database.ca_path: CA certificate is not readable by $(id -un): ${DB_CA_PATH} (a CA certificate is public — chmod 0644)"
fi
if [[ ${RT_SANDBOX} == vm && ${EXE_SECTION_PRESENT} -eq 1 ]]; then
  # Tolerate an empty runtime.exe.ssh_key_path when there's no TTY to prompt
  # at (see resolve_exe_key_path in lib.sh): a headless caller — e.g. the
  # platform control plane's job executor — legitimately omits it for the
  # BYO tier, whose exe machines are registered by the tenant post-handoff
  # rather than provisioned here. EXE_KEY staying empty is already handled
  # by every downstream use of it (the push-to-VM steps above are all
  # `-n ${EXE_KEY}`-gated).
  EXE_KEY=$(resolve_exe_key_path "${RT_SANDBOX}" "${EXE_KEY}" \
    "path to the exe.dev account SSH key (runtime.exe.ssh_key_path unset)")
  [[ -z ${EXE_KEY} || -f ${EXE_KEY} ]] || die "exe SSH key not found: ${EXE_KEY}"
fi
if [[ ${AI_PROVIDER} != openai-codex && -n ${AI_KEY_ENV} && -z ${!AI_KEY_ENV:-} ]]; then
  if is_tty; then
    log_warn "\$${AI_KEY_ENV} is unset — setup on the VM has no TTY to prompt; provide it now"
    prompt_value "API key for ${AI_PROVIDER} (\$${AI_KEY_ENV})" _prompted_key silent
    [[ -n ${_prompted_key} ]] || die "no API key provided"
    export "${AI_KEY_ENV}=${_prompted_key}"
  else
    die "\$${AI_KEY_ENV} must be set for unattended provisioning (headless setup requires an api-key provider)"
  fi
fi

ssh_key_opts "${ACCOUNT_KEY}"
SSH_BASE=(ssh "${SSH_KEY_OPTS[@]}" -o BatchMode=yes)
SCP_BASE=(scp "${SSH_KEY_OPTS[@]}" -o BatchMode=yes -q)

vm_ssh_ok() { "${SSH_BASE[@]}" -o ConnectTimeout=5 "${SSH_USER}@${VM_HOST}" true; }

# ---------------------------------------------------------------- step 1: VM

# Machine-readable IP contract for callers that parse this script's output
# (the platform control plane's job executor persists it to
# tenants.server_ip). Deliberately printed TWICE on the IP-based providers:
#
#   1. HERE — the moment the VM is known to exist, before any host setup.
#      Steps 3-5 run for many minutes and are where provisions actually fail,
#      and the VM is alive and billing throughout. Without this early line a
#      mid-setup failure leaves a running VM the cleanup path cannot reach
#      over SSH (the production symptom: "tenant … has no serverIp — cannot
#      ssh" against a live droplet). It is emitted on the reuse path too —
#      re-writing the same IP is idempotent for every caller.
#   2. As the LAST line of stdout on success (see the tail of this file),
#      which is the older half of the contract.
#
# stdout only, and never for exe (its VM_HOST is a *.exe.xyz hostname, not an
# IP; that path's output must stay byte-identical).
emit_server_ip() { # IP
  printf 'SERVER_IP=%s\n' "$1"
}

# PROVIDER SEAM: add new VM providers as provision_vm_<provider>() and extend
# the dispatch below.
provision_vm() {
  case "${PROVIDER}" in
    exe) provision_vm_exe ;;
    hetzner) provision_vm_hetzner ;;
    digitalocean) provision_vm_digitalocean ;;
    *) die "provision.provider '${PROVIDER}' is not implemented (only: exe, hetzner, digitalocean)" ;;
  esac
}

provision_vm_exe() {
  if vm_ssh_ok >/dev/null 2>&1; then
    log_info "${VM_HOST} already answers SSH — reusing existing VM (idempotent re-run)"
    return 0
  fi
  log_info "creating exe VM '${VM_NAME}' from ${MACHINE_IMAGE} (public image, no --registry-auth)"
  local out
  if out=$("${SSH_BASE[@]}" exe.dev new --name "${VM_NAME}" --image "${MACHINE_IMAGE}" --json 2>&1); then
    log_info "exe.dev: $(jq -c '.' <<<"${out}" 2>/dev/null || printf '%s' "${out}")"
  else
    log_warn "exe.dev new failed (${out}) — the VM may already exist; waiting for SSH anyway"
  fi
}

# ------------------------------------------------------------- hetzner (hcloud)

# Return-1 (never die) on any non-200 — including a transient 5xx — so a
# blip during boot polling just means "not ready yet, try again", not an
# aborted run. (Finding 2: this used to go through http_bearer_expect, whose
# die() on an unexpected status fired *inside* the poll loop below, where
# stdout/stderr are redirected to /dev/null — a transient hcloud 5xx silently
# killed the whole script with no visible message.)
hcloud_server_get() { # ID
  http_bearer_request "${HCLOUD_API_BASE}" "${HCLOUD_TOKEN}" GET "/servers/$1" '' || return 1
  [[ ${HTTP_STATUS} == 200 ]] || return 1
  return 0
}

_HCLOUD_POLL_IP=''
_HCLOUD_POLL_STATUS=''
_hcloud_poll_once() { # ID
  hcloud_server_get "$1" || return 1
  local status id ip
  read -r status id ip <<<"$(hcloud_server_status_id_ip "${HTTP_BODY}")"
  _HCLOUD_POLL_STATUS=${status}
  [[ ${status} == running && -n ${ip} ]] || return 1
  _HCLOUD_POLL_IP=${ip}
  return 0
}

# Poll GET /servers/<id> every 5s (timeout 300s) until status=running with a
# public IPv4. Deliberately NOT retry_until: each poll attempt's output is
# still swallowed (>/dev/null 2>&1, same noise suppression retry_until would
# give), but the terminal-state check and die() run in THIS frame, between
# attempts — not inside the swallowed one — so a server landing in a terminal
# bad state (off/error/deleting) dies immediately, with a visible message
# naming the observed status, instead of silently polling to the full 300s
# timeout (Finding 3).
_hcloud_wait_running() { # ID
  local id=$1 timeout=300 interval=5 waited=0
  while true; do
    _hcloud_poll_once "${id}" >/dev/null 2>&1 && return 0
    case "${_HCLOUD_POLL_STATUS}" in
      off | error | deleting)
        die "hcloud server '${VM_NAME}' (id=${id}) landed in terminal state '${_HCLOUD_POLL_STATUS}' — will never become running"
        ;;
    esac
    ((waited >= timeout)) &&
      die "timed out after ${timeout}s waiting for hcloud server '${VM_NAME}' (id=${id}) to become running"
    sleep "${interval}"
    waited=$((waited + interval))
  done
}

provision_vm_hetzner() {
  http_bearer_expect "${HCLOUD_API_BASE}" "${HCLOUD_TOKEN}" GET \
    "/servers?name=${VM_NAME}" '' '200' "hcloud: list servers named '${VM_NAME}'"
  local status id ip
  read -r status id ip <<<"$(hcloud_server_lookup "${HTTP_BODY}")"

  if [[ -n ${id} ]]; then
    log_info "hcloud server '${VM_NAME}' already exists (id=${id}, status=${status}) — reusing (idempotent re-run)"
  else
    log_info "creating hcloud server '${VM_NAME}' (${HZ_SERVER_TYPE}/${HZ_LOCATION}/${HZ_IMAGE}, ssh_keys=[${HZ_SSH_KEY_NAME}])"
    local create_body
    create_body=$(hcloud_server_create_body "${VM_NAME}" "${HZ_SERVER_TYPE}" "${HZ_LOCATION}" "${HZ_IMAGE}" "${HZ_SSH_KEY_NAME}")
    http_bearer_expect "${HCLOUD_API_BASE}" "${HCLOUD_TOKEN}" POST '/servers' \
      "${create_body}" '201' "hcloud: create server '${VM_NAME}'"
    read -r status id ip <<<"$(hcloud_server_status_id_ip "${HTTP_BODY}")"
    [[ -n ${id} ]] || die "hcloud: create response for '${VM_NAME}' is missing a server id: ${HTTP_BODY}"
  fi

  _hcloud_wait_running "${id}"
  VM_HOST=${_HCLOUD_POLL_IP}
  log_info "hcloud server '${VM_NAME}' is running at ${VM_HOST}"
  emit_server_ip "${VM_HOST}"

  if [[ -n ${DNS_PROVIDER} ]]; then
    log_step "DNS: upsert A record (${DNS_PROVIDER})"
    dns_upsert_a_record "${DNS_HOST}" "${VM_HOST}"
  fi
}

# ------------------------------------------------------------- digitalocean

# Same never-die, return-1-on-non-200 doctrine as hcloud_server_get above:
# a transient 5xx during boot polling must mean "try again", not "abort the
# whole run" — see that function's comment for the full reasoning.
do_droplet_get() { # ID
  http_bearer_request "${DO_API_BASE}" "${DIGITALOCEAN_TOKEN}" GET "/droplets/$1" '' || return 1
  [[ ${HTTP_STATUS} == 200 ]] || return 1
  return 0
}

_DO_POLL_IP=''
_DO_POLL_STATUS=''
_do_poll_once() { # ID
  do_droplet_get "$1" || return 1
  local status id ip
  read -r status id ip <<<"$(do_droplet_status_id_ip "${HTTP_BODY}")"
  _DO_POLL_STATUS=${status}
  [[ ${status} == active && -n ${ip} ]] || return 1
  _DO_POLL_IP=${ip}
  return 0
}

# Poll GET /droplets/<id> every 5s (timeout 300s) until status=active with a
# public IPv4. Mirrors _hcloud_wait_running's terminal-state fast-fail (see
# its comment): 'archive' is DO's "gone" state — a droplet landing there will
# never become active, so die immediately with the observed status instead
# of polling to the full timeout.
_do_wait_active() { # ID
  local id=$1 timeout=300 interval=5 waited=0
  while true; do
    _do_poll_once "${id}" >/dev/null 2>&1 && return 0
    case "${_DO_POLL_STATUS}" in
      archive)
        die "digitalocean droplet '${VM_NAME}' (id=${id}) landed in terminal state '${_DO_POLL_STATUS}' — will never become active"
        ;;
    esac
    ((waited >= timeout)) &&
      die "timed out after ${timeout}s waiting for digitalocean droplet '${VM_NAME}' (id=${id}) to become active"
    sleep "${interval}"
    waited=$((waited + interval))
  done
}

# File the droplet under provision.digitalocean.project_id (droplet-create has
# no project field, so this is a separate call — see do_project_assign_body).
#
# DELIBERATELY BEST-EFFORT: project membership is cosmetic grouping in the DO
# console, while the droplet it would group is already created and already
# being paid for. Failing the provision here would orphan that droplet over a
# label, so every failure warns and returns 0 instead. Re-assignment is a
# no-op on DO's side and this runs on the reuse path too, so a retried
# provision simply re-assigns.
do_project_assign() { # DROPLET_ID
  [[ -n ${DO_PROJECT_ID} ]] || return 0
  local id=$1 body
  body=$(do_project_assign_body "${id}")
  if ! http_bearer_request "${DO_API_BASE}" "${DIGITALOCEAN_TOKEN}" POST \
    "/projects/${DO_PROJECT_ID}/resources" "${body}"; then
    log_warn "digitalocean: project-assignment request for droplet ${id} failed (network) — continuing; the droplet stays in its current project"
    return 0
  fi
  case "${HTTP_STATUS}" in
    200 | 201 | 202)
      log_info "digitalocean: droplet ${id} assigned to project ${DO_PROJECT_ID}"
      ;;
    *)
      log_warn "digitalocean: could not assign droplet ${id} to project ${DO_PROJECT_ID} (HTTP ${HTTP_STATUS}: ${HTTP_BODY}) — continuing; assign it by hand or re-run to retry"
      ;;
  esac
}

provision_vm_digitalocean() {
  http_bearer_expect "${DO_API_BASE}" "${DIGITALOCEAN_TOKEN}" GET \
    "/droplets?tag_name=${DO_TAG}" '' '200' "digitalocean: list droplets tagged '${DO_TAG}'"
  local status id ip
  read -r status id ip <<<"$(do_droplet_lookup "${HTTP_BODY}" "${VM_NAME}")"

  if [[ -n ${id} ]]; then
    log_info "digitalocean droplet '${VM_NAME}' already exists (id=${id}, status=${status}) — reusing (idempotent re-run)"
  else
    # Ordered fallback: primary (size/region) first, then
    # provision.digitalocean.fallbacks[] in config order. A capacity/
    # availability error (do_is_capacity_error) advances to the next entry;
    # anything else (bad auth, invalid image, ...) dies immediately — a
    # broken credential shouldn't burn through every fallback first.
    local attempts=("${DO_SIZE} ${DO_REGION}") fb entry attempt_size attempt_region
    while IFS= read -r fb; do
      [[ -n ${fb} ]] && attempts+=("${fb}")
    done <<<"${DO_FALLBACKS}"

    local total=${#attempts[@]} i=0 succeeded=0
    for entry in "${attempts[@]}"; do
      i=$((i + 1))
      read -r attempt_size attempt_region <<<"${entry}"
      log_info "creating digitalocean droplet '${VM_NAME}' (${attempt_size}/${attempt_region}/${DO_IMAGE}, ssh_keys=[${DO_SSH_KEY_ID}]) [attempt ${i}/${total}]"
      local create_body
      create_body=$(do_droplet_create_body "${VM_NAME}" "${attempt_region}" "${attempt_size}" "${DO_IMAGE}" "${DO_SSH_KEY_ID}" "${DO_TAG}" "${DO_VPC_UUID}")
      http_bearer_request "${DO_API_BASE}" "${DIGITALOCEAN_TOKEN}" POST '/droplets' "${create_body}" ||
        die "digitalocean: create droplet '${VM_NAME}' request failed (network)"
      if [[ ${HTTP_STATUS} == 201 || ${HTTP_STATUS} == 202 ]]; then
        read -r status id ip <<<"$(do_droplet_status_id_ip "${HTTP_BODY}")"
        [[ -n ${id} ]] || die "digitalocean: create response for '${VM_NAME}' is missing a droplet id: ${HTTP_BODY}"
        log_info "digitalocean: '${VM_NAME}' created using ${attempt_size}/${attempt_region} (attempt ${i}/${total})"
        succeeded=1
        break
      fi
      if do_is_capacity_error "${HTTP_STATUS}" "${HTTP_BODY}"; then
        log_warn "digitalocean: ${attempt_size}/${attempt_region} unavailable (HTTP ${HTTP_STATUS}: ${HTTP_BODY}) — trying the next fallback"
        continue
      fi
      if do_is_account_limit_error "${HTTP_STATUS}" "${HTTP_BODY}"; then
        die_permanent "digitalocean: the account droplet limit is reached — create droplet '${VM_NAME}' refused: HTTP ${HTTP_STATUS}: ${HTTP_BODY}. Raise the limit in the DigitalOcean console; retrying cannot succeed"
      fi
      die "digitalocean: create droplet '${VM_NAME}' failed: HTTP ${HTTP_STATUS}: ${HTTP_BODY}"
    done
    [[ ${succeeded} -eq 1 ]] ||
      die "digitalocean: exhausted all ${total} size/region attempts for '${VM_NAME}' (tried: ${attempts[*]}) — all unavailable"
  fi

  # Runs on BOTH branches (fresh create and idempotent reuse), so a droplet
  # that was created before project_id was configured — or one whose earlier
  # assignment failed — gets filed on the next run.
  do_project_assign "${id}"

  _do_wait_active "${id}"
  VM_HOST=${_DO_POLL_IP}
  log_info "digitalocean droplet '${VM_NAME}' is running at ${VM_HOST}"
  emit_server_ip "${VM_HOST}"

  if [[ -n ${DNS_PROVIDER} ]]; then
    log_step "DNS: upsert A record (${DNS_PROVIDER})"
    dns_upsert_a_record "${DNS_HOST}" "${VM_HOST}"
  fi
}

# ------------------------------------------------------------------ DNS (cloudflare)

# PROVIDER SEAM: add new DNS providers as dns_upsert_a_record_<provider>() and
# extend the dispatch below.
dns_upsert_a_record() { # HOST IP
  case "${DNS_PROVIDER}" in
    cloudflare) dns_upsert_a_record_cloudflare "$1" "$2" ;;
    *) die "dns.provider '${DNS_PROVIDER}' is not implemented (only: cloudflare)" ;;
  esac
}

dns_upsert_a_record_cloudflare() { # HOST IP
  local host=$1 ip=$2

  http_bearer_expect "${CF_API_BASE}" "${CLOUDFLARE_API_TOKEN}" GET \
    "/zones?name=${DNS_ZONE}" '' '200' "cloudflare: resolve zone id for '${DNS_ZONE}'"
  local zone_id
  zone_id=$(cf_zone_id_from_list "${HTTP_BODY}")
  [[ -n ${zone_id} ]] || die "cloudflare: zone '${DNS_ZONE}' not found (check dns.zone and \$CLOUDFLARE_API_TOKEN's access)"

  http_bearer_expect "${CF_API_BASE}" "${CLOUDFLARE_API_TOKEN}" GET \
    "/zones/${zone_id}/dns_records?type=A&name=${host}" '' '200' "cloudflare: look up existing A record for '${host}'"
  local record_id body
  record_id=$(cf_dns_record_id_from_list "${HTTP_BODY}")
  body=$(cf_dns_record_body "${host}" "${ip}")

  if [[ -n ${record_id} ]]; then
    log_info "cloudflare: updating A ${host} → ${ip} (record ${record_id})"
    http_bearer_expect "${CF_API_BASE}" "${CLOUDFLARE_API_TOKEN}" PUT \
      "/zones/${zone_id}/dns_records/${record_id}" "${body}" '200' "cloudflare: update A record for '${host}'"
  else
    log_info "cloudflare: creating A ${host} → ${ip}"
    http_bearer_expect "${CF_API_BASE}" "${CLOUDFLARE_API_TOKEN}" POST \
      "/zones/${zone_id}/dns_records" "${body}" '200' "cloudflare: create A record for '${host}'"
  fi
}

log_step "step 1/5: provision VM (${PROVIDER})"
provision_vm

log_step "step 2/5: wait for SSH at ${SSH_USER}@${VM_HOST}"
retry_until 300 5 "SSH to ${SSH_USER}@${VM_HOST}" vm_ssh_ok ||
  die "VM never became reachable over SSH"
log_info "SSH is up"

# ------------------------------------------------------- step 3: push files

SECRETS_PUSHED=0
cleanup_remote_secrets() {
  if [[ ${SECRETS_PUSHED} -eq 1 ]]; then
    "${SSH_BASE[@]}" "${SSH_USER}@${VM_HOST}" "rm -f ${REMOTE_DIR}/secrets.env" 2>/dev/null || true
  fi
}
trap cleanup_remote_secrets EXIT

log_step "step 3/5: push toolkit + config + credentials"
"${SSH_BASE[@]}" "${SSH_USER}@${VM_HOST}" "mkdir -p ${REMOTE_DIR}/systemd ${REMOTE_DIR}/keys && chmod 700 ${REMOTE_DIR} ${REMOTE_DIR}/keys"

# The source tree itself is NEVER copied from here (git clone on the target
# avoids macOS AppleDouble '._*' files that crash config-sync YAML parsing);
# Assert every toolkit file exists BEFORE anything is pushed. Four separate
# provisions have now failed late — after the droplet was created, paid for,
# and fully set up — because a file setup-host.sh renders was never sent. A
# missing file is an operator error, not a runtime condition; catching it here
# turns a 10-minute failed provision into an immediate, named error.
for _f in \
  "${SCRIPT_DIR}/lib.sh" \
  "${SCRIPT_DIR}/setup-host.sh" \
  "${SCRIPT_DIR}/seed.sh" \
  "${SCRIPT_DIR}/tau-backup.sh.tmpl" \
  "${SCRIPT_DIR}/systemd/tau-api.service.tmpl" \
  "${SCRIPT_DIR}/systemd/tau-worker.service.tmpl" \
  "${SCRIPT_DIR}/systemd/tau-backup.service.tmpl" \
  "${SCRIPT_DIR}/systemd/tau-backup.timer.tmpl"; do
  [[ -f ${_f} ]] || die "toolkit file missing, cannot provision: ${_f}"
done
unset _f

# only the toolkit, config, and small key files move — with COPYFILE_DISABLE=1.
export COPYFILE_DISABLE=1
# tau-backup.sh.tmpl belongs in THIS list: setup-host.sh's backup phase seds it
# from ${SCRIPT_DIR} on the VM (setup-host.sh:498). Omitting it failed the
# provision at phase 6.6 with a bare
#   sed: can't read /root/tau-setup/tau-backup.sh.tmpl: No such file or directory
# after the instance was otherwise fully built — services up, caddy serving.
"${SCP_BASE[@]}" "${SCRIPT_DIR}/lib.sh" "${SCRIPT_DIR}/setup-host.sh" "${SCRIPT_DIR}/seed.sh" \
  "${SCRIPT_DIR}/tau-backup.sh.tmpl" \
  "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/"
# Every template setup-host.sh renders on the VM. tau-backup.{service,timer}
# were omitted, so the backup phase died on a missing file AFTER the instance
# was fully built. Include every template rendered by instance setup.
"${SCP_BASE[@]}" "${SCRIPT_DIR}/systemd/tau-api.service.tmpl" "${SCRIPT_DIR}/systemd/tau-worker.service.tmpl" \
  "${SCRIPT_DIR}/systemd/tau-backup.service.tmpl" "${SCRIPT_DIR}/systemd/tau-backup.timer.tmpl" \
  "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/systemd/"

# Rewrite key paths in the pushed config to their locations on the VM.
REWRITTEN_CFG=$(mktemp)
cp "${CFG_FILE}" "${REWRITTEN_CFG}"
if [[ ${SRC_MODE} == git-ssh && -n ${DEPLOY_KEY} ]]; then
  yq -i ".source.deploy_key_path = \"${REMOTE_DIR}/keys/deploy_key\"" "${REWRITTEN_CFG}"
  "${SCP_BASE[@]}" "${DEPLOY_KEY}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/keys/deploy_key"
fi
if [[ ${RT_SANDBOX} == vm && -n ${EXE_KEY} ]]; then
  yq -i ".runtime.exe.ssh_key_path = \"${REMOTE_DIR}/keys/exe_key\"" "${REWRITTEN_CFG}"
  "${SCP_BASE[@]}" "${EXE_KEY}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/keys/exe_key"
fi
if [[ ${CADDY_ENABLE} == true ]]; then
  yq -i ".ingress.tls_cert_path = \"${REMOTE_DIR}/keys/origin_cert.pem\"" "${REWRITTEN_CFG}"
  yq -i ".ingress.tls_key_path = \"${REMOTE_DIR}/keys/origin_key.pem\"" "${REWRITTEN_CFG}"
  "${SCP_BASE[@]}" "${INGRESS_CERT}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/keys/origin_cert.pem"
  "${SCP_BASE[@]}" "${INGRESS_KEY}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/keys/origin_key.pem"
fi
if [[ -n ${DB_CA_PATH} ]]; then
  yq -i ".database.ca_path = \"${REMOTE_DIR}/keys/database_ca.pem\"" "${REWRITTEN_CFG}"
  "${SCP_BASE[@]}" "${DB_CA_PATH}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/keys/database_ca.pem"
fi
# Platform-managed artifacts: push the whole staging dir (managed.env + files/
# + manifest) recursively, then lock it down root-only (it holds credentials,
# like keys/ above) and rewrite the config path to the pushed location so
# setup-host.sh's phase_artifacts installs from there.
if [[ -n ${ARTIFACTS_DIR} ]]; then
  "${SCP_BASE[@]}" -r "${ARTIFACTS_DIR}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/artifacts"
  "${SSH_BASE[@]}" "${SSH_USER}@${VM_HOST}" "chmod -R go-rwx ${REMOTE_DIR}/artifacts 2>/dev/null || true"
  yq -i ".artifacts.dir = \"${REMOTE_DIR}/artifacts\"" "${REWRITTEN_CFG}"
fi
"${SCP_BASE[@]}" "${REWRITTEN_CFG}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/tau-setup.yaml"
rm -f "${REWRITTEN_CFG}"
"${SSH_BASE[@]}" "${SSH_USER}@${VM_HOST}" "chmod 600 ${REMOTE_DIR}/keys/* 2>/dev/null || true"

# Secrets env file (0600, removed after the run).
SECRETS_TMP=$(mktemp)
{
  for name in "${FORWARD_ENVS[@]}"; do
    if [[ -n ${!name:-} ]]; then
      # Single-quoted (sh_single_quote), for the same reason backup.env is:
      # REMOTE_CMD `source`s this file. A tenant DSN carries
      # `?sslmode=verify-full&sslrootcert=…`, and written bare the `&` is a
      # shell metacharacter — bash backgrounds the assignment at the `&`, so
      # the variable arrives UNSET on the target while the remainder parses as
      # a second, harmless assignment. No syntax error, no warning, nothing in
      # the log. That silence cost a live provision, which died with
      # "database.mode=external needs database.dsn" while the DSN was in fact
      # being forwarded correctly.
      printf '%s=%s\n' "${name}" "$(sh_single_quote "${!name}")"
    fi
  done
} >"${SECRETS_TMP}"
if [[ -s ${SECRETS_TMP} ]]; then
  "${SCP_BASE[@]}" "${SECRETS_TMP}" "${SSH_USER}@${VM_HOST}:${REMOTE_DIR}/secrets.env"
  "${SSH_BASE[@]}" "${SSH_USER}@${VM_HOST}" "chmod 600 ${REMOTE_DIR}/secrets.env"
  SECRETS_PUSHED=1
fi
rm -f "${SECRETS_TMP}"
log_info "pushed toolkit, config, keys$( ((SECRETS_PUSHED)) && printf ', secrets.env')"

# ---------------------------------------------------------- step 4: run setup

log_step "step 4/5: run setup-host.sh on ${VM_HOST} (streaming output)"
"${SSH_BASE[@]}" "${SSH_USER}@${VM_HOST}" "${REMOTE_CMD}"

# ------------------------------------------------------------- step 5: done

log_step "step 5/5: cleanup + handoff"
cleanup_remote_secrets
SECRETS_PUSHED=0

cat <<EOF

================================================================================
 Tenant provisioned.

   URL:  ${CORE_ORIGIN}

 Hand this to the human owner: open the URL and create the first admin
 passkey. The bootstrap token printed by setup-host.sh above self-disables
 the moment that passkey exists.

 VM:    ${SSH_USER}@${VM_HOST}  (ssh with the configured account key)
================================================================================
EOF

# Orchestrator contract (see the interfaces block in the task-4 brief): on the
# hetzner/digitalocean paths VM_HOST is the bare IPv4 assigned by
# provision_vm_hetzner()/provision_vm_digitalocean(), so print it as the LAST
# line of stdout, after everything else, for callers that parse this script's
# output. exe.dev's VM_HOST is a *.exe.xyz hostname, not an IP, and the exe
# path has no such contract — its output must stay byte-identical, so this is
# gated to the IP-based providers only. This repeats the line those functions
# already emitted the moment the VM existed (see emit_server_ip) — same value,
# and parsers must tolerate seeing it more than once.
if [[ ${PROVIDER} == hetzner || ${PROVIDER} == digitalocean ]]; then
  emit_server_ip "${VM_HOST}"
fi
