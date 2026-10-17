#!/usr/bin/env bash
# Installs the CLI tools needed by the Cilium labs: kubectl, kind, helm, cilium-cli, jq (+ containerlab).
# - No root needed: binaries go to ~/.local/bin (override with BIN_DIR=...).
# - Skips tools already on PATH; FORCE=1 reinstalls/upgrades to the latest.
# - Honours your http(s)_proxy variables (curl reads them).
# - Docker and gettext (envsubst) are only checked, never installed.
# Env overrides: BIN_DIR, FORCE=1, HELM_VERSION=v3.x.y, INSTALL_CLAB=0
set -euo pipefail

BIN="${BIN_DIR:-$HOME/.local/bin}"
FORCE="${FORCE:-0}"
INSTALL_CLAB="${INSTALL_CLAB:-1}"
mkdir -p "$BIN"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

[ "$(uname -s)" = Linux ] || { echo "Linux only"; exit 1; }
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac
for t in curl tar sha256sum install; do
  command -v "$t" >/dev/null || { echo "missing prerequisite: $t"; exit 1; }
done

dl() { curl -fsSL --retry 3 -o "$2" "$1"; }

# Latest release tag of a GitHub repo, via the redirect (no API rate limit)
latest_tag() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'
}

# verify <file> <checksum-url>; checksum file is "<hash>" or "<hash>  <name>"
verify() {
  local want
  if want="$(curl -fsSL "$2" 2>/dev/null | awk 'NR==1{print $1}')" && [ -n "$want" ]; then
    echo "$want  $1" | sha256sum -c - >/dev/null || { echo "  CHECKSUM MISMATCH for $1"; exit 1; }
    echo "  checksum ok"
  else
    echo "  (no checksum published/reachable, verification skipped)"
  fi
}

skip() { # <cmd>: true if already installed and not forcing
  if [ "$FORCE" != 1 ] && command -v "$1" >/dev/null 2>&1; then
    echo "[skip] $1 already installed at $(command -v "$1")"; return 0
  fi
  return 1
}

echo "== Installing into $BIN (arch: $ARCH)"

if ! skip kubectl; then
  echo "[kubectl]"
  V="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  dl "https://dl.k8s.io/release/$V/bin/linux/$ARCH/kubectl" "$TMP/kubectl"
  verify "$TMP/kubectl" "https://dl.k8s.io/release/$V/bin/linux/$ARCH/kubectl.sha256"
  install -m 0755 "$TMP/kubectl" "$BIN/kubectl"
fi

if ! skip kind; then
  echo "[kind]"
  V="$(latest_tag kubernetes-sigs/kind)"
  dl "https://github.com/kubernetes-sigs/kind/releases/download/$V/kind-linux-$ARCH" "$TMP/kind"
  verify "$TMP/kind" "https://github.com/kubernetes-sigs/kind/releases/download/$V/kind-linux-$ARCH.sha256sum"
  install -m 0755 "$TMP/kind" "$BIN/kind"
fi

if ! skip helm; then
  echo "[helm]"
  V="${HELM_VERSION:-$(latest_tag helm/helm)}"
  dl "https://get.helm.sh/helm-$V-linux-$ARCH.tar.gz" "$TMP/helm.tgz"
  verify "$TMP/helm.tgz" "https://get.helm.sh/helm-$V-linux-$ARCH.tar.gz.sha256sum"
  tar -xzf "$TMP/helm.tgz" -C "$TMP"
  install -m 0755 "$TMP/linux-$ARCH/helm" "$BIN/helm"
fi

if ! skip cilium; then
  echo "[cilium-cli]"
  V="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  dl "https://github.com/cilium/cilium-cli/releases/download/$V/cilium-linux-$ARCH.tar.gz" "$TMP/cilium.tgz"
  verify "$TMP/cilium.tgz" "https://github.com/cilium/cilium-cli/releases/download/$V/cilium-linux-$ARCH.tar.gz.sha256sum"
  tar -xzf "$TMP/cilium.tgz" -C "$TMP" cilium
  install -m 0755 "$TMP/cilium" "$BIN/cilium"
fi

if ! skip jq; then
  echo "[jq]"
  V="$(latest_tag jqlang/jq)"
  dl "https://github.com/jqlang/jq/releases/download/$V/jq-linux-$ARCH" "$TMP/jq"
  want="$(curl -fsSL "https://github.com/jqlang/jq/releases/download/$V/sha256sum.txt" 2>/dev/null | awk -v n="jq-linux-$ARCH" '$2==n{print $1}')" || want=""
  if [ -n "$want" ]; then echo "$want  $TMP/jq" | sha256sum -c - >/dev/null && echo "  checksum ok"
  else echo "  (checksum skipped)"; fi
  install -m 0755 "$TMP/jq" "$BIN/jq"
fi

# containerlab needs a system-wide install (sudo containerlab must resolve to /usr/bin/containerlab)
if command -v containerlab >/dev/null 2>&1; then
  echo "[skip] containerlab already installed at $(command -v containerlab)"
elif [ "$INSTALL_CLAB" = 1 ]; then
  echo "[containerlab]"
  if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then
    bash -c "$(curl -fsSL https://get.containerlab.dev)"
  else
    echo "  Needs root (installs a system package). Run this as an admin:"
    echo '    bash -c "$(curl -sL https://get.containerlab.dev)"'
  fi
fi

echo
echo "== Preflight checks"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "! $BIN is not on PATH. Add:  export PATH=\"$BIN:\$PATH\"" ;; esac
command -v docker >/dev/null || echo "! docker not found (install Docker Engine; not handled by this script)"
if command -v docker >/dev/null && ! docker info >/dev/null 2>&1; then
  echo "! docker daemon not reachable for user $USER (is the daemon running? are you in the 'docker' group?)"
fi
command -v envsubst >/dev/null || echo "! envsubst missing: install the 'gettext' (Debian/Ubuntu: gettext-base) package"
w="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"; i="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
{ [ "$w" -lt 524288 ] || [ "$i" -lt 512 ]; } && echo "! inotify limits low (watches=$w, instances=$i). As admin: sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512"

echo
echo "== Versions"
export PATH="$BIN:$PATH"
kubectl version --client 2>/dev/null | head -n1 || true
kind version 2>/dev/null || true
helm version --short 2>/dev/null || true
cilium version --client 2>/dev/null | head -n1 || true
jq --version 2>/dev/null || true
containerlab version 2>/dev/null | grep -i version | head -n1 || true
