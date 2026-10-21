# 03 – Native routing (no tunnel)

## Purpose

This stage removes the VXLAN tunnel. Pod packets go between the nodes without encapsulation. Each node has a
route to the pod CIDR of each other node.

When you complete this stage, you know:

- The difference between tunnel routing and native routing.
- When native routing is possible: the network between the nodes must deliver packets to pod IP addresses.
- What `ipv4NativeRoutingCIDR` does, and why it must agree with the kind `podSubnet`.
- What `autoDirectNodeRoutes` does on a shared L2 network.
- Why BPF masquerading replaces the iptables masquerade rules.

## Concepts

### Tunnel and native routing

In tunnel mode (stages 01 and 02), the Docker bridge sees only node addresses. In native routing mode, the
Docker bridge sees the pod addresses directly. Thus, the nodes must know where each pod CIDR is.

```
 tunnel (stages 01, 02)                  native (this stage)

 +----------------------------------+    +----------------------------------+
 | outer: 172.18.0.2 -> 172.18.0.3  |    | IP: 10.244.1.5 -> 10.244.2.7     |
 | UDP 8472 + VXLAN header          |    | TCP payload                      |
 | inner: 10.244.1.5 -> 10.244.2.7  |    +----------------------------------+
 | TCP payload                      |    no extra header
 +----------------------------------+
```

| | Tunnel | Native |
|-|--------|--------|
| Network must know pod CIDRs | no | yes |
| Extra header on each packet | yes (50 bytes for VXLAN) | no |
| Pod IP addresses visible on the wire | no | yes |

### autoDirectNodeRoutes

All kind nodes connect to the same Docker bridge (one L2 segment). Thus, a node can send a packet directly to
any other node. With `autoDirectNodeRoutes: true`, each Cilium agent adds a route for the pod CIDR of each
other node, with that node as the next hop:

```
 routing table of native-worker (example)

 10.244.0.0/24 via 172.18.0.5 dev eth0     # pod CIDR of native-control-plane
 10.244.2.0/24 via 172.18.0.3 dev eth0     # pod CIDR of native-worker2
 10.244.3.0/24 via 172.18.0.4 dev eth0     # pod CIDR of native-worker3
```

```
 pod A 10.244.1.5                                   pod B 10.244.2.7
 (native-worker)                                    (native-worker2)
      |                                                  ^
      v                                                  |
 route 10.244.2.0/24 via 172.18.0.3  -- Docker bridge -->  eth0 172.18.0.3
```

`autoDirectNodeRoutes` works only if all nodes are on one L2 segment. If the nodes are in different L2
segments, a router must know the pod CIDRs, for example through BGP (stage
[05](../05-bgp-frr/README.md)).

### ipv4NativeRoutingCIDR

`ipv4NativeRoutingCIDR` tells Cilium which destinations it can reach without masquerading (SNAT). Cilium does
not change the source address of packets to this CIDR. Packets to all other destinations (for example the
internet) get the node IP address as the source address.

```
 pod 10.244.1.5 -> 10.244.2.7   inside 10.244.0.0/16: no SNAT, source stays 10.244.1.5
 pod 10.244.1.5 -> 1.1.1.1      outside:              SNAT,    source changes to 172.18.0.2
```

The value must be the same as `podSubnet` in `kind.yaml` (`10.244.0.0/16`). If the value is too small, pod
traffic between nodes gets SNAT and the destination pod sees the wrong source address.

### BPF masquerading

`bpf.masquerade: true` tells Cilium to do the SNAT in eBPF, not with iptables rules. It needs the kube-proxy
replacement, which `cilium install` turns on because kube-proxy is not present.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `native` |
| Nodes | `native-control-plane`, `native-worker`, `native-worker2`, `native-worker3` |
| Pod subnet | `10.244.0.0/16`, one `/24` per node |
| Service subnet | `10.96.0.0/12` |
| Routing | native, `autoDirectNodeRoutes` |
| kube-proxy | no, Cilium replaces it |
| Masquerading | BPF |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Four nodes, no default CNI, no kube-proxy, explicit pod and Service subnets. |
| `values.yaml` | Native routing, `ipv4NativeRoutingCIDR`, `autoDirectNodeRoutes`, BPF masquerade, Hubble Relay. |
| `mise-tasks/check` | `cilium status --wait`, then the pod CIDR routes of `native-worker`. |

## Procedure

Do the steps in the stage folder (`03-native-routing/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task makes the cluster, installs Cilium, and runs the `check` task. Expected output of the check
(example):

```
--- pod CIDR routes on native-worker:
10.244.0.0/24 via 172.18.0.5 dev eth0
10.244.2.0/24 via 172.18.0.3 dev eth0
10.244.3.0/24 via 172.18.0.4 dev eth0
Then: cilium connectivity test
Behind a proxy / no direct internet? Skip the world tests:
  cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
```

There are three routes: one for each other node. The local pod CIDR of `native-worker` is not in the list.

### Step 2: Examine the routing mode

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -iE 'routing|masquerading'
```

Expected output (example):

```
Routing:                 Network: Native   Host: BPF
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
```

- `Network: Native`: no tunnel.
- `Host: BPF`: eBPF routes the packets, not the kernel network stack.
- `10.244.0.0/16` in the masquerading line is the `ipv4NativeRoutingCIDR`. Cilium does no SNAT for it.

Make sure that there is no VXLAN interface:

```bash
docker exec native-worker ip link show cilium_vxlan
```

Expected output: `Device "cilium_vxlan" does not exist.`

### Step 3: See pod addresses on the wire

1. Start two pods on different nodes:

   ```bash
   kubectl run a --image=nginx:1.31-alpine --overrides='{"spec":{"nodeName":"native-worker"}}'
   kubectl run b --image=curlimages/curl:8.23.0 --overrides='{"spec":{"nodeName":"native-worker2"}}' \
     --command -- sleep infinity
   kubectl wait --for=condition=Ready pod/a pod/b
   kubectl get pod a -o wide
   ```

2. Send a request from `b` to `a`. Use the pod IP address of `a`:

   ```bash
   kubectl exec b -- curl -s -o /dev/null -w '%{http_code}\n' http://<IP of a>
   ```

   Expected output: `200`.

3. (Optional) Capture the packets on the node of `a`. The capture shows the pod IP addresses, not node
   addresses in a VXLAN header:

   ```bash
   docker exec native-worker tcpdump -ni eth0 tcp port 80
   ```

   `tcpdump` is not in the kind node image. Install it first if the node has network access:
   `docker exec native-worker sh -c 'apt-get update && apt-get install -y tcpdump'`.

4. Delete the pods: `kubectl delete pod a b`.

### Step 4: Do the connectivity test

```bash
cilium connectivity test
```

If the host has no direct internet access, skip the world tests:

```bash
cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
```

The test names can change between Cilium versions. Use `cilium connectivity test --list-tests` to see them.

## Experiments

- Stop a worker (`docker stop native-worker3`). After some time, the other nodes remove the route to its pod
  CIDR. Start it again with `docker start native-worker3`.
- Set `ipv4NativeRoutingCIDR` to `10.244.0.0/24` and do `cilium upgrade --values values.yaml`. Then pods on
  other nodes see the node IP address as the source address. Use `hubble observe` to see this.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| No `10.244` routes on the worker. | The agents are not ready, or `autoDirectNodeRoutes` is off. | Do `cilium status --wait`. Make sure that `values.yaml` has `autoDirectNodeRoutes: true`. |
| Connectivity test fails for the world tests. | The host has no direct internet access. | Skip the world tests (see step 4). |
| Requests to cluster addresses go to a proxy. | `HTTP_PROXY` is set on the host. | Put the Docker subnet (for example `172.18.0.0/16`), `10.244.0.0/16` and `10.96.0.0/12` in `NO_PROXY`. |

## Clean up

```bash
mise run down
```

This deletes the kind cluster `native`.

## References

- Routing concepts (tunnel and native): https://docs.cilium.io/en/stable/network/concepts/routing/
- Masquerading: https://docs.cilium.io/en/stable/network/concepts/masquerading/
- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/
- kind networking options: https://kind.sigs.k8s.io/docs/user/configuration/
