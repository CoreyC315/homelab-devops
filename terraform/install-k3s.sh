#!/bin/bash

# Define Node IPs
SERVER_IP="192.168.1.201"
AGENT_1_IP="192.168.1.211"
AGENT_2_IP="192.168.1.212"
USER="ubuntu"

# SSH Options to avoid "Host key verification failed" errors during automation
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "🚀 Starting K3s Installation..."

# --- 1. Install K3s Server ---
echo "🔹 Installing K3s Server on $SERVER_IP..."
ssh $SSH_OPTS $USER@$SERVER_IP "curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644"

echo "✅ Server Installed. Waiting for node-token..."
sleep 10

# --- 2. Fetch the Join Token ---
NODE_TOKEN=$(ssh $SSH_OPTS $USER@$SERVER_IP "sudo cat /var/lib/rancher/k3s/server/node-token")
echo "🔑 Token fetched: $NODE_TOKEN"

# --- 3. Join Agent 1 ---
echo "🔹 Joining Agent 1 ($AGENT_1_IP)..."
ssh $SSH_OPTS $USER@$AGENT_1_IP "curl -sfL https://get.k3s.io | K3S_URL=https://$SERVER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -"

# --- 4. Join Agent 2 ---
echo "🔹 Joining Agent 2 ($AGENT_2_IP)..."
ssh $SSH_OPTS $USER@$AGENT_2_IP "curl -sfL https://get.k3s.io | K3S_URL=https://$SERVER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -"

# --- 5. Configure Local Access ---
echo "🔹 Setting up local kubectl access..."
mkdir -p ~/.kube
scp $SSH_OPTS $USER@$SERVER_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/config
# Replace 127.0.0.1 with the actual Server IP in the config file
sed -i '' "s/127.0.0.1/$SERVER_IP/g" ~/.kube/config

echo "🎉 Cluster is ready! Running 'kubectl get nodes'..."
kubectl get nodes