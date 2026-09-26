#!/usr/bin/env bash
# seed.sh — seed a freshly-installed tau instance via the FICUS_PASSWORD
# bootstrap bearer (fully privileged until the first admin passkey exists):
#
#   1. AI provider account   POST /api/provider-auth/<provider>/accounts
#                             (optional: only when ai.model is configured)
#   2. exe SSH key secret    PUT  /api/secrets/exe-provider-ssh-key   (vm runtime)
#   3. starter squad         POST /api/squads
#                             (optional: only when squad.name is configured)
#   4. starter agent         POST /api/squads/<id>/spawn
#                             (optional: only when squad.name is configured)
#
# Steps 1/3/4 are opt-in: self-hosters who explicitly configure ai.model /
# squad.name keep today's behaviour; a config with neither seeds nothing —
# the in-app onboarding checklist is the path for everyone else. Idempotent:
# every step checks before creating, and the whole script is a safe no-op
# once the first admin passkey exists (the bootstrap bearer self-disables at
# that point). Called by setup-host.sh, but also usable standalone against a
# running instance.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: seed.sh --config tau-setup.yaml [options]

Seeds an exe SSH key secret, and — only when explicitly configured — an AI
provider account and/or a starter squad + agent, on a running tau instance,
using the FICUS_PASSWORD bootstrap bearer. A config with no ai.model and no
squad.name skips both cleanly (the in-app onboarding checklist is the path
instead).

Options:
  --config FILE     tau-setup.yaml (required; see tau-setup.example.yaml)
  --env-file FILE   .env holding FICUS_PASSWORD (default: <source.dest>/.env)
  --api-url URL     API base URL (default: http://127.0.0.1:<core.port>)
  --dry-run         print what would be seeded, without calling the API
  -h, --help        show this help

Secrets: the bearer comes from $FICUS_PASSWORD or the env file; the AI key from
the env var named by ai.key_env in the config (prompted on a TTY if unset).
EOF
}

CONFIG='' ENV_FILE='' API_URL='' DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG=${2:?--config needs a value}
      shift 2
      ;;
    --env-file)
      ENV_FILE=${2:?--env-file needs a value}
      shift 2
      ;;
    --api-url)
      API_URL=${2:?--api-url needs a value}
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

[[ -n ${CONFIG} ]] || {
  usage >&2
  die "--config is required"
}

require_cmd curl
require_cmd jq
cfg_load "${CONFIG}"

# ---------------------------------------------------------------- config

# Presence probes for the two opt-in sections — an absent section reads as
# the empty string via cfg_get's default, exactly like the file's other
# optional-section probes (e.g. runtime.exe.ssh_key_path). The AI probe keys
# off ai.model specifically, NOT ai.provider: ai.provider has a non-empty
# default of its own ('openai'), and ai.model is the field that was
# unconditionally required pre-change — so a config that sets ONLY
# ai.model (relying on the provider default) must still opt in. squad.name
# has no default at all: an explicit squad.name is the opt-in for the
# starter squad + agent.
AI_MODEL=$(cfg_get '.ai.model' '')
AI_SECTION_PRESENT=0
[[ -n ${AI_MODEL} ]] && AI_SECTION_PRESENT=1

AI_PROVIDER=$(cfg_get '.ai.provider' 'openai')
case "${AI_PROVIDER}" in
  openai) AI_KEY_ENV_DEFAULT='OPENAI_API_KEY' ;;
  anthropic) AI_KEY_ENV_DEFAULT='ANTHROPIC_API_KEY' ;;
  openai-codex) AI_KEY_ENV_DEFAULT='' ;;
  *) die "config: ai.provider must be openai, anthropic, or openai-codex (got '${AI_PROVIDER}')" ;;
esac
AI_KEY_ENV=$(cfg_get '.ai.key_env' "${AI_KEY_ENV_DEFAULT}")
SQUAD_NAME=$(cfg_get '.squad.name' '')
SQUAD_PURPOSE=$(cfg_get '.squad.purpose' 'first squad for the new tenant')
AGENT_TYPE=$(cfg_get '.squad.agent.type' 'engineer')
AGENT_MODEL=$(cfg_get '.squad.agent.model' "${AI_MODEL}")
# REQUIRED and explicit — no default, and validated against the SAME five values
# the core accepts (lib.sh's require_sandbox_runtime, shared with setup-host.sh).
RT_SANDBOX=$(trim_ws "$(cfg_get '.runtime.sandbox')") # compared against `vm` below; padding would silently mis-compare
require_sandbox_runtime "${RT_SANDBOX}"
EXE_KEY_PATH=$(expand_tilde "$(cfg_get '.runtime.exe.ssh_key_path')")
CORE_PORT=$(cfg_get '.core.port' '3000')
SRC_DEST=$(expand_tilde "$(cfg_get '.source.dest' '/opt/tau')")

# A squad is configured but there is no model to spawn its agent with — ai:
# is absent/opted-out AND squad.agent.model was not set explicitly either.
# Fail fast here with a clear message; left unguarded this reaches
# api_expect deep inside the squad block and dies on a raw HTTP 400 from the
# spawn call instead.
if [[ -n ${SQUAD_NAME} && -z ${AGENT_MODEL} ]]; then
  die "squad.name is set ('${SQUAD_NAME}') but no model is configured for its agent — set squad.agent.model, or set ai.model to opt in to AI provider seeding (squad.agent.model defaults to it)"
fi

# Guard the #1 headless footgun: an agent whose model needs OAuth. Only
# meaningful when a squad is actually going to be created.
if [[ -n ${SQUAD_NAME} && ${AI_PROVIDER} != openai-codex && ${AGENT_MODEL} == openai-codex:* ]]; then
  die "squad.agent.model (${AGENT_MODEL}) is an openai-codex model but ai.provider is ${AI_PROVIDER} — the starter agent's model must match the seeded api-key provider"
fi

[[ -n ${ENV_FILE} ]] || ENV_FILE="${SRC_DEST}/.env"
[[ -n ${API_URL} ]] || API_URL="http://127.0.0.1:${CORE_PORT}"

# ---------------------------------------------------------------- dry run

if [[ ${DRY_RUN} -eq 1 ]]; then
  log_step "seed plan (dry run — no API calls)"
  plan "API:            ${API_URL} (bearer from \$FICUS_PASSWORD or ${ENV_FILE})"
  if [[ ${AI_SECTION_PRESENT} -eq 0 ]]; then
    plan "provider:       no ai.model in config — SKIP (self-hosters opt in with ai.model; onboarding collects a provider key in-app instead)"
  elif [[ ${AI_PROVIDER} == openai-codex ]]; then
    plan "provider:       openai-codex — SKIP key seeding (needs interactive ChatGPT OAuth);"
    plan "                would print instructions to finish via Settings > AI Providers"
  else
    plan "provider:       POST /api/provider-auth/${AI_PROVIDER}/accounts {key: \$${AI_KEY_ENV} ($(redact_secret "${!AI_KEY_ENV:-}")), label: setup}"
  fi
  if [[ ${RT_SANDBOX} == vm ]]; then
    if [[ -n ${EXE_KEY_PATH} ]]; then
      plan "exe key:        PUT /api/secrets/exe-provider-ssh-key (value from ${EXE_KEY_PATH})"
    else
      plan "exe key:        <unset> — would skip (BYO tier: exe machines are registered post-handoff)"
    fi
  fi
  if [[ -n ${SQUAD_NAME} ]]; then
    plan "squad:          POST /api/squads {name: ${SQUAD_NAME}, purpose: ${SQUAD_PURPOSE}}"
    plan "agent:          POST /api/squads/<id>/spawn {agentTypeId: ${AGENT_TYPE}, model: ${AGENT_MODEL}}"
  else
    plan "squad:          no squad.name in config — SKIP (self-hosters opt in with squad.name; onboarding creates the first squad in-app instead)"
  fi
  plan "idempotency:    each step checks before creating; no-op once an admin passkey exists"
  exit 0
fi

# ---------------------------------------------------------------- bearer

FICUS_API_BASE=${API_URL}
FICUS_BEARER=${FICUS_PASSWORD:-}
if [[ -z ${FICUS_BEARER} ]]; then
  FICUS_BEARER=$(envfile_get "${ENV_FILE}" 'FICUS_PASSWORD') ||
    die "no bearer: set \$FICUS_PASSWORD or provide --env-file with FICUS_PASSWORD (looked in ${ENV_FILE})"
fi
[[ -n ${FICUS_BEARER} ]] || die "FICUS_PASSWORD is empty — cannot authenticate seeding requests"

retry_until 30 2 "API up at ${API_URL}" api_is_up "${API_URL}" ||
  die "tau API is not reachable at ${API_URL}"

# Once an admin exists the bootstrap bearer is dead — seeding is a no-op.
AUTH_STATUS=$(curl -sS --max-time 10 "${API_URL}/api/auth/status")
if [[ $(jq -r '.hasAdminUser' <<<"${AUTH_STATUS}") == 'true' ]]; then
  log_info "an admin user already exists — the bootstrap bearer is disabled; nothing to seed"
  exit 0
fi

# ---------------------------------------------------------------- provider

if [[ ${AI_SECTION_PRESENT} -eq 0 ]]; then
  log_info "no ai.model in config — skipping AI provider seeding (set ai.model to opt in, or configure a provider later via Settings > AI Providers)"
elif [[ ${AI_PROVIDER} == openai-codex ]]; then
  log_step "seeding AI provider account (${AI_PROVIDER})"
  log_warn "ai.provider=openai-codex requires an interactive ChatGPT OAuth login — skipping key seeding (unattended)"
  log_warn "after creating your admin passkey, open Settings > AI Providers > OpenAI Codex and complete the OAuth flow"
  log_warn "headless setups should use an api-key provider instead (openai or anthropic)"
else
  log_step "seeding AI provider account (${AI_PROVIDER})"
  api_expect GET "/api/provider-auth/${AI_PROVIDER}/accounts" '' '200' 'list provider accounts'
  if [[ $(jq 'length' <<<"${API_BODY}") -gt 0 ]]; then
    log_info "provider ${AI_PROVIDER} already has $(jq 'length' <<<"${API_BODY}") account(s) — skipping"
  else
    AI_KEY=${!AI_KEY_ENV:-}
    if [[ -z ${AI_KEY} ]]; then
      prompt_value "API key for ${AI_PROVIDER} (\$${AI_KEY_ENV} unset)" AI_KEY silent
    fi
    [[ -n ${AI_KEY} ]] || die "no API key for ${AI_PROVIDER}: set \$${AI_KEY_ENV}"
    api_expect POST "/api/provider-auth/${AI_PROVIDER}/accounts" \
      "$(jq -n --arg key "${AI_KEY}" '{key: $key, label: "setup"}')" \
      '200|201' 'create provider account'
    log_info "created ${AI_PROVIDER} account (label: setup)"
  fi
fi

# ---------------------------------------------------------------- exe key

if [[ ${RT_SANDBOX} == vm ]]; then
  EXE_KEY_PATH=$(resolve_exe_key_path "${RT_SANDBOX}" "${EXE_KEY_PATH}" \
    "path to the exe.dev account SSH key (runtime.exe.ssh_key_path unset)")
  if [[ -z ${EXE_KEY_PATH} ]]; then
    log_warn "runtime.exe.ssh_key_path is unset — skipping exe-provider-ssh-key seeding (add an exe key later via the admin UI)"
  else
    log_step "seeding exe provider SSH key (secret: exe-provider-ssh-key)"
    [[ -f ${EXE_KEY_PATH} ]] || die "exe SSH key not found: ${EXE_KEY_PATH}"
    api_expect PUT '/api/secrets/exe-provider-ssh-key' \
      "$(jq -n --rawfile v "${EXE_KEY_PATH}" '{value: $v}')" \
      '200|201' 'seed exe-provider-ssh-key'
    log_info "seeded exe-provider-ssh-key (worker picks it up without a restart)"
  fi
fi

# ---------------------------------------------------------------- squad

if [[ -z ${SQUAD_NAME} ]]; then
  log_info "no squad.name in config — skipping starter squad/agent seeding (add squad.name to opt in, or create your first squad via onboarding)"
else
  log_step "ensuring starter squad '${SQUAD_NAME}'"
  api_expect GET '/api/squads' '' '200' 'list squads'
  SQUAD_ID=$(jq -r --arg name "${SQUAD_NAME}" '[.[] | select(.name == $name)][0].id // empty' <<<"${API_BODY}")
  if [[ -n ${SQUAD_ID} ]]; then
    log_info "squad '${SQUAD_NAME}' already exists (${SQUAD_ID}) — skipping create"
  else
    api_expect POST '/api/squads' \
      "$(jq -n --arg name "${SQUAD_NAME}" --arg purpose "${SQUAD_PURPOSE}" '{name: $name, purpose: $purpose}')" \
      '200|201' 'create squad'
    SQUAD_ID=$(jq -r '.id' <<<"${API_BODY}")
    log_info "created squad '${SQUAD_NAME}' (${SQUAD_ID})"
  fi

  log_step "ensuring starter agent (${AGENT_TYPE}, model ${AGENT_MODEL})"
  api_expect GET "/api/squads/${SQUAD_ID}/agents" '' '200' 'list squad agents'
  # A squad auto-creates a MANAGER agent on creation, so a plain "any agent?"
  # check would ALWAYS skip and the configured starter worker (e.g. engineer)
  # would never spawn — the config silently ignored. Skip only when an agent of
  # the CONFIGURED type already exists, so a fresh squad still gets its starter
  # agent while re-runs stay idempotent (no duplicate).
  AGENT_COUNT=$(jq -r --arg type "${AGENT_TYPE}" '[.agents[] | select(.agentTypeId == $type)] | length' <<<"${API_BODY}")
  if [[ ${AGENT_COUNT} -gt 0 ]]; then
    log_info "squad already has a '${AGENT_TYPE}' agent — skipping spawn"
  else
    api_expect POST "/api/squads/${SQUAD_ID}/spawn" \
      "$(jq -n --arg type "${AGENT_TYPE}" --arg model "${AGENT_MODEL}" '{agentTypeId: $type, model: $model}')" \
      '200|201' 'spawn starter agent'
    log_info "spawned ${AGENT_TYPE} agent with model ${AGENT_MODEL}"
  fi
fi

log_info "seeding complete"
