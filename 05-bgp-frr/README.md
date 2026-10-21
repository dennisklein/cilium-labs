# 05 – BGP: Cilium peering with an FRR router (containerlab)

## Purpose

Stage [04](../04-lbipam-l2/README.md) made LoadBalancer IP addresses reachable with ARP. ARP works only on one
L2 segment. In a data center, routers connect many segments. Routers learn routes with BGP. This stage makes
the Cilium nodes BGP speakers. They tell a router (FRR) which prefixes they can deliver:

- the pod CIDR of each node,
- the LoadBalancer IP addresses.

The LB pool `10.200.0.0/24` is not on the Docker bridge. Thus, the router can reach these addresses only
through the BGP routes.

When you complete this stage, you know:

- The three Cilium BGP resources: `CiliumBGPClusterConfig`, `CiliumBGPPeerConfig` and `CiliumBGPAdvertisement`.
- How FRR accepts BGP sessions from a full subnet (`bgp listen range`).
- How ECMP gives the router one next hop for each node that advertises an LB IP address.
- How containerlab starts a router on the same Docker network as kind.

## Concepts

### BGP in two sentences

BGP (Border Gateway Protocol) is the routing protocol between networks. Two BGP speakers open a TCP session
(port 179) and send each other prefixes with attributes (for example the AS path and the next hop).

Here the Cilium nodes are in AS 65001 and FRR is in AS 65000. Different AS numbers make the sessions eBGP.

```
               FRR (AS 65000)  <kind-prefix>.0.100
         +--------+---------+---------+--------+
       eBGP     eBGP      eBGP      eBGP          one session for each node
         |        |         |         |
   bgp-control  bgp-worker  bgp-worker2  bgp-worker3      (Cilium, AS 65001)
   -plane
```

### The Cilium BGP resources

`bgp.yaml.tpl` has three resources. Labels connect them:

```
 CiliumBGPClusterConfig bgp-all
   nodeSelector: bgp=enabled           (the up task puts this label on all nodes)
   localASN: 65001
   peer frr: 65000 @ ${FRR_IP}  --peerConfigRef-->  CiliumBGPPeerConfig peer-frr
                                                      timers: hold 9 s, keepalive 3 s
                                                      graceful restart
                                                      family ipv4/unicast
                                                      advertisements: advertise=bgp
                                                                 |
                                                                 v
                                                  CiliumBGPAdvertisement adverts
                                                    (label advertise=bgp)
                                                    - PodCIDR
                                                    - Service LoadBalancerIP
                                                      (selector matches all Services)
```

A Service selector is necessary for Service advertisements. The expression `never-used NotIn [x]` agrees with
all Services, because no Service has the label `never-used=x`.

### FRR with a listen range

FRR does not know the node addresses in advance. `bgp listen range` tells FRR to accept a session from each
address in the kind subnet. All these peers use the peer group `CILIUM`:

```
router bgp 65000
 neighbor CILIUM peer-group
 neighbor CILIUM remote-as 65001
 bgp listen range ${KIND_SUBNET} peer-group CILIUM
 address-family ipv4 unicast
  maximum-paths 8                  # ECMP: up to 8 next hops for one prefix
```

`no bgp ebgp-requires-policy` lets FRR accept and send routes without a route map. This is good for a lab,
but not for production.

### ECMP for LoadBalancer IP addresses

The Service `web` has `externalTrafficPolicy: Cluster` (the default). Thus, all four nodes advertise the LB IP
address. FRR installs one route with four next hops. FRR sends each flow to one of the nodes. The eBPF load
balancer on that node sends the flow to a `web` pod.

```
 FRR route table:  10.200.0.10/32  via 172.18.0.2  (bgp-control-plane)
                                   via 172.18.0.3  (bgp-worker)
                                   via 172.18.0.4  (bgp-worker2)
                                   via 172.18.0.5  (bgp-worker3)
```

The pod CIDRs are different: each node advertises only its own `/24`. Thus, each pod CIDR has one next hop.

### containerlab on the kind network

containerlab starts network labs from a topology file. Usually, it makes its own management network. In this
stage, `mgmt.network: kind` attaches the FRR container to the Docker network of kind. Thus, FRR and the nodes
are on the same L2 segment, and FRR can open sessions to the node addresses directly.

The `up` task renders the templates into `build/`:

| Variable | Example | Used in |
|----------|---------|---------|
| `KIND_SUBNET` | `172.18.0.0/16` | `topo.clab.yml.tpl` (`mgmt.ipv4-subnet`), `frr.conf.tpl` (listen range) |
| `FRR_IP` | `172.18.0.100` | `topo.clab.yml.tpl` (`mgmt-ipv4`), `frr.conf.tpl` (router ID), `bgp.yaml.tpl` (peer address) |

containerlab runs with `sudo`. The task renders the files before, so `sudo -E` (pass the environment) is not
necessary.

## Lab topology

```
 ===+============== docker network kind 172.18.0.0/16 ===================+===
    |              |               |               |                     |
 bgp-control-   bgp-worker      bgp-worker2     bgp-worker3        clab-bgp-lab-frr
 plane          web pod         web pod         web pod            172.18.0.100
 AS 65001       AS 65001        AS 65001        AS 65001           AS 65000
    \______________\_______________\_______________\____ eBGP ______/
```

| Item | Value |
|------|-------|
| Cluster name | `bgp` |
| Nodes | `bgp-control-plane`, `bgp-worker`, `bgp-worker2`, `bgp-worker3` (all with label `bgp=enabled`) |
| Routing | native, `autoDirectNodeRoutes` (as stage 03) |
| Router | FRR 10.7.1, container `clab-bgp-lab-frr`, `<PREFIX>.0.100`, AS 65000 |
| LB pool | `10.200.0.10` - `10.200.0.250` (`../common/pool-10.200.yaml`) |
| Demo | Deployment and LoadBalancer Service `web` (`../common/demo-lb.yaml`) |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Four nodes, no default CNI, no kube-proxy. |
| `values.yaml` | Native routing (as stage 03) and `bgpControlPlane.enabled`. |
| `bgp.yaml.tpl` | The three Cilium BGP resources. `${FRR_IP}` comes from the `up` task. |
| `topo.clab.yml.tpl` | containerlab topology: one FRR node on the kind network. |
| `frr/frr.conf.tpl` | FRR BGP configuration with the listen range. |
| `frr/daemons`, `frr/vtysh.conf` | FRR start configuration: only `bgpd`, integrated configuration. |
| `mise-tasks/up` | Cluster, Cilium, render, BGP resources, pool, demo, containerlab, then `check`. |
| `mise-tasks/check` | Waits for BGP, shows the FRR sessions and routes, sends a request from FRR. |

## Prerequisites

- containerlab (from `mise.toml`).
- `sudo` access. The `up` and `down` tasks ask for the password first.

## Procedure

Do the steps in the stage folder (`05-bgp-frr/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 sudo -v                          ask for the password first
 kind_up, cilium_up
 render build/frr.conf, build/topo.clab.yml
 kubectl label nodes --all bgp=enabled
 wait_crds                        BGP CRDs and the LB pool CRD
 apply bgp.yaml.tpl, pool, demo
 clab deploy                      start FRR on the kind network
 mise run check
```

Expected output of the check (example, shortened):

```
--- BGP sessions on FRR:
IPv4 Unicast Summary:
BGP router identifier 172.18.0.100, local AS number 65000 VRF default vrf-id 0
Neighbor        V    AS   MsgRcvd   MsgSent   Up/Down State/PfxRcd   PfxSnt Desc
*172.18.0.2     4 65001        20        18  00:00:45            2        0 N/A
*172.18.0.3     4 65001        20        18  00:00:45            2        0 N/A
*172.18.0.4     4 65001        20        18  00:00:44            2        0 N/A
*172.18.0.5     4 65001        20        18  00:00:44            2        0 N/A

* - dynamic neighbor
4 dynamic neighbor(s), limit 100
Total number of neighbors 4
B>* 10.200.0.10/32 [20/0] via 172.18.0.2, eth0, weight 1, 00:00:40
  *                       via 172.18.0.3, eth0, weight 1, 00:00:40
  *                       via 172.18.0.4, eth0, weight 1, 00:00:40
  *                       via 172.18.0.5, eth0, weight 1, 00:00:40
B>* 10.244.0.0/24 [20/0] via 172.18.0.5, eth0, weight 1, 00:00:44
B>* 10.244.1.0/24 [20/0] via 172.18.0.3, eth0, weight 1, 00:00:45
...
--- FRR -> LB IP 10.200.0.10:
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

Each node sends 2 prefixes (`PfxRcd`): its pod CIDR and the LB IP address. The `*` in front of a neighbor
tells you that the listen range made the session (dynamic neighbor).

### Step 2: Examine BGP from the Cilium side

```bash
cilium bgp peers
```

Expected output (example):

```
Node                Local AS   Peer AS   Peer Address    Session State   Uptime   Family         Received   Advertised
bgp-control-plane   65001      65000     172.18.0.100    established     2m       ipv4/unicast   0          2
bgp-worker          65001      65000     172.18.0.100    established     2m       ipv4/unicast   0          2
...
```

`Received 0`: FRR sends no routes to the nodes. Show the routes that the nodes advertise:

```bash
cilium bgp routes advertised ipv4 unicast
```

### Step 3: Examine the routes in FRR

```bash
docker exec clab-bgp-lab-frr vtysh -c 'show ip route bgp'
docker exec clab-bgp-lab-frr vtysh -c 'show bgp ipv4 unicast 10.200.0.10/32'
```

The second command shows the four paths for the LB IP address and the AS path `65001` of each path.

### Step 4: Send requests to the LB IP address

```bash
docker exec clab-bgp-lab-frr wget -qO- -T3 http://10.200.0.10 | head -n 4
```

Expected output: the first lines of the nginx welcome page.

The host has no route to `10.200.0.0/24`. Thus, `curl http://10.200.0.10` from the host does not work. Only
FRR has the BGP routes.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: Stop a node

1. Show the next hops of the LB IP address in FRR:

   ```bash
   docker exec clab-bgp-lab-frr vtysh -c 'show ip route 10.200.0.10/32'
   ```

   Expected output: four next hops, one for each node.

2. Stop a node:

   ```bash
   docker stop bgp-worker2
   ```

3. Wait 10 seconds (more than the hold time of 9 seconds). Then show the sessions and the next hops:

   ```bash
   docker exec clab-bgp-lab-frr vtysh -c 'show bgp summary'
   docker exec clab-bgp-lab-frr vtysh -c 'show ip route 10.200.0.10/32'
   ```

   Expected output: the session to the address of `bgp-worker2` is gone. The route has three next hops.

4. Send a request from FRR:

   ```bash
   docker exec clab-bgp-lab-frr wget -qO- -T3 http://10.200.0.10 | head -n 4
   ```

   The request works, because three nodes still advertise the address.

5. Start the node again and wait until it is ready:

   ```bash
   docker start bgp-worker2
   kubectl wait --for=condition=Ready node/bgp-worker2 --timeout=180s
   ```

6. Do step 1 again. Expected output: four next hops.

### Experiment 2: Advertise only from nodes with a backend

1. Show the nodes of the `web` pods:

   ```bash
   kubectl get pods -l app=web -o wide
   ```

2. Set `externalTrafficPolicy: Local` on the Service:

   ```bash
   kubectl patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
   ```

3. Wait some seconds. Then show the next hops:

   ```bash
   docker exec clab-bgp-lab-frr vtysh -c 'show ip route 10.200.0.10/32'
   ```

   Expected output: only the nodes from step 1 are next hops. The control plane has no `web` pod, so it does
   not advertise the address. With `Local`, a node sends the traffic only to its local pods. Thus, it keeps the
   source address of the client.

4. Restore the policy:

   ```bash
   kubectl patch svc web -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
   ```

### Experiment 3: Restart the agents with graceful restart

1. In a second terminal, count the next hops of the LB IP address each second:

   ```bash
   while true; do
     docker exec clab-bgp-lab-frr vtysh -c 'show ip route 10.200.0.10/32' | grep -c via
     sleep 1
   done
   ```

   Expected output: `4` each second.

2. In the first terminal, restart the Cilium agents:

   ```bash
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Examine the second terminal. The count stays at `4`. When an agent restarts, FRR keeps its routes for up to
   15 seconds (`restartTimeSeconds`), until the session is up again.

4. Show the graceful restart state of a session:

   ```bash
   docker exec clab-bgp-lab-frr vtysh -c 'show bgp neighbors' | grep -A3 'Graceful restart information'
   ```

5. Stop the loop in the second terminal with `Ctrl+C`.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| FRR starts with an empty configuration. | `vtysh.conf` is missing. | The file must have `service integrated-vtysh-config`. |
| FRR rejects the `bgp listen range` line. | The peer group is not defined yet. | Define the peer group before `bgp listen range` in `frr.conf.tpl`. |
| No sessions in `show bgp summary`. | The nodes do not have the label, or the BGP resources are missing. | Do `kubectl get nodes -l bgp=enabled` and `kubectl get ciliumbgpclusterconfigs`. |
| LB IP address stays `<pending>`. | No pool. | Do `kubectl get ciliumloadbalancerippools`. Keep `.0` and `.255` out of the pool. |
| A change in `frr.conf.tpl` has no effect. | containerlab does not reload the configuration. | Do `mise run down` and `mise run up`. |

## Clean up

```bash
mise run down
```

This destroys the containerlab lab first, then deletes the kind cluster `bgp`.

## References

- Cilium BGP Control Plane resources: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/
- Operation (`cilium bgp peers`, logs): https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/
- LB-IPAM: https://docs.cilium.io/en/stable/network/lb-ipam/
- containerlab quick start: https://containerlab.dev/quickstart/
- containerlab management network: https://containerlab.dev/manual/network/
- FRR BGP: https://docs.frrouting.org/en/latest/bgp.html
