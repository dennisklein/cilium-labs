#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium install --context "kind-${CLUSTER}" --version "$CILIUM_VERSION" --values values.yaml --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443
echo "No tunnel now. Check node routes: docker exec lab-worker ip route | grep 10.244"
echo "Then: cilium connectivity test"
echo "Behind a proxy / no direct internet? Skip the world tests:"
echo "  cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'"
