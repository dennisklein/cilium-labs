# 04 – LoadBalancer IPs without a cloud: LB-IPAM + L2 announcements

**Scope.** Native-routing cluster plus Cilium **LB-IPAM** (hands out `LoadBalancer` IPs from a pool) and
**L2 announcements** (a node answers ARP for that IP). The pool is carved from the top of the kind Docker subnet
(`<prefix>.255.200-250`, computed at run time), so the host can `curl` the service directly.

**What you learn**
- How `type: LoadBalancer` works on bare metal with only Cilium.
- L2 leader election per service (one node "owns" the IP at a time).

**Run / verify / tear down**
```bash
./up.sh                                    # prints the LB IP and curls it
kubectl get svc web
kubectl -n kube-system get lease | grep -i l2    # which node announces the IP
./down.sh
```

**Gotchas**
- Works when the host sits on the Docker bridge (Docker Engine on Linux). It will not work with Docker Desktop.
- Add the pool range to `NO_PROXY` if your host uses a proxy.
- `k8sClientRateLimit` is raised in `values.yaml` because L2 leases generate extra API traffic.
- The pool/policy CRDs use `cilium.io/v2alpha1`; check `kubectl explain` if you upgrade Cilium.

**Docs**
- LB-IPAM: https://docs.cilium.io/en/stable/network/lb-ipam/
- L2 announcements: https://docs.cilium.io/en/stable/network/l2-announcements/
- kind + LoadBalancer background: https://kind.sigs.k8s.io/docs/user/known-issues/
