#!/usr/bin/env bash
# Sourced by every stage's up.sh / down.sh
set -euo pipefail
export CILIUM_VERSION="${CILIUM_VERSION:-1.18.0}"   # bump to latest 1.18.x patch if you like
export CLUSTER="${CLUSTER:-lab}"                    # must match `name:` in the stage's kind.yaml

for t in docker kind kubectl helm envsubst; do
  command -v "$t" >/dev/null || { echo "missing prerequisite: $t"; exit 1; }
done

k() { kubectl --context "kind-${CLUSTER}" "$@"; }

kind_up() { kind create cluster --config "$1"; }

cilium_install() {
  local values="$1"; shift
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
    --kube-context "kind-${CLUSTER}" -n kube-system -f "$values" \
    --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443 "$@"
  k -n kube-system rollout status ds/cilium --timeout=300s
  k -n kube-system rollout status deploy/cilium-operator --timeout=300s
  k wait --for=condition=Ready nodes --all --timeout=300s
}

wait_crds() { for c in "$@"; do until k get crd "$c" >/dev/null 2>&1; do sleep 2; done; done; }

# IPv4 subnet of the docker network used by kind, e.g. 172.18.0.0/16
kind_subnet() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | grep -v ':' | head -n1
}
