#!/usr/bin/env bash
cd "$(dirname "$0")"
source ../common.sh
[ -f topo.clab.yml ] && clab destroy -t topo.clab.yml --cleanup || true   # lab first, then cluster
kind delete cluster --name lab
