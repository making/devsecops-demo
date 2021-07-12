#!/bin/bash
set -ex

REGISTRY_HOST=$1
CA_PATH=$2

cat <<EOF >> /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".registry.configs."${REGISTRY_HOST}".tls]
  ca_file = "${CA_PATH}"
EOF

systemctl restart containerd