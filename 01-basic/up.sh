#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium install --context "kind-${CLUSTER}" --version "$CILIUM_VERSION" --values values.yaml --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443
echo "Done. Try: cilium status && cilium connectivity test   (needs cilium-cli)"
