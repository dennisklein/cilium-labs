# Sourced by the stage tasks. mise provides [env] (CLUSTER, KUBECONFIG, optional CILIUM_VERSION) and [tools].
# KUBECONFIG is per stage, so kubectl and cilium need no --context (stage 07 is the exception).
set -euo pipefail

kind_up() {  # [kind config], default kind.yaml
  mkdir -p "$(dirname "$KUBECONFIG")"
  kind create cluster --name "$CLUSTER" --config "${1:-kind.yaml}"
}

cilium_up() {  # extra flags (--set, --context) are passed through
  cilium install ${CILIUM_VERSION:+--version "$CILIUM_VERSION"} --values values.yaml \
    --set k8sServiceHost="${API_HOST:-${CLUSTER}-control-plane}" --set k8sServicePort=6443 "$@"
}

# sudo resets PATH, so pass the mise-managed binary by absolute path
clab() { sudo "$(command -v containerlab)" "$@"; }

wait_crds() { for c in "$@"; do until kubectl get crd "$c" >/dev/null 2>&1; do sleep 2; done; done; }

# IPv4 subnet of the docker network used by kind, e.g. 172.18.0.0/16
kind_subnet() {
  docker network inspect kind -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | grep -v ':' | head -n1
}

wait_bgp() {  # <frr container>: wait for the first established session instead of a blind sleep
  for _ in $(seq 30); do
    docker exec "$1" vtysh -c 'show bgp summary json' 2>/dev/null | grep -q Established && return
    sleep 2
  done
}
