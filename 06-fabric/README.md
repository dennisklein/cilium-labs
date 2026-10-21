# 06 – Leaf/spine fabric around kind (containerlab `ext-container`)

## Purpose

In stage [05](../05-bgp-frr/README.md), all nodes and the router were on one Docker bridge. A real data center
has racks. Each rack has a leaf switch, and spine switches connect the leaves. This stage builds a small
leaf/spine fabric with FRR. Each kind worker gets an uplink to the leaf of its rack. An external client behind
the spine reaches a LoadBalancer IP address through the fabric.

When you complete this stage, you know:

- How containerlab connects existing kind node containers to a lab (`kind: ext-container`).
- Why each rack needs its own `CiliumBGPClusterConfig`.
- How the spine uses ECMP across two leaves with different AS numbers.
- Why the nodes need a static return route to the client network.
- How north-south traffic (fabric) and east-west traffic (Docker bridge) use different interfaces.

## Concepts

### Leaf/spine

```
                          client 10.10.20.2
                                |  10.10.20.0/24
                         spine  AS 65000
                     eth1 /            \ eth2
          10.10.10.0/31  /              \  10.10.10.2/31
                        /                \
           leaf1 AS 65101                leaf2 AS 65102
               | eth2 10.10.1.0/31           | eth2 10.10.2.0/31
               |                             |
               | eth1 10.10.1.1              | eth1 10.10.2.1
     fabric-worker (rack 1)          fabric-worker2 (rack 2)
     Cilium AS 65001                 Cilium AS 65001
               \_____________________________/
                 eth0: docker network kind (east-west, native routing)
```

Each link is a point-to-point `/31` network (two addresses, no network or broadcast address). Each router has
its own AS number. All sessions are eBGP.

| Session | Side A | Side B |
|---------|--------|--------|
| spine - leaf1 | 10.10.10.0 (AS 65000) | 10.10.10.1 (AS 65101) |
| spine - leaf2 | 10.10.10.2 (AS 65000) | 10.10.10.3 (AS 65102) |
| leaf1 - fabric-worker | 10.10.1.0 (AS 65101) | 10.10.1.1 (AS 65001) |
| leaf2 - fabric-worker2 | 10.10.2.0 (AS 65102) | 10.10.2.1 (AS 65001) |

The control plane has no uplink and no BGP session.

### containerlab `ext-container`

containerlab usually makes all lab nodes. With `kind: ext-container`, it uses a container that exists already.
Here these are the kind node containers. containerlab only adds the veth links (`eth1`) to them:

```yaml
nodes:
  fabric-worker:  {kind: ext-container}   # must be the exact container name
  fabric-worker2: {kind: ext-container}
links:
  - endpoints: ["leaf1:eth2", "fabric-worker:eth1"]
  - endpoints: ["leaf2:eth2", "fabric-worker2:eth1"]
```

containerlab does not configure addresses in `ext-container` nodes. Thus, the `up` task does this with
`docker exec` (function `wire`).

### One cluster config for each rack

A `CiliumBGPClusterConfig` has one list of peers for all selected nodes. The two racks have different peers
(leaf1 and leaf2). Thus, the stage has two cluster configs. A node label selects the config:

```
 node label rack=1  -->  CiliumBGPClusterConfig rack1  -->  peer leaf1 10.10.1.0 AS 65101
 node label rack=2  -->  CiliumBGPClusterConfig rack2  -->  peer leaf2 10.10.2.0 AS 65102
                                       \                 /
                                CiliumBGPPeerConfig peer  -->  CiliumBGPAdvertisement adverts
                                                               (PodCIDR, LoadBalancerIP)
```

A node can be in only one cluster config. Keep the selectors disjoint.

### ECMP on the spine

Both racks advertise the LB IP address. The spine gets two paths with different AS paths:

```
 10.200.0.10/32  via leaf1: AS path 65101 65001
                 via leaf2: AS path 65102 65001
```

By default, BGP uses more than one path only if the AS paths are the same. `bgp bestpath as-path
multipath-relax` lets the spine use both paths, because the paths have the same length. `maximum-paths 4`
permits up to four next hops.

### The return route

Cilium BGP sends routes to the leaves, but it does not install the routes that it receives. Thus, the nodes do
not know the client network `10.10.20.0/24`. Without help, a reply to the client goes through `eth0` (default
route to the Docker bridge) and does not arrive. The `up` task adds a static route on each worker:

```
 fabric-worker:   10.10.20.0/24 via 10.10.1.0 dev eth1
 fabric-worker2:  10.10.20.0/24 via 10.10.2.0 dev eth1
```

### North-south and east-west

```
 client -> spine -> leaf1 -> fabric-worker eth1          (north-south, fabric)
                                 |
                                 | eBPF load balancer selects a web pod
                                 v
                      pod on fabric-worker2 via eth0     (east-west, Docker bridge, native routing)
```

If the backend pod is on a different node, the receiving node sends the packet over `eth0` and changes the
source address to its own address (SNAT). The reply comes back to the receiving node. Then the node sends the
reply to the client through `eth1`.

`devices: "eth+"` in `values.yaml` tells Cilium to attach its eBPF programs to `eth0` and `eth1`. Without
this, Cilium does not process the LB traffic that arrives on `eth1`. `eth1` exists only after
`clab deploy`. Thus, the `up` task restarts the Cilium agents after it configures `eth1`.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `fabric` |
| Nodes | `fabric-control-plane`, `fabric-worker` (rack 1), `fabric-worker2` (rack 2) |
| Routing | native, `autoDirectNodeRoutes` on `eth0` |
| Fabric | containerlab `cilium-fabric`: `spine`, `leaf1`, `leaf2` (FRR 10.7.1), `client` (netshoot) |
| LB pool | `10.200.0.10` - `10.200.0.250` (`../common/pool-10.200.yaml`) |
| Demo | Deployment and LoadBalancer Service `web` (`../common/demo-lb.yaml`) |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Control plane and two workers, no default CNI, no kube-proxy. |
| `values.yaml` | Native routing, `devices: eth+`, `bgpControlPlane.enabled`. |
| `bgp.yaml` | Cluster configs `rack1` and `rack2`, peer config, advertisement. |
| `topo.clab.yml` | Fabric nodes, addresses, the two `ext-container` nodes and the links. |
| `frr/spine.conf`, `frr/leaf1.conf`, `frr/leaf2.conf` | FRR BGP configuration of each router. |
| `mise-tasks/up` | Cluster, Cilium, labels, BGP resources, demo, containerlab, node wiring, agent restart, `check`. |
| `mise-tasks/check` | Waits for BGP on the spine, shows sessions and routes, sends a request from the client. |

## Prerequisites

- containerlab (from `mise.toml`).
- `sudo` access. The `up` and `down` tasks ask for the password first.

## Procedure

Do the steps in the stage folder (`06-fabric/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 sudo -v
 kind_up, cilium_up
 kubectl label node fabric-worker rack=1, fabric-worker2 rack=2
 wait_crds, apply pool, bgp.yaml, demo
 clab deploy -t topo.clab.yml          spine, leaves, client, links to the workers
 wire fabric-worker   10.10.1.1/31, route 10.10.20.0/24 via 10.10.1.0
 wire fabric-worker2  10.10.2.1/31, route 10.10.20.0/24 via 10.10.2.0
 kubectl -n kube-system rollout restart ds/cilium      (Cilium finds eth1)
 mise run check
```

Expected output of the check (example, shortened):

```
Neighbor        V    AS   MsgRcvd   MsgSent   Up/Down State/PfxRcd   PfxSnt Desc
10.10.10.1      4 65101        30        28  00:01:10            4        5 N/A
10.10.10.3      4 65102        30        28  00:01:10            4        5 N/A
...
B>* 10.10.1.0/31 [20/0] via 10.10.10.1, eth1, weight 1, 00:01:10
B>* 10.10.2.0/31 [20/0] via 10.10.10.3, eth2, weight 1, 00:01:10
B>* 10.200.0.10/32 [20/0] via 10.10.10.1, eth1, weight 1, 00:00:30
  *                       via 10.10.10.3, eth2, weight 1, 00:00:30
B>* 10.244.1.0/24 [20/0] via 10.10.10.1, eth1, weight 1, 00:00:30
B>* 10.244.2.0/24 [20/0] via 10.10.10.3, eth2, weight 1, 00:00:30
--- client -> LB IP 10.200.0.10 via the fabric:
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

The LB IP address has two next hops (ECMP). Each pod CIDR has one next hop: the leaf of its rack.

### Step 2: Examine the sessions of the nodes

```bash
cilium bgp peers
```

Expected output (example):

```
Node             Local AS   Peer AS   Peer Address   Session State   Uptime   Family         Received   Advertised
fabric-worker    65001      65101     10.10.1.0      established     2m       ipv4/unicast   6          2
fabric-worker2   65001      65102     10.10.2.0      established     2m       ipv4/unicast   6          2
```

The control plane is not in the list, because it has no `rack` label. `Received` is more than 0, but Cilium
does not install these routes.

### Step 3: Examine the uplink of a node

```bash
docker exec fabric-worker ip addr show eth1
docker exec fabric-worker ip route | grep -E '10.10|10.244'
```

Expected output (part):

```
    inet 10.10.1.1/31 scope global eth1
10.10.1.0/31 dev eth1 proto kernel scope link src 10.10.1.1
10.10.20.0/24 via 10.10.1.0 dev eth1
10.244.0.0/24 via 172.18.0.x dev eth0
10.244.2.0/24 via 172.18.0.y dev eth0
```

The route to the client goes through `eth1`. The routes to the other pod CIDRs go through `eth0`.

### Step 4: Send requests from the client

```bash
docker exec clab-cilium-fabric-client curl -s -m 5 http://10.200.0.10 | head -n 4
docker exec clab-cilium-fabric-client traceroute -n 10.200.0.10
```

The trace shows the spine (`10.10.20.1`), a leaf (`10.10.10.1` or `10.10.10.3`), and then the node.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the lab in its
initial state.

### Experiment 1: Disconnect rack 1 from the spine

1. Show the next hops of the LB IP address on the spine:

   ```bash
   docker exec clab-cilium-fabric-spine vtysh -c 'show ip route 10.200.0.10/32'
   ```

   Expected output: two next hops, `10.10.10.1` (leaf1) and `10.10.10.3` (leaf2).

2. Set the spine link of leaf1 to down:

   ```bash
   docker exec clab-cilium-fabric-leaf1 ip link set eth1 down
   ```

3. Do step 1 again. Expected output: one next hop, `10.10.10.3` (leaf2). The link is down, so FRR on the spine
   closes the session to leaf1 at once.

4. Send requests from the client:

   ```bash
   for i in $(seq 5); do
     docker exec clab-cilium-fabric-client curl -s -m 2 -o /dev/null -w '%{http_code}\n' http://10.200.0.10
   done
   ```

   Expected output: `200` five times. All traffic goes through rack 2.

5. Set the link to up again and reset the BGP sessions of leaf1, so that it connects at once:

   ```bash
   docker exec clab-cilium-fabric-leaf1 ip link set eth1 up
   docker exec clab-cilium-fabric-leaf1 vtysh -c 'clear bgp *'
   ```

6. Wait some seconds. Then do step 1 again. Expected output: two next hops.

### Experiment 2: Remove the return route of rack 1

1. Remove the return route on `fabric-worker`:

   ```bash
   docker exec fabric-worker ip route del 10.10.20.0/24
   ```

2. Send ten requests from the client. Each request uses a new source port, so ECMP can select a different
   rack:

   ```bash
   for i in $(seq 10); do
     docker exec clab-cilium-fabric-client curl -s -m 2 -o /dev/null -w '%{http_code}\n' http://10.200.0.10
   done
   ```

   Expected output: a mix of `200` and `000`. The requests through rack 1 arrive at `fabric-worker`, but the
   replies go out on `eth0` and do not come back to the client.

3. Add the return route again:

   ```bash
   docker exec fabric-worker ip route replace 10.10.20.0/24 via 10.10.1.0 dev eth1
   ```

4. Do step 2 again. Expected output: `200` ten times.

### Experiment 3: Advertise only from the rack with a backend

1. Scale `web` to one replica and show its node:

   ```bash
   kubectl scale deploy web --replicas=1
   kubectl rollout status deploy web
   kubectl get pods -l app=web -o wide
   ```

2. Set `externalTrafficPolicy: Local` on the Service:

   ```bash
   kubectl patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
   ```

3. Wait some seconds. Then show the next hops on the spine:

   ```bash
   docker exec clab-cilium-fabric-spine vtysh -c 'show ip route 10.200.0.10/32'
   ```

   Expected output: one next hop, the leaf of the rack with the `web` pod. The node of the other rack has no
   local backend. Thus, it does not advertise the address.

4. Restore the Service and the Deployment:

   ```bash
   kubectl patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
   kubectl scale deploy web --replicas=3
   ```

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `clab deploy` fails: container not found. | The `ext-container` names are wrong. | The names must be `fabric-worker` and `fabric-worker2` (cluster name `fabric`). |
| No sessions between the nodes and the leaves. | `eth1` has no address, or no `rack` label. | Do `docker exec fabric-worker ip addr show eth1` and `kubectl get nodes -L rack`. |
| Sessions are up, but the client times out. | No return route, or Cilium does not use `eth1`. | Make sure the return route exists. Do `kubectl -n kube-system rollout restart ds/cilium`. |
| One node has no BGP instance. | The node is in two cluster configs. | Keep the `rack` selectors disjoint. |
| A change in an FRR file has no effect. | containerlab does not reload the configuration. | Do `mise run down` and `mise run up`. |

## Clean up

```bash
mise run down
```

This destroys the containerlab fabric first, then deletes the kind cluster `fabric`.

## References

- containerlab `ext-container`: https://containerlab.dev/manual/kinds/ext-container/
- containerlab and kind: https://containerlab.dev/manual/kinds/k8s-kind/
- Cilium BGP Control Plane: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/
- FRR BGP (multipath): https://docs.frrouting.org/en/latest/bgp.html
