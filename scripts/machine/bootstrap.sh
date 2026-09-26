#!/usr/bin/env bash
#
# tau machine bootstrap
# =====================
# Prepares a VM host to run tau VM-based sandbox "boxes" (per-sandbox unix users
# managed by box-provision.sh, which this script installs into /opt/tau/bin).
#
# Target OS : Ubuntu 24.04 LTS ONLY (systemd 255, bash 5.2). Other distros are
#             out of scope for this slice and untested.
# Privilege : must run as root, or as a passwordless sudoer (the SSH admin user).
# Idempotent: safe to re-run — every step checks-then-acts, so a drift
#             re-bootstrap (same or newer --version) converges without error.
# No secrets: this script embeds NO credentials. Config/secrets arrive later via
#             each box's ~/.tau/server.env (pushed by the slice-2 manager).
# Invocation: works both when streamed + run over SSH (bootstrapMachine in
#             apps/core/src/services/machines/bootstrap.ts) and as a cloud-init
#             `runcmd` payload.
#
# Usage:
#   bootstrap.sh --version <hash> [--egress-lockdown] [--core-cidr <cidr>]...
#
# --version         opaque bootstrap version (sha256 of this file, computed by
#                   the caller) recorded in /opt/tau/manifest.json.
# --egress-lockdown install nftables egress rules (default OFF this slice). The
#                   rules mirror k8s/network-policy.yaml: allow DNS + the public
#                   internet + any --core-cidr, drop RFC1918 / link-local /
#                   cloud-metadata / other special-use ranges.
# --core-cidr       (repeatable) a CIDR allowed through the egress lockdown even
#                   though it may fall inside a dropped private range — the tau
#                   Core endpoint the box must reach.
#
# Final line on stdout is exactly one machine-readable capabilities marker:
#   FICUS_CAPS_JSON: {"arch":...,"cpus":...,"memMb":...,"diskGb":...,"kernel":...,"docker":"rootless","forwarding":"yes","browser":"available"}
# `browser` is "available" once verify_browser confirms Chromium's sandbox is ON
# and the tau-browser service is live, else "unavailable" with a "browserReason"
# token: install/setup — playwright_install_failed / chromium_download_failed /
# user_setup_failed / setup_failed / install_failed; runtime — apparmor_parser_missing
# / apparmor_load_failed / sandbox_check_failed / service_start_failed /
# service_inactive. An unavailable browser NEVER fails bootstrap — the machine
# still comes up; only browsing is off (never --no-sandbox).
# `docker` is "rootless" once the engine + rootless launcher are installed (this
# script installs them), else "none".
# All other (noisy) output is routed to stderr so that line stands alone.

set -euo pipefail

# Pinned bun: the repo has no .bun-version / package.json engines pin, so this
# tracks current stable. Bump deliberately (it changes the bootstrap hash).
BUN_VERSION="1.2.23"

# Pinned nix + devbox toolchain — what box users need for `devbox install`
# (per-box comfort-set seeding, apps/core devbox-seed.ts). DEVBOX_VERSION tracks
# the devbox.json schema pin in devbox-seed.ts. Bump deliberately (each bump
# changes the bootstrap hash → re-bootstrap).
#
# CAVEAT on bumping NIX_VERSION: install_nix's idempotency is a MARKER SKIP (it
# no-ops when the installed nix already matches the pin). It is NOT an upgrade
# path — the official installer REFUSES to run over an existing /nix ("refusing
# to install because /nix already exists"). So on a host already bootstrapped at
# an older nix, a bare version bump makes install_nix re-run the installer, which
# then errors out; a real bump needs an explicit upgrade step (e.g. `nix upgrade-
# nix`, or tearing down /nix first). Treat a NIX_VERSION change as such.
NIX_VERSION="2.24.9"
DEVBOX_VERSION="0.14.0"

# Pinned Playwright for the shared per-machine browser service (install_browser,
# browser-tools-in-sandbox spec §4.1). MUST equal apps/core's `playwright`
# dependency (currently ^1.58.2 → 1.58.2) so the machine's Chromium matches the
# Playwright the core tools drive it with, and MUST stay in lockstep with the
# PLAYWRIGHT_VERSION ARG in packages/machine-image/Dockerfile and
# apps/core/docker-sandbox/Dockerfile (asserted by bootstrap.test.ts). Bump
# deliberately — it changes the bootstrap hash → re-bootstrap.
PLAYWRIGHT_VERSION="1.58.2"
# Upper bound on each Chromium download + extract attempt. A healthy run takes
# under a minute; Playwright's out-of-process extractor intermittently stalls
# forever mid-extract under the pinned bun (5 of 9 runs on an arm64 Ubuntu 24.04
# VM), which would otherwise hold bootstrap until Core's 15-minute SSH deadline
# and mark the whole machine unreachable. The stall is not sticky, so a stalled
# attempt is retried once; the worst case stays at 10 minutes.
BROWSER_DOWNLOAD_TIMEOUT_SECS=300
BROWSER_DOWNLOAD_ATTEMPTS=2

FICUS_ROOT="/opt/tau"
BUN_INSTALL_DIR="${FICUS_ROOT}/bun"      # official installer target (dispatcher: "install to /opt/tau/bun")
BUN_BIN_LINK="${FICUS_ROOT}/bin/bun"     # stable invocation path used by box-provision's unit

# Prebaked-image marker (packages/machine-image/Dockerfile writes it as
# {"bunVersion","nixVersion","devboxVersion"}). Present ONLY on a VM booted from
# the ficus-machine image, where bun/nix/devbox/apt prereqs are already baked. Its
# PRESENCE (regardless of the exact baked versions) is the source of truth that
# the tooling is baked: main() then SKIPS every install step and uses the baked
# tooling. This is deliberately NOT gated on a version match — a prebaked image
# is NEVER reinstalled over at boot (install_nix would brick on an existing /nix,
# see below), so changing a pinned version is done by REBAKING the image, not by
# a boot-time reinstall. A drift between the baked pins and the script's pins only
# logs a WARNING (log_prebaked_decision). Absent on a BYO-SSH bare Ubuntu host
# (full install path). Overridable via --marker-file for the
# --print-prebaked-decision dry run ONLY.
PREBAKED_MARKER="${FICUS_ROOT}/prebaked"

# Multi-user nix lays its default profile here; the `nix` binary lives under it.
# devbox lands on the standard system PATH so every box user can invoke it.
NIX_PROFILE_BIN="/nix/var/nix/profiles/default/bin"
NIX_BIN="${NIX_PROFILE_BIN}/nix"
DEVBOX_BIN="/usr/local/bin/devbox"

# Shared per-machine browser service layout (install_browser). ONE Chromium per
# machine, root-owned + world-readable under /opt/tau/browser, driven by the
# unprivileged `tau-browser` system user over a group-restricted unix socket.
# See the browser-tools-in-sandbox spec §4.1/§4.2. install_browser installs the
# packages + the sandbox hard gate + the real service (per-box BrowserContext,
# token auth, caps — write_browser_service).
FICUS_BROWSER_USER="tau-browser"
FICUS_BROWSER_ROOT="${FICUS_ROOT}/browser"
FICUS_BROWSER_HOME="${FICUS_BROWSER_ROOT}/home"            # writable HOME for the service user
FICUS_BROWSER_BROWSERS_PATH="${FICUS_BROWSER_ROOT}/ms-playwright"  # PLAYWRIGHT_BROWSERS_PATH
FICUS_BROWSER_SERVICE_JS="${FICUS_BROWSER_ROOT}/service/tau-browser.js"
FICUS_BROWSER_VERIFY_JS="${FICUS_BROWSER_ROOT}/service/verify-sandbox.js"
# The socket path (/run/tau-browser/sock, 0660 group tau-browser) is fixed in the
# static unit + service program, not a shell constant.
FICUS_BROWSER_UNIT="/etc/systemd/system/tau-browser.service"
FICUS_BROWSER_APPARMOR="/etc/apparmor.d/tau-browser-chromium"
# Durable, machine-readable availability markers written by verify_browser. On a
# host that CAN run the sandboxed browser: READY (timestamp), UNAVAILABLE removed.
# On a host that CANNOT: UNAVAILABLE (reason token + timestamp + detail), READY
# removed — browsing is disabled but the machine still comes up. These sit next
# to the capabilities.browser field the control plane consumes (a human debugging
# a VM reads them directly).
FICUS_BROWSER_READY_MARKER="${FICUS_BROWSER_ROOT}/READY"
FICUS_BROWSER_UNAVAILABLE_MARKER="${FICUS_BROWSER_ROOT}/UNAVAILABLE"

# Browser availability, reported to the control plane via capabilities.browser
# (print_capabilities). Set by install_browser/verify_browser; global so
# print_capabilities (run after main) sees it. Defaults to unavailable/not_verified
# so a caps line is honest even if neither ran.
#
# INVARIANT: the browser NEVER affects bootstrap's exit code. Every browser step —
# install (bun install / Chromium download / apt deps), setup (user, unit,
# AppArmor, layout), the sandbox verify, and the service start — is fail-open:
# on any failure it marks capabilities.browser=unavailable (durable marker + LOUD
# ERROR log + stopped/disabled unit) and lets bootstrap continue with exit 0. It
# NEVER falls back to --no-sandbox.
BROWSER_STATUS="unavailable"
BROWSER_REASON="not_verified"
# Reason token set by _browser_install_steps on the first failing install/setup
# step; read by install_browser to mark the browser unavailable.
BROWSER_INSTALL_REASON=""

BOOTSTRAP_VERSION=""
EGRESS_LOCKDOWN=false
PRINT_EGRESS_RULESET=false
PRINT_PREBAKED_DECISION=false
CORE_CIDRS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      BOOTSTRAP_VERSION="${2:-}"
      shift 2
      ;;
    --egress-lockdown)
      EGRESS_LOCKDOWN=true
      shift
      ;;
    --core-cidr)
      CORE_CIDRS+=("${2:-}")
      shift 2
      ;;
    --print-egress-ruleset)
      # Side-effect-free dry run: validate --core-cidr(s) then print the exact
      # `table inet tau_egress` ruleset apply_egress_lockdown would load and exit
      # (no apt, no nft, no sudo). Used by tests to assert + `nft -c -f` the rules.
      PRINT_EGRESS_RULESET=true
      shift
      ;;
    --print-prebaked-decision)
      # Side-effect-free dry run: read the prebaked marker (at --marker-file, or
      # the default path), print the install decision main() would take —
      # `skip` (use the baked tooling) when the marker is present, `install`
      # (full BYO path) when it is absent — plus any drift WARNING on stderr, then
      # exit (no apt, no nix, no install). Used by tests to assert the never-brick
      # prebaked semantics without running the real installs.
      PRINT_PREBAKED_DECISION=true
      shift
      ;;
    --marker-file)
      # Override the prebaked-marker path. For the --print-prebaked-decision dry
      # run ONLY (lets tests point at a fixture marker); never passed in production.
      PREBAKED_MARKER="${2:-}"
      shift 2
      ;;
    *)
      echo "bootstrap.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Run privileged commands directly when root, else via sudo. Array form keeps
# expansion shellcheck-clean and correct when empty (bash 4.4+, Ubuntu ships 5.2).
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo)
fi

# Every apt-get in this script waits for the dpkg lock instead of failing on
# it. On a FRESH droplet's first boot, cloud-init and unattended-upgrades run
# their own apt-get and hold /var/lib/dpkg/lock-frontend for a minute or more
# — and the platform's wait-for-SSH probe now gets us onto the box fast
# enough that we reliably arrive while they still do. Seen live (smoke4):
# `E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process
# 1612 (apt-get)` → bootstrap exit 100 → whole provision attempt burned.
# DPkg::Lock::Timeout makes apt block-and-wait up to N seconds (apt >= 2.0;
# Ubuntu 24.04 ships 2.7) rather than exiting 100. 600s comfortably covers a
# slow first-boot unattended-upgrades run while staying far inside
# bootstrap's own wall-clock bound.
#
# The cloud-init wait BELOW is belt to this suspenders: on first boot it
# blocks until cloud-init has finished entirely (including its package
# phase), so we usually never contend at all; the lock timeout then covers
# the one thing cloud-init doesn't serialize — unattended-upgrades kicking
# off on its own timer. `|| true`: a broken/absent cloud-init must not fail
# bootstrap over what is only an optimization.
command -v cloud-init >/dev/null 2>&1 && "${SUDO[@]}" cloud-init status --wait >/dev/null 2>&1 || true
APT_LOCK_WAIT=(-o DPkg::Lock::Timeout=600)

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  "${SUDO[@]}" apt-get "${APT_LOCK_WAIT[@]}" update -y
  # Base toolchain + rootless-container prerequisites (uidmap/slirp4netns/
  # dbus-user-session/fuse-overlayfs). `unzip` is required by the official bun
  # installer (install_bun below unpacks the release with it) and is absent on a
  # truly minimal Ubuntu 24.04 image. `ca-certificates`/`gnupg` are needed to
  # add Docker's apt repo (install_docker_packages).
  "${SUDO[@]}" apt-get "${APT_LOCK_WAIT[@]}" install -y --no-install-recommends \
    git \
    curl \
    unzip \
    tmux \
    jq \
    build-essential \
    ca-certificates \
    gnupg \
    uidmap \
    dbus-user-session \
    slirp4netns \
    fuse-overlayfs
}

make_dirs() {
  # /opt/tau/server and /opt/tau/cli receive core-pushed machine artifacts (the
  # sandbox-server bundle and the tau CLI); the push's `install -D` also creates
  # them, so pre-creating here is belt-and-braces.
  "${SUDO[@]}" mkdir -p "${FICUS_ROOT}/bin" "${FICUS_ROOT}/server" "${FICUS_ROOT}/cli"
}

install_docker_packages() {
  # Install the Docker ENGINE + rootless launcher scripts SYSTEM-WIDE, but run NO
  # shared daemon: on a multi-box VM a single rootful dockerd is root-equivalent
  # for every box user (spec §5). Per-user rootless setup
  # (`dockerd-rootless-setuptool.sh install`) is box-provision.sh's job; bootstrap
  # only lays down the binaries + rootless scripts (dockerd-rootless.sh,
  # dockerd-rootless-setuptool.sh, rootlesskit) that per-box provisioning needs.
  export DEBIAN_FRONTEND=noninteractive

  # Docker's official apt repo (docker-ce-rootless-extras is NOT in Ubuntu's
  # default repos). Idempotent: the keyring + list are overwritten, not appended.
  "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | "${SUDO[@]}" gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  "${SUDO[@]}" chmod a+r /etc/apt/keyrings/docker.gpg

  local arch codename
  arch="$(dpkg --print-architecture)"
  # shellcheck disable=SC1091  # /etc/os-release is a runtime file, not a source input
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "${arch}" "${codename}" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.list >/dev/null

  "${SUDO[@]}" apt-get "${APT_LOCK_WAIT[@]}" update -y
  "${SUDO[@]}" apt-get "${APT_LOCK_WAIT[@]}" install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-ce-rootless-extras

  # Close the root hole: the package enables a rootful system daemon by default.
  # Disable AND mask both the service and its socket so nothing (including
  # socket-activation) ever brings a shared rootful dockerd up. Each box runs its
  # OWN rootless daemon as a systemd --user service instead (box-provision.sh).
  "${SUDO[@]}" systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
  "${SUDO[@]}" systemctl mask docker.service docker.socket >/dev/null 2>&1 || true
}

install_bun() {
  if [ -x "${BUN_INSTALL_DIR}/bin/bun" ]; then
    local current
    current="$("${BUN_INSTALL_DIR}/bin/bun" --version 2>/dev/null || echo "")"
    if [ "${current}" = "${BUN_VERSION}" ]; then
      "${SUDO[@]}" ln -sf "${BUN_INSTALL_DIR}/bin/bun" "${BUN_BIN_LINK}"
      return 0
    fi
  fi
  # Official installer, pinned to an exact tag, into a system-wide location
  # (NOT a user home). It writes ${BUN_INSTALL_DIR}/bin/bun.
  curl -fsSL https://bun.sh/install \
    | "${SUDO[@]}" env "BUN_INSTALL=${BUN_INSTALL_DIR}" bash -s "bun-v${BUN_VERSION}"
  # Stable path referenced by box-provision's systemd unit ExecStart.
  "${SUDO[@]}" ln -sf "${BUN_INSTALL_DIR}/bin/bun" "${BUN_BIN_LINK}"
}

# Put `nix` on the STANDARD system PATH. The multi-user installer only wires nix
# into login shells (its /etc/profile.d entry), but the sandbox-server runs box
# commands in a NON-login shell (bash -c), which never sources that — so devbox
# would not find nix. A symlink on /usr/local/bin fixes it. A non-root box user's
# nix auto-connects to the root nix-daemon socket for store writes (see below).
link_nix_on_path() {
  "${SUDO[@]}" ln -sf "${NIX_BIN}" /usr/local/bin/nix
}

# Install nix in MULTI-USER (daemon) mode. Rationale: one machine hosts MANY
# unprivileged box users, and only the daemon mode (a root-owned /nix/store whose
# writes are mediated over a socket) lets ANY of them realize store paths / run
# `devbox install`. A single-user store is owned by exactly one user and cannot
# serve the others, so it is unusable here. Pinned to an exact release; idempotent
# (skip when the installed nix already matches the pin).
install_nix() {
  if [ -x "${NIX_BIN}" ] && "${NIX_BIN}" --version 2>/dev/null | grep -q "${NIX_VERSION}"; then
    link_nix_on_path
    return 0
  fi
  # Official pinned installer. `--daemon` = multi-user; `--yes` (and the no-tty
  # headless mode this non-interactive ssh/cloud-init run is already in) answers
  # every prompt yes so it never blocks on a read; `--no-channel-add` keeps it
  # lean — devbox pins its own nixpkgs inputs, so a system channel is dead weight.
  curl -fsSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" \
    | "${SUDO[@]}" sh -s -- --daemon --yes --no-channel-add
  link_nix_on_path
}

# Install the pinned devbox RELEASE binary (the exact static artifact the official
# launcher would otherwise fetch at runtime) straight to /usr/local/bin, so it is
# on every box user's PATH with no per-user runtime download or ~/.cache priming.
# Pinned + idempotent (skip when the installed devbox already matches the pin).
install_devbox() {
  if [ -x "${DEVBOX_BIN}" ] && "${DEVBOX_BIN}" version 2>/dev/null | grep -q "${DEVBOX_VERSION}"; then
    return 0
  fi
  # dpkg arch (amd64|arm64) matches the release asset naming exactly.
  local arch asset tmp
  arch="$(dpkg --print-architecture)"
  asset="devbox_${DEVBOX_VERSION}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/jetify-com/devbox/releases/download/${DEVBOX_VERSION}/${asset}" \
    -o "${tmp}/devbox.tar.gz"
  tar -xzf "${tmp}/devbox.tar.gz" -C "${tmp}"
  "${SUDO[@]}" install -m 0755 "${tmp}/devbox" "${DEVBOX_BIN}"
  rm -rf "${tmp}"
}

# ---------------------------------------------------------------------------
# Shared per-machine browser service (browser-tools-in-sandbox spec §4.1).
#
# PHASE 1 scope: install Playwright + Chromium into /opt/tau/browser
# (root-owned, world-readable), create the `tau-browser` system user, and lay
# down the `tau-browser.service` SYSTEM unit + AppArmor profile. The service
# PROGRAM (write_browser_service) is now the real Phase 2 implementation
# (browser-tools-in-sandbox spec §4.2): per-box BrowserContext, token auth,
# caps — see scripts/machine/browser/tau-browser.js for the source of truth.
#
# The Chromium sandbox stays ON (spec §5): the service NEVER passes --no-sandbox.
# verify_browser() (run on every boot in main) confirms the sandbox is enabled;
# if it cannot be, browsing is marked UNAVAILABLE (capabilities.browser + durable
# marker + ERROR log + a stopped/disabled unit) but bootstrap STILL succeeds — an
# un-sandboxable host gets NO browser, never an unsafe one. KEEP IN LOCKSTEP with
# the RUN layer in packages/machine-image/Dockerfile (same pin, layout, user/unit).
# ---------------------------------------------------------------------------

# Write the service program: per-box BrowserContext, token auth, caps
# (browser-tools-in-sandbox spec §4.2). The Chromium sandbox stays ON (no
# --no-sandbox).
write_browser_service() {
  "${SUDO[@]}" tee "${FICUS_BROWSER_SERVICE_JS}" >/dev/null <<'BROWSER_SERVICE_JS'
// @ts-check
// tau-browser.service program — per-box BrowserContext, token auth, caps
// (browser-tools-in-sandbox spec §4.2, Phase 2). Serves a small JSON verb
// protocol over the unix socket: one Playwright BrowserContext per
// authenticated box user, run-id-keyed pages inside it. A box can never
// reach another box's context or pages — identity comes from auth, no verb
// accepts a context identifier.
//
// SINGLE SOURCE OF TRUTH: packages/machine-image/Dockerfile COPYs this file, and
// scripts/machine/bootstrap.sh (write_browser_service) embeds it verbatim
// (it is streamed standalone over SSH and cannot COPY siblings). bootstrap.test.ts
// asserts the two copies stay byte-identical.
import fs from 'node:fs'
import crypto from 'node:crypto'

const SOCK = process.env.FICUS_BROWSER_SOCK || process.env.TAU_BROWSER_SOCK || '/run/tau-browser/sock'
// A SIBLING of /opt/tau/browser, not a child — install_browser recursively
// chown/chmods /opt/tau/browser to root:root + a+rX (every box user must
// read the browser binaries), which would world-expose token digests if they
// lived inside it.
const DEFAULT_TOKENS_DIR = '/opt/tau/browser-tokens'
const DEFAULT_MEMORY_HIGH_MB = 8192

const VIEWPORT = { width: 1280, height: 720 }
const MAX_CONSOLE_ENTRIES = 50
const MAX_PAGES_PER_BOX = 3
const MEMORY_MB_PER_PAGE = 256
const PAGE_IDLE_MS = 10 * 60 * 1000
const CONTEXT_IDLE_MS = 15 * 60 * 1000
const SWEEP_INTERVAL_MS = 60 * 1000

// Also the path-traversal defense for the token filename below.
const BOX_USER_RE = /^box_[0-9a-f]{12}$/

// A box-user name safe to interpolate into a token filename: alphanumerics,
// underscore and hyphen only — no '/', no '.', no NUL — so it can never traverse
// out of tokensDir. box_<hex> already satisfies this; this guard exists for the
// docker-dev escape hatch below (R-B17), whose allowed user is an arbitrary OS
// username and must be filename-safe before it reaches readFileSync.
function isSafeTokenUser(name) {
  return typeof name === 'string' && /^[A-Za-z0-9_-]+$/.test(name)
}

// A fixed-length decoy digest so a missing/invalid token file compares against
// something the same shape as a real sha256 digest (32 bytes) — the timing and
// code path stay identical to a real mismatch, never leaking "no such file" vs
// "wrong token" (R-B8).
const DECOY_DIGEST = crypto.createHash('sha256').update('decoy').digest()

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function errorResponse(status, message) {
  return jsonResponse(status, { error: message })
}

/**
 * @param {number} status
 * @param {string} message
 * @returns {Error & { status: number }}
 */
function httpError(status, message) {
  const err = /** @type {Error & { status: number }} */ (new Error(message))
  err.status = status
  return err
}

function toBase64(data) {
  return (Buffer.isBuffer(data) ? data : Buffer.from(data)).toString('base64')
}

// SSRF guard (R-B9 / R-B14). Blocks host-local, link-local and cloud-metadata
// surfaces — used both by open()'s own check and the per-context route()
// handler below (defense in depth for redirects/iframes/subresources).
// Deliberately conservative: loopback + link-local + metadata names only.
// RFC1918 private ranges are NOT blocked (R-B15) — a box's `bash` already
// reaches them, so blocking only in-browser would be inconsistent.
//
// WHATWG URL normalizes hostnames but keeps IPv6 addresses bracketed
// ('[::1]') and can leave a trailing '.' on FQDNs — both defeated the naive
// string-equality/endsWith checks this replaces (R-B14 proof: [::1],
// [::ffff:127.0.0.1], [::ffff:169.254.169.254], [::], a trailing-dot
// metadata.google.internal., and a trailing-dot localhost. all slipped
// through). This version normalizes first, then checks.

function isBlockedIPv4(h) {
  const m = /^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/.exec(h)
  if (!m) return false
  if (h === '0.0.0.0') return true
  const first = Number(m[1])
  const second = Number(m[2])
  if (first === 127) return true // 127.0.0.0/8 (loopback)
  if (first === 169 && second === 254) return true // 169.254.0.0/16 (incl. the 169.254.169.254 cloud metadata IP)
  return false
}

// Converts a bare "hex:hex" IPv4-in-hex tail (the last 32 bits of an
// IPv4-mapped IPv6 address, e.g. "7f00:1") to dotted-quad. Returns null if
// the tail isn't that shape.
function hexPairToDottedQuad(tail) {
  const m = /^([0-9a-f]{1,4}):([0-9a-f]{1,4})$/i.exec(tail)
  if (!m) return null
  const hi = parseInt(m[1], 16)
  const lo = parseInt(m[2], 16)
  return [(hi >> 8) & 0xff, hi & 0xff, (lo >> 8) & 0xff, lo & 0xff].join('.')
}

function isBlockedIPv6(h) {
  // h is already lowercase with surrounding [ ] stripped.
  if (h === '::1' || h === '::') return true
  // Fully-expanded loopback ("0:0:0:0:0:0:0:1" and zero-padded variants) —
  // WHATWG URL always compresses to "::1", but this stays defensive against
  // any input that reaches isBlockedHost some other way.
  const groups = h.split(':')
  if (groups.length === 8 && groups.slice(0, 7).every((g) => /^0*$/.test(g)) && /^0*1$/.test(groups[7])) {
    return true
  }
  // IPv4-embedding IPv6 prefixes: IPv4-mapped (::ffff:a.b.c.d /
  // ::ffff:HHHH:HHHH), IPv4-translated (::ffff:0:0/96, one extra zero group
  // vs IPv4-mapped), and NAT64 well-known (64:ff9b::/96). Each embeds the
  // target as the low 32 bits, in either dotted-quad or bare hex-pair form —
  // extract and re-classify it as IPv4.
  for (const prefixRe of [/^::ffff:(.+)$/i, /^::ffff:0:(.+)$/i, /^64:ff9b::(.+)$/i]) {
    const m = prefixRe.exec(h)
    if (!m) continue
    const tail = m[1]
    const dotted = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(tail) ? tail : hexPairToDottedQuad(tail)
    if (dotted && isBlockedIPv4(dotted)) return true
  }
  if (/^fe[89ab][0-9a-f]:/.test(h)) return true // fe80::/10 (link-local)
  if (/^f[cd][0-9a-f]{2}:/.test(h)) return true // fc00::/7 (unique-local)
  return false
}

function isBlockedHost(hostname) {
  let h = (hostname || '').toLowerCase()
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1)
  h = h.replace(/\.+$/, '') || h // strip ALL trailing FQDN root dots (guard: never reduce to '')
  if (h === 'localhost' || h === 'metadata' || h === 'metadata.google.internal') return true
  if (h.endsWith('.internal')) return true
  if (h.includes(':')) return isBlockedIPv6(h)
  return isBlockedIPv4(h)
}

// Installed on every BrowserContext (R-B9b). Applies to every request the
// context makes — top-level navigation, redirects, iframes, subresources —
// not just the `open` verb's initial goto, which only validates the URL the
// caller supplied. `blockedHost` is the host predicate in force for this
// service (the built-in one unless createService was given deps.isBlockedHost).
async function routeHandler(route, blockedHost = isBlockedHost) {
  let target
  try {
    target = new URL(route.request().url())
  } catch {
    await route.abort()
    return
  }
  const bad = !/^https?:$/.test(target.protocol) || blockedHost(target.hostname)
  if (bad) {
    await route.abort()
  } else {
    await route.continue()
  }
}

export function createService(deps = {}) {
  const launch =
    deps.launch ||
    (async () => {
      // Dynamic import: the default path is only ever evaluated if a real
      // launch actually happens. Tests always inject a fake `launch`, so the
      // test suite has zero load-time dependency on the `playwright` package
      // being installed (Phase 3 drops it from apps/core entirely).
      const { chromium } = await import('playwright')
      return chromium.launch({ headless: true })
    })
  const now = deps.now || Date.now
  const tokensDir =
    deps.tokensDir || process.env.FICUS_BROWSER_TOKENS_DIR || process.env.TAU_BROWSER_TOKENS_DIR || DEFAULT_TOKENS_DIR
  // Docker-dev-only escape hatch (R-B17): the docker sandbox's box server runs as
  // a plain OS user (root) whose name never matches BOX_USER_RE, so the prod
  // box_<hex> gate would 401 every in-container browser call. When — and ONLY
  // when — FICUS_BROWSER_DEV_ALLOW_USER is set (prod NEVER sets it; the systemd
  // unit does not carry it), also accept a box user equal to it, still
  // constrained by isSafeTokenUser so the token filename can't traverse. With the
  // env unset the auth path is byte-identical to box_<hex>-only.
  const devAllowUser =
    deps.devAllowUser || process.env.FICUS_BROWSER_DEV_ALLOW_USER || process.env.TAU_BROWSER_DEV_ALLOW_USER || ''
  const memoryHighMb =
    deps.memoryHighMb ||
    Number(process.env.FICUS_BROWSER_MEMORY_HIGH_MB || process.env.TAU_BROWSER_MEMORY_HIGH_MB) ||
    DEFAULT_MEMORY_HIGH_MB
  // The SSRF host guard is injectable so an embedder whose browser has no more
  // network reach than the caller already has can turn it off (the host sandbox
  // runtime runs this engine in-process on the user's own machine, where the
  // agent's `bash` already reaches localhost). Unset — every machine host and
  // container — this is the built-in blocklist, unchanged.
  const blockedHost = deps.isBlockedHost || isBlockedHost
  // The disconnect policy is injectable: the host sandbox runtime runs this
  // engine IN-PROCESS inside the long-lived core, where process.exit(1) on a
  // Chrome crash would kill the api/worker. Unset — the systemd unit and the
  // docker box — the production default is unchanged: exit(1), systemd
  // restarts the unit.
  const onDisconnected = deps.onDisconnected || (() => process.exit(1))
  const pageCeiling = Math.max(1, Math.floor(memoryHighMb / MEMORY_MB_PER_PAGE))

  let browser = null
  let browserPromise = null

  // boxUser -> { context, lastUsed, pages: Map<runId, {page, consoleLogs, lastUsed}>, pagePromises: Map<runId, Promise> }
  // Structurally isolated: every lookup below is scoped through this map keyed
  // on the AUTHENTICATED box user — no verb ever accepts or looks up a
  // context/box identifier, so cross-context reach is not expressible.
  const contexts = new Map()
  // In-flight context creations, keyed by boxUser (R-B10 / C2 fix). Closes the
  // TOCTOU window where concurrent requests for the same box would each pass
  // "no existing context" and each call newContext().
  const contextPromises = new Map()

  function totalPages() {
    let n = 0
    for (const ctxEntry of contexts.values()) n += ctxEntry.pages.size
    return n
  }

  // Pages currently being created anywhere on the machine but not yet in any
  // ctxEntry.pages map — counted toward the machine ceiling so concurrent
  // opens can't all pass the same capacity check before any of them finishes
  // creating (R-B10 / proven C2: "498 leaked pages, caps bypassed").
  function totalPending() {
    let n = 0
    for (const ctxEntry of contexts.values()) n += ctxEntry.pagePromises.size
    return n
  }

  function resetState() {
    // Close the OLD browser before dropping our reference — otherwise a
    // transient newPage()/newContext() failure on a still-alive Chromium
    // (renderer crash, "Target closed", allocation failure under memory
    // pressure) leaks the process: every other box's pages silently stop
    // counting toward pageCeiling (contexts.clear()), and the next open()
    // launches a SECOND Chromium in the same cgroup — a MemoryHigh feedback
    // loop where the response to memory pressure doubles memory use.
    const old = browser
    browser = null
    browserPromise = null
    contexts.clear()
    if (old) old.close().catch(() => {})
  }

  async function getBrowser() {
    if (browser) return browser
    if (!browserPromise) {
      browserPromise = Promise.resolve()
        .then(() => launch())
        .then((b) => {
          browser = b
          // Real Chromium exposes `.on`; the plain fakes used by most tests
          // don't. Systemd restarts the unit on crash (Restart=on-failure);
          // every box gets a clean recovery once the service comes back up —
          // an embedder that injected a different onDisconnected policy gets
          // that policy resolved here instead of the exit.
          if (typeof b.on === 'function') {
            b.on('disconnected', onDisconnected)
          }
          return b
        })
        .catch(() => {
          resetState()
          throw httpError(502, 'browser restarted')
        })
    }
    return browserPromise
  }

  // Builds (but does not await here) a fresh context for boxUser. Synchronous
  // up to its first await, and the caller registers the returned promise into
  // contextPromises BEFORE any other code can run — see getOrCreateContext.
  function createContext(boxUser) {
    return (async () => {
      const b = await getBrowser()
      let context
      try {
        context = await b.newContext({ viewport: VIEWPORT, acceptDownloads: false })
        await context.route('**', (route) => routeHandler(route, blockedHost))
      } catch {
        resetState()
        throw httpError(502, 'browser restarted')
      }
      const ctxEntry = { context, lastUsed: now(), pages: new Map(), pagePromises: new Map() }
      contexts.set(boxUser, ctxEntry)
      return ctxEntry
    })()
  }

  async function getOrCreateContext(boxUser) {
    const existing = contexts.get(boxUser)
    if (existing) {
      existing.lastUsed = now()
      return existing
    }
    const inFlight = contextPromises.get(boxUser)
    if (inFlight) return inFlight

    const p = createContext(boxUser)
    contextPromises.set(boxUser, p)
    try {
      return await p
    } finally {
      contextPromises.delete(boxUser)
    }
  }

  // Returns whether a slot was actually freed. Only a REALIZED page
  // (ctxEntry.pages) can be evicted — an in-flight reservation
  // (ctxEntry.pagePromises) isn't a page yet, so during a concurrent burst
  // where every slot is pending, there is nothing to evict (R-B16).
  function evictLruPage(ctxEntry) {
    let lruRunId = null
    let lruTime = Infinity
    for (const [runId, pageEntry] of ctxEntry.pages) {
      if (pageEntry.lastUsed < lruTime) {
        lruTime = pageEntry.lastUsed
        lruRunId = runId
      }
    }
    if (lruRunId === null) return false
    const pageEntry = ctxEntry.pages.get(lruRunId)
    ctxEntry.pages.delete(lruRunId)
    pageEntry.page.close().catch(() => {})
    return true
  }

  // Builds (but does not await here) a fresh page for runId inside ctxEntry.
  // Synchronous up to its first await; the caller registers the returned
  // promise into ctxEntry.pagePromises before any other code can run.
  function createPage(ctxEntry, runId) {
    return (async () => {
      let page
      try {
        page = await ctxEntry.context.newPage()
      } catch {
        resetState()
        throw httpError(502, 'browser restarted')
      }
      const consoleLogs = []
      page.on('console', (msg) => {
        consoleLogs.push({ type: msg.type(), text: msg.text() })
        if (consoleLogs.length > MAX_CONSOLE_ENTRIES) consoleLogs.shift()
      })
      const pageEntry = { page, consoleLogs, lastUsed: now() }
      // The page closing out from under us (crash, external close) drops the
      // tracked entry so it doesn't linger as a phantom slot against the caps.
      page.on('close', () => {
        if (ctxEntry.pages.get(runId) === pageEntry) {
          ctxEntry.pages.delete(runId)
        }
      })
      ctxEntry.pages.set(runId, pageEntry)
      return pageEntry
    })()
  }

  async function openPage(boxUser, runId) {
    const ctxEntry = await getOrCreateContext(boxUser)

    // Everything from here to the pagePromises.set() below runs with NO
    // `await` in between — a single synchronous turn — so concurrent opens
    // for other runIds cannot interleave between the capacity check and the
    // reservation that accounts for it (R-B10 / proven C2).
    const existing = ctxEntry.pages.get(runId)
    if (existing) {
      existing.lastUsed = now()
      return existing
    }
    const inFlight = ctxEntry.pagePromises.get(runId)
    if (inFlight) return inFlight

    const occupied = ctxEntry.pages.size + ctxEntry.pagePromises.size
    if (occupied >= MAX_PAGES_PER_BOX) {
      // A same-box LRU swap nets ZERO change to the machine-wide total (one
      // realized page leaves, one reservation joins), so it never needs the
      // ceiling check below — but if every one of this box's slots is
      // currently in-flight (a concurrent burst), there is nothing realized
      // to swap: reject rather than silently let the box exceed its own cap
      // (R-B16; proven: 10 concurrent opens on one box produced 10 live
      // pages because eviction only ever looked at ctxEntry.pages, which
      // stays empty until each page finishes creating).
      if (!evictLruPage(ctxEntry)) {
        throw httpError(429, `this box already has ${MAX_PAGES_PER_BOX} pages opening, retry shortly`)
      }
    } else if (totalPages() + totalPending() >= pageCeiling) {
      // A genuine net-new page against the machine-wide budget (not an
      // own-box swap, so it can't be absorbed by an eviction above).
      throw httpError(429, 'browser at capacity on this machine, retry shortly')
    }

    const p = createPage(ctxEntry, runId)
    ctxEntry.pagePromises.set(runId, p)
    try {
      return await p
    } finally {
      ctxEntry.pagePromises.delete(runId)
    }
  }

  // The ONLY way any verb reaches a page — scoped to the authenticated box's
  // own context, never any other box's.
  function getPage(boxUser, runId) {
    const ctxEntry = contexts.get(boxUser)
    if (!ctxEntry) return null
    const pageEntry = ctxEntry.pages.get(runId)
    if (!pageEntry) return null
    ctxEntry.lastUsed = now()
    pageEntry.lastUsed = now()
    return pageEntry
  }

  async function closePage(boxUser, runId) {
    const ctxEntry = contexts.get(boxUser)
    if (!ctxEntry) return
    const pageEntry = ctxEntry.pages.get(runId)
    if (!pageEntry) return
    ctxEntry.pages.delete(runId)
    try {
      await pageEntry.page.close()
    } catch {}
  }

  function sweepIdle() {
    const t = now()
    for (const [boxUser, ctxEntry] of contexts) {
      for (const [runId, pageEntry] of ctxEntry.pages) {
        if (t - pageEntry.lastUsed >= PAGE_IDLE_MS) {
          ctxEntry.pages.delete(runId)
          pageEntry.page.close().catch(() => {})
        }
      }
      if (t - ctxEntry.lastUsed >= CONTEXT_IDLE_MS) {
        contexts.delete(boxUser)
        for (const pageEntry of ctxEntry.pages.values()) {
          pageEntry.page.close().catch(() => {})
        }
        ctxEntry.context.close().catch(() => {})
      }
    }
  }

  // Programmatic close of one box's context — for the in-process host
  // embedder, which knows sandboxId -> boxUser and must not wait for the
  // 15-min idle sweep when a sandbox stops. The HTTP verb protocol never
  // accepts a box identifier; this is an embedder-only API. An in-flight
  // context creation for the same user may still land after a close — the
  // idle sweep collects it later, same race the engine already has.
  function closeContext(boxUser) {
    const ctxEntry = contexts.get(boxUser)
    if (!ctxEntry) return Promise.resolve(false)
    contexts.delete(boxUser)
    const closers = []
    for (const pageEntry of ctxEntry.pages.values()) closers.push(pageEntry.page.close().catch(() => {}))
    closers.push(ctxEntry.context.close().catch(() => {}))
    return Promise.all(closers).then(() => true)
  }

  // R-B8: token files store sha256(token) as 64 lowercase hex chars, NEVER the
  // raw token — a digest leaked via a misconfigured file:// serve or a
  // mis-permissioned file is unreplayable. Task 4's writer must write digests,
  // not raw tokens. We hash the bearer token from the request and compare
  // digests, always through a fixed-length timingSafeEqual (real digest or the
  // DECOY_DIGEST placeholder above) so an invalid/missing file takes the same
  // code path and shape as a genuine mismatch — never leaking which it was.
  function checkAuth(req) {
    const boxUser = req.headers.get('x-tau-box-user') || ''
    const authHeader = req.headers.get('authorization') || ''
    const match = /^Bearer (.+)$/.exec(authHeader)
    // Prod gate: box_<hex> only. R-B17 dev escape hatch: additionally accept a
    // user equal to the (prod-unset) FICUS_BROWSER_DEV_ALLOW_USER, still
    // filename-safe. isSafeTokenUser is redundant for BOX_USER_RE matches but
    // mandatory for the dev user before it reaches readFileSync below.
    const allowed =
      BOX_USER_RE.test(boxUser) || (devAllowUser !== '' && boxUser === devAllowUser && isSafeTokenUser(boxUser))
    if (!allowed || !match) return null

    const provided = match[1]
    let storedHex = null
    try {
      storedHex = fs.readFileSync(`${tokensDir}/${boxUser}.token`, 'utf8').trim()
    } catch {
      // Missing token file — falls through to the same generic failure as a
      // mismatch below.
    }
    const validHex = typeof storedHex === 'string' && /^[0-9a-f]{64}$/i.test(storedHex)
    const providedDigest = crypto.createHash('sha256').update(provided).digest()
    const storedDigest = validHex ? Buffer.from(storedHex, 'hex') : DECOY_DIGEST
    const matches = crypto.timingSafeEqual(providedDigest, storedDigest)
    if (!validHex || !matches) return null
    return boxUser
  }

  async function routeVerb(verb, boxUser, body) {
    const runId = body && body.runId

    if (verb === 'open') {
      // R-B9a: validate the scheme of the caller-supplied URL before ever
      // touching page/context state. The per-context route (installed at
      // context creation) is the defense-in-depth layer that also covers
      // redirects/iframes/subresources — this is just the top-level check.
      let parsedUrl
      try {
        parsedUrl = new URL(body.url)
      } catch {
        throw httpError(400, 'invalid url')
      }
      if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
        throw httpError(400, 'invalid url')
      }
      // R-B14: open() enforces the SSRF guard itself — the primary attack
      // (opening a host-local/metadata URL directly) must not depend solely
      // on the per-context route() handler below.
      if (blockedHost(parsedUrl.hostname)) {
        throw httpError(400, 'invalid url')
      }
      const pageEntry = await openPage(boxUser, runId)
      await pageEntry.page.goto(parsedUrl.href, { waitUntil: 'domcontentloaded', timeout: 30000 })
      const title = await pageEntry.page.title()
      const screenshot = await pageEntry.page.screenshot({ type: 'png' })
      return jsonResponse(200, { title, screenshotBase64: toBase64(screenshot) })
    }

    if (verb === 'close') {
      await closePage(boxUser, runId)
      return jsonResponse(200, { ok: true })
    }

    const pageEntry = getPage(boxUser, runId)
    if (!pageEntry) throw httpError(404, 'unknown runId')

    switch (verb) {
      case 'click': {
        if (body.selector) {
          await pageEntry.page.locator(body.selector).click({ timeout: 5000 })
        } else if (body.x != null && body.y != null) {
          await pageEntry.page.mouse.click(body.x, body.y)
        } else {
          throw httpError(400, 'Provide either a selector or x/y coordinates.')
        }
        const result = { ok: true }
        if (body.returnScreenshot === true) {
          result.screenshotBase64 = toBase64(await pageEntry.page.screenshot({ type: 'png' }))
        }
        return jsonResponse(200, result)
      }
      case 'type': {
        if (body.selector) {
          await pageEntry.page.locator(body.selector).fill(body.text, { timeout: 5000 })
        } else {
          await pageEntry.page.keyboard.type(body.text)
        }
        const result = { ok: true }
        if (body.returnScreenshot === true) {
          result.screenshotBase64 = toBase64(await pageEntry.page.screenshot({ type: 'png' }))
        }
        return jsonResponse(200, result)
      }
      case 'scroll': {
        const delta = (body.amount ?? 500) * (body.direction === 'up' ? -1 : 1)
        await pageEntry.page.mouse.wheel(0, delta)
        await pageEntry.page.waitForTimeout(300)
        const result = { deltaPx: delta }
        if (body.returnScreenshot === true) {
          result.screenshotBase64 = toBase64(await pageEntry.page.screenshot({ type: 'png' }))
        }
        return jsonResponse(200, result)
      }
      case 'screenshot': {
        const screenshot = await pageEntry.page.screenshot({ type: 'png' })
        return jsonResponse(200, { screenshotBase64: toBase64(screenshot) })
      }
      case 'read': {
        const text = body.selector
          ? ((await pageEntry.page.locator(body.selector).textContent({ timeout: 5000 })) ?? '')
          : await pageEntry.page.evaluate(() => document.body.innerText)
        return jsonResponse(200, { text })
      }
      case 'console': {
        return jsonResponse(200, { entries: pageEntry.consoleLogs })
      }
      default:
        throw httpError(404, 'unknown verb')
    }
  }

  async function fetchHandler(req) {
    const url = new URL(req.url)

    if (req.method === 'GET' && url.pathname === '/healthz') {
      return jsonResponse(200, { ok: true, pages: totalPages(), contexts: contexts.size })
    }
    if (req.method !== 'POST') {
      return errorResponse(404, 'not found')
    }

    const boxUser = checkAuth(req)
    if (!boxUser) return errorResponse(401, 'unauthorized')

    let body
    try {
      body = await req.json()
    } catch {
      return errorResponse(400, 'invalid JSON body')
    }
    if (body === null || typeof body !== 'object') {
      return errorResponse(400, 'invalid JSON body')
    }

    const verb = url.pathname.slice(1)
    try {
      return await routeVerb(verb, boxUser, body)
    } catch (err) {
      const status = (err && err.status) || 500
      const message = err && err.status ? err.message : err instanceof Error ? err.message : String(err)
      return errorResponse(status, message)
    }
  }

  const sweepTimer = setInterval(sweepIdle, SWEEP_INTERVAL_MS)
  if (typeof sweepTimer.unref === 'function') sweepTimer.unref()

  function shutdown() {
    clearInterval(sweepTimer)
    const closers = []
    for (const ctxEntry of contexts.values()) {
      for (const pageEntry of ctxEntry.pages.values()) {
        closers.push(pageEntry.page.close().catch(() => {}))
      }
      closers.push(ctxEntry.context.close().catch(() => {}))
    }
    contexts.clear()
    const b = browser
    browser = null
    browserPromise = null
    if (b) closers.push(b.close().catch(() => {}))
    return Promise.all(closers)
  }

  return { fetch: fetchHandler, shutdown, sweepIdle, closeContext }
}

if (import.meta.main) {
  const service = createService()

  try {
    fs.unlinkSync(SOCK)
  } catch {}

  Bun.serve({ unix: SOCK, fetch: service.fetch, maxRequestBodySize: 1 << 20 })

  try {
    fs.chmodSync(SOCK, 0o660)
  } catch (err) {
    console.error('tau-browser: could not chmod socket', err)
  }

  const onShutdown = () => {
    service.shutdown().finally(() => process.exit(0))
  }
  process.on('SIGTERM', onShutdown)
  process.on('SIGINT', onShutdown)
}
BROWSER_SERVICE_JS
}

# Write the one-shot Chromium sandbox verification program (the hard gate, run by
# verify_browser). Launches headless Chromium WITHOUT --no-sandbox and confirms a
# renderer works and chrome://sandbox does not report an unsandboxed process.
write_browser_verify() {
  "${SUDO[@]}" tee "${FICUS_BROWSER_VERIFY_JS}" >/dev/null <<'BROWSER_VERIFY_JS'
// One-shot Chromium sandbox verification — PHASE 1 hard gate (spec §4.1/§5).
// Launches headless Chromium WITHOUT --no-sandbox and confirms a renderer works
// under the unprivileged tau-browser user (a missing user-namespace grant
// crashes the zygote here) and that chrome://sandbox does not report an
// unsandboxed process. Exit 0 = sandbox active; non-zero = FAIL (bootstrap
// aborts, browsing disabled on this host — never downgraded to --no-sandbox).
//
// SINGLE SOURCE OF TRUTH: packages/machine-image/Dockerfile COPYs this file, and
// scripts/machine/bootstrap.sh (write_browser_verify) embeds it verbatim.
// bootstrap.test.ts asserts the two copies stay byte-identical.
const { chromium } = require('playwright')

async function main() {
  const browser = await chromium.launch({ headless: true })
  try {
    const page = await browser.newPage()
    // A renderer that loads a page proves the user-namespace sandbox could be
    // entered; without the AppArmor userns grant this throws.
    await page.goto('about:blank', { timeout: 15000 })
    await page.goto('chrome://sandbox', { timeout: 15000 }).catch(() => {})
    const text = (await page.innerText('body').catch(() => '')) || ''
    if (/not sandboxed/i.test(text)) {
      throw new Error('chrome://sandbox reports an unsandboxed process: ' + text.slice(0, 200))
    }
    console.error('tau-browser: sandbox verification passed')
  } finally {
    await browser.close().catch(() => {})
  }
}

main().catch((err) => {
  console.error('tau-browser: sandbox verification FAILED —', err && err.message ? err.message : err)
  process.exit(1)
})
BROWSER_VERIFY_JS
}

# Write the AppArmor profile that grants unprivileged user-namespace creation to
# the pinned Chromium binaries. Ubuntu 24.04 restricts unprivileged userns via
# AppArmor by default — the same mechanism gates its own browser packages — so
# Chromium's sandbox cannot enter a namespace without this grant. The glob
# attachment matches both the full `chrome` and the `headless_shell` binary
# across Playwright build directories, so it is version-independent.
write_browser_apparmor() {
  "${SUDO[@]}" tee "${FICUS_BROWSER_APPARMOR}" >/dev/null <<'BROWSER_APPARMOR'
# tau-browser: grant unprivileged user-namespace creation to the pinned Chromium
# so its renderer sandbox works under the unprivileged tau-browser user. KEEP the
# sandbox ON — never --no-sandbox (browser-tools-in-sandbox spec §4.1/§5).
#
# SINGLE SOURCE OF TRUTH: packages/machine-image/Dockerfile COPYs this file to
# /etc/apparmor.d/tau-browser-chromium, and scripts/machine/bootstrap.sh
# (write_browser_apparmor) embeds it verbatim. bootstrap.test.ts asserts the two
# copies stay byte-identical.
abi <abi/4.0>,
include <tunables/global>

profile tau-browser-chromium /opt/tau/browser/ms-playwright/chromium*/chrome-linux*/{chrome,headless_shell} flags=(unconfined) {
  userns,

  include if exists <local/tau-browser-chromium>
}
BROWSER_APPARMOR
}

# Write the tau-browser.service SYSTEM unit. Runs as the unprivileged
# `tau-browser` user. RuntimeDirectory gives /run/tau-browser (0750, group
# tau-browser) so box users added to the group at provision (Phase 2) can reach
# the 0660 socket. The memory cap is NOT baked here — it is host-specific and
# written per-boot by write_browser_memory_dropin (so a prebaked image, built on
# a different-sized builder, still gets THIS VM's cap).
# The unit body is fully static (all paths are fixed /opt/tau constants), so it
# is embedded verbatim — byte-identical to scripts/machine/browser/tau-browser.service
# (which the machine image COPYs), asserted by bootstrap.test.ts.
write_browser_unit() {
  "${SUDO[@]}" tee "${FICUS_BROWSER_UNIT}" >/dev/null <<'BROWSER_UNIT'
[Unit]
Description=tau shared browser service (per-box contexts, token auth, caps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tau-browser
Group=tau-browser
RuntimeDirectory=tau-browser
RuntimeDirectoryMode=0750
Environment=HOME=/opt/tau/browser/home
Environment=PLAYWRIGHT_BROWSERS_PATH=/opt/tau/browser/ms-playwright
Environment=FICUS_BROWSER_SOCK=/run/tau-browser/sock
ExecStart=/opt/tau/bin/bun /opt/tau/browser/service/tau-browser.js
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
BROWSER_UNIT
  "${SUDO[@]}" chmod 0644 "${FICUS_BROWSER_UNIT}"
}

# Write the host-specific memory cap as a systemd drop-in: MemoryHigh = min(50%
# of MemTotal, 8 GB) (spec §8.1) — the cap sits on the process that actually
# consumes the memory. Computed from THIS host's /proc/meminfo and (re)written
# per-boot by verify_browser, so a prebaked image (baked on a differently-sized
# builder) still ends up with the correct cap for the VM it boots on.
write_browser_memory_dropin() {
  local mem_total_kb half_mb cap_mb mem_high_mb dropin_dir
  mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  half_mb=$((mem_total_kb / 2 / 1024))
  cap_mb=8192 # 8 GB
  if [ "${half_mb}" -lt "${cap_mb}" ]; then
    mem_high_mb="${half_mb}"
  else
    mem_high_mb="${cap_mb}"
  fi
  dropin_dir="${FICUS_BROWSER_UNIT}.d"
  "${SUDO[@]}" mkdir -p "${dropin_dir}"
  # Both env spellings for one release (Ficus rename): this drop-in is rewritten
  # per boot, including on a prebaked image whose baked tau-browser.js may
  # predate the rename and read only the TAU_ name.
  printf '[Service]\nMemoryHigh=%sM\nEnvironment=FICUS_BROWSER_MEMORY_HIGH_MB=%s\nEnvironment=TAU_BROWSER_MEMORY_HIGH_MB=%s\n' "${mem_high_mb}" "${mem_high_mb}" "${mem_high_mb}" \
    | "${SUDO[@]}" install -m 0644 /dev/stdin "${dropin_dir}/memory.conf"
}

# Create the tau-browser system user + group (idempotent). No login shell; a
# writable HOME under /opt/tau/browser for the browser's runtime state.
ensure_browser_user() {
  getent group "${FICUS_BROWSER_USER}" >/dev/null 2>&1 \
    || "${SUDO[@]}" groupadd --system "${FICUS_BROWSER_USER}"
  id -u "${FICUS_BROWSER_USER}" >/dev/null 2>&1 \
    || "${SUDO[@]}" useradd --system --gid "${FICUS_BROWSER_USER}" \
      --home-dir "${FICUS_BROWSER_HOME}" --create-home \
      --shell /usr/sbin/nologin "${FICUS_BROWSER_USER}"
}

# The actual Playwright + Chromium install and service-scaffolding steps. Returns
# non-zero (and sets BROWSER_INSTALL_REASON to a token) at the FIRST failing step,
# so install_browser can mark the browser unavailable and continue. It is ALWAYS
# called in a tested context (`if ! _browser_install_steps`), so `set -e` is
# disabled inside it — hence every fallible step is explicitly guarded with
# `|| { BROWSER_INSTALL_REASON=<token>; return 1; }` (bare failures would silently
# run on instead of aborting). The heavy Chromium download is the single most
# likely real-world failure (network/apt/disk); it must never brick provisioning.
_browser_install_steps() {
  BROWSER_INSTALL_REASON=""
  "${SUDO[@]}" mkdir -p "${FICUS_BROWSER_ROOT}/service" "${FICUS_BROWSER_BROWSERS_PATH}" \
    || { BROWSER_INSTALL_REASON=setup_failed; return 1; }

  # Pin Playwright via a private package.json + `bun install` into
  # /opt/tau/browser/node_modules. Skip the (350 MB) download when the pinned
  # playwright is already installed AND a Chromium build is present.
  local installed=""
  if [ -f "${FICUS_BROWSER_ROOT}/node_modules/playwright/package.json" ]; then
    installed="$(jq -r '.version // ""' \
      "${FICUS_BROWSER_ROOT}/node_modules/playwright/package.json" 2>/dev/null || echo "")"
  fi
  # Playwright writes INSTALLATION_COMPLETE only after extraction finishes, so a
  # chrome binary without it is a truncated leftover from an interrupted
  # download — treat it as absent and re-download.
  local chromium_present=false
  compgen -G "${FICUS_BROWSER_BROWSERS_PATH}/chromium-*/chrome-linux*/chrome" >/dev/null 2>&1 \
    && compgen -G "${FICUS_BROWSER_BROWSERS_PATH}/chromium-*/INSTALLATION_COMPLETE" >/dev/null 2>&1 \
    && chromium_present=true
  if [ "${installed}" != "${PLAYWRIGHT_VERSION}" ] || [ "${chromium_present}" != true ]; then
    printf '{"name":"tau-browser","private":true,"dependencies":{"playwright":"%s"}}\n' \
      "${PLAYWRIGHT_VERSION}" \
      | "${SUDO[@]}" tee "${FICUS_BROWSER_ROOT}/package.json" >/dev/null \
      || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
    # Install the Playwright npm package(s) pinned exactly.
    "${SUDO[@]}" env "PLAYWRIGHT_BROWSERS_PATH=${FICUS_BROWSER_BROWSERS_PATH}" \
      "${BUN_BIN_LINK}" install --cwd "${FICUS_BROWSER_ROOT}" \
      || { BROWSER_INSTALL_REASON=playwright_install_failed; return 1; }
    # Download Chromium + its OS deps (--with-deps apt-installs libnss3/libatk/…).
    # The likeliest failure of the whole feature: a network blip, apt mirror
    # hiccup, or disk-full here marks the browser unavailable, never aborts.
    # Invoke Playwright through bun (cli.js) rather than its node_modules/.bin
    # shim: the shim is `#!/usr/bin/env node` and machine hosts install bun, NOT
    # node — the shim exits 127 ("node: not found"), the original cause of
    # chromium_download_failed on every do_droplet host.
    # `timeout` runs inside sudo so its process-group kill also reaches
    # Playwright's forked extractor, which is what stalls. A retry re-downloads:
    # the stalled attempt left no INSTALLATION_COMPLETE marker.
    local attempt
    for attempt in $(seq 1 "${BROWSER_DOWNLOAD_ATTEMPTS}"); do
      "${SUDO[@]}" env "PLAYWRIGHT_BROWSERS_PATH=${FICUS_BROWSER_BROWSERS_PATH}" \
        DEBIAN_FRONTEND=noninteractive \
        timeout -k 30 "${BROWSER_DOWNLOAD_TIMEOUT_SECS}" \
        "${BUN_BIN_LINK}" "${FICUS_BROWSER_ROOT}/node_modules/playwright/cli.js" install --with-deps chromium \
        && break
      [ "${attempt}" -lt "${BROWSER_DOWNLOAD_ATTEMPTS}" ] \
        || { BROWSER_INSTALL_REASON=chromium_download_failed; return 1; }
      echo "bootstrap.sh: WARNING Chromium install attempt ${attempt} failed or stalled; retrying" >&2
    done
  fi

  write_browser_service || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  write_browser_verify || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  write_browser_apparmor || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  ensure_browser_user || { BROWSER_INSTALL_REASON=user_setup_failed; return 1; }
  write_browser_unit || { BROWSER_INSTALL_REASON=setup_failed; return 1; }

  # Root-owned + world-readable so every box user's sandbox server can READ the
  # browser binaries (spec §4.1); the service user's HOME stays private + writable.
  "${SUDO[@]}" chown -R root:root "${FICUS_BROWSER_ROOT}" \
    || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  "${SUDO[@]}" chmod -R a+rX "${FICUS_BROWSER_ROOT}" \
    || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  "${SUDO[@]}" chown -R "${FICUS_BROWSER_USER}:${FICUS_BROWSER_USER}" "${FICUS_BROWSER_HOME}" \
    || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  "${SUDO[@]}" chmod 0700 "${FICUS_BROWSER_HOME}" \
    || { BROWSER_INSTALL_REASON=setup_failed; return 1; }
  return 0
}

# Install Playwright + Chromium (with OS deps) into /opt/tau/browser and lay down
# the tau-browser service scaffolding. Idempotent: the heavy download is skipped
# when the pinned Playwright is already present; the small service/unit/profile
# files are always (re)written so a drift re-bootstrap converges. Called from the
# non-prebaked install flow (alongside install_bun/install_devbox); on a prebaked
# image the exact same layout is baked by the Dockerfile RUN layer.
#
# FAIL-OPEN: ALWAYS returns 0. Any install/setup failure marks the browser
# unavailable (durable marker + capabilities.browser + LOUD ERROR log + stopped/
# disabled unit) with a reason token and lets bootstrap continue — a browser
# problem must NEVER brick provisioning.
install_browser() {
  if ! _browser_install_steps; then
    browser_mark_unavailable "${BROWSER_INSTALL_REASON:-install_failed}" \
      "browser install/setup step failed (see log above)"
    return 0
  fi
  # Install succeeded; verify_browser (called later in main) confirms the runtime
  # sandbox and decides READY vs a runtime reason.
}

# Mark browsing UNAVAILABLE on this host: durable machine-readable marker (reason
# token + timestamp + detail), READY removed, the service stopped AND disabled so
# a sandbox-broken unit does not flap (Restart=on-failure), and a LOUD ERROR log
# line naming the exact reason so a misconfigured host is visible in journald /
# the control plane. Sets the globals print_capabilities reports as
# capabilities.browser=unavailable + browserReason. NEVER exits non-zero — the
# machine still comes up; only browsing is off. NEVER falls back to --no-sandbox.
# `reason` is a fixed [a-z_] token (safe to embed unescaped in the caps JSON);
# `detail` is free-text for the marker + log only.
browser_mark_unavailable() {
  local reason="$1" detail="$2" ts
  BROWSER_STATUS="unavailable"
  BROWSER_REASON="${reason}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "${SUDO[@]}" mkdir -p "${FICUS_BROWSER_ROOT}" 2>/dev/null || true
  printf 'reason=%s\ntimestamp=%s\ndetail=%s\n' "${reason}" "${ts}" "${detail}" \
    | "${SUDO[@]}" tee "${FICUS_BROWSER_UNAVAILABLE_MARKER}" >/dev/null 2>&1 || true
  "${SUDO[@]}" rm -f "${FICUS_BROWSER_READY_MARKER}" 2>/dev/null || true
  # Stop + disable so the unit does not crash-loop (and stays down across reboots)
  # on a host that cannot sandbox it.
  "${SUDO[@]}" systemctl disable --now tau-browser.service >/dev/null 2>&1 || true
  echo "bootstrap.sh: ERROR browser unavailable on this host (reason=${reason}): ${detail} — browsing disabled; the machine still comes up. NEVER falling back to --no-sandbox." >&2
}

# Mark browsing READY: durable marker (timestamp), UNAVAILABLE removed, globals
# reported as capabilities.browser=available.
browser_mark_ready() {
  local ts
  BROWSER_STATUS="available"
  BROWSER_REASON=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'timestamp=%s\n' "${ts}" \
    | "${SUDO[@]}" tee "${FICUS_BROWSER_READY_MARKER}" >/dev/null 2>&1 || true
  "${SUDO[@]}" rm -f "${FICUS_BROWSER_UNAVAILABLE_MARKER}" 2>/dev/null || true
}

# SOFT GATE (spec §4.1/§5, softened 2026-08-24 per owner). Run on EVERY boot in
# main() — on both the prebaked (baked layout) and BYO (install_browser) paths,
# because loading the AppArmor profile into the running kernel and starting the
# SYSTEM service are per-boot actions. Loads the profile, runs the one-shot
# Chromium sandbox check as the tau-browser user, and starts the service.
#
# NEVER fails bootstrap: on ANY failure the machine still comes up (return 0)
# with browsing marked UNAVAILABLE — durable marker + capabilities.browser +
# ERROR log + a stopped/disabled unit — so an un-sandboxable host gets NO browser
# rather than an unsafe one. NEVER falls back to --no-sandbox. Only the happy
# path (sandbox verified ON + service active) marks READY.
verify_browser() {
  # 0. If install_browser already marked the browser unavailable (e.g. the
  #    Chromium download failed), KEEP that more-specific reason — a runtime
  #    sandbox check on a half-installed browser would only overwrite it with a
  #    less useful token. Nothing to verify; the caps/marker already reflect it.
  if [ "${BROWSER_STATUS}" = "unavailable" ] && [ "${BROWSER_REASON}" != "not_verified" ]; then
    return 0
  fi

  # 1. Load the AppArmor profile into the running kernel (grants Chromium the
  #    unprivileged userns its sandbox needs). Missing/failed → unavailable.
  if ! command -v apparmor_parser >/dev/null 2>&1; then
    browser_mark_unavailable apparmor_parser_missing \
      "apparmor_parser not found — cannot grant Chromium the userns its sandbox needs"
    return 0
  fi
  if ! "${SUDO[@]}" apparmor_parser -r -W "${FICUS_BROWSER_APPARMOR}" 2>/dev/null; then
    browser_mark_unavailable apparmor_load_failed \
      "failed to load ${FICUS_BROWSER_APPARMOR} into the running kernel"
    return 0
  fi

  # 2. One-shot sandbox check as the tau-browser user (runuser: always available,
  #    no password, needs root — hence the SUDO wrapper). This is where a host
  #    that cannot enter the userns sandbox (or musl/Alpine that cannot run the
  #    glibc Chromium) fails — non-fatally.
  #
  #    Run it from ${FICUS_BROWSER_ROOT} (world-rX) rather than inheriting
  #    bootstrap's CWD: bootstrap runs as root from /root (0700), and runuser
  #    keeps the caller's CWD. bun started in a directory the target user cannot
  #    stat silently yields an EMPTY process.env — so PLAYWRIGHT_BROWSERS_PATH
  #    is dropped, Playwright falls back to $HOME/.cache/ms-playwright, the
  #    (correctly-installed) Chromium is "not found", and this gate fails with a
  #    misleading sandbox_check_failed. An accessible CWD is mandatory. Any
  #    tau-browser bun invocation is subject to this (the SYSTEM unit is safe
  #    only because systemd's default WorkingDirectory=/ is accessible).
  if ! ( cd "${FICUS_BROWSER_ROOT}" && "${SUDO[@]}" runuser -u "${FICUS_BROWSER_USER}" -- \
    env "HOME=${FICUS_BROWSER_HOME}" "PLAYWRIGHT_BROWSERS_PATH=${FICUS_BROWSER_BROWSERS_PATH}" \
    "${BUN_BIN_LINK}" "${FICUS_BROWSER_VERIFY_JS}" ) >&2; then
    browser_mark_unavailable sandbox_check_failed \
      "Chromium sandbox one-shot verification failed as ${FICUS_BROWSER_USER} (see log above)"
    return 0
  fi

  # 3. Write THIS host's memory cap, then start (or restart) the SYSTEM service
  #    and confirm it stays active. A service that will not start/stay up →
  #    unavailable (and browser_mark_unavailable leaves it stopped + disabled).
  #    Each step guarded so it marks-unavailable-and-returns-0 rather than
  #    `set -e`-aborting bootstrap.
  if ! write_browser_memory_dropin; then
    browser_mark_unavailable service_start_failed \
      "failed to write the tau-browser MemoryHigh drop-in"
    return 0
  fi
  if ! "${SUDO[@]}" systemctl daemon-reload; then
    browser_mark_unavailable service_start_failed "systemctl daemon-reload failed"
    return 0
  fi
  "${SUDO[@]}" systemctl enable tau-browser.service >/dev/null 2>&1 || true
  if ! "${SUDO[@]}" systemctl restart tau-browser.service 2>/dev/null; then
    browser_mark_unavailable service_start_failed \
      "systemctl restart tau-browser.service failed"
    return 0
  fi
  if ! "${SUDO[@]}" systemctl is-active --quiet tau-browser.service; then
    "${SUDO[@]}" systemctl status tau-browser.service --no-pager -l >&2 2>/dev/null || true
    browser_mark_unavailable service_inactive \
      "tau-browser.service did not stay active after start"
    return 0
  fi

  # Happy path: sandbox verified ON and the service is live.
  browser_mark_ready
}

# Read a string field from the prebaked marker JSON. Prefer jq (baked into the
# image alongside the toolchain — install_base_packages installs it); fall back
# to a grep/sed extraction so the check still works if jq is somehow absent.
# Prints the value (empty string when the field is missing). The caller has
# already confirmed the marker file exists.
marker_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "${field}" '.[$f] // ""' "${PREBAKED_MARKER}" 2>/dev/null || true
  else
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      "${PREBAKED_MARKER}" 2>/dev/null | head -n1
  fi
}

# Log the prebaked-image decision to stderr. Called by main() ONLY when the
# marker is already known to exist. It NEVER changes whether the installs run —
# a prebaked image ALWAYS uses its baked tooling and main() ALWAYS skips the
# installs when the marker is present. This function only decides what to LOG:
#   - all baked bun/nix/devbox versions equal this script's pins → a plain
#     fast-path notice (the common, healthy case); or
#   - a version DRIFTS (stale image, e.g. a pin bumped but the image not yet
#     rebaked) → a clear per-field WARNING naming the drift, stating that the
#     baked tooling is being used, and recommending an image rebake.
# Why we NEVER reinstall on drift: bun/devbox would overwrite fine, but the
# official nix installer REFUSES to run over an existing /nix and errors out —
# under `set -e` that aborts the whole run and BRICKS provisioning (the VM is
# marked unreachable). Using the baked tooling can never brick. The correct way
# to change a pinned version on a prebaked image is to REBAKE the image, which
# the warning tells the operator to do. This is an OPTIMIZATION-and-safety layer
# only — the per-machine/per-boot steps (make_dirs, write_manifest,
# apply_egress_lockdown, and the caps probe) run regardless.
log_prebaked_decision() {
  local baked_bun baked_nix baked_devbox baked_playwright
  baked_bun="$(marker_field bunVersion)"
  baked_nix="$(marker_field nixVersion)"
  baked_devbox="$(marker_field devboxVersion)"
  baked_playwright="$(marker_field playwrightVersion)"
  if [ "${baked_bun}" = "${BUN_VERSION}" ] &&
    [ "${baked_nix}" = "${NIX_VERSION}" ] &&
    [ "${baked_devbox}" = "${DEVBOX_VERSION}" ] &&
    [ "${baked_playwright}" = "${PLAYWRIGHT_VERSION}" ]; then
    echo "bootstrap.sh: prebaked ficus-machine image detected (bun ${baked_bun}, nix ${baked_nix}, devbox ${baked_devbox}, playwright ${baked_playwright} match pins) — skipping install steps" >&2
    return 0
  fi
  # Drift: DO NOT reinstall (a nix reinstall over the baked /nix bricks the run —
  # see above). Use the baked tooling and warn per drifting field; a real version
  # bump is applied by rebaking the image, not by a boot-time reinstall.
  [ "${baked_bun}" = "${BUN_VERSION}" ] ||
    echo "bootstrap.sh: WARNING prebaked image bun ${baked_bun} != script ${BUN_VERSION} — using baked tooling; rebake the ficus-machine image to change pinned versions" >&2
  [ "${baked_nix}" = "${NIX_VERSION}" ] ||
    echo "bootstrap.sh: WARNING prebaked image nix ${baked_nix} != script ${NIX_VERSION} — using baked tooling; rebake the ficus-machine image to change pinned versions" >&2
  [ "${baked_devbox}" = "${DEVBOX_VERSION}" ] ||
    echo "bootstrap.sh: WARNING prebaked image devbox ${baked_devbox} != script ${DEVBOX_VERSION} — using baked tooling; rebake the ficus-machine image to change pinned versions" >&2
  [ "${baked_playwright}" = "${PLAYWRIGHT_VERSION}" ] ||
    echo "bootstrap.sh: WARNING prebaked image playwright ${baked_playwright} != script ${PLAYWRIGHT_VERSION} — using baked tooling; rebake the ficus-machine image to change pinned versions" >&2
}

write_manifest() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"bootstrapVersion":"%s","bunVersion":"%s","nixVersion":"%s","devboxVersion":"%s","playwrightVersion":"%s","bootstrappedAt":"%s"}\n' \
    "${BOOTSTRAP_VERSION}" "${BUN_VERSION}" "${NIX_VERSION}" "${DEVBOX_VERSION}" "${PLAYWRIGHT_VERSION}" "${ts}" \
    | "${SUDO[@]}" tee "${FICUS_ROOT}/manifest.json" >/dev/null
}

# SECURITY-CRITICAL. Every --core-cidr is interpolated verbatim into the root
# `nft -f` input (render_egress_ruleset), so a hostile value must be rejected
# BEFORE any nft (or apt) call — otherwise it could inject nft syntax or widen
# the allow-list. Enforce a strict IPv4-CIDR shape AND numeric bounds (the regex
# alone still permits e.g. 999.0.0.0/40); the prefix must be 1..32, so a /0
# "allow the whole internet" value is rejected too. Exit 2 on the first bad value. Called
# unconditionally at startup, before main and before the print-ruleset path.
validate_core_cidrs() {
  # No CIDRs → nothing to validate. Guard the expansion so an empty array is not
  # an "unbound variable" under `set -u` on older bash (matches apply_egress's
  # count-guard pattern).
  [ "${#CORE_CIDRS[@]}" -gt 0 ] || return 0
  local cidr
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$'
  for cidr in "${CORE_CIDRS[@]}"; do
    if [[ ! "${cidr}" =~ $re ]]; then
      echo "bootstrap.sh: invalid --core-cidr (not an IPv4 CIDR): ${cidr}" >&2
      exit 2
    fi
    # Reject leading-zero octets (e.g. 010.0.0.0). They are valid to the bounds
    # check below (10# reads them as decimal) but are a nonstandard/ambiguous form
    # — some parsers read 010 as octal — so refuse them outright before nft sees it.
    local octet
    for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
      if [ "${#octet}" -gt 1 ] && [ "${octet#0}" != "${octet}" ]; then
        echo "bootstrap.sh: invalid --core-cidr (leading-zero octet): ${cidr}" >&2
        exit 2
      fi
    done
    # 10#… forces base-10 so a leading-zero octet (e.g. 010) is not read as octal.
    # Prefix must be 1..32: reject /0 too — as an allow-exception, 0.0.0.0/0 would
    # match every destination and silently punch the whole egress lockdown open
    # (operator error), so require at least a /1.
    if [ "$((10#${BASH_REMATCH[1]}))" -gt 255 ] ||
      [ "$((10#${BASH_REMATCH[2]}))" -gt 255 ] ||
      [ "$((10#${BASH_REMATCH[3]}))" -gt 255 ] ||
      [ "$((10#${BASH_REMATCH[4]}))" -gt 255 ] ||
      [ "$((10#${BASH_REMATCH[5]}))" -gt 32 ] ||
      [ "$((10#${BASH_REMATCH[5]}))" -lt 1 ]; then
      echo "bootstrap.sh: invalid --core-cidr (octet>255 or prefix not in 1..32): ${cidr}" >&2
      exit 2
    fi
  done
}

# Print the exact `table inet tau_egress` nftables ruleset apply_egress_lockdown
# loads. Split out so it can be asserted + `nft -c -f`'d without root/nft
# (--print-egress-ruleset) and piped into the real `nft -f -`. Reads CORE_CIDRS,
# which validate_core_cidrs has already vetted — the ONLY untrusted input here.
render_egress_ruleset() {
  # v4 deny-list — byte-identical to the `except:` block of the 0.0.0.0/0 egress
  # rule in k8s/network-policy.yaml (private + link-local + cloud-metadata +
  # other special-use ranges). Keep in lockstep with that file. DNS and the
  # explicit --core-cidr allow-exceptions are accepted before the drop;
  # everything else (the public internet) is accepted by the default policy.
  local denied4="0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4"

  # v6 deny-list — closes the slice-2 dual-stack leak (a v4-only lockdown lets a
  # dual-stack VM reach internal ranges over IPv6). fc00::/7 (ULA) already
  # subsumes fd00::/8 and the AWS IPv6 IMDS address fd00:ec2::254; fe80::/10
  # (link-local) already subsumes the fe80::a9fe:a9fe metadata mapping of
  # 169.254.169.254. They are deliberately collapsed to these two non-overlapping
  # supernets: an nftables `flags interval` set REJECTS overlapping elements, so
  # listing fd00::/8 or the metadata addresses alongside their supernets would
  # make `nft -f` fail to load.
  local denied6="fc00::/7, fe80::/10"

  local -a rules=(
    'table inet tau_egress {'
    '  set denied4 {'
    '    type ipv4_addr'
    '    flags interval'
    "    elements = { ${denied4} }"
    '  }'
    '  set denied6 {'
    '    type ipv6_addr'
    '    flags interval'
    "    elements = { ${denied6} }"
    '  }'
    '  chain output {'
    '    type filter hook output priority 0; policy accept;'
    '    oif "lo" accept'
    '    ct state established,related accept'
    # DNS is allowed to ANY destination on :53 BY DESIGN — public egress is open
    # (default policy accept), and the resolver a box will use is not known at
    # bootstrap time. If a specific resolver CIDR becomes knowable later, scope
    # these two rules to it (`ip daddr <resolver> udp dport 53 accept`) to stop a
    # box exfiltrating over DNS to an arbitrary server; left open for now.
    '    udp dport 53 accept'
    '    tcp dport 53 accept'
  )
  # oif "lo" + established/related sit BEFORE any drop so the box->core REVERSE
  # tunnel keeps working under lockdown: it reaches core over 127.0.0.1:<port>
  # (loopback) and its payload rides the INBOUND ssh connection, whose return
  # traffic is `established` — both are permitted even if core is inside an
  # otherwise-dropped RFC1918 range.
  if [ "${#CORE_CIDRS[@]}" -gt 0 ]; then
    local joined
    joined="$(printf '%s, ' "${CORE_CIDRS[@]}")"
    joined="${joined%, }"
    rules+=("    ip daddr { ${joined} } accept")
  fi
  # Rootless-docker interaction (Task 1): a box's containers egress via
  # slirp4netns userspace NAT, which performs the actual outbound socket() calls
  # in the HOST network namespace as the box user. Those packets therefore
  # traverse THIS output hook and are subject to the same deny-list — a container
  # cannot bypass it to reach RFC1918, and ordinary container internet egress
  # (default policy accept) still works. Rootless docker's own iptables live in a
  # separate (rootlesskit) netns and do not collide with this inet table.
  rules+=(
    '    ip daddr @denied4 drop'
    '    ip6 daddr @denied6 drop'
    '  }'
    '}'
  )

  printf '%s\n' "${rules[@]}"
}

apply_egress_lockdown() {
  command -v nft >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    "${SUDO[@]}" apt-get "${APT_LOCK_WAIT[@]}" install -y --no-install-recommends nftables
  }

  # Idempotent: flush + recreate a dedicated table so re-runs never stack rules.
  "${SUDO[@]}" nft delete table inet tau_egress 2>/dev/null || true
  render_egress_ruleset | "${SUDO[@]}" nft -f -
}

# Read the first line a TCP endpoint sends within 5s and print it. sshd greets
# every connection with its version banner immediately, so this doubles as both
# a "is something listening" probe and a "did data flow" check. bash's /dev/tcp
# avoids a netcat dependency; the subshell scopes fd 3 so it always closes.
read_tcp_banner() {
  (
    exec 3<>"/dev/tcp/$1/$2" || exit 1
    local line
    IFS= read -r -t 5 line <&3 || exit 1
    printf '%s' "${line}"
  ) 2>/dev/null
}

# Empirical TCP-forwarding self-test (decision-ladder step 2 — see
# detect_forwarding): prove forwarding works by actually forwarding. Generates
# an ephemeral ed25519 key, authorizes it for the CURRENT user, opens an
# in-host `ssh -N -L <lport>:127.0.0.1:22` loopback back into the local sshd,
# then reads through the forwarded port. sshd's version banner arriving through
# the tunnel proves the direct-tcpip channel carried data; an authenticated
# session whose forwarded connection carries nothing means sshd refused the
# channel (AllowTcpForwarding no). Everything is cleaned up: the authorized_keys
# line (tagged with a unique comment), the temp key/known_hosts dir, the ssh pid.
#
# Returns 0 = forwarding works ("yes"), 1 = session up but channel refused
# ("no"), 2 = the self-test could not run at all (no local sshd on loopback:22,
# key auth refused, no ssh client, no HOME) — indeterminate, NOT "no".
forwarding_selftest() {
  [ -n "${HOME:-}" ] && [ -d "${HOME}" ] || return 2
  command -v ssh >/dev/null 2>&1 || return 2
  command -v ssh-keygen >/dev/null 2>&1 || return 2
  # The loopback needs a local sshd answering on the default port.
  read_tcp_banner 127.0.0.1 22 | grep -q '^SSH-' || return 2

  local tag tmp akf
  tag="tau-fwd-probe-$$"
  tmp="$(mktemp -d)" || return 2
  if ! ssh-keygen -q -t ed25519 -N '' -C "${tag}" -f "${tmp}/key" 2>/dev/null; then
    rm -rf "${tmp}"
    return 2
  fi
  # Authorize the ephemeral key for the current user (0600/0700 so sshd's
  # StrictModes accepts it). The tagged line is removed again below.
  akf="${HOME}/.ssh/authorized_keys"
  if ! { mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh" &&
    cat "${tmp}/key.pub" >>"${akf}" && chmod 600 "${akf}"; } 2>/dev/null; then
    rm -rf "${tmp}"
    return 2
  fi

  # ssh binds the -L port only AFTER authentication + forward setup succeed, so
  # "the local port answers" == "session established". ExitOnForwardFailure
  # makes a refused local bind fatal instead of a silent no-op session.
  local lport pid
  lport=$((20000 + RANDOM % 40000))
  ssh -i "${tmp}/key" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${tmp}/known_hosts" \
    -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
    -N -L "${lport}:127.0.0.1:22" "$(id -un)@127.0.0.1" 2>/dev/null &
  pid=$!

  # Wait (<=10s) for the client to authenticate and bind the forward port,
  # bailing out early if ssh itself dies (auth refused, port collision) —
  # that is "could not run the test", never "no".
  local up=false
  for _ in $(seq 1 50); do
    kill -0 "${pid}" 2>/dev/null || break
    if (exec 3<>"/dev/tcp/127.0.0.1/${lport}") 2>/dev/null; then
      up=true
      break
    fi
    sleep 0.2
  done

  # Verdict: banner through the tunnel = the forwarded channel carried data.
  local result=2
  if [ "${up}" = true ]; then
    if read_tcp_banner 127.0.0.1 "${lport}" | grep -q '^SSH-'; then
      result=0
    else
      result=1
    fi
  fi

  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  # Remove exactly the tagged key line (grep -F: literal match; rewrite through
  # cat so the file keeps its inode/permissions; grep exits 1 on an emptied
  # file, hence the || true).
  grep -vF "${tag}" "${akf}" >"${tmp}/ak" 2>/dev/null || true
  cat "${tmp}/ak" >"${akf}" 2>/dev/null || true
  rm -rf "${tmp}"
  return "${result}"
}

# Probe whether the host's sshd permits TCP forwarding. A machine with
# forwarding disabled cannot host tunnel-reached boxes; the slice-2 manager must
# reject it loudly at ensure rather than fail with opaque ECONNRESETs.
#
# Decision ladder — DEFINITIVE for any reachable host; "unknown" survives only
# as a last-ditch value when even the config files are unreadable:
#   1. `sshd -T` effective config (needs privilege + a valid config) — run via
#      the script's `${SUDO[@]}` wrapper so an unprivileged sudoer still gets a
#      real answer instead of sshd's "no hostkeys available" failure. An
#      explicit AllowTcpForwarding value maps to yes/no.
#   2. `sshd -T` unavailable (observed live: exe's exeuntu sshd) → EMPIRICAL
#      loopback self-test (forwarding_selftest above): actually forward a port
#      and see whether data flows. yes/no when the test runs to a verdict.
#   3. Self-test could not run (no local sshd loopback) → config files: an
#      explicit `AllowTcpForwarding no` in /etc/ssh/sshd_config or
#      sshd_config.d/*.conf → "no"; otherwise "yes", because OpenSSH's
#      compiled-in default is AllowTcpForwarding=yes — absence of an explicit
#      "no" means forwarding is enabled. Only when the main config exists but
#      cannot be read even via sudo do we report "unknown".
detect_forwarding() {
  local line value
  # Step 1: effective config. `sshd -T` failing (or emitting no match) leaves
  # the capture empty; the `if` swallows the non-zero so `set -e`/pipefail
  # don't abort here.
  if line="$("${SUDO[@]}" sshd -T 2>/dev/null | grep -i allowtcpforwarding)"; then
    value="$(printf '%s\n' "${line}" | awk 'NR==1 {print tolower($2)}')"
    case "${value}" in
      no)
        printf 'no'
        return
        ;;
      yes | all | local | remote)
        printf 'yes'
        return
        ;;
    esac
    # Unrecognized value: fall through to the empirical test.
  fi

  # Step 2: empirical loopback self-test.
  local rc=0
  forwarding_selftest || rc=$?
  case "${rc}" in
    0)
      printf 'yes'
      return
      ;;
    1)
      printf 'no'
      return
      ;;
  esac

  # Step 3: config files + OpenSSH's compiled-in default. Read via ${SUDO[@]}
  # (sshd_config is 0644 on Ubuntu but root-only on some hardened hosts);
  # missing sshd_config.d fragments are fine (cat's stderr is dropped).
  if "${SUDO[@]}" sh -c 'cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null' 2>/dev/null |
    grep -Eiq '^[[:space:]]*allowtcpforwarding[[:space:]]+no([[:space:]]|$)'; then
    printf 'no'
    return
  fi
  # No explicit "no". If the main config is readable (or absent entirely —
  # sshd would run on pure compiled-in defaults), the default (yes) applies.
  if [ ! -e /etc/ssh/sshd_config ] || "${SUDO[@]}" test -r /etc/ssh/sshd_config 2>/dev/null; then
    printf 'yes'
  else
    printf 'unknown'
  fi
}

# Report rootless-docker availability for the `docker` capability. "rootless"
# when the rootless daemon launcher is installed AND the kernel permits
# unprivileged user namespaces (what per-box rootless dockerd needs); "none"
# otherwise. Ubuntu 24.04 enables unprivileged userns by default, so the legacy
# `unprivileged_userns_clone` sysctl is often absent — treat absent as enabled,
# and only fail when it is present and explicitly 0.
detect_docker() {
  if ! command -v dockerd-rootless.sh >/dev/null 2>&1; then
    printf 'none'
    return
  fi
  local f=/proc/sys/kernel/unprivileged_userns_clone
  if [ -f "${f}" ] && [ "$(cat "${f}")" != "1" ]; then
    printf 'none'
    return
  fi
  printf 'rootless'
}

print_capabilities() {
  local arch cpus mem_mb disk_gb kernel docker forwarding browser_json
  arch="$(uname -m)"
  cpus="$(nproc)"
  mem_mb="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
  disk_gb="$(df -BG --output=size / | awk 'NR==2 {gsub(/[^0-9]/, "", $1); print $1}')"
  kernel="$(uname -r)"
  docker="$(detect_docker)"
  forwarding="$(detect_forwarding)"
  # Browser availability, set by verify_browser (a global, seen here because main
  # runs in this same shell). The control plane reads capabilities.browser to show
  # a misconfigured host; on unavailable it also carries a fixed reason token.
  # BROWSER_REASON is [a-z_] only, so it is safe unquoted in the JSON.
  if [ "${BROWSER_STATUS:-unavailable}" = "available" ]; then
    browser_json='"browser":"available"'
  else
    browser_json="$(printf '"browser":"unavailable","browserReason":"%s"' "${BROWSER_REASON:-not_verified}")"
  fi
  printf 'FICUS_CAPS_JSON: {"arch":"%s","cpus":%s,"memMb":%s,"diskGb":%s,"kernel":"%s","docker":"%s","forwarding":"%s",%s}\n' \
    "${arch}" "${cpus}" "${mem_mb}" "${disk_gb}" "${kernel}" "${docker}" "${forwarding}" "${browser_json}"
}

main() {
  # Prebaked ficus-machine image: when its /opt/tau/prebaked marker is PRESENT, the
  # install_* steps are already baked, so skip them and use the baked tooling —
  # ALWAYS, regardless of whether the baked versions match this script's pins.
  # A prebaked image is never reinstalled over at boot (a nix reinstall over the
  # baked /nix would brick the run — see log_prebaked_decision), so a version
  # drift only logs a WARNING recommending an image rebake; it never falls back to
  # the installs. This is the ONLY thing prebaked changes — the per-machine/
  # per-boot work below (make_dirs, the manifest with the caller's --version hash,
  # verify_browser's Chromium-sandbox check — which loads the AppArmor profile
  # into the running kernel and starts the SYSTEM browser service, both per-boot,
  # and marks browsing unavailable without failing bootstrap if it cannot — and
  # the egress lockdown) STILL runs, and print_capabilities (the caps probe
  # reflecting THIS VM) always runs after main. The non-prebaked (no-marker)
  # branch is the original sequence, unchanged: idempotent installs on a bare host.
  if [ -f "${PREBAKED_MARKER}" ]; then
    log_prebaked_decision
    make_dirs
  else
    install_base_packages
    make_dirs
    install_docker_packages
    install_bun
    install_nix
    install_devbox
    # install_browser is fail-open (always returns 0); the `|| true` is
    # defence-in-depth so even an unexpected non-zero can never `set -e`-abort
    # bootstrap. The browser NEVER affects bootstrap's exit code.
    install_browser || true
  fi
  write_manifest
  # Chromium-sandbox check (spec §4.1/§5): loading the AppArmor profile into the
  # running kernel + starting the SYSTEM browser service are per-boot actions, so
  # this runs on BOTH the prebaked (baked layout) and BYO (install_browser) paths.
  # It NEVER fails bootstrap — if the sandbox cannot be enabled it marks browsing
  # unavailable (capabilities.browser + durable marker + ERROR log + stopped unit)
  # and the machine still comes up; it NEVER falls back to --no-sandbox. `|| true`
  # is defence-in-depth on the same invariant (verify_browser already returns 0).
  verify_browser || true
  if [ "${EGRESS_LOCKDOWN}" = true ]; then
    apply_egress_lockdown
  fi
}

# Validate the (untrusted) --core-cidr input BEFORE any nft/apt call — see the
# security note on validate_core_cidrs. Runs on every invocation.
validate_core_cidrs

# Dry run: print the rendered egress ruleset and exit without touching the host.
if [ "${PRINT_EGRESS_RULESET}" = true ]; then
  render_egress_ruleset
  exit 0
fi

# Dry run: report the prebaked install decision main() would take (and any drift
# WARNING) without running a single install step. `skip` == marker present (use
# the baked tooling); `install` == no marker (full BYO install path).
if [ "${PRINT_PREBAKED_DECISION}" = true ]; then
  if [ -f "${PREBAKED_MARKER}" ]; then
    log_prebaked_decision
    printf 'skip\n'
  else
    printf 'install\n'
  fi
  exit 0
fi

# Route all incidental stdout from the provisioning steps to stderr so the only
# thing on real stdout is the single capabilities marker line below.
main 1>&2
print_capabilities
