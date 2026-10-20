#!/usr/bin/env bash
cd "$(dirname "$0")"
source ../common.sh
clab destroy -t topo.clab.yml --cleanup || true
kind delete cluster --name egress
