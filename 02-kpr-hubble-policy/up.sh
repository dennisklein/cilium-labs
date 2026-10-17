#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium_install values.yaml
k apply -f demo.yaml
k -n demo wait --for=condition=Ready pod --all --timeout=120s
echo "--- allowed:";  k -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server/
echo "--- denied (expect 403 from L7 proxy):"
k -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' -X POST http://server/
echo "Hubble UI: cilium hubble ui   |  flows: hubble observe -n demo"
