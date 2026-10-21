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
   A=$(kubectl get pod a -o jsonpath='{.status.podIP}'); echo "$A"
   ```

2. In a second terminal, capture the HTTP packets on `eth0` of `native-worker`. The kind node image has no
   `tcpdump`. Thus, start a `netshoot` container in the network namespace of the node container:

   ```bash
   docker run --rm --net container:native-worker nicolaka/netshoot tcpdump -ni eth0 -c 4 tcp port 80
   ```

3. In the first terminal, send a request from `b` to `a`:

   ```bash
   kubectl exec b -- curl -s -o /dev/null -w '%{http_code}\n' "http://$A"
   ```

   Expected output: `200`.

4. Examine the capture in the second terminal. Expected output (example):

   ```
   IP 10.244.2.14.41234 > 10.244.1.9.80: Flags [S], seq 1234567890, win 64240, length 0
   IP 10.244.1.9.80 > 10.244.2.14.41234: Flags [S.], seq 987654321, ack 1234567891, win 65160, length 0
   IP 10.244.2.14.41234 > 10.244.1.9.80: Flags [.], ack 1, win 502, length 0
   IP 10.244.2.14.41234 > 10.244.1.9.80: Flags [P.], seq 1:75, ack 1, win 502, length 74: HTTP: GET / HTTP/1.1
   ```

   The packets on `eth0` have the pod IP addresses. There is no VXLAN header (compare with experiment 2 of
   stage [01](../01-basic/README.md#experiment-2-capture-the-tunnel-traffic)). `tcpdump` stops after 4
   packets.

5. Delete the pods:

   ```bash
   kubectl delete pod a b
   ```

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

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: Remove a node and see its route go

1. Show the pod CIDR routes on `native-worker`:

   ```bash
   docker exec native-worker ip route | grep 10.244
   kubectl get node native-worker3 -o jsonpath='{.spec.podCIDR}{"\n"}'
   ```

   One of the routes goes to the pod CIDR of `native-worker3`.

2. Delete the node object of `native-worker3`. The container continues to run:

   ```bash
   kubectl delete node native-worker3
   ```

3. Show the routes again:

   ```bash
   docker exec native-worker ip route | grep 10.244
   ```

   The route to the pod CIDR of `native-worker3` is not there now. The Cilium agents remove the route when the
   node goes out of the cluster.

4. Restart the kubelet on `native-worker3`. The kubelet registers the node again:

   ```bash
   docker exec native-worker3 systemctl restart kubelet
   kubectl wait --for=condition=Ready node/native-worker3 --timeout=120s
   ```

5. Do step 3 again. The route is there again. The node can get a different pod CIDR than before.

### Experiment 2: Make ipv4NativeRoutingCIDR too small

In this experiment, `ipv4NativeRoutingCIDR` covers only one `/24`. Then Cilium does SNAT for pod traffic to
the other pod CIDRs. The nginx access log shows the source address that the server sees.

1. Start a server pod and a client pod on two workers:

   ```bash
   kubectl run a --image=nginx:1.31-alpine --overrides='{"spec":{"nodeName":"native-worker"}}'
   kubectl run b --image=curlimages/curl:8.23.0 --overrides='{"spec":{"nodeName":"native-worker2"}}' \
     --command -- sleep infinity
   kubectl wait --for=condition=Ready pod/a pod/b
   kubectl get pod a b -o wide
   A=$(kubectl get pod a -o jsonpath='{.status.podIP}')
   ```

   If the IP address of `a` or `b` is in `10.244.0.0/24`, use different workers. Only the pod CIDRs outside of
   `10.244.0.0/24` show the effect.

2. Send a request and show the source address in the log of `a`:

   ```bash
   kubectl exec b -- curl -s -o /dev/null http://$A
   kubectl logs a | tail -n 1
   ```

   Expected output: the line starts with the pod IP address of `b` (for example `10.244.2.14`). No SNAT.

3. Find the running Cilium version. Then set `ipv4NativeRoutingCIDR` to `10.244.0.0/24`:

   ```bash
   V=$(helm -n kube-system list -o json | jq -r '.[] | select(.name=="cilium") | .app_version')
   cilium upgrade --version "$V" --reuse-values --set ipv4NativeRoutingCIDR=10.244.0.0/24
   kubectl -n kube-system rollout status ds/cilium
   ```

4. Do step 2 again. Expected output: the line starts with the node IP address of `native-worker2` (for example
   `172.18.0.3`). Cilium did SNAT, because the destination is not in `ipv4NativeRoutingCIDR`.

5. Restore the value and delete the pods:

   ```bash
   cilium upgrade --version "$V" --reuse-values --set ipv4NativeRoutingCIDR=10.244.0.0/16
   kubectl -n kube-system rollout status ds/cilium
   kubectl delete pod a b
   ```

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
