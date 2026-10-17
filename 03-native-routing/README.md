# 03 – Native routing (no tunnel)

**Scope.** 4-node kind cluster where pod traffic is **routed directly** between nodes instead of encapsulated.
Each node gets a route to every other node's pod CIDR (`autoDirectNodeRoutes`), possible because all kind nodes
share one L2 segment (the Docker bridge). BPF masquerading is enabled for traffic leaving the pod CIDR.

**What you learn**
- Tunnel vs native routing and when native routing is possible (nodes on a shared L2 / routed fabric).
- `ipv4NativeRoutingCIDR` must match the kind `podSubnet` (`10.244.0.0/16` here).

**Run / verify / tear down**
```bash
./up.sh
docker exec lab-worker ip route | grep 10.244     # one route per remote node, via its 172.18.x.x address
cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
./down.sh
```

**Gotchas**
- Test names vary by Cilium version: `cilium connectivity test --list-tests`.
- If you use a proxy, put the Docker subnet and `10.244.0.0/16`, `10.96.0.0/12` in `NO_PROXY` (proper CIDRs, e.g. `172.18.0.0/16`).

**Docs**
- Routing concepts (tunnel vs native): https://docs.cilium.io/en/stable/network/concepts/routing/
- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/
- kind networking options: https://kind.sigs.k8s.io/docs/user/configuration/
