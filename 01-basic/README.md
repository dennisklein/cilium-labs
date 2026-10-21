# 01 – Basic: kind + Cilium (VXLAN tunnel)

## Purpose

This stage makes the smallest useful Cilium cluster. All other stages start from this setup.

When you complete this stage, you know:

- Why a kind cluster without a CNI plugin has nodes that are `NotReady`.
- How `cilium install` puts Cilium into the cluster as the CNI plugin.
- How `ipam.mode: kubernetes` gives each node a range of pod IP addresses.
- How VXLAN encapsulation moves pod traffic between nodes.
- How to do the Cilium end-to-end test, `cilium connectivity test`.

## Concepts

### kind nodes are containers

kind ("Kubernetes in Docker") runs each Kubernetes node as a Docker container. All node containers
connect to one Docker bridge network with the name `kind`. The host also connects to this bridge.

```
 host
 +--------------------------------------------------------------------+
 |  docker network "kind" (bridge, for example 172.18.0.0/16)         |
 |  ------+--------------------+--------------------+--------------   |
 |        |                    |                    |                 |
 |  +-----+-----------+  +-----+-----------+  +-----+-----------+     |
 |  | basic-control-  |  | basic-worker    |  | basic-worker2   |     |
 |  | plane           |  |                 |  |                 |     |
 |  | eth0 172.18.0.x |  | eth0 172.18.0.y |  | eth0 172.18.0.z |     |
 |  +-----------------+  +-----------------+  +-----------------+     |
 +--------------------------------------------------------------------+
```

### A cluster needs a CNI plugin

Kubernetes does not connect pods to the network itself. A CNI (Container Network Interface) plugin does this
work. By default, kind installs its own small CNI plugin, `kindnet`. The `kind.yaml` file of this stage
disables it:

```yaml
networking:
  disableDefaultCNI: true
```

Without a CNI plugin, the nodes stay `NotReady` and pods stay `Pending`. Cilium is the CNI plugin here. When
the Cilium agent starts on a node, the node changes to `Ready`.

### cilium install

`cilium install` (from cilium-cli) installs the Cilium Helm chart. It does not need a local Helm chart or the
`helm` command. Before the install, it examines the cluster and adds Helm values for the cluster type. For
kind, it sets these values:

| Helm value | Value from cilium-cli | Chart default |
|------------|-----------------------|---------------|
| `ipam.mode` | `kubernetes` | `cluster-pool` |
| `operator.replicas` | `1` | `2` |
| `routingMode`, `tunnelProtocol` | `tunnel`, `vxlan` (only if `routingMode` is not set) | empty (agent: tunnel, vxlan) |

Thus, this stage needs no `values.yaml` file. Later stages add a `values.yaml` file with only the values that
are different from these defaults. Use `cilium config view` to see the result in the cluster.

### Pod IP addresses (IPAM)

`ipam.mode: kubernetes` tells Cilium to use the pod CIDR that Kubernetes gives to each node
(`node.spec.podCIDR`). kind uses the cluster pod subnet `10.244.0.0/16` and gives a `/24` to each node.

```
 cluster pod subnet 10.244.0.0/16
   |
   +-- basic-control-plane  10.244.0.0/24
   +-- basic-worker         10.244.1.0/24
   +-- basic-worker2        10.244.2.0/24
```

The order of the node ranges can change from one run to the next.

### VXLAN tunnel

The Docker bridge does not know the pod subnets. Thus, a packet from a pod on one node to a pod on another node
cannot go on the bridge as it is. In tunnel mode, Cilium puts the full pod packet inside a UDP packet (VXLAN,
UDP port 8472) between the two node IP addresses. The receiving node removes the outer header and sends the
inner packet to the destination pod.

```
 pod A 10.244.1.5 (basic-worker)             pod B 10.244.2.7 (basic-worker2)
      |                                            ^
      v                                            |
 +--------------------------+  Docker bridge  +--------------------------+
 | cilium_vxlan             | --------------> | cilium_vxlan             |
 | outer: 172.18.0.y ->     |                 | remove outer header,     |
 |        172.18.0.z UDP    |                 | send inner packet to     |
 | inner: 10.244.1.5 ->     |                 | pod B                    |
 |        10.244.2.7        |                 |                          |
 +--------------------------+                 +--------------------------+
```

Tunnel mode works on all networks, because the network only sees node-to-node traffic. The cost is an extra
header (50 bytes) on each packet. Stage [03](../03-native-routing/README.md) removes the tunnel.

### kube-proxy is still present

In this stage, kube-proxy still implements Kubernetes Services with iptables rules. Cilium only connects the
pods. Stage [02](../02-kpr-hubble-policy/README.md) removes kube-proxy.

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `basic` |
| Nodes | `basic-control-plane`, `basic-worker`, `basic-worker2` |
| Pod subnet | `10.244.0.0/16` (kind default), one `/24` per node |
| Service subnet | `10.96.0.0/12` (kind default) |
| Routing | tunnel, VXLAN |
| kube-proxy | yes |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Three nodes. The default CNI is off. |
| `mise.toml` | `CLUSTER=basic`, `KUBECONFIG=build/kubeconfig`, tasks `up`, `check` and `down`. |

## Procedure

Do the steps in the stage folder (`01-basic/`). See the [top-level README](../README.md) for the toolchain.

### Step 1: Start the lab

Start the lab:

```bash
mise run up
```

The `up` task does these steps:

```
 //:preflight      docker info (is the Docker daemon available?)
       |
 kind_up           kind create cluster --name basic --config kind.yaml
       |           (kubeconfig goes to build/kubeconfig)
 cilium_up         cilium install --version <latest stable>
       |           (no values.yaml: only the cilium-cli defaults for kind)
 mise run check    cilium status --wait
```

The task ends when Cilium is ready. Expected output at the end (example):

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled

DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator    Desired: 1, Ready: 1/1, Available: 1/1
...
Next: cilium connectivity test
```

### Step 2: Examine the nodes

```bash
kubectl get nodes -o wide
```

All three nodes are `Ready`. The `INTERNAL-IP` column shows the address of each node on the Docker bridge.

```
NAME                  STATUS   ROLES           ...   INTERNAL-IP   ...
basic-control-plane   Ready    control-plane   ...   172.18.0.3    ...
basic-worker          Ready    <none>          ...   172.18.0.2    ...
basic-worker2         Ready    <none>          ...   172.18.0.4    ...
```

Show the pod CIDR of each node:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,PODCIDR:.spec.podCIDR'
```

```
NAME                  PODCIDR
basic-control-plane   10.244.0.0/24
basic-worker          10.244.1.0/24
basic-worker2         10.244.2.0/24
```

### Step 3: Examine the routing mode

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i routing
```

Expected output:

```
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
```

`Network: Tunnel [vxlan]` tells you that pod traffic between nodes goes through the VXLAN tunnel.
`Host: Legacy` tells you that the host network stack of the kernel routes the traffic. Later stages change
this to `BPF`.

Show that kube-proxy is present:

```bash
kubectl -n kube-system get ds kube-proxy
```

### Step 4: Do the connectivity test

```bash
cilium connectivity test
```

The test makes the namespace `cilium-test-1` with client and server pods. Then it sends traffic in many
combinations: pod to pod, pod to Service, pod to host, pod to the internet, and traffic with network policies.
The test takes some minutes. Expected output at the end:

```
✅ [cilium-test-1] All NN tests (MMM actions) successful, K tests skipped, 0 scenarios skipped.
```

If the host has no direct internet access (for example, only through a proxy), skip the tests that go to the
internet:

```bash
cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
```

The test names can change between Cilium versions. Use `cilium connectivity test --list-tests` to see them.

## Experiments

- Look at the VXLAN interface on a node: `docker exec basic-worker ip -d link show cilium_vxlan`.
- See the tunnel traffic. Start a pod on each worker, send a ping between them, and capture on the bridge
  side of a node: `docker exec basic-worker tcpdump -ni eth0 udp port 8472`. (Install `tcpdump` in the node
  container first: `docker exec basic-worker apt-get install -y tcpdump`, if the node has network access.)
- Show the Helm values that cilium-cli used: `helm -n kube-system get values cilium`.
- Show the Cilium endpoints (one for each pod) on a node:
  `kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list`.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| Nodes stay `NotReady`. | The Cilium agent does not start. | Do `cilium status` and `kubectl -n kube-system logs ds/cilium`. |
| The *world* connectivity tests time out. | The host has no direct internet access. | Skip the world tests (see step 4). This is not a Cilium problem. |
| `kind get nodes` shows nothing. | kind uses the cluster name `kind` by default. | Use `kind get nodes --name basic`. |
| The agents do not start. The log shows `failed to probe helper` and `FnSetRetval: bpf_set_retval R1 is not a scalar`. | Cilium 1.20.1 probes a BPF helper that some kernels reject. Cilium 1.20.2 removed this probe (cilium/cilium#48213). | Use Cilium 1.20.2 or later. Do not set `CILIUM_VERSION` to 1.20.1. See the [Cilium version](../README.md#cilium-version) section. |
| `kind create cluster` fails, "already exist". | The cluster of this stage exists from an earlier run. | Do `mise run down` first. |

## Clean up

```bash
mise run down
```

This deletes the kind cluster `basic`. The file `build/kubeconfig` stays. The next `up` task overwrites it.

## References

- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/
- Routing concepts (tunnel and native): https://docs.cilium.io/en/stable/network/concepts/routing/
- IPAM modes: https://docs.cilium.io/en/stable/network/concepts/ipam/
- Cilium Helm values: https://docs.cilium.io/en/stable/helm-reference/
- kind configuration (`networking.disableDefaultCNI`): https://kind.sigs.k8s.io/docs/user/configuration/
