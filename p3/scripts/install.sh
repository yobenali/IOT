#!/bin/bash
# P3 — K3d + Argo CD
# Installs Docker, kubectl and k3d, creates a K3d cluster, installs Argo CD
# and deploys wil42/playground from GitHub into the "dev" namespace.

set -euo pipefail

CLUSTER_NAME="p3"
APP_NAME="wil-playground"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS="$SCRIPT_DIR/../confs"

log() { echo -e "\n\033[1;34m=== $* ===\033[0m"; }

#permission & base check
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

# ─── 1. Tools ────────────────────────────────────────────────────────────────
log "Installing base packages"
apt-get update -y
apt-get install -y curl ca-certificates

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl"
  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi

if ! command -v k3d >/dev/null 2>&1; then
  log "Installing k3d"
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# ─── 2. Cluster ──────────────────────────────────────────────────────────────
if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "Cluster '$CLUSTER_NAME' already exists, skipping creation"
else
  log "Creating K3d cluster '$CLUSTER_NAME'"
  # host port 8888 -> k3d load balancer -> the app's LoadBalancer Service
  k3d cluster create "$CLUSTER_NAME" -p "8888:8888@loadbalancer" --wait
fi
kubectl config use-context "k3d-$CLUSTER_NAME"

# ─── 3. Namespaces ───────────────────────────────────────────────────────────
log "Creating namespaces argocd and dev"
kubectl apply -f "$CONFS/namespaces.yaml"

# ─── 4. Argo CD ──────────────────────────────────────────────────────────────
log "Installing Argo CD"
# --server-side: the ApplicationSet CRD is too big for client-side apply
kubectl apply --server-side --force-conflicts -n argocd -f "$ARGOCD_MANIFEST"

log "Waiting for Argo CD to be ready (this can take a few minutes)"
kubectl wait --for=condition=established crd/applications.argoproj.io --timeout=120s
kubectl wait --for=condition=available deployment --all -n argocd --timeout=600s

# ─── 5. Application ──────────────────────────────────────────────────────────
log "Creating the Argo CD Application"
kubectl apply -f "$CONFS/application.yaml"

log "Waiting for Argo CD to deploy $APP_NAME into dev"
for _ in $(seq 1 60); do
  kubectl get deployment "$APP_NAME" -n dev >/dev/null 2>&1 && break
  sleep 5
done
kubectl wait --for=condition=available "deployment/$APP_NAME" -n dev --timeout=900s

# ─── 6. Give the normal user kubectl access ──────────────────────────────────
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  mkdir -p "$USER_HOME/.kube"
  [ -f "$USER_HOME/.kube/config" ] && cp "$USER_HOME/.kube/config" "$USER_HOME/.kube/config.bak"
  k3d kubeconfig get "$CLUSTER_NAME" > "$USER_HOME/.kube/config"
  chown -R "$SUDO_USER":"$SUDO_USER" "$USER_HOME/.kube"
  usermod -aG docker "$SUDO_USER"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
ARGOCD_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"

log "Done"
kubectl get ns argocd dev
kubectl get pods -n dev
echo
echo "App:      curl http://localhost:8888"
echo "Argo CD:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "          then open https://localhost:8080  (user: admin  password: $ARGOCD_PASSWORD)"
