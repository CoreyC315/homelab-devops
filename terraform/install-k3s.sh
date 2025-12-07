#!/bin/bash

# Define Node IPs
SERVER_IP="192.168.1.201"
AGENT_VM_IP="192.168.1.211"
AGENT_PI_IP="192.168.1.93"  
AGENT_PI_USER="pi"           # Assumed user for Pi, change if needed
USER="ubuntu"

# SSH Options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Tailscale Auth Key (Optional: Needed if VMs aren't on Tailscale yet)
# TS_AUTHKEY="ts-auth-key-here" 

echo "🚀 Starting Hybrid K3s Installation..."

# --- 1. Install K3s Server ---
echo "🔹 Installing K3s Server on $SERVER_IP..."
ssh $SSH_OPTS $USER@$SERVER_IP "curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --node-taint CriticalAddonsOnly=true:NoExecute \
  --write-kubeconfig-mode 644"

# ^ Note: --node-taint prevents your heavy apps from landing on this weak VM

echo "✅ Server Installed. Waiting for startup..."
sleep 15

# --- 2. Fetch the Join Token ---
NODE_TOKEN=$(ssh $SSH_OPTS $USER@$SERVER_IP "sudo cat /var/lib/rancher/k3s/server/node-token")
echo "🔑 Token fetched."

# --- 3. Join Agent 1 (The Juiced VM) ---
echo "🔹 Joining Agent 1 ($AGENT_VM_IP)..."
ssh $SSH_OPTS $USER@$AGENT_VM_IP "curl -sfL https://get.k3s.io | K3S_URL=https://$SERVER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -"

# --- 4. Join Agent 2 (The Raspberry Pi) ---
echo "🔹 Joining Agent 2 ($AGENT_PI_IP)..."
# Note: K3s binaries work across archs (x86/ARM) automatically.
# We use the '--node-label' to tell K8s this is an ARM device.
ssh $SSH_OPTS $AGENT_PI_USER@$AGENT_PI_IP "curl -sfL https://get.k3s.io | K3S_URL=https://$SERVER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -s - agent --node-label kubernetes.io/arch=arm64"

# --- 5. Configure Local Access ---
echo "🔹 Setting up local kubectl access..."
mkdir -p ~/.kube
scp $SSH_OPTS $USER@$SERVER_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' "s/127.0.0.1/$SERVER_IP/g" ~/.kube/config

echo "🎉 Cluster is ready! Checking nodes..."
kubectl get nodes -o wide