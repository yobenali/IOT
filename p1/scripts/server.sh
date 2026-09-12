#!/bin/bash
set -e

echo "=== Configuring iptables legacy for Debian 12 ==="
apt-get update -y
apt-get install -y curl iptables
update-alternatives --set iptables /usr/sbin/iptables-legacy || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

echo "=== Installing K3s in server mode ==="
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="v1.28" INSTALL_K3S_EXEC="\
  --write-kubeconfig-mode=644 \
  --tls-san=192.168.56.110 \
  --node-ip=192.168.56.110 \
  --advertise-address=192.168.56.110 \
  --flannel-iface=eth1 \
  --prefer-bundled-bin \
  --disable=traefik \
  --disable=servicelb \
  --disable=local-storage" sh -

echo "=== Waiting for K3s to be ready ==="
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  ... waiting for node to be Ready"
  sleep 2
done

echo "=== Saving node token and kubeconfig to shared folder ==="
mkdir -p /vagrant/confs
cp /var/lib/rancher/k3s/server/node-token /vagrant/confs/node-token
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token
chmod 644 /vagrant/confs/node-token /vagrant/node-token 2>/dev/null || true

# Export kubeconfig with static server IP for remote / worker use
sed 's/127.0.0.1/192.168.56.110/g' /etc/rancher/k3s/k3s.yaml > /vagrant/confs/k3s.yaml
chmod 644 /vagrant/confs/k3s.yaml 2>/dev/null || true

echo "=== Setting up kubectl and aliases ==="
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

for BASHRC in /home/vagrant/.bashrc /root/.bashrc; do
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> "$BASHRC"
  echo 'alias k="kubectl"' >> "$BASHRC"
  echo 'source <(kubectl completion bash)' >> "$BASHRC"
  echo 'complete -o default -F __start_kubectl k' >> "$BASHRC"
done

echo "=== Server installation complete ==="
kubectl get nodes -o wide
