#!/bin/bash
set -e

echo "=== Installing K3s in server (controller) mode ==="
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
  --write-kubeconfig-mode=644 \
  --bind-address=192.168.56.110 \
  --advertise-address=192.168.56.110 \
  --node-ip=192.168.56.110" sh -

echo "=== Waiting for K3s to be ready ==="
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  ... waiting for node to be Ready"
  sleep 3
done

echo "=== Saving node token to shared folder ==="
# /vagrant is Vagrant's built-in synced folder, readable by all VMs
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token
chmod 644 /vagrant/node-token

echo "=== Setting up kubectl for the vagrant user ==="
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /home/vagrant/.bashrc

echo "=== Server installation complete ==="
kubectl get nodes -o wide