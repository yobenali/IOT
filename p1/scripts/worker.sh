#!/bin/bash
set -e

echo "=== Configuring iptables legacy for Debian 12 ==="
apt-get update -y
apt-get install -y curl iptables
update-alternatives --set iptables /usr/sbin/iptables-legacy || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

echo "=== Waiting for server API to be reachable ==="
until curl -k -s https://192.168.56.110:6443 > /dev/null 2>&1; do
  echo "  ... waiting for server at 192.168.56.110:6443"
  sleep 3
done

echo "=== Reading token from shared folder ==="
TOKEN_FILE="/vagrant/node-token"
if [ -f "/vagrant/confs/node-token" ]; then
  TOKEN_FILE="/vagrant/confs/node-token"
fi

if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: node-token not found."
  exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")

echo "=== Installing K3s in agent mode ==="
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL="v1.28" \
  K3S_URL="https://192.168.56.110:6443" \
  K3S_TOKEN="${TOKEN}" \
  INSTALL_K3S_EXEC="--node-ip=192.168.56.111 --flannel-iface=eth1 --prefer-bundled-bin" \
  sh -

echo "=== Waiting for agent to start ==="
until systemctl is-active --quiet k3s-agent; do
  echo "  ... waiting for k3s-agent service"
  sleep 2
done

# Setup kubectl access on worker using exported kubeconfig
if [ -f /vagrant/confs/k3s.yaml ]; then
  mkdir -p /home/vagrant/.kube
  cp /vagrant/confs/k3s.yaml /home/vagrant/.kube/config
  chown -R vagrant:vagrant /home/vagrant/.kube
  ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
  for BASHRC in /home/vagrant/.bashrc /root/.bashrc; do
    echo 'export KUBECONFIG=/home/vagrant/.kube/config' >> "$BASHRC"
    echo 'alias k="kubectl"' >> "$BASHRC"
  done
fi

echo "=== Agent installation complete ==="
systemctl status k3s-agent --no-pager
