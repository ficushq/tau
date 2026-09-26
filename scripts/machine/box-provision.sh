#!/usr/bin/env bash
#
# tau box provisioning
# ====================
# Creates (or removes) ONE per-sandbox "box": a dedicated unix user that runs
# the tau sandbox server as a systemd service — either a per-box SYSTEM unit or
# a lingering systemd --user service, see --unit-mode.
#
# A box is THREE units, not one (spec D2, "socket activation + idle self-exit"):
#   <prefix>.socket        ListenStream=127.0.0.1:<port>. The only always-on
#                          unit; owns the box's port whether or not a server
#                          process exists, and activates the proxy below.
#   <prefix>-proxy.service systemd-socket-proxyd --exit-idle-time=30s <sock>,
#                          Requires=/After= the server, so the first connection
#                          after an idle exit brings the server back.
#   <prefix>.service       the bun server, bound to a UNIX socket
#                          (EXECUTOR_SOCKET) and exiting 0 after
#                          EXECUTOR_IDLE_EXIT_MS of quiet. NOT enabled: only the
#                          socket is, so an idle box costs zero RAM (measured
#                          2026-09-01 on a test host: 39 idle bun servers =
#                          1,672 MB).
# <prefix> is `tau-box-<user>` in system mode and `tau-sandbox-server` in user
# mode. Installed onto the host
# by bootstrap.sh at /opt/tau/bin/box-provision.sh; INVOKED by the slice-2
# manager, never during bootstrap itself.
#
# Target OS : Ubuntu 24.04 LTS ONLY (systemd 255, bash 5.2).
# Privilege : provisioning/publication require root or a passwordless sudoer.
#             --prepare-nix-cache runs unprivileged as the box user.
# Idempotent: safe to re-run — user creation, dirs, unit install, and linger all
#             check-then-act; --remove on an absent user is a no-op success.
# No secrets: embeds NO credentials. The server config/secrets arrive out-of-band
#             in %h/.tau/server.env, pushed by the slice-2 manager AFTER this
#             runs; the unit tolerates that file's (and the server bundle's)
#             absence and simply starts once they appear.
#
# Box user naming convention (informational — the user is passed in as --unix-user,
# this script does NOT derive it): the manager names box users `box_<hash>`, where
# <hash> is the first 12 hex chars of sha256(sandboxId).
#
# --unix-user validation (security): provisioning accepts the general account
# charset `^[a-z_][a-z0-9_-]{0,30}$`. REMOVAL is stricter and only ever acts on
# `box_<12 hex>` users (AND requires a real UID >= 1000) — it will never archive
# or delete a host account like `root` or `ubuntu`. --port is validated as an
# integer in 1024-65535 before it is written into the systemd unit.
#
# Usage:
#   Provision (port required):
#     box-provision.sh --sandbox-id <id> --unix-user <user> --port <port> \
#                      [--unit-mode system|user] [--with-docker]
#   Restore/remove (port unused and optional):
#     box-provision.sh --unix-user <user> --remove
#     box-provision.sh --unix-user <user> --restore <tar>
#     box-provision.sh --unix-user <user> --restore-stream \
#                      --codec <gzip|zstd> --state-dirs "<dirs>"
#
#   Cache maintenance (port unused):
#     box-provision.sh --unix-user <user> --prepare-nix-cache
#     box-provision.sh --sandbox-id devbox-prewarm-<role>-<machine> \
#                      --unix-user <user> --publish-nix-cache
#
# --port <port>
#            --port is required for provisioning only. Restore and removal do
#            not configure or connect to a server port, so they may omit it. If
#            supplied in any mode, it must be a separate value in 1024-65535.
#
# --unit-mode system|user
#            WHICH systemd manager runs the box server. Defaults from
#            --sandbox-id: `agent_*` → system, everything else (`squad_*`,
#            `system_manager_*`, and any legacy/unknown id) → user, matching
#            box-manager's `boxUnitControl` seam exactly — the two sides must
#            never disagree about which unit exists, so the manager passes the
#            flag explicitly.
#
#            user   — today's layout: `tau-sandbox-server.service` under the box
#                     user's own lingering `systemd --user` manager. Required
#                     for --with-docker (rootless dockerd IS a user service).
#            system — one root-owned unit per box,
#                     /etc/systemd/system/tau-box-<user>.service with
#                     User=/Group=<user> and Slice=tau-box-<user>.slice. No
#                     linger, so a light box costs no `systemd --user` + dbus
#                     pair (measured 2026-09-01 on a test host: ~13 MB per box
#                     × 45 managers ≈ 585 MB of pure idle overhead).
#
#            Mode changes are MIGRATED, detected from what is on disk (never
#            from the flag): re-provisioning a box that carries the other mode's
#            unit tears that one down (stop, disable, remove its unit + slice
#            drop-in, drop linger when leaving user mode) before installing the
#            new one.
#
# --with-docker  Provision a per-box ROOTLESS dockerd as the box user's own
#            systemd --user service (default OFF). Squad + system-manager boxes
#            pass it; agent (light) boxes do NOT (they never run containers),
#            mirroring k8s where the agent role skips dockerd. Requires the box
#            user's linger (enabled here) + a /etc/subuid+/etc/subgid range
#            (useradd auto-allocates on Ubuntu 24.04; allocated here if missing).
#            The daemon listens on unix:///run/user/<uid>/docker.sock. NO shared
#            rootful daemon is ever started — bootstrap.sh masks the system one.
#
# On provisioning, the box user's useradd-assigned UID (NOT deterministic) is
# printed as the sole stdout line `FICUS_BOX_UID=<uid>` so the caller (box-manager)
# can bake DOCKER_HOST. All other output goes to stderr.
#
# --remove   Stop all three units (socket first, so it cannot re-activate the
#            proxy mid-teardown), disable linger, ARCHIVE the whole home to
#            /opt/tau/archive/<user>-<epoch>.tar.gz (timestamped, never
#            overwriting), then `userdel -r`. The archive includes the workspace;
#            slice 2's manager must pull any archives it cares about BEFORE
#            calling --remove.
#
# --restore <tar>
#            Extract a previously pulled state archive (gzip'd tar whose top
#            members are the box's state dirs — `.private` for agent/
#            system-manager boxes, and `workspace` alongside `.private` for a
#            SQUAD box — pushed to <tar> by a core-side caller holding an
#            at-rest archive; box MIGRATION does not use this mode, it streams
#            host→host via --restore-stream below)
#            into the box user's HOME, then re-own EVERY extracted member to the
#            box user and lock it (workspace 0755, private trees 0700; extraction
#            runs as root and would otherwise keep the archived ownership,
#            leaving a squad ~/workspace unwritable). Idempotent — overwriting an
#            existing tree is fine. A missing/empty <tar> is a successful no-op
#            (mirrors the pull side, which emits an EMPTY archive for a box that
#            had nothing to archive). Like removal, restore only ever acts on
#            box_<12 hex> users.
#
# --restore-stream --codec <gzip|zstd> --state-dirs "<dirs>"
#            The STREAMING sibling of --restore, used by box migration: the tar
#            arrives on STDIN (piped straight from the source machine's `tar c`
#            over SSH) and is extracted into the box HOME without ever being
#            staged on this host's disk — a multi-GB squad ~/workspace would
#            otherwise need transient headroom equal to itself, on a machine
#            that may be migrating BECAUSE of disk pressure.
#            --codec must equal the codec the SOURCE wrote with: a stream can
#            only be read once, so unlike --restore this mode cannot re-read the
#            archive to learn anything about it. For the same reason the members
#            to re-own are supplied as --state-dirs (the role-derived set) rather
#            than listed from the tar. Ownership/modes are applied by the SAME
#            helper --restore uses (workspace 0755, private trees 0700), so the
#            two paths cannot drift. Like removal, only ever acts on
#            box_<12 hex> users.

set -euo pipefail

SANDBOX_ID=""
UNIX_USER=""
PORT=""
PORT_SUPPLIED=false
REMOVE=false
RESTORE=false
RESTORE_TAR=""
RESTORE_STREAM=false
CODEC="gzip"
STATE_DIRS=""
STAGING_ID=""
WITH_DOCKER=false
UNIT_MODE=""
PRINT_SUBID_START=false
PRINT_SLICE_LIMITS=false
PRINT_UNITS=false
PREPARE_NIX_CACHE=false
PUBLISH_NIX_CACHE=false
MEMTOTAL_KB_OVERRIDE=""
NPROC_OVERRIDE=""

# The subordinate-id maps ensure_subid_range allocates from. Real paths in
# production; overridable ONLY so the side-effect-free --print-subid-start dry run
# can point the overlap scan at test fixtures (mirrors bootstrap's
# --print-egress-ruleset). Nothing else changes these.
SUBUID_FILE="/etc/subuid"
SUBGID_FILE="/etc/subgid"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sandbox-id)
      SANDBOX_ID="${2:-}"
      shift 2
      ;;
    --unix-user)
      UNIX_USER="${2:-}"
      shift 2
      ;;
    --port)
      # Do not consume another option as the value. Besides producing a precise
      # error, this keeps mode flags such as --restore-stream from disappearing
      # when a caller accidentally emits a bare --port.
      if [ "$#" -lt 2 ] || [[ "${2}" == --* ]]; then
        echo "box-provision.sh: --port requires a value" >&2
        exit 2
      fi
      PORT="${2}"
      PORT_SUPPLIED=true
      shift 2
      ;;
    --with-docker)
      WITH_DOCKER=true
      shift
      ;;
    --unit-mode)
      UNIT_MODE="${2:-}"
      shift 2
      ;;
    --prepare-nix-cache)
      PREPARE_NIX_CACHE=true
      shift
      ;;
    --publish-nix-cache)
      PUBLISH_NIX_CACHE=true
      shift
      ;;
    --remove)
      REMOVE=true
      shift
      ;;
    --restore)
      RESTORE=true
      RESTORE_TAR="${2:-}"
      shift 2
      ;;
    --restore-stream)
      RESTORE_STREAM=true
      shift
      ;;
    --codec)
      CODEC="${2:-}"
      shift 2
      ;;
    --state-dirs)
      STATE_DIRS="${2:-}"
      shift 2
      ;;
    --staging-id)
      STAGING_ID="${2:-}"
      shift 2
      ;;
    --print-slice-limits)
      # Side-effect-free dry run: print the per-box slice resource limits this
      # host would install (MemoryHigh/MemoryMax/TasksMax), then exit. Pair
      # with --memtotal-kb to pin the host size. Used by tests.
      PRINT_SLICE_LIMITS=true
      shift
      ;;
    --memtotal-kb)
      MEMTOTAL_KB_OVERRIDE="${2:-}"
      shift 2
      ;;
    --nproc)
      NPROC_OVERRIDE="${2:-}"
      shift 2
      ;;
    --print-units)
      # Side-effect-free dry run: print the THREE unit files this invocation
      # would install — server, socket, proxy — each as a `# path: <path>`
      # header then the file body, then exit. Pair with
      # --unit-mode/--unix-user/--port/--sandbox-id. Used by tests.
      PRINT_UNITS=true
      shift
      ;;
    --print-subid-start)
      # Side-effect-free dry run: scan the subuid/subgid maps and print the start
      # ensure_subid_range would allocate for a fresh 65536 block, then exit. No
      # useradd, no tee, no sudo. Used by tests to assert the overlap scan.
      PRINT_SUBID_START=true
      shift
      ;;
    --subuid-file)
      SUBUID_FILE="${2:-}"
      shift 2
      ;;
    --subgid-file)
      SUBGID_FILE="${2:-}"
      shift 2
      ;;
    *)
      echo "box-provision.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# --- Unit mode ---------------------------------------------------------------
#
# Resolved BEFORE anything privileged runs so the --with-docker conflict below
# is caught by argument validation rather than half-way through a provision.
# The default is derived from the sandboxId PREFIX — the same authority that
# decides a box's role (#1315) — and is mirrored 1:1 by box-manager's
# `boxUnitControl` seam, which also passes --unit-mode explicitly. An unknown
# prefix (a legacy id that is neither agent_/squad_/system_manager_) keeps the
# historical user-manager layout: unknown must never silently move a live box
# onto a different unit.
if [ -z "${UNIT_MODE}" ]; then
  case "${SANDBOX_ID}" in
    agent_*) UNIT_MODE="system" ;;
    *) UNIT_MODE="user" ;;
  esac
fi
case "${UNIT_MODE}" in
  system | user) ;;
  *)
    echo "box-provision.sh: invalid --unit-mode '${UNIT_MODE}' (must be system or user)" >&2
    exit 2
    ;;
esac

# Rootless docker IS a systemd --user service (dockerd-rootless-setuptool writes
# ~/.config/systemd/user/docker.service and the daemon listens on
# /run/user/<uid>/docker.sock, which only a user manager + linger create). A
# docker box therefore cannot drop its user manager; refuse the combination
# loudly instead of provisioning a box whose docker socket never appears.
if [ "${WITH_DOCKER}" = true ] && [ "${UNIT_MODE}" = "system" ]; then
  echo "box-provision.sh: --with-docker requires --unit-mode user (rootless docker needs the box user's systemd --user manager)" >&2
  exit 2
fi

# Subordinate-id allocation: one 65536-wide block per box user, starting here.
SUBID_COUNT=65536
SUBID_BASE=100000

# Highest (start+count) end across all entries in a subuid/subgid map file,
# floored at SUBID_BASE (the conventional base for the first block). Returns
# SUBID_BASE for an absent/empty file. Malformed lines are skipped defensively.
# Read-only + unprivileged: the maps are world-readable.
# --- Per-box resource limits -------------------------------------------------
#
# Every box runs under its own user-<uid>.slice. The cpu/memory/pids
# controllers are delegated to user slices, so CPU is already fair-shared per
# box — but MemoryHigh/MemoryMax defaulted to infinity, so ONE box's build
# (measured 2026-09-01: four rustc @650MB + go + a 1.8GB Chromium on an 8GB
# host carrying 53 boxes) drove the host to ~80MB free and 180MB/s of
# page-cache re-reads, and every co-located sandbox-server stopped answering
# health probes: the squad box flapped "Box server unresponsive → Starting →
# Running" for an hour. The drop-in below caps each box relative to host RAM:
# memory.high throttles the greedy slice before it can starve the others, and
# memory.max is the hard stop (the kernel OOM-kills inside THAT slice only).
# TasksMax bounds fork bombs the same way. Written as root under
# /etc/systemd/system so a box user cannot raise its own limits.
SLICE_MEMORY_HIGH_PCT=35
SLICE_MEMORY_MAX_PCT=50
SLICE_TASKS_MAX=8192
# CPU: one box may use at most half the host's cores (never below one full
# core). Memory caps (above) stop a build from paging the host out; this stops
# it from taking every core, so co-located sandbox-servers keep answering.
SLICE_CPU_SHARE_PCT=50

# How long a socket-activated box server stays resident with nothing to do
# before it exits(0) and hands the port back to its .socket unit. Measured
# 2026-09-01 on a test host: 39 idle bun servers held 1,672 MB — the whole
# point of the socket layout. The gate that makes the exit safe (no live bash
# invocation, no open shell, no active watcher) lives in the server itself;
# see packages/k8s-sandbox/src/services/idle-exit.ts.
IDLE_EXIT_MS=600000

host_nproc() {
  if [ -n "${NPROC_OVERRIDE}" ]; then
    printf '%s' "${NPROC_OVERRIDE}"
    return
  fi
  nproc
}

# The parallelism a box's builds should default to: half the host's cores,
# at least one. Written to ~/.tau/host.env as FICUS_BOX_CPUS; the server derives
# CARGO_BUILD_JOBS / MAKEFLAGS / GOMAXPROCS / CMAKE_BUILD_PARALLEL_LEVEL for
# every child it spawns unless the caller set them explicitly.
box_cpus() {
  local n
  n="$(host_nproc)"
  case "${n}" in
    ''|*[!0-9]*)
      echo "box-provision.sh: could not read nproc (${n:-empty})" >&2
      return 1
      ;;
  esac
  local cpus=$(( n * SLICE_CPU_SHARE_PCT / 100 ))
  [ "${cpus}" -lt 1 ] && cpus=1
  printf '%s' "${cpus}"
}

host_memtotal_kb() {
  if [ -n "${MEMTOTAL_KB_OVERRIDE}" ]; then
    printf '%s' "${MEMTOTAL_KB_OVERRIDE}"
    return
  fi
  awk '/^MemTotal:/ {print $2}' /proc/meminfo
}

# Prints "MemoryHigh=<bytes>\nMemoryMax=<bytes>\nTasksMax=<n>" for this host.
slice_limits() {
  local total_kb high_kb max_kb
  total_kb="$(host_memtotal_kb)"
  case "${total_kb}" in
    ''|*[!0-9]*)
      echo "box-provision.sh: could not read MemTotal (${total_kb:-empty})" >&2
      return 1
      ;;
  esac
  high_kb=$(( total_kb * SLICE_MEMORY_HIGH_PCT / 100 ))
  max_kb=$(( total_kb * SLICE_MEMORY_MAX_PCT / 100 ))
  local n quota
  n="$(host_nproc)"
  case "${n}" in
    ''|*[!0-9]*)
      echo "box-provision.sh: could not read nproc (${n:-empty})" >&2
      return 1
      ;;
  esac
  quota=$(( n * SLICE_CPU_SHARE_PCT ))
  [ "${quota}" -lt 100 ] && quota=100
  printf 'MemoryHigh=%s\nMemoryMax=%s\nTasksMax=%s\nCPUQuota=%s%%\n' "$(( high_kb * 1024 ))" "$(( max_kb * 1024 ))" "${SLICE_TASKS_MAX}" "${quota}"
}

# ~/.tau/host.env: per-box facts the HOST decides (Core never sees nproc). The
# unit loads it BEFORE server.env, so anything Core pushes still wins.
write_host_env() {
  local home="$1" cpus
  cpus="$(box_cpus)" || return 1
  printf 'FICUS_BOX_CPUS=%s\n' "${cpus}" \
    | "${SUDO[@]}" install -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0644 /dev/stdin "${home}/.tau/host.env"
}

# Where the limits land depends on WHICH slice the box's server runs under:
# user mode inherits the box user's own user-<uid>.slice, system mode carries
# its own tau-box-<user>.slice (named in the unit's `Slice=`). Both live under
# /etc/systemd/system so a box user cannot raise its own limits.
user_slice_dropin_dir() {
  printf '/etc/systemd/system/user-%s.slice.d' "$(box_uid)"
}

system_slice_dropin_dir() {
  printf '/etc/systemd/system/tau-box-%s.slice.d' "${UNIX_USER}"
}

slice_dropin_dir() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_slice_dropin_dir
  else
    user_slice_dropin_dir
  fi
}

install_slice_limits() {
  local limits
  limits="$(slice_limits)" || return 1
  local dir
  dir="$(slice_dropin_dir)"
  "${SUDO[@]}" install -d -m 0755 "${dir}"
  printf '[Slice]\n%s\n' "${limits}" \
    | "${SUDO[@]}" install -o root -g root -m 0644 /dev/stdin "${dir}/50-tau-box.conf"
  "${SUDO[@]}" systemctl daemon-reload
}

# Removal drops BOTH modes' drop-ins: the box is going away entirely, and a box
# that was migrated between modes at some point may carry the other one.
remove_slice_limits() {
  "${SUDO[@]}" rm -rf "$(user_slice_dropin_dir)" "$(system_slice_dropin_dir)"
  "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
}

highest_subid_end() {
  local file="$1" highest="${SUBID_BASE}" s c end
  [ -r "${file}" ] || {
    printf '%s' "${highest}"
    return 0
  }
  while IFS=: read -r _ s c; do
    [[ "${s}" =~ ^[0-9]+$ ]] || continue
    [[ "${c}" =~ ^[0-9]+$ ]] || continue
    end=$((s + c))
    if [ "${end}" -gt "${highest}" ]; then highest="${end}"; fi
  done <"${file}"
  printf '%s' "${highest}"
}

# The start of the next non-overlapping 65536 block across BOTH maps: the max end
# over subuid and subgid. Since it sits at/above every existing range's end, the
# allocated block [start, start+65536) cannot overlap any existing entry.
next_subid_start() {
  local u g
  u="$(highest_subid_end "${SUBUID_FILE}")"
  g="$(highest_subid_end "${SUBGID_FILE}")"
  if [ "${u}" -ge "${g}" ]; then printf '%s' "${u}"; else printf '%s' "${g}"; fi
}

# Side-effect-free dry run (tests): print the computed start and exit, no privilege.
if [ "${PRINT_SLICE_LIMITS}" = true ]; then
  slice_limits
  exit $?
fi

if [ "${PRINT_SUBID_START}" = true ]; then
  next_subid_start
  printf '\n'
  exit 0
fi

if [ -z "${UNIX_USER}" ]; then
  echo "box-provision.sh: --unix-user is required" >&2
  exit 2
fi

# Validate --unix-user BEFORE any privileged call. Provisioning accepts the
# general account charset below; removal (see remove_box) narrows further and
# ONLY ever acts on `box_<hash>` users this tooling created — that guard, not
# this charset, is what stops `--unix-user ubuntu --remove` from deleting a host
# admin account.
if [[ ! "${UNIX_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
  echo "box-provision.sh: invalid --unix-user '${UNIX_USER}' (must match ^[a-z_][a-z0-9_-]{0,30}\$)" >&2
  exit 2
fi

# Validate --port BEFORE it is baked into the root-written systemd unit, so a
# newline (or any non-digit) can never inject arbitrary unit directives. --port
# is REQUIRED on the provision path: an empty value would otherwise write
# `Environment=FICUS_BOX_PORT=` into the unit. Removal and restore modes do not
# use a port, so omission is safe there. If a caller does supply --port in any
# mode, validate it consistently rather than silently accepting malformed input.
if [ "${REMOVE}" != true ] && [ "${RESTORE}" != true ] && [ "${RESTORE_STREAM}" != true ] && [ "${PORT_SUPPLIED}" != true ] && [ "${PREPARE_NIX_CACHE}" != true ] && [ "${PUBLISH_NIX_CACHE}" != true ]; then
  echo "box-provision.sh: --port is required for provisioning" >&2
  exit 2
fi
if [ "${PORT_SUPPLIED}" = true ]; then
  if [[ ! "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1024 ] || [ "${PORT}" -gt 65535 ]; then
    echo "box-provision.sh: invalid --port '${PORT}' (must be an integer 1024-65535)" >&2
    exit 2
  fi
fi

# Validate the stream-restore inputs BEFORE any privileged call, for the same
# reason --port is validated above: both values are interpolated into commands
# that run as root. --codec selects a tar flag; --state-dirs names the HOME
# members that get chown -R'd, so each must be a plain path segment (no `..`, no
# separators, no shell metacharacters) — the caller only ever sends the fixed
# role-derived literals, and this re-asserts that independently.
if [ "${RESTORE_STREAM}" = true ]; then
  case "${CODEC}" in
    gzip | zstd) ;;
    *)
      echo "box-provision.sh: invalid --codec '${CODEC}' (must be gzip or zstd)" >&2
      exit 2
      ;;
  esac
  # An EMPTY list is rejected, not tolerated: the per-entry loop below passes it
  # vacuously, and the restore would then re-own only `.private` (reown_members'
  # fallback) and still exit 0 — leaving a streamed ~/workspace ROOT-OWNED on a
  # box that reports success. A restore that cannot name what it is restoring is
  # not a restore.
  if [[ ! "${STATE_DIRS}" =~ [^[:space:]] ]]; then
    echo "box-provision.sh: --restore-stream requires a non-empty --state-dirs" >&2
    exit 2
  fi
  for d in ${STATE_DIRS}; do
    if [[ ! "${d}" =~ ^[A-Za-z0-9._-]+$ ]] || [ "${d}" = "." ] || [ "${d}" = ".." ]; then
      echo "box-provision.sh: invalid --state-dirs entry '${d}' (must be a plain path segment)" >&2
      exit 2
    fi
  done
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo)
fi

# The user-manager unit name is FIXED (one per box user, in that user's own
# manager); the system unit is per-box, so it carries the user in its name.
USER_UNIT_PREFIX="tau-sandbox-server"
USER_UNIT_NAME="${USER_UNIT_PREFIX}.service"
USER_SOCKET_NAME="${USER_UNIT_PREFIX}.socket"
USER_PROXY_NAME="${USER_UNIT_PREFIX}-proxy.service"

# systemd's socket proxy. Absent on a pre-density machine image; provisioning
# refuses rather than installing a socket whose activated service cannot exist.
SOCKET_PROXYD="/usr/lib/systemd/systemd-socket-proxyd"

system_unit_prefix() {
  printf 'tau-box-%s' "${UNIX_USER}"
}

system_unit_name() {
  printf '%s.service' "$(system_unit_prefix)"
}

system_socket_name() {
  printf '%s.socket' "$(system_unit_prefix)"
}

system_proxy_name() {
  printf '%s-proxy.service' "$(system_unit_prefix)"
}

system_unit_path() {
  printf '/etc/systemd/system/%s' "$(system_unit_name)"
}

system_socket_path() {
  printf '/etc/systemd/system/%s' "$(system_socket_name)"
}

system_proxy_path() {
  printf '/etc/systemd/system/%s' "$(system_proxy_name)"
}

system_slice_name() {
  printf 'tau-box-%s.slice' "${UNIX_USER}"
}

user_unit_path() {
  printf '%s/.config/systemd/user/%s' "$1" "${USER_UNIT_NAME}"
}

user_socket_path() {
  printf '%s/.config/systemd/user/%s' "$1" "${USER_SOCKET_NAME}"
}

user_proxy_path() {
  printf '%s/.config/systemd/user/%s' "$1" "${USER_PROXY_NAME}"
}

# The units this invocation's --unit-mode installs, and where they land
# ($1 = home, for the user-mode paths).
unit_name() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_unit_name
  else
    printf '%s' "${USER_UNIT_NAME}"
  fi
}

socket_name() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_socket_name
  else
    printf '%s' "${USER_SOCKET_NAME}"
  fi
}

proxy_name() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_proxy_name
  else
    printf '%s' "${USER_PROXY_NAME}"
  fi
}

unit_path() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_unit_path
  else
    user_unit_path "$1"
  fi
}

socket_path() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_socket_path
  else
    user_socket_path "$1"
  fi
}

proxy_path() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_proxy_path
  else
    user_proxy_path "$1"
  fi
}

# The RuntimeDirectory= the SERVER unit declares, and the unix socket inside it
# that the server binds and the proxy connects to. Both units must name the
# SAME path; in user mode `%t` (XDG_RUNTIME_DIR) resolves identically in both
# because they share one user manager, so no uid lookup is needed and the
# --print-units dry run stays pure. In a SYSTEM unit `%t` is /run, so the
# concrete path is spelled out (and is per-box, hence the user in its name).
runtime_dir_name() {
  if [ "${UNIT_MODE}" = "system" ]; then
    system_unit_prefix
  else
    printf 'tau-sandbox'
  fi
}

box_socket_file() {
  if [ "${UNIT_MODE}" = "system" ]; then
    printf '/run/%s/server.sock' "$(system_unit_prefix)"
  else
    printf '%%t/tau-sandbox/server.sock'
  fi
}

# systemd-socket-proxyd connects to the backend ONCE per accepted connection and
# does not retry, so the first request after a cold start would be dropped in the
# window between `systemctl start <server>` returning (Type=simple: exec'd, not
# yet listening) and the server actually binding its socket. Wait for the socket
# to exist first — bounded at 30s, then fail loudly so a genuinely broken server
# surfaces as a failed proxy rather than a silent hang.
#
# `$$` is systemd's escape for a literal `$` in an Exec line (systemd would
# otherwise try to expand `$n` itself); `%t` is expanded by systemd before the
# shell ever sees it.
proxy_wait_command() {
  local sock="$1"
  printf "/bin/sh -c 'n=0; while [ ! -S %s ] && [ \$\$n -lt 300 ]; do sleep 0.1; n=\$\$((n+1)); done; test -S %s'" \
    "${sock}" "${sock}"
}

# Run systemctl against ANOTHER user's --user manager non-interactively.
#
# `systemctl --machine=<user>@.host --user` connects directly to that user's
# systemd manager bus and needs no XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS
# guessing. It requires systemd >= 248 (Ubuntu 24.04 ships 255) and a running
# per-user manager, which `loginctl enable-linger` guarantees. systemd itself
# recommends this form when XDG_RUNTIME_DIR is unset.
#   Source: Red Hat KB "How to execute systemctl --user as a different user"
#           https://access.redhat.com/solutions/4661741
#           and systemd's own "consider using --machine=@.host --user" hint.
sysu() {
  "${SUDO[@]}" systemctl --machine="${UNIX_USER}@.host" --user "$@"
}

# systemctl for THIS box's server unit, whichever manager owns it. Everything
# that touches the box unit goes through here so a mode change can never leave a
# verb pointed at the wrong manager.
sysbox() {
  if [ "${UNIT_MODE}" = "system" ]; then
    "${SUDO[@]}" systemctl "$@"
  else
    sysu "$@"
  fi
}

user_home() {
  getent passwd "${UNIX_USER}" | cut -d: -f6
}

box_uid() {
  id -u "${UNIX_USER}"
}



# Run a command AS the box user inside its own lingering systemd --user session.
# Also used for cache maintenance/publication reads, which need only UID/HOME
# isolation and do not require a running user manager.
# linger (enabled in provision_box) guarantees the user manager + its
# XDG_RUNTIME_DIR (/run/user/<uid>) exist, which the rootless docker tooling and
# `systemctl --user` both need. HOME is set explicitly because the privilege drop
# does not reliably reset it — the setuptool writes ~/.config/systemd/user +
# ~/.docker, so a wrong HOME would land them under the invoking user. PATH is
# pinned so the box user's (possibly empty) environment still finds the system
# dockerd-rootless scripts.
#
# The drop-to-box-user command cannot be `"${SUDO[@]}" -u` — when box-provision
# itself runs AS ROOT (a root SSH admin user), SUDO is the empty array, so that
# would expand to a bare `-u …` and try to exec `-u` as a command. Select the
# drop tool by privilege: `runuser -u` when already root (util-linux, always
# present, needs no sudo), `sudo -u` when a passwordless sudoer.
run_as_box() {
  local uid runtime_dir home
  uid="$(box_uid)"
  runtime_dir="/run/user/${uid}"
  home="$(user_home)"
  local -a as_box
  if [ "$(id -u)" -eq 0 ]; then
    as_box=(runuser -u "${UNIX_USER}" --)
  else
    as_box=(sudo -u "${UNIX_USER}")
  fi
  "${as_box[@]}" \
    env "HOME=${home}" \
      "XDG_RUNTIME_DIR=${runtime_dir}" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime_dir}/bus" \
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      "$@"
}

# Rootless docker needs a /etc/subuid + /etc/subgid subordinate-id range for the
# box user. useradd on Ubuntu 24.04 auto-allocates one; when it is missing we
# allocate a 65536-wide range ourselves. The old keyed formula
# (100000+(uid-1000)*65536) could OVERLAP an auto-allocated peer's range after a
# uid was freed and reused (a fresh box getting a recycled uid maps onto a live
# peer's block). Instead SCAN both maps for the highest existing range end and
# append the next block ABOVE it — provably non-overlapping. Idempotent: a user
# already present in a map is left as-is (never duplicated).
ensure_subid_range() {
  local in_uid=false in_gid=false start
  grep -q "^${UNIX_USER}:" "${SUBUID_FILE}" 2>/dev/null && in_uid=true
  grep -q "^${UNIX_USER}:" "${SUBGID_FILE}" 2>/dev/null && in_gid=true

  # Already allocated in both maps (correct existing entry / useradd default) → leave.
  if [ "${in_uid}" = true ] && [ "${in_gid}" = true ]; then
    return 0
  fi

  # One start for both maps (mirrors useradd's paired allocation), chosen above
  # the highest end across BOTH so it collides with neither.
  start="$(next_subid_start)"

  if [ "${in_uid}" != true ]; then
    printf '%s:%s:%s\n' "${UNIX_USER}" "${start}" "${SUBID_COUNT}" | "${SUDO[@]}" tee -a "${SUBUID_FILE}" >/dev/null
  fi
  if [ "${in_gid}" != true ]; then
    printf '%s:%s:%s\n' "${UNIX_USER}" "${start}" "${SUBID_COUNT}" | "${SUDO[@]}" tee -a "${SUBGID_FILE}" >/dev/null
  fi
}

# Provision the box user's OWN rootless dockerd (a systemd --user service). NEVER
# starts a shared rootful daemon (bootstrap.sh masks the system one) — closing
# the multi-box root hole (spec §5). Idempotent: setuptool tolerates an existing
# install; enable/start are best-effort.
provision_docker() {
  ensure_subid_range

  # dockerd-rootless-setuptool.sh sets up the box user's ~/.config/systemd/user
  # docker.service. It is idempotent (tolerates "already installed"); its stdout
  # is routed to stderr so it never pollutes the FICUS_BOX_UID marker line.
  #
  # `--skip-iptables` makes the setuptool's iptables pre-flight check pass on
  # kernels where the nf_tables backend is BUILT INTO the kernel but listed in
  # neither /proc/modules nor modules.builtin — e.g. exe.dev's custom kernel,
  # where `iptables` works fine via the nft backend yet `modprobe nf_tables`
  # FATALs ("Module nf_tables not found"). Without the flag that false-negative
  # check aborts install ("Missing system requirements"), no unit is written,
  # and the box's docker.service never exists (observed live on exe 2026-07-14).
  run_as_box dockerd-rootless-setuptool.sh install --skip-iptables >&2 \
    || echo "box-provision.sh: dockerd-rootless-setuptool.sh returned non-zero (may already be installed)" >&2

  # The flag's catch: when (and only when) that pre-flight check tripped, the
  # setuptool bakes `--iptables=false` into the unit's ExecStart — which disables
  # the container bridge's MASQUERADE, so containers get a default route but NO
  # egress (verified live on exe: TCP to any off-box address fails). iptables
  # itself works on such kernels (nft backend), so strip the flag back out with a
  # systemd drop-in that reproduces the setuptool's own launch line minus
  # `--iptables=false`. A drop-in (not an in-place unit edit) survives the
  # setuptool REWRITING docker.service on every re-provision. On a host whose
  # kernel lists the module normally the check passes, no flag is baked, and the
  # drop-in reproduces the stock ExecStart verbatim — a harmless no-op.
  local home exec_line launcher_cmd override_dir
  home="$(user_home)"
  exec_line="$(run_as_box sed -n 's/^ExecStart=//p' \
    "${home}/.config/systemd/user/docker.service" 2>/dev/null | head -n1)"
  launcher_cmd="${exec_line// --iptables=false/}"
  if [ -n "${launcher_cmd}" ]; then
    override_dir="${home}/.config/systemd/user/docker.service.d"
    run_as_box mkdir -p "${override_dir}"
    printf '[Service]\nExecStart=\nExecStart=%s\n' "${launcher_cmd}" \
      | run_as_box tee "${override_dir}/override.conf" >/dev/null
    sysu daemon-reload >/dev/null 2>&1 || true
  fi

  # Enable + RESTART (not start) the user docker daemon so
  # unix:///run/user/<uid>/docker.sock exists with the corrected flags: the
  # setuptool auto-STARTS docker.service during install — with `--iptables=false`
  # still baked in — so a plain `start` would no-op against that running daemon
  # and leave container egress broken. The bounce is safe: provisioning only runs
  # on first-create or an unhealthy re-provision (box-manager skips healthy boxes).
  sysu enable docker.service >/dev/null 2>&1 || true
  sysu restart docker.service >/dev/null 2>&1 \
    || echo "box-provision.sh: rootless docker.service start deferred" >&2
}

remove_box() {
  # SAFETY: removal ARCHIVES the home and `userdel -r`s the account — it must
  # ONLY ever touch users this tooling created, which always follow the
  # `box_<12 hex>` convention. Refuse anything else outright (this catches
  # `root`, `ubuntu`, and any other host account that passes the general
  # provisioning charset). Checked before existence, before any privileged call.
  if [[ ! "${UNIX_USER}" =~ ^box_[0-9a-f]{12}$ ]]; then
    echo "box-provision.sh: refusing to remove non-box user '${UNIX_USER}' (must match box_<12hex>)" >&2
    exit 2
  fi

  if ! id -u "${UNIX_USER}" >/dev/null 2>&1; then
    echo "box-provision.sh: user ${UNIX_USER} does not exist; nothing to remove" >&2
    return 0
  fi

  # Defense-in-depth: never delete a system/service account even if it somehow
  # carried a box_* name — require a real login UID (>= 1000).
  local uid
  uid="$(id -u "${UNIX_USER}")"
  if [ "${uid}" -lt 1000 ]; then
    echo "box-provision.sh: refusing to remove '${UNIX_USER}' with system UID ${uid} (< 1000)" >&2
    exit 2
  fi

  # Best-effort teardown of the running service before the manager goes away.
  # Removal is mode-AGNOSTIC (it may run without a --sandbox-id, and a box may
  # carry the other mode's leftovers): tear down BOTH layouts unconditionally.
  # Socket first: it would otherwise re-activate the proxy (and through it the
  # server) between the stops below.
  sysu stop "${USER_SOCKET_NAME}" "${USER_PROXY_NAME}" "${USER_UNIT_NAME}" >/dev/null 2>&1 || true
  sysu disable "${USER_SOCKET_NAME}" "${USER_UNIT_NAME}" >/dev/null 2>&1 || true
  "${SUDO[@]}" systemctl stop "$(system_socket_name)" "$(system_proxy_name)" "$(system_unit_name)" >/dev/null 2>&1 || true
  "${SUDO[@]}" systemctl disable "$(system_socket_name)" "$(system_unit_name)" >/dev/null 2>&1 || true
  "${SUDO[@]}" rm -f "$(system_unit_path)" "$(system_socket_path)" "$(system_proxy_path)"
  "${SUDO[@]}" loginctl disable-linger "${UNIX_USER}" >/dev/null 2>&1 || true
  remove_slice_limits
  # Give the per-user manager a moment to exit so its files aren't in the tar.
  "${SUDO[@]}" loginctl terminate-user "${UNIX_USER}" >/dev/null 2>&1 || true

  # loginctl terminate-user is ASYNC and does not reliably reap a rootless
  # dockerd (or other detached processes) that isn't tracked in a login session,
  # so a subsequent `userdel` fails with "user ... is currently used by process
  # N" (observed against a live exe.dev --with-docker box, 2026-07-13).
  # Force-kill everything the user owns and wait for it to actually exit.
  "${SUDO[@]}" pkill -KILL -u "${UNIX_USER}" >/dev/null 2>&1 || true
  local kill_tries=0
  while "${SUDO[@]}" pgrep -u "${UNIX_USER}" >/dev/null 2>&1; do
    kill_tries=$((kill_tries + 1))
    [ "${kill_tries}" -ge 20 ] && break # ~10s cap, then let userdel try anyway
    "${SUDO[@]}" pkill -KILL -u "${UNIX_USER}" >/dev/null 2>&1 || true
    sleep 0.5
  done

  local home
  home="$(user_home)"
  if [ -n "${home}" ] && [ -d "${home}" ]; then
    "${SUDO[@]}" mkdir -p "${FICUS_ARCHIVE_DIR}"
    prune_box_archives
    local epoch archive parent base
    epoch="$(date -u +%s)"
    archive="${FICUS_ARCHIVE_DIR}/${UNIX_USER}-${epoch}.tar.gz"
    parent="$(dirname "${home}")"
    base="$(basename "${home}")"
    # Archive the WHOLE home (workspace included) before deletion.
    #
    # A FAILED tar leaves a partial (often zero-byte) file behind, and removal
    # is retried — so without cleaning it up, every retry of a box that cannot
    # be removed adds another full-size tarball. See prune_box_archives.
    if ! "${SUDO[@]}" tar czf "${archive}" -C "${parent}" "${base}"; then
      "${SUDO[@]}" rm -f "${archive}"
      echo "box-provision.sh: archive of ${home} FAILED; removed partial ${archive}" >&2
      return 1
    fi
    echo "box-provision.sh: archived ${home} -> ${archive}" >&2
  fi

  "${SUDO[@]}" userdel -r "${UNIX_USER}" >/dev/null 2>&1 ||
    "${SUDO[@]}" userdel -rf "${UNIX_USER}" >/dev/null 2>&1 ||
    "${SUDO[@]}" userdel "${UNIX_USER}"
  echo "box-provision.sh: removed box user ${UNIX_USER}" >&2
}

# Bound /opt/tau/archive before writing another tarball into it.
#
# Removal archives a box's whole home to <user>-<epoch>.tar.gz, "timestamped,
# never overwriting" — and until now NOTHING ever deleted them. On a host with
# ordinary churn that is a slow leak; on a host where removal keeps failing it
# is not slow at all.
#
# What happened: a box's removal started failing, the tenant retried every 60s,
# and each retry re-tarred the same LIVE 549MB home. Three boxes produced 240
# tarballs and 42GB in hours, filled the host to 100%, and then tar itself
# began failing with ENOSPC — which made removal fail, which caused more
# retries. The host could not recover on its own because the thing that needed
# space was the thing consuming it.
#
# Two bounds, both cheap and both applied BEFORE writing:
#   * one tarball per box — older ones are superseded retries or superseded
#     snapshots; the newest is the one worth keeping
#   * an age cap for the rest
#
# Never fatal: this is housekeeping in front of a removal, and a failure to
# prune must not block the removal itself.
prune_box_archives() {
  local keep_days="${FICUS_ARCHIVE_RETENTION_DAYS:-${TAU_ARCHIVE_RETENTION_DAYS:-14}}"
  [ -d "${FICUS_ARCHIVE_DIR}" ] || return 0

  # Supersede: keep only the newest tarball per box.
  local b stamps n
  for b in $("${SUDO[@]}" ls -1 "${FICUS_ARCHIVE_DIR}" 2>/dev/null |
    sed -nE 's/^(box_[0-9a-f]+)-[0-9]+\.tar\.gz$/\1/p' | sort -u); do
    stamps="$("${SUDO[@]}" ls -1 "${FICUS_ARCHIVE_DIR}" 2>/dev/null |
      sed -nE "s/^${b}-([0-9]+)\.tar\.gz\$/\\1/p" | sort -n)"
    n="$(printf '%s\n' "${stamps}" | grep -c . || true)"
    [ "${n}" -le 1 ] && continue
    printf '%s\n' "${stamps}" | head -n "$((n - 1))" | while read -r ts; do
      [ -n "${ts}" ] || continue
      "${SUDO[@]}" rm -f "${FICUS_ARCHIVE_DIR}/${b}-${ts}.tar.gz" || true
    done
  done

  # Age cap for whatever survives the supersede pass.
  "${SUDO[@]}" find "${FICUS_ARCHIVE_DIR}" -maxdepth 1 -name 'box_*.tar.gz' \
    -mtime "+${keep_days}" -delete 2>/dev/null || true
  return 0
}

# tar's flag for the selected --codec. The SAME mapping box-manager uses to
# WRITE on the source, so read and write can never disagree.
tar_codec_flag() {
  if [ "${CODEC}" = "zstd" ]; then
    printf '%s' '--zstd'
  else
    printf '%s' '-z'
  fi
}

# Re-own + lock a restored box HOME. Extraction runs as ROOT and keeps the
# ARCHIVED (source-side) ownership, so every restored tree must be handed back
# to the box user — a squad box whose ~/workspace stayed root-owned would be
# unwritable (a functionally dead box). Modes mirror ensure_dirs: ~/workspace
# 0755, every private tree 0700.
#
# Shared by BOTH restore modes (--restore reads its members from the tar,
# --restore-stream is told them, since a stream can only be read once) so the
# streamed path can never drift from the file path's ownership guarantee.
#
# $1 = home; remaining args = member names (each arg may itself be a
# newline-separated list, which is how --restore passes its `tar tzf` output).
reown_members() {
  local home="$1"
  shift
  # Tolerate an EMPTY archive (no members): make sure ~/.private exists and is
  # locked so restore never fails a box that had nothing to restore.
  "${SUDO[@]}" install -d "${home}/.private"
  local members m
  members="$(printf '%s\n' "$@" .private | grep -v '^$' | sort -u)"
  for m in ${members}; do
    # Only touch members that actually landed under HOME (defense-in-depth
    # against a member name that resolves elsewhere; extraction already confines
    # to `-C ${home}`).
    [ -e "${home}/${m}" ] || continue
    "${SUDO[@]}" chown -R "${UNIX_USER}:${UNIX_USER}" "${home}/${m}"
    if [ "${m}" = "workspace" ]; then
      "${SUDO[@]}" chmod 755 "${home}/${m}"
    else
      "${SUDO[@]}" chmod 700 "${home}/${m}"
    fi
  done
  printf '%s' "${members//$'\n'/ }"
}

restore_stream() {
  # SAFETY: this extracts + `chown -R`s inside a user's HOME as root — the same
  # guard --restore carries, for the same reason.
  if [[ ! "${UNIX_USER}" =~ ^box_[0-9a-f]{12}$ ]]; then
    echo "box-provision.sh: refusing to restore into non-box user '${UNIX_USER}' (must match box_<12hex>)" >&2
    exit 2
  fi

  if ! id -u "${UNIX_USER}" >/dev/null 2>&1; then
    echo "box-provision.sh: user ${UNIX_USER} does not exist; cannot restore" >&2
    exit 1
  fi

  local home
  home="$(user_home)"
  if [ -z "${home}" ] || [ ! -d "${home}" ]; then
    echo "box-provision.sh: could not resolve home for ${UNIX_USER}" >&2
    exit 1
  fi

  if [[ ! "${STAGING_ID}" =~ ^[0-9a-f-]{36}$ ]]; then
    echo "box-provision.sh: --restore-stream requires a UUID --staging-id" >&2
    exit 2
  fi
  local staging="${home}/.tau-migrate/${STAGING_ID}"
  "${SUDO[@]}" rm -rf -- "${staging}"
  "${SUDO[@]}" install -d -m 0700 -o "${UNIX_USER}" -g "${UNIX_USER}" "${staging}"

  # The tar arrives on STDIN and extracts into fresh operation staging.
  #
  # Fail-closed: a stream truncated ANYWHERE fails the decompressor, tar exits
  # non-zero, and `set -e` propagates that to the caller (which aborts the
  # migration with the SOURCE box still fully intact). Nothing below this line
  # runs on a failed extraction.
  "${SUDO[@]}" tar -x "$(tar_codec_flag)" --no-same-owner --no-overwrite-dir -f - -C "${staging}"

  # Unquoted on purpose: STATE_DIRS is a space-separated list, and arg
  # validation has already proved it non-empty and made every entry a plain path
  # segment. Non-emptiness is load-bearing HERE: with an empty list this would
  # re-own only `.private` (reown_members' fallback) and still exit 0, leaving a
  # streamed ~/workspace root-owned on a box that reports success.
  local members
  members="$(reown_members "${staging}" ${STATE_DIRS})"
  echo "box-provision.sh: restored streamed archive -> staging (codec ${CODEC}, members ${members})" >&2
}

restore_box() {
  # SAFETY: restore extracts + `chown -R`s inside a user's HOME as root. Like
  # removal, only ever act on `box_<12 hex>` users this tooling created (this
  # refuses `root`, `ubuntu`, and any other host account that passes the
  # general provisioning charset). Checked before any privileged call.
  if [[ ! "${UNIX_USER}" =~ ^box_[0-9a-f]{12}$ ]]; then
    echo "box-provision.sh: refusing to restore into non-box user '${UNIX_USER}' (must match box_<12hex>)" >&2
    exit 2
  fi

  if [ -z "${RESTORE_TAR}" ]; then
    echo "box-provision.sh: --restore requires a tar path" >&2
    exit 2
  fi

  # A missing/empty tar is a successful no-op: the pull side emits an EMPTY
  # archive for a box that never had ~/.private, so there is nothing to restore.
  if [ ! -s "${RESTORE_TAR}" ]; then
    echo "box-provision.sh: restore tar '${RESTORE_TAR}' is absent or empty; nothing to restore" >&2
    return 0
  fi

  if ! id -u "${UNIX_USER}" >/dev/null 2>&1; then
    echo "box-provision.sh: user ${UNIX_USER} does not exist; cannot restore" >&2
    exit 1
  fi

  local home
  home="$(user_home)"
  if [ -z "${home}" ] || [ ! -d "${home}" ]; then
    echo "box-provision.sh: could not resolve home for ${UNIX_USER}" >&2
    exit 1
  fi

  # The tar's top members are the box's state dirs (box-manager's pull creates
  # it via `tar czf - -C <home> <dir>...`): `.private` for agent/system-manager
  # boxes, and `workspace` alongside `.private` for a SQUAD box (its
  # authoritative working tree). They extract straight into the HOME;
  # overwrite-in-place keeps this idempotent.
  "${SUDO[@]}" tar xzf "${RESTORE_TAR}" -C "${home}"

  # Re-own EVERY top-level member the archive carried (see reown_members). Read
  # the members from the tar itself rather than assuming `.private`, so a squad
  # ~/workspace is never left root-owned.
  local members
  members="$("${SUDO[@]}" tar tzf "${RESTORE_TAR}" 2>/dev/null | sed 's#/.*##' | grep -v '^$' | sort -u)"
  members="$(reown_members "${home}" "${members}")"
  echo "box-provision.sh: restored ${RESTORE_TAR} -> ${home} (${members})" >&2
}

ensure_user() {
  if ! id -u "${UNIX_USER}" >/dev/null 2>&1; then
    "${SUDO[@]}" useradd --create-home --shell /bin/bash "${UNIX_USER}"
  fi
  # Join the box user to the tau-browser group so it can reach the 0660
  # /run/tau-browser/sock (Phase 2). Fail-open: a machine provisioned before
  # the browser service exists has no tau-browser group yet — that must not
  # fail provisioning, only skip the membership (no browser calls until the
  # box is recreated on a browser-capable machine).
  if getent group tau-browser >/dev/null 2>&1; then
    "${SUDO[@]}" usermod -aG tau-browser "${UNIX_USER}"
  else
    echo "box-provision.sh: tau-browser group not found; skipping browser group membership (pre-browser machine)" >&2
  fi
}

# Only the dedicated, pristine machine prewarmer may populate this store.
# Ordinary boxes READ shared objects via Git alternates; their fetcher SQLite
# databases, credentials, custom sources and new objects remain private.
NIX_CACHE_ROOT="/opt/tau/cache/nix"

init_shared_nix_cache() (
  umask 022
  local name
  "${SUDO[@]}" install -d -o root -g root -m 0755 "${NIX_CACHE_ROOT}"
  for name in tarball-cache tarball-cache-v2; do
    "${SUDO[@]}" git -c init.defaultBranch=main init --bare --quiet "${NIX_CACHE_ROOT}/${name}"
    "${SUDO[@]}" chmod 0755 "${NIX_CACHE_ROOT}/${name}" "${NIX_CACHE_ROOT}/${name}/objects"
  done
)

# Runs entirely AS THE BOX USER, including directory creation and atomic
# alternate updates. Never traverse an agent-controlled path as root.
attach_nix_cache() (
  set -euo pipefail
  local cache="$1" shared="$2" alternate temp
  [ -d "${shared}/objects" ] || exit 0
  if [ ! -e "${cache}/HEAD" ]; then
    git -c init.defaultBranch=main init --bare --quiet "${cache}"
  fi
  mkdir -p "${cache}/objects/info"
  exec 9>"${cache}/objects/info/.tau-shared.lock"
  flock -w 1 9 || exit 0
  alternate="${cache}/objects/info/alternates"
  if ! grep -Fxq "${shared}/objects" "${alternate}" 2>/dev/null; then
    temp="$(mktemp "${alternate}.XXXXXX")"
    trap 'rm -f "${temp:-}"' EXIT
    if [ -f "${alternate}" ]; then cat "${alternate}" >"${temp}"; fi
    printf '\n%s\n' "${shared}/objects" >>"${temp}"
    mv -f "${temp}" "${alternate}"
  fi
  # prune-packed removes ONLY loose duplicates already readable from a pack
  # (including alternates). Never gc/prune: Nix stores roots in SQLite, not refs.
  # Nix can recreate loose objects even with alternates attached. Recheck on
  # every start and after seeding, including when the shared pack is unchanged.
  # Bound work; an interrupted pass safely retries on the next invocation.
  timeout 5s nice -n 19 git --git-dir="${cache}" prune-packed || exit 0
)

prepare_nix_cache() {
  local home name
  home="$(user_home)"
  [ -n "${home}" ] || return 1
  # ExecStartPre runs unprivileged. Operator invocations drop privileges too,
  # so poisoned cache paths cannot escape the box UID.
  if [ "$(id -un)" != "${UNIX_USER}" ]; then
    run_as_box bash /opt/tau/bin/box-provision.sh --unix-user "${UNIX_USER}" --prepare-nix-cache
    return
  fi
  for name in tarball-cache tarball-cache-v2; do
    attach_nix_cache "${home}/.cache/nix/${name}" "${NIX_CACHE_ROOT}/${name}"
  done
}

publish_nix_cache() (
  set -euo pipefail
  # The caller is the Core prewarm path, never a normal/customized agent box.
  if [[ ! "${SANDBOX_ID}" =~ ^devbox-prewarm-(squad|agent)-[a-zA-Z0-9-]+$ ]]; then
    echo 'box-provision.sh: only a dedicated devbox prewarm may publish Nix objects' >&2
    exit 2
  fi
  local expected home name shared cache staging pack
  expected="box_$(printf '%s' "${SANDBOX_ID}" | sha256sum | cut -c1-12)"
  [ "${UNIX_USER}" = "${expected}" ] || exit 2
  # Publication is root-only; the box users never get write permission here.
  [ "$(id -u)" -eq 0 ] || exit 2
  init_shared_nix_cache
  home="$(user_home)"
  exec 8>"${NIX_CACHE_ROOT}/.publish.lock"
  flock -w 120 8
  staging="$(mktemp -d "${NIX_CACHE_ROOT}/.publish.XXXXXX")"
  trap 'rm -rf "${staging}"' EXIT
  for name in tarball-cache tarball-cache-v2; do
    cache="${home}/.cache/nix/${name}"
    shared="${NIX_CACHE_ROOT}/${name}"
    [ -d "${cache}/objects" ] || continue
    # Run all reads of the prewarmer's repository AS that user. Git object IDs
    # include content hashes; index-pack --strict verifies the incoming pack.
    run_as_box git --git-dir="${cache}" cat-file --batch-all-objects --batch-check='%(objectname)' | LC_ALL=C sort -u >"${staging}/source"
    git --git-dir="${shared}" cat-file --batch-all-objects --batch-check='%(objectname)' | LC_ALL=C sort -u >"${staging}/shared"
    LC_ALL=C comm -23 "${staging}/source" "${staging}/shared" >"${staging}/new"
    [ -s "${staging}/new" ] || continue
    run_as_box nice -n 19 git --git-dir="${cache}" pack-objects --stdout --threads=1 --window=0 <"${staging}/new" \
      | git --git-dir="${shared}" index-pack --stdin --strict >"${staging}/result"
    pack="$(awk '{print $2}' "${staging}/result")"
    [[ "${pack}" =~ ^[0-9a-f]{40}$ ]] || exit 1
    chmod 0444 "${shared}/objects/pack/pack-${pack}.pack" "${shared}/objects/pack/pack-${pack}.idx"
  done
)

ensure_dirs() {
  local home="$1"
  # The HOME itself is 0700: Ubuntu useradd leaves 0755 (via /etc/login.defs
  # HOME_MODE not being set), which would let every co-located box user on the
  # shared machine read this box's ~/memory, ~/.tau/skills, ~/bin, ... —
  # cross-tenant data exposure. chmod (not install -d) so re-provisioning an
  # EXISTING box tightens it too; idempotent by nature.
  "${SUDO[@]}" chmod 700 "${home}"
  # ~/.private (0700) private scratch, ~/.tau (0700) holds server.env secrets,
  # ~/workspace the box's working tree.
  "${SUDO[@]}" install -d -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0700 "${home}/.private"
  "${SUDO[@]}" install -d -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0700 "${home}/.tau"
  "${SUDO[@]}" install -d -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0755 "${home}/workspace"
}

# The unit file body for --unit-mode, printed to stdout ($1 = the box HOME).
# PURE: no privilege, no writes — install_unit pipes it, the --print-units dry
# run prints it, so what tests assert is byte-for-byte what a machine receives.
#
# EnvironmentFile is prefixed with `-` so the unit is valid (and can be
# enabled/started) even before the slice-2 manager pushes server.env or the
# server bundle. The server binds EXECUTOR_PORT, which the manager writes into
# server.env (box-manager `derivedBoxEnv`) BEFORE the first unit restart, so the
# real listen port always comes from there. FICUS_BOX_PORT is never read as a
# port (kept range-validated above only so the unit always carries a concrete,
# injection-safe value) — but the server DOES read its presence as the
# VM-runtime marker for the fail-closed gate: because it is baked into the
# unit itself, a unit activated before server.env lands still identifies as a
# VM boot, sees no EXECUTOR_AUTH_TOKEN, and exits instead of serving
# unauthenticated (packages/k8s-sandbox/src/server.ts). host.env is listed
# FIRST so anything Core pushes in server.env still wins.
#
# The service-cgroup ownership marker rides ExecStart, NOT Environment=:
# systemd applies EnvironmentFile= content OVER Environment= values regardless
# of unit order (systemd.exec(5)), so a configurable host.env/server.env value
# for EXECUTOR_SERVICE_CGROUP could silently disable the server's residual-
# child census while KillMode=control-group still kills those children at
# service exit. argv belongs to this root-installed unit, so the
# `--service-cgroup` switch is the one channel those files cannot override.
#
# The system unit spells the HOME out instead of using `%h`: in a SYSTEM unit
# `%h` resolves against the service manager (root), NOT against `User=`, so
# `%h/.tau/server.env` would silently read /root's files and the box would boot
# without its env. The user unit keeps `%h` byte-for-byte as it always was.
render_unit() {
  local home="$1"
  local -a unit
  if [ "${UNIT_MODE}" = "system" ]; then
    unit=(
      '[Unit]'
      'Description=tau sandbox server'
      'After=network-online.target'
      'Wants=network-online.target'
      ''
      '[Service]'
      'Type=simple'
      "User=${UNIX_USER}"
      "Group=${UNIX_USER}"
      "WorkingDirectory=${home}"
      "RuntimeDirectory=$(runtime_dir_name)"
      "Environment=FICUS_BOX_PORT=${PORT}"
      'Environment=FICUS_BROWSER_SOCK=/run/tau-browser/sock'
      "Environment=EXECUTOR_SOCKET=$(box_socket_file)"
      "Environment=EXECUTOR_IDLE_EXIT_MS=${IDLE_EXIT_MS}"
      "EnvironmentFile=-${home}/.tau/host.env"
      "EnvironmentFile=-${home}/.tau/server.env"
      "ExecStartPre=-/bin/bash /opt/tau/bin/box-provision.sh --unix-user ${UNIX_USER} --prepare-nix-cache"
      "ExecStart=/opt/tau/bin/bun /opt/tau/server/server.js --service-cgroup"
      'Delegate=no'
      'ExitType=main'
      'KillMode=control-group'
      'Restart=on-failure'
      'RestartSec=2'
      "Slice=$(system_slice_name)"
      ''
      '[Install]'
      'WantedBy=multi-user.target'
    )
  else
    unit=(
      '[Unit]'
      'Description=tau sandbox server'
      'After=network-online.target'
      'Wants=network-online.target'
      ''
      '[Service]'
      'Type=simple'
      "RuntimeDirectory=$(runtime_dir_name)"
      "Environment=FICUS_BOX_PORT=${PORT}"
      'Environment=FICUS_BROWSER_SOCK=/run/tau-browser/sock'
      "Environment=EXECUTOR_SOCKET=$(box_socket_file)"
      "Environment=EXECUTOR_IDLE_EXIT_MS=${IDLE_EXIT_MS}"
      'EnvironmentFile=-%h/.tau/host.env'
      'EnvironmentFile=-%h/.tau/server.env'
      "ExecStartPre=-/bin/bash /opt/tau/bin/box-provision.sh --unix-user ${UNIX_USER} --prepare-nix-cache"
      'ExecStart=/opt/tau/bin/bun /opt/tau/server/server.js --service-cgroup'
      'Delegate=no'
      'ExitType=main'
      'KillMode=control-group'
      'Restart=on-failure'
      'RestartSec=2'
      ''
      '[Install]'
      'WantedBy=default.target'
    )
  fi
  printf '%s\n' "${unit[@]}"
}

# The SOCKET unit: the only thing that is always "on". It owns the box's
# 127.0.0.1:<port> forever (so Core's tunnel forward always finds a listener,
# whether or not a server process exists) and activates the PROXY — hence the
# explicit `Service=`, since the socket's name does not match the proxy's.
# PURE, like render_unit.
render_socket_unit() {
  printf '%s\n' \
    '[Unit]' \
    'Description=tau sandbox server socket' \
    '' \
    '[Socket]' \
    "ListenStream=127.0.0.1:${PORT}" \
    'NoDelay=true' \
    "Service=$(proxy_name)" \
    '' \
    '[Install]' \
    'WantedBy=sockets.target'
}

# The PROXY unit: socket-activated, forwards the accepted TCP connection to the
# server's unix socket, and exits after 30s idle. Its idle time is deliberately
# far SHORTER than the server's (10 min), so a live proxy never fronts a server
# that has already gone away. `Requires=`+`After=` on the server unit is what
# brings the server back on the first connection after an idle exit.
# PURE, like render_unit.
render_proxy_unit() {
  local sock
  sock="$(box_socket_file)"
  local -a unit
  unit=(
    '[Unit]'
    'Description=tau sandbox server socket proxy'
    "Requires=$(unit_name)"
    "After=$(unit_name)"
    ''
    '[Service]'
    'Type=simple'
  )
  # A system-mode proxy must run AS the box user to reach a socket the box user
  # owns; a user-mode proxy already does, by living in that user's manager.
  if [ "${UNIT_MODE}" = "system" ]; then
    unit+=("User=${UNIX_USER}" "Group=${UNIX_USER}")
  fi
  unit+=(
    'PrivateTmp=no'
    "ExecStartPre=$(proxy_wait_command "${sock}")"
    "ExecStart=${SOCKET_PROXYD} --exit-idle-time=30s ${sock}"
  )
  printf '%s\n' "${unit[@]}"
}

# Install all THREE units (server, socket, proxy) for this --unit-mode.
install_unit() {
  local home="$1"

  if [ "${UNIT_MODE}" = "system" ]; then
    # Root-owned 0644 under /etc/systemd/system: the box user must not be able
    # to rewrite the units that run as it.
    render_unit "${home}" \
      | "${SUDO[@]}" install -o root -g root -m 0644 /dev/stdin "$(unit_path "${home}")"
    render_socket_unit \
      | "${SUDO[@]}" install -o root -g root -m 0644 /dev/stdin "$(socket_path "${home}")"
    render_proxy_unit \
      | "${SUDO[@]}" install -o root -g root -m 0644 /dev/stdin "$(proxy_path "${home}")"
    return
  fi

  "${SUDO[@]}" install -d -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0700 "${home}/.config"
  "${SUDO[@]}" install -d -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0700 "${home}/.config/systemd"
  "${SUDO[@]}" install -d -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0700 "$(dirname "$(unit_path "${home}")")"
  render_unit "${home}" \
    | "${SUDO[@]}" install -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0644 /dev/stdin "$(unit_path "${home}")"
  render_socket_unit \
    | "${SUDO[@]}" install -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0644 /dev/stdin "$(socket_path "${home}")"
  render_proxy_unit \
    | "${SUDO[@]}" install -o "${UNIX_USER}" -g "${UNIX_USER}" -m 0644 /dev/stdin "$(proxy_path "${home}")"
}

# The socket layout is not optional: without systemd-socket-proxyd the socket
# would own the box's port and activate a proxy that cannot start, so every
# request to the box would hang. Refuse loudly instead of silently falling back
# to the old single-unit layout (spec: "never silently installs the old layout").
assert_socket_proxyd() {
  if [ ! -x "${SOCKET_PROXYD}" ]; then
    echo "box-provision.sh: ${SOCKET_PROXYD} is missing; this machine image is too old for socket-activated boxes" >&2
    exit 1
  fi
}

# Converge a box that was provisioned under the OTHER unit mode. Detection is by
# WHAT EXISTS ON DISK, never by a flag: whichever caller re-provisions the box
# next (a spec-hash drift re-provision, a migrate, an operator run) must be able
# to see the stale layout without being told about it.
#
# Leaving user mode also KILLS the old user manager (disable-linger +
# terminate-user) before the new system unit is installed: the outgoing
# tau-sandbox-server still holds FICUS_BOX_PORT, and the incoming unit binds the
# same port. Belt-and-braces — the caller starts the unit only after this
# returns — but a lingering manager would otherwise survive indefinitely.
reconcile_unit_mode() {
  local home="$1"
  if [ "${UNIT_MODE}" = "system" ]; then
    local old_unit
    old_unit="$(user_unit_path "${home}")"
    if "${SUDO[@]}" test -e "${old_unit}" || "${SUDO[@]}" test -e "/var/lib/systemd/linger/${UNIX_USER}"; then
      echo "box-provision.sh: converting ${UNIX_USER} from the user unit to the system unit" >&2
      sysu stop "${USER_SOCKET_NAME}" "${USER_PROXY_NAME}" "${USER_UNIT_NAME}" >/dev/null 2>&1 || true
      sysu disable "${USER_SOCKET_NAME}" "${USER_UNIT_NAME}" >/dev/null 2>&1 || true
      "${SUDO[@]}" rm -f "${old_unit}" "$(user_socket_path "${home}")" "$(user_proxy_path "${home}")"
      sysu daemon-reload >/dev/null 2>&1 || true
      "${SUDO[@]}" rm -rf "$(user_slice_dropin_dir)"
      "${SUDO[@]}" loginctl disable-linger "${UNIX_USER}" >/dev/null 2>&1 || true
      "${SUDO[@]}" loginctl terminate-user "${UNIX_USER}" >/dev/null 2>&1 || true
      "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  else
    local old_unit
    old_unit="$(system_unit_path)"
    if "${SUDO[@]}" test -e "${old_unit}"; then
      echo "box-provision.sh: converting ${UNIX_USER} from the system unit to the user unit" >&2
      "${SUDO[@]}" systemctl stop "$(system_socket_name)" "$(system_proxy_name)" "$(system_unit_name)" >/dev/null 2>&1 || true
      "${SUDO[@]}" systemctl disable "$(system_socket_name)" "$(system_unit_name)" >/dev/null 2>&1 || true
      "${SUDO[@]}" rm -f "${old_unit}" "$(system_socket_path)" "$(system_proxy_path)"
      "${SUDO[@]}" rm -rf "$(system_slice_dropin_dir)"
      "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
}

provision_box() {
  assert_socket_proxyd
  ensure_user

  local home
  home="$(user_home)"
  if [ -z "${home}" ]; then
    echo "box-provision.sh: could not resolve home for ${UNIX_USER}" >&2
    exit 1
  fi

  # Tear the OTHER mode's layout down first (no-op for a box already in this
  # mode, or a brand-new one), so the two never coexist and the outgoing server
  # can never hold the port the incoming unit binds.
  reconcile_unit_mode "${home}"

  if [ "${UNIT_MODE}" = "user" ]; then
    # Linger keeps the user's systemd manager running with no login session, which
    # is what lets `--machine=<user>@.host --user` reach it and the service persist.
    # System mode deliberately has NO linger: skipping the per-box
    # `systemd --user` + dbus pair is the entire point (~13 MB each).
    "${SUDO[@]}" loginctl enable-linger "${UNIX_USER}"
  fi

  ensure_dirs "${home}"
  init_shared_nix_cache
  install_slice_limits
  write_host_env "${home}"
  install_unit "${home}"

  if [ "${UNIT_MODE}" = "user" ]; then
    # The user manager may take a beat to come up after enable-linger; retry the
    # first reload before enabling.
    for _ in 1 2 3 4 5; do
      if sysu daemon-reload >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  else
    "${SUDO[@]}" systemctl daemon-reload
  fi

  # Only the SOCKET is enabled+started. It costs nothing (a listening fd) and
  # is what makes an idle box reachable with no server process at all: the first
  # connection activates the proxy, which `Requires=` the server.
  #
  # The SERVER unit is explicitly DISABLED. It keeps an `[Install]` section only
  # so this `disable` can find and remove the boot-time symlink a pre-socket
  # provision of this same box left behind — leaving it enabled would start
  # every box's server at host boot and give back exactly the RAM this layout
  # reclaims. Nothing else in the system enables it.
  sysbox disable "$(unit_name)" >/dev/null 2>&1 || true
  sysbox enable --now "$(socket_name)" >/dev/null 2>&1 || true
  # The SERVER is deliberately NOT started here. server.env — which carries the box's
  # EXECUTOR_AUTH_TOKEN and EXECUTOR_BIND=127.0.0.1 — is pushed by box-manager
  # only AFTER this script returns, so a unit started now would boot token-less
  # on 0.0.0.0: an unauthenticated executor any co-located box could drive for
  # the whole provision window (a minute+ for docker roles). The manager's
  # post-env `systemctl restart` (which starts an inactive unit fine) performs
  # the first real activation; nothing in this script needs the unit running.
  # Belt-and-braces: the server itself refuses to start when FICUS_BOX_PORT (baked
  # into this unit below, so present even without server.env) or EXECUTOR_BIND
  # is set without EXECUTOR_AUTH_TOKEN (packages/k8s-sandbox/src/server.ts), so
  # even a stray pre-env start fails closed instead of serving.

  # Per-box rootless docker (squad + system-manager); agent light boxes skip it.
  if [ "${WITH_DOCKER}" = true ]; then
    provision_docker
  fi

  echo "box-provision.sh: provisioned box ${UNIX_USER} (sandbox ${SANDBOX_ID}, port ${PORT}, unit-mode ${UNIT_MODE}, docker ${WITH_DOCKER})" >&2

  # Sole stdout line: the box user's useradd-assigned UID, so box-manager can bake
  # DOCKER_HOST=unix:///run/user/<uid>/docker.sock. Everything else went to stderr.
  printf 'FICUS_BOX_UID=%s\n' "$(box_uid)"
}

FICUS_ARCHIVE_DIR="/opt/tau/archive"

# Side-effect-free dry run (tests): print the three unit files this invocation
# would install (server, socket, proxy), each prefixed with a `# path: <path>`
# header, and exit. Dispatched HERE —
# after every function it calls is DEFINED, and after argument validation, so
# the printed unit is exactly what a real provision would write (an earlier
# dispatch, next to --print-slice-limits, would call render_unit/unit_path
# before bash has read them). Reads nothing and writes nothing: the HOME is the
# `useradd --create-home` default (matching box-paths.ts's boxHomeForUser)
# rather than a getent lookup, so it works for a user that does not exist.
if [ "${PRINT_UNITS}" = true ]; then
  PRINT_HOME="/home/${UNIX_USER}"
  printf '# path: %s\n' "$(unit_path "${PRINT_HOME}")"
  render_unit "${PRINT_HOME}"
  printf '# path: %s\n' "$(socket_path "${PRINT_HOME}")"
  render_socket_unit
  printf '# path: %s\n' "$(proxy_path "${PRINT_HOME}")"
  render_proxy_unit
  exit 0
fi

if [ "${PREPARE_NIX_CACHE}" = true ]; then
  prepare_nix_cache
elif [ "${PUBLISH_NIX_CACHE}" = true ]; then
  publish_nix_cache
elif [ "${REMOVE}" = true ]; then
  remove_box
elif [ "${RESTORE}" = true ]; then
  restore_box
elif [ "${RESTORE_STREAM}" = true ]; then
  restore_stream
else
  provision_box
fi
