#!/bin/bash

ROLE=$1
SERVER_IP=$2

if [ "$ROLE" == "server" ]; then
    echo "Installing K3s Server..."
    curl -sfL https://get.k3s.io | sh -
    sleep 5
    sudo chmod 644 /var/lib/rancher/k3s/server/node-token
    if ! command -v kubectl &> /dev/null; then
        curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi
    echo "K3s Server installed successfully"

elif [ "$ROLE" == "agent" ]; then
    echo "Installing K3s Agent..."
    sleep 15
    TOKEN=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /home/vagrant/.ssh/insecure_private_key vagrant@${SERVER_IP} "sudo cat /var/lib/rancher/k3s/server/node-token")
    curl -sfL https://get.k3s.io | K3S_URL=https://${SERVER_IP}:6443 K3S_TOKEN=${TOKEN} sh -
    echo "K3s Agent installed successfully"
fi
