#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
command -v cilium >/dev/null || { echo "missing cilium-cli"; exit 1; }
command -v jq >/dev/null || { echo "missing jq"; exit 1; }

kind create cluster --config kind-mesh1.yaml
kind create cluster --config kind-mesh2.yaml

# Shared CA: copy mesh1's CA into mesh2 BEFORE installing Cilium there
export CLUSTER=mesh1; cilium install --context "kind-${CLUSTER}" --version "$CILIUM_VERSION" --values values.yaml --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443 --set cluster.name=mesh1 --set cluster.id=1
kubectl --context kind-mesh1 -n kube-system get secret cilium-ca -o json \
  | jq 'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields)' \
  | kubectl --context kind-mesh2 -n kube-system apply -f -
export CLUSTER=mesh2; cilium install --context "kind-${CLUSTER}" --version "$CILIUM_VERSION" --values values.yaml --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443 --set cluster.name=mesh2 --set cluster.id=2

cilium clustermesh connect --context kind-mesh1 --destination-context kind-mesh2
cilium clustermesh status --context kind-mesh1 --wait

for n in 1 2; do
  NAME=mesh$n envsubst < demo.yaml.tpl | kubectl --context kind-mesh$n apply -f -
  kubectl --context kind-mesh$n wait --for=condition=Ready pod --all --timeout=120s
done
echo "--- waiting until mesh1 gets replies from BOTH clusters (up to ~2 min)..."
ok=0
for t in $(seq 24); do
  out=$(for i in $(seq 20); do kubectl --context kind-mesh1 exec client -- curl -s http://echo:5678; done | sort | uniq -c)
  if echo "$out" | grep -q mesh1 && echo "$out" | grep -q mesh2; then ok=1; break; fi
  sleep 5
done
echo "$out"
[ "$ok" = 1 ] && echo "OK: global service balances across both clusters" || echo "FAIL: only one cluster answers (see README troubleshooting)"
