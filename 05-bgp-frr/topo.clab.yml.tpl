# Rendered by the up task into build/topo.clab.yml; bind paths are relative to build/.
name: bgp-lab
mgmt:
  network: kind                 # attach lab nodes to the existing kind docker network
  ipv4-subnet: ${KIND_SUBNET}   # must equal the kind network's subnet
topology:
  nodes:
    frr:
      kind: linux
      image: quay.io/frrouting/frr:10.7.1
      mgmt-ipv4: ${FRR_IP}
      binds:
        - ./frr.conf:/etc/frr/frr.conf     # rendered next to this file, in build/
        - ../frr/daemons:/etc/frr/daemons
        - ../frr/vtysh.conf:/etc/frr/vtysh.conf
