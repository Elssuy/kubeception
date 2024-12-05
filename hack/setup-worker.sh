#!/bin/bash

set -e
set -x

usage() {
  echo "USAGE: ${0} [Control plane IP] [TOKEN] [CA String]"
  exit 1
}

CONTROLPLANE_IP=$1
TOKEN=$2
CA=$3
KUBELETVERSION=1.31.3
KUBERNETES_VERSION=v1.31
PROJECT_PATH=stable:/v1.31

if [[ -z ${CONTROLPLANE_IP} ]]; then
  echo "Control plane ip is not set"
  usage
fi

if [[ -z ${TOKEN} ]]; then
  echo "Token is not set"
  usage
fi

if [[ -z ${CA} ]]; then
  echo "CA is not set"
  usage
fi


###################
# Network setup
###################

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

###################
# CRI-O Setup
###################

sudo apt update
sudo apt install apt-transport-https ca-certificates curl gnupg2 software-properties-common -y

export OS=xUbuntu_22.04
export CRIO_VERSION=1.24

curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/${PROJECT_PATH}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
cat <<EOF | sudo tee /etc/apt/sources.list.d/cri-o.list
deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/${PROJECT_PATH}/deb/ /
EOF

sudo apt update
sudo apt install cri-o -y

sudo systemctl start crio
sudo systemctl enable crio

# Install Kubelet

sudo apt-get update && sudo apt-get install -y apt-transport-https curl
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /
EOF
sudo apt-get update
sudo apt-get install -y kubelet
sudo apt-mark hold kubelet

###################
# Kubelet setup
###################

mkdir -p /var/lib/kubelet
mkdir -p /var/lib/kubelet/pki
mkdir -p /var/lib/kubelet/manifests
mkdir -p /etc/kubernetes

cat <<EOF > /var/lib/kubelet/kubelet-config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerRuntimeEndpoint: /run/crio/crio.sock
cgroupDriver: systemd
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /var/lib/kubelet/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
clusterDNS:
  - 10.32.0.2
clusterDomain: cluster.local
rotateCertificates: true
serverTLSBootstrap: false
EOF

cat <<EOF > /var/lib/kubelet/bootstrap-kubeconfig
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /var/lib/kubelet/pki/ca.crt
    server: https://$CONTROLPLANE_IP:6443
  name: bootstrap
contexts:
- context:
    cluster: bootstrap
    user: kubelet-bootstrap
  name: bootstrap
current-context: bootstrap
kind: Config
preferences: {}
users:
- name: kubelet-bootstrap
  user:
    token: $TOKEN
EOF


cat <<EOF > /etc/systemd/system/kubelet.service
[Unit]
Description=Kubelet Service
Requires=cri-o.service
After=cri-o.service

[Service]
Restart=always

ExecStart=/usr/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --bootstrap-kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \\
  --kubeconfig=/var/lib/kubelet/kubeconfig


[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "$CA" | base64 -d > /var/lib/kubelet/pki/ca.crt
