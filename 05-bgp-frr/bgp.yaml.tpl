apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata: {name: bgp-all}
spec:
  nodeSelector: {matchLabels: {bgp: enabled}}
  bgpInstances:
  - name: lab
    localASN: 65001
    peers:
    - name: frr
      peerASN: 65000
      peerAddress: ${FRR_IP}
      peerConfigRef: {name: peer-frr}
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata: {name: peer-frr}
spec:
  timers: {holdTimeSeconds: 9, keepAliveTimeSeconds: 3}
  gracefulRestart: {enabled: true, restartTimeSeconds: 15}
  families:
  - afi: ipv4
    safi: unicast
    advertisements: {matchLabels: {advertise: bgp}}
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata: {name: adverts, labels: {advertise: bgp}}
spec:
  advertisements:
  - advertisementType: PodCIDR
  - advertisementType: Service
    service: {addresses: [LoadBalancerIP]}
    selector:
      matchExpressions: [{key: never-used, operator: NotIn, values: ["x"]}]
