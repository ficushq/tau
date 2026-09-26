#!/usr/bin/env bash
# Build a core release artifact from this checkout.
#
# This is the ONE builder both producers run (spec §4.2): GitHub Actions
# (`core-artifact.yml`) and the control plane's `build_core_artifact` job. It
# owns the build environment, the prerequisite checks and the three builds;
# `scripts/artifact/lib/assemble-core-artifact.ts` owns everything structural
# (staging, pruning, manifest, signature, tarball, smoke).
#
#   scripts/artifact/build-core-artifact.sh --out-dir DIR [--sign-key PATH]
#                                           [--builder LABEL] [--skip-install] [--smoke]
#
# --skip-install skips the ROOT `bun install` only; the config extensions are
# always installed, since nothing else ever populates them.
#
# On success the last three lines of stdout are the machine-readable trailer:
#   CORE_ARTIFACT_SHA=<40-hex>
#   CORE_ARTIFACT_DIGEST=sha256:<hex>
#   CORE_ARTIFACT_TARBALL=<absolute path>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR=""
SIGN_KEY=""
BUILDER=""
SKIP_INSTALL=0
SMOKE=0

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="${2:?--out-dir needs a value}"; shift 2 ;;
    --sign-key) SIGN_KEY="${2:?--sign-key needs a value}"; shift 2 ;;
    --builder) BUILDER="${2:?--builder needs a value}"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --smoke) SMOKE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  echo "error: --out-dir is required" >&2
  usage
  exit 2
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# --- the build environment, set HERE rather than trusted from the caller ---
#
# Several build-time imports reach apps/core/src/db, which throws at module
# evaluation when DATABASE_URL is unset. Nothing here connects, so the value
# only has to parse — but it points at LOCALHOST on purpose: if something ever
# does connect, it fails immediately instead of hanging on an unroutable host
# while CI burns its timeout.
export DATABASE_URL="${DATABASE_URL:-postgres://build:build@localhost:5432/build}"
# A builder must never inherit test or root-relocation state: FICUS_TEST_MODE
# swaps in test doubles, and FICUS_ROOT/FICUS_REPO_ROOT would point the builds and
# the machine-bundle prebuild at a DIFFERENT tree than the one we are staging.
unset FICUS_TEST_MODE
unset FICUS_ROOT
unset FICUS_REPO_ROOT
# ...and their legacy spellings, for one release (Ficus rename): the in-process
# bridge would promote an inherited TAU_ name to FICUS_ inside the build.
unset TAU_TEST_MODE # legacy-env
unset TAU_ROOT # legacy-env
unset TAU_REPO_ROOT # legacy-env

# --- prerequisites ---
if ! COMMIT="$(git rev-parse HEAD 2>/dev/null)"; then
  echo "error: not a git checkout (git rev-parse HEAD failed)." >&2
  echo "       Build from a real clone: a tarball checkout degrades the CLI build stamp to 'dev'." >&2
  exit 1
fi
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: git rev-parse HEAD returned '$COMMIT', not a 40-hex sha" >&2
  exit 1
fi

if [[ ! -f .bun-version ]]; then
  echo "error: .bun-version is missing; it is the single pin the manifest records" >&2
  exit 1
fi
BUN_V="$(tr -d '[:space:]' < .bun-version)"
BUN_ACTUAL="$(bun --version)"
if [[ "$BUN_ACTUAL" != "$BUN_V" ]]; then
  # Repair rather than refuse: the pin is this checkout's own .bun-version,
  # and the control plane's fallback build is the ONLY artifact path for a
  # tenant upgrade — a refusal here used to strand every upgrade after a Core
  # bun bump until someone hand-installed the new bun on the host. The
  # install is per-user (${BUN_INSTALL:-$HOME/.bun}) and only reaches PATH
  # for this build; it never touches the system bun.
  if [[ ! "$BUN_V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: .bun-version pins '$BUN_V', which is not an x.y.z version." >&2
    exit 1
  fi
  echo "==> bun $BUN_ACTUAL is on PATH but .bun-version pins $BUN_V — installing $BUN_V for this build" >&2
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  if ! curl -fsSL https://bun.sh/install | bash -s "bun-v$BUN_V" >/dev/null 2>&1; then
    echo "error: installing bun $BUN_V failed (network to bun.sh / GitHub?). Install $BUN_V on this host and retry." >&2
    exit 1
  fi
  export PATH="$BUN_INSTALL/bin:$PATH"
  hash -r
  BUN_ACTUAL="$(bun --version)"
  if [[ "$BUN_ACTUAL" != "$BUN_V" ]]; then
    echo "error: bun $BUN_ACTUAL is on PATH after installing $BUN_V — the manifest records the pin, and the box refuses a mismatch." >&2
    exit 1
  fi
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64|Darwin-arm64) ;;
  *) echo "error: unsupported native Core artifact build target" >&2; exit 1 ;;
esac

echo "==> commit $COMMIT (bun $BUN_V)" >&2

# --- install ---
# --skip-install skips ONLY the root install, for CI (which restores its own
# cache) and for repeat local runs.
if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "==> bun install --frozen-lockfile --ignore-scripts" >&2
  bun install --frozen-lockfile --ignore-scripts
fi

# ALWAYS, --skip-install or not: the root install runs with --ignore-scripts,
# so it never populates config/agent/extensions/*/node_modules — and those
# ship inside the artifact, because the box never installs anything. A cached
# CI install would otherwise produce an artifact with a dead extension. This
# is cheap and idempotent when the extensions are already installed.
echo "==> bun run extensions:install" >&2
bun run extensions:install

# --- builds ---
echo "==> build: core" >&2
(cd apps/core && bun run build)
echo "==> build: cli" >&2
(cd apps/cli && bun run build)
# Deliberately NOT `bun run build:web`: that wrapper also runs
# sync-web-dist-if-configured.sh, a sudo rsync deploy hook for bare-metal dev
# boxes that has no business firing on a build machine.
echo "==> build: web" >&2
bun run --filter web build

for output in apps/core/dist/index.js apps/core/dist/worker.js apps/core/dist/migrate.js \
  apps/core/dist/smoke-configured-extensions.js apps/core/dist/box-control.js apps/cli/dist/tau.js apps/web/dist/index.html \
  apps/core/docs-dist/index.html apps/core/docs-dist/404.html apps/core/docs-dist/pagefind/pagefind.js; do
  if [[ ! -f "$output" ]]; then
    echo "error: build finished but $output does not exist" >&2
    exit 1
  fi
done

# --- prebuilt machine-host bundles ---
# A subprocess, not an import: build-machine-bundles pulls in apps/core/src/db,
# whose connection watchdog would otherwise keep this process alive. It clears
# and recreates the directory itself; the rm here makes the fresh-each-run
# contract explicit and survives a future change to that script.
echo "==> machine bundles" >&2
rm -rf "$REPO_ROOT/machine"
bun scripts/artifact/build-machine-bundles.ts "$REPO_ROOT/machine"

# --- assemble ---
ASSEMBLE_ARGS=(--checkout "$REPO_ROOT" --commit "$COMMIT" --out-dir "$OUT_DIR")
# `if` blocks, not `cond && append`: under `set -e` a false one-line `&&`
# list is a failing command and would exit the script.
if [[ -n "$SIGN_KEY" ]]; then ASSEMBLE_ARGS+=(--sign-key "$SIGN_KEY"); fi
if [[ -n "$BUILDER" ]]; then ASSEMBLE_ARGS+=(--builder "$BUILDER"); fi
if [[ "$SMOKE" -eq 1 ]]; then ASSEMBLE_ARGS+=(--smoke); fi

TRAILER_FILE="$(mktemp)"
trap 'rm -f "$TRAILER_FILE"' EXIT
echo "==> assemble" >&2
bun scripts/artifact/lib/assemble-core-artifact.ts "${ASSEMBLE_ARGS[@]}" | tee "$TRAILER_FILE"

# The trailer is this script's contract with its callers (CI and the control
# plane parse it); a silent shape change must fail the build, not the caller.
for key in 'CORE_ARTIFACT_SHA=' 'CORE_ARTIFACT_DIGEST=' 'CORE_ARTIFACT_TARBALL='; do
  if ! grep -q "^${key}" "$TRAILER_FILE"; then
    echo "error: the assembler did not emit ${key} on stdout" >&2
    exit 1
  fi
done
