# 08 – Dual-stack (IPv4 + IPv6)

**Scope.** Lab 03's native-routing cluster, but every pod and Service gets **both an IPv4 and an IPv6 address**.
kind runs in `ipFamily: dual` mode and Cilium has IPv6 enabled; nodes still route pod CIDRs directly to each other
(`autoDirectNodeRoutes`), now for both families. The demo checks pod-to-pod traffic across nodes per family and
Service access over IPv4 and IPv6.

**What you learn**
- The three places dual-stack must be configured consistently: kind (`ipFamily`, two pod/service CIDRs),
  Kubernetes objects (`ipFamilyPolicy: RequireDualStack`) and Cilium (`ipv6.enabled`, `ipv6NativeRoutingCIDR`).
- That native routing, Service load-balancing and masquerading work per family, with separate routes for each.

**Run / verify / tear down**
```bash
mise run up          # prints pod IPs, Service IPs, per-family HTTP checks and the IPv6 routes
mise run check   # the probes only; run again at any time
kubectl get pod -o jsonpath='{.items[*].status.podIPs}'
docker exec lab-worker ip -6 route | grep fd00:10:244
cilium connectivity test --test '!pod-to-world,!pod-to-cidr,!to-entities-world,!to-fqdns'
mise run down
```

**Gotchas**
- Docker's `kind` network must have IPv6 enabled (kind creates it that way when the Docker daemon supports it).
  Check with `docker network inspect kind -f '{{.EnableIPv6}}'`; the `up` task warns if it can't confirm.
- Pods and nodes get IPv6 only inside the Docker network (ULA addresses). Reaching the **IPv6 internet** also needs
  IPv6 forwarding/NAT on the host, which is usually absent, so keep the *world* tests skipped.
- The `up` task passes the control plane's IPv4 address as `k8sServiceHost` instead of its container name, as a precaution so
  the name doesn't resolve to IPv6 first (not something that failed in testing).
- Dual-stack can't be switched on in an existing cluster here: recreate it (`mise run down && mise run up`).

**Docs**
- Kubernetes dual-stack: https://kubernetes.io/docs/concepts/services-networking/dual-stack/
- kind configuration (`ipFamily`, subnets): https://kind.sigs.k8s.io/docs/user/configuration/
- Cilium routing concepts: https://docs.cilium.io/en/stable/network/concepts/routing/
- Cilium Helm values (`ipv6.*`): https://docs.cilium.io/en/stable/helm-reference/
