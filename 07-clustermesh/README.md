# 07 – Cluster Mesh: two kind clusters, one global service

## Purpose

This stage connects two Kubernetes clusters with Cilium **Cluster Mesh**. Pods in one cluster can connect to
pods in the other cluster. A **global service** sends requests to the backends of both clusters.

When you complete this stage, you know:

- The prerequisites of Cluster Mesh: unique cluster names and IDs, pod CIDRs that do not overlap, a shared CA.
- What the `clustermesh-apiserver` does and how the clusters connect to it.
- How the annotation `service.cilium.io/global: "true"` merges the backends of a Service.
- How to examine the data that one cluster exports to the other cluster.

## Concepts

### Two clusters on one Docker network

Both kind clusters use the Docker network `kind`. Thus, the nodes of `mesh1` can reach the nodes of `mesh2`
directly. Cilium uses VXLAN (the cilium-cli default) between all nodes of both clusters.

```
 ==+===================== docker network kind ==========================+==
   |                  |                               |                  |
 mesh1-control-   mesh1-worker                 mesh2-control-     mesh2-worker
 plane                                         plane
 cluster.name=mesh1, cluster.id=1              cluster.name=mesh2, cluster.id=2
 pods 10.1.0.0/16, services 10.11.0.0/16       pods 10.2.0.0/16, services 10.12.0.0/16
```

### Prerequisites

| Prerequisite | Why | Where |
|--------------|-----|-------|
| Unique `cluster.name` | Identifies the cluster in the mesh. | `--set cluster.name=meshN` in the `up` task |
| Unique `cluster.id` (1-255) | Cilium puts the cluster ID into the security identities. Identities must not collide. | `--set cluster.id=N` in the `up` task |
| Pod CIDRs do not overlap | A pod IP address must point to exactly one pod in the mesh. | `podSubnet` in `kind-mesh1.yaml`, `kind-mesh2.yaml` |
| Shared CA | The agents of one cluster must trust the certificates of the other cluster. | Secret `cilium-ca`, copied from `mesh1` to `mesh2` |

### The clustermesh-apiserver

Each cluster runs a `clustermesh-apiserver` with an etcd. It exports the state of the cluster: nodes,
endpoints, identities and global services. The Cilium agents of the other cluster connect to it and read
this state.

```
 mesh1                                         mesh2
 +---------------------------+                 +---------------------------+
 | clustermesh-apiserver     | <-- read ------ | cilium agents             |
 | (etcd, NodePort, mTLS)    |                 |                           |
 |                           |                 | clustermesh-apiserver     |
 | cilium agents             | ------ read --> | (etcd, NodePort, mTLS)    |
 +---------------------------+                 +---------------------------+
```

`values.yaml` sets `clustermesh.useAPIServer: true`. The chart defaults give the apiserver a `NodePort`
Service and make the TLS certificates with Helm. The certificates come from the CA `cilium-ca`. Thus, the
CA must be the same in both clusters.

`cilium clustermesh connect` writes the connection data (address and certificates) of each cluster into the
other cluster.

### Global service

A Service with the annotation `service.cilium.io/global: "true"` is a global service. It must have the same
name and namespace in both clusters. The agents merge the backends of both clusters:

```
 client (mesh1) --> Service echo (global)
                       |
                       +--> echo pod mesh1  "hello from mesh1"
                       +--> echo pod mesh1
                       +--> echo pod mesh2  "hello from mesh2"
                       +--> echo pod mesh2
```

Each `echo` pod answers with the name of its cluster. Thus, you can see which cluster answered.

### Name the Service port

The Service in `demo.yaml.tpl` has a named port (`name: http`). With an unnamed port, Cilium 1.18.0 exported
the backends without port information. Then the other cluster did not merge the remote backends, but
`cilium clustermesh status` showed no error. The name prevents this problem.

## Lab topology

| Item | mesh1 | mesh2 |
|------|-------|-------|
| kind config | `kind-mesh1.yaml` | `kind-mesh2.yaml` |
| Context | `kind-mesh1` | `kind-mesh2` |
| Nodes | `mesh1-control-plane`, `mesh1-worker` | `mesh2-control-plane`, `mesh2-worker` |
| Cluster ID | 1 | 2 |
| Pod subnet | `10.1.0.0/16` | `10.2.0.0/16` |
| Service subnet | `10.11.0.0/16` | `10.12.0.0/16` |
| Demo | `echo` (2 pods, "hello from mesh1"), `client` | `echo` (2 pods, "hello from mesh2"), `client` |

Both contexts are in one file, `build/kubeconfig`. The current context is the context of the cluster that
kind made last (`kind-mesh2`). Thus, always give `--context` to `kubectl` and `cilium` in this stage.

## Files

| File | Content |
|------|---------|
| `kind-mesh1.yaml`, `kind-mesh2.yaml` | Two nodes for each cluster, no default CNI, no kube-proxy, different subnets. |
| `values.yaml` | `clustermesh.useAPIServer: true`. |
| `demo.yaml.tpl` | Deployment `echo`, global Service `echo` (named port), pod `client`. `${NAME}` is the cluster name. |
| `mise-tasks/up` | Both clusters, Cilium with a shared CA, connect, demo in both clusters, then `check`. |
| `mise-tasks/check` | Sends requests from `mesh1` until replies come from both clusters. |

## Procedure

Do the steps in the stage folder (`07-clustermesh/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 kind_up kind-mesh1.yaml, kind_up kind-mesh2.yaml
 cilium install (mesh1, cluster.id=1)
 copy secret kube-system/cilium-ca: mesh1 --> mesh2      (before Cilium is in mesh2)
 cilium install (mesh2, cluster.id=2)                     (uses the copied CA)
 cilium clustermesh connect --context kind-mesh1 --destination-context kind-mesh2
 cilium clustermesh status --context kind-mesh1 --wait
 apply demo.yaml.tpl in both clusters (NAME=mesh1, NAME=mesh2)
 mise run check
```

The task copies the CA before the second install. If `cilium install` finds no `cilium-ca`, it makes a new
CA. Then the clusters do not trust each other.

Expected output of the check (example):

```
--- waiting until mesh1 gets replies from BOTH clusters (up to ~2 min)...
     11 hello from mesh1
      9 hello from mesh2
OK: global service balances across both clusters
```

The check sends 20 requests. The numbers change from run to run. If only one cluster answers for 2 minutes,
the task fails with `FAIL: only one cluster answers`.

### Step 2: Examine the mesh status

Examine both directions. Each cluster shows only its own view:

```bash
cilium clustermesh status --context kind-mesh1
cilium clustermesh status --context kind-mesh2
```

Expected output (example, part):

```
✅ Service "clustermesh-apiserver" of type "NodePort" found
✅ Cluster access information is available:
  - 172.18.0.3:32379
✅ Deployment clustermesh-apiserver is ready
✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]
🔌 Cluster Connections:
  - mesh2: 2/2 configured, 2/2 connected
```

### Step 3: Examine the merged backends

1. Show the Service table of an agent in `mesh1`:

   ```bash
   kubectl --context kind-mesh1 -n kube-system exec ds/cilium -- cilium-dbg service list
   ```

   Find the ClusterIP of `echo` (`kubectl --context kind-mesh1 get svc echo`). It has four backends: two
   with `10.1.x.x` addresses (mesh1) and two with `10.2.x.x` addresses (mesh2).

2. Send requests from the client in `mesh2`:

   ```bash
   for i in $(seq 10); do kubectl --context kind-mesh2 exec client -- curl -s http://echo:5678; done
   ```

   Expected output: a mix of `hello from mesh1` and `hello from mesh2`.

### Step 4: Fail over to the other cluster

1. Scale `echo` in `mesh1` to zero:

   ```bash
   kubectl --context kind-mesh1 scale deploy echo --replicas=0
   ```

2. Send requests from the client in `mesh1`:

   ```bash
   for i in $(seq 5); do kubectl --context kind-mesh1 exec client -- curl -s http://echo:5678; done
   ```

   Expected output: only `hello from mesh2`. The local Service has no local backends, but the global service
   still works.

3. Scale `echo` back: `kubectl --context kind-mesh1 scale deploy echo --replicas=2`.

## Experiments

- **Local preference.** Add the annotation `service.cilium.io/affinity: "local"` to the Service in both
  clusters. Then each cluster uses its local backends first and the remote backends only if there is no local
  backend.
- **Remove a cluster from a Service.** Set `service.cilium.io/shared: "false"` on the Service in `mesh2`. Then
  `mesh2` does not export its backends, but it still uses the backends of `mesh1`.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `clustermesh status` shows all green, but only the local cluster answers. | The Service port has no name (seen with Cilium 1.18.0). | Give the port a name (`name: http`). Examine the exported record (see below). |
| The agents cannot connect to the other cluster: TLS errors. | The clusters have different CAs. | Do `mise run down` and `mise run up`. The task copies the CA before the second install. |
| `kubectl` shows the wrong cluster. | The current context is `kind-mesh2`. | Always use `--context kind-mesh1` or `--context kind-mesh2`. |
| `cilium clustermesh connect` fails. | The clustermesh-apiserver is not ready. | Do `cilium clustermesh status --context kind-mesh1 --wait` and try again. |

### Examine the exported record

The clustermesh-apiserver keeps the exported services in etcd. Read the record of `echo` with a one-shot pod.
The pod uses the client certificate in the secret `clustermesh-apiserver-local-cert`. The `etcd` image has no
`sleep`. Thus, `etcdctl` must be the command of the pod. Then read the output with `kubectl logs`.

```bash
kubectl --context kind-mesh1 -n kube-system run etcdctl --restart=Never --image=quay.io/coreos/etcd:v3.6.5 \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "etcdctl",
        "image": "quay.io/coreos/etcd:v3.6.5",
        "command": ["etcdctl", "--endpoints=https://clustermesh-apiserver.kube-system.svc:2379",
                    "--cacert=/tls/ca.crt", "--cert=/tls/tls.crt", "--key=/tls/tls.key",
                    "get", "--prefix", "cilium/cache/services/v1/mesh1/"],
        "volumeMounts": [{"name": "tls", "mountPath": "/tls"}]
      }],
      "volumes": [{"name": "tls", "secret": {"secretName": "clustermesh-apiserver-local-cert"}}]
    }}'
kubectl --context kind-mesh1 -n kube-system logs etcdctl
kubectl --context kind-mesh1 -n kube-system delete pod etcdctl
```

The backends must have port information, for example:

```
{"10.1.1.42":{"http":{"Protocol":"TCP","Port":5678}}}
```

If the port name is empty and the record has no port, the other cluster ignores the backends.

## Clean up

```bash
mise run down
```

This deletes both kind clusters, `mesh1` and `mesh2`.

## References

- Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/
- Set up Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/
- Load balancing and global services: https://docs.cilium.io/en/stable/network/clustermesh/services/
- kind configuration (pod and Service subnets): https://kind.sigs.k8s.io/docs/user/configuration/
