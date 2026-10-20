#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium install --context "kind-${CLUSTER}" --version "$CILIUM_VERSION" --values values.yaml --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443
k apply -f demo.yaml
k -n demo wait --for=condition=Ready pod --all --timeout=120s
echo "--- allowed:";  k -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server/
echo "--- denied (expect 403 from L7 proxy):"
k -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' -X POST http://server/
echo "Hubble UI: cilium hubble ui   |  flows: hubble observe -n demo"
