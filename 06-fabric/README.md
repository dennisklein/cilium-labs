# 06 – Leaf/spine fabric around kind (containerlab `ext-container`)

**Scope.** Two kind workers are wired with point-to-point links (`eth1`) into a small FRR fabric, and an
external **client** sits behind the spine. Cilium advertises pod CIDRs and LB IPs to the leaves; the client reaches
the `LoadBalancer` IP across the fabric with ECMP. East-west pod traffic stays on `eth0` (native routing).

```
            client 10.10.20.2
                 |
              spine  AS 65000
             /          \
      leaf1 AS 65101   leaf2 AS 65102
           |                |
     fabric-worker     fabric-worker2      (Cilium, AS 65001, rack=1 / rack=2)
```

**What you learn**
- Connecting existing kind node containers to containerlab with `kind: ext-container` links.
- One `CiliumBGPClusterConfig` per rack (node selector `rack=1|2`) because each rack peers with a different leaf.
- Why the nodes need a return route to the client network via `eth1`.

**Run / verify / tear down**
```bash
./up.sh                                           # ends with client -> LB IP via the fabric
docker exec clab-cilium-fabric-spine vtysh -c 'show ip route bgp'
cilium bgp peers
./down.sh
```

**Gotchas**
- Cilium's BGP Control Plane advertises routes but does not install learned ones, so the fabric carries
  north-south traffic only.
- A node can be selected by only **one** `CiliumBGPClusterConfig`; keep the rack selectors disjoint.
- Node-side addressing (`ip addr` on `eth1`, return route) is done by `up.sh`, then the agents are restarted
  so `devices: eth+` picks up `eth1`.
- Container names must match exactly (`fabric-worker`, `fabric-worker2`); the cluster is named `fabric`.

**Docs**
- containerlab `ext-container`: https://containerlab.dev/manual/kinds/ext-container
- containerlab + kind (`k8s-kind`): https://containerlab.dev/manual/kinds/k8s-kind
- Cilium BGP Control Plane: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/
- FRR BGP: https://docs.frrouting.org/en/latest/bgp.html
