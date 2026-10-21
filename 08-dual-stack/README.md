# 08 – Dual-stack (IPv4 + IPv6)

## Purpose

This stage uses the native-routing cluster of stage [03](../03-native-routing/README.md) and adds IPv6. Each
pod and each Service gets an IPv4 address and an IPv6 address. The nodes route the pod CIDRs of both families
directly.

When you complete this stage, you know:

- The three places where you must configure dual-stack: kind, the Kubernetes objects, and Cilium.
- How a dual-stack Service gets two ClusterIPs.
- How a client selects the address family.
- That native routing, Service load balancing and masquerading work separately for each family.

## Concepts

### Three layers of configuration

```
 kind (kind.yaml)                Kubernetes objects (demo.yaml)      Cilium (values.yaml)
 ipFamily: dual                  Service:                            ipv6.enabled: true
 podSubnet:                        ipFamilyPolicy: RequireDualStack  ipv4NativeRoutingCIDR:
   10.244.0.0/16,                  ipFamilies: [IPv4, IPv6]            10.244.0.0/16
   fd00:10:244::/56                                                  ipv6NativeRoutingCIDR:
 serviceSubnet:                  Pods: get both families               fd00:10:244::/56
   10.96.0.0/16,                 automatically                       autoDirectNodeRoutes: true
   fd00:10:96::/112
```

All three layers must agree. If one layer has only IPv4, the objects get only IPv4 addresses.

- **kind** gives each node a pod CIDR of each family and configures the API server for two Service CIDRs.
- **Kubernetes objects.** A Service is single-stack by default. `ipFamilyPolicy: RequireDualStack` asks for
  two ClusterIPs. The first family in `ipFamilies` is the primary family (`spec.clusterIP`).
- **Cilium** gives each pod an address from each pod CIDR of its node and installs the routes for both
  families.

### Node pod CIDRs

The IPv6 pod subnet is a `/56`. Kubernetes gives each node a `/64` from it:

```
 node            IPv4 pod CIDR     IPv6 pod CIDR
 dual-worker     10.244.1.0/24     fd00:10:244:1::/64
 dual-worker2    10.244.2.0/24     fd00:10:244:2::/64
 ...
```

### Routes for each family

`autoDirectNodeRoutes` adds the routes for both families. The next hop of an IPv6 route is the IPv6 address of
the other node on the Docker network:

```
 IPv4: 10.244.2.0/24      via 172.18.0.3              dev eth0
 IPv6: fd00:10:244:2::/64 via fc00:f853:ccd:e793::3   dev eth0
```

The IPv6 subnet of the Docker network `kind` (for example `fc00:f853:ccd:e793::/64`) is a ULA subnet (unique
local address). These addresses work only inside the Docker network.

### Address family selection

The DNS name `web` has an `A` record (IPv4) and an `AAAA` record (IPv6). The client selects the family:

```
 curl -4 http://web  --> A    10.96.x.x            --> eBPF IPv4 Service --> pod IPv4 address
 curl -6 http://web  --> AAAA fd00:10:96::xxxx     --> eBPF IPv6 Service --> pod IPv6 address
```

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `dual` |
| Nodes | `dual-control-plane`, `dual-worker`, `dual-worker2`, `dual-worker3` |
| Pod subnets | `10.244.0.0/16`, `fd00:10:244::/56` |
| Service subnets | `10.96.0.0/16`, `fd00:10:96::/112` |
| Routing | native for both families, `autoDirectNodeRoutes` |
| Demo | Deployment `web` (3 x nginx, one for each worker if possible), dual-stack Service `web`, pod `client` |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Four nodes, `ipFamily: dual`, two pod and two Service subnets. |
| `values.yaml` | `ipv6.enabled`, native routing CIDRs for both families, BPF masquerade, Hubble Relay. |
| `demo.yaml` | `web` with pod anti-affinity, dual-stack Service `web`, pod `client`. |
| `mise-tasks/up` | Cluster, IPv6 check of the Docker network, Cilium, demo, then `check`. |
| `mise-tasks/check` | Pod and Service addresses, HTTP probes for each family, IPv6 routes. |

## Prerequisites

The Docker network `kind` must have IPv6. kind makes the network with IPv6 if the Docker daemon supports it.
Examine it:

```bash
docker network inspect kind -f '{{.EnableIPv6}}'
```

Expected output: `true`. If the network exists from an earlier kind version without IPv6, delete all kind
clusters and the network (`docker network rm kind`). Then kind makes it again.

## Procedure

Do the steps in the stage folder (`08-dual-stack/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task makes the cluster and examines the Docker network. If it cannot confirm IPv6, it shows
`WARNING: could not confirm IPv6 on the docker 'kind' network`. Then it installs Cilium and the demo, and runs
the `check` task.

Expected output of the check (example):

```
--- pods (node and both IPs)
NAME              NODE           IPS
client            dual-worker3   10.244.3.12,fd00:10:244:3::a1
web-...-abcde     dual-worker    10.244.1.20,fd00:10:244:1::5c
web-...-fghij     dual-worker2   10.244.2.31,fd00:10:244:2::7e
web-...-klmno     dual-worker3   10.244.3.44,fd00:10:244:3::3d
--- Service cluster IPs (expect one IPv4 and one IPv6)
["10.96.120.15","fd00:10:96::c3a1"]
--- client -> every web pod, per family (expect 200)
10.244.1.20                    200
fd00:10:244:1::5c              200
10.244.2.31                    200
fd00:10:244:2::7e              200
10.244.3.44                    200
fd00:10:244:3::3d              200
--- via the Service name, forced family (expect 200)
IPv4: 200
IPv6: 200
--- IPv6 pod-CIDR routes on a worker (native routing, one per remote node)
fd00:10:244::/64 via fc00:f853:ccd:e793::5 dev eth0 metric 1024 pref medium
fd00:10:244:2::/64 via fc00:f853:ccd:e793::3 dev eth0 metric 1024 pref medium
fd00:10:244:3::/64 via fc00:f853:ccd:e793::4 dev eth0 metric 1024 pref medium
```

### Step 2: Examine the Cilium status

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -iE 'routing|masquerading|ipam'
```

Expected output (example):

```
IPAM:                    IPv4: 4/254 allocated from 10.244.1.0/24, IPv6: 4/18446744073709551614 allocated from fd00:10:244:1::/64
Routing:                 Network: Native   Host: BPF
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Enabled]
```

### Step 3: Examine the Service

```bash
kubectl get svc web -o yaml | grep -A3 -E 'clusterIPs|ipFamilies'
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

The Service has two ClusterIPs. The eBPF Service table has one entry for each family, each with three
backends of the same family.

### Step 4: Send requests for each family

```bash
kubectl exec client -- curl -4 -s -o /dev/null -w '%{http_code}\n' http://web
kubectl exec client -- curl -6 -s -o /dev/null -w '%{http_code}\n' http://web
kubectl exec client -- curl -s -o /dev/null -w '%{remote_ip}\n' http://web
```

The first two commands give `200`. The third command shows the address that curl used if you do not select a
family.

### Step 5: Do the connectivity test

```bash
cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
```

The connectivity test examines IPv6 too, because Cilium has IPv6 on.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state.

### Experiment 1: Make an IPv6-only Service

1. Make a single-stack IPv6 Service for the `web` pods:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Service
   metadata: {name: web6}
   spec:
     ipFamilyPolicy: SingleStack
     ipFamilies: [IPv6]
     selector: {app: web}
     ports: [{port: 80, targetPort: 80}]
   EOF
   ```

2. Show the ClusterIPs:

   ```bash
   kubectl get svc web6 -o jsonpath='{.spec.clusterIPs}{"\n"}'
   ```

   Expected output: one IPv6 address, for example `["fd00:10:96::5a2b"]`.

3. Send requests for each family:

   ```bash
   kubectl exec client -- curl -6 -s -m 3 -o /dev/null -w '%{http_code}\n' http://web6
   kubectl exec client -- curl -4 -s -m 3 -o /dev/null -w '%{http_code}\n' http://web6
   ```

   Expected output: `200` for IPv6. `000` for IPv4, because the name `web6` has no `A` record.

4. Try to change the primary family of the dual-stack Service `web`:

   ```bash
   kubectl patch svc web -p '{"spec":{"ipFamilies":["IPv6","IPv4"]}}'
   ```

   Expected output: an error. Kubernetes does not let you change `ipFamilies[0]` of an existing Service. To
   change it, delete the Service and make it again.

5. Delete the IPv6 Service:

   ```bash
   kubectl delete svc web6
   ```

### Experiment 2: Examine the IPv6 neighbors of a node

1. Show the IPv6 neighbor table of `dual-worker`:

   ```bash
   docker exec dual-worker ip -6 neigh show dev eth0
   ```

   Expected output (example):

   ```
   fc00:f853:ccd:e793::3 lladdr 02:42:ac:12:00:03 router REACHABLE
   fc00:f853:ccd:e793::4 lladdr 02:42:ac:12:00:04 router REACHABLE
   fe80::1 lladdr 02:42:9e:00:00:01 router STALE
   ```

   The other nodes are neighbors on `eth0`. They are the next hops of the IPv6 pod CIDR routes (step 1 of the
   procedure). IPv6 uses neighbor discovery (NDP), not ARP.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| The `up` task shows the IPv6 warning. | The Docker network `kind` has no IPv6, or `docker network inspect` failed. | See "Prerequisites". |
| Pods have only IPv4 addresses. | IPv6 is off in one layer. | Do `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDRs}'` and `cilium config view \| grep ipv6`. |
| The IPv6 world tests fail. | The host has no IPv6 forwarding and NAT for the ULA addresses. | Skip the world tests. This is normal. |
| Dual-stack does not start in an existing cluster. | You cannot change the families of a running kind cluster. | Do `mise run down` and `mise run up`. |

## Clean up

```bash
mise run down
```

This deletes the kind cluster `dual`.

## References

- Kubernetes dual-stack: https://kubernetes.io/docs/concepts/services-networking/dual-stack/
- kind configuration (`ipFamily`, subnets): https://kind.sigs.k8s.io/docs/user/configuration/
- Cilium routing concepts: https://docs.cilium.io/en/stable/network/concepts/routing/
- Cilium Helm values (`ipv6.*`): https://docs.cilium.io/en/stable/helm-reference/
