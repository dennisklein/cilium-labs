# 09 – Egress Gateway: pods leave the cluster with a fixed source IP

**Scope.** Normally a pod's traffic leaves the cluster with its *node's* IP, which changes with scheduling.
With an **egress gateway** the traffic of selected pods to selected destinations is redirected to a chosen gateway
node and SNATed to a predictable IP. Here two kind workers (gateways A and B) have an uplink (`eth1`) to a router,
and an external `server` (nginx) sits behind the router and logs the source IP of each request.

```
 client pods (egress-worker3) --cluster--> gateway A (egress-worker,  eth1 10.30.1.1, egress IP 10.30.1.100) --\
                                                                                                           router --- server 10.30.2.2
                                       \-> gateway B (egress-worker2, eth1 10.30.3.1, egress IP 10.30.3.100) --/
```

**What you learn**
- The policy: `CiliumEgressGatewayPolicy` = pod selector + destination CIDRs + gateway node selector + `egressIP`.
- The egress IP must exist on a gateway interface (the script adds it as a secondary address on `eth1`).
- Changing the gateway is just a policy change: the server sees the other egress IP afterwards.

**Run / verify / tear down**
```bash
mise run up     # 1) no policy -> unreachable (000)   2) via gateway A -> server logs 10.30.1.100
mise run check   # the probes only; run again at any time
            # 3) via gateway B -> server logs 10.30.3.100; the unlabeled client stays unreachable
kubectl exec client-egress -- curl -s -m 3 http://10.30.2.2
docker logs clab-cilium-egress-server 2>&1 | tail
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
mise run down
```

**Gotchas**
- Requires `egressGateway.enabled`, `bpf.masquerade` and `kubeProxyReplacement` (all set in `values.yaml`).
  `l7Proxy: false` is set because older docs list the L7 proxy as incompatible.
- The server network is only routable from the gateway nodes, so the lab proves the redirect: an unselected pod can't reach it at all.
- A policy whose `egressIP` is not configured on the selected gateway makes it drop matching traffic.
- Uses VXLAN tunnel mode, the commonly documented path. Native routing hasn't been tried here.
- The `up` task restarts the agents after wiring `eth1` so `devices: eth+` picks the uplink up. IPv4 only.

**Docs**
- Egress Gateway: https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- containerlab `ext-container`: https://containerlab.dev/manual/kinds/ext-container
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/
