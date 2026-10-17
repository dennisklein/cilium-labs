apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec:
  blocks:
  - start: "${PREFIX}.255.200"
    stop:  "${PREFIX}.255.250"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: lab-l2}
spec:
  loadBalancerIPs: true
  interfaces: ["^eth[0-9]+"]
