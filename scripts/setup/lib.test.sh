#!/usr/bin/env bash
# lib.test.sh — unit tests for the pure helpers in lib.sh.
# Run: bash scripts/setup/lib.test.sh   (needs mikefarah yq v4 on PATH for the
# config-parsing cases; those are skipped with a warning if yq is missing).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PASS=0 FAIL=0

expect_eq() { # DESCRIPTION ACTUAL EXPECTED
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    log_error "FAIL: $1 — expected '$3', got '$2'"
  fi
}

expect_not_match() { # DESCRIPTION ACTUAL REGEX
  if [[ $2 =~ $3 ]]; then
    FAIL=$((FAIL + 1))
    log_error "FAIL: $1 — '$2' unexpectedly matches /$3/"
  else
    PASS=$((PASS + 1))
  fi
}

expect_match() { # DESCRIPTION ACTUAL REGEX
  if [[ $2 =~ $3 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    log_error "FAIL: $1 — '$2' does not match /$3/"
  fi
}

# Some sections below RUN helpers that install ROOT-OWNED files (`install -o
# root -g root`, chown root:root). macOS has no `root` GROUP at all — it is
# `wheel` — and an unprivileged user cannot chown to root on any platform, so
# there those helpers cannot execute at all.
#
# That mattered far more than it looks: `x=$( ... )` takes the status of its
# command substitution, so one failing section ended the ENTIRE runner through
# `set -e` — no summary line, and every assertion after it silently unreached
# (which is how two whole sections sat dead here). Probe the capability ONCE
# and let the affected sections skip loudly instead.
ROOT_INSTALL_PROBE_DIR=$(mktemp -d)
if install -o root -g root -m 644 /dev/null "${ROOT_INSTALL_PROBE_DIR}/probe" 2>/dev/null; then
  FICUS_TEST_ROOT_INSTALL=1
  # Machine-readable positive marker, emitted ONLY when the root-install
  # sections will actually execute. CI's root step greps the full output for
  # exactly this line, so a run where they self-skipped again (any skip
  # cause, present or future) can never look green — the summary line alone
  # cannot tell those apart. Deliberately printed BEFORE the summary so the
  # tail -n 1 summary gates are unaffected, and as a bare echo (no timestamp
  # or level prefix) so the token stays stable.
  echo 'TAU root-install sections: ENABLED'
else
  FICUS_TEST_ROOT_INSTALL=0
  log_warn 'this host cannot install root:root files — the sections that RUN those helpers (ensure_system_bun_node, ensure_swapfile) will be skipped; they run on Linux CI'
fi
rm -rf "${ROOT_INSTALL_PROBE_DIR}"

# --- gen_hex_secret ---------------------------------------------------------
expect_match 'gen_hex_secret default is 64 hex chars' "$(gen_hex_secret)" '^[0-9a-f]{64}$'
expect_match 'gen_hex_secret 16 is 32 hex chars' "$(gen_hex_secret 16)" '^[0-9a-f]{32}$'
expect_eq 'gen_hex_secret is random' "$([[ $(gen_hex_secret) == $(gen_hex_secret) ]] && echo same || echo differs)" 'differs'

# --- redact_secret ----------------------------------------------------------
expect_eq 'redact_secret empty' "$(redact_secret '')" '<empty>'
out=$(redact_secret 'sk-supersecretvalue')
expect_match 'redact_secret shows only prefix' "${out}" '^sk-s… \(19 chars, redacted\)$'
expect_eq 'redact_secret hides the value' "$([[ ${out} == *supersecret* ]] && echo leaked || echo hidden)" 'hidden'

# --- expand_tilde -----------------------------------------------------------
expect_eq 'expand_tilde bare ~' "$(expand_tilde '~')" "${HOME}"
# shellcheck disable=SC2088 # passing a literal tilde is the point of the test
expect_eq 'expand_tilde ~/x' "$(expand_tilde '~/x/y')" "${HOME}/x/y"
expect_eq 'expand_tilde absolute untouched' "$(expand_tilde '/a/b')" '/a/b'
expect_eq 'expand_tilde empty' "$(expand_tilde '')" ''

# --- cfg_env_pairs / entrypoint tilde expansion ------------------------------
# NOTE (fixed): the require_env_file_sandbox_runtime section below once invoked
# a helper that can die() — which is `exit 1` — OUTSIDE a subshell, so `|| true`
# could not catch it and the runner exited silently at that line, leaving every
# assertion after it unreachable (including this cfg_env_pairs block). The rule
# that came out of it: anything here that can die() is invoked only inside
# `( ... )` or `$( ... )`, or the suite stops without printing its summary.
if yq_is_mikefarah; then
  tilde_cfg=$(mktemp)
  cat >"${tilde_cfg}" <<'EOF'
core:
  env:
    HOME_DIR: ~/.tau-x
    FICUS_LOG_FILE_API: /var/log/tau/api.log
    FICUS_MAX_MACHINES: '10'
    FICUS_OTHER_HOME: ~someoneelse/.tau
EOF
  cfg_load "${tilde_cfg}"
  # A .env is not a shell: nothing downstream expands `~`, so a config value
  # written `~/.tau-x` reached the core verbatim and it created a directory
  # literally named `~`. Absolute values, non-path-shaped values and `~user`
  # (which expand_tilde deliberately does not resolve) are untouched.
  expect_eq 'cfg_env_pairs expands a leading ~ in a core.env value' \
    "$(cfg_env_pairs '.core.env')" \
    "HOME_DIR=${HOME}/.tau-x
FICUS_LOG_FILE_API=/var/log/tau/api.log
FICUS_MAX_MACHINES=10
FICUS_OTHER_HOME=~someoneelse/.tau"
  rm -f "${tilde_cfg}"

  tilde_cfg=$(mktemp)
  cat >"${tilde_cfg}" <<'EOF'
platform:
  env:
    PLATFORM_DO_SSH_KEY_PATH: ~/keys/do-deploy
EOF
  cfg_load "${tilde_cfg}"
  expect_eq 'cfg_env_pairs expands a leading ~ in a platform.env value too' \
    "$(cfg_env_pairs '.platform.env')" \
    "PLATFORM_DO_SSH_KEY_PATH=${HOME}/keys/do-deploy"
  rm -f "${tilde_cfg}"

  # A *_ENV value is an env var NAME resolving to a SECRET, never a path. The
  # whole point of the indirection is that secret values never live in the
  # yaml, so a secret that happens to start with `~` must not be rewritten.
  tilde_cfg=$(mktemp)
  cat >"${tilde_cfg}" <<'EOF'
core:
  env:
    FICUS_TOKEN_ENV: FICUS_TILDE_TEST_SECRET
EOF
  cfg_load "${tilde_cfg}"
  FICUS_TILDE_TEST_SECRET='~/not-a-path-just-a-secret'
  expect_eq 'cfg_env_pairs never rewrites a *_ENV-resolved secret' \
    "$(cfg_env_pairs '.core.env')" \
    'FICUS_TOKEN=~/not-a-path-just-a-secret'
  unset FICUS_TILDE_TEST_SECRET
  rm -f "${tilde_cfg}"
fi

# source.dest and platform.cli_dir are directories the toolkit creates and
# clones into, so `~` there has to be expanded before first use, not after.
for tilde_entry in 'setup-host.sh:1' 'upgrade-host.sh:1' 'seed.sh:1'; do
  tilde_script=${tilde_entry%%:*}
  expect_eq "${tilde_script} expands ~ in source.dest" \
    "$(grep -c "SRC_DEST=\$(expand_tilde " "${SCRIPT_DIR}/${tilde_script}" || true)" "${tilde_entry##*:}"
done

# --- trim_ws ----------------------------------------------------------------
expect_eq 'trim_ws strips both ends' "$(trim_ws '  vm  ')" 'vm'
expect_eq 'trim_ws strips tabs and newlines' "$(trim_ws "$(printf '\t vm \n')")" 'vm'
expect_eq 'trim_ws leaves inner spaces alone' "$(trim_ws '  a b  ')" 'a b'
expect_eq 'trim_ws on whitespace-only is empty' "$(trim_ws '   ')" ''
expect_eq 'trim_ws on empty is empty' "$(trim_ws '')" ''

# --- require_sandbox_runtime -------------------------------------------------
# ONE definition of the five supported runtimes, shared by every entrypoint
# that reads runtime.sandbox. There is no default and no auto-detection: the
# core itself refuses to start without FICUS_SANDBOX_RUNTIME, so a config that
# never chose one — or that still names a retired spelling — must die here.
for valid_runtime in docker-sysbox docker-socket k8s vm host; do
  expect_eq "require_sandbox_runtime accepts ${valid_runtime}" \
    "$( (require_sandbox_runtime "${valid_runtime}" && echo ok) 2>&1)" 'ok'
done
rsr_empty=$( (require_sandbox_runtime '') 2>&1 || true)
expect_match 'require_sandbox_runtime: empty says it is required' "${rsr_empty}" 'runtime.sandbox is required'
expect_match 'require_sandbox_runtime: empty names all five values' \
  "${rsr_empty}" 'docker-sysbox, docker-socket, k8s, vm, host'
rsr_none=$( (require_sandbox_runtime none) 2>&1 || true)
expect_match 'require_sandbox_runtime: an unknown value names all five and quotes what it got' \
  "${rsr_none}" "runtime.sandbox must be one of docker-sysbox, docker-socket, k8s, vm, host \(got 'none'\)"
rsr_sysbox=$( (require_sandbox_runtime sysbox) 2>&1 || true)
expect_match 'require_sandbox_runtime: legacy sysbox gets its rename hint' "${rsr_sysbox}" 'use docker-sysbox'
rsr_socket=$( (require_sandbox_runtime socket) 2>&1 || true)
expect_match 'require_sandbox_runtime: legacy socket gets its rename hint' "${rsr_socket}" 'use docker-socket'
for legacy_auto in auto docker; do
  rsr_auto=$( (require_sandbox_runtime "${legacy_auto}") 2>&1 || true)
  expect_match "require_sandbox_runtime: ${legacy_auto} says auto-detection was removed" \
    "${rsr_auto}" 'auto-detection was removed'
done
# Parity with the core's requireSandboxRuntime, which trims before matching: a
# yaml value that picked up stray whitespace is a typo, not a sixth runtime.
# Case is NOT normalized on either side — the five values are exact.
expect_eq 'require_sandbox_runtime accepts a whitespace-padded value' \
  "$( (require_sandbox_runtime '  vm  ' && echo ok) 2>&1)" 'ok'
expect_eq 'require_sandbox_runtime accepts a tab/newline-padded value' \
  "$( (require_sandbox_runtime "$(printf '\tdocker-socket\n')" && echo ok) 2>&1)" 'ok'
expect_match 'require_sandbox_runtime: whitespace-only is "required", not an unknown value' \
  "$( (require_sandbox_runtime '   ') 2>&1 || true)" 'runtime.sandbox is required'
expect_match 'require_sandbox_runtime: a padded legacy spelling still gets its rename hint' \
  "$( (require_sandbox_runtime ' sysbox ') 2>&1 || true)" "got 'sysbox'.* use docker-sysbox"
expect_match 'require_sandbox_runtime does NOT lowercase' \
  "$( (require_sandbox_runtime 'Host') 2>&1 || true)" "got 'Host'"
expect_eq 'require_sandbox_runtime: a rejected value exits non-zero' \
  "$( (require_sandbox_runtime none) >/dev/null 2>&1 && echo zero || echo nonzero)" 'nonzero'

# --- require_env_file_sandbox_runtime ----------------------------------------
# An upgrade rewrites no .env, so a host whose .env predates the mandatory
# FICUS_SANDBOX_RUNTIME (or still names a retired spelling) would be restarted
# into two units that immediately die. The upgrade must refuse BEFORE it
# restarts anything — and must never pick a runtime on the operator's behalf.
RSR_ENV_TMP=$(mktemp -d)
printf 'DATABASE_URL=postgres://x\nFICUS_SANDBOX_RUNTIME=vm\n' >"${RSR_ENV_TMP}/ok.env"
expect_eq 'require_env_file_sandbox_runtime accepts a valid value' \
  "$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/ok.env" && echo ok) 2>&1)" 'ok'
printf 'FICUS_SANDBOX_RUNTIME="docker-socket"\n' >"${RSR_ENV_TMP}/quoted.env"
expect_eq 'require_env_file_sandbox_runtime tolerates a quoted value' \
  "$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/quoted.env" && echo ok) 2>&1)" 'ok'
printf 'DATABASE_URL=postgres://x\n' >"${RSR_ENV_TMP}/missing.env"
rsr_env_missing=$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/missing.env") 2>&1 || true)
expect_match 'require_env_file_sandbox_runtime: an .env with no runtime dies naming the file' \
  "${rsr_env_missing}" "${RSR_ENV_TMP}/missing.env"
expect_match 'require_env_file_sandbox_runtime: the missing-value error names all five' \
  "${rsr_env_missing}" 'docker-sysbox, docker-socket, k8s, vm, host'
expect_eq 'require_env_file_sandbox_runtime: a missing value exits non-zero' \
  "$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/missing.env") >/dev/null 2>&1 && echo zero || echo nonzero)" \
  'nonzero'
for retired in auto docker sysbox socket; do
  printf 'FICUS_SANDBOX_RUNTIME=%s\n' "${retired}" >"${RSR_ENV_TMP}/${retired}.env"
  rsr_env_legacy=$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/${retired}.env") 2>&1 || true)
  expect_match "require_env_file_sandbox_runtime: the retired '${retired}' spelling dies" \
    "${rsr_env_legacy}" "got '${retired}'"
done
expect_match 'require_env_file_sandbox_runtime: sysbox gets its rename hint' \
  "$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/sysbox.env") 2>&1 || true)" 'docker-sysbox'
expect_match 'require_env_file_sandbox_runtime: an absent env file is fatal, not skipped' \
  "$( (require_env_file_sandbox_runtime "${RSR_ENV_TMP}/nope.env") 2>&1 || true)" \
  "env file '${RSR_ENV_TMP}/nope.env' not found"
# It must NOT repair the file: choosing between docker-sysbox and docker-socket
# is a security decision, and a silent rewrite would make it for the operator.
# Subshell, like every other call in this section: die() is `exit 1`, so an
# unwrapped call ends the whole runner right here — silently, before the summary.
( require_env_file_sandbox_runtime "${RSR_ENV_TMP}/auto.env" ) >/dev/null 2>&1 || true
expect_eq 'require_env_file_sandbox_runtime never rewrites the env file' \
  "$(cat "${RSR_ENV_TMP}/auto.env")" 'FICUS_SANDBOX_RUNTIME=auto'
rm -rf "${RSR_ENV_TMP}"

# The upgrade primitive has to actually CALL it — a check nothing runs is not a
# check, and the failure it prevents (both units dead after the tree moved) is
# only visible on a real box.
expect_eq 'upgrade-host.sh preflights the target env file' \
  "$(grep -c 'require_env_file_sandbox_runtime' "${SCRIPT_DIR}/upgrade-host.sh" || true)" '2'

# --- resolve_exe_key_path ----------------------------------------------------
# Non-interactive (no TTY): an empty ssh_key_path must be TOLERATED — resolve
# to empty with a warning, not die/hang. This is the headless-provisioning
# path the platform control plane's job executor relies on for the BYO tier
# (it runs setup-host.sh/seed.sh over `ssh -o BatchMode=yes`, no pty).
is_tty() { return 1; }
expect_eq 'resolve_exe_key_path: vm + empty + no TTY -> empty (no prompt, no die)' \
  "$(resolve_exe_key_path vm '' 'test prompt' 2>/dev/null)" ''
expect_eq 'resolve_exe_key_path: vm + already-set path is returned untouched' \
  "$(resolve_exe_key_path vm '/some/key' 'test prompt' 2>/dev/null)" '/some/key'
expect_eq 'resolve_exe_key_path: non-vm sandbox is untouched even if empty' \
  "$(resolve_exe_key_path docker '' 'test prompt' 2>/dev/null)" ''
warn_out=$(resolve_exe_key_path vm '' 'test prompt' 2>&1 >/dev/null)
expect_match 'resolve_exe_key_path: no-TTY skip logs a warning' "${warn_out}" 'skipping'
source "${SCRIPT_DIR}/lib.sh"

# Interactive (TTY): empty ssh_key_path is still prompted for, same as before.
is_tty() { return 0; }
prompt_value() { printf -v "$2" '%s' '/prompted/key'; }
expect_eq 'resolve_exe_key_path: vm + empty + TTY -> prompts' \
  "$(resolve_exe_key_path vm '' 'test prompt')" '/prompted/key'
source "${SCRIPT_DIR}/lib.sh"

# --- render_bootstrap_token_block --------------------------------------------
# Non-TTY stdout: a freshly-generated token must be WITHHELD (only the
# .env-file pointer is printed) — piping setup-host.sh's output to a log
# must never leak the plaintext bootstrap credential.
is_stdout_tty() { return 1; }
out=$(render_bootstrap_token_block 1 'sekrit-value' 'generated (openssl rand -hex 32)' '/opt/tau-core/.env')
expect_eq 'render_bootstrap_token_block: generated + no stdout TTY -> value withheld' \
  "$([[ ${out} == *sekrit-value* ]] && echo leaked || echo withheld)" 'withheld'
expect_match 'render_bootstrap_token_block: generated + no stdout TTY -> points at the .env file' \
  "${out}" 'Bootstrap token withheld .* /opt/tau-core/\.env'
source "${SCRIPT_DIR}/lib.sh"

# TTY stdout: a freshly-generated token IS printed, same as before.
is_stdout_tty() { return 0; }
out=$(render_bootstrap_token_block 1 'sekrit-value' 'generated (openssl rand -hex 32)' '/opt/tau-core/.env')
expect_match 'render_bootstrap_token_block: generated + stdout TTY -> value printed' "${out}" 'sekrit-value'
source "${SCRIPT_DIR}/lib.sh"

# Not generated (pre-existing FICUS_PASSWORD): never printed either way, TTY or not.
is_stdout_tty() { return 1; }
out=$(render_bootstrap_token_block 0 'sekrit-value' 'existing /opt/tau-core/.env' '/opt/tau-core/.env')
expect_eq 'render_bootstrap_token_block: not generated -> value never printed (no TTY)' \
  "$([[ ${out} == *sekrit-value* ]] && echo leaked || echo withheld)" 'withheld'
expect_match 'render_bootstrap_token_block: not generated -> shows the source' "${out}" 'existing /opt/tau-core/\.env'
source "${SCRIPT_DIR}/lib.sh"

# --- envfile_get ------------------------------------------------------------
tmp_env=$(mktemp)
printf 'A=1\nFICUS_PASSWORD=first\nFICUS_PASSWORD=second\nB=x=y\n' >"${tmp_env}"
expect_eq 'envfile_get last assignment wins' "$(envfile_get "${tmp_env}" 'FICUS_PASSWORD')" 'second'
expect_eq 'envfile_get value containing =' "$(envfile_get "${tmp_env}" 'B')" 'x=y'
expect_eq 'envfile_get missing key rc' "$(envfile_get "${tmp_env}" 'NOPE' && echo found || echo missing)" 'missing'
expect_eq 'envfile_get missing file rc' "$(envfile_get '/nonexistent-file' 'A' && echo found || echo missing)" 'missing'
rm -f "${tmp_env}"

# The env file is rendered whole by setup-platform.sh's build_env_content, and
# the Stripe signing secret is emitted LAST — an .env is last-assignment-wins
# (systemd and envfile_get both), so a stale STRIPE_WEBHOOK_SECRET_ENV left in
# platform.env can never shadow the registered endpoint's own secret.
tmp_env=$(mktemp)
printf 'STRIPE_WEBHOOK_SECRET=whsec_stale\nSTRIPE_WEBHOOK_SECRET=whsec_registered\n' >"${tmp_env}"
expect_eq 'envfile_get: a later STRIPE_WEBHOOK_SECRET wins over an earlier one' \
  "$(envfile_get "${tmp_env}" 'STRIPE_WEBHOOK_SECRET')" 'whsec_registered'
rm -f "${tmp_env}"

# --- envfile_set --------------------------------------------------------------
# The write-side counterpart, used by retarget-origin.sh to patch APP_URL /
# FICUS_WEB_ORIGIN / FICUS_PLATFORM_INGEST_URL in an already-rendered .env
# without re-rendering the whole file (which would need secrets that are
# deliberately unavailable off-box on a hosted tenant).
tmp_env=$(mktemp)
printf '# a comment\nAPP_URL=https://old.hiretau.ai\n\nFICUS_WEB_ORIGIN=https://old.hiretau.ai\nFICUS_ENCRYPTION_KEY=deadbeef\n' >"${tmp_env}"
envfile_set "${tmp_env}" APP_URL 'https://acme.ficus.sh'
envfile_set "${tmp_env}" FICUS_WEB_ORIGIN 'https://acme.ficus.sh'
expect_eq 'envfile_set: updates the targeted keys' \
  "$(envfile_get "${tmp_env}" APP_URL)/$(envfile_get "${tmp_env}" FICUS_WEB_ORIGIN)" \
  'https://acme.ficus.sh/https://acme.ficus.sh'
expect_eq 'envfile_set: preserves every other line byte-for-byte (comment, blank line, secret, ordering)' \
  "$(cat "${tmp_env}")" \
  '# a comment
APP_URL=https://acme.ficus.sh

FICUS_WEB_ORIGIN=https://acme.ficus.sh
FICUS_ENCRYPTION_KEY=deadbeef'
after_first=$(cat "${tmp_env}")
envfile_set "${tmp_env}" APP_URL 'https://acme.ficus.sh'
envfile_set "${tmp_env}" FICUS_WEB_ORIGIN 'https://acme.ficus.sh'
expect_eq 'envfile_set: re-running with the same values is a no-op (idempotent)' "$(cat "${tmp_env}")" "${after_first}"
rm -f "${tmp_env}"

tmp_env=$(mktemp)
printf 'A=1\n' >"${tmp_env}"
envfile_set "${tmp_env}" FICUS_PLATFORM_INGEST_URL 'https://ficus.sh'
expect_eq 'envfile_set: appends a key that is not already present' \
  "$(cat "${tmp_env}")" $'A=1\nFICUS_PLATFORM_INGEST_URL=https://ficus.sh'
envfile_set "${tmp_env}" FICUS_PLATFORM_INGEST_URL 'https://ficus.sh'
expect_eq 'envfile_set: re-running an appended key is still a no-op (idempotent)' \
  "$(cat "${tmp_env}")" $'A=1\nFICUS_PLATFORM_INGEST_URL=https://ficus.sh'
rm -f "${tmp_env}"

tmp_env=$(mktemp)
printf 'FICUS_PASSWORD=first\nFICUS_PASSWORD=second\n' >"${tmp_env}"
envfile_set "${tmp_env}" FICUS_PASSWORD 'third'
expect_eq 'envfile_set: rewrites every existing assignment of a duplicated key, not just the last' \
  "$(cat "${tmp_env}")" $'FICUS_PASSWORD=third\nFICUS_PASSWORD=third'
rm -f "${tmp_env}"

# envfile_set dies (exit 1) on a missing file — die() is `exit 1`, so this
# MUST run inside a subshell, or it would end the whole runner right here.
expect_eq 'envfile_set: a missing file dies (non-zero)' \
  "$( (envfile_set '/nonexistent-file' A 1) >/dev/null 2>&1 && echo zero || echo nonzero)" 'nonzero'

# --- envfile_set: FAILURE INJECTION -------------------------------------------
# A round-3 regression review found the previous implementation relied on
# errexit to catch a failing write inside a span that can be called from a
# subshell used as an if/&&/||-condition (retarget-origin.sh's cert-restore
# span does exactly that) — bash suppresses -e for the WHOLE dynamic extent
# of evaluating such a condition, including a `set -e` restated inside a
# nested subshell, so a failing write there was SILENTLY IGNORED and the
# function returned success with a truncated file installed. Reproduced
# before the fix: input `A=1/SECRET=keep/C=3`, the write forced to fail,
# result was a TRUNCATED file with no error. envfile_set now builds the
# whole replacement in memory and checks the write/mv explicitly — this
# proves that fix holds, standing in for the `if !( … )`-suppressed-errexit
# scenario without needing to reconstruct that exact calling context here
# (retarget-origin.test.sh's own mutation-phase failure injection covers
# the real end-to-end path).
tmp_env=$(mktemp)
printf 'A=1\nSECRET=keep\nC=3\n' >"${tmp_env}"
envfile_set_before=$(cat "${tmp_env}")
envfile_set_inject_rc=0
(
  # Shadow the printf BUILTIN so ONLY envfile_set's checked staged write
  # (`printf '%s' "${content}" >"${tmp}"` — the one two-argument '%s' call)
  # fails; every other printf (the read's sentinel, die()'s log_error) runs
  # the real builtin, so this reaches — and exercises — the write check.
  printf() {
    [[ $# -eq 2 && $1 == '%s' ]] && return 1
    # shellcheck disable=SC2059 # pass-through shim: forwards the caller's own format
    builtin printf "$@"
  }
  envfile_set "${tmp_env}" A 9
) >/dev/null 2>&1 || envfile_set_inject_rc=$?
expect_eq 'envfile_set failure injection: a failing write returns non-zero' "${envfile_set_inject_rc}" '1'
expect_eq 'envfile_set failure injection: the live .env is byte-identical to before (not truncated)' \
  "$(cat "${tmp_env}")" "${envfile_set_before}"
expect_eq 'envfile_set failure injection: no staged temp file is left behind' \
  "$(find "$(dirname "${tmp_env}")" -maxdepth 1 -name ".$(basename "${tmp_env}").??????" 2>/dev/null | wc -l | tr -d ' ')" '0'
rm -f "${tmp_env}"

# --- envfile_set: READ-SIDE FAILURE INJECTION ---------------------------------
# A round-4 review found the input read (`while read …; done <FILE`) was
# unchecked: inside retarget-origin.sh's errexit-suppressed span, a FILE that
# could not be opened left the rebuilt content as just `KEY=value`, which was
# then mv'd over the live .env with rc=0 — every other line (secrets
# included) gone. Each case below runs envfile_set in BOTH contexts:
#   plain      — `( set -e; envfile_set … )` as a bare statement (errexit live)
#   suppressed — the same subshell as an `if` condition, where bash ignores
#                errexit for everything inside it (retarget-origin.sh's shape)
# and asserts: non-zero exit, the .env byte-identical (cmp, so trailing
# newlines/NULs count), and no staging file left next to it.
efs_setup_none() { :; }
efs_setup_short_read_exit0() {
  # A read that "succeeds" (exit 0) but returns only the first line — what a
  # file truncated mid-read looks like to the reader.
  cat() {
    local a
    for a in "$@"; do
      [[ ${a} == "${EFS_FILE}" ]] && {
        command head -n 1 "${a}"
        return 0
      }
    done
    command cat "$@"
  }
}
efs_setup_read_error_midfile() {
  # A read that errors partway: first line delivered, then a non-zero exit.
  cat() {
    local a
    for a in "$@"; do
      [[ ${a} == "${EFS_FILE}" ]] && {
        command head -n 1 "${a}"
        return 1
      }
    done
    command cat "$@"
  }
}
efs_invoke() { # CONTEXT SETUP_FN — runs envfile_set "${EFS_FILE}" A 9; sets EFS_RC
  EFS_RC=0
  if [[ $1 == plain ]]; then
    set +e
    (
      set -e
      "$2"
      envfile_set "${EFS_FILE}" A 9
    ) >/dev/null 2>&1
    EFS_RC=$?
    set -e
  elif (
    set -e
    "$2"
    envfile_set "${EFS_FILE}" A 9
  ) >/dev/null 2>&1; then
    EFS_RC=0
  else
    EFS_RC=$?
  fi
}
efs_case() { # LABEL SETUP_FN CONTENT_PRINTF_FORMAT [chmod-000]
  local ctx dir
  for ctx in plain suppressed; do
    dir=$(mktemp -d)
    EFS_FILE="${dir}/.env"
    # shellcheck disable=SC2059 # the format IS the fixture (may carry \0)
    printf "$3" >"${EFS_FILE}"
    cp -p "${EFS_FILE}" "${dir}/pristine"
    [[ ${4:-} == chmod-000 ]] && chmod 000 "${EFS_FILE}"
    efs_invoke "${ctx}" "$2"
    chmod 600 "${EFS_FILE}"
    expect_eq "envfile_set read injection (${1}, ${ctx}): returns non-zero" \
      "$([[ ${EFS_RC} -ne 0 ]] && echo nonzero || echo "zero")" 'nonzero'
    expect_eq "envfile_set read injection (${1}, ${ctx}): the live .env is byte-identical" \
      "$(cmp -s "${EFS_FILE}" "${dir}/pristine" && echo same || echo differs)" 'same'
    expect_eq "envfile_set read injection (${1}, ${ctx}): no staging file is left behind" \
      "$(find "${dir}" -maxdepth 1 -name '..env.??????' | wc -l | tr -d ' ')" '0'
    rm -rf "${dir}"
  done
}
EFS_FIXTURE='A=1\nSECRET=keep\nC=3\n'
if [[ ${EUID} -eq 0 ]]; then
  # Root reads a mode-000 file regardless, so the file cannot be made
  # unreadable here; CI's unprivileged lib.test.sh run executes this case.
  printf 'SKIP: envfile_set unreadable-.env injection (root ignores mode 000; covered by the unprivileged run)\n' >&2
else
  efs_case 'unreadable .env' efs_setup_none "${EFS_FIXTURE}" chmod-000
fi
efs_case 'read returns only part of the file, exit 0' efs_setup_short_read_exit0 "${EFS_FIXTURE}"
efs_case 'read errors mid-file' efs_setup_read_error_midfile "${EFS_FIXTURE}"
efs_case 'file contains a NUL byte the shell cannot hold' efs_setup_none 'A=1\nSEC\0RET=keep\nC=3\n'

# The byte-count check must count BYTES: a multi-byte UTF-8 value must not
# look like a short read, in either the C locale or a UTF-8 one.
tmp_env=$(mktemp)
printf 'A=1\nNAME=caf\xc3\xa9 \xe2\x9c\x93\nC=3\n' >"${tmp_env}"
for efs_locale in C en_US.UTF-8 C.UTF-8; do
  (
    export LC_ALL=${efs_locale}
    envfile_set "${tmp_env}" A 2
  ) 2>/dev/null || true
  expect_eq "envfile_set: a UTF-8 value is not mistaken for a short read (LC_ALL=${efs_locale})" \
    "$(od -An -tx1 "${tmp_env}" | tr -d ' \n')" \
    "$(printf 'A=2\nNAME=caf\xc3\xa9 \xe2\x9c\x93\nC=3\n' | od -An -tx1 | tr -d ' \n')"
  printf 'A=1\nNAME=caf\xc3\xa9 \xe2\x9c\x93\nC=3\n' >"${tmp_env}"
done
rm -f "${tmp_env}"

# --- caddy_write_and_reload: FAILURE INJECTION --------------------------------
# Same round-3 finding, different call site: caddy_write_and_reload's own
# Caddyfile-backup line (`[[ ${had_current} -eq 1 ]] && as_root cat
# "${CADDYFILE_PATH}" >"${backup}"`) had no explicit check either. A failed
# backup write there must die WITHOUT installing the new Caddyfile — not
# silently proceed with a 0-byte backup that a later failed reload would
# then "restore".
cwr_tmp=$(mktemp -d)
CWR_CADDYFILE="${cwr_tmp}/Caddyfile"
printf 'old-content\n' >"${CWR_CADDYFILE}"
cwr_before=$(cat "${CWR_CADDYFILE}")
cwr_inject_rc=0
(
  CADDYFILE_PATH="${CWR_CADDYFILE}"
  as_root() { "$@"; }
  caddy() { return 0; } # caddy validate always "passes" in this test
  systemctl() { return 0; }
  # Drop -o/-g so caddy_install_atomically's `install -o root -g root`
  # SUCCEEDS unprivileged too — otherwise an unprivileged run would die
  # there (can't chown to root) and pass even without the backup-write
  # check this test is about.
  install() {
    local a=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        -o | -g) shift 2 ;;
        *)
          a+=("$1")
          shift
          ;;
      esac
    done
    command install "${a[@]}"
  }
  cat() {
    # Fail only reads/backups of CWR_CADDYFILE — never `cat` in general.
    for a in "$@"; do [[ ${a} == "${CWR_CADDYFILE}" ]] && return 1; done
    command cat "$@"
  }
  caddy_write_and_reload 'new-content'
) >/dev/null 2>&1 || cwr_inject_rc=$?
expect_eq 'caddy_write_and_reload failure injection: a failing backup write dies (non-zero)' "${cwr_inject_rc}" '1'
expect_eq 'caddy_write_and_reload failure injection: the live Caddyfile is completely untouched' \
  "$(cat "${CWR_CADDYFILE}")" "${cwr_before}"
rm -rf "${cwr_tmp}"

# A failed STAGED write must die before anything is installed — with
# `caddy validate` mocked to always pass, so the write check itself (not
# validate as a backstop) is what is under test. Same -o/-g-dropping
# install shim as above, so an unprivileged run cannot pass by dying at
# the install instead.
cwr_tmp=$(mktemp -d)
CWR_CADDYFILE="${cwr_tmp}/Caddyfile"
printf 'old-content\n' >"${CWR_CADDYFILE}"
cwr_before=$(cat "${CWR_CADDYFILE}")
cwr_inject_rc=0
(
  CADDYFILE_PATH="${CWR_CADDYFILE}"
  as_root() { "$@"; }
  caddy() { return 0; }
  systemctl() { return 0; }
  install() {
    local a=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        -o | -g) shift 2 ;;
        *)
          a+=("$1")
          shift
          ;;
      esac
    done
    command install "${a[@]}"
  }
  # Fail only the staged write (`printf '%s' "${rendered}" >"${staged}"`).
  printf() {
    [[ $# -eq 2 && $1 == '%s' && $2 == 'new-content' ]] && return 1
    # shellcheck disable=SC2059 # pass-through shim: forwards the caller's own format
    builtin printf "$@"
  }
  caddy_write_and_reload 'new-content'
) >/dev/null 2>&1 || cwr_inject_rc=$?
expect_eq 'caddy_write_and_reload failure injection: a failing staged write dies (non-zero)' "${cwr_inject_rc}" '1'
expect_eq 'caddy_write_and_reload failure injection: a failing staged write leaves the live Caddyfile untouched' \
  "$(cat "${CWR_CADDYFILE}")" "${cwr_before}"
rm -rf "${cwr_tmp}"

# --- retry_until ------------------------------------------------------------
expect_eq 'retry_until immediate success' "$(retry_until 5 1 'true' true && echo ok)" 'ok'
marker=$(mktemp -u)
succeed_second_try() { [[ -e ${marker} ]] || {
  touch "${marker}"
  return 1
}; }
expect_eq 'retry_until succeeds on retry' "$(retry_until 10 1 'second try' succeed_second_try && echo ok)" 'ok'
rm -f "${marker}"
expect_eq 'retry_until times out' "$(retry_until 1 1 'never' false 2>/dev/null && echo ok || echo timeout)" 'timeout'

# --- render_caddyfile / caddy_host_from_origin -------------------------------
# TLS is a SUPPLIED Cloudflare Origin CA certificate now, never ACME. These
# two cases are the PORT of the previous 'render_caddyfile without email' /
# 'with email adds a global options block' pair (signature was HOST PORT
# ACME_EMAIL): Let's Encrypt caps a registered domain at 50 certs/week across
# every *.hiretau.ai subdomain, and issuance happens AFTER payment — so
# per-tenant ACME turns a rate limit into paid-but-broken tenants.
expect_eq 'render_caddyfile serves the supplied origin certificate' \
  "$(render_caddyfile 'tau.example.com' 3000 '/etc/caddy/tls/origin.crt' '/etc/caddy/tls/origin.key')" \
  'tau.example.com {
    tls /etc/caddy/tls/origin.crt /etc/caddy/tls/origin.key
    reverse_proxy 127.0.0.1:3000
}'
caddy_rendered=$(render_caddyfile 'tau.example.com' 3000 '/etc/caddy/tls/origin.crt' '/etc/caddy/tls/origin.key')
expect_eq 'render_caddyfile emits no ACME email / global options block' \
  "$([[ ${caddy_rendered} == *email* || ${caddy_rendered} == '{'* ]] && echo present || echo gone)" 'gone'

# --- TLS source preflight + install (source pair -> canonical pair) ----------
tls_preflight_tmp=$(mktemp -d)
printf 'certificate' >"${tls_preflight_tmp}/apps.crt"
preflight_tls_source 'ingress.apps_tls_cert_path' "${tls_preflight_tmp}/apps.crt"
tls_preflight_rc=0
tls_preflight_err=$(preflight_public_certificate \
  'platform.env.PLATFORM_ORIGIN_CA_PATH' "${tls_preflight_tmp}/apps.crt" 2>&1) || tls_preflight_rc=$?
expect_eq 'preflight_public_certificate: malformed public root fails before host mutation' \
  "$([[ ${tls_preflight_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
expect_match 'preflight_public_certificate: malformed root error names the env key without PEM content' \
  "${tls_preflight_err}" 'PLATFORM_ORIGIN_CA_PATH: file does not contain a valid X.509 CA certificate'
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=not-a-ca' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -keyout "${tls_preflight_tmp}/leaf.key" -out "${tls_preflight_tmp}/leaf.crt" >/dev/null 2>&1
tls_preflight_rc=0
tls_preflight_err=$(preflight_public_certificate \
  'platform.env.PLATFORM_ORIGIN_CA_PATH' "${tls_preflight_tmp}/leaf.crt" 2>&1) || tls_preflight_rc=$?
expect_eq 'preflight_public_certificate: a valid leaf certificate is rejected as the public root' \
  "$([[ ${tls_preflight_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
tls_preflight_rc=0
tls_preflight_err=$(preflight_tls_source \
  'ingress.apps_tls_key_path' "${tls_preflight_tmp}/missing.key" 2>&1) || tls_preflight_rc=$?
expect_eq 'preflight_tls_source: missing apps key fails before later phases can mutate the host' \
  "$([[ ${tls_preflight_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
expect_match 'preflight_tls_source: missing apps key names its config field and source path' \
  "${tls_preflight_err}" 'ingress\.apps_tls_key_path: file not found: .*missing\.key'
printf 'private key' >"${tls_preflight_tmp}/unreadable.key"
chmod 000 "${tls_preflight_tmp}/unreadable.key"
if [[ ! -r ${tls_preflight_tmp}/unreadable.key ]]; then
  tls_preflight_rc=0
  tls_preflight_err=$(preflight_tls_source \
    'ingress.apps_tls_key_path' "${tls_preflight_tmp}/unreadable.key" 2>&1) || tls_preflight_rc=$?
  expect_eq 'preflight_tls_source: unreadable apps key fails before host mutation' \
    "$([[ ${tls_preflight_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_match 'preflight_tls_source: unreadable apps key has an actionable error' \
    "${tls_preflight_err}" 'ingress\.apps_tls_key_path: file is not readable'
fi
chmod 600 "${tls_preflight_tmp}/unreadable.key"

# --- tls_pair_matches ---------------------------------------------------------
# retarget-origin.sh's key/cert-mismatch validation: catches a pushed origin
# cert paired with the WRONG key (or vice versa) before anything on the host
# is touched. Compares derived public keys, not moduli, so it holds for RSA
# and EC pairs alike.
tls_pair_a_key="${tls_preflight_tmp}/pair-a.key"
tls_pair_a_crt="${tls_preflight_tmp}/pair-a.crt"
tls_pair_b_key="${tls_preflight_tmp}/pair-b.key"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=pair-a' \
  -keyout "${tls_pair_a_key}" -out "${tls_pair_a_crt}" >/dev/null 2>&1
openssl genrsa -out "${tls_pair_b_key}" 2048 >/dev/null 2>&1
expect_eq 'tls_pair_matches: a certificate matches its own key' \
  "$(tls_pair_matches "${tls_pair_a_crt}" "${tls_pair_a_key}" && echo match || echo mismatch)" 'match'
expect_eq 'tls_pair_matches: a certificate does NOT match an unrelated key' \
  "$(tls_pair_matches "${tls_pair_a_crt}" "${tls_pair_b_key}" && echo match || echo mismatch)" 'mismatch'
expect_eq 'tls_pair_matches: a missing certificate is a mismatch, not a die' \
  "$(tls_pair_matches "${tls_preflight_tmp}/nope.crt" "${tls_pair_a_key}" && echo match || echo mismatch)" 'mismatch'
expect_eq 'tls_pair_matches: a missing key is a mismatch, not a die' \
  "$(tls_pair_matches "${tls_pair_a_crt}" "${tls_preflight_tmp}/nope.key" && echo match || echo mismatch)" 'mismatch'
ec_key="${tls_preflight_tmp}/ec.key"
ec_crt="${tls_preflight_tmp}/ec.crt"
if openssl ecparam -name prime256v1 -genkey -noout -out "${ec_key}" >/dev/null 2>&1 &&
  openssl req -x509 -new -key "${ec_key}" -days 1 -subj '/CN=ec-pair' -out "${ec_crt}" >/dev/null 2>&1; then
  expect_eq 'tls_pair_matches: also holds for an EC certificate/key pair' \
    "$(tls_pair_matches "${ec_crt}" "${ec_key}" && echo match || echo mismatch)" 'match'
  expect_eq 'tls_pair_matches: an EC certificate does not match an RSA key' \
    "$(tls_pair_matches "${ec_crt}" "${tls_pair_a_key}" && echo match || echo mismatch)" 'mismatch'
else
  printf 'SKIP: openssl ecparam unavailable — skipping EC tls_pair_matches cases\n' >&2
fi
rm -rf "${tls_preflight_tmp}"

cert_install_tmp=$(mktemp -d)
mkdir -p "${cert_install_tmp}/source" "${cert_install_tmp}/canonical"
printf 'origin-cert-content' >"${cert_install_tmp}/source/origin.crt"
printf 'origin-key-content' >"${cert_install_tmp}/source/origin.key"
printf 'existing-origin-cert' >"${cert_install_tmp}/canonical/origin.crt"
printf 'existing-origin-key' >"${cert_install_tmp}/canonical/origin.key"
printf 'apps-cert-content' >"${cert_install_tmp}/source/apps-origin.crt"
printf 'apps-key-content' >"${cert_install_tmp}/source/apps-origin.key"
cert_install_log="${cert_install_tmp}/install.log"
(
  # Keep the ownership contract observable without requiring a real caddy
  # account in CI. The actual install runs as the current test user.
  id() { return 0; }
  as_root() {
    printf '%q ' "$@" >>"${cert_install_log}"
    printf '\n' >>"${cert_install_log}"
    local -a translated=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          translated+=("$1" "$(command id -un)")
          shift 2
          ;;
        -g)
          translated+=("$1" "$(command id -gn)")
          shift 2
          ;;
        *)
          translated+=("$1")
          shift
          ;;
      esac
    done
    command "${translated[@]}"
  }
  CADDY_TLS_DIR="${cert_install_tmp}/canonical"
  CADDY_TLS_CERT_PATH="${cert_install_tmp}/canonical/origin.crt"
  CADDY_TLS_KEY_PATH="${cert_install_tmp}/canonical/origin.key"
  install_origin_cert \
    "${cert_install_tmp}/source/origin.crt" \
    "${cert_install_tmp}/source/origin.key" \
    "${cert_install_tmp}/canonical/origin.crt" \
    "${cert_install_tmp}/canonical/origin.key"
  install_origin_cert \
    "${cert_install_tmp}/source/apps-origin.crt" \
    "${cert_install_tmp}/source/apps-origin.key" \
    "${cert_install_tmp}/canonical/apps-origin.crt" \
    "${cert_install_tmp}/canonical/apps-origin.key"
)
expect_eq 'install_origin_cert: installs the requested certificate bytes' \
  "$(cat "${cert_install_tmp}/canonical/apps-origin.crt" 2>/dev/null || true)" 'apps-cert-content'
expect_eq 'install_origin_cert: installs the requested private-key bytes' \
  "$(cat "${cert_install_tmp}/canonical/apps-origin.key" 2>/dev/null || true)" 'apps-key-content'
expect_eq 'install_origin_cert: apps install leaves the canonical origin certificate byte-identical' \
  "$(cat "${cert_install_tmp}/canonical/origin.crt")" 'origin-cert-content'
expect_eq 'install_origin_cert: apps install leaves the canonical origin key byte-identical' \
  "$(cat "${cert_install_tmp}/canonical/origin.key")" 'origin-key-content'
expect_match 'install_origin_cert: existing origin certificate remains 0644 root:root through the generalized helper' \
  "$(cat "${cert_install_log}")" 'install -m 0644 -o root -g root .*source/origin\.crt .*canonical/origin\.crt'
expect_match 'install_origin_cert: existing origin key remains 0600 caddy:caddy through the generalized helper' \
  "$(cat "${cert_install_log}")" 'install -m 0600 -o caddy -g caddy .*source/origin\.key .*canonical/origin\.key'
expect_match 'install_origin_cert: apps certificate is 0644 root:root' \
  "$(cat "${cert_install_log}")" 'install -m 0644 -o root -g root .*apps-origin\.crt'
expect_match 'install_origin_cert: apps private key is 0600 caddy:caddy' \
  "$(cat "${cert_install_log}")" 'install -m 0600 -o caddy -g caddy .*apps-origin\.key'
rm -rf "${cert_install_tmp}"

# --- render_authorized_keys_line / detect_rrsync (tau-ci CI publisher) -------
# The whole point of the tau-ci account is that CI does NOT hold root on the
# control plane, so the key that lands in its authorized_keys must be confined
# to the CLI asset directory and nothing else.
ci_pubkey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAATESTKEYMATERIAL tau-setup-ci'
expect_eq 'render_authorized_keys_line: forced rrsync command, write-only, confined to the cli dir' \
  "$(render_authorized_keys_line '/usr/bin/rrsync' '/var/www/tau/cli' "${ci_pubkey}")" \
  "command=\"/usr/bin/rrsync -wo /var/www/tau/cli\",restrict ${ci_pubkey}"
expect_match 'render_authorized_keys_line: restrict (no forwarding, no pty) is always present' \
  "$(render_authorized_keys_line '/usr/bin/rrsync' '/var/www/tau/cli' "${ci_pubkey}")" 'restrict'
# No rrsync on the host: `restrict` alone still removes forwarding and pty,
# but the forced command is GONE — the caller must warn, never pretend.
expect_eq 'render_authorized_keys_line: no rrsync → restrict alone, no forced command' \
  "$(render_authorized_keys_line '' '/var/www/tau/cli' "${ci_pubkey}")" \
  "restrict ${ci_pubkey}"
expect_eq 'render_authorized_keys_line: no rrsync → no command= at all (not an empty one)' \
  "$([[ $(render_authorized_keys_line '' '/var/www/tau/cli' "${ci_pubkey}") == *command=* ]] && echo present || echo absent)" \
  'absent'
expect_eq 'detect_rrsync: honors the FICUS_SETUP_RRSYNC override' \
  "$(FICUS_SETUP_RRSYNC=/opt/custom/rrsync detect_rrsync)" '/opt/custom/rrsync'
# A missing PATH candidate is not an error, even when an absolute fallback exists.
expect_eq 'detect_rrsync: succeeds even when PATH has no rrsync' \
  "$(PATH=/nonexistent FICUS_SETUP_RRSYNC='' detect_rrsync >/dev/null 2>&1; echo "rc=$?")" 'rc=0'

# --- dsn_host_port -----------------------------------------------------------
# Reachability-probe target for a postgres DSN. Prints ONLY host + port — a
# DSN embeds a password, and this value is logged.
expect_eq 'dsn_host_port: plain dsn' \
  "$(dsn_host_port 'postgres://postgres:pw@127.0.0.1:5432/tau')" '127.0.0.1 5432'
expect_eq 'dsn_host_port: managed dsn with query params' \
  "$(dsn_host_port 'postgresql://doadmin:pw@private-db.example.internal:25060/defaultdb?sslmode=require')" \
  'private-db.example.internal 25060'
expect_eq 'dsn_host_port: never echoes the password' \
  "$([[ $(dsn_host_port 'postgres://u:sup3rsecret@h.example:5432/d') == *sup3rsecret* ]] && echo leaked || echo hidden)" \
  'hidden'
expect_eq 'dsn_host_port: portless dsn yields nothing (caller skips the probe)' \
  "$(dsn_host_port 'postgres://postgres@dbhost/tau')" ''
expect_eq 'dsn_host_port: empty dsn yields nothing' "$(dsn_host_port '')" ''

expect_eq 'caddy_host_from_origin extracts host' \
  "$(caddy_host_from_origin 'https://acme.hiretau.ai')" 'acme.hiretau.ai'
# die() calls exit, which would abort this whole test script if invoked
# directly — run it in a real forked subshell so only that subshell dies, and
# check its exit status from the outer (unaffected) shell.
caddy_port_rc=0
(caddy_host_from_origin 'https://acme.hiretau.ai:3000' >/dev/null 2>&1) || caddy_port_rc=$?
expect_eq 'caddy_host_from_origin rejects an explicit port' "${caddy_port_rc}" '1'

# --- origin_host --------------------------------------------------------------
expect_eq 'origin_host strips scheme, no port' \
  "$(origin_host 'https://acme.hiretau.ai')" 'acme.hiretau.ai'
expect_eq 'origin_host strips scheme and port' \
  "$(origin_host 'https://acme.exe.xyz:3000')" 'acme.exe.xyz'
expect_eq 'origin_host handles http' \
  "$(origin_host 'http://acme.example.com:8080')" 'acme.example.com'

# --- backup_oncalendar_from_schedule -----------------------------------------
expect_eq 'backup_oncalendar_from_schedule renders daily OnCalendar' \
  "$(backup_oncalendar_from_schedule '03:15')" '*-*-* 03:15:00'
expect_eq 'backup_oncalendar_from_schedule midnight' \
  "$(backup_oncalendar_from_schedule '00:00')" '*-*-* 00:00:00'
expect_eq 'backup_oncalendar_from_schedule end of day' \
  "$(backup_oncalendar_from_schedule '23:59')" '*-*-* 23:59:00'
bad_schedule_rc=0
(backup_oncalendar_from_schedule '25:00' >/dev/null 2>&1) || bad_schedule_rc=$?
expect_eq 'backup_oncalendar_from_schedule rejects an invalid hour' "${bad_schedule_rc}" '1'
bad_schedule_rc=0
(backup_oncalendar_from_schedule '3:15' >/dev/null 2>&1) || bad_schedule_rc=$?
expect_eq 'backup_oncalendar_from_schedule rejects a non-zero-padded hour' "${bad_schedule_rc}" '1'
bad_schedule_rc=0
(backup_oncalendar_from_schedule 'nope' >/dev/null 2>&1) || bad_schedule_rc=$?
expect_eq 'backup_oncalendar_from_schedule rejects garbage' "${bad_schedule_rc}" '1'

# --- sh_single_quote ----------------------------------------------------------
expect_eq 'sh_single_quote plain value' "$(sh_single_quote 'AKIA123')" "'AKIA123'"
expect_eq 'sh_single_quote empty value' "$(sh_single_quote '')" "''"
expect_eq 'sh_single_quote escapes an embedded single quote' \
  "$(sh_single_quote "it's a test")" "'it'\\''s a test'"

# A tenant DSN carries `&` (`?sslmode=verify-full&sslrootcert=…`). Both
# secrets.env and backup.env are SOURCED, and a bare value backgrounds at the
# `&`: the variable arrives UNSET while the remainder parses as a second,
# harmless assignment — no syntax error, no warning. A live provision died on
# "database.mode=external needs database.dsn" this way, with the DSN being
# forwarded correctly the whole time. Only a real source round-trip proves it.
SQ_DSN_PROBE='postgres://u:p@h.example:25060/db?sslmode=verify-full&sslrootcert=%2Fetc%2Ftau%2Fdatabase-ca.crt'
SQ_TMP=$(mktemp)
printf 'PROBE=%s\n' "$(sh_single_quote "${SQ_DSN_PROBE}")" >"${SQ_TMP}"
expect_eq 'sh_single_quote: a value containing & survives being sourced' \
  "$(
    set -a
    # shellcheck source=/dev/null
    . "${SQ_TMP}"
    set +a
    printf '%s' "${PROBE:-<UNSET>}"
  )" "${SQ_DSN_PROBE}"
rm -f "${SQ_TMP}"

# The fix only holds if provision.sh actually routes forwarded secrets through
# it — secrets.env is written inline there, so this guards the call site.
expect_eq 'provision.sh: secrets.env values go through sh_single_quote' \
  "$(grep -cF 'sh_single_quote "${!name}"' "${SCRIPT_DIR}/provision.sh" || true)" '1'

# --- render_backup_env_content -----------------------------------------------
expect_eq 'render_backup_env_content real mode single-quotes values' \
  "$(render_backup_env_content real 'AKIA123' 's3cret' 'passphrase-value')" \
  "# Generated by scripts/setup/setup-host.sh — backup S3 credentials +
# encryption passphrase. 0600 root-owned; read by tau-backup.sh. Never log or
# print these values in full. Values are single-quoted so this file sources
# safely even if a secret contains spaces, \$(...), or backticks.
FICUS_BACKUP_S3_ACCESS_KEY='AKIA123'
FICUS_BACKUP_S3_SECRET_KEY='s3cret'
FICUS_BACKUP_PASSPHRASE='passphrase-value'"

redacted=$(render_backup_env_content redact 'AKIA123456789' 's3cretvalue12345' 'passphrase-supersecret')
expect_match 'render_backup_env_content redact mode hides the access key' \
  "${redacted}" "FICUS_BACKUP_S3_ACCESS_KEY='AKIA… \(13 chars, redacted\)'"
expect_match 'render_backup_env_content redact mode hides the secret key' \
  "${redacted}" "FICUS_BACKUP_S3_SECRET_KEY='s3cr… \(16 chars, redacted\)'"
expect_match 'render_backup_env_content redact mode hides the passphrase' \
  "${redacted}" "FICUS_BACKUP_PASSPHRASE='pass… \(22 chars, redacted\)'"
expect_eq 'render_backup_env_content redact mode leaks nothing of the secret values' \
  "$([[ ${redacted} == *'AKIA123456789'* || ${redacted} == *'s3cretvalue12345'* || ${redacted} == *'passphrase-supersecret'* ]] && echo leaked || echo hidden)" \
  'hidden'

placeholder=$(render_backup_env_content redact '<supplied-at-run-time>' '<supplied-at-run-time>' '<supplied-at-run-time>')
expect_match 'render_backup_env_content redact mode shows dry-run placeholders verbatim (quoted)' \
  "${placeholder}" "FICUS_BACKUP_S3_ACCESS_KEY='<supplied-at-run-time>'"

# Finding 2 (review): a passphrase containing shell metacharacters (spaces,
# single quotes, $(...) command substitution, backticks) must round-trip
# LITERALLY through render → write-to-disk → `source`, and must execute
# NOTHING — a bare/unquoted FICUS_BACKUP_PASSPHRASE=${passphrase} assignment
# would let `$(touch ...)`/backticks run as root when the rendered
# backup.env is sourced.
metachar_marker=$(mktemp -u)
metachar_passphrase="it's \$(touch ${metachar_marker}) \`touch ${metachar_marker}\` \"quoted\" and spaces"
metachar_env=$(mktemp)
render_backup_env_content real 'AKIA123' 's3cret' "${metachar_passphrase}" >"${metachar_env}"
(
  # shellcheck disable=SC1090
  source "${metachar_env}"
  printf '%s' "${FICUS_BACKUP_PASSPHRASE}" >"${metachar_env}.sourced"
)
expect_eq 'render_backup_env_content metachar passphrase round-trips literally through source' \
  "$(cat "${metachar_env}.sourced")" "${metachar_passphrase}"
expect_eq 'render_backup_env_content metachar passphrase executes nothing when sourced ($(...) / backticks)' \
  "$([[ -e ${metachar_marker} ]] && echo executed || echo safe)" 'safe'
rm -f "${metachar_env}" "${metachar_env}.sourced" "${metachar_marker}"

# --- config parsing (needs mikefarah yq) -------------------------------------
if yq_is_mikefarah; then
  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  port: 3000
  serve_web: false
database:
  dsn: ''
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_get string' "$(cfg_get '.core.origin')" 'https://x.example.com:3000'
  expect_eq 'cfg_get number' "$(cfg_get '.core.port')" '3000'
  expect_eq 'cfg_bool false stays false (no // footgun)' "$(cfg_bool '.core.serve_web' 'true')" 'false'
  expect_eq 'cfg_get missing → default' "$(cfg_get '.core.nope' 'dflt')" 'dflt'
  expect_eq 'cfg_get empty string → default' "$(cfg_get '.database.dsn' 'dflt')" 'dflt'
  expect_eq 'cfg_get missing section → default' "$(cfg_get '.runtime.exe.ssh_key_path' '')" ''
  rm -f "${tmp_cfg}"

  # --- cfg_set (write-side counterpart, used by retarget-origin.sh) ---------
  cfg_set_tmp=$(mktemp)
  cat >"${cfg_set_tmp}" <<'EOF'
source:
  repo: git@example.com:acme/tau.git
  dest: /opt/tau-core
core:
  origin: https://old.hiretau.ai
  port: 3000
  env: {}
ingress:
  tls_cert_path: /etc/caddy/tls/origin.crt
  tls_key_path: /etc/caddy/tls/origin.key
EOF
  cfg_load "${cfg_set_tmp}"
  cfg_set '.core.origin' 'https://acme.ficus.sh'
  cfg_set '.ingress.tls_cert_path' '/etc/caddy/tls/new.crt'
  cfg_set '.ingress.tls_key_path' '/etc/caddy/tls/new.key'
  cfg_set '.core.env.FICUS_PLATFORM_INGEST_URL' 'https://ficus.sh'
  expect_eq 'cfg_set: rewrote core.origin' "$(cfg_get '.core.origin')" 'https://acme.ficus.sh'
  expect_eq 'cfg_set: rewrote ingress.tls_cert_path' "$(cfg_get '.ingress.tls_cert_path')" '/etc/caddy/tls/new.crt'
  expect_eq 'cfg_set: rewrote ingress.tls_key_path' "$(cfg_get '.ingress.tls_key_path')" '/etc/caddy/tls/new.key'
  expect_eq 'cfg_set: created a NEW key under an existing empty map (core.env.FICUS_PLATFORM_INGEST_URL)' \
    "$(cfg_get '.core.env.FICUS_PLATFORM_INGEST_URL')" 'https://ficus.sh'
  expect_eq 'cfg_set: touched NOTHING else — source.repo untouched' \
    "$(cfg_get '.source.repo')" 'git@example.com:acme/tau.git'
  expect_eq 'cfg_set: touched NOTHING else — source.dest untouched' \
    "$(cfg_get '.source.dest')" '/opt/tau-core'
  expect_eq 'cfg_set: touched NOTHING else — core.port untouched' "$(cfg_get '.core.port')" '3000'
  cfg_set '.core.origin' 'https://acme.ficus.sh'
  cfg_set '.ingress.tls_cert_path' '/etc/caddy/tls/new.crt'
  cfg_set '.ingress.tls_key_path' '/etc/caddy/tls/new.key'
  cfg_set '.core.env.FICUS_PLATFORM_INGEST_URL' 'https://ficus.sh'
  expect_eq 'cfg_set: re-running with the same values is idempotent (core.origin still correct)' \
    "$(cfg_get '.core.origin')" 'https://acme.ficus.sh'
  expect_eq 'cfg_set: idempotent re-run still touched nothing else' "$(cfg_get '.core.port')" '3000'
  # A value carrying yq-expression-looking characters must land LITERALLY —
  # it travels through the environment (strenv()), never spliced into the yq
  # expression string, precisely so a cert PATH (or any future caller's
  # value) can never be read as yq syntax.
  cfg_set '.dns.zone' "weird'value.with:colons"
  expect_eq "cfg_set: a value containing quotes/colons is written literally, not interpreted as yq syntax" \
    "$(cfg_get '.dns.zone')" "weird'value.with:colons"
  rm -f "${cfg_set_tmp}"

  # --- cfg_has (structural presence, unlike cfg_get's "empty means unset") --
  # do-machine-mode-part2 Task 7: provision.sh must only call
  # resolve_exe_key_path (which can warn/prompt) when runtime.exe was actually
  # configured — a do_droplet config (runtime.sandbox: vm, no runtime.exe
  # section at all) must emit no exe warning.
  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
runtime:
  sandbox: vm
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_has: no runtime.exe section at all -> absent' \
    "$(cfg_has '.runtime.exe.ssh_key_path' && echo present || echo absent)" 'absent'
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
runtime:
  sandbox: vm
  exe:
    ssh_key_path: ''
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_has: runtime.exe.ssh_key_path present but empty -> present (self-hoster prompt path)' \
    "$(cfg_has '.runtime.exe.ssh_key_path' && echo present || echo absent)" 'present'
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
runtime:
  sandbox: vm
  exe:
    ssh_key_path: /root/keys/exe
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_has: runtime.exe.ssh_key_path present with a value -> present' \
    "$(cfg_has '.runtime.exe.ssh_key_path' && echo present || echo absent)" 'present'
  rm -f "${tmp_cfg}"

  # --- cfg_env_pairs / cfg_env_forward_names (core.env passthrough) ---------
  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env: {}
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_env_pairs empty map yields nothing' "$(cfg_env_pairs '.core.env')" ''
  expect_eq 'cfg_env_forward_names empty map yields nothing' "$(cfg_env_forward_names '.core.env')" ''
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    FICUS_MAX_MACHINES: '10'
    FICUS_PLATFORM_INGEST_URL: https://ingest.example.com
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_env_pairs renders two literal pairs' \
    "$(cfg_env_pairs '.core.env')" \
    'FICUS_MAX_MACHINES=10
FICUS_PLATFORM_INGEST_URL=https://ingest.example.com'
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    not-a-valid-key: whatever
EOF
  cfg_load "${tmp_cfg}"
  invalid_key_rc=0
  (cfg_env_pairs '.core.env' >/dev/null 2>&1) || invalid_key_rc=$?
  expect_eq 'cfg_env_pairs dies on an invalid key' "${invalid_key_rc}" '1'
  rm -f "${tmp_cfg}"

  # --- looks_like_literal_secret / literal-secret rejection ------------------
  # The *_ENV indirection exists so no secret VALUE lives in the yaml, but for a
  # long time nothing enforced it — a live control plane shipped raw object-
  # storage credentials in its config file. The detector must be sharp in BOTH
  # directions: a literal credential is a hard failure, and a path, an id, an
  # empty placeholder or a plain endpoint must stay legal or every existing
  # config breaks.
  expect_secret() { # DESCRIPTION KEY VALUE
    if looks_like_literal_secret "$2" "$3"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      log_error "FAIL: $1 — '$2' was NOT flagged as a literal secret"
    fi
  }
  expect_not_secret() { # DESCRIPTION KEY VALUE
    if looks_like_literal_secret "$2" "$3"; then
      FAIL=$((FAIL + 1))
      log_error "FAIL: $1 — '$2' was wrongly flagged as a literal secret"
    else
      PASS=$((PASS + 1))
    fi
  }

  expect_secret 'a credential-shaped key with a literal value' 'PLATFORM_BACKUP_S3_SECRET_KEY' 'wJalrXUtnFEMI'
  expect_secret 'an access key under an obvious name' 'SPACES_KEY' 'AKIAIOSFODNN7EXAMPLE'
  expect_secret 'a Stripe secret key under an innocuous name' 'SOME_VALUE' 'sk_live_abcdef'
  expect_secret 'a webhook signing secret under an innocuous name' 'ANYTHING' 'whsec_abcdef'
  expect_secret 'a DigitalOcean token under an innocuous name' 'ANYTHING' 'dop_v1_abcdef'
  expect_secret 'a GitHub PAT under an innocuous name' 'ANYTHING' 'github_pat_abcdef'
  expect_secret 'a PEM body under an innocuous name' 'ANYTHING' '-----BEGIN PRIVATE KEY-----'
  expect_secret 'a connection string with an inline password' 'PLATFORM_SHARED_DATABASE_URL' 'postgres://u:p@h:5432/db'

  # Representative environment values must remain non-secret. A false
  # positive here does not annoy an operator — it stops setup dead.
  expect_not_secret 'a *_KEY_PATH pointing at a file' 'PLATFORM_ORIGIN_KEY_PATH' '/etc/tau/tls/origin.key'
  expect_not_secret 'a signing *_KEY_PATH' 'PLATFORM_CORE_ARTIFACT_SIGNING_KEY_PATH' '/etc/tau/keys/x.pem'
  expect_not_secret 'an empty *_KEY_ID placeholder' 'PLATFORM_DO_SSH_KEY_ID' ''
  expect_not_secret 'a plain https endpoint' 'PLATFORM_BACKUP_S3_ENDPOINT' 'https://nyc3.digitaloceanspaces.com'
  expect_not_secret 'a connection URL with no inline password' 'SOME_URL' 'https://user@example.com/path'
  expect_not_secret 'a bare domain' 'PLATFORM_TENANT_DOMAIN' 'hiretau.ai'
  expect_not_secret 'an operator email' 'PLATFORM_OPERATOR_EMAIL' 'ops@hiretau.ai'
  expect_not_secret 'a region' 'AWS_SES_REGION' 'us-east-1'
  expect_not_secret 'a *_ENV pointer naming an env var' 'STRIPE_SECRET_KEY_ENV' 'STRIPE_SECRET_KEY'

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    FICUS_PLATFORM_USAGE_TOKEN: sk_live_pastedstraightintotheyaml
EOF
  cfg_load "${tmp_cfg}"
  literal_secret_rc=0
  (cfg_env_pairs '.core.env' >/dev/null 2>&1) || literal_secret_rc=$?
  expect_eq 'cfg_env_pairs dies on a literal secret value' "${literal_secret_rc}" '1'
  # The message has to name the fix, and must never echo the secret itself.
  literal_secret_msg=$( (cfg_env_pairs '.core.env' 2>&1 >/dev/null) || true )
  expect_match 'the literal-secret die names the *_ENV fix' "${literal_secret_msg}" 'FICUS_PLATFORM_USAGE_TOKEN_ENV'
  expect_not_match 'the literal-secret die never echoes the value' "${literal_secret_msg}" 'pastedstraightintotheyaml'
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    FICUS_PLATFORM_USAGE_TOKEN_ENV: PLATFORM_USAGE_TOKEN
EOF
  cfg_load "${tmp_cfg}"
  PLATFORM_USAGE_TOKEN='sk-supersecretvalue'
  expect_eq 'cfg_env_pairs resolves *_ENV indirection from the environment' \
    "$(cfg_env_pairs '.core.env')" \
    'FICUS_PLATFORM_USAGE_TOKEN=sk-supersecretvalue'
  redacted=$(cfg_env_pairs '.core.env' redact)
  expect_match 'cfg_env_pairs redact mode hides the *_ENV secret value' \
    "${redacted}" '^FICUS_PLATFORM_USAGE_TOKEN=sk-s… \(19 chars, redacted\)$'
  expect_eq 'cfg_env_forward_names lists the underlying env var name' \
    "$(cfg_env_forward_names '.core.env')" 'PLATFORM_USAGE_TOKEN'
  unset PLATFORM_USAGE_TOKEN
  unset_env_rc=0
  (cfg_env_pairs '.core.env' >/dev/null 2>&1) || unset_env_rc=$?
  expect_eq 'cfg_env_pairs dies when the *_ENV-referenced var is unset' "${unset_env_rc}" '1'
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    FICUS_MULTI: |
      line one
      line two
EOF
  cfg_load "${tmp_cfg}"
  newline_rc=0
  (cfg_env_pairs '.core.env' >/dev/null 2>&1) || newline_rc=$?
  expect_eq 'cfg_env_pairs dies on a value containing a newline' "${newline_rc}" '1'
  rm -f "${tmp_cfg}"

  # Finding 1 (review): the newline check must run on the RESOLVED *_ENV
  # secret, not on the yaml value (which is just an env var NAME and can
  # never contain a newline — that would be a dead check). A multi-line
  # secret (e.g. a PEM) must die, not render a corrupted multi-line .env
  # entry, and the secret value itself must never appear in the die message.
  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    FICUS_SECRET_ENV: MULTILINE_SECRET
EOF
  cfg_load "${tmp_cfg}"
  MULTILINE_SECRET=$'SEKRET-LINE-ONE\nSEKRET-LINE-TWO'
  multiline_env_rc=0 multiline_env_out=''
  multiline_env_out=$( (cfg_env_pairs '.core.env' >/dev/null) 2>&1 ) || multiline_env_rc=$?
  unset MULTILINE_SECRET
  expect_eq 'cfg_env_pairs dies when a *_ENV-resolved secret contains a newline' "${multiline_env_rc}" '1'
  expect_match 'cfg_env_pairs newline die message names the key/var, not the secret' \
    "${multiline_env_out}" 'FICUS_SECRET_ENV'
  expect_eq 'cfg_env_pairs newline die message does not leak the secret value' \
    "$([[ ${multiline_env_out} == *'SEKRET-LINE'* ]] && echo leaked || echo hidden)" 'hidden'
  rm -f "${tmp_cfg}"

  # Finding 2 (review): cfg_env_forward_names must validate the *_ENV value's
  # shape too (not just cfg_env_pairs) — provision.sh only calls
  # cfg_env_forward_names on the control machine, so a malformed env-var name
  # must fail fast there instead of silently forwarding nothing and only
  # surfacing on the remote target after VM provisioning.
  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
core:
  origin: https://x.example.com:3000
  env:
    FICUS_X_ENV: bad-name
EOF
  cfg_load "${tmp_cfg}"
  bad_env_name_rc=0
  (cfg_env_forward_names '.core.env' >/dev/null 2>&1) || bad_env_name_rc=$?
  expect_eq 'cfg_env_forward_names dies on a malformed *_ENV value' "${bad_env_name_rc}" '1'
  rm -f "${tmp_cfg}"

  # --- cfg_do_fallbacks (provision.digitalocean.fallbacks ordered pairs) ----
  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
provision:
  digitalocean:
    size: s-1vcpu-2gb
    region: nyc3
    fallbacks:
      - { size: s-1vcpu-2gb, region: sfo3 }
      - { size: s-2vcpu-2gb, region: nyc3 }
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_do_fallbacks lists SIZE REGION pairs in config order' \
    "$(cfg_do_fallbacks '.provision.digitalocean.fallbacks')" \
    's-1vcpu-2gb sfo3
s-2vcpu-2gb nyc3'
  rm -f "${tmp_cfg}"

  tmp_cfg=$(mktemp)
  cat >"${tmp_cfg}" <<'EOF'
provision:
  digitalocean:
    size: s-1vcpu-2gb
    region: nyc3
EOF
  cfg_load "${tmp_cfg}"
  expect_eq 'cfg_do_fallbacks yields nothing when fallbacks is absent (optional)' \
    "$(cfg_do_fallbacks '.provision.digitalocean.fallbacks')" ''
  rm -f "${tmp_cfg}"
else
  log_warn "mikefarah yq not on PATH — skipping cfg_* tests"
fi

# --- api_request keeps secrets out of curl argv ------------------------------
# Stub curl as a shell function: record argv, the --config file content, and
# stdin, then emulate `-o FILE` + `-w %{http_code}` the way api_request expects.
FICUS_API_BASE='http://api.test'
FICUS_BEARER='sekret-bearer"with\quirks'
CURL_SPY_DIR=$(mktemp -d)
curl() {
  printf '%s\n' "$@" >"${CURL_SPY_DIR}/argv"
  local prev='' arg outfile='' cfg=''
  for arg in "$@"; do
    case "${prev}" in
      -o) outfile=${arg} ;;
      --config) cfg=${arg} ;;
    esac
    prev=${arg}
  done
  # Read --config BEFORE stdin (matches real curl, which parses its config at
  # startup; macOS bash 3.2 also invalidates the proc-sub fd for functions in
  # a pipeline once the pipe stdin has been drained).
  [[ -n ${cfg} ]] && cat "${cfg}" >"${CURL_SPY_DIR}/config"
  cat >"${CURL_SPY_DIR}/stdin"
  [[ -n ${outfile} ]] && printf '{"ok":true}' >"${outfile}"
  printf '200'
}

api_request POST '/spy' '{"key":"topsecret-api-key"}'
expect_eq 'api_request rc/status contract kept' "${API_STATUS}" '200'
expect_eq 'api_request body contract kept' "${API_BODY}" '{"ok":true}'
expect_eq 'bearer absent from curl argv' "$(grep -c 'sekret-bearer' "${CURL_SPY_DIR}/argv" || true)" '0'
expect_eq 'request body absent from curl argv' "$(grep -c 'topsecret-api-key' "${CURL_SPY_DIR}/argv" || true)" '0'
expect_eq 'request body travels via stdin' "$(cat "${CURL_SPY_DIR}/stdin")" '{"key":"topsecret-api-key"}'
expect_eq 'bearer travels via --config, curl-escaped' \
  "$(cat "${CURL_SPY_DIR}/config")" 'header = "Authorization: Bearer sekret-bearer\"with\\quirks"'

api_request GET '/spy' ''
expect_eq 'GET has no data flag in argv' "$(grep -c -- '--data' "${CURL_SPY_DIR}/argv" || true)" '0'
expect_eq 'GET sends empty stdin' "$(cat "${CURL_SPY_DIR}/stdin")" ''

unset -f curl
rm -rf "${CURL_SPY_DIR}"

# --- http_bearer_request keeps secrets out of curl argv, is overridable -----
# Same doctrine as api_request's test above, but exercised through the
# FICUS_SETUP_HTTP_CMD seam (a distinct command name, not a `curl` shadow) so
# hcloud/Cloudflare traffic never touches a real network in tests.
HTTP_SPY_DIR=$(mktemp -d)
fake_http_cmd() {
  printf '%s\n' "$@" >"${HTTP_SPY_DIR}/argv"
  local prev='' arg outfile='' cfg=''
  for arg in "$@"; do
    case "${prev}" in
      -o) outfile=${arg} ;;
      --config) cfg=${arg} ;;
    esac
    prev=${arg}
  done
  [[ -n ${cfg} ]] && cat "${cfg}" >"${HTTP_SPY_DIR}/config"
  cat >"${HTTP_SPY_DIR}/stdin"
  [[ -n ${outfile} ]] && printf '{"servers":[]}' >"${outfile}"
  printf '200'
}
FICUS_SETUP_HTTP_CMD=fake_http_cmd

http_bearer_request 'https://api.hetzner.cloud/v1' 'hz-secret-token' GET '/servers?name=acme' ''
expect_eq 'http_bearer_request rc/status contract kept' "${HTTP_STATUS}" '200'
expect_eq 'http_bearer_request body contract kept' "${HTTP_BODY}" '{"servers":[]}'
expect_eq 'http_bearer_request GET has no data flag in argv' "$(grep -c -- '--data' "${HTTP_SPY_DIR}/argv" || true)" '0'
expect_eq 'http_bearer_request token absent from curl argv' "$(grep -c 'hz-secret-token' "${HTTP_SPY_DIR}/argv" || true)" '0'
expect_eq 'http_bearer_request token travels via --config' \
  "$(cat "${HTTP_SPY_DIR}/config")" 'header = "Authorization: Bearer hz-secret-token"'
expect_eq 'http_bearer_request hits the requested base+path' \
  "$(grep -c 'https://api.hetzner.cloud/v1/servers?name=acme' "${HTTP_SPY_DIR}/argv" || true)" '1'

http_bearer_request 'https://api.cloudflare.com/client/v4' 'cf-secret-token' POST '/zones/z1/dns_records' '{"content":"1.2.3.4"}'
expect_eq 'http_bearer_request POST body absent from curl argv' "$(grep -c '1.2.3.4' "${HTTP_SPY_DIR}/argv" || true)" '0'
expect_eq 'http_bearer_request POST body travels via stdin' "$(cat "${HTTP_SPY_DIR}/stdin")" '{"content":"1.2.3.4"}'

unset -f fake_http_cmd
unset FICUS_SETUP_HTTP_CMD
rm -rf "${HTTP_SPY_DIR}"

# --- hcloud pure helpers (request builders / response parsers / reuse branch) -
expect_eq 'hcloud_server_create_body shape' \
  "$(hcloud_server_create_body 'acme' 'cx32' 'fsn1' 'ubuntu-24.04' 'platform-deploy')" \
  '{
  "name": "acme",
  "server_type": "cx32",
  "location": "fsn1",
  "image": "ubuntu-24.04",
  "ssh_keys": [
    "platform-deploy"
  ]
}'

expect_eq 'hcloud_server_lookup finds an existing server by name (reuse branch)' \
  "$(hcloud_server_lookup '{"servers":[{"id":123,"status":"running","public_net":{"ipv4":{"ip":"1.2.3.4"}}}]}')" \
  'running 123 1.2.3.4'
expect_eq 'hcloud_server_lookup yields nothing when no server matches (create branch)' \
  "$(hcloud_server_lookup '{"servers":[]}')" ''
expect_eq 'hcloud_server_lookup handles a server with no IP yet' \
  "$(hcloud_server_lookup '{"servers":[{"id":9,"status":"initializing","public_net":{"ipv4":null}}]}')" \
  'initializing 9 '

expect_eq 'hcloud_server_status_id_ip parses a create/get response' \
  "$(hcloud_server_status_id_ip '{"server":{"id":42,"status":"running","public_net":{"ipv4":{"ip":"5.6.7.8"}}}}')" \
  'running 42 5.6.7.8'
expect_eq 'hcloud_server_status_id_ip handles a not-yet-running server' \
  "$(hcloud_server_status_id_ip '{"server":{"id":42,"status":"initializing","public_net":{"ipv4":null}}}')" \
  'initializing 42 '

# --- digitalocean pure helpers (request builder / response parsers / reuse
# branch / public-vs-private IPv4 pick / capacity-error matcher) -------------
expect_eq 'do_droplet_create_body shape' \
  "$(do_droplet_create_body 'acme' 'nyc3' 's-1vcpu-2gb' 'ubuntu-24-04-x64' 'abc123' 'tau-tenant')" \
  '{
  "name": "acme",
  "region": "nyc3",
  "size": "s-1vcpu-2gb",
  "image": "ubuntu-24-04-x64",
  "ssh_keys": [
    "abc123"
  ],
  "tags": [
    "tau-tenant"
  ]
}'

# vpc_uuid pins the droplet to a specific VPC network instead of whatever the
# region's DEFAULT VPC happens to be at create time. That default is a
# console setting that can change without warning, and a droplet in the wrong
# VPC cannot reach the shared Postgres cluster's private host — which is the
# host every tenant DSN uses.
expect_eq 'do_droplet_create_body pins vpc_uuid when one is given' \
  "$(do_droplet_create_body 'acme' 'nyc3' 's-1vcpu-2gb' 'ubuntu-24-04-x64' 'abc123' 'tau-tenant' 'vpc-abc-123' | jq -c .)" \
  '{"name":"acme","region":"nyc3","size":"s-1vcpu-2gb","image":"ubuntu-24-04-x64","ssh_keys":["abc123"],"tags":["tau-tenant"],"vpc_uuid":"vpc-abc-123"}'
expect_eq 'do_droplet_create_body omits vpc_uuid entirely when it is empty (DO then picks the default VPC)' \
  "$(do_droplet_create_body 'acme' 'nyc3' 's-1vcpu-2gb' 'ubuntu-24-04-x64' 'abc123' 'tau-tenant' '' | jq -c .)" \
  '{"name":"acme","region":"nyc3","size":"s-1vcpu-2gb","image":"ubuntu-24-04-x64","ssh_keys":["abc123"],"tags":["tau-tenant"]}'

# Droplet-create has NO project_id field — assignment is a separate call to
# POST /projects/<id>/resources with the droplet's URN.
expect_eq 'do_project_assign_body builds the droplet URN' \
  "$(do_project_assign_body 12345 | jq -c .)" \
  '{"resources":["do:droplet:12345"]}'

# The easiest thing to get wrong per the DO API: a droplet response carries
# BOTH a public and a private v4 entry — the public one must be picked
# regardless of array order.
expect_eq 'do_droplet_lookup picks the PUBLIC ipv4 when a private one is also present (reuse branch)' \
  "$(do_droplet_lookup '{"droplets":[{"id":123,"name":"acme","status":"active","networks":{"v4":[{"ip_address":"10.0.0.5","type":"private"},{"ip_address":"203.0.113.9","type":"public"}]}}]}' 'acme')" \
  'active 123 203.0.113.9'
expect_eq 'do_droplet_lookup picks the public ipv4 even when it is listed FIRST' \
  "$(do_droplet_lookup '{"droplets":[{"id":123,"name":"acme","status":"active","networks":{"v4":[{"ip_address":"203.0.113.9","type":"public"},{"ip_address":"10.0.0.5","type":"private"}]}}]}' 'acme')" \
  'active 123 203.0.113.9'
expect_eq 'do_droplet_lookup filters to the exact NAME (tag_name alone can return other tagged droplets)' \
  "$(do_droplet_lookup '{"droplets":[{"id":1,"name":"other-tenant","status":"active","networks":{"v4":[{"ip_address":"198.51.100.1","type":"public"}]}}]}' 'acme')" \
  ''
expect_eq 'do_droplet_lookup yields nothing when no droplet matches (create branch)' \
  "$(do_droplet_lookup '{"droplets":[]}' 'acme')" ''
expect_eq 'do_droplet_lookup handles a droplet with no public ip yet' \
  "$(do_droplet_lookup '{"droplets":[{"id":9,"name":"acme","status":"new","networks":{"v4":[]}}]}' 'acme')" \
  'new 9 '

expect_eq 'do_droplet_status_id_ip parses a create/get response, picking the public ipv4' \
  "$(do_droplet_status_id_ip '{"droplet":{"id":42,"status":"active","networks":{"v4":[{"ip_address":"10.0.0.9","type":"private"},{"ip_address":"5.6.7.8","type":"public"}]}}}')" \
  'active 42 5.6.7.8'
expect_eq 'do_droplet_status_id_ip handles a not-yet-active droplet (no networks yet)' \
  "$(do_droplet_status_id_ip '{"droplet":{"id":42,"status":"new","networks":{"v4":[]}}}')" \
  'new 42 '

expect_eq 'do_is_capacity_error: 422 with a capacity-shaped message → true' \
  "$(do_is_capacity_error 422 '{"message":"The size s-1vcpu-2gb is not available in this region."}' && echo yes || echo no)" 'yes'
expect_eq 'do_is_capacity_error: 503 with a capacity-shaped message → true' \
  "$(do_is_capacity_error 503 '{"message":"insufficient capacity in this datacenter"}' && echo yes || echo no)" 'yes'
expect_eq 'do_is_capacity_error: 401 (auth) never matches, regardless of message → false' \
  "$(do_is_capacity_error 401 '{"message":"Unable to authenticate you."}' && echo yes || echo no)" 'no'
expect_eq 'do_is_capacity_error: 403 (forbidden) never matches → false' \
  "$(do_is_capacity_error 403 '{"message":"not available to your account — forbidden"}' && echo yes || echo no)" 'no'
expect_eq 'do_is_capacity_error: 422 with a non-capacity message (invalid image) → false' \
  "$(do_is_capacity_error 422 '{"message":"You specified an invalid image for Droplet creation."}' && echo yes || echo no)" 'no'
expect_eq 'do_is_capacity_error: 200 (success) never matches → false' \
  "$(do_is_capacity_error 200 '{"message":"ok"}' && echo yes || echo no)" 'no'

expect_eq 'do_is_account_limit_error: 422 droplet-limit message → true' \
  "$(do_is_account_limit_error 422 '{"id":"unprocessable_entity","message":"You have reached your droplet limit. Please contact support to request an increase."}' && echo yes || echo no)" 'yes'
expect_eq 'do_is_account_limit_error: 422 with a size-stockout message → false (that is capacity, not the account)' \
  "$(do_is_account_limit_error 422 '{"message":"The size s-1vcpu-2gb is not available in this region."}' && echo yes || echo no)" 'no'
expect_eq 'do_is_account_limit_error: 503 never matches → false' \
  "$(do_is_account_limit_error 503 '{"message":"droplet limit"}' && echo yes || echo no)" 'no'
expect_eq 'PROVISION_EXIT_PERMANENT is the platform executor contract (66)' "${PROVISION_EXIT_PERMANENT}" '66'

# --- cloudflare pure helpers (parsers / idempotent-upsert branch / body) -----
expect_eq 'cf_zone_id_from_list finds the zone id' \
  "$(cf_zone_id_from_list '{"result":[{"id":"zone123","name":"hiretau.ai"}]}')" 'zone123'
expect_eq 'cf_zone_id_from_list yields nothing when the zone is not found' \
  "$(cf_zone_id_from_list '{"result":[]}')" ''

expect_eq 'cf_dns_record_id_from_list finds the existing record (update branch)' \
  "$(cf_dns_record_id_from_list '{"result":[{"id":"rec456","type":"A"}]}')" 'rec456'
expect_eq 'cf_dns_record_id_from_list yields nothing when no record exists (create branch)' \
  "$(cf_dns_record_id_from_list '{"result":[]}')" ''

# PORTED from 'cf_dns_record_body shape (unproxied A record)': the record must
# now be PROXIED. A Cloudflare Origin CA certificate is trusted by Cloudflare's
# proxy and by nothing else — an unproxied (grey-cloud) record would put that
# certificate in front of real browsers, which reject it. There is no
# half-measure: proxied records and origin certs go together.
expect_eq 'cf_dns_record_body shape (PROXIED A record — origin certs require the orange cloud)' \
  "$(cf_dns_record_body 'acme.hiretau.ai' '1.2.3.4')" \
  '{
  "type": "A",
  "name": "acme.hiretau.ai",
  "content": "1.2.3.4",
  "proxied": true
}'

# --- provision.sh integration: SERVER_IP contract + robust boot polling -----
# Runs provision.sh as a real subprocess (not just its pure helpers) with
# fake `ssh`/`scp` and a fake FICUS_SETUP_HTTP_CMD exported as bash functions
# (bash-to-bash function export — provision.sh is invoked as `bash
# provision.sh`, a child bash process that inherits them) so a full
# hetzner/exe success path can run with no real network or SSH target.
if yq_is_mikefarah; then
  PROV_TMP=$(mktemp -d)

  # Shared no-op ssh/scp: every remote step (SSH wait, file pushes, remote
  # setup-host.sh run, secrets cleanup) just succeeds instantly.
  #
  # PROV_SSH_FAIL_MATCH (exported into a single provision.sh run) makes this
  # fake ssh FAIL for any invocation whose argv contains that substring —
  # how the mid-run-failure cases below simulate a provision that dies after
  # the VM exists (e.g. inside the remote setup-host.sh run) without
  # redefining/restoring the fake around each test.
  ssh() {
    if [[ -n ${PROV_SSH_FAIL_MATCH:-} ]]; then
      local _ssh_arg
      for _ssh_arg in "$@"; do
        if [[ ${_ssh_arg} == *"${PROV_SSH_FAIL_MATCH}"* ]]; then return 1; fi
      done
    fi
    return 0
  }
  # PROV_SCP_CAPTURE (exported into a single provision.sh run) turns the fake
  # scp into a recorder: every invocation's argv is appended to
  # $PROV_SCP_CAPTURE/log, and each local source file is copied into that
  # directory under the BASENAME it would have landed at on the VM. That is how
  # the database-CA delivery case below inspects both what was pushed and the
  # config rewriting that goes with it, with no real remote involved.
  scp() {
    if [[ -n ${PROV_SCP_CAPTURE:-} ]]; then
      printf '%s\n' "$*" >>"${PROV_SCP_CAPTURE}/log"
      local _scp_args=("$@") _scp_dst _scp_src _scp_last
      _scp_last=$((${#_scp_args[@]} - 1))
      _scp_dst=${_scp_args[${_scp_last}]}
      for _scp_src in "${_scp_args[@]:0:${_scp_last}}"; do
        [[ -f ${_scp_src} ]] || continue
        cp "${_scp_src}" "${PROV_SCP_CAPTURE}/$(basename "${_scp_dst}")"
      done
    fi
    return 0
  }
  export -f ssh scp

  # Common request-arg parsing for the hcloud fakes below: pulls the request
  # URL and the `-o <file>` response-body destination out of curl-style argv,
  # drains stdin (POST bodies), and leaves them in $_url/$_outfile.
  _prov_parse_http_argv() {
    _url='' _outfile='' _prev=''
    local arg
    for arg in "$@"; do
      case "${_prev}" in
        -o) _outfile=${arg} ;;
      esac
      case "${arg}" in
        http*) _url=${arg} ;;
      esac
      _prev=${arg}
    done
    cat >/dev/null
  }
  export -f _prov_parse_http_argv

  touch "${PROV_TMP}/key"
  chmod 600 "${PROV_TMP}/key"

  cat >"${PROV_TMP}/hetzner.yaml" <<EOF
provision:
  provider: hetzner
  name: acme
  account_key_path: ${PROV_TMP}/key
  hetzner:
    server_type: cx32
    location: fsn1
    image: ubuntu-24.04
    ssh_key_name: platform-deploy
core:
  origin: https://acme.hiretau.ai
source:
  mode: git-https
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  cat >"${PROV_TMP}/exe.yaml" <<EOF
provision:
  provider: exe
  name: acme
  account_key_path: ${PROV_TMP}/key
core:
  origin: https://acme.exe.xyz:3000
source:
  mode: git-https
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  cat >"${PROV_TMP}/digitalocean.yaml" <<EOF
provision:
  provider: digitalocean
  name: acme-do
  account_key_path: ${PROV_TMP}/key
  digitalocean:
    size: s-1vcpu-2gb
    region: nyc3
    image: ubuntu-24-04-x64
    ssh_key_id: '12345'
core:
  origin: https://acme-do.hiretau.ai
source:
  mode: git-https
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  cat >"${PROV_TMP}/digitalocean-fallback.yaml" <<EOF
provision:
  provider: digitalocean
  name: acme-fb
  account_key_path: ${PROV_TMP}/key
  digitalocean:
    size: s-1vcpu-2gb
    region: nyc3
    image: ubuntu-24-04-x64
    ssh_key_id: '12345'
    fallbacks:
      - { size: s-1vcpu-2gb, region: sfo3 }
      - { size: s-2vcpu-2gb, region: nyc3 }
core:
  origin: https://acme-fb.hiretau.ai
source:
  mode: git-https
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  # -- Finding 1: hetzner success path ends with `SERVER_IP=<ip>` as the LAST
  # stdout line (after the handoff banner); exe's output has no such line.
  fake_hcloud_http_ok() {
    _prov_parse_http_argv "$@"
    local body code
    case "${_url}" in
      *'?name='*) body='{"servers":[]}' code=200 ;;
      *'/servers/'*) body='{"server":{"id":555,"status":"running","public_net":{"ipv4":{"ip":"203.0.113.9"}}}}' code=200 ;;
      *) body='{"server":{"id":555,"status":"initializing","public_net":{"ipv4":null}}}' code=201 ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_hcloud_http_ok

  hetzner_out=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner.yaml")
  hetzner_last_line=$(printf '%s\n' "${hetzner_out}" | tail -n1)
  expect_match 'hetzner success path: last stdout line is SERVER_IP=<ip>' "${hetzner_last_line}" '^SERVER_IP=[0-9.]+$'
  expect_eq 'hetzner success path: SERVER_IP matches the polled server IP' "${hetzner_last_line}" 'SERVER_IP=203.0.113.9'

  exe_out=$(bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/exe.yaml")
  expect_eq 'exe success path: output has no SERVER_IP line (byte-identical contract)' \
    "$(printf '%s\n' "${exe_out}" | grep -c '^SERVER_IP=' || true)" '0'

  # -- provider: exe --dry-run stdout is byte-identical to before the
  # digitalocean provider was added (golden text, captured against the
  # pre-change script) — adding a new PROVIDER SEAM branch must never touch
  # the exe branch's own output. Compared via files, NOT a heredoc nested in
  # a `$(...)` command substitution: bash 3.2 (macOS's system bash) corrupts
  # backslash-newline pairs inside such a heredoc, collapsing the `exe.dev \`
  # continuation line into one line with extra spaces — a real bug this test
  # tripped over, not a hypothetical one.
  GH_TOKEN='' bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/exe.yaml" --dry-run 2>/dev/null |
    sed "s#${PROV_TMP}#TMPDIR#g" >"${PROV_TMP}/exe-dryrun-actual.txt"
  cat >"${PROV_TMP}/exe-dryrun-expected.txt" <<'EOF'

Step 1 — provision VM (provider seam: exe)
  ssh -i TMPDIR/key -o IdentitiesOnly=yes -o IdentityAgent=none exe.dev \
      new --name acme --image ghcr.io/ficushq/ficus-machine:latest --json
  (skipped if exedev@acme.exe.xyz already answers SSH — idempotent re-run)

Step 2 — wait for SSH
  retry ssh exedev@acme.exe.xyz true (account key, IdentityAgent=none) until reachable (timeout 300s)

Step 3 — push toolkit + config + credentials (COPYFILE_DISABLE=1)
  → /home/exedev/tau-setup/: lib.sh setup-host.sh seed.sh systemd/*.tmpl
  → /home/exedev/tau-setup/tau-setup.yaml (key paths rewritten to /home/exedev/tau-setup/keys/*)

Step 4 — run setup on the VM
  ssh exedev@acme.exe.xyz 'set -a; [ -f /home/exedev/tau-setup/secrets.env ] && . /home/exedev/tau-setup/secrets.env; set +a; bash /home/exedev/tau-setup/setup-host.sh --config /home/exedev/tau-setup/tau-setup.yaml'
  then: setup-host.sh phases 0-8 (run it with --dry-run locally to see its full plan)

Step 5 — cleanup + handoff
  delete /home/exedev/tau-setup/secrets.env on the VM
  print https://acme.exe.xyz:3000 + 'create your first admin passkey' handoff
EOF
  expect_eq 'provider: exe dry-run output unchanged (byte-identical)' \
    "$(cmp -s "${PROV_TMP}/exe-dryrun-actual.txt" "${PROV_TMP}/exe-dryrun-expected.txt" && echo identical || echo differs)" \
    'identical'

  # -- BYO-tier headless gap: `runtime.sandbox: vm` with NO
  # `runtime.exe.ssh_key_path` (the platform control plane renders exactly
  # this for the BYO tier — exe machines are registered by the tenant
  # post-handoff, not provisioned here) must NOT die at provision.sh's own
  # preflight, even though this run has no TTY (matches how the job
  # executor invokes it: `ssh -o BatchMode=yes`, no pty upstream either).
  cat >"${PROV_TMP}/hetzner-byo.yaml" <<EOF
provision:
  provider: hetzner
  name: acme-byo
  account_key_path: ${PROV_TMP}/key
  hetzner:
    server_type: cx32
    location: fsn1
    image: ubuntu-24.04
    ssh_key_name: platform-deploy
core:
  origin: https://acme-byo.hiretau.ai
source:
  mode: git-https
runtime:
  sandbox: vm
ai:
  provider: openai-codex
EOF
  byo_out=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner-byo.yaml")
  byo_last_line=$(printf '%s\n' "${byo_out}" | tail -n1)
  expect_match 'BYO headless gap: vm sandbox + empty exe key + no TTY still reaches SERVER_IP (no die)' \
    "${byo_last_line}" '^SERVER_IP=[0-9.]+$'

  # -- do-machine-mode-part2 Task 7: hetzner-byo.yaml above has `runtime.sandbox:
  # vm` and NO `runtime.exe` section at all — the do_droplet shape (the
  # platform default). It must emit NO exe-key warning at all, not even the
  # "unset, skipping" one the same headless run used to log. A config that DOES
  # configure runtime.exe (even with an empty ssh_key_path — the self-hoster
  # "prompt me" shape) still gets it, unchanged.
  byo_stderr=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner-byo.yaml" 2>&1 >/dev/null)
  expect_eq 'do_droplet-shaped config (no runtime.exe section) emits no exe-key warning' \
    "$(printf '%s\n' "${byo_stderr}" | grep -c 'ssh_key_path is unset' || true)" '0'

  cat >"${PROV_TMP}/hetzner-exe-configured.yaml" <<EOF
provision:
  provider: hetzner
  name: acme-exe-cfg
  account_key_path: ${PROV_TMP}/key
  hetzner:
    server_type: cx32
    location: fsn1
    image: ubuntu-24.04
    ssh_key_name: platform-deploy
core:
  origin: https://acme-exe-cfg.hiretau.ai
source:
  mode: git-https
runtime:
  sandbox: vm
  exe:
    ssh_key_path: ''
ai:
  provider: openai-codex
EOF
  exe_cfg_stderr=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner-exe-configured.yaml" 2>&1 >/dev/null)
  expect_eq 'runtime.exe present (even empty ssh_key_path): the exe-key warning still fires — unchanged' \
    "$(printf '%s\n' "${exe_cfg_stderr}" | grep -c 'ssh_key_path is unset' || true)" '1'

  # -- Early SERVER_IP: a run that dies AFTER the server exists (here: the
  # remote setup-host.sh invocation fails) must still have printed
  # SERVER_IP=<ip>. Same contract as the digitalocean case below — see that
  # test's comment for why this is the whole point of the line.
  hz_midfail_rc=0
  hz_midfail_out=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_ok \
    PROV_SSH_FAIL_MATCH=setup-host.sh \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner.yaml" 2>/dev/null) || hz_midfail_rc=$?
  expect_eq 'hetzner mid-setup failure: provision.sh exits non-zero' \
    "$([[ ${hz_midfail_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_eq 'hetzner mid-setup failure: SERVER_IP was already printed (server exists and is billing)' \
    "$(printf '%s\n' "${hz_midfail_out}" | grep -c '^SERVER_IP=203\.0\.113\.9$' || true)" '1'

  unset -f fake_hcloud_http_ok

  # -- Finding 2: a transient hcloud 5xx during boot polling is retried, not
  # fatal. First GET /servers/<id> returns 503; second returns running. Before
  # the fix this died inside the (output-swallowed) poll and the run never
  # reached SERVER_IP.
  export PROV_POLL_COUNT_FILE="${PROV_TMP}/poll-count"
  printf '0' >"${PROV_POLL_COUNT_FILE}"
  fake_hcloud_http_transient() {
    _prov_parse_http_argv "$@"
    local body code n
    case "${_url}" in
      *'?name='*) body='{"servers":[]}' code=200 ;;
      *'/servers/'*)
        n=$(($(cat "${PROV_POLL_COUNT_FILE}") + 1))
        printf '%s' "${n}" >"${PROV_POLL_COUNT_FILE}"
        if ((n == 1)); then
          body='{"error":"internal server error"}' code=503
        else
          body='{"server":{"id":555,"status":"running","public_net":{"ipv4":{"ip":"203.0.113.9"}}}}' code=200
        fi
        ;;
      *) body='{"server":{"id":555,"status":"initializing","public_net":{"ipv4":null}}}' code=201 ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_hcloud_http_transient

  transient_out=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_transient \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner.yaml")
  expect_eq 'transient 5xx during boot poll: run survives and reaches SERVER_IP (retried, not fatal)' \
    "$(printf '%s\n' "${transient_out}" | tail -n1)" 'SERVER_IP=203.0.113.9'
  expect_eq 'transient 5xx during boot poll: the fake actually saw two poll attempts' \
    "$(cat "${PROV_POLL_COUNT_FILE}")" '2'

  unset -f fake_hcloud_http_transient
  unset PROV_POLL_COUNT_FILE

  # -- Finding 3: a server landing in a terminal state (error/off/deleting)
  # fails fast (well under the 300s poll timeout) with a visible message
  # naming the observed status — not a silent hang to the full timeout.
  fake_hcloud_http_terminal() {
    _prov_parse_http_argv "$@"
    local body code
    case "${_url}" in
      *'?name='*) body='{"servers":[]}' code=200 ;;
      *'/servers/'*) body='{"server":{"id":555,"status":"error","public_net":{"ipv4":null}}}' code=200 ;;
      *) body='{"server":{"id":555,"status":"initializing","public_net":{"ipv4":null}}}' code=201 ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_hcloud_http_terminal

  terminal_rc=0
  terminal_err=''
  terminal_start=$(date +%s)
  terminal_err=$(HCLOUD_TOKEN=dummy-hcloud-token FICUS_SETUP_HTTP_CMD=fake_hcloud_http_terminal \
    timeout 20 bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/hetzner.yaml" 2>&1 >/dev/null) || terminal_rc=$?
  terminal_elapsed=$(($(date +%s) - terminal_start))
  expect_eq 'terminal hcloud state: provision.sh exits non-zero' \
    "$([[ ${terminal_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_eq 'terminal hcloud state: fails fast, well under the 300s poll timeout' \
    "$([[ ${terminal_elapsed} -lt 60 ]] && echo fast || echo slow)" 'fast'
  expect_match 'terminal hcloud state: die message names the observed status, not swallowed' \
    "${terminal_err}" "terminal state 'error'"

  unset -f fake_hcloud_http_terminal

  # -- digitalocean success path: create → poll → SERVER_IP=<public ipv4>,
  # picking the PUBLIC entry even though the poll response also carries a
  # private one (the easiest thing to get wrong per the DO API).
  fake_do_http_ok() {
    _prov_parse_http_argv "$@"
    local body code
    case "${_url}" in
      *'?tag_name='*) body='{"droplets":[]}' code=200 ;;
      *'/droplets/'*)
        body='{"droplet":{"id":777,"status":"active","networks":{"v4":[{"ip_address":"10.116.0.5","type":"private"},{"ip_address":"198.51.100.9","type":"public"}]}}}'
        code=200
        ;;
      *) body='{"droplet":{"id":777,"status":"new","networks":{"v4":[]}}}' code=202 ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_do_http_ok

  do_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean.yaml")
  do_last_line=$(printf '%s\n' "${do_out}" | tail -n1)
  expect_match 'digitalocean success path: last stdout line is SERVER_IP=<ip>' "${do_last_line}" '^SERVER_IP=[0-9.]+$'
  expect_eq 'digitalocean success path: SERVER_IP picks the PUBLIC ipv4, not the private one' \
    "${do_last_line}" 'SERVER_IP=198.51.100.9'

  # -- Early SERVER_IP contract (production incident): the IP must reach
  # stdout the moment the droplet is known to exist, NOT only after host
  # setup finishes. Host setup runs for many minutes and is where failures
  # actually happen; the droplet is alive and billing the whole time. The
  # control plane persists this line to tenants.server_ip, and its cleanup
  # path (terminate → ssh to the VM) is unreachable without it — the observed
  # symptom was "tenant … has no serverIp — cannot ssh" against a live
  # droplet. Simulated here by failing the remote setup-host.sh run (step 4).
  do_midfail_rc=0
  do_midfail_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_ok \
    PROV_SSH_FAIL_MATCH=setup-host.sh \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean.yaml" 2>/dev/null) || do_midfail_rc=$?
  expect_eq 'digitalocean mid-setup failure: provision.sh exits non-zero' \
    "$([[ ${do_midfail_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_eq 'digitalocean mid-setup failure: SERVER_IP was already printed (droplet exists and is billing)' \
    "$(printf '%s\n' "${do_midfail_out}" | grep -c '^SERVER_IP=198\.51\.100\.9$' || true)" '1'
  expect_eq 'digitalocean mid-setup failure: the handoff banner is NOT printed (the run really did fail)' \
    "$([[ ${do_midfail_out} == *'Tenant provisioned.'* ]] && echo claimed-success || echo failed)" 'failed'

  unset -f fake_do_http_ok

  # -- digitalocean idempotent reuse: an existing droplet (matched by tag +
  # exact name) is reused — the create endpoint (POST /droplets, no query,
  # no id in path) must never be called.
  export PROV_DO_CREATE_COUNT_FILE="${PROV_TMP}/do-create-count"
  printf '0' >"${PROV_DO_CREATE_COUNT_FILE}"
  fake_do_http_reuse() {
    _prov_parse_http_argv "$@"
    local body code
    case "${_url}" in
      *'?tag_name='*)
        body='{"droplets":[{"id":888,"name":"acme-do","status":"active","networks":{"v4":[{"ip_address":"198.51.100.9","type":"public"}]}}]}'
        code=200
        ;;
      *'/droplets/'*)
        body='{"droplet":{"id":888,"status":"active","networks":{"v4":[{"ip_address":"198.51.100.9","type":"public"}]}}}'
        code=200
        ;;
      *)
        printf '%s' "$(($(cat "${PROV_DO_CREATE_COUNT_FILE}") + 1))" >"${PROV_DO_CREATE_COUNT_FILE}"
        body='{"droplet":{"id":999,"status":"new","networks":{"v4":[]}}}'
        code=202
        ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_do_http_reuse

  reuse_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_reuse \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean.yaml")
  expect_eq 'digitalocean idempotent reuse: SERVER_IP is the EXISTING droplet, not a new one' \
    "$(printf '%s\n' "${reuse_out}" | tail -n1)" 'SERVER_IP=198.51.100.9'
  expect_eq 'digitalocean idempotent reuse: create (POST /droplets) is never called' \
    "$(cat "${PROV_DO_CREATE_COUNT_FILE}")" '0'

  # The reuse path emits the early SERVER_IP too — a re-provision that adopts
  # an existing droplet and then fails mid-setup must still report the IP (the
  # control plane re-writes the same value; the write is idempotent).
  reuse_midfail_rc=0
  reuse_midfail_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_reuse \
    PROV_SSH_FAIL_MATCH=setup-host.sh \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean.yaml" 2>/dev/null) || reuse_midfail_rc=$?
  expect_eq 'digitalocean reuse + mid-setup failure: provision.sh exits non-zero' \
    "$([[ ${reuse_midfail_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_eq 'digitalocean reuse + mid-setup failure: SERVER_IP of the EXISTING droplet was already printed' \
    "$(printf '%s\n' "${reuse_midfail_out}" | grep -c '^SERVER_IP=198\.51\.100\.9$' || true)" '1'

  unset -f fake_do_http_reuse
  unset PROV_DO_CREATE_COUNT_FILE

  # -- digitalocean VPC pinning + project assignment.
  #
  # vpc_uuid must be PASSED, not left to the region's default VPC: the default
  # is a console setting that can change without warning, and a droplet
  # outside the VPC cannot reach the shared Postgres cluster's private host —
  # the host every tenant DSN uses.
  #
  # project_id has no droplet-create field at all; it is a separate
  # POST /projects/<id>/resources call with the droplet's URN, made AFTER
  # create. It is cosmetic grouping, so it must never fail the provision and
  # orphan a paid droplet — see the 403 case below.
  export PROV_DO_CREATE_BODY_FILE="${PROV_TMP}/do-create-body"
  export PROV_DO_PROJECT_FILE="${PROV_TMP}/do-project-call"
  : >"${PROV_DO_CREATE_BODY_FILE}"
  : >"${PROV_DO_PROJECT_FILE}"

  # Like _prov_parse_http_argv, but KEEPS stdin (the POST body) so the request
  # payloads can be asserted on. PROJECT_CODE picks the project-call response.
  _fake_do_http_vpc_project() { # PROJECT_CODE ...ARGV
    local project_code=$1
    shift
    local _url='' _outfile='' _prev='' arg
    for arg in "$@"; do
      case "${_prev}" in
        -o) _outfile=${arg} ;;
      esac
      case "${arg}" in
        http*) _url=${arg} ;;
      esac
      _prev=${arg}
    done
    local sent_body
    sent_body=$(cat)

    local body code
    case "${_url}" in
      *'/projects/'*)
        printf '%s %s' "${_url}" "${sent_body}" >"${PROV_DO_PROJECT_FILE}"
        body='{"resources":[]}' code=${project_code}
        ;;
      *'?tag_name='*) body='{"droplets":[]}' code=200 ;;
      *'/droplets/'*)
        body='{"droplet":{"id":777,"status":"active","networks":{"v4":[{"ip_address":"198.51.100.9","type":"public"}]}}}'
        code=200
        ;;
      *)
        printf '%s' "${sent_body}" >"${PROV_DO_CREATE_BODY_FILE}"
        body='{"droplet":{"id":777,"status":"new","networks":{"v4":[]}}}' code=202
        ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  fake_do_http_project_ok() { _fake_do_http_vpc_project 201 "$@"; }
  fake_do_http_project_403() { _fake_do_http_vpc_project 403 "$@"; }
  export -f _fake_do_http_vpc_project fake_do_http_project_ok fake_do_http_project_403

  cat >"${PROV_TMP}/digitalocean-vpc.yaml" <<EOF
provision:
  provider: digitalocean
  name: acme-vpc
  account_key_path: ${PROV_TMP}/key
  digitalocean:
    size: s-1vcpu-2gb
    region: nyc3
    image: ubuntu-24-04-x64
    ssh_key_id: '12345'
    vpc_uuid: vpc-test-uuid
    project_id: proj-test-id
core:
  origin: https://acme-vpc.hiretau.ai
source:
  mode: git-https
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  vpc_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_project_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean-vpc.yaml")
  expect_eq 'digitalocean vpc: the create body pins vpc_uuid from config' \
    "$(jq -r '.vpc_uuid' <"${PROV_DO_CREATE_BODY_FILE}")" 'vpc-test-uuid'
  # (the recorded line is "<url> <body>", and the body is pretty-printed JSON
  # spanning several lines — hence head -1 before cutting the url off)
  expect_match 'digitalocean project: POST goes to /projects/<configured id>/resources' \
    "$(head -1 <"${PROV_DO_PROJECT_FILE}" | cut -d' ' -f1)" '/projects/proj-test-id/resources$'
  expect_eq 'digitalocean project: the body is the droplet URN' \
    "$(cut -d' ' -f2- <"${PROV_DO_PROJECT_FILE}" | jq -c .)" '{"resources":["do:droplet:777"]}'
  expect_eq 'digitalocean vpc/project: the provision still ends with SERVER_IP' \
    "$(printf '%s\n' "${vpc_out}" | tail -n1)" 'SERVER_IP=198.51.100.9'

  # The reachable failure state: droplet created, assignment refused. Losing a
  # cosmetic grouping must not fail the provision and orphan a paid droplet.
  : >"${PROV_DO_PROJECT_FILE}"
  proj_rc=0
  proj_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_project_403 \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean-vpc.yaml" 2>"${PROV_TMP}/proj-err") || proj_rc=$?
  expect_eq 'digitalocean project assignment failure: provision.sh still exits 0' "${proj_rc}" '0'
  expect_eq 'digitalocean project assignment failure: SERVER_IP is still emitted' \
    "$(printf '%s\n' "${proj_out}" | tail -n1)" 'SERVER_IP=198.51.100.9'
  expect_match 'digitalocean project assignment failure: warns loudly instead of dying silently' \
    "$(cat "${PROV_TMP}/proj-err")" 'project'

  # Omitting both keys must leave the payload and the call sequence exactly as
  # they were — the toolkit is used outside the platform too.
  : >"${PROV_DO_CREATE_BODY_FILE}"
  : >"${PROV_DO_PROJECT_FILE}"
  DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_project_ok \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean.yaml" >/dev/null
  expect_eq 'digitalocean without vpc_uuid: no vpc_uuid key in the create body' \
    "$(jq -r 'has("vpc_uuid")' <"${PROV_DO_CREATE_BODY_FILE}")" 'false'
  expect_eq 'digitalocean without project_id: no project assignment call is made' \
    "$(cat "${PROV_DO_PROJECT_FILE}")" ''

  unset -f _fake_do_http_vpc_project fake_do_http_project_ok fake_do_http_project_403
  unset PROV_DO_CREATE_BODY_FILE PROV_DO_PROJECT_FILE

  # -- digitalocean ordered fallback: a capacity-shaped 422 on the PRIMARY
  # size/region advances to fallback #1 (config order), which succeeds.
  export PROV_DO_ATTEMPT_FILE="${PROV_TMP}/do-fallback-attempts"
  printf '0' >"${PROV_DO_ATTEMPT_FILE}"
  fake_do_http_capacity_fallback() {
    _prov_parse_http_argv "$@"
    local body code n
    case "${_url}" in
      *'?tag_name='*) body='{"droplets":[]}' code=200 ;;
      *'/droplets/'*)
        body='{"droplet":{"id":321,"status":"active","networks":{"v4":[{"ip_address":"203.0.113.50","type":"public"}]}}}'
        code=200
        ;;
      *)
        n=$(($(cat "${PROV_DO_ATTEMPT_FILE}") + 1))
        printf '%s' "${n}" >"${PROV_DO_ATTEMPT_FILE}"
        if ((n == 1)); then
          body='{"message":"The size s-1vcpu-2gb is not available in region nyc3 at this time."}'
          code=422
        else
          body='{"droplet":{"id":321,"status":"new","networks":{"v4":[]}}}'
          code=202
        fi
        ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_do_http_capacity_fallback

  fb_out=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_capacity_fallback \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean-fallback.yaml")
  expect_eq 'digitalocean fallback: capacity error on the primary advances to fallback #1, which succeeds' \
    "$(printf '%s\n' "${fb_out}" | tail -n1)" 'SERVER_IP=203.0.113.50'
  expect_eq 'digitalocean fallback: exactly 2 create attempts (primary capacity-failed, fallback #1 succeeded)' \
    "$(cat "${PROV_DO_ATTEMPT_FILE}")" '2'

  unset -f fake_do_http_capacity_fallback
  unset PROV_DO_ATTEMPT_FILE

  # -- digitalocean ordered fallback: a 401 (bad auth) on the primary must
  # NOT burn through fallbacks — it dies immediately, on the first attempt.
  export PROV_DO_ATTEMPT_FILE="${PROV_TMP}/do-401-attempts"
  printf '0' >"${PROV_DO_ATTEMPT_FILE}"
  fake_do_http_401() {
    _prov_parse_http_argv "$@"
    local body code
    case "${_url}" in
      *'?tag_name='*) body='{"droplets":[]}' code=200 ;;
      *'/droplets/'*) body='{"droplet":{"id":1,"status":"active","networks":{"v4":[{"ip_address":"203.0.113.51","type":"public"}]}}}' code=200 ;;
      *)
        printf '%s' "$(($(cat "${PROV_DO_ATTEMPT_FILE}") + 1))" >"${PROV_DO_ATTEMPT_FILE}"
        body='{"id":"unauthorized","message":"Unable to authenticate you."}'
        code=401
        ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_do_http_401

  do401_rc=0
  do401_err=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_401 \
    timeout 20 bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean-fallback.yaml" 2>&1 >/dev/null) || do401_rc=$?
  expect_eq 'digitalocean fallback: a 401 exits non-zero' "$([[ ${do401_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_eq 'digitalocean fallback: a 401 does NOT burn through fallbacks — only ONE create attempt is made' \
    "$(cat "${PROV_DO_ATTEMPT_FILE}")" '1'
  expect_match 'digitalocean fallback: 401 die message is visible' "${do401_err}" 'HTTP 401'

  unset -f fake_do_http_401
  unset PROV_DO_ATTEMPT_FILE

  # -- digitalocean terminal state: a droplet landing in 'archive' (DO's
  # "gone" state) fails fast, well under the 300s poll timeout, with a
  # visible message naming the observed status.
  fake_do_http_terminal() {
    _prov_parse_http_argv "$@"
    local body code
    case "${_url}" in
      *'?tag_name='*) body='{"droplets":[]}' code=200 ;;
      *'/droplets/'*) body='{"droplet":{"id":404,"status":"archive","networks":{"v4":[]}}}' code=200 ;;
      *) body='{"droplet":{"id":404,"status":"new","networks":{"v4":[]}}}' code=202 ;;
    esac
    [[ -n ${_outfile} ]] && printf '%s' "${body}" >"${_outfile}"
    printf '%s' "${code}"
  }
  export -f fake_do_http_terminal

  do_terminal_rc=0
  do_terminal_start=$(date +%s)
  do_terminal_err=$(DIGITALOCEAN_TOKEN=dummy-do-token FICUS_SETUP_HTTP_CMD=fake_do_http_terminal \
    timeout 20 bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/digitalocean.yaml" 2>&1 >/dev/null) || do_terminal_rc=$?
  do_terminal_elapsed=$(($(date +%s) - do_terminal_start))
  expect_eq 'digitalocean terminal state: provision.sh exits non-zero' \
    "$([[ ${do_terminal_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_eq 'digitalocean terminal state: fails fast, well under the 300s poll timeout' \
    "$([[ ${do_terminal_elapsed} -lt 60 ]] && echo fast || echo slow)" 'fast'
  expect_match 'digitalocean terminal state: die message names the observed status, not swallowed' \
    "${do_terminal_err}" "terminal state 'archive'"

  # -- database.ca_path: the shared managed Postgres cluster's CA, delivered
  # to the tenant VM over the SAME scp path as the Cloudflare origin
  # certificate. Tenant DSNs use sslmode=verify-full, which has no fallback:
  # if this file does not arrive at the path the DSN's `sslrootcert` names,
  # every connection on that tenant fails outright. So the checks belong
  # BEFORE the droplet is created and paid for, exactly like the origin cert's
  # (698de62f).
  printf -- '-----BEGIN CERTIFICATE-----\nfake-do-cluster-ca\n-----END CERTIFICATE-----\n' >"${PROV_TMP}/db-ca.crt"

  cat >"${PROV_TMP}/exe-dbca.yaml" <<EOF
provision:
  provider: exe
  name: acme
  account_key_path: ${PROV_TMP}/key
core:
  origin: https://acme.exe.xyz:3000
source:
  mode: git-https
database:
  mode: external
  ca_path: ${PROV_TMP}/db-ca.crt
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  mkdir -p "${PROV_TMP}/scp-capture"
  PROV_SCP_CAPTURE="${PROV_TMP}/scp-capture" \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/exe-dbca.yaml" >/dev/null
  expect_match 'database CA: pushed to the VM alongside the other key material' \
    "$(cat "${PROV_TMP}/scp-capture/log")" '/home/exedev/tau-setup/keys/database_ca\.pem'
  # The path in the config the VM receives must be the VM's path, not this
  # machine's — same rewrite the origin cert/key get.
  expect_eq 'database CA: the pushed config points at the CA on the VM, not on the control machine' \
    "$(yq '.database.ca_path' "${PROV_TMP}/scp-capture/tau-setup.yaml")" \
    '/home/exedev/tau-setup/keys/database_ca.pem'
  # Not a secret (it is a public certificate) — but it is still a real file
  # whose CONTENTS have to arrive intact.
  expect_match 'database CA: the certificate itself is what gets copied' \
    "$(cat "${PROV_TMP}/scp-capture/database_ca.pem")" 'fake-do-cluster-ca'

  # External mode must plan the PGDG postgresql-client install: the nightly
  # backup timer needs pg_dump, and its major must cover the managed
  # cluster's (Ubuntu 24.04 ships v16; the live cluster runs v18 — the first
  # real backup fired with no pg_dump at all, and even the distro package
  # would have failed on major). Asserted via setup-host.sh --dry-run, which
  # exits while printing the plan, before any phase can touch the host.
  # `|| true`: a die inside $() under set -e would otherwise abort the whole
  # suite with no summary line — observed; the expect_match then reports the
  # error output instead.
  cat >"${PROV_TMP}/sh-external.yaml" <<EOF
core:
  origin: https://acme.example:3000
source:
  mode: git-https
  repo: https://github.com/example/tau.git
database:
  mode: external
  ca_path: ${PROV_TMP}/db-ca.crt
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
  model: gpt-5
EOF
  sh_dry_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@db.example:25060/t?sslmode=verify-full' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${PROV_TMP}/sh-external.yaml" --dry-run 2>&1) || true
  expect_match 'setup-host dry-run (external db): plans the PGDG pg_dump install' \
    "${sh_dry_out}" 'pg_dump via PGDG postgresql-client'

  # source.mode=artifact: the dry run must plan acquire → stage → activate
  # instead of the clone/build/db:migrate plan, and must NEVER print the
  # FICUS_ARTIFACT_* URL VALUES — only the env var names — since they are
  # presigned GET credentials borne by the environment.
  cat >"${PROV_TMP}/sh-artifact.yaml" <<EOF
core:
  origin: https://acme.example:3000
source:
  mode: artifact
  repo: https://github.com/example/tau.git
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
  model: gpt-5
EOF
  sh_artifact_dry_out=$(FICUS_ARTIFACT_TARBALL_URL='https://example.test/tarball?sig=ZZZ-SECRET-VALUE-ZZZ' \
    FICUS_ARTIFACT_MANIFEST_URL='https://example.test/manifest.json' \
    FICUS_ARTIFACT_SIG_URL='https://example.test/manifest.sig' \
    FICUS_ARTIFACT_PUBKEY_B64='ZZZ-PUBKEY-B64-ZZZ' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${PROV_TMP}/sh-artifact.yaml" --dry-run 2>&1) || true
  expect_match 'setup-host dry-run (artifact mode): plans acquire/stage, naming the env vars' \
    "${sh_artifact_dry_out}" 'FICUS_ARTIFACT_TARBALL_URL'
  expect_eq 'setup-host dry-run (artifact mode): the secret URL VALUE never reaches the plan' \
    "$(grep -c 'ZZZ-SECRET-VALUE-ZZZ' <<<"${sh_artifact_dry_out}" || true)" '0'
  expect_match 'setup-host dry-run (artifact mode): the build phase is a no-op' \
    "${sh_artifact_dry_out}" 'nothing to build'
  expect_match 'setup-host dry-run (artifact mode): the migrate phase defers to activation' \
    "${sh_artifact_dry_out}" 'migrations run inside artifact_activate'
  expect_match 'setup-host dry-run (artifact mode): the services phase plans artifact_activate' \
    "${sh_artifact_dry_out}" 'artifact_activate'

  # A PARTIAL artifact input set must die naming what is missing — never
  # silently fall back to a source build.
  sh_artifact_partial_err=$(FICUS_ARTIFACT_TARBALL_URL='https://example.test/tarball' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${PROV_TMP}/sh-artifact.yaml" --dry-run 2>&1) || true
  expect_match 'setup-host dry-run (artifact mode, partial env): dies, refusing to fall back to a source build' \
    "${sh_artifact_partial_err}" 'artifact inputs are incomplete'
  expect_match 'setup-host dry-run (artifact mode, partial env): names a missing var' \
    "${sh_artifact_partial_err}" 'FICUS_ARTIFACT_MANIFEST_URL'

  # runtime.sandbox is REQUIRED and explicit: there is no default and no
  # auto-detection anywhere in the stack (the core refuses to start without
  # FICUS_SANDBOX_RUNTIME), so an unset value must die instead of silently
  # installing `vm`, and the retired spellings must die naming the five values.
  cat >"${PROV_TMP}/sh-no-sandbox.yaml" <<EOF
core:
  origin: https://acme.example:3000
source:
  mode: git-https
  repo: https://github.com/example/tau.git
ai:
  provider: openai-codex
  model: gpt-5
EOF
  sh_no_sandbox_err=$(bash "${SCRIPT_DIR}/setup-host.sh" --config "${PROV_TMP}/sh-no-sandbox.yaml" --dry-run 2>&1) || true
  expect_match 'setup-host: an unset runtime.sandbox dies instead of defaulting to vm' \
    "${sh_no_sandbox_err}" 'runtime.sandbox is required'
  expect_match 'setup-host: the unset-runtime error names all five values' \
    "${sh_no_sandbox_err}" 'docker-sysbox, docker-socket, k8s, vm, host'

  cat >"${PROV_TMP}/sh-legacy-sandbox.yaml" <<EOF
core:
  origin: https://acme.example:3000
source:
  mode: git-https
  repo: https://github.com/example/tau.git
runtime:
  sandbox: docker
ai:
  provider: openai-codex
  model: gpt-5
EOF
  sh_legacy_sandbox_err=$(bash "${SCRIPT_DIR}/setup-host.sh" --config "${PROV_TMP}/sh-legacy-sandbox.yaml" --dry-run 2>&1) || true

  # A yaml value with stray whitespace is a typo, not a sixth runtime: it must
  # be ACCEPTED (the trim happens where the value is read, so the rendered .env
  # gets `vm`, not ` vm ` — which would pass the core's trimming boot guard and
  # then fail every isVmRuntime() comparison).
  cat >"${PROV_TMP}/sh-padded-sandbox.yaml" <<EOF
core:
  origin: https://acme.example:3000
source:
  mode: git-https
  repo: https://github.com/example/tau.git
runtime:
  sandbox: '  vm  '
ai:
  provider: openai-codex
  model: gpt-5
EOF
  sh_padded_out=$(bash "${SCRIPT_DIR}/setup-host.sh" --config "${PROV_TMP}/sh-padded-sandbox.yaml" --dry-run 2>&1) || true
  expect_eq 'setup-host: a whitespace-padded runtime.sandbox is accepted, not rejected' \
    "$([[ ${sh_padded_out} == *'runtime.sandbox must be one of'* ]] && echo rejected || echo accepted)" 'accepted'
  # The load-bearing half: the value must reach the rendered .env TRIMMED.
  # Validating a trimmed copy while writing the padded original is exactly the
  # failure this guards — ` vm ` passes the core's (trimming) boot guard and
  # then matches no isVmRuntime() comparison.
  expect_eq 'setup-host: the padded value lands trimmed in the rendered .env' \
    "$(printf '%s\n' "${sh_padded_out}" | sed -n 's/.*FICUS_SANDBOX_RUNTIME=//p' | tail -1)" 'vm'
  expect_match 'setup-host: the retired `docker` spelling dies naming the five values' \
    "${sh_legacy_sandbox_err}" "runtime.sandbox must be one of docker-sysbox, docker-socket, k8s, vm, host \(got 'docker'\)"

  # provision.sh and seed.sh carry the same requirement (they read the same key
  # for their own decisions and must not invent a default either).
  for required_caller in provision.sh seed.sh; do
    expect_eq "${required_caller} reads runtime.sandbox with no default" \
      "$(grep -c "cfg_get '.runtime.sandbox')" "${SCRIPT_DIR}/${required_caller}" || true)" '1'
    expect_eq "${required_caller} validates it through lib.sh's shared helper" \
      "$(grep -c 'require_sandbox_runtime "\${RT_SANDBOX}"' "${SCRIPT_DIR}/${required_caller}" || true)" '1'
  done

  cat >"${PROV_TMP}/exe-dbca-missing.yaml" <<EOF
provision:
  provider: exe
  name: acme
  account_key_path: ${PROV_TMP}/key
core:
  origin: https://acme.exe.xyz:3000
source:
  mode: git-https
database:
  mode: external
  ca_path: ${PROV_TMP}/does-not-exist.crt
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF
  dbca_missing_rc=0
  dbca_missing_err=$(bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/exe-dbca-missing.yaml" 2>&1 >/dev/null) ||
    dbca_missing_rc=$?
  expect_eq 'database CA: a missing certificate fails BEFORE any VM is created' \
    "$([[ ${dbca_missing_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
  expect_match 'database CA: the missing-file message names the config key' \
    "${dbca_missing_err}" 'database.ca_path'

  # READABILITY, not just existence — the control plane runs as an
  # unprivileged service user, so a root-owned 0600 CA would otherwise fail
  # with an opaque `scp: Permission denied` after the droplet exists.
  cp "${PROV_TMP}/db-ca.crt" "${PROV_TMP}/db-ca-unreadable.crt"
  chmod 000 "${PROV_TMP}/db-ca-unreadable.crt"
  if [[ -r ${PROV_TMP}/db-ca-unreadable.crt ]]; then
    # Running as root (or on a filesystem that ignores the mode): the
    # distinction this case exists to prove is unobservable here.
    log_warn 'skipping the unreadable-CA case — this user can read a 0000 file'
  else
    cat >"${PROV_TMP}/exe-dbca-unreadable.yaml" <<EOF
provision:
  provider: exe
  name: acme
  account_key_path: ${PROV_TMP}/key
core:
  origin: https://acme.exe.xyz:3000
source:
  mode: git-https
database:
  mode: external
  ca_path: ${PROV_TMP}/db-ca-unreadable.crt
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF
    dbca_perm_rc=0
    dbca_perm_err=$(bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/exe-dbca-unreadable.yaml" 2>&1 >/dev/null) ||
      dbca_perm_rc=$?
    expect_eq 'database CA: an unreadable certificate fails BEFORE any VM is created' \
      "$([[ ${dbca_perm_rc} -ne 0 ]] && echo nonzero || echo zero)" 'nonzero'
    expect_match 'database CA: the permission message is actionable' \
      "${dbca_perm_err}" 'not readable'
  fi
  chmod 644 "${PROV_TMP}/db-ca-unreadable.crt"

  # -- source.mode=artifact forwards the four FICUS_ARTIFACT_* presigned-URL
  # values (and never GH_TOKEN — artifact mode never clones from GitHub);
  # source.mode=git-https is the mirror image (GH_TOKEN, none of the four).
  # Both are asserted against the CONTENT of the secrets.env actually pushed
  # to the VM (via PROV_SCP_CAPTURE, same mechanism as the database CA case
  # above), not just against provision.sh's source — a real run is what
  # proves FORWARD_ENVS assembly and the push loop agree.
  cat >"${PROV_TMP}/artifact-mode.yaml" <<EOF
provision:
  provider: exe
  name: acme
  account_key_path: ${PROV_TMP}/key
core:
  origin: https://acme.exe.xyz:3000
source:
  mode: artifact
runtime:
  sandbox: docker-socket
ai:
  provider: openai-codex
EOF

  mkdir -p "${PROV_TMP}/scp-capture-artifact"
  PROV_SCP_CAPTURE="${PROV_TMP}/scp-capture-artifact" \
    GH_TOKEN='ZZZ-SHOULD-NOT-FORWARD-ZZZ' \
    FICUS_ARTIFACT_TARBALL_URL='https://example.test/tarball?sig=ZZZ' \
    FICUS_ARTIFACT_MANIFEST_URL='https://example.test/manifest.json' \
    FICUS_ARTIFACT_SIG_URL='https://example.test/manifest.sig' \
    FICUS_ARTIFACT_PUBKEY_B64='ZZZ-PUBKEY-B64-ZZZ' \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/artifact-mode.yaml" >/dev/null
  artifact_secrets=$(cat "${PROV_TMP}/scp-capture-artifact/secrets.env" 2>/dev/null || true)
  for artifact_env_name in FICUS_ARTIFACT_TARBALL_URL FICUS_ARTIFACT_MANIFEST_URL FICUS_ARTIFACT_SIG_URL FICUS_ARTIFACT_PUBKEY_B64; do
    expect_eq "source.mode=artifact: secrets.env forwards ${artifact_env_name}" \
      "$(grep -c "^${artifact_env_name}=" <<<"${artifact_secrets}" || true)" '1'
  done
  expect_eq 'source.mode=artifact: secrets.env does NOT forward GH_TOKEN' \
    "$(grep -c '^GH_TOKEN=' <<<"${artifact_secrets}" || true)" '0'

  mkdir -p "${PROV_TMP}/scp-capture-githttps"
  PROV_SCP_CAPTURE="${PROV_TMP}/scp-capture-githttps" \
    GH_TOKEN='ZZZ-GH-TOKEN-ZZZ' \
    FICUS_ARTIFACT_TARBALL_URL='https://example.test/tarball?sig=ZZZ' \
    FICUS_ARTIFACT_MANIFEST_URL='https://example.test/manifest.json' \
    FICUS_ARTIFACT_SIG_URL='https://example.test/manifest.sig' \
    FICUS_ARTIFACT_PUBKEY_B64='ZZZ-PUBKEY-B64-ZZZ' \
    bash "${SCRIPT_DIR}/provision.sh" --config "${PROV_TMP}/exe.yaml" >/dev/null
  githttps_secrets=$(cat "${PROV_TMP}/scp-capture-githttps/secrets.env" 2>/dev/null || true)
  expect_eq 'source.mode=git-https: secrets.env still forwards GH_TOKEN' \
    "$(grep -c '^GH_TOKEN=' <<<"${githttps_secrets}" || true)" '1'
  for artifact_env_name in FICUS_ARTIFACT_TARBALL_URL FICUS_ARTIFACT_MANIFEST_URL FICUS_ARTIFACT_SIG_URL FICUS_ARTIFACT_PUBKEY_B64; do
    expect_eq "source.mode=git-https: secrets.env does NOT forward ${artifact_env_name}" \
      "$(grep -c "^${artifact_env_name}=" <<<"${githttps_secrets}" || true)" '0'
  done

  unset -f fake_do_http_terminal ssh scp _prov_parse_http_argv
  rm -rf "${PROV_TMP}"
else
  log_warn "mikefarah yq not on PATH — skipping provision.sh integration tests"
fi

# --- restore_unpack_archive / restore_home_subdir ---------------------------
# A miniature backup envelope, encrypted with the SAME openssl params
# tau-backup.sh.tmpl uses (aes-256-cbc, pbkdf2), round-tripped to prove the
# restore path can open a real backup and that the envelope-shape guards fire.
# The passphrase embeds a space AND a '&' — the presigned-URL/DSN metacharacter
# — to confirm `-pass file:` carries it verbatim.
RESTORE_TMP=$(mktemp -d)
RESTORE_PASS='corr3ct h0rse & battery'
mkdir -p "${RESTORE_TMP}/src/.tau/agents"
printf 'PGDUMPDATA' >"${RESTORE_TMP}/src/db.dump"
printf 'FICUS_ENCRYPTION_KEY=deadbeef\nAPP_URL=https://old.example\n' >"${RESTORE_TMP}/src/.env"
printf 'workspace-file\n' >"${RESTORE_TMP}/src/.tau/agents/a.txt"
# Same top-level member layout tau-backup.sh.tmpl produces: db.dump, the
# HOME_DIR tree, and .env.
tar -czf "${RESTORE_TMP}/backup.tar.gz" \
  -C "${RESTORE_TMP}/src" db.dump \
  -C "${RESTORE_TMP}/src" .tau \
  -C "${RESTORE_TMP}/src" .env
RESTORE_PASSFILE="${RESTORE_TMP}/pass"
printf '%s' "${RESTORE_PASS}" >"${RESTORE_PASSFILE}"
openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:${RESTORE_PASSFILE}" \
  -in "${RESTORE_TMP}/backup.tar.gz" -out "${RESTORE_TMP}/backup.tar.gz.enc"

mkdir -p "${RESTORE_TMP}/out" && chmod 700 "${RESTORE_TMP}/out"
restore_unpack_archive "${RESTORE_TMP}/backup.tar.gz.enc" "${RESTORE_PASSFILE}" "${RESTORE_TMP}/out" 2>/dev/null
expect_eq 'restore_unpack_archive: db.dump extracted' "$(cat "${RESTORE_TMP}/out/db.dump")" 'PGDUMPDATA'
expect_match 'restore_unpack_archive: .env extracted (carries the encryption key)' \
  "$(cat "${RESTORE_TMP}/out/.env")" 'FICUS_ENCRYPTION_KEY=deadbeef'
expect_eq 'restore_unpack_archive: workspace tree extracted' \
  "$(cat "${RESTORE_TMP}/out/.tau/agents/a.txt")" 'workspace-file'
expect_eq 'restore_home_subdir: finds the sole workspace directory' \
  "$(restore_home_subdir "${RESTORE_TMP}/out")" "${RESTORE_TMP}/out/.tau"
# The encryption-key carry-forward seam phase_restore relies on.
expect_eq 'envfile_get pulls FICUS_ENCRYPTION_KEY from the restored .env (carry-forward seam)' \
  "$(envfile_get "${RESTORE_TMP}/out/.env" 'FICUS_ENCRYPTION_KEY')" 'deadbeef'

# Wrong passphrase: openssl bad-decrypt → die, extract nothing.
mkdir -p "${RESTORE_TMP}/out-bad" && chmod 700 "${RESTORE_TMP}/out-bad"
printf 'wrong-passphrase' >"${RESTORE_TMP}/pass-bad"
ru_rc=0
ru_err=$( (restore_unpack_archive "${RESTORE_TMP}/backup.tar.gz.enc" "${RESTORE_TMP}/pass-bad" "${RESTORE_TMP}/out-bad") 2>&1 >/dev/null ) || ru_rc=$?
expect_eq 'restore_unpack_archive: wrong passphrase dies' "${ru_rc}" '1'
expect_match 'restore_unpack_archive: wrong-passphrase message names decryption' "${ru_err}" 'decrypt'
expect_eq 'restore_unpack_archive: wrong passphrase extracts no db.dump' \
  "$([[ -e ${RESTORE_TMP}/out-bad/db.dump ]] && echo present || echo absent)" 'absent'

# RED-GREEN envelope-shape guard: an archive with no db.dump is rejected.
mkdir -p "${RESTORE_TMP}/nodump-src"
printf 'x\n' >"${RESTORE_TMP}/nodump-src/.env"
tar -czf "${RESTORE_TMP}/nodump.tar.gz" -C "${RESTORE_TMP}/nodump-src" .env
openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:${RESTORE_PASSFILE}" \
  -in "${RESTORE_TMP}/nodump.tar.gz" -out "${RESTORE_TMP}/nodump.tar.gz.enc"
mkdir -p "${RESTORE_TMP}/out-nodump" && chmod 700 "${RESTORE_TMP}/out-nodump"
rn_rc=0
rn_err=$( (restore_unpack_archive "${RESTORE_TMP}/nodump.tar.gz.enc" "${RESTORE_PASSFILE}" "${RESTORE_TMP}/out-nodump") 2>&1 >/dev/null ) || rn_rc=$?
expect_eq 'restore_unpack_archive: missing db.dump dies (envelope-shape guard)' "${rn_rc}" '1'
expect_match 'restore_unpack_archive: missing-db.dump message says not a tau envelope' "${rn_err}" 'db.dump'

rm -rf "${RESTORE_TMP}"

# --- install_rendered --------------------------------------------------------
# The staged render → verify → install path. A live tenant provision once
# piped a failed sed straight into `as_root tee`, installing a 0-byte
# tau-backup.service that daemon-reload accepted silently — these tests pin
# the guards that make that impossible. as_root is stubbed to plain execution
# (no sudo in tests); the closing `source` restores the real one.
as_root() { "$@"; }
# GNU stat and BSD (macOS) stat spell the mode differently, and a bare `stat -c`
# fails on macOS — inside `x=$( ... )` under `set -e` that ends the whole runner
# before it prints a summary. Every mode check in this file goes through here.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
IR_TMP=$(mktemp -d)
IR_DEST="${IR_TMP}/rendered.out"
IR_TMPL="${IR_TMP}/unit.tmpl"
printf 'User=@RUN_USER@\nExecStart=@BUN_BIN@ run\n' >"${IR_TMPL}"
ir_render_good() { sed -e 's|@RUN_USER@|tau|g' -e 's|@BUN_BIN@|/usr/local/bin/bun|g' "${IR_TMPL}"; }
ir_render_unsubstituted() { sed -e 's|@NOT_IN_TEMPLATE@|x|g' "${IR_TMPL}"; } # sed "succeeds", markers survive
ir_render_empty() { :; }
ir_render_fail() { return 3; }

# Good render: lands with the requested mode and the rendered content.
(install_rendered --check-placeholders 0640 "$(id -un)" "$(id -gn)" "${IR_DEST}" ir_render_good) 2>/dev/null
expect_eq 'install_rendered: good render installs the rendered content' \
  "$(cat "${IR_DEST}")" $'User=tau\nExecStart=/usr/local/bin/bun run'
expect_eq 'install_rendered: good render installs with the requested mode' \
  "$(file_mode "${IR_DEST}")" '640'
rm -f "${IR_DEST}"

# Empty render: dies (exit 1), names the destination, installs NOTHING.
ir_rc=0
ir_err=$( (install_rendered 0644 "$(id -un)" "$(id -gn)" "${IR_DEST}" ir_render_empty) 2>&1 >/dev/null ) || ir_rc=$?
expect_eq 'install_rendered: empty render dies' "${ir_rc}" '1'
expect_match 'install_rendered: empty-render message names the destination and the cause' \
  "${ir_err}" "refusing to install ${IR_DEST}.*empty"
expect_eq 'install_rendered: empty render installs nothing' \
  "$([[ -e ${IR_DEST} ]] && echo present || echo absent)" 'absent'

# Empty render over an EXISTING file: the previous good content survives —
# the exact regression a direct `> dest` / `| tee dest` cannot pass.
printf 'previous good content\n' >"${IR_DEST}"
ir_rc=0
(install_rendered 0644 "$(id -un)" "$(id -gn)" "${IR_DEST}" ir_render_empty) 2>/dev/null || ir_rc=$?
expect_eq 'install_rendered: empty render leaves an existing destination untouched' \
  "$(cat "${IR_DEST}")" 'previous good content'
rm -f "${IR_DEST}"

# A render whose sed matched nothing: exits 0, but the @PLACEHOLDER@ markers
# survive — with --check-placeholders that dies instead of installing.
ir_rc=0
ir_err=$( (install_rendered --check-placeholders 0644 "$(id -un)" "$(id -gn)" "${IR_DEST}" ir_render_unsubstituted) 2>&1 >/dev/null ) || ir_rc=$?
expect_eq 'install_rendered: unsubstituted @PLACEHOLDER@ markers die under --check-placeholders' "${ir_rc}" '1'
expect_match 'install_rendered: placeholder message names the destination' \
  "${ir_err}" "refusing to install ${IR_DEST}.*@PLACEHOLDER@"
expect_match 'install_rendered: the offending marker is shown' "${ir_err}" '@RUN_USER@'
expect_eq 'install_rendered: unsubstituted render installs nothing' \
  "$([[ -e ${IR_DEST} ]] && echo present || echo absent)" 'absent'

# Without --check-placeholders (env-style renders), `@…@` in a VALUE is legal
# content, not a marker — a DSN or S3 secret may contain it.
(install_rendered 0600 "$(id -un)" "$(id -gn)" "${IR_DEST}" printf 'SECRET=a@B@c\n') 2>/dev/null
expect_eq 'install_rendered: @…@ in values installs fine without --check-placeholders' \
  "$(cat "${IR_DEST}")" 'SECRET=a@B@c'
expect_eq 'install_rendered: env-style render lands 0600' "$(file_mode "${IR_DEST}")" '600'
rm -f "${IR_DEST}"

# A render command that FAILS dies too (not just empty output).
ir_rc=0
ir_err=$( (install_rendered 0644 "$(id -un)" "$(id -gn)" "${IR_DEST}" ir_render_fail) 2>&1 >/dev/null ) || ir_rc=$?
expect_eq 'install_rendered: failing render command dies' "${ir_rc}" '1'
expect_match 'install_rendered: failing-render message names the render command' \
  "${ir_err}" 'render command failed \(ir_render_fail\)'
expect_eq 'install_rendered: failing render installs nothing' \
  "$([[ -e ${IR_DEST} ]] && echo present || echo absent)" 'absent'

rm -rf "${IR_TMP}"

# --- core unit rendering (@DEST@ vs @RUN_ROOT@) ------------------------------
# The units carry TWO roots: the box install root (@DEST@ — where .env lives,
# in BOTH layouts) and the tree the services actually run from (@RUN_ROOT@ —
# <dest>/current once the box is on artifacts). Rendering both to the same
# value is exactly the bug this split exists to prevent: an artifact box whose
# WorkingDirectory never follows the flip keeps serving the old release.
CU_TMP=$(mktemp -d)
expect_eq 'core_run_root: a plain checkout runs from <dest>' \
  "$(core_run_root "${CU_TMP}")" "${CU_TMP}"
mkdir -p "${CU_TMP}/releases"
expect_eq 'core_run_root: a box with releases/ runs from <dest>/current' \
  "$(core_run_root "${CU_TMP}")" "${CU_TMP}/current"
rm -rf "${CU_TMP}/releases"
# shellcheck disable=SC2030 # the subshell scope IS the point: the override
# must not leak into the renders below.
expect_eq 'core_run_root: CORE_LAYOUT=artifact forces the artifact layout before releases/ exists' \
  "$( (CORE_LAYOUT=artifact; core_run_root "${CU_TMP}") )" "${CU_TMP}/current"

# render_core_unit reads caller globals, exactly as setup-host.sh/upgrade-host.sh
# supply them.
SRC_DEST="${CU_TMP}" RUN_USER=tau BUN_BIN=/usr/local/bin/bun DB_MODE=container
cu_api=$(render_core_unit "${SCRIPT_DIR}/systemd/tau-api.service.tmpl")
expect_eq 'render_core_unit: git layout runs from <dest>/apps/core' \
  "$(printf '%s\n' "${cu_api}" | grep -Fxc "WorkingDirectory=${CU_TMP}/apps/core")" '1'
expect_eq 'render_core_unit: git layout pins FICUS_ROOT to <dest>' \
  "$(printf '%s\n' "${cu_api}" | grep -Fxc "Environment=FICUS_ROOT=${CU_TMP}")" '1'
expect_eq 'render_core_unit: .env is read from <dest>, never from the run root' \
  "$(printf '%s\n' "${cu_api}" | grep -Fxc "EnvironmentFile=${CU_TMP}/.env")" '1'
expect_eq 'render_core_unit: the optional platform-managed env file survives the split' \
  "$(printf '%s\n' "${cu_api}" | grep -Fxc 'EnvironmentFile=-/etc/tau/managed.env')" '1'
expect_eq 'render_core_unit: no @PLACEHOLDER@ survives (install_rendered would refuse it)' \
  "$(printf '%s\n' "${cu_api}" | grep -c '@[A-Z_]*@' || true)" '0'
expect_eq 'render_core_unit: a container database adds the docker ordering' \
  "$(printf '%s\n' "${cu_api}" | grep -Fxc 'After=network-online.target docker.service')" '1'
# systemd applies EnvironmentFile= AFTER Environment= regardless of the order
# the lines appear in, so the unit's FICUS_ROOT does NOT win over one in .env —
# the line position below is cosmetic, and the real guard is setup-host.sh
# refusing a FICUS_ROOT through core.env (see the gate test).
expect_eq 'render_core_unit: the unit documents that EnvironmentFile overrides Environment' \
  "$(grep -Fc 'systemd applies EnvironmentFile= AFTER Environment=' "${SCRIPT_DIR}/systemd/tau-api.service.tmpl")" '1'

mkdir -p "${CU_TMP}/releases"
cu_api_art=$(render_core_unit "${SCRIPT_DIR}/systemd/tau-api.service.tmpl")
cu_worker_art=$(render_core_unit "${SCRIPT_DIR}/systemd/tau-worker.service.tmpl")
for cu_pair in "tau-api:${cu_api_art}" "tau-worker:${cu_worker_art}"; do
  cu_name=${cu_pair%%:*}
  cu_body=${cu_pair#*:}
  expect_eq "render_core_unit: ${cu_name} on the artifact layout runs from <dest>/current/apps/core" \
    "$(printf '%s\n' "${cu_body}" | grep -Fxc "WorkingDirectory=${CU_TMP}/current/apps/core")" '1'
  expect_eq "render_core_unit: ${cu_name} on the artifact layout pins FICUS_ROOT to <dest>/current" \
    "$(printf '%s\n' "${cu_body}" | grep -Fxc "Environment=FICUS_ROOT=${CU_TMP}/current")" '1'
  expect_eq "render_core_unit: ${cu_name} still reads <dest>/.env — a release carries no secrets" \
    "$(printf '%s\n' "${cu_body}" | grep -Fxc "EnvironmentFile=${CU_TMP}/.env")" '1'
done
DB_MODE=external
cu_api_ext=$(render_core_unit "${SCRIPT_DIR}/systemd/tau-api.service.tmpl")
expect_eq 'render_core_unit: an external database orders on network only' \
  "$(printf '%s\n' "${cu_api_ext}" | grep -Fxc 'After=network-online.target')" '1'
unset SRC_DEST RUN_USER BUN_BIN DB_MODE
rm -rf "${CU_TMP}"

# --- install_managed_env / install_artifacts -------------------------------
# Platform-managed artifact installs (the sync + provision landing functions).
# On the real (Linux, root) target these install 0600/mode-per-manifest files
# owned by root; here we run as a non-root macOS/CI user with no `root` group,
# so as_root is stubbed to run install(1) with the `-o`/`-g` ownership args
# STRIPPED (mode + content + atomicity are what these tests pin, not chown).
# FICUS_MANAGED_ENV_PATH / FICUS_ARTIFACTS_DIR are overridden so nothing touches
# the real /etc. The closing `source` restores the real as_root.
as_root() {
  if [[ ${1:-} == install ]]; then
    shift
    local args=()
    while (($#)); do
      case "$1" in
        -o | -g) shift 2 ;;
        *)
          args+=("$1")
          shift
          ;;
      esac
    done
    install "${args[@]}"
  else
    "$@"
  fi
}
AR_TMP=$(mktemp -d)
FICUS_MANAGED_ENV_PATH="${AR_TMP}/etc-tau/managed.env"
FICUS_ARTIFACTS_DIR="${AR_TMP}/etc-tau/artifacts"

# Staging dir with a managed.env and one file artifact.
AR_STAGE="${AR_TMP}/stage"
mkdir -p "${AR_STAGE}/files"
printf '# header\nSES_SMTP_PASSWORD=secret-value\n' >"${AR_STAGE}/managed.env"
printf 'APNS-CERT-BODY' >"${AR_STAGE}/files/apns.pem"
printf '0600 apns.pem\n' >"${AR_STAGE}/manifest"

install_managed_env "${AR_STAGE}"
expect_eq 'install_managed_env: installs managed.env content' \
  "$(cat "${FICUS_MANAGED_ENV_PATH}")" $'# header\nSES_SMTP_PASSWORD=secret-value'
expect_eq 'install_managed_env: managed.env lands 0600' "$(file_mode "${FICUS_MANAGED_ENV_PATH}")" '600'

install_artifacts "${AR_STAGE}"
expect_eq 'install_artifacts: installs the file body' \
  "$(cat "${FICUS_ARTIFACTS_DIR}/apns.pem")" 'APNS-CERT-BODY'
expect_eq 'install_artifacts: file lands with the manifest mode' \
  "$(file_mode "${FICUS_ARTIFACTS_DIR}/apns.pem")" '600'

# No managed.env in staging → install_managed_env is a no-op (dest untouched).
AR_STAGE2="${AR_TMP}/stage2"
mkdir -p "${AR_STAGE2}"
rm -f "${FICUS_MANAGED_ENV_PATH}"
install_managed_env "${AR_STAGE2}"
expect_eq 'install_managed_env: no managed.env in staging is a no-op' \
  "$([[ -e ${FICUS_MANAGED_ENV_PATH} ]] && echo present || echo absent)" 'absent'

# No manifest → install_artifacts is a no-op (existing artifacts untouched).
ar_before=$(ls "${FICUS_ARTIFACTS_DIR}")
install_artifacts "${AR_STAGE2}"
expect_eq 'install_artifacts: no manifest is a no-op' "$(ls "${FICUS_ARTIFACTS_DIR}")" "${ar_before}"

# Atomicity: a zero-byte managed.env is rejected by install_rendered and leaves
# any prior good file intact (never a truncating direct write).
printf 'GOOD=1\n' >"${FICUS_MANAGED_ENV_PATH}"
AR_STAGE3="${AR_TMP}/stage3"
mkdir -p "${AR_STAGE3}"
: >"${AR_STAGE3}/managed.env"
ar_rc=0
(install_managed_env "${AR_STAGE3}") 2>/dev/null || ar_rc=$?
expect_eq 'install_managed_env: empty managed.env dies' "${ar_rc}" '1'
expect_eq 'install_managed_env: empty managed.env leaves prior content intact' \
  "$(cat "${FICUS_MANAGED_ENV_PATH}")" 'GOOD=1'

# RED-GREEN guard: a manifest naming a path-traversal target is refused — an
# artifact may never escape the fixed /etc/tau/artifacts root.
AR_STAGE4="${AR_TMP}/stage4"
mkdir -p "${AR_STAGE4}/files"
printf 'escape' >"${AR_STAGE4}/files/x"
printf '0600 ../escape\n' >"${AR_STAGE4}/manifest"
ar_rc=0
ar_err=$( (install_artifacts "${AR_STAGE4}") 2>&1 >/dev/null ) || ar_rc=$?
expect_eq 'install_artifacts: unsafe (traversal) target dies' "${ar_rc}" '1'
expect_match 'install_artifacts: unsafe-target message names the offense' "${ar_err}" 'unsafe artifact target'

# --- managed_env_would_change ----------------------------------------------
# The sync restart driver: semantic change detection for managed.env.
AR_STAGE5="${AR_TMP}/stage5"
mkdir -p "${AR_STAGE5}"
expect_eq 'managed_env_would_change: no staged managed.env -> 0' \
  "$(managed_env_would_change "${AR_STAGE5}")" '0'

printf '# header\nKEY=v1\n' >"${AR_STAGE5}/managed.env"
printf '# header\nKEY=v1\n' >"${FICUS_MANAGED_ENV_PATH}"
expect_eq 'managed_env_would_change: identical dest -> 0' \
  "$(managed_env_would_change "${AR_STAGE5}")" '0'

printf '# header\nKEY=v2\n' >"${AR_STAGE5}/managed.env"
expect_eq 'managed_env_would_change: differing dest -> 1' \
  "$(managed_env_would_change "${AR_STAGE5}")" '1'

# Deletion case: the staged file SHRANK (env artifact removed) → changed.
printf '# header\n' >"${AR_STAGE5}/managed.env"
expect_eq 'managed_env_would_change: env deleted (header-only vs vars) -> 1' \
  "$(managed_env_would_change "${AR_STAGE5}")" '1'

# Absent dest + header-only staged file: loads zero vars either way — a
# semantic no-op that must NOT restart the fleet's services.
rm -f "${FICUS_MANAGED_ENV_PATH}"
expect_eq 'managed_env_would_change: absent dest + header-only staged -> 0' \
  "$(managed_env_would_change "${AR_STAGE5}")" '0'
printf '# header\nKEY=v1\n' >"${AR_STAGE5}/managed.env"
expect_eq 'managed_env_would_change: absent dest + staged vars -> 1' \
  "$(managed_env_would_change "${AR_STAGE5}")" '1'

# --- prune_artifacts --------------------------------------------------------
# The deletion half of reconciliation: files not in the manifest are removed,
# listed ones are kept, and everything stays inside FICUS_ARTIFACTS_DIR.
mkdir -p "${FICUS_ARTIFACTS_DIR}"
printf 'KEEP' >"${FICUS_ARTIFACTS_DIR}/apns.pem"
printf 'STALE' >"${FICUS_ARTIFACTS_DIR}/deleted-artifact.pem"
# A sibling OUTSIDE the artifacts dir (the database CA analogue) must survive.
printf 'CA' >"${AR_TMP}/etc-tau/database-ca.crt"
AR_STAGE6="${AR_TMP}/stage6"
mkdir -p "${AR_STAGE6}"
printf '0600 apns.pem\n' >"${AR_STAGE6}/manifest"
prune_artifacts "${AR_STAGE6}"
expect_eq 'prune_artifacts: manifest-listed file kept' \
  "$([[ -f ${FICUS_ARTIFACTS_DIR}/apns.pem ]] && echo present || echo absent)" 'present'
expect_eq 'prune_artifacts: unlisted file removed' \
  "$([[ -e ${FICUS_ARTIFACTS_DIR}/deleted-artifact.pem ]] && echo present || echo absent)" 'absent'
expect_eq 'prune_artifacts: sibling outside the artifacts dir untouched' \
  "$(cat "${AR_TMP}/etc-tau/database-ca.crt")" 'CA'

# Empty manifest = "no file artifact should exist": prunes the last one.
: >"${AR_STAGE6}/manifest"
prune_artifacts "${AR_STAGE6}"
expect_eq 'prune_artifacts: empty manifest prunes everything' \
  "$(ls "${FICUS_ARTIFACTS_DIR}" | wc -l | tr -d ' ')" '0'

# No manifest at all fails SAFE: set unknown → prune nothing.
printf 'X' >"${FICUS_ARTIFACTS_DIR}/survivor.pem"
AR_STAGE7="${AR_TMP}/stage7"
mkdir -p "${AR_STAGE7}"
prune_artifacts "${AR_STAGE7}"
expect_eq 'prune_artifacts: no manifest prunes nothing (fail-safe)' \
  "$([[ -f ${FICUS_ARTIFACTS_DIR}/survivor.pem ]] && echo present || echo absent)" 'present'

# --- ensure_managed_env_dropins ---------------------------------------------
# Pre-#689 units (no managed.env EnvironmentFile line) get a drop-in exactly
# once; post-#689 units (inline line) are left alone entirely.
FICUS_SYSTEMD_UNIT_DIR="${AR_TMP}/systemd"
mkdir -p "${FICUS_SYSTEMD_UNIT_DIR}"
printf '[Service]\nEnvironmentFile=/opt/tau-core/.env\n' >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
printf '[Service]\nEnvironmentFile=/opt/tau-core/.env\n' >"${FICUS_SYSTEMD_UNIT_DIR}/tau-worker.service"

ensure_managed_env_dropins
expect_eq 'ensure_managed_env_dropins: pre-#689 unit -> drop-in written + flagged' \
  "${MANAGED_ENV_DROPIN_CHANGED}" '1'
expect_eq 'ensure_managed_env_dropins: drop-in carries exactly the EnvironmentFile stanza' \
  "$(cat "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/managed-env.conf")" \
  $'[Service]\nEnvironmentFile=-/etc/tau/managed.env'
expect_eq 'ensure_managed_env_dropins: worker drop-in written too' \
  "$([[ -f ${FICUS_SYSTEMD_UNIT_DIR}/tau-worker.service.d/managed-env.conf ]] && echo present || echo absent)" 'present'

# Second run: drop-ins already correct → NOT flagged (no spurious daemon-reload).
ensure_managed_env_dropins
expect_eq 'ensure_managed_env_dropins: idempotent second run -> unflagged' \
  "${MANAGED_ENV_DROPIN_CHANGED}" '0'

# Post-#689 units already carry the line inline → nothing written, unflagged.
rm -rf "${FICUS_SYSTEMD_UNIT_DIR}"
mkdir -p "${FICUS_SYSTEMD_UNIT_DIR}"
printf '[Service]\nEnvironmentFile=/opt/tau-core/.env\nEnvironmentFile=-/etc/tau/managed.env\n' \
  >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
cp "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service" "${FICUS_SYSTEMD_UNIT_DIR}/tau-worker.service"
ensure_managed_env_dropins
expect_eq 'ensure_managed_env_dropins: inline-line unit -> no drop-in, unflagged' \
  "${MANAGED_ENV_DROPIN_CHANGED}" '0'
expect_eq 'ensure_managed_env_dropins: inline-line unit -> no drop-in dir created' \
  "$([[ -e ${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d ]] && echo present || echo absent)" 'absent'

# --- tau-api memory guardrail -----------------------------------------------
api_template="${SCRIPT_DIR}/systemd/tau-api.service.tmpl"
worker_template="${SCRIPT_DIR}/systemd/tau-worker.service.tmpl"
for directive in 'MemoryAccounting=yes' 'MemoryHigh=25%' 'MemoryMax=35%' \
  'OOMPolicy=kill' 'Restart=on-failure' 'RestartSec=5s' \
  'StartLimitIntervalSec=300s' 'StartLimitBurst=5'; do
  expect_eq "tau-api unit contains ${directive}" \
    "$(grep -Fxc "${directive}" "${api_template}" || true)" '1'
done
for directive in 'MemoryAccounting=' 'MemoryHigh=' 'MemoryMax=' 'OOMPolicy='; do
  expect_eq "tau-worker unit excludes ${directive}" \
    "$(grep -Fc "${directive}" "${worker_template}" || true)" '0'
done

rm -rf "${FICUS_SYSTEMD_UNIT_DIR}"
mkdir -p "${FICUS_SYSTEMD_UNIT_DIR}"
printf '[Service]\nRestart=on-failure\n' >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
printf '[Service]\n' >"${FICUS_SYSTEMD_UNIT_DIR}/tau-worker.service"
ensure_tau_api_memory_guardrail
expect_eq 'legacy api unit gets memory guardrail and changed flag' "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}" '1'
expected_guardrail=$'[Unit]\nStartLimitIntervalSec=300s\nStartLimitBurst=5\n\n[Service]\nMemoryAccounting=yes\nMemoryHigh=25%\nMemoryMax=35%\nOOMPolicy=kill\nRestart=on-failure\nRestartSec=5s'
expect_eq 'memory guardrail drop-in has exact canonical policy' \
  "$(cat "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf")" "${expected_guardrail}"
expect_eq 'worker never gets memory guardrail' \
  "$([[ -e ${FICUS_SYSTEMD_UNIT_DIR}/tau-worker.service.d/memory-guardrail.conf ]] && echo present || echo absent)" 'absent'
ensure_tau_api_memory_guardrail
expect_eq 'memory guardrail reconciliation is idempotent' "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}" '0'
printf '%s\n' "${expected_guardrail/MemoryMax=35%/MemoryMax=99%}" \
  >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf"
ensure_tau_api_memory_guardrail
expect_eq 'mutated MemoryMax is repaired and flagged' "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$(grep -Fxc 'MemoryMax=35%' "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf")" '1:1'
printf '%s\n' "${expected_guardrail/OOMPolicy=kill/OOMPolicy=continue}" \
  >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf"
ensure_tau_api_memory_guardrail
expect_eq 'mutated OOMPolicy is repaired and flagged' "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$(grep -Fxc 'OOMPolicy=kill' "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf")" '1:1'
printf '%s\n' "${expected_guardrail/Restart=on-failure/Restart=always}" \
  >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf"
ensure_tau_api_memory_guardrail
expect_eq 'mutated Restart is repaired and flagged' "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$(grep -Fxc 'Restart=on-failure' "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf")" '1:1'
printf '%s\nMemoryMax=infinity\n' "${expected_guardrail}" >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
ensure_tau_api_memory_guardrail
expect_eq 'later conflicting MemoryMax keeps canonical managed drop-in' \
  "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$(grep -Fxc 'MemoryMax=35%' "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf")" '0:1'
rm -rf "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d"
printf '[Service]\nStartLimitIntervalSec=300s\nStartLimitBurst=5\nMemoryAccounting=yes\nMemoryHigh=25%%\nMemoryMax=35%%\nOOMPolicy=kill\nRestart=on-failure\nRestartSec=5s\n' >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
ensure_tau_api_memory_guardrail
expect_eq 'unit directives in wrong section require canonical managed drop-in' \
  "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$([[ -f ${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf ]] && echo present || echo absent)" '1:present'

rm -rf "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d"
printf '%s\n' "${expected_guardrail}" >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service"
ensure_tau_api_memory_guardrail
expect_eq 'inline canonical policy needs no managed drop-in' \
  "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$([[ -e ${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/memory-guardrail.conf ]] && echo present || echo absent)" '0:absent'
mkdir -p "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d"
printf '[Service]\nMemoryMax=infinity\nOOMPolicy=continue\nRestart=no\n' >"${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/zzzzz-local.conf"
ensure_tau_api_memory_guardrail
ordered_guardrail=$(find "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d" -maxdepth 1 -name '*.z-tau-memory-guardrail.conf' -print)
expect_eq 'lexically later conflict installs a provably final managed policy and flags change' \
  "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}:$(tail -n 6 "${ordered_guardrail}" | tr '\n' ' ')" \
  '1:MemoryAccounting=yes MemoryHigh=25% MemoryMax=35% OOMPolicy=kill Restart=on-failure RestartSec=5s '
expect_eq 'lexically later conflicting unrelated drop-in is preserved' \
  "$(cat "${FICUS_SYSTEMD_UNIT_DIR}/tau-api.service.d/zzzzz-local.conf")" $'[Service]\nMemoryMax=infinity\nOOMPolicy=continue\nRestart=no'
ensure_tau_api_memory_guardrail
expect_eq 'dynamic final managed policy is idempotent on second run' "${FICUS_API_MEMORY_GUARDRAIL_CHANGED}" '0'
expect_eq 'dynamic managed filename sorts after the conflicting drop-in' \
  "$([[ $(basename "${ordered_guardrail}") > zzzzz-local.conf ]] && echo yes || echo no)" 'yes'


rm -rf "${AR_TMP}"
source "${SCRIPT_DIR}/lib.sh"

# Delivery paths must reconcile before reloading/restarting systemd.
for caller in setup-host.sh upgrade-host.sh; do
  guard_line=$(grep -n 'ensure_tau_api_memory_guardrail' "${SCRIPT_DIR}/${caller}" | head -1 | cut -d: -f1)
  action_line=$(grep -nE 'systemctl daemon-reload|restart_core_services' "${SCRIPT_DIR}/${caller}" | tail -1 | cut -d: -f1)
  expect_eq "${caller} reconciles api guardrail before service action" \
    "$([[ ${guard_line} -lt ${action_line} ]] && echo yes || echo no)" 'yes'
done
expect_eq 'apply-artifacts emits api guardrail marker after existing markers' \
  "$(tail -3 "${SCRIPT_DIR}/apply-artifacts.sh" | grep -c '^echo "FICUS_.*_CHANGED=' || true)" '3'

# --- setup-host.sh --dry-run: restore phase gating -------------------------
# The restore step must appear in the plan ONLY when FICUS_SETUP_RESTORE_URL is
# set, and a restore plan must NEVER print the presigned URL's query string
# (it is a credential). A non-restore dry-run must be byte-identical to before
# this feature — so the same config with no restore env vars must contain no
# 'restore' plan text at all.
if yq_is_mikefarah; then
  SH_TMP=$(mktemp -d)
  cat >"${SH_TMP}/restore.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
ai:
  provider: openai-codex
  key_env: ''
  model: openai-codex:gpt-5.5
provision:
  provider: digitalocean
  name: acme
EOF

  # With restore env set: Phase 3.5 present, URL query string absent.
  sh_restore_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    FICUS_SETUP_RESTORE_URL='https://s3.example.com/b/tenants/src/2026-08-01.tar.gz.enc?X-Amz-Signature=SECRETSIG&X-Amz-Expires=7200' \
    FICUS_SETUP_RESTORE_PASSPHRASE='pass' FICUS_SETUP_RESTORE_STRIP_CREDENTIALS=1 \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SH_TMP}/restore.yaml" --dry-run 2>/dev/null)
  expect_eq 'setup-host --dry-run: restore config includes the restore phase' \
    "$([[ ${sh_restore_out} == *'Phase 3.5 — restore from backup'* ]] && echo yes || echo no)" 'yes'
  expect_eq 'setup-host --dry-run: restore config includes the base URL (query stripped)' \
    "$([[ ${sh_restore_out} == *'https://s3.example.com/b/tenants/src/2026-08-01.tar.gz.enc'* ]] && echo yes || echo no)" 'yes'
  expect_eq 'setup-host --dry-run: the presigned URL query string (a credential) never appears' \
    "$([[ ${sh_restore_out} == *SECRETSIG* ]] && echo leaked || echo hidden)" 'hidden'
  expect_eq 'setup-host --dry-run: cross-subdomain restore mentions the credential strip' \
    "$([[ ${sh_restore_out} == *'DELETE FROM user_credentials'* ]] && echo yes || echo no)" 'yes'

  # Without restore env: no restore phase, no restore text at all.
  sh_plain_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SH_TMP}/restore.yaml" --dry-run 2>/dev/null)
  expect_eq 'setup-host --dry-run: non-restore config has no restore phase' \
    "$([[ ${sh_plain_out} == *'restore from backup'* ]] && echo present || echo absent)" 'absent'

  # The pre-rename spelling of each *_SETUP_* input still works (N-I7).
  sh_legacy_out=$(TAU_SETUP_DATABASE_DSN='postgres://u:p@h:5432/db' \
    TAU_SETUP_RESTORE_URL='https://s3.example.com/b/legacy.tar.gz.enc?X-Amz-Signature=SIG' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SH_TMP}/restore.yaml" --dry-run 2>/dev/null) # legacy-env
  expect_eq 'setup-host --dry-run: the TAU_SETUP_* spellings are still read (restore phase planned)' \
    "$([[ ${sh_legacy_out} == *'https://s3.example.com/b/legacy.tar.gz.enc'* ]] && echo yes || echo no)" 'yes'

  # PERMANENT fallback: an existing .env that predates the rename holds only
  # TAU_ENCRYPTION_KEY — the plan must read it ("existing"), never generate.
  mkdir -p "${SH_TMP}/dest"
  printf 'TAU_ENCRYPTION_KEY=old-key\nTAU_PASSWORD=old-pw\nTAU_INTERNAL_EVENT_TOKEN=old-tok\n' >"${SH_TMP}/dest/.env" # legacy-env
  yq -i ".source.dest = \"${SH_TMP}/dest\"" "${SH_TMP}/restore.yaml"
  sh_tau_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/db' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SH_TMP}/restore.yaml" --dry-run 2>/dev/null)
  expect_eq 'setup-host --dry-run: a TAU_-only .env encryption key is "existing", not generated' \
    "$(grep -c "FICUS_ENCRYPTION_KEY from: existing ${SH_TMP}/dest/.env" <<<"${sh_tau_out}")" '1'
  expect_eq 'setup-host --dry-run: ...and so are the password and event token' \
    "$(grep -c -e "FICUS_PASSWORD (bootstrap bearer) from: existing" -e "FICUS_INTERNAL_EVENT_TOKEN (api↔worker event transport) from: existing" <<<"${sh_tau_out}")" '2'
  expect_eq 'setup-host --dry-run: no secret is planned as generated' "$(grep -c 'from: generated' <<<"${sh_tau_out}" || true)" '0'
  # Ruling 24: both spellings with different keys stop even a dry run, naming
  # the key and never a value.
  printf 'FICUS_ENCRYPTION_KEY=other-key\n' >>"${SH_TMP}/dest/.env"
  sh_conflict_rc=0
  sh_conflict_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/db' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SH_TMP}/restore.yaml" --dry-run 2>&1) || sh_conflict_rc=$?
  expect_eq 'setup-host --dry-run: conflicting encryption keys stop the run' "${sh_conflict_rc}" '1'
  expect_match 'setup-host --dry-run: ...naming the key' "${sh_conflict_out}" 'TAU_ENCRYPTION_KEY and FICUS_ENCRYPTION_KEY disagree on this host'
  expect_eq 'setup-host --dry-run: ...never a value' "$(grep -c -e 'old-key' -e 'other-key' <<<"${sh_conflict_out}" || true)" '0'

  rm -rf "${SH_TMP}"
else
  log_warn "mikefarah yq not on PATH — skipping setup-host.sh restore dry-run tests"
fi

# --- setup-host.sh --dry-run: platform-managed artifacts phase -------------
# Phase 5.5 appears ONLY when artifacts.dir is set; the rendered units carry
# the optional managed.env EnvironmentFile line; and NO credential value ever
# reaches the plan output (only file names + modes from the manifest do).
if yq_is_mikefarah; then
  AH_TMP=$(mktemp -d)
  mkdir -p "${AH_TMP}/stage/files"
  printf '# header\nSES_SMTP_PASSWORD=TOPSECRETVALUE\n' >"${AH_TMP}/stage/managed.env"
  printf 'APNS' >"${AH_TMP}/stage/files/apns.pem"
  printf '0600 apns.pem\n' >"${AH_TMP}/stage/manifest"
  cat >"${AH_TMP}/base.yaml" <<EOF
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
ai:
  provider: openai-codex
  key_env: ''
  model: openai-codex:gpt-5.5
provision:
  provider: digitalocean
  name: acme
artifacts:
  dir: ${AH_TMP}/stage
EOF

  ah_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${AH_TMP}/base.yaml" --dry-run 2>/dev/null)
  expect_eq 'setup-host --dry-run: artifacts.dir set shows Phase 5.5' \
    "$([[ ${ah_out} == *'Phase 5.5 — platform-managed artifacts'* ]] && echo yes || echo no)" 'yes'
  expect_eq 'setup-host --dry-run: the managed.env credential VALUE is never printed' \
    "$([[ ${ah_out} == *TOPSECRETVALUE* ]] && echo leaked || echo hidden)" 'hidden'
  expect_eq 'setup-host --dry-run: the manifest file name + mode are shown' \
    "$([[ ${ah_out} == *'0600 apns.pem'* ]] && echo yes || echo no)" 'yes'
  expect_eq 'setup-host --dry-run: rendered units carry the optional managed.env EnvironmentFile line' \
    "$([[ ${ah_out} == *'EnvironmentFile=-/etc/tau/managed.env'* ]] && echo yes || echo no)" 'yes'

  # No artifacts.dir → no Phase 5.5 at all (byte-identical to before this feature).
  yq -i 'del(.artifacts)' "${AH_TMP}/base.yaml"
  ah_plain=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${AH_TMP}/base.yaml" --dry-run 2>/dev/null)
  expect_eq 'setup-host --dry-run: no artifacts.dir means no artifacts phase' \
    "$([[ ${ah_plain} == *'platform-managed artifacts'* ]] && echo present || echo absent)" 'absent'

  rm -rf "${AH_TMP}"
else
  log_warn "mikefarah yq not on PATH — skipping setup-host.sh artifacts dry-run tests"
fi

# --- seed.sh / setup-host.sh --dry-run: ai:/squad seeding becomes optional --
# Provision-time seeding (starter squad + AI provider account) is being
# replaced by the in-app onboarding checklist
# (docs/history/superpowers/plans/2026-08-05-onboarding-checklist.md, Task 4). The
# toolkit must keep working UNCHANGED for self-hosters who explicitly
# configure ai:/squad — but a config with neither section must provision
# cleanly and seed nothing (setup-host.sh must not die on the old
# unconditional `cfg_require '.ai.model'`).
if yq_is_mikefarah; then
  SEED_TMP=$(mktemp -d)

  # Config WITH explicit ai: + squad — self-hosters keep today's exact
  # behaviour. Uses an api-key provider (not openai-codex) so this also
  # exercises the AI key resolution / "AI provider key from:" plan line that
  # the old code ran unconditionally.
  cat >"${SEED_TMP}/full.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
ai:
  provider: openai
  key_env: ''
  model: openai:gpt-5.5
squad:
  name: starter
  purpose: first squad for the new tenant
  agent:
    type: engineer
    model: ''
EOF

  # Config with NEITHER section — the new opt-in default.
  cat >"${SEED_TMP}/minimal.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
EOF

  # -- seed.sh --dry-run directly: explicit ai:+squad keeps today's exact plan
  # lines (byte-identical format strings; only reached via the new presence
  # guard, which is true here).
  seed_full_out=$(env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    bash "${SCRIPT_DIR}/seed.sh" --config "${SEED_TMP}/full.yaml" --dry-run 2>/dev/null)
  expect_match 'seed.sh dry-run (explicit ai+squad): provider plan unchanged' \
    "${seed_full_out}" 'provider:       POST /api/provider-auth/openai/accounts \{key: \$OPENAI_API_KEY \(<empty>\), label: setup\}'
  expect_match 'seed.sh dry-run (explicit ai+squad): squad plan unchanged' \
    "${seed_full_out}" 'squad:          POST /api/squads \{name: starter, purpose: first squad for the new tenant\}'
  expect_match 'seed.sh dry-run (explicit ai+squad): agent plan unchanged, model falls back to ai.model' \
    "${seed_full_out}" 'agent:          POST /api/squads/<id>/spawn \{agentTypeId: engineer, model: openai:gpt-5.5\}'

  # -- seed.sh --dry-run directly: minimal config (no ai:, no squad.name)
  # reports both skipped and plans NO provider/squad/agent API call.
  seed_min_out=$(bash "${SCRIPT_DIR}/seed.sh" --config "${SEED_TMP}/minimal.yaml" --dry-run 2>/dev/null)
  expect_match 'seed.sh dry-run (no ai/squad): provider seeding reports skipped' \
    "${seed_min_out}" 'provider:       no ai.model in config — SKIP'
  expect_match 'seed.sh dry-run (no ai/squad): squad seeding reports skipped' \
    "${seed_min_out}" 'squad:          no squad.name in config — SKIP'
  expect_eq 'seed.sh dry-run (no ai/squad): no provider API call planned' \
    "$([[ ${seed_min_out} == *'POST /api/provider-auth'* ]] && echo present || echo absent)" 'absent'
  expect_eq 'seed.sh dry-run (no ai/squad): no squad-create API call planned' \
    "$([[ ${seed_min_out} == *'POST /api/squads {name:'* ]] && echo present || echo absent)" 'absent'
  expect_eq 'seed.sh dry-run (no ai/squad): no agent-spawn API call planned' \
    "$([[ ${seed_min_out} == *'POST /api/squads/<id>/spawn'* ]] && echo present || echo absent)" 'absent'

  # -- guard branches: the provider api_expect and the squad/agent api_expect
  # calls in seed.sh's EXECUTE path must sit lexically nested inside the
  # AI_SECTION_PRESENT / SQUAD_NAME presence guards (2-space indent under an
  # else branch), not run unconditionally — so a config with neither section
  # never reaches them, matching the dry-run plan above. Same technique as
  # the phase_step guard below (grep over the real source, not a description
  # of it).
  SEED_PROVIDER_BLOCK=$(mktemp)
  sed -n '/^# ---------------------------------------------------------------- provider$/,/^# ---------------------------------------------------------------- exe key$/p' \
    "${SCRIPT_DIR}/seed.sh" >"${SEED_PROVIDER_BLOCK}"
  expect_eq 'seed.sh: provider seeding is gated behind an AI_SECTION_PRESENT check' \
    "$(grep -cE '^if \[\[ \$\{AI_SECTION_PRESENT\} -eq 0 \]\]; then' "${SEED_PROVIDER_BLOCK}")" '1'
  expect_eq 'seed.sh: the provider-auth api_expect call is nested inside that guard' \
    "$(grep -cE '^[[:space:]]+api_expect GET "/api/provider-auth/\$\{AI_PROVIDER\}/accounts"' "${SEED_PROVIDER_BLOCK}")" '1'
  expect_eq 'seed.sh: no unguarded (top-level) provider-auth api_expect call' \
    "$(grep -cE '^api_expect.*provider-auth' "${SEED_PROVIDER_BLOCK}")" '0'
  rm -f "${SEED_PROVIDER_BLOCK}"

  SEED_SQUAD_BLOCK=$(mktemp)
  sed -n '/^# ---------------------------------------------------------------- squad$/,$p' \
    "${SCRIPT_DIR}/seed.sh" >"${SEED_SQUAD_BLOCK}"
  expect_eq 'seed.sh: squad/agent seeding is gated behind a SQUAD_NAME emptiness check' \
    "$(grep -cE '^if \[\[ -z \$\{SQUAD_NAME\} \]\]; then' "${SEED_SQUAD_BLOCK}")" '1'
  expect_eq 'seed.sh: the squad-create api_expect call is nested inside that guard' \
    "$(grep -cE "^[[:space:]]+api_expect POST '/api/squads'" "${SEED_SQUAD_BLOCK}")" '1'
  expect_eq 'seed.sh: the agent-spawn api_expect call is nested inside that guard' \
    "$(grep -cE '^[[:space:]]+api_expect POST "/api/squads/\$\{SQUAD_ID\}/spawn"' "${SEED_SQUAD_BLOCK}")" '1'
  expect_eq 'seed.sh: no unguarded (top-level) squad-create api_expect call' \
    "$(grep -cE "^api_expect POST '/api/squads'" "${SEED_SQUAD_BLOCK}")" '0'
  rm -f "${SEED_SQUAD_BLOCK}"

  # -- setup-host.sh --dry-run: minimal config (no ai:, no squad.name)
  # succeeds — it must NOT die on the old unconditional `.ai.model` require —
  # and its delegated Phase 7 (seed.sh --dry-run) reports both skipped.
  sh_min_rc=0
  sh_min_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SEED_TMP}/minimal.yaml" --dry-run 2>&1) || sh_min_rc=$?
  expect_eq 'setup-host --dry-run (no ai/squad): exits 0 (does not die on missing ai.model)' "${sh_min_rc}" '0'
  expect_match 'setup-host --dry-run (no ai/squad): delegated seed plan reports provider skipped' \
    "${sh_min_out}" 'provider:       no ai.model in config — SKIP'
  expect_match 'setup-host --dry-run (no ai/squad): delegated seed plan reports squad skipped' \
    "${sh_min_out}" 'squad:          no squad.name in config — SKIP'
  expect_eq 'setup-host --dry-run (no ai/squad): no "AI provider key from" plan line' \
    "$([[ ${sh_min_out} == *'AI provider key from:'* ]] && echo present || echo absent)" 'absent'

  # -- setup-host.sh --dry-run: explicit ai:+squad config is unchanged —
  # the "AI provider key from:" line still appears, and the delegated seed
  # plan still shows the real squad/agent creation calls.
  sh_full_out=$(env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SEED_TMP}/full.yaml" --dry-run 2>/dev/null)
  expect_match 'setup-host --dry-run (explicit ai+squad): AI provider key plan line unchanged' \
    "${sh_full_out}" 'AI provider key from: \$OPENAI_API_KEY \(unset — would prompt on a TTY, else fail\)'
  expect_match 'setup-host --dry-run (explicit ai+squad): delegated squad plan unchanged' \
    "${sh_full_out}" 'squad:          POST /api/squads \{name: starter, purpose: first squad for the new tenant\}'

  # -- CRITICAL regression: presence must key off ai.model, NOT ai.provider.
  # ai.provider has its own non-empty default ('openai'), so a config that
  # sets ONLY ai.model (relying on that default, exactly like the config
  # this toolkit required pre-change) must still seed a provider account —
  # not silently skip because ai.provider was never written down.
  cat >"${SEED_TMP}/partial-ai.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
ai:
  model: openai:gpt-5.5
EOF
  seed_partial_ai_out=$(env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    bash "${SCRIPT_DIR}/seed.sh" --config "${SEED_TMP}/partial-ai.yaml" --dry-run 2>/dev/null)
  expect_match 'seed.sh dry-run (ai.model set, ai.provider omitted): still plans provider seeding (defaults to openai)' \
    "${seed_partial_ai_out}" 'provider:       POST /api/provider-auth/openai/accounts \{key: \$OPENAI_API_KEY \(<empty>\), label: setup\}'
  expect_eq 'seed.sh dry-run (ai.model set, ai.provider omitted): provider is NOT reported skipped' \
    "$([[ ${seed_partial_ai_out} == *'no ai.model in config — SKIP'* ]] && echo skipped || echo seeded)" 'seeded'

  # Same partial config through setup-host.sh: must not die on `.ai.model`,
  # and its delegated plan must show the same real provider POST (not the
  # old cfg_require unconditional AI_MODEL, and not a false "no ai.model"
  # skip driven off the ai.provider default).
  sh_partial_ai_rc=0
  sh_partial_ai_out=$(env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SEED_TMP}/partial-ai.yaml" --dry-run 2>&1) || sh_partial_ai_rc=$?
  expect_eq 'setup-host --dry-run (ai.model set, ai.provider omitted): exits 0' "${sh_partial_ai_rc}" '0'
  expect_match 'setup-host --dry-run (ai.model set, ai.provider omitted): AI provider key plan line present (section counted as configured)' \
    "${sh_partial_ai_out}" 'AI provider key from: \$OPENAI_API_KEY \(unset — would prompt on a TTY, else fail\)'
  expect_match 'setup-host --dry-run (ai.model set, ai.provider omitted): delegated seed plan still seeds the provider' \
    "${sh_partial_ai_out}" 'provider:       POST /api/provider-auth/openai/accounts'

  # -- Important: squad.name configured with no ai: (and no explicit
  # squad.agent.model) must die EARLY with a clear message, not deep inside
  # api_expect's raw-400 handling when the spawn call actually fires.
  cat >"${SEED_TMP}/squad-only.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
squad:
  name: starter
EOF
  seed_squad_only_rc=0
  seed_squad_only_err=$(bash "${SCRIPT_DIR}/seed.sh" --config "${SEED_TMP}/squad-only.yaml" --dry-run 2>&1 >/dev/null) ||
    seed_squad_only_rc=$?
  expect_eq 'seed.sh (squad.name set, no ai:, no squad.agent.model): dies (non-zero exit)' \
    "$([[ ${seed_squad_only_rc} -ne 0 ]] && echo dies || echo succeeds)" 'dies'
  expect_match 'seed.sh (squad.name set, no ai:, no squad.agent.model): error names the missing model, not a raw API 400' \
    "${seed_squad_only_err}" 'squad.name is set .*but no model is configured for its agent'
  expect_eq 'seed.sh (squad.name set, no ai:, no squad.agent.model): never reaches api_expect (no HTTP status in the error)' \
    "$([[ ${seed_squad_only_err} == *'returned HTTP'* ]] && echo reached-api || echo failed-early)" 'failed-early'

  # The same config through setup-host.sh --dry-run: Phase 7 delegates to
  # seed.sh --dry-run, so the early die must propagate (set -e) rather than
  # being swallowed by a plan that claims success.
  sh_squad_only_rc=0
  bash "${SCRIPT_DIR}/setup-host.sh" --config "${SEED_TMP}/squad-only.yaml" --dry-run >/dev/null 2>&1 ||
    sh_squad_only_rc=$?
  expect_eq 'setup-host --dry-run (squad.name set, no ai:): the delegated die propagates (non-zero exit)' \
    "$([[ ${sh_squad_only_rc} -ne 0 ]] && echo dies || echo succeeds)" 'dies'

  cat >"${SEED_TMP}/codex-openai-mismatch.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.hiretau.ai
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
ai:
  provider: openai-codex
  key_env: ''
  model: openai:gpt-5.5
provision:
  provider: digitalocean
  name: acme
EOF

  codex_openai_rc=0
  codex_openai_out=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${SEED_TMP}/codex-openai-mismatch.yaml" --dry-run 2>&1) ||
    codex_openai_rc=$?
  expect_eq 'setup rejects openai model under openai-codex auth namespace' "${codex_openai_rc}" '1'
  expect_match 'setup explains distinct openai auth namespaces' \
    "${codex_openai_out}" 'openai and openai-codex are distinct'

  rm -rf "${SEED_TMP}"
else
  log_warn "mikefarah yq not on PATH — skipping seed.sh/setup-host.sh optional-seeding tests"
fi

# --- upgrade-host.sh mode selection (artifact vs git) -----------------------
# Runs the real script: both branches die before anything on the host is
# touched, which is exactly what makes them safe to exercise here.
if yq_is_mikefarah; then
  UH_TMP=$(mktemp -d)
  cat >"${UH_TMP}/tau-setup.yaml" <<EOF
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
  dest: ${UH_TMP}/no-such-checkout
core:
  origin: https://tau.example.com
  port: 3000
EOF
  # SOME artifact inputs but not all: a delivery bug. Falling back to a source
  # build here would rebuild from git while the control plane records that it
  # shipped a verified artifact.
  uh_rc=0
  uh_out=$(FICUS_ARTIFACT_TARBALL_URL=https://example.invalid/t.tgz FICUS_ARTIFACT_SIG_URL=https://example.invalid/s \
    bash "${SCRIPT_DIR}/upgrade-host.sh" --config "${UH_TMP}/tau-setup.yaml" 2>&1) || uh_rc=$?
  expect_eq 'upgrade-host: a PARTIAL FICUS_ARTIFACT_* set dies' "${uh_rc}" '1'
  expect_match 'upgrade-host: the partial-set message refuses the source-build fallback' \
    "${uh_out}" 'refusing to fall back to a source build'
  expect_match 'upgrade-host: the partial-set message names a missing input' \
    "${uh_out}" 'FICUS_ARTIFACT_MANIFEST_URL'
  expect_eq 'upgrade-host: a partial set never reaches the git flow' \
    "$(grep -c 'is not a git checkout' <<<"${uh_out}" || true)" '0'
  # NO artifact inputs at all is plain git mode — which still refuses to run
  # against a dest that is not a checkout.
  uh_rc=0
  uh_out=$(ENV_RENAME_BACKUP_ROOT="${UH_TMP}/bk" bash "${SCRIPT_DIR}/upgrade-host.sh" --config "${UH_TMP}/tau-setup.yaml" 2>&1) || uh_rc=$?
  expect_eq 'upgrade-host: no artifact inputs = git mode' "${uh_rc}" '1'
  expect_match 'upgrade-host: git mode still requires a checkout at source.dest' \
    "${uh_out}" 'is not a git checkout — nothing to upgrade'
  rm -rf "${UH_TMP}"
else
  log_warn 'skipping the upgrade-host.sh mode-selection tests — mikefarah yq not available'
fi

# --- core release artifacts (acquire / stage / activate / retention) --------
#
# Behavioural coverage for the artifact_* helpers, driven against a REAL
# fixture: an Ed25519 keypair generated with openssl, a small artifact tree, a
# manifest whose per-file hashes and digest are computed exactly the way
# scripts/artifact/lib/manifest.ts computes them (sorted files map, sha256 over
# its canonical JSON), a real signature over the manifest bytes, a real gzip
# tarball — all served over file:// URLs, which curl speaks, so no test HTTP
# server is needed. The structural guard over the same code (verify ORDER, the
# flip recipe, the migrate env) lives in
# the managed artifact contract
#
# These helpers target Ubuntu: GNU coreutils (`mv -T`, `sha256sum -c`) and
# OpenSSL 3 (`pkeyutl -rawin`; LibreSSL cannot verify a raw Ed25519 signature
# at all). A macOS dev box has neither by default, so this section runs against
# a shim directory that puts GNU/OpenSSL-3 equivalents first on PATH — the same
# GNU/BSD accommodation file_mtime makes for stat(1) — and skips itself with a
# warning when they are not installed (the yq precedent).

# --- pure helpers (no toolchain needed) ---
expect_eq 'artifact_release_dir: <dest>/releases/<sha>-<digest12>' \
  "$(artifact_release_dir /opt/tau-core 1111111111111111111111111111111111111111 0123456789ab)" \
  '/opt/tau-core/releases/1111111111111111111111111111111111111111-0123456789ab'
expect_eq 'artifact_digest12: the first 12 hex of a sha256: digest' \
  "$(artifact_digest12 "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")" '0123456789ab'
expect_eq 'artifact_emit_release_trailer: the two lines the control plane parses' \
  "$(artifact_emit_release_trailer 'git-deadbeef' '1111-2222' | tr '\n' ' ')" \
  'FICUS_RELEASE_BEFORE=git-deadbeef FICUS_RELEASE_AFTER=1111-2222 '
ART_ID_TMP=$(mktemp -d)
expect_eq 'artifact_current_release_id: neither a release symlink nor a checkout -> unknown' \
  "$(artifact_current_release_id "${ART_ID_TMP}")" 'unknown'
mkdir -p "${ART_ID_TMP}/releases/abc-123"
ln -sfn "${ART_ID_TMP}/releases/abc-123" "${ART_ID_TMP}/current"
expect_eq 'artifact_current_release_id: reads the release id through current' \
  "$(artifact_current_release_id "${ART_ID_TMP}")" 'abc-123'
rm -rf "${ART_ID_TMP}"

# --- toolchain shim (or skip) ---
ART_SKIP=''
ART_OPENSSL=''
ART_PATH_BEFORE=${PATH}
ART_SHIM=$(mktemp -d)
if mv --version 2>/dev/null | grep -q 'GNU coreutils'; then
  : # already GNU
elif have gmv; then
  ln -sfn "$(command -v gmv)" "${ART_SHIM}/mv"
else
  ART_SKIP='GNU mv (needs -T)'
fi
if sha256sum --version 2>/dev/null | grep -q 'GNU coreutils'; then
  : # already GNU
elif have gsha256sum; then
  ln -sfn "$(command -v gsha256sum)" "${ART_SHIM}/sha256sum"
else
  ART_SKIP=${ART_SKIP:-'GNU sha256sum (needs -c --strict)'}
fi
if openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  ART_OPENSSL=$(command -v openssl)
else
  for art_cand in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    if [[ -x ${art_cand} ]] && "${art_cand}" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
      ART_OPENSSL=${art_cand}
      ln -sfn "${ART_OPENSSL}" "${ART_SHIM}/openssl"
      break
    fi
  done
fi
[[ -n ${ART_OPENSSL} ]] || ART_SKIP=${ART_SKIP:-'OpenSSL 3 (pkeyutl -rawin)'}
for art_cmd in python3 jq bun curl tar; do
  have "${art_cmd}" || ART_SKIP=${ART_SKIP:-"${art_cmd}"}
done

if [[ -n ${ART_SKIP} ]]; then
  log_warn "skipping the core release artifact tests — ${ART_SKIP} not available"
else
  PATH="${ART_SHIM}:${PATH}"
  ART_TMP=$(mktemp -d)
  ART_BUN=$(bun --version | tr -d '[:space:]')
  ART_SHA_A='1111111111111111111111111111111111111111'
  ART_SHA_B='2222222222222222222222222222222222222222'
  ART_SHA_C='3333333333333333333333333333333333333333'
  ART_SHA_D='4444444444444444444444444444444444444444'

  # The manifest builder, replicating scripts/artifact/lib/manifest.ts:
  # sha256 per file (root artifact.json excluded from its own map), keys sorted,
  # digest = sha256 of the canonical (separator-free) JSON of that map.
  cat >"${ART_TMP}/manifest.py" <<'PYEOF'
import hashlib, json, os, sys

root, commit, commit_date, bun_version, builder = sys.argv[1:6]
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
manifest = {
    "schema": 1,
    "commit": commit,
    "commitDate": commit_date,
    "bun": bun_version,
    "platform": "linux-x64",
    "builder": builder,
    "files": files,
    "digest": digest,
}
sys.stdout.write(json.dumps(manifest, indent=2) + "\n")
PYEOF

  "${ART_OPENSSL}" genpkey -algorithm ed25519 -out "${ART_TMP}/key.pem" 2>/dev/null
  "${ART_OPENSSL}" pkey -in "${ART_TMP}/key.pem" -pubout -out "${ART_TMP}/pub.pem" 2>/dev/null
  # A second, unrelated key: proves the signature check is a real check and not
  # "any well-formed signature passes".
  "${ART_OPENSSL}" genpkey -algorithm ed25519 -out "${ART_TMP}/other-key.pem" 2>/dev/null

  art_tree() { printf '%s/staging/tau-core-%s\n' "$1" "$2"; }

  # A miniature core release tree: the migration runner activate executes, the
  # CLI bundle (exec bit must survive the tarball round-trip) and a config file.
  art_make_tree() { # WORK SHA
    local tree
    tree=$(art_tree "$1" "$2")
    mkdir -p "${tree}/apps/core/dist" "${tree}/apps/cli/dist" "${tree}/config" "${1}/dist"
    cat >"${tree}/apps/core/dist/migrate.js" <<'JSEOF'
const fs = require('node:fs')
fs.writeFileSync(
  process.env.MIGRATE_PROOF,
  `FICUS_ROOT=${process.env.FICUS_ROOT}\nTAU_ROOT=${process.env.TAU_ROOT}\nFICUS_MIGRATE_LIVE=${process.env.FICUS_MIGRATE_LIVE}\nTAU_MIGRATE_LIVE=${process.env.TAU_MIGRATE_LIVE}\nDATABASE_URL=${process.env.DATABASE_URL}\nCWD=${process.cwd()}\nPW=${process.env.PW}\n`,
)
JSEOF
    printf '#!/usr/bin/env bun\nconsole.log("tau")\n' >"${tree}/apps/cli/dist/tau.js"
    chmod 755 "${tree}/apps/cli/dist/tau.js"
    printf 'agent: fixture\n' >"${tree}/config/agent.yaml"
  }

  # NOTE: on a macOS dev box this is bsdtar; production runs GNU tar. The
  # helpers only use flags both implement (-tzf/-xzf, --no-same-owner,
  # --no-same-permissions), but a tar-behaviour claim proven here is proven
  # about bsdtar — the guards below are written to not depend on either one's
  # extraction quirks, which is the point of listing members before extracting.
  art_tar() { # WORK SHA
    tar -C "${1}/staging" -czf "${1}/dist/tau-core-${2}-linux-x64.tar.gz" "tau-core-${2}"
  }

  # Repack a tarball with one extra member under an arbitrary (hostile) name.
  cat >"${ART_TMP}/repack.py" <<'PYREPACK'
import io, sys, tarfile

src, dst, extra_name = sys.argv[1:4]
with tarfile.open(src, "r:gz") as tin, tarfile.open(dst, "w:gz") as tout:
    for member in tin.getmembers():
        tout.addfile(member, tin.extractfile(member) if member.isfile() else None)
    payload = b"pwned\n"
    info = tarfile.TarInfo(extra_name)
    info.size = len(payload)
    tout.addfile(info, io.BytesIO(payload))
PYREPACK

  # Manifest the tree as it stands, copy the manifest into the tree (P1 writes
  # both), sign the manifest BYTES, and tar it up.
  art_seal() { # WORK SHA BUN_VERSION
    local tree
    tree=$(art_tree "$1" "$2")
    python3 "${ART_TMP}/manifest.py" "${tree}" "$2" '2026-08-25T00:00:00Z' "$3" 'test:fixture' >"${1}/dist/artifact.json"
    cp "${1}/dist/artifact.json" "${tree}/artifact.json"
    "${ART_OPENSSL}" pkeyutl -sign -inkey "${ART_TMP}/key.pem" -rawin \
      -in "${1}/dist/artifact.json" -out "${1}/dist/artifact.sig.raw"
    base64 <"${1}/dist/artifact.sig.raw" >"${1}/dist/artifact.sig"
    art_tar "$1" "$2"
  }

  # A whole publishable artifact in a fresh work dir.
  art_publish() { # WORK SHA BUN_VERSION
    mkdir -p "$1/staging" "$1/dist"
    art_make_tree "$1" "$2"
    art_seal "$1" "$2" "$3"
  }

  # How many session dirs the acquire staging area still holds.
  art_incoming_count() { # DEST
    { find "${1}/releases/.incoming" -mindepth 1 -maxdepth 1 2>/dev/null || true; } | wc -l | tr -d ' '
  }

  # --- the box under test ---
  ART_DEST=$(mktemp -d)/tau-core
  mkdir -p "${ART_DEST}"
  ART_PROOF="${ART_TMP}/migrate-proof.txt"
  # FICUS_ROOT in the .env is deliberate: activate must pin the CANDIDATE, not
  # whatever the box's environment file claims.
  printf 'DATABASE_URL=postgres://fixture/db\nMIGRATE_PROOF=%s\nFICUS_ROOT=/should/never/win\n' \
    "${ART_PROOF}" >"${ART_DEST}/.env"

  ART_CALLS="${ART_TMP}/calls.log"
  : >"${ART_CALLS}"
  as_root() { printf 'as_root %s\n' "$*" >>"${ART_CALLS}"; }
  restart_core_services() {
    printf 'restart %s\n' "$1" >>"${ART_CALLS}"
    if [[ -f ${ART_TMP}/restart-fails ]]; then
      # Fail exactly once: the rollback restart that follows must succeed, so
      # the test can tell "rolled back and recovered" from "died twice".
      rm -f "${ART_TMP}/restart-fails"
      die 'fake restart_core_services: core API failed to start'
    fi
  }

  # --- happy path: acquire ---
  ART_WORK_A="${ART_TMP}/work-a"
  art_publish "${ART_WORK_A}" "${ART_SHA_A}" "${ART_BUN}"
  ART_RC=0
  ART_OUT_A=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_A}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_A}/dist/artifact.json" \
    "file://${ART_WORK_A}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a good artifact verifies (exit 0)' "${ART_RC}" '0'
  ART_LINE1=$(printf '%s\n' "${ART_OUT_A}" | sed -n 1p)
  ART_TREE_A=$(printf '%s\n' "${ART_OUT_A}" | sed -n 2p)
  ART_DIGEST12_A=$(printf '%s\n' "${ART_LINE1}" | awk '{print $2}')
  expect_eq 'artifact_acquire: line 1 is "<sha> <digest12>"' \
    "$(printf '%s\n' "${ART_LINE1}" | awk '{print $1, length($2)}')" "${ART_SHA_A} 12"
  expect_eq 'artifact_acquire: line 2 is the extracted tree' \
    "$([[ -f ${ART_TREE_A}/artifact.json ]] && echo tree || echo missing)" 'tree'
  expect_eq 'artifact_acquire: the tarball round-trip preserves exec bits' \
    "$([[ -x ${ART_TREE_A}/apps/cli/dist/tau.js ]] && echo executable || echo plain)" 'executable'
  expect_eq 'artifact_acquire: prints nothing else on stdout (2 lines exactly)' \
    "$(printf '%s\n' "${ART_OUT_A}" | wc -l | tr -d ' ')" '2'

  # --- stage ---
  ART_RELEASE_A=$(artifact_release_dir "${ART_DEST}" "${ART_SHA_A}" "${ART_DIGEST12_A}")
  artifact_stage "${ART_DEST}" "${ART_TREE_A}" "${ART_SHA_A}" "${ART_DIGEST12_A}" 2>/dev/null
  expect_eq 'artifact_stage: the release lands at releases/<sha>-<digest12>' \
    "$([[ -f ${ART_RELEASE_A}/apps/core/dist/migrate.js ]] && echo staged || echo missing)" 'staged'
  expect_eq 'artifact_stage: writes the .tau-release-complete marker' \
    "$([[ -f ${ART_RELEASE_A}/.tau-release-complete ]] && echo marked || echo unmarked)" 'marked'
  expect_match 'artifact_stage: the marker records what was staged' \
    "$(<"${ART_RELEASE_A}/.tau-release-complete")" "\"sha\":\"${ART_SHA_A}\".*\"digest\":\"sha256:[0-9a-f]{64}\""
  expect_eq 'artifact_stage: the incoming session dir is cleaned up' \
    "$(art_incoming_count "${ART_DEST}")" '0'

  # --- activate (first release: nothing to roll back to) ---
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_DEST}" "${ART_RELEASE_A}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: a healthy activation exits 0' "${ART_RC}" '0'
  expect_eq 'artifact_activate: reports FICUS_RELEASE_ROLLED_BACK=0' "${ART_ACT_OUT}" 'FICUS_RELEASE_ROLLED_BACK=0'
  expect_eq 'artifact_activate: current points at the new release' \
    "$(readlink "${ART_DEST}/current")" "${ART_RELEASE_A}"
  expect_eq 'artifact_activate: no previous on a first activation' \
    "$([[ -e ${ART_DEST}/previous ]] && echo present || echo absent)" 'absent'
  expect_match 'artifact_activate: the migrate ran with FICUS_ROOT pinned to the CANDIDATE' \
    "$(<"${ART_PROOF}")" "FICUS_ROOT=${ART_RELEASE_A}"
  # A pre-rename candidate reads the TAU_ spellings (run-migrations.ts,
  # paths.ts), so the migrate gets both, per invocation.
  expect_match 'artifact_activate: the migrate also got TAU_ROOT = the candidate' \
    "$(<"${ART_PROOF}")" "TAU_ROOT=${ART_RELEASE_A}"
  expect_match 'artifact_activate: the migrate got FICUS_MIGRATE_LIVE=1' "$(<"${ART_PROOF}")" 'FICUS_MIGRATE_LIVE=1'
  expect_match 'artifact_activate: the migrate got TAU_MIGRATE_LIVE=1' "$(<"${ART_PROOF}")" 'TAU_MIGRATE_LIVE=1'
  expect_match 'artifact_activate: the migrate got the DB env from <dest>/.env' \
    "$(<"${ART_PROOF}")" 'DATABASE_URL=postgres://fixture/db'
  # Matched on the release directory's NAME, not its absolute path: macOS
  # resolves /var -> /private/var when a process cd's, so the recorded cwd is
  # the physical path of the same directory.
  expect_match 'artifact_activate: the migrate ran from the candidate apps/core' \
    "$(<"${ART_PROOF}")" "CWD=.*/$(basename "${ART_RELEASE_A}")/apps/core"
  expect_match 'artifact_activate: systemd was reloaded before the restart' \
    "$(<"${ART_CALLS}")" 'as_root systemctl daemon-reload'
  expect_match 'artifact_activate: the services were restarted on the core port' \
    "$(<"${ART_CALLS}")" 'restart 3000'

  # --- a second release: previous starts tracking the old current ---
  ART_WORK_B="${ART_TMP}/work-b"
  art_publish "${ART_WORK_B}" "${ART_SHA_B}" "${ART_BUN}"
  ART_RC=0
  ART_OUT_B=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_B}/dist/tau-core-${ART_SHA_B}-linux-x64.tar.gz" \
    "file://${ART_WORK_B}/dist/artifact.json" \
    "file://${ART_WORK_B}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_DIGEST12_B=$(printf '%s\n' "${ART_OUT_B}" | sed -n 1p | awk '{print $2}')
  ART_TREE_B=$(printf '%s\n' "${ART_OUT_B}" | sed -n 2p)
  ART_RELEASE_B=$(artifact_release_dir "${ART_DEST}" "${ART_SHA_B}" "${ART_DIGEST12_B}")
  artifact_stage "${ART_DEST}" "${ART_TREE_B}" "${ART_SHA_B}" "${ART_DIGEST12_B}" 2>/dev/null
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_DEST}" "${ART_RELEASE_B}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: second activation exits 0' "${ART_RC}" '0'
  expect_eq 'artifact_activate: current follows the new release' \
    "$(readlink "${ART_DEST}/current")" "${ART_RELEASE_B}"
  expect_eq 'artifact_activate: previous now points at the release it displaced' \
    "$(readlink "${ART_DEST}/previous")" "${ART_RELEASE_A}"

  # --- stage idempotency: a complete release is never rebuilt in place ---
  printf 'sentinel\n' >"${ART_RELEASE_B}/.sentinel"
  ART_RC=0
  ART_OUT_B2=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_B}/dist/tau-core-${ART_SHA_B}-linux-x64.tar.gz" \
    "file://${ART_WORK_B}/dist/artifact.json" \
    "file://${ART_WORK_B}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_TREE_B2=$(printf '%s\n' "${ART_OUT_B2}" | sed -n 2p)
  ART_RC=0
  artifact_stage "${ART_DEST}" "${ART_TREE_B2}" "${ART_SHA_B}" "${ART_DIGEST12_B}" 2>/dev/null || ART_RC=$?
  expect_eq 'artifact_stage: re-staging a complete release succeeds' "${ART_RC}" '0'
  expect_eq 'artifact_stage: re-staging leaves the existing release untouched' \
    "$([[ -f ${ART_RELEASE_B}/.sentinel ]] && echo untouched || echo replaced)" 'untouched'
  expect_eq 'artifact_stage: re-staging still cleans up the incoming dir' \
    "$(art_incoming_count "${ART_DEST}")" '0'

  # --- a release dir with no marker is debris, and gets replaced ---
  ART_PARTIAL="${ART_DEST}/releases/${ART_SHA_C}-deadbeefcafe"
  mkdir -p "${ART_PARTIAL}/half-extracted"
  ART_WORK_C="${ART_TMP}/work-c"
  art_publish "${ART_WORK_C}" "${ART_SHA_C}" "${ART_BUN}"
  ART_RC=0
  ART_OUT_C=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_C}/dist/tau-core-${ART_SHA_C}-linux-x64.tar.gz" \
    "file://${ART_WORK_C}/dist/artifact.json" \
    "file://${ART_WORK_C}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_DIGEST12_C=$(printf '%s\n' "${ART_OUT_C}" | sed -n 1p | awk '{print $2}')
  ART_TREE_C=$(printf '%s\n' "${ART_OUT_C}" | sed -n 2p)
  ART_RELEASE_C=$(artifact_release_dir "${ART_DEST}" "${ART_SHA_C}" "${ART_DIGEST12_C}")
  mv "${ART_PARTIAL}" "${ART_RELEASE_C}"
  artifact_stage "${ART_DEST}" "${ART_TREE_C}" "${ART_SHA_C}" "${ART_DIGEST12_C}" 2>/dev/null
  expect_eq 'artifact_stage: an unmarked (partial) release dir is replaced, not merged into' \
    "$([[ -d ${ART_RELEASE_C}/half-extracted ]] && echo merged || echo replaced)" 'replaced'
  expect_eq 'artifact_stage: the replacement is complete' \
    "$([[ -f ${ART_RELEASE_C}/.tau-release-complete ]] && echo marked || echo unmarked)" 'marked'

  # --- the pre-flip hook: after the migrate, before the flip ---------------
  # upgrade-host.sh renames the host's env files here (N-C1): the old release
  # must still be `current` while it runs, and it must never run when the
  # candidate's migration failed.
  epr_preflip() { echo "preflip $1 current=$(readlink "${ART_DEST}/current")" >>"${ART_CALLS}"; }
  : >"${ART_CALLS}"
  printf '[migrate-ran]\n' >"${ART_PROOF}"
  ART_PREFLIP_BEFORE=$(readlink "${ART_DEST}/current")
  ART_RC=0
  ART_ACT_OUT=$(ARTIFACT_PREFLIP_HOOK=epr_preflip artifact_activate "${ART_DEST}" "${ART_RELEASE_A}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: activation with a pre-flip hook exits 0' "${ART_RC}" '0'
  expect_match 'artifact_activate: the pre-flip hook runs with current still at the OLD release' \
    "$(<"${ART_CALLS}")" "preflip ${ART_RELEASE_A} current=${ART_PREFLIP_BEFORE}"
  expect_match 'artifact_activate: the pre-flip hook runs AFTER the candidate migration' \
    "$(<"${ART_PROOF}")" "FICUS_ROOT=${ART_RELEASE_A}"
  expect_match 'artifact_activate: the pre-flip hook runs before the restart' \
    "$(tr '\n' '|' <"${ART_CALLS}")" "preflip ${ART_RELEASE_A} current=[^|]*\\|.*restart 3000"
  # A failing hook: current untouched, no restart.
  epr_preflip_fails() { echo preflip-failed >>"${ART_CALLS}"; return 1; }
  : >"${ART_CALLS}"
  ART_RC=0
  ART_ACT_OUT=$(ARTIFACT_PREFLIP_HOOK=epr_preflip_fails artifact_activate "${ART_DEST}" "${ART_RELEASE_B}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: a failing pre-flip hook fails the activation' "$([[ ${ART_RC} -ne 0 ]] && echo failed)" 'failed'
  expect_eq 'artifact_activate: a failing pre-flip hook leaves current untouched' "$(readlink "${ART_DEST}/current")" "${ART_RELEASE_A}"
  expect_eq 'artifact_activate: a failing pre-flip hook restarts nothing' "$(grep -c '^restart' "${ART_CALLS}" || true)" '0'
  # A failing migrate: the hook never runs.
  mv "${ART_RELEASE_B}/apps/core/dist/migrate.js" "${ART_TMP}/migrate.js.saved"
  printf 'process.exit(3)\n' >"${ART_RELEASE_B}/apps/core/dist/migrate.js"
  : >"${ART_CALLS}"
  ART_RC=0
  ART_ACT_OUT=$(sleep() { :; }; ARTIFACT_PREFLIP_HOOK=epr_preflip artifact_activate "${ART_DEST}" "${ART_RELEASE_B}" 3000 2>/dev/null) || ART_RC=$?
  mv -f "${ART_TMP}/migrate.js.saved" "${ART_RELEASE_B}/apps/core/dist/migrate.js"
  expect_eq 'artifact_activate: a failed migrate fails the activation' "$([[ ${ART_RC} -ne 0 ]] && echo failed)" 'failed'
  expect_eq 'artifact_activate: with a failed migrate the pre-flip hook never runs' "$(grep -c '^preflip' "${ART_CALLS}" || true)" '0'
  # Back to the state the next case expects: B current, A previous.
  ART_RC=0
  artifact_activate "${ART_DEST}" "${ART_RELEASE_B}" 3000 >/dev/null 2>&1 || ART_RC=$?
  ln -sfn "${ART_RELEASE_A}" "${ART_DEST}/previous"
  expect_eq 'artifact_activate: (fixture) back on release B' "${ART_RC}:$(readlink "${ART_DEST}/current")" "0:${ART_RELEASE_B}"
  unset -f epr_preflip epr_preflip_fails

  # --- activate with a failing health check: flip back to previous ---
  # The rollback hook (upgrade-host.sh restores the env backup set there)
  # runs after the symlinks are swapped back and BEFORE the rollback restart.
  epr_hook() { echo hook >>"${ART_CALLS}"; }
  : >"${ART_CALLS}"
  touch "${ART_TMP}/restart-fails"
  ART_RC=0
  ART_ACT_OUT=$(ARTIFACT_ROLLBACK_HOOK=epr_hook artifact_activate "${ART_DEST}" "${ART_RELEASE_C}" 3000 2>/dev/null) || ART_RC=$?
  expect_match 'artifact_activate: the rollback hook runs before the rollback restart' \
    "$(tr '\n' '|' <"${ART_CALLS}")" '^([^|]*\|)*restart 3000\|([^|]*\|)*hook\|([^|]*\|)*restart 3000\|'
  unset -f epr_hook
  expect_eq 'artifact_activate: an unhealthy activation exits non-zero' \
    "$([[ ${ART_RC} -ne 0 ]] && echo failed || echo ok)" 'failed'
  expect_eq 'artifact_activate: reports FICUS_RELEASE_ROLLED_BACK=1' "${ART_ACT_OUT}" 'FICUS_RELEASE_ROLLED_BACK=1'
  expect_eq 'artifact_activate: current is flipped back to the release that was serving' \
    "$(readlink "${ART_DEST}/current")" "${ART_RELEASE_B}"
  expect_eq 'artifact_activate: previous is restored too' \
    "$(readlink "${ART_DEST}/previous")" "${ART_RELEASE_A}"
  expect_eq 'artifact_activate: the rollback restarts the services again' \
    "$(grep -c '^restart 3000$' "${ART_CALLS}" || true)" '2'

  # --- re-activating the release that is already current ---
  # Regression: activate set previous=cur_before unconditionally, so a re-run
  # of the SAME release made previous==current — losing the rollback target and
  # letting retention delete it from disk.
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_DEST}" "${ART_RELEASE_B}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: re-activating the current release exits 0' "${ART_RC}" '0'
  expect_eq 'artifact_activate: re-activating the current release leaves current alone' \
    "$(readlink "${ART_DEST}/current")" "${ART_RELEASE_B}"
  expect_eq 'artifact_activate: re-activating the current release does NOT clobber previous' \
    "$(readlink "${ART_DEST}/previous")" "${ART_RELEASE_A}"
  # …and with enough newer releases around to fill the two "newest other" slots,
  # retention still keeps the rollback target (it would have deleted it had
  # previous been clobbered above).
  mkdir -p "${ART_DEST}/releases/filler-1" "${ART_DEST}/releases/filler-2"
  touch -t 203001010000 "${ART_DEST}/releases/filler-1" "${ART_DEST}/releases/filler-2"
  artifact_retention "${ART_DEST}" 2>/dev/null
  expect_eq 'artifact_retention: the rollback target survives a prune' \
    "$([[ -d ${ART_RELEASE_A} ]] && echo kept || echo deleted)" 'kept'
  expect_eq 'artifact_retention: the current release survives a prune' \
    "$([[ -d ${ART_RELEASE_B} ]] && echo kept || echo deleted)" 'kept'
  # (counted with the same glob retention itself walks — `.incoming` is a dot
  # directory and is deliberately not a release)
  expect_eq 'artifact_retention: prunes the rest down to four' \
    "$({ ls -1d "${ART_DEST}"/releases/*/ 2>/dev/null || true; } | wc -l | tr -d ' ')" '4'
  expect_eq 'artifact_retention: the release nothing points at and nothing keeps fresh is the one that goes' \
    "$([[ -d ${ART_RELEASE_C} ]] && echo kept || echo deleted)" 'deleted'
  # A conversion-era node_modules compat symlink whose git release retention
  # just pruned must not be left dangling; one that still resolves must stay.
  ln -sfn "${ART_RELEASE_A}/node_modules" "${ART_DEST}/node_modules"
  mkdir -p "${ART_RELEASE_A}/node_modules"
  artifact_retention "${ART_DEST}" 2>/dev/null
  expect_eq 'artifact_retention: a compat symlink that still resolves is kept' \
    "$([[ -L ${ART_DEST}/node_modules && -e ${ART_DEST}/node_modules ]] && echo kept || echo gone)" 'kept'
  ln -sfn "${ART_DEST}/releases/no-such-release/node_modules" "${ART_DEST}/node_modules"
  artifact_retention "${ART_DEST}" 2>/dev/null
  expect_eq 'artifact_retention: a DANGLING compat symlink is swept' \
    "$([[ -L ${ART_DEST}/node_modules ]] && echo still-there || echo swept)" 'swept'

  # --- a box with nothing to roll back to ---
  # A first-ever activation that fails health has no earlier release to return
  # to: it must say so (ROLLED_BACK=0 — nothing was rolled back) and still exit
  # non-zero, rather than claim a rollback it never performed.
  ART_DEST2=$(mktemp -d)/tau-core
  mkdir -p "${ART_DEST2}"
  printf 'DATABASE_URL=postgres://fixture/db\nMIGRATE_PROOF=%s\n' "${ART_PROOF}" >"${ART_DEST2}/.env"
  ART_RC=0
  ART_OUT_A2=$(artifact_acquire "${ART_DEST2}" \
    "file://${ART_WORK_A}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_A}/dist/artifact.json" \
    "file://${ART_WORK_A}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_TREE_A2=$(printf '%s\n' "${ART_OUT_A2}" | sed -n 2p)
  ART_RELEASE_A2=$(artifact_release_dir "${ART_DEST2}" "${ART_SHA_A}" "${ART_DIGEST12_A}")
  artifact_stage "${ART_DEST2}" "${ART_TREE_A2}" "${ART_SHA_A}" "${ART_DIGEST12_A}" 2>/dev/null
  touch "${ART_TMP}/restart-fails"
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_DEST2}" "${ART_RELEASE_A2}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: a failed first activation exits non-zero' \
    "$([[ ${ART_RC} -ne 0 ]] && echo failed || echo ok)" 'failed'
  expect_eq 'artifact_activate: with no rollback target it reports FICUS_RELEASE_ROLLED_BACK=0' \
    "${ART_ACT_OUT}" 'FICUS_RELEASE_ROLLED_BACK=0'
  expect_eq 'artifact_activate: with no rollback target current still points at the failed release' \
    "$(readlink "${ART_DEST2}/current")" "${ART_RELEASE_A2}"

  # …and a LATER failed activation on that same box (current set, previous
  # still absent) must restore it exactly — including REMOVING the `previous`
  # link the failed activation created.
  ART_RC=0
  ART_OUT_B3=$(artifact_acquire "${ART_DEST2}" \
    "file://${ART_WORK_B}/dist/tau-core-${ART_SHA_B}-linux-x64.tar.gz" \
    "file://${ART_WORK_B}/dist/artifact.json" \
    "file://${ART_WORK_B}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_TREE_B3=$(printf '%s\n' "${ART_OUT_B3}" | sed -n 2p)
  ART_RELEASE_B3=$(artifact_release_dir "${ART_DEST2}" "${ART_SHA_B}" "${ART_DIGEST12_B}")
  artifact_stage "${ART_DEST2}" "${ART_TREE_B3}" "${ART_SHA_B}" "${ART_DIGEST12_B}" 2>/dev/null
  touch "${ART_TMP}/restart-fails"
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_DEST2}" "${ART_RELEASE_B3}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: the rollback reports FICUS_RELEASE_ROLLED_BACK=1' \
    "${ART_ACT_OUT}" 'FICUS_RELEASE_ROLLED_BACK=1'
  expect_eq 'artifact_activate: the rollback restores current' \
    "$(readlink "${ART_DEST2}/current")" "${ART_RELEASE_A2}"
  expect_eq 'artifact_activate: the rollback removes a previous that did not exist before it' \
    "$([[ -e ${ART_DEST2}/previous ]] && echo present || echo absent)" 'absent'
  rm -rf "${ART_DEST2}"

  # --- the migrate step READS <dest>/.env, it does not EXECUTE it ---
  # `set -a; . .env` would expand `$` inside a password and run backticks as
  # root, out of a file whose whole purpose is to hold unvetted secrets.
  ART_DEST3=$(mktemp -d)/tau-core
  mkdir -p "${ART_DEST3}"
  ART_SIDE="${ART_TMP}/side-effect.txt"
  ART_PROOF3="${ART_TMP}/migrate-proof-3.txt"
  {
    printf '# a comment line\n\n'
    printf 'DATABASE_URL=postgres://fixture/db\n'
    printf 'MIGRATE_PROOF=%s\n' "${ART_PROOF3}"
    printf 'PW=pa$$word\n'
    printf 'X=`touch %s`\n' "${ART_SIDE}"
    printf 'NOT_AN_ASSIGNMENT\n'
  } >"${ART_DEST3}/.env"
  ART_RC=0
  ART_OUT_A3=$(artifact_acquire "${ART_DEST3}" \
    "file://${ART_WORK_A}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_A}/dist/artifact.json" \
    "file://${ART_WORK_A}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_TREE_A3=$(printf '%s\n' "${ART_OUT_A3}" | sed -n 2p)
  # …and while we hold a verified tree: staging it under the WRONG sha must die
  # before the move, leaving the tree where it was.
  ART_RC=0
  (artifact_stage "${ART_DEST3}" "${ART_TREE_A3}" "${ART_SHA_C}" 'deadbeefcafe' 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_stage: a tree whose artifact.json names another commit is refused' \
    "$([[ ${ART_RC} -ne 0 ]] && echo refused || echo staged)" 'refused'
  expect_eq 'artifact_stage: the refusal happens before the move (the tree is still there)' \
    "$([[ -f ${ART_TREE_A3}/artifact.json ]] && echo intact || echo moved)" 'intact'
  ART_RELEASE_A3=$(artifact_release_dir "${ART_DEST3}" "${ART_SHA_A}" "${ART_DIGEST12_A}")
  # An unmarked release dir must never be activated…
  mkdir -p "${ART_DEST3}/releases/unmarked"
  ART_RC=0
  (artifact_activate "${ART_DEST3}" "${ART_DEST3}/releases/unmarked" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_activate: refuses a release dir with no completion marker' \
    "$([[ ${ART_RC} -ne 0 ]] && echo refused || echo activated)" 'refused'
  expect_eq 'artifact_activate: the refusal happens before any flip' \
    "$([[ -e ${ART_DEST3}/current ]] && echo flipped || echo untouched)" 'untouched'
  artifact_stage "${ART_DEST3}" "${ART_TREE_A3}" "${ART_SHA_A}" "${ART_DIGEST12_A}" 2>/dev/null
  ART_RC=0
  artifact_activate "${ART_DEST3}" "${ART_RELEASE_A3}" 3000 >/dev/null 2>&1 || ART_RC=$?
  expect_eq 'artifact_activate: a .env full of shell metacharacters still activates' "${ART_RC}" '0'
  expect_match 'artifact_activate: a $-bearing value reaches the migrate child verbatim' \
    "$(<"${ART_PROOF3}")" 'PW=pa\$\$word'
  expect_match 'artifact_activate: the ordinary values still arrive' \
    "$(<"${ART_PROOF3}")" 'DATABASE_URL=postgres://fixture/db'
  expect_eq 'artifact_activate: a backtick in .env is a VALUE, not a command' \
    "$([[ -e ${ART_SIDE} ]] && echo executed || echo inert)" 'inert'
  rm -rf "${ART_DEST3}"

  # --- a leaked .incoming session dir is swept by the next acquire ---
  mkdir -p "${ART_DEST}/releases/.incoming/stale-session/tree"
  printf 'leaked 70MB tarball stand-in\n' >"${ART_DEST}/releases/.incoming/stale-session/artifact.tar.gz"
  ART_RC=0
  artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_A}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_A}/dist/artifact.json" \
    "file://${ART_WORK_A}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" >/dev/null 2>&1 || ART_RC=$?
  expect_eq 'artifact_acquire: a leaked staging session from an earlier run is swept' \
    "$([[ -e ${ART_DEST}/releases/.incoming/stale-session ]] && echo leaked || echo swept)" 'swept'

  # --- tampered file: the manifest and the bytes disagree ---
  ART_WORK_T="${ART_TMP}/work-tamper-file"
  art_publish "${ART_WORK_T}" "${ART_SHA_A}" "${ART_BUN}"
  printf 'agent: TAMPERED\n' >"$(art_tree "${ART_WORK_T}" "${ART_SHA_A}")/config/agent.yaml"
  art_tar "${ART_WORK_T}" "${ART_SHA_A}" # re-tar WITHOUT re-signing
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_T}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_T}/dist/artifact.json" \
    "file://${ART_WORK_T}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a tampered file fails' "$([[ ${ART_RC} -ne 0 ]] && echo failed || echo ok)" 'failed'
  expect_eq 'artifact_acquire: a tampered file reports hash_mismatch' "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=hash_mismatch'

  # --- an extra file the manifest never mentions ---
  ART_WORK_X="${ART_TMP}/work-extra-file"
  art_publish "${ART_WORK_X}" "${ART_SHA_A}" "${ART_BUN}"
  printf 'backdoor\n' >"$(art_tree "${ART_WORK_X}" "${ART_SHA_A}")/config/extra.yaml"
  art_tar "${ART_WORK_X}" "${ART_SHA_A}"
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_X}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_X}/dist/artifact.json" \
    "file://${ART_WORK_X}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a file the manifest never lists is fatal' \
    "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=hash_mismatch'

  # --- tampered manifest: the signature no longer covers these bytes ---
  ART_WORK_M="${ART_TMP}/work-tamper-manifest"
  art_publish "${ART_WORK_M}" "${ART_SHA_A}" "${ART_BUN}"
  sed 's/"builder": "test:fixture"/"builder": "test:TAMPERED"/' \
    <"${ART_WORK_M}/dist/artifact.json" >"${ART_WORK_M}/dist/artifact.json.new"
  mv -f "${ART_WORK_M}/dist/artifact.json.new" "${ART_WORK_M}/dist/artifact.json"
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_M}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_M}/dist/artifact.json" \
    "file://${ART_WORK_M}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a tampered manifest fails' "$([[ ${ART_RC} -ne 0 ]] && echo failed || echo ok)" 'failed'
  expect_eq 'artifact_acquire: a tampered manifest reports sig_invalid' "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=sig_invalid'

  # --- a perfectly valid artifact signed by the WRONG key ---
  ART_WORK_K="${ART_TMP}/work-wrong-key"
  art_publish "${ART_WORK_K}" "${ART_SHA_A}" "${ART_BUN}"
  "${ART_OPENSSL}" pkeyutl -sign -inkey "${ART_TMP}/other-key.pem" -rawin \
    -in "${ART_WORK_K}/dist/artifact.json" -out "${ART_WORK_K}/dist/artifact.sig.raw"
  base64 <"${ART_WORK_K}/dist/artifact.sig.raw" >"${ART_WORK_K}/dist/artifact.sig"
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_K}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_K}/dist/artifact.json" \
    "file://${ART_WORK_K}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a signature from another key reports sig_invalid' \
    "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=sig_invalid'

  # --- the bun pin ---
  ART_WORK_BUN="${ART_TMP}/work-bun"
  art_publish "${ART_WORK_BUN}" "${ART_SHA_A}" '0.0.0-not-the-hosts-bun'
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_BUN}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_BUN}/dist/artifact.json" \
    "file://${ART_WORK_BUN}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a bun the host does not run is fatal' "$([[ ${ART_RC} -ne 0 ]] && echo failed || echo ok)" 'failed'
  expect_eq 'artifact_acquire: a bun mismatch reports bun_mismatch' "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=bun_mismatch'

  # --- the bun pin: a mismatch against a VALID pin is repaired, not refused ---
  expect_eq 'bun_pin_is_valid: x.y.z' "$(bun_pin_is_valid 1.4.2 && echo yes || echo no)" 'yes'
  expect_eq 'bun_pin_is_valid: a suffix is refused' "$(bun_pin_is_valid 0.0.0-not-the-hosts-bun && echo yes || echo no)" 'no'
  expect_eq 'bun_pin_is_valid: two parts are refused' "$(bun_pin_is_valid 1.4 && echo yes || echo no)" 'no'
  expect_eq 'bun_pin_is_valid: empty is refused' "$(bun_pin_is_valid '' && echo yes || echo no)" 'no'

  ART_WORK_BUN2="${ART_TMP}/work-bun-install"
  art_publish "${ART_WORK_BUN2}" "${ART_SHA_A}" '9.9.9'
  ART_BUN_HOME="${ART_TMP}/bun-home"
  ART_RC=0
  ART_OUT_BUN=$(
    (
      HOME="${ART_BUN_HOME}"
      RUN_USER=''
      # The stub stands in for the official installer: it records the pin it
      # was asked for and plants a bun that reports it.
      bun_official_install() {
        printf '%s\n' "$1" >>"${ART_TMP}/bun-installs"
        mkdir -p "${HOME}/.bun/bin"
        printf '#!/bin/sh\necho 9.9.9\n' >"${HOME}/.bun/bin/bun"
        chmod 755 "${HOME}/.bun/bin/bun"
      }
      artifact_acquire "${ART_DEST}" \
        "file://${ART_WORK_BUN2}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
        "file://${ART_WORK_BUN2}/dist/artifact.json" \
        "file://${ART_WORK_BUN2}/dist/artifact.sig" \
        "${ART_TMP}/pub.pem"
    ) 2>/dev/null
  ) || ART_RC=$?
  expect_eq 'artifact_acquire: a mismatched but valid pin installs that bun and verifies (exit 0)' "${ART_RC}" '0'
  expect_eq 'artifact_acquire: the installer was asked for exactly the manifest pin' \
    "$(cat "${ART_TMP}/bun-installs" 2>/dev/null)" '9.9.9'
  expect_eq 'artifact_acquire: line 1 after a bun install is still "<sha> <digest12>"' \
    "$(printf '%s\n' "${ART_OUT_BUN}" | sed -n 1p | awk '{print $1}')" "${ART_SHA_A}"

  # --- the bun pin: an installer failure is still bun_mismatch ---------------
  ART_RC=0
  ART_ERR=$(
    (
      HOME="${ART_BUN_HOME}-fail"
      RUN_USER=''
      bun_official_install() { return 1; }
      artifact_acquire "${ART_DEST}" \
        "file://${ART_WORK_BUN2}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
        "file://${ART_WORK_BUN2}/dist/artifact.json" \
        "file://${ART_WORK_BUN2}/dist/artifact.sig" \
        "${ART_TMP}/pub.pem"
    ) 2>/dev/null
  ) || ART_RC=$?
  expect_eq 'artifact_acquire: a failed bun install reports bun_mismatch' "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=bun_mismatch'

  # --- a URL that does not resolve ---
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_TMP}/nope.tar.gz" "file://${ART_TMP}/nope.json" "file://${ART_TMP}/nope.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: an unreachable artifact reports download_failed' \
    "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=download_failed'

  # --- a tarball that reaches outside its own root ---
  # The signature covers the MANIFEST, not the tarball, so extraction is the one
  # step that can still be handed hostile bytes: the member list is checked
  # first, and a bad one is never unpacked.
  ART_WORK_ESC="${ART_TMP}/work-escape"
  art_publish "${ART_WORK_ESC}" "${ART_SHA_A}" "${ART_BUN}"
  python3 "${ART_TMP}/repack.py" \
    "${ART_WORK_ESC}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "${ART_WORK_ESC}/dist/escaped.tar.gz" "tau-core-${ART_SHA_A}/../escape.txt"
  mv -f "${ART_WORK_ESC}/dist/escaped.tar.gz" "${ART_WORK_ESC}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz"
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_ESC}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_ESC}/dist/artifact.json" \
    "file://${ART_WORK_ESC}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a member traversing out of the root reports download_failed' \
    "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=download_failed'
  expect_eq 'artifact_acquire: the escaping tarball is never unpacked' \
    "$({ find "${ART_DEST}" -name 'escape.txt' 2>/dev/null || true; } | wc -l | tr -d ' ')" '0'

  ART_WORK_ROOT="${ART_TMP}/work-second-root"
  art_publish "${ART_WORK_ROOT}" "${ART_SHA_A}" "${ART_BUN}"
  python3 "${ART_TMP}/repack.py" \
    "${ART_WORK_ROOT}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "${ART_WORK_ROOT}/dist/second-root.tar.gz" 'not-the-artifact-root/x.txt'
  mv -f "${ART_WORK_ROOT}/dist/second-root.tar.gz" "${ART_WORK_ROOT}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz"
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_ROOT}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_ROOT}/dist/artifact.json" \
    "file://${ART_WORK_ROOT}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: a member outside tau-core-<sha>/ reports download_failed' \
    "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=download_failed'

  # --- the tree carries a DIFFERENT artifact.json than the signed one ---
  # (the in-tree copy is what core reads to self-report its version, so it has
  # to be the very bytes the signature covers)
  ART_WORK_IT="${ART_TMP}/work-intree"
  art_publish "${ART_WORK_IT}" "${ART_SHA_A}" "${ART_BUN}"
  sed 's/"builder": "test:fixture"/"builder": "test:in-tree-lie"/' \
    <"$(art_tree "${ART_WORK_IT}" "${ART_SHA_A}")/artifact.json" >"${ART_TMP}/intree.json"
  cp "${ART_TMP}/intree.json" "$(art_tree "${ART_WORK_IT}" "${ART_SHA_A}")/artifact.json"
  art_tar "${ART_WORK_IT}" "${ART_SHA_A}" # re-tar; the SIGNED manifest is untouched
  ART_RC=0
  ART_ERR=$(artifact_acquire "${ART_DEST}" \
    "file://${ART_WORK_IT}/dist/tau-core-${ART_SHA_A}-linux-x64.tar.gz" \
    "file://${ART_WORK_IT}/dist/artifact.json" \
    "file://${ART_WORK_IT}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'artifact_acquire: an in-tree artifact.json that differs from the signed one is fatal' \
    "${ART_ERR}" 'FICUS_ARTIFACT_ERROR=manifest_invalid'

  # --- every failed acquire cleans up after itself ---
  expect_eq 'artifact_acquire: failures leave no incoming debris behind' \
    "$(art_incoming_count "${ART_DEST}")" '0'

  # --- retention: current + previous + the 2 newest others ---
  # --- the git -> artifact conversion (upgrade-host.sh's first-upgrade hop) ---
  # A realistic pre-conversion box: a git checkout with build outputs, a
  # dotfile, the secrets .env and a build stamp. After the conversion the WHOLE
  # checkout — dotfiles included — is ONE release directory, .env and the stamp
  # are still at <dest>, and BOTH layout links point at the moved tree: the box
  # has to be consistent at every instant, because the units are re-rendered to
  # <dest>/current in the same breath and must never name a path that does not
  # exist.
  ART_CONV=$(mktemp -d)/tau-core
  mkdir -p "${ART_CONV}/apps/core/dist" "${ART_CONV}/config"
  git -C "${ART_CONV}" init -q -b main
  git -C "${ART_CONV}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ART_CONV_HEAD=$(git -C "${ART_CONV}" rev-parse HEAD)
  printf 'DATABASE_URL=postgres://fixture/db\nMIGRATE_PROOF=%s\n' "${ART_PROOF}" >"${ART_CONV}/.env"
  printf 'FICUS_BUILD_COMMIT=%s\n' "${ART_CONV_HEAD}" >"${ART_CONV}/.tau-build-stamp"
  printf 'old index\n' >"${ART_CONV}/apps/core/dist/index.js"
  mkdir -p "${ART_CONV}/node_modules/jsdom/browser"
  printf 'css\n' >"${ART_CONV}/node_modules/jsdom/browser/default-stylesheet.css"
  printf 'registry=x\n' >"${ART_CONV}/.npmrc"
  printf '{}\n' >"${ART_CONV}/package.json"
  printf 'cfg\n' >"${ART_CONV}/config/webhooks.yaml"
  expect_eq 'convert: before the conversion the box reports git-<head sha> (the BEFORE trailer)' \
    "$(artifact_current_release_id "${ART_CONV}")" "git-${ART_CONV_HEAD}"

  artifact_convert_git_checkout "${ART_CONV}" 2>/dev/null
  ART_CONV_REL="${ART_CONV}/releases/git-${ART_CONV_HEAD}"
  expect_eq 'convert: the checkout lands at releases/git-<head sha>' \
    "$([[ -d ${ART_CONV_REL} ]] && echo moved || echo missing)" 'moved'
  expect_eq 'convert: DOTFILES move too — .git is the whole rollback tree' \
    "$([[ -d ${ART_CONV_REL}/.git && -f ${ART_CONV_REL}/.npmrc ]] && echo moved || echo left-behind)" 'moved'
  expect_eq 'convert: the whole tree moves, not just its top level' \
    "$([[ -f ${ART_CONV_REL}/apps/core/dist/index.js && -f ${ART_CONV_REL}/config/webhooks.yaml && -f ${ART_CONV_REL}/package.json ]] && echo complete || echo partial)" 'complete'
  expect_eq 'convert: .env stays at <dest> — secrets live outside the releases' \
    "$([[ -f ${ART_CONV}/.env && ! -e ${ART_CONV_REL}/.env ]] && echo kept || echo moved)" 'kept'
  expect_eq 'convert: the .env is never rewritten' \
    "$(grep -c 'DATABASE_URL=postgres://fixture/db' "${ART_CONV}/.env")" '1'
  expect_eq 'convert: the build stamp stays at <dest>' \
    "$([[ -f ${ART_CONV}/.tau-build-stamp && ! -e ${ART_CONV_REL}/.tau-build-stamp ]] && echo kept || echo moved)" 'kept'
  # current, not just previous: between the conversion and the first flip the
  # box must survive a reboot, and the re-rendered units name <dest>/current.
  expect_eq 'convert: current points at the converted tree (the units can run immediately)' \
    "$(readlink "${ART_CONV}/current")" "${ART_CONV_REL}"
  expect_eq 'convert: current/apps/core — the units WorkingDirectory — resolves' \
    "$([[ -d ${ART_CONV}/current/apps/core ]] && echo resolves || echo dangling)" 'resolves'
  expect_eq 'convert: previous points at the converted tree too (a complete layout)' \
    "$(readlink "${ART_CONV}/previous")" "${ART_CONV_REL}"
  expect_eq 'convert: the release id is still git-<head sha>, now read through current' \
    "$(artifact_current_release_id "${ART_CONV}")" "git-${ART_CONV_HEAD}"
  # The moved tree was BUILT at <dest>, and bun bakes that absolute path into
  # its bundles (jsdom reads node_modules files through it at boot) — so the
  # OLD path must keep resolving or the conversion breaks its own rollback
  # target. Live-hit on the first artifact canary.
  expect_eq 'convert: a node_modules compat symlink keeps the baked build paths resolving' \
    "$(readlink "${ART_CONV}/node_modules")" "${ART_CONV_REL}/node_modules"
  expect_eq 'convert: a file read through the OLD node_modules path still works' \
    "$(cat "${ART_CONV}/node_modules/jsdom/browser/default-stylesheet.css" 2>/dev/null)" 'css'
  expect_eq 'convert: <dest> keeps exactly .env, the stamp and the layout'  \
    "$(find "${ART_CONV}" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')" \
    '.env .tau-build-stamp current node_modules previous releases '
  ART_RC=0
  (artifact_convert_git_checkout "${ART_CONV}") 2>/dev/null || ART_RC=$?
  expect_eq 'convert: refuses a <dest> that is not (or is no longer) a git checkout' "${ART_RC}" '1'

  # --- resumable: an interrupted conversion is finished by the next run ---
  # Simulates a crash mid-move by pre-moving part of the tree by hand into a
  # release dir that therefore already exists. Because each entry moves with
  # its own rename and `.git` moves LAST, "a .git at <dest>" still means
  # "unfinished", and the re-run moves the remainder.
  ART_CONV3=$(mktemp -d)/tau-core
  mkdir -p "${ART_CONV3}/apps/core" "${ART_CONV3}/config"
  git -C "${ART_CONV3}" init -q -b main
  git -C "${ART_CONV3}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ART_CONV3_HEAD=$(git -C "${ART_CONV3}" rev-parse HEAD)
  printf 'secrets\n' >"${ART_CONV3}/.env"
  printf '{}\n' >"${ART_CONV3}/package.json"
  printf 'dot\n' >"${ART_CONV3}/.npmrc"
  printf 'core\n' >"${ART_CONV3}/apps/core/marker"
  printf 'cfg\n' >"${ART_CONV3}/config/webhooks.yaml"
  ART_CONV3_REL="${ART_CONV3}/releases/git-${ART_CONV3_HEAD}"
  mkdir -p "${ART_CONV3_REL}"
  mv "${ART_CONV3}/apps" "${ART_CONV3_REL}/apps"     # the "already moved" half
  mv "${ART_CONV3}/.npmrc" "${ART_CONV3_REL}/.npmrc"
  artifact_convert_git_checkout "${ART_CONV3}" 2>/dev/null
  expect_eq 'convert: a re-run after an interrupted conversion completes it' \
    "$([[ -d ${ART_CONV3_REL}/.git && -f ${ART_CONV3_REL}/package.json && -f ${ART_CONV3_REL}/config/webhooks.yaml ]] && echo complete || echo incomplete)" 'complete'
  expect_eq 'convert: the already-moved half is untouched by the re-run' \
    "$([[ -f ${ART_CONV3_REL}/apps/core/marker && -f ${ART_CONV3_REL}/.npmrc ]] && echo intact || echo lost)" 'intact'
  expect_eq 'convert: the resumed run leaves the same <dest> layout' \
    "$(find "${ART_CONV3}" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')" \
    '.env current previous releases '
  # A name living on BOTH sides cannot come from an interrupted run (rename is
  # atomic) — it is an ambiguous state, and merging trees blindly is how a
  # half-old half-new checkout gets served.
  ART_CONV4=$(mktemp -d)/tau-core
  mkdir -p "${ART_CONV4}"
  git -C "${ART_CONV4}" init -q -b main
  git -C "${ART_CONV4}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "${ART_CONV4}/releases/git-$(git -C "${ART_CONV4}" rev-parse HEAD)/apps"
  mkdir -p "${ART_CONV4}/apps"
  ART_RC=0
  (artifact_convert_git_checkout "${ART_CONV4}") 2>/dev/null || ART_RC=$?
  expect_eq 'convert: a name present at BOTH <dest> and the release dir is refused' "${ART_RC}" '1'
  expect_eq 'convert: the refusal moves nothing' \
    "$([[ -d ${ART_CONV4}/apps && -d ${ART_CONV4}/.git ]] && echo intact || echo disturbed)" 'intact'
  rm -rf "$(dirname "${ART_CONV3}")" "$(dirname "${ART_CONV4}")"

  # …and the converted box takes a real release end to end. Because the
  # conversion left a real `current`, the first activation displaces something:
  # `previous` names the git tree, which is what makes the auto-rollback below
  # possible at all.
  ART_WORK_D="${ART_TMP}/work-d"
  art_publish "${ART_WORK_D}" "${ART_SHA_D}" "${ART_BUN}"
  ART_RC=0
  ART_OUT_D=$(artifact_acquire "${ART_CONV}" \
    "file://${ART_WORK_D}/dist/tau-core-${ART_SHA_D}-linux-x64.tar.gz" \
    "file://${ART_WORK_D}/dist/artifact.json" \
    "file://${ART_WORK_D}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  expect_eq 'convert: a converted box acquires a release (exit 0)' "${ART_RC}" '0'
  ART_DIGEST12_D=$(printf '%s\n' "${ART_OUT_D}" | sed -n 1p | awk '{print $2}')
  ART_TREE_D=$(printf '%s\n' "${ART_OUT_D}" | sed -n 2p)
  ART_RELEASE_D=$(artifact_release_dir "${ART_CONV}" "${ART_SHA_D}" "${ART_DIGEST12_D}")
  artifact_stage "${ART_CONV}" "${ART_TREE_D}" "${ART_SHA_D}" "${ART_DIGEST12_D}" 2>/dev/null
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_CONV}" "${ART_RELEASE_D}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'convert: activating the first release on a converted box exits 0' "${ART_RC}" '0'
  expect_eq 'convert: current now serves the artifact release' \
    "$(readlink "${ART_CONV}/current")" "${ART_RELEASE_D}"
  expect_eq 'convert: previous names the git tree it displaced (the rollback target)' \
    "$(readlink "${ART_CONV}/previous")" "${ART_CONV_REL}"
  expect_eq 'convert: the AFTER trailer value now reads as the artifact release id' \
    "$(artifact_current_release_id "${ART_CONV}")" "${ART_SHA_D}-${ART_DIGEST12_D}"
  artifact_retention "${ART_CONV}" 2>/dev/null
  expect_eq 'convert: retention keeps the converted git tree (previous protects it)' \
    "$([[ -d ${ART_CONV_REL} ]] && echo kept || echo deleted)" 'kept'
  rm -rf "$(dirname "${ART_CONV}")"

  # --- a FAILED first activation on a converted box rolls back to the git tree
  # This is what the conversion's `current` buys: before it, the very first
  # artifact activation had nothing to flip back to, so an unhealthy release
  # stayed current.
  ART_CONV2=$(mktemp -d)/tau-core
  mkdir -p "${ART_CONV2}/apps/core"
  git -C "${ART_CONV2}" init -q -b main
  git -C "${ART_CONV2}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ART_CONV2_HEAD=$(git -C "${ART_CONV2}" rev-parse HEAD)
  printf 'DATABASE_URL=postgres://fixture/db\nMIGRATE_PROOF=%s\n' "${ART_PROOF}" >"${ART_CONV2}/.env"
  printf 'old\n' >"${ART_CONV2}/apps/core/marker"
  artifact_convert_git_checkout "${ART_CONV2}" 2>/dev/null
  ART_CONV2_REL="${ART_CONV2}/releases/git-${ART_CONV2_HEAD}"
  ART_RC=0
  ART_OUT_E=$(artifact_acquire "${ART_CONV2}" \
    "file://${ART_WORK_D}/dist/tau-core-${ART_SHA_D}-linux-x64.tar.gz" \
    "file://${ART_WORK_D}/dist/artifact.json" \
    "file://${ART_WORK_D}/dist/artifact.sig" \
    "${ART_TMP}/pub.pem" 2>/dev/null) || ART_RC=$?
  ART_DIGEST12_E=$(printf '%s\n' "${ART_OUT_E}" | sed -n 1p | awk '{print $2}')
  ART_TREE_E=$(printf '%s\n' "${ART_OUT_E}" | sed -n 2p)
  ART_RELEASE_E=$(artifact_release_dir "${ART_CONV2}" "${ART_SHA_D}" "${ART_DIGEST12_E}")
  artifact_stage "${ART_CONV2}" "${ART_TREE_E}" "${ART_SHA_D}" "${ART_DIGEST12_E}" 2>/dev/null
  : >"${ART_CALLS}"
  touch "${ART_TMP}/restart-fails"
  ART_RC=0
  ART_ACT_OUT=$(artifact_activate "${ART_CONV2}" "${ART_RELEASE_E}" 3000 2>/dev/null) || ART_RC=$?
  expect_eq 'convert: an unhealthy FIRST activation exits non-zero' \
    "$([[ ${ART_RC} -ne 0 ]] && echo failed || echo ok)" 'failed'
  expect_eq 'convert: an unhealthy first activation reports FICUS_RELEASE_ROLLED_BACK=1' \
    "${ART_ACT_OUT}" 'FICUS_RELEASE_ROLLED_BACK=1'
  expect_eq 'convert: current is rolled back to the git tree the box was serving' \
    "$(readlink "${ART_CONV2}/current")" "${ART_CONV2_REL}"
  expect_eq 'convert: previous is restored to what the conversion left' \
    "$(readlink "${ART_CONV2}/previous")" "${ART_CONV2_REL}"
  expect_eq 'convert: the rollback restarted the services again' \
    "$(grep -c '^restart 3000$' "${ART_CALLS}" || true)" '2'
  rm -f "${ART_TMP}/restart-fails"
  rm -rf "$(dirname "${ART_CONV2}")"

  ART_RET=$(mktemp -d)
  mkdir -p "${ART_RET}/releases"
  printf 'secrets\n' >"${ART_RET}/.env"
  for art_i in 1 2 3 4 5 6; do
    mkdir -p "${ART_RET}/releases/rel-${art_i}"
    touch -t "2026010${art_i}0000" "${ART_RET}/releases/rel-${art_i}"
  done
  ln -sfn "${ART_RET}/releases/rel-1" "${ART_RET}/current"
  ln -sfn "${ART_RET}/releases/rel-2" "${ART_RET}/previous"
  artifact_retention "${ART_RET}" 2>/dev/null
  expect_eq 'artifact_retention: prunes down to four releases' \
    "$(find "${ART_RET}/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" '4'
  expect_eq 'artifact_retention: keeps current, previous and the two newest others' \
    "$(find "${ART_RET}/releases" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')" \
    'rel-1 rel-2 rel-5 rel-6 '
  expect_eq 'artifact_retention: never touches anything outside releases/' \
    "$([[ -f ${ART_RET}/.env ]] && echo intact || echo gone)" 'intact'
  rm -rf "${ART_RET}"

  rm -rf "${ART_TMP}" "${ART_DEST}"
  PATH=${ART_PATH_BEFORE}
  source "${SCRIPT_DIR}/lib.sh"
fi
rm -rf "${ART_SHIM}"

# --- git_env_setup: git-https without a token clones anonymously -----------
# Core is public, so an unattended box with no $GH_TOKEN must clone rather
# than die. With a token the askpass path is unchanged.
GES_ANON=$(
  (
    SRC_MODE=git-https SRC_REPO=https://github.com/example-org/tau.git
    unset GH_TOKEN
    is_tty() { return 1; }
    git_env_setup 2>/dev/null
    printf '%s|%s|%s' "${GIT_AUTH_URL}" "${GIT_CLEAN_URL}" "${GIT_ASKPASS:-unset}"
  )
)
expect_eq 'git_env_setup: git-https with no token → anonymous https URL, no askpass helper' \
  "${GES_ANON}" 'https://github.com/example-org/tau.git|https://github.com/example-org/tau.git|unset'
GES_SSH_STYLE=$(
  (
    SRC_MODE=git-https SRC_REPO=git@github.com:example-org/tau.git
    unset GH_TOKEN
    is_tty() { return 1; }
    git_env_setup 2>/dev/null
    printf '%s' "${GIT_AUTH_URL}"
  )
)
expect_eq 'git_env_setup: anonymous clone still normalizes an ssh-style URL' \
  "${GES_SSH_STYLE}" 'https://github.com/example-org/tau.git'
GES_TOKEN=$(
  (
    SRC_MODE=git-https SRC_REPO=https://github.com/example-org/tau.git GH_TOKEN=ghp_test
    git_env_setup 2>/dev/null
    printf '%s|%s' "${GIT_AUTH_URL}" "$([[ -x ${GIT_ASKPASS:-/nonexistent} ]] && echo askpass || echo none)"
  )
)
expect_eq 'git_env_setup: git-https with a token keeps the x-access-token askpass path' \
  "${GES_TOKEN}" 'https://x-access-token@github.com/example-org/tau.git|askpass'

# --- ensure_system_bun_node -------------------------------------------------
# Managed hosts expose Bun through stable system paths so Node shebangs never
# resolve Bun's process-global /tmp shim.
SBN_TMP=$(mktemp -d)
SBN_SYS="${SBN_TMP}/system-bin"
SBN_SOURCE="${SBN_TMP}/source-bun"
cat >"${SBN_SOURCE}" <<'EOF'
#!/bin/sh
[ "$#" -eq 1 ] && [ -x "$1" ] || exit 81
grep -Fq 'console.log("stable-node-ok")' "$1" || exit 82
printf '%s\n' stable-node-ok
EOF
chmod 755 "${SBN_SOURCE}"
# These cases RUN ensure_system_bun_node, which installs root:root binaries —
# see the FICUS_TEST_ROOT_INSTALL probe at the top of this file.
if [[ ${FICUS_TEST_ROOT_INSTALL} -eq 1 ]]; then
  sbn_result=$(
    (
      FICUS_SYSTEM_BIN_DIR="${SBN_SYS}"
      as_root() { "$@"; }
      getent() { [[ $1 == passwd && $2 == tau-runner ]] && printf 'tau-runner:x:1:1::%s:/bin/false\n' "${SBN_TMP}/runner-home"; }
      runuser() {
        [[ $1 == -u && $3 == -- ]] || return 91
        shift 3
        printf '%s\n' "$*" >>"${SBN_TMP}/runuser.calls"
        "$@"
      }
      if ! declare -F ensure_system_bun_node >/dev/null; then
        printf missing-helper
        exit 0
      fi
      ensure_system_bun_node tau-runner "${SBN_SOURCE}"
      ensure_system_bun_node tau-runner "${SBN_SOURCE}"
      printf '%s|%s|%s' "$(file_mode "${SBN_SYS}/bun")" \
        "$(readlink "${SBN_SYS}/node")" "$(tr '\n' ';' <"${SBN_TMP}/runuser.calls")"
    ) 2>/dev/null
  )
  expect_match 'ensure_system_bun_node installs mode-755 Bun and absolute Node link' \
    "${sbn_result}" "^755\\|${SBN_SYS}/bun\\|"
  expect_match 'ensure_system_bun_node verifies a Node shebang as RUN_USER with sanitized HOME and PATH' \
    "${sbn_result}" "env -i HOME=${SBN_TMP}/runner-home PATH=${SBN_SYS}:/usr/bin:/bin"
  expect_match 'ensure_system_bun_node verifies managed Bun as RUN_USER' \
    "${sbn_result}" "test -x ${SBN_SYS}/bun"
  expect_match 'ensure_system_bun_node verifies managed Node as RUN_USER' \
    "${sbn_result}" "test -x ${SBN_SYS}/node"
  expect_eq 'ensure_system_bun_node leaves exactly one Node compatibility link' \
    "$(find "${SBN_SYS}" -maxdepth 1 -type l -name node 2>/dev/null | wc -l | tr -d ' ')" '1'

  chmod 0777 "${SBN_SYS}/bun"
  sbn_mode_repaired=$(
    (
      FICUS_SYSTEM_BIN_DIR="${SBN_SYS}"
      as_root() { "$@"; }
      getent() { printf 'tau-runner:x:1:1::%s:/bin/false\n' "${SBN_TMP}/runner-home"; }
      runuser() { shift 3; "$@"; }
      ensure_system_bun_node tau-runner "${SBN_SOURCE}"
      file_mode "${SBN_SYS}/bun"
    ) 2>/dev/null
  )
  expect_eq 'ensure_system_bun_node repairs metadata even when Bun bytes already match' "${sbn_mode_repaired}" '755'

  SBN_BAD="${SBN_TMP}/bad-bun"
  printf bad >"${SBN_BAD}"
  sbn_bad=$(
    (
      FICUS_SYSTEM_BIN_DIR="${SBN_TMP}/bad-system"
      as_root() { "$@"; }
      runuser() { return 0; }
      ensure_system_bun_node tau-runner "${SBN_BAD}"
    ) >/dev/null 2>&1 && echo accepted || echo rejected
  )
  expect_eq 'ensure_system_bun_node rejects a non-executable source before creating targets' "${sbn_bad}" 'rejected'
  expect_eq 'ensure_system_bun_node rejection leaves system targets absent' \
    "$([[ -e ${SBN_TMP}/bad-system/bun || -e ${SBN_TMP}/bad-system/node ]] && echo changed || echo absent)" 'absent'
else
  log_warn 'skipping the ensure_system_bun_node cases — this host cannot install root:root files'
fi
rm -rf "${SBN_TMP}"

# --- ensure_swapfile state-machine contract --------------------------------
SWAP_LIB_SOURCE=$(<"${SCRIPT_DIR}/lib.sh")
expect_match 'ensure_swapfile exposes an isolated fstab test seam' "${SWAP_LIB_SOURCE}" 'FICUS_SWAP_FSTAB'
expect_match 'ensure_swapfile allocates through a same-directory temporary file' "${SWAP_LIB_SOURCE}" '\.tau-new\.\$\$'
expect_match 'ensure_swapfile capacity-checks with df before allocating' "${SWAP_LIB_SOURCE}" 'df .*--output=avail'
expect_match 'ensure_swapfile exact-matches fstab fields with awk' "${SWAP_LIB_SOURCE}" '\$1 == path && \$3 == "swap"'
expect_match 'ensure_swapfile cleanup clears its RETURN trap before root removal' \
  "${SWAP_LIB_SOURCE}" 'cleanup_swap_temp_on_return[^}]*trap - RETURN'
expect_eq 'ensure_swapfile no longer hard-codes a 4096 MiB dd fallback' \
  "$([[ ${SWAP_LIB_SOURCE} == *'count=4096'* ]] && echo hard-coded || echo derived)" 'derived'

# The cases below RUN ensure_swapfile, which allocates and installs a
# root-owned swapfile — same capability gate as ensure_system_bun_node above.
# (The source-contract assertions just above run everywhere; only the ones
# that execute the helper need a Linux host.)
if [[ ${FICUS_TEST_ROOT_INSTALL} -eq 1 ]]; then
  SWAP_TMP=$(mktemp -d)
  # Active managed path: no allocation, exact fstab row remains singular.
  swap_active_result=$(
    (
      path="${SWAP_TMP}/managed-swap"; : >"${path}"; : >"${SWAP_TMP}/fstab"
      FICUS_SWAP_FSTAB="${SWAP_TMP}/fstab"
      swapon() { [[ $1 == --show=* ]] && printf '%s\n' "${path}"; }
      as_root() { "$@"; }
      ensure_swapfile 1M "${path}"
      ensure_swapfile 1M "${path}"
      awk -v path="${path}" '$1 == path && $3 == "swap" { n++ } END { print n+0 }' "${SWAP_TMP}/fstab"
    ) 2>/dev/null
  )
  expect_eq 'ensure_swapfile active managed path persists exactly one fstab row' "${swap_active_result}" '1'

  swap_duplicate_result=$(
    (
      path="${SWAP_TMP}/duplicate-swap"
      : >"${path}"
      printf '%s none swap sw 0 0\n%s none swap defaults 0 0\n' "${path}" "${path}" >"${SWAP_TMP}/duplicate-fstab"
      FICUS_SWAP_FSTAB="${SWAP_TMP}/duplicate-fstab"
      swapon() { [[ $1 == --show=* ]] && printf '%s\n' "${path}"; }
      as_root() { "$@"; }
      ensure_swapfile 1M "${path}"
      grep -cF "${path} none swap sw 0 0" "${SWAP_TMP}/duplicate-fstab"
      awk -v path="${path}" '$1 == path && $3 == "swap" { n++ } END { print n+0 }' "${SWAP_TMP}/duplicate-fstab"
    ) 2>/dev/null | paste -sd '|' -
  )
  expect_eq 'ensure_swapfile normalizes duplicate managed fstab rows to one canonical row' "${swap_duplicate_result}" '1|1'

  # Unrelated active swap is preserved without allocation or persistence.
  swap_other_result=$(
    (
      : >"${SWAP_TMP}/other-fstab"; FICUS_SWAP_FSTAB="${SWAP_TMP}/other-fstab"
      swapon() { [[ $1 == --show=* ]] && printf '/other-swap\n'; }
      as_root() { printf '%s\n' "$1" >>"${SWAP_TMP}/other.calls"; "$@"; }
      ensure_swapfile 1M "${SWAP_TMP}/new-swap"
      printf '%s|%s' "$([[ -s ${SWAP_TMP}/other-fstab ]] && echo changed || echo empty)" \
        "$([[ -e ${SWAP_TMP}/other.calls ]] && cat "${SWAP_TMP}/other.calls" || echo no-calls)"
    ) 2>/dev/null
  )
  expect_eq 'ensure_swapfile preserves unrelated active swap without root mutations' "${swap_other_result}" 'empty|no-calls'

  # Capacity rejection happens before any allocation/root mutation.
  swap_space_result=$(
    (
      : >"${SWAP_TMP}/space-fstab"; FICUS_SWAP_FSTAB="${SWAP_TMP}/space-fstab"
      swapon() { return 0; }
      df() { printf 'Avail\n1\n'; }
      as_root() { printf called >>"${SWAP_TMP}/space.calls"; "$@"; }
      ensure_swapfile 2M "${SWAP_TMP}/space-swap"
    ) >/dev/null 2>&1 && echo accepted || echo rejected
  )
  expect_eq 'ensure_swapfile rejects insufficient capacity' "${swap_space_result}" 'rejected'
  expect_eq 'ensure_swapfile capacity rejection performs no root mutation' \
    "$([[ -e ${SWAP_TMP}/space.calls ]] && echo called || echo none)" 'none'

  # A failure after root allocation must remove the root-owned temporary file
  # through the root-capable seam rather than leaving a multi-GB orphan.
  swap_cleanup_result=$(
    (
      path="${SWAP_TMP}/cleanup-swap"; temp="${path}.tau-new.$$"
      : >"${SWAP_TMP}/cleanup-fstab"; FICUS_SWAP_FSTAB="${SWAP_TMP}/cleanup-fstab"
      swapon() { return 0; }
      fallocate() { : >"$3"; }
      mkswap() { : >"${SWAP_TMP}/cleanup.calls"; return 1; }
      rm() {
        if [[ $2 == "${temp}" && ${AS_ROOT_CALL:-0} != 1 ]]; then
          return 1
        fi
        command rm "$@"
      }
      as_root() {
        printf '%s\n' "$1" >>"${SWAP_TMP}/cleanup.calls"
        AS_ROOT_CALL=1 "$@"
      }
      ensure_swapfile 1M "${path}"
    ) >/dev/null 2>&1 || true
    if find "${SWAP_TMP}" -maxdepth 1 -name 'cleanup-swap.tau-new.*' -print -quit | grep -q .; then
      cleanup_state=orphaned
    else
      cleanup_state=removed
    fi
    printf '%s|%s' "${cleanup_state}" "$(grep -c '^rm$' "${SWAP_TMP}/cleanup.calls" 2>/dev/null || true)"
  )
  expect_eq 'ensure_swapfile root-cleans its temporary file after allocation failure' \
    "${swap_cleanup_result}" 'removed|1'

  swap_trap_result=$(
    (
      path="${SWAP_TMP}/trap-swap"; : >"${SWAP_TMP}/trap-fstab"
      FICUS_SWAP_FSTAB="${SWAP_TMP}/trap-fstab"
      swapon() { return 0; }; fallocate() { : >"$3"; }; mkswap() { return 1; }
      as_root() { printf '%s\n' "$1" >>"${SWAP_TMP}/trap.calls"; "$@"; }
      ensure_swapfile 1M "${path}" || true
      after_failed_swap_return() { :; }
      after_failed_swap_return
      grep -c '^rm$' "${SWAP_TMP}/trap.calls"
    ) 2>/dev/null
  )
  expect_eq 'ensure_swapfile clears its RETURN trap after failure cleanup' "${swap_trap_result}" '2'

  fstab_fault_result=$(
    (
      fstab="${SWAP_TMP}/fault-fstab"; printf 'ORIGINAL\n' >"${fstab}"
      FICUS_SWAP_FSTAB="${fstab}"
      as_root() { "$@"; }
      awk() {
        if [[ $* == *'{ print }'* ]]; then printf 'PARTIAL\n'; return 1; fi
        command awk "$@"
      }
      ensure_swap_fstab_entry /swapfile >/dev/null 2>&1 && status=accepted || status=rejected
      printf '%s|%s|%s' "${status}" "$(cat "${fstab}")" \
        "$(find "${SWAP_TMP}" -maxdepth 1 -name 'fault-fstab.tau-new.*' -print | wc -l | tr -d ' ')"
    )
  )
  expect_eq 'ensure_swap_fstab_entry fails closed on a mid-stream read error' \
    "${fstab_fault_result}" 'rejected|ORIGINAL|0'

  fstab_sync_fault_result=$(
    (
      fstab="${SWAP_TMP}/sync-fault-fstab"; printf 'ORIGINAL\n' >"${fstab}"
      FICUS_SWAP_FSTAB="${fstab}"
      as_root() { [[ $1 == sync ]] && return 1; "$@"; }
      ensure_swap_fstab_entry /swapfile >/dev/null 2>&1 && status=accepted || status=rejected
      printf '%s|%s|%s' "${status}" "$(cat "${fstab}")" \
        "$(find "${SWAP_TMP}" -maxdepth 1 -name 'sync-fault-fstab.tau-new.*' -print | wc -l | tr -d ' ')"
    )
  )
  expect_eq 'ensure_swap_fstab_entry preserves fstab and cleans staging when fsync fails' \
    "${fstab_sync_fault_result}" 'rejected|ORIGINAL|0'
  rm -rf "${SWAP_TMP}"
else
  log_warn 'skipping the ensure_swapfile runtime cases — this host cannot install root:root files'
fi

# Every supported memory-heavy build reconciles swap first, and every tenant
# path establishes the shared system Bun/Node runtime before building.
for caller in setup-host.sh upgrade-host.sh; do
  expect_eq "${caller} reconciles swap before its build" \
    "$(awk '/ensure_swapfile/{s=NR} /^phase_build$|build_app /{b=NR; if (s && s < b) { print "ordered"; exit }}' "${SCRIPT_DIR}/${caller}")" 'ordered'
done
for caller in setup-host.sh upgrade-host.sh; do
  expect_eq "${caller} installs stable runtime before its build" \
    "$(awk '/ensure_system_bun_node/{s=NR} /^phase_build$|build_app /{b=NR; if (s && s < b) { print "ordered"; exit }}' "${SCRIPT_DIR}/${caller}")" 'ordered'
done
for caller in setup-host.sh upgrade-host.sh; do
  expect_eq "${caller} establishes stable runtime before its build" \
    "$(awk '/ensure_system_bun_node/{s=NR} /^phase_build$|build_app /{b=NR; if (s && s < b) { print "ordered"; exit }}' "${SCRIPT_DIR}/${caller}")" 'ordered'
done
expect_match 'setup-host renders the stable system Bun path' "$(<"${SCRIPT_DIR}/setup-host.sh")" 'BUN_BIN=/usr/local/bin/bun'
expect_match 'upgrade docs require root capability from the invoking non-root operator' \
  "$(<"${SCRIPT_DIR}/README.md")" 'invoking operator must either be root or have non-interactive sudo'
expect_match 'upgrade docs require configured run_user and discoverable Bun source' \
  "$(<"${SCRIPT_DIR}/README.md")" 'Bun source discovery'

# --- bun_path_prepend -------------------------------------------------------
# Regression: upgrade-host.sh died with "required command 'bun' not found" on a
# tenant whose systemd units were happily RUNNING bun, because bun's installer
# only exports its PATH from the shell rc files and a non-interactive ssh shell
# never reads them. The platform suite passed throughout — its fakes had bun on
# PATH. These cases run in subshells so the real PATH is never mutated.

# A box where bun exists ONLY at the installer's location: the failing case.
BP_TMP=$(mktemp -d)
mkdir -p "${BP_TMP}/.bun/bin"
printf '#!/bin/sh\necho 1.3.14\n' >"${BP_TMP}/.bun/bin/bun"
chmod +x "${BP_TMP}/.bun/bin/bun"

bp_found=$(
  HOME="${BP_TMP}" PATH=/usr/bin:/bin bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    have bun && { echo precondition-failed; exit 0; }
    bun_path_prepend
    have bun && echo found || echo missing'
)
expect_eq 'bun_path_prepend finds an rc-only bun installation' "${bp_found}" 'found'

# It must not DIE when bun is genuinely absent — the caller decides.
BP_EMPTY=$(mktemp -d)
bp_absent=$(
  HOME="${BP_EMPTY}" PATH=/usr/bin:/bin bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    bun_path_prepend && echo "returned ok" || echo "returned failure"'
)
expect_eq 'bun_path_prepend is silent when bun is nowhere' "${bp_absent}" 'returned ok'

# Already-resolvable bun: leave PATH exactly as found.
bp_noop=$(
  HOME="${BP_TMP}" PATH="${BP_TMP}/.bun/bin:/usr/bin:/bin" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    before=${PATH}
    bun_path_prepend
    [[ ${PATH} == "${before}" ]] && echo unchanged || echo mutated'
)
expect_eq 'bun_path_prepend does not touch an already-good PATH' "${bp_noop}" 'unchanged'
rm -rf "${BP_TMP}" "${BP_EMPTY}"

# Guard the ORDERING too: a require_cmd that runs before the PATH is repaired is
# the exact shape of the original bug, and it would pass every case above.
expect_eq 'upgrade-host.sh repairs PATH before requiring bun' \
  "$(awk '/bun_path_prepend/{p=NR} /require_cmd bun/{r=NR} END{print (p && r && p < r) ? "ordered" : "unordered"}' \
    "${SCRIPT_DIR}/upgrade-host.sh")" 'ordered'
expect_eq 'setup-host.sh uses the shared helper rather than its own PATH line' \
  "$(grep -c 'bun_path_prepend' "${SCRIPT_DIR}/setup-host.sh")" '1'

# --- build stamp (idempotent build skip) ------------------------------------
# Live evidence: a provision retry against the SAME commit spent 2m44s of a
# 4m41s run (58%) rebuilding output it had already built 2m41s earlier in the
# failed attempt. These tests cover the stamp helpers directly (pure) and
# build_app's actual skip/no-skip/half-fail behaviour via a fake `bun` on
# PATH — the same "fake the command, assert what got called" technique
# bun_path_prepend's tests use above, extended to also let the fake produce
# the files build_app's own assertions require.

file_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"; }

# --- pure helpers: build_stamp_path / build_lock_hash / build_outputs_present
expect_eq 'build_stamp_path lives next to the checkout' \
  "$(build_stamp_path /opt/tau-core)" '/opt/tau-core/.tau-build-stamp'

BS_TMP=$(mktemp -d)
printf 'lockfile contents A' >"${BS_TMP}/bun.lock"
lock_a=$(build_lock_hash "${BS_TMP}")
expect_match 'build_lock_hash: a sha256 hex digest' "${lock_a}" '^[0-9a-f]{64}$'
printf 'lockfile contents B' >"${BS_TMP}/bun.lock"
lock_b=$(build_lock_hash "${BS_TMP}")
expect_eq 'build_lock_hash: changes when bun.lock changes' \
  "$([[ ${lock_a} != "${lock_b}" ]] && echo differs || echo same)" 'differs'
rm -f "${BS_TMP}/bun.lock"
expect_eq 'build_lock_hash: missing bun.lock -> empty (never matches a real stamp)' \
  "$(build_lock_hash "${BS_TMP}")" ''

expect_eq 'build_outputs_present: nothing built yet -> false' \
  "$(build_outputs_present "${BS_TMP}" false && echo yes || echo no)" 'no'
mkdir -p "${BS_TMP}/apps/core/dist" "${BS_TMP}/apps/web/dist"
touch "${BS_TMP}/apps/core/dist/index.js"
expect_eq 'build_outputs_present: worker.js still missing -> false' \
  "$(build_outputs_present "${BS_TMP}" false && echo yes || echo no)" 'no'
touch "${BS_TMP}/apps/core/dist/worker.js"
touch "${BS_TMP}/apps/core/dist/migrate.js"
# Each of these leaves exactly ONE output missing, so every case proves the
# check it names rather than riding on a later one.
expect_eq 'build_outputs_present: core built but CLI bundle missing -> false' \
  "$(build_outputs_present "${BS_TMP}" false && echo yes || echo no)" 'no'
mkdir -p "${BS_TMP}/apps/cli/dist"
touch "${BS_TMP}/apps/cli/dist/tau.js"
expect_eq 'build_outputs_present: core + CLI outputs present, serve_web=false -> true' \
  "$(build_outputs_present "${BS_TMP}" false && echo yes || echo no)" 'yes'
# The migration bundle is a build OUTPUT: the artifact path runs it directly,
# and a git box that skipped its rebuild without one has nothing to migrate
# with. Everything else is present here, so only this check can fail.
rm -f "${BS_TMP}/apps/core/dist/migrate.js"
expect_eq 'build_outputs_present: everything but migrate.js -> false' \
  "$(build_outputs_present "${BS_TMP}" false && echo yes || echo no)" 'no'
touch "${BS_TMP}/apps/core/dist/migrate.js"
expect_eq 'build_outputs_present: with migrate.js back -> true' \
  "$(build_outputs_present "${BS_TMP}" false && echo yes || echo no)" 'yes'
expect_eq 'build_outputs_present: serve_web=true but web/dist/index.html missing -> false' \
  "$(build_outputs_present "${BS_TMP}" true && echo yes || echo no)" 'no'
touch "${BS_TMP}/apps/web/dist/index.html"
expect_eq 'build_outputs_present: core + web outputs present, serve_web=true -> true' \
  "$(build_outputs_present "${BS_TMP}" true && echo yes || echo no)" 'yes'
rm -rf "${BS_TMP}"

# --- build_stamp_is_current: a real (throwaway) git checkout ---------------
BS_GIT=$(mktemp -d)
git -C "${BS_GIT}" init -q -b main
git -C "${BS_GIT}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head1=$(git -C "${BS_GIT}" rev-parse HEAD)
mkdir -p "${BS_GIT}/apps/core/dist" "${BS_GIT}/apps/cli/dist" "${BS_GIT}/apps/web/dist"
touch "${BS_GIT}/apps/core/dist/index.js" "${BS_GIT}/apps/core/dist/worker.js" "${BS_GIT}/apps/core/dist/migrate.js" "${BS_GIT}/apps/cli/dist/tau.js" "${BS_GIT}/apps/web/dist/index.html"
printf 'lock-v1' >"${BS_GIT}/bun.lock"

expect_eq 'build_stamp_is_current: no stamp on disk -> not current' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'

build_stamp_write "${BS_GIT}" true
expect_eq 'build_stamp_is_current: fresh stamp, commit+lock+outputs all match -> current (skip)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'yes'

rm -f "${BS_GIT}/apps/web/dist/index.html"
expect_eq 'build_stamp_is_current: serve_web=true but web output missing -> NOT current' \
  "$(build_stamp_is_current "${BS_GIT}" true && echo yes || echo no)" 'no'
touch "${BS_GIT}/apps/web/dist/index.html"

git -C "${BS_GIT}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
expect_eq 'build_stamp_is_current: HEAD moved past the stamped commit -> NOT current (no skip)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
git -C "${BS_GIT}" reset -q --hard "${head1}"
expect_eq 'build_stamp_is_current: back at the stamped commit -> current again' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'yes'

printf 'lock-v2-different' >"${BS_GIT}/bun.lock"
expect_eq 'build_stamp_is_current: bun.lock content changed -> NOT current (no skip)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
printf 'lock-v1' >"${BS_GIT}/bun.lock"
build_stamp_write "${BS_GIT}" true

rm -f "${BS_GIT}/apps/core/dist/worker.js"
expect_eq 'build_stamp_is_current: a build output was deleted after the stamp -> NOT current (no skip)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
touch "${BS_GIT}/apps/core/dist/worker.js"

rm -f "${BS_GIT}/apps/cli/dist/tau.js"
expect_eq 'build_stamp_is_current: CLI bundle deleted after the stamp -> NOT current (no skip)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
touch "${BS_GIT}/apps/cli/dist/tau.js"

rm -f "${BS_GIT}/apps/core/dist/migrate.js"
expect_eq 'build_stamp_is_current: migrate bundle deleted after the stamp -> NOT current (no skip)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
touch "${BS_GIT}/apps/core/dist/migrate.js"
# Content, not just presence: a truncated/rewritten migrate bundle must
# invalidate the stamp exactly like a rewritten index.js does.
printf 'tampered\n' >"${BS_GIT}/apps/core/dist/migrate.js"
expect_eq 'build_stamp_is_current: migrate bundle CONTENT changed after the stamp -> NOT current' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
: >"${BS_GIT}/apps/core/dist/migrate.js"
expect_eq 'build_stamp_is_current: restoring the stamped migrate bundle -> current again' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'yes'
# An older-format stamp (written before migrate.js was an output) must fail
# CLOSED — a missing field is no proof, not a pass.
grep -v '^FICUS_BUILD_HASH_CORE_MIGRATE=' "$(build_stamp_path "${BS_GIT}")" >"${BS_GIT}/.stamp.legacy"
mv "${BS_GIT}/.stamp.legacy" "$(build_stamp_path "${BS_GIT}")"
expect_eq 'build_stamp_is_current: a legacy stamp with no migrate hash -> NOT current (fails closed)' \
  "$(build_stamp_is_current "${BS_GIT}" false && echo yes || echo no)" 'no'
build_stamp_write "${BS_GIT}" true

build_stamp_clear "${BS_GIT}"
expect_eq 'build_stamp_clear: removes the stamp file' \
  "$([[ -f $(build_stamp_path "${BS_GIT}") ]] && echo present || echo absent)" 'absent'

# --- build_app: skip vs. real build vs. half-failed build -------------------
# A fake `bun` on PATH that records every invocation and, on a "run build" /
# "run build:web" it is actually allowed to reach, drops in the files a real
# build would have produced — so build_app's own [[ -f ... ]] assertions
# still pass on a build that "ran". BUN_FAKE_FAIL_AT lets one case simulate
# the build dying partway through (a crash / OOM kill mid-build).
FAKE_BIN=$(mktemp -d)
cat >"${FAKE_BIN}/bun" <<'FAKEBUN'
#!/bin/sh
set -e
printf '%s\n' "bun $*" >>"${BUN_FAKE_LOG}"
if [ "${BUN_FAKE_FAIL_AT:-}" != "" ] && [ "$*" = "${BUN_FAKE_FAIL_AT}" ]; then
  exit 1
fi
if [ "$1 $2" = "run build" ]; then
  mkdir -p dist
  printf 'built\n' >dist/index.js
  printf 'built\n' >dist/worker.js
  printf 'built\n' >dist/migrate.js
  printf 'built\n' >dist/tau.js
elif [ "$1 $2" = "run build:web" ]; then
  mkdir -p apps/web/dist
  printf 'built\n' >apps/web/dist/index.html
fi
exit 0
FAKEBUN
chmod +x "${FAKE_BIN}/bun"

# Case 1: no stamp at all -> build_app performs a REAL build (fake bun is
# invoked for every step), and a valid stamp exists afterward.
BA_TMP=$(mktemp -d)
git -C "${BA_TMP}" init -q -b main
git -C "${BA_TMP}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'lock-v1' >"${BA_TMP}/bun.lock"
mkdir -p "${BA_TMP}/apps/core" "${BA_TMP}/apps/cli" # build_app's `(cd apps/core && bun run build)` and `(cd apps/cli && bun run build)` need the dirs to pre-exist, as they would in a real checkout
BA_LOG=$(mktemp -u)
: >"${BA_LOG}"
ba_skip1=$(
  PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    build_app "'"${BA_TMP}"'" true
    printf %s "${_tau_build_skipped}"'
)
expect_eq 'build_app: no stamp -> does NOT skip (_tau_build_skipped=false)' "${ba_skip1}" 'false'
expect_eq 'build_app: no stamp -> bun install actually ran' \
  "$(grep -c '^bun install --ignore-scripts$' "${BA_LOG}")" '1'
expect_eq 'build_app: no stamp -> bun run build actually ran (core + cli)' \
  "$(grep -c '^bun run build$' "${BA_LOG}")" '2'
expect_eq 'build_app: no stamp -> bun run build:web actually ran (serve_web=true)' \
  "$(grep -c '^bun run build:web$' "${BA_LOG}")" '1'
expect_eq 'build_app: a real build leaves a stamp that reads back as current' \
  "$(build_stamp_is_current "${BA_TMP}" true && echo yes || echo no)" 'yes'
expect_eq 'build_app: a real build produces the migrate bundle (asserted, not assumed)' \
  "$([[ -f ${BA_TMP}/apps/core/dist/migrate.js ]] && echo built || echo missing)" 'built'

# Case 2: that stamp is now valid for the current commit+lock -> a SECOND
# build_app call must skip entirely: fake bun must NEVER be invoked, and the
# build outputs' mtimes must still be bumped forward (the upgrade path's
# external mtime probe needs this — see lib.sh's comment on build_app).
mtime_before=$(file_mtime "${BA_TMP}/apps/core/dist/index.js")
mtime_migrate_before=$(file_mtime "${BA_TMP}/apps/core/dist/migrate.js")
sleep 1 # coarse (1s) mtime resolution on some filesystems
: >"${BA_LOG}"
ba_skip2=$(
  PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    build_app "'"${BA_TMP}"'" true
    printf %s "${_tau_build_skipped}"'
)
expect_eq 'build_app: matching stamp -> DOES skip (_tau_build_skipped=true)' "${ba_skip2}" 'true'
expect_eq 'build_app: matching stamp -> fake bun is never invoked' \
  "$([[ -s ${BA_LOG} ]] && echo called || echo untouched)" 'untouched'
mtime_after=$(file_mtime "${BA_TMP}/apps/core/dist/index.js")
expect_eq 'build_app: skip path still bumps the output mtime forward (honest re-assertion)' \
  "$([[ ${mtime_after} -gt ${mtime_before} ]] && echo advanced || echo stale)" 'advanced'
expect_eq 'build_app: skip path re-asserts the migrate bundle too' \
  "$([[ $(file_mtime "${BA_TMP}/apps/core/dist/migrate.js") -gt ${mtime_migrate_before} ]] && echo advanced || echo stale)" 'advanced'

ba_log_line=$(
  PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    build_app "'"${BA_TMP}"'" true' 2>&1 >/dev/null
)
expect_match 'build_app: skip path logs the stamped commit and "skipping rebuild"' \
  "${ba_log_line}" 'skipping rebuild'
rm -rf "${BA_TMP}"

# Case 3: a NEW commit invalidates the stamp -> build_app does NOT skip, so
# the mtime genuinely advances via a real rebuild (this is the path the
# platform's upgrade mtime probe relies on; see lib.sh's comment).
BA_TMP2=$(mktemp -d)
git -C "${BA_TMP2}" init -q -b main
git -C "${BA_TMP2}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'lock-v1' >"${BA_TMP2}/bun.lock"
mkdir -p "${BA_TMP2}/apps/core/dist" "${BA_TMP2}/apps/cli/dist" "${BA_TMP2}/apps/web/dist"
touch "${BA_TMP2}/apps/core/dist/index.js" "${BA_TMP2}/apps/core/dist/worker.js" "${BA_TMP2}/apps/core/dist/migrate.js" "${BA_TMP2}/apps/cli/dist/tau.js" "${BA_TMP2}/apps/web/dist/index.html"
build_stamp_write "${BA_TMP2}" true
git -C "${BA_TMP2}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'new commit, stamp now stale'
mtime_stale_before=$(file_mtime "${BA_TMP2}/apps/core/dist/index.js")
sleep 1
: >"${BA_LOG}"
ba_skip3=$(
  PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    build_app "'"${BA_TMP2}"'" false
    printf %s "${_tau_build_skipped}"'
)
expect_eq 'build_app: stamp for an OLD commit -> does NOT skip on the new commit' "${ba_skip3}" 'false'
expect_eq 'build_app: new-commit rebuild -> bun run build actually ran (core + cli)' \
  "$(grep -c '^bun run build$' "${BA_LOG}")" '2'
mtime_stale_after=$(file_mtime "${BA_TMP2}/apps/core/dist/index.js")
expect_eq 'build_app: new-commit rebuild genuinely advances the mtime (probe stays satisfied)' \
  "$([[ ${mtime_stale_after} -gt ${mtime_stale_before} ]] && echo advanced || echo stale)" 'advanced'
rm -rf "${BA_TMP2}"

# Case 4: a build that dies partway through must leave NO stamp — even if a
# (now-stale) stamp existed before this run started. Simulates a crash/OOM
# kill between the core build and the web build.
BA_TMP3=$(mktemp -d)
git -C "${BA_TMP3}" init -q -b main
git -C "${BA_TMP3}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'lock-v1' >"${BA_TMP3}/bun.lock"
mkdir -p "${BA_TMP3}/apps/core/dist" "${BA_TMP3}/apps/cli/dist" "${BA_TMP3}/apps/web/dist"
touch "${BA_TMP3}/apps/core/dist/index.js" "${BA_TMP3}/apps/core/dist/worker.js" "${BA_TMP3}/apps/core/dist/migrate.js" "${BA_TMP3}/apps/cli/dist/tau.js" "${BA_TMP3}/apps/web/dist/index.html"
build_stamp_write "${BA_TMP3}" true
printf 'lock-v2' >"${BA_TMP3}/bun.lock" # invalidates the stamp -> a real build will be attempted
: >"${BA_LOG}"
ba_rc4=0
PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" BUN_FAKE_FAIL_AT='run build:web' bash -c '
  set -euo pipefail
  source "'"${SCRIPT_DIR}"'/lib.sh"
  build_app "'"${BA_TMP3}"'" true' >/dev/null 2>&1 || ba_rc4=$?
expect_eq 'build_app: a build that dies mid-way exits non-zero' \
  "$([[ ${ba_rc4} -ne 0 ]] && echo died || echo survived)" 'died'
expect_eq 'build_app: half-failed build -> no stamp left behind (not even the stale one)' \
  "$([[ -f $(build_stamp_path "${BA_TMP3}") ]] && echo present || echo absent)" 'absent'
rm -rf "${BA_TMP3}"

# Case 5 (the review-blocking gap, reproduced exactly): build_stamp_is_current
# used to check ONLY [[ -f ]] for its outputs. Truncating apps/core/dist/
# index.js to 0 bytes left a file that still exists, so a stamp for the same
# commit+lock still read as current and build_app still skipped — shipping
# the corrupt (0-byte) bundle, and on the upgrade path the skip's
# touch-forward then makes the platform's mtime probe PASS over it. A stamp
# must prove CONTENT (a hash), not just presence.
BA_TMP4=$(mktemp -d)
git -C "${BA_TMP4}" init -q -b main
git -C "${BA_TMP4}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'lock-v1' >"${BA_TMP4}/bun.lock"
# build_app's `(cd apps/core && bun run build)` AND `(cd apps/cli && bun run
# build)` both need their directory to pre-exist. The cli step was added to
# build_app later than this fixture: without apps/cli the build died, the
# `bash -c` around it exited non-zero, and `set -e` ended the whole runner here
# — silently, on every platform, taking the rest of the file with it.
mkdir -p "${BA_TMP4}/apps/core" "${BA_TMP4}/apps/cli"
: >"${BA_LOG}"
PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
  source "'"${SCRIPT_DIR}"'/lib.sh"
  build_app "'"${BA_TMP4}"'" true' >/dev/null
# Baseline: a real (fake-bun) successful build ran and left a stamp that
# reads as current, exactly like a legitimate prior provision/upgrade run.
expect_eq 'build_app corrupt-output repro: baseline build leaves a stamp that reads current' \
  "$(build_stamp_is_current "${BA_TMP4}" true && echo yes || echo no)" 'yes'

printf '' >"${BA_TMP4}/apps/core/dist/index.js" # truncate to 0 bytes -- the reviewer's exact repro; the stamp is untouched
: >"${BA_LOG}"
ba_skip5=$(
  PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    build_app "'"${BA_TMP4}"'" true
    printf %s "${_tau_build_skipped}"'
)
expect_eq 'build_app: index.js truncated to 0 bytes under a valid stamp -> does NOT skip' "${ba_skip5}" 'false'
# Twice: build_app runs `bun run build` once in apps/core and once in apps/cli
# (the cli bundle the webhook actions exec). The point of the assertion is that
# it ran AT ALL rather than being skipped over a corrupt output.
expect_eq 'build_app: truncated-output rebuild -> bun run build actually ran (never ships the corrupt bundle)' \
  "$(grep -c '^bun run build$' "${BA_LOG}")" '2'
rm -rf "${BA_TMP4}"

# Case 6: the same gap, but the OTHER output is the one tampered with
# (worker.js) while index.js is untouched — proves every expected output is
# independently hash-checked, not just the first one.
BA_TMP5=$(mktemp -d)
git -C "${BA_TMP5}" init -q -b main
git -C "${BA_TMP5}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'lock-v1' >"${BA_TMP5}/bun.lock"
mkdir -p "${BA_TMP5}/apps/core" "${BA_TMP5}/apps/cli" # both build_app cd targets must pre-exist
: >"${BA_LOG}"
PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
  source "'"${SCRIPT_DIR}"'/lib.sh"
  build_app "'"${BA_TMP5}"'" false' >/dev/null
printf 'corrupted' >"${BA_TMP5}/apps/core/dist/worker.js" # index.js left alone
: >"${BA_LOG}"
ba_skip6=$(
  PATH="${FAKE_BIN}:${PATH}" BUN_FAKE_LOG="${BA_LOG}" bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    build_app "'"${BA_TMP5}"'" false
    printf %s "${_tau_build_skipped}"'
)
expect_eq 'build_app: worker.js tampered (index.js untouched) under a valid stamp -> does NOT skip' "${ba_skip6}" 'false'
rm -rf "${BA_TMP5}"

# Case 7: an older-format stamp (written before the hash fields existed) must
# NOT be trusted as a free pass just because the commit/lock/existence checks
# all match -- a missing hash field is treated as no proof, same as no stamp.
BS_OLD=$(mktemp -d)
git -C "${BS_OLD}" init -q -b main
git -C "${BS_OLD}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "${BS_OLD}/apps/core/dist"
touch "${BS_OLD}/apps/core/dist/index.js" "${BS_OLD}/apps/core/dist/worker.js"
printf 'lock-v1' >"${BS_OLD}/bun.lock"
{
  printf 'FICUS_BUILD_COMMIT=%s\n' "$(git -C "${BS_OLD}" rev-parse HEAD)"
  printf 'FICUS_BUILD_LOCK_HASH=%s\n' "$(build_lock_hash "${BS_OLD}")"
  printf 'FICUS_BUILD_AT=%s\n' "$(date -u +%FT%TZ)"
} >"$(build_stamp_path "${BS_OLD}")" # deliberately no FICUS_BUILD_HASH_* fields
expect_eq 'build_stamp_is_current: old-format stamp (no hash fields) -> NOT current (no skip)' \
  "$(build_stamp_is_current "${BS_OLD}" false && echo yes || echo no)" 'no'
rm -rf "${BS_OLD}"

rm -rf "${FAKE_BIN}" "${BS_GIT}"
BA_LOG_LEFTOVER=${BA_LOG:-}
[[ -n ${BA_LOG_LEFTOVER} ]] && rm -f "${BA_LOG_LEFTOVER}"

# --- upgrade_result_message: the same-commit / build-skipped resolution ----
# upgrade-host.sh's mtime probe interaction (the hosted control plane's verifyUpgrade,
# which requires apps/core/dist/index.js's mtime to have strictly increased):
# a NEW commit always rebuilds for real (build_app's own mtime bump above),
# so that path is untouched. A SAME-commit re-run with a valid stamp instead
# gets an honest "nothing to do" message rather than the old (now potentially
# false) "rebuilt" claim — while build_app's skip path still bumps the mtime
# and upgrade-host.sh still restarts services, so the probe itself still
# passes; this message is purely what the operator sees.
expect_eq 'upgrade_result_message: different commits -> "upgraded A -> B"' \
  "$(upgrade_result_message 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' false)" \
  'upgraded aaaaaaaaaaaa → bbbbbbbbbbbb'
expect_eq 'upgrade_result_message: same commit + build skipped -> honest no-op' \
  "$(upgrade_result_message 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' true)" \
  'already at aaaaaaaaaaaa, build current — nothing to do (migrations re-checked, services restarted)'
expect_eq 'upgrade_result_message: same commit but build NOT skipped -> the old "rebuilt anyway" wording' \
  "$(upgrade_result_message 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' false)" \
  'already at aaaaaaaaaaaa — rebuilt and restarted anyway (idempotent re-run)'

# upgrade-host.sh must actually use this function (not a hand-rolled
# duplicate of the same branching) and must feed it build_app's own
# _tau_build_skipped rather than assuming false — that's what keeps this file
# from silently drifting back to the "always claims rebuilt" bug.
expect_eq 'upgrade-host.sh calls the shared upgrade_result_message helper' \
  "$(grep -c 'upgrade_result_message "${BEFORE_SHA}" "${AFTER_SHA}"' "${SCRIPT_DIR}/upgrade-host.sh")" '1'
expect_eq 'upgrade-host.sh feeds it build_app'"'"'s own _tau_build_skipped' \
  "$(grep -c '\${_tau_build_skipped:-false}' "${SCRIPT_DIR}/upgrade-host.sh")" '1'


# --- phase_step ---------------------------------------------------------
# The marker is a CONTRACT with run-toolkit.ts. It must land on stdout (the
# only stream that pump() scans), while the human banner stays on stderr.
ps_out=$(
  bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    phase_step preflight "phase 0/8: preflight"
    phase_step build "phase 2/8: dependencies + build"' 2>/dev/null
)
expect_eq 'phase_step marker 1 is on stdout' "$(printf '%s' "${ps_out}" | sed -n 1p)" 'FICUS_PHASE=1/13 preflight'
expect_eq 'phase_step ordinal increments' "$(printf '%s' "${ps_out}" | sed -n 2p)" 'FICUS_PHASE=2/13 build'

ps_err=$(
  bash -c '
    source "'"${SCRIPT_DIR}"'/lib.sh"
    phase_step preflight "phase 0/8: preflight"' 2>&1 >/dev/null
)
expect_eq 'phase_step still prints the human banner on stderr' \
  "$([[ ${ps_err} == *'==>'*'preflight'* ]] && echo yes || echo no)" 'yes'
expect_eq 'the human banner never leaks onto stdout' \
  "$([[ ${ps_out} == *'==>'* ]] && echo leaked || echo clean)" 'clean'

# The load-bearing guard: a phase added without a marker would silently
# freeze a customer's progress display, with nothing failing anywhere.
#
# Anchored to start-of-line-plus-indentation, NOT bare '^phase_step ' (every
# call site sits inside a function body) and NOT an unanchored match (which
# would also count a commented-out `# phase_step ...`, inflating the total and
# letting the guard pass while a real phase went unmarked).
declared=$(grep -cE '^[[:space:]]*phase_step ' "${SCRIPT_DIR}/setup-host.sh" || true)
expect_eq 'every phase in setup-host.sh goes through phase_step' \
  "$(grep -c 'log_step "phase' "${SCRIPT_DIR}/setup-host.sh" || true)" '0'
expect_eq 'FICUS_PHASE_TOTAL matches the number of phase_step call sites' \
  "${declared}" "$(bash -c 'source "'"${SCRIPT_DIR}"'/lib.sh"; printf %s "${FICUS_PHASE_TOTAL}"')"

# --- health probes hit the core's real public route -------------------------
# The core's public liveness route is GET /health (apps/core/src/index.ts);
# /api/health does not exist on the core, so probing it can only "succeed" by
# accident (a proxy answering anything). Stub curl as a shell function that
# records the argv it was given and emits FAKE_CODE as the http code.
HEALTH_SPY=$(mktemp)
FAKE_CODE=200
curl() {
  printf '%s\n' "$*" >>"${HEALTH_SPY}"
  printf '%s' "${FAKE_CODE}"
}
probe_status() {
  "$@" >/dev/null 2>&1 && printf ok || printf no
}

FAKE_CODE=200
expect_eq 'api_is_up: 200 means up' "$(probe_status api_is_up 'http://127.0.0.1:3000')" 'ok'
FAKE_CODE=401
expect_eq 'api_is_up: 401 means up (auth-gated)' "$(probe_status api_is_up 'http://127.0.0.1:3000')" 'ok'
FAKE_CODE=404
expect_eq 'api_is_up: 404 means down' "$(probe_status api_is_up 'http://127.0.0.1:3000')" 'no'
expect_eq 'api_is_up probes GET /health' "$(grep -c 'http://127.0.0.1:3000/health' "${HEALTH_SPY}" || true)" '3'
expect_eq 'api_is_up never probes /api/health' "$(grep -c '/api/health' "${HEALTH_SPY}" || true)" '0'

: >"${HEALTH_SPY}"
FAKE_CODE=200
expect_eq 'core_api_health_ok: 200 means ok' "$(probe_status core_api_health_ok 3000)" 'ok'
FAKE_CODE=401
expect_eq 'core_api_health_ok: 401 means ok' "$(probe_status core_api_health_ok 3000)" 'ok'
expect_eq 'core_api_health_ok probes GET /health' "$(grep -c 'http://127.0.0.1:3000/health' "${HEALTH_SPY}" || true)" '2'
: >"${HEALTH_SPY}"
FAKE_CODE=404
expect_eq 'core_api_health_ok: 404 means not ok' "$(probe_status core_api_health_ok 3000)" 'no'
# 404 on the first family falls through to the IPv6 loopback family.
expect_eq 'core_api_health_ok tried both address families on /health' \
  "$(grep -c 'http://\[::1\]:3000/health' "${HEALTH_SPY}" || true)" '1'
expect_eq 'core_api_health_ok never probes /api/health' "$(grep -c '/api/health' "${HEALTH_SPY}" || true)" '0'
unset -f curl
rm -f "${HEALTH_SPY}"

# ---------------------------------------------- gh version floor (`gh --attach`)

expect_eq 'version_at_least: equal versions pass' \
  "$(version_at_least 2.99.0 2.99.0 && echo yes || echo no)" 'yes'
expect_eq 'version_at_least: newer passes' \
  "$(version_at_least 2.99.1 2.99.0 && echo yes || echo no)" 'yes'
expect_eq 'version_at_least: older fails' \
  "$(version_at_least 2.98.9 2.99.0 && echo yes || echo no)" 'no'
# The reason this uses `sort -V` and not a lexical or float compare: 2.100.0 is
# NEWER than 2.99.0, and both of those get it backwards.
expect_eq 'version_at_least: 2.100.0 is newer than 2.99.0' \
  "$(version_at_least 2.100.0 2.99.0 && echo yes || echo no)" 'yes'
expect_eq 'version_at_least: empty installed version fails closed' \
  "$(version_at_least '' 2.99.0 && echo yes || echo no)" 'no'

# cmd_semver parses gh's actual output shape.
gh() { printf 'gh version 2.99.0 (2026-08-14)\nhttps://github.com/cli/cli/releases/tag/v2.99.0\n'; }
expect_eq 'cmd_semver extracts gh version' "$(cmd_semver gh)" '2.99.0'

# The check only speaks for the `host` runtime: every other runtime pins gh in
# its sandbox image, so the operator's own gh is irrelevant there.
gh() { printf 'gh version 2.50.0 (2025-01-01)\n'; }
expect_eq 'check_host_runtime_gh: silent for docker-sysbox even with old gh' \
  "$(check_host_runtime_gh docker-sysbox 2>&1)" ''
expect_eq 'check_host_runtime_gh: silent for k8s even with old gh' \
  "$(check_host_runtime_gh k8s 2>&1)" ''
expect_match 'check_host_runtime_gh: warns for host with old gh' \
  "$(check_host_runtime_gh host 2>&1)" '2\.50\.0 is older than 2\.99\.0'
# Warn, never abort: setup must survive an old gh, because gh is needed for one
# agent capability rather than for running Tau.
expect_eq 'check_host_runtime_gh: old gh does not fail the caller' \
  "$(check_host_runtime_gh host >/dev/null 2>&1 && echo ok || echo died)" 'ok'

gh() { printf 'gh version 2.99.0 (2026-08-14)\n'; }
expect_eq 'check_host_runtime_gh: silent for host when gh is new enough' \
  "$(check_host_runtime_gh host 2>&1)" ''
unset -f gh

# gh absent entirely is a warning too, not a hard failure.
# lib.sh's own have() is put back afterwards: `unset -f have` used to remove it
# for the rest of the run, silently skipping every later `if have …` case.
HAVE_SAVED=$(declare -f have)
have() { [[ $1 != gh ]]; }
expect_match 'check_host_runtime_gh: warns when gh is missing' \
  "$(check_host_runtime_gh host 2>&1)" 'gh is not installed'
expect_eq 'check_host_runtime_gh: missing gh does not fail the caller' \
  "$(check_host_runtime_gh host >/dev/null 2>&1 && echo ok || echo died)" 'ok'
eval "${HAVE_SAVED}"
unset HAVE_SAVED

# =============================================================================
# Backup render extraction + retarget-backup.sh helpers
# =============================================================================

# --- render_backup_script_content: setup-host.sh's render is byte-identical --
# The golden reference is a VERBATIM copy of setup-host.sh's
# render_backup_script body from before the sed program moved into lib.sh.
# setup-host.sh's CURRENT render_backup_script (a wrapper now) is lifted out
# of the file and run with the same globals phase_backup sees; both must
# produce the same bytes, for both database modes.
RBS_TMP=$(mktemp -d)
_legacy_render_backup_script() {
  sed -e "s|@DEST@|${SRC_DEST}|g" \
    -e "s|@HOME_DIR@|${BACKUP_HOME_DIR}|g" \
    -e "s|@DB_MODE@|${DB_MODE}|g" \
    -e "s|@DB_CONTAINER@|${DB_CONTAINER}|g" \
    -e "s|@S3_ENDPOINT@|${BACKUP_S3_ENDPOINT}|g" \
    -e "s|@S3_REGION@|${BACKUP_S3_REGION}|g" \
    -e "s|@S3_BUCKET@|${BACKUP_S3_BUCKET}|g" \
    -e "s|@S3_PREFIX@|${BACKUP_S3_PREFIX}|g" \
    -e "s|@BACKUP_ENV_FILE@|${BACKUP_ENV_TARGET_LEGACY}|g" \
    "${SCRIPT_DIR}/tau-backup.sh.tmpl"
}
for rbs_mode in container external; do
  (
    unset BACKUP_SCRIPT_PATH BACKUP_ENV_TARGET
    source "${SCRIPT_DIR}/lib.sh"
    SRC_DEST=/opt/tau-core BACKUP_HOME_DIR=/home/tau/.tau DB_MODE=${rbs_mode} DB_CONTAINER=tau-postgres
    BACKUP_S3_ENDPOINT=https://nyc3.digitaloceanspaces.com BACKUP_S3_REGION=nyc3
    BACKUP_S3_BUCKET=tau-backups BACKUP_S3_PREFIX=tenants/acct-1/acme
    BACKUP_ENV_TARGET_LEGACY='/etc/tau/backup.env' # setup-host.sh's old literal
    eval "$(sed -n '/^render_backup_script() {$/,/^}$/p' "${SCRIPT_DIR}/setup-host.sh")"
    declare -F render_backup_script >/dev/null && : >"${RBS_TMP}/${rbs_mode}.found"
    _legacy_render_backup_script >"${RBS_TMP}/${rbs_mode}.legacy"
    render_backup_script >"${RBS_TMP}/${rbs_mode}.new"
  )
  expect_eq "setup-host.sh's render_backup_script is still defined (${rbs_mode})" \
    "$([[ -e ${RBS_TMP}/${rbs_mode}.found ]] && echo yes || echo no)" 'yes'
  expect_eq "setup-host.sh renders tau-backup.sh byte-identically after the extraction (${rbs_mode})" \
    "$(cmp -s "${RBS_TMP}/${rbs_mode}.legacy" "${RBS_TMP}/${rbs_mode}.new" && echo same || echo differs)" 'same'
  expect_eq "the extracted render is non-trivial (${rbs_mode}: no @TOKEN@ left, bucket substituted)" \
    "$(grep -c '@[A-Z_]*@' "${RBS_TMP}/${rbs_mode}.new" || true) $(grep -c "^S3_BUCKET='tau-backups'\$" "${RBS_TMP}/${rbs_mode}.new")" '0 1'
done
expect_eq 'backup paths default to what setup-host.sh always used' \
  "$(
    unset BACKUP_SCRIPT_PATH BACKUP_ENV_TARGET
    source "${SCRIPT_DIR}/lib.sh"
    printf '%s %s' "${BACKUP_SCRIPT_PATH}" "${BACKUP_ENV_TARGET}"
  )" '/usr/local/bin/tau-backup.sh /etc/tau/backup.env'
expect_eq 'setup-host.sh no longer defines the backup paths itself (one definition, in lib.sh)' \
  "$(grep -cE '^BACKUP_(SCRIPT_PATH|ENV_TARGET)=' "${SCRIPT_DIR}/setup-host.sh" || true)" '0'
# phase_backup's backup.env render is unchanged (render_backup_env_content was
# already in lib.sh and has its own golden test above): same call, same args.
expect_eq "phase_backup still renders backup.env with the same call" \
  "$(grep -cF 'render_backup_env_content real "${BACKUP_S3_ACCESS_KEY_VALUE}" "${BACKUP_S3_SECRET_KEY_VALUE}" "${BACKUP_PASSPHRASE_VALUE}"' "${SCRIPT_DIR}/setup-host.sh")" '1'
expect_eq "phase_backup still installs backup.env 0600 root and tau-backup.sh 0755 root at the lib.sh paths" \
  "$(grep -cF 'install_rendered 0600 root root "${BACKUP_ENV_TARGET}"' "${SCRIPT_DIR}/setup-host.sh") $(grep -cF 'install_rendered --check-placeholders 0755 root root "${BACKUP_SCRIPT_PATH}"' "${SCRIPT_DIR}/setup-host.sh")" '1 1'

# setup-host.sh --dry-run with backups on still plans the same files.
if yq_is_mikefarah; then
  cat >"${RBS_TMP}/backup.yaml" <<'EOF'
source:
  mode: git-https
  repo: https://github.com/ficushq/tau.git
  ref: main
core:
  origin: https://acme.ficus.sh
  env:
    HOME_DIR: /home/tau/.tau
database:
  mode: external
runtime:
  sandbox: docker-socket
secrets:
  password_env: PLATFORM_TAU_PASSWORD
backup:
  enabled: true
  s3_endpoint: https://nyc3.digitaloceanspaces.com
  s3_region: nyc3
  s3_bucket: tau-backups
  s3_prefix: tenants/acct-1/acme
EOF
  rbs_dry=$(FICUS_SETUP_DATABASE_DSN='postgres://u:p@h:5432/tau' FICUS_BACKUP_S3_ACCESS_KEY='AKIADRYRUN123' \
    FICUS_BACKUP_S3_SECRET_KEY='dry-run-secret-value' FICUS_BACKUP_PASSPHRASE='dry-run-passphrase' \
    bash "${SCRIPT_DIR}/setup-host.sh" --config "${RBS_TMP}/backup.yaml" --dry-run 2>/dev/null) || true
  expect_contains_line() { # DESCRIPTION CONTENT LINE
    if grep -qxF -- "$3" <<<"$2"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      log_error "FAIL: $1 — no line exactly '$3'"
    fi
  }
  expect_contains_line 'setup-host --dry-run (backup on): plans the script render at the same path' "${rbs_dry}" \
    '  render /usr/local/bin/tau-backup.sh from tau-backup.sh.tmpl (dest=/opt/tau-core, db.mode=external, s3=https://nyc3.digitaloceanspaces.com/tau-backups)'
  expect_contains_line 'setup-host --dry-run (backup on): plans backup.env at the same path' "${rbs_dry}" \
    '  write /etc/tau/backup.env (0600 root-owned; secrets redacted below):'
  unset -f expect_contains_line
else
  log_warn "mikefarah yq not on PATH — skipping setup-host.sh backup dry-run test"
fi
rm -rf "${RBS_TMP}"

# --- helper-injection harness ---------------------------------------------------
# Each failure case runs a helper in BOTH contexts:
#   plain      — `( set -e; setup; helper … )` as a bare statement (errexit live)
#   suppressed — the same subshell as an `if` condition, where bash ignores
#                errexit for everything inside it (the retarget scripts' shape)
# HI_RC is the subshell's status; HI_OUT is what the subshell printed after
# the helper returned (only reached when errexit did not abort it) — so the
# suppressed context proves the helper RETURNS non-zero on its own, without
# errexit's help.
HI_OUT_FILE=$(mktemp)
hi_invoke() { # CTX SETUP_FN CMD...
  local ctx=$1 setup=$2
  shift 2
  # A ( … ) subshell, not $( … ): the suppression under test is the one a
  # subshell used as an if-condition gets (bash 3.2 does not extend it into a
  # command substitution the same way).
  if [[ ${ctx} == plain ]]; then
    set +e
    (
      set -e
      "${setup}"
      "$@" 2>/dev/null
      printf 'returned=0'
    ) >"${HI_OUT_FILE}"
    HI_RC=$?
    set -e
  elif (
    set -e
    "${setup}"
    "$@" 2>/dev/null
    printf 'returned=%s' "$?"
  ) >"${HI_OUT_FILE}"; then
    HI_RC=0
  else
    HI_RC=$?
  fi
  HI_OUT=$(cat "${HI_OUT_FILE}")
}
hi_expect_failed() { # LABEL — the helper failed in HI's last context
  expect_eq "$1: fails" "$([[ ${HI_RC} -ne 0 || ${HI_OUT} == *returned=[1-9]* ]] && echo failed || echo "succeeded (${HI_OUT})")" 'failed'
}
hi_none() { :; }

# --- read_file_exact ------------------------------------------------------------
RFE_TMP=$(mktemp -d)
printf 'a\nb\n\n' >"${RFE_TMP}/nl"
printf 'no-newline' >"${RFE_TMP}/nonl"
: >"${RFE_TMP}/empty"
printf 'caf\xc3\xa9 \xe2\x9c\x93\n' >"${RFE_TMP}/utf8"
for rfe_f in nl nonl empty utf8; do
  rfe_v='unset'
  read_file_exact "${RFE_TMP}/${rfe_f}" rfe_v
  expect_eq "read_file_exact: exact bytes (${rfe_f}), trailing newlines kept" \
    "$(printf '%s' "${rfe_v}" | od -An -tx1 | tr -d ' \n')" "$(od -An -tx1 "${RFE_TMP}/${rfe_f}" | tr -d ' \n')"
done
# shellcheck disable=SC2030,SC2031 # the locale change is meant to stay inside each subshell
for rfe_locale in C en_US.UTF-8 C.UTF-8; do
  expect_eq "read_file_exact: a UTF-8 file is not mistaken for a short read (LC_ALL=${rfe_locale})" \
    "$(
      export LC_ALL=${rfe_locale}
      read_file_exact "${RFE_TMP}/utf8" rfe_v 2>/dev/null && echo ok || echo refused
    )" 'ok'
done
printf 'first\nsecond\nthird\n' >"${RFE_TMP}/f"
printf 'A=1\0B=2\n' >"${RFE_TMP}/nul"
RFE_FILE="${RFE_TMP}/f"
rfe_short_read() { cat() { command head -n 1 "${RFE_FILE}"; return 0; }; }
rfe_read_error() { cat() { command head -n 1 "${RFE_FILE}"; return 1; }; }
rfe_case() { # LABEL SETUP FILE
  local ctx
  for ctx in plain suppressed; do
    hi_invoke "${ctx}" "$2" rfe_check "$3"
    hi_expect_failed "read_file_exact (${1}, ${ctx})"
    [[ ${ctx} == suppressed ]] &&
      expect_eq "read_file_exact (${1}, ${ctx}): leaves VAR untouched" "${HI_OUT}" 'VAR=untouched returned=1'
  done
}
rfe_check() { # FILE — prints VAR after the call, then lets hi_invoke print the status
  local VAR=untouched rc=0
  read_file_exact "$1" VAR || rc=$?
  printf 'VAR=%s ' "${VAR}"
  return "${rc}"
}
rfe_case 'missing file' hi_none "${RFE_TMP}/nope"
if [[ ${EUID} -eq 0 ]]; then
  printf 'SKIP: read_file_exact unreadable-file injection (root ignores mode 000; covered by the unprivileged run)\n' >&2
else
  cp "${RFE_TMP}/f" "${RFE_TMP}/locked"
  chmod 000 "${RFE_TMP}/locked"
  rfe_case 'unreadable file' hi_none "${RFE_TMP}/locked"
  chmod 600 "${RFE_TMP}/locked"
fi
rfe_case 'read returns only part of the file, exit 0' rfe_short_read "${RFE_TMP}/f"
rfe_case 'read errors mid-file' rfe_read_error "${RFE_TMP}/f"
rfe_case 'file contains a NUL byte' hi_none "${RFE_TMP}/nul"
rm -rf "${RFE_TMP}"

# --- stage_file_replacement --------------------------------------------------------
SFR_TMP=$(mktemp -d)
SFR_DEST="${SFR_TMP}/target.env"
sfr_reset() {
  printf 'OLD=1\n' >"${SFR_DEST}"
  chmod 640 "${SFR_DEST}"
}
sfr_reset
sfr_staged=''
sfr_content="NEW='it'\\''s \$(x)'"$'\n\n'
stage_file_replacement "${SFR_DEST}" "${sfr_content}" sfr_staged
expect_eq 'stage_file_replacement: stages next to DEST (same directory, hidden name)' \
  "$([[ $(dirname "${sfr_staged}") == "${SFR_TMP}" && $(basename "${sfr_staged}") == .target.env.?????? ]] && echo yes || echo "no: ${sfr_staged}")" 'yes'
expect_eq 'stage_file_replacement: the staged file holds exactly CONTENT (trailing newlines too)' \
  "$(od -An -tx1 "${sfr_staged}" | tr -d ' \n')" "$(printf '%s' "${sfr_content}" | od -An -tx1 | tr -d ' \n')"
expect_eq "stage_file_replacement: the staged file carries DEST's mode and owner" \
  "$(_file_mode_owner_group "${sfr_staged}")" "$(_file_mode_owner_group "${SFR_DEST}")"
expect_eq 'stage_file_replacement: DEST itself is untouched' "$(cat "${SFR_DEST}")" 'OLD=1'
rm -f "${sfr_staged}"
sfr_mktemp_fails() { mktemp() { return 1; }; }
sfr_write_fails() {
  printf() {
    [[ $# -eq 2 && $1 == '%s' ]] && return 1
    # shellcheck disable=SC2059 # pass-through shim: forwards the caller's own format
    builtin printf "$@"
  }
}
sfr_chmod_fails() { chmod() { return 1; }; }
sfr_chown_fails() { chown() { return 1; }; }
sfr_check() { # DEST — prints VAR after the call
  local VAR=untouched rc=0
  stage_file_replacement "$1" 'NEW=2' VAR || rc=$?
  builtin printf 'VAR=%s ' "${VAR}"
  return "${rc}"
}
sfr_case() { # LABEL SETUP [DEST]
  local ctx dest=${3:-${SFR_DEST}}
  for ctx in plain suppressed; do
    sfr_reset
    hi_invoke "${ctx}" "$2" sfr_check "${dest}"
    hi_expect_failed "stage_file_replacement (${1}, ${ctx})"
    [[ ${ctx} == suppressed ]] &&
      expect_eq "stage_file_replacement (${1}, ${ctx}): leaves VAR empty" "${HI_OUT}" 'VAR= returned=1'
    expect_eq "stage_file_replacement (${1}, ${ctx}): DEST is byte-identical" "$(cat "${SFR_DEST}")" 'OLD=1'
    expect_eq "stage_file_replacement (${1}, ${ctx}): no staged file is left behind" \
      "$(find "${SFR_TMP}" -maxdepth 1 -name '.target.env.*' | wc -l | tr -d ' ')" '0'
  done
}
sfr_case 'DEST missing' hi_none "${SFR_TMP}/nope.env"
sfr_case 'mktemp fails' sfr_mktemp_fails
sfr_case 'the staged write fails' sfr_write_fails
sfr_case 'chmod fails' sfr_chmod_fails
sfr_case 'chown fails' sfr_chown_fails
rm -rf "${SFR_TMP}"

# --- sh_single_unquote / sh_env_parse ------------------------------------------------
for ssu_v in '' 'plain' "it's" "a'b'c" "''" ' spaced out ' '$(x) `y` "z" \ end' $'tab\there' 'AKIA/abc+def='; do
  ssu_out='unset'
  sh_single_unquote "$(sh_single_quote "${ssu_v}")" ssu_out
  expect_eq "sh_single_unquote inverts sh_single_quote: $(printf '%q' "${ssu_v}")" "${ssu_out}" "${ssu_v}"
done
ssu_out='unset'
sh_single_unquote 'DO00ABC/def+ghi=' ssu_out
expect_eq 'sh_single_unquote: a bare shell-inert word reads as itself' "${ssu_out}" 'DO00ABC/def+ghi='
# shellcheck disable=SC2016,SC2088 # literal shell syntax the parser must refuse
for ssu_bad in '"dq"' '$HOME' "'unterminated" "bare'quoted'" 'two words' '`id`' '~/x' "'a'b"; do
  ssu_out=untouched
  ssu_rc=0
  sh_single_unquote "${ssu_bad}" ssu_out || ssu_rc=$?
  expect_eq "sh_single_unquote refuses $(printf '%q' "${ssu_bad}") (and leaves VAR alone)" "${ssu_rc}:${ssu_out}" '1:untouched'
done

sep_raw="# comment

A='first'
B=bare-word
A='it'\\''s last'
"
sep_a='' sep_b='' sep_c=''
sh_env_parse "${sep_raw}" 'test file' A:sep_a B:sep_b C:sep_c
expect_eq 'sh_env_parse: last assignment wins, quotes decoded' "${sep_a}" "it's last"
expect_eq 'sh_env_parse: bare value' "${sep_b}" 'bare-word'
expect_eq 'sh_env_parse: an absent key reads as empty' "${sep_c}" ''
sep_err=$(sh_env_parse "A='x'
SNEAKY='hunter2-value'
" 'test file' A:sep_a 2>&1) && sep_rc=0 || sep_rc=$?
expect_eq 'sh_env_parse: an unexpected key fails' "${sep_rc}" '1'
expect_match 'sh_env_parse: names the line of the unexpected key' "${sep_err}" 'test file line 2: unexpected key'
expect_not_match 'sh_env_parse: never prints the unexpected key text (it may be secret bytes)' "${sep_err}" 'SNEAKY'
# A passphrase spanning lines: its continuation looks like KEY=VALUE, and the
# "key" is part of the secret — only the line number may be printed.
sep_err=$(sh_env_parse "A='x'
PASS='first half
HUNTER2PART='second half'
" 'test file' A:sep_a PASS:sep_b 2>&1) && sep_rc=0 || sep_rc=$?
expect_eq 'sh_env_parse: a multi-line quoted value fails' "${sep_rc}" '1'
expect_not_match 'sh_env_parse: a multi-line value leaks none of its continuation' "${sep_err}" 'HUNTER2PART|second half|first half'

expect_not_match 'sh_env_parse: never prints the value' "${sep_err}" 'hunter2'
sep_err=$(sh_env_parse "A=\"hunter2-value\"" 'test file' A:sep_a 2>&1) && sep_rc=0 || sep_rc=$?
expect_eq 'sh_env_parse: a double-quoted (shell-evaluated) value fails' "${sep_rc}" '1'
expect_not_match 'sh_env_parse: a bad value is not printed' "${sep_err}" 'hunter2'
sep_err=$(sh_env_parse "export A='hunter2-value'" 'test file' A:sep_a 2>&1) && sep_rc=0 || sep_rc=$?
expect_eq 'sh_env_parse: a non-assignment line fails' "${sep_rc}" '1'
expect_not_match 'sh_env_parse: a bad line is not printed' "${sep_err}" 'hunter2'
# Non-ASCII bytes (valid UTF-8, and an invalid lone 0xff) inside single
# quotes are passed through byte-for-byte under LC_ALL=C — what
# retarget-backup.sh runs with.
sep_bytes=$'p\xc3\xa4ss \xe2\x9c\x93 \xff end'
sep_bytes_raw="PASS=$(sh_single_quote "${sep_bytes}")"
sep_b=''
# shellcheck disable=SC2030,SC2031 # the locale change is meant to stay inside the subshell
(
  export LC_ALL=C
  sh_env_parse "${sep_bytes_raw}" 'test file' PASS:sep_b &&
    printf '%s' "${sep_b}" >"${HI_OUT_FILE}.bytes"
) 2>/dev/null || true
expect_eq 'sh_env_parse under LC_ALL=C: a non-ASCII single-quoted value round-trips byte-exactly' \
  "$(od -An -tx1 "${HI_OUT_FILE}.bytes" 2>/dev/null | tr -d ' \n')" "$(printf '%s' "${sep_bytes}" | od -An -tx1 | tr -d ' \n')"
rm -f "${HI_OUT_FILE}.bytes"
# In a suppressed context it must still RETURN non-zero on its own.
if sh_env_parse "BAD LINE" 'test file' A:sep_a 2>/dev/null; then sep_rc=0; else sep_rc=$?; fi
expect_eq 'sh_env_parse: returns non-zero in an if-condition too' "${sep_rc}" '1'

# --- s3_list_probe ---------------------------------------------------------------
S3P_TMP=$(mktemp -d)
s3p_run() { # STATUS|exit:N — runs the probe against a curl function; sets S3P_RC and S3P_ERR
  S3P_RC=0
  S3P_ERR=$(
    curl() {
      local a prev=''
      builtin printf '%s\n' "$@" >"${S3P_TMP}/argv"
      for a in "$@"; do
        [[ ${prev} == --config ]] && command cat "${a}" >"${S3P_TMP}/config"
        prev=${a}
      done
      [[ ${S3P_ANSWER} == exit:* ]] && return "${S3P_ANSWER#exit:}"
      builtin printf '%s' "${S3P_ANSWER}"
    }
    s3_list_probe https://sfo3.example.com sfo3 ficus-backups tenants/a/b 'AKIA-ID' 'se"cr\et-VALUE' 2>&1
  ) || S3P_RC=$?
}
S3P_ANSWER=200 s3p_run
expect_eq 's3_list_probe: HTTP 200 passes' "${S3P_RC}" '0'
expect_eq 's3_list_probe: one ListObjectsV2 of the bucket under the prefix, max-keys=1' \
  "$(tail -n 1 "${S3P_TMP}/argv")" 'https://sfo3.example.com/ficus-backups?list-type=2&max-keys=1&prefix=tenants/a/b/'
expect_eq 's3_list_probe: SigV4 for the given region' "$(grep -cxF 'aws:amz:sfo3:s3' "${S3P_TMP}/argv")" '1'
expect_eq 's3_list_probe: the secret is not on argv' "$(grep -c 'VALUE' "${S3P_TMP}/argv" || true)" '0'
expect_eq 's3_list_probe: credentials travel in the curl config, escaped' "$(cat "${S3P_TMP}/config")" 'user = "AKIA-ID:se\"cr\\et-VALUE"'
S3P_ANSWER=403 s3p_run
expect_eq 's3_list_probe: HTTP 403 fails' "${S3P_RC}" '1'
expect_match 's3_list_probe: HTTP 403 names the status' "${S3P_ERR}" 'returned HTTP 403'
expect_not_match 's3_list_probe: never prints the secret' "${S3P_ERR}" 'VALUE'
S3P_ANSWER=exit:6 s3p_run
expect_eq 's3_list_probe: a curl failure fails' "${S3P_RC}" '1'
expect_match 's3_list_probe: a curl failure names the curl exit' "${S3P_ERR}" 'curl exit 6'
# The REAL curl must accept the argv (a typo'd option would exit 2 before
# connecting): against a closed local port it must get as far as connecting.
if have curl; then
  s3p_real=$(s3_list_probe https://127.0.0.1:9 us-east-1 b p 'AKIA' 'secret' 2>&1) && s3p_real_rc=0 || s3p_real_rc=$?
  expect_eq 's3_list_probe (real curl): a closed port fails' "${s3p_real_rc}" '1'
  expect_match 's3_list_probe (real curl): the argv is valid — it fails connecting (exit 7), not parsing (exit 2)' "${s3p_real}" 'curl exit 7'
fi
rm -rf "${S3P_TMP}"

# --- backup_file ------------------------------------------------------------------
BF_TMP=$(mktemp -d)
printf 'secret\n' >"${BF_TMP}/x.env"
chmod 600 "${BF_TMP}/x.env"
bf_one=$(backup_file "${BF_TMP}/x.env" 2>/dev/null)
bf_two=$(backup_file "${BF_TMP}/x.env" 2>/dev/null)
expect_eq 'backup_file: prints a backup path next to the file' \
  "$([[ ${bf_one} == "${BF_TMP}/x.env.bak-"* && -f ${bf_one} ]] && echo yes || echo no)" 'yes'
expect_eq 'backup_file: two backups in the same second get distinct names' "$([[ ${bf_one} != "${bf_two}" ]] && echo yes || echo no)" 'yes'
expect_eq 'backup_file: keeps the mode (a 0600 secret stays 0600)' "$(_file_mode_owner_group "${bf_one}" | cut -d' ' -f1)" '600'
expect_eq 'backup_file: a missing file is a silent no-op' "$(backup_file "${BF_TMP}/nope" 2>/dev/null; echo "rc=$?")" 'rc=0'
rm -rf "${BF_TMP}"
# --- env prefix rename ---
# The Ficus hard rename of a host's env files (lib.sh's `env prefix rename`
# section): the rename rules, Ruling 24's conflict stop, symlinks (Minor 4),
# the journaled backup set (N-C1), the direction key (N-C2), the unit filter
# and the converted-host restore (N-I3). Legacy TAU_ fixture lines carry the
# `legacy-env` marker so the codemod leaves them alone on a re-run.
EPR=$(mktemp -d)
# The invoking user's own group, so files created here (BSD takes the
# directory's group) are ones an unprivileged run can keep as they are.
chgrp "$(id -g)" "${EPR}" 2>/dev/null || true
EPR_SAVED_AS_ROOT=$(declare -f as_root)
EPR_SAVED_SYSTEMD_UNIT_DIR=${FICUS_SYSTEMD_UNIT_DIR}
EPR_SAVED_MANAGED_ENV_PATH=${FICUS_MANAGED_ENV_PATH}
EPR_SAVED_BACKUP_ENV_TARGET=${BACKUP_ENV_TARGET}
EPR_SAVED_BACKUP_SCRIPT_PATH=${BACKUP_SCRIPT_PATH}
EPR_CALLS="${EPR}/calls"
: >"${EPR_CALLS}"
# Run everything as the invoking user: install(1) without -o/-g (ownership is
# not what these cases pin), systemctl recorded and never run.
as_root() {
  printf 'as_root %s\n' "$*" >>"${EPR_CALLS}"
  if [[ ${1:-} == systemctl ]]; then return 0; fi
  if [[ ${1:-} == install ]]; then
    shift
    local args=()
    while (($#)); do
      case "$1" in
        -o | -g) shift 2 ;;
        *)
          args+=("$1")
          shift
          ;;
      esac
    done
    install "${args[@]}"
    return
  fi
  "$@"
}
epr_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# A core unit file under the scratch unit dir: epr_unit api|worker.
epr_unit() { printf '%s/tau-%s.service' "${FICUS_SYSTEMD_UNIT_DIR}" "$1"; } # phase5-unit-name

printf '# x\nTAU_A=1\nB=2\nexport TAU_C="x y"\nFICUS_D=4\nTAU_D=old\nTAU_MANAGED_SECRET_KEYS=TAU_P,Q\n' >"${EPR}/.env" # legacy-env
chmod 0640 "${EPR}/.env"
expect_eq 'envfile_rename_prefix: counts renamed lines' "$(envfile_rename_prefix "${EPR}/.env" TAU FICUS 2>/dev/null)" '3'
expect_eq 'envfile_rename_prefix: hard rename, FICUS wins an unprotected conflict, list mapped' "$(<"${EPR}/.env")" \
  $'# x\nFICUS_A=1\nB=2\nexport FICUS_C="x y"\nFICUS_D=4\nFICUS_MANAGED_SECRET_KEYS=FICUS_P,Q'
expect_eq 'envfile_rename_prefix: mode preserved' "$(epr_mode "${EPR}/.env")" '640'
expect_eq 'envfile_rename_prefix: idempotent' "$(envfile_rename_prefix "${EPR}/.env" TAU FICUS 2>/dev/null)" '0'
expect_eq 'envfile_rename_prefix: an absent file is a no-op printing 0' \
  "$(envfile_rename_prefix "${EPR}/no-such.env" TAU FICUS 2>/dev/null)" '0'
expect_eq 'envfile_rename_prefix: no staging file is left behind' \
  "$(find "${EPR}" -maxdepth 1 -name '*.ficus-rename.*' | wc -l | tr -d ' ')" '0'

# Ruling 24 / N-I2: conflicting protected values stop before any write; identical values de-duplicate.
printf 'TAU_ENCRYPTION_KEY=aaa\nFICUS_ENCRYPTION_KEY=bbb\n' >"${EPR}/conf.env"
cp -p "${EPR}/conf.env" "${EPR}/conf.orig"
expect_eq 'envfile_rename_prefix: protected conflict dies' "$( (envfile_rename_prefix "${EPR}/conf.env" TAU FICUS) >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
expect_eq 'envfile_rename_prefix: protected conflict writes nothing' "$(cmp -s "${EPR}/conf.env" "${EPR}/conf.orig" && echo same)" 'same'
expect_eq 'envfile_rename_prefix: the error names the key, never the value' \
  "$( (envfile_rename_prefix "${EPR}/conf.env" TAU FICUS) 2>&1 >/dev/null | grep -c -e aaa -e bbb)" '0'
expect_match 'envfile_rename_prefix: the error names both spellings of the key' \
  "$( (envfile_rename_prefix "${EPR}/conf.env" TAU FICUS) 2>&1 >/dev/null)" 'TAU_ENCRYPTION_KEY and FICUS_ENCRYPTION_KEY disagree on this host'
expect_eq 'envfile_prefix_conflicts: lists the protected key' "$(envfile_prefix_conflicts "${EPR}/conf.env" TAU FICUS)" 'ENCRYPTION_KEY'
expect_eq 'envfile_prefix_conflicts: never writes' "$(cmp -s "${EPR}/conf.env" "${EPR}/conf.orig" && echo same)" 'same'
expect_eq 'envfile_get_prefixed: protected conflict dies' "$( (envfile_get_prefixed "${EPR}/conf.env" ENCRYPTION_KEY) >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
expect_eq 'envfile_get_prefixed: its error never carries a value' \
  "$( (envfile_get_prefixed "${EPR}/conf.env" ENCRYPTION_KEY) 2>&1 | grep -c -e aaa -e bbb)" '0'
printf 'TAU_PASSWORD=p\nFICUS_PASSWORD=p\n' >"${EPR}/same.env" # legacy-env
envfile_rename_prefix "${EPR}/same.env" TAU FICUS >/dev/null 2>&1
expect_eq 'envfile_rename_prefix: identical protected values de-duplicate silently' "$(<"${EPR}/same.env")" 'FICUS_PASSWORD=p'
printf 'TAU_PASSWORD="p"\nFICUS_PASSWORD=p\n' >"${EPR}/same-quoted.env" # legacy-env
expect_eq 'envfile_prefix_conflicts: a quoted and a bare copy of one value do not conflict' \
  "$(envfile_prefix_conflicts "${EPR}/same-quoted.env" TAU FICUS)" ''
printf 'TAU_OTHER_TOKEN=a\nFICUS_OTHER_TOKEN=b\n' >"${EPR}/unprot.env" # legacy-env
expect_eq 'envfile_rename_prefix: an unprotected conflict keeps FICUS_ and names the dropped key' \
  "$(envfile_rename_prefix "${EPR}/unprot.env" TAU FICUS 2>&1 >/dev/null | grep -c 'TAU_OTHER_TOKEN')" '1'
expect_eq 'envfile_rename_prefix: ...and the file keeps only the FICUS_ value' "$(<"${EPR}/unprot.env")" 'FICUS_OTHER_TOKEN=b'

# Minor 4: a symlinked env file keeps its link; the target is rewritten.
printf 'TAU_A=1\n' >"${EPR}/real.env" # legacy-env
ln -s "${EPR}/real.env" "${EPR}/link.env"
envfile_rename_prefix "${EPR}/link.env" TAU FICUS >/dev/null
expect_eq 'envfile_rename_prefix: symlink kept' "$([[ -L ${EPR}/link.env ]] && echo link)" 'link'
expect_eq 'envfile_rename_prefix: target renamed' "$(<"${EPR}/real.env")" 'FICUS_A=1'

if yq_is_mikefarah; then
  printf 'core:\n  env:\n    TAU_PLATFORM_INGEST_URL: https://ficus.sh\n' >"${EPR}/c.yaml" # legacy-env
  yaml_rename_env_prefix "${EPR}/c.yaml" TAU FICUS 2>/dev/null
  expect_eq 'yaml_rename_env_prefix: key renamed' "$(yq '.core.env.FICUS_PLATFORM_INGEST_URL' "${EPR}/c.yaml")" 'https://ficus.sh'
  expect_eq 'yaml_rename_env_prefix: old key gone' "$(yq '.core.env.TAU_PLATFORM_INGEST_URL' "${EPR}/c.yaml")" 'null' # legacy-env
  printf '# top\ncore:\n  port: 3000\n  env:\n    # knob\n    TAU_MAX_MACHINES: "10" # tier\n    FICUS_X: keep\n' >"${EPR}/order.yaml" # legacy-env
  chmod 0600 "${EPR}/order.yaml"
  ln -s "${EPR}/order.yaml" "${EPR}/order-link.yaml"
  yaml_rename_env_prefix "${EPR}/order-link.yaml" TAU FICUS 2>/dev/null
  expect_eq 'yaml_rename_env_prefix: comments, order and quoting survive; the link stays a link' \
    "$(<"${EPR}/order.yaml")$([[ -L ${EPR}/order-link.yaml ]] && echo ' [link]')" \
    $'# top\ncore:\n  port: 3000\n  env:\n    # knob\n    FICUS_MAX_MACHINES: "10" # tier\n    FICUS_X: keep [link]'
  expect_eq 'yaml_rename_env_prefix: the file keeps its mode' "$(epr_mode "${EPR}/order.yaml")" '600'
  printf 'core:\n  env:\n    TAU_PASSWORD_ENV: A\n    FICUS_PASSWORD_ENV: B\n' >"${EPR}/yconf.yaml" # legacy-env
  cp -p "${EPR}/yconf.yaml" "${EPR}/yconf.orig"
  expect_eq 'yaml_rename_env_prefix: a protected conflict dies' \
    "$( (yaml_rename_env_prefix "${EPR}/yconf.yaml" TAU FICUS) >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
  expect_eq 'yaml_rename_env_prefix: ...before writing anything' "$(cmp -s "${EPR}/yconf.yaml" "${EPR}/yconf.orig" && echo same)" 'same'
  expect_eq 'yaml_prefix_conflicts: names the suffix' "$(yaml_prefix_conflicts "${EPR}/yconf.yaml" TAU FICUS)" 'PASSWORD_ENV'
else
  log_warn 'mikefarah yq not on PATH — skipping the yaml_rename_env_prefix cases'
fi

printf '[Service]\nEnvironment=TAU_ROOT=/srv/core/current\nEnvironment=PATH=/usr/bin\nEnvironment="TAU_X=1"\n' >"${EPR}/u.service" # legacy-env
expect_eq 'unitfile_rename_env_prefix: counts renamed lines' "$(unitfile_rename_env_prefix "${EPR}/u.service" TAU FICUS 2>/dev/null)" '2'
expect_eq 'unitfile_rename_env_prefix: only Environment= names change, values keep their paths' "$(<"${EPR}/u.service")" \
  $'[Service]\nEnvironment=FICUS_ROOT=/srv/core/current\nEnvironment=PATH=/usr/bin\nEnvironment="FICUS_X=1"'

printf 'TAU_ENCRYPTION_KEY=abc\n' >"${EPR}/old.env" # legacy-env
expect_eq 'envfile_get_prefixed: falls back to TAU_ (permanent)' "$(envfile_get_prefixed "${EPR}/old.env" ENCRYPTION_KEY)" 'abc'
expect_eq 'host_env_prefix: TAU host' "$(host_env_prefix "${EPR}/old.env")" 'TAU'
expect_eq 'host_env_prefix: FICUS host' "$(host_env_prefix "${EPR}/.env")" 'FICUS'
expect_eq 'host_env_prefix: no file is NONE' "$(host_env_prefix "${EPR}/no-such.env")" 'NONE'
printf 'FICUS_ENCRYPTION_KEY=\nTAU_ENCRYPTION_KEY=abc\n' >"${EPR}/empty-ficus.env" # legacy-env
expect_eq 'envfile_get_prefixed: an empty FICUS_ value counts as unset' "$(envfile_get_prefixed "${EPR}/empty-ficus.env" ENCRYPTION_KEY)" 'abc'
expect_eq 'envfile_get_prefixed: FICUS_ wins over an identical TAU_' \
  "$(printf 'FICUS_PASSWORD=p\nTAU_PASSWORD=p\n' >"${EPR}/both.env"; envfile_get_prefixed "${EPR}/both.env" PASSWORD)" 'p' # legacy-env
expect_eq 'envfile_get_prefixed: neither name returns 1' \
  "$( (envfile_get_prefixed "${EPR}/.env" NO_SUCH_SUFFIX) >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
# Presence is decided on what a dotenv reader sees (trimmed, one quote level
# removed): an empty-looking FICUS_ value never hides a real TAU_ one.
for epr_empty in '""' "''" ' ' '  ""  '; do
  printf 'FICUS_ENCRYPTION_KEY=%s\nTAU_ENCRYPTION_KEY=realkey\n' "${epr_empty}" >"${EPR}/emptyish.env" # legacy-env
  expect_eq "envfile_get_prefixed: FICUS_ENCRYPTION_KEY=${epr_empty} reads the real TAU_ key" \
    "$(envfile_get_prefixed "${EPR}/emptyish.env" ENCRYPTION_KEY)" 'realkey'
done
printf 'FICUS_ENCRYPTION_KEY="quoted-key"\n' >"${EPR}/quoted.env"
expect_eq 'envfile_get_prefixed: returns the value a dotenv reader sees (quotes removed)' \
  "$(envfile_get_prefixed "${EPR}/quoted.env" ENCRYPTION_KEY)" 'quoted-key'
# `export` and indented lines, and CRLF, are assignments too: a pre-rename
# key written that way is never read as absent (no new key is generated).
printf 'export TAU_ENCRYPTION_KEY=exported-key\n' >"${EPR}/export.env" # legacy-env
expect_eq 'envfile_get_prefixed: sees an export TAU_ line' "$(envfile_get_prefixed "${EPR}/export.env" ENCRYPTION_KEY)" 'exported-key'
printf '  TAU_PASSWORD=indented\r\n' >"${EPR}/indent.env" # legacy-env
expect_eq 'envfile_get_prefixed: sees an indented CRLF line, without the CR' "$(envfile_get_prefixed "${EPR}/indent.env" PASSWORD)" 'indented'

# Backup set + journal (N-C1).
printf 'one\n' >"${EPR}/f1"
printf 'two\n' >"${EPR}/f2"
chmod 0600 "${EPR}/f2"
export ENV_RENAME_BACKUP_ROOT="${EPR}/bk"
EPR_SET=$(env_rename_backup_create FICUS "${EPR}/rel" "${EPR}/f1" "${EPR}/f2" 2>/dev/null)
expect_eq 'backup set: journal names set, target and release' "$(<"${EPR}/bk/PENDING")" "${EPR_SET}"$'\tFICUS\t'"${EPR}/rel"
expect_eq 'backup set: the set dir is 0700' "$(epr_mode "${EPR_SET}")" '700'
expect_eq 'backup set: the backup root is 0700' "$(epr_mode "${EPR}/bk")" '700'
expect_eq 'backup set: a second set is refused while one is journaled' \
  "$( (env_rename_backup_create FICUS "${EPR}/rel" "${EPR}/f1") >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
printf 'changed\n' >"${EPR}/f1"
printf 'changed\n' >"${EPR}/f2"
env_rename_backup_restore "${EPR_SET}" 2>/dev/null
expect_eq 'backup set: f1 restored byte-for-byte' "$(<"${EPR}/f1")" 'one'
expect_eq 'backup set: f2 restored with its mode' "$(epr_mode "${EPR}/f2")" '600'
expect_match 'backup set: manifest records path and sha256' "$(<"${EPR_SET}/MANIFEST")" "[0-9a-f]{64}.*${EPR}/f2"
expect_eq 'backup set: a verified restore clears the journal' "$([[ -e ${EPR}/bk/PENDING ]] && echo left || echo gone)" 'gone'
expect_match 'backup set: a restore daemon-reloads' "$(<"${EPR_CALLS}")" 'as_root systemctl daemon-reload'
# A tampered copy is refused before anything is touched.
EPR_SET2=$(env_rename_backup_create FICUS "${EPR}/rel" "${EPR}/f1" "${EPR}/f2" 2>/dev/null)
printf 'tampered\n' >"${EPR_SET2}/2"
printf 'live-1\n' >"${EPR}/f1"
epr_rc=0
env_rename_backup_restore "${EPR_SET2}" 2>/dev/null || epr_rc=$?
expect_eq 'backup set: a copy that no longer matches its sha256 fails the restore' "${epr_rc}" '1'
expect_eq 'backup set: ...and nothing is restored' "$(<"${EPR}/f1")" 'live-1'
expect_eq 'backup set: ...and the journal is kept' "$([[ -e ${EPR}/bk/PENDING ]] && echo kept || echo gone)" 'kept'
rm -f "${EPR}/bk/PENDING"
# Prune keeps the newest five and never the journaled one.
for epr_i in 1 2 3 4 5 6; do
  mkdir -p "${EPR}/bk/2020010${epr_i}T000000Z-abc12${epr_i}"
done
printf '%s\tFICUS\t\n' "${EPR}/bk/20200101T000000Z-abc121" >"${EPR}/bk/PENDING"
env_rename_backup_prune 2>/dev/null
expect_eq 'backup prune: the journaled set survives even when it is the oldest' \
  "$([[ -d ${EPR}/bk/20200101T000000Z-abc121 ]] && echo kept || echo pruned)" 'kept'
expect_eq 'backup prune: only the newest five others remain' \
  "$(find "${EPR}/bk" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" '6'
rm -f "${EPR}/bk/PENDING"
env_rename_backup_prune 2>/dev/null
expect_eq 'backup prune: without a journal, five sets are kept' \
  "$(find "${EPR}/bk" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" '5'
rm -rf "${EPR}/bk"

# Direction key (N-C2): artifact.json wins; package.json is the fallback.
mkdir -p "${EPR}/rel"
printf '{"name":"tau"}' >"${EPR}/rel/package.json"
printf '{"schema":1,"envPrefix":"FICUS"}' >"${EPR}/rel/artifact.json"
expect_eq 'core_release_env_prefix: artifact.json envPrefix wins' "$(core_release_env_prefix "${EPR}/rel")" 'FICUS'
mkdir -p "${EPR}/git"
printf '{"name":"tau"}' >"${EPR}/git/package.json"
expect_eq 'core_release_env_prefix: git checkout falls back to package.json' "$(core_release_env_prefix "${EPR}/git")" 'TAU'
mkdir -p "${EPR}/old-art"
printf '{"name":"tau","private":true,"workspaces":[]}\n' >"${EPR}/old-art/package.json"
printf '{"schema":1}' >"${EPR}/old-art/artifact.json"
expect_eq 'core_release_env_prefix: a pre-rename artifact (no envPrefix) reads TAU' "$(core_release_env_prefix "${EPR}/old-art")" 'TAU'
mkdir -p "${EPR}/ficus-git"
printf '{"name":"ficus"}' >"${EPR}/ficus-git/package.json"
expect_eq 'core_release_env_prefix: a ficus checkout reads FICUS' "$(core_release_env_prefix "${EPR}/ficus-git")" 'FICUS'
mkdir -p "${EPR}/odd"
printf '{"name":"other"}' >"${EPR}/odd/package.json"
expect_eq 'core_release_env_prefix: unknown name dies' "$( (core_release_env_prefix "${EPR}/odd") >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
mkdir -p "${EPR}/bad-prefix"
printf '{"schema":1,"envPrefix":"OTHER"}' >"${EPR}/bad-prefix/artifact.json"
expect_eq 'core_release_env_prefix: an unknown envPrefix dies' "$( (core_release_env_prefix "${EPR}/bad-prefix") >/dev/null 2>&1; echo "rc=$?")" 'rc=1'

# install_core_units renders what the running release reads.
expect_eq 'core_unit_prefix_filter TAU: pre-rename units carry TAU_ROOT' \
  "$(printf 'Environment=FICUS_ROOT=/srv/core/current\nEnvironment=PATH=/usr/bin\n' | core_unit_prefix_filter TAU)" \
  $'Environment=TAU_ROOT=/srv/core/current\nEnvironment=PATH=/usr/bin' # legacy-env
expect_eq 'core_unit_prefix_filter FICUS: unchanged' \
  "$(printf 'Environment=FICUS_ROOT=/x\n' | core_unit_prefix_filter FICUS)" 'Environment=FICUS_ROOT=/x'
expect_eq 'core_unit_prefix_filter: an unknown prefix fails' \
  "$( (printf 'x\n' | core_unit_prefix_filter OTHER) >/dev/null 2>&1; echo "rc=$?")" 'rc=1'

# --- reconcile, migrate and the converted-host restore on a fake host --------
# A fake host: <dest> with current -> a release, the env files under a scratch
# /etc, the units in a scratch unit dir, and the backup root in the tmp dir.
epr_host() { # NAME RELEASE_PACKAGE_JSON [ARTIFACT_JSON]
  EPR_H="${EPR}/host-$1"
  rm -rf "${EPR_H}"
  mkdir -p "${EPR_H}/dest/releases/rel" "${EPR_H}/etc" "${EPR_H}/units" "${EPR_H}/bin"
  printf '%s' "$2" >"${EPR_H}/dest/releases/rel/package.json"
  [[ -z ${3:-} ]] || printf '%s' "$3" >"${EPR_H}/dest/releases/rel/artifact.json"
  ln -sfn "${EPR_H}/dest/releases/rel" "${EPR_H}/dest/current"
  SRC_DEST="${EPR_H}/dest"
  FICUS_MANAGED_ENV_PATH="${EPR_H}/etc/managed.env"
  BACKUP_ENV_TARGET="${EPR_H}/etc/backup.env"
  BACKUP_SCRIPT_PATH="${EPR_H}/bin/tau-backup.sh"
  FICUS_SYSTEMD_UNIT_DIR="${EPR_H}/units"
  CFG_FILE=''
  RUN_USER=$(id -un) BUN_BIN=/usr/local/bin/bun DB_MODE=external CORE_LAYOUT=''
  export ENV_RENAME_BACKUP_ROOT="${EPR_H}/bk"
  printf 'TAU_ENCRYPTION_KEY=k\nTAU_SANDBOX_RUNTIME=host\nOTHER=1\n' >"${SRC_DEST}/.env" # legacy-env
  printf 'TAU_MANAGED=1\nTAU_PLATFORM_INSTANCE_TOKEN=t\n' >"${FICUS_MANAGED_ENV_PATH}" # legacy-env
  mkdir -p "$(epr_unit api).d"
  printf '[Service]\nEnvironment=TAU_ROOT=%s/current\n' "${SRC_DEST}" >"$(epr_unit api)" # legacy-env
  printf '[Service]\nEnvironment=TAU_ROOT=%s/current\n' "${SRC_DEST}" >"$(epr_unit worker)" # legacy-env
  printf '[Service]\nEnvironment=TAU_EXTRA=1\n' >"$(epr_unit api).d/extra.conf" # legacy-env
  chmod 0600 "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}"
}
# Compare every MANIFEST path with its backed-up copy.
epr_matches_manifest() { # SETDIR
  local idx _sha path ok=yes
  while IFS=$'\t' read -r idx _sha path; do
    cmp -s "$1/${idx}" "${path}" || ok="no (${path})"
  done <"$1/MANIFEST"
  printf '%s' "${ok}"
}

# Reconcile, active release TAU (package.json tau, no envPrefix): restore.
epr_host tau-active '{"name":"tau"}' '{"schema":1}'
EPR_SET=$(env_rename_backup_create FICUS "${SRC_DEST}/releases/new" "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}" 2>/dev/null)
envfile_rename_prefix "${SRC_DEST}/.env" TAU FICUS >/dev/null 2>&1
envfile_rename_prefix "${FICUS_MANAGED_ENV_PATH}" TAU FICUS >/dev/null 2>&1
env_prefix_reconcile 2>/dev/null
expect_eq 'env_prefix_reconcile (active TAU): the files are byte-identical to the MANIFEST' "$(epr_matches_manifest "${EPR_SET}")" 'yes'
expect_eq 'env_prefix_reconcile (active TAU): PENDING is removed' "$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo left || echo gone)" 'gone'
expect_eq 'env_prefix_reconcile: without a journal it is a no-op' "$(env_prefix_reconcile 2>/dev/null; echo "rc=$?")" 'rc=0'

# Reconcile, active release FICUS, half-renamed host: finish and commit.
epr_host ficus-active '{"name":"tau"}' '{"schema":1,"envPrefix":"FICUS"}'
env_rename_backup_create FICUS "${SRC_DEST}/releases/rel" "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}" >/dev/null 2>&1
envfile_rename_prefix "${SRC_DEST}/.env" TAU FICUS >/dev/null 2>&1
env_prefix_reconcile 2>/dev/null
expect_eq 'env_prefix_reconcile (active FICUS): finishes managed.env' "$(<"${FICUS_MANAGED_ENV_PATH}")" $'FICUS_MANAGED=1\nFICUS_PLATFORM_INSTANCE_TOKEN=t'
expect_eq 'env_prefix_reconcile (active FICUS): finishes the units too' \
  "$(grep -c '^Environment=FICUS_' "$(epr_unit api)" "$(epr_unit api).d/extra.conf" | cut -d: -f2 | tr '\n' ' ')" '1 1 '
expect_eq 'env_prefix_reconcile (active FICUS): PENDING is removed' "$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo left || echo gone)" 'gone'
expect_eq 'env_prefix_reconcile (active FICUS): one set is left' \
  "$(find "${ENV_RENAME_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" '1'

# migrate on a host whose .env is FICUS_ but managed.env is still TAU_: the v2
# ".env already FICUS" shortcut would have skipped managed.env.
epr_host half '{"name":"tau"}'
envfile_rename_prefix "${SRC_DEST}/.env" TAU FICUS >/dev/null 2>&1
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
expect_eq 'migrate_env_prefix_host: a FICUS_ .env does not skip a TAU_ managed.env' \
  "$(<"${FICUS_MANAGED_ENV_PATH}")" $'FICUS_MANAGED=1\nFICUS_PLATFORM_INSTANCE_TOKEN=t'
expect_eq 'migrate_env_prefix_host: renames the units and drop-ins' \
  "$(cat "$(epr_unit api)" "$(epr_unit api).d/extra.conf" | grep -c '^Environment=FICUS_')" '2'
expect_eq 'migrate_env_prefix_host: creates exactly one set' \
  "$(find "${ENV_RENAME_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" '1'
expect_eq 'migrate_env_prefix_host: leaves the rename pending for the caller to commit' \
  "${ENV_RENAME_PENDING}:$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo journaled)" '1:journaled'
EPR_HALF_SET=${ENV_RENAME_BACKUP_SET}
# The EXIT/TERM trap body restores it (once), leaving no journal: the active
# release reads TAU_ (Ruling 29 — the files must match the active release).
env_prefix_on_exit 143 2>/dev/null
expect_eq 'env_prefix_on_exit: a failed exit restores the set byte for byte' "$(epr_matches_manifest "${EPR_HALF_SET}")" 'yes'
expect_eq 'env_prefix_on_exit: ...clears the journal' "$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo left || echo gone)" 'gone'
printf 'after\n' >>"${FICUS_MANAGED_ENV_PATH}"
env_prefix_on_exit 1 2>/dev/null
expect_eq 'env_prefix_on_exit: idempotent — a second call (the EXIT after a TERM) restores nothing' \
  "$(tail -n 1 "${FICUS_MANAGED_ENV_PATH}")" 'after'
# A clean exit (rc 0) never restores.
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
env_prefix_on_exit 0
expect_eq 'env_prefix_on_exit: rc 0 does not restore' "$(grep -c '^FICUS_' "${FICUS_MANAGED_ENV_PATH}")" '2'
env_prefix_commit 2>/dev/null
expect_eq 'env_prefix_commit: clears the flag and the journal' \
  "${ENV_RENAME_PENDING}:$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo left || echo gone)" '0:gone'

# Ruling 29: a failure or signal AFTER the flip (the active release reads
# FICUS_) must not restore TAU_ files under it — the rename is finished
# forward and committed instead.
epr_host forward '{"name":"ficus"}'
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
# A step the rename had not reached yet (a half-renamed host).
printf 'TAU_MANAGED=1\nTAU_PLATFORM_INSTANCE_TOKEN=t\n' >"${FICUS_MANAGED_ENV_PATH}" # legacy-env
env_prefix_on_exit 143 2>/dev/null
expect_eq 'env_prefix_on_exit (active FICUS): keeps and finishes the rename instead of restoring' \
  "$(host_env_prefix "${SRC_DEST}/.env"):$(<"${FICUS_MANAGED_ENV_PATH}")" $'FICUS:FICUS_MANAGED=1\nFICUS_PLATFORM_INSTANCE_TOKEN=t'
expect_eq 'env_prefix_on_exit (active FICUS): commits — no journal, flag cleared' \
  "${ENV_RENAME_PENDING}:$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo left || echo gone)" '0:gone'
# The rollback hook runs after the swap back: active TAU again -> restore.
epr_host rollback-hook '{"name":"tau"}'
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
EPR_RB_SET=${ENV_RENAME_BACKUP_SET}
env_prefix_restore_pending 2>/dev/null
expect_eq 'env_prefix_restore_pending (the rollback hook, active TAU): restores byte for byte' "$(epr_matches_manifest "${EPR_RB_SET}")" 'yes'
# When the active release cannot be told, nothing is restored or committed:
# the journal is kept for the next run's reconcile.
epr_host unknown '{"name":"other"}'
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
env_prefix_on_exit 1 2>/dev/null
expect_eq 'env_prefix_on_exit (active release unknown): files stay renamed, journal kept' \
  "$(host_env_prefix "${SRC_DEST}/.env"):$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo kept || echo gone)" 'FICUS:kept'
# The state Ruling 29 forbids — TAU_ files, a FICUS_ release, no journal —
# is never produced by any of the settle paths above.
epr_forbidden_state() { # prints "forbidden" for ENV=TAU / RELEASE=FICUS / no journal
  if [[ $(host_env_prefix "${SRC_DEST}/.env") == TAU && ! -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] &&
    [[ $(core_release_env_prefix "$(active_release_tree)" 2>/dev/null) == FICUS ]]; then
    echo forbidden
  else
    echo ok
  fi
}
for epr_rel in '{"name":"tau"}' '{"name":"ficus"}'; do
  for epr_rc in 1 129 130 143; do
    epr_host "matrix-${epr_rc}" "${epr_rel}"
    ENV_RENAME_PENDING=0
    migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
    env_prefix_on_exit "${epr_rc}" 2>/dev/null
    expect_eq "settle matrix (release ${epr_rel}, rc ${epr_rc}): never TAU_ files under a FICUS_ release without a journal" \
      "$(epr_forbidden_state)" 'ok'
  done
done

# M3: a reconcile removes the staging files an interrupted rename left.
epr_host staging '{"name":"tau"}'
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
: >"$(dirname "${FICUS_MANAGED_ENV_PATH}")/.managed.env.ficus-rename.AbC123"
: >"${SRC_DEST}/..env.ficus-restore.XyZ789"
: >"${SRC_DEST}/.dotenv-unrelated"
ENV_RENAME_PENDING=0
env_prefix_reconcile 2>/dev/null
expect_eq 'env_prefix_reconcile: removes leftover .<name>.ficus-rename.* / .ficus-restore.* staging files' \
  "$(find "$(dirname "${FICUS_MANAGED_ENV_PATH}")" "${SRC_DEST}" -maxdepth 1 -name '*.ficus-re*' | wc -l | tr -d ' ')" '0'
expect_eq 'env_prefix_reconcile: ...and nothing else' "$([[ -e ${SRC_DEST}/.dotenv-unrelated ]] && echo kept)" 'kept'

# M2: a TAU_ line inside a multi-line value (a PEM block) is value text — an
# otherwise clean host makes no backup set, run after run.
epr_host pem '{"name":"ficus"}'
printf 'FICUS_ENCRYPTION_KEY=k\nFICUS_CERT="-----BEGIN\nTAU_NOT_A_KEY=x\n-----END"\n' >"${SRC_DEST}/.env" # legacy-env
printf 'FICUS_MANAGED=1\n' >"${FICUS_MANAGED_ENV_PATH}"
for epr_f in "$(epr_unit api)" "$(epr_unit worker)" "$(epr_unit api).d/extra.conf"; do
  unitfile_rename_env_prefix "${epr_f}" TAU FICUS >/dev/null 2>&1
done
for epr_i in 1 2; do
  ENV_RENAME_PENDING=0
  migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
done
expect_eq 'migrate_env_prefix_host: a TAU_ line inside a PEM value makes no set' \
  "$([[ -d ${ENV_RENAME_BACKUP_ROOT} ]] && find "${ENV_RENAME_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ' || echo 0):${ENV_RENAME_PENDING}" '0:0'

# An all-FICUS_ host: no set, no journal.
epr_host clean '{"name":"ficus"}'
for epr_f in "${SRC_DEST}/.env" "${FICUS_MANAGED_ENV_PATH}"; do envfile_rename_prefix "${epr_f}" TAU FICUS >/dev/null 2>&1; done
for epr_f in "$(epr_unit api)" "$(epr_unit worker)" "$(epr_unit api).d/extra.conf"; do
  unitfile_rename_env_prefix "${epr_f}" TAU FICUS >/dev/null 2>&1
done
ENV_RENAME_PENDING=0
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
expect_eq 'migrate_env_prefix_host: an all-FICUS host creates no set and no PENDING' \
  "$([[ -d ${ENV_RENAME_BACKUP_ROOT} ]] && find "${ENV_RENAME_BACKUP_ROOT}" -mindepth 1 | wc -l | tr -d ' ' || echo 0):${ENV_RENAME_PENDING}" '0:0'

# A TAU target on a FICUS host is refused, and nothing changes.
cp -p "${SRC_DEST}/.env" "${EPR}/clean.env.orig"
expect_match 'migrate_env_prefix_host: a pre-rename target on a FICUS host is refused' \
  "$( (migrate_env_prefix_host TAU "${SRC_DEST}/releases/rel") 2>&1)" 'target Core predates the Ficus rename'
expect_eq 'migrate_env_prefix_host: ...with nothing changed' "$(cmp -s "${SRC_DEST}/.env" "${EPR}/clean.env.orig" && echo same)" 'same'

# Ruling 24 across files: a conflict in managed.env stops the run before ANY write.
epr_host conflict '{"name":"ficus"}'
printf 'FICUS_PLATFORM_PASSWORD=a\nTAU_PLATFORM_PASSWORD=b\n' >>"${FICUS_MANAGED_ENV_PATH}" # legacy-env
cp -p "${SRC_DEST}/.env" "${EPR}/conflict.env.orig"
ENV_RENAME_PENDING=0
expect_match 'migrate_env_prefix_host: a protected conflict names the key' \
  "$( (migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel") 2>&1)" 'TAU_PLATFORM_PASSWORD and FICUS_PLATFORM_PASSWORD disagree'
expect_eq 'migrate_env_prefix_host: ...never the value' \
  "$( (migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel") 2>&1 | grep -c -e '=a' -e '=b')" '0'
expect_eq 'migrate_env_prefix_host: ...before renaming even the clean .env' "$(cmp -s "${SRC_DEST}/.env" "${EPR}/conflict.env.orig" && echo same)" 'same'
expect_eq 'migrate_env_prefix_host: ...and creates no set' "$([[ -d ${ENV_RENAME_BACKUP_ROOT} ]] && echo made || echo none)" 'none'

# N-I3: with ARTIFACT_CONVERTED_THIS_RUN=1 the units stay out of the set, and
# a restore renders them for the CURRENT layout with TAU_ROOT.
epr_host converted '{"name":"tau"}'
ENV_RENAME_PENDING=0
ARTIFACT_CONVERTED_THIS_RUN=1
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
expect_eq 'converted run: the set carries UNITS_EXCLUDED' "$([[ -e ${ENV_RENAME_BACKUP_SET}/UNITS_EXCLUDED ]] && echo yes)" 'yes'
expect_eq 'converted run: no unit file is in the MANIFEST' "$(grep -c '\.service\|\.conf' "${ENV_RENAME_BACKUP_SET}/MANIFEST" || true)" '0'
expect_eq 'converted run: the units are not renamed by the rename step' "$(grep -c '^Environment=TAU_ROOT=' "$(epr_unit api)")" '1' # legacy-env
install_core_units "${SCRIPT_DIR}/systemd" FICUS 2>/dev/null
env_prefix_restore_pending 2>/dev/null
expect_eq 'converted run: the restore renders units with Environment=TAU_ROOT= for the current layout' \
  "$(grep -hc "^Environment=TAU_ROOT=${SRC_DEST}/current$" "$(epr_unit api)" "$(epr_unit worker)" | tr '\n' ' ')" '1 1 ' # legacy-env
expect_eq 'converted run: ...and no Environment=FICUS_ROOT is left' "$(grep -c '^Environment=FICUS_ROOT' "$(epr_unit api)" || true)" '0'
expect_eq 'converted run: the env files are back byte for byte' "$(epr_matches_manifest "$(find "${ENV_RENAME_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d)")" 'yes'
# Without the templates (apply-artifacts.sh ships none): return 3, change nothing, keep the journal.
ENV_RENAME_PENDING=0
epr_host converted2 '{"name":"tau"}'
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
ARTIFACT_CONVERTED_THIS_RUN=0
EPR_SAVED_SCRIPT_DIR=${SCRIPT_DIR}
SCRIPT_DIR="${EPR}/no-templates"
cp -p "${SRC_DEST}/.env" "${EPR}/converted2.env.renamed"
epr_rc=0
env_rename_backup_restore "${ENV_RENAME_BACKUP_SET}" 2>/dev/null || epr_rc=$?
SCRIPT_DIR=${EPR_SAVED_SCRIPT_DIR}
expect_eq 'converted restore without unit templates: returns 3' "${epr_rc}" '3'
expect_eq 'converted restore without unit templates: changes nothing' "$(cmp -s "${SRC_DEST}/.env" "${EPR}/converted2.env.renamed" && echo same)" 'same'
expect_eq 'converted restore without unit templates: keeps the journal' "$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo kept)" 'kept'
ENV_RENAME_PENDING=0

# tau-backup.sh is re-rendered from the template during the rename.
epr_host backup '{"name":"tau"}'
render_backup_script_content "${SCRIPT_DIR}/tau-backup.sh.tmpl" "${SRC_DEST}" /home/x/.tau external '' \
  https://s3.example.com us-east-1 bucket pfx "${BACKUP_ENV_TARGET}" | sed 's/FICUS_/TAU_/g' >"${BACKUP_SCRIPT_PATH}" # legacy-env
chmod 0750 "${BACKUP_SCRIPT_PATH}"
render_backup_env_content real ak sk pp | sed 's/FICUS_/TAU_/g' >"${BACKUP_ENV_TARGET}" # legacy-env
migrate_env_prefix_host FICUS "${SRC_DEST}/releases/rel" 2>/dev/null
expect_eq 'migrate_env_prefix_host: tau-backup.sh is re-rendered from the template' \
  "$(cmp -s "${BACKUP_SCRIPT_PATH}" <(render_backup_script_content "${SCRIPT_DIR}/tau-backup.sh.tmpl" "${SRC_DEST}" /home/x/.tau external '' \
    https://s3.example.com us-east-1 bucket pfx "${BACKUP_ENV_TARGET}") && echo same)" 'same'
expect_eq 'migrate_env_prefix_host: ...keeping its mode' "$(epr_mode "${BACKUP_SCRIPT_PATH}")" '750'
expect_eq 'migrate_env_prefix_host: backup.env is renamed, values kept' \
  "$(grep -c "^FICUS_BACKUP_[A-Z_0-9]*='" "${BACKUP_ENV_TARGET}")" '3'
env_prefix_restore_pending 2>/dev/null
expect_eq 'migrate_env_prefix_host: a restore puts the old tau-backup.sh back' "$(grep -c 'TAU_BACKUP_' "${BACKUP_SCRIPT_PATH}" | tr -d ' ')" \
  "$(grep -c 'FICUS_BACKUP_' "${SCRIPT_DIR}/tau-backup.sh.tmpl" | tr -d ' ')" # legacy-env

# require_host_env_prefix: dies on an unmigrated host, before anything else.
epr_host require '{"name":"ficus"}'
expect_match 'require_host_env_prefix: a TAU host is refused' \
  "$( (require_host_env_prefix FICUS "${SRC_DEST}/.env") 2>&1)" 'this host still uses TAU_\* settings'
envfile_rename_prefix "${SRC_DEST}/.env" TAU FICUS >/dev/null 2>&1
expect_eq 'require_host_env_prefix: a FICUS host passes' "$(require_host_env_prefix FICUS "${SRC_DEST}/.env" 2>&1; echo "rc=$?")" 'rc=0'
mkdir -p "${ENV_RENAME_BACKUP_ROOT}"
: >"${ENV_RENAME_BACKUP_ROOT}/PENDING"
expect_match 'require_host_env_prefix: a journaled (interrupted) rename is refused' \
  "$( (require_host_env_prefix FICUS "${SRC_DEST}/.env") 2>&1)" 'env rename journaled'
rm -f "${ENV_RENAME_BACKUP_ROOT}/PENDING"
printf '{"name":"tau"}' >"${SRC_DEST}/releases/rel/package.json"
expect_match 'require_host_env_prefix: a FICUS .env under a pre-rename active release is refused' \
  "$( (require_host_env_prefix FICUS "${SRC_DEST}/.env") 2>&1)" 'active release .* reads TAU_\* settings'

# --- M11: one toolkit run at a time (flock on the backup root) --------------
if have flock; then
  export ENV_RENAME_BACKUP_ROOT="${EPR}/lock-bk"
  mkdir -p "${ENV_RENAME_BACKUP_ROOT}"
  mkfifo "${EPR}/lock-fifo"
  ( flock 8; : >"${EPR}/lock-held"; read -r _ <"${EPR}/lock-fifo" ) 8>>"${ENV_RENAME_BACKUP_ROOT}/.lock" &
  EPR_LOCK_PID=$!
  for epr_i in $(seq 1 100); do [[ -e ${EPR}/lock-held ]] && break; sleep 0.1; done
  expect_match 'env_prefix_lock: a second run waits, then refuses while another holds the lock' \
    "$( (ENV_RENAME_LOCK_WAIT=1 env_prefix_lock) 2>&1; echo "rc=$?")" 'holds .*\.lock.*rc=1'
  printf 'go\n' >"${EPR}/lock-fifo"
  wait "${EPR_LOCK_PID}" 2>/dev/null || true
  expect_eq 'env_prefix_lock: free again once the other run exits' "$( (ENV_RENAME_LOCK_WAIT=1 env_prefix_lock) 2>/dev/null; echo "rc=$?")" 'rc=0'
  expect_eq 'env_prefix_lock: the backup root stays 0700' "$(epr_mode "${ENV_RENAME_BACKUP_ROOT}")" '700'
else
  log_warn 'flock not on PATH — skipping the env_prefix_lock cases (Linux hosts have it)'
fi

# --- M12: git mode reads the TARGET's package.json before the checkout moves --
if have git; then
  EPR_GIT="${EPR}/git-src"
  git init -q "${EPR_GIT}/origin"
  (
    cd "${EPR_GIT}/origin"
    printf '{"name":"ficus"}\n' >package.json
    git add package.json
    git -c user.email=t@example.com -c user.name=t commit -q -m ficus
    git branch -q -M main
    printf '{"name":"tau"}\n' >package.json
    git -c user.email=t@example.com -c user.name=t commit -q -am tau
    git -c user.email=t@example.com -c user.name=t tag -a -m old-release tau-release
    git reset -q --hard HEAD~1
  )
  git clone -q "${EPR_GIT}/origin" "${EPR_GIT}/dest"
  expect_eq 'git_rev_env_prefix: reads a revision it is not checked out at' \
    "$(git_rev_env_prefix "${EPR_GIT}/dest" tau-release):$(git_rev_env_prefix "${EPR_GIT}/dest" HEAD)" 'TAU:FICUS'
  expect_eq 'git_rev_env_prefix: an unknown revision dies' \
    "$( (git_rev_env_prefix "${EPR_GIT}/dest" no-such-rev) >/dev/null 2>&1; echo "rc=$?")" 'rc=1'
  # git_source_sync hands the hook the revision BEFORE it checks it out, and a
  # hook that dies leaves the checkout where it was.
  epr_git_hook() { printf 'hook %s head=%s\n' "$1" "$(git -C "${SRC_DEST}" rev-parse --short HEAD)" >>"${EPR}/git-hook.log"; }
  epr_git_hook_refuses() { die "refused $1"; }
  EPR_GIT_HEAD=$(git -C "${EPR_GIT}/dest" rev-parse --short HEAD)
  EPR_GIT_OUT=$(
    SRC_MODE=git-ssh SRC_REPO="${EPR_GIT}/origin" SRC_REF=tau-release SRC_DEST="${EPR_GIT}/dest" SRC_DEPLOY_KEY=/dev/null
    GIT_PRE_CHECKOUT_HOOK=epr_git_hook
    git_source_sync >/dev/null 2>&1
    git -C "${SRC_DEST}" rev-parse --short HEAD
  )
  expect_match 'git_source_sync: the pre-checkout hook sees the target before the checkout moves' \
    "$(cat "${EPR}/git-hook.log" 2>/dev/null)" "^hook tau-release head=${EPR_GIT_HEAD}$"
  git -C "${EPR_GIT}/dest" checkout -q -f "${EPR_GIT_HEAD}"
  EPR_GIT_RC=0
  (
    SRC_MODE=git-ssh SRC_REPO="${EPR_GIT}/origin" SRC_REF=tau-release SRC_DEST="${EPR_GIT}/dest" SRC_DEPLOY_KEY=/dev/null
    GIT_PRE_CHECKOUT_HOOK=epr_git_hook_refuses
    git_source_sync
  ) >/dev/null 2>&1 || EPR_GIT_RC=$?
  expect_eq 'git_source_sync: a refusing hook stops the sync with the checkout unmoved' \
    "${EPR_GIT_RC}:$(git -C "${EPR_GIT}/dest" rev-parse --short HEAD)" "1:${EPR_GIT_HEAD}"
  unset -f epr_git_hook epr_git_hook_refuses
  : "${EPR_GIT_OUT}"
else
  log_warn 'git not on PATH — skipping the git pre-checkout cases'
fi

# --- errexit-proof failure injection -----------------------------------------
# Each case runs the writer in both contexts (plain and inside an `if`
# condition, where bash suppresses errexit) with one step forced to fail, and
# requires: non-zero, the file byte-identical, no staging file left behind.
epr_inject_setup_mv() { mv() { return 1; }; }
epr_inject_setup_printf() {
  printf() {
    [[ $# -eq 2 && $1 == '%s' && ${2} == *FICUS_* ]] && return 1
    # shellcheck disable=SC2059 # pass-through shim
    builtin printf "$@"
  }
}
epr_inject_setup_mktemp() { mktemp() { return 1; }; }
epr_inject_setup_chmod() { chmod() { return 1; }; }
epr_inject_setup_cat() { cat() { return 1; }; }
for epr_case in mv printf mktemp chmod cat; do
  for epr_ctx in plain suppressed; do
    printf '# c\nTAU_A=1\nTAU_ENCRYPTION_KEY=k\n' >"${EPR}/inj.env" # legacy-env
    cp -p "${EPR}/inj.env" "${EPR}/inj.orig"
    hi_invoke "${epr_ctx}" "epr_inject_setup_${epr_case}" envfile_rename_prefix "${EPR}/inj.env" TAU FICUS
    hi_expect_failed "envfile_rename_prefix failure injection (${epr_case}, ${epr_ctx})"
    expect_eq "envfile_rename_prefix failure injection (${epr_case}, ${epr_ctx}): the file is byte-identical" \
      "$(cmp -s "${EPR}/inj.env" "${EPR}/inj.orig" && echo same)" 'same'
    expect_eq "envfile_rename_prefix failure injection (${epr_case}, ${epr_ctx}): no staging file is left" \
      "$(find "${EPR}" -maxdepth 1 -name '.inj.env.*' | wc -l | tr -d ' ')" '0'
  done
done
# The backup set: a failing copy leaves no set and no journal, in both contexts.
epr_inject_setup_cp() { cp() { return 1; }; }
epr_inject_setup_cmp() { cmp() { return 1; }; }
epr_inject_setup_sync() { sync() { [[ ${1:-} == --version ]] && return 0; return 1; }; }
for epr_case in cp cmp sync; do
  for epr_ctx in plain suppressed; do
    export ENV_RENAME_BACKUP_ROOT="${EPR}/inj-bk"
    rm -rf "${ENV_RENAME_BACKUP_ROOT}"
    hi_invoke "${epr_ctx}" "epr_inject_setup_${epr_case}" env_rename_backup_create FICUS "${EPR}/rel" "${EPR}/f1" "${EPR}/f2"
    hi_expect_failed "env_rename_backup_create failure injection (${epr_case}, ${epr_ctx})"
    expect_eq "env_rename_backup_create failure injection (${epr_case}, ${epr_ctx}): no journal" \
      "$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo left || echo none)" 'none'
    expect_eq "env_rename_backup_create failure injection (${epr_case}, ${epr_ctx}): no partial set" \
      "$(find "${ENV_RENAME_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" '0'
  done
done
# The restore: a failing rename of the staged copy leaves the journal (the
# next run reconciles) and returns non-zero in both contexts.
for epr_ctx in plain suppressed; do
  export ENV_RENAME_BACKUP_ROOT="${EPR}/inj-rbk"
  rm -rf "${ENV_RENAME_BACKUP_ROOT}"
  printf 'one\n' >"${EPR}/f1"
  EPR_SET=$(env_rename_backup_create FICUS "${EPR}/rel" "${EPR}/f1" 2>/dev/null)
  printf 'renamed\n' >"${EPR}/f1"
  hi_invoke "${epr_ctx}" epr_inject_setup_mv env_rename_backup_restore "${EPR_SET}"
  hi_expect_failed "env_rename_backup_restore failure injection (mv, ${epr_ctx})"
  expect_eq "env_rename_backup_restore failure injection (mv, ${epr_ctx}): the journal is kept" \
    "$([[ -e ${ENV_RENAME_BACKUP_ROOT}/PENDING ]] && echo kept || echo gone)" 'kept'
  expect_eq "env_rename_backup_restore failure injection (mv, ${epr_ctx}): no staging file is left" \
    "$(find "${EPR}" -maxdepth 1 -name '.f1.ficus-restore.*' | wc -l | tr -d ' ')" '0'
done

# --- TypeScript parity: the shell twin agrees with renameEnvPrefix -----------
# Same fixture, both implementations (packages/shared/src/legacy-env.ts): the
# renamed content, or a protected-conflict refusal on both sides.
EPR_TS_LIB="${SCRIPT_DIR}/../../packages/shared/src/legacy-env.ts"
if [[ -f ${EPR_TS_LIB} ]] && ! have bun; then
  # In this repo the TypeScript twin is right here: a run without bun would
  # silently drop the parity guarantee, so it is a failure, not a skip.
  FAIL=$((FAIL + 1))
  log_error 'FAIL: TS parity — bun is not on PATH, so envfile_rename_prefix cannot be checked against renameEnvPrefix'
fi
if [[ -f ${EPR_TS_LIB} ]] && have bun; then
  cat >"${EPR}/parity.ts" <<TSEOF
import { readFileSync } from 'node:fs'
import { EnvPrefixConflictError, renameEnvPrefix } from '$(cd "$(dirname "${EPR_TS_LIB}")" && pwd)/legacy-env.ts'
try {
  process.stdout.write(renameEnvPrefix(readFileSync(process.argv[2], 'utf8'), 'TAU_', 'FICUS_').content)
} catch (error) {
  process.stdout.write(error instanceof EnvPrefixConflictError ? '<conflict>' : '<ts-error>')
}
TSEOF
  epr_parity() { # LABEL CONTENT
    local ts sh err
    printf '%s' "$2" >"${EPR}/parity.env"
    ts=$(bun "${EPR}/parity.ts" "${EPR}/parity.env" && printf x) || ts='<bun-failed>x'
    ts=${ts%x}
    if err=$( (envfile_rename_prefix "${EPR}/parity.env" TAU FICUS) 2>&1 >/dev/null); then
      sh=$(cat "${EPR}/parity.env" && printf x)
      sh=${sh%x}
    elif [[ ${err} == *'disagree on this host'* ]]; then
      sh='<conflict>' # the protected-conflict refusal, and only that
    else
      sh='<sh-error>'
    fi
    expect_eq "TS parity: $1" "${sh}" "${ts}"
  }
  # legacy-env: every fixture below is a TAU_ input on purpose.
  epr_parity 'plain rename, comments, blank lines, export' $'# c\n\nTAU_A=1\nexport TAU_B=2\nB=3\n' # legacy-env
  epr_parity 'no trailing newline' 'TAU_A=1' # legacy-env
  epr_parity 'CRLF endings are kept' $'TAU_A=1\r\nX=2\r\n' # legacy-env
  epr_parity 'a PEM continuation line is value text' $'TAU_KEY="-----BEGIN\nTAU_INNER=x\n-----END"\nTAU_B=1\n' # legacy-env
  epr_parity 'a dropped multi-line entry takes its continuation lines' $'FICUS_KEY=v\nTAU_KEY="a\nb"\n' # legacy-env
  epr_parity 'KEY = value with spaces is left alone' $'TAU_A = 1\nTAU_B=2\n' # legacy-env
  epr_parity 'unprotected conflict: FICUS_ wins' $'TAU_T=a\nFICUS_T=b\n' # legacy-env
  epr_parity 'protected conflict refuses' $'TAU_ENCRYPTION_KEY=a\nFICUS_ENCRYPTION_KEY=b\n' # legacy-env
  epr_parity 'protected identical values de-duplicate' $'TAU_ENCRYPTION_KEY=a\nFICUS_ENCRYPTION_KEY="a"\n' # legacy-env
  epr_parity 'empty FICUS_ yields to TAU_' $'FICUS_PASSWORD=\nTAU_PASSWORD=x\n' # legacy-env
  epr_parity 'empty TAU_ is dropped' $'TAU_PASSWORD=\nFICUS_PASSWORD=x\n' # legacy-env
  epr_parity 'both empty' $'TAU_X=\nFICUS_X=\n' # legacy-env
  epr_parity 'managed key list mapped (quoted)' $'TAU_MANAGED_SECRET_KEYS="TAU_A, B,,TAU_C"\n' # legacy-env
  epr_parity 'managed key list mapped (bare)' $'TAU_MANAGED_SECRET_KEYS= TAU_A,B \n' # legacy-env
  epr_parity 'duplicate TAU_ keys both renamed' $'TAU_A=1\nTAU_A=2\n' # legacy-env
  epr_parity 'a later FICUS_ line still wins' $'TAU_A=1\nX=y\nFICUS_A=2\n' # legacy-env
  epr_parity 'the bare prefix is not a key' $'TAU_=1\nFICUS_=2\n' # legacy-env
  epr_parity 'an escaped quote does not close' $'TAU_A="x\\"\nTAU_B=1"\nTAU_C=2\n' # legacy-env
  epr_parity 'indented export' $'  export   TAU_A=1\n' # legacy-env
  epr_parity 'already renamed file' $'FICUS_A=1\n'
  epr_parity 'empty file' ''
else
  log_warn 'skipping the TypeScript parity cases — bun or packages/shared/src/legacy-env.ts not available'
fi

eval "${EPR_SAVED_AS_ROOT}"
FICUS_SYSTEMD_UNIT_DIR=${EPR_SAVED_SYSTEMD_UNIT_DIR}
FICUS_MANAGED_ENV_PATH=${EPR_SAVED_MANAGED_ENV_PATH}
BACKUP_ENV_TARGET=${EPR_SAVED_BACKUP_ENV_TARGET}
BACKUP_SCRIPT_PATH=${EPR_SAVED_BACKUP_SCRIPT_PATH}
unset ENV_RENAME_BACKUP_ROOT SRC_DEST RUN_USER BUN_BIN DB_MODE CORE_LAYOUT EPR_H
ENV_RENAME_PENDING=0 ENV_RENAME_BACKUP_SET='' ARTIFACT_CONVERTED_THIS_RUN=0 CFG_FILE=''
unset -f epr_mode epr_unit epr_host epr_matches_manifest epr_parity epr_inject_setup_mv epr_inject_setup_printf \
  epr_inject_setup_mktemp epr_inject_setup_chmod epr_inject_setup_cat epr_inject_setup_cp epr_inject_setup_cmp epr_inject_setup_sync
rm -rf "${EPR}"

rm -f "${HI_OUT_FILE}"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
