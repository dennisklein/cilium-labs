#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
command -v containerlab >/dev/null || { echo "missing containerlab"; exit 1; }
kind_up kind.yaml
cilium_install values.yaml
export KIND_SUBNET="$(kind_subnet)"
export FRR_IP="$(echo "$KIND_SUBNET" | cut -d. -f1,2).0.100"
envsubst '${KIND_SUBNET} ${FRR_IP}' < frr/frr.conf.tpl > build/frr.conf
k label nodes --all bgp=enabled --overwrite
wait_crds ciliumbgpclusterconfigs.cilium.io ciliumbgppeerconfigs.cilium.io ciliumbgpadvertisements.cilium.io ciliumloadbalancerippools.cilium.io
envsubst '${FRR_IP}' < bgp.yaml.tpl | k apply -f -
k apply -f ../common/pool-10.200.yaml -f ../common/demo-lb.yaml
envsubst '${KIND_SUBNET} ${FRR_IP}' < topo.clab.yml.tpl > topo.clab.yml   # rendered here: no `sudo -E` needed
sudo containerlab deploy -t topo.clab.yml --reconfigure
for i in $(seq 30); do   # wait for the first session instead of a blind sleep
  docker exec clab-bgp-lab-frr vtysh -c 'show bgp summary json' 2>/dev/null | grep -q Established && break
  sleep 2
done
sleep 5   # let the remaining nodes establish
echo "--- BGP sessions on FRR:"
docker exec clab-bgp-lab-frr vtysh -c 'show bgp summary'
docker exec clab-bgp-lab-frr vtysh -c 'show ip route bgp'
IP=$(k get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "--- FRR -> LB IP $IP:"
docker exec clab-bgp-lab-frr wget -qO- -T3 "http://$IP" | head -n 4
