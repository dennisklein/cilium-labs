# 04 – LoadBalancer IPs without a cloud: LB-IPAM + L2 announcements

## Purpose

In a cloud, a Service of `type: LoadBalancer` gets an external IP address from the cloud provider. kind has
no cloud provider. Thus, the Service stays `<pending>`. This stage uses two Cilium functions to replace the
cloud load balancer:

1. **LB-IPAM** gives each LoadBalancer Service an IP address from a pool.
2. **L2 announcements** make one node answer ARP requests for that IP address. Thus, the host can send
   packets to the IP address on the Docker bridge.

When you complete this stage, you know:

- How a `CiliumLoadBalancerIPPool` gives addresses to LoadBalancer Services.
- How a `CiliumL2AnnouncementPolicy` selects the Services and the interfaces for ARP.
- How Cilium uses Kubernetes leases to select one node as the owner of each IP address.
- Why the pool must be in the subnet of the Docker bridge for L2 announcements.

## Concepts

### LB-IPAM

LB-IPAM is a controller in the Cilium operator. It examines Services of `type: LoadBalancer`. For each
Service, it takes a free address from a pool and writes it to `status.loadBalancer.ingress`. LB-IPAM only
gives the address. It does not make the address reachable. L2 announcements (this stage) or BGP (stages 05
and 06) do that.

```
 Service web (type: LoadBalancer)
     |
     v
 LB-IPAM (cilium-operator) -- takes a free IP from --> CiliumLoadBalancerIPPool lab-pool
     |                                                 172.18.255.200 - 172.18.255.250
     v
 status.loadBalancer.ingress[0].ip = 172.18.255.200
```

### L2 announcements

The host and the kind nodes are on the same L2 segment (the Docker bridge). To send a packet to
`172.18.255.200`, the host sends an ARP request: "who has 172.18.255.200?". One node must answer with its
MAC address. With L2 announcements, the Cilium agent of one node answers.

```
 host                         Docker bridge                     l2-worker2 (lease holder)
  |  ARP: who has 172.18.255.200? ------------------------------> cilium agent
  |  <---------------------------- ARP reply: MAC of l2-worker2 eth0
  |  TCP to 172.18.255.200:80 ----------------------------------> eBPF: Service web
  |                                                                  |
  |                                                    backend pod on any node
```

Only one node at a time can answer for an IP address. The Cilium agents use a Kubernetes lease for each
Service to select this node (leader election). If the node stops, the lease expires and a different node
takes it. Then the new node sends a gratuitous ARP, and the host updates its ARP table.

### The pool must be on the bridge subnet

ARP works only inside one L2 subnet. Thus, the pool must be inside the subnet of the Docker network `kind`.
The `up` task reads the subnet (for example `172.18.0.0/16`) and uses the first two octets as `PREFIX`. Then it
renders `l2.yaml.tpl` with `envsubst`:

```
 kind subnet 172.18.0.0/16  -->  PREFIX=172.18  -->  pool 172.18.255.200 - 172.18.255.250
```

Docker gives addresses to containers from the bottom of the subnet. Thus, the top of the subnet is free.

### The policy

```yaml
kind: CiliumL2AnnouncementPolicy
spec:
  loadBalancerIPs: true        # announce the LoadBalancer IP addresses
  interfaces: ["^eth[0-9]+"]   # answer ARP on eth0 (the Docker bridge)
```

The policy has no `serviceSelector` and no `nodeSelector`. Thus, it applies to all Services and all nodes.

## Lab topology

```
 host 172.18.0.1 ---- curl http://172.18.255.200
   |
 ==+=========== docker network kind 172.18.0.0/16 ======================
   |               |                |                |
 l2-control-     l2-worker        l2-worker2       l2-worker3
 plane           web pod          web pod          web pod
                 ^-- one node answers ARP for 172.18.255.200 (lease)
```

| Item | Value |
|------|-------|
| Cluster name | `l2` |
| Nodes | `l2-control-plane`, `l2-worker`, `l2-worker2`, `l2-worker3` |
| Routing | native, `autoDirectNodeRoutes` (as stage 03) |
| LB pool | `<PREFIX>.255.200` - `<PREFIX>.255.250` |
| Demo | Deployment `web` (3 x nginx), Service `web` of `type: LoadBalancer` |

## Files

| File | Content |
|------|---------|
| `kind.yaml` | Four nodes, no default CNI, no kube-proxy. |
| `values.yaml` | Native routing (as stage 03) and `l2announcements.enabled`. |
| `l2.yaml.tpl` | The pool `lab-pool` and the policy `lab-l2`. `${PREFIX}` comes from the `up` task. |
| `../common/demo-lb.yaml` | Deployment and LoadBalancer Service `web`. Stages 05 and 06 use it too. |
| `mise-tasks/up` | Cluster, Cilium, pool and policy, demo, then `check`. |
| `mise-tasks/check` | Waits for the LB IP address, then sends a request from the host. |

## Procedure

Do the steps in the stage folder (`04-lbipam-l2/`).

### Step 1: Start the lab

```bash
mise run up
```

The `up` task does these steps:

```
 kind_up, cilium_up
 PREFIX=$(kind_subnet | cut -d. -f1,2)
 wait_crds        ciliumloadbalancerippools, ciliuml2announcementpolicies
 envsubst < l2.yaml.tpl | kubectl apply -f -
 kubectl apply -f ../common/demo-lb.yaml
 mise run check
```

Expected output of the check (example):

```
LB IP: 172.18.255.200  -> curl from the host (Linux, same docker bridge):
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

### Step 2: Examine the Service and the pool

```bash
kubectl get svc web
```

Expected output (example):

```
NAME   TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
web    LoadBalancer   10.96.45.123   172.18.255.200   80:31234/TCP   1m
```

Show the pool and the number of free addresses:

```bash
kubectl get ciliumloadbalancerippools
```

Expected output (example):

```
NAME       DISABLED   CONFLICTING   IPS AVAILABLE   AGE
lab-pool   false      False         50              1m
```

### Step 3: Find the node that announces the IP address

```bash
kubectl -n kube-system get lease | grep l2announce
```

Expected output (example):

```
cilium-l2announce-default-web   l2-worker2   1m
```

The second column is the node that holds the lease. This node answers ARP for the IP address of `default/web`.

Make sure that the host has the MAC address of that node in its ARP table:

```bash
ip neigh show 172.18.255.200
docker exec l2-worker2 cat /sys/class/net/eth0/address
```

The two MAC addresses are the same.

### Step 4: Send requests from the host

```bash
IP=$(kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 6); do curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"; done
```

Expected output: `200` six times. The announcing node receives all requests. Its eBPF load balancer sends
each request to one of the three `web` pods, also to pods on other nodes.

### Step 5: Move the announcement to a different node

1. Stop the node that holds the lease (in this example `l2-worker2`):

   ```bash
   docker stop l2-worker2
   ```

2. Wait approximately 20 seconds. Then examine the lease again:

   ```bash
   kubectl -n kube-system get lease | grep l2announce
   ```

   A different node now holds the lease.

3. Send a request from the host again: `curl -s -o /dev/null -w '%{http_code}\n' "http://$IP"`. Expected
   output: `200`.

4. Start the node again: `docker start l2-worker2`.

## Experiments

Do the experiments after the procedure, in the sequence below. Each experiment ends with the cluster in its
initial state. The experiments use the variable `PREFIX`. Set it first:

```bash
PREFIX=$(docker network inspect kind -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' \
  | grep -v ':' | head -n1 | cut -d. -f1,2); echo "$PREFIX"
```

### Experiment 1: Add a second LoadBalancer Service

1. Make a second Service for the Deployment `web`:

   ```bash
   kubectl expose deploy web --name web2 --type LoadBalancer --port 80
   ```

2. Show the two Services and their leases:

   ```bash
   kubectl get svc web web2
   kubectl -n kube-system get lease | grep l2announce
   ```

   `web2` gets the next free address of the pool (for example `172.18.255.201`). It has its own lease. The
   lease holder can be a different node than for `web`.

3. Send a request to the new address:

   ```bash
   IP2=$(kubectl get svc web2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   curl -s -o /dev/null -w '%{http_code}\n' "http://$IP2"
   ```

   Expected output: `200`.

4. Delete the Service:

   ```bash
   kubectl delete svc web2
   ```

### Experiment 2: Request a specific address

1. Make a Service that requests the address `<PREFIX>.255.240` with the annotation `lbipam.cilium.io/ips`:

   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: Service
   metadata:
     name: web-fixed
     annotations: {lbipam.cilium.io/ips: "${PREFIX}.255.240"}
   spec:
     type: LoadBalancer
     selector: {app: web}
     ports: [{port: 80, targetPort: 80}]
   EOF
   ```

2. Show the address and send a request:

   ```bash
   kubectl get svc web-fixed
   curl -s -o /dev/null -w '%{http_code}\n' "http://${PREFIX}.255.240"
   ```

   Expected output: `EXTERNAL-IP` is `<PREFIX>.255.240`, and curl gives `200`.

3. Delete the Service:

   ```bash
   kubectl delete svc web-fixed
   ```

### Experiment 3: Announce only Services with a label

1. Apply a changed policy with a `serviceSelector`. It selects only Services with the label `announce=yes`:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: cilium.io/v2alpha1
   kind: CiliumL2AnnouncementPolicy
   metadata: {name: lab-l2}
   spec:
     serviceSelector: {matchLabels: {announce: "yes"}}
     loadBalancerIPs: true
     interfaces: ["^eth[0-9]+"]
   EOF
   ```

2. Show the leases:

   ```bash
   kubectl -n kube-system get lease | grep l2announce
   ```

   Expected output: no lease for `web`. No node answers ARP for its address now.

3. Remove the old ARP entry on the host. Then send a request:

   ```bash
   IP=$(kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   sudo ip neigh flush to "$IP"
   curl -s -m 3 -o /dev/null -w '%{http_code}\n' "http://$IP"
   ```

   Expected output: `000`. The host gets no ARP reply.

4. Put the label on the Service. Then send the request again:

   ```bash
   kubectl label svc web announce=yes
   sleep 5
   curl -s -m 3 -o /dev/null -w '%{http_code}\n' "http://$IP"
   ```

   Expected output: `200`. A node has the lease again.

5. Restore the policy and remove the label:

   ```bash
   PREFIX=$PREFIX envsubst < l2.yaml.tpl | kubectl apply -f -
   kubectl label svc web announce-
   ```

## Troubleshooting

| Symptom | Cause | Remedy |
|---------|-------|--------|
| `EXTERNAL-IP` stays `<pending>`. | No pool, or the pool has no free address. | Do `kubectl get ciliumloadbalancerippools` and `kubectl describe svc web`. |
| The IP address is set, but `curl` from the host times out. | No node holds the lease, or the host is not on the Docker bridge. | Do `kubectl -n kube-system get lease`. L2 announcements do not work with Docker Desktop (the containers are in a VM). |
| No lease, errors about leases in the agent log. | The agent is rate-limited by the API server client. | Increase `k8sClientRateLimit.qps` and `.burst` in `values.yaml` (defaults 10 and 20). |
| `curl` goes to the proxy. | `HTTP_PROXY` is set. | Put the pool range or the Docker subnet in `NO_PROXY`. |
| `kubectl apply` fails for the pool after a Cilium upgrade. | The API version `cilium.io/v2alpha1` changed. | Do `kubectl explain ciliumloadbalancerippool` and update `l2.yaml.tpl`. |

## Clean up

```bash
mise run down
```

This deletes the kind cluster `l2`.

## References

- LB-IPAM: https://docs.cilium.io/en/stable/network/lb-ipam/
- L2 announcements: https://docs.cilium.io/en/stable/network/l2-announcements/
- kind and LoadBalancer Services: https://kind.sigs.k8s.io/docs/user/loadbalancer/
