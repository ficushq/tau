#!/usr/bin/env bash
# apply-artifacts.sh — apply a platform-managed artifact staging directory to
# THIS host. The SYNC-path counterpart to setup-host.sh's phase_artifacts.
#
# The control plane copies this script, lib.sh, and a complete artifact staging
# directory to a running managed instance, then runs as root:
#
#     bash apply-artifacts.sh <staging-dir>
#
# The staging dir is the FULL current artifact set (not a delta) and this
# script RECONCILES the host against it: managed.env is installed whole,
# every manifest-listed file is installed, and anything under
# /etc/tau/artifacts/ the manifest no longer lists is PRUNED (lib.sh's
# prune_artifacts — that is how an artifact DELETED from the platform registry
# leaves the fleet). It also ensures the tau units actually load managed.env
# (ensure_managed_env_dropins — hosts provisioned before the unit templates
# carried the EnvironmentFile line need a drop-in, or every sync is a silent
# no-op for the running processes). Same lib.sh functions a fresh provision
# uses, so a synced host and a freshly-provisioned host end up identical.
#
# It deliberately does NOT restart any service or daemon-reload: the executor
# owns those decisions, driven by the three marker lines this script prints as
# its LAST output (`systemctl restart` only when the managed environment
# actually changed, or when the API guardrail was repaired — file-kind artifacts are read per-use, e.g. APNs certs,
# so installing one never needs a restart; `systemctl daemon-reload` only
# when a drop-in was written). Credential contents are never echoed here.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

STAGE_DIR=${1:-}
[[ -n ${STAGE_DIR} ]] || die "usage: apply-artifacts.sh <staging-dir>"
[[ -d ${STAGE_DIR} ]] || die "apply-artifacts.sh: staging directory not found: ${STAGE_DIR}"

# Detect BEFORE installing (the install overwrites the file being compared).
ENV_CHANGED=$(managed_env_would_change "${STAGE_DIR}")

install_managed_env "${STAGE_DIR}"
install_artifacts "${STAGE_DIR}"
prune_artifacts "${STAGE_DIR}"
ensure_managed_env_dropins
ensure_tau_api_memory_guardrail
log_info "artifacts applied from ${STAGE_DIR}"

# Machine-readable markers for the sync executor (stdout; logs go to stderr).
# On exit 0 these three lines are ALWAYS present — the executor keys its
# daemon-reload/restart decisions off them.
echo "FICUS_MANAGED_ENV_CHANGED=${ENV_CHANGED}"
echo "FICUS_MANAGED_ENV_DROPIN_CHANGED=${MANAGED_ENV_DROPIN_CHANGED}"
echo "FICUS_API_MEMORY_GUARDRAIL_CHANGED=${FICUS_API_MEMORY_GUARDRAIL_CHANGED}"
