#!/usr/bin/env bash
# Sourced by every stage's up.sh / down.sh
set -euo pipefail
# Versions and CLUSTER come from mise.toml [env]; tools come from mise.toml [tools].
: "${CILIUM_VERSION:?not set: run the stage inside the mise environment (mise activate, or mise x -- ./NN-xxx/up.sh)}"
: "${CLUSTER:?not set: run the stage inside the mise environment}"

for t in docker kind kubectl helm envsubst; do
  command -v "$t" >/dev/null || { echo "missing prerequisite: $t (mise install; docker comes from the OS)"; exit 1; }
done

# sudo resets PATH, so pass the mise-managed binary by absolute path
clab() { sudo "$(command -v containerlab)" "$@"; }

k() { kubectl --context "kind-${CLUSTER}" "$@"; }

kind_up() { kind create cluster --config "$1"; }

wait_crds() { for c in "$@"; do until k get crd "$c" >/dev/null 2>&1; do sleep 2; done; done; }

# IPv4 subnet of the docker network used by kind, e.g. 172.18.0.0/16
kind_subnet() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | grep -v ':' | head -n1
}
