# 01 – Basic: kind + Cilium (VXLAN tunnel)

**Scope.** The smallest useful setup: a 3-node kind cluster (1 control plane + 2 workers) whose default CNI is
disabled and replaced by Cilium. Pod-to-pod traffic between nodes is encapsulated in **VXLAN**; kube-proxy is
still running. Use it as the baseline every other lab builds on.

**What you learn**
- Why kind needs `disableDefaultCNI: true` (nodes stay `NotReady` until a CNI exists).
- Installing Cilium with Helm and what `ipam.mode: kubernetes` means (pod CIDRs come from the kind nodes).
- Running Cilium's own end-to-end check, `cilium connectivity test`.

**Run / verify / tear down**
```bash
mise run up
mise run check   # the probes only; run again at any time
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i routing   # Network: Tunnel [vxlan]
cilium connectivity test        # behind a proxy / no direct internet: see ../03-native-routing/mise-tasks/check for the skip filter
mise run down
```

**Gotchas**
- Pods can't reach the internet directly if your host only has a proxy; the *world* connectivity tests will time out (not a Cilium problem).
- `kind get nodes` needs `--name lab` (or `export KIND_CLUSTER_NAME=lab`).

**Docs**
- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/
- kind configuration (`networking.disableDefaultCNI`): https://kind.sigs.k8s.io/docs/user/configuration/
- Cilium Helm values: https://docs.cilium.io/en/stable/helm-reference/
