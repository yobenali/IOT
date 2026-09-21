# Inception-of-Things (IoT)

A deep-dive into **Kubernetes** orchestration using **K3s**, **K3d**, **Vagrant** and **Argo CD** — built as part of a System Administration curriculum focused on modern DevOps practices.

---

## Overview

This project progressively builds expertise in container orchestration and infrastructure automation across three parts, each introducing a new layer of complexity:

| Part | Stack | Description |
|------|-------|-------------|
| P1 | K3s + Vagrant | Multi-node Kubernetes cluster with controller/agent architecture |
| P2 | K3s + Ingress | Single-node cluster serving 3 apps with host-based routing |
| P3 | K3d + Argo CD | GitOps CI/CD pipeline with automated continuous delivery |
| Bonus | Gitlab | Self-hosted Gitlab replacing GitHub as the GitOps source |

---

## Team

| Login | Part |
|-------|------|
| yobenali | P1 — K3s + Vagrant, P2 — K3s + Ingress |
| teammate2 | P3 — K3d + Argo CD |
| teammate3 | Bonus — Gitlab |

---

## Part 1 — Multi-Node K3s Cluster with Vagrant

Provisions two Debian virtual machines from a single `Vagrantfile`, installs K3s in controller/agent topology, and establishes passwordless SSH access — all fully automated.

### Architecture

```
┌─────────────────────────────────┐     ┌─────────────────────────────────┐
│         yobenaliS               │     │         yobenaliSW              │
│      192.168.56.110             │────▶│      192.168.56.111             │
│   K3s — controller mode         │     │   K3s — agent mode              │
└─────────────────────────────────┘     └─────────────────────────────────┘
         Server (Master)                        Worker Node
```

### What it does
- Spins up two VMs using Vagrant and VirtualBox with minimal resources (1 CPU, 1GB RAM each)
- Installs K3s on both machines via automated shell provisioning
- Server node runs the control plane (API server, scheduler, controller manager)
- Worker node joins the cluster using a shared node-token via the Vagrant shared folder
- Both machines are reachable over SSH with no password prompt

### How to run
```bash
cd p1
vagrant up
vagrant ssh yobenaliS
kubectl get nodes -o wide
```

### Expected result
```
NAME          STATUS   ROLES                  AGE   VERSION         INTERNAL-IP
yobenaliS     Ready    control-plane,master   2m    v1.28.15+k3s1   192.168.56.110
yobenaliSW    Ready    <none>                 1m    v1.28.15+k3s1   192.168.56.111
```

### Stack
`Vagrant` · `VirtualBox` · `K3s v1.28` · `Debian 12 (Bookworm)` · `kubectl`

---

## Part 2 — Ingress-Based Routing with Three Applications

A single Kubernetes node running three distinct web applications, routed exclusively by the HTTP `Host` header — no port differences, no path differences.

### Architecture

```
                         ┌──────────────────────────────────────┐
                         │         yobenaliS — K3S              │
                         │          192.168.56.110               │
                         │                                       │
  Host: app1.com  ──────▶│  Traefik Ingress Controller          │
  Host: app2.com  ──────▶│        │                             │
  (default)       ──────▶│        ├──▶ app1  (1 replica)        │
                         │        ├──▶ app2  (3 replicas)       │
                         │        └──▶ app3  (default route)    │
                         └──────────────────────────────────────┘
```

### Routing rules

| Host Header | Application | Replicas |
|-------------|-------------|----------|
| `app1.com`  | app1        | 1        |
| `app2.com`  | app2        | 3        |
| *(any other)* | app3      | 1        |

### What it does
- Single Vagrant VM provisioned with K3s in server mode
- Three Deployments and Services deployed via Kubernetes manifests
- Traefik Ingress Controller (built into K3s) handles all routing
- `app2` runs with 3 replicas demonstrating horizontal scaling
- A catch-all Ingress rule routes any unknown host to `app3` by default

### How to run
```bash
cd p2
vagrant up
```

### How to test
```bash
curl -H "Host: app1.com" http://192.168.56.110   # → Hello from app1.
curl -H "Host: app2.com" http://192.168.56.110   # → Hello from app2.
curl http://192.168.56.110                         # → Hello from app3.
```

### Stack
`Vagrant` · `VirtualBox` · `K3s v1.28` · `Traefik` · `Debian 12 (Bookworm)` · `kubectl`

---

## Repository Structure

```
.
├── p1/
│   ├── Vagrantfile
│   ├── scripts/
│   │   ├── server.sh          # K3s controller installation & configuration
│   │   └── worker.sh          # K3s agent installation & cluster join
│   └── confs/
│       └── k3s.yaml           # Kubeconfig exported with cluster IP
│
├── p2/
│   ├── Vagrantfile
│   ├── scripts/
│   │   └── install.sh         # K3s installation + manifest deployment
│   └── confs/
│       ├── app1.yaml          # Deployment + Service
│       ├── app2.yaml          # Deployment + Service (3 replicas)
│       ├── app3.yaml          # Deployment + Service (default backend)
│       └── ingress.yaml       # Traefik Ingress routing rules
│
├── p3/
│   ├── scripts/
│   │   └── install.sh         # K3d + Argo CD automated setup
│   └── confs/
│       └── deployment.yaml    # App manifest tracked by Argo CD
│
└── bonus/
    ├── scripts/
    └── confs/
```

---

## Key Technical Decisions

**Why `eth1` for flannel interface?**
In Vagrant + VirtualBox, `eth0` is the NAT interface used by Vagrant itself. `eth1` is the dedicated private network interface carrying the `192.168.56.x` subnet. Binding flannel to `eth1` ensures pod-to-pod traffic routes over the correct network.

**Why token sharing via `/vagrant`?**
Vagrant automatically mounts the project directory as `/vagrant` on all VMs simultaneously. Writing the K3s node-token to this shared folder from the server and reading it on the worker is the cleanest, most reliable approach — no SSH tunneling or manual copy needed.

**Why `host: ""` instead of `defaultBackend` in Ingress?**
Traefik (K3s built-in) does not implement the `defaultBackend` Ingress field the same way as Nginx. Using an empty host catch-all rule (`host: ""`) is the correct way to define a default route in Traefik.

---

## Skills Demonstrated

- Infrastructure as Code with Vagrant
- Kubernetes cluster bootstrapping from scratch
- Multi-node K3s topology (controller + agent)
- Kubernetes resource management (Deployments, Services, Ingress)
- Host-based HTTP routing with Traefik
- Horizontal pod scaling with ReplicaSets
- Automated VM provisioning with shell scripts
- GitOps continuous delivery with Argo CD (P3)
- Network troubleshooting (CNI interfaces, flannel configuration)
