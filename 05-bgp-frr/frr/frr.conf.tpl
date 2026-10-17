frr defaults traditional
hostname frr
log stdout informational
!
router bgp 65000
 bgp router-id ${FRR_IP}
 no bgp ebgp-requires-policy
 no bgp network import-check
 neighbor CILIUM peer-group
 neighbor CILIUM remote-as 65001
 bgp listen range ${KIND_SUBNET} peer-group CILIUM
 !
 address-family ipv4 unicast
  neighbor CILIUM activate
  maximum-paths 8
 exit-address-family
exit
