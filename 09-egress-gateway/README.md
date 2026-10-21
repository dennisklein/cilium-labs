# 09 – Egress Gateway: pods leave the cluster with a fixed source IP

## Purpose

Usually, the traffic of a pod leaves the cluster with the IP address of its node as the source address (SNAT).
The node can change when Kubernetes schedules the pod again. Thus, an external firewall cannot identify the
pod. An **egress gateway** solves this problem. Cilium sends the traffic of selected pods to selected
destinations through a gateway node. The gateway node changes the source address to a fixed **egress IP**.

When you complete this stage, you know:

- The parts of a `CiliumEgressGatewayPolicy`: pod selector, destination CIDRs, gateway node selector, egress IP.
- Why the egress IP must be an address on an interface of the gateway node.
- How a policy change moves the traffic to a different gateway.
- What the Helm prerequisites of the egress gateway are.

## Concepts

### Without and with an egress gateway

```
 without a policy:
 client pod (egress-worker3) --> egress-worker3 SNAT to its node IP --> ? (no route to 10.30.2.0/24)

 with a policy:
 client pod (egress-worker3) --VXLAN--> gateway node --SNAT to egress IP--> router --> server
```

The client pod and the gateway are on different nodes. Cilium sends the packet from the node of the pod to the
gateway node through the VXLAN tunnel. The gateway node changes the source address to the egress IP and sends
the packet out on its uplink `eth1`.

### The policy

```yaml
kind: CiliumEgressGatewayPolicy
spec:
  selectors:
  - podSelector: {matchLabels: {egress: "true"}}       # which pods
  destinationCIDRs: ["10.30.2.0/24"]                    # which destinations
  egressGateway:
    nodeSelector: {matchLabels: {egress-gw: "a"}}       # which gateway node
    egressIP: 10.30.1.100                               # which source address
```

Only traffic that agrees with the pod selector **and** the destination CIDRs goes through the gateway. Other
traffic of the same pod uses the usual path.

### The egress IP must be on the gateway

The gateway node uses the egress IP as the source address. Replies come back to the egress IP. Thus, the
egress IP must be an address of the gateway node. The `up` task adds it as a second address on `eth1`
(function `wire`):

```
 egress-worker   eth1: 10.30.1.1/24 (uplink), 10.30.1.100/24 (egress IP A)
 egress-worker2  eth1: 10.30.3.1/24 (uplink), 10.30.3.100/24 (egress IP B)
```

If the egress IP is not on the selected gateway node, the gateway drops the traffic that agrees with the
policy.

### Helm prerequisites

| Helm value | Value | Set by |
|------------|-------|--------|
| `egressGateway.enabled` | `true` | `values.yaml` |
| `bpf.masquerade` | `true` | `values.yaml` |
| `kubeProxyReplacement` | `true` | `cilium install` (kube-proxy is not present) |
| `l7Proxy` | `false` | `values.yaml` (older documents list the L7 proxy as not compatible) |
| `devices` | `eth+` | `values.yaml` (Cilium must use the uplink `eth1`) |
| routing | VXLAN tunnel | `cilium install` default for kind |

## Lab topology

```
                      VXLAN (cluster, Docker bridge eth0)
  egress-worker3  ------------------------------+------------------------------+
  client-egress (egress=true)                   |                              |
  client-plain                                  v                              v
                                         egress-worker (gw A)          egress-worker2 (gw B)
                                         egress-gw=a                   egress-gw=b
                                         eth1 10.30.1.1                eth1 10.30.3.1
                                         egress IP 10.30.1.100         egress IP 10.30.3.100
                                                |                              |
                                     10.30.1.254 eth1                10.30.3.254 eth3
                                                +---------- router ------------+
                                                       eth2 10.30.2.254
                                                            |
                                                   server 10.30.2.2 (nginx)
                                                   logs the source IP address
```

| Item | Value |
|------|-------|
| Cluster name | `egress` |
| Nodes | `egress-control-plane`, `egress-worker` (gw A), `egress-worker2` (gw B), `egress-worker3` (clients) |
| Routing | VXLAN tunnel |
| External lab | containerlab `cilium-egress`: `router` (netshoot), `server` (nginx) |
| Server network | `10.30.2.0/24`, reachable only from the gateway nodes |
| Demo pods | `client-egress` (label `egress=true`), `client-plain` (no label), both on `egress-worker3` |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Control plane and three workers, no default CNI, no kube-proxy. |
| `values.yaml` | Egress gateway, BPF masquerade, no L7 proxy, `devices: eth+`. |
| `demo.yaml` | The two client pods on `egress-worker3`. |
| `policy-a.yaml` | Policy `via-gateway`: gateway A, egress IP `10.30.1.100`. |
| `policy-b.yaml` | Policy `via-gateway`: gateway B, egress IP `10.30.3.100`. |
| `topo.clab.yml` | Router, server, the two gateway nodes as `ext-container`, and the links. |
| `mise-tasks/up` | Cluster, Cilium, labels, demo, containerlab, gateway wiring, agent restart, then `check`. |
| `mise-tasks/check` | The walkthrough: no policy, gateway A, gateway B. |

The `check` task of this stage changes the cluster: it deletes and applies the policies. At the end, policy B
is active.

## Prerequisites

- containerlab (from `mise.toml`).
- `sudo` access. The `up` and `down` tasks ask for the password first.

## Procedure

Do the steps in the stage folder (`09-egress-gateway/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 sudo -v
 kind_up, cilium_up
 kubectl label node egress-worker egress-gw=a, egress-worker2 egress-gw=b
 wait_crds ciliumegressgatewaypolicies.cilium.io, apply demo.yaml
 clab deploy -t topo.clab.yml                         router, server, links to the gateways
 wire egress-worker   10.30.1.1 + 10.30.1.100, route 10.30.2.0/24 via 10.30.1.254
 wire egress-worker2  10.30.3.1 + 10.30.3.100, route 10.30.2.0/24 via 10.30.3.254
 kubectl -n kube-system rollout restart ds/cilium     (Cilium finds eth1)
 mise run check
```

### Step 2: Follow the walkthrough of the check task

The `check` task has three parts. Expected output (example, shortened):

```
--- 1) no policy: the server network is only routable from the gateway nodes (expect 000 = unreachable)
client-egress: 000
--- 2) policy via gateway A (egress IP 10.30.1.100)
ciliumegressgatewaypolicy.cilium.io/via-gateway created
client-egress: 200
client-plain (not selected): 000
server saw:
10.30.1.100 - - [21/Oct/2026:10:00:01 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.23.0" "-"
10.30.1.100 - - [21/Oct/2026:10:00:01 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.23.0" "-"
--- 3) move to gateway B (egress IP 10.30.3.100)
ciliumegressgatewaypolicy.cilium.io/via-gateway created
client-egress: 200
server saw:
10.30.3.100 - - [21/Oct/2026:10:00:09 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.23.0" "-"
10.30.3.100 - - [21/Oct/2026:10:00:09 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.23.0" "-"
--- datapath entries
Source IP     Destination CIDR   Egress IP     Gateway IP
10.244.3.17   10.30.2.0/24       10.30.3.100   172.18.0.4
```

What the parts show:

1. **No policy.** `egress-worker3` has no route to `10.30.2.0/24`. curl shows `000` (no connection).
2. **Gateway A.** The traffic of `client-egress` goes through `egress-worker`. The server log shows the
   source address `10.30.1.100`. `client-plain` has no label. Its traffic does not go through the gateway, so
   it still gets `000`.
3. **Gateway B.** The task replaces policy A with policy B. Now the server log shows `10.30.3.100`. The
   pods did not change. Only the policy changed.

The `datapath entries` table comes from the eBPF map of one agent. `Gateway IP` is the address of the gateway
node on the Docker bridge.

### Step 3: Send requests by hand

```bash
kubectl exec client-egress -- curl -s -m 3 http://10.30.2.2 | head -n 4
docker logs clab-cilium-egress-server 2>&1 | tail -n 3
```

The last log line shows the egress IP of the active policy.

### Step 4: Examine the gateway node

```bash
docker exec egress-worker2 ip addr show eth1
kubectl get ciliumegressgatewaypolicies
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
```

`eth1` of `egress-worker2` has the uplink address and the egress IP.

## Experiments

- **Gateway failure.** With policy B active, stop the gateway: `docker stop egress-worker2`. The traffic of
  `client-egress` stops, because the policy selects only that node. Start it again with
  `docker start egress-worker2`.
- **Select the interface, not the address.** In policy A, remove `egressIP` and set `interface: eth1`. Cilium
  then uses the first IPv4 address of `eth1` on the gateway (`10.30.1.1`). The server log shows this address.
- **Wrong egress IP.** Set `egressIP: 10.30.1.200` in policy A (an address that is not on the node) and apply
  it. The traffic of `client-egress` stops.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `client-egress` gets `000` with a policy. | The egress IP is not on the gateway, or Cilium does not use `eth1`. | Do `docker exec egress-worker ip addr show eth1`. Restart the agents. |
| `cilium-dbg bpf egress list` is empty. | The policy selects no pod or no node. | Do `kubectl get pods --show-labels` and `kubectl get nodes -L egress-gw`. |
| The server log shows a node address, not the egress IP. | The traffic did not go through the policy. | Make sure the destination is in `destinationCIDRs`. |
| The agents do not start with the egress gateway. | A prerequisite is missing. | Do `cilium config view \| grep -E 'egress\|masquerade\|kube-proxy'`. |

## Clean up

```bash
mise run down
```

This destroys the containerlab lab first, then deletes the kind cluster `egress`.

## References

- Egress Gateway: https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- containerlab `ext-container`: https://containerlab.dev/manual/kinds/ext-container/
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/
