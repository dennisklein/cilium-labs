# Cilium + kind + containerlab lab ladder

## Purpose

This repository is a series of labs ("stages") for Cilium networking. Each stage is a folder with a small
kind cluster, a Cilium configuration and a demo. Each stage adds one or more functions to the stages before
it. Do the stages in sequence. Each stage README has the concepts, ASCII diagrams, a step-by-step procedure
with expected output, experiments and troubleshooting.

## The stages

```
 01 basic        kind + Cilium, VXLAN tunnel
  |
 02 kpr          - kube-proxy, + Hubble, WireGuard, L7 policy
  |
 03 native       - tunnel, + native routing, BPF masquerade
  |
  +-- 04 l2       + LB-IPAM, L2 announcements (ARP)
  |
  +-- 05 bgp      + BGP to one FRR router
  |    |
  |   06 fabric   + leaf/spine FRR fabric, external client, ECMP
  |
  +-- 08 dual     + IPv6 (dual-stack)

 07 mesh         two clusters, Cluster Mesh, global service   (needs 01, 02)
 09 egress       egress gateway with a fixed source IP        (needs 02, 06)
```

| Stage | Cluster | Adds | containerlab |
|-------|---------|------|--------------|
| [01-basic](01-basic/README.md) | `basic` | kind + Cilium, VXLAN tunnel, kube-proxy still present | no |
| [02-kpr-hubble-policy](02-kpr-hubble-policy/README.md) | `kpr` | kube-proxy replacement, Hubble, WireGuard, L7 policy | no |
| [03-native-routing](03-native-routing/README.md) | `native` | no tunnel, native routing, BPF masquerade | no |
| [04-lbipam-l2](04-lbipam-l2/README.md) | `l2` | LB-IPAM + L2 announcements on the Docker bridge | no |
| [05-bgp-frr](05-bgp-frr/README.md) | `bgp` | Cilium BGP control plane, peering with an FRR container on the kind network | yes (mgmt = kind network) |
| [06-fabric](06-fabric/README.md) | `fabric` | spine/leaf FRR fabric, node uplinks (`ext-container`), external client reaches LB IPs over BGP/ECMP | yes (`ext-container`) |
| [07-clustermesh](07-clustermesh/README.md) | `mesh1`, `mesh2` | two kind clusters, Cluster Mesh, global service | no |
| [08-dual-stack](08-dual-stack/README.md) | `dual` | IPv4 + IPv6 pods and Services, native routing for both families | no |
| [09-egress-gateway](09-egress-gateway/README.md) | `egress` | selected pods leave through a gateway node with a fixed egress IP | yes (`ext-container`) |

Each stage has its own cluster name. Thus, you can keep a stage and start a different stage. Each cluster
uses CPU and memory. On a small host, do `mise run down` before you start the next stage.

## How a stage works

```
 host
 +------------------------------------------------------------------------------+
 |  mise           tools (kind, kubectl, cilium-cli, ...) and env per stage      |
 |   |                                                                          |
 |   +-- mise run up --> kind create cluster  (node containers on Docker)       |
 |                   --> cilium install       (Helm chart, values.yaml)         |
 |                   --> kubectl apply        (demo, policies, pools)           |
 |                   --> clab deploy          (stages 05, 06, 09: FRR, clients) |
 |                   --> mise run check       (probes with expected results)    |
 |                                                                              |
 |  docker network "kind"                                                       |
 |  ==+===============+===============+===============+=====                    |
 |    |               |               |               |                         |
 |  <cluster>-     <cluster>-      <cluster>-      containerlab nodes           |
 |  control-plane  worker          worker2         (some stages)                |
 +------------------------------------------------------------------------------+
```

Each stage folder has these tasks:

| Task | What it does |
|------|--------------|
| `up` | Makes the cluster, installs Cilium, applies the lab objects, then runs `check`. |
| `check` | Runs the probes of the stage again. In stage 09, it also applies the policies. |
| `down` | Destroys the containerlab lab (if there is one), then deletes the cluster(s). |

## Quick start

1. Install [mise](https://mise.jdx.dev/) and Docker. Docker comes from the operating system, not from mise.
2. In the repository root, trust the configuration and install the tools:

   ```bash
   mise trust -a && mise install
   ```

3. Activate mise in the shell. Then mise loads the `[env]` of a stage when you go into its folder:

   ```bash
   eval "$(mise activate bash)"
   ```

4. Start the first stage:

   ```bash
   cd 01-basic && mise run up
   ```

   From the repository root, you can also do `mise run //01-basic:up`.

5. Do the procedure in the README of the stage.
6. Delete the stage:

   ```bash
   mise run down
   ```

Other useful commands:

- `mise tasks ls --all` shows the tasks of all stages.
- `mise run down-all` deletes all stages, one after the other.

## Configuration

### mise

The root `mise.toml` is the single source of truth for the tools and the shared environment:

- `[tools]`: `kubectl`, `kind`, `helm`, `cilium-cli`, `jq`, `containerlab`, `hubble`, `envsubst`. All tools use
  `latest`.
- `[env]`: `LAB_ROOT`. The stage tasks use it to find the shared shell functions in `lib/lab.sh`.

Each stage `mise.toml` sets `CLUSTER` and `KUBECONFIG` (`<stage>/build/kubeconfig`). With `mise activate`,
`kubectl`, `cilium` and `hubble` in a stage folder use the cluster of that stage. You do not need
`--context`. Stage 07 is different: it has two contexts in one file, so use `--context`.

Without `mise activate`, use `mise x -- kubectl ...` in the stage folder, or
`kind export kubeconfig --name <cluster>`.

| Tool | Stages |
|------|--------|
| `docker`, `kind`, `kubectl`, `cilium-cli` | all |
| `envsubst` | 04, 05, 07 (render templates) |
| `containerlab` | 05, 06, 09 |
| `jq` | 07 |
| `hubble` | 02 (optional, to see flows) |
| `helm` | optional, to examine the release (`helm -n kube-system get values cilium`) |

### Cilium version

By default, `cilium install` installs the Cilium version that is the default of the installed cilium-cli.
Thus, when `mise install` updates cilium-cli, the Cilium version can change too.

To pin the Cilium version, set `CILIUM_VERSION`. The `cilium_up` function in `lib/lab.sh` then adds
`--version $CILIUM_VERSION` to `cilium install`.

- For all stages, for all users: add it to `[env]` in the root `mise.toml`.

  ```toml
  [env]
  CILIUM_VERSION = "1.20.3"
  ```

- For all stages, only on your computer: put the same `[env]` block in `mise.local.toml` in the repository
  root. git ignores this file.
- For one run: `CILIUM_VERSION=1.20.3 mise run up`.

Show the version that cilium-cli uses by default:

```bash
cilium version --client
```

### Cilium Helm values

`cilium install` examines the cluster and sets Helm values for kind (see stage
[01](01-basic/README.md#cilium-install)). The `values.yaml` file of each stage has only the values that are
different from these values and from the chart defaults. Stage 01 has no `values.yaml` file. To see all
values in a running cluster:

```bash
cilium config view
helm -n kube-system get values cilium
```

## Recommendations

- **inotify limits.** Many kind nodes need more inotify watches and instances than the default. Set them on
  the host:

  ```bash
  sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
  ```

- **Proxy.** If the host uses a proxy, put these networks in `NO_PROXY` as CIDRs: the Docker subnet (for
  example `172.18.0.0/16`), `10.244.0.0/16`, `10.96.0.0/12` and `10.200.0.0/24`. Pods do not use the proxy.
  Thus, skip the connectivity tests that need direct internet access (see
  [03-native-routing](03-native-routing/README.md#step-4-do-the-connectivity-test)).

## Notes

- FRR 10.7.1 is pinned in the containerlab topology files.
- `kind` commands need `--name <cluster>`. `kind get clusters` shows all clusters.
- Stages 05, 06 and 09 run containerlab with `sudo` (function `clab` in `lib/lab.sh`). `sudo` resets `PATH`,
  so `clab` gives the absolute path of the mise binary. The tasks render the topology with `envsubst` first,
  so `sudo -E` is not necessary. The `up` and `down` tasks ask for the `sudo` password first.
- After you edit an FRR configuration, destroy and deploy the lab again (`mise run down`, `mise run up`).
- The files in `build/` and `clab-*/` are generated. git ignores them.

## Documentation

- kind: https://kind.sigs.k8s.io/docs/user/quick-start/ , configuration
  https://kind.sigs.k8s.io/docs/user/configuration/ , known issues https://kind.sigs.k8s.io/docs/user/known-issues/
- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/ , Helm values
  https://docs.cilium.io/en/stable/helm-reference/
- containerlab: https://containerlab.dev/ , kinds https://containerlab.dev/manual/kinds/
- Version note: `docs.cilium.io/en/stable/` is for the latest Cilium release. If you use an older Cilium
  version, replace `stable` with the minor version in the URL (for example `v1.20`).
