#!/usr/bin/env bash
cd "$(dirname "$0")"
sudo containerlab destroy -t topo.clab.yml --cleanup || true
kind delete cluster --name egress
