# 05 – BGP: Cilium peering with an FRR router (containerlab)

**Scope.** Native-routing cluster whose nodes (AS 65001) peer with an **FRR** router (AS 65000) that containerlab
runs on the *same Docker network as kind* (`mgmt.network: kind`). Cilium's **BGP Control Plane** advertises
the pod CIDRs and the `LoadBalancer` IPs (pool `10.200.0.10-250`, which exist only via BGP).

```
 FRR (AS 65000, <kind-subnet>.0.100)  <-- eBGP -->  kind nodes (AS 65001, Cilium)
```

**What you learn**
- The Cilium BGP v2 resources: `CiliumBGPClusterConfig` → `CiliumBGPPeerConfig` → `CiliumBGPAdvertisement`.
- ECMP: FRR installs the LB IP with one next hop per node.
- Combining kind and containerlab on one bridge network.

**Run / verify / tear down**
```bash
./up.sh
cilium bgp peers
docker exec clab-bgp-lab-frr vtysh -c 'show bgp summary'
docker exec clab-bgp-lab-frr vtysh -c 'show ip route bgp'
docker exec clab-bgp-lab-frr wget -qO- -T3 http://10.200.0.10 | head -n 4
./down.sh      # destroys the lab first, then the cluster
```

**Try next:** `docker stop lab-worker2` (next hop disappears within the hold time); patch `web` with
`externalTrafficPolicy: Local` (only nodes hosting a backend advertise the IP).

**Gotchas (all hit during testing)**
- FRR needs `vtysh.conf` (`service integrated-vtysh-config`) or it starts with an empty config.
- In `frr.conf`, define the peer-group **before** `bgp listen range`.
- Keep `.0` out of the LB pool. Don't run `sudo -E containerlab` (rendered with `envsubst` instead).
- After editing an FRR config, destroy and redeploy the lab.

**Docs**
- Cilium BGP Control Plane resources: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/
- Operating it (`cilium bgp peers`, logs): https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/
- containerlab quickstart: https://containerlab.dev/quickstart
- containerlab `linux` kind: https://containerlab.dev/manual/kinds/linux/
- FRR BGP: https://docs.frrouting.org/en/latest/bgp.html
