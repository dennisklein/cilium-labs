#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
docker network inspect kind -f '{{.EnableIPv6}}' 2>/dev/null | grep -q true \
  || echo "WARNING: could not confirm IPv6 on the docker 'kind' network (see README)."

# Use the control plane's IPv4 address for the API server: avoids the name resolving to IPv6 first
CPIP="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${CLUSTER}-control-plane")"
cilium_install values.yaml --set k8sServiceHost="$CPIP"

k apply -f demo.yaml
k wait --for=condition=Ready pod --all --timeout=120s

echo "--- pods (node and both IPs)"
k get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IPS:.status.podIPs[*].ip'
echo "--- Service cluster IPs (expect one IPv4 and one IPv6)"
k get svc web -o jsonpath='{.spec.clusterIPs}{"\n"}'
echo "--- client -> every web pod, per family (expect 200)"
for ip in $(k get pods -l app=web -o jsonpath='{.items[*].status.podIPs[*].ip}'); do
  case "$ip" in *:*) url="http://[$ip]" ;; *) url="http://$ip" ;; esac
  printf '%-30s ' "$ip"
  k exec client -- curl -s -o /dev/null -m 3 -w '%{http_code}\n' "$url" || echo FAIL
done
echo "--- via the Service name, forced family (expect 200)"
for f in 4 6; do
  printf 'IPv%s: ' "$f"
  k exec client -- curl "-$f" -s -o /dev/null -m 3 -w '%{http_code}\n' http://web || echo FAIL
done
echo "--- IPv6 pod-CIDR routes on a worker (native routing, one per remote node)"
docker exec "${CLUSTER}-worker" ip -6 route | grep fd00:10:244 || true
