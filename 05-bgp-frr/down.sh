#!/usr/bin/env bash
cd "$(dirname "$0")"
[ -f topo.clab.yml ] && sudo containerlab destroy -t topo.clab.yml --cleanup || true   # lab first, then cluster
kind delete cluster --name lab
