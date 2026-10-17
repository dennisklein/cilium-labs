# Cilium + kind + containerlab lab ladder

Run `./NN-xxx/up.sh`, experiment, then `./NN-xxx/down.sh`. One stage at a time (stages 1-5 reuse the cluster name `lab`).

| Stage | Adds | Containerlab required|
|-------|------|----------------------|
| [01-basic](01-basic/README.md) | kind + Cilium, VXLAN tunnel, kube-proxy still present | no |
| [02-kpr-hubble-policy](02-kpr-hubble-policy/README.md) | kube-proxy replacement, Hubble, WireGuard, L7 policy | no |
| [03-native-routing](03-native-routing/README.md) | no tunnel, native routing, BPF masquerade | no |
| [04-lbipam-l2](04-lbipam-l2/README.md) | LB-IPAM + L2 announcements on the docker bridge | no |
| [05-bgp-frr](05-bgp-frr/README.md) | Cilium BGP control plane peering with an FRR container on the kind network | yes (mgmt = kind network) |
| [06-fabric](06-fabric/README.md) | spine/leaf FRR fabric, per-node uplinks (ext-container), external client reaching LB IPs over BGP/ECMP | yes (ext-container) |
| [07-clustermesh](07-clustermesh/README.md) | two kind clusters, Cluster Mesh, global service | no |
| [08-dual-stack](08-dual-stack/README.md)   | IPv4 + IPv6 pods and Services, native routing for both families | no |
| [09-egress-gateway](09-egress-gateway/README.md) | selected pods leave via a gateway node with a fixed egress IP, through a router to an external server | yes (ext-container) |

### Quick start

* Use the wrapper installation script:
```
./install-tools.sh 
```
* It will perform a user-level install of:
  - `kubectl`;
  - `kind`;
  - `helm`;
  - `cilium-cli`;
  - `containerlab`: only if root is available;
  - `jq`
* It will also check for `docker/envsubst/inotify`.

### Tools required to run the labs

* `docker, kind, kubectl, helm, envsubst` (gettext): all labs;
* `containerlab`: labs 05/06;
* `cilium-cli` + `jq`: lab 07.

### Recommendations (nice to have)

* **Host**: raise `inotify` limits (`fs.inotify.max_user_watches=524288`, `max_user_instances=512`).

### Notes

* Pinned: Cilium 1.18.0 (CILIUM_VERSION env), FRR 10.2.1.
* `kind` commands need `--name <cluster>` (or `export KIND_CLUSTER_NAME=lab`); `kind get clusters` lists all.
* If labs are launched on a host behind a proxy: put the docker subnet(s) and `10.244.0.0/16, 10.96.0.0/12, 10.200.0.0/24` in `NO_PROXY` (proper CIDRs, e.g. 172.18.0.0/16). Pods don't use the proxy, so skip the connectivity tests that need direct internet (see [03-native-routing](03-native-routing/up.sh)).
* Labs 05/06 run `sudo containerlab` without `-E`; the topology is rendered with `envsubst` beforehand.
* After editing an FRR config, destroy and redeploy the lab (destroy, re-render, deploy).

#### Cluster Mesh troubleshooting (stage 07)

- Symptom: mesh healthy (`cilium clustermesh status` all green) but a global service only answers locally.
- Cause found: an UNNAMED service port. Cilium 1.18.0 exported the remote backends with empty port info.
- Fix: give the port a name (`name: http`). Check the exported record:
  - `etcdctl get --prefix cilium/cache/services/v1/<cluster>/` via a throwaway pod using secret `clustermesh-apiserver-local-cert`;
  - backends must look like: `{"10.2.1.42":{"http":{"Protocol":"TCP","Port":5678}}}`.
- Note: the `etcd` image has no `sleep`; run `etcdctl` as the pod's only command and read `kubectl logs`.

## Documentation

Each lab has its own README (scope, verify commands, gotchas, official docs).
- kind: https://kind.sigs.k8s.io/docs/user/quick-start/ , configuration https://kind.sigs.k8s.io/docs/user/configuration/ , known issues https://kind.sigs.k8s.io/docs/user/known-issues/
- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/ , Helm values https://docs.cilium.io/en/stable/helm-reference/
- containerlab: https://containerlab.dev/ , kinds https://containerlab.dev/manual/kinds/
- Version note: the labs pin Cilium 1.18.0, while `docs.cilium.io/en/stable/` tracks a newer release.
  If a page or CRD apiVersion differs from what you see in the lab, replace `stable` by `v1.18` in the URL.
