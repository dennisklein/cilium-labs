#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium_install values.yaml
echo "No tunnel now. Check node routes: docker exec lab-worker ip route | grep 10.244"
echo "Then: cilium connectivity test"
echo "Behind a proxy / no direct internet? Skip the world tests:"
echo "  cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'"
