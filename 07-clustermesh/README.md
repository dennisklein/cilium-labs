# 07 – Cluster Mesh: two kind clusters, one global service

**Scope.** Two clusters (`mesh1`, `mesh2`) on the same Docker network with non-overlapping pod/service CIDRs,
a shared Cilium CA and **Cluster Mesh** connecting them. A Service annotated `service.cilium.io/global: "true"`
load-balances across the pods of *both* clusters.

**What you learn**
- Cluster Mesh prerequisites: unique cluster name/ID, non-overlapping CIDRs, shared CA.
- Global services, and how to inspect what a cluster exports.

**Run / verify / tear down**
```bash
./up.sh                                          # ends with OK once replies come from both clusters
cilium clustermesh status --context kind-mesh1
cilium clustermesh status --context kind-mesh2
kubectl --context kind-mesh1 exec client -- curl -s http://echo:5678
./down.sh
```

**Gotchas (hit during testing)**
- **Name the Service port.** With an unnamed port, Cilium 1.18.0 exported the backends without port info and no
  remote backends were merged, even though `clustermesh status` was all green. Check the exported record:
  backends should look like `{"10.2.1.42":{"http":{"Protocol":"TCP","Port":5678}}}`.
- Both `clustermesh status` directions must be checked: each cluster only reports its own view.
- Two clusters means two contexts (`kind-mesh1`, `kind-mesh2`); use `--context`.
- Reading the exported data without `etcdctl` in the image: run a one-shot pod with the `etcd` image and
  secret `clustermesh-apiserver-local-cert` (the etcd image has no `sleep`; make `etcdctl` the pod's command).

**Docs**
- Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/
- Load-balancing & global services: https://docs.cilium.io/en/stable/network/clustermesh/services/
- kind configuration (pod/service subnets): https://kind.sigs.k8s.io/docs/user/configuration/
