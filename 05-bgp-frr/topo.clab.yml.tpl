name: bgp-lab
mgmt:
  network: kind                 # attach lab nodes to the existing kind docker network
  ipv4-subnet: ${KIND_SUBNET}   # must equal the kind network's subnet
topology:
  nodes:
    frr:
      kind: linux
      image: quay.io/frrouting/frr:10.2.1
      mgmt-ipv4: ${FRR_IP}
      binds:
        - ./build/frr.conf:/etc/frr/frr.conf
        - ./frr/daemons:/etc/frr/daemons
        - ./frr/vtysh.conf:/etc/frr/vtysh.conf
