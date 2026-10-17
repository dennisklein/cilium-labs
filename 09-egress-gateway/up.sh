#!/usr/bin/env bash
cd "$(dirname "$0")"; export CLUSTER=egress; source ../common.sh
command -v containerlab >/dev/null || { echo "missing containerlab"; exit 1; }
SRV=clab-cilium-egress-server

kind_up kind.yaml
cilium_install values.yaml
k label node egress-worker  egress-gw=a --overwrite
k label node egress-worker2 egress-gw=b --overwrite
wait_crds ciliumegressgatewaypolicies.cilium.io
k apply -f demo.yaml

sudo containerlab deploy -t topo.clab.yml --reconfigure

# Gateway side: uplink address + the egress IP (must exist on the node) + route to the server network
wire() { # <container> <uplink ip> <egress ip> <router ip>
  docker exec "$1" ip addr add "$2/24" dev eth1 2>/dev/null || true
  docker exec "$1" ip addr add "$3/24" dev eth1 2>/dev/null || true
  docker exec "$1" ip link set eth1 up
  docker exec "$1" ip route replace 10.30.2.0/24 via "$4" dev eth1
}
wire egress-worker  10.30.1.1 10.30.1.100 10.30.1.254
wire egress-worker2 10.30.3.1 10.30.3.100 10.30.3.254
k -n kube-system rollout restart ds/cilium && k -n kube-system rollout status ds/cilium
k wait --for=condition=Ready pod/client-egress pod/client-plain --timeout=120s

try() { k exec "$1" -- curl -s -o /dev/null -m 3 -w '%{http_code}' http://10.30.2.2 2>/dev/null || true; }
wait_ok() { for i in $(seq 15); do [ "$(try client-egress)" = 200 ] && return 0; sleep 2; done; return 1; }

echo "--- 1) no policy: the server network is only routable from the gateway nodes (expect 000 = unreachable)"
echo "client-egress: $(try client-egress)"
echo "--- 2) policy via gateway A (egress IP 10.30.1.100)"
k apply -f policy-a.yaml
wait_ok && echo "client-egress: 200" || echo "client-egress: FAILED (see README)"
echo "client-plain (not selected): $(try client-plain)"
echo "server saw:"; docker logs "$SRV" 2>&1 | tail -n 2
echo "--- 3) move to gateway B (egress IP 10.30.3.100)"
k delete -f policy-a.yaml >/dev/null; k apply -f policy-b.yaml
sleep 5; wait_ok && echo "client-egress: 200" || echo "client-egress: FAILED (see README)"
echo "server saw:"; docker logs "$SRV" 2>&1 | tail -n 2
echo "--- datapath entries"
k -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
