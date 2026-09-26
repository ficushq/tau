#!/usr/bin/env bash
# lib.sh — shared helpers for the tau setup toolkit.
#
# Sourced by setup-host.sh, provision.sh, and seed.sh. Not a standalone
# script. Everything here is side-effect free at source time.
#
# YAML dependency (documented choice): config files are parsed with mikefarah
# yq v4 (https://github.com/mikefarah/yq) — a single static binary with one
# well-defined syntax. ensure_yq installs it automatically on Linux targets;
# on a macOS control machine install it with `brew install yq`. The python
# `yq` (jq wrapper) is NOT supported and is rejected by ensure_yq.

# shellcheck shell=bash

# ------------------------------------------------------------------ logging

if [[ -t 2 ]]; then
  _C_INFO=$'\033[1;34m' _C_WARN=$'\033[1;33m' _C_ERR=$'\033[1;31m' _C_STEP=$'\033[1;36m' _C_OFF=$'\033[0m'
else
  _C_INFO='' _C_WARN='' _C_ERR='' _C_STEP='' _C_OFF=''
fi

_ts() { date '+%H:%M:%S'; }

# A log write never fails the caller: when the reader of stderr is gone (a
# dropped SSH session), the env rename's restore and reconcile must still run
# to the end rather than die on the log line before them.
log_info() { printf '%s %sinfo%s  %s\n' "$(_ts)" "$_C_INFO" "$_C_OFF" "$*" >&2 || true; }
log_warn() { printf '%s %swarn%s  %s\n' "$(_ts)" "$_C_WARN" "$_C_OFF" "$*" >&2 || true; }
log_error() { printf '%s %serror%s %s\n' "$(_ts)" "$_C_ERR" "$_C_OFF" "$*" >&2 || true; }
log_step() { printf '\n%s %s==>%s %s\n' "$(_ts)" "$_C_STEP" "$_C_OFF" "$*" >&2 || true; }

# Total number of phase_step call sites in setup-host.sh. Pinned by a test in
# lib.test.sh so adding a phase without a marker fails CI rather than silently
# freezing a customer's progress display.
FICUS_PHASE_TOTAL=13
_tau_phase_n=0

# Announce a phase on two channels at once:
#   - the human banner on stderr, exactly as log_step always printed it;
#   - FICUS_PHASE=<ordinal>/<total> <slug> on STDOUT, which is the only stream
#     run-toolkit.ts scans (pump(proc.stdout, true), stderr false).
#
# The slug is the contract; the ordinal is diagnostics. The control plane maps
# slugs to customer-facing labels, so no product copy lives in this toolkit —
# which is also the self-hosting tool.
phase_step() { # SLUG HUMAN_TEXT...
  local slug=$1
  shift
  _tau_phase_n=$((_tau_phase_n + 1))
  printf 'FICUS_PHASE=%s/%s %s\n' "${_tau_phase_n}" "${FICUS_PHASE_TOTAL}" "${slug}"
  log_step "$@"
}
# Dry-run plan lines go to stdout so they can be captured/reviewed.
plan() { printf '  %s\n' "$*"; }

die() {
  log_error "$*"
  exit 1
}

# Exit code for a failure NO retry can fix. The platform's provision executor
# (TOOLKIT_EXIT_PERMANENT in its provision executor) maps exactly this code to a PermanentJobError so the
# job fails now instead of after five backoff attempts. Every other non-zero
# exit is retried. Today's only permanent case is the DigitalOcean account
# droplet limit.
PROVISION_EXIT_PERMANENT=66

die_permanent() {
  log_error "$*"
  exit "${PROVISION_EXIT_PERMANENT}"
}

# ------------------------------------------------------------------ basics

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() { # NAME [INSTALL_HINT]
  have "$1" || die "required command '$1' not found${2:+ — $2}"
}

# The gh release that introduced `gh --attach`. Agent prompts instruct agents to
# attach screenshots with it, so anywhere an agent runs gh, this is the floor.
# Kept beside the sandbox images' own pin (packages/k8s-sandbox/Dockerfile,
# apps/core/docker-sandbox/Dockerfile) — bump all three together.
FICUS_MIN_GH_VERSION='2.99.0'

# Print a command's semver, or nothing when it cannot be parsed.
# `gh --version` prints "gh version 2.99.0 (2026-...)"; the sed keeps the digits.
cmd_semver() { # NAME
  "$1" --version 2>/dev/null | sed -n 's/^[^0-9]*\([0-9][0-9.]*\).*/\1/p' | head -1
}

# True when INSTALLED is >= MINIMUM, by version sort.
#
# `sort -V` is the comparison here rather than a hand-rolled field split: it is
# the same idiom the sandbox Dockerfiles use for this exact check, and it gets
# 2.100.0 > 2.99.0 right, which a lexical or float compare does not.
version_at_least() { # INSTALLED MINIMUM
  [ -n "$1" ] || return 1
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Warn when the HOST's gh cannot run `gh --attach`.
#
# Only the `host` sandbox runtime needs this. Every other runtime gives agents a
# sandbox image whose Dockerfile pins gh at build time, so the host's own copy is
# irrelevant there; under `host` there is no image and agents run the operator's
# gh directly.
#
# This warns rather than dies on purpose. gh is not required to run Tau — it is
# required for one agent capability (attaching screenshots to GitHub), and a
# setup that aborts because an optional capability is unavailable would be
# disproportionate. The failure it prevents is the silent one: agent prompts
# telling agents to run a flag their gh does not have, which surfaces later as a
# confusing tool error rather than a setup message.
check_host_runtime_gh() { # SANDBOX_RUNTIME
  [ "$1" = host ] || return 0
  if ! have gh; then
    log_warn "gh is not installed. Under the 'host' sandbox runtime agents use this machine's gh, and agent prompts tell them to attach screenshots with 'gh --attach' (needs ${FICUS_MIN_GH_VERSION}+). Install gh to enable it."
    return 0
  fi
  local v
  v=$(cmd_semver gh)
  if ! version_at_least "${v}" "${FICUS_MIN_GH_VERSION}"; then
    log_warn "gh ${v:-(unknown version)} is older than ${FICUS_MIN_GH_VERSION}. Under the 'host' sandbox runtime agents use this machine's gh, and 'gh --attach' — which agent prompts tell them to use — will fail until it is upgraded."
  fi
}

# Put a user-local bun installation on PATH.
#
# bun's installer appends its PATH line to the shell rc files, which a
# NON-INTERACTIVE ssh session never reads. So on a perfectly healthy tenant —
# one whose systemd units run bun happily, because they name it by absolute
# path — `command -v bun` finds nothing. upgrade-host.sh died on exactly that
# ("required command 'bun' not found") against a real box while its entire
# test suite passed, because the test fakes had bun on PATH already.
#
# No-op when bun already resolves, and silent when bun is nowhere to be found:
# the caller decides whether that is fatal (upgrade) or means "install it"
# (setup).
bun_path_prepend() {
  have bun && return 0
  [[ -x ${HOME}/.bun/bin/bun ]] && export PATH="${HOME}/.bun/bin:${PATH}"
  return 0
}

# A bun pin as .bun-version and artifact.json record it: three dot-separated
# integers and nothing else. Nothing that fails this is ever handed to an
# installer, however it arrived.
bun_pin_is_valid() { # VERSION
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# The official installer, pinned to one version. A function of its own so
# lib.test.sh can stub it — the real one needs the network.
bun_official_install() { # VERSION
  curl -fsSL https://bun.sh/install | bash -s "bun-v$1"
}

# Install exactly VERSION: for this user at ${HOME}/.bun (and on PATH for the
# rest of this process), and — when a run user is known — at the managed
# system path via ensure_system_bun_node, so a unit that runs
# /usr/local/bin/bun picks it up on its next start. Returns non-zero, never
# dies, when the version is malformed or the install did not produce it; the
# caller decides how fatal that is.
#
# Exists because a Core bun bump used to strand every existing box: the pin
# moved, setup-host.sh only runs at provision, and upgrade-host.sh refused the
# mismatch (bun_mismatch) with no way forward but a hand install on each host
# (2026-09-15, 1.3.8 → 1.4.2, control plane + three tenants).
install_pinned_bun() { # VERSION
  local version=$1 out
  if ! bun_pin_is_valid "${version}"; then
    log_error "refusing to install bun '${version}': not a pinned x.y.z version"
    return 1
  fi
  log_info "installing bun ${version} (official installer, pinned)"
  out=$(mktemp "/tmp/tau-bun-install.XXXXXX")
  if ! bun_official_install "${version}" >"${out}" 2>&1; then
    log_error "bun ${version}: the official installer failed (network to bun.sh / GitHub?):"
    tail -n 5 "${out}" >&2
    rm -f "${out}"
    return 1
  fi
  rm -f "${out}"
  export BUN_INSTALL="${HOME}/.bun"
  export PATH="${BUN_INSTALL}/bin:${PATH}"
  hash -r 2>/dev/null || true
  if [[ "$(bun --version 2>/dev/null | tr -d '[:space:]')" != "${version}" ]]; then
    log_error "bun $(bun --version 2>/dev/null || echo '<none>') is on PATH after installing ${version}"
    return 1
  fi
  if [[ -n ${RUN_USER:-} ]] && declare -F ensure_system_bun_node >/dev/null; then
    ensure_system_bun_node "${RUN_USER}" "${BUN_INSTALL}/bin/bun"
  fi
  log_info "bun: $(command -v bun) ($(bun --version))"
}

# Install Bun at a stable, root-owned system path and provide Node compatibility
# for dependency entrypoints that use `#!/usr/bin/env node`. The smoke test runs
# through that shebang as the service account, proving both PATH resolution and
# traversal permissions without relying on Bun's /tmp shim.
managed_user_home() { # RUN_USER
  local home
  home=$(getent passwd "$1" | awk -F: 'NR == 1 { print $6 }') || return 1
  [[ ${home} == /* ]] || return 1
  printf '%s' "${home}"
}

ensure_system_bun_node() { # RUN_USER SOURCE_BUN
  local run_user=$1 source_bun=$2
  local system_bin=${FICUS_SYSTEM_BIN_DIR:-${TAU_SYSTEM_BIN_DIR:-/usr/local/bin}}
  local system_bun="${system_bin}/bun" system_node="${system_bin}/node"
  local run_home smoke output

  [[ -x ${source_bun} ]] || die "bun source is not executable: ${source_bun}"
  run_home=$(managed_user_home "${run_user}") || die "could not resolve home for ${run_user}"
  as_root install -d -m 0755 -o root -g root "${system_bin}"
  if ! cmp -s "${source_bun}" "${system_bun}" 2>/dev/null; then
    as_root install -m 0755 -o root -g root "${source_bun}" "${system_bun}"
  fi
  as_root chown root:root "${system_bun}"
  as_root chmod 0755 "${system_bun}"
  as_root ln -sfn "${system_bun}" "${system_node}"
  [[ $(as_root readlink "${system_node}") == "${system_bun}" ]] ||
    die "managed node compatibility link is not ${system_node} -> ${system_bun}"
  as_root runuser -u "${run_user}" -- env -i HOME="${run_home}" \
    PATH="${system_bin}:/usr/bin:/bin" test -x "${system_bun}" ||
    die "managed Bun runtime is not executable by ${run_user}"
  as_root runuser -u "${run_user}" -- env -i HOME="${run_home}" \
    PATH="${system_bin}:/usr/bin:/bin" test -x "${system_node}" ||
    die "managed Node runtime is not executable by ${run_user}"

  smoke=$(mktemp "/tmp/tau-node-smoke.XXXXXX")
  printf '#!/usr/bin/env node\nconsole.log("stable-node-ok")\n' >"${smoke}"
  chmod 0755 "${smoke}"
  output=$(as_root runuser -u "${run_user}" -- env -i \
    HOME="${run_home}" PATH="${system_bin}:/usr/bin:/bin" "${smoke}") || {
    rm -f "${smoke}"
    die "managed Node runtime is not executable by ${run_user}"
  }
  rm -f "${smoke}"
  [[ ${output} == stable-node-ok ]] ||
    die "managed Node runtime smoke test returned unexpected output for ${run_user}"
}

# Run a command as root: directly when already root, via sudo otherwise.
as_root() {
  if [[ ${EUID} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_root_capability() {
  if [[ ${EUID} -ne 0 ]]; then
    have sudo || die "this script needs root for systemd/docker/apt — run as root or install sudo"
    sudo -n true 2>/dev/null || log_warn "sudo may prompt for a password during setup"
  fi
}

# ------------------------------------------------------- atomic rendered installs

# Render → verify → install; never render straight into the destination.
# Observed live: a failed sed piped into `as_root tee /etc/systemd/system/
# tau-backup.service` left a 0-byte unit file behind — and an empty or
# truncated unit is WORSE than a missing one, because `systemctl daemon-reload`
# accepts it silently and the unit simply never works. So the render is staged
# to a private 0600 tmp file and only `install`ed over the destination after
# it verifies: non-empty always, and — for sed-template renders, via
# --check-placeholders — free of unsubstituted @PLACEHOLDER@ markers (a sed
# expression that matches nothing "succeeds" and leaves them behind). Env-style
# renders skip the placeholder check on purpose: their values are arbitrary
# secrets/DSNs that may legitimately contain `@…@` sequences.
#
# RENDER_CMD runs in the caller's execution context (no pipeline subshell), so
# a die() inside it — and inside this function — aborts the script for real.
# Do not call this from an -e-suppressed context (`if`/`||`/pipeline); see the
# core.env note below for why that would swallow the die.
install_rendered() { # [--check-placeholders] MODE OWNER GROUP DEST RENDER_CMD [ARGS...]
  local check=0
  if [[ $1 == --check-placeholders ]]; then
    check=1
    shift
  fi
  local mode=$1 owner=$2 group=$3 dest=$4 tmp
  shift 4
  tmp=$(mktemp)
  chmod 600 "${tmp}"
  "$@" >"${tmp}" || {
    rm -f "${tmp}"
    die "refusing to install ${dest}: render command failed (${1})"
  }
  [[ -s ${tmp} ]] || {
    rm -f "${tmp}"
    die "refusing to install ${dest}: rendered content is empty (${1} produced no output)"
  }
  if [[ ${check} -eq 1 ]] && grep -nE '@[A-Z_]+@' "${tmp}" >&2; then
    rm -f "${tmp}"
    die "refusing to install ${dest}: rendered content still contains unsubstituted @PLACEHOLDER@ markers (offending lines above)"
  fi
  # Checked, not left to errexit: the env-rename restore renders units from
  # inside an `if !` span, where a failed install would otherwise pass.
  if ! as_root install -m "${mode}" -o "${owner}" -g "${group}" "${tmp}" "${dest}"; then
    rm -f "${tmp}"
    die "refusing to continue: installing ${dest} failed"
  fi
  rm -f "${tmp}"
}

# Poll a condition until it succeeds or a timeout elapses. Never a fixed sleep.
retry_until() { # TIMEOUT_SECS INTERVAL_SECS DESCRIPTION CMD [ARGS...]
  local timeout=$1 interval=$2 desc=$3
  shift 3
  local waited=0
  until "$@" >/dev/null 2>&1; do
    if ((waited >= timeout)); then
      log_error "timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  return 0
}

gen_hex_secret() { # [BYTES=32]
  openssl rand -hex "${1:-32}"
}

# Show only enough of a secret to correlate, never the value.
redact_secret() {
  local v=${1:-}
  if [[ -z ${v} ]]; then
    printf '<empty>'
  else
    printf '%s… (%d chars, redacted)' "${v:0:4}" "${#v}"
  fi
}

is_tty() { [[ -t 0 ]]; }
is_stdout_tty() { [[ -t 1 ]]; }

# Renders setup-host.sh phase_report's bootstrap-token block. Isolated from
# phase_report itself (which also needs a live curl to the freshly-started
# API) so this piece — the only part with a security-relevant branch — can
# be unit-tested directly. When stdout is not a TTY, the freshly-generated
# value is withheld: piping/redirecting setup-host.sh's output (systemd
# journal, `ssh host ... > out.log`, CI artifacts, a wrapper script's log
# file, ...) would otherwise permanently leak a fully-privileged bootstrap
# credential into a captured log. The not-generated case (an existing
# FICUS_PASSWORD, from env or a prior run's .env) already never printed the
# value itself, so it's unaffected either way. `is_stdout_tty` is called
# indirectly (not inlined as `[[ -t 1 ]]`) so lib.test.sh can override it the
# same way it already overrides `is_tty` for resolve_exe_key_path.
render_bootstrap_token_block() { # PW_GENERATED FICUS_PW_VALUE PW_SOURCE ENV_FILE
  local generated=$1 value=$2 source=$3 env_file=$4
  if [[ ${generated} -eq 1 ]]; then
    if is_stdout_tty; then
      printf '   %s\n' "${value}"
      printf '   (printed once — also stored in %s)\n' "${env_file}"
    else
      printf '   Bootstrap token withheld (non-interactive run); read FICUS_PASSWORD from %s if needed.\n' "${env_file}"
    fi
  else
    printf '   from %s (not re-printed)\n' "${source}"
  fi
}

prompt_value() { # PROMPT VAR_NAME [silent]
  local prompt=$1 __var=$2 mode=${3:-} __val=''
  is_tty || die "cannot prompt for '${prompt}' — no TTY (supply it via config/env for unattended runs)"
  if [[ ${mode} == silent ]]; then
    read -r -s -p "${prompt}: " __val
    printf '\n' >&2
  else
    read -r -p "${prompt}: " __val
  fi
  printf -v "${__var}" '%s' "${__val}"
}

# The complete, closed set of sandbox runtimes — the SAME five the core's
# FICUS_SANDBOX_RUNTIME accepts (apps/core/src/services/sandbox/runtime.ts).
FICUS_SANDBOX_RUNTIMES='docker-sysbox, docker-socket, k8s, vm, host'

# Validate a runtime.sandbox value, or die naming every supported one.
#
# There is no default and no auto-detection anywhere in the stack: the core
# refuses to start without FICUS_SANDBOX_RUNTIME, so a config that never chose a
# runtime must fail on the control machine rather than install a runtime nobody
# picked and surface as a host that boots and cannot run a single agent. The
# retired spellings get their rename hint instead of a bare rejection — they
# were valid for a long time and appear in every older config.
#
# ONE definition, used by setup-host.sh, provision.sh and seed.sh, so the three
# cannot drift into accepting different sets.
# Strip leading/trailing whitespace. Pure string surgery, no subshell tricks.
trim_ws() { # VALUE
  local v=${1:-}
  v=${v#"${v%%[![:space:]]*}"}
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

require_sandbox_runtime() { # VALUE
  local value hint=''
  # Trimmed before matching, exactly like the core's requireSandboxRuntime: a
  # yaml value that picked up stray whitespace is a typo, not a sixth runtime.
  # NOT lowercased on either side — the five values are exact, so `Host` is a
  # real misconfiguration and says so. Callers trim at the READ site too (the
  # value is compared against `vm` and written into .env verbatim), so this is
  # the second line of defence, not the only one.
  value=$(trim_ws "${1:-}")
  [[ -n ${value} ]] ||
    die "config: runtime.sandbox is required — one of ${FICUS_SANDBOX_RUNTIMES} (see docs/wiki/sandbox-runtimes.md)"
  case "${value}" in
    docker-sysbox | docker-socket | k8s | vm | host) return 0 ;;
    sysbox) hint=' — use docker-sysbox' ;;
    socket) hint=' — use docker-socket' ;;
    auto | docker) hint=' — auto-detection was removed, choose docker-sysbox or docker-socket' ;;
  esac
  die "config: runtime.sandbox must be one of ${FICUS_SANDBOX_RUNTIMES} (got '${value}')${hint}"
}

# Refuse to restart tau-api/tau-worker against an env file that does not name a
# supported FICUS_SANDBOX_RUNTIME (or, on a host an upgrade is about to rename,
# its TAU_ spelling — envfile_read_prefixed reads either).
#
# An upgrade deliberately rewrites no .env — that is what makes it runnable long
# after provisioning without re-supplying a single secret. But the runtime is
# now MANDATORY and EXPLICIT in the core, so a box whose .env predates that (or
# still carries a retired spelling) comes back from an upgrade with both units
# dead: the build succeeded, the migrations ran, the tree moved, and nothing
# serves. Check it BEFORE anything on the box changes.
#
# It never repairs the file. Picking between docker-sysbox and docker-socket is
# a security decision (socket mode hands agents the host's docker socket), and
# guessing on the operator's behalf is exactly the auto-detection this whole
# change removed.
require_env_file_sandbox_runtime() { # ENV_FILE
  local file=$1 value='' hint=''
  [[ -f ${file} ]] ||
    die "FICUS_SANDBOX_RUNTIME preflight: env file '${file}' not found — the services read it at startup, so an upgrade cannot verify what they would come back as"
  # A non-root (sudo) run that cannot read it cannot check anything in it —
  # this, or whether it still uses TAU_ names a Ficus release needs renamed
  # (Ruling 31: fail closed). Name the file, never its contents.
  [[ -r ${file} ]] ||
    die "cannot read ${file} as $(id -un) (uid ${EUID}), so this non-root run cannot check it (its sandbox runtime, or TAU_ names the Ficus Core release needs renamed — the rename is root-only) — re-run this as root"
  envfile_read_prefixed value "${file}" SANDBOX_RUNTIME || value=''
  # Tolerate `KEY="value"` / `KEY='value'` and stray whitespace: systemd's
  # EnvironmentFile strips the quotes, so those are the same setting.
  value=${value#[\"\']}
  value=${value%[\"\']}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [[ -n ${value} ]] ||
    die "FICUS_SANDBOX_RUNTIME is not set in ${file} — tau-api and tau-worker refuse to start without it, so restarting them now would take this instance DOWN. Add one of ${FICUS_SANDBOX_RUNTIMES} to that file (see docs/wiki/sandbox-runtimes.md) and re-run."
  case "${value}" in
    docker-sysbox | docker-socket | k8s | vm | host) return 0 ;;
    sysbox) hint=' — this host predates the rename: use docker-sysbox' ;;
    socket) hint=' — this host predates the rename: use docker-socket' ;;
    auto | docker) hint=' — auto-detection was removed, choose docker-sysbox or docker-socket' ;;
  esac
  die "FICUS_SANDBOX_RUNTIME in ${file} must be one of ${FICUS_SANDBOX_RUNTIMES} (got '${value}')${hint}. tau-api and tau-worker refuse to start otherwise, so restarting them now would take this instance DOWN; fix that file and re-run."
}

# Resolve runtime.exe.ssh_key_path for `runtime.sandbox: vm`, tolerating an
# empty value when there's no TTY to prompt at: a headless run (e.g. the
# platform control plane's job executor, over `ssh -o BatchMode=yes` with no
# pty) with an empty ssh_key_path is NOT an error — the BYO tier's rendered
# config legitimately omits it, since exe machines are registered by the
# tenant after handoff rather than at provision time. Prints the resolved
# path (possibly still empty) to stdout; callers remain responsible for any
# `-f` existence check on a non-empty result. Interactive runs still get the
# original prompt-if-unset behavior.
resolve_exe_key_path() { # RT_SANDBOX EXE_KEY_PATH PROMPT_LABEL
  local sandbox=$1 path=$2 label=$3
  if [[ ${sandbox} == vm && -z ${path} ]]; then
    if is_tty; then
      prompt_value "${label}" path
      path=$(expand_tilde "${path}")
    else
      log_warn "runtime.exe.ssh_key_path is unset and there's no TTY to prompt — skipping (add an exe key later via the admin UI, or set it in the config for an unattended run that needs one now)"
    fi
  fi
  printf '%s' "${path}"
}

# Expand a leading ~ (config files may use ~/keys/...).
expand_tilde() {
  local p=${1:-}
  # shellcheck disable=SC2088 # matching a literal leading tilde is the point
  case "${p}" in
    '~') printf '%s' "${HOME}" ;;
    '~/'*) printf '%s/%s' "${HOME}" "${p#'~/'}" ;;
    *) printf '%s' "${p}" ;;
  esac
}

# ------------------------------------------------------------------ yq / config

YQ_VERSION="v4.44.3"

yq_is_mikefarah() {
  have yq && yq --version 2>/dev/null | grep -q 'mikefarah'
}

ensure_yq() {
  if yq_is_mikefarah; then return 0; fi
  case "$(uname -s)" in
    Linux)
      local arch
      case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) die "unsupported architecture for yq auto-install: $(uname -m)" ;;
      esac
      log_info "installing yq ${YQ_VERSION} (mikefarah) to /usr/local/bin/yq"
      as_root curl -fsSL -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"
      as_root chmod +x /usr/local/bin/yq
      yq_is_mikefarah || die "yq installed but not usable (wrong flavor on PATH?)"
      ;;
    *)
      die "mikefarah yq v4 is required to parse the config — install it (macOS: brew install yq)"
      ;;
  esac
}

CFG_FILE=''

cfg_load() { # FILE
  CFG_FILE=$1
  [[ -f ${CFG_FILE} ]] || die "config file not found: ${CFG_FILE}"
  yq_is_mikefarah || die "mikefarah yq v4 is required (run preflight / brew install yq)"
  yq '.' "${CFG_FILE}" >/dev/null || die "config file is not valid YAML: ${CFG_FILE}"
}

cfg_get() { # .dotted.path [DEFAULT]
  local path=$1 default=${2:-} val
  val=$(yq -r "${path}" "${CFG_FILE}" 2>/dev/null) || die "failed to read ${path} from ${CFG_FILE}"
  if [[ -z ${val} || ${val} == 'null' ]]; then
    printf '%s' "${default}"
  else
    printf '%s' "${val}"
  fi
}

# True (exit 0) iff PATH exists in the config file and is not explicit null —
# INCLUDING an explicitly empty string (''), unlike cfg_get's "empty means
# unset" collapsing. Needed where the question is "was this key written at
# all", not "does it have a value" — e.g. provision.sh's exe-section probe: a
# do_droplet config with no `runtime.exe:` section at all must skip the
# exe-key resolution (and its warning/prompt) entirely, while a self-hoster's
# `runtime.exe.ssh_key_path: ''` (present, empty, meaning "prompt me") must
# still go through it. cfg_get can't tell those two apart; this can.
cfg_has() { # .dotted.path
  local path=$1 sentinel='__tau_cfg_absent__' val
  val=$(yq -r "(${path} // \"${sentinel}\")" "${CFG_FILE}" 2>/dev/null) || die "failed to probe ${path} in ${CFG_FILE}"
  [[ ${val} != "${sentinel}" ]]
}

# The install root: .source.dest, tilde-expanded, with the toolkit's default —
# the one resolution every entrypoint uses (and the control plane's probes
# mirror).
cfg_source_dest() {
  expand_tilde "$(cfg_get '.source.dest' '/opt/tau-core')"
}

cfg_require() { # .dotted.path DESCRIPTION
  local val
  val=$(cfg_get "$1")
  [[ -n ${val} ]] || die "config: $1 (${2}) is required in ${CFG_FILE}"
  printf '%s' "${val}"
}

cfg_bool() { # .dotted.path DEFAULT(true|false)
  local val
  val=$(cfg_get "$1" "$2")
  case "${val}" in
    true | yes | 1) printf 'true' ;;
    false | no | 0) printf 'false' ;;
    *) die "config: $1 must be true or false (got '${val}')" ;;
  esac
}

# Write a single scalar VALUE to PATH in CFG_FILE, in place — the write-side
# counterpart to cfg_get, for tools (e.g. retarget-origin.sh) that mutate an
# already-provisioned host's config rather than only reading it. VALUE is
# passed through the environment (yq's strenv()), never spliced into the yq
# expression string itself, so nothing the caller passes — quotes, colons,
# a leading '-' — can be interpreted as yq syntax. Only ever assigns a
# scalar; a map/array literal would need exactly that unsafe interpolation
# and no caller needs one. Creates PATH (and any missing parent maps), same
# as a normal yq assignment.
cfg_set() { # .dotted.path VALUE
  local path=$1
  FICUS_CFG_SET_VALUE=$2 yq -i "${path} = strenv(FICUS_CFG_SET_VALUE)" "${CFG_FILE}" ||
    die "failed to write ${path} to ${CFG_FILE}"
}

# ------------------------------------------------------------------ digitalocean fallbacks

# Ordered (size, region) pairs from provision.digitalocean.fallbacks — one
# "SIZE REGION" per line, in config order — tried in turn by
# provision_vm_digitalocean() after the primary size/region when a create
# fails with a capacity/availability error (do_is_capacity_error above).
# Missing/null PATH yields no lines (the fallbacks list is optional).
cfg_do_fallbacks() { # .dotted.path (e.g. .provision.digitalocean.fallbacks)
  yq -r "(${1} // []) | .[] | .size + \" \" + .region" "${CFG_FILE}" 2>/dev/null ||
    die "failed to read ${1} from ${CFG_FILE}"
}

# ------------------------------------------------------------------ core.env passthrough

# Raw (unvalidated) keys of a flat map at PATH (e.g. '.core.env'), one per
# line. Missing/null PATH yields no lines (flag-gated: an absent map is a
# no-op). This is the only allowed use of an inner command substitution for
# core.env parsing: die() run inside a `$(...)` or `< <(...)` subshell only
# terminates that subshell, and when the whole call sits in an
# -e-suppressed context (any `||`/`if`/pipeline — which is how tests, and
# real callers, invoke these helpers) that exit is silently swallowed. Key
# *validation* (which must die visibly) therefore happens directly in each
# public function's own execution context, not inside a nested helper.
_cfg_map_keys_raw() { # .dotted.path
  yq -r "(${1} // {}) | keys | .[]" "${CFG_FILE}" 2>/dev/null || die "failed to read ${1} keys from ${CFG_FILE}"
}

# True when a LITERAL config entry looks like it carries a credential VALUE.
#
# The *_ENV indirection exists so that no secret value ever lives in the yaml
# (setup-platform.sh's env block says so in as many words), but nothing
# enforced it: `SPACES_KEY: <literal>` was accepted exactly as happily as
# `SPACES_KEY_ENV: SPACES_KEY`, and a live control plane ran for weeks with
# raw object-storage credentials sitting in a world-readable config file that
# gets copied around, diffed, and pasted into issues.
#
# Two independent signals, because each catches what the other misses:
#   * the KEY is credential-shaped (…_KEY, …_SECRET, …_TOKEN, …_PASSWORD,
#     …_CREDENTIALS) — catches an unrecognizable secret under an obvious name.
#     …_PATH / …_ID / …_URL / …_ENV endings are excluded: those name a file,
#     an identifier or a pointer, and every shipped config uses them that way.
#   * the VALUE carries a known credential prefix, or is a URL with an inline
#     password — catches a secret hidden under an innocuous name.
#
# An empty value and a filesystem path are never a secret, checked first so a
# `FOO_KEY: ''` placeholder and a `FOO_KEY: /etc/...` path both stay legal.
looks_like_literal_secret() { # KEY VALUE
  local key=$1 val=$2
  [[ -n ${val} ]] || return 1
  [[ ${val} != /* && ${val} != '~'* ]] || return 1

  case "${key}" in
    *_PATH | *_ID | *_URL | *_ENV | *_DIR | *_FILE) ;;
    *_KEY | *_SECRET | *_TOKEN | *_PASSWORD | *_CREDENTIALS | *_SECRET_KEY | *_ACCESS_KEY | *_API_KEY)
      return 0 ;;
  esac

  case "${val}" in
    sk_* | rk_* | whsec_* | dop_v1_* | ghp_* | gho_* | ghs_* | ghu_* | github_pat_* | xoxb-* | AKIA* | 'SG.'* | '-----BEGIN'*)
      return 0 ;;
  esac
  # scheme://user:password@host — a connection string with the password inline.
  [[ ${val} =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@ ]] && return 0

  return 1
}

# Resolve a flat string map at PATH to KEY=value .env lines (real|redact MODE,
# default real). Two forms per entry:
#   FOO: bar        → literal:     FOO=bar
#   FOO_ENV: BAR    → indirection: FOO=<contents of $BAR>  (BAR is an env var
#                      name, not a value — the same *_env convention used
#                      elsewhere in the config, e.g. secrets.encryption_key_env
#                      — so secret VALUES never live in the yaml). In redact
#                      mode the resolved value is passed through redact_secret
#                      instead of printed in full.
#
# Dies on: a key that isn't SCREAMING_SNAKE_CASE, a value containing a
# newline (not representable as a single .env line), a *_ENV value that
# isn't a valid env var name, or a *_ENV reference to a variable that is
# unset.
cfg_env_pairs() { # .dotted.path [real|redact]
  local path=$1 mode=${2:-real} keys key val target
  keys=$(_cfg_map_keys_raw "${path}") || die "failed to read ${path} keys from ${CFG_FILE}"
  while IFS= read -r key; do
    [[ -z ${key} ]] && continue
    [[ ${key} =~ ^[A-Z][A-Z0-9_]*$ ]] ||
      die "config: ${path} key '${key}' is invalid — must match ^[A-Z][A-Z0-9_]*\$"
    val=$(cfg_get "${path}.${key}")
    if [[ ${key} == *_ENV ]]; then
      target=${key%_ENV}
      [[ ${val} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
        die "config: ${path}.${key} must name a valid env var (got '${val}')"
      [[ -n ${!val:-} ]] ||
        die "config: ${path}.${key} references \$${val}, which is unset"
      # The newline check MUST run on the resolved secret (${!val}), not on
      # `val` (which here is just the env var NAME and can never contain a
      # newline in practice — checking it would be a dead check). Never print
      # the secret value itself in the die message — name the key and the env
      # var name only.
      [[ ${!val} != *$'\n'* ]] ||
        die "config: ${path}.${key} resolves \$${val} to a value containing a newline — not valid in a .env file"
      if [[ ${mode} == redact ]]; then
        printf '%s=%s\n' "${target}" "$(redact_secret "${!val}")"
      else
        printf '%s=%s\n' "${target}" "${!val}"
      fi
    else
      [[ ${val} != *$'\n'* ]] ||
        die "config: ${path}.${key} value contains a newline — not valid in a .env file"
      # A literal that looks like a credential is a config bug, not a style
      # preference: the fix is one rename away and the failure it prevents
      # (a secret committed to a config file) is unrecoverable once it has
      # happened. Never echo the value — name the key and the fix only.
      ! looks_like_literal_secret "${key}" "${val}" ||
        die "config: ${path}.${key} holds a literal value that looks like a credential — secret VALUES never live in the config. Rename the key to ${key}_ENV, set it to the NAME of an environment variable (e.g. '${path}.${key}_ENV: ${key}'), and export that variable before running setup."
      # A value starting with `~` is path-shaped by definition, and NOTHING
      # downstream will expand it: the file we are writing is a .env, read by
      # systemd's EnvironmentFile= and by bun's dotenv loader, neither of which
      # is a shell. `HOME_DIR: ~/.tau` used to reach the core verbatim and make
      # it create a directory literally named `~`. Same expansion the toolkit
      # already applies to every path it reads from the config.
      #
      # Only this literal branch. A *_ENV value resolves to a SECRET (that is
      # the entire point of the indirection — secret values never live in the
      # yaml), never a path, and silently rewriting a secret that happens to
      # begin with `~` would corrupt it.
      [[ ${val} != '~'* ]] || val=$(expand_tilde "${val}")
      printf '%s=%s\n' "${key}" "${val}"
    fi
  done <<<"${keys}"
}

# Names of the env vars referenced by PATH's *_ENV-suffixed keys (the VALUES,
# not the keys), one per line — used to forward them to a remote target
# (e.g. provision.sh's FORWARD_ENVS) without resolving or requiring them
# to be set locally.
cfg_env_forward_names() { # .dotted.path
  local path=$1 keys key val
  keys=$(_cfg_map_keys_raw "${path}") || die "failed to read ${path} keys from ${CFG_FILE}"
  while IFS= read -r key; do
    [[ -z ${key} ]] && continue
    [[ ${key} =~ ^[A-Z][A-Z0-9_]*$ ]] ||
      die "config: ${path} key '${key}' is invalid — must match ^[A-Z][A-Z0-9_]*\$"
    if [[ ${key} == *_ENV ]]; then
      val=$(cfg_get "${path}.${key}")
      # Validate the shape here too (not just in cfg_env_pairs): this is the
      # helper provision.sh uses on the control machine, and a malformed
      # name silently expands empty in `${!name:-}` there — dropping the
      # secret with no error until setup-host.sh re-validates on the remote
      # target, after a VM has already been provisioned. Fail fast instead.
      [[ ${val} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
        die "config: ${path}.${key} must name a valid env var (got '${val}')"
      printf '%s\n' "${val}"
    fi
  done <<<"${keys}"
}

# ------------------------------------------------------------------ .env files

# Read KEY=VALUE from an env file (no interpolation; last assignment wins).
envfile_get() { # FILE KEY
  local file=$1 key=$2 line last='' found=0
  [[ -f ${file} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    # KEY is quoted in the regex so a metacharacter in it is matched
    # literally, not as regex syntax — same reasoning as envfile_set's
    # quoted match (its write-side counterpart).
    if [[ ${line} =~ ^"${key}"= ]]; then
      last=${line#"${key}"=}
      found=1
    fi
  done <"${file}"
  [[ ${found} -eq 1 ]] || return 1
  printf '%s' "${last}"
}

# Portable "MODE OWNER:GROUP" of FILE (GNU stat, then BSD/macOS stat) — used
# by envfile_set to carry an existing file's permissions across an atomic
# same-directory replace.
_file_mode_owner_group() { # FILE
  stat -c '%a %U:%G' "$1" 2>/dev/null || stat -f '%Lp %Su:%Sg' "$1"
}

# Update (or append) KEY=VALUE in FILE in place — the write-side counterpart
# to envfile_get, for tools (e.g. retarget-origin.sh) that patch a couple of
# keys in an already-rendered .env without re-rendering the whole file (which
# would need secrets that may no longer be available off-box). Preserves
# every OTHER line byte-for-byte: comments, ordering, blank lines, and any
# secret already sitting in the file. Every existing assignment of KEY is
# rewritten in place (matching envfile_get's "last assignment wins" read
# semantics — a file with a duplicate key keeps having a duplicate key, both
# updated, rather than being silently collapsed to one); if KEY is absent,
# one line is appended. FILE must already exist.
#
# Never a direct `cat > FILE` — setup-host.sh's own phase_env comment names
# exactly why: that truncates the previous good file the instant the write
# starts, so a write that dies partway leaves the services with a gutted
# EnvironmentFile. Instead: build the new content in a temp file NEXT TO
# FILE (same directory — never /tmp, both because this content carries live
# secrets and because a same-filesystem temp is what makes the final `mv`
# an ATOMIC rename; /tmp is very often a different filesystem, where `mv`
# silently degrades to copy+unlink and a crash mid-copy can leave a
# half-written .env), copy FILE's mode/owner onto it, then `mv -f` it over
# FILE in one syscall.
envfile_set() { # FILE KEY VALUE
  local file=$1 key=$2 value=$3 dir tmp found=0 line mog mode owner_group content='' raw rest size
  [[ -f ${file} ]] || die "envfile_set: file not found: ${file}"
  dir=$(dirname -- "${file}")
  mog=$(_file_mode_owner_group "${file}") || die "envfile_set: could not stat ${file}"
  mode=${mog%% *}
  owner_group=${mog#* }

  # Read FILE, and prove the read got ALL of it, before building anything —
  # the replacement is built from what was read, so a read that silently
  # came up short would drop every line after that point from the live .env
  # (secrets included) while "succeeding". What is checked, exactly:
  #   1. the size probe (`wc -c <FILE`) must succeed — this fails if FILE
  #      cannot be opened (e.g. unreadable);
  #   2. `cat` must exit 0 — it exits non-zero if FILE cannot be opened or
  #      if any read(2) on it returns an error, so a mid-file I/O error is
  #      NOT mistaken for EOF (a bare `while read …; done <FILE` cannot tell
  #      the two apart: `read` returns non-zero for both);
  #   3. the sentinel `x` printed after cat must be present (it also keeps
  #      the command substitution from stripping FILE's trailing newlines);
  #   4. the byte length of what was read must equal the probed size — this
  #      catches FILE changing size between the probe and the read, and any
  #      bytes the shell cannot hold (a command substitution drops NUL
  #      bytes), so such a file is refused rather than rewritten without them.
  # Each is an explicit `|| die`/`if`, never errexit (see the write-side note
  # below for why).
  size=$(wc -c <"${file}") || die "envfile_set: could not read ${file}"
  size=${size//[[:space:]]/}
  [[ ${size} =~ ^[0-9]+$ ]] || die "envfile_set: could not determine the size of ${file}"
  raw=$(cat -- "${file}" && printf x) || die "envfile_set: failed to read ${file}"
  [[ ${raw} == *x ]] || die "envfile_set: failed to read ${file}"
  raw=${raw%x}
  # Byte length, not character length: a UTF-8 value would otherwise count
  # short. LC_ALL is switched only inside this `( … )` subshell, whose exit
  # status carries the comparison result.
  if ! (
    LC_ALL=C
    [[ ${#raw} -eq ${size} ]]
  ); then
    die "envfile_set: read of ${file} came up short or contained bytes the shell cannot hold (NUL) — refusing to rewrite it"
  fi

  # Build the WHOLE replacement content in a variable — nothing has touched
  # disk yet, so there is nothing to clean up if this part fails. Lines are
  # split with parameter expansion rather than `read <<<"${raw}"`: a
  # here-string may be backed by a temp file (in $TMPDIR, i.e. usually
  # /tmp — no place for this file's secrets) and would be one more redirect
  # to check. Every line is re-emitted with a trailing newline (a final line
  # that lacked one gains it). KEY is quoted in the regex so a metacharacter
  # in it (only ever a SCREAMING_SNAKE_CASE identifier in every real caller,
  # but defense in depth costs nothing here) is matched literally, not as
  # regex syntax.
  rest=${raw}
  while [[ -n ${rest} ]]; do
    line=${rest%%$'\n'*}
    if [[ ${line} == "${rest}" ]]; then rest=''; else rest=${rest#*$'\n'}; fi
    if [[ ${line} =~ ^"${key}"= ]]; then
      content+="${key}=${value}"$'\n'
      found=1
    else
      content+="${line}"$'\n'
    fi
  done
  [[ ${found} -eq 1 ]] || content+="${key}=${value}"$'\n'

  tmp=$(mktemp "${dir}/.$(basename -- "${file}").XXXXXX") ||
    die "envfile_set: failed to create a staging file next to ${file}"

  # The staged write and the final mv are checked explicitly (die on
  # failure, removing the staging file); chmod/chown failures only warn —
  # mktemp created the staging file 0600 and owned by the caller, so a
  # failure there leaves it more restrictive, never less. Never errexit, here
  # or in the read above: a caller that invokes this from inside a subshell
  # being used as an if/&&/||-condition (retarget-origin.sh's cert-restore
  # span does exactly that) runs with -e silently suppressed for the entire
  # dynamic extent of evaluating that condition, INCLUDING a `set -e`
  # restated inside the subshell — that suppression cannot be un-suppressed
  # from within. A single unchecked read or write in that context would not
  # abort; it would just silently produce a truncated/wrong file that then
  # gets `mv`'d into place as if nothing were wrong.
  if ! printf '%s' "${content}" >"${tmp}"; then
    rm -f "${tmp}"
    die "envfile_set: failed to write the staged replacement for ${file}"
  fi
  if ! chmod "${mode}" "${tmp}" 2>/dev/null; then
    log_warn "envfile_set: could not chmod the staged replacement for ${file} to ${mode}"
  fi
  if ! chown "${owner_group}" "${tmp}" 2>/dev/null; then
    log_warn "envfile_set: could not chown the staged replacement for ${file} to ${owner_group} (needs root)"
  fi
  if ! mv -f "${tmp}" "${file}"; then
    rm -f "${tmp}"
    die "envfile_set: failed to atomically replace ${file}"
  fi
}

# Read FILE's exact bytes into the variable named VAR, proving the read got
# all of it — the same four checks envfile_set's read makes (see there): the
# size probe must succeed, `cat` must exit 0, the sentinel must survive, and
# the byte count must match the probe (catches a short read, a file changing
# under us, and NUL bytes the shell cannot hold). Every step is an explicit
# check, so this is safe to call where errexit is suppressed. Never dies:
# returns 1 after a log_error naming FILE (never its content), leaving VAR
# untouched.
read_file_exact() { # FILE VAR
  local _rfe_file=$1 _rfe_var=$2 _rfe_size _rfe_raw
  if ! _rfe_size=$(wc -c <"${_rfe_file}"); then
    log_error "could not read ${_rfe_file}"
    return 1
  fi
  _rfe_size=${_rfe_size//[[:space:]]/}
  if [[ ! ${_rfe_size} =~ ^[0-9]+$ ]]; then
    log_error "could not determine the size of ${_rfe_file}"
    return 1
  fi
  if ! _rfe_raw=$(cat -- "${_rfe_file}" && printf x) || [[ ${_rfe_raw} != *x ]]; then
    log_error "failed to read ${_rfe_file}"
    return 1
  fi
  _rfe_raw=${_rfe_raw%x}
  if ! (
    LC_ALL=C
    [[ ${#_rfe_raw} -eq ${_rfe_size} ]]
  ); then
    log_error "read of ${_rfe_file} came up short or it contains bytes the shell cannot hold (NUL)"
    return 1
  fi
  printf -v "${_rfe_var}" '%s' "${_rfe_raw}"
}

# Stage CONTENT as the replacement for the EXISTING file DEST, for a caller
# that then commits it with `mv -f STAGED DEST`: a new file created next to
# DEST (same directory, so that mv is an atomic rename — and never /tmp,
# since CONTENT may be a secret), holding exactly CONTENT, carrying DEST's
# mode and owner:group. Sets the variable named VAR to the staged path.
#
# Every step is explicitly checked, so this is safe where errexit is
# suppressed. On ANY failure the staged file is removed, VAR is left empty,
# DEST is untouched, and it returns 1 after a log_error. Unlike envfile_set,
# a chmod/chown failure is fatal: a script staged at mktemp's 0600 would
# install as a file systemd cannot execute.
stage_file_replacement() { # DEST CONTENT VAR
  local _sfr_dest=$1 _sfr_content=$2 _sfr_var=$3 _sfr_dir _sfr_base _sfr_mog _sfr_tmp
  printf -v "${_sfr_var}" '%s' ''
  if [[ ! -f ${_sfr_dest} ]]; then
    log_error "cannot stage a replacement for ${_sfr_dest}: it does not exist"
    return 1
  fi
  if ! _sfr_dir=$(dirname -- "${_sfr_dest}") || ! _sfr_base=$(basename -- "${_sfr_dest}"); then
    log_error "cannot stage a replacement for ${_sfr_dest}: bad path"
    return 1
  fi
  if ! _sfr_mog=$(_file_mode_owner_group "${_sfr_dest}") || [[ ${_sfr_mog} != *' '*:* ]]; then
    log_error "cannot stage a replacement for ${_sfr_dest}: could not read its mode/owner"
    return 1
  fi
  if ! _sfr_tmp=$(mktemp "${_sfr_dir}/.${_sfr_base}.XXXXXX") || [[ -z ${_sfr_tmp} ]]; then
    log_error "failed to create a staging file next to ${_sfr_dest}"
    return 1
  fi
  if ! printf '%s' "${_sfr_content}" >"${_sfr_tmp}"; then
    rm -f "${_sfr_tmp}"
    log_error "failed to write the staged replacement for ${_sfr_dest}"
    return 1
  fi
  if ! chmod "${_sfr_mog%% *}" "${_sfr_tmp}"; then
    rm -f "${_sfr_tmp}"
    log_error "failed to set mode ${_sfr_mog%% *} on the staged replacement for ${_sfr_dest}"
    return 1
  fi
  if ! chown "${_sfr_mog#* }" "${_sfr_tmp}"; then
    rm -f "${_sfr_tmp}"
    log_error "failed to set owner ${_sfr_mog#* } on the staged replacement for ${_sfr_dest}"
    return 1
  fi
  printf -v "${_sfr_var}" '%s' "${_sfr_tmp}"
}

# Timestamped copy of FILE next to it (`cp -p`, so a 0600 secret stays 0600).
# Prints the backup path on stdout (the log_info line goes to stderr) so a
# caller can capture it; a missing FILE is a no-op that prints nothing. Used
# by the retarget-*.sh primitives before they rewrite a live file.
backup_file() { # FILE
  local file=$1 ts dest
  [[ -f ${file} ]] || return 0
  ts=$(date -u '+%Y%m%dT%H%M%SZ')
  # The XXXXXX suffix (via `mktemp -u` — a dry run, no file created by this
  # call) makes the name unique even when two backups of the same file land
  # in the same wall-clock SECOND (this timestamp has no finer resolution),
  # e.g. a quick re-run right after a failure — without it, the second
  # backup would silently overwrite the first, destroying the only copy of
  # what was there before this run started.
  dest=$(mktemp -u "${file}.bak-${ts}-XXXXXX") || die "backup_file: failed to compute a unique backup name for ${file}"
  # Explicit check: callers capture this function's output with `$(...)`,
  # and bash does not carry errexit into a command substitution (no
  # inherit_errexit here), so an unchecked failed copy would still print
  # a backup path that does not hold the original.
  cp -p "${file}" "${dest}" || die "backup_file: failed to back up ${file} to ${dest}"
  log_info "backed up ${file} -> ${dest}"
  printf '%s' "${dest}"
}

# ------------------------------------------------------------------ origin/host

# Bare host (no scheme, no port) of an origin like https://acme.example.com or
# https://acme.example.com:3000. Pure string surgery, no validation — callers
# that need a portless host (caddy) or a routable DNS record name (provision.sh)
# layer their own checks on top; see caddy_host_from_origin below.
origin_host() { # ORIGIN
  local rest=${1#*://}
  printf '%s' "${rest%%:*}"
}

# "HOST PORT" of a postgres DSN, for a pre-migrate TCP reachability probe.
# Prints NOTHING when the DSN carries no explicit host:port pair (a unix
# socket, a portless URL, an empty value) — callers treat that as "no probe
# target", not as an error.
#
# Deliberately narrow: it prints the host and the port and nothing else. A DSN
# embeds a role password, and this result IS logged.
dsn_host_port() { # DSN
  local dsn=${1:-}
  [[ ${dsn} =~ @([^:/@]+):([0-9]+)/ ]] || return 0
  printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# ------------------------------------------------------------------ ingress (caddy)

# Extract the bare host from a validated core.origin for use as a Caddyfile
# site address. Caddy owns 443 when ingress is enabled (it terminates TLS with
# the supplied origin certificate and proxies to 127.0.0.1:<core.port>), so an
# origin with an explicit port would leave the vhost listening on the wrong
# thing — reject it with a clear message instead of silently dropping the port.
caddy_host_from_origin() { # ORIGIN
  local origin=$1 rest=${1#*://}
  [[ ${rest} != *:* ]] ||
    die "config: ingress.caddy requires a portless core.origin (caddy owns 443 and proxies to 127.0.0.1:<core.port>) — got '${origin}'"
  origin_host "${origin}"
}

# ---------------------------------------------------------------- origin TLS
#
# TLS IS NOT ACME ANYWHERE IN THIS TOOLKIT. Every hostname is proxied through
# Cloudflare and the origin presents a Cloudflare Origin CA certificate that
# the operator supplies (ingress.tls_cert_path / ingress.tls_key_path). Do not
# "improve" this back to Let's Encrypt:
#
#   * Let's Encrypt allows 50 certificates per REGISTERED DOMAIN per week,
#     shared across every *.hiretau.ai subdomain. Per-tenant ACME therefore
#     caps signups at 50/week — and issuance happens AFTER payment, so a
#     failure there is a paid-but-broken tenant.
#   * An Origin CA certificate is trusted by Cloudflare's proxy and by nothing
#     else. It REQUIRES the hostname to be proxied (orange cloud) — see
#     cf_dns_record_body's proxied:true. There is no half-measure.
#   * One certificate covers both `hiretau.ai` and `*.hiretau.ai` and is valid
#     for years, so nothing here does per-host issuance or renewal. That is the
#     entire point of the switch.
#
# Caddy needs no port 80 for this (there is no HTTP-01 challenge to answer).
#
# Canonical on-host locations, installed by install_origin_cert and referenced
# by both rendered Caddyfiles. Overridable via env (default unchanged) SOLELY
# so a test can point the mutating helpers at a scratch directory instead of
# the real /etc/caddy/tls — setup-host.sh/upgrade-host.sh never set this
# variable, so their behavior is unaffected.
CADDY_TLS_DIR="${CADDY_TLS_DIR:-/etc/caddy/tls}"
CADDY_TLS_CERT_PATH="${CADDY_TLS_DIR}/origin.crt"
CADDY_TLS_KEY_PATH="${CADDY_TLS_DIR}/origin.key"
CADDY_APPS_TLS_CERT_PATH="${CADDY_TLS_DIR}/apps-origin.crt"
CADDY_APPS_TLS_KEY_PATH="${CADDY_TLS_DIR}/apps-origin.key"

preflight_tls_source() { # CONFIG_KEY PATH
  local config_key=$1 path=$2
  [[ -f ${path} ]] || die "${config_key}: file not found: ${path}"
  [[ -r ${path} ]] || die "${config_key}: file is not readable: ${path}"
}

# True (exit 0) iff CERT's public key matches KEY's — i.e. this certificate
# and private key are actually a pair. Compares derived public keys
# (openssl pkey -pubout), not moduli, so it works for RSA and EC certificates
# alike — a Cloudflare Origin CA cert can be either. Callers that want a
# distinct "file not found"/"not readable" error should run
# preflight_tls_source first: a missing or malformed file here just reads as
# a mismatch (return 1), not a die. `-passin pass:` deliberately passes an
# EMPTY passphrase rather than none: an encrypted key then fails immediately
# as a wrong-passphrase error (→ mismatch) instead of openssl blocking on an
# interactive passphrase prompt with no TTY to answer it — which, run as
# root on a live tenant, would just hang the whole retarget.
tls_pair_matches() { # CERT KEY
  local cert=$1 key=$2 cert_pub key_pub
  cert_pub=$(openssl x509 -in "${cert}" -noout -pubkey 2>/dev/null) || return 1
  key_pub=$(openssl pkey -in "${key}" -passin pass: -pubout 2>/dev/null) || return 1
  [[ -n ${cert_pub} && ${cert_pub} == "${key_pub}" ]]
}

preflight_public_certificate() { # CONFIG_KEY PATH
  local config_key=$1 path=$2 basic_constraints
  preflight_tls_source "${config_key}" "${path}"
  basic_constraints=$(openssl x509 -in "${path}" -noout -ext basicConstraints 2>/dev/null) ||
    die "${config_key}: file does not contain a valid X.509 CA certificate: ${path}"
  grep -Eq 'CA:[[:space:]]*TRUE' <<<"${basic_constraints}" ||
    die "${config_key}: file does not contain a valid X.509 CA certificate: ${path}"
}

# Install a supplied cert/key pair to explicit canonical paths. The KEY is
# 0600 and owned by caddy's own service user — it is the only reader (caddy's
# packaged unit runs as User=caddy), and the certificate is useless to an
# attacker without it. Never cat/echo either file: only paths are ever logged.
#
# Requires the caddy package to already be installed (install_caddy), since
# that is what creates the caddy user.
install_origin_cert() { # CERT_SRC KEY_SRC [CERT_DEST KEY_DEST]
  local cert=$1 key=$2 cert_dest=${3:-${CADDY_TLS_CERT_PATH}} key_dest=${4:-${CADDY_TLS_KEY_PATH}}
  [[ -f ${cert} ]] || die "origin certificate not found: ${cert}"
  [[ -f ${key} ]] || die "origin private key not found: ${key}"
  [[ $(dirname "${cert_dest}") == "${CADDY_TLS_DIR}" && $(dirname "${key_dest}") == "${CADDY_TLS_DIR}" ]] ||
    die "origin certificate destinations must be inside ${CADDY_TLS_DIR}"
  id -u caddy >/dev/null 2>&1 ||
    die "the 'caddy' service user does not exist — install caddy before the origin certificate"
  # Explicit `|| die` on each — never left to errexit. A caller that
  # invokes this from inside a subshell being used as an if/&&/||
  # condition (retarget-origin.sh's cert-restore span does exactly that,
  # to contain a die()'s exit to the subshell) runs with errexit silently
  # suppressed for everything in that subshell, INCLUDING a `set -e`
  # restated inside it — bash disables -e for the whole dynamic extent of
  # evaluating such a condition and that suppression is NOT one a nested
  # `set -e` can undo. A failed install here would otherwise be silently
  # ignored, continuing as if the cert/key had been installed.
  as_root install -d -m 0755 -o root -g root "${CADDY_TLS_DIR}" ||
    die "failed to create ${CADDY_TLS_DIR}"
  as_root install -m 0644 -o root -g root "${cert}" "${cert_dest}" ||
    die "failed to install the origin certificate to ${cert_dest}"
  as_root install -m 0600 -o caddy -g caddy "${key}" "${key_dest}" ||
    die "failed to install the origin private key to ${key_dest}"
  log_info "installed origin certificate ${cert_dest} (0644) + key ${key_dest} (0600, caddy-owned)"
}

# -------------------------------------------------------------- database TLS
#
# CA certificate for an EXTERNAL postgres (database.ca_path). Canonical on-host
# location, and the ONE path a tenant DSN's `sslrootcert` may name.
#
# This constant is half of a two-sided contract: the other half is
# the managed database configuration, which writes this path into each DSN.
# Change one and you MUST change the other — under `sslmode=verify-full` a
# mismatch is not a degradation but a total connection failure, because
# verify-full has no fallback to fall back to. That is the point: `require`
# would happily connect to an impostor.
FICUS_DB_CA_DIR='/etc/tau'
FICUS_DB_CA_PATH="${FICUS_DB_CA_DIR}/database-ca.crt"

# Install the supplied database CA to the canonical path above.
#
# 0644 and root-owned, DELIBERATELY unlike the origin key next door: a CA
# certificate is a public document, and several unprivileged readers need it —
# the tau api and worker units (which run as the configured run user, not
# root) and pg_dump inside the nightly backup. Locking it down would only
# break them. The private key is the secret; this is not.
install_database_ca() { # CA_SRC
  local ca=$1
  [[ -f ${ca} ]] || die "database.ca_path: CA certificate not found: ${ca}"
  as_root install -d -m 0755 -o root -g root "${FICUS_DB_CA_DIR}"
  as_root install -m 0644 -o root -g root "${ca}" "${FICUS_DB_CA_PATH}"
  log_info "installed database CA ${FICUS_DB_CA_PATH} (0644)"
}

# ------------------------------------------------------ managed artifacts
#
# Fleet-wide platform-managed credentials, delivered as a STAGING DIRECTORY
# built by the control plane
# and installed here. ONE staging layout, two callers: setup-host.sh's
# phase_artifacts at provision, and apply-artifacts.sh over ssh on a later
# sync. Both call the two functions below, so the on-host result is identical
# regardless of path.
#
#   <stage>/managed.env      -> /etc/tau/managed.env  (0600 root)  [env artifacts]
#   <stage>/files/<target>   -> /etc/tau/artifacts/<target>        [file artifacts]
#   <stage>/manifest          "<mode> <target>" per file artifact
#
# FICUS_MANAGED_ENV_PATH is half of a two-sided contract: the OTHER half is the
# `EnvironmentFile=-/etc/tau/managed.env` line in systemd/tau-api.service.tmpl
# and tau-worker.service.tmpl. Change one and you must change the other.
#
# FICUS_ARTIFACTS_DIR is EXCLUSIVELY artifact-managed: nothing but these install
# functions ever writes into it. Everything else the toolkit places lives
# elsewhere — the database CA at /etc/tau/database-ca.crt, managed.env at
# /etc/tau/managed.env (both SIBLINGS of this dir, never inside it), Caddy TLS
# material under /etc/caddy/tls, units under /etc/systemd/system. That
# exclusivity is what makes prune_artifacts safe: any file in this dir that
# the current manifest doesn't list can only be a leftover of a DELETED
# artifact, so removing it is reconciliation, not collateral damage.
#
# These three are also seams (lib.test.sh points them at scratch dirs). Until
# phase 5 either spelling may be set BEFORE sourcing this file — the control
# plane's own scripts still set the TAU_ one — and the TAU_ name stays an
# alias of the same value. A caller that overrides one AFTER sourcing must
# use the FICUS_ name: that is the one every function here reads.
FICUS_ARTIFACTS_DIR=${FICUS_ARTIFACTS_DIR:-${TAU_ARTIFACTS_DIR:-/etc/tau/artifacts}}
FICUS_MANAGED_ENV_PATH=${FICUS_MANAGED_ENV_PATH:-${TAU_MANAGED_ENV_PATH:-/etc/tau/managed.env}}
# Where the tau-api/tau-worker units live (overridden in lib.test.sh).
FICUS_SYSTEMD_UNIT_DIR=${FICUS_SYSTEMD_UNIT_DIR:-${TAU_SYSTEMD_UNIT_DIR:-/etc/systemd/system}}
TAU_ARTIFACTS_DIR=${FICUS_ARTIFACTS_DIR}
TAU_MANAGED_ENV_PATH=${FICUS_MANAGED_ENV_PATH}
TAU_SYSTEMD_UNIT_DIR=${FICUS_SYSTEMD_UNIT_DIR}

# Install the staged managed.env (all platform-managed env credentials) to the
# canonical path the units reference. 0600 root — it holds live credentials.
# No-op when the staging dir carries no managed.env. Atomic via
# install_rendered: staged to a private tmp, verified non-empty, then
# install(1)ed over the destination — never a truncating direct write.
install_managed_env() { # STAGE_DIR
  local stage=$1
  local src="${stage}/managed.env"
  [[ -f ${src} ]] || return 0
  as_root install -d -m 0755 -o root -g root "$(dirname "${FICUS_MANAGED_ENV_PATH}")"
  install_rendered 0600 root root "${FICUS_MANAGED_ENV_PATH}" cat "${src}"
  log_info "installed ${FICUS_MANAGED_ENV_PATH} (0600)"
}

# Install staged artifact FILES to FICUS_ARTIFACTS_DIR, each with the mode
# recorded in the staging manifest. No-op when there is no manifest. File-kind
# artifacts (e.g. APNs certificates) are read per-use by the app, so installing
# or updating one does NOT restart any service — only a managed.env change
# does (the sync executor owns that decision).
install_artifacts() { # STAGE_DIR
  local stage=$1
  local manifest="${stage}/manifest"
  [[ -f ${manifest} ]] || return 0
  as_root install -d -m 0755 -o root -g root "${FICUS_ARTIFACTS_DIR}"
  local mode target src
  while read -r mode target; do
    [[ -n ${mode} && -n ${target} ]] || continue
    # Defense in depth over the registry's own validation: an artifact may
    # never escape the fixed root. A bare basename only.
    case "${target}" in
      */* | .. | .) die "install_artifacts: refusing unsafe artifact target '${target}'" ;;
    esac
    [[ ${mode} =~ ^0[0-7]{3}$ ]] || die "install_artifacts: invalid mode '${mode}' for '${target}'"
    src="${stage}/files/${target}"
    [[ -f ${src} ]] || die "install_artifacts: staged file missing for '${target}': ${src}"
    install_rendered "${mode}" root root "${FICUS_ARTIFACTS_DIR}/${target}" cat "${src}"
    log_info "installed ${FICUS_ARTIFACTS_DIR}/${target} (${mode})"
  done <"${manifest}"
}

# Would installing <stage>/managed.env CHANGE the effective managed
# environment of the tau services? Prints 1 or 0. The sync executor restarts
# tau-api/tau-worker only when this says 1 (file-kind artifacts are read
# per-use and never need a restart), so the comparison is deliberately
# SEMANTIC, not byte-level:
#   * destination exists      -> changed iff the bytes differ (header lines are
#                                constants, so byte-compare == var-compare);
#   * destination absent      -> changed iff the staged file carries at least
#                                one actual KEY=VALUE line. A header-only
#                                managed.env loads zero variables — exactly
#                                what an absent (optional, `-` prefixed)
#                                EnvironmentFile loads — so materializing it
#                                on a tenant with no env artifacts must NOT
#                                restart the whole fleet's services for a
#                                semantic no-op.
# No-op (prints 0) when the staging dir has no managed.env at all.
managed_env_would_change() { # STAGE_DIR
  local stage=$1
  local src="${stage}/managed.env"
  if [[ ! -f ${src} ]]; then
    echo 0
    return 0
  fi
  if [[ -f ${FICUS_MANAGED_ENV_PATH} ]]; then
    if cmp -s "${src}" "${FICUS_MANAGED_ENV_PATH}"; then echo 0; else echo 1; fi
  else
    # KEY=VALUE lines start with a non-#, non-blank character.
    if grep -q '^[^#[:space:]]' "${src}"; then echo 1; else echo 0; fi
  fi
}

# Remove every file under FICUS_ARTIFACTS_DIR that the staging manifest does NOT
# list — the deletion half of reconciliation: an artifact deleted from the
# platform registry vanishes from the manifest, and this sweeps its installed
# file off the host. Constrained BY CONSTRUCTION to FICUS_ARTIFACTS_DIR: names
# come from globbing that directory itself (basename only, no recursion), and
# removal re-joins them onto the same fixed root — nothing outside the dir can
# ever be touched. Safe because the dir is exclusively artifact-managed (see
# the FICUS_ARTIFACTS_DIR comment above). Fails safe twice over: no manifest
# means "set unknown — prune nothing", and a missing dir means nothing to do.
prune_artifacts() { # STAGE_DIR
  local stage=$1
  local manifest="${stage}/manifest"
  [[ -f ${manifest} ]] || return 0
  [[ -d ${FICUS_ARTIFACTS_DIR} ]] || return 0
  local existing name mode target keep
  for existing in "${FICUS_ARTIFACTS_DIR}"/*; do
    [[ -e ${existing} || -L ${existing} ]] || continue # empty-dir glob literal
    name=$(basename -- "${existing}")
    keep=0
    while read -r mode target; do
      [[ -n ${mode} && -n ${target} ]] || continue
      if [[ ${target} == "${name}" ]]; then keep=1; fi
    done <"${manifest}"
    if [[ ${keep} -eq 0 ]]; then
      as_root rm -f -- "${FICUS_ARTIFACTS_DIR}/${name}"
      log_info "pruned ${FICUS_ARTIFACTS_DIR}/${name} (no longer in the artifact manifest)"
    fi
  done
}

# Ensure the tau-api/tau-worker units actually LOAD managed.env — the fix for
# tenants provisioned before the units' templates gained the
# `EnvironmentFile=-/etc/tau/managed.env` line: on such hosts a sync would
# install managed.env, restart the services, and report success while the
# running processes never saw a single variable (verified live: unit file
# without the line, /proc/<pid>/environ without the keys). For each unit whose
# INSTALLED unit file lacks a reference to managed.env, write a systemd
# drop-in (<unit>.service.d/managed-env.conf) carrying exactly that line.
# Sets MANAGED_ENV_DROPIN_CHANGED=1 iff a drop-in was created or corrected —
# the sync executor daemon-reloads AND restarts on that signal (the services'
# effective environment gains the managed.env contents, so a restart is what
# makes the fix real). Idempotent: units that already carry the line inline
# (every post-template-change provision), or an already-correct drop-in, are
# left untouched and don't set the flag — no spurious fleet-wide reloads.
# shellcheck disable=SC2034 # consumed by apply-artifacts.sh and lib.test.sh
MANAGED_ENV_DROPIN_CHANGED=0
# shellcheck disable=SC2034 # MANAGED_ENV_DROPIN_CHANGED is consumed by the sourcing scripts
ensure_managed_env_dropins() {
  MANAGED_ENV_DROPIN_CHANGED=0
  local unit unit_file dropin content
  content=$'[Service]\nEnvironmentFile=-/etc/tau/managed.env'
  for unit in tau-api tau-worker; do
    unit_file="${FICUS_SYSTEMD_UNIT_DIR}/${unit}.service"
    dropin="${FICUS_SYSTEMD_UNIT_DIR}/${unit}.service.d/managed-env.conf"
    if [[ -f ${unit_file} ]] && grep -qF '/etc/tau/managed.env' "${unit_file}"; then
      continue # unit already loads managed.env inline
    fi
    if [[ -f ${dropin} && $(cat "${dropin}") == "${content}" ]]; then
      continue # drop-in already in place and correct
    fi
    as_root install -d -m 0755 -o root -g root "$(dirname "${dropin}")"
    install_rendered 0644 root root "${dropin}" printf '%s\n' "${content}"
    MANAGED_ENV_DROPIN_CHANGED=1
    log_info "installed ${dropin} (unit file lacked the managed.env EnvironmentFile line)"
  done
}

# ---------------------------------------------------------- core unit files
#
# The tau-api/tau-worker units are rendered from the same templates by BOTH
# setup-host.sh (provision) and upgrade-host.sh (artifact upgrades), which is
# why the renderer lives here rather than in either script: two copies of this
# sed would drift, and a drifted unit is the failure mode where `git log`
# reports the new commit while systemd keeps running the old tree.
#
# The templates carry two different roots on purpose:
#   @DEST@      the box's install root — where .env lives, and the ONLY place
#               it lives (a release tree carries no secrets of its own)
#   @RUN_ROOT@  the tree the services actually run FROM: <dest>/current under
#               the artifact layout, <dest> itself for a git checkout
#
# Caller globals (the toolkit's established convention — see git_source_sync):
# SRC_DEST, RUN_USER, BUN_BIN, DB_MODE, and optionally CORE_LAYOUT.

# Where the units' WorkingDirectory points. `releases/` existing is the
# on-disk proof of the artifact layout; CORE_LAYOUT=artifact forces it for the
# window during a first conversion where the caller knows the layout is about
# to exist but the directory state does not say so yet.
core_run_root() { # DEST
  if [[ ${CORE_LAYOUT:-} == artifact || -d $1/releases ]]; then
    printf '%s/current\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# shellcheck disable=SC2153 # SRC_DEST/RUN_USER/BUN_BIN/DB_MODE are CALLER
# globals (setup-host.sh, upgrade-host.sh), not typos of the locals below.
render_core_unit() { # TEMPLATE_FILE
  local bun_dir db_after='' run_root
  bun_dir=$(dirname "${BUN_BIN}")
  [[ ${DB_MODE:-} == container ]] && db_after=' docker.service'
  run_root=$(core_run_root "${SRC_DEST}")
  sed -e "s|@DEST@|${SRC_DEST}|g" \
    -e "s|@RUN_ROOT@|${run_root}|g" \
    -e "s|@RUN_USER@|${RUN_USER}|g" \
    -e "s|@BUN_BIN@|${BUN_BIN}|g" \
    -e "s|@BUN_DIR@|${bun_dir}|g" \
    -e "s|@DB_AFTER@|${db_after}|g" \
    "$1"
}

# The unit templates name FICUS_ROOT. A release that predates the Ficus rename
# reads TAU_ROOT instead, so its units are rendered through this filter
# (stdin -> stdout): TAU turns every Environment=FICUS_… assignment into the
# TAU_ spelling, FICUS passes the render through unchanged.
core_unit_prefix_filter() { # PREFIX
  case "$1" in
    FICUS) cat ;;
    TAU) sed -E 's/^Environment=("?)FICUS_/Environment=\1TAU_/' ;;
    *)
      log_error "core_unit_prefix_filter: prefix must be FICUS or TAU (got '$1')"
      return 1
      ;;
  esac
}

# render_core_unit piped through core_unit_prefix_filter; pipefail in the
# subshell so a failed render is a failed render whatever the caller set.
render_core_unit_for_prefix() { # PREFIX TEMPLATE_FILE
  (
    set -o pipefail
    render_core_unit "$2" | core_unit_prefix_filter "$1"
  )
}

# Render + install both core units, in the env spelling PREFIX (default FICUS)
# the release that will run them reads: the conversion branch, the pre-flip
# hook and the env-restore of a converted host each pass the prefix of the
# release they are rendering for, so a pre-rename release is never started
# with a unit it cannot read. --check-placeholders is load-bearing: a
# sed expression that matches nothing "succeeds", and a unit that reaches
# systemd with a literal @RUN_ROOT@ in its WorkingDirectory simply refuses to
# start. Does NOT daemon-reload — callers own that (and the restart) so a
# reload happens exactly once per run.
install_core_units() { # TEMPLATE_DIR [PREFIX]
  local template_dir=$1 prefix=${2:-FICUS} unit
  _epr_is_prefix "${prefix}" || die "install_core_units: prefix must be FICUS or TAU (got '${prefix}')"
  for unit in tau-api tau-worker; do
    install_rendered --check-placeholders 0644 root root \
      "${FICUS_SYSTEMD_UNIT_DIR}/${unit}.service" \
      render_core_unit_for_prefix "${prefix}" "${template_dir}/${unit}.service.tmpl"
  done
}

# Canonical tau-api cgroup policy. Fresh units carry this inline; legacy units
# receive the same policy through the managed drop-in below.
tau_api_memory_guardrail_content() {
  printf '%s\n' '[Unit]' \
    'StartLimitIntervalSec=300s' \
    'StartLimitBurst=5' \
    '' \
    '[Service]' \
    'MemoryAccounting=yes' \
    'MemoryHigh=25%' \
    'MemoryMax=35%' \
    'OOMPolicy=kill' \
    'Restart=on-failure' \
    'RestartSec=5s'
}

# shellcheck disable=SC2034 # consumed by maintenance scripts and tests
FICUS_API_MEMORY_GUARDRAIL_CHANGED=0
ensure_tau_api_memory_guardrail() {
  FICUS_API_MEMORY_GUARDRAIL_CHANGED=0
  local unit_file="${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
  local dropin_dir="${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d"
  local content effective=0 candidate
  content=$(tau_api_memory_guardrail_content)

  # systemd merges drop-ins in C-locale lexical order and scalar directives
  # use the final assignment. Parse that exact sequence; mere presence of the
  # desired text in an earlier file is not sufficient.
  local -a policy_files=("${unit_file}")
  if [[ -d ${dropin_dir} ]]; then
    while IFS= read -r candidate; do policy_files+=("${candidate}"); done < <(
      find "${dropin_dir}" -maxdepth 1 -type f -name '*.conf' -print | LC_ALL=C sort
    )
  fi
  if [[ -f ${unit_file} ]] && awk '
    /^\[.*\]$/ { section=$0; next }
    /^[[:space:]]*[#;]/ { next }
    {
      pos=index($0, "="); if (!pos) next
      key=substr($0, 1, pos-1); value=substr($0, pos+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (section == "[Unit]" && (key == "StartLimitIntervalSec" || key == "StartLimitBurst")) unit[key]=value
      if (section == "[Service]" && (key == "MemoryAccounting" || key == "MemoryHigh" || key == "MemoryMax" || key == "OOMPolicy" || key == "Restart" || key == "RestartSec")) service[key]=value
    }
    END {
      exit !(unit["StartLimitIntervalSec"] == "300s" && unit["StartLimitBurst"] == "5" &&
        service["MemoryAccounting"] == "yes" && service["MemoryHigh"] == "25%" &&
        service["MemoryMax"] == "35%" && service["OOMPolicy"] == "kill" &&
        service["Restart"] == "on-failure" && service["RestartSec"] == "5s")
    }
  ' "${policy_files[@]}"; then
    effective=1
  fi
  [[ ${effective} -eq 0 ]] || return 0

  # Choose a name provably later than the current lexical maximum instead of
  # guessing a large prefix. Replacing the maximum file's .conf suffix with a
  # longer suffix preserves its full prefix and compares later at the first
  # differing byte. A future still-later operator file is handled the same way
  # on the next reconciliation; unrelated drop-ins are never modified.
  local dropin="${dropin_dir}/memory-guardrail.conf" max_base max_stem
  if (( ${#policy_files[@]} > 1 )); then
    max_base=$(basename -- "${policy_files[${#policy_files[@]}-1]}")
    if [[ ${max_base} == memory-guardrail.conf || ${max_base} == *.z-tau-memory-guardrail.conf ]]; then
      dropin="${dropin_dir}/${max_base}" # repair the already-final managed file
    else
      max_stem=${max_base%.conf}
      dropin="${dropin_dir}/${max_stem}.z-tau-memory-guardrail.conf"
    fi
  fi
  as_root install -d -m 0755 -o root -g root "${dropin_dir}" || die "could not create ${dropin_dir}"
  install_rendered 0644 root root "${dropin}" printf '%s\n' "${content}"
  FICUS_API_MEMORY_GUARDRAIL_CHANGED=1
  log_info "installed ${dropin} (made the canonical tau-api memory policy the effective final assignment)"
}

# ------------------------------------------------------------------ restore
#
# Restore-from-backup unpack primitive. A tenant backup envelope (produced by
# tau-backup.sh.tmpl) is an openssl-encrypted gzip tar whose top-level members
# are, exactly: `db.dump` (a `pg_dump -Fc` custom-format dump), the HOME_DIR
# tree (a single directory, e.g. `.tau/`), and the instance `.env` (which
# carries FICUS_ENCRYPTION_KEY). This decrypts + extracts one, asserting the
# envelope shape, so setup-host.sh's phase_restore can pg_restore the dump,
# lay down the workspace tree, and carry the encryption key forward.
#
# The passphrase is read from PASSFILE (a 0600 tmpfile the caller writes from
# $FICUS_SETUP_RESTORE_PASSPHRASE) and NEVER passed on argv — same discipline as
# tau-backup.sh.tmpl's own `-pass file:` encryption. The openssl parameters
# here (aes-256-cbc + pbkdf2) mirror that template exactly; changing one side
# without the other makes every existing backup undecryptable.
#
# Pure enough to unit-test: lib.test.sh builds a miniature envelope with a
# known passphrase and round-trips it through this function.
restore_unpack_archive() { # ENC_FILE PASSFILE OUT_DIR
  local enc=$1 passfile=$2 out=$3
  [[ -f ${enc} ]] || die "restore: encrypted backup archive not found: ${enc}"
  [[ -f ${passfile} ]] || die "restore: passphrase file not found: ${passfile}"
  [[ -d ${out} ]] || die "restore: output directory does not exist: ${out}"
  local tar_file="${out}/backup.tar.gz"
  # Wrong passphrase, or a corrupt/truncated download, both surface here as a
  # non-zero openssl exit — die loudly rather than proceeding to extract
  # garbage. openssl auto-reads the salt from the "Salted__" header, so `-salt`
  # is only needed on the encrypt side.
  openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:${passfile}" -in "${enc}" -out "${tar_file}" 2>/dev/null ||
    die "restore: could not decrypt the backup archive (wrong passphrase, or a corrupt/truncated download)"
  tar -xzf "${tar_file}" -C "${out}" ||
    die "restore: could not extract the decrypted backup archive"
  rm -f "${tar_file}"
  [[ -f ${out}/db.dump ]] || die "restore: archive is missing db.dump — not a tau backup envelope"
  [[ -f ${out}/.env ]] || die "restore: archive is missing .env — not a tau backup envelope"
}

# The sole top-level DIRECTORY extracted from a backup envelope — the HOME_DIR
# workspace tree (db.dump and .env are files, so they're excluded). Prints its
# path, or nothing if the archive carried no workspace directory. Kept separate
# from restore_unpack_archive so the source's HOME_DIR basename (which may
# differ from the target's) never has to be guessed.
restore_home_subdir() { # OUT_DIR
  find "$1" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1
}

# Render a single-origin Caddyfile vhost for HOST, proxying to core on PORT and
# serving the supplied origin certificate. No ACME, no global options block —
# see the doctrine comment above.
render_caddyfile() { # HOST PORT CERT_PATH KEY_PATH
  local host=$1 port=$2 cert=$3 key=$4
  printf '%s {\n    tls %s %s\n    reverse_proxy 127.0.0.1:%s\n}\n' "${host}" "${cert}" "${key}" "${port}"
}

# Overridable via env (default unchanged) for the same reason as
# CADDY_TLS_DIR above — a test-only seam, not a real config knob.
CADDYFILE_PATH="${CADDYFILE_PATH:-/etc/caddy/Caddyfile}"

# Validate a staged Caddyfile as root so Caddy can also open the 0600 TLS keys.
# The caller owns FILE and removes it after validation.
caddy_validate_file() { # FILE
  local file=$1
  as_root caddy validate --config "${file}" --adapter caddyfile >/dev/null
}

caddy_validate_rendered() { # CONTENT
  local rendered=$1 staged
  [[ -n ${rendered} ]] || die "refusing to validate an empty Caddyfile"
  staged=$(mktemp)
  chmod 600 "${staged}"
  printf '%s' "${rendered}" >"${staged}"
  if ! caddy_validate_file "${staged}"; then
    rm -f "${staged}"
    die "Caddy rejected the staged configuration; the live Caddyfile was not changed"
  fi
  rm -f "${staged}"
}

# Replace the live Caddyfile with a sibling staged file, so the final rename is
# atomic on the destination filesystem rather than a truncate-and-copy.
caddy_install_atomically() { # SOURCE
  local source=$1 live_stage
  live_stage=$(as_root mktemp "${CADDYFILE_PATH}.tau-new.XXXXXX")
  if ! as_root install -m 0644 -o root -g root "${source}" "${live_stage}"; then
    as_root rm -f "${live_stage}" || true
    die "failed to stage ${CADDYFILE_PATH}"
  fi
  if ! as_root mv -f "${live_stage}" "${CADDYFILE_PATH}"; then
    as_root rm -f "${live_stage}" || true
    die "failed to atomically replace ${CADDYFILE_PATH}"
  fi
}

# Idempotent Caddyfile install: validate before an atomic replacement and
# RELOAD (never restart) an already-running Caddy. A failed reload restores the
# prior on-disk bytes and reloads that known-good configuration again.
caddy_write_and_reload() { # CONTENT
  local rendered=$1 current='' was_active=0 changed=0 staged='' backup='' had_current=0
  # The content arrives via a `$(render_…)` command substitution, and a render
  # that died inside one yields an EMPTY string in an -e-suppressed context —
  # never let that become an empty Caddyfile (or "unchanged" against an
  # already-empty one).
  [[ -n ${rendered} ]] || die "refusing to install ${CADDYFILE_PATH}: rendered Caddyfile is empty"
  as_root systemctl is-active --quiet caddy 2>/dev/null && was_active=1
  if [[ -f ${CADDYFILE_PATH} ]]; then
    had_current=1
    current=$(as_root cat "${CADDYFILE_PATH}")
  fi
  if [[ ${rendered} != "${current}" ]]; then
    # Staging-file setup and the staged write are each checked explicitly,
    # never left to errexit (see the backup-write note below for why) —
    # `caddy validate` is NOT relied on as a backstop for them: a staging
    # file that silently came out empty or short could still validate.
    staged=$(mktemp) || die "failed to create a staging file for ${CADDYFILE_PATH}"
    if ! backup=$(mktemp); then
      rm -f "${staged}"
      die "failed to create a backup file for ${CADDYFILE_PATH}"
    fi
    if ! chmod 600 "${staged}" "${backup}"; then
      rm -f "${staged}" "${backup}"
      die "failed to restrict the permissions of the staged ${CADDYFILE_PATH}"
    fi
    if ! printf '%s' "${rendered}" >"${staged}"; then
      rm -f "${staged}" "${backup}"
      die "failed to write the staged ${CADDYFILE_PATH}; the live Caddyfile was not changed"
    fi
    if ! caddy_validate_file "${staged}"; then
      rm -f "${staged}" "${backup}"
      die "Caddy rejected the staged configuration; the live Caddyfile was not changed"
    fi
    # Explicit check, never left to errexit (same reasoning as
    # install_origin_cert above: a caller running this from inside an
    # if/&&/||-condition subshell has errexit silently suppressed for
    # everything in it, unrecoverably by a nested `set -e`). Without this
    # check, a failed backup write here would leave `${backup}` a 0-byte
    # file that a later failed enable/reload below would then "restore",
    # taking Caddy down with an EMPTY config instead of the real prior one.
    if [[ ${had_current} -eq 1 ]] && ! as_root cat "${CADDYFILE_PATH}" >"${backup}"; then
      rm -f "${staged}" "${backup}"
      die "failed to back up the current ${CADDYFILE_PATH} before installing the new one — refusing to proceed without a valid rollback target"
    fi
    caddy_install_atomically "${staged}"
    changed=1
  fi
  if ! as_root systemctl enable --now caddy; then
    if [[ ${changed} -eq 1 ]]; then
      if [[ ${had_current} -eq 1 ]]; then caddy_install_atomically "${backup}"; else as_root rm -f "${CADDYFILE_PATH}"; fi
    fi
    rm -f "${staged}" "${backup}"
    die "failed to enable or start caddy; restored the prior Caddyfile"
  fi
  if [[ ${changed} -eq 1 && ${was_active} -eq 1 ]]; then
    log_info "Caddyfile content changed — reloading caddy"
    if ! as_root systemctl reload caddy; then
      if [[ ${had_current} -eq 1 ]]; then caddy_install_atomically "${backup}"; else as_root rm -f "${CADDYFILE_PATH}"; fi
      as_root systemctl reload caddy >/dev/null 2>&1 || true
      rm -f "${staged}" "${backup}"
      die "Caddy reload failed; restored the prior Caddyfile"
    fi
  elif [[ ${changed} -eq 1 ]]; then
    log_info "wrote ${CADDYFILE_PATH} — caddy started fresh with it"
  else
    log_info "Caddyfile unchanged — no reload needed"
  fi
  rm -f "${staged}" "${backup}"
}

install_caddy() {
  have caddy && return 0
  log_info "installing caddy (official cloudsmith apt repo)"
  as_root apt-get update -qq
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    debian-keyring debian-archive-keyring apt-transport-https curl
  # Fetch to temp files FIRST, then install. `curl … | tee` writes an EMPTY
  # apt source when the fetch 404s, and a zero-byte .list poisons every later
  # `apt-get update` on the host — observed when cloudsmith's path moved.
  local _key _list
  _key=$(mktemp) _list=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${_key}' '${_list}'" RETURN
  curl -1sLf -o "${_key}" 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' ||
    die "caddy: could not fetch the cloudsmith signing key"
  # NOTE: 'debian.deb.txt', not 'debian.txt' — cloudsmith's older path 404s.
  curl -1sLf -o "${_list}" 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' ||
    die "caddy: could not fetch the cloudsmith apt source list"
  [[ -s ${_key} && -s ${_list} ]] || die "caddy: cloudsmith returned an empty key or source list"
  as_root gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg <"${_key}"
  as_root install -m 0644 "${_list}" /etc/apt/sources.list.d/caddy-stable.list
  as_root apt-get update -qq
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
}

# ------------------------------------------------------------------ swap
#
# Ensure a swapfile exists. The tenant tier is a 2GB droplet (Postgres moved
# to the shared managed cluster, so the RUNTIME fits comfortably) — but the
# BUILD does not: vite/rollup bundling the web app peaks well above what 2GB
# with no swap can serve. Observed on the first real tenant provision: the box
# sat at 1914MB/1967MB with kswapd0 burning CPU, the build crawled for ten
# minutes and then died. With 4GB of swap the same build completes in ~23s and
# touches ~273MB of it.
#
# Cloud images ship with no swap at all, so this is not "tuning" — it is the
# difference between provisioning working and not. Idempotent: a second run
# finds the file and returns.
swap_path_is_active() { # PATH
  swapon --show=NAME --noheadings 2>/dev/null |
    awk -v path="$1" '$1 == path { found=1 } END { exit !found }'
}

swap_fstab_has_entry() { # PATH FSTAB
  awk -v path="$1" '$1 == path && $3 == "swap" { found=1 } END { exit !found }' "$2" 2>/dev/null
}

install_fstab_atomically() { # SOURCE FSTAB
  local source=$1 fstab=$2 staged="${fstab}.tau-new.$$"
  cleanup_swap_temp "${staged}"
  if ! as_root install -m 0644 -o root -g root "${source}" "${staged}"; then
    cleanup_swap_temp "${staged}"
    return 1
  fi
  if ! as_root sync -f "${staged}"; then
    cleanup_swap_temp "${staged}"
    return 1
  fi
  if ! as_root mv -f -- "${staged}" "${fstab}"; then
    cleanup_swap_temp "${staged}"
    return 1
  fi
}

ensure_swap_fstab_entry() { # PATH
  local path=$1 fstab=${FICUS_SWAP_FSTAB:-${TAU_SWAP_FSTAB:-/etc/fstab}}
  local counts matching canonical temp
  counts=$(awk -v path="${path}" '
    $1 == path && $3 == "swap" { matching++ }
    $1 == path && $2 == "none" && $3 == "swap" && $4 == "sw" && $5 == 0 && $6 == 0 { canonical++ }
    END { print matching+0, canonical+0 }
  ' "${fstab}" 2>/dev/null) || return 1
  read -r matching canonical <<<"${counts}"
  [[ ${matching} == 1 && ${canonical} == 1 ]] && return 0
  temp=$(mktemp "/tmp/tau-swap-fstab.XXXXXX")
  if ! awk -v path="${path}" '
    $1 == path && $3 == "swap" { if (!written++) print path " none swap sw 0 0"; next }
    { print }
    END { if (!written) print path " none swap sw 0 0" }
  ' "${fstab}" >"${temp}" 2>/dev/null; then
    rm -f "${temp}"
    return 1
  fi
  if ! install_fstab_atomically "${temp}" "${fstab}"; then
    rm -f "${temp}"
    return 1
  fi
  rm -f "${temp}"
}

cleanup_swap_temp() { # PATH
  as_root rm -f -- "$1"
}

cleanup_swap_temp_on_return() { # PATH
  trap - RETURN
  cleanup_swap_temp "$1"
}

ensure_swapfile() { # [SIZE=4G] [PATH=/swapfile]
  local size=${1:-4G} path=${2:-/swapfile}
  local parent bytes mib available temp
  parent=$(dirname "${path}")
  [[ -d ${parent} ]] || die "swapfile parent directory does not exist: ${parent}"
  bytes=$(numfmt --from=iec "${size}" 2>/dev/null) || die "invalid swapfile size: ${size}"
  [[ ${bytes} =~ ^[0-9]+$ && ${bytes} -gt 0 ]] || die "invalid swapfile size: ${size}"
  mib=$(((bytes + 1048575) / 1048576))

  if swap_path_is_active "${path}"; then
    as_root chmod 0600 "${path}"
    ensure_swap_fstab_entry "${path}"
    log_info "managed swap ${path} is active"
    return 0
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | awk 'NF { found=1 } END { exit !found }'; then
    log_info "another swap device is active — leaving it alone"
    return 0
  fi
  if [[ -e ${path} && ! -f ${path} ]]; then
    die "refusing to replace non-regular swap target: ${path}"
  fi
  if [[ -f ${path} ]]; then
    as_root chmod 0600 "${path}"
    as_root swapon "${path}" || die "existing managed swapfile cannot be activated: ${path}"
    swap_path_is_active "${path}" || die "swapfile activation was not reported active: ${path}"
    ensure_swap_fstab_entry "${path}"
    return 0
  fi

  available=$(df -B1 --output=avail "${parent}" | awk 'NR == 2 { print $1 }')
  [[ ${available} =~ ^[0-9]+$ ]] || die "could not determine free space for swapfile at ${parent}"
  ((available >= bytes)) || die "insufficient free space for ${size} swapfile at ${path}"
  temp="${path}.tau-new.$$"
  cleanup_swap_temp "${temp}"
  trap 'cleanup_swap_temp_on_return "${temp}"' RETURN
  log_info "creating ${size} swapfile at ${path}"
  as_root fallocate -l "${bytes}" "${temp}" 2>/dev/null ||
    as_root dd if=/dev/zero of="${temp}" bs=1M count="${mib}" status=none || return 1
  as_root chmod 0600 "${temp}" || return 1
  as_root mkswap "${temp}" >/dev/null || return 1
  as_root mv "${temp}" "${path}" || return 1
  as_root swapon "${path}"
  swap_path_is_active "${path}" || die "swapfile activation was not reported active: ${path}"
  ensure_swap_fstab_entry "${path}"
  trap - RETURN
}

# ------------------------------------------------------------------ backup

# Convert a `backup.schedule` HH:MM (24h, UTC) config value into a systemd
# OnCalendar= expression (daily at that time). Dies on anything else — a bad
# schedule should fail setup, not silently install a timer that never fires
# (or fires constantly).
backup_oncalendar_from_schedule() { # HH:MM
  local sched=$1
  [[ ${sched} =~ ^([0-1][0-9]|2[0-3]):([0-5][0-9])$ ]] ||
    die "config: backup.schedule must be HH:MM in 24h UTC (got '${sched}')"
  printf '*-*-* %s:00' "${sched}"
}

# Single-quote VALUE for safe inclusion in a POSIX-sh-sourced file, escaping
# embedded single quotes as '\'' (close quote, escaped literal quote, reopen
# quote). Result round-trips byte-for-byte through `source`/`.` regardless of
# spaces, $(...), backticks, or other shell metacharacters in VALUE.
sh_single_quote() { # VALUE
  local v=$1
  v=${v//\'/\'\\\'\'}
  printf "'%s'" "${v}"
}

# Render the contents of the 0600 root-owned /etc/tau/backup.env file the
# rendered tau-backup.sh reads its S3 credentials + encryption passphrase
# from. MODE redact is for --dry-run plan output — same shape as
# build_env_content's redact mode in setup-host.sh, kept as a pure lib.sh
# helper (explicit args, no globals) so it is directly unit-testable.
#
# Values are single-quoted (sh_single_quote): tau-backup.sh.tmpl `source`s
# this file, so a bare/unquoted assignment would let a passphrase containing
# spaces, $(...), or backticks corrupt parsing or execute as root.
render_backup_env_content() { # MODE(real|redact) ACCESS_KEY SECRET_KEY PASSPHRASE
  local mode=$1 access=$2 secret=$3 passphrase=$4
  if [[ ${mode} == redact ]]; then
    # A dry-run placeholder like <supplied-at-run-time> is not a secret —
    # show it verbatim instead of redacting it (mirrors setup-host.sh's
    # redact_unless_placeholder for the other secret fields).
    [[ ${access} == '<'*'>' ]] || access=$(redact_secret "${access}")
    [[ ${secret} == '<'*'>' ]] || secret=$(redact_secret "${secret}")
    [[ ${passphrase} == '<'*'>' ]] || passphrase=$(redact_secret "${passphrase}")
  fi
  cat <<EOF
# Generated by scripts/setup/setup-host.sh — backup S3 credentials +
# encryption passphrase. 0600 root-owned; read by tau-backup.sh. Never log or
# print these values in full. Values are single-quoted so this file sources
# safely even if a secret contains spaces, \$(...), or backticks.
FICUS_BACKUP_S3_ACCESS_KEY=$(sh_single_quote "${access}")
FICUS_BACKUP_S3_SECRET_KEY=$(sh_single_quote "${secret}")
FICUS_BACKUP_PASSPHRASE=$(sh_single_quote "${passphrase}")
EOF
}

# Where the nightly backup's two rendered files live. Written by setup-host.sh
# (phase_backup) and rewritten in place by retarget-backup.sh. Env-overridable
# only so tests can point them at a scratch directory (the same idiom as
# CADDY_TLS_DIR/CADDYFILE_PATH); setup-host.sh and upgrade-host.sh never set
# either.
BACKUP_SCRIPT_PATH="${BACKUP_SCRIPT_PATH:-/usr/local/bin/tau-backup.sh}"
BACKUP_ENV_TARGET="${BACKUP_ENV_TARGET:-/etc/tau/backup.env}"

# Render tau-backup.sh.tmpl with its @TOKEN@ substitutions. Explicit args, no
# globals, so setup-host.sh (fresh render from its config) and
# retarget-backup.sh (re-render of a live host, non-S3 values carried over
# from the installed script) share exactly one render. The sed program is the
# one setup-host.sh has always used: values are spliced in verbatim, so a
# value containing '|', '&' or '\' would corrupt the output — callers that
# take values from outside the toolkit validate them first.
render_backup_script_content() { # TEMPLATE DEST HOME_DIR DB_MODE DB_CONTAINER S3_ENDPOINT S3_REGION S3_BUCKET S3_PREFIX BACKUP_ENV_FILE
  sed -e "s|@DEST@|${2}|g" \
    -e "s|@HOME_DIR@|${3}|g" \
    -e "s|@DB_MODE@|${4}|g" \
    -e "s|@DB_CONTAINER@|${5}|g" \
    -e "s|@S3_ENDPOINT@|${6}|g" \
    -e "s|@S3_REGION@|${7}|g" \
    -e "s|@S3_BUCKET@|${8}|g" \
    -e "s|@S3_PREFIX@|${9}|g" \
    -e "s|@BACKUP_ENV_FILE@|${10}|g" \
    "$1"
}

# Read the values a live tau-backup.sh was rendered with — the `NAME='value'`
# lines its template writes near the top — into LIVE_<NAME> for DEST HOME_DIR
# DB_MODE DB_CONTAINER S3_ENDPOINT S3_REGION S3_BUCKET S3_PREFIX
# BACKUP_ENV_FILE, and the script's exact bytes into LIVE_SCRIPT. Re-deriving
# them would need setup-host.sh's whole config, secrets included, so both
# retarget-backup.sh and the env rename carry them over from the installed
# copy. Dies on a script this toolkit did not render (a missing or empty
# required value, or one the render's sed program would corrupt).
backup_script_read_values() { # SCRIPT
  local script=$1 _found=' ' _rest _line _tok _val
  local tokens='DEST HOME_DIR DB_MODE DB_CONTAINER S3_ENDPOINT S3_REGION S3_BUCKET S3_PREFIX BACKUP_ENV_FILE'
  read_file_exact "${script}" LIVE_SCRIPT || die "could not read ${script}"
  _rest=${LIVE_SCRIPT}
  while [[ -n ${_rest} ]]; do
    _line=${_rest%%$'\n'*}
    if [[ ${_line} == "${_rest}" ]]; then _rest=''; else _rest=${_rest#*$'\n'}; fi
    if [[ ${_line} =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] && [[ " ${tokens} " == *" ${BASH_REMATCH[1]} "* ]] &&
      [[ ${_found} != *" ${BASH_REMATCH[1]} "* ]]; then
      printf -v "LIVE_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
      _found+="${BASH_REMATCH[1]} "
    fi
  done
  for _tok in ${tokens}; do
    [[ ${_found} == *" ${_tok} "* ]] ||
      die "${script} has no ${_tok}='…' line — it was not rendered from a tau-backup.sh.tmpl this script understands; re-run setup-host.sh's phase_backup instead"
  done
  for _tok in DEST HOME_DIR DB_MODE S3_PREFIX BACKUP_ENV_FILE; do
    _val="LIVE_${_tok}"
    [[ -n ${!_val} ]] || die "${script} has an empty ${_tok} — refusing to re-render it"
  done
  # Carried-over values go through the same sed program; refuse any it would
  # corrupt (the original render could not have produced one, so this means
  # the file was edited by hand).
  for _tok in DEST HOME_DIR DB_MODE DB_CONTAINER S3_PREFIX BACKUP_ENV_FILE; do
    _val="LIVE_${_tok}"
    [[ ${!_val} != *[\|\&\\]* ]] || die "${script}'s ${_tok} contains '|', '&' or '\\' — refusing to re-render it"
  done
}

# Re-render the INSTALLED tau-backup.sh (BACKUP_SCRIPT_PATH) from TEMPLATE with
# the values it already carries, and install it in place with the same mode
# and owner (staged next to it, one rename). The env rename uses this when it
# renames backup.env: an installed copy that predates the rename reads the
# TAU_ backup names, the template reads FICUS_BACKUP_* and
# FICUS_TERMINATION_BACKUP_EFFECT_ID. A no-op when nothing would change.
backup_script_rerender() { # TEMPLATE
  local template=$1 target new staged
  [[ -f ${template} ]] ||
    die "${template} not found — push tau-backup.sh.tmpl with the toolkit; ${BACKUP_SCRIPT_PATH} must be re-rendered alongside the backup.env rename"
  _epr_resolve "${BACKUP_SCRIPT_PATH}" target || die "${BACKUP_SCRIPT_PATH} not found — nothing to re-render"
  backup_script_read_values "${target}"
  # retarget-backup.sh replaces these three with validated values; here they
  # are carried over, so they get the same sed-safety check as the rest.
  local _tok _val
  for _tok in S3_ENDPOINT S3_REGION S3_BUCKET; do
    _val="LIVE_${_tok}"
    [[ ${!_val} != *[\|\&\\]* ]] || die "${target}'s ${_tok} contains '|', '&' or '\\' — refusing to re-render it"
  done
  if ! new=$(render_backup_script_content "${template}" \
    "${LIVE_DEST}" "${LIVE_HOME_DIR}" "${LIVE_DB_MODE}" "${LIVE_DB_CONTAINER}" \
    "${LIVE_S3_ENDPOINT}" "${LIVE_S3_REGION}" "${LIVE_S3_BUCKET}" "${LIVE_S3_PREFIX}" "${LIVE_BACKUP_ENV_FILE}" && printf x) ||
    [[ ${new} != *x ]]; then
    die "failed to render ${template}"
  fi
  new=${new%x}
  [[ -n ${new} ]] || die "rendering ${template} produced nothing"
  [[ ! ${new} =~ @[A-Z_]+@ ]] || die "rendering ${template} left an unsubstituted @PLACEHOLDER@ — refusing to install it"
  if [[ ${new} == "${LIVE_SCRIPT}" ]]; then
    return 0
  fi
  stage_file_replacement "${target}" "${new}" staged || die "could not stage the re-rendered ${target} — it was left unchanged"
  if ! mv -f -- "${staged}" "${target}"; then
    rm -f -- "${staged}"
    die "could not install the re-rendered ${target} — it was left unchanged"
  fi
  log_info "re-rendered ${target} from ${template} (its target and paths unchanged)"
}

# Inverse of sh_single_quote, for reading back a file this toolkit (or the
# control plane, which quotes the same way) wrote as sourced `KEY='value'`
# lines — backup.env, a pushed secrets.env. Accepts exactly two shapes and
# evaluates nothing:
#   - a bare word of shell-inert characters (e.g. an access key id);
#   - a sequence of '...' segments and \' escapes, and nothing else (what
#     sh_single_quote produces).
# Anything else — double quotes, $, backticks, spaces outside quotes, an
# unterminated quote — returns 1 instead of guessing what a shell would make
# of it. Sets the variable named VAR; leaves it untouched on failure.
sh_single_unquote() { # VALUE VAR
  local _ssu_in=$1 _ssu_var=$2 _ssu_out='' _ssu_bare='^[A-Za-z0-9_./:@%+,=-]*$'
  if [[ ${_ssu_in} =~ ${_ssu_bare} ]]; then
    printf -v "${_ssu_var}" '%s' "${_ssu_in}"
    return 0
  fi
  while [[ -n ${_ssu_in} ]]; do
    if [[ ${_ssu_in} == "'"* ]]; then
      _ssu_in=${_ssu_in#"'"}
      [[ ${_ssu_in} == *"'"* ]] || return 1
      _ssu_out+=${_ssu_in%%"'"*}
      _ssu_in=${_ssu_in#*"'"}
    elif [[ ${_ssu_in} == "\\'"* ]]; then
      _ssu_out+="'"
      _ssu_in=${_ssu_in#"\\'"}
    else
      return 1
    fi
  done
  printf -v "${_ssu_var}" '%s' "${_ssu_out}"
}

# Strictly parse RAW, the contents of a sourced-style env file, WITHOUT
# sourcing it. Every line must be blank, a `#` comment, or KEY=VALUE where KEY
# is one of the listed keys and VALUE decodes with sh_single_unquote. Each
# KEY:VAR pair sets VAR to KEY's decoded value (last assignment wins, as when
# sourced); VAR is set to '' first, so a key that is absent reads as empty.
# Returns 1 after a log_error naming LABEL and the line number — never the
# line's key or value, since these files hold secrets.
# Lines are split with parameter expansion, not `read <<<`, so the content
# never passes through a here-string temp file.
sh_env_parse() { # RAW LABEL KEY:VAR...
  local _sep_rest=$1 _sep_label=$2 _sep_line _sep_n=0 _sep_key _sep_val _sep_dec _sep_pair _sep_hit
  shift 2
  for _sep_pair in "$@"; do
    printf -v "${_sep_pair#*:}" '%s' ''
  done
  while [[ -n ${_sep_rest} ]]; do
    _sep_line=${_sep_rest%%$'\n'*}
    if [[ ${_sep_line} == "${_sep_rest}" ]]; then _sep_rest=''; else _sep_rest=${_sep_rest#*$'\n'}; fi
    _sep_n=$((_sep_n + 1))
    [[ ${_sep_line} =~ ^[[:space:]]*$ || ${_sep_line} =~ ^[[:space:]]*# ]] && continue
    if [[ ! ${_sep_line} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      log_error "${_sep_label} line ${_sep_n} is not a KEY=VALUE assignment"
      return 1
    fi
    _sep_key=${BASH_REMATCH[1]}
    _sep_val=${BASH_REMATCH[2]}
    _sep_hit=''
    for _sep_pair in "$@"; do
      [[ ${_sep_pair%%:*} == "${_sep_key}" ]] && _sep_hit=${_sep_pair#*:}
    done
    if [[ -z ${_sep_hit} ]]; then
      # The line number only, never the key text: in a file whose quoting is
      # off (a passphrase spanning lines), the "key" may be secret bytes.
      log_error "${_sep_label} line ${_sep_n}: unexpected key (expected only: ${*%%:*})"
      return 1
    fi
    if ! sh_single_unquote "${_sep_val}" _sep_dec; then
      log_error "${_sep_label} line ${_sep_n}: the value of ${_sep_key} is not a bare word or a single-quoted string (value not shown)"
      return 1
    fi
    printf -v "${_sep_hit}" '%s' "${_sep_dec}"
  done
}

# curl config-file credentials, never argv (ps-visible) — the same user line
# tau-backup.sh.tmpl builds for its own requests (that script is standalone
# and keeps its own copy). Escapes \ and " for the curl config quoted string.
_s3_curl_user_config() { # ACCESS SECRET
  local a=${1//\\/\\\\} s=${2//\\/\\\\}
  a=${a//\"/\\\"}
  s=${s//\"/\\\"}
  printf 'user = "%s:%s"\n' "${a}" "${s}"
}

# Read-only credential + reachability check for a backup target: ONE signed
# ListObjectsV2 (max-keys=1) under PREFIX — the same request shape, auth
# (curl --aws-sigv4) and URL form tau-backup.sh's retention step uses, so a
# pass means the nightly job can authenticate to and list this bucket with
# this key. Writes nothing. Credentials travel in a curl --config file over a
# process-substitution fd (never argv, never disk). Returns 1 after a
# log_error naming the endpoint, bucket, prefix and curl exit / HTTP status —
# never a credential.
s3_list_probe() { # ENDPOINT REGION BUCKET PREFIX ACCESS SECRET
  local endpoint=$1 region=$2 bucket=$3 prefix=$4 access=$5 secret=$6 key_prefix code rc=0
  key_prefix="${prefix:+${prefix%/}/}"
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
    --aws-sigv4 "aws:amz:${region}:s3" \
    --config <(_s3_curl_user_config "${access}" "${secret}") \
    "${endpoint%/}/${bucket}?list-type=2&max-keys=1&prefix=${key_prefix}") || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log_error "could not reach ${endpoint} to list s3://${bucket}/${key_prefix} (curl exit ${rc})"
    return 1
  fi
  if [[ ${code} != 200 ]]; then
    log_error "listing s3://${bucket}/${key_prefix} at ${endpoint} returned HTTP ${code:-<none>} (403: the key is wrong or not granted this bucket; 404: no such bucket)"
    return 1
  fi
}

# ------------------------------------------------------------------ tau API

# Callers set FICUS_API_BASE (e.g. http://127.0.0.1:3000) and FICUS_BEARER.
API_STATUS=''
API_BODY=''

# Secrets must never enter curl's argv (argv is world-readable via ps /
# /proc/<pid>/cmdline): the bearer travels in a curl --config file delivered
# over a process-substitution fd (never touches disk, nothing to clean up),
# and the request body arrives on stdin via --data-binary @-.
_api_curl_auth_config() {
  # curl config quoted strings honor \\ and \" escapes — escape exactly those.
  local b=${FICUS_BEARER//\\/\\\\}
  printf 'header = "Authorization: Bearer %s"\n' "${b//\"/\\\"}"
}

api_request() { # METHOD PATH [JSON_BODY]
  local method=$1 path=$2 body=${3:-}
  local tmp rc=0
  tmp=$(mktemp)
  local args=(-sS -o "${tmp}" -w '%{http_code}' -X "${method}")
  if [[ -n ${body} ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
    API_STATUS=$(printf '%s' "${body}" |
      curl --config <(_api_curl_auth_config) "${args[@]}" "${FICUS_API_BASE}${path}") || rc=$?
  else
    API_STATUS=$(curl --config <(_api_curl_auth_config) "${args[@]}" "${FICUS_API_BASE}${path}" </dev/null) || rc=$?
  fi
  if [[ ${rc} -eq 0 ]]; then
    API_BODY=$(cat "${tmp}")
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  API_STATUS=000
  API_BODY=''
  return 1
}

api_expect() { # METHOD PATH JSON_BODY EXPECTED_STATUS_REGEX DESCRIPTION
  local method=$1 path=$2 body=$3 expect=$4 desc=$5
  api_request "${method}" "${path}" "${body}" || die "${desc}: request to ${path} failed (network)"
  [[ ${API_STATUS} =~ ^(${expect})$ ]] ||
    die "${desc}: ${method} ${path} returned HTTP ${API_STATUS}: ${API_BODY}"
}

# GET /health → 200 or 401 both mean the API is up (401 = up + auth-gated
# behind a proxy). /health is the core's real public liveness route —
# apps/core/src/index.ts has no /api/health.
api_is_up() { # BASE_URL
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$1/health" 2>/dev/null) || return 1
  [[ ${code} == 200 || ${code} == 401 ]]
}

# ------------------------------------------------------------------ bearer HTTP (VM/DNS providers)

# Generic bearer-auth JSON HTTP, for provision.sh's VM/DNS provider APIs
# (Hetzner, Cloudflare). Unlike api_request (one fixed FICUS_API_BASE/FICUS_BEARER
# pair) this takes BASE and TOKEN per call, since a single provision.sh run
# talks to two providers with two different tokens. Same secrets doctrine as
# api_request: the token travels via curl --config on a process-substitution
# fd, the body via stdin — never argv. The transport command itself is
# ${FICUS_SETUP_HTTP_CMD:-curl} (TAU_SETUP_HTTP_CMD until phase 5) so tests
# can substitute a record-and-assert fake
# without a real network (or shadowing the real `curl`, which api_request's
# tests already use for their own purposes).
HTTP_STATUS=''
HTTP_BODY=''

_http_bearer_curl_config() { # TOKEN
  local t=${1//\\/\\\\}
  printf 'header = "Authorization: Bearer %s"\n' "${t//\"/\\\"}"
}

http_bearer_request() { # BASE TOKEN METHOD PATH [JSON_BODY]
  local base=$1 token=$2 method=$3 path=$4 body=${5:-}
  local cmd=${FICUS_SETUP_HTTP_CMD:-${TAU_SETUP_HTTP_CMD:-curl}}
  local tmp rc=0
  tmp=$(mktemp)
  local args=(-sS -o "${tmp}" -w '%{http_code}' -X "${method}")
  if [[ -n ${body} ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
    HTTP_STATUS=$(printf '%s' "${body}" |
      "${cmd}" --config <(_http_bearer_curl_config "${token}") "${args[@]}" "${base}${path}") || rc=$?
  else
    HTTP_STATUS=$("${cmd}" --config <(_http_bearer_curl_config "${token}") "${args[@]}" "${base}${path}" </dev/null) || rc=$?
  fi
  if [[ ${rc} -eq 0 ]]; then
    HTTP_BODY=$(cat "${tmp}")
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  HTTP_STATUS=000
  HTTP_BODY=''
  return 1
}

http_bearer_expect() { # BASE TOKEN METHOD PATH JSON_BODY EXPECTED_STATUS_REGEX DESCRIPTION
  local base=$1 token=$2 method=$3 path=$4 body=$5 expect=$6 desc=$7
  http_bearer_request "${base}" "${token}" "${method}" "${path}" "${body}" ||
    die "${desc}: request to ${path} failed (network)"
  [[ ${HTTP_STATUS} =~ ^(${expect})$ ]] ||
    die "${desc}: ${method} ${path} returned HTTP ${HTTP_STATUS}: ${HTTP_BODY}"
}

# ------------------------------------------------------------------ hetzner (hcloud)

# Request body for POST /servers.
hcloud_server_create_body() { # NAME SERVER_TYPE LOCATION IMAGE SSH_KEY_NAME
  jq -n --arg name "$1" --arg st "$2" --arg loc "$3" --arg img "$4" --arg key "$5" \
    '{name: $name, server_type: $st, location: $loc, image: $img, ssh_keys: [$key]}'
}

# "STATUS ID IP" from a raw hcloud Server resource object (the shape shared by
# create/get responses' `.server` and each element of a list response's
# `.servers`). IP is '' when not yet allocated.
_hcloud_server_status_id_ip() { # SERVER_OBJECT_JSON
  jq -r '.status + " " + (.id | tostring) + " " + (.public_net.ipv4.ip // "")' <<<"$1"
}

# GET /servers?name=<name> response → "STATUS ID IP" of the first match, or
# empty ('') if no server with that name exists — the idempotent-reuse branch
# selection provision_vm_hetzner() uses to decide reuse vs. create.
hcloud_server_lookup() { # LIST_RESPONSE_JSON
  local first
  first=$(jq -c '.servers[0] // empty' <<<"$1")
  [[ -n ${first} ]] && _hcloud_server_status_id_ip "${first}"
}

# POST /servers or GET /servers/<id> response (top-level `.server`) → "STATUS
# ID IP".
hcloud_server_status_id_ip() { # SERVER_RESPONSE_JSON
  _hcloud_server_status_id_ip "$(jq -c '.server' <<<"$1")"
}

# ------------------------------------------------------------------ digitalocean (droplets)

# Request body for POST /droplets. TAG is set at create (e.g. 'tau-tenant')
# so idempotent reuse/destroy can filter by tag+exact-name — DO's list
# endpoint can't combine a `name` and `tag_name` query in one call (see
# do_droplet_lookup below), so the tag is what keeps an unrelated,
# same-named droplet from ever being mistaken for one of ours.
#
# VPC_UUID is optional and is omitted from the payload when empty — DO then
# places the droplet in whatever the region's DEFAULT VPC currently is. Pass
# it whenever the droplet has to reach anything else over a private network
# (e.g. a managed database's private host): "the default VPC" is a console
# setting that can be changed later, silently, for every droplet created
# after that point.
do_droplet_create_body() { # NAME REGION SIZE IMAGE SSH_KEY_ID TAG [VPC_UUID]
  jq -n --arg name "$1" --arg region "$2" --arg size "$3" --arg img "$4" --arg key "$5" --arg tag "$6" \
    --arg vpc "${7:-}" \
    '{name: $name, region: $region, size: $size, image: $img, ssh_keys: [$key], tags: [$tag]}
     + (if $vpc == "" then {} else {vpc_uuid: $vpc} end)'
}

# Body for POST /projects/<project_id>/resources. Droplet-create has NO
# project_id field, so project membership is a SEPARATE call made once the
# droplet exists, addressing it by URN. Re-assigning a resource that is
# already in the project is a no-op on DO's side, so this is safe to repeat
# on every (idempotent) provision run.
do_project_assign_body() { # DROPLET_ID
  jq -n --arg urn "do:droplet:$1" '{resources: [$urn]}'
}

# "STATUS ID IP" from a raw DO Droplet resource object (the shape shared by
# create/get responses' `.droplet` and each element of a list response's
# `.droplets`). IP is the first `networks.v4[]` entry with `type=="public"`
# — DO droplets always carry BOTH a public and (on most plans) a private
# v4 entry, so picking the wrong one is the easy mistake here. '' when no
# public entry has been allocated yet.
_do_droplet_status_id_ip() { # DROPLET_OBJECT_JSON
  jq -r '.status + " " + (.id | tostring) + " " +
    (((.networks.v4 // []) | map(select(.type == "public")) | .[0].ip_address) // "")' <<<"$1"
}

# GET /droplets?tag_name=<tag> response, filtered client-side to the exact
# NAME (DO's list endpoint rejects combining `tag_name` with `name` in one
# query) → "STATUS ID IP" of the match, or empty ('') if none — the
# idempotent-reuse branch selection provision_vm_digitalocean() uses to
# decide reuse vs. create.
do_droplet_lookup() { # LIST_RESPONSE_JSON NAME
  local list=$1 name=$2 first
  first=$(jq -c --arg name "${name}" '(.droplets // []) | map(select(.name == $name)) | .[0] // empty' <<<"${list}")
  [[ -n ${first} ]] && _do_droplet_status_id_ip "${first}"
}

# POST /droplets or GET /droplets/<id> response (top-level `.droplet`) →
# "STATUS ID IP".
do_droplet_status_id_ip() { # DROPLET_RESPONSE_JSON
  _do_droplet_status_id_ip "$(jq -c '.droplet' <<<"$1")"
}

# True (rc 0) when STATUS/BODY look like a DO capacity/availability failure
# (size or region temporarily out of stock) rather than something a retry
# with a DIFFERENT size/region can't fix (bad auth, invalid image, account
# droplet-limit, ...). Matched defensively — status in {422,503} AND a
# message containing a capacity-ish keyword — rather than on an exact
# string, since DO's wording isn't a documented, stable contract. Used by
# provision_vm_digitalocean()'s ordered-fallback loop to decide "try the
# next size/region" vs. "die now, don't burn through fallbacks on an auth
# problem".
# True iff DO refused the create because the ACCOUNT's droplet limit is
# reached (HTTP 422, "You have reached your droplet limit…"). Not a size
# stockout: no fallback and no retry fixes it, only a limit increase from the
# console, so provision.sh exits PROVISION_EXIT_PERMANENT on it. Mirrors the
# platform's do-resources.ts isAccountDropletLimitError for the machine-host
# path.
do_is_account_limit_error() { # HTTP_STATUS HTTP_BODY
  local status=$1 body=$2 msg
  [[ ${status} == 422 ]] || return 1
  msg=$(jq -r '.message // empty' <<<"${body}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [[ ${msg} == *'droplet limit'* ]]
}

do_is_capacity_error() { # HTTP_STATUS HTTP_BODY
  local status=$1 body=$2 msg
  case "${status}" in
    422 | 503) ;;
    *) return 1 ;;
  esac
  msg=$(jq -r '.message // empty' <<<"${body}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "${msg}" in
    *unavailable* | *'not available'* | *'no longer available'* | *capacity* | *insufficient*) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------ cloudflare DNS

# GET /zones?name=<zone> response → the zone id, or '' if not found.
cf_zone_id_from_list() { # ZONES_LIST_JSON
  jq -r '.result[0].id // empty' <<<"$1"
}

# GET /zones/<zid>/dns_records?type=A&name=<fqdn> response → the existing
# record's id, or '' if none exists yet — the idempotent-upsert branch
# selection (empty → POST a new record, else PUT to this id).
cf_dns_record_id_from_list() { # RECORDS_LIST_JSON
  jq -r '.result[0].id // empty' <<<"$1"
}

# Request body for creating/updating an A record pointing NAME at the
# provisioned server's IP.
#
# proxied:true is REQUIRED, not a preference: the origin presents a Cloudflare
# Origin CA certificate (see the origin TLS block above), which is trusted by
# Cloudflare's proxy and by no browser on earth. A grey-cloud (unproxied)
# record would hand that certificate straight to real browsers, which reject
# it — and would publish the origin IP, defeating the firewall rule that only
# admits Cloudflare's ranges. Origin certs and orange-cloud records are one
# decision, not two.
cf_dns_record_body() { # NAME CONTENT
  jq -n --arg name "$1" --arg content "$2" \
    '{type: "A", name: $name, content: $content, proxied: true}'
}

# ------------------------------------------------------------------ ssh helpers

# SSH options for key-pinned, agent-free connections (deploy keys, exe account
# keys). IdentityAgent=none + IdentitiesOnly=yes make the -i key authoritative.
# Sets the global SSH_KEY_OPTS array (no namerefs — macOS ships bash 3.2).
# shellcheck disable=SC2034 # consumed by the sourcing scripts, not this file
SSH_KEY_OPTS=()
ssh_key_opts() { # KEY_PATH
  # shellcheck disable=SC2034 # consumed by the sourcing scripts, not this file
  SSH_KEY_OPTS=(-i "$1" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new)
}

# ------------------------------------------------------------------ git source
#
# Shared by setup-host.sh (tenant) and setup-platform.sh (control plane) —
# both clone the SAME repo the SAME way, and a duplicated token-handling
# routine is exactly the kind of thing that drifts apart. Driven by the
# caller's already-validated globals rather than arguments, matching how these
# two scripts hold their config throughout:
#
#   SRC_MODE (git-ssh|git-https)  SRC_REPO  SRC_REF  SRC_DEST  SRC_DEPLOY_KEY
#
# `artifact` mode is NOT handled here — it is a tenant-only seam and stays in
# setup-host.sh.

GIT_ASKPASS_HELPER=''
cleanup_git_askpass() {
  if [[ -n ${GIT_ASKPASS_HELPER} ]]; then rm -f "${GIT_ASKPASS_HELPER}"; fi
}

# shellcheck disable=SC2153 # SRC_* are the caller's config globals, by design
git_env_setup() {
  GIT_AUTH_URL=''
  GIT_CLEAN_URL=${SRC_REPO}
  case "${SRC_MODE}" in
    git-ssh)
      export GIT_SSH_COMMAND="ssh -i ${SRC_DEPLOY_KEY} -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new"
      ;;
    git-https)
      local token=${GH_TOKEN:-}
      # A token is optional: Core is a public repository (2026-09-16), so an
      # unattended run with no $GH_TOKEN clones anonymously instead of dying.
      # Interactive runs still get one chance to supply a token for a private
      # fork; leaving it blank means anonymous too.
      if [[ -z ${token} ]] && is_tty; then
        prompt_value "GitHub token for git-https clone (blank = anonymous, public repository)" token silent
      fi
      local bare=${SRC_REPO}
      bare=${bare#https://}
      # Accept ssh-style URLs in https mode: git@github.com:org/repo.git
      if [[ ${bare} == git@* ]]; then
        bare=${bare#git@}
        bare=${bare/:/\/}
      fi
      if [[ -z ${token} ]]; then
        log_info "git-https: no \$GH_TOKEN — cloning https://${bare} anonymously (public repository)"
        GIT_AUTH_URL="https://${bare}"
        GIT_CLEAN_URL="https://${bare}"
        export GIT_TERMINAL_PROMPT=0
        return 0
      fi
      # The token must never appear in git's argv (ps-visible) or in the URL.
      # Only the non-secret username rides in the URL; git obtains the
      # password at auth time from a GIT_ASKPASS helper that reads it from
      # this process's environment (the helper file itself holds no secret).
      GIT_AUTH_URL="https://x-access-token@${bare}"
      GIT_CLEAN_URL="https://${bare}"
      GIT_ASKPASS_HELPER=$(mktemp)
      cat >"${GIT_ASKPASS_HELPER}" <<'EOF'
#!/bin/sh
# tau-setup GIT_ASKPASS helper — answers git credential prompts from the env.
printf '%s\n' "${FICUS_SETUP_GIT_TOKEN:-${TAU_SETUP_GIT_TOKEN:-}}"
EOF
      chmod 700 "${GIT_ASKPASS_HELPER}"
      # An entrypoint that installed the toolkit EXIT trap
      # (env_prefix_install_traps) already removes the helper there; replacing
      # that trap here would also drop the env restore it runs.
      if [[ ${TOOLKIT_EXIT_TRAP_INSTALLED:-0} -ne 1 ]]; then
        trap cleanup_git_askpass EXIT
      fi
      export FICUS_SETUP_GIT_TOKEN="${token}"
      export GIT_ASKPASS="${GIT_ASKPASS_HELPER}"
      export GIT_TERMINAL_PROMPT=0
      ;;
  esac
}

# shellcheck disable=SC2153 # SRC_* are the caller's config globals, by design
git_source_sync() {
  git_env_setup

  if [[ ! -d ${SRC_DEST} ]]; then
    as_root mkdir -p "${SRC_DEST}"
    as_root chown "$(id -u):$(id -g)" "${SRC_DEST}"
  fi

  # A pre-existing NON-git, non-empty dest means someone pointed source.dest at
  # an occupied path (classic: /opt/tau, which the ficus-machine image owns). Fail
  # with a clear instruction instead of git's opaque "destination path already
  # exists and is not an empty directory" fatal.
  if [[ ! -d ${SRC_DEST}/.git ]] && [[ -n $(ls -A "${SRC_DEST}" 2>/dev/null) ]]; then
    die "source.dest '${SRC_DEST}' already exists, is non-empty, and is not a git checkout — pick an unused path (the ficus-machine image owns /opt/tau; use e.g. /opt/tau-core)"
  fi

  if [[ -d ${SRC_DEST}/.git ]]; then
    log_info "existing checkout found — fetching ${SRC_REF} (idempotent re-run)"
    local current_url
    current_url=$(git -C "${SRC_DEST}" remote get-url origin 2>/dev/null || true)
    [[ ${current_url} == "${GIT_CLEAN_URL}" || ${current_url} == "${SRC_REPO}" ]] ||
      log_warn "origin URL is '${current_url}', config says '${SRC_REPO}' — fetching from the configured repo anyway"
    # --force on tags is REQUIRED, not defensive: .github/workflows/
    # cli-binaries.yml force-moves the `nightly` tag on every main build
    # (`git tag -f nightly` + `git push --force`). Without --force git refuses
    # the whole fetch with "would clobber existing tag", so the SECOND run of
    # this script on any host fails — the first clone succeeds because it has
    # no local tags yet. Observed on the control plane's first re-run.
    if [[ ${SRC_MODE} == git-https ]]; then
      git -C "${SRC_DEST}" fetch --tags --force "${GIT_AUTH_URL}" '+refs/heads/*:refs/remotes/origin/*'
    else
      git -C "${SRC_DEST}" fetch --tags --force origin
    fi
    # Before the checkout moves: a caller may need to look at the target
    # revision first (upgrade-host.sh reads its package.json to refuse a
    # pre-rename target on a renamed host). It is handed the revision the
    # checkout below resolves to; a failure there dies with nothing moved.
    if [[ -n ${GIT_PRE_CHECKOUT_HOOK:-} ]]; then
      if git -C "${SRC_DEST}" show-ref --verify --quiet "refs/remotes/origin/${SRC_REF}"; then
        "${GIT_PRE_CHECKOUT_HOOK}" "origin/${SRC_REF}"
      else
        "${GIT_PRE_CHECKOUT_HOOK}" "${SRC_REF}"
      fi
    fi
    # --force (-f) is deliberate: a re-run/upgrade must be authoritative over the
    # checkout. The build writes tracked files in place (bun.lock is re-resolved
    # by `bun install`, tsconfig.tsbuildinfo by tsc), so a plain checkout aborts
    # with "Your local changes to bun.lock would be overwritten". We WANT the
    # target ref's versions; -f discards those local tracked edits. Untracked and
    # gitignored paths (node_modules, dist, the rendered .env) are not touched.
    if git -C "${SRC_DEST}" show-ref --verify --quiet "refs/remotes/origin/${SRC_REF}"; then
      git -C "${SRC_DEST}" checkout -f -B "${SRC_REF}" "origin/${SRC_REF}"
    else
      git -C "${SRC_DEST}" checkout -f --detach "${SRC_REF}"
    fi
  else
    if [[ ${SRC_REF} =~ ^[0-9a-f]{7,40}$ ]]; then
      # A sha can't be cloned with --branch; clone default branch then detach.
      git clone "${GIT_AUTH_URL:-${SRC_REPO}}" "${SRC_DEST}"
      git -C "${SRC_DEST}" checkout --detach "${SRC_REF}"
    else
      git clone --branch "${SRC_REF}" "${GIT_AUTH_URL:-${SRC_REPO}}" "${SRC_DEST}"
    fi
    if [[ -n ${GIT_AUTH_URL} ]]; then
      # Never leave the token on disk in .git/config.
      git -C "${SRC_DEST}" remote set-url origin "${GIT_CLEAN_URL}"
    fi
  fi
  git -C "${SRC_DEST}" submodule update --init --recursive
  log_info "source ready at ${SRC_DEST} ($(git -C "${SRC_DEST}" rev-parse --short HEAD))"
}

# ------------------------------------------------------- app build / run cycle
#
# THE most expensive lesson this toolkit encodes, and the reason these three
# functions live in lib.sh rather than inline in setup-host.sh:
#
#   tau-api runs `bun run dist/index.js`. A checkout that has been fetched and
#   moved to a new ref but NOT rebuilt therefore keeps serving the OLD bundle
#   while `git log` on the box shows the new commit. Every symptom points at
#   "the deploy didn't land" and every check an operator naturally reaches for
#   (git status, the ref, the file times of src/) says it did. A full day was
#   lost to exactly that.
#
# The countermeasure is structural, not procedural: there is ONE definition of
# "bring this checkout into service" and every caller — the fresh-provision
# path (setup-host.sh's phase_build/phase_migrate/phase_services) and the
# fleet upgrade path (upgrade-host.sh) — goes through it. Nobody hand-rolls a
# fetch + restart sequence, so nobody can hand-roll one that forgets the core
# build.

# --------------------------------------------------------- build stamp (skip)
#
# WHY: a provision retry re-runs setup-host.sh against the SAME commit it just
# built — the earlier attempt died in a LATER phase (e.g. machine_host), not
# the build. build_app has no memory of that, so it re-ran `bun install` +
# `bun run build` unconditionally: the single most expensive step in the
# toolkit. Live evidence: a provision retry spent 2m44s of a 4m41s run (58%)
# rebuilding a commit it had already built 2m41s earlier in the failed
# attempt.
#
# The stamp records the two things that can change what `bun install && bun
# run build` produces at pinned dependency versions — the built commit and a
# hash of bun.lock — PLUS a sha256 of every output file that build actually
# produced. A build is skipped only when ALL of: the stamp exists, its commit
# matches current HEAD, its lock hash matches current bun.lock, the outputs
# this call would produce still exist on disk, AND each of those outputs'
# CURRENT bytes hash to what the stamped build produced. That last check is
# load-bearing, not redundant with the existence check: `[[ -f ]]` is true
# for a truncated-to-0-bytes or otherwise corrupted file, so existence alone
# was once enough to skip over — and then ship — a broken bundle. A stamp
# missing a hash field (an older-format stamp, written before this field
# existed) is treated as no stamp at all, never as a free pass.
#
# upgrade-host.sh calls build_app too, and its caller — the platform's fleet
# upgrade job — independently re-verifies the upgrade
# over SSH by reading apps/core/dist/index.js's mtime before and after, and
# REQUIRES it to have strictly INCREASED (that check exists because "deploy
# without rebuild" was a real historical bug, and git logs lie about it — see
# that file's own comment). A skipped build therefore still touches its
# output files' mtimes forward before returning: build_stamp_is_current just
# hashed those exact bytes and confirmed they equal what the stamped build
# produced, so marking them "verified now" is a claim backed by actual proof
# of content — not merely a file existing at that path — and it is what keeps
# that external probe from reading a legitimate no-op as a lie. Migrations
# and the service restart are NOT skipped — only the expensive compile step
# is.
#
# Concurrency: platform-triggered runs (setup-host.sh, upgrade-host.sh) are
# serialized per tenant by the job queue's advisory lock (queue.ts,
# pg_try_advisory_xact_lock keyed on tenant id), so two build_app calls for
# the same checkout never race in that path; a manual out-of-band run racing
# one anyway degrades at worst to a redundant rebuild — a file the racer left
# missing or mid-write just fails the next skip check's hash comparison —
# never to a corrupted skip.

build_stamp_path() { printf '%s/.tau-build-stamp\n' "$1"; } # SRC_DEST

# sha256 of bun.lock. Empty string (never matches a real stamp) when the
# lockfile is missing, rather than dying — a missing lockfile is a build
# failure for `build_app` itself to report, not this helper's job.
build_lock_hash() { # SRC_DEST
  local src_dest=$1
  [[ -f ${src_dest}/bun.lock ]] || {
    printf ''
    return 0
  }
  sha256sum "${src_dest}/bun.lock" | awk '{print $1}'
}

# sha256 of a single build output file, same style as build_lock_hash: empty
# string (never matches a real stamp field) when the file is missing, rather
# than dying. Callers that need "missing" to read as "no proof" (as opposed
# to "an older-format stamp with no field at all") check for a non-empty
# stamped value themselves — see build_stamp_is_current.
build_output_hash() { # FILE
  local file=$1
  [[ -f ${file} ]] || {
    printf ''
    return 0
  }
  sha256sum "${file}" | awk '{print $1}'
}

# The build outputs THIS call's build would produce, mirroring build_app's
# own post-build assertions exactly so the skip check can never be looser
# than the real thing it stands in for. Existence only — see
# build_stamp_is_current for the content (hash) proof layered on top.
build_outputs_present() { # SRC_DEST SERVE_WEB
  local src_dest=$1 serve_web=$2
  [[ -f ${src_dest}/apps/core/dist/index.js && -f ${src_dest}/apps/core/dist/worker.js ]] || return 1
  # `apps/core dist/migrate.js` is the standalone migration bundle. The
  # artifact path runs it directly (artifact_activate's pre-flip migrate), and
  # a git-mode box that skipped its rebuild without it would have no bundle to
  # hand the next artifact upgrade — so it is a build OUTPUT, not a by-product.
  [[ -f ${src_dest}/apps/core/dist/migrate.js ]] || return 1
  # Custom webhook commands and host agents can run this CLI bundle;
  # a deploy that built core but not the CLI left every webhook notification
  # silently no-opping (2026-08-23). The CLI is now a first-class build output.
  [[ -f ${src_dest}/apps/cli/dist/tau.js ]] || return 1
  if [[ ${serve_web} == true ]]; then
    [[ -f ${src_dest}/apps/web/dist/index.html ]] || return 1
  fi
  return 0
}

# True (0) iff the stamp proves the checkout's current build outputs are
# already what a fresh build would produce, i.e. build_app may skip the
# expensive part.
build_stamp_is_current() { # SRC_DEST SERVE_WEB
  local src_dest=$1 serve_web=$2 stamp head stamp_commit stamp_lock stamp_hash
  stamp=$(build_stamp_path "${src_dest}")
  [[ -f ${stamp} ]] || return 1
  head=$(git -C "${src_dest}" rev-parse HEAD 2>/dev/null) || return 1
  stamp_commit=$(envfile_get "${stamp}" FICUS_BUILD_COMMIT) || return 1
  [[ -n ${stamp_commit} && ${stamp_commit} == "${head}" ]] || return 1
  stamp_lock=$(envfile_get "${stamp}" FICUS_BUILD_LOCK_HASH) || return 1
  [[ ${stamp_lock} == "$(build_lock_hash "${src_dest}")" ]] || return 1
  build_outputs_present "${src_dest}" "${serve_web}" || return 1
  # build_outputs_present only proved the paths exist; a truncated or
  # corrupted file passes that check too. Re-verify each expected output's
  # CONTENT against the hash the stamped (successful) build recorded. A
  # missing field — an older-format stamp, or a stamp written for a call that
  # didn't build that output — must NOT read as a match; it must fail closed
  # just like a missing stamp.
  stamp_hash=$(envfile_get "${stamp}" FICUS_BUILD_HASH_CORE_INDEX)
  [[ -n ${stamp_hash} && ${stamp_hash} == "$(build_output_hash "${src_dest}/apps/core/dist/index.js")" ]] || return 1
  stamp_hash=$(envfile_get "${stamp}" FICUS_BUILD_HASH_CORE_WORKER)
  [[ -n ${stamp_hash} && ${stamp_hash} == "$(build_output_hash "${src_dest}/apps/core/dist/worker.js")" ]] || return 1
  stamp_hash=$(envfile_get "${stamp}" FICUS_BUILD_HASH_CORE_MIGRATE)
  [[ -n ${stamp_hash} && ${stamp_hash} == "$(build_output_hash "${src_dest}/apps/core/dist/migrate.js")" ]] || return 1
  stamp_hash=$(envfile_get "${stamp}" FICUS_BUILD_HASH_CLI_TAU)
  [[ -n ${stamp_hash} && ${stamp_hash} == "$(build_output_hash "${src_dest}/apps/cli/dist/tau.js")" ]] || return 1
  if [[ ${serve_web} == true ]]; then
    stamp_hash=$(envfile_get "${stamp}" FICUS_BUILD_HASH_WEB_INDEX)
    [[ -n ${stamp_hash} && ${stamp_hash} == "$(build_output_hash "${src_dest}/apps/web/dist/index.html")" ]] || return 1
  fi
  return 0
}

# Delete the stamp. Called at the START of an actual (non-skipped) build —
# NEVER on the skip path — so a build that dies halfway can never leave a
# valid stamp sitting over stale or half-written outputs.
build_stamp_clear() { # SRC_DEST
  rm -f "$(build_stamp_path "$1")"
}

# Write the stamp. Only ever called after build_app's own output assertions
# have already passed: a stamp is a claim about a build that is KNOWN good.
# Records a sha256 of each output THIS call's build actually produced (core
# always; web only when serve_web) alongside the commit/lock fields, so a
# later skip check can prove content, not just presence.
build_stamp_write() { # SRC_DEST SERVE_WEB
  local src_dest=$1 serve_web=$2 stamp
  stamp=$(build_stamp_path "${src_dest}")
  {
    printf 'FICUS_BUILD_COMMIT=%s\n' "$(git -C "${src_dest}" rev-parse HEAD)"
    printf 'FICUS_BUILD_LOCK_HASH=%s\n' "$(build_lock_hash "${src_dest}")"
    printf 'FICUS_BUILD_HASH_CORE_INDEX=%s\n' "$(build_output_hash "${src_dest}/apps/core/dist/index.js")"
    printf 'FICUS_BUILD_HASH_CORE_WORKER=%s\n' "$(build_output_hash "${src_dest}/apps/core/dist/worker.js")"
    printf 'FICUS_BUILD_HASH_CORE_MIGRATE=%s\n' "$(build_output_hash "${src_dest}/apps/core/dist/migrate.js")"
    printf 'FICUS_BUILD_HASH_CLI_TAU=%s\n' "$(build_output_hash "${src_dest}/apps/cli/dist/tau.js")"
    if [[ ${serve_web} == true ]]; then
      printf 'FICUS_BUILD_HASH_WEB_INDEX=%s\n' "$(build_output_hash "${src_dest}/apps/web/dist/index.html")"
    fi
    printf 'FICUS_BUILD_AT=%s\n' "$(date -u +%FT%TZ)"
  } >"${stamp}"
}

# Install dependencies and build the app from a checkout. ALWAYS builds core;
# builds web too when serve_web is true. Dies (rather than returning non-zero
# quietly) if the core build did not actually produce the two entrypoints the
# systemd units execute.
#
# Sets the global _tau_build_skipped (true|false) so callers — currently only
# upgrade-host.sh's final summary line — can tell whether this call actually
# rebuilt anything.
build_app() { # SRC_DEST SERVE_WEB(true|false)
  local src_dest=$1 serve_web=$2
  cd "${src_dest}" || die "build_app: cannot enter '${src_dest}'"
  _tau_build_skipped=false
  if build_stamp_is_current "${src_dest}" "${serve_web}"; then
    local stamp_commit
    stamp_commit=$(envfile_get "$(build_stamp_path "${src_dest}")" FICUS_BUILD_COMMIT)
    log_info "build current for ${stamp_commit:0:12} (bun.lock unchanged, outputs present) — skipping rebuild"
    # See the big comment above: honestly re-asserting "these outputs are
    # current" for the upgrade path's external mtime probe.
    touch apps/core/dist/index.js apps/core/dist/worker.js apps/core/dist/migrate.js apps/cli/dist/tau.js
    [[ ${serve_web} == true ]] && touch apps/web/dist/index.html
    _tau_build_skipped=true
    return 0
  fi
  # A real build is about to happen — clear any stamp NOW, so a death partway
  # through (core builds, web dies; or the process is killed) can never leave
  # a valid-looking stamp over outputs that don't match it.
  build_stamp_clear "${src_dest}"
  # --ignore-scripts skips the root postinstall (submodules + extensions);
  # bun-pty is externalized from the core build so the runtime does not need
  # it vendored by this install.
  bun install --ignore-scripts
  # The one root postinstall step we still want: agent extension deps.
  bun run extensions:install
  (cd apps/core && bun run build)
  # Not defensive noise: this assertion is what turns "the build silently did
  # nothing" into a failed run instead of a green one serving stale code.
  [[ -f apps/core/dist/index.js && -f apps/core/dist/worker.js ]] ||
    die "build did not produce apps/core/dist/{index,worker}.js"
  # The migration bundle the artifact path (and any bundle-based migrate) runs.
  [[ -f apps/core/dist/migrate.js ]] || die "build did not produce apps/core/dist/migrate.js"
  # The webhook action scripts exec this bundle. Without it, every GitHub
  # webhook notification silently no-ops (2026-08-23 incident) — so a missing
  # CLI bundle is a failed deploy, not a green one.
  (cd apps/cli && bun run build)
  [[ -f apps/cli/dist/tau.js ]] || die "build did not produce apps/cli/dist/tau.js"
  if [[ ${serve_web} == true ]]; then
    bun run build:web
    [[ -f apps/web/dist/index.html ]] || die "web build did not produce apps/web/dist/index.html"
  fi
  build_stamp_write "${src_dest}" "${serve_web}"
  log_info "build complete"
}

# The human-facing line for upgrade-host.sh's post-upgrade summary. Pulled
# out as a pure function so the same-commit/build-skipped wording is
# unit-testable without running an actual upgrade end-to-end.
upgrade_result_message() { # BEFORE_SHA AFTER_SHA BUILD_SKIPPED(true|false)
  local before=$1 after=$2 skipped=$3
  if [[ ${before} != "${after}" ]]; then
    printf 'upgraded %s → %s' "${before:0:12}" "${after:0:12}"
  elif [[ ${skipped} == true ]]; then
    printf 'already at %s, build current — nothing to do (migrations re-checked, services restarted)' "${after:0:12}"
  else
    printf 'already at %s — rebuilt and restarted anyway (idempotent re-run)' "${after:0:12}"
  fi
}

# Apply drizzle migrations from a checkout, with a small retry: a transient
# "starting up"/connection blip shouldn't fail a whole run, and drizzle
# migrations are idempotent (applied-migration tracking), so retrying after a
# partial connection failure is safe.
run_db_migrations() { # SRC_DEST
  local src_dest=$1 attempt
  for attempt in 1 2 3; do
    # Both spellings, per invocation (not an env file): the checkout being
    # migrated may predate the Ficus rename and read only TAU_MIGRATE_LIVE.
    if (cd "${src_dest}/apps/core" && FICUS_MIGRATE_LIVE=1 TAU_MIGRATE_LIVE=1 bun run db:migrate); then
      log_info "migrations complete"
      return 0
    fi
    log_warn "db:migrate attempt ${attempt} failed — retrying in 5s (database may still be initializing)"
    sleep 5
  done
  die "database migrations failed after 3 attempts"
}

# Probe BOTH loopback families. The rendered .env pins HOST=127.0.0.1, but a
# hand-edited .env (or a future default change) could bind ::1 instead, and a
# v4-only probe then reports a healthy core as dead — which is exactly what
# happened before HOST was pinned. Checking both means the probe reflects the
# core's health rather than its address family.
core_api_health_ok() { # CORE_PORT
  local code url
  for url in "http://127.0.0.1:$1/health" "http://[::1]:$1/health"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null) || continue
    [[ ${code} == 200 || ${code} == 401 ]] && return 0
  done
  return 1
}

core_worker_active() { as_root systemctl is-active --quiet tau-worker; }
core_worker_restarts() { as_root systemctl show -p NRestarts --value tau-worker 2>/dev/null; }

# Restart tau-api + tau-worker and REFUSE to return until both are genuinely
# serving. Dies otherwise, dumping the relevant journal — a restart that is
# reported as successful while the unit crash-loops is the second half of the
# stale-bundle trap (the first half being a skipped build).
restart_core_services() { # CORE_PORT
  local core_port=$1
  # A unit that crash-looped its StartLimitBurst dry is LOCKED OUT: plain
  # `systemctl restart` then fails instantly with "Start request repeated too
  # quickly" — which is exactly the state a rollback finds the services in
  # after a bad release crash-looped (live-hit on the first artifact canary).
  # reset-failed clears the lockout; on a healthy unit it is a no-op.
  as_root systemctl reset-failed tau-api tau-worker 2>/dev/null || true
  as_root systemctl restart tau-api tau-worker
  if ! retry_until 180 3 "core API up (GET /health → 200/401)" core_api_health_ok "${core_port}"; then
    log_error "tau-api did not become healthy — last journald lines:"
    as_root journalctl -u tau-api -n 60 --no-pager >&2 || true
    die "core API failed to start"
  fi
  if ! retry_until 60 2 'tau-worker active' core_worker_active; then
    log_error "tau-worker is not active — last journald lines:"
    as_root journalctl -u tau-worker -n 60 --no-pager >&2 || true
    die "worker failed to start"
  fi
  # is-active reads "active" even mid-crash-loop (the start→crash window under
  # Restart=on-failure), so also require the restart counter to hold still for
  # a bounded observation window (> RestartSec=3). NRestarts resets on the
  # manual `systemctl restart` above, so any climb here is a fresh crash loop.
  local restarts_before restarts_after
  restarts_before=$(core_worker_restarts)
  if [[ ${restarts_before} =~ ^[0-9]+$ ]]; then
    sleep 8
    restarts_after=$(core_worker_restarts)
    if [[ ${restarts_after} != "${restarts_before}" ]] || ! core_worker_active; then
      log_error "tau-worker is crash-looping (NRestarts ${restarts_before} → ${restarts_after:-?}) — last journald lines:"
      as_root journalctl -u tau-worker -n 60 --no-pager >&2 || true
      die "worker started but did not stay up"
    fi
  else
    log_warn "could not read NRestarts for tau-worker (got '${restarts_before}') — skipping the crash-loop check"
  fi
  log_info "services up: api on :${core_port} (health 401 = up + auth-gated), worker active"
}

# ------------------------------------------------------ core release artifacts
#
# The box side of the prebuilt-core-artifact pipeline (spec
# docs/history/superpowers/specs/2026-08-20-prebuilt-core-artifacts-design.md §4.4).
# A tenant VM stops building tau: it downloads an immutable, content-addressed
# release artifact, verifies it, and activates it by moving ONE symlink.
#
#   <dest>/releases/<sha>-<digest12>/   an extracted, verified artifact
#   <dest>/current  -> releases/<…>     the ONLY thing activation changes
#   <dest>/previous -> releases/<…>     the rollback target
#   <dest>/.env                         secrets — outside the releases
#
# Trust posture: the transport (a short-lived presigned GET) is NOT the trust
# boundary. The Ed25519 signature over artifact.json's BYTES is checked before
# any field of the manifest is believed; then EVERY extracted file is re-hashed
# against that manifest in BOTH directions, so neither a partial extract (a
# path the manifest lists but the tree lacks) nor an injected file (in the
# tree, absent from the manifest) can reach `current`; then the host's bun is
# compared against the version the artifact was built for. Only after all of
# that does anything get staged.
#
# The artifact format is P1's and frozen: tarball root `tau-core-<sha>/`,
# `artifact.json` at that root (schema 1, files map keyed by POSIX relpath ->
# `sha256:<hex>`, the root artifact.json excluded from its own map), digest =
# sha256 over the canonical (key-sorted) files map, `artifact.sig` = base64
# Ed25519 over the artifact.json bytes.
#
# These helpers target Ubuntu (GNU coreutils, OpenSSL 3, jq — all already in
# the toolkit's apt list). `openssl pkeyutl -rawin` is the load-bearing one:
# LibreSSL and OpenSSL 1.1 cannot verify a raw Ed25519 signature at all, so a
# missing -rawin is a hard, actionable failure rather than a skipped check.

# Where a verified release lives. The identity of a release is the pair
# (commit, digest): two builds of the same commit that produce different bytes
# are different releases and must not share a directory.
artifact_release_dir() { # DEST SHA DIGEST12
  printf '%s/releases/%s-%s\n' "$1" "$2" "$3"
}

# The short form of a `sha256:<hex>` digest used in release directory names.
artifact_digest12() { # DIGEST
  local digest=$1
  printf '%s\n' "${digest#sha256:}" | cut -c1-12
}

# What <DEST> is serving right now, as a trailer value:
#   <sha>-<digest12>   artifact layout (current -> releases/<id>)
#   git-<sha>          a pre-conversion git checkout (upgrade-host.sh converts
#                      it on the first artifact upgrade)
#   unknown            neither — a box in an unexpected state
artifact_current_release_id() { # DEST
  local dest=$1 target sha
  target=$(readlink "${dest}/current" 2>/dev/null || true)
  if [[ -n ${target} ]]; then
    printf '%s\n' "$(basename "${target}")"
    return 0
  fi
  if [[ -d ${dest}/.git ]] && have git; then
    sha=$(git -C "${dest}" rev-parse HEAD 2>/dev/null || true)
    if [[ -n ${sha} ]]; then
      printf 'git-%s\n' "${sha}"
      return 0
    fi
  fi
  printf 'unknown\n'
}

# The stdout trailer the control plane parses to learn what this run did.
# FICUS_RELEASE_ROLLED_BACK is emitted by artifact_activate itself (it is the
# only code that knows whether the flip survived), so it is deliberately NOT
# printed here — printing it twice would let a caller's stale value shadow the
# real outcome.
artifact_emit_release_trailer() { # BEFORE AFTER
  printf 'FICUS_RELEASE_BEFORE=%s\nFICUS_RELEASE_AFTER=%s\n' "${1:-unknown}" "${2:-unknown}"
}

# Abort an acquire: delete the half-downloaded incoming dir, print the machine
# -readable reason token on STDOUT (the human explanation goes to stderr like
# every other log line), and exit non-zero.
#
# The exit is only as containing as the caller's context: inside a `$(...)` it
# ends the substitution subshell and the caller sees a non-zero status plus the
# token as captured output — the caller MUST check that status (and re-emit the
# token line, which is now in its variable rather than on the log stream).
# Called anywhere else it terminates the script outright, like die().
_artifact_fail() { # INCOMING_DIR TOKEN MESSAGE...
  local incoming=$1 token=$2
  shift 2
  log_error "$*"
  if [[ -n ${incoming} ]]; then rm -rf "${incoming}"; fi
  printf 'FICUS_ARTIFACT_ERROR=%s\n' "${token}"
  exit 1
}

# Point LINK at TARGET atomically, even when LINK already exists and resolves
# to a DIRECTORY — where a plain `ln -sfn` would create the new link INSIDE
# that directory instead of replacing it. Create a sibling and rename it over:
# the control plane's own release flip (setup-platform.sh, and the manual
# rollback in the operator recovery procedure) uses this exact recipe,
# and rename(2) means no reader ever sees a missing `current`.
_artifact_symlink_swap() { # TARGET LINK
  local target=$1 link=$2
  ln -sfn "${target}" "${link}.next" && mv -Tf "${link}.next" "${link}"
}

# Convert a git-checkout box to the artifact layout, in place: the checkout
# that is running right now becomes `releases/git-<head sha>` — the tree
# `current` points at from this moment on, and the rollback target of the
# first artifact activation. Gated on `.git` being present at <dest>: that is
# also the RESUME signal (see below), so it is the trigger, not "releases/ is
# absent".
#
# What does NOT move: `.env` (the secrets — FICUS_ENCRYPTION_KEY among them —
# live at <dest>/.env in BOTH layouts, which is exactly why the units keep
# `EnvironmentFile=<dest>/.env` while their WorkingDirectory follows the run
# root), `releases/` itself, `.tau-build-stamp` (a claim about a checkout that
# is no longer at <dest>; the outputs it names travel with the tree), and the
# `current`/`previous` links, which are layout, not checkout content.
#
# EVERYTHING else moves, dotfiles included — `.git` is the whole point, and a
# `mv <dest>/* <target>` glob silently leaves every dotfile behind.
#
# RESUMABLE. Each entry is moved with its own rename(2), so a crash leaves
# every entry either wholly at <dest> or wholly in the release — never half of
# one. `.git` is moved LAST and is the trigger, so an interrupted conversion
# still looks like "a git checkout at <dest>" to the next run, which then
# moves the remainder into the release dir that already exists. An entry
# present on BOTH sides cannot come from an interrupted run (a rename is
# atomic) and is refused rather than merged.
#
# `current` is set here, not left for the activation: between this function
# and the flip the box must survive a reboot, and units whose WorkingDirectory
# is <dest>/current must never name a path that does not exist. `previous` is
# set to the same tree so the layout is complete and self-consistent from the
# first instant.
#
# The services keep running from the tree at its NEW path: a running process
# holds its cwd and open file descriptors across a rename, so the old core
# keeps serving until the caller restarts it.
artifact_convert_git_checkout() { # DEST
  local dest=$1 head_sha target entry name
  require_cmd git
  [[ -d ${dest}/.git ]] ||
    die "artifact_convert_git_checkout: '${dest}' is not a git checkout — nothing to convert"
  head_sha=$(git -C "${dest}" rev-parse HEAD) ||
    die "artifact_convert_git_checkout: could not read HEAD of ${dest}"
  target="${dest}/releases/git-${head_sha}"
  log_warn "converting the git checkout at ${dest} to the artifact layout — the old tree becomes releases/git-${head_sha:0:12} (the rollback target)"
  mkdir -p "${target}"
  # Two passes so `.git` lands last: while it is still at <dest> this whole
  # conversion is resumable.
  while IFS= read -r entry; do
    [[ -n ${entry} ]] || continue
    name=${entry##*/}
    # Written as an if, not `[[ … ]] && die`: the && form returns 1 on the
    # normal path and can trip an inherited `set -e`.
    if [[ -e ${target}/${name} ]]; then
      die "artifact_convert_git_checkout: '${name}' exists at BOTH ${dest} and ${target} — refusing to merge two trees; move or remove one by hand"
    fi
    mv "${entry}" "${target}/${name}" ||
      die "artifact_convert_git_checkout: could not move ${name} into ${target}"
  done < <(
    find "${dest}" -mindepth 1 -maxdepth 1 \
      ! -name releases ! -name .env ! -name .tau-build-stamp \
      ! -name current ! -name previous ! -name .git
    printf '%s\n' "${dest}/.git"
  )
  # Proof the dotfiles came along, not just the visible tree.
  [[ -d ${target}/.git ]] ||
    die "artifact_convert_git_checkout: ${target} has no .git after the move — the conversion did not move the checkout"
  _artifact_symlink_swap "${target}" "${dest}/previous"
  _artifact_symlink_swap "${target}" "${dest}/current"
  # The tree just moved was BUILT at ${dest}: bun inlines module __dirname
  # into the bundle as an absolute path, and some deps read files from
  # node_modules through it at boot (jsdom loads its default stylesheet that
  # way). The old build therefore only runs while ${dest}/node_modules still
  # resolves — without this compat symlink the conversion silently breaks its
  # own rollback target (live-hit on the first artifact canary).
  if [[ -d ${target}/node_modules ]]; then
    ln -sfn "${target}/node_modules" "${dest}/node_modules" ||
      die "artifact_convert_git_checkout: could not leave the node_modules compat symlink"
  fi
  log_info "converted ${dest}: current and previous -> releases/git-${head_sha}"
}

# Fetch ONE artifact file. The URL is a presigned GET, i.e. a credential, and
# argv is world-readable through /proc/<pid>/cmdline (and `ps`) for as long as
# curl runs — so the URL is handed to curl on STDIN via `--config -` instead,
# where nothing but this process and curl ever sees it. Everything else stays
# in argv: none of it is secret. curl's own stderr is discarded because its
# error text can echo the URL it failed on.
#
# Config-file syntax: a double-quoted value understands backslash escapes, so
# both characters that could end the string early are escaped first.
_artifact_curl_download() { # OUT_FILE URL
  local out=$1 url=$2 escaped
  escaped=${url//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf 'url = "%s"\n' "${escaped}" |
    curl -fsSL --retry 3 --retry-delay 2 -o "${out}" --config - 2>/dev/null
}

# Download + verify a core release artifact. Nothing is trusted until the
# signature over artifact.json checks out, and nothing is staged until every
# file in the extracted tree matches the manifest.
#
# OUTPUT CONTRACT (parsed by callers — upgrade-host.sh):
#   success: exactly two stdout lines
#              1) "<sha> <digest12>"
#              2) the path of the verified, extracted tree (feed both to
#                 artifact_stage)
#   failure: one stdout line "FICUS_ARTIFACT_ERROR=<token>" and a non-zero EXIT
#            (not a return — see _artifact_fail). Tokens: download_failed,
#            sig_invalid, hash_mismatch, bun_mismatch, manifest_invalid.
#
# Because the failure token goes to stdout, a caller that captures stdout (the
# only way to read the success lines) owns re-emitting that line so the control
# plane's log scanner still sees it.
#
# The three URLs are credentials (presigned GETs): they are never logged, and
# curl's own stderr — which can echo the URL it failed on — is discarded in
# favour of a message naming which of the three files failed.
artifact_acquire() { # DEST TARBALL_URL MANIFEST_URL SIG_URL PUBKEY_PEM_PATH
  local dest=$1 tarball_url=$2 manifest_url=$3 sig_url=$4 pubkey=$5
  local incoming tree schema commit platform digest digest12 manifest_bun host_bun files_n pkeyutl_help

  require_cmd curl
  require_cmd jq
  require_cmd openssl
  # bun's installer only exports its PATH from the shell rc files, which a
  # non-interactive ssh session never reads — repair PATH before demanding it.
  bun_path_prepend
  require_cmd bun "setup-host.sh installs bun at \${HOME}/.bun/bin — was this host set up by the toolkit?"
  [[ -s ${pubkey} ]] || die "artifact_acquire: artifact public key '${pubkey}' is missing or empty"
  # Fail loudly on a toolchain that CANNOT check the signature, rather than
  # silently degrading to an unverified download.
  pkeyutl_help=$(openssl pkeyutl -help 2>&1 || true)
  case ${pkeyutl_help} in
  *-rawin*) ;;
  *) die "this openssl has no 'pkeyutl -rawin' ($(openssl version 2>/dev/null)) — raw Ed25519 verification needs OpenSSL 3.x (LibreSSL and OpenSSL 1.1 cannot do it); install openssl >= 3" ;;
  esac

  # Sweep the staging area first: an acquire that is killed between the
  # download and the stage (a job timeout, a reboot, an OOM) leaves an
  # artifact-sized session dir behind, and artifact_retention cannot see it —
  # its glob does not match dot directories. Upgrades are serialized per tenant
  # by the job queue's advisory lock, so no concurrent acquire can be using it.
  rm -rf "${dest}/releases/.incoming"
  mkdir -p "${dest}/releases/.incoming"
  # mktemp INSIDE releases/ so the later stage move is a same-filesystem
  # rename (atomic) rather than a copy.
  incoming=$(mktemp -d "${dest}/releases/.incoming/XXXXXXXX") ||
    die "artifact_acquire: could not create an incoming dir under ${dest}/releases/.incoming"

  _artifact_curl_download "${incoming}/artifact.json" "${manifest_url}" ||
    _artifact_fail "${incoming}" download_failed "could not download the artifact manifest (artifact.json)"
  _artifact_curl_download "${incoming}/artifact.sig" "${sig_url}" ||
    _artifact_fail "${incoming}" download_failed "could not download the artifact signature (artifact.sig)"
  _artifact_curl_download "${incoming}/artifact.tar.gz" "${tarball_url}" ||
    _artifact_fail "${incoming}" download_failed "could not download the artifact tarball"

  # --- 1. signature over the manifest BYTES, before reading a single field ---
  base64 -d <"${incoming}/artifact.sig" >"${incoming}/artifact.sig.bin" 2>/dev/null ||
    _artifact_fail "${incoming}" sig_invalid "artifact.sig is not valid base64"
  openssl pkeyutl -verify -pubin -inkey "${pubkey}" -rawin \
    -in "${incoming}/artifact.json" -sigfile "${incoming}/artifact.sig.bin" >/dev/null 2>&1 ||
    _artifact_fail "${incoming}" sig_invalid "artifact.json failed Ed25519 signature verification against ${pubkey}"
  log_info "artifact signature ok"

  # --- 2. manifest shape (now that it is authentic, is it what we expect?) ---
  jq -e . <"${incoming}/artifact.json" >/dev/null 2>&1 ||
    _artifact_fail "${incoming}" manifest_invalid "artifact.json is not valid JSON"
  schema=$(jq -r '.schema // empty' <"${incoming}/artifact.json")
  [[ ${schema} == 1 ]] ||
    _artifact_fail "${incoming}" manifest_invalid "unsupported artifact manifest schema '${schema}' (this toolkit understands 1)"
  commit=$(jq -r '.commit // empty' <"${incoming}/artifact.json")
  [[ ${commit} =~ ^[0-9a-f]{40}$ ]] ||
    _artifact_fail "${incoming}" manifest_invalid "artifact manifest commit '${commit}' is not a 40-hex sha"
  platform=$(jq -r '.platform // empty' <"${incoming}/artifact.json")
  [[ ${platform} == linux-x64 ]] ||
    _artifact_fail "${incoming}" manifest_invalid "artifact platform '${platform}' is not linux-x64"
  digest=$(jq -r '.digest // empty' <"${incoming}/artifact.json")
  [[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] ||
    _artifact_fail "${incoming}" manifest_invalid "artifact digest '${digest}' is not a sha256:<hex> digest"
  files_n=$(jq -r '(.files // {}) | length' <"${incoming}/artifact.json")
  [[ ${files_n} =~ ^[0-9]+$ && ${files_n} -gt 0 ]] ||
    _artifact_fail "${incoming}" manifest_invalid "artifact manifest lists no files"

  # --- 3. extract, refusing a tarball that reaches outside its own root ------
  tree="${incoming}/tree/tau-core-${commit}"
  mkdir -p "${incoming}/tree"
  tar -tzf "${incoming}/artifact.tar.gz" >"${incoming}/members.txt" 2>/dev/null ||
    _artifact_fail "${incoming}" download_failed "the artifact tarball is not readable gzip (truncated download?)"
  if grep -qvE "^tau-core-${commit}/" "${incoming}/members.txt" ||
    grep -qE '(^|/)\.\.(/|$)' "${incoming}/members.txt"; then
    _artifact_fail "${incoming}" download_failed "the tarball has members outside tau-core-${commit}/ — refusing to extract it"
  fi
  # --no-same-owner/--no-same-permissions: the archive's uid/gid/mode bits are
  # the BUILDER's, and this may run as root — the tree belongs to whoever the
  # box runs as, with a sane umask, not to whatever the tarball claims.
  tar -xzf "${incoming}/artifact.tar.gz" --no-same-owner --no-same-permissions -C "${incoming}/tree" ||
    _artifact_fail "${incoming}" download_failed "extracting the artifact tarball failed"
  [[ -d ${tree} ]] ||
    _artifact_fail "${incoming}" download_failed "the tarball did not contain tau-core-${commit}/"

  # The tree carries its own copy of the manifest (core reads it to self-report
  # its version). It must be the very bytes we verified the signature over.
  cmp -s "${tree}/artifact.json" "${incoming}/artifact.json" ||
    _artifact_fail "${incoming}" manifest_invalid "the in-tree artifact.json differs from the signed manifest"

  # --- 4. every file, both directions ---------------------------------------
  # Set first: a path the manifest lists but the tree lacks (partial extract)
  # and a file in the tree the manifest never mentions (injection) are equally
  # fatal. `! -type d` rather than `-type f` so a smuggled symlink shows up as
  # an extra entry instead of being invisible to the walk.
  jq -r '.files | keys[]' <"${incoming}/artifact.json" | LC_ALL=C sort >"${incoming}/expected.txt"
  (cd "${tree}" && find . ! -type d | sed -e 's|^\./||' -e '/^artifact\.json$/d') |
    LC_ALL=C sort >"${incoming}/actual.txt"
  if ! diff -u "${incoming}/expected.txt" "${incoming}/actual.txt" >"${incoming}/files.diff" 2>&1; then
    log_error "the artifact tree does not match the manifest's file list (-manifest/+tree):"
    head -40 "${incoming}/files.diff" >&2
    _artifact_fail "${incoming}" hash_mismatch "artifact tree/manifest file lists differ"
  fi
  # Bytes second: one sha256sum -c pass over the manifest's own hashes.
  jq -r '.files | to_entries[] | "\(.value | sub("^sha256:"; ""))  \(.key)"' \
    <"${incoming}/artifact.json" >"${incoming}/sums.txt"
  if ! (cd "${tree}" && sha256sum -c --quiet --strict "${incoming}/sums.txt") >"${incoming}/sums.out" 2>&1; then
    log_error "artifact files failing sha256 verification:"
    head -20 "${incoming}/sums.out" >&2
    _artifact_fail "${incoming}" hash_mismatch "one or more artifact files do not match their manifest sha256"
  fi

  # --- 5. the bun pin (the artifact ships no runtime of its own) -------------
  manifest_bun=$(jq -r '.bun // empty' <"${incoming}/artifact.json")
  host_bun=$(bun --version 2>/dev/null | tr -d '[:space:]')
  [[ -n ${manifest_bun} ]] ||
    _artifact_fail "${incoming}" manifest_invalid "artifact manifest does not record a bun version"
  # A mismatch is repaired, not refused: the manifest is signature-verified by
  # now, so its pin is trusted, and the release cannot run on any other bun.
  # Only a pin the installer cannot produce (malformed, or the install fails)
  # is still bun_mismatch.
  if [[ ${host_bun} != "${manifest_bun}" ]]; then
    log_warn "host bun ${host_bun:-<none>} != the ${manifest_bun} this artifact was built for — installing the pinned bun"
    install_pinned_bun "${manifest_bun}" ||
      _artifact_fail "${incoming}" bun_mismatch "host bun ${host_bun:-<none>} != the ${manifest_bun} this artifact was built for, and installing ${manifest_bun} failed"
    host_bun=$(bun --version 2>/dev/null | tr -d '[:space:]')
  fi
  [[ ${host_bun} == "${manifest_bun}" ]] ||
    _artifact_fail "${incoming}" bun_mismatch "host bun ${host_bun:-<none>} != the ${manifest_bun} this artifact was built for"

  digest12=$(artifact_digest12 "${digest}")
  log_info "artifact verified: commit ${commit:0:12}, digest ${digest12}, ${files_n} files, bun ${manifest_bun}"
  printf '%s %s\n%s\n' "${commit}" "${digest12}" "${tree}"
}

# Move a verified tree into its immutable release dir and mark it complete.
# The marker is what makes this idempotent: re-running for a release that is
# already complete is a no-op success (the CP's own completeRelease() posture),
# while a release dir WITHOUT the marker is the debris of an interrupted stage
# and gets replaced wholesale — never merged into, which is how a half-extracted
# tree would become activatable.
artifact_stage() { # DEST INCOMING_TREE SHA DIGEST12
  local dest=$1 tree=$2 sha=$3 digest12=$4 release marker digest tree_commit
  release=$(artifact_release_dir "${dest}" "${sha}" "${digest12}")
  marker="${release}/.tau-release-complete"
  if [[ -f ${marker} ]]; then
    log_info "release ${sha:0:12}-${digest12} is already staged and complete — nothing to do"
    _artifact_discard_incoming "${dest}" "${tree}"
    return 0
  fi
  [[ -d ${tree} ]] || die "artifact_stage: '${tree}' is not a directory — nothing to stage"
  if [[ -e ${release} ]]; then
    log_warn "replacing an incomplete release dir at ${release} (no .tau-release-complete marker)"
    rm -rf "${release}"
  fi
  # The caller passes the sha it thinks it verified; the tree carries the sha
  # it actually IS. A mismatch means the two got crossed somewhere between
  # acquire and stage, and staging it would file the tree under a name that
  # lies about its contents.
  tree_commit=$(jq -r '.commit // empty' <"${tree}/artifact.json" 2>/dev/null || true)
  [[ ${tree_commit} == "${sha}" ]] ||
    die "artifact_stage: the tree's artifact.json says commit '${tree_commit}', not '${sha}' — refusing to stage it"
  mkdir -p "${dest}/releases"
  mv "${tree}" "${release}" ||
    die "artifact_stage: could not move the verified tree into ${release} (same-filesystem rename expected)"
  digest=$(jq -r '.digest // empty' <"${release}/artifact.json" 2>/dev/null || true)
  # Marker last, and renamed into place, so its mere existence is proof the
  # whole tree landed.
  printf '{"sha":"%s","digest":"%s","digest12":"%s","stagedAt":"%s"}\n' \
    "${sha}" "${digest}" "${digest12}" "$(date -u +%FT%TZ)" >"${marker}.tmp"
  mv -f "${marker}.tmp" "${marker}"
  # The tree has moved out; the tarball, signature and work files it came with
  # have not. Leaving them would grow releases/.incoming by one artifact-sized
  # directory per upgrade.
  _artifact_discard_incoming "${dest}" "${tree}"
  log_info "staged release ${sha:0:12}-${digest12} at ${release}"
}

# Delete the acquire session directory a tree came from (tarball, manifest,
# signature, work files). Refuses to touch anything that is not under
# <dest>/releases/.incoming/.
_artifact_discard_incoming() { # DEST TREE
  local dest=$1 path=$2 base
  base="${dest}/releases/.incoming"
  [[ ${path} == "${base}/"* ]] || return 0
  while [[ ${path} == "${base}/"*/* ]]; do
    path=$(dirname "${path}")
  done
  rm -rf "${path}"
}

# The program the pre-flip migration runs, as the CHILD shell sees it: $1 is
# <dest>/.env, $2 is the candidate release dir (passed as arguments so no path
# has to survive a round of quoting).
#
# The env file is read VERBATIM — one KEY=VALUE per line, systemd's
# EnvironmentFile semantics — and deliberately NOT sourced. `.` would run the
# file as shell: a password containing `$` would be expanded to nothing, and a
# value containing backticks or $(...) would EXECUTE, as root, from a file
# whose whole purpose is to hold secrets nobody vets for shell syntax.
#
# FICUS_ROOT is exported AFTER the file is read, so a FICUS_ROOT that happens to
# live in .env (pointing at `current`, i.e. the OLD tree) cannot shadow the
# candidate being migrated. Both spellings are exported, and the caller sets
# both *_MIGRATE_LIVE: a pre-rename candidate reads TAU_ROOT and
# TAU_MIGRATE_LIVE (run-migrations.ts, paths.ts), a Ficus one FICUS_ (its
# bridge then drops the TAU_ copies). Per-invocation env, not an env file. The `|| [[ -n ${line} ]]` keeps a final line with
# no trailing newline.
# shellcheck disable=SC2016 # deliberate: this expands in the child shell, not here
_ARTIFACT_MIGRATE_PROGRAM='while IFS= read -r line || [[ -n ${line} ]]; do
  if [[ -z ${line} || ${line} == \#* || ${line} != *=* ]]; then continue; fi
  export "${line%%=*}=${line#*=}"
done <"$1"
export FICUS_ROOT="$2" TAU_ROOT="$2"
cd "$2/apps/core" && exec bun dist/migrate.js'

# Put a staged release into service: migrate from the CANDIDATE, flip the
# symlink, restart, and roll back if the box does not come up.
#
# The migrate runs BEFORE the flip so a migration failure leaves `current`
# untouched, and it runs from the candidate with FICUS_ROOT pinned to it — never
# inherited, which would point the runner at the OLD `current` tree. The
# candidate carries no .env of its own (secrets live at <dest>/.env, outside
# the releases), so the DB env is sourced explicitly and only for that step —
# the #937 failure class, where a runner that had always been started from a
# directory containing .env silently lost its database URL.
#
# Emits FICUS_RELEASE_ROLLED_BACK=0|1 on stdout. Returns non-zero if the release
# did not end up serving, whether or not the rollback itself succeeded.
#
# Two optional hooks (function names, empty = none):
#   ARTIFACT_PREFLIP_HOOK   called as `<hook> RELEASE_DIR` after the candidate
#                           migration succeeded and immediately before the
#                           first symlink swap — upgrade-host.sh renames the
#                           host's env files there, so the old release serves
#                           renamed files for no longer than this one step. A
#                           failure ends the activation with `current`
#                           untouched (and the caller's EXIT trap restores).
#   ARTIFACT_ROLLBACK_HOOK  called with no arguments after the symlinks are
#                           swapped back and before the rollback restart —
#                           upgrade-host.sh restores the env backup set there.
#                           Its failure is logged; the rollback restart still
#                           runs.
artifact_activate() { # DEST RELEASE_DIR CORE_PORT
  local dest=$1 release_dir=$2 core_port=$3 cur_before prev_before attempt hook_rc
  [[ -f ${release_dir}/.tau-release-complete ]] ||
    die "artifact_activate: ${release_dir} has no .tau-release-complete marker — refusing to activate an unverified tree"
  [[ -f ${dest}/.env ]] ||
    die "artifact_activate: ${dest}/.env is missing — a release tree carries no environment of its own"

  # --- 1. migrate from the candidate (forward-only, same retry as git mode) --
  for attempt in 1 2 3; do
    if env FICUS_ROOT="${release_dir}" TAU_ROOT="${release_dir}" FICUS_MIGRATE_LIVE=1 TAU_MIGRATE_LIVE=1 \
      bash -c "${_ARTIFACT_MIGRATE_PROGRAM}" tau-migrate "${dest}/.env" "${release_dir}"; then
      log_info "migrations complete (candidate ${release_dir})"
      break
    fi
    [[ ${attempt} -lt 3 ]] ||
      die "database migrations failed after 3 attempts from ${release_dir} — 'current' left untouched"
    log_warn "migrate attempt ${attempt} failed — retrying in 5s (database may still be initializing)"
    sleep 5
  done

  # --- 2. the flip (one rename; previous only moves on a successful flip) ----
  cur_before=$(readlink "${dest}/current" 2>/dev/null || true)
  prev_before=$(readlink "${dest}/previous" 2>/dev/null || true)
  if [[ -n ${ARTIFACT_PREFLIP_HOOK:-} ]]; then
    declare -F "${ARTIFACT_PREFLIP_HOOK}" >/dev/null ||
      die "artifact_activate: ARTIFACT_PREFLIP_HOOK '${ARTIFACT_PREFLIP_HOOK}' is not a function — 'current' left untouched"
    # A plain call, not `hook || …`: that form would suppress errexit inside
    # the hook. With errexit live a failure ends the script here; without it
    # (a caller's condition), the status check below does.
    hook_rc=0
    "${ARTIFACT_PREFLIP_HOOK}" "${release_dir}"
    hook_rc=$?
    [[ ${hook_rc} -eq 0 ]] ||
      die "artifact_activate: the pre-flip hook failed (${hook_rc}) — 'current' left untouched"
  fi
  _artifact_symlink_swap "${release_dir}" "${dest}/current"
  # Re-activating the release that is ALREADY current displaces nothing, so
  # `previous` must not move. Setting previous=current there would destroy the
  # rollback pointer twice over: the real previous is forgotten, AND
  # artifact_retention — which keeps exactly what current and previous name —
  # is handed permission to delete it from disk.
  if [[ -n ${cur_before} && ${cur_before} != "${release_dir}" ]]; then
    _artifact_symlink_swap "${cur_before}" "${dest}/previous"
  fi
  log_info "current -> $(basename "${release_dir}") (previous -> ${cur_before:-<none>})"

  # --- 3. restart and prove the box is actually serving ---------------------
  # Unconditional daemon-reload: it is cheap and idempotent, and skipping it
  # would restart into a stale unit whenever the units were re-rendered in the
  # same run (the artifact layout changes WorkingDirectory).
  as_root systemctl daemon-reload || log_warn "systemctl daemon-reload failed — continuing to the restart"
  # In a SUBSHELL: restart_core_services die()s on an unhealthy box, and a die
  # in this shell would take the rollback with it.
  if (restart_core_services "${core_port}"); then
    printf 'FICUS_RELEASE_ROLLED_BACK=0\n'
    return 0
  fi

  # --- 4. auto-rollback -----------------------------------------------------
  log_error "core did not come up on $(basename "${release_dir}")"
  # Nothing to roll back to when there was no `current`, and equally when
  # `current` was already THIS release: flipping it to itself would report a
  # rollback that never happened.
  if [[ -z ${cur_before} || ${cur_before} == "${release_dir}" ]]; then
    log_error "no earlier release to roll back to — ${dest}/current still points at the failed release"
    printf 'FICUS_RELEASE_ROLLED_BACK=0\n'
    return 1
  fi
  log_error "rolling back: current -> $(basename "${cur_before}")"
  _artifact_symlink_swap "${cur_before}" "${dest}/current"
  # Put `previous` back exactly as it was, including "there wasn't one" — a
  # rolled-back activation must leave no trace, and a `previous` left equal to
  # `current` would make a later rollback a silent no-op.
  if [[ -n ${prev_before} ]]; then
    _artifact_symlink_swap "${prev_before}" "${dest}/previous"
  else
    rm -f "${dest}/previous"
  fi
  if [[ -n ${ARTIFACT_ROLLBACK_HOOK:-} ]]; then
    if ! "${ARTIFACT_ROLLBACK_HOOK}"; then
      log_error "the rollback hook (${ARTIFACT_ROLLBACK_HOOK}) failed — continuing with the rollback restart"
    fi
  fi
  # Best effort — but a failed rollback restart must NOT turn into a zero exit.
  (restart_core_services "${core_port}") ||
    log_error "the rollback restart ALSO failed — this box needs an operator"
  printf 'FICUS_RELEASE_ROLLED_BACK=1\n'
  return 1
}

# Prune old releases: keep whatever `current` and `previous` point at, plus the
# two newest others (by mtime), and delete the rest. Only direct children of
# <dest>/releases are considered — the glob skips .incoming, and nothing
# outside that directory is ever looked at, let alone removed.
artifact_retention() { # DEST
  local dest=$1 releases keep entry name extra=0 target
  releases="${dest}/releases"
  [[ -d ${releases} ]] || return 0
  keep=$'\n'
  for target in "$(readlink "${dest}/current" 2>/dev/null || true)" "$(readlink "${dest}/previous" 2>/dev/null || true)"; do
    if [[ -n ${target} ]]; then keep="${keep}$(basename "${target}")"$'\n'; fi
  done
  while IFS= read -r entry; do
    [[ -d ${entry} ]] || continue
    name=$(basename "${entry}")
    if [[ ${keep} == *$'\n'"${name}"$'\n'* ]]; then continue; fi
    if ((extra < 2)); then
      extra=$((extra + 1))
      continue
    fi
    log_info "retention: removing old release ${name}"
    rm -rf "${entry}"
  done < <(ls -1dt "${releases}"/*/ 2>/dev/null || true)
  # If pruning removed the converted git tree, the conversion-era compat
  # symlink (see artifact_convert_git_checkout) now dangles — drop it.
  if [[ -L ${dest}/node_modules && ! -e ${dest}/node_modules ]]; then
    rm -f "${dest}/node_modules"
  fi
}

# ------------------------------------------------ env prefix rename (Ficus)
#
# The Ficus rename renames every TAU_* setting to FICUS_*. Core reads FICUS_*
# from the release that ships the rename on (with a one-release in-process
# fallback, packages/shared/src/legacy-env.ts), so the host's env-bearing files
# are HARD-RENAMED — once, by the upgrade that moves the host onto that
# release, and never before:
#
#   <dest>/.env, managed.env, backup.env    KEY= / export KEY= lines
#   the host config yaml                    .core.env.<P>_* keys
#   the core API and worker units + drop-ins  Environment=<P>_ lines
#   the installed tau-backup.sh             re-rendered from the template
#
# Only NAMES change. Values — the host's install paths included — and file
# locations are phase-5 identity and stay exactly as they are.
#
# Safety, in the order it happens:
#   * direction: the TARGET prefix comes from the release being activated
#     (core_release_env_prefix: artifact.json .envPrefix, else package.json
#     .name), never from a literal. A pre-rename target on a renamed host is
#     refused before anything changes.
#   * conflicts (Ruling 24): TAU_X and FICUS_X that both exist with DIFFERENT
#     values for a suffix containing ENCRYPTION_KEY or PASSWORD stop the run
#     before a single byte is written. Messages name keys, never values.
#   * backup set: every env-bearing file is copied byte for byte (cp -p, cmp,
#     sha256 in a MANIFEST) into ${ENV_RENAME_BACKUP_ROOT}/<ts>-<rand>/, root
#     0700. The set holds PLAINTEXT SECRETS; the newest five are kept.
#   * journal: PENDING (<set>\t<target>\t<release>) is fsynced before the
#     first rename and removed on commit or on a verified restore. A run that
#     dies without either — KILL, OOM, reboot — leaves it for the next toolkit
#     run, whose env_prefix_reconcile makes the files match the ACTIVE
#     release: restore when it reads TAU_, finish the rename when it reads
#     FICUS_.
#   * restore: the EXIT/TERM/HUP/INT traps (env_prefix_install_traps) and the
#     artifact rollback hook put the set back when a run fails after renaming.
#
# Every function here checks every step explicitly (die / return 1) instead of
# leaning on errexit: callers run them inside `$(...)`, `if !` and `||`
# spans, where bash suppresses errexit for the whole dynamic extent.

# Where backup sets and the PENDING journal live. Read at CALL time, so a test
# (or an operator) can point it elsewhere after sourcing this file.
env_rename_backup_root() {
  printf '%s' "${ENV_RENAME_BACKUP_ROOT:-/var/backups/ficus-env-rename}"
}

# Run state for the current toolkit invocation (see the traps below).
ENV_RENAME_PENDING=0
ENV_RENAME_BACKUP_SET=''

_epr_is_prefix() { [[ $1 == FICUS || $1 == TAU ]]; }

# The rename, the restore and the reconcile write root-owned files (the backup
# root, managed.env, backup.env, the units) and are ROOT-ONLY (Controller
# Ruling 30). A non-root (sudo) run takes no lock and proceeds only while none
# of them is needed; it refuses otherwise, with the reason.
_epr_is_root() { [[ ${EUID} -eq 0 ]]; }
_epr_require_prefixes() { # CALLER FROM TO
  if ! _epr_is_prefix "$2" || ! _epr_is_prefix "$3"; then
    die "$1: prefixes must be TAU or FICUS (got '$2' -> '$3')"
  fi
}
_epr_protected() { [[ $1 == *ENCRYPTION_KEY* || $1 == *PASSWORD* ]]; }
_epr_managed_keys() { [[ $1 == MANAGED_SECRET_KEYS || $1 == *_MANAGED_SECRET_KEYS ]]; }

# Trim [[:space:]] (C locale) off both ends / the start of $1 into _EPR_OUT.
_epr_trim() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  _EPR_OUT=${v%"${v##*[![:space:]]}"}
}
_epr_trim_start() {
  local v=$1
  _EPR_OUT=${v#"${v%%[![:space:]]*}"}
}

# Index of the first QUOTE in TEXT not escaped by a backslash, or -1, into
# _EPR_CLOSE (renameEnvPrefix's findClosingQuote).
_epr_find_close() { # TEXT QUOTE
  local t=$1 q=$2 i=0 n=${#1} c
  while ((i < n)); do
    c=${t:i:1}
    if [[ ${c} == "\\" ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ ${c} == "${q}" ]]; then
      _EPR_CLOSE=${i}
      return 0
    fi
    i=$((i + 1))
  done
  _EPR_CLOSE=-1
}

# The value as a dotenv reader sees it, for comparing two entries: trimmed,
# one level of surrounding quotes removed (renameEnvPrefix's normalizedValue).
_epr_normalize() { # RAW -> _EPR_OUT
  local v q
  _epr_trim "$1"
  v=${_EPR_OUT}
  q=${v:0:1}
  if [[ ${q} == '"' || ${q} == "'" || ${q} == '`' ]]; then
    _epr_find_close "${v:1}" "${q}"
    if ((_EPR_CLOSE == -1)); then _EPR_OUT=${v:1}; else _EPR_OUT=${v:1:_EPR_CLOSE}; fi
  else
    _EPR_OUT=${v}
  fi
}

# Map the comma-separated names of a *_MANAGED_SECRET_KEYS value to TO
# (mapManagedKeyList): items trimmed, empty items dropped.
_epr_map_list() { # VALUE FROM TO -> _EPR_OUT
  local rest=$1 from=$2_ to=$3_ item out='' first=1
  while :; do
    if [[ ${rest} == *,* ]]; then
      item=${rest%%,*}
      rest=${rest#*,}
    else
      item=${rest}
      rest=''
    fi
    _epr_trim "${item}"
    item=${_EPR_OUT}
    if [[ -n ${item} ]]; then
      [[ ${item} == "${from}"* ]] && item=${to}${item#"${from}"}
      if ((first)); then out=${item}; else out+=",${item}"; fi
      first=0
    fi
    [[ -n ${rest} ]] || break
  done
  _EPR_OUT=${out}
}

# A raw *_MANAGED_SECRET_KEYS value mapped, keeping surrounding quotes
# (mapManagedKeyValue).
_epr_map_value() { # RAW FROM TO -> _EPR_OUT
  local v q
  _epr_trim "$1"
  v=${_EPR_OUT}
  q=${v:0:1}
  if ((${#v} >= 2)) && [[ (${q} == '"' || ${q} == "'") && ${v: -1} == "${q}" ]]; then
    _epr_map_list "${v:1:${#v}-2}" "$2" "$3"
    _EPR_OUT="${q}${_EPR_OUT}${q}"
  else
    _epr_map_list "${v}" "$2" "$3"
  fi
}

# Split RAW exactly like JavaScript's split('\n') into _EPR_LINES (a trailing
# newline yields a final empty element, so a join restores RAW byte for byte).
_epr_split_lines() { # RAW
  local rest=$1
  _EPR_LINES=()
  while [[ ${rest} == *$'\n'* ]]; do
    _EPR_LINES+=("${rest%%$'\n'*}")
    rest=${rest#*$'\n'}
  done
  _EPR_LINES+=("${rest}")
}

# Parse the KEY= assignments of _EPR_LINES (renameEnvPrefix's parseEnvEntries):
# `KEY=` with no space around `=`, optionally after indentation and `export `.
# A value that opens a quote and does not close it on the same line continues
# to the closing quote, so a KEY= line inside a PEM block is value text.
_epr_parse_entries() {
  local n=${#_EPR_LINES[@]} i=0 end body eol first opened q cont value
  local re='^([[:space:]]*(export[[:space:]]+)?)([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  _E_START=() _E_END=() _E_LEAD=() _E_KEY=() _E_FIRST=() _E_EOL=() _E_VALUE=()
  while ((i < n)); do
    body=${_EPR_LINES[i]}
    eol=''
    if [[ ${body} == *$'\r' ]]; then
      body=${body%$'\r'}
      eol=$'\r'
    fi
    # JavaScript's `.` stops at a bare CR, so such a line is not an entry there.
    if [[ ${body} =~ ${re} && ${BASH_REMATCH[4]} != *$'\r'* ]]; then
      first=${BASH_REMATCH[4]}
      _E_LEAD+=("${BASH_REMATCH[1]}")
      _E_KEY+=("${BASH_REMATCH[3]}")
      _E_FIRST+=("${first}")
      _E_EOL+=("${eol}")
      _E_START+=("${i}")
      end=${i}
      value=${first}
      _epr_trim_start "${first}"
      opened=${_EPR_OUT}
      q=${opened:0:1}
      if [[ ${q} == '"' || ${q} == "'" || ${q} == '`' ]]; then
        _epr_find_close "${opened:1}" "${q}"
        if ((_EPR_CLOSE == -1)); then
          while ((end + 1 < n)); do
            end=$((end + 1))
            cont=${_EPR_LINES[end]}
            cont=${cont%$'\r'}
            value+=$'\n'"${cont}"
            _epr_find_close "${cont}" "${q}"
            if ((_EPR_CLOSE != -1)); then break; fi
          done
        fi
      fi
      _E_END+=("${end}")
      _E_VALUE+=("${value}")
      i=$((end + 1))
    else
      i=$((i + 1))
    fi
  done
}

# Is NEEDLE one of the remaining arguments?
_epr_in() { # NEEDLE ITEM...
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == "${needle}" ]] && return 0
  done
  return 1
}

# The shell twin of renameEnvPrefix (packages/shared/src/legacy-env.ts), over
# the CONTENT of a dotenv file. Same semantics, pinned by lib.test.sh's
# TypeScript parity cases:
#   * every KEY= / export KEY= entry whose key starts with FROM_ becomes TO_;
#     comments, blank lines, order, CRLF endings and multi-line values kept;
#   * a TO_ entry for the same suffix wins and the FROM_ entry is dropped
#     (listed in _EPR_CONFLICTS when the values differ); identical values are
#     dropped silently;
#   * an empty TO_ value counts as unset (the FROM_ entry is renamed in place
#     and the empty TO_ entry dropped); an empty FROM_ value is dropped;
#   * *_MANAGED_SECRET_KEYS items are mapped to TO_;
#   * a PROTECTED suffix (ENCRYPTION_KEY / PASSWORD) with different non-empty
#     values returns 2 with the FROM_ keys in _EPR_PROTECTED and builds
#     nothing (Ruling 24).
# Sets _EPR_RESULT, _EPR_RENAMED (keys), _EPR_RENAMED_LINES, _EPR_CONFLICTS
# and _EPR_PROTECTED. Pure: never touches a file.
_epr_rename_content() { # RAW FROM TO
  local raw=$1 from=$2 to=$3 k j n suffix val tval target
  local -a tv_suf=() tv_val=() src=() drop_at=() repl_at=() repl_line=()
  _EPR_RESULT='' _EPR_RENAMED=() _EPR_RENAMED_LINES=0 _EPR_CONFLICTS=() _EPR_PROTECTED=()
  _epr_split_lines "${raw}"
  _epr_parse_entries
  n=${#_E_KEY[@]}

  # Existing TO_ values by suffix (the last one wins, as in dotenv), and the
  # suffixes that have a non-empty FROM_ value.
  for ((k = 0; k < n; k++)); do
    if [[ ${_E_KEY[k]} == "${to}_"?* ]]; then
      suffix=${_E_KEY[k]#"${to}_"}
      _epr_normalize "${_E_VALUE[k]}"
      for ((j = 0; j < ${#tv_suf[@]}; j++)); do
        [[ ${tv_suf[j]} == "${suffix}" ]] && break
      done
      tv_suf[j]=${suffix}
      tv_val[j]=${_EPR_OUT}
    fi
    if [[ ${_E_KEY[k]} == "${from}_"?* ]]; then
      _epr_normalize "${_E_VALUE[k]}"
      [[ -n ${_EPR_OUT} ]] && src+=("${_E_KEY[k]#"${from}_"}")
    fi
  done

  # _epr_target SUFFIX -> 0 with the winning TO_ value in _EPR_TV, 1 when TO_
  # is unset or empty. 2 in _EPR_TV_STATE marks "set but empty".
  _epr_target() {
    local s=$1 i
    _EPR_TV='' _EPR_TV_STATE=0
    for ((i = 0; i < ${#tv_suf[@]}; i++)); do
      if [[ ${tv_suf[i]} == "${s}" ]]; then
        _EPR_TV=${tv_val[i]}
        if [[ -n ${_EPR_TV} ]]; then
          _EPR_TV_STATE=1
          return 0
        fi
        _EPR_TV_STATE=2
        return 1
      fi
    done
    return 1
  }

  for ((k = 0; k < n; k++)); do
    [[ ${_E_KEY[k]} == "${from}_"?* ]] || continue
    suffix=${_E_KEY[k]#"${from}_"}
    _epr_protected "${suffix}" || continue
    _epr_target "${suffix}" || continue
    tval=${_EPR_TV}
    _epr_normalize "${_E_VALUE[k]}"
    if [[ -n ${_EPR_OUT} && ${_EPR_OUT} != "${tval}" ]] && ! _epr_in "${_E_KEY[k]}" ${_EPR_PROTECTED[@]+"${_EPR_PROTECTED[@]}"}; then
      _EPR_PROTECTED+=("${_E_KEY[k]}")
    fi
  done
  if ((${#_EPR_PROTECTED[@]} > 0)); then
    unset -f _epr_target
    return 2
  fi

  for ((k = 0; k < n; k++)); do
    if [[ ${_E_KEY[k]} == "${to}_"?* ]]; then
      suffix=${_E_KEY[k]#"${to}_"}
      if ! _epr_target "${suffix}" && _epr_in "${suffix}" ${src[@]+"${src[@]}"}; then
        drop_at+=("${_E_START[k]}")
      fi
      continue
    fi
    [[ ${_E_KEY[k]} == "${from}_"?* ]] || continue
    suffix=${_E_KEY[k]#"${from}_"}
    _epr_normalize "${_E_VALUE[k]}"
    val=${_EPR_OUT}
    target=0
    _epr_target "${suffix}" && target=1
    if ((target)) || [[ ${_EPR_TV_STATE} -eq 2 && -z ${val} ]]; then
      if ((target)) && [[ -n ${val} && ${val} != "${_EPR_TV}" ]] && ! _epr_in "${_E_KEY[k]}" ${_EPR_CONFLICTS[@]+"${_EPR_CONFLICTS[@]}"}; then
        _EPR_CONFLICTS+=("${_E_KEY[k]}")
      fi
      drop_at+=("${_E_START[k]}")
      continue
    fi
    val=${_E_FIRST[k]}
    if [[ ${_E_START[k]} -eq ${_E_END[k]} ]] && _epr_managed_keys "${suffix}"; then
      _epr_map_value "${val}" "${from}" "${to}"
      val=${_EPR_OUT}
    fi
    repl_at+=("${_E_START[k]}")
    repl_line+=("${_E_LEAD[k]}${to}_${suffix}=${val}${_E_EOL[k]}")
    _EPR_RENAMED_LINES=$((_EPR_RENAMED_LINES + 1))
    _epr_in "${_E_KEY[k]}" ${_EPR_RENAMED[@]+"${_EPR_RENAMED[@]}"} || _EPR_RENAMED+=("${_E_KEY[k]}")
  done
  unset -f _epr_target

  # Re-join, dropping whole entries (continuation lines included).
  local out='' i=0 total=${#_EPR_LINES[@]} e line sep=''
  while ((i < total)); do
    line=${_EPR_LINES[i]}
    e=-1
    for ((j = 0; j < n; j++)); do
      if [[ ${_E_START[j]} -eq ${i} ]]; then
        e=${j}
        break
      fi
    done
    if ((e >= 0)) && _epr_in "${i}" ${drop_at[@]+"${drop_at[@]}"}; then
      i=$((_E_END[e] + 1))
      continue
    fi
    if ((e >= 0)); then
      for ((j = 0; j < ${#repl_at[@]}; j++)); do
        if [[ ${repl_at[j]} -eq ${i} ]]; then
          line=${repl_line[j]}
          break
        fi
      done
    fi
    out+="${sep}${line}"
    sep=$'\n'
    i=$((i + 1))
  done
  _EPR_RESULT=${out}
  return 0
}

# Copy SRC's mode and owner:group onto DST (GNU --reference, else stat).
_epr_copy_mode_owner() { # SRC DST
  local mog
  if ! chmod --reference="$1" "$2" 2>/dev/null; then
    mog=$(_file_mode_owner_group "$1") || return 1
    chmod "${mog%% *}" "$2" || return 1
  fi
  # Only when it differs: an unprivileged caller may not chown even to its
  # own user when the group is one it is not a member of.
  mog=$(_file_mode_owner_group "$1") || return 1
  [[ $(_file_mode_owner_group "$2") == "${mog}" ]] && return 0
  if ! chown --reference="$1" -- "$2" 2>/dev/null; then
    chown "${mog#* }" "$2" || return 1
  fi
}

# Replace the (already resolved) regular file TARGET with CONTENT atomically:
# a temp file in TARGET's own directory, TARGET's mode and owner, then one
# rename. A symlink that pointed at TARGET keeps pointing at it. Returns 1
# after a log_error — TARGET untouched — on any failure.
_epr_write_atomic() { # TARGET CONTENT
  local target=$1 content=$2 dir base tmp
  if ! dir=$(dirname -- "${target}") || ! base=$(basename -- "${target}"); then
    log_error "cannot resolve the directory of ${target}"
    return 1
  fi
  if ! tmp=$(mktemp "${dir}/.${base}.ficus-rename.XXXXXX") || [[ -z ${tmp} ]]; then
    log_error "failed to create a staging file next to ${target}"
    return 1
  fi
  if ! printf '%s' "${content}" >"${tmp}"; then
    rm -f -- "${tmp}"
    log_error "failed to write the staged replacement for ${target}"
    return 1
  fi
  if ! _epr_copy_mode_owner "${target}" "${tmp}"; then
    rm -f -- "${tmp}"
    log_error "failed to copy the mode/owner of ${target} onto its staged replacement"
    return 1
  fi
  if ! mv -f -- "${tmp}" "${target}"; then
    rm -f -- "${tmp}"
    log_error "failed to atomically replace ${target}"
    return 1
  fi
}

# Resolve FILE through symlinks (readlink -f) into the variable named VAR.
# Returns 1 when FILE (or its target) does not exist as a regular file.
_epr_resolve() { # FILE VAR
  local _er_path
  [[ -e $1 ]] || return 1
  _er_path=$(readlink -f -- "$1") || return 1
  [[ -f ${_er_path} ]] || return 1
  printf -v "$2" '%s' "${_er_path}"
}

# The message every protected-conflict refusal uses (names only, never values).
_epr_conflict_message() { # WHERE FROM TO SUFFIX...
  local where=$1 from=$2 to=$3 s msg=''
  shift 3
  for s in "$@"; do
    msg+="${msg:+; }${from}_${s} and ${to}_${s} disagree on this host"
  done
  printf '%s (%s); keep the right one, delete the other, and re-run' "${msg}" "${where}"
}

# The PROTECTED suffixes (ENCRYPTION_KEY / PASSWORD) whose FROM_ and TO_
# entries in the dotenv FILE hold different non-empty values, one per line.
# Prints nothing when there are none or FILE is absent. Never writes.
envfile_prefix_conflicts() { # FILE FROM TO
  local file=$1 from=$2 to=$3 target raw key rc=0 LC_ALL=C
  _epr_require_prefixes envfile_prefix_conflicts "${from}" "${to}"
  _epr_resolve "${file}" target || return 0
  read_file_exact "${target}" raw || die "envfile_prefix_conflicts: could not read ${target}"
  _epr_rename_content "${raw}" "${from}" "${to}" || rc=$?
  [[ ${rc} -eq 2 ]] || return 0
  for key in ${_EPR_PROTECTED[@]+"${_EPR_PROTECTED[@]}"}; do
    printf '%s\n' "${key#"${from}_"}"
  done
}

# Hard-rename the dotenv FILE's FROM_ entries to TO_ in place (the shell twin
# of renameEnvPrefix; see _epr_rename_content for the exact rules). Dies
# before writing anything on a protected conflict. Prints the number of
# renamed lines; 0 — and no write — when FILE is absent or already clean.
envfile_rename_prefix() { # FILE FROM TO
  local file=$1 from=$2 to=$3 target raw rc=0 LC_ALL=C
  _epr_require_prefixes envfile_rename_prefix "${from}" "${to}"
  if ! _epr_resolve "${file}" target; then
    printf '0\n'
    return 0
  fi
  read_file_exact "${target}" raw || die "envfile_rename_prefix: could not read ${target}"
  _epr_rename_content "${raw}" "${from}" "${to}" || rc=$?
  if [[ ${rc} -eq 2 ]]; then
    die "$(_epr_conflict_message "${target}" "${from}" "${to}" "${_EPR_PROTECTED[@]#"${from}_"}")"
  fi
  if ((${#_EPR_CONFLICTS[@]} > 0)); then
    log_warn "${target}: kept the ${to}_ value and dropped the differing ${from}_ line for: ${_EPR_CONFLICTS[*]}"
  fi
  if [[ ${_EPR_RESULT} == "${raw}" ]]; then
    printf '0\n'
    return 0
  fi
  _epr_write_atomic "${target}" "${_EPR_RESULT}" || die "envfile_rename_prefix: ${target} was left unchanged"
  if ((_EPR_RENAMED_LINES > 0)); then
    log_info "${target}: renamed ${_EPR_RENAMED_LINES} line(s) ${from}_ -> ${to}_ (${_EPR_RENAMED[*]})"
  fi
  printf '%s\n' "${_EPR_RENAMED_LINES}"
}

# The .core.env keys of YAML, one per line (none when absent).
_epr_yaml_env_keys() { # YAML
  yq -r '(.core.env // {}) | keys | .[]' "$1" 2>/dev/null
}

# Like envfile_prefix_conflicts, for the host config's .core.env map.
yaml_prefix_conflicts() { # YAML FROM TO
  local yaml=$1 from=$2 to=$3 target keys key suffix fv tv
  _epr_require_prefixes yaml_prefix_conflicts "${from}" "${to}"
  _epr_resolve "${yaml}" target || return 0
  keys=$(_epr_yaml_env_keys "${target}") || die "yaml_prefix_conflicts: could not read .core.env from ${target}"
  while IFS= read -r key; do
    [[ ${key} == "${from}_"?* ]] || continue
    suffix=${key#"${from}_"}
    _epr_protected "${suffix}" || continue
    grep -qxF -- "${to}_${suffix}" <<<"${keys}" || continue
    fv=$(K=${key} yq -r '.core.env[strenv(K)] // ""' "${target}") || die "yaml_prefix_conflicts: could not read ${target}"
    tv=$(K=${to}_${suffix} yq -r '.core.env[strenv(K)] // ""' "${target}") || die "yaml_prefix_conflicts: could not read ${target}"
    [[ -n ${fv} && -n ${tv} && ${fv} != "${tv}" ]] && printf '%s\n' "${suffix}"
  done <<<"${keys}"
  return 0
}

# Rename the host config's .core.env.<FROM>_* keys to <TO>_* (comments and
# order kept), with renameEnvPrefix's conflict rules: a protected conflict
# dies before any write; otherwise a non-empty TO_ key wins and the FROM_ key
# is dropped (logged when the values differ). The edit is made on a copy next
# to the resolved file and renamed over it, so a symlinked yaml stays a link.
yaml_rename_env_prefix() { # YAML FROM TO
  local yaml=$1 from=$2 to=$3 target keys key suffix twin fv tv tmp conflicts dropped=() renamed=0
  _epr_require_prefixes yaml_rename_env_prefix "${from}" "${to}"
  _epr_resolve "${yaml}" target || return 0
  keys=$(_epr_yaml_env_keys "${target}") || die "yaml_rename_env_prefix: could not read .core.env from ${target}"
  grep -q -- "^${from}_." <<<"${keys}" || return 0
  conflicts=$(yaml_prefix_conflicts "${target}" "${from}" "${to}") || die "yaml_rename_env_prefix: could not check ${target} for conflicting settings"
  if [[ -n ${conflicts} ]]; then
    # shellcheck disable=SC2086 # one suffix per line, split on purpose
    die "$(_epr_conflict_message "${target} .core.env" "${from}" "${to}" ${conflicts})"
  fi
  if ! tmp=$(mktemp "$(dirname -- "${target}")/.$(basename -- "${target}").ficus-rename.XXXXXX") || [[ -z ${tmp} ]]; then
    die "yaml_rename_env_prefix: failed to create a staging file next to ${target}"
  fi
  if ! cp -p -- "${target}" "${tmp}"; then
    rm -f -- "${tmp}"
    die "yaml_rename_env_prefix: failed to stage a copy of ${target}"
  fi
  while IFS= read -r key; do
    [[ ${key} == "${from}_"?* ]] || continue
    suffix=${key#"${from}_"}
    twin=${to}_${suffix}
    if grep -qxF -- "${twin}" <<<"${keys}"; then
      if ! fv=$(K=${key} yq -r '.core.env[strenv(K)] // ""' "${tmp}") ||
        ! tv=$(K=${twin} yq -r '.core.env[strenv(K)] // ""' "${tmp}"); then
        rm -f -- "${tmp}"
        die "yaml_rename_env_prefix: could not read ${target}"
      fi
      if [[ -n ${tv} || -z ${fv} ]]; then
        # The TO_ key wins; the FROM_ key goes.
        [[ -n ${fv} && ${fv} != "${tv}" ]] && dropped+=("${key}")
        if ! K=${key} yq -i 'del(.core.env[strenv(K)])' "${tmp}"; then
          rm -f -- "${tmp}"
          die "yaml_rename_env_prefix: failed to edit the staged copy of ${target}"
        fi
        continue
      fi
      # An empty TO_ value counts as unset: it goes, and FROM_ is renamed.
      if ! K=${twin} yq -i 'del(.core.env[strenv(K)])' "${tmp}"; then
        rm -f -- "${tmp}"
        die "yaml_rename_env_prefix: failed to edit the staged copy of ${target}"
      fi
    fi
    if ! K=${key} N=${twin} yq -i '(.core.env[strenv(K)] | key) = strenv(N)' "${tmp}"; then
      rm -f -- "${tmp}"
      die "yaml_rename_env_prefix: failed to edit the staged copy of ${target}"
    fi
    renamed=$((renamed + 1))
  done <<<"${keys}"
  if ! _epr_copy_mode_owner "${target}" "${tmp}" || ! mv -f -- "${tmp}" "${target}"; then
    rm -f -- "${tmp}"
    die "yaml_rename_env_prefix: failed to replace ${target} — it was left unchanged"
  fi
  ((${#dropped[@]} == 0)) || log_warn "${target}: kept the ${to}_ value and dropped the differing ${from}_ key for: ${dropped[*]}"
  log_info "${target}: renamed ${renamed} .core.env key(s) ${from}_ -> ${to}_"
}

# Rename the Environment=<FROM>_… (and Environment="<FROM>_…") assignments of
# a systemd unit or drop-in to <TO>_, nothing else. Same atomic write.
# Prints the number of renamed lines.
# The unit-file rename over CONTENT: sets _EPR_RESULT and _EPR_RENAMED_LINES.
_epr_unit_rename_content() { # RAW FROM TO
  local raw=$1 from=$2 to=$3 line out='' sep='' re
  _EPR_RENAMED_LINES=0
  re="^Environment=(\"?)${from}_"
  _epr_split_lines "${raw}"
  for line in "${_EPR_LINES[@]}"; do
    if [[ ${line} =~ ${re} ]]; then
      line="Environment=${BASH_REMATCH[1]}${to}_${line#"Environment=${BASH_REMATCH[1]}${from}_"}"
      _EPR_RENAMED_LINES=$((_EPR_RENAMED_LINES + 1))
    fi
    out+="${sep}${line}"
    sep=$'\n'
  done
  _EPR_RESULT=${out}
}

unitfile_rename_env_prefix() { # FILE FROM TO
  local file=$1 from=$2 to=$3 target raw count LC_ALL=C
  _epr_require_prefixes unitfile_rename_env_prefix "${from}" "${to}"
  if ! _epr_resolve "${file}" target; then
    printf '0\n'
    return 0
  fi
  read_file_exact "${target}" raw || die "unitfile_rename_env_prefix: could not read ${target}"
  _epr_unit_rename_content "${raw}" "${from}" "${to}"
  count=${_EPR_RENAMED_LINES}
  if ((count > 0)); then
    _epr_write_atomic "${target}" "${_EPR_RESULT}" || die "unitfile_rename_env_prefix: ${target} was left unchanged"
    log_info "${target}: renamed ${count} Environment= line(s) ${from}_ -> ${to}_"
  fi
  printf '%s\n' "${count}"
}

# Read <P>_SUFFIX from the dotenv FILE into the variable named VAR, preferring
# FICUS_<SUFFIX> and falling back to the TAU_ spelling. The file is parsed the
# way the rename parses it (_epr_parse_entries: `KEY=` / `export KEY=`,
# indentation, CRLF, multi-line quoted values; the last assignment wins), and
# a value is judged by what a dotenv reader sees — trimmed, one level of
# quotes removed (_epr_normalize). FICUS_ wins only when that value is
# non-empty (`FICUS_X=""` or `FICUS_X= ` next to a real TAU_X reads the TAU_
# one); VAR receives that normalized value. Returns 1 when neither name is
# present. For a PROTECTED suffix whose two names hold different non-empty
# values it DIES, naming the keys only — so call it in the current shell (not
# inside `$(...)`), where that die ends the run instead of reading as
# "absent".
#
# PERMANENT: backup archives and hand-kept env files outlive the rename, so
# this fallback is what keeps a pre-rename encryption key from ever being
# replaced by a freshly generated key. Never remove the TAU_ fallback.
envfile_read_prefixed() { # VAR FILE SUFFIX
  local _erp_var=$1 _erp_file=$2 _erp_suffix=$3 _erp_raw _erp_k _erp_n
  local _erp_nf='' _erp_nt='' _erp_has_ficus=0 _erp_has_tau=0 LC_ALL=C
  [[ -f ${_erp_file} ]] || return 1
  read_file_exact "${_erp_file}" _erp_raw || die "could not read ${_erp_file}"
  _epr_split_lines "${_erp_raw}"
  _epr_parse_entries
  _erp_n=${#_E_KEY[@]}
  for ((_erp_k = 0; _erp_k < _erp_n; _erp_k++)); do
    if [[ ${_E_KEY[_erp_k]} == "FICUS_${_erp_suffix}" ]]; then
      _epr_normalize "${_E_VALUE[_erp_k]}"
      _erp_nf=${_EPR_OUT}
      _erp_has_ficus=1
    elif [[ ${_E_KEY[_erp_k]} == "TAU_${_erp_suffix}" ]]; then
      _epr_normalize "${_E_VALUE[_erp_k]}"
      _erp_nt=${_EPR_OUT}
      _erp_has_tau=1
    fi
  done
  if ((_erp_has_ficus && _erp_has_tau)) && _epr_protected "${_erp_suffix}" &&
    [[ -n ${_erp_nf} && -n ${_erp_nt} && ${_erp_nf} != "${_erp_nt}" ]]; then
    die "$(_epr_conflict_message "${_erp_file}" TAU FICUS "${_erp_suffix}")"
  fi
  if ((_erp_has_ficus)) && [[ -n ${_erp_nf} ]]; then
    printf -v "${_erp_var}" '%s' "${_erp_nf}"
  elif ((_erp_has_tau)); then
    printf -v "${_erp_var}" '%s' "${_erp_nt}"
  elif ((_erp_has_ficus)); then
    printf -v "${_erp_var}" '%s' ''
  else
    return 1
  fi
}

# Print the value envfile_read_prefixed reads (see there), or return 1.
envfile_get_prefixed() { # FILE SUFFIX
  local _egp_value
  envfile_read_prefixed _egp_value "$1" "$2" || return 1
  printf '%s' "${_egp_value}"
}

# The env prefix the host's settings use: FICUS or TAU by its encryption key,
# else by any prefixed line, else NONE. The same rule as the control plane's
# ENV_PREFIX_PROBE (keep the two in step).
host_env_prefix() { # ENV_FILE
  local file=$1 p
  for p in FICUS TAU; do
    if grep -q "^${p}_ENCRYPTION_KEY=" "${file}" 2>/dev/null; then
      printf '%s\n' "${p}"
      return 0
    fi
  done
  for p in FICUS TAU; do
    if grep -q "^${p}_" "${file}" 2>/dev/null; then
      printf '%s\n' "${p}"
      return 0
    fi
  done
  printf 'NONE\n'
}

# The env prefix a Core release TREE reads (N-C2): artifact.json's
# .envPrefix when the tree has one (every release from the Ficus rename on),
# else its root package.json name — `ficus` reads FICUS_, `tau` reads TAU_
# (a git checkout, or an artifact that predates the field). Anything else
# dies: a wrong guess here renames a live host's settings the wrong way.
core_release_env_prefix() { # TREE
  local tree=$1 p name
  have jq || die "core_release_env_prefix: jq is required"
  [[ -d ${tree} ]] || die "core_release_env_prefix: '${tree}' is not a directory"
  if [[ -f ${tree}/artifact.json ]]; then
    p=$(jq -r '.envPrefix // empty' "${tree}/artifact.json" 2>/dev/null) ||
      die "core_release_env_prefix: could not read ${tree}/artifact.json"
    if [[ -n ${p} ]]; then
      _epr_is_prefix "${p}" || die "core_release_env_prefix: ${tree}/artifact.json has an unknown envPrefix '${p}'"
      printf '%s\n' "${p}"
      return 0
    fi
  fi
  [[ -f ${tree}/package.json ]] ||
    die "core_release_env_prefix: ${tree} has neither an artifact.json envPrefix nor a package.json"
  name=$(jq -r '.name // empty' "${tree}/package.json" 2>/dev/null) ||
    die "core_release_env_prefix: could not read ${tree}/package.json"
  case "${name}" in
    ficus) printf 'FICUS\n' ;;
    tau) printf 'TAU\n' ;;
    *) die "core_release_env_prefix: ${tree}/package.json is named '${name}', not ficus or tau — cannot tell which env prefix it reads" ;;
  esac
}

# The env prefix the git revision REV of the checkout at DEST reads, from its
# root package.json as committed — read with `git show`, so it can be asked
# before the checkout moves (N-C2). Dies when it cannot be told.
git_rev_env_prefix() { # DEST REV
  local json name
  json=$(git -C "$1" show "$2:package.json" 2>/dev/null) ||
    die "could not read package.json at revision $2 of $1"
  name=$(jq -r '.name // empty' <<<"${json}" 2>/dev/null) ||
    die "package.json at revision $2 of $1 is not valid JSON"
  case "${name}" in
    ficus) printf 'FICUS\n' ;;
    tau) printf 'TAU\n' ;;
    *) die "package.json at revision $2 of $1 is named '${name}', not ficus or tau — cannot tell which env prefix it reads" ;;
  esac
}

# The release tree the services run from: what <dest>/current resolves to
# on the artifact layout, <dest> itself for a git checkout.
active_release_tree() {
  if [[ -e ${SRC_DEST}/current || -L ${SRC_DEST}/current ]]; then
    readlink -f -- "${SRC_DEST}/current" || return 1
  else
    printf '%s\n' "${SRC_DEST}"
  fi
}

# The env-bearing files of this host that exist, each resolved through
# symlinks, one per line, deduplicated. --no-units leaves out the core units
# and their drop-ins (a git->artifact conversion in the same run re-renders
# them; see env_rename_backup_restore).
# Every path host_env_files considers, unresolved and unfiltered (an
# unmatched drop-in glob stays literal): one per line.
_host_env_candidates() { # [--no-units]
  local f
  printf '%s\n' "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}" "${BACKUP_ENV_TARGET}" "${CFG_FILE:-}"
  if [[ ${1:-} != --no-units ]]; then
    printf '%s\n' "${FICUS_SYSTEMD_UNIT_DIR}"/tau-{api,worker}.service # phase5-unit-name
    for f in "${FICUS_SYSTEMD_UNIT_DIR}"/tau-{api,worker}.service.d/*.conf; do # phase5-unit-name
      printf '%s\n' "${f}"
    done
  fi
  printf '%s\n' "${BACKUP_SCRIPT_PATH}"
}

host_env_files() { # [--no-units]
  local f resolved seen=$'\n' listing
  listing=$(_host_env_candidates "$@") || return 1
  while IFS= read -r f; do
    [[ -n ${f} ]] || continue
    _epr_resolve "${f}" resolved || continue
    [[ ${seen} == *$'\n'"${resolved}"$'\n'* ]] && continue
    seen+="${resolved}"$'\n'
    printf '%s\n' "${resolved}"
  done <<<"${listing}"
}

# Flush FILE's filesystem to disk (GNU `sync -f`; plain `sync` elsewhere).
_epr_sync() { # FILE
  if sync --version >/dev/null 2>&1; then
    sync -f -- "$1"
  else
    sync
  fi
}

_epr_sha256() { # FILE -> hex on stdout
  local out
  out=$(sha256sum -- "$1" 2>/dev/null) || out=$(shasum -a 256 -- "$1" 2>/dev/null) || return 1
  printf '%s' "${out%% *}"
}

# Create a backup set of FILE... (resolved paths) and journal it. Prints the
# set dir. Dies — having removed the partial set and never having written
# PENDING — on any failure, so nothing is ever renamed without a verified,
# journaled copy of what it replaces.
env_rename_backup_create() { # TARGET RELEASE_DIR FILE...
  local target=$1 release=$2 root setdir ts f idx=0 sha manifest='' tmp
  shift 2
  root=$(env_rename_backup_root)
  _epr_is_prefix "${target}" || die "env_rename_backup_create: target must be TAU or FICUS"
  if [[ -e ${root}/PENDING ]]; then
    die "env_rename_backup_create: ${root}/PENDING already journals a rename — reconcile it first"
  fi
  if ! mkdir -p -- "${root}" || ! chmod 0700 "${root}"; then
    die "env_rename_backup_create: could not create ${root} (root 0700)"
  fi
  ts=$(date -u '+%Y%m%dT%H%M%SZ') || die "env_rename_backup_create: could not read the clock"
  if ! setdir=$(umask 077 && mktemp -d "${root}/${ts}-XXXXXX") || [[ -z ${setdir} ]]; then
    die "env_rename_backup_create: could not create a backup set under ${root}"
  fi
  _epr_backup_fail() {
    rm -rf -- "${setdir}"
    die "env_rename_backup_create: $* — nothing was renamed"
  }
  chmod 0700 "${setdir}" || _epr_backup_fail "could not chmod ${setdir}"
  for f in "$@"; do
    idx=$((idx + 1))
    _epr_resolve "${f}" f || _epr_backup_fail "'${f}' is not an existing file"
    cp -p -- "${f}" "${setdir}/${idx}" || _epr_backup_fail "could not copy ${f}"
    cmp -s -- "${f}" "${setdir}/${idx}" || _epr_backup_fail "the copy of ${f} does not match it"
    sha=$(_epr_sha256 "${setdir}/${idx}") && [[ ${sha} =~ ^[0-9a-f]{64}$ ]] ||
      _epr_backup_fail "could not hash the copy of ${f}"
    manifest+="${idx}"$'\t'"${sha}"$'\t'"${f}"$'\n'
  done
  printf '%s' "${manifest}" >"${setdir}/MANIFEST" || _epr_backup_fail "could not write the MANIFEST"
  if [[ ${ARTIFACT_CONVERTED_THIS_RUN:-0} -eq 1 ]]; then
    : >"${setdir}/UNITS_EXCLUDED" || _epr_backup_fail "could not write the UNITS_EXCLUDED marker"
  fi
  # The journal, last: written to a temp file, flushed, then renamed into
  # place — so PENDING exists only once the whole set is durably on disk.
  tmp="${root}/.PENDING.tmp.$$"
  printf '%s\t%s\t%s\n' "${setdir}" "${target}" "${release}" >"${tmp}" ||
    { rm -f -- "${tmp}"; _epr_backup_fail "could not write the journal"; }
  _epr_sync "${tmp}" || { rm -f -- "${tmp}"; _epr_backup_fail "could not flush the backup set to disk"; }
  mv -f -- "${tmp}" "${root}/PENDING" || { rm -f -- "${tmp}"; _epr_backup_fail "could not install the journal"; }
  if ! _epr_sync "${root}/PENDING"; then
    rm -f -- "${root}/PENDING"
    _epr_backup_fail "could not flush the journal to disk"
  fi
  unset -f _epr_backup_fail
  log_info "env backup set ${setdir}: ${idx} file(s), plaintext secrets included (root 0700)"
  printf '%s\n' "${setdir}"
}

# The first field of PENDING (the journaled set), or nothing.
_epr_pending_set() {
  local root line
  root=$(env_rename_backup_root)
  [[ -f ${root}/PENDING ]] || return 0
  read_file_exact "${root}/PENDING" line || return 1
  printf '%s' "${line%%$'\t'*}"
}

# Put a backup set back, byte for byte, and verify every file's sha256.
# Returns 0 after a verified restore (removing PENDING when it journals this
# set, then daemon-reloading), 1 on any failure (log_error; what was not yet
# restored is untouched and PENDING is kept), and 3 — having changed nothing,
# PENDING kept — when the set excluded the units and the unit templates are
# not next to this script (apply-artifacts.sh). Never exits: the rollback
# hook calls it and must still reach the rollback restart.
env_rename_backup_restore() { # SETDIR
  local setdir=$1 raw rest line idx sha path dir tmp got n=0 pending
  local re=$'^([0-9]+)\t([0-9a-f]{64})\t(/.+)$'
  local -a idxs=() shas=() paths=()
  if [[ ! -d ${setdir} || ! -f ${setdir}/MANIFEST ]]; then
    log_error "env restore: ${setdir} is not a backup set (no MANIFEST)"
    return 1
  fi
  read_file_exact "${setdir}/MANIFEST" raw || return 1
  rest=${raw}
  while [[ -n ${rest} ]]; do
    line=${rest%%$'\n'*}
    if [[ ${line} == "${rest}" ]]; then rest=''; else rest=${rest#*$'\n'}; fi
    [[ -n ${line} ]] || continue
    if [[ ! ${line} =~ ${re} ]]; then
      log_error "env restore: ${setdir}/MANIFEST has a malformed line — nothing was restored"
      return 1
    fi
    idxs+=("${BASH_REMATCH[1]}")
    shas+=("${BASH_REMATCH[2]}")
    paths+=("${BASH_REMATCH[3]}")
  done
  # Every copy must still be what was backed up before ANYTHING is touched.
  for ((n = 0; n < ${#idxs[@]}; n++)); do
    got=$(_epr_sha256 "${setdir}/${idxs[n]}") || got=''
    if [[ ${got} != "${shas[n]}" ]]; then
      log_error "env restore: the backup copy of ${paths[n]} in ${setdir} does not match its MANIFEST sha256 — nothing was restored"
      return 1
    fi
  done
  if [[ -e ${setdir}/UNITS_EXCLUDED ]] && ! _epr_have_unit_templates; then
    log_warn "env restore: ${setdir} excluded the units (a git->artifact conversion ran in the same upgrade) and the unit templates are not next to this script — leaving it journaled for the next upgrade"
    return 3
  fi
  for ((n = 0; n < ${#idxs[@]}; n++)); do
    idx=${idxs[n]} sha=${shas[n]} path=${paths[n]}
    dir=$(dirname -- "${path}") || return 1
    if [[ ! -d ${dir} ]]; then
      log_error "env restore: ${dir} no longer exists — cannot restore ${path}"
      return 1
    fi
    if ! tmp=$(mktemp "${dir}/.$(basename -- "${path}").ficus-restore.XXXXXX") || [[ -z ${tmp} ]]; then
      log_error "env restore: could not stage ${path}"
      return 1
    fi
    if ! cp -p -- "${setdir}/${idx}" "${tmp}"; then
      rm -f -- "${tmp}"
      log_error "env restore: could not stage ${path}"
      return 1
    fi
    got=$(_epr_sha256 "${tmp}") || got=''
    if [[ ${got} != "${sha}" ]]; then
      rm -f -- "${tmp}"
      log_error "env restore: the staged copy of ${path} does not match its sha256"
      return 1
    fi
    if ! mv -f -- "${tmp}" "${path}"; then
      rm -f -- "${tmp}"
      log_error "env restore: could not put ${path} back"
      return 1
    fi
    got=$(_epr_sha256 "${path}") || got=''
    if [[ ${got} != "${sha}" ]]; then
      log_error "env restore: ${path} does not match its sha256 after the restore"
      return 1
    fi
  done
  if [[ -e ${setdir}/UNITS_EXCLUDED ]]; then
    # The pre-conversion units are never copied back: they point at the git
    # checkout that no longer exists. Render the CURRENT layout's units in
    # the spelling the pre-rename release reads (N-I3). A subshell, so a die
    # in the render is contained to this restore.
    if ! (
      install_core_units "${SCRIPT_DIR}/systemd" TAU
      ensure_tau_api_memory_guardrail
    ); then
      log_error "env restore: files restored, but re-rendering the units for the pre-rename release failed"
      return 1
    fi
  fi
  pending=$(_epr_pending_set) || pending=''
  if [[ -n ${pending} && $(readlink -f -- "${pending}" 2>/dev/null) == "$(readlink -f -- "${setdir}" 2>/dev/null)" ]]; then
    if ! rm -f -- "$(env_rename_backup_root)/PENDING"; then
      log_error "env restore: files restored, but the journal could not be removed"
      return 1
    fi
  fi
  as_root systemctl daemon-reload || log_warn "env restore: systemctl daemon-reload failed"
  log_info "env restore: ${#idxs[@]} file(s) restored byte for byte from ${setdir}"
}

# Are both core unit templates next to this toolkit copy?
_epr_have_unit_templates() {
  local t
  for t in "${SCRIPT_DIR}/systemd"/tau-{api,worker}.service.tmpl; do # phase5-unit-name
    [[ -f ${t} ]] || return 1
  done
}

# Keep the newest five backup sets; never remove the one PENDING journals.
env_rename_backup_prune() {
  local root pending d name
  local -a sets=()
  root=$(env_rename_backup_root)
  [[ -d ${root} ]] || return 0
  pending=$(_epr_pending_set) || return 1
  for d in "${root}"/*; do
    name=${d##*/}
    [[ -d ${d} && ${name} =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$ ]] && sets+=("${d}")
  done
  ((${#sets[@]} > 5)) || return 0
  for d in "${sets[@]:0:${#sets[@]}-5}"; do
    [[ ${d} == "${pending}" ]] && continue
    rm -rf -- "${d}" || return 1
    log_info "pruned env backup set ${d}"
  done
}

# Does FILE have a line that step 8 below would rename? $2 is the kind.
_epr_needs_rename() { # FILE dotenv|yaml|unit|backup_script
  local rc=0 from=TAU keys raw rrc=0 LC_ALL=C
  case "$2" in
    dotenv | unit)
      # Exactly what the rename would do: a TAU_ line inside a multi-line
      # value (a PEM block) is value text, and must not make a set every run.
      read_file_exact "$1" raw || die "could not read $1"
      if [[ $2 == dotenv ]]; then
        _epr_rename_content "${raw}" "${from}" FICUS || rrc=$?
        # A protected conflict (2) is a change the rename would stop on.
        [[ ${rrc} -eq 2 ]] && return 0
      else
        _epr_unit_rename_content "${raw}" "${from}" FICUS
      fi
      [[ ${_EPR_RESULT} != "${raw}" ]]
      return
      ;;
    yaml)
      keys=$(_epr_yaml_env_keys "$1") || die "could not read .core.env from $1"
      grep -q "^${from}_." <<<"${keys}" || rc=$?
      ;;
    backup_script) grep -qF "${from}_BACKUP_" -- "$1" || rc=$? ;;
  esac
  ((rc <= 1)) || die "could not read $1"
  return "${rc}"
}

# Step 8 of migrate_env_prefix_host: rename every env-bearing file (each a
# no-op when already clean). Shared with env_prefix_reconcile.
_env_prefix_rename_files() { # [--no-units]
  local f
  for f in "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}" "${BACKUP_ENV_TARGET}"; do
    envfile_rename_prefix "${f}" TAU FICUS >/dev/null || die "renaming ${f} failed"
  done
  if [[ -n ${CFG_FILE:-} ]]; then
    yaml_rename_env_prefix "${CFG_FILE}" TAU FICUS
  fi
  if [[ ${1:-} != --no-units ]]; then
    for f in "${FICUS_SYSTEMD_UNIT_DIR}"/tau-{api,worker}.service "${FICUS_SYSTEMD_UNIT_DIR}"/tau-{api,worker}.service.d/*.conf; do # phase5-unit-name
      [[ -e ${f} ]] || continue
      unitfile_rename_env_prefix "${f}" TAU FICUS >/dev/null || die "renaming ${f} failed"
    done
  fi
  if [[ -f ${BACKUP_SCRIPT_PATH} ]] && _epr_needs_rename "${BACKUP_SCRIPT_PATH}" backup_script; then
    backup_script_rerender "${SCRIPT_DIR}/tau-backup.sh.tmpl"
  fi
}

# Hard-rename this host's settings to the TARGET prefix, with a journaled
# backup set (see the section header). TAU as the target renames nothing and
# refuses a host whose settings are already FICUS_. Leaves ENV_RENAME_PENDING=1
# after renaming: the caller commits (env_prefix_commit) once the release that
# reads the new names is serving; otherwise the traps settle it by the active
# release (env_prefix_settle_pending). Root-only: a non-root run refuses when a
# rename is needed (require_env_rename_privilege) and proceeds otherwise.
migrate_env_prefix_host() { # TARGET [RELEASE_DIR]
  local target=$1 release=${2:-} root current listing f kind c conflicts='' need=0 no_units=''
  local -a files=()
  _epr_is_prefix "${target}" || die "migrate_env_prefix_host: target must be TAU or FICUS (got '${target}')"
  root=$(env_rename_backup_root)
  if [[ -e ${root}/PENDING ]]; then
    local rc=0
    env_prefix_reconcile || rc=$?
    [[ ${rc} -eq 0 ]] || die "a pending env rename (${root}/PENDING) could not be reconciled (rc ${rc}) — nothing new was renamed"
  fi
  current=$(host_env_prefix "${SRC_DEST}/.env")
  if [[ ${target} == TAU && ${current} == FICUS ]]; then
    die "target Core predates the Ficus rename but this host's settings are FICUS_*; re-run with --restore-env-backup <set> (see ${root}) or choose a Ficus release"
  fi
  if [[ ${target} == TAU ]]; then
    return 0
  fi
  if ! _epr_is_root; then
    require_env_rename_privilege FICUS
    log_info "env prefix: every host env file is readable and none needs renaming (non-root run)"
    return 0
  fi
  [[ ${ARTIFACT_CONVERTED_THIS_RUN:-0} -eq 1 ]] && no_units=--no-units
  # shellcheck disable=SC2086 # an empty ${no_units} must vanish, not pass ''
  listing=$(host_env_files ${no_units}) || die "could not list this host's env files"
  while IFS= read -r f; do
    [[ -n ${f} ]] && files+=("${f}")
  done <<<"${listing}"

  # Ruling 24: a protected conflict anywhere stops the run before any write.
  # (${c} is one suffix per line, split into arguments on purpose.)
  # shellcheck disable=SC2086
  for f in "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}" "${BACKUP_ENV_TARGET}"; do
    c=$(envfile_prefix_conflicts "${f}" TAU FICUS) || die "could not check ${f} for conflicting settings"
    [[ -z ${c} ]] || conflicts+="${conflicts:+; }$(_epr_conflict_message "${f}" TAU FICUS ${c})"
  done
  if [[ -n ${CFG_FILE:-} ]]; then
    c=$(yaml_prefix_conflicts "${CFG_FILE}" TAU FICUS) || die "could not check ${CFG_FILE} for conflicting settings"
    # shellcheck disable=SC2086 # one suffix per line, split on purpose
    [[ -z ${c} ]] || conflicts+="${conflicts:+; }$(_epr_conflict_message "${CFG_FILE} .core.env" TAU FICUS ${c})"
  fi
  [[ -z ${conflicts} ]] || die "refusing to rename this host's settings: ${conflicts}"

  # Per file: will anything change? (No ".env is already FICUS" shortcut —
  # a half-renamed host is finished file by file.)
  for f in ${files[@]+"${files[@]}"}; do
    kind=dotenv
    [[ ${f} == "$(readlink -f -- "${CFG_FILE:-/nonexistent}" 2>/dev/null)" ]] && kind=yaml
    [[ ${f} == *.service || ${f} == *.conf ]] && kind=unit
    [[ ${f} == "$(readlink -f -- "${BACKUP_SCRIPT_PATH}" 2>/dev/null)" ]] && kind=backup_script
    if _epr_needs_rename "${f}" "${kind}"; then
      need=1
      break
    fi
  done
  if ((need == 0)); then
    log_info "env prefix already FICUS (all files)"
    return 0
  fi

  ENV_RENAME_BACKUP_SET=$(env_rename_backup_create FICUS "${release}" "${files[@]}") && [[ -n ${ENV_RENAME_BACKUP_SET} ]] ||
    die "could not create the env backup set — nothing was renamed"
  ENV_RENAME_BACKUP_SET=${ENV_RENAME_BACKUP_SET%$'\n'}
  ENV_RENAME_PENDING=1
  log_info "renaming this host's TAU_* settings to FICUS_* (backup set ${ENV_RENAME_BACKUP_SET}; if this run fails, it is restored before the flip or finished forward after it)"
  # shellcheck disable=SC2086 # an empty ${no_units} must vanish, not pass ''
  _env_prefix_rename_files ${no_units}
  _epr_sync_files "${files[@]}" || die "could not flush the renamed env files to disk"
  as_root systemctl daemon-reload || die "systemctl daemon-reload failed after the env rename"
}

# The pre-flip hook (ARTIFACT_PREFLIP_HOOK): rename to the prefix RELEASE_DIR
# reads, then render the units that release reads, right before the flip.
migrate_env_prefix_host_for() { # RELEASE_DIR
  local release=$1 t
  t=$(core_release_env_prefix "${release}") || die "could not tell which env prefix ${release} reads"
  migrate_env_prefix_host "${t}" "${release}"
  install_core_units "${SCRIPT_DIR}/systemd" "${t}"
  ensure_tau_api_memory_guardrail
}

# Flush the filesystem of each FILE (each touched filesystem once).
_epr_sync_files() { # FILE...
  local f seen=$'\n' d
  for f in "$@"; do
    d=$(dirname -- "${f}") || return 1
    [[ ${seen} == *$'\n'"${d}"$'\n'* ]] && continue
    seen+="${d}"$'\n'
    _epr_sync "${f}" || return 1
  done
}

# Remove the staging files an interrupted rename or restore left next to each
# file of SETDIR's MANIFEST (.<name>.ficus-rename.* / .<name>.ficus-restore.*).
_epr_clean_staging() { # SETDIR
  local idx _sha path dir base f
  [[ -f $1/MANIFEST ]] || return 0
  while IFS=$'\t' read -r idx _sha path; do
    [[ -n ${path} ]] || continue
    dir=$(dirname -- "${path}") && base=$(basename -- "${path}") || continue
    for f in "${dir}/.${base}.ficus-rename."* "${dir}/.${base}.ficus-restore."*; do
      [[ -e ${f} ]] || continue
      if rm -f -- "${f}"; then
        log_info "removed ${f}, a staging file an interrupted run left behind"
      fi
    done
  done <"$1/MANIFEST" || return 0
}

# The env prefix the ACTIVE release reads, into _EPR_ACTIVE (and its tree into
# _EPR_ACTIVE_TREE). Returns 1 when it cannot be told.
_epr_active_prefix() {
  _EPR_ACTIVE='' _EPR_ACTIVE_TREE=''
  _EPR_ACTIVE_TREE=$(active_release_tree) || return 1
  _EPR_ACTIVE=$(core_release_env_prefix "${_EPR_ACTIVE_TREE}") || return 1
  _epr_is_prefix "${_EPR_ACTIVE}"
}

# Finish SETDIR's rename forward — the active release reads FICUS_ — and
# commit. Contained: on any failure it returns 1 with the journal kept, so the
# next toolkit run's reconcile finishes the job.
_env_prefix_finish_forward() { # SETDIR
  local setdir=$1 no_units='' listing f
  local -a files=()
  _epr_clean_staging "${setdir}"
  [[ -e ${setdir}/UNITS_EXCLUDED ]] && no_units=--no-units
  # shellcheck disable=SC2086 # an empty ${no_units} must vanish, not pass ''
  if ! (
    _env_prefix_rename_files ${no_units} || exit 1
    listing=$(host_env_files ${no_units}) || exit 1
    while IFS= read -r f; do
      [[ -n ${f} ]] && files+=("${f}")
    done <<<"${listing}"
    _epr_sync_files ${files[@]+"${files[@]}"} || exit 1
    as_root systemctl daemon-reload || exit 1
  ); then
    return 1
  fi
  ENV_RENAME_BACKUP_SET=${setdir}
  env_prefix_commit
}

# Make a journaled rename match the ACTIVE release (N-C1): restore the set
# when the release that is serving reads TAU_, finish the rename file by file
# and commit when it reads FICUS_. No journal: nothing to do. Returns 3 (the
# journal kept) when this toolkit copy cannot finish the job here — the units
# or tau-backup.sh template are not next to it.
env_prefix_reconcile() {
  local root raw line setdir target release rc=0
  root=$(env_rename_backup_root)
  if ! _epr_is_root; then
    if [[ -e ${root}/PENDING ]]; then
      die "an interrupted upgrade left an env rename journaled in ${root}/PENDING, and reconciling it is root-only (it restores or finishes root-owned env files) — re-run this as root"
    fi
    if [[ -d ${root} && ! -x ${root} ]]; then
      log_warn "cannot look for a journaled env rename in ${root} as a non-root user; if an upgrade was interrupted, re-run this as root"
    fi
    return 0
  fi
  [[ -e ${root}/PENDING ]] || return 0
  read_file_exact "${root}/PENDING" raw || die "could not read ${root}/PENDING"
  line=${raw%%$'\n'*}
  setdir=${line%%$'\t'*}
  line=${line#*$'\t'}
  target=${line%%$'\t'*}
  release=${line#*$'\t'}
  if [[ ${setdir} != "${root}/"* || ! -f ${setdir}/MANIFEST ]]; then
    die "${root}/PENDING names '${setdir}', which is not a backup set under ${root} — inspect it by hand before re-running"
  fi
  _epr_active_prefix || die "could not tell which env prefix the active release (${_EPR_ACTIVE_TREE:-under ${SRC_DEST}}) reads"
  log_warn "found a journaled env rename (set ${setdir}, target ${target}, release ${release:-<none>}) from an interrupted run; the active release ${_EPR_ACTIVE_TREE} reads ${_EPR_ACTIVE}_*"
  if [[ ${_EPR_ACTIVE} == TAU ]]; then
    env_rename_backup_restore "${setdir}" || rc=$?
    case ${rc} in
      0)
        _epr_clean_staging "${setdir}"
        log_info "reconcile: restored ${setdir} (the active release reads TAU_*)"
        ;;
      3) return 3 ;;
      *) die "reconcile: restoring ${setdir} failed — the journal is kept; inspect ${setdir}/MANIFEST before re-running" ;;
    esac
    return 0
  fi
  if [[ -f ${BACKUP_SCRIPT_PATH} ]] && _epr_needs_rename "${BACKUP_SCRIPT_PATH}" backup_script &&
    [[ ! -f ${SCRIPT_DIR}/tau-backup.sh.tmpl ]]; then
    log_warn "reconcile: ${BACKUP_SCRIPT_PATH} still reads the pre-rename backup settings and tau-backup.sh.tmpl is not next to this script — leaving the rename journaled for the next upgrade"
    return 3
  fi
  _env_prefix_finish_forward "${setdir}" ||
    die "reconcile: finishing the rename journaled in ${setdir} failed — the journal is kept; re-run"
  log_info "reconcile: finished the rename journaled in ${setdir} (the active release reads FICUS_*)"
}

# Settle THIS run's pending rename after a failure or a signal (Ruling 29): the
# env files must end up matching the ACTIVE release. When the release serving
# now reads TAU_ (the flip never happened, or was rolled back), the set is
# restored; when it reads FICUS_ (the failure came after the flip, or there
# was nothing to roll back to), the rename is finished forward and committed.
# When that cannot be told, or either step fails, the journal is kept and the
# next toolkit run's reconcile settles it. Runs once (the flag is cleared
# first): the TERM trap runs it, and then the EXIT trap does again.
env_prefix_settle_pending() {
  local rc=0
  [[ ${ENV_RENAME_PENDING:-0} -eq 1 ]] || return 0
  ENV_RENAME_PENDING=0
  if ! _epr_active_prefix; then
    log_error "cannot tell which env prefix the active release reads — $(env_rename_backup_root)/PENDING is kept, and the next toolkit run reconciles it"
    return 1
  fi
  if [[ ${_EPR_ACTIVE} == TAU ]]; then
    log_warn "restoring this host's env files from ${ENV_RENAME_BACKUP_SET} (the run that renamed them did not complete, and the active release reads TAU_*)"
    env_rename_backup_restore "${ENV_RENAME_BACKUP_SET}" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
      log_error "the env restore from ${ENV_RENAME_BACKUP_SET} did not complete (rc ${rc}) — $(env_rename_backup_root)/PENDING is kept, and the next toolkit run reconciles it"
    fi
    return "${rc}"
  fi
  log_warn "the active release ${_EPR_ACTIVE_TREE} reads FICUS_*: keeping this host's renamed env files and committing the rename (set ${ENV_RENAME_BACKUP_SET})"
  if ! _env_prefix_finish_forward "${ENV_RENAME_BACKUP_SET}"; then
    log_error "finishing the env rename forward did not complete — $(env_rename_backup_root)/PENDING is kept, and the next toolkit run reconciles it"
    return 1
  fi
}

# artifact_activate's rollback hook: it runs after the symlinks are swapped
# back, so the active release is the old one again and this restores.
env_prefix_restore_pending() {
  env_prefix_settle_pending
}

# The EXIT/TERM/HUP/INT trap body: settle on any failed or signalled exit.
# Idempotent — a TERM trap runs it, and then the EXIT trap does again.
env_prefix_on_exit() { # RC
  [[ ${1:-0} -ne 0 ]] || return 0
  env_prefix_settle_pending || true
}

# The renamed files are now what the serving release reads: forget the
# journal and prune old sets.
env_prefix_commit() {
  local root pending
  ENV_RENAME_PENDING=0
  root=$(env_rename_backup_root)
  pending=$(_epr_pending_set) || pending=''
  if [[ -n ${pending} && (-z ${ENV_RENAME_BACKUP_SET} || ${pending} == "${ENV_RENAME_BACKUP_SET}") ]]; then
    rm -f -- "${root}/PENDING" || log_warn "could not remove ${root}/PENDING — the next toolkit run will reconcile it (a no-op)"
  fi
  env_rename_backup_prune || log_warn "could not prune old env backup sets under ${root}"
}

# The one EXIT trap body for the toolkit's entrypoints: the artifact pubkey
# temp file, the git askpass helper, then the env restore on a failed exit.
toolkit_exit_trap() { # RC
  local rc=${1:-0}
  if [[ -n ${ARTIFACT_PUBKEY_FILE:-} ]]; then rm -f -- "${ARTIFACT_PUBKEY_FILE}"; fi
  cleanup_git_askpass
  env_prefix_on_exit "${rc}"
}

# Install the traps (N-C1). Bash runs an EXIT trap with $?=0 when a signal
# ends the script, so the signals get their own traps with the conventional
# 128+N status, which the EXIT trap then sees too (a no-op the second time).
env_prefix_install_traps() {
  TOOLKIT_EXIT_TRAP_INSTALLED=1
  # A dropped SSH session closes the pipes the log lines go to. Without this
  # the next write kills the script with an untrapped SIGPIPE — before any
  # trap could settle a pending rename. Ignored, the write just fails (the
  # log_* helpers tolerate that) and the run ends through its own checks.
  trap '' PIPE
  trap 'toolkit_exit_trap $?' EXIT
  trap 'env_prefix_on_exit 143; exit 143' TERM
  trap 'env_prefix_on_exit 129; exit 129' HUP
  trap 'env_prefix_on_exit 130; exit 130' INT
}

# Serialize the toolkit runs that can rename, restore or reconcile a host's
# env files: an exclusive flock on ${ENV_RENAME_BACKUP_ROOT}/.lock, held on
# fd 9 until this process (and its children) exit. Waits up to
# ENV_RENAME_LOCK_WAIT seconds (default 900) for another run, then dies.
env_prefix_lock() {
  local root
  root=$(env_rename_backup_root)
  if ! _epr_is_root; then
    log_warn "not running as root: the env-rename lock is not taken — this run goes on only while this host needs no env rename, restore or reconcile (those are root-only)"
    return 0
  fi
  if ! have flock; then
    log_warn "flock is not installed — toolkit runs on this host are not serialized"
    return 0
  fi
  if ! mkdir -p -- "${root}" || ! chmod 0700 "${root}"; then
    die "could not create ${root} (root 0700)"
  fi
  exec 9>>"${root}/.lock" || die "could not open ${root}/.lock"
  flock -w "${ENV_RENAME_LOCK_WAIT:-900}" 9 ||
    die "another toolkit run on this host holds ${root}/.lock (an upgrade, setup or artifact sync) — wait for it to finish and re-run"
}

# Controller Ruling 30: refuse, early and with the reason, a NON-ROOT run that
# would have to rename this host's settings to TARGET. Ruling 31: fail closed
# — a host env file this user cannot read (or cannot even tell exists,
# behind a directory it cannot search or list) might need the rename, so it
# refuses too, naming the path and never reading anything from it. A root
# run, a TAU target, or every file readable with nothing to rename: 0.
require_env_rename_privilege() { # TARGET
  local listing f kind anc
  _epr_is_root && return 0
  [[ $1 == FICUS ]] || return 0
  listing=$(_host_env_candidates) || die "could not list this host's env files"
  while IFS= read -r f; do
    [[ -n ${f} ]] || continue
    if [[ -e ${f} ]]; then
      [[ -r ${f} ]] ||
        die "cannot read ${f} as $(id -un) (uid ${EUID}), so this non-root run cannot tell whether it still uses TAU_ names the Ficus Core release needs renamed (the rename is root-only) — re-run this as root"
      continue
    fi
    # Absent, or hidden: walk up to the nearest ancestor that is visible.
    anc=$(dirname -- "${f}")
    while [[ ! -e ${anc} && ${anc} != / && ${anc} != . ]]; do
      anc=$(dirname -- "${anc}")
    done
    if [[ -d ${anc} && ! -x ${anc} ]] || { [[ ${f} == *'*'* && ${anc} == "$(dirname -- "${f}")" && -d ${anc} && ! -r ${anc} ]]; }; then
      die "cannot tell whether ${f} exists: ${anc} cannot be searched (or listed) by $(id -un) (uid ${EUID}), so this non-root run cannot check it for TAU_ names the Ficus Core release needs renamed (the rename is root-only) — re-run this as root"
    fi
  done <<<"${listing}"
  listing=$(host_env_files) || die "could not list this host's env files"
  while IFS= read -r f; do
    [[ -n ${f} && -r ${f} ]] || continue
    kind=dotenv
    [[ ${f} == "$(readlink -f -- "${CFG_FILE:-/nonexistent}" 2>/dev/null)" ]] && kind=yaml
    [[ ${f} == *.service || ${f} == *.conf ]] && kind=unit
    [[ ${f} == "$(readlink -f -- "${BACKUP_SCRIPT_PATH}" 2>/dev/null)" ]] && kind=backup_script
    if _epr_needs_rename "${f}" "${kind}"; then
      die "this host's settings must be renamed TAU_* -> FICUS_* for the Ficus Core release (${f} still uses TAU_ names), and the rename is root-only (it backs up and rewrites root-owned env files and units) — re-run this as root"
    fi
  done <<<"${listing}"
  return 0
}

# Refuse to run a FICUS_-only primitive on a host that was never renamed
# (or the reverse) — its .env, and the release it serves when that can be
# told — or whose rename is still journaled from an interrupted upgrade.
# Dies before any write.
require_host_env_prefix() { # WANT [ENV_FILE]
  local want=$1 file=${2:-${SRC_DEST}/.env} got tree release=NONE
  got=$(host_env_prefix "${file}")
  [[ ${got} == "${want}" ]] ||
    die "this host still uses TAU_* settings — upgrade it to the Ficus Core release first (retarget/move jobs are refused on unmigrated hosts) [${file}: ${got}]"
  [[ ! -e $(env_rename_backup_root)/PENDING ]] ||
    die "an interrupted upgrade left an env rename journaled in $(env_rename_backup_root)/PENDING — run the tenant upgrade (it reconciles) before retargeting"
  # The active release, when this host has one this toolkit can read (an
  # unknown one cannot disagree — the control plane's probe rule).
  if [[ -n ${SRC_DEST:-} ]]; then
    tree=$(active_release_tree) || tree=''
    if [[ -n ${tree} && (-f ${tree}/artifact.json || -f ${tree}/package.json) ]]; then
      release=$(core_release_env_prefix "${tree}") || die "could not tell which env prefix ${tree} reads"
    fi
  fi
  [[ ${release} == NONE || ${release} == "${want}" ]] ||
    die "this host's active release (${tree}) reads ${release}_* settings — upgrade it to the Ficus Core release first (retarget/move jobs are refused on unmigrated hosts)"
}

# ------------------------------------------------------------------ CI publisher (tau-ci)
#
# GitHub Actions publishes the CLI release assets onto the control-plane host
# over rsync-over-ssh (.github/workflows/cli-binaries.yml). The alternative to
# what follows is CI holding root on the control plane, which is precisely
# what this exists to prevent: the `tau-ci` account owns the CLI asset
# directory and NOTHING else — not the platform checkout, not the env file,
# not the TLS key, not the Caddyfile.

# Candidate rrsync locations, plus a FICUS_SETUP_RRSYNC (until phase 5 also
# TAU_SETUP_RRSYNC, which setup-platform.sh still sets) override for hosts where
# it lives somewhere else. rrsync ships with rsync but has moved between
# releases and is not on PATH on Ubuntu 24.04. Prints the path, or nothing
# when it cannot be found.
detect_rrsync() {
  if [[ -n ${FICUS_SETUP_RRSYNC:-${TAU_SETUP_RRSYNC:-}} ]]; then
    printf '%s' "${FICUS_SETUP_RRSYNC:-${TAU_SETUP_RRSYNC:-}}"
    return 0
  fi
  local c
  for c in /usr/bin/rrsync /usr/share/rsync/scripts/rrsync /usr/local/bin/rrsync; do
    if [[ -x ${c} ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  command -v rrsync 2>/dev/null || true
}

# One authorized_keys line for the CI publisher key, restricted as tightly as
# rsync-over-ssh allows.
#
#   command="<rrsync> -wo <dir>"  a FORCED command: whatever the client asks
#                                 for is discarded and rrsync runs instead,
#                                 confined to <dir>. -wo is write-only into
#                                 that directory, so the key cannot read
#                                 anything back out or touch any other path.
#   restrict                      no port/agent/X11 forwarding, no pty, no
#                                 user-rc. It does NOT block command
#                                 execution, which is why rsync still works.
#
# With no rrsync available the forced command is omitted and `restrict` alone
# remains — still no forwarding and no interactive shell, but the key can then
# run any command, so the caller MUST warn loudly rather than pretend the
# confinement is in place.
render_authorized_keys_line() { # RRSYNC_PATH CLI_DIR PUBLIC_KEY
  local rrsync=$1 cli_dir=$2 pubkey=$3
  if [[ -n ${rrsync} ]]; then
    printf 'command="%s -wo %s",restrict %s\n' "${rrsync}" "${cli_dir}" "${pubkey}"
  else
    printf 'restrict %s\n' "${pubkey}"
  fi
}

# ------------------------------------------------------------------ wizard

# Interactive generator for tau-setup.yaml. Prompts for the essentials, writes
# the file (no secrets — env var names and key paths only).
wizard_write_config() { # OUT_FILE
  local out=$1
  is_tty || die "--wizard needs an interactive terminal"
  if [[ -e ${out} ]]; then
    local overwrite=''
    prompt_value "config ${out} exists — overwrite? [y/N]" overwrite
    [[ ${overwrite} == y || ${overwrite} == Y ]] || die "aborted (kept existing ${out})"
  fi

  log_step "tau setup wizard — writes ${out} (secrets are NEVER stored in it)"

  local src_mode src_repo src_ref src_dest deploy_key=''
  prompt_value "source mode (git-ssh | git-https) [git-ssh]" src_mode
  src_mode=${src_mode:-git-ssh}
  [[ ${src_mode} == git-ssh || ${src_mode} == git-https ]] || die "unsupported source mode '${src_mode}' (artifact is not implemented yet)"
  local default_repo='git@github.com:ficushq/tau.git'
  [[ ${src_mode} == git-https ]] && default_repo='https://github.com/ficushq/tau.git'
  prompt_value "repo [${default_repo}]" src_repo
  src_repo=${src_repo:-${default_repo}}
  prompt_value "ref (branch/tag/sha) [main]" src_ref
  src_ref=${src_ref:-main}
  prompt_value "install dest on the target [/opt/tau]" src_dest
  src_dest=${src_dest:-/opt/tau}
  if [[ ${src_mode} == git-ssh ]]; then
    prompt_value "deploy key path (read access to the repo)" deploy_key
    [[ -n ${deploy_key} ]] || die "git-ssh mode needs a deploy key path"
  else
    log_info "git-https: put the token in GH_TOKEN when you run setup (never in the yaml)"
  fi

  local vm_name ssh_user core_port origin
  prompt_value "exe VM name (instance lives at https://<name>.exe.xyz) [my-tau]" vm_name
  vm_name=${vm_name:-my-tau}
  prompt_value "VM ssh user [exedev]" ssh_user
  ssh_user=${ssh_user:-exedev}
  prompt_value "core API port [3000]" core_port
  core_port=${core_port:-3000}
  prompt_value "browser-facing origin [https://${vm_name}.exe.xyz:${core_port}]" origin
  origin=${origin:-https://${vm_name}.exe.xyz:${core_port}}
  [[ ${origin} =~ ^https?://[^/[:space:]]+$ ]] || die "origin must be scheme://host[:port] with NO path"

  local db_mode db_dsn=''
  prompt_value "database (container = local ParadeDB in docker | external) [container]" db_mode
  db_mode=${db_mode:-container}
  if [[ ${db_mode} == external ]]; then
    log_info "external DSN: prefer supplying it via FICUS_SETUP_DATABASE_DSN at run time"
    prompt_value "postgres DSN (blank to supply via env)" db_dsn
  elif [[ ${db_mode} != container ]]; then
    die "database mode must be container or external"
  fi

  local sandbox='' exe_key='' exe_image='ghcr.io/ficushq/ficus-machine:latest'
  # The sandbox runtime has NO default: the core refuses to start without an
  # explicit FICUS_SANDBOX_RUNTIME, so the wizard must make the operator choose.
  # Bounded retries — an EOF on stdin returns an empty answer forever, and an
  # unbounded loop would spin instead of failing.
  local sandbox_try
  for sandbox_try in 1 2 3 4 5; do
    prompt_value "sandbox runtime (docker-sysbox | docker-socket | k8s | vm | host)" sandbox
    case "${sandbox}" in
      docker-sysbox | docker-socket | k8s | vm | host) break ;;
      *) log_warn "choose one of: docker-sysbox, docker-socket, k8s, vm, host (got '${sandbox}')" ;;
    esac
    sandbox=''
  done
  [[ -n ${sandbox} ]] ||
    die "sandbox runtime is required — one of docker-sysbox, docker-socket, k8s, vm, host (see docs/wiki/sandbox-runtimes.md)"
  if [[ ${sandbox} == vm ]]; then
    prompt_value "exe.dev account SSH key path" exe_key
    [[ -n ${exe_key} ]] || die "vm runtime needs the exe account key path"
    local img=''
    prompt_value "machine image [${exe_image}]" img
    exe_image=${img:-${exe_image}}
  fi

  local ai_provider ai_model ai_key_env
  prompt_value "AI provider (openai | anthropic | openai-codex) [openai]" ai_provider
  ai_provider=${ai_provider:-openai}
  local default_model default_key_env
  case "${ai_provider}" in
    openai) default_model='openai:gpt-5.5' default_key_env='OPENAI_API_KEY' ;;
    anthropic) default_model='anthropic:claude-sonnet-4-6' default_key_env='ANTHROPIC_API_KEY' ;;
    openai-codex)
      default_model='openai-codex:gpt-5.5:low' default_key_env=''
      log_warn "openai-codex needs an interactive ChatGPT OAuth login — unattended setup will skip key seeding"
      ;;
    *) die "unsupported provider '${ai_provider}'" ;;
  esac
  prompt_value "model [${default_model}]" ai_model
  ai_model=${ai_model:-${default_model}}
  ai_key_env=${default_key_env}
  if [[ -n ${default_key_env} ]]; then
    local env_name=''
    prompt_value "env var that will hold the API key [${default_key_env}]" env_name
    ai_key_env=${env_name:-${default_key_env}}
  fi

  local squad_name squad_purpose agent_type
  prompt_value "starter squad name [starter]" squad_name
  squad_name=${squad_name:-starter}
  prompt_value "squad purpose [first squad for the new tenant]" squad_purpose
  squad_purpose=${squad_purpose:-first squad for the new tenant}
  prompt_value "starter agent type [engineer]" agent_type
  agent_type=${agent_type:-engineer}

  umask 077
  cat >"${out}" <<EOF
# Generated by the tau setup wizard on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# Secrets are never stored here — see the env vars / key paths referenced below.
source:
  mode: ${src_mode}
  repo: ${src_repo}
  ref: ${src_ref}
  dest: ${src_dest}
  deploy_key_path: '${deploy_key}'
core:
  origin: ${origin}
  port: ${core_port}
  serve_web: true
  run_user: ''
database:
  mode: ${db_mode}
  dsn: '${db_dsn}'
runtime:
  sandbox: ${sandbox}
  exe:
    ssh_key_path: '${exe_key}'
    machine_image: ${exe_image}
ai:
  provider: ${ai_provider}
  key_env: ${ai_key_env}
  model: ${ai_model}
squad:
  name: ${squad_name}
  purpose: ${squad_purpose}
  agent:
    type: ${agent_type}
    model: ''
secrets:
  encryption_key_env: ''
  password_env: ''
provision:
  provider: exe
  name: ${vm_name}
  ssh_user: ${ssh_user}
  account_key_path: ''
EOF
  log_info "wrote ${out}"
  cat <<EOF

Next steps:
  # remote (provision an exe VM and set it up end-to-end):
  ${ai_key_env:+${ai_key_env}=... }scripts/setup/provision.sh --config ${out}

  # or on-target (run ON the Ubuntu 24.04 host itself):
  ${ai_key_env:+${ai_key_env}=... }scripts/setup/setup-host.sh --config ${out}
EOF
}
