# 02 – kube-proxy replacement, Hubble, WireGuard, L7 policy

## Purpose

This stage uses the VXLAN topology of stage [01](../01-basic/README.md) and adds four functions:

1. **kube-proxy replacement.** kube-proxy is not installed. Cilium implements Services in eBPF.
2. **Hubble.** You can see each network flow in the cluster.
3. **WireGuard.** Cilium encrypts pod traffic between nodes.
4. **L7 network policy.** A `CiliumNetworkPolicy` lets the `client` pod send only `GET /` to the `server` pods.

When you complete this stage, you know:

- How Cilium does Service load balancing without kube-proxy and without iptables.
- Why the Cilium agent needs the real address of the API server when kube-proxy is not present.
- How to see flows and policy decisions with Hubble.
- How a policy can allow or deny traffic at L3/L4 (addresses, ports) and at L7 (HTTP method and path).
- How to make sure that WireGuard encrypts the traffic between nodes.

## Concepts

### kube-proxy replacement

kube-proxy usually writes iptables rules on each node. These rules change a Service IP address (ClusterIP) to
the IP address of a backend pod. Cilium can do this work in eBPF programs. The eBPF program selects the backend
when the pod opens the connection (socket-level load balancing). Thus, the packet goes directly to the
backend pod.

```
 with kube-proxy (stage 01)               with Cilium kube-proxy replacement (this stage)

 client pod                               client pod
    | dst 10.96.x.x:80 (ClusterIP)           | connect(10.96.x.x:80)
    v                                        v
 iptables DNAT (kube-proxy rules)         eBPF at the socket: dst = 10.244.2.7:80
    | dst 10.244.2.7:80                      |
    v                                        v
 server pod                               server pod
```

`kind.yaml` sets `kubeProxyMode: none`, so kind does not install kube-proxy. `cilium install` finds that
kube-proxy is not present. Then it sets these Helm values:

| Helm value | Value | Why |
|------------|-------|-----|
| `kubeProxyReplacement` | `true` | Cilium must implement Services. |
| `k8sServiceHost`, `k8sServicePort` | address and port of the API server | See below. |

The Cilium agent must connect to the Kubernetes API server. Usually it uses the Service `kubernetes`
(`10.96.0.1`). Without kube-proxy, nothing implements this Service before Cilium starts. Thus, Cilium must
use the real address of the API server. cilium-cli reads it from the EndpointSlice `default/kubernetes`.

### Hubble

Hubble is the observability layer of Cilium. Each Cilium agent records the flows that go through its eBPF
programs. Hubble Relay collects the flows of all nodes. The `hubble` CLI and the Hubble UI read the flows from
Hubble Relay.

```
 node 1: cilium agent (hubble server) --+
 node 2: cilium agent (hubble server) --+--> hubble-relay --> hubble CLI (port-forward 4245)
 node 3: cilium agent (hubble server) --+                 --> hubble-ui
```

Hubble is on by default in the agent. `values.yaml` adds Hubble Relay and the Hubble UI.

### WireGuard transparent encryption

Each Cilium agent makes a WireGuard key pair and a WireGuard interface `cilium_wg0`. The agent publishes its
public key in the `CiliumNode` object. All agents add the other nodes as WireGuard peers. Pod traffic to a
different node goes through `cilium_wg0` (UDP port 51871). The pods do not know about the encryption.

```
 pod (kpr-worker) --> cilium_wg0 ==== encrypted UDP 51871 ====> cilium_wg0 --> pod (kpr-worker2)
```

WireGuard must be in the host kernel (Linux 5.6 or later). The kind nodes use the kernel of the host.

### L7 policy

Without a policy, all pods can connect to all pods. When a policy selects a pod, the pod accepts only the
traffic that the policy allows (default deny).

The policy `client-get-only` in `demo.yaml` selects the `server` pods. It has two parts:

```yaml
ingress:
- fromEndpoints: [{matchLabels: {app: client}}]   # L3: only from pods with app=client
  toPorts:
  - ports: [{port: "80", protocol: TCP}]           # L4: only TCP port 80
    rules:
      http: [{method: "GET", path: "/"}]           # L7: only GET /
```

For the L7 rule, Cilium sends the connections to port 80 through an Envoy proxy. Envoy reads each HTTP request.
If the request does not agree with the rule, Envoy sends `403 Forbidden`. The connection stays open.

```
 client --GET /--> eBPF --> Envoy (L7 rule: allow) --> server   -> 200
 client --POST /-> eBPF --> Envoy (L7 rule: deny)               -> 403 from Envoy
 other  --GET /--> eBPF (L3 rule: deny, drop)                   -> timeout
```

## Lab topology

| Item | Value |
|------|-------|
| Cluster name | `kpr` |
| Nodes | `kpr-control-plane`, `kpr-worker`, `kpr-worker2` |
| Routing | tunnel, VXLAN (cilium-cli default for kind) |
| kube-proxy | no, Cilium replaces it |
| Encryption | WireGuard |
| Demo namespace | `demo`: Deployment `server` (2 x nginx), Service `server`, pod `client` (curl) |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Three nodes, no default CNI, `kubeProxyMode: none`. |
| `values.yaml` | Hubble Relay and UI, WireGuard encryption. |
| `demo.yaml` | Namespace `demo`, server, client and the policy `client-get-only`. |
| `mise-tasks/up` | Cluster, Cilium, wait for the policy CRD, demo, then `check`. |
| `mise-tasks/check` | Sends `GET` and `POST` from the client to the server. |

## Procedure

Do the steps in the stage folder (`02-kpr-hubble-policy/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 kind_up         kind create cluster --name kpr          (no kube-proxy)
 cilium_up       cilium install --values values.yaml     (sets kubeProxyReplacement=true)
 wait_crds       wait for ciliumnetworkpolicies.cilium.io
 kubectl apply   demo.yaml, then wait until the pods are Ready
 mise run check  the HTTP probes
```

The task waits for the CRD, because the Cilium operator makes the Cilium CRDs some seconds after
`cilium install` stops. Expected output of `cilium install` (part):

```
🔮 Auto-detected Kubernetes kind: kind
ℹ️  Detecting real Kubernetes API server addr and port on Kind
🔮 Auto-detected kube-proxy has not been installed
ℹ️  Cilium will fully replace all functionalities of kube-proxy
```

Expected output of the check at the end:

```
--- allowed:
200
--- denied (expect 403 from L7 proxy):
403
Hubble UI: cilium hubble ui   |  flows: hubble observe -n demo
```

### Step 2: Examine the kube-proxy replacement

1. Make sure that kube-proxy is not present:

   ```bash
   kubectl -n kube-system get ds kube-proxy
   ```

   Expected output: `Error from server (NotFound): daemonsets.apps "kube-proxy" not found`.

2. Show the status of the agent:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -iE 'kubeproxy|encryption'
   ```

   Expected output (example):

   ```
   KubeProxyReplacement:    True   [eth0   172.18.0.3 fc00:f853:ccd:e793::3 (Direct Routing)]
   Encryption:              Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: ..., Port: 51871, Peers: 2)]
   ```

   `Peers: 2` tells you that the node has a WireGuard tunnel to each of the two other nodes.

3. Show the Service table in eBPF. Each ClusterIP has one entry for each backend:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
   ```

   Find the ClusterIP of `demo/server` (`kubectl -n demo get svc server`). It has two backends, one for each
   server pod.

### Step 3: Send requests through the L7 policy

1. Send an allowed request:

   ```bash
   kubectl -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server/
   ```

   Expected output: `200`.

2. Send a request with a different method:

   ```bash
   kubectl -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' -X POST http://server/
   ```

   Expected output: `403`. Envoy blocked the request.

3. Send a request to a different path:

   ```bash
   kubectl -n demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server/index.html
   ```

   Expected output: `403`. The rule allows only the path `/`.

4. Send a request from a pod that the policy does not allow:

   ```bash
   kubectl -n demo run other --rm -i --restart=Never --image=curlimages/curl:8.23.0 --command -- \
     curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://server/
   ```

   Expected output: `000` after 3 seconds. Cilium dropped the packets at L3, so the TCP connection did not
   start.

### Step 4: Observe the flows with Hubble

1. Open a port forward to Hubble Relay. Keep it open in a second terminal:

   ```bash
   cilium hubble port-forward
   ```

2. Show the flows in the namespace `demo`:

   ```bash
   hubble observe -n demo --last 20
   ```

   Expected output (example, shortened):

   ```
   demo/client:51234 (ID:1234) -> demo/server-...:80 (ID:5678) http-request FORWARDED (HTTP/1.1 GET http://server/)
   demo/client:51234 (ID:1234) <- demo/server-...:80 (ID:5678) http-response FORWARDED (HTTP/1.1 200 1ms (GET http://server/))
   demo/client:51240 (ID:1234) -> demo/server-...:80 (ID:5678) http-request DROPPED (HTTP/1.1 POST http://server/)
   demo/other:40000 (ID:9999) <> demo/server-...:80 (ID:5678) Policy denied DROPPED (TCP Flags: SYN)
   ```

3. Show only the dropped flows:

   ```bash
   hubble observe -n demo --verdict DROPPED
   ```

4. Open the Hubble UI in a browser (optional):

   ```bash
   cilium hubble ui
   ```

### Step 5: Make sure that WireGuard encrypts the traffic

Show the WireGuard peers on a node:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

Expected output (example):

```
Encryption: Wireguard
Interface: cilium_wg0
	Public key: ...
	Number of peers: 2
```

## Experiments

- Change the L7 rule to allow `POST` too. Apply `demo.yaml` again and send the POST request.
- Delete the policy (`kubectl -n demo delete cnp client-get-only`). Then the `other` pod can connect.
- Remove the `encryption` block from `values.yaml` and apply it to the running cluster:
  `cilium upgrade --values values.yaml`. Then `cilium-dbg status` shows `Encryption: Disabled`.

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| The Cilium agents do not start, WireGuard errors in the log. | The host kernel has no WireGuard. | Remove the `encryption` block from `values.yaml`. Do `mise run down` and `mise run up`. |
| `kubectl apply -f demo.yaml` fails: no matches for kind `CiliumNetworkPolicy`. | The CRD is not there yet. | The `up` task waits for it. If you apply by hand, wait some seconds. |
| `hubble observe` fails: connection refused. | No port forward. | Start `cilium hubble port-forward` first. |
| The POST request gives `200`. | The L7 rule is not active. | Do `kubectl -n demo get cnp` and `cilium-dbg policy get`. |

## Clean up

```bash
mise run down
```

This deletes the kind cluster `kpr`.

## References

- kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Hubble: https://docs.cilium.io/en/stable/observability/hubble/
- Hubble CLI: https://docs.cilium.io/en/stable/observability/hubble/hubble-cli/
- WireGuard encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Network policy (L3, L4, L7): https://docs.cilium.io/en/stable/security/policy/
- L7 HTTP policy: https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
- kind `kubeProxyMode`: https://kind.sigs.k8s.io/docs/user/configuration/
