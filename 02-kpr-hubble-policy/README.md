# 02 – kube-proxy replacement, Hubble, WireGuard, L7 policy

**Scope.** Same VXLAN topology as lab 01, but kube-proxy is **removed** (`kubeProxyMode: none`) and Cilium's eBPF
datapath handles Services (`kubeProxyReplacement: true`). Adds **Hubble** (flow observability), **WireGuard**
transparent encryption between nodes, and a demo **CiliumNetworkPolicy** that allows only `GET /` from `client` to `server`.

**What you learn**
- eBPF Service load-balancing without kube-proxy (`k8sServiceHost` is set to the control-plane container name).
- Seeing traffic with Hubble; enforcing policy at L3/L4 *and* L7 (HTTP method/path).
- Node-to-node encryption without sidecars.

**Run / verify / tear down**
```bash
mise run up        # prints 200 for GET and 403 for POST
mise run check   # the probes only; run again at any time
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -iE 'encryption|kubeproxy'
cilium hubble port-forward &   # then, with the hubble CLI installed: hubble observe -n demo
mise run down
```

**Gotchas**
- WireGuard needs kernel support (5.6+). If the agents fail, delete the `encryption:` block in `values.yaml`.
- The `hubble` CLI comes from `mise.toml`; the Hubble UI works through `cilium hubble ui`.

**Docs**
- kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Hubble: https://docs.cilium.io/en/stable/observability/hubble/
- WireGuard encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Network policy (incl. L7): https://docs.cilium.io/en/stable/security/policy/
- kind `kubeProxyMode`: https://kind.sigs.k8s.io/docs/user/configuration/
