#!/bin/bash
# Bonus — P3 with a local GitLab instead of GitHub
# Installs Docker, kubectl, k3d, helm and git, creates a K3d cluster, installs
# GitLab (official Helm chart, latest version) in the "gitlab" namespace and
# Argo CD in "argocd", pushes the app manifests to a GitLab repository, and
# lets Argo CD deploy wil42/playground from that repository into "dev".

set -euo pipefail

CLUSTER_NAME="bonus"
APP_NAME="wil-playground"
PROJECT="aoueldma"                       # GitLab repo name (contains a login)
GITLAB_HOST="gitlab.localhost"
GITLAB_URL="http://$GITLAB_HOST"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS="$SCRIPT_DIR/../confs"

log() { echo -e "\n\033[1;34m=== $* ===\033[0m"; }
die() { echo -e "\033[1;31m$*\033[0m" >&2; exit 1; }

# ─── 0. Checks ───────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Please run as root: sudo bash $0"

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "$MEM_MB" -lt 7500 ]; then
  echo "WARNING: only ${MEM_MB}MB of RAM. GitLab needs about 8GB, pods may not start."
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"
else
  REAL_USER="root"
fi
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
REPO_DIR="$USER_HOME/$PROJECT-gitlab"

# ─── 1. Tools ────────────────────────────────────────────────────────────────
log "Installing base packages"
apt-get update -y
apt-get install -y curl ca-certificates git

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

if ! command -v helm >/dev/null 2>&1; then
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# gitlab.localhost -> the k3d load balancer (port 80 -> Traefik -> GitLab)
if ! grep -qE "^[^#]*[[:space:]]$GITLAB_HOST([[:space:]]|\$)" /etc/hosts; then
  echo "127.0.0.1 $GITLAB_HOST" >> /etc/hosts
fi

# ─── 2. Cluster ──────────────────────────────────────────────────────────────
if k3d cluster list p3 >/dev/null 2>&1; then
  die "The P3 cluster is running and uses port 8888. Delete it first: k3d cluster delete p3"
fi

if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "Cluster '$CLUSTER_NAME' already exists, skipping creation"
else
  log "Creating K3d cluster '$CLUSTER_NAME'"
  # 8888 -> the app's LoadBalancer Service, 80 -> Traefik (GitLab web UI)
  k3d cluster create "$CLUSTER_NAME" \
    -p "8888:8888@loadbalancer" \
    -p "80:80@loadbalancer" \
    --wait
fi
kubectl config use-context "k3d-$CLUSTER_NAME"

# ─── 3. Namespaces ───────────────────────────────────────────────────────────
log "Creating namespaces argocd, dev and gitlab"
kubectl apply -f "$CONFS/namespaces.yaml"

# ─── 4. Argo CD and GitLab (installed in parallel, waited for afterwards) ────
log "Installing Argo CD"
# --server-side: the ApplicationSet CRD is too big for client-side apply
kubectl apply --server-side --force-conflicts -n argocd -f "$ARGOCD_MANIFEST"

log "Installing PostgreSQL, Valkey and Garage for GitLab"
# GitLab 19 (chart 10) no longer bundles a database, Redis or object storage
hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
secret_val() {
  kubectl -n gitlab get secret "$1" -o jsonpath="{.data.$2}" | base64 -d
}
if ! kubectl -n gitlab get secret gitlab-postgres >/dev/null 2>&1; then
  kubectl -n gitlab create secret generic gitlab-postgres \
    --from-literal=psql-password="$(hex 16)"
fi
if ! kubectl -n gitlab get secret gitlab-garage >/dev/null 2>&1; then
  # Garage key format: "GK" + 24 hex chars, secret = 64 hex chars
  kubectl -n gitlab create secret generic gitlab-garage \
    --from-literal=rpc-secret="$(hex 32)" \
    --from-literal=access-key="GK$(hex 12)" \
    --from-literal=secret-key="$(hex 32)"
fi
S3_ACCESS_KEY="$(secret_val gitlab-garage access-key)"
S3_SECRET_KEY="$(secret_val gitlab-garage secret-key)"

kubectl apply -f "$CONFS/gitlab-deps.yaml"
kubectl -n gitlab rollout status statefulset/gitlab-postgres --timeout=300s
kubectl -n gitlab rollout status deployment/gitlab-valkey --timeout=300s
kubectl -n gitlab rollout status statefulset/gitlab-garage --timeout=300s

log "Configuring Garage (layout, access key, buckets)"
gar() { kubectl -n gitlab exec gitlab-garage-0 -- /garage "$@"; }
for _ in $(seq 1 30); do gar status >/dev/null 2>&1 && break; sleep 2; done

LAYOUT_VERSION="$(gar layout show | grep -oiE 'layout version: [0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
if [ "${LAYOUT_VERSION:-0}" = "0" ]; then
  NODE_ID="$(gar node id -q | cut -d@ -f1)"
  gar layout assign -z dc1 -c 10G "$NODE_ID"
  gar layout apply --version 1
fi

gar key info "$S3_ACCESS_KEY" >/dev/null 2>&1 \
  || gar key import --yes -n gitlab "$S3_ACCESS_KEY" "$S3_SECRET_KEY"

for bucket in git-lfs gitlab-artifacts gitlab-uploads gitlab-packages \
              gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files \
              gitlab-dependency-proxy gitlab-pages gitlab-backups tmp; do
  gar bucket info "$bucket" >/dev/null 2>&1 || gar bucket create "$bucket"
  gar bucket allow --read --write --owner "$bucket" --key "$S3_ACCESS_KEY" >/dev/null
done

# Connection Secrets for GitLab (Rails) and the toolbox (s3cmd, backups)
S3_HOST="gitlab-garage.gitlab.svc.cluster.local:3900"
kubectl -n gitlab create secret generic gitlab-object-storage \
  --dry-run=client -o yaml --from-literal=config="provider: AWS
region: garage
aws_access_key_id: $S3_ACCESS_KEY
aws_secret_access_key: $S3_SECRET_KEY
endpoint: \"http://$S3_HOST\"
path_style: true
" | kubectl apply -f -
kubectl -n gitlab create secret generic gitlab-object-storage-s3cmd \
  --dry-run=client -o yaml --from-literal=config="[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
bucket_location = garage
host_base = $S3_HOST
host_bucket = $S3_HOST
use_https = False
signature_v2 = False
" | kubectl apply -f -

log "Installing GitLab (latest official Helm chart)"
helm repo add gitlab https://charts.gitlab.io/ --force-update
helm repo update gitlab
helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab \
  --values "$CONFS/gitlab-values.yaml" \
  --timeout 900s

log "Waiting for Argo CD to be ready"
kubectl wait --for=condition=established crd/applications.argoproj.io --timeout=120s
kubectl wait --for=condition=available deployment --all -n argocd --timeout=600s

log "Waiting for GitLab to be ready (10-20 minutes the first time)"
kubectl wait --for=condition=available deployment --all -n gitlab --timeout=1800s

for _ in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in")" = "200" ] && break
  sleep 5
done
[ "$(curl -s -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in")" = "200" ] \
  || die "GitLab is not reachable on $GITLAB_URL"

GITLAB_PASSWORD="$(kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d)"

# ─── 5. GitLab repository ────────────────────────────────────────────────────
log "Creating an access token for root"
# The API has no password login, so the token is created with the Rails runner
TOKEN="glpat-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
kubectl exec -n gitlab deploy/gitlab-toolbox -- gitlab-rails runner "
  t = User.find_by_username('root').personal_access_tokens.new(
        name: 'iot-bonus', scopes: [:api, :read_repository, :write_repository],
        expires_at: 30.days.from_now)
  t.organization = Organizations::Organization.first if t.respond_to?(:organization=) && t.organization.nil?
  t.set_token('$TOKEN')
  t.save!
"

API="$GITLAB_URL/api/v4"
if [ "$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $TOKEN" \
        "$API/projects/root%2F$PROJECT")" = "200" ]; then
  log "GitLab project root/$PROJECT already exists"
else
  log "Creating public GitLab project root/$PROJECT"
  curl -fsS -o /dev/null -X POST -H "PRIVATE-TOKEN: $TOKEN" \
    --data "name=$PROJECT&path=$PROJECT&visibility=public" "$API/projects"
fi

REMOTE="http://oauth2:$TOKEN@$GITLAB_HOST/root/$PROJECT.git"
# safe.directory: root runs git in a folder owned by the normal user
g() { git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" "$@"; }
if [ -d "$REPO_DIR/.git" ]; then
  log "Local clone $REPO_DIR already exists"
  g remote set-url origin "$REMOTE"
elif [ -n "$(git ls-remote --heads "$REMOTE")" ]; then
  log "Cloning root/$PROJECT into $REPO_DIR"
  git clone -q "$REMOTE" "$REPO_DIR"
else
  log "Pushing the app manifests (v1) to root/$PROJECT"
  mkdir -p "$REPO_DIR"
  g init -q -b main
  cp -r "$CONFS/manifests" "$REPO_DIR/"
  g config user.name "IoT"
  g config user.email "root@$GITLAB_HOST"
  g add .
  g commit -q -m "v1"
  g remote add origin "$REMOTE"
  g push -q -u origin main
fi
g config user.name >/dev/null || g config user.name "IoT"
g config user.email >/dev/null || g config user.email "root@$GITLAB_HOST"
chown -R "$REAL_USER":"$REAL_USER" "$REPO_DIR"

# ─── 6. Application ──────────────────────────────────────────────────────────
log "Creating the Argo CD Application (source: local GitLab)"
kubectl apply -f "$CONFS/application.yaml"

log "Waiting for Argo CD to deploy $APP_NAME into dev"
for _ in $(seq 1 60); do
  kubectl get deployment "$APP_NAME" -n dev >/dev/null 2>&1 && break
  sleep 5
done
kubectl wait --for=condition=available "deployment/$APP_NAME" -n dev --timeout=900s

# ─── 7. Give the normal user kubectl access ──────────────────────────────────
if [ "$REAL_USER" != "root" ]; then
  mkdir -p "$USER_HOME/.kube"
  [ -f "$USER_HOME/.kube/config" ] && cp "$USER_HOME/.kube/config" "$USER_HOME/.kube/config.bak"
  k3d kubeconfig get "$CLUSTER_NAME" > "$USER_HOME/.kube/config"
  chown -R "$REAL_USER":"$REAL_USER" "$USER_HOME/.kube"
  usermod -aG docker "$REAL_USER"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
ARGOCD_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"

log "Done"
kubectl get ns argocd dev gitlab
kubectl get pods -n dev
echo
echo "App:      curl http://localhost:8888"
echo "GitLab:   $GITLAB_URL  (user: root  password: $GITLAB_PASSWORD)"
echo "Repo:     $REPO_DIR  (remote: $GITLAB_URL/root/$PROJECT)"
echo "Argo CD:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "          then open https://localhost:8080  (user: admin  password: $ARGOCD_PASSWORD)"
echo
echo "Switch to v2:"
echo "  cd $REPO_DIR"
echo "  sed -i 's/wil42\/playground:v1/wil42\/playground:v2/g' manifests/deployment.yaml"
echo "  git commit -am v2 && git push"
