#!/bin/bash
set -e

echo "=== Configuring iptables legacy for Debian 12 ==="
apt-get update -y
apt-get install -y curl iptables
update-alternatives --set iptables /usr/sbin/iptables-legacy || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

echo "=== Installing K3s in server mode ==="
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="v1.28" \
  K3S_KUBECONFIG_MODE="644" \
  INSTALL_K3S_EXEC="--node-ip=192.168.56.110 --advertise-address=192.168.56.110 --tls-san=192.168.56.110 --flannel-iface=eth1" \
  sh -

echo "=== Waiting for K3s to be ready ==="
until sudo k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  ... waiting for node to be Ready"
  sleep 2
done

echo "=== Setting up kubectl for vagrant user ==="
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

for BASHRC in /home/vagrant/.bashrc /root/.bashrc; do
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> "$BASHRC"
  echo 'alias k="kubectl"' >> "$BASHRC"
done

echo "=== Applying app configurations ==="
sudo k3s kubectl apply -f /vagrant/confs/

echo "=== Setup complete ==="
sudo k3s kubectl get all
