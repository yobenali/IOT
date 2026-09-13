#!/bin/bash
set -e

echo "=== Installing K3s in server mode ==="
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
  --bind-address=192.168.56.110 \
  --advertise-address=192.168.56.110 \
  --node-ip=192.168.56.110 \
  --flannel-iface=eth1" sh -

echo "=== Waiting for K3s to be ready ==="
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  sleep 3
done

echo "=== Applying app configurations ==="
kubectl apply -f /vagrant/confs/

echo "=== Setup complete ==="
kubectl get all -n default