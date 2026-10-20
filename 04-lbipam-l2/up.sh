#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium_install values.yaml
export PREFIX="$(kind_subnet | cut -d. -f1,2)"
wait_crds ciliumloadbalancerippools.cilium.io ciliuml2announcementpolicies.cilium.io
envsubst < l2.yaml.tpl | k apply -f -
k apply -f ../common/demo-lb.yaml
sleep 10
IP=$(k get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LB IP: $IP  -> curl from the host (Linux, same docker bridge):"
curl -s -m 5 "http://$IP" | head -n 4 || echo "not reachable yet; check the L2 announcement leases: kubectl -n kube-system get lease | grep l2"
