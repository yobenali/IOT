#!/bin/bash
set -e

echo "=== Installing dependencies ==="
apt-get update -y
apt-get install -y curl

echo "=== Waiting for server API to be reachable ==="
until curl -k -s https://192.168.56.110:6443 > /dev/null 2>&1; do
  echo "  ... waiting for server at 192.168.56.110:6443"
  sleep 3
done

echo "=== Reading token from shared folder ==="
# /vagrant is Vagrant's built-in synced folder, written to by the server
if [ ! -f /vagrant/node-token ]; then
  echo "ERROR: /vagrant/node-token not found."
  echo "Make sure the server VM provisioned successfully first."
  exit 1
fi
TOKEN=$(cat /vagrant/node-token)

echo "=== Installing K3s in agent mode ==="
curl -sfL https://get.k3s.io | \
  K3S_URL="https://192.168.56.110:6443" \
  K3S_TOKEN="${TOKEN}" \
  INSTALL_K3S_EXEC="--node-ip=192.168.56.111" \
  sh -

echo "=== Waiting for agent to start ==="
until systemctl is-active --quiet k3s-agent; do
  echo "  ... waiting for k3s-agent service"
  sleep 2
done

echo "=== Agent installation complete ==="
systemctl status k3s-agent --no-pager