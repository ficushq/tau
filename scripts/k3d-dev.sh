#!/usr/bin/env bash
#
# k3d Local Dev Management
#
# Manages the local k3d cluster for Tau sandbox development.
#
# Usage:
#   k3d-dev.sh setup          Create cluster, namespace, PVC, build & push image
#   k3d-dev.sh start          Start a stopped cluster
#   k3d-dev.sh stop           Stop the cluster (preserves state, frees resources)
#   k3d-dev.sh status         Show cluster status, pods, PVC
#   k3d-dev.sh logs [pod]     Tail logs from a sandbox pod (latest if no name given)
#   k3d-dev.sh shell [pod]    Shell into a sandbox pod
#   k3d-dev.sh pods           List sandbox pods
#   k3d-dev.sh kill [pod]     Kill a sandbox pod (or all if no name given)
#   k3d-dev.sh import         Rebuild sandbox image and push to local registry
#   k3d-dev.sh teardown       Delete the entire cluster (destructive!)
#
# The cluster mounts ~/.tau into the k3d node so sandbox pods and the
# host API share workspace/memory/ssh data via a static PV/PVC.

set -euo pipefail

CLUSTER_NAME="tau-dev"
NAMESPACE="tau-sandboxes-dev"
KUBECTL_CONTEXT="${FICUS_K8S_CONTEXT:-k3d-tau-dev-token}"
REGISTRY_CONTAINER="tau-registry"
K3D_NETWORK="${FICUS_K3D_NETWORK:-tau-dev}"
REGISTRY_HOST_PORT="${FICUS_K3D_REGISTRY_PORT:-5001}"
REGISTRY_ENDPOINT="${REGISTRY_CONTAINER}:5000"
REGISTRY_IMAGE="localhost:${REGISTRY_HOST_PORT}/tau-sandbox:latest"
SANDBOX_IMAGE="${REGISTRY_ENDPOINT}/tau-sandbox:latest"
AGENT_REGISTRY_IMAGE="localhost:${REGISTRY_HOST_PORT}/tau-sandbox-agent:latest"
AGENT_SANDBOX_IMAGE="${REGISTRY_ENDPOINT}/tau-sandbox-agent:latest"
FICUS_HOME="${HOME}/.tau"
HOST_IP_FILE="${FICUS_HOME}/.k3d-host-ip"
REGISTRY_CONFIG_FILE="${FICUS_HOME}/k3d-registries.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${GREEN}[k3d]${NC} $*"; }
warn() { echo -e "${YELLOW}[k3d]${NC} $*"; }
err()  { echo -e "${RED}[k3d]${NC} $*" >&2; }
kctl() { kubectl --context "${KUBECTL_CONTEXT}" "$@"; }

cluster_exists() {
  k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""
}

cluster_running() {
  local status
  status=$(docker inspect -f '{{.State.Running}}' "k3d-${CLUSTER_NAME}-server-0" 2>/dev/null || echo "false")
  [[ "$status" == "true" ]]
}

ensure_running() {
  if ! command -v k3d &>/dev/null; then
    err "k3d is not installed. Run: bun run k3d:setup"
    exit 1
  fi
  if ! cluster_exists; then
    err "Cluster '${CLUSTER_NAME}' does not exist. Run: bun run k3d:setup"
    exit 1
  fi
  if ! cluster_running; then
    err "Cluster '${CLUSTER_NAME}' is stopped. Run: bun run k3d:start"
    exit 1
  fi
}

# Get the latest sandbox pod name
latest_pod() {
  kctl -n "${NAMESPACE}" get pods \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null
}

# Detect the IP that routes from inside Docker/k3d to the host.
# OrbStack auto-injects host.docker.internal; Linux Docker and Docker Desktop
# use the host-gateway flag. The resolved IP is universally reachable from
# any container/pod within the runtime, and the API binds 0.0.0.0 so any
# host-owned IP works.
detect_host_alias_ip() {
  local ip
  if docker info 2>/dev/null | grep -qi orbstack; then
    ip=$(docker run --rm alpine sh -c 'getent hosts host.docker.internal | awk "{print \$1}"' 2>/dev/null || echo "198.19.249.2")
    log "Detected OrbStack — using ${ip} for host.k3d.internal" >&2
  else
    ip=$(docker run --rm --add-host=host.docker.internal:host-gateway alpine sh -c 'getent hosts host.docker.internal | awk "{print \$1}"' 2>/dev/null || echo "172.17.0.1")
    log "Detected Docker / Docker Desktop — using ${ip} for host.k3d.internal" >&2
  fi
  echo "${ip}"
}

# Persist the host IP so apps/core/.../pod-manager.ts can inject it into
# every sandbox pod's hostAliases. k3d's --host-alias flag is unreliable
# across versions (silently dropped in v5.8.3); pod-spec hostAliases is
# always honored by kubelet.
write_host_ip() {
  local ip="$1"
  mkdir -p "${FICUS_HOME}"
  echo "${ip}" > "${HOST_IP_FILE}"
  log "Wrote ${HOST_IP_FILE}"
}

native_linux_docker() {
  local os
  os=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo "")
  [[ "${os}" == Linux* || "${os}" == Ubuntu* || "${os}" == Debian* || "${os}" == Fedora* || "${os}" == CentOS* ]]
}

k3d_network_gateway() {
  docker network inspect "${K3D_NETWORK}" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || \
    docker network inspect "k3d-${CLUSTER_NAME}" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || \
    true
}

write_reachable_host_ip_after_cluster_create() {
  # On native Linux Docker, Docker's default bridge gateway (often 172.17.0.1)
  # may be unreachable from pods attached to the k3d network. The k3d network
  # gateway is the reliable route back to host-bound services.
  #
  # On Docker Desktop / macOS / OrbStack, host.docker.internal is the portable
  # host route; keep the value selected by detect_host_alias_ip().
  if native_linux_docker; then
    local ip
    ip=$(k3d_network_gateway)
    if [[ -n "${ip}" ]]; then
      write_host_ip "${ip}"
    else
      warn "Could not determine k3d network gateway; leaving ${HOST_IP_FILE} unchanged"
    fi
  else
    log "Keeping host.k3d.internal IP selected for Docker Desktop / OrbStack"
  fi
}

format_bytes() {
  local bytes="${1:-0}"
  if [[ "${bytes}" -ge 1073741824 ]]; then
    awk -v b="${bytes}" 'BEGIN { printf "%.1fGiB", b / 1073741824 }'
  elif [[ "${bytes}" -ge 1048576 ]]; then
    awk -v b="${bytes}" 'BEGIN { printf "%.1fMiB", b / 1048576 }'
  else
    echo "${bytes}B"
  fi
}

image_archive_bytes() {
  docker exec "k3d-${CLUSTER_NAME}-server-0" sh -c 'find /k3d/images -name "*.tar" -type f -exec stat -c %s {} + 2>/dev/null | awk "{sum+=\$1} END {print sum+0}"' 2>/dev/null || echo "0"
}

cleanup_import_archives() {
  if ! cluster_running; then
    return
  fi

  local bytes remaining_archive_bytes
  bytes=$(image_archive_bytes)
  if ! docker exec "k3d-${CLUSTER_NAME}-server-0" sh -c 'find /k3d/images -name "*.tar" -type f -delete' 2>/dev/null; then
    warn "Failed to remove stale k3d image import archives from /k3d/images"
    return
  fi

  remaining_archive_bytes=$(image_archive_bytes)
  if [[ "${remaining_archive_bytes:-0}" -gt 0 ]]; then
    warn "Removed some k3d image import archives, but $(format_bytes "${remaining_archive_bytes}") remain in /k3d/images"
  else
    log "Removed stale k3d image import archives from /k3d/images ($(format_bytes "${bytes}"))"
  fi
}

prune_node_images() {
  if ! cluster_running; then
    return
  fi
  # Drop node images no longer referenced by any pod. Repeated `import` rebuilds leave the previous
  # tau-sandbox:latest generations as unreferenced layers in containerd's overlay snapshotter — the
  # top disk consumer when the node hits DiskPressure (which evicts every sandbox at once). Pruning
  # on each import keeps that store from growing unbounded.
  if docker exec "k3d-${CLUSTER_NAME}-server-0" crictl rmi --prune >/dev/null 2>&1; then
    log "Pruned unused node images from containerd (stale sandbox layers)"
  else
    warn "Failed to prune unused node images (crictl rmi --prune)"
  fi
}

write_registry_config() {
  mkdir -p "${FICUS_HOME}"
  cat > "${REGISTRY_CONFIG_FILE}" <<EOF
mirrors:
  "${REGISTRY_ENDPOINT}":
    endpoint:
      - "http://${REGISTRY_ENDPOINT}"
EOF
  log "Wrote ${REGISTRY_CONFIG_FILE} for local registry ${REGISTRY_ENDPOINT}"
}

ensure_registry() {
  log "Ensuring local registry is running via docker compose..."
  docker compose up -d registry

  if cluster_running; then
    if ! docker inspect "${REGISTRY_CONTAINER}" >/dev/null 2>&1; then
      err "Registry container ${REGISTRY_CONTAINER} is not running"
      exit 1
    fi

    for network in "${K3D_NETWORK}" "k3d-${CLUSTER_NAME}"; do
      if ! docker network inspect "${network}" >/dev/null 2>&1; then
        continue
      fi
      if ! docker inspect "${REGISTRY_CONTAINER}" --format '{{json .NetworkSettings.Networks}}' | grep -q "${network}"; then
        docker network connect "${network}" "${REGISTRY_CONTAINER}" 2>/dev/null || true
        log "Attached ${REGISTRY_CONTAINER} to ${network} network"
      fi
    done
  fi
}

ensure_node_registry_config() {
  if ! cluster_running; then
    return
  fi

  write_registry_config
  if docker exec "k3d-${CLUSTER_NAME}-server-0" sh -c "test -f /etc/rancher/k3s/registries.yaml && grep -q '${REGISTRY_ENDPOINT}' /etc/rancher/k3s/registries.yaml" 2>/dev/null; then
    return
  fi

  log "Installing local registry config into existing k3d node..."
  docker exec "k3d-${CLUSTER_NAME}-server-0" mkdir -p /etc/rancher/k3s
  docker cp "${REGISTRY_CONFIG_FILE}" "k3d-${CLUSTER_NAME}-server-0:/etc/rancher/k3s/registries.yaml"
  warn "Restarting k3d cluster once so containerd picks up the local registry config..."
  k3d cluster stop "${CLUSTER_NAME}"
  k3d cluster start "${CLUSTER_NAME}"
  kctl wait --for=condition=Ready node --all --timeout=60s
  ensure_registry
}

build_and_push_sandbox_image() {
  local build_platform="linux/$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"

  # One multi-stage Dockerfile, two targets. BuildKit builds and caches the
  # shared `base` stage once, reused across both --target builds.
  log "Building squad sandbox image (${build_platform})..."
  docker build --platform "${build_platform}" --target squad -t "${REGISTRY_IMAGE}" -f "${REPO_ROOT}/packages/k8s-sandbox/Dockerfile" "${REPO_ROOT}"
  log "Building agent (light) sandbox image..."
  docker build --platform "${build_platform}" --target agent -t "${AGENT_REGISTRY_IMAGE}" -f "${REPO_ROOT}/packages/k8s-sandbox/Dockerfile" "${REPO_ROOT}"

  log "Pushing sandbox images to local registry (${SANDBOX_IMAGE}, ${AGENT_SANDBOX_IMAGE})..."
  docker push "${REGISTRY_IMAGE}"
  docker push "${AGENT_REGISTRY_IMAGE}"
}

# ─── Commands ──────────────────────────────────────────────────────────────

cmd_setup() {
  # --- Check prerequisites ---
  if ! command -v docker &>/dev/null; then
    err "Docker is required. Install Docker Desktop first."
    exit 1
  fi
  if ! docker info &>/dev/null; then
    err "Docker daemon is not running. Start Docker Desktop first."
    exit 1
  fi
  if ! command -v kubectl &>/dev/null; then
    err "kubectl is required. Install with: brew install kubectl"
    exit 1
  fi

  # --- Install k3d if missing ---
  if ! command -v k3d &>/dev/null; then
    log "Installing k3d via Homebrew..."
    brew install k3d
  fi

  # --- Check if cluster already exists ---
  if cluster_exists; then
    warn "Cluster '${CLUSTER_NAME}' already exists."
    if ! cluster_running; then
      log "Starting stopped cluster..."
      cmd_start
    else
      ensure_registry
      ensure_node_registry_config
    fi
    echo ""
    echo "  To rebuild & push image: bun run k3d:import"
    echo "  To destroy and recreate:   bun run k3d:teardown && bun run k3d:setup"
    echo ""
    return
  fi

  ensure_registry

  # --- Ensure ~/.tau directories exist ---
  log "Ensuring ${FICUS_HOME} directories..."
  mkdir -p "${FICUS_HOME}/workspaces/squads"
  mkdir -p "${FICUS_HOME}/workspaces/agents"
  mkdir -p "${FICUS_HOME}/memory"
  mkdir -p "${FICUS_HOME}/ssh"
  mkdir -p "${FICUS_HOME}/nix"
  mkdir -p "${FICUS_HOME}/sessions"

  # --- Detect host alias IP and persist for pod-manager ---
  local HOST_ALIAS_IP
  HOST_ALIAS_IP=$(detect_host_alias_ip)
  write_host_ip "${HOST_ALIAS_IP}"

  # --- Create k3d cluster ---
  write_registry_config
  log "Creating k3d cluster '${CLUSTER_NAME}'..."
  k3d cluster create "${CLUSTER_NAME}" \
    --agents 0 \
    --volume "${FICUS_HOME}:/tau-data" \
    --network "${K3D_NETWORK}" \
    --no-lb \
    --registry-config "${REGISTRY_CONFIG_FILE}" \
    --k3s-arg "--disable=traefik@server:0" \
    --host-alias "${HOST_ALIAS_IP}:host.k3d.internal"

  ensure_registry

  log "Waiting for node to be ready..."
  kubectl wait --for=condition=Ready node --all --timeout=60s

  write_reachable_host_ip_after_cluster_create

  # --- Create namespace ---
  log "Creating namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}"

  # --- Create headless service ---
  log "Creating headless service..."
  kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: tau-sandboxes
spec:
  clusterIP: None
  selector:
    app: tau-sandbox
  ports:
    - port: 50051
      targetPort: 50051
      name: http
EOF

  # --- Create static PV + PVC ---
  log "Creating PersistentVolume and PersistentVolumeClaim..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: tau-core-data-local
  labels:
    type: local
    app: tau-dev
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /tau-data
    type: Directory
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: ${NAMESPACE}
    name: tau-core-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tau-core-data
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: ""
  volumeName: tau-core-data-local
EOF

  log "Waiting for PVC to bind..."
  kubectl wait -n "${NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound pvc/tau-core-data --timeout=30s

  # --- Create service account with token auth ---
  # Bun's node-fetch compatibility doesn't pass client certificates through
  # HTTPS agents, so the default kubeconfig (client-cert auth) doesn't work.
  # Create a service account with a long-lived token and configure kubectl
  # to use it instead.
  log "Creating service account for token-based auth..."
  kubectl -n "${NAMESPACE}" create serviceaccount tau-dev 2>/dev/null || true
  kubectl create clusterrolebinding tau-dev-admin \
    --clusterrole=cluster-admin \
    --serviceaccount="${NAMESPACE}:tau-dev" 2>/dev/null || true

  local token
  token=$(kubectl -n "${NAMESPACE}" create token tau-dev --duration=87600h)

  # Add token-based user and context to kubeconfig
  kubectl config set-credentials tau-dev-token --token="${token}"
  kubectl config set-context k3d-tau-dev-token \
    --cluster="k3d-${CLUSTER_NAME}" \
    --user=tau-dev-token \
    --namespace="${NAMESPACE}"
  kubectl config use-context k3d-tau-dev-token

  log "Configured kubectl to use token auth (context: k3d-tau-dev-token)"

  # --- Build and push sandbox image ---
  # Use native arch for local dev (arm64 on Apple Silicon, amd64 on Intel).
  # Production builds use --platform linux/amd64 explicitly.
  build_and_push_sandbox_image
  cleanup_import_archives
  prune_node_images

  # --- Done ---
  echo ""
  echo -e "${GREEN}════════════════════════════════════════${NC}"
  echo -e "${GREEN} k3d dev cluster ready!${NC}"
  echo -e "${GREEN}════════════════════════════════════════${NC}"
  echo ""
  echo "  Add to your .env:"
  echo ""
  echo "    FICUS_SANDBOX_RUNTIME=k8s"
  echo "    FICUS_K8S_LOCAL=true"
  echo "    FICUS_K8S_NAMESPACE=${NAMESPACE}"
  echo "    FICUS_K8S_RUNTIME_CLASS="
  echo "    FICUS_SANDBOX_IMAGE=${SANDBOX_IMAGE}"
  echo ""
  echo "  Then restart: bun run reload:core"
  echo ""
  echo "  Commands:"
  echo "    bun run k3d:status    — cluster & pod status"
  echo "    bun run k3d:pods      — list sandbox pods"
  echo "    bun run k3d:logs      — tail sandbox pod logs"
  echo "    bun run k3d:stop      — stop cluster (saves battery)"
  echo "    bun run k3d:start     — resume cluster"
  echo "    bun run k3d:import    — rebuild & push image"
  echo ""
}

cmd_start() {
  if ! command -v k3d &>/dev/null || ! cluster_exists; then
    err "Cluster '${CLUSTER_NAME}' does not exist. Run: bun run k3d:setup"
    exit 1
  fi
  if cluster_running; then
    log "Cluster is already running."
    return
  fi
  log "Starting cluster '${CLUSTER_NAME}'..."
  k3d cluster start "${CLUSTER_NAME}"
  log "Waiting for node to be ready..."
  kctl wait --for=condition=Ready node --all --timeout=60s
  write_reachable_host_ip_after_cluster_create
  ensure_registry
  ensure_node_registry_config
  log "Cluster started."
}

cmd_stop() {
  if ! command -v k3d &>/dev/null || ! cluster_exists; then
    warn "Cluster '${CLUSTER_NAME}' does not exist."
    return
  fi
  if ! cluster_running; then
    log "Cluster is already stopped."
    return
  fi
  log "Stopping cluster '${CLUSTER_NAME}'..."
  k3d cluster stop "${CLUSTER_NAME}"
  log "Cluster stopped. State is preserved — run 'bun run k3d:start' to resume."
}

cmd_status() {
  echo ""
  # Cluster status
  if ! command -v k3d &>/dev/null; then
    echo -e "  Cluster:  ${RED}k3d not installed${NC}"
    return
  fi
  if ! cluster_exists; then
    echo -e "  Cluster:  ${RED}not created${NC} — run: bun run k3d:setup"
    return
  fi
  if cluster_running; then
    echo -e "  Cluster:  ${GREEN}running${NC} (${CLUSTER_NAME})"
  else
    echo -e "  Cluster:  ${YELLOW}stopped${NC} — run: bun run k3d:start"
    return
  fi

  # Node
  echo -e "  Node:     $(kctl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && echo -e "${GREEN}ready${NC}" || echo -e "${YELLOW}not ready${NC}")"

  # PVC
  local pvc_status
  pvc_status=$(kctl -n "${NAMESPACE}" get pvc tau-core-data -o jsonpath='{.status.phase}' 2>/dev/null || echo "missing")
  if [[ "$pvc_status" == "Bound" ]]; then
    echo -e "  PVC:      ${GREEN}bound${NC} (tau-core-data → ~/.tau)"
  else
    echo -e "  PVC:      ${RED}${pvc_status}${NC}"
  fi

  # Image
  local image_loaded
  image_loaded=$(docker exec "k3d-${CLUSTER_NAME}-server-0" sh -c "crictl images -o json 2>/dev/null | grep -c \"${SANDBOX_IMAGE}\" || true" 2>/dev/null)
  image_loaded=${image_loaded:-0}
  if [[ "$image_loaded" -gt 0 ]]; then
    echo -e "  Image:    ${GREEN}loaded${NC} (${SANDBOX_IMAGE})"
  else
    echo -e "  Image:    ${YELLOW}not imported${NC} — run: bun run k3d:import"
  fi

  # Disk pressure early warning
  local node_disk_pct node_disk_line archive_bytes
  node_disk_pct=$(docker exec "k3d-${CLUSTER_NAME}-server-0" sh -c "df -P /var/lib/rancher/k3s | awk 'NR==2 {gsub(/%/, \"\", \$5); print \$5}'" 2>/dev/null || echo "0")
  node_disk_line=$(docker exec "k3d-${CLUSTER_NAME}-server-0" sh -c "df -h /var/lib/rancher/k3s | awk 'NR==2 {print \$3 \" used / \" \$2 \" (\" \$5 \")\"}'" 2>/dev/null || echo "unknown")
  node_disk_pct=${node_disk_pct:-0}
  node_disk_line=${node_disk_line:-unknown}
  archive_bytes=$(image_archive_bytes)
  if [[ "${node_disk_line}" == "unknown" ]]; then
    echo -e "  Node disk: ${YELLOW}unknown${NC} — could not read k3d node disk usage"
  elif [[ "${node_disk_pct}" -ge 80 ]]; then
    echo -e "  Node disk: ${YELLOW}${node_disk_line}${NC} — kubelet image GC starts near 85%"
  else
    echo -e "  Node disk: ${GREEN}${node_disk_line}${NC}"
  fi
  if [[ "${archive_bytes:-0}" -gt 0 ]]; then
    echo -e "  Image archives: ${YELLOW}$(format_bytes "${archive_bytes}")${NC} in /k3d/images — removed after next import"
  else
    echo -e "  Image archives: ${GREEN}none${NC} in /k3d/images"
  fi

  echo ""

  # Pods
  echo -e "  ${BLUE}Sandbox Pods:${NC}"
  local pods
  pods=$(kctl -n "${NAMESPACE}" get pods -o wide --no-headers 2>/dev/null)
  if [[ -z "$pods" ]]; then
    echo -e "  ${DIM}  (none)${NC}"
  else
    echo "$pods" | while IFS= read -r line; do
      echo "    $line"
    done
  fi
  echo ""
}

cmd_pods() {
  ensure_running
  kctl -n "${NAMESPACE}" get pods -o wide
}

cmd_logs() {
  ensure_running
  local pod="${1:-}"
  if [[ -z "$pod" ]]; then
    pod=$(latest_pod)
    if [[ -z "$pod" ]]; then
      err "No sandbox pods found."
      exit 1
    fi
    log "Tailing logs for latest pod: ${pod}"
  fi
  kctl -n "${NAMESPACE}" logs -f --tail 200 "$pod"
}

cmd_shell() {
  ensure_running
  local pod="${1:-}"
  if [[ -z "$pod" ]]; then
    pod=$(latest_pod)
    if [[ -z "$pod" ]]; then
      err "No sandbox pods found."
      exit 1
    fi
    log "Connecting to latest pod: ${pod}"
  fi
  kctl -n "${NAMESPACE}" exec -it "$pod" -- bash
}

cmd_kill() {
  ensure_running
  local pod="${1:-}"
  if [[ -z "$pod" ]]; then
    log "Killing all sandbox pods..."
    kctl -n "${NAMESPACE}" delete pods --all --force 2>/dev/null || true
    log "All pods killed. They will be recreated on next use."
  else
    log "Killing pod: ${pod}"
    kctl -n "${NAMESPACE}" delete pod "$pod" --force 2>/dev/null || true
    log "Pod killed. It will be recreated on next use."
  fi
}

cmd_import() {
  if ! cluster_exists; then
    err "Cluster '${CLUSTER_NAME}' does not exist. Run: bun run k3d:setup"
    exit 1
  fi
  if ! cluster_running; then
    err "Cluster is stopped. Run: bun run k3d:start"
    exit 1
  fi

  ensure_registry
  ensure_node_registry_config
  build_and_push_sandbox_image
  cleanup_import_archives
  prune_node_images

  log "Done! Kill running pods to pick up the new image: bun run k3d:kill"
}

cmd_teardown() {
  if ! command -v k3d &>/dev/null; then
    warn "k3d is not installed. Nothing to tear down."
    return
  fi
  if ! cluster_exists; then
    warn "Cluster '${CLUSTER_NAME}' does not exist."
    return
  fi

  echo -e "${YELLOW}This will delete the k3d cluster and all running pods.${NC}"
  echo -e "${YELLOW}Data in ~/.tau/ is preserved.${NC}"
  echo ""
  read -r -p "Continue? [y/N] " confirm
  if [[ "$confirm" == "*[yY]*" ]]; then
    log "Cancelled."
    return
  fi

  log "Deleting cluster '${CLUSTER_NAME}'..."
  k3d cluster delete "${CLUSTER_NAME}"
  kubectl delete pv tau-core-data-local 2>/dev/null || true
  log "Done. Data in ~/.tau/ is preserved."
}

cmd_help() {
  echo ""
  echo "Usage: k3d-dev.sh <command> [args]"
  echo ""
  echo "Commands:"
  echo "  setup          Create cluster, build & push image"
  echo "  start          Start a stopped cluster"
  echo "  stop           Stop cluster (preserves state, frees resources)"
  echo "  status         Show cluster status, pods, PVC"
  echo "  pods           List sandbox pods"
  echo "  logs [pod]     Tail logs (latest pod if none specified)"
  echo "  shell [pod]    Shell into a pod (latest if none specified)"
  echo "  kill [pod]     Kill a pod (all pods if none specified)"
  echo "  import         Rebuild sandbox image and push to local registry"
  echo "  teardown       Delete entire cluster (destructive!)"
  echo ""
}

# ─── Main ──────────────────────────────────────────────────────────────────

case "${1:-help}" in
  setup)    cmd_setup ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  pods)     cmd_pods ;;
  logs)     cmd_logs "${2:-}" ;;
  shell)    cmd_shell "${2:-}" ;;
  kill)     cmd_kill "${2:-}" ;;
  import)   cmd_import ;;
  teardown) cmd_teardown ;;
  help|-h|--help) cmd_help ;;
  *)
    err "Unknown command: $1"
    cmd_help
    exit 1
    ;;
esac
