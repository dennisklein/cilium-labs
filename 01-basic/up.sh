#!/usr/bin/env bash
cd "$(dirname "$0")"; source ../common.sh
kind_up kind.yaml
cilium_install values.yaml
echo "Done. Try: cilium status && cilium connectivity test   (needs cilium-cli)"
