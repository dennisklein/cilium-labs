#!/usr/bin/env bash
cd "$(dirname "$0")"; export CLUSTER=fabric; source ../common.sh
command -v containerlab >/dev/null || { echo "missing containerlab"; exit 1; }
kind_up kind.yaml
cilium install --context "kind-${CLUSTER}" --version "$CILIUM_VERSION" --values values.yaml --set k8sServiceHost="${CLUSTER}-control-plane" --set k8sServicePort=6443
k label node fabric-worker  rack=1 --overwrite
k label node fabric-worker2 rack=2 --overwrite
wait_crds ciliumbgpclusterconfigs.cilium.io ciliumloadbalancerippools.cilium.io
k apply -f ../common/pool-10.200.yaml -f bgp.yaml -f ../common/demo-lb.yaml

clab deploy -t topo.clab.yml --reconfigure

# Address the kind-node side of each uplink (containerlab only injects eth1)
wire() { # <container> <ip/31> <leaf ip>
  docker exec "$1" ip addr add "$2" dev eth1 2>/dev/null || true
  docker exec "$1" ip link set eth1 up
  docker exec "$1" ip route replace 10.10.20.0/24 via "$3" dev eth1   # return path to client
}
wire fabric-worker  10.10.1.1/31 10.10.1.0
wire fabric-worker2 10.10.2.1/31 10.10.2.0
k -n kube-system rollout restart ds/cilium && k -n kube-system rollout status ds/cilium
for i in $(seq 30); do
  docker exec clab-cilium-fabric-spine vtysh -c 'show bgp summary json' 2>/dev/null | grep -q Established && break
  sleep 2
done
sleep 5
docker exec clab-cilium-fabric-spine vtysh -c 'show bgp summary'
docker exec clab-cilium-fabric-spine vtysh -c 'show ip route bgp'
IP=$(k get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "--- client -> LB IP $IP via the fabric:"
docker exec clab-cilium-fabric-client curl -s -m 5 "http://$IP" | head -n 4
